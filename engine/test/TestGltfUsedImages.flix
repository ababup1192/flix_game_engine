// loadTextured は材質の baseColorTexture と normalTexture が指す画像だけを絵に戻す（metallicRoughness の画像は decode しない）。
mod TestGltf.UsedImages {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayOutputStream
    import javax.imageio.ImageIO

    /// 1 × 1 の PNG のバイト（argb の色。-65536 = 不透明の赤・-16711936 = 不透明の緑）。
    def onePixelPng(argb: Int32): List[Int8] \ IO = squarePng(1, argb)

    /// side × side の一色の PNG のバイト。
    def squarePng(side: Int32, argb: Int32): List[Int8] \ IO =
        let image = new BufferedImage(side, side, BufferedImage.TYPE_INT_ARGB);
        List.range(0, side * side) |> List.forEach(k -> image.setRGB(Int32.remainder(k, side), k / side, argb));
        let out = new ByteArrayOutputStream();
        discard ImageIO.write(image, "png", out);
        Array.toList(out.toByteArray())

    /// 三角 1 つ・uv つき・材質 1 つ（baseColorTexture = 画像 0・metallicRoughnessTexture = 画像 1）の .glb。
    def baseAndOrmGlb(): Vector[Int8] \ IO = baseAndOrmGlbOfSide(1)

    def baseAndOrmGlbOfSide(side: Int32): Vector[Int8] \ IO =
        let base = TestGltf.padded(0i8, squarePng(side, -65536));
        let orm = TestGltf.padded(0i8, onePixelPng(-16711936));
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
            Gltf.fromGlbTextured(baseAndOrmGlb()) |> Result.map(m -> m#textures |> List.map(Texture3d.argb)))

    @Test
    def testBaseColorLimitShrinksTheTexture(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((2, 2) :: Nil),
            Gltf.fromGlbTexturedWith({ baseColor = 2 | Gltf.noTextureLimits() }, baseAndOrmGlbOfSide(4))
                |> Result.map(m -> m#textures |> List.map(t -> (Texture3d.width(t), Texture3d.height(t)))))

    @Test
    def testNormalLimitDoesNotTouchTheBaseColor(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((4, 4) :: Nil),
            Gltf.fromGlbTexturedWith({ normal = 2 | Gltf.noTextureLimits() }, baseAndOrmGlbOfSide(4))
                |> Result.map(m -> m#textures |> List.map(t -> (Texture3d.width(t), Texture3d.height(t)))))
}
