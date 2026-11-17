// ドット絵のアトラスを Nearest で貼った床と壁（E4 の確かめ・門ではなく記録・probes）: 縮んだ所で隣のタイルの色が混ざるか・mip のレベルの切り替わりで縞が出るか。
// アトラスは 64 × 64（16 × 16 のタイル 4 × 4）。使うのは左上のタイル（草: 2 つの緑の 2 px の市松と 1 px の濃い粒）だけで、隣のタイルはどれも真っ赤と真っ青
// （混ざれば緑の中に赤紫が出る）。床と横の壁は 1 m に 1 タイル（32 テクセル / m の半分の密度 = 16）を、見下ろしのカメラと地面すれすれのカメラで撮る。
mod V2Atlas {

    /// アトラスの画素（ARGB）。左上のタイルが草・ほかは赤と青の互い違い。
    def atlasPixel(x: Int32, y: Int32): Int32 =
        let tx = x / 16;
        let ty = y / 16;
        if (tx == 0 and ty == 0) {
            let dark = Int32.remainder(x * 7 + y * 13, 11) == 0;
            if (dark) V2Materials.opaque(30, 70, 25)
            else if (Int32.remainder(x / 2 + y / 2, 2) == 0) V2Materials.opaque(90, 170, 60) else V2Materials.opaque(70, 140, 50)
        }
        else if (Int32.remainder(tx + ty, 2) == 0) V2Materials.opaque(250, 0, 0) else V2Materials.opaque(0, 0, 250)

    pub def atlas(): Texture3d.Texture3d =
        match Texture3d.fromArgb(64, 64, Vector.range(0, 64 * 64) |> Vector.map(i -> atlasPixel(Int32.remainder(i, 64), i / 64))) {
            case Ok(t)    => t
            case Err(why) => bug!("アトラスを作れない: ${why}")
        }

    /// 左上のタイルの uv（0..0.25）を貼った 1 m の四角（points は時計回り・uv は同じ順の角）。
    def tileQuad(p0: Vec3.Vec3, p1: Vec3.Vec3, p2: Vec3.Vec3, p3: Vec3.Vec3): Mesh3d.TexturedPolygon =
        { points = p0 :: p1 :: p2 :: p3 :: Nil, uvs = { x = 0.0, y = 0.25 } :: { x = 0.0, y = 0.0 } :: { x = 0.25, y = 0.0 } :: { x = 0.25, y = 0.25 } :: Nil,
          color = Color.rgb(1.0, 1.0, 1.0) }

    /// 床（x −12..12・z 0..60）と、右の横の壁（x = 3・z 2..40・高さ 3。カメラから見て横向きで、縮みが一番強い面）。
    def ground(): Mesh3d.Mesh3d =
        let v = Vec3.v3;
        let floor = List.range(-12, 12) |> List.flatMap(i -> List.range(0, 60) |> List.map(j -> {
            let x = Int32.toFloat64(i);
            let z = Int32.toFloat64(j);
            tileQuad(v(x, 0.0, z), v(x, 0.0, z + 1.0), v(x + 1.0, 0.0, z + 1.0), v(x + 1.0, 0.0, z))
        }));
        let wall = List.range(2, 40) |> List.flatMap(j -> List.range(0, 3) |> List.map(k -> {
            let z = Int32.toFloat64(j);
            let y = Int32.toFloat64(k);
            tileQuad(v(3.0, y, z + 1.0), v(3.0, y + 1.0, z + 1.0), v(3.0, y + 1.0, z), v(3.0, y, z))
        }));
        match Mesh3d.fromTexturedPolygons(List.append(floor, wall)) {
            case Ok(m)    => m
            case Err(why) => bug!("床を作れない: ${why}")
        }

    /// low が真なら地面すれすれ（目の高さ 1.2 m）・偽なら見下ろし（HD-2D の画角）。capped が真なら mip のレベルの数を 16 px のタイルの分（Scene3d.atlasMipLevelsFor）までにする。
    pub def yard(low: Bool, capped: Bool): Scene3d.Scene3dCmd =
        let tex = atlas();
        let camera = if (low) { eye = Vec3.v3(0.0, 1.2, -1.0), yaw = 0.0, pitch = 0.05, fovY = 1.0, near = 0.3, far = 100.0, lensShift = Vec2.zero() }
                     else { eye = Vec3.v3(0.0, 17.0, -14.0), yaw = 0.0, pitch = 0.7, fovY = 0.42, near = 1.0, far = 100.0, lensShift = Vec2.zero() };
        let material = Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest);
        let drawn = if (capped) material |> Scene3d.withMaxMipLevels(Scene3d.atlasMipLevelsFor(16)) else material;
        { instances = Scene3d.meshInstance(ground(), Mat4.identity()) |> Scene3d.withMaterial(drawn) :: Nil,
          textures = tex :: Nil,
          environment = { ambient = Color.rgb(1.0, 1.0, 1.0), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(Color.rgb(0.04, 0.04, 0.1)) }
          | Scene3d.scene(camera, Room.design()) }
}
