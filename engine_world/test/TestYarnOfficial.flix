// 公式の Yarn Spinner の testplan との突き合わせ。testdata/yarn/subset/ は公式の TestCases から部分集合に収まる所を
// 抜き出した .yarn と .testplan（並びと字は公式のまま）で、Go の bin/fge yarn build が書いた木を YarnRunner.trace で流し、
// 出来事の列が testplan の行（line・option・command・stop）と同じになるかを見る。select の番号は testplan から取る。

mod TestYarnOfficial {

    def dir(): String = "../../testdata/yarn/subset/"

    /// testplan の期待の行（select と空行を除く）・select の番号（0 始まり）・流した出来事を行にした物。
    def caseOf(name: String): (List[String], List[String]) \ Fs.FileRead =
        let plan = Fs.FileRead.readLines(dir() + name + ".testplan") |> Result.getWithDefault(Nil) |> List.map(String.trim);
        let picks = plan |> List.filterMap(line ->
            if (String.startsWith(prefix = "select:", line)) Int32.fromString(String.trim(String.dropLeft(7, line))) |> Option.map(n -> n - 1)
            else None);
        let expected = plan |> List.filter(line -> line != "" and not String.startsWith(prefix = "select:", line));
        let program = Yarn.loadOr(Yarn.empty(), dir() + name + ".yarn.json");
        (expected, YarnRunner.trace(program, "Start", picks) |> List.flatMap(planLinesOf))

    /// 出来事を testplan の行の形にする（話し手のある行は「話し手: 字」・タグは後ろに #key か #key:value）。TestYarnRunner も使う。
    pub def planLinesOf(event: YarnRunner.Event): List[String] = match event {
        case YarnRunner.Event.Line(line)    => "line: `${textOf(line)}`${tagsOf(line#tags)}" :: Nil
        case YarnRunner.Event.Choices(lines) => lines |> List.map(line -> "option: `${textOf(line)}`${tagsOf(line#tags)}")
        case YarnRunner.Event.Command(command) => "command: `${String.intercalate(" ", command#name :: command#args)}`" :: Nil
        case YarnRunner.Event.Done          => "stop" :: Nil
    }

    def textOf(line: Yarn.Line): String = if (line#speaker == "") line#text else "${line#speaker}: ${line#text}"

    def tagsOf(tags: List[Yarn.Tag]): String =
        tags |> List.map(tag -> if (tag#value == "") " #${tag#key}" else " #${tag#key}:${tag#value}") |> String.intercalate("")

    // ══════════════════════════════════════════════════════
    // 公式の testplan
    // ══════════════════════════════════════════════════════

    /// 地の文・話し手のある行・行の後ろのコメントとタグ（Lines.yarn から <<if>> の行を除いた物）。
    @Test
    def testLinesMatchTheOfficialPlan(): Unit \ Assert + Fs.FileRead =
        let (expected, actual) = caseOf("Lines");
        Assert.assertEq(expected = expected, actual)

    /// 引数・記号のあるコマンドが待たずに順に流れる（Commands.yarn から {式} と変数を除いた物）。
    @Test
    def testCommandsMatchTheOfficialPlan(): Unit \ Assert + Fs.FileRead =
        let (expected, actual) = caseOf("Commands");
        Assert.assertEq(expected = expected, actual)

    /// 選択肢・字下げした選択肢・選んだ中身を流した後に選択肢の後ろへ戻る（ShortcutOptions.yarn から条件と変数を除いた物）。
    @Test
    def testShortcutOptionsMatchTheOfficialPlan(): Unit \ Assert + Fs.FileRead =
        let (expected, actual) = caseOf("ShortcutOptions");
        Assert.assertEq(expected = expected, actual)

    /// <<jump>> の後ろの行は流れない（Jumps.yarn の名前で跳ぶ所）。
    @Test
    def testJumpsMatchTheOfficialPlan(): Unit \ Assert + Fs.FileRead =
        let (expected, actual) = caseOf("Jumps");
        Assert.assertEq(expected = expected, actual)

    /// \ のエスケープ・// のコメント・\: で話し手にしない行（Escaping.yarn から {式} とマークアップを除いた物）。
    @Test
    def testEscapingMatchesTheOfficialPlan(): Unit \ Assert + Fs.FileRead =
        let (expected, actual) = caseOf("Escaping");
        Assert.assertEq(expected = expected, actual)

    /// 選択肢の外の字下げは意味を持たず、空行で選択肢のまとまりが分かれる（Indentation.yarn の選択肢の所）。
    @Test
    def testIndentationMatchesTheOfficialPlan(): Unit \ Assert + Fs.FileRead =
        let (expected, actual) = caseOf("Indentation");
        Assert.assertEq(expected = expected, actual)
}
