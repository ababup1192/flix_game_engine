// HeadlessRender.renderPngFull — ShaderDoc の面と追加フォントを 1 枚に一緒に渡せること。
// 追加フォントが届いたかは、渡した時と渡さない時で絵が変わるか、SoftRaster.renderFull に直に渡した絵と同じかで見る。
// 字の縁のならし（textAntialias）は本ごとの表（Scene#fontAntialias）で決められ、表に入れた本の字だけが絵全体の設定と違う。
mod TestHeadlessRenderFull {
    import java.io.File
    import java.nio.file.Files
    import javax.imageio.ImageIO

    def outDir(): String = "build/test/renderfull"

    def uiTtf(): String = "../templates/game-starter/assets/Xolonium-Regular.ttf"
    def altTtf(): String = "../templates/rpg-starter/assets/PixelMplus10-Regular.ttf"

    def cfg(): HeadlessRender.RenderConfig \ IO =
        { design = { x = 48.0, y = 24.0 }, scale = 1, background = { r = 0.0, g = 0.0, b = 0.0 },
          fontTtf = uiTtf(), fontAtlas = HeadlessFont.buildUiAtlas(uiTtf(), uiTtf()),
          outDir = outDir(), frameW = 48, frameH = 24 | HeadlessRender.defaults() }

    /// 左半分の面（ShaderDoc の単色）。
    def surface(): SoftRaster.SurfaceCmd =
        { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 24.0, y = 24.0 } },
          spec = { name = "fill", cycleRate = 0.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.2, g = 0.4, b = 0.9 }),
                                              alpha = ShaderDoc.Field.Const(1.0) }) },
          time = 0.0, mask = Nil, zIndex = 0, blend = DrawCmd.BlendMode.Normal }

    /// 追加フォント（font_alt）で書いた字の描き物と、その本。
    def altText(): (List[GameEngine.Drawable], Map[String, SoftRaster.FontEntry]) \ IO =
        let atlas = HeadlessFont.buildAtlas("alt", altTtf());
        (Text.toDrawables(Text.make("Ab", atlas, 12.0), { x = 26.0, y = 4.0 }), Map#{ "font_alt" => { ttf = altTtf(), atlas = atlas } })

    def bytesOf(path: String): List[Int8] \ IO = Files.readAllBytes(new File(path).toPath()) |> Array.toList

    def scene(fonts: Map[String, SoftRaster.FontEntry], drawables: List[GameEngine.Drawable]): HeadlessRender.Scene =
        { passes = Nil, drawables = drawables, polygons = Nil, surfaces = surface() :: Nil, fonts = fonts, fontAntialias = Map.empty() }

    /// 面と追加フォントを一緒に渡した絵は、SoftRaster.renderFull に同じ物を直に渡した絵とバイトまで同じ。
    @Test
    def testFullMatchesSoftRasterRenderFull(): Unit \ IO + Assert =
        let (drawables, fonts) = altText();
        HeadlessRender.renderPngFull(cfg(), scene(fonts, drawables), "full");
        let c = cfg();
        let req: SoftRaster.RasterReq =
            { drawables = drawables, polygons = Nil, design = c#design, scale = c#scale, background = c#background,
              texturePath = c#texturePath, fontTtf = c#fontTtf, fontAtlas = c#fontAtlas, outPath = "${outDir()}/direct.png",
              shapeAntialias = c#shapeAntialias, textAntialias = c#textAntialias };
        SoftRaster.renderFull(req, surface() :: Nil, fonts, Map.empty());
        Assert.assertEq(expected = bytesOf("${outDir()}/direct.png"), bytesOf("${outDir()}/full.png"))

    /// 追加フォントを渡さないと、その字は描けず絵が変わる（渡した本が字に届いている）。
    @Test
    def testFontsReachTheText(): Unit \ IO + Assert =
        let (drawables, fonts) = altText();
        HeadlessRender.renderPngFull(cfg(), scene(fonts, drawables), "withFonts");
        HeadlessRender.renderPngFull(cfg(), scene(Map.empty(), drawables), "withoutFonts");
        Assert.assertEq(expected = false, bytesOf("${outDir()}/withFonts.png") == bytesOf("${outDir()}/withoutFonts.png"))

    /// 白い字だけの絵（面は無し）を、絵全体の字の縁の設定 whole・本の設定 perFont で描いて、PNG のバイトを返す。
    def textOnly(whole: Bool, perFont: Option[Bool], name: String): List[Int8] \ IO =
        let atlas = HeadlessFont.buildAtlas("alt", uiTtf());
        let drawables = Text.toDrawables(Text.make("Ab", atlas, 12.0), { x = 4.0, y = 4.0 });
        let fonts = Map#{ "font_alt" => { ttf = uiTtf(), atlas = atlas } };
        let antialias = perFont |> Option.map(smooth -> Map#{ "font_alt" => smooth }) |> Option.getWithDefault(Map.empty());
        HeadlessRender.renderPngFull({ textAntialias = whole | cfg() },
            { passes = Nil, drawables = drawables, polygons = Nil, surfaces = Nil, fonts = fonts, fontAntialias = antialias }, name);
        bytesOf("${outDir()}/${name}.png")

    /// 絵全体はならす設定のまま表で本を false にした字は、絵全体で切った字とバイトまで同じ（逆も同じ）。
    /// 表に無い本は絵全体に従うので、ならした絵と切った絵は違う。
    @Test
    def testTextAntialiasPerFont(): Unit \ IO + Assert =
        Assert.assertEq(expected = (true, true, false),
            (textOnly(true, Some(false), "crispOnSmooth") == textOnly(false, None, "crispWhole"),
             textOnly(false, Some(true), "smoothOnCrisp") == textOnly(true, None, "smoothWhole"),
             textOnly(true, None, "smoothWhole2") == textOnly(false, None, "crispWhole2")))

    /// PNG の実色数（RGB の種類）。
    def distinctColors(path: String): Int32 \ IO =
        let img = ImageIO.read(new File(path));
        List.range(0, img.getWidth()) |> List.flatMap(x -> List.range(0, img.getHeight()) |> List.map(y ->
            Int32.bitwiseAnd(img.getRGB(x, y), 16777215))) |> List.toSet |> Set.size

    /// 字の縁をならさない白い字は、黒い背景と白の 2 色だけ（縁に中間色を出さない）。ならす字は中間色が出る。
    @Test
    def testCrispTextHasOnlyTwoColors(): Unit \ IO + Assert =
        discard textOnly(false, None, "twoColors");
        discard textOnly(true, None, "manyColors");
        Assert.assertEq(expected = (2, true),
            (distinctColors("${outDir()}/twoColors.png"), distinctColors("${outDir()}/manyColors.png") > 2))
}
