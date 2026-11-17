// PostStack の曲線の門: 線形の色の帯を view transform と露出に通した 8bit の値が、Blender 5.2.3 の Color Management と 2/255 以内で合う。
// 手本は engine_world/test/gen/PostCurveCases.flix（post_curves_blender.py が Blender で書く）。
// 描き手の Pass は画面の値を持つので、帯は sRGB の曲線で縮めた値の Rgba16Float の絵として本編の面に読ませる（1 を超える所も同じ曲線を延ばす）。
mod TestPostStackBlender {

    use ShaderEval.TexImage

    type alias Case = { input = (Float64, Float64, Float64), want = (Int32, Int32, Int32) }

    def casesOf(text: String): List[Case] =
        String.lines(text) |> List.filterMap(line -> match String.words(line) {
            case r :: g :: b :: wr :: wg :: wb :: Nil =>
                forM (rf <- Float64.fromString(r); gf <- Float64.fromString(g); bf <- Float64.fromString(b);
                      ri <- Int32.fromString(wr); gi <- Int32.fromString(wg); bi <- Int32.fromString(wb))
                yield { input = (rf, gf, bf), want = (ri, gi, bi) }
            case _ => None
        })

    /// 線形の値 → sRGB の曲線で縮めた値（1 を超える所も同じ式）。
    def encode(c: Float64): Float64 =
        if (c <= 0.0031308) c * 12.92 else 1.055 * Float64.pow(base = c, 1.0 / 2.4) - 0.055

    def to8(v: Float64): Int32 = Float64.round(Num.clamp01(v) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    /// 帯の全部を 1 枚の絵（幅 = 数）にして本編の面で読み、答えから 2/255 を超えて離れた物（入力・答え・エンジン）。
    def misses(stack: PostStack.Stack, text: String): List[String] = missesOf(stack, casesOf(text))

    /// Blender の Khronos PBR Neutral は log2 の 2^-9〜2^10 に詰めた LUT で、0 の成分を 2^-9 として読む。暗い色（露出の後の一番明るい成分が 2^-4 未満）で
    /// 成分に 0 があると、一番暗い成分で暗い所を沈める所が式（Khronos の仕様）から最大 6/255 ずれるので、その物は比べない。
    def outsideNeutralLut(exposure: Float64, c: Case): Bool =
        let (r, g, b) = c#input;
        let k = Float64.pow(base = 2.0, exposure);
        Float64.min(r, Float64.min(g, b)) * k < Float64.pow(base = 2.0, -9.0) and Float64.max(r, Float64.max(g, b)) * k < 0.0625

    def neutralMisses(exposure: Float64, text: String): List[String] =
        missesOf(stackOf(PostStack.ViewTransform.KhronosNeutral, exposure), casesOf(text) |> List.filter(c -> not outsideNeutralLut(exposure, c)))

    def missesOf(stack: PostStack.Stack, cases: List[Case]): List[String] =
        let n = List.length(cases);
        let rgba = cases |> List.flatMap(c -> { let (r, g, b) = c#input; encode(r) :: encode(g) :: encode(b) :: 1.0 :: Nil }) |> List.toVector;
        let present = PostStack.build({ size = { x = 320.0, y = 180.0 }, clear = Color.rgb(0.0, 0.0, 0.0), world = Nil }, stack)#present;
        match present#item {
            case Render.Item.Shader(sh) =>
                let compiled = ShaderEval.compile(ShaderDoc.bindParams(sh#params, sh#spec),
                                                  Map#{ PostStack.sceneName() => TexImage.Rgba16Float(ShaderEval.hdrTextureOf(n, 1, rgba)) });
                List.zipWithIndex(cases) |> List.filterMap(e -> {
                    let (i, c) = e;
                    let (r, g, b, _) = ShaderEval.evalCompiled(compiled, (Int32.toFloat64(i) + 0.5) / Int32.toFloat64(n), 0.5, 0.0);
                    let got = (to8(r), to8(g), to8(b));
                    let (wr, wg, wb) = c#want;
                    let (gr, gg, gb) = got;
                    if (Int32.abs(gr - wr) <= 2 and Int32.abs(gg - wg) <= 2 and Int32.abs(gb - wb) <= 2) None
                    else Some("${c#input} → Blender ${c#want} / engine ${got}")
                }) |> List.take(5)
            case _ => "本編の面が Shader 面でない" :: Nil
        }

    def stackOf(v: PostStack.ViewTransform, exposure: Float64): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withViewTransform(v) |> PostStack.withExposure(exposure)

    @Test
    def testStandardMatchesBlender(): Unit \ Assert =
        Assert.assertEq(expected = Nil, misses(stackOf(PostStack.ViewTransform.Standard, 0.0), PostCurveCases.standardZero()))

    @Test
    def testStandardPlusTwoStopsMatchesBlender(): Unit \ Assert =
        Assert.assertEq(expected = Nil, misses(stackOf(PostStack.ViewTransform.Standard, 2.0), PostCurveCases.standardPlusTwo()))

    @Test
    def testStandardMinusTwoStopsMatchesBlender(): Unit \ Assert =
        Assert.assertEq(expected = Nil, misses(stackOf(PostStack.ViewTransform.Standard, -2.0), PostCurveCases.standardMinusTwo()))

    @Test
    def testKhronosNeutralMatchesBlender(): Unit \ Assert =
        Assert.assertEq(expected = Nil, neutralMisses(0.0, PostCurveCases.neutralZero()))

    @Test
    def testKhronosNeutralMinusTwoStopsMatchesBlender(): Unit \ Assert =
        Assert.assertEq(expected = Nil, neutralMisses(-2.0, PostCurveCases.neutralMinusTwo()))

    @Test
    def testKhronosNeutralPlusTwoStopsMatchesBlender(): Unit \ Assert =
        Assert.assertEq(expected = Nil, neutralMisses(2.0, PostCurveCases.neutralPlusTwo()))
}
