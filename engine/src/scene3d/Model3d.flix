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
    /// - alphaMode・alphaCutoff（既定 0.5）・doubleSided = glTF の欄のまま（loadTextured は alphaMode を材質に当てる — BLEND は半透明・MASK は 0.5 で抜く。doubleSided は当てない）
    /// - baseColorTexture・normalTexture・emissiveTexture = 読めた絵の名前（Texture3d.name。絵を読まない Gltf.load と、読めなかった絵は None）
    /// - emissive = emissiveFactor × KHR_materials_emissive_strength（線形の量・既定 0）
    pub type alias GltfMaterial = { name = String, alphaMode = AlphaMode, alphaCutoff = Float64, doubleSided = Bool,
                                    baseColorTexture = Option[String], normalTexture = Option[String],
                                    emissiveTexture = Option[String], emissive = { r = Float64, g = Float64, b = Float64 } }

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

    /// ノードの world の原点（world の行列の平行移動の列）。
    pub def nodeOrigin(node: ModelNode): Vec3.Vec3 = Mat4.apply(node#world, Vec3.zero())

    /// ノード node から出た parts の形（world を焼き込んだ頂点）を、そのノードの局所の座標へ戻す行列（焼き込みに使った world の逆行列）。
    /// 回す扉は、そのノードの parts を `node#world × 回転 × これ` で置く（ノードの原点のまわりで回る）。
    /// None: 逆行列の無い world・skin のある glb（skin のある glb の形はジョイントに付けて焼く物があり、ノードの world と焼いた行列が違いうる）。
    // WhyNot: 部品の番号で引かない — parts と nodes をそのたびに頭から辿り、全部の部品に回すと二乗になる。部品はノードの parts から引ける。
    pub def partLocalToNode(node: ModelNode, model: Model3d): Option[Mat4.Mat4] =
        if (Option.nonEmpty(model#skin)) None else Mat4.inverse(node#world)
}
