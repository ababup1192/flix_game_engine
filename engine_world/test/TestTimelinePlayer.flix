// Timeline の Player（resume と seek の記録）のテスト。待ちを解くのは resume だけ・seek は待ちを越えない・
// 飛ばした区間の音は鳴らず飛んだ先ちょうどの音は 1 回鳴る・待ちに着いてからの秒、を見る。

mod TestTimelinePlayer {
    use Timeline.{Duration, ClipState, Playback}

    enum Cut with Eq, Order, ToString {
        case Walk
        case Arrive
        case Read
        case Leave
    }

    /// 歩き 3 秒（1 秒目と 2 秒目に足音）→ 着いた音 → 読むのを待つ → 去る音。
    def cut(): Timeline.Timeline[Cut] =
        Timeline.buildOrPanic("cut", Timeline.noTempo(), List#{
            Timeline.append(Cut.Walk, Duration.Seconds(3.0))
                |> Timeline.withSoundAt("step1", Duration.Seconds(1.0)) |> Timeline.withSoundAt("step2", Duration.Seconds(2.0)),
            Timeline.append(Cut.Arrive, Duration.Seconds(0.0)) |> Timeline.withSound("arrive"),
            Timeline.waitFor(Cut.Read),
            Timeline.append(Cut.Leave, Duration.Seconds(0.5)) |> Timeline.withSound("leave")
        })

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 1.0e-9

    /// 0 から end まで 1/30 秒ずつ刻み、act(壁の時刻, player) で操作を足しながら鳴った音を集める。
    def play(act: (Float64, Timeline.Player) -> Timeline.Player, end: Float64): List[String] =
        let tl = cut();
        let dt = 1.0 / 30.0;
        def go(i: Int32, p: Timeline.Player, acc: List[String]): List[String] = {
            let wall = Int32.toFloat64(i) * dt;
            if (wall > end) acc
            else {
                let next = act(wall, p);
                let prev = if (i == 0) 0.0 else Int32.toFloat64(i - 1) * dt;
                let playback = if (i == 0) Playback.Enter else Playback.Play;
                go(i + 1, next, acc ::: Timeline.soundsOnPlayer(playback, prev, wall, next, tl))
            }
        };
        go(0, Timeline.player(), Nil)

    @Test
    def testWithoutControlsTheWalkPlaysThenStopsAtTheWait(): Unit \ Assert =
        Assert.assertEq(expected = List#{"step1", "step2", "arrive"}, play((_, p) -> p, 10.0))

    @Test
    def testSkippingTheWalkDropsItsLaterStepsButPlaysTheArrival(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = List#{"step1", "arrive"},
            play((wall, p) -> if (near(wall, 1.5)) Timeline.skipToEndOf(Cut.Walk, wall, p, tl) else p, 10.0))

    @Test
    def testSeekStopsAtTheWait(): Unit \ Assert =
        let tl = cut();
        let p = Timeline.seekOn(0.5, 100.0, Timeline.player(), tl);
        Assert.assertEq(expected = (true, 3.0), (Timeline.isWaitingOn(0.5, p, tl), Timeline.playheadOn(0.5, p, tl)#t))

    @Test
    def testResumeBeforeTheWaitIsNotCounted(): Unit \ Assert =
        let tl = cut();
        let early = Timeline.resumeOn(1.0, Timeline.player(), tl);
        Assert.assertEq(expected = true, Timeline.isWaitingOn(5.0, early, tl))

    @Test
    def testResumeAfterASkipContinuesFromTheWait(): Unit \ Assert =
        let tl = cut();
        let skipped = Timeline.skipToEndOf(Cut.Walk, 1.0, Timeline.player(), tl);
        let resumed = Timeline.resumeOn(2.0, skipped, tl);
        Assert.assertEq(expected = ClipState.Active(0.5), Timeline.stateOf(Cut.Leave, Timeline.playheadOn(2.25, resumed, tl), tl))

    @Test
    def testWaitedCountsFromArrivalAtTheWait(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = true, Timeline.waitedOn(4.5, Timeline.player(), tl) |> Option.exists(s -> near(s, 1.5)))

    @Test
    def testSkipToNextWaitSilencesEverythingSkipped(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = List#{"arrive"},
            play((wall, p) -> if (wall == 0.0) Timeline.skipToNextWait(wall, p, tl) else p, 10.0))

    @Test
    def testPlayerMatchesTheOldResumeList(): Unit \ Assert =
        let tl = cut();
        let p = Timeline.resumeOn(6.0, Timeline.player(), tl);
        let old = Timeline.resume(6.0, Nil, tl);
        let pair = (h: Timeline.Playhead) -> (h#t, h#passed);
        Assert.assertEq(expected = pair(Timeline.playheadOf(6.3, old, tl)), pair(Timeline.playheadOn(6.3, p, tl)))
}
