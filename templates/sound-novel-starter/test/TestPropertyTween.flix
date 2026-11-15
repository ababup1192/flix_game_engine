// 名前の付いた舞台の値の表（PropertyTween）をテストする: tween の途中・遅れて始まる物・同じ鍵への書き直し・
// 一度だけの演出・settle・セーブの JSON の往復。時刻は物語の時計の頭からの秒で組む。
mod TestPropertyTween {

    use fge::{Clock, Curve}

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.after(seconds, Clock.zero())

    def alpha(): PropertyTween.NumKey = PropertyTween.numKey("overlay.alpha")

    def ambience(): PropertyTween.NameKey = PropertyTween.nameKey("audio.ambience")

    def shake(): PropertyTween.TriggerKey = PropertyTween.triggerKey("camera.shake")

    def empty(): PropertyTween.Table[Stage.Story] = PropertyTween.empty()

    /// 0 秒から 2 秒かけて 0 → 1（線形）。
    def fade(): PropertyTween.Table[Stage.Story] =
        PropertyTween.tween(alpha(), Some(0.0), 1.0, t(0.0), 0.0, 2.0, Curve.Ease.Linear, empty())

    @Test
    def testTweenIsHalfWayAtHalfTheSeconds(): Unit \ Assert =
        Assert.assertEq(expected = 0.5, PropertyTween.numAt(t(1.0), alpha(), -1.0, fade()))

    @Test
    def testTweenHoldsTheTargetAfterItEnds(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, PropertyTween.numAt(t(9.0), alpha(), -1.0, fade()))

    @Test
    def testUnwrittenKeyReadsTheFallback(): Unit \ Assert =
        Assert.assertEq(expected = 0.25, PropertyTween.numAt(t(1.0), alpha(), 0.25, empty()))

    @Test
    def testDelayedTweenKeepsThePreviousValueUntilItBegins(): Unit \ Assert =
        let delayed = PropertyTween.setNum(alpha(), 0.25, t(0.0), 0.0, empty())
            |> PropertyTween.tween(alpha(), Some(0.5), 1.0, t(0.0), 3.0, 2.0, Curve.Ease.Linear);
        Assert.assertEq(expected = (0.25, 0.75), (PropertyTween.numAt(t(1.0), alpha(), -1.0, delayed), PropertyTween.numAt(t(4.0), alpha(), -1.0, delayed)))

    @Test
    def testFirstDelayedWriteReadsTheFallbackUntilItBegins(): Unit \ Assert =
        let later = PropertyTween.setNum(alpha(), 0.75, t(0.0), 2.0, empty());
        Assert.assertEq(expected = (-1.0, 0.75), (PropertyTween.numAt(t(1.0), alpha(), -1.0, later), PropertyTween.numAt(t(3.0), alpha(), -1.0, later)))

    @Test
    def testTweenWithoutFromStartsAtTheValueWhenItBegins(): Unit \ Assert =
        let back = PropertyTween.tween(alpha(), None, 0.0, t(1.0), 0.0, 2.0, Curve.Ease.Linear, fade());
        Assert.assertEq(expected = 0.25, PropertyTween.numAt(t(2.0), alpha(), -1.0, back))

    @Test
    def testDelayedStepsOnOneKeyPlayInTurn(): Unit \ Assert =
        let up = PropertyTween.tween(alpha(), Some(0.0), 1.0, t(0.0), 0.0, 1.0, Curve.Ease.Linear, empty());
        let down = PropertyTween.tween(alpha(), None, 0.0, t(0.0), 1.0, 1.0, Curve.Ease.Linear, up);
        let at = s -> PropertyTween.numAt(t(s), alpha(), -1.0, down);
        Assert.assertEq(expected = (0.5, 1.0, 0.5), (at(0.5), at(1.0), at(1.5)))

    @Test
    def testLaterWriteDropsStepsPlannedAfterIt(): Unit \ Assert =
        let planned = PropertyTween.tween(alpha(), Some(0.0), 1.0, t(0.0), 5.0, 1.0, Curve.Ease.Linear, empty());
        let now = PropertyTween.setNum(alpha(), 0.3, t(1.0), 0.0, planned);
        Assert.assertEq(expected = 0.3, PropertyTween.numAt(t(9.0), alpha(), -1.0, now))

    @Test
    def testEaseShapesTheMiddleOfATween(): Unit \ Assert =
        let eased = PropertyTween.tween(alpha(), Some(0.0), 1.0, t(0.0), 0.0, 2.0, Curve.Ease.InQuad, empty());
        Assert.assertEq(expected = Curve.ease(Curve.Ease.InQuad, 0.25), PropertyTween.numAt(t(0.5), alpha(), -1.0, eased))

    @Test
    def testNameChangesWhenItsDelayHasPassed(): Unit \ Assert =
        let night = PropertyTween.setName(ambience(), Some("amb_night"), t(0.0), 0.0, empty());
        let river = PropertyTween.setName(ambience(), Some("amb_river"), t(1.0), 2.0, night);
        Assert.assertEq(expected = (Some("amb_night"), Some("amb_river")),
                        (PropertyTween.nameAt(t(2.0), ambience(), river), PropertyTween.nameAt(t(3.0), ambience(), river)))

    @Test
    def testNameSetToNoneReadsAsNone(): Unit \ Assert =
        let off = PropertyTween.setName(ambience(), Some("amb_night"), t(0.0), 0.0, empty())
            |> PropertyTween.setName(ambience(), None, t(1.0), 0.0);
        Assert.assertEq(expected = None, PropertyTween.nameAt(t(2.0), ambience(), off))

    @Test
    def testTriggerReadsSecondsSinceItBeganOnlyWhileItRuns(): Unit \ Assert =
        let shook = PropertyTween.trigger(shake(), t(1.0), 0.5, 1.0, empty());
        let at = s -> PropertyTween.triggerAt(t(s), shake(), shook);
        Assert.assertEq(expected = (None, Some(0.5), None), (at(1.2), at(2.0), at(2.6)))

    @Test
    def testRetriggerStartsOver(): Unit \ Assert =
        let twice = PropertyTween.trigger(shake(), t(0.0), 0.0, 1.0, empty()) |> PropertyTween.trigger(shake(), t(0.5), 0.0, 1.0);
        Assert.assertEq(expected = Some(0.5), PropertyTween.triggerAt(t(1.0), shake(), twice))

    @Test
    def testSettleBringsEveryValueToItsEndIncludingDelayed(): Unit \ Assert =
        let planned = PropertyTween.tween(alpha(), Some(0.0), 0.8, t(0.0), 5.0, 1.0, Curve.Ease.Linear, empty())
            |> PropertyTween.setName(ambience(), Some("amb_river"), t(0.0), 5.0)
            |> PropertyTween.settle;
        Assert.assertEq(expected = (0.8, Some("amb_river")),
                        (PropertyTween.numAt(t(0.0), alpha(), -1.0, planned), PropertyTween.nameAt(t(0.0), ambience(), planned)))

    @Test
    def testSettleDropsTriggers(): Unit \ Assert =
        let settled = PropertyTween.trigger(shake(), t(0.0), 0.0, 10.0, empty()) |> PropertyTween.settle;
        Assert.assertEq(expected = None, PropertyTween.triggerAt(t(1.0), shake(), settled))

    @Test
    def testEndValuesReadThePlannedLastValue(): Unit \ Assert =
        let planned = PropertyTween.tween(alpha(), Some(0.0), 0.8, t(0.0), 5.0, 1.0, Curve.Ease.Linear, empty())
            |> PropertyTween.setName(ambience(), Some("amb_river"), t(0.0), 5.0);
        Assert.assertEq(expected = (0.8, Some("amb_river")), (PropertyTween.numEnd(alpha(), -1.0, planned), PropertyTween.nameEnd(ambience(), planned)))

    @Test
    def testJsonRoundTripKeepsEndValues(): Unit \ Assert =
        let moving = PropertyTween.tween(alpha(), Some(0.0), 0.8, t(0.0), 0.0, 3.0, Curve.Ease.Linear, empty())
            |> PropertyTween.setName(ambience(), Some("amb_river"), t(0.0), 0.0)
            |> PropertyTween.setName(PropertyTween.nameKey("fx.particles"), None, t(0.0), 0.0);
        let back: Result[String, PropertyTween.Table[Stage.Story]] = PropertyTween.fromJson(PropertyTween.toJson(moving));
        let read = (tb: PropertyTween.Table[Stage.Story]) ->
            (PropertyTween.numAt(t(0.0), alpha(), -1.0, tb), PropertyTween.nameAt(t(0.0), ambience(), tb),
             PropertyTween.nameAt(t(0.0), PropertyTween.nameKey("fx.particles"), tb));
        Assert.assertEq(expected = Ok((0.8, Some("amb_river"), None)), back |> Result.map(read))

    @Test
    def testJsonWithWrongTypeIsAnError(): Unit \ Assert =
        let bad = Util.Json.Json.JObject(Map#{ "nums" => Util.Json.Json.JObject(Map#{ "overlay.alpha" => Util.Json.Json.JString("x") }) });
        let back: Result[String, PropertyTween.Table[Stage.Story]] = PropertyTween.fromJson(bad);
        Assert.assertTrue(Result.isErr(back))
}
