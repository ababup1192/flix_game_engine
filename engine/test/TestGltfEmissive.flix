// glb の emissive（loadTextured）: 材質の 4 通り（baseColorTexture の有無 × emissive の有無）・emission の値（factor × strength・絵 × 定数）・
// spec の名前（木の形を変える物で分かれ、絵の名前では分かれない・emissive の無い材質は今の名前）・読めない emissiveTexture・
// GltfMaterial の欄（alphaMode・alphaCutoff・doubleSided・絵の名前）。
mod TestGltf.Emissive {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    /// 三角 1 枚（uv の有無を選ぶ）・材質 1 つ（materialJson）・2 色の画像 2 枚（画像 0 = baseColor の色 base・画像 1 = emissive の色 glow）の .glb。
    /// textures[0] = 画像 0（sampler 0 = Linear）・textures[1] = 画像 1（sampler 1 = emissiveSampler の magFilter）。
    def glbWith(materialJson: String, uv: Bool, base: Int32, glow: Int32, emissiveSampler: Int32): Vector[Int8] \ IO =
        let baseImage = TestGltf.padded(0i8, TestGltf.onePixelPng(base));
        let glowImage = TestGltf.padded(0i8, TestGltf.onePixelPng(glow));
        let geometry = List.flatten(TestGltf.f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil) ::
                                    TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) ::
                                    TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) :: Nil);
        let baseAt = List.length(geometry);
        let glowAt = baseAt + List.length(baseImage);
        let attributes = if (uv) "\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2" else "\"POSITION\":0,\"NORMAL\":1";
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{${attributes}},\"material\":0}]}]," +
            "\"materials\":[${materialJson}]," +
            "\"samplers\":[{\"magFilter\":9729},{\"magFilter\":${emissiveSampler}}]," +
            "\"textures\":[{\"source\":0,\"sampler\":0},{\"source\":1,\"sampler\":1}]," +
            "\"images\":[{\"bufferView\":3,\"mimeType\":\"image/png\"},{\"bufferView\":4,\"mimeType\":\"image/png\"}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," +
            "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}," +
            "{\"buffer\":0,\"byteOffset\":${baseAt},\"byteLength\":${List.length(baseImage)}}," +
            "{\"buffer\":0,\"byteOffset\":${glowAt},\"byteLength\":${List.length(glowImage)}}]," +
            "\"buffers\":[{\"byteLength\":${glowAt + List.length(glowImage)}}]}";
        TestGltf.glb(json, List.flatten(geometry :: baseImage :: glowImage :: Nil))

    def red(): Int32 = -65536

    def green(): Int32 = -16711936

    def linear(): Int32 = 9729

    def nearest(): Int32 = 9728

    /// 材質の JSON の欄（"baseColorTexture" を足すなら pbrMetallicRoughness に）。
    def withBase(rest: String): String = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0}}${rest}}"

    def withoutBase(rest: String): String = "{\"name\":\"glow\"${rest}}"

    def glowTexture(): String = ",\"emissiveTexture\":{\"index\":1}"

    def strength(s: String): String = ",\"extensions\":{\"KHR_materials_emissive_strength\":{\"emissiveStrength\":${s}}}"

    def read(bytes: Vector[Int8]): Model3d.Model3d \ IO = TestGltf.okOrBug(Gltf.fromGlbTextured(bytes))

    def firstPart(m: Model3d.Model3d): Model3d.ModelPart = match List.head(m#parts) {
        case Some(p) => p
        case None    => bug!("part が無い")
    }

    /// 最初の part の材質の spec の名前（材質が無ければ None）。
    def specNameOf(m: Model3d.Model3d): Option[String] =
        firstPart(m)#material |> Option.map(mat -> Scene3d.materialFieldsOf(mat)#spec#name)

    /// 最初の part の材質に emission が付いているか（材質が無ければ None）。
    def emissionPresenceOf(m: Model3d.Model3d): Option[Bool] =
        firstPart(m)#material |> Option.map(mat -> Option.nonEmpty(Scene3d.materialFieldsOf(mat)#emission))

    /// bytes を読んだ時の spec の名前と、読む間に stderr へ "emissiveTexture" を名指す行が出たか。
    /// 差し替えた後に読んだ数（いつも 0）だけバイトを落としてから読む（TestGltf.loadSkinned と同じ理由）。
    def readWarned(bytes: Vector[Int8]): (Option[String], Bool) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let name = specNameOf(read(Vector.drop(buf.size(), bytes)));
        System.setErr(old);
        (name, String.contains(substr = "emissiveTexture", buf.toString()))

    // ════════════════════════════════════════════════════════════════════
    // 材質の 4 通り
    // ════════════════════════════════════════════════════════════════════

    /// baseColorTexture だけ（emissive 無し）の材質は今の texturedMaterial の名前のまま・emission 無し。
    @Test
    def testBaseOnlyKeepsTheTexturedName(): Unit \ {Assert, IO} =
        let m = read(glbWith(withBase(""), true, red(), green(), linear()));
        Assert.assertEq(expected = (Some("scene3d:textured:Linear"), Some(false)), (specNameOf(m), emissionPresenceOf(m)))

    /// 絵 + emissiveTexture（factor 1・strength 40）は emission つきで、名前に絵の読み方と値が入る。emissive の絵も textures に入る。
    @Test
    def testBaseAndEmissiveTextureGetsEmission(): Unit \ {Assert, IO} =
        let m = read(glbWith(withBase(",\"emissiveFactor\":[1,1,1]" + glowTexture() + strength("40")), true, red(), green(), linear()));
        Assert.assertEq(expected = (Some("gltf:tex:Linear:etLinear(40.0,40.0,40.0)"), Some(true), 2),
            (specNameOf(m), emissionPresenceOf(m), List.length(m#textures)))

    /// baseColorTexture の無い emissive だけの材質は、頂点の色の材質に emission（定数）が付く。
    @Test
    def testEmissiveOnlyMaterialGetsVertexColorBase(): Unit \ {Assert, IO} =
        let m = read(glbWith(withoutBase(",\"emissiveFactor\":[1,0.5,0]"), true, red(), green(), linear()));
        Assert.assertEq(expected = (Some("gltf:vc:ec(1.0,0.5,0.0)"), Some(true)), (specNameOf(m), emissionPresenceOf(m)))

    /// 絵の無い emissive の emission は Solid（factor × strength）。
    @Test
    def testEmissiveWithoutTextureIsSolid(): Unit \ {Assert, IO} =
        let m = read(glbWith(withoutBase(",\"emissiveFactor\":[0.5,0.5,0.5]" + strength("4")), true, red(), green(), linear()));
        let emission = firstPart(m)#material |> Option.flatMap(mat -> Scene3d.materialFieldsOf(mat)#emission);
        Assert.assertEq(expected = Some((2.0, 2.0, 2.0)), match emission {
            case Some(ShaderDoc.Shade.Solid(c)) => Some((c#r, c#g, c#b))
            case _                              => None
        })

    /// factor が 0 なら emissiveTexture を指していても光らず（絵も無い材質は None）、絵を decode しない。
    @Test
    def testZeroFactorDoesNotGlowNorDecode(): Unit \ {Assert, IO} =
        let m = read(glbWith(withoutBase(glowTexture()), true, red(), green(), linear()));
        Assert.assertEq(expected = (None, 0), (specNameOf(m), List.length(m#textures)))

    // ════════════════════════════════════════════════════════════════════
    // spec の名前
    // ════════════════════════════════════════════════════════════════════

    /// 同じ factor でも「絵 × 定数」と「定数だけ」は名前が分かれる（木の形が違う）。
    @Test
    def testTextureAndConstantNamesDiffer(): Unit \ {Assert, IO} =
        let withTexture = specNameOf(read(glbWith(withoutBase(",\"emissiveFactor\":[1,1,1]" + glowTexture()), true, red(), green(), linear())));
        let constant = specNameOf(read(glbWith(withoutBase(",\"emissiveFactor\":[1,1,1]"), true, red(), green(), linear())));
        Assert.assertEq(expected = (Some("gltf:vc:etLinear(1.0,1.0,1.0)"), Some("gltf:vc:ec(1.0,1.0,1.0)")), (withTexture, constant))

    /// 絵の中身（名前）が違うだけなら名前は同じ（同じプログラムを使い回す）。
    @Test
    def testImageContentDoesNotChangeTheName(): Unit \ {Assert, IO} =
        let materialJson = withBase(",\"emissiveFactor\":[1,1,1]" + glowTexture());
        Assert.assertEq(expected = specNameOf(read(glbWith(materialJson, true, red(), green(), linear()))),
            specNameOf(read(glbWith(materialJson, true, green(), red(), linear()))))

    /// emissive の絵の sampler が Nearest で baseColor が Linear なら、名前の絵の読み方が分かれる。
    @Test
    def testEmissiveSamplerEntersTheName(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some("gltf:tex:Linear:etNearest(1.0,1.0,1.0)"),
            specNameOf(read(glbWith(withBase(",\"emissiveFactor\":[1,1,1]" + glowTexture()), true, red(), green(), nearest()))))

    // ════════════════════════════════════════════════════════════════════
    // 読めない emissiveTexture
    // ════════════════════════════════════════════════════════════════════

    /// texCoord 1 の emissiveTexture は光らせず（Solid へ倒さない）、知らせが出る。絵の無い材質なので None。
    @Test
    def testTexCoordOneDoesNotGlowAndWarns(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (None, true),
            readWarned(glbWith(withoutBase(",\"emissiveFactor\":[1,1,1],\"emissiveTexture\":{\"index\":1,\"texCoord\":1}"), true, red(), green(), linear())))

    /// TEXCOORD_0 の無い形には、emissiveTexture の emission を外した材質（今の texturedMaterial）が付き、知らせが出る。
    @Test
    def testNoUvPartDropsTextureEmissionAndWarns(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Some("scene3d:textured:Linear"), true),
            readWarned(glbWith(withBase(",\"emissiveFactor\":[1,1,1]" + glowTexture()), false, red(), green(), linear())))

    // ════════════════════════════════════════════════════════════════════
    // GltfMaterial の欄
    // ════════════════════════════════════════════════════════════════════

    /// alphaMode の 3 通り（無し = Opaque）・alphaCutoff の既定 0.5・doubleSided。
    @Test
    def testGltfMaterialReadsAlphaAndSides(): Unit \ {Assert, IO} =
        let info = (rest: String) -> firstPart(read(glbWith(withoutBase(rest), true, red(), green(), linear())))#gltfMaterial
            |> Option.map(g -> (g#name, g#alphaMode, g#alphaCutoff, g#doubleSided));
        Assert.assertEq(expected = Some(("glow", Model3d.AlphaMode.Opaque, 0.5, false)) :: Some(("glow", Model3d.AlphaMode.Mask, 0.25, false))
                                   :: Some(("glow", Model3d.AlphaMode.Blend, 0.5, true)) :: Nil,
            info("") :: info(",\"alphaMode\":\"MASK\",\"alphaCutoff\":0.25") :: info(",\"alphaMode\":\"BLEND\",\"doubleSided\":true") :: Nil)

    /// 読めた絵の名前（baseColor・emissive）と emissive（factor × strength）が入る。
    @Test
    def testGltfMaterialNamesTheTextures(): Unit \ {Assert, IO} =
        let m = read(glbWith(withBase(",\"emissiveFactor\":[1,0.5,0]" + glowTexture() + strength("2")), true, red(), green(), linear()));
        let names = m#textures |> List.map(Texture3d.name);
        Assert.assertEq(expected = Some((List.head(names), None, List.head(List.drop(1, names)), (2.0, 1.0, 0.0))),
            firstPart(m)#gltfMaterial |> Option.map(g -> (g#baseColorTexture, g#normalTexture, g#emissiveTexture, (g#emissive#r, g#emissive#g, g#emissive#b))))

    /// 絵を読まない fromGlb も GltfMaterial を入れ、絵の名前は None・材質は None。
    @Test
    def testFromGlbKeepsInfoWithoutTextures(): Unit \ {Assert, IO} =
        let m = TestGltf.okOrBug(Gltf.fromGlb(glbWith(withBase(",\"emissiveFactor\":[1,1,1]" + glowTexture()), true, red(), green(), linear())));
        Assert.assertEq(expected = (Some((None, None)), false),
            (firstPart(m)#gltfMaterial |> Option.map(g -> (g#baseColorTexture, g#emissiveTexture)), Option.nonEmpty(firstPart(m)#material)))

    // ════════════════════════════════════════════════════════════════════
    // 材質の口
    // ════════════════════════════════════════════════════════════════════

    /// withoutEmission は emission を外し、withSpecName は名前だけを替える。
    @Test
    def testWithoutEmissionAndWithSpecName(): Unit \ {Assert, IO} =
        let m = read(glbWith(withBase(",\"emissiveFactor\":[1,1,1]"), true, red(), green(), linear()));
        let changed = firstPart(m)#material |> Option.map(mat -> Scene3d.materialFieldsOf(mat |> Scene3d.withoutEmission |> Scene3d.withSpecName("night:sign")));
        Assert.assertEq(expected = Some(("night:sign", false)), changed |> Option.map(f -> (f#spec#name, Option.nonEmpty(f#emission))))

    // ════════════════════════════════════════════════════════════════════
    // 資材（testdata/emissive_plates.glb）
    // ════════════════════════════════════════════════════════════════════

    /// 板 2 枚と印の点: sign は絵 × emissive の名前・flame（uv なし・絵なし）は頂点の色 + 定数の名前・tip は mesh の無いノード。
    @Test
    def testEmissivePlatesAsset(): Unit \ {Assert, Fs.FileRead, IO} =
        let m = TestGltf.okOrBug(Gltf.loadTextured("test/data/testdata/emissive_plates.glb"));
        let names = m#parts |> List.map(p -> p#material |> Option.map(mat -> Scene3d.materialFieldsOf(mat)#spec#name));
        Assert.assertEq(expected = (Some("gltf:tex:Nearest:etNearest(2.0,2.0,2.0)") :: Some("gltf:vc:ec(1.0,0.62,0.18)") :: Nil,
                                    "sign" :: "flame" :: "tip" :: Nil, Nil),
            (names, m#nodes |> List.map(n -> n#name), Model3d.findNode("tip", m) |> Option.map(n -> n#parts) |> Option.getWithDefault(0 :: Nil)))
}
