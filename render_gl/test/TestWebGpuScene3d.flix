// WebGPU の 3D の描き手の、GPU を呼ばない所（場面の値を R3dScene の欄の位置へ詰める・矩形の上下の向き・まだ描けない物の数え）を固定する。
// 欄の位置は Render3dWgsl.sceneDeclarations の並び（vec3 の後ろの 4 バイトに f32 か i32・光の配列は 400 バイト目から 16 バイト刻みの vec4）。
// WhyNot: mod TestWebGpuScene3d にしない — topLeftOf は Render3d.WebGpuRenderer の中の pub でない関数で、子のモジュールからしか呼べない。
mod Render3d.WebGpuRenderer.TestWebGpuScene3d {
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.ScenePlan.ScenePassSpec
    use Render3d.WebGpuRenderer.{clearOf, packPassValues, packSceneValues, sceneValueBytes, skipsOf, topLeftOf}

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

    /// 影は切り、奥行きの書き出しの欄は書かない: uSunShadowOn（76）・uShadowOn（220）・uDepthOut（248）が 0・uShadowSpot（232）が -1。
    @Test
    def testShadowAndDepthOutputAreOff(): Unit \ {Assert, IO} =
        let buf = packed();
        Assert.assertEq(expected = (0, 0, 0, -1), (buf.getInt(76), buf.getInt(220), buf.getInt(248), buf.getInt(232)))

    /// 奥行きの書き出しの pass は uDepthRange（224・228）に near と幅・uDepthOut（248）に 1。
    @Test
    def testDepthPassWritesRangeAndFlag(): Unit \ {Assert, IO} =
        let buf = packed();
        packPassValues(buf, ScenePassSpec.DepthOut({ near = 0.5, range = 12.0 }));
        Assert.assertEq(expected = (0.5f32, 12.0f32, 1), (buf.getFloat(224), buf.getFloat(228), buf.getInt(248)))

    /// 色の pass は、前の場面が奥行きの書き出しでも uDepthOut を 0 に戻し、幅を 1 にする（入れ物を場面をまたいで使い回す）。
    @Test
    def testColorPassClearsDepthFlag(): Unit \ {Assert, IO} =
        let buf = packed();
        packPassValues(buf, ScenePassSpec.DepthOut({ near = 0.5, range = 12.0 }));
        packPassValues(buf, ScenePassSpec.Color);
        Assert.assertEq(expected = (1.0f32, 0), (buf.getFloat(228), buf.getInt(248)))

    /// 奥行きの書き出しの幅が 0 でも 0 で割らない（GL の Render3d.putDepthRange と同じ下限）。
    @Test
    def testDepthPassRangeIsNeverZero(): Unit \ {Assert, IO} =
        let buf = packed();
        packPassValues(buf, ScenePassSpec.DepthOut({ near = 0.5, range = 0.0 }));
        Assert.assertEq(expected = RenderUtil.f32(0.000001), buf.getFloat(228))

    // ── 場面の地の色（clearOf）──

    def depthOut(): ScenePassSpec = ScenePassSpec.DepthOut({ near = 0.5, range = 12.0 })

    def sky(): Scene3d.Sky3d = Scene3d.gradientSky(Color.rgb(0.1, 0.2, 0.9), Color.rgb(0.8, 0.8, 0.9), Color.rgb(0.3, 0.3, 0.3))

    def withBackground(c: Color, s: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd = { environment = { background = Some(c) | s#environment } | s }

    def panorama(): Texture3d.Texture3d = match Texture3d.fromArgb(2, 2, Vector#{0, 0, 0, 0}) {
        case Ok(t)  => t
        case Err(e) => bug!(e)
    }

    /// 奥行きの書き出しで空を塗る場面は、background があっても一番奥の白で消す（GL は空の frag が白を塗る）。
    @Test
    def testDepthWithSkyClearsWhite(): Unit \ Assert =
        let s = { sky = Some(sky()) | withBackground(Color.rgb(0.25, 0.5, 0.75), scene()) };
        Assert.assertEq(expected = (1.0, 1.0, 1.0, 1.0), clearOf(depthOut(), s))

    /// 奥行きの書き出しで空の無い場面は background で消す（GL の beginScene と同じ）。
    @Test
    def testDepthWithoutSkyClearsBackground(): Unit \ Assert =
        Assert.assertEq(expected = (0.25, 0.5, 0.75, 1.0), clearOf(depthOut(), withBackground(Color.rgb(0.25, 0.5, 0.75), scene())))

    /// 色の pass で空のある場面は透明で消す（空は描かずに数える・background は空があれば使わない）。
    @Test
    def testColorWithSkyClearsTransparent(): Unit \ Assert =
        let s = { sky = Some(sky()) | withBackground(Color.rgb(0.25, 0.5, 0.75), scene()) };
        Assert.assertEq(expected = (0.0, 0.0, 0.0, 0.0), clearOf(ScenePassSpec.Color, s))

    /// sky が無くても景色を背景に描く場面（Scene3d.drawnSkyOf が Some を返す）は、奥行きの書き出しで白で消す。
    @Test
    def testDepthWithBackgroundPanoramaClearsWhite(): Unit \ Assert =
        let e = Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentAsBackground(true);
        let s = { environmentMap = Some(e) | withBackground(Color.rgb(0.25, 0.5, 0.75), scene()) };
        Assert.assertEq(expected = (1.0, 1.0, 1.0, 1.0), clearOf(depthOut(), s))

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

    def cutoutWood(): Scene3d.Material3d = Scene3d.withCutout(true, wood())

    /// Output.Depth の場面は描くので場面としては数えず、骨つきの物・描けない版の材質の物（形だけで書く）・ビルボードだけを数える。
    /// cutout の材質の物は材質の道で抜いて書くので数えない。
    @Test
    def testDepthSceneCountsOnlyWhatItCannotDraw(): Unit \ {Assert, IO} =
        let cutout = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(cutoutWood());
        let scene = { output = Scene3d.Output.Depth({ near = 0.1, range = 10.0 })
                      | Render3d.FakeGl.sceneOf(skinnedWithMaterial(Vec3.zero()) :: plainWithMaterial(Vec3.zero()) :: cutout :: Nil) };
        Assert.assertEq(expected = Map#{"3D の骨つきの物" => 1, "3D の奥行きの書き出しの材質の物（描けない版を形で書く）" => 0, "3D のビルボード" => 0},
                        skipsOfScene(scene))

    /// 材質つきの骨つきの物は骨つきの物として 1 回だけ数え、材質の物には数えない。
    @Test
    def testSkinnedWithMaterialIsCountedOnce(): Unit \ {Assert, IO} =
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(skinnedWithMaterial(Vec3.zero()) :: Nil));
        Assert.assertEq(expected = (Some(1), Some(0)), (Map.get("3D の骨つきの物", skips), Map.get("3D の半透明の材質の物（頂点の色で不透明に描く）", skips)))

    /// 描ける版の不透明の材質の物（絵つき・cutout）は、まだ描けない物に数えない。
    @Test
    def testDrawableMaterialIsNotCounted(): Unit \ {Assert, IO} =
        let cutout = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(cutoutWood());
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(plainWithMaterial(Vec3.zero()) :: cutout :: Nil));
        Assert.assertEq(expected = 0, Map.foldLeft((acc, n) -> acc + n, 0, skips))

    def glassWood(): Scene3d.Material3d = Scene3d.withAlphaBlend(true, wood())

    /// 視錐台の外（目の後ろ）の材質の物は数えない。骨つきの物は計画が間引かない（Scene3d.isOutsideFrustum がいつも偽・GL も描く）ので目の後ろでも数える。
    @Test
    def testCulledThingsAreNotCounted(): Unit \ {Assert, IO} =
        let behind = Vec3.v3(0.0, 0.0, -50.0);
        let glass = (at: Vec3.Vec3) -> Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.translate(at)) |> Scene3d.withMaterial(glassWood());
        let skips = skipsOfScene(Render3d.FakeGl.sceneOf(skinnedWithMaterial(behind) :: glass(behind) :: glass(Vec3.zero()) :: Nil));
        Assert.assertEq(expected = (Some(1), Some(1)), (Map.get("3D の骨つきの物", skips), Map.get("3D の半透明の材質の物（頂点の色で不透明に描く）", skips)))

    /// GL の左下が原点の矩形（y = 20・高さ 40）を、高さ 200 の描き先の左上が原点にすると y は 200 − 20 − 40 = 140。
    @Test
    def testTopLeftFlipsGlOrigin(): Unit \ Assert =
        Assert.assertEq(expected = (10, 140, 30, 40), topLeftOf(200, { x = 10, y = 20, width = 30, height = 40 }))
}
