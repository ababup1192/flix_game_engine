// Rgba16Float の Pass（RenderTarget.Format.Rgba16Float）を CPU で描き出す決まりを具体値で固定する。
//   1 を超える値が切られずに残る・8bit へ落とす所（無限大は 255）・書き込みの決まり（rgb は [0, 65504]・α は [0, 1]）・half の丸め・
//   blendPixelF の α の式・Graphics2D の物は 8bit の下書きから混ぜる・3D の emission が残る・
//   読む所で α を 0..1 に切る・RenderCache の鍵・Window の基準と縮め。
// 値は half でちょうど表せる数（0.75・1.5・2.0・3.0）を選ぶ（丸めの差を答えに混ぜない）。
mod TestRenderPassesHdr {
    import java.awt.image.BufferedImage

    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    def cfg(scale: Int32): HeadlessRender.RenderConfig =
        { design = { x = 4.0, y = 4.0 }, scale = scale,
          background = { r = 0.0, g = 0.0, b = 0.0 },
          texturePath = Map.empty(),
          fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
          fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                        ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
          outDir = "build/test/renderpasses_hdr", frameW = 4, frameH = 4,
          gifDelayMs = 66, gifFps = 15, shapeAntialias = true, textAntialias = true }

    def pass(target: RenderTarget.Descriptor, op: RenderTarget.LoadOp): HeadlessRender.PassSpec =
        { name = "hdr", clear = op, drawables = Nil, polygons = Nil, surfaces = Nil, scenes = Nil, target = target }

    def hdrPass(op: RenderTarget.LoadOp): HeadlessRender.PassSpec = pass(RenderTarget.withHdr(RenderTarget.defaultDescriptor()), op)

    def ldrPass(op: RenderTarget.LoadOp): HeadlessRender.PassSpec = pass(RenderTarget.defaultDescriptor(), op)

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    /// 全面（design 4×4）の単色の面。
    def fill(c: Color, alpha: Float64, blend: DrawCmd.BlendMode): SoftRaster.SurfaceCmd =
        { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 4.0, y = 4.0 } },
          spec = { name = "fill", cycleRate = 0.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(alpha) }) },
          time = 0.0, mask = Nil, zIndex = 0, blend = blend }

    /// name の絵の r を k 倍・α を chanA の場で読んで画面へ出す面（g・b は 0）。
    def readScaled(name: String, k: Float64, chanA: Bool): SoftRaster.SurfaceCmd =
        let r = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = ShaderDoc.Field.Tex({ name = name, chan = ShaderDoc.TexChan.R }),
                                      b = ShaderDoc.Field.Const(k) });
        let g = if (chanA) ShaderDoc.Field.Tex({ name = name, chan = ShaderDoc.TexChan.A }) else ShaderDoc.Field.Const(0.0);
        { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 4.0, y = 4.0 } },
          spec = { name = "read", cycleRate = 0.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = r, g = g, b = ShaderDoc.Field.Const(0.0) }),
                                              alpha = ShaderDoc.Field.Const(1.0) }) },
          time = 0.0, mask = Nil, zIndex = 0, blend = DrawCmd.BlendMode.Normal }

    def req(c: HeadlessRender.RenderConfig, drawables: List[GameEngine.Drawable]): SoftRaster.RasterReq =
        { drawables = drawables, polygons = Nil, design = c#design, scale = c#scale, background = c#background,
          texturePath = c#texturePath, fontTtf = c#fontTtf, fontAtlas = c#fontAtlas,
          outPath = "", shapeAntialias = true, textAntialias = true, scenes = Nil }

    /// 本編（8bit）で images を surfaces で読んだ絵の (x, y) の画素。
    def screenPixel(images: Map[String, SoftRaster.PassImage], surfaces: List[SoftRaster.SurfaceCmd],
                    drawables: List[GameEngine.Drawable], x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO =
        channels(SoftRaster.renderToImageFull(req(cfg(1), drawables), surfaces, Map.empty(), images).getRGB(x, y))

    /// Rgba16Float の絵の (x, y) の (r, g, b, α)。Rgba8Unorm が来たら止める。
    def hdrPixel(img: SoftRaster.PassImage, x: Int32, y: Int32): (Float64, Float64, Float64, Float64) =
        match img {
            case SoftRaster.PassImage.Rgba16Float(hdr) =>
                let at = c -> ShaderEval.hdrChannelOf(hdr, (y * ShaderEval.hdrWidthOf(hdr) + x) * 4 + c);
                (at(0), at(1), at(2), at(3))
            case SoftRaster.PassImage.Rgba8Unorm(_) => bug!("Rgba16Float の pass が 8bit で描かれた")
        }

    def box(at: Vec2.Vec2, size: Vec2.Vec2, c: Color, blend: DrawCmd.BlendMode): GameEngine.Drawable =
        DrawCmd.make({
          texture = "", position = at, scale = size, rotation = 0.0, color = c, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = None, clip = None, blend = blend, mask = Nil })

    def sprite(texture: String, at: Vec2.Vec2, scale: Float64): GameEngine.Drawable =
        DrawCmd.make({
          texture = texture, position = at, scale = { x = scale, y = scale }, rotation = 0.0, color = gray(1.0), alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 1, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    // ════════════════════════════════════════════════════════
    // 1 を超える値が残る
    // ════════════════════════════════════════════════════════

    /// 0.75 の面を Add で 2 回重ねた pass を、0.5 倍して読んだ本編の (1, 1)。
    def addedTwiceReadHalf(p: HeadlessRender.PassSpec): (Int32, Int32, Int32, Int32) \ IO =
        let adds = fill(gray(0.75), 1.0, DrawCmd.BlendMode.Add) :: fill(gray(0.75), 1.0, DrawCmd.BlendMode.Add) :: Nil;
        let img = HeadlessRender.renderPassImage(cfg(1), { surfaces = adds | p }, None);
        screenPixel(Map#{ "hdr" => img }, readScaled("hdr", 0.5, false) :: Nil, Nil, 1, 1)

    // Rgba16Float の pass は Add で 1.5 を持ち、0.5 倍して読むと 0.75（191）。
    @Test
    def testHdrPassKeepsValueAboveOneThroughAdd(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (255, 191, 0, 0), addedTwiceReadHalf(hdrPass(RenderTarget.LoadOp.ClearTransparent)))

    // Rgba8Unorm の pass は 1 に切られるので、0.5 倍して読むと 0.5（128）。
    @Test
    def testLdrPassClipsValueAboveOneThroughAdd(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (255, 128, 0, 0), addedTwiceReadHalf(ldrPass(RenderTarget.LoadOp.ClearTransparent)))

    // half の丸め: 0.1 は half で 0.0999755859375・1.0002 は 1 に寄る・1.5 はそのまま。
    @Test
    def testRoundToHalfRoundsToHalfPrecision(): Unit \ Assert =
        Assert.assertEq(expected = (0.0999755859375, 1.0, 1.5),
                        (ShaderEval.roundToHalf(0.1), ShaderEval.roundToHalf(1.0002), ShaderEval.roundToHalf(1.5)))

    // hdrTextureOf は渡された値を half に丸めて持つ（0.1 → 0.0999755859375）。
    @Test
    def testHdrTextureOfRoundsToHalf(): Unit \ Assert =
        Assert.assertEq(expected = 0.0999755859375, ShaderEval.hdrChannelOf(ShaderEval.hdrTextureOf(1, 1, Vector#{0.1, 0.0, 0.0, 1.0}), 0))

    // ════════════════════════════════════════════════════════
    // 8bit へ落とす所
    // ════════════════════════════════════════════════════════

    // 無限大の r を 8bit の画素にすると 255（整数にする前に 0..1 に切る。切らないと Int32 に入らず黒になる）。
    @Test
    def testInfinityBecomesFullByteOnArgb(): Unit \ Assert =
        Assert.assertEq(expected = (255, 255, 0, 0), channels(SoftRaster.argbOfRgba(Float64.positiveInfinity(), 0.0, 0.0, 1.0)))

    // r が 1e30 の面を黒で Clear した 8bit の pass に描くと r は 255。
    @Test
    def testHugeSurfaceValueBecomesFullByteInLdrPass(): Unit \ {Assert, IO} =
        let huge = fill({ r = 1.0e30, g = 0.0, b = 0.0 }, 1.0, DrawCmd.BlendMode.Normal);
        let img = HeadlessRender.renderPassImage(cfg(1), { surfaces = huge :: Nil | ldrPass(RenderTarget.LoadOp.Clear(gray(0.0))) }, None);
        Assert.assertEq(expected = (255, 255, 0, 0), channels(SoftRaster.toArgbImage(img).getRGB(1i32, 1i32)))

    // ════════════════════════════════════════════════════════
    // 書き込みの決まり
    // ════════════════════════════════════════════════════════

    // 面の出力は rgb を [0, 65504]・α を [0, 1] に切る（−0.5 → 0・70000 → 65504・2.0 はそのまま・α 1.5 → 1）。
    @Test
    def testHdrWriteRuleClampsSurface(): Unit \ {Assert, IO} =
        let surface = fill({ r = -0.5, g = 70000.0, b = 2.0 }, 1.5, DrawCmd.BlendMode.Normal);
        let painted = HeadlessRender.renderPassImage(cfg(1), { surfaces = surface :: Nil | hdrPass(RenderTarget.LoadOp.ClearTransparent) }, None);
        Assert.assertEq(expected = (0.0, 65504.0, 2.0, 1.0), hdrPixel(painted, 1, 1))

    // Clear の 2.0 は切らずに残る（面の無い pass の画素）。
    @Test
    def testHdrClearKeepsValueAboveOne(): Unit \ {Assert, IO} =
        let cleared = HeadlessRender.renderPassImage(cfg(1), hdrPass(RenderTarget.LoadOp.Clear(gray(2.0))), None);
        Assert.assertEq(expected = (2.0, 2.0, 2.0, 1.0), hdrPixel(cleared, 3, 3))

    /// dst = (1, 1, 1, α 0.5) に src = (0.5, 0.5, 0.5, α 0.5) を blend で混ぜた (r, α)。
    def blendedOverHalf(blend: DrawCmd.BlendMode): (Float64, Float64) \ IO =
        let px = Array#{1.0, 1.0, 1.0, 0.5} @ Static;
        SoftRaster.blendPixelF(blend, 0.5, 0.5, 0.5, 0.5, px, 0);
        (Array.get(0, px), Array.get(3, px))

    // blendPixelF の Normal は glBlendFunc と同じ: rgb = 0.25 + 0.5 = 0.75・α = 0.25 + 0.25 = 0.5。
    @Test
    def testBlendPixelFNormalFollowsGlFactors(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0.75, 0.5), blendedOverHalf(DrawCmd.BlendMode.Normal))

    // blendPixelF の Add: rgb = 1 + 0.25 = 1.25・α = 0.25 + 0.5 = 0.75。
    @Test
    def testBlendPixelFAddFollowsGlFactors(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (1.25, 0.75), blendedOverHalf(DrawCmd.BlendMode.Add))

    // blendPixelF の Multiply: rgb = 1 × (1 − 0.5 × 0.5) = 0.75・α = 0.5 × 0.5 + 0.5 × 0.5 = 0.5（dst の α のまま）。
    @Test
    def testBlendPixelFMultiplyFollowsGlFactors(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0.75, 0.5), blendedOverHalf(DrawCmd.BlendMode.Multiply))

    // ════════════════════════════════════════════════════════
    // Graphics2D の物（下書き → 混ぜる）
    // ════════════════════════════════════════════════════════

    /// Clear 2.0 の Rgba16Float の pass に Normal の赤い箱（左 2 列）・緑の sprite（1×1 の絵を 2 倍・右下）・青の多角形（右上の 1 行）を描いた絵。
    def mixedDrawPass(): SoftRaster.PassImage \ IO =
        let greenTex = new BufferedImage(1i32, 1i32, 2i32);
        greenTex.setRGB(0i32, 0i32, Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(255, 8)));
        let drawables = box({ x = 0.0, y = 0.0 }, { x = 2.0, y = 4.0 }, { r = 1.0, g = 0.0, b = 0.0 }, DrawCmd.BlendMode.Normal)
            :: sprite("green", { x = 2.0, y = 2.0 }, 2.0) :: Nil;
        let polygon: GameEngine.PolygonRenderCmd =
            { vertices = { x = 2.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 4.0, y = 1.0 } :: { x = 2.0, y = 1.0 } :: Nil,
              color = { r = 0.0, g = 0.0, b = 1.0 }, alpha = 1.0, zIndex = 0,
              blend = DrawCmd.BlendMode.Normal, clip = None, grad = None };
        HeadlessRender.renderPassImageWith(cfg(1), Map#{ "green" => SoftRaster.PassImage.Rgba8Unorm(greenTex) },
                                           { drawables = drawables, polygons = polygon :: Nil | hdrPass(RenderTarget.LoadOp.Clear(gray(2.0))) }, None)

    // 箱の画素は箱の色。
    @Test
    def testNormalBoxBlendsIntoHdrPass(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (1.0, 0.0, 0.0, 1.0), hdrPixel(mixedDrawPass(), 0, 0))

    // sprite の画素は絵の色。
    @Test
    def testNormalSpriteBlendsIntoHdrPass(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0.0, 1.0, 0.0, 1.0), hdrPixel(mixedDrawPass(), 3, 3))

    // 多角形の画素は多角形の色。
    @Test
    def testNormalPolygonBlendsIntoHdrPass(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0.0, 0.0, 1.0, 1.0), hdrPixel(mixedDrawPass(), 3, 0))

    // 何も描かない (3, 1) は 2.0 のまま（描いた物の外を 8bit に切らない）。
    @Test
    def testUndrawnPixelKeepsValueAboveOne(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (2.0, 2.0, 2.0, 1.0), hdrPixel(mixedDrawPass(), 3, 1))

    // ════════════════════════════════════════════════════════
    // 読む所で α を切る
    // ════════════════════════════════════════════════════════

    /// 白の箱を Add で 3 回重ねた Rgba16Float の pass。
    def whiteAddedThrice(): SoftRaster.PassImage \ IO =
        let white = box({ x = 0.0, y = 0.0 }, { x = 4.0, y = 4.0 }, gray(1.0), DrawCmd.BlendMode.Add);
        HeadlessRender.renderPassImage(cfg(1), { drawables = white :: white :: white :: Nil | hdrPass(RenderTarget.LoadOp.ClearTransparent) }, None)

    // Add を 3 回重ねると α は 3 まで溜まる。
    @Test
    def testAddAccumulatesAlphaInHdrPass(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 3.0, match hdrPixel(whiteAddedThrice(), 1, 1) { case (_, _, _, a) => a })

    // 面の tex は溜まった α を 1 で読む（g = 1 → 255）。
    @Test
    def testSurfaceReadsAccumulatedAlphaAsOne(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (255, 191, 255, 0),
                        screenPixel(Map#{ "hdr" => whiteAddedThrice() }, readScaled("hdr", 0.25, true) :: Nil, Nil, 1, 1))

    // 青の地へ Normal の sprite で貼ると α 1 として混ざって白になる（溜まった α を混ぜ式に入れない）。
    @Test
    def testSpriteReadsAccumulatedAlphaAsOne(): Unit \ {Assert, IO} =
        let blueGround = box({ x = 0.0, y = 0.0 }, { x = 4.0, y = 4.0 }, { r = 0.0, g = 0.0, b = 1.0 }, DrawCmd.BlendMode.Normal);
        Assert.assertEq(expected = (255, 255, 255, 255),
                        screenPixel(Map#{ "hdr" => whiteAddedThrice() }, Nil, blueGround :: sprite("hdr", { x = 0.0, y = 0.0 }, 1.0) :: Nil, 1, 1))

    // ════════════════════════════════════════════════════════
    // RenderCache の鍵
    // ════════════════════════════════════════════════════════

    /// r だけ v の 1×1 の Rgba16Float の絵。
    def redHdr(v: Float64): SoftRaster.PassImage =
        SoftRaster.PassImage.Rgba16Float(ShaderEval.hdrTextureOf(1, 1, Vector#{v, 0.0, 0.0, 1.0}))

    // 1 を超えた所だけ違う 2 枚（1.5 と 2.0）は、鍵（画素の指紋）が別。
    @Test
    def testCacheDigestSeparatesValuesAboveOne(): Unit \ {Assert, IO} =
        Assert.assertFalse(RenderCache.passImageDigest(redHdr(1.5)) == RenderCache.passImageDigest(redHdr(2.0)))

    // 同じ 2 枚（1.5 と 2.0）も 8bit に切ると同じ画素。
    @Test
    def testValuesAboveOneClipToSameByte(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = SoftRaster.toArgbImage(redHdr(1.5)).getRGB(0i32, 0i32), SoftRaster.toArgbImage(redHdr(2.0)).getRGB(0i32, 0i32))

    // ════════════════════════════════════════════════════════
    // 3D の emission
    // ════════════════════════════════════════════════════════

    /// 環境光が黒・光の無い場面に、黒の材質で emission の r が 1.6 の板（design 4×4 を覆う）。
    def glowingPlateScene(): Scene3d.RenderCmd =
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 };
        let material = Scene3d.material({ name = "glow", cycleRate = 0.0, bindings = Nil,
                out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(gray(0.0)), alpha = ShaderDoc.Field.Const(1.0) }) })
            |> Scene3d.withEmission(ShaderDoc.Shade.Rgb({ r = ShaderDoc.Field.Const(1.6), g = ShaderDoc.Field.Const(0.0),
                                                          b = ShaderDoc.Field.Const(0.0) }));
        let plate = Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-4.0, 4.0, 2.0) :: Vec3.v3(4.0, 4.0, 2.0) :: Vec3.v3(4.0, -4.0, 2.0) :: Vec3.v3(-4.0, -4.0, 2.0) :: Nil,
              color = gray(1.0) } :: Nil), Mat4.identity()) |> Scene3d.withMaterial(material);
        let base = Scene3d.scene(camera, { x = 4.0, y = 4.0 });
        { at = { x = 0.0, y = 0.0 }, clip = None,
          scene = { instances = plate :: Nil, environment = { ambient = gray(0.0) | base#environment } | base } }

    // emission 1.6 の材質を Rgba16Float の pass に描くと r は 1.6（half で 1.599609375）が残る。
    @Test
    def testEmissionAboveOneSurvivesInHdrPass(): Unit \ {Assert, IO} =
        let hdr = HeadlessRender.renderPassImage(cfg(1), { scenes = glowingPlateScene() :: Nil | hdrPass(RenderTarget.LoadOp.Clear(gray(0.0))) }, None);
        Assert.assertEq(expected = 1.599609375, match hdrPixel(hdr, 2, 2) { case (r, _, _, _) => r })

    // 同じ材質を 8bit の pass に描くと r は 255 に切られる（3D の層も argbOfRgba を通る）。
    @Test
    def testEmissionAboveOneClipsInLdrPass(): Unit \ {Assert, IO} =
        let ldr = HeadlessRender.renderPassImage(cfg(1), { scenes = glowingPlateScene() :: Nil | ldrPass(RenderTarget.LoadOp.Clear(gray(0.0))) }, None);
        Assert.assertEq(expected = (255, 255, 0, 0), channels(SoftRaster.toArgbImage(ldr).getRGB(2i32, 2i32)))

    // ════════════════════════════════════════════════════════
    // 寸法（Window の基準・縮め）
    // ════════════════════════════════════════════════════════

    /// 書き出しの倍率 2 で、scale 0.5・Clear 2.0 の Rgba16Float の pass を basis の記述子で描いた絵。
    def halfScaleHdr(descriptor: RenderTarget.Descriptor): SoftRaster.PassImage \ IO =
        HeadlessRender.renderPassImage(cfg(2), pass(RenderTarget.withHdr({ scale = 0.5 | descriptor }), RenderTarget.LoadOp.Clear(gray(2.0))), None)

    // Window の基準・scale 0.5 は、書き出し 8×8 の半分のテクセル寸法 4×4。
    @Test
    def testHdrWindowHalfPassSize(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (4, 4), SoftRaster.passImageSize(halfScaleHdr(RenderTarget.windowDescriptor())))

    // Window の基準で縮めても Clear の 2.0 は残る。
    @Test
    def testHdrWindowHalfPassKeepsClear(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2.0, match hdrPixel(halfScaleHdr(RenderTarget.windowDescriptor()), 3, 3) { case (r, _, _, _) => r })

    // Design の基準・scale 0.5 は design 4×4 の半分の 2×2。
    @Test
    def testHdrDesignHalfPassSize(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (2, 2), SoftRaster.passImageSize(halfScaleHdr(RenderTarget.defaultDescriptor())))

    // Design の基準で縮めても Clear の 2.0 は残る。
    @Test
    def testHdrDesignHalfPassKeepsClear(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2.0, match hdrPixel(halfScaleHdr(RenderTarget.defaultDescriptor()), 1, 1) { case (r, _, _, _) => r })
}
