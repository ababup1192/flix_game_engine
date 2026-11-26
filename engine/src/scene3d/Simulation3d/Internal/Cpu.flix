// Simulation3d.Internal.Cpu — プリセットの規則の CPU の版（GL・WebGL2・CPU の描き出しとテストが呼ぶ）。
// 群れの 1 刻みは render_gl の kernel と同じ式を Float32 で 1 演算ずつ丸めて書く。近所の和は固定小数点の整数で足す。

/// 状態の並び: 1 個 = 8 個の Float32（位置の xyz・1・速さの xyz・0）。GPU の Boid と同じ並び。
/// GPU とは許し幅で合い（近所の判定の境目と sqrt の丸めで 1 違いうる）、CPU の中では格子と総当たりがバイトで合う。
pub mod Simulation3d.Internal.Cpu {
    use Simulation3d.Internal.{FlockParams, Vec3f, PresetRules}
    use Simulation3d.Internal.Step.{Progress, StepPlan}

    pub def floatsPerElement(): Int32 = 8

    /// 近所の和の 1 項を [-1, 1] に丸めてから掛ける数（2^30）。i32 に収まり、N 項の和は 64 bit に収まる。
    def fixedOne(): Float32 = 1073741824.0f32

    /// 分離の 1 項の大きさの上限（separationRadius ÷ 下限の距離）。
    def separationLimit(): Float32 = 10.0f32

    /// 分離の距離の下限（separationRadius に掛ける）。重なった 2 個で 1/d があふれないように置く。
    def minSeparationFraction(): Float32 = 0.1f32

    // ── Float32 の道具 ──

    def f32Of(x: Float64): Float32 = Float64.truncateToFloat32(x)

    def f64Of(x: Float32): Float64 = Float32.toFloat64(x)

    def sqrtF(x: Float32): Float32 = f32Of(Num.sqrt(f64Of(x)))

    def absF(x: Float32): Float32 = if (x < 0.0f32) -x else x

    def minF(a: Float32, b: Float32): Float32 = if (a < b) a else b

    def maxF(a: Float32, b: Float32): Float32 = if (a > b) a else b

    def clampF(lo: Float32, hi: Float32, x: Float32): Float32 = minF(hi, maxF(lo, x))

    /// x ÷ bound を [-1, 1] に丸め、fixedOne 倍を最も近い整数にする。
    def quantize(x: Float32, bound: Float32): Int64 =
        Int32.toInt64(Float64.truncateToInt32(Float64.round(f64Of(clampF(-1.0f32, 1.0f32, x / bound) * fixedOne()))))

    def velocityBound(p: FlockParams): Float32 = maxF(p#maxSpeed, 0.000001f32) * 2.0f32

    def forRange(i: Int32, end: Int32, f: Int32 -> Unit \ ef): Unit \ ef =
        if (i < end) { f(i); forRange(i + 1, end, f) } else ()

    // ── 初めの状態 ──

    /// p#count 個を箱の中に一様に置き、速さの各成分を ±maxSpeed/2 の一様にした状態（seed ごとに決まる・LCG）。
    pub def initialState(p: FlockParams, seed: Int32): Vector[Float32] = region rc {
        let n = Int32.max(0, p#count);
        let out = Array.repeat(rc, n * floatsPerElement(), 0.0f32);
        let x = Ref.fresh(rc, Int32.toInt64(seed) * -7046029254386353131i64 + 1i64);
        let next = () -> {
            Ref.put(Ref.get(x) * 6364136223846793005i64 + 1442695040888963407i64, x);
            Int64.toFloat32(Int64.logicalRightShift(dist = 40, Ref.get(x))) / 16777216.0f32
        };
        let lo = p#lo;
        let hi = p#hi;
        forRange(0, n, i -> {
            let o = i * floatsPerElement();
            Array.put(lo#x + (hi#x - lo#x) * next(), o, out);
            Array.put(lo#y + (hi#y - lo#y) * next(), o + 1, out);
            Array.put(lo#z + (hi#z - lo#z) * next(), o + 2, out);
            Array.put(1.0f32, o + 3, out);
            Array.put((next() * 2.0f32 - 1.0f32) * p#maxSpeed * 0.5f32, o + 4, out);
            Array.put((next() * 2.0f32 - 1.0f32) * p#maxSpeed * 0.5f32, o + 5, out);
            Array.put((next() * 2.0f32 - 1.0f32) * p#maxSpeed * 0.5f32, o + 6, out)
        });
        Array.toVector(out)
    }

    // ── 1 刻み ──

    /// 近所の和（10 個: 寄る 3・そろう 3・離れる 3・数 1）へ j 個目の寄与を足す。i 個目の位置は (px, py, pz)。
    // WhyNot: 近所を見る数に上限を置かない — 「最初の K 個だけ」はセルの中の並び（GPU では atomic の順）に答えが左右される。
    def addTerm(p: FlockParams, acc: Array[Int64, r], px: Float32, py: Float32, pz: Float32, state: Vector[Float32], j: Int32): Unit \ r =
        let o = j * floatsPerElement();
        let dx = Vector.get(o, state) - px;
        let dy = Vector.get(o + 1, state) - py;
        let dz = Vector.get(o + 2, state) - pz;
        let d2 = dx * dx + dy * dy + dz * dz;
        let radius = p#neighborRadius;
        if (d2 >= radius * radius) ()
        else {
            let add = (k: Int32, v: Int64) -> Array.put(Array.get(k, acc) + v, k, acc);
            add(9, 1i64);
            add(0, quantize(dx, radius)); add(1, quantize(dy, radius)); add(2, quantize(dz, radius));
            let vb = velocityBound(p);
            add(3, quantize(Vector.get(o + 4, state), vb)); add(4, quantize(Vector.get(o + 5, state), vb)); add(5, quantize(Vector.get(o + 6, state), vb));
            let s = p#separationRadius;
            if (d2 < s * s) {
                let dmin = s * minSeparationFraction();
                let k = s / maxF(d2, dmin * dmin);
                add(6, quantize(-dx * k, separationLimit())); add(7, quantize(-dy * k, separationLimit())); add(8, quantize(-dz * k, separationLimit()))
            } else ()
        }

    /// 長さを m までに縮めた (x, y, z)。
    def clampLength(m: Float32, x: Float32, y: Float32, z: Float32): (Float32, Float32, Float32) =
        let l2 = x * x + y * y + z * z;
        if (l2 > m * m) { let k = m / sqrtF(l2); (x * k, y * k, z * k) } else (x, y, z)

    /// 箱の端から margin の内側で中へ向かう力の 1 軸。
    def edgeAlong(p: FlockParams, lo: Float32, hi: Float32, x: Float32): Float32 =
        let m = maxF(p#margin, 0.000001f32);
        let low = clampF(0.0f32, 1.0f32, (lo + m - x) / m);
        let high = clampF(0.0f32, 1.0f32, (x - (hi - m)) / m);
        (low - high) * p#maxForce

    /// 1 軸の押し戻し: (位置, 速さ)。箱を出た物は箱へ戻し、速さを中向きにする。
    def pushBack(lo: Float32, hi: Float32, np: Float32, v: Float32): (Float32, Float32) =
        let v1 = if (np < lo) absF(v) else v;
        let v2 = if (np > hi) -absF(v1) else v1;
        (clampF(lo, hi, np), v2)

    /// i 個目を近所の和 acc から 1 刻み進めて out へ書く。
    def integrate(p: FlockParams, acc: Array[Int64, r], state: Vector[Float32], i: Int32, out: Array[Float32, r]): Unit \ r =
        let o = i * floatsPerElement();
        let px = Vector.get(o, state); let py = Vector.get(o + 1, state); let pz = Vector.get(o + 2, state);
        let vx = Vector.get(o + 4, state); let vy = Vector.get(o + 5, state); let vz = Vector.get(o + 6, state);
        let n = Array.get(9, acc);
        let wide = (k: Int32) -> Int64.toFloat32(Array.get(k, acc));
        let (rx, ry, rz) =
            if (n > 0i64) {
                let inv = 1.0f32 / Int64.toFloat32(n);
                let kc = p#neighborRadius / fixedOne() * inv;
                let ka = velocityBound(p) / fixedOne() * inv;
                let ks = separationLimit() / fixedOne();
                let along = (c: Int32, v: Float32) ->
                    wide(c) * kc * p#cohesion + (wide(c + 3) * ka - v) * p#alignment + wide(c + 6) * ks * p#separation;
                (along(0, vx), along(1, vy), along(2, vz))
            } else (0.0f32, 0.0f32, 0.0f32);
        let (tx, ty, tz) = match p#target {
            case Some(t) =>
                let ax = t#x - px; let ay = t#y - py; let az = t#z - pz;
                let k = p#targetWeight / maxF(sqrtF(ax * ax + ay * ay + az * az), 1.0f32);
                (rx + ax * k, ry + ay * k, rz + az * k)
            case None => (rx, ry, rz)
        };
        let (cx, cy, cz) = clampLength(p#maxForce, tx, ty, tz);
        let sx = cx + edgeAlong(p, p#lo#x, p#hi#x, px);
        let sy = cy + edgeAlong(p, p#lo#y, p#hi#y, py);
        let sz = cz + edgeAlong(p, p#lo#z, p#hi#z, pz);
        let (nvx, nvy, nvz) = clampLength(p#maxSpeed, vx + sx * p#dt, vy + sy * p#dt, vz + sz * p#dt);
        let (qx, wx) = pushBack(p#lo#x, p#hi#x, px + nvx * p#dt, nvx);
        let (qy, wy) = pushBack(p#lo#y, p#hi#y, py + nvy * p#dt, nvy);
        let (qz, wz) = pushBack(p#lo#z, p#hi#z, pz + nvz * p#dt, nvz);
        Array.put(qx, o, out); Array.put(qy, o + 1, out); Array.put(qz, o + 2, out); Array.put(1.0f32, o + 3, out);
        Array.put(wx, o + 4, out); Array.put(wy, o + 5, out); Array.put(wz, o + 6, out); Array.put(0.0f32, o + 7, out)

    def clearAcc(acc: Array[Int64, r]): Unit \ r = forRange(0, 10, k -> Array.put(0i64, k, acc))

    /// 1 軸のセルの番号（箱の外は端のセル）。
    def cellAlong(lo: Float32, size: Float32, cells: Int32, x: Float32): Int32 =
        let c = Float64.floor(f64Of((x - lo) / size));
        Float64.truncateToInt32(Float64.min(Float64.max(c, 0.0), Int32.toFloat64(cells - 1)))

    def cellCoordOf(p: FlockParams, state: Vector[Float32], i: Int32): (Int32, Int32, Int32) =
        let o = i * floatsPerElement();
        (cellAlong(p#lo#x, p#cellSize#x, p#gx, Vector.get(o, state)),
         cellAlong(p#lo#y, p#cellSize#y, p#gy, Vector.get(o + 1, state)),
         cellAlong(p#lo#z, p#cellSize#z, p#gz, Vector.get(o + 2, state)))

    def cellIndexOf(p: FlockParams, c: (Int32, Int32, Int32)): Int32 =
        let (x, y, z) = c;
        x + p#gx * (y + p#gy * z)

    /// 群れを 1 刻み進めた状態（近所は格子で引く。セルの大きさは neighborRadius 以上なので、隣の 27 セルで足りる）。
    pub def stepFlock(p: FlockParams, state: Vector[Float32]): Vector[Float32] = region rc {
        let n = Vector.length(state) / floatsPerElement();
        let cells = p#gx * p#gy * p#gz;
        let cellOf = Array.repeat(rc, n, 0);
        let start = Array.repeat(rc, cells + 1, 0);
        forRange(0, n, i -> {
            let c = cellIndexOf(p, cellCoordOf(p, state, i));
            Array.put(c, i, cellOf);
            Array.put(Array.get(c + 1, start) + 1, c + 1, start)
        });
        forRange(0, cells, c -> Array.put(Array.get(c + 1, start) + Array.get(c, start), c + 1, start));
        let fill = Array.copyOfRange(rc, 0, cells + 1, start);
        let sorted = Array.repeat(rc, Int32.max(n, 1), 0);
        forRange(0, n, i -> {
            let c = Array.get(i, cellOf);
            let at = Array.get(c, fill);
            Array.put(i, at, sorted);
            Array.put(at + 1, c, fill)
        });
        let acc = Array.repeat(rc, 10, 0i64);
        let out = Array.repeat(rc, n * floatsPerElement(), 0.0f32);
        forRange(0, n, i -> {
            clearAcc(acc);
            let o = i * floatsPerElement();
            let px = Vector.get(o, state); let py = Vector.get(o + 1, state); let pz = Vector.get(o + 2, state);
            let (cx, cy, cz) = cellCoordOf(p, state, i);
            forRange(Int32.max(cz - 1, 0), Int32.min(cz + 1, p#gz - 1) + 1, z ->
                forRange(Int32.max(cy - 1, 0), Int32.min(cy + 1, p#gy - 1) + 1, y ->
                    forRange(Int32.max(cx - 1, 0), Int32.min(cx + 1, p#gx - 1) + 1, x -> {
                        let cell = cellIndexOf(p, (x, y, z));
                        forRange(Array.get(cell, start), Array.get(cell + 1, start), s -> {
                            let j = Array.get(s, sorted);
                            if (j != i) addTerm(p, acc, px, py, pz, state, j) else ()
                        })
                    })));
            integrate(p, acc, state, i, out)
        });
        Array.toVector(out)
    }

    /// 群れを 1 刻み進めた状態（総当たり。stepFlock とバイトで同じになる答え。テストだけが呼ぶ）。
    pub def stepFlockBrute(p: FlockParams, state: Vector[Float32]): Vector[Float32] = region rc {
        let n = Vector.length(state) / floatsPerElement();
        let acc = Array.repeat(rc, 10, 0i64);
        let out = Array.repeat(rc, n * floatsPerElement(), 0.0f32);
        forRange(0, n, i -> {
            clearAcc(acc);
            let o = i * floatsPerElement();
            let px = Vector.get(o, state); let py = Vector.get(o + 1, state); let pz = Vector.get(o + 2, state);
            forRange(0, n, j -> if (j != i) addTerm(p, acc, px, py, pz, state, j) else ());
            integrate(p, acc, state, i, out)
        });
        Array.toVector(out)
    }

    /// steps 刻み進めた状態。
    pub def advance(p: FlockParams, steps: Int64, state: Vector[Float32]): Vector[Float32] =
        if (steps <= 0i64) state else advance(p, steps - 1i64, stepFlock(p, state))

    // ── 宣言から ──

    /// 宣言 sim を count 個で解く 1 刻みの値。
    pub def paramsOf(count: Int32, sim: Simulation3d.Simulation3d[k]): FlockParams =
        let r = Simulation3d.Internal.fieldsOf(sim);
        match Simulation3d.Internal.rulesOf(sim) {
            case PresetRules.Flock(rules) => Simulation3d.Internal.flockParamsOf(rules, r#bounds, count)
        }

    /// 宣言 sim の今の時刻の状態を count 個で求める。prev = 前のコマの進みと状態（cache の無い描き手は None）。
    /// 作り直す時は prewarm の始点から、続ける時は前の状態から進める（Simulation3d.Internal.Step.planOf）。
    pub def computeState(count: Int32, prev: Option[(Progress, Vector[Float32])], sim: Simulation3d.Simulation3d[k]): (Progress, Vector[Float32]) =
        let r = Simulation3d.Internal.fieldsOf(sim);
        let p = paramsOf(count, sim);
        let structure = Simulation3d.Internal.structureOf(count, sim);
        let step = Simulation3d.Internal.Step.stepIndexOf(r#time);
        let progress = { step = step, structure = structure };
        match Simulation3d.Internal.Step.planOf(r#prewarmSteps, prev |> Option.map(fst), structure, step) {
            case StepPlan.Reset(_, steps) => (progress, advance(p, steps, initialState(p, r#seed)))
            case StepPlan.Advance(steps) =>
                let before = prev |> Option.map(snd) |> Option.getWithDefault(Vector.empty());
                (progress, advance(p, steps, before))
        }

    /// 宣言 sim の今の時刻の状態（cache の無い描き手の道・数は Simulation3d.Internal.cpuCountOf）。
    pub def stateAt(sim: Simulation3d.Simulation3d[k]): Vector[Float32] =
        snd(computeState(Simulation3d.Internal.cpuCountOf(sim), None, sim))

    // ── 出口 ──

    /// 状態を MultiMesh の並び（1 体 12 個の行優先 3×4・1 体 3 個の sRGB の色）にする。前 = 速さの向き（速さが 0 に近ければ +Z）・
    /// 上 = +Y に近い向き（前が真上・真下に近ければ +X を手がかりにする）。色は速さで明るさを少し変えた白。
    pub def transformsOf(p: FlockParams, state: Vector[Float32]): { transforms = Vector[Float64], colors = Vector[Float64] } = region rc {
        let n = Vector.length(state) / floatsPerElement();
        let t = Array.repeat(rc, n * 12, 0.0);
        let colors = Array.repeat(rc, n * 3, 0.0);
        forRange(0, n, i -> {
            let o = i * floatsPerElement();
            let vx = Vector.get(o + 4, state); let vy = Vector.get(o + 5, state); let vz = Vector.get(o + 6, state);
            let speed2 = vx * vx + vy * vy + vz * vz;
            let (fx, fy, fz) = if (speed2 > 0.000000000001f32) { let k = 1.0f32 / sqrtF(speed2); (vx * k, vy * k, vz * k) } else (0.0f32, 0.0f32, 1.0f32);
            let (hx, hy, hz) = if (absF(fy) > 0.999f32) (1.0f32, 0.0f32, 0.0f32) else (0.0f32, 1.0f32, 0.0f32);
            let (ux, uy, uz) = (hy * fz - hz * fy, hz * fx - hx * fz, hx * fy - hy * fx);
            let rl = 1.0f32 / sqrtF(ux * ux + uy * uy + uz * uz);
            let (rx, ry, rz) = (ux * rl, uy * rl, uz * rl);
            let (upx, upy, upz) = (fy * rz - fz * ry, fz * rx - fx * rz, fx * ry - fy * rx);
            let row = (r: Int32, a: Float32, b: Float32, c: Float32, d: Float32) -> {
                Array.put(f64Of(a), i * 12 + r * 4, t); Array.put(f64Of(b), i * 12 + r * 4 + 1, t);
                Array.put(f64Of(c), i * 12 + r * 4 + 2, t); Array.put(f64Of(d), i * 12 + r * 4 + 3, t)
            };
            row(0, rx, upx, fx, Vector.get(o, state));
            row(1, ry, upy, fy, Vector.get(o + 1, state));
            row(2, rz, upz, fz, Vector.get(o + 2, state));
            let shade = f64Of(0.75f32 + 0.25f32 * clampF(0.0f32, 1.0f32, sqrtF(speed2) / maxF(p#maxSpeed, 0.000001f32)));
            Array.put(shade, i * 3, colors); Array.put(shade, i * 3 + 1, colors); Array.put(shade, i * 3 + 2, colors)
        });
        { transforms = Array.toVector(t), colors = Array.toVector(colors) }
    }
}
