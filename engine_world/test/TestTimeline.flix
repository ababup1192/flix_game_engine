// Timeline のテスト。区間（Seg）は「合計尺」と「境界でどの区間に落ちるか・範囲外で None になるか」、
// クリップは開始の時刻と startedBetween の境目を見る。時刻表（build）は、描く側と鳴らす側が同じ時刻を
// 読むこと、拍がテンポから秒になること、小節の頭へ合わせる長さ、フレームをどう刻んでも音がちょうど
// 1 回鳴ること、待ちと早押し、書き間違いで止まることを見る（場面の見本は戦いの入り・場面転換の会話・
// パズルの連鎖）。絵はテストしない（スナップショットと目視の仕事）。

mod TestTimeline {
    use Timeline.{Duration, ClipState, Playback, BuildError}


    def walkPickBack(): List[Timeline.Seg] =
        Timeline.seg("walk", 2.0) :: Timeline.seg("pick", 0.5)
            :: Timeline.seg("back", 2.0) :: Nil

    /// 合計尺は区間の和。
    @Test
    def testTotalSumsDurations(): Unit \ Assert =
        Assert.assertEq(expected = 4.5, Timeline.total(walkPickBack()))

    /// 区間の頭からの経過秒 u が返る。境界(dur ちょうど)は次の区間の 0 秒目。
    @Test
    def testAtReturnsSegAndElapsed(): Unit \ Assert =
        let segs = walkPickBack();
        Assert.assertEq(expected = (Some(("walk", 0.0)), Some(("walk", 1.5)),
                                    Some(("pick", 0.0)), Some(("back", 0.25))),
            (Timeline.at(segs, 0.0) |> Option.map(r -> (r#name, r#u)),
             Timeline.at(segs, 1.5) |> Option.map(r -> (r#name, r#u)),
             Timeline.at(segs, 2.0) |> Option.map(r -> (r#name, r#u)),
             Timeline.at(segs, 2.75) |> Option.map(r -> (r#name, r#u))))

    /// 範囲外は None = Done。合計尺ちょうども Done(区間は半開 [0, dur))。
    @Test
    def testAtOutOfRangeIsDone(): Unit \ Assert =
        let segs = walkPickBack();
        Assert.assertEq(expected = (None, None, None),
            (Timeline.at(segs, 4.5) |> Option.map(r -> r#name),
             Timeline.at(segs, -0.1) |> Option.map(r -> r#name),
             Timeline.at(Nil, 0.0) |> Option.map(r -> r#name)))

    /// 長さ 0 の区間は踏まれない(次の区間の頭に落ちる)。
    @Test
    def testAtSkipsZeroLengthSeg(): Unit \ Assert =
        let segs = Timeline.seg("a", 1.0) :: Timeline.seg("empty", 0.0)
            :: Timeline.seg("b", 1.0) :: Nil;
        Assert.assertEq(expected = Some(("b", 0.0)),
            Timeline.at(segs, 1.0) |> Option.map(r -> (r#name, r#u)))

    // ── クリップ ──

    /// 頭から順の (tag, 長さ) は、前の長さを足し上げた時刻に並ぶ。
    @Test
    def testToClipsStartsWhereThePreviousEnds(): Unit \ Assert =
        let clips = Timeline.toClips(("walk", 2.0) :: ("pick", 0.5) :: ("back", 2.0) :: Nil);
        Assert.assertEq(expected = (Some(0.0), Some(2.0), Some(2.5), 4.5),
            (Timeline.startOf("walk", clips), Timeline.startOf("pick", clips),
             Timeline.startOf("back", clips), Timeline.durationOf(clips)))

    /// 全体の秒は重なったクリップの一番遅い終わり（足し算ではない）。
    @Test
    def testTotalOfClipsIsTheLatestEnd(): Unit \ Assert =
        let clips = Timeline.clip("long", 0.0, 3.0) :: Timeline.clip("short", 1.0, 0.5) :: Nil;
        Assert.assertEq(expected = 3.0, Timeline.durationOf(clips))

    /// 前のフレームから今までに始まったクリップだけ拾う（前のフレームちょうどに始まった物は拾わない
    /// —— 2 回鳴らさない）。
    @Test
    def testStartedBetweenPicksEachStartOnce(): Unit \ Assert =
        let clips = Timeline.clip("a", 1.0, 0.5) :: Timeline.clip("b", 2.0, 0.5) :: Nil;
        let tags = (t0, t1) -> Timeline.startedBetween(t0, t1, clips) |> List.map(c -> c#tag);
        Assert.assertEq(expected = ("a" :: Nil, Nil, "b" :: Nil, Nil),
            (tags(0.9, 1.0), tags(1.0, 1.1), tags(1.5, 2.5), tags(2.5, 1.5)))

    /// 頭（start = 0）のクリップは、時計を負から回したときだけ拾う。空の列の全体の秒は 0。
    @Test
    def testStartedBetweenAtZeroNeedsANegativeStart(): Unit \ Assert =
        let clips = Timeline.clip("head", 0.0, 1.0) :: Nil;
        Assert.assertEq(expected = (0, 1, 0.0),
            (List.length(Timeline.startedBetween(0.0, 0.1, clips)),
             List.length(Timeline.startedBetween(-1.0, 0.1, clips)),
             Timeline.durationOf((Nil: List[Timeline.Clip[String]]))))

    // ── 時刻表（build） ──



    def tempo(bpm: Float64): Timeline.Tempo = { bpm = bpm, beatsPerBar = 4 }

    def built(r: Result[List[BuildError[a]], Timeline.Timeline[a]]): Timeline.Timeline[a] = match r {
        case Ok(tl) => tl
        case Err(_) => bug!("時刻表の書き間違い")
    }

    def startOf(tag: a, tl: Timeline.Timeline[a]): Float64 with Order[a] =
        Timeline.clipOf(tag, tl) |> Option.map(c -> c#start) |> Option.getWithDefault(-1.0)

    // ── 場面 1: WARNING → 帯 → 叩きつけ → 向き合い（次の小節の頭まで）→ ターン 1 ──

    enum Intro with Eq, Order, ToString {
        case Warning
        case Flash
        case Wipe
        case Slam
        case Hold
        case Turn1
    }

    def intro(bpm: Float64, warningBars: Float64, flashSeconds: Float64): Timeline.Timeline[Intro] =
        built(Timeline.build(tempo(bpm), List#{
            Timeline.append(Intro.Warning, Duration.Bars(warningBars))     |> Timeline.withSound("warning"),
            Timeline.append(Intro.Flash, Duration.Seconds(flashSeconds))   |> Timeline.withSound("whoosh"),
            Timeline.append(Intro.Wipe, Duration.Seconds(0.3)),
            Timeline.append(Intro.Slam, Duration.Seconds(0.12))            |> Timeline.withSound("introSlam"),
            Timeline.atEndOf(Intro.Wipe, Intro.Hold, Duration.ToNextBar),
            Timeline.append(Intro.Turn1, Duration.Beats(1.0))              |> Timeline.withSound("turnStart")
        }))

    /// 0 から end まで dts を繰り返して刻み、鳴った音を集める（最初のフレームは Enter）。
    def playAll(tl: Timeline.Timeline[a], dts: List[Float64], end: Float64): List[String] =
        def go(t, i, acc) =
            if (t >= end) acc
            else {
                let dt = List.nth(Int32.remainder(i, List.length(dts)), dts) |> Option.getWithDefault(0.016);
                let playback = if (i == 0) Playback.Enter else Playback.Play;
                go(t + dt, i + 1, acc ::: Timeline.soundsOn(playback, Timeline.playheadAt(t), Timeline.playheadAt(t + dt), tl))
            };
        go(0.0, 0, Nil)

    def introOrder(): List[String] = List#{"warning", "whoosh", "introSlam", "turnStart"}

    @Test
    def testEverySoundOnceAt60fps(): Unit \ Assert =
        let tl = intro(175.0, 2.0, 0.32);
        Assert.assertEq(expected = introOrder(), playAll(tl, List#{1.0 / 60.0}, Timeline.endOf(tl) + 0.1))

    @Test
    def testEverySoundOnceWithHitchesAndZeroFrames(): Unit \ Assert =
        // 引っかかり（0.25・0.5 秒）・長さ 0 のフレーム・半端な刻みが混ざっても、取りこぼしも二重鳴りも無い。
        let tl = intro(175.0, 2.0, 0.32);
        Assert.assertEq(expected = introOrder(),
            playAll(tl, List#{0.016, 0.0, 0.25, 0.033, 0.0071, 0.5}, Timeline.endOf(tl) + 0.1))

    @Test
    def testTurn1LandsOnBarHeadWhateverTheFlashLength(): Unit \ Assert =
        // 帯の秒を 0.32 → 0.5 に変えても、ターン 1 は同じ小節の頭（12 拍目）に乗る（今の holdSeconds 2.2114 の手計算が要らない）。
        let landing = List#{0.32, 0.5} |> List.map(flash -> startOf(Intro.Turn1, intro(175.0, 2.0, flash)));
        let barHead = Timeline.secondsOf(tempo(175.0), Duration.Beats(12.0));
        Assert.assertEq(expected = List#{barHead, barHead}, landing)

    @Test
    def testSlamSoundAndSlamClipShareStartAtAnyTempo(): Unit \ Assert =
        // テンポを変えても、叩きつけの音は叩きつけの絵が始まるフレームで鳴る。
        let agree = List#{120.0, 150.0, 175.0, 200.0} |> List.map(bpm -> {
            let tl = intro(bpm, 2.0, 0.32);
            let slam = startOf(Intro.Slam, tl);
            Timeline.soundsOn(Playback.Play, Timeline.playheadAt(slam - 0.016), Timeline.playheadAt(slam), tl) == List#{"introSlam"}
        });
        Assert.assertEq(expected = List#{true, true, true, true}, agree)

    @Test
    def testViewSeesClipActiveOnTheExactFrameItsSoundFires(): Unit \ Assert =
        // フレームの終わりが頭ちょうどでも、音が鳴るフレームで描く側はもう Active(0) を読む。
        let tl = intro(175.0, 2.0, 0.32);
        let slam = startOf(Intro.Slam, tl);
        Assert.assertEq(expected = (List#{"introSlam"}, ClipState.Active(0.0)),
            (Timeline.soundsOn(Playback.Play, Timeline.playheadAt(slam - 0.016), Timeline.playheadAt(slam), tl), Timeline.stateOf(Intro.Slam, Timeline.playheadAt(slam), tl)))

    @Test
    def testSoundAtTimeZeroFiresOnEnterFrame(): Unit \ Assert =
        Assert.assertEq(expected = List#{"warning"}, Timeline.soundsOn(Playback.Enter, Timeline.playheadAt(0.0), Timeline.playheadAt(0.016), intro(175.0, 2.0, 0.32)))

    @Test
    def testLengtheningWarningMovesTurn1ByOneBar(): Unit \ Assert =
        let shift = startOf(Intro.Turn1, intro(175.0, 3.0, 0.32)) - startOf(Intro.Turn1, intro(175.0, 2.0, 0.32));
        Assert.assertEq(expected = true, Float64.abs(shift - Timeline.secondsOf(tempo(175.0), Duration.Bars(1.0))) < 1.0e-12)

    @Test
    def testSeekPlaysNothing(): Unit \ Assert =
        let tl = intro(175.0, 2.0, 0.32);
        Assert.assertEq(expected = Nil, Timeline.soundsOn(Playback.Seek, Timeline.playheadAt(0.1), Timeline.playheadAt(Timeline.endOf(tl)), tl))

    @Test
    def testSecondsOnlyClipsMatchTodaysToClipsBitForBit(): Unit \ Assert =
        // 秒だけの表は、今の Timeline.toClips と同じ順で足すので開始の時刻がビットまで同じ（描き出しの一致を保てる）。
        let tl = built(Timeline.build(tempo(175.0), List#{
            Timeline.append(Intro.Flash, Duration.Seconds(0.32)),
            Timeline.append(Intro.Wipe, Duration.Seconds(0.3)),
            Timeline.append(Intro.Hold, Duration.Seconds(2.2114))
        }));
        Assert.assertEq(expected = 0.32 + 0.3, startOf(Intro.Hold, tl))

    // ── 書き間違いは build で止まる ──

    @Test
    def testDuplicateTagIsAnError(): Unit \ Assert =
        let r = Timeline.build(tempo(120.0), List#{
            Timeline.append(Intro.Flash, Duration.Seconds(0.3)) |> Timeline.withSound("whoosh"),
            Timeline.append(Intro.Flash, Duration.Seconds(0.5))
        });
        Assert.assertEq(expected = Err(List#{BuildError.DuplicateTag(Intro.Flash)}), r |> Result.map(_ -> ()))

    @Test
    def testForwardReferenceIsAnError(): Unit \ Assert =
        let r = Timeline.build(tempo(120.0), List#{ Timeline.atEndOf(Intro.Wipe, Intro.Hold, Duration.Beats(1.0)) });
        Assert.assertEq(expected = Err(List#{BuildError.UnknownAnchor(Intro.Wipe)}), r |> Result.map(_ -> ()))

    // ── 場面 2: 拍の演出 → 間 → 窓が入る → 読む（待ち）→ 窓が退く ──

    enum Talk with Eq, Order, ToString {
        case Beat
        case WindowIn
        case Read
        case WindowOut
    }

    def talk(): Timeline.Timeline[Talk] =
        built(Timeline.build(tempo(120.0), List#{
            Timeline.append(Talk.Beat, Duration.Seconds(1.2))                                            |> Timeline.withSound("beatHit"),
            Timeline.append(Talk.WindowIn, Duration.Seconds(0.3)) |> Timeline.withDelay(Duration.Seconds(1.0)) |> Timeline.withSound("windowIn"),
            Timeline.waitFor(Talk.Read),
            Timeline.append(Talk.WindowOut, Duration.Seconds(0.3))                                       |> Timeline.withSound("windowOut")
        }))

    /// 壁の時計を 60fps で end まで回し、presses の秒に決定キーを押したときに鳴った音。
    def playTalk(presses: List[Float64], end: Float64): List[String] =
        let tl = talk();
        let dt = 1.0 / 60.0;
        def go(wall, resumes, i, acc) =
            if (wall >= end) acc
            else {
                let next = wall + dt;
                let pressed = List.exists(p -> wall < p and p <= next, presses);
                let resumesNext = if (pressed) Timeline.resume(next, resumes, tl) else resumes;
                let t0 = Timeline.playheadOf(wall, resumes, tl);
                let t1 = Timeline.playheadOf(next, resumesNext, tl);
                let playback = if (i == 0) Playback.Enter else Playback.Play;
                go(next, resumesNext, i + 1, acc ::: Timeline.soundsOn(playback, t0, t1, tl))
            };
        go(0.0, Nil, 0, Nil)

    @Test
    def testTalkWaitsForReaderThenWindowLeavesOnce(): Unit \ Assert =
        Assert.assertEq(expected = List#{"beatHit", "windowIn", "windowOut"}, playTalk(List#{8.0}, 10.0))

    @Test
    def testEarlyPressDoesNotSkipTheWait(): Unit \ Assert =
        // 窓が入り切る前（2.0 秒）の早押しは数えない。待ちに着いた後（2.5 秒）は止まったまま。
        Assert.assertEq(expected = List#{"beatHit", "windowIn"}, playTalk(List#{2.0}, 10.0))

    @Test
    def testTalkClockResumesFromPress(): Unit \ Assert =
        let tl = talk();
        let resumes = Timeline.resume(8.0, Nil, tl);
        Assert.assertEq(expected = true, Float64.abs(Timeline.playheadOf(8.1, resumes, tl)#t - 2.6) < 1.0e-9)

    @Test
    def testClipAfterWaitStaysBeforeWhileWaiting(): Unit \ Assert =
        // 待ちの位置ちょうど（2.5 秒）で止まっている間、待ちの後に書いた窓の退きはまだ始まらない（音も鳴らない）。
        let tl = talk();
        let head = Timeline.playheadOf(7.0, Nil, tl);
        Assert.assertEq(expected = (ClipState.Before, Nil),
            (Timeline.stateOf(Talk.WindowOut, head, tl), Timeline.soundsOn(Playback.Play, Timeline.playheadOf(2.4, Nil, tl), head, tl)))

    @Test
    def testPlacedBeforeWaitIsAnError(): Unit \ Assert =
        let r = Timeline.build(tempo(120.0), List#{
            Timeline.append(Talk.Beat, Duration.Seconds(1.0)),
            Timeline.waitFor(Talk.Read),
            Timeline.atStartOf(Talk.Beat, Talk.WindowOut, Duration.Seconds(0.3))
        });
        Assert.assertEq(expected = Err(List#{BuildError.PlacedBeforeWait(Talk.WindowOut)}), r |> Result.map(_ -> ()))

    @Test
    def testSoundOnWaitIsAnError(): Unit \ Assert =
        let r = Timeline.build(tempo(120.0), List#{ Timeline.waitFor(Talk.Read) |> Timeline.withSound("ping") });
        Assert.assertEq(expected = Err(List#{BuildError.SoundOnWait(Talk.Read)}), r |> Result.map(_ -> ()))

    // ── 場面 3: 連鎖 n 段（溜め → 弾け + しずく）──

    enum Chain with Eq, Order, ToString {
        case Squeeze(Int32)
        case Burst(Int32)
        case Drip(Int32)
    }

    def chain(chains: Int32, stepSeconds: Float64): Timeline.Timeline[Chain] =
        built(Timeline.build(tempo(120.0), List.range(0, chains) |> List.flatMap(i -> List#{
            Timeline.append(Chain.Squeeze(i), Duration.Seconds(stepSeconds))                     |> Timeline.withFittedSound("squeeze"),
            Timeline.atEndOf(Chain.Squeeze(i), Chain.Burst(i), Duration.Seconds(0.1))            |> Timeline.withSound("pop"),
            Timeline.join(Chain.Drip(i), Duration.Seconds(0.5)) |> Timeline.withDelay(Duration.Seconds(0.15)) |> Timeline.withSound("drip")
        })))

    @Test
    def testSqueezeSoundLengthFollowsSqueezeClip(): Unit \ Assert =
        // 溜めを 0.3 秒にすると、書き出す溜めの音の長さも 0.3 秒（SfxRender はここから引く）。
        Assert.assertEq(expected = Some(0.3), Timeline.soundLengthOf("squeeze", chain(3, 0.3)))

    @Test
    def testChainSoundsInTimeOrder(): Unit \ Assert =
        // append は表の終わり（前の段のしずくの終わり）に並ぶので、段は重ならない。
        let tl = chain(2, 0.2);
        Assert.assertEq(expected = List#{"squeeze", "pop", "drip", "squeeze", "pop", "drip"},
            Timeline.soundsOn(Playback.Enter, Timeline.playheadAt(0.0), Timeline.playheadAt(Timeline.endOf(tl)), tl))

    @Test
    def testFittedSoundOnTwoLengthsIsAnError(): Unit \ Assert =
        let r = Timeline.build(tempo(120.0), List#{
            Timeline.append(Chain.Squeeze(0), Duration.Seconds(0.2)) |> Timeline.withFittedSound("squeeze"),
            Timeline.append(Chain.Squeeze(1), Duration.Seconds(0.3)) |> Timeline.withFittedSound("squeeze")
        });
        Assert.assertEq(expected = Err(List#{BuildError.FittedLengthConflict("squeeze")}), r |> Result.map(_ -> ()))

    @Test
    def testSameTimeSoundsKeepWrittenOrder(): Unit \ Assert =
        let tl = built(Timeline.build(tempo(120.0), List#{
            Timeline.append(Talk.Beat, Duration.Seconds(0.5)) |> Timeline.withSound("first") |> Timeline.withSound("second"),
            Timeline.join(Talk.WindowIn, Duration.Seconds(0.5)) |> Timeline.withSound("third")
        }));
        Assert.assertEq(expected = List#{"first", "second", "third"}, Timeline.soundsOn(Playback.Enter, Timeline.playheadAt(0.0), Timeline.playheadAt(0.1), tl))

    // ── 手前へずらす・テンポの下限 ──

    enum Lead with Eq, Order, ToString {
        case Banner
        case Gap
        case Turn
    }

    /// 帯の後、「次の小節の頭の 1 拍前」に来る行: 小節の頭まで伸ばした行の終わりから 1 拍戻す。
    /// 帯がどこで終わっても、ターンは小節の 4 拍目に乗り、帯の終わりより前には来ない。
    def lead(bannerSeconds: Float64): Timeline.Timeline[Lead] =
        built(Timeline.build(tempo(120.0), List#{
            Timeline.append(Lead.Banner, Duration.Seconds(bannerSeconds)),
            Timeline.append(Lead.Gap, Duration.ToNextBar) |> Timeline.withDelay(Duration.Beats(1.0)),
            Timeline.atEndOf(Lead.Gap, Lead.Turn, Duration.Beats(0.0)) |> Timeline.withDelay(Duration.Beats(-1.0))
        }))

    @Test
    def testANegativeDelayPlacesOneBeatBeforeTheBarHead(): Unit \ Assert =
        // 120 BPM: 1 拍 0.5 秒・1 小節 2 秒。帯 1.2 秒 → 1.5 秒（1 小節目の 4 拍目）・帯 1.6 秒 → 3.5 秒（2 小節目の 4 拍目）。
        Assert.assertEq(expected = List#{1.5, 3.5, 1.5},
            List#{1.2, 1.6, 0.4} |> List.map(b -> startOf(Lead.Turn, lead(b))))

    @Test
    def testTempoNeverDividesByZero(): Unit \ Assert =
        let t = Timeline.tempo(0.0, 0);
        Assert.assertEq(expected = (1.0, 1, 60.0), (t#bpm, t#beatsPerBar, Timeline.secondsOf(t, Duration.Beats(1.0))))
}
