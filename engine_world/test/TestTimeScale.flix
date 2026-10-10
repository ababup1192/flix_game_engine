// TimeScale のテスト。テストするのは「止めの間は時計が進まない」「戻った後は等速」
// 「gameAt と realAt が互いに逆になる」「フレームの dt を割った合計が式と一致する」だけ。

mod TestTimeScale {

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.000001

    def plan(): TimeScale.Plan =
        TimeScale.freezeThenSlow({ freeze = 0.2, freezeScale = 0.0, slow = 0.5, slowScale = 0.25, ramp = 0.3 })

    /// 止めの間はゲームの時計がほとんど進まず（0 は下限の 0.001 倍に上がる）、スローの間は 4 分の 1 で進む。
    @Test
    def testFreezeStopsAndSlowCrawls(): Unit \ Assert =
        Assert.assertEq(expected = (true, true),
            (near(TimeScale.gameAt(plan(), 0.2), 0.0002), near(TimeScale.gameAt(plan(), 0.7), 0.1252)))

    /// 戻り切った後は実秒と同じだけ進む。
    @Test
    def testAfterTheRampTimeRunsAtFullSpeed(): Unit \ Assert =
        let g = r -> TimeScale.gameAt(plan(), r);
        Assert.assertEq(expected = true, near(g(3.0) - g(2.0), 1.0))

    /// realAt は gameAt の逆（止めの区間の外で）。
    @Test
    def testRealAtInvertsGameAt(): Unit \ Assert =
        let back = r -> TimeScale.realAt(plan(), TimeScale.gameAt(plan(), r));
        Assert.assertEq(expected = (true, true, true), (near(back(0.5), 0.5), near(back(0.85), 0.85), near(back(2.0), 2.0)))

    /// 1/60 秒ずつ gameDt で進めた時計は、合図をまたいでも式の値と一致する。
    @Test
    def testGameDtAddsUpToGameAt(): Unit \ Assert =
        let dt = 1.0 / 60.0;
        let age = List.range(0, 90) |> List.foldLeft((acc, _i) -> acc + TimeScale.gameDt(plan(), acc, dt), -0.1);
        // 実秒 1.5 − 0.1（合図の前の等速）を過ぎた時点。
        Assert.assertEq(expected = true, near(age, TimeScale.gameAt(plan(), 1.4)))

    /// 区間を手で組んで速さを 0 にしても、時計は止まったままにならない（下限が効く）。
    @Test
    def testHandMadeZeroScaleStillMoves(): Unit \ Assert =
        let p = { segments = { dur = 0.2, scale = 0.0 } :: Nil, ramp = 0.0 };
        let age = List.range(0, 30) |> List.foldLeft((acc, _i) -> acc + TimeScale.gameDt(p, acc, 1.0 / 60.0), 0.0);
        Assert.assertEq(expected = true, age > 0.1)

    /// 区間の無い計画は等速（dt のまま）。
    @Test
    def testEmptyPlanRunsAtFullSpeed(): Unit \ Assert =
        Assert.assertEq(expected = true,
            near(TimeScale.gameDt({ segments = Nil, ramp = 0.0 }, 0.5, 0.25), 0.25))
}
