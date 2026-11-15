// YarnCommands のテスト。受ける行と断る行の見本（go の検査と同じ command-args.json）を表で読み、
// Param で書いた表（marker・text・scope を含む）が見本と同じ vocab.json になる事・型付きで読める事・2 つ目の使い手（道具や敵の名前を引く
// 13 個のゲームのコマンド）の台本の行が表で読める事を見る。

mod TestYarnCommands {
    use YarnCommands.Param
    use YarnCommands.Param.Or

    def samplesPath(): String = "../../go/internal/yarn/testdata/command-args.json"

    def commandOf(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "t.yarn", line = 1 } }

    def samples(): Map[String, Util.Json.Json] \ Fs.FileRead =
        DocJson.readJson(samplesPath()) |> Result.toOption |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty())

    def sampleSpecs(): List[YarnCommands.Spec] \ Fs.FileRead =
        Map.get("commands", samples()) |> Option.map(YarnCommands.fromJson) |> Option.flatMap(Result.toOption) |> Option.getWithDefault(Nil)

    /// 見本の 1 行: (コマンド, 引数, 受けるか)。
    def sampleCases(): List[(String, List[String], Bool)] \ Fs.FileRead =
        Map.get("cases", samples()) |> Option.map(caseRows) |> Option.getWithDefault(Nil)

    def caseRows(json: Util.Json.Json): List[(String, List[String], Bool)] = match json {
        case Util.Json.Json.JArray(xs) => xs |> Vector.toList |> List.filterMap(caseOf)
        case _                         => Nil
    }

    def caseOf(json: Util.Json.Json): Option[(String, List[String], Bool)] =
        forM (
            obj <- JsonCodec.expectObject(json);
            cmd <- Map.get("cmd", obj) |> Option.flatMap(JsonCodec.expectString);
            ok  <- Map.get("ok", obj) |> Option.flatMap(JsonCodec.expectBool)
        ) yield (cmd, Map.get("args", obj) |> Option.map(stringsOf) |> Option.getWithDefault(Nil), ok)

    def stringsOf(json: Util.Json.Json): List[String] = match json {
        case Util.Json.Json.JArray(xs) => xs |> Vector.toList |> List.filterMap(JsonCodec.expectString)
        case _                         => Nil
    }

    // ── 見本の表を Param で書いた物 ──

    def alpha(): Param.Req[Float64] = Param.num("alpha", 0.0, 1.0) |> Param.at(1) |> Param.required
    def color(): Param.Req[String] = Param.choice("color", "black" :: "white" :: Nil) |> Param.default("black")
    def startAlpha(): Param.Opt[Float64] = Param.num("from", 0.0, 1.0)
    def time(): Param.Req[Float64] = Param.time(0.0)
    def ease(): Param.Req[Curve.Ease] = Param.ease(Curve.Ease.SmoothStep)

    def nowhere(key: String): List[YarnCommands.DocRef] = YarnCommands.DocRef.Keys("../nowhere.json", key) :: Nil
    def amb(): Param.Opt[Or[List[String]]] = Param.name("amb", nowhere("sounds")) |> Param.list |> Param.orWords("off" :: Nil)
    def volume(): Param.Opt[Or[Float64]] = Param.num("volume", 0.0, 1.0) |> Param.orNames(nowhere("volumes"))
    def who(): Param.Opt[Or[String]] = Param.name("who", Nil) |> Param.at(1) |> Param.orWords("all" :: Nil) |> Param.oneOf("target")
    def side(): Param.Opt[String] = Param.choice("at", "left" :: "center" :: "right" :: Nil) |> Param.oneOf("target")
    def strength(): Param.Req[Float64] = Param.num("strength", 0.0, 20.0) |> Param.at(1) |> Param.default(1.0)
    def device(): Param.Opt[Bool] = Param.flag("device")
    def text(): Param.Req[String] = Param.name("text", Nil) |> Param.at(1) |> Param.required
    def note(): Param.Opt[String] = Param.name("note", Nil) |> Param.at(2)

    def actor(): Param.Req[Or[String]] = Param.name("who", nowhere("cast")) |> Param.at(1) |> Param.orWords("all" :: Nil) |> Param.required
    def face(): Param.Opt[String] =
        Param.name("face", YarnCommands.DocRef.Path("../nowhere.json", "cast.*.faces[]") :: Nil) |> Param.at(2) |> Param.scopedBy("who")
    def spot(): Param.Req[(String, String)] =
        Param.marker("on", nowhere("cast.*.markers") ::: nowhere("props.*.markers")) |> Param.required
    def line(): Param.Req[String] = Param.text("line") |> Param.at(1) |> Param.required

    def overlay(): YarnCommands.Spec =
        YarnCommands.spec("overlay", "画面に被せる色の濃さを時間で変える",
            Param.erase(alpha()) :: Param.erase(color()) :: Param.erase(startAlpha()) :: Param.erase(time()) :: Param.erase(ease()) :: Nil)

    def written(): List[YarnCommands.Spec] =
        overlay() ::
        YarnCommands.spec("audio", "環境音を重ねる・音量を変える", Param.erase(amb()) :: Param.erase(volume()) :: Nil) ::
        YarnCommands.spec("hide", "立ち絵を消す", Param.erase(who()) :: Param.erase(side()) :: Nil) ::
        YarnCommands.spec("shake", "画面を揺らす", Param.erase(strength()) :: Param.erase(device()) :: Nil) ::
        YarnCommands.spec("label", "字を出す", Param.erase(text()) :: Param.erase(note()) :: Nil) ::
        YarnCommands.spec("show", "立ち絵を出す", Param.erase(actor()) :: Param.erase(face()) :: Nil) ::
        YarnCommands.spec("fx", "粒を出す", Param.erase(spot()) :: Nil) ::
        YarnCommands.spec("say", "名前の無い字を出す", Param.erase(line()) :: Nil) :: Nil

    def parsed(name: String, args: List[String]): Result[String, YarnCommands.Args] =
        written() |> List.find(s -> YarnCommands.nameOf(s) == name)
                  |> Option.toOk("見本の表に <<${name}>> が無い")
                  |> Result.flatMap(s -> YarnCommands.parse(s, commandOf(name, args)))

    // ── 見本 ──

    /// 見本の全部の行で、受けるか断るかが見本と同じ（違った行の一覧が空）。
    @Test
    def testEverySampleLineIsAcceptedOrRejectedAsWritten(): Unit \ Assert + Fs.FileRead =
        let specs = sampleSpecs() |> List.map(s -> (YarnCommands.nameOf(s), s)) |> List.toMap;
        let wrong = sampleCases() |> List.filter(match (cmd, args, ok) ->
            Map.get(cmd, specs) |> Option.map(s -> Result.isOk(YarnCommands.parse(s, commandOf(cmd, args))) != ok) |> Option.getWithDefault(true));
        Assert.assertEq(expected = Nil, wrong)

    /// 見本は 60 行より多い（読めずに 0 行で通っていない）。
    @Test
    def testSamplesAreRead(): Unit \ Assert + Fs.FileRead =
        Assert.assertTrue(List.length(sampleCases()) > 60)

    /// Param で書いた表を書き出すと、見本の commands と同じ vocab.json になる。
    @Test
    def testTableWrittenWithParamMatchesTheSamples(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = YarnCommands.toJson(sampleSpecs()), YarnCommands.toJson(written()))

    /// 書き出した表を読み戻すと同じ表になる。
    @Test
    def testTableSurvivesJson(): Unit \ Assert =
        let back = YarnCommands.fromJson(YarnCommands.toJson(written())) |> Result.map(YarnCommands.toJson);
        Assert.assertEq(expected = Ok(YarnCommands.toJson(written())), back)

    def oneParam(row: Util.Json.Json): Util.Json.Json =
        Util.Json.Json.JObject(Map#{ "bg" => Util.Json.Json.JObject(Map#{ "params" => Util.Json.Json.JArray(Vector#{ row }) }) })

    def typedRow(typeName: String): Util.Json.Json =
        Util.Json.Json.JObject(Map#{ "name" => Util.Json.Json.JString("a"), "type" => Util.Json.Json.JString(typeName) })

    /// values の無い choice と ease は表の誤り（go の検査も同じく止める）。
    @Test
    def testChoiceAndEaseWithoutValuesAreRejected(): Unit \ Assert =
        Assert.assertEq(expected = (true, true),
            (Result.isErr(YarnCommands.fromJson(oneParam(typedRow("choice")))), Result.isErr(YarnCommands.fromJson(oneParam(typedRow("ease"))))))

    /// 型に合わない既定の値は表の誤り。
    @Test
    def testDefaultOutsideTheTypeIsRejected(): Unit \ Assert =
        let row = Util.Json.Json.JObject(Map#{ "name" => Util.Json.Json.JString("a"), "type" => Util.Json.Json.JString("choice"),
            "values" => Util.Json.Json.JArray(Vector#{ Util.Json.Json.JString("x") }), "default" => Util.Json.Json.JString("y") });
        Assert.assertTrue(Result.isErr(YarnCommands.fromJson(oneParam(row))))

    /// 中身の無い {}（引数を見ないコマンド）は表の一覧に入らない。
    @Test
    def testEmptyCommandIsNotATable(): Unit \ Assert =
        let json = Util.Json.Json.JObject(Map#{ "bg" => Util.Json.Json.JObject(Map.empty()) });
        Assert.assertEq(expected = Ok(0), YarnCommands.fromJson(json) |> Result.map(List.length))

    def smallAndLarge(): YarnCommands.Spec =
        YarnCommands.spec("tick", "小さい数と大きい数の既定",
            Param.erase(Param.time(0.0001)) ::
            Param.erase(Param.num("tiny", 0.0, 0.001) |> Param.default(0.0005)) ::
            Param.erase(Param.num("huge", 0.0, 100000000.0) |> Param.default(20000000.0)) ::
            Param.erase(Param.num("steps", 0.0, 9.0) |> Param.list |> Param.default(1.0 :: 2.5 :: Nil)) :: Nil)

    /// 0.001 未満・1e7 以上の数と、並びの既定の値は、指数を使わない台本の数の形で書き、型で照らして通る。
    @Test
    def testDefaultsAreWrittenAsPlainNumbers(): Unit \ Assert =
        let text = Util.Json.toPrettyString(2, YarnCommands.toJson(smallAndLarge() :: Nil));
        Assert.assertEq(expected = (true, true, true, true, true),
            (String.contains(substr = "\"0.0001\"", text), String.contains(substr = "\"0.0005\"", text),
             String.contains(substr = "\"20000000.0\"", text), String.contains(substr = "\"1.0,2.5\"", text),
             Result.isOk(YarnCommands.fromJson(YarnCommands.toJson(smallAndLarge() :: Nil)))))

    // ── 型付きで読む ──

    /// 必須の位置の引数を数で読む。
    @Test
    def testRequiredNumberIsRead(): Unit \ Assert =
        Assert.assertEq(expected = Ok(0.5), parsed("overlay", "0.5" :: Nil) |> Result.map(Param.get(alpha())))

    /// 書いていない default の引数は既定の値。
    @Test
    def testDefaultFillsAMissingChoice(): Unit \ Assert =
        Assert.assertEq(expected = Ok("black"), parsed("overlay", "0.5" :: Nil) |> Result.map(Param.get(color())))

    /// 書いた choice はその値。
    @Test
    def testWrittenChoiceWins(): Unit \ Assert =
        Assert.assertEq(expected = Ok("white"), parsed("overlay", "0.5" :: "color=white" :: Nil) |> Result.map(Param.get(color())))

    /// 書いていない Opt の引数は None。
    @Test
    def testMissingOptionalIsNone(): Unit \ Assert =
        Assert.assertEq(expected = Ok(None), parsed("overlay", "0.5" :: Nil) |> Result.map(Param.getOpt(startAlpha())))

    /// time と ease の既定。
    @Test
    def testTimeAndEaseDefaults(): Unit \ Assert =
        Assert.assertEq(expected = Ok((0.0, Curve.Ease.SmoothStep)),
            parsed("overlay", "0.5" :: Nil) |> Result.map(a -> (Param.get(time(), a), Param.get(ease(), a))))

    /// ease の名前を曲線に読む。
    @Test
    def testEaseNameIsRead(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Curve.Ease.InOutCubic), parsed("overlay", "0.5" :: "ease=inOutCubic" :: Nil) |> Result.map(Param.get(ease())))

    /// orWords の語は Word。
    @Test
    def testOrWordIsAWord(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(Or.Word("off"))), parsed("audio", "amb=off" :: Nil) |> Result.map(Param.getOpt(amb())))

    /// , で並べた名前は Value の並び。
    @Test
    def testListIsSplitOnComma(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(Or.Value("sea" :: "wind" :: Nil))), parsed("audio", "amb=sea,wind" :: Nil) |> Result.map(Param.getOpt(amb())))

    /// orNames の数でない値は名前（Word）、数は Value。
    @Test
    def testOrNamesTellsNamesFromNumbers(): Unit \ Assert =
        Assert.assertEq(expected = (Ok(Some(Or.Word("loud"))), Ok(Some(Or.Value(0.3)))),
            (parsed("audio", "volume=loud" :: Nil) |> Result.map(Param.getOpt(volume())),
             parsed("audio", "volume=0.3" :: Nil) |> Result.map(Param.getOpt(volume()))))

    /// flag は true / false。
    @Test
    def testFlagIsRead(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(true)), parsed("shake", "device=true" :: Nil) |> Result.map(Param.getOpt(device())))

    /// "…" は外し、\" を戻した字。
    @Test
    def testQuotedTextIsUnquoted(): Unit \ Assert =
        Assert.assertEq(expected = Ok("say \"hi\""), parsed("label", "\"say \\\"hi\\\"\"" :: Nil) |> Result.map(Param.get(text())))

    /// marker は . で 1 回だけ区切った (名前, 点)。
    @Test
    def testMarkerIsReadAsNameAndPoint(): Unit \ Assert =
        Assert.assertEq(expected = Ok(("whale", "mouth")), parsed("fx", "on=whale.mouth" :: Nil) |> Result.map(Param.get(spot())))

    /// text は "…" を外した、空白を含む字。
    @Test
    def testTextKeepsSpaces(): Unit \ Assert =
        Assert.assertEq(expected = Ok("good morning, toma"), parsed("say", "\"good morning, toma\"" :: Nil) |> Result.map(Param.get(line())))

    /// scope を付けた引数は、実行時には値だけで読む（Doc で照らさない）。
    @Test
    def testScopedNameIsReadAsItsValue(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some("smile")), parsed("show", "toma" :: "smile" :: Nil) |> Result.map(Param.getOpt(face())))

    /// ほかの引数を指さない scope は表の誤り（go の検査も同じく止める）。
    @Test
    def testScopeToAnUnknownParamIsRejected(): Unit \ Assert =
        let row = Util.Json.Json.JObject(Map#{ "name" => Util.Json.Json.JString("a"), "type" => Util.Json.Json.JString("name"),
            "scope" => Util.Json.Json.JString("who") });
        Assert.assertTrue(Result.isErr(YarnCommands.fromJson(oneParam(row))))

    /// 知らない鍵には近い鍵を添える。
    @Test
    def testUnknownKeySuggestsTheNearKey(): Unit \ Assert =
        let why = match parsed("overlay", "0.5" :: "colr=white" :: Nil) {
            case Err(e) => e
            case Ok(_)  => ""
        };
        Assert.assertTrue(String.contains(substr = "もしかして: color", why))

    /// 断る理由は台本の場所で終わる。
    @Test
    def testRejectionNamesThePlace(): Unit \ Assert =
        let why = match parsed("overlay", Nil) {
            case Err(e) => e
            case Ok(_)  => ""
        };
        Assert.assertTrue(String.endsWith(suffix = "（t.yarn:1）", why))

    // ── 2 つ目の使い手: 道具・敵・店・仲間の名前を Doc から引くゲームのコマンド ──

    def doc(file: String, keys: String): List[YarnCommands.DocRef] = YarnCommands.DocRef.Keys("../" + file, keys) :: Nil

    def item(): Param.Req[String] = Param.name("item", doc("rpg.items.json", "items")) |> Param.at(1) |> Param.required
    def count(): Param.Req[Float64] = Param.num("count", 1.0, 99.0) |> Param.at(2) |> Param.required

    def gameTable(): List[YarnCommands.Spec] =
        let none = name -> YarnCommands.spec(name, name, Nil);
        YarnCommands.spec("quest", "依頼を進める", Param.erase(Param.choice("verb", "accept" :: "defeat" :: "report" :: Nil) |> Param.at(1) |> Param.required) :: Nil) ::
        YarnCommands.spec("join", "仲間に入れる", Param.erase(Param.name("member", doc("rpg.party.json", "members")) |> Param.at(1) |> Param.required) :: Nil) ::
        YarnCommands.spec("give", "道具を渡す", Param.erase(item()) :: Param.erase(count()) :: Nil) ::
        YarnCommands.spec("take", "道具を減らす", Param.erase(item()) :: Param.erase(count()) :: Nil) ::
        YarnCommands.spec("gold", "お金を足す", Param.erase(Param.num("amount", -99999.0, 99999.0) |> Param.at(1) |> Param.required) :: Nil) ::
        YarnCommands.spec("shop", "店を開く", Param.erase(Param.name("shop", YarnCommands.DocRef.Path("../rpg.shops.json", "goods[].shop") :: Nil) |> Param.at(1)) :: Nil) ::
        YarnCommands.spec("fight", "戦う", Param.erase(Param.name("foe", doc("rpg.foes.json", "foes")) |> Param.at(1) |> Param.required) ::
                                           Param.erase(Param.name("win", Nil) |> Param.at(2)) :: Nil) ::
        YarnCommands.spec("open", "物を開ける", Param.erase(Param.name("id", Nil) |> Param.at(1) |> Param.required) :: Nil) ::
        YarnCommands.spec("warp", "出口へ移る", Param.erase(Param.name("exit", Nil) |> Param.at(1) |> Param.required) :: Nil) ::
        none("inn") :: none("heal") :: none("ride") :: none("ending") :: Nil

    def gameLines(): List[(String, List[String])] =
        ("quest", "accept" :: Nil) :: ("quest", "report" :: Nil) :: ("join", "mina" :: Nil) :: ("give", "yakusou" :: "3" :: Nil) ::
        ("take", "totostaff" :: "1" :: Nil) :: ("gold", "300" :: Nil) :: ("shop", Nil) :: ("shop", "mine" :: Nil) ::
        ("fight", "mimic" :: "MimicWon" :: Nil) :: ("open", "cave_mole" :: Nil) :: ("warp", "to_surface" :: Nil) ::
        ("inn", Nil) :: ("heal", Nil) :: ("ride", Nil) :: ("ending", Nil) :: Nil

    /// 13 個のコマンドを表で書け、台本の行が全部読める（読めない行の一覧が空）。
    @Test
    def testSecondUserLinesAllParse(): Unit \ Assert =
        let table = gameTable() |> List.map(s -> (YarnCommands.nameOf(s), s)) |> List.toMap;
        let unread = gameLines() |> List.filter(match (name, args) ->
            Map.get(name, table) |> Option.map(s -> Result.isErr(YarnCommands.parse(s, commandOf(name, args)))) |> Option.getWithDefault(true));
        Assert.assertEq(expected = (13, Nil), (Map.size(table), unread))

    /// 引数を取らないコマンドに引数を書くと、取らない事を言って断る。
    @Test
    def testCommandWithoutParamsRejectsArgs(): Unit \ Assert =
        let why = gameTable() |> List.find(s -> YarnCommands.nameOf(s) == "inn")
            |> Option.toOk("inn が無い")
            |> Result.flatMap(inn -> YarnCommands.parse(inn, commandOf("inn", "tonight" :: Nil)) |> Result.map(_ -> "受けた"));
        Assert.assertEq(expected = Err("<<inn>> は引数を取らない（t.yarn:1）"), why)

    // ── Curve.Ease ──

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.000001

    /// 全部の曲線が 0 で 0・1 で 1。
    @Test
    def testEveryEaseKeepsBothEnds(): Unit \ Assert =
        let off = Curve.easeTable() |> List.filter(row -> not (near(Curve.ease(snd(row), 0.0), 0.0) and near(Curve.ease(snd(row), 1.0), 1.0))) |> List.map(fst);
        Assert.assertEq(expected = Nil, off)

    /// 真ん中の値（Linear・SmoothStep・InOut は 0.5、InQuad 0.25・OutQuad 0.75・InCubic 0.125）。
    @Test
    def testEaseMiddles(): Unit \ Assert =
        let at = e -> Float64.round(Curve.ease(e, 0.5) * 1000.0) / 1000.0;
        Assert.assertEq(expected = (0.5, 0.5, 0.25, 0.75, 0.125, 0.5, 0.5, 0.5),
            (at(Curve.Ease.Linear), at(Curve.Ease.SmoothStep), at(Curve.Ease.InQuad), at(Curve.Ease.OutQuad),
             at(Curve.Ease.InCubic), at(Curve.Ease.InOutCubic), at(Curve.Ease.InOutSine), at(Curve.Ease.InOutBounce)))

    /// Back は出だしで 0 を下回り（InBack(0.2) < 0）、終わりで 1 を超える（OutBack(0.8) > 1）。Elastic も 1 を超え、OutBounce は 1/2.75 で 1 に着き、1.5/2.75 で 0.75 まで跳ね返る。
    @Test
    def testBackOvershootsAndBounceLands(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, true, true),
            (Curve.ease(Curve.Ease.InBack, 0.2) < 0.0, Curve.ease(Curve.Ease.OutBack, 0.8) > 1.0,
             Curve.ease(Curve.Ease.OutElastic, 0.1) > 1.0, near(Curve.ease(Curve.Ease.OutBounce, 1.0 / 2.75), 1.0) and near(Curve.ease(Curve.Ease.OutBounce, 1.5 / 2.75), 0.75)))

    /// 0〜1 の外は端の値。
    @Test
    def testEaseClampsOutside(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 1.0), (Curve.ease(Curve.Ease.InCubic, -1.0), Curve.ease(Curve.Ease.InCubic, 2.0)))

    /// 名前は 26 個で重ならず、ToString は表の名前。
    @Test
    def testEaseNamesAreUnique(): Unit \ Assert =
        let names = Curve.easeTable() |> List.map(fst);
        Assert.assertEq(expected = (26, 26, "inOutCubic"), (List.length(names), Set.size(List.toSet(names)), ToString.toString(Curve.Ease.InOutCubic)))

    /// EcsTween の曲線は同じ動きの Curve.Ease に写る（0.3 で 0.3・0.09・0.51・0.18）。
    @Test
    def testEcsEasingMapsToTheSameCurve(): Unit \ Assert =
        let at = e -> Float64.round(Curve.ease(EcsTween.toEase(e), 0.3) * 1000.0) / 1000.0;
        Assert.assertEq(expected = (0.3, 0.09, 0.51, 0.18),
            (at(EcsTween.Easing.Linear), at(EcsTween.Easing.EaseIn), at(EcsTween.Easing.EaseOut), at(EcsTween.Easing.EaseInOut)))
}
