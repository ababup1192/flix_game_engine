// 払い・タップで選ぶ選択肢（Gate）をテストする: 台詞の頁のまま待つゲート・選択肢の頁のゲート・tap の当たる物・どこでも押す tap・
// 決まらない組・送りとオートとスキップがゲートで止まること・バックログ・キーと払いの入力（Controls）・当たる物の矩形（Hint）・novel.prompts.json。
// シナリオは test/fixtures/gate/gate.yarn。
mod TestGate {

    use fge::{App, Clock, Rect2}
    use fge::GameEngine.Key
    use TestKit.{quiet, settle}

    def res(): Res.Res \ Fs.FileRead = TestKit.fixtureRes("test/fixtures/gate", "Gate")

    def begun(r: Res.Res): World.World = TestKit.begun(r)

    def textOf(w: World.World): String = World.pageOf(w)#current |> Option.map(line -> line#text) |> Option.getWithDefault("")

    def passed(r: Res.Res, input: Gate.Input, w: World.World): World.World = settle(r, quiet(() -> WorldRead.passGate(r, input, w)))

    def swipe(dir: Gesture.Direction): Gate.Input = Gate.Input.Did(Gate.Act.Swipe(dir))

    def tap(name: String): Gate.Input = Gate.Input.Did(Gate.Act.Tap(name))

    def gateText(w: World.World): String =
        WorldRead.gateHere(w) |> Option.map(g -> g#choices |> List.map(c -> Gate.actText(c#act)) |> String.intercalate("|")) |> Option.getWithDefault("")

    /// 台詞の頁のゲートを上へ払った後の分かれ道（選択肢の頁のゲート）まで。
    def atFork(r: Res.Res): World.World =
        let after = passed(r, swipe(Gesture.Direction.Up), begun(r));
        TestKit.readUntil(r, w -> Option.nonEmpty(WorldRead.gateHere(w)), Nil, settle(r, TestKit.advance(r, after)))

    /// 分かれ道で下を選んだ後の、鍵の tap のゲートまで。
    def atKey(r: Res.Res): World.World =
        let picked = passed(r, swipe(Gesture.Direction.Down), atFork(r));
        TestKit.readUntil(r, w -> gateText(w) == "tap:key", Nil, picked)

    def atAnywhere(r: Res.Res): World.World =
        TestKit.readUntil(r, w -> gateText(w) == "tap", Nil, passed(r, tap("key"), atKey(r)))

    def atMixed(r: Res.Res): World.World =
        TestKit.readUntil(r, World.isChoosing, Nil, passed(r, tap(""), atAnywhere(r)))

    // ── ゲートを見分ける ──

    @Test
    def testLineFollowedByActOptionsIsAGateOnTheLine(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Some(true), WorldRead.gateHere(begun(res())) |> Option.map(g -> g#viaLine))

    @Test
    def testOptionsWithActAreAGate(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = "left|down", gateText(atFork(res())))

    @Test
    def testOptionsWithoutActEverywhereAreNotAGate(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Option.isEmpty(WorldRead.gateHere(atMixed(res()))))

    @Test
    def testMutedCaptionIsHidden(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Some(None), WorldRead.gateHere(begun(res())) |> Option.flatMap(g -> List.head(g#choices)) |> Option.map(c -> c#caption))

    @Test
    def testIconTagIsCarried(): Unit \ {Assert, Fs.FileRead} =
        let icons = WorldRead.gateHere(atFork(res())) |> Option.map(g -> g#choices |> List.filterMap(c -> c#icon)) |> Option.getWithDefault(Nil);
        Assert.assertEq(expected = "blade" :: Nil, icons)

    // ── 選ぶ ──

    @Test
    def testSwipeInTheGateDirectionPassesTheLineGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = "「払った後の行。」", textOf(passed(r, swipe(Gesture.Direction.Up), begun(r))))

    @Test
    def testSwipeInAnotherDirectionStays(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let start = begun(r);
        Assert.assertEq(expected = World.talkLineOf(start), World.talkLineOf(passed(r, swipe(Gesture.Direction.Down), start)))

    @Test
    def testAdvanceDoesNotPassTheGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let start = begun(r);
        Assert.assertEq(expected = World.talkLineOf(start), World.talkLineOf(settle(r, TestKit.advance(r, start))))

    @Test
    def testForkGatePicksTheMatchingOption(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = "「左を選んだ。」", textOf(passed(r, swipe(Gesture.Direction.Left), atFork(r))))

    @Test
    def testTapOnAnotherTargetStays(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let start = atKey(r);
        Assert.assertEq(expected = "tap:key", gateText(passed(r, tap("door"), start)))

    @Test
    def testTapOnTheTargetPicks(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = "「鍵を押した。」", textOf(passed(r, tap("key"), atKey(r))))

    @Test
    def testConfirmPicksTheLoneTap(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = "「鍵を押した。」", textOf(passed(r, Gate.Input.Confirm, atKey(r))))

    @Test
    def testTapAnywhereAcceptsAnyTarget(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        Assert.assertEq(expected = "「押した。」", textOf(passed(r, tap("somewhere"), atAnywhere(r))))

    @Test
    def testLoneGateLeavesNoChosenLineInTheLog(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let chosen = World.logOf(passed(r, swipe(Gesture.Direction.Up), begun(r))) |> List.exists(e -> match e {
            case World.Entry.Chose(_) => true
            case _                    => false
        });
        Assert.assertFalse(chosen)

    @Test
    def testForkGateLeavesTheChosenLineInTheLog(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let chosen = World.logOf(passed(r, swipe(Gesture.Direction.Left), atFork(r))) |> List.exists(e -> match e {
            case World.Entry.Chose(text) => text == "左へ払って戻る"
            case _                       => false
        });
        Assert.assertTrue(chosen)

    // ── オートとスキップ ──

    @Test
    def testAutoStopsAtTheGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let auto = quiet(() -> WorldRead.togglePlayback(World.Playback.Auto, begun(r)));
        Assert.assertEq(expected = World.Playback.Manual, World.playbackOf(settle(r, auto)))

    @Test
    def testSkipStopsAtTheGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let skip = quiet(() -> WorldRead.togglePlayback(World.Playback.Skip, begun(r)));
        Assert.assertEq(expected = World.talkLineOf(begun(r)), World.talkLineOf(settle(r, skip)))

    // ── キーと払い（Controls） ──

    def keyFrame(key: Key): App.Frame = { justPressed = Set#{key}, down = Set#{key} | App.emptyFrame() }

    @Test
    def testPrevKeySwipesUpInTheGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let up = KeysDoc.rec(r#keys)#prev |> List.head |> Option.getWithDefault(Key.Up);
        Assert.assertEq(expected = "「払った後の行。」", textOf(settle(r, Controls.interact(keyFrame(up), r, begun(r)))))

    @Test
    def testFlickDownKeySwipesDownInTheGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let down = KeysDoc.rec(r#keys)#flickDown |> List.head |> Option.getWithDefault(Key.Numpad2);
        Assert.assertEq(expected = "「下を選んだ。」", textOf(settle(r, Controls.interact(keyFrame(down), r, atFork(r)))))

    @Test
    def testMouseSwipeLeftPicksAndDoesNotRollBack(): Unit \ {Assert, Fs.FileRead} =
        // 左へ払う（ブラウザ版は離したフレームで戻るのキーも出る）と、ゲートが先に受けて左を選ぶ。
        let r = res();
        let k = KindDoc.rec(r#kind);
        let start = { x = 600.0, y = 200.0 };
        let to = { x = 600.0 - k#swipeMin * 2.0, y = 200.0 };
        let rollback = KeysDoc.rec(r#keys)#rollback |> List.head |> Option.getWithDefault(Key.PageUp);
        let frames = { mouseClicked = true, mouseDown = true, cursor = start | App.emptyFrame() } ::
                     { mouseDown = true, mouseMoved = true, cursor = to, realNow = Clock.after(k#swipeSeconds / 2.0, Clock.zero()) | App.emptyFrame() } ::
                     { cursor = to, realNow = Clock.after(k#swipeSeconds / 2.0, Clock.zero()), justPressed = Set#{rollback}, down = Set#{rollback} | App.emptyFrame() } :: Nil;
        let w = List.foldLeft((acc, f) -> Controls.interact(f, r, acc), atFork(r), frames);
        Assert.assertEq(expected = "「左を選んだ。」", textOf(settle(r, w)))

    // ── 当たる物の矩形・novel.prompts.json ──

    def promptsWith(text: String): PromptsDoc.Doc = PromptsDoc.fromJson(text) |> Option.getWithDefault(PromptsDoc.defaults())

    def keyOnPhoto(): PromptsDoc.Doc =
        promptsWith("{ \"targets\": { \"key\": { \"photo\": \"room\", \"rect\": { \"x\": 0.5, \"y\": 0.25, \"w\": 0.1, \"h\": 0.2 } } } }")

    def screenRect(): Rect2.Rect2 = { position = { x = 0.0, y = 0.0 }, size = { x = 1000.0, y = 500.0 } }

    @Test
    def testTargetOnTheShownPhotoIsPlacedInsideIt(): Unit \ Assert =
        let r = Hint.targetRect(keyOnPhoto(), Some(("room", screenRect())), _ -> None, "key");
        Assert.assertEq(expected = Some((500.0, 125.0, 100.0, 100.0)), r |> Option.map(x -> (x#position#x, x#position#y, x#size#x, x#size#y)))

    @Test
    def testTargetOnAnotherPhotoIsNotThere(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(Hint.targetRect(keyOnPhoto(), Some(("hall", screenRect())), _ -> None, "key")))

    @Test
    def testTargetOnAnActorFollowsTheActor(): Unit \ Assert =
        let doc = promptsWith("{ \"targets\": { \"badge\": { \"actor\": \"a\", \"rect\": { \"x\": 0.0, \"y\": 0.0, \"w\": 0.5, \"h\": 0.5 } } } }");
        let r = Hint.targetRect(doc, None, name -> if (name == "a") Some(screenRect()) else None, "badge");
        Assert.assertEq(expected = Some((500.0, 250.0)), r |> Option.map(x -> (x#size#x, x#size#y)))

    @Test
    def testTapTargetAtFindsTheTargetUnderThePoint(): Unit \ Assert =
        let gate = { choices = { act = Gate.Act.Tap("key"), index = 0, icon = None, caption = None } :: Nil, viaLine = false };
        let targets = name -> Hint.targetRect(keyOnPhoto(), Some(("room", screenRect())), _ -> None, name);
        Assert.assertEq(expected = "key", Hint.tapTargetAt(targets, gate, { x = 550.0, y = 200.0 }))

    @Test
    def testTargetWithoutAnAnchorIsNotRead(): Unit \ Assert =
        let doc = promptsWith("{ \"targets\": { \"key\": { \"rect\": { \"x\": 0.5 } } } }");
        Assert.assertTrue(Option.isEmpty(PromptsDoc.targetOf("key", doc)))

    // ── 端の帯・選べる物の無い組・セーブとロード ──

    @Test
    def testEdgeDragWithTheRollbackKeyStaysAtTheGate(): Unit \ {Assert, Fs.FileRead} =
        // 右の端の帯から左へ払う（Gesture はドラッグにする・ブラウザ版は離したフレームで戻るのキーも出る）と、ゲートのまま戻らない。
        let r = res();
        let k = KindDoc.rec(r#kind);
        let edge = PromptsDoc.rec(r#prompts)#edge;
        let start = { x = Layout.width(Layout.Fit.Regular) - edge / 2.0, y = 200.0 };
        let finish = { x = start#x - k#swipeMin * 2.0, y = 200.0 };
        let rollback = KeysDoc.rec(r#keys)#rollback |> List.head |> Option.getWithDefault(Key.PageUp);
        let frames = { mouseClicked = true, mouseDown = true, cursor = start | App.emptyFrame() } ::
                     { mouseDown = true, mouseMoved = true, cursor = finish, realNow = Clock.after(k#swipeSeconds / 2.0, Clock.zero()) | App.emptyFrame() } ::
                     { cursor = finish, realNow = Clock.after(k#swipeSeconds / 2.0, Clock.zero()), justPressed = Set#{rollback}, down = Set#{rollback} | App.emptyFrame() } :: Nil;
        let fork = atFork(r);
        let w = List.foldLeft((acc, f) -> Controls.interact(f, r, acc), fork, frames);
        Assert.assertEq(expected = World.talkLineOf(fork), World.talkLineOf(settle(r, w)))

    @Test
    def testGroupWithNoOpenOptionIsNotAGate(): Unit \ Assert =
        // 組の全部に #act があっても、全部が <<if>> で選べなければゲートにしない。
        let line = { speaker = "", text = "上へ", parts = Nil, tags = { key = "act", value = "up" } :: Nil, source = { file = "t", line = 1 } };
        Assert.assertTrue(Option.isEmpty(Gate.ofOptions({ line = line, available = false } :: Nil)))

    def restoredGateText(r: Res.Res, w: World.World): String =
        WorldRead.slotHere(r, w) |> Option.map(slot -> settle(r, quiet(() -> WorldRead.restore(r, slot#mark, TestKit.w0(r))))) |> Option.map(gateText)
            |> Option.getWithDefault("")

    @Test
    def testSaveAtTheLineGateLoadsBackToTheSameGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let w = begun(r);
        Assert.assertEq(expected = gateText(w), restoredGateText(r, w))

    @Test
    def testSaveAtTheOptionsGateLoadsBackToTheSameGate(): Unit \ {Assert, Fs.FileRead} =
        let r = res();
        let w = atFork(r);
        Assert.assertEq(expected = gateText(w), restoredGateText(r, w))
}
