// .hdr（Radiance の RGBE）の読み・half の絵・half の段の約束。
mod TestTexture3dHdr {

    def bytesOf(header: String, body: List[Int32]): Vector[Int8] =
        let head = String.toList(header) |> List.map(c -> Int32.truncateToInt8(Char.toBmpCodePoint(c)));
        List.append(head, body |> List.map(Int32.truncateToInt8)) |> List.toVector

    /// 0..255 の数（Int8 へは下の 8 bit を切り出す）。
    def raw(values: List[Int32]): List[Int32] = values

    def flatHdr(): Vector[Int8] =
        bytesOf("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 2\n",
                raw(128 :: 64 :: 32 :: 129 :: 0 :: 0 :: 0 :: 0 :: 128 :: 128 :: 128 :: 130 :: 255 :: 0 :: 0 :: 128 :: Nil))

    /// 幅 8 の新しい RLE の 1 行（r は 128 の並び・g は 1..8 をそのまま・b は 0 の並び・e は 130 の並び）。
    def rleHdr(): Vector[Int8] =
        bytesOf("#?RGBE\n\n-Y 1 +X 8\n",
                raw(2 :: 2 :: 0 :: 8 :: 136 :: 128 :: 8 :: 1 :: 2 :: 3 :: 4 :: 5 :: 6 :: 7 :: 8 :: 136 :: 0 :: 136 :: 130 :: Nil))

    def halvesOf(t: Texture3d.Texture3d): Vector[Float64] = match Texture3d.sourceOf(t) {
        case Texture3d.Source.Rgba16Float(bits) => Vector.map(Texture3d.Internal.fromHalfBits, bits)
        case _                                  => Vector.empty()
    }

    def decoded(bytes: Vector[Int8]): Vector[Float64] = match Texture3d.decodeHdr(bytes) {
        case Ok(t)  => halvesOf(t)
        case Err(e) => bug!(e)
    }

    /// 平らな行: RGBE (128, 64, 32, 129) は (1, 0.5, 0.25)・α は 1。
    @Test
    def testFlatRowDecodesFirstPixel(): Unit \ Assert =
        Assert.assertEq(expected = Vector#{1.0, 0.5, 0.25, 1.0}, Vector.take(4, decoded(flatHdr())))

    /// e = 0 の画素は 0。
    @Test
    def testZeroExponentIsBlack(): Unit \ Assert =
        Assert.assertEq(expected = Vector#{0.0, 0.0, 0.0, 1.0}, Vector.slice(start = 4, end = 8, decoded(flatHdr())))

    /// 1 を超える明るさのまま持つ（e = 130 で 2）。
    @Test
    def testBrightPixelKeepsAboveOne(): Unit \ Assert =
        Assert.assertEq(expected = Vector#{2.0, 2.0, 2.0, 1.0}, Vector.slice(start = 8, end = 12, decoded(flatHdr())))

    /// 新しい RLE の行: 並びの数（run）とそのままの数（g）を読む。e = 130 で 2^−6。
    @Test
    def testRleRowDecodesRunsAndLiterals(): Unit \ Assert =
        let px = decoded(rleHdr());
        Assert.assertEq(expected = (2.0, 3.0 / 64.0, 0.0), (Vector.get(8, px), Vector.get(9, px), Vector.get(10, px)))

    /// 頭が #?RADIANCE でない物は Err。
    @Test
    def testBrokenHeaderIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.decodeHdr(bytesOf("P6\n\n-Y 1 +X 1\n", raw(1 :: 1 :: 1 :: 128 :: Nil)))))

    /// +Y（上下が逆）の向きは Err。
    @Test
    def testFlippedOrientationIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.decodeHdr(bytesOf("#?RADIANCE\n\n+Y 1 +X 1\n", raw(1 :: 1 :: 1 :: 128 :: Nil)))))

    /// バイトが足りない行は Err。
    @Test
    def testShortBodyIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.decodeHdr(bytesOf("#?RADIANCE\n\n-Y 2 +X 2\n", raw(1 :: 1 :: 1 :: 128 :: Nil)))))

    /// .hdr の絵の形式は Rgba16Float。
    @Test
    def testDecodedFormatIsRgba16Float(): Unit \ Assert =
        Assert.assertEq(expected = Some(Texture3d.Format.Rgba16Float), Texture3d.decodeHdr(flatHdr()) |> Result.toOption |> Option.map(Texture3d.formatOf))

    /// fromRgba16Float の数が合わなければ Err。
    @Test
    def testFromRgba16FloatChecksCount(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.fromRgba16Float(2, 2, Vector.repeat(15, 1.0))))

    /// half の段: 2 × 2 の 1 段上は 4 つの平均（1・3・5・7 → 4）。
    @Test
    def testHalfMipAverages(): Unit \ Assert =
        let bits = Vector#{1.0, 3.0, 5.0, 7.0} |> Vector.flatMap(v -> Vector#{v, v, v, 1.0}) |> Vector.map(Texture3d.Internal.toHalfBits);
        let top = Mip.buildRgba16Float(2, 2, bits) |> List.drop(1) |> List.head |> Option.map(level -> { let (_, _, b) = level; Texture3d.Internal.fromHalfBits(Vector.get(0, b)) });
        Assert.assertEq(expected = Some(4.0), top)

    /// half の景色の拡散の光は明るさのまま（一様な 2 の景色で 2）。
    @Test
    def testHalfSkyIrradianceKeepsBrightness(): Unit \ Assert =
        let t = Texture3d.fromRgba16Float(64, 32, Vector.repeat(64 * 32, ()) |> Vector.flatMap(_ -> Vector#{2.0, 2.0, 2.0, 1.0}));
        let red = t |> Result.toOption |> Option.flatMap(SphericalHarmonics.fromEquirectangular)
                    |> Option.map(sh -> { let (r, _, _) = SphericalHarmonics.irradianceAt(sh, Vec3.v3(0.0, 1.0, 0.0)); r });
        Assert.assertTrue(red |> Option.exists(r -> Float64.abs(r - 2.0) < 2.0e-3))

    /// half の環境マップは線形の量として読む（colorSpace が Linear）。
    @Test
    def testHalfEnvironmentIsLinear(): Unit \ Assert =
        let space = Texture3d.decodeHdr(flatHdr()) |> Result.toOption |> Option.map(t -> Scene3d.environmentMapFieldsOf(Scene3d.environmentMap(t))#colorSpace);
        Assert.assertEq(expected = Some(Texture3d.ColorSpace.Linear), space)
}
