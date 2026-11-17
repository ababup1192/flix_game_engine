// App.withLetterboxView: 窓の比が design と違うコマだけ、その絵を Pass へ描いてから描き手に余りへ広げるよう頼む所（App.Internal.Paint.renderFrame）。

mod TestLetterboxView {

    def design(): Vec2.Vec2 = { x = 8.0, y = 8.0 }

    /// design と同じ比の窓（余りが無い）。
    def square(): Display.Display = Display.desktop(design())

    /// design の倍の幅の窓（左右に余りが出る）。
    def wide(): Display.Display = { size = { x = 16.0, y = 8.0 } | Display.desktop(design()) }

    def atlas(): FontAtlas =
        { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    def drawing(app: App[Int32, ef]): App[Int32, ef] =
        app |> App.withView((_ctx, _world) -> checked_ecast(Nil))

    def withLetterbox(app: App[Int32, ef]): App[Int32, ef] =
        app |> App.withLetterboxView((_ctx, _world) -> checked_ecast(Nil))

    /// display の窓で app の 1 コマを流し、描き手が受けた op の並び（begin:<名前> = Pass を開く・render = renderCommands・letterbox:<名前> = fillLetterbox）。
    def opsOn(display: Display.Display, app: App[Int32, {}]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        let note = s -> Ref.put(s :: Ref.get(log), log);
        run {
            discard App.Internal.Paint.renderFrame(app, _ -> (), None, design(), display, 0,
                                                   App.Internal.Paint.plainLook(Nil), App.Internal.Paint.freshTileCache(), None, false)
        } with handler RenderTarget.Target {
            def beginTarget(spec, k) = { note("begin:${spec#name}"); k(()) }
            def endTarget(k) = k(())
            def pixelScale(k) = k(1.0)
        } with handler Platform.Draw2d {
            def renderCommands(_sprites, _tileMaps, _polygons, _staticLayer, k) = { note("render"); k(()) }
            def drawSurface(_cmd, k) = k(())
            def fillLetterbox(texture, k) = { note("letterbox:${texture}"); k(()) }
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
        List.reverse(Ref.get(log))

    /// 余りのある窓では、絵を Pass に描き、広げる頼みを本編の renderCommands より先に出す。
    @Test
    def testWideWindowPaintsLetterboxBeforeTheScreen(): Unit \ {Assert, IO} =
        let name = App.Internal.Paint.letterboxTarget();
        Assert.assertEq(expected = "begin:${name}" :: "render" :: "letterbox:${name}" :: "render" :: Nil,
                        opsOn(wide(), App.make(0) |> drawing |> withLetterbox))

    /// 窓の比が design と同じなら、絵を描かず頼みも出さない。
    @Test
    def testSameAspectSkipsTheLetterbox(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "render" :: Nil, opsOn(square(), App.make(0) |> drawing |> withLetterbox))

    /// withLetterboxView の無い App は、余りのある窓でも頼みを出さない（余りは描き手が黒で塗る）。
    @Test
    def testNoLetterboxViewSendsNothing(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "render" :: Nil, opsOn(wide(), App.make(0) |> drawing))

    /// design の倍の幅の窓には余りがある。
    @Test
    def testWideWindowIsLetterboxed(): Unit \ Assert =
        Assert.assertTrue(App.Internal.Paint.isLetterboxed(wide(), design()))

    /// 比の違いが 0.5% 以内の窓は余りと見なさない。
    @Test
    def testTinyDifferenceIsNotLetterboxed(): Unit \ Assert =
        Assert.assertFalse(App.Internal.Paint.isLetterboxed({ size = { x = 8.02, y = 8.0 } | Display.desktop(design()) }, design()))
}
