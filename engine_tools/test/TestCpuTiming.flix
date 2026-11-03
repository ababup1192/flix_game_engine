// TestCpuTiming — 測った時間の列のまとめ方（中央値・最小・最大）を具体値で固定する。

mod TestCpuTiming {

    /// 奇数個は並べた真ん中（10, 30, 20 → 20）。最小と最大も並べた端。
    @Test
    def testSummarizeOddCountTakesMiddle(): Unit \ Assert =
        let summary = CpuTiming.summarize(Nel.Nel(10.0, 30.0 :: 20.0 :: Nil));
        Assert.assertEq(expected = (20.0, 10.0, 30.0), (summary#median, summary#min, summary#max))

    /// 偶数個は真ん中の 2 つの平均（10, 20, 30, 100 → (20 + 30) / 2 = 25）。外れた 1 回（100）に引かれない。
    @Test
    def testSummarizeEvenCountAveragesMiddlePair(): Unit \ Assert =
        Assert.assertEq(expected = 25.0, CpuTiming.summarize(Nel.Nel(100.0, 10.0 :: 30.0 :: 20.0 :: Nil))#median)

    /// 温めの回は数えず、work は warmup + runs 回呼ばれ、最後の回の値が返る（2 + 3 = 5 回目の値は 5）。
    @Test
    def testMeasureSkipsWarmupAndReturnsLastValue(): Unit \ Assert + IO =
        let calls = Ref.fresh(Static, 0);
        let (summary, last) = CpuTiming.measure({ warmup = 2, runs = 3 }, () -> { Ref.put(Ref.get(calls) + 1, calls); Ref.get(calls) });
        Assert.assertEq(expected = (3, 5), (Vector.length(summary#samples), last))

    /// 測る回数が 0 以下でも 1 回は測る（中央値が無い結果を返さない）。
    @Test
    def testMeasureRunsAtLeastOnce(): Unit \ Assert + IO =
        Assert.assertEq(expected = 1, Vector.length(fst(CpuTiming.measure({ warmup = 0, runs = 0 }, () -> Ref.fresh(Static, 0)))#samples))
}
