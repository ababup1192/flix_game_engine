// Render3dGlsl.materialFragmentSource が ShaderGen.compile3d の部品を差し込む約束（varying が先・uniforms → functions の順・
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
        let source = Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertTrue(indexOf("in vec3 vNormal;", source) >= 0 and indexOf("in vec3 vNormal;", source) < indexOf("// FUNCTIONS", source))

    /// uniforms は functions より前に置かれる。
    @Test
    def testUniformsBeforeFunctions(): Unit \ Assert =
        let source = Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertTrue(indexOf("// UNIFORMS", source) >= 0 and indexOf("// UNIFORMS", source) < indexOf("// FUNCTIONS", source))

    /// fog は emission を足す前の色に掛かる（r3d_surfaceOut の中でかすみの後に emission × intensity を足す）。
    @Test
    def testEmissionAddedAfterFog(): Unit \ Assert =
        let out = Render3dGlsl.surfaceOutSource();
        Assert.assertTrue(indexOf("if (fogOn) c = fogged(c, p);", out) >= 0 and
                          indexOf("if (fogOn) c = fogged(c, p);", out) < indexOf("c + r3d_srgbToLinear3(emission) * intensity", out))

    /// 色は線形へ戻した albedo × tint × light（頂点の色は掛けない）。
    @Test
    def testAlbedoReplacesVertexColor(): Unit \ Assert =
        Assert.assertTrue(indexOf("r3d_surfaceOut(r3d_srgbToLinear3(albedo.rgb), vTint, light, emission, vEmissionIntensity, vWorld, true)", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// cutout は α が 0.5 未満を捨てる。
    @Test
    def testCutoutDiscardsBelowHalf(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uCutout == 1 && albedo.a < 0.5) discard;", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// 光の式は LightModel3d の木から作った lightAt をそのまま持つ。
    @Test
    def testLightIsGeneratedFromTheTree(): Unit \ Assert =
        let generated = LightModel3d.Codegen.toGlsl("lightAt", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: Nil, LightModel3d.lightingModel());
        Assert.assertTrue(indexOf(generated, Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// 影の無いプログラム（uShadowOn = 0）と、影を落とさないスポットは光を減らさない。
    @Test
    def testShadowOffKeepsFullLight(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (uShadowOn == 0 || i != uShadowSpot) return 1.0;", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// bias を引いた画素の z が地図の値以下なら照らされている。
    @Test
    def testLitWhenBiasedDepthNotBehindMap(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (z <= texelFetch(map, t, 0).r) lit++;", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// 地図の外（NDC の x・y が −1..1 の外）は影にしない。
    @Test
    def testOutsideMapIsLit(): Unit \ Assert =
        Assert.assertTrue(indexOf("if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    // ── 絵つきの材質 ──

    /// 絵 1 枚 × 頂点の色の材質（Scene3d.texturedMaterial）の uv つきの frag。
    def texturedSource(): String =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Linear));
        Render3dGlsl.materialFragmentSource(ShaderGen.compile3d(fields#spec, fields#emission, fields#metallicRoughnessShade), { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })

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
        Assert.assertTrue(indexOf("const vec2 vUv = vec2(0.0, 0.0);", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// uv つきの頂点シェーダーは location 5 の uv と 6 のタンジェントを受け、タンジェントは model の左上 3×3 で写して w に行列式の符号を掛ける。
    @Test
    def testUvVertexSourceCarriesTangent(): Unit \ Assert =
        let source = Render3dGlsl.materialVertexSource({ skinned = false, uv = true, lightmap = false });
        Assert.assertEq(expected = (true, true),
            (indexOf("layout (location = 5) in vec2 aUv;", source) >= 0,
             indexOf("vTangent = vec4(modelLinear * (aTangent.xyz), aTangent.w * sign(determinant(modelLinear)));", source) >= 0))

    /// 骨つきの uv つきの版はタンジェントも skin で曲げる。
    @Test
    def testSkinnedUvVertexSourceBendsTangent(): Unit \ Assert =
        Assert.assertTrue(indexOf("modelLinear * (mat3(skin) * aTangent.xyz)", Render3dGlsl.materialVertexSource({ skinned = true, uv = true, lightmap = false })) >= 0)

    /// uv の無い形の材質の頂点シェーダーは、頂点の色のプログラムと同じ字（uv の無い場面の GLSL を変えない）。
    @Test
    def testUvlessMaterialVertexSourceIsMeshSource(): Unit \ Assert =
        Assert.assertEq(expected = Render3dGlsl.meshVertexSource(), Render3dGlsl.materialVertexSource({ skinned = false, uv = false, lightmap = false }))

    // ── 法線マップ ──

    /// 法線マップつきの uv つきの frag。
    def normalMappedSource(): String =
        let fields = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Nearest));
        Render3dGlsl.materialFragmentSource(ShaderGen.compile3d(fields#spec, fields#emission, fields#metallicRoughnessShade), { skinned = false, uv = true, normalMap = true, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })

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
            (indexOf("vec3 b = cross(n, t) * tangent.w;", source) >= 0, indexOf("vec3 p = t * m.x + b * m.y + n * m.z;", source) >= 0))

    /// Spec の Normal は法線マップを当てる前の法線（sg_normal = normalize(vNormal)）を読む。
    @Test
    def testSpecNormalReadsUnmappedNormal(): Unit \ Assert =
        Assert.assertTrue(indexOf("vec3 sg_normal = normalize(vNormal);", normalMappedSource()) >= 0)

    /// uv の無い形では法線マップを当てない（normalMap が真でも uNormalMap を宣言しない）。
    @Test
    def testUvlessIgnoresNormalMap(): Unit \ Assert =
        Assert.assertEq(expected = -1, indexOf("uNormalMap", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = true, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })))

    /// 骨つきの uv つきの頂点シェーダーは、法線マップに要る vTangent を出す（タンジェントも skin で曲げる）。
    @Test
    def testSkinnedVertexSourceFeedsNormalMap(): Unit \ Assert =
        let vertex = Render3dGlsl.materialVertexSource({ skinned = true, uv = true, lightmap = false });
        Assert.assertEq(expected = (true, true), (indexOf("out vec4 vTangent;", vertex) >= 0, indexOf("mat3(skin) * aTangent.xyz", vertex) >= 0))

    def count(part: String, s: String): Int32 =
        match String.indexOf(substr = part, s) {
            case None    => 0
            case Some(i) => 1 + count(part, String.dropLeft(i + String.length(part), s))
        }

    /// 法線マップと lightmap を両方使い、材質が sg_texMip を持たない時も、sg_texMip の定義は 1 回だけ出る。
    @Test
    def testTexMipIsDefinedOnceWithNormalMapAndLightmap(): Unit \ Assert =
        Assert.assertEq(expected = 1, count("vec4 sg_texMip(", Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })))

    /// lightmap の版は lightmapLightAt に lightmap の絵から読んだ色を渡し、lightAt（環境光と hemisphere を足す方）を main で呼ばない。
    @Test
    def testLightmapUsesBakedLight(): Unit \ Assert =
        Assert.assertTrue(indexOf("vec3 light = lightmapLightAt(vWorld, normalize(vNormal), lightmapColor());",
            Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// lightmap の版の光の式は LightModel3d の木から作った lightmapLightAt をそのまま持つ。
    @Test
    def testBakedLightIsGeneratedFromTheTree(): Unit \ Assert =
        let generated = LightModel3d.Codegen.toGlsl("lightmapLightAt", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.LightmapColor :: Nil,
                                                    LightModel3d.lightmapLightingModel());
        Assert.assertTrue(indexOf(generated, Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0)

    /// lightmap の版の頂点シェーダーは location 7 の 2 本目の uv を vUv2 へ渡す。
    @Test
    def testLightmapVertexPassesUv2(): Unit \ Assert =
        let source = Render3dGlsl.materialVertexSource({ skinned = false, uv = true, lightmap = true });
        Assert.assertTrue(indexOf("layout (location = 7) in vec2 aUv2;", source) >= 0 and indexOf("vUv2 = aUv2;", source) >= 0)

    // ── 材質のプログラムの鍵 ──

    def plainKind(): Render3d.ProgramKind = { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false }

    def keyOf(m: Scene3d.Material3d, kind: Render3d.ProgramKind): String = Render3d.materialKey(Scene3d.materialFieldsOf(m), kind)

    /// 同じ spec の名前でも、emission の有る材質と無い材質・emission の木が違う材質は別の鍵で、同じプログラムを取り合わない。
    @Test
    def testMaterialKeyTellsEmissionApart(): Unit \ Assert =
        let plain = Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear);
        let white = plain |> Scene3d.withEmission(ShaderDoc.Shade.Solid(Color.rgb(1.0, 1.0, 1.0)));
        let red = plain |> Scene3d.withEmission(ShaderDoc.Shade.Solid(Color.rgb(1.0, 0.0, 0.0)));
        Assert.assertEq(expected = 3, List.size(List.distinct(keyOf(plain, plainKind()) :: keyOf(white, plainKind()) :: keyOf(red, plainKind()) :: Nil)))

    /// 読む絵の名前だけが違う材質は同じ鍵（GLSL に出るのは絵の番号だけで、同じプログラムを使い回す）。
    @Test
    def testMaterialKeyIgnoresTextureNames(): Unit \ Assert =
        Assert.assertEq(expected = keyOf(Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear), plainKind()),
                        keyOf(Scene3d.texturedMaterial("tex3d:b", ShaderDoc.FilterMode.Linear), plainKind()))

    /// 半透明・両面・alpha to coverage の版は、それぞれ別の鍵（+bl・+ds・+cov）。
    @Test
    def testMaterialKeyTellsLookVariantsApart(): Unit \ Assert =
        let m = Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear);
        let prefix = (k: String) -> String.takeWhile(c -> c != ':', k);
        Assert.assertEq(expected = ("3d+uv+bl", "3d+uv+ds", "3d+uv+cov"),
            (prefix(keyOf(m, { blend = true | plainKind() })), prefix(keyOf(m, { doubleSided = true | plainKind() })),
             prefix(keyOf(m, { coverage = true | plainKind() }))))

    def sourceOf(look: { blend = Bool, doubleSided = Bool, coverage = Bool, metallicRoughness = Bool }): String =
        Render3dGlsl.materialFragmentSource(glsl(), { skinned = false, uv = false, normalMap = false, lightmap = false,
                                                  blend = look#blend, doubleSided = look#doubleSided, coverage = look#coverage, metallicRoughness = look#metallicRoughness })

    /// 半透明の版は材質の α を出す（ほかの版は 1）。
    @Test
    def testBlendVariantWritesMaterialAlpha(): Unit \ Assert =
        Assert.assertEq(expected = (true, false),
            (indexOf("vWorld, true), albedo.a);", sourceOf({ blend = true, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0,
             indexOf("vWorld, true), albedo.a);", sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = false })) >= 0))

    /// 両面の版は裏の面（!gl_FrontFacing）の法線を裏返して光を計算する。
    @Test
    def testDoubleSidedVariantFlipsBackFaceNormal(): Unit \ Assert =
        let source = sourceOf({ blend = false, doubleSided = true, coverage = false, metallicRoughness = false });
        Assert.assertTrue(indexOf("gl_FrontFacing ? normalize(vNormal) : -normalize(vNormal)", source) >= 0
                          and indexOf("lightAt(vWorld, facingNormal)", source) >= 0)

    /// alpha to coverage の版は discard せず、α を縁の幅で立ち上げて出す。
    @Test
    def testCoverageVariantDoesNotDiscard(): Unit \ Assert =
        let source = sourceOf({ blend = false, doubleSided = false, coverage = true, metallicRoughness = false });
        Assert.assertEq(expected = (-1, true), (indexOf("discard;", source), indexOf("/ max(fwidth(albedo.a), 1e-4) + 0.5", source) >= 0))

    /// metallic と roughness を持つ版は +mr の別の鍵になる。
    @Test
    def testMaterialKeyTellsMetallicRoughnessApart(): Unit \ Assert =
        let m = Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear);
        let prefix = (k: String) -> String.takeWhile(c -> c != ':', k);
        Assert.assertEq(expected = "3d+uv+mr", prefix(keyOf(m, { metallicRoughness = true | plainKind() })))

    /// metallic と roughness を持つ版は、materialEval に metalRough を受けさせ、pbrAt の色をかすみ → emission の組み立てに渡す。
    /// 持たない版はどちらも出さない（持たない材質の GLSL の字は変わらない — TestRender3dGlslPinned の固定が守る）。
    @Test
    def testMetallicRoughnessVariantCallsPbrModel(): Unit \ Assert =
        let glossy = sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = true });
        let plain = sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertEq(expected = (true, true, true, false, false),
            (indexOf("materialEval(albedo, emission, metalRough);", glossy) >= 0,
             indexOf("vec3 lit = pbrAt(vWorld, n, base, light, vec3(metalRough, 0.0), envColor);", glossy) >= 0,
             indexOf("r3d_surfaceOutLit(lit, emission, vEmissionIntensity, vWorld)", glossy) >= 0,
             indexOf("pbrAt", plain) >= 0, indexOf("metalRough", plain) >= 0))

    /// 映り込みの空の uniform は metallic と roughness を持つ版だけが宣言する。
    @Test
    def testReflectionUniformsOnlyInMetallicRoughnessVariant(): Unit \ Assert =
        let glossy = sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = true });
        let plain = sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertEq(expected = (true, false),
            (indexOf("uniform vec3 uZenith;", glossy) >= 0, indexOf("uniform vec3 uZenith;", plain) >= 0))

    /// 環境マップの読みは metallic と roughness を持つ版だけが宣言し、環境マップが無い時（uEnvOn が 1 でない）は絵を読まない。
    @Test
    def testEnvironmentReadOnlyInMetallicRoughnessVariantAndGuarded(): Unit \ Assert =
        let glossy = sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = true });
        let plain = sourceOf({ blend = false, doubleSided = false, coverage = false, metallicRoughness = false });
        Assert.assertEq(expected = (true, true, false),
            (indexOf("uniform sampler2D uEnvMap;", glossy) >= 0, indexOf("if (uEnvOn == 1) envColor = environmentColorAt(", glossy) >= 0,
             indexOf("uEnvMap", plain) >= 0))
}
