// Board — 1 面の盤の値（W×H のマスの地面の高さ・巻き貝・初めの置き物と潮の満ち引きの表）。
// levels の Doc の 2 枚の格子（heights・props）から組む。手ごとに変わる物（ヤドカリ・小石・流木・水）は World.State。
mod Board {

    /// 盤のマス（列, 行）。(0, 0) が左上。
    pub type alias Cell = (Int32, Int32)

    /// 1 面の盤。heights は盤の中の全マスを持つ。cycle は手数 t → 潮位の表（面の物か rules の既定）。
    pub type alias Board = {
        cols = Int32,
        rows = Int32,
        heights = Map[Cell, Int32],
        goal = Cell,
        crab = Cell,
        pebbles = Set[Cell],
        driftwood = Set[Cell],
        cycle = Vector[Int32]
    }

    /// 盤の大きさの上限と、押せる物の数の上限（解く道具の状態の数を抑えるため）。
    def maxCols(): Int32 = 8
    def maxRows(): Int32 = 6
    def maxPushables(): Int32 = 4

    /// 地面の高さの上限（0..3）。
    pub def maxHeight(): Int32 = 3

    /// 2 枚の格子から盤を組む。大きさ・字・ヤドカリと巻き貝の数が規則に合わないときは理由を返す。
    pub def fromRows(cycle: Vector[Int32], heights: List[String], props: List[String]): Result[String, Board] =
        let rows = List.length(heights);
        let cols = List.head(heights) |> Option.map(String.length) |> Option.getWithDefault(0);
        let sameWidth = rowsOfWidth(cols, heights) and rowsOfWidth(cols, props);
        if (rows == 0 or cols == 0 or rows > maxRows() or cols > maxCols())
            Err("盤は 1×1 から ${maxCols()}×${maxRows()} まで（${cols}×${rows}）")
        else if (List.length(props) != rows or not sameWidth)
            Err("heights と props は同じ大きさの長方形にする")
        else if (Vector.isEmpty(cycle))
            Err("cycle が空")
        else {
            let heightCells = charsOf(heights);
            let propCells = charsOf(props);
            let badHeight = heightCells |> List.find(e -> { let (_, ch) = e; not isHeightChar(ch) });
            let badProp = propCells |> List.find(e -> { let (_, ch) = e; not String.contains(substr = Char.toString(ch), ".o=@*") });
            let at = (want: Char) -> propCells |> List.filter(e -> snd(e) == want) |> List.map(fst);
            match (badHeight, badProp, at('@'), at('*')) {
                case (Some((_, ch)), _, _, _) => Err("heights に読めない字 '${ch}'（0〜${maxHeight()}）")
                case (_, Some((_, ch)), _, _) => Err("props に読めない字 '${ch}'（. o = @ *）")
                case (None, None, crab :: Nil, goal :: Nil) =>
                    let pebbles = List.toSet(at('o'));
                    let driftwood = List.toSet(at('='));
                    if (Set.size(pebbles) + Set.size(driftwood) > maxPushables())
                        Err("押せる物（o と =）は ${maxPushables()} つまで")
                    else
                        Ok({ cols = cols, rows = rows, cycle = cycle, goal = goal, crab = crab,
                             pebbles = pebbles, driftwood = driftwood,
                             heights = heightCells |> List.map(e -> { let (c, ch) = e; (c, digitOf(ch)) }) |> List.toMap })
                case _ => Err("ヤドカリ @ と巻き貝 * は 1 つずつ")
            }
        }

    def rowsOfWidth(cols: Int32, rows: List[String]): Bool =
        List.forAll(row -> String.length(row) == cols, rows)

    def isHeightChar(ch: Char): Bool =
        Char.digit(radix = 10, ch) |> Option.exists(n -> n <= maxHeight())

    def digitOf(ch: Char): Int32 = Char.digit(radix = 10, ch) |> Option.getWithDefault(0)

    /// 格子の字をマスごとにほどく。
    def charsOf(rows: List[String]): List[(Cell, Char)] =
        rows |> List.zipWithIndex |> List.flatMap(match (y, row) ->
            String.toList(row) |> List.zipWithIndex |> List.map(match (x, ch) -> ((x, y), ch)))

    pub def isInside(cell: Cell, b: Board): Bool =
        let (x, y) = cell;
        x >= 0 and y >= 0 and x < b#cols and y < b#rows

    /// 盤の縁のマス（外海と隣り合う）。
    pub def isEdge(cell: Cell, b: Board): Bool =
        let (x, y) = cell;
        x == 0 or y == 0 or x == b#cols - 1 or y == b#rows - 1

    /// 地面の高さ。盤の外は 0。
    pub def heightAt(cell: Cell, b: Board): Int32 = Map.getWithDefault(cell, 0, b#heights)

    /// 盤の中の全マス（行の順）。
    pub def cells(b: Board): List[Cell] = Map.keysOf(b#heights) |> Set.toList

    /// 上下左右の隣（盤の外も含む）。
    pub def neighbors(cell: Cell): List[Cell] =
        let (x, y) = cell;
        (x, y - 1) :: (x, y + 1) :: (x - 1, y) :: (x + 1, y) :: Nil

    /// 手数 t の潮位。
    pub def tideAt(t: Int32, b: Board): Int32 =
        Vector.get(Int32.modulo(t, Vector.length(b#cycle)), b#cycle)
}
