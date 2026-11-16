// 画面の演出の命令: 覆い（<<overlay>>）・カメラ（<<camera>>）・揺れの強さと相手（<<shake 強さ on=>>）と、world の層を層の数で並べる決まり。
// 強さ・覆いの始まり・層の数は Doc（assets/novel.kind.json）、人物と小物はテスト用の Doc（test/fixtures/novel.cast.json）から引く。
mod TestStageEffects {

    use fge::{Clock, Render, RichText, Yarn}

    def res(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def k(): KindDoc.Rec \ Fs.FileRead = KindDoc.rec(res()#kind)

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def tried(at: Float64, name: String, args: List[String], st: Stage.Stage): Result[String, Stage.Stage] \ Fs.FileRead =
        Commands.execute(Commands.Replay.Live, { now = t(at), node = "", res = res(), instant = false }, command(name, args), st) |> Result.map(fst)

    def applied(at: Float64, name: String, args: List[String], st: Stage.Stage): Stage.Stage \ Fs.FileRead =
        tried(at, name, args, st) |> Result.getWithDefault(st)

    def alphaAt(at: Float64, st: Stage.Stage): Float64 \ Fs.FileRead =
        PropertyTween.numAt(t(at), Stage.overlayAlphaKey(), k()#overlayStart, st#props)

    def envAt(at: Float64): View.Env \ Fs.FileRead =
        let r = res();
        { storyNow = t(at) | View.envOf(Layout.Fit.Regular, r, TestKit.w0(r)) }

    /// world の層に描いた面の (シェーダーの名前, z)。
    def shaderZs(st: Stage.Stage): List[(String, Int32)] \ Fs.FileRead =
        ViewStage.frame(envAt(100.0), st, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) => Some((s#spec#name, s#zIndex))
            case _                     => None
        })

    def zOfShader(name: String, st: Stage.Stage): Int32 \ Fs.FileRead =
        shaderZs(st) |> List.find(match (n, _) -> n == name) |> Option.map(snd) |> Option.getWithDefault(-1)

    // ══ <<overlay>> ══

    @Test
    def testOverlayEndsAtTheAlpha(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(0.0, "overlay", "0.6" :: "time=1" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(0.6, PropertyTween.numEnd(Stage.overlayAlphaKey(), k()#overlayStart, st#props)))

    @Test
    def testOverlayStartsFromTheDocStart(): Unit \ {Assert, Fs.FileRead} =
        // 一度も覆いを書いていない時は、Doc の overlayStart から動き出す。
        let st = applied(0.0, "overlay", "0.6" :: "time=1" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(k()#overlayStart, alphaAt(0.0, st)))

    @Test
    def testOverlayToTheSameAlphaChangesNothing(): Unit \ {Assert, Fs.FileRead} =
        // 動いている途中で同じ濃さへの覆いを書いても、動きを始め直さない。
        let first = applied(0.0, "overlay", "0.6" :: "time=2" :: Nil, Stage.empty());
        let again = applied(1.0, "overlay", "0.6" :: "time=2" :: Nil, first);
        Assert.assertTrue(TestKit.near(alphaAt(1.5, first), alphaAt(1.5, again)))

    @Test
    def testOverlayFromStartsThere(): Unit \ {Assert, Fs.FileRead} =
        // from= は始まりの濃さ（flash は from=1 で 1 行）。
        let st = applied(0.0, "overlay", "0" :: "from=1" :: "time=1" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(1.0, alphaAt(0.0, st)))

    @Test
    def testOverlayUnknownColorIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(tried(0.0, "overlay", "0.5" :: "color=purple" :: Nil, Stage.empty())))

    @Test
    def testScreenOverlayIsDrawnInTheHud(): Unit \ {Assert, Fs.FileRead} =
        // layer=screen の覆いは hud に描く。
        let st = applied(0.0, "overlay", "0.5" :: "layer=screen" :: Nil, Stage.empty());
        Assert.assertEq(expected = 1, List.length(ViewStage.screenOverlay(envAt(1.0), st, 44)))

    @Test
    def testStageOverlayIsNotDrawnInTheHud(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(0.0, "overlay", "0.5" :: Nil, Stage.empty());
        Assert.assertEq(expected = 0, List.length(ViewStage.screenOverlay(envAt(1.0), st, 44)))

    // ══ <<camera>> ══

    @Test
    def testCameraEndsAtTheZoom(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(0.0, "camera", "zoom=1.5" :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(1.5, PropertyTween.numEnd(Stage.cameraKey(Stage.CameraField.Zoom), 1.0, st#props)))

    @Test
    def testCameraZoomScalesTheWorld(): Unit \ {Assert, Fs.FileRead} =
        // 寄ると world の層の物が大きく描かれる（背景の面の幅が zoom 倍）。
        let st = applied(0.0, "camera", "zoom=2" :: "time=0" :: Nil, Stage.empty());
        let r = res();
        let shot = { photo = BackdropDoc.rec(r#backdrops)#photos |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault(""),
                     grade = BackdropDoc.rec(r#backdrops)#grades |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("") };
        let withShot = Stage.withBackdrop(t(0.0), shot, 0.0, st);
        let widthOf = (s: Stage.Stage) -> ViewStage.frame(envAt(1.0), s, true) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(x) => Some(x#rect#size#x)
            case _                     => None
        }) |> List.head |> Option.getWithDefault(0.0);
        Assert.assertTrue(TestKit.near(2.0 * widthOf(Stage.withBackdrop(t(0.0), shot, 0.0, Stage.empty())), widthOf(withShot)))

    // ══ <<shake>> ══

    @Test
    def testNamedShakeUsesTheDocPx(): Unit \ {Assert, Fs.FileRead} =
        // <<shake 名前>> の揺れ幅は novel.kind.json の shakes の px。
        let name = k()#shakes |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("");
        let px = Map.get(name, k()#shakes) |> Option.map(s -> s#px) |> Option.getWithDefault(-1.0);
        let st = applied(0.0, "shake", name :: Nil, Stage.empty());
        Assert.assertTrue(TestKit.near(px, PropertyTween.numEnd(Stage.shakeAmpKeyOf(Stage.ShakeTarget.Screen), 0.0, st#props)))

    @Test
    def testUnknownShakeNameIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(tried(0.0, "shake", "zz" :: Nil, Stage.empty())))

    @Test
    def testShakeOnAnActorShakesOnlyThatActor(): Unit \ {Assert, Fs.FileRead} =
        // on=名前 はその絵だけを揺らす（画面は揺れない）。
        let st = applied(0.0, "shake", "on=a" :: Nil, Stage.empty());
        let mid = t(k()#shakeSeconds / 3.0);
        Assert.assertEq(expected = (true, (0.0, 0.0)),
                        (Stage.shakeOffset(mid, Stage.ShakeTarget.Actor("a"), st) != (0.0, 0.0), Stage.shakeOffset(mid, Stage.ShakeTarget.Screen, st)))

    @Test
    def testShakeOnWindowShakesTheWindow(): Unit \ {Assert, Fs.FileRead} =
        let st = applied(0.0, "shake", "on=window" :: Nil, Stage.empty());
        Assert.assertTrue(Stage.shakeOffset(t(k()#shakeSeconds / 3.0), Stage.ShakeTarget.Window, st) != (0.0, 0.0))

    // ══ 層の数で並べる ══

    @Test
    def testDocLayerDecidesTheZ(): Unit \ {Assert, Fs.FileRead} =
        // 後から出した小物 book（layer 450）は、人物 a（500）より奥の z に描く。
        let st = Stage.settle(applied(1.0, "show", "book" :: Nil, applied(0.0, "show", "a" :: Nil, Stage.empty())));
        Assert.assertTrue(zOfShader("picture_cast_book_plain", st) < zOfShader("picture_cast_a_plain", st))

    @Test
    def testStageOverlayIsAboveTheActors(): Unit \ {Assert, Fs.FileRead} =
        // 覆い（overlayLayer）は人物より手前に描く。
        let st = Stage.settle(applied(1.0, "overlay", "0.5" :: Nil, applied(0.0, "show", "a" :: Nil, Stage.empty())));
        let items = ViewStage.frame(envAt(100.0), st, true);
        let boxZ = items |> List.filterMap(placed -> match placed#item {
            case Render.Item.Box(b) => Some(b#zIndex)
            case _                  => None
        }) |> List.foldLeft(Int32.max, -1);
        Assert.assertTrue(boxZ > zOfShader("picture_cast_a_plain", st))

    @Test
    def testParticlesWithoutALayerAreAboveTheActors(): Unit \ {Assert, Fs.FileRead} =
        // 層の数を書かない粒（既定 700）は、人物（500）より手前に描く。
        let r = res() |> Res.withEffects(EffectsDoc.defaults());
        let st = Stage.settle(applied(1.0, "fx", "snow" :: Nil, applied(0.0, "show", "a" :: Nil, Stage.empty())));
        let env = { storyNow = t(100.0) | View.envOf(Layout.Fit.Regular, r, TestKit.w0(r)) };
        let items = ViewStage.frame(env, st, true);
        let castZ = items |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) => Some(s#zIndex)
            case _                     => None
        }) |> List.foldLeft(Int32.max, -1);
        let polyZ = items |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(_) => None
            case other                 => Some(ViewStage.zOf(other))
        }) |> List.foldLeft(Int32.max, -1);
        Assert.assertTrue(polyZ > castZ)

    @Test
    def testAttachedActorIsNotCountedAsPresence(): Unit \ {Assert, Fs.FileRead} =
        // 背景に付く絵（shade）は、縦の頁の覆いを薄くする「人物が出ている量」に数えない。
        let st = Stage.settle(applied(0.0, "show", "shade" :: Nil, Stage.empty()));
        Assert.assertTrue(TestKit.near(0.0, Cast.presenceOf(t(10.0), res()#cast, st#cast)))

    // ══ <<text align=center>> の行ごとの真ん中寄せ ══

    /// align を書いた舞台で、今の行 text（ルビ rubies）を shown 字まで出した時に、横の NVL の頁に描いた本文の字の (字, x, y)（影を除く）。
    def placedGlyphs(align: Option[String], text: String, rubies: List[RichText.Ruby], shown: Float64): List[(String, Float64, Float64)] \ {Fs.FileRead, IO} =
        let r0 = res();
        let atlas = SceneRender.cfgOf(Layout.size(Layout.Fit.Regular), "debug", Map.empty())#fontAtlas;
        let w = TestKit.begun(r0);
        World.readOf(w) |> Option.map(r -> {
            let line = { rubies = rubies | Page.plainLine(text, "a:1") };
            let page = { lines = Nil, current = Some(line), reveal = { text = text, shown = shown } | r#page };
            let props = align |> Option.map(a -> PropertyTween.setName(Stage.textAlignKey(), Some(a), t(0.0), 0.0, r#stage#props)) |> Option.getWithDefault(r#stage#props);
            ViewText.textLayer(atlas, View.envOf(Layout.Fit.Regular, r0, w), { page = page, stage = { props = props | r#stage } | r })
        }) |> Option.getWithDefault(Nil) |> List.filterMap(p -> match p#item {
            case Render.Item.Text(x) if x#zIndex == View.zText() + 1 => Some((x#text, p#at#x, p#at#y))
            case _                                                     => None
        })

    def middleOfTheNvlPage(): Float64 = Layout.nvlText()#x + Layout.nvlText()#width / 2.0

    @Test
    def testCenteredLineIsCenteredRowByRow(): Unit \ {Assert, Fs.FileRead, IO} =
        // 改行の後の 1 字の行（き）も、頁の幅の真ん中あたりに置く。
        let glyphs = placedGlyphs(Some("center"), "あいうえお\nき", Nil, 100.0);
        let lastRow = glyphs |> List.filter(match (s, _, _) -> s == "き") |> List.map(match (_, x, _) -> x);
        Assert.assertTrue(lastRow |> List.exists(x -> Float64.abs(x - middleOfTheNvlPage()) < 30.0))

    @Test
    def testCenteredRowsStayPutWhileTheyAppear(): Unit \ {Assert, Fs.FileRead, IO} =
        // 文字送りが 2 行目へ入る前（1 行目の 3 字まで）と出し終えた時で、1 行目の字の x が同じ（2 行目はまだ描かない）。
        let early = placedGlyphs(Some("center"), "あいうえお\nき", Nil, 3.0);
        let done = placedGlyphs(Some("center"), "あいうえお\nき", Nil, 100.0) |> List.filter(match (s, _, _) -> s == "あ" or s == "い" or s == "う");
        Assert.assertEq(expected = done, early)

    @Test
    def testCenteredRowsKeepTheirRuby(): Unit \ {Assert, Fs.FileRead, IO} =
        // 2 行目の親字（かき = 全体の 6・7 字目）のルビも、親字の上に真ん中寄せで出る。
        let glyphs = placedGlyphs(Some("center"), "あいうえお\nかき", { start = 6, length = 2, text = "よみ" } :: Nil, 100.0);
        let rubyX = glyphs |> List.filter(match (s, _, _) -> s == "よみ") |> List.map(match (_, x, _) -> x);
        Assert.assertTrue(rubyX |> List.exists(x -> Float64.abs(x - middleOfTheNvlPage()) < 30.0))

    @Test
    def testLeftAlignedLineStaysAtTheLeftEdge(): Unit \ {Assert, Fs.FileRead, IO} =
        let glyphs = placedGlyphs(None, "あいうえお\nき", Nil, 100.0);
        Assert.assertEq(expected = Some(Layout.nvlText()#x), glyphs |> List.find(match (s, _, _) -> s == "き") |> Option.map(match (_, x, _) -> x))
}
