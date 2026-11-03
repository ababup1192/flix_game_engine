// TestMouseDelta — consumeMouseDelta が返す動いた量の決め方（GL を呼ばない純粋な部分）を具体値で固定する。

mod TestMouseDelta {

    // ふつうは前に読んだ位置 (10, 20) から今の位置 (13, 16) への差。
    @Test
    def testDeltaIsDifferenceFromBase(): Unit \ Assert =
        Assert.assertEq(expected = (3.0, -4.0),
                        LwjglInput.mouseDeltaInWindow({ rebase = false, focused = true }, (10.0, 20.0), (13.0, 16.0)))

    // キャプチャを切り替えた直後・フォーカスが戻った直後（rebase）と、フォーカスが無い間は 0（跳んだ量・ほかのアプリの上の動きで視点を回さない）。
    @Test
    def testDeltaIsZeroOnRebaseOrWithoutFocus(): Unit \ Assert =
        Assert.assertEq(expected = ((0.0, 0.0), (0.0, 0.0)),
                        (LwjglInput.mouseDeltaInWindow({ rebase = true, focused = true }, (10.0, 20.0), (500.0, 500.0)),
                         LwjglInput.mouseDeltaInWindow({ rebase = false, focused = false }, (10.0, 20.0), (500.0, 500.0))))
}
