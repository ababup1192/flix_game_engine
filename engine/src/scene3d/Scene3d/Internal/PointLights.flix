// Scene3d.Internal.PointLights — 上限を超えた点光源・スポットライトの選び（Scene3d.pickLights の中身）。

/// 光の選びの中身。ゲームは呼ばない（Scene3d.pickLights を呼ぶ）。
pub mod Scene3d.Internal.PointLights {

    /// 点光源の選び（Scene3d.pickLights の doc の点光源の段）。上限以下なら cmd の並びのまま。
    pub def pickPointLights(cmd: Scene3d.Scene3dCmd): List[Scene3d.PointLight] =
        let limit = Scene3d.maxPointLights();
        if (List.length(cmd#pointLights) <= limit) cmd#pointLights
        else {
            let frustum = Scene3d.frustumOf(cmd);
            let ranked = List.zip(List.range(0, List.length(cmd#pointLights)), cmd#pointLights)
                |> List.filterMap(pair -> pointPickScoreOf(cmd#camera, Scene3d.aspectOf(cmd), frustum, snd(pair)) |> Option.map(score -> (score, pair)))
                |> Sort.sortStableBy(fst);
            let scores = ranked |> List.map(fst) |> List.toVector;
            ranked
                |> List.take(limit)
                |> List.map(entry -> {
                    let (score, (i, light)) = entry;
                    (i, { intensity = light#intensity * pointPickWeightOf(scores, limit, score) | light })
                })
                |> Sort.sortStableBy(fst)
                |> List.map(snd)
        }

    /// 点光源を選ぶ点数（小さいほど先に選ぶ）。選ばない光は None。
    /// 目が球の外: (画面の真ん中の向き（Camera3d.centerRayDirection）と光の中心の向きの間の角 − asin(range / 距離) + π/2 + 1) ÷ 球が視錐台へ入っている度合い。
    /// 目が球の中: (距離 / range) × (角 + 1) ÷ 度合いを 1 へ (1 − 距離 / range) だけ近づけた物。どちらも球の表面で同じ値になる。
    // WhyNot: 目からの距離で選ばない — 見下ろしの遠いカメラでは画面の下の端の光ばかり選ばれ、画面の真ん中から奥の光の溜まりが出ない。
    // WhyNot: 注目点を視線と地面の交点にしない — 場面に地面の高さの約束が無く、水平に見るカメラでは交わらない。
    // WhyNot: 視錐台に掛かるかだけで落とさない — 画面の端で光が出入りした瞬間に残りの順位がずれ、境の重みが跳ねる。度合いで割ると、
    //   出ていく光の点数は度合いが 0 へ近づくにつれて大きくなり、落ちる時には選ばれていない。
    // WhyNot: 目が球の中の光に向きの角をそのまま使わない — 手に持つ灯りが目の少し後ろへずれただけで最下位へ落ちる。
    //   度合いも、視錐台より大きな球は 0.5 から上がらないので、目の周りを照らす光ほど 1 へ近づける。
    // WhyNot: `+ π/2 + 1` を足さずに割らない — 角は負になりうるので、度合いで割って大きくするには分子を正にしておく。
    // WhyNot: `insideRatio <= 0.0` で落とさない — NaN の位置や range も落とす。
    pub def pointPickScoreOf(camera: Camera3d.Camera3d, aspect: Float64, frustum: Frustum.Frustum, light: Scene3d.PointLight): Option[Float64] =
        let insideRatio = Frustum.sphereInsideRatio(frustum, light#position, light#range);
        if (not (insideRatio > 0.0 and light#range > 0.0 and light#intensity > 0.0)) None
        else {
            let toLight = Vec3.sub(light#position, camera#eye);
            let dist = Vec3.length(toLight);
            let reach = light#range;
            let forward = Camera3d.centerRayDirection(camera, aspect);
            let centerAngle = Num.atan2(Vec3.length(Vec3.cross(forward, toLight)), Vec3.dot(forward, toLight));
            if (dist > reach)
                Some((centerAngle - Num.asin(reach / dist) + Num.pi() / 2.0 + 1.0) / insideRatio)
            else {
                let closeness = dist / reach;
                Some(closeness * (centerAngle + 1.0) / (insideRatio + (1.0 - insideRatio) * (1.0 - closeness)))
            }
        }

    /// 選んだ点光源 1 本の重み（0〜1）。scores = 候補の点数の小さい順・score = その光の点数・limit = 選ぶ本数。
    /// 選ばれない最初の光（limit + 1 番目）の点数で 0・pointFullRanks 番目の点数までは 1・その間はまっすぐつなぐ。候補が limit 本以下なら全部 1。
    // WhyNot: 点数の差が 0 の時に 1 か 0 へ分けない — 格子に並べた光を真ん中から見ると同点になりやすく、その 1 コマだけ光が消える。
    def pointPickWeightOf(scores: Vector[Float64], limit: Int32, score: Float64): Float64 =
        if (Vector.length(scores) <= limit) 1.0
        else {
            let cutoff = Vector.get(limit, scores);
            let full = Vector.get(pointFullRanks() - 1, scores);
            let weight = Num.clamp01((cutoff - score) / Float64.max(cutoff - full, 1.0e-6));
            if (Float64.isNan(weight)) 1.0 else weight
        }

    /// 点光源を 8 本を超えて渡した時に、元の強さのまま残す本数（その先の 7・8 本目が 9 本目へ向けて暗くなる）。
    // WhyNot: 選んだ全部を点数でなめらかに落とさない — 幅を広げると暗くなる光が増える。境の手前の 2 本だけを暗くする。
    def pointFullRanks(): Int32 = 6

    /// lights から eye に近い limit 本（同じ距離なら並びの前の物）を元の並びの順で返す。上限以下ならそのまま。
    pub def nearest(limit: Int32, eye: Vec3.Vec3, positionOf: a -> Vec3.Vec3, lights: List[a]): List[a] =
        if (List.length(lights) <= limit) lights
        else
            List.zip(List.range(0, List.length(lights)), lights)
                |> Sort.sortStableBy(pair -> Vec3.distanceSquared(positionOf(snd(pair)), eye))
                |> List.take(limit)
                |> Sort.sortStableBy(fst)
                |> List.map(snd)
}
