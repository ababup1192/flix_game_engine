// TestPlatform — Platform の何もしない handler（3D を描かない handler の組が張る物）。

mod TestPlatform {

    /// 積む場面 1 つ（中身は問わない）。
    def anyScene(): Scene3d.RenderCmd =
        { at = Vec2.zero(), clip = None,
          scene = Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }, { x = 200.0, y = 100.0 }) }

    // runNoopDraw3d の中で 3D の場面を積んでも、本体の答えはそのまま返る。
    @Test
    def testRunNoopDraw3dKeepsTheResult(): Unit \ Assert =
        Assert.assertEq(expected = 7, Platform.runNoopDraw3d(() -> { Platform.Draw3d.drawScene3d(anyScene()); 7 }))
}
