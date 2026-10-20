// TestCursorLook — 止めた画面の出入りの見た目と、動き出した拍に withCursor の宣言を当て直すかを具体値で固定する。

mod TestCursorLook {

    // 止めると、バッジを出し十字を見せる（withCursor で矢印を隠しているゲームでも見える）。
    @Test
    def testHaltLookShowsCrosshair(): Unit \ Assert =
        Assert.assertEq(expected = App.CursorLook.HaltLook.HaltLook(App.CursorLook.Badge.Shown, App.CursorLook.Look.Look(GameEngine.Cursor.Crosshair, App.CursorLook.Visibility.Show)),
                        App.CursorLook.haltEnterLook())

    // 抜けるときは形だけ戻し、見せるか隠すかは触らない。
    @Test
    def testLeaveHaltLookLeavesVisibilityToApp(): Unit \ Assert =
        Assert.assertEq(expected = App.CursorLook.HaltLook.HaltLook(App.CursorLook.Badge.Hidden, App.CursorLook.Look.Look(GameEngine.Cursor.Default, App.CursorLook.Visibility.LeaveToApp)),
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

    def hiddenArrow(): App.CursorSpec = { icon = GameEngine.Cursor.Default, visible = false }
}
