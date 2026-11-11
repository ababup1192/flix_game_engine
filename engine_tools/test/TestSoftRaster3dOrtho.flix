// CPU の描き手の正射影の三角形の道（SoftRaster3d.depthMapOf・Projection.Orthographic）:
//   w = 1 なので深度は目の距離の一次・手前の面（z ≥ −w）で切り・奥は切らずに地図の「何も無い」(1) のまま。
// 光の目は目の座標の x −1..1・y −1..1・目の前 1..3 の箱（view は単位行列）。地図は 8 × 8（行 0 が NDC の y = −1 側）。
mod SoftRaster3d.TestSoftRaster3dOrtho {

    def eye(): SoftRaster3d.LightEye =
        { view = Mat4.identity(), proj = Mat4.orthographic({ left = -1.0, right = 1.0, bottom = -1.0, top = 1.0, near = 1.0, far = 3.0 }),
          projection = SoftRaster3d.Projection.Orthographic }

    /// 左（x = −1）が目の後ろ（z = 0）・右（x = 1）が目の前 2（z = −2）へ傾いた板。
    def tilted(): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-1.0, 1.0, 0.0) :: Vec3.v3(1.0, 1.0, -2.0) :: Vec3.v3(1.0, -1.0, -2.0) :: Vec3.v3(-1.0, -1.0, 0.0) :: Nil,
              color = Color.rgb(1.0, 1.0, 1.0) } :: Nil), Mat4.identity())

    /// 目の前 distance にある真正面の板（x・y −5..5 で箱の外へはみ出す）。
    def flatAt(distance: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(
            { points = Vec3.v3(-5.0, 5.0, 0.0 - distance) :: Vec3.v3(5.0, 5.0, 0.0 - distance) :: Vec3.v3(5.0, -5.0, 0.0 - distance) :: Vec3.v3(-5.0, -5.0, 0.0 - distance) :: Nil,
              color = Color.rgb(1.0, 1.0, 1.0) } :: Nil), Mat4.identity())

    def mapAt(map: Vector[Float64], x: Int32, y: Int32): Float64 = Vector.get(y * 8 + x, map)

    /// 目の前 2（near 1・far 3 の真ん中）の真正面の板は、どの画素も深度 0.5（透視なら詰まって 0.5 にならない）。
    @Test
    def testFlatPlateAtMidDepthIsHalf(): Unit \ {Assert, IO} =
        let map = SoftRaster3d.depthMapOf(flatAt(2.0) :: Nil, eye(), 8);
        Assert.assertEq(expected = (0.5, 0.5), (mapAt(map, 0, 0), mapAt(map, 7, 7)))

    /// 傾いた板（目の前 x + 1）の深度は x の一次で、地図の値は x / 2。画素 7 の真ん中（NDC x = 0.875）は 0.4375。
    @Test
    def testTiltedPlateDepthIsLinear(): Unit \ {Assert, IO} =
        let map = SoftRaster3d.depthMapOf(tilted() :: Nil, eye(), 8);
        Assert.assertTrue(Float64.abs(mapAt(map, 7, 3) - 0.4375) < 1.0e-9)

    /// 手前の面（目の前 1）より手前に出た側（画素 x ≤ 3）は切れて、地図に何も書かない（1 のまま）。
    @Test
    def testPartInFrontOfNearIsClipped(): Unit \ {Assert, IO} =
        let map = SoftRaster3d.depthMapOf(tilted() :: Nil, eye(), 8);
        Assert.assertEq(expected = (1.0, 1.0, true), (mapAt(map, 0, 3), mapAt(map, 3, 3), mapAt(map, 4, 3) < 1.0))

    /// far（目の前 3）の向こうの板は、深度が 1 を超えるので何も書かない。
    @Test
    def testPlateBeyondFarWritesNothing(): Unit \ {Assert, IO} =
        let map = SoftRaster3d.depthMapOf(flatAt(5.0) :: Nil, eye(), 8);
        Assert.assertEq(expected = Vector.repeat(64, 1.0), map)

    /// 目の後ろの板は何も書かない（透視の w ≤ 0 と違い、正射影は z ≥ −w の切りで落とす）。
    @Test
    def testPlateBehindEyeWritesNothing(): Unit \ {Assert, IO} =
        let map = SoftRaster3d.depthMapOf(flatAt(-2.0) :: Nil, eye(), 8);
        Assert.assertEq(expected = Vector.repeat(64, 1.0), map)
}
