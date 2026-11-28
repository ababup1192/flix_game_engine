// Gltf — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// glTF 2.0 のバイナリ（.glb）を読む: メッシュ・スキン・頂点のジョイントの重み・アニメーション・uv（TEXCOORD_0）とタンジェント（TANGENT）。
/// BIN に埋めた画像（PNG / JPEG）と材質（baseColorTexture・normalTexture・emissive・sampler）も読む（ゲームの入口は Model3d.loader / load / decode）。
/// ノードは全部（mesh の無いノードも）名前・行列・局所の境界つきで Model3d の nodes に入る（Model3d.findNode で引く）。
/// 右手系の glTF を左手系の engine へ X の反転（S = diag(−1, 1, 1)）で写す。glTF の正面 +Z は engine でも +Z のまま、
/// キャラの右手（glTF の −X）は engine の +X に来る。位置と法線は x を反転し、三角形の巡りを逆にする。
/// 回転は (x, −y, −z, w)、倍率はそのまま、行列（逆バインド行列・matrix のノード・rootTransform）は S·M·S。
/// 読まない物（Err）: 外の uri・data URI・sparse accessor・三角形以外の primitive・1 体 64 本を超えるジョイント。
/// 捨てて 1 回知らせる物: JOINTS_1 / WEIGHTS_1・ジョイントでないノードを動かす欄・CUBICSPLINE の接線。
/// 絵で読み飛ばして 1 行ずつ知らせる物: texCoord ≠ 0・KHR_texture_transform・MIRRORED_REPEAT（REPEAT で読む）・外の uri の画像。
// WhyNot: Mesh3d.fromObj と同じく反転せずに読まない — 左右の決まったキャラ（右手に剣）が鏡写しになる。
pub mod Gltf {

    /// 材質の絵の長い辺の上限（px）。baseColor = baseColorTexture と emissiveTexture（同じ色の絵）・normal = normalTexture。
    /// 上限を超える絵は mip と同じ縮め方で半分にしていく。
    pub type alias TextureLimits = { baseColor = Int32, normal = Int32 }

    /// 上限なし。ほかの値は { normal = 1024 | Gltf.noTextureLimits() } の形で替える。
    pub def noTextureLimits(): TextureLimits = { baseColor = Texture3d.maxSide(), normal = Texture3d.maxSide() }

    /// 読み方の選択肢。limits = 材質の絵の大きさの上限（場面の絵の上限に収める・近くで見ない法線マップを小さくする）・
    /// pbr = 材質の metallic・roughness も読み、baseColorFactor と emissiveFactor を線形の値として読む（付く条件・既定値・絵の読み方は materialOf の説明。
    /// metallicRoughnessTexture の画像もデコードする・上限は limits#baseColor）・
    /// vertexColors = 頂点の色 COLOR_0 を読み、線形の値 → 画面の値にして baseColorFactor に掛ける（Gltf.Internal.colorsOf。白は 1 のまま）。偽なら COLOR_0 は読まない・
    /// occlusion = metallic・roughness の付く材質の occlusionTexture も読み、材質の AO にする（Scene3d.withOcclusionTexture。pbr が偽なら読まない・上限は limits#baseColor）。
    /// ゲームは project.json の任意キー "gltf" に書く。
    // WhyNot: pbr を既定で真にしない — Blender の書き出しは絵も emissive も無い材質にも metallic・roughness を書くので、読むと今まで頂点の色だけだった
    //   part が材質を持つ物になり、part を束ねるゲームの条件（material が None）が外れて draw が増える。鏡面のプログラムも使う。ゲームが選んで読む。
    // WhyNot: vertexColors を既定で真にしない — Blender の書き出しは頂点の色の層があると COLOR_0 を書くので、
    //   今まで捨てていた白でない COLOR_0 を持つゲームの glb の色が engine を上げただけで変わる。読みたいゲームが選ぶ。
    // WhyNot: occlusion を既定で真にしない — 環境の光が当たる所の明るさが engine を上げただけで変わり、AO をベイクした lightmap と重ねると 2 回効く。読みたいゲームが選ぶ。
    pub type alias LoadOptions = { limits = TextureLimits, pbr = Bool, vertexColors = Bool, occlusion = Bool }

    /// 上限なし・metallic・roughness を読まない・COLOR_0 を読まない・AO の絵を読まない。欄を書き替えて使う: `{ vertexColors = true | Gltf.defaultLoadOptions() }`。
    pub def defaultLoadOptions(): LoadOptions = { limits = noTextureLimits(), pbr = false, vertexColors = false, occlusion = false }

    /// .glb のバイトから、絵と材質つきで作る。ゲームは Model3d.loader / load / decode を使う（engine のテストと bench が選択肢を直に渡す時の API）。
    /// 壊れている・読まない物を含む時は Err。TEXCOORD_0・TANGENT が読めない（数が頂点の数と違う・NaN か無限）時は、その欄を使わずに読んで 1 行知らせる。
    /// parts に材質（baseColorTexture → Scene3d.texturedMaterial・normalTexture → 法線マップ・emissive → emission・sampler の wrap）、
    /// textures に BIN に埋めた画像（decoder で解く・どの材質からも指されない絵は解かない）。baseColorFactor は頂点の色に書き込んであり、VertexColor で掛かる。
    /// 絵も emissive も無い材質の primitive は材質 None（頂点の色で描く）。
    /// emissive（emissiveFactor。emissiveTexture があれば絵 × それ。KHR_materials_emissive_strength は Scene3d.withEmissionIntensity）の付く材質は光る
    /// （glTF の決まりどおり。止めるなら Scene3d.withoutEmission）。emissive の付く材質の spec の名前は "gltf:" で始まり、
    /// 木の形を変える物（絵の読み方・emissiveFactor の値・絵の有無）を全部名前に入れる（strength は木の外の倍率なので入れない）。emissive の無い材質は Scene3d.texturedMaterial のまま。
    /// emissiveTexture を指しているのに読めない時（texCoord ≠ 0・画像が読めない・形に TEXCOORD_0 が無い）は光らせず、材質ごとに 1 行知らせる。
    /// key = Some なら、形の中身の鍵を key から作り（part ごとに "key#part<番号>"・まとめた形は "key#all"）、絵は機種が持てるなら機種の側に解いて持つ
    /// （ImageData.ImageDecoder の platformImageOfBytes・id は "key#image<番号>"。上限より大きい絵は画素へ戻して縮める）。
    /// key は同じ key なら同じバイトだと呼ぶ側が約束できる字（ImageData.ImageDecoder の versionedKey）。None（デスクトップの開発中のファイル）なら頂点から鍵を作る。
    /// 読み方は 2 つの手順（絵を使わずに形・ノード・骨・アニメ・材質の記述を読む ／ 絵を解いて材質と形の鍵を付ける）。
    pub def decodeWith(decoder: ImageData.ImageDecoder, options: LoadOptions, key: Option[String], bytes: Vector[Int8]): Result[String, Model3d.Model3d] \ IO =
        Gltf.Internal.Parse.parse(Gltf.Internal.Parse.readOptionsOf(options), bytes) |> Result.map(Gltf.Internal.assemble(decoder, options, key, bytes))

    /// parsed に絵と材質を付ける（decode = 画像の番号・上限・バイト → 絵）。parse の知らせを先に、捨てた物の知らせと
    /// 絵と材質の知らせ（同じ字は 1 行）を後に出す。
    // WhyNot: parse の知らせを List.distinct しない — primitive ごとに同じ字の知らせが並ぶのが、どの primitive かを数える手がかり。
    def assembleBy(decode: (Int32, Int32, Vector[Int8]) -> Result[String, Texture3d.Texture3d] \ IO, options: LoadOptions,
                   bytes: Vector[Int8], parsed: Gltf.Internal.Parse.Parsed): Model3d.Model3d \ IO =
        let p = Log.warnAllThen(parsed#lines, parsed);
        let used = usedImages(options, p#materials);
        let images = p#images |> Vector.mapWithIndex((k, source) -> match Map.get(k, used) {
            case Some(maxSide) => decodeImage(decode(k, maxSide), bytes, source) |> (decoded -> (Option.map(Texture3d.limitSize(maxSide), fst(decoded)), snd(decoded)))
            case None          => (None, Nil)
        });
        let decoded = images |> Vector.map(fst);
        let materials = p#materials |> Vector.mapWithIndex((k, m) -> materialOf(decoded, options, k, withoutBakedTransform(m)));
        let (parts, attachLines) = attachMaterials(p#parts, materials);
        let lines = List.flatten((Vector.toList(images) |> List.flatMap(snd)) :: attachLines :: Nil) |> List.distinct;
        Log.warnAllThen(List.append(p#droppedLines, lines),
                        { mesh = p#mesh, skin = p#skin, clips = p#clips, parts = parts,
                          textures = Vector.toList(decoded) |> List.filterMap(identity), nodes = p#nodes })

    /// 材質の番号ごとに 1 回作った物。withUv = TEXCOORD_0 のある primitive に付ける材質・withoutUv = 無い primitive に付ける材質
    /// （emissiveTexture と metallicRoughnessTexture は uv で読むので、無い primitive には emission を外し、metallic・roughness は値だけにした材質）・
    /// noUvLines = withoutUv を使った時の知らせ。
    type alias MaterialBuild = { withUv = Option[Scene3d.Material3d], withoutUv = Option[Scene3d.Material3d], info = Model3d.GltfMaterial,
                                 lines = List[String], noUvLines = List[String] }

    /// parsedParts に、材質の番号ごとの materials を付ける。材質の知らせと、uv の無い part に withoutUv を付けた知らせも返す。
    def attachMaterials(parsedParts: List[Gltf.Internal.Parse.ParsedPart], materials: Vector[MaterialBuild]): (List[Model3d.ModelPart], List[String]) =
        let assigned = parsedParts |> List.map(p -> {
            let part = { mesh = p#mesh, material = None, node = Some(p#node), gltfMaterial = None };
            assignMaterial(part, p#material |> Option.flatMap(k -> Vector.nth(k, materials)))
        });
        (List.map(fst, assigned), List.append(Vector.toList(materials) |> List.flatMap(m -> m#lines), assigned |> List.flatMap(snd)))

    /// part に材質を付ける（part の形の uv の有無で withUv か withoutUv を選ぶ）。withoutUv を選んだ時の知らせも返す。
    def assignMaterial(part: Model3d.ModelPart, build: Option[MaterialBuild]): (Model3d.ModelPart, List[String]) =
        let hasUv = Option.nonEmpty(Mesh3d.uvs(part#mesh));
        let material = build |> Option.flatMap(b -> if (hasUv) b#withUv else b#withoutUv);
        let lines = if (hasUv) Nil else build |> Option.map(b -> b#noUvLines) |> Option.getWithDefault(Nil);
        ({ material = material, gltfMaterial = Option.map(b -> b#info, build) | part }, lines)

    /// 材質の uv で読む絵の口 1 つ（読み方 options で読む物だけ）。field = glTF の欄の名前・info = 絵・
    /// isRead = 読めたか（TextureNames の欄）・noUv = TEXCOORD_0 の無い形での扱い（知らせの字）。
    type alias UvTextureSlot = { field = String, info = Gltf.Internal.Parse.TextureInfo, isRead = TextureNames -> Bool, noUv = String }

    /// 材質の emissiveTexture（emissive が 0 でない材質だけ）・metallicRoughnessTexture と occlusionTexture（options の pbr が真で metallic・roughness の付く材質だけ・
    /// occlusionTexture は options の occlusion も真の時だけ）の口。上限はどれも limits#baseColor。
    // WhyNot: AO の絵を metallic・roughness の無い材質で読まない — AO は metallic・roughness の色の b で運び、そのプログラムの中で掛ける（Scene3d.withOcclusionTexture）。
    def uvTextureSlotsOf(options: LoadOptions, material: Gltf.Internal.Parse.MaterialSpec): List[UvTextureSlot] =
        let emissive = if (isZeroColor(emissiveOf(material))) Nil
                       else { field = "emissiveTexture", info = material#emissive, isRead = n -> Option.nonEmpty(n#emissive), noUv = "光らせない" } :: Nil;
        let occlusion = if (options#occlusion) { field = "occlusionTexture", info = material#occlusion, isRead = n -> Option.nonEmpty(n#occlusion), noUv = "読まない" } :: Nil else Nil;
        let pbr = if (not options#pbr or not wantsMetallicRoughness(material)) Nil
                  else { field = "metallicRoughnessTexture", info = material#metalRough, isRead = n -> Option.nonEmpty(n#metallicRoughness), noUv = "読まず値だけにする" } :: occlusion;
        emissive ::: pbr

    /// 材質の baseColorTexture・normalTexture と uvTextureSlotsOf の口（texCoord が 0 の物）が指す画像の番号 → その絵の長い辺の上限
    /// （2 つ以上から指されたら大きい方）。KHR_texture_transform を uv に書き込む材質は、書き込んだ後の絵の読み方で選ぶ。
    // WhyNot: 全部の画像を decode しない — 2048² なら 1 枚 16 MB をヒープに持つ。
    def usedImages(options: LoadOptions, materials: Vector[Gltf.Internal.Parse.MaterialSpec]): Map[Int32, Int32] =
        let limits = options#limits;
        materials |> Vector.toList |> List.map(withoutBakedTransform)
            |> List.flatMap(material -> (material#base, limits#baseColor)
                                        :: (material#normal, limits#normal)
                                        :: (uvTextureSlotsOf(options, material) |> List.filter(slot -> slot#info#texCoord == 0) |> List.map(slot -> (slot#info, limits#baseColor))))
            |> List.filterMap(entry -> { let (info, maxSide) = entry; info#source |> Option.map(src -> (src, maxSide)) })
            |> List.foldLeft((acc, entry) -> { let (src, maxSide) = entry; Map.insertWith((a, b) -> Int32.max(a, b), src, maxSide, acc) }, Map.empty())

    /// images[k] を絵に戻す（BIN の bufferView の PNG / JPEG）。外の uri・読めない画像は None と知らせる 1 行。
    def decodeImage(decode: Vector[Int8] -> Result[String, Texture3d.Texture3d] \ IO, bytes: Vector[Int8], source: Gltf.Internal.Parse.ImageSource): (Option[Texture3d.Texture3d], List[String]) \ IO =
        match source {
            case Gltf.Internal.Parse.ImageSource.InBin(start, length) => decode(Gltf.Internal.copyRange(start, start + length, bytes)) |> decodedImage
            case Gltf.Internal.Parse.ImageSource.Unreadable(e) => decodedImage(Err(e))
            case Gltf.Internal.Parse.ImageSource.ExternalUri   => (None, "glTF: 外の uri の画像は読まない — その絵の材質は頂点の色で描く（画像は .glb に埋める）" :: Nil)
            case Gltf.Internal.Parse.ImageSource.NoSource      => (None, "glTF: bufferView も uri も無い画像を読み飛ばした" :: Nil)
        }

    /// 解いた絵と、解けなかった時の知らせ。
    def decodedImage(r: Result[String, Texture3d.Texture3d]): (Option[Texture3d.Texture3d], List[String]) = match r {
        case Ok(t)  => (Some(t), Nil)
        case Err(e) => (None, "glTF: 画像が読めないので、その絵の材質は頂点の色で描く（${e}）" :: Nil)
    }

    /// 材質 index 1 つ（材質の番号ごとに 1 回）:
    ///
    /// | baseColorTexture | emissive | 材質 |
    /// |---|---|---|
    /// | 読めた | 0 | Scene3d.texturedMaterial（spec の名前もそのまま） |
    /// | 読めた | 0 でない | texturedMaterial + emission・spec の名前は "gltf:tex:<絵の読み方>:<emissive>" |
    /// | 無い | 0 でない | 頂点の色の材質 + emission・spec の名前は "gltf:vc:<emissive>" |
    /// | 無い | 0 | None（頂点の色で描く） |
    ///
    /// metallic・roughness は、LoadOptions の pbr が真の時だけ読む。pbrMetallicRoughness があり metallicFactor・roughnessFactor・metallicRoughnessTexture のどれかが書いてある材質に
    /// Scene3d.withMetallicRoughness で付く（書いていない値は glTF の既定の 1。pbrMetallicRoughness が無い・baseColorFactor だけの材質は付けない — 色だけの古い glb が
    /// 全部金属に見えるのを避ける）。絵が無く emissive も無い材質も、付く時は材質になる（"gltf:vc"・頂点の色の土台）。
    /// metallicRoughnessTexture は texCoord が 0 で読めた時だけ Scene3d.withMetallicRoughnessTexture（読めない時は値だけにして知らせる）。
    ///
    /// texturedMaterial の絵の読み方は sampler の magFilter（NEAREST なら Nearest・ほかは Linear）、wrapS か wrapT が CLAMP_TO_EDGE なら Clamp。
    /// 法線マップは baseColorTexture のある材質にだけ足す（strength = scale・既定 1）。読み飛ばした物の知らせも返す。
    /// alphaMode（材質のある物だけ）: BLEND → Scene3d.withAlphaBlend(true)・MASK → Scene3d.withCutout(true)（alphaCutoff は 0.5 の固定。
    /// 0.5 でなければ 1 行知らせる）・OPAQUE → そのまま。doubleSided は材質のある物にそのまま当てる（Blender の書き出しは全部の材質を真にする。
    /// 裏を描きたくない物は、ゲームが読んだ model#parts の material を Scene3d.withDoubleSided(false, ..) に替える）。
    // WhyNot: 材質の無い物（頂点の色で描く）に当てるため材質を作らない — 材質を作ると batch の鍵と tint の掛け方が替わり、絵が変わる。
    def materialOf(images: Vector[Option[Texture3d.Texture3d]], options: LoadOptions, index: Int32, material: Gltf.Internal.Parse.MaterialSpec): MaterialBuild =
        let readPbr = options#pbr;
        let base = textureRefOf(images, material#base);
        let normal = textureRefOf(images, material#normal);
        let emission = emissionOf(images, readPbr, index, material);
        let metal = metallicRoughnessOf(images, readPbr, material) |> Option.map(b -> withOcclusionBuild(images, options#occlusion, material, b));
        let names = { base = fst(base) |> Option.map(r -> Texture3d.name(r#texture)),
                      normal = fst(normal) |> Option.map(r -> Texture3d.name(r#texture)),
                      emissive = emission#texture |> Option.map(r -> Texture3d.name(r#texture)),
                      metallicRoughness = metal |> Option.flatMap(b -> b#texture) |> Option.map(r -> Texture3d.name(r#texture)),
                      occlusion = metal |> Option.flatMap(b -> b#occlusion) |> Option.map(o -> Texture3d.name(fst(o)#texture)) };
        let surface = fst(base) |> Option.map(ref -> {
            let textured = Scene3d.texturedMaterial(Texture3d.name(ref#texture), ref#filter) |> Scene3d.withWrap(ref#wrap);
            match fst(normal) {
                case Some(n) =>
                    let strength = material#normalScale |> Option.getWithDefault(1.0);
                    textured |> Scene3d.withNormalMap({ texture = Texture3d.name(n#texture), strength = strength })
                case None => textured
            }
        });
        let baseName = fst(base) |> Option.map(r -> "tex:${ToString.toString(r#filter)}") |> Option.getWithDefault("vc");
        let lit = (e: Option[EmissionBuild]) -> match (surface, e) {
            case (None, None)       => metal |> Option.map(b -> vertexColorMaterial("gltf:vc") |> Scene3d.withWrap(metalWrapOf(b)))
            case (_, None)          => surface
            case (Some(m), Some(b)) => Some(m |> Scene3d.withEmission(b#shade) |> Scene3d.withEmissionIntensity(b#strength) |> Scene3d.withSpecName("gltf:${baseName}:${b#name}"))
            case (None, Some(b))    => Some(vertexColorMaterial("gltf:${baseName}:${b#name}") |> Scene3d.withEmission(b#shade) |> Scene3d.withEmissionIntensity(b#strength) |> Scene3d.withWrap(b#wrap))
        };
        let usesTexture = Option.nonEmpty(emission#texture);
        let info = gltfMaterialOf(names, material);
        let withAlpha = (m: Option[Scene3d.Material3d]) -> m |> Option.map(withAlphaModeOf(info#alphaMode) >> Scene3d.withDoubleSided(info#doubleSided));
        let withUv = withAlpha(lit(emission#build) |> Option.map(withPbrOf(metal, true)));
        // WhyNot: 材質の無い（頂点の色で描く）物の alphaCutoff を知らせない — α を持たないので抜く所が無い。
        let cutoffLine = if (Option.isEmpty(withUv)) Nil else alphaCutoffLine(index, material, info);
        let noUvLines = uvTextureSlotsOf(options, material) |> List.filter(slot -> slot#isRead(names))
            |> List.map(slot -> "glTF: 材質 ${materialLabel(index, material)} の ${slot#field} を、TEXCOORD_0 の無い形では${slot#noUv}（uv で読む絵）");
        { withUv = withUv, withoutUv = withAlpha(lit(if (usesTexture) None else emission#build) |> Option.map(withPbrOf(metal, false))),
          info = info,
          lines = List.flatten(snd(base) :: snd(normal) :: emission#lines :: metalLines(index, material, metal) :: emissiveFactorLine(index, material) :: cutoffLine :: Nil),
          noUvLines = noUvLines }

    /// metallic・roughness の付く材質か（式は materialOf の説明）。
    def wantsMetallicRoughness(material: Gltf.Internal.Parse.MaterialSpec): Bool =
        material#hasPbr and (material#hasMetallic or material#hasRoughness or Option.nonEmpty(material#metalRough#index))

    /// 材質に付ける metallic・roughness。metallic・roughness = metallicFactor・roughnessFactor（既定 1）・texture = 読めた metallicRoughnessTexture。
    /// occlusion = 読めた occlusionTexture と strength（LoadOptions の occlusion が真の時だけ）。
    type alias MetalBuild = { metallic = Float64, roughness = Float64, texture = Option[TextureRef], unreadable = Bool, lines = List[String],
                              occlusion = Option[(TextureRef, Float64)] }

    /// b に occlusionTexture を足した物（読まない・読めない時は b のまま。読めない時の知らせは textureRefOf の行）。
    def withOcclusionBuild(images: Vector[Option[Texture3d.Texture3d]], enabled: Bool, material: Gltf.Internal.Parse.MaterialSpec, b: MetalBuild): MetalBuild =
        if (not enabled) b
        else {
            let (ref, lines) = textureRefOf(images, material#occlusion);
            { occlusion = Option.map(r -> (r, material#occlusionStrength), ref), lines = List.append(b#lines, lines) | b }
        }

    /// material の metallic・roughness（付けない材質は None）。絵を指しているのに読めない時は texture = None・unreadable = true。
    def metallicRoughnessOf(images: Vector[Option[Texture3d.Texture3d]], enabled: Bool, material: Gltf.Internal.Parse.MaterialSpec): Option[MetalBuild] =
        if (not enabled or not wantsMetallicRoughness(material)) None
        else {
            let info = material#metalRough;
            let (ref, lines) = textureRefOf(images, info);
            Some({ metallic = material#metallicFactor |> Option.getWithDefault(1.0),
                   roughness = material#roughnessFactor |> Option.getWithDefault(1.0),
                   texture = ref, unreadable = Option.nonEmpty(info#index) and Option.isEmpty(ref), lines = lines, occlusion = None })
        }

    /// 絵の無い材質（頂点の色の土台）の wrap は metallicRoughnessTexture の sampler に合わせる。
    def metalWrapOf(b: MetalBuild): Scene3d.Wrap = b#texture |> Option.map(r -> r#wrap) |> Option.getWithDefault(Scene3d.Wrap.Repeat)

    /// 材質 m に metal の metallic・roughness と AO の絵を付ける（metal が None なら m のまま）。useTexture が偽なら絵（metallicRoughnessTexture・AO）は付けず値だけ。
    def withPbrOf(metal: Option[MetalBuild], useTexture: Bool, m: Scene3d.Material3d): Scene3d.Material3d = match metal {
        case None    => m
        case Some(b) =>
            let valued = m |> Scene3d.withMetallicRoughness(b#metallic, b#roughness);
            let textured = b#texture |> Option.filter(_ -> useTexture)
                |> Option.map(ref -> Scene3d.withMetallicRoughnessTexture(Texture3d.name(ref#texture), valued)) |> Option.getWithDefault(valued);
            b#occlusion |> Option.filter(_ -> useTexture)
                |> Option.map(o -> { let (ref, strength) = o; Scene3d.withOcclusionTexture(Texture3d.name(ref#texture), strength, textured) })
                |> Option.getWithDefault(textured)
    }

    /// metallicRoughnessTexture が読めない時の知らせと、絵の読み飛ばしの知らせ。
    def metalLines(index: Int32, material: Gltf.Internal.Parse.MaterialSpec, metal: Option[MetalBuild]): List[String] = match metal {
        case None    => Nil
        case Some(b) =>
            let unreadable = if (b#unreadable) "glTF: 材質 ${materialLabel(index, material)} の metallicRoughnessTexture が読めないので、metallicFactor・roughnessFactor の値だけで読む" :: Nil else Nil;
            List.append(b#lines, unreadable)
    }

    /// glTF の alphaMode を材質に当てる（BLEND は半透明・MASK は α 0.5 で抜く・OPAQUE はそのまま）。
    def withAlphaModeOf(mode: Model3d.AlphaMode, m: Scene3d.Material3d): Scene3d.Material3d = match mode {
        case Model3d.AlphaMode.Opaque => m
        case Model3d.AlphaMode.Mask   => Scene3d.withCutout(true, m)
        case Model3d.AlphaMode.Blend  => Scene3d.withAlphaBlend(true, m)
    }

    /// MASK の材質の alphaCutoff が 0.5 でない時の知らせ（0.5 で抜く）。
    def alphaCutoffLine(index: Int32, material: Gltf.Internal.Parse.MaterialSpec, info: Model3d.GltfMaterial): List[String] =
        if (info#alphaMode == Model3d.AlphaMode.Mask and info#alphaCutoff != 0.5)
            "glTF: 材質 ${materialLabel(index, material)} の alphaCutoff ${Float64.toString(info#alphaCutoff)} は使わず、α 0.5 で抜く" :: Nil
        else Nil

    /// 材質を知らせの中で名指す字（name があれば name・無ければ番号）。
    def materialLabel(index: Int32, material: Gltf.Internal.Parse.MaterialSpec): String =
        material#name |> Option.map(n -> "'${n}'") |> Option.getWithDefault("materials[${index}]")

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
    /// linear が真（LoadOptions の pbr）なら emissiveFactor を線形の値として読み、画面の値へ戻して持つ（baseColorOf と同じ理由）。
    def emissionOf(images: Vector[Option[Texture3d.Texture3d]], linear: Bool, index: Int32, material: Gltf.Internal.Parse.MaterialSpec): EmissionOf =
        let raw = material#emissiveFactor;
        let screen = (v: Float64) -> if (linear) Texture3d.linearToSrgb(v) else v;
        let c = { r = screen(raw#r), g = screen(raw#g), b = screen(raw#b) };
        let strength = material#emissiveStrength;
        let info = material#emissive;
        let digits = "(${Float64.toString(c#r)},${Float64.toString(c#g)},${Float64.toString(c#b)})";
        if (isZeroColor(emissiveOf(material))) { build = None, texture = None, lines = Nil }
        else if (Option.isEmpty(info#index))
            { build = Some({ shade = ShaderDoc.Shade.Solid(Color.rgb(c#r, c#g, c#b)), name = "ec${digits}", wrap = Scene3d.Wrap.Repeat, strength = strength }), texture = None, lines = Nil }
        else match textureRefOf(images, info) {
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
    def emissiveOf(material: Gltf.Internal.Parse.MaterialSpec): { r = Float64, g = Float64, b = Float64 } =
        let c = material#emissiveFactor;
        let strength = material#emissiveStrength;
        let at = (v: Float64) -> { let x = v * strength; if (x > 0.0) x else 0.0 };
        { r = at(c#r), g = at(c#g), b = at(c#b) }

    /// emissiveFactor が 3 つの数でない時の知らせ（emissiveOf が (0, 0, 0) にした事）。
    def emissiveFactorLine(index: Int32, material: Gltf.Internal.Parse.MaterialSpec): List[String] =
        material#emissiveFactorError |> Option.map(e -> "${e}（材質 ${materialLabel(index, material)}）— emissive を (0, 0, 0) として読む" :: Nil)
            |> Option.getWithDefault(Nil)

    def isZeroColor(c: { r = Float64, g = Float64, b = Float64 }): Bool = c#r <= 0.0 and c#g <= 0.0 and c#b <= 0.0

    /// GltfMaterial の絵の名前の欄（読めた絵の Texture3d.name）。
    type alias TextureNames = { base = Option[String], normal = Option[String], emissive = Option[String], metallicRoughness = Option[String],
                                occlusion = Option[String] }

    /// glTF の材質の欄を読む（alphaMode は MASK・BLEND の他は Opaque・alphaCutoff 既定 0.5・doubleSided 既定 偽）。
    def gltfMaterialOf(names: TextureNames, material: Gltf.Internal.Parse.MaterialSpec): Model3d.GltfMaterial =
        { name = material#name |> Option.getWithDefault(""), alphaMode = material#alphaMode,
          alphaCutoff = material#alphaCutoff,
          doubleSided = material#doubleSided,
          baseColorTexture = names#base, normalTexture = names#normal, emissiveTexture = names#emissive,
          emissive = emissiveOf(material),
          metallic = material#metallicFactor |> Option.getWithDefault(1.0),
          roughness = material#roughnessFactor |> Option.getWithDefault(1.0),
          metallicRoughnessTexture = names#metallicRoughness,
          occlusionTexture = names#occlusion, occlusionStrength = material#occlusionStrength }

    /// textureInfo（{ index, texCoord, extensions }）が指す絵と、sampler の読み方。
    type alias TextureRef = { texture = Texture3d.Texture3d, filter = ShaderDoc.FilterMode, wrap = Scene3d.Wrap }

    /// parse が頂点の uv に焼き込んだ transform（Gltf.Internal.Parse.bakedTransformOf）を、材質の絵から外した物（読み飛ばしの知らせを出さない。
    /// 書き込むのは実際に読む uv が 0 番の時だけなので、texCoord も 0 にそろえる）。
    def withoutBakedTransform(m: Gltf.Internal.Parse.MaterialSpec): Gltf.Internal.Parse.MaterialSpec =
        if (Option.isEmpty(Gltf.Internal.Parse.bakedTransformOf(m))) m
        else {
            let clear = (t: Gltf.Internal.Parse.TextureInfo) -> { transform = None, texCoord = 0 | t };
            { base = clear(m#base), normal = clear(m#normal), emissive = clear(m#emissive), metalRough = clear(m#metalRough), occlusion = clear(m#occlusion) | m }
        }

    def textureRefOf(images: Vector[Option[Texture3d.Texture3d]], info: Gltf.Internal.Parse.TextureInfo): (Option[TextureRef], List[String]) =
        let transformLine = if (Option.nonEmpty(info#transform))
            "glTF: KHR_texture_transform を読み飛ばした（uv をずらさず・回さずに読む）" :: Nil else Nil;
        match info#index {
            case None => (None, Nil)
            case Some(_) if info#texCoord != 0 =>
                (None, "glTF: texCoord が 0 でない絵を読み飛ばした（TEXCOORD_0 だけを読む）" :: transformLine)
            case Some(_) =>
                let mirroredLine = if (info#mirrored) "glTF: MIRRORED_REPEAT を REPEAT として読んだ" :: Nil else Nil;
                let filter = if (info#nearest) ShaderDoc.FilterMode.Nearest else ShaderDoc.FilterMode.Linear;
                let wrap = if (info#clamp) Scene3d.Wrap.Clamp else Scene3d.Wrap.Repeat;
                let found = info#source |> Option.flatMap(src -> Vector.nth(src, images)) |> Option.flatMap(identity);
                (Option.map(t -> { texture = t, filter = filter, wrap = wrap }, found), List.append(transformLine, mirroredLine))
        }
}
