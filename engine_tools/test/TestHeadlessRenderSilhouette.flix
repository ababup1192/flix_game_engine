// シルエット描き出しの純関数部分のテスト。PNG 書き出しは renderPng の既存経路に
// 流すだけなので、ここでは「絞り」と「黒化」だけを見る。
mod TestHeadlessRenderSilhouette {

    /// z に置いた最小の Drawable。シルエット化で消えるべき情報（色・半透明・Add）を持たせる。
    def drawableAt(z: Int32): GameEngine.Drawable =
        DrawCmd.make({
          texture = "", position = { x = 0.0, y = 0.0 }, scale = { x = 8.0, y = 8.0 },
          rotation = 0.0, color = { r = 1.0, g = 0.0, b = 0.0 }, alpha = 0.5,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = z, style = None, clip = None, blend = DrawCmd.BlendMode.Add, mask = Nil })

    /// z に置いた最小の多角形。grad（頂点色）はシルエット化で外れるべき情報。
    def polygonAt(z: Int32): GameEngine.PolygonRenderCmd =
        { vertices = { x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 4.0 } :: Nil,
          color = { r = 0.2, g = 0.8, b = 0.4 }, alpha = 0.5, zIndex = z,
          clip = None, blend = DrawCmd.BlendMode.Add,
          triangles = None, grad = Some({ color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0 } :: Nil) }

    @Test
    def testWorldBandDropsUiAndHud(): Unit \ Assert =
        // 既定の絞り = world の範囲（z < UI 層の底）だけが残る。UI 層と HUD の範囲は形の検査の対象外。
        let (drawables, polygons) = HeadlessRender.silhouette(HeadlessRender.SilhouetteScope.WorldBand,
            drawableAt(5) :: drawableAt(CanvasLayer.layerStride()) :: drawableAt(ZBand.hudBase()) :: Nil,
            polygonAt(3) :: polygonAt(ZBand.hudBase()) :: Nil);
        Assert.assertEq(expected = ((1, Some(5)), (1, Some(3))),
            ((List.length(drawables), List.head(drawables) |> Option.map(d -> DrawCmd.zIndexOf(d))),
             (List.length(polygons),  List.head(polygons)  |> Option.map(p -> p#zIndex))))

    /// z に置いた最小のシェーダー面。中の場（水色のグラデ）と抜き（alpha）は
    /// シルエット化で捨てられるべき情報。
    def surfaceAt(z: Int32): SoftRaster.SurfaceCmd =
        { rect = { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 8.0 } },
          spec = { name = "ground", cycleRate = 1.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({
                       shade = ShaderDoc.Shade.Ramp({ lo = { r = 0.1, g = 0.4, b = 0.5 },
                                                      hi = { r = 0.9, g = 1.0, b = 1.0 },
                                                      field = ShaderDoc.Field.Uv({ axis = ShaderDoc.Axis.U }) }),
                       alpha = ShaderDoc.Field.Const(0.25) }) },
          time = 0.0, mask = Nil, zIndex = z, blend = DrawCmd.BlendMode.Add }

    @Test
    def testSurfacesAreKeptAsSolidBlack(): Unit \ Assert =
        // 面を渡せばシルエットに写る（黒のベタ・全面 alpha 1・Normal）。
        // ここが抜けると地平線も接地も写らず、構図の検査が何も見ずに通ってしまう。
        let (_, _, surfaces) = HeadlessRender.silhouetteWith(HeadlessRender.SilhouetteScope.WorldBand,
            Nil, Nil, surfaceAt(2) :: Nil);
        Assert.assertEq(expected = Some(((0.0, 0.0, 0.0), 1.0, DrawCmd.BlendMode.Normal)),
            List.head(surfaces) |> Option.map(s -> match s#spec#out {
                case ShaderDoc.Out.Fill(f) =>
                    let ink = match f#shade {
                        case ShaderDoc.Shade.Solid(c) => Color.channels(c)
                        case _                        => (-1.0, -1.0, -1.0)
                    };
                    let a = match f#alpha {
                        case ShaderDoc.Field.Const(v) => v
                        case _                        => -1.0
                    };
                    (ink, a, s#blend)
            }))

    @Test
    def testSurfacesOutsideWorldBandAreDropped(): Unit \ Assert =
        // 絞りは Drawable と同じ物差しで面にも掛かる。
        let (_, _, surfaces) = HeadlessRender.silhouetteWith(HeadlessRender.SilhouetteScope.WorldBand,
            Nil, Nil, surfaceAt(2) :: surfaceAt(CanvasLayer.layerStride()) :: Nil);
        Assert.assertEq(expected = 1, List.length(surfaces))

    @Test
    def testAllKeepsEverythingAndBlackens(): Unit \ Assert =
        // All は絞らず全アイテムを黒の不透明・Normal にする。多角形の grad（頂点色）も外れる。
        let (drawables, polygons) = HeadlessRender.silhouette(HeadlessRender.SilhouetteScope.All,
            drawableAt(ZBand.hudBase()) :: Nil, polygonAt(3) :: Nil);
        Assert.assertEq(
            expected = (Some(((0.0, 0.0, 0.0), 1.0, DrawCmd.BlendMode.Normal)),
                        Some(((0.0, 0.0, 0.0), 1.0, DrawCmd.BlendMode.Normal, true))),
            (List.head(drawables) |> Option.map(d -> (Color.channels(DrawCmd.colorOf(d)), DrawCmd.alphaOf(d), DrawCmd.blendOf(d))),
             List.head(polygons)  |> Option.map(p ->
                 (Color.channels(p#color), p#alpha, p#blend, Option.isEmpty(p#grad)))))
}
