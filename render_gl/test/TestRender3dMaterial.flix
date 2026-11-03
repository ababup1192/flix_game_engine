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
        let source = Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false });
        Assert.assertTrue(indexOf("in vec3 vNormal;", source) >= 0 and indexOf("in vec3 vNormal;", source) < indexOf("// FUNCTIONS", source))

    /// uniforms は functions より前に置かれる。
    @Test
    def testUniformsBeforeFunctions(): Unit \ Assert =
        let source = Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false });
        Assert.assertTrue(indexOf("// UNIFORMS", source) >= 0 and indexOf("// UNIFORMS", source) < indexOf("// FUNCTIONS", source))

    /// fog は emission を足す前の色に掛かる。
    @Test
    def testEmissionAddedAfterFog(): Unit \ Assert =
        Assert.assertTrue(indexOf("fogged(c, vWorld) + emission", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// 色は albedo × tint × light（頂点の色は掛けない）。
    @Test
    def testAlbedoReplacesVertexColor(): Unit \ Assert =
        Assert.assertTrue(indexOf("albedo.rgb * uTint * lightAt(", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// cutout は α が 0.5 未満を捨てる。
    @Test
    def testCutoutDiscardsBelowHalf(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uCutout == 1 && albedo.a < 0.5) discard;", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// 影はスポットの光だけに掛かる（点光源の項には掛からない）。
    @Test
    def testShadowMultipliesSpotTerm(): Unit \ Assert =
        Assert.assertTrue(indexOf("* cone * spotShadow(i, p);", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// 点光源の項は影を受けない。
    @Test
    def testPointTermHasNoShadow(): Unit \ Assert =
        Assert.assertTrue(indexOf("attenuation(d2, uPointRange[i]) * clamp(dot(n, l), 0.0, 1.0);", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// 影の無いプログラム（uShadowOn = 0）と、影を落とさないスポットは光を減らさない。
    @Test
    def testShadowOffKeepsFullLight(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uShadowOn == 0 || i != uShadowSpot) return 1.0;", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// bias を引いた画素の z が地図の値以下なら照らされている。
    @Test
    def testLitWhenBiasedDepthNotBehindMap(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (z <= texelFetch(uShadowMap, t, 0).r) lit++;", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// 地図の外（NDC の x・y が −1..1 の外）は影にしない。
    @Test
    def testOutsideMapIsLit(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    // ── 絵つきの材質 ──

    /// 絵 1 枚 × 頂点の色の材質（Scene3d.texturedMaterial）の uv つきの frag。
    def texturedSource(): String =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Linear));
        Render3d.materialFragmentSource(ShaderGen.compile3d(fields#spec, fields#emission), { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })

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
        Assert.assertTrue(indexOf("const vec2 vUv = vec2(0.0, 0.0);", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// uv つきの頂点シェーダーは location 5 の uv と 6 のタンジェントを受け、タンジェントは uModel の左上 3×3 で写して w に行列式の符号を掛ける。
    @Test
    def testUvVertexSourceCarriesTangent(): Unit \ Assert =
        let source = Render3d.materialVertexSource({ skinned = false, uv = true, lightmap = false });
        Assert.assertEq(expected = (true, true),
            (indexOf("layout (location = 5) in vec2 aUv;", source) >= 0,
             indexOf("vTangent = vec4(modelLinear * (aTangent.xyz), aTangent.w * sign(determinant(modelLinear)));", source) >= 0))

    /// 骨つきの uv つきの版はタンジェントも skin で曲げる。
    @Test
    def testSkinnedUvVertexSourceBendsTangent(): Unit \ Assert =
        Assert.assertTrue(indexOf("modelLinear * (mat3(skin) * aTangent.xyz)", Render3d.materialVertexSource({ skinned = true, uv = true, lightmap = false })) >= 0)

    /// uv の無い形の材質の頂点シェーダーは、頂点の色のプログラムと同じ字（uv の無い場面の GLSL を変えない）。
    @Test
    def testUvlessMaterialVertexSourceIsMeshSource(): Unit \ Assert =
        Assert.assertEq(expected = Render3d.meshVertexSource(), Render3d.materialVertexSource({ skinned = false, uv = false, lightmap = false }))

    // ── 法線マップ ──

    /// 法線マップつきの uv つきの frag。
    def normalMappedSource(): String =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Nearest));
        Render3d.materialFragmentSource(ShaderGen.compile3d(fields#spec, fields#emission), { skinned = false, uv = true, normalMap = true, lightmap = false, blend = false, doubleSided = false, coverage = false })

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
        Assert.assertEq(expected = -1, indexOf("uNormalMap", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = true, lightmap = false, blend = false, doubleSided = false, coverage = false })))

    /// 骨つきの uv つきの頂点シェーダーは、法線マップに要る vTangent を出す（タンジェントも skin で曲げる）。
    @Test
    def testSkinnedVertexSourceFeedsNormalMap(): Unit \ Assert =
        let vertex = Render3d.materialVertexSource({ skinned = true, uv = true, lightmap = false });
        Assert.assertEq(expected = (true, true), (indexOf("out vec4 vTangent;", vertex) >= 0, indexOf("mat3(skin) * aTangent.xyz", vertex) >= 0))

    def count(part: String, s: String): Int32 =
        match String.indexOf(substr = part, s) {
            case None    => 0
            case Some(i) => 1 + count(part, String.dropLeft(i + String.length(part), s))
        }

    /// 法線マップと lightmap を両方使い、材質が sg_texMip を持たない時も、sg_texMip の定義は 1 回だけ出る。
    @Test
    def testTexMipIsDefinedOnceWithNormalMapAndLightmap(): Unit \ Assert =
        Assert.assertEq(expected = 1, count("vec4 sg_texMip(", Render3d.materialFragmentSource(glsl(), { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false })))

    /// lightmap の版は lightBakedAt で光を求め、lightAt（環境光と hemisphere を足す方）を main で呼ばない。
    @Test
    def testLightmapUsesBakedLight(): Unit \ Assert =
        Assert.assertTrue(indexOf("albedo.rgb * uTint * lightBakedAt(vWorld, normalize(vNormal), bakedLight())",
            Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// lightBakedAt は環境光と hemisphere を足さずに、ベイクした光から始める。
    @Test
    def testBakedLightStartsWithoutAmbient(): Unit \ Assert =
        Assert.assertTrue(indexOf("vec3 lightBakedAt(vec3 p, vec3 n, vec3 baked) {\n    vec3 light = baked;\n",
            Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false })) >= 0)

    /// lightmap の版の頂点シェーダーは location 7 の 2 本目の uv を vUv2 へ渡す。
    @Test
    def testLightmapVertexPassesUv2(): Unit \ Assert =
        let source = Render3d.materialVertexSource({ skinned = false, uv = true, lightmap = true });
        Assert.assertTrue(indexOf("layout (location = 7) in vec2 aUv2;", source) >= 0 and indexOf("vUv2 = aUv2;", source) >= 0)

    // ── 材質のプログラムの鍵 ──

    def plainKind(): Render3d.ProgramKind = { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false }

    /// 同じ spec の名前でも、emission の有る材質と無い材質は別の鍵（+em）で、同じプログラムを取り合わない。
    @Test
    def testMaterialKeyTellsEmissionApart(): Unit \ Assert =
        let plain = Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear);
        let glowing = plain |> Scene3d.withEmission(ShaderDoc.Shade.Solid(Color.rgb(1.0, 1.0, 1.0)));
        Assert.assertEq(expected = ("3d+uv:scene3d:textured:Linear", "3d+uv+em:scene3d:textured:Linear"),
            (Render3d.materialKey(Scene3d.materialFieldsOf(plain), plainKind()), Render3d.materialKey(Scene3d.materialFieldsOf(glowing), plainKind())))

    /// 半透明・両面・alpha to coverage の版は、それぞれ別の鍵（+bl・+ds・+cov）。
    @Test
    def testMaterialKeyTellsLookVariantsApart(): Unit \ Assert =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear));
        Assert.assertEq(expected = ("3d+uv+bl:scene3d:textured:Linear", "3d+uv+ds:scene3d:textured:Linear", "3d+uv+cov:scene3d:textured:Linear"),
            (Render3d.materialKey(fields, { blend = true | plainKind() }), Render3d.materialKey(fields, { doubleSided = true | plainKind() }),
             Render3d.materialKey(fields, { coverage = true | plainKind() })))

    def sourceOf(look: { blend = Bool, doubleSided = Bool, coverage = Bool }): String =
        Render3d.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false,
                                                  blend = look#blend, doubleSided = look#doubleSided, coverage = look#coverage })

    /// 半透明の版は材質の α を出す（ほかの版は 1）。
    @Test
    def testBlendVariantWritesMaterialAlpha(): Unit \ Assert =
        Assert.assertEq(expected = (true, false),
            (indexOf("+ emission, albedo.a);", sourceOf({ blend = true, doubleSided = false, coverage = false })) >= 0,
             indexOf("+ emission, albedo.a);", sourceOf({ blend = false, doubleSided = false, coverage = false })) >= 0))

    /// 両面の版は裏の面（!gl_FrontFacing）の法線を裏返して光を計算する。
    @Test
    def testDoubleSidedVariantFlipsBackFaceNormal(): Unit \ Assert =
        let source = sourceOf({ blend = false, doubleSided = true, coverage = false });
        Assert.assertTrue(indexOf("gl_FrontFacing ? normalize(vNormal) : -normalize(vNormal)", source) >= 0
                          and indexOf("lightAt(vWorld, facingNormal)", source) >= 0)

    /// alpha to coverage の版は discard せず、α を縁の幅で立ち上げて出す。
    @Test
    def testCoverageVariantDoesNotDiscard(): Unit \ Assert =
        let source = sourceOf({ blend = false, doubleSided = false, coverage = true });
        Assert.assertEq(expected = (-1, true), (indexOf("discard;", source), indexOf("/ max(fwidth(albedo.a), 1e-4) + 0.5", source) >= 0))
}
