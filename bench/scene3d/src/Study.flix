// Study — 暗い書斎の丸い木の卓に、強く光る緑の球・真鍮の燭台のろうそく・ランタン・本の列・虫眼鏡を置いた場面（view transform と preset の見比べ用）。
// 家具は実写スキャンの glTF（Poly Haven・CC0）を Blender で .glb にした物を dir から読む。glb は git に入れない（無い時は場面を作らずに止める）。
// 座標は engine の Scene3d の約束（左手系・X = 東・Y = 上・Z = 北・1 = 1 m）。卓の天板は y = 1.004。
mod Study {
    use fge::{Camera3d, Color, HeadlessLoad, Gltf, Mat4, Mesh3d, Model3d, Num, Render, Scene3d, ShaderDoc, Vec2, Vec3}
    use fge::ShaderDoc.{BinOp, Field, Shade, Out, UnOp, Axis3}

    pub def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    /// 読んだ家具。
    pub type alias Kit = { table = Model3d.Model3d, candles = Model3d.Model3d, lantern = Model3d.Model3d,
                           glass = Model3d.Model3d, books = Model3d.Model3d }

    /// dir の .glb を全部読む。読めない物があれば Err（ファイルの名前つき）。
    pub def load(dir: String): Result[String, Kit] \ Fs.FileRead + IO =
        let model = (name: String) -> {
            let path = "${dir}/${name}.glb";
            Fs.FileRead.readBytes(path) |> Result.mapErr(e -> "${path}: 読めない（${e}）") |> Result.flatMap(Gltf.decodeWith(HeadlessLoad.stbDecoder(), { pbr = true | Gltf.defaultLoadOptions() }, None))
        };
        forM (table <- model("round_wooden_table_01"); candles <- model("brass_candleholders"); lantern <- model("Lantern_01");
              glass <- model("magnifying_glass_01"); books <- model("book_encyclopedia_set_01"))
        yield { table = table, candles = candles, lantern = lantern, glass = glass, books = books }

    def v(x: Float64, y: Float64, z: Float64): Vec3.Vec3 = Vec3.v3(x, y, z)

    def top(): Float64 = 1.004

    /// model の parts を world で置く。glTF の光る材質（ろうそくの火）は emission を k 倍にする。
    def placed(model: Model3d.Model3d, world: Mat4.Mat4, glow: Float64): List[Scene3d.Instance3d] =
        model#parts |> List.map(part -> {
            let inst = Scene3d.meshInstance(part#mesh, world);
            let lit = part#gltfMaterial |> Option.map(g -> g#emissive#r + g#emissive#g + g#emissive#b > 0.0) |> Option.getWithDefault(false);
            match part#material {
                case Some(m) => Scene3d.withMaterial(if (lit) Scene3d.withEmissionIntensity(glow, m) else m, inst)
                case None    => inst
            }
        })

    def at(x: Float64, y: Float64, z: Float64, turn: Float64, s: Float64): Mat4.Mat4 =
        Mat4.mul(Mat4.translate(v(x, y, z)), Mat4.mul(Mat4.rotateY(turn), Mat4.scale(v(s, s, s))))

    /// 軸にそろった箱（外から見て時計回り）。inward なら中から見て表。
    def box(lo: Vec3.Vec3, hi: Vec3.Vec3, inward: Bool): Mesh3d.Mesh3d =
        let (x0, y0, z0, x1, y1, z1) = (lo#x, lo#y, lo#z, hi#x, hi#y, hi#z);
        let c = Color.rgb(1.0, 1.0, 1.0);
        let face = (ps: List[Vec3.Vec3]) -> { points = if (inward) List.reverse(ps) else ps, color = c };
        Mesh3d.fromPolygons(
            face(v(x0, y1, z0) :: v(x0, y1, z1) :: v(x1, y1, z1) :: v(x1, y1, z0) :: Nil)
                :: face(v(x0, y0, z0) :: v(x1, y0, z0) :: v(x1, y0, z1) :: v(x0, y0, z1) :: Nil)
                :: face(v(x0, y0, z0) :: v(x0, y1, z0) :: v(x1, y1, z0) :: v(x1, y0, z0) :: Nil)
                :: face(v(x1, y0, z1) :: v(x1, y1, z1) :: v(x0, y1, z1) :: v(x0, y0, z1) :: Nil)
                :: face(v(x0, y0, z1) :: v(x0, y1, z1) :: v(x0, y1, z0) :: v(x0, y0, z0) :: Nil)
                :: face(v(x1, y0, z0) :: v(x1, y1, z0) :: v(x1, y1, z1) :: v(x1, y0, z1) :: Nil)
                :: Nil)

    def sphere(center: Vec3.Vec3, r: Float64): Mesh3d.Mesh3d =
        let rows = 24;
        let cols = 40;
        let pt = (i: Int32, j: Int32) -> {
            let th = Num.pi() * Int32.toFloat64(i) / Int32.toFloat64(rows);
            let ph = 0.0 - Num.tau() * Int32.toFloat64(j) / Int32.toFloat64(cols);
            v(center#x + r * Num.sin(th) * Num.cos(ph), center#y + r * Num.cos(th), center#z + r * Num.sin(th) * Num.sin(ph))
        };
        Mesh3d.fromPolygons(List.range(0, rows) |> List.flatMap(i -> List.range(0, cols) |> List.map(j ->
            { points = pt(i, j) :: pt(i, j + 1) :: pt(i + 1, j + 1) :: pt(i + 1, j) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) })))

    def k(x: Float64): Field = Field.Const(x)
    def world(a: Axis3): Field = Field.World({ axis = a })

    /// 壁の漆喰（world の点の雲のノイズで濃淡）。
    def plaster(): Scene3d.Material3d =
        let n = Field.Fbm({ octaves = 4, scale = 3.0, seed = 7 });
        Scene3d.material({ name = "study_plaster", cycleRate = 0.0, bindings = Nil,
            out = Out.Fill({ shade = Shade.Ramp({ lo = Color.rgb(0.16, 0.13, 0.11), hi = Color.rgb(0.30, 0.26, 0.22), field = n }), alpha = k(1.0) }) })
            |> Scene3d.withMetallicRoughness(0.0, 0.95)

    /// 床の板（x に沿った板の継ぎ目と、板ごとの木目の濃淡）。
    def planks(): Scene3d.Material3d =
        let along = Field.Bin({ op = BinOp.Mul, a = world(Axis3.Z), b = k(5.0) });
        let seam = Field.Smoothstep({ lo = 0.0, hi = 0.06, of = Field.Un({ op = UnOp.Fract, of = along }) });
        let grain = Field.Fbm({ octaves = 3, scale = 9.0, seed = 3 });
        let tone = Field.Bin({ op = BinOp.Mul, a = seam, b = Field.Blend({ a = k(0.55), b = k(1.0), by = grain }) });
        Scene3d.material({ name = "study_planks", cycleRate = 0.0, bindings = Nil,
            out = Out.Fill({ shade = Shade.Ramp({ lo = Color.rgb(0.05, 0.03, 0.02), hi = Color.rgb(0.36, 0.22, 0.12), field = tone }), alpha = k(1.0) }) })
            |> Scene3d.withMetallicRoughness(0.0, 0.7)

    def glowing(name: String, c: Color, intensity: Float64): Scene3d.Material3d =
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil, out = Out.Fill({ shade = Shade.Solid(c), alpha = k(1.0) }) })
            |> Scene3d.withEmission(Shade.Solid(c)) |> Scene3d.withEmissionIntensity(intensity)

    def green(): Color = Color.rgb(0.0, 1.0, 0.08)
    def warm(): Color = Color.rgb(1.0, 0.55, 0.18)

    pub def scene(kit: Kit): Scene3d.Scene3dCmd =
        let y = top();
        let orbAt = v(0.0, y + 0.1, 0.08);
        let lanternAt = v(-0.36, y, -0.04);
        let candlesAt = v(0.02, y, 0.4);
        let instances = List.flatten(
            ((Scene3d.meshInstance(box(v(-3.0, 0.0, -3.0), v(3.0, 3.0, 3.0), true), Mat4.identity()) |> Scene3d.withMaterial(plaster()))
                :: (Scene3d.meshInstance(box(v(-3.0, -0.02, -3.0), v(3.0, 0.0, 3.0), false), Mat4.identity()) |> Scene3d.withMaterial(planks()))
                :: (Scene3d.meshInstance(sphere(orbAt, 0.09), Mat4.identity()) |> Scene3d.withMaterial(glowing("study_orb", green(), 8.0)))
                :: (Scene3d.meshInstance(sphere(v(lanternAt#x, y + 0.1, lanternAt#z), 0.026), Mat4.identity()) |> Scene3d.withMaterial(glowing("study_lantern", warm(), 20.0)))
                :: Nil)
            :: placed(kit#table, Mat4.identity(), 1.0)
            :: placed(kit#candles, at(candlesAt#x, candlesAt#y, candlesAt#z, 0.0, 0.42), 4.0)
            :: placed(kit#lantern, at(lanternAt#x, lanternAt#y, lanternAt#z, 0.4, 1.0), 1.0)
            :: placed(kit#books, at(0.3, y, -0.18, 0.0 - Num.pi() / 2.0, 1.0), 1.0)
            :: placed(kit#glass, Mat4.mul(Mat4.translate(v(-0.1, y + 0.014, -0.28)), Mat4.mul(Mat4.rotateY(0.7), Mat4.rotateX(Num.pi() / 2.0))), 1.0)
            :: Nil);
        let camera = { eye = v(0.0, 1.3, -0.82), yaw = 0.0, pitch = 0.27, fovY = 0.7, near = 0.03, far = 20.0, lensShift = Vec2.zero() };
        { instances = instances,
          pointLights = { position = orbAt, color = green(), intensity = 1.6, range = 2.4 }
              :: { position = v(lanternAt#x, y + 0.095, lanternAt#z), color = warm(), intensity = 1.4, range = 1.8 }
              :: { position = v(candlesAt#x, y + 0.4, candlesAt#z), color = warm(), intensity = 1.4, range = 2.2 } :: Nil,
          sky = Some(Scene3d.gradientSky(Color.rgb(0.05, 0.05, 0.07), Color.rgb(0.10, 0.08, 0.07), Color.rgb(0.04, 0.03, 0.03))),
          textures = List.flatten(kit#table#textures :: kit#candles#textures :: kit#lantern#textures :: kit#glass#textures :: kit#books#textures :: Nil),
          environment = { ambient = Color.rgb(0.05, 0.05, 0.055), hemisphere = 0.0, toonSteps = 0, fog = None, background = None }
          | Scene3d.scene(camera, design()) }

    pub def items(kit: Kit): List[Render.PlacedItem] = Render.scene3d(Vec2.zero(), scene(kit)) :: Nil
}
