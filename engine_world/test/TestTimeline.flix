// Timeline のテスト。テストするのは「合計尺」と「境界でどの区間に落ちるか・
// 範囲外で None(Done)になるか」だけ — 絵はテストしない(スナップショットと目視の仕事)。

mod TestTimeline {

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
}
