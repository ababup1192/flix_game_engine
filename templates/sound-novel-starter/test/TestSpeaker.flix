// 話し手とメッセージ枠をテストする: <<window 型>>・<<window off|on time=>>・<<text>>・<<speak>>・<<fx on=絵.点>>・cast.speaker と話し手を明るくする・
// hideWindow・メッセージ枠の型の Doc（windows）と Mark v3 の mode の読み替え・台詞の「」。
// 人物と小物はテスト用の Doc（test/fixtures/novel.cast.json）、粒・型・字の大きさはテンプレートの Doc から引く。
mod TestSpeaker {

    use fge::{Clock, DocJson, JsonCodec, Yarn}
    use Commands.Out

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def exec(res: Res.Res, name: String, args: List[String], st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        Commands.execute(Commands.Replay.Live, { now = Clock.zero(), node = "", res = res }, command(name, args), st)

    def stageAfter(res: Res.Res, name: String, args: List[String], st: Stage.Stage): Stage.Stage =
        exec(res, name, args, st) |> Result.map(fst) |> Result.getWithDefault(st)

    def castRes(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def at(seconds: Float64): Clock.Time[Stage.Story] = Clock.after(seconds, Clock.zero())

    /// 名前の付いた puff の粒（テンプレートの novel.effects.json の最初の物）。
    def puffName(res: Res.Res): String =
        EffectsDoc.rec(res#effects)#particles |> Map.toList |> List.find(match (_, p) -> EffectsDoc.isPointed(p#look)) |> Option.map(fst) |> Option.getWithDefault("")

    /// 画面に広げる粒（puff でない最初の物）。
    def spreadName(res: Res.Res): String =
        EffectsDoc.rec(res#effects)#particles |> Map.toList |> List.find(match (_, p) -> not EffectsDoc.isPointed(p#look)) |> Option.map(fst) |> Option.getWithDefault("")

    def castEnv(res: Res.Res, now: Clock.Time[Stage.Story], st: Stage.Stage): Cast.Env =
        { doc = res#cast, fit = Layout.Fit.Regular, storyNow = now, realNow = Clock.zero(), missing = Set.empty(), light = Cast.steadyLight(Cast.plainTone()),
          props = st#props, photo = None, backdropShift = 0.0 }

    def twoShown(res: Res.Res): Stage.Stage =
        Stage.empty() |> stageAfter(res, "show", "a" :: "time=0" :: Nil) |> stageAfter(res, "show", "b" :: "time=0" :: Nil)

    // ── <<window>> ──

    @Test
    def testWindowToAnUnknownTypeIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(exec(TestKit.res(), "window", "nosuch" :: Nil, Stage.empty())))

    @Test
    def testWindowTimeIsOnlyForOffAndOn(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(exec(TestKit.res(), "window", "bottom" :: "time=1" :: Nil, Stage.empty())))

    @Test
    def testWindowTypeIsWrittenAsItsName(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = "bottom", stageAfter(TestKit.res(), "window", "bottom" :: Nil, Stage.empty())#mode)

    @Test
    def testWindowOffWithTimeFadesHalfwayAtHalfTime(): Unit \ {Assert, Fs.FileRead} =
        let st = stageAfter(TestKit.res(), "window", "off" :: "time=2" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(0.5, Stage.windowAlphaAt(at(1.0), st)))

    @Test
    def testWindowOnShowsTheWindowAgain(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        let st = Stage.empty() |> stageAfter(res, "window", "off" :: Nil) |> stageAfter(res, "window", "on" :: Nil);
        Assert.assertFalse(Stage.isWindowHidden(Clock.zero(), st))

    @Test
    def testSwitchingToTheSameTypeByItsAliasDoesNotTurnThePage(): Unit \ {Assert, Fs.FileRead} =
        // 空の舞台の Nvl は windows の最初の nvl の型なので、その型の名前へ替えても頁をめくらない。
        let res = TestKit.res();
        let nvl = fst(ThemeDoc.windowOf(ThemeDoc.kindAlias(ThemeDoc.WindowKind.Nvl), res#theme));
        Assert.assertEq(expected = Ok(Nil), exec(res, "window", nvl :: Nil, Stage.empty()) |> Result.map(snd))

    // ── メッセージ枠の型の Doc と Mark v3 の mode ──

    @Test
    def testAdvAliasReadsAsTheFirstAdvType(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        let firstAdv = ThemeDoc.rec(res#theme)#windows |> Map.toList |> List.find(match (_, w) -> w#kind == ThemeDoc.WindowKind.Adv) |> Option.map(fst);
        Assert.assertEq(expected = firstAdv, Some(fst(ThemeDoc.windowOf("Adv", res#theme))))

    def windowRows(text: String): Map[String, Util.Json.Json] =
        DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty())

    @Test
    def testWindowsNamedLikeTheOldModeAreDropped(): Unit \ Assert =
        let rows = windowRows("{ \"Adv\": { \"kind\": \"adv\" }, \"wide\": { \"kind\": \"adv\", \"place\": \"center\" } }");
        Assert.assertEq(expected = Set#{"wide"}, Map.keysOf(fst(ThemeDoc.windowsFrom(rows))))

    @Test
    def testWindowWithoutKindIsDropped(): Unit \ Assert =
        let rows = windowRows("{ \"wide\": { \"place\": \"center\" }, \"sub\": { \"kind\": \"adv\", \"frame\": \"outline\" } }");
        Assert.assertEq(expected = Set#{"sub"}, Map.keysOf(fst(ThemeDoc.windowsFrom(rows))))

    @Test
    def testRestoreReadsTheOldModeAsTheTypeName(): Unit \ {Assert, Fs.FileRead} =
        // Mark v3 の "Adv" は、戻した舞台では windows の最初の adv の型の名前になる。
        let res = TestKit.res();
        let old = { mode = "Adv" | Stage.empty() };
        Assert.assertEq(expected = fst(ThemeDoc.windowOf("Adv", res#theme)), Stage.withModeResolved(res#theme, old)#mode)

    @Test
    def testLineWithoutQuotesKeepsTheText(): Unit \ Assert =
        let line = { speaker = "a", text = "やあ", parts = Nil, tags = Nil, source = { file = "t", line = 1 } };
        Assert.assertEq(expected = "やあ", Page.lineOf("A", false, line)#text)

    @Test
    def testLineWithQuotesIsWrapped(): Unit \ Assert =
        let line = { speaker = "a", text = "やあ", parts = Nil, tags = Nil, source = { file = "t", line = 1 } };
        Assert.assertEq(expected = "「やあ」", Page.lineOf("A", true, line)#text)

    // ── <<text>> ──

    @Test
    def testTextWithoutArgumentsIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(exec(TestKit.res(), "text", Nil, Stage.empty())))

    @Test
    def testTextUnknownSizeIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(exec(TestKit.res(), "text", "size=nosuch" :: Nil, Stage.empty())))

    @Test
    def testTextSizeScalesByTheDoc(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        let (name, scale) = KindDoc.rec(res#kind)#textSizes |> Map.toList |> List.head |> Option.getWithDefault(("", 1.0));
        Assert.assertEq(expected = scale, Stage.textScaleOf(res#kind, stageAfter(res, "text", "size=${name}" :: Nil, Stage.empty())))

    @Test
    def testTextSpeedIsKept(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = 0.5, Stage.textSpeedAt(Clock.zero(), stageAfter(TestKit.res(), "text", "speed=0.5" :: Nil, Stage.empty())))

    @Test
    def testTextLockHoldsTheText(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Stage.isTextLocked(at(0.5), stageAfter(TestKit.res(), "text", "lock=1" :: Nil, Stage.empty())))

    // ── <<speak>> と話し手 ──

    @Test
    def testSpeakWritesTheSpeaker(): Unit \ {Assert, Fs.FileRead} =
        let st = stageAfter(castRes(), "speak", "cup" :: Nil, Stage.empty());
        Assert.assertEq(expected = Some("cup"), PropertyTween.nameAt(Clock.zero(), Stage.speakerKey(), st#props))

    @Test
    def testSpeakWithSpeakFxButNoMouthIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(exec(castRes(), "speak", "b" :: Nil, Stage.empty())))

    @Test
    def testSpeakPutsTheSpeakFxAtTheMouth(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        let fx = CastDoc.rec(res#cast)#cast |> Map.get("a") |> Option.flatMap(e -> e#speakFx) |> Option.getWithDefault("");
        let st = stageAfter(res, "speak", "a" :: Nil, Stage.empty());
        Assert.assertEq(expected = Some("a.mouth"), PropertyTween.nameAt(Clock.zero(), Stage.fxOnceAtKey(fx), st#props))

    @Test
    def testSameSpeakerIsNotWrittenAgain(): Unit \ Assert =
        let once = Stage.withSpeaker(Clock.zero(), Some("a"), Stage.empty());
        let again = Stage.withSpeaker(at(3.0), Some("a"), once);
        Assert.assertEq(expected = PropertyTween.nameSince(at(3.0), Stage.speakerKey(), once#props), PropertyTween.nameSince(at(3.0), Stage.speakerKey(), again#props))

    @Test
    def testOthersDimWhileTheSpeakerIsShown(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        let h = CastDoc.rec(res#cast)#highlight;
        let st = Stage.withSpeaker(Clock.zero(), Some("b"), twoShown(res));
        let late = at(h#seconds + 1.0);
        Assert.assertTrue(TestKit.near(1.0 - h#dim, Cast.brightnessOf(castEnv(res, late, st), st#cast, CastDoc.Kind.Character, "a")))

    @Test
    def testTheSpeakerStaysBright(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        let st = Stage.withSpeaker(Clock.zero(), Some("b"), twoShown(res));
        Assert.assertEq(expected = 1.0, Cast.brightnessOf(castEnv(res, at(5.0), st), st#cast, CastDoc.Kind.Character, "b"))

    @Test
    def testNobodyDimsWhenTheSpeakerIsNotShown(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        let st = Stage.withSpeaker(Clock.zero(), Some("someone"), twoShown(res));
        Assert.assertEq(expected = 1.0, Cast.brightnessOf(castEnv(res, at(5.0), st), st#cast, CastDoc.Kind.Character, "a"))

    @Test
    def testDimmingIsHalfwayAtHalfTheSeconds(): Unit \ {Assert, Fs.FileRead} =
        // 話し手が a から b へ替わると、a は highlight の seconds の半分で dim の半分だけ暗い。
        let res = castRes();
        let h = CastDoc.rec(res#cast)#highlight;
        let st = twoShown(res) |> Stage.withSpeaker(Clock.zero(), Some("a")) |> Stage.withSpeaker(at(1.0), Some("b"));
        let mid = at(1.0 + h#seconds / 2.0);
        Assert.assertTrue(TestKit.near(1.0 - h#dim / 2.0, Cast.brightnessOf(castEnv(res, mid, st), st#cast, CastDoc.Kind.Character, "a")))

    @Test
    def testNarrationWritesNoSpeaker(): Unit \ {Assert, Fs.FileRead} =
        // 地の文の台詞は cast.speaker を None にする（台本の最初の台詞までに話し手が出ない作例を通る）。
        let res = TestKit.res();
        let w = TestKit.begun(res);
        let narration = World.pageOf(w)#current |> Option.exists(line -> String.isEmpty(line#speaker));
        let speaker = PropertyTween.nameEnd(Stage.speakerKey(), World.stageOf(res, w)#props);
        Assert.assertTrue(not narration or Option.isEmpty(speaker))

    @Test
    def testTemplateSpeakFxArePointedParticles(): Unit \ {Assert, Fs.FileRead} =
        // テンプレートの novel.cast.json の speakFx は、どれも novel.effects.json の点から出せる粒（puff）。
        let res = TestKit.res();
        let d = CastDoc.rec(res#cast);
        let named = List.append(Map.valuesOf(d#cast), Map.valuesOf(d#props)) |> List.filterMap(e -> e#speakFx);
        let bad = named |> List.filter(n -> not (EffectsDoc.particleOf(n, res#effects) |> Option.exists(p -> EffectsDoc.isPointed(p#look))));
        Assert.assertEq(expected = Nil, bad)

    // ── hideWindow ──

    @Test
    def testPropWithHideWindowHidesTheWindow(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        let st = stageAfter(res, "show", "cup" :: "time=0" :: Nil, Stage.empty());
        Assert.assertTrue(Cast.hidesWindow(res#cast, st#cast))

    @Test
    def testCastWithoutHideWindowKeepsTheWindow(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        Assert.assertFalse(Cast.hidesWindow(res#cast, twoShown(res)#cast))

    // ── <<fx on=絵.点>> ──

    @Test
    def testFxOnAMarkerWritesThePoint(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        let name = puffName(res);
        let st = stageAfter(res, "fx", name :: "on=a.mouth" :: Nil, Stage.empty());
        Assert.assertEq(expected = Some("a.mouth"), PropertyTween.nameAt(Clock.zero(), Stage.particlesAtKey(), st#props))

    @Test
    def testFxOnAnUnknownMarkerIsAnError(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        Assert.assertTrue(Result.isErr(exec(res, "fx", puffName(res) :: "on=a.tail" :: Nil, Stage.empty())))

    @Test
    def testFxOnAMarkerWithASpreadLookIsAnError(): Unit \ {Assert, Fs.FileRead} =
        let res = castRes();
        Assert.assertTrue(Result.isErr(exec(res, "fx", spreadName(res) :: "on=a.mouth" :: Nil, Stage.empty())))

    @Test
    def testMarkerPointIsInsideTheShownPicture(): Unit \ {Assert, Fs.FileRead} =
        // 点の位置は、出ている絵の矩形の中の markers の割合の所。
        let res = castRes();
        let st = twoShown(res);
        let env = castEnv(res, at(5.0), st);
        let rect = Cast.placedOf(env, st#cast) |> List.find(p -> p#figure#name == "a") |> Option.map(p -> p#rect);
        let m = CastDoc.markerOf("a", "mouth", res#cast);
        let expected = forM (r <- rect; k <- m) yield (r#position#x + r#size#x * k#x, r#position#y + r#size#y * k#y);
        Assert.assertEq(expected = expected, Cast.markerPointOf(env, st#cast, "a", "mouth") |> Option.map(p -> (p#x, p#y)))
}
