// Render.drawWithLayouts の字の組みの cache: cache を渡しても渡さなくても、同じ描画命令の列になる。

mod TestTextLayoutCache {
    import java.lang.Object
    import java.util.HashMap

    /// 欄ごとに半端な値を持つアトラス（足す順が変わると値がずれるように）。
    def oddAtlas(): FontAtlas =
        let m = (i: Int32) -> {
            let f = Int32.toFloat64(i);
            ({ xOff = 0.37 * f - 1.1, yOff = -7.3 + 0.13 * f, glyphW = 5.7 + 0.21 * f, glyphH = 9.1 - 0.07 * f,
               advance = 6.3 + 0.11 * f, s0 = 0.017 * f, t0 = 0.031 * f, s1 = 0.017 * f + 0.0213, t1 = 0.031 * f + 0.0391 }: TextLayout.GlyphMetrics)
        };
        let glyphs = List.range(33, 127) |> List.foldLeft((acc, cp) -> Map.insert(cp, m(cp - 32), acc), Map.empty());
        // 空白（32）は幅 0 の字（w <= 0 で捨てる道を通す）。
        let space = { xOff = 0.0, yOff = 0.0, glyphW = 0.0, glyphH = 0.0, advance = 4.1, s0 = 0.0, t0 = 0.0, s1 = 0.0, t1 = 0.0 };
        ({ textureName = "font_odd", fontSize = 32.0, textureSize = 512.0, ascent = 25.3, descent = 6.7, lineGap = 1.9,
           glyphs = Map.insert(32, space, glyphs) }: FontAtlas)

    def textItem(content: String, size: Float64, alpha: Float64, rotation: Float64, wrap: Option[Float64]): Render.Item =
        Render.Item.Text({ text = content, fontAtlas = oddAtlas(), fontSize = size, tint = { r = 0.3, g = 0.6, b = 0.9 },
                           alpha = alpha, rotation = rotation, zIndex = 7, wrapWidth = wrap })

    def at(x: Float64, y: Float64, item: Render.Item): Render.PlacedItem = { at = { x = x, y = y }, item = item }

    /// 不透明・薄い・回した・折り返し・複数行・空白・空・切り抜いた字と、箱を混ぜた列。
    def items(): List[Render.PlacedItem] =
        let box = RawDraw.box({ x = 10.0, y = 4.0 }, { r = 1.0, g = 0.0, b = 0.0 }, 3);
        let rect = { position = { x = 0.0, y = 0.0 }, size = { x = 50.0, y = 50.0 } };
        at(0.0, 0.0, box) ::
        at(123.456, 78.9012, textItem("Unit 17", 13.0, 1.0, 0.0, None)) ::
        at(0.0, 0.0, box) ::
        at(-33.3, 1e5 + 0.1, textItem("a b\ncdef ghij", 17.5, 1.0, 0.0, None)) ::
        at(5.5, 6.25, textItem("Wrap me around please ok", 32.0, 1.0, 0.0, Some(71.3))) ::
        at(1.0, 2.0, textItem("DMG 98231", 13.0, 0.5, 0.0, None)) ::
        at(1.0, 2.0, textItem("DMG 98231", 13.0, 1.0, 0.1, None)) ::
        at(9.0, 9.0, textItem("", 13.0, 1.0, 0.0, None)) ::
        at(3.0, 4.0, Render.clipped(rect, textItem("Unit 17", 13.0, 1.0, 0.0, None))) ::
        // 同じ文で大きさだけ違う字（cache の鍵は文なので、組み直しの道を通す）。
        at(2.0, 2.0, textItem("Unit 17", 21.0, 1.0, 0.0, None)) :: Nil

    def drawn(layouts: Option[HashMap[String, Object]]): List[DrawCmd.Drawable] =
        fst(Render.drawWithLayouts(layouts, _ -> None, items()))

    /// cache が空の時（組んで入れる）の列は、cache を渡さない列と同じ。
    @Test
    def testEmptyCacheSameDrawables(): Unit \ {Assert, IO} =
        let m: HashMap[String, Object] = new HashMap();
        Assert.assertEq(expected = drawn(None), drawn(Some(m)))

    /// 同じ cache で 2 回描くと、1 回目（組んで入れる）も 2 回目（当たる）も、cache を渡さない列と同じ。
    @Test
    def testWarmCacheSameDrawables(): Unit \ {Assert, IO} =
        let m: HashMap[String, Object] = new HashMap();
        let cold = drawn(Some(m));
        let base = drawn(None);
        Assert.assertEq(expected = (base, base), (cold, drawn(Some(m))))
}
