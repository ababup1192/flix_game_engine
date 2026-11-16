// WebGPU の 3D の描き手の、GPU を呼ばない所（場面の値を R3dScene の欄の位置へ詰める・矩形の上下の向き・まだ描けない物の数え）を固定する。
// 欄の位置は Render3dWgsl.sceneDeclarations の並び（vec3 の後ろの 4 バイトに f32 か i32・光の配列は 400 バイト目から 16 バイト刻みの vec4）。
// WhyNot: mod TestWebGpuScene3d にしない — topLeftOf は Render3d.WebGpuRenderer の中の pub でない関数で、子のモジュールからしか呼べない。
mod Render3d.WebGpuRenderer.TestWebGpuScene3d {
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.WebGpuRenderer.{packSceneValues, sceneValueBytes, skipsOf, topLeftOf}

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(1.0, 2.0, 3.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 }

    def light(x: Float64, range: Float64): Scene3d.PointLight =
        { position = Vec3.v3(x, 4.0, 5.0), color = Color.rgb(1.0, 0.5, 0.25), intensity = 2.0, range = range }

    def scene(): Scene3d.Scene3dCmd =
        { pointLights = light(6.0, 7.0) :: light(8.0, 9.0) :: Nil,
          environment = { ambient = Color.rgb(0.2, 0.3, 0.4), hemisphere = 0.25, toonSteps = 3,
                          fog = Some({ color = Color.rgb(0.1, 0.1, 0.1), near = 10.0, far = 50.0 }), background = None }
          | Scene3d.scene(camera(), { x = 320.0, y = 180.0 }) }

    def packed(): ByteBuffer \ IO =
        let buf = ByteBuffer.allocate(sceneValueBytes()).order(ByteOrder.LITTLE_ENDIAN);
        packSceneValues(buf, Render3d.Light.lightDataOf(scene(), 0));
        buf

    /// 頭の欄: 環境光の r（0）・hemisphere（12）・目の x（16）・toonSteps（28）・かすみ（44）・かすみの遠い端（52）・点光源の数（56）。
    @Test
    def testHeadFieldsSitAtWgslOffsets(): Unit \ {Assert, IO} =
        let d = Render3d.Light.lightDataOf(scene(), 0);
        let buf = packed();
        Assert.assertEq(expected = (Array.get(0, d#ambient), 0.25f32, 1.0f32, 3, 1, 50.0f32, 2),
                        (buf.getFloat(0), buf.getFloat(12), buf.getFloat(16), buf.getInt(28), buf.getInt(44), buf.getFloat(52), buf.getInt(56)))

    /// 光の配列: 2 本目の点光源の x は 400 + 16 バイト目・その range は uPointRange[1].x（400 + 32 × 点光源の上限 + 16 バイト目）。
    @Test
    def testPointLightArraysAreVec4Strided(): Unit \ {Assert, IO} =
        let p = Scene3d.maxPointLights();
        let buf = packed();
        Assert.assertEq(expected = (8.0f32, 9.0f32), (buf.getFloat(400 + 16), buf.getFloat(400 + 32 * p + 16)))

    /// 影と奥行きの書き出しは切る: uSunShadowOn（76）・uShadowOn（220）・uDepthOut（248）が 0・uShadowSpot（232）が -1。
    @Test
    def testShadowAndDepthOutputAreOff(): Unit \ {Assert, IO} =
        let buf = packed();
        Assert.assertEq(expected = (0, 0, 0, -1), (buf.getInt(76), buf.getInt(220), buf.getInt(248), buf.getInt(232)))

    // ── まだ描けない物の数え（skipsOf）──

    def wood(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:0123456789abcdef", ShaderDoc.FilterMode.Nearest)

    def skinnedWithMaterial(at: Vec3.Vec3): Scene3d.Instance3d =
        Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.translate(at))
            |> Scene3d.withPose(Render3d.FakeGl.poseAt(0.0)) |> Scene3d.withMaterial(wood())

    def plainWithMaterial(at: Vec3.Vec3): Scene3d.Instance3d =
        Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.translate(at)) |> Scene3d.withMaterial(wood())

    /// 場面 1 つを計画の候補に分けて、まだ描けない物の種類と回数を返す。
    def skipsOfScene(scene: Scene3d.Scene3dCmd): Map[String, Int32] \ IO =
        let grouped = Render3d.ScenePlan.groupScenes(Render3d.ScenePlan.freshPlanner(Render3d.DrawMode.Instanced), { alphaToOne = false, poseRowLimit = 0 }, 1,
                                                     Render3d.FakeGl.cmdOf(scene) :: Nil);
        grouped#scenes |> List.flatMap(skipsOf(grouped#members)) |> List.toMap

    /// Output.Depth の場面は奥行きの書き出しの 1 回だけで、中身（材質の物・骨つきの物）は数えない。
    @Test
    def testDepthSceneCountsOnlyTheDepthOutput(): Unit \ {Assert, IO} =
        let scene = { output = Scene3d.Output.Depth({ near = 0.1, range = 10.0 }) | Render3d.FakeGl.sceneOf(skinnedWithMaterial(Vec3.zero()) :: plainWithMaterial(Vec3.zero()) :: Nil) };
        Assert.assertEq(expected = Map#{"3D の奥行きの書き出し（Output.Depth）" => 1}, skipsOfScene(scene))

    /// 材質つきの骨つきの物は骨つきの物として 1 回だけ数え、材質の物には数えない。
    @Test
    def testSkinnedWithMaterialIsCountedOnce(): Unit \ {Assert, IO} =
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(skinnedWithMaterial(Vec3.zero()) :: Nil));
        Assert.assertEq(expected = (Some(1), Some(0)), (Map.get("3D の骨つきの物", skips), Map.get("3D の材質の物（頂点の色で描く）", skips)))

    /// 視錐台の外（目の後ろ）の材質の物は数えない。骨つきの物は計画が間引かない（Scene3d.isOutsideFrustum がいつも偽・GL も描く）ので目の後ろでも数える。
    @Test
    def testCulledThingsAreNotCounted(): Unit \ {Assert, IO} =
        let behind = Vec3.v3(0.0, 0.0, -50.0);
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(skinnedWithMaterial(behind) :: plainWithMaterial(behind) :: plainWithMaterial(Vec3.zero()) :: Nil));
        Assert.assertEq(expected = (Some(1), Some(1)), (Map.get("3D の骨つきの物", skips), Map.get("3D の材質の物（頂点の色で描く）", skips)))

    /// GL の左下が原点の矩形（y = 20・高さ 40）を、高さ 200 の描き先の左上が原点にすると y は 200 − 20 − 40 = 140。
    @Test
    def testTopLeftFlipsGlOrigin(): Unit \ Assert =
        Assert.assertEq(expected = (10, 140, 30, 40), topLeftOf(200, { x = 10, y = 20, width = 30, height = 40 }))
}
