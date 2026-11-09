// 小さい画面（スマホ）の並べ方の当たりをテストする: Small の時は大きくしたボタンの真ん中で押せ、Large の時は今の並べ方のまま。
// 当たりの矩形は View が描く所と同じ Layout の関数から引く（座標の数を写さない）。遊びの結果は端末の sizeClass で変わらない。
mod TestSmallScreen {

    use fge::{App, Display}
    use TestKit.{begun, settle, w0}

    def small(res: Res.Res): Layout.Fit = Layout.fitOf(Display.SizeClass.Small, Display.Orientation.Landscape, Layout.size(Layout.Fit.Regular), res#smallScreen, res#portrait)

    def center(r: { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } }): { x = Float64, y = Float64 } =
        { x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 }

    /// 端末の sizeClass の画面で p を押した 1 フレーム。
    def clickAt(sizeClass: Display.SizeClass, p: { x = Float64, y = Float64 }): App.Frame =
        { mouseClicked = true, mouseDown = true, cursor = p, sizeClass = sizeClass | App.emptyFrame() }

    def press(res: Res.Res, sizeClass: Display.SizeClass, p: { x = Float64, y = Float64 }, w: World.World): World.World =
        Controls.interact(clickAt(sizeClass, p), res, w)

    /// 下の帯の button の矩形（fit の並べ方）。
    def buttonRect(fit: Layout.Fit, button: World.Button): { position = { x = Float64, y = Float64 }, size = { x = Float64, y = Float64 } } =
        Layout.button(fit, WorldMenu.buttonIndexOf(fit, button) |> Option.getWithDefault(0), List.length(WorldMenu.buttonsOf(fit)))

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

    @Test
    def testSmallLogButtonOpensTheLogAtItsCenter(): Unit \ {Assert, Fs.FileRead} =
        // Small: 大きくした「ログ」のボタンの真ん中を押すとバックログが開く。
        let res = TestKit.res();
        let w = press(res, Display.SizeClass.Small, center(buttonRect(small(res), World.Button.Log)), begun(res));
        Assert.assertTrue(isLogOpen(w))

    @Test
    def testLargeKeepsTheRegularButtonStrip(): Unit \ {Assert, Fs.FileRead} =
        // Large: 今の並べ方の「ログ」のボタンの真ん中を押すとバックログが開く。
        let res = TestKit.res();
        let w = press(res, Display.SizeClass.Large, center(buttonRect(Layout.Fit.Regular, World.Button.Log)), begun(res));
        Assert.assertTrue(isLogOpen(w))

    @Test
    def testLargeIgnoresTheSmallButtonCenter(): Unit \ {Assert, Fs.FileRead} =
        // Large: Small のボタンの真ん中（今の帯より上）を押してもバックログは開かない（Small の並べ方は Large に出ない）。
        let res = TestKit.res();
        let w = press(res, Display.SizeClass.Large, center(buttonRect(small(res), World.Button.Log)), begun(res));
        Assert.assertFalse(isLogOpen(w))

    @Test
    def testSmallTitleSettingsItemOpensSettings(): Unit \ {Assert, Fs.FileRead} =
        // Small: タイトル画面の大きくした「設定」の真ん中を押すと設定が開く。
        let res = TestKit.res();
        let w = press(res, Display.SizeClass.Small, center(titleRect(small(res), World.TitleItem.Settings)), w0(res));
        Assert.assertTrue(isSettingsOpen(w))

    @Test
    def testLargeTitleSettingsItemOpensSettings(): Unit \ {Assert, Fs.FileRead} =
        // Large: タイトル画面の今の「設定」の真ん中を押すと設定が開く。
        let res = TestKit.res();
        let w = press(res, Display.SizeClass.Large, center(titleRect(Layout.Fit.Regular, World.TitleItem.Settings)), w0(res));
        Assert.assertTrue(isSettingsOpen(w))

    @Test
    def testSmallChoiceIsPickedAtItsCenter(): Unit \ {Assert, Fs.FileRead} =
        // Small: 大きくした選択肢の真ん中を押すと、その選択肢を選んで選択肢が消える。
        let res = TestKit.res();
        let choosing = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let count = TestKit.choiceCount(choosing);
        let w = press(res, Display.SizeClass.Small, center(Layout.choice(small(res), count - 1, count)), choosing);
        Assert.assertFalse(World.isChoosing(w))

    @Test
    def testSmallAskNoButtonClosesTheAsk(): Unit \ {Assert, Fs.FileRead} =
        // Small: 確認のウィンドウの大きくした「いいえ」の真ん中を押すとウィンドウが閉じる。
        let res = TestKit.res();
        let asking = TestKit.quiet(() -> World.askFor(World.Ask.Quit, w0(res)));
        let w = press(res, Display.SizeClass.Small, center(Layout.askButton(small(res), Layout.Side.Right)), asking);
        Assert.assertTrue(Option.isEmpty(w#ask))

    @Test
    def testSmallBackButtonClosesSettings(): Unit \ {Assert, Fs.FileRead} =
        // Small: 画面の大きくした「戻る」の真ん中を押すと設定が閉じる。
        let res = TestKit.res();
        let opened = press(res, Display.SizeClass.Small, center(titleRect(small(res), World.TitleItem.Settings)), w0(res));
        let w = press(res, Display.SizeClass.Small, center(Layout.back(small(res))), opened);
        Assert.assertTrue(w#panel == World.Panel.Closed)

    /// 端末の sizeClass の画面で p を押して、動かさずに離す（本文はこの離した拍に送る）。
    def tapAt(res: Res.Res, sizeClass: Display.SizeClass, p: { x = Float64, y = Float64 }, w: World.World): World.World =
        Controls.interact({ cursor = p, sizeClass = sizeClass | App.emptyFrame() }, res, press(res, sizeClass, p, w))

    /// 画面の上の端（どちらの並べ方でもボタンも選択肢も無い所）を n 回タップして読み進める（選択肢では止まる）。タップのたびに待ちと文字送りを使い切る。
    def readByTaps(res: Res.Res, sizeClass: Display.SizeClass, n: Int32, w: World.World): World.World =
        if (n <= 0) w else readByTaps(res, sizeClass, n - 1, settle(res, tapAt(res, sizeClass, { x = 480.0, y = 20.0 }, w)))

    @Test
    def testReadingResultDoesNotDependOnSizeClass(): Unit \ {Assert, Fs.FileRead} =
        // 同じ押し方で読み進めた結果（場面・台本の位置・頁に積んだ行の数・バックログの行の数）は Small と Large で同じで、読み進んでもいる。
        let res = TestKit.res();
        let summary = (w: World.World) -> (E2e.fingerprint(res, w), List.length(World.pageOf(w)#lines), List.length(World.logOf(w)));
        let large = readByTaps(res, Display.SizeClass.Large, 16, begun(res));
        Assert.assertEq(expected = (summary(large), true),
                        (summary(readByTaps(res, Display.SizeClass.Small, 16, begun(res))), List.length(World.logOf(large)) > List.length(World.logOf(begun(res)))))
}
