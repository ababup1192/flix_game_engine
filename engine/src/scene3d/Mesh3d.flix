// Mesh3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// GPU に置く形（閉じた型 — 作る関数からだけ作り、中身と contentHash が食い違わない）。
/// 頂点は面ごとに分けて持つ（面の法線を各頂点へ写すため、隣の面と頂点を共有しない）。
pub mod Mesh3d {
    import java.nio.ByteBuffer
    import java.security.MessageDigest

    /// 多角形 1 つ: 頂点の列（3 つ以上・凸・外から見て時計回り）と色。
    pub type alias Polygon = { points = List[Vec3.Vec3], color = Color }

    /// 頂点の欄（頂点 i の値は [3i, 3i + 3) の 3 つ）。uvSet = 絵の上の位置とタンジェント（uv の無い形は None）。
    // WhyNot: 欄を並びの位置で持たない — 骨の重みなどを後から足した時、位置で読む所が全部ずれる。
    type alias Vertices = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], skin = Option[SkinWeights],
                            uvSet = Option[UvSet], uvs2 = Option[Vector[Float64]] }

    /// 頂点ごとの uv（[2i, 2i + 2)。(0, 0) が絵の左上・v は絵の下へ増える）とタンジェント（[4i, 4i + 4)。xyz は u が増える向きの単位ベクトル・
    /// w = ±1 で cross(法線, xyz) × w が絵の上（−v）を向く）。
    // WhyNot: uvs と tangents を別々の Option にしない — uv があるのにタンジェントが無い形を型で作れなくする。
    type alias UvSet = { uvs = Vector[Float64], tangents = Vector[Float64] }

    /// 頂点ごとに 4 つのジョイントの番号（スキンの中の何番目か）と重み（頂点 i の値は [4i, 4i + 4)）。
    pub type alias SkinWeights = { joints = Vector[Int32], weights = Vector[Float64] }

    /// hash = 中身の鍵・baseHash = uv を足す前の鍵（uv の無い形は hash と同じ）。
    type alias Mesh3dRec = { vertices = Vertices, indices = Vector[Int32], hash = String, baseHash = String, low = Vec3.Vec3, high = Vec3.Vec3,
                             maxJoint = Option[Int32] }

    enum Mesh3dData { case Mesh3dData(Mesh3dRec) }

    pub type alias Mesh3d = Mesh3dData

    def recOf(m: Mesh3d): Mesh3dRec = let Mesh3dData.Mesh3dData(r) = m; r

    /// 多角形の列から作る。各多角形は頂点 0 を要に扇に割り、巻き方は入力のまま保つ（外から見て時計回りが表）。
    /// 法線は多角形 1 つに 1 本（Newell の式で頂点の並びから求め、各頂点へ写す）。3 点未満の多角形は捨てる。
    pub def fromPolygons(polys: List[Polygon]): Mesh3d =
        let kept = List.filter(p -> List.length(p#points) >= 3, polys);
        let vertexCount = List.foldLeft((acc, p) -> acc + List.length(p#points), 0, kept);
        let triangleCount = vertexCount - 2 * List.length(kept);
        let (positions, normals, colors, indices) = region rc {
            let pos: Array[Float64, rc] = Array.empty(rc, vertexCount * 3);
            let nor: Array[Float64, rc] = Array.empty(rc, vertexCount * 3);
            let col: Array[Float64, rc] = Array.empty(rc, vertexCount * 3);
            let idx: Array[Int32, rc] = Array.empty(rc, triangleCount * 3);
            discard List.foldLeft((cursor, p) -> {
                let (base, slot) = cursor;
                let n = polygonNormal(p#points);
                let c = Vec3.v3(p#color#r, p#color#g, p#color#b);
                let size = List.foldLeft((k, q) -> {
                    putVec3(base + k, q, pos);
                    putVec3(base + k, n, nor);
                    putVec3(base + k, c, col);
                    k + 1
                }, 0, p#points);
                List.range(1, size - 1) |> List.forEach(i -> {
                    let t = (slot + i - 1) * 3;
                    Array.put(base, t, idx);
                    Array.put(base + i, t + 1, idx);
                    Array.put(base + i + 1, t + 2, idx)
                });
                (base + size, slot + size - 2)
            }, (0, 0), kept);
            (Array.toVector(pos), Array.toVector(nor), Array.toVector(col), Array.toVector(idx))
        };
        let (low, high) = boundsOfPositions(positions);
        let hash = hashOf(positions, colors, indices);
        Mesh3dData.Mesh3dData({
            vertices = { positions = positions, normals = normals, colors = colors, skin = None, uvSet = None, uvs2 = None },
            indices = indices,
            hash = hash,
            baseHash = hash,
            low = low,
            high = high,
            maxJoint = None
        })

    /// 頂点の並びから作る。positions・normals・colors は頂点ごとに 3 つ、indices は 3 つで三角 1 枚（表は外から見て時計回り）。
    /// skin = 頂点ごとに 4 つのジョイントの番号と重み（重みは足して 1 に直す）。
    /// 数の食い違い・範囲の外の頂点の番号・0 ≦ 番号 < Skin3d.maxJoints() でないジョイント・負の重み・重みの合計が 0 の頂点は Err。
    /// スキンの数とは描く時に照らす（Scene3d.skinningOf）。
    pub def fromArrays(arrays: { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32],
                                 skin = Option[SkinWeights] }): Result[String, Mesh3d] =
        let positions = arrays#positions;
        let count = Vector.length(positions) / 3;
        let badIndex = Vector.exists(i -> i < 0 or i >= count, arrays#indices);
        if (Vector.length(positions) != count * 3) Err("Mesh3d.fromArrays: positions の数が 3 の倍数でない")
        else if (Vector.length(arrays#normals) != count * 3 or Vector.length(arrays#colors) != count * 3)
            Err("Mesh3d.fromArrays: normals・colors の数が positions と食い違う")
        else if (Int32.remainder(Vector.length(arrays#indices), 3) != 0) Err("Mesh3d.fromArrays: indices の数が 3 の倍数でない")
        else if (badIndex) Err("Mesh3d.fromArrays: indices に頂点の範囲（0〜${count - 1}）の外の番号がある")
        else {
            let skinR = match arrays#skin {
                case None => Ok(None)
                case Some(sw) => Result.map(Some, checkSkin(count, sw))
            };
            Result.map(skin -> {
                let (low, high) = boundsOfPositions(positions);
                let hash = arraysHashOf(positions, arrays#normals, arrays#colors, arrays#indices, skin);
                Mesh3dData.Mesh3dData({
                    vertices = { positions = positions, normals = arrays#normals, colors = arrays#colors, skin = skin, uvSet = None, uvs2 = None },
                    indices = arrays#indices,
                    hash = hash,
                    baseHash = hash,
                    low = low,
                    high = high,
                    maxJoint = Option.map(sw -> Vector.foldLeft(Int32.max, 0, sw#joints), skin)
                })
            }, skinR)
        }

    def checkSkin(count: Int32, sw: SkinWeights): Result[String, SkinWeights] =
        let badJoint = Vector.exists(j -> j < 0 or j >= Skin3d.maxJoints(), sw#joints);
        let badWeight = Vector.exists(w -> not (w >= 0.0), sw#weights);
        let sums = Vector.range(0, count) |> Vector.map(v ->
            Vector.get(v * 4, sw#weights) + Vector.get(v * 4 + 1, sw#weights) + Vector.get(v * 4 + 2, sw#weights) + Vector.get(v * 4 + 3, sw#weights));
        if (Vector.length(sw#joints) != count * 4 or Vector.length(sw#weights) != count * 4)
            Err("Mesh3d.fromArrays: skin の joints・weights の数が頂点の数 × 4 でない")
        else if (badJoint) Err("Mesh3d.fromArrays: skin のジョイントの番号が 0〜${Skin3d.maxJoints() - 1} の外")
        else if (badWeight) Err("Mesh3d.fromArrays: skin の重みに負の数か数でない値がある")
        else match Vector.findIndexOf(s -> s <= 0.0, sums) {
            case Some(v) => Err("Mesh3d.fromArrays: 頂点 ${v} の重みの合計が 0")
            case None => Ok({ weights = Vector.mapWithIndex((k, w) -> w / Vector.get(k / 4, sums), sw#weights) | sw })
        }

    /// uv を付ける（頂点ごとに u・v の 2 つ）。タンジェントは三角形の辺と uv の差から求める（作る時に 1 回・GL と CPU は同じ値を読む）。
    /// uv の決まりの写し: (0, 0) が絵の左上・v は絵の下へ増える（glTF と 2D の面の Uv と同じ）。
    /// 作るのは読み込みの時に 1 回（毎コマ呼ぶと、そのたびに中身の鍵の SHA を取り直す）。
    /// 数が頂点の数 × 2 でない・NaN・無限は Err。
    pub def withUvs(uvs: Vector[Float64], m: Mesh3d): Result[String, Mesh3d] =
        let r = recOf(m);
        let count = Vector.length(r#vertices#positions) / 3;
        if (Vector.length(uvs) != count * 2) Err("Mesh3d.withUvs: uvs の数が頂点の数 × 2（${count * 2}）でない")
        else if (Vector.exists(x -> not isFiniteNumber(x), uvs)) Err("Mesh3d.withUvs: uvs に NaN か無限がある")
        else Ok(withUvSet({ uvs = uvs, tangents = computeTangents(r#vertices#positions, r#vertices#normals, uvs, r#indices) }, r))

    /// 外で求めたタンジェント（頂点ごとに x・y・z・w の 4 つ。glTF の TANGENT）で置き換える。xyz は長さ 1 にそろえる。
    /// uv が無い・数の食い違い・w が ±1 でない・xyz の長さが 0 か数でない、は Err。
    pub def withTangents(tangents: Vector[Float64], m: Mesh3d): Result[String, Mesh3d] =
        let r = recOf(m);
        let count = Vector.length(r#vertices#positions) / 3;
        match r#vertices#uvSet {
            case None => Err("Mesh3d.withTangents: uv の無い形にはタンジェントを付けられない（先に withUvs）")
            case Some(set) =>
                if (Vector.length(tangents) != count * 4) Err("Mesh3d.withTangents: tangents の数が頂点の数 × 4（${count * 4}）でない")
                else match Vector.findIndexOf(k -> not isTangentOk(vec4At(tangents, k)), Vector.range(0, count)) {
                    case Some(k) => Err("Mesh3d.withTangents: 頂点 ${k} のタンジェントの w が ±1 でないか、xyz の長さが 0")
                    case None =>
                        let rows = Vector.range(0, count) |> Vector.map(k -> {
                            let (t, w) = vec4At(tangents, k);
                            (Vec3.normalized(t), w)
                        });
                        let unit = rowsOf(count, 4, (k, c) -> {
                            let (n, w) = Vector.get(k, rows);
                            if (c == 3) w else component(c, n)
                        });
                        Ok(withUvSet({ tangents = unit | set }, r))
                }
        }

    def isTangentOk(t: (Vec3.Vec3, Float64)): Bool =
        let (xyz, w) = t;
        let len = Vec3.length(xyz);
        (w == 1.0 or w == -1.0) and isFiniteNumber(len) and len >= 1.0e-12

    def isFiniteNumber(x: Float64): Bool = not Float64.isNan(x) and not Float64.isInfinite(x)

    /// uv つきの多角形（uvs は points と同じ数・同じ並び）。
    pub type alias TexturedPolygon = { points = List[Vec3.Vec3], uvs = List[Vec2.Vec2], color = Color }

    /// uv つきの多角形の列から作る（割り方と法線は fromPolygons と同じ・3 点未満の多角形は捨てる）。
    /// points と uvs の数が違う多角形・NaN か無限の uv は Err。
    pub def fromTexturedPolygons(polys: List[TexturedPolygon]): Result[String, Mesh3d] =
        match List.toVector(polys) |> Vector.findIndexOf(p -> List.length(p#points) != List.length(p#uvs)) {
            case Some(i) => Err("Mesh3d.fromTexturedPolygons: 多角形 ${i} の points と uvs の数が違う")
            case None =>
                let kept = List.filter(p -> List.length(p#points) >= 3, polys);
                let mesh = fromPolygons(kept |> List.map(p -> { points = p#points, color = p#color }));
                withUvs(kept |> List.flatMap(p -> p#uvs |> List.flatMap(uv -> uv#x :: uv#y :: Nil)) |> List.toVector, mesh)
        }

    /// 箱投影の uv（形の座標 × scale。置き場所を動かしても絵が付いて動く）。三角形ごとに、面の法線の一番大きい軸の面へ写す:
    ///   +X: (z, −y)・−X: (−z, −y)・+Y: (x, −z)・−Y: (x, z)・+Z: (−x, −y)・−Z: (x, −y)
    /// どの面も cross(u の向き, v の向き) が外向きの法線になり、外から見て鏡写しにならない（+Y の面は北が絵の上）。
    /// 軸の違う面と共有している頂点は分ける（スキンの欄も一緒に写す）。前からある uv は置き換える。
    // WhyNot: 頂点の法線で面を選ばない — 1 枚の三角形の中で軸が混ざり、絵が伸びる。
    pub def withBoxUvs(scale: Float64, m: Mesh3d): Mesh3d =
        let r = recOf(m);
        let v = r#vertices;
        let count = Vector.length(v#positions) / 3;
        let corners = r#indices;
        let faces = Vector.range(0, Vector.length(corners) / 3) |> Vector.map(t ->
            boxFaceOf(Vec3.cross(Vec3.sub(vec3At(v#positions, Vector.get(t * 3 + 1, corners)), vec3At(v#positions, Vector.get(t * 3, corners))),
                                 Vec3.sub(vec3At(v#positions, Vector.get(t * 3 + 2, corners)), vec3At(v#positions, Vector.get(t * 3, corners))))));
        let split = splitByFace(count, corners, faces);
        let sources = Vector.append(Vector.range(0, count), split#extra |> Vector.map(fst));
        let faceOfVertex = Vector.append(split#home, split#extra |> Vector.map(snd));
        let positions = pickRows(sources, 3, v#positions);
        let uvRows = Vector.range(0, Vector.length(sources)) |> Vector.map(k -> boxUv(scale, Vector.get(k, faceOfVertex), vec3At(positions, k)));
        let uvs = rowsOf(Vector.length(sources), 2, (k, c) -> { let (u, w) = Vector.get(k, uvRows); if (c == 0) u else w });
        let moved = if (Vector.isEmpty(split#extra)) r
            else {
                let normals = pickRows(sources, 3, v#normals);
                let colors = pickRows(sources, 3, v#colors);
                let skin = Option.map(sw -> { joints = pickRows(sources, 4, sw#joints), weights = pickRows(sources, 4, sw#weights) }, v#skin);
                let uvs2 = Option.map(pickRows(sources, 2), v#uvs2);
                let hash = arraysHashOf(positions, normals, colors, split#indices, skin);
                { vertices = { positions = positions, normals = normals, colors = colors, skin = skin, uvSet = None, uvs2 = uvs2 },
                  indices = split#indices, hash = hash, baseHash = hash | r }
            };
        withUvSet({ uvs = uvs, tangents = computeTangents(moved#vertices#positions, moved#vertices#normals, uvs, moved#indices) }, moved)

    /// 元の並び values（頂点ごとに width 個）から、sources の頂点の順に写した並び。
    def pickRows(sources: Vector[Int32], width: Int32, values: Vector[a]): Vector[a] =
        rowsOf(Vector.length(sources), width, (k, c) -> Vector.get(Vector.get(k, sources) * width + c, values))

    /// count 行 × width 列の並び（行 k・列 c の値は cell(k, c)）。
    // WhyNot: 行ごとの小さな Vector を Vector.flatMap でつながない — 頂点 16 万の形で 1 秒近くかかる。
    def rowsOf(count: Int32, width: Int32, cell: (Int32, Int32) -> a \ ef): Vector[a] \ ef =
        Vector.range(0, count * width) |> Vector.map(j -> cell(j / width, Int32.remainder(j, width)))

    def component(c: Int32, v: Vec3.Vec3): Float64 = if (c == 0) v#x else if (c == 1) v#y else v#z

    /// 箱の面の番号（0 = +X・1 = −X・2 = +Y・3 = −Y・4 = +Z・5 = −Z）。同じ大きさの軸は X → Y → Z の順に取る。
    def boxFaceOf(n: Vec3.Vec3): Int32 =
        let (ax, ay, az) = (Float64.abs(n#x), Float64.abs(n#y), Float64.abs(n#z));
        if (ax >= ay and ax >= az) (if (n#x >= 0.0) 0 else 1)
        else if (ay >= az) (if (n#y >= 0.0) 2 else 3)
        else if (n#z >= 0.0) 4 else 5

    def boxUv(scale: Float64, face: Int32, p: Vec3.Vec3): (Float64, Float64) =
        let (u, w) = match face {
            case 0 => (p#z, 0.0 - p#y)
            case 1 => (0.0 - p#z, 0.0 - p#y)
            case 2 => (p#x, 0.0 - p#z)
            case 3 => (p#x, p#z)
            case 4 => (0.0 - p#x, 0.0 - p#y)
            case _ => (p#x, 0.0 - p#y)
        };
        (u * scale, w * scale)

    /// 頂点を面ごとに分けた結果。home = 元の頂点 k の面（最初に使う三角形の面・使われない頂点は 0）・
    /// extra = 足した頂点の (元の頂点, 面) の並び（番号は count から）・indices = 分けた後の三角形の番号。
    type alias FaceSplit = { home = Vector[Int32], extra = Vector[(Int32, Int32)], indices = Vector[Int32] }

    def splitByFace(count: Int32, corners: Vector[Int32], faces: Vector[Int32]): FaceSplit = region rc {
        let home: Array[Int32, rc] = Array.repeat(rc, count, -1);
        let extra = Ref.fresh(rc, (Map.empty(): Map[(Int32, Int32), Int32]));
        let revExtra = Ref.fresh(rc, (Nil: List[(Int32, Int32)]));
        let indices = corners |> Vector.mapWithIndex((c, vertex) -> {
            let face = Vector.get(c / 3, faces);
            let current = Array.get(vertex, home);
            if (current < 0) { Array.put(face, vertex, home); vertex }
            else if (current == face) vertex
            else match Map.get((vertex, face), Ref.get(extra)) {
                case Some(k) => k
                case None =>
                    let k = count + Map.size(Ref.get(extra));
                    Ref.put(Map.insert((vertex, face), k, Ref.get(extra)), extra);
                    Ref.put((vertex, face) :: Ref.get(revExtra), revExtra);
                    k
            }
        });
        { home = Array.toVector(home) |> Vector.map(f -> Int32.max(0, f)),
          extra = List.toVector(List.reverse(Ref.get(revExtra))), indices = indices }
    }

    def withUvSet(set: UvSet, r: Mesh3dRec): Mesh3d =
        Mesh3dData.Mesh3dData({ vertices = { uvSet = Some(set) | r#vertices }, hash = surfaceHashOf(r#baseHash, Some(set), r#vertices#uvs2) | r })

    /// 2 本目の uv（lightmap を読む UV。頂点ごとに u・v の 2 つ・(0, 0) が絵の左上）を付ける。Unity の uv2・Godot の UV2・
    /// Bevy の ATTRIBUTE_UV_1・glTF の TEXCOORD_1 にあたる。タンジェントは作らない（法線マップは 1 本目の uv で読む）。
    /// 数が頂点の数 × 2 でない・NaN・無限は Err。
    pub def withUvs2(uvs: Vector[Float64], m: Mesh3d): Result[String, Mesh3d] =
        let r = recOf(m);
        let count = Vector.length(r#vertices#positions) / 3;
        if (Vector.length(uvs) != count * 2) Err("Mesh3d.withUvs2: uvs の数が頂点の数 × 2（${count * 2}）でない")
        else if (Vector.exists(x -> not isFiniteNumber(x), uvs)) Err("Mesh3d.withUvs2: uvs に NaN か無限がある")
        else Ok(Mesh3dData.Mesh3dData({ vertices = { uvs2 = Some(uvs) | r#vertices }, hash = surfaceHashOf(r#baseHash, r#vertices#uvSet, Some(uvs)) | r }))

    /// uv の欄（1 本目の uv とタンジェント・2 本目の uv）を足した中身の鍵。withUvSet と withUvs2 のどちらの順で付けても同じ鍵になる。
    // WhyNot: uv の無い形の鍵に uv の欄を足さない — 前からある形の鍵（GL の頂点バッファ・描き出しの鍵）を変えない。2 本目の uv の無い形も同じ。
    def surfaceHashOf(baseHash: String, set: Option[UvSet], uvs2: Option[Vector[Float64]]): String =
        match (set, uvs2) {
            case (None, None)          => baseHash
            case (Some(s), None)       => digestOf("uv|${baseHash}", s#uvs :: s#tangents :: Nil, Nil)
            case (None, Some(second))  => digestOf("uv2|${baseHash}", second :: Nil, Nil)
            case (Some(s), Some(second)) => digestOf("uv+uv2|${baseHash}", s#uvs :: s#tangents :: second :: Nil, Nil)
        }

    /// 頂点ごとのタンジェント（x・y・z・w）。三角形ごとに
    ///   t = (e1·dv2 − e2·dv1) / det（u が増える向き）・b = (e2·du1 − e1·du2) / det（v が増える向き）
    /// を、その頂点を使う三角形の分だけ足し、法線に直交させて長さ 1 にする。w は cross(n, t) が −b（絵の上）の側なら +1。
    /// |det| < 1e−12 の三角形は足さない。足した t が法線と平行（長さ 0）なら、法線に直交する決まった向き。
    def computeTangents(positions: Vector[Float64], normals: Vector[Float64], uvs: Vector[Float64], indices: Vector[Int32]): Vector[Float64] = region rc {
        let count = Vector.length(positions) / 3;
        let tSum: Array[Float64, rc] = Array.repeat(rc, count * 3, 0.0);
        let bSum: Array[Float64, rc] = Array.repeat(rc, count * 3, 0.0);
        let uvAt = (k: Int32) -> (Vector.get(k * 2, uvs), Vector.get(k * 2 + 1, uvs));
        Vector.range(0, Vector.length(indices) / 3) |> Vector.forEach(t -> {
            let (i0, i1, i2) = (Vector.get(t * 3, indices), Vector.get(t * 3 + 1, indices), Vector.get(t * 3 + 2, indices));
            let p0 = vec3At(positions, i0);
            let e1 = Vec3.sub(vec3At(positions, i1), p0);
            let e2 = Vec3.sub(vec3At(positions, i2), p0);
            let (u0, v0) = uvAt(i0);
            let (u1, v1) = uvAt(i1);
            let (u2, v2) = uvAt(i2);
            let (du1, dv1, du2, dv2) = (u1 - u0, v1 - v0, u2 - u0, v2 - v0);
            let det = du1 * dv2 - du2 * dv1;
            if (Float64.abs(det) < 1.0e-12) ()
            else {
                let tangent = Vec3.mul(Vec3.sub(Vec3.mul(e1, dv2), Vec3.mul(e2, dv1)), 1.0 / det);
                let bitangent = Vec3.mul(Vec3.sub(Vec3.mul(e2, du1), Vec3.mul(e1, du2)), 1.0 / det);
                (i0 :: i1 :: i2 :: Nil) |> List.forEach(k -> { addVec3(k, tangent, tSum); addVec3(k, bitangent, bSum) })
            }
        });
        let out: Array[Float64, rc] = Array.empty(rc, count * 4);
        Vector.range(0, count) |> Vector.forEach(k -> {
            let t = tangentOf(vec3At(normals, k), readVec3(k, tSum), readVec3(k, bSum));
            List.range(0, 4) |> List.forEach(c -> Array.put(Vector.get(c, t), k * 4 + c, out))
        });
        Array.toVector(out)
    }

    def addVec3(k: Int32, v: Vec3.Vec3, sums: Array[Float64, r]): Unit \ r =
        Array.put(Array.get(k * 3, sums) + v#x, k * 3, sums);
        Array.put(Array.get(k * 3 + 1, sums) + v#y, k * 3 + 1, sums);
        Array.put(Array.get(k * 3 + 2, sums) + v#z, k * 3 + 2, sums)

    def putVec3(k: Int32, v: Vec3.Vec3, out: Array[Float64, r]): Unit \ r =
        Array.put(v#x, k * 3, out);
        Array.put(v#y, k * 3 + 1, out);
        Array.put(v#z, k * 3 + 2, out)

    def readVec3(k: Int32, sums: Array[Float64, r]): Vec3.Vec3 \ r =
        Vec3.v3(Array.get(k * 3, sums), Array.get(k * 3 + 1, sums), Array.get(k * 3 + 2, sums))

    def tangentOf(n: Vec3.Vec3, t: Vec3.Vec3, b: Vec3.Vec3): Vector[Float64] =
        let ortho = Vec3.sub(t, Vec3.mul(n, Vec3.dot(n, t)));
        let unit = if (Vec3.length(ortho) < 1.0e-12) fallbackTangent(n) else Vec3.normalized(ortho);
        let w = if (Vec3.dot(Vec3.cross(n, unit), Vec3.mul(b, -1.0)) < 0.0) -1.0 else 1.0;
        Vector#{ unit#x, unit#y, unit#z, w }

    /// 法線 n に直交する決まった向き（上との外積・n がほぼ上下なら東との外積）。
    def fallbackTangent(n: Vec3.Vec3): Vec3.Vec3 =
        if (Float64.abs(n#y) < 0.9) Vec3.normalized(Vec3.cross(Vec3.v3(0.0, 1.0, 0.0), n))
        else Vec3.normalized(Vec3.cross(Vec3.v3(1.0, 0.0, 0.0), n))

    def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 =
        Vec3.v3(Vector.get(k * 3, v), Vector.get(k * 3 + 1, v), Vector.get(k * 3 + 2, v))

    def vec4At(v: Vector[Float64], k: Int32): (Vec3.Vec3, Float64) =
        (Vec3.v3(Vector.get(k * 4, v), Vector.get(k * 4 + 1, v), Vector.get(k * 4 + 2, v)), Vector.get(k * 4 + 3, v))

    // WhyNot: fromPolygons と同じ字にしない — 法線は位置から決まらず外から来るので、法線と重みも鍵に入れる（同じ位置で法線だけ違う形を取り違えない）。
    def arraysHashOf(positions: Vector[Float64], normals: Vector[Float64], colors: Vector[Float64], indices: Vector[Int32],
                     skin: Option[SkinWeights]): String =
        match skin {
            case None     => digestOf("arrays", positions :: normals :: colors :: Nil, indices :: Nil)
            case Some(sw) => digestOf("arrays+skin", positions :: normals :: colors :: sw#weights :: Nil, indices :: sw#joints :: Nil)
        }

    /// 鍵の字（SHA-256 の 16 進）。tag の字と、各並びの長さと値のバイト（Float64 は IEEE 754 のビットのまま）を順に流す。
    // WhyNot: 値を文字列につないでから SHA を取らない — 頂点 16 万の形で Double.toString だけで数十 ms かかる。
    def digestOf(tag: String, floats: List[Vector[Float64]], ints: List[Vector[Int32]]): String =
        unsafe IO {
            let md = MessageDigest.getInstance("SHA-256");
            md.update(unchecked_cast(String.toBytes(tag) as Array[Int8, Static]));
            floats |> List.forEach(v -> {
                let buffer = ByteBuffer.allocate(4 + Vector.length(v) * 8);
                discard buffer.putInt(Vector.length(v));
                discard buffer.asDoubleBuffer().put(unchecked_cast(v as Array[Float64, Static]));
                md.update(buffer.array())
            });
            ints |> List.forEach(v -> {
                let buffer = ByteBuffer.allocate(4 + Vector.length(v) * 4);
                discard buffer.putInt(Vector.length(v));
                discard buffer.asIntBuffer().put(unchecked_cast(v as Array[Int32, Static]));
                md.update(buffer.array())
            });
            Util.Codec.encodeHex(Array.toVector(md.digest()))
        }

    // WhyNot: 頂点 0・1・2 の外積だけで法線を出さない — 先頭の 3 点が一直線に並ぶ多角形（辺の途中に頂点がある壁）で 0 になる。
    def polygonNormal(points: List[Vec3.Vec3]): Vec3.Vec3 =
        let next = List.append(List.drop(1, points), List.take(1, points));
        List.zip(points, next)
            |> List.foldLeft((acc, pair) -> {
                let (a, b) = pair;
                Vec3.v3(acc#x + (a#y - b#y) * (a#z + b#z),
                        acc#y + (a#z - b#z) * (a#x + b#x),
                        acc#z + (a#x - b#x) * (a#y + b#y))
            }, Vec3.zero())
            |> Vec3.normalized

    def boundsOfPositions(positions: Vector[Float64]): (Vec3.Vec3, Vec3.Vec3) =
        let count = Vector.length(positions) / 3;
        if (count == 0) (Vec3.zero(), Vec3.zero())
        else {
            let axis = (offset: Int32) -> List.range(0, count) |> List.map(i -> Vector.get(i * 3 + offset, positions));
            let lowOf = (vs: List[Float64]) -> List.foldLeft(Float64.min, Float64.maxValue(), vs);
            let highOf = (vs: List[Float64]) -> List.foldLeft(Float64.max, Float64.minValue(), vs);
            (Vec3.v3(lowOf(axis(0)), lowOf(axis(1)), lowOf(axis(2))),
             Vec3.v3(highOf(axis(0)), highOf(axis(1)), highOf(axis(2))))
        }

    // 法線は位置から決まるので鍵に入れない。
    def hashOf(positions: Vector[Float64], colors: Vector[Float64], indices: Vector[Int32]): String =
        digestOf("polygons", positions :: colors :: Nil, indices :: Nil)

    /// Wavefront OBJ と .mtl の字から作る。読むのは v・vt・f（v/vt/vn の形は 1 番目と 2 番目の番号・負の番号はその行までの頂点から数える）・
    /// usemtl と .mtl の newmtl・Kd。ほかの行は読み飛ばす。.mtl に無い材質と Kd の無い材質は灰色。
    /// 全部の面の全部の頂点に vt があれば uv つき（v は 1 − v に直す。OBJ は絵の左下が 0）、1 つでも欠ければ uv なし。
    /// 座標は OBJ のまま読む（右手系の OBJ を左手系で読むので Z の向きに鏡写しになり、反時計回りの面が時計回りの表にそろう）。
    /// 数の読めない v・vt・番号の範囲外や 3 点未満の f・面が 1 つも無い字は Err（行の番号つき）。
    // WhyNot: Z を反転して読まない — 反転すると巻き方も裏返り、OBJ の表の面が裏として捨てられる。
    // WhyNot: u を反転して絵の鏡写しを戻さない — 形も鏡写しなので、そろって鏡写しのままの方が左右非対称の家具と絵の位置が食い違わない。
    //   文字の入った絵を貼るなら glb を使う。
    pub def fromObj(objText: String, mtlText: String): Result[String, Mesh3d] =
        let colors = parseMtl(mtlText);
        let lines = String.lines(objText) |> List.map(String.words);
        let numbered = List.zip(List.range(1, List.length(lines) + 1), lines);
        let pointsR = numbered |> List.foldLeft((acc, line) -> Result.flatMap(found -> {
            let (lineNo, words) = line;
            let (vs, vts) = found;
            match words {
                case "v" :: rest  => Result.map(v -> (v :: vs, vts), parseVertex(lineNo, rest))
                case "vt" :: rest => Result.map(t -> (vs, t :: vts), parseTexCoord(lineNo, rest))
                case _ => Ok(found)
            }
        }, acc), Ok((Nil, Nil)));
        Result.flatMap(revPoints -> {
            let (revVerts, revUvs) = revPoints;
            let verts = List.toVector(List.reverse(revVerts));
            let uvs = List.toVector(List.reverse(revUvs));
            let start = { color = defaultGray(), seen = 0, seenUv = 0, polys = Nil };
            let facesR = numbered |> List.foldLeft((acc, line) -> Result.flatMap(state -> {
                let (lineNo, words) = line;
                match words {
                    case "v" :: _  => Ok({ seen = state#seen + 1 | state })
                    case "vt" :: _ => Ok({ seenUv = state#seenUv + 1 | state })
                    case "usemtl" :: name :: _ => Ok({ color = Map.getWithDefault(name, defaultGray(), colors) | state })
                    case "f" :: rest =>
                        Result.map(face -> { polys = (face, state#color) :: state#polys | state },
                                   parseFace(lineNo, { seen = state#seen, seenUv = state#seenUv, verts = verts, uvs = uvs }, rest))
                    case _ => Ok(state)
                }
            }, acc), Ok(start));
            Result.flatMap(state -> {
                let faces = List.reverse(state#polys);
                if (List.isEmpty(faces)) Err("OBJ に面（f の行）が 1 つも無い")
                else match faces |> List.map(fc -> { let (face, color) = fc; face#uvs |> Option.map(uv -> { points = face#points, uvs = uv, color = color }) })
                                 |> List.sequence {
                    case Some(textured) => fromTexturedPolygons(textured)
                    case None => Ok(fromPolygons(faces |> List.map(fc -> { let (face, color) = fc; { points = face#points, color = color } })))
                }
            }, facesR)
        }, pointsR)

    def parseTexCoord(lineNo: Int32, words: List[String]): Result[String, Vec2.Vec2] =
        match List.map(Float64.fromString, List.take(2, words)) {
            case Some(u) :: Some(v) :: Nil => Ok({ x = u, y = 1.0 - v })
            case _ => Err("OBJ ${lineNo} 行目: vt の座標が 2 つの数で読めない")
        }

    def defaultGray(): Color = Color.rgb(0.6, 0.6, 0.6)

    def parseVertex(lineNo: Int32, words: List[String]): Result[String, Vec3.Vec3] =
        match List.map(Float64.fromString, List.take(3, words)) {
            case Some(x) :: Some(y) :: Some(z) :: Nil => Ok(Vec3.v3(x, y, z))
            case _ => Err("OBJ ${lineNo} 行目: v の座標が 3 つの数で読めない")
        }

    /// f の行の頂点（と、全部の頂点に vt があればその uv）。seen・seenUv = その行までの v・vt の数（負の番号の数え始め）。
    def parseFace(lineNo: Int32, at: { seen = Int32, seenUv = Int32, verts = Vector[Vec3.Vec3], uvs = Vector[Vec2.Vec2] },
                  words: List[String]): Result[String, { points = List[Vec3.Vec3], uvs = Option[List[Vec2.Vec2]] }] =
        let indexOf = (part: Int32, word: String) ->
            String.splitOn({ substr = "/" }, word) |> List.drop(part) |> List.head |> Option.flatMap(Int32.fromString);
        let points = List.map(w -> indexOf(0, w) |> Option.flatMap(i -> pick(at#seen, at#verts, i)), words);
        let uvs = List.map(w -> indexOf(1, w) |> Option.flatMap(i -> pick(at#seenUv, at#uvs, i)), words);
        if (List.length(points) < 3) Err("OBJ ${lineNo} 行目: f の頂点が 3 つ未満")
        else if (List.exists(Option.isEmpty, points)) Err("OBJ ${lineNo} 行目: f の頂点の番号が読めないか範囲の外")
        else Ok({ points = List.filterMap(identity, points), uvs = List.sequence(uvs) })

    /// OBJ の番号 i（1 から・負なら seen から数える）の要素（範囲の外は None）。
    def pick(seen: Int32, items: Vector[a], i: Int32): Option[a] =
        let k = if (i < 0) seen + i else i - 1;
        if (i == 0 or k < 0 or k >= Int32.min(seen, Vector.length(items))) None else Some(Vector.get(k, items))

    def parseMtl(text: String): Map[String, Color] =
        let num = (s: String) -> Float64.fromString(s) |> Option.getWithDefault(0.0);
        let (_, found) = String.lines(text) |> List.map(String.words) |> List.foldLeft((acc, words) -> {
            let (current, m) = acc;
            match words {
                case "newmtl" :: name :: _ => (name, Map.insert(name, defaultGray(), m))
                case "Kd" :: r :: g :: b :: _ => (current, Map.insert(current, Color.rgb(num(r), num(g), num(b)), m))
                case _ => (current, m)
            }
        }, ("", Map.empty()));
        found

    /// 中身の鍵（位置・色・番号の SHA-256 の 16 進。uv つきは uv とタンジェントも）。同じ中身なら同じ字になる。GL はこれで頂点バッファを引く。
    pub def contentHash(m: Mesh3d): String = recOf(m)#hash

    /// 頂点の最小と最大（形の座標）。頂点の無い形は 0。
    pub def bounds(m: Mesh3d): { min = Vec3.Vec3, max = Vec3.Vec3 } =
        let r = recOf(m);
        { min = r#low, max = r#high }

    pub def triangleCount(m: Mesh3d): Int32 = Vector.length(recOf(m)#indices) / 3

    pub def vertexCount(m: Mesh3d): Int32 = Vector.length(recOf(m)#vertices#positions) / 3

    /// 頂点の位置（形の座標。頂点ごとに x・y・z の 3 つ）。
    pub def positions(m: Mesh3d): Vector[Float64] = recOf(m)#vertices#positions

    /// 頂点の法線（長さ 1。頂点ごとに 3 つ。面積 0 の面は 0）。
    pub def normals(m: Mesh3d): Vector[Float64] = recOf(m)#vertices#normals

    /// 頂点の色（頂点ごとに r・g・b の 3 つ）。
    pub def colors(m: Mesh3d): Vector[Float64] = recOf(m)#vertices#colors

    /// 頂点ごとに 4 つのジョイントの番号（スキンの中の何番目か）。ジョイントの無い形は None。
    pub def skinJoints(m: Mesh3d): Option[Vector[Int32]] = recOf(m)#vertices#skin |> Option.map(sw -> sw#joints)

    /// 頂点ごとに 4 つの重み（足して 1）。ジョイントの無い形は None。
    pub def skinWeights(m: Mesh3d): Option[Vector[Float64]] = recOf(m)#vertices#skin |> Option.map(sw -> sw#weights)

    /// 使っているジョイントの番号の最大（重みが 0 の欄の番号も数える）。ジョイントの無い形は None。
    // WhyNot: 描く時に頂点を舐めて求めない — 毎コマ全部のインスタンスで頂点の数だけ回すことになる。
    pub def maxSkinJoint(m: Mesh3d): Option[Int32] = recOf(m)#maxJoint

    /// 三角形の頂点の番号（3 つで 1 枚・外から見て時計回り）。
    pub def indices(m: Mesh3d): Vector[Int32] = recOf(m)#indices

    /// 頂点の uv（頂点ごとに u・v の 2 つ。(0, 0) が絵の左上）。uv の無い形は None。
    pub def uvs(m: Mesh3d): Option[Vector[Float64]] = recOf(m)#vertices#uvSet |> Option.map(set -> set#uvs)

    /// 頂点の 2 本目の uv（lightmap を読む UV。頂点ごとに u・v の 2 つ）。無い形は None。
    pub def uvs2(m: Mesh3d): Option[Vector[Float64]] = recOf(m)#vertices#uvs2

    /// 頂点のタンジェント（頂点ごとに x・y・z・w の 4 つ。cross(法線, xyz) × w が絵の上を向く）。uv の無い形は None。
    pub def tangents(m: Mesh3d): Option[Vector[Float64]] = recOf(m)#vertices#uvSet |> Option.map(set -> set#tangents)
}
