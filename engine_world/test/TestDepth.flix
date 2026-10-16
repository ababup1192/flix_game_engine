// Depth（見下ろしの前後関係）— 足元が下にある物ほど大きい zIndex になること、
// 画面の外まで歩いても数が壊れないこと。
mod TestDepth {

    @Test
    def testLowerFootComesInFront(): Unit \ Assert =
        Assert.assertEq(expected = true, Depth.orderAt(120.0) > Depth.orderAt(80.0))

    @Test
    def testSameRowSharesOrder(): Unit \ Assert =
        Assert.assertEq(expected = Depth.orderAt(40.0), Depth.orderAt(40.7))

    @Test
    def testFarOutsideKeepsOrder(): Unit \ Assert =
        Assert.assertEq(expected = true, Depth.orderAt(-1.0e12) < Depth.orderAt(0.0) and Depth.orderAt(0.0) < Depth.orderAt(1.0e12))
}
