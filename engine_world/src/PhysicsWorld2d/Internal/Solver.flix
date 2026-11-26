// PhysicsWorld2d.Internal.Solver — 接触の解き手（Box2D 3 の soft step）。region の配列を書き換えて回す。
// 刻みを substep に割り、毎回「重力 → warm start → ばねで柔らかくした接触を 1 回 → 位置を進める → relax（食い込みを戻す分を抜く）」。
// 最後に跳ね返りを 1 回。接触の離れは、刻みの頭の離れに、その後の体の動きを足して出す（ナローフェーズを substep ごとに回さない）。
// 決まり: 足し引き掛け割りと平方根だけ・点を解く順は回ごとに前から・後ろからと入れ替える。ゲームからは呼ばない。
pub mod PhysicsWorld2d.Internal.Solver {
    use PhysicsWorld2d.Internal.Data.Warm
    import java.util.Arrays

    // 体の欄（bs の stride 17）: 0 x・1 y・2 cos・3 sin・4 vx・5 vy・6 w・7 重さの逆数・8 慣性の逆数・9 粗い当たりの半径・10 眠りの時計・
    // 11 摩擦・12 跳ね返り・13〜16 刻みの頭の x・y・cos・sin。
    // 点の欄（ps の stride 15）: 0 nx・1 ny・2〜5 刻みの頭の腕（a の x y・b の x y）・6 法線の重さ・7 接線の重さ・8 刻みの頭の離れ・9 摩擦・
    // 10 法線の衝撃の貯め・11 接線の衝撃の貯め・12 跳ね返り・13 刻みの頭の近づく速さ・14 法線の衝撃の一番大きい値。点の体の番号は pab（stride 2）。

    pub def bStride(): Int32 = 17
    def sStride(): Int32 = 15

    def slop(): Float64 = 0.005
    def bounceThreshold(): Float64 = 1.0
    def contactHertz(): Float64 = 30.0
    def contactDamping(): Float64 = 10.0
    def maxPushout(): Float64 = 3.0

    /// 接触の点 1 つ (体 a の番号, 体 b の番号, nx, ny, px, py, separation, 組の鍵, 特徴の番号)。
    // WhyNot: record にしない — 点ごとに 10 回ほど欄を引き、名前で探す重さが 1 刻みの 1 割を超えた。
    pub type alias Point = (Int32, Int32, Float64, Float64, Float64, Float64, Float64, Int64, Int32)

    /// 解き手が読む配列の組（体の欄・Dynamic か・Kinematic か・眠り・この刻みに起こした体・点の体の番号・体の数）。
    pub type alias Solve[r: Region] = { bs = Array[Float64, r], dyn = Array[Bool, r], kin = Array[Bool, r], asleep = Array[Bool, r],
                                        woken = Array[Bool, r], pab = Array[Int32, r], n = Int32 }

    /// ばねの係数（Box2D 3 の b2MakeSoft）: (biasRate, massScale, impulseScale, 1/h, h)。
    // WhyNot: record にしない — 点ごとに欄を引くので、名前で探す重さが乗る。
    type alias Soft = (Float64, Float64, Float64, Float64, Float64)

    def softOf(h: Float64): Soft =
        let omega = 2.0 * PortableMath.pi() * Float64.min(contactHertz(), 0.25 / h);
        let a1 = 2.0 * contactDamping() + h * omega;
        let a2 = h * omega * a1;
        let a3 = 1.0 / (1.0 + a2);
        (omega / a1, a2 * a3, a3, 1.0 / h, h)

    /// 起きていて、この刻みに起こしたのでない Dynamic の体。
    pub def moving(dyn: Array[Bool, r], asleep: Array[Bool, r], woken: Array[Bool, r], i: Int32): Bool \ r =
        Array.get(i, dyn) and not Array.get(i, asleep) and not Array.get(i, woken)

    /// 1 刻み解く（dt 秒・gravity・substeps 回）。返すのは点ごとの (法線, 接線) の衝撃の貯め（stride 2）。
    pub def solveStep(rc: Region[r], sv: Solve[r], pts: Vector[Point], warm: Warm,
                  step: { dt = Float64, gx = Float64, gy = Float64, substeps = Int32 }): Array[Float64, r] \ r =
        let bs = sv#bs;
        let pab = sv#pab;
        let m = Vector.length(pts);
        let h = step#dt / Int32.toFloat64(step#substeps);
        let soft = softOf(h);
        let ps = Array.repeat(rc, m * sStride(), 0.0);
        Vector.forEachWithIndex((k, p) -> prepare(bs, ps, pab, warm, k, p), pts);
        substepLoop(sv, ps, m, { gx = step#gx * h, gy = step#gy * h, soft = soft }, step#substeps);
        restitutionAll(bs, ps, pab, 0, m);
        let out = Array.repeat(rc, m * 2, 0.0);
        copyImpulses(ps, out, 0, m);
        out

    def copyImpulses(ps: Array[Float64, r], out: Array[Float64, r], k: Int32, m: Int32): Unit \ r =
        if (k >= m) ()
        else {
            Array.put(Array.get(k * sStride() + 10, ps), k * 2, out);
            Array.put(Array.get(k * sStride() + 11, ps), k * 2 + 1, out);
            copyImpulses(ps, out, k + 1, m)
        }

    /// 控えから組と特徴の (法線, 接線) の衝撃（無ければ 0）。
    def warmLookup(pair: Int64, feature: Int32, warm: Warm): (Float64, Float64) =
        let (keys, features, normal, tangent) = warm;
        let at = PhysicsWorld2d.Internal.Data.searchKey(pair, keys, 0, Vector.length(keys) - 1);
        if (at < 0) (0.0, 0.0)
        else if (Vector.get(at * 2, features) == feature) (Vector.get(at * 2, normal), Vector.get(at * 2, tangent))
        else if (Vector.get(at * 2 + 1, features) == feature) (Vector.get(at * 2 + 1, normal), Vector.get(at * 2 + 1, tangent))
        else (0.0, 0.0)

    /// 点の鍵の組を小さい順に並べ、組ごとの 2 つの枠へ衝撃を置いた控え。manifolds は (組の鍵, 最初の点の番号, 点の数)。
    pub def warmOf(rc: Region[r], pts: Vector[Point], manifolds: Vector[(Int64, Int32, Int32)], impulses: Array[Float64, r]): Warm \ r =
        let count = Vector.length(manifolds);
        let sorted = sortedKeys(rc, Vector.map(fst3, manifolds));
        let features = Array.repeat(rc, count * 2, -1);
        let normal = Array.repeat(rc, count * 2, 0.0);
        let tangent = Array.repeat(rc, count * 2, 0.0);
        Vector.forEach(mf -> {
            let (key, first, n) = mf;
            let at = PhysicsWorld2d.Internal.Data.searchKey(key, sorted, 0, count - 1);
            List.range(0, Int32.min(n, 2)) |> List.forEach(j -> {
                let (_, _, _, _, _, _, _, _, feature) = Vector.get(first + j, pts);
                Array.put(feature, at * 2 + j, features);
                Array.put(Array.get((first + j) * 2, impulses), at * 2 + j, normal);
                Array.put(Array.get((first + j) * 2 + 1, impulses), at * 2 + j, tangent)
            })
        }, manifolds);
        (sorted, Array.toVector(features), Array.toVector(normal), Array.toVector(tangent))

    def fst3(t: (Int64, Int32, Int32)): Int64 = let (k, _, _) = t; k

    /// 鍵を小さい順に並べた Vector（鍵はただ 1 つずつなので、並べ方で結果が変わらない）。
    pub def sortedKeys(rc: Region[r], keys: Vector[Int64]): Vector[Int64] \ r =
        let arr = Vector.toArray(rc, keys);
        unchecked_cast(Arrays.sort(arr) as _ \ r);
        Array.toVector(arr)

    /// 点 k の欄を詰める: 腕・法線と接線の重さ・刻みの頭の離れ・摩擦・前の刻みの衝撃・跳ね返り・近づく速さ。
    def prepare(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], warm: Warm, k: Int32, p: Point): Unit \ r =
        let (ia, ib, nx, ny, px, py, separation, pair, feature) = p;
        let oa = ia * bStride();
        let ob = ib * bStride();
        let o = k * sStride();
        let rax = px - Array.get(oa, bs);
        let ray = py - Array.get(oa + 1, bs);
        let rbx = px - Array.get(ob, bs);
        let rby = py - Array.get(ob + 1, bs);
        let ima = Array.get(oa + 7, bs);
        let imb = Array.get(ob + 7, bs);
        let iia = Array.get(oa + 8, bs);
        let iib = Array.get(ob + 8, bs);
        let rna = rax * ny - ray * nx;
        let rnb = rbx * ny - rby * nx;
        let kn = ima + imb + iia * rna * rna + iib * rnb * rnb;
        let rta = -rax * nx - ray * ny;
        let rtb = -rbx * nx - rby * ny;
        let kt = ima + imb + iia * rta * rta + iib * rtb * rtb;
        let dvx = Array.get(ob + 4, bs) - Array.get(ob + 6, bs) * rby - Array.get(oa + 4, bs) + Array.get(oa + 6, bs) * ray;
        let dvy = Array.get(ob + 5, bs) + Array.get(ob + 6, bs) * rbx - Array.get(oa + 5, bs) - Array.get(oa + 6, bs) * rax;
        let (wn, wt) = warmLookup(pair, feature, warm);
        Array.put(nx, o, ps); Array.put(ny, o + 1, ps);
        Array.put(rax, o + 2, ps); Array.put(ray, o + 3, ps); Array.put(rbx, o + 4, ps); Array.put(rby, o + 5, ps);
        Array.put(if (kn > 0.0) 1.0 / kn else 0.0, o + 6, ps);
        Array.put(if (kt > 0.0) 1.0 / kt else 0.0, o + 7, ps);
        Array.put(separation, o + 8, ps);
        Array.put(PortableMath.sqrt(Array.get(oa + 11, bs) * Array.get(ob + 11, bs)), o + 9, ps);
        Array.put(wn, o + 10, ps); Array.put(wt, o + 11, ps);
        Array.put(Float64.max(Array.get(oa + 12, bs), Array.get(ob + 12, bs)), o + 12, ps);
        Array.put(dvx * nx + dvy * ny, o + 13, ps);
        Array.put(0.0, o + 14, ps);
        Array.put(ia, k * 2, pab); Array.put(ib, k * 2 + 1, pab)

    /// substep の中身: gx gy = 1 substep の重力の速さ。
    type alias Substep = { gx = Float64, gy = Float64, soft = Soft }

    def substepLoop(sv: Solve[r], ps: Array[Float64, r], m: Int32, sub: Substep, left: Int32): Unit \ r =
        if (left <= 0) ()
        else {
            let soft = sub#soft;
            applyGravity(sv, sub#gx, sub#gy, 0);
            warmAll(sv#bs, ps, sv#pab, 0, m);
            softRounds(sv#bs, ps, sv#pab, soft, true, m, 2 + Int32.modulo(left, 2));
            let (_, _, _, _, h) = soft;
            integrate(sv, h, 0);
            softRounds(sv#bs, ps, sv#pab, soft, false, m, 2 + Int32.modulo(left + 1, 2));
            substepLoop(sv, ps, m, sub, left - 1)
        }

    // WhyNot: 輪の中で sv#… を引かない — record の欄は名前で探すので、体の数 × substep の数だけ重さが乗る。配列は輪の外で 1 回だけ取り出す。
    def applyGravity(sv: Solve[r], gx: Float64, gy: Float64, i: Int32): Unit \ r =
        gravityFrom(sv#bs, sv#dyn, sv#asleep, sv#woken, gx, gy, i, sv#n)

    def gravityFrom(bs: Array[Float64, r], dyn: Array[Bool, r], asleep: Array[Bool, r], woken: Array[Bool, r],
                    gx: Float64, gy: Float64, i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            if (moving(dyn, asleep, woken, i)) {
                let o = i * bStride();
                Array.put(Array.get(o + 4, bs) + gx, o + 4, bs);
                Array.put(Array.get(o + 5, bs) + gy, o + 5, bs)
            } else ();
            gravityFrom(bs, dyn, asleep, woken, gx, gy, i + 1, n)
        }

    /// 位置と向きを進める（向きは cos・sin の組を回して長さ 1 に戻す。三角関数を使わない）。Kinematic の体も進める。
    def integrate(sv: Solve[r], dt: Float64, i: Int32): Unit \ r =
        integrateFrom(sv#bs, sv#dyn, sv#kin, sv#asleep, sv#woken, dt, i, sv#n)

    def integrateFrom(bs: Array[Float64, r], dyn: Array[Bool, r], kin: Array[Bool, r], asleep: Array[Bool, r], woken: Array[Bool, r],
                      dt: Float64, i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            if (moving(dyn, asleep, woken, i) or Array.get(i, kin)) integrateOne(bs, dt, i * bStride()) else ();
            integrateFrom(bs, dyn, kin, asleep, woken, dt, i + 1, n)
        }

    def integrateOne(bs: Array[Float64, r], dt: Float64, o: Int32): Unit \ r =
        let vx = Array.get(o + 4, bs);
        let vy = Array.get(o + 5, bs);
        let w = Array.get(o + 6, bs);
        Array.put(Array.get(o, bs) + vx * dt, o, bs);
        Array.put(Array.get(o + 1, bs) + vy * dt, o + 1, bs);
        let c0 = Array.get(o + 2, bs);
        let s0 = Array.get(o + 3, bs);
        let c1 = c0 - s0 * w * dt;
        let s1 = s0 + c0 * w * dt;
        let len = PortableMath.sqrt(c1 * c1 + s1 * s1);
        Array.put(c1 / len, o + 2, bs);
        Array.put(s1 / len, o + 3, bs)

    def warmAll(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], k: Int32, m: Int32): Unit \ r =
        if (k >= m) ()
        else {
            let o = k * sStride();
            let nx = Array.get(o, ps);
            let ny = Array.get(o + 1, ps);
            let wn = Array.get(o + 10, ps);
            let wt = Array.get(o + 11, ps);
            impulseAt(bs, ps, pab, k, wn * nx + wt * ny, wn * ny - wt * nx);
            warmAll(bs, ps, pab, k + 1, m)
        }

    /// count は「回数 × 2 + 向き」（向き 0 は前から・1 は後ろから。回ごとに入れ替える）。
    // WhyNot: いつも同じ順で解かない — 先に解いた側へ偏って、積んだ箱の塔が 3 秒で倒れた（soft step でも）。
    def softRounds(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], soft: Soft, useBias: Bool, m: Int32, count: Int32): Unit \ r =
        let left = count / 2;
        let backward = Int32.modulo(count, 2) == 1;
        if (left <= 0) ()
        else {
            if (backward) solveBack(bs, ps, pab, soft, useBias, m - 1) else solveAll(bs, ps, pab, soft, useBias, 0, m);
            softRounds(bs, ps, pab, soft, useBias, m, (left - 1) * 2 + (if (backward) 0 else 1))
        }

    def solveBack(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], soft: Soft, useBias: Bool, k: Int32): Unit \ r =
        if (k < 0) ()
        else {
            solveNormal(bs, ps, pab, soft, useBias, k);
            solveFriction(bs, ps, pab, k);
            solveBack(bs, ps, pab, soft, useBias, k - 1)
        }

    def solveAll(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], soft: Soft, useBias: Bool, k: Int32, m: Int32): Unit \ r =
        if (k >= m) ()
        else {
            solveNormal(bs, ps, pab, soft, useBias, k);
            solveFriction(bs, ps, pab, k);
            solveAll(bs, ps, pab, soft, useBias, k + 1, m)
        }

    /// 今の離れ: 刻みの頭の離れ + (b の点の動き − a の点の動き)·n。
    def currentSeparation(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], k: Int32): Float64 \ r =
        let o = k * sStride();
        let oa = Array.get(k * 2, pab) * bStride();
        let ob = Array.get(k * 2 + 1, pab) * bStride();
        let (dax, day) = anchorMove(bs, oa, Array.get(o + 2, ps), Array.get(o + 3, ps));
        let (dbx, dby) = anchorMove(bs, ob, Array.get(o + 4, ps), Array.get(o + 5, ps));
        Array.get(o + 8, ps) + (dbx - dax) * Array.get(o, ps) + (dby - day) * Array.get(o + 1, ps)

    /// 体の点（刻みの頭の腕 rx ry）が刻みの頭から動いた量。
    def anchorMove(bs: Array[Float64, r], ob: Int32, rx: Float64, ry: Float64): (Float64, Float64) \ r =
        let c = Array.get(ob + 2, bs);
        let s = Array.get(ob + 3, bs);
        let c0 = Array.get(ob + 15, bs);
        let s0 = Array.get(ob + 16, bs);
        let dc = c * c0 + s * s0;
        let ds = s * c0 - c * s0;
        (Array.get(ob, bs) - Array.get(ob + 13, bs) + dc * rx - ds * ry - rx,
         Array.get(ob + 1, bs) - Array.get(ob + 14, bs) + ds * rx + dc * ry - ry)

    def solveNormal(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], soft: Soft, useBias: Bool, k: Int32): Unit \ r =
        let o = k * sStride();
        let sep = currentSeparation(bs, ps, pab, k);
        let speculative = sep > 0.0;
        let (biasRate, softMass, softImpulse, invH, _) = soft;
        let bias = if (speculative) sep * invH else if (useBias) Float64.max(biasRate * Float64.min(0.0, sep + slop()), -maxPushout()) else 0.0;
        let massScale = if (speculative or not useBias) 1.0 else softMass;
        let impulseScale = if (speculative or not useBias) 0.0 else softImpulse;
        let nx = Array.get(o, ps);
        let ny = Array.get(o + 1, ps);
        let vn = relativeAt(bs, ps, pab, k, nx, ny);
        let old = Array.get(o + 10, ps);
        let delta = -Array.get(o + 6, ps) * massScale * (vn + bias) - impulseScale * old;
        let total = Float64.max(old + delta, 0.0);
        Array.put(total, o + 10, ps);
        Array.put(Float64.max(Array.get(o + 14, ps), total), o + 14, ps);
        let d = total - old;
        impulseAt(bs, ps, pab, k, d * nx, d * ny)

    /// 摩擦（法線の衝撃 × 摩擦係数で挟む）。接線は (ny, −nx)。
    def solveFriction(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], k: Int32): Unit \ r =
        let o = k * sStride();
        let tx = Array.get(o + 1, ps);
        let ty = -Array.get(o, ps);
        let vt = relativeAt(bs, ps, pab, k, tx, ty);
        let limit = Array.get(o + 9, ps) * Array.get(o + 10, ps);
        let old = Array.get(o + 11, ps);
        let total = Float64.max(-limit, Float64.min(limit, old - Array.get(o + 7, ps) * vt));
        Array.put(total, o + 11, ps);
        let d = total - old;
        impulseAt(bs, ps, pab, k, d * tx, d * ty)

    /// 跳ね返り（刻みの頭に bounceThreshold より速く近づいていて、押し返しが働いた点だけ）。
    def restitutionAll(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], k: Int32, m: Int32): Unit \ r =
        if (k >= m) ()
        else {
            let o = k * sStride();
            let e = Array.get(o + 12, ps);
            let vn0 = Array.get(o + 13, ps);
            if (e > 0.0 and vn0 < -bounceThreshold() and Array.get(o + 14, ps) > 0.0) {
                let nx = Array.get(o, ps);
                let ny = Array.get(o + 1, ps);
                let vn = relativeAt(bs, ps, pab, k, nx, ny);
                let old = Array.get(o + 10, ps);
                let total = Float64.max(old - Array.get(o + 6, ps) * (vn + e * vn0), 0.0);
                Array.put(total, o + 10, ps);
                let d = total - old;
                impulseAt(bs, ps, pab, k, d * nx, d * ny)
            } else ();
            restitutionAll(bs, ps, pab, k + 1, m)
        }

    /// 点 k の相対の速さを向き (dx, dy) へ写した値。
    def relativeAt(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], k: Int32, dx: Float64, dy: Float64): Float64 \ r =
        let o = k * sStride();
        let oa = Array.get(k * 2, pab) * bStride();
        let ob = Array.get(k * 2 + 1, pab) * bStride();
        let wa = Array.get(oa + 6, bs);
        let wb = Array.get(ob + 6, bs);
        let rvx = Array.get(ob + 4, bs) - wb * Array.get(o + 5, ps) - Array.get(oa + 4, bs) + wa * Array.get(o + 3, ps);
        let rvy = Array.get(ob + 5, bs) + wb * Array.get(o + 4, ps) - Array.get(oa + 5, bs) - wa * Array.get(o + 2, ps);
        rvx * dx + rvy * dy

    /// 点 k に衝撃 (jx, jy) を掛ける（a から引き、b へ足す）。
    def impulseAt(bs: Array[Float64, r], ps: Array[Float64, r], pab: Array[Int32, r], k: Int32, jx: Float64, jy: Float64): Unit \ r =
        let o = k * sStride();
        let oa = Array.get(k * 2, pab) * bStride();
        let ob = Array.get(k * 2 + 1, pab) * bStride();
        let ima = Array.get(oa + 7, bs);
        let imb = Array.get(ob + 7, bs);
        Array.put(Array.get(oa + 4, bs) - jx * ima, oa + 4, bs);
        Array.put(Array.get(oa + 5, bs) - jy * ima, oa + 5, bs);
        Array.put(Array.get(oa + 6, bs) - (Array.get(o + 2, ps) * jy - Array.get(o + 3, ps) * jx) * Array.get(oa + 8, bs), oa + 6, bs);
        Array.put(Array.get(ob + 4, bs) + jx * imb, ob + 4, bs);
        Array.put(Array.get(ob + 5, bs) + jy * imb, ob + 5, bs);
        Array.put(Array.get(ob + 6, bs) + (Array.get(o + 4, ps) * jy - Array.get(o + 5, ps) * jx) * Array.get(ob + 8, bs), ob + 6, bs)
}
