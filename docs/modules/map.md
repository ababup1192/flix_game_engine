# 盤面と地形（Grid・タイル層・DualGrid / Terrain・経路と視線）

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| タイルのマス目と移動範囲 | Grid / GridSearch（実例: `templates/platformer-starter/src/Stage.flix`） |
| 敵を追わせる・逃がす・ふらつかせる(距離場の 1 歩) | Steering |
| チップ絵タイル（タイルマップ・tilemap）を 1 draw call で敷く(事前に生成・マスごとの照明色 tint・屋根や庇は zIndex で手前にも) | App.withTileLayers / TileScene（実例: `templates/platformer-starter/src/Main.flix` / `templates/rpg-starter/src/TownMap.flix`） |
| チップ絵なしでマップ地形(壁・水)を多角形で描く（タイルマップを絵なしで） | DualGrid / Material（repo 内に見本なし。[dual-grid.md](../dual-grid.md)） |
| rows の文字格子から地形の見た目を作る(*.terrain.json) | Terrain / TerrainDoc（repo 内に見本なし。[dual-grid.md](../dual-grid.md)） |
| 側面・斜めの自然地形（丘・砂丘・崖）を高さの関数で 1px ドット絵に敷く | PxTerrain（init で 1 回組んで持ち回す） |
| 文字の並び（rows）の大きさを測る・1 マスずつほどく | Grid.dimsOfRows / Grid.cellsOfRows |
| 文字格子から 1 種類の文字のマスを集める | Terrain.cellsOf |
| 壁越しに見えるか（視線の遮蔽）を判定する（壁の向こうの松明を消す・敵から見えるか） | GridRay |
| 見えている範囲に重なるマスだけ並べる（盤が広くても仕事は画面ぶん） | Grid.cellsIn |
| マスごとの「いま」を持つ（耕した・濡れた・置いた。セーブに乗る側） | TileState |

## モジュール 1 行紹介

- **Grid** — 正方タイルの「何列目・何行目」と画面上のピクセル位置を相互に変換する。セル座標の規約は 2 つ: 左上原点・tileSize 割りの系（cellAt）と、セル中心が整数・境界 ±0.5 の系（cellAtCentered — GridRay / WallFaces が使う）。
- **TileState** — マス目の「いま」を持つ疎な表（耕した・濡れた・置いた）。日ごとの一斉更新とセーブの往復を持つ。地図の形（読むだけの設計図）とは置き場所を分ける。
- **GridSearch** — マス目の上で「どこまで行けるか・何歩かかるか・どこが射程か」を求める。
- **Steering** — 距離場（GridSearch）の 1 歩 chase / flee / wander。「入れるか」は canEnter で注入。敵 AI とイベントシーンが同じ 1 歩を使う。乱数を持たず同着は固定順 — 何度描き出しても毎回同じ。
- **GridRay** — マス目の世界で「start から goal の間に壁が挟まるか」（視線の遮蔽）。壁の向こうの松明を消す・敵から主人公が見えるか、の見通し判定。solid の判定は関数で注入する。
- **Dir4** — 上下左右の 4 方向を 1 つの値としてまとめて表す。
- **TileScene** — App.withTileLayers のタイル層宣言(TileLayerSpec)を CPU 投影で普通の絵へ変換する。ヘッドレス生成・F8 停止画面・スナップショットが GPU の事前生成と同じ絵になるための橋。
- **DualGrid** — セル4角の埋まり方から 16 ケースの地形多角形(丸/四角/ひし形/揺らぎ)を作る純幾何。概念: docs/dual-grid.md。
- **Material** — DualGrid のタイルに質感(塗り・フチ・持ち上げ・表面の粒)を着せる。チップ絵は使わない。チップ絵ではなく色と質感パラメータで手続き生成する。
- **Terrain** — 「どのセル文字に、どの質感を着せるか」の表と rows アダプタ。rows の文字格子を塗るだけで DualGrid の角の変化形が自動生成される。fromRows は Doc+rows だけで完結する教科書 API。
- **TerrainDoc** — セル文字→質感の表の宣言(*.terrain.json)を読む codec。色は #rrggbb か @キー(テーマ参照)。

## 地形の 4 つ（DualGrid / Material / Terrain / TerrainDoc）の見本

**この 4 つ(DualGrid / Material / Terrain / TerrainDoc)を呼ぶ見本はこのリポジトリに無い。**`templates/` にも `bench/` にも呼び出し元は 0 件で、`.terrain.json` も 1 つも無い。使うときの写経元は `engine_world/src/Terrain.flix` / `Material.flix` / `TerrainDoc.flix` の冒頭 doc コメントと、Doc の形は `engine_world/test/TestTerrainDoc.flix`。仕組みの説明は[dual-grid.md](../dual-grid.md)。
