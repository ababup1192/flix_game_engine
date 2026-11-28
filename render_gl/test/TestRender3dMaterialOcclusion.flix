// 材質の AO（Scene3d.withOcclusionTexture）の材質の frag（GLSL・WGSL）: ARM の絵の共有・materialEval の z を r3d_materialOcclusion へ入れる文・
// 光の木の +occ の変種・AO の無い材質の字・プログラムの鍵と字の表の鍵。
mod Render3d.TestRender3dMaterialOcclusion {

    def kindOf(materialOcclusion: Bool): Render3d.ProgramKey.ProgramKind =
        { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false,
          metallicRoughness = true, screenAoOnBlend = false, materialOcclusion = materialOcclusion, variant = Render3d.ProgramKey.defaultShaderVariant() }

    def armMaterial(): Scene3d.MaterialFields =
        Scene3d.texturedMaterial("tex3d:base", ShaderDoc.FilterMode.Linear)
            |> Scene3d.withMetallicRoughnessTexture("tex3d:arm")
            |> Scene3d.withOcclusionTexture("tex3d:arm", 1.0)
            |> Scene3d.materialFieldsOf

    def plainMaterial(): Scene3d.MaterialFields =
        Scene3d.texturedMaterial("tex3d:base", ShaderDoc.FilterMode.Linear) |> Scene3d.withMetallicRoughnessTexture("tex3d:arm") |> Scene3d.materialFieldsOf

    def glslOf(m: Scene3d.MaterialFields, kind: Render3d.ProgramKey.ProgramKind): String =
        Render3dGlsl.materialFragmentSource(ShaderGen.compile3d(m#spec, m#emission, m#metallicRoughnessShade, kind#materialOcclusion), kind)

    def wgslOf(m: Scene3d.MaterialFields, kind: Render3d.ProgramKey.ProgramKind): String =
        Render3dWgsl.materialFragmentSource(ShaderGen.Wgsl.compile3d(m#spec, m#emission, m#metallicRoughnessShade, kind#materialOcclusion, 1), kind)

    def assignment(): String = "r3d_materialOcclusion = metalRough.z;"

    /// ARM の絵は occlusion と metallicRoughness で 1 組（base と arm の 2 組）。
    @Test
    def testArmIsOneTextureRead(): Unit \ Assert =
        Assert.assertEq(expected = "tex3d:base" :: "tex3d:arm" :: Nil, Scene3d.materialTexReadsOf(armMaterial()) |> List.map(fst))

    /// AO の付いた GLSL の frag は metalRough を vec3 で受ける。
    @Test
    def testGlslReceivesVec3MetalRough(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "vec3 metalRough;", glslOf(armMaterial(), kindOf(true))))

    /// AO の付いた GLSL の frag は光の前に z を r3d_materialOcclusion へ入れる。
    @Test
    def testGlslAssignsMaterialOcclusion(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = assignment(), glslOf(armMaterial(), kindOf(true))))

    /// AO の付いた WGSL の frag も z を r3d_materialOcclusion へ入れる。
    @Test
    def testWgslAssignsMaterialOcclusion(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = assignment(), wgslOf(armMaterial(), kindOf(true))))

    /// AO の付いた frag の光の式は、SSAO の無い場面で直接光の SSAO の値（r3d_aoDirect）を読まない。
    @Test
    def testOcclusionWithoutSsaoDoesNotReadScreenAo(): Unit \ Assert =
        Assert.assertFalse(String.contains(substr = "r3d_aoDirect", glslOf(armMaterial(), kindOf(true))))

    /// AO の無い材質の frag は metalRough が vec2 のまま。
    @Test
    def testNoOcclusionKeepsVec2(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "vec2 metalRough;", glslOf(plainMaterial(), kindOf(false))))

    /// AO の無い材質の frag は材質の AO を読まない。
    @Test
    def testNoOcclusionDoesNotReadMaterialOcclusion(): Unit \ Assert =
        Assert.assertFalse(String.contains(substr = "r3d_materialOcclusion", glslOf(plainMaterial(), kindOf(false))))

    /// lightmap の面の AO も lightmapLightAt の +occ の変種で読む。
    @Test
    def testLightmapOcclusionReadsMaterialOcclusion(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "r3d_materialOcclusion", glslOf(armMaterial(), { lightmap = true | kindOf(true) })))

    /// プログラムの鍵は AO の有無で分かれる。
    @Test
    def testMaterialKeyTellsOcclusionApart(): Unit \ Assert =
        Assert.assertTrue(Render3d.ProgramKey.materialKey(armMaterial(), kindOf(true)) != Render3d.ProgramKey.materialKey(armMaterial(), kindOf(false)))

    /// 書き出しの字の表の鍵も AO の有無で分かれる（ブラウザで違う字を引かない）。
    @Test
    def testSourceKeyTellsOcclusionApart(): Unit \ Assert =
        let keyOf = (k: Render3d.ProgramKey.ProgramKind) -> Render3d.ShaderSourceKey.toKeyString(Render3d.ShaderSourceKey.MaterialFragmentTemplate(k, true));
        Assert.assertTrue(keyOf(kindOf(true)) != keyOf(kindOf(false)))
}
