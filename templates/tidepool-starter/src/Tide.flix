// Tide — 水の決まり（抜け口の高さ d と、1 手ごとの水位の更新）。どれも純粋な関数。
// 水位の表 Water は盤の中の全マスを持ち、w(c) ≥ h(c)。w(c) > h(c) のマスが沈んでいる。
mod Tide {

    use Board.Cell

    /// マス → 水面の高さ（盤の中の全マス）。
    pub type alias Water = Map[Cell, Int32]

    /// 乾いた盤（w = h）。
    pub def dry(b: Board.Board): Water = b#heights

    pub def isSubmerged(cell: Cell, water: Water, b: Board.Board): Bool =
        Map.getWithDefault(cell, 0, water) > Board.heightAt(cell, b)

    /// 抜け口の高さ d(c): 盤の外へ出る道の上の一番高い地面が、一番低くなる道のその高さ。
    /// 小石のマスと、小石に囲まれて外へ出られないマスは入らない（∞）。
    /// 高さ k ごとに「地面が k 以下のマスだけを通って縁から届くマス」を広げ、低い k から先に決める。
    /// WhyNot: 一般の優先度付きキューを使わない。高さは 0..3 の 4 段しかなく、段ごとに広げても全マス 4 回で済む。
    pub def drainHeights(pebbles: Set[Cell], b: Board.Board): Map[Cell, Int32] =
        List.range(0, Board.maxHeight() + 1) |> List.foldRight((k, acc) -> {
            let isOpen = c -> Board.isInside(c, b) and not Set.memberOf(c, pebbles) and Board.heightAt(c, b) <= k;
            let seeds = Board.cells(b) |> List.filter(c -> Board.isEdge(c, b) and isOpen(c));
            reach(isOpen, seeds) |> Set.foldLeft((m, c) -> Map.insert(c, k, m), acc)
        }, Map.empty())

    /// 1 手の後の水位。before は手の前の水位、tide は新しい潮位、pebbles は手の後の小石の位置。
    /// 残る水（抜け口より上はあふれる）と外海を水源にして、高い水位から順に、地面がそれより低い隣へ同じ高さで広げる。
    pub def flow(pebbles: Set[Cell], tide: Int32, before: Water, b: Board.Board): Water =
        let drains = drainHeights(pebbles, b);
        let kept = Board.cells(b) |> List.filterMap(c -> {
            let left = Map.getWithDefault(c, 0, before) |> Int32.min(Map.getWithDefault(c, Int32.maxValue(), drains));
            if (not Set.memberOf(c, pebbles) and left > Board.heightAt(c, b)) Some((c, left)) else None
        });
        let fromSea = Board.cells(b) |> List.filter(c -> Board.isEdge(c, b) and tide > Board.heightAt(c, b)
            and not Set.memberOf(c, pebbles)) |> List.map(c -> (c, tide));
        let sources = List.append(kept, fromSea);
        let levels = sources |> List.map(snd) |> List.distinct |> List.sort |> List.reverse;
        let reached = levels |> List.foldLeft((acc, v) -> {
            let isOpen = c -> Board.isInside(c, b) and not Set.memberOf(c, pebbles)
                and Board.heightAt(c, b) < v and not Map.memberOf(c, acc);
            let seeds = sources |> List.filter(s -> snd(s) == v) |> List.map(fst) |> List.filter(isOpen);
            reach(isOpen, seeds) |> Set.foldLeft((m, c) -> Map.insert(c, v, m), acc)
        }, Map.empty());
        Map.unionWith(Int32.max, reached, b#heights)

    /// 面の初めの水: 乾いた盤から、何も動かさずに満ち引きを 1 周回した後の水（t = 0 の潮位で終わる）。
    pub def initialWater(b: Board.Board): Water =
        cycleOnce(b#pebbles, dry(b), b)

    /// 小石を動かさずに満ち引きを 1 周回す（t = 1, 2, …, len の潮位を順に当てる）。
    pub def cycleOnce(pebbles: Set[Cell], water: Water, b: Board.Board): Water =
        List.range(1, Vector.length(b#cycle) + 1)
            |> List.foldLeft((w, t) -> flow(pebbles, Board.tideAt(t, b), w, b), water)

    /// seeds から isOpen のマスだけを通って届くマス（seeds のうち isOpen の物を含む）。
    def reach(isOpen: Cell -> Bool, seeds: List[Cell]): Set[Cell] =
        spread(isOpen, Set.empty(), seeds |> List.filter(isOpen))

    def spread(isOpen: Cell -> Bool, seen: Set[Cell], todo: List[Cell]): Set[Cell] = match todo {
        case Nil => seen
        case c :: rest =>
            if (Set.memberOf(c, seen)) spread(isOpen, seen, rest)
            else spread(isOpen, Set.insert(c, seen), List.append(Board.neighbors(c) |> List.filter(isOpen), rest))
    }
}
