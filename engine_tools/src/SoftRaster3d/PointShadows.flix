// SoftRaster3d.PointShadows — CPU の描き手（SoftRaster3d）の点光源の影（面ごとの地図と、画素ごとの影の割合）。約束は Scene3d.PointShadows.atlasOf の doc。
mod SoftRaster3d.PointShadows {
    use SoftRaster3d.{LightEye, Placed, Projection}

    /// 場面の点光源の影。atlas の値と、点光源の番号（pickLights の後の並び・maxPointLights() 個）ごとの影を落とす灯りと面 6 枚の地図（影を落とさない灯りは None）。
    /// 面の地図は tileSize × tileSize（行 0 が ndc.y = −1 側）で、atlas の塊の 1 面と同じ画素の並び。
    pub enum Set {
        case Set(Scene3d.PointShadows.Atlas, Vector[Option[(Scene3d.PointShadows.ShadowedPointLight, Vector[Vector[Float64]])]])
    }

    /// 影の割合がどの灯りも 1 の並び（影の無い場面は画素ごとに作らずこれを使い回す）。
    pub def allLit(): Vector[Float64] = Vector.repeat(Scene3d.maxPointLights(), 1.0)

    /// 場面（pickLights の後）の点光源の影の地図を描く（影が無ければ None）。instances = 影を落とす不透明の物・
    /// textureOf = ビルボードの絵の名前 → 段 0 の絵（castShadows のビルボードを光の方へ向けて描く）。
    pub def build(instances: List[Placed], textureOf: String -> Option[ShaderEval.TexData], scene: Scene3d.Scene3dCmd): Option[Set] \ IO =
        Scene3d.PointShadows.atlasOf(scene) |> Option.map(atlas -> {
            let maps = atlas#lights |> List.map(light -> {
                let casters = Scene3d.PointShadows.castingBillboardsOf(scene, light)
                    |> List.filterMap(pair -> { let (f, right) = pair; textureOf(f#texture) |> Option.map(tex -> (f, tex, right)) });
                (light#pointIndex, (light, facesOf(instances, casters, atlas, light)))
            }) |> List.toMap;
            Set.Set(atlas, Vector.range(0, Scene3d.maxPointLights()) |> Vector.map(i -> Map.get(i, maps)))
        })

    def facesOf(instances: List[Placed], casters: List[(Scene3d.BillboardFields, ShaderEval.TexData, Vec3.Vec3)],
                atlas: Scene3d.PointShadows.Atlas, light: Scene3d.PointShadows.ShadowedPointLight): Vector[Vector[Float64]] \ IO =
        let billboards = { casters = casters, basis = { right = Vec3.v3(1.0, 0.0, 0.0), up = Vec3.v3(0.0, 1.0, 0.0), facing = Vec3.v3(0.0, 0.0, -1.0) } };
        Vector.range(0, 6) |> Vector.map(face -> {
            let eye: LightEye = { view = Scene3d.PointShadows.faceViewOf(light#position, face),
                                  proj = Scene3d.PointShadows.faceProjectionOf(light#near, light#far, atlas#guardScale),
                                  projection = Projection.Perspective(light#near) };
            SoftRaster3d.ShadowMaps.buildShadowMap(instances, billboards, eye, Vector.get(face, light#frustums), atlas#tileSize)
        })

    /// 点 p（g = 形の法線・n = 光の計算の法線）で、点光源の番号ごとの影の割合（maxPointLights() 個。影を落とさない・光が届かない・面が背を向けた灯りは 1）。
    pub def litAt(set: Option[Set], p: Vec3.Vec3, g: Vec3.Vec3, n: Vec3.Vec3): Vector[Float64] = match set {
        case None => allLit()
        case Some(Set.Set(atlas, lights)) => Vector.map(entry -> litOf(atlas, entry, p, g, n), lights)
    }

    def litOf(atlas: Scene3d.PointShadows.Atlas, entry: Option[(Scene3d.PointShadows.ShadowedPointLight, Vector[Vector[Float64]])],
              p: Vec3.Vec3, g: Vec3.Vec3, n: Vec3.Vec3): Float64 = match entry {
        case None => 1.0
        case Some((light, faces)) =>
            if (not Scene3d.PointShadows.isSampled(light, p, n)) 1.0
            else Scene3d.PointShadows.sampleOf(atlas, light, p, g) |> Option.map(s -> {
                let r = atlas#pcfRadius;
                let side = 2 * r + 1;
                let lit = SoftRaster3d.Internal.countLit(Vector.get(s#face, faces), atlas#tileSize, s#x - r, s#y - r, side, s#ref, 0, 0);
                1.0 - light#strength * (1.0 - Int32.toFloat64(lit) / Int32.toFloat64(side * side))
            }) |> Option.getWithDefault(1.0)
    }

    /// lights に場面の点光源の影と光の量の読み方（Physical か・1 / max(unitsPerMeter², 1e−12)。GL の uniform と同じ値）を入れた物。
    pub def withSceneLighting(points: Option[Set], scene: Scene3d.Scene3dCmd, lights: SoftRaster3d.Lights): SoftRaster3d.Lights =
        let SoftRaster3d.Lights.Lights(ar, ag, ab, hemi, steps, packedPoints, spots, shadow, sun, _, ones, _, _) = lights;
        let physical = if (scene#lightUnits == Scene3d.LightUnits.Physical) 1.0 else 0.0;
        let upm = scene#unitsPerMeter;
        SoftRaster3d.Lights.Lights(ar, ag, ab, hemi, steps, packedPoints, spots, shadow, sun, points, ones, physical, 1.0 / Float64.max(upm * upm, 1.0e-12))

    /// どの点光源も影の割合 1 の並び（ビルボード）。
    pub def unshadowedPointsOf(lights: SoftRaster3d.Lights): Vector[Float64] =
        let SoftRaster3d.Lights.Lights(_, _, _, _, _, _, _, _, _, _, ones, _, _) = lights;
        ones

    /// 点 p（g = 形の法線・n = 光の計算の法線）の点光源ごとの影の割合（影の無い場面は全部 1 の並びを使い回す）。
    pub def pointLitOf(lights: SoftRaster3d.Lights, p: (Float64, Float64, Float64), g: Vec3.Vec3, n: Vec3.Vec3): Vector[Float64] =
        let SoftRaster3d.Lights.Lights(_, _, _, _, _, _, _, _, _, points, ones, _, _) = lights;
        match points {
            case None => ones
            case Some(_) =>
                let (px, py, pz) = p;
                litAt(points, Vec3.v3(px, py, pz), g, n)
        }
}
