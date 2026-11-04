// TestNum — 0〜1 への丸め・小数部・周期の折り返しを具体値で固定する。
// 特に「負の値でどうなるか」を pin する（書き方が割れるのはそこだけ）。
mod TestNum {

    @Test
    def testClamp01PinsBothEnds(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 0.25, 1.0),
            (Num.clamp01(-3.0), Num.clamp01(0.25), Num.clamp01(9.0)))

    @Test
    def testClampFallsToLowEndWhenRangeIsEmpty(): Unit \ Assert =
        // lo > hi は範囲が無い。下端に丸める（呼び側が気付けるよう黙って通さない）。
        Assert.assertEq(expected = (2.0, 5.0), (Num.clamp(2.0, 8.0, -1.0), Num.clamp(5.0, 1.0, 3.0)))

    @Test
    def testClampIntPinsBothEndsAndEmptyRange(): Unit \ Assert =
        // Float64 版と同じ約束（lo > hi は下端）。Flix 標準の Int32.clamp は pub でなく呼べない。
        Assert.assertEq(expected = (2, 5, 8, 5),
            (Num.clampInt(2, 8, -1), Num.clampInt(2, 8, 5), Num.clampInt(2, 8, 99),
             Num.clampInt(5, 1, 3)))

    @Test
    def testFractIsAlwaysInsideZeroToOne(): Unit \ Assert =
        // 負でも 0 以上 1 未満。歩行の位相が逆向きでも途切れないための性質。
        Assert.assertEq(expected = (0.25, 0.75, 0.0), (Num.fract(1.25), Num.fract(-0.25), Num.fract(3.0)))

    @Test
    def testWrapToLoopsAndKeepsNegativesPositive(): Unit \ Assert =
        Assert.assertEq(expected = (1.0, 9.0, 0.0),
            (Num.wrapTo(4.0, 5.0), Num.wrapTo(10.0, -1.0), Num.wrapTo(4.0, 8.0)))

    @Test
    def testWrapToNeverGoesNegativeOnRoundingEdge(): Unit \ Assert =
        // 1.7/0.1 は丸めで 17 ちょうどに繰り上がり、素朴な x - p*floor(x/p) は -2.2e-16 を返す。
        // 時刻に使うと -ε が「-1 時」へ化けるので、0 以上へ戻すのが契約。
        Assert.assertEq(expected = true, Num.wrapTo(0.1, 1.7) >= 0.0)

    @Test
    def testWrapToLeavesValueAloneWhenPeriodIsNotPositive(): Unit \ Assert =
        Assert.assertEq(expected = (7.0, 7.0), (Num.wrapTo(0.0, 7.0), Num.wrapTo(-2.0, 7.0)))

    @Test
    def testLerpDoesNotClampOutsideRange(): Unit \ Assert =
        // 範囲外は伸ばしたまま（外挿）。収めたいなら呼ぶ側が clamp01 を通す決まり。
        Assert.assertEq(expected = (5.0, 20.0), (Num.lerp(0.0, 10.0, 0.5), Num.lerp(0.0, 10.0, 2.0)))

    @Test
    def testPiIsHalfOfTau(): Unit \ Assert =
        Assert.assertEq(expected = Num.tau(), Num.pi() * 2.0)
}
