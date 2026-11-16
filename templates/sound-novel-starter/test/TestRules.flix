// ルールと進行だけをテストする。座標・描き方・文字送りの見た目はテストしない。
// シナリオは作例の写し（TestKit.res）。行の文字は写さず、ノードの名前・変数・シナリオの木から期待値を導く。
// 作例のシナリオに無い効果音だけは、テスト用の木（TestKit.fixtureRes）で見る。ゲームの台本と Doc を見るのは Controls.loadRes の物だけ。
// 作例の筋（どの選択肢でどの結末か）は作例を確かめるテスト（mod TestSample。make new-game が外す）。
mod TestRules {

    use fge::{App, AudioMixer, Clock, Emit, JsonCodec, Vec2, Yarn, YarnRunner}
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
        // はじめから: novel.story.json の opening の最初の台詞を、台本の頭のコマンドどおりの舞台で出す。
        let res = TestKit.res();
        let w = begun(res);
        let opening = StoryDoc.openingOf(res#story);
        Assert.assertEq(expected = ("Reading", opening, List.head(sayLines(res, opening)), "nvl"),
                        (World.sceneName(w), World.talkNodeOf(w), Some(lineNo(w)), World.stageOf(res, w)#mode))

    /// ゲームの novel.shots.json の場面は全部、ゲームの Doc と台本で、実機と同じ App から shot:<名前> の始まりで組める。
    @Test
    def testEveryShotBuildsFromTheApp(): Unit \ {Assert, Fs.FileRead} =
        let res = Controls.loadRes();
        let app = TestKit.app(res, w0(res));
        Assert.assertEq(expected = Nil,
            Shots.names(res) |> List.filter(name -> Result.isErr(App.buildStart(app, Vec2.zero(), App.shotStartName(name), Map.empty()))))

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
        let opening = StoryDoc.openingOf(res#story);
        Assert.assertEq(expected = (List.nth(1, sayLines(res, opening)), true, w#saveRev + 1),
                        (Some(lineNo(next)), Saves.isSeen(World.talkLineOf(w), next#saves), next#saveRev))

    @Test
    def testNvlPageKeepsEarlierLinesUntilClear(): Unit \ {Assert, Fs.FileRead} =
        // NVL は頁に前の行を積んだまま次の行を足す（<<window clear>> まではめくらない）。
        let res = TestKit.res();
        let w = begun(res) |> advance(res) |> settle(res) |> advance(res) |> settle(res);
        Assert.assertEq(expected = 2, List.length(World.pageOf(w)#lines))

    @Test
    def testNvlPageTurnsWhenRowsRunOut(): Unit \ {Assert} =
        // 頁に入り切らない行が来たら、頁をめくってその行だけにする。
        let line = text -> Page.plainLine(text, text);
        let fits = lines -> List.length(lines) <= 2;
        let page = Page.empty() |> Page.show(ThemeDoc.WindowKind.Nvl, fits, line("a")) |> Page.show(ThemeDoc.WindowKind.Nvl, fits, line("b"))
                                |> Page.show(ThemeDoc.WindowKind.Nvl, fits, line("c"));
        Assert.assertEq(expected = (0, Some("c")), (List.length(page#lines), page#current |> Option.map(l -> l#text)))

    @Test
    def testAdvStacksLinesOnThePage(): Unit \ {Assert, Fs.FileRead} =
        // ADV の台詞も頁に積む（横の ADV のウィンドウは今の 1 行だけを描き、縦の画面は頁に積んで描く）。
        let res = TestKit.res();
        let w = readTo(res, "StudioWindow", 0 :: Nil, begun(res)) |> advance(res) |> settle(res);
        Assert.assertEq(expected = ("bottom", 1), (World.stageOf(res, w)#mode, List.length(World.pageOf(w)#lines)))

    @Test
    def testAdvDropsOldestLinesWhenThePageIsFull(): Unit \ Assert =
        // ADV は頁に入り切らない時、頁をめくらずに古い行から落として積み続ける。
        let fits = lines -> List.length(lines) <= 2;
        let line = text -> Page.plainLine(text, text);
        let page = Page.empty() |> Page.show(ThemeDoc.WindowKind.Adv, fits, line("a")) |> Page.show(ThemeDoc.WindowKind.Adv, fits, line("b"))
                                |> Page.show(ThemeDoc.WindowKind.Adv, fits, line("c"));
        Assert.assertEq(expected = ("b" :: Nil, Some("c")), (page#lines |> List.map(l -> l#text), page#current |> Option.map(l -> l#text)))

    @Test
    def testAdvBackdropCueStartsANewPage(): Unit \ {Assert, Fs.FileRead} =
        // ADV のまま次の場面（背景を替える）へ進むと、前の場面の台詞は頁に残らない。
        let res = TestKit.res();
        let before = readTo(res, "Invitation", 0 :: 0 :: Nil, begun(res));
        let earlier = sayLines(res, "LastDelivery") |> List.map(n -> "${n}") |> List.toSet;
        let inside = before |> advance(res) |> settle(res) |> advance(res) |> settle(res);
        let carried = World.pageOf(inside)#lines |> List.exists(l -> Set.memberOf(lineOfSource(l#source), earlier));
        Assert.assertEq(expected = ("bottom", false), (World.stageOf(res, inside)#mode, carried))

    /// 頁の行の source（「ファイル:行」）の行番号の字。
    def lineOfSource(source: String): String =
        source |> String.splitOn(substr = ":") |> List.last |> Option.getWithDefault("")

    @Test
    def testAdvPageTurnsWhenTheBackdropChanges(): Unit \ Assert =
        // ADV で場面が変わる（背景を替える）と、次の行から新しい頁になる。今の行は次の行まで出したまま。
        let fits = _ -> true;
        let line = text -> Page.plainLine(text, text);
        let turned = Page.empty() |> Page.show(ThemeDoc.WindowKind.Adv, fits, line("a")) |> Page.show(ThemeDoc.WindowKind.Adv, fits, line("b")) |> Page.turn;
        let next = turned |> Page.show(ThemeDoc.WindowKind.Adv, fits, line("c"));
        Assert.assertEq(expected = ((0, Some("b")), (0, Some("c"))),
                        ((List.length(turned#lines), turned#current |> Option.map(l -> l#text)),
                         (List.length(next#lines), next#current |> Option.map(l -> l#text))))

    // ══ 選択肢と変数 ══

    @Test
    def testChoicesBlockAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出している間は決定で先へ進めない（pick だけが進める）。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let after = settle(res, advance(res, asking));
        Assert.assertEq(expected = (true, placeOf(asking)), (World.isChoosing(after), placeOf(after)))

    @Test
    def testConditionalChoiceNeedsBothLetters(): Unit \ {Assert, Fs.FileRead} =
        // 工房の誘いの選択肢の 1 つ目は $own_pace and $shared_tiredness の時だけ選べる。どちらも無ければ選べない目印つきで並び、pick しても動かない。
        let res = TestKit.res();
        let invited = readTo(res, "Invitation", 1 :: 1 :: Nil, begun(res)) |> (w -> TestKit.readUntil(res, World.isChoosing, Nil, w));
        let tried = settle(res, pick(res, 0, invited));
        let available = World.choicesOf(invited) |> List.map(option -> option#available);
        Assert.assertEq(expected = (false :: true :: true :: Nil, placeOf(invited)), (available, placeOf(tried)))

    @Test
    def testCursorSkipsChoicesThatCannotBePicked(): Unit \ {Assert, Fs.FileRead} =
        // 選べない選択肢にはカーソルが止まらない（1 つ目が選べない時、どちらへ動かしても 2 つ目か 3 つ目）。
        let res = TestKit.res();
        let invited = readTo(res, "Invitation", 1 :: 1 :: Nil, begun(res)) |> (w -> TestKit.readUntil(res, World.isChoosing, Nil, w));
        let cursorAfter = delta -> World.readOf(quiet(() -> WorldRead.moveChoice(delta, invited))) |> Option.map(r -> r#choiceCursor);
        Assert.assertEq(expected = (Some(2), Some(1)), (cursorAfter(1), cursorAfter(2)))

    @Test
    def testStoryEndRollsTheCredits(): Unit \ {Assert, Fs.FileRead} =
        // シナリオの終わりまで読むとクレジットへ。
        let res = TestKit.res();
        let done = TestKit.readUntil(res, World.isCredits, 0 :: 0 :: 0 :: Nil, begun(res));
        Assert.assertEq(expected = true, World.isCredits(done))

    // ══ 演出 ══

    @Test
    def testEveryCommandInTheScriptIsUnderstood(): Unit \ {Assert, Fs.FileRead} =
        // ゲームのシナリオのコマンドは全部、ゲームの命令も入れた Commands の表で読めて当てられる（写真・時間帯の名前は backdrops にある）。wait は実行器が待つ。
        let res = Controls.loadRes();
        let ctx = { now = Clock.zero(), node = "", res = res, instant = false };
        let bad = commandsOf(res#dialogue) |> List.filter(c -> c#name != "wait")
            |> List.filterMap(c -> match Commands.execute(Commands.Replay.Silent, ctx, c, Stage.empty()) {
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
        // 選んだ後の行から戻ると、問いの行へ戻って選び直せる。選んだ枝の <<set>> を過ぎた行から戻ると、その <<set>> も取り消される。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let chose = settle(res, pick(res, 0, asking));
        let back = settle(res, quiet(() -> WorldLog.rollback(res, chose)));
        let set = TestKit.readUntil(res, w -> World.variableOf("$own_pace", w) == "True", Nil, chose);
        let unset = settle(res, quiet(() -> WorldLog.rollback(res, set)));
        Assert.assertEq(expected = (placeOf(asking), true, "False"),
                        (placeOf(back), World.isChoosing(settle(res, advance(res, back))), World.variableOf("$own_pace", unset)))

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
        let before = readTo(res, "StudioWindow", 0 :: Nil, begun(res)) |> advance(res) |> settle(res);
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
        let atEaves = readTo(res, "StudioWindow", 0 :: Nil, begun(res)) |> advance(res) |> settle(res) |> advance(res) |> settle(res);
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, atEaves));
        let elsewhere = readTo(res, "Reply", Nil, saved);
        let loaded = settle(res, quiet(() -> WorldSaves.loadFrom(res, page1(), 0, elsewhere)));
        let stageOf = (w: World.World) -> { let st = World.stageOf(res, w); (st#shot |> Option.map(shot -> (shot#photo, shot#grade)), st#mode, Stage.ambienceOf(World.now(w), st)) };
        Assert.assertEq(expected = (placeOf(atEaves), stageOf(atEaves)), (placeOf(loaded), stageOf(loaded)))

    @Test
    def testLoadingRestoresVariables(): Unit \ {Assert, Fs.FileRead} =
        // セーブは変数も戻す（選んだ後にセーブしたデータでは $own_pace が残る）。
        let res = TestKit.res();
        let chose = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 2, chose));
        let loaded = settle(res, quiet(() -> WorldSaves.loadFrom(res, page1(), 2, quiet(() -> WorldRead.newGame(res, saved)))));
        Assert.assertEq(expected = "True", World.variableOf("$own_pace", loaded))

    @Test
    def testSlotRemembersWhereAndWhen(): Unit \ {Assert, Fs.FileRead} =
        // データには場所（写真の名前）・台詞の頭・保存した日時（起動の時刻 + 実時間）が入る。
        let res = TestKit.res();
        let atEaves = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let w = { clockBase = 1000i64, realNow = Clock.after(42.5, Clock.zero()) | atEaves };
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, w));
        let place = World.stageOf(res, w)#shot |> Option.flatMap(shot -> BackdropDoc.photoOf(shot#photo, res#backdrops)) |> Option.map(p -> p#label);
        let slot = Saves.slotOf(page1(), 0, saved#saves);
        Assert.assertEq(expected = Some((place |> Option.getWithDefault(""), 1042i64, true)),
                        slot |> Option.map(s -> (s#place, s#savedAt, String.startsWith(prefix = s#excerpt, World.talkLineOf(w)) or not String.isEmpty(s#excerpt))))

    @Test
    def testSavingOverAFilledSlotAsksFirst(): Unit \ {Assert, Fs.FileRead} =
        // 埋まっている枠を選ぶと上書きを尋ね、いいえなら前のデータのまま、はいなら今の所で書き直す。
        let res = TestKit.res();
        let first = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, first));
        let later = quiet(() -> WorldSaves.openSave(readTo(res, "Reply", Nil, saved)));
        let asked = quiet(() -> WorldSaves.withTab(page1(), later) |> (opened -> WorldSaves.chooseSlot(res, 0, opened)));
        let nodeIn = (w: World.World) -> Saves.slotOf(page1(), 0, w#saves) |> Option.map(s -> s#mark#bookmark#node);
        Assert.assertEq(expected = (Some(World.Ask.Overwrite(page1(), 0)), Some("StudioWindow"), Some("Reply")),
                        (World.askOf(asked), nodeIn(quiet(() -> WorldMenu.answer(res, World.Answer.No, asked))), nodeIn(quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked)))))

    @Test
    def testDeletingASlotAsksThenRemovesIt(): Unit \ {Assert, Fs.FileRead} =
        // 削除は尋ねてから消す。
        let res = TestKit.res();
        let here = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, page1(), 1, here));
        let asked = quiet(() -> WorldSaves.deleteSlot(1, WorldSaves.withTab(page1(), WorldSaves.openSave(saved))));
        let gone = quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked));
        Assert.assertEq(expected = (Some(World.Ask.Delete(page1(), 1)), false),
                        (World.askOf(asked), Option.nonEmpty(Saves.slotOf(page1(), 1, gone#saves))))

    @Test
    def testContinueLoadsTheNewestSave(): Unit \ {Assert, Fs.FileRead} =
        // タイトルの「つづきから」は、ページを問わずいちばん新しいデータを読む。
        let res = TestKit.res();
        let here = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let a = quiet(() -> WorldSaves.writeSlot(res, page1(), 0, here));
        let b = quiet(() -> WorldSaves.writeSlot(res, Saves.Tab.Numbered(3), 5, readTo(res, "Reply", Nil, a)));
        let continued = settle(res, quiet(() -> WorldMenu.chooseTitle(res, World.TitleItem.Continue, World.toTitle(b))));
        Assert.assertEq(expected = (Some((Saves.Tab.Numbered(3), 5)), "Reply"), (Saves.latest(b#saves), World.talkNodeOf(continued)))

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
        let here = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let saved = quiet(() -> WorldMenu.press(res, World.Button.QuickSave, here));
        let moved = readTo(res, "Reply", Nil, saved);
        let asked = quiet(() -> WorldMenu.press(res, World.Button.QuickLoad, moved));
        let loaded = settle(res, quiet(() -> WorldMenu.answer(res, World.Answer.Yes, asked)));
        Assert.assertEq(expected = (Some(World.Ask.QuickLoad), placeOf(here)), (World.askOf(asked), placeOf(loaded)))

    @Test
    def testAutosaveAtEachNewNode(): Unit \ {Assert, Fs.FileRead} =
        // 新しいノードに入って最初の行を出すとオートのページの先頭へ残り、前の物は 1 つ後ろへずれる。同じノードの間は残さない。
        let res = TestKit.res();
        let atLetter = readTo(res, "FirstLetter", Nil, begun(res));
        let next = settle(res, advance(res, atLetter));
        let nodeAt = (i: Int32, w: World.World) -> Saves.slotOf(Saves.Tab.Auto, i, w#saves) |> Option.map(s -> s#mark#bookmark#node);
        let opening = StoryDoc.openingOf(res#story);
        Assert.assertEq(expected = (Some("FirstLetter"), Some(opening), Saves.serialOf(next#saves)),
                        (nodeAt(0, atLetter), nodeAt(1, atLetter), Saves.serialOf(atLetter#saves)))

    @Test
    def testPushedPagesKeepOnlyTheNewestSix(): Unit \ {Assert, Fs.FileRead} =
        // オートとクイックのページは新しい 6 つだけを持つ（先頭が一番新しい）。
        let res = TestKit.res();
        let w = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let pushed = List.range(0, 8) |> List.foldLeft((acc, _) -> quiet(() -> WorldSaves.quickSave(res, acc)), w);
        let serials = List.range(0, Saves.perPage() + 1) |> List.map(i -> Saves.slotOf(Saves.Tab.Quick, i, pushed#saves) |> Option.map(s -> s#serial));
        let top = Saves.serialOf(pushed#saves);
        Assert.assertEq(expected = List.map(i -> if (i < Saves.perPage()) Some(top - i) else None, List.range(0, Saves.perPage() + 1)), serials)

    @Test
    def testSaveScreenOnlyWritesNumberedPages(): Unit \ {Assert, Fs.FileRead} =
        // セーブ画面はページ 1〜3 だけを巡り、オートのページを開いていても書かない。
        let res = TestKit.res();
        let w = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let opened = quiet(() -> WorldSaves.openSave(w));
        let cycled = quiet(() -> WorldSaves.moveTab(1, quiet(() -> WorldSaves.moveTab(1, quiet(() -> WorldSaves.moveTab(1, opened))))));
        let tabOf = (cur: World.World) -> World.slotsOf(cur) |> Option.map(fst) |> Option.map(Saves.isWritable);
        Assert.assertEq(expected = (Some(true), Some(true), false),
                        (tabOf(opened), tabOf(cycled), List.exists(t -> not Saves.isWritable(t), WorldSaves.tabsOf(opened))))

    @Test
    def testSavesSurviveJson(): Unit \ {Assert, Fs.FileRead} =
        // セーブデータ・既読・設定は JSON を通しても同じ。
        let res = TestKit.res();
        let chose = readTo(res, "StudioWindow", 0 :: Nil, begun(res));
        let tuned = quiet(() -> WorldSettings.withSide(World.Pair.Display, Layout.Side.Right, quiet(() -> WorldSettings.withSide(World.Pair.SkipScope, Layout.Side.Right, chose))));
        let saves = quiet(() -> WorldSaves.writeSlot(res, page1(), 3, tuned))#saves;
        let back = Saves.fromJson(Saves.fresh(res#kind), Saves.toJson(saves));
        let shape = (whole: Saves.Saves) -> { let s = Saves.rec(whole); (Map.keysOf(s#slots), s#seen, s#serial, s#config#cps, s#config#skipScope, s#config#display,
                                        Map.valuesOf(s#slots) |> List.map(slot -> (slot#savedAt, slot#place, Stage.fromSnapshot(slot#mark#stage)#mode, slot#mark#bookmark#node))) };
        Assert.assertEq(expected = shape(saves), shape(back))

    // ── セーブの形の版（Saves.formOf・decode・World.opened） ──

    /// クイックセーブを 1 つ持つセーブの JSON。
    def savedJson(res: Res.Res): Util.Json.Json =
        Saves.toJson(quiet(() -> WorldSaves.quickSave(res, begun(res)))#saves)

    /// 一番上の欄 key を value に替えた JSON。
    def withField(key: String, value: Util.Json.Json, json: Util.Json.Json): Util.Json.Json =
        Util.Json.Json.JObject(Map.insert(key, value, JsonCodec.expectObject(json) |> Option.getWithDefault(Map.empty())))

    def versioned(v: Int32, json: Util.Json.Json): Util.Json.Json = withField("version", Util.Json.Json.JNumber(JsonCodec.intToBd(v)), json)

    /// どの枠からも "stage" を外した JSON（テンプレートの外で同じ version 3 を使った別の形）。
    def withoutStage(json: Util.Json.Json): Util.Json.Json =
        let root = JsonCodec.expectObject(json) |> Option.getWithDefault(Map.empty());
        let slots = Map.get("slots", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty())
            |> Map.map(slot -> Util.Json.Json.JObject(Map.remove("stage", JsonCodec.expectObject(slot) |> Option.getWithDefault(Map.empty()))));
        withField("slots", Util.Json.Json.JObject(slots), json)

    @Test
    def testSavesAreWrittenInTheCurrentForm(): Unit \ {Assert, Fs.FileRead} =
        let json = savedJson(TestKit.res());
        Assert.assertEq(expected = (Some(Saves.formatVersion()), Saves.Form.Current),
                        (JsonCodec.expectObject(json) |> Option.flatMap(root -> Map.get("version", root)) |> Option.flatMap(JsonCodec.expectInt), Saves.formOf(json)))

    @Test
    def testVersion3WithTheStageIsStillRead(): Unit \ {Assert, Fs.FileRead} =
        // 0.96.0・0.97.0 のテンプレートが書いた version 3（どの枠も "stage" を持つ）は読む。
        let res = TestKit.res();
        Assert.assertTrue(Saves.decode(Saves.fresh(res#kind), versioned(3, savedJson(res))) |> Option.exists(Saves.hasAny))

    @Test
    def testVersion3WithoutTheStageIsRefused(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        Assert.assertEq(expected = None, Saves.decode(Saves.fresh(res#kind), withoutStage(versioned(3, savedJson(res)))) |> Option.map(Saves.hasAny))

    @Test
    def testVersion2IsReadAsTheLegacyForm(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Saves.Form.Legacy, Saves.formOf(withoutStage(versioned(2, savedJson(TestKit.res())))))

    @Test
    def testALaterVersionIsRefused(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Saves.Form.Foreign, Saves.formOf(versioned(Saves.formatVersion() + 1, savedJson(TestKit.res()))))

    @Test
    def testRefusedSavesAreToldAtTheTitle(): Unit \ {Assert, Fs.FileRead} =
        // 読めない形のセーブだった起動は、タイトルで「この版では読めない」と知らせ、セーブは空。
        let res = TestKit.res();
        let w = World.opened({ saves = Saves.fresh(res#kind), refused = true, keptAs = None }, 0i64);
        Assert.assertEq(expected = ("Title", Some(StoryDoc.labelOf(StoryDoc.Label.SavesRefused, res#story)), false),
                        (World.sceneName(w), World.toastOf(res, w), Saves.hasAny(w#saves)))

    @Test
    def testKeptRefusedSavesAreToldAtTheTitle(): Unit \ {Assert, Fs.FileRead} =
        // 断ったファイルを写して残せた時は、残したことも知らせる。
        let res = TestKit.res();
        let w = World.opened({ saves = Saves.fresh(res#kind), refused = true, keptAs = Some(Saves.refusedPath(3)) }, 0i64);
        Assert.assertEq(expected = Some(StoryDoc.labelOf(StoryDoc.Label.SavesRefusedKept, res#story)), World.toastOf(res, w))

    @Test
    def testReadableSavesAreNotTold(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        Assert.assertEq(expected = None, World.toastOf(res, World.opened({ saves = Saves.fresh(res#kind), refused = false, keptAs = None }, 0i64)))

    /// files（道 → 中身）を Fs.FileRead に答え、Fs.FileWrite の write を (道, 中身) で written に積んで f を流す（ほかの書き方は Err）。
    def withFiles(files: Map[String, String], written: Ref[List[(String, String)], r], f: Unit -> a \ ef): a \ (ef - Fs.FileRead - Fs.FileWrite) + r =
        let lookup = path -> Map.get(path, files) |> Option.toOk(IoError.IoError(IoError.ErrorKind.NotFound, path));
        let refuse = path -> Err(IoError.IoError(IoError.ErrorKind.Unsupported, path));
        run { f() } with handler Fs.FileRead {
            def read(path, k)      = k(lookup(path))
            def readLines(path, k) = k(lookup(path) |> Result.map(String.lines))
            def readBytes(path, k) = k(lookup(path) |> Result.map(String.toBytes))
        } with handler Fs.FileWrite {
            def write(data, path, k)        = { Ref.put((path, data#str) :: Ref.get(written), written); k(Ok(())) }
            def writeLines(_data, path, k)  = k(refuse(path))
            def writeBytes(_data, path, k)  = k(refuse(path))
            def append(_data, path, k)      = k(refuse(path))
            def appendLines(_data, path, k) = k(refuse(path))
            def appendBytes(_data, path, k) = k(refuse(path))
            def truncate(path, k)           = k(refuse(path))
            def copyWith(_src, dst, _opts, k) = k(refuse(dst))
            def moveWith(_src, dst, _opts, k) = k(refuse(dst))
            def delete(path, k)             = k(refuse(path))
            def mkDir(_dir, k)              = k(Ok(()))
            def mkDirs(_dir, k)             = k(Ok(()))
            def mkTempDir(prefix, k)        = k(Err(IoError.IoError(IoError.ErrorKind.Unsupported, prefix)))
        }

    /// files の上で Saves.load を流し、(断ったか, 残した先, 書いた (道, 中身) の列) を返す。
    def loadOn(res: Res.Res, files: Map[String, String]): (Bool, Option[String], List[(String, String)]) = region rc {
        let written = Ref.fresh(rc, Nil);
        let opened = withFiles(files, written, () -> Saves.load(res#kind));
        (opened#refused, opened#keptAs, Ref.get(written))
    }

    def textOf(json: Util.Json.Json): String = Util.Json.toPrettyString(2, json)

    @Test
    def testRefusedSaveIsCopiedBeforeItIsOverwritten(): Unit \ {Assert, Fs.FileRead} =
        // stage の無い version 3 を読むと断り、元の中身をそのまま refusedPath(3) へ写す。
        let res = TestKit.res();
        let old = textOf(withoutStage(versioned(3, savedJson(res))));
        Assert.assertEq(expected = (true, Some(Saves.refusedPath(3)), (Saves.refusedPath(3), old) :: Nil),
                        loadOn(res, Map#{ Saves.path() => old }))

    @Test
    def testAnEarlierKeptFileIsNotOverwritten(): Unit \ {Assert, Fs.FileRead} =
        // 前に残したファイルが同じ名前であれば、書かずにそれを残した先にする。
        let res = TestKit.res();
        let old = textOf(withoutStage(versioned(3, savedJson(res))));
        Assert.assertEq(expected = (true, Some(Saves.refusedPath(3)), Nil),
                        loadOn(res, Map#{ Saves.path() => old, Saves.refusedPath(3) => "前の物" }))

    @Test
    def testReadableSaveIsNotCopied(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        Assert.assertEq(expected = (false, None, Nil), loadOn(res, Map#{ Saves.path() => textOf(savedJson(res)) }))

    @Test
    def testSaveWithShortAmbienceNameReadsTheSoundName(): Unit \ {Assert, Fs.FileRead} =
        // ambience の鍵に amb_ の無い短い名前（"evening"）で書いた枠は、音の名前（amb_evening）として読む。
        let res = TestKit.res();
        let bookmark = WorldRead.slotHere(res, begun(res)) |> Option.map(s -> YarnRunner.bookmarkToJson(s#mark#bookmark));
        let read = bookmark
            |> Option.map(bm -> Util.Json.Json.JObject(Map#{ "slots" => Util.Json.Json.JObject(Map#{
                   "0" => Util.Json.Json.JObject(Map#{ "bookmark" => bm, "ambience" => Util.Json.Json.JString("evening") }) }) }))
            |> Option.map(Saves.fromJson(Saves.fresh(res#kind)))
            |> Option.map(s -> Saves.rec(s)#slots |> Map.valuesOf |> List.map(x -> ambienceOfMark(x#mark)));
        Assert.assertEq(expected = Some(Some("amb_evening") :: Nil), read)

    /// 戻れる所の舞台で鳴っている環境音。
    def ambienceOfMark(mark: Saves.Mark): Option[String] =
        PropertyTween.nameEnd(Stage.ambienceKey(), Stage.fromSnapshot(mark#stage)#props)

    @Test
    def testAmbienceSoundNameWithoutAmbPrefixSurvivesJson(): Unit \ {Assert, Fs.FileRead} =
        // amb_ で始まらない音の名前（rain_loop）の環境音も、セーブの JSON を通してそのまま戻る。
        let res = TestKit.res();
        let saves = WorldRead.slotHere(res, begun(res))
            |> Option.map(slot -> {
                let stage = Stage.withAmbience(Clock.zero(), Some("rain_loop"), Stage.fromSnapshot(slot#mark#stage));
                Saves.withPushed(Saves.Tab.Quick, { mark = { stage = Stage.snapshotOf(stage) | slot#mark } | slot }, Saves.fresh(res#kind))
            });
        let read = saves |> Option.map(s -> Saves.fromJson(Saves.fresh(res#kind), Saves.toJson(s)))
            |> Option.map(s -> Saves.rec(s)#slots |> Map.valuesOf |> List.map(x -> ambienceOfMark(x#mark)));
        Assert.assertEq(expected = Some(Some("rain_loop") :: Nil), read)

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
    def testHeldPointerDragsTheSlider(): Unit \ {Assert, Fs.FileRead} =
        // 帯の左端で押し始め、押したまま（指なら横へなぞったまま）帯の上を動かすと、クリックのフレームが無くても値が付いて動く。
        // 帯の左端 → 右端と動かすと、文字の速さは下限 → 上限（= ノーウェイト）になる。
        let res = TestKit.res();
        let fit = Layout.Fit.Regular;
        let bar = Layout.settingBar(fit, 0);
        let held = x -> { mouseDown = true, mouseMoved = true, cursor = { x = x, y = bar#position#y + bar#size#y / 2.0 } | App.emptyFrame() };
        let opened = quiet(() -> WorldSettings.openSettings(w0(res)));
        let left = Controls.interact({ mouseClicked = true | held(bar#position#x) }, res, opened);
        let right = Controls.interact(held(bar#position#x + bar#size#x), res, left);
        let cps = cur -> Saves.configOf(cur#saves)#cps;
        let range = kind(res)#cpsSlider;
        Assert.assertEq(expected = (range#min, range#max, true), (cps(left), cps(right), KindDoc.isNoWait(cps(right), res#kind)))

    @Test
    def testDragStaysOnTheFirstSlider(): Unit \ {Assert, Fs.FileRead} =
        // 文字の速さの帯を掴んだまま、下の行（オートの待ち）の帯の右端へずれても、動くのは文字の速さだけ。離すと掴みが外れる。
        let res = TestKit.res();
        let fit = Layout.Fit.Regular;
        let first = Layout.settingBar(fit, 0);
        let second = Layout.settingBar(fit, 1);
        let frame = (down, x, y) -> { mouseDown = down, mouseMoved = true, cursor = { x = x, y = y } | App.emptyFrame() };
        let opened = quiet(() -> WorldSettings.openSettings(w0(res)));
        let start = Controls.interact({ mouseClicked = true | frame(true, first#position#x, first#position#y + first#size#y / 2.0) }, res, opened);
        let slid = Controls.interact(frame(true, second#position#x + second#size#x, second#position#y + second#size#y / 2.0), res, start);
        let released = Controls.interact(frame(false, second#position#x, second#position#y + second#size#y / 2.0), res, slid);
        let c = Saves.configOf(released#saves);
        Assert.assertEq(expected = (kind(res)#cpsSlider#max, kind(res)#autoWait, World.Grab.Free), (c#cps, c#autoWait, released#grab))

    @Test
    def testPressHeldFromThePreviousScreenGrabsNoSlider(): Unit \ {Assert, Fs.FileRead} =
        // 前の画面で押したまま設定が開くと、指がスライダーの帯の上にあっても、離すまでどのスライダーも掴まない（値は既定のまま）。
        let res = TestKit.res();
        let reach = Layout.settingBarReach(Layout.Fit.Regular, 0);
        let held = { mouseDown = true, mouseMoved = true, cursor = { x = reach#position#x + reach#size#x - 1.0, y = reach#position#y + reach#size#y / 2.0 } | App.emptyFrame() };
        let opened = quiet(() -> WorldSettings.openSettings(w0(res)));
        let after = Controls.interact(held, res, Controls.interact(held, res, opened));
        Assert.assertEq(expected = (kind(res)#cps, false), (Saves.configOf(after#saves)#cps, isSliderGrabbed(after)))

    def isSliderGrabbed(w: World.World): Bool = match w#grab {
        case World.Grab.Slider(_) => true
        case _                    => false
    }

    @Test
    def testNoWaitShowsTheWholeLineAtOnce(): Unit \ {Assert, Fs.FileRead} =
        // 文字の速さが最大（ノーウェイト）なら、行は出た拍に全部出る（文字送りしない）。
        let res = TestKit.res();
        let fast = quiet(() -> WorldSettings.withLevel(res, World.Slider.TextSpeed, kind(res)#cpsSlider#max, w0(res)));
        let opened = quiet(() -> WorldRead.newGame(res, fast));
        let shown = opened |> TestKit.stepBy(res, waitOf(opened) + 0.02);
        Assert.assertTrue(Page.isDone(World.pageOf(shown)))

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
        // シナリオの <<audio se 音>> はその音の名前の出来事になり、Controls が同じ名前の音を鳴らす。
        let res = TestKit.fixtureRes("test/fixtures/sound", "Sound");
        let (_, heard) = TestKit.readHearing(res, w -> World.talkNodeOf(w) == "SoundAfter", Nil, begun(res));
        Assert.assertEq(expected = (true, Some("se_slap")),
                        (List.memberOf(World.Event.Cue("se_slap"), heard), Controls.soundOf(World.Event.Cue("se_slap"))))

    @Test
    def testLoadingIsSilent(): Unit \ {Assert, Fs.FileRead} =
        // ロードで読み直す時、通り過ぎた <<audio se>> は鳴らさない（返事は Loaded の 1 つだけ）。
        let res = TestKit.fixtureRes("test/fixtures/sound", "Sound");
        let past = readTo(res, "SoundAfter", Nil, begun(res));
        let saved = quiet(() -> WorldSaves.writeSlot(res, Saves.Tab.Numbered(1), 0, past));
        let (_, heard) = Emit.collect(() -> WorldSaves.loadFrom(res, Saves.Tab.Numbered(1), 0, saved));
        Assert.assertEq(expected = World.Event.Loaded :: Nil, heard)

    // ── 台本の字の置き換え（novel.story.json の replace） ──

    def withReplace(table: Map[String, String], res: Res.Res): Res.Res =
        Res.withStory(StoryDoc.Doc.Doc({ replace = table | StoryDoc.rec(res#story) }), res)

    def currentText(w: World.World): String = World.pageOf(w)#current |> Option.map(l -> l#text) |> Option.getWithDefault("")

    /// 最初の台詞の頭の 2 字を ★ に替える表（行の字を写さずに、本物のシナリオの字から作る）。
    def headTable(res: Res.Res): (String, Map[String, String]) =
        let head = String.takeLeft(2, currentText(begun(res)));
        (head, Map#{ head => "★" })

    @Test
    def testReplaceIsAppliedToTheShownLine(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        let (head, table) = headTable(res);
        let shown = currentText(begun(withReplace(table, res)));
        Assert.assertEq(expected = (true, false), (String.startsWith(prefix = "★", shown), String.contains(substr = head, shown)))

    @Test
    def testReplaceIsAppliedToTheBacklog(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        let (_, table) = headTable(res);
        let logged = World.logOf(begun(withReplace(table, res))) |> List.filterMap(entry -> match entry {
            case World.Entry.Said(line, _) => Some(line#text)
            case _                         => None
        });
        Assert.assertTrue(logged |> List.exists(String.startsWith(prefix = "★")))

    @Test
    def testReplaceIsAppliedToTheSpeakerName(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        let id = StoryDoc.speakerIds(res#story) |> List.head |> Option.getWithDefault("");
        let name = StoryDoc.nameOf(id, res#story);
        Assert.assertEq(expected = "★", StoryDoc.nameOf(id, withReplace(Map#{ name => "★" }, res)#story))

    def replacing(table: Map[String, String], text: String): String =
        StoryDoc.replaceText(StoryDoc.Doc.Doc({ replace = table | StoryDoc.rec(StoryDoc.defaults()) }), text)

    @Test
    def testTheLongerKeyIsReplacedFirst(): Unit \ Assert =
        Assert.assertEq(expected = "B", replacing(Map#{ "××" => "A", "××××" => "B" }, "××××"))

    @Test
    def testReplacedTextIsNotReplacedAgain(): Unit \ Assert =
        Assert.assertEq(expected = "bc", replacing(Map#{ "a" => "b", "b" => "c" }, "ab"))

    @Test
    def testReplaceKeepsTheRubyAfterIt(): Unit \ Assert =
        // ×××× を 3 字に替えると、後ろのルビの始まりも 1 字前へずれる（4 字の印 → 3 字）。
        let doc = StoryDoc.Doc.Doc({ replace = Map#{ "××××" => "ユウキ" } | StoryDoc.rec(StoryDoc.defaults()) });
        let line = { speaker = "", text = "××××の字", tags = Nil, source = { file = "t", line = 1 },
                     parts = Yarn.Part.Literal("××××の") :: Yarn.Part.Markup("ruby", "じ") :: Yarn.Part.Literal("字") :: Yarn.Part.Close("ruby") :: Nil };
        let replaced = StoryDoc.replaceLine(doc, line);
        Assert.assertEq(expected = ("ユウキの字", 4 :: Nil), (replaced#text, Yarn.rubiesOf(replaced) |> List.map(r -> r#start)))

    @Test
    def testTheMigrateRecordKeepsTheScriptText(): Unit \ {Assert, Fs.FileRead} =
        // 移行の記録（World.Event.Executed の Said）の字は台本の字のまま（置き換える前）。
        let res = TestKit.res();
        let (head, table) = headTable(res);
        let replaced = withReplace(table, res);
        let started = quiet(() -> WorldRead.newGame(replaced, w0(replaced)));
        let (_, events) = TestKit.stepHearing(replaced, 30.0, started);
        let said = events |> List.filterMap(e -> match e {
            case World.Event.Executed(World.Executed.Said(_, _, text)) => Some(text)
            case _                                                    => None
        });
        Assert.assertTrue(said |> List.exists(String.startsWith(prefix = head)))
}
