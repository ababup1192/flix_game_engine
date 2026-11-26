// 撮る文脈で先に作らない口（handleDraw3d の ahead）と、engine_world が自動で先に作る場面を版で分ける決め方が描き手の持ち越しの行の版と同じ答えになる事。
// WebGPU は PC の Dawn で device を開いて確かめ、開かない機械では `[preload-ahead] SKIP:` の行を出して通す（TestWgslDawn と同じ）。
mod Render3d.TestPreloadAhead {
    import fge.webgpu.WebGpu

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0, lensShift = Vec2.zero() }

    def scene(): Scene3d.Scene3dCmd = Scene3d.scene(camera(), { x = 64.0, y = 64.0 })

    /// 四角 1 枚の集まり "floor" を scene で先に作る宣言。
    def floorCmd(): Scene3d.PreloadCmd =
        let quad = { points = Vec3.v3(-2.0, -2.0, 10.0) :: Vec3.v3(-2.0, 2.0, 10.0) :: Vec3.v3(2.0, 2.0, 10.0) :: Vec3.v3(2.0, -2.0, 10.0) :: Nil,
                     color = Color.rgb(0.8, 0.4, 0.2) };
        let group = Scene3d.staticGroup("floor", ("q", Scene3d.meshInstance(Mesh3d.fromPolygons(quad :: Nil), Mat4.identity())) :: Nil);
        { groups = () -> group :: Nil, scenes = () -> scene() :: Nil | Scene3d.preloadCmd("k", () -> Nil) }

    /// 先に作ると (1, 2) を返す描き手で作った GL の塗りのコアに、ahead で宣言を渡した答え。
    def glProgressOf(ahead: Bool): (Int32, Int32) \ IO =
        let renderer = { preload = (_, _, _) -> checked_ecast({ done = 1, total = 2 }) | Scene3dRenderer.none() };
        let paint = RenderPaint.create(FakeGl.silent(), { designWidth = 64, designHeight = 64, clearColor = Color.rgb(0.0, 0.0, 0.0),
                                                          screenFramebuffer = 0, scene3d = renderer, gpuTimer = RenderPaint.noFrameTimer() });
        let p = RenderPaintHandlers.handleDraw3d(ahead, paint, () -> Platform.Draw3d.preload3d(floorCmd()));
        (p#done, p#total)

    /// GL: ahead が偽なら描き手を呼ばず、済んだ進み具合（0 と 0）を返す。
    @Test
    def testGlSkipsPreloadWhenNotAhead(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = ((0, 0), (1, 2)), (glProgressOf(false), glProgressOf(true)))

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    /// WebGPU: ahead が偽なら済んだ進み具合（total 0）、真なら集まり × 場面の 1 つを作る進み具合（total 1）。
    @Test
    def testWebGpuSkipsPreloadWhenNotAhead(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[preload-ahead] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let totals = webGpuTotals(gpu);
                gpu.destroy();
                Assert.assertEq(expected = (0, 1), totals)
        }

    def webGpuTotals(gpu: WebGpu): (Int32, Int32) \ IO =
        let paint = RenderPaint.Internal.WebGpuPaint.create(gpu, { designWidth = 64, designHeight = 64, clearColor = Color.rgb(0.0, 0.0, 0.0), width = 64, height = 64,
                                                                    scene3d = Render3d.WebGpuRenderer.makeScenes });
        let skipped = RenderPaint.Internal.WebGpuPaint.handleDraw3d(false, paint, () -> Platform.Draw3d.preload3d(floorCmd()));
        let made = RenderPaint.Internal.WebGpuPaint.handleDraw3d(true, paint, () -> Platform.Draw3d.preload3d(floorCmd()));
        RenderPaint.Internal.WebGpuPaint.release(paint);
        (skipped#total, made#total)

    /// engine_world の自動の場面の版（色の場面は "color" + preloadVariantKey(preloadVariantOf)・奥行きの書き出しは "depth"）が、
    /// 描き手の持ち越しの行の版（coverage を除く carriedKeyOf）と同じ字になる。
    @Test
    def testAutoSceneVariantMatchesCarriedKey(): Unit \ Assert =
        let shadows = Scene3d.withPointShadows(Scene3d.pointShadowMap(), scene());
        let scenes = scene() :: { output = Scene3d.Output.Depth({ near = 1.0, range = 10.0 }) | scene() } :: shadows ::
                     { lightUnits = Scene3d.LightUnits.Physical | scene() } :: Scene3d.withPsx(Scene3d.psxPreset(), scene()) ::
                     { output = Scene3d.Output.Depth({ near = 1.0, range = 10.0 }) | shadows } :: Nil;
        let autoKeyOf = (s: Scene3d.Scene3dCmd) -> match s#output {
            case Scene3d.Output.Color    => "color" + Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(s))
            case Scene3d.Output.Depth(_) => "depth"
        };
        Assert.assertEq(expected = List.map(autoKeyOf, scenes), List.map(Render3d.StaticRows.carriedKeyOf(false), scenes))
}
