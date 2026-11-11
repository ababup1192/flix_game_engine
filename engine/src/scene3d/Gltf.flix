// Gltf — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// glTF 2.0 のバイナリ（.glb）を読む: メッシュ・スキン・頂点のジョイントの重み・アニメーション・uv（TEXCOORD_0）とタンジェント（TANGENT）。
/// loadTextured はさらに、BIN に埋めた画像（PNG / JPEG）と材質（baseColorTexture・normalTexture・emissive・sampler）も読む。
/// ノードは全部（mesh の無いノードも）名前・行列・局所の境界つきで Model3d の nodes に入る（Model3d.findNode で引く）。
/// 右手系の glTF を左手系の engine へ X の反転（S = diag(−1, 1, 1)）で写す。glTF の正面 +Z は engine でも +Z のまま、
/// キャラの右手（glTF の −X）は engine の +X に来る。位置と法線は x を反転し、三角形の巡りを逆にする。
/// 回転は (x, −y, −z, w)、倍率はそのまま、行列（逆バインド行列・matrix のノード・rootTransform）は S·M·S。
/// 読まない物（Err）: 外の uri・data URI・sparse accessor・三角形以外の primitive・1 体 64 本を超えるジョイント。
/// 捨てて 1 回知らせる物: JOINTS_1 / WEIGHTS_1・ジョイントでないノードを動かす欄・CUBICSPLINE の接線。
/// 絵（loadTextured）で読み飛ばして 1 行ずつ知らせる物: texCoord ≠ 0・KHR_texture_transform・MIRRORED_REPEAT（REPEAT で読む）・外の uri の画像。
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

    /// 頂点の欄（glTF の座標のまま）。uvs = TEXCOORD_0（無ければ None）・tangents = TANGENT（uv が無いか TANGENT が無ければ None）・
    /// uvs2 = TEXCOORD_1（lightmap を読む 2 本目の uv。無ければ None）・material = primitive の材質の番号。
    type alias Part = { positions = Vector[Float64], normals = Vector[Float64], colors = Vector[Float64], indices = Vector[Int32],
                        joints = Vector[Int32], weights = Vector[Float64], uvs = Option[Vector[Float64]],
                        tangents = Option[Vector[Float64]], uvs2 = Option[Vector[Float64]], material = Option[Int32] }

    /// 組んだ Model3d と、parts の並びの材質の番号（loadTextured が材質を付ける）。
    type alias Built = { model = Model3d.Model3d, jointOfNode = Map[Int32, Int32], partMaterials = List[Option[Int32]] }

    /// path の .glb を読む（Fs.FileRead.readBytes）。読めない・壊れている時は Err（パスつき）。
    pub def load(path: String): Result[String, Model3d.Model3d] \ Fs.FileRead =
        loadWith(fromGlb, path)

    /// .glb のバイトから作る。壊れている・読まない物を含む時は Err。parts は primitive ごと（材質 None・gltfMaterial の絵の名前は None）・textures は空。
    /// TEXCOORD_0・TANGENT が読めない（数が頂点の数と違う・NaN か無限）時は、その欄を使わずに読んで 1 行知らせる。
    pub def fromGlb(bytes: Vector[Int8]): Result[String, Model3d.Model3d] =
        parseAndBuild(bytes) |> Result.map(gb -> {
            let (glb, built) = gb;
            let infoOnly = (material: Obj) -> { withUv = None, withoutUv = None, info = gltfMaterialOf(noTextureNames(), material), lines = Nil, noUvLine = None };
            let (parts, lines) = attachMaterials(built, objectsOf("materials", glb#json) |> Vector.map(infoOnly));
            Log.warnAllThen(List.append(warningsOf(glb#json, built#jointOfNode), lines), { parts = parts | built#model })
        })

    /// fromGlb の、形の中身の鍵を key から作る版（part ごとに "key#part<番号>"・まとめた形は "key#all"）。
    /// key は同じ key なら同じバイトだと呼ぶ側が約束できる字（ImageData.ImageDecoder の versionedKey）。
    // WhyNot: いつも頂点の SHA-256 を取らない — ブラウザでは 1 部屋の形 3 つで 30 ms を超え、部屋を読むたびに積もる。
    pub def fromGlbKeyed(key: String, bytes: Vector[Int8]): Result[String, Model3d.Model3d] =
        fromGlb(bytes) |> Result.map(model ->
            { mesh = Mesh3d.withContentKey("${key}#all", model#mesh),
              parts = model#parts |> List.mapWithIndex((k, part) -> { mesh = Mesh3d.withContentKey("${key}#part${k}", part#mesh) | part }) | model })

    /// 材質の絵の長い辺の上限（px）。baseColor = baseColorTexture と emissiveTexture（同じ色の絵）・normal = normalTexture。
    /// 上限を超える絵は mip と同じ縮め方で半分にしていく。
    pub type alias TextureLimits = { baseColor = Int32, normal = Int32 }

    /// 上限なし。ほかの値は { normal = 1024 | Gltf.noTextureLimits() } の形で替える。
    pub def noTextureLimits(): TextureLimits = { baseColor = Texture3d.maxSide(), normal = Texture3d.maxSide() }

    /// path の .glb を、絵と材質つきで読む。parts に材質（baseColorTexture → Scene3d.texturedMaterial・normalTexture → 法線マップ・
    /// emissive → emission・sampler の wrap）、textures に BIN に埋めた画像（decoder で解く）。baseColorFactor は頂点の色に書き込んであり、VertexColor で掛かる。
    /// 絵も emissive も無い材質の primitive は材質 None（頂点の色で描く）。読めない・壊れている時は Err（パスつき）。
    /// emissive（emissiveFactor。emissiveTexture があれば絵 × それ。KHR_materials_emissive_strength は Scene3d.withEmissionIntensity）の付く材質は光る
    /// （glTF の決まりどおり。止めるなら Scene3d.withoutEmission）。emissive の付く材質の spec の名前は "gltf:" で始まり、
    /// 木の形を変える物（絵の読み方・emissiveFactor の値・絵の有無）を全部名前に入れる（strength は木の外の倍率なので入れない）。emissive の無い材質は Scene3d.texturedMaterial のまま。
    /// emissiveTexture を指しているのに読めない時（texCoord ≠ 0・画像が読めない・形に TEXCOORD_0 が無い）は光らせず、材質ごとに 1 行知らせる。
    /// decoder は読み込みの頭で LoadProgress.imageDecoder() で受け取り、並列の仕事へ渡す。
    /// limits は材質の絵の大きさの上限（場面の絵の上限に収める・近くで見ない法線マップを小さくする）。上限を掛けないなら noTextureLimits()。
    pub def loadTexturedUsing(decoder: ImageData.ImageDecoder, limits: TextureLimits, path: String): Result[String, Model3d.Model3d] \ Fs.FileRead + IO =
        loadWith(fromGlbTexturedUsing(decoder, limits), path)

    /// loadTexturedUsing のバイトの版。
    pub def fromGlbTexturedUsing(decoder: ImageData.ImageDecoder, limits: TextureLimits, bytes: Vector[Int8]): Result[String, Model3d.Model3d] \ IO =
        fromGlbTexturedBy(Texture3d.decodeUsing(decoder), limits, bytes)

    def fromGlbTexturedBy(decode: Vector[Int8] -> Result[String, Texture3d.Texture3d] \ IO, limits: TextureLimits,
                          bytes: Vector[Int8]): Result[String, Model3d.Model3d] \ IO =
        match parseAndBuild(bytes) {
            case Err(e) => Err(e)
            case Ok((glb, built)) =>
                let used = usedImages(limits, glb#json);
                let images = objectsOf("images", glb#json) |> Vector.mapWithIndex((k, image) -> match Map.get(k, used) {
                    case Some(maxSide) => decodeImage(decode, glb, image) |> (decoded -> (Option.map(Texture3d.limitSize(maxSide), fst(decoded)), snd(decoded)))
                    case None          => (None, Nil)
                });
                let decoded = images |> Vector.map(fst);
                let materials = objectsOf("materials", glb#json) |> Vector.mapWithIndex(materialOf(glb, decoded));
                let (parts, attachLines) = attachMaterials(built, materials);
                let lines = List.flatten((Vector.toList(images) |> List.flatMap(snd)) :: attachLines :: Nil) |> List.distinct;
                Ok(Log.warnAllThen(List.append(warningsOf(glb#json, built#jointOfNode), lines),
                                   { parts = parts, textures = Vector.toList(decoded) |> List.filterMap(identity) | built#model }))
        }

    /// path を読んでバイトの版 fromBytes へ渡す（読めない時と Err にパスを付ける）。
    def loadWith(fromBytes: Vector[Int8] -> Result[String, Model3d.Model3d] \ ef, path: String): Result[String, Model3d.Model3d] \ ef + Fs.FileRead =
        Fs.FileRead.readBytes(path)
            |> Result.mapErr(e -> "${path}: 読めない（${e}）")
            |> Result.flatMap(bytes -> fromBytes(bytes) |> Result.mapErr(e -> "${path}: ${e}"))

    def parseAndBuild(bytes: Vector[Int8]): Result[String, (Glb, Built)] =
        forM (
            glb <- parseGlb(bytes);
            _ <- checkBuffers(glb#json);
            built <- buildModel(glb)
        ) yield (glb, built)

    /// 材質の番号ごとに 1 回作った物。withUv = TEXCOORD_0 のある primitive に付ける材質・withoutUv = 無い primitive に付ける材質
    /// （emissiveTexture は uv で読むので、無い primitive には emission を外した材質）・noUvLine = withoutUv を使った時の知らせ。
    type alias MaterialBuild = { withUv = Option[Scene3d.Material3d], withoutUv = Option[Scene3d.Material3d], info = Model3d.GltfMaterial,
                                 lines = List[String], noUvLine = Option[String] }

    /// built の parts に、材質の番号ごとの materials を付ける。材質の知らせと、uv の無い part に withoutUv を付けた知らせも返す。
    def attachMaterials(built: Built, materials: Vector[MaterialBuild]): (List[Model3d.ModelPart], List[String]) =
        let assigned = List.zip(built#model#parts, built#partMaterials) |> List.map(pm -> {
            let (part, index) = pm;
            assignMaterial(part, index |> Option.flatMap(k -> Vector.nth(k, materials)))
        });
        (List.map(fst, assigned), List.append(Vector.toList(materials) |> List.flatMap(m -> m#lines), assigned |> List.flatMap(snd)))

    /// part に材質を付ける（part の形の uv の有無で withUv か withoutUv を選ぶ）。withoutUv を選んだ時の知らせも返す。
    def assignMaterial(part: Model3d.ModelPart, build: Option[MaterialBuild]): (Model3d.ModelPart, List[String]) =
        let hasUv = Option.nonEmpty(Mesh3d.uvs(part#mesh));
        let material = build |> Option.flatMap(b -> if (hasUv) b#withUv else b#withoutUv);
        let line = if (hasUv) Nil else build |> Option.flatMap(b -> b#noUvLine) |> Option.toList;
        ({ material = material, gltfMaterial = Option.map(b -> b#info, build) | part }, line)

    /// emissive が 0 でなく texCoord が 0 の emissiveTexture（光らせるのに読む絵）と、その上限。
    def emissiveImageOf(limits: TextureLimits, material: Obj): List[(Obj, Int32)] =
        let info = objectOf("emissiveTexture", material);
        if (isZeroColor(emissiveOf(material)) or Option.getWithDefault(0, intOf("texCoord", info)) != 0) Nil
        else (info, limits#baseColor) :: Nil

    /// 材質の baseColorTexture・normalTexture・emissiveTexture（emissive が 0 でない材質だけ）が指す画像の番号 → その絵の長い辺の上限
    /// （2 つ以上から指されたら大きい方）。
    // WhyNot: 全部の画像を decode しない — metallicRoughness・occlusion の絵は描くのに使わず、2048² なら 1 枚 16 MB をヒープに持つ。
    def usedImages(limits: TextureLimits, json: Obj): Map[Int32, Int32] =
        let textures = objectsOf("textures", json);
        objectsOf("materials", json) |> Vector.toList
            |> List.flatMap(material -> (objectOf("baseColorTexture", objectOf("pbrMetallicRoughness", material)), limits#baseColor)
                                        :: (objectOf("normalTexture", material), limits#normal)
                                        :: emissiveImageOf(limits, material))
            |> List.filterMap(entry -> { let (info, maxSide) = entry; intOf("index", info) |> Option.map(k -> (k, maxSide)) })
            |> List.filterMap(entry -> { let (k, maxSide) = entry; Vector.nth(k, textures) |> Option.flatMap(texture -> intOf("source", texture)) |> Option.map(src -> (src, maxSide)) })
            |> List.foldLeft((acc, entry) -> { let (src, maxSide) = entry; Map.insertWith((a, b) -> Int32.max(a, b), src, maxSide, acc) }, Map.empty())

    /// images[k] を絵に戻す（BIN の bufferView の PNG / JPEG）。外の uri・読めない画像は None と知らせる 1 行。
    def decodeImage(decode: Vector[Int8] -> Result[String, Texture3d.Texture3d] \ IO, glb: Glb, image: Obj): (Option[Texture3d.Texture3d], List[String]) \ IO =
        match (intOf("bufferView", image), stringOf("uri", image)) {
            case (Some(view), _) =>
                match Result.flatMap(decode, viewBytes(glb, view)) {
                    case Ok(t)  => (Some(t), Nil)
                    case Err(e) => (None, "glTF: 画像が読めないので、その絵の材質は頂点の色で描く（${e}）" :: Nil)
                }
            case (None, Some(_)) => (None, "glTF: 外の uri の画像は読まない — その絵の材質は頂点の色で描く（画像は .glb に埋める）" :: Nil)
            case (None, None)    => (None, "glTF: bufferView も uri も無い画像を読み飛ばした" :: Nil)
        }

    /// bufferView のバイト（BIN の中）。
    def viewBytes(glb: Glb, viewIndex: Int32): Result[String, Vector[Int8]] =
        forM (
            view <- objectAt("bufferViews", viewIndex, glb#json);
            bin <- glb#bin |> Option.toOk("glTF: BIN のチャンクが無い");
            length <- intOf("byteLength", view) |> Option.toOk("glTF: bufferViews[${viewIndex}] に byteLength が無い");
            offset <- Ok(Option.getWithDefault(0, intOf("byteOffset", view)));
            _ <- require(offset >= 0 and length >= 0 and offset + length <= bin#length, "glTF: bufferViews[${viewIndex}] が BIN の外を指す")
        ) yield Vector.slice(start = bin#start + offset, end = bin#start + offset + length, glb#bytes)

    /// 材質 index 1 つ（材質の番号ごとに 1 回）:
    ///
    /// | baseColorTexture | emissive | 材質 |
    /// |---|---|---|
    /// | 読めた | 0 | Scene3d.texturedMaterial（spec の名前もそのまま） |
    /// | 読めた | 0 でない | texturedMaterial + emission・spec の名前は "gltf:tex:<絵の読み方>:<emissive>" |
    /// | 無い | 0 でない | 頂点の色の材質 + emission・spec の名前は "gltf:vc:<emissive>" |
    /// | 無い | 0 | None（頂点の色で描く） |
    ///
    /// texturedMaterial の絵の読み方は sampler の magFilter（NEAREST なら Nearest・ほかは Linear）、wrapS か wrapT が CLAMP_TO_EDGE なら Clamp。
    /// 法線マップは baseColorTexture のある材質にだけ足す（strength = scale・既定 1）。読み飛ばした物の知らせも返す。
    /// alphaMode（材質のある物だけ）: BLEND → Scene3d.withAlphaBlend(true)・MASK → Scene3d.withCutout(true)（alphaCutoff は 0.5 の固定。
    /// 0.5 でなければ 1 行知らせる）・OPAQUE → そのまま。doubleSided は当てない（Blender の書き出しは全部の材質を真にするので、
    /// 両面で描く物はゲームが gltfMaterial を見て Scene3d.withDoubleSided を当てる）。
    def materialOf(glb: Glb, images: Vector[Option[Texture3d.Texture3d]], index: Int32, material: Obj): MaterialBuild =
        let pbr = objectOf("pbrMetallicRoughness", material);
        let base = textureRefOf(glb, images, objectOf("baseColorTexture", pbr));
        let normal = textureRefOf(glb, images, objectOf("normalTexture", material));
        let emission = emissionOf(glb, images, index, material);
        let names = { base = fst(base) |> Option.map(r -> Texture3d.name(r#texture)),
                      normal = fst(normal) |> Option.map(r -> Texture3d.name(r#texture)),
                      emissive = emission#texture |> Option.map(r -> Texture3d.name(r#texture)) };
        let surface = fst(base) |> Option.map(ref -> {
            let textured = Scene3d.texturedMaterial(Texture3d.name(ref#texture), ref#filter) |> Scene3d.withWrap(ref#wrap);
            match fst(normal) {
                case Some(n) =>
                    let strength = numberAt("scale", objectOf("normalTexture", material)) |> Option.getWithDefault(1.0);
                    textured |> Scene3d.withNormalMap({ texture = Texture3d.name(n#texture), strength = strength })
                case None => textured
            }
        });
        let baseName = fst(base) |> Option.map(r -> "tex:${ToString.toString(r#filter)}") |> Option.getWithDefault("vc");
        let lit = (e: Option[EmissionBuild]) -> match (surface, e) {
            case (_, None)          => surface
            case (Some(m), Some(b)) => Some(m |> Scene3d.withEmission(b#shade) |> Scene3d.withEmissionIntensity(b#strength) |> Scene3d.withSpecName("gltf:${baseName}:${b#name}"))
            case (None, Some(b))    => Some(vertexColorMaterial("gltf:${baseName}:${b#name}") |> Scene3d.withEmission(b#shade) |> Scene3d.withEmissionIntensity(b#strength) |> Scene3d.withWrap(b#wrap))
        };
        let usesTexture = Option.nonEmpty(emission#texture);
        let info = gltfMaterialOf(names, material);
        let withAlpha = (m: Option[Scene3d.Material3d]) -> m |> Option.map(withAlphaModeOf(info#alphaMode));
        let withUv = withAlpha(lit(emission#build));
        // WhyNot: 材質の無い（頂点の色で描く）物の alphaCutoff を知らせない — α を持たないので抜く所が無い。
        let cutoffLine = if (Option.isEmpty(withUv)) Nil else alphaCutoffLine(index, material, info);
        { withUv = withUv, withoutUv = withAlpha(lit(if (usesTexture) None else emission#build)),
          info = info,
          lines = List.flatten(snd(base) :: snd(normal) :: emission#lines :: emissiveFactorLine(index, material) :: cutoffLine :: Nil),
          noUvLine = if (usesTexture) Some("glTF: 材質 ${materialLabel(index, material)} の emissiveTexture を、TEXCOORD_0 の無い形では光らせない（uv で読む絵）") else None }

    /// glTF の alphaMode を材質に当てる（BLEND は半透明・MASK は α 0.5 で抜く・OPAQUE はそのまま）。
    def withAlphaModeOf(mode: Model3d.AlphaMode, m: Scene3d.Material3d): Scene3d.Material3d = match mode {
        case Model3d.AlphaMode.Opaque => m
        case Model3d.AlphaMode.Mask   => Scene3d.withCutout(true, m)
        case Model3d.AlphaMode.Blend  => Scene3d.withAlphaBlend(true, m)
    }

    /// MASK の材質の alphaCutoff が 0.5 でない時の知らせ（0.5 で抜く）。
    def alphaCutoffLine(index: Int32, material: Obj, info: Model3d.GltfMaterial): List[String] =
        if (info#alphaMode == Model3d.AlphaMode.Mask and info#alphaCutoff != 0.5)
            "glTF: 材質 ${materialLabel(index, material)} の alphaCutoff ${Float64.toString(info#alphaCutoff)} は使わず、α 0.5 で抜く" :: Nil
        else Nil

    /// 材質を知らせの中で名指す字（name があれば name・無ければ番号）。
    def materialLabel(index: Int32, material: Obj): String =
        stringOf("name", material) |> Option.map(n -> "'${n}'") |> Option.getWithDefault("materials[${index}]")

    /// 頂点の色をそのまま光を当てる前の色にする材質（α 1）。emissive だけの材質の土台。
    def vertexColorMaterial(name: String): Scene3d.Material3d =
        let vc = (chan: ShaderDoc.TexChan) -> ShaderDoc.Field.VertexColor({ chan = chan });
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Rgb({ r = vc(ShaderDoc.TexChan.R), g = vc(ShaderDoc.TexChan.G),
                                                                                    b = vc(ShaderDoc.TexChan.B) }),
                                                      alpha = ShaderDoc.Field.Const(1.0) }) })

    /// 材質の emission。shade = 足す色・name = spec の名前に入れる字（"et<絵の読み方>(r,g,b)" = 絵 × 定数・"ec(r,g,b)" = 定数だけ）・
    /// wrap = emissive の絵の sampler の wrap（baseColorTexture の無い材質の wrap にする。ある材質は baseColorTexture の wrap のまま）・
    /// strength = KHR_materials_emissive_strength（Scene3d.withEmissionIntensity に渡す）。
    type alias EmissionBuild = { shade = ShaderDoc.Shade, name = String, wrap = Scene3d.Wrap, strength = Float64 }

    /// build = 付ける emission（emissive が 0・絵を指しているのに読めない時は None）・texture = 読めた emissiveTexture・lines = 知らせ。
    type alias EmissionOf = { build = Option[EmissionBuild], texture = Option[TextureRef], lines = List[String] }

    /// emissive の色 c = emissiveFactor。emissiveTexture を指していなければ Solid(c)、指していて読めれば 絵の rgb × c。strength は木に入れない
    /// （線形へ戻した後に掛ける倍率。強さだけ違う材質が同じプログラムを使う）。光るかどうかは emissiveFactor × strength が 0 でないかで決める。
    /// 指しているのに読めない時は付けない（Solid へ倒すと、Blender の書き出しの factor (1, 1, 1) × 強さで物全体が真っ白に光る）。
    def emissionOf(glb: Glb, images: Vector[Option[Texture3d.Texture3d]], index: Int32, material: Obj): EmissionOf =
        let c = emissiveFactorOf(material);
        let strength = emissiveStrengthOf(material);
        let info = objectOf("emissiveTexture", material);
        let digits = "(${Float64.toString(c#r)},${Float64.toString(c#g)},${Float64.toString(c#b)})";
        if (isZeroColor(emissiveOf(material))) { build = None, texture = None, lines = Nil }
        else if (Option.isEmpty(intOf("index", info)))
            { build = Some({ shade = ShaderDoc.Shade.Solid(Color.rgb(c#r, c#g, c#b)), name = "ec${digits}", wrap = Scene3d.Wrap.Repeat, strength = strength }), texture = None, lines = Nil }
        else match textureRefOf(glb, images, info) {
            case (Some(ref), lines) =>
                let read = (chan: ShaderDoc.TexChan, k: Float64) ->
                    ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul, b = ShaderDoc.Field.Const(k),
                                          a = ShaderDoc.Field.Sampler({ filter = ref#filter, of = ShaderDoc.Field.Tex({ name = Texture3d.name(ref#texture), chan = chan }) }) });
                { build = Some({ shade = ShaderDoc.Shade.Rgb({ r = read(ShaderDoc.TexChan.R, c#r), g = read(ShaderDoc.TexChan.G, c#g), b = read(ShaderDoc.TexChan.B, c#b) }),
                                 name = "et${ToString.toString(ref#filter)}${digits}", wrap = ref#wrap, strength = strength }),
                  texture = Some(ref), lines = lines }
            case (None, lines) =>
                { build = None, texture = None,
                  lines = "glTF: 材質 ${materialLabel(index, material)} の emissiveTexture が読めないので光らせない" :: lines }
        }

    /// emissiveFactor（既定 (0, 0, 0)）× KHR_materials_emissive_strength の emissiveStrength（既定 1）。負と NaN は 0。
    /// emissiveFactor が 3 つの数でない材質は (0, 0, 0)（知らせは emissiveFactorLine が材質ごとに 1 行）。
    def emissiveOf(material: Obj): { r = Float64, g = Float64, b = Float64 } =
        let c = emissiveFactorOf(material);
        let strength = emissiveStrengthOf(material);
        let at = (v: Float64) -> { let x = v * strength; if (x > 0.0) x else 0.0 };
        { r = at(c#r), g = at(c#g), b = at(c#b) }

    /// emissiveFactor（既定 (0, 0, 0)）。負と NaN は 0。3 つの数でない材質は (0, 0, 0)。
    def emissiveFactorOf(material: Obj): { r = Float64, g = Float64, b = Float64 } =
        let factor = numbersOf("emissiveFactor", 3, material) |> Result.toOption |> Option.flatMap(identity)
            |> Option.getWithDefault(Vector#{ 0.0, 0.0, 0.0 });
        let at = (k: Int32) -> { let v = Vector.get(k, factor); if (v > 0.0) v else 0.0 };
        { r = at(0), g = at(1), b = at(2) }

    /// KHR_materials_emissive_strength の emissiveStrength（既定 1）。負と NaN は 0。
    def emissiveStrengthOf(material: Obj): Float64 =
        let s = numberAt("emissiveStrength", objectOf("KHR_materials_emissive_strength", objectOf("extensions", material)))
            |> Option.getWithDefault(1.0);
        if (s > 0.0) s else 0.0

    /// emissiveFactor が 3 つの数でない時の知らせ（emissiveOf が (0, 0, 0) にした事）。
    def emissiveFactorLine(index: Int32, material: Obj): List[String] = match numbersOf("emissiveFactor", 3, material) {
        case Err(e) => "${e}（材質 ${materialLabel(index, material)}）— emissive を (0, 0, 0) として読む" :: Nil
        case Ok(_)  => Nil
    }

    def isZeroColor(c: { r = Float64, g = Float64, b = Float64 }): Bool = c#r <= 0.0 and c#g <= 0.0 and c#b <= 0.0

    /// GltfMaterial の絵の名前の欄（読めた絵の Texture3d.name）。
    type alias TextureNames = { base = Option[String], normal = Option[String], emissive = Option[String] }

    def noTextureNames(): TextureNames = { base = None, normal = None, emissive = None }

    /// glTF の材質の欄を読む（alphaMode は MASK・BLEND の他は Opaque・alphaCutoff 既定 0.5・doubleSided 既定 偽）。
    def gltfMaterialOf(names: TextureNames, material: Obj): Model3d.GltfMaterial =
        let alphaMode = match stringOf("alphaMode", material) {
            case Some("MASK")  => Model3d.AlphaMode.Mask
            case Some("BLEND") => Model3d.AlphaMode.Blend
            case _             => Model3d.AlphaMode.Opaque
        };
        { name = stringOf("name", material) |> Option.getWithDefault(""), alphaMode = alphaMode,
          alphaCutoff = numberAt("alphaCutoff", material) |> Option.getWithDefault(0.5),
          doubleSided = Map.get("doubleSided", material) == Some(Util.Json.Json.JBool(true)),
          baseColorTexture = names#base, normalTexture = names#normal, emissiveTexture = names#emissive,
          emissive = emissiveOf(material) }

    /// textureInfo（{ index, texCoord, extensions }）が指す絵と、sampler の読み方。
    type alias TextureRef = { texture = Texture3d.Texture3d, filter = ShaderDoc.FilterMode, wrap = Scene3d.Wrap }

    def textureRefOf(glb: Glb, images: Vector[Option[Texture3d.Texture3d]], info: Obj): (Option[TextureRef], List[String]) =
        let transformLine = if (Map.memberOf("KHR_texture_transform", objectOf("extensions", info)))
            "glTF: KHR_texture_transform を読み飛ばした（uv をずらさず・回さずに読む）" :: Nil else Nil;
        match intOf("index", info) {
            case None => (None, Nil)
            case Some(_) if Option.getWithDefault(0, intOf("texCoord", info)) != 0 =>
                (None, "glTF: texCoord が 0 でない絵を読み飛ばした（TEXCOORD_0 だけを読む）" :: transformLine)
            case Some(k) =>
                let texture = objectsOf("textures", glb#json) |> Vector.nth(k) |> Option.getWithDefault(Map.empty());
                let sampler = intOf("sampler", texture) |> Option.flatMap(sk -> Vector.nth(sk, objectsOf("samplers", glb#json)))
                    |> Option.getWithDefault(Map.empty());
                let wraps = intOf("wrapS", sampler) :: intOf("wrapT", sampler) :: Nil;
                let mirroredLine = if (List.exists(w -> w == Some(33648), wraps))
                    "glTF: MIRRORED_REPEAT を REPEAT として読んだ" :: Nil else Nil;
                let filter = if (intOf("magFilter", sampler) == Some(9728)) ShaderDoc.FilterMode.Nearest else ShaderDoc.FilterMode.Linear;
                let wrap = if (List.exists(w -> w == Some(33071), wraps)) Scene3d.Wrap.Clamp else Scene3d.Wrap.Repeat;
                let found = intOf("source", texture) |> Option.flatMap(src -> Vector.nth(src, images)) |> Option.flatMap(identity);
                (Option.map(t -> { texture = t, filter = filter, wrap = wrap }, found), List.append(transformLine, mirroredLine))
        }

    def numberAt(key: String, o: Obj): Option[Float64] = Map.get(key, o) |> Option.flatMap(numberOf)

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
        let len = (i: Int32) -> Num.sqrt(c(i) * c(i) + c(i + 1) * c(i + 1) + c(i + 2) * c(i + 2));
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
                let s = Num.sqrt(trace + 1.0) * 2.0;
                { x = (m(2, 1) - m(1, 2)) / s, y = (m(0, 2) - m(2, 0)) / s, z = (m(1, 0) - m(0, 1)) / s, w = 0.25 * s }
            } else if (m(0, 0) > m(1, 1) and m(0, 0) > m(2, 2)) {
                let s = Num.sqrt(1.0 + m(0, 0) - m(1, 1) - m(2, 2)) * 2.0;
                { x = 0.25 * s, y = (m(0, 1) + m(1, 0)) / s, z = (m(0, 2) + m(2, 0)) / s, w = (m(2, 1) - m(1, 2)) / s }
            } else if (m(1, 1) > m(2, 2)) {
                let s = Num.sqrt(1.0 + m(1, 1) - m(0, 0) - m(2, 2)) * 2.0;
                { x = (m(0, 1) + m(1, 0)) / s, y = 0.25 * s, z = (m(1, 2) + m(2, 1)) / s, w = (m(0, 2) - m(2, 0)) / s }
            } else {
                let s = Num.sqrt(1.0 + m(2, 2) - m(0, 0) - m(1, 1)) * 2.0;
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

    def buildModel(glb: Glb): Result[String, Built] =
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
                nested <- Vector.toList(meshNodes) |> Result.traverse(i -> nodeParts(glb, nodes, parentOf, skinBuild, i) |> Result.map(ps -> (i, ps)));
                parts <- Ok(nested |> List.flatMap(snd));
                mesh <- meshOfParts(parts, Option.nonEmpty(skinBuild));
                partMeshes <- parts |> Result.traverse(part -> partMeshOf(part, Option.nonEmpty(skinBuild)));
                clips <- readAnimations(glb, Option.map(b -> b#jointOfNode, skinBuild) |> Option.getWithDefault(Map.empty()))
            ) yield {
                let partNodes = nested |> List.flatMap(np -> List.map(_ -> fst(np), snd(np)));
                { model = { mesh = mesh, skin = Option.map(b -> b#skin, skinBuild), clips = clips,
                            parts = List.zip(partMeshes, partNodes) |> List.map(mn -> { mesh = fst(mn), material = None, node = Some(snd(mn)), gltfMaterial = None }),
                            textures = Nil, nodes = modelNodesOf(glb, nodes, parentOf, partNodes) },
                  jointOfNode = Option.map(b -> b#jointOfNode, skinBuild) |> Option.getWithDefault(Map.empty()),
                  partMaterials = parts |> List.map(p -> p#material) }
            }
        }

    // ── ノードの一覧（Model3d.nodes）──

    /// glTF の nodes の全部を ModelNode にする（world は根から親の順に 1 巡で掛ける）。parentOf = parentsOfNodes(nodes)・partNodes = parts の並びの、各 part のノードの番号。
    /// 行列が読めないノード（matrix が 16 個の数でない等）は単位行列で続けて 1 行知らせる。根から辿れないノード（木が輪になっている）は world = local。
    // WhyNot: nodeParts の chainOf / productOf で world を出さない — ノードごとに根まで辿るので、ノード n 個・深さ d で n·d 回掛ける。
    // WhyNot: 部品の形の焼き込み（nodeParts）をこの 1 巡に寄せない — 骨つきの glb の部品の頂点が 1 bit でも変わると、描き出しの鍵が変わる。
    def modelNodesOf(glb: Glb, nodes: Vector[Obj], parentOf: Map[Int32, Int32], partNodes: List[Int32]): List[Model3d.ModelNode] =
        let count = Vector.length(nodes);
        let localsGl = nodes |> Vector.mapWithIndex((i, node) -> match nodeMatrix(node) {
            case Ok(m)  => m
            case Err(e) => Log.warnThen("glTF: nodes[${i}] の行列を単位行列として読む（${e}）", Mat4.identity())
        });
        let children = nodes |> Vector.map(node -> intsOf("children", node) |> Vector.filter(c -> c >= 0 and c < count));
        let roots = Vector.range(0, count) |> Vector.filter(i -> not Map.memberOf(i, parentOf)) |> Vector.toList;
        let worldsGl = roots |> List.foldLeft((acc, root) -> worldsFrom(localsGl, children, root, Mat4.identity(), acc), Map.empty());
        let partsOf = List.zipWithIndex(partNodes) |> List.foldRight((kn, acc) -> {
            let (k, n) = kn;
            Map.insertWith((fresh, old) -> List.append(fresh, old), n, k :: Nil, acc)
        }, Map.empty());
        Vector.range(0, count) |> Vector.toList |> List.map(i -> {
            let node = Vector.get(i, nodes);
            let local = Vector.get(i, localsGl);
            { name = stringOf("name", node) |> Option.getWithDefault(""), parent = Map.get(i, parentOf),
              local = mirrorMat4(local), world = mirrorMat4(Map.getWithDefault(i, local, worldsGl)),
              localBounds = intOf("mesh", node) |> Option.flatMap(localBoundsOfMesh(glb)),
              parts = Map.getWithDefault(i, Nil, partsOf) }
        })

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
        let prims = objectAt("meshes", meshIndex, glb#json) |> Result.toOption |> Option.map(m -> objectsOf("primitives", m))
            |> Option.getWithDefault(Vector.empty());
        prims |> Vector.toList
            |> List.filterMap(prim -> intOf("POSITION", objectOf("attributes", prim)) |> Option.flatMap(positionBoundsOf(glb)))
            |> List.reduceLeft((a, b) -> { min = Vec3.v3(Float64.min(a#min#x, b#min#x), Float64.min(a#min#y, b#min#y), Float64.min(a#min#z, b#min#z)),
                                           max = Vec3.v3(Float64.max(a#max#x, b#max#x), Float64.max(a#max#y, b#max#y), Float64.max(a#max#z, b#max#z)) })

    def positionBoundsOf(glb: Glb, accessorIndex: Int32): Option[Mesh3d.Bounds] =
        let declared = forM (
            acc <- objectAt("accessors", accessorIndex, glb#json) |> Result.toOption;
            low <- numbersOf("min", 3, acc) |> Result.toOption |> Option.flatMap(identity);
            high <- numbersOf("max", 3, acc) |> Result.toOption |> Option.flatMap(identity)
        ) yield (vec3At(low, 0), vec3At(high, 0));
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
            let uvs = optionalAttribute(glb, attributes, "TEXCOORD_0", 2, count);
            let uvs2 = optionalAttribute(glb, attributes, "TEXCOORD_1", 2, count);
            let tangents = optionalAttribute(glb, attributes, "TANGENT", 4, count);
            let indexList = match indices {
                case Some(a) => Vector.map(toIndex, a#values)
                case None => Vector.range(0, count)
            };
            let normalMat = Mat4.normalMatrix(transform);
            let placedPositions = flatXyz(Vector.range(0, count) |> Vector.map(v -> Mat4.apply(transform, vec3At(positions#values, v * 3))));
            let placedNormals = Option.map(n -> flatXyz(Vector.range(0, count) |> Vector.map(v ->
                Vec3.normalized(Mat4.applyDir(normalMat, vec3At(n#values, v * 3))))), normals);
            let placedTangents = forM (_ <- uvs; t <- tangents) yield placeTangents(transform, t#values);
            let part = { positions = placedPositions, normals = Option.getWithDefault(Vector.empty(), placedNormals),
                         colors = rowsOf(count, Vector.length(color), (_, c) -> Vector.get(c, color)), indices = indexList,
                         joints = fst(skin), weights = snd(skin), uvs = Option.map(a -> a#values, uvs), tangents = placedTangents,
                         uvs2 = Option.map(a -> a#values, uvs2), material = intOf("material", prim) };
            if (Option.nonEmpty(normals)) part else flatShaded(part)
        }

    /// 無くても形は描ける頂点の欄（TEXCOORD_0・TANGENT）を読む。読めない・数が頂点の数と違う・NaN か無限がある時は、
    /// その欄を使わずに続けて 1 行知らせる（None）。
    // WhyNot: Err にしない — uv を使わない fromGlb まで読めなくなる。形（POSITION・indices）が読めれば描ける。
    def optionalAttribute(glb: Glb, attributes: Obj, key: String, width: Int32, count: Int32): Option[Accessor] =
        match traverseOpt(intOf(key, attributes), k -> readAccessorWidth(glb, k, width, key)) {
            case Ok(None)    => None
            case Ok(Some(a)) => usableAttribute(key, count, a)
            case Err(e)      => Log.warnThen("${e} — ${key} を使わずに読む", None)
        }

    /// 読めた欄 a が頂点の数 count とそろい、全部が有限の数なら Some。違えば 1 行知らせて None。
    def usableAttribute(key: String, count: Int32, a: Accessor): Option[Accessor] =
        if (a#count != count) Log.warnThen("glTF: ${key} の数 ${a#count} が頂点の数 ${count} と違う — ${key} を使わずに読む", None)
        else if (Vector.exists(x -> Float64.isNan(x) or Float64.isInfinite(x), a#values))
            Log.warnThen("glTF: ${key} に NaN か無限がある — ${key} を使わずに読む", None)
        else Some(a)

    /// TANGENT を置き場所の行列 transform で写す（xyz は左上 3×3 を掛けて長さ 1 に・行列が裏返すなら w の符号も裏返す）。
    // WhyNot: 法線の行列で写さない — タンジェントは面の上の向きで、置き場所の行列のまま写る。
    def placeTangents(transform: Mat4.Mat4, values: Vector[Float64]): Vector[Float64] =
        let c = Mat4.toColumns(transform);
        let col = (j: Int32) -> Vec3.v3(Vector.get(j * 4, c), Vector.get(j * 4 + 1, c), Vector.get(j * 4 + 2, c));
        let flip = if (Vec3.dot(col(0), Vec3.cross(col(1), col(2))) < 0.0) -1.0 else 1.0;
        let count = Vector.length(values) / 4;
        let placed = Vector.range(0, count) |> Vector.map(v -> Vec3.normalized(Mat4.applyDir(transform, vec3At(values, v * 4))));
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

    /// baseColorFactor をそのまま頂点の色にする。材質や baseColorFactor が無ければ白。
    // WhyNot: glTF の決まりどおり線形の値として読まない — OBJ の Kd も Blender の値を画面の値（sRGB の値）として読む。
    //   片方だけ直すと同じ Blender の色が形式で違って見える。COLOR_0 と emissiveFactor も同じく画面の値として読む。
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
        let faceNormals = Vector.range(0, tris) |> Vector.map(t -> {
            let p = c -> vec3At(part#positions, corner(t, c) * 3);
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
          material = part#material }

    /// count 行 × width 列の並び（行 k・列 c の値は cell(k, c)）。
    // WhyNot: 行ごとの小さな Vector を Vector.flatMap でつながない — 頂点数万の glb で数百 ms かかる。
    def rowsOf(count: Int32, width: Int32, cell: (Int32, Int32) -> a \ ef): Vector[a] \ ef =
        Vector.range(0, count * width) |> Vector.map(j -> cell(j / width, Int32.remainder(j, width)))

    /// src（頂点ごとに width 個）から、sources の頂点の順に写した並び。
    def gather(width: Int32, src: Vector[a], sources: Vector[Int32]): Vector[a] =
        rowsOf(Vector.length(sources), width, (k, c) -> Vector.get(Vector.get(k, sources) * width + c, src))

    def flatXyz(vs: Vector[Vec3.Vec3]): Vector[Float64] = rowsOf(Vector.length(vs), 3, (k, c) -> component(c, Vector.get(k, vs)))

    def component(c: Int32, v: Vec3.Vec3): Float64 = if (c == 0) v#x else if (c == 1) v#y else v#z

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
    def partMeshOf(part: Part, skinned: Bool): Result[String, Mesh3d.Mesh3d] =
        Result.map(mesh -> part#uvs |> Option.map(uv -> withPartUvs(part, uv, mesh)) |> Option.getWithDefault(mesh)
                               |> withPartUvs2(part),
                   meshOfParts(part :: Nil, skinned))

    def withPartUvs2(part: Part, mesh: Mesh3d.Mesh3d): Mesh3d.Mesh3d =
        part#uvs2 |> Option.map(uv -> attachUvs2(uv, mesh)) |> Option.getWithDefault(mesh)

    def attachUvs2(uv: Vector[Float64], mesh: Mesh3d.Mesh3d): Mesh3d.Mesh3d =
        match Mesh3d.withUvs2(uv, mesh) {
            case Ok(withSecond) => withSecond
            case Err(e)         => Log.warnThen("glTF: TEXCOORD_1 を使わずに読む（${e}）", mesh)
        }

    /// mesh に uv を付け、part に TANGENT があればそれも付ける。uv を付けられなければ mesh のまま。
    def withPartUvs(part: Part, uv: Vector[Float64], mesh: Mesh3d.Mesh3d): Mesh3d.Mesh3d =
        match Mesh3d.withUvs(uv, mesh) {
            case Ok(textured) => part#tangents |> Option.map(t -> withPartTangents(t, textured)) |> Option.getWithDefault(textured)
            case Err(e)       => Log.warnThen("glTF: uv を使わずに読む（${e}）", mesh)
        }

    /// TANGENT の x と w の符号を反転して付ける。付けられなければ uv から求めた物のまま。
    def withPartTangents(tangents: Vector[Float64], textured: Mesh3d.Mesh3d): Mesh3d.Mesh3d =
        let mirrored = Vector.mapWithIndex((k, x) -> if (Int32.remainder(k, 4) == 0 or Int32.remainder(k, 4) == 3) 0.0 - x else x, tangents);
        match Mesh3d.withTangents(mirrored, textured) {
            case Ok(m)  => m
            case Err(e) => Log.warnThen("glTF: TANGENT を使えないので uv から求め直した（${e}）", textured)
        }

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
