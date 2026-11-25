// glb の頂点の色 COLOR_0（Gltf.readPrimitive）: 選んだ時（LoadOptions の vertexColors）だけ、FLOAT と正規化した整数を線形の値として読んで画面の値へ戻す・
// baseColorFactor と掛ける・1 を超える値は 1 に切る・読めない型と幅は使わずに白・選ばない時と COLOR_0 の無い glb は今までの色・
// Model3d.scaleVertexColors の掛け算と中身の鍵と、掛けられない k。
mod TestGltf.VertexColor {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    /// 三角 1 枚（位置・法線と、accessor 2 の COLOR_0）の .glb。colorAccessor = accessor 2 の JSON・colorBytes = その bufferView 2 のバイト・
    /// primitiveExtra = primitive の JSON に足す欄・root = 根に足す欄。
    def glbWithColors(colorAccessor: String, colorBytes: List[Int8], primitiveExtra: String, root: String): Vector[Int8] =
        let geometry = List.append(TestGltf.f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil),
                                   TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil));
        let colors = TestGltf.padded(0i8, colorBytes);
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"COLOR_0\":2}${primitiveExtra}}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"},${colorAccessor}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," +
            "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":${List.length(colors)}}]," +
            "\"buffers\":[{\"byteLength\":${72 + List.length(colors)}}]${root}}";
        TestGltf.glb(json, List.append(geometry, colors))

    /// FLOAT の VEC3: 頂点 0 = (1, 0, 0)・頂点 1 = (0.5, 0.5, 0.5)・頂点 2 = (0, 0, 1)（線形の値）。
    def floatGlb(primitiveExtra: String, root: String): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}",
                      TestGltf.f32s(1.0 :: 0.0 :: 0.0 :: 0.5 :: 0.5 :: 0.5 :: 0.0 :: 0.0 :: 1.0 :: Nil), primitiveExtra, root)

    /// FLOAT の VEC4: 頂点 0 = (0, 1, 0, 0.2)・頂点 1 = (1, 1, 1, 0.2)・頂点 2 = (0, 0, 0, 0.2)（α は読まない）。
    def floatVec4Glb(): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC4\"}",
                      TestGltf.f32s(0.0 :: 1.0 :: 0.0 :: 0.2 :: 1.0 :: 1.0 :: 1.0 :: 0.2 :: 0.0 :: 0.0 :: 0.0 :: 0.2 :: Nil), "", "")

    /// FLOAT の VEC3 で 1 を超える値: 頂点 0 = (2, 1.5, 0)・頂点 1・2 = (1, 1, 1)。
    def overOneGlb(): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}",
                      TestGltf.f32s(2.0 :: 1.5 :: 0.0 :: 1.0 :: 1.0 :: 1.0 :: 1.0 :: 1.0 :: 1.0 :: Nil), "", "")

    /// FLOAT の VEC2（COLOR_0 に無い幅）。
    def vec2Glb(): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}",
                      TestGltf.f32s(0.0 :: 0.0 :: 0.0 :: 0.0 :: 0.0 :: 0.0 :: Nil), "", "")

    /// 正規化した UNSIGNED_SHORT の VEC4: 頂点 0 = (0, 1, 0)・頂点 1 = (1, 1, 1)・頂点 2 = (0, 0, 0)（α は 1）。
    def ushortGlb(normalized: Bool): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5123,\"normalized\":${if (normalized) "true" else "false"},\"count\":3,\"type\":\"VEC4\"}",
                      TestGltf.u16s(0 :: 65535 :: 0 :: 65535 :: 65535 :: 65535 :: 65535 :: 65535 :: 0 :: 0 :: 0 :: 65535 :: Nil), "", "")

    /// 正規化した UNSIGNED_BYTE の VEC4（Blender の書き出しの形）: 頂点 0 = (255, 0, 0)・頂点 1 = (0, 255, 0)・頂点 2 = (0, 0, 255)。
    def ubyteGlb(): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5121,\"normalized\":true,\"count\":3,\"type\":\"VEC4\"}",
                      TestGltf.u8s(255 :: 0 :: 0 :: 255 :: 0 :: 255 :: 0 :: 255 :: 0 :: 0 :: 255 :: 255 :: Nil), "", "")

    def withVertexColors(): Gltf.LoadOptions = { vertexColors = true | Gltf.defaultLoadOptions() }

    def colorsWith(options: Gltf.LoadOptions, bytes: Vector[Int8]): List[Float64] \ IO =
        Mesh3d.colors(TestGltf.okOrBug(Gltf.decodeWith(TestDecoder.imageIo(), options, None, bytes))#mesh) |> Vector.toList

    def colorsOf(bytes: Vector[Int8]): List[Float64] \ IO = colorsWith(withVertexColors(), bytes)

    def rounded(xs: List[Float64]): List[Float64] = xs |> List.map(x -> Float64.round(x * 10000.0) / 10000.0)

    @Test
    def testFloatColorsAreLinearTurnedToScreenValues(): Unit \ {Assert, IO} =
        let half = Texture3d.linearToSrgb(0.5);
        Assert.assertEq(expected = rounded(1.0 :: 0.0 :: 0.0 :: half :: half :: half :: 0.0 :: 0.0 :: 1.0 :: Nil), rounded(colorsOf(floatGlb("", ""))))

    @Test
    def testFloatVec4ColorsIgnoreAlpha(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0.0 :: 1.0 :: 0.0 :: 1.0 :: 1.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: Nil, colorsOf(floatVec4Glb()))

    @Test
    def testNormalizedUnsignedShortColorsAreRead(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0.0 :: 1.0 :: 0.0 :: 1.0 :: 1.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: Nil, colorsOf(ushortGlb(true)))

    @Test
    def testNormalizedUnsignedByteColorsAreRead(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: Nil, colorsOf(ubyteGlb()))

    @Test
    def testColorsAboveOneAreClampedToOne(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1.0 :: 1.0 :: 0.0 :: Nil, List.take(3, colorsOf(overOneGlb())))

    /// bytes を読み、読む間に stderr へ出た字と一緒に返す（差し替えた後に読んだ数だけバイトを落としてから読む。TestGltf.loadSkinned の WhyNot）。
    def colorsWithWarning(bytes: Vector[Int8]): (List[Float64], String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let colors = colorsOf(Vector.drop(buf.size(), bytes));
        System.setErr(old);
        (colors, buf.toString())

    @Test
    def testNotNormalizedIntegerColorsAreIgnored(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List.repeat(9, 1.0), fst(colorsWithWarning(ushortGlb(false))))

    @Test
    def testNotNormalizedIntegerColorsAreReported(): Unit \ {Assert, IO} =
        Assert.assertTrue(String.contains(substr = "COLOR_0 を使わずに読む", snd(colorsWithWarning(ushortGlb(false)))))

    @Test
    def testVec2ColorsAreIgnored(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List.repeat(9, 1.0), fst(colorsWithWarning(vec2Glb())))

    @Test
    def testVec2ColorsAreReported(): Unit \ {Assert, IO} =
        Assert.assertTrue(String.contains(substr = "COLOR_0 の幅 2 は読まない", snd(colorsWithWarning(vec2Glb()))))

    /// baseColorFactor（画面の値として読む口）の (0.5, 1, 1) と頂点 0 の (1, 0, 0) を掛けると (0.5, 0, 0)。
    @Test
    def testColorsAreMultipliedByBaseColorFactor(): Unit \ {Assert, IO} =
        let bytes = floatGlb(",\"material\":0", ",\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorFactor\":[0.5,1.0,1.0,1.0]}}]");
        Assert.assertEq(expected = 0.5 :: 0.0 :: 0.0 :: Nil, rounded(List.take(3, colorsOf(bytes))))

    /// 選ばない時は、白でない COLOR_0（Blender の書き出しの正規化した UNSIGNED_BYTE）を持つ glb も今までどおり白。
    @Test
    def testTexturedLoaderWithoutVertexColorsKeepsWhite(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List.repeat(9, 1.0),
                        Mesh3d.colors(TestGltf.okOrBug(Gltf.decodeWith(TestDecoder.imageIo(), { limits = Gltf.noTextureLimits() | Gltf.defaultLoadOptions() }, None, ubyteGlb()))#mesh) |> Vector.toList)

    @Test
    def testDefaultLoadOptionsKeepWhite(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List.repeat(9, 1.0), colorsWith(Gltf.defaultLoadOptions(), ubyteGlb()))

    @Test
    def testPlainLoaderKeepsWhite(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List.repeat(9, 1.0), Mesh3d.colors(TestGltf.okOrBug(TestGltf.decode(ubyteGlb()))#mesh) |> Vector.toList)

    @Test
    def testGlbWithoutColorsStaysWhite(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List.repeat(9, 1.0), colorsOf(TestGltf.triangleGlb("", "")))

    def ushortModel(): Model3d.Model3d \ IO =
        TestGltf.okOrBug(Gltf.decodeWith(TestDecoder.imageIo(), withVertexColors(), None, ushortGlb(true)))

    def partColors(model: Model3d.Model3d): List[Float64] = model#parts |> List.flatMap(p -> Mesh3d.colors(p#mesh) |> Vector.toList)

    @Test
    def testScaleVertexColorsDoublesEveryPart(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0.0 :: 2.0 :: 0.0 :: 2.0 :: 2.0 :: 2.0 :: 0.0 :: 0.0 :: 0.0 :: Nil,
                        partColors(Model3d.scaleVertexColors(2.0, ushortModel())))

    @Test
    def testScaleVertexColorsDoublesTheWholeMesh(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0.0 :: 2.0 :: 0.0 :: 2.0 :: 2.0 :: 2.0 :: 0.0 :: 0.0 :: 0.0 :: Nil,
                        Mesh3d.colors(Model3d.scaleVertexColors(2.0, ushortModel())#mesh) |> Vector.toList)

    @Test
    def testScaleVertexColorsTwiceMultipliesAgain(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0.0 :: 4.0 :: 0.0 :: 4.0 :: 4.0 :: 4.0 :: 0.0 :: 0.0 :: 0.0 :: Nil,
                        partColors(Model3d.scaleVertexColors(2.0, Model3d.scaleVertexColors(2.0, ushortModel()))))

    /// model の頂点の色に k を掛け、掛ける間に stderr へ出た字と一緒に返す（k に読んだバイトの数 × 0 を足して、差し替えた後に掛ける。colorsWithWarning と同じ）。
    def scaledWithWarning(k: Float64, model: Model3d.Model3d): (Model3d.Model3d, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let scaled = Model3d.scaleVertexColors(k + Int32.toFloat64(buf.size()) * 0.0, model);
        System.setErr(old);
        (scaled, buf.toString())

    @Test
    def testScaleVertexColorsByNanKeepsColors(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = partColors(ushortModel()), partColors(fst(scaledWithWarning(Float64.nan(), ushortModel()))))

    @Test
    def testScaleVertexColorsByNegativeKeepsColors(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = partColors(ushortModel()), partColors(fst(scaledWithWarning(-2.0, ushortModel()))))

    @Test
    def testScaleVertexColorsByInfinityKeepsTheContentKey(): Unit \ {Assert, IO} =
        let model = ushortModel();
        Assert.assertEq(expected = Mesh3d.contentHash(model#mesh), Mesh3d.contentHash(fst(scaledWithWarning(Float64.positiveInfinity(), model))#mesh))

    @Test
    def testScaleVertexColorsByNegativeIsReported(): Unit \ {Assert, IO} =
        Assert.assertTrue(String.contains(substr = "Model3d.scaleVertexColors の k -2.0", snd(scaledWithWarning(-2.0, ushortModel()))))

    @Test
    def testScaleColorsByTwoChangesTheContentKey(): Unit \ {Assert, IO} =
        let mesh = ushortModel()#mesh;
        Assert.assertFalse(Mesh3d.contentHash(Mesh3d.scaleColors(2.0, mesh)) == Mesh3d.contentHash(mesh))

    @Test
    def testScaleColorsByOneKeepsTheContentKey(): Unit \ {Assert, IO} =
        let mesh = ushortModel()#mesh;
        Assert.assertEq(expected = Mesh3d.contentHash(mesh), Mesh3d.contentHash(Mesh3d.scaleColors(1.0, mesh)))
}
