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

    /// world の点 at・法線 n の画素（uv は (0, 0)・頂点の色は白）。
    def point(at: Vec3.Vec3, n: Vec3.Vec3): ShaderEval.SurfacePoint =
        { world = at, normal = n, uv = { x = 0.0, y = 0.0 }, color = { r = 1.0, g = 1.0, b = 1.0 } }

    /// 3D の画素 1 つの α（tex 無し・Param 無しで組み直す）。
    def alpha3(spec: ShaderDoc.Spec, at: Vec3.Vec3, n: Vec3.Vec3): Float64 =
        alphaOf(ShaderEval.evalCompiled3(ShaderEval.compile(spec, Map.empty()), point(at, n), 0.0))

    /// 絵の無い材質の組み直し。
    def material(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], params: Map[String, Float64]): ShaderEval.CompiledSpec =
        ShaderEval.compileMaterial({ spec = spec, emission = emission, params = params, textures = Map.empty(), repeat = true })

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
        let compiled = material(alphaSpec(Field.Const(1.0)), Some(glow), Map.empty());
        let sample = ShaderEval.evalMaterial3(compiled, point(v3(0.25, 0.0, 0.0), up()), 0.0);
        Assert.assertEq(expected = (0.5, 1.0, 0.25, 0.5, 0.0),
            (sample#albedo#r, sample#alpha, sample#emission#r, sample#emission#g, sample#emission#b))

    /// albedo の Rgb は 0..1 に切り（1.5 → 1）、emission は切らない（1.5 はそのまま・負の −0.5 だけ 0）。
    /// emission は Rgba16Float の描き先で 1 を超えて残る（8bit の描き先は書く所で切る）。
    @Test
    def testEvalMaterial3ClampsAlbedoButNotEmission(): Unit \ Assert =
        let rgb = (r, g) -> Shade.Rgb({ r = Field.Const(r), g = Field.Const(g), b = Field.Const(0.0) });
        let spec = { name = "t", cycleRate = 0.0, bindings = Nil, out = Out.Fill({ shade = rgb(1.5, 0.0), alpha = Field.Const(1.0) }) };
        let sample = ShaderEval.evalMaterial3(material(spec, Some(rgb(1.5, -0.5)), Map.empty()), point(v3(0.0, 0.0, 0.0), up()), 0.0);
        Assert.assertEq(expected = (1.0, 1.5, 0.0), (sample#albedo#r, sample#emission#r, sample#emission#g))

    /// emission が無い材質の emission は黒。
    @Test
    def testEvalMaterial3WithoutEmissionIsBlack(): Unit \ Assert =
        let compiled = material(alphaSpec(Field.Const(1.0)), None, Map.empty());
        let sample = ShaderEval.evalMaterial3(compiled, point(v3(0.25, 0.0, 0.0), up()), 0.0);
        Assert.assertEq(expected = (0.0, 0.0, 0.0), (sample#emission#r, sample#emission#g, sample#emission#b))

    /// compileMaterial は spec と emission の両方の Param に値の表の値を入れる（a = 0.25 は α、b = 0.75 は emission の r）。
    @Test
    def testCompileMaterialBindsParamsInSpecAndEmission(): Unit \ Assert =
        let glow = Shade.Rgb({ r = Field.Param({ name = "b" }), g = Field.Const(0.0), b = Field.Const(0.0) });
        let compiled = material(alphaSpec(Field.Param({ name = "a" })), Some(glow), Map#{ "a" => 0.25, "b" => 0.75 });
        let sample = ShaderEval.evalMaterial3(compiled, point(v3(0.0, 0.0, 0.0), up()), 0.0);
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

    /// compile3d の uv は vUv — Uv を読む場は sg_uv（= vUv）を読む。
    @Test
    def testCompile3dUvReadsVUv(): Unit \ Assert =
        let fns = ShaderGen.compile3d(alphaSpec(Field.Uv({ axis = ShaderDoc.Axis.U })), None)#functions;
        Assert.assertEq(expected = (true, true),
            (String.contains({ substr = "vec2 sg_uv = vUv;" }, fns),
             String.contains({ substr = "(sg_uv).x" }, fns)))

    /// Param の uniform は spec の名前の後ろに emission だけの名前を足した並び（a → uParam0・b → uParam1）。
    @Test
    def testCompile3dParamUniformsIncludeEmission(): Unit \ Assert =
        let glow = Shade.Rgb({ r = Field.Param({ name = "b" }), g = Field.Param({ name = "a" }), b = Field.Const(0.0) });
        let m = ShaderGen.compile3d(alphaSpec(Field.Param({ name = "a" })), Some(glow));
        Assert.assertEq(expected = ("a" :: "b" :: Nil,
                                    "uniform float uTime;\nuniform float uParam0;\nuniform float uParam1;\n", true),
            (m#paramNames, m#uniforms, String.contains({ substr = "emission = vec3(uParam1, uParam0, 0.0);" }, m#functions)))

    /// 3D の材質の tex は uTex0 を sg_uv で段つきで読み（sg_texMip）、sampler の uniform を宣言する。
    @Test
    def testCompile3dReadsTexture(): Unit \ Assert =
        let m = ShaderGen.compile3d(alphaSpec(Field.Tex({ name = "a", chan = ShaderDoc.TexChan.R })), None);
        Assert.assertEq(expected = (true, true, ("a", ShaderDoc.FilterMode.Nearest) :: Nil),
            (String.contains({ substr = "uniform sampler2D uTex0;\nuniform float uTexFlip0;\n" }, m#uniforms),
             String.contains({ substr = "sg_texMip(uTex0, uTexFlip0, uTexLevels0, (sg_uv))" }, m#functions),
             m#texReads))

    /// 同じ絵を r・g・b で読む材質は、読みを 1 つに括り出す（括り出しの印 ⟦ ⟧ は残らない）。
    @Test
    def testCompile3dHoistsRepeatedTextureReads(): Unit \ Assert =
        let tex = (c: ShaderDoc.TexChan) -> Field.Tex({ name = "a", chan = c });
        let spec = { out = Out.Fill({ shade = Shade.Rgb({ r = tex(ShaderDoc.TexChan.R), g = tex(ShaderDoc.TexChan.G), b = tex(ShaderDoc.TexChan.B) }),
                                      alpha = Field.Const(1.0) }) | alphaSpec(Field.Const(1.0)) };
        let fns = ShaderGen.compile3d(spec, None)#functions;
        Assert.assertEq(expected = (true, false),
            (String.contains({ substr = "vec4 sg_r0 = sg_texMip(uTex0" }, fns), String.contains({ substr = "⟦" }, fns)))

    /// 3D の VertexColor は varying の vColor を読む。
    @Test
    def testCompile3dVertexColorReadsVColor(): Unit \ Assert =
        let fns = ShaderGen.compile3d(alphaSpec(Field.VertexColor({ chan = ShaderDoc.TexChan.G })), None)#functions;
        Assert.assertEq(expected = true, String.contains({ substr = "albedo = vec4(vec3(0.5, 0.5, 0.5), vColor.g);" }, fns))

    /// 2D の面の VertexColor は 1.0 の字になる。
    @Test
    def testCompile2dVertexColorIsOne(): Unit \ Assert =
        Assert.assertEq(expected = "outColor = vec4(vec3(0.5, 0.5, 0.5), 1.0);",
            ShaderGen.compileBody(alphaSpec(Field.VertexColor({ chan = ShaderDoc.TexChan.R }))))

    /// 材質の emission の比べ: 場の軸が違えば等しくない・同じ中身なら等しい・片方だけ無ければ等しくない。
    @Test
    def testEqMaterialComparesEmission(): Unit \ Assert =
        let glow = a -> Some(Shade.Rgb({ r = world(a), g = Field.Const(0.0), b = Field.Const(0.0) }));
        let spec = alphaSpec(Field.Const(1.0));
        Assert.assertEq(expected = (false, true, false),
            (ShaderGen.eqMaterial(spec, glow(Axis3.X), spec, glow(Axis3.Y)),
             ShaderGen.eqMaterial(spec, glow(Axis3.X), spec, glow(Axis3.X)),
             ShaderGen.eqMaterial(spec, glow(Axis3.X), spec, None)))

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

    // ════════════════════════════════════════════════════════════════════
    // 材質の絵（ShaderEval の 3D の Tex・Wrap・VertexColor）
    // ════════════════════════════════════════════════════════════════════

    /// 横 4 × 縦 1 の絵。赤の成分が左から 0・85・170・255（α は 0。赤だけを読む）。
    def redRamp(): ShaderEval.TexData =
        { width = 4, height = 1, pixels = Vector#{ 0x00000000, 0x00550000, 0x00aa0000, 0x00ff0000 } }

    /// 絵 "ramp" の赤を α の席で読む材質（linear なら Linear で読む）の、uv の画素の α。
    def rampAlpha(linear: Bool, repeat: Bool, uv: Vec2.Vec2): Float64 =
        let read = Field.Tex({ name = "ramp", chan = ShaderDoc.TexChan.R });
        let field = if (linear) Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = read }) else read;
        let compiled = ShaderEval.compileMaterial({ spec = alphaSpec(field), emission = None, params = Map.empty(),
                                                    textures = Map#{ "ramp" => Vector#{ redRamp() } }, repeat = repeat });
        ShaderEval.evalMaterial3(compiled, { uv = uv | point(v3(0.0, 0.0, 0.0), up()) }, 0.0)#alpha

    /// Repeat は 0..1 の外の uv を繰り返す（u = 1.25 は u = 0.25 と同じテクセル）。
    @Test
    def testRepeatWrapsU(): Unit \ Assert =
        Assert.assertEq(expected = rampAlpha(false, true, { x = 0.25 + 0.125, y = 0.5 }), rampAlpha(false, true, { x = 1.25 + 0.125, y = 0.5 }))

    /// Repeat の Linear は u = 0 で、左端と右端の 2 テクセルの平均を読む（GL の REPEAT と同じく反対の端へ回る）。
    @Test
    def testRepeatLinearAtZeroAveragesEdgeTexels(): Unit \ Assert =
        Assert.assertEq(expected = (0.0 + 1.0) / 2.0, rampAlpha(true, true, { x = 0.0, y = 0.5 }))

    /// Clamp は 0..1 の外の uv で端のテクセルを読む（u = 1.25 は右端）。
    @Test
    def testClampKeepsEdgeTexel(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, rampAlpha(false, false, { x = 1.25, y = 0.5 }))

    /// 3D の VertexColor は画素の頂点の色を読む（g = 0.3）。
    @Test
    def testVertexColorReadsPointColor(): Unit \ Assert =
        let compiled = material(alphaSpec(Field.VertexColor({ chan = ShaderDoc.TexChan.G })), None, Map.empty());
        Assert.assertEq(expected = 0.3,
            ShaderEval.evalMaterial3(compiled, { color = { r = 0.9, g = 0.3, b = 0.1 } | point(v3(0.0, 0.0, 0.0), up()) }, 0.0)#alpha)

    /// 2D の面の VertexColor は 1。
    @Test
    def testVertexColorIsOneOn2dSurface(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, ShaderEval.evalAlpha(alphaSpec(Field.VertexColor({ chan = ShaderDoc.TexChan.B })), { x = 0.5, y = 0.5 }, 0.0))

    /// vertexColor は JSON を往復しても同じ Spec に戻る。
    @Test
    def testJsonRoundTripVertexColor(): Unit \ Assert =
        let spec = alphaSpec(Field.VertexColor({ chan = ShaderDoc.TexChan.B }));
        let same = match ShaderJson.parse(ShaderJson.toJson(spec)) {
            case Ok(back) => ShaderGen.eqSpec(spec, back)
            case Err(_)   => false
        };
        Assert.assertEq(expected = true, same)

    /// 材質の絵の組は、Spec の後ろに emission にだけ出てくる組を足した並び。
    @Test
    def testMaterialTexReadsAppendsEmission(): Unit \ Assert =
        let glow = Shade.Rgb({ r = Field.Tex({ name = "b", chan = ShaderDoc.TexChan.R }), g = Field.Tex({ name = "a", chan = ShaderDoc.TexChan.R }),
                               b = Field.Const(0.0) });
        Assert.assertEq(expected = ("a", ShaderDoc.FilterMode.Nearest) :: ("b", ShaderDoc.FilterMode.Nearest) :: Nil,
            ShaderDoc.materialTexReads(alphaSpec(Field.Tex({ name = "a", chan = ShaderDoc.TexChan.A })), Some(glow)))

    /// 上限を超えた組（7 組目）を読む tex は 0 の Const になり、6 組目までは残る。
    @Test
    def testLimitMaterialTexReadsZeroesSeventh(): Unit \ Assert =
        let tex = (n: Int32) -> Field.Tex({ name = "t${n}", chan = ShaderDoc.TexChan.R });
        let sum = List.range(1, 8) |> List.map(tex) |> List.reduceLeft((a, b) -> Field.Bin({ op = BinOp.Add, a = a, b = b }))
            |> Option.getWithDefault(Field.Const(0.0));
        let (limited, _) = ShaderDoc.limitMaterialTexReads(6, alphaSpec(sum), None);
        Assert.assertEq(expected = List.range(1, 7) |> List.map(n -> "t${n}"), ShaderDoc.texNames(limited))

    // ════════════════════════════════════════════════════════════════════
    // 段つきの絵（ShaderEval.evalMaterial3Mip）
    // ════════════════════════════════════════════════════════════════════

    /// redRamp の段（4 × 1 → 2 × 1 → 1 × 1。段 1 の赤は 43・213）を読む材質の、uv (u, 0.5) の画素の α。
    /// 右隣の画素の u は u + du（下隣は動かない）なので、ρ = du × 4。
    def rampMipAlpha(linear: Bool, repeat: Bool, u: Float64, du: Float64): Float64 =
        let read = Field.Tex({ name = "ramp", chan = ShaderDoc.TexChan.R });
        let field = if (linear) Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = read }) else read;
        let compiled = ShaderEval.compileMaterial({ spec = alphaSpec(field), emission = None, params = Map.empty(),
                                                    textures = Map#{ "ramp" => List.toVector(Mip.build(Mip.Average.Raw, redRamp())) }, repeat = repeat });
        let at = (x: Float64) -> { uv = { x = x, y = 0.5 } | point(v3(0.0, 0.0, 0.0), up()) };
        ShaderEval.evalMaterial3Mip(compiled, at(u), at(u + du), at(u), 0.0)#alpha

    def round6(x: Float64): Float64 = Float64.round(x * 1000000.0) / 1000000.0

    /// 1 画素に u が 0.5 動く（ρ = 2・lod = 1）と段 1 を読む（左半分は赤 43）。
    @Test
    def testMipReadsLevelOneAtLodOne(): Unit \ Assert =
        Assert.assertEq(expected = round6(43.0 / 255.0), round6(rampMipAlpha(false, true, 0.125, 0.5)))

    /// Repeat は段 1 でも 0..1 の外の uv を繰り返す（u = 1.25 は u = 0.25 と同じ）。
    @Test
    def testMipRepeatWrapsOnLevelOne(): Unit \ Assert =
        Assert.assertEq(expected = rampMipAlpha(false, true, 0.25, 0.5), rampMipAlpha(false, true, 1.25, 0.5))

    /// Nearest の lod 0.5 は段 0 と段 1 をそれぞれ NEAREST で読んで半分ずつ混ぜる（赤 0 と 43 の間）。
    @Test
    def testMipNearestBlendsTwoLevels(): Unit \ Assert =
        Assert.assertEq(expected = round6(0.5 * 43.0 / 255.0), round6(rampMipAlpha(false, true, 0.125, Num.sqrt(2.0) / 4.0)))

    /// 隣の画素と座標が変わらない（拡大）なら段 0 を読む。
    @Test
    def testMipMagnifiedReadsLevelZero(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, rampMipAlpha(false, true, 0.875, 0.0))

    /// 絵を読む材質の cutout の α は段 0 で読み直す（materialCutoutAlpha の textureLod(…, 0.0)）。段の数の uniform も宣言する。
    @Test
    def testCompile3dCutoutAlphaReadsLevelZero(): Unit \ Assert =
        let m = ShaderGen.compile3d(alphaSpec(Field.Tex({ name = "a", chan = ShaderDoc.TexChan.A })), None);
        Assert.assertEq(expected = ("materialCutoutAlpha()", true, true),
            (m#cutoutAlpha, String.contains({ substr = "return textureLod(uTex0, vec2((sg_uv).x" }, m#functions),
             String.contains({ substr = "uniform float uTexLevels0;" }, m#uniforms)))

    /// 絵を読まない材質の cutout は albedo.a のまま（段の関数も足さない）。
    @Test
    def testCompile3dCutoutAlphaWithoutTextureIsAlbedo(): Unit \ Assert =
        let m = ShaderGen.compile3d(alphaSpec(Field.Const(0.25)), None);
        Assert.assertEq(expected = ("albedo.a", false), (m#cutoutAlpha, String.contains({ substr = "sg_texMip" }, m#functions)))

    /// 2D の面の tex は段を読まず、今の texture() の字のまま。
    @Test
    def testCompile2dTexKeepsPlainTexture(): Unit \ Assert =
        Assert.assertEq(expected = "outColor = vec4(vec3(0.5, 0.5, 0.5), texture(uTex0, vec2((vUv).x, mix((vUv).y, 1.0 - (vUv).y, uTexFlip0))).r);",
            ShaderGen.compileBody(alphaSpec(Field.Tex({ name = "a", chan = ShaderDoc.TexChan.R }))))
}
