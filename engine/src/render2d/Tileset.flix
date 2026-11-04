/// タイルセットのアトラス元 — 1 枚のタイル画像と、そこからマスを切り出す設定。
/// 寸法（texWidth / texHeight / tileSize）は自分で全部埋めてもよいし（実行時に生成した
/// アトラスを使うゲーム）、make で 0 のまま作ってマップの loader 側に
/// getTextureInfo() で補完させてもよい。
pub type alias TileSetAtlasSource = {
    textureName = String,
    texWidth    = Float64,
    texHeight   = Float64,
    tileSize    = Float64,
    marginX     = Float64,
    marginY     = Float64,
    spacingX    = Float64,
    spacingY    = Float64
}

/// タイルセット — マップが使うタイル画像一式。
pub type alias Tileset = { atlasSource = TileSetAtlasSource }

pub mod Tileset {
    pub def make(source: TileSetAtlasSource): Tileset = { atlasSource = source }

    /// タイル 1 マスの一辺（ピクセル）。本プロジェクトはタイル正方形なので Float64 単一値
    pub def tileSize(tileSet: Tileset): Float64 =
        tileSet#atlasSource#tileSize
}

mod TileSetAtlasSource {
    /// margin/spacing のデフォルトを 0 として生成する。
    /// texWidth / texHeight / tileSize は tilemap loader が後から補完するため 0 で初期化する。
    pub def make(config: { textureName = String,
                           marginX = Float64, marginY = Float64,
                           spacingX = Float64, spacingY = Float64 }): TileSetAtlasSource = {
        textureName = config#textureName,
        texWidth    = 0.0,
        texHeight   = 0.0,
        tileSize    = 0.0,
        marginX     = config#marginX,
        marginY     = config#marginY,
        spacingX    = config#spacingX,
        spacingY    = config#spacingY
    }
}
