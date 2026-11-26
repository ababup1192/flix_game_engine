// Draw — Scenes の場面（右手系・線形の色）を engine の 3D の場面（左手系・画面の値の色）にして描く。
// 右手系から左手系へは Z を裏返す（形の頂点・行列・カメラ・光の向き）。裏返すと面の巻き方も逆になるので、番号の並びはそのまま渡す。
mod Draw {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, PostStack, Render, Scene3d, ShaderDoc, Texture3d, Vec2, Vec3}

    /// 場面を描く材料（形と材質は読み込みの時に 1 回だけ作る）。
    pub type alias Kit = { field = Scenes.Field, meshes = Vector[Mesh3d.Mesh3d], materials = Vector[Scene3d.Material3d] }

    /// 光の量の倍率（比べる相手の adapter の LIGHT_SCALE に当たる）。
    // WhyNot: ここで three.js と絵を合わせて決めない — 合わせるのは比べる相手の頁で frame 60 の絵を並べる段（S3）。それまでは 1 のまま。
    def lightScale(): Float64 = 1.0

    pub def kitOf(field: Scenes.Field): Result[String, Kit] =
        Geometry.fieldShapes() |> Vector.toList |> List.map(meshOf) |> Result.sequence
            |> Result.map(meshes -> { field = field, meshes = List.toVector(meshes), materials = field#materials |> Vector.mapWithIndex(materialOf) })

    /// 右手系の形を左手系の Mesh3d へ（Z を裏返す）。
    pub def meshOf(shape: Geometry.Shape): Result[String, Mesh3d.Mesh3d] =
        let flipZ = (v: Vector[Float64]) -> v |> Vector.mapWithIndex((i, x) -> if (Int32.remainder(i, 3) == 2) 0.0 - x else x);
        Mesh3d.fromArrays({ positions = flipZ(shape#positions), normals = flipZ(shape#normals),
                            colors = Vector.repeat(Vector.length(shape#positions), 1.0), indices = shape#indices, skin = None })
            |> Result.flatMap(Mesh3d.withUvs(shape#uvs))

    def screenColor(c: Scenes.V3): Color =
        let (r, g, b) = c;
        Color.rgb(Texture3d.linearToSrgb(r), Texture3d.linearToSrgb(g), Texture3d.linearToSrgb(b))

    def materialOf(i: Int32, pbr: Scenes.Pbr): Scene3d.Material3d =
        let c = screenColor(pbr#color);
        Scene3d.material({ name = "wec_pbr_${i}", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(pbr#opacity) }) })
            |> Scene3d.withMetallicRoughness(pbr#metalness, pbr#roughness)
            |> Scene3d.withAlphaBlend(pbr#opacity < 1.0)

    /// 右手系の列優先の行列を左手系へ（S × m × S・S は Z の裏返し）。
    pub def mirroredColumns(m: Vector[Float64]): Vector[Float64] =
        m |> Vector.mapWithIndex((i, x) -> {
            let row = Int32.remainder(i, 4);
            let col = i / 4;
            if ((row == 2) != (col == 2)) 0.0 - x else x
        })

    def flip(v: Scenes.V3): Vec3.Vec3 = { let (x, y, z) = v; Vec3.v3(x, y, 0.0 - z) }

    /// 位置から注視点を見るカメラ。
    def cameraOf(c: Scenes.Camera): Camera3d.Camera3d =
        let eye = flip(c#position);
        let d = Vec3.normalized(Vec3.sub(flip(c#target), eye));
        { eye = eye, yaw = Num.atan2(d#x, d#z), pitch = Num.asin(0.0 - d#y), fovY = c#fovY * Num.pi() / 180.0,
          near = c#near, far = c#far, lensShift = Vec2.zero() }

    /// 時刻 t の物全部（物ごとに 1 つずつ置く）。
    pub def instances(kit: Kit, t: Float64): List[Scene3d.Instance3d] =
        let f = kit#field;
        List.range(0, f#count) |> List.map(i ->
            Scene3d.meshInstance(Vector.get(Vector.get(i, f#geom), kit#meshes), Mat4.ofColumns(mirroredColumns(Scenes.worldColumns(f, t, i))) |> Result.getWithDefault(Mat4.identity()))
                |> Scene3d.withMaterial(Vector.get(Vector.get(i, f#material), kit#materials)))

    /// 時刻 t の場面。
    pub def scene(kit: Kit, t: Float64): Scene3d.Scene3dCmd =
        let f = kit#field;
        let (ar, ag, ab) = f#ambient#color;
        let k = f#ambient#intensity;
        let sun = { color = screenColor(f#sun#color), intensity = f#sun#intensity * lightScale() | Scene3d.directionalLight(flip(f#sun#direction)) };
        { instances = instances(kit, t),
          directionalLight = Some(sun),
          environment = { ambient = screenColor((ar * k, ag * k, ab * k)), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(screenColor(f#clearColor)) },
          resolution = Scene3d.Resolution.Native
          | Scene3d.scene(cameraOf(f#camera), Vec2.v2(Scenes.width(), Scenes.height())) }
            |> Scene3d.withLightUnits(Scene3d.LightUnits.Physical)
            |> Scene3d.withUnitsPerMeter(1.0)

    pub def items(kit: Kit, t: Float64): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene(kit, t)) :: Nil

    /// 比べる相手と同じ条件の後がけ（MSAA 4×・ACES）。
    // WhyNot: 線形で掛ける ACES にしない — engine に無い（ViewTransform に足すのは X2 の相談の後）。今ある AcesNarkowicz は画面の値に掛けるので、明るい所の色が比べる相手とずれる。
    pub def post(): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral)
            |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.0 }))
            |> PostStack.withMsaa(PostStack.Msaa.X4)
}
