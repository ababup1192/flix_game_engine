// YarnRunner の変数・<<if>>・{式}・visited のテスト。シナリオは testdata/yarn/runner/vars.yarn（Go の build が書いた vars.yarn.json を読む）。
// どう選んでも変数が式どおりになること・条件が偽の選択肢は出ないこと・会話をまたいで値と訪れた数を持ち越せること・
// セーブの JSON を行き来しても同じ値に戻ることを見る。

mod TestYarnVariables {

    def program(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), "../../testdata/yarn/runner/vars.yarn.json")

    def linesOf(events: List[YarnRunner.Event]): List[String] = events |> List.flatMap(TestYarnOfficial.planLinesOf)

    def at(seconds: Float64): Clock.Time[Clock.Real] = Clock.after(seconds, Clock.zero())

    /// picks の順に選びきった実行器（台詞は送る）。
    def runToEnd(storage: YarnStorage.Storage, node: String, picks: List[Int32]): YarnRunner.Runner[Clock.Real] \ Fs.FileRead =
        let (runner, _) = YarnRunner.startWith(storage, program(), node, at(0.0));
        drive(100, runner, picks)

    def drive(budget: Int32, runner: YarnRunner.Runner[Clock.Real], picks: List[Int32]): YarnRunner.Runner[Clock.Real] =
        if (budget <= 0) runner
        else match (YarnRunner.shownOf(runner), picks) {
            case (YarnRunner.Shown.Line(_), _)              => drive(budget - 1, fst(YarnRunner.step(YarnRunner.Action.Advance, at(0.0), runner)), picks)
            case (YarnRunner.Shown.Choices(_), pick :: rest) => drive(budget - 1, fst(YarnRunner.step(YarnRunner.Action.Choose(pick), at(0.0), runner)), rest)
            case _                                          => runner
        }

    /// 0 と 1 の 3 つの並び 8 通り。
    def allPicks(): List[List[Int32]] =
        List#{0, 1} |> List.flatMap(a -> List#{0, 1} |> List.flatMap(b -> List#{0, 1} |> List.map(c -> List#{a, b, c})))

    /// 規則をそのまま数えた期待値: 切符が残っていて 0 番（一緒に降りる）を選んだ駅だけ、切符が減り連れが増える。
    /// 切符が無い駅は「一緒に」が出ないので、0 番は「ひとりで」になる。返すのは（切符・連れ・各駅で出た選択肢の数）。
    def expectedTrip(picks: List[Int32]): (Int32, Int32, List[Int32]) =
        let step = (acc, pick) -> {
            let (tickets, companions, shown) = acc;
            let offered = if (tickets > 0) 2 else 1;
            if (tickets > 0 and pick == 0) (tickets - 1, companions + 1, offered :: shown)
            else (tickets, companions, offered :: shown)
        };
        let (tickets, companions, shown) = List.foldLeft(step, (2, 0, Nil), picks);
        (tickets, companions, List.reverse(shown))

    def number(n: Int32): Option[Yarn.Value] = Some(Yarn.Value.Number(Int32.toFloat64(n)))

    // ══════════════════════════════════════════════════════
    // どう選んでも
    // ══════════════════════════════════════════════════════

    /// 8 通りのどの選び方でも、終わった時の切符と連れの数は規則で数えた値と同じ。
    @Test
    def testEveryPathEndsWithTheCountedValues(): Unit \ Assert + Fs.FileRead =
        let actual = allPicks() |> List.map(picks -> {
            let runner = runToEnd(YarnStorage.empty(), "Trip", picks);
            (YarnRunner.valueOf("$tickets", runner), YarnRunner.valueOf("$companions", runner))
        });
        let expected = allPicks() |> List.map(picks -> { let (t, c, _) = expectedTrip(picks); (number(t), number(c)) });
        Assert.assertEq(expected = expected, actual)

    /// どの選び方でも、切符の無い駅では条件の偽の「一緒に降りる」が出ない（出た選択肢の数が規則どおり）。
    @Test
    def testFalseOptionsAreNeverShown(): Unit \ Assert + Fs.FileRead =
        let shownCounts = picks -> YarnRunner.trace(program(), "Trip", picks) |> List.filterMap(event -> match event {
            case YarnRunner.Event.Choices(lines) => Some(List.length(lines))
            case _                               => None
        });
        let expected = allPicks() |> List.map(picks -> { let (_, _, shown) = expectedTrip(picks); shown });
        Assert.assertEq(expected = expected, allPicks() |> List.map(shownCounts))

    /// {式} は値を字にして台詞へ差し込む（ノードの中にいる間は、そのノードを出た回数はまだ足されていない）。
    @Test
    def testInlineExpressionsShowTheValues(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = List#{"line: `girl: 切符は残り 0 枚・連れは 2 人・2 回目の後`", "stop"},
            YarnRunner.trace(program(), "Trip", List#{0, 0, 0}) |> linesOf |> List.filter(line -> not String.startsWith(prefix = "option", line)))

    // ══════════════════════════════════════════════════════
    // 条件
    // ══════════════════════════════════════════════════════

    /// <<if>> は最初に真になった枝だけを流す（選んだ選択肢が立てた旗で分かれる）。
    @Test
    def testIfRunsTheFirstTrueBranch(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = (List#{"line: `girl: また会えたね`", "stop"}, List#{"line: `girl: 切符はそのまま`", "stop"}),
            (YarnRunner.trace(program(), "Meet", List#{0}) |> linesOf |> List.drop(2),
             YarnRunner.trace(program(), "Meet", List#{1}) |> linesOf |> List.drop(2)))

    /// 選択肢の字の {式} も値になる。
    @Test
    def testOptionTextShowsValues(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = List#{"option: `ミナ と話す`", "option: `黙る`"},
            YarnRunner.trace(program(), "Meet", Nil) |> linesOf)

    /// 条件が全部偽の選択肢のまとまりは、出さずに後ろへ進む。
    @Test
    def testAllFalseOptionsAreSkipped(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = List#{"line: `girl: 飛ばした`", "stop"}, YarnRunner.trace(program(), "Hidden", Nil) |> linesOf)

    /// 台詞の後ろに <<set>> と <<if>> を挟んでも、次に出るのが選択肢なら choicesFollow は真。
    @Test
    def testChoicesFollowLooksPastSetAndIf(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = true, YarnRunner.choicesFollow(fst(YarnRunner.start(program(), "Question", at(0.0)))))

    // ══════════════════════════════════════════════════════
    // 持ち越す・ゲームから読み書きする・セーブ
    // ══════════════════════════════════════════════════════

    /// 終わった会話の storageOf を startWith へ渡すと、visited が前の会話を覚えている。
    @Test
    def testVisitedCarriesOverBetweenTalks(): Unit \ Assert + Fs.FileRead =
        let first = runToEnd(YarnStorage.empty(), "Again", Nil);
        let (_, second) = YarnRunner.startWith(YarnRunner.storageOf(first), program(), "Again", at(0.0));
        Assert.assertEq(expected = List#{"line: `girl: 二度目`"}, linesOf(second))

    /// ゲームが切符を 0 枚と書いて始めると、どの駅でも「一緒に降りる」は出ない。
    @Test
    def testGameWrittenValueDrivesConditions(): Unit \ Assert + Fs.FileRead =
        let storage = YarnStorage.empty() |> YarnStorage.set("$tickets", Yarn.Value.Number(0.0));
        let runner = runToEnd(storage, "Trip", List#{0, 0, 0});
        Assert.assertEq(expected = (number(0), number(0)), (YarnRunner.valueOf("$tickets", runner), YarnRunner.valueOf("$companions", runner)))

    /// 宣言と型の違う値をゲームが書いても、式は初めの値で読む。
    @Test
    def testWrongTypedValueReadsAsTheDeclaredDefault(): Unit \ Assert + Fs.FileRead =
        let storage = YarnStorage.empty() |> YarnStorage.set("$tickets", Yarn.Value.Text("たくさん"));
        let (runner, _) = YarnRunner.startWith(storage, program(), "Hidden", at(0.0));
        Assert.assertEq(expected = number(2), YarnRunner.valueOf("$tickets", runner))

    /// セーブの JSON へ書いて読み戻すと、変数の値と訪れた数が同じに戻る。
    @Test
    def testStorageRoundTripsThroughJson(): Unit \ Assert + Fs.FileRead =
        let storage = YarnRunner.storageOf(runToEnd(YarnStorage.empty(), "Meet", List#{0}));
        let back = storage |> YarnStorage.toJson |> Util.Json.toPrettyString(2) |> DocJson.parse |> Option.flatMap(YarnStorage.fromJson);
        let view = s -> (YarnStorage.valuesOf(s), YarnStorage.visitCountOf("Meet", s));
        Assert.assertEq(expected = Some(view(storage)), Option.map(view, back))

    /// 書いた値は宣言の順でなく名前の順に並び、ノードを出た回数は 1。
    @Test
    def testStorageAfterOneTalk(): Unit \ Assert + Fs.FileRead =
        let storage = YarnRunner.storageOf(runToEnd(YarnStorage.empty(), "Meet", List#{0}));
        Assert.assertEq(expected = (List#{("$met", Yarn.Value.Bool(true))}, 1),
            (YarnStorage.valuesOf(storage), YarnStorage.visitCountOf("Meet", storage)))
}
