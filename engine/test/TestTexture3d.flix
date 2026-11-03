// TestTexture3d — 3D の材質が読む絵（寸法の検査・PNG の読み戻し・中身の鍵と名前）。
mod TestTexture3d {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayOutputStream
    import javax.imageio.ImageIO

    /// 左上が赤・右上が緑・左下が青・右下が白の 2 × 2（不透明）。
    def quad(): Vector[Int32] = Vector#{ -65536, -16711936, -16776961, -1 }

    def quadTexture(): Texture3d.Texture3d =
        match Texture3d.fromArgb(2, 2, quad()) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    /// argb の 2 × 2 を PNG のバイトにする。
    def pngOf(argb: Vector[Int32]): Vector[Int8] \ IO =
        let image = new BufferedImage(2, 2, BufferedImage.TYPE_INT_ARGB);
        Vector.forEachWithIndex((k, c) -> image.setRGB(Int32.remainder(k, 2), k / 2, c), argb);
        let out = new ByteArrayOutputStream();
        discard ImageIO.write(image, "png", out);
        Array.toVector(out.toByteArray())

    /// 画素の数が幅 × 高さでなければ Err。
    @Test
    def testFromArgbRejectsCountMismatch(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.fromArgb(2, 2, Vector#{ 0, 0, 0 })))

    /// 辺が 0 なら Err。
    @Test
    def testFromArgbRejectsZeroSide(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.fromArgb(0, 1, Vector.empty())))

    /// 辺が上限を超えれば Err。
    @Test
    def testFromArgbRejectsTooWide(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(Texture3d.fromArgb(Texture3d.maxSide() + 1, 1, Vector.repeat(Texture3d.maxSide() + 1, 0))))

    /// 2 × 2 の PNG を読むと、行 0 が絵の上の ARGB に戻る。
    @Test
    def testDecodeReadsPngRows(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok(quad()), Texture3d.decode(pngOf(quad())) |> Result.map(Texture3d.argb))

    /// PNG でも JPEG でもないバイトは Err。
    @Test
    def testDecodeRejectsGarbage(): Unit \ {Assert, IO} =
        Assert.assertTrue(Result.isErr(Texture3d.decode(Vector#{ 1i8, 2i8, 3i8 })))

    /// 同じ画素なら同じ鍵、1 画素違えば違う鍵。
    @Test
    def testContentHashFollowsPixels(): Unit \ Assert =
        let again = Texture3d.fromArgb(2, 2, quad()) |> Result.map(Texture3d.contentHash);
        let changed = Texture3d.fromArgb(2, 2, Vector.update(0, -1, quad())) |> Result.map(Texture3d.contentHash);
        Assert.assertEq(expected = (true, false),
            (again == Ok(Texture3d.contentHash(quadTexture())), changed == Ok(Texture3d.contentHash(quadTexture()))))

    /// 寸法が違えば、画素の並びが同じでも鍵が違う（2 × 2 と 4 × 1）。
    @Test
    def testContentHashIncludesSize(): Unit \ Assert =
        Assert.assertEq(expected = false,
            Texture3d.fromArgb(4, 1, quad()) |> Result.map(Texture3d.contentHash) == Ok(Texture3d.contentHash(quadTexture())))

    /// 名前は "tex3d:" と鍵の頭 16 字。
    @Test
    def testNameIsPrefixAndHashHead(): Unit \ Assert =
        let t = quadTexture();
        Assert.assertEq(expected = "tex3d:" + String.takeLeft(16, Texture3d.contentHash(t)), Texture3d.name(t))

    /// srgbToLinearColor は 3 成分をそれぞれ srgbToLinear へ通す（0.5 は約 0.214）。
    @Test
    def testSrgbToLinearColorConvertsEachChannel(): Unit \ Assert =
        let c = Texture3d.srgbToLinearColor(Color.rgb(0.5, 0.25, 1.5));
        Assert.assertEq(expected = (Texture3d.srgbToLinear(0.5), Texture3d.srgbToLinear(0.25), Texture3d.srgbToLinear(1.5)), (c#r, c#g, c#b))

    /// 段の平均の色空間: 材質の絵は Srgb。
    @Test
    def testMipSpaceOfMaterialTextureIsSrgb(): Unit \ Assert =
        Assert.assertEq(expected = Texture3d.ColorSpace.Srgb, Texture3d.mipSpaceOf(Texture3d.TextureUse.MaterialTexture))

    /// 段の平均の色空間: 法線マップは Linear。
    @Test
    def testMipSpaceOfNormalMapIsLinear(): Unit \ Assert =
        Assert.assertEq(expected = Texture3d.ColorSpace.Linear, Texture3d.mipSpaceOf(Texture3d.TextureUse.NormalMap))

    /// 段の平均の色空間: lightmap はその colorSpace のまま。
    @Test
    def testMipSpaceOfLightmapIsItsSpace(): Unit \ Assert =
        Assert.assertEq(expected = Texture3d.ColorSpace.Linear, Texture3d.mipSpaceOf(Texture3d.TextureUse.Lightmap(Texture3d.ColorSpace.Linear)))

    /// Srgb の絵は SrgbCurve で平均する。
    @Test
    def testMipAverageOfSrgbIsSrgbCurve(): Unit \ Assert =
        Assert.assertEq(expected = Mip.Average.SrgbCurve, Texture3d.mipAverageOf(Texture3d.ColorSpace.Srgb))

    /// 0〜1 を 1/20000 刻みで見た、表の版と式の差の最大（srgbToLinear と linearToSrgb の大きい方）。
    def maxLutError(): Float64 =
        let lut = Texture3d.colorLut();
        List.range(0, 20001) |> List.foldLeft((acc, k) -> {
            let x = Int32.toFloat64(k) / 20000.0;
            let a = Float64.abs(Texture3d.srgbToLinearLut(lut, x) - Texture3d.srgbToLinear(x));
            let b = Float64.abs(Texture3d.linearToSrgbLut(lut, x) - Texture3d.linearToSrgb(x));
            Float64.max(acc, Float64.max(a, b))
        }, 0.0)

    /// 表の版と式の差は 8bit の 1 段の 1/100（3.9e-5）未満。
    @Test
    def testColorLutStaysWithinHundredthOfAStep(): Unit \ Assert =
        Assert.assertTrue(maxLutError() < 3.9e-5)

    /// 0〜1 の外は式と同じ値（1 を超える値は伸ばし、負は linearToSrgb で 0）。
    @Test
    def testColorLutOutsideRangeIsFormula(): Unit \ Assert =
        let lut = Texture3d.colorLut();
        Assert.assertEq(expected = (Texture3d.srgbToLinear(1.5), Texture3d.linearToSrgb(2.0), Texture3d.linearToSrgb(-0.5)),
            (Texture3d.srgbToLinearLut(lut, 1.5), Texture3d.linearToSrgbLut(lut, 2.0), Texture3d.linearToSrgbLut(lut, -0.5)))
}
