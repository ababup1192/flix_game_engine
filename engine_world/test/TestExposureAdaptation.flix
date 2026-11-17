// ExposureAdaptation（狙いの明るさへ露出を近づける）を具体値で固定する: 近づく割合・明るくなる時と暗くなる時の速さ・
// 刻み方に依らない着く所・灰色に合わせる露出・上下限。
mod TestExposureAdaptation {

    def settings(): ExposureAdaptation.Settings = ExposureAdaptation.defaults()

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.000001

    @Test
    def testStepMovesByOneMinusExpOfSpeedTimesDt(): Unit \ Assert =
        Assert.assertEq(expected = true, near(4.0 * (1.0 - Float64.exp(-3.0 * 0.5)), ExposureAdaptation.step(settings(), 0.5, 4.0, 0.0)))

    @Test
    def testStepUsesTheSlowSpeedWhenGettingDarker(): Unit \ Assert =
        Assert.assertEq(expected = true, near(-4.0 * (1.0 - Float64.exp(-1.0 * 0.5)), ExposureAdaptation.step(settings(), 0.5, -4.0, 0.0)))

    @Test
    def testStepWithoutTimeKeepsThePreviousValue(): Unit \ Assert =
        Assert.assertEq(expected = 1.5, ExposureAdaptation.step(settings(), 0.0, 4.0, 1.5))

    @Test
    def testTwoHalfStepsReachTheSamePlaceAsOneStep(): Unit \ Assert =
        let half = ExposureAdaptation.step(settings(), 0.25, 4.0, ExposureAdaptation.step(settings(), 0.25, 4.0, 0.0));
        Assert.assertEq(expected = true, near(ExposureAdaptation.step(settings(), 0.5, 4.0, 0.0), half))

    @Test
    def testMidGrayNeedsNoExposure(): Unit \ Assert =
        Assert.assertEq(expected = true, near(0.0, ExposureAdaptation.computeExposure(settings(), ExposureAdaptation.evOf(0.18))))

    @Test
    def testBrighterPlaceGetsLowerExposure(): Unit \ Assert =
        Assert.assertEq(expected = true, near(-2.0, ExposureAdaptation.computeExposure(settings(), ExposureAdaptation.evOf(0.72))))

    @Test
    def testExposureStopsAtTheLimit(): Unit \ Assert =
        Assert.assertEq(expected = 4.0, ExposureAdaptation.computeExposure(settings(), ExposureAdaptation.evOf(0.0)))

    @Test
    def testCompensationAddsToTheExposure(): Unit \ Assert =
        Assert.assertEq(expected = true, near(0.5, ExposureAdaptation.computeExposure({ compensation = 0.5 | settings() }, ExposureAdaptation.evOf(0.18))))

    @Test
    def testEnteringABrightPlaceStartsOverexposed(): Unit \ Assert =
        let dark = ExposureAdaptation.evOf(0.02);
        let bright = ExposureAdaptation.evOf(1.5);
        let justIn = ExposureAdaptation.computeExposure(settings(), ExposureAdaptation.step(settings(), 0.05, bright, dark));
        let settled = ExposureAdaptation.computeExposure(settings(), bright);
        Assert.assertEq(expected = true, justIn > settled + 2.0)
}
