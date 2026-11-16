// 移行の突き合わせの記録（MigrateOut）: 出来事の並び・流した文の所・コマの予定・バスの音量・読み戻した所。
// シナリオは test/fixtures/migrate/migrate.yarn（同じフレームで流れるコマンド・時間を取る <<bg>>・<<wait>>・選択肢・<<set>>・自分への <<jump>>）。
// flow は「行く」を選び、Again に 2 回入ってから最後の行まで読む。
mod TestMigrate {

    use fge::{App, DocJson, Flow, JsonCodec, Resources}
    use Util.Json.Json

    type alias AppState = Resources.With[Res.Res, World.World]

    def flowText(): String =
        "fps 10\nwait 0.5\ntap confirm\ndrive reader until choice max 30\ntap confirm\n" +
        "drive reader until talkLine=test/fixtures/migrate/migrate.yarn:26 max 30\nwait 3\n"

    def res(): Res.Res \ Fs.FileRead = TestKit.fixtureRes("test/fixtures/migrate", "Station")

    /// 見本を流した結果（流せない時は理由の Err）。
    def outcome(): Result[String, Flow.Outcome[AppState]] \ Fs.FileRead =
        let r = res();
        let app = TestKit.app(r, TestKit.w0(r));
        let title = Resources.of(r, TestKit.w0(r));
        forM (
            script <- Flow.Parse.parseText(Flow.vocabOf(app, title), "migrate-test.flow", flowText()) |> Result.mapErr(Flow.Parse.problemsText);
            played <- Flow.play(app, { design = Layout.size(Layout.Fit.Regular), limit = 900 }, script, { world = title, state = App.freshStepState() })
                      |> Result.mapErr(failure -> failure#why)
        ) yield played

    def record(): Result[String, MigrateOut.Record] \ Fs.FileRead =
        forM (
            o     <- outcome();
            probe <- MigrateOut.probeRowsOf("logSize" :: Nil, res()#dialogue)
        ) yield MigrateOut.recordOf(10.0, probe, o#frames)

    def objectOf(row: Json): Map[String, Json] = JsonCodec.expectObject(row) |> Option.getWithDefault(Map.empty())

    def textOf(key: String, row: Json): String = JsonCodec.stringOr(key, "", objectOf(row))

    def intOf(key: String, row: Json): Int32 = JsonCodec.intOr(key, -9, objectOf(row))

    def lineOf(x: World.Executed): Int32 = match x {
        case World.Executed.Said((_, _, line), _, _)            => line
        case World.Executed.Offered((_, _, line), _)            => line
        case World.Executed.Commanded((_, _, line), _, _, _, _) => line
    }

    def events(): Result[String, List[Json]] \ Fs.FileRead = record() |> Result.map(rec -> rec#events)

    // ── 出来事と流した文の所 ──

    @Test
    def testEveryRunnerEventIsRecordedInOrder(): Unit \ {Assert, Fs.FileRead} =
        // 台詞・選択肢・コマンドを出た順に（Again へ入り直した 2 回の 21 行目も 2 つ）。
        let lines = outcome() |> Result.map(o -> MigrateOut.executedOf(o#frames) |> List.map(match (_, x) -> lineOf(x)));
        Assert.assertEq(expected = Ok(6 :: 7 :: 8 :: 9 :: 10 :: 11 :: 12 :: 13 :: 21 :: 21 :: 26 :: Nil), lines)

    @Test
    def testCommandsInTheSameFrameShareTheFrameNumber(): Unit \ {Assert, Fs.FileRead} =
        // 頭の <<audio>> 2 つと <<wait>> は同じフレームで流れ、どれも落ちない。
        let frames = outcome() |> Result.map(o -> MigrateOut.executedOf(o#frames) |> List.filter(match (_, x) -> lineOf(x) <= 8) |> List.map(fst) |> List.distinct |> List.length);
        Assert.assertEq(expected = Ok(1), frames)

    @Test
    def testRanLinesHoldSetJumpAndIfButNotTheUnchosenOption(): Unit \ {Assert, Fs.FileRead} =
        // <<set>>・<<jump>>・<<if>> の行も載り、選ばなかった「戻る」の中（17 行目）と <<declare>>（5 行目）は載らない。
        let lines = outcome() |> Result.map(o -> MigrateOut.ranLinesOf(o#frames) |> List.map(snd) |> List.toSet |> Set.toList);
        Assert.assertEq(expected = Ok(6 :: 7 :: 8 :: 9 :: 10 :: 11 :: 12 :: 13 :: 14 :: 15 :: 21 :: 22 :: 23 :: 24 :: 26 :: Nil), lines)

    @Test
    def testEventsNumberLinesPerVisit(): Unit \ {Assert, Fs.FileRead} =
        // 台詞の seq はノードに入ってからの番号で、Again へ入り直すと 0 から。待ちと選択肢の seq はそれまでの台詞の数。
        let rows = events() |> Result.map(es -> es |> List.map(e -> "${textOf("kind", e)}${intOf("seq", e)}"));
        Assert.assertEq(expected = Ok("wait0" :: "line0" :: "wait1" :: "line1" :: "choice2" :: "line0" :: "line0" :: "line1" :: Nil), rows)

    @Test
    def testChoiceCarriesThePickedOption(): Unit \ {Assert, Fs.FileRead} =
        let picked = events() |> Result.map(es -> es |> List.filter(e -> textOf("kind", e) == "choice") |> List.map(e -> intOf("picked", e)));
        Assert.assertEq(expected = Ok(0 :: Nil), picked)

    @Test
    def testLineCarriesTheProbesAndVariablesWhenItIsDone(): Unit \ {Assert, Fs.FileRead} =
        // バックログの行の数（選んだ選択肢も 1 行）と、シナリオの変数 $n（宣言から全部載る）。最後の行の時の $n は 3。
        let probes = events() |> Result.map(es -> es |> List.filter(e -> textOf("kind", e) == "line")
            |> List.map(e -> Map.get("probes", objectOf(e)) |> Option.map(p -> (intOf("logSize", p), intOf("$n", p))) |> Option.getWithDefault((-1, -1))));
        Assert.assertEq(expected = Ok((1, 0) :: (2, 0) :: (4, 1) :: (5, 2) :: (6, 3) :: Nil), probes)

    @Test
    def testUnknownProbeIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(MigrateOut.probeRowsOf("nope" :: Nil, res()#dialogue)))

    // ── コマの予定 ──

    @Test
    def testTimedCommandGetsThreeMidShotsWithItsSeconds(): Unit \ {Assert, Fs.FileRead} =
        // time=1.0 の <<bg>> は 0.25・0.5・0.75 の 3 枚（world の層・1 行目の後の 0 番目の時間を取る命令・秒は 1.0）。
        let mids = record() |> Result.map(rec -> rec#shots |> List.filterMap(s -> s#mid |> Option.filter(m -> m#cmd == "bg")
            |> Option.map(m -> (s#seq, m#step, m#at, m#seconds, s#layer == MigrateOut.Layer.WorldLayer))));
        Assert.assertEq(expected = Ok((0, 0, 0.25, 1.0, true) :: (0, 0, 0.5, 1.0, true) :: (0, 0, 0.75, 1.0, true) :: Nil), mids)

    @Test
    def testMidFrameJsonCarriesTheSeconds(): Unit \ {Assert, Fs.FileRead} =
        let seconds = record() |> Result.map(rec -> match MigrateOut.framesJson(10.0, rec#shots) {
            case Json.JArray(items) => Vector.toList(items) |> List.filter(f -> textOf("cmd", f) == "bg")
                |> List.map(f -> JsonCodec.floatOr("seconds", -1.0, objectOf(f)))
            case _ => Nil
        });
        Assert.assertEq(expected = Ok(1.0 :: 1.0 :: 1.0 :: Nil), seconds)

    @Test
    def testEachDoneLineIsShotInBothLayers(): Unit \ {Assert, Fs.FileRead} =
        let done = record() |> Result.map(rec -> rec#shots |> List.filter(s -> Option.isEmpty(s#mid)) |> List.map(s -> (s#node, s#seq)) |> List.distinct);
        Assert.assertEq(expected = Ok(("Station", 0) :: ("Station", 1) :: ("Again", 0) :: ("Again", 1) :: Nil), done)

    @Test
    def testDoneLineIsTheFrameBeforeTheNextEvent(): Unit \ {Assert, Fs.FileRead} =
        // 台詞を出し終えたコマは、次に出来事が出たフレームの 1 つ前（最後の行は flow の最後のフレーム）。
        let ok = forM (o <- outcome(); rec <- record()) yield {
            let eventFrames = MigrateOut.executedOf(o#frames) |> List.map(fst) |> List.toSet;
            let last = List.length(o#frames) - 1;
            rec#shots |> List.filter(s -> Option.isEmpty(s#mid)) |> List.forAll(s -> s#frame == last or Set.memberOf(s#frame + 1, eventFrames))
        };
        Assert.assertEq(expected = Ok(true), ok)

    // ── バスの音量 ──

    @Test
    def testBusesListEveryMixerBusWithDecibels(): Unit \ {Assert, Fs.FileRead} =
        // バスは novel.mixer.json の 3 本。最初の値は 0 秒の所にあり、-60〜0 dB の数。
        let firsts = outcome() |> Result.map(o -> match MigrateOut.busesJson(10.0, _ -> 0.5, o#frames) {
            case Some(Json.JObject(m)) => Map.toList(m) |> List.map(match (name, points) -> (name, firstPoint(points)))
            case _                     => Nil
        });
        Assert.assertEq(expected = Ok(("ambience", true) :: ("bgm", true) :: ("se", true) :: Nil), firsts)

    /// [[秒, dB], …] の頭が 0 秒で -60〜0 dB か。
    def firstPoint(points: Json): Bool = match points {
        case Json.JArray(rows) => Vector.head(rows) |> Option.exists(row -> match row {
            case Json.JArray(pair) =>
                let num = i -> Vector.nth(i, pair) |> Option.flatMap(JsonCodec.expectFloat);
                num(0) == Some(0.0) and num(1) |> Option.exists(db -> db <= 0.0 and db > -60.0)
            case _ => false
        })
        case _ => false
    }

    // ── 読み戻した所 ──

    @Test
    def testRestoredSeqCountsFromTheLastEntry(): Unit \ {Assert, Fs.FileRead} =
        // 最後の行（Again の 2 回目の 2 行目）は、入り直してから 1 回送った所なので 1（events の seq と同じ）。
        let seq = outcome() |> Result.map(o -> MigrateOut.restoredSeqOf(o#last#world));
        Assert.assertEq(expected = Ok(1), seq)

    @Test
    def testRestoreJsonCarriesThePlace(): Unit \ {Assert, Fs.FileRead} =
        let place = forM (
            o      <- outcome();
            probes <- MigrateOut.probeRowsOf("logSize" :: Nil, res()#dialogue);
            root   <- DocJson.parse(MigrateOut.restoreJson("s1", false, probes, Layout.size(Layout.Fit.Regular), "Again", 1, o#last, Nil, Nil))
                      |> Option.toOk("restore.json が JSON でない")
        ) yield (textOf("save", root), textOf("node", root), intOf("seq", root), Map.get("probes", objectOf(root)) |> Option.map(p -> intOf("$n", p)));
        Assert.assertEq(expected = Ok(("s1", "Again", 1, Some(3))), place)
}
