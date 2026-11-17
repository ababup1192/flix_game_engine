// 夜の町の街灯（点光源 24 本）を見下ろしのカメラで撮る場面: 描き手が 8 本（Scene3d.pickLights。画面の真ん中に近い順・境の近くは暗く）だけを
// 計算する決まりで、画面の真ん中から奥の光の溜まりが出るか・カメラを横へ動かしても光がぱっと切り替わらないかを見る（門ではなく記録・probes）。
// 街灯の頭は光を当てないビルボード（光が選ばれなくても位置が見える）。床は 1 m の市松。
mod V2Lamps {

    /// 街灯の並び（4 列 × 6 行 = 24 本。x は 4 m おき・z は 3 m おき・高さ 2.2 m）。
    pub def lampPositions(): List[Vec3.Vec3] =
        List.range(0, 4) |> List.flatMap(i -> List.range(0, 6) |> List.map(j ->
            Vec3.v3(-6.0 + 4.0 * Int32.toFloat64(i), 2.2, 1.0 + 3.0 * Int32.toFloat64(j))))

    def lamp(p: Vec3.Vec3): Scene3d.PointLight =
        { position = p, color = Color.rgb(1.0, 0.72, 0.4), intensity = 2.2, range = 3.6 }

    def head(p: Vec3.Vec3): Scene3d.Billboard3d =
        let side = Int32.toFloat64(RadialBuiltin.size());
        Scene3d.billboard(RadialBuiltin.lightName(), { position = { x = 0.0, y = 0.0 }, size = { x = side, y = side } }, p, { x = 0.6, y = 0.6 })
            |> Scene3d.withAnchor({ x = 0.5, y = 0.5 }) |> Scene3d.withBillboardTint(Color.rgb(1.0, 0.85, 0.6)) |> Scene3d.unlit

    def up(x0: Float64, x1: Float64, z0: Float64, z1: Float64, c: Color): Mesh3d.Polygon =
        { points = Vec3.v3(x0, 0.0, z0) :: Vec3.v3(x0, 0.0, z1) :: Vec3.v3(x1, 0.0, z1) :: Vec3.v3(x1, 0.0, z0) :: Nil, color = c }

    /// 市松の床（x −10..10・z −4..20）。
    def floor(): Scene3d.Instance3d =
        let tile = (i: Int32, j: Int32) -> {
            let x0 = Int32.toFloat64(i - 10);
            let z0 = Int32.toFloat64(j - 4);
            up(x0, x0 + 1.0, z0, z0 + 1.0, if (Int32.modulo(i + j, 2) == 0) Color.rgb(0.62, 0.6, 0.58) else Color.rgb(0.5, 0.48, 0.47))
        };
        Scene3d.meshInstance(Mesh3d.fromPolygons(List.range(0, 20) |> List.flatMap(i -> List.range(0, 24) |> List.map(j -> tile(i, j)))), Mat4.identity())

    /// カメラを x へ dx だけずらした夜の町（大きさ size）。
    pub def night(dx: Float64, size: Vec2.Vec2): Scene3d.Scene3dCmd =
        let camera = { eye = Vec3.v3(dx, 13.0, -9.0), yaw = 0.0, pitch = 0.82, fovY = 0.75, near = 1.0, far = 80.0 };
        let base = Scene3d.scene(camera, size);
        { instances = floor() :: Nil, pointLights = lampPositions() |> List.map(lamp), billboards = lampPositions() |> List.map(head),
          environment = { ambient = Color.rgb(0.08, 0.09, 0.16), hemisphere = 0.0, toonSteps = 0, fog = None, background = Some(Color.rgb(0.02, 0.02, 0.05)) }
          | base }
}
