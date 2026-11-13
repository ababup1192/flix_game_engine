// tape.json（TapeOut）と、そのシナリオの位置（World.talkCursorOf）。
// シナリオは小さな見本（下の program）: 時間を取らないコマンド・時間を取る <<bg>>・<<wait>>・鳴り続ける音を 1 つずつ並べる。
mod TestTape {

    use fge::{App, DocJson, Emit, Flow, JsonCodec, Rect2, Resources, Yarn}
    use Util.Json.Json

    type alias AppState = Resources.With[Res.Res, World.World]

    /// 見本のシナリオ（t.yarn・ノードは最初に開く Station）。
    ///   10 <<ambience river>>（時間を取らない・鳴り続ける） 11 <<se slap>> 12 <<wait 1>> 13 地の文
    ///   14 <<bg station dusk 1.0>>（時間を取る） 15 <<se furin>> 16 <<wait 1>> 17 千夏の台詞
    ///   18 <<se slap>> 19 <<wait 1>> 20 地の文
    def programText(): String =
        "{\"version\": 3, \"files\": [\"t.yarn\"], \"variables\": [], \"nodes\": [{\"title\": \"Station\", \"file\": \"t.yarn\", \"line\": 8, \"headers\": [], \"body\": [" +
        "{\"kind\": \"command\", \"line\": 10, \"name\": \"ambience\", \"args\": [\"river\"]}," +
        "{\"kind\": \"command\", \"line\": 11, \"name\": \"se\", \"args\": [\"slap\"]}," +
        "{\"kind\": \"command\", \"line\": 12, \"name\": \"wait\", \"args\": [\"1\"]}," +
        "{\"kind\": \"line\", \"line\": 13, \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"command\", \"line\": 14, \"name\": \"bg\", \"args\": [\"station\", \"dusk\", \"1.0\"]}," +
        "{\"kind\": \"command\", \"line\": 15, \"name\": \"se\", \"args\": [\"furin\"]}," +
        "{\"kind\": \"command\", \"line\": 16, \"name\": \"wait\", \"args\": [\"1\"]}," +
        "{\"kind\": \"line\", \"line\": 17, \"speaker\": \"chinatsu\", \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"command\", \"line\": 18, \"name\": \"se\", \"args\": [\"slap\"]}," +
        "{\"kind\": \"command\", \"line\": 19, \"name\": \"wait\", \"args\": [\"1\"]}," +
        "{\"kind\": \"line\", \"line\": 20, \"text\": \"" + longText() + "\"}]}]}"

    /// 台詞の字（文字送りが何フレームかかる長さ）。
    // WhyNot: 1 字にしない —— 1 フレームで出し終わると、読み手の drive が同じフレームで送ってしまい、その行がシナリオの位置に載らない。
    def longText(): String = "夏草の駅に降りると、蜩の声が押し寄せてきた。"

    def res(): Res.Res \ Fs.FileRead = resOf(programText())

    def resOf(text: String): Res.Res \ Fs.FileRead =
        let program = Yarn.fromJson(text) |> Option.getWithDefault(Yarn.empty());
        Res.withDialogue(program, TestKit.res())

    // ── シナリオの位置（World.talkCursorOf） ──

    @Test
    def testWaitAfterAnInstantCommandKeepsTheEmptyCursor(): Unit \ {Assert, Fs.FileRead} =
        // 頭の <<se>> の後の <<wait>> の間は、前の値（まだ何も無い = 空）のまま。
        let r = res();
        let opened = TestKit.quiet(() -> WorldRead.newGame(r, TestKit.w0(r)));
        Assert.assertEq(expected = "", World.talkCursorOf(opened))

    @Test
    def testWaitAfterABackdropPointsAtTheBackdrop(): Unit \ {Assert, Fs.FileRead} =
        // <<bg>> の後の <<wait>> の間は <<bg>> の行（<<se>> と <<wait>> の行ではない）。
        let r = res();
        let waiting = TestKit.advance(r, TestKit.begun(r));
        Assert.assertEq(expected = "t.yarn:14", World.talkCursorOf(waiting))

    @Test
    def testWaitAfterALineKeepsTheLine(): Unit \ {Assert, Fs.FileRead} =
        // 台詞の後に時間を取らない <<se>> と <<wait>> が続く間は、その台詞の行のまま。
        let r = res();
        let atLine = TestKit.settle(r, TestKit.advance(r, TestKit.begun(r)));
        let waiting = TestKit.advance(r, atLine);
        Assert.assertEq(expected = "t.yarn:17", World.talkCursorOf(waiting))

    // ── tape.json ──

    /// 見本のシナリオを流す flow（タイトル → はじめから → 最後の行まで読む）。
    // WhyNot: flow に start title を書かない —— start は Doc とシナリオを読み直すので、見本のシナリオが本物に戻る。
    def flowText(marks: List[String]): String =
        let mark = i -> List.nth(i, marks) |> Option.map(name -> "mark ${name}\n") |> Option.getWithDefault("");
        "fps 10\n" + mark(0) + "wait 0.5\ntap confirm\n" + mark(1) +
        "drive reader until talkLine=t.yarn:17 max 20\n" + mark(2) + "drive reader until talkLine=t.yarn:20 max 20\nwait 0.5\n"

    def table(): TapeOut.Table =
        { title = "見本", sceneNames = Map#{ "opening" => "はじめ" }, soundLabels = Map#{ "se_slap" => "叩く" },
          hiddenSounds = Set#{ "ui_open" },
          msg = { x0 = 0.1, x1 = 0.9, cy = 0.8, lh = 0.05, padTop = 0.1, padBot = 0.1, font = 0.04, cps = 30.0, when = Map.empty() },
          probes = "logSize" :: Nil, probeNames = Map.empty(), playUrl = "",
          objects = h -> FlowVideo.objectsOf(Layout.Fit.Regular, h#resources, h#world) }

    /// flow を流して tape.json を作り、JSON の木にする（流せない・作れない時は理由の Err）。
    def tapeOf(marks: List[String]): Result[String, Map[String, Json]] \ Fs.FileRead =
        tapeFrom(flowText(marks), marks, false)

    /// flow の文から tape.json の木を作る。untilStop なら flow が途中で止まってもそこまでの分で作る（FlowVideo と同じ）。
    def tapeFrom(flow: String, marks: List[String], untilStop: Bool): Result[String, Map[String, Json]] \ Fs.FileRead =
        tapeWith(table(), programText(), flow, marks, untilStop)

    /// 表を差し替えて tapeFrom と同じく作る。
    def tapeWith(tbl: TapeOut.Table, program: String, flow: String, marks: List[String], untilStop: Bool): Result[String, Map[String, Json]] \ Fs.FileRead =
        let r = resOf(program);
        let app = TestKit.app(r, TestKit.w0(r));
        let design = Layout.size(Layout.Fit.Regular);
        let title = Resources.of(r, TestKit.w0(r));
        let parsed = Flow.Parse.parseText(Flow.vocabOf(app, title), "tape-test.flow", flow) |> Result.mapErr(Flow.Parse.problemsText);
        let upTo = (played: Result[Flow.Failure[AppState], Flow.Outcome[AppState]]) -> match played {
            case Ok(outcome)                => Ok(outcome)
            case Err(failure) if untilStop  => Ok(failure#upTo)
            case Err(failure)               => Err(failure#why)
        };
        forM (
            script  <- parsed;
            outcome <- upTo(Flow.play(app, { design = design, limit = 600 }, script, { world = title, state = App.freshStepState() }));
            text    <- TapeOut.toJson(tbl, { game = "g", flow = "tape-test.flow", fps = script#fps, design = design, marks = marks, outcome = outcome });
            root    <- DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("tape.json が JSON でない")
        ) yield root

    def arrayAt(key: String, root: Map[String, Json]): List[Json] =
        match Map.get(key, root) {
            case Some(Json.JArray(items)) => Vector.toList(items)
            case _                        => Nil
        }

    /// [秒, 値] の値の側。
    def secondOf(pair: Json): Json = match pair {
        case Json.JArray(items) => Vector.nth(1, items) |> Option.getWithDefault(Json.JNull)
        case _                  => Json.JNull
    }

    def textAt(key: String, row: Json): String =
        JsonCodec.expectObject(row) |> Option.map(obj -> JsonCodec.stringOr(key, "", obj)) |> Option.getWithDefault("")

    /// 行の番号の JSON（null は -1）。
    def lineOf(value: Json): Int32 = JsonCodec.expectInt(value) |> Option.getWithDefault(-1)

    @Test
    def testScenesFollowTheMarksInOrder(): Unit \ {Assert, Fs.FileRead} =
        // mark が書いた順にシーンになり、表示名は表から（無ければ mark の名前）。
        let scenes = tapeOf("start" :: "opening" :: "chinatsu" :: Nil) |> Result.map(root ->
            arrayAt("scenes", root) |> List.map(row -> (textAt("id", row), textAt("name", row))));
        Assert.assertEq(expected = Ok(("start", "start") :: ("opening", "はじめ") :: ("chinatsu", "chinatsu") :: Nil), scenes)

    @Test
    def testTimelineKeepsOnlyChangesAndEmptyIsNull(): Unit \ {Assert, Fs.FileRead} =
        // シナリオの位置が変わった所だけが載り、空は null（-1）。<<se>> と <<wait>> の行（11・12・15・16・18・19）は載らない。
        let lines = tapeOf(Nil) |> Result.map(root -> arrayAt("timeline", root) |> List.map(pair -> lineOf(secondOf(pair))));
        Assert.assertEq(expected = Ok(-1 :: 13 :: 14 :: 17 :: 20 :: Nil), lines)

    @Test
    def testSustainedSoundIsListedOnceWhenItStarts(): Unit \ {Assert, Fs.FileRead} =
        // 鳴り続ける音は鳴り始めのフレームに 1 回だけ ambience で載る（タイトルの環境音と <<ambience river>>）。
        let started = tapeOf(Nil) |> Result.map(root -> arrayAt("sounds", root)
            |> List.filter(row -> textAt("kind", row) == "ambience") |> List.map(row -> textAt("name", row)));
        Assert.assertEq(expected = Ok(Stage.ambienceSound(StoryDoc.rec(TestKit.res()#story)#titleAmbience) :: Stage.ambienceSound("river") :: Nil), started)

    @Test
    def testOneShotSoundCarriesItsLabel(): Unit \ {Assert, Fs.FileRead} =
        // 一発の音は se で、表の label が付く（UI の返事の音は表で外す）。
        let shots = tapeOf(Nil) |> Result.map(root -> arrayAt("sounds", root)
            |> List.filter(row -> textAt("kind", row) == "se") |> List.map(row -> (textAt("name", row), textAt("label", row))));
        Assert.assertEq(expected = Ok(("se_slap", "叩く") :: ("se_furin", "se_furin") :: ("se_slap", "叩く") :: Nil), shots)

    @Test
    def testStoppedFlowStillWritesTheFramesSoFar(): Unit \ {Assert, Fs.FileRead} =
        // flow が途中で止まっても（届かない until）、止まるまでの分で tape.json を作る。読み始めた 13 行目は載る。
        let stopping = "fps 10\nwait 0.5\ntap confirm\ndrive reader until talkLine=t.yarn:99 max 2\n";
        let lines = tapeFrom(stopping, Nil, true) |> Result.map(root -> arrayAt("timeline", root) |> List.map(pair -> lineOf(secondOf(pair))));
        Assert.assertEq(expected = Ok(true), lines |> Result.map(List.memberOf(13)))

    @Test
    def testSameMarkNameTwiceStops(): Unit \ {Assert, Fs.FileRead} =
        // 同じ名前の mark が 2 つあると tape.json を作らない。
        Assert.assertTrue(Result.isErr(tapeOf("start" :: "start" :: Nil)))

    @Test
    def testWholeNumberProbeIsWrittenAsInt(): Unit \ {Assert, Fs.FileRead} =
        // Num の問いが整数なら整数で書く（最後の値 = 読んだ行の数）。
        let last = tapeOf(Nil) |> Result.map(root -> Map.get("probes", root) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(obj -> arrayAt("logSize", obj)) |> Option.getWithDefault(Nil) |> List.last |> Option.map(secondOf)
            |> Option.flatMap(JsonCodec.expectInt));
        Assert.assertEq(expected = Ok(Some(3)), last)

    @Test
    def testMsgCarriesItsWhenCondition(): Unit \ {Assert, Fs.FileRead} =
        // msg の when（問い → 値）がそのまま tape.json の msg に載る。
        let tbl = { msg = { when = Map#{ "logSize" => "3" } | table()#msg } | table() };
        let when = tapeWith(tbl, programText(), flowText(Nil), Nil, false) |> Result.map(root -> Map.get("msg", root) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("when")) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(obj -> JsonCodec.stringOr("logSize", "", obj)));
        Assert.assertEq(expected = Ok(Some("3")), when)

    @Test
    def testMsgWhenOnAProbeNotListedStops(): Unit \ {Assert, Fs.FileRead} =
        // msg の when が probes に無い問いを見ていたら tape.json を作らない。
        let tbl = { msg = { when = Map#{ "mode" => "Adv" } | table()#msg } | table() };
        Assert.assertTrue(Result.isErr(tapeWith(tbl, programText(), flowText(Nil), Nil, false)))

    // ── ノードをまたぐ flow と選択肢（choices） ──

    /// ノード 2 つ・選択肢 2 つの見本（t.yarn）。
    ///   Station（8）: 10 地の文 11 選択肢 12「右へ」→ 13 <<jump Field>> / 14「左へ」→ 15 地の文 16 <<jump Field>>
    ///   Field（18）: 20 地の文
    def forkText(): String =
        "{\"version\": 3, \"files\": [\"t.yarn\"], \"variables\": [], \"nodes\": [" +
        "{\"title\": \"Station\", \"file\": \"t.yarn\", \"line\": 8, \"headers\": [], \"body\": [" +
        "{\"kind\": \"line\", \"line\": 10, \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"options\", \"line\": 11, \"options\": [" +
        "{\"line\": 12, \"text\": \"右へ\", \"body\": [{\"kind\": \"jump\", \"line\": 13, \"node\": \"Field\"}]}," +
        "{\"line\": 14, \"text\": \"左へ\", \"body\": [{\"kind\": \"line\", \"line\": 15, \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"jump\", \"line\": 16, \"node\": \"Field\"}]}]}]}," +
        "{\"title\": \"Field\", \"file\": \"t.yarn\", \"line\": 18, \"headers\": [], \"body\": [" +
        "{\"kind\": \"line\", \"line\": 20, \"text\": \"" + longText() + "\"}]}]}"

    /// 選択肢まで読み、カーソルを 2 つ目へ動かして選び、Field の行まで読む flow。
    def forkFlow(): String =
        "fps 10\nwait 0.5\ntap confirm\ndrive reader until choice max 30\nwait 0.3\ntap next\nwait 0.3\ntap confirm\n" +
        "drive reader until talkLine=t.yarn:20 max 30\nwait 0.5\n"

    def forkTape(): Result[String, Map[String, Json]] \ Fs.FileRead = tapeWith(table(), forkText(), forkFlow(), Nil, false)

    def objectAt(key: String, root: Map[String, Json]): Map[String, Json] =
        Map.get(key, root) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty())

    @Test
    def testTopNodeIsTheFirstNodeOpened(): Unit \ {Assert, Fs.FileRead} =
        // ノードをまたいだ flow でも作れて、top の node は最初に開いたノード。
        Assert.assertEq(expected = Ok("Station"), forkTape() |> Result.map(root -> textAt("node", Json.JObject(root))))

    /// lines の行 n の node（無ければ空）。
    def lineNode(n: String, root: Map[String, Json]): String =
        Map.get(n, objectAt("lines", root)) |> Option.map(textAt("node")) |> Option.getWithDefault("")

    @Test
    def testLineOfTheFirstNodeCarriesItsNode(): Unit \ {Assert, Fs.FileRead} =
        // 最初のノードの行には、そのノードの名前が載る。
        Assert.assertEq(expected = Ok("Station"), forkTape() |> Result.map(lineNode("10")))

    @Test
    def testLineAfterTheJumpCarriesTheNextNode(): Unit \ {Assert, Fs.FileRead} =
        // <<jump>> の先のノードの行には、先のノードの名前が載る。
        Assert.assertEq(expected = Ok("Field"), forkTape() |> Result.map(lineNode("20")))

    @Test
    def testChoiceRecordsItsOptionsAndThePickedOne(): Unit \ {Assert, Fs.FileRead} =
        // 2 つの選択肢を出して 2 つ目を選ぶと、choices に 1 行: 最初の選択肢の行・ノード・字の並び・選んだ番号。
        let rows = forkTape() |> Result.map(root -> arrayAt("choices", root) |> List.filterMap(JsonCodec.expectObject) |> List.map(row -> (
            Map.get("line", row) |> Option.flatMap(JsonCodec.expectInt),
            JsonCodec.stringOr("node", "", row),
            arrayAt("options", row) |> List.filterMap(JsonCodec.expectString),
            Map.get("picked", row) |> Option.flatMap(JsonCodec.expectInt))));
        Assert.assertEq(expected = Ok((Some(12), "Station", "右へ" :: "左へ" :: Nil, Some(1)) :: Nil), rows)

    /// choices の picked の並び（作れなければ Err）。
    def pickedOf(tape: Result[String, Map[String, Json]]): Result[String, List[Int32]] =
        tape |> Result.map(root -> arrayAt("choices", root) |> List.filterMap(JsonCodec.expectObject)
            |> List.filterMap(row -> Map.get("picked", row) |> Option.flatMap(JsonCodec.expectInt)))

    @Test
    def testChoiceCarriesTheLineShownWithTheOptions(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出していた時の台詞（頁の今の行）が question に載る。
        let questions = forkTape() |> Result.map(root -> arrayAt("choices", root) |> List.map(textAt("question")));
        Assert.assertEq(expected = Ok(longText() :: Nil), questions)

    @Test
    def testFingerTapOnTheSecondOptionIsPickedOne(): Unit \ {Assert, Fs.FileRead} =
        // カーソルを動かさず 2 つ目の選択肢を指で押しても、picked は 1。
        let box = Layout.choice(Layout.Fit.Regular, 1, 2);
        let x = Float64.round(box#position#x + box#size#x / 2.0);
        let y = Float64.round(box#position#y + box#size#y / 2.0);
        let tap = "tap ${Float64.toString(x)},${Float64.toString(y)}";
        let flow = "fps 10\nwait 0.5\ntap confirm\ndrive reader until choice max 30\nwait 0.3\n${tap}\n" +
                   "drive reader until talkLine=t.yarn:20 max 30\nwait 0.5\n";
        Assert.assertEq(expected = Ok(1 :: Nil), pickedOf(tapeWith(table(), forkText(), flow, Nil, false)))

    /// 選ぶとすぐ同じ選択肢へ戻る見本（t.yarn）。
    ///   Station（8）: 10 地の文 11 <<jump Loop>>
    ///   Loop（13）: 15 選択肢 16「回る」→ 17 <<jump Loop>> / 18「出る」→ 19 <<jump Field>>
    ///   Field（21）: 23 地の文
    def loopText(): String =
        "{\"version\": 3, \"files\": [\"t.yarn\"], \"variables\": [], \"nodes\": [" +
        "{\"title\": \"Station\", \"file\": \"t.yarn\", \"line\": 8, \"headers\": [], \"body\": [" +
        "{\"kind\": \"line\", \"line\": 10, \"text\": \"" + longText() + "\"}," +
        "{\"kind\": \"jump\", \"line\": 11, \"node\": \"Loop\"}]}," +
        "{\"title\": \"Loop\", \"file\": \"t.yarn\", \"line\": 13, \"headers\": [], \"body\": [" +
        "{\"kind\": \"options\", \"line\": 15, \"options\": [" +
        "{\"line\": 16, \"text\": \"回る\", \"body\": [{\"kind\": \"jump\", \"line\": 17, \"node\": \"Loop\"}]}," +
        "{\"line\": 18, \"text\": \"出る\", \"body\": [{\"kind\": \"jump\", \"line\": 19, \"node\": \"Field\"}]}]}]}," +
        "{\"title\": \"Field\", \"file\": \"t.yarn\", \"line\": 21, \"headers\": [], \"body\": [" +
        "{\"kind\": \"line\", \"line\": 23, \"text\": \"" + longText() + "\"}]}]}"

    @Test
    def testSameOptionsShownAgainRightAfterPickingAreTwoChoices(): Unit \ {Assert, Fs.FileRead} =
        // 選んだ同じフレームで同じ選択肢がまた出ても、選ぶたびに 1 行ずつ載る（1 回目は「回る」、2 回目は「出る」）。
        let flow = "fps 10\nwait 0.5\ntap confirm\ndrive reader until choice max 30\nwait 0.3\ntap confirm\nwait 0.3\n" +
                   "tap next\nwait 0.3\ntap confirm\ndrive reader until talkLine=t.yarn:23 max 30\nwait 0.5\n";
        Assert.assertEq(expected = Ok(0 :: 1 :: Nil), pickedOf(tapeWith(table(), loopText(), flow, Nil, false)))

    /// 同じ字の選択肢を 2 回出す見本（t.yarn・ノード Station）。
    ///   10 地の文 11 選択肢 12「右へ」→ 13 地の文 / 14「左へ」→ 15 地の文
    ///   16 地の文 17 選択肢 18「右へ」→ 19 地の文 / 20「左へ」→ 21 地の文 22 地の文
    def twiceText(): String =
        let say = (n: Int32) -> "{\"kind\": \"line\", \"line\": ${Int32.toString(n)}, \"text\": \"" + longText() + "\"}";
        let ask = (n: Int32) -> "{\"kind\": \"options\", \"line\": ${Int32.toString(n)}, \"options\": [" +
            "{\"line\": ${Int32.toString(n + 1)}, \"text\": \"右へ\", \"body\": [" + say(n + 2) + "]}," +
            "{\"line\": ${Int32.toString(n + 3)}, \"text\": \"左へ\", \"body\": [" + say(n + 4) + "]}]}";
        "{\"version\": 3, \"files\": [\"t.yarn\"], \"variables\": [], \"nodes\": [" +
        "{\"title\": \"Station\", \"file\": \"t.yarn\", \"line\": 8, \"headers\": [], \"body\": [" +
        say(10) + "," + ask(11) + "," + say(16) + "," + ask(17) + "," + say(22) + "]}]}"

    /// 1 フレーム分の流した結果を手で組む（出来事は before と after の World の溜めの差）。
    def played(r: Res.Res, before: World.World, after: World.World): Flow.Played[AppState] =
        { step = { frame = App.emptyFrame(), before = Resources.of(r, before), after = Resources.of(r, after), sounds = Nil, sustained = Nil },
          state = App.freshStepState() }

    /// f を走らせ、その間に出た出来事を World の溜めに足す（ゲームの 1 フレームと同じ溜め方）。
    // WhyNot: TestKit.pick を使わない — 出来事を捨てるので、溜めから選んだことを読む TapeOut.choicesOf に渡せない。
    def recorded(f: Unit -> World.World \ Emit[World.Event], w: World.World): World.World =
        let (next, events) = Emit.collectInto(f, w#events);
        { events = events | next }

    def pickRecorded(r: Res.Res, i: Int32, w: World.World): World.World = recorded(() -> WorldRead.pick(r, i, w), w)

    /// 同じ字の選択肢の 1 回目で「右へ」を選び、2 回目の選択肢を出している所までの 2 フレームと、その時の World。
    def pickedOnceThenAsked(r: Res.Res): (List[Flow.Played[AppState]], World.World) =
        let asked = TestKit.readUntil(r, World.isChoosing, Nil, TestKit.begun(r));
        let chose = pickRecorded(r, 0, asked);
        let again = TestKit.readUntil(r, World.isChoosing, Nil, chose);
        (played(r, asked, chose) :: played(r, chose, again) :: Nil, again)

    def pickedIndexes(frames: List[Flow.Played[AppState]]): List[Int32] = TapeOut.choicesOf(frames) |> List.map(c -> c#picked)

    @Test
    def testSecondTimeOfTheSameOptionsStartsWhenTheyAppearedAgain(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢が 0 フレーム目に出て 2 フレーム目に「回る」を選ぶと同じフレームでまた出る。2 回目（4 フレーム目に「出る」）の at はまた出た 2。
        let r = resOf(loopText());
        let asked = TestKit.readUntil(r, World.isChoosing, Nil, TestKit.begun(r));
        let again = pickRecorded(r, 0, asked);
        let left = pickRecorded(r, 1, again);
        let frames = played(r, asked, asked) :: played(r, asked, asked) :: played(r, asked, again) ::
                     played(r, again, again) :: played(r, again, left) :: Nil;
        Assert.assertEq(expected = 0 :: 2 :: Nil, TapeOut.choicesOf(frames) |> List.map(c -> c#at))

    @Test
    def testJumpingBackFromTheLogIsNotAPick(): Unit \ {Assert, Fs.FileRead} =
        // 2 回目の選択肢からバックログで前の行へ戻ると選択肢は消えるが、選んだ所には数えない（1 回目の「右へ」だけ）。
        let r = resOf(twiceText());
        let (frames, again) = pickedOnceThenAsked(r);
        let back = recorded(() -> WorldLog.jumpTo(r, 0, again), again);
        Assert.assertEq(expected = 0 :: Nil, pickedIndexes(List.append(frames, played(r, again, back) :: Nil)))

    @Test
    def testJumpingBackFromTheLogHidesTheOptions(): Unit \ {Assert, Fs.FileRead} =
        // 上の見本の前提: 2 回目の選択肢からバックログの一番新しい行へ戻ると、選択肢は出ていない。
        let r = resOf(twiceText());
        let (_, again) = pickedOnceThenAsked(r);
        Assert.assertFalse(World.isChoosing(TestKit.quiet(() -> WorldLog.jumpTo(r, 0, again))))

    @Test
    def testLeavingForTheTitleIsNotAPick(): Unit \ {Assert, Fs.FileRead} =
        // 2 回目の選択肢を出したままタイトルへ戻っても、選んだ所には数えない。
        let r = resOf(twiceText());
        let (frames, again) = pickedOnceThenAsked(r);
        Assert.assertEq(expected = 0 :: Nil, pickedIndexes(List.append(frames, played(r, again, World.toTitle(again)) :: Nil)))

    @Test
    def testChoiceTimeIsWhenTheOptionsAppeared(): Unit \ {Assert, Fs.FileRead} =
        // 選んだ所の秒は、選択肢が出たフレーム（シナリオの位置が最初の選択肢の行になった秒と同じ）。
        let times = forkTape() |> Result.map(root -> {
            let shown = arrayAt("timeline", root) |> List.find(pair -> lineOf(secondOf(pair)) == 12) |> Option.flatMap(firstOf);
            let chosen = arrayAt("choices", root) |> List.head |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(Map.get("t"));
            (shown, chosen)
        });
        Assert.assertEq(expected = true, times |> Result.map(match (a, b) -> not Option.isEmpty(a) and a == b) |> Result.getWithDefault(false))

    /// [秒, 値] の秒の側。
    def firstOf(pair: Json): Option[Json] = match pair {
        case Json.JArray(items) => Vector.nth(0, items)
        case _                  => None
    }

    @Test
    def testFlowWithoutChoicesHasNoChoices(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢の無い flow では choices は空。
        Assert.assertEq(expected = Ok(Nil), tapeOf(Nil) |> Result.map(root -> arrayAt("choices", root)))

    // ── 画面に出ている物（objects） ──

    def box(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 = { position = { x = x, y = y }, size = { x = w, y = h } }

    def thing(id: String, r: Rect2.Rect2): TapeOut.ScreenObject = { id = id, name = id, rect = r }

    def asTuple(f: TapeOut.Fraction): (Float64, Float64, Float64, Float64) = (f#x, f#y, f#w, f#h)

    @Test
    def testRectBecomesFractionOfTheScreen(): Unit \ Assert =
        // design の px を画面の幅と高さで割る（960×540 の (96, 54, 480, 270) → 0.1, 0.1, 0.5, 0.5）。
        Assert.assertEq(expected = Some((0.1, 0.1, 0.5, 0.5)),
                        TapeOut.fractionOf({ x = 960.0, y = 540.0 }, box(96.0, 54.0, 480.0, 270.0)) |> Option.map(asTuple))

    @Test
    def testFractionIsClampedToTheScreenAndRoundedToThreeDigits(): Unit \ Assert =
        // はみ出す分は画面の端で切り、小数 3 桁に丸める（-12 → 0・1/3 → 0.333）。
        Assert.assertEq(expected = Some((0.0, 0.0, 0.333, 1.0)),
                        TapeOut.fractionOf({ x = 960.0, y = 540.0 }, box(-12.0, -12.0, 332.0, 564.0)) |> Option.map(asTuple))

    @Test
    def testSameObjectInARowFoldsIntoOneSpan(): Unit \ Assert =
        // 続けて出ている間は 1 行（from = 出たフレーム、to = 消えたフレーム）。10fps で a は 0〜3 フレーム目、b は 2〜4 フレーム目（最後まで）。
        let a = thing("a", box(0.0, 0.0, 96.0, 54.0));
        let b = thing("b", box(96.0, 54.0, 96.0, 54.0));
        let spans = TapeOut.spansOf(10.0, { x = 960.0, y = 540.0 }, (a :: Nil) :: (a :: Nil) :: (a :: b :: Nil) :: (b :: Nil) :: Nil)
            |> List.map(s -> (s#id, s#startAt, s#endAt));
        Assert.assertEq(expected = ("a", 0.0, 0.3) :: ("b", 0.2, 0.4) :: Nil, spans)

    @Test
    def testMovedObjectStartsANewSpan(): Unit \ Assert =
        // 同じ id でも矩形が変われば別の行（動いた先の位置で注釈を付けられるように）。
        let here = thing("girl", box(0.0, 0.0, 96.0, 54.0));
        let there = thing("girl", box(0.0, 270.0, 96.0, 54.0));
        let spans = TapeOut.spansOf(10.0, { x = 960.0, y = 540.0 }, (here :: Nil) :: (there :: Nil) :: Nil)
            |> List.map(s -> (s#startAt, s#rect#y));
        Assert.assertEq(expected = (0.0, 0.0) :: (0.1, 0.5) :: Nil, spans)

    @Test
    def testMessageWindowIsListedAsMessage(): Unit \ {Assert, Fs.FileRead} =
        // 読み始めるとメッセージウィンドウが id message で載る（テープの頁が直した台詞を重ねる所）。
        let ids = tapeOf(Nil) |> Result.map(root -> arrayAt("objects", root) |> List.map(row -> textAt("id", row)));
        Assert.assertEq(expected = Ok(true), ids |> Result.map(List.memberOf("message")))

    @Test
    def testTitleMenuIsListedFromTheFirstFrame(): Unit \ {Assert, Fs.FileRead} =
        // タイトル画面のメニューは 0 秒から載る。
        let first = tapeOf(Nil) |> Result.map(root -> arrayAt("objects", root)
            |> List.find(row -> textAt("id", row) == "title_menu")
            |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(obj -> Map.get("from", obj)) |> Option.flatMap(JsonCodec.expectInt));
        Assert.assertEq(expected = Ok(Some(0)), first)
}
