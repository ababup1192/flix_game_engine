// 画面の上の技（SSAO・+ao）の変種と pass の表を具体値で固定する: +ao の鍵と group 0 の binding・pass の並び・
// 一番多くの絵を読む材質の frag が texture と sampler の約束の 16 を超えないこと。
mod Render3d.TestScreenPasses {

    def plain(): Render3d.ProgramKey.ShaderVariant = Render3d.ProgramKey.defaultShaderVariant()

    def ao(): Render3d.ProgramKey.ShaderVariant = { ambientOcclusion = true | plain() }

    def inputs(show: Bool): Scene3d.ScreenInputs =
        Scene3d.screenInputs({ depth = "d", depthRange = 10.0, ambientOcclusion = Some(ScreenEffects3d.ambientOcclusion()),
                               show = if (show) Some(ScreenEffects3d.ScreenDebug.AmbientOcclusion) else None })

    @Test
    def testAmbientOcclusionKeyIsAo(): Unit \ Assert =
        Assert.assertEq(expected = "+ao", Render3d.ProgramKey.variantKeyOf(ao()))

    @Test
    def testAmbientOcclusionAddsOnlyTheMaskToGroup0(): Unit \ Assert =
        Assert.assertEq(expected = Set#{ Render3d.ProgramKey.Group0Binding.AoMask }, Render3d.ProgramKey.group0Of(ao()))

    @Test
    def testAmbientOcclusionLayoutCodeIsFour(): Unit \ Assert =
        Assert.assertEq(expected = 4, Render3d.WebGpuRenderer.layoutCodeOf(ao()))

    @Test
    def testBillboardKeepsAmbientOcclusion(): Unit \ Assert =
        Assert.assertTrue(Render3d.ProgramKey.billboardVariantOf(ao())#ambientOcclusion)

    @Test
    def testPassesAreMaskThenTwoBlurs(): Unit \ Assert =
        Assert.assertEq(expected = "AoMask" :: "AoBlurH" :: "AoBlurV" :: Nil,
                        Render3d.ScreenPasses.passesOf(inputs(false)) |> List.map(p -> ToString.toString(p#kind)))

    @Test
    def testShowAddsTheShowPassLast(): Unit \ Assert =
        Assert.assertEq(expected = Some("ShowAo"), Render3d.ScreenPasses.passesOf(inputs(true)) |> List.last |> Option.map(p -> ToString.toString(p#kind)))

    @Test
    def testNoAmbientOcclusionHasNoPasses(): Unit \ Assert =
        let none = Scene3d.screenInputs({ depth = "d", depthRange = 10.0, ambientOcclusion = None, show = None });
        Assert.assertEq(expected = 0, List.length(Render3d.ScreenPasses.passesOf(none)))

    // ── texture と sampler の約束（WebGL2 の MAX_TEXTURE_IMAGE_UNITS・WebGPU の maxSampledTexturesPerShaderStage と maxSamplersPerShaderStage はどれも 16） ──

    def count(sub: String, s: String): Int32 =
        String.splitOn({ substr = sub }, s) |> List.length |> (n -> n - 1)

    /// 絵を一番多く読む材質（絵 6 枚・法線マップ・lightmap・PBR の環境マップ）の +ps+ao の版。
    def heaviestKind(): Render3d.ProgramKey.ProgramKind =
        { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = true,
          screenAoOnBlend = false, variant = { pointShadows = true, physicalUnits = true, psx = true, skyIrradiance = true, ambientOcclusion = true } }

    def sixTextures(): ShaderDoc.Spec =
        let tex = (i: Int32) -> ShaderDoc.Field.Tex({ name = "t${i}", chan = ShaderDoc.TexChan.R });
        let sum = List.range(1, 6) |> List.foldLeft((acc, i) -> ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Add, a = acc, b = tex(i) }), tex(0));
        { name = "six", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = sum, g = sum, b = sum }), alpha = ShaderDoc.Field.Const(1.0) }) }

    @Test
    def testHeaviestWgslMaterialStaysWithinSixteenTextures(): Unit \ Assert =
        let source = Render3dWgsl.materialFragmentSource(ShaderGen.Wgsl.compile3d(sixTextures(), None, None, 1), heaviestKind());
        Assert.assertTrue(count("texture_2d", source) + count("texture_depth_2d", source) <= 16)

    @Test
    def testHeaviestWgslMaterialStaysWithinSixteenSamplers(): Unit \ Assert =
        let source = Render3dWgsl.materialFragmentSource(ShaderGen.Wgsl.compile3d(sixTextures(), None, None, 1), heaviestKind());
        Assert.assertTrue(count(": sampler;", source) <= 16)

    @Test
    def testHeaviestGlslMaterialStaysWithinSixteenSamplers(): Unit \ Assert =
        let source = Render3dGlsl.materialFragmentSource(ShaderGen.compile3d(sixTextures(), None, None), heaviestKind());
        Assert.assertTrue(count("uniform sampler2D", source) <= 16)
}
