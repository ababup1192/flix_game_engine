// 何を守るか（LogCapture を使うので engine_tools のテストに置く）: 純粋な関数の中から *Then の口で知らせた行が、本当に stderr へ出ること
// （`let _ = Log.warn(..)` は Flix が呼び出しごと消すので、出た文面まで確かめる）と、
// LogCapture.capture が知らせた行を出た順に集め、stderr へは出さないこと（出ればテストの実行器がこのテストを FAIL にする）。
mod TestLog {

    def decodeWithWarning(n: Int32): Int32 =
        if (n < 0) Log.fellBackThen("probe", "n=${n}", "0", "負の数です", 0) else n

    @Test
    def warnThenPrintsFromPureCode(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (7, "probe: 1 行" :: Nil), LogCapture.capture(() -> Log.warnThen("probe: 1 行", 7)))

    @Test
    def fellBackThenUsesTheFixedSentence(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0, "probe fail-open: n=-3 を0に替えました — 負の数です" :: Nil), LogCapture.capture(() -> decodeWithWarning(-3)))

    @Test
    def warnAllThenPrintsEveryLineInOrderAndNothingWhenEmpty(): Unit \ {Assert, IO} =
        let (_, lines) = LogCapture.capture(() -> Log.warnAllThen("probe-a" :: "probe-b" :: Nil, ()));
        let (_, quiet) = LogCapture.capture(() -> Log.warnAllThen(Nil, 1));
        Assert.assertEq(expected = ("probe-a" :: "probe-b" :: Nil, Nil), (lines, quiet))

    @Test
    def captureOfQuietCodeKeepsTheValueAndCollectsNothing(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (5, Nil), LogCapture.capture(() -> decodeWithWarning(5)))
}
