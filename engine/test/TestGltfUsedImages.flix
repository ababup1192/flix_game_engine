// loadTextured は材質の baseColorTexture と normalTexture が指す画像だけを絵に戻す（metallicRoughness の画像は decode しない）。
mod TestGltf.UsedImages {

    /// 三角 1 つ・uv つき・材質 1 つ（baseColorTexture = 画像 0・metallicRoughnessTexture = 画像 1）の .glb。
    def baseAndOrmGlb(): Vector[Int8] \ IO = baseAndOrmGlbOfSide(1)

    def baseAndOrmGlbOfSide(side: Int32): Vector[Int8] \ IO =
        let base = TestGltf.padded(0i8, TestGltf.squarePng(side, -65536));
        let orm = TestGltf.padded(0i8, TestGltf.onePixelPng(-16711936));
        let geometry = TestGltf.f32s(-1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: Nil) ++
                       TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil) ++
                       TestGltf.f32s(0.0 :: 0.0 :: 1.0 :: 0.0 :: 0.0 :: 1.0 :: Nil);
        let baseAt = List.length(geometry);
        let ormAt = baseAt + List.length(base);
        let json = "{\"asset\":{\"version\":\"2.0\"},\"nodes\":[{\"mesh\":0}]," +
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"material\":0}]}]," +
            "\"materials\":[{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0},\"metallicRoughnessTexture\":{\"index\":1}}}]," +
            "\"textures\":[{\"source\":0},{\"source\":1}]," +
            "\"images\":[{\"bufferView\":3,\"mimeType\":\"image/png\"},{\"bufferView\":4,\"mimeType\":\"image/png\"}]," +
            "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":1,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
            "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC2\"}]," +
            "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36},{\"buffer\":0,\"byteOffset\":36,\"byteLength\":36}," +
            "{\"buffer\":0,\"byteOffset\":72,\"byteLength\":24}," +
            "{\"buffer\":0,\"byteOffset\":${baseAt},\"byteLength\":${List.length(base)}}," +
            "{\"buffer\":0,\"byteOffset\":${ormAt},\"byteLength\":${List.length(orm)}}]," +
            "\"buffers\":[{\"byteLength\":${ormAt + List.length(orm)}}]}";
        TestGltf.glb(json, geometry ++ base ++ orm)

    @Test
    def testOnlyTheBaseColorImageIsDecoded(): Unit \ {Assert, IO} =
        let red = -65536;
        Assert.assertEq(expected = Ok(Vector#{red} :: Nil),
            Gltf.fromGlbTexturedUsing(TestDecoder.imageIo(), Gltf.noTextureLimits(), baseAndOrmGlb()) |> Result.map(m -> m#textures |> List.map(TestDecoder.pixelsOf)))

    @Test
    def testBaseColorLimitShrinksTheTexture(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((2, 2) :: Nil),
            Gltf.fromGlbTexturedUsing(TestDecoder.imageIo(), { baseColor = 2 | Gltf.noTextureLimits() }, baseAndOrmGlbOfSide(4))
                |> Result.map(m -> m#textures |> List.map(t -> (Texture3d.width(t), Texture3d.height(t)))))

    @Test
    def testNormalLimitDoesNotTouchTheBaseColor(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((4, 4) :: Nil),
            Gltf.fromGlbTexturedUsing(TestDecoder.imageIo(), { normal = 2 | Gltf.noTextureLimits() }, baseAndOrmGlbOfSide(4))
                |> Result.map(m -> m#textures |> List.map(t -> (Texture3d.width(t), Texture3d.height(t)))))

    @Test
    def testUsingDecodesWithTheGivenDecoder(): Unit \ {Assert, IO} =
        let green = -16711936;
        let decoder = ImageData.decoderOf(_ -> checked_ecast(Ok({ width = 1, height = 1, argb = Vector#{green} })));
        Assert.assertEq(expected = Ok(Vector#{green} :: Nil),
            Gltf.fromGlbTexturedUsing(decoder, Gltf.noTextureLimits(), baseAndOrmGlb()) |> Result.map(m -> m#textures |> List.map(TestDecoder.pixelsOf)))
}
