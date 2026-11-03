// Room — 固定の部屋 1 つ（床と 4 方の壁と天井・家具 12・松明 4）を 3D の場面にする。
// 静止画（Still）と実機の窓（Main）が同じこれを描くので、CPU と GL の絵と重さを同じ場面で比べられる。
// 座標は engine の Scene3d の約束（左手系・X = 東・Y = 上・Z = 北）。家具の OBJ は Blender の m で、1 m = world の 16。
mod Room {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Render, Scene3d, Transform3d, Vec2, Vec3}

    /// 描き物の大きさ（design px）。
    pub def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    /// Blender の 1 m が world の何単位か（fps3d_lab と同じ）。
    def meter(): Float64 = 16.0

    // 部屋の広さ（m）。
    def roomW(): Float64 = 8.0
    def roomD(): Float64 = 6.0
    def roomH(): Float64 = 3.0

    def pi(): Float64 = 3.141592653589793

    // ── 家具 ──

    /// 家具 1 つ。x・z = 床の点（m）・turn = 向き（度。0 で正面が北・増えると東へ回る）・scale = 大きさの掛け目。
    type alias Prop = { model = String, x = Float64, z = Float64, turn = Float64, scale = Float64 }

    def prop(model: String, x: Float64, z: Float64, turn: Float64): Prop =
        { model = model, x = x, z = z, turn = turn, scale = 1.0 }

    def props(): List[Prop] =
        { scale = 1.6 | prop("rug", 4.0, 3.2, 0.0) } ::
        prop("table", 4.0, 3.2, 0.0) ::
        prop("bench", 4.0, 2.65, 0.0) ::
        prop("bench", 4.0, 3.75, 180.0) ::
        prop("bookshelf", 1.6, 5.72, 180.0) ::
        prop("bookshelf", 2.25, 5.72, 180.0) ::
        prop("desk", 7.6, 4.2, 270.0) ::
        prop("chair", 7.0, 4.2, 90.0) ::
        prop("chest", 5.3, 5.65, 180.0) ::
        prop("barrel", 7.55, 5.6, 0.0) ::
        { scale = 0.9 | prop("barrel", 6.95, 5.65, 0.0) } ::
        prop("barrel", 7.6, 4.95, 0.0) ::
        Nil

    /// 読む OBJ の名前（props の model の重なりを除いた物）。
    def modelNames(): List[String] = props() |> List.map(p -> p#model) |> List.distinct

    /// assets/models/<名前>.obj と .mtl を全部読む。読めない・壊れた物があれば Err（ファイルの名前つき）。
    pub def loadMeshes(): Result[String, Map[String, Mesh3d.Mesh3d]] \ Fs.FileRead =
        modelNames() |> List.foldLeft((acc, name) -> Result.flatMap(found ->
            Result.map(mesh -> Map.insert(name, mesh, found), loadMesh(name)), acc), Ok(Map.empty()))

    def loadMesh(name: String): Result[String, Mesh3d.Mesh3d] \ Fs.FileRead =
        let base = "assets/models/${name}";
        forM (
            objText <- readText("${base}.obj");
            mtlText <- readText("${base}.mtl");
            mesh <- Mesh3d.fromObj(objText, mtlText) |> Result.mapErr(why -> "${base}.obj: ${why}")
        ) yield mesh

    def readText(path: String): Result[String, String] \ Fs.FileRead =
        Fs.FileRead.read(path) |> Result.mapErr(e -> "${path} を読めない（${e}）")

    def propInstance(meshes: Map[String, Mesh3d.Mesh3d], p: Prop): Option[Scene3d.Instance3d] =
        Map.get(p#model, meshes) |> Option.map(mesh -> {
            let s = meter() * p#scale;
            let place = { yaw = p#turn * pi() / 180.0, scale = Vec3.v3(s, s, s)
                          | Transform3d.of(Vec3.v3(p#x * meter(), 0.0, p#z * meter())) };
            Scene3d.meshInstance(mesh, Transform3d.toMat4(place)) |> Scene3d.withName(p#model)
        })

    // ── 部屋の殻（床・壁・天井）──

    def rgb(r: Float64, g: Float64, b: Float64): Color = Color.rgb(r, g, b)

    def quad(a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3, d: Vec3.Vec3, color: Color): Mesh3d.Polygon =
        { points = a :: b :: c :: d :: Nil, color = color }

    /// 床（1 m の石畳の市松）。上を向く面。
    def floorTiles(): List[Mesh3d.Polygon] =
        let m = meter();
        List.range(0, 8) |> List.flatMap(i -> List.range(0, 6) |> List.map(j -> {
            let x0 = Int32.toFloat64(i) * m;
            let z0 = Int32.toFloat64(j) * m;
            let color = if (Int32.modulo(i + j, 2) == 0) rgb(0.36, 0.33, 0.30) else rgb(0.30, 0.27, 0.25);
            quad(Vec3.v3(x0, 0.0, z0), Vec3.v3(x0, 0.0, z0 + m), Vec3.v3(x0 + m, 0.0, z0 + m), Vec3.v3(x0 + m, 0.0, z0), color)
        }))

    /// 天井（内を向く面 1 枚）。
    def ceiling(): Mesh3d.Polygon =
        let (w, d, h) = (roomW() * meter(), roomD() * meter(), roomH() * meter());
        quad(Vec3.v3(0.0, h, 0.0), Vec3.v3(w, h, 0.0), Vec3.v3(w, h, d), Vec3.v3(0.0, h, d), rgb(0.17, 0.12, 0.09))

    /// 壁 1 面の石積み（高さ 0.5 m の段・段ごとに半分ずらした 1 m の石）。
    /// origin = 内から見て左下の角・along = 右へ進む向き（長さ 1）・length = 幅（m）。
    /// 内から見て時計回り（左下 → 左上 → 右上 → 右下）に頂点を並べるので、面は部屋の内を向く。
    def wall(origin: Vec3.Vec3, along: Vec3.Vec3, length: Float64): List[Mesh3d.Polygon] =
        let m = meter();
        let rowH = m * 0.5;
        let rows = Float64.round(roomH() / 0.5) |> Float64.tryToInt32 |> Option.getWithDefault(6);
        List.range(0, rows) |> List.flatMap(row -> {
            let y0 = Int32.toFloat64(row) * rowH;
            let shift = if (Int32.modulo(row, 2) == 0) 0.0 else 0.5;
            let cuts = List.range(0, Float64.ceil(length + 1.0) |> Float64.tryToInt32 |> Option.getWithDefault(0))
                |> List.map(k -> Int32.toFloat64(k) - shift)
                |> List.filter(s -> s < length);
            cuts |> List.mapWithIndex((k, s0) -> {
                let a = Float64.max(0.0, s0);
                let b = Float64.min(length, s0 + 1.0);
                let p = (s, y) -> Vec3.add(Vec3.add(origin, Vec3.mul(along, s * m)), Vec3.v3(0.0, y, 0.0));
                let color = if (Int32.modulo(k + row, 3) == 0) rgb(0.40, 0.36, 0.33)
                            else if (Int32.modulo(k + row, 3) == 1) rgb(0.36, 0.32, 0.29)
                            else rgb(0.33, 0.30, 0.28);
                quad(p(a, y0), p(a, y0 + rowH), p(b, y0 + rowH), p(b, y0), color)
            }) |> List.filter(poly -> List.length(poly#points) == 4)
        })

    def walls(): List[Mesh3d.Polygon] =
        let (w, d) = (roomW() * meter(), roomD() * meter());
        List.flatten(
            wall(Vec3.v3(0.0, 0.0, d), Vec3.v3(1.0, 0.0, 0.0), roomW()) ::        // 北（内から見て西 → 東）
            wall(Vec3.v3(w, 0.0, 0.0), Vec3.v3(-1.0, 0.0, 0.0), roomW()) ::       // 南（東 → 西）
            wall(Vec3.v3(0.0, 0.0, 0.0), Vec3.v3(0.0, 0.0, 1.0), roomD()) ::      // 西（南 → 北）
            wall(Vec3.v3(w, 0.0, d), Vec3.v3(0.0, 0.0, -1.0), roomD()) :: Nil)    // 東（北 → 南）

    /// 部屋の殻を 1 つの形に（床・壁・天井は動かないので 1 つにまとめ、GPU へは 1 回だけ上がる）。
    // WhyNot: 毎コマ作り直さない — 中身の鍵（contentHash）を毎コマ計算することになる。
    def shellMesh(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons(List.append(floorTiles(), ceiling() :: walls()))

    // ── 松明 ──

    /// 松明 1 本。at = 炎の真ん中（m）・facing = 壁から部屋へ向かう向き。
    type alias Torch = { at = Vec3.Vec3, facing = Vec3.Vec3 }

    def torches(): List[Torch] =
        { at = Vec3.v3(0.12, 2.0, 3.0), facing = Vec3.v3(1.0, 0.0, 0.0) } ::
        { at = Vec3.v3(7.88, 2.0, 2.4), facing = Vec3.v3(-1.0, 0.0, 0.0) } ::
        { at = Vec3.v3(3.1, 2.0, 5.88), facing = Vec3.v3(0.0, 0.0, -1.0) } ::
        { at = Vec3.v3(6.2, 2.0, 5.88), facing = Vec3.v3(0.0, 0.0, -1.0) } :: Nil

    /// 箱 1 つ（6 面とも外を向く）。
    def cube(lo: Vec3.Vec3, hi: Vec3.Vec3, color: Color): List[Mesh3d.Polygon] =
        let (x0, y0, z0) = (lo#x, lo#y, lo#z);
        let (x1, y1, z1) = (hi#x, hi#y, hi#z);
        let v = Vec3.v3;
        quad(v(x0, y1, z0), v(x0, y1, z1), v(x1, y1, z1), v(x1, y1, z0), color) ::
        quad(v(x0, y0, z0), v(x1, y0, z0), v(x1, y0, z1), v(x0, y0, z1), color) ::
        quad(v(x1, y0, z1), v(x1, y1, z1), v(x0, y1, z1), v(x0, y0, z1), color) ::
        quad(v(x0, y0, z0), v(x0, y1, z0), v(x1, y1, z0), v(x1, y0, z0), color) ::
        quad(v(x1, y0, z0), v(x1, y1, z0), v(x1, y1, z1), v(x1, y0, z1), color) ::
        quad(v(x0, y0, z1), v(x0, y1, z1), v(x0, y1, z0), v(x0, y0, z0), color) :: Nil

    /// 松明の形（柄と炎の芯。原点 = 炎の真ん中・world の単位）。
    def torchMesh(): Mesh3d.Mesh3d =
        let m = meter();
        let v = (x, y, z) -> Vec3.v3(x * m, y * m, z * m);
        Mesh3d.fromPolygons(List.append(
            cube(v(-0.04, -0.45, -0.04), v(0.04, -0.08, 0.04), rgb(0.22, 0.14, 0.08)),
            cube(v(-0.07, -0.08, -0.07), v(0.07, 0.12, 0.07), rgb(1.0, 0.78, 0.35))))

    def torchInstance(mesh: Mesh3d.Mesh3d, torch: Torch): Scene3d.Instance3d =
        Scene3d.meshInstance(mesh, Mat4.translate(Vec3.mul(torch#at, meter()))) |> Scene3d.withName("torch")

    /// 炎から少し部屋の側へ出した点光源（壁に貼り付けると壁の面が光の真後ろになり、照らされない）。
    def torchLight(torch: Torch): Scene3d.PointLight =
        { position = Vec3.mul(Vec3.add(torch#at, Vec3.mul(torch#facing, 0.3)), meter()),
          color = rgb(1.0, 0.72, 0.42), intensity = 1.5, range = 6.5 * meter() }

    // ── 場面 ──

    /// 部屋の形の作り置き（殻・松明・家具）。毎コマ作り直さないように一度だけ組む。
    pub type alias Kit = { shell = Mesh3d.Mesh3d, torch = Mesh3d.Mesh3d, furniture = List[Scene3d.Instance3d] }

    pub def kitOf(meshes: Map[String, Mesh3d.Mesh3d]): Kit =
        { shell = shellMesh(), torch = torchMesh(), furniture = props() |> List.filterMap(propInstance(meshes)) }

    /// 目の高さ（1.6 m）・南の壁の近くから北を向くカメラ。yaw はラジアン。
    pub def camera(yaw: Float64): Camera3d.Camera3d =
        { eye = Vec3.v3(4.0 * meter(), 1.7 * meter(), 0.35 * meter()), yaw = yaw, pitch = 0.14,
          fovY = 1.05, near = 1.0, far = 400.0 }

    pub def scene(kit: Kit, yaw: Float64): Scene3d.Scene3dCmd =
        { instances = (Scene3d.meshInstance(kit#shell, Mat4.identity()) |> Scene3d.withName("shell")) ::
                      List.append(kit#furniture, torches() |> List.map(torchInstance(kit#torch))),
          pointLights = torches() |> List.map(torchLight),
          environment = { ambient = rgb(0.16, 0.13, 0.15), hemisphere = 0.25, toonSteps = 0,
                          fog = Some({ color = rgb(0.03, 0.02, 0.03), near = 4.0 * meter(), far = 14.0 * meter() }),
                          background = Some(rgb(0.0, 0.0, 0.0)) }
          | Scene3d.scene(camera(yaw), design()) }

    /// 画面全体に部屋を 1 つ置いた描き物の列。
    pub def items(kit: Kit, yaw: Float64): List[Render.PlacedItem] =
        Render.scene3d(Vec2.zero(), scene(kit, yaw)) :: Nil
}
