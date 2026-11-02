// Model3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 読み込んだキャラ 1 体（開いたレコード）。mesh = 全部の primitive をつないだ形（材質の色は頂点の色に書き込んである）・
/// skin = ジョイントの木（ジョイントの無い形は None）・clips = 名前ごとのアニメーションクリップ・
/// parts = primitive ごとの形と材質（材質を分けて描く時。同じ skin と Pose を全部の part に渡せば曲がりはそろう）・
/// textures = parts の材質が読む絵（場面の textures に入れる）。
pub mod Model3d {

    /// primitive 1 つ。mesh = 形（uv を持つ primitive だけ uv つき）・material = 材質（絵の無い材質は None で、頂点の色で描く）。
    pub type alias ModelPart = { mesh = Mesh3d.Mesh3d, material = Option[Scene3d.Material3d] }

    pub type alias Model3d = { mesh = Mesh3d.Mesh3d, skin = Option[Skin3d.Skin3d], clips = Map[String, AnimationClip3d.AnimationClip3d],
                               parts = List[ModelPart], textures = List[Texture3d.Texture3d] }
}
