// 型で分けた時計（Clock[c]・App.addClock・frame#realNow）の決まり: 止めて戻しても・スロー中でも
// 時刻表の音は 1 回だけ鳴る・止めている間も実時間は進む・時計は実フレームに 1 回だけ進む。
// どれも App.trace（実機と同じ advanceFrame → audio の経路）で確かめる。
mod TestClock {

    use GameEngine.Key
    use Timeline.Duration

    pub enum Play

    enum Halt { case Menu }

    enum Beat with Eq, Order, ToString { case Hit }

    /// paused = P で開け閉めする窓・hitAt = ヒットストップの合図・cueAt = 時刻表の起点。
    type alias World = { play = Clock.Clock[Play], paused = Bool, hitAt = Clock.Time[Play],
                         cueAt = Clock.Time[Play], plan = TimeScale.Plan }

    /// 0.3 秒に "hit" が鳴る表。
    def cue(): Timeline.Timeline[Beat] =
        Timeline.buildOrPanic("t", Timeline.noTempo(), List#{
            Timeline.insert(Duration.Seconds(0.3), Beat.Hit, Duration.Seconds(0.1)) |> Timeline.withSound("hit")
        })

    /// 0.2 秒止めて 0.5 秒 0.2 倍・0.1 秒で戻すヒットストップ。
    def hitstop(): TimeScale.Plan =
        TimeScale.freezeThenSlow({ freeze = 0.2, freezeScale = 0.0, slow = 0.5, slowScale = 0.2, ramp = 0.1 })

    def start(hitAt: Clock.Time[Play]): World =
        { play = Clock.start(), paused = false, hitAt = hitAt, cueAt = Clock.zero(), plan = hitstop() }

    def paceOf(w: World): Clock.Pace[Play, Halt] =
        Clock.paceOf(if (w#paused) Clock.Run.Paused(Halt.Menu) else Clock.Run.Running)
            |> Clock.withSlow(w#hitAt, w#plan)

    def app(): App.App[World, {}] =
        App.make(start(Clock.never()))
            |> App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w }, paceOf = paceOf })
            |> App.addSystem((f, w) -> if (App.justPressed(Key.P, f)) { paused = not w#paused | w } else w)
            |> App.withAudio(ws -> Timeline.soundsOnClock(ws#after#play, ws#after#cueAt, cue()))

    def frame(keys: Set[Key]): App.Frame =
        App.frameOf(prev = Set#{}, current = keys, 1.0 / 60.0, { x = 320.0, y = 240.0 },
                    { prevCursor = None, cursor = Vec2.zero() }, { prevDown = false, down = false, wheel = 0.0 })

    def idle(n: Int32): List[App.Frame] = List.repeat(n, frame(Set#{}))

    def press(): List[App.Frame] = frame(Set#{Key.P}) :: Nil

    def soundsOf(steps: List[App.TraceStep[World]]): List[String] = List.flatMap(s -> s#sounds, steps)

    def lastOf(steps: List[App.TraceStep[World]]): App.TraceStep[World] =
        List.last(steps) |> Option.getWithDefault({ frame = frame(Set#{}), before = start(Clock.never()),
                                                     after = start(Clock.never()), sounds = Nil, sustained = Nil })

    // ========================================================================
    // 止める
    // ========================================================================

    /// 0.25 秒進めて止め、止めたまま 1 秒、戻して 0.5 秒 —— 0.3 秒の音は 1 回だけ鳴る。
    @Test
    def testPauseAcrossCueRingsOnce(): Unit \ Assert =
        let frames = idle(15) ::: press() ::: idle(60) ::: press() ::: idle(30);
        Assert.assertEq(expected = "hit" :: Nil, soundsOf(App.trace(app(), frames, start(Clock.never()))))

    /// 0.3 秒の音を鳴らした後（20 フレーム目）で止め、1 秒置いて戻しても、音は鳴り直さない。
    @Test
    def testPauseAfterCueDoesNotRingAgain(): Unit \ Assert =
        let frames = idle(20) ::: press() ::: idle(60) ::: press() ::: idle(30);
        Assert.assertEq(expected = "hit" :: Nil, soundsOf(App.trace(app(), frames, start(Clock.never()))))

    /// 止めている 60 フレームの間、遊びの時計は進まず（dt 0）、実時間は 1 秒進む。
    @Test
    def testPauseHoldsPlayClockButNotRealTime(): Unit \ Assert =
        let steps = App.trace(app(), press() ::: idle(1) ::: idle(60), start(Clock.never()));
        let held = List.drop(2, steps);
        let first = List.head(held) |> Option.getWithDefault(lastOf(steps));
        let last = lastOf(steps);
        Assert.assertEq(expected = (true, 0.0, true),
            (Clock.nowOf(first#after#play) == Clock.nowOf(last#after#play),
             Clock.dtOf(last#after#play),
             Float64.abs(Clock.since(first#frame#realNow, last#frame#realNow) - 59.0 / 60.0) < 0.000001))

    // ========================================================================
    // 遅くする
    // ========================================================================

    /// 頭からヒットストップ（0.2 秒止め → 0.5 秒 0.2 倍）を掛けても、0.3 秒の音は 1 回だけ鳴る。
    @Test
    def testSlowAcrossCueRingsOnce(): Unit \ Assert =
        Assert.assertEq(expected = "hit" :: Nil, soundsOf(App.trace(app(), idle(120), start(Clock.zero()))))

    /// 止める区間（0.2 秒）の中では、遊びの時計はほとんど進まない（実時間の 1% 未満）。
    @Test
    def testSlowFreezesPlayClock(): Unit \ Assert =
        let last = lastOf(App.trace(app(), idle(6), start(Clock.zero())));
        Assert.assertEq(expected = true, Clock.dtOf(last#after#play) < (1.0 / 60.0) * 0.01)

    /// スローが終わった後（0.2 + 0.5 + 0.1 秒の実時間より後）は実時間どおり 1/60 秒ずつ進む。
    @Test
    def testSlowEndsAtRealDt(): Unit \ Assert =
        let last = lastOf(App.trace(app(), idle(120), start(Clock.zero())));
        Assert.assertEq(expected = true, Float64.abs(Clock.dtOf(last#after#play) - 1.0 / 60.0) < 0.000001)

    /// まだ合図の無いスロー（never）は、時計の進みを 1 秒も削らない。
    @Test
    def testNeverSlowKeepsRealDt(): Unit \ Assert =
        let last = lastOf(App.trace(app(), idle(60), start(Clock.never())));
        Assert.assertEq(expected = true, Float64.abs(Clock.since(Clock.zero(), Clock.nowOf(last#after#play)) - 1.0) < 0.000001)

    /// スローの最中に止めたフレームの進みはちょうど 0（TimeScale の近似を通さない）。
    @Test
    def testPauseInsideSlowIsExactlyZero(): Unit \ Assert =
        let last = lastOf(App.trace(app(), idle(3) ::: press() ::: idle(5), start(Clock.zero())));
        Assert.assertEq(expected = 0.0, Clock.dtOf(last#after#play))

    /// 止めている間はスローも止まり、戻ると続きから流れる（スローの進みは遊びの時計で測る）。
    @Test
    def testPauseInsideSlowKeepsSlow(): Unit \ Assert =
        let last = lastOf(App.trace(app(), idle(3) ::: press() ::: idle(120) ::: press() ::: idle(2), start(Clock.zero())));
        Assert.assertEq(expected = true, Clock.isSlowed(paceOf(last#after), last#after#play))

    // ========================================================================
    // 実フレームに 1 回
    // ========================================================================

    /// 固定刻み（1/120 秒）で系が 2 回回っても、時計は実フレームの 1/60 秒だけ進む。
    @Test
    def testFixedStepAdvancesClockOncePerFrame(): Unit \ Assert =
        let last = lastOf(App.trace(App.withFixedStep(1.0 / 120.0, app()), idle(1), start(Clock.never())));
        Assert.assertEq(expected = true, Float64.abs(Clock.dtOf(last#after#play) - 1.0 / 60.0) < 0.000001)

    /// 系を直に呼ぶテストは tickClocks で実機と同じ 1 回の進みを組める（advanceFrame と同じ今）。
    @Test
    def testTickClocksMatchesTrace(): Unit \ Assert =
        let traced = lastOf(App.trace(app(), idle(1), start(Clock.never())));
        let ticked = App.tickClocks(app(), 1.0 / 60.0, start(Clock.never()));
        Assert.assertEq(expected = Clock.nowOf(traced#after#play), Clock.nowOf(ticked#play))

    // ========================================================================
    // 実時間で鳴らす
    // ========================================================================

    /// 実時間の前後（0.25 → 0.35 秒）を渡すと、0.3 秒の音が鳴る。遊びの時計が止まっていても実時間は進む。
    @Test
    def testSoundsBetweenTimesOnRealTime(): Unit \ Assert =
        let at: Clock.Time[Clock.Real] = Clock.zero();
        Assert.assertEq(expected = "hit" :: Nil,
            Timeline.soundsBetweenTimes(at, { before = Clock.after(0.25, at), after = Clock.after(0.35, at) }, cue()))

    // ========================================================================
    // 寿命
    // ========================================================================

    /// 1 秒の寿命を 0.25 秒で止め、止めたまま 1 秒置いても、進みは 0.25 のまま。
    @Test
    def testLifetimeStopsWithItsClock(): Unit \ Assert =
        let span = Lifetime.fireOn(Clock.zero(), 1.0);
        let last = lastOf(App.trace(app(), idle(14) ::: press() ::: idle(60), start(Clock.never())));
        Assert.assertEq(expected = true, Float64.abs(Lifetime.progressOn(Clock.nowOf(last#after#play), span) - 0.25) < 0.000001)
}
