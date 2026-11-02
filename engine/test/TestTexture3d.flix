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
}
