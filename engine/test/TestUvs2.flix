// 2 本目の uv（lightmap を読む UV）: Mesh3d.withUvs2 の確かめ・中身の鍵・withBoxUvs で頂点を分けた後の写し、
// glTF の TEXCOORD_1 の読み込み（X の反転を受けない・法線の無い形で角ごとに写す・数の食い違い・無い時）。
// 2 本目の uv の無い形の鍵が今と同じことは TestMeshArraysFixed の固定値（uv の無い形と uv つきの形）が押さえる。
mod TestGltf.Uvs2 {
    import java.io.{ByteArrayOutputStream, PrintStream}
    import java.lang.System

    def triangle(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil,
                              color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    def okOr(m: Result[String, Mesh3d.Mesh3d]): Mesh3d.Mesh3d = match m {
        case Ok(mesh) => mesh
        case Err(e)   => bug!(e)
    }

    def secondUvs(): Vector[Float64] = Vector#{0.1, 0.2, 0.3, 0.4, 0.5, 0.6}

    @Test
    def testWrongCountIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Mesh3d.withUvs2(Vector#{0.0, 0.0}, triangle())))

    @Test
    def testNaNIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Mesh3d.withUvs2(Vector#{0.0, 0.0, 0.0, 0.0, 0.0, Float64.nan()}, triangle())))

    @Test
    def testUvs2AreKept(): Unit \ Assert =
        Assert.assertEq(expected = Some(secondUvs()), Mesh3d.uvs2(okOr(Mesh3d.withUvs2(secondUvs(), triangle()))))

    @Test
    def testUvs2ChangeTheKey(): Unit \ Assert =
        Assert.assertFalse(Mesh3d.contentHash(triangle()) == Mesh3d.contentHash(okOr(Mesh3d.withUvs2(secondUvs(), triangle()))))

    @Test
    def testOrderOfUvsAndUvs2GivesTheSameKey(): Unit \ Assert =
        let uvs = Vector#{0.0, 0.0, 1.0, 0.0, 0.0, 1.0};
        let first = okOr(Mesh3d.withUvs(uvs, triangle()) |> Result.flatMap(Mesh3d.withUvs2(secondUvs())));
        let second = okOr(Mesh3d.withUvs2(secondUvs(), triangle()) |> Result.flatMap(Mesh3d.withUvs(uvs)));
        Assert.assertEq(expected = Mesh3d.contentHash(first), Mesh3d.contentHash(second))

    /// z の面の三角形と x の面の三角形が辺（頂点 0・1）を共有する形。withBoxUvs は共有の頂点を分ける。
    def bentPair(): Mesh3d.Mesh3d =
        okOr(Mesh3d.fromArrays({
            positions = Vector#{0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0},
            normals = Vector#{0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0},
            colors = Vector#{1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0},
            indices = Vector#{0, 2, 1, 0, 1, 3}, skin = None }))

    def bentUvs2(): Vector[Float64] = Vector#{0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.5, 0.5}

    /// 頂点の位置 → その頂点の 2 本目の uv（同じ位置の頂点は同じ uv のはず）。
    def uvs2ByPosition(m: Mesh3d.Mesh3d): List[(List[Float64], List[Float64])] =
        let positions = Mesh3d.positions(m);
        let uvs2 = Mesh3d.uvs2(m) |> Option.getWithDefault(Vector.empty());
        List.range(0, Vector.length(positions) / 3) |> List.map(k ->
            (Vector.slice(start = k * 3, end = k * 3 + 3, positions) |> Vector.toList,
             Vector.slice(start = k * 2, end = k * 2 + 2, uvs2) |> Vector.toList))
            |> List.sort |> List.distinct

    @Test
    def testBoxUvsCarryUvs2WithSplitVertices(): Unit \ Assert =
        let before = okOr(Mesh3d.withUvs2(bentUvs2(), bentPair()));
        Assert.assertEq(expected = uvs2ByPosition(before), uvs2ByPosition(Mesh3d.withBoxUvs(1.0, before)))

    @Test
    def testBoxUvsSplitTheSharedVertices(): Unit \ Assert =
        let before = okOr(Mesh3d.withUvs2(bentUvs2(), bentPair()));
        Assert.assertTrue(Vector.length(Mesh3d.positions(Mesh3d.withBoxUvs(1.0, before))) > Vector.length(Mesh3d.positions(before)))

    // ── glTF の TEXCOORD_1 ──

    /// 三角 1 つの .glb。withNormals = NORMAL を持つか・uv2 = TEXCOORD_1 の値（数が頂点と違ってもよい）。
    def triangleWithUvs2Glb(withNormals: Bool, uv2: List[Float64]): Vector[Int8] =
        let uvCount = List.length(uv2) / 2;
        let normalAttr = if (withNormals) "\"NORMAL\":1," else "";
        let uvAccessor = if (withNormals) 2 else 1;
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,${normalAttr}\"TEXCOORD_1\":${uvAccessor}}}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            (if (withNormals) "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," else "") +
            "{\"bufferView\":${uvAccessor},\"componentType\":5126,\"count\":${uvCount},\"type\":\"VEC2\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," +
            (if (withNormals) "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," else "") +
            "{\"buffer\":0,\"byteOffset\":${if (withNormals) 72 else 36},\"byteLength\":${uvCount * 8}}]," +
            "\"buffers\":[{\"byteLength\":${(if (withNormals) 72 else 36) + uvCount * 8}}]}";
        let positions = TestGltf.f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil);
        let normals = if (withNormals) TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) else Nil;
        TestGltf.glb(json, List.flatten(positions :: normals :: TestGltf.f32s(uv2) :: Nil))

    def firstPartUvs2(bytes: Vector[Int8]): Result[String, Option[Vector[Float64]]] =
        Gltf.fromGlb(bytes) |> Result.map(m -> List.head(m#parts) |> Option.flatMap(p -> Mesh3d.uvs2(p#mesh)))

    def threeUvs(): List[Float64] = 0.25 :: 0.5 :: 0.75 :: 0.125 :: 0.375 :: 0.625 :: Nil

    @Test
    def testTexcoord1IsReadAsIs(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(List.toVector(threeUvs()))), firstPartUvs2(triangleWithUvs2Glb(true, threeUvs())))

    @Test
    def testTexcoord1FollowsCornersWithoutNormals(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(List.toVector(threeUvs()))), firstPartUvs2(triangleWithUvs2Glb(false, threeUvs())))

    /// firstPartUvs2 と、読む間に stderr へ TEXCOORD_1 を名指す 1 行が出たか（TestGltf.firstPartUvsWarned と同じ受け方）。
    def firstPartUvs2Warned(bytes: Vector[Int8]): (Result[String, Option[Vector[Float64]]], Bool) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let uvs = firstPartUvs2(Vector.drop(buf.size(), bytes));
        System.setErr(old);
        (uvs, String.contains(substr = "TEXCOORD_1", buf.toString()))

    @Test
    def testTexcoord1WithWrongCountIsDroppedAndTold(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Ok(None), true), firstPartUvs2Warned(triangleWithUvs2Glb(true, 0.0 :: 0.0 :: 1.0 :: 1.0 :: Nil)))

    @Test
    def testGlbWithoutTexcoord1HasNoUvs2(): Unit \ Assert =
        Assert.assertEq(expected = Ok(None),
            Gltf.fromGlb(TestGltf.triangleWithUvsGlb(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil))
                |> Result.map(m -> List.head(m#parts) |> Option.flatMap(p -> Mesh3d.uvs2(p#mesh))))

    @Test
    def testTexcoord1IsReadByLoadTexturedToo(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok(Some(List.toVector(threeUvs()))),
            Gltf.fromGlbTextured(triangleWithUvs2Glb(true, threeUvs())) |> Result.map(m -> List.head(m#parts) |> Option.flatMap(p -> Mesh3d.uvs2(p#mesh))))
}
