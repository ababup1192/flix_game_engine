// TestFlowSaveLoad — flow の saveload（セーブ → 読み直し）と、読み直さない流れとの比べ（Flow.SaveLoad）を固定する。
// ゲーム: Z で数が 1 増える。X は 1 回目だけ数を 10 増やしてフラグ seen を立てる（チュートリアルを 1 回だけ出すのと同じ形）。
// spin は毎フレーム増える一時的な値でセーブに書かない。セーブは {"n": 数, "seen": 真偽}。
// kept = 読んだセーブにあった seen（遊びには使わず書く時に重ねて戻す。知らないキーを残して書き戻すゲームの形）。
mod TestFlowSaveLoad {
    use GameEngine.Key
    use Util.Json.Json

    type alias Game = { n = Int32, seen = Bool, kept = Bool, spin = Int32 }

    def start(): Game = { n = 0, seen = false, kept = false, spin = 0 }

    def step(frame: App.Frame, w: Game): Game =
        let counted = if (App.justPressed(Key.Z, frame)) { n = w#n + 1 | w } else w;
        let marked = if (App.justPressed(Key.X, frame) and not counted#seen) { n = counted#n + 10, seen = true | counted } else counted;
        { spin = marked#spin + 1 | marked }

    /// seenProbe = フラグ seen も問いに出すか（出さなければ問いは数だけ）。
    def table(seenProbe: Bool, trip: Option[Flow.SaveRoundTrip[Game]]): Flow.Table[Game] =
        let n = { name = "n", doc = "数", read = Flow.Probe.Num(w -> Int32.toFloat64(w#n)) };
        let seen = { name = "seen", doc = "フラグ", read = Flow.Probe.Flag(w -> w#seen) };
        { roles = _ -> (Key.Z, "count") :: (Key.X, "mark") :: Nil,
          probes = if (seenProbe) n :: seen :: Nil else n :: Nil, saveRoundTrip = trip | Flow.emptyTable() }

    def saveText(w: Game): Option[String] =
        Some("{\"n\": ${Int32.toString(w#n)}, \"seen\": ${if (w#seen or w#kept) "true" else "false"}}")

    def fieldsOf(text: String): Result[String, Map[String, Json]] =
        DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("JSON の object でない")

    /// 正しく読む。spin は読み直すと 0 から（セーブに出ない一時的な値）。
    def loadFaithful(text: String, _w: Game): Result[String, Game] =
        fieldsOf(text) |> Result.map(o -> { n = JsonCodec.intOr("n", 0, o), seen = JsonCodec.boolOr("seen", false, o), kept = false, spin = 0 })

    /// フラグ seen を遊びに読み落とす（書いたキーを知らない物と見なす不具合）。字は kept に残すので、読み直してすぐ書いたセーブは元と同じ。
    def loadForgetsSeen(text: String, _w: Game): Result[String, Game] =
        fieldsOf(text) |> Result.map(o -> { n = JsonCodec.intOr("n", 0, o), seen = false, kept = JsonCodec.boolOr("seen", false, o), spin = 0 })

    /// 数を 1 つ多く読む（読み直してすぐ書いた字が元と違う）。
    def loadOffByOne(text: String, _w: Game): Result[String, Game] =
        fieldsOf(text) |> Result.map(o -> { n = JsonCodec.intOr("n", 0, o) + 1, seen = JsonCodec.boolOr("seen", false, o), kept = false, spin = 0 })

    def appWith(seenProbe: Bool, load: (String, Game) -> Result[String, Game]): App.App[Game, {}] =
        App.make(start()) |> App.addSystem(step) |> App.withFlow(table(seenProbe, Some({ save = saveText, load = load })))

    /// 本文を両方の流れで流した判定（Ok = 知らせ・Err = 出す行の列）。
    def judged(seenProbe: Bool, load: (String, Game) -> Result[String, Game], text: String): Result[List[String], String] \ Fs.FileRead =
        let app = appWith(seenProbe, load);
        match Flow.Parse.parseText(Flow.vocabOf(app, start()), "body", text) {
            case Err(problems) => Err(Flow.Parse.problemsText(problems) :: Nil)
            case Ok(script) =>
                let both = Flow.SaveLoad.playBoth(app, { design = Vec2.zero(), limit = 1000 }, script,
                                                  { world = start(), state = App.freshStepState() });
                Flow.SaveLoad.judge(app, "body", both#plain, both#reloaded)
        }

    /// FAIL で始まる行だけ。
    def failLines(r: Result[List[String], String]): List[String] = match r {
        case Err(lines) => lines |> List.filter(String.startsWith(prefix = "FAIL"))
        case Ok(_)      => Nil
    }

    def markTwice(): String = "fps 60\ntap mark\nwait 2f\nsaveload\ntap count\nwait 2f\ntap mark\nwait 2f\n"

    def markOnce(): String = "fps 60\ntap mark\nwait 2f\nsaveload\ntap count\nwait 2f\n"

    def probeSplit(): String = "FAIL body: saveload で読み直した流れと読み直さない流れで、問いの値が分かれた（App.withFlow の probes）"

    def saveSplit(): String = "FAIL body: saveload で読み直した流れと読み直さない流れで、最後のセーブが違う"

    @Test
    def testFaithfulLoadPassesEvenThoughTheSpinRestarts(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isOk(judged(true, loadFaithful, markTwice())))

    @Test
    def testForgottenMarkUsedAgainSplitsTheProbes(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(List.memberOf(probeSplit(), failLines(judged(false, loadForgetsSeen, markTwice()))))

    @Test
    def testForgottenMarkUsedAgainMakesTheLastSaveDiffer(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(List.memberOf(saveSplit(), failLines(judged(false, loadForgetsSeen, markTwice()))))

    @Test
    def testForgottenMarkNeverUsedAgainIsCaughtByItsProbe(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = probeSplit() :: Nil, failLines(judged(true, loadForgetsSeen, markOnce())))

    @Test
    def testForgottenMarkNeverUsedAgainWithoutAProbePasses(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isOk(judged(false, loadForgetsSeen, markOnce())))

    @Test
    def testLoadThatChangesTheSaveStopsAtTheSaveLoadLine(): Unit \ {Assert, Fs.FileRead} =
        let head = "FAIL body:4: saveload で読み直した流れが止まった";
        Assert.assertEq(expected = Some(head),
                        failLines(judged(true, loadOffByOne, markTwice())) |> List.head |> Option.map(String.takeLeft(String.length(head))))

    @Test
    def testSaveLoadWithoutRoundTripIsAParseError(): Unit \ Assert =
        let app = App.make(start()) |> App.addSystem(step) |> App.withFlow(table(true, None));
        Assert.assertTrue(Result.isErr(Flow.Parse.parseText(Flow.vocabOf(app, start()), "body", "saveload\n")))

    @Test
    def testDiffNamesTheChangedKey(): Unit \ Assert =
        Assert.assertEq(expected = "seen: true → false", Flow.SaveLoad.diffText("{\"n\": 1, \"seen\": true}", "{\"n\": 1, \"seen\": false}"))
}
