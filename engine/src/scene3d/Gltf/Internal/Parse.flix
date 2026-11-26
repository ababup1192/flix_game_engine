// Gltf.Internal.Parse — glb のバイトを、絵も機種も使わずに形・ノード・骨・アニメ・材質の記述へ読む（parse）。
// 絵を解いて材質を付けるのは Gltf の assemble。ブラウザは parse を Web Worker で回し、メインは assemble だけをする。

/// glb の parse。ゲームからは呼ばない（入口は Model3d.loader / load / decode）。
// WhyNot: ここで Log を呼ばない — Worker の中で出した知らせはメインの ?fge=errors に載らない。知らせは Parsed の lines で返し、assemble が出す。
pub mod Gltf.Internal.Parse {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JNumber, JString}
    use Gltf.Internal.{rowsOf, gather, flatXyz, component, copyRange, float32OfBits}

    type alias Obj = Map[String, Json]

    /// textureInfo 1 つ（{ index, texCoord, extensions }）と、それが指す textures・samplers の読み方。
    /// source = textures[index] の source（画像の番号）・nearest = sampler の magFilter が NEAREST・
    /// clamp = wrapS か wrapT が CLAMP_TO_EDGE・mirrored = wrapS か wrapT が MIRRORED_REPEAT・transform = KHR_texture_transform を持つ。
    pub type alias TextureInfo = { index = Option[Int32], texCoord = Int32, transform = Bool, source = Option[Int32],
                                   nearest = Bool, clamp = Bool, mirrored = Bool }

    /// 材質 1 つの記述（glTF の materials の欄を読んだだけ。絵は番号で指す）。
    /// emissiveFactor = 負と NaN を 0 にした値（3 つの数でなければ (0, 0, 0) と emissiveFactorError）・
    /// emissiveStrength = KHR_materials_emissive_strength（負と NaN は 0・既定 1）・
    /// hasPbr・hasMetallic・hasRoughness = pbrMetallicRoughness・metallicFactor・roughnessFactor の欄があるか（数でなくても）。
    pub type alias MaterialSpec = { name = Option[String], alphaMode = Model3d.AlphaMode, alphaCutoff = Float64, doubleSided = Bool,
                                    base = TextureInfo, normal = TextureInfo, normalScale = Option[Float64], emissive = TextureInfo,
                                    emissiveFactor = { r = Float64, g = Float64, b = Float64 }, emissiveFactorError = Option[String],
                                    emissiveStrength = Float64, metalRough = TextureInfo, hasPbr = Bool, hasMetallic = Bool, hasRoughness = Bool,
                                    metallicFactor = Option[Float64], roughnessFactor = Option[Float64] }

    /// 画像 1 つの在りか。InBin(start, length) = 元のバイトの中の場所・Unreadable = bufferView が読めない（理由）・
    /// ExternalUri = 外の uri・NoSource = bufferView も uri も無い。
    pub enum ImageSource with Eq, ToString {
        case InBin(Int32, Int32)
        case Unreadable(String)
        case ExternalUri
        case NoSource
    }

    /// primitive 1 つの形。node = その primitive を持つノードの番号・material = 材質の番号・
    /// givenTangents = glb の TANGENT を形に付けた（偽なら uv から求める）。
    pub type alias ParsedPart = { mesh = Mesh3d.Mesh3d, node = Int32, material = Option[Int32], givenTangents = Bool }

    /// Skin3d.make に渡した物（同じ物を渡せば同じ Skin3d になる）。
    pub type alias SkinSpec = { names = Vector[String], parents = Vector[Int32], rest = Vector[Skin3d.JointPose],
                                inverseBinds = Option[Vector[Mat4.Mat4]], rootTransform = Mat4.Mat4 }

    /// AnimationClip3d.make に渡した物。
    pub type alias ClipSpec = { name = String, channels = List[AnimationClip3d.Channel] }

    /// 形を読む時の選択肢（LoadOptions の pbr と vertexColors。絵の大きさの上限 limits は入れない）。
    pub type alias ReadOptions = { pbr = Bool, vertexColors = Bool }

    /// parse の結果。mesh = 全部の primitive をつないだ形・clipSpecs = clips を作った物（並びは glTF の animations の順）・
    /// materials と images = glTF の materials と images の並びの記述・lines = 読みながら出た知らせ（出す順）・
    /// droppedLines = 捨てた物を種類ごとに 1 行・read = 読んだ選択肢。
    pub type alias Parsed = { mesh = Mesh3d.Mesh3d, skin = Option[Skin3d.Skin3d], skinSpec = Option[SkinSpec],
                              clips = Map[String, AnimationClip3d.AnimationClip3d], clipSpecs = List[ClipSpec],
                              parts = List[ParsedPart], nodes = List[Model3d.ModelNode],
                              materials = Vector[MaterialSpec], images = Vector[ImageSource],
                              lines = List[String], droppedLines = List[String], read = ReadOptions }

    /// GLB の中身: JSON の木と、元のバイトの中の BIN チャンクの場所と、番号で引く JSON の配列（parseGlb で 1 回だけ取り出す）。
    // WhyNot: 番号で引くたびに json から配列を取り出さない — 取り出すたびに配列全体を作り直すので、accessor 2,000 個の束で二乗になる。
    type alias Glb = { json = Obj, bytes = Vector[Int8], bin = Option[{ start = Int32, length = Int32 }],
                       accessors = Vector[Obj], bufferViews = Vector[Obj], images = Vector[Obj], meshes = Vector[Obj],
                       materials = Vector[Obj], textures = Vector[Obj], samplers = Vector[Obj], skins = Vector[Obj] }

    /// 読んだ accessor（成分を平らに並べた値。normalized の物は 0..1 / −1..1 に直してある）。
    type alias Accessor = { count = Int32, width = Int32, componentType = Int32, values = Vector[Float64] }

    /// 読んだスキン。jointOfNode = ノードの番号 → 並べ替えた後のジョイントの番号・newOfOld = skin.joints の何番目か → 並べ替えた後の番号・
    /// bindWorlds = 並べ替えた後の番号ごとの、バインドの時のジョイントの world 行列（glTF の座標）・spec = skin を作った物。
    type alias SkinBuild = { skin = Skin3d.Skin3d, spec = SkinSpec, jointOfNode = Map[Int32, Int32], newOfOld = Vector[Int32], bindWorlds = Vector[Mat4.Mat4] }

    /// primitive の頂点をどのジョイントに付けるか。Skinned = JOINTS_0 / WEIGHTS_0 を読む・Rigid = 1 本に重み 1・NoSkin = 重みなし。
    enum Binding {
        case Skinned(Vector[Int32])
        case Rigid(Int32)
        case NoSkin
    }

    /// 頂点の欄（glTF の座標のまま）。uvs = TEXCOORD_0（無ければ None）・tangents = TANGENT（uv が無いか TANGENT が無ければ None）・
    /// uvs2 = TEXCOORD_1（lightmap を読む 2 本目の uv。無ければ None）・material = primitive の材質の番号・lines = 読みながら出た知らせ。
    type alias Part = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32],
                        joints = Vector[Int32], weights = Vector[Float64], uvs = Option[Vector[Float64]],
                        tangents = Option[Vector[Float64]], uvs2 = Option[Vector[Float64]], material = Option[Int32], lines = List[String] }

    /// buildModel の結果。parsed = 材質・画像・捨てた物の知らせの他を埋めた Parsed。
    type alias Built = { parsed = Parsed, skinBuild = Option[SkinBuild] }

    /// LoadOptions から形を読む時の選択肢を取り出す。
    pub def readOptionsOf(options: Gltf.LoadOptions): ReadOptions = { pbr = options#pbr, vertexColors = options#vertexColors }

    /// .glb のバイトを読む（壊れている・読まない物を含む時は Err。知らせの行は Ok の時だけ返す）。
    /// read の pbr = baseColorFactor を線形の値として読む（偽なら画面の値として読む。baseColorOf の WhyNot）・vertexColors = COLOR_0 を読む。
    pub def parse(read: ReadOptions, bytes: Vector[Int8]): Result[String, Parsed] =
        forM (
            glb <- parseGlb(bytes);
            _ <- checkBuffers(glb#json);
            built <- buildModel(read, glb)
        ) yield {
            let jointOfNode = built#skinBuild |> Option.map(b -> b#jointOfNode) |> Option.getWithDefault(Map.empty());
            { droppedLines = warningsOf(glb#json, jointOfNode),
              materials = glb#materials |> Vector.map(materialSpecOf(glb)),
              images = glb#images |> Vector.map(imageSourceOf(glb)) | built#parsed }
        }

    /// images[k] の在りか（BIN の bufferView・外の uri・どちらも無い）。
    def imageSourceOf(glb: Glb, image: Obj): ImageSource =
        match (intOf("bufferView", image), stringOf("uri", image)) {
            case (Some(view), _) => binSourceOf(glb, view)
            case (None, Some(_)) => ImageSource.ExternalUri
            case (None, None)    => ImageSource.NoSource
        }

    def binSourceOf(glb: Glb, view: Int32): ImageSource = match viewRange(glb, view) {
        case Ok((start, length)) => ImageSource.InBin(start, length)
        case Err(e)              => ImageSource.Unreadable(e)
    }

    /// bufferView の元のバイトの中の場所（BIN の中）。
    def viewRange(glb: Glb, viewIndex: Int32): Result[String, (Int32, Int32)] =
        forM (
            view <- entryAt("bufferViews", viewIndex, glb#bufferViews);
            bin <- glb#bin |> Option.toOk("glTF: BIN のチャンクが無い");
            length <- intOf("byteLength", view) |> Option.toOk("glTF: bufferViews[${viewIndex}] に byteLength が無い");
            offset <- Ok(Option.getWithDefault(0, intOf("byteOffset", view)));
            _ <- require(offset >= 0 and length >= 0 and offset + length <= bin#length, "glTF: bufferViews[${viewIndex}] が BIN の外を指す")
        ) yield (bin#start + offset, length)

    /// materials[k] の記述。
    def materialSpecOf(glb: Glb, material: Obj): MaterialSpec =
        let pbr = objectOf("pbrMetallicRoughness", material);
        let alphaMode = match stringOf("alphaMode", material) {
            case Some("MASK")  => Model3d.AlphaMode.Mask
            case Some("BLEND") => Model3d.AlphaMode.Blend
            case _             => Model3d.AlphaMode.Opaque
        };
        let factor = numbersOf("emissiveFactor", 3, material);
        let rawFactor = factor |> Result.toOption |> Option.flatMap(identity) |> Option.getWithDefault(Vector#{ 0.0, 0.0, 0.0 });
        let positive = (k: Int32) -> { let v = Vector.get(k, rawFactor); if (v > 0.0) v else 0.0 };
        let strength = numberAt("emissiveStrength", objectOf("KHR_materials_emissive_strength", objectOf("extensions", material)))
            |> Option.getWithDefault(1.0);
        { name = stringOf("name", material), alphaMode = alphaMode,
          alphaCutoff = numberAt("alphaCutoff", material) |> Option.getWithDefault(0.5),
          doubleSided = Map.get("doubleSided", material) == Some(Util.Json.Json.JBool(true)),
          base = textureInfoOf(glb, objectOf("baseColorTexture", pbr)),
          normal = textureInfoOf(glb, objectOf("normalTexture", material)),
          normalScale = numberAt("scale", objectOf("normalTexture", material)),
          emissive = textureInfoOf(glb, objectOf("emissiveTexture", material)),
          emissiveFactor = { r = positive(0), g = positive(1), b = positive(2) },
          emissiveFactorError = errorOf(factor),
          emissiveStrength = if (strength > 0.0) strength else 0.0,
          metalRough = textureInfoOf(glb, objectOf("metallicRoughnessTexture", pbr)),
          hasPbr = Map.memberOf("pbrMetallicRoughness", material),
          hasMetallic = Map.memberOf("metallicFactor", pbr), hasRoughness = Map.memberOf("roughnessFactor", pbr),
          metallicFactor = numberAt("metallicFactor", pbr), roughnessFactor = numberAt("roughnessFactor", pbr) }

    def errorOf(r: Result[String, a]): Option[String] = match r {
        case Err(e) => Some(e)
        case Ok(_)  => None
    }

    def textureInfoOf(glb: Glb, info: Obj): TextureInfo =
        let index = intOf("index", info);
        let texture = index |> Option.flatMap(k -> Vector.nth(k, glb#textures)) |> Option.getWithDefault(Map.empty());
        let sampler = intOf("sampler", texture) |> Option.flatMap(sk -> Vector.nth(sk, glb#samplers)) |> Option.getWithDefault(Map.empty());
        let wraps = intOf("wrapS", sampler) :: intOf("wrapT", sampler) :: Nil;
        { index = index, texCoord = Option.getWithDefault(0, intOf("texCoord", info)),
          transform = Map.memberOf("KHR_texture_transform", objectOf("extensions", info)),
          source = intOf("source", texture), nearest = intOf("magFilter", sampler) == Some(9728),
          clamp = List.exists(w -> w == Some(33071), wraps), mirrored = List.exists(w -> w == Some(33648), wraps) }

    def numberAt(key: String, o: Obj): Option[Float64] = Map.get(key, o) |> Option.flatMap(numberOf)


    // ── バイト ──────────────────────────────────────────────

    def u8(bytes: Vector[Int8], i: Int32): Int32 = Int32.bitwiseAnd(Int8.toInt32(Vector.get(i, bytes)), 0xFF)

    def u16(bytes: Vector[Int8], i: Int32): Int32 = u8(bytes, i) + u8(bytes, i + 1) * 256

    /// 4 バイトのリトルエンディアン（2^31 以上は負の数になる。長さとして読む所は負を Err にする）。
    def u32Bits(bytes: Vector[Int8], i: Int32): Int32 = Int32.bitwiseOr(u16(bytes, i), Int32.leftShift(u16(bytes, i + 2), 16))

    def i16(bytes: Vector[Int8], i: Int32): Int32 = let v = u16(bytes, i); if (v >= 32768) v - 65536 else v

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
            case Some(j) => Ok(glbOf(j, bytes, bin))
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

    def glbOf(json: Obj, bytes: Vector[Int8], bin: Option[{ start = Int32, length = Int32 }]): Glb =
        { json = json, bytes = bytes, bin = bin,
          accessors = objectsOf("accessors", json), bufferViews = objectsOf("bufferViews", json), images = objectsOf("images", json),
          meshes = objectsOf("meshes", json), materials = objectsOf("materials", json), textures = objectsOf("textures", json),
          samplers = objectsOf("samplers", json), skins = objectsOf("skins", json) }

    // 後ろの空白の詰め物は trim で落ちる。
    def parseJson(bytes: Vector[Int8], start: Int32, length: Int32): Result[String, Obj] =
        let text = String.fromBytes(copyRange(start, start + length, bytes)) |> String.trim;
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

    /// items（Glb の配列）の index 番目。kind は知らせに書く配列の名前。
    def entryAt(kind: String, index: Int32, items: Vector[Obj]): Result[String, Obj] =
        Vector.nth(index, items) |> Option.toOk("glTF: ${kind}[${index}] が無い")

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
            acc <- entryAt("accessors", index, glb#accessors);
            _ <- require(not Map.memberOf("sparse", acc), "glTF: accessors[${index}] の sparse は読まない");
            viewIndex <- intOf("bufferView", acc) |> Option.toOk("glTF: accessors[${index}] に bufferView が無い");
            view <- entryAt("bufferViews", viewIndex, glb#bufferViews);
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

    /// ノードの局所の姿勢（glTF の座標）。matrix のノードは平行移動・回転・倍率に分ける。
    def nodePose(node: Obj): Result[String, Skin3d.JointPose] =
        forM (
            matrix <- numbersOf("matrix", 16, node);
            t <- numbersOf("translation", 3, node);
            r <- numbersOf("rotation", 4, node);
            s <- numbersOf("scale", 3, node)
        ) yield match matrix {
            case Some(cells) => Gltf.Internal.decompose(cells)
            case None =>
                { translation = Option.map(v -> Gltf.Internal.vec3At(v, 0), t) |> Option.getWithDefault(Vec3.zero()),
                  rotation = Option.map(v -> Gltf.Internal.quatOf(v), r) |> Option.getWithDefault(Quat.identity()),
                  scale = Option.map(v -> Gltf.Internal.vec3At(v, 0), s) |> Option.getWithDefault(Vec3.one()) }
        }

    def nodeMatrix(node: Obj): Result[String, Mat4.Mat4] =
        Result.flatMap(matrix -> match matrix {
            case Some(cells) => Mat4.ofColumns(cells)
            case None => Result.map(Skin3d.jointPoseToMat4, nodePose(node))
        }, numbersOf("matrix", 16, node))

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
            skinObj <- entryAt("skins", skinIndex, glb#skins);
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
                                Mat4.ofColumns(copyRange(k * 16, k * 16 + 16, acc#values)))
                ) yield List.toVector(mats)
        }

    def assembleSkin(nodes: Vector[Obj], jointNodes: Vector[Int32], links: Vector[Link],
                     rootGl: Mat4.Mat4, ibmsGl: Vector[Mat4.Mat4]): Result[String, SkinBuild] =
        let count = Vector.length(jointNodes);
        let order = List.range(0, count) |> Sort.sortStableBy(k -> Vector.get(k, links)#depth) |> List.toVector;
        let newOfOld = order |> Vector.mapWithIndex((newIndex, old) -> (old, newIndex))
                             |> Vector.foldLeft((m, pair) -> Map.insert(fst(pair), snd(pair), m), Map.empty());
        let newOf = (old: Int32) -> Map.getWithDefault(old, 0, newOfOld);
        let names = order |> Vector.map(old -> {
            let node = Vector.get(Vector.get(old, jointNodes), nodes);
            stringOf("name", node) |> Option.getWithDefault("joint${old}")
        });
        let parents = order |> Vector.map(old -> Vector.get(old, links)#parent |> Option.map(newOf) |> Option.getWithDefault(-1));
        let bindsGl = order |> Vector.map(old -> Vector.get(old, ibmsGl));
        let specOf = (restGl: List[Skin3d.JointPose]) ->
            { names = names, parents = parents, rest = List.toVector(List.map(Gltf.Internal.mirrorPose, restGl)),
              inverseBinds = Some(Vector.map(Gltf.Internal.mirrorMat4, bindsGl)), rootTransform = Gltf.Internal.mirrorMat4(rootGl) };
        forM (
            restGl <- Vector.toList(order) |> Result.traverse(old ->
                          Vector.nth(Vector.get(old, jointNodes), nodes) |> Option.toOk("glTF: ジョイントのノードが無い") |> Result.flatMap(nodePose));
            bindWorlds <- Vector.toList(bindsGl) |> Result.traverse(m ->
                              Mat4.inverse(m) |> Option.toOk("glTF: 逆バインド行列に逆行列が無い"));
            spec <- Ok(specOf(restGl));
            skin <- Skin3d.make(spec)
        ) yield {
            skin = skin,
            spec = spec,
            jointOfNode = Vector.range(0, count) |> Vector.foldLeft((m, old) -> Map.insert(Vector.get(old, jointNodes), newOf(old), m), Map.empty()),
            newOfOld = Vector.range(0, count) |> Vector.map(newOf),
            bindWorlds = List.toVector(bindWorlds)
        }

    // ── メッシュ ────────────────────────────────────────────

    def buildModel(read: ReadOptions, glb: Glb): Result[String, Built] =
        let nodes = objectsOf("nodes", glb#json);
        let parentOf = parentsOfNodes(nodes);
        let meshNodes = Vector.range(0, Vector.length(nodes)) |> Vector.filter(i -> Map.memberOf("mesh", Vector.get(i, nodes)));
        let skinIndices = meshNodes |> Vector.filterMap(i -> intOf("skin", Vector.get(i, nodes))) |> Vector.toList |> List.toSet;
        if (Set.size(skinIndices) > 1) Err("glTF: スキンのあるメッシュのノードが、別々のスキンを指す")
        else {
            let skinR = match Set.toList(skinIndices) {
                case k :: _ => Result.map(Some, buildSkin(glb, nodes, parentOf, k))
                case Nil => Ok(None)
            };
            forM (
                skinBuild <- skinR;
                nested <- Vector.toList(meshNodes) |> Result.traverse(i -> nodeParts(read, glb, nodes, parentOf, skinBuild, i) |> Result.map(ps -> (i, ps)));
                parts <- Ok(nested |> List.flatMap(snd));
                mesh <- meshOfParts(parts, Option.nonEmpty(skinBuild));
                partMeshes <- parts |> Result.traverse(part -> partMeshOf(part, Option.nonEmpty(skinBuild)));
                animations <- readAnimations(glb, Option.map(b -> b#jointOfNode, skinBuild) |> Option.getWithDefault(Map.empty()))
            ) yield {
                let partNodes = nested |> List.flatMap(np -> List.map(_ -> fst(np), snd(np)));
                let (modelNodes, nodeLines) = modelNodesOf(glb, nodes, parentOf, partNodes);
                let parsedParts = List.zip(List.zip(partMeshes, partNodes), parts) |> List.map(entry -> {
                    let ((built, node), part) = entry;
                    { mesh = built#mesh, node = node, material = part#material, givenTangents = built#givenTangents }
                });
                let lines = List.flatten((parts |> List.flatMap(p -> p#lines)) :: (partMeshes |> List.flatMap(b -> b#lines)) :: nodeLines :: Nil);
                { parsed = { mesh = mesh, skin = Option.map(b -> b#skin, skinBuild), skinSpec = Option.map(b -> b#spec, skinBuild),
                             clips = fst(animations), clipSpecs = snd(animations), parts = parsedParts, nodes = modelNodes,
                             materials = Vector.empty(), images = Vector.empty(), lines = lines, droppedLines = Nil, read = read },
                  skinBuild = skinBuild }
            }
        }

    // ── ノードの一覧（Model3d.nodes）──

    /// glTF の nodes の全部を ModelNode にする（world は根から親の順に 1 巡で掛ける）。parentOf = parentsOfNodes(nodes)・partNodes = parts の並びの、各 part のノードの番号。
    /// 行列が読めないノード（matrix が 16 個の数でない等）は単位行列で続けて 1 行知らせる。根から辿れないノード（木が輪になっている）は world = local。
    // WhyNot: nodeParts の chainOf / productOf で world を出さない — ノードごとに根まで辿るので、ノード n 個・深さ d で n·d 回掛ける。
    // WhyNot: 部品の形の焼き込み（nodeParts）をこの 1 巡に寄せない — 骨つきの glb の部品の頂点が 1 bit でも変わると、描き出しの鍵が変わる。
    def modelNodesOf(glb: Glb, nodes: Vector[Obj], parentOf: Map[Int32, Int32], partNodes: List[Int32]): (List[Model3d.ModelNode], List[String]) =
        let count = Vector.length(nodes);
        let readLocals = nodes |> Vector.mapWithIndex((i, node) -> match nodeMatrix(node) {
            case Ok(m)  => (m, Nil)
            case Err(e) => (Mat4.identity(), "glTF: nodes[${i}] の行列を単位行列として読む（${e}）" :: Nil)
        });
        let localsGl = Vector.map(fst, readLocals);
        let children = nodes |> Vector.map(node -> intsOf("children", node) |> Vector.filter(c -> c >= 0 and c < count));
        let roots = Vector.range(0, count) |> Vector.filter(i -> not Map.memberOf(i, parentOf)) |> Vector.toList;
        let worldsGl = roots |> List.foldLeft((acc, root) -> worldsFrom(localsGl, children, root, Mat4.identity(), acc), Map.empty());
        let partsOf = List.zipWithIndex(partNodes) |> List.foldRight((kn, acc) -> {
            let (k, n) = kn;
            Map.insertWith((fresh, old) -> List.append(fresh, old), n, k :: Nil, acc)
        }, Map.empty());
        let modelNodes = Vector.range(0, count) |> Vector.toList |> List.map(i -> {
            let node = Vector.get(i, nodes);
            let local = Vector.get(i, localsGl);
            { name = stringOf("name", node) |> Option.getWithDefault(""), parent = Map.get(i, parentOf),
              local = Gltf.Internal.mirrorMat4(local), world = Gltf.Internal.mirrorMat4(Map.getWithDefault(i, local, worldsGl)),
              localBounds = intOf("mesh", node) |> Option.flatMap(localBoundsOfMesh(glb)),
              parts = Map.getWithDefault(i, Nil, partsOf) }
        });
        (modelNodes, Vector.toList(readLocals) |> List.flatMap(snd))

    /// ノード i から下の world（glTF の座標）を acc に足す（parentWorld = 親の world）。一度足したノードは辿らない（輪で止まる）。
    def worldsFrom(locals: Vector[Mat4.Mat4], children: Vector[Vector[Int32]], i: Int32, parentWorld: Mat4.Mat4,
                   acc: Map[Int32, Mat4.Mat4]): Map[Int32, Mat4.Mat4] =
        if (Map.memberOf(i, acc)) acc
        else {
            let world = Mat4.mul(parentWorld, Vector.get(i, locals));
            Vector.get(i, children) |> Vector.foldLeft((m, c) -> worldsFrom(locals, children, c, world, m), Map.insert(i, world, acc))
        }

    /// mesh の全部の primitive の POSITION の min と max（engine の座標）。accessor の min / max があればそれを、無ければ頂点から求める。
    /// X の反転で min と max の x が入れ替わるので、反転した後で組み直す。読めない primitive は数えない（全部読めなければ None）。
    def localBoundsOfMesh(glb: Glb, meshIndex: Int32): Option[Mesh3d.Bounds] =
        let prims = entryAt("meshes", meshIndex, glb#meshes) |> Result.toOption |> Option.map(m -> objectsOf("primitives", m))
            |> Option.getWithDefault(Vector.empty());
        prims |> Vector.toList
            |> List.filterMap(prim -> intOf("POSITION", objectOf("attributes", prim)) |> Option.flatMap(positionBoundsOf(glb)))
            |> List.reduceLeft((a, b) -> { min = Vec3.v3(Float64.min(a#min#x, b#min#x), Float64.min(a#min#y, b#min#y), Float64.min(a#min#z, b#min#z)),
                                           max = Vec3.v3(Float64.max(a#max#x, b#max#x), Float64.max(a#max#y, b#max#y), Float64.max(a#max#z, b#max#z)) })

    def positionBoundsOf(glb: Glb, accessorIndex: Int32): Option[Mesh3d.Bounds] =
        let declared = forM (
            acc <- entryAt("accessors", accessorIndex, glb#accessors) |> Result.toOption;
            low <- numbersOf("min", 3, acc) |> Result.toOption |> Option.flatMap(identity);
            high <- numbersOf("max", 3, acc) |> Result.toOption |> Option.flatMap(identity)
        ) yield (Gltf.Internal.vec3At(low, 0), Gltf.Internal.vec3At(high, 0));
        let glBounds = match declared {
            case Some(b) => Some(b)
            case None    => readAccessorWidth(glb, accessorIndex, 3, "POSITION") |> Result.toOption |> Option.flatMap(a -> scannedBounds(a#values))
        };
        glBounds |> Option.map(b -> {
            let (low, high) = b;
            { min = Vec3.v3(0.0 - high#x, low#y, low#z), max = Vec3.v3(0.0 - low#x, high#y, high#z) }
        })

    /// 頂点ごとに 3 つの並びの min と max（glTF の座標）。頂点が無ければ None。
    def scannedBounds(values: Vector[Float64]): Option[(Vec3.Vec3, Vec3.Vec3)] =
        let count = Vector.length(values) / 3;
        if (count == 0) None
        else {
            let axis = (c: Int32, f: (Float64, Float64) -> Float64, start: Float64) ->
                Vector.range(0, count) |> Vector.foldLeft((acc, v) -> f(acc, Vector.get(v * 3 + c, values)), start);
            Some((Vec3.v3(axis(0, Float64.min, Float64.maxValue()), axis(1, Float64.min, Float64.maxValue()), axis(2, Float64.min, Float64.maxValue())),
                  Vec3.v3(axis(0, Float64.max, 0.0 - Float64.maxValue()), axis(1, Float64.max, 0.0 - Float64.maxValue()), axis(2, Float64.max, 0.0 - Float64.maxValue()))))
        }

    /// メッシュのノード 1 つの primitive の列。
    ///   - skin のあるノード: 変換を無視し（仕様の MUST）、JOINTS_0 / WEIGHTS_0 を読む
    ///   - ジョイントの子孫: バインドの時のジョイントの world 行列 × ジョイントから下の局所の鎖で写し、そのジョイントに重み 1
    ///   - ほか: world 行列を焼き込む（スキンがあれば根のジョイントに重み 1）
    def nodeParts(read: ReadOptions, glb: Glb, nodes: Vector[Obj], parentOf: Map[Int32, Int32], skinBuild: Option[SkinBuild], i: Int32): Result[String, List[Part]] =
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
            meshObj <- entryAt("meshes", meshIndex, glb#meshes);
            parts <- objectsOf("primitives", meshObj) |> Vector.toList |> Result.traverse(prim -> readPrimitive(read, glb, fst(placement), snd(placement), prim))
        ) yield parts

    def readPrimitive(read: ReadOptions, glb: Glb, transform: Mat4.Mat4, binding: Binding, prim: Obj): Result[String, Part] =
        let attributes = objectOf("attributes", prim);
        let mode = Option.getWithDefault(4, intOf("mode", prim));
        forM (
            _ <- require(mode == 4, "glTF: primitive の mode ${mode} は読まない（三角形 = 4 だけ）");
            positionIndex <- intOf("POSITION", attributes) |> Option.toOk("glTF: primitive に POSITION が無い");
            positions <- readAccessorWidth(glb, positionIndex, 3, "POSITION");
            normals <- traverseOpt(intOf("NORMAL", attributes), k -> readAccessorWidth(glb, k, 3, "NORMAL"));
            indices <- traverseOpt(intOf("indices", prim), k -> readAccessorWidth(glb, k, 1, "indices"));
            skin <- readSkinAttributes(glb, attributes, binding, positions#count);
            color <- baseColorOf(read#pbr, glb, prim)
        ) yield {
            let count = positions#count;
            let (colorAccessor, colorLines) = if (read#vertexColors) vertexColorsOf(glb, attributes, count) else (None, Nil);
            let vertexColors = colorAccessor |> Option.map(a -> (a#width, a#values));
            let (uvs, uvLines) = optionalAttribute(glb, attributes, "TEXCOORD_0", 2, count);
            let (uvs2, uv2Lines) = optionalAttribute(glb, attributes, "TEXCOORD_1", 2, count);
            let (tangents, tangentLines) = optionalAttribute(glb, attributes, "TANGENT", 4, count);
            let indexList = match indices {
                case Some(a) => Vector.map(toIndex, a#values)
                case None => Vector.range(0, count)
            };
            let normalMat = Mat4.normalMatrix(transform);
            let placedPositions = flatXyz(Vector.range(0, count) |> Vector.map(v -> Mat4.apply(transform, Gltf.Internal.vec3At(positions#values, v * 3))));
            let placedNormals = Option.map(n -> flatXyz(Vector.range(0, count) |> Vector.map(v ->
                Vec3.normalized(Mat4.applyDir(normalMat, Gltf.Internal.vec3At(n#values, v * 3))))), normals);
            let placedTangents = forM (_ <- uvs; t <- tangents) yield placeTangents(transform, t#values);
            let part = { positions = placedPositions, normals = Option.getWithDefault(Vector.empty(), placedNormals),
                         colors = Gltf.Internal.colorsOf(count, color, vertexColors), indices = indexList,
                         joints = fst(skin), weights = snd(skin), uvs = Option.map(a -> a#values, uvs), tangents = placedTangents,
                         uvs2 = Option.map(a -> a#values, uvs2), material = intOf("material", prim),
                         lines = List.flatten(colorLines :: uvLines :: uv2Lines :: tangentLines :: Nil) };
            if (Option.nonEmpty(normals)) part else flatShaded(part)
        }

    /// COLOR_0 を読む（読める形と型は Gltf.Internal.colorAccessorProblem）。無ければ None・読めない時は使わずに 1 行知らせる。
    def vertexColorsOf(glb: Glb, attributes: Obj, count: Int32): (Option[Accessor], List[String]) =
        intOf("COLOR_0", attributes) |> Option.map(k -> {
            let normalized = entryAt("accessors", k, glb#accessors) |> Result.toOption |> Option.exists(acc -> Map.get("normalized", acc) == Some(Util.Json.Json.JBool(true)));
            let checked = readAccessor(glb, k) |> Result.flatMap(a ->
                Gltf.Internal.colorAccessorProblem(a#width, a#componentType, normalized) |> Option.map(Err) |> Option.getWithDefault(Ok(a)));
            match checked {
                case Ok(a)  => usableAttribute("COLOR_0", count, a)
                case Err(e) => (None, "${e} — COLOR_0 を使わずに読む" :: Nil)
            }
        }) |> Option.getWithDefault((None, Nil))

    /// 無くても形は描ける頂点の欄（TEXCOORD_0・TANGENT）を読む。読めない・数が頂点の数と違う・NaN か無限がある時は、
    /// その欄を使わずに続けて 1 行知らせる（None）。
    // WhyNot: Err にしない — uv を使わない形（当たり判定の形など）まで読めなくなる。形（POSITION・indices）が読めれば描ける。
    def optionalAttribute(glb: Glb, attributes: Obj, key: String, width: Int32, count: Int32): (Option[Accessor], List[String]) =
        match traverseOpt(intOf(key, attributes), k -> readAccessorWidth(glb, k, width, key)) {
            case Ok(None)    => (None, Nil)
            case Ok(Some(a)) => usableAttribute(key, count, a)
            case Err(e)      => (None, "${e} — ${key} を使わずに読む" :: Nil)
        }

    /// 読めた欄 a が頂点の数 count とそろい、全部が有限の数なら Some。違えば 1 行知らせて None。
    def usableAttribute(key: String, count: Int32, a: Accessor): (Option[Accessor], List[String]) =
        if (a#count != count) (None, "glTF: ${key} の数 ${a#count} が頂点の数 ${count} と違う — ${key} を使わずに読む" :: Nil)
        else if (Vector.exists(x -> Float64.isNan(x) or Float64.isInfinite(x), a#values))
            (None, "glTF: ${key} に NaN か無限がある — ${key} を使わずに読む" :: Nil)
        else (Some(a), Nil)

    /// TANGENT を置き場所の行列 transform で写す（xyz は左上 3×3 を掛けて長さ 1 に・行列が裏返すなら w の符号も裏返す）。
    // WhyNot: 法線の行列で写さない — タンジェントは面の上の向きで、置き場所の行列のまま写る。
    def placeTangents(transform: Mat4.Mat4, values: Vector[Float64]): Vector[Float64] =
        let c = Mat4.toColumns(transform);
        let col = (j: Int32) -> Vec3.v3(Vector.get(j * 4, c), Vector.get(j * 4 + 1, c), Vector.get(j * 4 + 2, c));
        let flip = if (Vec3.dot(col(0), Vec3.cross(col(1), col(2))) < 0.0) -1.0 else 1.0;
        let count = Vector.length(values) / 4;
        let placed = Vector.range(0, count) |> Vector.map(v -> Vec3.normalized(Mat4.applyDir(transform, Gltf.Internal.vec3At(values, v * 4))));
        rowsOf(count, 4, (v, axis) -> if (axis == 3) Vector.get(v * 4 + 3, values) * flip else component(axis, Vector.get(v, placed)))

    def traverseOpt(o: Option[Int32], f: Int32 -> Result[String, a]): Result[String, Option[a]] = match o {
        case Some(k) => Result.map(Some, f(k))
        case None => Ok(None)
    }

    /// 頂点ごとの 4 つのジョイントの番号（並べ替えた後）と重み。重みの無い形は空。
    def readSkinAttributes(glb: Glb, attributes: Obj, binding: Binding, count: Int32): Result[String, (Vector[Int32], Vector[Float64])] =
        let rigid = (j: Int32) -> Ok((rowsOf(count, 4, (_, c) -> if (c == 0) j else 0),
                                      rowsOf(count, 4, (_, c) -> if (c == 0) 1.0 else 0.0)));
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

    /// baseColorFactor を頂点の色にする。材質や baseColorFactor が無ければ白。linear が偽なら値をそのまま（画面の値として）、
    /// 真なら glTF の決まりどおり線形の値として読み、頂点の色（画面の値）へ戻して書く（描き手は頂点の色を線形へ戻すので、元の線形の値に戻る）。
    // WhyNot: pbr が偽の時は線形として読まない — OBJ の Kd も Blender の値を画面の値（sRGB の値）として読む。
    //   片方だけ直すと同じ Blender の色が形式で違って見え、既存のゲームの色が変わる。emissiveFactor も同じく画面の値として読む（COLOR_0 は Gltf.Internal.colorsOf）。
    // WhyNot: pbr が真の時は線形として読む — 画面の値として読むと、金・赤が濃く、暗い色が黒く潰れて Blender の手本と合わない。
    def baseColorOf(linear: Bool, glb: Glb, prim: Obj): Result[String, Vector[Float64]] =
        let white = Vector#{ 1.0, 1.0, 1.0 };
        match intOf("material", prim) {
            case None => Ok(white)
            case Some(k) => Result.flatMap(material ->
                Result.map(factor -> match factor {
                    case Some(rgba) => Vector.take(3, rgba) |> Vector.map(c -> Float64.max(0.0, Float64.min(1.0, c)))
                        |> Vector.map(c -> if (linear) Texture3d.linearToSrgb(c) else c)
                    case None => white
                }, numbersOf("baseColorFactor", 4, objectOf("pbrMetallicRoughness", material))), entryAt("materials", k, glb#materials))
        }

    /// 法線の無い primitive は、三角形ごとに頂点を分けて面の法線を付ける（glTF の表は外から見て反時計回り）。
    def flatShaded(part: Part): Part =
        let tris = Vector.length(part#indices) / 3;
        let corner = (t: Int32, c: Int32) -> Vector.get(t * 3 + c, part#indices);
        let corners = Vector.range(0, tris * 3) |> Vector.map(k -> corner(k / 3, k - (k / 3) * 3));
        let faceNormals = Vector.range(0, tris) |> Vector.map(t -> {
            let p = c -> Gltf.Internal.vec3At(part#positions, corner(t, c) * 3);
            Vec3.normalized(Vec3.cross(Vec3.sub(p(1), p(0)), Vec3.sub(p(2), p(0))))
        });
        let hasSkin = not Vector.isEmpty(part#joints);
        { positions = gather(3, part#positions, corners),
          normals = rowsOf(tris * 3, 3, (k, c) -> component(c, Vector.get(k / 3, faceNormals))),
          colors = gather(3, part#colors, corners),
          indices = Vector.range(0, tris * 3),
          joints = if (hasSkin) gather(4, part#joints, corners) else Vector.empty(),
          weights = if (hasSkin) gather(4, part#weights, corners) else Vector.empty(),
          uvs = Option.map(uv -> gather(2, uv, corners), part#uvs),
          tangents = Option.map(t -> gather(4, t, corners), part#tangents),
          uvs2 = Option.map(uv -> gather(2, uv, corners), part#uvs2),
          material = part#material, lines = part#lines }

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

    /// primitive 1 つの形（meshOfParts と同じ写し方）。uv があれば uv つきにし、TANGENT があれば x と w の符号を反転して使う
    /// （X の反転で cross(N, T) の向きが裏返るので、w も裏返すと絵の上の向きが保たれる）。無ければ Mesh3d が uv から求める。
    /// uv を付けられなければ uv なしの形で続けて 1 行知らせる（uv は形を描くのに要らない）。
    /// 2 本目の uv（TEXCOORD_1）があれば付ける（X の反転は受けない — uv と同じく絵の上の位置）。付けられなければ 2 本目の uv なしで続けて 1 行知らせる。
    def partMeshOf(part: Part, skinned: Bool): Result[String, PartMesh] =
        Result.map(mesh -> {
            let textured = part#uvs |> Option.map(uv -> withPartUvs(part, uv, mesh)) |> Option.getWithDefault({ mesh = mesh, givenTangents = false, lines = Nil });
            let (second, secondLines) = withPartUvs2(part, textured#mesh);
            { mesh = second, givenTangents = textured#givenTangents, lines = List.append(textured#lines, secondLines) }
        }, meshOfParts(part :: Nil, skinned))

    /// primitive 1 つの形。givenTangents = TANGENT を付けた・lines = 付けられなかった欄の知らせ。
    type alias PartMesh = { mesh = Mesh3d.Mesh3d, givenTangents = Bool, lines = List[String] }

    def withPartUvs2(part: Part, mesh: Mesh3d.Mesh3d): (Mesh3d.Mesh3d, List[String]) =
        part#uvs2 |> Option.map(uv -> attachUvs2(uv, mesh)) |> Option.getWithDefault((mesh, Nil))

    def attachUvs2(uv: Vector[Float64], mesh: Mesh3d.Mesh3d): (Mesh3d.Mesh3d, List[String]) =
        match Mesh3d.withUvs2(uv, mesh) {
            case Ok(withSecond) => (withSecond, Nil)
            case Err(e)         => (mesh, "glTF: TEXCOORD_1 を使わずに読む（${e}）" :: Nil)
        }

    /// mesh に uv を付け、part に TANGENT があればそれも付ける。uv を付けられなければ mesh のまま。
    def withPartUvs(part: Part, uv: Vector[Float64], mesh: Mesh3d.Mesh3d): PartMesh =
        match Mesh3d.withUvs(uv, mesh) {
            case Ok(textured) => part#tangents |> Option.map(t -> withPartTangents(t, textured))
                                     |> Option.getWithDefault({ mesh = textured, givenTangents = false, lines = Nil })
            case Err(e)       => { mesh = mesh, givenTangents = false, lines = "glTF: uv を使わずに読む（${e}）" :: Nil }
        }

    /// TANGENT の x と w の符号を反転して付ける。付けられなければ uv から求めた物のまま。
    def withPartTangents(tangents: Vector[Float64], textured: Mesh3d.Mesh3d): PartMesh =
        let mirrored = Vector.mapWithIndex((k, x) -> if (Int32.remainder(k, 4) == 0 or Int32.remainder(k, 4) == 3) 0.0 - x else x, tangents);
        match Mesh3d.withTangents(mirrored, textured) {
            case Ok(m)  => { mesh = m, givenTangents = true, lines = Nil }
            case Err(e) => { mesh = textured, givenTangents = false, lines = "glTF: TANGENT を使えないので uv から求め直した（${e}）" :: Nil }
        }

    // ── アニメーション ──────────────────────────────────────

    /// 名前ごとのクリップと、それを作った物（glTF の animations の順）。
    def readAnimations(glb: Glb, jointOfNode: Map[Int32, Int32]): Result[String, (Map[String, AnimationClip3d.AnimationClip3d], List[ClipSpec])] =
        objectsOf("animations", glb#json)
            |> Vector.toList
            |> List.zip(List.range(0, Vector.length(objectsOf("animations", glb#json))))
            |> Result.traverse(pair -> {
                let (k, anim) = pair;
                let name = stringOf("name", anim) |> Option.getWithDefault("animation${k}");
                Result.flatMap(channels -> {
                    let spec = { name = name, channels = List.filterMap(identity, channels) };
                    makeClip(spec) |> Result.map(clip -> (clip, spec))
                }, objectsOf("channels", anim) |> Vector.toList |> Result.traverse(readChannel(glb, jointOfNode, anim)))
            })
            |> Result.map(made -> (clipsByName(List.map(fst, made)), List.map(snd, made)))

    /// spec から作ったクリップ（Gltf.Internal.Codec が同じ物から作り直す）。
    pub def makeClip(spec: ClipSpec): Result[String, AnimationClip3d.AnimationClip3d] =
        AnimationClip3d.make(spec#name, spec#channels) |> Result.mapErr(e -> "glTF: ${e}")

    /// 名前 → クリップ（同じ名前は後ろの物）。
    pub def clipsByName(clips: List[AnimationClip3d.AnimationClip3d]): Map[String, AnimationClip3d.AnimationClip3d] =
        List.foldLeft((m, c) -> Map.insert(AnimationClip3d.name(c), c, m), Map.empty(), clips)

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
                         Vector.range(0, count) |> Vector.flatMap(k -> copyRange((k * 3 + 1) * width, (k * 3 + 2) * width, values))))
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
