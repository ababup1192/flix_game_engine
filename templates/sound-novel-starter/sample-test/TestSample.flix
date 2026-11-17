// 作例（雪どけを待たない便り）そのものを確かめるテスト: 作例の筋・作例の Doc の値・描き出しの見本の絵・テストが読む写しが作例と同じか。
// test/ の外に置き、engine の templates/ の下で流す時だけ bin/with-sample-tests が test/ へ貼る（make test・engine の test-all）。
// ゲームでは流れない（ゲームは台本と Doc を書き換えるので、ここは作例の時だけ意味がある）。make new-game は new-game.exclude を読んで消す。
// テンプレートの規則のテストは test/ の直下で、作例の写し（test/fixtures/sample）を読む。
mod TestSample {

    use fge::{DocJson, ProjectLoader}
    use TestKit.{begun, readTo}

    /// 写しを持つ作例のファイル（ゲームの直下からの場所）。
    /// WhyNot: dialogue.json は比べない — 写しの木は写しの .yarn から --no-vocab で組む（ゲームの語彙と Doc で検査させない）ので、
    /// 中の .yarn の場所と vocab の欄が違う。木が .yarn と合うかはコミットの門の yarn check が見る。
    def copiedFiles(): List[String] =
        StoryDoc.path() :: KindDoc.path() :: ThemeDoc.path() :: BackdropDoc.path() :: CreditsDoc.path() :: KeysDoc.path() ::
        SmallScreenDoc.path() :: PortraitDoc.path() :: RailDoc.path() :: CastDoc.path() :: ShotsDoc.path() :: Controls.mixerPath() ::
        EffectsDoc.path() :: PromptsDoc.path() :: "assets/talk/yukidoke.yarn" :: Nil

    @Test
    def testFixtureIsACopyOfTheSample(): Unit \ {Assert, Fs.FileRead} =
        // test/fixtures/sample の Doc と台本は、作例の assets と同じ中身
        // （作例を直したら cp assets/… test/fixtures/sample/assets/… で写し、bin/fge yarn build test/fixtures/sample/assets/talk --no-vocab）。
        let differs = copiedFiles() |> List.filter(path ->
            Fs.FileRead.read(path) |> Result.toOption != (Fs.FileRead.read("${TestKit.sampleRoot()}/${path}") |> Result.toOption));
        Assert.assertEq(expected = Nil, differs)

    // ══ 作例の筋 ══

    @Test
    def testTellingYourPaceSetsOwnPace(): Unit \ {Assert, Fs.FileRead} =
        // 最初の手紙の選択肢: 坂をゆっくり上がると添える（1 つ目）と、枝を読み終えた所で $own_pace が立ち、2 つ目では立たない。
        let res = TestKit.res();
        let asking = TestKit.readUntil(res, World.isChoosing, Nil, begun(res));
        let ownPace = i -> World.variableOf("$own_pace", readTo(res, "StudioWindow", i :: Nil, asking));
        Assert.assertEq(expected = ("True", "False"), (ownPace(0), ownPace(1)))

    @Test
    def testSlowLettersNeedsBothHonestLetters(): Unit \ {Assert, Fs.FileRead} =
        // 2 通の手紙で歩調と休む日を伝えると、誘いで春からの手紙を選べ、期限を決めない文通の結末に着く。
        let res = TestKit.res();
        let ending = readTo(res, "SlowLetters", 0 :: 0 :: 0 :: Nil, begun(res));
        Assert.assertEq(expected = ("SlowLetters", "True", "True"),
                        (World.talkNodeOf(ending), World.variableOf("$own_pace", ending), World.variableOf("$shared_tiredness", ending)))

    @Test
    def testDecliningKeepsTheMap(): Unit \ {Assert, Fs.FileRead} =
        // 手紙で歩調も休む日も伝えず、誘いを断ると（選べるのは 2 つ目と 3 つ目）、地図をしまう結末に着き、どちらの変数も立たない。
        let res = TestKit.res();
        let ending = readTo(res, "KeptMap", 1 :: 1 :: 2 :: Nil, begun(res));
        Assert.assertEq(expected = ("KeptMap", "False", "False"),
                        (World.talkNodeOf(ending), World.variableOf("$own_pace", ending), World.variableOf("$shared_tiredness", ending)))

    // ══ 作例の Doc の値 ══

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

    @Test
    def testRailDocMatchesCodeDefaults(): Unit \ {Assert, Fs.FileRead} =
        // novel.rail.json は読めて、コードの既定値と同じ値から出発している。
        let read = DocJson.readJson(RailDoc.path()) |> Result.toOption |> Option.map(_ -> TestDocs.railShape(RailDoc.rec(RailDoc.load(RailDoc.path()))));
        Assert.assertEq(expected = Some(TestDocs.railShape(RailDoc.rec(RailDoc.defaults()))), read)

    @Test
    def testRenderSampleCastHasTextures(): Unit \ {Assert, Fs.FileRead} =
        // 描き出しの見本（CastDoc.sample）の表情は、どれも project.json の textures にある（無ければ cast の場面に絵が出ない）。
        let textures = TestDocs.namesIn("textures");
        Assert.assertEq(expected = Nil, TestDocs.castTextures(CastDoc.sample()) |> List.filter(t -> not Set.memberOf(t, textures)))

    @Test
    def testTheSampleDesignIsThePortraitScreen(): Unit \ {Assert, IO} =
        // 作例の project.json の design は縦の 540×1170（描き出しの基準の絵と PC の窓の中身はこの大きさ）。
        let d = SceneRender.design();
        Assert.assertEq(expected = (540.0, 1170.0), (d#x, d#y))

    @Test
    def testTheSampleDeclaresNoExtraFont(): Unit \ {Assert, Fs.FileRead} =
        // 作例は本文の本だけで描く（GameBoot.app で App.withFonts に名前を宣言していない）。
        Assert.assertEq(expected = Nil, SceneRender.declaredFontsOf(TestKit.res()))
}
