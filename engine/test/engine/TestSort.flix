// TestSort — 安定な並べ替えの約束（並び順・安定・大きい入力）を固定する。
mod TestSort {

    def ascending(n: Int32): List[Int32] = List.range(0, n)

    def isSorted(xs: List[Int32]): Bool = match xs {
        case a :: b :: rest => a <= b and isSorted(b :: rest)
        case _              => true
    }

    @Test
    def testEmptyAndSingleStayAsTheyAre(): Unit \ Assert =
        Assert.assertEq(expected = (Nil: List[Int32]), Sort.sortStable(Nil))

    @Test
    def testSingleStays(): Unit \ Assert =
        Assert.assertEq(expected = 7 :: Nil, Sort.sortStable(7 :: Nil))

    @Test
    def testSortsShuffled(): Unit \ Assert =
        Assert.assertEq(expected = 1 :: 2 :: 3 :: 4 :: 5 :: Nil, Sort.sortStable(3 :: 1 :: 5 :: 2 :: 4 :: Nil))

    @Test
    def testAscendingInputStays(): Unit \ Assert =
        Assert.assertEq(expected = ascending(9), Sort.sortStable(ascending(9)))

    @Test
    def testDescendingInputIsReversed(): Unit \ Assert =
        Assert.assertEq(expected = ascending(9), Sort.sortStable(List.reverse(ascending(9))))

    @Test
    def testSortStableByKeepsArrivalOrderOfEqualKeys(): Unit \ Assert =
        let xs = ("b", 1) :: ("a", 2) :: ("b", 3) :: ("a", 4) :: ("b", 5) :: Nil;
        Assert.assertEq(expected = ("a", 2) :: ("a", 4) :: ("b", 1) :: ("b", 3) :: ("b", 5) :: Nil,
            Sort.sortStableBy(fst, xs))

    @Test
    def testAllSameKeyKeepsArrivalOrder(): Unit \ Assert =
        let xs = List.map(i -> (0, i), ascending(20));
        Assert.assertEq(expected = xs, Sort.sortStableBy(fst, xs))

    @Test
    def testSortStableWithUsesTheComparison(): Unit \ Assert =
        Assert.assertEq(expected = 3 :: 2 :: 1 :: Nil,
            Sort.sortStableWith((a, b) -> b <=> a, 2 :: 3 :: 1 :: Nil))

    @Test
    def testHundredThousandAscendingIsFastAndSorted(): Unit \ Assert =
        Assert.assertEq(expected = true, isSorted(Sort.sortStable(ascending(100000))))

    @Test
    def testHundredThousandSameKeyKeepsOrder(): Unit \ Assert =
        let xs = List.map(i -> (0, i), ascending(100000));
        Assert.assertEq(expected = true, Sort.sortStableBy(fst, xs) == xs)

    @Test
    def testHundredThousandDescendingIsSorted(): Unit \ Assert =
        Assert.assertEq(expected = true, isSorted(Sort.sortStable(List.reverse(ascending(100000)))))

}
