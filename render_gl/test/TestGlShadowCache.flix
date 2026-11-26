// TestGlShadowCache — GL の描き手が、動かない物（staticGroup）の影の地図の控え（Render3d.GlShadowCache）をコマをまたいで使い、
// 鍵（光の行列・集まり）が替わった時だけ描き直す事を、GL を呼ばない記録の GL（Render3d.FakeGl）で固定する。
mod Render3d.TestGlShadowCache {
    use Render3d.FakeGl.{cmdOf, freshRecorded, freshState, paint, recordingGl, sceneOf, timesCalled}

    def triangle(): Scene3d.Instance3d = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity())

    def lampAt(z: Float64): Scene3d.PointLight = { position = Vec3.v3(0.0, 1.0, z), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 20.0 }

    /// 集まり 1 つと、z の灯り 1 本の点光源の影の場面。
    def sceneAt(z: Float64): Scene3d.RenderCmd =
        let base = sceneOf(Nil);
        let shadowed = { maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() };
        let group = Scene3d.staticGroup("town", ("a", triangle()) :: Nil);
        cmdOf(Scene3d.withPointShadows(shadowed, { pointLights = lampAt(z) :: Nil, groups = group :: Nil | base }))

    /// cmds を 1 コマずつ同じ描き手で描き、コマごとの (控えを使い回した数, 描き直した数)。
    def countsOf(frames: List[Scene3d.RenderCmd]): List[(Int32, Int32)] \ IO =
        let state = freshState();
        let gl = recordingGl(freshRecorded());
        frames |> List.map(cmd -> {
            paint(gl, state, cmd :: Nil);
            let c = Render3d.Counts.takeCounts(state);
            (c#shadowMapsReused, c#shadowMapsRedrawn)
        })

    // 同じ場面を 3 コマ描くと、atlas の面 6 つの控えを最初のコマに描き、続くコマは使い回す。
    @Test
    def testSameLightReusesCache(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0, 6) :: (6, 0) :: (6, 0) :: Nil, countsOf(sceneAt(5.0) :: sceneAt(5.0) :: sceneAt(5.0) :: Nil))

    // 灯りが動いたコマは 6 面とも描き直し、元の位置へ戻ったコマは前の控えを使い回す。
    @Test
    def testMovedLightRedrawsAndReturningReuses(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0, 6) :: (0, 6) :: (6, 0) :: Nil, countsOf(sceneAt(5.0) :: sceneAt(4.0) :: sceneAt(5.0) :: Nil))

    // 控えを使い回すコマは、控えを地図へ写す（面ごとに glBlitFramebuffer を 1 回）。
    @Test
    def testReusedCacheIsBlittedPerFace(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let state = freshState();
        let gl = recordingGl(log);
        paint(gl, state, sceneAt(5.0) :: Nil);
        let first = timesCalled("blitFramebuffer", log);
        paint(gl, state, sceneAt(5.0) :: Nil);
        Assert.assertEq(expected = (6, 12), (first, timesCalled("blitFramebuffer", log)))
}
