// JSON とコードの橋渡しだけをテストする: コードが名前で引く物（写真・音・言葉の鍵・語彙）が Doc と素材の側に揃っているか。
mod TestDocs {

    use fge::{DocJson, JsonCodec, ProjectLoader, Yarn}

    /// project.json の配列 key の各要素の name。
    def namesIn(key: String): Set[String] \ Fs.FileRead =
        DocJson.readJson("project.json") |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(root -> Map.get(key, root))
            |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(obj -> JsonCodec.stringOr("name", "", obj))))
            |> Option.getWithDefault(Nil) |> List.toSet

    /// シナリオの <<audio channel 音>> の音の名前（off は入れない）。
    def audioSounds(channel: String, program: Yarn.Program): List[String] =
        def walk(body: List[Yarn.Statement]): List[Yarn.Command] = body |> List.flatMap(statement -> match statement {
            case Yarn.Statement.Command(c)      => c :: Nil
            case Yarn.Statement.Choose(cs)      => cs |> List.flatMap(choice -> walk(choice#body))
            case Yarn.Statement.If(branches, _) => branches |> List.flatMap(b -> walk(b#body))
            case _                              => Nil
        });
        Yarn.nodeNames(program) |> List.filterMap(n -> Yarn.nodeOf(n, program)) |> List.flatMap(node -> walk(node#body))
            |> List.filter(c -> c#name == "audio" and List.head(c#args) == Some(channel))
            |> List.filterMap(c -> List.nth(1, c#args)) |> List.filter(n -> n != "off")

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
        // 返事の音・シナリオの <<audio se>> と <<audio ambience>>・タイトルの環境音は、どれも project.json の sounds にある。
        let res = TestKit.res();
        let sounds = namesIn("sounds");
        let replies = World.Event.Paged :: World.Event.Revealed :: World.Event.Moved :: World.Event.Picked ::
                      World.Event.Opened :: World.Event.Closed :: World.Event.Saved :: World.Event.Loaded :: World.Event.Rolled :: Nil;
        let ses = audioSounds("se", res#dialogue) |> List.map(World.Event.Cue);
        let played = List.append(replies, ses) |> List.filterMap(Controls.soundOf);
        let ambiences = StoryDoc.rec(res#story)#titleAmbience :: audioSounds("ambience", res#dialogue);
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
    def testEveryVariableHasALabel(): Unit \ {Assert, Fs.FileRead} =
        // シナリオの変数は、どれも novel.story.json の vars に表示名がある（$ 付きの名前のまま出る物が無い）。
        let res = TestKit.res();
        let unnamed = Yarn.variablesOf(res#dialogue) |> List.map(fst)
            |> List.filter(name -> StoryDoc.varLabelOf(name, res#story) == name);
        Assert.assertEq(expected = Nil, unnamed)

    @Test
    def testVocabFileMatchesTalk(): Unit \ {Assert, Fs.FileRead} =
        // build の check が読む assets/talk/vocab.json は、Talk.vocabJson を書いた物と同じ（make talk-vocab で書き直す）。
        let onDisk = Fs.FileRead.read(Talk.vocabPath()) |> Result.toOption |> Option.map(String.trim);
        Assert.assertEq(expected = Some(String.trim(Talk.vocabJson())), onDisk)


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
        // 横の位置と縦の位置は、同じ名前の集まり（シナリオの <<show 名前 at=位置>> は向きを知らずに書く）。
        let d = CastDoc.rec(CastDoc.load(CastDoc.path()));
        Assert.assertEq(expected = Map.keysOf(d#slots), Map.keysOf(d#portraitSlots))

    @Test
    def testCastAndPropNamesNeverOverlap(): Unit \ {Assert, Fs.FileRead} =
        // 人物と小物の名前は重ならない（<<show 名前>> は cast を先に引くので、重なった小物は出せない）。
        let d = CastDoc.rec(CastDoc.load(CastDoc.path()));
        Assert.assertEq(expected = Set.empty(), Set.intersection(Map.keysOf(d#cast), Map.keysOf(d#props)))

    @Test
    def testCastDocFallsOpen(): Unit \ {Assert, Fs.FileRead} =
        // 無い・壊れた novel.cast.json は既定値（人物なし・既定の位置）で読み、1 欄だけ書いた Doc はその欄だけが入る。
        let shape = (doc: CastDoc.Doc) -> { let d = CastDoc.rec(doc); (d#fadeSeconds, Map.keysOf(d#slots), Map.size(d#cast)) };
        let missing = shape(CastDoc.load("assets/no-such.cast.json"));
        let broken = CastDoc.fromJson("{ broken") |> Option.map(shape);
        let one = CastDoc.fromJson("{ \"fadeSeconds\": 1.0 }") |> Option.map(shape);
        let d = shape(CastDoc.defaults());
        Assert.assertEq(expected = (d, None, Some((1.0, Map.keysOf(CastDoc.rec(CastDoc.defaults())#slots), 0))), (missing, broken, one))


    // ══ 描き出しの場面（novel.shots.json） ══

    @Test
    def testShotsDocSkipsOnlyTheUnreadableShots(): Unit \ Assert =
        // 知らない画面・知らない until・say と until の両方・名前の無い場面・型の違う say・秒の無い場面・同じ名前の 2 つ目は
        // 飛ばし（理由の頭の語つき）、読める場面は並びのまま残す。vars の数と真偽は字にして受ける。
        let text = "{ \"version\": 1, \"shots\": [" +
                   " { \"name\": \"a\", \"node\": \"Station\", \"say\": 1, \"at\": 1.0 }," +
                   " { \"name\": \"b\", \"open\": \"gallery\", \"at\": 1.0 }," +
                   " { \"name\": \"c\", \"until\": \"end\", \"at\": 1.0 }," +
                   " { \"name\": \"d\", \"say\": 1, \"until\": \"choices\", \"at\": 1.0 }," +
                   " { \"node\": \"Station\", \"at\": 1.0 }," +
                   " { \"name\": \"f\", \"node\": \"Station\", \"say\": \"2\", \"at\": 1.0 }," +
                   " { \"name\": \"g\", \"open\": \"title\" }," +
                   " { \"name\": \"e\", \"open\": \"log\", \"pointer\": [1.0, 2.0], \"vars\": { \"closeness\": 2, \"stayed\": true }, \"at\": 1.0 }," +
                   " { \"name\": \"a\", \"open\": \"title\", \"at\": 1.0 } ] }";
        let named = r -> match r {
            case Ok(shot)             => "ok ${shot#name} ${Map.toList(shot#vars)}"
            case Err((which, reason)) => "skip ${which} " + (String.splitOn(substr = " ", reason) |> List.head |> Option.getWithDefault(""))
        };
        Assert.assertEq(expected = Some("ok a Nil" :: "skip b open" :: "skip c until" :: "skip d say" :: "skip shots[4] name" :: "skip f say"
                                        :: "skip g at（時計を据える秒の数）が無い" :: "ok e (closeness, 2.0) :: (stayed, true) :: Nil" :: "skip a 同じ名前の場面が前にある" :: Nil),
                        ShotsDoc.rowsOf(text) |> Option.map(List.map(named)))

    @Test
    def testShotNotInTheDocBuildsNothing(): Unit \ {Assert, Fs.FileRead} =
        // novel.shots.json に無い名前の場面は組まない（描き出しは名前の誤りとして断る）。
        Assert.assertEq(expected = true, Option.isEmpty(Shots.worldOf("nvll", TestKit.res())))

    @Test
    def testShotNamesDoNotOverlapRenderOnlyNames(): Unit \ {Assert, Fs.FileRead} =
        // Doc の場面の名前は、描き出しだけの名前（menu・saveload・tooltip・cast・small-*・portrait-* など）と重ならない。
        let doc = Shots.names(TestKit.res()) |> List.toSet;
        Assert.assertEq(expected = Nil, SceneRender.renderOnlyNames() |> List.filter(name -> Set.memberOf(name, doc)))
}
