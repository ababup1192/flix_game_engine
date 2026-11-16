// Timeline の PlaybackLog（resume と seek の記録）のテスト。待ちを解くのは resume だけ・seek は待ちを越えない・
// 飛ばした区間の音は鳴らず飛んだ先ちょうどの音は 1 回鳴る・待ちに着いてからの秒・クリップの頭は飛ばした区間の物も返る・
// 表の後ろを縮めても後ろへ足しても再生位置が続く、を見る。時刻はフレームの番号（30 fps）から作る。

mod TestTimelinePlaybackLog {
    use Timeline.{Duration, ClipState, Playback}

    enum Cut with Eq, Order, ToString {
        case Walk
        case Arrive
        case Read
        case Leave
        case Extra
    }

    def walkStep(secs: Float64): Timeline.Step[Cut] =
        Timeline.append(Cut.Walk, Duration.Seconds(secs))
            |> Timeline.withSoundAt("step1", Duration.Seconds(1.0)) |> Timeline.withSoundAt("step2", Duration.Seconds(2.0))

    /// 歩き 3 秒（1 秒目と 2 秒目に足音）→ 着いた音 → 読むのを待つ → 去る音。
    def cut(): Timeline.Timeline[Cut] =
        Timeline.buildOrPanic("cut", Timeline.noTempo(), List#{
            walkStep(3.0),
            Timeline.append(Cut.Arrive, Duration.Seconds(0.0)) |> Timeline.withSound("arrive"),
            Timeline.waitFor(Cut.Read),
            Timeline.append(Cut.Leave, Duration.Seconds(0.5)) |> Timeline.withSound("leave")
        })

    def wallOf(frame: Int32): Float64 = Int32.toFloat64(frame) / 30.0

    /// 0 フレーム目から last フレーム目まで、act(フレームの番号, 壁の時刻, 記録) で操作を足しながら、each で集める。
    def frames(act: (Int32, Float64, Timeline.PlaybackLog) -> Timeline.PlaybackLog,
               each: (Playback, Float64, Float64, Timeline.PlaybackLog) -> List[b], last: Int32): List[b] =
        def go(i: Int32, p: Timeline.PlaybackLog, acc: List[b]): List[b] = {
            if (i > last) acc
            else {
                let wall = wallOf(i);
                let next = act(i, wall, p);
                let prev = if (i == 0) 0.0 else wallOf(i - 1);
                let playback = if (i == 0) Playback.Enter else Playback.Play;
                go(i + 1, next, acc ::: each(playback, prev, wall, next))
            }
        };
        go(0, Timeline.playbackLog(), Nil)

    def play(act: (Int32, Float64, Timeline.PlaybackLog) -> Timeline.PlaybackLog): List[String] =
        let tl = cut();
        frames(act, (playback, prev, wall, p) -> Timeline.soundsOnWall(playback, prev, wall, p, tl), 300)

    def started(act: (Int32, Float64, Timeline.PlaybackLog) -> Timeline.PlaybackLog): List[Cut] =
        let tl = cut();
        frames(act, (playback, prev, wall, p) -> Timeline.startedOnWall(playback, prev, wall, p, tl), 300)

    @Test
    def testWithoutControlsTheWalkPlaysThenStopsAtTheWait(): Unit \ Assert =
        Assert.assertEq(expected = List#{"step1", "step2", "arrive"}, play((_, _, p) -> p))

    @Test
    def testSeekingPastTheWalkDropsItsLaterStepsButPlaysTheArrival(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = List#{"step1", "arrive"},
            play((i, wall, p) -> if (i == 45) Timeline.seekOn(wall, 3.0, p, tl) else p))

    @Test
    def testSeekStopsAtTheWait(): Unit \ Assert =
        let tl = cut();
        let p = Timeline.seekOn(0.5, 100.0, Timeline.playbackLog(), tl);
        Assert.assertEq(expected = (true, 3.0), (Timeline.isWaitingOn(0.5, p, tl), Timeline.playheadOn(0.5, p, tl)#t))

    @Test
    def testResumeBeforeTheWaitIsNotCounted(): Unit \ Assert =
        let tl = cut();
        let early = Timeline.resumeOn(1.0, Timeline.playbackLog(), tl);
        Assert.assertEq(expected = true, Timeline.isWaitingOn(5.0, early, tl))

    @Test
    def testResumeAfterASeekContinuesFromTheWait(): Unit \ Assert =
        let tl = cut();
        let skipped = Timeline.seekOn(1.0, 3.0, Timeline.playbackLog(), tl);
        let resumed = Timeline.resumeOn(2.0, skipped, tl);
        Assert.assertEq(expected = ClipState.Active(0.5), Timeline.stateOf(Cut.Leave, Timeline.playheadOn(2.25, resumed, tl), tl))

    @Test
    def testWaitedCountsFromArrivalAtTheWait(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = Some(1.5), Timeline.waitedOn(4.5, Timeline.playbackLog(), tl))

    @Test
    def testSkipToNextWaitSilencesEverythingSkipped(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = List#{"arrive"}, play((i, wall, p) -> if (i == 0) Timeline.skipToNextWait(wall, p, tl) else p))

    @Test
    def testTheResumeListContinuesFromTheWait(): Unit \ Assert =
        // 待ち（表の 3 秒）に壁の 3 秒で着き、6 秒で解いた: 6.5 秒には表の 3.5 秒・解いた待ちは 1 つ。
        let tl = cut();
        let head = Timeline.playheadOf(6.5, Timeline.resume(6.0, Nil, tl), tl);
        Assert.assertEq(expected = (3.5, 1), (head#t, head#passed))

    @Test
    def testAResumeTimeBeforeTheWaitIsNotCounted(): Unit \ Assert =
        Assert.assertEq(expected = true, Timeline.isWaiting(5.0, List#{1.0}, cut()))

    @Test
    def testStartedClipsIncludeTheOnesInsideASkippedRange(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = List#{Cut.Walk, Cut.Arrive, Cut.Read},
            started((i, wall, p) -> if (i == 0) Timeline.skipToNextWait(wall, p, tl) else p))

    @Test
    def testEachClipStartsOnceAcrossAResume(): Unit \ Assert =
        let tl = cut();
        Assert.assertEq(expected = List#{Cut.Walk, Cut.Arrive, Cut.Read, Cut.Leave},
            started((i, wall, p) -> if (i == 150) Timeline.resumeOn(wall, p, tl) else p))

    @Test
    def testShorteningTheRunningClipAndAppendingKeepThePlayhead(): Unit \ Assert =
        // 待ちを 1 つ解いた後（表の 1 秒）に始まる 3 秒の溜めを、表の 2 秒（壁の 3 秒）で縮めて後ろへ 1 本足す。
        let before = Timeline.buildOrPanic("before", Timeline.noTempo(), List#{
            Timeline.append(Cut.Arrive, Duration.Seconds(1.0)), Timeline.waitFor(Cut.Read), walkStep(3.0) });
        let after = Timeline.buildOrPanic("after", Timeline.noTempo(), List#{
            Timeline.append(Cut.Arrive, Duration.Seconds(1.0)), Timeline.waitFor(Cut.Read), walkStep(1.0),
            Timeline.append(Cut.Extra, Duration.Seconds(0.5)) });
        let p = Timeline.resumeOn(2.0, Timeline.playbackLog(), before);
        let pair = (h: Timeline.Playhead) -> (h#t, h#passed);
        Assert.assertEq(expected = (pair(Timeline.playheadOn(3.0, p, before)), ClipState.Active(0.0)),
                        (pair(Timeline.playheadOn(3.0, p, after)), Timeline.stateOf(Cut.Extra, Timeline.playheadOn(3.0, p, after), after)))
}
