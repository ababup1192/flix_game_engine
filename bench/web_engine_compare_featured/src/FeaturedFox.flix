// FeaturedFox — 配る大きさを測るだけの app: glb の骨つきの狐が 1 つ目のアニメを回し、太陽の影を床に落とし、bloom と ACES と MSAA 4× を掛ける。
// 比べる相手の realistic の app（glTF・アニメ・影・bloom・ACES）と同じ機能だけを使う。
// assets/Fox.glb は git に入れない（Makefile の featured-assets が比べる相手の素材から写す）。
mod FeaturedFox {
    use fge::{AnimationClip3d, App, Color, Mat4, Mesh3d, Model3d, Pose3d, PostStack, Render, Scene3d, ShaderDoc, Vec2, Vec3}

    def size(): Vec2.Vec2 = Vec2.v2(1920.0, 1080.0)

    def v(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = Vec3.v3(x, y, z)

    /// 一辺 20 m の床（上を向く 1 枚）。
    def ground(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = v(-10.0, 0.0, -10.0) :: v(-10.0, 0.0, 10.0) :: v(10.0, 0.0, 10.0) :: v(10.0, 0.0, -10.0) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil)

    def grey(): Scene3d.Material3d =
        Scene3d.material({ name = "featured_ground", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(Color.rgb(0.5, 0.5, 0.5)), alpha = ShaderDoc.Field.Const(1.0) }) })

    /// 時刻 t（秒）の場面。
    pub def scene(fox: Model3d.Model3d, t: Float64): Scene3d.Scene3dCmd =
        let camera = { eye = v(0.0, 1.2, -3.0), yaw = 0.0, pitch = 0.23, fovY = 0.873, near = 0.1, far = 100.0, lensShift = Vec2.zero() };
        let sun = { intensity = 3.0, shadow = Some(Scene3d.directionalShadow()) | Scene3d.directionalLight(v(-2.0, -4.0, 3.0)) };
        let pose = Option.flatMap(skin -> fox#clips |> Map.valuesOf |> List.head |> Option.map(clip -> Pose3d.compute(skin, AnimationClip3d.sample(skin, clip, t, true))), fox#skin);
        let place = Mat4.scale(v(0.01, 0.01, 0.01));
        let foxParts = Model3d.partInstances(place, fox) |> List.map(i -> match pose {
            case Some(p) => Scene3d.withPose(p, i)
            case None    => i
        });
        { instances = (Scene3d.meshInstance(ground(), Mat4.identity()) |> Scene3d.withMaterial(grey())) :: foxParts,
          directionalLight = Some(sun),
          environment = { ambient = Color.rgb(0.5, 0.5, 0.5), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(Color.rgb(0.0, 0.0, 0.0)) },
          resolution = Scene3d.Resolution.Native
          | Scene3d.scene(camera, size()) }

    pub def app(fox: Model3d.Model3d): App.App[Float64, {}] =
        App.make(0.0)
            |> App.addSystem((frame, t) -> t + frame#dt)
            |> App.withView((_ctx, t) -> checked_ecast(Render.scene3d(Vec2.zero(), scene(fox, t)) :: Nil))
            |> App.withPostStack(_ -> checked_ecast(PostStack.preset(PostStack.Preset.Neutral)
                |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.0 }))
                |> PostStack.withBloom(Some({ threshold = 0.85, smoothness = 0.5, size = 0.04, strength = 0.6 }))
                |> PostStack.withMsaa(PostStack.Msaa.X4)))
}
