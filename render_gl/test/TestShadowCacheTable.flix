// GL と WebGPU が共有する影の地図の控えの表（Render3d.ShadowCacheTable）の、引き方と残す数を固定する。
mod Render3d.TestShadowCacheTable {
    use Render3d.ShadowCacheTable

    /// 鍵 "k0".."k(n-1)" を世代 gen で 1 回ずつ引く（中身は鍵の名前）。
    def touchAll(t: ShadowCacheTable.Table[String], gen: Int64, ks: List[String]): Unit \ IO =
        List.forEach(k -> discard ShadowCacheTable.ensure(t, gen, k, () -> k), ks)

    def keyRange(lo: Int32, hi: Int32): List[String] = List.range(lo, hi) |> List.map(i -> "k${i}")

    /// 同じ鍵を 2 回引くと、2 回目は作らずに前の控えを返す。
    @Test
    def testSecondEnsureReusesEntry(): Unit \ {Assert, IO} =
        let t = ShadowCacheTable.fresh();
        discard ShadowCacheTable.ensure(t, 0i64, "a", () -> "first");
        Assert.assertEq(expected = ("first", false), ShadowCacheTable.ensure(t, 1i64, "a", () -> "second"))

    /// 下限（16）までは、使わなかったコマでも何も外さない。
    @Test
    def testKeepsUpToMinimum(): Unit \ {Assert, IO} =
        let t = ShadowCacheTable.fresh();
        touchAll(t, 0i64, keyRange(0, 16));
        discard ShadowCacheTable.endFrame(t);
        Assert.assertEq(expected = Nil, ShadowCacheTable.endFrame(t))

    /// 下限を超えた分は、最後に使った世代の古い物から外して返す。
    @Test
    def testDropsOldestOverMinimum(): Unit \ {Assert, IO} =
        let t = ShadowCacheTable.fresh();
        touchAll(t, 0i64, "old1" :: "old2" :: Nil);
        touchAll(t, 1i64, keyRange(0, 16));
        discard ShadowCacheTable.endFrame(t);
        Assert.assertEq(expected = "old1" :: "old2" :: Nil, Sort.sortStable(ShadowCacheTable.endFrame(t)))

    /// 引き直した控えは世代が新しくなり、古い順に外す時に外されない。
    @Test
    def testTouchedEntryIsKept(): Unit \ {Assert, IO} =
        let t = ShadowCacheTable.fresh();
        touchAll(t, 0i64, "old" :: "touched" :: Nil);
        touchAll(t, 1i64, keyRange(0, 15));
        touchAll(t, 2i64, "touched" :: Nil);
        discard ShadowCacheTable.endFrame(t);
        Assert.assertEq(expected = "old" :: Nil, ShadowCacheTable.endFrame(t))

    /// 使った数が下限を超えたコマは、使った数の 2 倍まで残す。
    @Test
    def testKeepsTwiceTheUsedCount(): Unit \ {Assert, IO} =
        let t = ShadowCacheTable.fresh();
        touchAll(t, 0i64, keyRange(0, 30));
        discard ShadowCacheTable.endFrame(t);
        touchAll(t, 1i64, keyRange(0, 10));
        discard ShadowCacheTable.endFrame(t);
        Assert.assertEq(expected = 20, ShadowCacheTable.sizeOf(t))

    /// 外した控えは表から消え、残る数は下限になる。
    @Test
    def testDroppedEntriesLeaveTable(): Unit \ {Assert, IO} =
        let t = ShadowCacheTable.fresh();
        touchAll(t, 0i64, keyRange(0, 20));
        discard ShadowCacheTable.endFrame(t);
        discard ShadowCacheTable.endFrame(t);
        Assert.assertEq(expected = 16, ShadowCacheTable.sizeOf(t))
}
