// Tests for Text module

mod TestText {

    def approx(a: Float64, b: Float64): Bool =
        Float64.abs(a - b) < 0.001

    /// 等幅 advance=10、ascent=8、descent=2、lineGap=0、fontSize=16。
    /// 'A','B','C' のみ登録、scale=1.0 (fontSize=16 / atlas#fontSize=16) のサンプルアトラス。
    def sampleAtlas(): FontAtlas =
        let metrics: TextLayout.GlyphMetrics = {
            xOff = 0.0, yOff = 0.0, glyphW = 10.0, glyphH = 10.0,
            advance = 10.0, s0 = 0.0, t0 = 0.0, s1 = 1.0, t1 = 1.0
        };
        let glyphs = Map.empty()
            |> Map.insert(65, metrics)   // 'A'
            |> Map.insert(66, metrics)   // 'B'
            |> Map.insert(67, metrics);  // 'C'
        ({
            textureName = "atlas",
            fontSize    = 16.0,
            textureSize = 256.0,
            ascent      = 8.0,
            descent     = 2.0,
            lineGap     = 0.0,
            glyphs      = glyphs
        }: FontAtlas)

    // ========================================================================
    // measure — 1 行
    // ========================================================================

    /// 単一行 "ABC" は advance(10) * 3 = 30、高さは lineHeight = ascent+descent+lineGap = 10
    @Test
    def testMeasureSingleLine(): Unit \ Assert =
        let label = Text.make("ABC", sampleAtlas(), 16.0);
        let sz = Text.measure(label);
        Assert.assertTrue(approx(sz#x, 30.0));
        Assert.assertTrue(approx(sz#y, 10.0))

    /// 空文字列でも高さ 1 行分は確保される
    @Test
    def testMeasureEmptyString(): Unit \ Assert =
        let label = Text.make("", sampleAtlas(), 16.0);
        let sz = Text.measure(label);
        Assert.assertTrue(approx(sz#x, 0.0));
        Assert.assertTrue(approx(sz#y, 10.0))

    // ========================================================================
    // measure — 複数行
    // ========================================================================

    /// 2 行 "AB\nC" は max(2,1)*10=20、高さは 2*10=20
    @Test
    def testMeasureTwoLines(): Unit \ Assert =
        let label = Text.make("AB\nC", sampleAtlas(), 16.0);
        let sz = Text.measure(label);
        Assert.assertTrue(approx(sz#x, 20.0));
        Assert.assertTrue(approx(sz#y, 20.0))

    /// 3 行 "A\nBC\nA" は max=20、高さは 3*10=30
    @Test
    def testMeasureThreeLines(): Unit \ Assert =
        let label = Text.make("A\nBC\nA", sampleAtlas(), 16.0);
        let sz = Text.measure(label);
        Assert.assertTrue(approx(sz#x, 20.0));
        Assert.assertTrue(approx(sz#y, 30.0))

    // ========================================================================
    // measure — fontSize スケーリング
    // ========================================================================

    /// fontSize = atlas#fontSize の 2 倍 (32.0) なら、scale = 2.0 で全体が倍
    @Test
    def testMeasureScaledFontSize(): Unit \ Assert =
        let label = Text.make("AB", sampleAtlas(), 32.0);
        let sz = Text.measure(label);
        // advance(10)*2 chars * scale(2) = 40、高さ 10 * 2 = 20
        Assert.assertTrue(approx(sz#x, 40.0));
        Assert.assertTrue(approx(sz#y, 20.0))

    /// 半分の fontSize なら半分のサイズ
    @Test
    def testMeasureHalfFontSize(): Unit \ Assert =
        let label = Text.make("ABC", sampleAtlas(), 8.0);
        let sz = Text.measure(label);
        // advance(10)*3 chars * scale(0.5) = 15、高さ 10 * 0.5 = 5
        Assert.assertTrue(approx(sz#x, 15.0));
        Assert.assertTrue(approx(sz#y, 5.0))

    // ========================================================================
    // measure — 未登録グリフ
    // ========================================================================

    /// アトラスに無い文字は advance 0 として扱う
    @Test
    def testMeasureUnknownGlyph(): Unit \ Assert =
        let label = Text.make("AXC", sampleAtlas(), 16.0);
        let sz = Text.measure(label);
        // 'A'(10) + 'X'(0) + 'C'(10) = 20
        Assert.assertTrue(approx(sz#x, 20.0));
        Assert.assertTrue(approx(sz#y, 10.0))

    // ========================================================================
    // 折り返し（wrapWidth）— measure
    // ========================================================================

    /// 幅 30 で折ると "ABCAB"(1 文字 10px) は "ABC" / "AB" の 2 行になる。
    /// 幅 = 一番広い行の 30、高さ = 2 行 × 10
    @Test
    def testMeasureWrapFoldsIntoTwoRows(): Unit \ Assert =
        let label = Text.make("ABCAB", sampleAtlas(), 16.0) |> Text.setWrapWidth(Some(30.0));
        let sz = Text.measure(label);
        Assert.assertEq(expected = (30.0, 20.0), (sz#x, sz#y))

    /// 折り返し幅が文字列より広ければ、折り返し無しと同じ寸法（"ABC" = 30 × 10）
    @Test
    def testMeasureWrapWiderThanTextIsNoop(): Unit \ Assert =
        let label = Text.make("ABC", sampleAtlas(), 16.0) |> Text.setWrapWidth(Some(100.0));
        let sz = Text.measure(label);
        Assert.assertEq(expected = (30.0, 10.0), (sz#x, sz#y))

    /// 改行と折り返しの併用: "ABCA\nB" を幅 30 で折ると "ABC" / "A" / "B" の 3 行
    @Test
    def testMeasureWrapAndNewlineCombine(): Unit \ Assert =
        let label = Text.make("ABCA\nB", sampleAtlas(), 16.0) |> Text.setWrapWidth(Some(30.0));
        let sz = Text.measure(label);
        Assert.assertEq(expected = (30.0, 30.0), (sz#x, sz#y))

    // ========================================================================
    // 折り返し（wrapWidth）— toDrawables
    // ========================================================================

    /// 幅 30 で折った "ABCA" の 4 文字目は 2 行目の先頭に置かれる。
    /// x = 0（行頭）、y = lineHeight(10) + ascent(8) = 18
    @Test
    def testToDrawablesWrapSecondRowPosition(): Unit \ Assert =
        let label = Text.make("ABCA", sampleAtlas(), 16.0) |> Text.setWrapWidth(Some(30.0));
        let ds = Text.toDrawables(label, {x = 0.0, y = 0.0});
        let fourth = List.drop(3, ds) |> List.head;
        match fourth {
            case Some(d) => Assert.assertEq(expected = (0.0, 18.0), (DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y))
            case None    => bug!("4 文字目の Drawable が無い")
        }

    /// wrapWidth = None は折り返さない: "ABCA" は 1 行のまま、4 文字目は x=30・y=8（ascent）
    @Test
    def testToDrawablesNoWrapKeepsSingleRow(): Unit \ Assert =
        let label = Text.make("ABCA", sampleAtlas(), 16.0);
        let ds = Text.toDrawables(label, {x = 0.0, y = 0.0});
        let fourth = List.drop(3, ds) |> List.head;
        match fourth {
            case Some(d) => Assert.assertEq(expected = (30.0, 8.0), (DrawCmd.positionOf(d)#x, DrawCmd.positionOf(d)#y))
            case None    => bug!("4 文字目の Drawable が無い")
        }

    def oddAtlas(): FontAtlas =
        let m = (i: Int32) -> {
            let f = Int32.toFloat64(i);
            ({ xOff = 0.37 * f - 1.1, yOff = -7.3 + 0.13 * f, glyphW = 5.7 + 0.21 * f, glyphH = 9.1 - 0.07 * f,
               advance = 6.3 + 0.11 * f, s0 = 0.017 * f, t0 = 0.031 * f, s1 = 0.017 * f + 0.0213, t1 = 0.031 * f + 0.0391 }: TextLayout.GlyphMetrics)
        };
        let glyphs = List.range(32, 127) |> List.foldLeft((acc, cp) -> Map.insert(cp, m(cp - 32), acc), Map.empty());
        ({ textureName = "odd", fontSize = 32.0, textureSize = 512.0, ascent = 25.3, descent = 6.7, lineGap = 1.9, glyphs = glyphs }: FontAtlas)

    /// 控えを通した字の組みと、控えを通さない字の組みが、どの入力でも同じ描画命令になる
    @Test
    def testLayoutCacheSameDrawables(): Unit \ Assert =
        let texts = "Unit 17" :: "DMG 98231" :: "a b\ncdef ghij" :: "" :: "  lead" :: "Wrap me around please ok" :: Nil;
        let sizes = 13.0 :: 17.5 :: 32.0 :: Nil;
        let wraps = None :: Some(40.0) :: Some(71.3) :: Nil;
        let hs = HorizontalAlignment.Left :: HorizontalAlignment.Center :: HorizontalAlignment.Right :: Nil;
        let vs = VerticalAlignment.Top :: VerticalAlignment.Center :: VerticalAlignment.Bottom :: Nil;
        let poss = ({x = 0.0, y = 0.0}: Vec2.Vec2) :: {x = 123.456, y = 78.9012} :: {x = -33.3, y = 1e5 + 0.1} :: Nil;
        let labels = List.flatMap(t -> List.flatMap(s -> List.flatMap(w -> List.flatMap(h -> List.map(v ->
            Text.make(t, oddAtlas(), s) |> Text.setWrapWidth(w) |> Text.setHorizontalAlignment(h) |> Text.setVerticalAlignment(v),
            vs), hs), wraps), sizes), texts);
        let bad = List.flatMap(l -> List.filter(p -> Text.layoutToDrawables(l, Text.buildLayout(l), p) != Text.toDrawablesUncached(l, p)
                                                  or Text.layoutToDrawablesV1(l, Text.buildLayout(l), p) != Text.toDrawablesUncached(l, p), poss), labels);
        Assert.assertEq(expected = 0, List.length(bad))

    def layoutIntoList(label: Text, pos: Vec2.Vec2): List[GameEngine.Drawable] =
        let Text.Text(r) = label;
        let atlas = r#fontAtlas;
        region rc {
            let ds = MutList.empty(rc);
            Text.layoutInto(ds, Text.buildLayout(label), atlas#textureName, atlas#textureSize, r#visual#color, r#visual#zIndex, pos#x, pos#y);
            MutList.toList(ds)
        }

    /// 平らな列（packed）から積んだ左上ぞろえの字は、cache を通さない字の組みと同じ描画命令になる
    @Test
    def testLayoutIntoSameDrawables(): Unit \ Assert =
        let texts = "Unit 17" :: "DMG 98231" :: "a b\ncdef ghij" :: "" :: "  lead" :: "Wrap me around please ok" :: Nil;
        let sizes = 13.0 :: 17.5 :: 32.0 :: Nil;
        let wraps = None :: Some(40.0) :: Some(71.3) :: Nil;
        let poss = ({x = 0.0, y = 0.0}: Vec2.Vec2) :: {x = 123.456, y = 78.9012} :: {x = -33.3, y = 1e5 + 0.1} :: Nil;
        let labels = List.flatMap(t -> List.flatMap(s -> List.map(w ->
            Text.make(t, oddAtlas(), s) |> Text.setWrapWidth(w), wraps), sizes), texts);
        let bad = List.flatMap(l -> List.filter(p -> layoutIntoList(l, p) != Text.toDrawablesUncached(l, p), poss), labels);
        Assert.assertEq(expected = 0, List.length(bad))

}
