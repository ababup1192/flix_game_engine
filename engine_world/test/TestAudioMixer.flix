// TestAudioMixer — 音の通り道（AudioMixer）の規則を固定する。
// 確かめるのは規則だけ: 振り分けの最長一致・クールダウン・ダッキングの下がり方と戻り方
// （一発の音・鳴り続ける音の両方）・スナップショットへなめらかに移ること・Doc の読み込み。
mod TestAudioMixer {

    def dt(): Float64 = 1.0 / 60.0

    def duck(): AudioMixer.Duck =
        { bus = "music", by = "sfx" :: Nil, depth = 0.5,
          attackSeconds = 0.1, holdSeconds = 0.0, releaseSeconds = 0.2 }

    def mixer(): AudioMixer.Mixer =
        { routes = { bus = "music", prefixes = "bgm" :: Nil } :: { bus = "ui", prefixes = "bgmUi" :: "cursor" :: Nil } :: Nil,
          ducks = duck() :: Nil,
          cooldowns = { prefix = "cursor", seconds = 0.05 } :: Nil | AudioMixer.defaults() }

    /// 一発の音はどれも 0.5 秒鳴る、として数える。
    def half(_name: String): Float64 = 0.5

    /// n フレームぶん、毎フレーム同じ音を宣言して進める。
    def advanceFrames(m: AudioMixer.Mixer, n: Int32, plays: List[String], hums: List[String], s: AudioMixer.State): AudioMixer.State =
        List.range(0, n) |> List.foldLeft((acc, _) -> snd(AudioMixer.step(m, half, dt(), plays, hums, acc)), s)

    /// 名前の頭が長く一致したバスへ振り分ける（bgm より bgmUi が勝つ）。
    @Test
    def testLongestPrefixWins(): Unit \ Assert =
        Assert.assertEq(expected = ("music", "ui", "sfx"),
            (AudioMixer.busOf(mixer(), "bgmFight"), AudioMixer.busOf(mixer(), "bgmUiTick"), AudioMixer.busOf(mixer(), "slash")))

    /// クールダウンの間に来た同じ音は鳴らさず、過ぎたら鳴らす。
    @Test
    def testCooldownDropsRepeatsInsideTheWindow(): Unit \ Assert =
        let (first, s1) = AudioMixer.step(mixer(), half, dt(), "cursor" :: Nil, Nil, AudioMixer.initial());
        let (second, s2) = AudioMixer.step(mixer(), half, dt(), "cursor" :: Nil, Nil, s1);
        let (third, _) = AudioMixer.step(mixer(), half, 0.05, "cursor" :: Nil, Nil, s2);
        Assert.assertEq(expected = (1, 0, 1), (List.length(first), List.length(second), List.length(third)))

    /// 効果音が鳴ると、曲は attackSeconds で depth まで下がる。
    @Test
    def testOneShotDucksMusicToDepth(): Unit \ Assert =
        let (_, s1) = AudioMixer.step(mixer(), half, dt(), "slash" :: Nil, Nil, AudioMixer.initial());
        let s2 = advanceFrames(mixer(), 10, Nil, Nil, s1);
        Assert.assertEq(expected = duck()#depth, AudioMixer.gainOf(mixer(), s2, "bgmFight"))

    /// 鳴り終わって releaseSeconds たてば、曲は元の音量へ戻る。
    @Test
    def testMusicReturnsAfterRelease(): Unit \ Assert =
        let (_, s1) = AudioMixer.step(mixer(), half, dt(), "slash" :: Nil, Nil, AudioMixer.initial());
        let s2 = advanceFrames(mixer(), 60, Nil, Nil, s1);
        Assert.assertEq(expected = 1.0, AudioMixer.gainOf(mixer(), s2, "bgmFight"))

    /// 鳴り続ける音でも（holdSeconds = 0 のままで）曲は下がる。
    @Test
    def testSustainedSoundDucksMusicWithoutHold(): Unit \ Assert =
        let s = advanceFrames(mixer(), 20, Nil, "rain" :: Nil, AudioMixer.initial());
        Assert.assertEq(expected = duck()#depth, AudioMixer.gainOf(mixer(), s, "bgmFight"))

    def talkMixer(): AudioMixer.Mixer =
        { transitionSeconds = 0.5,
          snapshots = { name = "talk", buses = { name = "music", volume = Some(0.5), lowpassGainHF = Some(0.2) } :: Nil } :: Nil
          | mixer() }

    /// スナップショットへは値の距離によらず transitionSeconds でちょうど移る（4 分の 1 の時間で 4 分の 1）。
    @Test
    def testSnapshotMovesOverTransitionSeconds(): Unit \ Assert =
        let s0 = advanceFrames(talkMixer(), 1, Nil, Nil, AudioMixer.initial());
        let talk = AudioMixer.withSnapshot("talk", talkMixer());
        let s1 = snd(AudioMixer.step(talk, half, 0.125, Nil, Nil, s0));
        Assert.assertEq(expected = 0.875, AudioMixer.gainOf(talk, s1, "bgmFight"))

    /// スナップショットのローパスも移り切ればその値になる。
    @Test
    def testSnapshotLowpassArrives(): Unit \ Assert =
        let talk = AudioMixer.withSnapshot("talk", talkMixer());
        let s = advanceFrames(talk, 40, Nil, Nil, advanceFrames(talkMixer(), 1, Nil, Nil, AudioMixer.initial()));
        Assert.assertEq(expected = 0.2, AudioMixer.lowpassGainHFOf(talk, s, "bgmFight"))

    /// 効果音が鳴ったそのフレームから曲は下がり始める（1 フレーム遅れない）。
    @Test
    def testDuckStartsOnTheSameFrame(): Unit \ Assert =
        let (_, s) = AudioMixer.step(mixer(), half, dt(), "slash" :: Nil, Nil, AudioMixer.initial());
        Assert.assertTrue(AudioMixer.gainOf(mixer(), s, "bgmFight") < 1.0)

    /// 鳴り続ける音の宣言が続く間は、フレームの長さが揺れても曲は下がったまま。
    @Test
    def testSustainedDuckSurvivesUnevenFrames(): Unit \ Assert =
        let s = List.range(0, 30) |> List.foldLeft((acc, i) -> {
            let frame = if (Int32.modulo(i, 2) == 0) 0.008 else 0.05;
            snd(AudioMixer.step(mixer(), half, frame, Nil, "rain" :: Nil, acc))
        }, AudioMixer.initial());
        Assert.assertEq(expected = duck()#depth, AudioMixer.gainOf(mixer(), s, "bgmFight"))

    /// holdSeconds の間は、鳴り終わっても曲は下がったまま。
    @Test
    def testHoldKeepsTheDuck(): Unit \ Assert =
        let held = { ducks = { holdSeconds = 1.0 | duck() } :: Nil | mixer() };
        let s = advanceFrames(held, 30, Nil, Nil, advanceFrames(held, 20, Nil, "rain" :: Nil, AudioMixer.initial()));
        Assert.assertEq(expected = duck()#depth, AudioMixer.gainOf(held, s, "bgmFight"))

    // ── AudioMixdown（実機と同じ規則で書き出す）──
    // 1 秒 10 サンプル・10fps で、1 コマ = 1 サンプルにして並びを読む。

    def mixFrame(plays: List[String], sustained: List[String]): AudioMixdown.MixFrame =
        { plays = plays, sustained = List.map(n -> { name = n, volume = 1.0, pitch = 1.0 }, sustained),
          mixer = AudioMixer.defaults() }

    /// 同じ名前が鳴り直すと頭から（重ねて足さない）: 振れ幅は 1 本ぶんを超えない。
    @Test
    def testMixdownRestartsInsteadOfStacking(): Unit \ Assert =
        let sounds = Map#{"tick" => Vector#{1.0, 1.0, 1.0}};
        let out = AudioMixdown.mixdown(10, 10.0, sounds, mixFrame("tick" :: Nil, Nil) :: mixFrame("tick" :: Nil, Nil) :: mixFrame(Nil, Nil) :: mixFrame(Nil, Nil) :: mixFrame(Nil, Nil) :: Nil);
        Assert.assertEq(expected = Vector#{1.0, 1.0, 1.0, 1.0, 0.0}, out)

    /// 鳴り続ける音は宣言が消えたコマで止まる。
    @Test
    def testMixdownStopsWhenTheDeclarationEnds(): Unit \ Assert =
        let sounds = Map#{"hum" => Vector#{0.5}};
        let out = AudioMixdown.mixdown(10, 10.0, sounds, mixFrame(Nil, "hum" :: Nil) :: mixFrame(Nil, "hum" :: Nil) :: mixFrame(Nil, Nil) :: Nil);
        Assert.assertEq(expected = Vector#{0.5, 0.5, 0.0}, out)

    /// 鳴り続ける音が止まれば、曲は releaseSeconds で元へ戻る。
    @Test
    def testMusicReturnsAfterSustainedStops(): Unit \ Assert =
        let s = advanceFrames(mixer(), 30, Nil, Nil, advanceFrames(mixer(), 20, Nil, "rain" :: Nil, AudioMixer.initial()));
        Assert.assertEq(expected = 1.0, AudioMixer.gainOf(mixer(), s, "bgmFight"))

    /// クールダウンも名前の頭の一番長い一致で決まる。
    @Test
    def testCooldownLongestPrefixWins(): Unit \ Assert =
        let m = { cooldowns = { prefix = "cur", seconds = 1.0 } :: { prefix = "cursorFast", seconds = 0.0 } :: Nil | mixer() };
        Assert.assertEq(expected = (1.0, 0.0), (AudioMixer.cooldownOf(m, "cursor"), AudioMixer.cooldownOf(m, "cursorFast")))

    /// 壊れた JSON は None（load はそこで既定へ倒す）。
    @Test
    def testBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, AudioMixerDoc.fromJson("{ not json") |> Option.map(m -> m#defaultBus))

    /// 1 欄だけ書いた Doc は、その欄だけ変わり残りは既定のまま。
    @Test
    def testOneFieldOverrides(): Unit \ Assert =
        let got = AudioMixerDoc.fromJson("{\"version\": 1, \"defaultBus\": \"voice\"}");
        Assert.assertEq(expected = Some(("voice", 0)),
            got |> Option.map(m -> (m#defaultBus, List.length(m#buses))))

    /// 行の数は JSON の配列の長さに追随し、読めない行だけ落ちる。
    @Test
    def testRowsFollowTheArray(): Unit \ Assert =
        let got = AudioMixerDoc.fromJson("{\"buses\": [{\"name\": \"a\"}, {\"name\": \"b\", \"volume\": 0.5}, {\"volume\": 1}]}");
        Assert.assertEq(expected = Some(("a" :: "b" :: Nil)), got |> Option.map(m -> List.map(b -> b#name, m#buses)))
}
