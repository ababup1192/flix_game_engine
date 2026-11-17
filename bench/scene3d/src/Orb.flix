// Orb — 暗い部屋の丸い卓に、強く光る緑の球・ろうそく 2 本・赤い液の瓶・本の積みを置いた場面（view transform の違いを見比べる用）。
// 光る物は emission を 1 を大きく超える明るさにする（Standard では色のまま飽和し、AgX では芯が白へ抜ける所を見せる）。
// 形は基本形（箱・円柱・球）を多角形で組む。座標は engine の Scene3d の約束（左手系・X = 東・Y = 上・Z = 北・1 = 1 m）。
mod Orb {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, Render, Scene3d, ShaderDoc, Vec2, Vec3}

    pub def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def v(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = Vec3.v3(x, y, z)

    /// 軸にそろった箱（外から見て時計回りの 6 面）。
    def box(lo: Vec3.Vec3, hi: Vec3.Vec3, c: Color): List[Mesh3d.Polygon] =
        let (x0, y0, z0, x1, y1, z1) = (lo#x, lo#y, lo#z, hi#x, hi#y, hi#z);
        let face = ps -> { points = ps, color = c };
        face(v(x0, y1, z0) :: v(x0, y1, z1) :: v(x1, y1, z1) :: v(x1, y1, z0) :: Nil)
            :: face(v(x0, y0, z0) :: v(x1, y0, z0) :: v(x1, y0, z1) :: v(x0, y0, z1) :: Nil)
            :: face(v(x0, y0, z0) :: v(x0, y1, z0) :: v(x1, y1, z0) :: v(x1, y0, z0) :: Nil)
            :: face(v(x1, y0, z1) :: v(x1, y1, z1) :: v(x0, y1, z1) :: v(x0, y0, z1) :: Nil)
            :: face(v(x0, y0, z1) :: v(x0, y1, z1) :: v(x0, y1, z0) :: v(x0, y0, z0) :: Nil)
            :: face(v(x1, y0, z0) :: v(x1, y1, z0) :: v(x1, y1, z1) :: v(x1, y0, z1) :: Nil)
            :: Nil

    /// 部屋の内側（床・壁・天井。中から見て表）。
    def room(c: Color): List[Mesh3d.Polygon] =
        box(v(-3.0, 0.0, -3.0), v(3.0, 3.0, 3.0), c) |> List.map(p -> { points = List.reverse(p#points) | p })

    def ring(cx: Float64, cz: Float64, r: Float64, y: Float64, n: Int32): List[Vec3.Vec3] =
        List.range(0, n) |> List.map(i -> {
            let a = 0.0 - Int32.toFloat64(i) / Int32.toFloat64(n) * Num.tau();
            v(cx + Num.cos(a) * r, y, cz + Num.sin(a) * r)
        })

    /// 円柱（上と下のふたつき）。
    def cylinder(cx: Float64, cz: Float64, r: Float64, y0: Float64, y1: Float64, c: Color): List[Mesh3d.Polygon] =
        let n = 28;
        let top = ring(cx, cz, r, y1, n);
        let bottom = ring(cx, cz, r, y0, n);
        let sides = List.range(0, n) |> List.map(i -> {
            let j = Int32.remainder(i + 1, n);
            let at = (ps: List[Vec3.Vec3], k: Int32) -> List.drop(k, ps) |> List.head |> Option.getWithDefault(Vec3.zero());
            { points = at(bottom, i) :: at(top, i) :: at(top, j) :: at(bottom, j) :: Nil, color = c }
        });
        { points = top, color = c } :: { points = List.reverse(bottom), color = c } :: sides

    /// 球（緯度と経度で割った四角の列）。
    def sphere(center: Vec3.Vec3, r: Float64, c: Color): List[Mesh3d.Polygon] =
        let rows = 16;
        let cols = 28;
        let at = (i: Int32, j: Int32) -> {
            let th = Num.pi() * Int32.toFloat64(i) / Int32.toFloat64(rows);
            let ph = 0.0 - Num.tau() * Int32.toFloat64(j) / Int32.toFloat64(cols);
            v(center#x + r * Num.sin(th) * Num.cos(ph), center#y + r * Num.cos(th), center#z + r * Num.sin(th) * Num.sin(ph))
        };
        List.range(0, rows) |> List.flatMap(i -> List.range(0, cols) |> List.map(j ->
            { points = at(i, j) :: at(i, j + 1) :: at(i + 1, j + 1) :: at(i + 1, j) :: Nil, color = c }))

    def solid(name: String, c: Color): Scene3d.Material3d =
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(1.0) }) })

    def glowing(name: String, c: Color, k: Float64): Scene3d.Material3d =
        solid(name, c) |> Scene3d.withEmission(ShaderDoc.Shade.Solid(c)) |> Scene3d.withEmissionIntensity(k)

    def placed(polys: List[Mesh3d.Polygon], m: Scene3d.Material3d): Scene3d.Instance3d =
        Scene3d.meshInstance(Mesh3d.fromPolygons(polys), Mat4.identity()) |> Scene3d.withMaterial(m)

    def green(): Color = Color.rgb(0.0, 1.0, 0.08)
    def flame(): Color = Color.rgb(1.0, 0.45, 0.05)

    /// 場面。t で炎が少し揺れる（撮る時は t = 0 のコマ）。
    pub def scene(t: Float64): Scene3d.Scene3dCmd =
        let wall = Color.rgb(0.32, 0.27, 0.24);
        let wood = Color.rgb(0.42, 0.24, 0.12);
        let wax = Color.rgb(0.92, 0.88, 0.78);
        let flicker = 1.0 + 0.05 * Num.sin(t * 9.0);
        let candle = (x: Float64, z: Float64) ->
            placed(cylinder(x, z, 0.035, 0.76, 0.9, wax), solid("orb_wax", wax))
                :: placed(sphere(v(x, 0.93, z), 0.022, flame()), glowing("orb_flame", flame(), 10.0 * flicker)) :: Nil;
        let books = placed(List.flatten(
                box(v(0.25, 0.76, 0.18), v(0.47, 0.8, 0.46), Color.rgb(0.7, 0.08, 0.08))
                    :: box(v(0.27, 0.8, 0.2), v(0.46, 0.84, 0.45), Color.rgb(0.08, 0.2, 0.65))
                    :: box(v(0.24, 0.84, 0.22), v(0.45, 0.87, 0.44), Color.rgb(0.85, 0.65, 0.1)) :: Nil), solid("orb_books", Color.rgb(1.0, 1.0, 1.0)));
        let bottle = placed(cylinder(-0.32, 0.22, 0.06, 0.76, 0.98, Color.rgb(0.75, 0.04, 0.06)), solid("orb_liquid", Color.rgb(0.75, 0.04, 0.06)));
        let instances = List.flatten(
            (placed(room(wall), solid("orb_wall", wall))
                :: placed(cylinder(0.0, 0.25, 0.62, 0.72, 0.76, wood), solid("orb_table", wood))
                :: placed(cylinder(0.0, 0.25, 0.08, 0.0, 0.72, wood), solid("orb_leg", wood))
                :: placed(sphere(v(0.0, 0.92, 0.25), 0.15, green()), glowing("orb_orb", green(), 8.0))
                :: books :: bottle :: Nil)
                :: candle(-0.42, 0.45) :: candle(0.4, -0.02) :: Nil);
        let camera = { eye = v(0.0, 1.22, -1.15), yaw = 0.0, pitch = 0.22, fovY = 0.75, near = 0.05, far = 20.0, lensShift = Vec2.zero() };
        { instances = instances,
          pointLights = { position = v(0.0, 0.92, 0.25), color = green(), intensity = 2.0, range = 2.2 }
              :: { position = v(-0.42, 0.95, 0.45), color = flame(), intensity = 1.2, range = 1.6 }
              :: { position = v(0.4, 0.95, -0.02), color = flame(), intensity = 1.2, range = 1.6 } :: Nil,
          environment = { ambient = Color.rgb(0.02, 0.02, 0.025), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(Color.rgb(0.0, 0.0, 0.0)) }
          | Scene3d.scene(camera, design()) }

    pub def items(t: Float64): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene(t)) :: Nil
}
