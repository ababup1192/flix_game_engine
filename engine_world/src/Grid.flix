// Grid — 正方タイルの「何列目・何行目」と画面上のピクセル位置を相互に変換する。
// マス目とピクセルの行き来を一箇所にまとめるので、盤面の描画や当たり判定のたびに
// 同じ掛け算・割り算を書かずに済む。
// 利用例: マスの中心にキャラを置く / クリックした点がどのマスかを求める / 隣のマスを取る。
// 注意: 知っているのはタイルの大きさだけで、盤が画面のどこにあるかは扱わない（位置合わせは呼び側）。
// セル座標の規約は 2 つある: 左上原点・tileSize 割りの系（cellAt / cellOf）と、
// セル中心が整数・境界 ±0.5 の系（cellAtCentered — GridRay / WallFaces の疑似 3D 側）。

pub mod Grid {

    /// `cell` の中心のピクセル位置。原点 (0, 0) がセル (0, 0) の左上であるグリッド上で。
    /// セル (c, r) は x が [c*tileSize, (c+1)*tileSize) に広がるので、中心は半タイル分
    /// ずれる。
    pub def cellCenter(tileSize: Float64, cell: (Int32, Int32)): Vec2.Vec2 =
        let (col, row) = cell;
        { x = (Int32.toFloat64(col) + 0.5) * tileSize,
          y = (Int32.toFloat64(row) + 0.5) * tileSize }

    /// ピクセル位置がどのセルに入るか — 中心に限らずセル内の任意の点について `cellCenter`
    /// の逆。floor を使うので、原点の左や上の点は 0 方向へ丸めず負のセルに入る。
    pub def cellOf(tileSize: Float64, pos: Vec2.Vec2): (Int32, Int32) =
        (floorDiv(pos#x, tileSize), floorDiv(pos#y, tileSize))

    /// `cell` から方向 `d` へ 1 歩進んだセル。
    pub def neighbor(cell: (Int32, Int32), d: Dir4.Dir4): (Int32, Int32) =
        let (col, row) = cell;
        let (dx, dy) = Dir4.delta(d);
        (col + dx, row + dy)

    /// `cell` が `cols` x `rows` のグリッド内にあるか: 列が [0, cols)、行が [0, rows)。
    /// 列も行も持たないグリッドは何も含まない。
    pub def inRect(cell: (Int32, Int32), cols: Int32, rows: Int32): Bool =
        let (col, row) = cell;
        col >= 0 and col < cols and row >= 0 and row < rows

    /// 浮動小数の除算を、含まれる整数セル添字へ切り下げる。
    def floorDiv(value: Float64, tileSize: Float64): Int32 =
        Num.floorInt(value / tileSize)

    /// セル座標を名前付き成分で持つための record 型。列 = `x`、行 = `y`。tuple 版
    /// `(col, row)` と同じ値を表すが、境界で `(a, b)` へ組み替えずそのまま渡せる。
    pub type alias Cell = { x = Int32, y = Int32 }

    /// `cellCenter` の record 版。セルを `{x, y}` で受け取り中心のピクセル位置を返す。
    /// tuple ↔ record の変換を呼び側に書かせないための入口で、値は tuple 版と一致する。
    pub def cellCenterOf(tileSize: Float64, cell: Cell): Vec2.Vec2 =
        cellCenter(tileSize, (cell#x, cell#y))

    /// `cellOf` の record 版。ピクセル位置がどのセルに入るかを `{x, y}` で返す。floor で
    /// 丸めるので原点の左・上の点は負のセルに入る（tuple 版と同じ）。`cellCenterOf` の逆。
    /// 名前が `cellOfOf` にならないよう、他の record 版（`cellCenterOf` 等）の "Of" 付け足しでは
    /// なく `cellAt` と別綴りにする（`Of` 自体が「〜が入るセル」を表す接尾で二重になるため）。
    pub def cellAt(tileSize: Float64, pos: Vec2.Vec2): Cell =
        let (col, row) = cellOf(tileSize, pos);
        { x = col, y = row }

    /// 「セル中心が整数・境界が ±0.5」の座標系（1 マス = 1.0）で、世界点 `p` が属するセル。
    /// 境界 ±0.5 ちょうどの点は + 側のマスに属する（floor(p + 0.5) — どこから呼んでも
    /// 同じタイブレークになるよう式ごとここに一本化）。
    /// `cellAt` とは座標系が別物: あちらは「原点 (0,0) がセル (0,0) の左上」で tileSize で
    /// 割る系、こちらはセル (0,0) の中心が点 (0,0) に来る系（GridRay / WallFaces が使う）。
    pub def cellAtCentered(p: Vec2.Vec2): Cell =
        { x = Num.floorInt(p#x + 0.5), y = Num.floorInt(p#y + 0.5) }

    /// 文字の並び（rows）の大きさ。`cols` は**一番長い行**の文字数で、短い行は右が
    /// 空いているものとして扱う（末尾の空白を書かなくてよい）。
    /// 盤・面・部屋・ドット絵のコマなど、テキストで書いた格子は全部この形で測る。
    pub def dimsOfRows(rows: List[String]): { cols = Int32, rows = Int32 } =
        { cols = rows |> List.foldLeft((acc, row) -> Int32.max(acc, String.length(row)), 0),
          rows = List.length(rows) }

    /// 文字の並びを「(セル, その文字)」の列にほどく。並びは上の行から、行の中は左から
    /// （毎回同じ順なので、畳み込んだ結果が作り直しでもぶれない）。
    /// 短い行はそこで終わる — 空きを埋める文字は呼び側が決める（意味づけはゲームの仕事）。
    pub def cellsOfRows(rows: List[String]): List[(Cell, Char)] =
        rows
            |> List.zipWithIndex
            |> List.flatMap(rowPair -> {
                let (row, text) = rowPair;
                text
                    |> String.toList
                    |> List.zipWithIndex
                    |> List.map(colPair -> {
                        let (col, ch) = colPair;
                        (({ x = col, y = row }: Cell), ch)
                    })
            })

    /// `neighbor` の record 版。`cell` から方向 `d` へ 1 歩進んだセルを `{x, y}` で返す。
    pub def neighborOf(cell: Cell, d: Dir4.Dir4): Cell =
        let (col, row) = neighbor((cell#x, cell#y), d);
        { x = col, y = row }

    /// `inRect` の record 版。`cell` が `cols` x `rows`（列 [0,cols)・行 [0,rows)）の内側か。
    pub def inRectOf(cell: Cell, cols: Int32, rows: Int32): Bool =
        inRect((cell#x, cell#y), cols, rows)

    /// 見えている矩形に重なるマスを並べる（盤の外は含めない）。
    ///
    /// margin は「矩形の外だけれど見るマス」の余分。上へ伸びる木や屋根は、画面の下の外に
    /// 立っていても葉が画面の中へ差し込むので、下側を余分に見ないと縁で消える。
    ///
    /// 並びは上の行から、行の中は左から。1 フレームの仕事を画面ぶんに抑える口なので、
    /// 盤が広くなっても組む量は増えない。
    pub def cellsIn(spec: { tileSize = Float64, area = { position = Vec2.Vec2, size = Vec2.Vec2 },
                            cols = Int32, rows = Int32,
                            margin = { left = Int32, top = Int32,
                                       right = Int32, bottom = Int32 } }): List[Cell] =
        let t = spec#tileSize;
        if (t <= 0.0 or spec#cols <= 0 or spec#rows <= 0) Nil
        else {
            let a = spec#area;
            let m = spec#margin;
            let c0 = Int32.max(0, floorTo(a#position#x / t) - m#left);
            let r0 = Int32.max(0, floorTo(a#position#y / t) - m#top);
            let c1 = Int32.min(spec#cols - 1, floorTo((a#position#x + a#size#x) / t) + m#right);
            let r1 = Int32.min(spec#rows - 1, floorTo((a#position#y + a#size#y) / t) + m#bottom);
            forM (r <- List.range(r0, r1 + 1); c <- List.range(c0, c1 + 1))
                yield ({ x = c, y = r }: Cell)
        }

    /// 余分を見ない margin（見えている矩形にちょうど重なるマスだけ）。
    pub def noMargin(): { left = Int32, top = Int32, right = Int32, bottom = Int32 } =
        { left = 0, top = 0, right = 0, bottom = 0 }

    def floorTo(v: Float64): Int32 =
        if (not Float64.isFinite(v)) 0
        else Num.floorInt(v)
}
