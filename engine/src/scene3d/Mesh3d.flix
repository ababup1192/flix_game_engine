// Mesh3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// GPU に置く形（閉じた型 — 作る関数からだけ作り、中身と contentHash が食い違わない）。
/// 頂点は面ごとに分けて持つ（面の法線を各頂点へ写すため、隣の面と頂点を共有しない）。
pub mod Mesh3d {

    /// 多角形 1 つ: 頂点の列（3 つ以上・凸・外から見て時計回り）と色。
    pub type alias Polygon = { points = List[Vec3.Vec3], color = Color }

    /// 頂点の欄（頂点 i の値は [3i, 3i + 3) の 3 つ）。
    // WhyNot: 欄を並びの位置で持たない — 骨の重みなどを後から足した時、位置で読む所が全部ずれる。
    type alias Vertices = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], skin = Option[SkinWeights] }

    /// 頂点ごとに 4 つのジョイントの番号（スキンの中の何番目か）と重み（頂点 i の値は [4i, 4i + 4)）。
    pub type alias SkinWeights = { joints = Vector[Int32], weights = Vector[Float64] }

    type alias Mesh3dRec = { vertices = Vertices, indices = Vector[Int32], hash = String, low = Vec3.Vec3, high = Vec3.Vec3, maxJoint = Option[Int32] }

    enum Mesh3dData { case Mesh3dData(Mesh3dRec) }

    pub type alias Mesh3d = Mesh3dData

    def recOf(m: Mesh3d): Mesh3dRec = let Mesh3dData.Mesh3dData(r) = m; r

    /// 多角形の列から作る。各多角形は頂点 0 を要に扇に割り、巻き方は入力のまま保つ（外から見て時計回りが表）。
    /// 法線は多角形 1 つに 1 本（Newell の式で頂点の並びから求め、各頂点へ写す）。3 点未満の多角形は捨てる。
    pub def fromPolygons(polys: List[Polygon]): Mesh3d =
        let kept = List.filter(p -> List.length(p#points) >= 3, polys);
        let (_, revFaces) = List.foldLeft((acc, p) -> {
            let (base, out) = acc;
            (base + List.length(p#points), (base, p) :: out)
        }, (0, Nil), kept);
        let faces = List.reverse(revFaces);
        let positions = faces |> List.flatMap(face -> snd(face)#points |> List.flatMap(xyz)) |> List.toVector;
        let normals = faces |> List.flatMap(face -> {
            let points = snd(face)#points;
            let n = xyz(polygonNormal(points));
            points |> List.flatMap(_ -> n)
        }) |> List.toVector;
        let colors = faces |> List.flatMap(face -> {
            let p = snd(face);
            let c = p#color#r :: p#color#g :: p#color#b :: Nil;
            p#points |> List.flatMap(_ -> c)
        }) |> List.toVector;
        let indices = faces |> List.flatMap(face -> {
            let (base, p) = face;
            List.range(1, List.length(p#points) - 1) |> List.flatMap(i -> base :: base + i :: base + i + 1 :: Nil)
        }) |> List.toVector;
        let (low, high) = boundsOfPositions(positions);
        Mesh3dData.Mesh3dData({
            vertices = { positions = positions, normals = normals, colors = colors, skin = None },
            indices = indices,
            hash = hashOf(positions, colors, indices),
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
                Mesh3dData.Mesh3dData({
                    vertices = { positions = positions, normals = arrays#normals, colors = arrays#colors, skin = skin },
                    indices = arrays#indices,
                    hash = arraysHashOf(positions, arrays#normals, arrays#colors, arrays#indices, skin),
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

    // WhyNot: fromPolygons と同じ字にしない — 法線は位置から決まらず外から来るので、法線と重みも鍵に入れる（同じ位置で法線だけ違う形を取り違えない）。
    def arraysHashOf(positions: Vector[Float64], normals: Vector[Float64], colors: Vector[Float64], indices: Vector[Int32],
                     skin: Option[SkinWeights]): String =
        let skinText = match skin {
            case None => "-"
            case Some(sw) => "${Vector.join(",", sw#joints)}|${Vector.join(",", sw#weights)}"
        };
        let text = "arrays|${Vector.join(",", positions)}|${Vector.join(",", normals)}|${Vector.join(",", colors)}|${Vector.join(",", indices)}|${skinText}";
        Util.Codec.encodeHex(Util.Checksum.sha256(String.toBytes(text)))

    def xyz(v: Vec3.Vec3): List[Float64] = v#x :: v#y :: v#z :: Nil

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
        let text = "${Vector.join(",", positions)}|${Vector.join(",", colors)}|${Vector.join(",", indices)}";
        Util.Codec.encodeHex(Util.Checksum.sha256(String.toBytes(text)))

    /// Wavefront OBJ と .mtl の字から作る。読むのは v・f（v/vt/vn の形も先頭の番号だけ・負の番号はその行までの頂点から数える）・
    /// usemtl と .mtl の newmtl・Kd。ほかの行は読み飛ばす。.mtl に無い材質と Kd の無い材質は灰色。
    /// 座標は OBJ のまま読む（右手系の OBJ を左手系で読むので Z の向きに鏡写しになり、反時計回りの面が時計回りの表にそろう）。
    /// 数の読めない v・番号の範囲外や 3 点未満の f・面が 1 つも無い字は Err（行の番号つき）。
    // WhyNot: Z を反転して読まない — 反転すると巻き方も裏返り、OBJ の表の面が裏として捨てられる。
    pub def fromObj(objText: String, mtlText: String): Result[String, Mesh3d] =
        let colors = parseMtl(mtlText);
        let lines = String.lines(objText) |> List.map(String.words);
        let numbered = List.zip(List.range(1, List.length(lines) + 1), lines);
        let vertexList = numbered |> List.foldLeft((acc, line) -> Result.flatMap(found -> {
            let (lineNo, words) = line;
            match words {
                case "v" :: rest => Result.map(v -> v :: found, parseVertex(lineNo, rest))
                case _ => Ok(found)
            }
        }, acc), Ok(Nil));
        Result.flatMap(revVerts -> {
            let verts = List.toVector(List.reverse(revVerts));
            let start = { color = defaultGray(), seen = 0, polys = Nil };
            let facesR = numbered |> List.foldLeft((acc, line) -> Result.flatMap(state -> {
                let (lineNo, words) = line;
                match words {
                    case "v" :: _ => Ok({ seen = state#seen + 1 | state })
                    case "usemtl" :: name :: _ => Ok({ color = Map.getWithDefault(name, defaultGray(), colors) | state })
                    case "f" :: rest =>
                        Result.map(points -> { polys = { points = points, color = state#color } :: state#polys | state },
                                   parseFace(lineNo, state#seen, verts, rest))
                    case _ => Ok(state)
                }
            }, acc), Ok(start));
            Result.flatMap(state ->
                if (List.isEmpty(state#polys)) Err("OBJ に面（f の行）が 1 つも無い")
                else Ok(fromPolygons(List.reverse(state#polys))), facesR)
        }, vertexList)

    def defaultGray(): Color = Color.rgb(0.6, 0.6, 0.6)

    def parseVertex(lineNo: Int32, words: List[String]): Result[String, Vec3.Vec3] =
        match List.map(Float64.fromString, List.take(3, words)) {
            case Some(x) :: Some(y) :: Some(z) :: Nil => Ok(Vec3.v3(x, y, z))
            case _ => Err("OBJ ${lineNo} 行目: v の座標が 3 つの数で読めない")
        }

    def parseFace(lineNo: Int32, seen: Int32, verts: Vector[Vec3.Vec3], words: List[String]): Result[String, List[Vec3.Vec3]] =
        let points = List.map(faceIndex(seen, verts), words);
        if (List.length(points) < 3) Err("OBJ ${lineNo} 行目: f の頂点が 3 つ未満")
        else if (List.exists(Option.isEmpty, points)) Err("OBJ ${lineNo} 行目: f の頂点の番号が読めないか範囲の外")
        else Ok(List.filterMap(identity, points))

    def faceIndex(seen: Int32, verts: Vector[Vec3.Vec3], word: String): Option[Vec3.Vec3] =
        let head = String.splitOn({ substr = "/" }, word) |> List.head |> Option.getWithDefault("");
        Int32.fromString(head) |> Option.flatMap(i -> {
            let k = if (i < 0) seen + i else i - 1;
            if (i == 0 or k < 0 or k >= Int32.min(seen, Vector.length(verts))) None else Some(Vector.get(k, verts))
        })

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

    /// 中身の鍵（位置・色・番号の SHA-256 の 16 進）。同じ中身なら同じ字になる。GL はこれで頂点バッファを引く。
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
}
