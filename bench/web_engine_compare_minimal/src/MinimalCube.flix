// MinimalCube — 配る大きさを測るだけの最小の app: 光の当たる PBR の箱 1 つが回る（MSAA 4×・ACES）。
// 比べる相手の minimal の app（箱・太陽・環境光・ACES・MSAA）と同じ機能だけを使う。
mod MinimalCube {
    use fge::{App, Color, Mat4, Mesh3d, PostStack, Render, Scene3d, ShaderDoc, Vec2, Vec3}

    def size(): Vec2.Vec2 = Vec2.v2(1920.0, 1080.0)

    def v(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = Vec3.v3(x, y, z)

    /// 一辺 1 の箱（外から見て時計回りの 6 面）。
    def box(): Mesh3d.Mesh3d =
        let c = Color.rgb(1.0, 1.0, 1.0);
        let face = ps -> { points = ps, color = c };
        Mesh3d.fromPolygons(
            face(v(-0.5, 0.5, -0.5) :: v(-0.5, 0.5, 0.5) :: v(0.5, 0.5, 0.5) :: v(0.5, 0.5, -0.5) :: Nil)
                :: face(v(-0.5, -0.5, -0.5) :: v(0.5, -0.5, -0.5) :: v(0.5, -0.5, 0.5) :: v(-0.5, -0.5, 0.5) :: Nil)
                :: face(v(-0.5, -0.5, -0.5) :: v(-0.5, 0.5, -0.5) :: v(0.5, 0.5, -0.5) :: v(0.5, -0.5, -0.5) :: Nil)
                :: face(v(0.5, -0.5, 0.5) :: v(0.5, 0.5, 0.5) :: v(-0.5, 0.5, 0.5) :: v(-0.5, -0.5, 0.5) :: Nil)
                :: face(v(-0.5, -0.5, 0.5) :: v(-0.5, 0.5, 0.5) :: v(-0.5, 0.5, -0.5) :: v(-0.5, -0.5, -0.5) :: Nil)
                :: face(v(0.5, -0.5, -0.5) :: v(0.5, 0.5, -0.5) :: v(0.5, 0.5, 0.5) :: v(0.5, -0.5, 0.5) :: Nil)
                :: Nil)

    def material(): Scene3d.Material3d =
        let c = Color.rgb8(204, 85, 34);
        Scene3d.material({ name = "minimal_cube", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(1.0) }) })
            |> Scene3d.withMetallicRoughness(0.0, 0.4)

    /// 時刻 t（秒）の場面。
    pub def scene(mesh: Mesh3d.Mesh3d, t: Float64): Scene3d.Scene3dCmd =
        let camera = { eye = v(0.0, 1.2, -3.0), yaw = 0.0, pitch = 0.38, fovY = 0.873, near = 0.1, far = 100.0, lensShift = Vec2.zero() };
        let sun = { intensity = 3.0 | Scene3d.directionalLight(v(-2.0, -4.0, 3.0)) };
        { instances = (Scene3d.meshInstance(mesh, Mat4.rotateY(t)) |> Scene3d.withMaterial(material())) :: Nil,
          directionalLight = Some(sun),
          environment = { ambient = Color.rgb(0.5, 0.5, 0.5), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(Color.rgb(0.0, 0.0, 0.0)) },
          resolution = Scene3d.Resolution.Native
          | Scene3d.scene(camera, size()) }

    pub def app(): App.App[Float64, {}] =
        let mesh = box();
        App.make(0.0)
            |> App.addSystem((frame, t) -> t + frame#dt)
            |> App.withView((_ctx, t) -> checked_ecast(Render.scene3d(Vec2.zero(), scene(mesh, t)) :: Nil))
            |> App.withPostStack(_ -> checked_ecast(PostStack.preset(PostStack.Preset.Neutral)
                |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.0 }))
                |> PostStack.withMsaa(PostStack.Msaa.X4)))
}
