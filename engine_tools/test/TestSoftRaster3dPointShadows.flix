// SoftRaster3d の点光源の影と光の量の読み方（Physical）を、式から導いた値で確かめる。
//   床（y = 0）の真ん中の画素の上に点光源（y = 4）を置き、withBoard なら間に 4 × 4 の板（y = 2）を浮かせる。ambient は 0・頂点の色は白。
//   影 = 板の真下の床の光は 1 − strength 倍（pcf 0・全部が影）。Physical = 逆二乗 × 窓・拡散に 1/π。
// 場面は 16 × 16（倍率 1）。カメラは (0, 6, −6) から斜め下を見て、真ん中の画素は床の (0, 0, −0.2) あたりに当たる。
mod SoftRaster3d.TestSoftRaster3dPointShadows {

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.v3(0.0, 6.0, -6.0), yaw = 0.0, pitch = 0.8, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    def up(x0: Float64, x1: Float64, z0: Float64, z1: Float64, y: Float64): Mesh3d.Polygon =
        { points = Vec3.v3(x0, y, z0) :: Vec3.v3(x0, y, z1) :: Vec3.v3(x1, y, z1) :: Vec3.v3(x1, y, z0) :: Nil, color = gray(1.0) }

    def lamp(): Scene3d.PointLight =
        { position = Vec3.v3(0.0, 4.0, -0.2), color = gray(1.0), intensity = 0.5, range = 40.0 }

    pub def sceneOf(withBoard: Bool): Scene3d.Scene3dCmd =
        let base = Scene3d.scene(camera(), { x = 16.0, y = 16.0 });
        let floor = Scene3d.meshInstance(Mesh3d.fromPolygons(up(-10.0, 10.0, -10.0, 10.0, 0.0) :: Nil), Mat4.identity());
        let board = Scene3d.meshInstance(Mesh3d.fromPolygons(up(-2.0, 2.0, -2.2, 1.8, 2.0) :: Nil), Mat4.identity());
        { instances = if (withBoard) floor :: board :: Nil else floor :: Nil, pointLights = lamp() :: Nil,
          environment = { ambient = gray(0.0) | base#environment } | base }

    pub def shadowMap(): Scene3d.PointShadowMap =
        { mapSize = 64, pcfRadius = 0, bias = 0.02, normalBias = 1.0, strength = 0.8 | Scene3d.pointShadowMap() }

    def centerRed(scene: Scene3d.Scene3dCmd): Int32 \ IO =
        let img = TestSoftRaster3dSupport.renderOn(16, scene);
        Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, img.getRGB(8, 8)), 255)

    def allPixels(scene: Scene3d.Scene3dCmd): List[Int32] \ IO =
        let img = TestSoftRaster3dSupport.renderOn(16, scene);
        List.range(0, 256) |> List.map(k -> img.getRGB(k - (k / 16) * 16, k / 16))

    /// 板の真下の床は点光源の影に入り、明るさが下がる。
    @Test
    def testBoardShadowsTheFloorBelowTheLamp(): Unit \ {Assert, IO} =
        let lit = centerRed(sceneOf(true));
        let shadowed = centerRed(sceneOf(true) |> Scene3d.withPointShadows(shadowMap()));
        Assert.assertTrue(shadowed < lit)

    /// 影の中の光は 1 − strength 倍: 影なしの光の量 × 0.2 と 1 段の差で合う。
    @Test
    def testShadowKeepsOneMinusStrength(): Unit \ {Assert, IO} =
        let open = centerRed(sceneOf(false));
        let shadowed = centerRed(sceneOf(true) |> Scene3d.withPointShadows(shadowMap()));
        let expected = Texture3d.linearToSrgb(Texture3d.srgbToLinear(Int32.toFloat64(open) / 255.0) * 0.2) * 255.0;
        Assert.assertTrue(Float64.abs(Int32.toFloat64(shadowed) - expected) <= 2.0)

    /// 影を落とす物が無ければ、影ありの設定でも絵は影なしと画素まで同じ。
    @Test
    def testNoCasterKeepsPixels(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = allPixels(sceneOf(false)), allPixels(sceneOf(false) |> Scene3d.withPointShadows(shadowMap())))

    /// 上限 0 本の設定は影なしと画素まで同じ。
    @Test
    def testZeroShadowedLightsKeepsPixels(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = allPixels(sceneOf(true)), allPixels(sceneOf(true) |> Scene3d.withPointShadows({ maxShadowedLights = 0 | shadowMap() })))

    /// Physical の光: 拡散の点光源の光は intensity × 窓 / d² / π（d = 4 m・窓はほぼ 1）。
    @Test
    def testPhysicalPointIsInverseSquareOverPi(): Unit \ Assert =
        let env = { ambient = gray(0.0) | Scene3d.scene(camera(), { x = 1.0, y = 1.0 })#environment };
        let light = { position = Vec3.v3(0.0, 4.0, 0.0), color = gray(1.0), intensity = 3.0, range = 400.0 };
        let c = SoftRaster3d.lightWithUnitsAt(env, light :: Nil, Nil, Scene3d.LightUnits.Physical, 1.0, Vec3.zero(), Vec3.v3(0.0, 1.0, 0.0));
        let ratio = 16.0 / 160000.0;
        let window = (1.0 - ratio * ratio) * (1.0 - ratio * ratio);
        Assert.assertTrue(Float64.abs(c#r - 3.0 * window / 16.0 / Num.pi()) < 1.0e-9)

    /// Physical の逆二乗は m で測る: 1 m = 16 の場面で 64 離れた光は、1 m = 1 の場面で 4 離れた光と同じ量。
    @Test
    def testPhysicalMeasuresMeters(): Unit \ Assert =
        let env = { ambient = gray(0.0) | Scene3d.scene(camera(), { x = 1.0, y = 1.0 })#environment };
        let at = (h: Float64, range: Float64, upm: Float64) ->
            SoftRaster3d.lightWithUnitsAt(env, { position = Vec3.v3(0.0, h, 0.0), color = gray(1.0), intensity = 3.0, range = range } :: Nil, Nil,
                                          Scene3d.LightUnits.Physical, upm, Vec3.zero(), Vec3.v3(0.0, 1.0, 0.0))#r;
        Assert.assertTrue(Float64.abs(at(64.0, 6400.0, 16.0) - at(4.0, 400.0, 1.0)) < 1.0e-12)

    /// Legacy の lightWithUnitsAt は lightAt と同じ値（ビットまで）。
    @Test
    def testLegacyUnitsMatchLightAt(): Unit \ Assert =
        let env = { ambient = gray(0.1) | Scene3d.scene(camera(), { x = 1.0, y = 1.0 })#environment };
        let light = { position = Vec3.v3(0.3, 2.0, 0.1), color = Color.rgb(1.0, 0.7, 0.4), intensity = 1.5, range = 6.0 };
        let p = Vec3.v3(0.2, 0.0, -0.1);
        let n = Vec3.v3(0.0, 1.0, 0.0);
        let a = SoftRaster3d.lightAt(env, light :: Nil, Nil, p, n);
        let b = SoftRaster3d.lightWithUnitsAt(env, light :: Nil, Nil, Scene3d.LightUnits.Legacy, 16.0, p, n);
        Assert.assertEq(expected = (a#r, a#g, a#b), (b#r, b#g, b#b))
}
