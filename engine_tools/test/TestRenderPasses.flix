// pass（レンダーターゲット）描き出しの配管を具体値で固定する。
//   renderPassImage: clear Clear = その色で塗ってから / Keep = prev の中身の上に描き足す
//   renderToImageFull: extraImages の絵が普通のスプライトとして描ける（design 寸法 × scale 拡大）
// フォントは描かないが RasterReq の配管上 TTF の実パスが要るため、リポジトリ内の
// 資産を相対参照する（テストの cwd = engine_tools/ 前提）。
mod TestRenderPasses {
    import java.awt.image.BufferedImage
    import java.io.File
    import javax.imageio.ImageIO

    /// 出力の比較は (a, r, g, b) のタプルで行う（負の ARGB int を直接比べると読みにくい）。
    def channels(p: Int32): (Int32, Int32, Int32, Int32) =
        let c = shift -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, p), 255);
        (c(24), c(16), c(8), c(0))

    /// ARGB int の組み立て（テスト入力用）。
    def argb(a: Int32, r: Int32, g: Int32, b: Int32): Int32 =
        Int32.leftShift(a, 24)
            |> Int32.bitwiseOr(Int32.leftShift(r, 16))
            |> Int32.bitwiseOr(Int32.leftShift(g, 8))
            |> Int32.bitwiseOr(b)

    def cfg(scale: Int32): HeadlessRender.RenderConfig =
        { design = { x = 4.0, y = 4.0 }, scale = scale,
          background = { r = 0.0, g = 0.0, b = 0.0 },
          texturePath = Map.empty(),
          fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
          fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                        ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
          outDir = "build/test/renderpasses", frameW = 4, frameH = 4,
          gifDelayMs = 66, gifFps = 15, shapeAntialias = true, textAntialias = true }

    /// pass を描き出して 8bit の画像で受け取る（prev は 8bit の前の中身）。
    def renderArgb(c: HeadlessRender.RenderConfig, p: HeadlessRender.PassSpec, prev: Option[BufferedImage]): BufferedImage \ IO =
        SoftRaster.toArgbImage(HeadlessRender.renderPassImage(c, p, Option.map(SoftRaster.PassImage.Rgba8Unorm, prev)))

    def emptyPass(op: RenderTarget.LoadOp): HeadlessRender.PassSpec =
        { name = "paper", clear = op, drawables = Nil, polygons = Nil, surfaces = Nil, scenes = Nil, target = RenderTarget.defaultDescriptor() }

    /// 最小の Drawable（テクスチャ名だけ指定。位置・拡大は個々のテストで上書きする）。
    def drawable(texture: String): GameEngine.Drawable =
        DrawCmd.make({
          texture = texture, position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
          rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    // clear Clear は GL の glClear と同じ — ターゲットの全画素がその色（不透明）になる。
    @Test
    def testRenderPassImageClearColorFillsWholeTarget(): Unit \ {Assert, IO} =
        let img: BufferedImage =
            renderArgb(cfg(1),
                emptyPass(RenderTarget.LoadOp.Clear({ r = 1.0, g = 0.0, b = 0.0 })), None);
        Assert.assertEq(expected = (255, 255, 0, 0) :: (255, 255, 0, 0) :: Nil,
            channels(img.getRGB(0i32, 0i32)) :: channels(img.getRGB(3i32, 3i32)) :: Nil)

    // clear Keep は前フレームのターゲットの中身が残ったまま始まる（残像が作れる）。
    @Test
    def testRenderPassImageNoneKeepsPrevContent(): Unit \ {Assert, IO} =
        let prev: BufferedImage =
            renderArgb(cfg(1),
                emptyPass(RenderTarget.LoadOp.Clear({ r = 0.0, g = 0.0, b = 1.0 })), None);
        let img: BufferedImage =
            renderArgb(cfg(1), emptyPass(RenderTarget.LoadOp.Keep), Some(prev));
        Assert.assertEq(expected = (255, 0, 0, 255), channels(img.getRGB(2i32, 2i32)))

    // clear Keep で prev が無ければ透明から（ターゲットを作った直後の 1 コマ目と同じ）。
    @Test
    def testRenderPassImageNoneWithoutPrevStartsTransparent(): Unit \ {Assert, IO} =
        let img: BufferedImage =
            renderArgb(cfg(1), emptyPass(RenderTarget.LoadOp.Keep), None);
        Assert.assertEq(expected = (0, 0, 0, 0), channels(img.getRGB(0i32, 0i32)))

    // extraImages の絵（2×2）を design (1,1) に置き scale=2 で描き出すと、出力 (2,2) は
    // 元画像 (0,0) の画素になる（表示サイズ = 実寸 × drawable#scale、拡大は最近傍）。
    @Test
    def testRenderToImageFullRendersExtraImageSprite(): Unit \ {Assert, IO} =
        let paper = new BufferedImage(2i32, 2i32, 2i32);
        paper.setRGB(0i32, 0i32, argb(255, 0, 255, 0));
        paper.setRGB(1i32, 1i32, argb(255, 255, 0, 0));
        let c = cfg(2);
        let req: SoftRaster.RasterReq =
            { drawables = DrawCmd.make({ position = { x = 1.0, y = 1.0 } | DrawCmd.toSpec(drawable("paper")) }) :: Nil,
              polygons = Nil, design = c#design, scale = c#scale, background = c#background,
              texturePath = c#texturePath, fontTtf = c#fontTtf, fontAtlas = c#fontAtlas,
              outPath = "", shapeAntialias = true, textAntialias = true, scenes = Nil };
        let img = SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map#{"paper" => SoftRaster.PassImage.Rgba8Unorm(paper)});
        Assert.assertEq(expected = (255, 0, 255, 0), channels(img.getRGB(2i32, 2i32)))

    // シェーダー面の tex 場が pass の描き出し（extraImages）を読める。
    //   2×2 の pass 画像（左上=緑・右下=赤）を Rgb{Tex×3} で素通しする面を design 4×4 全面に貼る。
    //   出力 (1,1) の画素中心は uv=(0.375,0.375) → texel(0,0)=緑、(3,3) は uv=0.875 → texel(1,1)=赤。
    //   NEAREST の floor 量子化と ARGB のチャンネル取り出しをまとめて釘打ちする。
    @Test
    def testRenderToImageFullSurfaceReadsPassTexture(): Unit \ {Assert, IO} =
        let paper = new BufferedImage(2i32, 2i32, 2i32);
        paper.setRGB(0i32, 0i32, argb(255, 0, 255, 0));
        paper.setRGB(1i32, 1i32, argb(255, 255, 0, 0));
        let c = cfg(1);
        let req: SoftRaster.RasterReq =
            { drawables = Nil, polygons = Nil, design = c#design, scale = c#scale,
              background = c#background, texturePath = c#texturePath, fontTtf = c#fontTtf,
              fontAtlas = c#fontAtlas, outPath = "", shapeAntialias = true, textAntialias = true, scenes = Nil };
        let texOf = chan -> ShaderDoc.Field.Tex({ name = "paper", chan = chan });
        let surface: SoftRaster.SurfaceCmd =
            { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 4.0, y = 4.0 } },
              spec = { name = "blit", cycleRate = 0.0, bindings = Nil,
                       out = ShaderDoc.Out.Fill({
                           shade = ShaderDoc.Shade.Rgb({
                               r = texOf(ShaderDoc.TexChan.R), g = texOf(ShaderDoc.TexChan.G),
                               b = texOf(ShaderDoc.TexChan.B) }),
                           alpha = ShaderDoc.Field.Const(1.0) }) },
              time = 0.0, mask = Nil, zIndex = 0, blend = DrawCmd.BlendMode.Normal };
        let img = SoftRaster.renderToImageFull(req, surface :: Nil, Map.empty(),
                                               Map#{"paper" => SoftRaster.PassImage.Rgba8Unorm(paper)});
        Assert.assertEq(expected = (255, 0, 255, 0) :: (255, 255, 0, 0) :: Nil,
            channels(img.getRGB(1i32, 1i32)) :: channels(img.getRGB(3i32, 3i32)) :: Nil)

    /// PNG を読み戻した 1 画素。読めなければ (−1, −1, −1, −1)。
    def readPixel(path: String, x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO =
        let img = ImageIO.read(new File(path));
        if (Object.isNull(img)) (-1, -1, -1, -1) else channels(img.getRGB(x, y))

    // renderGifWithPasses: コマ番号で色が変わる pass を本編がスプライトとして貼ると、
    // コマ別 PNG に「そのコマの pass の色」が出る — pass がコマごとに描き直されている証拠。
    // GIF の実在と Filmstrip のコマ数も同時に釘打ちする。
    @Test
    def testRenderGifWithPassesRendersPassPerFrame(): Unit \ {Assert, IO} =
        let c = { outDir = "build/test/rendergifpasses" | cfg(1) };
        let toCmds = t -> {
            let p: HeadlessRender.PassSpec =
                { name = "paper",
                  clear = RenderTarget.LoadOp.Clear({ r = t, g = 0.0, b = 0.0 }),
                  drawables = Nil, polygons = Nil, surfaces = Nil, scenes = Nil, target = RenderTarget.defaultDescriptor() };
            (p :: Nil, drawable("paper") :: Nil,
             (Nil: List[GameEngine.PolygonRenderCmd]), (Nil: List[SoftRaster.SurfaceCmd]))
        };
        let strip = HeadlessRender.renderGifWithPasses(c, 0.0 :: 1.0 :: Nil, 1, toCmds, "smoke");
        let gifExists = (new File("build/test/rendergifpasses/smoke.gif")).exists();
        Assert.assertEq(
            expected = (2, true, (255, 0, 0, 0), (255, 255, 0, 0)),
            (strip#frameCount, gifExists,
             readPixel("build/test/rendergifpasses/frames/smoke/0.png", 1i32, 1i32),
             readPixel("build/test/rendergifpasses/frames/smoke/1.png", 1i32, 1i32)))

    // 組み込みの放射テクスチャ: Render.lightAt が下ろす Drawable（texture "__radial_light"・
    // centered・Add）を texturePath 空のまま描き出すと、黒背景の中心 (128,128) が白へ加算され、
    // 四隅 (0,0) は黒のまま残る（縁は rgb 0 まで減衰しているので Add は背景を汚さない）。
    // engine_tools は engine_world（lightAt の住処）に依存できないため、Drawable を直接組む。
    @Test
    def testRenderToImageFullRendersBuiltinRadialLight(): Unit \ {Assert, IO} =
        let c = cfg(1);
        let light = DrawCmd.make({ texture = "__radial_light", position = { x = 128.0, y = 128.0 },
                      centered = true, blend = DrawCmd.BlendMode.Add | DrawCmd.toSpec(drawable("")) });
        let req: SoftRaster.RasterReq =
            { drawables = light :: Nil,
              polygons = Nil, design = { x = 256.0, y = 256.0 }, scale = c#scale,
              background = c#background, texturePath = c#texturePath, fontTtf = c#fontTtf,
              fontAtlas = c#fontAtlas, outPath = "", shapeAntialias = true, textAntialias = true, scenes = Nil };
        let img = SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map.empty());
        Assert.assertEq(expected = (255, 255, 255, 255) :: (255, 0, 0, 0) :: Nil,
            channels(img.getRGB(128i32, 128i32)) :: channels(img.getRGB(0i32, 0i32)) :: Nil)

    // ── Pass の中のシェーダー面（GL と同じく pass の絵に描く）──

    /// rgb だけ（pass の alpha は GL のブレンドの副産物で、一致を約束していない — docs/backend-parity.md）。
    def rgbOf(p: Int32): (Int32, Int32, Int32) =
        let (_, r, g, b) = channels(p);
        (r, g, b)

    /// design 4×4 全面の面。shade と alpha 1。
    def faceOf(shade: ShaderDoc.Shade): SoftRaster.SurfaceCmd =
        { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 4.0, y = 4.0 } },
          spec = { name = "face", cycleRate = 0.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({ shade = shade, alpha = ShaderDoc.Field.Const(1.0) }) },
          time = 0.0, mask = Nil, zIndex = 0, blend = DrawCmd.BlendMode.Normal }

    /// name のテクスチャを rgb で素通しする面。
    def passThrough(name: String): SoftRaster.SurfaceCmd =
        let texOf = chan -> ShaderDoc.Field.Tex({ name = name, chan = chan });
        faceOf(ShaderDoc.Shade.Rgb({ r = texOf(ShaderDoc.TexChan.R), g = texOf(ShaderDoc.TexChan.G),
                                     b = texOf(ShaderDoc.TexChan.B) }))

    def withSurface(surface: SoftRaster.SurfaceCmd, p: HeadlessRender.PassSpec): HeadlessRender.PassSpec =
        { surfaces = surface :: Nil | p }

    // 面は Clear の枝と ClearTransparent の枝の両方で pass の絵に塗られる（落とす所が 2 か所あったため両方見る）。
    @Test
    def testPassSurfaceIsPaintedInBothClearBranches(): Unit \ {Assert, IO} =
        let green = faceOf(ShaderDoc.Shade.Solid({ r = 0.0, g = 1.0, b = 0.0 }));
        let cleared = renderArgb(cfg(1), withSurface(green, emptyPass(RenderTarget.LoadOp.Clear({ r = 1.0, g = 0.0, b = 0.0 }))), None);
        let transparent = renderArgb(cfg(1), withSurface(green, emptyPass(RenderTarget.LoadOp.ClearTransparent)), None);
        Assert.assertEq(expected = (0, 255, 0) :: (0, 255, 0) :: Nil,
            rgbOf(cleared.getRGB(1i32, 1i32)) :: rgbOf(transparent.getRGB(1i32, 1i32)) :: Nil)

    // 2 段の連鎖: 前の pass の絵を次の pass の面が tex で読む。
    @Test
    def testPassSurfaceReadsEarlierPass(): Unit \ {Assert, IO} =
        let blue = faceOf(ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 1.0 }));
        let first = renderArgb(cfg(1), withSurface(blue, emptyPass(RenderTarget.LoadOp.ClearTransparent)), None);
        let second = SoftRaster.toArgbImage(HeadlessRender.renderPassImageWith(cfg(1), Map#{ "paper" => SoftRaster.PassImage.Rgba8Unorm(first) },
            withSurface(passThrough("paper"), { name = "copy" | emptyPass(RenderTarget.LoadOp.ClearTransparent) }), None));
        Assert.assertEq(expected = (0, 0, 255), rgbOf(second.getRGB(2i32, 2i32)))

    // 自分の history（"paper@history"）は描き出しでは毎回透明 = rgb 0 を読む。本編で貼ると黒。
    @Test
    def testPassHistoryReadsTransparentInHeadless(): Unit \ {Assert, IO} =
        let c = { outDir = "build/test/renderpasses_history" | cfg(1) };
        let p = withSurface(passThrough(RenderTarget.historyName("paper")),
                            emptyPass(RenderTarget.LoadOp.Clear({ r = 1.0, g = 1.0, b = 1.0 })));
        HeadlessRender.renderPngFull({ background = { r = 1.0, g = 0.0, b = 0.0 } | c },
            { passes = p :: Nil, drawables = drawable("paper") :: Nil, polygons = Nil, surfaces = Nil, scenes = Nil,
              fonts = Map.empty(), fontAntialias = Map.empty() }, "history");
        Assert.assertEq(expected = (255, 0, 0, 0), readPixel("build/test/renderpasses_history/history.png", 1, 1))

    // ── 縮んだ pass（RenderTarget.Descriptor の scale）──

    /// x = 2..4 の白い箱（design 4×4・整数座標）。
    def whiteBoxRight(): GameEngine.Drawable =
        DrawCmd.make({
          texture = "", position = { x = 2.0, y = 0.0 }, scale = { x = 2.0, y = 4.0 },
          rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    def halfPass(): HeadlessRender.PassSpec =
        { drawables = whiteBoxRight() :: Nil, target = { scale = 0.5 | RenderTarget.defaultDescriptor() } | emptyPass(RenderTarget.LoadOp.Clear({ r = 0.0, g = 0.0, b = 0.0 })) }

    // scale 0.5 の pass はテクセル寸法 2×2 で、テクセル i は design の点 2i+1 を塗る:
    // テクセル 0（点 1）は箱の外の黒・テクセル 1（点 3）は箱（2..4）の白。
    @Test
    def testHalfPassPicksTexelCenters(): Unit \ {Assert, IO} =
        let img = renderArgb(cfg(1), halfPass(), None);
        Assert.assertEq(expected = (2, 2, (0, 0, 0), (255, 255, 255)),
                        (img.getWidth(), img.getHeight(), rgbOf(img.getRGB(0i32, 0i32)), rgbOf(img.getRGB(1i32, 0i32))))

    // 縮んだ pass を sprite で貼ると design 全面を覆い、1 テクセルが 2px の塊になる（GL が registry に design 寸法で載せるのと同じ）。
    @Test
    def testHalfPassBlitsAsTwoPixelBlocks(): Unit \ {Assert, IO} =
        let c = { outDir = "build/test/renderpasses_half" | cfg(1) };
        HeadlessRender.renderPngFull({ background = { r = 1.0, g = 0.0, b = 0.0 } | c },
            { passes = halfPass() :: Nil, drawables = drawable("paper") :: Nil, polygons = Nil, surfaces = Nil, scenes = Nil,
              fonts = Map.empty(), fontAntialias = Map.empty() }, "half");
        let at = x -> readPixel("build/test/renderpasses_half/half.png", x, 1);
        Assert.assertEq(expected = (255, 0, 0, 0) :: (255, 0, 0, 0) :: (255, 255, 255, 255) :: (255, 255, 255, 255) :: Nil,
                        at(0) :: at(1) :: at(2) :: at(3) :: Nil)

    // Keep の縮んだ pass は、何も描かなければ前の中身のテクセルをそのまま残す（広げて拾う往復で元に戻る）。
    @Test
    def testHalfKeepPassRoundTripsPrev(): Unit \ {Assert, IO} =
        let prev = new BufferedImage(2i32, 2i32, 2i32);
        prev.setRGB(0i32, 0i32, argb(255, 10, 20, 30));
        prev.setRGB(1i32, 1i32, argb(255, 200, 100, 50));
        let img = renderArgb(cfg(1), { target = { scale = 0.5 | RenderTarget.defaultDescriptor() } | emptyPass(RenderTarget.LoadOp.Keep) }, Some(prev));
        Assert.assertEq(expected = (10, 20, 30) :: (200, 100, 50) :: Nil,
                        rgbOf(img.getRGB(0i32, 0i32)) :: rgbOf(img.getRGB(1i32, 1i32)) :: Nil)

    // ── 描き先の画素を基準にした pass（RenderTarget.Basis.Window）──

    /// 書き出しの倍率 scale で描いた pass の寸法。
    def passSize(scale: Int32, basis: RenderTarget.Basis): (Int32, Int32) \ IO =
        let img = renderArgb(cfg(scale), { target = { basis = basis | RenderTarget.defaultDescriptor() } | emptyPass(RenderTarget.LoadOp.ClearTransparent) }, None);
        (img.getWidth(), img.getHeight())

    // Window の pass は書き出しの倍率 2 で design の 2 倍の寸法、Design の pass は design のまま。
    @Test
    def testWindowPassFollowsExportScale(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = ((8, 8), (4, 4)), (passSize(2, RenderTarget.Basis.Window), passSize(2, RenderTarget.Basis.Design)))

    /// 赤い板（x/z が −1..−0.3。design の x 0..1.4 に写る）と青い地の 3D の場面を描いた pass の 1 行（y = design の 2）の色。
    def plateRow(scale: Int32, basis: RenderTarget.Basis): List[(Int32, Int32, Int32, Int32)] \ IO =
        let red = { r = 1.0, g = 0.0, b = 0.0 };
        let plate = Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(-0.6, 2.0, 2.0) :: Vec3.v3(-0.6, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
              color = red } :: Nil), Mat4.identity());
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 };
        let base = Scene3d.scene(camera, { x = 4.0, y = 4.0 });
        let scene = { instances = plate :: Nil, environment = { background = Some({ r = 0.0, g = 0.0, b = 1.0 }) | base#environment } | base };
        let img = renderArgb(cfg(scale),
            { target = { basis = basis | RenderTarget.defaultDescriptor() }, scenes = { at = { x = 0.0, y = 0.0 }, clip = None, scene = scene } :: Nil | emptyPass(RenderTarget.LoadOp.ClearTransparent) }, None);
        let y = img.getHeight() / 2;
        List.range(0, img.getWidth()) |> List.map(x -> channels(img.getRGB(x, y)))

    // Window の pass の 3D の縁は書き出しの 1 画素で切れる: 倍率 2 では板が 3 画素（design の 1.5 画素ぶん）・Design の pass は design の 1 画素。
    @Test
    def testWindowPassDrawsSceneEdgeAtExportPixels(): Unit \ {Assert, IO} =
        let redCount = (row: List[(Int32, Int32, Int32, Int32)]) -> List.count(c -> { let (_, r, g, b) = c; r == 255 and g == 0 and b == 0 }, row);
        Assert.assertEq(expected = (3, 1), (redCount(plateRow(2, RenderTarget.Basis.Window)), redCount(plateRow(2, RenderTarget.Basis.Design))))
}
