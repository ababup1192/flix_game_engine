// TestRichText — スパン列の素の文章・長さ・先頭切り出し（文字送り連携）を具体値で固定する。
// place（描画）は手組みの atlas を使って、返る順序・1 字ずつの位置・色を具体値で固定する。
mod TestRichText {

    def spans(): List[RichText.Span] =
        RichText.colored("あお", {r = 0.0, g = 0.0, b = 1.0})
            :: RichText.plain("は")
            :: RichText.strong("嘘つき")
            :: RichText.plain("だよ") :: Nil

    @Test
    def testPlainTextAndLength(): Unit \ Assert =
        // 見た目を除いた素の文章と合計文字数。
        Assert.assertEq(expected = ("あおは嘘つきだよ", 8),
            (RichText.plainText(spans()), RichText.length(spans())))

    @Test
    def testTakeCutsAcrossSpanBoundaries(): Unit \ Assert =
        // 先頭 4 文字 = 「あおは嘘」。3 スパン目（太字）の途中で切れ、太字属性は保たれる。
        let cut = RichText.take(4, spans());
        let bolds = cut |> List.map(span -> span#bold);
        Assert.assertEq(expected = ("あおは嘘", false :: false :: true :: Nil, 3),
            (RichText.plainText(cut), bolds, List.length(cut)))

    @Test
    def testTakeZeroAndOverrun(): Unit \ Assert =
        // 0 文字なら空、全長以上なら全部（それ以上は増えない）。
        Assert.assertEq(expected = ("", "あおは嘘つきだよ"),
            (RichText.plainText(RichText.take(0, spans())),
             RichText.plainText(RichText.take(99, spans()))))

    // ========================================================================
    // wrapLinesBy: 行折り（place と同じ規則。幅は外から与えるのでテストは純粋）
    // ========================================================================

    /// 全角 2・半角 1 の近似幅（呼び側がスクロール勘定に使うのと同じ形）。
    def unitWidth(ch: Char): Float64 = if (Char.isAscii(ch)) 1.0 else 2.0

    // 幅 6 なら全角 3 字ずつで折れる(ちょうど収まる字は同じ行、あふれた字から次の行)。
    @Test
    def testWrapBreaksAtWidth(): Unit \ Assert =
        let lines = RichText.wrapLinesBy(unitWidth, 6.0, spans());
        Assert.assertEq(expected = "あおは" :: "嘘つき" :: "だよ" :: Nil,
            lines |> List.map(RichText.plainText))

    // 1 スパンの途中で折れても、両側の断片に太字属性が残る。
    @Test
    def testWrapKeepsAttributesAcrossBreak(): Unit \ Assert =
        let lines = RichText.wrapLinesBy(unitWidth, 4.0, RichText.strong("嘘つき") :: Nil);
        let flags = lines |> List.map(line -> line |> List.map(span -> span#bold));
        Assert.assertEq(expected = (("嘘つ" :: "き" :: Nil), (true :: Nil) :: (true :: Nil) :: Nil),
            (lines |> List.map(RichText.plainText), flags))

    // '\n' でも折れる。空行は空の行として残る（黙って消えない）。
    @Test
    def testWrapHonorsNewline(): Unit \ Assert =
        let lines = RichText.wrapLinesBy(unitWidth, 99.0, RichText.plain("a\n\nb") :: Nil);
        Assert.assertEq(expected = "a" :: "" :: "b" :: Nil,
            lines |> List.map(RichText.plainText))

    // 行頭では折らない: maxWidth より広い字も 1 字は必ず置く（無限ループを作らない）。
    @Test
    def testWrapPlacesOversizeCharAtLineStart(): Unit \ Assert =
        let lines = RichText.wrapLinesBy(unitWidth, 1.0, RichText.plain("あい") :: Nil);
        Assert.assertEq(expected = "あ" :: "い" :: Nil,
            lines |> List.map(RichText.plainText))

    // 行数の規約: 空の入力も「空行 1 つ」で 0 行にはならず、末尾の '\n' は空行を残す。
    // 行数を高さの予約・スクロールの勘定に使う呼び側が頼る性質なので pin する。
    @Test
    def testWrapLineCountConvention(): Unit \ Assert =
        Assert.assertEq(expected = ("" :: Nil, "" :: Nil, "a" :: "" :: Nil),
            (RichText.wrapLinesBy(unitWidth, 9.0, Nil) |> List.map(RichText.plainText),
             RichText.wrapLinesBy(unitWidth, 9.0, RichText.plain("") :: Nil) |> List.map(RichText.plainText),
             RichText.wrapLinesBy(unitWidth, 9.0, RichText.plain("a\n") :: Nil) |> List.map(RichText.plainText)))

    // BMP の外の字（サロゲートペア）は上位・下位が別々の Char として幅を測られるので、
    // ペアの真ん中で行が折れる。1 字が 2 行に割れる現在の壊れ方を具体値で固定する
    // （幅 2+2=4 が maxWidth 3 に収まらず、2 文字目にあたる下位サロゲートで折れる）。
    @Test
    def testWrapSplitsSurrogatePair(): Unit \ Assert =
        let lines = RichText.wrapLinesBy(unitWidth, 3.0, RichText.plain("𝄞") :: Nil);
        let lens = lines |> List.map(line -> String.length(RichText.plainText(line)));
        Assert.assertEq(expected = (2, 1 :: 1 :: Nil), (List.length(lines), lens))

    // ========================================================================
    // place: 1 字ずつの描画アイテム（返る順序・位置の積み上がり・色）
    // ========================================================================

    /// 'A' = 送り 10、'B' = 20、'C' = 5 の手組み atlas。fontSize 16 で size 16 なら等倍。
    /// 送り幅を字ごとに変えてあるので、x の積み上がりが壊れると位置がずれて落ちる。
    def sampleAtlas(): FontAtlas =
        let metrics = (advance -> ({
            xOff = 0.0, yOff = 0.0, glyphW = advance, glyphH = 10.0,
            advance = advance, s0 = 0.0, t0 = 0.0, s1 = 1.0, t1 = 1.0
        }: TextLayout.GlyphMetrics));
        let glyphs = Map.empty()
            |> Map.insert(65, metrics(10.0))   // 'A'
            |> Map.insert(66, metrics(20.0))   // 'B'
            |> Map.insert(67, metrics(5.0));   // 'C'
        ({
            textureName = "atlas",
            fontSize    = 16.0,
            textureSize = 256.0,
            ascent      = 8.0,
            descent     = 2.0,
            lineGap     = 0.0,
            glyphs      = glyphs
        }: FontAtlas)

    def ink(): Color = {r = 0.1, g = 0.2, b = 0.3}

    /// 左上 (100, 200)・行間 3・文字サイズ 16 の置き方。maxWidth だけテストごとに変える。
    def placement(maxWidth: Float64): RichText.Placement =
        { atlas = sampleAtlas(), size = 16.0, baseTint = ink(), z = 40,
          pos = {x = 100.0, y = 200.0}, maxWidth = maxWidth, lineGap = 3.0 }

    /// 1 アイテムを (字, x, y) に畳む。
    def glyphAt(placed: Render.PlacedItem): (String, Float64, Float64) =
        match placed#item {
            case Render.Item.Text(r) => (r#text, placed#at#x, placed#at#y)
            case _                   => ("?", placed#at#x, placed#at#y)
        }

    /// 1 アイテムの色を (r, g, b) に畳む。
    def glyphTint(placed: Render.PlacedItem): (Float64, Float64, Float64) =
        match placed#item {
            case Render.Item.Text(r) => (r#tint#r, r#tint#g, r#tint#b)
            case _                   => (-1.0, -1.0, -1.0)
        }

    // 1 行に並ぶ字は書いた順で返り、x は前の字の送り幅を足した値になる
    // （'A'=10 → 'B'=20 → 'C'=5 なので 100, 110, 130）。
    @Test
    def testPlaceOrderAndCumulativeX(): Unit \ Assert =
        let items = RichText.place(placement(1000.0),
            RichText.plain("AB") :: RichText.colored("C", {r = 0.0, g = 0.0, b = 1.0}) :: Nil);
        Assert.assertEq(
            expected = ("A", 100.0, 200.0) :: ("B", 110.0, 200.0) :: ("C", 130.0, 200.0) :: Nil,
            items |> List.map(glyphAt))

    // スパンをまたいでも x は続きから積む（1 字だけのスパンを 3 つ並べても上と同じ位置）。
    @Test
    def testPlaceCarriesXAcrossSpans(): Unit \ Assert =
        let items = RichText.place(placement(1000.0),
            RichText.plain("A") :: RichText.plain("B") :: RichText.plain("C") :: Nil);
        Assert.assertEq(
            expected = ("A", 100.0, 200.0) :: ("B", 110.0, 200.0) :: ("C", 130.0, 200.0) :: Nil,
            items |> List.map(glyphAt))

    // 太字スパンは 1 字につき 2 アイテム。素の字が先・半ピクセル右のコピーが後で、
    // x の積み上げには素の送り幅しか効かない（2 字目は 110 のまま）。
    @Test
    def testPlaceBoldEmitsTwoItemsPerChar(): Unit \ Assert =
        let items = RichText.place(placement(1000.0), RichText.strong("AB") :: Nil);
        Assert.assertEq(
            expected = ("A", 100.0, 200.0) :: ("A", 100.5, 200.0)
                    :: ("B", 110.0, 200.0) :: ("B", 110.5, 200.0) :: Nil,
            items |> List.map(glyphAt))

    // 折り返した 2 行目は x が左端に戻り、y は size + lineGap = 19 だけ下がる。
    // maxWidth 25 では 'A'(10) の後に 'B'(20) が入らないので 2 行になる。
    @Test
    def testPlaceWrapsToNextLine(): Unit \ Assert =
        let items = RichText.place(placement(25.0), RichText.plain("AB") :: Nil);
        Assert.assertEq(
            expected = ("A", 100.0, 200.0) :: ("B", 100.0, 219.0) :: Nil,
            items |> List.map(glyphAt))

    // 端: スパン 0 個なら空、1 スパン 1 字なら左上ぴったりに 1 個だけ。
    @Test
    def testPlaceEmptyAndSingle(): Unit \ Assert =
        Assert.assertEq(expected = (0, ("A", 100.0, 200.0) :: Nil),
            (List.length(RichText.place(placement(1000.0), Nil)),
             RichText.place(placement(1000.0), RichText.plain("A") :: Nil) |> List.map(glyphAt)))

    // 色: tint 無指定は baseTint、指定ありはその色。太字のコピーも同じ色になる。
    @Test
    def testPlaceTints(): Unit \ Assert =
        let items = RichText.place(placement(1000.0),
            RichText.plain("A") :: RichText.strong("B") :: RichText.colored("C", {r = 1.0, g = 0.0, b = 0.0}) :: Nil);
        Assert.assertEq(
            expected = (0.1, 0.2, 0.3) :: (0.1, 0.2, 0.3) :: (0.1, 0.2, 0.3) :: (1.0, 0.0, 0.0) :: Nil,
            items |> List.map(glyphTint))

    // ── ルビ ──

    // ふりがなは親字の上に中央そろえで載り（B=20 幅の上に 8px の "AA"=10 幅 → x は 110+5）、y は行の上の rubySize+1 だけ上。
    @Test
    def testPlaceRubyCentersTheReadingAboveTheBase(): Unit \ Assert =
        let items = RichText.placeRuby(placement(1000.0), 8.0, { start = 1, length = 1, text = "AA" } :: Nil, 99,
                                       RichText.plain("AB") :: Nil);
        Assert.assertEq(expected = ("A", 100.0, 200.0) :: ("B", 110.0, 200.0) :: ("AA", 115.0, 191.0) :: Nil,
                        items |> List.map(glyphAt))

    // 文字送りの途中: 親字が全部見えるまでふりがなは出ない。
    @Test
    def testPlaceRubyWaitsForTheWholeBase(): Unit \ Assert =
        let items = visible -> RichText.placeRuby(placement(1000.0), 8.0, { start = 0, length = 2, text = "C" } :: Nil, visible,
                                                  RichText.plain("AB") :: Nil) |> List.map(glyphAt) |> List.map(match (t, _, _) -> t);
        Assert.assertEq(expected = (List#{"A"}, List#{"A", "B", "C"}), (items(1), items(2)))

    // 親字とふりがなは 1 つの塊で行をまたがない。ふりがなが広いと塊の幅はふりがなの幅になる。
    @Test
    def testRubyGroupDoesNotBreakAndTakesTheWiderWidth(): Unit \ Assert =
        let one = _ -> 1.0;
        let count = (rubies, maxWidth) -> RichText.rubyLineCountBy(one, text -> Int32.toFloat64(String.length(text)), maxWidth, rubies,
                                                                   RichText.plain("abcde") :: Nil);
        Assert.assertEq(expected = (2, 2, 3),
                        (count(Nil, 3.0), count({ start = 2, length = 2, text = "x" } :: Nil, 3.0),
                         count({ start = 2, length = 2, text = "xxx" } :: Nil, 3.0)))
}
