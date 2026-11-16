// ゲームの口（GameView.backdrop・GameCommands.backdropSwitch・GameView.hud・GameView.objects・Commands.applyText・<<tween>>）と
// novel.backdrops.json の initial・title・aspect の配線: 差し替えの形（ViewStage.backdropsUsing・Commands.bgUsing・Commands.executeUsing・
// View.gameHudUsing・FlowVideo.objectsUsing）に偽の関数を差して、差した物が使われることを見る。
// このファイルはテンプレートの持ち物で、ゲームが口を埋めても落ちないように、テンプレートの既定（None・Nil）には頼らない。
// 背景の Doc には、テスト用の写真 2 枚（p0・p1）と時間帯 1 つ（g）を足し、initial と title を外して使う（ゲームの写真の数や欄には頼らない。
// ゲームの写真と時間帯は残すので、読み始めた World の台本の <<bg>> はそのまま当たる）。
mod TestGameHooks {

    use fge::{App, Clock, Emit, Flow, Num, RawDraw, Rect2, Render, Resources, Yarn, YarnCommands, YarnRunner}
    use Commands.Out
    use TestKit.begun

    def res(): Res.Res \ Fs.FileRead =
        let base = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"));
        Res.withBackdrops(withTestPhotos(base#backdrops), base)

    /// 背景の Doc に写真 p0・p1（絵は無くてよい）と時間帯 g を足し、initial と title を外した物。
    def withTestPhotos(doc: BackdropDoc.Doc): BackdropDoc.Doc =
        let d = BackdropDoc.rec(doc);
        let photo = name -> { texture = "test_${name}", label = name, aspect = None, blank = false };
        BackdropDoc.Doc.Doc({ photos = d#photos |> Map.insert("p0", photo("p0")) |> Map.insert("p1", photo("p1"))
                                                |> Map.insert("dark", { texture = "", label = "暗闇", aspect = None, blank = true }),
                              grades = Map.insert("g", BackdropDoc.plainGrade(), d#grades), initial = None, title = None | d })

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def ctxAt(r: Res.Res, at: Float64): Commands.Ctx = { now = t(at), node = "", res = r, instant = false }

    def applied(r: Res.Res, at: Float64, name: String, args: List[String], st: Stage.Stage): Stage.Stage =
        Commands.execute(Commands.Replay.Live, ctxAt(r, at), command(name, args), st) |> Result.map(fst) |> Result.getWithDefault(st)

    def photoAt(_r: Res.Res, i: Int32): String = "p${Int32.toString(i)}"

    def grade(_r: Res.Res): String = "g"

    type alias SwitchOf = (Commands.Ctx, Option[Stage.Shot], Stage.Shot, Stage.Switch) -> Option[Stage.GameSwitch]

    def noSwitch(): SwitchOf = (_, _, _, _) -> None

    def walk(seconds: Float64): SwitchOf =
        (_, _, _, _) -> Some({ seconds = seconds, sounds = { at = 0.2, sound = "se_a" } :: { at = 1.5, sound = "se_b" } :: Nil })

    /// switchOf を差した <<bg>> を at 秒に当てる（ゲームの GameCommands に左右されない）。
    def bgBy(r: Res.Res, switchOf: SwitchOf, instant: Bool, at: Float64, args: List[String], st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        let c = Commands.bgUsing(switchOf);
        forM (a <- YarnCommands.parse(c#spec, command("bg", args)); done <- c#apply({ instant = instant | ctxAt(r, at) }, a, st)) yield done

    def bgTo(r: Res.Res, at: Float64, args: List[String], st: Stage.Stage): Stage.Stage =
        bgBy(r, noSwitch(), false, at, args, st) |> Result.map(fst) |> Result.getWithDefault(st)

    /// 写真 0 番へすぐ替えた舞台。
    def firstShown(r: Res.Res): Stage.Stage = bgTo(r, 0.0, photoAt(r, 0) :: "grade=${grade(r)}" :: "transition=cut" :: Nil, Stage.empty())

    /// 写真 0 番から 1 番へ、1.0 秒に switchOf で替えた時（args = transition などの足す引数）。
    def ownedBy(r: Res.Res, switchOf: SwitchOf, instant: Bool, args: List[String]): Result[String, (Stage.Stage, List[Out])] =
        bgBy(r, switchOf, instant, 1.0, photoAt(r, 1) :: args, firstShown(r))

    def ownedStage(r: Res.Res, args: List[String]): Stage.Stage =
        ownedBy(r, walk(3.0), false, args) |> Result.map(fst) |> Result.getWithDefault(Stage.empty())

    def envOf(r: Res.Res, at: Float64): View.Env = { storyNow = t(at) | View.envOf(Layout.Fit.Regular, r, TestKit.w0(r)) }

    def withBackdrops(f: BackdropDoc.Rec -> BackdropDoc.Rec, r: Res.Res): Res.Res = Res.withBackdrops(BackdropDoc.Doc.Doc(f(BackdropDoc.rec(r#backdrops))), r)

    def withInitial(r: Res.Res): Res.Res = withBackdrops(d -> { initial = Some({ photo = photoAt(r, 1), grade = grade(r) }) | d }, r)

    def withoutInitial(r: Res.Res): Res.Res = withBackdrops(d -> { initial = None | d }, r)

    def screenArea(): Option[Float64] -> Rect2.Rect2 = _ -> Layout.screen(Layout.Fit.Regular)

    /// photo 1 番だけ x = 1000、ほかは x = 2000 に、z 1 の印を置くゲームの絵。
    def marker(r: Res.Res): ViewStage.BackdropPainter = (_, _, photo, _) ->
        Some(View.at(if (photo == photoAt(r, 1)) 1000.0 else 2000.0, 0.0, RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 0.0, b = 1.0 }, 1)) :: Nil)

    def noPaint(): ViewStage.BackdropPainter = (_, _, _, _) -> None

    def xsOf(items: List[Render.PlacedItem]): List[Float64] = items |> List.map(p -> p#at#x)

    def zOfBox(items: List[Render.PlacedItem], x: Float64): List[Int32] = items |> List.filter(p -> p#at#x == x) |> List.map(p -> ViewStage.zOf(p#item))

    // ══ novel.backdrops.json の initial・title・aspect ══

    @Test
    def testInitialIsReadFromTheDoc(): Unit \ Assert =
        let doc = BackdropDoc.fromJson("{\"initial\": {\"photo\": \"lair\", \"grade\": \"clear\"}}");
        Assert.assertEq(expected = Some(Some(("lair", "clear"))), doc |> Option.map(d -> BackdropDoc.initialOf(d) |> Option.map(i -> (i#photo, i#grade))))

    @Test
    def testTitleIsReadFromTheDoc(): Unit \ Assert =
        let doc = BackdropDoc.fromJson("{\"title\": {\"scale\": 1.05, \"drift\": {\"amp\": [10, 6], \"rate\": [0.13, 0.09], \"phase\": [0, 1.0]}}}");
        Assert.assertEq(expected = Some(Some((1.05, 6.0, 1.0))), doc |> Option.map(d -> BackdropDoc.titleOf(d) |> Option.map(x -> (x#scale, x#drift#amp#y, x#drift#phase#y))))

    @Test
    def testAspectIsReadPerPhoto(): Unit \ Assert =
        let doc = BackdropDoc.fromJson("{\"photos\": {\"a\": {\"texture\": \"t\", \"aspect\": 0.5}, \"b\": {\"texture\": \"t\"}}}");
        Assert.assertEq(expected = Some((Some(0.5), None)), doc |> Option.map(d -> (BackdropDoc.aspectOf("a", d), BackdropDoc.aspectOf("b", d))))

    @Test
    def testInitialIsShownWhileThereIsNoBackdrop(): Unit \ {Assert, Fs.FileRead} =
        let r = withInitial(res());
        Assert.assertEq(expected = Some(photoAt(r, 1)), Stage.shownShot(r#backdrops, Stage.empty()) |> Option.map(s -> s#photo))

    @Test
    def testWithoutInitialNothingIsShownBeforeTheFirstBg(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Option.isEmpty(Stage.shownShot(withoutInitial(res())#backdrops, Stage.empty())))

    @Test
    def testTheFirstBgCrossesFromTheInitialBackdrop(): Unit \ {Assert, Fs.FileRead} =
        let r = withInitial(res());
        let st = bgTo(r, 0.0, photoAt(r, 0) :: Nil, Stage.empty());
        Assert.assertEq(expected = (Some(photoAt(r, 1)), Some(grade(r))), (st#under |> Option.map(s -> s#photo), st#shot |> Option.map(s -> s#grade)))

    @Test
    def testTallPhotoCoversTheScreenCentered(): Unit \ {Assert, Fs.FileRead} =
        // aspect 0.5 の写真は、横の画面の幅を覆い、上下をはみ出して真ん中に置く。
        let base = res();
        let r = withBackdrops(d -> { photos = Map.adjust(p -> { aspect = Some(0.5) | p }, photoAt(base, 0), d#photos) | d }, base);
        let surfaces = ViewStage.backdropsUsing(noPaint(), ViewStage.photoRect(Layout.Fit.Regular), envOf(r, 10.0), firstShown(r)) |> List.filterMap(p -> match p#item {
            case Render.Item.Shader(x) => Some((p#at#y, x#rect#size#y))
            case _                     => None
        });
        let h = Layout.height(Layout.Fit.Regular);
        Assert.assertTrue(surfaces |> List.exists(match (y, sh) -> sh > h and TestKit.near(h / 2.0, y + sh / 2.0)))

    @Test
    def testTitleFrameWithoutTitleIsTheFrame(): Unit \ {Assert, Fs.FileRead} =
        let r = withBackdrops(d -> { title = None | d }, res());
        let st = firstShown(r);
        Assert.assertEq(expected = xsOf(ViewStage.frame(envOf(r, 1.0), st, true)), xsOf(ViewStage.titleFrame(envOf(r, 1.0), st)))

    @Test
    def testTitleScalesAndDriftsTheBackdrop(): Unit \ {Assert, Fs.FileRead} =
        // 実時間 0 秒（envOf の realNow）の漂いは sin(0 × 0.13 + 0.4) × 10。画面の真ん中を軸に 1.05 倍してからずらす。
        let r = withBackdrops(d -> { title = Some({ scale = 1.05, drift = { amp = { x = 10.0, y = 6.0 }, rate = { x = 0.13, y = 0.09 }, phase = { x = 0.4, y = 1.0 } } }) | d }, res());
        let st = firstShown(r);
        let env = envOf(r, 1.0);
        let cx = Layout.width(Layout.Fit.Regular) * 0.5;
        let drift = Num.sin(View.realSeconds(env) * 0.13 + 0.4) * 10.0;
        let expected = xsOf(ViewStage.frame(env, st, true)) |> List.map(x -> cx + (x - cx) * 1.05 + drift);
        let actual = xsOf(ViewStage.titleFrame(env, st));
        Assert.assertTrue(List.length(expected) == List.length(actual) and List.zip(expected, actual) |> List.forAll(match (e, a) -> TestKit.near(e, a)))

    // ══ GameView.backdrop ══

    @Test
    def testGamePaintedBackdropIsDrawnInTheCurrentBand(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let st = bgTo(r, 0.0, photoAt(r, 1) :: "grade=${grade(r)}" :: "transition=cut" :: Nil, Stage.empty());
        Assert.assertEq(expected = View.zBackdropShot() + 1 :: Nil, zOfBox(ViewStage.backdropsUsing(marker(r), screenArea(), envOf(r, 5.0), st), 1000.0))

    @Test
    def testWithoutAGamePictureTheStillIsDrawn(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let items = ViewStage.backdropsUsing(noPaint(), screenArea(), envOf(r, 5.0), firstShown(r));
        Assert.assertTrue(items |> List.exists(p -> match p#item {
            case Render.Item.Shader(_) => true
            case _                     => false
        }))

    @Test
    def testABlankPhotoDrawsNothing(): Unit \ {Assert, Fs.FileRead} =
        // 絵を持たない写真（blank）は、写真の面を描かず（地の色だけが見える）、待つ絵の名前も無い。
        let r = res();
        let st = bgTo(r, 0.0, "dark" :: "grade=g" :: "transition=cut" :: Nil, Stage.empty());
        let shaders = ViewStage.backdropsUsing((_, _, _, _) -> None, screenArea(), envOf(r, 1.0), st) |> List.count(p -> match p#item {
            case Render.Item.Shader(_) => true
            case _                     => false
        });
        Assert.assertEq(expected = (0, None), (shaders, BackdropDoc.textureOf("dark", r#backdrops)))

    @Test
    def testTemplateTransitionsFadeTheGamePicture(): Unit \ {Assert, Fs.FileRead} =
        // テンプレートの fade の途中は、前の背景（写真 0 番 = x 2000）と今の背景（写真 1 番 = x 1000）の両方を描く。
        let r = res();
        let st = bgTo(r, 1.0, photoAt(r, 1) :: "transition=fade" :: "time=2" :: Nil, firstShown(r));
        let xs = xsOf(ViewStage.backdropsUsing(marker(r), screenArea(), envOf(r, 2.0), st));
        Assert.assertTrue(List.memberOf(1000.0, xs) and List.memberOf(2000.0, xs))

    // ══ GameCommands.backdropSwitch ══

    @Test
    def testGameOwnedSwitchWaitsWithALineWait(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Ok(Out.LineWait(3.0) :: Nil), ownedBy(res(), walk(3.0), false, Nil) |> Result.map(snd))

    @Test
    def testInstantDoesNotAskTheGame(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Ok(Nil), ownedBy(res(), walk(3.0), true, Nil) |> Result.map(snd))

    @Test
    def testWithoutTheGameTheSwitchIsTheScripts(): Unit \ {Assert, Fs.FileRead} =
        let st = ownedBy(res(), noSwitch(), false, "transition=slide" :: Nil) |> Result.map(fst) |> Result.getWithDefault(Stage.empty());
        Assert.assertEq(expected = (true, BackdropDoc.Transition.Slide), (Option.isEmpty(st#switch#game), st#switch#transition))

    @Test
    def testGameOwnedSwitchDrawsOnlyTheNewBackdrop(): Unit \ {Assert, Fs.FileRead} =
        // ゲームが持つ切り替えの途中は、前の背景（x 2000）を重ねず、今の背景（x 1000）だけを描く。
        let r = res();
        let xs = xsOf(ViewStage.backdropsUsing(marker(r), screenArea(), envOf(r, 2.0), ownedStage(r, Nil)));
        Assert.assertEq(expected = (true, false), (List.memberOf(1000.0, xs), List.memberOf(2000.0, xs)))

    @Test
    def testGameOwnedPanDoesNotSlideTheBackdrop(): Unit \ {Assert, Fs.FileRead} =
        // 台本が transition=pan でも、ゲームが持つ間は今の背景を横へずらさない（印は x 1000 のまま）。
        let r = res();
        let xs = xsOf(ViewStage.backdropsUsing(marker(r), screenArea(), envOf(r, 2.0), ownedStage(r, "transition=pan" :: "time=0.8" :: Nil)));
        Assert.assertEq(expected = (true, true), (List.memberOf(1000.0, xs), xs |> List.forAll(x -> x == 1000.0 or x <= 0.0)))

    @Test
    def testGameOwnedBlackDoesNotDarkenTheWorld(): Unit \ {Assert, Fs.FileRead} =
        // 台本が transition=black でも、ゲームが持つ間は暗転の箱（world の背景より手前の Box）を出さない。
        let r = res();
        let st = ownedStage(r, "transition=black" :: Nil);
        let veils = ViewStage.frame(envOf(r, 2.5), st, true) |> List.filter(p -> match p#item {
            case Render.Item.Box(b) => b#zIndex >= View.zWorldStride()
            case _                  => false
        });
        Assert.assertEq(expected = 0, List.length(veils))

    @Test
    def testGameOwnedCutKeepsTheGamesSeconds(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(TestKit.near(3.0, ownedStage(res(), "transition=cut" :: Nil)#fadeSeconds))

    @Test
    def testGameOwnedSwitchSoundsAreCutByTheStoryClock(): Unit \ {Assert, Fs.FileRead} =
        // 1.0 秒に始めた切り替えの音（0.2 秒と 1.5 秒）を、物語の時刻 0.5〜1.5 と 1.5〜2.0 と 2.0〜3.0 で分けて出す。
        let st = ownedStage(res(), Nil);
        let between = (a, b) -> Stage.gameSwitchSoundsBetween(t(a), t(b), st);
        Assert.assertEq(expected = ("se_a" :: Nil, Nil, "se_b" :: Nil), (between(0.5, 1.5), between(1.5, 2.0), between(2.0, 3.0)))

    // ══ World を通す（Silent とスキップの instant・歩く間の待ちと音） ══

    /// ctx#instant を game.instant（1 か 0）に書く命令。
    def probe(): Commands.Command[Stage.Stage] =
        { spec = YarnCommands.spec("probe", "instant を書く", Nil), timing = Commands.Timing.Instant,
          apply = (ctx, _, st) -> Ok(({ props = PropertyTween.setNum(PropertyTween.numKey("game.instant"), if (ctx#instant) 1.0 else 0.0, ctx#now, 0.0, st#props) | st }, Nil)),
          needs = Commands.noAssets }

    def probed(r: Res.Res, replay: Commands.Replay): Float64 =
        Commands.executeUsing(probe() :: Nil, replay, ctxAt(r, 0.0), command("probe", Nil), Stage.empty())
            |> Result.map(match (st, _) -> PropertyTween.numEnd(PropertyTween.numKey("game.instant"), -1.0, st#props)) |> Result.getWithDefault(-1.0)

    @Test
    def testSilentReplayRaisesInstant(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = (1.0, 0.0), (probed(r, Commands.Replay.Silent), probed(r, Commands.Replay.Live)))

    @Test
    def testSkippingRaisesInstant(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let w = begun(r);
        let instantWhen = (mode: World.Playback) -> World.readOf(w) |> Option.map(rd -> WorldRead.ctxOf(r, { playback = mode | rd }, w)#instant);
        Assert.assertEq(expected = (Some(true), Some(false)), (instantWhen(World.Playback.Skip), instantWhen(World.Playback.Manual)))

    /// 読み始めた所から、出来事 events を新しいビートとして流し始めた World（入力 1 回で実行器が返した束と同じ扱い）。
    def beatWith(r: Res.Res, events: List[YarnRunner.Event]): World.World = TestKit.quiet(() -> WorldRead.beginBeat(r, events, begun(r)))

    /// 読み始めた所で、ゲームが持つ 3 秒の切り替え（<<bg p1>>）と、その後の台詞 1 行（.yarn の 99 行目）を流し始めた World。
    def walking(r: Res.Res): World.World =
        beatWith(withWalk(3.0, r), YarnRunner.Event.Command(command("bg", photoAt(r, 1) :: "grade=${grade(r)}" :: Nil)) :: YarnRunner.Event.Line(heldLine()) :: Nil)

    /// <<bg>> がゲームの seconds 秒の切り替えで歩く描く元。
    def withWalk(seconds: Float64, r: Res.Res): Res.Res =
        { commands = Commands.tableOf(Commands.bgUsing(walk(seconds)) :: Commands.commandsIn(r#commands)) | r }

    /// 読み始めた所で、outs を出す命令とその後の台詞 1 行を流し始めた World。
    def waitingByAll(r: Res.Res, outs: List[Out]): World.World =
        let withOuts = { commands = Commands.tableOf(outsCommand("waitout", outs) :: Commands.commandsIn(r#commands)) | r };
        beatWith(withOuts, YarnRunner.Event.Command(command("waitout", Nil)) :: YarnRunner.Event.Line(heldLine()) :: Nil)

    def waitingBy(r: Res.Res, out: Out): World.World = waitingByAll(r, out :: Nil)

    /// 明けたら出す台詞 1 行（.yarn の 99 行目「歩いた後の行。」）。
    def heldLine(): Yarn.Line = { speaker = "", text = "歩いた後の行。", parts = Nil, tags = Nil, source = { file = "test", line = 99 } }

    /// out を 1 つ出すだけの命令 name。
    def waitCommand(name: String, out: Out): Commands.Command[Stage.Stage] = outsCommand(name, out :: Nil)

    def outsCommand(name: String, outs: List[Out]): Commands.Command[Stage.Stage] =
        { spec = YarnCommands.spec(name, "待ちを出す", Nil), timing = Commands.Timing.Timed,
          apply = (_, _, st) -> Ok((st, outs)), needs = Commands.noAssets }

    /// 押すと明ける待ちを出す tapwait と、押しても明けない待ちを出す hardwait を、読み進める命令の表に足した描く元。
    def withWaitCommands(r: Res.Res): Res.Res =
        { commands = Commands.tableOf(waitCommand("tapwait", Out.WaitOrTap(5.0)) :: waitCommand("hardwait", Out.Wait(5.0)) :: Commands.commandsIn(r#commands)) | r }

    /// 読み始めた所で押すと明ける 5 秒の待ち（tapwait）と、その後の出来事 rest を流し始めた World。
    def tapWaitingWith(r: Res.Res, rest: List[YarnRunner.Event]): World.World =
        beatWith(withWaitCommands(r), YarnRunner.Event.Command(command("tapwait", Nil)) :: rest)

    def isPaused(w: World.World): Bool = WorldRead.isPaused(w)

    def currentText(w: World.World): String = World.pageOf(w)#current |> Option.map(l -> l#text) |> Option.getWithDefault("")

    def cuesOf(events: List[World.Event]): List[String] = events |> List.filterMap(e -> match e {
        case World.Event.Cue(name) => Some(name)
        case _                     => None
    })

    def stepHearing(r: Res.Res, dt: Float64, w: World.World): (World.World, List[String]) =
        let (next, events) = TestKit.stepHearing(r, dt, w);
        (next, cuesOf(events))

    @Test
    def testSkippingAWalkFinishesIt(): Unit \ {Assert, Fs.FileRead} =
        // スキップで歩きの待ちを飛ばすと、切り替えも終わりの形になる（前の背景を持たない）。
        let r = res();
        let skipped = World.mapRead(rd -> { playback = World.Playback.Skip | rd }, walking(r));
        let after = TestKit.stepBy(r, 0.01, skipped);
        Assert.assertEq(expected = Some(true), World.readOf(after) |> Option.map(rd -> Option.isEmpty(rd#stage#under)) |> Option.map(under -> under and not isPaused(after)))

    @Test
    def testWalkSoundRingsOnceOnTheStoryClock(): Unit \ {Assert, Fs.FileRead} =
        // 0.2 秒の音は、最初の 0.5 秒のフレームで 1 回だけ鳴り、次の 0.5 秒では鳴らない。
        let r = res();
        let (w1, first) = stepHearing(r, 0.5, walking(r));
        let (_, second) = stepHearing(r, 0.5, w1);
        Assert.assertEq(expected = ("se_a" :: Nil, Nil), (first, second))

    @Test
    def testWalkSoundWaitsWhileAScreenIsOpen(): Unit \ {Assert, Fs.FileRead} =
        // 画面（ログ）を開いている間は物語の時計が止まるので、歩きの音は鳴らない。
        let r = res();
        let opened = TestKit.quiet(() -> WorldLog.openLog(walking(r)));
        let (_, heard) = stepHearing(r, 2.0, opened);
        Assert.assertEq(expected = Nil, heard)

    // ══ 押すと明ける待ち（Out.WaitOrTap） ══

    @Test
    def testWithoutATapTheWalkEndsByItsSeconds(): Unit \ {Assert, Fs.FileRead} =
        // 押さなければ、1 秒では明けず、3 秒の後に明けて預けた台詞を出す。
        let r = res();
        let early = TestKit.stepBy(r, 1.0, walking(r));
        let ended = TestKit.stepBy(r, 2.5, early);
        Assert.assertEq(expected = (true, false, "歩いた後の行。"), (isPaused(early), isPaused(ended), currentText(ended)))

    @Test
    def testATapEndsTheWalk(): Unit \ {Assert, Fs.FileRead} =
        // 歩いている途中に押すと、待ちが明けて預けた台詞を出す。
        let r = res();
        let pressed = TestKit.advance(r, TestKit.stepBy(r, 1.0, walking(r)));
        Assert.assertEq(expected = (false, "歩いた後の行。"), (isPaused(pressed), currentText(pressed)))

    @Test
    def testATapLeavesTheWalkFinished(): Unit \ {Assert, Fs.FileRead} =
        // 押して明けた時は、ゲームが持つ切り替えも終わりの形（前の背景を持たない）。
        let r = res();
        let pressed = TestKit.advance(r, TestKit.stepBy(r, 1.0, walking(r)));
        Assert.assertEq(expected = Some(true), World.readOf(pressed) |> Option.map(rd -> Option.isEmpty(rd#stage#under)))

    @Test
    def testATapDoesNotEndAPlainWait(): Unit \ {Assert, Fs.FileRead} =
        // Out.Wait の待ちは押しても明けない。
        let r = res();
        let pressed = TestKit.advance(r, TestKit.stepBy(r, 1.0, waitingBy(r, Out.Wait(3.0))));
        Assert.assertTrue(isPaused(pressed))

    @Test
    def testATapWaitWithAPlainWaitIsNotTappable(): Unit \ {Assert, Fs.FileRead} =
        // 1 つのコマンドが Wait と WaitOrTap を両方出したら、押しても明けない待ち。
        let r = res();
        Assert.assertTrue(isPaused(TestKit.advance(r, waitingByAll(r, Out.WaitOrTap(3.0) :: Out.Wait(1.0) :: Nil))))

    @Test
    def testAPlainWaitThenATapWaitIsNotTappable(): Unit \ {Assert, Fs.FileRead} =
        // Wait の後に WaitOrTap を出しても、押しても明けない待ち（出した順に左右されない）。
        let r = res();
        Assert.assertTrue(isPaused(TestKit.advance(r, waitingByAll(r, Out.Wait(1.0) :: Out.WaitOrTap(3.0) :: Nil))))

    @Test
    def testOneTapPassesTheTapWaitsThatFollow(): Unit \ {Assert, Fs.FileRead} =
        // 押すと明ける待ちの後に、押すと明ける待ちを出す命令が 2 つと台詞が続く時、1 回押すと台詞まで出て、字も出し切る。
        let r = withWaitCommands(res());
        let rest = YarnRunner.Event.Command(command("tapwait", Nil)) :: YarnRunner.Event.Command(command("tapwait", Nil))
            :: YarnRunner.Event.Line(heldLine()) :: Nil;
        let pressed = TestKit.advance(r, tapWaitingWith(r, rest));
        Assert.assertEq(expected = (false, "歩いた後の行。", true), (isPaused(pressed), currentText(pressed), Page.isDone(World.pageOf(pressed))))

    @Test
    def testOneTapStopsAtAPlainWait(): Unit \ {Assert, Fs.FileRead} =
        // 続いた待ちが押しても明けない待ちなら、そこで止まり、後ろの台詞はまだ出さない。
        let r = withWaitCommands(res());
        let rest = YarnRunner.Event.Command(command("hardwait", Nil)) :: YarnRunner.Event.Line(heldLine()) :: Nil;
        let pressed = TestKit.advance(r, tapWaitingWith(r, rest));
        Assert.assertEq(expected = (true, false), (isPaused(pressed), currentText(pressed) == "歩いた後の行。"))

    @Test
    def testATapWaitFromAGameCommandEndsOnATap(): Unit \ {Assert, Fs.FileRead} =
        // ゲームのコマンドが出す WaitOrTap（ゲームが持つ切り替えは無い）も、押すと明ける。
        let r = res();
        let pressed = TestKit.advance(r, waitingBy(r, Out.WaitOrTap(5.0)));
        Assert.assertEq(expected = "歩いた後の行。", currentText(pressed))

    @Test
    def testTheWalkDoesNotGoOnWhileAScreenIsOpen(): Unit \ {Assert, Fs.FileRead} =
        // 画面（ログ）を開いている間は、秒が過ぎても押しても待ちは明けない。
        let r = res();
        let opened = TestKit.quiet(() -> WorldLog.openLog(walking(r)));
        let w = TestKit.advance(r, TestKit.stepBy(r, 5.0, opened));
        Assert.assertTrue(isPaused(w))

    @Test
    def testAutoDoesNotTapThroughTheWalk(): Unit \ {Assert, Fs.FileRead} =
        // オートは押す代わりに送っても、押すと明ける待ちを秒より先には明けない。
        let r = res();
        let auto = World.mapRead(rd -> { playback = World.Playback.Auto | rd }, walking(r));
        Assert.assertTrue(isPaused(TestKit.stepBy(r, 2.0, auto)))

    @Test
    def testTheFlowReaderDoesNotTapDuringATapWait(): Unit \ {Assert, Fs.FileRead} =
        // flow の reader は押すと明ける待ちの間は押さない（基準の版と同じく、待ちの秒を流す）。
        let r = res();
        let w = walking(r);
        Assert.assertEq(expected = (true, false), (WorldRead.isTapWait(w), readerTaps(r, w)))

    /// flow の reader が、読み始めてから十分たった所で押すか。
    def readerTaps(r: Res.Res, w: World.World): Bool =
        E2e.table()#drives |> List.exists(d -> match d#act(10.0, Resources.of(r, w)) {
            case Flow.DriveAct.Tap(_) => true
            case _                    => false
        })

    @Test
    def testTheFlowReaderDoesNotTapDuringAPlainWait(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertFalse(readerTaps(r, waitingBy(r, Out.Wait(3.0))))

    @Test
    def testTheFlowReaderTapsAfterTheWaitEnds(): Unit \ {Assert, Fs.FileRead} =
        // 待ちが明けて預けた台詞を出し終えたら、今まで通り押す。
        let r = res();
        let ended = TestKit.stepBy(r, 30.0, waitingBy(r, Out.WaitOrTap(3.0)));
        Assert.assertTrue(readerTaps(r, ended))

    /// flow の ready が Busy か（入力を受けられない）。
    def isBusy(r: Res.Res, w: World.World): Bool =
        E2e.table()#ready |> Option.exists(ready -> match ready(Resources.of(r, w)) {
            case Flow.Ready.Busy(_) => true
            case Flow.Ready.Ready   => false
        })

    @Test
    def testTheFlowIsBusyDuringAWait(): Unit \ {Assert, Fs.FileRead} =
        // 命令が出した待ちの間は、flow の tap を待たせる（Busy）。明けて台詞を出し終えたら Ready。
        let r = res();
        let w = waitingBy(r, Out.LineWait(3.0));
        Assert.assertEq(expected = (true, false), (isBusy(r, w), isBusy(r, TestKit.stepBy(r, 30.0, w))))

    @Test
    def testTheFlowIsBusyDuringTheRunnersWait(): Unit \ {Assert, Fs.FileRead} =
        // 実行器の <<wait>> の間も Busy（台本 test/fixtures/switch の Enter: 台詞を送ると <<wait 0.9>>）。
        let r = res() |> Res.withDialogue(Yarn.loadOr(Yarn.empty(), "test/fixtures/switch/dialogue.json")) |> TestKit.withOpening("Enter");
        Assert.assertTrue(isBusy(r, TestKit.advance(r, begun(r))))

    // ══ 次の台詞を待たせる待ち（Out.LineWait。bg がゲームの切り替えで出す・ゲームのコマンドも出せる）の間に流す命令 ══

    /// 合図 name を出すだけの命令（timing で時間を取るかを決める）。
    def signalCommand(name: String, timing: Commands.Timing): Commands.Command[Stage.Stage] =
        { spec = YarnCommands.spec(name, "合図を出す", Nil), timing = timing,
          apply = (_, _, st) -> Ok((st, Out.Event(name) :: Nil)), needs = Commands.noAssets }

    /// 3 秒の切り替えの待ちを出す walk・時間を取らない合図 quick・時間を取る合図 slow を、読み進める命令の表に足した描く元。
    def withSwitchCommands(r: Res.Res): Res.Res =
        { commands = Commands.tableOf(waitCommand("walk", Out.LineWait(3.0)) :: signalCommand("quick", Commands.Timing.Instant)
                                      :: signalCommand("slow", Commands.Timing.Timed) :: Commands.commandsIn(r#commands)) | r }

    /// 読み始めた所で、walk と rest の命令と台詞を流し始めた World（walk を当てた所）と、そこで出た合図。
    def walkedInto(r: Res.Res, rest: List[String]): (World.World, List[String]) =
        walkedIntoEvents(r, rest |> List.map(name -> YarnRunner.Event.Command(command(name, Nil))))

    /// walkedInto の、walk の後ろの出来事 rest を直に渡す形（rest の後ろに台詞 1 行）。
    def walkedIntoEvents(r: Res.Res, rest: List[YarnRunner.Event]): (World.World, List[String]) =
        let events = YarnRunner.Event.Command(command("walk", Nil)) :: rest ::: (YarnRunner.Event.Line(heldLine()) :: Nil);
        let (next, heard) = Emit.collect(() -> WorldRead.beginBeat(r, events, begun(r)));
        (next, heard |> List.filterMap(e -> match e {
            case World.Event.Signal(name) => Some(name)
            case _                        => None
        }))

    @Test
    def testASoundAfterTwoCommentsRingsWithTheFirst(): Unit \ {Assert, Fs.FileRead} =
        // コメント A・コメント B（どちらも音を鳴らして LineWait 1 秒）の後ろの効果音は、A と同じ頭で鳴り、B は 1 秒後に鳴る。
        let base = res();
        let r = { commands = Commands.tableOf(outsCommand("commentA", Out.Sound("se_a") :: Out.LineWait(1.0) :: Nil)
                                              :: outsCommand("commentB", Out.Sound("se_b") :: Out.LineWait(1.0) :: Nil)
                                              :: outsCommand("quick", Out.Sound("se_x") :: Nil) :: Commands.commandsIn(base#commands)) | base };
        let events = YarnRunner.Event.Command(command("commentA", Nil)) :: YarnRunner.Event.Command(command("commentB", Nil))
            :: YarnRunner.Event.Command(command("quick", Nil)) :: YarnRunner.Event.Line(heldLine()) :: Nil;
        let (begun0, atStart) = Emit.collect(() -> WorldRead.beginBeat(r, events, begun(r)));
        let (w1, first) = stepHearing(r, 0.5, begun0);
        let (_, second) = stepHearing(r, 1.0, w1);
        Assert.assertEq(expected = ("se_a" :: "se_x" :: Nil, "se_b" :: Nil), (cuesOf(atStart) ::: first, second))

    @Test
    def testAGameCommandLineWaitLetsTheAudioThrough(): Unit \ {Assert, Fs.FileRead} =
        // ゲームのコマンド（コメントを 1 件流して 0.65 秒置く形）が LineWait を出すと、後ろの <<audio>> は待たずに流れ、台詞だけが待つ。
        let base = res();
        let r = { commands = Commands.tableOf(waitCommand("comment", Out.LineWait(0.65)) :: Commands.commandsIn(base#commands)) | base };
        let events = YarnRunner.Event.Command(command("comment", Nil)) :: YarnRunner.Event.Command(command("audio", "ambience" :: "amb_river" :: Nil))
            :: YarnRunner.Event.Line(heldLine()) :: Nil;
        let w = TestKit.stepBy(r, 0.2, beatWith(r, events));
        let ambience = World.readOf(w) |> Option.flatMap(rd -> Stage.ambienceOf(World.now(w), rd#stage));
        Assert.assertEq(expected = (Some("amb_river"), true), (ambience, isPaused(w)))

    @Test
    def testInstantCommandsRunDuringTheSwitch(): Unit \ {Assert, Fs.FileRead} =
        // 切り替えの待ちの間も、後ろの時間を取らない命令は先に流れ、台詞は頁に積むが字は出さない。
        let (w, signals) = walkedInto(withSwitchCommands(res()), "quick" :: Nil);
        Assert.assertEq(expected = ("quick" :: Nil, true, 0), (signals, isPaused(w), Page.visibleCount(World.pageOf(w))))

    @Test
    def testATimedCommandAlsoRunsDuringTheSwitch(): Unit \ {Assert, Fs.FileRead} =
        // 時間を取る命令も切り替えの頭で流れ、その後ろの時間を取らない命令も流れる。
        let (_, signals) = walkedInto(withSwitchCommands(res()), "slow" :: "quick" :: Nil);
        Assert.assertEq(expected = "slow" :: "quick" :: Nil, signals)

    @Test
    def testTheLineComesAfterTheSwitch(): Unit \ {Assert, Fs.FileRead} =
        let r = withSwitchCommands(res());
        let (w, _) = walkedInto(r, "quick" :: Nil);
        Assert.assertEq(expected = "歩いた後の行。", currentText(TestKit.stepBy(r, 3.5, w)))

    @Test
    def testAPlainTapWaitHoldsTheInstantCommands(): Unit \ {Assert, Fs.FileRead} =
        // ゲームのコマンドが出す WaitOrTap の後ろの時間を取らない命令は、待ちが明けてから流れる。
        let r = { commands = Commands.tableOf(waitCommand("walk", Out.WaitOrTap(3.0)) :: signalCommand("quick", Commands.Timing.Instant)
                                              :: Commands.commandsIn(res()#commands)) | res() };
        let (_, signals) = walkedInto(r, "quick" :: Nil);
        Assert.assertEq(expected = Nil, signals)

    @Test
    def testAudioCommandsDuringTheSwitchKeepTheWait(): Unit \ {Assert, Fs.FileRead} =
        // 切り替えの間に流した <<audio>>（命令の出来事になる物）の後も、待ちの秒が明けるまで台詞は出ない。
        let r = withSwitchCommands(res());
        let rest = YarnRunner.Event.Command(command("audio", "ambience" :: "amb_river" :: Nil)) :: YarnRunner.Event.Command(command("audio", "all" :: "off" :: Nil))
            :: YarnRunner.Event.Command(command("wait", "0.8" :: Nil)) :: Nil;
        let (w, _) = walkedIntoEvents(r, rest);
        let later = TestKit.stepBy(r, 1.0, w);
        Assert.assertEq(expected = (true, false), (isPaused(later), currentText(later) == "歩いた後の行。"))

    @Test
    def testAWalkingBgInTheScriptWaitsThroughSetAndAudio(): Unit \ {Assert, Fs.FileRead} =
        // 台本（test/fixtures/switch）の歩く <<bg>>（5.4 秒）→ <<set>> → <<audio>> 2 つ → <<wait 0.8>> → 台詞を実行器から流す:
        // 送ってから 1 秒では台詞が出ず、6.5 秒では出ている。
        let base = res() |> Res.withDialogue(Yarn.loadOr(Yarn.empty(), "test/fixtures/switch/dialogue.json")) |> TestKit.withOpening("Walk");
        let r = { commands = Commands.tableOf(Commands.bgUsing(walk(5.4)) :: Commands.commandsIn(base#commands)) | base };
        let walked = TestKit.advance(r, begun(r));
        let early = stepFrames(r, 30, walked);
        let late = stepFrames(r, 165, early);
        Assert.assertEq(expected = ("「歩く前の行。」", "「歩いた後の行。」"), (currentText(early), currentText(late)))

    @Test
    def testAWalkingBgAtTheHeadOfAJumpedNodeWaitsThroughSetAndAudio(): Unit \ {Assert, Fs.FileRead} =
        // <<wait 0.9>> → <<jump>> で入ったノードの頭の歩く <<bg>>（5.4 秒）→ <<set>> → <<audio>> 2 つ → <<wait 0.8>> → 台詞:
        // 送ってから 0.9 + 1 秒では台詞が出ず、0.9 + 6.5 秒では出ている。
        let base = res() |> Res.withDialogue(Yarn.loadOr(Yarn.empty(), "test/fixtures/switch/dialogue.json")) |> TestKit.withOpening("Enter");
        let r = { commands = Commands.tableOf(Commands.bgUsing(walk(5.4)) :: Commands.commandsIn(base#commands)) | base };
        let walked = TestKit.advance(r, begun(r));
        let early = stepFrames(r, 57, walked);
        let late = stepFrames(r, 165, early);
        Assert.assertEq(expected = ("「歩く前の行。」", "「歩いた後の行。」"), (currentText(early), currentText(late)))

    /// 台本（test/fixtures/switch）の node を、実機と同じ 1 フレーム（Flow.play・30 fps・flow の reader が読んで送る）で流し、
    /// 歩く <<bg p1>> を当てたフレームから「歩いた後の行。」を出したフレームまでのフレームの数。
    def walkFramesByFlow(node: String, lineNo: Int32): Result[String, Int32] \ Fs.FileRead =
        let base = res() |> Res.withDialogue(Yarn.loadOr(Yarn.empty(), "test/fixtures/switch/dialogue.json")) |> TestKit.withOpening(node);
        let r = { commands = Commands.tableOf(Commands.bgUsing(walk(5.4)) :: Commands.commandsIn(base#commands)) | base };
        let app = TestKit.app(r, TestKit.w0(r));
        let title = Resources.of(r, TestKit.w0(r));
        let text = "fps 30\nwait 0.5\ntap confirm\ndrive reader until talkLine=test/fixtures/switch/switch.yarn:${Int32.toString(lineNo)} max 20\nwait 0.5\n";
        forM (
            script <- Flow.Parse.parseText(Flow.vocabOf(app, title), "switch-test.flow", text) |> Result.mapErr(Flow.Parse.problemsText);
            played <- Flow.play(app, { design = Layout.size(Layout.Fit.Regular), limit = 1200 }, script, { world = title, state = App.freshStepState() })
                      |> Result.mapErr(failure -> failure#why)
        ) yield framesFromWalkToLine(Flow.worldsOf(played) |> List.map(h -> h#world))

    def framesFromWalkToLine(worlds: List[World.World]): Int32 =
        let indexed = List.zipWithIndex(worlds);
        let walkAt = indexed |> List.find(p -> World.readOf(snd(p)) |> Option.exists(rd -> rd#stage#shot |> Option.exists(shot -> shot#photo == "p1"))) |> Option.map(fst);
        let lineAt = indexed |> List.find(p -> currentText(snd(p)) == "「歩いた後の行。」") |> Option.map(fst);
        match (walkAt, lineAt) {
            case (Some(a), Some(b)) => b - a
            case _                  => -1
        }

    @Test
    def testAWalkingBgThenAWaitShowsTheLineWhenTheWalkEndsOnTheAppPath(): Unit \ {Assert, Fs.FileRead} =
        // 歩く <<bg>> 5.4 秒 → <<audio>> 2 つ → <<wait 0.8>> → 台詞: <<wait>> は歩きの頭から数えて重なるので、台詞は歩きの終わり
        // 162 フレームの前後に出る。間の比べ（migrate diff --times）と同じく ±1 フレームの幅で見る。
        let frames = walkFramesByFlow("Walk", 16) |> Result.getWithDefault(-1);
        Assert.assertTrue(frames >= 162 and frames <= 164)

    @Test
    def testAWalkingBgAtTheHeadOfAJumpedNodeShowsTheLineWhenTheWalkEndsOnTheAppPath(): Unit \ {Assert, Fs.FileRead} =
        let frames = walkFramesByFlow("Enter", 33) |> Result.getWithDefault(-1);
        Assert.assertTrue(frames >= 162 and frames <= 164)

    /// 1/30 秒のフレームを n 回進める（実機と同じく、待ちが明けたフレームの次のフレームで実行器が進む）。
    def stepFrames(r: Res.Res, n: Int32, w: World.World): World.World =
        List.range(0, n) |> List.foldLeft((cur, _) -> TestKit.stepBy(r, 1.0 / 30.0, cur), w)

    @Test
    def testAudioAfterAWalkingBgKeepsTheWait(): Unit \ {Assert, Fs.FileRead} =
        // 歩く <<bg>>（ゲームの backdropSwitch が 5.4 秒）→ <<audio>> 2 つ → <<wait 0.8>> → 台詞: 1 秒では台詞が出ず、6.5 秒で出る。
        let base = res();
        let r = { commands = Commands.tableOf(Commands.bgUsing(walk(5.4)) :: Commands.commandsIn(base#commands)) | base };
        let events = YarnRunner.Event.Command(command("bg", photoAt(r, 1) :: "grade=${grade(r)}" :: Nil))
            :: YarnRunner.Event.Command(command("audio", "ambience" :: "amb_river" :: Nil))
            :: YarnRunner.Event.Command(command("audio", "all" :: "off" :: Nil))
            :: YarnRunner.Event.Command(command("wait", "0.8" :: Nil)) :: YarnRunner.Event.Line(heldLine()) :: Nil;
        let w = TestKit.stepBy(r, 0.2, beatWith(r, events));
        let early = TestKit.stepBy(r, 1.0, w);
        let late = TestKit.stepBy(r, 6.5, early);
        Assert.assertEq(expected = (false, true), (currentText(early) == "歩いた後の行。", currentText(late) == "歩いた後の行。"))

    @Test
    def testTheSwitchStopsAtAWait(): Unit \ {Assert, Fs.FileRead} =
        // <<wait>> は実行器の待ちなので時間を取る側: そこで止まり、後ろの時間を取らない命令も待つ。
        let (_, signals) = walkedIntoEvents(withSwitchCommands(res()), YarnRunner.Event.Command(command("wait", "1" :: Nil)) :: YarnRunner.Event.Command(command("quick", Nil)) :: Nil);
        Assert.assertEq(expected = Nil, signals)

    @Test
    def testTheSwitchStopsAtChoices(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢で止まり、まだ出さない。
        let line = { text = "行く" | heldLine() };
        let option = { line = line, available = true };
        let (w, signals) = walkedIntoEvents(withSwitchCommands(res()), YarnRunner.Event.Choices(option :: Nil) :: YarnRunner.Event.Command(command("quick", Nil)) :: Nil);
        Assert.assertEq(expected = (Nil, false), (signals, World.isChoosing(w)))

    @Test
    def testAPlainWaitFromAFlowedCommandIsNotTappable(): Unit \ {Assert, Fs.FileRead} =
        // 切り替えの間に流した命令が Out.Wait を出したら、押しても明けない待ちになる（音を聞かせる待ちを飛ばさない）。
        let r = { commands = Commands.tableOf({ timing = Commands.Timing.Instant | waitCommand("sewait", Out.Wait(1.0)) } :: Commands.commandsIn(withSwitchCommands(res())#commands)) | res() };
        let (w, _) = walkedInto(withSwitchCommands(r), "sewait" :: Nil);
        Assert.assertEq(expected = (true, false), (isPaused(w), WorldRead.isTapWait(w)))

    // ══ <<tween 鍵>> ══

    @Test
    def testTweenMovesAGameKeyOverTime(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(res(), 0.0, "tween", "lair.arrive" :: "1" :: "time=2" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(0.5, PropertyTween.numAt(t(1.0), PropertyTween.numKey("game.lair.arrive"), 0.0, st#props)))

    @Test
    def testTweenSettlesAtItsEnd(): Unit \ {Assert, Fs.FileRead} =
        let st = Stage.settle(applied(res(), 0.0, "tween", "lair.arrive" :: "1" :: "time=2" :: Nil, Stage.empty()));
        Assert.assertTrue(TestKit.near(1.0, PropertyTween.numAt(t(0.0), PropertyTween.numKey("game.lair.arrive"), 0.0, st#props)))

    @Test
    def testTweenRefusesAWrittenGamePrefix(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(Commands.execute(Commands.Replay.Live, ctxAt(res(), 0.0), command("tween", "game.lair.arrive" :: "1" :: Nil), Stage.empty())))

    // ══ Commands.applyText ══

    @Test
    def testApplyTextIsTheSameAsTheScriptLine(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let byText = Commands.applyText(ctxAt(r, 0.0), "<<show a time=0>>", Stage.empty()) |> Result.map(match (st, _) -> Cast.markToJson(Cast.markOf(st#cast)));
        let byScript = Commands.execute(Commands.Replay.Live, ctxAt(r, 0.0), command("show", "a" :: "time=0" :: Nil), Stage.empty()) |> Result.map(match (st, _) -> Cast.markToJson(Cast.markOf(st#cast)));
        Assert.assertEq(expected = byScript, byText)

    @Test
    def testCommandTextKeepsQuotedWordsTogether(): Unit \ Assert =
        Assert.assertEq(expected = Ok(("feed", "\"a b\"" :: "from=x" :: Nil)), Commands.commandOfText("<<feed \"a b\" from=x>>") |> Result.map(c -> (c#name, c#args)))

    @Test
    def testApplyTextOfAnUnknownCommandIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(Commands.applyText(ctxAt(res(), 0.0), "<<nope a>>", Stage.empty())))

    @Test
    def testApplyTextNeedsTheSameAssetsAsTheScriptLine(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = Commands.needsOf(r, command("show", "a" :: Nil), Stage.empty()), Commands.needsOfText(r, "<<show a>>", Stage.empty()))

    // ══ GameView.hud・GameView.objects ══

    def hudZs(band: View.HudBand): List[Int32] \ Fs.FileRead =
        let r = res();
        let hud = (_: View.Env, _: World.Read) -> (band, View.at(0.0, 0.0, RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 1.0, b = 1.0 }, 3))) :: Nil;
        World.readOf(begun(r)) |> Option.map(rd -> View.gameHudUsing(hud, envOf(r, 0.0), rd) |> List.map(p -> ViewStage.zOf(p#item))) |> Option.getWithDefault(Nil)

    @Test
    def testHudOverTheWindowIsAboveTheText(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = View.zGameHud() + 3 :: Nil, hudZs(View.HudBand.OverWindow))

    @Test
    def testHudUnderTheWindowIsBelowTheVeil(): Unit \ {Assert, Fs.FileRead} =
        let zs = hudZs(View.HudBand.UnderWindow);
        Assert.assertEq(expected = (View.zGameHudUnder() + 3 :: Nil, true), (zs, zs |> List.forAll(z -> z < View.zVeil())))

    @Test
    def testThumbnailHudUnderTheWindowIsAboveTheWorldAndBelowTheText(): Unit \ {Assert, Fs.FileRead} =
        // サムネでは world を 0..8 に詰め、UnderWindow の hud はその上（9）・字（zVeil 10）の下にまとめる。
        let r = res();
        let st = TestKit.stepBy(r, 0.0, begun(r)) |> World.readOf |> Option.map(rd -> rd#stage) |> Option.getWithDefault(Stage.empty());
        let worldTop = ViewStage.thumbnail(envOf(r, 0.0), applied(r, 0.0, "show", "a" :: Nil, st), true) |> List.map(p -> ViewStage.zOf(p#item)) |> List.maximum |> Option.getWithDefault(0);
        let hud = (_: View.Env, _: World.Read) -> (View.HudBand.UnderWindow, View.at(0.0, 0.0, RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 0.0, b = 0.0 }, 5))) :: Nil;
        let hudZs = World.readOf(begun(r)) |> Option.map(rd -> View.thumbHudUsing(hud, envOf(r, 0.0), rd) |> List.map(p -> ViewStage.zOf(p#item))) |> Option.getWithDefault(Nil);
        Assert.assertEq(expected = (View.zThumbHudUnder() :: Nil, true, true), (hudZs, worldTop < View.zThumbHudUnder(), View.zThumbHudUnder() < View.zVeil()))

    @Test
    def testGameObjectsAreListedWhileReading(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let lamp = (_: View.Env, _: World.Read) -> { id = "lamp", name = "電灯", rect = Layout.screen(Layout.Fit.Regular) } :: Nil;
        let ids = FlowVideo.objectsUsing(lamp, View.emptyFonts(), Layout.Fit.Regular, r, begun(r)) |> List.map(o -> o#id);
        Assert.assertTrue(List.memberOf("lamp", ids))

    // ══ 先に積んだ台詞の戻れる所 ══

    /// コメント（LineWait 1 秒）と、環境音も替えるコメントと台詞 1 行を流し、3 秒進めた所（台詞は 1 つ目のコメントの頭で積み、
    /// 環境音を替える 2 つ目のコメントは後から当たる）。
    def commentsThenAmbience(r: Res.Res): World.World = commentsThenAmbienceAt(r, 3.0)

    /// 同じ流れを secs 秒進めた所。
    def commentsThenAmbienceAt(r: Res.Res, secs: Float64): World.World =
        let withComment = withAmbienceComments(r);
        let events = YarnRunner.Event.Command(command("comment", Nil)) :: YarnRunner.Event.Command(command("ambcomment", Nil))
            :: YarnRunner.Event.Line(heldLine()) :: Nil;
        TestKit.stepBy(withComment, secs, beatWith(withComment, events))

    /// コメント（LineWait 1 秒）と、環境音を amb_river へ替えるコメント（ambcomment）を足した描く元。
    def withAmbienceComments(r: Res.Res): Res.Res =
        let ambComment = { spec = YarnCommands.spec("ambcomment", "環境音を替えるコメント", Nil), timing = Commands.Timing.Timed,
                           apply = (ctx, _, st) -> Ok(({ props = PropertyTween.setName(Stage.ambienceKey(), Some("amb_river"), ctx#now, 0.0, st#props) | st }, Out.LineWait(1.0) :: Nil)),
                           needs = Commands.noAssets };
        { commands = Commands.tableOf(waitCommand("comment", Out.LineWait(1.0)) :: ambComment :: Commands.commandsIn(r#commands)) | r }

    def ambienceOfMark(m: Saves.Mark): Option[String] = PropertyTween.nameEnd(Stage.ambienceKey(), Stage.fromSnapshot(m#stage)#props)

    @Test
    def testCommandsAppliedAfterAnEarlyLineAreInItsMark(): Unit \ {Assert, Fs.FileRead} =
        // 台詞を先に積んだ後に当たった環境音も、その台詞の戻れる所の舞台に入る。
        let w = commentsThenAmbience(res());
        Assert.assertEq(expected = Some(Some("amb_river")), WorldRead.headMarkOf(World.logOf(w)) |> Option.map(ambienceOfMark))

    @Test
    def testASaveBeforeTheLaterCommandHasItsStage(): Unit \ {Assert, Fs.FileRead} =
        // 2 つ目のコメントが当たる前（台詞は積んである）にセーブしても、その環境音は戻れる所の舞台に入る。
        let r = withAmbienceComments(res());
        let w = commentsThenAmbienceAt(r, 0.5);
        let head = WorldRead.headMarkOf(World.logOf(w)) |> Option.map(ambienceOfMark);
        let saved = WorldRead.slotHere(r, w) |> Option.map(slot -> ambienceOfMark(slot#mark));
        Assert.assertEq(expected = (Some(Some("amb_winter_wind")), Some(Some("amb_river"))), (head, saved))

    @Test
    def testRestoringAnEarlyLineKeepsItsAmbienceAndGoesOn(): Unit \ {Assert, Fs.FileRead} =
        // その戻れる所から戻すと環境音が残り、送ると先へ進む。
        let r = res();
        let w = commentsThenAmbience(r);
        let back = WorldRead.headMarkOf(World.logOf(w)) |> Option.map(m -> TestKit.stepBy(r, 30.0, TestKit.quiet(() -> WorldRead.restore(r, m, w))));
        let ambience = back |> Option.flatMap(b -> World.readOf(b) |> Option.flatMap(rd -> Stage.ambienceOf(World.now(b), rd#stage)));
        let moved = back |> Option.map(b -> TestKit.placeOf(TestKit.stepBy(r, 30.0, TestKit.advance(r, b))) != TestKit.placeOf(b));
        Assert.assertEq(expected = (Some("amb_river"), Some(true)), (ambience, moved))

    // ══ GameCommands.onLine ══

    /// 台詞を積むたびに game.count の数を 1 つ増やす口を差した描く元。
    def withLineCounter(r: Res.Res): Res.Res =
        let key = PropertyTween.nameKey("game.count");
        let count = (st: Stage.Stage) -> PropertyTween.nameEnd(key, st#props) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(0);
        { onLine = Commands.lineHookOf((ctx, st) -> { props = PropertyTween.setName(key, Some(Int32.toString(count(st) + 1)), ctx#now, 0.0, st#props) | st }) | r }

    def countOf(r: Res.Res, w: World.World): Option[String] =
        PropertyTween.nameEnd(PropertyTween.nameKey("game.count"), World.stageOf(r, w)#props)

    @Test
    def testTheLineHookRunsOncePerLine(): Unit \ {Assert, Fs.FileRead} =
        // 台詞を 1 行積むたびに口が 1 回呼ばれ、舞台の値が台詞の数だけ進む。
        let r = withLineCounter(res());
        let first = begun(r);
        let second = TestKit.settle(r, TestKit.advance(r, first));
        Assert.assertEq(expected = (Some("1"), Some("2")), (countOf(r, first), countOf(r, second)))

    // ══ GameE2e.drives ══

    @Test
    def testGameDrivesComeAfterTheReader(): Unit \ Assert =
        // flow の drive は、テンプレートの reader の後ろにゲームの drive が並ぶ。
        Assert.assertEq(expected = "reader" :: (GameE2e.drives() |> List.map(d -> d#name)), E2e.table()#drives |> List.map(d -> d#name))
}
