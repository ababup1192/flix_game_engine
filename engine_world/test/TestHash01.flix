// Hash01 のテスト。決定論・値域 [0,1)・チャンネル独立・ざっくり均等分布を固定する。

mod TestHash01 {

    /// 決定論：同じ (index, channel) は常に同じ値を返す（2回まわして一致）。
    @Test
    def testDeterministic(): Unit \ Assert =
        let sample = index -> Hash01.at(index, 3);
        Assert.assertEq(
            expected = List.map(sample, List.range(0, 20)),
            List.map(sample, List.range(0, 20)))

    /// 値域：500 サンプルすべてが [0, 1) に収まる。
    @Test
    def testInUnitRange(): Unit \ Assert =
        let allInRange = List.forAll(index -> {
            let value = Hash01.at(index, 1);
            value >= 0.0 and value < 1.0
        }, List.range(0, 500));
        Assert.assertEq(expected = true, allInRange)

    /// チャンネル独立：同じ index でもチャンネルが違えば別の値になる
    /// （1つの要素から複数の独立な乱数を引ける）。
    @Test
    def testChannelsDiffer(): Unit \ Assert =
        Assert.assertEq(expected = true, Hash01.at(5, 1) != Hash01.at(5, 2))

    /// ざっくり均等：500 サンプルのうち中点 0.5 未満はおよそ半分（150〜350 の緩い範囲）。
    /// 厳密な一様性ではなく、一方に極端に偏っていないことの確認。
    @Test
    def testRoughSpread(): Unit \ Assert =
        let below = List.count(index -> Hash01.at(index, 7) < 0.5, List.range(0, 500));
        Assert.assertEq(expected = true, below > 150 and below < 350)

    // ══════════════════════════════════════════════════════
    // indexOf / pickBy
    // ══════════════════════════════════════════════════════

    /// 1..7 個のどれでも、200 個の鍵の添字はすべて 0..n-1 に収まり、どの添字も 1 回は選ばれる。
    @Test
    def testIndexOfCoversEveryIndexInRange(): Unit \ Assert =
        let picksOf = n -> List.range(0, 200) |> List.map(index -> Hash01.indexOf({ index = index, channel = 0 }, n));
        Assert.assertEq(
            expected = List.range(1, 8) |> List.map(n -> List.range(0, n)),
            List.range(1, 8) |> List.map(n -> picksOf(n) |> List.toSet |> Set.toList))

    /// 0 個以下は 0。
    @Test
    def testIndexOfNonPositiveIsZero(): Unit \ Assert =
        Assert.assertEq(expected = (0, 0),
            (Hash01.indexOf({ index = 5, channel = 1 }, 0), Hash01.indexOf({ index = 5, channel = 1 }, -3)))

    /// pickBy は列の中の 1 つを返し（どの鍵でも）、空の列には None。
    @Test
    def testPickByReturnsMemberOrNone(): Unit \ Assert =
        let xs = List#{"a", "b", "c"};
        let picked = List.range(0, 100) |> List.map(index -> Hash01.pickBy({ index = index, channel = 2 }, xs));
        Assert.assertEq(expected = (true, None),
            (List.forAll(p -> Option.exists(x -> List.memberOf(x, xs), p), picked),
             Hash01.pickBy({ index = 0, channel = 0 }, (Nil: List[String]))))
}
