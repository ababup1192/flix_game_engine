// Render3d.materialFragmentSource が ShaderGen.compile3d の部品を差し込む約束（varying が先・uniforms → functions の順・
// albedo に光を掛けてから emission を足す）を固定するテスト。GL は呼ばず、組み上がった GLSL の字だけを見る。

mod TestRender3dMaterial {

    def glsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n// UNIFORMS\n", functions = "// FUNCTIONS\nvoid materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil }

    def indexOf(part: String, s: String): Int32 =
        String.indexOf(substr = part, s) |> Option.getWithDefault(-1)

    /// vNormal の宣言は材質の関数より前にある。
    @Test
    def testVaryingDeclaredBeforeFunctions(): Unit \ Assert =
        let source = Render3d.materialFragmentSource(glsl());
        Assert.assertTrue(indexOf("in vec3 vNormal;", source) >= 0 and indexOf("in vec3 vNormal;", source) < indexOf("// FUNCTIONS", source))

    /// uniforms は functions より前に置かれる。
    @Test
    def testUniformsBeforeFunctions(): Unit \ Assert =
        let source = Render3d.materialFragmentSource(glsl());
        Assert.assertTrue(indexOf("// UNIFORMS", source) >= 0 and indexOf("// UNIFORMS", source) < indexOf("// FUNCTIONS", source))

    /// fog は emission を足す前の色に掛かる。
    @Test
    def testEmissionAddedAfterFog(): Unit \ Assert =
        Assert.assertTrue(indexOf("fogged(c, vWorld) + emission", Render3d.materialFragmentSource(glsl())) >= 0)

    /// 色は albedo × tint × light（頂点の色は掛けない）。
    @Test
    def testAlbedoReplacesVertexColor(): Unit \ Assert =
        Assert.assertTrue(indexOf("albedo.rgb * uTint * lightAt(", Render3d.materialFragmentSource(glsl())) >= 0)

    /// cutout は α が 0.5 未満を捨てる。
    @Test
    def testCutoutDiscardsBelowHalf(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uCutout == 1 && albedo.a < 0.5) discard;", Render3d.materialFragmentSource(glsl())) >= 0)

    /// 影はスポットの光だけに掛かる（点光源の項には掛からない）。
    @Test
    def testShadowMultipliesSpotTerm(): Unit \ Assert =
        Assert.assertTrue(indexOf("* cone * spotShadow(i, p);", Render3d.materialFragmentSource(glsl())) >= 0)

    /// 点光源の項は影を受けない。
    @Test
    def testPointTermHasNoShadow(): Unit \ Assert =
        Assert.assertTrue(indexOf("attenuation(d2, uPointRange[i]) * clamp(dot(n, l), 0.0, 1.0);", Render3d.materialFragmentSource(glsl())) >= 0)

    /// 影の無いプログラム（uShadowOn = 0）と、影を落とさないスポットは光を減らさない。
    @Test
    def testShadowOffKeepsFullLight(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uShadowOn == 0 || i != uShadowSpot) return 1.0;", Render3d.materialFragmentSource(glsl())) >= 0)

    /// bias を引いた画素の z が地図の値以下なら照らされている。
    @Test
    def testLitWhenBiasedDepthNotBehindMap(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (z <= texelFetch(uShadowMap, t, 0).r) lit++;", Render3d.materialFragmentSource(glsl())) >= 0)

    /// 地図の外（NDC の x・y が −1..1 の外）は影にしない。
    @Test
    def testOutsideMapIsLit(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;", Render3d.materialFragmentSource(glsl())) >= 0)

}
