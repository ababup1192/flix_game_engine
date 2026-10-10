// EcsTween（汎用 ECS tween）の純粋層テスト。
// 補間の途中経過・完了時の値・進行中フラグ・複数チャンネル同時・カーブ・1往復(yoyo)を、
// 公開 API（start / step / isActive）だけを通して確認する。
//
// キーは (entity, channel) を (Int32, Int32) で表す（EcsTween は意味を知らない＝整数で十分）。
// 共通入力 posTrack: 位置 (0,0)→(100,50) を 1.0 秒で動かす。1.0 秒の半分(0.5秒)で進捗は半分になる。
mod TestEcsTween {

    /// 位置 (0,0)→(100,50) を動かす Vec トラック（多くのテストの共通入力）。
    def posTrack(): EcsTween.Track =
        EcsTween.Track.Vec({start = {x = 0.0, y = 0.0}, target = {x = 100.0, y = 50.0}})

    // ========================================================================
    // 補間: 進捗に応じて出発点と目標の間を直線で進む
    // ========================================================================

    /// 1.0 秒の動きを 0.5 秒だけ進めると、ちょうど中間 (50, 25) になる（直線補間の半分）。
    @Test
    def testVecLerpsAtMidpoint(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, false, Map.empty());
        let (_next, outs, _done) = EcsTween.step(0.5, tweens);
        match outs {
            case (_key, EcsTween.Out.VecOut(v)) :: Nil =>
                Assert.assertEq(expected = (50.0, 25.0), (v#x, v#y))
            case _ => bug!("expected a single VecOut")
        }

    /// EaseIn（序盤ゆっくり）では 0.5 秒時点の進捗が 0.25（0.5×0.5）になり、
    /// 位置は直線の中間 (50,25) ではなく (25, 12.5) になる＝カーブが効いていることを確認する。
    @Test
    def testEaseInCurvesMidpoint(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.EaseIn, false, Map.empty());
        let (_next, outs, _done) = EcsTween.step(0.5, tweens);
        match outs {
            case (_key, EcsTween.Out.VecOut(v)) :: Nil =>
                Assert.assertEq(expected = (25.0, 12.5), (v#x, v#y))
            case _ => bug!("expected a single VecOut")
        }

    // ========================================================================
    // 完了: 経過が長さに達したら目標へぴったり止まり、進行リストから外れる
    // ========================================================================

    /// 1.0 秒の動きを 1.0 秒進めると、目標 (100, 50) にぴったり到達する（手前の半端値で止まらない）。
    @Test
    def testCompletesAtExactTarget(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, false, Map.empty());
        let (_next, outs, _done) = EcsTween.step(1.0, tweens);
        match outs {
            case (_key, EcsTween.Out.VecOut(v)) :: Nil =>
                Assert.assertEq(expected = (100.0, 50.0), (v#x, v#y))
            case _ => bug!("expected a single VecOut")
        }

    /// 完了すると進行中ではなくなり（isActive=false）、完了キー一覧にそのキーが乗る。
    @Test
    def testRemovedAndReportedOnCompletion(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, false, Map.empty());
        let (next, _outs, done) = EcsTween.step(1.0, tweens);
        Assert.assertEq(
            expected = (false, (1, 0) :: Nil),
            (EcsTween.isActive((1, 0), next), done))

    /// まだ完了していない（0.5 < 1.0）間は進行中のまま（isActive=true）で、完了キーは空。
    @Test
    def testStaysActiveBeforeCompletion(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, false, Map.empty());
        let (next, _outs, done) = EcsTween.step(0.5, tweens);
        Assert.assertEq(
            expected = (true, Nil),
            (EcsTween.isActive((1, 0), next), done))

    // ========================================================================
    // 複数チャンネル: 1 つの相手に複数の動き（位置・透明度）を同時にかけられる
    // ========================================================================

    /// 同じ相手(1)に 2 チャンネル（0=位置 Vec、1=透明度 Scalar 0→1）を積み、0.5 秒進めると
    /// それぞれ独立に中間値（位置(50,25)・透明度 0.5）になる＝複合キー (entity, channel) の実証。
    @Test
    def testMultiChannelInterpolatesIndependently(): Unit \ Assert =
        let withPos = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, false, Map.empty());
        let tweens  = EcsTween.start((1, 1), EcsTween.Track.Scalar({start = 0.0, target = 1.0}), 1.0, EcsTween.Easing.Linear, false, withPos);
        let (_next, outs, _done) = EcsTween.step(0.5, tweens);
        let byKey = List.toMap(outs);
        match (Map.get((1, 0), byKey), Map.get((1, 1), byKey)) {
            case (Some(EcsTween.Out.VecOut(v)), Some(EcsTween.Out.ScalarOut(a))) =>
                Assert.assertEq(expected = (50.0, 25.0, 0.5), (v#x, v#y, a))
            case _ => bug!("expected both channels to produce output")
        }

    // ========================================================================
    // 1往復(yoyo): 出発点→目標→出発点 と進み、完了で出発点に戻る
    // ========================================================================

    /// yoyo は折り返すので、半分(0.5秒)の時点で目標 (100, 50) に達する（往きの終点＝折り返し点）。
    @Test
    def testYoyoReachesTargetAtMidpoint(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, true, Map.empty());
        let (_next, outs, _done) = EcsTween.step(0.5, tweens);
        match outs {
            case (_key, EcsTween.Out.VecOut(v)) :: Nil =>
                Assert.assertEq(expected = (100.0, 50.0), (v#x, v#y))
            case _ => bug!("expected a single VecOut")
        }

    /// yoyo は完了(1.0秒)で出発点 (0, 0) に戻る（往って還る 1 往復）。
    @Test
    def testYoyoReturnsToStartAtCompletion(): Unit \ Assert =
        let tweens = EcsTween.start((1, 0), posTrack(), 1.0, EcsTween.Easing.Linear, true, Map.empty());
        let (_next, outs, _done) = EcsTween.step(1.0, tweens);
        match outs {
            case (_key, EcsTween.Out.VecOut(v)) :: Nil =>
                Assert.assertEq(expected = (0.0, 0.0), (v#x, v#y))
            case _ => bug!("expected a single VecOut")
        }


    // ── steppedInt（整数を 1 つずつ動かす） ──

    /// 等間隔なら進みの 4 分の 1 ごとに 1 つ移る（境目ちょうどで次の値になる）。
    @Test
    def testSteppedIntLinearStepsOnTheBoundary(): Unit \ Assert =
        let at = u -> EcsTween.steppedInt(4, 0, EcsTween.Easing.Linear, u);
        Assert.assertEq(expected = (4, 3, 3, 2, 0), (at(0.0), at(0.25), at(0.49), at(0.5), at(1.0)))

    /// EaseOut は出だしで速く移る（進み半分で 4 回中 3 回移っている）。範囲外は端の値。
    @Test
    def testSteppedIntEaseOutFrontLoads(): Unit \ Assert =
        let at = u -> EcsTween.steppedInt(0, 4, EcsTween.Easing.EaseOut, u);
        Assert.assertEq(expected = (3, 0, 4), (at(0.5), at(-1.0), at(2.0)))
}
