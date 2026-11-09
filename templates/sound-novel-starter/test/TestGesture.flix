// 読む画面の 1 回の押しの分け方（Gesture）と、台詞を送るのがタップだけであることをテストする。
// 押しは実機と同じ Controls.interact に、押した・押したまま動かした・離したのフレームを順に渡して作る。
// 動いた量と秒は novel.kind.json の数から導く（Doc の値を変えてもテストは壊れない）。
mod TestGesture {

    use fge::{App, Clock}
    use fge::GameEngine.Key
    use TestKit.{begun, quiet}

    def kind(res: Res.Res): KindDoc.Rec = KindDoc.rec(res#kind)

    /// 本文の上の、どのボタンにも当たらない所（横の画面）。
    def spot(): { x = Float64, y = Float64 } = { x = 480.0, y = 20.0 }

    def shifted(dx: Float64, dy: Float64): { x = Float64, y = Float64 } = { x = spot()#x + dx, y = spot()#y + dy }

    /// at 秒に p を押したフレーム。
    def down(at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        { mouseClicked = true, mouseDown = true, cursor = p, realNow = Clock.after(at, Clock.zero()) | App.emptyFrame() }

    /// at 秒に押したまま p へ動かしたフレーム。
    def held(at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        { mouseDown = true, mouseMoved = true, cursor = p, realNow = Clock.after(at, Clock.zero()) | App.emptyFrame() }

    /// at 秒に p で離したフレーム。
    def up(at: Float64, p: { x = Float64, y = Float64 }): App.Frame =
        { cursor = p, realNow = Clock.after(at, Clock.zero()) | App.emptyFrame() }

    /// フレームを古い順に Controls.interact へ渡す。
    def play(res: Res.Res, frames: List[App.Frame], w: World.World): World.World =
        List.foldLeft((acc, frame) -> Controls.interact(frame, res, acc), w, frames)

    /// 押しの種類の名前（Kind は記録を持つので比べられる字へ写す）。
    def nameOf(kind: Option[Gesture.Kind]): String = match kind {
        case Some(Gesture.Kind.Tap(p))    => "Tap(${p#x},${p#y})"
        case Some(Gesture.Kind.Swipe(d))  => "Swipe(${d})"
        case Some(Gesture.Kind.LongPress) => "LongPress"
        case Some(Gesture.Kind.Drag)      => "Drag"
        case None                         => "None"
    }

    /// Gesture.step にフレームを古い順に渡し、最後のフレームで決まった種類の名前。
    def classified(res: Res.Res, frames: List[App.Frame]): String =
        let limits = KindDoc.gestureLimits(res#kind);
        frames |> List.foldLeft((acc, frame) -> Gesture.step(limits, frame, snd(acc)), (None, Gesture.idle())) |> fst |> nameOf

    // ══ 分け方 ══

    @Test
    def testGestureKindsOnRelease(): Unit \ {Assert, Fs.FileRead} =
        // 動かさずにすぐ離す = 押した所のタップ（離す所が slop 内でずれても押した所）、動かさずに長押しの秒まで置く = 長押し、
        // swipeMin を払いの秒の内に左へ = 左の払い、slop を越えてゆっくり動かす = ドラッグ。
        let res = TestKit.res();
        let k = kind(res);
        let tap = classified(res, down(0.0, spot()) :: up(0.1, shifted(k#tapSlop / 2.0, 0.0)) :: Nil);
        let long = classified(res, down(0.0, spot()) :: held(k#longPressSeconds, spot()) :: up(k#longPressSeconds, spot()) :: Nil);
        let swipe = classified(res, down(0.0, spot()) :: held(k#swipeSeconds / 2.0, shifted(0.0 - k#swipeMin, 0.0)) :: up(k#swipeSeconds / 2.0, shifted(0.0 - k#swipeMin, 0.0)) :: Nil);
        let drag = classified(res, down(0.0, spot()) :: held(k#swipeSeconds * 2.0, shifted(k#tapSlop * 2.0, 0.0)) :: up(k#swipeSeconds * 2.0, shifted(k#tapSlop * 2.0, 0.0)) :: Nil);
        Assert.assertEq(expected = ("Tap(480.0,20.0)", "LongPress", "Swipe(Left)", "Drag"), (tap, long, swipe, drag))

    @Test
    def testReleaseWithoutPressIsNothing(): Unit \ {Assert, Fs.FileRead} =
        // 押し始めを見ていない離し（他の画面で押した指を、ここで離した）は、どの種類にもならない。
        let res = TestKit.res();
        Assert.assertEq(expected = "None", classified(res, up(0.0, spot()) :: Nil))

    // ══ 読む画面の送り ══

    @Test
    def testTapAdvancesOnRelease(): Unit \ {Assert, Fs.FileRead} =
        // 押して動かさずに離すと 1 行送る（クリックと、ブラウザ版の指のタップ）。押しただけの拍では送らない。
        let res = TestKit.res();
        let start = begun(res);
        let pressed = play(res, down(0.0, spot()) :: Nil, start);
        let released = play(res, up(0.1, spot()) :: Nil, pressed);
        Assert.assertEq(expected = (World.talkLineOf(start), World.talkLineOf(TestKit.advance(res, start))),
                        (World.talkLineOf(pressed), World.talkLineOf(released)))

    @Test
    def testHeldMovingFingerNeverAdvances(): Unit \ {Assert, Fs.FileRead} =
        // 指を置いたまま何度動かしても（行ったり来たりして押した所へ戻っても）送らない。
        let res = TestKit.res();
        let start = begun(res);
        let k = kind(res);
        let w = play(res, down(0.0, spot()) :: held(0.2, shifted(k#tapSlop * 2.0, 0.0)) :: held(0.4, shifted(0.0, k#tapSlop * 4.0))
                          :: held(0.6, spot()) :: held(0.8, shifted(0.0 - k#tapSlop * 3.0, 0.0)) :: Nil, start);
        Assert.assertEq(expected = World.talkLineOf(start), World.talkLineOf(w))

    @Test
    def testReleasingADragDoesNotAdvanceButTheNextTapDoes(): Unit \ {Assert, Fs.FileRead} =
        // 押したまま動かして離しても送らない。一度離して押し直したタップで 1 行送る。
        let res = TestKit.res();
        let start = begun(res);
        let k = kind(res);
        let dragged = play(res, down(0.0, spot()) :: held(1.0, shifted(k#tapSlop * 2.0, 0.0)) :: up(1.2, shifted(k#tapSlop * 2.0, 0.0)) :: Nil, start);
        let tapped = play(res, down(2.0, spot()) :: up(2.1, spot()) :: Nil, dragged);
        Assert.assertEq(expected = (World.talkLineOf(start), World.talkLineOf(TestKit.advance(res, start))),
                        (World.talkLineOf(dragged), World.talkLineOf(tapped)))

    @Test
    def testSwipeDoesNotAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 払い（swipeMin を払いの秒の内に上へ）は離しても送らない。
        let res = TestKit.res();
        let start = begun(res);
        let k = kind(res);
        let far = shifted(0.0, k#swipeMin * 2.0);
        let w = play(res, down(0.0, far) :: held(k#swipeSeconds / 2.0, spot()) :: up(k#swipeSeconds / 2.0, spot()) :: Nil, start);
        Assert.assertEq(expected = World.talkLineOf(start), World.talkLineOf(w))

    @Test
    def testLongPressDoesNotAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 動かさずに長押しの秒まで置いてから離しても送らない。
        let res = TestKit.res();
        let start = begun(res);
        let k = kind(res);
        let w = play(res, down(0.0, spot()) :: held(k#longPressSeconds, spot()) :: up(k#longPressSeconds + 0.1, spot()) :: Nil, start);
        Assert.assertEq(expected = World.talkLineOf(start), World.talkLineOf(w))

    @Test
    def testConfirmKeyAdvancesOnPress(): Unit \ {Assert, Fs.FileRead} =
        // キーの決定は押した拍に 1 行送る（押しの分け方を通らない）。
        let res = TestKit.res();
        let start = begun(res);
        let w = Controls.interact({ justPressed = Set#{Key.Enter}, down = Set#{Key.Enter} | App.emptyFrame() }, res, start);
        Assert.assertEq(expected = World.talkLineOf(TestKit.advance(res, start)), World.talkLineOf(w))

    @Test
    def testButtonPressIsNotAlsoATap(): Unit \ {Assert, Fs.FileRead} =
        // オートのボタンを押して離しても、オートが入るだけで、本文のタップとして台詞は進まない。
        let res = TestKit.res();
        let start = begun(res);
        let fit = Layout.Fit.Regular;
        let all = WorldMenu.buttonsOf(fit);
        let i = all |> List.zipWithIndex |> List.find(match (_, b) -> b == World.Button.Auto) |> Option.map(fst) |> Option.getWithDefault(0);
        let r = Layout.button(fit, i, List.length(all));
        let p = { x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 };
        let w = play(res, down(0.0, p) :: up(0.1, p) :: Nil, start);
        Assert.assertEq(expected = (World.Playback.Auto, World.talkLineOf(start)), (World.playbackOf(w), World.talkLineOf(w)))

    // ══ 他の画面は分け方に巻き込まない ══

    @Test
    def testSliderDragInSettingsChangesValueWithoutAdvancing(): Unit \ {Assert, Fs.FileRead} =
        // 読んでいる途中で設定を開き、文字の速さの帯を左端から右端へなぞって離すと、値は上限になり、台詞は進まず設定も開いたまま。
        let res = TestKit.res();
        let reading = begun(res);
        let opened = quiet(() -> WorldMenu.press(res, World.Button.Settings, reading));
        let bar = Layout.settingBar(Layout.Fit.Regular, 0);
        let y = bar#position#y + bar#size#y / 2.0;
        let w = play(res, down(0.0, { x = bar#position#x, y = y }) :: held(0.3, { x = bar#position#x + bar#size#x, y = y })
                          :: up(0.4, { x = bar#position#x + bar#size#x, y = y }) :: Nil, opened);
        Assert.assertEq(expected = (kind(res)#cpsSlider#max, World.talkLineOf(reading), World.panelName(opened)),
                        (Saves.configOf(w#saves)#cps, World.talkLineOf(w), World.panelName(w)))

    @Test
    def testClosingAPanelByClickDoesNotAdvanceOnRelease(): Unit \ {Assert, Fs.FileRead} =
        // 設定の戻るを押して閉じ、その指を読む画面で離しても、タップとして台詞は進まない。
        let res = TestKit.res();
        let reading = begun(res);
        let opened = quiet(() -> WorldMenu.press(res, World.Button.Settings, reading));
        let back = Layout.back(Layout.Fit.Regular);
        let p = { x = back#position#x + back#size#x / 2.0, y = back#position#y + back#size#y / 2.0 };
        let w = play(res, down(0.0, p) :: up(0.1, p) :: Nil, opened);
        Assert.assertEq(expected = ("Closed", World.talkLineOf(reading)), (World.panelName(w), World.talkLineOf(w)))
}
