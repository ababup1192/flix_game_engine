// LoadProgress.Deferred — 後回しの素材を受ける機種の handler（WebLayer）の、機種に依らない部品の振る舞い。
mod TestLoadProgressDeferred {
    use LoadProgress.Deferred.{PendingSound, SoundCall}

    // ========================================================================
    // 道の状態の字 → LoadState
    // ========================================================================

    /// 機種の字は同じ名前の LoadState に読み替える
    @Test
    def testKnownStateTextsMapToLoadStates(): Unit \ Assert =
        Assert.assertEq(expected = LoadProgress.LoadState.Queued :: LoadProgress.LoadState.Downloading :: LoadProgress.LoadState.Downloaded :: LoadProgress.LoadState.Loaded :: Nil,
                        List.map(LoadProgress.Deferred.loadStateOfText, "queued" :: "downloading" :: "downloaded" :: "loaded" :: Nil))

    /// "failed:理由" は理由を持った Failed
    @Test
    def testFailedTextKeepsTheReason(): Unit \ Assert =
        Assert.assertEq(expected = LoadProgress.LoadState.Failed("404"), LoadProgress.Deferred.loadStateOfText("failed:404"))

    /// 知らない字は待ち続けにせず、その字を理由にした Failed
    @Test
    def testUnknownTextIsFailed(): Unit \ Assert =
        Assert.assertEq(expected = LoadProgress.LoadState.Failed("paused"), LoadProgress.Deferred.loadStateOfText("paused"))

    // ========================================================================
    // 道ごとのまとめ（1 本の道を 2 つの名前で宣言した絵）
    // ========================================================================

    /// 同じ道 bg/sea.webp の 2 つの名前は 1 つの組にまとまり、道の並びは最初に出た順
    @Test
    def testSamePathWithTwoNamesIsOneGroup(): Unit \ Assert =
        let entries = ("sea", "bg/sea.webp") :: ("town", "bg/town.webp") :: ("sea_night", "bg/sea.webp") :: Nil;
        Assert.assertEq(expected = ("bg/sea.webp", ("sea", "bg/sea.webp") :: ("sea_night", "bg/sea.webp") :: Nil) :: ("bg/town.webp", ("town", "bg/town.webp") :: Nil) :: Nil,
                        LoadProgress.Deferred.groupByPath(snd, entries))

    // ========================================================================
    // 届く前の音の覚え書き
    // ========================================================================

    def noted(calls: List[SoundCall]): Map[String, PendingSound] =
        List.foldLeft((acc, call) -> LoadProgress.Deferred.notePendingSound("bgm", call, acc), Map.empty(), calls)

    /// 鳴らす・音量・高さ・ループを言われた順に重ね、最後に言われた値を持つ
    @Test
    def testCallsAreMergedIntoTheLastValues(): Unit \ Assert =
        let calls = SoundCall.SetVolume(0.3) :: SoundCall.Play :: SoundCall.SetVolume(0.8) :: SoundCall.SetPitch(1.5) :: SoundCall.SetLooping(false) :: Nil;
        Assert.assertEq(expected = Some((true, Some(false), Some(0.8), Some(1.5))),
                        Map.get("bgm", noted(calls)) |> Option.map(p -> (p#playing, p#looping, p#volume, p#pitch)))

    /// 止めろと言われたら覚えた事を全部忘れる
    @Test
    def testStopForgetsTheSound(): Unit \ Assert =
        Assert.assertEq(expected = false, Map.memberOf("bgm", noted(SoundCall.Play :: SoundCall.SetVolume(0.5) :: SoundCall.Stop :: Nil)))

    def soundOf(playing: Bool, looping: Option[Bool]): PendingSound =
        { playing = playing, looping = looping, volume = None, pitch = None }

    /// 届いた時に鳴らすのは、鳴らせと言われたループの音だけ（宣言のループか、後から言われたループ）
    @Test
    def testOnlyLoopingSoundsPlayOnArrival(): Unit \ Assert =
        Assert.assertEq(expected = (true, false, true, false, false),
                        (LoadProgress.Deferred.playsOnArrival(soundOf(true, None), true),
                         LoadProgress.Deferred.playsOnArrival(soundOf(true, None), false),
                         LoadProgress.Deferred.playsOnArrival(soundOf(true, Some(true)), false),
                         LoadProgress.Deferred.playsOnArrival(soundOf(true, Some(false)), true),
                         LoadProgress.Deferred.playsOnArrival(soundOf(false, None), true)))
}
