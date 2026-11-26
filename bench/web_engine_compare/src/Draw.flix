// Draw — Scenes の場面（右手系・線形の色）を engine の 3D の場面（左手系・画面の値の色）にして描く。
// 右手系から左手系へは Z を裏返す（形の頂点・行列・カメラ・光の向き）。
mod Draw {
    use fge::{Camera3d, Color, Mat4, Mesh3d, MultiMesh3d, Num, PostStack, Render, Scene3d, ShaderDoc, Texture3d, Vec2, Vec3}

    /// 場面を描く材料（形と材質と、同じ形と材質の物の組は読み込みの時に 1 回だけ作る）。path = 物の置き方。
    pub type alias Kit = { field = Scenes.Field, meshes = Vector[Mesh3d.Mesh3d], materials = Vector[Scene3d.Material3d], batches = List[Batch], chunks = List[Chunk], fixed = Option[List[Scene3d.Instance3d]], path = Path }

    /// 同じ形と材質の物の番号の組。
    pub type alias Batch = { geom = Int32, material = Int32, members = Vector[Int32] }

    /// 動かない物を区画ごとにまとめた Scene3d.staticGroup（center と radius は区画を囲む XZ の円）。
    pub type alias Chunk = { centerX = Float64, centerZ = Float64, radius = Float64, group = Scene3d.StaticGroup }

    /// fixed = 動かない場面の物の列（読み込みの時に 1 回作って毎コマ同じ値を渡す）。
    /// 物の置き方。PerObject = 入門の書き方（物ごとに Scene3d.meshInstance）・Batched = 形と材質の組ごとに MultiMesh3d を毎コマ組む・
    /// Chunks = 動かない物を区画ごとの staticGroup に読み込みの時に 1 回まとめ、カメラの向きから見える区画だけを渡す。
    pub enum Path with Eq, ToString {
        case PerObject
        case Batched
        case Chunks
    }

    /// 区画の一辺（m）。
    def chunkSize(): Float64 = 16.0

    /// 光の量の倍率（比べる相手の adapter の LIGHT_SCALE に当たる）。
    // WhyNot: 環境光に掛けない — three.js は掛けるが、engine の環境光は今でも影の側が three.js より明るい（frame 60 の絵で比べた）。
    def lightScale(): Float64 = Num.pi()

    pub def kitOf(path: Path, field: Scenes.Field): Result[String, Kit] =
        Geometry.fieldShapes() |> Vector.toList |> List.map(meshOf) |> Result.sequence
            |> Result.map(meshes -> { field = field, meshes = List.toVector(meshes), materials = field#materials |> Vector.mapWithIndex(materialOf), chunks = Nil, fixed = None,
                                      batches = batchesOf(field), path = path })
            |> Result.map(kit -> if (path == Path.Chunks) { chunks = chunksOf(kit) | kit } else kit)
            |> Result.map(kit -> if (path == Path.PerObject and not field#animated) { fixed = Some(instances(kit, 0.0)) | kit } else kit)

    /// 物を XZ の区画に分け、区画ごとに t = 0 の置き方で staticGroup を作る。
    def chunksOf(kit: Kit): List[Chunk] =
        let f = kit#field;
        let cellOf = i -> (Num.floorInt(Vector.get(i * 3, f#position) / chunkSize()), Num.floorInt(Vector.get(i * 3 + 2, f#position) / chunkSize()));
        List.range(0, f#count)
            |> List.foldRight((i, acc) -> Map.insertWith(List.append, cellOf(i), i :: Nil, acc), Map.empty())
            |> Map.toList
            |> List.map(entry -> {
                let ((cx, cz), members) = entry;
                let items = members |> List.map(i -> ("o${i}", instanceOf(kit, 0.0, i)));
                { centerX = (Int32.toFloat64(cx) + 0.5) * chunkSize(), centerZ = (Int32.toFloat64(cz) + 0.5) * chunkSize(),
                  radius = chunkSize() * 0.75, group = Scene3d.staticGroup("wec_chunk_${cx}_${cz}", items) }
            })

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
        List.range(0, kit#field#count) |> List.map(instanceOf(kit, t))

    /// 物 i を時刻 t の置き方で 1 つ置く。
    def instanceOf(kit: Kit, t: Float64, i: Int32): Scene3d.Instance3d =
        let f = kit#field;
        Scene3d.meshInstance(Vector.get(Vector.get(i, f#geom), kit#meshes), worldOf(f, t, i))
            |> Scene3d.withMaterial(Vector.get(Vector.get(i, f#material), kit#materials))

    /// 時刻 t のカメラから見える区画（XZ の上で、区画を囲む円が横の画角の中か、カメラが円の中にある）。
    // WhyNot: engine の視錐台の判定へ渡さない — staticGroup は中を間引かないので、出す・外すは区画を持つゲームの側が決める（docs/scene3d.md の staticGroup）。
    pub def visibleChunks(kit: Kit, t: Float64): List[Scene3d.StaticGroup] =
        let cam = Scenes.cameraAt(kit#field, t);
        let (ex, _, ez) = cam#position;
        let (tx, _, tz) = cam#target;
        let (dx, dz) = (tx - ex, tz - ez);
        let dl = Num.sqrt(dx * dx + dz * dz);
        let halfY = cam#fovY * Num.pi() / 360.0;
        let halfX = Num.atan2(Num.sin(halfY) / Num.cos(halfY) * Scenes.width() / Scenes.height(), 1.0);
        kit#chunks |> List.filterMap(r -> {
            let (vx, vz) = (r#centerX - ex, r#centerZ - ez);
            let dist = Num.sqrt(vx * vx + vz * vz);
            let inside = dist <= r#radius;
            let near = dist - r#radius < cam#far;
            let cosAngle = (vx * dx + vz * dz) / (dist * dl);
            let angle = Num.atan2(Num.sqrt(Float64.max(0.0, 1.0 - cosAngle * cosAngle)), cosAngle);
            let widen = Num.asin(Float64.min(1.0, r#radius / Float64.max(dist, 0.0001)));
            if (inside or (near and angle <= halfX + widen)) Some(r#group) else None
        })

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
        { instances = if (kit#path == Path.PerObject) Option.getWithDefault(instances(kit, t), kit#fixed) else Nil,
          multiMeshes = if (kit#path == Path.Batched) multiMeshes(kit, t) else Nil,
          groups = if (kit#path == Path.Chunks) visibleChunks(kit, t) else Nil,
          directionalLight = Some(sun),
          environment = { ambient = screenColor((ar * k, ag * k, ab * k)), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(screenColor(f#clearColor)) },
          resolution = Scene3d.Resolution.Native
          | Scene3d.scene(cameraOf(Scenes.cameraAt(f, t)), Vec2.v2(Scenes.width(), Scenes.height())) }
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
