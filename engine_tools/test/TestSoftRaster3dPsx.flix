// CPU の描き手の PS1 風の描き方（Scene3d.PsxLook）: 切っていれば絵は同じ・色の丸め・頂点の丸め・アフィンの uv。
// 場面は 8×8（design・倍率 1）。カメラは原点で +Z を向き、縦の画角 90 度なので、奥行き z の点 (x, y) は画面の x = (x / z + 1) × 4・y = (1 − y / z) × 4 に写る。
mod TestSoftRaster3dPsx {
    import java.awt.image.BufferedImage

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    /// 奥行き z に立つ板（x は left..right・y は −1..1）。
    def plate(color: Color, z: Float64, left: Float64, right: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(left, 1.0, z) :: Vec3.v3(right, 1.0, z) :: Vec3.v3(right, -1.0, z) :: Vec3.v3(left, -1.0, z) :: Nil,
              color = color } :: Nil), Mat4.identity())

    def sceneOf(instances: List[Scene3d.Instance3d]): Scene3d.Scene3dCmd =
        { instances = instances | Scene3d.scene(camera(), { x = 8.0, y = 8.0 }) }

    def render(scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let req: SoftRaster.RasterReq =
            { drawables = Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1, background = Color.rgb(0.0, 0.0, 0.0),
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true,
              scenes = { at = Vec2.zero(), clip = None, scene = scene } :: Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map.empty())

    def pixels(img: BufferedImage): List[Int32] \ IO =
        List.range(0, 64) |> List.map(i -> img.getRGB(Int32.remainder(i, 8), i / 8))

    def red(img: BufferedImage, x: Int32, y: Int32): Int32 \ IO = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, img.getRGB(x, y)), 255)

    /// 灰色の板（環境光 0.51 だけ。画面の値は 8 bit で 130 = 5 ビットの段の境目 128 の近く）。
    def grayPlate(): Scene3d.Scene3dCmd =
        let s = sceneOf(plate(Color.rgb(1.0, 1.0, 1.0), 2.0, -1.0, 1.0) :: Nil);
        { environment = { ambient = Color.rgb(0.51, 0.51, 0.51) | s#environment } | s }

    @Test
    def testOffLooksTheSame(): Unit \ {Assert, IO} =
        let look = { dither = Scene3d.DitherPattern.Bayer4x4, ditherStrength = 2.0 | Scene3d.psxOff() };
        Assert.assertEq(expected = pixels(render(grayPlate())), pixels(render(Scene3d.withPsx(look, grayPlate()))))

    /// 5 ビット・ディザなしでは、板の画素の赤は 31 段の値（q × 255 / 31 を丸めた物）のどれか。
    @Test
    def testFiveBitsLandOnThirtyOneSteps(): Unit \ {Assert, IO} =
        let img = render(Scene3d.withPsx({ colorDepth = 5, dither = Scene3d.DitherPattern.Off | Scene3d.psxOff() }, grayPlate()));
        let steps = List.range(0, 32) |> List.map(q -> Float64.round(Int32.toFloat64(q) * 255.0 / 31.0) |> Float64.tryToInt32 |> Option.getWithDefault(-1));
        Assert.assertTrue(List.memberOf(red(img, 4, 4), steps))

    /// 板の灰（8 bit で 130）は 31 段の値に無いので、5 ビットに丸めると丸めない時と違う値になる。
    @Test
    def testFiveBitsChangeTheGray(): Unit \ {Assert, IO} =
        let img = render(Scene3d.withPsx({ colorDepth = 5, dither = Scene3d.DitherPattern.Off | Scene3d.psxOff() }, grayPlate()));
        Assert.assertFalse(red(img, 4, 4) == red(render(grayPlate()), 4, 4))

    /// ディザの表は 4×4 の格子で画素ごとに足す量を変えるので、同じ色の板でも隣り合う画素の値が分かれる。
    @Test
    def testDitherSplitsAFlatColor(): Unit \ {Assert, IO} =
        let img = render(Scene3d.withPsx({ colorDepth = 5 | Scene3d.psxOff() }, grayPlate()));
        let row = List.range(2, 6) |> List.map(x -> red(img, x, 4)) |> List.toSet;
        Assert.assertTrue(Set.size(row) > 1)

    /// 左の縁が画面の x = 2.6 の板。丸めなしなら画素 2（真ん中 2.5）は塗らず、格子 2 で丸めると縁が 2 へ動いて塗る。
    @Test
    def testWithoutVertexSnapTheEdgePixelStaysEmpty(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0, red(render(sceneOf(plate(Color.rgb(1.0, 0.0, 0.0), 2.0, -0.7, 1.0) :: Nil)), 2, 4))

    @Test
    def testVertexSnapMovesAnEdge(): Unit \ {Assert, IO} =
        let s = sceneOf(plate(Color.rgb(1.0, 0.0, 0.0), 2.0, -0.7, 1.0) :: Nil);
        Assert.assertTrue(red(render(Scene3d.withPsx({ vertexSnap = 2.0 | Scene3d.psxOff() }, s)), 2, 4) > 0)

    def pairOf(uv: { x = Float64, y = Float64 }): (Float64, Float64) = (uv#x, uv#y)

    /// 遠近で補正した uv (0.25, 0.5)・頂点の (u × w, v × w) を補正した重みで足した物 (1.5, 0.75)・depth 2 → 画面の重みの uv は (0.75, 0.375)。
    @Test
    def testAffineUvAtZeroKeepsThePerspectiveUv(): Unit \ Assert =
        Assert.assertEq(expected = (0.25, 0.5), pairOf(SoftRaster3d.Psx.affineUv(0.0, 2.0, (0.25, 0.5), (1.5, 0.75))))

    @Test
    def testAffineUvAtOneIsTheScreenWeightedUv(): Unit \ Assert =
        Assert.assertEq(expected = (0.75, 0.375), pairOf(SoftRaster3d.Psx.affineUv(1.0, 2.0, (0.25, 0.5), (1.5, 0.75))))

    @Test
    def testAffineUvAtHalfMixesTheTwo(): Unit \ Assert =
        Assert.assertEq(expected = (0.5, 0.4375), pairOf(SoftRaster3d.Psx.affineUv(0.5, 2.0, (0.25, 0.5), (1.5, 0.75))))
}
