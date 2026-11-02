// Render3d.materialFragmentSource が ShaderGen.compile3d の部品を差し込む約束（varying が先・uniforms → functions の順・
// albedo に光を掛けてから emission を足す）を固定するテスト。GL は呼ばず、組み上がった GLSL の字だけを見る。

mod TestRender3dMaterial {

    def glsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n// UNIFORMS\n", functions = "// FUNCTIONS\nvoid materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def indexOf(part: String, s: String): Int32 =
        String.indexOf(substr = part, s) |> Option.getWithDefault(-1)

    /// vNormal の宣言は材質の関数より前にある。
    @Test
    def testVaryingDeclaredBeforeFunctions(): Unit \ Assert =
        let source = Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false });
        Assert.assertTrue(indexOf("in vec3 vNormal;", source) >= 0 and indexOf("in vec3 vNormal;", source) < indexOf("// FUNCTIONS", source))

    /// uniforms は functions より前に置かれる。
    @Test
    def testUniformsBeforeFunctions(): Unit \ Assert =
        let source = Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false });
        Assert.assertTrue(indexOf("// UNIFORMS", source) >= 0 and indexOf("// UNIFORMS", source) < indexOf("// FUNCTIONS", source))

    /// fog は emission を足す前の色に掛かる。
    @Test
    def testEmissionAddedAfterFog(): Unit \ Assert =
        Assert.assertTrue(indexOf("fogged(c, vWorld) + emission", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// 色は albedo × tint × light（頂点の色は掛けない）。
    @Test
    def testAlbedoReplacesVertexColor(): Unit \ Assert =
        Assert.assertTrue(indexOf("albedo.rgb * uTint * lightAt(", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// cutout は α が 0.5 未満を捨てる。
    @Test
    def testCutoutDiscardsBelowHalf(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uCutout == 1 && albedo.a < 0.5) discard;", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// 影はスポットの光だけに掛かる（点光源の項には掛からない）。
    @Test
    def testShadowMultipliesSpotTerm(): Unit \ Assert =
        Assert.assertTrue(indexOf("* cone * spotShadow(i, p);", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// 点光源の項は影を受けない。
    @Test
    def testPointTermHasNoShadow(): Unit \ Assert =
        Assert.assertTrue(indexOf("attenuation(d2, uPointRange[i]) * clamp(dot(n, l), 0.0, 1.0);", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// 影の無いプログラム（uShadowOn = 0）と、影を落とさないスポットは光を減らさない。
    @Test
    def testShadowOffKeepsFullLight(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uShadowOn == 0 || i != uShadowSpot) return 1.0;", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// bias を引いた画素の z が地図の値以下なら照らされている。
    @Test
    def testLitWhenBiasedDepthNotBehindMap(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (z <= texelFetch(uShadowMap, t, 0).r) lit++;", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// 地図の外（NDC の x・y が −1..1 の外）は影にしない。
    @Test
    def testOutsideMapIsLit(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    // ── 絵つきの材質 ──

    /// 絵 1 枚 × 頂点の色の材質（Scene3d.texturedMaterial）の uv つきの frag。
    def texturedSource(): String =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Linear));
        Render3d.materialFragmentSource(ShaderGen.compile3d(fields#spec, fields#emission), { uv = true, normalMap = false })

    /// 絵つきの材質の frag は uTex0 を宣言し、vUv（varying）で読む。
    @Test
    def testTexturedFragmentDeclaresSamplerAndUv(): Unit \ Assert =
        let source = texturedSource();
        Assert.assertEq(expected = (true, true, true),
            (indexOf("uniform sampler2D uTex0;", source) >= 0, indexOf("in vec2 vUv;", source) >= 0,
             indexOf("sg_texMip(uTex0, uTexFlip0, uTexLevels0, (sg_uv))", source) >= 0))

    /// 頂点の色（vColor）と uv（vUv）の宣言は材質の関数より前にある。
    @Test
    def testTexturedVaryingsDeclaredBeforeFunctions(): Unit \ Assert =
        let source = texturedSource();
        let fns = indexOf("void materialEval(", source);
        Assert.assertTrue(indexOf("in vec3 vColor;", source) >= 0 and indexOf("in vec3 vColor;", source) < fns
            and indexOf("in vec2 vUv;", source) < fns)

    /// 絵つきの材質は絵の r に頂点の色の r を掛ける。
    @Test
    def testTexturedFragmentMultipliesVertexColor(): Unit \ Assert =
        Assert.assertTrue(indexOf(".r * vColor.r)", texturedSource()) >= 0)

    /// uv の無い形の frag では vUv は (0, 0) の const。
    @Test
    def testUvlessFragmentUsesConstUv(): Unit \ Assert =
        Assert.assertTrue(indexOf("const vec2 vUv = vec2(0.0, 0.0);", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = false })) >= 0)

    /// uv つきの頂点シェーダーは location 5 の uv と 6 のタンジェントを受け、タンジェントは uModel の左上 3×3 で写して w に行列式の符号を掛ける。
    @Test
    def testUvVertexSourceCarriesTangent(): Unit \ Assert =
        let source = Render3d.materialVertexSource({ skinned = false, uv = true });
        Assert.assertEq(expected = (true, true),
            (indexOf("layout (location = 5) in vec2 aUv;", source) >= 0,
             indexOf("vTangent = vec4(modelLinear * (aTangent.xyz), aTangent.w * sign(determinant(modelLinear)));", source) >= 0))

    /// 骨つきの uv つきの版はタンジェントも skin で曲げる。
    @Test
    def testSkinnedUvVertexSourceBendsTangent(): Unit \ Assert =
        Assert.assertTrue(indexOf("modelLinear * (mat3(skin) * aTangent.xyz)", Render3d.materialVertexSource({ skinned = true, uv = true })) >= 0)

    /// uv の無い形の材質の頂点シェーダーは、頂点の色のプログラムと同じ字（uv の無い場面の GLSL を変えない）。
    @Test
    def testUvlessMaterialVertexSourceIsMeshSource(): Unit \ Assert =
        Assert.assertEq(expected = Render3d.meshVertexSource(), Render3d.materialVertexSource({ skinned = false, uv = false }))

    // ── 法線マップ ──

    /// 法線マップつきの uv つきの frag。
    def normalMappedSource(): String =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Nearest));
        Render3d.materialFragmentSource(ShaderGen.compile3d(fields#spec, fields#emission), { uv = true, normalMap = true })

    /// 法線マップつきの frag は uNormalMap と vTangent を宣言し、光の計算に傾けた法線を渡す。
    @Test
    def testNormalMappedFragmentLightsWithMappedNormal(): Unit \ Assert =
        let source = normalMappedSource();
        Assert.assertEq(expected = (true, true, true),
            (indexOf("uniform sampler2D uNormalMap;", source) >= 0, indexOf("in vec4 vTangent;", source) >= 0,
             indexOf("lightAt(vWorld, normalMapped(normalize(vNormal)))", source) >= 0))

    /// 傾ける式は B = cross(N, T) × w・緑（c.y）を B に掛ける（OpenGL 流）。
    @Test
    def testNormalMapUsesBitangentFromCrossAndW(): Unit \ Assert =
        let source = normalMappedSource();
        Assert.assertEq(expected = (true, true),
            (indexOf("vec3 b = cross(n, t) * vTangent.w;", source) >= 0, indexOf("vec3 p = t * m.x + b * m.y + n * m.z;", source) >= 0))

    /// Spec の Normal は法線マップを当てる前の法線（sg_normal = normalize(vNormal)）を読む。
    @Test
    def testSpecNormalReadsUnmappedNormal(): Unit \ Assert =
        Assert.assertTrue(indexOf("vec3 sg_normal = normalize(vNormal);", normalMappedSource()) >= 0)

    /// uv の無い形では法線マップを当てない（normalMap が真でも uNormalMap を宣言しない）。
    @Test
    def testUvlessIgnoresNormalMap(): Unit \ Assert =
        Assert.assertEq(expected = -1, indexOf("uNormalMap", Render3d.materialFragmentSource(glsl(), { uv = false, normalMap = true })))

    /// 骨つきの uv つきの頂点シェーダーは、法線マップに要る vTangent を出す（タンジェントも skin で曲げる）。
    @Test
    def testSkinnedVertexSourceFeedsNormalMap(): Unit \ Assert =
        let vertex = Render3d.materialVertexSource({ skinned = true, uv = true });
        Assert.assertEq(expected = (true, true), (indexOf("out vec4 vTangent;", vertex) >= 0, indexOf("mat3(skin) * aTangent.xyz", vertex) >= 0))
}
