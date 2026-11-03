// Tests for AllocMeter

mod TestAllocMeter {

    /// 畳み込みの中で List.append を呼ぶ形。要素を 1 つ足すたびに acc を作り直すので
    /// 割り当てが N の二乗で増える。
    def appendInFold(n: Int32): Int32 =
        List.range(0, n)
            |> List.foldLeft((acc, x) -> List.append(acc, x :: Nil), (Nil: List[Int32]))
            |> List.length

    /// 割り当てバイト数を読める JVM である
    @Test
    def testThreadAllocatedMemoryIsEnabled(): Unit \ Assert =
        Assert.assertTrue(AllocMeter.isThreadAllocatedMemoryEnabled())

    /// 二乗の割り当ては N を 8 倍にすると 20 倍を超えて増える (線形なら 8 倍で止まる)
    @Test
    def testAppendInFoldAllocatesQuadratically(): Unit \ Assert =
        let small = AllocMeter.measureBytes(3, _ -> appendInFold(100));
        let large = AllocMeter.measureBytes(3, _ -> appendInFold(800));
        let ratio = Int64.toFloat64(large) / Int64.toFloat64(small);
        Assert.assertTrue(ratio > 20.0)

}
