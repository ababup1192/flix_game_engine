// TestCursorLook — 止めた画面の出入りの見た目と、動き出した拍に withCursor・withMouseCapture の宣言を当て直すかを具体値で固定する。

mod TestCursorLook {

    // 止めると、バッジを出し十字を見せ、マウスのキャプチャを放す（withCursor で矢印を隠している・キャプチャしているゲームでも囲える）。
    @Test
    def testHaltLookShowsCrosshair(): Unit \ Assert =
        Assert.assertEq(expected = App.CursorLook.HaltLook.HaltLook(App.CursorLook.Badge.Shown, App.CursorLook.Look.Look(GameEngine.Cursor.Crosshair, App.CursorLook.Visibility.Show), App.CursorLook.Capture.Release),
                        App.CursorLook.haltEnterLook())

    // 抜けるときは形だけ戻し、見せるか隠すか・キャプチャするかは触らない（動き出した拍に宣言を当て直す）。
    @Test
    def testLeaveHaltLookLeavesVisibilityToApp(): Unit \ Assert =
        Assert.assertEq(expected = App.CursorLook.HaltLook.HaltLook(App.CursorLook.Badge.Hidden, App.CursorLook.Look.Look(GameEngine.Cursor.Default, App.CursorLook.Visibility.LeaveToApp), App.CursorLook.Capture.LeaveToApp),
                        App.CursorLook.haltLeaveLook())

    // 止めた画面を抜けた拍（Stale）には、withCursor の「隠す」をもう一度当てる。
    @Test
    def testCursorChangeAfterHaltHidesAgain(): Unit \ Assert =
        Assert.assertEq(expected = Some(App.CursorLook.Look.Look(GameEngine.Cursor.Default, App.CursorLook.Visibility.Hide)),
                        App.CursorLook.cursorChange(hiddenArrow(), App.CursorLook.State.Stale))

    // 前に当てた宣言と同じなら、当て直さない。
    @Test
    def testCursorChangeSkipsSameSpec(): Unit \ Assert =
        Assert.assertEq(expected = None, App.CursorLook.cursorChange(hiddenArrow(), App.CursorLook.State.Applied(hiddenArrow())))

    // キャプチャの宣言: まだ当てていない・止めた画面が放した（None）なら当て、同じ値なら当てず、変わった拍だけ当てる。
    @Test
    def testCaptureChangeAppliesOnlyWhenChanged(): Unit \ Assert =
        Assert.assertEq(expected = (Some(true), None, Some(false)),
                        (App.CursorLook.captureChange(true, None),
                         App.CursorLook.captureChange(true, Some(true)),
                         App.CursorLook.captureChange(false, Some(true))))

    def hiddenArrow(): App.CursorSpec = { icon = GameEngine.Cursor.Default, visible = false }
}
