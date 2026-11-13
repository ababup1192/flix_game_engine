// 付箋の tape.json（TapeOut）と、そのシナリオの位置（World.talkCursorOf）。
// シナリオは小さな見本（下の program）: 時間を取らないコマンド・時間を取る <<bg>>・<<wait>>・鳴り続ける音を 1 つずつ並べる。
mod TestTape {

    use fge::{App, DocJson, Flow, JsonCodec, Rect2, Resources, Yarn}
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

    def res(): Res.Res \ Fs.FileRead =
        let program = Yarn.fromJson(programText()) |> Option.getWithDefault(Yarn.empty());
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
          msg = { x0 = 0.1, x1 = 0.9, cy = 0.8, lh = 0.05, padTop = 0.1, padBot = 0.1, font = 0.04, cps = 30.0 },
          probes = "logSize" :: Nil, probeNames = Map.empty(), playUrl = "",
          objects = h -> FlowVideo.objectsOf(Layout.Fit.Regular, h#resources, h#world) }

    /// flow を流して tape.json を作り、JSON の木にする（流せない・作れない時は理由の Err）。
    def tapeOf(marks: List[String]): Result[String, Map[String, Json]] \ Fs.FileRead =
        let r = res();
        let app = TestKit.app(r, TestKit.w0(r));
        let design = Layout.size(Layout.Fit.Regular);
        let title = Resources.of(r, TestKit.w0(r));
        let parsed = Flow.Parse.parseText(Flow.vocabOf(app, title), "tape-test.flow", flowText(marks)) |> Result.mapErr(Flow.Parse.problemsText);
        forM (
            script  <- parsed;
            outcome <- Flow.play(app, { design = design, limit = 600 }, script, { world = title, state = App.freshStepState() })
                       |> Result.mapErr(failure -> failure#why);
            text    <- TapeOut.toJson(table(), { game = "g", flow = "tape-test.flow", fps = script#fps, design = design, marks = marks, outcome = outcome });
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
        // 同じ id でも矩形が変われば別の行（動いた先の位置で付箋を指せるように）。
        let here = thing("girl", box(0.0, 0.0, 96.0, 54.0));
        let there = thing("girl", box(0.0, 270.0, 96.0, 54.0));
        let spans = TapeOut.spansOf(10.0, { x = 960.0, y = 540.0 }, (here :: Nil) :: (there :: Nil) :: Nil)
            |> List.map(s -> (s#startAt, s#rect#y));
        Assert.assertEq(expected = (0.0, 0.0) :: (0.1, 0.5) :: Nil, spans)

    @Test
    def testMessageWindowIsListedAsMessage(): Unit \ {Assert, Fs.FileRead} =
        // 読み始めるとメッセージウィンドウが id message で載る（付箋の頁が直した台詞を重ねる所）。
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
