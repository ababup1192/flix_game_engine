// glb の metallic・roughness（loadTextured）: 付く条件（pbrMetallicRoughness に metallicFactor・roughnessFactor・metallicRoughnessTexture のどれかがある）・
// 書いていない値の既定（1）・絵の読み方（B = metallic・G = roughness）・読めない絵と uv の無い形での値だけへの倒れ方・GltfMaterial の欄。
mod TestGltf.Metallic {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    /// 三角 1 枚（uv の有無を選ぶ）・材質 1 つ（materialJson）・画像 2 枚（画像 0 = baseColor・画像 1 = metallicRoughness）の .glb。
    def glbWith(materialJson: String, uv: Bool): Vector[Int8] \ IO =
        let baseImage = TestGltf.padded(0i8, TestGltf.onePixelPng(-65536));
        let ormImage = TestGltf.padded(0i8, TestGltf.onePixelPng(-16711936));
        let geometry = List.flatten(TestGltf.f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil) ::
                                    TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) ::
                                    TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) :: Nil);
        let baseAt = List.length(geometry);
        let ormAt = baseAt + List.length(baseImage);
        let attributes = if (uv) "\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2" else "\"POSITION\":0,\"NORMAL\":1";
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{${attributes}},\"material\":0}]}]," +
            "\"materials\":[${materialJson}]," +
            "\"textures\":[{\"source\":0},{\"source\":1}]," +
            "\"images\":[{\"bufferView\":3,\"mimeType\":\"image/png\"},{\"bufferView\":4,\"mimeType\":\"image/png\"}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," +
            "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}," +
            "{\"buffer\":0,\"byteOffset\":${baseAt},\"byteLength\":${List.length(baseImage)}}," +
            "{\"buffer\":0,\"byteOffset\":${ormAt},\"byteLength\":${List.length(ormImage)}}]," +
            "\"buffers\":[{\"byteLength\":${ormAt + List.length(ormImage)}}]}";
        TestGltf.glb(json, List.flatten(geometry :: baseImage :: ormImage :: Nil))

    /// pbrMetallicRoughness の欄（materialJson の中身）。
    def pbr(inside: String): String = "{\"pbrMetallicRoughness\":{${inside}}}"

    def read(bytes: Vector[Int8]): Model3d.Model3d \ IO = TestGltf.okOrBug(Gltf.fromGlbTexturedPbrUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(), bytes))

    def firstPart(m: Model3d.Model3d): Model3d.ModelPart = match List.head(m#parts) {
        case Some(p) => p
        case None    => bug!("part が無い")
    }

    /// 最初の part の材質の metallic・roughness・絵の名前（材質が無ければ None・付いていなければ Some(None)）。
    def metallicOf(m: Model3d.Model3d): Option[Option[(Float64, Float64, Option[String])]] =
        firstPart(m)#material |> Option.map(mat -> Scene3d.metallicRoughnessOf(mat) |> Option.map(mr -> (mr#metallic, mr#roughness, mr#texture)))

    def base(): String = "\"baseColorTexture\":{\"index\":0}"

    def orm(): String = "\"metallicRoughnessTexture\":{\"index\":1}"

    /// 既存の loadTexturedUsing は metallic・roughness を付けず、画像も読まない（0.91.0 と同じ材質）。値は GltfMaterial に載る。
    @Test
    def testPlainLoaderIgnoresMetallicRoughness(): Unit \ {Assert, IO} =
        let m = TestGltf.okOrBug(Gltf.fromGlbTexturedUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(),
            glbWith(pbr(base() + "," + orm() + ",\"metallicFactor\":0.25,\"roughnessFactor\":0.75"), true)));
        Assert.assertEq(expected = (Some(false), 1, Some((0.25, 0.75, false))),
            (firstPart(m)#material |> Option.map(mat -> Option.nonEmpty(Scene3d.metallicRoughnessOf(mat))), List.length(m#textures),
             firstPart(m)#gltfMaterial |> Option.map(g -> (g#metallic, g#roughness, Option.nonEmpty(g#metallicRoughnessTexture)))))

    /// 絵も emissive も無い材質は、既存の loadTexturedUsing では None（頂点の色で描く）のまま。
    @Test
    def testPlainLoaderKeepsVertexColorOnlyMaterialsNone(): Unit \ {Assert, IO} =
        let m = TestGltf.okOrBug(Gltf.fromGlbTexturedUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(),
            glbWith(pbr("\"metallicFactor\":0,\"roughnessFactor\":0.5"), true)));
        Assert.assertEq(expected = None, firstPart(m)#material |> Option.map(mat -> Scene3d.materialFieldsOf(mat)#spec#name))

    /// baseColorFactor 0.5: 既存の口は画面の値として 0.5 のまま、PBR の口は線形の値として読み、頂点の色（画面の値）へ linearToSrgb(0.5) で戻して書く。
    @Test
    def testPbrLoaderReadsBaseColorFactorAsLinear(): Unit \ {Assert, IO} =
        let bytes = glbWith(pbr("\"baseColorFactor\":[0.5,0.5,0.5,1],\"metallicFactor\":0.2"), true);
        let redOf = (m: Model3d.Model3d) -> Vector.get(0, Mesh3d.colors(firstPart(m)#mesh));
        let plain = TestGltf.okOrBug(Gltf.fromGlbTexturedUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(), bytes));
        Assert.assertEq(expected = (0.5, Texture3d.linearToSrgb(0.5)), (redOf(plain), redOf(read(bytes))))

    /// pbrMetallicRoughness が無い材質は付かない（材質の無い物は頂点の色のまま）。
    @Test
    def testNoPbrObjectHasNoMaterial(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = None, metallicOf(read(glbWith("{\"name\":\"plain\"}", true))))

    /// baseColor だけの材質（絵あり）は metallic・roughness を付けない（glTF の既定の 1 を当てると、色だけの古い glb が全部金属に見える）。
    @Test
    def testBaseColorOnlyHasNoMetallicRoughness(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(None), metallicOf(read(glbWith(pbr(base()), true))))

    /// baseColorFactor だけで絵も emissive も無い材質は材質を持たない。
    @Test
    def testBaseColorFactorOnlyHasNoMaterial(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = None, metallicOf(read(glbWith(pbr("\"baseColorFactor\":[0.2,0.6,0.9,1]"), true))))

    /// metallicFactor だけ → roughness は 1。roughnessFactor だけ → metallic は 1。
    @Test
    def testMissingFactorDefaultsToOne(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Some(Some((0.3, 1.0, None))), Some(Some((1.0, 0.4, None)))),
            (metallicOf(read(glbWith(pbr(base() + ",\"metallicFactor\":0.3"), true))),
             metallicOf(read(glbWith(pbr(base() + ",\"roughnessFactor\":0.4"), true)))))

    /// 絵が無く emissive も無い材質も、metallic・roughness を書いてあれば頂点の色の土台（"gltf:vc"）の材質になる。
    @Test
    def testFactorsMakeAVertexColorMaterial(): Unit \ {Assert, IO} =
        let m = read(glbWith(pbr("\"metallicFactor\":0,\"roughnessFactor\":0.5"), true));
        Assert.assertEq(expected = (Some(Some((0.0, 0.5, None))), Some("gltf:vc")),
            (metallicOf(m), firstPart(m)#material |> Option.map(mat -> Scene3d.materialFieldsOf(mat)#spec#name)))

    /// metallicRoughnessTexture だけ → 係数は 1・1 で、絵の名前が付く。絵は textures に入る。
    @Test
    def testTextureOnlyUsesFactorOneAndTheTexture(): Unit \ {Assert, IO} =
        let m = read(glbWith(pbr(base() + "," + orm()), true));
        let flagged = metallicOf(m) |> Option.map(o -> o |> Option.map(t -> { let (a, b, c) = t; (a, b, Option.nonEmpty(c)) }));
        Assert.assertEq(expected = (Some(Some((1.0, 1.0, true))), 2), (flagged, List.length(m#textures)))

    /// 絵の読み方は glTF の決まり（B = metallic・G = roughness）。係数は絵に掛かる。
    @Test
    def testTextureReadsBlueAndGreen(): Unit \ {Assert, IO} =
        let m = read(glbWith(pbr(base() + "," + orm() + ",\"metallicFactor\":0.5"), true));
        let shade = firstPart(m)#material |> Option.flatMap(mat -> Scene3d.materialFieldsOf(mat)#metallicRoughnessShade);
        let channels = match shade {
            case Some(ShaderDoc.Shade.Rgb(c)) => (chanOf(c#r), chanOf(c#g))
            case _                            => (None, None)
        };
        Assert.assertEq(expected = (Some(ShaderDoc.TexChan.B), Some(ShaderDoc.TexChan.G)), channels)

    def chanOf(f: ShaderDoc.Field): Option[ShaderDoc.TexChan] = match f {
        case ShaderDoc.Field.Bin(b) => match b#b {
            case ShaderDoc.Field.Sampler(s) => match s#of {
                case ShaderDoc.Field.Tex(t) => Some(t#chan)
                case _                      => None
            }
            case _ => None
        }
        case _ => None
    }

    /// 読めない絵（texCoord 1）は値だけにして（画像は decode しない）、metallicRoughnessTexture を名指す知らせが出る。
    @Test
    def testTexCoordOneFallsBackToValuesAndWarns(): Unit \ {Assert, IO} =
        let bytes = glbWith(pbr(base() + ",\"metallicRoughnessTexture\":{\"index\":1,\"texCoord\":1},\"metallicFactor\":0.2"), true);
        let ((result, textureCount), warned) = readWarned(bytes);
        Assert.assertEq(expected = (Some(Some((0.2, 1.0, None))), 1, true), (result, textureCount, warned))

    /// TEXCOORD_0 の無い形には絵を付けず値だけの材質が付き、知らせが出る。
    @Test
    def testNoUvPartDropsTheTextureAndWarns(): Unit \ {Assert, IO} =
        let ((result, _), warned) = readWarned(glbWith(pbr(base() + "," + orm() + ",\"roughnessFactor\":0.6"), false));
        Assert.assertEq(expected = (Some(Some((1.0, 0.6, None))), true), (result, warned))

    /// bytes を読んだ時の metallicOf と絵の数と、読む間に stderr へ "metallicRoughnessTexture" を名指す行が出たか。
    def readWarned(bytes: Vector[Int8]): ((Option[Option[(Float64, Float64, Option[String])]], Int32), Bool) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let model = read(Vector.drop(buf.size(), bytes));
        let result = (metallicOf(model), List.length(model#textures));
        System.setErr(old);
        (result, String.contains(substr = "metallicRoughnessTexture", buf.toString()))

    /// GltfMaterial に metallic・roughness（書いていなければ 1）と絵の名前が載る。
    @Test
    def testGltfMaterialCarriesTheValues(): Unit \ {Assert, IO} =
        let given = firstPart(read(glbWith(pbr(base() + "," + orm() + ",\"metallicFactor\":0.25,\"roughnessFactor\":0.75"), true)))#gltfMaterial;
        let missing = firstPart(read(glbWith(pbr(base()), true)))#gltfMaterial;
        Assert.assertEq(expected = (Some((0.25, 0.75, true)), Some((1.0, 1.0, false))),
            (given |> Option.map(g -> (g#metallic, g#roughness, Option.nonEmpty(g#metallicRoughnessTexture))),
             missing |> Option.map(g -> (g#metallic, g#roughness, Option.nonEmpty(g#metallicRoughnessTexture)))))

    /// withoutMetallicRoughness で外すと、今までの絵（付ける前と同じ鍵）に戻る。
    @Test
    def testWithoutMetallicRoughnessDropsIt(): Unit \ {Assert, IO} =
        let m = read(glbWith(pbr(base() + ",\"metallicFactor\":0,\"roughnessFactor\":0.5"), true));
        let dropped = firstPart(m)#material |> Option.map(mat -> Option.nonEmpty(Scene3d.metallicRoughnessOf(Scene3d.withoutMetallicRoughness(mat))));
        Assert.assertEq(expected = Some(false), dropped)
}
