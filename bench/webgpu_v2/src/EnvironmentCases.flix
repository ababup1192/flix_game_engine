// 環境マップと mip の場面（R2b・P8 の (7b)）: 金色の球を metallic × roughness の格子に並べ、正距円筒のパノラマ（bench/gl_parity の pbrEnvironment3d と同じ絵）を映して
// GL と WebGPU で比べる。roughness が mip のレベルを選ぶので、パノラマの mip（128 × 64 から 8 レベル・CPU の Mip.build）の全部を読む。
// 景色を背景に描く場面は目の正面（+z）に絵の継ぎ目（u = 0 と 1）が来る。mip の場面は、細かい市松を貼った長い床を浅い角度で見る（遠くほど上の mip のレベルを読む）。
mod V2Environment {

    /// 8bit の値そのままの色（k / 255）。
    def c8(r: Int32, g: Int32, b: Int32): Color = Color.rgb(Int32.toFloat64(r) / 255.0, Int32.toFloat64(g) / 255.0, Int32.toFloat64(b) / 255.0)

    /// 横 128・縦 64 のパノラマ。上半分は青の空・下半分は茶の床・地平の 8 行は赤と黄の縦縞・南（絵の真ん中）の上に白い四角（bench/gl_parity の parityPanorama と同じ）。
    pub def panorama(): Texture3d.Texture3d =
        let texel = (x: Int32, y: Int32) ->
            if (x >= 56 and x < 72 and y >= 14 and y < 26) V2Materials.opaque(255, 255, 255)
            else if (y >= 28 and y < 36) (if (Int32.remainder(x / 8, 2) == 0) V2Materials.opaque(220, 60, 50) else V2Materials.opaque(240, 210, 70))
            else if (y < 32) V2Materials.opaque(70, 110 + y * 2, 200)
            else V2Materials.opaque(110 - (y - 32), 80 - (y - 32) / 2, 50);
        match Texture3d.fromArgb(128, 64, Vector.range(0, 128 * 64) |> Vector.map(k -> texel(Int32.remainder(k, 128), k / 128))) {
            case Ok(t)    => t
            case Err(why) => bug!("パノラマの絵を作れない: ${why}")
        }

    /// 半径 1 の球（緯度 14・経度 20 の分割・法線は位置と同じ向き・外から見て時計回り。bench/gl_parity の sphereMesh と同じ形）。
    def sphere(): Mesh3d.Mesh3d =
        let rings = 14;
        let segments = 20;
        let point = (i: Int32, j: Int32) -> {
            let theta = Num.pi() * Int32.toFloat64(i) / Int32.toFloat64(rings);
            let phi = 2.0 * Num.pi() * Int32.toFloat64(j) / Int32.toFloat64(segments);
            Vec3.v3(Num.sin(theta) * Num.cos(phi), Num.cos(theta), Num.sin(theta) * Num.sin(phi))
        };
        let index = (i: Int32, j: Int32) -> i * (segments + 1) + j;
        let vertices = List.range(0, rings + 1) |> List.flatMap(i -> List.range(0, segments + 1) |> List.map(j -> point(i, j))) |> List.toVector;
        let coords = vertices |> Vector.flatMap(v -> Vector#{v#x, v#y, v#z});
        let facing = (a: Int32, b: Int32, c: Int32) -> {
            let (va, vb, vc) = (Vector.get(a, vertices), Vector.get(b, vertices), Vector.get(c, vertices));
            let outward = Vec3.dot(Vec3.cross(Vec3.sub(vb, va), Vec3.sub(vc, va)), Vec3.add(va, Vec3.add(vb, vc)));
            if (outward >= 0.0) a :: b :: c :: Nil else a :: c :: b :: Nil
        };
        let triangles = List.range(0, rings) |> List.flatMap(i -> List.range(0, segments) |> List.flatMap(j ->
            List.append(facing(index(i, j), index(i, j + 1), index(i + 1, j)), facing(index(i, j + 1), index(i + 1, j + 1), index(i + 1, j)))));
        match Mesh3d.fromArrays({ positions = coords, normals = coords, colors = vertices |> Vector.flatMap(_ -> Vector#{1.0, 1.0, 1.0}),
                                  indices = List.toVector(triangles), skin = None }) {
            case Ok(mesh) => mesh
            case Err(why) => bug!("球を作れない: ${why}")
        }

    /// 金色の球を metallic（左から 0・0.5・1）× roughness（上から 0.1・0.4・0.7・1）で 3 列 × 4 行に並べた置いた物。
    def spheres(): List[Scene3d.Instance3d] =
        let gold = Scene3d.material({ name = "v2:env:gold", cycleRate = 0.0, bindings = Nil,
                                      out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c8(230, 180, 70)), alpha = ShaderDoc.Field.Const(1.0) }) });
        let ball = sphere();
        List.range(0, 4) |> List.flatMap(row -> List.range(0, 3) |> List.map(column -> {
            let roughness = Vector.get(row, Vector#{0.1, 0.4, 0.7, 1.0});
            let world = Mat4.mul(Mat4.translate(Vec3.v3((Int32.toFloat64(column) - 1.0) * 2.2, (1.5 - Int32.toFloat64(row)) * 2.0, 14.0)),
                                 Mat4.scale(Vec3.v3(0.85, 0.85, 0.85)));
            Scene3d.meshInstance(ball, world) |> Scene3d.withMaterial(gold |> Scene3d.withMetallicRoughness(Int32.toFloat64(column) * 0.5, roughness))
        }))

    /// 球の格子を点光源とスポットで照らし、環境マップ env を付けた場面（地の色は暗い紺）。yaw・pitch = 目の向き。
    pub def scene(env: Scene3d.EnvironmentMap, yaw: Float64, pitch: Float64): Scene3d.Scene3dCmd =
        let camera = { eye = Vec3.zero(), yaw = yaw, pitch = pitch, fovY = 1.0, near = 0.5, far = 100.0 };
        { instances = spheres(), textures = panorama() :: Nil, environmentMap = Some(env),
          pointLights = { position = Vec3.v3(-6.0, 6.0, 6.0), color = c8(255, 240, 220), intensity = 1.6, range = 40.0 } :: Nil,
          spotLights = { color = c8(200, 220, 255), intensity = 1.2, range = 40.0 | Scene3d.spotLight(Vec3.v3(7.0, 4.0, 5.0), Vec3.v3(0.0, 0.0, 14.0), 1.2) } :: Nil,
          environment = { ambient = c8(60, 60, 70), hemisphere = 0.2, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
          | Scene3d.scene(camera, Room.design()) }

    /// 箱なし・強さ 1・背景に描かない環境マップ。
    pub def plain(): Scene3d.EnvironmentMap = Scene3d.environmentMap(panorama())

    /// 球の周りの部屋（12 × 10 × 12）の箱で補正する・強さ 0.8。
    pub def boxed(): Scene3d.EnvironmentMap =
        let box = { min = Vec3.v3(-6.0, -5.0, 8.0), max = Vec3.v3(6.0, 5.0, 20.0), center = Vec3.v3(0.0, 0.0, 14.0) };
        Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentBox(box) |> Scene3d.withEnvironmentIntensity(0.8)

    /// 景色を背景にも描く・強さ 0.9。
    pub def background(): Scene3d.EnvironmentMap =
        Scene3d.environmentMap(panorama()) |> Scene3d.withEnvironmentAsBackground(true) |> Scene3d.withEnvironmentIntensity(0.9)

    /// 細かい市松（256 × 256・1 升 4 画素）を、uv を 4 m で 1 回の繰り返しにして貼った長い床（幅 16 m・奥行き 60 m）を、目の高さ 1.5 m から浅い角度で見る場面。
    /// name = 材質が読む絵の名前（場面の絵か全体の登録の絵）・textures = 場面に載せる絵。
    pub def mipFloor(name: String, textures: List[Texture3d.Texture3d]): Scene3d.Scene3dCmd =
        let plane = Mesh3d.fromPolygons({ points = Vec3.v3(-8.0, 0.0, 1.0) :: Vec3.v3(-8.0, 0.0, 61.0) :: Vec3.v3(8.0, 0.0, 61.0) :: Vec3.v3(8.0, 0.0, 1.0) :: Nil,
                                          color = Color.rgb(1.0, 1.0, 1.0) } :: Nil) |> Mesh3d.withBoxUvs(0.25);
        let camera = { eye = Vec3.v3(0.0, 1.5, 0.0), yaw = 0.0, pitch = 0.12, fovY = 1.0, near = 0.5, far = 100.0 };
        { instances = Scene3d.meshInstance(plane, Mat4.identity()) |> Scene3d.withMaterial(Scene3d.texturedMaterial(name, ShaderDoc.FilterMode.Linear)) :: Nil,
          textures = textures,
          environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(c8(10, 10, 30)) }
          | Scene3d.scene(camera, Room.design()) }

    /// mipFloor の市松（白と濃い青）。
    pub def fineChecker(): Texture3d.Texture3d =
        let n = 256;
        let px = Vector.range(0, n * n) |> Vector.map(i -> if (Int32.remainder(i / 4 + (i / n) / 4, 2) == 0) V2Materials.opaque(240, 240, 240) else V2Materials.opaque(30, 40, 110));
        match Texture3d.fromArgb(n, n, px) {
            case Ok(t)    => t
            case Err(why) => bug!("市松の絵を作れない: ${why}")
        }
}
