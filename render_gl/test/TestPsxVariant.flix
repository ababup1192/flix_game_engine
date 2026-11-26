// PS1 風の変種（+psx）のプログラム: 場面から変種を選ぶ・奥行きの書き出しは既定・鍵・GLSL と WGSL の字（頂点の丸め・アフィンの uv・色の丸め）・
// 既定の変種の字が変わらないこと（既定の字の sha は TestPointShadowVariants と TestGlslPinned が固定する）。
mod Render3d.TestPsxVariant {

    def has(part: String, s: String): Bool = String.contains(substr = part, s)

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    def plain(): Scene3d.Scene3dCmd = Scene3d.scene(camera(), Vec2.v2(320.0, 240.0))

    def psxScene(): Scene3d.Scene3dCmd = Scene3d.withPsx(Scene3d.psxPreset(), plain())

    def psx(): Render3d.ShaderVariant = { pointShadows = false, physicalUnits = false, psx = true, skyIrradiance = false }

    def kind(uv: Bool): Render3d.ProgramKind =
        { skinned = false, uv = uv, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false,
          metallicRoughness = false, pointShadows = false, physicalUnits = false, psx = true, skyIrradiance = false }

    def solidGlsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n", functions = "void materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def solidWgsl(): ShaderGen.Wgsl.MaterialWgsl =
        { declarations = "", functions = "fn materialEval(vUv: vec2f, vWorld: vec3f, vNormal: vec3f, vColor: vec3f) -> SgMaterial {}\n",
          slots = Nil, paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    // ── 変種を選ぶ ──

    @Test
    def testPlainSceneIsDefaultVariant(): Unit \ Assert =
        Assert.assertEq(expected = "", Render3d.variantKeyOf(Render3d.shaderVariantOf(plain())))

    @Test
    def testPsxSceneKeyIsPsx(): Unit \ Assert =
        Assert.assertEq(expected = "+psx", Render3d.variantKeyOf(Render3d.shaderVariantOf(psxScene())))

    @Test
    def testDepthOutputDropsPsx(): Unit \ Assert =
        let depth = { output = Scene3d.Output.Depth({ near = 0.0, range = 10.0 }) | psxScene() };
        Assert.assertFalse(Render3d.passVariantOf(depth)#psx)

    @Test
    def testBillboardKeepsPsx(): Unit \ Assert =
        Assert.assertTrue(Render3d.billboardVariantOf({ pointShadows = true | psx() })#psx)

    @Test
    def testPsxUsesLightLayout(): Unit \ Assert =
        Assert.assertEq(expected = 1, Render3d.WebGpuRenderer.layoutCodeOf(psx()))

    @Test
    def testPsxWithPointShadowsUsesShadowLayout(): Unit \ Assert =
        Assert.assertEq(expected = 2, Render3d.WebGpuRenderer.layoutCodeOf({ pointShadows = true | psx() }))

    // ── GLSL ──

    @Test
    def testGlslPsxVertexSnaps(): Unit \ Assert =
        Assert.assertTrue(has("gl_Position = r3d_vertexSnap(", Render3dGlsl.litVertexSourceFor(false, psx())))

    @Test
    def testGlslDefaultVertexDoesNotSnap(): Unit \ Assert =
        Assert.assertFalse(has("r3d_vertexSnap", Render3dGlsl.litVertexSource(false)))

    @Test
    def testGlslMaterialVertexWithoutPsxIsUnchanged(): Unit \ Assert =
        let k = { skinned = true, uv = true, lightmap = false };
        Assert.assertEq(expected = Render3dGlsl.materialVertexSource(k), Render3dGlsl.materialVertexSourceFor(k, false))

    @Test
    def testGlslMaterialVertexSendsAffineUv(): Unit \ Assert =
        Assert.assertTrue(has("    vUvAffine = vec3(aUv * gl_Position.w, gl_Position.w);\n", Render3dGlsl.materialVertexSourceFor({ skinned = false, uv = true, lightmap = false }, true)))

    @Test
    def testGlslMaterialVertexWritesAffineUvAfterPosition(): Unit \ Assert =
        let source = Render3dGlsl.materialVertexSourceFor({ skinned = false, uv = true, lightmap = false }, true);
        let position = String.indexOf(substr = "    gl_Position = ", source) |> Option.getWithDefault(-1);
        let affine = String.indexOf(substr = "    vUvAffine = ", source) |> Option.getWithDefault(-1);
        Assert.assertTrue(position >= 0 and position < affine)

    @Test
    def testGlslMaterialFragmentMixesUvBeforeEval(): Unit \ Assert =
        let source = Render3dGlsl.materialFragmentSource(solidGlsl(), kind(true));
        let mix = String.indexOf(substr = "    vUv = mix(vUvPerspective, vUvAffine.xy / vUvAffine.z, uPsx.w);\n", source) |> Option.getWithDefault(-1);
        let eval = String.indexOf(substr = "    materialEval(albedo, emission);\n", source) |> Option.getWithDefault(-1);
        Assert.assertTrue(mix >= 0 and mix < eval)

    @Test
    def testGlslMaterialFragmentQuantizesColor(): Unit \ Assert =
        Assert.assertTrue(has("fragColor = vec4(r3d_colorDepth(r3d_surfaceOut(", Render3dGlsl.materialFragmentSource(solidGlsl(), kind(false))))

    @Test
    def testGlslBillboardQuantizesColor(): Unit \ Assert =
        Assert.assertTrue(has("r3d_colorDepth(", Render3dGlsl.billboardFragmentSourceFor(psx())))

    // ── WGSL ──

    @Test
    def testWgslPsxDeclaresLightBuffer(): Unit \ Assert =
        Assert.assertTrue(has("var<uniform> r3dLight: R3dLight;", Render3dWgsl.variantDeclarations(psx())))

    @Test
    def testWgslMaterialFragmentMixesUv(): Unit \ Assert =
        Assert.assertTrue(has("let vUv = mix(i.vUv, i.vUvAffine, r3dLight.uPsx.w);", Render3dWgsl.materialFragmentSource(solidWgsl(), kind(true))))

    @Test
    def testWgslLitVertexWithoutPsxIsUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = Render3dWgsl.litVertexSource(true), Render3dWgsl.litVertexSourceFor(true, false))

    @Test
    def testWgslVertexSnapsBeforeClipFromGl(): Unit \ Assert =
        Assert.assertTrue(has("sg_clipFromGl(r3d_vertexSnap(", Render3dWgsl.materialVertexSourceFor(true, false, true, true)))
}
