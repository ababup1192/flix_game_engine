// 材質の場面（R2b・P8 の (2)）: bench/scene3d の部屋の物に、場面の絵（Texture3d）を貼った材質を付けて GL と WebGPU で比べる。
// 形は箱投影の uv（Mesh3d.withBoxUvs）にし、絵は CPU で作る市松（色の絵・cutout の穴あきの絵・法線マップの縞）。
mod V2Materials {

    /// 部屋の 1 m（bench/scene3d の Room の長さの単位）。
    def meter(): Float64 = 16.0

    /// 市松の絵（cells × cells の升・1 升 side 画素）。hole = 偶数の升を透明にする。
    def checker(cells: Int32, side: Int32, a: Int32, b: Int32, hole: Bool): Texture3d.Texture3d =
        let n = cells * side;
        let px = Vector.range(0, n * n) |> Vector.map(i -> {
            let even = Int32.remainder(i / side + (i / n) / side, 2) == 0;
            if (even and hole) 0 else if (even) a else b
        });
        match Texture3d.fromArgb(n, n, px) {
            case Ok(t)    => t
            case Err(why) => bug!("市松の絵を作れない: ${why}")
        }

    /// 横縞の法線マップ（緑が上・明るい行と暗い行で傾きを交互に）。
    def stripes(): Texture3d.Texture3d =
        let n = 32;
        let px = Vector.range(0, n * n) |> Vector.map(i -> if (Int32.remainder(i / n / 4, 2) == 0) opaque(128, 192, 255) else opaque(128, 64, 255));
        match Texture3d.fromArgb(n, n, px) {
            case Ok(t)    => t
            case Err(why) => bug!("縞の絵を作れない: ${why}")
        }

    /// 不透明の ARGB（0〜255 の r・g・b）。
    def opaque(r: Int32, g: Int32, b: Int32): Int32 =
        Int32.bitwiseOr(Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(r, 16)), Int32.leftShift(g, 8)), b)

    def colorTexture():Texture3d.Texture3d = checker(8, 8, opaque(208, 160, 96), opaque(64, 96, 128), false)

    def holeTexture(): Texture3d.Texture3d = checker(6, 8, opaque(224, 224, 224), opaque(192, 64, 64), true)

    /// 部屋の置いた物を、箱投影の uv と材質 material に替えた場面（絵 textures を場面に載せる）。
    def withMaterial(room: Scene3d.Scene3dCmd, textures: List[Texture3d.Texture3d], material: Scene3d.Material3d): Scene3d.Scene3dCmd =
        liftedWithMaterial(0.0, room, textures, material)

    /// withMaterial の、殻（shell）でない物を lift だけ上へずらす版。
    def liftedWithMaterial(lift: Float64, room: Scene3d.Scene3dCmd, textures: List[Texture3d.Texture3d], material: Scene3d.Material3d): Scene3d.Scene3dCmd =
        let restyle = (i: Scene3d.Instance3d) -> {
            let f = Scene3d.instanceFieldsOf(i);
            let world = if (f#name == "shell") f#world else Mat4.mul(Mat4.translate(Vec3.v3(0.0, lift, 0.0)), f#world);
            Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0 / meter(), f#mesh), world) |> Scene3d.withTint(f#tint) |> Scene3d.withMaterial(material)
        };
        { instances = List.map(restyle, room#instances), textures = textures | room }

    /// 絵つき（Linear）の材質。
    pub def textured(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let t = colorTexture();
        withMaterial(room, t :: Nil, Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Linear))

    /// 穴あきの絵を Nearest で読む cutout の材質（片面）。
    pub def cutout(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let t = holeTexture();
        withMaterial(room, t :: Nil, Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest) |> Scene3d.withCutout(true))

    /// 穴あきの cutout を両面にした材質（穴から物の裏の面が見える）。殻でない物は床から 3 cm 浮かせる。
    // WhyNot: 敷物と家具の足を床に接したままにしない — 両面にすると敷物の裏の面が床と同じ高さで勝ち負けを争い、奥行きの丸めの差だけで千 px の桁が動いて、
    //   両面の道を取り違えた差と見分けられなくなる。
    pub def twoSided(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let t = holeTexture();
        liftedWithMaterial(0.03 * meter(), room, t :: Nil, Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest) |> Scene3d.withCutout(true) |> Scene3d.withDoubleSided(true))

    /// 色を Param（r・g・b）で受ける材質の Spec（params が違う物は別の行になる）。
    def paramSpec(): ShaderDoc.Spec =
        let p = (n: String) -> ShaderDoc.Field.Param({ name = n });
        { name = "v2:param", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = p("r"), g = p("g"), b = p("b") }), alpha = ShaderDoc.Field.Const(1.0) }) }

    /// 部屋に、params だけが違う材質の小物を count 個（格子に）足した場面（材質の行が count 本を超える・値の binding の比べ）。
    pub def manyMaterials(count: Int32, piece: Mesh3d.Mesh3d, room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let place = (i: Int32) -> {
            let (col, row) = (Int32.remainder(i, 20), i / 20);
            let at = Vec3.v3((1.0 + 0.3 * Int32.toFloat64(col)) * meter(), (0.3 + 0.2 * Int32.toFloat64(row)) * meter(), 6.0 * meter());
            let tone = Int32.toFloat64(i) / Int32.toFloat64(Int32.max(1, count));
            Scene3d.meshInstance(piece, Mat4.translate(at))
                |> Scene3d.withMaterial(Scene3d.material(paramSpec()) |> Scene3d.withParams(Map#{"r" => tone, "g" => 1.0 - tone, "b" => 0.5}))
        };
        { instances = List.append(room#instances, List.range(0, count) |> List.map(place)) | room }

    /// 絵つきの材質に縞の法線マップを当てた材質。
    pub def normalMapped(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let t = colorTexture();
        let n = stripes();
        withMaterial(room, t :: n :: Nil, Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Linear)
                                         |> Scene3d.withNormalMap({ texture = Texture3d.name(n), strength = 1.0 }))
}
