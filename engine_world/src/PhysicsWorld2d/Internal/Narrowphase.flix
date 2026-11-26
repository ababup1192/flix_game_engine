// PhysicsWorld2d.Internal.Narrowphase — 2 つの形の細かい当たり（接触の点 0〜2 個）と、光線・点の当たり。法線は a から b へ向く。
// 円-円・多角形-円・多角形-多角形（分離軸で一番浅い辺を選び、相手の辺を切り取る。片方の軸で離れたら止める）。
// 多角形は world の頂点の配列（stride 4: x・y・辺の外向きの法線の x・y。体ごとの始まりの番号と数で読む）から読む。
// ゲームからは呼ばない（PhysicsWorld2d の中身）。
pub mod PhysicsWorld2d.Internal.Narrowphase {
    use PhysicsWorld2d.Internal.Shape.Shape

    /// 体の姿勢 (x, y, cos, sin)。
    // WhyNot: record にしない — 組ごとに作って欄を引くので、名前で探す重さが乗る。
    pub type alias Pose = (Float64, Float64, Float64, Float64)

    /// 当たりの出し先: 点の欄（stride 5: nx・ny・px・py・separation。2 点まで）・整数の欄（0〜1 点ごとの特徴の番号・2 点の数）・
    /// 途中の値（0 一番浅い辺の離れ・1 辺の一番内側の深さ・2〜5 切り取る線分の x1・y1・x2・y2）。separation が負なら食い込み。特徴は warm start の鍵の片側。
    // WhyNot: 点の List やタプル・Option を返さない — 返すたびに入れ物を作り、組の数 × 辺の数だけの割り当てがブラウザ版でそのまま時間に出る。
    pub type alias Scratch[r: Region] = (Array[Float64, r], Array[Int32, r], Array[Float64, r])

    pub def newScratch(rc: Region[r]): Scratch[r] \ r = (Array.repeat(rc, 2 * contactStride(), 0.0), Array.repeat(rc, 3, 0), Array.repeat(rc, 6, 0.0))

    /// 出し先の点の欄の stride。
    pub def contactStride(): Int32 = 5

    /// 接触の点を作る離れ（これより離れた組は点を作らない。speculative contact の余白）。
    pub def margin(): Float64 = 0.02

    /// 形の頂点の数（円は 0）。
    pub def vertexCount(shape: Shape): Int32 = match shape {
        case Shape.Circle(_) => 0
        case Shape.Polygon(xs, _, _, _) => Vector.length(xs)
    }

    /// 形の world の頂点と法線を wv の頂点 v0 から書く（円は書かない）。
    pub def writeWorldVertices(shape: Shape, px: Float64, py: Float64, c: Float64, s: Float64, wv: Array[Float64, r], v0: Int32): Unit \ r = match shape {
        case Shape.Circle(_) => ()
        case Shape.Polygon(xs, ys, nxs, nys) => writeVertices(xs, ys, nxs, nys, (px, py, c, s), wv, v0, 0); ()
    }

    def writeVertices(xs: Vector[Float64], ys: Vector[Float64], nxs: Vector[Float64], nys: Vector[Float64], p: Pose,
                      wv: Array[Float64, r], v0: Int32, i: Int32): Unit \ r =
        if (i >= Vector.length(xs)) ()
        else {
            let (px, py, c, s) = p;
            let lx = Vector.get(i, xs);
            let ly = Vector.get(i, ys);
            let lnx = Vector.get(i, nxs);
            let lny = Vector.get(i, nys);
            let o = (v0 + i) * 4;
            Array.put(c * lx - s * ly + px, o, wv);
            Array.put(s * lx + c * ly + py, o + 1, wv);
            Array.put(c * lnx - s * lny, o + 2, wv);
            Array.put(s * lnx + c * lny, o + 3, wv);
            writeVertices(xs, ys, nxs, nys, p, wv, v0, i + 1)
        }

    /// 体 a（頂点 va から na 個・中心 ax ay）と体 b の当たりを sc へ書く。点の数は countOf(sc)。
    pub def collideInto(sc: Scratch[r], wv: Array[Float64, r], a: Shape, va: Int32, na: Int32, ax: Float64, ay: Float64,
                        b: Shape, vb: Int32, nb: Int32, bx: Float64, by: Float64): Unit \ r = {
        // WhyNot: (a, b) の組で match しない — 組ごとにタプルを 1 つ作る。
        match a {
            case Shape.Circle(ra) => circleWith(sc, wv, ra, ax, ay, b, vb, nb, bx, by)
            case Shape.Polygon(_, _, _, _) => polygonWith(sc, wv, va, na, b, vb, nb, bx, by)
        };
        ()
    }

    def circleWith(sc: Scratch[r], wv: Array[Float64, r], ra: Float64, ax: Float64, ay: Float64, b: Shape, vb: Int32, nb: Int32, bx: Float64, by: Float64): Unit \ r = {
        match b {
            case Shape.Circle(rb) => circlesInto(sc, ra, ax, ay, rb, bx, by)
            case Shape.Polygon(_, _, _, _) => polygonCircleInto(sc, wv, vb, nb, ra, ax, ay, true)
        };
        ()
    }

    def polygonWith(sc: Scratch[r], wv: Array[Float64, r], va: Int32, na: Int32, b: Shape, vb: Int32, nb: Int32, bx: Float64, by: Float64): Unit \ r = {
        match b {
            case Shape.Circle(rb) => polygonCircleInto(sc, wv, va, na, rb, bx, by, false)
            case Shape.Polygon(_, _, _, _) => polygonsInto(sc, wv, va, na, vb, nb)
        };
        ()
    }

    /// sc に書いた点の数。
    pub def countOf(sc: Scratch[r]): Int32 \ r = let (_, ints, _) = sc; Array.get(2, ints)

    /// sc に書いた点 k の欄 field（0 nx・1 ny・2 px・3 py・4 separation）。
    pub def contactOf(sc: Scratch[r], k: Int32, field: Int32): Float64 \ r = let (pts, _, _) = sc; Array.get(k * contactStride() + field, pts)

    /// sc に書いた点 k の特徴の番号。
    pub def featureOf(sc: Scratch[r], k: Int32): Int32 \ r = let (_, ints, _) = sc; Array.get(k, ints)

    def setCount(sc: Scratch[r], n: Int32): Unit \ r = let (_, ints, _) = sc; Array.put(n, 2, ints)

    /// 点 k を書く。flipped なら法線を返す向きに直す（位置はそのまま）。
    def putContact(sc: Scratch[r], k: Int32, flipped: Bool, nx: Float64, ny: Float64, px: Float64, py: Float64, sep: Float64, feature: Int32): Unit \ r =
        let (pts, ints, _) = sc;
        let o = k * contactStride();
        Array.put(if (flipped) -nx else nx, o, pts);
        Array.put(if (flipped) -ny else ny, o + 1, pts);
        Array.put(px, o + 2, pts);
        Array.put(py, o + 3, pts);
        Array.put(sep, o + 4, pts);
        Array.put(feature, k, ints)

    def circlesInto(sc: Scratch[r], ra: Float64, ax: Float64, ay: Float64, rb: Float64, bx: Float64, by: Float64): Unit \ r =
        let dx = bx - ax;
        let dy = by - ay;
        let d2 = dx * dx + dy * dy;
        let reach = ra + rb + margin();
        if (d2 > reach * reach) setCount(sc, 0)
        else {
            let d = PortableMath.sqrt(d2);
            let apart = d > 1.0e-9;
            let nx = if (apart) dx / d else 0.0;
            let ny = if (apart) dy / d else 1.0;
            let sep = d - ra - rb;
            let mid = ra + sep / 2.0;
            putContact(sc, 0, false, nx, ny, ax + nx * mid, ay + ny * mid, sep, 0);
            setCount(sc, 1)
        };
        ()

    /// 多角形（頂点 v0 から n 個）と円（中心 cx cy・半径 rb）。flipped なら円の側が a（法線を返す向きに書く）。
    def polygonCircleInto(sc: Scratch[r], wv: Array[Float64, r], v0: Int32, n: Int32, rb: Float64, cx: Float64, cy: Float64, flipped: Bool): Unit \ r =
        let (_, _, tmp) = sc;
        let face = shallowestFace(wv, v0, n, cx, cy, tmp, 0, 0, Float64.minValue());
        let s = Array.get(0, tmp);
        if (s > rb + margin()) setCount(sc, 0)
        else {
            let j = Int32.modulo(face + 1, n);
            let o1 = (v0 + face) * 4;
            let o2 = (v0 + j) * 4;
            let x1 = Array.get(o1, wv);
            let y1 = Array.get(o1 + 1, wv);
            let x2 = Array.get(o2, wv);
            let y2 = Array.get(o2 + 1, wv);
            let u1 = (cx - x1) * (x2 - x1) + (cy - y1) * (y2 - y1);
            let u2 = (cx - x2) * (x1 - x2) + (cy - y2) * (y1 - y2);
            if (s > 0.0 and u1 <= 0.0) cornerInto(sc, cx, cy, rb, x1, y1, 100 + face, flipped)
            else if (s > 0.0 and u2 <= 0.0) cornerInto(sc, cx, cy, rb, x2, y2, 100 + j, flipped)
            else {
                let nx = Array.get(o1 + 2, wv);
                let ny = Array.get(o1 + 3, wv);
                let sep = s - rb;
                putContact(sc, 0, flipped, nx, ny, cx - nx * (rb + sep / 2.0), cy - ny * (rb + sep / 2.0), sep, face);
                setCount(sc, 1)
            }
        };
        ()

    /// 円の中心から一番離れた辺（同じ離れなら前の辺）。離れは tmp[0] へ。
    def shallowestFace(wv: Array[Float64, r], v0: Int32, n: Int32, cx: Float64, cy: Float64, tmp: Array[Float64, r],
                       i: Int32, bestI: Int32, best: Float64): Int32 \ r =
        if (i >= n) { Array.put(best, 0, tmp); bestI }
        else {
            let o = (v0 + i) * 4;
            let si = Array.get(o + 2, wv) * (cx - Array.get(o, wv)) + Array.get(o + 3, wv) * (cy - Array.get(o + 1, wv));
            if (si > best) shallowestFace(wv, v0, n, cx, cy, tmp, i + 1, i, si)
            else shallowestFace(wv, v0, n, cx, cy, tmp, i + 1, bestI, best)
        }

    /// 円（中心 cx cy・半径 rb）が多角形の角 (vx, vy) に当たる点。
    def cornerInto(sc: Scratch[r], cx: Float64, cy: Float64, rb: Float64, vx: Float64, vy: Float64, feature: Int32, flipped: Bool): Unit \ r =
        let dx = cx - vx;
        let dy = cy - vy;
        let d = PortableMath.sqrt(dx * dx + dy * dy);
        if (d > rb + margin() or d < 1.0e-9) setCount(sc, 0)
        else {
            let nx = dx / d;
            let ny = dy / d;
            let sep = d - rb;
            putContact(sc, 0, flipped, nx, ny, vx + nx * sep / 2.0, vy + ny * sep / 2.0, sep, feature);
            setCount(sc, 1)
        };
        ()

    /// a の辺の法線のうち、b を一番離す辺（同じ離れなら前の辺）。margin を超えて離れた軸が見つかったらそこで止める。離れは tmp[0] へ。
    def maxSeparation(wv: Array[Float64, r], va: Int32, na: Int32, vb: Int32, nb: Int32, tmp: Array[Float64, r],
                      i: Int32, bestI: Int32, best: Float64): Int32 \ r =
        if (i >= na or best > margin()) { Array.put(best, 0, tmp); bestI }
        else {
            let o = (va + i) * 4;
            deepestAlong(Array.get(o + 2, wv), Array.get(o + 3, wv), Array.get(o, wv), Array.get(o + 1, wv), wv, vb, nb, tmp, 0, Float64.maxValue());
            let deepest = Array.get(1, tmp);
            if (deepest > best) maxSeparation(wv, va, na, vb, nb, tmp, i + 1, i, deepest)
            else maxSeparation(wv, va, na, vb, nb, tmp, i + 1, bestI, best)
        }

    /// b の頂点のうち、辺 (法線 nx ny・頂点 vx vy) の一番内側の深さを tmp[1] へ。
    def deepestAlong(nx: Float64, ny: Float64, vx: Float64, vy: Float64, wv: Array[Float64, r], vb: Int32, nb: Int32, tmp: Array[Float64, r],
                     k: Int32, m: Float64): Unit \ r =
        if (k >= nb) Array.put(m, 1, tmp)
        else {
            let o = (vb + k) * 4;
            deepestAlong(nx, ny, vx, vy, wv, vb, nb, tmp, k + 1, Float64.min(m, nx * (Array.get(o, wv) - vx) + ny * (Array.get(o + 1, wv) - vy)))
        }

    /// a の辺で離れなかった時だけ b の辺を見る。
    def polygonsInto(sc: Scratch[r], wv: Array[Float64, r], va: Int32, na: Int32, vb: Int32, nb: Int32): Unit \ r =
        let (_, _, tmp) = sc;
        let edgeA = maxSeparation(wv, va, na, vb, nb, tmp, 0, 0, Float64.minValue());
        let sepA = Array.get(0, tmp);
        if (sepA > margin()) setCount(sc, 0)
        else {
            let edgeB = maxSeparation(wv, vb, nb, va, na, tmp, 0, 0, Float64.minValue());
            let sepB = Array.get(0, tmp);
            if (sepB > margin()) setCount(sc, 0)
            else if (sepB > sepA + 0.001) clipInto(sc, wv, vb, nb, edgeB, va, na, true)
            else clipInto(sc, wv, va, na, edgeA, vb, nb, false)
        };
        ()

    /// 基準の多角形（頂点 vr から nr 個）の辺 edge に、相手（頂点 vi から ni 個）の一番向かい合う辺を切り取って当てる。flipped なら法線を返す向きに直す。
    def clipInto(sc: Scratch[r], wv: Array[Float64, r], vr: Int32, nr: Int32, edge: Int32, vi: Int32, ni: Int32, flipped: Bool): Unit \ r =
        let (_, _, tmp) = sc;
        let oe = (vr + edge) * 4;
        let nx = Array.get(oe + 2, wv);
        let ny = Array.get(oe + 3, wv);
        let incEdge = mostFacing(wv, vi, ni, nx, ny, 0, 0, Float64.maxValue());
        let i2 = Int32.modulo(incEdge + 1, ni);
        let r2 = Int32.modulo(edge + 1, nr);
        let or2 = (vr + r2) * 4;
        let rx1 = Array.get(oe, wv);
        let ry1 = Array.get(oe + 1, wv);
        let rx2 = Array.get(or2, wv);
        let ry2 = Array.get(or2 + 1, wv);
        let tlen = PortableMath.sqrt((rx2 - rx1) * (rx2 - rx1) + (ry2 - ry1) * (ry2 - ry1));
        let tx = (rx2 - rx1) / tlen;
        let ty = (ry2 - ry1) / tlen;
        let oi1 = (vi + incEdge) * 4;
        let oi2 = (vi + i2) * 4;
        Array.put(Array.get(oi1, wv), 2, tmp); Array.put(Array.get(oi1 + 1, wv), 3, tmp);
        Array.put(Array.get(oi2, wv), 4, tmp); Array.put(Array.get(oi2 + 1, wv), 5, tmp);
        setCount(sc, 0);
        let kept = clipSegment(-tx, -ty, -(tx * rx1 + ty * ry1), tmp) and clipSegment(tx, ty, tx * rx2 + ty * ry2, tmp);
        if (kept) {
            let base = (if (flipped) 1000000 else 0) + edge * 10000 + incEdge * 100;
            clipPoint(sc, nx, ny, rx1, ry1, flipped, base, Array.get(2, tmp), Array.get(3, tmp));
            clipPoint(sc, nx, ny, rx1, ry1, flipped, base + 1, Array.get(4, tmp), Array.get(5, tmp))
        } else ();
        ()

    /// 相手の辺のうち、法線 (nx, ny) と一番向かい合う辺（同じなら前の辺）。
    def mostFacing(wv: Array[Float64, r], vi: Int32, ni: Int32, nx: Float64, ny: Float64, k: Int32, bestK: Int32, best: Float64): Int32 \ r =
        if (k >= ni) bestK
        else {
            let o = (vi + k) * 4;
            let d = nx * Array.get(o + 2, wv) + ny * Array.get(o + 3, wv);
            if (d < best) mostFacing(wv, vi, ni, nx, ny, k + 1, k, d) else mostFacing(wv, vi, ni, nx, ny, k + 1, bestK, best)
        }

    /// 切り取った点 1 つを接触の点として足す（margin より離れていれば捨てる）。feature は (b が基準なら 1000000) + 基準の辺 × 10000 + 相手の辺 × 100 + 線分の端（0・1）。
    /// 切った点は外にあった端の番号のまま。
    def clipPoint(sc: Scratch[r], nx: Float64, ny: Float64, rx1: Float64, ry1: Float64, flipped: Bool, feature: Int32, px: Float64, py: Float64): Unit \ r =
        let sep = nx * (px - rx1) + ny * (py - ry1);
        if (sep > margin()) ()
        else {
            let cx = px - nx * sep / 2.0;
            let cy = py - ny * sep / 2.0;
            let k = countOf(sc);
            putContact(sc, k, flipped, nx, ny, cx, cy, sep, feature);
            setCount(sc, k + 1)
        };
        ()

    /// 線分（tmp の 2・3 と 4・5）を「n·p <= offset」の側に切る（2 点とも外なら false）。
    def clipSegment(nx: Float64, ny: Float64, offset: Float64, tmp: Array[Float64, r]): Bool \ r =
        let x1 = Array.get(2, tmp);
        let y1 = Array.get(3, tmp);
        let x2 = Array.get(4, tmp);
        let y2 = Array.get(5, tmp);
        let d1 = nx * x1 + ny * y1 - offset;
        let d2 = nx * x2 + ny * y2 - offset;
        if (d1 <= 0.0 and d2 <= 0.0) true
        else if (d1 > 0.0 and d2 > 0.0) false
        else {
            let t = d1 / (d1 - d2);
            let cx = x1 + t * (x2 - x1);
            let cy = y1 + t * (y2 - y1);
            if (d1 > 0.0) { Array.put(cx, 2, tmp); Array.put(cy, 3, tmp) }
            else { Array.put(cx, 4, tmp); Array.put(cy, 5, tmp) };
            true
        }

    // ── 光線と点 ──

    /// 光線（起点 ox oy・長さ 1 の向き dx dy・長さ maxDist）が形に当たる (距離, 法線の x, 法線の y)。起点が形の中なら当てない。
    pub def rayCast(shape: Shape, p: Pose, ray: (Float64, Float64, Float64, Float64), maxDist: Float64): Option[(Float64, Float64, Float64)] = match shape {
        case Shape.Circle(r) => rayCircle(p, r, ray, maxDist)
        case Shape.Polygon(_, _, _, _) => region rc {
            let (wv, n) = worldVerticesOf(rc, shape, p);
            rayPolygon(wv, n, ray, maxDist, 0, (-1.0, maxDist, 0.0, 0.0, true))
        }
    }

    def worldVerticesOf(rc: Region[r], shape: Shape, p: Pose): (Array[Float64, r], Int32) \ r =
        let n = vertexCount(shape);
        let wv = Array.repeat(rc, n * 4, 0.0);
        let (px, py, c, s) = p;
        writeWorldVertices(shape, px, py, c, s, wv, 0);
        (wv, n)

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

    /// 辺ごとに入る・出るを切り詰める（Cyrus-Beck）。acc は (入る距離, 出る距離, 入った辺の法線の x, y, まだ当たりうるか)。
    def rayPolygon(wv: Array[Float64, r], n: Int32, ray: (Float64, Float64, Float64, Float64), maxDist: Float64, i: Int32,
                   acc: (Float64, Float64, Float64, Float64, Bool)): Option[(Float64, Float64, Float64)] \ r =
        let (lo, hi, bx, by, live) = acc;
        if (i >= n) { if (not live or lo < 0.0 or lo > hi) None else Some((lo, bx, by)) }
        else {
            let (ox, oy, dx, dy) = ray;
            let o = i * 4;
            let nx = Array.get(o + 2, wv);
            let ny = Array.get(o + 3, wv);
            let num = nx * (Array.get(o, wv) - ox) + ny * (Array.get(o + 1, wv) - oy);
            let den = nx * dx + ny * dy;
            let next =
                if (not live) acc
                else if (den == 0.0) (if (num < 0.0) (lo, hi, bx, by, false) else acc)
                else {
                    let t = num / den;
                    if (den < 0.0) (if (t > lo) (t, hi, nx, ny, live) else acc)
                    else (lo, Float64.min(hi, t), bx, by, live)
                };
            rayPolygon(wv, n, ray, maxDist, i + 1, next)
        }

    /// 点が形の中（境目を含む）か。
    pub def containsPoint(shape: Shape, p: Pose, px: Float64, py: Float64): Bool = match shape {
        case Shape.Circle(r) =>
            let (cx, cy, _, _) = p;
            (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r
        case Shape.Polygon(_, _, _, _) => region rc {
            let (wv, n) = worldVerticesOf(rc, shape, p);
            insideAll(wv, n, px, py, 0)
        }
    }

    def insideAll(wv: Array[Float64, r], n: Int32, px: Float64, py: Float64, i: Int32): Bool \ r =
        if (i >= n) true
        else {
            let o = i * 4;
            if (Array.get(o + 2, wv) * (px - Array.get(o, wv)) + Array.get(o + 3, wv) * (py - Array.get(o + 1, wv)) <= 0.0) insideAll(wv, n, px, py, i + 1)
            else false
        }
}
