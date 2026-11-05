// SpatialGrid — 位置の列を升へ 1 回振り分け、ある点の近くの物だけを引く格子（純粋）。
// 全員どうしを比べる二乗の形を、近くの升だけを見る形へ置き換える。持つのは位置と番号だけで、
// 半径や押し合いなどの規則は呼ぶ側に残す。2D でも 3D でも使えるので引数名は x, y で、3D は足元の平面の (x, z) を渡す。
//
// 使いどころ: 毎コマ位置が変わる群れの押し合い・近くの敵を数える・範囲の当たり。
// 毎コマ作り直す格子は World に置かない（開発時の履歴がコマごとの格子を全部抱える）。その場の let で持つ。
pub mod SpatialGrid {

    /// 振り分けた格子。xs・ys = 入れた順の位置・starts[c] から starts[c + 1] の手前までが order の中の升 c の範囲・
    /// order = 升の順に並べた番号（行が外側、升の中は入れた順）・cols × rows = 升の数・(minX, minY) = 升の原点・size = 升の一辺。
    enum GridData {
        case GridData(Vector[Float64], Vector[Float64], Vector[Int32], Vector[Int32], Int32, Int32, Float64, Float64, Float64)
    }

    /// 近くの物を引く格子。`build` か `buildBy` で作る。
    pub type alias SpatialGrid = GridData

    /// 位置の列から作る。番号は `xs`・`ys` の並びの位置。`minCellSize` は升の一辺の下限で、
    /// 物が広く散らばると升の数が物の数に見合う所まで一辺が広がる。ふつうは引く半径の 2 倍くらいを渡す。
    /// `xs` と `ys` の長さが違うのは呼ぶ側の誤り（`bug!`）。
    pub def build(minCellSize: Float64, xs: Vector[Float64], ys: Vector[Float64]): SpatialGrid =
        if (Vector.length(xs) != Vector.length(ys)) bug!("SpatialGrid.build: xs と ys の長さが違う")
        else assemble(minCellSize, xs, ys)

    /// 物の列から作る。番号は `items` の並びの位置。`posOf` は 1 つにつき 1 回だけ呼ぶ。
    /// レコードの列から位置を引くなら、列を 2 本作って `build` へ渡すよりこちらが速い。
    pub def buildBy(minCellSize: Float64, items: List[a], posOf: a -> (Float64, Float64)): SpatialGrid = region rc {
        let n = List.length(items);
        let xs = Array.repeat(rc, n, 0.0);
        let ys = Array.repeat(rc, n, 0.0);
        items |> List.forEachWithIndex((i, item) -> {
            let (x, y) = posOf(item);
            Array.put(x, i, xs);
            Array.put(y, i, ys)
        });
        assemble(minCellSize, Array.toVector(xs), Array.toVector(ys))
    }

    /// (x, y) から `radius` 以内（ちょうど `radius` の物も入る）の物を畳む。`f` は (蓄積, 番号, その物の x, その物の y) を受ける。
    /// 自分も番号で通るので、飛ばすかどうかは `f` が決める。回す順は行が外側、升の中は入れた順で、同じ格子なら毎回同じ。
    /// `radius` が負なら何も通らない。升の一辺より大きな `radius` も引ける（見る升が増えるだけ）。
    ///
    /// `f` は呼ぶ所にその場のラムダで書く。変数に入れて持ち回った関数はコンパイラが内側のループへ畳み込めず、
    /// 1 回の呼び出しごとに値を箱へ詰めるので、別の `f` も同じ道を通る時に最悪 2.5 倍くらい遅くなる。
    pub def foldNearIndex(grid: SpatialGrid, x: Float64, y: Float64, radius: Float64, init: b, f: (b, Int32, Float64, Float64) -> b \ ef): b \ ef =
        match grid {
            case GridData.GridData(xs, ys, starts, order, cols, rows, minX, minY, size) =>
                if (radius < 0.0) init
                else {
                    let firstCol = cellIndexOf(minX, size, cols, x - radius);
                    let lastCol = cellIndexOf(minX, size, cols, x + radius);
                    let firstRow = cellIndexOf(minY, size, rows, y - radius);
                    let lastRow = cellIndexOf(minY, size, rows, y + radius);
                    foldRows(xs, ys, starts, order, cols, firstCol, lastCol, x, y, radius * radius, firstRow, lastRow, init, f)
                }
        }

    /// 升の一辺: `minCellSize` を下限に、升の数が物の数の 4 倍 + 1024 に見合う所まで広げた値。
    // WhyNot: 下限だけで一辺を決めない — 遠くに 1 体はぐれると升の数が広さに比例して膨らみ、物の数と関係なく大きな配列を作ることになる。
    // WhyNot: 面積だけで広げない — 一直線に並ぶと面積が 0 になり、長い方の辺の升の数が抑えられない。
    def cellSizeOf(minCellSize: Float64, n: Int32, width: Float64, depth: Float64): Float64 =
        let budget = Int32.toFloat64(4 * n + 1024);
        let spread = Float64.max(Num.sqrt(width * depth / budget), Float64.max(width, depth) / budget);
        Float64.max(Float64.max(0.01, minCellSize), spread)

    def assemble(minCellSize: Float64, xs: Vector[Float64], ys: Vector[Float64]): SpatialGrid = region rc {
        let n = Vector.length(xs);
        let minX = if (n == 0) 0.0 else Vector.foldLeft(Float64.min, Float64.maxValue(), xs);
        let minY = if (n == 0) 0.0 else Vector.foldLeft(Float64.min, Float64.maxValue(), ys);
        let width = if (n == 0) 0.0 else Vector.foldLeft(Float64.max, Float64.minValue(), xs) - minX;
        let depth = if (n == 0) 0.0 else Vector.foldLeft(Float64.max, Float64.minValue(), ys) - minY;
        let size = cellSizeOf(minCellSize, n, width, depth);
        let cols = Num.floorInt(width / size) + 1;
        let rows = Num.floorInt(depth / size) + 1;
        let starts = Array.repeat(rc, cols * rows + 1, 0);
        let cells = Array.repeat(rc, n, 0);
        countCells(xs, ys, minX, minY, size, cols, rows, cells, starts, 0, n);
        sumUp(starts, 1);
        let cursor = Array.copyOfRange(rc, 0, cols * rows, starts);
        let order = Array.repeat(rc, n, 0);
        placeOrder(cells, cursor, order, 0, n);
        GridData.GridData(xs, ys, Array.toVector(starts), Array.toVector(order), cols, rows, minX, minY, size)
    }

    /// 座標 `value` の入る升の列（行）の番号。格子の外は端の升へ寄せる。
    // WhyNot: Num.floorInt に任せて後で端へ寄せない — Int32 に収まらない大きさは 0 になるので、とても大きな半径で見る升が 0 列目だけになる。
    def cellIndexOf(origin: Float64, size: Float64, count: Int32, value: Float64): Int32 =
        let at = (value - origin) / size;
        if (at <= 0.0) 0
        else if (at >= Int32.toFloat64(count)) count - 1
        else Num.clampInt(0, count - 1, Num.floorInt(at))

    /// 物 i から n の手前までの升を cells へ書き、升ごとの数を starts の 1 つ後ろへ足す。
    def countCells(xs: Vector[Float64], ys: Vector[Float64], minX: Float64, minY: Float64, size: Float64, cols: Int32, rows: Int32,
                   cells: Array[Int32, r], starts: Array[Int32, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            let cell = cellIndexOf(minY, size, rows, Vector.get(i, ys)) * cols + cellIndexOf(minX, size, cols, Vector.get(i, xs));
            Array.put(cell, i, cells);
            Array.put(Array.get(cell + 1, starts) + 1, cell + 1, starts);
            countCells(xs, ys, minX, minY, size, cols, rows, cells, starts, i + 1, n)
        }

    /// 数を頭から足し込んで、升ごとの始まりにする。
    def sumUp(starts: Array[Int32, r], cell: Int32): Unit \ r =
        if (cell >= Array.length(starts)) ()
        else {
            Array.put(Array.get(cell, starts) + Array.get(cell - 1, starts), cell, starts);
            sumUp(starts, cell + 1)
        }

    /// 物を入れた順に、自分の升の次の空きへ置く。
    def placeOrder(cells: Array[Int32, r], cursor: Array[Int32, r], order: Array[Int32, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            let cell = Array.get(i, cells);
            let at = Array.get(cell, cursor);
            Array.put(i, at, order);
            Array.put(at + 1, cell, cursor);
            placeOrder(cells, cursor, order, i + 1, n)
        }

    /// 行 row から lastRow までを畳む。同じ行の隣り合う升は order の上で続いているので、1 行を 1 区間で回す。
    // WhyNot: 引数をレコードに束ねない — 内側のループで欄を読むたびに名前で探すことになる。
    def foldRows(xs: Vector[Float64], ys: Vector[Float64], starts: Vector[Int32], order: Vector[Int32], cols: Int32, firstCol: Int32, lastCol: Int32,
                 x: Float64, y: Float64, radiusSquared: Float64, row: Int32, lastRow: Int32, acc: b, f: (b, Int32, Float64, Float64) -> b \ ef): b \ ef =
        if (row > lastRow) acc
        else {
            let first = Vector.get(row * cols + firstCol, starts);
            let end = Vector.get(row * cols + lastCol + 1, starts);
            foldRows(xs, ys, starts, order, cols, firstCol, lastCol, x, y, radiusSquared, row + 1, lastRow,
                     foldRange(xs, ys, order, x, y, radiusSquared, first, end, acc, f), f)
        }

    /// order の k から end の手前までのうち、半径の中の物を畳む。
    // WhyNot: 升の順に並べた位置の写しを持って順に読まない — 番号の使い所が 1 つになると Flix の最適化の結果が変わり、順に読む得より損が大きく、測って 2 割遅かった。
    def foldRange(xs: Vector[Float64], ys: Vector[Float64], order: Vector[Int32], x: Float64, y: Float64, radiusSquared: Float64,
                  k: Int32, end: Int32, acc: b, f: (b, Int32, Float64, Float64) -> b \ ef): b \ ef =
        if (k >= end) acc
        else {
            let index = Vector.get(k, order);
            let otherX = Vector.get(index, xs);
            let otherY = Vector.get(index, ys);
            let dx = x - otherX;
            let dy = y - otherY;
            if (dx * dx + dy * dy <= radiusSquared) foldRange(xs, ys, order, x, y, radiusSquared, k + 1, end, f(acc, index, otherX, otherY), f)
            else foldRange(xs, ys, order, x, y, radiusSquared, k + 1, end, acc, f)
        }
}
