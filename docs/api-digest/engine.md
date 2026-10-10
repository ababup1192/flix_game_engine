<!-- engine v0.35.0 / 生成: 2026-10-11 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine

`engine/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## TileSetAtlasSource — `engine/src/render/Tileset.flix`
- margin/spacing のデフォルトを 0 として生成する。
  `pub def make(config: { textureName = String, marginX = Float64, marginY = Float64, spacingX = Float64, spacingY = Float64 }): TileSetAtlasSource`
