// 骨つきの場面と instance の場面（R2b・P8 の (3)）: bench/scene3d の部屋に、ジョイント 3 本で曲がる柱の人形と、同じ形を多数並べた物を足して GL と WebGPU で比べる。
// 人形は柱を高さで 6 つのリングに割った形で、リングの頂点を下と上のジョイントへ高さで振り分けた重みで曲げる。姿勢は人形ごとに違い、3 体に 1 体は同じ 1 つの姿勢を共有する（同じ行を読む）。
mod V2Skinned {

    /// 部屋の 1 m（bench/scene3d の Room の長さの単位）。
    def meter(): Float64 = 16.0

    /// ジョイントの間の長さ（m）。柱の高さはその 3 つ分。
    def segment(): Float64 = 0.3

    /// 柱の太さの半分（m）。
    def halfWidth(): Float64 = 0.08

    /// 柱を高さで割るリングの数。
    def rings(): Int32 = 6

    /// 根 → 腰 → 胸のジョイント 3 本（親の向きで segment() ずつ上）。
    def skin(): Skin3d.Skin3d =
        let at = (y: Float64) -> { translation = Vec3.v3(0.0, y, 0.0), rotation = Quat.identity(), scale = Vec3.one() };
        match Skin3d.make({ names = Vector#{ "root", "waist", "chest" }, parents = Vector#{ -1, 0, 1 },
                            rest = Vector#{ at(0.0), at(segment() * meter()), at(segment() * meter()) }, inverseBinds = None, rootTransform = Mat4.identity() }) {
            case Ok(s)  => s
            case Err(e) => bug!("人形のスキンを作れない: ${e}")
        }

    /// 柱の 4 つの側面（外から見て時計回り）。skinned = ジョイントの重みを付ける。面ごとに頂点を持ち、法線と色は面で同じ。uv は面の横（0..1）と高さ（0..1）。
    def column(withUv: Bool, skinned: Bool): Mesh3d.Mesh3d =
        let w = halfWidth() * meter();
        let height = 3.0 * segment() * meter();
        let n = rings();
        // 面 = (横の始め, 横の終わり, 法線, 色)
        let faces = Vector#{
            ((-w, -w), (w, -w), (0.0, -1.0), (0.9, 0.5, 0.3)),
            ((w, -w), (w, w), (1.0, 0.0), (0.3, 0.8, 0.4)),
            ((w, w), (-w, w), (0.0, 1.0), (0.3, 0.5, 0.9)),
            ((-w, w), (-w, -w), (-1.0, 0.0), (0.9, 0.85, 0.3))
        };
        let perFace = 2 * (n + 1);
        let vertexCount = 4 * perFace;
        let corner = (f: Int32, k: Int32, side: Int32) -> {
            let ((ax, az), (bx, bz), _, _) = Vector.get(f, faces);
            let (x, z) = if (side == 0) (ax, az) else (bx, bz);
            (x, height * Int32.toFloat64(k) / Int32.toFloat64(n), z)
        };
        let vertexOf = (i: Int32) -> (i / perFace, Int32.remainder(i, perFace) / 2, Int32.remainder(i, 2));
        let positions = Vector.range(0, vertexCount) |> Vector.flatMap(i -> { let (f, k, side) = vertexOf(i); let (x, y, z) = corner(f, k, side); Vector#{ x, y, z } });
        let normals = Vector.range(0, vertexCount) |> Vector.flatMap(i -> { let (_, _, (nx, nz), _) = Vector.get(i / perFace, faces); Vector#{ nx, 0.0, nz } });
        let colors = Vector.range(0, vertexCount) |> Vector.flatMap(i -> { let (_, _, _, (r, g, b)) = Vector.get(i / perFace, faces); Vector#{ r, g, b } });
        let jointsAndWeights = Vector.range(0, vertexCount) |> Vector.map(i -> { let (_, k, _) = vertexOf(i); weightsAt(Int32.toFloat64(k) / Int32.toFloat64(n) * 3.0) });
        let indices = Vector.range(0, 4 * n) |> Vector.flatMap(q -> {
            let base = (q / n) * perFace + 2 * Int32.remainder(q, n);
            Vector#{ base, base + 2, base + 3, base, base + 3, base + 1 }
        });
        let mesh = match Mesh3d.fromArrays({ positions = positions, normals = normals, colors = colors, indices = indices,
                                              skin = if (skinned) Some({ joints = Vector.flatMap(fst, jointsAndWeights), weights = Vector.flatMap(snd, jointsAndWeights) }) else None }) {
            case Ok(m)  => m
            case Err(e) => bug!("人形の形を作れない: ${e}")
        };
        if (not withUv) mesh
        else {
            let uvs = Vector.range(0, vertexCount) |> Vector.flatMap(i -> { let (_, k, side) = vertexOf(i); Vector#{ Int32.toFloat64(side), 1.0 - Int32.toFloat64(k) / Int32.toFloat64(n) } });
            match Mesh3d.withUvs(uvs, mesh) {
                case Ok(m)  => m
                case Err(e) => bug!("人形の uv を付けられない: ${e}")
            }
        }

    /// 高さ t（ジョイントの間の長さを 1 とした数・0..3）の頂点の (ジョイントの番号 4 つ, 重み 4 つ)。下のジョイントと上のジョイントへ高さで振り分ける。
    def weightsAt(t: Float64): (Vector[Int32], Vector[Float64]) =
        let low = Int32.min(1, Num.floorInt(t));
        let frac = Float64.min(1.0, t - Int32.toFloat64(low));
        (Vector#{ low, low + 1, 0, 0 }, Vector#{ 1.0 - frac, frac, 0.0, 0.0 })

    /// i 番目の姿勢: 腰を z 軸で・胸を x 軸で曲げ、根を少し回す（3 体に 1 体は 0 番の姿勢と同じ値）。
    def poseOf(i: Int32): Pose3d.Pose3d =
        let k = Int32.toFloat64(Int32.remainder(i, 7));
        let local = (axis: Vec3.Vec3, angle: Float64, y: Float64) -> { translation = Vec3.v3(0.0, y, 0.0), rotation = axisAngle(axis, angle), scale = Vec3.one() };
        Pose3d.compute(skin(), Vector#{ local(Vec3.v3(0.0, 1.0, 0.0), 0.3 * k, 0.0),
                                        local(Vec3.v3(0.0, 0.0, 1.0), 0.15 + 0.12 * k, segment() * meter()),
                                        local(Vec3.v3(1.0, 0.0, 0.0), -0.5 + 0.17 * k, segment() * meter()) })

    /// 長さ 1 の軸 axis まわりに angle（ラジアン）回す向き。
    def axisAngle(axis: Vec3.Vec3, angle: Float64): Quat.Quat =
        let s = Num.sin(0.5 * angle);
        { x = axis#x * s, y = axis#y * s, z = axis#z * s, w = Num.cos(0.5 * angle) }

    /// 人形 count 体を部屋の床に格子で置いた物。material = 付ける材質（None なら頂点の色）・withUv = uv つきの形にする。
    def figures(count: Int32, withUv: Bool, material: Option[Scene3d.Material3d]): List[Scene3d.Instance3d] =
        let mesh = column(withUv, true);
        let shared = poseOf(0);
        List.range(0, count) |> List.map(i -> {
            let (col, row) = (Int32.remainder(i, 6), i / 6);
            let at = Vec3.v3((2.2 + 0.7 * Int32.toFloat64(col)) * meter(), 0.0, (3.0 + 0.8 * Int32.toFloat64(row)) * meter());
            let world = Mat4.mul(Mat4.translate(at), Mat4.rotateY(0.4 * Int32.toFloat64(i)));
            let pose = if (Int32.remainder(i, 3) == 0) shared else poseOf(i);
            let tone = Int32.toFloat64(i) / Int32.toFloat64(Int32.max(1, count));
            let placed = Scene3d.meshInstance(mesh, world) |> Scene3d.withPose(pose) |> Scene3d.withTint(Color.rgb(1.0, 1.0 - 0.5 * tone, 0.6 + 0.4 * tone));
            match material {
                case Some(m) => Scene3d.withMaterial(m, placed)
                case None    => placed
            }
        })

    /// 人形の数。
    pub def figureCount(): Int32 = 24

    /// 頂点の色の人形を部屋に足した場面。
    pub def vertexColored(room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        { instances = List.append(room#instances, figures(figureCount(), false, None)) | room }

    /// 絵つきの材質（uv・タンジェント）の人形を部屋に足した場面。
    pub def textured(texture: Texture3d.Texture3d, room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let material = Scene3d.texturedMaterial(Texture3d.name(texture), ShaderDoc.FilterMode.Linear);
        { instances = List.append(room#instances, figures(figureCount(), true, Some(material))), textures = texture :: room#textures | room }

    /// 小さな形 count 個（a と骨の無い柱を交互に・格子・向きと tint を物ごとに）を部屋に足した場面（1 体ごとの値の番号と行の頭の物を見る）。
    pub def crowd(count: Int32, a: Mesh3d.Mesh3d, room: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let b = column(false, false);
        let place = (i: Int32) -> {
            let (col, row) = (Int32.remainder(i, 40), i / 40);
            let at = Vec3.v3((0.6 + 0.17 * Int32.toFloat64(col)) * meter(), (0.2 + 0.15 * Int32.toFloat64(row)) * meter(), (5.5 + 0.05 * Int32.toFloat64(Int32.remainder(i, 7))) * meter());
            let tone = Int32.toFloat64(Int32.remainder(i * 37, 101)) / 100.0;
            let turn = Mat4.mul(Mat4.translate(at), Mat4.rotateY(0.31 * Int32.toFloat64(i)));
            let (mesh, world) = if (Int32.remainder(i, 2) == 0) (a, turn) else (b, Mat4.mul(turn, Mat4.scale(Vec3.v3(0.5, 0.15, 0.5))));
            Scene3d.meshInstance(mesh, world)
                |> Scene3d.withTint(Color.rgb(tone, 1.0 - tone, 0.5 + 0.5 * tone))
        };
        { instances = List.append(room#instances, List.range(0, count) |> List.map(place)) | room }
}
