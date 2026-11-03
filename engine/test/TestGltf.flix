// TestGltf — glTF の読み込み（Gltf.fromGlb / load）。小さな GLB をテストの中でバイトに組んで、
// accessor の読み方（byteStride・normalized・UNSIGNED_SHORT）・CUBICSPLINE・読まない物の Err・
// 右手系 → 左手系の写し方（X の反転・巡りの裏返し）を確かめ、Blender で書き出した two_joints.glb で向きを確かめる。
mod TestGltf {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import javax.imageio.ImageIO
    import java.lang.Float
    import java.lang.System

    // ════════════════════════════════════════════════════════════════════
    // GLB を組む
    // ════════════════════════════════════════════════════════════════════

    def le32(v: Int32): List[Int8] =
        List.range(0, 4) |> List.map(k -> Int32.truncateToInt8(Int32.bitwiseAnd(Int32.logicalRightShift(dist = 8 * k, v), 0xFF)))

    def le16(v: Int32): List[Int8] = List.take(2, le32(v))

    def f32s(xs: List[Float64]): List[Int8] =
        List.flatMap(x -> le32(Float.floatToIntBits(Float64.truncateToFloat32(x))), xs)

    def u16s(xs: List[Int32]): List[Int8] = List.flatMap(le16, xs)

    def u8s(xs: List[Int32]): List[Int8] = List.map(Int32.truncateToInt8, xs)

    /// 4 の倍数の長さへ fill で詰める。
    def padded(fill: Int8, bytes: List[Int8]): List[Int8] =
        List.append(bytes, List.repeat(Int32.remainder(4 - Int32.remainder(List.length(bytes), 4), 4), fill))

    /// 1 × 1 の PNG のバイト（argb の色。-65536 = 不透明の赤・-16711936 = 不透明の緑）。
    def onePixelPng(argb: Int32): List[Int8] \ IO = squarePng(1, argb)

    /// side × side の一色の PNG のバイト。
    def squarePng(side: Int32, argb: Int32): List[Int8] \ IO =
        let image = new BufferedImage(side, side, BufferedImage.TYPE_INT_ARGB);
        List.range(0, side * side) |> List.forEach(k -> image.setRGB(Int32.remainder(k, side), k / side, argb));
        let out = new ByteArrayOutputStream();
        discard ImageIO.write(image, "png", out);
        Array.toList(out.toByteArray())

    /// JSON の字と BIN のバイトから .glb を組む（JSON は空白・BIN は 0 で 4 の倍数へ詰める）。
    def glb(json: String, bin: List[Int8]): Vector[Int8] =
        let jsonBytes = padded(32i8, Vector.toList(String.toBytes(json)));
        let binBytes = padded(0i8, bin);
        let total = 12 + 8 + List.length(jsonBytes) + 8 + List.length(binBytes);
        List.flatten(le32(0x46546C67) :: le32(2) :: le32(total) ::
                     le32(List.length(jsonBytes)) :: le32(0x4E4F534A) :: jsonBytes ::
                     le32(List.length(binBytes)) :: le32(0x004E4942) :: binBytes :: Nil)
            |> List.toVector

    /// 三角 1 枚の .glb（skin なし）。glTF の座標で (−1, 0, 0)・(1, 0, 0)・(0, 1, 0) の反時計回り（+Z から見て表）、法線 +Z。
    /// primitiveExtra・bufferExtra は primitive と buffers[0] の JSON に足す欄。
    def triangleGlb(primitiveExtra: String, bufferExtra: String): Vector[Int8] =
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1}${primitiveExtra}}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}]," +
            "\"buffers\":[{\"byteLength\":72${bufferExtra}}]}";
        glb(json, List.append(f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil),
                              f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil)))

    /// triangleGlb と同じ三角に、uvs を TEXCOORD_0（VEC2・count = uvs の数 / 2）として足した .glb。
    def triangleWithUvsGlb(uvs: List[Float64]): Vector[Int8] =
        let uvCount = List.length(uvs) / 2;
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2}}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":2,\"componentType\":5126,\"count\":${uvCount},\"type\":\"VEC2\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," +
            "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":${uvCount * 8}}]," +
            "\"buffers\":[{\"byteLength\":${72 + uvCount * 8}}]}";
        glb(json, List.flatten(f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil) ::
                               f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) :: f32s(uvs) :: Nil))

    /// fromGlb で読んだ最初の part の uv（読めなければ Err のまま）。
    def firstPartUvs(bytes: Vector[Int8]): Result[String, Option[Vector[Float64]]] =
        Gltf.fromGlb(bytes) |> Result.map(m -> List.head(m#parts) |> Option.flatMap(p -> Mesh3d.uvs(p#mesh)))

    /// firstPartUvs と、読む間に stderr へ TEXCOORD_0 を名指す 1 行が出たか。
    /// 差し替えた後に読んだ数（いつも 0）だけバイトを落としてから読む（loadSkinned と同じ理由）。
    def firstPartUvsWarned(bytes: Vector[Int8]): (Result[String, Option[Vector[Float64]]], Bool) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let uvs = firstPartUvs(Vector.drop(buf.size(), bytes));
        System.setErr(old);
        (uvs, String.contains(substr = "TEXCOORD_0", buf.toString()))

    /// triangleGlb と同じ三角を、頂点ごとに 4 つ目の数（99）を挟んだ byteStride 16 の並びで持つ .glb。
    def stridedTriangleGlb(): Vector[Int8] =
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1}}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":48,\"byteStride\":16},{\"buffer\":0,\"byteOffset\":48,\"byteLength\":36}]," +
            "\"buffers\":[{\"byteLength\":84}]}";
        glb(json, List.append(f32s(-1.0 :: 0.0 :: 0.0 :: 99.0 :: 1.0 :: 0.0 :: 0.0 :: 99.0 :: 0.0 :: 1.0 :: 0.0 :: 99.0 :: Nil),
                              f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil)))

    /// skin つきの三角の .glb。ノード 0 = child（root から (0, 1, 0)）・ノード 1 = root・skin.joints = [0, 1]（子が先）。
    /// JOINTS_0 は UNSIGNED_SHORT で 3 頂点とも [0, 0, 0, 0]（= child）、WEIGHTS_0 は normalized の UNSIGNED_BYTE で [51, 204, 0, 0]。
    /// アニメーション "lift" は child の平行移動を CUBICSPLINE で、時刻 0・1 の値が (0, 0, 0)・(0, 2, 0)（入りと出の接線は全部 9）。
    def skinnedGlb(): Vector[Int8] =
        let json = "{\"asset\":{\"version\":\"2.0\"}," +
            "\"nodes\":[{\"name\":\"child\",\"translation\":[0,1,0]},{\"name\":\"root\",\"children\":[0]},{\"mesh\":0,\"skin\":0}]," +
            "\"skins\":[{\"joints\":[0,1]}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"JOINTS_0\":2,\"WEIGHTS_0\":3}}]}]," +
            "\"animations\":[{\"name\":\"lift\",\"channels\":[{\"sampler\":0,\"target\":{\"node\":0,\"path\":\"translation\"}}]," +
            "\"samplers\":[{\"input\":4,\"output\":5,\"interpolation\":\"CUBICSPLINE\"}]}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":2,\"componentType\":5123,\"count\":3,\"type\":\"VEC4\"}," +
            "{\"bufferView\":3,\"componentType\":5121,\"normalized\":true,\"count\":3,\"type\":\"VEC4\"}," +
            "{\"bufferView\":4,\"componentType\":5126,\"count\":2,\"type\":\"SCALAR\"}," +
            "{\"bufferView\":5,\"componentType\":5126,\"count\":6,\"type\":\"VEC3\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," +
            "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24},{\"buffer\":0,\"byteOffset\":96,\"byteLength\":12}," +
            "{\"buffer\":0,\"byteOffset\":108,\"byteLength\":8},{\"buffer\":0,\"byteOffset\":116,\"byteLength\":72}]," +
            "\"buffers\":[{\"byteLength\":188}]}";
        glb(json, List.flatten(
            f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil) ::
            f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) ::
            u16s(0 :: 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: Nil) ::
            u8s(51 :: 204 :: 0 :: 0 :: 51 :: 204 :: 0 :: 0 :: 51 :: 204 :: 0 :: 0 :: Nil) ::
            f32s(0.0 :: 1.0 :: Nil) ::
            f32s(9.0 :: 9.0 :: 9.0 :: 0.0 :: 0.0 :: 0.0 :: 9.0 :: 9.0 :: 9.0 ::
                 9.0 :: 9.0 :: 9.0 :: 0.0 :: 2.0 :: 0.0 :: 9.0 :: 9.0 :: 9.0 :: Nil) :: Nil))

    /// skinnedGlb を読み、読む間に stderr へ出た字と一緒に返す（CUBICSPLINE を知らせる 1 行が出る）。
    /// 差し替えた後に読んだ数（いつも 0）だけバイトを落としてから読む。
    // WhyNot: 引数無しの純粋な読み込みを渡さない — Flix は純粋な式を stderr の差し替えより前へ動かせるので、知らせが差し替える前の stderr に出る。
    def loadSkinned(): (Model3d.Model3d, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let model = okOrBug(Gltf.fromGlb(Vector.drop(buf.size(), skinnedGlb())));
        System.setErr(old);
        (model, buf.toString())

    def okOrBug(r: Result[String, a]): a = match r {
        case Ok(v) => v
        case Err(e) => bug!(e)
    }

    /// 形の頂点 v の位置。
    def positionOf(mesh: Mesh3d.Mesh3d, v: Int32): Vec3.Vec3 =
        let p = Mesh3d.positions(mesh);
        Vec3.v3(Vector.get(v * 3, p), Vector.get(v * 3 + 1, p), Vector.get(v * 3 + 2, p))

    /// Blender で書き出した資材（テストは engine/ で流れる）。
    def twoJoints(): Model3d.Model3d \ Fs.FileRead = okOrBug(Gltf.load("test/data/two_joints.glb"))

    def skinOf(m: Model3d.Model3d): Skin3d.Skin3d = match m#skin {
        case Some(s) => s
        case None => bug!("skin が無い")
    }

    def clipOf(m: Model3d.Model3d, name: String): AnimationClip3d.AnimationClip3d = match Map.get(name, m#clips) {
        case Some(c) => c
        case None => bug!("クリップ ${name} が無い")
    }

    def jointOf(skin: Skin3d.Skin3d, name: String): Int32 = match Skin3d.jointIndex(skin, name) {
        case Some(j) => j
        case None => bug!("ジョイント ${name} が無い")
    }

    // ════════════════════════════════════════════════════════════════════
    // 座標の写し方
    // ════════════════════════════════════════════════════════════════════

    /// glTF の −X の頂点（頂点 0 の (−1, 0, 0)）は engine の +X（(1, 0, 0)）に来る。
    @Test
    def testGltfMirrorsMinusXToPlusX(): Unit \ Assert =
        let p = positionOf(okOrBug(Gltf.fromGlb(triangleGlb("", "")))#mesh, 0);
        Assert.assertEq(expected = (1.0, 0.0, 0.0), (p#x, p#y, p#z))

    /// glTF の表（+Z から見て反時計回り・法線 +Z）は、巡りを逆にして engine でも表（cross(b − a, c − a) が法線の向き）。
    @Test
    def testGltfKeepsFrontFaceFront(): Unit \ Assert =
        let mesh = okOrBug(Gltf.fromGlb(triangleGlb("", "")))#mesh;
        let corner = c -> positionOf(mesh, Vector.get(c, Mesh3d.indices(mesh)));
        let facing = Vec3.cross(Vec3.sub(corner(1), corner(0)), Vec3.sub(corner(2), corner(0)));
        let normal = Vec3.v3(Vector.get(0, Mesh3d.normals(mesh)), Vector.get(1, Mesh3d.normals(mesh)), Vector.get(2, Mesh3d.normals(mesh)));
        Assert.assertTrue(Vec3.dot(facing, normal) > 0.0)

    // ════════════════════════════════════════════════════════════════════
    // 組み立てた GLB
    // ════════════════════════════════════════════════════════════════════

    /// byteStride 16 の並びから、挟んだ 99 を飛ばして位置を読む（x は反転）。
    @Test
    def testGltfReadsByteStride(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Vector#{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0 }),
                        Gltf.fromGlb(stridedTriangleGlb()) |> Result.map(m -> Mesh3d.positions(m#mesh) |> Vector.map(x -> x + 0.0)))

    /// normalized の UNSIGNED_BYTE の重み 51・204 は 51 / 255 = 0.2・204 / 255 = 0.8。
    @Test
    def testGltfReadsNormalizedWeights(): Unit \ {Assert, IO} =
        let weights = Mesh3d.skinWeights(fst(loadSkinned())#mesh) |> Option.getWithDefault(Vector.empty());
        Assert.assertTrue(Float64.abs(Vector.get(0, weights) - 0.2) + Float64.abs(Vector.get(1, weights) - 0.8) < 1.0e-9)

    /// UNSIGNED_SHORT の JOINTS_0 を読み、子が先の skin.joints を親が先へ並べ替えた番号へ付け替える
    /// （4 つの欄とも skin.joints の 0 番目 = child なので、並べ替えた後の 1 が 4 つ）。
    @Test
    def testGltfReadsUnsignedShortJointsAndReorders(): Unit \ {Assert, IO} =
        let model = fst(loadSkinned());
        Assert.assertEq(expected = (Vector#{ "root", "child" }, Some(Vector#{ 1, 1, 1, 1 })),
                        (Skin3d.names(skinOf(model)), Mesh3d.skinJoints(model#mesh) |> Option.map(Vector.take(4))))

    /// CUBICSPLINE は (入り, 値, 出) の真ん中を取る: 1 秒目の child の平行移動の y は 2（接線の 9 ではない）。捨てたことを 1 行知らせる。
    @Test
    def testGltfTakesMiddleOfCubicSpline(): Unit \ {Assert, IO} =
        let (model, err) = loadSkinned();
        let skin = skinOf(model);
        let poses = AnimationClip3d.sample(skin, clipOf(model, "lift"), 1.0, false);
        Assert.assertEq(expected = (2.0, true), (Vector.get(jointOf(skin, "child"), poses)#translation#y, String.contains(substr = "CUBICSPLINE", err)))

    /// 途中で切れたバイト（最後の 4 バイトが無い）は Err。
    @Test
    def testGltfRejectsTruncatedBytes(): Unit \ Assert =
        let bytes = triangleGlb("", "");
        Assert.assertTrue(Result.isErr(Gltf.fromGlb(Vector.take(Vector.length(bytes) - 4, bytes))))

    /// mode 1（線）の primitive は Err。
    @Test
    def testGltfRejectsNonTriangleMode(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Gltf.fromGlb(triangleGlb(",\"mode\":1", ""))))

    /// 外の uri を持つバッファは Err。
    @Test
    def testGltfRejectsExternalUri(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Gltf.fromGlb(triangleGlb("", ",\"uri\":\"tri.bin\""))))

    /// 有限の TEXCOORD_0 は part の uv になる（uv の (0, 0)・(1, 0)・(0, 1) が頂点の並びのまま）。
    @Test
    def testGltfReadsTexcoordIntoPart(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(Vector#{0.0, 0.0, 1.0, 0.0, 0.0, 1.0})),
                        firstPartUvs(triangleWithUvsGlb(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil)))

    /// NaN のある TEXCOORD_0 は Err にせず、uv なしの part で読んで 1 行知らせる（uv を使わない fromGlb が読めなくならない）。
    @Test
    def testGltfReadsWithoutUvWhenTexcoordHasNaN(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Ok(None), true),
                        firstPartUvsWarned(triangleWithUvsGlb(0.0 :: 0.0 :: Float64.nan() :: 0.0 :: 0.0 :: 1.0 :: Nil)))

    /// 頂点の数（3）と数が違う TEXCOORD_0（2 つ）も、uv なしの part で読んで 1 行知らせる。
    @Test
    def testGltfReadsWithoutUvWhenTexcoordCountDiffers(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Ok(None), true), firstPartUvsWarned(triangleWithUvsGlb(0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil)))

    // ════════════════════════════════════════════════════════════════════
    // Blender の資材（two_joints.glb）
    // ════════════════════════════════════════════════════════════════════

    /// ジョイント 3 本（root・tip・side.R）・クリップ bend・板の頂点 4 つ。
    @Test
    def testTwoJointsHasJointsClipAndVertices(): Unit \ Assert + Fs.FileRead =
        let model = twoJoints();
        Assert.assertEq(expected = (3, "bend" :: Nil, 4),
                        (Skin3d.jointCount(skinOf(model)), Map.keysOf(model#clips) |> Set.toList, Mesh3d.vertexCount(model#mesh)))

    /// bend の長さは 24 fps の 1 〜 25 コマ目の最後 = 25 / 24 秒。
    @Test
    def testTwoJointsBendLastsTwentyFiveFrames(): Unit \ Assert + Fs.FileRead =
        Assert.assertTrue(Float64.abs(AnimationClip3d.duration(clipOf(twoJoints(), "bend")) - 25.0 / 24.0) < 1.0e-6)

    /// レストポーズの joint 行列は単位行列（逆バインド行列と rootTransform を同じ写し方で写した）。
    @Test
    def testTwoJointsRestPoseJointMatricesAreIdentity(): Unit \ Assert + Fs.FileRead =
        let skin = skinOf(twoJoints());
        let mats = Pose3d.jointMatrices(Pose3d.compute(skin, Skin3d.restPose(skin)));
        Assert.assertTrue(Vector.forAll(m -> Vector.zip(Mat4.toColumns(m), Mat4.toColumns(Mat4.identity()))
                                             |> Vector.forAll(pair -> Float64.abs(fst(pair) - snd(pair)) < 1.0e-6), mats))

    /// side.R（Blender の −X 0.3 に置いた、キャラの右）は engine の +X 0.3（右が右）。
    @Test
    def testTwoJointsSideRightIsPlusX(): Unit \ Assert + Fs.FileRead =
        let skin = skinOf(twoJoints());
        let pose = Pose3d.compute(skin, Skin3d.restPose(skin));
        Assert.assertTrue(Float64.abs(Mat4.apply(Pose3d.jointTransform(pose, jointOf(skin, "side.R")), Vec3.zero())#x - 0.3) < 1.0e-6)

    /// bend の終わりでは tip が X 軸まわりに 90 度倒れ、板の上の角 (−0.1, 1, 0) は tip の根元 (0, 0.5, 0) から +Z へ 0.5 の (−0.1, 0.5, 0.5) へ来る。
    @Test
    def testTwoJointsBendTipsForwardAtEnd(): Unit \ Assert + Fs.FileRead =
        let model = twoJoints();
        let skin = skinOf(model);
        let clip = clipOf(model, "bend");
        let mats = Pose3d.jointMatrices(Pose3d.compute(skin, AnimationClip3d.sample(skin, clip, AnimationClip3d.duration(clip), false)));
        let moved = Mat4.apply(Vector.get(jointOf(skin, "tip"), mats), Vec3.v3(-0.1, 1.0, 0.0));
        Assert.assertTrue(Vec3.distanceSquared(moved, Vec3.v3(-0.1, 0.5, 0.5)) < 1.0e-9)

    // ════════════════════════════════════════════════════════════════════
    // 絵と材質（loadTexturedUsing・textured_two_materials.glb）
    // ════════════════════════════════════════════════════════════════════
    // 板 A は材質 A（4 × 4 の絵・左上が赤・NEAREST と、(128, 255, 128) の法線マップ・scale 0.5）、板 B は材質 B（baseColorFactor だけ）。

    def textured(): Model3d.Model3d \ {Fs.FileRead, IO} = okOrBug(Gltf.loadTexturedUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(), "test/data/textured_two_materials.glb"))

    def partAt(m: Model3d.Model3d, k: Int32): Model3d.ModelPart = match List.nth(k, m#parts) {
        case Some(p) => p
        case None => bug!("part ${k} が無い")
    }

    def materialA(m: Model3d.Model3d): Scene3d.MaterialFields = match partAt(m, 0)#material {
        case Some(mat) => Scene3d.materialFieldsOf(mat)
        case None => bug!("板 A に材質が無い")
    }

    /// primitive ごとに part が 2 つ。
    @Test
    def testTexturedPartsPerPrimitive(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = 2, List.length(textured()#parts))

    /// 絵のある材質 A の板だけが材質を持ち、絵の無い材質 B の板は None（頂点の色で描く）。
    @Test
    def testOnlyTexturedMaterialBecomesMaterial(): Unit \ {Assert, Fs.FileRead, IO} =
        let m = textured();
        Assert.assertEq(expected = (true, false), (Option.nonEmpty(partAt(m, 0)#material), Option.nonEmpty(partAt(m, 1)#material)))

    /// 材質 A の絵は 4 × 4 で、左上のテクセルが赤。
    @Test
    def testBaseColorImageTopLeftIsRed(): Unit \ {Assert, Fs.FileRead, IO} =
        let m = textured();
        let name = ShaderDoc.materialTexReads(materialA(m)#spec, None) |> List.head |> Option.map(fst) |> Option.getWithDefault("");
        let image = m#textures |> List.find(t -> Texture3d.name(t) == name);
        Assert.assertEq(expected = Some((4, 4, -65536)),
            Option.map(t -> (Texture3d.width(t), Texture3d.height(t), Vector.get(0, Texture3d.argb(t))), image))

    /// sampler の magFilter が NEAREST の絵は Nearest で読む。
    @Test
    def testNearestSamplerReadsNearest(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Some(ShaderDoc.FilterMode.Nearest),
            ShaderDoc.materialTexReads(materialA(textured())#spec, None) |> List.head |> Option.map(snd))

    /// normalTexture は法線マップになり、strength は scale（0.5）。
    @Test
    def testNormalTextureStrengthIsScale(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = Some(0.5), materialA(textured())#normalMap |> Option.map(n -> n#strength))

    /// 書き出した TANGENT（x と w を反転して読んだ物）は、同じ形と uv から Mesh3d が求めたタンジェントと向きも w も一致する。
    @Test
    def testExportedTangentMatchesComputed(): Unit \ {Assert, Fs.FileRead, IO} =
        let mesh = partAt(textured(), 0)#mesh;
        let exported = Mesh3d.tangents(mesh) |> Option.getWithDefault(Vector.empty());
        let computed = Mesh3d.uvs(mesh) |> Option.flatMap(uv -> Mesh3d.withUvs(uv, mesh) |> Result.toOption) |> Option.flatMap(Mesh3d.tangents)
            |> Option.getWithDefault(Vector.empty());
        Assert.assertEq(expected = (16, true),
            (Vector.length(exported), Vector.length(computed) == 16 and Vector.forAll(pair -> Float64.abs(fst(pair) - snd(pair)) < 1.0e-4, Vector.zip(exported, computed))))

    /// 板 A は uv を持ち、uv の (0, 0)（絵の左上）は板の左上の角（engine の +X 側・上）に来る（glTF の −X が engine の +X）。
    @Test
    def testTexturedPlateTopLeftUvAtTopLeftCorner(): Unit \ {Assert, Fs.FileRead, IO} =
        let mesh = partAt(textured(), 0)#mesh;
        let uvs = Mesh3d.uvs(mesh) |> Option.getWithDefault(Vector.empty());
        let corner = Vector.range(0, Mesh3d.vertexCount(mesh)) |> Vector.find(v -> Vector.get(v * 2, uvs) == 0.0 and Vector.get(v * 2 + 1, uvs) == 0.0)
            |> Option.map(v -> positionOf(mesh, v));
        Assert.assertEq(expected = Some((1.5, 1.0)), Option.map(p -> (p#x, p#y), corner))

    /// 絵を読まない load は、loadTextured と同じ mesh（全部の primitive をつないだ形）を返し、parts の材質は None。
    @Test
    def testLoadKeepsMeshAndHasNoMaterials(): Unit \ {Assert, Fs.FileRead, IO} =
        let plain = okOrBug(Gltf.load("test/data/textured_two_materials.glb"));
        Assert.assertEq(expected = (true, true, 0),
            (Mesh3d.contentHash(plain#mesh) == Mesh3d.contentHash(textured()#mesh),
             List.forAll(p -> Option.isEmpty(p#material), plain#parts), List.length(plain#textures)))
}
