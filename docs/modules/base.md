# 土台（App・ECS・数の道具）と重いとき

> [docs/module-index.md](../module-index.md) の分野の 1 つ。1 行 = 1 件で、`make module Q=<語>` が行ごとに引く。
> 型と引数は `make api Q=<名前>`、使い方は `engine_world/src/<名前>.flix` 冒頭の doc。

## やりたいこと → モジュール

| やりたいこと | モジュール |
|---|---|
| 0〜1 に収める・小数部だけ残す・周期で折り返す（負の値も安全） | Num.clamp01 / clamp / fract / wrapTo / lerp |
| 床丸め・最近整数（0.5 は上へ）で Int32 に落とす（負の座標もマスが揃う） | Num.floorInt / roundInt |
| 値を範囲に収める（1 軸） | Num.clamp（カメラの寄せ幅は CameraRig.clampAxis） |
| 番号（敵・日付・タイル）で列から 1 つ選ぶ（同じ番号なら毎回同じ・乱数の状態を持たない） | Hash01.pickBy({ index, channel }, 列) / indexOf(鍵, 個数) |

## モジュール 1 行紹介

- **App** — ゲームを「宣言」で組み立てて走らせるランナー。
- **EntityId** — entity を識別する番号（共有 ECS lib のトップレベル型）。
- **Query** — 部品ごとに分かれた表から「同じ物が持つ複数の部品」を突き合わせて取り出す。
- **Hash01** — 2 つの整数から 0 以上 1 未満のばらついた数を 1 つ決める（決定論の乱れ）。列から 1 つ選ぶ indexOf / pickBy（台詞の差分・技・柄を乱数の状態なしで）。
- **RandomUtil** — 乱数の小さな操作。リストから 1 つ選ぶ・範囲内の実数を引く。

## 症状 → モジュール（重い・fps が落ちる）

| 症状 | モジュール |
|---|---|
| 小さすぎて見えない物・画面外の物を大量に作っている | Scatter.strip（作る前に捨てる。reach 余白と cellsMax の倍々間引き） |
| 動かない背景を毎フレーム作り直している | App.withStaticLayer（鍵が同じ間は GPU バッファを使い回す） |
| タイルが多い・タイル宣言の組み立てが毎フレーム走る | App.withTileLayers（tiles はサンク — 鍵が変わるまで評価されない） |
| 遠くで 1px を切る物まで組み立てている | 倍率の床で place ごと切る（実戦の例: templates/race-starter の propCull / palmCull） |
| 1 マスを画素ぶんの box で組んでいる（絵は同じでも桁が違う） | PxSprite.drawQuad（1 コマ = 1 クアッド）。アトラスは PxSpriteAtlas.bake + App.withSpriteAtlases |
| 動画の連番・ギャラリーの描き出しが遅い（コマごとにテクスチャのファイルを読み直している） | SoftRaster.freshTextureCache + renderToImageCached（コマ列の前に 1 本作って持ち回る。画素は同じ） |
| 描き出しの口を流すたびにコンパイルし直している | mk/game.mk の HEADLESS_RUN（bin/headless-run が jar を 1 回だけ作って使い回す。ゲームの Makefile で上書きしない） |
| make reference-check / make status が「budget NG」と言う | 絵の値段の検査（決まりと逃がし方は docs/performance.md §9）。静的層ぶんは HeadlessRender.noteStaticItems で申告して引く |
