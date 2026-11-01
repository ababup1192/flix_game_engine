// Gltf — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// glTF 2.0 のバイナリ（.glb）を読む: メッシュ・スキン・頂点のジョイントの重み・アニメーション。
/// 右手系の glTF を左手系の engine へ X の反転（S = diag(−1, 1, 1)）で写す。glTF の正面 +Z は engine でも +Z のまま、
/// キャラの右手（glTF の −X）は engine の +X に来る。位置と法線は x を反転し、三角形の巡りを逆にする。
/// 回転は (x, −y, −z, w)、倍率はそのまま、行列（逆バインド行列・matrix のノード・rootTransform）は S·M·S。
/// 読まない物（Err）: 外の uri・data URI・sparse accessor・三角形以外の primitive・1 体 64 本を超えるジョイント。
/// 捨てて 1 回知らせる物: JOINTS_1 / WEIGHTS_1・ジョイントでないノードを動かす欄・CUBICSPLINE の接線。
// WhyNot: Mesh3d.fromObj と同じく反転せずに読まない — 左右の決まったキャラ（右手に剣）が鏡写しになる。
pub mod Gltf {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JNumber, JString}

    type alias Obj = Map[String, Json]

    /// GLB の中身: JSON の木と、元のバイトの中の BIN チャンクの場所。
    type alias Glb = { json = Obj, bytes = Vector[Int8], bin = Option[{ start = Int32, length = Int32 }] }

    /// 読んだ accessor（成分を平らに並べた値。normalized の物は 0..1 / −1..1 に直してある）。
    type alias Accessor = { count = Int32, width = Int32, componentType = Int32, values = Vector[Float64] }

    /// 読んだスキン。jointOfNode = ノードの番号 → 並べ替えた後のジョイントの番号・newOfOld = skin.joints の何番目か → 並べ替えた後の番号・
    /// bindWorlds = 並べ替えた後の番号ごとの、バインドの時のジョイントの world 行列（glTF の座標）。
    type alias SkinBuild = { skin = Skin3d.Skin3d, jointOfNode = Map[Int32, Int32], newOfOld = Vector[Int32], bindWorlds = Vector[Mat4.Mat4] }

    /// primitive の頂点をどのジョイントに付けるか。Skinned = JOINTS_0 / WEIGHTS_0 を読む・Rigid = 1 本に重み 1・NoSkin = 重みなし。
    enum Binding {
        case Skinned(Vector[Int32])
        case Rigid(Int32)
        case NoSkin
    }

    /// 頂点の欄（glTF の座標のまま）。
    type alias Part = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32],
                        joints = Vector[Int32], weights = Vector[Float64] }

    /// path の .glb を読む（Fs.FileRead.readBytes）。読めない・壊れている時は Err（パスつき）。
    pub def load(path: String): Result[String, Model3d.Model3d] \ Fs.FileRead =
        Fs.FileRead.readBytes(path)
            |> Result.mapErr(e -> "${path}: 読めない（${e}）")
            |> Result.flatMap(bytes -> fromGlb(bytes) |> Result.mapErr(e -> "${path}: ${e}"))

    /// .glb のバイトから作る。壊れている・読まない物を含む時は Err。
    pub def fromGlb(bytes: Vector[Int8]): Result[String, Model3d.Model3d] =
        forM (
            glb <- parseGlb(bytes);
            _ <- checkBuffers(glb#json);
            model <- buildModel(glb)
        ) yield Log.warnAllThen(warningsOf(glb#json, model#jointOfNode), model#model)

    // ── バイト ──────────────────────────────────────────────

    def u8(bytes: Vector[Int8], i: Int32): Int32 = Int32.bitwiseAnd(Int8.toInt32(Vector.get(i, bytes)), 0xFF)

    def u16(bytes: Vector[Int8], i: Int32): Int32 = u8(bytes, i) + u8(bytes, i + 1) * 256

    /// 4 バイトのリトルエンディアン（2^31 以上は負の数になる。長さとして読む所は負を Err にする）。
    def u32Bits(bytes: Vector[Int8], i: Int32): Int32 = Int32.bitwiseOr(u16(bytes, i), Int32.leftShift(u16(bytes, i + 2), 16))

    def i16(bytes: Vector[Int8], i: Int32): Int32 = let v = u16(bytes, i); if (v >= 32768) v - 65536 else v

    /// IEEE 754 の単精度のビットから組む。
    // WhyNot: java.lang.Float.intBitsToFloat を呼ばない — Java の呼び出しは IO の効果が付き、純粋な読み込みにならない。
    def float32OfBits(bits: Int32): Float64 =
        let sign = if (bits < 0) -1.0 else 1.0;
        let exponent = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 23, bits), 0xFF);
        let mantissa = Int32.toFloat64(Int32.bitwiseAnd(bits, 0x7FFFFF));
        if (exponent == 0) sign * mantissa * Float64.pow(base = 2.0, -149.0)
        else if (exponent == 255) (if (mantissa == 0.0) sign * Float64.positiveInfinity() else Float64.nan())
        else sign * (1.0 + mantissa / 8388608.0) * Float64.pow(base = 2.0, Int32.toFloat64(exponent - 127))

    def require(cond: Bool, message: String): Result[String, Unit] = if (cond) Ok(()) else Err(message)

    // ── チャンク ─────────────────────────────────────────────

    def parseGlb(bytes: Vector[Int8]): Result[String, Glb] =
        let n = Vector.length(bytes);
        if (n < 12) Err("GLB: 頭の 12 バイトが無い")
        else if (u32Bits(bytes, 0) != 0x46546C67) Err("GLB: magic が glTF でない")
        else if (u32Bits(bytes, 4) != 2) Err("GLB: version が 2 でない（${u32Bits(bytes, 4)}）")
        else {
            let total = u32Bits(bytes, 8);
            if (total < 12 or total > n) Err("GLB: 全体の長さ ${total} がバイトの数 ${n} と合わない（途中で切れている）")
            else readChunks(bytes, total, 12, None, None)
        }

    def readChunks(bytes: Vector[Int8], total: Int32, at: Int32, json: Option[Obj], bin: Option[{ start = Int32, length = Int32 }]): Result[String, Glb] =
        if (at >= total) match json {
            case Some(j) => Ok({ json = j, bytes = bytes, bin = bin })
            case None => Err("GLB: JSON のチャンクが無い")
        }
        else if (total - at < 8) Err("GLB: チャンクの頭が途中で切れている")
        else {
            let length = u32Bits(bytes, at);
            let kind = u32Bits(bytes, at + 4);
            let start = at + 8;
            if (length < 0 or length > total - start) Err("GLB: チャンクが途中で切れている")
            else if (kind == 0x4E4F534A and Option.isEmpty(json))
                Result.flatMap(j -> readChunks(bytes, total, start + length, Some(j), bin), parseJson(bytes, start, length))
            else if (kind == 0x004E4942 and Option.isEmpty(bin))
                readChunks(bytes, total, start + length, json, Some({ start = start, length = length }))
            else readChunks(bytes, total, start + length, json, bin)
        }

    // 後ろの空白の詰め物は trim で落ちる。
    def parseJson(bytes: Vector[Int8], start: Int32, length: Int32): Result[String, Obj] =
        let text = String.fromBytes(Vector.slice(start = start, end = start + length, bytes)) |> String.trim;
        match Util.Json.parse(text) {
            case Ok(JObject(m)) => Ok(m)
            case Ok(_) => Err("GLB: JSON の頭がオブジェクトでない")
            case Err(e) => Err("GLB: JSON が読めない（${e}）")
        }

    def checkBuffers(json: Obj): Result[String, Unit] =
        if (objectsOf("buffers", json) |> Vector.exists(b -> Map.memberOf("uri", b)))
            Err("glTF: uri を持つバッファ（外のファイル・data URI）は読まない（.glb の BIN だけを読む）")
        else Ok(())

    // ── JSON ────────────────────────────────────────────────

    def objectsOf(key: String, o: Obj): Vector[Obj] = match Map.get(key, o) {
        case Some(JArray(items)) => Vector.map(item -> match item {
            case JObject(m) => m
            case _ => Map.empty()
        }, items)
        case _ => Vector.empty()
    }

    def objectOf(key: String, o: Obj): Obj = match Map.get(key, o) {
        case Some(JObject(m)) => m
        case _ => Map.empty()
    }

    def objectAt(kind: String, index: Int32, o: Obj): Result[String, Obj] =
        Vector.nth(index, objectsOf(kind, o)) |> Option.toOk("glTF: ${kind}[${index}] が無い")

    def intOf(key: String, o: Obj): Option[Int32] = match Map.get(key, o) {
        case Some(JNumber(d)) => BigDecimal.tryToInt32(d)
        case _ => None
    }

    def stringOf(key: String, o: Obj): Option[String] = match Map.get(key, o) {
        case Some(JString(s)) => Some(s)
        case _ => None
    }

    def numberOf(j: Json): Option[Float64] = match j {
        case JNumber(d) => BigDecimal.tryToFloat64(d)
        case _ => None
    }

    def intsOf(key: String, o: Obj): Vector[Int32] = match Map.get(key, o) {
        case Some(JArray(items)) => Vector.filterMap(item -> match item {
            case JNumber(d) => BigDecimal.tryToInt32(d)
            case _ => None
        }, items)
        case _ => Vector.empty()
    }

    /// 数の並び（無ければ None・数でない物や長さ違いは Err）。
    def numbersOf(key: String, width: Int32, o: Obj): Result[String, Option[Vector[Float64]]] = match Map.get(key, o) {
        case None => Ok(None)
        case Some(JArray(items)) =>
            let nums = Vector.filterMap(numberOf, items);
            if (Vector.length(nums) != width or Vector.length(items) != width) Err("glTF: ${key} が ${width} 個の数でない")
            else Ok(Some(nums))
        case Some(_) => Err("glTF: ${key} が数の並びでない")
    }

    // ── accessor ────────────────────────────────────────────

    def widthOfType(t: Option[String]): Result[String, Int32] = match t {
        case Some("SCALAR") => Ok(1)
        case Some("VEC2") => Ok(2)
        case Some("VEC3") => Ok(3)
        case Some("VEC4") => Ok(4)
        case Some("MAT4") => Ok(16)
        case Some(other) => Err("glTF: accessor の type ${other} は読まない")
        case None => Err("glTF: accessor に type が無い")
    }

    def componentSize(componentType: Int32): Result[String, Int32] = match componentType {
        case 5120 => Ok(1)
        case 5121 => Ok(1)
        case 5122 => Ok(2)
        case 5123 => Ok(2)
        case 5125 => Ok(4)
        case 5126 => Ok(4)
        case other => Err("glTF: componentType ${other} は読まない")
    }

    /// 1 つの成分。normalized なら仕様の式で 0..1（符号なし）/ −1..1（符号つき）に直す。
    def readComponent(bytes: Vector[Int8], componentType: Int32, normalized: Bool, at: Int32): Float64 = match componentType {
        case 5126 => float32OfBits(u32Bits(bytes, at))
        case 5121 => let v = Int32.toFloat64(u8(bytes, at)); if (normalized) v / 255.0 else v
        case 5123 => let v = Int32.toFloat64(u16(bytes, at)); if (normalized) v / 65535.0 else v
        case 5120 => let v = Int32.toFloat64(Int8.toInt32(Vector.get(at, bytes))); if (normalized) Float64.max(v / 127.0, -1.0) else v
        case 5122 => let v = Int32.toFloat64(i16(bytes, at)); if (normalized) Float64.max(v / 32767.0, -1.0) else v
        case _ => Int64.toFloat64(Int64.bitwiseAnd(Int32.toInt64(u32Bits(bytes, at)), 0xFFFFFFFFi64))
    }

    def readAccessor(glb: Glb, index: Int32): Result[String, Accessor] =
        forM (
            acc <- objectAt("accessors", index, glb#json);
            _ <- require(not Map.memberOf("sparse", acc), "glTF: accessors[${index}] の sparse は読まない");
            viewIndex <- intOf("bufferView", acc) |> Option.toOk("glTF: accessors[${index}] に bufferView が無い");
            view <- objectAt("bufferViews", viewIndex, glb#json);
            _ <- require(Option.getWithDefault(0, intOf("buffer", view)) == 0, "glTF: bufferViews[${viewIndex}] が buffers[0] 以外を指す");
            bin <- glb#bin |> Option.toOk("glTF: BIN のチャンクが無い");
            width <- widthOfType(stringOf("type", acc));
            componentType <- intOf("componentType", acc) |> Option.toOk("glTF: accessors[${index}] に componentType が無い");
            size <- componentSize(componentType);
            count <- intOf("count", acc) |> Option.toOk("glTF: accessors[${index}] に count が無い");
            values <- readValues(glb#bytes, bin, view, acc, { index = index, count = count, width = width, componentType = componentType, size = size })
        ) yield { count = count, width = width, componentType = componentType, values = values }

    def readValues(bytes: Vector[Int8], bin: { start = Int32, length = Int32 }, view: Obj, acc: Obj,
                   shape: { index = Int32, count = Int32, width = Int32, componentType = Int32, size = Int32 }): Result[String, Vector[Float64]] =
        let viewOffset = Option.getWithDefault(0, intOf("byteOffset", view));
        let viewLength = Option.getWithDefault(-1, intOf("byteLength", view));
        let accOffset = Option.getWithDefault(0, intOf("byteOffset", acc));
        let elementSize = shape#size * shape#width;
        let stride = Option.getWithDefault(elementSize, intOf("byteStride", view));
        let need = if (shape#count == 0) 0i64
                   else Int32.toInt64(accOffset) + Int32.toInt64(stride) * Int32.toInt64(shape#count - 1) + Int32.toInt64(elementSize);
        let normalized = Map.get("normalized", acc) == Some(Util.Json.Json.JBool(true));
        let base = bin#start + viewOffset + accOffset;
        if (viewOffset < 0 or viewLength < 0 or accOffset < 0 or shape#count < 0 or viewOffset > bin#length or viewLength > bin#length - viewOffset)
            Err("glTF: accessors[${shape#index}] の bufferView が BIN の外を指す（途中で切れている）")
        else if (stride < elementSize) Err("glTF: accessors[${shape#index}] の byteStride ${stride} が 1 頂点の大きさ ${elementSize} より小さい")
        else if (need > Int32.toInt64(viewLength)) Err("glTF: accessors[${shape#index}] が bufferView の外まで続く（途中で切れている）")
        else
            Ok(Vector.range(0, shape#count * shape#width) |> Vector.map(k -> {
                let i = k / shape#width;
                let c = k - i * shape#width;
                readComponent(bytes, shape#componentType, normalized, base + i * stride + c * shape#size)
            }))

    def readAccessorWidth(glb: Glb, index: Int32, width: Int32, what: String): Result[String, Accessor] =
        Result.flatMap(a -> if (a#width == width) Ok(a) else Err("glTF: ${what} の accessor の幅が ${a#width}（${width} のはず）"),
                       readAccessor(glb, index))

    // ── ノードと座標の写し方 ─────────────────────────────────

    def mirror(): Mat4.Mat4 = Mat4.scale(Vec3.v3(-1.0, 1.0, 1.0))

    /// S·M·S（glTF の座標の行列 → engine の座標の行列）。
    def mirrorMat4(m: Mat4.Mat4): Mat4.Mat4 = Mat4.mul(mirror(), Mat4.mul(m, mirror()))

    def mirrorPose(p: Skin3d.JointPose): Skin3d.JointPose =
        { translation = Vec3.v3(0.0 - p#translation#x, p#translation#y, p#translation#z),
          rotation = { x = p#rotation#x, y = 0.0 - p#rotation#y, z = 0.0 - p#rotation#z, w = p#rotation#w },
          scale = p#scale }

    /// ノードの局所の姿勢（glTF の座標）。matrix のノードは平行移動・回転・倍率に分ける。
    def nodePose(node: Obj): Result[String, Skin3d.JointPose] =
        forM (
            matrix <- numbersOf("matrix", 16, node);
            t <- numbersOf("translation", 3, node);
            r <- numbersOf("rotation", 4, node);
            s <- numbersOf("scale", 3, node)
        ) yield match matrix {
            case Some(cells) => decompose(cells)
            case None =>
                { translation = Option.map(v -> vec3At(v, 0), t) |> Option.getWithDefault(Vec3.zero()),
                  rotation = Option.map(v -> quatOf(v), r) |> Option.getWithDefault(Quat.identity()),
                  scale = Option.map(v -> vec3At(v, 0), s) |> Option.getWithDefault(Vec3.one()) }
        }

    def nodeMatrix(node: Obj): Result[String, Mat4.Mat4] =
        Result.flatMap(matrix -> match matrix {
            case Some(cells) => Mat4.ofColumns(cells)
            case None => Result.map(Skin3d.jointPoseToMat4, nodePose(node))
        }, numbersOf("matrix", 16, node))

    /// 列優先の 16 個を平行移動・回転・倍率に分ける（行列式が負なら x の倍率を負にする）。
    def decompose(cells: Vector[Float64]): Skin3d.JointPose =
        let c = i -> Vector.get(i, cells);
        let len = (i: Int32) -> Vec2.sqrt(c(i) * c(i) + c(i + 1) * c(i + 1) + c(i + 2) * c(i + 2));
        let det = c(0) * (c(5) * c(10) - c(9) * c(6)) - c(4) * (c(1) * c(10) - c(9) * c(2)) + c(8) * (c(1) * c(6) - c(5) * c(2));
        let sx = if (det < 0.0) 0.0 - len(0) else len(0);
        let sy = len(4);
        let sz = len(8);
        let safe = s -> if (Float64.abs(s) < 1.0e-12) 1.0 else s;
        let m = (row: Int32, col: Int32) -> c(col * 4 + row) / safe(if (col == 0) sx else if (col == 1) sy else sz);
        { translation = Vec3.v3(c(12), c(13), c(14)), rotation = quatOfRotation(m), scale = Vec3.v3(sx, sy, sz) }

    def quatOfRotation(m: (Int32, Int32) -> Float64): Quat.Quat =
        let trace = m(0, 0) + m(1, 1) + m(2, 2);
        let q =
            if (trace > 0.0) {
                let s = Vec2.sqrt(trace + 1.0) * 2.0;
                { x = (m(2, 1) - m(1, 2)) / s, y = (m(0, 2) - m(2, 0)) / s, z = (m(1, 0) - m(0, 1)) / s, w = 0.25 * s }
            } else if (m(0, 0) > m(1, 1) and m(0, 0) > m(2, 2)) {
                let s = Vec2.sqrt(1.0 + m(0, 0) - m(1, 1) - m(2, 2)) * 2.0;
                { x = 0.25 * s, y = (m(0, 1) + m(1, 0)) / s, z = (m(0, 2) + m(2, 0)) / s, w = (m(2, 1) - m(1, 2)) / s }
            } else if (m(1, 1) > m(2, 2)) {
                let s = Vec2.sqrt(1.0 + m(1, 1) - m(0, 0) - m(2, 2)) * 2.0;
                { x = (m(0, 1) + m(1, 0)) / s, y = 0.25 * s, z = (m(1, 2) + m(2, 1)) / s, w = (m(0, 2) - m(2, 0)) / s }
            } else {
                let s = Vec2.sqrt(1.0 + m(2, 2) - m(0, 0) - m(1, 1)) * 2.0;
                { x = (m(0, 2) + m(2, 0)) / s, y = (m(1, 2) + m(2, 1)) / s, z = 0.25 * s, w = (m(1, 0) - m(0, 1)) / s }
            };
        Quat.normalized(q)

    def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 = Vec3.v3(Vector.get(k, v), Vector.get(k + 1, v), Vector.get(k + 2, v))

    def quatOf(v: Vector[Float64]): Quat.Quat = { x = Vector.get(0, v), y = Vector.get(1, v), z = Vector.get(2, v), w = Vector.get(3, v) }

    /// ノードの番号 → 親のノードの番号。
    def parentsOfNodes(nodes: Vector[Obj]): Map[Int32, Int32] =
        Vector.range(0, Vector.length(nodes)) |> Vector.foldLeft((m, i) ->
            intsOf("children", Vector.get(i, nodes)) |> Vector.foldLeft((acc, child) -> Map.insert(child, i, acc), m), Map.empty())

    /// 根からノードまでの祖先の列（根が先・自分を含む）。輪になった木は Err。
    def chainOf(parentOf: Map[Int32, Int32], limit: Int32, node: Int32): Result[String, List[Int32]] =
        chainLoop(parentOf, limit, node, Nil)

    def chainLoop(parentOf: Map[Int32, Int32], limit: Int32, node: Int32, acc: List[Int32]): Result[String, List[Int32]] =
        if (List.length(acc) > limit) Err("glTF: ノードの木が輪になっている")
        else match Map.get(node, parentOf) {
            case Some(p) => chainLoop(parentOf, limit, p, node :: acc)
            case None => Ok(node :: acc)
        }

    /// 並んだノードの局所の行列を根から掛けた物（glTF の座標）。
    def productOf(nodes: Vector[Obj], chain: List[Int32]): Result[String, Mat4.Mat4] =
        chain
            |> Result.traverse(i -> Vector.nth(i, nodes) |> Option.toOk("glTF: nodes[${i}] が無い") |> Result.flatMap(nodeMatrix))
            |> Result.map(List.foldLeft(Mat4.mul, Mat4.identity()))

    // ── スキン ──────────────────────────────────────────────

    def buildSkin(glb: Glb, nodes: Vector[Obj], parentOf: Map[Int32, Int32], skinIndex: Int32): Result[String, SkinBuild] =
        forM (
            skinObj <- objectAt("skins", skinIndex, glb#json);
            jointNodes <- Ok(intsOf("joints", skinObj));
            _ <- require(Vector.length(jointNodes) > 0, "glTF: skins[${skinIndex}] にジョイントが無い");
            _ <- require(Vector.length(jointNodes) <= Skin3d.maxJoints(),
                         "glTF: skins[${skinIndex}] のジョイントが ${Vector.length(jointNodes)} 本（上限 ${Skin3d.maxJoints()} 本）");
            oldOfNode <- Ok(Vector.range(0, Vector.length(jointNodes)) |> Vector.foldLeft((m, k) -> Map.insert(Vector.get(k, jointNodes), k, m), Map.empty()));
            chains <- Vector.toList(jointNodes) |> Result.traverse(chainOf(parentOf, Vector.length(nodes)));
            links <- List.zip(List.range(0, Vector.length(jointNodes)), chains) |> Result.traverse(pair -> linkOf(oldOfNode, snd(pair)));
            rootGl <- rootTransformOf(nodes, links);
            ibmsGl <- inverseBindsOf(glb, skinObj, Vector.length(jointNodes));
            built <- assembleSkin(nodes, jointNodes, List.toVector(links), rootGl, ibmsGl)
        ) yield built

    /// ジョイント 1 本の、親のジョイント（skin.joints の何番目か）と、根なら上のジョイントでないノード。
    /// depth = 上にあるジョイントの数。
    type alias Link = { parent = Option[Int32], above = Option[Int32], depth = Int32 }

    // chain は根が先で、最後が自分。
    def linkOf(oldOfNode: Map[Int32, Int32], chain: List[Int32]): Result[String, Link] =
        let ancestors = List.reverse(chain) |> List.drop(1);
        let depth = ancestors |> List.count(n -> Map.memberOf(n, oldOfNode));
        match ancestors {
            case Nil => Ok({ parent = None, above = None, depth = 0 })
            case p :: _ =>
                match Map.get(p, oldOfNode) {
                    case Some(k) => Ok({ parent = Some(k), above = None, depth = depth })
                    case None =>
                        if (depth > 0) Err("glTF: ジョイントとその親のジョイントの間に、ジョイントでないノード（nodes[${p}]）が挟まる")
                        else Ok({ parent = None, above = Some(p), depth = 0 })
                }
        }

    def rootTransformOf(nodes: Vector[Obj], links: List[Link]): Result[String, Mat4.Mat4] =
        let aboves = links |> List.filter(l -> Option.isEmpty(l#parent)) |> List.map(l -> l#above) |> List.toSet;
        if (Set.size(aboves) > 1) Err("glTF: 根のジョイントが複数あり、それぞれ別のジョイントでない祖先を持つ")
        else match Set.toList(aboves) {
            case Some(above) :: _ => Result.flatMap(chain -> productOf(nodes, chain), chainOf(parentsOfNodes(nodes), Vector.length(nodes), above))
            case _ => Ok(Mat4.identity())
        }

    def inverseBindsOf(glb: Glb, skinObj: Obj, count: Int32): Result[String, Vector[Mat4.Mat4]] =
        match intOf("inverseBindMatrices", skinObj) {
            case None => Ok(Vector.range(0, count) |> Vector.map(_ -> Mat4.identity()))
            case Some(index) =>
                forM (
                    acc <- readAccessorWidth(glb, index, 16, "inverseBindMatrices");
                    _ <- require(acc#count == count, "glTF: inverseBindMatrices の数 ${acc#count} がジョイントの数 ${count} と違う");
                    mats <- Vector.toList(Vector.range(0, count)) |> Result.traverse(k ->
                                Mat4.ofColumns(Vector.slice(start = k * 16, end = k * 16 + 16, acc#values)))
                ) yield List.toVector(mats)
        }

    // WhyNot: List.sortBy に深さだけを渡さない — 安定ソートではないので、同じ深さのジョイントの並びが skin.joints の順にならない。
    def assembleSkin(nodes: Vector[Obj], jointNodes: Vector[Int32], links: Vector[Link],
                     rootGl: Mat4.Mat4, ibmsGl: Vector[Mat4.Mat4]): Result[String, SkinBuild] =
        let count = Vector.length(jointNodes);
        let order = List.range(0, count) |> List.sortBy(k -> (Vector.get(k, links)#depth, k)) |> List.toVector;
        let newOfOld = order |> Vector.mapWithIndex((newIndex, old) -> (old, newIndex))
                             |> Vector.foldLeft((m, pair) -> Map.insert(fst(pair), snd(pair), m), Map.empty());
        let newOf = (old: Int32) -> Map.getWithDefault(old, 0, newOfOld);
        let names = order |> Vector.map(old -> {
            let node = Vector.get(Vector.get(old, jointNodes), nodes);
            stringOf("name", node) |> Option.getWithDefault("joint${old}")
        });
        let parents = order |> Vector.map(old -> Vector.get(old, links)#parent |> Option.map(newOf) |> Option.getWithDefault(-1));
        let bindsGl = order |> Vector.map(old -> Vector.get(old, ibmsGl));
        forM (
            restGl <- Vector.toList(order) |> Result.traverse(old ->
                          Vector.nth(Vector.get(old, jointNodes), nodes) |> Option.toOk("glTF: ジョイントのノードが無い") |> Result.flatMap(nodePose));
            bindWorlds <- Vector.toList(bindsGl) |> Result.traverse(m ->
                              Mat4.inverse(m) |> Option.toOk("glTF: 逆バインド行列に逆行列が無い"));
            skin <- Skin3d.make({ names = names, parents = parents, rest = List.toVector(List.map(mirrorPose, restGl)),
                                  inverseBinds = Some(Vector.map(mirrorMat4, bindsGl)), rootTransform = mirrorMat4(rootGl) })
        ) yield {
            skin = skin,
            jointOfNode = Vector.range(0, count) |> Vector.foldLeft((m, old) -> Map.insert(Vector.get(old, jointNodes), newOf(old), m), Map.empty()),
            newOfOld = Vector.range(0, count) |> Vector.map(newOf),
            bindWorlds = List.toVector(bindWorlds)
        }

    // ── メッシュ ────────────────────────────────────────────

    def buildModel(glb: Glb): Result[String, { model = Model3d.Model3d, jointOfNode = Map[Int32, Int32] }] =
        let nodes = objectsOf("nodes", glb#json);
        let parentOf = parentsOfNodes(nodes);
        let meshNodes = Vector.range(0, Vector.length(nodes)) |> Vector.filter(i -> Map.memberOf("mesh", Vector.get(i, nodes)));
        let skinIndices = meshNodes |> Vector.filterMap(i -> intOf("skin", Vector.get(i, nodes))) |> Vector.toList |> List.toSet;
        if (Vector.isEmpty(meshNodes)) Err("glTF: メッシュを持つノードが無い")
        else if (Set.size(skinIndices) > 1) Err("glTF: スキンのあるメッシュのノードが、別々のスキンを指す")
        else {
            let skinR = match Set.toList(skinIndices) {
                case k :: _ => Result.map(Some, buildSkin(glb, nodes, parentOf, k))
                case Nil => Ok(None)
            };
            forM (
                skinBuild <- skinR;
                parts <- Vector.toList(meshNodes) |> Result.traverse(i -> nodeParts(glb, nodes, parentOf, skinBuild, i));
                mesh <- meshOfParts(List.flatten(parts), Option.nonEmpty(skinBuild));
                clips <- readAnimations(glb, Option.map(b -> b#jointOfNode, skinBuild) |> Option.getWithDefault(Map.empty()))
            ) yield {
                model = { mesh = mesh, skin = Option.map(b -> b#skin, skinBuild), clips = clips },
                jointOfNode = Option.map(b -> b#jointOfNode, skinBuild) |> Option.getWithDefault(Map.empty())
            }
        }

    /// メッシュのノード 1 つの primitive の列。
    ///   - skin のあるノード: 変換を無視し（仕様の MUST）、JOINTS_0 / WEIGHTS_0 を読む
    ///   - ジョイントの子孫: バインドの時のジョイントの world 行列 × ジョイントから下の局所の鎖で写し、そのジョイントに重み 1
    ///   - ほか: world 行列を焼き込む（スキンがあれば根のジョイントに重み 1）
    def nodeParts(glb: Glb, nodes: Vector[Obj], parentOf: Map[Int32, Int32], skinBuild: Option[SkinBuild], i: Int32): Result[String, List[Part]] =
        let node = Vector.get(i, nodes);
        let jointOfNode = Option.map(b -> b#jointOfNode, skinBuild) |> Option.getWithDefault(Map.empty());
        let placementR: Result[String, (Mat4.Mat4, Binding)] = match (skinBuild, intOf("skin", node)) {
            case (Some(b), Some(_)) => Ok((Mat4.identity(), Binding.Skinned(b#newOfOld)))
            case _ =>
                Result.flatMap(chain -> {
                    let fromTop = List.reverse(chain);
                    let below = List.takeWhile(n -> not Map.memberOf(n, jointOfNode), fromTop);
                    match (skinBuild, List.drop(List.length(below), fromTop)) {
                        case (Some(b), joint :: _) =>
                            let j = Map.getWithDefault(joint, 0, jointOfNode);
                            Result.map(local -> (Mat4.mul(Vector.get(j, b#bindWorlds), local), Binding.Rigid(j)), productOf(nodes, List.reverse(below)))
                        case (Some(_), Nil) => Result.map(world -> (world, Binding.Rigid(0)), productOf(nodes, chain))
                        case (None, _) => Result.map(world -> (world, Binding.NoSkin), productOf(nodes, chain))
                    }
                }, chainOf(parentOf, Vector.length(nodes), i))
        };
        forM (
            placement <- placementR;
            meshIndex <- intOf("mesh", node) |> Option.toOk("glTF: nodes[${i}] の mesh が数でない");
            meshObj <- objectAt("meshes", meshIndex, glb#json);
            parts <- objectsOf("primitives", meshObj) |> Vector.toList |> Result.traverse(prim -> readPrimitive(glb, fst(placement), snd(placement), prim))
        ) yield parts

    def readPrimitive(glb: Glb, transform: Mat4.Mat4, binding: Binding, prim: Obj): Result[String, Part] =
        let attributes = objectOf("attributes", prim);
        let mode = Option.getWithDefault(4, intOf("mode", prim));
        forM (
            _ <- require(mode == 4, "glTF: primitive の mode ${mode} は読まない（三角形 = 4 だけ）");
            positionIndex <- intOf("POSITION", attributes) |> Option.toOk("glTF: primitive に POSITION が無い");
            positions <- readAccessorWidth(glb, positionIndex, 3, "POSITION");
            normals <- traverseOpt(intOf("NORMAL", attributes), k -> readAccessorWidth(glb, k, 3, "NORMAL"));
            indices <- traverseOpt(intOf("indices", prim), k -> readAccessorWidth(glb, k, 1, "indices"));
            skin <- readSkinAttributes(glb, attributes, binding, positions#count);
            color <- baseColorOf(glb, prim)
        ) yield {
            let count = positions#count;
            let indexList = match indices {
                case Some(a) => Vector.map(toIndex, a#values)
                case None => Vector.range(0, count)
            };
            let normalMat = Mat4.normalMatrix(transform);
            let placedPositions = Vector.range(0, count) |> Vector.flatMap(v -> xyzOf(Mat4.apply(transform, vec3At(positions#values, v * 3))));
            let placedNormals = Option.map(n -> Vector.range(0, count) |> Vector.flatMap(v ->
                xyzOf(Vec3.normalized(Mat4.applyDir(normalMat, vec3At(n#values, v * 3))))), normals);
            let part = { positions = placedPositions, normals = Option.getWithDefault(Vector.empty(), placedNormals),
                         colors = Vector.range(0, count) |> Vector.flatMap(_ -> color), indices = indexList,
                         joints = fst(skin), weights = snd(skin) };
            if (Option.nonEmpty(normals)) part else flatShaded(part)
        }

    def traverseOpt(o: Option[Int32], f: Int32 -> Result[String, a]): Result[String, Option[a]] = match o {
        case Some(k) => Result.map(Some, f(k))
        case None => Ok(None)
    }

    def xyzOf(v: Vec3.Vec3): Vector[Float64] = Vector#{ v#x, v#y, v#z }

    /// 頂点ごとの 4 つのジョイントの番号（並べ替えた後）と重み。重みの無い形は空。
    def readSkinAttributes(glb: Glb, attributes: Obj, binding: Binding, count: Int32): Result[String, (Vector[Int32], Vector[Float64])] =
        let rigid = (j: Int32) -> Ok((Vector.range(0, count) |> Vector.flatMap(_ -> Vector#{ j, 0, 0, 0 }),
                                      Vector.range(0, count) |> Vector.flatMap(_ -> Vector#{ 1.0, 0.0, 0.0, 0.0 })));
        match binding {
            case Binding.NoSkin => Ok((Vector.empty(), Vector.empty()))
            case Binding.Rigid(j) => rigid(j)
            case Binding.Skinned(newOfOld) => match (intOf("JOINTS_0", attributes), intOf("WEIGHTS_0", attributes)) {
                case (Some(jk), Some(wk)) =>
                    forM (
                        joints <- readAccessorWidth(glb, jk, 4, "JOINTS_0");
                        _ <- require(joints#componentType == 5121 or joints#componentType == 5123,
                                     "glTF: JOINTS_0 の componentType ${joints#componentType} は読まない（UNSIGNED_BYTE か UNSIGNED_SHORT）");
                        weights <- readAccessorWidth(glb, wk, 4, "WEIGHTS_0");
                        _ <- require(joints#count == count and weights#count == count, "glTF: JOINTS_0 / WEIGHTS_0 の数が頂点の数と違う");
                        remapped <- Vector.toList(joints#values) |> Result.traverse(old ->
                                        Vector.nth(toIndex(old), newOfOld) |> Option.toOk("glTF: JOINTS_0 の番号 ${old} がジョイントの数の外"))
                    ) yield (List.toVector(remapped), weights#values)
                case _ => rigid(0)
            }
        }

    /// baseColorFactor をそのまま頂点の色にする。材質や baseColorFactor が無ければ白。
    // WhyNot: 1/2.2 乗で直さない — engine の光は色の値をそのまま掛ける式で、OBJ の Kd も Blender の値をそのまま使う。
    //   直すと同じ Blender の色が glTF だけ明るく白っぽく出る。
    def baseColorOf(glb: Glb, prim: Obj): Result[String, Vector[Float64]] =
        let white = Vector#{ 1.0, 1.0, 1.0 };
        match intOf("material", prim) {
            case None => Ok(white)
            case Some(k) => Result.flatMap(material ->
                Result.map(factor -> match factor {
                    case Some(rgba) => Vector.take(3, rgba) |> Vector.map(c -> Float64.max(0.0, Float64.min(1.0, c)))
                    case None => white
                }, numbersOf("baseColorFactor", 4, objectOf("pbrMetallicRoughness", material))), objectAt("materials", k, glb#json))
        }

    /// 法線の無い primitive は、三角形ごとに頂点を分けて面の法線を付ける（glTF の表は外から見て反時計回り）。
    def flatShaded(part: Part): Part =
        let tris = Vector.length(part#indices) / 3;
        let corner = (t: Int32, c: Int32) -> Vector.get(t * 3 + c, part#indices);
        let corners = Vector.range(0, tris * 3) |> Vector.map(k -> corner(k / 3, k - (k / 3) * 3));
        let normals = Vector.range(0, tris) |> Vector.flatMap(t -> {
            let p = c -> vec3At(part#positions, corner(t, c) * 3);
            let n = xyzOf(Vec3.normalized(Vec3.cross(Vec3.sub(p(1), p(0)), Vec3.sub(p(2), p(0)))));
            Vector.flatten(Vector#{ n, n, n })
        });
        let hasSkin = not Vector.isEmpty(part#joints);
        { positions = Vector.flatMap(v -> sliceAt(3, part#positions, v), corners),
          normals = normals,
          colors = Vector.flatMap(v -> sliceAt(3, part#colors, v), corners),
          indices = Vector.range(0, tris * 3),
          joints = if (hasSkin) Vector.flatMap(v -> sliceAt(4, part#joints, v), corners) else Vector.empty(),
          weights = if (hasSkin) Vector.flatMap(v -> sliceAt(4, part#weights, v), corners) else Vector.empty() }

    def sliceAt(width: Int32, src: Vector[a], v: Int32): Vector[a] = Vector.slice(start = v * width, end = v * width + width, src)

    def concatOf(f: Part -> Vector[a], parts: List[Part]): Vector[a] = Vector.flatten(List.toVector(List.map(f, parts)))

    /// 番号として読む（Int32 に入らない値は -1 にして、後の範囲の確かめで Err にする）。
    def toIndex(x: Float64): Int32 = Float64.tryToInt32(x) |> Option.getWithDefault(-1)

    /// primitive をつなぎ、X を反転して巡りを逆にする。
    def meshOfParts(parts: List[Part], skinned: Bool): Result[String, Mesh3d.Mesh3d] =
        let (_, revIndices) = parts |> List.foldLeft((acc, part) -> {
            let (base, out) = acc;
            (base + Vector.length(part#positions) / 3, Vector.map(i -> i + base, part#indices) :: out)
        }, (0, Nil));
        let flipX = (v: Vector[Float64]) -> Vector.mapWithIndex((k, x) -> if (Int32.remainder(k, 3) == 0) 0.0 - x else x, v);
        let indices = Vector.flatten(List.toVector(List.reverse(revIndices)));
        let rewound = Vector.range(0, Vector.length(indices)) |> Vector.map(k -> {
            let corner = Int32.remainder(k, 3);
            let at = if (corner == 1) k + 1 else if (corner == 2) k - 1 else k;
            Vector.get(at, indices)
        });
        Mesh3d.fromArrays({
            positions = flipX(concatOf(p -> p#positions, parts)),
            normals = flipX(concatOf(p -> p#normals, parts)),
            colors = concatOf(p -> p#colors, parts),
            indices = rewound,
            skin = if (skinned) Some({ joints = concatOf(p -> p#joints, parts), weights = concatOf(p -> p#weights, parts) }) else None
        }) |> Result.mapErr(e -> "glTF: ${e}")

    // ── アニメーション ──────────────────────────────────────

    def readAnimations(glb: Glb, jointOfNode: Map[Int32, Int32]): Result[String, Map[String, AnimationClip3d.AnimationClip3d]] =
        objectsOf("animations", glb#json)
            |> Vector.toList
            |> List.zip(List.range(0, Vector.length(objectsOf("animations", glb#json))))
            |> Result.traverse(pair -> {
                let (k, anim) = pair;
                let name = stringOf("name", anim) |> Option.getWithDefault("animation${k}");
                Result.flatMap(channels -> AnimationClip3d.make(name, List.filterMap(identity, channels)) |> Result.mapErr(e -> "glTF: ${e}"),
                               objectsOf("channels", anim) |> Vector.toList |> Result.traverse(readChannel(glb, jointOfNode, anim)))
            })
            |> Result.map(clips -> List.foldLeft((m, c) -> Map.insert(AnimationClip3d.name(c), c, m), Map.empty(), clips))

    def pathOf(s: Option[String]): Option[AnimationClip3d.Path] = match s {
        case Some("translation") => Some(AnimationClip3d.Path.Translation)
        case Some("rotation") => Some(AnimationClip3d.Path.Rotation)
        case Some("scale") => Some(AnimationClip3d.Path.Scale)
        case _ => None
    }

    /// 1 本の欄。weights・ジョイントでないノードの欄は None（捨てる）。
    def readChannel(glb: Glb, jointOfNode: Map[Int32, Int32], anim: Obj, ch: Obj): Result[String, Option[AnimationClip3d.Channel]] =
        let target = objectOf("target", ch);
        let joint = intOf("node", target) |> Option.flatMap(n -> Map.get(n, jointOfNode));
        match (pathOf(stringOf("path", target)), joint) {
            case (Some(path), Some(j)) =>
                let width = match path {
                    case AnimationClip3d.Path.Rotation => 4
                    case _ => 3
                };
                forM (
                    samplerIndex <- intOf("sampler", ch) |> Option.toOk("glTF: channel に sampler が無い");
                    sampler <- Vector.nth(samplerIndex, objectsOf("samplers", anim)) |> Option.toOk("glTF: samplers[${samplerIndex}] が無い");
                    inputIndex <- intOf("input", sampler) |> Option.toOk("glTF: sampler に input が無い");
                    outputIndex <- intOf("output", sampler) |> Option.toOk("glTF: sampler に output が無い");
                    times <- readAccessorWidth(glb, inputIndex, 1, "sampler の input");
                    output <- readAccessorWidth(glb, outputIndex, width, "sampler の output");
                    keyed <- keyValuesOf(stringOf("interpolation", sampler), width, times#count, output#values)
                ) yield {
                    let (interpolation, values) = keyed;
                    Some({ joint = j, path = path, times = times#values, values = mirrorValues(path, values), interpolation = interpolation })
                }
            case _ => Ok(None)
        }

    /// つなぎ方とキーフレームの値。CUBICSPLINE は (入り, 値, 出) の 3 つ組の真ん中を取って Linear にする。
    def keyValuesOf(interpolation: Option[String], width: Int32, count: Int32, values: Vector[Float64]): Result[String, (AnimationClip3d.Interpolation, Vector[Float64])] =
        match interpolation {
            case None => Ok((AnimationClip3d.Interpolation.Linear, values))
            case Some("LINEAR") => Ok((AnimationClip3d.Interpolation.Linear, values))
            case Some("STEP") => Ok((AnimationClip3d.Interpolation.Step, values))
            case Some("CUBICSPLINE") =>
                if (Vector.length(values) != count * 3 * width) Err("glTF: CUBICSPLINE の output が times の数 × 3 でない")
                else Ok((AnimationClip3d.Interpolation.Linear,
                         Vector.range(0, count) |> Vector.flatMap(k -> Vector.slice(start = (k * 3 + 1) * width, end = (k * 3 + 2) * width, values))))
            case Some(other) => Err("glTF: interpolation ${other} は読まない")
        }

    def mirrorValues(path: AnimationClip3d.Path, values: Vector[Float64]): Vector[Float64] = match path {
        case AnimationClip3d.Path.Translation => Vector.mapWithIndex((k, v) -> if (Int32.remainder(k, 3) == 0) 0.0 - v else v, values)
        case AnimationClip3d.Path.Rotation =>
            Vector.mapWithIndex((k, v) -> { let c = Int32.remainder(k, 4); if (c == 1 or c == 2) 0.0 - v else v }, values)
        case AnimationClip3d.Path.Scale => values
    }

    // ── 知らせ ──────────────────────────────────────────────

    /// 捨てた物を種類ごとに 1 行。
    def warningsOf(json: Obj, jointOfNode: Map[Int32, Int32]): List[String] =
        let prims = objectsOf("meshes", json) |> Vector.flatMap(m -> objectsOf("primitives", m));
        let extraWeights = prims |> Vector.exists(p -> {
            let a = objectOf("attributes", p);
            Map.memberOf("JOINTS_1", a) or Map.memberOf("WEIGHTS_1", a)
        });
        let anims = objectsOf("animations", json);
        let strayTarget = anims |> Vector.flatMap(a -> objectsOf("channels", a)) |> Vector.exists(ch -> {
            let target = objectOf("target", ch);
            Option.nonEmpty(pathOf(stringOf("path", target))) and
                not (intOf("node", target) |> Option.exists(n -> Map.memberOf(n, jointOfNode)))
        });
        let cubic = anims |> Vector.flatMap(a -> objectsOf("samplers", a)) |> Vector.exists(s -> stringOf("interpolation", s) == Some("CUBICSPLINE"));
        (if (extraWeights) "glTF: JOINTS_1 / WEIGHTS_1 を捨てた（1 頂点 4 本のジョイントまで読む）" :: Nil else Nil) :::
        (if (strayTarget) "glTF: ジョイントでないノードを動かすアニメーションの欄を捨てた" :: Nil else Nil) :::
        (if (cubic) "glTF: CUBICSPLINE のアニメーションを、接線を捨てて Linear として読んだ" :: Nil else Nil)
}
