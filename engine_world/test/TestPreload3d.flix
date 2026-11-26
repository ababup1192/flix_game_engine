// App.withPreload3d の宣言を、描き手へ渡す頼みにする所（App.Internal.Paint.preloadCmd）。毎コマ読むのは key だけで、Doc の読み直しでも key が変わる。

mod TestPreload3d {

    /// World の値をそのまま key にし、instances を読むと止まる App。
    def appWithPlan(): App[Int32, ef] =
        App.make(0) |> App.withPreload3d({ textures = _ -> bug!("頼みを作る時は読まない") | App.preload3d(world -> "floor${world}", _ -> bug!("頼みを作る時は読まない")) })

    def keyOf(app: App[Int32, ef], docGen: Int32, world: Int32): Option[String] =
        App.Internal.Paint.preloadCmd(app, docGen, world) |> Option.map(cmd -> cmd#key)

    /// 宣言の無い App は何も頼まない。
    @Test
    def testNoPlanNoRequest(): Unit \ Assert =
        Assert.assertEq(expected = None, keyOf(App.make(0), 0, 1))

    /// ゲームの key が変わると、頼みの key も変わる。
    @Test
    def testGameKeyChangesTheKey(): Unit \ Assert =
        Assert.assertTrue(keyOf(appWithPlan(), 0, 1) != keyOf(appWithPlan(), 0, 2))

    /// Doc を読み直すと、ゲームの key が同じでも頼みの key が変わる。
    @Test
    def testDocReloadChangesTheKey(): Unit \ Assert =
        let cache = App.Internal.Paint.freshTileCache();
        let reloaded = App.Internal.Paint.bumpTileGen(true, cache);
        Assert.assertTrue(keyOf(appWithPlan(), cache#gen, 1) != keyOf(appWithPlan(), reloaded#gen, 1))

    /// 変種を足すと、ゲームの key が同じでも頼みの key が変わり、頼みに変種が乗る。
    @Test
    def testVariantsChangeTheKey(): Unit \ Assert =
        let ps = { pointShadows = true, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = false };
        let withVariants = App.make(0) |> App.withPreload3d({ variants = _ -> ps :: Nil | App.preload3d(_ -> "k", _ -> Nil) });
        let plain = App.make(0) |> App.withPreload3d(App.preload3d(_ -> "k", _ -> Nil));
        let variantsOf = (app: App[Int32, {}]) -> App.Internal.Paint.preloadCmd(app, 0, 1) |> Option.map(cmd -> List.map(Scene3d.preloadVariantKey, cmd#variants));
        Assert.assertEq(expected = (true, Some("+ps" :: Nil)), (keyOf(withVariants, 0, 1) != keyOf(plain, 0, 1), variantsOf(withVariants)))

    /// 頼みの instances は、その時の World でゲームの instances を読む。
    @Test
    def testInstancesReadTheWorld(): Unit \ Assert =
        let mesh = Mesh3d.fromPolygons(Nil);
        let app = App.make(0) |> App.withPreload3d(App.preload3d(_ -> "k", world -> List.repeat(world, Scene3d.meshInstance(mesh, Mat4.identity()))));
        let count = App.Internal.Paint.preloadCmd(app, 0, 3) |> Option.map(cmd -> List.length((cmd#instances)()));
        Assert.assertEq(expected = Some(3), count)

    // ── renderFrame の中の順 ──

    def design(): Vec2.Vec2 = { x = 8.0, y = 8.0 }

    def atlas(): FontAtlas =
        { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    def withOnePass(app: App[Int32, ef]): App[Int32, ef] =
        app |> App.withPassPlan(_ -> checked_ecast(Render.passPlan({ name = "pass", clear = RenderTarget.LoadOp.ClearTransparent, items = Nil } :: Nil)))

    def drawing(app: App[Int32, ef]): App[Int32, ef] =
        app |> App.withView((_ctx, _world) -> checked_ecast(Nil))

    def planned(app: App[Int32, ef]): App[Int32, ef] =
        app |> App.withPreload3d(App.preload3d(_ -> "k", _ -> Nil))

    /// app の 1 コマで描き手が受けた op の並び（preload3d はその key・render = renderCommands。Pass の分と画面の分で 2 回出る）。
    def opsWith(cache: App.Internal.Paint.TileCache, app: App[Int32, {}]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        RenderTarget.runNoop(() -> run {
            discard App.Internal.Paint.renderFrame(app, _ -> (), None, design(), Display.desktop(design()), 0,
                                                   App.Internal.Paint.plainLook(Nil), cache, None, false)
        } with handler Platform.Draw2d {
            def renderCommands(_sprites, _tileMaps, _polygons, _staticLayers, k) = { Ref.put("render" :: Ref.get(log), log); k(()) }
            def drawSurface(_cmd, k) = k(())
            def fillLetterbox(_texture, k) = k(())
        } with handler Platform.Draw3d {
            def drawScene3d(_cmd, k) = k(())
            def preload3d(cmd, k) = { Ref.put(cmd#key :: Ref.get(log), log); k(Scene3d.noPreload()) }
        } with handler Platform.GpuResources {
            def initTileBuffer(_instances, _k) = bug!("unused")
            def updateTileBuffer(_vaoId, _instances, _k) = bug!("unused")
            def ensureTexture(_name, _key, _w, _h, _argb, k) = k(())
            def ensureGlyphs(_textureName, _codepoints, k) = k(())
            def getFontAtlas(_name, k) = k(atlas())
            def getTextureInfo(_name, k) = k(None)
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
        });
        List.reverse(Ref.get(log))

    def opsOf(app: App[Int32, {}]): List[String] \ IO = opsWith(App.Internal.Paint.freshTileCache(), app)

    /// 頼みは Pass より先に出る（Pass の場面が読む物も、そのコマの頭で上がっている）。
    @Test
    def testPreloadComesBeforePasses(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "0:k" :: "render" :: "render" :: Nil, opsOf(App.make(0) |> drawing |> withOnePass |> planned))

    /// Doc の読み直しで世代が進むと、renderFrame の頼みの key に世代が入る。
    @Test
    def testRenderFramePassesTheDocGeneration(): Unit \ {Assert, IO} =
        let reloaded = App.Internal.Paint.bumpTileGen(true, App.Internal.Paint.freshTileCache());
        Assert.assertEq(expected = List.head("1:k" :: Nil), List.head(opsWith(reloaded, App.make(0) |> drawing |> planned)))

    /// 宣言の無い App は頼みを出さない。
    @Test
    def testNoPlanSendsNoRequest(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "render" :: "render" :: Nil, opsOf(App.make(0) |> drawing |> withOnePass))

    /// 頼みの groups と scenes は、その時の World でゲームの groups と scenes を読む。
    @Test
    def testGroupsAndScenesReadTheWorld(): Unit \ Assert =
        let group = Scene3d.staticGroup("floor", Nil);
        let scene = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 10.0, lensShift = Vec2.zero() }, design());
        let app = App.make(0) |> App.withPreload3d({ groups = world -> List.repeat(world, group), scenes = _ -> scene :: Nil | App.preload3d(_ -> "k", _ -> Nil) });
        let counts = App.Internal.Paint.preloadCmd(app, 0, 2) |> Option.map(cmd -> (List.length((cmd#groups)()), List.length((cmd#scenes)())));
        Assert.assertEq(expected = Some((2, 1)), counts)

    /// 描き手が返した進み具合は、次のコマの ViewCtx#preload3d に入る（最初のコマは、まだ済んでいない 0 / 1）。
    @Test
    def testProgressReachesTheNextViewCtx(): Unit \ {Assert, IO} =
        let seen = Ref.fresh(Static, Nil);
        let app = App.make(0) |> App.withView((ctx, _world) -> unsafe IO { Ref.put(ctx#preload3d :: Ref.get(seen), seen); Nil }) |> planned;
        let once = (cache: App.Internal.Paint.TileCache) -> RenderTarget.runNoop(() -> run {
            let (next, _, _) = App.Internal.Paint.renderFrame(app, _ -> (), None, design(), Display.desktop(design()), 0,
                                                              App.Internal.Paint.plainLook(Nil), cache, None, false);
            next
        } with handler Platform.Draw2d {
            def renderCommands(_sprites, _tileMaps, _polygons, _staticLayers, k) = k(())
            def drawSurface(_cmd, k) = k(())
            def fillLetterbox(_texture, k) = k(())
        } with handler Platform.Draw3d {
            def drawScene3d(_cmd, k) = k(())
            def preload3d(_cmd, k) = k({ done = 1, total = 2 })
        } with handler Platform.GpuResources {
            def initTileBuffer(_instances, _k) = bug!("unused")
            def updateTileBuffer(_vaoId, _instances, _k) = bug!("unused")
            def ensureTexture(_name, _key, _w, _h, _argb, k) = k(())
            def ensureGlyphs(_textureName, _codepoints, k) = k(())
            def getFontAtlas(_name, k) = k(atlas())
            def getTextureInfo(_name, k) = k(None)
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
        });
        discard once(once(App.Internal.Paint.freshTileCache()));
        Assert.assertEq(expected = (1, 2) :: (0, 1) :: Nil, Ref.get(seen) |> List.map(p -> (p#done, p#total)))

    /// view の無い App は描かないので、宣言があっても頼みを出さない。
    @Test
    def testNoViewSendsNoRequest(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, opsOf(App.make(0) |> planned))
}
