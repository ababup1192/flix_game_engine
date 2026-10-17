# データと保存（Doc の読み込み・知らせ・セーブ・履歴）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 巻き戻し・リプレイ・履歴 | Worldline |
| セーブ・ロード | SaveManager / Persistence |
| Doc の一覧を一覧表 1 枚にし watchFile・一括リロード・表示中バッジを導出 | DocTable |
| Doc を fail-open で読む（読めない・壊れは既定値へ） | DocJson.loadOr / decodeObject |
| 既定値で続けたことを 1 行知らせる（純粋な関数の中から） | Log.fellBackThen / warnThen / warnAllThen（`let _ = Log.warn(..)` は消える。docs/error-handling.md の決まり 3） |
| リソース JSON の形（型・必須・既定値）を公式スキーマ方言で宣言する | Schema（実例: `templates/race-starter/project.schema.json`） |

## モジュール 1 行紹介

- **Persistence** — 値をディスクに保存し、また読み戻すための汎用のしくみ。
- **SaveManager** — セーブデータをスロット番号でファイルに保存・読み出しする薄い層。
- **Worldline** — World の軌跡（履歴・巻き戻し・リプレイ・分岐の土台）。時間区間の振り付けは Timeline（別物）。
- **JsonCodec** — 値 ⇄ JSON の純変換ヘルパ（expect 系 / encode・decode）。
- **DocJson** — Doc を読むときの JSON 道具箱。parse・デコード補助（atNode 等）と fail-open 読み込み（loadOr・checkVersion）。
- **EcsCodec** — 「番号ごとの値の表」を JSON と相互変換する共通ヘルパ。
- **CatalogContainer** — 「1 ファイル = 1 種類の一覧」を表す汎用の入れ物。
- **Schema** — リソース（ゲームデータ JSON）の形を宣言する公式スキーマ方言（例: level.json の隣の level.schema.json）。データの形（type / required / default）はゲームも検証に使い、見せ方（widget）はエディタ専用でエンジンは開けない封筒として運ぶ。未知の type タグ・kind は黙って通さず Err にする。
- **DocTable** — Doc の一覧表（id・パス・読み直し）1 枚から、watchFile の配線・一括リロード・ActiveDocs の名乗りを導出する。一覧の手写しを 1 か所に。既定は `row` で 1 行、外れる行に `watchOnly` / `reloadAllOnly` / `activeWhen` を被せる。

## 新しい Doc（*.kind.json）を 1 つ足す順

1. **Schema** — 形を宣言する（`*.schema.json`。任意）
2. **`<X>Doc.flix`** — 型と fromJson/toJson を書く（decode は JsonCodec、エラー位置は DocJson.atNode）
3. **DocJson** — decodeObject で fromJson を 1 行に / loadOr で fail-open 読み
4. **DocTable** — 一覧表に 1 行足す（watch・F1 リロード・表示中バッジが導出される）
5. **Persistence / EcsCodec** — セーブに乗る値だけ（表なら EcsCodec）
