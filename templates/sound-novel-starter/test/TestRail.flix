// 縦の画面の右の列（しおり・ログ・オート）と右上の …、指の長押し（touchHold のキー）をテストする。
// 押しは実機と同じ Controls.interact に、押した・押したまま・離したのフレームを順に渡して作る（縦に持ったスマホの縦の画面）。
// 矩形は View が描く所と同じ Rail の関数から引き、秒は novel.rail.json と novel.kind.json から導く（Doc の値を変えてもテストは壊れない）。
mod TestRail {

    use fge::{App, Clock, Display, Rect2}
    use fge::GameEngine.Key
    use TestKit.{begun, quiet}

    def kind(res: Res.Res): KindDoc.Rec = KindDoc.rec(res#kind)

    /// 縦に持ったスマホ（390×844）の縦の design。
    def tall(): { x = Float64, y = Float64 } = { x = 540.0, y = 1169.0 }

    /// 太い縦の画面（360×640）の縦の design（下限の高さ）。
    def short(): { x = Float64, y = Float64 } = { x = 540.0, y = 960.0 }

    def portraitOf(res: Res.Res, design: { x = Float64, y = Float64 }): Layout.Fit =
        Layout.fitOf(Display.SizeClass.Small, Display.Orientation.Portrait, design, res#smallScreen, res#portrait)

    def portrait(res: Res.Res): Layout.Fit = portraitOf(res, tall())

    /// 列を画面の下から積む縦の画面（novel.rail.json の anchor = bottom と同じ形）。
    def bottomAnchored(res: Res.Res, design: { x = Float64, y = Float64 }): Layout.Fit = match portraitOf(res, design) {
        case Layout.Fit.Portrait(p, size) => Layout.Fit.Portrait({ rail = { anchor = defaultBottomAnchor() | p#rail } | p }, size)
        case other                        => other
    }

    /// novel.rail.json に anchor = bottom だけを書いた時の積み方（余白は RailDoc の既定）。
    def defaultBottomAnchor(): RailDoc.Anchor =
        RailDoc.fromJson("{ \"anchor\": \"bottom\" }") |> Option.map(d -> RailDoc.rec(d)#anchor) |> Option.getWithDefault(RailDoc.Anchor.Bottom(0.0))

    /// 頁の左の、右の列のボタンにも右上の … にも当たらない所。
    def spot(): { x = Float64, y = Float64 } = { x = 140.0, y = 640.0 }

    def center(r: Rect2.Rect2): { x = Float64, y = Float64 } =
        { x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 }

    def indexOf(res: Res.Res, button: World.Button): Int32 =
        WorldMenu.buttonIndexOf(portrait(res), button) |> Option.getWithDefault(0)

    def buttonCenter(res: Res.Res, button: World.Button): { x = Float64, y = Float64 } =
        center(Rail.button(portrait(res), indexOf(res, button)))

    def frameAt(at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        { cursor = p, viewport = tall(), sizeClass = Display.SizeClass.Small, dt = 0.1, realNow = Clock.after(at, Clock.zero()) | App.emptyFrame() }

    /// at 秒に p を押したフレーム。
    def down(at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        { mouseClicked = true, mouseDown = true | frameAt(at, p) }

    /// at 秒に p を押したままのフレーム。
    def held(at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        { mouseDown = true | frameAt(at, p) }

    /// at 秒に p で離したフレーム。
    def up(at: Float64, p: { x = Float64, y = Float64 }): App.Frame = frameAt(at, p)

    /// 0 秒に p を押し、長押しの秒を 0.1 秒越えるまで押したままにするフレーム（離さない）。
    def pressLong(res: Res.Res, p: { x = Float64, y = Float64 }): List[App.Frame] =
        let long = Rail.longPressSecondsOf(portrait(res));
        down(0.0, p) :: held(long / 2.0, p) :: held(long + 0.1, p) :: Nil

    /// フレームを古い順に Controls.interact へ渡す。
    def play(res: Res.Res, frames: List[App.Frame], w: World.World): World.World =
        List.foldLeft((acc, frame) -> Controls.interact(frame, res, acc), w, frames)

    def keyOf(keys: List[Key], fallback: Key): Key = List.head(keys) |> Option.getWithDefault(fallback)

    /// ブラウザ版の指の長押しを離したフレーム（押しは出さず、touchGestures の longPress = touchHold のキーが押した所のまま届く）。
    def touchHoldRelease(res: Res.Res, at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        let hold = keyOf(KeysDoc.rec(res#keys)#touchHold, Key.Menu);
        { justPressed = Set#{hold}, down = Set#{hold} | up(at, p) }

    def tipOf(w: World.World): Option[Int32] = World.readOf(w) |> Option.flatMap(r -> r#tip) |> Option.map(fst)

    // ══ 列のボタンは本文のタップにならない ══

    @Test
    def testRailTapIsNotAlsoATap(): Unit \ {Assert, Fs.FileRead} =
        // 右の列のオートを押して（遊び始めて 5 秒の所で）すぐ離しても、オートが入るだけで、本文のタップとして台詞は進まない。
        let res = TestKit.res();
        let start = begun(res);
        let p = buttonCenter(res, World.Button.Auto);
        let w = play(res, down(5.0, p) :: up(5.1, p) :: Nil, start);
        Assert.assertEq(expected = (World.Playback.Auto, World.talkLineOf(start)), (World.playbackOf(w), World.talkLineOf(w)))

    @Test
    def testRailLongPressTooltipIsNotAlsoATap(): Unit \ {Assert, Fs.FileRead} =
        // 右の列のログを長押ししてツールチップを出してから離しても、ログは開かず、台詞も進まない。
        let res = TestKit.res();
        let start = begun(res);
        let p = buttonCenter(res, World.Button.Log);
        let w = play(res, List.append(pressLong(res, p), up(5.0, p) :: Nil), start);
        Assert.assertEq(expected = ("Closed", World.talkLineOf(start)), (World.panelName(w), World.talkLineOf(w)))

    @Test
    def testRailLongPressAutoStillStartsSkip(): Unit \ {Assert, Fs.FileRead} =
        // 右の列のオートを長押しするとスキップになる（離す前に入る）。
        let res = TestKit.res();
        let w = play(res, pressLong(res, buttonCenter(res, World.Button.Auto)), begun(res));
        Assert.assertEq(expected = World.Playback.Skip, World.playbackOf(w))

    @Test
    def testRailTapOnAutoWhileSkippingStopsSkip(): Unit \ {Assert, Fs.FileRead} =
        // スキップの間に右の列のオートを短く押して離すと、オートにはならずスキップが止まる（列にスキップのボタンは無い）。
        let res = TestKit.res();
        let skipping = World.mapRead(r -> { playback = World.Playback.Skip | r }, begun(res));
        let p = buttonCenter(res, World.Button.Auto);
        let w = play(res, down(5.0, p) :: up(5.1, p) :: Nil, skipping);
        Assert.assertEq(expected = World.Playback.Manual, World.playbackOf(w))

    // ══ 指の長押し（touchHold） ══

    @Test
    def testTouchHoldOnLogShowsItsNameWithoutHiding(): Unit \ {Assert, Fs.FileRead} =
        // 指でログを長押しして離すと、ウィンドウは隠さず、ログも開かず、名前のツールチップを出す。
        let res = TestKit.res();
        let w = play(res, touchHoldRelease(res, 1.0, buttonCenter(res, World.Button.Log)) :: Nil, begun(res));
        Assert.assertEq(expected = ("Closed", Some(indexOf(res, World.Button.Log))), (World.panelName(w), tipOf(w)))

    @Test
    def testTouchHoldOnAutoStartsSkip(): Unit \ {Assert, Fs.FileRead} =
        // 指でオートを長押しして離すとスキップになる（ウィンドウは隠さない）。
        let res = TestKit.res();
        let w = play(res, touchHoldRelease(res, 1.0, buttonCenter(res, World.Button.Auto)) :: Nil, begun(res));
        Assert.assertEq(expected = (World.Playback.Skip, "Closed"), (World.playbackOf(w), World.panelName(w)))

    @Test
    def testTouchHoldOnTextHidesTheWindow(): Unit \ {Assert, Fs.FileRead} =
        // 本文の上の指の長押しはウィンドウを隠す。
        let res = TestKit.res();
        let w = play(res, touchHoldRelease(res, 1.0, spot()) :: Nil, begun(res));
        Assert.assertEq(expected = "Hidden", World.panelName(w))

    @Test
    def testTouchHoldOnMoreDoesNothing(): Unit \ {Assert, Fs.FileRead} =
        // … の上の指の長押しは、隠さず、メニューも開かず、台詞も進めない。
        let res = TestKit.res();
        let start = begun(res);
        let w = play(res, touchHoldRelease(res, 1.0, center(Rail.moreButton(portrait(res))#hit)) :: Nil, start);
        Assert.assertEq(expected = ("Closed", World.talkLineOf(start)), (World.panelName(w), World.talkLineOf(w)))

    @Test
    def testEscapeOnRailHidesWithoutTooltip(): Unit \ {Assert, Fs.FileRead} =
        // キーボードの戻るのキー（Esc）は、カーソルが列の上でもツールチップを出さず、ウィンドウを隠す。
        let res = TestKit.res();
        let back = keyOf(KeysDoc.rec(res#keys)#back, Key.Escape);
        let frame = { justPressed = Set#{back}, down = Set#{back} | up(1.0, buttonCenter(res, World.Button.Log)) };
        let w = play(res, frame :: Nil, begun(res));
        Assert.assertEq(expected = ("Hidden", None), (World.panelName(w), tipOf(w)))

    @Test
    def testLandscapeTouchHoldHidesTheWindow(): Unit \ {Assert, Fs.FileRead} =
        // 横に持ったスマホ（下の帯の横の画面）でも、指の長押しはウィンドウを隠す。
        let res = TestKit.res();
        let hold = keyOf(KeysDoc.rec(res#keys)#touchHold, Key.Menu);
        let frame = { justPressed = Set#{hold}, down = Set#{hold}, cursor = { x = 480.0, y = 200.0 }, sizeClass = Display.SizeClass.Small | App.emptyFrame() };
        let w = play(res, frame :: Nil, begun(res));
        Assert.assertEq(expected = "Hidden", World.panelName(w))

    @Test
    def testTooltipEndsAfterToastSecondsAndWhenAPanelOpens(): Unit \ {Assert, Fs.FileRead} =
        // 指の長押しで出した名前は、知らせと同じ秒の内は出ていて、その秒を過ぎると消え、設定の画面を開くと消える。
        let res = TestKit.res();
        let w = play(res, touchHoldRelease(res, 1.0, buttonCenter(res, World.Button.Log)) :: Nil, begun(res));
        let shownAt = (seconds: Float64) -> World.readOf(w) |> Option.flatMap(World.tipOf(res, Clock.after(seconds, Clock.zero())));
        let opened = quiet(() -> WorldMenu.press(res, World.Button.Settings, w));
        Assert.assertEq(expected = (Some(indexOf(res, World.Button.Log)), None, None),
                        (shownAt(1.0 + kind(res)#toastSeconds / 2.0), shownAt(1.0 + kind(res)#toastSeconds + 0.1), tipOf(opened)))

    // ══ 右上の … としおり ══

    @Test
    def testMoreOpensTheMenuWithoutAdvancing(): Unit \ {Assert, Fs.FileRead} =
        // 右上の … を押して離すと … のメニューが開き、台詞は進まない。
        let res = TestKit.res();
        let start = begun(res);
        let p = center(Rail.moreButton(portrait(res))#hit);
        let w = play(res, down(0.0, p) :: up(0.1, p) :: Nil, start);
        Assert.assertEq(expected = ("Menu", World.talkLineOf(start)), (World.panelName(w), World.talkLineOf(w)))

    @Test
    def testReleasingOffTheButtonCancels(): Unit \ {Assert, Fs.FileRead} =
        // マウスで列のオートを押し、ボタンの外（頁の上）へずらして離すと、オートは入らず台詞も進まず、掴みも外れる。
        let res = TestKit.res();
        let start = begun(res);
        let p = buttonCenter(res, World.Button.Auto);
        let w = play(res, down(5.0, p) :: held(5.05, spot()) :: up(5.1, spot()) :: Nil, start);
        Assert.assertEq(expected = (World.Playback.Manual, World.talkLineOf(start), World.Grab.Free),
                        (World.playbackOf(w), World.talkLineOf(w), w#grab))

    @Test
    def testTouchReleaseAtThePressPointStillTaps(): Unit \ {Assert, Fs.FileRead} =
        // ブラウザ版の指は、動かしている間は指の所に、離す時は押した所に戻して届く（fge-web.js）。その形なら、
        // 指をずらしても今までどおり押したことになる。
        let res = TestKit.res();
        let start = begun(res);
        let p = buttonCenter(res, World.Button.Auto);
        let w = play(res, down(5.0, p) :: held(5.05, spot()) :: up(5.1, p) :: Nil, start);
        Assert.assertEq(expected = World.Playback.Auto, World.playbackOf(w))

    @Test
    def testSaveLoadOpensSaveThroughItsPick(): Unit \ {Assert, Fs.FileRead} =
        // しおりを押して離すと [セーブ｜ロード] の選びが開き、セーブを押すとセーブの画面になる。台詞は進まない。
        let res = TestKit.res();
        let start = begun(res);
        let mark = buttonCenter(res, World.Button.SaveLoad);
        let chosen = play(res, down(0.0, mark) :: up(0.1, mark) :: Nil, start);
        let save = center(Rail.saveLoadItem(portrait(res), 0, List.length(WorldMenu.saveLoadItems())));
        let w = play(res, down(1.0, save) :: up(1.1, save) :: Nil, chosen);
        Assert.assertEq(expected = ("SaveLoadPick", "SaveSlots", World.talkLineOf(start)), (World.panelName(chosen), World.panelName(w), World.talkLineOf(w)))

    // ══ 置き場所 ══

    /// 列の全部の押せる正方形（上から）。
    def railRects(fit: Layout.Fit): List[Rect2.Rect2] =
        List.range(0, List.length(WorldMenu.buttonsOf(fit))) |> List.map(Rail.button(fit))

    def bottomOf(r: Rect2.Rect2): Float64 = r#position#y + r#size#y

    def rightOf(r: Rect2.Rect2): Float64 = r#position#x + r#size#x

    @Test
    def testBottomAnchorEndsTheRailAtRailBottom(): Unit \ {Assert, Fs.FileRead} =
        // 列を下から積むと、最後のボタンの下端は画面の下から railBottom の所に来る。
        let res = TestKit.res();
        let fit = bottomAnchored(res, tall());
        let last = railRects(fit) |> List.last |> Option.map(bottomOf) |> Option.getWithDefault(0.0);
        Assert.assertEq(expected = Layout.height(fit) - 36.0, last)

    @Test
    def testPageAndChoicesEndLeftOfTheRail(): Unit \ {Assert, Fs.FileRead} =
        // 頁の文と選択肢は、列の左端より左で終わる（列を上から積んでも下から積んでも・選択肢の有無どちらでも・太い縦の画面でも）。
        let res = TestKit.res();
        let fits = portraitOf(res, short()) :: portraitOf(res, tall()) :: bottomAnchored(res, short()) :: bottomAnchored(res, tall()) :: Nil;
        let crossing = fits |> List.count(fit -> {
            let areas = Layout.page(fit, 0) :: Layout.page(fit, 3) :: (List.range(0, 3) |> List.map(i -> Layout.choice(fit, i, 3)));
            areas |> List.exists(r -> rightOf(r) >= Rail.left(fit))
        });
        Assert.assertEq(expected = 0, crossing)

    @Test
    def testRailStacksDownTheRightEdgeWithoutOverlap(): Unit \ {Assert, Fs.FileRead} =
        // 列のボタンは、画面の右半分の中に左端をそろえて縦一列、上から順に重ならず下へ並ぶ（… とも重ならない）。
        let res = TestKit.res();
        let fit = portrait(res);
        let rects = Rail.moreButton(fit)#hit :: railRects(fit);
        let columns = railRects(fit) |> List.map(r -> r#position#x) |> List.distinct |> List.length;
        let stacked = List.zip(rects, List.drop(1, rects)) |> List.forAll(match (a, b) -> bottomOf(a) <= b#position#y);
        let inside = rects |> List.forAll(r -> rightOf(r) <= Layout.width(fit) and r#position#x > Layout.width(fit) / 2.0);
        Assert.assertEq(expected = (1, true, true), (columns, stacked, inside))

    @Test
    def testPopupGroundsStayInsideTheScreen(): Unit \ {Assert, Fs.FileRead} =
        // … のメニューの地としおりの選びの地は、太い縦の画面でも、列を下から積んでも、画面の中に収まる。
        let res = TestKit.res();
        let fits = portraitOf(res, short()) :: bottomAnchored(res, short()) :: Nil;
        let boxes = fits |> List.flatMap(fit ->
            Rail.menuBox(fit, List.length(WorldMenu.menuItems())) :: Rail.saveLoadBox(fit, List.length(WorldMenu.saveLoadItems())) :: Nil);
        let outside = boxes |> List.count(r -> r#position#x < 0.0 or r#position#y < 0.0 or rightOf(r) > 540.0 or bottomOf(r) > 960.0);
        Assert.assertEq(expected = 0, outside)
}
