// WebGPU の 1 コマの submit の回数の数え（FrameStats の行の終わりに出す「2 回以上のコマの数と一番多い回数」）を固定する。
// WhyNot: mod TestSubmitCounts にしない — 数える関数は WebGpuPaint の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderPaint.Internal.WebGpuPaint.TestSubmitCounts {
    use RenderPaint.Internal.WebGpuPaint.{noteFrameSubmits, takeSubmitCountsOf}

    /// frameCounters と同じ並びの 0 の入れ物。
    def freshCounters(): Array[Int32, Static] \ IO = Array#{0, 0, 0, 0, 0, 0} @ Static

    /// 1 コマずつ submit の回数を数えて読む（frames, twoOrMore, most）。
    def countsAfter(perFrame: List[Int32]): (Int32, Int32, Int32) \ IO =
        let counters = freshCounters();
        List.forEach(submits -> noteFrameSubmits(submits, counters), perFrame);
        let counts = takeSubmitCountsOf(counters);
        (counts#frames, counts#twoOrMore, counts#most)

    /// 1 回ずつの 3 コマは、コマの数 3・2 回以上 0・一番多い回数 1。
    @Test
    def testFramesCountEveryFrame(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (3, 0, 1), countsAfter(1 :: 1 :: 1 :: Nil))

    /// 2 回以上のコマだけを数える（1・2・3・1 回なら 2 コマ）。一番多い回数は後のコマが少なくても 3 のまま。
    @Test
    def testTwoOrMoreAndMostKeepMaximum(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (4, 2, 3), countsAfter(1 :: 2 :: 3 :: 1 :: Nil))

    /// 読むと 0 に戻り、次に読む時は読んだ後のコマだけを数える。
    @Test
    def testTakeResetsCounts(): Unit \ {Assert, IO} =
        let counters = freshCounters();
        noteFrameSubmits(3, counters);
        discard takeSubmitCountsOf(counters);
        noteFrameSubmits(1, counters);
        let counts = takeSubmitCountsOf(counters);
        Assert.assertEq(expected = (1, 0, 1), (counts#frames, counts#twoOrMore, counts#most))
}
