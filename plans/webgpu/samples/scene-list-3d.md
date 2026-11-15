# 書き味の見本: 3D の不透明の batch を行にする（R2a）

R2a で 3D の不透明の batch（頂点の色の物・骨つきの物・不透明の材質の物）を `Render3d.SceneList` の行にし、GL の backend（`Render3d.GlRows`）が流す形にした。
計画（`Render3d.ScenePlan`）は GL も GL の `State` も受けず、backend に聞く物（描き先の能力・材質ごとの順の番号と使えるか）は値で受け取る。決める所は 4 つ。
比べはこの Mac（Apple M4 Pro・macOS 27・GL は Apple の Metal の上の OpenGL）で、2026-11-16。別案のコードは commit していない。
「1 回目」は最初のコミット（計画の内側は record の形）、「2 回目」はレビューの後（計画の内側を配列で回した後）。

## 1. 1 行の高さ（9.1 の「`RenderList` の 1 行の欄と高さ（3D）」）

| 見る点 | (A) 1 行 = batch 1 つ・backend が行ごとに材質を付け直す | (B) 低い高さ: 「材質を付ける行」と「形を描く行」を分ける | (C) 1 行 = batch 1 つ + 「前の材質の行と同じ付け方」のフラグ（入れた形） |
|---|---|---|---|
| 行の数 | batch の数 | batch の数 + 付け方が替わる回数（形が物ごとの場面で材質 1 種なら +1・付け方が毎回替わる場面で倍） | batch の数 |
| 付け直すかを決める所 | backend（GL は毎行 cutout・uParamN・絵・sampler を入れ直す） | 前半（行の種類で表す） | 前半（`SceneList.isSameBinding`・GPU 無しのテストで固定） |
| field 12,000・形が物ごと・材質 1 種の `draw`（CPU の区間・p50）・1 回目 | 33.5〜35.4 ms | — | 28.3〜30.1 ms |
| 同じ・2 回目（(B) と (C) を同じ日に 2 本ずつ） | — | 27.1〜30.1 ms | 27.0〜27.2 ms |
| 同じ場面の 1 コマ（frame p50）・1 回目 | 70.5〜74.9 ms | — | 73.2〜78.0 ms（起動ごとの揺れの内。`bench/scene3d/RESULTS.md` の「±20% に見える」） |
| 同じ・2 回目 | — | 57.6〜62.5 ms | 57.2〜59.0 ms |
| gl-parity | 81 行が変える前の木と 1 字も同じ | 同じ | 同じ |
| 行の形を見る `TestSceneList` | — | 行の数と種類の並びを見る物が落ちる（材質の行の前に付ける行が挟まる） | 緑 |

**(C) に決めた。** (B) は GL の呼び出しが (C) と同じで速さは揺れの内、行の種類が 1 つ増えて「材質を付ける行の後に形の行が来る」という並びの決まりを 2 つの backend が守る事になる。
(C) は 2D の形のレビューで決めた「物の集まり」の高さ（判断 13）を 3D でも崩さず、付け直さずに済むかを前半の 1 か所で決められる。
WebGPU では (C) のフラグが「材質の bind group を付け直さない」に、(B) の材質の行が `setBindGroup` に当たり、backend が出す命令は同じになる。
(B) の試しは `SceneList.putMaterialRow` で付け直す行の前に種類 4 の行を足し、`GlRows` がその行で `useMaterial`・`bindMaterial` を呼ぶ形（約 25 行）。

```flix
// 前半（SceneList.putMaterialRow）: 描く物のある行だけ、前に描いた材質の行と比べる。
let same = if (drawn and Option.exists(p -> isSameBinding(p, d), previous)) flagSameBinding() else 0;
// GL（GlRows.drawMaterialRow）: フラグが立っていれば draw だけ。
if (hasFlag(list, row, flagSameBinding())) () else { useMaterial(…); bindMaterial(…) };
drawWithLook(gl, look, () -> drawRowRange(gl, state, entry#locs#mesh, frame, row))
```

`isSameBinding` は順の番号・材質の木の鍵・params・cutout・wrap・法線マップ・材質の絵の組（名前と補間）が同じで、lightmap の版でない事（lightmap は物ごとに絵が違う）。
直しを外した確かめ: params を比べないようにすると `testOtherParamsRebind` が落ちる。GL がフラグを見ないようにすると `testSecondSameMaterialRowDoesNotRebind`（偽の GL で cutout の uniform と絵の数が 1 行の時と同じ）が落ちる。

## 2. 計画が材質の状態を backend に聞く形

| 見る点 | (a) 値で聞く: 前半が聞く材質を並べ（`groupScenes`）、backend が引いて順の番号の列を返し（`resolveMaterials`）、前半がそれで分ける（`planScenes`）（入れた形） | (b) 関数で聞く: `planScenes` に「材質 → 順の番号」の関数の record を渡し、batch ごとに呼ぶ |
|---|---|---|
| 判断 13 の「record は list を作る def へ渡さない」 | 守る | 破る（計画の中から backend の関数を呼ぶ） |
| GPU 無しのテスト | 答えを `Vector#{9, 3}` のように値で渡せる（`TestSceneList` の計画の 7 本） | 偽の関数を作れば書ける |
| 材質を組む順 | その材質の物が初めて来た順（前と同じ。`testProgramsBuildInArrivalOrder` が緑） | 同じ |

**(a) に決めた。** 2D の upload を関数の record にして list を作る前に呼ぶ形（判断 13）と同じ並びで、計画が backend を呼ばない事を型で守れる。(b) は動かしていない。
2 回目で、同じプログラム（版と材質の木の鍵が同じ）の材質は 1 回だけ聞くようにした（前は batch ごとに聞いていた。形が物ごとの場面で 12,000 回 → 1 回）。

## 3. 材質の batch が backend の材質を指す形（`MaterialBatch#entry` を替える）

| 見る点 | (a) 材質の表の番号（`handle` = 聞いた並びの番号。表は 1 回の prepare ごと・GL の backend の持ち物）（入れた形） | (b) 材質の鍵の字（`materialKey`）を持ち、描く時に `materialsRef` から引く |
|---|---|---|
| 前半の仕事 | 数を 1 つ持つだけ | batch ごとに鍵の字を組む（field の形が物ごとの場面で 1 コマ 12,000 回） |
| 描く時の仕事 | `Vector.get` | 字の鍵で Map を引く（(C) のフラグがあれば付け直す行だけ） |
| 木の鍵がぶつかった 2 つの材質（64 ビットの衝突） | 3 回目から、問い合わせのまとめで当たった時に `ShaderGen.eqMaterial` で 1 回比べ、違えば別の問い合わせ（別の番号）にする。表の番号はそれぞれのプログラムを指す | 2 つが同じ鍵の 1 つの控えを指し、後で組み直した方のプログラムで両方を描く |

**(a) に決めた。** 2D の絵の番号（backend の表の番号）と同じ考え。(b) は動かしていない。

## 4. 計画の内側を配列で運ぶ形（決まり 9 の 3D の分・2 回目）

field 12,000 の JFR（変える前の木・20 秒・875 標本）で、標本の 51% が record の欄の引き当て（`RecordExtend.lookupField`）。
呼び手は `Batch.hasSameTree`（物ごとに材質の木を比べる）・`Batch.kindBits`・`Batch.batchKeyOf`（物ごとに batch の鍵の組を作って Map で比べる）・`Material.vertexKindOf`・`Batch.batchOf`。

| 見る点 | (a) 物ごとに record を作って列で運ぶ（1 回目の形） | (b) 材質の値と頂点の形ごとに分け方を 1 回だけ決め、物ごとは配列の上の番号の引き当てだけ（入れた形） |
|---|---|---|
| 物ごとの仕事 | `PlacedDraw`・版の record・batch の鍵の組・Map の比べ・候補の中の木の比べ・batch の列 | 材質の値（同じ 1 つの値）で引く `IdentityHashMap`・(形の字, 鍵の番号) の引き当て・配列への書き込み |
| 描く物の運び方 | batch ごとの `List[MeshDraw]` | prepare の配列（`Grouped#members`）の範囲（`SpanBatch`） |
| split（field 12,000・形 1 つ・frame p50 の区間） | 12.1〜14.7 ms | 6.3〜6.4 ms |
| 1 コマ（同じ） | 15.3〜18.9 ms | 9.8〜10.1 ms |
| 形が物ごとの split | 24.4〜26.4 ms | 26.0〜27.7 ms（候補が物の数だけでき、候補ごとの仕事が残る） |
| gl-parity | — | 81 行が変える前の木と 1 字も同じ |

**(b) に決めた。** `TestRender3dBatch` が呼ぶ純粋な関数（`batchOf`・`shapeBatches`・`groupInOrder`・`groupByTextures`・`numberBatch`・`packDraw`）は record を返す口のまま残し、テストは 1 字も替えていない。
候補の並び（(形, 鍵) が初めて来た順・その中は絵の名前の並びが初めて来た順）は `groupInOrder` と `groupByTextures` の並びと同じにしてある（同じ深さの面の勝ち方を変えない）。

```flix
// 物ごと（ScenePlan.placeOne）: 分け方は材質の値と頂点の形の番号で控えから引く。
let p = placementOf(g, d);                  // IdentityHashMap → (頂点の形の番号 → Placement)
let level = levelOf(split, d, p);           // (形の字, 鍵の番号) → 候補の番号
Array.put(subOf(split, level, p#texture), i, subs)
// 候補ごと（spansOf）: 描く物を候補の順に members へ詰め、SpanBatch は範囲だけを持つ。
{ batch = { head = …, start = base + start, count = count }, surface = p#surface, handle = p#handle }
```
