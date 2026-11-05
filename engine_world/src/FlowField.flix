// FlowField — 目的のマスまでの歩数の地図（純粋）。1 回塗って、群れの全員が同じ地図を読んで進む。
// 1 体ずつ探すと 1 体ごとに盤面を塗り直すことになる（50 体で 50 回の探索）。塗るのは地図が古くなった時だけでよい。
// 「どのマスに入れるか」はゲームが述語で渡す。マスは (列, 行) のタプルで Grid・GridSearch と同じ流儀。
//
// 使いどころ: たくさんの敵が同じプレイヤーを追う・出口へ向かって流れる。
// 1 体が 1 歩ずつ探すだけなら Steering で足りる。
pub mod FlowField {

    /// 下るマスの選び方。歩数はどちらでも 4 方向で塗る。
    /// Four = 上下左右。Eight = それに斜めを足す（斜めは両脇のマスが開いている時だけ。壁の角を斜めに抜けない）。
    pub enum Neighbors with Eq, ToString {
        case Four,
        case Eight
    }

    /// 塗った地図。width × height = 塗った広さ・steps = マスの番号（行 × width + 列）→ 歩数（届かないマスは -1）・
    /// next = マスの番号 → 1 歩下るマスの番号（無ければ -1）。
    // WhyNot: 下るマスを読む時に探さない — 地図は数コマに 1 回しか変わらないのに、群れの全員が毎コマ隣のマスを引き直す。
    enum FieldData {
        case FieldData(Int32, Int32, Vector[Int32], Vector[Int32])
    }

    /// 歩数の地図。`build` で塗る。
    pub type alias FlowField = FieldData

    /// まだ塗っていない地図（どのマスも届かない）。
    pub def empty(): FlowField = FieldData.FieldData(0, 0, Vector.empty(), Vector.empty())

    /// `empty` のままの地図か。`build` で塗った地図は、届くマスが無くても false。
    pub def isEmpty(field: FlowField): Bool = match field {
        case FieldData.FieldData(_, _, steps, _) => Vector.isEmpty(steps)
    }

    /// `goals` を 0 歩として、`isOpen` のマスだけを上下左右に通って塗った地図。塗るのは width × height の中だけで、
    /// `opts#maxSteps` 歩より遠いマスは届かない扱い（0 なら `goals` だけ）。開いていないマスや外の `goals` は無視する。
    /// `isOpen` は 1 マスにつき 1 回だけ呼ぶ。
    pub def build(width: Int32, height: Int32, isOpen: (Int32, Int32) -> Bool, goals: List[(Int32, Int32)],
                  opts: { neighbors = Neighbors, maxSteps = Int32 }): FlowField = region rc {
        let cols = Int32.max(0, width);
        let rows = Int32.max(0, height);
        let count = cols * rows;
        let open = Array.repeat(rc, count, false);
        fillOpen(isOpen, cols, open, 0, count);
        let steps = Array.repeat(rc, count, -1);
        let queue = Array.repeat(rc, count, 0);
        let seeded = goals |> List.foldLeft((tail, goal) -> seedGoal(cols, rows, open, steps, queue, goal, tail), 0);
        flood(cols, rows, open, steps, queue, opts#maxSteps, 0, seeded);
        let next = Array.repeat(rc, count, -1);
        let directions = match opts#neighbors {
            case Neighbors.Four  => 4
            case Neighbors.Eight => 8
        };
        fillNext(cols, rows, open, steps, next, directions, 0, count);
        FieldData.FieldData(cols, rows, Array.toVector(steps), Array.toVector(next))
    }

    /// マス `cell` から目的までの歩数（届かないマス・地図の外は None）。
    pub def stepsAt(field: FlowField, cell: (Int32, Int32)): Option[Int32] = match field {
        case FieldData.FieldData(width, height, steps, _) =>
            indexAt(width, height, cell) |> Option.map(i -> Vector.get(i, steps)) |> Option.filter(s -> s >= 0)
    }

    /// `cell` から 1 歩下るマス（今より歩数が小さい隣のうち、一番小さい物）。目的のマス・届かないマス・地図の外は None。
    /// 同じ歩数の隣が複数あれば、上 → 右 → 下 → 左 → 右上 → 右下 → 左下 → 左上の順で先の物を選ぶ。
    pub def downhill(field: FlowField, cell: (Int32, Int32)): Option[(Int32, Int32)] = match field {
        case FieldData.FieldData(width, height, _, next) =>
            indexAt(width, height, cell) |> Option.map(i -> Vector.get(i, next)) |> Option.filter(j -> j >= 0)
                |> Option.map(j -> (Int32.remainder(j, width), j / width))
    }

    def indexAt(width: Int32, height: Int32, cell: (Int32, Int32)): Option[Int32] =
        let (col, row) = cell;
        if (isInside(width, height, col, row)) Some(row * width + col) else None

    def isInside(width: Int32, height: Int32, col: Int32, row: Int32): Bool =
        col >= 0 and row >= 0 and col < width and row < height

    /// 隣の向きの列の d 番目の列のずれ（上・右・下・左・右上・右下・左下・左上）。
    def colOffset(d: Int32): Int32 = match d {
        case 1 => 1
        case 3 => -1
        case 4 => 1
        case 5 => 1
        case 6 => -1
        case 7 => -1
        case _ => 0
    }

    /// 隣の向きの列の d 番目の行のずれ。
    def rowOffset(d: Int32): Int32 = match d {
        case 0 => -1
        case 2 => 1
        case 4 => -1
        case 5 => 1
        case 6 => 1
        case 7 => -1
        case _ => 0
    }

    def fillOpen(isOpen: (Int32, Int32) -> Bool, cols: Int32, open: Array[Bool, r], i: Int32, count: Int32): Unit \ r =
        if (i >= count) ()
        else {
            Array.put(isOpen(Int32.remainder(i, cols), i / cols), i, open);
            fillOpen(isOpen, cols, open, i + 1, count)
        }

    /// 目的のマスを 0 歩で queue の tail へ積み、次の tail を返す。
    def seedGoal(cols: Int32, rows: Int32, open: Array[Bool, r], steps: Array[Int32, r], queue: Array[Int32, r], goal: (Int32, Int32), tail: Int32): Int32 \ r =
        let (col, row) = goal;
        if (isInside(cols, rows, col, row) and Array.get(row * cols + col, open) and Array.get(row * cols + col, steps) < 0) {
            Array.put(0, row * cols + col, steps);
            Array.put(row * cols + col, tail, queue);
            tail + 1
        }
        else tail

    /// queue の head から tail の手前までを幅優先で広げる。
    def flood(cols: Int32, rows: Int32, open: Array[Bool, r], steps: Array[Int32, r], queue: Array[Int32, r], maxSteps: Int32, head: Int32, tail: Int32): Unit \ r =
        if (head >= tail) ()
        else {
            let cell = Array.get(head, queue);
            let reached = Array.get(cell, steps);
            let grown = if (reached >= maxSteps) tail else spread(cols, rows, open, steps, queue, cell, reached + 1, 0, tail);
            flood(cols, rows, open, steps, queue, maxSteps, head + 1, grown)
        }

    /// cell の上下左右（d = 0〜3）の開いたマスのうち、まだ塗っていない物を歩数 reached で塗って積む。
    def spread(cols: Int32, rows: Int32, open: Array[Bool, r], steps: Array[Int32, r], queue: Array[Int32, r], cell: Int32, reached: Int32, d: Int32, tail: Int32): Int32 \ r =
        if (d >= 4) tail
        else {
            let col = Int32.remainder(cell, cols) + colOffset(d);
            let row = cell / cols + rowOffset(d);
            if (isOpenAt(cols, rows, open, col, row) and Array.get(row * cols + col, steps) < 0) {
                Array.put(reached, row * cols + col, steps);
                Array.put(row * cols + col, tail, queue);
                spread(cols, rows, open, steps, queue, cell, reached, d + 1, tail + 1)
            }
            else spread(cols, rows, open, steps, queue, cell, reached, d + 1, tail)
        }

    def isOpenAt(cols: Int32, rows: Int32, open: Array[Bool, r], col: Int32, row: Int32): Bool \ r =
        isInside(cols, rows, col, row) and Array.get(row * cols + col, open)

    /// 斜めなら両脇のマスが開いている時だけ進める。
    def canStep(cols: Int32, rows: Int32, open: Array[Bool, r], col: Int32, row: Int32, d: Int32): Bool \ r =
        d < 4 or (isOpenAt(cols, rows, open, col + colOffset(d), row) and isOpenAt(cols, rows, open, col, row + rowOffset(d)))

    def fillNext(cols: Int32, rows: Int32, open: Array[Bool, r], steps: Array[Int32, r], next: Array[Int32, r], directions: Int32, i: Int32, count: Int32): Unit \ r =
        if (i >= count) ()
        else {
            let here = Array.get(i, steps);
            if (here > 0) Array.put(lowestNeighbor(cols, rows, open, steps, Int32.remainder(i, cols), i / cols, directions, 0, here, -1), i, next) else ();
            fillNext(cols, rows, open, steps, next, directions, i + 1, count)
        }

    /// d 番目から後の向きの隣で、歩数が lowest より小さい物があればその番号、無ければ best。
    def lowestNeighbor(cols: Int32, rows: Int32, open: Array[Bool, r], steps: Array[Int32, r], col: Int32, row: Int32, directions: Int32, d: Int32, lowest: Int32, best: Int32): Int32 \ r =
        if (d >= directions) best
        else {
            let toCol = col + colOffset(d);
            let toRow = row + rowOffset(d);
            let reached = if (isInside(cols, rows, toCol, toRow) and canStep(cols, rows, open, col, row, d)) Array.get(toRow * cols + toCol, steps) else -1;
            if (reached >= 0 and reached < lowest) lowestNeighbor(cols, rows, open, steps, col, row, directions, d + 1, reached, toRow * cols + toCol)
            else lowestNeighbor(cols, rows, open, steps, col, row, directions, d + 1, lowest, best)
        }
}
