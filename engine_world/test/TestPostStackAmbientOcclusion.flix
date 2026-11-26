// PostStack の SSAO（withAmbientOcclusion）を具体値で固定する: 奥行きの Pass（ps_depth_far）を場面の色より先に R32Float で置くか・
// 画面の上の技の入力を一番大きい場面にだけ入れるか・霧と奥行きのぼかしがその 1 枚を読むか・post.json の欄・Low の丸め。
mod TestPostStackAmbientOcclusion {

    def size(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(0.0, 2.0, 10.0), yaw = 0.0, pitch = 0.0, fovY = 0.8, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    def sceneOf(w: Float64): Render.PlacedItem = Render.scene3d(Vec2.zero(), Scene3d.scene(camera(), { x = w, y = 180.0 }))

    def built(world: List[Render.PlacedItem], s: PostStack.Stack): { plan = Render.PassPlan, present = Render.PlacedItem, issues = List[PostStack.Issue] } =
        PostStack.build({ size = size(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, s)

    def withAo(): PostStack.Stack = PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withAmbientOcclusion(Some(PostStack.ambientOcclusion()))

    def passNames(s: PostStack.Stack): List[String] = built(sceneOf(320.0) :: Nil, s)#plan#passes |> List.map(p -> p#name)

    /// Pass name の中の 3D の場面の画面の上の技の入力（場面ごと・並びの順）。
    def screenInputsIn(plan: Render.PassPlan, name: String): List[Option[Scene3d.ScreenInputs]] =
        plan#passes |> List.filter(p -> p#name == name) |> List.flatMap(p -> p#items) |> List.flatMap(i -> match i#item {
            case Render.Item.Scene3d(cmd) => cmd#screenInputs :: Nil
            case _                        => Nil
        })

    def fog(): PostStack.HeightFog = PostStack.heightFog()

    @Test
    def testAmbientOcclusionDrawsTheFarDepthBeforeTheScene(): Unit \ Assert =
        Assert.assertEq(expected = "ps_depth_far" :: "ps_scene" :: Nil, passNames(withAo()))

    @Test
    def testFarDepthIsR32Float(): Unit \ Assert =
        Assert.assertEq(expected = RenderTarget.Format.R32Float, Render.targetDescriptorOf(built(sceneOf(320.0) :: Nil, withAo())#plan, "ps_depth_far")#format)

    @Test
    def testFarDepthHasOneSample(): Unit \ Assert =
        let s = withAo() |> PostStack.withMsaa(PostStack.Msaa.X4);
        Assert.assertEq(expected = 1, Render.targetDescriptorOf(built(sceneOf(320.0) :: Nil, s)#plan, "ps_depth_far")#samples)

    @Test
    def testWithoutAmbientOcclusionTheSceneHasNoScreenInputs(): Unit \ Assert =
        let plan = built(sceneOf(320.0) :: Nil, PostStack.preset(PostStack.Preset.Neutral))#plan;
        Assert.assertEq(expected = 0, List.length(List.filter(Option.nonEmpty, screenInputsIn(plan, "ps_scene"))))

    @Test
    def testOnlyTheLargestSceneGetsScreenInputs(): Unit \ Assert =
        let plan = built(sceneOf(100.0) :: sceneOf(320.0) :: Nil, withAo())#plan;
        Assert.assertEq(expected = false :: true :: Nil, screenInputsIn(plan, "ps_scene") |> List.map(Option.nonEmpty))

    @Test
    def testScreenInputsReadTheFarDepthPass(): Unit \ Assert =
        let found = screenInputsIn(built(sceneOf(320.0) :: Nil, withAo())#plan, "ps_scene") |> List.filterMap(x -> x) |> List.map(i -> Scene3d.screenInputsFieldsOf(i)#depth);
        Assert.assertEq(expected = "ps_depth_far" :: Nil, found)

    @Test
    def testDepthRangeReachesTheFarCorner(): Unit \ Assert =
        Assert.assertTrue(Scene3d.Internal.ScreenInputs.depthRangeOf(camera(), size()) > camera()#far)

    @Test
    def testFogReadsTheFarDepthInsteadOfItsOwn(): Unit \ Assert =
        Assert.assertEq(expected = "ps_depth_far" :: "ps_scene" :: "ps_fog" :: Nil, passNames(withAo() |> PostStack.withHeightFog(Some(fog()))))

    @Test
    def testPhysicalFocusReadsTheFarDepthInsteadOfItsOwn(): Unit \ Assert =
        let s = withAo() |> PostStack.withDepthOfField(Some(PostStack.DepthOfField.Physical({ focusDistance = 5.0, fStop = 2.0 })));
        Assert.assertFalse(List.memberOf("ps_depth", passNames(s)))

    @Test
    def testDepthBandWithFogKeepsTwoDepthDraws(): Unit \ Assert =
        let s = withAo() |> PostStack.withHeightFog(Some(fog()))
                |> PostStack.withDepthOfField(Some(PostStack.DepthOfField.DepthBand({ focusDistance = 10.0, range = 4.0, band = 0.25, soft = 0.5, blur = 0.004 })));
        Assert.assertEq(expected = (true, true, false), (List.memberOf("ps_depth_far", passNames(s)), List.memberOf("ps_depth", passNames(s)), List.memberOf("ps_fogdepth", passNames(s))))

    @Test
    def testDebugViewAsksTheRendererToShowTheMask(): Unit \ Assert =
        let plan = built(sceneOf(320.0) :: Nil, withAo() |> PostStack.withDebugView(PostStack.DebugView.AmbientOcclusion))#plan;
        let shows = screenInputsIn(plan, "ps_scene") |> List.filterMap(x -> x) |> List.map(i -> Scene3d.screenInputsFieldsOf(i)#show);
        Assert.assertEq(expected = Some(ScreenEffects3d.ScreenDebug.AmbientOcclusion) :: Nil, shows)

    @Test
    def testLowQualityHalvesTheMaskAndCapsTheTaps(): Unit \ Assert =
        let s = withAo() |> PostStack.withQuality(PostStack.Quality.Auto) |> PostStack.resolveQuality(Display.SizeClass.Small);
        Assert.assertEq(expected = Some((0.5, 6)), PostStack.ambientOcclusionOf(s) |> Option.map(a -> (a#scale, a#taps)))

    // ── post.json ──

    @Test
    def testDocReadsAmbientOcclusionRadius(): Unit \ Assert =
        let s = PostStack.parse("{\"ambientOcclusion\": {\"radius\": 0.25}}");
        Assert.assertEq(expected = Ok(Some(0.25)), s |> Result.map(x -> PostStack.ambientOcclusionOf(x) |> Option.map(a -> a#radius)))

    @Test
    def testDocNullRemovesAmbientOcclusion(): Unit \ Assert =
        let s = PostStack.parse("{\"ambientOcclusion\": {\"radius\": 0.25}}") |> Result.flatMap(_ -> PostStack.parse("{\"ambientOcclusion\": null}"));
        Assert.assertEq(expected = Ok(None), s |> Result.map(x -> PostStack.ambientOcclusionOf(x) |> Option.map(a -> a#radius)))
}
