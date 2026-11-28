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

    /// 式は GLSL と同じ所から出る: GLSL の main の出口の文と、WGSL の `let outColor` の右辺が同じ字（smoothstep と絵の読みと atan の無い面）。
    @Test
    def testOutputExpressionIsTheSameTextAsGlsl(): Unit \ Assert =
        let veins = Field.Warp({ amount = 0.08, scale = 4.0, seed = 7, of = Field.Worley({ scale = 5.0, seed = 42, out = ShaderDoc.WorleyOut.F2mF1 }) });
        let spec = { name = "t", cycleRate = 0.25, bindings = Nil,
                     out = Out.Fill({ shade = Shade.Ramp({ lo = { r = 0.35, g = 0.55, b = 0.6 }, hi = { r = 0.8, g = 0.95, b = 0.98 }, field = veins }),
                                      alpha = Field.Fbm({ octaves = 3, scale = 2.0, seed = 1 }) }) };
        let glsl = ShaderGen.compileBody(spec);
        Assert.assertTrue(String.contains(substr = "let " + glsl, ShaderGen.Wgsl.compile(spec)#module))

    @Test
    def testSurfaceSlotsAreTheStructOrder(): Unit \ Assert =
        let out = ShaderGen.Wgsl.compile(fill(Nil, Field.Bin({ op = ShaderDoc.BinOp.Add, a = Field.Param({ name = "p" }), b = Field.Param({ name = "q" }) })));
        let names = out#slots |> List.map(ShaderGen.Wgsl.slotName) |> List.map(n -> n + ": f32") |> List.join(", ");
        Assert.assertEq(expected = (true, 8), (String.contains(substr = "struct SgValues { " + names + " };", out#module), List.length(out#slots)))

    @Test
    def testMaterialSlotsAreTimeThenLevelsThenParams(): Unit \ Assert =
        let spec = fill(("k", Field.Param({ name = "k" })) :: Nil, Field.Tex({ name = "a", chan = TexChan.A }));
        let m = ShaderGen.Wgsl.compile3d(spec, None, None, false, 1);
        Assert.assertEq(expected = ShaderGen.Wgsl.UniformSlot.Time :: ShaderGen.Wgsl.UniformSlot.TexLevels(0) :: ShaderGen.Wgsl.UniformSlot.Param(0) :: Nil, m#slots)

    @Test
    def testMaterialMetalRoughnessClampsWithVectorBounds(): Unit \ Assert =
        let m = ShaderGen.Wgsl.compile3d(fill(Nil, Field.Const(1.0)), None, Some(Shade.Solid({ r = 0.5, g = 0.25, b = 0.0 })), false, 1);
        Assert.assertTrue(String.contains(substr = "metalRough = clamp((vec3(0.5, 0.25, 0.0)).xy, vec2(0.0), vec2(1.0));", m#functions))

    /// 材質の mip のレベルを選ぶ読みの微分（dpdx）は sg_texMip の中だけ（materialEval の頭から呼ばれる）。
    @Test
    def testMaterialDerivativesOnlyInsideTexMip(): Unit \ Assert =
        let m = ShaderGen.Wgsl.compile3d(fill(Nil, Field.Tex({ name = "a", chan = TexChan.A })), None, None, false, 1);
        Assert.assertEq(expected = 1, List.length(String.splitOn({ substr = "dpdx(" }, m#functions)) - 1)

    @Test
    def testLightLoopBreaksOnTheCountInsideTheFixedBound(): Unit \ Assert =
        let wgsl = lightAt();
        Assert.assertEq(expected = (true, true, true),
                        (String.startsWith(prefix = "fn lightAt(p: vec3f, n: vec3f) -> vec3f {", wgsl),
                         String.contains(substr = "for (var i = 0; i < ${Scene3d.maxPointLights()}; i++) {", wgsl),
                         String.contains(substr = "if (i >= r3d.uPointCount) { break; }", wgsl)))

    /// f32 の光の配列は uniform の配列の 16 バイト刻みに合わせて vec4 の配列に入れ、x を読む。
    @Test
    def testLightRangeReadsTheXOfAVec4Array(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "(r3d.uPointRange[i].x * r3d.uPointRange[i].x)", lightAt()))

    /// 端が定数の smoothstep は sg_smoothstep を通す（端が等しい時に組み込みの smoothstep を定数で呼ばない）。
    @Test
    def testDiskWithZeroFeatherUsesTheEqualEdgeSafeSmoothstep(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "(1.0 - sg_smoothstep(0.3, 0.3, ",
                                          ShaderGen.Wgsl.compile(fill(Nil, Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.0 })))#module))

    @Test
    def testGlslKeepsTheBuiltinSmoothstep(): Unit \ Assert =
        Assert.assertFalse(String.contains(substr = "sg_smoothstep",
                                           ShaderGen.compile(fill(Nil, Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.0 })))))

    /// 影の割合（PCF）を読む側は select に入れず if の文にする（select は選ばない側も計算する）。
    @Test
    def testSpotShadowIsNotComputedInsideSelect(): Unit \ Assert =
        let lines = String.lines(lightAt()) |> List.filter(l -> String.contains(substr = "spotShadow(", l));
        Assert.assertEq(expected = (Nil: List[String]), lines |> List.filter(l -> String.contains(substr = "select(", l)))

    /// 光の式の木の smoothstep も、両端が同じ数なら組み込みの smoothstep を使わず、CPU と同じく端以上で 1 にする。
    @Test
    def testLightSmoothstepWithEqualNumberEndsIsAStep(): Unit \ Assert =
        let y = LightModel3d.ScalarExpr.Y(LightModel3d.Vec3Expr.In(Vec3Input.Normal));
        let s = LightModel3d.ScalarExpr.Smoothstep(LightModel3d.ScalarExpr.Num(0.5), LightModel3d.ScalarExpr.Num(0.5), y);
        let wgsl = LightModel3d.Codegen.toWgsl("f", Vec3Input.Normal :: Nil, LightModel3d.Vec3Expr.Make(s, s, s));
        Assert.assertTrue(String.contains(substr = "select(0.0, 1.0, n.y >= 0.5)", wgsl))

    @Test
    def testLightHasNoTernaryOrGlslNames(): Unit \ Assert =
        let wgsl = lightAt();
        Assert.assertEq(expected = (false, false, false),
                        (String.contains(substr = " ? ", wgsl), String.contains(substr = "float", wgsl), String.contains(substr = "inversesqrt", wgsl)))
}
