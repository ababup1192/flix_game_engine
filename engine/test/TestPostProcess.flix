// TestPostProcess — トーンマップの曲線の性質・tonemapped の木の形（色の場を 1 回だけ持つ）・FXAA の面の組み方を確かめる。

def solidSpec(c: Color): ShaderDoc.Spec =
    { name = "s", cycleRate = 0.0, bindings = Nil,
      out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(1.0) }) }

def gray(v: Float64): Color = { r = v, g = v, b = v }

def centre(): Vec2.Vec2 = { x = 0.5, y = 0.5 }

/// op・露出・白の点で Solid(v) をトーンマップした r の値。
def mappedR(op: PostProcess.Tonemap, stops: Float64, white: Float64, v: Float64): Float64 =
    ShaderEval.evalPixel(PostProcess.tonemapped(op, stops, white, solidSpec(gray(v))), centre(), 0.0)#r

/// fieldsOf の全部の節のうち、pred に合う物の数。
def countNodes(pred: ShaderDoc.Field -> Bool, spec: ShaderDoc.Spec): Int32 =
    ShaderDoc.fieldsOf(spec) |> List.map(field -> ShaderDoc.foldField((n, node) -> if (pred(node)) n + 1 else n, 0, field)) |> List.sum

def isTex(node: ShaderDoc.Field): Bool = match node {
    case ShaderDoc.Field.Tex(_) => true
    case _                      => false
}

def isUv(node: ShaderDoc.Field): Bool = match node {
    case ShaderDoc.Field.Uv(_) => true
    case _                     => false
}

// ════════════════════════════════════════════════════════════════════
// 曲線
// ════════════════════════════════════════════════════════════════════

/// AcesFitted の黒は黒のまま（0 → 0）。
@Test
def testAcesKeepsBlack(): Unit \ Assert =
    Assert.assertEq(expected = 0.0, mappedR(PostProcess.Tonemap.AcesFitted, 0.0, 4.0, 0.0))

/// AcesFitted は明るいほど明るい（0.5 < 1 < 2 < 3）。
@Test
def testAcesIsMonotonic(): Unit \ Assert =
    let at = v -> mappedR(PostProcess.Tonemap.AcesFitted, 0.0, 4.0, v);
    Assert.assertTrue(at(0.5) < at(1.0) and at(1.0) < at(2.0) and at(2.0) < at(3.0))

/// 白の点（露出 0 で 4.0）で AcesFitted も Reinhard も 1 になる。
@Test
def testWhitePointMapsToOne(): Unit \ Assert =
    let aces = mappedR(PostProcess.Tonemap.AcesFitted, 0.0, 4.0, 4.0);
    let reinhard = mappedR(PostProcess.Tonemap.Reinhard, 0.0, 4.0, 4.0);
    Assert.assertTrue(Float64.abs(aces - 1.0) < 0.0001 and Float64.abs(reinhard - 1.0) < 0.0001)

/// 拡張 Reinhard: x = 1・W = 4 で 1 × (1 + 1/16) / 2 = 0.53125。
@Test
def testReinhardExtendedValue(): Unit \ Assert =
    Assert.assertTrue(Float64.abs(mappedR(PostProcess.Tonemap.Reinhard, 0.0, 4.0, 1.0) - 0.53125) < 0.0001)

/// 露出は 2^stops を掛ける（1 stop 上げた 0.5 は露出 0 の 1.0 と同じ）。
@Test
def testExposureDoublesPerStop(): Unit \ Assert =
    let up = mappedR(PostProcess.Tonemap.Reinhard, 1.0, 4.0, 0.5);
    let plain = mappedR(PostProcess.Tonemap.Reinhard, 0.0, 4.0, 1.0);
    Assert.assertTrue(Float64.abs(up - plain) < 0.0001)

/// 既定の露出と白の点では、8bit の白 1.0 が 0.83〜0.9 になる（AcesFitted）。
@Test
def testDefaultsKeepWhiteNearTop(): Unit \ Assert =
    let v = mappedR(PostProcess.Tonemap.AcesFitted, PostProcess.defaultExposure(), PostProcess.defaultWhitePoint(), 1.0);
    Assert.assertTrue(v >= 0.83 and v <= 0.9)

/// 負の入力は 0 に切ってから曲線に掛ける（Reinhard の 1 + x が 0 を跨いで白に化けない）。
@Test
def testNegativeInputIsBlack(): Unit \ Assert =
    Assert.assertEq(expected = 0.0, mappedR(PostProcess.Tonemap.Reinhard, 0.0, 4.0, -2.0))

/// luma709 は 0.2126 / 0.7152 / 0.0722 の重み（緑だけ 1 なら 0.7152）。
@Test
def testLuma709Weights(): Unit \ Assert =
    let luma = PostProcess.luma709(ShaderDoc.Field.Const(0.0), ShaderDoc.Field.Const(1.0), ShaderDoc.Field.Const(0.0));
    Assert.assertTrue(Float64.abs(ShaderEval.evalField(luma, centre(), 0.0) - 0.7152) < 0.000001)

// ════════════════════════════════════════════════════════════════════
// tonemapped の木の形
// ════════════════════════════════════════════════════════════════════

/// Rgb の 3 本（tex を 1 つずつ）を包んでも、tex の節は 3 つのまま・bindings は pp_ の 6 つが増える。
@Test
def testTonemappedHoldsColourTreeOnce(): Unit \ Assert =
    let tex = chan -> ShaderDoc.Field.Tex({ name = "scene", chan = chan });
    let spec = { name = "s", cycleRate = 0.0, bindings = Nil,
                 out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = tex(ShaderDoc.TexChan.R), g = tex(ShaderDoc.TexChan.G),
                                                                            b = tex(ShaderDoc.TexChan.B) }),
                                            alpha = ShaderDoc.Field.Const(1.0) }) };
    let mapped = PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, 0.4, 4.0, spec);
    Assert.assertEq(expected = (3, 6), (countNodes(isTex, mapped), List.length(mapped#bindings)))

/// Ramp を包むと係数の場は pp_f に 1 回だけ（Uv の節が 1 つ）。
@Test
def testTonemappedRampHoldsFactorOnce(): Unit \ Assert =
    let mapped = PostProcess.tonemapped(PostProcess.Tonemap.Reinhard, 0.0, 4.0, ShaderDoc.demoSurface());
    Assert.assertEq(expected = (1, true), (countNodes(isUv, mapped), List.exists(nf -> fst(nf) == "pp_f", mapped#bindings)))

/// Ramp を包んだ色は、同じ色を Solid で包んだ色と同じ（lo = 0・hi = 1 の u = 0.5 は 0.5 の灰）。
@Test
def testTonemappedRampMatchesSolid(): Unit \ Assert =
    let ramp = { name = "r", cycleRate = 0.0, bindings = Nil,
                 out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Ramp({ lo = gray(0.0), hi = gray(1.0), field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) }),
                                            alpha = ShaderDoc.Field.Const(1.0) }) };
    let viaRamp = ShaderEval.evalPixel(PostProcess.tonemapped(PostProcess.Tonemap.Reinhard, 0.0, 4.0, ramp), centre(), 0.0)#r;
    Assert.assertTrue(Float64.abs(viaRamp - mappedR(PostProcess.Tonemap.Reinhard, 0.0, 4.0, 0.5)) < 0.0001)

/// tonemappedWith の after はトーンマップの後の値を受ける（r と b を入れ替えると、Solid(0, 0, 4) の r が 1）。
@Test
def testTonemappedWithSeesMappedValues(): Unit \ Assert =
    let swap = (r, g, b) -> ShaderDoc.Shade.Rgb({ r = b, g = g, b = r });
    let spec = PostProcess.tonemappedWith(PostProcess.Tonemap.Reinhard, 0.0, 4.0, swap, solidSpec({ r = 0.0, g = 0.0, b = 4.0 }));
    let c = ShaderEval.evalPixel(spec, centre(), 0.0);
    Assert.assertTrue(Float64.abs(c#r - 1.0) < 0.0001 and c#b == 0.0)

/// 包んだ面の名前は曲線・露出・白の点・元の名前を持つ（GPU の program の控えが元の面と取り違えない）。
@Test
def testTonemappedNameCarriesCurveExposureAndWhitePoint(): Unit \ Assert =
    Assert.assertEq(expected = "tonemap:AcesFitted:0.4:4.0:s",
                    PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, 0.4, 4.0, solidSpec(gray(1.0)))#name)

/// u に沿った色の面 spec を包んだ r が、包む前の r を Solid でトーンマップした r と同じか（u = 0.25）。
def matchesSolidAt(spec: ShaderDoc.Spec): Bool =
    let at = { x = 0.25, y = 0.5 };
    let raw = ShaderEval.evalPixel(spec, at, 0.0)#r;
    let mapped = ShaderEval.evalPixel(PostProcess.tonemapped(PostProcess.Tonemap.Reinhard, 0.0, 4.0, spec), at, 0.0)#r;
    Float64.abs(mapped - mappedR(PostProcess.Tonemap.Reinhard, 0.0, 4.0, raw)) < 0.0001

def fillSpec(shade: ShaderDoc.Shade, cycleRate: Float64): ShaderDoc.Spec =
    { name = "u", cycleRate = cycleRate, bindings = Nil,
      out = ShaderDoc.Out.Fill({ shade = shade, alpha = ShaderDoc.Field.Const(1.0) }) }

def alongU(): ShaderDoc.Field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U })

/// Gradient を包んだ色は、包む前の色を Solid で包んだ色と同じ。
@Test
def testTonemappedGradientMatchesSolid(): Unit \ Assert =
    let gradient = ShaderDoc.Shade.Gradient({ stops = (0.0, gray(0.0)) :: (0.5, { r = 0.8, g = 0.2, b = 0.1 }) :: (1.0, gray(1.0)) :: Nil,
                                              field = alongU() });
    Assert.assertTrue(matchesSolidAt(fillSpec(gradient, 0.0)))

/// Cosine を包んだ色は、包む前の色を Solid で包んだ色と同じ。
@Test
def testTonemappedCosineMatchesSolid(): Unit \ Assert =
    let cosine = ShaderDoc.Shade.Cosine({ a = gray(0.5), b = gray(0.5), c = gray(1.0), d = { r = 0.1, g = 0.2, b = 0.3 }, field = alongU() });
    Assert.assertTrue(matchesSolidAt(fillSpec(cosine, 0.0)))

/// cycleRate のある Ramp を、pp_tr を係数にした Ramp を返す after で包むと、往復は 1 回だけ掛かる
/// （lo = 黒・hi = 白の Ramp は係数そのものなので、Rgb で包んだ色と同じ。t = 0.5・cycleRate 0.5 で係数が 0.25 ずれる所）。
@Test
def testTonemappedWithAppliesCycleRateOnce(): Unit \ Assert =
    let cycling = fillSpec(ShaderDoc.Shade.Ramp({ lo = gray(0.0), hi = gray(1.0), field = alongU() }), 0.5);
    let rampAfter = (r, _, _) -> ShaderDoc.Shade.Ramp({ lo = gray(0.0), hi = gray(1.0), field = r });
    let at = { x = 0.1, y = 0.5 };
    let viaRamp = ShaderEval.evalPixel(PostProcess.tonemappedWith(PostProcess.Tonemap.Reinhard, 0.0, 4.0, rampAfter, cycling), at, 0.5)#r;
    let viaRgb = ShaderEval.evalPixel(PostProcess.tonemapped(PostProcess.Tonemap.Reinhard, 0.0, 4.0, cycling), at, 0.5)#r;
    Assert.assertTrue(Float64.abs(viaRamp - viaRgb) < 0.0001)

/// 白の点が 0 以下の Reinhard はそろえない x / (1 + x)（x = 1 で 0.5）。
@Test
def testReinhardNonPositiveWhitePointIsPlain(): Unit \ Assert =
    Assert.assertTrue(Float64.abs(mappedR(PostProcess.Tonemap.Reinhard, 0.0, -2.0, 1.0) - 0.5) < 0.0001)

/// 白の点が 0 以下の AcesFitted はそろえない Narkowicz の式（x = 1 で 2.54 / 3.16）。
@Test
def testAcesNonPositiveWhitePointIsPlain(): Unit \ Assert =
    Assert.assertTrue(Float64.abs(mappedR(PostProcess.Tonemap.AcesFitted, 0.0, -2.0, 1.0) - 2.54 / 3.16) < 0.0001)

// ════════════════════════════════════════════════════════════════════
// FXAA
// ════════════════════════════════════════════════════════════════════

/// fxaaSpec は source を Nearest と Linear の 2 組で読み（寸法は Nearest に相乗り）、tex の節は 27（隣 5 点 × 3 + 向きの 4 点 × 3）。
@Test
def testFxaaReadsTwoUnitsAndTwentySevenTaps(): Unit \ Assert =
    let spec = PostProcess.fxaaSpec("post");
    Assert.assertEq(expected = (("post", ShaderDoc.FilterMode.Nearest) :: ("post", ShaderDoc.FilterMode.Linear) :: Nil, 27),
                    (ShaderDoc.texReads(spec), countNodes(isTex, spec)))

/// fxaaSpec の JSON の往復で GLSL が同じ（Studio で開いて保存しても形が崩れない）。
@Test
def testFxaaSurvivesJsonRoundTrip(): Unit \ Assert =
    let spec = PostProcess.fxaaSpec("post");
    let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
        case Ok(s2) => ShaderGen.compile(s2) == ShaderGen.compile(spec)
        case Err(_) => false
    };
    Assert.assertTrue(same)

/// 平らな絵（4×4 の全部が 0x336699）では入力の色のまま。
@Test
def testFxaaKeepsFlatImage(): Unit \ Assert =
    let flat = ({ width = 4, height = 4, pixels = List.toVector(List.repeat(16, -13408615)) }: ShaderEval.TexData);
    let c = ShaderEval.evalPixelTex(PostProcess.fxaaSpec("post"), { x = 0.375, y = 0.375 }, 0.0, Map#{ "post" => flat });
    Assert.assertTrue(Float64.abs(c#r - 0.2) < 0.001 and Float64.abs(c#g - 0.4) < 0.001 and Float64.abs(c#b - 0.6) < 0.001)

mod TestPostProcessClash {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    /// spec の bindings に pp_ の名前があれば、包まずにそのまま返し、重なった名前を stderr に 1 行知らせる。
    /// 差し替えた後に読んだ数（いつも 0）を spec の名前に混ぜる。
    // WhyNot: 引数無しの純粋な式で包まない — Flix は純粋な式を stderr の差し替えより前へ動かせるので、知らせが差し替える前の stderr に出る。
    @Test
    def testTonemappedLeavesClashingSpecAlone(): Unit \ {Assert, IO} =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let spec = { name = "clash${buf.size()}", cycleRate = 0.0, bindings = ("pp_r", ShaderDoc.Field.Const(1.0)) :: Nil,
                     out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 2.0, g = 2.0, b = 2.0 }), alpha = ShaderDoc.Field.Const(1.0) }) };
        let mapped = PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, 0.4, 4.0, spec);
        System.setErr(old);
        Assert.assertEq(expected = (true, true), (ShaderGen.isSameSpec(spec, mapped), String.contains(substr = "pp_r", buf.toString())))
}
