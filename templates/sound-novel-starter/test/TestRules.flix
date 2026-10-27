// ルールと進行だけをテストする。座標・描き方・文字送りの見た目はテストしない。
// シナリオは本物（natsukusa.yarn を build した木）。行の文字は写さず、ノードの名前・変数・台本の木から期待値を導く。
mod TestRules {

    use fge::{Clock, Emit, Yarn, YarnRunner}
    use TestKit.{advance, begun, pick, placeOf, readTo, settle, quiet, w0}

    def kind(w: World.World): KindDoc.Rec = KindDoc.rec(w#kind)

    /// node の台詞（Say）の .yarn の行番号を上から。
    def sayLines(node: String, w: World.World): List[Int32] =
        Yarn.nodeOf(node, w#dialogue) |> Option.map(found -> found#body |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Say(say) => Some(say#source#line)
            case _                       => None
        })) |> Option.getWithDefault(Nil)

    def lineNo(w: World.World): Int32 =
        World.talkLineOf(w) |> String.splitOn(substr = ":") |> List.last
            |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(-1)

    // ══ 表紙と始まり ══

    @Test
    def testNewGameOpensTheOpeningNodeOnItsFirstLine(): Unit \ {Assert, Fs.FileRead} =
        // はじめから: コードが開くノード（Talk.Node.Opening）の最初の台詞を、台本の頭のコマンドどおりの舞台で出す。
        let w = begun();
        let opening = Talk.nodeName(Talk.Node.Opening);
        Assert.assertEq(expected = (World.Phase.Reading, opening, List.head(sayLines(opening, w)), Stage.Mode.Nvl),
                        (w#phase, World.talkNodeOf(w), Some(lineNo(w)), w#stage#mode))

    @Test
    def testContinueWithoutBookmarksOnlyNotices(): Unit \ {Assert, Fs.FileRead} =
        // 栞が無い時の「つづきから」は空の窓を開かず、知らせだけを出す。
        let start = w0();
        let w = quiet(() -> World.chooseTitle(World.TitleItem.Continue, start));
        Assert.assertEq(expected = (World.Panel.Closed, Some(StoryDoc.labelOf(StoryDoc.Label.NoSave, w#story))),
                        (w#panel, World.toastOf(w)))

    // ══ 読み進める ══

    /// 開いた直後の <<wait>> の秒（無ければ 0）。
    def waitOf(w: World.World): Float64 =
        YarnRunner.waitUntilOf(w#talk) |> Option.map(until -> Clock.since(Clock.nowOf(w#storyClock), until)) |> Option.getWithDefault(0.0)

    @Test
    def testAdvanceWhileTypingRevealsWithoutMoving(): Unit \ {Assert, Fs.FileRead} =
        // 文字送りの途中の決定は全文を出すだけで、行は動かない。
        // 頭の <<wait>> が明けるまで進めてから、1 字も出し切らない短い間だけ送る。
        let start = w0();
        let opened = quiet(() -> World.newGame(start));
        let typing = opened |> TestKit.stepBy(waitOf(opened) - 0.01) |> TestKit.stepBy(0.02);
        let before = placeOf(typing);
        let after = advance(typing);
        Assert.assertEq(expected = (false, true, before), (Page.isDone(typing#page), Page.isDone(after#page), placeOf(after)))

    @Test
    def testAdvanceMovesToTheNextSayAndMarksSeen(): Unit \ {Assert, Fs.FileRead} =
        // 出し終えた行の決定は、同じノードの次の台詞へ送り、送った行を既読にする（saveRev が進む = 書く）。
        let w = begun();
        let next = settle(advance(w));
        let opening = Talk.nodeName(Talk.Node.Opening);
        Assert.assertEq(expected = (List.nth(1, sayLines(opening, w)), true, w#saveRev + 1),
                        (Some(lineNo(next)), Saves.isSeen(World.talkLineOf(w), next#saves), next#saveRev))

    @Test
    def testNvlPageKeepsEarlierLinesUntilClear(): Unit \ {Assert, Fs.FileRead} =
        // NVL は頁に前の行を積んだまま次の行を足す（<<clear>> まではめくらない）。
        let w = begun() |> advance |> settle |> advance |> settle;
        Assert.assertEq(expected = 2, List.length(w#page#lines))

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
        // ADV は下の窓に今の 1 行だけ（頁に積まない）。
        let w = readTo("Paddy", Nil, begun()) |> advance |> settle;
        Assert.assertEq(expected = (Stage.Mode.Adv, 0), (w#stage#mode, List.length(w#page#lines)))

    // ══ 選択肢と変数 ══

    @Test
    def testChoicesBlockAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出している間は決定で先へ進めない（pick だけが進める）。
        let asking = TestKit.readUntil(World.isAsking, Nil, begun());
        let after = settle(advance(asking));
        Assert.assertEq(expected = (true, placeOf(asking)), (World.isAsking(after), placeOf(after)))

    @Test
    def testPickingTheNicknameRaisesCloseness(): Unit \ {Assert, Fs.FileRead} =
        // 田んぼの選択肢: 昔の呼び名（2 つ目）を選ぶと $closeness が 1 上がり、1 つ目では上がらない。
        let asking = TestKit.readUntil(World.isAsking, Nil, begun());
        let closeness = i -> World.variableOf("$closeness", settle(pick(i, asking)));
        Assert.assertEq(expected = ("0", "1"), (closeness(0), closeness(1)))

    @Test
    def testConditionalChoiceCannotBePickedWithoutCloseness(): Unit \ {Assert, Fs.FileRead} =
        // 川の選択肢の 2 つ目は $closeness >= 2 の時だけ選べる。足りなければ選べない印で並び、pick しても動かない。
        let atRiver = readTo("River", 0 :: 0 :: Nil, begun()) |> (w -> TestKit.readUntil(World.isAsking, Nil, w));
        let tried = settle(pick(1, atRiver));
        let available = atRiver#choices |> List.map(option -> option#available);
        Assert.assertEq(expected = (true :: false :: Nil, placeOf(atRiver)), (available, placeOf(tried)))

    @Test
    def testCursorSkipsChoicesThatCannotBePicked(): Unit \ {Assert, Fs.FileRead} =
        // 選べない選択肢にはカーソルが止まらない。
        let atRiver = readTo("River", 0 :: 0 :: Nil, begun()) |> (w -> TestKit.readUntil(World.isAsking, Nil, w));
        let moved = quiet(() -> World.moveChoice(1, atRiver));
        Assert.assertEq(expected = 0, moved#cursor)

    @Test
    def testTrueEndingNeedsBothWarmChoices(): Unit \ {Assert, Fs.FileRead} =
        // 両方の選択で近づくと、川で残る選択ができ、朝に $stayed が立つ。
        let morning = readTo("Morning", 1 :: 1 :: 1 :: Nil, begun());
        Assert.assertEq(expected = ("2", "True"), (World.variableOf("$closeness", morning), World.variableOf("$stayed", morning)))

    @Test
    def testSellingEndingKeepsDistance(): Unit \ {Assert, Fs.FileRead} =
        // 売ると答えて黙って帰ると、$house は sell・$stayed は立たない。
        let morning = readTo("Morning", 0 :: 0 :: 0 :: Nil, begun());
        Assert.assertEq(expected = ("sell", "False"), (World.variableOf("$house", morning), World.variableOf("$stayed", morning)))

    @Test
    def testStoryEndRollsTheCredits(): Unit \ {Assert, Fs.FileRead} =
        // シナリオの終わりまで読むとクレジットへ。
        let done = TestKit.readUntil(w -> w#phase == World.Phase.Credits, 1 :: 1 :: 1 :: Nil, begun());
        Assert.assertEq(expected = World.Phase.Credits, done#phase)

    // ══ 演出 ══

    @Test
    def testEveryCommandInTheScriptIsUnderstood(): Unit \ {Assert, Fs.FileRead} =
        // 台本のコマンドは全部 Stage が読める（写真・時間帯の名前は backdrops にある）。wait は実行器が待つ。
        let w = w0();
        let bad = commandsOf(w#dialogue) |> List.filter(c -> c#name != "wait")
            |> List.filterMap(c -> match Stage.cueOf(w#backdrops, c) {
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
        let start = w0();
        let w = quiet(() -> World.newGame(start));
        let at = s -> Stage.fadeProgress(Clock.after(s, Clock.nowOf(w#storyClock)), w#stage);
        Assert.assertEq(expected = (true, 1.0), (at(w#stage#fadeSeconds * 0.5) < 1.0, at(w#stage#fadeSeconds)))

    // ══ オート・スキップ ══

    /// 今の行を出し終えた時刻を据えた World（時計は at 秒）。
    def doneAt(w: World.World): World.World =
        let now = Clock.nowOf(w#storyClock);
        { doneAt = Some(now) | World.revealLine(w) }

    @Test
    def testAutoAdvancesAfterTheWait(): Unit \ {Assert, Fs.FileRead} =
        // オート: 出し終えてから「待ち + 字数 × autoPerChar」が過ぎると次へ。その前は送らない。
        let w = doneAt({ playback = World.Playback.Auto | begun() });
        let chars = w#page#current |> Option.map(line -> String.length(line#text)) |> Option.getWithDefault(0);
        let wait = w#saves#config#autoWait + Int32.toFloat64(chars) * kind(w)#autoPerChar;
        let early = TestKit.stepBy(wait * 0.5, w);
        let late = TestKit.stepBy(wait + 0.1, w);
        Assert.assertEq(expected = (placeOf(w), true), (placeOf(early), placeOf(late) != placeOf(w)))

    @Test
    def testSkipStopsAtUnreadLines(): Unit \ {Assert, Fs.FileRead} =
        // スキップは読んだ行だけを飛ばす。読んでいない行に来たら切れる。
        let w = TestKit.stepBy(kind(w0())#skipInterval, { playback = World.Playback.Skip | begun() });
        Assert.assertEq(expected = (World.Playback.Manual, true), (w#playback, Option.nonEmpty(w#page#current)))

    @Test
    def testSkipPassesReadLines(): Unit \ {Assert, Fs.FileRead} =
        // 読んだ行（既読）はスキップが送る。
        let first = begun();
        let seen = { saves = Saves.withSeen(World.talkLineOf(first), first#saves) | first };
        let w = TestKit.stepBy(kind(first)#skipInterval + 0.01, doneAt({ playback = World.Playback.Skip | seen }));
        Assert.assertEq(expected = true, placeOf(w) != placeOf(first))

    @Test
    def testPressingStopsAutoAndSkip(): Unit \ {Assert, Fs.FileRead} =
        // 人が決定を押したらオートもスキップも止める（人の速さに戻す）。
        let auto = advance({ playback = World.Playback.Auto | begun() });
        let skip = advance({ playback = World.Playback.Skip | begun() });
        Assert.assertEq(expected = (World.Playback.Manual, World.Playback.Manual), (auto#playback, skip#playback))

    // ══ 窓 ══

    @Test
    def testOpenPanelStopsTheStoryClock(): Unit \ {Assert, Fs.FileRead} =
        // 窓を開いている間は物語の時計が止まる（待ち・文字送り・オートが進まない）。
        let reading = begun();
        let w = quiet(() -> World.openPanel(World.Panel.Log, reading));
        let later = TestKit.stepBy(5.0, w);
        Assert.assertEq(expected = Clock.nowOf(w#storyClock), Clock.nowOf(later#storyClock))

    @Test
    def testLogKeepsNewestFirstAndCapsAtLogMax(): Unit \ {Assert, Fs.FileRead} =
        // ログは新しい順に積み、logMax を超えない。
        let w = begun() |> advance |> settle;
        let capped = { kind = KindDoc.Doc.Doc({ logMax = 1 | kind(w) }) | w } |> advance |> settle;
        Assert.assertEq(expected = (Some(World.talkLineOf(w)), 1),
                        (List.head(w#log) |> Option.map(line -> line#source), List.length(capped#log)))

    // ══ 栞 ══

    @Test
    def testLoadingABookmarkRestoresPlaceAndStage(): Unit \ {Assert, Fs.FileRead} =
        // 栞から読むと、挟んだ所のノードと行に戻り、舞台（写真・文章の出し方・環境音）も挟んだ時の形になる。
        let atPaddy = readTo("Paddy", Nil, begun()) |> advance |> settle |> advance |> settle;
        let saved = quiet(() -> World.saveSlot(0, atPaddy));
        let elsewhere = readTo("Lane", 1 :: Nil, saved);
        let loaded = settle(quiet(() -> World.loadSlot(0, elsewhere)));
        let stageOf = (w: World.World) -> (w#stage#shot |> Option.map(shot -> (shot#photo, shot#grade)), w#stage#mode, w#stage#ambience);
        Assert.assertEq(expected = (placeOf(atPaddy), stageOf(atPaddy)), (placeOf(loaded), stageOf(loaded)))

    @Test
    def testLoadingRestoresVariables(): Unit \ {Assert, Fs.FileRead} =
        // 栞は変数も戻す（選んだ後に挟んだ栞では $closeness が残る）。
        let chose = readTo("Lane", 1 :: Nil, begun());
        let saved = quiet(() -> World.saveSlot(2, chose));
        let loaded = settle(quiet(() -> World.loadSlot(2, quiet(() -> World.newGame(saved)))));
        Assert.assertEq(expected = "1", World.variableOf("$closeness", loaded))

    @Test
    def testSavesSurviveJson(): Unit \ {Assert, Fs.FileRead} =
        // 栞・既読・設定は JSON を通しても同じ。
        let chose = readTo("Lane", 1 :: Nil, begun());
        let saves = quiet(() -> World.saveSlot(3, chose))#saves;
        let back = Saves.fromJson(Saves.fresh(chose#kind), Saves.toJson(saves));
        Assert.assertEq(expected = (Map.keysOf(saves#slots), saves#seen, saves#config#cps),
                        (Map.keysOf(back#slots), back#seen, back#config#cps))

    // ══ 設定 ══

    @Test
    def testSettingsStayInRange(): Unit \ {Assert, Fs.FileRead} =
        // 設定の値は範囲の端で止まる。
        let w = w0();
        let pushed = (setting, delta) -> List.range(0, 100) |> List.foldLeft((acc, _) -> quiet(() -> World.adjust(setting, delta, acc)), w);
        let ends = World.settings() |> List.map(setting -> {
            let (lo, hi, _) = World.rangeOf(setting);
            (World.valueOf(setting, pushed(setting, -1)) == lo, World.valueOf(setting, pushed(setting, 1)) == hi)
        });
        Assert.assertEq(expected = List.map(_ -> (true, true), World.settings()), ends)

    @Test
    def testVolumeSettingsReachTheMixer(): Unit \ {Assert, Fs.FileRead} =
        // 環境音の音量を変えると、ミキサーの環境音のバスに届く（返事の音とは別のつまみ）。
        let start = w0();
        let w = quiet(() -> World.withSetting(World.Setting.AmbienceVolume, 0.0, start));
        Assert.assertEq(expected = (0.0, 0.0), (World.valueOf(World.Setting.AmbienceVolume, w), w#saves#config#ambienceVolume))

    // ══ 返事の音 ══

    @Test
    def testScriptSoundEffectsAreHeard(): Unit \ {Assert, Fs.FileRead} =
        // 台本の <<se>> は se_<名前> の出来事になり、Controls が同じ名前の音を鳴らす。
        let atLane = readTo("Lane", 1 :: Nil, begun());
        let (_, heard) = TestKit.readHearing(w -> World.talkNodeOf(w) == "Engawa", Nil, atLane);
        Assert.assertEq(expected = (true, Some("se_slap")),
                        (List.memberOf(World.Event.Cue("se_slap"), heard), Controls.soundOf(World.Event.Cue("se_slap"))))

    @Test
    def testLoadingABookmarkIsSilent(): Unit \ {Assert, Fs.FileRead} =
        // 栞から読み直す時、通り過ぎた <<se>> は鳴らさない（返事は Loaded の 1 つだけ）。
        let past = readTo("Engawa", 1 :: Nil, begun());
        let saved = quiet(() -> World.saveSlot(0, past));
        let (_, heard) = Emit.collect(() -> World.loadSlot(0, saved));
        Assert.assertEq(expected = World.Event.Loaded :: Nil, heard)
}
