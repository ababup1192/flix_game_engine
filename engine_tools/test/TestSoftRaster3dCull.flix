// CPU の描き手の視錐台の間引き（SoftRaster3d・Scene3d.isOutsideFrustum）:
//   画面の外の物を足しても絵は 1 画素も変わらない（同じ平面に重なった 2 枚の面の勝ち方も変わらない）・
//   縁をまたぐ物は描く・画面の外の物も影は落とす（影の地図は光の視錐台で間引く）。
// 場面は TestSoftRaster3d と同じ 8×8・原点から +Z を向く縦の画角 90 度のカメラ。
mod TestSoftRaster3d.Cull {
    import java.awt.image.BufferedImage

    /// 64 画素の argb。
    def pixelsOf(img: BufferedImage): List[Int32] \ IO =
        List.range(0, 64) |> List.map(k -> img.getRGB(Int32.remainder(k, 8), k / 8))

    /// 画面の外の板 3 枚: カメラの後ろ（z = −3）・far（100）の向こう（z = 200）・右の外（x 50..60）。
    def offscreen(): List[Scene3d.Instance3d] =
        TestSoftRaster3d.plate(TestSoftRaster3d.green(), -3.0, -1.0, 1.0, -1.0, 1.0)
            :: TestSoftRaster3d.plate(TestSoftRaster3d.green(), 200.0, -1.0, 1.0, -1.0, 1.0)
            :: TestSoftRaster3d.plate(TestSoftRaster3d.green(), 2.0, 50.0, 60.0, -1.0, 1.0) :: Nil

    // z = 2 に同じ大きさの赤と青の板を重ねた場面に、間引かれる板 3 枚を間に挟んでも、64 画素が全部同じ。
    @Test
    def testOffscreenInstancesDoNotChangeAnyPixel(): Unit \ {Assert, IO} =
        let red = TestSoftRaster3d.plate(TestSoftRaster3d.red(), 2.0, -1.0, 1.0, -1.0, 1.0);
        let blue = TestSoftRaster3d.plate(TestSoftRaster3d.blue(), 2.0, -1.0, 1.0, -1.0, 1.0);
        let without = TestSoftRaster3d.render(TestSoftRaster3d.sceneOf(red :: blue :: Nil));
        let withOffscreen = TestSoftRaster3d.render(TestSoftRaster3d.sceneOf(List.flatten((red :: offscreen()) :: (blue :: offscreen()) :: Nil)));
        Assert.assertEq(expected = pixelsOf(without), pixelsOf(withOffscreen))

    // 画面の外へはみ出す板（x 0.5..20・z 2）は間引かれず、画面の右端の画素（7, 4）は赤。
    @Test
    def testPlateStraddlingTheEdgeIsDrawn(): Unit \ {Assert, IO} =
        let img = TestSoftRaster3d.render(TestSoftRaster3d.sceneOf(TestSoftRaster3d.plate(TestSoftRaster3d.red(), 2.0, 0.5, 20.0, -1.0, 1.0) :: Nil));
        Assert.assertEq(expected = (255, 255, 0, 0), TestSoftRaster3d.pixel(img, 7, 4))

    // 45 度下を向くカメラの視錐台の上の面は y = 0 で、y = 1.5 の板（z 2..3）は画面の外（間引く）。
    // 真上の光（y = 3）から 1.5 下の板の影は 4 下の床で 8/3 倍に広がり z ≈ 1.2..3.8 に落ちる。画素 (4, 2) は床の z ≈ 2.2 で影の中。
    // 環境光は黒・strength 1 なので黒。
    @Test
    def testOffscreenBoardStillCastsShadow(): Unit \ {Assert, IO} =
        let board = TestSoftRaster3d.board(1.5, 2.0, 3.0);
        let lit = TestSoftRaster3d.spotLit(TestSoftRaster3d.overheadSpot(Some(TestSoftRaster3d.shadowMap(1.0))), TestSoftRaster3d.floor(TestSoftRaster3d.white()) :: board :: Nil);
        let scene = { camera = { pitch = 0.7853981633974483 | lit#camera } | lit };
        Assert.assertEq(expected = (true, (255, 0, 0, 0)),
            (Scene3d.isOutsideFrustum(Scene3d.frustumOf(scene), board), TestSoftRaster3d.pixel(TestSoftRaster3d.render(scene), 4, 2)))
}
