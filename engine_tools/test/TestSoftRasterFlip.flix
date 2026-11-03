// 反転（flipH = scale の符号）の置き場所を実画素で固定する。
//   覆う矩形は position から右へ伸びる（反転してもそこは動かない）
//   絵の中身だけが左右入れ替わる
// これが崩れると、左を向いた瞬間だけキャラが幅ぶん横へ飛ぶ（見下ろしの 4 方向で
// 「左に進むと 1 マス飛ぶ」に見える）。GL 側の同じ規約は render_gl の RenderFrame.originAxis。
mod TestSoftRasterFlip {
    import java.awt.image.BufferedImage

    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    /// 4×4 のテクスチャ。左半分が赤・右半分が青（左右の見分けが付く絵）。
    def halvesImage(): BufferedImage \ IO = region rc {
        let img = new BufferedImage(4i32, 4i32, 2i32);
        let red = -65536;    // 0xFFFF0000
        let blue = -16776961; // 0xFF0000FF
        let buf: Array[Int32, rc] = Array.repeat(rc, 16, red);
        List.forEach(row -> List.forEach(col ->
            Array.put(blue, row * 4 + col, buf), 2 :: 3 :: Nil), List.range(0, 4));
        img.setRGB(0i32, 0i32, 4i32, 4i32, buf, 0i32, 4i32);
        img
    }

    /// 8×8 の黒い紙の (2,2) にテクスチャを等倍で置く。flip なら scale#x を負にする。
    def render(flip: Bool): BufferedImage \ IO =
        let d: GameEngine.Drawable = DrawCmd.make({
              texture = "paper", position = { x = 2.0, y = 2.0 },
              scale = { x = if (flip) -1.0 else 1.0, y = 1.0 },
              rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
              centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
              zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal,
              mask = Nil });
        let req: SoftRaster.RasterReq =
            { drawables = d :: Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1,
              background = { r = 0.0, g = 0.0, b = 0.0 },
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true, scenes = Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map#{ "paper" => SoftRaster.PassImage.Rgba8Unorm(halvesImage()) })

    /// 反転しても紙の (1,3)（絵の左隣）と (6,3)（絵の右隣）は背景の黒のまま。
    /// 絵が横へ飛ぶと、どちらかに色が乗る。
    @Test
    def testFlipKeepsTheDrawnBox(): Unit \ {Assert, IO} =
        let img = render(true);
        let black = (255, 0, 0, 0);
        Assert.assertEq(expected = (black, black),
            (channels(img.getRGB(1i32, 3i32)), channels(img.getRGB(6i32, 3i32))))

    /// 枠の中で左右が入れ替わる: 左端の画素が赤→青、右端が青→赤。
    @Test
    def testFlipMirrorsTheContents(): Unit \ {Assert, IO} =
        let leftRight = img -> (channels(img.getRGB(2i32, 3i32)), channels(img.getRGB(5i32, 3i32)));
        let red = (255, 255, 0, 0);
        let blue = (255, 0, 0, 255);
        Assert.assertEq(expected = ((red, blue), (blue, red)),
            (leftRight(render(false)), leftRight(render(true))))
}
