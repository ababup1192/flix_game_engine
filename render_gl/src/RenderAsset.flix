// RenderAsset — 描画アセットの型エイリアス
//
// shape は engine の GameEngine.TextureEntry / TextureInfo / ... と完全一致させる。
// Flix の record 構造的型付けにより、engine 側の同型の値とそのまま相互変換可能。

pub mod RenderAsset {

    /// テクスチャマニフェスト 1 エントリ
    pub type alias TextureEntry = { name = String, path = String, hasAlpha = Bool }

    /// テクスチャ情報: GPU ハンドル ID + 元画像サイズ (Float64)
    pub type alias TextureInfo = { id = GpuHandle.TextureId, width = Float64, height = Float64 }

    /// 論理名 → TextureInfo
    pub type alias TextureRegistry = Map[String, TextureInfo]

    /// フォントマニフェスト 1 エントリ
    pub type alias FontEntry = { name = String, path = String, fontSize = Float64 }

    /// サウンドマニフェスト 1 エントリ。looping = true でループ再生
    pub type alias AudioEntry = { name = String, path = String, looping = Bool }

    /// 論理名 → OpenAL ソース ID
    pub type alias AudioRegistry = Map[String, Int32]

}
