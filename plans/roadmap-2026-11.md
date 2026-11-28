# これからの計画（2026-11-26 時点）

状態: 計画（git に入れない）。engine は v0.113.1 公開済み・main に段 A/B（1 回しか使わない形をつなぐ・Scene3dCheck・glTF の doubleSided）を取り込み済みで **未 push**。
順番の決め方: 先に「2 回目の対決の評価」に効く物、次に安全に小さく入る物、最後に層を変える大物。大物は計画とスパイクで 90 点を超えてから。

## 1. 今走っている物

| 物 | 状態 | 済んだら |
|---|---|---|
| glb の計画（plans/engine-web-glb-worker.md） | 段 1・2 済・段 3（束を半分に）中 | 親が測りを確かめて main へ。段 2 は口を消すので、段 1 だけ先に版を出すか決める |
| MultiMesh のスパイク（枝 worktree-agent-aa7a62051242ca97d） | 案 1（今の道の重い所を消す）・案 2（`MultiMesh3d`）を試作済み・測り中 | 結果を見て、案 1 / 案 2 / 両方を相談。plans/engine-horde-perf.md と重なる所を確かめる |

## 2. 次の順番

| 順 | 物 | 中身 | 大きさ（実時間） | 人の判断 |
|---|---|---|---|---|
| 1 | glb の取り込みとリリース | 測りの確かめ・main へ・night_school と conduit_hive の追随（conduit_hive は forbid.local.json の exempt） | 1〜2 時間 | 版の出し方（段 1 を先に出すか） |
| 2 | 動く物の方針 | MultiMesh の結果で決める。入れるなら計画を書いて 90 点 | 計画 1 時間・実装は結果次第 | engine の拡張なので相談 |
| 3 | native の (a)(b) | デスクトップの絵の読み書きを AWT から stb へ・native では起動し直さない | 2〜3 時間 | 了承済み（11-26） |
| 4 | 自動で先に作る（plans/engine-auto-preload.md） | 推す答え A のまま | 3〜4 時間 | 了承済み |
| 4b | 後から届く素材を近い物から解く（plans/engine-background-load-priority.md） | A: 見込みを鍵ごと（大きさから学ぶ）・B: プレイヤーからの距離で並べる。スマホで人物が出遅れた件の根っこ（0.114.0 はテンプレートで Group を分けて当座しのぎ） | 計画中・4〜6 時間（推測） | 了承済み（11-26）・計画のレビュー 90 点の後に実装 |
| 5 | 2 回目の対決の評価 | three.js の行を足す（npm の取得はその時に許可を取る）・Godot の 1 階の絵が消える原因・2D と 3D を分けて記録・「ゲームのコードを触らずに直せた割合」・公開できる比べの表の初版 | 3〜4 時間 | three の取得の許可 |
| 6 | handler の分割（plans/engine-handler-split.md） | 棚卸し → 分ける所だけ分ける。7 の土台 | 計画で決める | 計画のレビュー 90 点の後に相談 |
| 7 | native の組み立ての口（(c)） | 設定取り → native-image → PGO の口・「1 回組んで何度も流す確かめ」で使う・普段の短い確かめは JVM の設定で軽く | 計画で決める | 計画のレビュー 90 点の後に相談 |
| 8 | デスクトップのストリーミング | `LwjglLoad` が裏のスレッドで解いて届いた物から返す（ゲームのコードは触らない）。差し替えは LwjglLoad.handleWith の 1 か所（downloads の引数を足すので render_gl の pub が 1 つ変わる・台本や撮影の有無は engine_full かゲームの入口で決める） | 計画で決める | 急がない（今の規模では起動は困っていない） |
| 9 | GPU 用の圧縮した絵（KTX2 など） | 組み立てで変える道具・3 つの描き手の上げ方・SoftRaster と gl-parity の扱い | 大物。スパイクから | 外の道具の取得の許可 |

## 3. 合間に挟む手入れ（伸ばす速さを保つため）

- 並べて流すと時間の揺れで落ちる render_gl のテスト（`Render3d.TestCounts.testNestedPhaseIsNotCountedTwice`・`TestStaticRows.testMinimumStepGoesToOneWorkPerFrame`）
- main でも赤の go のテスト（`go/internal/testselect` の 4 本・`go/internal/dashboard` の 1 本）
- 段 B の残り: テンプレートの小物に当たりが無い（約 100 種）・上の階の抜け穴を見ていない
- 開発の 1 周の内訳を測る（人の了承 11-26）: engine を 1 か所直してから確かめが済むまでを、コンパイル（sync-engine-full・パッケージの組み立て）・テストの JVM の起動・ゲームの起動・素材の読み込み・描き出しに分けて時間を出す。`make verify` の門ごとの時間（今日の affected: go-test 5m4s・test 1m54s・render-all 2m16s）も使う。7 の native をどの確かめに使えば効くかを、この数で決める

## 4. 先の候補（計画の種だけ）

- AI に同じ仕様を渡して、うちと Godot で作らせる比べ（毎月 1 回の定点観測）
- ライセンスと公開の形（オープンソースか・法人の扱い）。作品がそろってから
- 重い場面での JVM と native の比べ（動く物のベンチの PC 版・night_school の上の階）
- 風で揺れる草原: MultiMesh を `Mobility.Static` で置き、揺れは頂点シェーダーで時刻と場所から曲げる（Godot・Unity の草と同じ形・CPU はほぼゼロ）。今の engine に 3D の風の頂点シェーダーは無い。MultiMesh だけなら CPU で揺らして 2 万本ほどまで（スパイクで 2 万個 6.9 ms）
