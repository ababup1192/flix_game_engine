// PsxRoom — 部屋を PS1 風の描き方（Scene3d.PsxLook）で描く場面（make run PSX=… と make psx-video が使う）。
// 部屋は Design の解像度（320×180）で描き、床に板目の絵を貼る（アフィンの uv の流れが見える）。
mod PsxRoom {
    use fge::{Color, Mat4, Mesh3d, Render, Scene3d, ShaderDoc, Texture3d, Vec2, Vec3}

    def meter(): Float64 = 16.0

    /// 字 → PS1 風の値。dither = 15 ビットの色と PS1 の表のディザ・full = dither に 1 画素の頂点の揺れと弱いアフィン・ほか = 切る。
    pub def lookOf(name: String): Scene3d.PsxLook = match name {
        case "dither" => { colorDepth = 5 | Scene3d.psxOff() }
        case "full"   => { colorDepth = 5, vertexSnap = 1.0, affineTextureMapping = 0.35 | Scene3d.psxOff() }
        case _        => Scene3d.psxOff()
    }

    /// 部屋の作り置きと床の絵（毎コマ作り直さない）。
    pub type alias Kit = { room = Room.Kit, floor = Scene3d.Instance3d, texture = Texture3d.Texture3d }

    pub def kitOf(room: Room.Kit): Kit =
        let tex = boardTexture();
        { room = room, floor = boardFloor(tex), texture = tex }

    /// 16 × 16 の板目（明るい板と暗い板が 4 texel 幅で縦に並び、板の継ぎ目の 1 texel が暗い）。
    def boardTexture(): Texture3d.Texture3d =
        let argb = (r: Int32, g: Int32, b: Int32) -> Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(r, 16), Int32.bitwiseOr(Int32.leftShift(g, 8), b)));
        let texel = (x: Int32, y: Int32) ->
            if (Int32.remainder(x, 4) == 3 or (y == Int32.remainder(x / 4 * 5, 16))) argb(40, 26, 18)
            else if (Int32.remainder(x / 4, 2) == 0) argb(150, 104, 66) else argb(118, 80, 50);
        match Texture3d.fromArgb(16, 16, Vector.range(0, 256) |> Vector.map(k -> texel(Int32.remainder(k, 16), k / 16))) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    /// 部屋の床（8 m × 6 m）より 1 cm 上の板目の床。1 m に絵 1 枚。
    def boardFloor(tex: Texture3d.Texture3d): Scene3d.Instance3d =
        let (w, d, y) = (8.0, 6.0, 0.01);
        let p = (x: Float64, z: Float64) -> Vec3.v3(x * meter(), y * meter(), z * meter());
        let mesh = match Mesh3d.fromTexturedPolygons({ points = p(0.0, 0.0) :: p(0.0, d) :: p(w, d) :: p(w, 0.0) :: Nil,
                                                      uvs = { x = 0.0, y = d } :: { x = 0.0, y = 0.0 } :: { x = w, y = 0.0 } :: { x = w, y = d } :: Nil,
                                                      color = Color.rgb(1.0, 1.0, 1.0) } :: Nil) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        };
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Nearest))

    /// 向き yaw の部屋を、板目の床を足して Design の解像度・PS1 風の値 look で描く描き物の列。
    pub def items(kit: Kit, look: Scene3d.PsxLook, yaw: Float64): List[Render.PlacedItem] =
        let base = Room.scene(kit#room, yaw);
        Render.scene3d(Vec2.zero(), { instances = kit#floor :: base#instances, textures = kit#texture :: Nil, resolution = Scene3d.Resolution.Design | base }
                                    |> Scene3d.withPsx(look)) :: Nil
}
