// TextDraw のテスト。芯（width / centerLeft）の値と、centered がそれらの合成であること
// を、advance を固定した小さなアトラスで pin する。Vec2 は Eq 非導出ゆえ座標はスカラで比較。

mod TestTextDraw {

    // advance だけ意味のあるグリフ（他のメトリクスは幅計算に効かないので 0）。
    def gm(advance: Float64): TextLayout.GlyphMetrics =
        { xOff = 0.0, yOff = 0.0, glyphW = 0.0, glyphH = 0.0, advance = advance,
          s0 = 0.0, t0 = 0.0, s1 = 0.0, t1 = 0.0 }

    // 'A'(65)・'B'(66) が各 advance=10、fontSize=1 のアトラス。size を s とすると
    // scale = s/1 なので width("AB") = 2 文字 × 10 × s。
    def atlas(): FontAtlas =
        { textureName = "test", fontSize = 1.0, textureSize = 1.0,
          ascent = 1.0, descent = 0.0, lineGap = 0.0,
          glyphs = Map.insert(66, gm(10.0), Map.insert(65, gm(10.0), Map.empty())) }

    /// width は advance 合計 × scale：'A','B' 各 10 を size=2 で測って 40。
    @Test
    def testWidthSumsAdvances(): Unit \ Assert =
        Assert.assertEq(expected = 40.0, TextDraw.width("AB", atlas(), 2.0))

    /// centerLeft は幅の半分だけ左：centerX=100・width=40 → 左端 80。
    @Test
    def testCenterLeftIsHalfWidthLeft(): Unit \ Assert =
        Assert.assertEq(expected = 80.0, TextDraw.centerLeft("AB", atlas(), 2.0, 100.0))

    /// size は幅 = width と一致し、高さ = ascent+descent（1 行分）を size 倍する：
    /// アトラスは ascent=1・descent=0・fontSize=1 なので size=2 で高さ 2、幅は "AB" で 40。
    @Test
    def testSizeMatchesWidthAndHeight(): Unit \ Assert =
        let s = TextDraw.size("AB", atlas(), 2.0);
        Assert.assertEq(expected = (TextDraw.width("AB", atlas(), 2.0), 2.0), (s#x, s#y))

    /// centered の左上 x は centerLeft に一致し、y はそのまま通る（芯の合成であることを固定）。
    @Test
    def testCenteredUsesCenterLeftAndWidth(): Unit \ Assert =
        let a = { text = "AB", atlas = atlas(), size = 2.0,
                  color = {r = 1.0, g = 1.0, b = 1.0}, z = 0, centerX = 100.0, y = 5.0 };
        let pos = TextDraw.centered(a)#at;
        Assert.assertEq(
            expected = (TextDraw.centerLeft("AB", atlas(), 2.0, 100.0), 5.0),
            (pos#x, pos#y))

    /// centeredAt の左上は center から寸法の半分だけ引いた点（縦横とも中央そろえ）：
    /// center=(100,50)・size="AB"(40,2) → 左上 (80, 49)。size() との整合で pin。
    @Test
    def testCenteredAtSubtractsHalfSize(): Unit \ Assert =
        let a = { text = "AB", atlas = atlas(), size = 2.0,
                  color = {r = 1.0, g = 1.0, b = 1.0}, z = 0,
                  center = {x = 100.0, y = 50.0} };
        let pos = TextDraw.centeredAt(a)#at;
        let s = TextDraw.size("AB", atlas(), 2.0);
        Assert.assertEq(
            expected = (100.0 - s#x / 2.0, 50.0 - s#y / 2.0),
            (pos#x, pos#y))
    // ── wrappedSize ──
    // advance 10・fontSize 1 のアトラスで size=1 なので、字 1 つ = 幅 10・1 行 = 高さ 1。

    def wrapped(text: String, wrapWidth: Float64): (Float64, Float64) =
        let s = TextDraw.wrappedSize(text, atlas(), 1.0, wrapWidth);
        (s#x, s#y)

    /// 幅に収まる字は 1 行分の高さ（行の高さ 1 つ）と、その字の幅。
    @Test
    def testWrappedSizeFitsOneLine(): Unit \ Assert =
        Assert.assertEq(expected = (20.0, 1.0), wrapped("AB", 100.0))

    /// 幅を超える字は次の行へ送られ、幅は一番長い行（3 字 = 30）・高さは 2 行分。
    @Test
    def testWrappedSizeBreaksAtWrapWidth(): Unit \ Assert =
        Assert.assertEq(expected = (30.0, 2.0), wrapped("ABABA", 35.0))

    /// 字の改行（\n）で、幅に余裕があっても行が増える。
    @Test
    def testWrappedSizeCountsNewline(): Unit \ Assert =
        Assert.assertEq(expected = (20.0, 2.0), wrapped("AB\nA", 100.0))

    /// 空の字は何も描かないので高さ 0。
    @Test
    def testWrappedSizeEmptyIsZero(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 0.0), wrapped("", 100.0))

    /// wrappedSize の行数は、Render.textWrapped が実際に描く字の段数（y の種類）と同じ。
    @Test
    def testWrappedSizeRowsMatchDrawnRows(): Unit \ Assert =
        let text = "ABABABAB";
        // 大きさ 0 の字は描き物にならないので、この確かめだけ字に大きさを与える。
        let visible = { glyphs = Map.map(g -> { glyphW = 1.0, glyphH = 1.0 | g }, atlas()#glyphs) | atlas() };
        let drawn = Render.Internal.Extract.textDrawables(text, visible, 1.0, { r = 1.0, g = 1.0, b = 1.0 },
                                                          1.0, 0.0, 0, Some(35.0), { x = 0.0, y = 0.0 });
        let rows = drawn |> List.map(d -> { let DrawCmd.Drawable.Drawable(_, _, py, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = d; py })
                         |> List.toSet |> Set.size;
        Assert.assertEq(expected = Int32.toFloat64(rows), TextDraw.wrappedSize(text, atlas(), 1.0, 35.0)#y)
}
