// Stage — StageDoc の rows(文字格子)を遊べる形に組む。すべて純粋。
//
// ── 文字の対応表(この表が正 — StageDoc の note と揃える)──
//   #  土(硬い)          X  石(硬い)          W  背後壁だけ(通れる)
//   =  一方通行床          ~  動く床(横往復)     !  消える床(点滅)
//   o  コイン              S  バネ                T  松明
//   c  チェックポイント    G  ゴール旗            P  開始位置
//   a  歩く敵              b  飛ぶ敵              z  撃つ敵
//   .  空
//
// 格子は不変(コインの取得などの進行は World が集合で覚える — rows は書き換えない)。
// 動く床・敵は「湧き場所」だけここが読み、動きは World / Enemies の仕事。
mod Stage {

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Stage(Rec)

    pub type alias Cell = { x = Int32, y = Int32 }

    /// 動く床 1 枚。cell は左端の休止位置、wTiles = 幅、横に ampTiles 往復する。
    pub type alias Platform = { cell = Cell, wTiles = Int32 }

    pub type alias Rec = {
        name = String,
        kind = String,               // outdoor / cave / tower(空気の選択)
        rows = Vector[Vector[Char]],
        width = Int32,
        height = Int32,
        start = Cell,
        coins = List[Cell],
        springs = List[Cell],
        torches = List[Cell],
        checkpoints = List[Cell],
        goal = Cell,
        platforms = List[Platform],
        enemies = List[(Cell, Enemies.Behavior)]
    }

    pub def rec(st: Stage): Rec = match st { case Stage.Stage(r) => r }

    /// Spec(rows)から Stage を組む。行長の不揃いは短い方に合わせず、
    /// 格子外扱い(charAt が '.' を返す)で吸収する。
    pub def make(spec: StageDoc.Spec): Stage =
        let rows = spec#rows |> List.map(r -> String.toList(r) |> List.toVector) |> List.toVector;
        let height = Vector.length(rows);
        let width = rows |> Vector.foldLeft((acc, r) -> Int32.max(acc, Vector.length(r)), 0);
        let cells = Grid.cellsOfRows(spec#rows);
        let find = byChar(cells);
        Stage.Stage({ name = spec#name, kind = spec#kind, rows = rows,
          width = width, height = height,
          start = List.head(find('P')) |> Option.getWithDefault({ x = 2, y = 2 }),
          coins = find('o'),
          springs = find('S'),
          torches = find('T'),
          checkpoints = find('c'),
          goal = List.head(find('G'))
              |> Option.getWithDefault({ x = width - 2, y = 2 }),
          platforms = platformsOf(find('~')),
          enemies = cells |> List.filterMap(entry -> {
              let (cell, ch) = entry;
              behaviorOf(ch) |> Option.map(b -> (cell, b))
          }) })

    /// 敵の文字 → 振る舞いの初期値。知らない文字は湧かさない(fail-open)。
    /// 飛ぶ敵の揺れの中心は Enemies.make が湧いた位置から入れる。
    def behaviorOf(ch: Char): Option[Enemies.Behavior] =
        match ch {
            case 'a' => Some(Enemies.Behavior.Walking(0.0))
            case 'b' => Some(Enemies.Behavior.Flying(0.0))
            case 'z' => Some(Enemies.Behavior.Shooting(0.0))
            case _   => None
        }

    /// 格子の 1 文字。外は '.'(空)— 落下死はステージ最下段より下で World が判定する。
    pub def charAt(st: Stage, x: Int32, y: Int32): Char =
        match Vector.nth(y, rec(st)#rows) {
            case Some(row) => Vector.nth(x, row) |> Option.getWithDefault('.')
            case None      => '.'
        }

    /// 全方向に硬いか。左右端の外も硬い(横に落ちない)。
    pub def solidAt(st: Stage, x: Int32, y: Int32): Bool =
        if (x < 0 or x >= rec(st)#width) true
        else {
            let ch = charAt(st, x, y);
            ch == '#' or ch == 'X'
        }

    /// 一方通行の床か(= のマス)。
    pub def oneWayAt(st: Stage, x: Int32, y: Int32): Bool =
        charAt(st, x, y) == '='

    /// 消える床のマスか(点滅の位相は World が時刻から決める)。
    pub def blinkAt(st: Stage, x: Int32, y: Int32): Bool =
        charAt(st, x, y) == '!'

    /// 背後壁を敷くマスか。cave の通れるマス(W と、ギミックが置かれた空洞)に敷く。
    pub def wallAt(st: Stage, x: Int32, y: Int32): Bool =
        if (rec(st)#kind != "cave" or solidAt(st, x, y)) false
        else {
            let ch = charAt(st, x, y);
            if (ch == '.') hasNeighborTunnel(st, x, y) else true
        }

    /// '.' でも周囲(自分含む 3×3)に W があれば洞窟の空洞とみなす —
    /// rows の W の塗り忘れで壁に穴が開かないための救済。
    def hasNeighborTunnel(st: Stage, x: Int32, y: Int32): Bool =
        List.range(-1, 2) |> List.exists(dy ->
            List.range(-1, 2) |> List.exists(dx ->
                charAt(st, x + dx, y + dy) == 'W'))

    /// マスの中心のワールド px。
    pub def centerOf(cell: Cell): Vec2.Vec2 =
        let ts = Physics.tileSize();
        { x = (Int32.toFloat64(cell#x) + 0.5) * ts,
          y = (Int32.toFloat64(cell#y) + 0.5) * ts }

    /// ステージ全体のワールド矩形(px)。カメラの見せる範囲。
    pub def worldRect(st: Stage): Rect2.Rect2 =
        let ts = Physics.tileSize();
        let s = rec(st);
        { position = { x = 0.0, y = 0.0 },
          size = { x = Int32.toFloat64(s#width) * ts,
                   y = Int32.toFloat64(s#height) * ts } }

    // ── 抽出 ──

    /// 文字 → その文字のマス(上の行から・行の中は左から)を引く関数。
    /// ほどいた格子を受け取って表に振り分けるので、文字の種類が増えても表は 1 枚のまま。
    def byChar(cells: List[(Cell, Char)]): Char -> List[Cell] =
        let table = cells
            |> List.foldLeft((acc, e) -> {
                let (cell, ch) = e;
                Map.insertWith((newL, oldL) -> newL ::: oldL, ch, cell :: Nil, acc)
            }, Map.empty())
            |> Map.map(List.reverse);
        ch -> Map.get(ch, table) |> Option.getWithDefault(Nil)

    /// 連続した '~' の水平の並びを 1 枚の動く床にまとめる(左端セル + 幅)。
    def platformsOf(tildes: List[Cell]): List[Platform] =
        let keys = tildes |> List.map(c -> (c#x, c#y));
        let isT = (x, y) -> List.memberOf((x, y), keys);
        tildes
            |> List.filter(c -> not isT(c#x - 1, c#y))   // 各並びの左端だけ
            |> List.map(c -> { cell = c, wTiles = runLength(isT, c#x, c#y, 0) })

    def runLength(isT: (Int32, Int32) -> Bool, x: Int32, y: Int32, acc: Int32): Int32 =
        if (isT(x + acc, y)) runLength(isT, x, y, acc + 1) else acc
}
