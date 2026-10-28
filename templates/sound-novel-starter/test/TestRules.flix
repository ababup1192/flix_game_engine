// ルールと進行だけをテストする。座標・描き方・文字送りの見た目はテストしない。
// シナリオは本物（natsukusa.yarn を build した木）。行の文字は写さず、ノードの名前・変数・台本の木から期待値を導く。
mod TestRules {

    use fge::{AudioMixer, Clock, Emit, Yarn, YarnRunner}
    use TestKit.{advance, begun, pick, placeOf, readTo, settle, quiet, w0}

    def kind(res: Res.Res): KindDoc.Rec = KindDoc.rec(res#kind)

    /// node の台詞（Say）の .yarn の行番号を上から。
    def sayLines(res: Res.Res, node: String): List[Int32] =
        Yarn.nodeOf(node, res#dialogue) |> Option.map(found -> found#body |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Say(say) => Some(say#source#line)
            case _                       => None
        })) |> Option.getWithDefault(Nil)

    def lineNo(w: World.World): Int32 =
        World.talkLineOf(w) |> String.splitOn(substr = ":") |> List.last
            |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(-1)

    // ══ タイトルと始まり ══

    @Test
    def testNewGameOpensTheOpeningNodeOnItsFirstLine(): Unit \ {Assert, Fs.FileRead} =
        // はじめから: コードが開くノード（Talk.Node.Opening）の最初の台詞を、台本の頭のコマンドどおりの舞台で出す。
        let res = TestKit.res();
        let w = begun(res);
        let opening = Talk.nodeName(Talk.Node.Opening);
        Assert.assertEq(expected = ("Reading", opening, List.head(sayLines(res, opening)), Stage.Mode.Nvl),
                        (World.sceneName(w), World.talkNodeOf(w), Some(lineNo(w)), World.stageOf(res, w)#mode))

    // ══ 読み進める ══

    /// 開いた直後の <<wait>> の秒（無ければ 0）。
    def waitOf(w: World.World): Float64 =
        World.readOf(w) |> Option.flatMap(r -> YarnRunner.waitUntilOf(r#talk)) |> Option.map(until -> Clock.since(Clock.nowOf(w#storyClock), until)) |> Option.getWithDefault(0.0)

    @Test
    def testAdvanceWhileTypingRevealsWithoutMoving(): Unit \ {Assert, Fs.FileRead} =
        // 文字送りの途中の決定は全文を出すだけで、行は動かない。
        // 頭の <<wait>> が明けるまで進めてから、1 字も出し切らない短い間だけ送る。
        let res = TestKit.res();
        let start = w0(res);
        let opened = quiet(() -> WorldRead.newGame(res, start));
        let typing = opened |> TestKit.stepBy(res, waitOf(opened) - 0.01) |> TestKit.stepBy(res, 0.02);
        let before = placeOf(typing);
        let after = advance(res, typing);
        Assert.assertEq(expected = (false, true, before), (Page.isDone(World.pageOf(typing)), Page.isDone(World.pageOf(after)), placeOf(after)))

    @Test
    def testAdvanceMovesToTheNextSayAndMarksSeen(): Unit \ {Assert, Fs.FileRead} =
        // 出し終えた行の決定は、同じノードの次の台詞へ送り、送った行を既読にする（saveRev が進む = 書く）。
        let res = TestKit.res();
        let w = begun(res);
        let next = settle(res, advance(res, w));
        let opening = Talk.nodeName(Talk.Node.Opening);
        Assert.assertEq(expected = (List.nth(1, sayLines(res, opening)), true, w#saveRev + 1),
                        (Some(lineNo(next)), Saves.isSeen(World.talkLineOf(w), next#saves), next#saveRev))

    @Test
    def testNvlPageKeepsEarlierLinesUntilClear(): Unit \ {Assert, Fs.FileRead} =
        // NVL は頁に前の行を積んだまま次の行を足す（<<clear>> まではめくらない）。
        let res = TestKit.res();
        let w = begun(res) |> advance(res) |> settle(res) |> advance(res) |> settle(res);
        Assert.assertEq(expected = 2, List.length(World.pageOf(w)#lines))

    @Test
    def testNvlPageTurnsWhenRowsRunOut(): Unit \ {Assert} =
        // 頁に入り切らない行が来たら、頁をめくってその行だけにする。
        let line = text -> { speaker = "", text = text, rubies = Nil, source = text };
        let fits = lines -> List.length(lines) <= 2;
        let page = Page.empty() |> Page.show(Stage.Mode.Nvl, fits, line("a")) |> Page.show(Stage.Mode.Nvl, fits, line("b"))
                                |> Page.show(Stage.Mode.Nvl, fits, line("c"));
        Assert.assertEq(expected = (0, Some("c")), (List.length(page#lines), page#current |> Option.map(l -> l#text)))

    @Test
    def testAdvGoesOneLineAtATime(): Unit \ {Assert, Fs.FileRead} =
        // ADV は下のウィンドウに今の 1 行だけ（頁に積まない）。
        let res = TestKit.res();
        let w = readTo(res, "Paddy", Nil, begun(res)) |> advance(res) |> settle(res);
        Assert.assertEq(expected = (Stage.Mode.Adv, 0), (World.stageOf(res, w)#mode, List.length(World.pageOf(w)#lines)))

    // ══ 選択肢と変数 ══

    @Test
    def testChoicesBlockAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出している間は決定で先へ進めない（pick だけが進める）。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let after = settle(res, advance(res, asking));
        Assert.assertEq(expected = (true, placeOf(asking)), (World.isChoosing(after), placeOf(after)))

    @Test
    def testPickingTheNicknameRaisesCloseness(): Unit \ {Assert, Fs.FileRead} =
        // 田んぼの選択肢: 昔の呼び名（2 つ目）を選ぶと $closeness が 1 上がり、1 つ目では上がらない。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let closeness = i -> World.variableOf("$closeness", settle(res, pick(res, i, asking)));
        Assert.assertEq(expected = ("0", "1"), (closeness(0), closeness(1)))

    @Test
    def testConditionalChoiceCannotBePickedWithoutCloseness(): Unit \ {Assert, Fs.FileRead} =
        // 川の選択肢の 2 つ目は $closeness >= 2 の時だけ選べる。足りなければ選べない印で並び、pick しても動かない。
        let res = TestKit.res();
        let atRiver = readTo(res, "River", 0 :: 0 :: Nil, begun(res)) |> (w -> TestKit.readUntil(res, World.isChoosing, Nil, w));
        let tried = settle(res, pick(res, 1, atRiver));
        let available = World.choicesOf(atRiver) |> List.map(option -> option#available);
        Assert.assertEq(expected = (true :: false :: Nil, placeOf(atRiver)), (available, placeOf(tried)))

    @Test
    def testCursorSkipsChoicesThatCannotBePicked(): Unit \ {Assert, Fs.FileRead} =
        // 選べない選択肢にはカーソルが止まらない。
        let res = TestKit.res();
        let atRiver = readTo(res, "River", 0 :: 0 :: Nil, begun(res)) |> (w -> TestKit.readUntil(res, World.isChoosing, Nil, w));
        let moved = quiet(() -> WorldRead.moveChoice(1, atRiver));
        Assert.assertEq(expected = Some(0), World.readOf(moved) |> Option.map(r -> r#choiceCursor))

    @Test
    def testTrueEndingNeedsBothWarmChoices(): Unit \ {Assert, Fs.FileRead} =
        // 両方の選択で近づくと、川で残る選択ができ、朝に $stayed が立つ。
        let res = TestKit.res();
        let morning = readTo(res, "Morning", 1 :: 1 :: 1 :: Nil, begun(res));
        Assert.assertEq(expected = ("2", "True"), (World.variableOf("$closeness", morning), World.variableOf("$stayed", morning)))

    @Test
    def testSellingEndingKeepsDistance(): Unit \ {Assert, Fs.FileRead} =
        // 売ると答えて黙って帰ると、$house は sell・$stayed は立たない。
        let res = TestKit.res();
        let morning = readTo(res, "Morning", 0 :: 0 :: 0 :: Nil, begun(res));
        Assert.assertEq(expected = ("sell", "False"), (World.variableOf("$house", morning), World.variableOf("$stayed", morning)))

    @Test
    def testStoryEndRollsTheCredits(): Unit \ {Assert, Fs.FileRead} =
        // シナリオの終わりまで読むとクレジットへ。
        let res = TestKit.res();
        let done = TestKit.readUntil(res, World.isCredits, 1 :: 1 :: 1 :: Nil, begun(res));
        Assert.assertEq(expected = true, World.isCredits(done))

    // ══ 演出 ══

    @Test
    def testEveryCommandInTheScriptIsUnderstood(): Unit \ {Assert, Fs.FileRead} =
        // 台本のコマンドは全部 Stage が読める（写真・時間帯の名前は backdrops にある）。wait は実行器が待つ。
        let res = TestKit.res();
        let bad = commandsOf(res#dialogue) |> List.filter(c -> c#name != "wait")
            |> List.filterMap(c -> match Stage.cueOf(res#backdrops, c) {
                case Ok(_)    => None
                case Err(why) => Some(why)
            });
        Assert.assertEq(expected = Nil, bad)

    def commandsOf(program: Yarn.Program): List[Yarn.Command] =
        def walk(body: List[Yarn.Statement]): List[Yarn.Command] = body |> List.flatMap(statement -> match statement {
            case Yarn.Statement.Command(c)   => c :: Nil
            case Yarn.Statement.Choose(cs)   => cs |> List.flatMap(choice -> walk(choice#body))
            case Yarn.Statement.If(branches, _) => branches |> List.flatMap(b -> walk(b#body))
            case _                           => Nil
        });
        Yarn.nodeNames(program) |> List.filterMap(name -> Yarn.nodeOf(name, program)) |> List.flatMap(node -> walk(node#body))

    @Test
    def testBackdropCrossfadeEndsAtItsSeconds(): Unit \ {Assert, Fs.FileRead} =
        // 背景の重ねは、コマンドの秒が過ぎると終わる（その前は途中）。
        let res = TestKit.res();
        let start = w0(res);
        let w = quiet(() -> WorldRead.newGame(res, start));
        let stage = World.stageOf(res, w);
        let at = s -> Stage.fadeProgress(Clock.after(s, Clock.nowOf(w#storyClock)), stage);
        Assert.assertEq(expected = (true, 1.0), (at(stage#fadeSeconds * 0.5) < 1.0, at(stage#fadeSeconds)))

    // ══ オート・スキップ ══

    /// 今の行を出し終えた時刻を据えた World（時計は at 秒）。
    def doneAt(w: World.World): World.World =
        let now = Clock.nowOf(w#storyClock);
        World.mapRead(r -> { doneAt = Some(now) | r }, WorldRead.revealLine(w))

    def playing(mode: World.Playback, w: World.World): World.World = World.mapRead(r -> { playback = mode | r }, w)

    @Test
    def testAutoAdvancesAfterTheWait(): Unit \ {Assert, Fs.FileRead} =
        // オート: 出し終えてから「待ち + 字数 × autoPerChar」が過ぎると次へ。その前は送らない。
        let res = TestKit.res();
        let w = doneAt(playing(World.Playback.Auto, begun(res)));
        let chars = World.pageOf(w)#current |> Option.map(line -> String.length(line#text)) |> Option.getWithDefault(0);
        let wait = Saves.configOf(w#saves)#autoWait + Int32.toFloat64(chars) * kind(res)#autoPerChar;
        let early = TestKit.stepBy(res, wait * 0.5, w);
        let late = TestKit.stepBy(res, wait + 0.1, w);
        Assert.assertEq(expected = (placeOf(w), true), (placeOf(early), placeOf(late) != placeOf(w)))

    @Test
    def testSkipStopsAtUnreadLines(): Unit \ {Assert, Fs.FileRead} =
        // スキップは読んだ行だけを飛ばす。読んでいない行に来たら切れる。
        let res = TestKit.res();
        let w = TestKit.stepBy(res, kind(res)#skipInterval, playing(World.Playback.Skip, begun(res)));
        Assert.assertEq(expected = (World.Playback.Manual, true), (World.playbackOf(w), Option.nonEmpty(World.pageOf(w)#current)))

    @Test
    def testSkipPassesReadLines(): Unit \ {Assert, Fs.FileRead} =
        // 読んだ行（既読）はスキップが送る。
        let res = TestKit.res();
        let first = begun(res);
        let seen = World.withSaves(Saves.withSeen(World.talkLineOf(first), first#saves), first);
        let w = TestKit.stepBy(res, kind(res)#skipInterval + 0.01, doneAt(playing(World.Playback.Skip, seen)));
        Assert.assertEq(expected = true, placeOf(w) != placeOf(first))

    @Test
    def testSkipEverythingPassesUnreadLines(): Unit \ {Assert, Fs.FileRead} =
        // 設定の「スキップ」を「未読も」にすると、読んでいない行も送る。
        let res = TestKit.res();
        let first = begun(res);
        let all = quiet(() -> WorldSettings.withSide(World.Pair.SkipScope, Layout.Side.Right, first));
        let w = TestKit.stepBy(res, kind(res)#skipInterval + 0.01, doneAt(playing(World.Playback.Skip, all)));
        Assert.assertEq(expected = (World.Playback.Skip, true), (World.playbackOf(w), placeOf(w) != placeOf(first)))

    @Test
    def testKeepSkipWaitsAtChoicesThenContinues(): Unit \ {Assert, Fs.FileRead} =
        // 「選択肢の後」を「続ける」にすると、スキップは選択肢で待ち、選んだ後も続く。「止める」なら選択肢で切れる。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let keep = quiet(() -> WorldSettings.withSide(World.Pair.AfterChoice, Layout.Side.Right, asking));
        let waiting = TestKit.stepBy(res, 0.5, playing(World.Playback.Skip, keep));
        let stopped = TestKit.stepBy(res, 0.5, playing(World.Playback.Skip, asking));
        Assert.assertEq(expected = (World.Playback.Skip, World.Playback.Skip, World.Playback.Manual),
                        (World.playbackOf(waiting), World.playbackOf(pick(res, 1, waiting)), World.playbackOf(stopped)))

    @Test
    def testPressingStopsAutoAndSkip(): Unit \ {Assert, Fs.FileRead} =
        // 人が決定を押したらオートもスキップも止める（人の速さに戻す）。
        let res = TestKit.res();
        let auto = advance(res, playing(World.Playback.Auto, begun(res)));
        let skip = advance(res, playing(World.Playback.Skip, begun(res)));
        Assert.assertEq(expected = (World.Playback.Manual, World.Playback.Manual), (World.playbackOf(auto), World.playbackOf(skip)))

    // ══ 画面と確認のウィンドウ ══

    @Test
    def testOpenPanelStopsTheStoryClock(): Unit \ {Assert, Fs.FileRead} =
        // 画面を開いている間は物語の時計が止まる（待ち・文字送り・オートが進まない）。
        let res = TestKit.res();
        let reading = begun(res);
        let w = quiet(() -> WorldLog.openLog(reading));
        let later = TestKit.stepBy(res, 5.0, w);
        Assert.assertEq(expected = Clock.nowOf(w#storyClock), Clock.nowOf(later#storyClock))

    @Test
    def testAskingStopsTheStoryClockAndBlocksAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 確認のウィンドウを開いている間も物語の時計は止まり、決定で本文は進まない。
        let res = TestKit.res();
        let reading = begun(res);
        let w = quiet(() -> World.askFor(World.Ask.ToTitle, reading));
        let later = advance(res, TestKit.stepBy(res, 5.0, w));
        Assert.assertEq(expected = (Clock.nowOf(w#storyClock), placeOf(w)), (Clock.nowOf(later#storyClock), placeOf(later)))

    @Test
    def testAnsweringNoKeepsReading(): Unit \ {Assert, Fs.FileRead} =
        // 「タイトルに戻りますか？」にいいえと答えると、ウィンドウが閉じて同じ所を読み続ける。はいならタイトルへ。
        let res = TestKit.res();
        let reading = begun(res);
        let w = quiet(() -> World.askFor(World.Ask.ToTitle, reading));
        let no = quiet(() -> WorldMenu.answer(res, World.Answer.No, w));
        let yes = quiet(() -> WorldMenu.answer(res, World.Answer.Yes, w));
        Assert.assertEq(expected = ((None, "Reading", placeOf(w)), "Title"),
                        ((World.askOf(no), World.sceneName(no), placeOf(no)), World.sceneName(yes)))

    @Test
    def testCloseButtonAsksBeforeQuitting(): Unit \ {Assert, Fs.FileRead} =
        // ウィンドウの閉じるボタンはすぐ終えず「終了しますか？」を出し、はいで終了の印が立つ。
        let res = TestKit.res();
        let asked = World.requestQuit(begun(res));
        let quit = quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked));
        Assert.assertEq(expected = (Some(World.Ask.Quit), false, true), (World.askOf(asked), asked#quitting, quit#quitting))

    // ══ バックログと戻る ══

    def sourceOf(entry: World.Entry): String = match entry {
        case World.Entry.Said(line, _) => line#source
        case World.Entry.Chose(_)      => ""
    }

    @Test
    def testLogKeepsNewestFirstAndCapsAtLogMax(): Unit \ {Assert, Fs.FileRead} =
        // バックログは新しい順に積み、logMax を超えない。
        let res = TestKit.res();
        let w = begun(res) |> advance(res) |> settle(res);
        let small = Res.withKind(KindDoc.Doc.Doc({ logMax = 1 | kind(res) }), res);
        let capped = w |> advance(small) |> settle(small);
        Assert.assertEq(expected = (Some(World.talkLineOf(w)), 1),
                        (List.head(World.logOf(w)) |> Option.map(sourceOf), List.length(World.logOf(capped))))

    @Test
    def testPickedChoiceIsLogged(): Unit \ {Assert, Fs.FileRead} =
        // 選んだ選択肢は、選んだ字のままバックログに残る（戻れる所は持たない）。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let text = List.nth(1, World.choicesOf(asking)) |> Option.map(option -> option#line#text) |> Option.getWithDefault("");
        let chose = pick(res, 1, asking);
        let logged = World.logOf(chose) |> List.exists(entry -> match entry {
            case World.Entry.Chose(t) => t == text
            case _                    => false
        });
        Assert.assertEq(expected = true, logged)

    @Test
    def testRollbackReturnsToThePreviousLine(): Unit \ {Assert, Fs.FileRead} =
        // 戻るは 1 つ前の行を出した所へ戻す（同じノード・同じ行）。
        let res = TestKit.res();
        let first = begun(res);
        let second = settle(res, advance(res, first));
        let back = settle(res, quiet(() -> WorldLog.rollback(res, second)));
        Assert.assertEq(expected = placeOf(first), placeOf(back))

    @Test
    def testRollbackOverAChoiceUndoesItsVariables(): Unit \ {Assert, Fs.FileRead} =
        // 選んだ後の行から戻ると、問いの行へ戻り、選んだ枝の <<set>> も取り消される（選び直せる）。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let chose = settle(res, pick(res, 1, asking));
        let back = settle(res, quiet(() -> WorldLog.rollback(res, chose)));
        Assert.assertEq(expected = (placeOf(asking), "0", true),
                        (placeOf(back), World.variableOf("$closeness", back), World.isChoosing(settle(res, advance(res, back)))))

    @Test
    def testRollbackAtTheFirstLineOnlyNotices(): Unit \ {Assert, Fs.FileRead} =
        // 最初の行では戻れない（知らせだけ）。
        let res = TestKit.res();
        let w = begun(res);
        let tried = quiet(() -> WorldLog.rollback(res, w));
        Assert.assertEq(expected = (placeOf(w), Some(StoryDoc.labelOf(StoryDoc.Label.NoRollback, res#story))),
                        (placeOf(tried), World.toastOf(res, tried)))

    @Test
    def testJumpFromLogGoesBackToThatLine(): Unit \ {Assert, Fs.FileRead} =
        // バックログの行を選び、確認のウィンドウではいと答えると、その行の場面へ戻り、バックログはその行までになる。
        let res = TestKit.res();
        let w = begun(res) |> advance(res) |> settle(res) |> advance(res) |> settle(res) |> advance(res) |> settle(res);
        let k = 2;
        let target = List.nth(k, World.logOf(w)) |> Option.map(sourceOf);
        let asked = quiet(() -> WorldLog.askJump(k, quiet(() -> WorldLog.openLog(w))));
        let jumped = settle(res, quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked)));
        Assert.assertEq(expected = (Some(World.Ask.Jump(k)), target, List.length(World.logOf(w)) - k, "Closed"),
                        (World.askOf(asked), Some(World.talkLineOf(jumped)), List.length(World.logOf(jumped)), World.panelName(jumped)))

    @Test
    def testRollbackWorksOnLinesReplayedByALoad(): Unit \ {Assert, Fs.FileRead} =
        // ロードで読み直した行にも戻れる所が付く（ロードした直後に戻ると 1 つ前の行）。
        let res = TestKit.res();
        let before = readTo(res, "Paddy", Nil, begun(res)) |> advance(res) |> settle(res);
        let saved = quiet(() -> WorldSaves.writeSlot(res, Saves.Tab.Numbered(1), 0, settle(res, advance(res, before))));
        let loaded = settle(res, quiet(() -> WorldSaves.loadFrom(res, Saves.Tab.Numbered(1), 0, quiet(() -> WorldRead.newGame(res, saved)))));
        let back = settle(res, quiet(() -> WorldLog.rollback(res, loaded)));
        Assert.assertEq(expected = placeOf(before), placeOf(back))

    // ══ セーブ・ロード ══

    def page1(): Saves.Tab = Saves.Tab.Numbered(1)

    @Test
    def testLoadingRestoresPlaceAndStage(): Unit \ {Assert, Fs.FileRead} =
        // ロードすると、セーブした所のノードと行に戻り、舞台（写真・文章の出し方・環境音）もセーブした時の形になる。
        let res = TestKit.res();
        let atPaddy = readTo(res, "Paddy", Nil, begun(res)) |> advance(res) |> settle(res) |> advance(res) |> settle(res);
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, atPaddy));
        let elsewhere = readTo(res, "Lane", 1 :: Nil, saved);
        let loaded = settle(res, quiet(() -> WorldSaves.loadFrom(res, page1(), 0, elsewhere)));
        let stageOf = (w: World.World) -> { let st = World.stageOf(res, w); (st#shot |> Option.map(shot -> (shot#photo, shot#grade)), st#mode, st#ambience) };
        Assert.assertEq(expected = (placeOf(atPaddy), stageOf(atPaddy)), (placeOf(loaded), stageOf(loaded)))

    @Test
    def testLoadingRestoresVariables(): Unit \ {Assert, Fs.FileRead} =
        // セーブは変数も戻す（選んだ後にセーブしたデータでは $closeness が残る）。
        let res = TestKit.res();
        let chose = readTo(res, "Lane", 1 :: Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 2, chose));
        let loaded = settle(res, quiet(() -> WorldSaves.loadFrom(res, page1(), 2, quiet(() -> WorldRead.newGame(res, saved)))));
        Assert.assertEq(expected = "1", World.variableOf("$closeness", loaded))

    @Test
    def testSlotRemembersWhereAndWhen(): Unit \ {Assert, Fs.FileRead} =
        // データには場所（写真の名前）・台詞の頭・保存した日時（起動の時刻 + 実時間）が入る。
        let res = TestKit.res();
        let atPaddy = readTo(res, "Paddy", Nil, begun(res));
        let w = { clockBase = 1000i64, realNow = Clock.after(42.5, Clock.zero()) | atPaddy };
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, w));
        let place = World.stageOf(res, w)#shot |> Option.flatMap(shot -> BackdropDoc.photoOf(shot#photo, res#backdrops)) |> Option.map(p -> p#label);
        let slot = Saves.slotOf(page1(), 0, saved#saves);
        Assert.assertEq(expected = Some((place |> Option.getWithDefault(""), 1042i64, true)),
                        slot |> Option.map(s -> (s#place, s#savedAt, String.startsWith(prefix = s#excerpt, World.talkLineOf(w)) or not String.isEmpty(s#excerpt))))

    @Test
    def testSavingOverAFilledSlotAsksFirst(): Unit \ {Assert, Fs.FileRead} =
        // 埋まっている枠を選ぶと上書きを尋ね、いいえなら前のデータのまま、はいなら今の所で書き直す。
        let res = TestKit.res();
        let first = readTo(res, "Paddy", Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, first));
        let later = quiet(() -> WorldSaves.openSave(readTo(res, "Lane", 1 :: Nil, saved)));
        let asked = quiet(() -> WorldSaves.withTab(page1(), later) |> (opened -> WorldSaves.chooseSlot(res, 0, opened)));
        let nodeIn = (w: World.World) -> Saves.slotOf(page1(), 0, w#saves) |> Option.map(s -> s#mark#bookmark#node);
        Assert.assertEq(expected = (Some(World.Ask.Overwrite(page1(), 0)), Some("Paddy"), Some("Lane")),
                        (World.askOf(asked), nodeIn(quiet(() -> WorldMenu.answer(res, World.Answer.No, asked))), nodeIn(quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked)))))

    @Test
    def testDeletingASlotAsksThenRemovesIt(): Unit \ {Assert, Fs.FileRead} =
        // 削除は尋ねてから消す。
        let res = TestKit.res();
        let here = readTo(res, "Paddy", Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 1, here));
        let asked = quiet(() -> WorldSaves.deleteSlot(1, WorldSaves.withTab(page1(), WorldSaves.openSave(saved))));
        let gone = quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked));
        Assert.assertEq(expected = (Some(World.Ask.Delete(page1(), 1)), false),
                        (World.askOf(asked), Option.nonEmpty(Saves.slotOf(page1(), 1, gone#saves))))

    @Test
    def testContinueLoadsTheNewestSave(): Unit \ {Assert, Fs.FileRead} =
        // タイトルの「つづきから」は、ページを問わずいちばん新しいデータを読む。
        let res = TestKit.res();
        let here = readTo(res, "Paddy", Nil, begun(res));
        let a = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, here));
        let b = quiet(() -> WorldSaves.writeSlot(res, Saves.Tab.Numbered(3), 5, readTo(res, "Lane", 1 :: Nil, a)));
        let continued = settle(res, quiet(() -> WorldMenu.chooseTitle(res, World.TitleItem.Continue, World.toTitle(b))));
        Assert.assertEq(expected = (Some((Saves.Tab.Numbered(3), 5)), "Lane"), (Saves.latest(b#saves), World.talkNodeOf(continued)))

    @Test
    def testContinueWithoutSavesOnlyNotices(): Unit \ {Assert, Fs.FileRead} =
        // データが無い時の「つづきから」は知らせだけを出す（タイトルのまま）。
        let res = TestKit.res();
        let start = w0(res);
        let w = quiet(() -> WorldMenu.chooseTitle(res, World.TitleItem.Continue, start));
        Assert.assertEq(expected = ("Title", Some(StoryDoc.labelOf(StoryDoc.Label.NoSave, res#story))),
                        (World.sceneName(w), World.toastOf(res, w)))

    @Test
    def testQuickSaveAndQuickLoad(): Unit \ {Assert, Fs.FileRead} =
        // クイックセーブはクイックのページの先頭へ入り、Qロードは確認の後にそこから読む。
        let res = TestKit.res();
        let here = readTo(res, "Paddy", Nil, begun(res));
        let saved = quiet(() -> WorldMenu.press(res, World.Button.QuickSave, here));
        let moved = readTo(res, "Lane", 1 :: Nil, saved);
        let asked = quiet(() -> WorldMenu.press(res, World.Button.QuickLoad, moved));
        let loaded = settle(res, quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked)));
        Assert.assertEq(expected = (Some(World.Ask.QuickLoad), placeOf(here)), (World.askOf(asked), placeOf(loaded)))

    @Test
    def testAutosaveAtEachNewNode(): Unit \ {Assert, Fs.FileRead} =
        // 新しいノードに入って最初の行を出すとオートのページの先頭へ残り、前の物は 1 つ後ろへずれる。同じノードの間は残さない。
        let res = TestKit.res();
        let atPaddy = readTo(res, "Paddy", Nil, begun(res));
        let next = settle(res, advance(res, atPaddy));
        let nodeAt = (i: Int32, w: World.World) -> Saves.slotOf(Saves.Tab.Auto, i, w#saves) |> Option.map(s -> s#mark#bookmark#node);
        let opening = Talk.nodeName(Talk.Node.Opening);
        Assert.assertEq(expected = (Some("Paddy"), Some(opening), Saves.serialOf(next#saves)),
                        (nodeAt(0, atPaddy), nodeAt(1, atPaddy), Saves.serialOf(atPaddy#saves)))

    @Test
    def testPushedPagesKeepOnlyTheNewestSix(): Unit \ {Assert, Fs.FileRead} =
        // オートとクイックのページは新しい 6 つだけを持つ（先頭が一番新しい）。
        let res = TestKit.res();
        let w = readTo(res, "Paddy", Nil, begun(res));
        let pushed = List.range(0, 8) |> List.foldLeft((acc, _) -> quiet(() -> WorldSaves.quickSave(res, acc)), w);
        let serials = List.range(0, Saves.perPage() + 1) |> List.map(i -> Saves.slotOf(Saves.Tab.Quick, i, pushed#saves) |> Option.map(s -> s#serial));
        let top = Saves.serialOf(pushed#saves);
        Assert.assertEq(expected = List.map(i -> if (i < Saves.perPage()) Some(top - i) else None, List.range(0, Saves.perPage() + 1)), serials)

    @Test
    def testSaveScreenOnlyWritesNumberedPages(): Unit \ {Assert, Fs.FileRead} =
        // セーブ画面はページ 1〜3 だけを巡り、オートのページを開いていても書かない。
        let res = TestKit.res();
        let w = readTo(res, "Paddy", Nil, begun(res));
        let opened = quiet(() -> WorldSaves.openSave(w));
        let cycled = quiet(() -> WorldSaves.moveTab(1, quiet(() -> WorldSaves.moveTab(1, quiet(() -> WorldSaves.moveTab(1, opened))))));
        let tabOf = (cur: World.World) -> World.slotsOf(cur) |> Option.map(fst) |> Option.map(Saves.isWritable);
        Assert.assertEq(expected = (Some(true), Some(true), false),
                        (tabOf(opened), tabOf(cycled), List.exists(t -> not Saves.isWritable(t), WorldSaves.tabsOf(opened))))

    @Test
    def testSavesSurviveJson(): Unit \ {Assert, Fs.FileRead} =
        // セーブデータ・既読・設定は JSON を通しても同じ。
        let res = TestKit.res();
        let chose = readTo(res, "Lane", 1 :: Nil, begun(res));
        let tuned = quiet(() -> WorldSettings.withSide(World.Pair.Display, Layout.Side.Right, quiet(() -> WorldSettings.withSide(World.Pair.SkipScope, Layout.Side.Right, chose))));
        let saves = quiet(() -> WorldSaves.writeSlot(res, page1(), 3, tuned))#saves;
        let back = Saves.fromJson(Saves.fresh(res#kind), Saves.toJson(saves));
        let shape = (whole: Saves.Saves) -> { let s = Saves.rec(whole); (Map.keysOf(s#slots), s#seen, s#serial, s#config#cps, s#config#skipScope, s#config#display,
                                        Map.valuesOf(s#slots) |> List.map(slot -> (slot#savedAt, slot#place, slot#mark#mode, slot#mark#bookmark#node))) };
        Assert.assertEq(expected = shape(saves), shape(back))

    @Test
    def testDateText(): Unit \ {Assert} =
        // 日時の字: 1970-01-01 からの秒を 年/月/日 時:分 に（うるう年の 2 月末も）。
        Assert.assertEq(expected = ("1970/01/01 00:00", "2024/02/29 23:59", "2026/08/14 19:32"),
                        (Saves.dateText(0i64), Saves.dateText(1709251140i64), Saves.dateText(1786735920i64)))

    // ══ 設定 ══

    @Test
    def testSlidersStayInRange(): Unit \ {Assert, Fs.FileRead} =
        // つまみの値は範囲の端で止まる。
        let res = TestKit.res();
        let w = w0(res);
        let pushed = (slider, delta) -> List.range(0, 100) |> List.foldLeft((acc, _) -> quiet(() -> WorldSettings.adjust(res, World.Setting.Slider(slider), delta, acc)), w);
        let levelAt = (slider, cur) -> WorldSettings.levelOf(slider, Saves.configOf(cur#saves));
        let ends = WorldSettings.settings() |> List.filterMap(setting -> match setting {
            case World.Setting.Slider(slider) =>
                let range = WorldSettings.rangeOf(slider, res#kind);
                Some((levelAt(slider, pushed(slider, -1)) == range#min, levelAt(slider, pushed(slider, 1)) == range#max))
            case _ => None
        });
        Assert.assertEq(expected = List.map(_ -> (true, true), ends), ends)

    @Test
    def testVolumeSettingsReachTheMixer(): Unit \ {Assert, Fs.FileRead} =
        // 全体の音量を 0 にすると、環境音と効果音のどちらのバスも 0 になる。
        let res = TestKit.res();
        let start = w0(res);
        let w = quiet(() -> WorldSettings.withLevel(res, World.Slider.MasterVolume, 0.0, start));
        let mixer = Controls.mixerOf(res, w);
        let state = AudioMixer.initial();
        Assert.assertEq(expected = (0.0, 0.0), (AudioMixer.busGainOf(mixer, state, "ambience"), AudioMixer.busGainOf(mixer, state, "se")))

    @Test
    def testResetRestoresDefaults(): Unit \ {Assert, Fs.FileRead} =
        // 初期設定に戻すは、尋ねてから novel.kind.json の既定へ戻す。
        let res = TestKit.res();
        let start = w0(res);
        let changed = quiet(() -> WorldSettings.withLevel(res, World.Slider.TextSpeed, 120.0, quiet(() -> WorldSettings.withSide(World.Pair.Display, Layout.Side.Right, start))));
        let reset = quiet(() -> WorldMenu.answer(res, World.Answer.Yes, quiet(() -> WorldSettings.activate(World.Setting.Reset, changed))));
        Assert.assertEq(expected = (kind(res)#cps, false), (Saves.configOf(reset#saves)#cps, WorldSettings.isFullscreen(reset)))

    @Test
    def testPairSettingsToggle(): Unit \ {Assert, Fs.FileRead} =
        // 2 つから選ぶ行は決定で反対側へ（フルスクリーンの宣言が替わる）。
        let res = TestKit.res();
        let start = w0(res);
        let once = quiet(() -> WorldSettings.activate(World.Setting.Pair(World.Pair.Display), start));
        let twice = quiet(() -> WorldSettings.activate(World.Setting.Pair(World.Pair.Display), once));
        Assert.assertEq(expected = (false, true, false), (WorldSettings.isFullscreen(start), WorldSettings.isFullscreen(once), WorldSettings.isFullscreen(twice)))

    // ══ 返事の音 ══

    @Test
    def testScriptSoundEffectsAreHeard(): Unit \ {Assert, Fs.FileRead} =
        // 台本の <<se>> は se_<名前> の出来事になり、Controls が同じ名前の音を鳴らす。
        let res = TestKit.res();
        let atLane = readTo(res, "Lane", 1 :: Nil, begun(res));
        let (_, heard) = TestKit.readHearing(res, w -> World.talkNodeOf(w) == "Engawa", Nil, atLane);
        Assert.assertEq(expected = (true, Some("se_slap")),
                        (List.memberOf(World.Event.Cue("se_slap"), heard), Controls.soundOf(World.Event.Cue("se_slap"))))

    @Test
    def testLoadingIsSilent(): Unit \ {Assert, Fs.FileRead} =
        // ロードで読み直す時、通り過ぎた <<se>> は鳴らさない（返事は Loaded の 1 つだけ）。
        let res = TestKit.res();
        let past = readTo(res, "Engawa", 1 :: Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, Saves.Tab.Numbered(1), 0, past));
        let (_, heard) = Emit.collect(() -> WorldSaves.loadFrom(res, Saves.Tab.Numbered(1), 0, saved));
        Assert.assertEq(expected = World.Event.Loaded :: Nil, heard)
}
