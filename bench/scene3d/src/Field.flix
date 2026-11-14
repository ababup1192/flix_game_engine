// Field — 小さな箱と柱を格子に並べた 3D の場面。物の数・形の種類・材質の種類・動く割合・半透明の割合・太陽の影をつまみで替える。
// 物は全部カメラに入る（数を増やした分だけ描く物が増える）。座標は engine の Scene3d の約束（左手系・X = 東・Y = 上・Z = 北）。
mod Field {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, Render, Scene3d, ShaderDoc, Vec2, Vec3}

    /// 形の種類。Shared(k) = k 種類を順に使う・PerObject = 物ごとに違う形。
    pub enum Shapes with Eq {
        case Shared(Int32)
        case PerObject
    }

    /// つまみ。count = 物の数・materials = 材質の種類・movingPercent = 毎コマ位置と向きを変える物の割合（%）・
    /// translucentPercent = 半透明の物の割合（%）・sunShadow = 太陽の影を落とすか。
    pub type alias Config = { count = Int32, shapes = Shapes, materials = Int32, movingPercent = Int32, translucentPercent = Int32, sunShadow = Bool }

    /// つまみの表（n・shapes = 数か each・mats・moving・alpha・shadow = 1 で影あり）を読む。
    pub def configOf(knobs: Map[String, String]): Config =
        { count = Int32.max(1, BenchRun.intKnob("n", 1000, knobs)),
          shapes = if (Map.get("shapes", knobs) == Some("each")) Shapes.PerObject else Shapes.Shared(Int32.max(1, BenchRun.intKnob("shapes", 1, knobs))),
          materials = Int32.max(1, BenchRun.intKnob("mats", 1, knobs)),
          movingPercent = BenchRun.intKnob("moving", 100, knobs),
          translucentPercent = BenchRun.intKnob("alpha", 0, knobs),
          sunShadow = Map.get("shadow", knobs) == Some("1") }

    /// 結果の行に足すつまみ（JSON の値）。
    pub def knobFields(c: Config): List[(String, String)] =
        let shapes = match c#shapes {
            case Shapes.Shared(k) => Int32.toString(k)
            case Shapes.PerObject => BenchRun.quoted("each")
        };
        ("n", Int32.toString(c#count)) :: ("shapes", shapes) :: ("mats", Int32.toString(c#materials)) ::
        ("moving", Int32.toString(c#movingPercent)) :: ("alpha", Int32.toString(c#translucentPercent)) ::
        ("shadow", if (c#sunShadow) "1" else "0") :: Nil

    /// 描き物の大きさ（design px）。
    pub def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    /// 格子の間隔（world の長さ）。
    def spacing(): Float64 = 3.0

    def fract(x: Float64): Float64 = x - Float64.floor(x)

    // ── 形 ──

    def quad(a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3, d: Vec3.Vec3, color: Color): Mesh3d.Polygon =
        { points = a :: b :: c :: d :: Nil, color = color }

    /// 底の真ん中が原点の箱（6 面とも外を向く）。half = 幅と奥行きの半分・height = 高さ。
    def boxMesh(halfW: Float64, height: Float64, halfD: Float64): Mesh3d.Mesh3d =
        let (x0, y0, z0) = (0.0 - halfW, 0.0, 0.0 - halfD);
        let (x1, y1, z1) = (halfW, height, halfD);
        let v = Vec3.v3;
        let (top, side, front) = (Color.rgb(1.0, 1.0, 1.0), Color.rgb(0.78, 0.78, 0.78), Color.rgb(0.62, 0.62, 0.62));
        Mesh3d.fromPolygons(
            quad(v(x0, y1, z0), v(x0, y1, z1), v(x1, y1, z1), v(x1, y1, z0), top) ::
            quad(v(x0, y0, z0), v(x1, y0, z0), v(x1, y0, z1), v(x0, y0, z1), front) ::
            quad(v(x1, y0, z1), v(x1, y1, z1), v(x0, y1, z1), v(x0, y0, z1), front) ::
            quad(v(x0, y0, z0), v(x0, y1, z0), v(x1, y1, z0), v(x1, y0, z0), front) ::
            quad(v(x1, y0, z0), v(x1, y1, z0), v(x1, y1, z1), v(x1, y0, z1), side) ::
            quad(v(x0, y0, z1), v(x0, y1, z1), v(x0, y1, z0), v(x0, y0, z0), side) :: Nil)

    /// k 番目の形（寸法は k で決まる。低い箱から細い柱まで）。
    def shapeOf(k: Int32): Mesh3d.Mesh3d =
        let f = Int32.toFloat64(k);
        boxMesh(0.35 + 0.6 * fract(f * 0.61803), 0.5 + 2.5 * fract(f * 0.2716), 0.35 + 0.6 * fract(f * 0.7548))

    def shapeCount(c: Config): Int32 = match c#shapes {
        case Shapes.Shared(k) => k
        case Shapes.PerObject => c#count
    }

    // ── 材質 ──

    /// 頂点の色 × 材質の色（Param の r・g・b）。α は Param の a。
    // WhyNot: 色を木の Const に入れない — 材質の種類ごとにプログラムを組むことになり、測りたい「値だけが違う材質」にならない。
    def spec(): ShaderDoc.Spec =
        let tinted = (chan: ShaderDoc.TexChan, name: String) ->
            ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, a = ShaderDoc.Field.VertexColor({ chan = chan }), b = ShaderDoc.Field.Param({ name = name }) });
        { name = "bench:field", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = tinted(ShaderDoc.TexChan.R, "r"), g = tinted(ShaderDoc.TexChan.G, "g"),
                                                                   b = tinted(ShaderDoc.TexChan.B, "b") }),
                                     alpha = ShaderDoc.Field.Param({ name = "a" }) }) }

    /// k 番目の材質（色は k で決まる）。translucent なら α 0.5 の半透明。
    def materialOf(translucent: Bool, k: Int32): Scene3d.Material3d =
        let f = Int32.toFloat64(k);
        let params = Map#{ "r" => 0.35 + 0.65 * fract(f * 0.61803), "g" => 0.35 + 0.65 * fract(f * 0.2716 + 0.3),
                           "b" => 0.35 + 0.65 * fract(f * 0.7548 + 0.6), "a" => if (translucent) 0.5 else 1.0 };
        Scene3d.material(spec()) |> Scene3d.withParams(params) |> Scene3d.withAlphaBlend(translucent)

    // ── 置き方 ──

    /// 置いた物 1 つ。at = 底の真ん中・phase = 動きの位相・moves = 毎コマ動くか・resting = 動かない時の物。
    type alias Placed = { mesh = Mesh3d.Mesh3d, material = Scene3d.Material3d, at = Vec3.Vec3, phase = Float64, moves = Bool, resting = Scene3d.Instance3d }

    /// 場面の作り置き。allResting = 全部が動かない時の物の列（動く割合 0% のコマはこれをそのまま渡す）。
    pub type alias Kit = { config = Config, extent = Float64, ground = Scene3d.Instance3d, placed = List[Placed], allResting = List[Scene3d.Instance3d] }

    /// 格子の 1 辺の物の数。
    def sideOf(count: Int32): Int32 =
        Float64.ceil(Num.sqrt(Int32.toFloat64(count))) |> Float64.tryToInt32 |> Option.getWithDefault(1)

    def instanceOf(mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d, world: Mat4.Mat4): Scene3d.Instance3d =
        Scene3d.meshInstance(mesh, world) |> Scene3d.withMaterial(material)

    pub def kitOf(c: Config): Kit =
        let side = sideOf(c#count);
        let extent = Int32.toFloat64(side) * spacing();
        let shapes = Vector.range(0, shapeCount(c)) |> Vector.map(shapeOf);
        let opaque = Vector.range(0, c#materials) |> Vector.map(materialOf(false));
        let translucent = Vector.range(0, c#materials) |> Vector.map(materialOf(true));
        let placed = List.range(0, c#count) |> List.map(i -> {
            let at = Vec3.v3((Int32.toFloat64(Int32.modulo(i, side)) + 0.5) * spacing() - extent / 2.0, 0.0, (Int32.toFloat64(i / side) + 0.5) * spacing());
            let mesh = Vector.get(Int32.modulo(i, Vector.length(shapes)), shapes);
            // WhyNot: 材質も i の剰余で選ばない — 形と材質が同じ周期で回り、16 × 16 の組が 16 通りにしかならない。
            let materialIndex = Int32.modulo(i / 16, c#materials);
            let material = if (Int32.modulo(i + 37, 100) < c#translucentPercent) Vector.get(materialIndex, translucent) else Vector.get(materialIndex, opaque);
            { mesh = mesh, material = material, at = at, phase = Int32.toFloat64(i) * 2.39996, moves = Int32.modulo(i, 100) < c#movingPercent,
              resting = instanceOf(mesh, material, Mat4.translate(at)) }
        });
        let groundMesh = Mesh3d.fromPolygons(
            quad(Vec3.v3(0.0 - extent, 0.0, 0.0 - extent / 2.0), Vec3.v3(0.0 - extent, 0.0, extent * 1.5),
                 Vec3.v3(extent, 0.0, extent * 1.5), Vec3.v3(extent, 0.0, 0.0 - extent / 2.0), Color.rgb(0.42, 0.46, 0.40)) :: Nil);
        { config = c, extent = extent, ground = Scene3d.meshInstance(groundMesh, Mat4.identity()), placed = placed,
          allResting = placed |> List.map(p -> p#resting) }

    /// 動く物の t 秒の姿（その場で回りながら上下する）。
    def movedInstance(p: Placed, t: Float64): Scene3d.Instance3d =
        let lift = 0.4 + 0.4 * Num.sin(t * 2.0 + p#phase);
        instanceOf(p#mesh, p#material, Mat4.mul(Mat4.translate(Vec3.add(p#at, Vec3.v3(0.0, lift, 0.0))), Mat4.rotateY(t * 1.5 + p#phase)))

    def instancesAt(kit: Kit, t: Float64): List[Scene3d.Instance3d] =
        if (kit#config#movingPercent <= 0) kit#allResting
        else kit#placed |> List.map(instanceAt(t))

    /// p の t 秒の姿（動かない物は置いた時の姿）。
    // WhyNot: instancesAt の List.map のラムダへ書き下さない・movedInstance の呼び出しで終えない — 呼び出しで終わる関数は続き（Thunk）を返し、
    //   1 コマに 1 回しか呼ばれないループを JVM が途中から JIT できず、物の数だけインタプリタで回る（docs/performance.md の 13 節）。
    // WhyNot: let に受けて返すだけの形にしない — Flix がたたむと movedInstance の呼び出しで終わる形に戻りうる（たたむかは確かめていない）。Option に包めば呼び出しの後に match が残る。
    @DontInline
    def instanceAt(t: Float64, p: Placed): Scene3d.Instance3d =
        match (if (p#moves) Some(movedInstance(p, t)) else None) {
            case Some(moved) => moved
            case None        => p#resting
        }

    // ── 場面 ──

    /// 格子の全部が入る高さと引きのカメラ（南の外から北を見下ろす）。
    def camera(extent: Float64): Camera3d.Camera3d =
        { eye = Vec3.v3(0.0, extent * 0.45, 0.0 - extent * 0.55), yaw = 0.0, pitch = 0.49, fovY = 1.05, near = 1.0, far = extent * 4.0 + 100.0 }

    def sun(c: Config, extent: Float64): Scene3d.DirectionalLight =
        let light = { intensity = 0.9 | Scene3d.directionalLight(Vec3.v3(-0.45, -1.0, 0.35)) };
        if (c#sunShadow) { shadow = Some({ distance = extent * 2.5, casterReach = extent * 2.5 | Scene3d.directionalShadow() }) | light }
        else light

    pub def scene(kit: Kit, t: Float64): Scene3d.Scene3dCmd =
        { instances = kit#ground :: instancesAt(kit, t),
          directionalLight = Some(sun(kit#config, kit#extent)),
          environment = { ambient = Color.rgb(0.38, 0.40, 0.46), hemisphere = 0.3, toonSteps = 0, fog = None,
                          background = Some(Color.rgb(0.55, 0.68, 0.82)) }
          | Scene3d.scene(camera(kit#extent), design()) }

    /// 画面全体に場面を 1 つ置いた描き物の列。
    pub def items(kit: Kit, t: Float64): List[Render.PlacedItem] =
        Render.scene3d(Vec2.zero(), scene(kit, t)) :: Nil
}
