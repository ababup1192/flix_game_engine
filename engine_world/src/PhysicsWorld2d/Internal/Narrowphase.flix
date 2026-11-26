// PhysicsWorld2d.Internal.Narrowphase — 2 つの形の細かい当たり（接触の点 0〜2 個）と、光線・点の当たり。法線は a から b へ向く。
// 円-円・多角形-円・多角形-多角形（分離軸で一番浅い辺を選び、相手の辺を切り取る。片方の軸で離れたら止める）。
// ゲームからは呼ばない（PhysicsWorld2d の中身）。
pub mod PhysicsWorld2d.Internal.Narrowphase {
    use PhysicsWorld2d.Internal.Shape.Shape

    /// 体の姿勢 (x, y, cos, sin)。
    // WhyNot: record にしない — 組ごとに作って欄を引くので、名前で探す重さが乗る。
    pub type alias Pose = (Float64, Float64, Float64, Float64)

    /// 接触の点 (nx, ny, px, py, separation, feature)。separation が負なら食い込み。feature は warm start の鍵の片側。
    // WhyNot: record にしない — 組ごとに作って欄を引く輪の中で、名前で探す重さが乗る。
    pub type alias Contact = (Float64, Float64, Float64, Float64, Float64, Int32)

    /// world の頂点と法線（x・y・法線の x・法線の y の Vector を 4 本。円は空）。
    // WhyNot: record にしない — 内側の輪で欄を引くたびに名前で探す分の重さが乗る。
    pub type alias WorldPolygon = (Vector[Float64], Vector[Float64], Vector[Float64], Vector[Float64])

    /// 接触の点を作る離れ（これより離れた組は点を作らない。speculative contact の余白）。
    pub def margin(): Float64 = 0.02

    /// 多角形の world の頂点と法線を先に作ってある時の当たり（円は空の組を渡す）。
    // WhyNot: 組ごとに world の頂点を作り直さない — 1 刻みに組の数 × 2 回 Vector を 4 本ずつ作ることになる。体ごとに 1 刻み 1 回だけ作る。
    pub def collideWith(a: Shape, wa: WorldPolygon, pa: Pose, b: Shape, wb: WorldPolygon, pb: Pose): List[Contact] = match (a, b) {
        case (Shape.Circle(ra), Shape.Circle(rb)) => circles(ra, pa, rb, pb)
        case (Shape.Polygon(_, _, _, _), Shape.Circle(rb)) => polygonCircle(wa, rb, pb)
        case (Shape.Circle(ra), Shape.Polygon(_, _, _, _)) => polygonCircle(wb, ra, pa) |> List.map(flip)
        case (Shape.Polygon(_, _, _, _), Shape.Polygon(_, _, _, _)) => polygons(wa, wb)
    }

    /// 形の world の頂点と法線（円は空）。
    pub def worldPolygonOf(shape: Shape, p: Pose): WorldPolygon = match shape {
        case Shape.Circle(_) => (Vector.empty(), Vector.empty(), Vector.empty(), Vector.empty())
        case Shape.Polygon(xs, ys, nxs, nys) => worldPolygon(xs, ys, nxs, nys, p)
    }

    def flip(k: Contact): Contact =
        let (nx, ny, px, py, sep, feature) = k;
        (-nx, -ny, px, py, sep, feature)

    def circles(ra: Float64, pa: Pose, rb: Float64, pb: Pose): List[Contact] =
        let (ax, ay, _, _) = pa;
        let (bx, by, _, _) = pb;
        let dx = bx - ax;
        let dy = by - ay;
        let d2 = dx * dx + dy * dy;
        let reach = ra + rb + margin();
        if (d2 > reach * reach) Nil
        else {
            let d = PortableMath.sqrt(d2);
            let (nx, ny) = if (d > 1.0e-9) (dx / d, dy / d) else (0.0, 1.0);
            let sep = d - ra - rb;
            let mid = ra + sep / 2.0;
            (nx, ny, ax + nx * mid, ay + ny * mid, sep, 0) :: Nil
        }

    def worldPolygon(xs: Vector[Float64], ys: Vector[Float64], nxs: Vector[Float64], nys: Vector[Float64], p: Pose): WorldPolygon =
        let (px, py, c, s) = p;
        (Vector.zipWith((lx, ly) -> c * lx - s * ly + px, xs, ys),
         Vector.zipWith((lx, ly) -> s * lx + c * ly + py, xs, ys),
         Vector.zipWith((lx, ly) -> c * lx - s * ly, nxs, nys),
         Vector.zipWith((lx, ly) -> s * lx + c * ly, nxs, nys))

    /// 多角形 a と円 b（中心 pb）。
    def polygonCircle(a: WorldPolygon, rb: Float64, pb: Pose): List[Contact] =
        let (axs, ays, anxs, anys) = a;
        let n = Vector.length(axs);
        let (cx, cy, _, _) = pb;
        let (face, s) = Vector.range(0, n) |> Vector.foldLeft((best, i) -> {
            let si = Vector.get(i, anxs) * (cx - Vector.get(i, axs)) + Vector.get(i, anys) * (cy - Vector.get(i, ays));
            if (si > snd(best)) (i, si) else best
        }, (0, Float64.minValue()));
        if (s > rb + margin()) Nil
        else {
            let j = Int32.modulo(face + 1, n);
            let (x1, y1, x2, y2) = (Vector.get(face, axs), Vector.get(face, ays), Vector.get(j, axs), Vector.get(j, ays));
            let u1 = (cx - x1) * (x2 - x1) + (cy - y1) * (y2 - y1);
            let u2 = (cx - x2) * (x1 - x2) + (cy - y2) * (y1 - y2);
            if (s > 0.0 and u1 <= 0.0) corner(cx, cy, rb, x1, y1, 100 + face)
            else if (s > 0.0 and u2 <= 0.0) corner(cx, cy, rb, x2, y2, 100 + j)
            else {
                let nx = Vector.get(face, anxs);
                let ny = Vector.get(face, anys);
                let sep = s - rb;
                (nx, ny, cx - nx * (rb + sep / 2.0), cy - ny * (rb + sep / 2.0), sep, face) :: Nil
            }
        }

    /// 円（中心 cx cy・半径 rb）が多角形の角 (vx, vy) に当たる点。
    def corner(cx: Float64, cy: Float64, rb: Float64, vx: Float64, vy: Float64, feature: Int32): List[Contact] =
        let dx = cx - vx;
        let dy = cy - vy;
        let d = PortableMath.sqrt(dx * dx + dy * dy);
        if (d > rb + margin() or d < 1.0e-9) Nil
        else {
            let nx = dx / d;
            let ny = dy / d;
            let sep = d - rb;
            (nx, ny, vx + nx * sep / 2.0, vy + ny * sep / 2.0, sep, feature) :: Nil
        }

    /// a の辺の法線のうち、b を一番離す物（辺の番号, 離れ）。margin を超えて離れた軸が見つかったらそこで止める。
    def maxSeparation(a: WorldPolygon, b: WorldPolygon): (Int32, Float64) =
        let (axs, ays, anxs, anys) = a;
        let (bxs, bys, _, _) = b;
        maxSeparationFrom(axs, ays, anxs, anys, bxs, bys, 0, 0, Float64.minValue())

    def maxSeparationFrom(axs: Vector[Float64], ays: Vector[Float64], anxs: Vector[Float64], anys: Vector[Float64],
                          bxs: Vector[Float64], bys: Vector[Float64], i: Int32, bestI: Int32, best: Float64): (Int32, Float64) =
        if (i >= Vector.length(axs) or best > margin()) (bestI, best)
        else {
            let deepest = deepestAlong(Vector.get(i, anxs), Vector.get(i, anys), Vector.get(i, axs), Vector.get(i, ays), bxs, bys, 0, Float64.maxValue());
            if (deepest > best) maxSeparationFrom(axs, ays, anxs, anys, bxs, bys, i + 1, i, deepest)
            else maxSeparationFrom(axs, ays, anxs, anys, bxs, bys, i + 1, bestI, best)
        }

    /// b の頂点のうち、辺 (法線 nx ny・頂点 vx vy) の一番内側の深さ。
    def deepestAlong(nx: Float64, ny: Float64, vx: Float64, vy: Float64, bxs: Vector[Float64], bys: Vector[Float64], k: Int32, m: Float64): Float64 =
        if (k >= Vector.length(bxs)) m
        else deepestAlong(nx, ny, vx, vy, bxs, bys, k + 1, Float64.min(m, nx * (Vector.get(k, bxs) - vx) + ny * (Vector.get(k, bys) - vy)))

    def polygons(a: WorldPolygon, b: WorldPolygon): List[Contact] =
        let (edgeA, sepA) = maxSeparation(a, b);
        if (sepA > margin()) Nil else polygonsB(a, b, edgeA, sepA)

    /// a の辺で離れなかった時だけ b の辺を見る。
    def polygonsB(a: WorldPolygon, b: WorldPolygon, edgeA: Int32, sepA: Float64): List[Contact] =
        let (edgeB, sepB) = maxSeparation(b, a);
        if (sepB > margin()) Nil
        else if (sepB > sepA + 0.001) clip(b, edgeB, a, true)
        else clip(a, edgeA, b, false)

    /// 基準の多角形 r の辺 edge に、相手 inc の一番向かい合う辺を切り取って当てる。flipped なら法線を返す向きに直す。
    def clip(r: WorldPolygon, edge: Int32, inc: WorldPolygon, flipped: Bool): List[Contact] =
        let (rxs, rys, rnxs, rnys) = r;
        let (ixs, iys, inxs, inys) = inc;
        let nr = Vector.length(rxs);
        let ni = Vector.length(ixs);
        let nx = Vector.get(edge, rnxs);
        let ny = Vector.get(edge, rnys);
        let incEdge = Vector.range(0, ni) |> Vector.foldLeft((best, k) -> {
            let d = nx * Vector.get(k, inxs) + ny * Vector.get(k, inys);
            if (d < snd(best)) (k, d) else best
        }, (0, Float64.maxValue())) |> fst;
        let i2 = Int32.modulo(incEdge + 1, ni);
        let r2 = Int32.modulo(edge + 1, nr);
        let (rx1, ry1, rx2, ry2) = (Vector.get(edge, rxs), Vector.get(edge, rys), Vector.get(r2, rxs), Vector.get(r2, rys));
        let tlen = PortableMath.sqrt((rx2 - rx1) * (rx2 - rx1) + (ry2 - ry1) * (ry2 - ry1));
        let tx = (rx2 - rx1) / tlen;
        let ty = (ry2 - ry1) / tlen;
        let seg = ((Vector.get(incEdge, ixs), Vector.get(incEdge, iys), 0), (Vector.get(i2, ixs), Vector.get(i2, iys), 1));
        let clipped = clipSegment(-tx, -ty, -(tx * rx1 + ty * ry1), seg)
            |> Option.flatMap(clipSegment(tx, ty, tx * rx2 + ty * ry2));
        let edges = (edge, incEdge, flipped);
        clipped |> Option.map(pair -> (fst(pair) :: snd(pair) :: Nil) |> List.filterMap(clipPoint(nx, ny, rx1, ry1, edges)))
                |> Option.getWithDefault(Nil)

    /// 切り取った点 1 つを接触の点にする（margin より離れていれば捨てる）。
    def clipPoint(nx: Float64, ny: Float64, rx1: Float64, ry1: Float64, edges: (Int32, Int32, Bool), p: (Float64, Float64, Int32)): Option[Contact] =
        let (px, py, id) = p;
        let (edge, incEdge, flipped) = edges;
        let sep = nx * (px - rx1) + ny * (py - ry1);
        if (sep > margin()) None
        else {
            let cx = px - nx * sep / 2.0;
            let cy = py - ny * sep / 2.0;
            let feature = (if (flipped) 1000000 else 0) + edge * 10000 + incEdge * 100 + id;
            Some(if (flipped) (-nx, -ny, cx, cy, sep, feature) else (nx, ny, cx, cy, sep, feature))
        }

    /// 線分を「n·p <= offset」の側に切る（2 点とも外なら None）。
    def clipSegment(nx: Float64, ny: Float64, offset: Float64,
                    seg: ((Float64, Float64, Int32), (Float64, Float64, Int32))): Option[((Float64, Float64, Int32), (Float64, Float64, Int32))] =
        let ((x1, y1, id1), (x2, y2, id2)) = seg;
        let d1 = nx * x1 + ny * y1 - offset;
        let d2 = nx * x2 + ny * y2 - offset;
        if (d1 <= 0.0 and d2 <= 0.0) Some(seg)
        else if (d1 > 0.0 and d2 > 0.0) None
        else {
            let t = d1 / (d1 - d2);
            let cut = (x1 + t * (x2 - x1), y1 + t * (y2 - y1), if (d1 > 0.0) id1 else id2);
            if (d1 > 0.0) Some((cut, (x2, y2, id2))) else Some(((x1, y1, id1), cut))
        }

    // ── 光線と点 ──

    /// 光線（起点 ox oy・長さ 1 の向き dx dy・長さ maxDist）が形に当たる (距離, 法線の x, 法線の y)。起点が形の中なら当てない。
    pub def rayCast(shape: Shape, p: Pose, ray: (Float64, Float64, Float64, Float64), maxDist: Float64): Option[(Float64, Float64, Float64)] = match shape {
        case Shape.Circle(r) => rayCircle(p, r, ray, maxDist)
        case Shape.Polygon(xs, ys, nxs, nys) => rayPolygon(worldPolygon(xs, ys, nxs, nys, p), ray, maxDist)
    }

    def rayCircle(p: Pose, r: Float64, ray: (Float64, Float64, Float64, Float64), maxDist: Float64): Option[(Float64, Float64, Float64)] =
        let (cx, cy, _, _) = p;
        let (ox, oy, dx, dy) = ray;
        let mx = ox - cx;
        let my = oy - cy;
        let c = mx * mx + my * my - r * r;
        let b = mx * dx + my * dy;
        let disc = b * b - c;
        if (c <= 0.0 or b > 0.0 or disc < 0.0) None
        else {
            let t = -b - PortableMath.sqrt(disc);
            if (t > maxDist) None
            else {
                let hx = ox + dx * t - cx;
                let hy = oy + dy * t - cy;
                Some((t, hx / r, hy / r))
            }
        }

    /// 辺ごとに入る・出るを切り詰める（Cyrus-Beck）。
    def rayPolygon(wp: WorldPolygon, ray: (Float64, Float64, Float64, Float64), maxDist: Float64): Option[(Float64, Float64, Float64)] =
        let (xs, ys, nxs, nys) = wp;
        let (ox, oy, dx, dy) = ray;
        let n = Vector.length(xs);
        let start = (-1.0, maxDist, 0.0, 0.0, true);
        let (enter, exit, enx, eny, ok) = Vector.range(0, n) |> Vector.foldLeft((acc, i) -> {
            let (lo, hi, bx, by, live) = acc;
            let nx = Vector.get(i, nxs);
            let ny = Vector.get(i, nys);
            let num = nx * (Vector.get(i, xs) - ox) + ny * (Vector.get(i, ys) - oy);
            let den = nx * dx + ny * dy;
            if (not live) acc
            else if (den == 0.0) (if (num < 0.0) (lo, hi, bx, by, false) else acc)
            else {
                let t = num / den;
                if (den < 0.0) (if (t > lo) (t, hi, nx, ny, live) else acc)
                else (lo, Float64.min(hi, t), bx, by, live)
            }
        }, start);
        if (not ok or enter < 0.0 or enter > exit) None else Some((enter, enx, eny))

    /// 点が形の中（境目を含む）か。
    pub def containsPoint(shape: Shape, p: Pose, px: Float64, py: Float64): Bool = match shape {
        case Shape.Circle(r) =>
            let (cx, cy, _, _) = p;
            (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r
        case Shape.Polygon(xs, ys, nxs, nys) =>
            let (wxs, wys, wnxs, wnys) = worldPolygon(xs, ys, nxs, nys, p);
            Vector.range(0, Vector.length(wxs)) |> Vector.forAll(i ->
                Vector.get(i, wnxs) * (px - Vector.get(i, wxs)) + Vector.get(i, wnys) * (py - Vector.get(i, wys)) <= 0.0)
    }
}
