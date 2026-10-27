// JSON とコードの橋渡しだけをテストする: コードが名前で引く物（写真・音・言葉の鍵・語彙）が Doc と素材の側に揃っているか。
mod TestDocs {

    use fge::{DocJson, JsonCodec, Yarn}

    /// project.json の配列 key の各要素の name。
    def namesIn(key: String): Set[String] \ Fs.FileRead =
        DocJson.readJson("project.json") |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(root -> Map.get(key, root))
            |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(obj -> JsonCodec.stringOr("name", "", obj))))
            |> Option.getWithDefault(Nil) |> List.toSet

    def commandArgs(name: String, program: Yarn.Program): List[String] =
        def walk(body: List[Yarn.Statement]): List[Yarn.Command] = body |> List.flatMap(statement -> match statement {
            case Yarn.Statement.Command(c)      => c :: Nil
            case Yarn.Statement.Choose(cs)      => cs |> List.flatMap(choice -> walk(choice#body))
            case Yarn.Statement.If(branches, _) => branches |> List.flatMap(b -> walk(b#body))
            case _                              => Nil
        });
        Yarn.nodeNames(program) |> List.filterMap(n -> Yarn.nodeOf(n, program)) |> List.flatMap(node -> walk(node#body))
            |> List.filter(c -> c#name == name) |> List.filterMap(c -> List.head(c#args))

    @Test
    def testEveryPhotoHasATexture(): Unit \ {Assert, Fs.FileRead} =
        // novel.backdrops.json の写真は、どれも project.json の textures に名前がある（描き出しと実機が同じ名前で読む）。
        let textures = namesIn("textures");
        let w = TestKit.w0();
        let missing = BackdropDoc.rec(w#backdrops)#photos |> Map.valuesOf |> List.map(photo -> photo#texture)
            |> List.filter(t -> not Set.memberOf(t, textures));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testEverySoundTheGameCanPlayIsRegistered(): Unit \ {Assert, Fs.FileRead} =
        // 返事の音・台本の <<se>> と <<ambience>>・タイトルの環境音は、どれも project.json の sounds にある。
        let sounds = namesIn("sounds");
        let w = TestKit.w0();
        let replies = World.Event.Paged :: World.Event.Revealed :: World.Event.Moved :: World.Event.Picked ::
                      World.Event.Opened :: World.Event.Closed :: World.Event.Saved :: World.Event.Loaded :: World.Event.Rolled :: Nil;
        let ses = commandArgs("se", w#dialogue) |> List.map(n -> World.Event.Cue("se_${n}"));
        let played = List.append(replies, ses) |> List.filterMap(Controls.soundOf);
        let ambiences = (StoryDoc.rec(w#story)#titleAmbience :: commandArgs("ambience", w#dialogue))
            |> List.filter(n -> n != "off") |> List.map(n -> "amb_${n}");
        let missing = List.append(played, ambiences) |> List.filter(n -> not Set.memberOf(n, sounds)) |> List.distinct;
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testStoryDocHasEveryLabel(): Unit \ {Assert, Fs.FileRead} =
        // novel.story.json に、画面に出す言葉の鍵が全部ある（無ければ既定の言葉で出るが、Doc で直せない言葉が残る）。
        let w = TestKit.w0();
        let missing = StoryDoc.labels() |> List.map(StoryDoc.labelKey)
            |> List.filter(key -> not Map.memberOf(key, StoryDoc.rec(w#story)#labels));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testEverySpeakerHasAName(): Unit \ {Assert, Fs.FileRead} =
        // 話し手の id（Talk.Speaker）は、どれも novel.story.json の names に呼び名がある。
        let w = TestKit.w0();
        let missing = Talk.speakers() |> List.map(Talk.speakerId)
            |> List.filter(id -> not Map.memberOf(id, StoryDoc.rec(w#story)#names));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testVocabFileMatchesTalk(): Unit \ {Assert, Fs.FileRead} =
        // build の check が読む assets/talk/vocab.json は、コードの語彙（Talk.vocabOf）を書いた物と同じ（make talk-vocab で書き直す）。
        let onDisk = Fs.FileRead.read(Talk.vocabPath()) |> Result.toOption |> Option.map(String.trim);
        Assert.assertEq(expected = Some(String.trim(Yarn.vocabJson(Talk.vocabOf()))), onDisk)

    @Test
    def testOpeningNodeExists(): Unit \ {Assert, Fs.FileRead} =
        // コードが開くノードが、build したシナリオにある。
        let w = TestKit.w0();
        Assert.assertEq(expected = true, Option.nonEmpty(Yarn.nodeOf(Talk.nodeName(Talk.Node.Opening), w#dialogue)))
}
