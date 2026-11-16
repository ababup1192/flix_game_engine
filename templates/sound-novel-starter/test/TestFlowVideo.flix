// 描き出しと flow の動画の画面の大きさ（SceneRender.designOf・fitOf・cfgOf・FlowVideo.objectsOf）と、撮るコマの上限（FlowVideo.frameBudgetOf）。
mod TestFlowVideo {

    use fge::{App, Flow, FontAtlas, ProjectLoader}

    def portraitDesign(): { x = Float64, y = Float64 } = { x = 540.0, y = 960.0 }

    /// このテンプレートの project.json を、design だけ w×h に替えて読んだ物。
    def projectSized(w: Int32, h: Int32): Result[String, ProjectLoader.Project] \ Fs.FileRead =
        ProjectLoader.loadProject(".") |> Result.map(p -> { config = { designWidth = w, designHeight = h | p#config } | p })

    @Test
    def testDesignIsReadFromTheProject(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Ok((540.0, 960.0)), SceneRender.designOf(projectSized(540, 960)) |> Result.map(d -> (d#x, d#y)))

    @Test
    def testTemplateDesignIsTheLandscapeScreen(): Unit \ {Assert, IO} =
        let d = SceneRender.design();
        Assert.assertEq(expected = (960.0, 540.0), (d#x, d#y))

    @Test
    def testZeroSizedDesignIsAnError(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Result.isErr(SceneRender.designOf(projectSized(0, 960))))

    @Test
    def testPortraitDesignIsDrawnWithThePortraitFit(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertTrue(Layout.isPortrait(SceneRender.fitOf(portraitDesign(), TestKit.res())))

    @Test
    def testLandscapeDesignIsDrawnWithTheRegularFit(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertFalse(Layout.isPortrait(SceneRender.fitOf(Layout.size(Layout.Fit.Regular), TestKit.res())))

    @Test
    def testPortraitDesignShootsAFrameOfTheSameSize(): Unit \ {Assert, IO} =
        let cfg = SceneRender.cfgOf(portraitDesign(), "debug", Map.empty());
        Assert.assertEq(expected = (540, 960), (cfg#frameW, cfg#frameH))

    @Test
    def testPortraitObjectsStayInsideTheScreen(): Unit \ {Assert, Fs.FileRead} =
        // 縦の design で読んでいる間の物（背景・メッセージウィンドウ・クイックメニュー）は、どれも 540 の幅の中に収まる。
        let r = TestKit.res();
        let objects = FlowVideo.objectsOf(View.emptyFonts(), SceneRender.fitOf(portraitDesign(), r), r, TestKit.begun(r));
        Assert.assertTrue(not List.isEmpty(objects) and (objects |> List.forAll(o -> o#rect#position#x + o#rect#size#x <= 540.01)))

    def scriptOf(steps: List[Flow.Step]): Flow.Script =
        { fps = 10.0, ready = None, options = Map.empty(),
          lines = steps |> List.map(step -> { file = "t.flow", number = 1, text = "", step = step }) }

    @Test
    def testFrameBudgetCoversWaitsAndUntilMax(): Unit \ Assert =
        // wait 2 秒と until の max 5 秒を 10fps で: 20 + 1 と 50 + 1 と 1。
        let steps = Flow.Step.Wait(Flow.Span.Secs(2.0), Flow.noOpt()) :: Flow.Step.Until(Flow.Expr.Name("lineDone"), 5.0) :: Nil;
        Assert.assertEq(expected = 73, FlowVideo.frameBudgetOf(scriptOf(steps)))

    @Test
    def testFrameBudgetGivesATapTheReadyWait(): Unit \ Assert =
        // tap は入力を受けられるまで待つ 10 秒を取りうる（100 + 1 と 1）。
        Assert.assertEq(expected = 102, FlowVideo.frameBudgetOf(scriptOf(Flow.Step.Tap(Flow.Target.Role("confirm"), Flow.noOpt()) :: Nil)))

    @Test
    def testFrameBudgetCoversTheRecordedFrames(): Unit \ Assert =
        // 記録が 30 フレームを書いた wait 1 秒（10 フレーム）は 30 フレームを取る（30 + 1 と 1）。
        let opt = { ns = List.repeat(30, 16000000i64) | Flow.noOpt() };
        Assert.assertEq(expected = 32, FlowVideo.frameBudgetOf(scriptOf(Flow.Step.Wait(Flow.Span.Secs(1.0), opt) :: Nil)))

    // ── 字の本（project.json の fonts と、ゲームの口に渡る Env#fonts） ──

    /// このテンプレートの project.json の fonts に、本文と同じ TTF の gothic を足して読んだ物。
    def projectWithGothic(): Result[String, ProjectLoader.Project] \ Fs.FileRead =
        ProjectLoader.loadProject(".") |> Result.map(p -> {
            let gothic = { name = "gothic", path = "assets/ShipporiMincho-Regular.subset.ttf", fontSize = 32.0 };
            { config = { fontManifest = gothic :: p#config#fontManifest | p#config } | p }
        })

    def atlasNamed(name: String): FontAtlas =
        { textureName = name, fontSize = 32.0, textureSize = 256.0, ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    @Test
    def testRenderingReadsTheProjectFonts(): Unit \ {Assert, Fs.FileRead, IO} =
        // 描き出しは App.withFonts で宣言した名前の本を、実機と同じ名前（font_<name>）で組み、名前で引ける。
        let fallback = atlasNamed("default");
        let picked = projectWithGothic() |> Result.map(p -> SceneRender.fontOfIn(SceneRender.fontsIn(p, "gothic" :: Nil), fallback))
            |> Result.map(fontOf -> (fontOf("gothic")#textureName, fontOf("unknown")#textureName));
        Assert.assertEq(expected = Ok(("font_gothic", "default")), picked)

    @Test
    def testAnUndeclaredFontIsTheBodyFontInRenderingToo(): Unit \ {Assert, Fs.FileRead, IO} =
        // project.json に有っても App.withFonts で宣言していない名前は、実機と同じく描き出しでも本文の本。
        let fallback = atlasNamed("default");
        let picked = projectWithGothic() |> Result.map(p -> SceneRender.fontOfIn(SceneRender.fontsIn(p, Nil), fallback)("gothic")#textureName);
        Assert.assertEq(expected = Ok("default"), picked)

    @Test
    def testTheTemplateDeclaresNoExtraFont(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Nil, SceneRender.declaredFontsOf(TestKit.res()))

    @Test
    def testGameHooksGetTheFontsOfTheFrame(): Unit \ {Assert, Fs.FileRead} =
        // 描く所の Env の字の本は ViewCtx から: 本文の本と、名前で引く本（GameView.draw・backdrop・hud はこの Env を受ける）。
        let r = TestKit.res();
        let ctx = App.viewCtxOfFonts(atlasNamed("body"), name -> if (name == "gothic") atlasNamed("font_gothic") else atlasNamed("body"),
                                     Layout.size(Layout.Fit.Regular));
        let fonts = View.envOfCtx(ctx, r, TestKit.w0(r))#fonts;
        Assert.assertEq(expected = ("body", "font_gothic"), (fonts#atlas#textureName, fonts#fontOf("gothic")#textureName))
}
