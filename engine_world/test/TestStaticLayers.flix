// App.withStaticLayers / withStaticLayer: 宣言した層が、1 コマの renderCommands の第 4 チャンネルへどう渡るか（App.Internal.Paint.renderFrame）。

mod TestStaticLayers {

    def design(): Vec2.Vec2 = { x = 8.0, y = 8.0 }

    def atlas(): FontAtlas =
        { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    def drawing(app: App[Int32, ef]): App[Int32, ef] =
        app |> App.withView((_ctx, _world) -> checked_ecast(Nil))

    /// 四角 1 つの PlacedItem（多角形チャンネルへ行く）。
    def square(): List[Render.PlacedItem] =
        { at = Vec2.zero(),
          item = RawDraw.polygon({ x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 4.0, y = 4.0 } :: Nil, Color.rgb(1.0, 1.0, 1.0), 0) } :: Nil

    /// world の 1 コマを流し、描き手が受けた静的層の依頼（id・key）と、知らせの並びを返す。
    def layersOf(app: App[Int32, {}], world: Int32): (List[(String, String)], List[String]) \ IO =
        let got = Ref.fresh(Static, Nil);
        let warned = Ref.fresh(Static, Nil);
        run {
            discard App.Internal.Paint.renderFrame(app, s -> unsafe IO { Ref.put(s :: Ref.get(warned), warned) }, None, design(),
                                                   Display.desktop(design()), world,
                                                   App.Internal.Paint.plainLook(Nil), App.Internal.Paint.freshTileCache(), None, false)
        } with handler RenderTarget.Target {
            def beginTarget(_spec, k) = k(())
            def endTarget(k) = k(())
            def pixelScale(k) = k(1.0)
        } with handler Platform.Draw2d {
            def renderCommands(_sprites, _tileMaps, _polygons, staticLayers, k) = {
                Ref.put(List.map(l -> (l#id, l#key), staticLayers), got);
                k(())
            }
            def drawSurface(_cmd, k) = k(())
            def fillLetterbox(_texture, k) = k(())
        } with handler Platform.Draw3d {
            def drawScene3d(_cmd, k) = k(())
            def preload3d(_cmd, k) = k(())
        } with handler Platform.GpuResources {
            def initTileBuffer(_instances, _k) = bug!("unused")
            def updateTileBuffer(_vaoId, _instances, _k) = bug!("unused")
            def ensureTexture(_name, _key, _w, _h, _argb, k) = k(())
            def ensureGlyphs(_textureName, _codepoints, k) = k(())
            def getFontAtlas(_name, k) = k(atlas())
            def getTextureInfo(_name, k) = k(None)
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
        };
        (Ref.get(got), Ref.get(warned))

    /// withStaticLayer は id "" の層 1 つとして渡る。
    @Test
    def testSingleLayerHasEmptyId(): Unit \ {Assert, IO} =
        let app = App.make(0) |> drawing |> App.withStaticLayer(w -> "floor-${Int32.toString(w)}", _ -> square());
        Assert.assertEq(expected = ("", "floor-3") :: Nil, fst(layersOf(app, 3)))

    /// withStaticLayers は宣言の並びのまま id と key を渡す。
    @Test
    def testLayersKeepDeclaredOrder(): Unit \ {Assert, IO} =
        let app = App.make(0) |> drawing |> App.withStaticLayers(w ->
            { id = "b", key = "kb${Int32.toString(w)}", items = () -> square() } ::
            { id = "a", key = "ka", items = () -> square() } :: Nil);
        Assert.assertEq(expected = ("b", "kb1") :: ("a", "ka") :: Nil, fst(layersOf(app, 1)))

    /// 1 コマを流しても items は呼ばない（作り直すかは描き手が key で決める）。
    @Test
    def testItemsAreNotBuiltBySubmit(): Unit \ {Assert, IO} =
        let app = App.make(0) |> drawing |> App.withStaticLayers(_ ->
            { id = "a", key = "k", items = () -> bug!("items は描き手が作り直す時だけ呼ぶ") } :: Nil);
        Assert.assertEq(expected = ("a", "k") :: Nil, fst(layersOf(app, 0)))

    /// 同じ id が 2 度並ぶと知らせる。
    @Test
    def testDuplicateIdWarns(): Unit \ {Assert, IO} =
        let app = App.make(0) |> drawing |> App.withStaticLayers(_ ->
            { id = "a", key = "k1", items = () -> square() } ::
            { id = "a", key = "k2", items = () -> square() } :: Nil);
        Assert.assertEq(expected = 1, List.length(snd(layersOf(app, 0))))

    /// 後に呼んだ withStaticLayer が withStaticLayers を置き換える。
    @Test
    def testLaterDeclarationWins(): Unit \ {Assert, IO} =
        let app = App.make(0) |> drawing
                  |> App.withStaticLayers(_ -> { id = "a", key = "k", items = () -> square() } :: Nil)
                  |> App.withStaticLayer(_ -> "only", _ -> square());
        Assert.assertEq(expected = ("", "only") :: Nil, fst(layersOf(app, 0)))
}
