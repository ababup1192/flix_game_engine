// TestUiFocusNav — 名前付きの選べる物を矢印・Tab・ホバーで巡るフォーカスの決まりを固定する。
mod TestUiFocusNav {

    /// 枠 1 つ（左上と大きさ）。
    def box(x: Float64, y: Float64): Rect2.Rect2 = { position = { x = x, y = y }, size = { x = 20.0, y = 20.0 } }

    /// 横に 3 つ（a b c）と、b の下に 1 つ（d）。
    ///   a  b  c
    ///      d
    def targets(): List[UiFocusNav.Target[String]] =
        { key = "a", rect = box(0.0, 0.0) } :: { key = "b", rect = box(40.0, 0.0) } ::
        { key = "c", rect = box(80.0, 0.0) } :: { key = "d", rect = box(44.0, 40.0) } :: Nil

    /// origin にキーで乗っているところから矢印を 1 回押した先。
    def arrow(step: (Int32, Int32), origin: String): Option[String] =
        UiFocusNav.update({ step = step | UiFocusNav.noInput() }, targets(), UiFocusNav.focusByKey(origin))#key

    /// origin から Tab を delta 回ぶん 1 回押した先（origin が None なら何にも乗っていない）。
    def tab(delta: Int32, origin: Option[String]): Option[String] =
        UiFocusNav.update({ tab = delta | UiFocusNav.noInput() }, targets(), { key = origin, byKey = true })#key

    @Test
    def testArrowsGoToTheNearestOneInThatDirection(): Unit \ Assert =
        // → は同じ行の隣へ、↓ は下の物へ、← で戻る。前に何も無ければ動かない。
        Assert.assertEq(expected = (Some("b"), Some("d"), Some("a"), Some("c")),
            (arrow((1, 0), "a"), arrow((0, 1), "b"), arrow((-1, 0), "b"), arrow((1, 0), "c")))

    @Test
    def testTheFirstArrowLandsOnTheFirstTarget(): Unit \ Assert =
        // どこにも乗っていなければ、最初の矢印で列の先頭に乗る。
        Assert.assertEq(expected = Some("a"),
            UiFocusNav.update({ step = (0, 1) | UiFocusNav.noInput() }, targets(), UiFocusNav.empty())#key)

    @Test
    def testTabFollowsTheListOrderAndWraps(): Unit \ Assert =
        Assert.assertEq(expected = (Some("b"), Some("a"), Some("d")),
            (tab(1, Some("a")), tab(1, Some("d")), tab(-1, None)))

    @Test
    def testTheLastInputWins(): Unit \ Assert =
        // マウスで c に乗った後に ← を押すとキーのフォーカス（b）、マウスを動かすとまた指の下（c）。
        let input = UiFocusNav.noInput();
        let mouse = { pointer = { x = 85.0, y = 5.0 }, pointerMoved = true | input };
        let hovered = UiFocusNav.update(mouse, targets(), UiFocusNav.empty());
        let keyed = UiFocusNav.update({ step = (-1, 0) | input }, targets(), hovered);
        let back = UiFocusNav.update(mouse, targets(), keyed);
        Assert.assertEq(expected = ((Some("c"), false), (Some("b"), true), (Some("c"), false)),
            ((hovered#key, hovered#byKey), (keyed#key, keyed#byKey), (back#key, back#byKey)))

    @Test
    def testAMouseFocusFollowsWhatMovesUnderTheStillPointer(): Unit \ Assert =
        // マウスで a に乗ったまま指を止め、a が動いて b がその場所へ来たら、フォーカスは b に移る。
        let still = { pointer = { x = 5.0, y = 5.0 } | UiFocusNav.noInput() };
        let moved = { key = "b", rect = box(0.0, 0.0) } :: { key = "a", rect = box(40.0, 0.0) } :: Nil;
        Assert.assertEq(expected = Some("b"), UiFocusNav.update(still, moved, UiFocusNav.focusByPointer("a"))#key)

    @Test
    def testAFocusWhoseTargetIsGoneIsDropped(): Unit \ Assert =
        let gone = UiFocusNav.update(UiFocusNav.noInput(), targets(), UiFocusNav.focusByKey("z"));
        Assert.assertEq(expected = None, gone#key)

    @Test
    def testTargetsOfUiListsTheMenuItems(): Unit \ Assert =
        // UiDoc のメニュー（meta を持つ子が項目）から、項目のパスと枠を Target の列にする（見出しは入らない）。
        let doc = "{\"root\": {\"name\":\"menu\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":100,\"height\":100,\"dir\":\"column\","
                + "\"children\":["
                + "{\"name\":\"head\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10},"
                + "{\"name\":\"slot0\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,\"meta\":\"m/0\"},"
                + "{\"name\":\"slot1\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,\"meta\":\"m/1\"}]}}";
        let got = DocJson.parse(doc)
            |> Option.flatMap(json -> UiSpec.parse(json) |> Result.toOption)
            |> Option.map(spec -> { let (_, ui) = UiSpec.spawnRoot(spec, UiStore.empty()); ui })
            |> Option.map(ui -> UiFocusNav.targetsOfUi("menu", ui, { x = 100.0, y = 100.0 }) |> List.map(t -> t#key));
        Assert.assertEq(expected = Some("menu/slot0" :: "menu/slot1" :: Nil), got)
}
