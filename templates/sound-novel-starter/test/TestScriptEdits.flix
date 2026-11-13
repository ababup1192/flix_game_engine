// テープの頁の「ここから遊ぶ」が渡す始まりの行とシナリオの直し（Starts の talk・ScriptEdits）。
// シナリオは小さな見本（下の program）。行の番号は t.yarn の行。
mod TestScriptEdits {

    use fge::{App, Render, Resources, Yarn}

    type alias AppState = Resources.With[Res.Res, World.World]

    /// 見本のシナリオ（t.yarn・ノード Station）。
    ///   10 地の文「こいつを持っていきな」 11 地の文「二つ目の行」 12 <<se slap>>
    ///   13 <<if>> の中に 14「枝の中の行」 15 選択肢 16「選ぶ」→ 17「選んだ後」 18「最後」
    def programText(): String =
        "{\"version\": 3, \"files\": [\"t.yarn\"], \"variables\": [], \"nodes\": [{\"title\": \"Station\", \"file\": \"t.yarn\", \"line\": 8, \"headers\": [], \"body\": [" +
        "{\"kind\": \"line\", \"line\": 10, \"text\": \"こいつを持っていきな\"}," +
        "{\"kind\": \"line\", \"line\": 11, \"text\": \"二つ目の行\"}," +
        "{\"kind\": \"command\", \"line\": 12, \"name\": \"se\", \"args\": [\"slap\"]}," +
        "{\"kind\": \"if\", \"line\": 13, \"clauses\": [{\"body\": [{\"kind\": \"line\", \"line\": 14, \"text\": \"枝の中の行\"}]}]}," +
        "{\"kind\": \"options\", \"line\": 15, \"options\": [{\"line\": 16, \"text\": \"選ぶ\", \"body\": [{\"kind\": \"line\", \"line\": 17, \"text\": \"選んだ後\"}]}]}," +
        "{\"kind\": \"line\", \"line\": 18, \"text\": \"最後\"}]}]}"

    def res(): Res.Res \ Fs.FileRead =
        let program = Yarn.fromJson(programText()) |> Option.getWithDefault(Yarn.empty());
        Res.withDialogue(program, TestKit.res())

    /// talk の始まりを引数で組む（組めなければ止める）。
    // WhyNot: App.startOrBug を通さない — 始まりの前に Doc とシナリオを読み直すので、見本のシナリオが本物に戻る。
    def started(args: Map[String, String]): AppState \ Fs.FileRead =
        let r = res();
        let fresh = Resources.of(r, TestKit.w0(r));
        let built = Starts.all() |> List.find(s -> s#name == "talk") |> Option.toOk("talk の始まりが無い")
            |> Result.flatMap(talk -> talk#build(fresh, Map.insert("talk", "Station", args)));
        match built {
            case Ok(h)    => h
            case Err(why) => bug!(why)
        }

    def lineOf(h: AppState): String = World.talkLineOf(h#world)

    def textOf(h: AppState): String = World.pageOf(h#world)#current |> Option.map(line -> line#text) |> Option.getWithDefault("")

    def hash(text: String): String = ScriptEdits.fnv1a(text)

    // ── FNV-1a ──

    @Test
    def testFnv1aMatchesThePageAndGo(): Unit \ Assert =
        // 頁の fnv1a と Go のテストに置いた組と同じ値。
        Assert.assertEq(expected = "e05227c0", ScriptEdits.fnv1a("こいつを持っていきな"))

    @Test
    def testFnv1aOfEmptyTextIsTheOffsetBasis(): Unit \ Assert =
        // 空の字は FNV-1a の初めの値のまま（Go の page_test の fnvPairs と同じ組）。
        Assert.assertEq(expected = "811c9dc5", ScriptEdits.fnv1a(""))

    @Test
    def testFnv1aOfAscii(): Unit \ Assert =
        // ASCII の字（Go の page_test の fnvPairs と同じ組）。
        Assert.assertEq(expected = "1a47e90b", ScriptEdits.fnv1a("abc"))

    @Test
    def testFnv1aOfTextWithLineBreakMark(): Unit \ Assert =
        // 「／」（行の折り返し）入りの台詞（Go の page_test の fnvPairs と同じ組）。
        Assert.assertEq(expected = "db27e017", ScriptEdits.fnv1a("今夜は風が強い。／船は来るだろうか"))

    // ── 始める行 ──

    @Test
    def testAtPointingAtACommandStartsFromThatCommand(): Unit \ {Assert, Fs.FileRead} =
        // at が演出コマンドの字（<<se slap>>）と合えば、その行から進めて次の台詞（<<if>> の中の 14）を出す。ノードの頭へは戻らない。
        let h = started(Map#{ "line" => "12", "at" => hash("<<se slap>>") });
        Assert.assertEq(expected = "t.yarn:14", lineOf(h))

    @Test
    def testCursorPointsAtTheFirstChoiceWhileChoosing(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出している間、シナリオの位置（talkCursor）は最初の選択肢の行。
        let h = started(Map#{ "line" => "14", "at" => hash("枝の中の行") });
        let r = h#resources;
        let asking = TestKit.advance(r, TestKit.settle(r, h#world));
        Assert.assertEq(expected = "t.yarn:16", World.talkCursorOf(asking))

    @Test
    def testLineAndMatchingAtStartThere(): Unit \ {Assert, Fs.FileRead} =
        // line の今の文のハッシュが at と合えば、その行から。
        let h = started(Map#{ "line" => "11", "at" => hash("二つ目の行") });
        Assert.assertEq(expected = "t.yarn:11", lineOf(h))

    @Test
    def testWrongAtFindsTheSameTextElsewhere(): Unit \ {Assert, Fs.FileRead} =
        // line の文が at と合わなければ、同じ文の行をノードの中で探す。
        let h = started(Map#{ "line" => "10", "at" => hash("二つ目の行") });
        Assert.assertEq(expected = "t.yarn:11", lineOf(h))

    @Test
    def testUnknownAtStartsAtTheNodeHead(): Unit \ {Assert, Fs.FileRead} =
        // どの行の文とも合わなければノードの頭から。
        let h = started(Map#{ "line" => "11", "at" => hash("シナリオから消えた文") });
        Assert.assertEq(expected = "t.yarn:10", lineOf(h))

    @Test
    def testTalkIsReadAsTheNodeName(): Unit \ {Assert, Fs.FileRead} =
        // 引数 talk は node の別名（URL の ?talk=Station）。
        Assert.assertEq(expected = "Station", World.talkNodeOf(started(Map.empty())#world))

    // ── シナリオの直し ──

    def edited(line: String, after: String, was: String): Map[String, String] =
        Map#{ "line" => line, "at" => hash("二つ目の行"), "edit.${line}" => after, "was.${line}" => was }

    @Test
    def testEditReplacesTheLineWhenWasMatches(): Unit \ {Assert, Fs.FileRead} =
        // was が今の文のハッシュに合う行は、後の文で出る。
        let h = started(edited("11", "直した二つ目", hash("二つ目の行")));
        Assert.assertEq(expected = "直した二つ目", textOf(h))

    @Test
    def testEditIsSkippedWhenWasDiffers(): Unit \ {Assert, Fs.FileRead} =
        // was が合わない行は当てず、元の文のまま。
        let h = started(edited("11", "直した二つ目", hash("前に書いてあった文")));
        Assert.assertEq(expected = "二つ目の行", textOf(h))

    @Test
    def testSkippedEditIsCounted(): Unit \ {Assert, Fs.FileRead} =
        // 当てなかった行の数をバナーで言う。
        let h = started(edited("11", "直した二つ目", hash("前に書いてあった文")));
        Assert.assertEq(expected = 1, h#resources#scriptEdits#skipped)

    @Test
    def testEditInsideIfBranchIsReplaced(): Unit \ {Assert, Fs.FileRead} =
        // <<if>> の中の行も、行の番号で引いて替わる。
        let h = started(Map.insert("edit.14", "直した枝", Map.insert("was.14", hash("枝の中の行"), edited("11", "二つ目の行", hash("二つ目の行")))));
        let r = h#resources;
        let next = TestKit.advance(r, TestKit.settle(r, h#world));
        Assert.assertEq(expected = "直した枝", textOf(Resources.of(r, next)))

    @Test
    def testEditOfChoiceAndItsBodyIsReplaced(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢の字と、選んだ後の行も替わる。
        let args = Map#{ "line" => "14", "at" => hash("枝の中の行"),
                         "edit.16" => "直した選択肢", "was.16" => hash("選ぶ"), "edit.17" => "直した選んだ後", "was.17" => hash("選んだ後") };
        let h = started(args);
        let r = h#resources;
        let asking = TestKit.advance(r, TestKit.settle(r, h#world));
        let options = World.choicesOf(asking) |> List.map(option -> option#line#text);
        let picked = TestKit.settle(r, TestKit.pick(r, 0, TestKit.settle(r, asking)));
        Assert.assertEq(expected = ("直した選択肢" :: Nil, "直した選んだ後"), (options, textOf(Resources.of(r, picked))))

    @Test
    def testEditedStartShowsTheBanner(): Unit \ {Assert, Fs.FileRead, IO} =
        // edit.* で開いた時は、前の文が合わなくても scriptEdited の言葉のバナーを出す。
        let h = started(edited("11", "直した二つ目", hash("前に書いてあった文")));
        let ctx = App.viewCtxOf(SceneRender.cfgOf("debug", Map.empty())#fontAtlas, SceneRender.design());
        let texts = View.hud(ctx, h#resources, h#world) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Text(t) => Some(t#text)
            case _                   => None
        });
        let shown = StoryDoc.labelOf(StoryDoc.Label.ScriptEdited, h#resources#story);
        Assert.assertTrue(texts |> List.exists(String.startsWith({prefix = shown})))

    @Test
    def testPlainStartShowsNoBanner(): Unit \ {Assert, Fs.FileRead} =
        // 直しの無い始まりはバナーを出さない。
        Assert.assertFalse(started(Map#{ "line" => "11" })#resources#scriptEdits#edited)
}
