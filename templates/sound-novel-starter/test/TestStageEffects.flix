// 画面の演出の命令: 覆い（<<overlay>>）・カメラ（<<camera>>）・揺れの強さと相手（<<shake 強さ on=>>）と、world の層を層の数で並べる決まり。
// 強さ・覆いの始まり・層の数は Doc（assets/novel.kind.json）、人物と小物はテスト用の Doc（test/fixtures/novel.cast.json）から引く。
mod TestStageEffects {

    use fge::{Clock, Render, Yarn}

    def res(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def k(): KindDoc.Rec \ Fs.FileRead = KindDoc.rec(res()#kind)

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def tried(at: Float64, name: String, args: List[String], st: Stage.Stage): Result[String, Stage.Stage] \ Fs.FileRead =
        Commands.execute(Commands.Replay.Live, { now = t(at), node = "", res = res() }, command(name, args), st) |> Result.map(fst)

    def applied(at: Float64, name: String, args: List[String], st: Stage.Stage): Stage.Stage \ Fs.FileRead =
        tried(at, name, args, st) |> Result.getWithDefault(st)

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.000001

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
        Assert.assertTrue(near(0.6, PropertyTween.numEnd(Stage.overlayAlphaKey(), k()#overlayStart, st#props)))

    @Test
    def testOverlayStartsFromTheDocStart(): Unit \ {Assert, Fs.FileRead} =
        // 一度も覆いを書いていない時は、Doc の overlayStart から動き出す。
        let st = applied(0.0, "overlay", "0.6" :: "time=1" :: Nil, Stage.empty());
        Assert.assertTrue(near(k()#overlayStart, alphaAt(0.0, st)))

    @Test
    def testOverlayToTheSameAlphaChangesNothing(): Unit \ {Assert, Fs.FileRead} =
        // 動いている途中で同じ濃さへの覆いを書いても、動きを始め直さない。
        let first = applied(0.0, "overlay", "0.6" :: "time=2" :: Nil, Stage.empty());
        let again = applied(1.0, "overlay", "0.6" :: "time=2" :: Nil, first);
        Assert.assertTrue(near(alphaAt(1.5, first), alphaAt(1.5, again)))

    @Test
    def testOverlayFromStartsThere(): Unit \ {Assert, Fs.FileRead} =
        // from= は始まりの濃さ（flash は from=1 で 1 行）。
        let st = applied(0.0, "overlay", "0" :: "from=1" :: "time=1" :: Nil, Stage.empty());
        Assert.assertTrue(near(1.0, alphaAt(0.0, st)))

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
        Assert.assertTrue(near(1.5, PropertyTween.numEnd(Stage.cameraKey(Stage.CameraField.Zoom), 1.0, st#props)))

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
        Assert.assertTrue(near(2.0 * widthOf(Stage.withBackdrop(t(0.0), shot, 0.0, Stage.empty())), widthOf(withShot)))

    // ══ <<shake>> ══

    @Test
    def testNamedShakeUsesTheDocPx(): Unit \ {Assert, Fs.FileRead} =
        // <<shake 名前>> の揺れ幅は novel.kind.json の shakes の px。
        let name = k()#shakes |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("");
        let px = Map.get(name, k()#shakes) |> Option.map(s -> s#px) |> Option.getWithDefault(-1.0);
        let st = applied(0.0, "shake", name :: Nil, Stage.empty());
        Assert.assertTrue(near(px, PropertyTween.numEnd(Stage.shakeAmpKeyOf(Stage.ShakeTarget.Screen), 0.0, st#props)))

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
    def testAttachedActorIsNotCountedAsPresence(): Unit \ {Assert, Fs.FileRead} =
        // 背景に付く絵（shade）は、縦の頁の覆いを薄くする「人物が出ている量」に数えない。
        let st = Stage.settle(applied(0.0, "show", "shade" :: Nil, Stage.empty()));
        Assert.assertTrue(near(0.0, Cast.presenceOf(t(10.0), res()#cast, st#cast)))
}
