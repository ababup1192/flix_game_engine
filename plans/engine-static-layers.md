# 静的層を区画ごとに持つ（App.withStaticLayers）

## なぜ

`App.withStaticLayer` は静的層を 1 つしか持てない。key が変わると層の多角形を全部作り直して GPU へ上げ直す。
壊せる置き物の多い見下ろしの地図では、置き物 1 つで地図全体の影（多角形 約 8,000 個）を上げ直し、そのコマが 43 ms 止まった
（CPU の組み立て 7 ms・GL へ送る 36 ms）。地図を区画に分け、鍵が変わった区画だけを作り直せば、上げ直しは 1 区画ぶんで済む。

## API の形

```flix
pub type alias StaticLayerSpec = { id = String, key = GameEngine.StaticKey, items = Unit -> List[Render.PlacedItem] }
pub def App.withStaticLayers(f: w -> List[StaticLayerSpec], app: App[w, ef]): App[w, ef]
```

- `withTileLayers(f: w -> List[TileLayerSpec])` にそろえる。宣言 `f` は毎コマ呼ばれるので、中身は `items` のサンクにし、
  作り直しの時だけ組む（TileLayerSpec の `tiles` と同じ）。
- `id` = 区画の名前（`"shadow/3,5"` など）。GPU バッファは id ごとに 1 本。`key` = その区画の中身を決める入力。
  同じ id で key が変わったら、その区画だけ捨てて作り直す。
- `withStaticLayer(key, build)` は残し、id `""` の 1 区画の `withStaticLayers` として実装する（既存の呼び手は無改修）。
  両方を呼んだら後に呼んだ方が勝つ（withTileLayers と同じく宣言は 1 つ）。
- Bevy / Godot には同じ物の決まった名前が無い（Godot の TileMap は quadrant、Bevy の tilemap は chunk）。区画の単位は
  ゲームが決めるので engine は `id` とだけ呼び、chunk の語は文書の例でだけ使う。

## 描き手の API

- `DrawCmd.StaticLayerCmd` に `id = String` を足す。
- `Platform.Draw2d.renderCommands` の第 4 引数を `Option[StaticLayerCmd]` から `List[StaticLayerCmd]` にする
  （handler は engine の中だけ: GL・WebGPU・engine_web の記録・テスト 3 つ。Studio・ゲームに handler は無い）。

## 描き手ごとのキャッシュ

GL と WebGPU は同じ `RenderStatic`（render_gl/Static.flix）を使う。キャッシュを `Array[Option[Entry]]`（1 枠）から
`Ref[Map[String, Entry]]`（id → Entry）にする。

- `resolve(alloc, cache, layers)`: 依頼の並びの順に、id の Entry の key が一致すれば使い回し、違えば古い buffer を捨てて作り直す。
  その後、このコマの依頼に無い id の buffer を捨てて表から消す（消えた id の後始末。区画を外した・地図を替えた時）。
- 同じ id が 1 コマに 2 度来たら、2 つ目からは「id + 出た順の番号」を表の名前にする（互いに捨て合って毎コマ作り直すのを防ぐ）。
  engine_world 側で初回 1 回だけ知らせる（warnOnce）。
- `release(alloc, cache)`: 全部捨てる（WebGPU の終わり）。
- SoftRaster とヘッドレスは Draw2d を通らない（PlacedItem を直に描く）ので、キャッシュは無い。

## 描く順

- 1 区画の中は今と同じ（z 昇順・同 z は入力順で 1 本の buffer へ並べる）。
- 区画どうしは、依頼の並びの順に range を繋いで `mergedByZ` に渡す。`mergedByZ` は z 昇順・同 z は入力順の安定な並べ替え
  なので、同 z の中では「区画 A の range → 区画 B の range」となり、A と B の items を繋いだ 1 層と同じ重なりになる。
  違うのは range の切れ目（draw call の数）だけで、画素は同じ。
- 動的な絵との順（同 z では tiles → sprites → polygons → static → surfaces → scenes）は変わらない。

## headless・F8

- F8 のズーム・パン中と注釈の書き出し（`staticPausedItems`）は、全区画の items を並びの順に繋いで今と同じく PlacedItem にする。
- ヘッドレスの描き出しはゲームが自分で静的な items を描き、`HeadlessRender.noteStaticItems` で申告する。区画に分けたゲームは
  `List.flatMap(s -> (s#items)(), specs)` を渡せばよい（engine に足す物は無い）。

## テスト

- render_gl/test/TestShapeBuffers: 区画 2 つで片方の鍵だけ替えると、create / destroy がその区画の 1 組だけ・消えた id の buffer を捨てる・
  同じ id が 2 度来ても毎コマ作り直さない・1 層と 2 区画で range の (z・頂点数の合計) の順が同じ。
- engine_world/test: withStaticLayer が id `""` の 1 区画になる・withStaticLayers が並び順のまま渡る。
- gl-parity / gl-capture の画素が動かない（既存の 1 層の呼び手は同じ絵）。
