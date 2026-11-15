# 書き味の見本: 3D の不透明の batch を行にする（R2a）

R2a で 3D の不透明の batch（頂点の色の物・骨つきの物・不透明の材質の物）を `Render3d.SceneList` の行にし、GL の backend（`Render3d.GlRows`）が流す形にした。
計画（`Render3d.ScenePlan`）は GL も GL の `State` も受けず、backend に聞く物（描き先の能力・材質ごとの順の番号と使えるか）は値で受け取る。決める所は 3 つ。
比べはこの Mac（Apple M4 Pro・macOS 27・GL は Apple の Metal の上の OpenGL）で、2026-11-16。別案のコードは commit していない。

## 1. 1 行の高さ（9.1 の「`RenderList` の 1 行の欄と高さ（3D）」）

| 見る点 | (A) 1 行 = batch 1 つ・backend が行ごとに材質を付け直す | (B) 低い高さ: 「材質を付ける行」と「形を描く行」を分ける | (C) 1 行 = batch 1 つ + 「前の材質の行と同じ付け方」のフラグ（入れた形） |
|---|---|---|---|
| 行の数 | batch の数 | batch の数 + 付け方が替わる回数（形が物ごとの場面で材質 1 種なら +1・付け方が毎回替わる場面で倍） | batch の数 |
| 付け直すかを決める所 | backend（GL は毎行 cutout・uParamN・絵・sampler を入れ直す） | 前半（行の種類で表す） | 前半（`SceneList.isSameBinding`・GPU 無しのテストで固定） |
| field 12,000・形が物ごと・材質 1 種の `draw`（CPU の区間・p50） | 33.5〜35.4 ms | 動かしていない（GL の呼び出しは (C) と同じになる） | 28.3〜30.1 ms |
| 同じ場面の 1 コマ（frame p50） | 70.5〜74.9 ms | — | 73.2〜78.0 ms（起動ごとの揺れの内。`bench/scene3d/RESULTS.md` の「±20% に見える」） |
| field 12,000・形 1 つ・材質 1 種（frame p50） | 15.3〜15.5 ms | — | 15.4〜18.9 ms（1 回目の 2 区間が遅い回。split が 13.5〜14.7 ms で、行の分は `draw` 0.2 ms） |
| gl-parity | 81 行が変える前の木と 1 字も同じ | — | 同じ |

**(C) に決めた。** 2D の形のレビューで決めた「物の集まり」の高さ（判断 13）を 3D でも崩さず、付け直さずに済むかを前半の 1 か所で決められる。
WebGPU では (C) のフラグが「材質の bind group を付け直さない」に、(B) の材質の行が `setBindGroup` に当たり、backend が出す命令は同じになる。
(B) は行の種類が 1 つ増えて「材質の行の後に形の行が来る」という並びの決まりを 2 つの backend が守る事になるので、動かして比べるまでもなく取らなかった（GL の呼び出しが (C) と同じなので速さは変わらない見込み【推】）。

```flix
// 前半（SceneList.putMaterialRow）: 描く物のある行だけ、前に描いた材質の行と比べる。
let same = if (drawn and Option.exists(p -> isSameBinding(p, d), previous)) flagSameBinding() else 0;
// GL（GlRows.drawMaterialRow）: フラグが立っていれば draw だけ。
if (hasFlag(list, row, flagSameBinding())) () else { useMaterial(…); bindMaterial(…) };
drawWithLook(gl, look, () -> drawRowRange(gl, state, entry#locs#mesh, frame, row))
```

`isSameBinding` は順の番号・材質の木の鍵・params・cutout・wrap・法線マップ・材質の絵の名前が同じで、lightmap の版でない事（lightmap は物ごとに絵が違う）。
直しを外した確かめ: params を比べないようにすると `testOtherParamsRebind` が落ちる。

## 2. 計画が材質の状態を backend に聞く形

| 見る点 | (a) 値で聞く: 前半が聞く材質を並べ（`groupScenes`）、backend が引いて順の番号の列を返し（`resolveMaterials`）、前半がそれで分ける（`planScenes`）（入れた形） | (b) 関数で聞く: `planScenes` に「材質 → 順の番号」の関数の record を渡し、batch ごとに呼ぶ |
|---|---|---|
| 判断 13 の「record は list を作る def へ渡さない」 | 守る | 破る（計画の中から backend の関数を呼ぶ） |
| GPU 無しのテスト | 答えを `Vector#{9, 3}` のように値で渡せる（`TestSceneList` の計画の 5 本） | 偽の関数を作れば書ける |
| 行数 | 前半に `GroupedScene`・`requestsOf`・`splitGroups` の分（約 40 行）が増えた | (a) より約 20 行少ない見込み【推】 |
| 材質を組む順 | 場面の順・候補の順（前と同じ。`testProgramsBuildInArrivalOrder` が緑） | 同じ |

**(a) に決めた。** 2D の upload を関数の record にして list を作る前に呼ぶ形（判断 13）と同じ並びで、計画が backend を呼ばない事を型で守れる。(b) は動かしていない（行数の見込みだけ）。

## 3. 材質の batch が backend の材質を指す形（`MaterialBatch#entry` を替える）

| 見る点 | (a) 材質の表の番号（`handle` = 聞いた並びの番号。表は 1 回の prepare ごと・GL の backend の持ち物）（入れた形） | (b) 材質の鍵の字（`materialKey`）を持ち、描く時に `materialsRef` から引く |
|---|---|---|
| 同じ鍵で中身の違う材質が同じコマに来た時（`warnMaterialThrash` の場面） | 先の batch は先に組んだプログラムで描く（前と同じ） | 先の batch も後で組み直したプログラムで描かれる |
| 前半の仕事 | 数を 1 つ持つだけ | batch ごとに鍵の字を組む（field の形が物ごとの場面で 1 コマ 12,000 回） |
| 描く時の仕事 | `Vector.get` | 字の鍵で Map を引く（(C) のフラグがあれば付け直す行だけ） |

**(a) に決めた。** 2D の絵の番号（backend の表の番号）と同じ考えで、前と振る舞いが 1 つも変わらない。(b) は動かしていない。
