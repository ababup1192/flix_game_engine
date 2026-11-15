// ゲームの口（GameView.backdrop・GameCommands.backdropSwitch・GameView.hud・GameView.objects・Commands.applyText・<<tween>>）と
// novel.backdrops.json の initial・title・aspect: ゲームが差した物が使われることと、差さなければ今までどおりであること。
// ゲームの口は差し替えの形（ViewStage.backdropsWith・Commands.bgWith・View.gameHudOf・FlowVideo.objectsWith）に偽の関数を渡して見る。
mod TestGameHooks {

    use fge::{Clock, Color, RawDraw, Render, Yarn, YarnCommands}
    use Commands.Out
    use TestKit.begun

    def res(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def ctxAt(r: Res.Res, at: Float64): Commands.Ctx = { now = t(at), node = "", res = r, instant = false }

    def applied(r: Res.Res, at: Float64, name: String, args: List[String], st: Stage.Stage): Stage.Stage =
        Commands.execute(Commands.Replay.Live, ctxAt(r, at), command(name, args), st) |> Result.map(fst) |> Result.getWithDefault(st)

    def photos(r: Res.Res): List[String] = BackdropDoc.rec(r#backdrops)#photos |> Map.keysOf |> Set.toList

    def photoAt(r: Res.Res, i: Int32): String = List.drop(i, photos(r)) |> List.head |> Option.getWithDefault("")

    def grade(r: Res.Res): String = BackdropDoc.rec(r#backdrops)#grades |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("")

    /// 写真 0 番へすぐ替えた舞台。
    def firstShown(r: Res.Res): Stage.Stage = applied(r, 0.0, "bg", photoAt(r, 0) :: "grade=${grade(r)}" :: "transition=cut" :: Nil, Stage.empty())

    def envOf(r: Res.Res, at: Float64): View.Env = { storyNow = t(at) | View.envOf(Layout.Fit.Regular, r, TestKit.w0(r)) }

    def withBackdrops(f: BackdropDoc.Rec -> BackdropDoc.Rec, r: Res.Res): Res.Res = Res.withBackdrops(BackdropDoc.Doc.Doc(f(BackdropDoc.rec(r#backdrops))), r)

    def withInitial(r: Res.Res): Res.Res = withBackdrops(d -> { initial = Some({ photo = photoAt(r, 1), grade = grade(r) }) | d }, r)

    /// photo 1 番だけ x = 1000、ほかは x = 2000 に、z 1 の印を置くゲームの絵。
    def marker(r: Res.Res): ViewStage.BackdropPainter = (_, _, photo, _) ->
        Some(View.at(if (photo == photoAt(r, 1)) 1000.0 else 2000.0, 0.0, RawDraw.box({ x = 1.0, y = 1.0 }, Color.hex("#ff00ff") |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 }), 1)) :: Nil)

    def noPaint(): ViewStage.BackdropPainter = (_, _, _, _) -> None

    def xsOf(items: List[Render.PlacedItem]): List[Float64] = items |> List.map(p -> p#at#x)

    def zOfBox(items: List[Render.PlacedItem], x: Float64): List[Int32] = items |> List.filter(p -> p#at#x == x) |> List.map(p -> ViewStage.zOf(p#item))

    def walk(seconds: Float64): (Commands.Ctx, Option[Stage.Shot], Stage.Shot, Stage.Switch) -> Option[Stage.GameSwitch] =
        (_, _, _, _) -> Some({ seconds = seconds, sounds = (0.0, "se_a") :: (1.5, "se_b") :: Nil })

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
    def testTheTemplateDocHasNoInitialNorTitle(): Unit \ {Assert, Fs.FileRead} =
        let d = res()#backdrops;
        Assert.assertEq(expected = (true, true), (Option.isEmpty(BackdropDoc.initialOf(d)), Option.isEmpty(BackdropDoc.titleOf(d))))

    @Test
    def testInitialIsShownWhileThereIsNoBackdrop(): Unit \ {Assert, Fs.FileRead} =
        let r = withInitial(res());
        Assert.assertEq(expected = Some(photoAt(r, 1)), Stage.shownShot(r#backdrops, Stage.empty()) |> Option.map(s -> s#photo))

    @Test
    def testWithoutInitialNothingIsShownBeforeTheFirstBg(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Option.isEmpty(Stage.shownShot(res()#backdrops, Stage.empty())))

    @Test
    def testTheFirstBgCrossesFromTheInitialBackdrop(): Unit \ {Assert, Fs.FileRead} =
        let r = withInitial(res());
        let st = applied(r, 0.0, "bg", photoAt(r, 0) :: Nil, Stage.empty());
        Assert.assertEq(expected = (Some(photoAt(r, 1)), Some(grade(r))), (st#under |> Option.map(s -> s#photo), st#shot |> Option.map(s -> s#grade)))

    @Test
    def testTallPhotoCoversTheScreenCentered(): Unit \ {Assert, Fs.FileRead} =
        // aspect 0.5 の写真は、横の画面の幅を覆い、上下をはみ出して真ん中に置く。
        let base = res();
        let r = withBackdrops(d -> { photos = Map.adjust(p -> { aspect = Some(0.5) | p }, photoAt(base, 0), d#photos) | d }, base);
        let surfaces = ViewStage.frame(envOf(r, 10.0), firstShown(r), true) |> List.filterMap(p -> match p#item {
            case Render.Item.Shader(x) => Some((p#at#y, x#rect#size#y))
            case _                     => None
        });
        let h = Layout.height(Layout.Fit.Regular);
        Assert.assertTrue(surfaces |> List.exists(match (y, sh) -> sh > h and TestKit.near(h / 2.0, y + sh / 2.0)))

    @Test
    def testTitleFrameWithoutTitleIsTheFrame(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let st = firstShown(r);
        Assert.assertEq(expected = xsOf(ViewStage.frame(envOf(r, 1.0), st, true)), xsOf(ViewStage.titleFrame(envOf(r, 1.0), st)))

    @Test
    def testTitleScalesAndDriftsTheBackdrop(): Unit \ {Assert, Fs.FileRead} =
        let base = res();
        let r = withBackdrops(d -> { title = Some({ scale = 1.05, drift = { amp = { x = 10.0, y = 6.0 }, rate = { x = 0.13, y = 0.09 }, phase = { x = 0.0, y = 1.0 } } }) | d }, base);
        let st = firstShown(r);
        Assert.assertFalse(xsOf(ViewStage.frame(envOf(r, 1.0), st, true)) == xsOf(ViewStage.titleFrame(envOf(r, 1.0), st)))

    // ══ GameView.backdrop ══

    @Test
    def testGamePaintedBackdropIsDrawn(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let st = applied(r, 0.0, "bg", photoAt(r, 1) :: "grade=${grade(r)}" :: "transition=cut" :: Nil, Stage.empty());
        let items = ViewStage.backdropsWith(marker(r), _ -> Layout.screen(Layout.Fit.Regular), envOf(r, 5.0), st);
        Assert.assertEq(expected = View.zBackdropShot() + 1 :: Nil, zOfBox(items, 1000.0))

    @Test
    def testWithoutAGamePictureTheStillIsDrawn(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let items = ViewStage.backdropsWith(noPaint(), _ -> Layout.screen(Layout.Fit.Regular), envOf(r, 5.0), firstShown(r));
        Assert.assertTrue(items |> List.exists(p -> match p#item {
            case Render.Item.Shader(_) => true
            case _                     => false
        }))

    @Test
    def testTemplateBackdropsAskTheGameAndFallBackToTheStill(): Unit \ {Assert, Fs.FileRead} =
        // テンプレートの GameView.backdrop は何も描かないので、backdropsIn は描かない口を渡した時と同じ。
        let r = res();
        let area = (_: Option[Float64]) -> Layout.screen(Layout.Fit.Regular);
        let env = envOf(r, 5.0);
        Assert.assertEq(expected = xsOf(ViewStage.backdropsWith(noPaint(), area, env, firstShown(r))), xsOf(ViewStage.backdropsIn(area, env, firstShown(r))))

    @Test
    def testTemplateTransitionsFadeTheGamePicture(): Unit \ {Assert, Fs.FileRead} =
        // テンプレートの fade の途中は、前の背景（写真 0 番 = x 2000）と今の背景（写真 1 番 = x 1000）の両方を描く。
        let r = res();
        let st = applied(r, 1.0, "bg", photoAt(r, 1) :: "transition=fade" :: "time=2" :: Nil, firstShown(r));
        let xs = xsOf(ViewStage.backdropsWith(marker(r), _ -> Layout.screen(Layout.Fit.Regular), envOf(r, 2.0), st));
        Assert.assertTrue(List.memberOf(1000.0, xs) and List.memberOf(2000.0, xs))

    // ══ GameCommands.backdropSwitch ══

    @Test
    def testGameOwnedSwitchWaitsForItsSeconds(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = Ok(Out.Wait(3.0) :: Nil), ownedOuts(r, walk(3.0), false))

    @Test
    def testInstantDoesNotAskTheGame(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = Ok(Nil), ownedOuts(r, walk(3.0), true))

    @Test
    def testTheTemplateDoesNotOwnTheSwitch(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let st = applied(r, 1.0, "bg", photoAt(r, 1) :: Nil, firstShown(r));
        Assert.assertTrue(Option.isEmpty(st#switch#game))

    @Test
    def testGameOwnedSwitchDrawsOnlyTheNewBackdrop(): Unit \ {Assert, Fs.FileRead} =
        // ゲームが持つ切り替えの途中は、前の背景（x 2000）を重ねず、今の背景（x 1000）だけを濃さ 1 で描く。
        let r = res();
        let st = ownedStage(r, walk(3.0));
        let xs = xsOf(ViewStage.backdropsWith(marker(r), _ -> Layout.screen(Layout.Fit.Regular), envOf(r, 2.0), st));
        Assert.assertEq(expected = (true, false), (List.memberOf(1000.0, xs), List.memberOf(2000.0, xs)))

    @Test
    def testGameOwnedSwitchRingsItsSoundsOnTheStoryClock(): Unit \ {Assert, Fs.FileRead} =
        // 1.0 秒に始めた切り替えの音（0 秒と 1.5 秒）を、物語の時刻 0.5〜1.0 と 1.0〜2.0 と 2.0〜3.0 で分けて出す。
        let st = ownedStage(res(), walk(3.0));
        let between = (a, b) -> Stage.gameSwitchSoundsBetween(t(a), t(b), st);
        Assert.assertEq(expected = ("se_a" :: Nil, Nil, "se_b" :: Nil), (between(0.5, 1.0), between(1.0, 2.0), between(2.0, 3.0)))

    @Test
    def testSkippingFinishesTheGameOwnedSwitch(): Unit \ {Assert, Fs.FileRead} =
        let st = Stage.withGameSwitchFinished(ownedStage(res(), walk(3.0)));
        Assert.assertTrue(TestKit.near(1.0, Stage.fadeProgress(t(1.5), st)))

    /// 写真 0 番から 1 番へ、1.0 秒に switchOf で替えた時の出来事。
    def ownedOuts(r: Res.Res, switchOf: (Commands.Ctx, Option[Stage.Shot], Stage.Shot, Stage.Switch) -> Option[Stage.GameSwitch], instant: Bool): Result[String, List[Out]] =
        ownedBy(r, switchOf, instant) |> Result.map(snd)

    def ownedStage(r: Res.Res, switchOf: (Commands.Ctx, Option[Stage.Shot], Stage.Shot, Stage.Switch) -> Option[Stage.GameSwitch]): Stage.Stage =
        ownedBy(r, switchOf, false) |> Result.map(fst) |> Result.getWithDefault(Stage.empty())

    def ownedBy(r: Res.Res, switchOf: (Commands.Ctx, Option[Stage.Shot], Stage.Shot, Stage.Switch) -> Option[Stage.GameSwitch], instant: Bool):
            Result[String, (Stage.Stage, List[Out])] =
        let c = Commands.bgWith(switchOf);
        let cmd = command("bg", photoAt(r, 1) :: Nil);
        forM (args <- YarnCommands.parse(c#spec, cmd); done <- c#apply({ instant = instant | ctxAt(r, 1.0) }, args, firstShown(r))) yield done

    // ══ <<tween game.<鍵>>> ══

    @Test
    def testTweenMovesAGameKeyOverTime(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let st = applied(r, 0.0, "tween", "game.lair.arrive" :: "1" :: "time=2" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(0.5, PropertyTween.numAt(t(1.0), PropertyTween.numKey("game.lair.arrive"), 0.0, st#props)))

    @Test
    def testTweenSettlesAtItsEnd(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let st = Stage.settle(applied(r, 0.0, "tween", "game.lair.arrive" :: "1" :: "time=2" :: Nil, Stage.empty()));
        Assert.assertTrue(TestKit.near(1.0, PropertyTween.numAt(t(0.0), PropertyTween.numKey("game.lair.arrive"), 0.0, st#props)))

    @Test
    def testTweenRefusesKeysOutsideGame(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertTrue(Result.isErr(Commands.execute(Commands.Replay.Live, ctxAt(r, 0.0), command("tween", "camera.zoom" :: "2" :: Nil), Stage.empty())))

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

    @Test
    def testGameHudIsPutInItsBand(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let read = World.readOf(begun(r));
        let hud = (_: View.Env, _: World.Read) -> View.at(0.0, 0.0, RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 1.0, b = 1.0 }, 3)) :: Nil;
        let zs = read |> Option.map(rd -> View.gameHudOf(hud, envOf(r, 0.0), rd) |> List.map(p -> ViewStage.zOf(p#item))) |> Option.getWithDefault(Nil);
        Assert.assertEq(expected = View.zGameHud() + 3 :: Nil, zs)

    @Test
    def testTemplateHasNoGameHud(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let read = World.readOf(begun(r));
        Assert.assertEq(expected = Some(0), read |> Option.map(rd -> List.length(GameView.hud(envOf(r, 0.0), rd))))

    @Test
    def testGameObjectsAreListedWhileReading(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let lamp = (_: View.Env, _: World.Read) -> { id = "lamp", name = "電灯", rect = Layout.screen(Layout.Fit.Regular) } :: Nil;
        let ids = FlowVideo.objectsWith(lamp, Layout.Fit.Regular, r, begun(r)) |> List.map(o -> o#id);
        Assert.assertTrue(List.memberOf("lamp", ids))

    @Test
    def testTemplateObjectsAreTheGameFreeList(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let none = (_: View.Env, _: World.Read) -> Nil;
        let ids = o -> o |> List.map((x: TapeOut.ScreenObject) -> x#id);
        Assert.assertEq(expected = ids(FlowVideo.objectsWith(none, Layout.Fit.Regular, r, begun(r))), ids(FlowVideo.objectsOf(Layout.Fit.Regular, r, begun(r))))
}
