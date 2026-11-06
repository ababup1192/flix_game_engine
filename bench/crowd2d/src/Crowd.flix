// Crowd — 敵の群れの 1 コマの規則。動きは毎コマ決まった量で、dt を読まない。
mod Crowd {
    use fge::{Num, SpatialGrid}

    pub enum NearSearch with Eq, ToString {
        case ScanAll,
        case Grid
    }

    /// xs・ys = 敵の位置・frame = 進めたコマ数・nearPairs = 前のコマで半径の中に見つけた相手の延べ数。
    pub type alias Crowd = { xs = Vector[Float64], ys = Vector[Float64], frame = Int32, nearPairs = Int32 }

    pub def counts(): List[Int32] = 100 :: 300 :: 1000 :: 3000 :: Nil

    pub def fieldWidth(): Float64 = 640.0

    pub def fieldHeight(): Float64 = 360.0

    def nearRadius(): Float64 = 12.0

    def gridCellSize(): Float64 = 2.0 * nearRadius()

    def chaseSpeed(): Float64 = 1.0

    def pushStrength(): Float64 = 1.5

    /// 位置は番号から決める。
    // WhyNot: 乱数を使わない — 探し方どうしで同じ群れを比べられなくなる。
    pub def start(n: Int32): Crowd =
        let spread = (rate, size) -> Vector.range(0, n) |> Vector.map(i -> size * fract(Int32.toFloat64(i) * rate));
        { xs = spread(0.7548776662, fieldWidth()), ys = spread(0.5698402910, fieldHeight()), frame = 0, nearPairs = 0 }

    def fract(x: Float64): Float64 = x - Float64.floor(x)

    pub def targetX(frame: Int32): Float64 = fieldWidth() / 2.0 + 200.0 * Num.cos(Int32.toFloat64(frame) * 0.01)

    pub def targetY(frame: Int32): Float64 = fieldHeight() / 2.0 + 110.0 * Num.sin(Int32.toFloat64(frame) * 0.013)

    pub def advance(search: NearSearch, crowd: Crowd): Crowd = region rc {
        let xs = crowd#xs;
        let ys = crowd#ys;
        let n = Vector.length(xs);
        let tx = targetX(crowd#frame);
        let ty = targetY(crowd#frame);
        let nextXs = Array.repeat(rc, n, 0.0);
        let nextYs = Array.repeat(rc, n, 0.0);
        let nearPairs = match search {
            case NearSearch.ScanAll => moveByScan(xs, ys, tx, ty, nextXs, nextYs, 0, n, 0)
            case NearSearch.Grid    => moveByGrid(buildGrid(xs, ys), xs, ys, tx, ty, nextXs, nextYs, 0, n, 0)
        };
        { xs = Array.toVector(nextXs), ys = Array.toVector(nextYs), frame = crowd#frame + 1, nearPairs = nearPairs }
    }

    pub def buildGrid(xs: Vector[Float64], ys: Vector[Float64]): SpatialGrid.SpatialGrid =
        SpatialGrid.build(gridCellSize(), xs, ys)

    // WhyNot: 2 つの探し方を 1 本の関数で受けて f を変数で回さない — SpatialGrid.foldNearIndex の f はその場のラムダでないと畳み込まれない。
    def moveByGrid(grid: SpatialGrid.SpatialGrid, xs: Vector[Float64], ys: Vector[Float64], tx: Float64, ty: Float64,
                   nextXs: Array[Float64, r], nextYs: Array[Float64, r], i: Int32, n: Int32, nearPairs: Int32): Int32 \ r =
        if (i >= n) nearPairs
        else {
            let x = Vector.get(i, xs);
            let y = Vector.get(i, ys);
            let (near, pushX, pushY) = SpatialGrid.foldNearIndex(grid, x, y, nearRadius(), (0, 0.0, 0.0),
                (acc, j, otherX, otherY) -> addPush(i, x, y, acc, j, otherX, otherY));
            place(i, x, y, tx, ty, pushX, pushY, nextXs, nextYs);
            moveByGrid(grid, xs, ys, tx, ty, nextXs, nextYs, i + 1, n, nearPairs + near)
        }

    def moveByScan(xs: Vector[Float64], ys: Vector[Float64], tx: Float64, ty: Float64,
                   nextXs: Array[Float64, r], nextYs: Array[Float64, r], i: Int32, n: Int32, nearPairs: Int32): Int32 \ r =
        if (i >= n) nearPairs
        else {
            let x = Vector.get(i, xs);
            let y = Vector.get(i, ys);
            let (near, pushX, pushY) = foldAllNear(xs, ys, x, y, nearRadius() * nearRadius(), 0, n, (0, 0.0, 0.0),
                (acc, j, otherX, otherY) -> addPush(i, x, y, acc, j, otherX, otherY));
            place(i, x, y, tx, ty, pushX, pushY, nextXs, nextYs);
            moveByScan(xs, ys, tx, ty, nextXs, nextYs, i + 1, n, nearPairs + near)
        }

    // WhyNot: List やレコードの列で回さない — 比べたいのは探し方の差で、列の読み方の差を混ぜると SpatialGrid の得が大きく見える。
    def foldAllNear(xs: Vector[Float64], ys: Vector[Float64], x: Float64, y: Float64, radiusSquared: Float64,
                    j: Int32, n: Int32, acc: b, f: (b, Int32, Float64, Float64) -> b \ ef): b \ ef =
        if (j >= n) acc
        else {
            let otherX = Vector.get(j, xs);
            let otherY = Vector.get(j, ys);
            let dx = x - otherX;
            let dy = y - otherY;
            if (dx * dx + dy * dy <= radiusSquared) foldAllNear(xs, ys, x, y, radiusSquared, j + 1, n, f(acc, j, otherX, otherY), f)
            else foldAllNear(xs, ys, x, y, radiusSquared, j + 1, n, acc, f)
        }

    /// 相手から離れる向きの力を足す。近いほど強い。
    def addPush(self: Int32, x: Float64, y: Float64, acc: (Int32, Float64, Float64), other: Int32, otherX: Float64, otherY: Float64): (Int32, Float64, Float64) =
        let (near, pushX, pushY) = acc;
        let dx = x - otherX;
        let dy = y - otherY;
        let distance = Num.sqrt(dx * dx + dy * dy);
        if (other == self or distance <= 0.0) acc
        else {
            let strength = (nearRadius() - distance) / (nearRadius() * distance);
            (near + 1, pushX + dx * strength, pushY + dy * strength)
        }

    def place(i: Int32, x: Float64, y: Float64, tx: Float64, ty: Float64, pushX: Float64, pushY: Float64,
              nextXs: Array[Float64, r], nextYs: Array[Float64, r]): Unit \ r =
        let dx = tx - x;
        let dy = ty - y;
        let distance = Float64.max(1.0, Num.sqrt(dx * dx + dy * dy));
        let movedX = x + chaseSpeed() * dx / distance + pushStrength() * pushX;
        let movedY = y + chaseSpeed() * dy / distance + pushStrength() * pushY;
        Array.put(Float64.max(0.0, Float64.min(fieldWidth(), movedX)), i, nextXs);
        Array.put(Float64.max(0.0, Float64.min(fieldHeight(), movedY)), i, nextYs)

    /// 1 体あたりの半径の中の相手の数。
    pub def nearPerEnemy(crowd: Crowd): Float64 =
        Int32.toFloat64(crowd#nearPairs) / Int32.toFloat64(Int32.max(1, Vector.length(crowd#xs)))

    /// 2 つの群れの位置の差の一番大きい物。
    pub def maxPositionGap(a: Crowd, b: Crowd): Float64 =
        let gap = (l, r) -> Vector.zip(l, r) |> Vector.foldLeft((worst, pair) -> Float64.max(worst, Float64.abs(fst(pair) - snd(pair))), 0.0);
        Float64.max(gap(a#xs, b#xs), gap(a#ys, b#ys))
}
