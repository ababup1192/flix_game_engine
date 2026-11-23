// TestFlowSaveLoad — flow の saveload（セーブ → 読み直し）と、読み直さない流れとの比べ（Flow.SaveLoad）を固定する。
// ゲーム: Z で数が 1 増える。X は 1 回目だけ数を 10 増やしてフラグ seen を立てる（チュートリアルを 1 回だけ出すのと同じ形）。
// spin は毎フレーム増える一時的な値、taps は Z を押した回数（返事の通し番号）で、どちらもセーブに書かない。セーブは {"n": 数, "seen": 真偽}。
// kept = 読んだセーブにあった seen（遊びには使わず書く時に重ねて戻す。知らないキーを残して書き戻すゲームの形）。
mod TestFlowSaveLoad {
    use GameEngine.Key
    use Util.Json.Json

    type alias Game = { n = Int32, seen = Bool, kept = Bool, spin = Int32, taps = Int64 }

    def start(): Game = { n = 0, seen = false, kept = false, spin = 0, taps = 0i64 }

    def step(frame: App.Frame, w: Game): Game =
        let pressed = App.justPressed(Key.Z, frame);
        let counted = if (pressed) { n = w#n + 1, taps = w#taps + 1i64 | w } else w;
        let marked = if (App.justPressed(Key.X, frame) and not counted#seen) { n = counted#n + 10, seen = true | counted } else counted;
        { spin = marked#spin + 1 | marked }

    type alias Load = (String, Game) -> Result[String, Game]

    type alias Setup = { probes = List[String], unsaved = List[String], replies = Bool, save = Game -> Option[String], load = Load }

    def setupOf(load: Load): Setup = { probes = "n" :: Nil, unsaved = Nil, replies = false, save = saveText, load = load }

    def probeRow(name: String): Flow.ProbeRow[Game] = match name {
        case "seen" => { name = "seen", doc = "フラグ", read = Flow.Probe.Flag(w -> w#seen) }
        case "spin" => { name = "spin", doc = "一時的な値", read = Flow.Probe.Num(w -> Int32.toFloat64(w#spin)) }
        case _      => { name = "n", doc = "数", read = Flow.Probe.Num(w -> Int32.toFloat64(w#n)) }
    }

    def table(s: Setup, withTrip: Bool): Flow.Table[Game] =
        { roles = _ -> (Key.Z, "count") :: (Key.X, "mark") :: Nil,
          probes = s#probes |> List.map(probeRow),
          replies = if (s#replies) Some(w -> w#taps) else None,
          saveRoundTrip = if (withTrip) Some({ save = s#save, load = s#load, unsaved = s#unsaved }) else None | Flow.emptyTable() }

    def saveText(w: Game): Option[String] =
        Some("{\"n\": ${Int32.toString(w#n)}, \"seen\": ${if (w#seen or w#kept) "true" else "false"}}")

    def fieldsOf(text: String): Result[String, Map[String, Json]] =
        DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("JSON の object でない")

    /// 正しく読む。spin と taps は読み直すと 0 から（セーブに出ない値）。
    def loadFaithful(text: String, _fresh: Game): Result[String, Game] =
        fieldsOf(text) |> Result.map(o -> { n = JsonCodec.intOr("n", 0, o), seen = JsonCodec.boolOr("seen", false, o) | start() })

    /// フラグ seen を遊びに読み落とす（書いたキーを知らない物と見なす不具合）。字は kept に残すので、読み直してすぐ書いたセーブは元と同じ。
    def loadForgetsSeen(text: String, _fresh: Game): Result[String, Game] =
        fieldsOf(text) |> Result.map(o -> { n = JsonCodec.intOr("n", 0, o), kept = JsonCodec.boolOr("seen", false, o) | start() })

    /// 数を 1 つ多く読む（読み直してすぐ書いた字が元と違う）。
    def loadOffByOne(text: String, _fresh: Game): Result[String, Game] =
        fieldsOf(text) |> Result.map(o -> { n = JsonCodec.intOr("n", 0, o) + 1, seen = JsonCodec.boolOr("seen", false, o) | start() })

    /// 字を読まず、渡された World をそのまま返す（今の World を渡すとすり抜ける形）。
    def loadIgnoresText(_text: String, given: Game): Result[String, Game] = Ok(given)

    def appOf(s: Setup): App.App[Game, {}] =
        App.make(start()) |> App.addSystem(step) |> App.withFlow(table(s, true))

    def outcomes(s: Setup, text: String): Result[List[String], { plain = Result[Flow.Failure[Game], Flow.Outcome[Game]], reloaded = Result[Flow.Failure[Game], Flow.Outcome[Game]] }] \ Fs.FileRead =
        let app = appOf(s);
        match Flow.Parse.parseText(Flow.vocabOf(app, start()), "body", text) {
            case Err(problems) => Err(Flow.Parse.problemsText(problems) :: Nil)
            case Ok(script)    => Ok(Flow.SaveLoad.playBoth(app, { design = Vec2.zero(), limit = 1000 }, script, { world = start(), state = App.freshStepState() }))
        }

    /// 本文を両方の流れで流して比べた結果（Ok = 知らせ・Err = 出す行の列）。
    def judged(s: Setup, text: String): Result[List[String], String] \ Fs.FileRead =
        match outcomes(s, text) {
            case Err(lines) => Err(lines)
            case Ok(both)   => Flow.SaveLoad.compareRuns(appOf(s), "body", both#plain, both#reloaded)
        }

    /// FAIL で始まる行だけ。
    def failLines(r: Result[List[String], String]): List[String] = match r {
        case Err(lines) => lines |> List.filter(String.startsWith(prefix = "FAIL"))
        case Ok(_)      => Nil
    }

    def anyContains(part: String, lines: List[String]): Bool = lines |> List.exists(String.contains(substr = part))

    def markTwice(): String = "fps 60\ntap mark\nwait 2f\nsaveload\ntap count\nwait 2f\ntap mark\nwait 2f\n"

    def markOnce(): String = "fps 60\ntap mark\nwait 2f\nsaveload\ntap count\nwait 2f\n"

    def probeSplit(): String = "FAIL body: saveload で読み直した流れと読み直さない流れで、問いの値が分かれた（App.withFlow の probes）"

    def saveSplit(): String = "FAIL body: saveload で読み直した流れと読み直さない流れで、最後のセーブが違う"

    @Test
    def testFaithfulLoadPassesEvenThoughTheSpinRestarts(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isOk(judged({ probes = "n" :: "seen" :: Nil | setupOf(loadFaithful) }, markTwice())))

    @Test
    def testForgottenMarkUsedAgainSplitsTheProbes(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(List.memberOf(probeSplit(), failLines(judged(setupOf(loadForgetsSeen), markTwice()))))

    @Test
    def testForgottenMarkUsedAgainMakesTheLastSaveDiffer(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(List.memberOf(saveSplit(), failLines(judged(setupOf(loadForgetsSeen), markTwice()))))

    @Test
    def testForgottenMarkNeverUsedAgainIsCaughtByItsProbe(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = probeSplit() :: Nil, failLines(judged({ probes = "n" :: "seen" :: Nil | setupOf(loadForgetsSeen) }, markOnce())))

    @Test
    def testForgottenMarkNeverUsedAgainWithoutAProbePasses(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isOk(judged(setupOf(loadForgetsSeen), markOnce())))

    @Test
    def testLoadThatChangesTheSaveStopsAtTheSaveLoadLine(): Unit \ {Assert, Fs.FileRead} =
        let head = "FAIL body:4: saveload で読み直した流れが止まった";
        Assert.assertEq(expected = Some(head),
                        failLines(judged(setupOf(loadOffByOne), markTwice())) |> List.head |> Option.map(String.takeLeft(String.length(head))))

    @Test
    def testLoadGetsTheFreshWorldNotTheRunningOne(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(anyContains("読み直してすぐ書いたセーブが元と違う", failLines(judged(setupOf(loadIgnoresText), markOnce()))))

    @Test
    def testSaveNoneStopsWithItsReason(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(anyContains("この場面ではセーブを書かない", failLines(judged({ save = _ -> None | setupOf(loadFaithful) }, markOnce()))))

    @Test
    def testLoadErrStopsWithItsReason(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(anyContains("読めない（壊れた）", failLines(judged(setupOf((_, _) -> Err("壊れた")), markOnce()))))

    @Test
    def testHeldKeyAtSaveLoadStopsBothRuns(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(anyContains("押しっぱなしの物がある", failLines(judged(setupOf(loadFaithful), "fps 60\nhold count\nsaveload\nrelease count\n"))))

    @Test
    def testRepliesAfterSaveLoadAreJudgedFromTheLoadedWorld(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isOk(judged({ replies = true | setupOf(loadFaithful) }, "fps 60\ntap count\nsaveload\ntap count\nwait 2f\ntap count\nwait 2f\n")))

    @Test
    def testFrameCountsMatchWithReplies(): Unit \ {Assert, Fs.FileRead} =
        let counts = match outcomes({ replies = true | setupOf(loadFaithful) }, "fps 60\ntap count\nsaveload\ntap count\nwait 2f\n") {
            case Ok(both) => (both#plain |> Result.map(o -> List.length(o#frames)) |> Result.toOption,
                              both#reloaded |> Result.map(o -> List.length(o#frames)) |> Result.toOption)
            case Err(_)   => (None, Some(-1))
        };
        Assert.assertEq(expected = fst(counts), snd(counts))

    @Test
    def testUnsavedProbeIsNotCompared(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isOk(judged({ probes = "n" :: "spin" :: Nil, unsaved = "spin" :: Nil | setupOf(loadFaithful) }, markOnce())))

    @Test
    def testProbeOfAnUnsavedValueSplitsWhenNotListed(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(List.memberOf(probeSplit(), failLines(judged({ probes = "n" :: "spin" :: Nil | setupOf(loadFaithful) }, markOnce()))))

    @Test
    def testFingerprintIsNotCompared(): Unit \ {Assert, Fs.FileRead} =
        let s = setupOf(loadFaithful);
        let app = appOf(s) |> App.withFingerprint(w -> Int32.toString(w#spin));
        let result = match Flow.Parse.parseText(Flow.vocabOf(app, start()), "body", markOnce()) {
            case Err(_)     => Err(Nil)
            case Ok(script) =>
                let both = Flow.SaveLoad.playBoth(app, { design = Vec2.zero(), limit = 1000 }, script, { world = start(), state = App.freshStepState() });
                Flow.SaveLoad.compareRuns(app, "body", both#plain, both#reloaded)
        };
        Assert.assertTrue(Result.isOk(result))

    @Test
    def testSaveLoadInARunFlowReloads(): Unit \ {Assert, Fs.FileRead} =
        let files = Map#{ "e2e/main.flow" => "fps 60\ntap mark\nwait 2f\nrun part.flow\ntap mark\nwait 2f\n",
                          "e2e/part.flow" => "fps 60\nsaveload\ntap count\nwait 2f\n" };
        let app = appOf(setupOf(loadForgetsSeen));
        let read = (path: String) -> Map.get(path, files) |> Option.toOk("${path} が無い");
        let result = match Flow.Parse.parseFile(Flow.vocabOf(app, start()), "e2e/main.flow", read) {
            case Err(problems) => Err(Flow.Parse.problemsText(problems) :: Nil)
            case Ok(script)    =>
                let both = Flow.SaveLoad.playBoth(app, { design = Vec2.zero(), limit = 1000 }, script, { world = start(), state = App.freshStepState() });
                Flow.SaveLoad.compareRuns(app, "body", both#plain, both#reloaded)
        };
        Assert.assertTrue(List.memberOf(saveSplit(), failLines(result)))

    @Test
    def testCompareLastSaysWhichRunStoppedWriting(): Unit \ Assert =
        let trip = Some({ save = (w: Game) -> if (w#n > 0) saveText(w) else None, load = loadFaithful, unsaved = Nil });
        Assert.assertEq(expected = Err("読み直した流れの最後はセーブを書かない場面（読み直さない流れは書く）"),
                        Flow.SaveLoad.compareLast(trip, { n = 1 | start() }, start()))

    @Test
    def testReportSaveLoadExitsOneOnASplit(): Unit \ {Assert, Fs.FileRead, IO} =
        let s = setupOf(loadForgetsSeen);
        let code = match (outcomes(s, markTwice()), Flow.Parse.parseText(Flow.vocabOf(appOf(s), start()), "body", markTwice())) {
            case (Ok(both), Ok(script)) => Flow.Cli.reportSaveLoad(appOf(s), "body", script, both#plain, both#reloaded)
            case _                      => -1
        };
        Assert.assertEq(expected = 1, code)

    @Test
    def testReportSaveLoadExitsZeroWhenSame(): Unit \ {Assert, Fs.FileRead, IO} =
        let s = setupOf(loadFaithful);
        let code = match (outcomes(s, markTwice()), Flow.Parse.parseText(Flow.vocabOf(appOf(s), start()), "body", markTwice())) {
            case (Ok(both), Ok(script)) => Flow.Cli.reportSaveLoad(appOf(s), "body", script, both#plain, both#reloaded)
            case _                      => -1
        };
        Assert.assertEq(expected = 0, code)

    @Test
    def testSaveLoadWithoutRoundTripIsAParseError(): Unit \ Assert =
        let app = App.make(start()) |> App.addSystem(step) |> App.withFlow(table(setupOf(loadFaithful), false));
        Assert.assertTrue(Result.isErr(Flow.Parse.parseText(Flow.vocabOf(app, start()), "body", "saveload\n")))

    @Test
    def testPlainPlayDoesNotReload(): Unit \ {Assert, Fs.FileRead} =
        let app = appOf(setupOf(loadForgetsSeen));
        let n = match Flow.Parse.parseText(Flow.vocabOf(app, start()), "body", markTwice()) {
            case Err(_)     => -1
            case Ok(script) => Flow.play(app, { design = Vec2.zero(), limit = 1000 }, script, { world = start(), state = App.freshStepState() })
                |> Result.map(o -> o#last#n) |> Result.getWithDefault(-1)
        };
        Assert.assertEq(expected = 11, n)

    @Test
    def testDiffNamesTheChangedKey(): Unit \ Assert =
        Assert.assertEq(expected = "seen: true → false", Flow.SaveLoad.diffText("{\"n\": 1, \"seen\": true}", "{\"n\": 1, \"seen\": false}"))
}
