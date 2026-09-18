// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 落ちてくるミノを ←→ で寄せ、Z/X で回し、↓ でそっと落とし、Space で一気に落とす。
// 揃った行が消え、点が入る。天井までブロックが積み上がったら GAME OVER。
// 手触りと収支の数値（落下速度・接地の猶予・得点）は RulesDoc、色は ThemeDoc、
// ミノの形は Pieces（別ファイル）— World は「規則」だけに集中する。
//
// ── 毎フレームの流れ ──
//   入力（Controls.step）→ 状態更新（World.step: 重力・接地/固定・ライン消去・涌き）→ 描画（View.frame）
//   Main の App.game の update 行がこの順（Controls.step |> ActiveDocs.step）。
//
// ── 場面の移り変わり（Phase）──
//
//   Playing ──ラインが揃って固定──▶ Clearing ──clearDuration 経過──▶ Playing
//   Playing ──新ミノが涌き位置で衝突──▶ GameOver ──Space/Enter──▶ Playing（リセット）
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// Doc が壊れていても止まらない（fail-open）: 読めない → 既定値で起動、一部が欠け → その欄だけ既定。
mod World {

    /// ミノの 7 種。色（ThemeDoc.colorOf）も形（Pieces.cellsOf）もこの種類から引く。
    pub enum Kind with Eq, ToString {
        case I
        case O
        case T
        case S
        case Z
        case J
        case L
    }

    /// いま画面が何をしているか。
    ///   Playing  … ミノを操作している（ふつうの状態）。
    ///   Clearing … 揃った行を光らせている最中（clearDuration の間）。実消去はこの後。
    ///   GameOver … 積み上がって涌けなくなった（Space/Enter で仕切り直し）。
    pub enum Phase with Eq, ToString {
        case Playing
        case Clearing
        case GameOver
    }

    /// 盤のマス。(col, row)。row 0 が最上段で、下に行くほど row が増える（画面と同じ向き）。
    pub type alias Cell = (Int32, Int32)

    /// いま操作しているミノ。kind = 種類、rot = 向き（0..3）、(col,row) = 原点セルの盤上の位置。
    /// 実際の 4 マスは Pieces.cellsOf(kind, rot) を (col,row) 平行移動したもの（piecesCells）。
    pub type alias Piece = { kind = Kind, rot = Int32, col = Int32, row = Int32 }

    /// ゲームの状態。盤（固定済みセル）と、いま落ちているミノと、次のミノと、収支を持つ。
    /// board は「固定したセル → その色を引くための Kind」。current が操作対象。
    /// bag / seed は 7-bag の涌き順（決定的な擬似乱数）。
    /// gravityTimer / lockTimer / grounded / lockResets が「落ちる・接地でねばる」の心臓。
    pub type alias World = {
        doc = RulesDoc.Doc,
        theme = ThemeDoc.Doc,
        shader = ShaderDoc.Spec,
        t = Float64,
        board = Map[Cell, Kind],
        current = Piece,
        nextKind = Kind,
        bag = List[Kind],
        seed = Int64,
        gravityTimer = Float64,
        lockTimer = Float64,
        grounded = Bool,
        lockResets = Int32,
        phase = Phase,
        clearRows = List[Int32],
        clearTimer = Float64,
        score = Int32,
        lines = Int32,
        activeDocsWritten = String
    }

    // ── 盤の寸法（project.json のレイアウトと対。View も同じ値を使う） ──

    pub def cols(): Int32 = 10
    pub def rows(): Int32 = 20

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub type alias Docs = { doc = RulesDoc.Doc, theme = ThemeDoc.Doc, shader = ShaderDoc.Spec }

    pub def shaderPath(): String = "assets/tetris.shader.json"

    /// ゲーム開始時の状態。空の盤に最初のミノが涌いた状態から始まる。
    /// seed は固定の定数から出発する（描き出しが決定的になる・遊びも毎回同じ並びで再現できる）。
    pub def initial(docs: Docs): World =
        // 最初のミノと NEXT を bag から引いて据える（spawnNext を 2 回まわす）。
        spawnNext(spawnNext(blank(docs)))

    /// まだ何も涌いていない空の World（initial だけが使う下ごしらえ）。
    /// seed は固定の定数から出発する（描き出しが決定的になる・遊びも毎回同じ並びで再現できる）。
    def blank(docs: Docs): World =
        { doc = docs#doc, theme = docs#theme, shader = docs#shader, t = 0.0, board = Map.empty(),
          current = spawnPiece(Kind.I), nextKind = Kind.I, bag = Nil,
          seed = 1i64, gravityTimer = 0.0, lockTimer = 0.0, grounded = false,
          lockResets = 0, phase = Phase.Playing, clearRows = Nil, clearTimer = 0.0,
          score = 0, lines = 0, activeDocsWritten = "" }

    /// 涌き位置に置いた Piece（rot 0・上端中央）。row = -1 は「最上行の 1 行上（隠しバッファ）」。
    /// こうすると最上段（row 0）まで積める＝盤が上まで満杯になって初めて涌けず GAME OVER になる。
    /// row 0 で涌かせると足元（row 0..1）の中央が塞がった時点で負け、画面の上に空きが見えるのに
    /// 負ける違和感が出る。col = cols/2 - 2 は 4×4 のミノ枠が中央に来るための左寄せ。
    def spawnPiece(kind: Kind): Piece =
        { kind = kind, rot = 0, col = cols() / 2 - 2, row = -1 }

    // ══════════════════════════════════════════════════════
    // 衝突・移動・回転（純粋な規則）
    // ══════════════════════════════════════════════════════

    /// Piece の実際の 4 マス（盤の座標）。Pieces.cellsOf を (col,row) 平行移動する。
    pub def piecesCells(p: Piece): List[Cell] =
        Pieces.cellsOf(p#kind, p#rot)
            |> List.map(cell -> { let (c, r) = cell; (c + p#col, r + p#row) })

    /// Piece が盤とぶつかるか。盤の左右・下の外か、固定セルに重なれば true。
    /// row < 0（上へのはみ出し）は許す — 涌いた直後や回転で一時的に上へ出ることがある。
    pub def collides(p: Piece, board: Map[Cell, Kind]): Bool =
        piecesCells(p) |> List.exists(cell -> {
            let (c, r) = cell;
            c < 0 or c >= cols() or r >= rows() or Map.memberOf(cell, board)
        })

    /// (dCol, dRow) だけ動かす。動けたら動いた World、だめなら元の World —
    /// どちらでも「動けたか」を Bool で同伴して返す（呼び手が lock リセットを判断する材料）。
    pub def tryMove(dCol: Int32, dRow: Int32, w: World): (World, Bool) =
        let moved = { col = w#current#col + dCol, row = w#current#row + dRow | w#current };
        if (collides(moved, w#board))
            (w, false)
        else
            (afterMoveOrRotate({ current = moved | w }), true)

    /// 回転（dir = +1 が時計回り・-1 が反時計回り）。回した形がぶつかるときは
    /// Pieces.wallKickOffsets を順に試し、最初に収まる平行移動を採用する（簡易ウォールキック）。
    /// 全部だめなら回さない。成功したかを Bool で同伴する。
    pub def tryRotate(dir: Int32, w: World): (World, Bool) =
        let rotated = { rot = Int32.modulo(w#current#rot + dir + 4, 4) | w#current };
        let fitted = Pieces.wallKickOffsets() |> List.map(kick -> {
                let (dc, dr) = kick;
                { col = rotated#col + dc, row = rotated#row + dr | rotated }
            })
            |> List.filter(cand -> not collides(cand, w#board))
            |> List.head;
        match fitted {
            case None      => (w, false)
            case Some(cand) => (afterMoveOrRotate({ current = cand | w }), true)
        }

    /// 移動・回転が成功したあとの共通処理: 接地の猶予をリセットする（設置面ねばり）。
    /// ただしリセットの回数が上限（maxLockResets）に達していたら猶予は戻さない
    /// （壁蹴りで無限に固定を先延ばしできないための天井）。
    def afterMoveOrRotate(w: World): World =
        if (w#grounded and w#lockResets < RulesDoc.rec(w#doc)#maxLockResets)
            { lockTimer = 0.0, lockResets = w#lockResets + 1 | w }
        else
            w

    // ══════════════════════════════════════════════════════
    // 涌き（spawnNext）と 7-bag（決定的な擬似乱数）
    // ══════════════════════════════════════════════════════

    /// 次のミノを涌かせる。キュー（bag）の先頭を current に据え、その次を NEXT として覗く。
    /// **取り出す前にキューを 2 枚以上へ継ぎ足す**（refill）ので、NEXT は必ず「次に涌く物」と
    /// 一致する。素朴に「空になってから引き直す」と、袋の最後の 1 枚を取った直後は覗く先が無く
    /// NEXT が現在のミノと同じに化け、次の引き直しで実物とズレる（ハードドロップで顕著）。それを防ぐ。
    /// 7-bag: 継ぎ足しは 7 種のシャッフル 1 袋なので、7 個ごとに全種が 1 度ずつ出る性質は保つ。
    /// 涌いた current が既にぶつかっていたら積み上がり = GAME OVER。[遷移: Playing→GameOver]
    pub def spawnNext(w: World): World =
        let (queue, s1) = refill(w#bag, w#seed);
        match queue {
            case Nil          => w                       // 起こらない（refill 後は必ず 2 枚以上）
            case kind :: rest =>
                let piece = spawnPiece(kind);
                let next = List.head(rest) |> Option.getWithDefault(kind);   // refill 済みなので rest は非空
                let w1 = { current = piece, nextKind = next, bag = rest, seed = s1,
                           gravityTimer = 0.0, lockTimer = 0.0, grounded = false, lockResets = 0 | w };
                if (collides(piece, w1#board))
                    { phase = Phase.GameOver | w1 }
                else
                    w1
        }

    /// キューが 2 枚未満なら 7 種シャッフルを 1 袋継ぎ足す（current を取り出しても NEXT を
    /// 正確に覗ける最小の在庫を保つ）。Pieces.all は 7 枚なので継ぎ足しは 1 回で足りる（再帰は保険）。
    def refill(bag: List[Kind], s: Int64): (List[Kind], Int64) =
        if (List.length(bag) >= 2)
            (bag, s)
        else
            let (fresh, s1) = shuffle(Pieces.all(), s);
            refill(List.append(bag, fresh), s1)

    // LCG（線形合同法・Knuth）。純粋・決定的。描き出しの seed 固定で毎回同じ絵になる。
    def nextSeed(s: Int64): Int64 =
        s * 6364136223846793005i64 + 1442695040888963407i64

    /// 0..n-1 の擬似乱数と次の種。上位ビットを使うと質がよい（下位ビットは周期が短い）。
    /// 上位を右シフトで取り出し、剰余で 0..n-1 に収めてから Int32 へ。
    def randInt(n: Int32, s: Int64): (Int32, Int64) =
        let s1 = nextSeed(s);
        let hi = Int64.abs(Int64.rightShift(s1, 33));
        let r = Int64.modulo(hi, Int32.toInt64(n)) |> Int64.tryToInt32 |> Option.getWithDefault(0);
        (r, s1)

    /// Fisher-Yates で並びをシャッフルする（純粋・決定的）。7-bag の詰め直しに使う。
    def shuffle(xs: List[Kind], s: Int64): (List[Kind], Int64) =
        let n = List.length(xs);
        // 「残り n-i 枚のうち何番目を取り出すか」の index を i=0..n-1 について決めていく。
        let (picks, s1) = List.range(0, n) |> List.foldLeft((acc, i) -> {
            let (chosen, sPrev) = acc;
            let hiExclusive = n - i;
            let (j, sNext) = randInt(hiExclusive, sPrev);
            (List.append(chosen, j :: Nil), sNext)
        }, (Nil, s));
        (applyPicks(xs, picks), s1)

    /// picks[i] = 「残っているカードのうち何番目を i 回目に取り出すか」。これで純粋にシャッフルを組む。
    def applyPicks(remaining: List[Kind], picks: List[Int32]): List[Kind] =
        match picks {
            case Nil        => remaining
            case j :: rest  =>
                let chosen = List.drop(j, remaining) |> List.head;
                match chosen {
                    case None    => remaining
                    case Some(k) =>
                        let without = List.append(List.take(j, remaining), List.drop(j + 1, remaining));
                        k :: applyPicks(without, rest)
                }
        }

    // ══════════════════════════════════════════════════════
    // 毎フレームの更新（重力・接地・固定・ライン消去・演出）
    // ══════════════════════════════════════════════════════

    /// 毎フレームの更新。phase ごとに分岐する。
    ///   Playing  … 重力で落とし、接地していれば固定を待つ。
    ///   Clearing … 演出の時間を進め、終わったら実消去して次のミノへ。
    ///   GameOver … 何もしない（Space/Enter の restart 待ち）。
    /// softDrop は下キーが押されているか（Controls が渡す）。
    /// 時計（t）だけは場面を問わず進める — 手が止まっている間も紙の繊維が流れ、
    /// 操作中のミノの縁が息をする（画面を完全に静止させないため）。
    pub def step(softDrop: Bool, dt: Float64, w: World): World =
        let ticked = { t = w#t + dt | w };
        match w#phase {
            case Phase.Playing  => tickPlaying(softDrop, dt, ticked)
            case Phase.Clearing => tickClearing(dt, ticked)
            case Phase.GameOver => ticked
        }

    /// Playing の 1 フレーム: 重力を積んで 1 行落とし、落ちられなければ接地として固定を待つ。
    def tickPlaying(softDrop: Bool, dt: Float64, w: World): World =
        let speed = if (softDrop) RulesDoc.rec(w#doc)#softDropFactor else 1.0;
        let timer = w#gravityTimer + dt * speed;
        // gravityInterval を超えた分だけ落下を試みる（1 フレームに 1 行で十分・素直に）。
        let dropped =
            if (timer >= RulesDoc.rec(w#doc)#gravityInterval) {
                let (w1, moved) = tryMove(0, 1, w);
                if (moved)
                    { gravityTimer = 0.0, grounded = false | w1 }
                else
                    { gravityTimer = 0.0, grounded = true | w1 }   // 直下が塞がっている = 接地
            } else
                { gravityTimer = timer | w };
        // 接地している間だけ lockTimer を積む。lockDelay 到達 or リセット上限で固定する。
        if (dropped#grounded) {
            let lockTimer = dropped#lockTimer + dt;
            if (lockTimer >= RulesDoc.rec(dropped#doc)#lockDelay or dropped#lockResets >= RulesDoc.rec(dropped#doc)#maxLockResets)
                lockPiece(dropped)
            else
                { lockTimer = lockTimer | dropped }
        } else
            dropped

    /// いまのミノを盤に固定し、揃った行を判定する。
    /// 揃った行があれば演出へ（実消去はまだしない）。無ければ即、次のミノを涌かせる。
    /// [遷移: Playing→Clearing]（揃ったとき）
    def lockPiece(w: World): World =
        let placed = piecesCells(w#current)
            |> List.foldLeft((b, cell) -> Map.insert(cell, w#current#kind, b), w#board);
        let full = fullRows(placed);
        if (List.isEmpty(full))
            spawnNext({ board = placed | w })
        else
            { board = placed, phase = Phase.Clearing, clearRows = full, clearTimer = 0.0 | w }

    /// すべての列が埋まっている行の番号（上から下へ）。ライン消しの検出。
    pub def fullRows(board: Map[Cell, Kind]): List[Int32] =
        List.range(0, rows()) |> List.filter(r ->
            List.range(0, cols()) |> List.forAll(c -> Map.memberOf((c, r), board)))

    /// Clearing の 1 フレーム: 演出の時間を進め、clearDuration を超えたら実消去して次のミノへ。
    /// [遷移: Clearing→Playing]
    def tickClearing(dt: Float64, w: World): World =
        let t = w#clearTimer + dt;
        if (t >= RulesDoc.rec(w#doc)#clearDuration) {
            let cleared = clearLines(w#clearRows, w#board);
            let gained = RulesDoc.scoreFor(List.length(w#clearRows), w#doc);
            spawnNext({ board = cleared, phase = Phase.Playing, clearRows = Nil, clearTimer = 0.0,
                    score = w#score + gained, lines = w#lines + List.length(w#clearRows) | w })
        } else
            { clearTimer = t | w }

    /// 指定の行を盤から消し、その上の行を消えた分だけ下へ詰める（純粋）。
    /// 各セルの新しい row = 元の row + 「自分より下で消えた行の数」。
    pub def clearLines(clearRows: List[Int32], board: Map[Cell, Kind]): Map[Cell, Kind] =
        Map.foldLeftWithKey((acc, cell, kind) -> {
            let (c, r) = cell;
            if (List.memberOf(r, clearRows))
                acc                                        // 消える行のセルは捨てる
            else {
                let below = List.count(cr -> cr > r, clearRows);   // 自分より下で消えた行数
                Map.insert((c, r + below), kind, acc)
            }
        }, Map.empty(), board)

    // ══════════════════════════════════════════════════════
    // プレイヤーの操作（Controls が呼ぶ）
    // ══════════════════════════════════════════════════════

    /// 左右に 1 マス動かす（Playing のときだけ）。設置面ねばりは tryMove の中で効く。
    pub def moveLeft(w: World): World = if (isPlaying(w)) fst(tryMove(-1, 0, w)) else w
    pub def moveRight(w: World): World = if (isPlaying(w)) fst(tryMove(1, 0, w)) else w

    /// 回転（cw = 時計回り / ccw = 反時計回り）。ウォールキック込みは tryRotate の中。
    pub def rotateCW(w: World): World = if (isPlaying(w)) fst(tryRotate(1, w)) else w
    pub def rotateCCW(w: World): World = if (isPlaying(w)) fst(tryRotate(-1, w)) else w

    /// ハードドロップ（Space）: 落ちられる限り一気に落とし、その場で固定する。
    /// 猶予（lockDelay）を待たず即固定 = テトリスの「叩きつけ」。
    pub def hardDrop(w: World): World =
        if (isPlaying(w)) lockPiece(dropToBottom(w)) else w

    /// これ以上落ちられない所まで current を落とした World（ゴーストと hardDrop が使う）。
    pub def dropToBottom(w: World): World =
        let (w1, moved) = tryMove(0, 1, w);
        if (moved) dropToBottom(w1) else w

    /// GAME OVER から仕切り直す（Space/Enter）。seed を初期へ戻して決定的に始め直す。
    /// 時計は引き継ぐ（絵の流れを巻き戻さない）。[遷移: GameOver→Playing]
    pub def restart(w: World): World =
        { t = w#t | initial({ doc = w#doc, theme = w#theme, shader = w#shader }) }

    def isPlaying(w: World): Bool = w#phase == Phase.Playing

    // ══════════════════════════════════════════════════════
    // Doc の差し替え（保存即反映）と 表示中の名乗り
    // ══════════════════════════════════════════════════════

    /// 手触り・収支の Doc を差し替える（落下速度や得点をその場で反映）。
    pub def withRules(doc: RulesDoc.Doc, w: World): World = { doc = doc | w }

    /// 色の Doc を差し替える。
    pub def withTheme(theme: ThemeDoc.Doc, w: World): World = { theme = theme | w }

    /// 紙の面を差し替える。
    pub def withShader(shader: ShaderDoc.Spec, w: World): World = { shader = shader | w }

}
