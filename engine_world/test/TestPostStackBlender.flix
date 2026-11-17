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
        gapsOf(stack, cases) |> List.filter(g -> g#gap > 2)
            |> List.map(g -> "${g#sample#input} → Blender ${g#sample#want} / engine ${g#got}") |> List.take(5)

    /// 帯の全部を 1 枚の絵（幅 = 数）にして本編の面で読み、答えとの 8bit の差（3 成分の大きい方）。
    def gapsOf(stack: PostStack.Stack, cases: List[Case]): List[{ sample = Case, got = (Int32, Int32, Int32), gap = Int32 }] =
        let n = List.length(cases);
        let rgba = cases |> List.flatMap(c -> { let (r, g, b) = c#input; encode(r) :: encode(g) :: encode(b) :: 1.0 :: Nil }) |> List.toVector;
        let present = PostStack.build({ size = { x = 320.0, y = 180.0 }, clear = Color.rgb(0.0, 0.0, 0.0), world = Nil }, stack)#present;
        match present#item {
            case Render.Item.Shader(sh) =>
                let compiled = ShaderEval.compile(ShaderDoc.bindParams(sh#params, sh#spec),
                                                  Map#{ PostStack.sceneName() => TexImage.Rgba16Float(ShaderEval.hdrTextureOf(n, 1, rgba)) });
                List.zipWithIndex(cases) |> List.map(e -> {
                    let (i, c) = e;
                    let (r, g, b, _) = ShaderEval.evalCompiled(compiled, (Int32.toFloat64(i) + 0.5) / Int32.toFloat64(n), 0.5, 0.0);
                    let got = (to8(r), to8(g), to8(b));
                    let (wr, wg, wb) = c#want;
                    let (gr, gg, gb) = got;
                    { sample = c, got = got, gap = Int32.max(Int32.abs(gr - wr), Int32.max(Int32.abs(gg - wg), Int32.abs(gb - wb))) }
                })
            case _ => Nil
        }

    def isGray(c: Case): Bool = let (r, g, b) = c#input; r == g and g == b

    /// AgX の近さ: (灰色で 2/255 を超えた数, 全部の中で 2/255 以内の割合（‰）, 差の最大)。
    def agxCloseness(exposure: Float64, text: String): (Int32, Int32, Int32) =
        let gaps = gapsOf(stackOf(PostStack.ViewTransform.AgX, exposure), casesOf(text));
        let n = Int32.max(1, List.length(gaps));
        (gaps |> List.count(g -> isGray(g#sample) and g#gap > 2),
         List.count(g -> g#gap <= 2, gaps) * 1000 / n,
         gaps |> List.map(g -> g#gap) |> List.maximum |> Option.getWithDefault(0))

    /// 自前の AgX の門: 灰色は全部 2/255 以内・全部の 80% 以上が 2/255 以内・差の最大は 20/255 まで（測った値は露出 0 で 86%・+2 で 83%・−2 で 89%・最大 18/255）
    /// （残る差は彩度 1 の原色の緑と青で、Blender の inset と outset の行列が公開の行列と違う所）。
    def isAgxClose(c: (Int32, Int32, Int32)): Bool = let (grayMisses, within, worst) = c; grayMisses == 0 and within >= 800 and worst <= 20

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

    @Test
    def testAgxIsCloseToBlender(): Unit \ Assert =
        Assert.assertEq(expected = (0, true), { let c = agxCloseness(0.0, PostCurveCases.agxZero()); let (g, _, _) = c; (g, isAgxClose(c)) })

    @Test
    def testAgxPlusTwoStopsIsCloseToBlender(): Unit \ Assert =
        Assert.assertEq(expected = (0, true), { let c = agxCloseness(2.0, PostCurveCases.agxPlusTwo()); let (g, _, _) = c; (g, isAgxClose(c)) })

    @Test
    def testAgxMinusTwoStopsIsCloseToBlender(): Unit \ Assert =
        Assert.assertEq(expected = (0, true), { let c = agxCloseness(-2.0, PostCurveCases.agxMinusTwo()); let (g, _, _) = c; (g, isAgxClose(c)) })
}
