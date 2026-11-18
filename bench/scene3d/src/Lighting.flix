// Lighting — 点光源の影・光の量の読み方（Legacy / Physical）・ビルボードの影の板の倍率を見比べる場面。
// 夜の街灯の場面（lampsScene）は実機の窓の重さ（make run SCENE=lamps SHADOWS=n）と CPU の静止画（make lighting）が同じこれを描く。
// 座標は engine の Scene3d の約束（左手系・X = 東・Y = 上・Z = 北）。長さは m（1 m = world の 1）。
mod Lighting {
    use fge::{Camera3d, Color, Mat4, Mesh3d, Num, Render, Scene3d, ShaderDoc, Vec2, Vec3}

    /// 夜の街灯の場面のつまみ。lamps = 街灯の本数（1〜8）・shadows = 点光源の影（None で影なし）・
    /// casterScale = 人の板の影の板の倍率・units = 光の量の読み方・intensityScale = 灯りの intensity に掛ける数（Physical で π 倍の比べ）・
    /// sun = 夕方の低い太陽と影を足す（ビルボードの太陽の影の比べ）。
    pub type alias Config = { lamps = Int32, shadows = Option[Scene3d.PointShadowMap], casterScale = Vec2.Vec2,
                              units = Scene3d.LightUnits, intensityScale = Float64, sun = Bool }

    pub def defaultConfig(): Config =
        { lamps = 6, shadows = None, casterScale = Vec2.one(), units = Scene3d.LightUnits.Legacy, intensityScale = 1.0, sun = false }

    /// 描き物の大きさ（design px）。
    pub def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def rgb(r: Float64, g: Float64, b: Float64): Color = Color.rgb(r, g, b)

    pub def pi(): Float64 = 3.141592653589793

    def quad(a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3, d: Vec3.Vec3, color: Color): Mesh3d.Polygon =
        { points = a :: b :: c :: d :: Nil, color = color }

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

    /// 道の石畳（1 m の升目を少しずつ違う灰色で）。
    def ground(): List[Mesh3d.Polygon] =
        List.range(-8, 8) |> List.flatMap(i -> List.range(-6, 18) |> List.map(j -> {
            let x = Int32.toFloat64(i);
            let z = Int32.toFloat64(j);
            let k = 0.30 + 0.04 * Int32.toFloat64(Int32.remainder(i * 7 + j * 13 + 100, 5)) / 4.0;
            quad(Vec3.v3(x, 0.0, z), Vec3.v3(x, 0.0, z + 1.0), Vec3.v3(x + 1.0, 0.0, z + 1.0), Vec3.v3(x + 1.0, 0.0, z), rgb(k, k * 0.95, k * 0.9))
        }))

    /// 街灯の立つ所（道の両側に 2 列・前から順）。
    def lampSpots(): List[Vec3.Vec3] =
        Vec3.v3(-3.2, 0.0, 0.0) :: Vec3.v3(3.2, 0.0, 2.5) :: Vec3.v3(-3.2, 0.0, 5.0) :: Vec3.v3(3.2, 0.0, 7.5) ::
        Vec3.v3(-3.2, 0.0, 10.0) :: Vec3.v3(3.2, 0.0, 12.5) :: Vec3.v3(-3.2, 0.0, 15.0) :: Vec3.v3(3.2, 0.0, 17.5) :: Nil

    def lampPost(at: Vec3.Vec3): List[Mesh3d.Polygon] =
        let side = if (at#x < 0.0) 1.0 else -1.0;
        List.append(cube(Vec3.v3(at#x - 0.07, 0.0, at#z - 0.07), Vec3.v3(at#x + 0.07, 3.3, at#z + 0.07), rgb(0.12, 0.12, 0.14)),
                    cube(Vec3.v3(at#x + side * 0.05 - 0.04, 3.2, at#z - 0.04), Vec3.v3(at#x + side * 0.55 + 0.04, 3.28, at#z + 0.04), rgb(0.12, 0.12, 0.14)))

    /// 灯りの頭（自分で光る黄色の箱）。
    def lampHead(at: Vec3.Vec3): List[Mesh3d.Polygon] =
        let side = if (at#x < 0.0) 1.0 else -1.0;
        let x = at#x + side * 0.55;
        cube(Vec3.v3(x - 0.12, 2.92, at#z - 0.12), Vec3.v3(x + 0.12, 3.2, at#z + 0.12), rgb(1.0, 0.86, 0.55))

    def lampLight(cfg: Config, at: Vec3.Vec3): Scene3d.PointLight =
        let side = if (at#x < 0.0) 1.0 else -1.0;
        { position = Vec3.v3(at#x + side * 0.55, 2.85, at#z), color = rgb(1.0, 0.74, 0.44), intensity = 1.6 * cfg#intensityScale, range = 9.0 }

    /// 道の小物（箱・樽・柱・ベンチ）。
    def props(walls: Bool): List[Mesh3d.Polygon] =
        let wood = rgb(0.46, 0.31, 0.18);
        let stone = rgb(0.55, 0.53, 0.5);
        List.flatten(
            cube(Vec3.v3(-2.4, 0.0, 0.8), Vec3.v3(-1.6, 0.8, 1.6), wood) ::
            cube(Vec3.v3(1.9, 0.0, 3.0), Vec3.v3(2.6, 1.1, 3.7), wood) ::
            cube(Vec3.v3(-1.0, 0.0, 6.0), Vec3.v3(-0.6, 2.2, 6.4), stone) ::
            cube(Vec3.v3(0.9, 0.0, 9.3), Vec3.v3(1.3, 2.2, 9.7), stone) ::
            cube(Vec3.v3(-2.6, 0.0, 9.0), Vec3.v3(-1.2, 0.45, 9.5), wood) ::
            cube(Vec3.v3(2.0, 0.0, 12.0), Vec3.v3(2.7, 0.9, 12.7), wood) ::
            (if (walls) cube(Vec3.v3(-5.0, 0.0, -2.0), Vec3.v3(-4.4, 4.5, 20.0), rgb(0.38, 0.33, 0.3)) ::
                        cube(Vec3.v3(4.4, 0.0, -2.0), Vec3.v3(5.0, 4.5, 20.0), rgb(0.36, 0.32, 0.3)) :: Nil else Nil))

    /// 歩く人の板の位置（t 秒で道の真ん中を北へ歩く）と、立っている人。
    def people(cfg: Config, t: Float64): List[Scene3d.Billboard3d] =
        let walker = Vec3.v3(0.3, 0.0, { let u = t * 1.2; u - 16.0 * Float64.floor(u / 16.0) } - 1.0);
        let standing = Vec3.v3(-1.8, 0.0, 3.2) :: Vec3.v3(1.6, 0.0, 6.8) :: Vec3.v3(-0.4, 0.0, 11.0) :: Nil;
        (walker :: standing) |> List.map(p ->
            Scene3d.billboard("person", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 32.0 } }, p, { x = 0.8, y = 1.6 })
                |> Scene3d.withCastShadows(true) |> Scene3d.withShadowCasterScale(cfg#casterScale))

    /// 道を見下ろすカメラ（HD-2D の町と同じくらいの俯角）。
    pub def camera(t: Float64): Camera3d.Camera3d =
        { eye = Vec3.v3(0.0 + 1.5 * Num.sin(t * 0.25), 7.5, -7.0), yaw = 0.0, pitch = 0.62, fovY = 0.9, near = 0.3, far = 80.0, lensShift = Vec2.zero() }

    pub def lampsScene(cfg: Config, t: Float64): Scene3d.Scene3dCmd =
        let spots = lampSpots() |> List.take(cfg#lamps);
        let solid = Mesh3d.fromPolygons(List.flatten(ground() :: props(not cfg#sun) :: List.map(lampPost, spots)));
        let heads = Mesh3d.fromPolygons(List.flatMap(lampHead, spots));
        let warm = rgb(1.0, 0.86, 0.55);
        let glow = Scene3d.material({ name = "lamp-head", cycleRate = 0.0, bindings = Nil,
                                      out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(warm), alpha = ShaderDoc.Field.Const(1.0) }) })
            |> Scene3d.withEmission(ShaderDoc.Shade.Solid(warm)) |> Scene3d.withEmissionIntensity(2.0);
        let base = { instances = Scene3d.meshInstance(solid, Mat4.identity()) :: (Scene3d.meshInstance(heads, Mat4.identity()) |> Scene3d.withMaterial(glow)) :: Nil,
                     billboards = people(cfg, t),
                     pointLights = spots |> List.map(lampLight(cfg)),
                     environment = { ambient = rgb(0.10, 0.11, 0.16), hemisphere = 0.03, toonSteps = 0,
                                     fog = Some({ color = rgb(0.04, 0.05, 0.09), near = 10.0, far = 30.0 }), background = Some(rgb(0.03, 0.035, 0.07)) }
                   | Scene3d.scene(camera(t), design()) } |> Scene3d.withLightUnits(cfg#units) |> withSun(cfg#sun);
        match cfg#shadows {
            case Some(m) => Scene3d.withPointShadows(m, base)
            case None    => base
        }

    /// 夕方の低い太陽（影つき）と、少し明るい ambient。
    def withSun(on: Bool, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        if (not on) scene
        else {
            let sun = { color = rgb(1.0, 0.82, 0.62), intensity = 1.1,
                        shadow = Some({ mapSize = 2048, distance = 40.0, pcfRadius = 1, bias = 0.03 | Scene3d.directionalShadow() })
                      | Scene3d.directionalLight(Vec3.v3(0.5, -0.45, -0.55)) };
            { directionalLight = Some(sun), environment = { ambient = rgb(0.32, 0.33, 0.4), fog = None, background = Some(rgb(0.45, 0.55, 0.7)) | scene#environment } | scene }
        }

    pub def lampsItems(cfg: Config, t: Float64): List[Render.PlacedItem] =
        Render.scene3d(Vec2.zero(), lampsScene(cfg, t)) :: Nil
}

// LightingStill — Lighting の場面と bench の部屋を CPU（SoftRaster）で描いて debug/lighting/ に書く（窓を開かない）。
// stills = 見比べの静止画・frames = 動画のコマ（夜の街灯・影なし / あり）。ラベルと並べは bin/lighting-sheets.sh（ffmpeg）。
mod LightingStill {
    use fge::{HeadlessFont, HeadlessRender, Render, Scene3d, Vec2}

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def scale(): Int32 = 3

    def config(): HeadlessRender.RenderConfig \ IO =
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        { design = Lighting.design(), scale = scale(), outDir = "debug/lighting", fontTtf = ttf(), fontAtlas = atlas,
          frameW = 320 * scale(), frameH = 180 * scale(), texturePath = Map#{ "person" => "assets/person.png" } | HeadlessRender.defaults() }

    def write(cfg: HeadlessRender.RenderConfig, name: String, scene: Scene3d.Scene3dCmd): Unit \ IO =
        HeadlessRender.renderPngSoft(cfg, Render.softSceneOf(_ -> None, Render.scene3d(Vec2.zero(), scene) :: Nil), name);
        println("[lighting] debug/lighting/${name}.png")

    /// 部屋（1 m = 16）の点光源の影の設定（bias は world の長さ）。
    def roomShadows(): Scene3d.PointShadowMap = { mapSize = 512, bias = 0.6, pcfRadius = 1 | Scene3d.pointShadowMap() }

    def lampShadows(): Scene3d.PointShadowMap = { maxShadowedLights = 6, mapSize = 512, bias = 0.04, pcfRadius = 1 | Scene3d.pointShadowMap() }

    /// 部屋の灯りの intensity を k 倍にした場面。
    def brighter(k: Float64, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        { pointLights = scene#pointLights |> List.map(l -> { intensity = l#intensity * k | l }) | scene }

    pub def stills(): Unit \ IO =
        let cfg = config();
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why) => println("[lighting] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let room = Room.scene(Room.kitOf(meshes), 0.0);
                let physical = room |> Scene3d.withLightUnits(Scene3d.LightUnits.Physical) |> Scene3d.withUnitsPerMeter(16.0);
                write(cfg, "room_shadow_off", room);
                write(cfg, "room_shadow_on", Scene3d.withPointShadows(roomShadows(), room));
                write(cfg, "room_units_legacy", room);
                write(cfg, "room_units_physical", physical);
                write(cfg, "room_units_physical_pi", brighter(Lighting.pi(), physical));
                write(cfg, "room_units_physical_pi_shadow", Scene3d.withPointShadows(roomShadows(), brighter(Lighting.pi(), physical)));
                List.forEach(k -> write(cfg, "room_units_physical_x${Int32.toString(k)}", Scene3d.withPointShadows(roomShadows(), brighter(Lighting.pi() * Int32.toFloat64(k), physical))), 2 :: 3 :: 4 :: 6 :: Nil)
        };
        let base = Lighting.defaultConfig();
        write(cfg, "lamps_shadow_off", Lighting.lampsScene(base, 2.0));
        write(cfg, "lamps_shadow_on", Lighting.lampsScene({ shadows = Some(lampShadows()) | base }, 2.0));
        write(cfg, "lamps_units_physical_pi", Lighting.lampsScene({ shadows = Some(lampShadows()), units = Scene3d.LightUnits.Physical, intensityScale = Lighting.pi() * 9.0 | base }, 2.0));
        write(cfg, "sun_caster_before", Lighting.lampsScene({ sun = true, lamps = 0 | base }, 2.0));
        write(cfg, "sun_caster_after", Lighting.lampsScene({ sun = true, lamps = 0, casterScale = Vec2.v2(0.6, 0.7) | base }, 2.0));
        write(cfg, "lamps_caster_before", Lighting.lampsScene({ shadows = Some(lampShadows()) | base }, 2.0));
        write(cfg, "lamps_caster_after", Lighting.lampsScene({ shadows = Some(lampShadows()), casterScale = Vec2.v2(0.6, 0.7) | base }, 2.0))

    /// 夜の街灯の動画のコマ（6 コマ / 秒で 8 秒・影なし / あり）。
    pub def frames(): Unit \ IO =
        let cfg = config();
        let base = Lighting.defaultConfig();
        List.range(0, 48) |> List.forEach(k -> {
            let t = Int32.toFloat64(k) / 6.0;
            HeadlessRender.renderPngSoft(cfg, Render.softSceneOf(_ -> None, Lighting.lampsItems(base, t)), "frames/off_${String.padLeft(3, '0', Int32.toString(k))}");
            HeadlessRender.renderPngSoft(cfg, Render.softSceneOf(_ -> None, Lighting.lampsItems({ shadows = Some(lampShadows()) | base }, t)),
                                         "frames/on_${String.padLeft(3, '0', Int32.toString(k))}")
        });
        println("[lighting] debug/lighting/frames/（off_ と on_ の 48 コマずつ）")
}
