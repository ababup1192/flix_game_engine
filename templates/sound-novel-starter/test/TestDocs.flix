// JSON とコードの橋渡しだけをテストする: コードが名前で引く物（写真・音・言葉の鍵・語彙）が Doc と素材の側に揃っているか。
mod TestDocs {

    use fge::{DocJson, JsonCodec, ProjectLoader, Yarn}

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
    def testProjectJsonLoads(): Unit \ {Assert, Fs.FileRead} =
        // project.json は実機の起動と同じ読み手で読める（欠けた欄があるとウィンドウが開く前に止まる）。
        let loaded = ProjectLoader.loadProject(".") |> Result.map(_ -> ());
        Assert.assertEq(expected = Ok(()), loaded)

    @Test
    def testProjectJsonHasPortraitDesign(): Unit \ {Assert, Fs.FileRead} =
        // project.json は縦の design の決め方（web.portraitDesign）を持つ（縦に持って開くと縦の画面で起動する）。
        let spec = ProjectLoader.loadProject(".") |> Result.toOption |> Option.flatMap(p -> p#portraitDesign)
            |> Option.map(s -> (s#width, s#minHeight));
        Assert.assertEq(expected = Some((540, 960)), spec)

    @Test
    def testPortraitDocMatchesCodeDefaults(): Unit \ {Assert, Fs.FileRead} =
        // novel.portrait.json は読めて、コードの既定値と同じ値から出発している。
        let read = DocJson.readJson(PortraitDoc.path()) |> Result.toOption |> Option.map(_ -> PortraitDoc.rec(PortraitDoc.load(PortraitDoc.path())));
        let d = PortraitDoc.rec(PortraitDoc.defaults());
        let shape = (r: PortraitDoc.Rec) -> (r#bodySize, r#pageBottom, r#choiceHeight, r#settingRowHeight, r#tabHeight, r#backHeight);
        Assert.assertEq(expected = Some(shape(d)), read |> Option.map(shape))

    /// RailDoc の値の全部（record は比べられないので組にする）。
    def railShape(r: RailDoc.Rec): ((RailDoc.Anchor, Float64, Float64, Float64, Float64), (Float64, Float64, Float64, Float64, Float64, Float64)) =
        ((r#anchor, r#iconSize, r#buttonHeight, r#railRight, r#moreTop),
         (r#moreSize, r#moreHeight, r#longPressSeconds, r#tooltipTextSize, r#saveLoadItemWidth, r#menuWidth))

    @Test
    def testRailDocMatchesCodeDefaults(): Unit \ {Assert, Fs.FileRead} =
        // novel.rail.json は読めて、コードの既定値と同じ値から出発している。
        let read = DocJson.readJson(RailDoc.path()) |> Result.toOption |> Option.map(_ -> railShape(RailDoc.rec(RailDoc.load(RailDoc.path()))));
        Assert.assertEq(expected = Some(railShape(RailDoc.rec(RailDoc.defaults()))), read)

    @Test
    def testRailDocFallsOpenAndReachesPortrait(): Unit \ {Assert, Fs.FileRead} =
        // 無い・壊れた novel.rail.json は既定値で読み、読めた値は縦の画面の Doc の rail 欄に届く（積み方と余白・長押しの秒）。
        let missing = railShape(RailDoc.rec(RailDoc.load("assets/no-such.rail.json")));
        let broken = RailDoc.fromJson("{ broken") |> Option.map(d -> railShape(RailDoc.rec(d)));
        let read = RailDoc.fromJson("{ \"anchor\": \"bottom\", \"railBottom\": 50, \"longPressSeconds\": 0.7 }") |> Option.getWithDefault(RailDoc.defaults());
        let rail = PortraitDoc.rec(PortraitDoc.withRail(read, PortraitDoc.defaults()))#rail;
        Assert.assertEq(expected = (railShape(RailDoc.rec(RailDoc.defaults())), None, RailDoc.Anchor.Bottom(50.0), 0.7),
                        (missing, broken, rail#anchor, rail#longPressSeconds))

    @Test
    def testEveryPhotoHasATexture(): Unit \ {Assert, Fs.FileRead} =
        // novel.backdrops.json の写真は、どれも project.json の textures に名前がある（描き出しと実機が同じ名前で読む）。
        let res = TestKit.res();
        let textures = namesIn("textures");
        let missing = BackdropDoc.rec(res#backdrops)#photos |> Map.valuesOf |> List.map(photo -> photo#texture)
            |> List.filter(t -> not Set.memberOf(t, textures));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testEverySoundTheGameCanPlayIsRegistered(): Unit \ {Assert, Fs.FileRead} =
        // 返事の音・台本の <<se>> と <<ambience>>・タイトルの環境音は、どれも project.json の sounds にある。
        let res = TestKit.res();
        let sounds = namesIn("sounds");
        let replies = World.Event.Paged :: World.Event.Revealed :: World.Event.Moved :: World.Event.Picked ::
                      World.Event.Opened :: World.Event.Closed :: World.Event.Saved :: World.Event.Loaded :: World.Event.Rolled :: Nil;
        let ses = commandArgs("se", res#dialogue) |> List.map(n -> World.Event.Cue("se_${n}"));
        let played = List.append(replies, ses) |> List.filterMap(Controls.soundOf);
        let ambiences = (StoryDoc.rec(res#story)#titleAmbience :: commandArgs("ambience", res#dialogue))
            |> List.filter(n -> n != "off") |> List.map(n -> "amb_${n}");
        let missing = List.append(played, ambiences) |> List.filter(n -> not Set.memberOf(n, sounds)) |> List.distinct;
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testStoryDocHasEveryLabel(): Unit \ {Assert, Fs.FileRead} =
        // novel.story.json に、画面に出す言葉の鍵が全部ある（無ければ既定の言葉で出るが、Doc で直せない言葉が残る）。
        let res = TestKit.res();
        let missing = StoryDoc.labels() |> List.map(StoryDoc.labelKey)
            |> List.filter(key -> not Map.memberOf(key, StoryDoc.rec(res#story)#labels));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testEverySpeakerHasAName(): Unit \ {Assert, Fs.FileRead} =
        // 話し手の id（Talk.Speaker）は、どれも novel.story.json の names に呼び名がある。
        let res = TestKit.res();
        let missing = Talk.speakers() |> List.map(Talk.speakerId)
            |> List.filter(id -> not Map.memberOf(id, StoryDoc.rec(res#story)#names));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testVocabFileMatchesTalk(): Unit \ {Assert, Fs.FileRead} =
        // build の check が読む assets/talk/vocab.json は、コードの語彙（Talk.vocabOf）を書いた物と同じ（make talk-vocab で書き直す）。
        let onDisk = Fs.FileRead.read(Talk.vocabPath()) |> Result.toOption |> Option.map(String.trim);
        Assert.assertEq(expected = Some(String.trim(Yarn.vocabJson(Talk.vocabOf()))), onDisk)

    @Test
    def testOpeningNodeExists(): Unit \ {Assert, Fs.FileRead} =
        // コードが開くノードが、build したシナリオにある。
        let res = TestKit.res();
        Assert.assertEq(expected = true, Option.nonEmpty(Yarn.nodeOf(Talk.nodeName(Talk.Node.Opening), res#dialogue)))


    // ══ 立ち絵と小物（novel.cast.json） ══

    /// Doc の人物と小物の、全部の表情から導いたテクスチャの名前。
    def castTextures(doc: CastDoc.Doc): List[String] =
        let d = CastDoc.rec(doc);
        List.append(Map.toList(d#cast), Map.toList(d#props))
            |> List.flatMap(match (name, entry) -> entry#faces |> List.map(face -> CastDoc.textureOf(name, face)))

    @Test
    def testEveryCastFaceHasATexture(): Unit \ {Assert, Fs.FileRead} =
        // novel.cast.json と描き出しの見本（CastDoc.sample）の、全部の人物と小物の表情は、
        // 導いた名前「cast_<名前>_<表情>」で project.json の textures にある（無ければ絵が出ない）。
        let textures = namesIn("textures");
        let missing = List.append(castTextures(CastDoc.load(CastDoc.path())), castTextures(CastDoc.sample()))
            |> List.filter(t -> not Set.memberOf(t, textures));
        Assert.assertEq(expected = Nil, missing)

    @Test
    def testCastSlotsMatchInBothOrientations(): Unit \ {Assert, Fs.FileRead} =
        // 横の位置と縦の位置は、同じ名前の集まり（シナリオの <<char 名前 位置>> は向きを知らずに書く）。
        let d = CastDoc.rec(CastDoc.load(CastDoc.path()));
        Assert.assertEq(expected = Map.keysOf(d#slots), Map.keysOf(d#portraitSlots))

    @Test
    def testFaceNamesNeverShadowSlotNames(): Unit \ {Assert, Fs.FileRead} =
        // 表情の名前と位置の名前は重ならない（コマンドの語は位置の名前を先に読むので、重なった表情は選べない）。
        let d = CastDoc.rec(CastDoc.load(CastDoc.path()));
        let faces = List.append(Map.valuesOf(d#cast), Map.valuesOf(d#props)) |> List.flatMap(e -> e#faces);
        Assert.assertEq(expected = Nil, faces |> List.filter(f -> Map.memberOf(f, d#slots)))

    @Test
    def testCastDocFallsOpen(): Unit \ {Assert, Fs.FileRead} =
        // 無い・壊れた novel.cast.json は既定値（人物なし・既定の位置）で読み、1 欄だけ書いた Doc はその欄だけが入る。
        let shape = (doc: CastDoc.Doc) -> { let d = CastDoc.rec(doc); (d#fadeSeconds, Map.keysOf(d#slots), Map.size(d#cast)) };
        let missing = shape(CastDoc.load("assets/no-such.cast.json"));
        let broken = CastDoc.fromJson("{ broken") |> Option.map(shape);
        let one = CastDoc.fromJson("{ \"fadeSeconds\": 1.0 }") |> Option.map(shape);
        let d = shape(CastDoc.defaults());
        Assert.assertEq(expected = (d, None, Some((1.0, Map.keysOf(CastDoc.rec(CastDoc.defaults())#slots), 0))), (missing, broken, one))
}
