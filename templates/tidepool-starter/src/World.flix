// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 1 手（act）: ヤドカリの手を盤に当てる → t を 1 進める → 水を更新（Tide.flow）→ 流木の浮き沈み → クリアか流されたか。
// 手ごとの状態（State）は Worldline に積み、取り消し（Z）は 1 つ戻る・やり直し（R）は面の初めを新しく積む。
// 先読みは同じ act に「待つ」を当てた結果（forecastOf）。盤の値は Board、水は Tide、色は ThemeDoc。
// Doc と面の列は Res が持ち、World は持たない（読む口は先頭に res を受ける）。
//
// ── 場面の移り変わり ──
//   Title ──決定──▶ Play（Phase: Playing ──巻き貝──▶ Cleared ──決定──▶ 次の面の Play / 最後なら Ending）
//                              Playing ──沈んだ──▶ Washed ──取り消し・やり直し──▶ Playing
mod World {

    use fge::{EcsTween, Emit, Worldline}
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

    /// 終了の確認。Esc か窓の閉じるボタンで Asking、はいで Confirmed（Main の App.quitWhen が見る）、いいえで Playing へ戻る。
    pub enum Quit with Eq, ToString {
        case Playing
        case Asking
        case Confirmed
    }

    /// どの画面か。その画面だけが持つ値を payload に持つ。
    /// WhyNot: Eq・ToString を付けない。Session は Worldline と動きの表を持ち、比べられない。比べる・字にするのは ScreenKind。
    pub enum Screen {
        /// 選んでいる面（0 から）。
        case Title(Int32)
        /// 遊んでいる面。
        case Play(Session)
        /// 最後の面を終えた後。最後の面の Session をそのまま持つ（背景の盤と、クリアの演出の時計 since を読む）。
        case Ending(Session)
    }

    /// 画面の名前だけ（比べる・flow の問いと指紋の字にする）。
    pub enum ScreenKind with Eq, ToString {
        case Title
        case Play
        case Ending
    }

    /// マウスで押せる物（View が描く木に ZStack.hit で積み、Controls が SortingLayer.pickFrom で引く）。
    pub enum Press with Eq, ToString {
        case QuitYes
        case QuitNo
    }

    /// 遊んでいる面の中身。
    pub type alias SessionRec = {
        level = Int32,
        line = Worldline.Worldline[State],
        // 1 手の前の状態と、そこから今の状態への進み（0..1。motion が進める）。画面は 2 つの間をつないで描く。
        before = State,
        blend = Float64,
        motion = EcsTween.Tweens[Int32, Int32],
        // 今の状態になった時刻（クリア・流されたの演出の時計）。
        since = Float64
    }

    /// 遊んでいる面。作るのは World の中（freshLevel）だけ。外からは sessionRecOf で読む。
    enum SessionOf(SessionRec)

    pub type alias Session = SessionOf

    /// 遊びの状態。best はクリアした面 → 一番多く取った貝殻の数（題名の画面で開いている面もここから決まる）。
    /// events は起きた出来事の溜め（Controls.sounds が前後の差 Emit.since だけを読む）。
    pub type alias World = {
        best = Map[Int32, Int32],
        t = Float64,
        screen = Screen,
        quit = Quit,
        events = Emit.Events[Event]
    }

    /// 描くため・問いのために読む、今の面と状態。Title は選んでいる面の初め（before = now・blend = 1）。
    pub type alias Shown = { level = Int32, now = State, before = State, blend = Float64, since = Float64 }

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
    // 画面と面を読む
    // ══════════════════════════════════════════════════════

    def sessionRec(session: Session): SessionRec = match session {
        case SessionOf.SessionOf(rec) => rec
    }

    def mapSessionRec(f: SessionRec -> SessionRec, session: Session): Session = SessionOf.SessionOf(f(sessionRec(session)))

    /// 遊んでいる面の中身（Play の外は None）。
    pub def sessionRecOf(w: World): Option[SessionRec] = match w#screen {
        case Screen.Play(session) => Some(sessionRec(session))
        case _                    => None
    }

    /// 遊んでいる面の中身を f で替える（Play の外はそのまま）。
    def mapSession(f: SessionRec -> SessionRec, w: World): World = match w#screen {
        case Screen.Play(session) => { screen = Screen.Play(mapSessionRec(f, session)) | w }
        case _                    => w
    }

    def current(s: SessionRec): State = Worldline.current(s#line)

    def shownOfSession(s: SessionRec): Shown =
        { level = s#level, now = current(s), before = s#before, blend = s#blend, since = s#since }

    /// 今の面と状態（値は加工しない。背景のための差し替えは View.inputOf）。
    pub def shownOf(res: Res.Res, w: World): Shown = match w#screen {
        case Screen.Title(level) =>
            let now = startOf(stageAt(res, level)#board);
            { level = level, now = now, before = now, blend = 1.0, since = w#t }
        case Screen.Play(session)   => shownOfSession(sessionRec(session))
        case Screen.Ending(session) => shownOfSession(sessionRec(session))
    }

    pub def state(res: Res.Res, w: World): State = shownOf(res, w)#now

    /// 今の面の番号（0 から）。
    pub def levelOf(w: World): Int32 = match w#screen {
        case Screen.Title(level)    => level
        case Screen.Play(session)   => sessionRec(session)#level
        case Screen.Ending(session) => sessionRec(session)#level
    }

    pub def screenKindOf(w: World): ScreenKind = match w#screen {
        case Screen.Title(_)  => ScreenKind.Title
        case Screen.Play(_)   => ScreenKind.Play
        case Screen.Ending(_) => ScreenKind.Ending
    }

    // ══════════════════════════════════════════════════════
    // 面の進行・取り消し・やり直し
    // ══════════════════════════════════════════════════════

    /// 面の番号を面の列の内へ収める。
    def clampLevel(res: Res.Res, level: Int32): Int32 = Int32.max(0, Int32.min(Vector.length(res#stages) - 1, level))

    def stageAt(res: Res.Res, level: Int32): Res.Stage = Vector.get(clampLevel(res, level), res#stages)

    /// 今の面。
    def stage(res: Res.Res, w: World): Res.Stage = stageAt(res, levelOf(w))

    pub def board(res: Res.Res, w: World): Board.Board = stage(res, w)#board

    pub def rockLevels(res: Res.Res, w: World): List[Layout.RockLevel] = Layout.levelsOf(stage(res, w)#rocks)

    /// 面 index の初めから遊ぶ（取り消しの履歴も新しくする）。
    pub def enterLevel(res: Res.Res, index: Int32, w: World): World = freshLevel(res, index, w) |> logged(Event.Selected :: Nil)

    def freshLevel(res: Res.Res, index: Int32, w: World): World =
        let start = startOf(stageAt(res, index)#board);
        let session = { level = index, line = Worldline.make(start, RulesDoc.rec(res#rules)#undoCap), before = start, blend = 1.0,
                        motion = Map.empty(), since = w#t };
        { screen = Screen.Play(SessionOf.SessionOf(session)) | w }

    /// 手を当てる。動けなかった手と、Play の外では何も変えない（履歴も出来事も積まない）。
    pub def play(res: Res.Res, move: Move, w: World): World =
        sessionRecOf(w) |> Option.flatMap(s -> {
            let b = stageAt(res, s#level)#board;
            act(b, move, current(s)) |> Option.map(next ->
                w |> mapSession(movedTo(res, w#t, Worldline.record(next, s#line))) |> logged(eventsOf(b, current(s), next)))
        }) |> Option.getWithDefault(w)

    /// 1 手戻す（流された後・クリアの後も戻れる）。Play の外では何もしない。
    pub def undo(res: Res.Res, w: World): World =
        sessionRecOf(w) |> Option.map(s -> {
            let undone = movedTo(res, w#t, Worldline.undo(s#line), s);
            w |> mapSession(_ -> undone) |> logged(if (toTuple(current(undone)) == toTuple(current(s))) Nil else Event.Undone :: Nil)
        }) |> Option.getWithDefault(w)

    /// 面の初めへ。履歴は残すので、取り消しでやり直しの前へ戻れる。Play の外では何もしない。
    pub def restart(res: Res.Res, w: World): World =
        sessionRecOf(w) |> Option.map(s ->
            w |> mapSession(movedTo(res, w#t, Worldline.record(startOf(stageAt(res, s#level)#board), s#line))) |> logged(Event.Restarted :: Nil)
        ) |> Option.getWithDefault(w)

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

    /// 状態が変わった後（line が新しい履歴）: 前の状態から今の状態へつなぐ動きを始める。t は今の時刻。
    /// 動いている途中で次の手が来ても、前の状態は「終わった後」の値なので、動きは終わりへ飛んでから次へ移る。
    def movedTo(res: Res.Res, t: Float64, line: Worldline.Worldline[State], s: SessionRec): SessionRec =
        let track = EcsTween.Track.Scalar({ start = 0.0, target = 1.0 });
        { line = line, before = current(s), blend = 0.0, since = t,
          motion = EcsTween.start((0, 0), track, RulesDoc.rec(res#rules)#tweenSeconds, EcsTween.Easing.EaseInOut, false, Map.empty()) | s }

    /// クリアの後の決定: 貝殻を残して次の面へ。最後の面なら Ending（Session はそのまま持つ）。
    pub def advance(res: Res.Res, w: World): World = match w#screen {
        case Screen.Play(session) => advanceFrom(res, session, w)
        case _                    => w
    }

    def advanceFrom(res: Res.Res, session: Session, w: World): World =
        let s = sessionRec(session);
        if (current(s)#phase != Phase.Cleared) w
        else {
            let shells = shellsFor(res#rules, stageAt(res, s#level)#parMoves, current(s)#t);
            let kept = { best = Map.insertWith(Int32.max, s#level, shells, w#best) | w };
            if (s#level + 1 >= Vector.length(res#stages)) logged(Event.Selected :: Nil, { screen = Screen.Ending(session) | kept })
            else enterLevel(res, s#level + 1, kept)
        }

    /// 題名の画面で開いている面か（面 1 と、前の面をクリアした面）。
    pub def isOpened(res: Res.Res, index: Int32, w: World): Bool =
        index >= 0 and index < Vector.length(res#stages) and (index == 0 or Map.memberOf(index - 1, w#best))

    /// 題名の画面で選ぶ面を delta だけ動かす（開いていない面へは動かない。題名の外では何もしない）。
    pub def selectLevel(res: Res.Res, delta: Int32, w: World): World = match w#screen {
        case Screen.Title(level) if isOpened(res, level + delta, w) =>
            logged(Event.Selected :: Nil, { screen = Screen.Title(level + delta) | w })
        case _ => w
    }

    /// 今の面の名前と最少手数。
    pub def stageName(res: Res.Res, w: World): String = stage(res, w)#name

    pub def parMoves(res: Res.Res, w: World): Int32 = stage(res, w)#parMoves

    // ══════════════════════════════════════════════════════
    // 起動・画面・Doc の差し替え
    // ══════════════════════════════════════════════════════

    pub def width(): Float64 = 640.0
    pub def height(): Float64 = 360.0

    pub def spritePath(): String = "assets/tidepool.sprite.json"

    /// 面の名前 → Doc のパス。
    pub def surfacePath(name: String): String = "assets/${name}.shader.json"

    /// ゲーム開始時の状態（題名の画面・面 1）。
    pub def initial(): World =
        { best = Map.empty(), t = 0.0, screen = Screen.Title(0), quit = Quit.Playing, events = Emit.empty() }

    /// 時刻を進める（水や海藻の揺れ）と、遊んでいる面の 1 手の動きを進める。
    pub def tick(dt: Float64, w: World): World =
        { t = w#t + dt | w } |> mapSession(tickMotion(dt))

    def tickMotion(dt: Float64, s: SessionRec): SessionRec =
        let (motion, outs, _) = EcsTween.step(dt, s#motion);
        let blend = outs |> List.foldLeft((acc, out) -> match snd(out) {
            case EcsTween.Out.ScalarOut(v) => v
            case _                         => acc
        }, s#blend);
        { motion = motion, blend = blend | s }

    /// 題名へ（どの画面からでも。選ぶ面は今の面）。
    pub def backToTitle(w: World): World = logged(Event.Selected :: Nil, { screen = Screen.Title(levelOf(w)) | w })

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

    /// 面の列が組み直された後（決まりか面の Doc を保存した）: 面の番号を数の内に収める。遊んでいる面は初めから
    /// （盤の形も満ち引きも変わりうるので履歴は持ち越さない・出来事は積まない）。終わりの画面は番号だけ収め、終えた状態と時刻はそのまま。
    pub def settleStages(res: Res.Res, w: World): World = match w#screen {
        case Screen.Title(level)    => { screen = Screen.Title(clampLevel(res, level)) | w }
        case Screen.Play(session)   => freshLevel(res, clampLevel(res, sessionRec(session)#level), w)
        case Screen.Ending(session) => { screen = Screen.Ending(mapSessionRec(s -> { level = clampLevel(res, s#level) | s }, session)) | w }
    }
}
