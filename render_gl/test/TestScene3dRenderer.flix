// 2D の描き手が 3D の描き手に問う関数のうち、GL 無しで答えが決まる所。何も描かない描き手（Scene3dRenderer.none）と、
// デスクトップの描き手が Pass の写しを読むかを決める判定（Render3d.readsTexture）。

mod TestScene3dRenderer {

    def camera(): Camera3d.Camera3d =
        { eye = { x = 0.0, y = 0.0, z = 0.0 }, yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }

    def sceneWithBillboard(texture: String): Scene3d.RenderCmd =
        let b = Scene3d.billboard(texture, { position = { x = 0.0, y = 0.0 }, size = { x = 1.0, y = 1.0 } },
                                  { x = 0.0, y = 0.0, z = 1.0 }, { x = 1.0, y = 1.0 });
        { at = { x = 0.0, y = 0.0 }, clip = None,
          scene = { billboards = b :: Nil | Scene3d.scene(camera(), { x = 10.0, y = 10.0 }) } }

    /// 場面の無い並びは番号を 1 つも持たない。
    @Test
    def testNoScenesHasNoNumbers(): Unit \ Assert =
        Assert.assertEq(expected = 0, Vector.length(Scene3dRenderer.noScenes()#zIndexes))

    /// 何も描かない描き手は、積んだ場面を捨てて番号を 1 つも返さない。
    @Test
    def testNonePreparesNoNumbers(): Unit \ {Assert, IO} =
        let prepared = Scene3dRenderer.none()#prepare(0i64, _ -> checked_ecast(None), { framebuffer = 0, format = RenderTarget.Format.Rgba8Unorm, samples = 1 },
                                                      sceneWithBillboard("hist") :: Nil);
        Assert.assertEq(expected = 0, Vector.length(prepared#zIndexes))

    /// ビルボードが貼る絵の名前なら貼ると答える。
    @Test
    def testReadsBillboardTexture(): Unit \ Assert =
        Assert.assertTrue(Render3d.readsTexture("hist", sceneWithBillboard("other") :: sceneWithBillboard("hist") :: Nil))

    /// どのビルボードも貼らない名前なら貼らないと答える。
    @Test
    def testIgnoresOtherTexture(): Unit \ Assert =
        Assert.assertFalse(Render3d.readsTexture("hist", sceneWithBillboard("other") :: Nil))

    /// 場面が無ければ貼らないと答える。
    @Test
    def testNoScenesReadNothing(): Unit \ Assert =
        Assert.assertFalse(Render3d.readsTexture("hist", Nil))
}
