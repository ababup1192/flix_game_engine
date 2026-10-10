<!-- engine v0.34.0 / 生成: 2026-10-11 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine_world

`engine_world/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## MapResourceCodec — `engine_world/src/legacy/MapResource.flix`
- `pub def encodeLevel(l: Level): Json`
- `pub def decodeLevel(element: Json): Option[Level]`
- `pub def encodeFieldValue(v: FieldValue): Json`
- `pub def decodeFieldValue(element: Json): Option[FieldValue]`
- `pub def encodeMaterial(m: Material): Json`
- `pub def decodeMaterial(element: Json): Option[Material]`

## ResourceCodec — `engine_world/src/legacy/Resource.flix`
- `pub def encodeSchema(s: ResourceSchema): Json`
- `pub def decodeSchema(element: Json): Option[ResourceSchema]`
