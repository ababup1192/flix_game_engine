// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 1 手（act）: ヤドカリの手を盤に当てる → t を 1 進める → 水を更新（Tide.flow）→ 流木の浮き沈み → クリアか流されたか。
// 手ごとの状態（State）は Worldline に積み、取り消し（Z）は 1 つ戻る・やり直し（R）は面の初めを新しく積む。
// 先読みは同じ act に「待つ」を当てた結果（forecastOf）。盤の値は Board、水は Tide、色は ThemeDoc。
//
// ── 場面の移り変わり ──
//   Title ──決定──▶ Play（Phase: Playing ──巻き貝──▶ Cleared ──決定──▶ 次の面の Play / 最後なら Ending）
//                              Playing ──沈んだ──▶ Washed ──取り消し・やり直し──▶ Playing
mod World {

    use fge::{AudioMixer, EcsTween, Emit, Log, PxShade, PxSpriteAtlas, PxSpriteDoc, ShaderDoc, Worldline}
    use Board.Cell

    /// ヤドカリの手。動けなかった手は手に数えない（act が None を返す）。
    pub enum Move with Eq, Order, ToString {
        case Up
        case Down
        case Left
        case Right
        case Wait
    }

    /// 面の中のフェーズ。Cleared と Washed では手を受けない（取り消し・やり直しは受ける）。
    pub enum Phase with Eq, ToString {
        case Playing
        case Cleared
        case Washed
    }

    /// 手や画面の操作で起きた出来事（World は音を知らない。Controls.soundOf が出来事から音を選ぶ）。
    pub enum Event with Eq, ToString {
        case WalkedOnSand
        case WalkedOnRock
        case PushedPebble
        case MovedDriftwood
        case TideFull
        case TideLow
        case Washed
        case Cleared
        case Undone
        case Restarted
        case Selected
        case Cancelled
    }

    /// 1 手ごとの状態。t は面の初めからの手数（＝手数の表示）。water は盤の中の全マスの水面の高さ。
    pub type alias State = {
        crab = Cell,
        pebbles = Set[Cell],
        driftwood = Set[Cell],
        water = Tide.Water,
        t = Int32,
        phase = Phase
    }

    /// 状態を比べられる組へ（record は Eq を持たないので、取り消しの前後を比べる時に使う）。
    pub def toTuple(s: State): (Cell, Set[Cell], Set[Cell], Tide.Water, Int32, Phase) =
        (s#crab, s#pebbles, s#driftwood, s#water, s#t, s#phase)

    /// 遊べる 1 面（Doc の名前と最少手数と盤）。rocks は盤から導いた岩の段の形（描くための形を前もって作って持つ。atlas と同じ扱い）。
    pub type alias Stage = { name = String, parMoves = Int32, board = Board.Board, rocks = Layout.RockLevels }

    /// 終了の確認。Esc か窓の閉じるボタンで Asking、はいで Confirmed（Main の App.quitWhen が見る）、いいえで Playing へ戻る。
    pub enum Quit with Eq, ToString {
        case Playing
        case Asking
        case Confirmed
    }

    /// どの画面か。
    pub enum Screen with Eq, ToString {
        case Title
        case Play
        case Ending
    }

    /// マウスで押せる物（View が描く木に ZStack.hit で積み、Controls が SortingLayer.pickFrom で引く）。
    pub enum Press with Eq, ToString {
        case QuitYes
        case QuitNo
    }

    pub type alias World = {
        rules = RulesDoc.Doc,
        levels = LevelsDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        // ドット絵を 1 枚にまとめたアトラスと、その画素から導いた鍵（bakedOf）。
        atlas = PxSpriteAtlas.Baked,
        atlasKey = String,
        surfaces = Surfaces,
        stages = Vector[Stage],
        level = Int32,
        line = Worldline.Worldline[State],
        // 1 手の前の状態と、そこから今の状態への進み（0..1。motion が進める）。画面は 2 つの間をつないで描く。
        before = State,
        blend = Float64,
        motion = EcsTween.Tweens[Int32, Int32],
        // 今の状態になった時刻（クリア・流されたの演出の時計）。
        since = Float64,
        // クリアした面 → 一番多く取った貝殻の数（題名の画面で開いている面もここから決まる）。
        best = Map[Int32, Int32],
        t = Float64,
        screen = Screen,
        quit = Quit,
        // 起きた出来事の溜め（Controls.sounds が前後の差 Emit.since だけを読む）と、音の通り道。
        events = Emit.Events[Event],
        mixer = AudioMixer.Mixer
    }

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub type alias Docs = {
        rules = RulesDoc.Doc,
        levels = LevelsDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        surfaces = Surfaces,
        mixer = AudioMixer.Mixer
    }

    /// 面を塗る宣言シェーダーの一式（どれも assets/*.shader.json から読む）。
    pub type alias Surfaces = {
        rock = ShaderDoc.Spec,
        water = ShaderDoc.Spec,
        caustics = ShaderDoc.Spec
    }

    // ══════════════════════════════════════════════════════
    // 1 手の規則
    // ══════════════════════════════════════════════════════

    /// 面の初めの状態（水は満ち引きを 1 周回した後の物）。
    pub def startOf(b: Board.Board): State =
        { crab = b#crab, pebbles = b#pebbles, driftwood = b#driftwood,
          water = Tide.initialWater(b), t = 0, phase = Phase.Playing }

    /// 1 手。動けない・押せない手、遊んでいないフェーズでは None（手に数えない）。
    pub def act(b: Board.Board, move: Move, s: State): Option[State] =
        if (s#phase != Phase.Playing) None
        else applyMove(b, move, s) |> Option.map(moved -> {
            let t = s#t + 1;
            let water = Tide.flow(moved#pebbles, Board.tideAt(t, b), s#water, b);
            let after = { water = water, t = t | moved };
            { phase = phaseOf(b, after) | after }
        })

    /// 手の後のフェーズ: 巻き貝なら Cleared、沈んだマスで流木の上でないなら Washed。
    def phaseOf(b: Board.Board, s: State): Phase =
        if (s#crab == b#goal) Phase.Cleared
        else if (Tide.isSubmerged(s#crab, s#water, b) and not Set.memberOf(s#crab, s#driftwood)) Phase.Washed
        else Phase.Playing

    /// 手を盤に当てる（水と t はまだ動かさない）。押す表は上から当てはめる。
    def applyMove(b: Board.Board, move: Move, s: State): Option[State] =
        match stepOf(move) {
            case None => Some(s)
            case Some(dir) =>
                let target = offset(dir, s#crab);
                let beyond = offset(dir, target);
                if (Set.memberOf(target, s#pebbles)) {
                    let canPush = Board.isInside(beyond, b) and not isOccupied(b, s, beyond)
                        and Board.heightAt(beyond, b) <= Board.heightAt(target, b);
                    let pushed = { pebbles = s#pebbles |> Set.remove(target) |> Set.insert(beyond) | s };
                    if (canPush and canEnter(b, pushed, s#crab, target)) Some({ crab = target | pushed }) else None
                } else if (isAfloat(b, s, target)) {
                    if (Board.isInside(beyond, b) and Tide.isSubmerged(beyond, s#water, b) and not isOccupied(b, s, beyond))
                        Some({ driftwood = s#driftwood |> Set.remove(target) |> Set.insert(beyond) | s })
                    else if (canEnter(b, s, s#crab, target)) Some({ crab = target | s })
                    else None
                } else if (canEnter(b, s, s#crab, target)) Some({ crab = target | s })
                else None
        }

    /// 行ける条件: 盤の中・小石が無い・沈んでいない（浮いた流木の上は可）・立つ高さの差が 1 以内。
    def canEnter(b: Board.Board, s: State, here: Cell, target: Cell): Bool =
        Board.isInside(target, b) and not Set.memberOf(target, s#pebbles)
            and (not Tide.isSubmerged(target, s#water, b) or Set.memberOf(target, s#driftwood))
            and Int32.abs(standHeight(b, s, target) - standHeight(b, s, here)) <= 1

    /// 立つ高さ: 浮いた流木があれば水面、無ければ地面。
    pub def standHeight(b: Board.Board, s: State, cell: Cell): Int32 =
        if (isAfloat(b, s, cell)) Map.getWithDefault(cell, 0, s#water) else Board.heightAt(cell, b)

    /// 流木があり、そのマスが沈んでいる。
    def isAfloat(b: Board.Board, s: State, cell: Cell): Bool =
        Set.memberOf(cell, s#driftwood) and Tide.isSubmerged(cell, s#water, b)

    /// 押し先に物がある（小石・流木・ヤドカリ・巻き貝）。
    /// WhyNot: 巻き貝のマスへ押させない。小石が乗ると巻き貝へ入れなくなり、取り消しでしか戻れない形が増えるだけなので。
    def isOccupied(b: Board.Board, s: State, cell: Cell): Bool =
        Set.memberOf(cell, s#pebbles) or Set.memberOf(cell, s#driftwood) or cell == s#crab or cell == b#goal

    def stepOf(move: Move): Option[(Int32, Int32)] = match move {
        case Move.Up    => Some((0, -1))
        case Move.Down  => Some((0, 1))
        case Move.Left  => Some((-1, 0))
        case Move.Right => Some((1, 0))
        case Move.Wait  => None
    }

    def offset(dir: (Int32, Int32), cell: Cell): Cell =
        let ((dx, dy), (x, y)) = (dir, cell);
        (x + dx, y + dy)

    /// 手の列を順に当てる。動けなかった手は飛ばす（数えない）。
    pub def actAll(b: Board.Board, moves: List[Move], s: State): State =
        moves |> List.foldLeft((acc, move) -> act(b, move, acc) |> Option.getWithDefault(acc), s)

    /// 解き方の字（U D L R W）を手の列へ。読めない字があれば None。
    pub def movesOf(text: String): Option[List[Move]] =
        String.toList(text) |> List.traverse(ch -> match ch {
            case 'U' => Some(Move.Up)
            case 'D' => Some(Move.Down)
            case 'L' => Some(Move.Left)
            case 'R' => Some(Move.Right)
            case 'W' => Some(Move.Wait)
            case _   => None
        })

    /// 手の列を解き方の字へ。
    pub def textOf(moves: List[Move]): String =
        moves |> List.map(move -> match move {
            case Move.Up    => "U"
            case Move.Down  => "D"
            case Move.Left  => "L"
            case Move.Right => "R"
            case Move.Wait  => "W"
        }) |> List.join("")

    // ══════════════════════════════════════════════════════
    // 先読み（「何もしないで 1 手待ったら」を同じ act で出す）
    // ══════════════════════════════════════════════════════

    /// 次の手で沈むマス・現れるマスと、待つとヤドカリが流されるか。遊んでいないフェーズでは空。
    pub type alias Forecast = { flooding = Set[Cell], emerging = Set[Cell], crabWashed = Bool }

    pub def forecastOf(b: Board.Board, s: State): Forecast =
        match act(b, Move.Wait, s) {
            case None => { flooding = Set.empty(), emerging = Set.empty(), crabWashed = false }
            case Some(next) =>
                let (now, later) = (submergedCells(b, s), submergedCells(b, next));
                { flooding = Set.difference(later, now), emerging = Set.difference(now, later),
                  crabWashed = next#phase == Phase.Washed }
        }

    /// 沈んでいるマス。
    pub def submergedCells(b: Board.Board, s: State): Set[Cell] =
        Board.cells(b) |> List.filter(c -> Tide.isSubmerged(c, s#water, b)) |> List.toSet

    /// クリアした手数の貝殻（par 以下 3・par + 幅 以下 2・それより多いと 1）。
    pub def shellsFor(rules: RulesDoc.Doc, parMoves: Int32, moves: Int32): Int32 =
        if (moves <= parMoves) 3 else if (moves <= parMoves + RulesDoc.rec(rules)#shellWidth) 2 else 1

    // ══════════════════════════════════════════════════════
    // 面の進行・取り消し・やり直し
    // ══════════════════════════════════════════════════════

    /// Doc から遊べる面の列を組む（組めない面は飛ばして 1 行ずつ言う。LevelsDoc.boardsOf）。
    def stagesOf(rules: RulesDoc.Doc, levels: LevelsDoc.Doc): Vector[Stage] =
        let built = LevelsDoc.boardsOf(rules, levels);
        built#boards
            |> Log.warnAllThen(built#problems)
            |> List.map(match (level, b) -> { name = level#name, parMoves = level#parMoves, board = b, rocks = Layout.rockLevelsOf(b) })
            |> List.toVector

    /// 今の面。
    def stage(w: World): Stage =
        Vector.get(Int32.max(0, Int32.min(Vector.length(w#stages) - 1, w#level)), w#stages)

    pub def board(w: World): Board.Board = stage(w)#board

    pub def rockLevels(w: World): List[Layout.RockLevel] = Layout.levelsOf(stage(w)#rocks)

    pub def state(w: World): State = Worldline.current(w#line)

    /// 面 index の初めから遊ぶ（取り消しの履歴も新しくする）。
    pub def enterLevel(index: Int32, w: World): World = freshLevel(index, w) |> logged(Event.Selected :: Nil)

    def freshLevel(index: Int32, w: World): World =
        let entered = { level = index, screen = Screen.Play | w };
        let start = startOf(board(entered));
        { line = Worldline.make(start, RulesDoc.rec(w#rules)#undoCap), before = start, blend = 1.0,
          motion = Map.empty(), since = w#t | entered }

    /// 手を当てる。動けなかった手は何も変えない（履歴も積まない）。
    pub def play(move: Move, w: World): World =
        match act(board(w), move, state(w)) {
            case Some(next) => movedFrom(w, { line = Worldline.record(next, w#line) | w }) |> logged(eventsOf(board(w), state(w), next))
            case None       => w
        }

    /// 1 手戻す（流された後・クリアの後も戻れる）。
    pub def undo(w: World): World =
        let undone = movedFrom(w, { line = Worldline.undo(w#line) | w });
        logged(if (toTuple(state(undone)) == toTuple(state(w))) Nil else Event.Undone :: Nil, undone)

    /// 面の初めへ。履歴は残すので、取り消しでやり直しの前へ戻れる。
    pub def restart(w: World): World =
        movedFrom(w, { line = Worldline.record(startOf(board(w)), w#line) | w }) |> logged(Event.Restarted :: Nil)

    /// 1 手の出来事: 巻き貝に着いた・流されたならそれだけ。ほかは動き（押す・流木・歩く）と、潮の満ち切り・引き切り。
    pub def eventsOf(b: Board.Board, before: State, after: State): List[Event] =
        match after#phase {
            case Phase.Cleared => Event.Cleared :: Nil
            case Phase.Washed  => Event.Washed :: Nil
            case Phase.Playing => Option.toList(actionOf(b, before, after)) ::: Option.toList(tideTurnOf(b, after#t))
        }

    def actionOf(b: Board.Board, before: State, after: State): Option[Event] =
        if (after#pebbles != before#pebbles) Some(Event.PushedPebble)
        else if (after#driftwood != before#driftwood or (after#crab != before#crab and Set.memberOf(after#crab, after#driftwood)))
            Some(Event.MovedDriftwood)
        else if (after#crab == before#crab) None
        else if (Board.heightAt(after#crab, b) == 0) Some(Event.WalkedOnSand)
        else Some(Event.WalkedOnRock)

    /// 手数 t で潮位が満ち引きの表の一番上・一番下に着いた（同じ潮位が続く手は初めの 1 手だけ）。
    /// WhyNot: 毎手の潮位の音は鳴らさない。1 手ごとに鳴ると単調になり、満ち切り・引き切りの節目が埋もれる。
    def tideTurnOf(b: Board.Board, t: Int32): Option[Event] =
        let (now, prev) = (Board.tideAt(t, b), Board.tideAt(t - 1, b));
        if (now == prev) None
        else if (Some(now) == Vector.maximum(b#cycle)) Some(Event.TideFull)
        else if (Some(now) == Vector.minimum(b#cycle)) Some(Event.TideLow)
        else None

    /// 出来事を溜めの末尾に足す。
    def logged(events: List[Event], w: World): World =
        { events = snd(Emit.collectInto(() -> List.forEach(event -> Emit.emit(event), events), w#events)) | w }

    /// 状態が変わった後: 前の状態から今の状態へつなぐ動きを始める。
    /// 動いている途中で次の手が来ても、前の状態は「終わった後」の値なので、動きは終わりへ飛んでから次へ移る。
    def movedFrom(prev: World, w: World): World =
        let track = EcsTween.Track.Scalar({ start = 0.0, target = 1.0 });
        { before = state(prev), blend = 0.0, since = w#t,
          motion = EcsTween.start((0, 0), track, RulesDoc.rec(w#rules)#tweenSeconds, EcsTween.Easing.EaseInOut, false, Map.empty()) | w }

    /// クリアの後の決定: 貝殻を残して次の面へ。最後の面なら Ending。
    pub def advance(w: World): World =
        if (state(w)#phase != Phase.Cleared) w
        else {
            let shells = shellsFor(w#rules, stage(w)#parMoves, state(w)#t);
            let kept = { best = Map.insertWith(Int32.max, w#level, shells, w#best) | w };
            if (w#level + 1 >= Vector.length(w#stages)) logged(Event.Selected :: Nil, { screen = Screen.Ending | kept })
            else enterLevel(w#level + 1, kept)
        }

    /// 題名の画面で開いている面か（面 1 と、前の面をクリアした面）。
    pub def isOpened(index: Int32, w: World): Bool =
        index >= 0 and index < Vector.length(w#stages) and (index == 0 or Map.memberOf(index - 1, w#best))

    /// 題名の画面で選ぶ面を delta だけ動かす（開いていない面へは動かない）。
    pub def selectLevel(delta: Int32, w: World): World =
        if (isOpened(w#level + delta, w)) logged(Event.Selected :: Nil, { level = w#level + delta | w }) else w

    /// 今の面の名前と最少手数。
    pub def stageName(w: World): String = stage(w)#name

    pub def parMoves(w: World): Int32 = stage(w)#parMoves

    // ══════════════════════════════════════════════════════
    // 起動・画面・Doc の差し替え
    // ══════════════════════════════════════════════════════

    pub def width(): Float64 = 640.0
    pub def height(): Float64 = 360.0

    pub def spritePath(): String = "assets/tidepool.sprite.json"

    /// 面の名前 → Doc のパス。
    pub def surfacePath(name: String): String = "assets/${name}.shader.json"

    /// 「中の色 → (明るい色, 暗い色)」の対応。文字は sprite.json の legend に合わせる。
    def shadeRamp(): PxShade.Ramp = Map#{ 'a' => ('A', 'd') }

    /// 読み込んだドット絵に仕上げ（ふち光・接地影・ディザ・粒）を掛ける（読み込み直後の 1 回だけ）。
    def shaded(theme: ThemeDoc.Doc, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        PxShade.shadeDoc(ThemeDoc.rec(theme)#shade, shadeRamp(), doc)

    /// GPU に登録するアトラスの論理名（View の drawQuad と Main の withSpriteAtlases がこの名前で待ち合わせる）。
    pub def atlasName(): String = "px"

    /// ドット絵を 1 枚のアトラスにまとめ、GPU キャッシュ用の鍵と対で返す。
    /// WhyNot: 鍵を名前だけにしない。Doc や色票を保存し直して絵が変わっても、鍵が同じだと GPU に古いテクスチャが残る。
    def bakedOf(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc): (PxSpriteAtlas.Baked, String) =
        let baked = PxSpriteAtlas.bake(sprites, key -> ThemeDoc.resolver(theme, key));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        (baked, "${atlasName()}:${Int32.toString(baked#side)}:${Int32.toString(h)}")

    def withShadedSprites(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, w: World): World =
        let doc = shaded(theme, sprites);
        let (baked, key) = bakedOf(theme, doc);
        { theme = theme, sprites = doc, atlas = baked, atlasKey = key | w }

    /// ゲーム開始時の状態（題名の画面・面 1）。
    pub def initial(docs: Docs): World =
        let shadedSprites = shaded(docs#theme, docs#sprites);
        let (baked, key) = bakedOf(docs#theme, shadedSprites);
        let stages = stagesOf(docs#rules, docs#levels);
        let first = Vector.head(stages) |> Option.map(s -> startOf(s#board))
            |> Option.getWithDefault({ crab = (0, 0), pebbles = Set.empty(), driftwood = Set.empty(),
                                       water = Map.empty(), t = 0, phase = Phase.Playing });
        { rules = docs#rules, levels = docs#levels, keys = docs#keys, theme = docs#theme, sprites = shadedSprites,
          atlas = baked, atlasKey = key, surfaces = docs#surfaces,
          stages = stages, level = 0, line = Worldline.make(first, RulesDoc.rec(docs#rules)#undoCap),
          before = first, blend = 1.0, motion = Map.empty(), since = 0.0, best = Map.empty(),
          t = 0.0, screen = Screen.Title, quit = Quit.Playing, events = Emit.empty(), mixer = docs#mixer }

    /// 時刻を進める（水や海藻の揺れ）と、1 手の動きを進める。
    pub def tick(dt: Float64, w: World): World =
        let (motion, outs, _) = EcsTween.step(dt, w#motion);
        let blend = outs |> List.foldLeft((acc, out) -> match snd(out) {
            case EcsTween.Out.ScalarOut(v) => v
            case _                         => acc
        }, w#blend);
        { t = w#t + dt, motion = motion, blend = blend | w }

    pub def withScreen(screen: Screen, w: World): World = { screen = screen | w }

    /// 終わりの画面から題名へ。
    pub def backToTitle(w: World): World = logged(Event.Selected :: Nil, withScreen(Screen.Title, w))

    // ── 終了の確認 ──

    /// Esc・閉じるボタン: 遊んでいる間なら確認の窓を出す。
    pub def askQuit(w: World): World =
        if (w#quit == Quit.Playing) logged(Event.Selected :: Nil, { quit = Quit.Asking | w }) else w

    /// 確認の窓への答え（yes なら終わる・no なら遊びへ戻る）。窓が出ていないときは何もしない。
    pub def answerQuit(yes: Bool, w: World): World =
        if (w#quit != Quit.Asking) w
        else if (yes) { quit = Quit.Confirmed | w }
        else logged(Event.Cancelled :: Nil, { quit = Quit.Playing | w })

    pub def isAskingQuit(w: World): Bool = w#quit == Quit.Asking

    pub def isQuitting(w: World): Bool = w#quit == Quit.Confirmed

    // ── Doc の差し替え（保存即反映） ──

    /// 決まりか面の Doc を差し替えたら面を組み直し、遊んでいる面は初めから（盤の形も満ち引きも変わりうるので履歴は持ち越さない）。
    pub def withRules(rules: RulesDoc.Doc, w: World): World = rebuilt({ rules = rules | w })

    pub def withLevels(levels: LevelsDoc.Doc, w: World): World = rebuilt({ levels = levels | w })

    def rebuilt(w: World): World =
        let stages = stagesOf(w#rules, w#levels);
        let level = Int32.max(0, Int32.min(Vector.length(stages) - 1, w#level));
        let reloaded = { stages = stages | w };
        if (w#screen == Screen.Play) freshLevel(level, reloaded) else { level = level | reloaded }

    pub def withKeys(keys: KeysDoc.Doc, w: World): World = { keys = keys | w }

    /// テーマには仕上げの強さ・光の向きも入っているので、色を変えたら絵も掛け直す。
    pub def withTheme(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc, w: World): World =
        withShadedSprites(theme, sprites, w)

    pub def withSprites(sprites: PxSpriteDoc.Doc, w: World): World =
        withShadedSprites(w#theme, sprites, w)

    pub def withSurfaces(surfaces: Surfaces, w: World): World = { surfaces = surfaces | w }

    pub def withMixer(mixer: AudioMixer.Mixer, w: World): World = { mixer = mixer | w }
}
