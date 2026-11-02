// 多角形マスク付きスプライトの型抜きを具体値で固定する。
//   mask の内側 = 絵の色 / mask の外（クアッドの内側でも）= 背景色
// mask は表示クアッドのローカル座標（design px・原点 = クアッド左上）。三角マスクで、
// GL のステンシル抜きと同じ「内側だけ塗る」画素集合になることの pin。
// フォントは描かないが RasterReq の配管上 TTF の実パスが要るため、リポジトリ内の
// 資産を相対参照する（テストの cwd = engine_tools/ 前提）。
mod TestSoftRasterMask {
    import java.awt.image.BufferedImage

    /// 出力の比較は (a, r, g, b) のタプルで行う（負の ARGB int を直接比べると読みにくい）。
    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    /// 8×8 の不透明な緑一色のテクスチャ（切り出し元の「絵」）。
    def greenImage(): BufferedImage \ IO = region rc {
        let img = new BufferedImage(8i32, 8i32, 2i32);
        // 0xFF00FF00（不透明の緑）の signed Int32 表現。16 進リテラルは Int32 の
        // 正の範囲を超えるので 10 進の負値で書く。
        let buf: Array[Int32, rc] = Array.repeat(rc, 64, -16711936);
        img.setRGB(0i32, 0i32, 8i32, 8i32, buf, 0i32, 8i32);
        img
    }

    /// 黒背景 8×8 に、左上直角三角形（(0,0)-(8,0)-(0,8)）で型抜きした緑スプライトを描き出す。
    def maskedRender(): BufferedImage \ IO =
        let mask = ({ x = 0.0, y = 0.0 } :: { x = 8.0, y = 0.0 } :: { x = 0.0, y = 8.0 } :: Nil)
            :: Nil;
        let d: GameEngine.Drawable = DrawCmd.make({
              texture = "paper", position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
              rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
              centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
              zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal,
              mask = mask });
        let req: SoftRaster.RasterReq =
            { drawables = d :: Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1,
              background = { r = 0.0, g = 0.0, b = 0.0 },
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true, scenes = Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map#{ "paper" => SoftRaster.PassImage.Rgba8Unorm(greenImage()) })

    // mask の内側（画素 (1,1)・三角形の奥）はテクスチャの緑がそのまま出る。
    @Test
    def testMaskedSpriteKeepsTextureInsideMask(): Unit \ {Assert, IO} =
        let img = maskedRender();
        Assert.assertEq(expected = (255, 0, 255, 0), channels(img.getRGB(1i32, 1i32)))

    // mask の外（画素 (6,6)。クアッドの内側だが三角形の外）は描かれず背景の黒のまま。
    @Test
    def testMaskedSpriteLeavesBackgroundOutsideMask(): Unit \ {Assert, IO} =
        let img = maskedRender();
        Assert.assertEq(expected = (255, 0, 0, 0), channels(img.getRGB(6i32, 6i32)))
}
