// 水の決まり（Tide）。盤は高さの格子で書き、外は全部外海。行の数字は左から各マスの水面の高さ。
// ヤドカリ @ と巻き貝 * は水に関わらない高さ 3 の角に置く。
mod TestTide {

    use Fixtures.{board, rowOf}

    /// 外海 | 0 1 0 | 3 の 1 本の水路（上下は高さ 3 の堤なので、外海は左の縁からだけ入る）。
    def channel(): Board.Board =
        board(0 :: Nil, "3333" :: "0103" :: "3333" :: Nil, "@..." :: "...." :: "...*" :: Nil)

    // ══════════════════════════════════════════════════════
    // 抜け口の高さ
    // ══════════════════════════════════════════════════════

    /// 縁のマスはその高さ・奥のくぼみ (2,1) は手前の段 (1,1) の高さ 1 で抜ける・堤は 3。
    @Test
    def testDrainHeightIsTheLowestPassToTheSea(): Unit \ Assert =
        let b = channel();
        Assert.assertEq(expected = 0 :: 1 :: 1 :: 3 :: Nil, rowOf(1, Tide.drainHeights(Set.empty(), b), b))

    // ══════════════════════════════════════════════════════
    // 1 手ごとの水位
    // ══════════════════════════════════════════════════════

    /// 乾いた水路に潮位 2: 外海とつながる 3 マス（抜け口 0・1・1 < 2）は潮位 2 まで沈み、堤は乾いたまま。
    @Test
    def testCellsOpenToTheSeaFillToTheTide(): Unit \ Assert =
        let b = channel();
        Assert.assertEq(expected = 2 :: 2 :: 2 :: 3 :: Nil, rowOf(1, Tide.flow(Set.empty(), 2, Tide.dry(b), b), b))

    /// 潮位 2 → 1 → 0: 外のマスは潮と一緒に下がり、奥のくぼみには抜け口の高さ 1 まで水が残る。
    @Test
    def testPoolKeepsWaterUpToItsDrainAsTheTideFalls(): Unit \ Assert =
        let b = channel();
        let w2 = Tide.flow(Set.empty(), 2, Tide.dry(b), b);
        let w1 = Tide.flow(Set.empty(), 1, w2, b);
        let w0 = Tide.flow(Set.empty(), 0, w1, b);
        Assert.assertEq(expected = (2 :: 2 :: 2 :: 3 :: Nil, 1 :: 1 :: 1 :: 3 :: Nil, 0 :: 1 :: 1 :: 3 :: Nil),
            (rowOf(1, w2, b), rowOf(1, w1, b), rowOf(1, w0, b)))

    /// 潮位 3 で満たした後に 0 へ: くぼみの水は抜け口 1 より上があふれ、1 だけ残る。
    @Test
    def testWaterAboveTheDrainSpillsOut(): Unit \ Assert =
        let b = channel();
        let w3 = Tide.flow(Set.empty(), 3, Tide.dry(b), b);
        Assert.assertEq(expected = 0 :: 1 :: 1 :: 3 :: Nil, rowOf(1, Tide.flow(Set.empty(), 0, w3, b), b))

    /// 外海 | 0 o 0 0 | 3: 潮位 2 で満たしてから (1,1) に小石を置いて潮位 0 へ。
    /// 小石の奥は外へ抜けられず 2 のまま残る（せき止めた水は引き潮でも残る）。小石を退けて潮位 0 を当てると 0 まで抜ける。
    @Test
    def testDammedWaterStaysAndDrainsWhenThePebbleMoves(): Unit \ Assert =
        let b = board(0 :: Nil, "33333" :: "00003" :: "33333" :: Nil, "@...." :: "....." :: "....*" :: Nil);
        let filled = Tide.flow(Set.empty(), 2, Tide.dry(b), b);
        let dammed = Tide.flow(Set#{(1, 1)}, 0, filled, b);
        let drained = Tide.flow(Set.empty(), 0, dammed, b);
        Assert.assertEq(expected = (0 :: 0 :: 2 :: 2 :: 3 :: Nil, 0 :: 0 :: 0 :: 0 :: 3 :: Nil),
            (rowOf(1, dammed, b), rowOf(1, drained, b)))

    /// 小石のマス (2,1) は沈んだ水路の中でも乾いている（w = h）。小石の奥 (3,1) にも水は届かない。
    @Test
    def testPebbleCellStaysDryAndBlocksTheWater(): Unit \ Assert =
        let b = board(0 :: Nil, "33333" :: "00003" :: "33333" :: Nil, "@...." :: "....." :: "....*" :: Nil);
        Assert.assertEq(expected = 2 :: 2 :: 0 :: 0 :: 3 :: Nil, rowOf(1, Tide.flow(Set#{(2, 1)}, 2, Tide.dry(b), b), b))

    /// 高さ 3 の堤で囲った内側は、潮位 3 の満ち潮でも乾いたまま（縁の 3 は潮位 3 を越えない）。
    @Test
    def testInsideOfAHighWallStaysDryAtHighTide(): Unit \ Assert =
        let b = board(0 :: Nil, "3333" :: "3003" :: "3333" :: Nil, "@..." :: "...." :: "...*" :: Nil);
        Assert.assertEq(expected = 3 :: 0 :: 0 :: 3 :: Nil, rowOf(1, Tide.flow(Set.empty(), 3, Tide.dry(b), b), b))

    /// 乾いた段 (1,1)（高さ 1）は水源ではない: 隣のくぼみ (2,1)（高さ 0）は乾いたまま。
    @Test
    def testDryStepDoesNotFillTheHollowNextToIt(): Unit \ Assert =
        let b = board(0 :: Nil, "33333" :: "31033" :: "33333" :: Nil, "@...." :: "....." :: "....*" :: Nil);
        Assert.assertEq(expected = 3 :: 1 :: 0 :: 3 :: 3 :: Nil, rowOf(1, Tide.flow(Set.empty(), 3, Tide.dry(b), b), b))

    /// 抜け口 2 の池（水位 2）の中で小石を (2,1) から (2,2) へ動かす: 小石のいたマスは池と同じ 2 になり、
    /// 乾いた穴は残らない。池の水位は 1 つ（小石の新しいマスだけが乾いている）。
    @Test
    def testMovingAPebbleInsideAPoolLeavesNoDryHole(): Unit \ Assert =
        let b = board(0 :: Nil, "33333" :: "20003" :: "30003" :: "33333" :: Nil,
                      "@...." :: "....." :: "....." :: "....*" :: Nil);
        let high = Tide.flow(Set#{(2, 1)}, 3, Tide.dry(b), b);
        let pool = Tide.flow(Set#{(2, 1)}, 0, high, b);
        let moved = Tide.flow(Set#{(2, 2)}, 0, pool, b);
        Assert.assertEq(expected = (2 :: 2 :: 2 :: 2 :: 3 :: Nil, 3 :: 2 :: 0 :: 2 :: 3 :: Nil),
            (rowOf(1, moved, b), rowOf(2, moved, b)))

    // ══════════════════════════════════════════════════════
    // 面の初めの水
    // ══════════════════════════════════════════════════════

    /// 初めの水は満ち引きを 1 周回した後の物で、もう 1 周回しても変わらない（くぼみの水は一度入ったら抜けない）。
    @Test
    def testInitialWaterIsStableOverAnotherCycle(): Unit \ Assert =
        let b = board(0 :: 1 :: 2 :: 3 :: 2 :: 1 :: Nil, "3333" :: "0103" :: "3333" :: Nil, "@..." :: "...." :: "...*" :: Nil);
        let first = Tide.initialWater(b);
        Assert.assertEq(expected = (0 :: 1 :: 1 :: 3 :: Nil, first), (rowOf(1, first, b), Tide.cycleOnce(Set.empty(), first, b)))
}
