// 背景の替え方（<<bg … transition= pace=>>）・音（<<audio ambience|bgm|se|all>> の重ね・音量・フェード・wait・lockSeconds）・粒の演出（<<fx 名 once=true>>）。
// 写真・時間帯・音量の名前・粒の名前は Doc（novel.backdrops.json・novel.mixer.json・novel.effects.json）から引き、期待値は Doc から導く。
mod TestAudio {

    use fge::{Clock, Render, Yarn}
    use Commands.Out
    use TestKit.{advance, begun, stepBy}

    def res(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def executed(r: Res.Res, at: Float64, name: String, args: List[String], st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        Commands.execute(Commands.Replay.Live, { now = t(at), node = "", res = r }, command(name, args), st)

    def applied(at: Float64, name: String, args: List[String], st: Stage.Stage): Stage.Stage \ Fs.FileRead =
        executed(res(), at, name, args, st) |> Result.map(fst) |> Result.getWithDefault(st)

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.000001

    def photo(): String \ Fs.FileRead = BackdropDoc.rec(res()#backdrops)#photos |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("")

    def grade(): String \ Fs.FileRead = BackdropDoc.rec(res()#backdrops)#grades |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("")

    def bg(args: List[String]): Stage.Stage \ Fs.FileRead = applied(0.0, "bg", photo() :: "grade=${grade()}" :: args, Stage.empty())

    def envAt(at: Float64): View.Env \ Fs.FileRead =
        let r = res();
        { storyNow = t(at) | View.envOf(Layout.Fit.Regular, r, TestKit.w0(r)) }

    // ══ <<bg … transition= pace=>> ══

    @Test
    def testOmittedTransitionComesFromTheDoc(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = BackdropDoc.rec(res()#backdrops)#defaultTransition, bg(Nil)#switch#transition)

    @Test
    def testTransitionIsKeptOnTheStage(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = BackdropDoc.Transition.Slide, bg("transition=slide" :: Nil)#switch#transition)

    @Test
    def testCutTakesNoTime(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(near(0.0, bg("transition=cut" :: "time=2" :: Nil)#fadeSeconds))

    @Test
    def testPaceRunIsKeptOnTheStage(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Stage.Pace.Run, bg("transition=pan" :: "pace=run" :: Nil)#switch#pace)

    @Test
    def testUnknownTransitionIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(executed(res(), 0.0, "bg", photo() :: "grade=${grade()}" :: "transition=spin" :: Nil, Stage.empty())))

    @Test
    def testSlideBringsThePhotoFromTheRight(): Unit \ {Assert, Fs.FileRead} =
        // slide の途中は、今の写真の面が右へずれて描かれる（左端が画面の左端より右）。
        let st = applied(1.0, "bg", photo() :: "transition=slide" :: "time=2" :: Nil, bg("transition=cut" :: Nil));
        let lefts = ViewStage.frame(envAt(2.0), st, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) if Int32.remainder(s#zIndex, View.zWorldStride()) == 2 => Some(placed#at#x)
            case _                                                           => None
        });
        Assert.assertTrue(lefts |> List.exists(x -> x > 0.0))

    @Test
    def testBlackCoversTheScreenHalfway(): Unit \ {Assert, Fs.FileRead} =
        // black の真ん中は、暗い地の覆いが濃さ 1 で掛かる。
        let st = applied(1.0, "bg", photo() :: "transition=black" :: "time=2" :: Nil, bg("transition=cut" :: Nil));
        let veils = ViewStage.frame(envAt(2.0), st, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Box(b) if Int32.remainder(b#zIndex, View.zWorldStride()) == 3 => Some(b#alpha)
            case _                                                         => None
        });
        Assert.assertTrue(veils |> List.exists(a -> near(1.0, a)))

    // ══ <<audio>> ══

    @Test
    def testAmbienceLayersSounds(): Unit \ {Assert, Fs.FileRead} =
        // , でつないだ環境音は重ねて鳴る。
        let st = applied(0.0, "audio", "ambience" :: "amb_a,amb_b" :: Nil, Stage.empty());
        Assert.assertEq(expected = "amb_a" :: "amb_b" :: Nil, Stage.ambienceSoundsOf(t(1.0), st))

    @Test
    def testNamedVolumeComesFromTheMixerDoc(): Unit \ {Assert, Fs.FileRead} =
        let name = MixerDoc.rec(res()#sounds)#volumes |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("");
        let v = MixerDoc.volumeOf(name, res()#sounds) |> Option.getWithDefault(-1.0);
        let st = applied(0.0, "audio", "bgm" :: "bgm_x" :: "volume=${name}" :: Nil, Stage.empty());
        Assert.assertTrue(near(v, PropertyTween.numEnd(Stage.bgmVolumeKey(), 1.0, st#props)))

    @Test
    def testFadeInStartsSilent(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(0.0, "audio", "bgm" :: "bgm_x" :: "fade=2" :: Nil, Stage.empty());
        Assert.assertTrue(near(0.0, PropertyTween.numAt(t(0.0), Stage.bgmVolumeKey(), 1.0, st#props)))

    @Test
    def testFadeOutKeepsPlayingUntilItEnds(): Unit \ {Assert, Fs.FileRead} =
        // fade= で止めると、フェードの間は鳴り続け、終わった時に止まる。
        let playing = applied(0.0, "audio", "ambience" :: "amb_a" :: Nil, Stage.empty());
        let off = applied(1.0, "audio", "ambience" :: "off" :: "fade=2" :: Nil, playing);
        Assert.assertEq(expected = (Some("amb_a"), None), (Stage.ambienceOf(t(2.0), off), Stage.ambienceOf(t(3.5), off)))

    @Test
    def testAllOffStopsAmbienceAndMusic(): Unit \ {Assert, Fs.FileRead} =
        let playing = applied(0.0, "audio", "bgm" :: "bgm_x" :: Nil, applied(0.0, "audio", "ambience" :: "amb_a" :: Nil, Stage.empty()));
        let off = applied(1.0, "audio", "all" :: "off" :: Nil, playing);
        Assert.assertEq(expected = (None, None), (Stage.ambienceOf(t(2.0), off), PropertyTween.nameAt(t(2.0), Stage.bgmKey(), off#props)))

    @Test
    def testSustainedSoundsIncludeMusic(): Unit \ {Assert, Fs.FileRead} =
        // 鳴り続ける音は、環境音の列と音楽の全部。
        let r = res();
        let st = applied(0.0, "audio", "bgm" :: "bgm_x" :: Nil, applied(0.0, "audio", "ambience" :: "amb_a,amb_b" :: Nil, Stage.empty()));
        let w = World.withRead({ stage = st | World.emptyRead() }, TestKit.w0(r));
        Assert.assertEq(expected = "amb_a" :: "amb_b" :: "bgm_x" :: Nil, Controls.ambience(r, w) |> List.map(s -> s#name))

    @Test
    def testSeWaitWaitsForTheSoundLength(): Unit \ {Assert, Fs.FileRead} =
        // wait=true は、音の長さ（Res#soundSeconds）だけ待つ出来事を出す。
        let r = Res.withSoundSeconds(Map#{ "se_x" => 0.8 }, res());
        let outs = executed(r, 0.0, "audio", "se" :: "se_x" :: "wait=true" :: Nil, Stage.empty()) |> Result.map(snd);
        Assert.assertEq(expected = Ok(Out.Sound("se_x") :: Out.Wait(0.8) :: Nil), outs)

    @Test
    def testSeWaitIsDroppedWhenReplaying(): Unit \ {Assert, Fs.FileRead} =
        // ロードや戻るの当て直しでは待たない（音も鳴らさない）。
        let r = Res.withSoundSeconds(Map#{ "se_x" => 0.8 }, res());
        let outs = Commands.execute(Commands.Replay.Silent, { now = t(0.0), node = "", res = r }, command("audio", "se" :: "se_x" :: "wait=true" :: Nil), Stage.empty())
            |> Result.map(snd);
        Assert.assertEq(expected = Ok(Nil), outs)

    @Test
    def testLockSecondsHoldTheText(): Unit \ {Assert, Fs.FileRead} =
        // lockSeconds のある効果音を鳴らすと、その秒の間は押しても送らない間になる。
        let r = Res.withSounds(MixerDoc.Doc.Doc({ volumes = Map.empty(), lockSeconds = Map#{ "se_x" => 1.5 } }), res());
        let st = executed(r, 0.0, "audio", "se" :: "se_x" :: Nil, Stage.empty()) |> Result.map(fst) |> Result.getWithDefault(Stage.empty());
        Assert.assertEq(expected = (true, false), (Stage.isTextLocked(t(1.0), st), Stage.isTextLocked(t(2.0), st)))

    @Test
    def testWavSecondsReadsTheHeader(): Unit \ Assert =
        // 44 バイトの頭（byteRate 8000・data 4000 バイト）の WAV は 0.5 秒。
        let byte = (v: Int32) -> Int32.tryToInt8(if (v > 127) v - 256 else v) |> Option.getWithDefault(0i8);
        let le = (n: Int32) -> List.range(0, 4) |> List.map(k -> byte(Int32.bitwiseAnd(Int32.rightShift(n, k * 8), 255)));
        let tag = (s: String) -> String.toList(s) |> List.map(c -> byte(Char.toBmpCodePoint(c)));
        let header = List.flatten(tag("RIFF") :: le(4036) :: tag("WAVE") :: tag("fmt ") :: le(16) :: le(65537) :: le(8000) :: le(8000) :: le(65537) ::
                                  tag("data") :: le(4000) :: Nil);
        Assert.assertEq(expected = Some(0.5), SoundLength.wavSeconds(List.toVector(List.append(header, List.repeat(4000, 0i8)))))

    // ══ <<fx 名 once=true>> ══

    @Test
    def testFxOnceRunsForTheDocSeconds(): Unit \ {Assert, Fs.FileRead} =
        let name = EffectsDoc.rec(res()#effects)#particles |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("");
        let secs = EffectsDoc.particleOf(name, res()#effects) |> Option.map(p -> p#onceSeconds) |> Option.getWithDefault(0.0);
        let st = applied(0.0, "fx", name :: "once=true" :: Nil, Stage.empty());
        Assert.assertEq(expected = Some(secs), PropertyTween.triggerSpanAt(t(0.0), Stage.fxOnceKey(name), st#props) |> Option.map(snd))

    @Test
    def testUnknownFxIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(executed(res(), 0.0, "fx", "zz" :: Nil, Stage.empty())))

    // ══ wait=true で台詞を待つ（端から端まで） ══

    def waitRes(): Res.Res \ Fs.FileRead =
        TestKit.fixtureRes("test/fixtures/wait", "Wait") |> Res.withSoundSeconds(Map#{ "se_slap" => 1.0 })

    def currentText(w: World.World): String = World.pageOf(w)#current |> Option.map(l -> l#text) |> Option.getWithDefault("")

    @Test
    def testSeWaitHoldsTheNextLine(): Unit \ {Assert, Fs.FileRead} =
        // 送ると効果音が鳴り、その長さの間は次の台詞を出さない（前の台詞のまま）。
        let r = waitRes();
        let first = begun(r);
        let pressed = stepBy(r, 0.5, advance(r, first));
        Assert.assertEq(expected = currentText(first), currentText(pressed))

    @Test
    def testSeWaitShowsTheNextLineAfterTheSound(): Unit \ {Assert, Fs.FileRead} =
        // 音の長さが過ぎると、次の台詞を出す。
        let r = waitRes();
        let first = begun(r);
        let later = stepBy(r, 1.5, advance(r, first));
        Assert.assertTrue(currentText(later) != currentText(first) and currentText(later) != "")
}
