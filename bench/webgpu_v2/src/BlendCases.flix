// 半透明の場面（R2b・P8 の (6a)）: bench/scene3d の部屋の手前に、色の違う半透明の板を奥行きをずらして重ね、GL と WebGPU で比べる。
// 板は目に近い物から置く（来た順のまま描くと重なりの色が変わる＝計画の遠い順の並べ替えが効く）。1 枚は他の板と交わる向きに立て（深度を書くと欠ける）、
// 半透明の燭台の形（片面・裏を間引く）も 1 つ混ぜる。
mod V2Blend {

    /// 部屋の 1 m（bench/scene3d の Room の長さの単位）。
    def meter(): Float64 = 16.0

    /// 色 c・不透明さ alpha の半透明の材質（名前 name）。両面なら doubleSided。
    def glass(name: String, c: Color, alpha: Float64, doubleSided: Bool): Scene3d.Material3d =
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(c), alpha = ShaderDoc.Field.Const(alpha) }) })
            |> Scene3d.withAlphaBlend(true) |> Scene3d.withDoubleSided(doubleSided)

    /// 縦の板（幅 w・高さ h の m・x の中心 cx・床から y0・奥行き z の m）。
    def pane(cx: Float64, y0: Float64, z: Float64, w: Float64, h: Float64): Mesh3d.Mesh3d =
        let p = (x: Float64, y: Float64) -> Vec3.v3(x * meter(), y * meter(), z * meter());
        Mesh3d.fromPolygons({ points = p(cx - 0.5 * w, y0) :: p(cx - 0.5 * w, y0 + h) :: p(cx + 0.5 * w, y0 + h) :: p(cx + 0.5 * w, y0) :: Nil,
                              color = Color.rgb(1.0, 1.0, 1.0) } :: Nil)

    /// 奥行きの向き（z）に沿って立てた板（他の板と交わる）。
    def crossPane(x: Float64, y0: Float64, z0: Float64, d: Float64, h: Float64): Mesh3d.Mesh3d =
        let p = (y: Float64, z: Float64) -> Vec3.v3(x * meter(), y * meter(), z * meter());
        Mesh3d.fromPolygons({ points = p(y0, z0) :: p(y0 + h, z0) :: p(y0 + h, z0 + d) :: p(y0, z0 + d) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil)

    /// 半透明の物（目に近い物から並べる）。
    def glasses(kit: Room.Kit): List[Scene3d.Instance3d] =
        let at = (mesh: Mesh3d.Mesh3d, m: Scene3d.Material3d) -> Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(m);
        at(pane(3.4, 1.0, 2.2, 1.2, 1.0), glass("v2:glass:red", Color.rgb(0.95, 0.2, 0.15), 0.5, true)) ::
        at(pane(4.1, 0.9, 3.0, 1.3, 1.1), glass("v2:glass:green", Color.rgb(0.2, 0.85, 0.3), 0.55, true)) ::
        at(crossPane(3.0, 0.9, 1.8, 2.4, 1.4), glass("v2:glass:blue", Color.rgb(0.2, 0.35, 0.95), 0.45, true)) ::
        (Scene3d.meshInstance(kit#torch, Mat4.translate(Vec3.v3(4.4 * meter(), 1.2 * meter(), 2.7 * meter())))
            |> Scene3d.withMaterial(glass("v2:glass:amber", Color.rgb(0.95, 0.7, 0.2), 0.6, false))) ::
        at(pane(4.3, 1.3, 4.2, 2.0, 1.2), glass("v2:glass:white", Color.rgb(0.9, 0.9, 0.95), 0.35, true)) :: Nil

    /// 部屋（正面）の手前に半透明の物を足した場面。
    pub def room(kit: Room.Kit): Scene3d.Scene3dCmd =
        let r = Room.scene(kit, 0.0);
        { instances = List.append(r#instances, glasses(kit)) | r }
}
