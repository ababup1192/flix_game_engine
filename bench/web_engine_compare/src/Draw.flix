// Draw — Scenes の場面（右手系・線形の色）を engine の 3D の場面（左手系・画面の値の色）にして描く。
// 右手系から左手系へは Z を裏返す（形の頂点・行列・カメラ・光の向き）。
mod Draw {
    use fge::{Camera3d, Color, Mat4, Mesh3d, MultiMesh3d, Num, PostStack, Render, Scene3d, ShaderDoc, Texture3d, Vec2, Vec3}

    /// 場面を描く材料（形と材質と、同じ形と材質の物の組は読み込みの時に 1 回だけ作る）。path = 物の置き方。
    pub type alias Kit = { field = Scenes.Field, meshes = Vector[Mesh3d.Mesh3d], materials = Vector[Scene3d.Material3d], batches = List[Batch], path = Path }

    /// 同じ形と材質の物の番号の組。
    pub type alias Batch = { geom = Int32, material = Int32, members = Vector[Int32] }

    /// 物の置き方。PerObject = 入門の書き方（物ごとに Scene3d.meshInstance）・Batched = 形と材質の組ごとに MultiMesh3d を毎コマ組む。
    pub enum Path with Eq, ToString {
        case PerObject
        case Batched
    }

    /// 光の量の倍率（比べる相手の adapter の LIGHT_SCALE に当たる）。
    // WhyNot: 環境光に掛けない — three.js は掛けるが、engine の環境光は今でも影の側が three.js より明るい（frame 60 の絵で比べた）。
    def lightScale(): Float64 = Num.pi()

    pub def kitOf(path: Path, field: Scenes.Field): Result[String, Kit] =
        Geometry.fieldShapes() |> Vector.toList |> List.map(meshOf) |> Result.sequence
            |> Result.map(meshes -> { field = field, meshes = List.toVector(meshes), materials = field#materials |> Vector.mapWithIndex(materialOf),
                                      batches = batchesOf(field), path = path })

    /// 物を形と材質の組に分ける（組の中は物の番号の順）。
    def batchesOf(field: Scenes.Field): List[Batch] =
        List.range(0, field#count)
            |> List.foldRight((i, acc) -> Map.insertWith(List.append, (Vector.get(i, field#geom), Vector.get(i, field#material)), i :: Nil, acc), Map.empty())
            |> Map.toList
            |> List.map(entry -> { let ((g, m), members) = entry; { geom = g, material = m, members = List.toVector(members) } })

    /// 三角形ごとに 2 番目と 3 番目の頂点を入れ替える。
    // WhyNot: Z を裏返しただけで番号の並びをそのまま渡さない — 比べる相手の頁で撮ると裏の面が描かれた（engine の表の向きの約束は、裏返した後の形でも反時計回りの並びを裏と読む）。
    def swapWinding(indices: Vector[Int32]): Vector[Int32] =
        indices |> Vector.mapWithIndex((i, _) -> {
            let corner = Int32.remainder(i, 3);
            let source = if (corner == 1) i + 1 else if (corner == 2) i - 1 else i;
            Vector.get(source, indices)
        })

    /// 右手系の形を左手系の Mesh3d へ（Z を裏返す）。
    pub def meshOf(shape: Geometry.Shape): Result[String, Mesh3d.Mesh3d] =
        let flipZ = (v: Vector[Float64]) -> v |> Vector.mapWithIndex((i, x) -> if (Int32.remainder(i, 3) == 2) 0.0 - x else x);
        Mesh3d.fromArrays({ positions = flipZ(shape#positions), normals = flipZ(shape#normals),
                            colors = Vector.repeat(Vector.length(shape#positions), 1.0), indices = swapWinding(shape#indices), skin = None })
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
            Scene3d.meshInstance(Vector.get(Vector.get(i, f#geom), kit#meshes), worldOf(f, t, i))
                |> Scene3d.withMaterial(Vector.get(Vector.get(i, f#material), kit#materials)))

    /// 物 i の時刻 t の world の行列（左手系）。
    def worldOf(f: Scenes.Field, t: Float64, i: Int32): Mat4.Mat4 =
        Mat4.ofColumns(Scenes.mirroredWorldColumns(f, t, i)) |> Result.getWithDefault(Mat4.identity())

    /// 時刻 t の、形と材質の組ごとの MultiMesh3d。
    pub def multiMeshes(kit: Kit, t: Float64): List[MultiMesh3d.MultiMesh3d] =
        kit#batches |> List.map(b ->
            MultiMesh3d.build(Vector.get(b#geom, kit#meshes), Vector.length(b#members), j -> worldOf(kit#field, t, Vector.get(j, b#members)))
                |> MultiMesh3d.withMaterial(Vector.get(b#material, kit#materials)))

    /// 時刻 t の場面。
    pub def scene(kit: Kit, t: Float64): Scene3d.Scene3dCmd =
        let f = kit#field;
        let (ar, ag, ab) = f#ambient#color;
        let k = f#ambient#intensity;
        let sun = { color = screenColor(f#sun#color), intensity = f#sun#intensity * lightScale() | Scene3d.directionalLight(flip(f#sun#direction)) };
        { instances = if (kit#path == Path.PerObject) instances(kit, t) else Nil,
          multiMeshes = if (kit#path == Path.Batched) multiMeshes(kit, t) else Nil,
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
