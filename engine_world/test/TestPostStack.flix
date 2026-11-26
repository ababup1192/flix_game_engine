// PostStack（後がけの値の束）を具体値で固定する: どの欄でどの Pass が並ぶか・場面の Pass の形式・面に渡す数・
// 奥行きの絵の切り出し・組み方の問題・post.json の上書きの決まり・App.withPostStack の絵と計画。
mod TestPostStack {

    def size(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def black(): Color = Color.rgb(0.0, 0.0, 0.0)

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(0.0, 2.0, 10.0), yaw = 0.0, pitch = 0.0, fovY = 0.8, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

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
        Assert.assertEq(expected = PostStack.Issue.SeveralScenes(2) :: Nil,
                        built(sceneItem() :: sceneItem() :: Nil, neutral() |> PostStack.withDepthOfField(Some(band())))#issues)

    @Test
    def testTwoScenesWithoutDepthAreNotReported(): Unit \ Assert =
        Assert.assertEq(expected = Nil, built(sceneItem() :: sceneItem() :: Nil, neutral())#issues)

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

    // ── 本編の面の形 ──

    def specOf(item: Render.PlacedItem): Option[ShaderDoc.Spec] = match item#item {
        case Render.Item.Shader(sh) => Some(sh#spec)
        case _                      => None
    }

    def bindingNames(s: PostStack.Stack): List[String] =
        built(sceneItem() :: Nil, s)#present |> specOf |> Option.map(sp -> List.map(fst, sp#bindings)) |> Option.getWithDefault(Nil)

    def physical(focus: Float64, fStop: Float64): PostStack.DepthOfField =
        PostStack.DepthOfField.Physical({ focusDistance = focus, fStop = fStop })

    def everything(v: PostStack.ViewTransform): PostStack.Stack =
        neutral() |> PostStack.withViewTransform(v) |> PostStack.withBloom(Some(bloom()))
            |> PostStack.withVignette(Some({ strength = 0.3, inner = 0.35, outer = 1.05, center = { x = 0.5, y = 0.5 } }))
            |> PostStack.withColorGrade(Some({ lift = Color.rgb(1.0, 1.0, 1.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = Color.rgb(1.0, 1.0, 1.0), saturation = 1.0 }))
            |> PostStack.withDepthOfField(Some(physical(8.0, 2.8)))

    // GLSL と WGSL は binding ごとに変数を 1 つ宣言するので、同じ名前が 2 つあると shader が作れない。
    @Test
    def testBindingNamesAreUniqueWithEveryEffect(): Unit \ Assert =
        let views = PostStack.ViewTransform.Standard :: PostStack.ViewTransform.KhronosNeutral :: PostStack.ViewTransform.AgX
            :: PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.1 }) :: Nil;
        let dupes = views |> List.flatMap(v -> { let names = bindingNames(everything(v)); if (List.length(names) == Set.size(List.toSet(names))) Nil else names :: Nil });
        Assert.assertEq(expected = Nil, dupes)

    @Test
    def testMovingThePhysicalFocusKeepsTheSameSpec(): Unit \ Assert =
        let a = built(sceneItem() :: Nil, neutral() |> PostStack.withDepthOfField(Some(physical(4.0, 2.8))))#present |> specOf;
        let b = built(sceneItem() :: Nil, neutral() |> PostStack.withDepthOfField(Some(physical(9.0, 1.4))))#present |> specOf;
        Assert.assertEq(expected = Option.map(sp -> "${ShaderJson.toJson(sp)}", a), Option.map(sp -> "${ShaderJson.toJson(sp)}", b))

    @Test
    def testPhysicalFocusIsPassedInSceneUnits(): Unit \ Assert =
        let world = Render.scene3d(Vec2.zero(), Scene3d.scene(camera(), size()) |> Scene3d.withUnitsPerMeter(16.0)) :: Nil;
        Assert.assertEq(expected = Some(128.0), paramOf("ps_focus", built(world, neutral() |> PostStack.withDepthOfField(Some(physical(8.0, 2.8))))#present))

    @Test
    def testPhysicalWithoutApertureDrawsNoDepthPass(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: Nil, passNames(neutral() |> PostStack.withDepthOfField(Some(physical(8.0, 0.0)))))

    @Test
    def testNeutralColorGradeKeepsTheColor(): Unit \ Assert =
        let grade = { lift = Color.rgb(1.0, 1.0, 1.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = Color.rgb(1.0, 1.0, 1.0), saturation = 1.0 };
        let present = built(Nil, neutral() |> PostStack.withColorGrade(Some(grade)))#present;
        let out = match present#item {
            case Render.Item.Shader(sh) =>
                let tex = ShaderEval.hdrTextureOf(1, 1, Vector#{0.5, 0.25, 0.75, 1.0});
                let compiled = ShaderEval.compile(ShaderDoc.bindParams(sh#params, sh#spec), Map#{ PostStack.sceneName() => ShaderEval.TexImage.Rgba16Float(tex) });
                let (r, g, b, _) = ShaderEval.evalCompiled(compiled, 0.5, 0.5, 0.0);
                Some((Float64.round(r * 255.0), Float64.round(g * 255.0), Float64.round(b * 255.0)))
            case _ => None
        };
        Assert.assertEq(expected = Some((128.0, 64.0, 191.0)), out)

    @Test
    def testDocWithoutKindAndWithoutStartingDepthOfFieldIsAnError(): Unit \ Assert =
        Assert.assertEq(expected = true, Result.isErr(parsed("{\"preset\": \"Neutral\", \"depthOfField\": {\"fStop\": 4.0}}")))

    @Test
    def testDocWithoutKindKeepsTheStartingViewTransform(): Unit \ Assert =
        let vt = parsed("{\"preset\": \"DuskOutdoor\", \"viewTransform\": {\"whitePoint\": 8.0}}") |> Result.toOption |> Option.map(PostStack.viewTransformOf);
        let agx = match vt {
            case Some(PostStack.ViewTransform.AgX) => true
            case _                                 => false
        };
        Assert.assertEq(expected = true, agx)

    @Test
    def testNamedPresetsUseAgX(): Unit \ Assert =
        let isAgx = (p: PostStack.Preset) -> match PostStack.viewTransformOf(PostStack.preset(p)) {
            case PostStack.ViewTransform.AgX => true
            case _                           => false
        };
        Assert.assertEq(expected = Nil, PostStack.presets() |> List.filter(p -> p != PostStack.Preset.Neutral and not isAgx(p)))

    @Test
    def testScreenClearIsTheDefaultBackground(): Unit \ Assert =
        let frame = App.buildFrame(postApp() |> App.withScreenClear(Color.rgb(0.1, 0.2, 0.3)), size(), App.pickCtx(size()), 0, (_, _) -> Nil);
        let clear = frame#plan#passes |> List.find(p -> p#name == PostStack.sceneName()) |> Option.map(p -> match p#clear {
            case RenderTarget.LoadOp.Clear(c) => (c#r, c#g, c#b)
            case _                            => (-1.0, -1.0, -1.0)
        });
        Assert.assertEq(expected = Some((0.1, 0.2, 0.3)), clear)

    @Test
    def testDocOtherKindReplacesTheWholeField(): Unit \ Assert =
        let fd = parsed("{\"preset\": \"Neutral\", \"depthOfField\": {\"kind\": \"DepthBand\", \"blur\": 0.01}}") |> Result.toOption
            |> Option.flatMap(PostStack.depthOfFieldOf);
        let band = match fd {
            case Some(PostStack.DepthOfField.DepthBand(b)) => Some((b#blur, b#band))
            case _                                         => None
        };
        Assert.assertEq(expected = Some((0.01, 0.25)), band)

    @Test
    def testBackgroundClearsTheScenePass(): Unit \ Assert =
        let frame = App.buildFrame(postApp() |> App.withPostStack(_ -> neutral() |> PostStack.withBackground(Color.rgb(0.2, 0.4, 0.6))),
                                   size(), App.pickCtx(size()), 0, (_, _) -> Nil);
        let clear = frame#plan#passes |> List.find(p -> p#name == PostStack.sceneName()) |> Option.map(p -> match p#clear {
            case RenderTarget.LoadOp.Clear(c) => (c#r, c#g, c#b)
            case _                            => (-1.0, -1.0, -1.0)
        });
        Assert.assertEq(expected = Some((0.2, 0.4, 0.6)), clear)

    // ── 画面の歪み（Distortion） ──

    def haze(mask: PostStack.DistortionMask): PostStack.Distortion =
        { strength = { x = 3.0, y = 2.0 }, noiseSize = 24.0, speed = { x = 0.0, y = -20.0 }, mask = mask }

    def at(seconds: Float64): Clock.Time[Clock.Real] = Clock.after(seconds, Clock.zero())

    /// 計画と画面の面を字にした物（Pass の名前・描き先・面の Spec と数と時刻）。
    def planText(b: { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[PostStack.Issue] }): String =
        let itemText = (i: Render.PlacedItem) -> match i#item {
            case Render.Item.Shader(sh) => "${ShaderJson.toJson(sh#spec)} ${sh#params} ${sh#t}"
            case _                      => "${i#at#x},${i#at#y}"
        };
        let passes = b#plan#passes |> List.map(p -> {
            let d = Render.targetDescriptorOf(b#plan, p#name);
            "${p#name} ${d#format} ${d#scale} ${d#samples} ${List.map(itemText, p#items)}"
        });
        "${passes} ${itemText(b#present)}"

    @Test
    def testTimeWithoutDistortionKeepsThePlanAndThePicture(): Unit \ Assert =
        let s = PostStack.preset(PostStack.Preset.DuskOutdoor);
        Assert.assertEq(expected = planText(built(sceneItem() :: Nil, s)), planText(built(sceneItem() :: Nil, s |> PostStack.withTime(at(5.0)))))

    @Test
    def testZeroStrengthDrawsNoDistortPass(): Unit \ Assert =
        let still = { strength = { x = 0.0, y = 0.0 } | haze(PostStack.DistortionMask.Full) };
        Assert.assertEq(expected = planText(built(Nil, neutral())), planText(built(Nil, neutral() |> PostStack.withDistortion(Some(still)))))

    @Test
    def testZeroNoiseSizeDrawsNoDistortPass(): Unit \ Assert =
        let flat = { noiseSize = 0.0 | haze(PostStack.DistortionMask.Full) };
        Assert.assertEq(expected = planText(built(Nil, neutral())), planText(built(Nil, neutral() |> PostStack.withDistortion(Some(flat)))))

    @Test
    def testDistortionAddsOnePassAfterTheScene(): Unit \ Assert =
        Assert.assertEq(expected = "ps_scene" :: "ps_distort" :: "ps_bright" :: "ps_bloomA" :: "ps_bloomB" :: Nil,
                        passNames(neutral() |> PostStack.withBloom(Some(bloom())) |> PostStack.withDistortion(Some(haze(PostStack.DistortionMask.Full)))))

    @Test
    def testMainSurfaceReadsTheDistortedScene(): Unit \ Assert =
        let spec = built(Nil, neutral() |> PostStack.withDistortion(Some(haze(PostStack.DistortionMask.Full))))#present |> specOf;
        Assert.assertEq(expected = Some(true), spec |> Option.map(sp -> String.contains(substr = "ps_distort", "${ShaderJson.toJson(sp)}")))

    @Test
    def testDistortPassHasNoMsaa(): Unit \ Assert =
        let b = built(Nil, neutral() |> PostStack.withMsaa(PostStack.Msaa.X4) |> PostStack.withDistortion(Some(haze(PostStack.DistortionMask.Full))));
        Assert.assertEq(expected = (4, 1), (Render.targetDescriptorOf(b#plan, "ps_scene")#samples, Render.targetDescriptorOf(b#plan, "ps_distort")#samples))

    def distortItem(s: PostStack.Stack): Option[Render.PlacedItem] =
        built(Nil, s)#plan#passes |> List.find(p -> p#name == "ps_distort") |> Option.flatMap(p -> List.head(p#items))

    def distortSpecText(s: PostStack.Stack): Option[String] =
        distortItem(s) |> Option.flatMap(specOf) |> Option.map(sp -> "${ShaderJson.toJson(sp)}")

    @Test
    def testChangingStrengthAndTimeKeepsTheSameSpec(): Unit \ Assert =
        let a = neutral() |> PostStack.withDistortion(Some(haze(PostStack.DistortionMask.Full)));
        let b = neutral() |> PostStack.withDistortion(Some({ strength = { x = 6.0, y = 0.5 } | haze(PostStack.DistortionMask.Full) })) |> PostStack.withTime(at(12.5));
        Assert.assertEq(expected = distortSpecText(a), distortSpecText(b))

    @Test
    def testStrengthIsPassedAsAShareOfTheScreen(): Unit \ Assert =
        let item = distortItem(neutral() |> PostStack.withDistortion(Some(haze(PostStack.DistortionMask.Full))));
        Assert.assertEq(expected = (Some(3.0 / 320.0), Some(2.0 / 180.0)),
                        (item |> Option.flatMap(i -> paramOf("ps_distortX", i)), item |> Option.flatMap(i -> paramOf("ps_distortY", i))))

    // ── 画面の歪みを CPU で描いた絵 ──
    // 場面は r = 横の位置・g = 縦の位置の傾きの絵。Linear で読むので、出た r・g と位置の差が、そのまま読んだ位置のずれ（uv）になる。

    def gradeW(): Int32 = 64

    def gradeH(): Int32 = 36

    def gradient(): ShaderEval.TexImage =
        let rgba = List.range(0, gradeH()) |> List.flatMap(y -> List.range(0, gradeW()) |> List.flatMap(x ->
            (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(gradeW()) :: (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(gradeH()) :: 0.0 :: 1.0 :: Nil));
        ShaderEval.TexImage.Rgba16Float(ShaderEval.hdrTextureOf(gradeW(), gradeH(), List.toVector(rgba)))

    /// 傾きの絵の画素の真ん中の位置（端の 4 画素は除く。端は張り付きで読むので、ずれが測れない）。
    def samplePoints(): List[(Float64, Float64)] =
        List.range(4, gradeH() - 4) |> List.flatMap(y -> List.range(4, gradeW() - 4) |> List.map(x ->
            ((Int32.toFloat64(x) + 0.5) / Int32.toFloat64(gradeW()), (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(gradeH()))))

    /// 画素 (u, v) で読んだ位置のずれ（design の px）。
    def offsetsAt(s: PostStack.Stack, points: List[(Float64, Float64)]): List[(Float64, Float64)] =
        match distortItem(s) |> Option.map(i -> i#item) {
            case Some(Render.Item.Shader(sh)) =>
                let compiled = ShaderEval.compile(ShaderDoc.bindParams(sh#params, sh#spec), Map#{ PostStack.sceneName() => gradient() });
                points |> List.map(pt -> {
                    let (u, v) = pt;
                    let (r, g, _, _) = ShaderEval.evalCompiled(compiled, u, v, sh#t);
                    ((r - u) * size()#x, (g - v) * size()#y)
                })
            case _ => Nil
        }

    def hazy(mask: PostStack.DistortionMask, seconds: Float64): PostStack.Stack =
        neutral() |> PostStack.withDistortion(Some(haze(mask))) |> PostStack.withTime(at(seconds))

    def isMoved(o: (Float64, Float64)): Bool = let (dx, dy) = o; Float64.abs(dx) > 0.05 or Float64.abs(dy) > 0.05

    @Test
    def testCpuDistortionMovesPixelsWithinTheStrength(): Unit \ Assert =
        let offs = offsetsAt(hazy(PostStack.DistortionMask.Full, 1.5), samplePoints());
        let maxX = offs |> List.map(o -> Float64.abs(fst(o))) |> List.maximum |> Option.getWithDefault(0.0);
        let maxY = offs |> List.map(o -> Float64.abs(snd(o))) |> List.maximum |> Option.getWithDefault(0.0);
        Assert.assertEq(expected = (true, true, true), (List.count(isMoved, offs) > List.length(offs) / 2, maxX <= 3.0 + 0.2, maxY <= 2.0 + 0.2))

    @Test
    def testCpuDistortionAveragesToNoShift(): Unit \ Assert =
        let offs = offsetsAt(hazy(PostStack.DistortionMask.Full, 0.0), samplePoints());
        let n = Int32.toFloat64(Int32.max(1, List.length(offs)));
        let meanX = (offs |> List.map(fst) |> List.foldLeft((a, x) -> a + x, 0.0)) / n;
        let meanY = (offs |> List.map(snd) |> List.foldLeft((a, x) -> a + x, 0.0)) / n;
        Assert.assertEq(expected = (true, true), (Float64.abs(meanX) < 0.75, Float64.abs(meanY) < 0.5))

    @Test
    def testCpuBottomBandLeavesTheTopHalfStill(): Unit \ Assert =
        let pts = samplePoints();
        let offs = List.zip(pts, offsetsAt(hazy(PostStack.DistortionMask.BottomBand({ top = 0.5, soft = 0.0 }), 2.0), pts));
        let movedAbove = offs |> List.count(e -> snd(fst(e)) < 0.49 and isMoved(snd(e)));
        let movedBelow = offs |> List.count(e -> snd(fst(e)) > 0.51 and isMoved(snd(e)));
        Assert.assertEq(expected = (0, true), (movedAbove, movedBelow > 0))

    @Test
    def testCpuSameTimeDrawsTheSamePicture(): Unit \ Assert =
        Assert.assertEq(expected = offsetsAt(hazy(PostStack.DistortionMask.Full, 3.0), samplePoints()),
                        offsetsAt(hazy(PostStack.DistortionMask.Full, 3.0), samplePoints()))

    @Test
    def testCpuOtherTimeDrawsAnotherPicture(): Unit \ Assert =
        Assert.assertEq(expected = false, offsetsAt(hazy(PostStack.DistortionMask.Full, 0.0), samplePoints()) == offsetsAt(hazy(PostStack.DistortionMask.Full, 0.5), samplePoints()))

    /// 模様が speed（design の px / 秒）で流れるか: 時刻 t の点 p のずれと、時刻 0 の点 p − speed × t のずれの差の最大（px）。
    def flowGap(speed: Vec2.Vec2, seconds: Float64): Float64 =
        let d = { speed = speed | haze(PostStack.DistortionMask.Full) };
        let stackAt = (sec: Float64) -> neutral() |> PostStack.withDistortion(Some(d)) |> PostStack.withTime(at(sec));
        let pts = samplePoints() |> List.filter(pt -> { let (u, v) = pt; u > 0.25 and u < 0.75 and v > 0.25 and v < 0.75 });
        let back = pts |> List.map(pt -> { let (u, v) = pt; (u - speed#x * seconds / size()#x, v - speed#y * seconds / size()#y) });
        List.zip(offsetsAt(stackAt(seconds), pts), offsetsAt(stackAt(0.0), back))
            |> List.map(e -> { let ((ax, ay), (bx, by)) = e; Float64.max(Float64.abs(ax - bx), Float64.abs(ay - by)) })
            |> List.maximum |> Option.getWithDefault(99.0)

    @Test
    def testCpuPatternFlowsUpAtTheSpeed(): Unit \ Assert =
        Assert.assertEq(expected = true, flowGap({ x = 0.0, y = -20.0 }, 0.5) < 0.2)

    @Test
    def testCpuPatternFlowsSidewaysAtTheSpeedOnAWideScreen(): Unit \ Assert =
        Assert.assertEq(expected = true, flowGap({ x = 30.0, y = 0.0 }, 0.5) < 0.2)

    @Test
    def testFlowAfterALongTimeKeepsThePhasesWithinOneTurn(): Unit \ Assert =
        let item = distortItem(hazy(PostStack.DistortionMask.Full, 1000000.0));
        let phases = List.range(0, 8) |> List.filterMap(i -> item |> Option.flatMap(it -> paramOf("ps_dph${i}", it)));
        let turn = 2.0 * 3.141592653589793;
        Assert.assertEq(expected = (8, true), (List.length(phases), List.forAll(ph -> ph >= 0.0 and ph < turn, phases)))

    @Test
    def testCpuDistortionNeverPassesTheStrength(): Unit \ Assert =
        let offs = List.range(0, 6) |> List.flatMap(i -> offsetsAt(hazy(PostStack.DistortionMask.Full, Int32.toFloat64(i) * 0.37), samplePoints()));
        Assert.assertEq(expected = true, List.forAll(o -> Float64.abs(fst(o)) <= 3.0 + 0.05 and Float64.abs(snd(o)) <= 2.0 + 0.05, offs))

    @Test
    def testCpuMissingMaskTextureLeavesThePictureStill(): Unit \ Assert =
        Assert.assertEq(expected = 0, offsetsAt(hazy(PostStack.DistortionMask.Texture("no_such_mask"), 1.0), samplePoints()) |> List.count(isMoved))

    // ── post.json の歪み ──

    def bandOf(m: PostStack.DistortionMask): (Float64, Float64) = match m {
        case PostStack.DistortionMask.BottomBand(b) => (b#top, b#soft)
        case _                                      => (-1.0, -1.0)
    }

    @Test
    def testDocReadsTheDistortion(): Unit \ Assert =
        let read = parsed("{\"distortion\": {\"strength\": [1.5, 0.5], \"noiseSize\": 30, \"mask\": {\"kind\": \"BottomBand\", \"top\": 0.6}}}")
            |> Result.toOption |> Option.flatMap(PostStack.distortionOf)
            |> Option.map(x -> (x#strength#x, x#strength#y, x#noiseSize, x#speed#y, bandOf(x#mask)));
        Assert.assertEq(expected = Some((1.5, 0.5, 30.0, -20.0, (0.6, 0.3))), read)

    @Test
    def testDocTextureMaskNeedsAName(): Unit \ Assert =
        Assert.assertEq(expected = true, Result.isErr(parsed("{\"distortion\": {\"mask\": {\"kind\": \"Texture\"}}}")))

    @Test
    def testDocWithoutDistortionHasNone(): Unit \ Assert =
        Assert.assertEq(expected = Some(true), parsed("{\"preset\": \"DuskOutdoor\"}") |> Result.toOption |> Option.map(x -> Option.isEmpty(PostStack.distortionOf(x))))

    // ── CRT のにじみ ──

    def crt(): PostStack.Crt = { compositeBlur = 1.5, scanlines = 0.3, chromaBleed = 2.0 }

    @Test
    def testCrtAllZeroKeepsThePlanAndThePicture(): Unit \ Assert =
        let off = { compositeBlur = 0.0, scanlines = 0.0, chromaBleed = 0.0 };
        Assert.assertEq(expected = planText(built(Nil, neutral())), planText(built(Nil, neutral() |> PostStack.withCrt(Some(off)))))

    @Test
    def testCrtDrawsThePostPass(): Unit \ Assert =
        let b = built(Nil, neutral() |> PostStack.withCrt(Some(crt())));
        Assert.assertEq(expected = PostStack.postName() :: Nil,
                        b#plan#passes |> List.map(p -> p#name) |> List.filter(n -> n != PostStack.sceneName()))

    @Test
    def testCrtPresentsTheCrtSurface(): Unit \ Assert =
        let b = built(Nil, neutral() |> PostStack.withCrt(Some(crt())));
        Assert.assertTrue(specOf(b#present) |> Option.exists(sp -> String.startsWith(prefix = "ps_crt:", sp#name)))

    @Test
    def testCrtAfterFxaaReadsTheFxaaPass(): Unit \ Assert =
        Assert.assertTrue(List.memberOf("ps_fxaa", passNames(neutral() |> PostStack.withFxaa(true) |> PostStack.withCrt(Some(crt())))))

    @Test
    def testDocReadsCrt(): Unit \ Assert =
        Assert.assertEq(expected = Some(Some(2.5)), parsed("{\"crt\": {\"compositeBlur\": 2.5}}") |> Result.toOption |> Option.map(x -> PostStack.crtOf(x) |> Option.map(c -> c#compositeBlur)))
}

// 奥行きのぼかしの奥行きの絵（PostStack.Internal.Passes.depthItemOf）が、場面の描く物を全部写すか。
mod PostStack.Internal.Passes.TestDepthItem {

    /// 奥行きの絵の場面は、元の場面の MultiMesh を持つ（落とすと奥行きのぼかしで MultiMesh の物が消える）。
    @Test
    def testDepthSceneKeepsMultiMeshes(): Unit \ Assert =
        let tri = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        let crowd = MultiMesh3d.build(tri, 3, i -> Mat4.translate(Vec3.v3(Int32.toFloat64(i), 0.0, 0.0)));
        let camera = { eye = Vec3.v3(0.0, 0.0, -5.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() };
        let scene = { multiMeshes = crowd :: Nil | Scene3d.scene(camera, Vec2.v2(32.0, 32.0)) };
        let kept = match PostStack.Internal.Passes.depthItemOf((Vec2.zero(), scene), 0.5, 10.0, false)#item {
            case Render.Item.Scene3d(cmd) => List.sumWith(MultiMesh3d.countOf, cmd#multiMeshes)
            case _                        => -1
        };
        Assert.assertEq(expected = 3, kept)
}
