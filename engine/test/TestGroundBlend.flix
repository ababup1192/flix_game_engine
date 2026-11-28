// 頂点の色を割合にして 2 枚の絵を混ぜる地面の材質（Spec の Blend・VertexColor と Scene3d.withMetallicRoughnessShade）。
mod TestGroundBlend {

    def argb(r: Int32, g: Int32, b: Int32): Int32 = Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(r, 16), Int32.bitwiseOr(Int32.leftShift(g, 8), b)))

    def tex(name: String, chan: ShaderDoc.TexChan): ShaderDoc.Field = ShaderDoc.Field.Tex({ name = name, chan = chan })

    def byGreen(): ShaderDoc.Field = ShaderDoc.Field.VertexColor({ chan = ShaderDoc.TexChan.G })

    def mixOf(chan: ShaderDoc.TexChan): ShaderDoc.Field = ShaderDoc.Field.Blend({ a = tex("dirt", chan), b = tex("grass", chan), by = byGreen() })

    def groundSpec(): ShaderDoc.Spec =
        { name = "ground", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = mixOf(ShaderDoc.TexChan.R), g = mixOf(ShaderDoc.TexChan.G), b = mixOf(ShaderDoc.TexChan.B) }),
                                     alpha = ShaderDoc.Field.Const(1.0) }) }

    /// roughness（g）だけを 0.2 と 0.9 で頂点の色の G で混ぜる shade。
    def roughShade(): ShaderDoc.Shade =
        ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Const(0.0), g = ShaderDoc.Field.Blend({ a = ShaderDoc.Field.Const(0.2), b = ShaderDoc.Field.Const(0.9), by = byGreen() }),
                              b = ShaderDoc.Field.Const(0.0) })

    def sampleAt(green: Float64): ShaderEval.MaterialSample =
        let textures = Map#{ "dirt" => Vector#{ { width = 1, height = 1, pixels = Vector#{ argb(200, 100, 50) } } },
                             "grass" => Vector#{ { width = 1, height = 1, pixels = Vector#{ argb(50, 150, 50) } } } };
        let compiled = ShaderEval.compileMaterial({ spec = groundSpec(), emission = None, metallicRoughness = Some(roughShade()), readsMaterialOcclusion = false, params = Map.empty(),
                                                    textures = textures, repeat = true });
        ShaderEval.evalMaterial3(compiled, { world = Vec3.zero(), normal = Vec3.v3(0.0, 1.0, 0.0), uv = Vec2.zero(), color = Color.rgb(0.0, green, 0.0) }, 0.0)

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 1.0e-6

    /// 頂点の色の G が 0・0.5・1 の 3 点で、albedo の r は土・まん中・草になる。
    @Test
    def testAlbedoFollowsVertexGreen(): Unit \ Assert =
        let reds = (0.0 :: 0.5 :: 1.0 :: Nil) |> List.map(g -> sampleAt(g)#albedo#r);
        let expected = (200.0 / 255.0) :: (125.0 / 255.0) :: (50.0 / 255.0) :: Nil;
        Assert.assertTrue(List.zip(reds, expected) |> List.forAll(match (a, b) -> near(a, b)))

    /// shade の roughness も同じ割合で混ざる（G = 0.5 で 0.55）。
    @Test
    def testRoughnessFollowsVertexGreen(): Unit \ Assert =
        Assert.assertTrue(sampleAt(0.5)#metallicRoughness |> Option.exists(mr -> near(0.55, snd(mr))))

    def solid(): Scene3d.Material3d = Scene3d.material(groundSpec())

    /// m の木の鍵が、土台の材質に roughShade だけを付けた物と同じか。
    def hasRoughShade(m: Scene3d.Material3d): Bool =
        force Scene3d.materialFieldsOf(m)#shaderHash == force Scene3d.materialFieldsOf(Scene3d.withMetallicRoughnessShade(roughShade(), solid()))#shaderHash

    /// withMetallicRoughnessShade の後に withMetallicRoughness を呼ぶと値の shade になる（後に呼んだ物が勝つ）。
    @Test
    def testValueAfterShadeWins(): Unit \ Assert =
        let m = solid() |> Scene3d.withMetallicRoughnessShade(roughShade()) |> Scene3d.withMetallicRoughness(0.0, 0.5);
        Assert.assertTrue(Option.nonEmpty(Scene3d.metallicRoughnessOf(m)) and not hasRoughShade(m))

    /// withMetallicRoughness の後に withMetallicRoughnessShade を呼ぶと shade になる。
    @Test
    def testShadeAfterValueWins(): Unit \ Assert =
        let m = solid() |> Scene3d.withMetallicRoughness(0.0, 0.5) |> Scene3d.withMetallicRoughnessShade(roughShade());
        Assert.assertTrue(Option.isEmpty(Scene3d.metallicRoughnessOf(m)) and hasRoughShade(m))

    /// shade の絵も材質の絵の組に数える（土と草の 2 組）。
    @Test
    def testShadeTexturesCountAsMaterialReads(): Unit \ Assert =
        let shade = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Const(0.0), g = tex("rough", ShaderDoc.TexChan.G), b = ShaderDoc.Field.Const(0.0) });
        let m = solid() |> Scene3d.withMetallicRoughnessShade(shade);
        Assert.assertEq(expected = 3, List.length(Scene3d.materialTexReadsOf(Scene3d.materialFieldsOf(m))))
}
