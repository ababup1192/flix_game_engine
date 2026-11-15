// ShaderGen.Wgsl と LightModel3d.Codegen.toWgsl の字が、WebGPU の約束（clip の z・描き先の上下・uniformity・暗黙の型変換が無い・
// uniform の配列の 16 バイト刻み）に合わせてあるか。組めるかは render_gl の TestWgslDawn が Dawn で見る。
mod TestShaderGenWgsl {
    use ShaderDoc.{Field, Shade, Out, Axis, TexChan}
    use LightModel3d.Vec3Input

    def fill(bindings: List[(String, Field)], alpha: Field): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = bindings, out = Out.Fill({ shade = Shade.Solid({ r = 0.1, g = 0.2, b = 0.3 }), alpha = alpha }) }

    def texSpec(): ShaderDoc.Spec =
        fill(("s", Field.TexSize({ name = "a", axis = Axis.U })) :: Nil, Field.Tex({ name = "a", chan = TexChan.G }))

    def lightAt(): String =
        LightModel3d.Codegen.toWgsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModel())

    @Test
    def testSurfaceVertexMovesGlClipZIntoZeroToW(): Unit \ Assert =
        let wgsl = ShaderGen.Wgsl.compile(ShaderDoc.demoSurface())#module;
        Assert.assertEq(expected = (true, true),
                        (String.contains(substr = "o.position = sg_clipFromGl(sgFrame.projection * vec4f(screenPos, 0.0, 1.0));", wgsl),
                         String.contains(substr = "(p.z + p.w) * 0.5", ShaderGen.Wgsl.clipFromGlSource())))

    @Test
    def testTextureReadsDoNotFlipRows(): Unit \ Assert =
        Assert.assertFalse(String.contains(substr = "Flip", ShaderGen.Wgsl.compile(texSpec())#module))

    @Test
    def testSurfaceTextureReadsAtLevelZeroNotImplicitDerivatives(): Unit \ Assert =
        let wgsl = ShaderGen.Wgsl.compile(texSpec())#module;
        Assert.assertEq(expected = (true, false),
                        (String.contains(substr = "textureSampleLevel(uTex0, uTex0Sampler, (vUv), 0.0).g", wgsl),
                         String.contains(substr = "textureSample(", wgsl)))

    @Test
    def testTextureSizeIsConvertedToF32Explicitly(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "let sg_b_s = f32(textureDimensions(uTex0, 0).x);", ShaderGen.Wgsl.compile(texSpec())#module))

    @Test
    def testAngleUsesAtan2(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "(atan2((vUv).y - 0.5, (vUv).x - 0.25)",
                                          ShaderGen.Wgsl.compile(fill(Nil, Field.Angle({ cx = 0.25, cy = 0.5 })))#module))

    /// 式は GLSL と同じ所から出る: GLSL の main の出口の文と、WGSL の `let outColor` の右辺が同じ字。
    @Test
    def testOutputExpressionIsTheSameTextAsGlsl(): Unit \ Assert =
        let spec = ShaderDoc.waterVeins();
        let glsl = ShaderGen.compileBody(spec);
        Assert.assertTrue(String.contains(substr = "let " + glsl, ShaderGen.Wgsl.compile(spec)#module))

    @Test
    def testSurfaceSlotsAreTheStructOrder(): Unit \ Assert =
        let out = ShaderGen.Wgsl.compile(fill(Nil, Field.Bin({ op = ShaderDoc.BinOp.Add, a = Field.Param({ name = "p" }), b = Field.Param({ name = "q" }) })));
        let names = out#slots |> List.map(ShaderGen.Wgsl.slotName) |> List.map(n -> n + ": f32") |> List.join(", ");
        Assert.assertTrue(String.contains(substr = "struct SgValues { " + names + " };", out#module) and List.length(out#slots) == 8)

    @Test
    def testMaterialSlotsAreTimeThenLevelsThenParams(): Unit \ Assert =
        let spec = fill(("k", Field.Param({ name = "k" })) :: Nil, Field.Tex({ name = "a", chan = TexChan.A }));
        let m = ShaderGen.Wgsl.compile3d(spec, None, None, 1);
        Assert.assertEq(expected = ShaderGen.Wgsl.UniformSlot.Time :: ShaderGen.Wgsl.UniformSlot.TexLevels(0) :: ShaderGen.Wgsl.UniformSlot.Param(0) :: Nil, m#slots)

    @Test
    def testMaterialMetalRoughnessClampsWithVectorBounds(): Unit \ Assert =
        let m = ShaderGen.Wgsl.compile3d(fill(Nil, Field.Const(1.0)), None, Some(Shade.Solid({ r = 0.5, g = 0.25, b = 0.0 })), 1);
        Assert.assertTrue(String.contains(substr = "metalRough = clamp((vec3(0.5, 0.25, 0.0)).xy, vec2(0.0), vec2(1.0));", m#functions))

    /// 材質の mip のレベルを選ぶ読みの微分（dpdx）は sg_texMip の中だけ（materialEval の頭から呼ばれる）。
    @Test
    def testMaterialDerivativesOnlyInsideTexMip(): Unit \ Assert =
        let m = ShaderGen.Wgsl.compile3d(fill(Nil, Field.Tex({ name = "a", chan = TexChan.A })), None, None, 1);
        Assert.assertEq(expected = 1, List.length(String.splitOn({ substr = "dpdx(" }, m#functions)) - 1)

    @Test
    def testLightLoopBreaksOnTheCountInsideTheFixedBound(): Unit \ Assert =
        let wgsl = lightAt();
        Assert.assertTrue(String.startsWith(prefix = "fn lightAt(p: vec3f, n: vec3f) -> vec3f {", wgsl) and
                          String.contains(substr = "for (var i = 0; i < ${Scene3d.maxPointLights()}; i++) {", wgsl) and
                          String.contains(substr = "if (i >= r3d.uPointCount) { break; }", wgsl))

    /// f32 の光の配列は uniform の配列の 16 バイト刻みに合わせて vec4 の配列に入れ、x を読む。
    @Test
    def testLightRangeReadsTheXOfAVec4Array(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "(r3d.uPointRange[i].x * r3d.uPointRange[i].x)", lightAt()))

    @Test
    def testLightHasNoTernaryOrGlslNames(): Unit \ Assert =
        let wgsl = lightAt();
        Assert.assertEq(expected = (false, false, false),
                        (String.contains(substr = " ? ", wgsl), String.contains(substr = "float", wgsl), String.contains(substr = "inversesqrt", wgsl)))
}
