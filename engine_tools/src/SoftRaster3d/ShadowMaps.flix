// SoftRaster3d.ShadowMaps — CPU の描き手（SoftRaster3d）の影の地図を作る所（スポットの地図・太陽の地図と、そこへ描く castShadows のビルボード）。約束は SoftRaster3d の頭。
mod SoftRaster3d.ShadowMaps {
    use SoftRaster3d.{LightEye, Mat, Placed, Projection, SpotShadow, billboardQuadTris, binRows, coverRow, forEachRow, hoist, inkOf, instanceTris, rowMajorOf, spotShadowOf}

    /// spots（pickLights の後の並び）のうち shadow が Some の最初の 1 本の地図。mapSize が 0 以下なら影を落とさない。
    pub def shadowOf(instances: List[Placed], spots: List[Scene3d.SpotLight]): SpotShadow \ IO =
        let caster = List.zipWithIndex(spots) |> List.findMap(entry -> {
            let (index, spot) = entry;
            spot#shadow |> Option.filter(sm -> sm#mapSize > 0) |> Option.map(sm -> (index, spot, sm))
        });
        match caster {
            case None => None
            case Some((index, spot, sm)) =>
                let rows = rowMajorOf(Scene3d.shadowMatrix(spot));
                let size = Int32.min(sm#mapSize, Scene3d.maxShadowMapSize());
                let pcf = Int32.min(sm#pcfRadius, Scene3d.maxShadowPcfRadius());
                let cam = Scene3d.shadowCamera(spot);
                let eye = { view = Camera3d.viewMatrix(cam), proj = Camera3d.projectionMatrix(cam, 1.0), projection = Projection.Perspective(cam#near) };
                let map = buildShadowMap(instances, noBillboards(), eye, Scene3d.shadowFrustumOf(spot), size);
                spotShadowOf(index * LightModel3d.spotStride(), rows, size, Scene3d.spotShadowDepthBiasOf(spot, sm#bias), pcf, sm#strength, map)
        }

    /// 場面の太陽（Scene3d.directionalLightOf）と、その影の地図（Scene3d.directionalShadowOf の箱で、影を落とす物から作る）。
    /// textureOf = ビルボードの絵の名前 → 段 0 の絵（castShadows のビルボードを影の地図に描く）。
    pub def sunOf(instances: List[Placed], textureOf: String -> Option[ShaderEval.TexData], scene: Scene3d.Scene3dCmd): SoftRaster3d.Sun.Light \ IO =
        let light = Scene3d.directionalLightOf(scene);
        let shadow = Scene3d.directionalShadowOf(scene) |> Option.map(setup -> {
            let eye = { view = Mat4.identity(), proj = setup#matrix, projection = Projection.Orthographic };
            let toward = light |> Option.map(l -> Scene3d.sunTermsOf(l)#toward) |> Option.getWithDefault(Vec3.v3(0.0, 1.0, 0.0));
            let right = Scene3d.billboardShadowRightOfScene(scene);
            let casters = Scene3d.shadowCastingBillboardsOf(setup#frustum, scene) |> List.filterMap(f -> textureOf(f#texture) |> Option.map(tex -> (f, tex, right)));
            let basis = { right = right, up = Vec3.v3(0.0, 1.0, 0.0), facing = toward };
            SoftRaster3d.Sun.shadowOf(setup, scene#camera#eye, buildShadowMap(instances, { casters = casters, basis = basis }, eye, setup#frustum, setup#mapSize))
        });
        SoftRaster3d.Sun.of(light, shadow)

    /// 影の地図に描くビルボード（中身と段 0 の絵と板の横の向き）と、その板の縦と前の向き（basis の right は使わず、板ごとの横の向きを使う）。
    pub type alias BillboardCasters = { casters = List[(Scene3d.BillboardFields, ShaderEval.TexData, Vec3.Vec3)], basis = { right = Vec3.Vec3, up = Vec3.Vec3, facing = Vec3.Vec3 } }

    pub def noBillboards(): BillboardCasters = { casters = Nil, basis = { right = Vec3.v3(1.0, 0.0, 0.0), up = Vec3.v3(0.0, 1.0, 0.0), facing = Vec3.v3(0.0, 0.0, -1.0) } }

    /// 光から見た n × n の地図（一番近い面の NDC の z × 0.5 + 0.5。何も無い画素は 1。行 0 が NDC の y = −1 側）。
    /// eye =光の目（view → proj の順に掛ける。正射影の光は view を単位行列にして proj に world → clip の行列を渡してよい）・
    /// frustum = 影を落とす物の間引き（目に見えない物も影は落とす）。スポットと平行光源で共有する。
    /// billboards = 地図に描くビルボード（板の向きは billboards#basis・絵の α が billboardCutoff() 未満の画素は捨てる。間引きは呼ぶ側が済ませる）。
    // WhyNot: 裏の面を捨てない — 薄い板や片面だけの物は、光へ裏を向けていても影を落としてほしい。
    // WhyNot: cutout の材質の α を見ない — 材質を画素ごとに評価すると地図が場面の塗りと同じくらい重くなる。抜いた穴の影は今は埋まる。
    pub def buildShadowMap(instances: List[Placed], billboards: BillboardCasters, eye: LightEye, frustum: Frustum.Frustum, n: Int32): Vector[Float64] \ IO = region rc {
        let view = eye#view;
        let proj = eye#proj;
        let screen = { w = Int32.toFloat64(n), h = Int32.toFloat64(n), projection = eye#projection, vertexSnap = 0.0, affine = 0.0 };
        let meshTris = instances |> List.filter(f -> not Scene3d.isOutsideFrustumFields(frustum, f#fields))
            |> List.flatMap(f -> instanceTris(view, proj, screen, None, false, f, -1));
        let casterTris = List.zipWithIndex(billboards#casters) |> List.flatMap(entry -> {
            let (index, (f, _, right)) = entry;
            billboardQuadTris(view, proj, screen, { right = right | billboards#basis }, index, f)
        });
        let tris = hoist(rc, List.append(meshTris, casterTris) |> List.toVector);
        let bins = hoist(rc, binRows(rc, n, tris));
        let inks = hoist(rc, billboards#casters |> List.map(c -> { let (f, tex, _) = c; inkOf(tex, f) }) |> List.toVector);
        let noMats: Vector[Mat] = Vector.empty();
        let out: Array[Float64, Static] = Array.repeat(Static, n * n, 1.0);
        forEachRow(n, y -> region rr {
            let depth: Array[Float64, rr] = Array.repeat(rr, n, 2.0);
            let winner: Array[Int32, rr] = Array.repeat(rr, n, -1);
            let w0: Array[Float64, rr] = Array.repeat(rr, n, 0.0);
            let w1: Array[Float64, rr] = Array.repeat(rr, n, 0.0);
            let py = Int32.toFloat64(y) + 0.5;
            Vector.get(y, bins) |> List.forEach(ti -> coverRow(n, py, tris, inks, noMats, 0.0, 0.0, ti, depth, winner, w0, w1));
            // WhyNot: 画面の行の順（上が行 0）のまま置かない — GL の深度テクスチャは行 0 が NDC の y = −1 側で、向きをそろえる。
            List.range(0, n) |> List.forEach(x -> {
                let z = Array.get(x, depth);
                if (z <= 1.0) Array.put(z * 0.5 + 0.5, (n - 1 - y) * n + x, out) else ()
            })
        });
        Array.toVector(out)
    }
}
