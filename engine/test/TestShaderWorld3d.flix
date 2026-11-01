// ShaderDoc の World / Normal（3D の材質の入力）と、それを読む ShaderGen.compile3d・ShaderEval の 3D の口のテスト。
// 生の値を見たいので、読む場は α の席に置く（色の席は 0..1 に丸められる）。
mod TestShaderWorld3d {
    use ShaderDoc.Field
    use ShaderDoc.Shade
    use ShaderDoc.Out
    use ShaderDoc.Axis3
    use ShaderDoc.BinOp

    // ── 素材 ──────────────────────────────────────────────

    def grey(): Color = { r = 0.5, g = 0.5, b = 0.5 }

    /// 場 1 本を α の席に載せた Spec。
    def alphaSpec(f: Field): ShaderDoc.Spec =
        { name = "t", cycleRate = 0.0, bindings = Nil, out = Out.Fill({ shade = Shade.Solid(grey()), alpha = f }) }

    def world(axis: Axis3): Field = Field.World({ axis = axis })

    def normal(axis: Axis3): Field = Field.Normal({ axis = axis })

    def v3(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = { x = x, y = y, z = z }

    def alphaOf(rgba: (Float64, Float64, Float64, Float64)): Float64 =
        let (_, _, _, a) = rgba;
        a

    /// 3D の画素 1 つの α（tex 無し・Param 無しで組み直す）。
    def alpha3(spec: ShaderDoc.Spec, at: Vec3.Vec3, n: Vec3.Vec3): Float64 =
        alphaOf(ShaderEval.evalCompiled3(ShaderEval.compile(spec, Map.empty()), at, n, 0.0))

    def up(): Vec3.Vec3 = v3(0.0, 1.0, 0.0)

    // ════════════════════════════════════════════════════════════════════
    // CPU（ShaderEval）
    // ════════════════════════════════════════════════════════════════════

    /// World.x は画素の world の点の x をそのまま返す（y・z とは別の値にして取り違えを見分ける）。
    @Test
    def testEvalCompiled3WorldXReadsWorldPointX(): Unit \ Assert =
        Assert.assertEq(expected = 0.5, alpha3(alphaSpec(world(Axis3.X)), v3(0.5, 10.0, 50.0), up()))

    /// Normal.y は法線の y を返す（下向きの法線なら -1）。
    @Test
    def testEvalCompiled3NormalYReadsNormalY(): Unit \ Assert =
        Assert.assertEq(expected = -1.0, alpha3(alphaSpec(normal(Axis3.Y)), v3(0.0, 0.0, 0.0), v3(0.0, -1.0, 0.0)))

    /// 法線は長さ 1 にそろえてから読む（(0, 0, 2) の z は 1）。
    @Test
    def testEvalCompiled3NormalIsUnitLength(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, alpha3(alphaSpec(normal(Axis3.Z)), v3(0.0, 0.0, 0.0), v3(0.0, 0.0, 2.0)))

    /// World は uv の変換を受けない — Scaled(10 倍) の内側でも world の x のまま。
    @Test
    def testWorldIgnoresScaled(): Unit \ Assert =
        let scaled = Field.Scaled({ factor = 10.0, scroll = { x = 0.0, y = 0.0 }, of = world(Axis3.X) });
        Assert.assertEq(expected = 0.5, alpha3(alphaSpec(scaled), v3(0.5, 0.0, 0.0), up()))

    /// shared（bindings）の中の World も world を読み、後ろの場から Ref で引ける。
    @Test
    def testWorldInBindingIsReadByRef(): Unit \ Assert =
        let spec = { bindings = ("h", world(Axis3.Y)) :: Nil | alphaSpec(Field.Ref("h")) };
        Assert.assertEq(expected = 10.0, alpha3(spec, v3(0.5, 10.0, 50.0), up()))

    /// 2D の面（evalCompiled）では World は 0。
    @Test
    def testEvalCompiled2dWorldIsZero(): Unit \ Assert =
        let compiled = ShaderEval.compile(alphaSpec(world(Axis3.X)), Map.empty());
        Assert.assertEq(expected = 0.0, alphaOf(ShaderEval.evalCompiled(compiled, 0.5, 0.5, 0.0)))

    /// atWorld((X, Z), hash) は world の (x, z) を uv として読む — 2D で uv = (1.5, 0.5) を読んだ値と同じ。
    @Test
    def testAtWorldReadsWorldPlaneAsUv(): Unit \ Assert =
        let hash = Field.Hash1({ scale = 1.0, seed = 0, bucket = None });
        let expected = ShaderEval.evalField(hash, { x = 1.5, y = 0.5 }, 0.0);
        Assert.assertEq(expected = expected,
            alpha3(alphaSpec(ShaderDoc.atWorld((Axis3.X, Axis3.Z), hash)), v3(1.5, 10.0, 0.5), up()))

    /// atWorld で包んだ Hash は world の隣のマスで違う値を返す（x = 0.5 と 1.5 は別のマス）。
    @Test
    def testAtWorldHashDiffersAcrossCells(): Unit \ Assert =
        let spec = alphaSpec(ShaderDoc.atWorld((Axis3.X, Axis3.Z), Field.Hash1({ scale = 1.0, seed = 0, bucket = None })));
        Assert.assertEq(expected = true, alpha3(spec, v3(0.5, 0.0, 0.5), up()) != alpha3(spec, v3(1.5, 0.0, 0.5), up()))

    /// evalMaterial3 は albedo・α と、emission の色を返す。emission は World を読める（x = 0.25 → r = 0.25）。
    @Test
    def testEvalMaterial3ReturnsEmission(): Unit \ Assert =
        let glow = Shade.Rgb({ r = world(Axis3.X), g = Field.Const(0.5), b = Field.Const(0.0) });
        let compiled = ShaderEval.compileMaterial(alphaSpec(Field.Const(1.0)), Some(glow), Map.empty());
        let sample = ShaderEval.evalMaterial3(compiled, v3(0.25, 0.0, 0.0), up(), 0.0);
        Assert.assertEq(expected = (0.5, 1.0, 0.25, 0.5, 0.0),
            (sample#albedo#r, sample#alpha, sample#emission#r, sample#emission#g, sample#emission#b))

    /// emission が無い材質の emission は黒。
    @Test
    def testEvalMaterial3WithoutEmissionIsBlack(): Unit \ Assert =
        let compiled = ShaderEval.compileMaterial(alphaSpec(Field.Const(1.0)), None, Map.empty());
        let sample = ShaderEval.evalMaterial3(compiled, v3(0.25, 0.0, 0.0), up(), 0.0);
        Assert.assertEq(expected = (0.0, 0.0, 0.0), (sample#emission#r, sample#emission#g, sample#emission#b))

    /// compileMaterial は spec と emission の両方の Param に値の表の値を入れる（a = 0.25 は α、b = 0.75 は emission の r）。
    @Test
    def testCompileMaterialBindsParamsInSpecAndEmission(): Unit \ Assert =
        let glow = Shade.Rgb({ r = Field.Param({ name = "b" }), g = Field.Const(0.0), b = Field.Const(0.0) });
        let compiled = ShaderEval.compileMaterial(alphaSpec(Field.Param({ name = "a" })), Some(glow),
                                                  Map#{ "a" => 0.25, "b" => 0.75 });
        let sample = ShaderEval.evalMaterial3(compiled, v3(0.0, 0.0, 0.0), up(), 0.0);
        Assert.assertEq(expected = (0.25, 0.75), (sample#alpha, sample#emission#r))

    // ════════════════════════════════════════════════════════════════════
    // GLSL（ShaderGen）
    // ════════════════════════════════════════════════════════════════════

    /// 2D の compile では World / Normal は 0.0 の字になる（varying を読まない）。
    @Test
    def testCompile2dWorldIsZeroLiteral(): Unit \ Assert =
        let spec = alphaSpec(Field.Bin({ op = BinOp.Add, a = world(Axis3.X), b = normal(Axis3.Y) }));
        Assert.assertEq(expected = "outColor = vec4(vec3(0.5, 0.5, 0.5), (0.0 + 0.0));", ShaderGen.compileBody(spec))

    /// compile3d の関数は World を vWorld から、Normal を normalize した vNormal から読む。
    @Test
    def testCompile3dReadsVaryings(): Unit \ Assert =
        let spec = alphaSpec(Field.Bin({ op = BinOp.Add, a = world(Axis3.X), b = normal(Axis3.Y) }));
        let fns = ShaderGen.compile3d(spec, None)#functions;
        Assert.assertEq(expected = (true, true, true),
            (String.contains({ substr = "vec3 sg_normal = normalize(vNormal);" }, fns),
             String.contains({ substr = "albedo = vec4(vec3(0.5, 0.5, 0.5), (vWorld.x + sg_normal.y));" }, fns),
             String.contains({ substr = "emission = vec3(0.0, 0.0, 0.0);" }, fns)))

    /// compile3d の uv は (0, 0) — Uv を読む場は sg_uv（vec2(0.0, 0.0)）を読み、vUv は出ない。
    @Test
    def testCompile3dUvIsZero(): Unit \ Assert =
        let fns = ShaderGen.compile3d(alphaSpec(Field.Uv({ axis = ShaderDoc.Axis.U })), None)#functions;
        Assert.assertEq(expected = (true, true, false),
            (String.contains({ substr = "vec2 sg_uv = vec2(0.0, 0.0);" }, fns),
             String.contains({ substr = "(sg_uv).x" }, fns),
             String.contains({ substr = "vUv" }, fns)))

    /// Param の uniform は spec の名前の後ろに emission だけの名前を足した並び（a → uParam0・b → uParam1）。
    @Test
    def testCompile3dParamUniformsIncludeEmission(): Unit \ Assert =
        let glow = Shade.Rgb({ r = Field.Param({ name = "b" }), g = Field.Param({ name = "a" }), b = Field.Const(0.0) });
        let m = ShaderGen.compile3d(alphaSpec(Field.Param({ name = "a" })), Some(glow));
        Assert.assertEq(expected = ("a" :: "b" :: Nil,
                                    "uniform float uTime;\nuniform float uParam0;\nuniform float uParam1;\n", true),
            (m#paramNames, m#uniforms, String.contains({ substr = "emission = vec3(uParam1, uParam0, 0.0);" }, m#functions)))

    /// 3D の材質はテクスチャを読まない — tex は 0.0 になり、uTex の字は出ない。
    @Test
    def testCompile3dDropsTextures(): Unit \ Assert =
        let fns = ShaderGen.compile3d(alphaSpec(Field.Tex({ name = "a", chan = ShaderDoc.TexChan.R })), None)#functions;
        Assert.assertEq(expected = (false, true),
            (String.contains({ substr = "uTex" }, fns),
             String.contains({ substr = "albedo = vec4(vec3(0.5, 0.5, 0.5), 0.0);" }, fns)))

    /// emission の色の比べ: 場の軸が違えば等しくない・同じ中身なら等しい・片方だけ無ければ等しくない。
    @Test
    def testEqEmission(): Unit \ Assert =
        let glow = a -> Some(Shade.Rgb({ r = world(a), g = Field.Const(0.0), b = Field.Const(0.0) }));
        Assert.assertEq(expected = (false, true, false),
            (ShaderGen.eqEmission(glow(Axis3.X), glow(Axis3.Y)),
             ShaderGen.eqEmission(glow(Axis3.X), glow(Axis3.X)),
             ShaderGen.eqEmission(glow(Axis3.X), None)))

    // ════════════════════════════════════════════════════════════════════
    // JSON（ShaderJson）
    // ════════════════════════════════════════════════════════════════════

    /// world / normal は JSON を往復しても同じ Spec に戻る（軸の字 x / y / z を含む）。
    @Test
    def testJsonRoundTripWorldNormal(): Unit \ Assert =
        let spec = { bindings = ("w", world(Axis3.Z)) :: Nil |
                     alphaSpec(Field.Bin({ op = BinOp.Add, a = Field.Ref("w"),
                                           b = Field.Bin({ op = BinOp.Mul, a = normal(Axis3.X), b = world(Axis3.Y) }) })) };
        let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
            case Ok(back) => ShaderGen.eqSpec(spec, back)
            case Err(_)   => false
        };
        Assert.assertEq(expected = true, same)

    /// world の軸に x / y / z 以外の字（uv の "u"）を書いた JSON は Err。
    @Test
    def testJsonWorldRejectsUvAxis(): Unit \ Assert =
        let r = match Util.Json.parse("{\"name\":\"x\",\"out\":{\"kind\":\"fill\",\"shade\":{\"kind\":\"solid\",\"color\":\"#808080\"},\"alpha\":{\"kind\":\"world\",\"axis\":\"u\"}}}") {
            case Ok(j)  => Result.isErr(ShaderJson.parse(j))
            case Err(_) => false
        };
        Assert.assertEq(expected = true, r)

    // ════════════════════════════════════════════════════════════════════
    // 材質の Param の並び・2D で読むかの判定（ShaderDoc）
    // ════════════════════════════════════════════════════════════════════

    /// World / Normal を読む Spec だけが usesWorld3d（atWorld で包んだ物も読む側）。
    @Test
    def testUsesWorld3d(): Unit \ Assert =
        let hash = Field.Hash1({ scale = 1.0, seed = 0, bucket = None });
        Assert.assertEq(expected = (false, true, true),
            (ShaderDoc.usesWorld3d(alphaSpec(hash)),
             ShaderDoc.usesWorld3d(alphaSpec(ShaderDoc.atWorld((Axis3.X, Axis3.Z), hash))),
             ShaderDoc.usesWorld3d(alphaSpec(normal(Axis3.Y)))))
}
