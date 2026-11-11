// SoftRaster3d の metallic と roughness を持つ材質の色（LightModel3d.pbrModel を回した値）を、光の無い場面で式から導いた値で確かめる。
//   光が環境光だけなら鏡面は無く、色 = albedo × (1 − metallic) × 環境光 + 映り込み。空が無い映り込みの色は環境光 + hemisphere、
//   roughness 1 では映り込みの向きが法線になり、Fresnel は F0 のまま（F0 = mix(0.04, albedo, metallic)）。
// 場面は 8×8（倍率 1）。カメラは原点で +Z を向き、板は z = 2 で画面いっぱい。値は 0 と 1 を避けて 0.5 で置く。
mod TestSoftRaster3dMetallic {
    import java.awt.image.BufferedImage

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 }

    /// 環境光 ambient の場面に、z = 2 の板（頂点の色は白）へ材質 m を付けて置く。
    def sceneOf(ambient: Color, hemisphere: Float64, m: Scene3d.Material3d): Scene3d.Scene3dCmd =
        let base = Scene3d.scene(camera(), { x = 8.0, y = 8.0 });
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(2.0, 2.0, 2.0) :: Vec3.v3(2.0, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
                                         color = gray(1.0) } :: Nil);
        { instances = (Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(m)) :: Nil,
          environment = { ambient = ambient, hemisphere = hemisphere | base#environment } | base }

    def solid(c: Color): Scene3d.Material3d =
        Scene3d.material({ name = "metallic:solid", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(1.0) }) })

    def render(scene: Scene3d.Scene3dCmd): BufferedImage \ IO =
        let req: SoftRaster.RasterReq =
            { drawables = Nil, polygons = Nil,
              design = { x = 8.0, y = 8.0 }, scale = 1, background = gray(0.0),
              texturePath = Map.empty(),
              fontTtf = "../templates/game-starter/assets/Xolonium-Regular.ttf",
              fontAtlas = { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0,
                            ascent = 12.0, descent = 4.0, lineGap = 0.0, glyphs = Map.empty() },
              outPath = "", shapeAntialias = true, textAntialias = true,
              scenes = { at = Vec2.zero(), clip = None, scene = scene } :: Nil };
        SoftRaster.renderToImageFull(req, Nil, Map.empty(), Map.empty())

    def redAt(img: BufferedImage, x: Int32, y: Int32): Int32 \ IO = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, img.getRGB(x, y)), 255)

    def byteOf(v: Float64): Int32 = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, SoftRaster.argbOfRgba(v, v, v, 1.0)), 255)

    def lin(s: Float64): Float64 = Texture3d.srgbToLinear(s)

    def screen(l: Float64): Float64 = Texture3d.linearToSrgb(l)

    def isNear(v: Float64, actual: Int32): Bool = Int32.abs(byteOf(v) - actual) <= 1

    /// metallic 0・roughness 1: 色 = albedo × 環境光 + F0（0.04）× 映り込み（環境光 + hemisphere）。hemisphere は法線が水平の板では拡散に効かない。
    @Test
    def testDielectricRoughMixesDiffuseAndFaintReflection(): Unit \ {Assert, IO} =
        let m = Scene3d.withMetallicRoughness(0.0, 1.0, solid(gray(0.5)));
        let img = render(sceneOf(gray(0.5), 0.25, m));
        let ambient = lin(0.5);
        let expected = screen(lin(0.5) * ambient + 0.04 * (ambient + 0.25));
        Assert.assertTrue(isNear(expected, redAt(img, 4, 4)))

    /// metallic 1・roughness 1: 拡散が消え、色 = albedo（F0）× 映り込み。
    @Test
    def testMetalRoughReflectsOnlyTheTintedEnvironment(): Unit \ {Assert, IO} =
        let m = Scene3d.withMetallicRoughness(1.0, 1.0, solid(gray(0.5)));
        let img = render(sceneOf(gray(0.5), 0.0, m));
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(0.5)), redAt(img, 4, 4)))

    /// 空があれば映り込みは空の色。roughness 1 では跳ね返りの向きが法線（板の法線は −Z の水平）になるので、地平の色を読む（空の平均ではない）。
    @Test
    def testRoughMetalReflectsTheSkyTowardTheNormal(): Unit \ {Assert, IO} =
        let m = Scene3d.withMetallicRoughness(1.0, 1.0, solid(gray(0.5)));
        let sky = Scene3d.gradientSky(gray(0.9), gray(0.5), gray(0.1));
        let base = sceneOf(gray(0.0), 0.0, m);
        let img = render({ sky = Some(sky) | base });
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(0.5)), redAt(img, 4, 4)))

    /// metallic・roughness を付けない材質は拡散だけ（albedo × 環境光）。付けた物と絵が違う。
    @Test
    def testMaterialWithoutMetallicRoughnessIsDiffuseOnly(): Unit \ {Assert, IO} =
        let img = render(sceneOf(gray(0.5), 0.25, solid(gray(0.5))));
        Assert.assertTrue(isNear(screen(lin(0.5) * lin(0.5)), redAt(img, 4, 4)))
}
