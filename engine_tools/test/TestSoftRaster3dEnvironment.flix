// SoftRaster3d の環境マップ（周りの景色のパノラマ）の映り込みを、式から導いた値で確かめる。
//   跳ね返りの向き → 絵の座標（LightModel3d.environmentUvOf）→ 段つきの Repeat・Linear の読み → 線形へ戻して強さを掛ける。
//   箱の補正は SoftRaster3dLight.environmentDirectionAt（LightModel3d.environmentDirection の木）の向きで確かめる。
// 場面は 8×8（倍率 1）。カメラは原点で +Z を向き、板は z = 2 で画面いっぱい（法線は −Z）。
mod TestSoftRaster3dEnvironment {
    import java.awt.image.BufferedImage

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.5707963267948966, near = 0.1, far = 100.0 }

    def argbOf(r: Int32, g: Int32, b: Int32): Int32 =
        Int32.bitwiseOr(-16777216, Int32.bitwiseOr(Int32.leftShift(r, 16), Int32.bitwiseOr(Int32.leftShift(g, 8), b)))

    /// 横 4・縦 2 の単色の絵（128 は 0.5 に近い灰色）。
    def solidPanorama(r: Int32, g: Int32, b: Int32): Texture3d.Texture3d =
        match Texture3d.fromArgb(4, 2, Vector.repeat(8, argbOf(r, g, b))) {
            case Ok(t)  => t
            case Err(_) => bug!("TestSoftRaster3dEnvironment: 絵が作れない")
        }

    def solid(c: Color): Scene3d.Material3d =
        Scene3d.material({ name = "environment:solid", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(1.0) }) })

    /// 光の無い場面に、z = 2 の板へ metallic 1・roughness 1・灰色 0.5 の材質を置き、環境マップ env（None なら無し）を映す。
    def sceneOf(env: Option[Scene3d.EnvironmentMap], textures: List[Texture3d.Texture3d]): Scene3d.Scene3dCmd =
        let base = Scene3d.scene(camera(), { x = 8.0, y = 8.0 });
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(-2.0, 2.0, 2.0) :: Vec3.v3(2.0, 2.0, 2.0) :: Vec3.v3(2.0, -2.0, 2.0) :: Vec3.v3(-2.0, -2.0, 2.0) :: Nil,
                                         color = gray(1.0) } :: Nil);
        let m = Scene3d.withMetallicRoughness(1.0, 1.0, solid(gray(0.5)));
        { instances = (Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(m)) :: Nil,
          environment = { ambient = gray(0.0), hemisphere = 0.0 | base#environment },
          environmentMap = env, textures = textures | base }

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

    def channelAt(img: BufferedImage, shift: Int32, x: Int32, y: Int32): Int32 \ IO = Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, img.getRGB(x, y)), 255)

    def lin(s: Float64): Float64 = Texture3d.srgbToLinear(s)

    def screenByte(l: Float64): Int32 = Float64.tryToInt32(Float64.round(Texture3d.linearToSrgb(l) * 255.0)) |> Option.getWithDefault(0)

    def isNear(expected: Int32, actual: Int32): Bool = Int32.abs(expected - actual) <= 1

    /// 色 = F0（灰色 0.5 の線形）× 景色の色（線形）。roughness 1 の跳ね返りの向きは法線（−Z）で、絵の真ん中を読む。
    @Test
    def testMetalReflectsThePanorama(): Unit \ {Assert, IO} =
        let tex = solidPanorama(128, 128, 128);
        let img = render(sceneOf(Some(Scene3d.environmentMap(tex)), tex :: Nil));
        let expected = screenByte(lin(0.5) * lin(128.0 / 255.0));
        Assert.assertTrue(isNear(expected, channelAt(img, 16, 4, 4)))

    /// 景色の色が材質の色を通して映る（赤い景色は赤の成分だけ）。
    @Test
    def testPanoramaColorChannelsAreKept(): Unit \ {Assert, IO} =
        let tex = solidPanorama(255, 0, 0);
        let img = render(sceneOf(Some(Scene3d.environmentMap(tex)), tex :: Nil));
        Assert.assertTrue(isNear(screenByte(lin(0.5)), channelAt(img, 16, 4, 4)) and channelAt(img, 8, 4, 4) == 0 and channelAt(img, 0, 4, 4) == 0)

    /// 強さ 0 は映り込みが無い（拡散も無い金属なので黒）。
    @Test
    def testZeroIntensityReflectsNothing(): Unit \ {Assert, IO} =
        let tex = solidPanorama(128, 128, 128);
        let env = Scene3d.environmentMap(tex) |> Scene3d.withEnvironmentIntensity(0.0);
        let img = render(sceneOf(Some(env), tex :: Nil));
        Assert.assertEq(expected = 0, channelAt(img, 16, 4, 4))

    /// 強さは線形の量に掛かる（0.5 倍なら景色の線形の量が半分）。
    @Test
    def testIntensityScalesTheLinearColor(): Unit \ {Assert, IO} =
        let tex = solidPanorama(128, 128, 128);
        let env = Scene3d.environmentMap(tex) |> Scene3d.withEnvironmentIntensity(0.5);
        let img = render(sceneOf(Some(env), tex :: Nil));
        Assert.assertTrue(isNear(screenByte(lin(0.5) * lin(128.0 / 255.0) * 0.5), channelAt(img, 16, 4, 4)))

    /// 環境マップが無い場面は、空（無ければ ambient + hemisphere = 黒）を映す。環境マップを付けた絵とは違う。
    @Test
    def testWithoutEnvironmentMapReflectsTheSky(): Unit \ {Assert, IO} =
        let tex = solidPanorama(128, 128, 128);
        let img = render(sceneOf(None, tex :: Nil));
        Assert.assertEq(expected = 0, channelAt(img, 16, 4, 4))

    // ── 背景 ──

    /// 景色を背景に描くと、何も描かれない画素が景色の色になる（単色の景色は強さ 1 でそのまま）。sky があれば sky が勝つ。
    @Test
    def testEnvironmentAsBackgroundFillsEmptyPixels(): Unit \ {Assert, IO} =
        let tex = solidPanorama(200, 100, 50);
        let env = Scene3d.environmentMap(tex) |> Scene3d.withEnvironmentAsBackground(true);
        let empty = { instances = Nil | sceneOf(Some(env), tex :: Nil) };
        let img = render(empty);
        Assert.assertTrue(isNear(200, channelAt(img, 16, 4, 4)) and isNear(100, channelAt(img, 8, 4, 4)) and isNear(50, channelAt(img, 0, 4, 4)))

    /// asBackground が偽（既定）なら背景に描かない（地の色のまま）。
    @Test
    def testEnvironmentMapIsNotBackgroundByDefault(): Unit \ {Assert, IO} =
        let tex = solidPanorama(200, 100, 50);
        let empty = { instances = Nil | sceneOf(Some(Scene3d.environmentMap(tex)), tex :: Nil) };
        Assert.assertEq(expected = 0, channelAt(render(empty), 16, 4, 4))

    /// 背景の強さは線形に掛かる（0 なら黒）。
    @Test
    def testBackgroundIntensityZeroIsBlack(): Unit \ {Assert, IO} =
        let tex = solidPanorama(200, 100, 50);
        let env = Scene3d.environmentMap(tex) |> Scene3d.withEnvironmentAsBackground(true) |> Scene3d.withEnvironmentIntensity(0.0);
        let empty = { instances = Nil | sceneOf(Some(env), tex :: Nil) };
        Assert.assertEq(expected = 0, channelAt(render(empty), 16, 4, 4))

    // ── 箱の補正 ──

    def directionOf(p: (Float64, Float64, Float64), eye: (Float64, Float64, Float64), box: Option[Scene3d.EnvironmentBox]): (Float64, Float64, Float64) =
        let (px, py, pz) = p;
        let (ex, ey, ez) = eye;
        let zero = Vec3.v3(0.0, 0.0, 0.0);
        let b = box |> Option.getWithDefault({ min = zero, max = zero, center = zero });
        SoftRaster3dLight.environmentDirectionAt(px, py, pz, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, ex, ey, ez,
                                                 b#min#x, b#min#y, b#min#z, b#max#x, b#max#y, b#max#z, b#center#x, b#center#y, b#center#z,
                                                 if (Option.isEmpty(box)) 0.0 else 1.0)

    def room(): Scene3d.EnvironmentBox =
        { min = Vec3.v3(-4.0, 0.0, -4.0), max = Vec3.v3(4.0, 4.0, 4.0), center = Vec3.v3(0.0, 1.5, 0.0) }

    def isDirection(expected: (Float64, Float64, Float64), actual: (Float64, Float64, Float64)): Bool =
        let (ex, ey, ez) = expected;
        let (ax, ay, az) = actual;
        Float64.abs(ex - ax) < 1.0e-9 and Float64.abs(ey - ay) < 1.0e-9 and Float64.abs(ez - az) < 1.0e-9

    /// 箱が無ければ跳ね返りの向きのまま（床の点から (−0.6, 0.8, 0) へ見る → (0.6, 0.8, 0) へ跳ねる）。
    @Test
    def testWithoutBoxTheDirectionIsTheReflection(): Unit \ Assert =
        Assert.assertTrue(isDirection((0.6, 0.8, 0.0), directionOf((3.5, 0.0, 0.0), (3.5 - 0.6, 0.8, 0.0), None)))

    /// center から真っすぐ伸びる線は、箱で補正しても同じ向き（center の真下の点から真上へ）。
    @Test
    def testBoxKeepsTheDirectionOfALineThroughTheCenter(): Unit \ Assert =
        Assert.assertTrue(isDirection((0.0, 1.0, 0.0), directionOf((0.0, 0.0, 0.0), (0.0, 1.0, 0.0), Some(room()))))

    /// 壁に近い点（x = 3.5）から (0.6, 0.8, 0) へ跳ねる線は、x = 4 の壁の (4, 2/3, 0) に当たり、center (0, 1.5, 0) から見た向きで景色を読む。
    @Test
    def testBoxProjectsTheLineOntoTheWall(): Unit \ Assert =
        let hit = (4.0, 0.5 / 0.6 * 0.8, 0.0);
        let (hx, hy, hz) = hit;
        let (ox, oy, oz) = (hx, hy - 1.5, hz);
        let len = Num.sqrt(ox * ox + oy * oy + oz * oz);
        Assert.assertTrue(isDirection((ox / len, oy / len, oz / len), directionOf((3.5, 0.0, 0.0), (3.5 - 0.6, 0.8, 0.0), Some(room()))))
}
