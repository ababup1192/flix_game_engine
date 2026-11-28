// glb の KHR_texture_transform（Gltf.decodeWith）: 材質の全部の絵が同じ transform なら頂点の uv に焼き込む・絵ごとに違えば書き込まずに知らせる・
// 回転の向き（KHR_texture_transform の README の行列）と掛ける順・実際に読む uv の番号で決める書き込む条件・回した uv ではファイルの TANGENT を使わず uv から求め直す。
mod TestGltf.TextureTransform {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    def glbWith(materialJson: String, tangents: Bool): Vector[Int8] \ IO = TestGltf.materialTriangleGlb(materialJson, tangents)

    def read(bytes: Vector[Int8]): Model3d.Model3d \ IO =
        TestGltf.okOrBug(Gltf.decodeWith(TestDecoder.imageIo(), { limits = Gltf.noTextureLimits(), pbr = true | Gltf.defaultLoadOptions() }, None, bytes))

    def firstPart(m: Model3d.Model3d): Model3d.ModelPart = match List.head(m#parts) {
        case Some(p) => p
        case None    => bug!("part が無い")
    }

    def transform(fields: String): String = ",\"extensions\":{\"KHR_texture_transform\":{${fields}}}"

    /// baseColorTexture と metallicRoughnessTexture に同じ transform を書いた材質。
    def sharedMaterial(fields: String): String =
        let t = transform(fields);
        "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0${t}},\"metallicRoughnessTexture\":{\"index\":1${t}}}}"

    def uvsOf(m: Model3d.Model3d): Vector[Float64] = Mesh3d.uvs(firstPart(m)#mesh) |> Option.getWithDefault(Vector.empty())

    def near(expected: Vector[Float64], actual: Vector[Float64]): Bool =
        Vector.length(expected) == Vector.length(actual) and Vector.forAll(pair -> Float64.abs(fst(pair) - snd(pair)) < 1.0e-6, Vector.zip(expected, actual))

    /// 標準エラーへ出た字（f が知らせた行）と f の値。
    def capturingErr(f: Unit -> a \ IO): (a, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let value = f();
        System.setErr(old);
        (value, buf.toString())

    def plainUvs(): Vector[Float64] = Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }

    /// 同じ形と uv から Mesh3d が求めるタンジェント。
    def computedTangents(mesh: Mesh3d.Mesh3d): Option[Vector[Float64]] =
        Mesh3d.uvs(mesh) |> Option.flatMap(uv -> Mesh3d.withUvs(uv, mesh) |> Result.toOption) |> Option.flatMap(Mesh3d.tangents)

    def meshOf(material: String): Mesh3d.Mesh3d \ IO = firstPart(read(glbWith(material, true)))#mesh

    /// 材質の全部の絵が同じ transform なら、頂点の uv に焼き込む（(0,0) (1,0) (0,1) → 平行移動 × 倍率）。
    @Test
    def testSharedTransformIsBakedIntoUvs(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Vector#{ 0.5, 0.25, 2.5, 0.25, 0.5, 3.25 }, uvsOf(read(glbWith(sharedMaterial("\"offset\":[0.5,0.25],\"scale\":[2,3]"), false))))

    /// 回転 π/2 は (1, 0) を (0, −1)・(0, 1) を (1, 0) へ移す（u' = cos × u + sin × v・v' = −sin × u + cos × v。TextureTransformTest の矢印が Correct を指す向き）。
    @Test
    def testRotationFollowsKhrMatrix(): Unit \ {Assert, IO} =
        Assert.assertTrue(near(Vector#{ 0.0, 0.0, 0.0, -1.0, 1.0, 0.0 }, uvsOf(read(glbWith(sharedMaterial("\"rotation\":1.5707963267948966"), false)))))

    /// 倍率（左右で違う）→ 回転 → 平行移動の順に掛ける（(1,0) → (2,0) → (0,−2) → (0.5,−1.75)・(0,1) → (0,3) → (3,0) → (3.5,0.25)）。
    @Test
    def testScaleThenRotateThenOffset(): Unit \ {Assert, IO} =
        let material = sharedMaterial("\"offset\":[0.5,0.25],\"rotation\":1.5707963267948966,\"scale\":[2,3]");
        Assert.assertTrue(near(Vector#{ 0.5, 0.25, 0.5, -1.75, 3.5, 0.25 }, uvsOf(read(glbWith(material, false)))))

    /// 絵ごとに違う transform は焼き込まない（uv はそのまま）。
    @Test
    def testDifferentTransformsAreNotBaked(): Unit \ {Assert, IO} =
        let material = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0${transform("\"offset\":[0.5,0]")}},\"metallicRoughnessTexture\":{\"index\":1}}}";
        let (m, _) = capturingErr(() -> read(glbWith(material, false)));
        Assert.assertEq(expected = plainUvs(), uvsOf(m))

    /// 絵ごとに違う transform は読み飛ばしを知らせる。
    @Test
    def testDifferentTransformsAreReported(): Unit \ {Assert, IO} =
        let material = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0${transform("\"offset\":[0.5,0]")}},\"metallicRoughnessTexture\":{\"index\":1}}}";
        let (_, err) = capturingErr(() -> read(glbWith(material, false)));
        Assert.assertTrue(String.contains(substr = "KHR_texture_transform", err))

    /// baseColor・metallicRoughness と同じ transform で、ほかの絵 1 つ（field）だけが違う材質。
    def oneDifferent(field: String, index: Int32): String =
        let t = transform("\"offset\":[0.5,0]");
        "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0${t}},\"metallicRoughnessTexture\":{\"index\":1${t}}}," +
        "\"emissiveFactor\":[1,1,1],\"${field}\":{\"index\":${index}${transform("\"offset\":[0.25,0]")}}}"

    /// normalTexture だけが違う transform なら書き込まない。
    @Test
    def testDifferentNormalTransformIsNotBaked(): Unit \ {Assert, IO} =
        let (m, _) = capturingErr(() -> read(glbWith(oneDifferent("normalTexture", 0), false)));
        Assert.assertEq(expected = plainUvs(), uvsOf(m))

    /// emissiveTexture だけが違う transform なら書き込まない。
    @Test
    def testDifferentEmissiveTransformIsNotBaked(): Unit \ {Assert, IO} =
        let (m, _) = capturingErr(() -> read(glbWith(oneDifferent("emissiveTexture", 0), false)));
        Assert.assertEq(expected = plainUvs(), uvsOf(m))

    /// occlusionTexture だけが違う transform なら書き込まない。
    @Test
    def testDifferentOcclusionTransformIsNotBaked(): Unit \ {Assert, IO} =
        let (m, _) = capturingErr(() -> read(glbWith(oneDifferent("occlusionTexture", 1), false)));
        Assert.assertEq(expected = plainUvs(), uvsOf(m))

    /// texCoord を 0 でない uv へ上書きする transform は焼き込まない。
    @Test
    def testTexCoordOverrideIsNotBaked(): Unit \ {Assert, IO} =
        let (m, _) = capturingErr(() -> read(glbWith(sharedMaterial("\"offset\":[0.5,0],\"texCoord\":1"), false)));
        Assert.assertEq(expected = plainUvs(), uvsOf(m))

    /// transform の texCoord が無いのと 0 は同じに扱う（片方だけ 0 を書いても書き込む）。
    @Test
    def testMissingAndZeroTexCoordAreTheSame(): Unit \ {Assert, IO} =
        let material = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0${transform("\"offset\":[0.5,0]")}}," +
                       "\"metallicRoughnessTexture\":{\"index\":1${transform("\"offset\":[0.5,0],\"texCoord\":0")}}}}";
        Assert.assertEq(expected = Vector#{ 0.5, 0.0, 1.5, 0.0, 0.5, 1.0 }, uvsOf(read(glbWith(material, false))))

    /// textureInfo の texCoord が 1 でも transform が 0 へ上書きすれば、TEXCOORD_0 に書き込んて絵も読む。
    @Test
    def testTexCoordOverriddenToZeroIsBaked(): Unit \ {Assert, IO} =
        let t = transform("\"offset\":[0.5,0],\"texCoord\":0");
        let material = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0,\"texCoord\":1${t}},\"metallicRoughnessTexture\":{\"index\":1,\"texCoord\":1${t}}}}";
        Assert.assertEq(expected = Vector#{ 0.5, 0.0, 1.5, 0.0, 0.5, 1.0 }, uvsOf(read(glbWith(material, false))))

    /// texCoord を 0 へ上書きして書き込んだ材質は、絵を読み飛ばさない（材質が絵を読む）。
    @Test
    def testTexCoordOverriddenToZeroReadsTexture(): Unit \ {Assert, IO} =
        let t = transform("\"offset\":[0.5,0],\"texCoord\":0");
        let material = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0,\"texCoord\":1${t}},\"metallicRoughnessTexture\":{\"index\":1,\"texCoord\":1${t}}}}";
        Assert.assertEq(expected = Some(true), firstPart(read(glbWith(material, false)))#gltfMaterial |> Option.map(g -> Option.nonEmpty(g#baseColorTexture)))

    /// ずらすだけの transform はファイルの TANGENT をそのまま使う（x と w を反転して読む: (0, 1, 0, 1) → y = 1）。
    @Test
    def testOffsetKeepsFileTangents(): Unit \ {Assert, IO} =
        let tangents = Mesh3d.tangents(meshOf(sharedMaterial("\"offset\":[0.5,0]"))) |> Option.getWithDefault(Vector.empty());
        Assert.assertEq(expected = Some(1.0), Vector.nth(1, tangents))

    /// 回した uv ではファイルの TANGENT を使わず、焼き込んだ uv から求め直す（同じ形と uv から Mesh3d が求めた物と同じ）。
    @Test
    def testRotationRecomputesTangentsFromUvs(): Unit \ {Assert, IO} =
        let mesh = meshOf(sharedMaterial("\"rotation\":0.5"));
        Assert.assertEq(expected = computedTangents(mesh), Mesh3d.tangents(mesh))

    /// 負の倍率（裏返した uv）でもファイルの TANGENT を使わない。
    @Test
    def testNegativeScaleRecomputesTangentsFromUvs(): Unit \ {Assert, IO} =
        let mesh = meshOf(sharedMaterial("\"scale\":[-1,1]"));
        Assert.assertEq(expected = computedTangents(mesh), Mesh3d.tangents(mesh))

    /// 倍率 0 でもファイルの TANGENT を使わない。
    @Test
    def testZeroScaleRecomputesTangentsFromUvs(): Unit \ {Assert, IO} =
        let (mesh, _) = capturingErr(() -> meshOf(sharedMaterial("\"scale\":[0,1]")));
        Assert.assertEq(expected = computedTangents(mesh), Mesh3d.tangents(mesh))

    /// 焼き込んだ材質の絵は transform を読み飛ばした知らせを出さない。
    @Test
    def testBakedTransformIsNotReportedAsSkipped(): Unit \ {Assert, IO} =
        let (_, err) = capturingErr(() -> read(glbWith(sharedMaterial("\"rotation\":0.5"), false)));
        Assert.assertFalse(String.contains(substr = "KHR_texture_transform", err))
}
