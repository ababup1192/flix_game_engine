// PhysicsWorld2d.Internal.Shape — 2D の剛体の形（体の座標・重心が原点）。Collider2d と当たり（Narrowphase）の両方が使う下の層。
// ゲームからは呼ばない（形は Collider2d.circle・box・convex で作る）。
pub mod PhysicsWorld2d.Internal.Shape {

    /// 形。Polygon は重心を原点にした反時計回りの頂点の x・y と、各辺の外向きの法線の x・y。
    // WhyNot: 頂点を Vec2 の列で持たない — 当たりの内側の輪で record の欄を名前で探す重さが乗る。
    pub enum Shape with Eq, ToString {
        case Circle(Float64)
        case Polygon(Vector[Float64], Vector[Float64], Vector[Float64], Vector[Float64])
    }

    pub def circle(radius: Float64): Shape = Shape.Circle(radius)

    pub def box(halfWidth: Float64, halfHeight: Float64): Shape =
        polygonOf(Vector#{-halfWidth, halfWidth, halfWidth, -halfWidth}, Vector#{-halfHeight, -halfHeight, halfHeight, halfHeight})

    /// 点の列の凸包（反時計回り）を、重心を原点へ動かして形にする。返すのは (形, 動かした量)。
    /// 凸包の頂点が 3 つ未満（点が 1 直線に並ぶ）なら None。
    pub def convexHull(points: List[(Float64, Float64)]): Option[(Shape, (Float64, Float64))] =
        let sorted = Sort.sortStableWith(comparePoint, points) |> List.distinct;
        let lower = halfHull(sorted);
        let upper = halfHull(List.reverse(sorted));
        let hull = List.append(List.take(List.length(lower) - 1, lower), List.take(List.length(upper) - 1, upper));
        if (List.length(hull) < 3) None
        else {
            let (cx, cy) = centroidOf(hull);
            let xs = hull |> List.map(p -> fst(p) - cx) |> List.toVector;
            let ys = hull |> List.map(p -> snd(p) - cy) |> List.toVector;
            Some((polygonOf(xs, ys), (cx, cy)))
        }

    def comparePoint(a: (Float64, Float64), b: (Float64, Float64)): Comparison =
        if (fst(a) < fst(b)) Comparison.LessThan else if (fst(a) > fst(b)) Comparison.GreaterThan
        else if (snd(a) < snd(b)) Comparison.LessThan else if (snd(a) > snd(b)) Comparison.GreaterThan
        else Comparison.EqualTo

    /// 並べた点から、左へ曲がる点だけを残した半分の凸包（Andrew の monotone chain）。
    def halfHull(points: List[(Float64, Float64)]): List[(Float64, Float64)] =
        points |> List.foldLeft((stack, p) -> pushTurn(p, stack), Nil) |> List.reverse

    /// 逆順の積み stack に p を足す（右へ曲がる・まっすぐの点は落とす）。
    def pushTurn(p: (Float64, Float64), stack: List[(Float64, Float64)]): List[(Float64, Float64)] = match stack {
        case b :: a :: rest =>
            if (cross(a, b, p) <= 0.0) pushTurn(p, a :: rest) else p :: stack
        case _ => p :: stack
    }

    def cross(o: (Float64, Float64), a: (Float64, Float64), b: (Float64, Float64)): Float64 =
        (fst(a) - fst(o)) * (snd(b) - snd(o)) - (snd(a) - snd(o)) * (fst(b) - fst(o))

    /// 多角形の面の重心。
    def centroidOf(hull: List[(Float64, Float64)]): (Float64, Float64) =
        let v = List.toVector(hull);
        let n = Vector.length(v);
        let (area2, sx, sy) = Vector.range(0, n) |> Vector.foldLeft((acc, i) -> {
            let (a, x, y) = acc;
            let (x1, y1) = Vector.get(i, v);
            let (x2, y2) = Vector.get(Int32.modulo(i + 1, n), v);
            let c = x1 * y2 - x2 * y1;
            (a + c, x + (x1 + x2) * c, y + (y1 + y2) * c)
        }, (0.0, 0.0, 0.0));
        (sx / (3.0 * area2), sy / (3.0 * area2))

    def polygonOf(vx: Vector[Float64], vy: Vector[Float64]): Shape =
        let n = Vector.length(vx);
        let normals = Vector.range(0, n) |> Vector.map(i -> {
            let j = Int32.modulo(i + 1, n);
            let ex = Vector.get(j, vx) - Vector.get(i, vx);
            let ey = Vector.get(j, vy) - Vector.get(i, vy);
            let len = PortableMath.sqrt(ex * ex + ey * ey);
            (ey / len, -ex / len)
        });
        Shape.Polygon(vx, vy, Vector.map(fst, normals), Vector.map(snd, normals))

    /// 体の中心から一番遠い点までの長さ。
    pub def boundingRadius(shape: Shape): Float64 = match shape {
        case Shape.Circle(r) => r
        case Shape.Polygon(xs, ys, _, _) =>
            PortableMath.sqrt(Vector.zip(xs, ys) |> Vector.foldLeft((acc, p) -> Float64.max(acc, fst(p) * fst(p) + snd(p) * snd(p)), 0.0))
    }

    /// (面積, 原点まわりの面積の二次モーメント)。重さと慣性は density を掛けた物。
    pub def areaAndMoment(shape: Shape): (Float64, Float64) = match shape {
        case Shape.Circle(r) =>
            let a = PortableMath.pi() * r * r;
            (a, a * r * r / 2.0)
        case Shape.Polygon(xs, ys, _, _) =>
            let n = Vector.length(xs);
            Vector.range(0, n) |> Vector.foldLeft((acc, i) -> {
                let j = Int32.modulo(i + 1, n);
                let (x1, y1, x2, y2) = (Vector.get(i, xs), Vector.get(i, ys), Vector.get(j, xs), Vector.get(j, ys));
                let c = x1 * y2 - y1 * x2;
                (fst(acc) + c / 2.0, snd(acc) + c * (x1 * x1 + x1 * x2 + x2 * x2 + y1 * y1 + y1 * y2 + y2 * y2) / 12.0)
            }, (0.0, 0.0))
    }

    /// 頂点の数（円は 0）。
    pub def vertexCount(shape: Shape): Int32 = match shape {
        case Shape.Circle(_) => 0
        case Shape.Polygon(xs, _, _, _) => Vector.length(xs)
    }
}
