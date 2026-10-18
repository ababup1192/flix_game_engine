// 型で分けた時計（Clock[c]）の進み方と、時刻表の音が止める・遅くするをまたいでも 1 回だけ鳴ること。
mod TestTypedClock {

    use Timeline.Duration

    pub enum Play
    enum Halt { case Menu }

    enum Beat with Eq, Order, ToString { case Hit }

    def tl(): Timeline.Timeline[Beat] =
        Timeline.buildOrPanic("t", Timeline.noTempo(), List#{
            Timeline.insert(Duration.Seconds(0.3), Beat.Hit, Duration.Seconds(0.1)) |> Timeline.withSound("hit")
        })

    def going(): Clock.Run[Halt] = Clock.Run.Running

    def paused(): Clock.Run[Halt] = Clock.Run.Paused(Halt.Menu)

    /// runs の順に 1/60 秒ずつ進め、鳴った音を全部集める。
    def soundsOver(runs: List[Clock.Run[Halt]], clock: Clock.Clock[Play]): List[String] =
        let at = Clock.nowOf(clock);
        def loop(rs, c, acc) = match rs {
            case r :: rest =>
                let c1 = Clock.advance(r, 1.0 / 60.0, c);
                loop(rest, c1, List.append(acc, Timeline.soundsOnClock(c1, at, tl())))
            case Nil => acc
        };
        loop(runs, clock, Nil)

    @Test
    def testPausedClockDoesNotMove(): Unit \ Assert =
        let c = Clock.advance(paused(), 0.5, Clock.advance(going(), 0.5, (Clock.start(): Clock.Clock[Play])));
        Assert.assertEq(expected = (0.5, 0.0), (Clock.secondsOf(Clock.nowOf(c)), Clock.dtOf(c)))

    @Test
    def testPauseAcrossCueRingsOnce(): Unit \ Assert =
        // 0.25 秒進めて止め、止めたまま 1 秒、戻して 0.5 秒 —— 音は 1 回。
        let runs = List.repeat(15, going()) ::: List.repeat(60, paused()) ::: List.repeat(30, going());
        Assert.assertEq(expected = "hit" :: Nil, soundsOver(runs, Clock.start()))

    @Test
    def testSlowAcrossCueRingsOnce(): Unit \ Assert =
        // 頭でヒットストップ（0.2 秒止め → 0.5 秒 0.2 倍）を掛けても、音は 1 回。
        let plan = TimeScale.freezeThenSlow({ freeze = 0.2, freezeScale = 0.0, slow = 0.5, slowScale = 0.2, ramp = 0.1 });
        let runs = List.repeat(120, going());
        Assert.assertEq(expected = "hit" :: Nil, soundsOver(runs, Clock.withSlow(plan, Clock.start())))

    @Test
    def testSlowEndsAndClockCatchesUp(): Unit \ Assert =
        // スローが終われば外れ、以降は実時間どおり進む。
        let plan = TimeScale.freezeThenSlow({ freeze = 0.1, freezeScale = 0.0, slow = 0.0, slowScale = 1.0, ramp = 0.0 });
        let c = List.foldLeft((acc, _) -> Clock.advance(going(), 1.0 / 60.0, acc),
                              Clock.withSlow(plan, (Clock.start(): Clock.Clock[Play])), List.range(0, 30));
        Assert.assertEq(expected = false, Clock.isSlowed(c))

    @Test
    def testLifetimeOnSameClock(): Unit \ Assert =
        let c0: Clock.Clock[Play] = Clock.start();
        let l = Lifetime.fireOn(c0, 1.0);
        let c1 = Clock.advance(paused(), 0.5, Clock.advance(going(), 0.25, c0));
        Assert.assertEq(expected = 0.25, Lifetime.progressOn(c1, l))
}
