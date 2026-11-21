// 全体の登録の絵の mip つきの写し（Render3d.WebGpuMipmaps）が、PC の Dawn で CPU の Mip.build と同じレベルを作る事を、レベルごとに読み戻して固定する。
// 機種の側の絵（ブラウザの ImageBitmap）を材質の絵の置き場へ上げる道も、写す口を Dawn の writeTexture に替えて同じく固定する。
// WhyNot: mod TestWebGpuMipmapsDawn にしない — Render3d.WebGpuMipmaps は pub でなく、子の mod からだけ見える。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（TestWebGpuScene3dDawn と同じ。`[mipmaps-dawn] SKIP:` の行を出す）。
mod Render3d.WebGpuMipmaps.TestWebGpuMipmapsDawn {
    import fge.webgpu.BufferUsage
    import fge.webgpu.CommandEncoder
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    /// w × h の絵。成分は位置の 2 乗と 3 乗から作るばらばらの値（1 次の式だと 4 つの和が 4 の倍数にそろい、(和 + 2) / 4 の丸めを確かめられない）。
    def source(w: Int32, h: Int32): ShaderEval.TexData =
        { width = w, height = h, pixels = Vector.range(0, w * h) |> Vector.map(i ->
            Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(byteOf(i * i * 53 + 17), 24), Int32.leftShift(byteOf(i * i * i * 7 + i * 3), 16)),
                            Int32.bitwiseOr(Int32.leftShift(byteOf(i * i * 29 + 200), 8), byteOf(i * i * 13 + i * 71 + 5)))) }

    def byteOf(x: Int32): Int32 = Int32.bitwiseAnd(x, 255)

    /// average の写しを Dawn で作ってレベルごとに読み戻した ARGB の列と、Mip.build のレベルの列の組（Dawn で開けなければ Err）。
    def bothChains(average: Mip.Average, tex: ShaderEval.TexData): Result[String, (List[Vector[Int32]], List[Vector[Int32]])] \ IO =
        WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) |> Result.map(gpu -> {
            let expected = Mip.build(average, tex) |> List.map(td -> td#pixels);
            let found = gpuChain(gpu, average, tex);
            gpu.destroy();
            (expected, found)
        })

    def gpuChain(gpu: WebGpu, average: Mip.Average, tex: ShaderEval.TexData): List[Vector[Int32]] \ IO =
        let src = gpu.createTexture("test mip source", tex#width, tex#height, TextureFormat.RGBA8_UNORM,
                                    Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        gpu.writeTexture(src, 0, 0, 0, tex#width, tex#height, rgbaBytes(tex#pixels), 0, tex#width * 4);
        let mm = Render3d.WebGpuMipmaps.create(gpu);
        let encoder = gpu.createCommandEncoder("test mip");
        let copy = Render3d.WebGpuMipmaps.copyOf(mm, { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()) }, "test mip copy", src, average);
        gpu.submit(encoder.finish());
        Render3d.WebGpuMipmaps.afterSubmit(mm);
        let levels = List.range(0, copy#levels) |> List.map(level -> readLevel(gpu, copy#texture, level));
        copy#texture.destroy();
        src.destroy();
        Render3d.WebGpuMipmaps.release(mm);
        levels

    def readLevel(gpu: WebGpu, texture: Texture, level: Int32): Vector[Int32] \ IO =
        let w = Int32.max(1, Int32.rightShift(texture.width(), level));
        let h = Int32.max(1, Int32.rightShift(texture.height(), level));
        let buffer = gpu.createBuffer("test mip read", Int32.toInt64(256 * h), Int32.bitwiseOr(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let encoder: CommandEncoder = gpu.createCommandEncoder("test mip read");
        encoder.copyTextureToBuffer(texture, level, 0, 0, w, h, buffer, 0i64, 256);
        gpu.submit(encoder.finish());
        let data = ByteBuffer.allocateDirect(256 * h);
        gpu.readBuffer(buffer, 0i64, 256 * h, data);
        buffer.destroy();
        Vector.range(0, w * h) |> Vector.map(i -> argbAt(data, 256 * (i / w) + 4 * (i - (i / w) * w)))

    def argbAt(data: ByteBuffer, at: Int32): Int32 \ IO =
        let byte = (k: Int32) -> Int32.bitwiseAnd(Int8.toInt32(data.get(at + k)), 255);
        Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(byte(3), 24), Int32.leftShift(byte(0), 16)), Int32.bitwiseOr(Int32.leftShift(byte(1), 8), byte(2)))

    def rgbaBytes(pixels: Vector[Int32]): ByteBuffer \ IO =
        let buf = ByteBuffer.allocateDirect(4 * Vector.length(pixels));
        let channel = (x: Int32, shift: Int32) -> Int32.truncateToInt8(Int32.bitwiseAnd(Int32.rightShift(x, shift), 255));
        Vector.forEachWithIndex((i, x) -> {
            discard buf.put(4 * i, channel(x, 16));
            discard buf.put(4 * i + 1, channel(x, 8));
            discard buf.put(4 * i + 2, channel(x, 0));
            discard buf.put(4 * i + 3, channel(x, 24))
        }, pixels);
        buf

    /// 写しと Mip.build の、どのレベルのどの画素のどの成分でも差が tolerance 以内（レベルの数か画素の数が違えば偽）。Dawn で開けなければ SKIP。
    def assertChainWithin(tolerance: Int32, average: Mip.Average, tex: ShaderEval.TexData): Unit \ {Assert, IO} =
        match bothChains(average, tex) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[mipmaps-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok((expected, found)) => Assert.assertTrue(isWithin(tolerance, expected, found))
        }

    def isWithin(tolerance: Int32, expected: List[Vector[Int32]], found: List[Vector[Int32]]): Bool =
        List.length(expected) == List.length(found) and
        List.forAll(match (e, f) -> Vector.length(e) == Vector.length(f) and Vector.forAll(match (a, b) -> largestChannelDiff(a, b) <= tolerance, Vector.zip(e, f)),
                    List.zip(expected, found))

    def largestChannelDiff(a: Int32, b: Int32): Int32 =
        List.foldLeft((acc, shift) -> Int32.max(acc, Int32.abs(byteOf(Int32.rightShift(a, shift)) - byteOf(Int32.rightShift(b, shift)))), 0, 0 :: 8 :: 16 :: 24 :: Nil)

    /// Raw の写しのレベルが、辺が奇数の横長の絵（縦の端を繰り返す）で Mip.build のレベルと画素まで同じ。
    @Test
    def testRawCopyMatchesMipBuildOnWideOddTexture(): Unit \ {Assert, IO} = assertChainWithin(0, Mip.Average.Raw, source(5, 3))

    /// Raw の写しのレベルが、縦長の絵（幅が 1 になった後も横の端を繰り返す）で Mip.build のレベルと画素まで同じ。
    @Test
    def testRawCopyMatchesMipBuildOnTallTexture(): Unit \ {Assert, IO} = assertChainWithin(0, Mip.Average.Raw, source(3, 8))

    /// 1 × 1 の絵の写しはレベル 0 の 1 つだけで、元の画素のまま。
    @Test
    def testOnePixelCopyIsLevelZeroOnly(): Unit \ {Assert, IO} = assertChainWithin(0, Mip.Average.Raw, source(1, 1))

    /// SrgbCurve の写しのレベルが、横長の絵で Mip.build のレベルと成分ごとに ±1 以内（しきい値の際の f32 の丸め）。
    @Test
    def testSrgbCopyMatchesMipBuildOnWideOddTexture(): Unit \ {Assert, IO} = assertChainWithin(1, Mip.Average.SrgbCurve, source(5, 3))

    /// SrgbCurve の写しのレベルが、縦長の絵で Mip.build のレベルと成分ごとに ±1 以内。
    @Test
    def testSrgbCopyMatchesMipBuildOnTallTexture(): Unit \ {Assert, IO} = assertChainWithin(1, Mip.Average.SrgbCurve, source(3, 8))

    // ── 機種の側の絵（Texture3d.Source.PlatformImage）を材質の絵の置き場へ上げる ──

    /// 機種の側の絵 key を tex の画素で表す場面の絵の置き場（材質の絵の使い方）。
    def platformSource(key: String, tex: ShaderEval.TexData): Render3d.TextureSource =
        match Texture3d.fromPlatformImage({ key = key, width = tex#width, height = tex#height }) {
            case Ok(t)  => { textureOf = _ -> checked_ecast(None), own = Map#{Texture3d.name(t) => t} }
            case Err(e) => bug!(e)
        }

    /// 写す口 copy を付けた材質の置き場へ、Dawn で機種の側の絵 key（画素 tex）を上げた答え。Some なら (レベルごとに読み戻した ARGB の列, 写す口へ渡った key の列)。
    def uploadPlatform(gpu: WebGpu, copy: Option[Render3d.WebGpuMaterials.PlatformImageCopy], key: String, tex: ShaderEval.TexData): Option[(List[Vector[Int32]], List[String])] \ IO =
        let materials = Render3d.WebGpuMaterials.create(gpu, Render3d.WebGpuMaterials.ValuesBinding.Uniform);
        let keys = Ref.fresh(Static, Nil);
        copy |> Option.forEach(c -> Render3d.WebGpuMaterials.setPlatformImageCopy((k, texture) -> { Ref.put(k :: Ref.get(keys), keys); c(k, texture) }, materials));
        let encoder = gpu.createCommandEncoder("test platform image");
        let registered = { textureById = _ -> checked_ecast(None), encoding = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()) }, noteCopy = () -> checked_ecast(()) };
        let source = platformSource(key, tex);
        let name = Map.keysOf(source#own) |> Set.toList |> List.head |> Option.getWithDefault("");
        let found = Render3d.WebGpuMaterials.ensureEnvironmentTexture(materials, source, registered, 1i64, name);
        gpu.submit(encoder.finish());
        Render3d.WebGpuMaterials.afterSubmit(materials);
        let answer = found |> Option.map(match (texture, levels) -> (List.range(0, levels) |> List.map(level -> readLevel(gpu, texture, level)), Ref.get(keys)));
        Render3d.WebGpuMaterials.release(materials);
        answer

    /// レベル 0 へ tex の画素を書く写す口（頁の copyExternalImageToTexture の代わり）。
    def writingCopy(gpu: WebGpu, tex: ShaderEval.TexData): Render3d.WebGpuMaterials.PlatformImageCopy = (_, texture) -> {
        gpu.writeTexture(texture, 0, 0, 0, tex#width, tex#height, rgbaBytes(tex#pixels), 0, tex#width * 4);
        true
    }

    /// Dawn の device で f を流す（開けなければ SKIP の行を出して通す）。
    def withDawn(f: WebGpu -> Unit \ {Assert, IO}): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[mipmaps-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                f(gpu);
                gpu.destroy()
        }

    /// 機種の側の絵のレベルが、材質の絵の平均の仕方（SrgbCurve）の Mip.build のレベルと成分ごとに ±1 以内（GPU で上の段を作る）。
    @Test
    def testPlatformImageLevelsMatchMipBuild(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let tex = source(5, 3);
        let found = uploadPlatform(gpu, Some(writingCopy(gpu, tex)), "rooms/hall.jpg@v1", tex) |> Option.map(fst);
        Assert.assertTrue(found |> Option.exists(levels -> isWithin(1, Mip.build(Mip.Average.SrgbCurve, tex) |> List.map(td -> td#pixels), levels)))
    })

    /// 写す口へ渡る key は、場面の絵の PlatformImage の key のまま。
    @Test
    def testPlatformImageCopyReceivesTheKey(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let tex = source(4, 2);
        Assert.assertEq(expected = Some("rooms/hall.jpg@v1" :: Nil), uploadPlatform(gpu, Some(writingCopy(gpu, tex)), "rooms/hall.jpg@v1", tex) |> Option.map(snd))
    })

    /// 写せない口（偽を返す）の機種の側の絵は上げない。
    @Test
    def testPlatformImageNotCopiedIsNotUploaded(): Unit \ {Assert, IO} = withDawn(gpu ->
        Assert.assertEq(expected = None, uploadPlatform(gpu, Some((_, _) -> checked_ecast(false)), "rooms/hall.jpg@v1", source(4, 2)) |> Option.map(snd)))

    /// 写す口を付けていない置き場（デスクトップ）は、機種の側の絵を上げない。
    @Test
    def testPlatformImageWithoutCopyIsNotUploaded(): Unit \ {Assert, IO} = withDawn(gpu ->
        Assert.assertEq(expected = None, uploadPlatform(gpu, None, "rooms/hall.jpg@v1", source(4, 2)) |> Option.map(snd)))
}
