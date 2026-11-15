// WebGPU の 3D の描き手の、GPU を呼ばない所（場面の値を R3dScene の欄の位置へ詰める・矩形の上下の向き）を固定する。
// 欄の位置は Render3dWgsl.sceneDeclarations の並び（vec3 の後ろの 4 バイトに f32 か i32・光の配列は 400 バイト目から 16 バイト刻みの vec4）。
// WhyNot: mod TestWebGpuScene3d にしない — topLeftOf は Render3d.WebGpuRenderer の中の pub でない関数で、子のモジュールからしか呼べない。
mod Render3d.WebGpuRenderer.TestWebGpuScene3d {
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.WebGpuRenderer.{packSceneValues, sceneValueBytes, topLeftOf}

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

    /// GL の左下が原点の矩形（y = 20・高さ 40）を、高さ 200 の描き先の左上が原点にすると y は 200 − 20 − 40 = 140。
    @Test
    def testTopLeftFlipsGlOrigin(): Unit \ Assert =
        Assert.assertEq(expected = (10, 140, 30, 40), topLeftOf(200, { x = 10, y = 20, width = 30, height = 40 }))
}
