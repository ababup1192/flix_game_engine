// glb の occlusionTexture（Gltf.decodeWith の LoadOptions#occlusion）: 既定は読まない・pbr が偽なら読まない・ARM の絵は 1 枚を共有・
// metallic・roughness の付かない材質と TEXCOORD_1 の絵には付けない・GltfMaterial の欄・Scene3d の AO の口（描くかの判定と params）。
mod TestGltf.Metallic.Occlusion {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    def readWith(occlusion: Bool, bytes: Vector[Int8]): Model3d.Model3d \ IO =
        TestGltf.okOrBug(Gltf.decodeWith(TestDecoder.imageIo(), { limits = Gltf.noTextureLimits(), pbr = true, occlusion = occlusion | Gltf.defaultLoadOptions() },
                                         None, bytes))

    /// occlusionTexture（strength 0.5）を書いた材質。inside は pbrMetallicRoughness の中身・image は occlusionTexture の textures の番号。
    def withOcclusion(inside: String, image: Int32): String =
        "{\"pbrMetallicRoughness\":{${inside}},\"occlusionTexture\":{\"index\":${image},\"strength\":0.5}}"

    /// baseColor = 画像 0・metallicRoughness と occlusion = 画像 1（ARM の絵）の材質。
    def arm(): String = withOcclusion(TestGltf.Metallic.base() + "," + TestGltf.Metallic.orm(), 1)

    def materialOf(m: Model3d.Model3d): Option[Scene3d.Material3d] = TestGltf.Metallic.firstPart(m)#material

    def readWithOptions(pbr: Bool, occlusion: Bool, bytes: Vector[Int8]): Model3d.Model3d \ IO =
        TestGltf.okOrBug(Gltf.decodeWith(TestDecoder.imageIo(), { limits = Gltf.noTextureLimits(), pbr = pbr, occlusion = occlusion | Gltf.defaultLoadOptions() },
                                         None, bytes))

    /// 標準エラーへ出た字（f が知らせた行）と f の値。
    def capturingErr(f: Unit -> a \ IO): (a, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let value = f();
        System.setErr(old);
        (value, buf.toString())

    def armModel(): Model3d.Model3d \ IO = readWith(true, TestGltf.Metallic.glbWith(arm(), true))

    def aoNameOf(m: Model3d.Model3d): Option[String] = materialOf(m) |> Option.flatMap(Scene3d.occlusionOf) |> Option.map(o -> o#texture)

    /// ARM の絵（occlusion と metallicRoughness が同じ画像）は絵を増やさない（画像 2 枚のまま）。
    @Test
    def testArmDecodesNoExtraImage(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, List.length(armModel()#textures))

    /// ARM の絵の AO の名前は metallicRoughness の絵と同じ。
    @Test
    def testArmOcclusionNamesMetallicRoughnessImage(): Unit \ {Assert, IO} =
        let m = armModel();
        Assert.assertEq(expected = materialOf(m) |> Option.flatMap(Scene3d.metallicRoughnessOf) |> Option.flatMap(mr -> mr#texture), aoNameOf(m))

    /// ARM の材質が読む絵は 2 組（baseColor と ARM）。
    @Test
    def testArmIsTwoTextureReads(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(2), materialOf(armModel()) |> Option.map(x -> List.length(Scene3d.materialTexReadsOf(Scene3d.materialFieldsOf(x)))))

    /// strength は材質の AO に付く。
    @Test
    def testStrengthIsRead(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(0.5), materialOf(armModel()) |> Option.flatMap(Scene3d.occlusionOf) |> Option.map(o -> o#strength))

    /// occlusion を選ばない読み方は AO を付けない。
    @Test
    def testOcclusionOffByDefault(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = None, aoNameOf(readWith(false, TestGltf.Metallic.glbWith(arm(), true))))

    /// metallic・roughness の付かない材質（baseColor だけ）には、occlusionTexture があっても AO を付けない。
    @Test
    def testNoMetallicRoughnessMeansNoOcclusion(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = None, aoNameOf(readWith(true, TestGltf.Metallic.glbWith(withOcclusion(TestGltf.Metallic.base(), 1), true))))

    /// metallic・roughness の付かない材質の occlusionTexture の絵は decode しない（baseColor の 1 枚だけ）。
    @Test
    def testNoMetallicRoughnessDecodesNoOcclusionImage(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1, List.length(readWith(true, TestGltf.Metallic.glbWith(withOcclusion(TestGltf.Metallic.base(), 1), true))#textures))

    /// occlusion を選んでも pbr が偽なら AO の絵を decode しない（baseColor の 1 枚だけ）。
    @Test
    def testOcclusionWithoutPbrDecodesNoOcclusionImage(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1, List.length(readWithOptions(false, true, TestGltf.Metallic.glbWith(withOcclusion(TestGltf.Metallic.base(), 1), true))#textures))

    /// GltfMaterial の occlusionTexture は読めた AO の絵の名前（ARM なら metallicRoughnessTexture と同じ）。
    @Test
    def testGltfMaterialCarriesOcclusionTexture(): Unit \ {Assert, IO} =
        let g = TestGltf.Metallic.firstPart(armModel())#gltfMaterial;
        Assert.assertEq(expected = g |> Option.flatMap(x -> x#metallicRoughnessTexture), g |> Option.flatMap(x -> x#occlusionTexture))

    /// GltfMaterial の occlusionStrength は occlusionTexture の strength。
    @Test
    def testGltfMaterialCarriesOcclusionStrength(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(0.5), TestGltf.Metallic.firstPart(armModel())#gltfMaterial |> Option.map(x -> x#occlusionStrength))

    /// TEXCOORD_0 の無い形には AO を付けない（uv で読む絵）。
    @Test
    def testNoUvMeansNoOcclusion(): Unit \ {Assert, IO} =
        let (m, _) = capturingErr(() -> readWith(true, TestGltf.Metallic.glbWith(arm(), false)));
        Assert.assertEq(expected = Some(false), materialOf(m) |> Option.map(x -> Scene3d.hasMaterialOcclusion(Scene3d.materialFieldsOf(x))))

    /// TEXCOORD_1 で読む occlusionTexture は付けない。
    @Test
    def testTexCoordOneOcclusionIsNotAttached(): Unit \ {Assert, IO} =
        let material = "{\"pbrMetallicRoughness\":{${TestGltf.Metallic.base()},${TestGltf.Metallic.orm()}},\"occlusionTexture\":{\"index\":1,\"texCoord\":1}}";
        let (m, _) = capturingErr(() -> readWith(true, TestGltf.Metallic.glbWith(material, true)));
        Assert.assertEq(expected = None, aoNameOf(m))

    /// TEXCOORD_1 で読む occlusionTexture は読み飛ばしたと知らせる。
    @Test
    def testTexCoordOneOcclusionIsReported(): Unit \ {Assert, IO} =
        let material = "{\"pbrMetallicRoughness\":{${TestGltf.Metallic.base()},${TestGltf.Metallic.orm()}},\"occlusionTexture\":{\"index\":1,\"texCoord\":1}}";
        let (_, err) = capturingErr(() -> readWith(true, TestGltf.Metallic.glbWith(material, true)));
        Assert.assertTrue(String.contains(substr = "texCoord が 0 でない絵を読み飛ばした", err))

    // ── Scene3d の口 ──

    def plain(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:base", ShaderDoc.FilterMode.Linear)

    def aoOnly(): Scene3d.Material3d = plain() |> Scene3d.withOcclusionTexture("tex3d:ao", 1.0)

    /// AO の絵だけの材質（metallicRoughness が無い）は AO を描かない。
    @Test
    def testOcclusionWithoutMetallicRoughnessIsNotDrawn(): Unit \ Assert =
        Assert.assertFalse(Scene3d.hasMaterialOcclusion(Scene3d.materialFieldsOf(aoOnly())))

    /// AO の絵の後に metallicRoughness を付けても AO を描く（呼ぶ順は問わない）。
    @Test
    def testMetallicRoughnessAfterOcclusionDraws(): Unit \ Assert =
        Assert.assertTrue(Scene3d.hasMaterialOcclusion(Scene3d.materialFieldsOf(aoOnly() |> Scene3d.withMetallicRoughness(0.0, 0.5))))

    def shadeOverridden(): Scene3d.MaterialFields =
        let shade = ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Const(0.0), g = ShaderDoc.Field.Const(0.5), b = ShaderDoc.Field.Const(0.0) });
        plain() |> Scene3d.withMetallicRoughness(0.0, 0.5) |> Scene3d.withOcclusionTexture("tex3d:ao", 1.0)
                |> Scene3d.withMetallicRoughnessShade(shade) |> Scene3d.materialFieldsOf

    /// metallic・roughness を色の場で書き替えると AO は描かない（b は書いた色の場のまま）。
    @Test
    def testShadeOverrideIsNotOccluded(): Unit \ Assert =
        Assert.assertFalse(Scene3d.hasMaterialOcclusion(shadeOverridden()))

    /// metallic・roughness を色の場で書き替えると strength の値も params から外れる。
    @Test
    def testShadeOverrideDropsStrengthParam(): Unit \ Assert =
        Assert.assertFalse(Map.memberOf(Scene3d.pbrParamOcclusion(), shadeOverridden()#params))

    /// strength は 0..1 に丸めて params に入る（値だけ違う材質は同じプログラム）。
    @Test
    def testStrengthIsClampedIntoParams(): Unit \ Assert =
        let f = plain() |> Scene3d.withMetallicRoughness(0.0, 0.5) |> Scene3d.withOcclusionTexture("tex3d:ao", 3.0) |> Scene3d.materialFieldsOf;
        Assert.assertEq(expected = Some(1.0), Map.get(Scene3d.pbrParamOcclusion(), f#params))
}

// project.json の "gltf" の occlusion を pbr なしで書いた時の知らせ（Model3d.loader の読み方）。
mod Model3d.TestOcclusionNotice {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    def errOf(options: Gltf.LoadOptions): String \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let kept = Model3d.withOcclusionNotice(options);
        System.setErr(old);
        if (kept#occlusion == options#occlusion) buf.toString() else "options が替わった"

    /// occlusion だけで pbr が偽なら、AO の絵を読まないと 1 行知らせる。
    @Test
    def testOcclusionWithoutPbrIsReported(): Unit \ {Assert, IO} =
        Assert.assertTrue(String.contains(substr = "occlusion は pbr が偽", errOf({ occlusion = true | Gltf.defaultLoadOptions() })))

    /// pbr と一緒なら知らせない。
    @Test
    def testOcclusionWithPbrIsQuiet(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "", errOf({ occlusion = true, pbr = true | Gltf.defaultLoadOptions() }))
}
