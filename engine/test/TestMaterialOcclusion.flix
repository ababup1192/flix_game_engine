// 材質の AO の絵（Scene3d.withOcclusionTexture）の、光の木の変種 materialOcclusion・材質の部品の metalRough の幅（GLSL・WGSL）・CPU の材質の評価の AO。
mod TestMaterialOcclusion {
    use ShaderDoc.{Field, Shade, Out}
    use LightModel3d.Vec3Input

    def occludedVariant(): LightModel3d.LightVariant = { materialOcclusion = true | LightModel3d.legacyVariant() }

    def glslOf(name: String, tree: LightModel3d.Vec3Expr): String = glslWith(name, Nil, tree)

    /// extra = 位置と法線の後に受ける画素ごとの入力。
    def glslWith(name: String, extra: List[Vec3Input], tree: LightModel3d.Vec3Expr): String =
        LightModel3d.Codegen.toGlsl(name, Vec3Input.Position :: Vec3Input.Normal :: extra, tree)

    def count(substr: String, s: String): Int32 = List.length(String.splitOn({ substr = substr }, s)) - 1

    def materialOcclusionName(): String = "r3d_materialOcclusion"

    /// 変種 materialOcclusion の光の木は、材質の AO を環境の光（ambient + hemisphere）に掛ける（rgb の成分ごとに 1 回・直接光には掛けない）。
    @Test
    def testLightingModelReadsMaterialOcclusionPerChannel(): Unit \ Assert =
        Assert.assertEq(expected = 3, count(materialOcclusionName(), glslOf("lightAt", LightModel3d.lightingModelFor(occludedVariant()))))

    /// SSAO の無い変種の材質の AO は、SSAO の値（r3d_ao・r3d_aoDirect）を木に乗せない。
    @Test
    def testMaterialOcclusionDoesNotReadScreenAo(): Unit \ Assert =
        Assert.assertEq(expected = 0, count("r3d_ao", glslOf("lightAt", LightModel3d.lightingModelFor(occludedVariant()))))

    /// 変種でない光の木は材質の AO を読まない。
    @Test
    def testDefaultLightingModelHasNoMaterialOcclusion(): Unit \ Assert =
        Assert.assertEq(expected = 0, count(materialOcclusionName(), glslOf("lightAt", LightModel3d.lightingModel())))

    /// pbrModel の変種 materialOcclusion は映り込みに材質の AO を掛ける（rgb の成分ごと）。
    @Test
    def testPbrModelOccludesReflection(): Unit \ Assert =
        Assert.assertEq(expected = 3, count(materialOcclusionName(), glslWith("pbrAt", Vec3Input.Albedo :: Vec3Input.Light :: Vec3Input.MetallicRoughness :: Vec3Input.EnvironmentColor :: Nil,
                                                                          LightModel3d.pbrModelFor(occludedVariant()))))

    /// lightmap の面のベイクした光にも材質の AO を掛ける（rgb の成分ごと）。
    @Test
    def testLightmapModelOccludesBakedLight(): Unit \ Assert =
        Assert.assertEq(expected = 3, count(materialOcclusionName(), glslWith("lightmapLightAt", Vec3Input.LightmapColor :: Nil, LightModel3d.lightmapLightingModelFor(occludedVariant()))))

    // ── 材質の部品 ──

    def fill(): ShaderDoc.Spec = { name = "t", cycleRate = 0.0, bindings = Nil, out = Out.Fill({ shade = Shade.Solid({ r = 0.1, g = 0.2, b = 0.3 }), alpha = Field.Const(1.0) }) }

    def metal(): Shade = Shade.Rgb({ r = Field.Const(0.5), g = Field.Const(0.25), b = Field.Const(0.75) })

    /// 材質の AO を読む GLSL の materialEval は metalRough を vec3 で返す（z = AO）。
    @Test
    def testGlslOcclusionReturnsVec3(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "out vec3 metalRough", ShaderGen.compile3d(fill(), None, Some(metal()), true)#functions))

    /// 材質の AO を読まない GLSL の materialEval は vec2（b は読まない）。
    @Test
    def testGlslWithoutOcclusionKeepsVec2(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "out vec2 metalRough", ShaderGen.compile3d(fill(), None, Some(metal()), false)#functions))

    /// 材質の AO を読む WGSL の SgMaterial は metalRough を vec3f で持つ。
    @Test
    def testWgslOcclusionReturnsVec3f(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "metalRough: vec3f", ShaderGen.Wgsl.compile3d(fill(), None, Some(metal()), true, 1)#functions))

    /// 材質の AO を読む WGSL は 3 成分を 0..1 に丸める（端も vec3）。
    @Test
    def testWgslOcclusionClampsThreeChannels(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = ".xyz, vec3(0.0), vec3(1.0))", ShaderGen.Wgsl.compile3d(fill(), None, Some(metal()), true, 1)#functions))

    // ── CPU の材質の評価 ──

    def sampleOf(reads: Bool): ShaderEval.MaterialSample =
        let compiled = ShaderEval.compileMaterial({ spec = fill(), emission = None, metallicRoughness = Some(metal()), readsMaterialOcclusion = reads,
                                                    params = Map.empty(), textures = Map.empty(), repeat = true });
        ShaderEval.evalMaterial3(compiled, { world = { x = 0.0, y = 0.0, z = 0.0 }, normal = { x = 0.0, y = 1.0, z = 0.0 }, uv = { x = 0.0, y = 0.0 },
                                             color = { r = 1.0, g = 1.0, b = 1.0 } }, 0.0)

    /// 材質の AO を読む材質は metallicRoughness の色の b を材質の AO として返す。
    @Test
    def testCpuOcclusionReadsBlue(): Unit \ Assert =
        Assert.assertEq(expected = 0.75, sampleOf(true)#materialOcclusion)

    /// 材質の AO を読まない材質の AO は 1（b を読まない）。
    @Test
    def testCpuWithoutOcclusionIsOne(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, sampleOf(false)#materialOcclusion)
}
