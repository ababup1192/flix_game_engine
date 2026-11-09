// 縦の画面（縦の design で起動した時）の並べ方の当たりと押せる大きさをテストする。
// 当たりの矩形は View が描く所と同じ Layout の関数から引く（座標の数を写さない）。Frame#viewport が縦長なら縦の並べ方になる。
mod TestPortrait {

    use fge::{App, Clock, Display, Rect2}
    use fge::GameEngine.Key
    use TestKit.{begun, w0}

    /// 縦に持ったスマホ（390×844）の縦の design。
    def tall(): { x = Float64, y = Float64 } = { x = 540.0, y = 1169.0 }

    /// 太い縦の画面（360×640）の縦の design（下限の高さ）。
    def short(): { x = Float64, y = Float64 } = { x = 540.0, y = 960.0 }

    def portrait(res: Res.Res, design: { x = Float64, y = Float64 }): Layout.Fit =
        Layout.fitOf(Display.SizeClass.Small, Display.Orientation.Portrait, design, res#smallScreen, res#portrait)

    def center(r: { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } }): { x = Float64, y = Float64 } =
        { x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 }

    /// 縦の design の画面で p を押した 1 フレーム。
    def press(res: Res.Res, design: { x = Float64, y = Float64 }, p: { x = Float64, y = Float64 }, w: World.World): World.World =
        Controls.interact({ mouseClicked = true, mouseDown = true, cursor = p, viewport = design, sizeClass = Display.SizeClass.Small | App.emptyFrame() }, res, w)

    /// 縦の design の画面で p を押して離す（右の列のボタンは離した時に押したことになる）。
    def tapOn(res: Res.Res, design: { x = Float64, y = Float64 }, p: { x = Float64, y = Float64 }, w: World.World): World.World =
        TestKit.tapAt(res, { viewport = design, sizeClass = Display.SizeClass.Small | App.emptyFrame() }, p, w)

    /// 縦の design の画面でキーを押した 1 フレーム。
    def tap(res: Res.Res, design: { x = Float64, y = Float64 }, key: Key, w: World.World): World.World =
        Controls.interact({ justPressed = Set#{key}, down = Set#{key}, viewport = design | App.emptyFrame() }, res, w)

    def buttonRect(fit: Layout.Fit, button: World.Button): { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } } =
        Rail.button(fit, WorldMenu.buttonIndexOf(fit, button) |> Option.getWithDefault(0))

    def titleRect(fit: Layout.Fit, item: World.TitleItem): { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } } =
        let all = WorldMenu.titleItems();
        let i = all |> List.zipWithIndex |> List.find(match (_, it) -> it == item) |> Option.map(fst) |> Option.getWithDefault(0);
        Layout.titleItem(fit, i, List.length(all))

    def isLogOpen(w: World.World): Bool = match w#panel {
        case World.Panel.Log(_) => true
        case _                  => false
    }

    def isSettingsOpen(w: World.World): Bool = match w#panel {
        case World.Panel.Settings(_) => true
        case _                       => false
    }

    def slotCursorOf(w: World.World): Int32 = match w#panel {
        case World.Panel.SaveSlots(_, i) => i
        case World.Panel.LoadSlots(_, i) => i
        case _                           => -1
    }

    /// 縦の画面で押せる物の矩形の全部（右の列・…・しおりの選び・… のメニュー・タイトル・確認・戻る・タブ・セーブの枠と削除・設定の行と 2 択・選択肢 3 つ）。
    def touchTargets(fit: Layout.Fit): List[{ position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } }] =
        let saveLoads = List.length(WorldMenu.saveLoadItems());
        let buttons = List.range(0, List.length(WorldMenu.buttonsOf(fit))) |> List.map(Rail.button(fit));
        let more = Rail.moreButton(fit)#hit :: (List.range(0, saveLoads) |> List.map(i -> Rail.saveLoadItem(fit, i, saveLoads)));
        let titles = List.range(0, List.length(WorldMenu.titleItems())) |> List.map(i -> Layout.titleItem(fit, i, List.length(WorldMenu.titleItems())));
        let asks = Layout.sides() |> List.map(Layout.askButton(fit));
        let tabs = List.range(0, 5) |> List.map(Layout.tab(fit, 5));
        let slots = List.range(0, Saves.perPage()) |> List.flatMap(i -> Layout.slot(fit, i) :: Layout.remove(fit, i) :: Nil);
        let rows = List.range(0, List.length(WorldSettings.settings())) |> List.flatMap(i ->
            Layout.settingRow(fit, i) :: (Layout.sides() |> List.map(Layout.settingSide(fit, i))));
        let choices = List.range(0, 3) |> List.map(i -> Layout.choice(fit, i, 3));
        let menu = List.range(0, List.length(WorldMenu.menuItems())) |> List.map(Rail.menuItem(fit));
        List.flatten(buttons :: more :: titles :: asks :: tabs :: slots :: rows :: choices :: menu :: (Layout.back(fit) :: Nil) :: Nil)

    def menuRect(fit: Layout.Fit, item: World.Button): { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } } =
        let all = WorldMenu.menuItems();
        let i = all |> List.zipWithIndex |> List.find(match (_, b) -> b == item) |> Option.map(fst) |> Option.getWithDefault(0);
        Rail.menuItem(fit, i)

    /// しおりの選びの item（セーブかロード）の矩形。
    def saveLoadRect(fit: Layout.Fit, item: World.Button): { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } } =
        let all = WorldMenu.saveLoadItems();
        let i = all |> List.zipWithIndex |> List.find(match (_, b) -> b == item) |> Option.map(fst) |> Option.getWithDefault(0);
        Rail.saveLoadItem(fit, i, List.length(all))

    /// 読んでいる所から、しおり → セーブと押してセーブの画面を開く。
    def openSaveBySaveLoad(res: Res.Res, design: { x = Float64, y = Float64 }, w: World.World): World.World =
        let fit = portrait(res, design);
        let picking = tapOn(res, design, center(buttonRect(fit, World.Button.SaveLoad)), w);
        press(res, design, center(saveLoadRect(fit, World.Button.Save)), picking)

    def isMenuOpen(w: World.World): Bool = match w#panel {
        case World.Panel.Menu(_) => true
        case _                   => false
    }

    /// 右上の … の押せる正方形の真ん中。
    def moreCenter(res: Res.Res, design: { x = Float64, y = Float64 }): { x = Float64, y = Float64 } =
        center(Rail.moreButton(portrait(res, design))#hit)

    @Test
    def testMoreOpensMenuAndSettingsItemOpensSettings(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面の右上の … でメニューが開き、メニューの「設定」で設定の画面が開く。
        let res = TestKit.res();
        let fit = portrait(res, tall());
        let opened = tapOn(res, tall(), moreCenter(res, tall()), begun(res));
        let setting = press(res, tall(), center(menuRect(fit, World.Button.Settings)), opened);
        Assert.assertEq(expected = (true, true), (isMenuOpen(opened), isSettingsOpen(setting)))

    @Test
    def testMoreToTitleItemAsksFirst(): Unit \ {Assert, Fs.FileRead} =
        // … のメニューの「タイトルへ」はメニューを閉じて、タイトルへ戻るかを確認のウィンドウで尋ねる（すぐには戻らない）。
        let res = TestKit.res();
        let fit = portrait(res, tall());
        let opened = tapOn(res, tall(), moreCenter(res, tall()), begun(res));
        let asking = press(res, tall(), center(menuRect(fit, World.Button.ToTitle)), opened);
        Assert.assertEq(expected = ("Closed", Some(World.Ask.ToTitle), "Reading"), (World.panelName(asking), World.askOf(asking), World.sceneName(asking)))

    @Test
    def testTapOutsideMenuClosesIt(): Unit \ {Assert, Fs.FileRead} =
        // … のメニューの外（頁の左下の方）を押すとメニューが閉じる。
        let res = TestKit.res();
        let opened = tapOn(res, tall(), moreCenter(res, tall()), begun(res));
        Assert.assertTrue(press(res, tall(), { x = 120.0, y = 700.0 }, opened)#panel == World.Panel.Closed)

    @Test
    def testAutoIconStartsAuto(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面の右の列のオートを短く押して離すとオートになる。
        let res = TestKit.res();
        let w = tapOn(res, tall(), center(buttonRect(portrait(res, tall()), World.Button.Auto)), begun(res));
        Assert.assertEq(expected = World.Playback.Auto, World.playbackOf(w))

    /// 押せる物の短い辺が、画面の幅 width CSS px の端末で何 CSS px になるかの最小。
    def smallestCss(fit: Layout.Fit, width: Float64): Float64 =
        let k = width / Layout.width(fit);
        touchTargets(fit) |> List.map(r -> Float64.min(r#size#x, r#size#y) * k) |> List.minimum |> Option.getWithDefault(0.0)

    // ── 並べ方の組 ──

    @Test
    def testPortraitViewportSelectsPortraitFit(): Unit \ {Assert, Fs.FileRead} =
        // 縦の design なら区分に関わらず縦の並べ方。
        let res = TestKit.res();
        Assert.assertTrue(Layout.isPortrait(Layout.fitOf(Display.SizeClass.Large, Display.Orientation.Portrait, tall(), res#smallScreen, res#portrait)))

    @Test
    def testLandscapeScreenNeverSelectsPortraitFit(): Unit \ {Assert, Fs.FileRead} =
        // 向きが Portrait でも画面が横長なら横の並べ方へ落とす。
        let res = TestKit.res();
        Assert.assertFalse(Layout.isPortrait(Layout.fitOf(Display.SizeClass.Small, Display.Orientation.Portrait, { x = 960.0, y = 540.0 }, res#smallScreen, res#portrait)))

    // ── 押せる大きさ ──

    @Test
    def testTouchTargetsAreAtLeast44CssPxOnNarrowPhone(): Unit \ {Assert, Fs.FileRead} =
        // 360 CSS px 幅の縦の画面（太い方・高い方とも）で、押せる物はどれも 44 CSS px 以上。
        let res = TestKit.res();
        Assert.assertTrue(smallestCss(portrait(res, short()), 360.0) >= 43.99 and smallestCss(portrait(res, tall()), 360.0) >= 43.99)

    @Test
    def testTouchTargetsStayInsideTheScreen(): Unit \ {Assert, Fs.FileRead} =
        // 太い縦の画面でも、押せる物は画面の中に収まる。
        let res = TestKit.res();
        let fit = portrait(res, short());
        Assert.assertTrue(touchTargets(fit) |> List.forAll(r ->
            r#position#x >= 0.0 and r#position#y >= 0.0 and r#position#x + r#size#x <= Layout.width(fit) and r#position#y + r#size#y <= Layout.height(fit)))

    // ── 当たり ──

    /// 設定の行 i で、最大にしたつまみ（選んだ時の半径 8）の矩形と、右に寄せた一番長い値の字「ノーウェイト」（全角 1 字 = 字の大きさ 1 つ分）の矩形。
    def knobAndLongestValue(fit: Layout.Fit, i: Int32): (Rect2.Rect2, Rect2.Rect2) =
        let bar = Layout.settingBar(fit, i);
        let row = Layout.settingRow(fit, i);
        let text = Layout.settingText(fit);
        let width = Int32.toFloat64(String.length("ノーウェイト")) * text#value;
        let knob = { position = { x = bar#position#x + bar#size#x - 8.0, y = bar#position#y + bar#size#y / 2.0 - 8.0 }, size = { x = 16.0, y = 16.0 } };
        let value = { position = { x = row#position#x + row#size#x - width, y = row#position#y + text#valueTop }, size = { x = width, y = text#value } };
        (knob, value)

    def sliderRow(i: Int32, setting: World.Setting): Option[Int32] = match setting {
        case World.Setting.Slider(_) => Some(i)
        case _                       => None
    }

    def overlaps(a: Rect2.Rect2, b: Rect2.Rect2): Bool =
        a#position#x < b#position#x + b#size#x and b#position#x < a#position#x + a#size#x and
        a#position#y < b#position#y + b#size#y and b#position#y < a#position#y + a#size#y

    @Test
    def testSliderKnobNeverTouchesTheLongestValueText(): Unit \ {Assert, Fs.FileRead} =
        // 横・横持ちのスマホ・縦（細長い・太い）のどれでも、どのスライダーの行でも、最大にしたつまみと一番長い値の字が重ならない。
        let res = TestKit.res();
        let fits = Layout.Fit.Regular :: Layout.fitOf(Display.SizeClass.Small, Display.Orientation.Landscape, Layout.size(Layout.Fit.Regular), res#smallScreen, res#portrait)
                   :: portrait(res, tall()) :: portrait(res, short()) :: Nil;
        let sliders = WorldSettings.settings() |> List.zipWithIndex |> List.filterMap(match (i, setting) -> sliderRow(i, setting));
        let touching = fits |> List.flatMap(fit -> sliders |> List.map(knobAndLongestValue(fit)))
                            |> List.count(match (knob, value) -> overlaps(knob, value));
        Assert.assertEq(expected = 0, touching)

    @Test
    def testPortraitLogButtonOpensTheLog(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面の右の列の「ログ」の真ん中を押して離すとバックログが開く。
        let res = TestKit.res();
        let w = tapOn(res, tall(), center(buttonRect(portrait(res, tall()), World.Button.Log)), begun(res));
        Assert.assertTrue(isLogOpen(w))

    @Test
    def testPortraitTitleSettingsItemOpensSettings(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面のタイトルの「設定」の真ん中を押すと設定が開く。
        let res = TestKit.res();
        let w = press(res, short(), center(titleRect(portrait(res, short()), World.TitleItem.Settings)), w0(res));
        Assert.assertTrue(isSettingsOpen(w))

    @Test
    def testPortraitChoiceIsPickedAtItsCenter(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面の頁の下の選択肢の真ん中を押すと、その選択肢を選んで選択肢が消える。
        let res = TestKit.res();
        let choosing = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let count = TestKit.choiceCount(choosing);
        let w = press(res, tall(), center(Layout.choice(portrait(res, tall()), count - 1, count)), choosing);
        Assert.assertFalse(World.isChoosing(w))

    @Test
    def testPortraitAskNoButtonClosesTheAsk(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面の確認のウィンドウの「いいえ」の真ん中を押すとウィンドウが閉じる。
        let res = TestKit.res();
        let asking = TestKit.quiet(() -> World.askFor(World.Ask.Quit, w0(res)));
        let w = press(res, tall(), center(Layout.askButton(portrait(res, tall()), Layout.Side.Right)), asking);
        Assert.assertTrue(Option.isEmpty(w#ask))

    @Test
    def testPortraitSaveButtonOpensSaveAndBackCloses(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面のしおり → [セーブ｜ロード] の「セーブ」でセーブの画面が開き、「戻る」で閉じる。
        let res = TestKit.res();
        let fit = portrait(res, tall());
        let opened = openSaveBySaveLoad(res, tall(), begun(res));
        let closed = press(res, tall(), center(Layout.back(fit)), opened);
        Assert.assertEq(expected = (0, true), (slotCursorOf(opened), closed#panel == World.Panel.Closed))

    @Test
    def testPortraitDownKeyMovesOneSlot(): Unit \ {Assert, Fs.FileRead} =
        // 縦の画面のセーブの枠は 1 列なので、下のキーで 1 枠動く。
        let res = TestKit.res();
        let opened = openSaveBySaveLoad(res, tall(), begun(res));
        let down = KeysDoc.rec(res#keys)#next |> List.head |> Option.getWithDefault(Key.Down);
        Assert.assertEq(expected = 1, slotCursorOf(tap(res, tall(), down, opened)))

    @Test
    def testPortraitCreditsRunLongerThanLandscape(): Unit \ {Assert, Fs.FileRead} =
        // クレジットは画面の高さ分も流れるので、縦の画面は横より長く流れてから終わる。
        let res = TestKit.res();
        let started = World.toCredits(res, w0(res));
        let length = World.creditsLength(res);
        let at = { realNow = Clock.after((length + 600.0) / KindDoc.rec(res#kind)#creditsSpeed, started#realNow) | started };
        Assert.assertEq(expected = (true, false), (World.creditsOver(res, 540.0, at), World.creditsOver(res, 1169.0, at)))

    // ── 縦の頁 ──

    def block(text: String, height: Float64, isCurrent: Bool): View.Block =
        { line = { speaker = "", text = text, rubies = Nil, source = text }, visible = String.length(text), isCurrent = isCurrent, height = height }

    @Test
    def testKeepLatestDropsOldestWholeLines(): Unit \ Assert =
        // 頁に入り切らない時は、古い行から行ごと落として新しい 2 行を残す（100 + 段落の空き 26 + 100 = 226 ≤ 230）。
        let kept = View.keepLatest(230.0, block("a", 100.0, false) :: block("b", 100.0, false) :: block("c", 100.0, true) :: Nil);
        Assert.assertEq(expected = "b" :: "c" :: Nil, kept |> List.map(b -> b#line#text))

    @Test
    def testKeepLatestAlwaysKeepsTheCurrentLine(): Unit \ Assert =
        // 今の行だけで頁の高さを超えても、今の行は残る。
        let kept = View.keepLatest(300.0, block("a", 50.0, false) :: block("now", 500.0, true) :: Nil);
        Assert.assertEq(expected = "now" :: Nil, kept |> List.map(b -> b#line#text))

    @Test
    def testPageEndsAbovePageBottomAndChoices(): Unit \ {Assert, Fs.FileRead} =
        // 頁の下端は、選択肢が無ければ画面の下から pageBottom より上、選択肢があれば 1 つ目の選択肢の上（太い縦の画面でも）。
        let res = TestKit.res();
        let fit = portrait(res, short());
        let bottom = r -> r#position#y + r#size#y;
        let limit = Layout.height(fit) - PortraitDoc.rec(res#portrait)#pageBottom;
        Assert.assertTrue(bottom(Layout.page(fit, 0)) <= limit and bottom(Layout.page(fit, 3)) <= Layout.choice(fit, 0, 3)#position#y)
}
