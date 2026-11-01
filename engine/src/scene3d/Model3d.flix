// Model3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 読み込んだキャラ 1 体（開いたレコード）。mesh = 形・skin = ジョイントの木（ジョイントの無い形は None）・clips = 名前ごとのアニメーションクリップ。
pub mod Model3d {

    pub type alias Model3d = { mesh = Mesh3d.Mesh3d, skin = Option[Skin3d.Skin3d], clips = Map[String, AnimationClip3d.AnimationClip3d] }
}
