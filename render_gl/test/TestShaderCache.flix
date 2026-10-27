// RenderShaderCache.computeEvictions が「どの鍵を追い出すか」を固定するテスト。
// 上限未満 / 上限超過 / pinned で守る / 全部 pinned / 同じ program を持つ鍵が 2 つ、の 5 通り。

mod TestShaderCache {

    /// 世代が古い順に a(10) < b(20) < c(30) の 3 本。program 番号は 1/2/3 で全部別。
    def threeEntries(): List[(String, Int32, Int64)] =
        ("a", 1, 10i64) :: ("b", 2, 20i64) :: ("c", 3, 30i64) :: Nil

    /// 3 本で cap=3 なら 1 本も追い出さない。
    @Test
    def testUnderCapEvictsNothing(): Unit \ Assert =
        Assert.assertEq(expected = (Nil: List[String]),
            RenderShaderCache.computeEvictions(
                { entries = threeEntries(), pinned = Set.empty(), cap = 3 }))

    /// 3 本で cap=1 なら、古い方から 2 本 (a, b) をこの順で追い出す。
    @Test
    def testOverCapEvictsOldestFirst(): Unit \ Assert =
        Assert.assertEq(expected = "a" :: "b" :: Nil,
            RenderShaderCache.computeEvictions(
                { entries = threeEntries(), pinned = Set.empty(), cap = 1 }))

    /// 一番古い a の program(1) を pin すると、代わりに次に古い b と c が出る。
    @Test
    def testPinnedProgramSurvivesOverCap(): Unit \ Assert =
        Assert.assertEq(expected = "b" :: "c" :: Nil,
            RenderShaderCache.computeEvictions(
                { entries = threeEntries(), pinned = Set.singleton(1), cap = 1 }))

    /// 全部 pin されていれば cap=0 でも 1 本も出ない (上限を超えたままでよい)。
    @Test
    def testAllPinnedEvictsNothing(): Unit \ Assert =
        Assert.assertEq(expected = (Nil: List[String]),
            RenderShaderCache.computeEvictions(
                { entries = threeEntries(),
                  pinned = Set.insert(3, Set.insert(2, Set.singleton(1))), cap = 0 }))

    /// program 7 を共有する鍵 a と b は、鍵として別々に選ばれる (2 本とも返る)。
    @Test
    def testSharedProgramYieldsSeparateKeys(): Unit \ Assert =
        Assert.assertEq(expected = "a" :: "b" :: Nil,
            RenderShaderCache.computeEvictions(
                { entries = ("a", 7, 10i64) :: ("b", 7, 20i64) :: ("c", 9, 30i64) :: Nil,
                  pinned = Set.empty(), cap = 1 }))


    /// 引退した 1・2・3 のうち、今のコマで使った 1 と、別の鍵が指す 2 は残し、3 だけ消す。
    @Test
    def testRetiredDeletesOnlyUnusedAndUnkeyed(): Unit \ Assert =
        Assert.assertEq(expected = (Set#{3}, Set#{1, 2}),
            RenderShaderCache.retiredToDelete(Set#{1, 2, 3}, Set#{1}, Set#{2}))
}
