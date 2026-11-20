// 背景の替え方（<<bg … transition= pace=>>）・音（<<audio ambience|bgm|se|all>> の重ね・音量・フェード・wait・lockSeconds）・粒の演出（<<fx 名 once=true>>）。
// 写真・時間帯・音量の名前・粒の名前は Doc（novel.backdrops.json・novel.mixer.json・novel.effects.json）から引き、期待値は Doc から導く。
mod TestAudio {

    use fge::{Clock, Curve, DocJson, GameEngine, JsonCodec, ProjectLoader, Render, Yarn}
    use Commands.Out
    use TestKit.{advance, begun, stepBy}

    def res(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def executed(r: Res.Res, at: Float64, name: String, args: List[String], st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        Commands.execute(Commands.Replay.Live, { now = t(at), node = "", res = r, instant = false }, command(name, args), st)

    def applied(at: Float64, name: String, args: List[String], st: Stage.Stage): Stage.Stage \ Fs.FileRead =
        executed(res(), at, name, args, st) |> Result.map(fst) |> Result.getWithDefault(st)

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

    /// novel.backdrops.json の defaultSeconds・defaultEase を替えた描く元で <<bg>> を当てた舞台。
    def bgWithDefaults(seconds: Float64, ease: Curve.Ease, args: List[String]): Stage.Stage \ Fs.FileRead =
        let base = res();
        let r = base |> Res.withBackdrops(BackdropDoc.Doc.Doc({ defaultSeconds = seconds, defaultEase = ease | BackdropDoc.rec(base#backdrops) }));
        executed(r, 0.0, "bg", photo() :: "grade=${grade()}" :: args, Stage.empty()) |> Result.map(fst) |> Result.getWithDefault(Stage.empty())

    @Test
    def testOmittedTimeComesFromTheDoc(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = 3.0, bgWithDefaults(3.0, Curve.Ease.Linear, Nil)#fadeSeconds)

    @Test
    def testWrittenTimeWinsOverTheDoc(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = 0.5, bgWithDefaults(3.0, Curve.Ease.Linear, "time=0.5" :: Nil)#fadeSeconds)

    @Test
    def testOmittedEaseComesFromTheDoc(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Curve.Ease.InOutSine, bgWithDefaults(1.0, Curve.Ease.InOutSine, Nil)#switch#ease)

    @Test
    def testWrittenEaseWinsOverTheDoc(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Curve.Ease.OutQuad, bgWithDefaults(1.0, Curve.Ease.InOutSine, "ease=outQuad" :: Nil)#switch#ease)

    @Test
    def testBgDefaultsAreReadFromTheDoc(): Unit \ Assert =
        let text = "{\"version\": 1, \"photos\": {}, \"grades\": {}, \"defaultSeconds\": 2.5, \"defaultEase\": \"inOutQuad\"}";
        let read = BackdropDoc.fromJson(text) |> Option.map(d -> (BackdropDoc.rec(d)#defaultSeconds, BackdropDoc.rec(d)#defaultEase));
        Assert.assertEq(expected = Some((2.5, Curve.Ease.InOutQuad)), read)

    @Test
    def testTransitionIsKeptOnTheStage(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = BackdropDoc.Transition.Slide, bg("transition=slide" :: Nil)#switch#transition)

    @Test
    def testCutTakesNoTime(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(TestKit.near(0.0, bg("transition=cut" :: "time=2" :: Nil)#fadeSeconds))

    @Test
    def testPaceRunIsKeptOnTheStage(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Stage.Pace.Run, bg("transition=pan" :: "pace=run" :: Nil)#switch#pace)

    @Test
    def testUnknownTransitionIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(executed(res(), 0.0, "bg", photo() :: "grade=${grade()}" :: "transition=spin" :: Nil, Stage.empty())))

    @Test
    def testSlideBringsThePhotoFromTheRight(): Unit \ {Assert, Fs.FileRead} =
        // slide の途中は、今の写真の面が右へずれて描かれる（左端が画面の左端より右）。ゲームの GameView.backdrop は差さない（写真の面だけを見る）。
        let st = applied(1.0, "bg", photo() :: "transition=slide" :: "time=2" :: Nil, bg("transition=cut" :: Nil));
        let lefts = ViewStage.backdropsUsing((_, _, _, _) -> None, _ -> Layout.screen(Layout.Fit.Regular), envAt(2.0), st) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) if Int32.remainder(s#zIndex, View.zWorldStride()) == View.zBackdropShot() => Some(placed#at#x)
            case _                                                           => None
        });
        Assert.assertTrue(lefts |> List.exists(x -> x > 0.0))

    @Test
    def testDocBlackHoldKeepsTheScreenDark(): Unit \ {Assert, Fs.FileRead} =
        // novel.backdrops.json の black が 0.25・0.5・0.25 なら、2 秒の暗転の 1.4 秒目（進み 0.7）はまだ真っ暗の覆い（既定の形なら 0.6）。
        let base = res();
        let r = base |> Res.withBackdrops(BackdropDoc.Doc.Doc({ black = { fadeOut = 0.25, hold = 0.5, fadeIn = 0.25 } | BackdropDoc.rec(base#backdrops) }));
        let start = executed(r, 0.0, "bg", photo() :: "grade=${grade()}" :: "transition=cut" :: Nil, Stage.empty()) |> Result.map(fst) |> Result.getWithDefault(Stage.empty());
        let st = executed(r, 1.0, "bg", photo() :: "transition=black" :: "time=2" :: Nil, start) |> Result.map(fst) |> Result.getWithDefault(start);
        let env = { storyNow = t(2.4) | View.envOf(Layout.Fit.Regular, r, TestKit.w0(r)) };
        let veils = ViewStage.frame(env, st, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Box(b) if b#zIndex >= View.zWorldStride() => Some(b#alpha)
            case _                                                    => None
        });
        Assert.assertTrue(veils |> List.exists(a -> TestKit.near(1.0, a)))

    @Test
    def testSchemaEaseNamesAreTheCurveTable(): Unit \ {Assert, Fs.FileRead} =
        // スキーマの曲線の名前の一覧（novel.cast.json の fadeEase の enum）が Curve.easeTable と同じ並び（Studio のフォームで選べる名前）。
        let names = Fs.FileRead.read("assets/cast.schema.json") |> Result.toOption
            |> Option.flatMap(text -> DocJson.decodeObject(root -> root, text))
            |> Option.flatMap(Map.get("sections")) |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(Map.get("fadeEase"))
            |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(Map.get("type")) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("enum")) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString));
        Assert.assertEq(expected = Some(Curve.easeTable() |> List.map(fst)), names)

    @Test
    def testBlackoutHoldsDarkForItsShare(): Unit \ Assert =
        // fadeOut 0.4・hold 0.2・fadeIn 0.4 の暗転は、進み 0.55 でまだ真っ暗。
        Assert.assertEq(expected = 1.0, BackdropDoc.blackoutDarknessOf({ fadeOut = 0.4, hold = 0.2, fadeIn = 0.4 }, 0.55))

    @Test
    def testDefaultBlackoutIsHalfDarkAtAQuarter(): Unit \ Assert =
        Assert.assertTrue(TestKit.near(0.5, BackdropDoc.blackoutDarknessOf(BackdropDoc.defaultBlackout(), 0.25)))

    @Test
    def testBlackoutSwapsThePhotoInTheMiddleOfTheHold(): Unit \ Assert =
        Assert.assertTrue(TestKit.near(0.5, BackdropDoc.blackoutSwapAt({ fadeOut = 0.3, hold = 0.4, fadeIn = 0.3 })))

    @Test
    def testBlackoutIsReadFromTheDoc(): Unit \ Assert =
        let text = "{\"version\": 1, \"photos\": {}, \"grades\": {}, \"black\": {\"hold\": 0.3}}";
        let hold = BackdropDoc.fromJson(text) |> Option.map(d -> BackdropDoc.rec(d)#black#hold);
        Assert.assertEq(expected = Some(0.3), hold)

    @Test
    def testBlackCoversTheScreenHalfway(): Unit \ {Assert, Fs.FileRead} =
        // black の真ん中は、暗い地の覆いが濃さ 1 で掛かる。
        let st = applied(1.0, "bg", photo() :: "transition=black" :: "time=2" :: Nil, bg("transition=cut" :: Nil));
        let veils = ViewStage.frame(envAt(2.0), st, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Box(b) if b#zIndex >= View.zWorldStride() => Some(b#alpha)
            case _                                                    => None
        });
        Assert.assertTrue(veils |> List.exists(a -> TestKit.near(1.0, a)))

    @Test
    def testBlackWithoutAPreviousBackdropOnlyFadesIn(): Unit \ {Assert, Fs.FileRead} =
        // 前の背景が無い所からの black は、4 分の 1 の所でも暗くなる側でなく明ける側（覆いの濃さ = 1 - 進み）。
        let st = applied(1.0, "bg", photo() :: "grade=${grade()}" :: "transition=black" :: "time=2" :: Nil, Stage.empty());
        let veils = ViewStage.frame(envAt(1.5), st, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Box(b) if b#zIndex >= View.zWorldStride() => Some(b#alpha)
            case _                                                    => None
        });
        let opening = 1.0 - Stage.fadeProgress(t(1.5), st);
        Assert.assertTrue(veils |> List.exists(a -> TestKit.near(opening, a)))

    @Test
    def testBlackDarkensTheActorsToo(): Unit \ {Assert, Fs.FileRead} =
        // 暗転は背景だけでなく人物の上にも掛かる（覆いと同じ層の数）。
        let shown = Stage.settle(applied(0.0, "show", "a" :: Nil, bg("transition=cut" :: Nil)));
        let st = applied(1.0, "bg", photo() :: "transition=black" :: "time=2" :: Nil, shown);
        let items = ViewStage.frame(envAt(2.0), st, true);
        let boxZ = items |> List.filterMap(placed -> match placed#item {
            case Render.Item.Box(b) => Some(b#zIndex)
            case _                  => None
        }) |> List.foldLeft(Int32.max, -1);
        let castZ = items |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) if s#spec#name == "picture_cast_a_plain" => Some(s#zIndex)
            case _                                                             => None
        }) |> List.foldLeft(Int32.max, -1);
        Assert.assertTrue(boxZ > castZ)

    // ══ <<audio>> ══

    @Test
    def testAmbienceLayersSounds(): Unit \ {Assert, Fs.FileRead} =
        // , でつないだ環境音は重ねて鳴る。
        let st = applied(0.0, "audio", "ambience" :: "amb_a,amb_b" :: Nil, Stage.empty());
        Assert.assertEq(expected = "amb_a" :: "amb_b" :: Nil, Stage.ambienceSoundsOf(t(1.0), st))

    @Test
    def testNamedVolumeComesFromTheMixerDoc(): Unit \ {Assert, Fs.FileRead} =
        let name = MixerDoc.rec(res()#mixerExtras)#volumes |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("");
        let v = MixerDoc.volumeOf(name, res()#mixerExtras) |> Option.getWithDefault(-1.0);
        let st = applied(0.0, "audio", "bgm" :: "bgm_x" :: "volume=${name}" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(v, PropertyTween.numEnd(Stage.bgmVolumeKey(), 1.0, st#props)))

    @Test
    def testFadeInStartsSilent(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(0.0, "audio", "bgm" :: "bgm_x" :: "fade=2" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(0.0, PropertyTween.numAt(t(0.0), Stage.bgmVolumeKey(), 1.0, st#props)))

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
        let w = World.withRead({ stage = st | World.emptyRead(r#theme) }, TestKit.w0(r));
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
        let outs = Commands.execute(Commands.Replay.Silent, { now = t(0.0), node = "", res = r, instant = false }, command("audio", "se" :: "se_x" :: "wait=true" :: Nil), Stage.empty())
            |> Result.map(snd);
        Assert.assertEq(expected = Ok(Nil), outs)

    @Test
    def testLockSecondsHoldTheText(): Unit \ {Assert, Fs.FileRead} =
        // lockSeconds のある効果音を鳴らすと、その秒の間は押しても送らない間になる。
        let r = Res.withMixerExtras(MixerDoc.Doc.Doc({ volumes = Map.empty(), lockSeconds = Map#{ "se_x" => 1.5 } }), res());
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

    @Test
    def testRuntimeSoundLengthTakesThePlatformAnswerForUnloopedSounds(): Unit \ {Assert, Fs.FileRead} =
        // 実機の長さは機種の答え（audioSeconds）。鳴り続ける音と、機種が 0 と答えた音（project.json の sounds の頭の鳴り続けない音）は入れない。
        let unlooped = ProjectLoader.loadProject(".") |> Result.toOption |> Option.map(p -> p#config#soundManifest) |> Option.getWithDefault(Nil)
            |> List.filter(s -> not s#looping) |> List.map(s -> s#name);
        let silent = List.head(unlooped) |> Option.getWithDefault("");
        let got = run { SoundLength.load() } with handler GameEngine.Audio {
            def playAudio(_, k) = k(())
            def stopAudio(_, k) = k(())
            def setVolume(_, _, k) = k(())
            def setPitch(_, _, k) = k(())
            def setLooping(_, _, k) = k(())
            def setMasterVolume(_, k) = k(())
            def reloadAudio(_, _, k) = k(())
            def setLowpass(_, _, k) = k(())
            def audioSeconds(name, k) = k(if (name == silent) 0.0 else 1.5)
        };
        Assert.assertEq(expected = List.drop(1, unlooped) |> List.map(n -> (n, 1.5)) |> List.toMap, got)

    @Test
    def testSeVolumeIsAnError(): Unit \ {Assert, Fs.FileRead} =
        // 効果音は音量を運べないので、volume= を書くと黙って捨てずに止める。
        Assert.assertTrue(Result.isErr(executed(res(), 0.0, "audio", "se" :: "se_x" :: "volume=0.5" :: Nil, Stage.empty())))

    @Test
    def testAmbienceWaitIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(executed(res(), 0.0, "audio", "ambience" :: "amb_a" :: "wait=true" :: Nil, Stage.empty())))

    @Test
    def testFadeToTheSameMusicStartsFromTheVolumeNow(): Unit \ {Assert, Fs.FileRead} =
        // 鳴っている音楽と同じ音への fade= は、鳴らし直さず今の音量から動く。
        let playing = applied(0.0, "audio", "bgm" :: "bgm_x" :: "volume=0.8" :: Nil, Stage.empty());
        let quieter = applied(1.0, "audio", "bgm" :: "bgm_x" :: "volume=0.2" :: "fade=2" :: Nil, playing);
        Assert.assertTrue(TestKit.near(0.8, PropertyTween.numAt(t(1.0), Stage.bgmVolumeKey(), 1.0, quieter#props)))

    @Test
    def testSustainedVolumeComesFromTheStage(): Unit \ {Assert, Fs.FileRead} =
        // 鳴り続ける音の音量は、舞台の audio.bgmVolume。
        let r = res();
        let st = applied(0.0, "audio", "bgm" :: "bgm_x" :: "volume=0.3" :: Nil, Stage.empty());
        let w = World.withRead({ stage = st | World.emptyRead(r#theme) }, TestKit.w0(r));
        Assert.assertEq(expected = Some(0.3), Controls.ambience(r, w) |> List.head |> Option.map(s -> s#volume))

    @Test
    def testMusicBusFollowsTheMusicSetting(): Unit \ {Assert, Fs.FileRead} =
        // 音楽のバスには、設定の「全体 × BGM」の音量を掛ける（環境音の設定は掛けない）。
        let r = res();
        let w0 = TestKit.w0(r);
        let w = World.withSaves(Saves.withConfig({ musicVolume = 0.3, ambienceVolume = 0.9 | Saves.configOf(w0#saves) }, w0#saves), w0);
        let c = Saves.configOf(w#saves);
        let mixer = Controls.mixerOf(r, w);
        let bgm = mixer#buses |> List.find(b -> b#name == "bgm") |> Option.map(b -> b#volume) |> Option.getWithDefault(-1.0);
        Assert.assertTrue(TestKit.near(c#masterVolume * 0.3, bgm))

    @Test
    def testTheMusicVolumeSurvivesTheSaveJson(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let saves = Saves.withConfig({ musicVolume = 0.3 | Saves.configOf(Saves.fresh(r#kind)) }, Saves.fresh(r#kind));
        Assert.assertTrue(TestKit.near(0.3, Saves.configOf(Saves.fromJson(Saves.fresh(r#kind), Saves.toJson(saves)))#musicVolume))

    @Test
    def testTheSettingsHaveAMusicVolumeRow(): Unit \ Assert =
        Assert.assertTrue(List.memberOf(World.Setting.Slider(World.Slider.MusicVolume), WorldSettings.settings()))

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
        Assert.assertTrue(currentText(later) != currentText(first))

    def longerRes(): Res.Res \ Fs.FileRead =
        TestKit.fixtureRes("test/fixtures/wait", "WaitLonger") |> Res.withSoundSeconds(Map#{ "se_slap" => 1.0 })

    @Test
    def testSeWaitAndAWaitBehindOverlap(): Unit \ {Assert, Fs.FileRead} =
        // wait=true（1 秒）の後ろの <<wait 2>> とは重なる: 足して 3 秒ではなく、長い方の 2 秒で次の台詞が出る。
        let r = longerRes();
        let first = begun(r);
        let later = stepBy(r, 1.25, stepBy(r, 1.25, advance(r, first)));
        Assert.assertTrue(currentText(later) != currentText(first))

    @Test
    def testSeWaitAndAWaitBehindWaitForTheLongerOne(): Unit \ {Assert, Fs.FileRead} =
        // 効果音の 1 秒が明けても、後ろの <<wait 2>> が明けるまでは次の台詞を出さない。
        let r = longerRes();
        let first = begun(r);
        let pressed = stepBy(r, 0.75, stepBy(r, 0.75, advance(r, first)));
        Assert.assertEq(expected = currentText(first), currentText(pressed))
}
