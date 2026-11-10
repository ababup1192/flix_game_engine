// TestFlex — Flex（宣言木 → UiLayout 解決）の rect 割当を固定する。
// Float64 の等値比較なので入力は割り切れる数値に限る。割り切れない値（458/5 等）は
// expected 側もレイアウトと同じ式・同じ加算順で書く。
// rect はそのまま Eq できないので (x, y, w, h) の Float64 タプルへ落として比較する。
mod TestFlex {

    /// サイズだけ持つ描画なしの葉。
    def dot(w: Float64, h: Float64): Flex.Node =
        Flex.leaf({ x = w, y = h }, _ -> Nil)

    def rect4(r: Rect2.Rect2): (Float64, Float64, Float64, Float64) =
        (r#position#x, r#position#y, r#size#x, r#size#y)

    def rects(root: Flex.Node, w: Float64, h: Float64): List[(Float64, Float64, Float64, Float64)] =
        Flex.leafRects(root, { position = { x = 0.0, y = 0.0 }, size = { x = w, y = h } })
            |> List.map(rect4)

    // ── 直列・整列・余白 ──

    @Test
    def testRowPlacesLeavesInSequence(): Unit \ Assert =
        let root = Flex.box(Flex.rowStyle(), dot(30.0, 10.0) :: dot(50.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (0.0, 0.0, 30.0, 10.0) :: (30.0, 0.0, 50.0, 10.0) :: Nil,
            rects(root, 100.0, 20.0))

    @Test
    def testGrowDividesFreeSpaceByWeight(): Unit \ Assert =
        // 1:1:2 の Grow は余り全体（base 0）を重み配分する。中身の葉は Stretch で容器幅を映す。
        def growCol(w: Float64): Flex.Node =
            Flex.box({ width = UiLayout.SizeSpec.Grow(w),
                       crossAlign = UiLayout.CrossAlign.Stretch | Flex.columnStyle() },
                     dot(0.0, 10.0) :: Nil);
        let root = Flex.box(Flex.rowStyle(), growCol(1.0) :: growCol(1.0) :: growCol(2.0) :: Nil);
        Assert.assertEq(
            expected = (0.0, 0.0, 100.0, 10.0) :: (100.0, 0.0, 100.0, 10.0) :: (200.0, 0.0, 200.0, 10.0) :: Nil,
            rects(root, 400.0, 10.0))

    @Test
    def testCenterCentersOnBothAxes(): Unit \ Assert =
        let root = Flex.box({ mainAlign = UiLayout.MainAlign.Center,
                              crossAlign = UiLayout.CrossAlign.Center | Flex.columnStyle() },
                            dot(20.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (40.0, 20.0, 20.0, 10.0) :: Nil,
            rects(root, 100.0, 50.0))

    @Test
    def testPaddingAndGapOffsetChildren(): Unit \ Assert =
        let root = Flex.box({ padLeft = 5.0, padTop = 7.0, gap = 3.0 | Flex.columnStyle() },
                            dot(10.0, 10.0) :: dot(10.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (5.0, 7.0, 10.0, 10.0) :: (5.0, 20.0, 10.0, 10.0) :: Nil,
            rects(root, 100.0, 100.0))

    // ── ギャラリー骨格（Px の固定行 + Grow 行 ×5、480×530）──

    @Test
    def testGallerySkeletonBarsAndGrowRows(): Unit \ Assert =
        // 固定行・伸びる行それぞれに Stretch な 0 サイズの葉を置き、固定行の位置と行の等分高さを検分する。
        def barBox(h: Float64): Flex.Node =
            Flex.box({ height = UiLayout.SizeSpec.Px(h),
                       crossAlign = UiLayout.CrossAlign.Stretch | Flex.columnStyle() },
                     dot(0.0, 0.0) :: Nil);
        def rowBox(): Flex.Node =
            Flex.box({ height = UiLayout.SizeSpec.Grow(1.0),
                       crossAlign = UiLayout.CrossAlign.Stretch | Flex.rowStyle() },
                     dot(0.0, 0.0) :: Nil);
        let root = Flex.box({ crossAlign = UiLayout.CrossAlign.Stretch | Flex.columnStyle() },
               barBox(44.0)
            :: rowBox() :: rowBox() :: rowBox() :: rowBox() :: rowBox()
            :: barBox(28.0)
            :: Nil);
        // 行高 = 余り 458 の Grow 配分。UiLayout.growShare と同じ式（free * (w/total)、458/5 とは
        // 最下位ビットが違う）で書き、行の y もペン送りと同じ順の逐次加算で書く。
        let rh = (530.0 - 44.0 - 28.0) * (1.0 / 5.0);
        let y1 = 44.0;
        let y2 = y1 + rh;
        let y3 = y2 + rh;
        let y4 = y3 + rh;
        let y5 = y4 + rh;
        let yNote = y5 + rh;
        Assert.assertEq(
            expected = (0.0, 0.0, 480.0, 0.0)
                    :: (0.0, y1, 0.0, rh) :: (0.0, y2, 0.0, rh) :: (0.0, y3, 0.0, rh)
                    :: (0.0, y4, 0.0, rh) :: (0.0, y5, 0.0, rh)
                    :: (0.0, yNote, 480.0, 0.0)
                    :: Nil,
            rects(root, 480.0, 530.0))

    // ── wrap（折り返し）──

    @Test
    def testWrapBreaksRowsAtWidth(): Unit \ Assert =
        // 幅 100 に 30×10 を gap5 で 5 個 → 1 行目 3 個(30+5+30+5+30=100)、2 行目 2 個。
        // 2 行目の y = 行高 10 + gap 5 = 15。
        let root = Flex.box({ width = UiLayout.SizeSpec.Px(100.0), height = UiLayout.SizeSpec.Px(50.0),
                              wrap = true, gap = 5.0 | Flex.rowStyle() },
               dot(30.0, 10.0) :: dot(30.0, 10.0) :: dot(30.0, 10.0)
            :: dot(30.0, 10.0) :: dot(30.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (0.0, 0.0, 30.0, 10.0) :: (35.0, 0.0, 30.0, 10.0) :: (70.0, 0.0, 30.0, 10.0)
                    :: (0.0, 15.0, 30.0, 10.0) :: (35.0, 15.0, 30.0, 10.0) :: Nil,
            rects(root, 100.0, 50.0))

    @Test
    def testWrapRowHeightIsTallestChild(): Unit \ Assert =
        // 1 行目に高さ 10 と 20 が混在 → 2 行目は y = 20 から始まる(gap 0)。
        let root = Flex.box({ width = UiLayout.SizeSpec.Px(60.0), height = UiLayout.SizeSpec.Px(50.0),
                              wrap = true | Flex.rowStyle() },
               dot(30.0, 10.0) :: dot(30.0, 20.0) :: dot(30.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (0.0, 0.0, 30.0, 10.0) :: (30.0, 0.0, 30.0, 20.0)
                    :: (0.0, 20.0, 30.0, 10.0) :: Nil,
            rects(root, 60.0, 50.0))

    @Test
    def testWrapPlacesOversizeChildOnePerRow(): Unit \ Assert =
        // 1 個も入らない幅でも各行に 1 個は置く(行が空のまま無限に増えない)。
        let root = Flex.box({ width = UiLayout.SizeSpec.Px(20.0), height = UiLayout.SizeSpec.Px(50.0),
                              wrap = true | Flex.rowStyle() },
               dot(30.0, 10.0) :: dot(30.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (0.0, 0.0, 30.0, 10.0) :: (0.0, 10.0, 30.0, 10.0) :: Nil,
            rects(root, 20.0, 50.0))

    // ── abs（フロー外）──

    @Test
    def testAbsChildIsOutOfFlow(): Unit \ Assert =
        // column 親（pad 左2/上3）の下に abs=(10,20) の子 + フローの子 2 つ。
        // abs 子は親コンテンツ原点 + (10,20) に内在サイズで置かれ、フローの子 2 つは
        // abs 子を無視して縦に積まれる。親の自動高さにも abs 子は影響しない —
        // 後続の marker が y = 親高(3+10+10) から始まることで固定する。
        let absChild = Flex.box({ abs = Some({ x = 10.0, y = 20.0 }) | Flex.columnStyle() },
                                dot(5.0, 5.0) :: Nil);
        let parent = Flex.box({ padLeft = 2.0, padTop = 3.0 | Flex.columnStyle() },
                              absChild :: dot(30.0, 10.0) :: dot(30.0, 10.0) :: Nil);
        let root = Flex.box(Flex.columnStyle(), parent :: dot(30.0, 10.0) :: Nil);
        Assert.assertEq(
            expected = (12.0, 23.0, 5.0, 5.0)                       // abs 子（コンテンツ原点 (2,3) + (10,20)）
                    :: (2.0, 3.0, 30.0, 10.0) :: (2.0, 13.0, 30.0, 10.0)  // フローの子（abs 子を無視して縦積み）
                    :: (0.0, 23.0, 30.0, 10.0)                      // marker（親の自動高さに abs 子が入らない）
                    :: Nil,
            rects(root, 100.0, 100.0))

    // ── place: 確定 rect が draw に届いて連結される ──

    @Test
    def testPlacePassesRectsToDrawInTreeOrder(): Unit \ Assert =
        def mark(): Color = { r = 1.0, g = 1.0, b = 1.0 };
        let root = Flex.box(Flex.rowStyle(),
               Flex.leaf({ x = 30.0, y = 10.0 },
                         r -> ({ at = r#position, item = RawDraw.box(r#size, mark(), 1) }) :: Nil)
            :: Flex.leaf({ x = 50.0, y = 10.0 },
                         r -> ({ at = r#position, item = RawDraw.box(r#size, mark(), 1) }) :: Nil)
            :: Flex.leafAtCenter({ x = 20.0, y = 10.0 },
                         c -> RawDraw.boxAt(c, { x = 4.0, y = 4.0 }, mark(), 1) :: Nil)
            :: Nil);
        let placed = Flex.place(root, { position = { x = 0.0, y = 0.0 }, size = { x = 100.0, y = 20.0 } });
        // leafAtCenter は中心 (90, 5) を受け、boxAt が半寸ずらすので at = (88, 3)。
        Assert.assertEq(
            expected = (0.0, 0.0) :: (30.0, 0.0) :: (88.0, 3.0) :: Nil,
            placed |> List.map(p -> (p#at#x, p#at#y)))
    // ── wrappedText ──

    /// pad 8 の箱に折り返す字を 1 つ置くと、箱の高さは字の高さ + 16（窓が行数に合わせて伸びる）。
    @Test
    def testBoxFitsWrappedText(): Unit \ Assert =
        let atlas = { textureName = "t", fontSize = 1.0, textureSize = 1.0, ascent = 1.0, descent = 0.0,
                      lineGap = 0.0,
                      glyphs = Map.insert(65, { xOff = 0.0, yOff = 0.0, glyphW = 0.0, glyphH = 0.0, advance = 10.0,
                                                s0 = 0.0, t0 = 0.0, s1 = 0.0, t1 = 0.0 }, Map.empty()) };
        let look = { atlas = atlas, fontSize = 1.0, wrapWidth = 35.0, tint = { r = 1.0, g = 1.0, b = 1.0 }, zIndex = 0 };
        let style = { padLeft = 8.0, padTop = 8.0, padRight = 8.0, padBottom = 8.0 | Flex.columnStyle() };
        let inner = TextDraw.wrappedSize("AAAAA", atlas, 1.0, 35.0);
        // root の大きさは rootRect に上書きされるので、窓は外側の箱の子に置いて測る。
        let root = Flex.box(Flex.columnStyle(),
                            Flex.keyed("window", Flex.box(style, Flex.wrappedText(look, "AAAAA") :: Nil)) :: Nil);
        let r = Map.getWithDefault("window", { position = { x = 0.0, y = 0.0 }, size = { x = 0.0, y = 0.0 } },
                                   Flex.rectsOf(root, { position = { x = 0.0, y = 0.0 }, size = { x = 200.0, y = 200.0 } }));
        Assert.assertEq(expected = inner#y + 16.0, r#size#y)
}
