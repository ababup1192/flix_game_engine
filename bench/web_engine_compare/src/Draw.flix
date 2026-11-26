// Draw — Scenes の場面（右手系・線形の色）を engine の 3D の場面（左手系・画面の値の色）にして描く。
// 右手系から左手系へは Z を裏返す（形の頂点・行列・カメラ・光の向き）。
mod Draw {
    use fge::{AnimationClip3d, Camera3d, Color, Mat4, Mesh3d, Model3d, MultiMesh3d, Num, Pose3d, Ray3d, PostStack, Render, Scene3d, ShaderDoc, Skin3d, Texture3d, Vec2, Vec3}

    /// 場面を描く材料（形と材質と、同じ形と材質の物の組は読み込みの時に 1 回だけ作る）。path = 物の置き方。
    pub type alias Kit = { field = Scenes.Field, meshes = Vector[Mesh3d.Mesh3d], materials = Vector[Scene3d.Material3d], batches = List[Batch], chunks = List[Chunk], fixed = Option[List[Scene3d.Instance3d]], path = Path,
                              fox = Option[Fox], scenery = List[Scene3d.Instance3d], sceneryTextures = List[Texture3d.Texture3d] }

    /// K6 の狐（比べる相手の Fox.glb）。baked = Walk を 1 秒 bakeRate 刻みで姿勢にした物（群れが Walk だけの時に読み込みで 1 回作る）。
    pub type alias Fox = { model = Model3d.Model3d, skin = Skin3d.Skin3d, walkClip = AnimationClip3d.AnimationClip3d, runClip = AnimationClip3d.AnimationClip3d, baked = Vector[Pose3d.Pose3d] }

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

    /// 動かない glb（K4 の Sponza）を読み込みで 1 回置く。engine の glTF の読み手は X を裏返すので、Z の裏返しと合わせて Y の半回転（Sz × Sx）で置く。
    pub def withScenery(model: Model3d.Model3d, kit: Kit): Kit =
        { scenery = Model3d.partInstances(Mat4.scale(Vec3.v3(-1.0, 1.0, -1.0)), model), sceneryTextures = model#textures | kit }

    /// 狐の Walk を姿勢にする刻み（1 秒の数）。
    pub def bakeRate(): Float64 = 30.0

    /// 読んだ狐から骨と Walk・Run を取り出す（誤りの文は ASCII — font-bake が src の文字列の字を HUD の字のアトラスへ集める）。bake = Walk を刻みで姿勢にしておく（Babylon.js の baked animation と同じく、時刻を刻みに丸めて体どうしで姿勢を分け合う）。
    pub def foxOf(model: Model3d.Model3d, bake: Bool): Result[String, Fox] =
        let clip = name -> Map.get(name, model#clips) |> Option.toOk("Fox.glb: no clip ${name}");
        Option.toOk("Fox.glb: no skin", model#skin) |> Result.flatMap(skin -> clip("Walk") |> Result.flatMap(walk -> clip("Run") |> Result.map(running -> {
            let steps = Int32.max(1, Num.roundInt(AnimationClip3d.duration(walk) * bakeRate()));
            { model = model, skin = skin, walkClip = walk, runClip = running,
              baked = if (bake) Vector.range(0, steps) |> Vector.map(k -> Pose3d.compute(skin, AnimationClip3d.sample(skin, walk, Int32.toFloat64(k) / bakeRate(), true))) else Vector.empty() }
        })))

    /// K6: 時刻 t の体ごとの Run の重み（比べる相手の scene.update に当たる・混ぜない群れは空）。
    pub def crowdWeights(kit: Kit, t: Float64): Vector[Float64] = match kit#field#crowd {
        case Some(c) if c#blended => Vector.range(0, c#count) |> Vector.map(Scenes.runWeightAt(c, t))
        case _ => Vector.empty()
    }

    /// K6: 時刻 t の狐全部（体ごとに姿勢を付けて glb の部品を置く）。
    pub def crowdInstances(kit: Kit, weights: Vector[Float64], t: Float64): List[Scene3d.Instance3d] =
        match (kit#fox, kit#field#crowd) {
            case (Some(fox), Some(c)) =>
                List.range(0, c#count) |> List.flatMap(i -> {
                    let pose = poseOf(fox, c, weights, t, i);
                    Model3d.partInstances(foxWorld(c, i), fox#model) |> List.map(Scene3d.withPose(pose))
                })
            case _ => Nil
        }

    /// 体 i の時刻 t の姿勢。混ぜる群れは Walk と Run を毎コマ取り出して重みで混ぜ、混ぜない群れは刻みの姿勢から一番近い物を使う。
    def poseOf(fox: Fox, c: Scenes.Crowd, weights: Vector[Float64], t: Float64, i: Int32): Pose3d.Pose3d =
        let at = t + Vector.get(i, c#phase);
        if (c#blended) {
            let walk = AnimationClip3d.sample(fox#skin, fox#walkClip, at, true);
            let running = AnimationClip3d.sample(fox#skin, fox#runClip, at, true);
            Pose3d.compute(fox#skin, Pose3d.blend(walk, running, Vector.get(i, weights)))
        } else {
            let n = Vector.length(fox#baked);
            Vector.get(Int32.modulo(Num.roundInt(at * bakeRate()), n), fox#baked)
        }

    /// 体 i の根の行列（左手系）。engine の glTF の読み手は X を裏返して左手系にするので、右手系の 位置 × Y で yaw 回す × 倍率 を
    /// 左から Z の裏返し・右から X の裏返しで挟む（Sz × M × Sx。裏返しが 2 回なので三角形の表と裏は入れ替わらない）。
    def foxWorld(c: Scenes.Crowd, i: Int32): Mat4.Mat4 =
        let yaw = Vector.get(i, c#yaw);
        let s = c#scale;
        let (cs, sn) = (Num.cos(yaw) * s, Num.sin(yaw) * s);
        Mat4.ofColumns(Vector#{0.0 - cs, 0.0, 0.0 - sn, 0.0, 0.0, s, 0.0, 0.0, sn, 0.0, 0.0 - cs, 0.0,
                               Vector.get(i * 3, c#position), Vector.get(i * 3 + 1, c#position), 0.0 - Vector.get(i * 3 + 2, c#position), 1.0})
            |> Result.getWithDefault(Mat4.identity())

    /// K3 の作り直しの状態。field = 今の場面の写し・frame = 最後に作り直したコマ・looks = 組の番号 → その組を最後に作り直したコマの絵と材質
    /// （生きている絵は組の数まで。組が回ってくると前の絵は looks から落ちる）。
    pub type alias Churn = { field = Scenes.Field, frame = Int32, looks = Map[Int32, Look] }

    /// 作り直した組の絵と、組の中の物ごとの材質（materials の k 番目が組の k 番目の物）。
    pub type alias Look = { texture = Texture3d.Texture3d, materials = Vector[Scene3d.Material3d] }

    pub def churnOf(kit: Kit): Churn = { field = kit#field, frame = 0, looks = Map.empty() }

    /// 作り直した場面 field（コマ frame の後）と、そのコマの絵の画素 pixels から、組の絵と新しい材質を作って looks を差し替える。
    pub def respawn(frame: Int32, field: Scenes.Field, pixels: Vector[Int32], c: Churn): Churn =
        let size = Scenes.churnTextureSize();
        let batch = Scenes.churnBatchOf(field, frame);
        let first = batch * Scenes.churnPerFrame();
        match Texture3d.fromArgb(size, size, pixels) {
            case Err(_)  => { field = field, frame = frame | c }
            case Ok(tex) =>
                let materials = Vector.range(first, first + Scenes.churnPerFrame()) |> Vector.map(i -> {
                    let pbr = Vector.get(Vector.get(i, field#material), field#materials);
                    Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Linear) |> Scene3d.withMetallicRoughness(pbr#metalness, pbr#roughness)
                });
                { field = field, frame = frame, looks = Map.insert(batch, { texture = tex, materials = materials }, c#looks) }
        }

    /// 区画の一辺（m）。
    def chunkSize(): Float64 = 16.0

    /// 光の量の倍率（比べる相手の adapter の LIGHT_SCALE に当たる）。
    // WhyNot: 環境光に掛けない — three.js は掛けるが、engine の環境光は今でも影の側が three.js より明るい（frame 60 の絵で比べた）。
    def lightScale(): Float64 = Num.pi()

    pub def kitOf(path: Path, field: Scenes.Field): Result[String, Kit] =
        Scenes.shapesOf(field#shapes) |> Vector.toList |> List.map(meshOf) |> Result.sequence
            |> Result.map(meshes -> { field = field, meshes = List.toVector(meshes), materials = field#materials |> Vector.mapWithIndex(materialOf), chunks = Nil, fixed = None, fox = None, scenery = Nil, sceneryTextures = Nil,
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
    def instanceOf(kit: Kit, t: Float64, i: Int32): Scene3d.Instance3d = placed(kit, kit#field, t, i)

    /// 場面 f の物 i を時刻 t の置き方で、場面の材質のまま 1 つ置く。
    def placed(kit: Kit, f: Scenes.Field, t: Float64, i: Int32): Scene3d.Instance3d =
        Scene3d.meshInstance(Vector.get(Vector.get(i, f#geom), kit#meshes), worldOf(f, t, i))
            |> Scene3d.withMaterial(Vector.get(Vector.get(i, f#material), kit#materials))

    /// K3: 時刻 t の物全部。作り直した組の物は組の絵の材質に、場面の材質の色を tint で掛ける。
    def churnInstances(kit: Kit, c: Churn, t: Float64): List[Scene3d.Instance3d] =
        let f = c#field;
        let per = Scenes.churnPerFrame();
        List.range(0, f#count) |> List.map(i -> match Map.get(i / per, c#looks) {
            case Some(look) =>
                placed(kit, f, t, i) |> Scene3d.withMaterial(Vector.get(Int32.remainder(i, per), look#materials))
                                     |> Scene3d.withTint(screenColor(Vector.get(Vector.get(i, f#material), f#materials)#color))
            case None => placed(kit, f, t, i)
        })

    /// canvas の画素 (x, y)（左上が 0）の下にある一番近い物の番号。engine のレイ（Camera3d.screenPointToRay と Ray3d.hitMesh）で 1 つずつ当てる。
    pub def pick(kit: Kit, t: Float64, x: Float64, y: Float64): Option[Int32] =
        let f = kit#field;
        let cam = cameraOf(Scenes.cameraAt(f, t));
        let ray = Camera3d.screenPointToRay(cam, Vec2.v2(Scenes.width(), Scenes.height()), Vec2.v2(x, y));
        List.range(0, f#count)
            |> List.foldLeft((best, i) -> {
                let reach = best |> Option.map(snd) |> Option.getWithDefault(cam#far);
                Ray3d.hitMesh(ray, reach, Vector.get(Vector.get(i, f#geom), kit#meshes), worldOf(f, t, i))
                    |> Option.filter(hit -> hit#distance < reach)
                    |> Option.map(hit -> (i, hit#distance))
                    |> (found -> if (Option.isEmpty(found)) best else found)
            }, None)
            |> Option.map(fst)

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

    /// 時刻 t の場面（churn があれば K3 の今の場面の写しと組の絵で描く）。
    /// posed = 姿勢を付けた骨つきの物（K6 の狐）。
    pub def scene(kit: Kit, churn: Option[Churn], posed: List[Scene3d.Instance3d], t: Float64): Scene3d.Scene3dCmd =
        let f = kit#field;
        let perObject = () -> match churn {
            case Some(c) => churnInstances(kit, c, t)
            case None    => Option.getWithDefault(instances(kit, t), kit#fixed)
        };
        let (ar, ag, ab) = f#ambient#color;
        let k = f#ambient#intensity;
        let sun = { color = screenColor(f#sun#color), intensity = f#sun#intensity * lightScale() | Scene3d.directionalLight(flip(f#sun#direction)) };
        { instances = (if (kit#path == Path.PerObject) perObject() else Nil) ::: posed ::: kit#scenery,
          textures = (churn |> Option.map(c -> Map.valuesOf(c#looks) |> List.map(look -> look#texture)) |> Option.getWithDefault(Nil))
                     ::: (kit#fox |> Option.map(fox -> fox#model#textures) |> Option.getWithDefault(Nil)) ::: kit#sceneryTextures,
          multiMeshes = if (kit#path == Path.Batched) multiMeshes(kit, t) else Nil,
          groups = if (kit#path == Path.Chunks) visibleChunks(kit, t) else Nil,
          directionalLight = Some(sun),
          environment = { ambient = screenColor((ar * k, ag * k, ab * k)), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(screenColor(f#clearColor)) },
          resolution = Scene3d.Resolution.Native
          | Scene3d.scene(cameraOf(Scenes.cameraAt(f, t)), Vec2.v2(Scenes.width(), Scenes.height())) }
            |> Scene3d.withLightUnits(Scene3d.LightUnits.Physical)
            |> Scene3d.withUnitsPerMeter(1.0)

    pub def items(kit: Kit, churn: Option[Churn], posed: List[Scene3d.Instance3d], t: Float64): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene(kit, churn, posed, t)) :: Nil

    /// 比べる相手と同じ条件の後がけ（MSAA 4×・ACES）。
    // WhyNot: 線形で掛ける ACES にしない — engine に無い（ViewTransform に足すのは X2 の相談の後）。今ある AcesNarkowicz は画面の値に掛けるので、明るい所の色が比べる相手とずれる。
    pub def post(): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral)
            |> PostStack.withViewTransform(PostStack.ViewTransform.AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.0 }))
            |> PostStack.withMsaa(PostStack.Msaa.X4)
}
