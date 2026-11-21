// glb の頂点の色 COLOR_0（Gltf.readPrimitive）: FLOAT と正規化した UNSIGNED_SHORT を線形の値として読んで画面の値へ戻す・baseColorFactor と掛ける・
// 読めない型は使わずに白・COLOR_0 の無い glb は今までの色・Model3d.withVertexColorScale の掛け算と中身の鍵。
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

    /// 正規化した UNSIGNED_SHORT の VEC4: 頂点 0 = (0, 1, 0)・頂点 1 = (1, 1, 1)・頂点 2 = (0, 0, 0)（α は 1）。
    def ushortGlb(normalized: Bool): Vector[Int8] =
        glbWithColors("{\"bufferView\":2,\"componentType\":5123,\"normalized\":${if (normalized) "true" else "false"},\"count\":3,\"type\":\"VEC4\"}",
                      TestGltf.u16s(0 :: 65535 :: 0 :: 65535 :: 65535 :: 65535 :: 65535 :: 65535 :: 0 :: 0 :: 0 :: 65535 :: Nil), "", "")

    def colorsOf(bytes: Vector[Int8]): List[Float64] = Mesh3d.colors(TestGltf.okOrBug(Gltf.fromGlb(bytes))#mesh) |> Vector.toList

    def rounded(xs: List[Float64]): List[Float64] = xs |> List.map(x -> Float64.round(x * 10000.0) / 10000.0)

    @Test
    def testFloatColorsAreLinearTurnedToScreenValues(): Unit \ Assert =
        let half = Texture3d.linearToSrgb(0.5);
        Assert.assertEq(expected = rounded(1.0 :: 0.0 :: 0.0 :: half :: half :: half :: 0.0 :: 0.0 :: 1.0 :: Nil), rounded(colorsOf(floatGlb("", ""))))

    @Test
    def testNormalizedUnsignedShortColorsAreRead(): Unit \ Assert =
        Assert.assertEq(expected = 0.0 :: 1.0 :: 0.0 :: 1.0 :: 1.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: Nil, colorsOf(ushortGlb(true)))

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
        let (colors, warned) = colorsWithWarning(ushortGlb(false));
        Assert.assertEq(expected = (List.repeat(9, 1.0), true), (colors, String.contains(substr = "COLOR_0 を使わずに読む", warned)))

    /// baseColorFactor（画面の値として読む口）の (0.5, 1, 1) と頂点 0 の (1, 0, 0) を掛けると (0.5, 0, 0)。
    @Test
    def testColorsAreMultipliedByBaseColorFactor(): Unit \ Assert =
        let bytes = floatGlb(",\"material\":0", ",\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorFactor\":[0.5,1.0,1.0,1.0]}}]");
        Assert.assertEq(expected = 0.5 :: 0.0 :: 0.0 :: Nil, rounded(List.take(3, colorsOf(bytes))))

    @Test
    def testGlbWithoutColorsStaysWhite(): Unit \ Assert =
        Assert.assertEq(expected = List.repeat(9, 1.0), Mesh3d.colors(TestGltf.okOrBug(Gltf.fromGlb(TestGltf.triangleGlb("", "")))#mesh) |> Vector.toList)

    @Test
    def testVertexColorScaleDoublesColorsInEveryPart(): Unit \ Assert =
        let model = Model3d.withVertexColorScale(2.0, TestGltf.okOrBug(Gltf.fromGlb(ushortGlb(true))));
        let parts = model#parts |> List.flatMap(p -> Mesh3d.colors(p#mesh) |> Vector.toList);
        Assert.assertEq(expected = (0.0 :: 2.0 :: 0.0 :: 2.0 :: 2.0 :: 2.0 :: 0.0 :: 0.0 :: 0.0 :: Nil, true),
                        (List.take(9, parts), Mesh3d.colors(model#mesh) |> Vector.toList == List.take(9, parts)))

    @Test
    def testVertexColorScaleChangesTheContentKey(): Unit \ Assert =
        let mesh = TestGltf.okOrBug(Gltf.fromGlb(ushortGlb(true)))#mesh;
        Assert.assertEq(expected = (true, true),
                        (Mesh3d.contentHash(Mesh3d.withColorScale(2.0, mesh)) != Mesh3d.contentHash(mesh),
                         Mesh3d.contentHash(Mesh3d.withColorScale(1.0, mesh)) == Mesh3d.contentHash(mesh)))
}
