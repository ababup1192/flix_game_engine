// Model3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 読み込んだキャラ 1 体（開いたレコード）。mesh = 全部の primitive をつないだ形（材質の色は頂点の色に書き込んである）・
/// skin = ジョイントの木（ジョイントの無い形は None）・clips = 名前ごとのアニメーションクリップ・
/// parts = primitive ごとの形と材質（材質を分けて描く時。同じ skin と Pose を全部の part に渡せば曲がりはそろう）・
/// textures = parts の材質が読む絵（場面の textures に入れる）・
/// nodes = glTF のノードの全部（glTF の nodes の並び。mesh の無いノード・ライト・カメラ・ジョイントも入る）。
pub mod Model3d {

    /// primitive 1 つ。mesh = 形（uv を持つ primitive だけ uv つき。ノードの world の行列は焼き込んである）・
    /// material = 材質（絵も emissive も無い材質は None で、頂点の色で描く）・
    /// node = その primitive を持つノードの番号（nodes の何番目か）・
    /// gltfMaterial = glTF の材質の情報（材質の無い primitive は None）。
    pub type alias ModelPart = { mesh = Mesh3d.Mesh3d, material = Option[Scene3d.Material3d], node = Option[Int32],
                                 gltfMaterial = Option[GltfMaterial] }

    pub type alias Model3d = { mesh = Mesh3d.Mesh3d, skin = Option[Skin3d.Skin3d], clips = Map[String, AnimationClip3d.AnimationClip3d],
                               parts = List[ModelPart], textures = List[Texture3d.Texture3d], nodes = List[ModelNode] }

    /// 形と全部の parts の頂点の色に k を掛けた物（Mesh3d.scaleColors。今の色に掛けるので 2 回呼ぶと k × k 倍・NaN・負・無限の k は 1 として知らせる）。
    /// PS1 の GPU と同じく頂点の色の 0.5 を 1 倍として明るくもできる掛け算は k = 2
    /// （Blender で 0.5 より明るくベイクした所が絵より明るくなる）。既定の読み込みは 1 倍。読み込みの時に 1 回呼ぶ。
    pub def scaleVertexColors(k: Float64, model: Model3d): Model3d =
        if (k == 1.0) model
        else if (Float64.isNan(k) or Float64.isInfinite(k) or k < 0.0)
            Log.fellBackThen("scene3d", "Model3d.scaleVertexColors の k ${k}", "1 倍", "NaN・負・無限は掛けられない", model)
        else { mesh = Mesh3d.scaleColors(k, model#mesh), parts = model#parts |> List.map(p -> { mesh = Mesh3d.scaleColors(k, p#mesh) | p }) | model }

    /// glTF のノード 1 つ。座標は engine の座標（左手系。Gltf の頭の X の反転を済ませた物）。
    /// - name = glTF の name（無ければ ""。glTF は同じ名前を許す）
    /// - parent = 親のノードの番号（nodes の何番目か。根は None）
    /// - local = 親から見た行列（ノードの matrix か TRS）・world = 根から local を掛けた行列（ジョイントのノードも TRS の休みの姿勢から作り、
    ///   逆バインド行列からは作らない。アニメーションでは動かない）
    /// - localBounds = mesh を持つノードの、world を掛ける前の形の座標の min と max（mesh の無いノードは None）
    /// - parts = そのノードから出た parts の番号（Model3d の parts の何番目か）
    pub type alias ModelNode = { name = String, parent = Option[Int32], local = Mat4.Mat4, world = Mat4.Mat4,
                                 localBounds = Option[Mesh3d.Bounds], parts = List[Int32] }

    /// glTF の材質の alphaMode。Opaque = 不透明・Mask = alphaCutoff で抜く・Blend = 半透明。
    pub enum AlphaMode with Eq, ToString {
        case Opaque
        case Mask
        case Blend
    }

    /// glTF の材質の情報（読むだけ。描き方を決めるのは part#material）。
    /// - name = glTF の材質の name（無ければ ""）
    /// - alphaMode・alphaCutoff（既定 0.5）・doubleSided = glTF の欄のまま（glb の読み込みは材質のある部品に alphaMode と doubleSided を当てる — BLEND は半透明・MASK は 0.5 で抜く・doubleSided は glTF の値のまま）
    /// - baseColorTexture・normalTexture・emissiveTexture = 読めた絵の名前（Texture3d.name。読めなかった絵は None）
    /// - emissive = emissiveFactor × KHR_materials_emissive_strength（既定 0。factor は画面の値〔sRGB の値〕として読み、strength は線形の倍率）
    /// - metallic・roughness = pbrMetallicRoughness の metallicFactor・roughnessFactor（書いていなければ glTF の既定の 1。材質に付いたかは part#material を
    ///   Scene3d.metallicRoughnessOf で見る — pbrMetallicRoughness が無い・baseColorFactor だけの材質は付かない）
    /// - metallicRoughnessTexture = 読めた metallicRoughnessTexture の絵の名前（Texture3d.name。読めなかった絵は None）
    pub type alias GltfMaterial = { name = String, alphaMode = AlphaMode, alphaCutoff = Float64, doubleSided = Bool,
                                    baseColorTexture = Option[String], normalTexture = Option[String],
                                    emissiveTexture = Option[String], emissive = { r = Float64, g = Float64, b = Float64 },
                                    metallic = Float64, roughness = Float64, metallicRoughnessTexture = Option[String] }

    /// 名前が name のノード（同じ名前が複数あれば nodes の並びの前）。たくさん引く時は nodesByName を 1 回作って引く。
    pub def findNode(name: String, model: Model3d): Option[ModelNode] =
        List.find(n -> n#name == name, model#nodes)

    /// 名前 → ノード（同じ名前が複数あれば nodes の並びの前）。
    pub def nodesByName(model: Model3d): Map[String, ModelNode] =
        model#nodes |> List.foldRight((n, acc) -> Map.insert(n#name, n, acc), Map.empty())

    /// 名前が prefix で始まるノード（nodes の並びの順）。Blender の書き出しの名前の決まり（"COL_" など）で集める。
    pub def nodesWithPrefix(prefix: String, model: Model3d): List[ModelNode] =
        List.filter(n -> String.startsWith(prefix = prefix, n#name), model#nodes)

    /// ノード node から出た parts（node#parts の順）。1 回ごとに parts を並べ直すので、たくさんのノードに回す時は partsByNode を 1 回作って引く。
    pub def partsOfNode(node: ModelNode, model: Model3d): List[ModelPart] =
        let parts = List.toVector(model#parts);
        List.filterMap(k -> Vector.nth(k, parts), node#parts)

    /// ノードの番号（nodes の何番目か）→ そのノードから出た parts（parts の並びの順）。
    pub def partsByNode(model: Model3d): Map[Int32, List[ModelPart]] =
        model#parts |> List.foldRight((part, acc) -> match part#node {
            case Some(k) => Map.insertWith((fresh, old) -> List.append(fresh, old), k, part :: Nil, acc)
            case None    => acc
        }, Map.empty())

    /// parts を 1 つずつ置いた物（parts の並びの順）。world = 模型全体を置く行列・材質は part の物・名前は part を持つノードの名前
    /// （Scene3d.withName。F8 の注釈が場面の中の物をこの名前で指す。ノードの無い part は空）。
    /// 置き方を部品ごとに変える時（回す扉など）は partsOfNode と partLocalToNode で組み、名前は Scene3d.withName で付ける。
    pub def partInstances(world: Mat4.Mat4, model: Model3d): List[Scene3d.Instance3d] =
        let nodes = List.toVector(model#nodes);
        model#parts |> List.map(part -> {
            let placed = Scene3d.meshInstance(part#mesh, world);
            let lit = match part#material {
                case Some(m) => Scene3d.withMaterial(m, placed)
                case None    => placed
            };
            let name = part#node |> Option.flatMap(k -> Vector.nth(k, nodes)) |> Option.map(n -> n#name) |> Option.getWithDefault("");
            Scene3d.withName(name, lit)
        })

    /// ノードの world の原点（world の行列の平行移動の列）。
    pub def nodeOrigin(node: ModelNode): Vec3.Vec3 = Mat4.apply(node#world, Vec3.zero())

    /// ノード node から出た parts の形（world をベイクした頂点）を、そのノードの局所の座標へ戻す行列（焼き込みに使った world の逆行列）。
    /// 回す扉は、そのノードの parts を `node#world × 回転 × これ` で置く（ノードの原点のまわりで回る）。
    /// None: 逆行列の無い world・skin のある glb（skin のある glb の形はジョイントに付けてベイクする物があり、ノードの world とベイクした行列が違いうる）。
    // WhyNot: 部品の番号で引かない — parts と nodes をそのたびに頭から辿り、全部の部品に回すと二乗になる。部品はノードの parts から引ける。
    pub def partLocalToNode(node: ModelNode, model: Model3d): Option[Mat4.Mat4] =
        if (Option.nonEmpty(model#skin)) None else Mat4.inverse(node#world)

    // ── glb を読む口 ──

    enum LoaderData { case LoaderData(ImageData.ImageDecoder, Gltf.LoadOptions, String -> Option[LoadProgress.Preparsed] \ IO) }

    /// glb の読み方（絵を解くデコーダーと、project.json の "gltf" の選択肢と、機種がメインの外で解いた結果の引き方）。作るのは loader() だけ。
    pub type alias Loader = LoaderData

    /// 読み込みの頭（ループが回る前）で 1 回作り、並列の仕事や BackgroundLoad の decode へ渡す。
    /// 選択肢は project.json の任意キー "gltf"（{"pbr": Bool, "vertexColors": Bool, "maxTextureSide": Int, "maxNormalSide": Int}・欄の意味は Gltf.LoadOptions・
    /// 無い欄は Gltf.defaultLoadOptions）。LoadProgress.runNoop の下では imageDecoder で止まるので、画面なしは HeadlessLoad.handle で包む。
    // WhyNot: 選択肢を引数で受けない — 鍵の有無・PBR・頂点の色を読み込みのたびにゲームが選ぶと、同じ glb の色が場所によって変わる。
    pub def loader(): Loader \ LoadProgress + Fs.FileRead =
        let options = match ProjectLoader.loadProject(".") {
            case Ok(p)  => p#gltf
            case Err(e) => Log.fellBackThen("scene3d", "Model3d.loader の project.json", "Gltf.defaultLoadOptions()", e, Gltf.defaultLoadOptions())
        };
        LoaderData.LoaderData(LoadProgress.imageDecoder(), options, LoadProgress.downloads()#preparsedOf)

    /// 道 path の glb を読む（読み込みの頭でも、並列の仕事の中でも呼べる）。読めない・壊れている時は Err（道つき）。
    pub def load(loader: Loader, path: String): Result[String, Model3d] \ Fs.FileRead + IO =
        Fs.FileRead.readBytes(path) |> Result.mapErr(e -> "${path}: 読めない（${e}）") |> Result.flatMap(decode(loader, path))

    /// 読んだバイトから作る（BackgroundLoad.Group の decode など。path は鍵を作るのと Err に付けるのに使う）。
    /// ブラウザ（versionedKey が Some）は形の鍵を道と版から作り、絵を機種の側に持つ。デスクトップは頂点から鍵を作る（読み方は Gltf.decodeWith）。
    /// 機種がメインの外で解いた結果（LoadProgress.AssetDownloads#preparsedOf）があれば、バイトを読み直さずに絵と材質を付けるだけにする（値は同じ）。
    pub def decode(loader: Loader, path: String, bytes: Vector[Int8]): Result[String, Model3d] \ IO =
        let LoaderData.LoaderData(decoder, options, preparsedOf) = loader;
        let key = (decoder#versionedKey)(path);
        let carried = key |> Option.flatMap(preparsedOf) |> Option.flatMap(Gltf.Internal.toParsed(options, path));
        match carried {
            case Some(parsed) => Ok(Gltf.Internal.assemble(decoder, options, key, bytes, parsed))
            case None         => Gltf.decodeWith(decoder, options, key, bytes) |> Result.mapErr(e -> "${path}: ${e}")
        }
}
