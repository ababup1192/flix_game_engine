// SoftRaster3d に材質の AO の絵（Scene3d.withOcclusionTexture）を付けた材質を通す: 環境の光だけの面は暗くなり、点光源だけの面は変わらない。
// 場面は 8×8（倍率 1）。カメラは原点で +Z を向き、板は z = 2 で画面いっぱい。AO の絵は 1 × 1 で R = 64（AO ≒ 0.25）。
mod TestSoftRaster3dMaterialOcclusionScene {
    import java.awt.image.BufferedImage

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    def aoTexture(): Texture3d.Texture3d =
        match Texture3d.fromArgb(1, 1, Vector#{ Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(64, 16)) }) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    def material(occluded: Bool): Scene3d.Material3d =
        let base = Scene3d.material({ name = "occlusion:solid", cycleRate = 0.0, bindings = Nil,
                                      out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(gray(0.5)), alpha = ShaderDoc.Field.Const(1.0) }) })
                   |> Scene3d.withMetallicRoughness(0.0, 1.0);
        if (occluded) Scene3d.withOcclusionTexture(Texture3d.name(aoTexture()), 1.0, base) else base

    /// 環境光 ambient と点光源 points の場面に、z = 2 の板（uv つき・頂点の色は白）へ材質 m を付けて置く。
    def sceneOf(ambient: Color, points: List[Scene3d.PointLight], m: Scene3d.Material3d): Scene3d.Scene3dCmd =
        let base = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0, lensShift = Vec2.zero() },
                                 { x = 8.0, y = 8.0 });
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(2.0, 2.0, 2.0) :: Vec3.v3(2.0, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
                                         color = gray(1.0) } :: Nil) |> Mesh3d.withBoxUvs(1.0);
        { instances = (Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(m)) :: Nil, pointLights = points, textures = aoTexture() :: Nil,
          environment = { ambient = ambient, hemisphere = 0.0 | base#environment } | base }

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

    def ambientOnly(occluded: Bool): Int32 \ IO = redAt(render(sceneOf(gray(0.6), Nil, material(occluded))), 4, 4)

    def pointOnly(occluded: Bool): Int32 \ IO =
        let light = { position = Vec3.v3(0.0, 0.0, 0.5), color = gray(1.0), intensity = 1.0, range = 10.0 };
        redAt(render(sceneOf(gray(0.0), light :: Nil, material(occluded))), 4, 4)

    /// 環境の光だけの面は、AO の絵を付けると暗くなる。
    @Test
    def testAmbientOnlySurfaceIsDarkened(): Unit \ {Assert, IO} =
        Assert.assertTrue(ambientOnly(true) < ambientOnly(false))

    /// 点光源だけの面は、AO の絵を付けても変わらない（直接光と鏡面には掛からない）。
    @Test
    def testPointLightOnlySurfaceIsUnchanged(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = pointOnly(false), pointOnly(true))
}
