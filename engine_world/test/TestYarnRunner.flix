// YarnRunner と Yarn の木の読み手のテスト。シナリオは testdata/yarn/runner/runner.yarn（Go の build が書いた runner.yarn.json を読む）。
// 選択肢の中身を流した後に選択肢の後ろへ戻ること・意味の無い入力で状態が変わらないこと・<<wait>> が時計の時刻まで待つこと・
// 会話が終わると開いているノードが無くなること、木の JSON が壊れていれば既定へ落ちることを見る。

mod TestYarnRunner {

    def program(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), "../../testdata/yarn/runner/runner.yarn.json")

    def linesOf(events: List[YarnRunner.Event]): List[String] = events |> List.flatMap(TestYarnOfficial.planLinesOf)

    def at(seconds: Float64): Clock.Time[Clock.Real] = Clock.after(seconds, Clock.zero())

    // ══════════════════════════════════════════════════════
    // 始める
    // ══════════════════════════════════════════════════════

    /// ノードの頭の台詞で止まり、開いているノードはその名前。次が選択肢なのも分かる。
    @Test
    def testStartStopsAtTheFirstLine(): Unit \ Assert + Fs.FileRead =
        let (runner, events) = YarnRunner.start(program(), "Ask", at(0.0));
        Assert.assertEq(expected = (List#{"line: `girl: どうする？`"}, Some("Ask"), true),
                        (linesOf(events), YarnRunner.nodeOf(runner), YarnRunner.choicesFollow(runner)))

    /// 無いノードを開くと、すぐ終わって閉じる。
    @Test
    def testStartingAnUnknownNodeEndsAtOnce(): Unit \ Assert + Fs.FileRead =
        let (runner, events) = YarnRunner.start(program(), "Nope", at(0.0));
        Assert.assertEq(expected = (List#{"stop"}, false), (linesOf(events), YarnRunner.isOpen(runner)))

    // ══════════════════════════════════════════════════════
    // 選択肢
    // ══════════════════════════════════════════════════════

    /// 選んだ選択肢の中身を流した後、選択肢の後ろの行へ戻ってから終わる。
    @Test
    def testChoosingRunsTheBodyThenReturnsAfterTheOptions(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(
            expected = List#{"line: `girl: どうする？`", "option: `行く` #suspect", "option: `戻る`",
                             "line: `girl: 行こう`", "line: `girl: おわり`", "stop"},
            linesOf(YarnRunner.trace(program(), "Ask", List#{0})))

    /// 選択肢の数より大きい番号を選んでも、出来事は出ず選択肢を出したまま。
    @Test
    def testChoosingOutsideTheOptionsChangesNothing(): Unit \ Assert + Fs.FileRead =
        let (asked, _) = YarnRunner.start(program(), "Ask", at(0.0)) |> fst |> YarnRunner.step(YarnRunner.Action.Advance, at(0.0));
        let (after, events) = YarnRunner.step(YarnRunner.Action.Choose(2), at(0.0), asked);
        let shownChoices = match YarnRunner.shownOf(after) {
            case YarnRunner.Shown.Choices(lines) => List.length(lines)
            case _                               => bug!("選択肢を出したままのはず")
        };
        Assert.assertEq(expected = (0, 2), (List.length(events), shownChoices))

    // ══════════════════════════════════════════════════════
    // wait・stop・jump
    // ══════════════════════════════════════════════════════

    /// <<wait 0.5>> は 0.4 秒の Tick では明けず、0.5 秒の Tick で次の台詞を出す。
    @Test
    def testWaitHoldsUntilItsTime(): Unit \ Assert + Fs.FileRead =
        let (waiting, _) = YarnRunner.start(program(), "Wait", at(0.0));
        let (early, eventsEarly) = YarnRunner.step(YarnRunner.Action.Tick, at(0.4), waiting);
        let (_, eventsOnTime) = YarnRunner.step(YarnRunner.Action.Tick, at(0.5), early);
        Assert.assertEq(expected = (Nil, List#{"line: `girl: 待った`"}), (linesOf(eventsEarly), linesOf(eventsOnTime)))

    /// <<stop>> で終わり、その後ろの行は出ない。
    @Test
    def testStopEndsTheTalk(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = List#{"line: `one`", "stop"}, linesOf(YarnRunner.trace(program(), "Stopper", Nil)))

    /// 台詞の無いノードどうしが jump し合っても止まって終わる。
    @Test
    def testJumpLoopWithoutLinesEnds(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = List#{"stop"}, linesOf(YarnRunner.trace(program(), "Loop", Nil)))

    /// 終わった実行器はどのノードも開いていない。
    @Test
    def testFinishedRunnerHasNoOpenNode(): Unit \ Assert + Fs.FileRead =
        let (talking, _) = YarnRunner.start(program(), "Stopper", at(0.0));
        let (finished, _) = YarnRunner.step(YarnRunner.Action.Advance, at(0.0), talking);
        Assert.assertEq(expected = None, YarnRunner.nodeOf(finished))

    // ══════════════════════════════════════════════════════
    // 木の JSON の橋渡し
    // ══════════════════════════════════════════════════════

    /// 壊れた JSON・版の違う JSON は読まない（loadOr は既定へ落ちる）。
    @Test
    def testBrokenOrOtherVersionJsonIsNotRead(): Unit \ Assert =
        Assert.assertEq(expected = (true, true),
            (Option.isEmpty(Yarn.fromJson("{ broken")), Option.isEmpty(Yarn.fromJson("{\"version\": 2, \"nodes\": []}"))))

    /// ノードの一覧は木の JSON のノードの数に追随する。
    @Test
    def testNodeNamesFollowTheJson(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = List#{"Ask", "Loop", "Loop2", "Stopper", "Wait"}, Yarn.nodeNames(program()))
}
