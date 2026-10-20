// DrawHash.computeKey: 同じ入力なら同じ鍵・絵に効く入力が 1 つでも違えば別の鍵・絵に効かない
// 入力（書き先のパス）は鍵を変えない・指紋が欠けたら鍵を作らない、を固定する。
mod TestDrawHash {

    def drawable(x: Float64): GameEngine.Drawable = sprite("hero", x)

    def sprite(texture: String, x: Float64): GameEngine.Drawable =
        DrawCmd.make({
            texture = texture, position = { x = x, y = 20.0 }, scale = { x = 16.0, y = 16.0 },
            rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0, centered = false,
            uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 }, zIndex = 0,
            style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil
        })

    def trailSprite(): GameEngine.Drawable = sprite("trail", 0.0)

    def polygon(grad: Option[List[DrawCmd.VertexTint]]): GameEngine.PolygonRenderCmd =
        { vertices = { x = 0.0, y = 0.0 } :: { x = 10.0, y = 0.0 } :: { x = 0.0, y = 10.0 } :: Nil,
          color = { r = 0.5, g = 0.2, b = 0.1 }, alpha = 1.0, zIndex = 1, clip = None,
          blend = DrawCmd.BlendMode.Normal, grad = grad }

    def atlas(advance: Float64): FontAtlas =
        { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0, ascent = 12.0, descent = 4.0,
          lineGap = 0.0,
          glyphs = Map#{ 65 => { xOff = 0.0, yOff = 0.0, glyphW = 8.0, glyphH = 12.0, advance = advance,
                                 s0 = 0.0, t0 = 0.0, s1 = 8.0, t1 = 12.0 } } }

    def surface(time: Float64): SoftRaster.SurfaceCmd =
        { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 64.0, y = 64.0 } },
          spec = ShaderDoc.waterVeins(), time = time, mask = Nil, zIndex = 2,
          blend = DrawCmd.BlendMode.Normal }

    def frame(): DrawHash.Frame =
        { req = { drawables = drawable(10.0) :: trailSprite() :: Nil, polygons = polygon(None) :: Nil,
                  design = { x = 320.0, y = 180.0 }, scale = 2, background = { r = 0.0, g = 0.0, b = 0.1 },
                  texturePath = Map#{ "hero" => "assets/hero.png" }, fontTtf = "assets/ui.ttf",
                  fontAtlas = atlas(8.0), outPath = "gallery/a.png",
                  shapeAntialias = false, textAntialias = true },
          surfaces = surface(0.5) :: Nil,
          extraFonts = Map#{ "font_girl" => { ttf = "assets/girl.ttf", atlas = atlas(9.0) } }, fontAntialias = Map.empty() }

    def inputs(): DrawHash.Inputs =
        { engine = "e1", runtime = "jvm1",
          files = Map#{ "assets/hero.png" => "h1", "assets/ui.ttf" => "u1", "assets/girl.ttf" => "g1" },
          images = Map#{ "trail" => "t1" } }

    def keyOf(i: DrawHash.Inputs, f: DrawHash.Frame): String =
        DrawHash.computeKey(i, DrawHash.PngEncoding.Plain, f) |> Option.map(DrawHash.toHex) |> Option.getWithDefault("none")

    def base(): String = keyOf(inputs(), frame())

    def differs(i: DrawHash.Inputs, f: DrawHash.Frame): Bool = keyOf(i, f) != base()

    // ── 同じ物は同じ ──

    @Test
    def testSameInputsGiveSameKey(): Unit \ Assert =
        Assert.assertEq(expected = base(), keyOf(inputs(), frame()))

    @Test
    def testKeyIsSha256Hex(): Unit \ Assert =
        Assert.assertEq(expected = 64, String.length(base()))

    @Test
    def testOutPathDoesNotChangeKey(): Unit \ Assert =
        let f = frame();
        Assert.assertFalse(differs(inputs(), { req = { outPath = "debug/video/f0001.png" | f#req } | f }))

    @Test
    def testFilePathDoesNotChangeKeyWhenContentIsSame(): Unit \ Assert =
        let f = frame();
        let i = inputs();
        Assert.assertFalse(differs({ files = Map.insert("/tmp/base/assets/hero.png", "h1", i#files) | i },
                                   { req = { texturePath = Map#{ "hero" => "/tmp/base/assets/hero.png" } | f#req } | f }))

    // ── 命令が違えば違う ──

    @Test
    def testDrawableMovedByTinyAmountChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { drawables = drawable(10.0001) :: trailSprite() :: Nil | f#req } | f }))

    @Test
    def testGradNoneAndEmptyAreDifferent(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { polygons = polygon(Some(Nil)) :: Nil | f#req } | f }))

    @Test
    def testSurfaceTimeChangesKey(): Unit \ Assert =
        Assert.assertTrue(differs(inputs(), { surfaces = surface(0.75) :: Nil | frame() }))

    @Test
    def testSurfaceSpecChangesKey(): Unit \ Assert =
        let s = surface(0.5);
        Assert.assertTrue(differs(inputs(), { surfaces = { spec = ShaderDoc.lavaVeins() | s } :: Nil | frame() }))

    // ── 命令に出ない入力が違えば違う ──

    @Test
    def testTextureContentChangesKey(): Unit \ Assert =
        let i = inputs();
        Assert.assertTrue(differs({ files = Map.insert("assets/hero.png", "h2", i#files) | i }, frame()))

    @Test
    def testUnusedTextureContentDoesNotChangeKey(): Unit \ Assert =
        let f = frame();
        let i = inputs();
        Assert.assertFalse(differs({ files = Map.insert("assets/tree.png", "x2", i#files) | i },
                                   { req = { texturePath = Map.insert("tree", "assets/tree.png", f#req#texturePath) | f#req } | f }))

    @Test
    def testUnusedPassImageDoesNotChangeKey(): Unit \ Assert =
        Assert.assertFalse(differs({ images = Map#{ "trail" => "t1", "other" => "o1" } | inputs() }, frame()))

    @Test
    def testFontTtfContentChangesKey(): Unit \ Assert =
        let i = inputs();
        Assert.assertTrue(differs({ files = Map.insert("assets/ui.ttf", "u2", i#files) | i }, frame()))

    @Test
    def testExtraFontTtfContentChangesKey(): Unit \ Assert =
        let i = inputs();
        Assert.assertTrue(differs({ files = Map.insert("assets/girl.ttf", "g2", i#files) | i }, frame()))

    @Test
    def testFontAtlasChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { fontAtlas = atlas(8.5) | f#req } | f }))

    @Test
    def testExtraFontAtlasChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { extraFonts = Map#{ "font_girl" => { ttf = "assets/girl.ttf", atlas = atlas(9.5) } } | f }))

    @Test
    def testFontAntialiasChangesKey(): Unit \ Assert =
        // 本ごとの字の縁の表を決めると、同じ命令でも別の絵になるので鍵が変わる（空の表は前と同じ鍵）。
        let f = frame();
        Assert.assertTrue(differs(inputs(), { fontAntialias = Map#{ "font_girl" => false } | f }))

    @Test
    def testPassImageChangesKey(): Unit \ Assert =
        Assert.assertTrue(differs({ images = Map#{ "trail" => "t2" } | inputs() }, frame()))

    @Test
    def testScaleChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { scale = 3 | f#req } | f }))

    @Test
    def testBackgroundChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { background = { r = 0.0, g = 0.0, b = 0.2 } | f#req } | f }))

    @Test
    def testShapeAntialiasChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { shapeAntialias = true | f#req } | f }))

    @Test
    def testTextAntialiasChangesKey(): Unit \ Assert =
        let f = frame();
        Assert.assertTrue(differs(inputs(), { req = { textAntialias = false | f#req } | f }))

    @Test
    def testEngineChangesKey(): Unit \ Assert =
        Assert.assertTrue(differs({ engine = "e2" | inputs() }, frame()))

    @Test
    def testRuntimeChangesKey(): Unit \ Assert =
        Assert.assertTrue(differs({ runtime = "jvm2" | inputs() }, frame()))

    @Test
    def testPngEncodingChangesKey(): Unit \ Assert =
        let filmstrip = DrawHash.computeKey(inputs(), DrawHash.PngEncoding.Filmstrip, frame())
            |> Option.map(DrawHash.toHex) |> Option.getWithDefault("none");
        Assert.assertTrue(filmstrip != base())

    // ── 指紋が欠けたら鍵を作らない ──

    @Test
    def testMissingFileDigestGivesNoKey(): Unit \ Assert =
        let i = inputs();
        Assert.assertEq(expected = "none", keyOf({ files = Map.remove("assets/hero.png", i#files) | i }, frame()))

    @Test
    def testEmptyEngineGivesNoKey(): Unit \ Assert =
        Assert.assertEq(expected = "none", keyOf({ engine = "" | inputs() }, frame()))

    // ── アトラスの覚え（computeKeyCached）は computeKey と同じ鍵 ──

    def cachedKeyOf(cache: DrawHash.AtlasCache, f: DrawHash.Frame): String \ IO =
        DrawHash.computeKeyCached(cache, inputs(), DrawHash.PngEncoding.Plain, f)
            |> Option.map(DrawHash.toHex) |> Option.getWithDefault("none")

    @Test
    def testCachedKeyEqualsKey(): Unit \ IO + Assert =
        Assert.assertEq(expected = base(), cachedKeyOf(DrawHash.freshAtlasCache(), frame()))

    @Test
    def testCachedKeyFromRememberedAtlasEqualsKey(): Unit \ IO + Assert =
        let cache = DrawHash.freshAtlasCache();
        let f = frame();
        discard cachedKeyOf(cache, f);
        Assert.assertEq(expected = base(), cachedKeyOf(cache, f))

    @Test
    def testCachedKeyFollowsChangedAtlas(): Unit \ IO + Assert =
        let cache = DrawHash.freshAtlasCache();
        discard cachedKeyOf(cache, frame());
        let f = frame();
        let changed = { req = { fontAtlas = atlas(9.5) | f#req } | f };
        Assert.assertEq(expected = keyOf(inputs(), changed), cachedKeyOf(cache, changed))
}
