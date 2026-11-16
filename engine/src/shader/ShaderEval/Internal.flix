// ShaderEval.Internal — テクスチャの標本（NEAREST・Linear・REPEAT・Rgba16Float）とぼかしの点の巡り。
// 引数は数と列だけで受ける（画素ごと・点ごとに呼ばれるので、レコードを作らず引かない）。

/// ShaderEval の中身。ゲームからは呼ばない（ゲーム向けの関数は ShaderEval にある）。
pub mod ShaderEval.Internal {

    /// ぼかしの点の表（GLSL の sg_blur と同じ点の並び: i 番目は角度 a = i×黄金角・距離 r = √((i+0.5)/taps)）。
    /// 2i 番目に cos(a)·r、2i+1 番目に sin(a)·r（読む点は (u + 2i 番目 × 半径 x, v + 2i+1 番目 × 半径 y)）。
    pub def blurPoints(taps: Int32): Vector[Float64] =
        Vector.range(0, taps) |> Vector.flatMap(i -> {
            let fi = Int32.toFloat64(i);
            let r = Num.sqrt((fi + 0.5) / Int32.toFloat64(taps));
            let a = fi * 2.39996323;
            Vector#{Num.cos(a) * r, Num.sin(a) * r}
        })

    /// ぼかしの標本（点は blurPoints の表）。半径が 0 なら 1 点だけ読む（sg_blur と同じ分岐）。
    pub def blurTex(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, linear: Bool, repeat: Bool, taps: Int32, points: Vector[Float64],
                u: Float64, v: Float64, rx: Float64, ry: Float64): Float64 =
        if (rx == 0.0 and ry == 0.0) sampleTexAs(linear, repeat, w, h, pixels, shift, u, v)
        else blurSum(w, h, pixels, shift, linear, repeat, taps, points, u, v, rx, ry, 0, 0.0) / Int32.toFloat64(taps)

    pub def blurSum(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, linear: Bool, repeat: Bool, taps: Int32, points: Vector[Float64],
                u: Float64, v: Float64, rx: Float64, ry: Float64, i: Int32, acc: Float64): Float64 =
        if (i >= taps) acc
        else {
            let s = sampleTexAs(linear, repeat, w, h, pixels, shift, u + Vector.get(2 * i, points) * rx, v + Vector.get(2 * i + 1, points) * ry);
            blurSum(w, h, pixels, shift, linear, repeat, taps, points, u, v, rx, ry, i + 1, acc + s)
        }

    // ── TexBlurGroup の点の巡り（値の置き場 env[slot + j] が j 番目の shift の値）──

    pub def allSlotsEqual(k: Float64, slot: Int32, j: Int32, n: Int32, env: Array[Float64, r]): Bool \ r =
        if (j >= n) true
        else if (Array.get(slot + j, env) == k) allSlotsEqual(k, slot, j + 1, n, env)
        else false

    /// amount の値が仲間で 1 つ違う時: 仲間ごとに blurTex（env[slot + j] にある自分の amount で）。
    pub def blurGroupEach(w: Int32, h: Int32, pixels: Vector[Int32], shifts: Vector[Int32], repeat: Bool, taps: Int32,
                      points: Vector[Float64], u: Float64, v: Float64, rx: Float64, ry: Float64, slot: Int32, j: Int32,
                      env: Array[Float64, r]): Unit \ r =
        if (j >= Vector.length(shifts)) ()
        else {
            let k = Array.get(slot + j, env);
            Array.put(blurTex(w, h, pixels, Vector.get(j, shifts), false, repeat, taps, points, u, v, rx * k, ry * k), slot + j, env);
            blurGroupEach(w, h, pixels, shifts, repeat, taps, points, u, v, rx, ry, slot, j + 1, env)
        }

    /// amount の値が仲間で同じ時: 点を 1 回巡り、点ごとに全部の shift を足す（足す順は shift ごとに blurSum と同じ）。
    pub def blurGroupSame(w: Int32, h: Int32, pixels: Vector[Int32], shifts: Vector[Int32], repeat: Bool, taps: Int32,
                      points: Vector[Float64], u: Float64, v: Float64, rx: Float64, ry: Float64, slot: Int32, env: Array[Float64, r]): Unit \ r =
        let n = Vector.length(shifts);
        putSlots(0.0, slot, 0, n, env);
        if (rx == 0.0 and ry == 0.0) addTap(w, h, pixels, shifts, repeat, u, v, slot, env)
        else {
            blurGroupSum(w, h, pixels, shifts, repeat, taps, points, u, v, rx, ry, slot, 0, env);
            divideSlots(Int32.toFloat64(taps), slot, 0, n, env)
        }

    pub def putSlots(value: Float64, slot: Int32, j: Int32, n: Int32, env: Array[Float64, r]): Unit \ r =
        if (j >= n) () else { Array.put(value, slot + j, env); putSlots(value, slot, j + 1, n, env) }

    pub def divideSlots(d: Float64, slot: Int32, j: Int32, n: Int32, env: Array[Float64, r]): Unit \ r =
        if (j >= n) () else { Array.put(Array.get(slot + j, env) / d, slot + j, env); divideSlots(d, slot, j + 1, n, env) }

    pub def blurGroupSum(w: Int32, h: Int32, pixels: Vector[Int32], shifts: Vector[Int32], repeat: Bool, taps: Int32,
                     points: Vector[Float64], u: Float64, v: Float64, rx: Float64, ry: Float64, slot: Int32, i: Int32,
                     env: Array[Float64, r]): Unit \ r =
        if (i >= taps) ()
        else {
            addTap(w, h, pixels, shifts, repeat, u + Vector.get(2 * i, points) * rx, v + Vector.get(2 * i + 1, points) * ry, slot, env);
            blurGroupSum(w, h, pixels, shifts, repeat, taps, points, u, v, rx, ry, slot, i + 1, env)
        }

    /// (u, v) を NEAREST の sampleTexAs と同じテクセルで読み、shift ごとの値を env[slot + j] に足す（テクセルは 1 回だけ引く）。
    /// 寸法が 0 の絵は 0 を足すのと同じなので何もしない。
    pub def addTap(w: Int32, h: Int32, pixels: Vector[Int32], shifts: Vector[Int32], repeat: Bool, u: Float64, v: Float64,
               slot: Int32, env: Array[Float64, r]): Unit \ r =
        if (w <= 0 or h <= 0) ()
        else {
            let su = if (repeat) wrapUnit(u) else u;
            let sv = if (repeat) wrapUnit(v) else v;
            let ix = clampTexel(Float64.floor(su * Int32.toFloat64(w)), w);
            let iy = clampTexel(Float64.floor(sv * Int32.toFloat64(h)), h);
            addChannels(shifts, Vector.get(iy * w + ix, pixels), slot, 0, env)
        }

    pub def addChannels(shifts: Vector[Int32], argb: Int32, slot: Int32, j: Int32, env: Array[Float64, r]): Unit \ r =
        if (j >= Vector.length(shifts)) ()
        else {
            Array.put(Array.get(slot + j, env) + channelOf(Vector.get(j, shifts), argb), slot + j, env);
            addChannels(shifts, argb, slot, j + 1, env)
        }

    /// 8bit の画素 argb の、shift から始まる 8bit を 0..1 にした値。
    // WhyNot: Int32.logicalRightShift を使わない — 名前つき引数（dist =）の record をテクセルごとに作って引く。
    // 算術シフトでも、shift が 0..24 なら下の 8bit は同じ。
    pub def channelOf(shift: Int32, argb: Int32): Float64 =
        Int32.toFloat64(Int32.bitwiseAnd(Int32.rightShift(argb, shift), 255)) / 255.0

    pub def sampleTexAs(linear: Bool, repeat: Bool, w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        if (linear and not repeat) sampleTexLinear(w, h, pixels, shift, u, v)
        else if (not linear and not repeat) sampleTex(w, h, pixels, shift, u, v)
        else if (linear) sampleTexLinearRepeat(w, h, pixels, shift, wrapUnit(u), wrapUnit(v))
        else sampleTex(w, h, pixels, shift, wrapUnit(u), wrapUnit(v))

    /// 座標を 0..1 へ戻す（GL の REPEAT と同じ fract）。
    pub def wrapUnit(x: Float64): Float64 = x - Float64.floor(x)

    /// Linear の REPEAT の標本（GL の GL_LINEAR + REPEAT と同じ）。0..1 へ戻した座標で、端をまたぐ 4 テクセルは反対の端から読む。
    pub def sampleTexLinearRepeat(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        sampleLinearWith(true, w, h, pixels, shift, u, v)

    /// texel 添字を [0, n−1] へ回す（REPEAT。−1 は n−1・n は 0）。floor 済みの値を受ける。
    pub def wrapTexel(x: Float64, n: Int32): Int32 =
        let k = texelIndexOf(x);
        Int32.remainder(Int32.remainder(k, n) + n, n)

    /// Linear の標本（GL の GL_LINEAR + CLAMP_TO_EDGE と同じ点・同じ重み）。テクセルの中心が (i+0.5)/w なので
    /// 読む点から 0.5 引いた所の左下の 4 テクセルを、端に張り付けて、はみ出した分の割合で混ぜる。
    /// GPU は重みを固定小数（たいてい 8bit）に丸めるので ±1/255 程度ずれうる（docs/backend-parity.md の近似の行）。
    pub def sampleTexLinear(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        sampleLinearWith(false, w, h, pixels, shift, u, v)

    /// Linear の 4 テクセルを混ぜる（repeat なら端をまたぐテクセルは反対の端から・偽なら端に張り付ける）。
    // WhyNot: テクセルを読む閉包（at）を作らない — 画素ごとに閉包を作って 6 回呼ぶ。
    def sampleLinearWith(repeat: Bool, w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else {
            let x = u * Int32.toFloat64(w) - 0.5;
            let y = v * Int32.toFloat64(h) - 0.5;
            let x0 = Float64.floor(x);
            let y0 = Float64.floor(y);
            let fx = x - x0;
            let fy = y - y0;
            let ix0 = edgeTexel(repeat, x0, w);
            let ix1 = edgeTexel(repeat, x0 + 1.0, w);
            let row0 = edgeTexel(repeat, y0, h) * w;
            let row1 = edgeTexel(repeat, y0 + 1.0, h) * w;
            let a00 = channelOf(shift, Vector.get(row0 + ix0, pixels));
            let a10 = channelOf(shift, Vector.get(row0 + ix1, pixels));
            let a01 = channelOf(shift, Vector.get(row1 + ix0, pixels));
            let a11 = channelOf(shift, Vector.get(row1 + ix1, pixels));
            let top = a00 + (a10 - a00) * fx;
            let bottom = a01 + (a11 - a01) * fx;
            top + (bottom - top) * fy
        }

    def edgeTexel(repeat: Bool, x: Float64, n: Int32): Int32 = if (repeat) wrapTexel(x, n) else clampTexel(x, n)

    /// テクスチャ標本（NEAREST + CLAMP の釘打ち式 — GL と同じ量子化になるのが backend-parity の契約）。
    /// ix = clamp(floor(u*w), 0, w−1)・iy 同様。チャンネル値は 8bit を 255 で割った 0..1。
    pub def sampleTex(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else {
            let ix = clampTexel(Float64.floor(u * Int32.toFloat64(w)), w);
            let iy = clampTexel(Float64.floor(v * Int32.toFloat64(h)), h);
            let argb = Vector.get(iy * w + ix, pixels);
            channelOf(shift, argb)
        }

    /// texel 添字を [0, n−1] に張り付ける（CLAMP）。floor 済みの値を受ける。
    pub def clampTexel(x: Float64, n: Int32): Int32 =
        Int32.max(0, Int32.min(n - 1, texelIndexOf(x)))

    /// floor 済みの x の Int32（Int32 の外・無限大・NaN は 0）。
    // WhyNot: Float64.tryToInt32 |> Option.getWithDefault(0) と書かない — テクセルごとに Option を作る。値は同じ。
    def texelIndexOf(x: Float64): Int32 =
        if (x >= -2147483648.0 and x <= 2147483647.0) Float64.truncateToInt32(x) else 0

}
