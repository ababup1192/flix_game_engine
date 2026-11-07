// SoftRaster の shapeAntialias つまみ — 画素の格子に乗せる絵（ドット絵）で、宣言した色数が
// そのまま PNG に出るか。文字側（textAntialias）は理由が別（可読性）なので、
// 面の色の予算には効かないことだけをここで押さえる。
//
// なぜこの検査が要るか: 縁をなめらかにすると、宣言していない中間色が縁に湧く。
// PNG の実色数を数えるまで気づけないうえ、色数を予算で縛るドット絵ではそれが
// 「ドット絵に見えない」の直接の原因になる（矩形だけなら出ないので、多角形・
// 斜面・台形を使い始めた画面で初めて壊れる）。
mod TestSoftRasterAntialias {
    import java.awt.image.BufferedImage
    import java.io.File
    import javax.imageio.ImageIO

    def design(): Vec2.Vec2 = { x = 64.0, y = 48.0 }

    def outDir(): String = "build/test/antialias"

    /// 斜めの辺を持つ多角形 2 枚。矩形だけなら縁に中間色は出ないので、
    /// つまみの効き目はこの形でしか測れない。
    def polygons(): List[GameEngine.PolygonRenderCmd] =
        let tri = { x = 4.0, y = 4.0 } :: { x = 58.0, y = 10.0 } :: { x = 20.0, y = 42.0 } :: Nil;
        let wedge = { x = 30.0, y = 44.0 } :: { x = 62.0, y = 20.0 } :: { x = 62.0, y = 44.0 } :: Nil;
        ({ vertices = tri,
           color = { r = 0.85, g = 0.72, b = 0.30 }, alpha = 1.0, zIndex = 10,
           blend = DrawCmd.BlendMode.Normal, clip = None, grad = None, triangles = None }: GameEngine.PolygonRenderCmd) ::
        ({ vertices = wedge,
           color = { r = 0.20, g = 0.35, b = 0.55 }, alpha = 1.0, zIndex = 20,
           blend = DrawCmd.BlendMode.Normal, clip = None, grad = None, triangles = None }: GameEngine.PolygonRenderCmd) :: Nil

    def cfg(shapes: Bool, text: Bool): HeadlessRender.RenderConfig \ IO =
        let ttf = "../templates/game-starter/assets/Xolonium-Regular.ttf";
        { design = design(), scale = 1, background = { r = 0.05, g = 0.06, b = 0.09 },
          fontTtf = ttf, fontAtlas = HeadlessFont.buildUiAtlas(ttf, ttf),
          outDir = outDir(), frameW = 64, frameH = 48,
          shapeAntialias = shapes, textAntialias = text | HeadlessRender.defaults() }

    /// 生成した PNG の実色数（RGB の種類）。
    def distinctColors(path: String): Int32 \ IO =
        let img = ImageIO.read(new File(path));
        if (Object.isNull(img)) -1
        else {
            let w = img.getWidth();
            let h = img.getHeight();
            List.range(0, w) |> List.flatMap(x -> List.range(0, h) |> List.map(y ->
                Int32.bitwiseAnd(img.getRGB(x, y), 16777215)))
                |> List.toSet |> Set.size
        }

    def renderAt(name: String, shapes: Bool, text: Bool): Int32 \ IO =
        HeadlessRender.renderPng(cfg(shapes, text), Nil, polygons(), name);
        distinctColors("${outDir()}/${name}.png")

    @Test
    def testAntialiasOffKeepsTheDeclaredColorBudget(): Unit \ IO + Assert =
        // 宣言したのは背景 + 面 2 枚 = 3 色。切れば PNG もちょうど 3 色に収まる。
        Assert.assertEq(expected = 3, renderAt("hard", false, false))

    @Test
    def testAntialiasOnInventsColorsThatWereNeverDeclared(): Unit \ IO + Assert =
        // 既定（ON）のままだと、宣言していない中間色が縁に湧く。
        // ここが「宣言 13 色の画面が PNG で 2884 色になる」の最小の再現。
        Assert.assertEq(expected = true, renderAt("soft", true, true) > 3)

    @Test
    def testTextAntialiasDoesNotTouchShapeEdges(): Unit \ IO + Assert =
        // 面を切って字を残す組み合わせ（ドット絵のキャラと小さい TTF が同居する画面）。
        // 面の色の予算は字のつまみに引きずられない。
        Assert.assertEq(expected = 3, renderAt("mixed", false, true))
}
