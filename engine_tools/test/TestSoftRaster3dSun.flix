// SoftRaster3d の太陽の光（平行光源）と影を、式から導いた値で確かめる。
//   拡散 = 色 × intensity × facing × sunLit（ambient 0・頂点の色は白なので、真上から当てた水平な床は 線形の色 = intensity）。
//   影 = 板の下の床は sunLit = 1 − strength（pcf 0・全部が影の画素）・distance の外（薄める幅の外）は影なし。
// 場面は 16 × 16（倍率 1）。カメラは (0, 6, −6) から斜め下を見て、真ん中の画素は床の (0, 0, −0.2) あたりに当たる。
mod SoftRaster3d.TestSoftRaster3dSun {

    def gray(v: Float64): Color = { r = v, g = v, b = v }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.v3(0.0, 6.0, -6.0), yaw = 0.0, pitch = 0.8, fovY = 1.0, near = 0.1, far = 100.0 }

    def up(x0: Float64, x1: Float64, z0: Float64, z1: Float64, y: Float64): Mesh3d.Polygon =
        { points = Vec3.v3(x0, y, z0) :: Vec3.v3(x0, y, z1) :: Vec3.v3(x1, y, z1) :: Vec3.v3(x1, y, z0) :: Nil, color = gray(1.0) }

    /// 白い床（y = 0）に、withBoard が真なら 4 × 4 の板（y = 3）を浮かせた場面。ambient は 0・太陽は sun。
    def sceneOf(sun: Option[Scene3d.DirectionalLight], withBoard: Bool): Scene3d.Scene3dCmd =
        let base = Scene3d.scene(camera(), { x = 16.0, y = 16.0 });
        let floor = Scene3d.meshInstance(Mesh3d.fromPolygons(up(-10.0, 10.0, -10.0, 10.0, 0.0) :: Nil), Mat4.identity());
        let board = Scene3d.meshInstance(Mesh3d.fromPolygons(up(-2.0, 2.0, -2.0, 2.0, 3.0) :: Nil), Mat4.identity());
        { instances = if (withBoard) floor :: board :: Nil else floor :: Nil, directionalLight = sun,
          environment = { ambient = gray(0.0) | base#environment } | base }

    def downward(): Scene3d.DirectionalLight =
        { intensity = 0.5 | Scene3d.directionalLight(Vec3.v3(0.0, -1.0, 0.0)) }

    def shadowSettings(): Scene3d.DirectionalShadow =
        { mapSize = 256, bias = 0.02, normalBias = 0.0, pcfRadius = 0, strength = 0.8, distance = 50.0, casterReach = 20.0 }

    def shadowed(): Scene3d.DirectionalLight =
        { shadow = Some(shadowSettings()) | downward() }

    /// 真ん中の画素の赤（0〜255）。
    def centerRed(scene: Scene3d.Scene3dCmd): Int32 \ IO =
        let img = TestSoftRaster3dSupport.renderOn(16, scene);
        Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, img.getRGB(8, 8)), 255)

    def byteOf(linear: Float64): Int32 =
        let v = Texture3d.linearToSrgb(linear);
        Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, SoftRaster.argbOfRgba(v, v, v, 1.0)), 255)

    def isNear(linear: Float64, actual: Int32): Bool = Int32.abs(byteOf(linear) - actual) <= 1

    /// 真上から当たる太陽（intensity 0.5）は、水平な床の線形の色を 0.5 にする。
    @Test
    def testSunLightsAFacingFloor(): Unit \ {Assert, IO} =
        Assert.assertTrue(isNear(0.5, centerRed(sceneOf(Some(downward()), false))))

    /// 太陽の向きの長さは問わない（長さ 2 でも 1 と同じ画素）。
    @Test
    def testDirectionLengthDoesNotMatter(): Unit \ {Assert, IO} =
        let long = { direction = Vec3.v3(0.0, -2.0, 0.0) | downward() };
        Assert.assertEq(expected = centerRed(sceneOf(Some(downward()), false)), centerRed(sceneOf(Some(long), false)))

    /// 長さ 0 の向きの太陽は太陽なしと同じ（影を付けても同じ）。
    @Test
    def testZeroLengthDirectionIsNoSun(): Unit \ {Assert, IO} =
        let none = centerRed(sceneOf(None, true));
        let zero = { direction = Vec3.zero(), shadow = Some(shadowSettings()) | downward() };
        Assert.assertEq(expected = none, centerRed(sceneOf(Some(zero), true)))

    /// intensity 0 の太陽は太陽なしと同じ（影を付けても同じ）。
    @Test
    def testZeroIntensityIsNoSun(): Unit \ {Assert, IO} =
        let none = centerRed(sceneOf(None, true));
        let off = { intensity = 0.0, shadow = Some(shadowSettings()) | downward() };
        Assert.assertEq(expected = none, centerRed(sceneOf(Some(off), true)))

    /// 太陽が面の裏から（下から上へ）当たる時は何も足さない。
    @Test
    def testSunBehindTheSurfaceAddsNothing(): Unit \ {Assert, IO} =
        let below = { direction = Vec3.v3(0.0, 1.0, 0.0) | downward() };
        Assert.assertEq(expected = centerRed(sceneOf(None, false)), centerRed(sceneOf(Some(below), false)))

    /// 板の真下の床は影に入り、光の量が 1 − strength（0.8）倍になる: 0.5 × 0.2 = 0.1。
    @Test
    def testBoardShadowsTheFloorBelowIt(): Unit \ {Assert, IO} =
        Assert.assertTrue(isNear(0.1, centerRed(sceneOf(Some(shadowed()), true))))

    /// 影を落とす物が無ければ（板なし）影は出ない。
    @Test
    def testNoCasterNoShadow(): Unit \ {Assert, IO} =
        Assert.assertTrue(isNear(0.5, centerRed(sceneOf(Some(shadowed()), false))))

    /// mapSize 0 以下は影なし（板があっても太陽だけの明るさ）。
    @Test
    def testMapSizeZeroHasNoShadow(): Unit \ {Assert, IO} =
        let flat = { shadow = Some({ mapSize = 0 | shadowSettings() }) | downward() };
        Assert.assertTrue(isNear(0.5, centerRed(sceneOf(Some(flat), true))))

    /// distance（目の前の向きに測る）が点の奥行き（約 8.4）より短いと、その点は影を受けない。
    @Test
    def testBeyondDistanceHasNoShadow(): Unit \ {Assert, IO} =
        let near = { shadow = Some({ distance = 3.0 | shadowSettings() }) | downward() };
        Assert.assertTrue(isNear(0.5, centerRed(sceneOf(Some(near), true))))

    /// 太陽の鏡面は metallic と roughness を持つ材質にだけ足される: 光の向きを目への跳ね返りの向きにそろえると（板の拡散は同じ）、
    /// 持つ材質は鏡面の分だけ明るく、持たない材質は拡散だけ。
    @Test
    def testSunSpecularOnlyOnMetallicRoughness(): Unit \ {Assert, IO} =
        let solid = Scene3d.material({ name = "sun:solid", cycleRate = 0.0, bindings = Nil,
                                       out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(gray(0.5)), alpha = ShaderDoc.Field.Const(1.0) }) });
        let toEye = Vec3.mul(Camera3d.forward(camera()), -1.0);
        let mirrored = { direction = Vec3.v3(toEye#x, -toEye#y, toEye#z) | downward() };
        let withMaterial = (m: Scene3d.Material3d) -> {
            let base = sceneOf(Some(mirrored), false);
            { instances = base#instances |> List.map(Scene3d.withMaterial(m)) | base }
        };
        let plain = centerRed(withMaterial(solid));
        let glossy = centerRed(withMaterial(Scene3d.withMetallicRoughness(0.0, 0.5, solid)));
        Assert.assertTrue(glossy > plain)
}
