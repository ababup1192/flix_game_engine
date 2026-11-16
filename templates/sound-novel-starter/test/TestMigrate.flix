// 移行の突き合わせの記録（MigrateOut）: 出来事の並び・コマの予定・バスの音量。
// シナリオは TestTape と同じ形の小さな見本: 同じフレームで流れるコマンド・時間を取る <<bg>>・<<wait>>・台詞 3 行。
mod TestMigrate {

    use fge::{App, Flow, JsonCodec, Resources, Yarn}
    use Util.Json.Json

    type alias AppState = Resources.With[Res.Res, World.World]

    /// 見本のシナリオ（t.yarn・ノードは Station）。
    ///   10 <<audio ambience amb_river>> 11 <<audio se se_slap>> 12 <<wait 1>> 13 地の文
    ///   14 <<bg slope grade=dusk time=1.0>> 15 <<wait 1>> 16 千夏の台詞 17 <<wait 1>> 18 地の文
    def programText(): String =
        "{\"version\": 3, \"files\": [\"t.yarn\"], \"variables\": [], \"nodes\": [{\"title\": \"Station\", \"file\": \"t.yarn\", \"line\": 8, \"headers\": [], \"body\": [" +
        "{\"kind\": \"command\", \"line\": 10, \"name\": \"audio\", \"args\": [\"ambience\", \"amb_river\"]}," +
        "{\"kind\": \"command\", \"line\": 11, \"name\": \"audio\", \"args\": [\"se\", \"se_slap\"]}," +
        "{\"kind\": \"command\", \"line\": 12, \"name\": \"wait\", \"args\": [\"1\"]}," +
        "{\"kind\": \"line\", \"line\": 13, \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"command\", \"line\": 14, \"name\": \"bg\", \"args\": [\"slope\", \"grade=dusk\", \"time=1.0\"]}," +
        "{\"kind\": \"command\", \"line\": 15, \"name\": \"wait\", \"args\": [\"1\"]}," +
        "{\"kind\": \"line\", \"line\": 16, \"speaker\": \"chinatsu\", \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"command\", \"line\": 17, \"name\": \"wait\", \"args\": [\"1\"]}," +
        "{\"kind\": \"line\", \"line\": 18, \"text\": \"" + longText() + "\"}]}]}"

    // WhyNot: 1 字にしない —— 1 フレームで出し終わると、読み手の drive が同じフレームで送ってしまう。
    def longText(): String = "夏草の駅に降りると、蜩の声が押し寄せてきた。"

    def flowText(): String =
        "fps 10\nwait 0.5\ntap confirm\ndrive reader until talkLine=t.yarn:18 max 30\nwait 0.5\n"

    /// 見本を流した結果（流せない時は理由の Err）。
    def outcome(): Result[String, Flow.Outcome[AppState]] \ Fs.FileRead =
        let program = Yarn.fromJson(programText()) |> Option.getWithDefault(Yarn.empty());
        let r = Res.withDialogue(program, TestKit.res()) |> TestKit.withOpening("Station");
        let app = TestKit.app(r, TestKit.w0(r));
        let title = Resources.of(r, TestKit.w0(r));
        forM (
            script <- Flow.Parse.parseText(Flow.vocabOf(app, title), "migrate-test.flow", flowText()) |> Result.mapErr(Flow.Parse.problemsText);
            played <- Flow.play(app, { design = Layout.size(Layout.Fit.Regular), limit = 600 }, script, { world = title, state = App.freshStepState() })
                      |> Result.mapErr(failure -> failure#why)
        ) yield played

    def record(): Result[String, MigrateOut.Record] \ Fs.FileRead =
        outcome() |> Result.map(o -> MigrateOut.recordOf(10.0, "logSize" :: Nil, o#frames))

    def objectOf(row: Json): Map[String, Json] = JsonCodec.expectObject(row) |> Option.getWithDefault(Map.empty())

    def textOf(key: String, row: Json): String = JsonCodec.stringOr(key, "", objectOf(row))

    def intOf(key: String, row: Json): Int32 = JsonCodec.intOr(key, -9, objectOf(row))

    def ranLine(x: World.Executed): Int32 = match x {
        case World.Executed.Said((_, _, line), _, _)   => line
        case World.Executed.Offered((_, _, line), _)   => line
        case World.Executed.Ran((_, _, line), _, _, _) => line
    }

    @Test
    def testRanLinesHoldEveryStatementTheRunnerRan(): Unit \ {Assert, Fs.FileRead} =
        // 台詞・コマンド・<<wait>> の行が全部（流した文の行は実行器が数える）。
        let lines = outcome() |> Result.map(o -> MigrateOut.ranLinesOf(o#frames));
        Assert.assertEq(expected = Ok(10 :: 11 :: 12 :: 13 :: 14 :: 15 :: 16 :: 17 :: 18 :: Nil), lines)

    @Test
    def testEveryRunnerEventIsRecordedEvenInTheSameFrame(): Unit \ {Assert, Fs.FileRead} =
        // 同じフレームで流れる 2 つの <<audio>> も落とさず、実行器が出した文が全部、出た順に載る。
        let lines = outcome() |> Result.map(o -> MigrateOut.executedOf(o#frames) |> List.map(match (_, x) -> ranLine(x)));
        Assert.assertEq(expected = Ok(10 :: 11 :: 12 :: 13 :: 14 :: 15 :: 16 :: 17 :: 18 :: Nil), lines)

    @Test
    def testEventsAreWaitsAndLinesWithTheirNumbers(): Unit \ {Assert, Fs.FileRead} =
        // 台詞の seq はノードの中の番号、待ちの seq はそれまでに出した台詞の数。
        let rows = record() |> Result.map(rec -> rec#events |> List.map(e -> "${textOf("kind", e)}${intOf("seq", e)}"));
        Assert.assertEq(expected = Ok("wait0" :: "line0" :: "wait1" :: "line1" :: "wait2" :: "line2" :: Nil), rows)

    @Test
    def testLineCarriesTheProbesWhenItIsDone(): Unit \ {Assert, Fs.FileRead} =
        // 2 行目を出し終えた時のバックログは 2 行。
        let probes = record() |> Result.map(rec -> rec#events |> List.filter(e -> textOf("kind", e) == "line")
            |> List.map(e -> Map.get("probes", objectOf(e)) |> Option.map(p -> intOf("logSize", p)) |> Option.getWithDefault(-1)));
        Assert.assertEq(expected = Ok(1 :: 2 :: 3 :: Nil), probes)

    @Test
    def testTimedCommandGetsThreeMidShotsAfterTheFirstLine(): Unit \ {Assert, Fs.FileRead} =
        // time=1.0 の <<bg>> は 0.25・0.5・0.75 の 3 枚（world の層・1 行目の後の 0 番目の時間を取る命令）。
        let mids = record() |> Result.map(rec -> rec#shots |> List.filterMap(s -> s#mid |> Option.map(m -> (s#seq, m, s#layer))));
        let bg = share -> (0, ("bg", 0, share, 1.0), MigrateOut.Layer.WorldLayer);
        Assert.assertEq(expected = Ok(bg(0.25) :: bg(0.5) :: bg(0.75) :: Nil), mids)

    @Test
    def testEachDoneLineIsShotInBothLayers(): Unit \ {Assert, Fs.FileRead} =
        let done = record() |> Result.map(rec -> rec#shots |> List.filter(s -> Option.isEmpty(s#mid)) |> List.map(s -> (s#seq, s#layer)));
        let both = seq -> (seq, MigrateOut.Layer.WorldLayer) :: (seq, MigrateOut.Layer.AllLayers) :: Nil;
        Assert.assertEq(expected = Ok(List.flatten(both(0) :: both(1) :: both(2) :: Nil)), done)

    @Test
    def testBusesListEveryMixerBus(): Unit \ {Assert, Fs.FileRead} =
        // バスは novel.mixer.json の 3 本（どれも最初のフレームに 1 回は載る）。
        let names = outcome() |> Result.map(o -> match MigrateOut.busesJson(10.0, _ -> 0.5, o#frames) {
            case Json.JObject(m) => Map.keysOf(m) |> Set.toList
            case _               => Nil
        });
        Assert.assertEq(expected = Ok("ambience" :: "bgm" :: "se" :: Nil), names)
}
