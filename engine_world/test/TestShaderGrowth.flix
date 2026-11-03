// TestShaderGrowth — ShaderGen が組む GLSL の割り当てが、Doc の要素数に比例したままかを見る。
//
// 時間ではなくバイト数で見るので、熱・JIT・GC・マシンの速さに動かされない
// （engine_world の TestAllocGrowth と同じ測り方）。絶対バイト数は JDK やエスケープ解析で
// 動くので pin せず、要素数を 8 倍にしたとき割り当てが何倍に増えるかだけを見る。
// 比例なら 8 倍前後・二乗なら 64 倍前後で、線はその間に引く。
//
// 測るのは compile ではなく compileBody。compile は Spec に依らない prelude（4592 文字）を
// 必ず含むので、その固定ぶんが二乗の項を薄めて閾値の下に隠す。

/// n 個の区切りを持つグラデーションの Spec の GLSL 本体。
/// 区切りは位置だけ動かし、色は固定（色の桁数で長さが揺れないように）。
def gradientBody(n: Int32): Int32 =
    let stops = List.range(0, n) |> List.map(i ->
        (Int32.toFloat64(i) / Int32.toFloat64(n), { r = 0.5, g = 0.5, b = 0.5 }));
    ShaderGen.compileBody({ name = "g", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Gradient({
                stops = stops, field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) }),
            alpha = ShaderDoc.Field.Const(1.0) }) })
    |> String.length

/// n 本の binding を持つ Spec の GLSL 本体。
/// 各 binding の式は Uv 1 つに固定（式の重さでなく本数だけを動かす）。
def bindingsBody(n: Int32): Int32 =
    let bs = List.range(0, n) |> List.map(i ->
        ("b${i}", ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U })));
    ShaderGen.compileBody({ name = "g", cycleRate = 0.0, bindings = bs,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.5, g = 0.5, b = 0.5 }),
            alpha = ShaderDoc.Field.Const(1.0) }) })
    |> String.length

/// 指数 n の Pow を持つ Spec の GLSL 本体（整数指数なので反復積の文字列になる）。
def powBody(n: Int32): Int32 =
    ShaderGen.compileBody({ name = "g", cycleRate = 0.0, bindings = Nil,
        out = ShaderDoc.Out.Fill({
            shade = ShaderDoc.Shade.Solid({ r = 0.5, g = 0.5, b = 0.5 }),
            alpha = ShaderDoc.Field.Pow({
                of = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }),
                p = Int32.toFloat64(n) }) }) })
    |> String.length

def growthRatio(f: Int32 -> Int32): Float64 =
    let small = AllocMeter.measureBytes(3, _ -> f(100));
    let large = AllocMeter.measureBytes(3, _ -> f(800));
    Int64.toFloat64(large) / Int64.toFloat64(small)


/// 割り当てバイト数を読める JVM である（読めないと以下は 0 しか見ない）
@Test
def testShaderAllocMeterIsEnabled(): Unit \ Assert =
    Assert.assertTrue(AllocMeter.isThreadAllocatedMemoryEnabled())

/// グラデーションの GLSL の割り当ては、区切りの数に比例する。
@Test
def testGradientAllocatesLinearlyInStopCount(): Unit \ Assert =
    Assert.assertTrue(growthRatio(gradientBody) < 16.0)

/// binding の GLSL の割り当ては、binding の本数に比例する。
@Test
def testBindingsAllocateLinearlyInBindingCount(): Unit \ Assert =
    Assert.assertTrue(growthRatio(bindingsBody) < 16.0)

/// 整数指数の反復積の割り当ては、指数に比例する。
@Test
def testPowAllocatesLinearlyInExponent(): Unit \ Assert =
    Assert.assertTrue(growthRatio(powBody) < 16.0)

/// 現実的に凝った Doc 1 枚（binding 8 本・区切り 6 個のグラデ・pow 4・Warp/Worley 入り）。
/// 「ゲーム作者が水面や空を真面目に書いたらこのくらい」の代表として置く。
def elaborateSpec(): ShaderDoc.Spec =
    let veins = ShaderDoc.Field.Warp({ amount = 0.15, scale = 3.0, seed = 7,
        of = ShaderDoc.Field.Worley({ scale = 6.0, seed = 3, out = ShaderDoc.WorleyOut.F2mF1 }) });
    let bs =
        ("base",  veins) ::
        ("soft",  ShaderDoc.Field.Smoothstep({ lo = 0.1, hi = 0.6, of = ShaderDoc.Field.Ref("base") })) ::
        ("clouds", ShaderDoc.Field.Fbm({ octaves = 4, scale = 2.0, seed = 11 })) ::
        ("mixed", ShaderDoc.Field.Blend({ a = ShaderDoc.Field.Ref("soft"),
                                          b = ShaderDoc.Field.Ref("clouds"),
                                          by = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.V }) })) ::
        ("sharp", ShaderDoc.Field.Pow({ of = ShaderDoc.Field.Ref("mixed"), p = 4.0 })) ::
        ("glint", ShaderDoc.Field.Glints({ scale = 20.0, rate = 0.5, density = 0.3, seed = 5 })) ::
        ("ripple", ShaderDoc.Field.Ripples({ freq = 12.0, amp = 0.05, speed = 1.0, seed = 2 })) ::
        ("final", ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add,
                                        a = ShaderDoc.Field.Ref("sharp"),
                                        b = ShaderDoc.Field.Ref("glint") })) :: Nil;
    let stops =
        (0.0, { r = 0.02, g = 0.05, b = 0.12 }) ::
        (0.25, { r = 0.05, g = 0.20, b = 0.35 }) ::
        (0.45, { r = 0.10, g = 0.40, b = 0.55 }) ::
        (0.65, { r = 0.30, g = 0.65, b = 0.70 }) ::
        (0.85, { r = 0.70, g = 0.90, b = 0.88 }) ::
        (1.0,  { r = 0.95, g = 0.98, b = 1.0 }) :: Nil;
    { name = "elaborate", cycleRate = 0.3, bindings = bs,
      out = ShaderDoc.Out.Fill({
          shade = ShaderDoc.Shade.Gradient({ stops = stops, field = ShaderDoc.Field.Ref("final") }),
          alpha = ShaderDoc.Field.Ref("ripple") }) }

/// compile 1 回の割り当ては、Doc がどれだけ凝っていても Spec 非依存の prelude が支配する。
/// 凝った Doc（binding 8 本・区切り 6 個・pow 4）でも、素の Doc の 4 倍を超えない
/// （実測 1.23 倍）。超えたら Spec 依存の側が支配に回ったということで、
/// キャッシュのキーの持ち方（docs/performance.md の要相談の表）を測り直す合図。
@Test
def testCompileIsDominatedByPrelude(): Unit \ Assert =
    let plain = AllocMeter.measureBytes(3, _ -> String.length(ShaderGen.compile(ShaderDoc.demoSurface())));
    let rich = AllocMeter.measureBytes(3, _ -> String.length(ShaderGen.compile(elaborateSpec())));
    Assert.assertTrue(Int64.toFloat64(rich) / Int64.toFloat64(plain) < 4.0)
