// View に初めて出た staticGroup を engine が先に作り、済むまで場面から外して黒で覆う所（App.Internal.Paint.renderFrame → App.Internal.AutoPreload）。

mod TestAutoPreload3d {

    def design(): Vec2.Vec2 = { x = 8.0, y = 8.0 }

    def atlas(): FontAtlas =
        { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 10.0, lensShift = Vec2.zero() }

    /// groups を載せた空の場面。
    def sceneWith(groups: List[Scene3d.StaticGroup]): Scene3d.Scene3dCmd = { groups = groups | Scene3d.scene(camera(), design()) }

    def placed(groups: List[Scene3d.StaticGroup]): Render.PlacedItem = Render.scene3d(Vec2.zero(), sceneWith(groups))

    def notYet(): Scene3d.PreloadProgress = { done = 0, total = 1 }

    def finished(): Scene3d.PreloadProgress = { done = 1, total = 1 }

    def nameOf(g: Scene3d.StaticGroup): String = Scene3d.staticGroupFieldsOf(g)#name

    /// 1 コマの記録。key と preloaded と scenes = 描き手が受けた宣言の key と groups の名前と scenes の数（宣言が無ければ None）・
    /// drawn = 描いた場面ごとの groups の名前・covered = ZBand.autoPreloadCover の z の描き物があったか。
    type alias Shot = { key = Option[String], preloaded = Option[List[String]], scenes = Option[Int32], drawn = List[List[String]], covered = Bool }

    def isCover(d: DrawCmd.Drawable): Bool = DrawCmd.zIndexOf(d) == ZBand.autoPreloadCover()

    /// app のコマを frames（World・描き手が返す進み具合・Doc を読み直したか）の順に流した記録と、知らせの数。
    def runFrames(app: App[Int32, {}], frames: List[(Int32, Scene3d.PreloadProgress, Bool)]): (List[Shot], Int32) \ IO =
        let warned = Ref.fresh(Static, 0);
        let warn = (_: String) -> unsafe IO { Ref.put(Ref.get(warned) + 1, warned) };
        let (_, shots) = List.foldLeft((acc, f) -> {
            let (cache, done) = acc;
            let (world, progress, reload) = f;
            let (next, shot) = oneFrame(app, warn, world, progress, App.Internal.Paint.bumpTileGen(reload, cache));
            (next, shot :: done)
        }, (App.Internal.Paint.freshTileCache(), Nil), frames);
        (List.reverse(shots), Ref.get(warned))

    def oneFrame(app: App[Int32, {}], warn: String -> Unit, world: Int32, progress: Scene3d.PreloadProgress, cache: App.Internal.Paint.TileCache):
            (App.Internal.Paint.TileCache, Shot) \ IO =
        let shot = Ref.fresh(Static, { key = None, preloaded = None, scenes = None, drawn = Nil, covered = false });
        let next = RenderTarget.runNoop(() -> run {
            let (c, _, _) = App.Internal.Paint.renderFrame(app, warn, None, design(), Display.desktop(design()), world,
                                                           App.Internal.Paint.plainLook(Nil), cache, None, false);
            c
        } with handler Platform.Draw2d {
            def renderCommands(sprites, _tileMaps, polygons, _staticLayers, k) = {
                let hit = List.exists(isCover, sprites) or List.exists(p -> p#zIndex == ZBand.autoPreloadCover(), polygons);
                Ref.put({ covered = Ref.get(shot)#covered or hit | Ref.get(shot) }, shot);
                k(())
            }
            def drawSurface(_cmd, k) = k(())
            def fillLetterbox(_texture, k) = k(())
        } with handler Platform.Draw3d {
            def drawScene3d(cmd, k) = {
                Ref.put({ drawn = List.append(Ref.get(shot)#drawn, List.map(nameOf, cmd#scene#groups) :: Nil) | Ref.get(shot) }, shot);
                k(())
            }
            def preload3d(cmd, k) = {
                Ref.put({ key = Some(cmd#key), preloaded = Some(List.map(nameOf, (cmd#groups)())), scenes = Some(List.length((cmd#scenes)())) | Ref.get(shot) }, shot);
                k(progress)
            }
        } with handler Platform.GpuResources {
            def initTileBuffer(_instances, _k) = bug!("unused")
            def updateTileBuffer(_vaoId, _instances, _k) = bug!("unused")
            def ensureTexture(_name, _key, _w, _h, _argb, k) = k(())
            def ensureGlyphs(_textureName, _codepoints, k) = k(())
            def getFontAtlas(_name, k) = k(atlas())
            def getTextureInfo(_name, k) = k(None)
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
        });
        (next, Ref.get(shot))

    /// world の値ごとに items を返す App。
    def viewing(items: Int32 -> List[Render.PlacedItem]): App[Int32, {}] = App.make(0) |> App.withView((_ctx, world) -> items(world))

    /// world が 0 なら何も載せず、ほかは g を載せた場面を 1 つ返す App。
    def showing(g: Scene3d.StaticGroup): App[Int32, {}] = viewing(world -> if (world == 0) Nil else placed(g :: Nil) :: Nil)

    def plain(world: Int32, progress: Scene3d.PreloadProgress): (Int32, Scene3d.PreloadProgress, Bool) = (world, progress, false)

    def coveredOf(shots: List[Shot]): List[Bool] = List.map(s -> s#covered, shots)

    /// 初めての名前は、済むまで場面から外れ、描き手への宣言に足され、黒で覆われる。
    @Test
    def testFirstNameIsStrippedAndCovered(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g), plain(1, notYet()) :: Nil);
        Assert.assertEq(expected = Some((Some("a" :: Nil), Some(1), Nil :: Nil, true)), shots |> List.head |> Option.map(s -> (s#preloaded, s#scenes, s#drawn, s#covered)))

    /// 黒の z は HUD の範囲より手前で、待ちの表示（波紋・輪・Custom）より奥。
    @Test
    def testCoverSitsBetweenHudAndLoading(): Unit \ Assert =
        Assert.assertEq(expected = (true, true), (ZBand.autoPreloadCover() > ZBand.hudBase() + ZBand.innerMax(), ZBand.autoPreloadCover() < ZBand.loadingBase()))

    /// 前のコマで外して済んだコマは、集まりを載せて黒だけ残し、次のコマで明ける。
    @Test
    def testDoneFrameDrawsUnderTheCoverThenClears(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g), plain(1, notYet()) :: plain(1, finished()) :: plain(1, finished()) :: Nil);
        Assert.assertEq(expected = ((Nil :: Nil, true) :: (("a" :: Nil) :: Nil, true) :: (("a" :: Nil) :: Nil, false) :: Nil), shots |> List.map(s -> (s#drawn, s#covered)))

    /// 最初のコマで済めば（前のコマが黒でなければ）黒を出さない。
    @Test
    def testDoneOnTheFirstFrameNeverCovers(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g), plain(1, finished()) :: Nil);
        Assert.assertEq(expected = Some(((("a" :: Nil) :: Nil), false)), shots |> List.head |> Option.map(s -> (s#drawn, s#covered)))

    /// 描き手が先に作らない（撮る文脈・CPU の描き手）と、黒にならない。
    @Test
    def testNoPreloadRendererNeverCovers(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g), plain(1, Scene3d.noPreload()) :: plain(1, Scene3d.noPreload()) :: Nil);
        Assert.assertEq(expected = false :: false :: Nil, coveredOf(shots))

    /// 宣言と同じ名前の集まりは自動の宣言に足さず、宣言が済むまで外れて黒・済めば明ける。
    @Test
    def testDeclaredNameIsNotAddedTwiceButCovers(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let app = showing(g) |> App.withPreload3d({ groups = _ -> g :: Nil, scenes = _ -> sceneWith(Nil) :: Nil | App.preload3d(_ -> "k", _ -> Nil) });
        let (shots, _) = runFrames(app, plain(1, notYet()) :: plain(1, finished()) :: plain(1, finished()) :: Nil);
        Assert.assertEq(expected = (Some("a" :: Nil), true :: true :: false :: Nil), (shots |> List.head |> Option.flatMap(s -> s#preloaded), coveredOf(shots)))

    /// 一度済んだ宣言の名前は、宣言の key が替わって済まない間に 120 コマ以上ぶりに出ても黒にならない。
    @Test
    def testReadyDeclaredNameStaysReadyAfterTheKeyChanges(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let app = showing(g) |> App.withPreload3d({ groups = _ -> g :: Nil, scenes = _ -> sceneWith(Nil) :: Nil | App.preload3d(world -> if (world == 1) "k1" else "k2", _ -> Nil) });
        let away = List.repeat(130, plain(0, notYet()));
        let (shots, _) = runFrames(app, plain(1, finished()) :: List.append(away, plain(2, notYet()) :: Nil));
        Assert.assertEq(expected = Some(false), shots |> List.last |> Option.map(s -> s#covered))

    /// 宣言の場面に同じ版がある時は自動の場面を足さず、無い版の時だけ足す。
    @Test
    def testAutoSceneIsAddedOnlyForAMissingVariant(): Unit \ {Assert, IO} =
        let a = Scene3d.staticGroup("a", Nil);
        let physical = (gs: List[Scene3d.StaticGroup]) -> Render.scene3d(Vec2.zero(), { lightUnits = Scene3d.LightUnits.Physical | sceneWith(gs) });
        let app = viewing(world -> if (world == 1) placed(a :: Nil) :: Nil else physical(a :: Nil) :: Nil)
            |> App.withPreload3d({ scenes = _ -> sceneWith(Nil) :: Nil | App.preload3d(_ -> "k", _ -> Nil) });
        let (same, _) = runFrames(app, plain(1, notYet()) :: Nil);
        let (other, _) = runFrames(app, plain(2, notYet()) :: Nil);
        Assert.assertEq(expected = (Some(1), Some(2)), (same |> List.head |> Option.flatMap(s -> s#scenes), other |> List.head |> Option.flatMap(s -> s#scenes)))

    /// 同じ集まりを本編と Pass の場面で描いても、自動の宣言は 1 つで、済めば明ける。
    @Test
    def testGroupInPassAndMainIsAddedOnce(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let app = showing(g) |> App.withPassPlan(_ -> Render.passPlan({ name = "mirror", clear = RenderTarget.LoadOp.ClearTransparent, items = placed(g :: Nil) :: Nil } :: Nil));
        let (shots, _) = runFrames(app, plain(1, notYet()) :: plain(1, finished()) :: plain(1, finished()) :: Nil);
        Assert.assertEq(expected = (Some("a" :: Nil), true :: true :: false :: Nil), (shots |> List.head |> Option.flatMap(s -> s#preloaded), coveredOf(shots)))

    /// Clipped の中の場面の集まりも拾って外す。
    @Test
    def testClippedSceneIsStripped(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let clipped = { at = Vec2.zero(), item = Render.Item.Clipped({ rect = { position = Vec2.zero(), size = design() }, inner = Render.Item.Scene3d(sceneWith(g :: Nil)) }) };
        let (shots, _) = runFrames(viewing(_ -> clipped :: Nil), plain(1, notYet()) :: Nil);
        Assert.assertEq(expected = Some((Some("a" :: Nil), Nil :: Nil)), shots |> List.head |> Option.map(s -> (s#preloaded, s#drawn)))

    /// 作っている名前が View から消えても、済むまで黒が続く。
    @Test
    def testBuildingNameKeepsTheCoverAfterLeavingTheView(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g), plain(1, notYet()) :: plain(0, notYet()) :: plain(1, notYet()) :: Nil);
        Assert.assertEq(expected = true :: true :: true :: Nil, coveredOf(shots))

    /// 作り終えた名前で items の参照だけ替わった集まりは、外さず・黒にせず・宣言に足さない。
    @Test
    def testReadyNameWithANewValueIsLeftToTheRenderer(): Unit \ {Assert, IO} =
        let first = Scene3d.staticGroup("a", Nil);
        let second = Scene3d.staticGroup("a", Nil);
        let app = viewing(world -> if (world == 1) placed(first :: Nil) :: Nil else placed(second :: Nil) :: Nil);
        let (shots, _) = runFrames(app, plain(1, finished()) :: plain(2, notYet()) :: Nil);
        Assert.assertEq(expected = Some((None, ("a" :: Nil) :: Nil, false)), shots |> List.last |> Option.map(s -> (s#preloaded, s#drawn, s#covered)))

    /// 作り終えた名前が 120 コマ出ず、また出た時は作っている名前に戻り、描き手がそのコマで済んだと返せば黒を出さない。
    @Test
    def testForgottenNameIsRequestedAgainWithoutCover(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let away = List.repeat(120, plain(0, finished()));
        let (shots, _) = runFrames(showing(g), plain(1, finished()) :: List.append(away, plain(1, finished()) :: Nil));
        Assert.assertEq(expected = Some((Some("a" :: Nil), false)), shots |> List.last |> Option.map(s -> (s#preloaded, s#covered)))

    /// 作っている間に値が替われば、宣言に足すのは最新の値 1 つで、宣言の key が替わる。
    @Test
    def testBuildingValueIsReplaced(): Unit \ {Assert, IO} =
        let first = Scene3d.staticGroup("a", Nil);
        let second = Scene3d.staticGroup("a", Nil) |> Scene3d.withGroupTint(Color.rgb(1.0, 0.0, 0.0));
        let app = viewing(world -> if (world == 1) placed(first :: Nil) :: Nil else placed(second :: Nil) :: Nil);
        let (shots, _) = runFrames(app, plain(1, notYet()) :: plain(2, notYet()) :: Nil);
        let keys = shots |> List.map(s -> s#key);
        Assert.assertEq(expected = (Some("a" :: Nil), true), (shots |> List.last |> Option.flatMap(s -> s#preloaded), List.head(keys) != List.last(keys)))

    /// 名前が替わり続けたら 20 回目のコマで自動をやめ、知らせは 1 回で、そのコマで黒が明ける。
    @Test
    def testChangingNamesStopTheAutoPreload(): Unit \ {Assert, IO} =
        let app = viewing(world -> placed(Scene3d.staticGroup("n${world}", Nil) :: Nil) :: Nil);
        let (shots, warned) = runFrames(app, List.range(1, 26) |> List.map(i -> plain(i, notYet())));
        Assert.assertEq(expected = (1, Some(true), Some(false)), (warned, shots |> List.drop(18) |> List.head |> Option.map(s -> s#covered), shots |> List.drop(19) |> List.head |> Option.map(s -> s#covered)))

    /// Doc を読み直したコマで名前が替わっても数えない。
    @Test
    def testReloadFramesAreNotCounted(): Unit \ {Assert, IO} =
        let app = viewing(world -> placed(Scene3d.staticGroup("n${world}", Nil) :: Nil) :: Nil);
        let (_, warned) = runFrames(app, List.range(1, 26) |> List.map(i -> (i, notYet(), true)));
        Assert.assertEq(expected = 0, warned)

    /// 宣言の key が黒の途中で替わっても、作っている名前があれば黒は続く。
    @Test
    def testDeclaredKeyChangeKeepsTheCover(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let app = viewing(_ -> placed(g :: Nil) :: Nil) |> App.withPreload3d(App.preload3d(world -> "k${world}", _ -> Nil));
        let (shots, _) = runFrames(app, plain(1, notYet()) :: plain(2, notYet()) :: plain(3, notYet()) :: Nil);
        Assert.assertEq(expected = true :: true :: true :: Nil, coveredOf(shots))

    /// PopIn は作っている間に集まりを外すが、黒は出さない。
    @Test
    def testPopInStripsWithoutCover(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g) |> App.withAutoPreload3d(App.AutoPreload3d.PopIn), plain(1, notYet()) :: Nil);
        Assert.assertEq(expected = Some((Nil :: Nil, false)), shots |> List.head |> Option.map(s -> (s#drawn, s#covered)))

    /// Off は先に作る宣言を出さず、集まりはそのまま描く。
    @Test
    def testOffLeavesTheSceneAlone(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("a", Nil);
        let (shots, _) = runFrames(showing(g) |> App.withAutoPreload3d(App.AutoPreload3d.Off), plain(1, notYet()) :: Nil);
        Assert.assertEq(expected = Some((None, ("a" :: Nil) :: Nil, false)), shots |> List.head |> Option.map(s -> (s#preloaded, s#drawn, s#covered)))

    /// 集まりの無い場面は宣言を出さない。
    @Test
    def testNoGroupsSendsNoRequest(): Unit \ {Assert, IO} =
        let (shots, _) = runFrames(viewing(_ -> placed(Nil) :: Nil), plain(1, notYet()) :: Nil);
        Assert.assertEq(expected = Some((None, false)), shots |> List.head |> Option.map(s -> (s#preloaded, s#covered)))
}
