// PostStack（後がけの値の束）を具体値で固定する: どの欄でどの Pass が並ぶか・場面の Pass の形式・面に渡す数・
// 奥行きの絵の切り出し・組み方の問題・post.json の上書きの決まり・App.withPostStack の絵と計画。
mod TestPostStack {

    def size(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def black(): Color = Color.rgb(0.0, 0.0, 0.0)

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(0.0, 2.0, 10.0), yaw = 0.0, pitch = 0.0, fovY = 0.8, near = 0.1, far = 100.0 }

    def sceneItem(): Render.PlacedItem = Render.scene3d(Vec2.zero(), Scene3d.scene(camera(), size()))

    def built(world: List[Render.PlacedItem], s: PostStack.Stack): { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[PostStack.Issue] } =
        PostStack.build({ size = size(), clear = black(), world = world }, s)

    def passNames(s: PostStack.Stack): List[String] =
        built(sceneItem() :: Nil, s)#plan#passes |> List.map(p -> p#name)

    def sceneFormat(s: PostStack.Stack): RenderTarget.Format =
        Render.targetDescriptorOf(built(Nil, s)#plan, PostStack.sceneName())#format

    def specNameOf(item: Render.PlacedItem): String = match item#item {
        case Render.Item.Shader(sh) => sh#spec#name
        case _                      => ""
    }

    def paramOf(name: String, item: Render.PlacedItem): Option[Float64] = match item#item {
        case Render.Item.Shader(sh) => Map.get(name, sh#params)
        case _                      => None
    }

    def neutral(): PostStack.Stack = PostStack.preset(PostStack.Preset.Neutral)

    def bloom(): PostStack.Bloom = { threshold = 1.0, smoothness = 0.5, size = 0.04, strength = 0.6 }

    def band(): PostStack.DepthOfField = PostStack.DepthOfField.DepthBand({ focusDistance = 10.0, range = 4.0, band = 0.25, soft = 0.5, blur = 0.004 })

    // ── Pass の並び ──

    @Test
    def testNeutralDrawsOnlyTheScenePass(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: Nil, passNames(neutral()))

    @Test
    def testNeutralPresentsTheMainSurfaceDirectly(): Unit \ Assert =
        Assert.assertEq(expected = "ps_main", specNameOf(built(Nil, neutral())#present))

    @Test
    def testFxaaAddsThePostPassAndSmoothsIt(): Unit \ Assert =
        let b = built(Nil, neutral() |> PostStack.withFxaa(true));
        Assert.assertEq(expected = ("ps_scene" :: "ps_post" :: Nil, "fxaa:ps_post"), (List.map(p -> p#name, b#plan#passes), specNameOf(b#present)))

    @Test
    def testBloomAddsBrightAndTwoBlurPasses(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: "ps_bright" :: "ps_bloomA" :: "ps_bloomB" :: Nil,
                        passNames(neutral() |> PostStack.withBloom(Some(bloom()))))

    @Test
    def testDepthBandAddsDepthAndSoftPasses(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: "ps_depth" :: "ps_linear" :: "ps_soft" :: Nil,
                        passNames(neutral() |> PostStack.withDepthOfField(Some(band()))))

    @Test
    def testAcesNarkowiczBlursTheScenePassAsIs(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: "ps_depth" :: "ps_soft" :: Nil,
                        passNames(neutral() |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.0 }))
                                            |> PostStack.withDepthOfField(Some(band()))))

    @Test
    def testLowQualityShrinksTheBrightPassToAQuarter(): Unit \ Assert =
        let plan = built(Nil, neutral() |> PostStack.withBloom(Some(bloom())) |> PostStack.withQuality(PostStack.Quality.Low))#plan;
        Assert.assertEq(expected = 0.25, Render.targetDescriptorOf(plan, "ps_bright")#scale)

    // ── 場面の Pass の形式 ──

    @Test
    def testStandardWithoutBloomKeepsTheScenePassEightBit(): Unit \ Assert =
        Assert.assertEq(expected = RenderTarget.Format.Rgba8Unorm, sceneFormat(neutral()))

    @Test
    def testBloomMakesTheScenePassHalfFloat(): Unit \ Assert =
        Assert.assertEq(expected = RenderTarget.Format.Rgba16Float, sceneFormat(neutral() |> PostStack.withBloom(Some(bloom()))))

    @Test
    def testExposureMakesTheScenePassHalfFloat(): Unit \ Assert =
        Assert.assertEq(expected = RenderTarget.Format.Rgba16Float, sceneFormat(neutral() |> PostStack.withExposure(-1.0)))

    @Test
    def testMsaaX4ReachesTheScenePass(): Unit \ Assert =
        Assert.assertEq(expected = 4, Render.targetDescriptorOf(built(Nil, neutral() |> PostStack.withMsaa(PostStack.Msaa.X4))#plan, PostStack.sceneName())#samples)

    // ── 面に渡す数 ──

    @Test
    def testExposureIsPassedAsTwoToTheStops(): Unit \ Assert =
        Assert.assertEq(expected = Some(0.5), paramOf("ps_exposure", built(Nil, neutral() |> PostStack.withExposure(-1.0))#present))

    @Test
    def testSaturationAfterIsPassedAsOnePlusTheAmount(): Unit \ Assert =
        let s = neutral() |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.25 }));
        Assert.assertEq(expected = Some(1.25), paramOf("ps_satAfter", built(Nil, s)#present))

    @Test
    def testChangingExposureKeepsTheSameSpec(): Unit \ Assert =
        let a = built(Nil, neutral() |> PostStack.withExposure(-1.0))#present;
        let b = built(Nil, neutral() |> PostStack.withExposure(1.0))#present;
        let specOf = (item: Render.PlacedItem) -> match item#item {
            case Render.Item.Shader(sh) => "${ShaderJson.toJson(sh#spec)}"
            case _                      => ""
        };
        Assert.assertEq(expected = specOf(a), specOf(b))

    // ── 奥行きの絵 ──

    @Test
    def testDepthBandCutsTheBandAroundTheFocus(): Unit \ Assert =
        let depthPass = built(sceneItem() :: Nil, neutral() |> PostStack.withDepthOfField(Some(band())))#plan#passes
            |> List.find(p -> p#name == PostStack.depthName());
        let outputs = depthPass |> Option.map(p -> p#items |> List.filterMap(i -> match i#item {
            case Render.Item.Scene3d(cmd) => match cmd#output {
                case Scene3d.Output.Depth(d) => Some((d#near, d#range))
                case Scene3d.Output.Color    => None
            }
            case _ => None
        }));
        Assert.assertEq(expected = Some((6.0, 8.0) :: Nil), outputs)

    // ── 組み方の問題 ──

    @Test
    def testDepthOfFieldWithoutSceneIsReported(): Unit \ Assert =
        Assert.assertEq(expected = PostStack.Issue.NoScene3d :: Nil, built(Nil, neutral() |> PostStack.withDepthOfField(Some(band())))#issues)

    @Test
    def testTwoScenesAreReported(): Unit \ Assert =
        Assert.assertEq(expected = PostStack.Issue.SeveralScenes(2) :: Nil, built(sceneItem() :: sceneItem() :: Nil, neutral())#issues)

    @Test
    def testCustomPassWithReservedNameIsDroppedAndReported(): Unit \ Assert =
        let spec: ShaderDoc.Spec = { name = "mine", cycleRate = 0.0, bindings = Nil,
            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(black()), alpha = ShaderDoc.Field.Const(1.0) }) };
        let custom = { name = "ps_mine", at = PostStack.CustomAt.BeforeBloom, spec = spec, reads = Nil, scale = 1.0 };
        let b = built(Nil, neutral() |> PostStack.withCustom(custom :: Nil));
        Assert.assertEq(expected = (PostStack.Issue.ReservedPassName("ps_mine") :: Nil, "ps_scene" :: Nil), (b#issues, List.map(p -> p#name, b#plan#passes)))

    @Test
    def testAutoQualityIsLowOnSmallScreens(): Unit \ Assert =
        let low = match PostStack.qualityOf(PostStack.resolveQuality(Display.SizeClass.Small, neutral())) {
            case PostStack.Quality.Low => true
            case _                     => false
        };
        Assert.assertEq(expected = true, low)

    // ── post.json ──

    def parsed(text: String): Result[String, PostStack.Stack] = PostStack.parse(text) |> Result.mapErr(e -> "${e}")

    @Test
    def testDocOverridesOnlyTheWrittenVignetteField(): Unit \ Assert =
        let inner = parsed("{\"version\": 1, \"preset\": \"DuskOutdoor\", \"vignette\": {\"strength\": 0.5}}")
            |> Result.toOption |> Option.flatMap(PostStack.vignetteOf) |> Option.map(v -> (v#strength, v#inner));
        Assert.assertEq(expected = Some((0.5, 0.35)), inner)

    @Test
    def testDocNullRemovesTheBloom(): Unit \ Assert =
        let removed = parsed("{\"preset\": \"DuskOutdoor\", \"bloom\": null}") |> Result.toOption |> Option.map(s -> Option.isEmpty(PostStack.bloomOf(s)));
        Assert.assertEq(expected = Some(true), removed)

    @Test
    def testDocKeepsTheWhitePointWhenTheKindIsTheSame(): Unit \ Assert =
        let vt = parsed("{\"preset\": \"DuskOutdoor\", \"viewTransform\": {\"kind\": \"AcesNarkowicz\", \"saturationAfter\": 0.2}}")
            |> Result.toOption |> Option.map(PostStack.viewTransformOf);
        let pair = match vt {
            case Some(PostStack.ViewTransform.AcesNarkowicz(a)) => Some((a#whitePoint, a#saturationAfter))
            case _                                               => None
        };
        Assert.assertEq(expected = Some((4.0, 0.2)), pair)

    @Test
    def testDocPresetIsTheStartingPoint(): Unit \ Assert =
        Assert.assertEq(expected = Some(true), parsed("{\"preset\": \"DuskOutdoor\"}") |> Result.toOption |> Option.map(s -> PostStack.isFxaa(s)))

    @Test
    def testDocNumberAsStringIsAnError(): Unit \ Assert =
        Assert.assertEq(expected = true, Result.isErr(parsed("{\"exposure\": \"high\"}")))

    // ── 計画を足す ──

    @Test
    def testMergingPlansWithTheSameNameIsAnIssue(): Unit \ Assert =
        let a = Render.passPlan({ name = "ps_scene", clear = RenderTarget.LoadOp.ClearTransparent, items = Nil } :: Nil);
        let b = built(Nil, neutral())#plan;
        Assert.assertEq(expected = Err(Render.PassPlanIssue.DuplicatePass("ps_scene") :: Nil), Render.mergePassPlans(a, b) |> Result.map(_ -> ()))

    @Test
    def testMergingPlansPutsTheGamePassesFirst(): Unit \ Assert =
        let a = Render.passPlan({ name = "light", clear = RenderTarget.LoadOp.ClearTransparent, items = Nil } :: Nil);
        let names = Render.mergePassPlans(a, built(Nil, neutral())#plan) |> Result.map(p -> List.map(q -> q#name, p#passes));
        Assert.assertEq(expected = Ok("light" :: "ps_scene" :: Nil), names)

    // ── App.withPostStack ──

    def boxAt(x: Float64): Render.PlacedItem = { at = { x = x, y = 0.0 }, item = RawDraw.box({ x = 4.0, y = 4.0 }, black(), 0) }

    def postApp(): App.App[Int32, {}] =
        App.game({ init = 0, update = (_, w) -> w, view = (_, _) -> boxAt(1.0) :: Nil, reloads = Nil })
            |> App.withHudView((_, _) -> boxAt(2.0) :: Nil)
            |> App.withPostStack(_ -> neutral())

    @Test
    def testPostStackPutsTheViewIntoTheScenePass(): Unit \ Assert =
        let frame = App.buildFrame(postApp(), size(), App.pickCtx(size()), 0, (_, _) -> boxAt(1.0) :: Nil);
        let scene = frame#plan#passes |> List.find(p -> p#name == PostStack.sceneName()) |> Option.map(p -> List.map(i -> i#at#x, p#items));
        Assert.assertEq(expected = Some(1.0 :: Nil), scene)

    @Test
    def testPostStackLeavesTheHudOnTheScreen(): Unit \ Assert =
        let frame = App.buildFrame(postApp(), size(), App.pickCtx(size()), 0, (_, _) -> boxAt(1.0) :: Nil);
        Assert.assertEq(expected = "ps_main" :: "" :: Nil, List.map(specNameOf, frame#items))
}
