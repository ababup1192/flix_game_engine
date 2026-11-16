// lightmap の場面（R2b・P8 の (5a)）: bench/scene3d の部屋の物に、絵つきの材質と lightmap（2 本目の uv で読む前もって計算した光の絵）を付けて GL と WebGPU で比べる。
// 2 本目の uv は 1 本目と同じ箱投影を部屋 1 つ分で 0..1 に収めた物（物ごとに lightmap の違う所を読む）。lightmap の絵は CPU で作る、明るさの坂と升目の濃淡。
mod V2Lightmaps {

    /// 部屋の 1 m（bench/scene3d の Room の長さの単位）。
    def meter(): Float64 = 16.0

    /// 横に明るさの坂・縦に色の坂を持ち、4 × 4 の升の 1 つおきを暗くした lightmap の絵（64 × 64）。
    def bakedTexture(): Texture3d.Texture3d =
        let n = 64;
        let px = Vector.range(0, n * n) |> Vector.map(i -> {
            let (x, y) = (Int32.remainder(i, n), i / n);
            let dim = if (Int32.remainder(x / 16 + y / 16, 2) == 0) 1.0 else 0.55;
            let level = (v: Float64) -> Int32.max(0, Int32.min(255, Num.floorInt(255.0 * dim * v)));
            V2Materials.opaque(level(0.35 + 0.65 * Int32.toFloat64(x) / 63.0), level(0.5 + 0.3 * Int32.toFloat64(y) / 63.0), level(0.9 - 0.5 * Int32.toFloat64(x) / 63.0))
        });
        match Texture3d.fromArgb(n, n, px) {
            case Ok(t)    => t
            case Err(why) => bug!("lightmap の絵を作れない: ${why}")
        }

    /// 形 mesh（箱投影の uv つき）に、1 本目の uv を部屋 1 つ分（32 m 四方）で 0..1 へ縮めた 2 本目の uv を付ける。
    def withRoomUvs2(mesh: Mesh3d.Mesh3d): Mesh3d.Mesh3d =
        let uvs = Mesh3d.uvs(mesh) |> Option.getWithDefault(Vector.empty());
        match Mesh3d.withUvs2(uvs |> Vector.map(u -> 0.5 + u / 32.0), mesh) {
            case Ok(m)    => m
            case Err(why) => bug!("2 本目の uv を付けられない: ${why}")
        }

    /// 部屋の置いた物を、箱投影の uv と 2 本目の uv・材質 material・lightmap lm に替えた場面（絵 textures と lightmap の絵を場面に載せる）。
    def withLightmap(room: Scene3d.Scene3dCmd, textures: List[Texture3d.Texture3d], material: Scene3d.Material3d, lm: Scene3d.Lightmap): Scene3d.Scene3dCmd =
        let restyle = (i: Scene3d.Instance3d) -> {
            let f = Scene3d.instanceFieldsOf(i);
            Scene3d.meshInstance(withRoomUvs2(Mesh3d.withBoxUvs(1.0 / meter(), f#mesh)), f#world)
                |> Scene3d.withTint(f#tint) |> Scene3d.withMaterial(material) |> Scene3d.withLightmap(lm)
        };
        { instances = List.map(restyle, room#instances), textures = textures | room }

    /// 絵つき（Linear）の材質に sRGB の lightmap（強さ 1.5）。
    pub def textured(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let t = V2Materials.colorTexture();
        let baked = bakedTexture();
        withLightmap(room, t :: baked :: Nil, Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Linear),
                     { intensity = 1.5 | Scene3d.lightmap(Texture3d.name(baked)) })

    /// 絵つきの材質に縞の法線マップを当て、線形の lightmap（強さ 2・段 2 まで）を付けた材質（絵の組が 材質の絵 → 法線マップ → lightmap の 3 つ）。
    pub def normalLinear(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let t = V2Materials.colorTexture();
        let n = V2Materials.stripes();
        let baked = bakedTexture();
        withLightmap(room, t :: n :: baked :: Nil,
                     Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Linear) |> Scene3d.withNormalMap({ texture = Texture3d.name(n), strength = 1.0 }),
                     { colorSpace = Texture3d.ColorSpace.Linear, intensity = 2.0, maxLevels = 2 | Scene3d.lightmap(Texture3d.name(baked)) })
}
