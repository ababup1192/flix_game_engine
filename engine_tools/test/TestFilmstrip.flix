// Filmstrip.render の単体テスト。平坦色のフレーム列を横連結スプライトシートに描き出し、
// 幅 = フレーム数 × frameW・PNG-8（インデックスカラー）で書けたことを固定する。
mod TestFilmstrip {
    import java.awt.image.BufferedImage
    import java.io.ByteArrayOutputStream
    import java.io.File
    import java.nio.file.Files
    import java.util.Arrays
    import javax.imageio.ImageIO

    /// 指定の RGB で一様に塗った w×h の BufferedImage（TYPE_INT_RGB）。
    /// Graphics2D（createGraphics）は macOS の -XstartOnFirstThread 下でブロックしうるので、
    /// setRGB で 1 画素ずつ塗って AWT の GraphicsEnvironment に触れない。
    def solid(w: Int32, h: Int32, r: Int32, g: Int32, b: Int32): BufferedImage \ IO =
        let img = new BufferedImage(w, h, 1i32);
        let rgb = Int32.bitwiseAnd(r, 255i32) * 65536i32
                  + Int32.bitwiseAnd(g, 255i32) * 256i32 + Int32.bitwiseAnd(b, 255i32);
        List.forEach(y ->
            List.forEach(x -> img.setRGB(x, y, rgb), List.range(0i32, w)),
            List.range(0i32, h));
        img

    /// PNG を読み戻した (幅, 高)。読めなければ (0, 0)。
    def readDims(path: String): (Int32, Int32) \ IO =
        let img = ImageIO.read(new File(path));
        if (Object.isNull(img)) (0i32, 0i32) else (img.getWidth(), img.getHeight())

    /// 一様色フレーム 3 枚（各 8×6）を描き出すと、幅 = 3×8 = 24・高 6・PNG-8（indexed=true・3 色）になり、
    /// 書き出した PNG も 24×6 で読み戻せる。
    @Test
    def testRenderIndexedSheet(): Unit \ IO + Assert =
        let frames =
            solid(8i32, 6i32, 200i32, 30i32, 40i32) ::
            solid(8i32, 6i32, 30i32, 200i32, 40i32) ::
            solid(8i32, 6i32, 40i32, 30i32, 200i32) :: Nil;
        let out = "build/test/filmstrip_indexed.png";
        let observed = match Filmstrip.render(frames, out) {
            case None    => (0i32, 0i32, 0i32, 0i32, 0i32, false, 0i32, (0i32, 0i32))
            case Some(r) => (r#frameCount, r#frameW, r#frameH, r#width, r#height, r#indexed, r#colors, readDims(out))
        };
        Assert.assertEq(expected = (3i32, 8i32, 6i32, 24i32, 6i32, true, 3i32, (24i32, 6i32)), observed)

    /// 空フレーム列は None（ファイルも作らない）。
    @Test
    def testRenderEmptyIsNone(): Unit \ IO + Assert =
        Assert.assertEq(expected = true, Option.isEmpty(Filmstrip.render(Nil, "build/test/filmstrip_empty.png")))

    /// コマ別 PNG: 3 枚を dir へ描き出すと 0.png .. 2.png ができ、各コマとも 8×6 で読み戻せる。
    @Test
    def testRenderFramesWritesEachFrame(): Unit \ IO + Assert =
        let frames =
            solid(8i32, 6i32, 200i32, 30i32, 40i32) ::
            solid(8i32, 6i32, 30i32, 200i32, 40i32) ::
            solid(8i32, 6i32, 40i32, 30i32, 200i32) :: Nil;
        let dir = "build/test/filmstrip_frames";
        let meta = Filmstrip.renderFrames(frames, dir)
            |> Option.map(r -> (r#frameCount, r#frameW, r#frameH));
        Assert.assertEq(
            expected = (Some((3i32, 8i32, 6i32)), (8i32, 6i32), (8i32, 6i32), (8i32, 6i32)),
            (meta, readDims("${dir}/0.png"), readDims("${dir}/1.png"), readDims("${dir}/2.png")))

    /// コマ別 PNG: 空フレーム列は None（ディレクトリもファイルも作らない）。
    @Test
    def testRenderFramesEmptyIsNone(): Unit \ IO + Assert =
        Assert.assertEq(expected = true, Option.isEmpty(Filmstrip.renderFrames(Nil, "build/test/filmstrip_frames_empty")))

    /// 256 色を超えるフレーム（各画素を違う色に塗った 20×20 = 400 色）は
    /// フルカラーへフォールバックする（indexed=false）。幅・コマ数は保つ。
    @Test
    def testRenderFallbackFullColor(): Unit \ IO + Assert =
        let img = new BufferedImage(20i32, 20i32, 1i32);
        List.forEach(y ->
            List.forEach(x ->
                img.setRGB(x, y, y * 20i32 + x),   // 0..399 の相異なる RGB
                List.range(0i32, 20i32)),
            List.range(0i32, 20i32));
        let observed = match Filmstrip.render(img :: Nil, "build/test/filmstrip_fallback.png") {
            case None    => (true, 0i32, 0i32)
            case Some(r) => (r#indexed, r#frameCount, r#width)
        };
        Assert.assertEq(expected = (false, 1i32, 20i32), observed)

    /// w×h の TYPE_INT_ARGB（塗りが返す型）。画素 (x, y) の ARGB は argbOf(x, y)。
    def argbImage(w: Int32, h: Int32, argbOf: (Int32, Int32) -> Int32): BufferedImage \ IO =
        let img = new BufferedImage(w, h, 2i32);
        List.forEach(y -> List.forEach(x -> img.setRGB(x, y, argbOf(x, y)), List.range(0i32, w)), List.range(0i32, h));
        img

    /// img の全画素の RGB（下位 24bit）を行順に並べた物。
    def rgbPixels(img: BufferedImage): List[Int32] \ IO =
        List.range(0i32, img.getHeight()) |> List.flatMap(y ->
            List.range(0i32, img.getWidth()) |> List.map(x -> Int32.bitwiseAnd(img.getRGB(x, y), 16777215i32)))

    /// 256 色を超える TYPE_INT_ARGB のコマ（半透明の画素を含む）を renderFrame で書くと、
    /// TYPE_INT_RGB へ写してから ImageIO で書いた PNG とバイト列が同じ。
    @Test
    def testRenderFrameFullColorBytesMatchRgbCopy(): Unit \ IO + Assert =
        let img = argbImage(24i32, 20i32, (x, y) ->
            if (x == 3i32 and y == 3i32) 1074860595i32      // 0x40112233（アルファ 0x40）
            else -16777216i32 + (y * 24i32 + x) * 4099i32);  // 不透明・480 色
        let out = "build/test/filmstrip_argb_full.png";
        Filmstrip.renderFrame(img, out);
        let copy = new BufferedImage(24i32, 20i32, 1i32);
        List.forEach(y -> List.forEach(x -> copy.setRGB(x, y, img.getRGB(x, y)), List.range(0i32, 24i32)), List.range(0i32, 20i32));
        let expected = new ByteArrayOutputStream();
        discard ImageIO.write(copy, "png", expected);
        Assert.assertEq(expected = true, Arrays.equals(expected.toByteArray(), Files.readAllBytes(new File(out).toPath())))

    /// ちょうど 256 色のコマはインデックスカラー（TYPE_BYTE_INDEXED = 13）で書かれ、読み戻した画素は元と同じ。
    @Test
    def testRenderFrame256ColorsIsIndexedAndLossless(): Unit \ IO + Assert =
        let img = argbImage(16i32, 16i32, (x, y) -> -16777216i32 + (y * 16i32 + x) * 65793i32 + x * 7i32);
        let out = "build/test/filmstrip_256.png";
        Filmstrip.renderFrame(img, out);
        let back = ImageIO.read(new File(out));
        Assert.assertEq(expected = (13i32, rgbPixels(img)), (back.getType(), rgbPixels(back)))

    /// 257 色のコマはフルカラーへ切り替わり、読み戻した画素は元と同じ。
    @Test
    def testRenderFrame257ColorsIsFullColorAndLossless(): Unit \ IO + Assert =
        let img = argbImage(257i32, 1i32, (x, _) -> -16777216i32 + x * 40961i32);
        let out = "build/test/filmstrip_257.png";
        Filmstrip.renderFrame(img, out);
        let back = ImageIO.read(new File(out));
        Assert.assertEq(expected = (false, rgbPixels(img)), (back.getType() == 13i32, rgbPixels(back)))
}
