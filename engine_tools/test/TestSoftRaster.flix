// SoftRaster.blendPixel の合成式を具体値で固定する。
// GL 側（RenderSprite.applyBlend + シェーダの premultiply）と同じ式であることの pin:
//   Normal   = ふつうの半透明合成（SrcOver）
//   Add      = 明るく足す（255 でクランプ）
//   Multiply = 暗く沈める（白は素通し・黒は黒・alpha 0 で何も変えない）
mod TestSoftRaster {
    import java.awt.image.BufferedImage
    import java.io.File
    import javax.imageio.ImageIO

    /// ARGB int の組み立て（テスト入力用）。
    def argb(a: Int32, r: Int32, g: Int32, b: Int32): Int32 =
        Int32.leftShift(a, 24)
            |> Int32.bitwiseOr(Int32.leftShift(r, 16))
            |> Int32.bitwiseOr(Int32.leftShift(g, 8))
            |> Int32.bitwiseOr(b)

    /// 出力の比較は (a, r, g, b) のタプルで行う（負の ARGB int を直接比べると読みにくい）。
    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    // ── Add ──

    // 加算は dst + src×a/255。b は 240+25=265 → 255 にクランプされる。
    @Test
    def testAddSumsAndClamps(): Unit \ Assert =
        let out = SoftRaster.blendPixel(DrawCmd.BlendMode.Add,
            argb(128, 200, 100, 50), argb(255, 100, 200, 240));
        Assert.assertEq(expected = (255, 200, 250, 255), channels(out))

    // ── Multiply ──

    // 白は乗算の単位元 — 白い光を掛けても下の絵は変わらない。
    @Test
    def testMultiplyWhiteIsIdentity(): Unit \ Assert =
        let out = SoftRaster.blendPixel(DrawCmd.BlendMode.Multiply,
            argb(255, 255, 255, 255), argb(255, 12, 34, 56));
        Assert.assertEq(expected = (255, 12, 34, 56), channels(out))

    // 黒は全部を吸収する — 不透明な黒のオーバーレイは下の絵を真っ黒にする。
    @Test
    def testMultiplyBlackAbsorbs(): Unit \ Assert =
        let out = SoftRaster.blendPixel(DrawCmd.BlendMode.Multiply,
            argb(255, 0, 0, 0), argb(255, 200, 100, 50));
        Assert.assertEq(expected = (255, 0, 0, 0), channels(out))

    // alpha 0 は恒等 — 完全にフェードアウトしたオーバーレイは絵を明るくも暗くもしない
    // （glBlendFunc の因子切替だけで作ると a=0 で逆に明るくなる。この pin がその再発防止）。
    @Test
    def testMultiplyZeroAlphaIsIdentity(): Unit \ Assert =
        let out = SoftRaster.blendPixel(DrawCmd.BlendMode.Multiply,
            argb(0, 0, 0, 0), argb(255, 77, 88, 99));
        Assert.assertEq(expected = (255, 77, 88, 99), channels(out))

    // 半透明の黒（a=128）は半分だけ暗くする。
    @Test
    def testMultiplyHalfAlphaDims(): Unit \ Assert =
        let out = SoftRaster.blendPixel(DrawCmd.BlendMode.Multiply,
            argb(128, 0, 0, 0), argb(255, 200, 100, 50));
        Assert.assertEq(expected = (255, 99, 49, 24), channels(out))

    // ── Normal（SrcOver）──

    // 半透明の赤を緑の上に重ねると、赤と緑が半々に混ざる。
    @Test
    def testNormalIsSrcOver(): Unit \ Assert =
        let out = SoftRaster.blendPixel(DrawCmd.BlendMode.Normal,
            argb(128, 200, 0, 0), argb(255, 0, 200, 0));
        Assert.assertEq(expected = (255, 100, 99, 0), channels(out))

    // ── 描き出せない指定の報告（バックエンド同値の見張り） ──

    /// 最小の Drawable（属性は個々のテストで上書きする）。
    def drawable(texture: String, style: Option[GameEngine.BoxStyle]): GameEngine.Drawable =
        DrawCmd.make({
          texture = texture, position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
          rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = style, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    def someStyle(): Option[GameEngine.BoxStyle] =
        Some(DrawCmd.defaultStyle({ r = 1.0, g = 1.0, b = 1.0 }))

    /// 単色の box に付けた style は描ける（＝報告に出ない）。テクスチャと文字に付けた style は
    /// この経路では絵に出ないので、件数つきで報告される。
    @Test
    def testDroppedReportsStyleOnTexturedAndText(): Unit \ Assert =
        let ds = drawable("", someStyle()) ::
                 drawable("hero", someStyle()) ::
                 drawable("font_ui", someStyle()) ::
                 drawable("hero", None) :: Nil;
        let got = SoftRaster.dropped(ds) |> List.map(x -> (x#attr, x#count));
        Assert.assertEq(expected = ("style on textured sprite", 1) :: ("style on text", 1) :: Nil, got)

    /// 落とす物が無ければ報告は空（毎回の描き出しに無意味な行を出さない）。
    @Test
    def testDroppedIsEmptyWhenNothingLost(): Unit \ Assert =
        let ds = drawable("", someStyle()) :: drawable("hero", None) :: Nil;
        Assert.assertEq(expected = 0, List.length(SoftRaster.dropped(ds)))

    // ══════════════════════════════════════════════════════════════
    // 頂点色つき多角形（grad）の補間 — GL の頂点色補間と同じ線形の式であることの pin
    // ══════════════════════════════════════════════════════════════

    def black(): Color = { r = 0.0, g = 0.0, b = 0.0 }
    def white(): Color = { r = 1.0, g = 1.0, b = 1.0 }

    /// 上 2 頂点 top・下 2 頂点 bottom の縦グラデ四角（0,0)-(4,4)。
    def vgradQuad(top: Color, bottom: Color): GameEngine.PolygonRenderCmd =
        { vertices = { x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 }
                  :: { x = 4.0, y = 4.0 } :: { x = 0.0, y = 4.0 } :: Nil,
          color = top, alpha = 1.0, zIndex = 0, clip = None,
          blend = DrawCmd.BlendMode.Normal,
          grad = Some({ color = top, alpha = 1.0 } :: { color = top, alpha = 1.0 }
                   :: { color = bottom, alpha = 1.0 } :: { color = bottom, alpha = 1.0 } :: Nil) }

    //   (0,0)黒 ── (4,0)黒
    //     │  y=1.5 の点は上下の 0.375 地点 → 灰 0.375（=3/8。二進で正確）
    //   (0,4)白 ── (4,4)白
    @Test
    def testGradSampleInterpolatesVertically(): Unit \ Assert =
        let tris = DrawCmd.gradTriangles(vgradQuad(black(), white()));
        let got = SoftRaster.gradSample(tris, { x = 0.5, y = 1.5 })
            |> Option.map(t -> (t#color#r, t#color#g, t#color#b, t#alpha));
        Assert.assertEq(expected = Some((0.375, 0.375, 0.375, 1.0)), got)

    /// 色列が頂点より短いときは残りを color（ここでは青）で補い、濃さは頂点 α × 全体 α。
    /// 角の真上でサンプルすると重みが (1,0,0) になるので、期待値が丸め無しで決まる。
    @Test
    def testGradShortListFallsBackToBaseColorAndFoldsAlpha(): Unit \ Assert =
        let red: Color = { r = 1.0, g = 0.0, b = 0.0 };
        let blue: Color = { r = 0.0, g = 0.0, b = 1.0 };
        let tri: GameEngine.PolygonRenderCmd =
            { vertices = { x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 4.0 } :: Nil,
              color = blue, alpha = 0.5, zIndex = 0, clip = None,
              blend = DrawCmd.BlendMode.Normal,
              grad = Some({ color = red, alpha = 0.5 } :: Nil) };
        let tris = DrawCmd.gradTriangles(tri);
        let sampleAt = at -> SoftRaster.gradSample(tris, at)
            |> Option.map(t -> (t#color#r, t#color#b, t#alpha));
        // 頂点 0 = 渡した赤（α = 0.5×0.5）、頂点 1 = 補われた青（α = 1×0.5）。
        Assert.assertEq(
            expected = (Some((1.0, 0.0, 0.25)), Some((0.0, 1.0, 0.5))),
            (sampleAt({ x = 0.0, y = 0.0 }), sampleAt({ x = 4.0, y = 0.0 })))

    /// 縦グラデ四角を 4×4 の PNG 画素に描き出すと、各行の画素中心 (y+0.5)/4 の位置の
    /// 中間色が出る（0..255 へは argb の四捨五入。黒→白なら 32 / 96 / 159 / 223）。
    /// フォントは描かないが RasterReq の配管上 TTF の実パスが要るため、リポジトリ内の
    /// 資産を相対参照する（テストの cwd = engine_tools/ 前提）。
    @Test
    def testVgradRendersMiddleColors(): Unit \ {Assert, IO} =
        let img: BufferedImage = SoftRaster.renderToImage({
            drawables = Nil, polygons = vgradQuad(black(), white()) :: Nil,
            design = { x = 4.0, y = 4.0 }, scale = 1, background = black(),
            texturePath = Map.empty(),
            fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
            fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                          ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
            outPath = "", shapeAntialias = true, textAntialias = true });
        let grayAt = y -> { let (_, r, _, _) = channels(img.getRGB(1i32, y)); r };
        Assert.assertEq(expected = 32 :: 96 :: 159 :: 223 :: Nil,
            grayAt(0i32) :: grayAt(1i32) :: grayAt(2i32) :: grayAt(3i32) :: Nil)

    // ── テクスチャのキャッシュ（コマ列で 1 回だけ読む） ──

    /// 1 色で塗った 4×4 の PNG を書く（テクスチャのファイルの代わり）。
    def writeSolidPng(path: String, rgb: Int32): Unit \ IO =
        let img = new BufferedImage(4i32, 4i32, 2i32);
        List.range(0, 16) |> List.forEach(i -> img.setRGB(Int32.modulo(i, 4), i / 4, rgb));
        discard ImageIO.write(img, "png", new File(path))

    /// テクスチャ 1 枚を画面いっぱい（4×4）に貼った要求。
    def texturedReq(path: String): SoftRaster.RasterReq =
        let sprite = DrawCmd.make({
          texture = "t", position = { x = 0.0, y = 0.0 }, scale = { x = 4.0, y = 4.0 },
          rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil });
        { drawables = sprite :: Nil, polygons = Nil,
          design = { x = 4.0, y = 4.0 }, scale = 1, background = black(),
          texturePath = Map.singleton("t", path),
          fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
          fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                        ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
          outPath = "", shapeAntialias = true, textAntialias = true }

    def centerOf(img: BufferedImage): Int32 \ IO = img.getRGB(1i32, 1i32)

    /// キャッシュつきの描き出しは、キャッシュ無しと同じ画素を出す。同じキャッシュを使う間は
    /// ファイルを読み直さない（途中で書き換えても最初に読んだ絵のまま）。
    @Test
    def testTextureCacheReadsEachFileOnce(): Unit \ {Assert, IO} =
        let file: File = File.createTempFile("softraster-cache", ".png");
        file.deleteOnExit();
        let path: String = file.getPath();
        let red = argb(255, 255, 0, 0);
        let blue = argb(255, 0, 0, 255);
        writeSolidPng(path, red);
        let req = texturedReq(path);
        let cache = SoftRaster.freshTextureCache();
        let warnLog = SoftRaster.freshTexWarnLog();
        let plain = SoftRaster.renderToImage(req);
        let first = SoftRaster.renderToImageCached(req, Nil, Map.empty(), Map.empty(), warnLog, cache);
        writeSolidPng(path, blue);
        let second = SoftRaster.renderToImageCached(req, Nil, Map.empty(), Map.empty(), warnLog, cache);
        let fresh = SoftRaster.renderToImage(req);
        Assert.assertEq(expected = red :: red :: red :: blue :: Nil,
            centerOf(plain) :: centerOf(first) :: centerOf(second) :: centerOf(fresh) :: Nil)
}
