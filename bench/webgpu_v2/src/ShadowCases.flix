// 影の場面: bench/scene3d の部屋に影を落とすスポットを、殻を外した部屋の物と広い床に影を落とす太陽を足して GL と WebGPU で比べる。
// 影を落とす物は骨の無い家具・骨つきの人形（V2Skinned）・同じ形を多数並べた小物（instance）。受けるのは頂点の色の床と、絵つきの材質の物。
mod V2Shadows {

    /// 部屋の 1 m（bench/scene3d の Room の長さの単位）。
    def meter(): Float64 = 16.0

    /// 天井の近くから人形の格子の中ほどを照らす、影を落とすスポット。
    def spot(): Scene3d.SpotLight =
        let m = meter();
        { intensity = 3.0, range = 9.0 * m, color = Color.rgb(1.0, 0.95, 0.85),
          shadow = Some({ mapSize = 1024, bias = 0.0015, pcfRadius = 1, strength = 0.85 })
          | Scene3d.spotLight(Vec3.v3(3.2 * m, 2.7 * m, 2.6 * m), Vec3.v3(4.2 * m, 0.0, 4.4 * m), 1.6) }

    /// 奥の右上から手前へ差す太陽（影が目の側へ伸びる・影の地図 2048・PCF 1）。bias と distance は部屋の長さの単位（1 m = 16）。
    def sun(): Scene3d.DirectionalLight =
        let m = meter();
        { intensity = 1.1, color = Color.rgb(1.0, 0.96, 0.88),
          shadow = Some({ normalBias = 1.0, bias = 0.05 * m, distance = 14.0 * m, casterReach = 12.0 * m | Scene3d.directionalShadow() })
          | Scene3d.directionalLight(Vec3.v3(-0.5, -0.75, -0.6)) }

    /// 部屋に頂点の色の人形を足し、影を落とすスポットで照らした場面（受けるのは頂点の色の床と壁）。
    pub def spotRoom(kit: Room.Kit): Scene3d.Scene3dCmd =
        let room = V2Skinned.vertexColored(Room.scene(kit, 0.0));
        { spotLights = spot() :: Nil | room }

    /// spotRoom の部屋の物を絵つきの材質にし、絵つきの材質の人形を足した場面（影を受けるのは材質の物）。
    pub def spotRoomTextured(kit: Room.Kit): Scene3d.Scene3dCmd =
        let room = V2Skinned.textured(V2Materials.colorTexture(), V2Materials.textured(Room.scene(kit, 0.0)));
        { spotLights = spot() :: Nil | room }

    /// 殻（床・壁・天井）を外した部屋の物と頂点の色の人形を、広い市松の床の上に置いた場面（太陽が入る）。crowd = 足す小物の数（0 なら足さない）。
    pub def sunYard(kit: Room.Kit, crowd: Int32): Scene3d.Scene3dCmd =
        let room = Room.scene(kit, 0.0);
        let props = room#instances |> List.filter(i -> Scene3d.instanceFieldsOf(i)#name != "shell");
        let yard = { instances = Scene3d.meshInstance(floor(), Mat4.identity()) :: props, directionalLight = Some(sun()),
                     environment = { ambient = Color.rgb(0.1, 0.1, 0.12) | room#environment } | room };
        let withFigures = V2Skinned.vertexColored(yard);
        if (crowd > 0) V2Skinned.crowd(crowd, kit#torch, withFigures) else withFigures

    /// sunYard の物を絵つきの材質にした場面（人形は頂点の色のまま後から足す。影を受けるのは材質の床と家具）。
    pub def sunYardTextured(kit: Room.Kit): Scene3d.Scene3dCmd =
        let room = Room.scene(kit, 0.0);
        let props = room#instances |> List.filter(i -> Scene3d.instanceFieldsOf(i)#name != "shell");
        let yard = { instances = Scene3d.meshInstance(floor(), Mat4.identity()) :: props, directionalLight = Some(sun()),
                     environment = { ambient = Color.rgb(0.1, 0.1, 0.12) | room#environment } | room };
        V2Skinned.vertexColored(V2Materials.textured(yard))

    /// sunYard（小物なし）に影を落とすスポットも足した場面（1 つの場面に一辺の違う地図が 2 枚・色の pass が両方を読む）。
    pub def spotAndSun(kit: Room.Kit): Scene3d.Scene3dCmd =
        { spotLights = spot() :: Nil | sunYard(kit, 0) }

    /// 上を向く 1 m の市松の床（−4 m..12 m × −2 m..10 m）。
    def floor(): Mesh3d.Mesh3d =
        let m = meter();
        let tile = (i: Int32, j: Int32) -> {
            let x0 = Int32.toFloat64(i - 4) * m;
            let z0 = Int32.toFloat64(j - 2) * m;
            let c = if (Int32.modulo(i + j, 2) == 0) Color.rgb(0.62, 0.58, 0.52) else Color.rgb(0.5, 0.47, 0.43);
            ({ points = Vec3.v3(x0, 0.0, z0) :: Vec3.v3(x0, 0.0, z0 + m) :: Vec3.v3(x0 + m, 0.0, z0 + m) :: Vec3.v3(x0 + m, 0.0, z0) :: Nil, color = c }: Mesh3d.Polygon)
        };
        Mesh3d.fromPolygons(List.range(0, 16) |> List.flatMap(i -> List.range(0, 12) |> List.map(j -> tile(i, j))))
}
