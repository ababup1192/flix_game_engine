# 3D の道具箱（一人称で歩いて調べるゲームのための 14 の口）（rev3）

レビューの推移: rev0 72 点 → rev1 84 点 → rev2 88 点 → rev3（軽い指摘 3 件を直した）。記録は末尾。

2 本のゲーム（`/Users/abab/Documents/flix_ge_workspace/night_apartment`・`/Users/abab/Documents/flix_ge_workspace/fps3d_lab`）を engine 無改修で作り、
ゲーム側で回り道をした所から 14 の候補が出た。人の決定（2026-11-03）: **全部入れる・開発しやすい物から・段ごとにデモ（night_apartment）を追従させる**。
この計画は設計だけ。engine のソースは変えていない。実装は lightmap（`plans/engine-round9-lightmap.md`・0.75.0 の WIP）の後に、段ごとに相談してから始める。

用語:
- 置いた物 = `Scene3d.Instance3d`
- 動く光 = `PointLight` / `SpotLight`
- 描き手 = GL（`render_gl/src/Render3d.flix`）と CPU（`engine_tools/src/SoftRaster3d.flix`）。CPU の描き手は画面なしの描き出し・テスト・agent-eval が使う
- 箱 = 向きのある直方体（OBB）。軸にそろった箱は AABB と書く

名前について: `plans/engine-round10-2d3d-mix.md`（段 I・2D と 3D を混ぜる）と番号が重なる。どちらを先にするかは §10 の Q1 で人に聞く。

---

## 0. 調べて分かったこと（ソースで確かめた・2026-11-03）

| # | 候補 | 今の engine | 判定 |
|---|---|---|---|
| 1 | glTF のノードの名前と位置 | `Gltf.buildModel` はノードの world 行列を頂点に焼き込み、名前と行列を捨てる。`Model3d` に節の欄が無い。mesh の無いノード（empty）は読まない | **無い**。読む材料（`nodeMatrix`・`chainOf`・`productOf`）はある |
| 2 | マウスを閉じ込めて相対の動き | `glfwSetInputMode` は `GLFW_CURSOR_NORMAL`/`HIDDEN` の切り替え（`setCursorVisible`）だけ。`App.Frame` は `cursor`・`mouseDown`・`mouseMoved`(Bool)・`wheel` で、動いた量が無い。窓のフォーカスを知る口も無い | **無い**（隠すのはある） |
| 3 | 3D の当たり判定と歩き | 2D の `CollisionShape2D`（カプセル・坂・多角形）だけ。3D は無い | **無い**。night_apartment の `Collider`・`Walker` が実証済みの材料 |
| 4 | 見ている物を調べるレイ | レイの型・交わりの判定・画面の点 → world のレイ、のどれも無い（`Camera3d.worldToScreen` の逆向きだけある） | **無い** |
| 5 | フラスタムカリング | `Mesh3d.bounds`（形の座標の min/max）は**作る時に計算済みで持っている**が、使う所が 0 件。GL も CPU も裏面の間引きだけ | **半分ある**（境界は有る・判定が無い） |
| 6 | 色を線形で計算する | Pass の形式は `Rgba8Unorm`/`Rgba16Float`。`GL_SRGB` は不使用。sRGB の式は lightmap の中だけ（`Texture3d.srgbToLinear` など） | **無い**。下書きは `plans/engine-round8-linear-color.md`（段 G） |
| 7 | スポットの内側と外側の角度 | **縁はもうなめらか**: GL も CPU も `smoothstep(cos(fovY/2), cos(fovY/2 × spotInnerRatio()), dot)`、`spotInnerRatio() = 0.8` の固定（Render3d.flix:215・SoftRaster3d の頭の式） | **半分ある**（内側の角が固定で変えられない） |
| 8 | glb の emissive の絵・spec 名の共有 | `Gltf.usedImages` は baseColor と normal だけを decode する（0.75.0 で ORM・emissive を読まなくした）。材質は全部 `texturedMaterial` で spec 名 `scene3d:textured:<filter>`。プログラムの鍵（`Render3d.materialKey`）は `"3d"[+skin][+uv][+nm][+lm]:spec名` で、emission の有無は鍵に入らない。鍵が当たって中身が違うと `rebuildMaterial` で組み直し、同じコマなら警告する | **無い**＋鍵の穴。今は emission を付けないので壊れていないが、付けた瞬間に組み直しが起きる（night_apartment は `Stage.renamed` で spec 名を替えて避けている） |
| 9 | 半透明 | 3D は cutout だけ（`beginScene` が `glDisable(GL_BLEND)`・材質の出す α は 1）。並べ替えはプログラム番号の順だけ。CPU は画素ごとに深度の勝者 1 つ。glTF の `alphaMode` は読まない | **無い** |
| 10 | 細い物の欠け（MSAA） | `GLFW_SAMPLES`・マルチサンプルの renderbuffer は 0 件。縁をならすのは `PostProcess.fxaaSpec` だけ | **無い**（FXAA はある） |
| 11 | 空のグラデーション | `Environment3d.background = Option[Color]`（GL は scissor の中を `glClear`、CPU は塗る）。night_apartment は 2D の `Render.shaderFill` の Ramp を場面の下に敷き、見上げる角から地平の高さを毎コマ計算している | **無い**（2D で代わりは組める） |
| 12 | 場面の絵の枚数の上限 | `Render3d.texture3dCountBudget() = 64` の固定。GPU に持つ絵のキャッシュの枚数（texture unit の数ではない）。MB は 0.75.0 で project.json の `scene3dTextureBudgetMB` になった | **半分ある**（MB だけ外に出ている） |
| 13 | GPU の時間を測る | timer query は 0 件。`FrameDiagnostics` は CPU の時計（submit・swap）と数（shader・drawItems）だけで、App のヒッチの記録だけが読む。ゲームからは見えない。3D の数（置いた物・draw call）も入っていない | **無い** |
| 14 | 点光源を近い順に 8 個 | **もうある**: `Scene3d.pickLights`（点 8・スポット 2 を目に近い順・同じ距離なら並びの前）を GL の `drawScene`・`shadowCasterOf` と CPU の `renderLayer` が呼んでいる。night_apartment の `RoomLights.nearest` は同じ処理の写し（並びの戻し方だけ違う） | **ある**。残るのは文書とデモの掃除。境界での点滅（fps3d_lab が光をまとめて避けた）は別の話（§3.14） |

思ったより**小さい**物: 5（境界は持っている）・7（縁はもうなめらか）・12（1 行の定数）・14（済み）。
思ったより**大きい**物:
- 1: ノードの局所の境界（焼き込む前の形の座標の min/max）まで出さないと、当たり判定の箱が作れない
- 3: 段差・坂・落ちる・挟まれる、の決まりが多い。night_apartment で Collider 251 行 + Walker 165 行
- 9: CPU の描き手が「画素ごとに勝者 1 つ」の作りなので、半透明は 2 つ目の段として足す
- 13: ゲームに見せる口（`App.Frame`）までつなぐ

ゲーム側の回り道（エンジンに入れる候補の根拠。night_apartment は全部読んだ。fps3d_lab は 3D に関わるファイルを全部読んだ）:
- night_apartment `Rooms.leafOf`: 扉の当たり判定の箱 `COL_door_202` を、名前で引けないので「蝶番の横・外壁の面・5 cm より薄い」で探している。`collision.glb` の 234 個のノードは全部 `COL_*` の名前と translation/rotation を持つ（python で JSON を読んで確かめた）。`doors_F2.glb` は `door_202`〜`205` の 4 ノード（原点が蝶番）
- night_apartment `Collider.boxOfMesh`: 焼き込まれた頂点と法線から箱の向きを推し量っている。ノードの行列と局所の境界があれば、そのまま正確な箱になる
- night_apartment `Controls.inputOf`: 左ボタンを押している間だけのドラッグで視点を回す（「engine にはマウスを窓の中に閉じ込める口が無い」とコメントにある）
- night_apartment `StageView.sky`: 2D の Ramp で空を描いている
- night_apartment `Stage.decodePart` / `emissionOf`: emissive の PNG を glb の外から別に読み、点滅する管の範囲（mask）を掛けている
- night_apartment `Stage.renamed`: emission を足した材質の spec 名を替えている（組み直しを避けるため）
- night_apartment `Rooms.isDrawn`: 部屋ごとに描くかを決めている（壁の向こうを描かない。フラスタムでは代わりにならない）
- night_apartment `alpha_net.glb`: `alphaMode: BLEND`。ゲームは cutout にしている
- fps3d_lab `World.isFree` / `roomStep`: 2D の格子 + 円 + AABB で、高さは無い
- fps3d_lab `RoomView.lantern`: 手に持つ灯りを点光源で置いている
- fps3d_lab `RoomView.windowPool`: 円錐の縁が床に輪として映るので、円錐を広げて range で消している（7 の根拠）
- fps3d_lab `RoomView.chandelierLamps`: 8 本を超えると遠い光が点いたり消えたりするので、光を平均の位置 1 つにまとめた
- fps3d_lab `Props.flamePoints`: 芯の先の座標をコードへ手で写し、x も手で裏返している（1 の empty の根拠）
- fps3d_lab `View.warmPlan`: 部屋に入った最初のコマで止まらないよう、読み込み中に見えない Pass へ 1 つずつ描いて、シェーダーと絵を先に作らせている（5 のカリングで悪化させてはいけない根拠。§3.5）

---

## 1. 共通の決まり

- **使わないゲームの絵は 1 bit も変えない**: 各段の終わりに次の 3 つを確かめる
  - `make gl-parity`: A 段階の全部の行がバイト一致・B 段階の既存の行は差の画素の数が段の始めに控えた数と同じ
  - テンプレートの reference（`templates/*/reference/SHA256SUMS.txt`）が一致
  - `TestDrawHash` の固定値が変わらない
- 絵が変わる物（§9 の表）は、その版の移行メモ（`docs/migrations/<版>.md`）に書く。
- **レコードの型に欄を足すと、字で全部の欄を書いた所が止まる**（`SpotLight`・`Environment3d`・`TextureLimits`・`App.CursorSpec` はゲームが字で書いている）。
  - 足す時は、欄を足す代わりに閉じた型の `with*` か別の宣言にする。
  - それができない物（7 の `SpotLight`）だけ欄を足して移行メモに書き、同時に作る関数（`Scene3d.spotLight`）を足す。今後の欄はその関数で吸収する（`Scene3d.lightmap(name)` と同じ作法）。
- GL と CPU は同じ式で描く。式は SoftRaster3d の頭のコメントに一本化してあるので、そこを直してから両方を書く。gl-parity の行を足す。
- **描き出しの鍵（`engine_tools/src/DrawHash.flix`）を必ず直す**。
  - `putSceneCmd`・`putMaterial`・`putSpotLight` はレコードの全部の欄をパターンで書いているので、欄を足すとコンパイルが止まる（止まるのは良い。入れ忘れに気づける）。
  - 鍵に入れ忘れると、画面なしの描き出しのキャッシュが古い PNG を返し、agent-eval と render-loop が誤った絵で進む。
  - 決まり（0.75.0 の lightmap と同じ）: **None・偽・既定値の時は何も書かない**（今の鍵の字を保ち、前からあるキャッシュを塗り直させない）。それ以外の時だけ 1 バイトの印と値を書く。
  - TestDrawHash に「その欄で鍵が変わる」「既定値では今の固定値のまま」のテストを 1 本ずつ足す。
  - 欄ごとの扱いは §3 の各節の「鍵」の行。
- 毎コマ通る知らせは名前ごとに初回 1 回だけ（`docs/error-handling.md`）。
- 新しい口を入れたら、`agents-pack/AGENTS.core.md` の早見表に 1 行と `agents-pack/agent-eval/engine.json` にお題を 1 本足し、ゲームの足元で `make agent-eval ONLY=<お題>` を通す。
- 二乗を書かない（`docs/flix-conventions.md`）。当たり判定の箱の検索は格子で引く（§3.3）。

---

## 2. やる順と段（フェーズ）

開発しやすい順（小さく・ほかに頼らない物が先）に並べ、依存で並べ替えた。

```
段 1  入力と計測と小さな口        #12 #14 #7 #2 #13      （絵は変わらない）
段 2  glTF の中身と描く量          #1 #8 #5              （#8 だけ emissive つきの glb の絵が変わる）
段 3  当たり判定とレイ            #3 #4                 （描き手に触らない）
段 4  見た目                      #11 #9 #10            （既定では変わらない。alphaMode が BLEND / MASK の glb だけ変わる。
                                                         doubleSided は既定で当てない — §3.9）
段 5  色の線形化                  #6                    （3D を使う全部のゲームの絵が変わる）
```

依存（矢印は「先に要る」）:
- 4 ← 1（ノードの名前と局所の境界から調べる物の箱を作る）・3 の形の型（`CollisionShape3d.Box3d`。段 3 で 3 と 4 を同じ段に置き、形の型を先に書く）
- 9 ← 5（並べ替えに置いた物の world の境界を使う）・8（glTF の `alphaMode` を `GltfMaterial` で受け取る）
- 10 ← 9 と同じ段（MSAA の上での alpha to coverage は cutout と半透明の両方に関わる）
- 6 ← 全部（式の全部に効く: 空の色・emission の強さ・半透明の混ぜ方・MSAA の resolve・lightmap の露出）。最後
- 13 は依存しないが**先に置く**。後の段（5・9・10）の重さを測る道具になる
- 3 は 1 が無くても書けるが、デモの当たり判定の箱を名前で作るのは 1 の後

| 段 | 候補 | engine の工数 | デモの追従 | 版（§8 の推し） |
|---|---|---|---|---|
| 1 | 12・14・7・2・13 | 5 日 | 1 日 | 0.76.0 |
| 2 | 1・8・5 | 7 日（gl-parity の道具に「描いた数」の確かめを足す 0.5 日を含む） | 1.5 日 | 0.77.0 |
| 3 | 3・4 | 5.5 日 | 2 日 | 0.78.0 |
| 4 | 11・9・10 | 11 日（下の内訳） | 1.5 日 | 0.79.0 |
| 5 | 6 | 6〜8 日 | 3 日（fps3d_lab も。段 2 の emission と段 4 の半透明の値の合わせ直しを含む） | 0.80.0 |

計: engine 34〜36 日・デモ 9 日。段 2 の emission の強さと段 4 の半透明の値は、段 5 の線形化でもう一度合わせ直す（2 回目の分を段 5 のデモに入れた）。

段 4 の内訳: 空 GL と CPU 1.5 日／半透明 GL 1.5 日・CPU の 2 段目（重なった層ごとに光を計算する）2.5 日・裏の面（GL と CPU と法線の反転）1 日・glTF の読み取りと選ぶ口 0.5 日／
MSAA の FBO と resolve（Pass を読む所の全部・`Target.flix` の history の写しを含む）2 日・alpha to coverage 0.5 日・gl-parity の道具に GL だけの行を足す 1 日／文書とお題 0.5 日。
各段の中の順は表の並び（小さい物から）。段の終わりにレビュー役を立てて 85 点以上を確かめ、デモを追従させてから次へ進む。段 3 と段 4 は途中（3 の後・9 の後）にもレビューを入れる。

### 段 1 の終わりのデモ（night_apartment）
- **マウスで視点**: 窓をクリックするとマウスを閉じ込め、動いた量（`frame#mouseDelta`）で向きを変える。Esc で放す（放した状態で Esc を押すと終了の確認）。左ドラッグの回り道（`World.cursorOf`・`withCursor(Some(..))`）は消す。感度と上下反転は `walk.kind.json`。
- **クロスヘア**: 閉じ込めている間だけ画面の真ん中に小さな印。`AGENTS.local.md` の「画面に字や HUD を出さない」とぶつかるので、§10 の Q4 で人に確かめる（推し: 2 px の点・ほぼ見えない濃さ）。
- **懐中電灯の縁**: `lights.json` の flashlight に `innerConeDeg` を足し、`Scene3d.spotLight` で組む。
- **GPU の時間**: F3 で `FrameDiagnostics.summaryLines` を左上に出す（CPU・GPU・Pass ごとの GPU・置いた物の数）。debug の表示なので HUD の決まりの外（release では出さない）。
- **掃除**: `RoomLights.nearest` を消し、全部の灯りを `pointLights` に渡す（engine の `pickLights` が選ぶ）。

### 段 2 の終わりのデモ
- **扉の当たり判定**を名前で引く: `Model3d.findNode("COL_door_202", collision)` の箱。`Rooms.leafOf` の位置の探し方を消す。
- **蝶番**を `doors_F2.glb` のノード `door_202` の行列から取る（manifest の hinge の写しを消せるか確かめる）。
- **当たり判定の箱**を `CollisionShape3d.boxOfNode` で正確に作る（`Collider.boxOfMesh` の法線から推し量る処理を消す。斜めの手すりを分ける処理は書き出しの形の事情なので残す）。
- **emissive**を glb から読む: `GltfMaterial.emissiveTexture` の名前に、点滅の mask を掛けた emission を組み直す。manifest の emissive の PNG を別に読む処理を消す。
  emission を差し替えると木が変わるので、spec 名も替える: `Stage.renamed`（材質を組み直して名前を替える 8 行）を `Scene3d.withSpecName("night:emissive:<部品>", m)` の 1 行にする。
- **カリング**の効き目を F3 の表示で見る（置いた物の数と、描いた数）。

### 段 3 の終わりのデモ
- **歩き**を `CharacterBody3d.moveAndSlide` に置き換える（`Walker` の体の状態と足音は残し、押し出し・床・落ちるを engine へ）。
  - 移す前と後の足元の一致は求めない（球の間・1 コマの秒の上限・周りの箱を引く距離をエンジンの口として決め直したので、成り立たない）。
    代わりに、ゲームの性質テスト（`TestWalkProperty` の 505 通り・`TestWalk` の階段の高さ・止まって震えない・速く走った時）を engine の口で流して、同じ性質が成り立つことを確かめる。
  - デモの Settings は `floorMaxAngleDeg = 90`（今は傾いた箱を全部床として扱う。`isTilted` は足音の種類にしか使っていない）。
  - 歩ける範囲（`walk#bounds`）は外側の 4 枚の厚い箱として world に入れる（区切りごとに範囲へ収める順番は無くなる。範囲の端の数 cm だけ止まり方が変わりうる）。
- **調べる**:
  - 見ている物を毎コマ `Camera3d.forwardRay` と `Ray3d.pickNearest` で引く。調べる物は collision.glb の `COL_PRP_*`・扉の箱。壁の箱も入れて、遮られたら何も選ばない。
  - 見ている間はクロスヘアの印を少し明るくし、物の名前を 1 行出す（文言は Doc）。
  - E で調べた文言を出す（Doc `inspect.kind.json`: ノードの名前の頭 → 名前と文言。新しい Doc。`/doc-design` に沿う）。
- **扉**の E: 今の「足元からの距離と向き」をやめ、レイが当たった扉を動かす。

### 段 4 の終わりのデモ
- **空**を `Scene3d.gradientSky` にする（`StageView.sky` の 2D の面と地平の計算を消す。色は `look.json` のまま）。
- **窓ガラス・網**: `alpha_net.glb`（BLEND）が半透明で描かれる。網と金網は `part#gltfMaterial` の `doubleSided` を見て `Scene3d.withDoubleSided(true, ..)` をゲームが当てる（engine は既定で当てない・§3.9）。2 階の部屋の窓に、ガラスの板の glb を Blender から書き出して足す（書き出しの作業へ頼む。ガラスが無ければ網だけで確かめる）。
- **MSAA**: 場面の HDR の Pass を `RenderTarget.withMsaa(4, ..)` にし、外階段の手すり・金網の欠けが減るのを見る。F3 で GPU の時間の増え方を見て、`look.json` で切れるようにする。

### 段 5 の終わりのデモ
- lightmap の `intensity` を 2.0 に戻し、露出を `exposureStops` 0.6 へ（`docs/lightmap.md` の予告どおり）。
- `look.json`・`lights.json` の光の値を線形の目盛りで合わせ直す。fps3d_lab の look.json 4 本も。

---

## 3. 候補ごとの設計

各節の形: 足す口 → 型と既定値 → GL / CPU → gl-parity とテスト → 文書・早見表・お題。

### 3.12 場面の絵の枚数の上限を project.json で（段 1）

- **足す口**: project.json の任意キー `scene3dTextureBudgetCount`（既定 64。1 未満は既定）。`GameEngine.defaultScene3dTextureBudgetCount()`。
  - `EngineConfig` に `scene3dTextureBudgetCount` の欄
  - `ProjectLoader` が読む
  - `RenderPaint.create` と `Render3d.fresh` の引数に足す（MB と同じ通り道）
- **既定**: 64 で今と同じ。絵は変わらない。
- **GL**: `texture3dCountBudget()` を State の値に置き換える。**CPU**: 上限は無い（触らない）。
- **テスト**: `ProjectLoader` が読む・1 未満は既定・欠けていれば既定。
- **文書**: `docs/lightmap.md` の「場面の絵の予算」に 1 行。早見表は 0.75.0 の行（`scene3dTextureBudgetMB`）に「・枚数は `scene3dTextureBudgetCount`」を足すだけ（新しいお題は作らない。§1 の「新しい仕組み」に当たらない設定の 1 キーなので）。
- **移行メモ**: `EngineConfig` を字で組む所（ゲームとテンプレートには無い。engine のテストだけのはず）に欄を足す。0.75.0 の範囲は広げない（§8）。
- **鍵**: 触らない（描き出しの絵に関わらない）。

### 3.14 点光源を近い順に 8 個（段 1・もうある）

- engine は直さない。`Scene3d.pickLights` の doc に「ゲームが選ばなくても、描き手がこれで選ぶ。全部の光を渡してよい」を足す。
- `docs/modules/<3D の分野>.md` と早見表の 3D の行に「光が 8 本を超えたら `pointLights` に全部入れる（engine が目に近い順に選ぶ）」と書く。`forbid.json` には入れない（ゲームの写しの形が決まらない）。
- デモ: `RoomLights.nearest` を消す。並びの戻し方が違うので、足す順の丸めで絵が数段だけ変わりうる（ゲームの reference を撮り直す）。
- **後に回す**（§7）: 境界をまたいだ光の点滅を抑える。8 番目と 9 番目の光を距離の差で薄くつなぐ・優先度を付ける。8 本を超える場面の絵が変わるので、口を分けて入れる時に決める。

### 3.7 スポットの内側の角度（段 1）

- **型**: `SpotLight` に `innerFovY = Option[Float64]` を足す。`None` = 今と同じ `fovY × spotInnerRatio()`（0.8）。`Some(a)` = 円錐の中で、この角の内側は縁による減り無し（Unity の Inner Spot Angle・Bevy の `inner_angle` と同じ。全体の角で書くのは今の `fovY` にそろえるため）。
  - `fovY` 以上の値は `fovY` に、0 未満と NaN は 0 に直す（`Scene3d.spotConeOf(spot): { outerCos, innerCos }` に一本化）。
  - 内と外が同じ cos になる時は、smoothstep の 0 割りを避けるため内側の cos に 1e-6 を足す。
- **作る関数**: `Scene3d.spotLight(position, target, fovY): SpotLight`（白・intensity 1・range 10・影なし・`innerFovY = None`）。
  早見表と doc の例はこの形で書く: `{ color = .., intensity = .., innerFovY = Some(..) | Scene3d.spotLight(p, t, fov) }`。
- **既定で絵が変わらない**: `None` は今と同じ式。GL の uniform（`uSpotCone[i].y`）に入れる値が同じ。
- **GL**: `spotArrays` が `spotConeOf` を読む。**CPU**: `compileLights` が同じ物を読む。頭のコメントの `cone` の行（SoftRaster3d.flix:11）を直す。
  - 今は `spotInnerRatio()` が Render3d（:215）と SoftRaster3d（:52・pub）の 2 か所にある。`Scene3d.spotInnerRatio()` 1 つにまとめ、`spotConeOf` だけが読む。SoftRaster3d の方は消す（使う所は同じファイルの `compileLights` だけで、`spotConeOf` に置き換わる）。
- **鍵**: `putSpotLight` に `innerFovY` を足す。None は何も書かない（今の鍵のまま）、Some は印と値。
- **gl-parity**: B 段階 `spotSoftEdge3d`。床へ向けたスポット 2 本で、左は `innerFovY = Some(fovY × 0.3)`（縁が広くぼける）、右は `None`。上限は既存の `spotShadow` と同じ 300 から始め、1 回流して決める。
- **テスト**: `spotConeOf` の None・Some・fovY を超える値・負・NaN。CPU で「内側の角の中は cone = 1」「外側の角の外は 0」。
- **移行メモ**: `SpotLight` を字で全部の欄を書いた所（night_apartment `StageView.flashlight`・fps3d_lab `RoomView`・engine のテストと bench）は `innerFovY = None` を足すか、`Scene3d.spotLight` に替える。
- **早見表**: 「懐中電灯（縁のぼけたスポット）を目から照らす | `Scene3d.spotLight(p, t, fov)` に `innerFovY = Some(..)`（縁を広くぼかす）を `spotLights` へ（点光源で代わりにしない） |」
- **お題** `spot-soft-edge`:
  - prompt「懐中電灯の光の輪の縁を柔らかくしたい」
  - expect `innerFovY`
  - avoid `pointLights[^\n]*lantern|lantern[^\n]*PointLight`（弱いので avoid は入れないかもしれない。1 回流して決める）

### 3.2 マウスを閉じ込めて相対の動きを受け取る（段 1）

- **engine の効果**（`GameEngine.Game`）に 2 つの op を足す:
  - `setMouseCaptured(Bool)`: 真で `GLFW_CURSOR_DISABLED`。`glfwRawMouseMotionSupported()` なら `GLFW_RAW_MOUSE_MOTION` も入れる。偽で `GLFW_CURSOR_NORMAL`（`setCursorVisible` の宣言を当て直す）
  - `consumeMouseDelta(): Vec2.Vec2`: 前に読んだ時からの動いた量（design px・小数のまま）。`glfwGetCursorPos` の差を、`getMousePosition` と同じ倍率で design px に直す
  - 閉じ込めを切り替えたコマと、窓がフォーカスを取り戻したコマは、基準の位置を取り直して 0 を返す（`glfwSetWindowFocusCallback`）。取り直さないと、跳んだ量が一度に入って視点が回る
  - op を処理する所は 3 つ: `LwjglLayer`・`GlOffscreen`（0 を返す・何もしない）・`engine_world/test/TestPassPlan`。op の handler は refactor の索引に出ないので、実装の時に grep で数え直す
- **窓のフォーカス**: `isWindowFocused(): Bool` の op（GLFW の focus のコールバックで持つ）。
- **App**:
  - `App.Frame` に `mouseDelta = Vec2.Vec2` と `windowFocused = Bool` の欄。`Frame` を字で組むのは `App.frameOf` と `Flow` の中だけ（grep で確かめた）なので、ゲームは止まらない
  - `App.withMouseCapture(f: w -> Bool)`: 毎フレーム World から「閉じ込めたいか」を宣言する（`withCursor` と同じ作法。系の中で op を呼ばない）。App は宣言が変わったコマだけ当てる
  - F8 で止めている間は放し、再開した拍に当て直す（`CursorLook` と同じ流れ。`HaltLook` に閉じ込めの欄を足す）
  - フォーカスが外れたら GLFW が放す。戻ったら GLFW が閉じ込め直すので、App は触らない
  - 名前は Godot の `MOUSE_MODE_CAPTURED` / Bevy の `CursorGrabMode::Locked` の意味で `capture` にそろえる
  - **`App.CursorSpec` に欄を足さない**（ゲームが字で書いている）
- **閉じ込めている間の `frame#cursor`**: GLFW の仮の位置は窓の外へ流れていくので、App は閉じ込めた時の位置で `cursor` を止め、`mouseMoved` は偽にする（UI のホバーと `mouseMoved` を読む系を狂わせない）。動きは `mouseDelta` だけに出る。放した時、GLFW は窓の真ん中にカーソルを戻す（doc に書く）。
- **headless と台本**: `PropertyTest.frameOf` は sample の cursor の差を `mouseDelta` に入れる（MoveMouse の台本で視点が回る）。CPU の描き出しは 0。
- **鍵**: 触らない。
- **Studio**: Studio の中で走らせる時も同じ（窓は GLFW の窓）。Studio の「止める」は F8 と同じ道を通るので放される。実装の時に Studio で 1 回触って確かめる（§10 の Q5）。
- **テスト**: `App` の宣言の当て方（変わったコマだけ・F8 で放す・再開で当て直す）を純粋な関数（`CursorLook` の隣）でテストする。`PropertyTest.frameOf` の差。
- **文書**: `docs/modules/input.md` に「一人称の視点（マウスを閉じ込める）」の節（Esc で放す慣習・フォーカスを失った時・感度は Doc へ）。
- **早見表**: 「一人称でマウスで視点を回す（カーソルを窓に閉じ込める） | `App.withMouseCapture(w -> ..)` + `frame#mouseDelta`（design px）で yaw・pitch を回す。Esc で放す（ドラッグで代わりにしない） |」
- **お題** `mouse-look-capture`:
  - prompt「一人称の 3D の部屋で、マウスを動かすと視点が回るようにしたい（FPS のように）」
  - expect `withMouseCapture` ／ `mouseDelta`
  - avoid `mouseDown[^\n]*cursor#x\s*-`（ドラッグの差で回す形）

### 3.13 GPU の時間を測る口（段 1）

- **GL**: `GL_TIMESTAMP` の `glQueryCounter` をコマの始めと、各 Pass の境と、コマの終わりに打つ。
  - query は 3 コマぶんの輪で持ち、`GL_QUERY_RESULT_AVAILABLE` が真の物だけを読む（GPU を待たない。1〜2 コマ遅れの値）
  - `GL_TIME_ELAPSED` の入れ子は GL で許されないので、timestamp の差で出す
  - query を作れない環境（拡張が無い）では `None`
- **型**: `FrameDiagnostics.Diagnostics` に 3 つの欄を足す。`FrameDiagnostics.empty()` も直す。`Diagnostics` を字で組むのは render_gl の中だけ（ゲームは組まない）
  - `gpuNs = Option[Int64]`（コマ全体）
  - `gpuPasses = List[(String, Int64)]`（Pass の名前ごと。画面へ写す最後の段は `"screen"`）
  - `scene3dCounts = { instances = Int32, drawn = Int32, drawCalls = Int32 }`（段 2 のカリングで drawn が減るのを見る。段 1 では instances = drawn）
- **ゲームに見せる口**:
  - `App.withDiagnostics()` で集め始め（中で `GameEngine.Game.setDiagnosticsEnabled(true)` を呼ぶ。今これを呼ぶのはヒッチの見張りだけ・App.flix:1379）、`App.Frame` に `diagnostics = Option[FrameDiagnostics.Diagnostics]`（前のコマの値）
  - App のヒッチの記録も同じ値を読むので、`consumeDiagnostics` は App が 1 コマに 1 回だけ呼んで両方へ配る（今は hitchRow が呼んでいる。2 回呼ぶと片方が空になる）
- **表示の部品**: `FrameDiagnostics.summaryLines(d): List[String]`（純粋。ms で丸めた数行）。描くのはゲームの字の部品で。Godot の Performance monitor と同じく、出す所は決めない。
- **CPU と headless**: `gpuNs = None`・`gpuPasses = Nil`。gl-parity は無関係（絵を変えない）。
- **テスト**: query の輪の読み方（使える物だけ読む・3 コマ遅れまで）を、GL を呼ばない純粋な部分に切り出してテストする。`summaryLines` の字。
- **文書**: `docs/performance.md` の「測る」の節に 1 段落（`FLIX_GE_FRAME_STATS=1` の println との違い: こちらはゲームの画面に出せる・GPU を含む）。
- **早見表**: 「GPU と CPU の 1 コマの時間を debug 表示する | `App.withDiagnostics()` → `frame#diagnostics` → `FrameDiagnostics.summaryLines`（自前で nanoTime を測らない） |」
- **お題** `gpu-time-overlay`:
  - prompt「F3 で GPU の時間と CPU の時間を画面の隅に出したい」
  - expect `withDiagnostics` ／ `summaryLines|gpuNs`

### 3.1 glTF のノードの名前と位置（段 2）

- **型**（`Model3d` に足す）:
  ```
  pub type alias ModelNode = { name = String, parent = Option[Int32], local = Mat4.Mat4, world = Mat4.Mat4,
                               localBounds = Option[{ min = Vec3.Vec3, max = Vec3.Vec3 }], parts = List[Int32] }
  Model3d に nodes = List[ModelNode]・ModelPart に node = Option[Int32]
  ```
  - `name`: glTF の `name`（無ければ `""`）
  - `local` / `world`: engine の座標（S·M·S の写し。今の `mirrorMat4` と同じ）
  - `localBounds`: mesh を持つノードの、焼き込む前の形の座標の min/max（POSITION の accessor の `min`/`max`、無ければ頂点から計算）。x の反転で min と max が入れ替わるので、反転した後で計算し直す
  - `parts`: そのノードから出た `parts` の番号
  - **mesh の無いノード（empty・ライト・カメラ）も入れる**（印の点。fps3d_lab の芯の先・吊り元）。
  - スキンのジョイントのノードも入る。`world` はバインドの姿勢の時の行列（アニメーションでは動かない。doc に書く）。
- **部品の形は今のまま焼き込む**（絵と鍵を変えない）。局所の形が要る使い方（回す扉）は、`world` の逆行列を掛けて戻す関数を出す: `Model3d.partLocalToNode(model, partIndex): Option[Mat4]`。
  - 焼き込みに使った行列の逆行列を返す。ジョイントに付いた硬い部品（`bindWorlds × 局所の鎖` で焼いた物）は、ノードの world と焼いた行列が違うので None（doc に書く）。逆行列が無い時も None。
  - 回す扉は `world × R × world⁻¹` を置いた物の行列にする（今の `Doors.transformOf` の蝶番まわりの回転と同じ形になる）。
- **mesh の無い glb**: 今の `buildModel` は mesh を持つノードが無いと Err を返す（Gltf.flix:557）。空の parts が `meshOfParts` を通るかも実装の最初に確かめる。印の点だけの glb（empty だけ）も読めるよう、mesh が無ければ頂点 0 の形と空の parts で Ok にする（`fromGlb` のテストの「メッシュが無いと Err」は直す・移行メモ）。
- **引く関数**（`Model3d`）:
  - `findNode(name, model): Option[ModelNode]`（同じ名前が複数あれば並びの前。glTF は名前の重なりを許すので doc に書く）。1 回ごとに並びを見るので、たくさん引く時は下の `nodesByName` を使う（234 個の `COL_*` を 1 つずつ `findNode` すると二乗）
  - `nodesByName(model): Map[String, ModelNode]`（同じ名前は並びの前）
  - `nodesWithPrefix(prefix, model): List[ModelNode]`（`COL_` のような書き出しの名前の決まりで集める）
  - `partsOfNode(node, model): List[ModelPart]`
  - `nodeOrigin(node): Vec3`（world の平行移動の列）
  - 名前は Godot の `find_child`・Unity の `Transform.Find` の意味にそろえ、`get*` は使わない（探すのは失敗しうる）
- **読む所**: `Gltf.buildModel` で全部のノードを 1 巡して world を出す（今は mesh のノードごとに `chainOf` で根まで辿るので、ノードが n 個・深さ d で n·d。1 巡で親から順に掛ける形にして二乗を避ける）。`fromGlb`・`fromGlbTextured` の両方。
  - 骨の道（`nodeParts` の `Rigid` / `Skinned`・`bindWorlds`）は今の計算のまま残し、ノードの一覧は別に 1 巡で作る（骨つきの glb の部品の頂点を 1 bit も変えないため。1 巡化を骨の道へ広げるのは別の作業）。
- **鍵**: 部品の形と材質は今と同じなので、描き出しの鍵は変わらない。`nodes` は鍵に入れない（絵に出ない）。
- **extras**（Blender のカスタムプロパティ）は v1 では読まない（§7。調べる文言は Doc に置く方が Studio で触れる）。
- **移行メモ**: `Model3d` と `ModelPart` を字で全部の欄を書いた所（テストだけのはず。実装の最初に grep で数える）は `nodes = Nil` / `node = None` を足す。
- **テスト**（テストの中で組む小さな glb。`TestGltf` の作り）:
  - 名前・親・局所と world の行列（2 段の親子で、親の回転が子に掛かる）
  - x の反転（glTF の +X の点が engine の −X に来る）
  - `localBounds` の min/max が反転の後でも min ≦ max
  - empty のノード・empty だけの glb が Ok
  - `parts` の番号
  - `partLocalToNode` がジョイントに付いた部品で None
  - `nodesByName` と `findNode` が同じ答え
  - 同じ名前の 2 つで並びの前
  - 部品の頂点と `contentHash` が今と同じ（固定値）
- **早見表**: 「Blender で名前を付けた物（扉・調べる物・当たり判定の箱・印の点）を glb から名前で引く | `Model3d.findNode(name, model)` / `nodesWithPrefix("COL_", model)` → `node#world`・`node#localBounds`（位置や大きさで探さない） |」
- **お題** `gltf-node-by-name`:
  - prompt「Blender で door_201 という名前を付けた扉を、glb の中から見つけて蝶番のまわりに回したい」
  - expect `findNode|nodesWithPrefix` ／ `#world|nodeOrigin`

### 3.8 glb の emissive の絵・材質の情報・spec 名（段 2）

- **読む物**:
  - `emissiveTexture`（texCoord 0）
  - `emissiveFactor`（既定 (0,0,0)。glTF の決まりでは絵があっても factor が 0 なら光らない。Blender の書き出しは絵がある時 (1,1,1) を書く）
  - `KHR_materials_emissive_strength`（既定 1）
  - 絵の上限は `TextureLimits.baseColor` を使う（同じ色の絵。`TextureLimits` に欄を足すと night_apartment が字で書いた所が止まるので足さない）
  - `usedImages` に emissive を足し、その WhyNot（Gltf.flix:109「emissive を decode しない」）を「metallicRoughness・occlusion は decode しない」に直す
- **材質の作り方**（今の `Gltf.materialOf` は baseColorTexture がある時しか材質を作らない・Gltf.flix:144-160。4 通りに広げる）:

  | baseColorTexture | emissive | 材質 |
  |---|---|---|
  | 有り | 無し（factor が全部 0） | 今と同じ `texturedMaterial`（spec 名も今の `scene3d:textured:<filter>` のまま） |
  | 有り | 有り | `texturedMaterial` + `withEmission` |
  | 無し | 有り | 頂点の色の材質（`Field.VertexColor` の Out・baseColorFactor は今どおり頂点の色）+ `withEmission`。fps3d_lab の `flame.glb`（emissive だけの材質）が光る |
  | 無し | 無し | 今と同じ None（頂点の色で描く） |

  - emission の式: emissiveTexture を**指していない**材質は `Solid(factor × strength)`。指していて読めた材質は `Tex(emissive).c × factor.c × strength`（材質の wrap・emissive の絵の sampler の filter）。
  - TEXCOORD_0 の有無は部品ごとで、材質は材質の番号ごとに 1 回作る（Gltf.flix:98）。emission を付けるかは、部品へ材質を割り当てる所（:99-102 の zip の中）で、その部品の uv の有無を見て決める。uv の無い部品は emission を外した材質を使い、知らせは材質ごとに 1 回
  - **指しているのに読めない**時（texCoord ≠ 0・decode の失敗・外の uri・形に TEXCOORD_0 が無い）は emission を付けず、`Log.warnAllThen` の lines に 1 行足す。Solid へ倒すと、Blender の書き出しの factor (1,1,1) × 強さで物全体が真っ白に光る。
  - factor が全部 0 なら emission を付けない（絵を decode もしない）。
- **spec 名**: emission を付けた材質だけ、木の形を変える物を全部字に入れる: `gltf:<base>:<filter>:<em>`。
  - `<base>` = `tex`（絵）/ `vc`（頂点の色）、`<filter>` = baseColor の絵の読み方（`vc` の時は無し）、`<em>` = `et<filter>(<r>,<g>,<b>)`（emissive の絵の読み方 × 定数。baseColor と違う sampler でも名前が分かれる）/ `ec(<r>,<g>,<b>)`（定数だけ）。同じ factor で「絵 × factor」と「factor だけ」が並んでも名前が分かれる（木の形が違うのに同じ名前だと、毎コマ組み直しになる・Render3d.flix:981 の知らせ）。
  - 絵の名前は入れない（`ShaderGen.eqMaterial` の `namePairing` が絵の名前の違いを同じと扱うので、同じプログラムを使い回せる）。
  - **emission の無い材質の spec 名は今のまま**。描き出しの鍵は spec の JSON を書く（`putMaterial`）ので、名前を替えると glb を使う全部の場面のキャッシュが描き直しになる。替えない。
- **絵を読まない `fromGlb`**: emission は付けない（絵が無い）。`gltfMaterial` は入れ、絵の名前の欄は None にする。
- **spec 名を替える口**: `Scene3d.withSpecName(name, m)`（材質の spec の名前だけを替える）。ゲームが emission や木を差し替えた材質は、これで名前を替える（替えないと、engine が付けた名前のまま木だけが変わり、毎コマ組み直しになる・`+em` は有無しか見ない）。`withEmission` の doc にも書く。同じ名前を違う木の 2 つの材質に付けると、やはり毎コマ組み直しになるので、木ごとに名前を分ける（部品ごとに mask が違うなら部品ごとの名前）と doc に書く。
- **プログラムの鍵の穴を塞ぐ**: `Render3d.materialKey` に `+em`（emission の有無）を足す。
  - 同じ spec 名で emission の有る材質と無い材質が混ざっても、別のプログラムになる（emission の有無だけが違う材質なら名前を替えなくてよくなる。木を差し替えたら `withSpecName`）。
  - 有無だけを見る（Shade の木の比べは今の `eqMaterial` に任せる）。毎コマ払う手間は `Option.isSome` 1 回。
  - CPU は材質を束ねないので触らない。
- **材質の情報を部品に残す**: `ModelPart` に `gltfMaterial = Option[GltfMaterial]` を足す。
  ```
  pub type alias GltfMaterial = { name = String, alphaMode = AlphaMode, alphaCutoff = Float64, doubleSided = Bool,
                                  baseColorTexture = Option[String], normalTexture = Option[String],
                                  emissiveTexture = Option[String], emissive = { r = Float64, g = Float64, b = Float64 } }
  pub enum AlphaMode with Eq, ToString { case Opaque  case Mask  case Blend }
  ```
  - 絵の名前は `Texture3d.name`。`emissive` は factor × strength。
  - ゲームが自前の材質を組み直す時（night_apartment の点滅の mask）に、絵の名前を Shade の木から掘り出さずに済む。
  - `alphaMode` と `doubleSided` は段 2 では**記録だけ**で、描き方は変えない。段 4 の 9 で使う（今 BLEND の glb の絵を段 2 で変えないため）。
- **既定で絵が変わる所**: emissive つきの glb を `loadTextured` で読むゲームは、その物が光り始める（glTF の決まりどおり・Godot も Unity も読み込みで光る）。移行メモに書く。
  - 止めたい時は `{ emission = None | Scene3d.materialFieldsOf(m) }` の形が無いので、`Scene3d.withoutEmission(m)` を足す。
  - 実装の最初に workspace の glb で emissive を持つ物を数える（night_apartment の `bld_props`・`site_props` は持つ。fps3d_lab は未確認）。
- **ヒープ**: emissive の絵も decode するので、0.75.0 の D7 で減らした分が一部戻る。上限は baseColor と同じで絞れる。
- **GL / CPU**: 新しい描き方は無い（emission は今もある）。
- **鍵**: emission はもう `putMaterial` に入っている（Shade の木）。spec 名を替えるのは emission の付いた材質だけなので、emissive の無い glb の場面の鍵は今のまま。emissive の有る glb は絵が変わるので鍵も変わってよい。
- **テスト**:
  - emissive の絵つきの小さな glb で、材質に emission が付き、`model#textures` に絵が入る
  - baseColorTexture の無い emissive だけの材質に、頂点の色の材質と emission が付く
  - factor 0 で付かない・strength が掛かる・絵の無い emissive は Solid
  - spec 名が factor と「絵 × 定数 / 定数だけ」で変わり、絵の名前では変わらない。emission の無い材質の spec 名が今と同じ
  - emissive の絵を指しているのに読めない（texCoord 1・TEXCOORD_0 の無い形）時に emission が付かず、知らせが 1 行
  - emissive の絵の sampler が Nearest で baseColor が Linear の時、名前が分かれる
  - emissive の無い glb の場面の描き出しの鍵が今の固定値と同じ
  - `GltfMaterial` の欄（alphaMode の 3 通り・doubleSided・cutoff の既定 0.5）
  - `materialKey` に `+em`
- **gl-parity**: 既存の `gltfTextured` の差の数が同じ（emissive の無い glb の絵が変わらないこと）。新しい行 `gltfEmissive3d`（emissive の絵つきの板と、emissive だけの材質の板）を B 段階に足す。
- **早見表**: 既存の「3D の家具・壁に木目や石の絵」の行に「・glb の emissive（`KHR_materials_emissive_strength` つき）も読む・材質の情報は `part#gltfMaterial`」を足す。
- **お題** `gltf-emissive`:
  - prompt「Blender で光る看板（emission の絵）を付けた glb を置いたら光らせたい」
  - expect `loadTextured`
  - avoid `withEmission\([^)]*decode`（絵を別に読んで自前で付ける形）

### 3.5 フラスタムカリング（段 2）

- **判定**:
  - 置いた物の world の境界 = `Mesh3d.bounds` の 8 つの角を world 行列で写した物
  - 6 つの面（射影 × view の行列から取る）のどれか 1 つの外に 8 つの角が全部あれば描かない
  - 外れる側に倒した判定（迷ったら描く）なので、描かない物は画素を 1 つも出さない物だけ → **絵は 1 bit も変わらない**
  - 面の取り出しの丸めに備えて、面の距離に 1e-4 の余裕を足す
- **対象外**:
  - 骨つき（`skinningOf` が Some）は Pose で形が境界の外へ出うるので間引かない
  - 頂点の無い形
  - ビルボードは外接球で間引く（半径は `size × max(|anchor|, |1 − anchor|)` の長さ。anchor が 0〜1 の外でも覆う）
- **影の地図**: スポットの影を描く段は、`Scene3d.shadowCamera` の視錐台で別に間引く（目に見えない物も影は落とす）。
- **Output.Depth**: 色と同じ判定。
- **シェーダーと絵を先に作る**（fps3d_lab の `warmPlan` を悪化させない）:
  - `splitByMaterial` の材質の組み立て（初めての材質の GLSL の組み立て）は、**間引く前の全部の物**で行う。間引くのは描く段（`drawInstancesLit` / `drawMaterials`）の手前
  - 間引いた物が読む絵も「今のコマで使う絵」として数える（`textureNamesOf` の全部 = 材質の絵・法線マップ・lightmap。場面の絵は `sweepTextures3d`、全体の登録の絵の段つきの写しは `mipCopiesRef`（Render3d.flix:942-945）の両方）。数えないと、振り向くたびに絵を上げ直して止まる
  - **形（頂点のバッファ）も同じ**: `lastUsed` を進めるのは `drawMesh` の中の `meshEntry` だけ（Render3d.flix:1071・1145）で、`endFrame` は 128 コマ使わなかった形を捨てる（:1265-1270）。間引いた物も `meshEntry` で `lastUsed` だけを進める（上げていない形は上げる。描かない）。進めないと振り向くたびに頂点を上げ直し、`noteUploadStreak` の知らせも鳴る
- **描く順を変えない**（1 bit も変えないための決まり）: `drawMaterials` の `List.sortBy`（:707）は安定ソートではないので、並べる前に物を減らすと、同じプログラムの物どうしの順が入れ替わりうる（同じ平面に重なった面の z-fighting の画素が変わる）。
  **間引く前の全部の物で並べ（今と同じ並び）、`forEach` の中で間引いた物を飛ばす**。頂点の色の物（`drawInstancesLit`）も同じく、並びを作った後で飛ばす。
- **重さ**: 角 8 つ × 面 6 つで約 0.3 µs。今の 1 物あたり約 7 µs の仕事を、外の物では払わなくなる。
- **pub の口**（ゲームが光や羽虫を自分で間引く・数を出す）:
  - `Camera3d.frustum(c, aspect): Frustum`（閉じた型）
  - `Frustum.intersectsBox(f, min, max, world): Bool`
  - `Frustum.intersectsSphere(f, center, radius): Bool`
  - `Scene3d.worldBoundsOf(i): Option[{ min, max }]`（9 の並べ替えも使う。骨つきは None）
- **CPU**: `instanceTris` の手前で同じ判定。near の面で切る今の処理は残す。
- **数**: 13 の `scene3dCounts.drawn` に描いた数を入れる。
- **鍵**: 触らない（場面の中身は同じ。間引きは描き手の中の話）。
- **gl-parity**: 既存の 3D の B 段階の行の差の数が変わらない。新しい行 `cullOffscreen3d`（画面の外に 200 個の箱・中に 1 個）は差の数が中の 1 個の行と同じ。
  間引いた数（`drawn`）の確かめは gl-parity の道具（GL と CPU の絵を比べる作り・bench/gl_parity/src/Main.flix）には無いので、行に「GL の診断の数の期待値」を持たせる小さな改修を足す（工数 0.5 日を段 2 に入れた）。
- **テスト**:
  - 面の取り出し（目の前の点が中・後ろが外・横の外）
  - 境界をまたぐ箱は中
  - 骨つきは常に中
  - 間引いても間引かなくても CPU の絵が同じ（場面を 2 回描いて画素を比べる。内部の切り替えを test からだけ渡す）
  - GL（`GlOffscreen`）: 間引いた物の形と絵が 200 コマ後も GPU に残っている・同じ平面に重なった 2 枚の面の場面で、間引く物を足しても絵が同じ
- **文書**: `docs/performance.md` の 3D の節。間引くのは視錐台の外だけで、壁の向こう（night_apartment の部屋ごとの判定）は間引かない、と書く。
- **早見表とお題**: 足さない（ゲームが何も書かなくても効く）。pub の `Frustum` は doc だけ。

### 3.3 3D の当たり判定と歩き（段 3）

night_apartment の `Collider`（向きのある箱 × 縦に並べた球・下へのレイで床）と `Walker`（細かく区切って押し出す・段差・坂・落ちる）を材料にする。実機で歩き回って直した決まりを、そのまま engine へ写す。

- **形**（`engine/src/scene3d/CollisionShape3d.flix`・純粋。2D の `CollisionShape2D`（形の enum・CollisionShape2D.flix:6）と同じく、形の enum にする）:
  - `pub enum CollisionShape3d { case BoxShape3d(Box3d)  case SphereShape3d({ center, radius })  case CapsuleShape3d({ feet, radius, height }) }`。4 のレイの的もこの enum を使う（別の enum を作らない）
  - `Box3d = { center, ax, ay, az, half }`（向きのある箱）
  - 作る関数:
    - `box3d(center, half)`（軸にそろう）
    - `boxOfNode(node: Model3d.ModelNode): Option[Box3d]`（`localBounds` × `world`。軸に倍率が入っても正しく、せん断がある時は外接箱に倒す）
    - `boxOfMesh(mesh, world)`（AABB を world で写す）
  - `transformBox(m, b)`（回る扉）
  - 問い:
    - `closestPoint(b, p)`
    - `penetration(b, capsuleAt): Float64`（食い込みの深さ。扉が体を押し込まない判定に使う）
    - `pushOutHorizontal(b, sphereCenter, r): Option[Vec2]`（night_apartment の `pushOut` の式。WhyNot も写す）
- **静的な箱の集まり**: `CollisionWorld3d`（閉じた型）。
  - `build(boxes, cellSize)` で xz の格子に入れ、`boxesNear(world, x, z, reach)` で周りのマスの箱だけ返す（大きい箱は重なる全部のマスに入れ、返す時に重複を除き、**元の並びの番号で並べ直して返す**）
  - 押し出しは箱を並びの順に 1 つずつ足し込む（Collider.flix:227-243）ので、角で 2 枚に挟まれた時は順で答えが変わる。`moveAndSlide` は「静的な箱（`build` に渡した並び）の後に moving」の順で押し出す（night_apartment の `List.append(env#boxes, Doors.leafBoxes(..))` と同じ）
  - night_apartment の `Collider.near` は毎コマ全部の箱を見る（234 個で今は軽いが、N はゲームが決める）
  - 動く箱（扉）は毎コマ `List[Box3d]` で別に渡す
- **歩く体**（`engine_world/src/CharacterBody3d.flix`。Godot の `CharacterBody3D.move_and_slide`・Unity の `CharacterController.Move` に当たる）:
  ```
  pub type alias Settings = { radius = Float64, height = Float64, stepHeight = Float64, floorMaxAngleDeg = Float64,
                              snapLength = Float64, gravity = Float64, maxSubstep = Float64 }
  pub def settings(radius, height): Settings   // stepHeight 0.3・floorMaxAngleDeg 45（Godot の既定）・snapLength 0.45・gravity 9.8・maxSubstep = min(0.05, radius/2)
  pub enum Footing { case OnFloor(Floor)  case Airborne(Float64) }   // Floor = { y, normal, sloped = Bool }・Airborne の値は縦の速さ（上が正）
  // sloped = 床の箱のどの軸も |y| < 0.98（約 11.5°。night_apartment の isTilted と同じしきい値・足音の種類が一致する）
  pub type alias Body = { feet = Vec3.Vec3, footing = Footing }
  pub def moveAndSlide(world, moving: List[Box3d], s: Settings, motion: Vec2.Vec2, dt: Float64, b: Body): Body
  pub def snapToFloor(world, moving, s, b): Body           // 足元を下の床に合わせる（始まり・置き直し。Godot の apply_floor_snap）
  pub def overlapDepth(world, moving, s, b): Float64       // 食い込みの一番深い所
  ```
  - `motion` は水平の速さ（m/秒）。向き（yaw・pitch）と足音と頭の上下はゲームが持つ（体の物理だけを engine へ）
  - **決まり**（night_apartment のまま）:
    - 区切った 1 歩ごとに、歩ける範囲 → 押し出し → 床の順
    - 押し出しの後の方が深く食い込むなら水平に動かない
    - 立っている間は段の高さの中で床に吸い付く（階段を下りても浮かない）
    - 床が消えたら落ちる。落ちている間は下の床で止まる
    - 床は体の真ん中の真下で決め、無い時だけ周りの 4 点で探す（WhyNot: 5 点の一番高い所を取ると斜めの手すりに乗り上げる）
  - **坂**: 床の面の法線と真上の角が `floorMaxAngleDeg` 以下なら床、超えたら壁（乗らずに押し出す）。
    night_apartment は傾いた箱を全部床として扱う（`isTilted` は足音の種類にしか使っていない・Collider.flix:194-210）。外階段の段板は約 43°（ノードの rotation から計算）。
    デモは `floorMaxAngleDeg = 90` で、傾いた箱を全部床として扱う今の決まりにそろえる。新しいゲームの既定は 45°
  - **カプセルの近似**: 縦に並べた球（間は半径以下）で近似する（night_apartment は間を直径以下にしていた。engine は角の当たりを細かくするため半径以下）。正確な線分 × 箱の最近点は §7
  - 地面の平面（側溝で落ちない `groundY`）と歩ける範囲（bounds）はゲームの事情なので engine に入れない。ゲームは平面を大きな薄い箱、範囲を外側の 4 枚の厚い箱として world に入れる（範囲の箱は頭より高くする。上面が「足元 + stepHeight」より低いと床として拾い、乗り上げる）
  - **範囲の端**: Walker は区切りごとに「範囲に収める → 押し出す」の順（Walker.flix:117-118 の WhyNot）。箱で表すと「押し出す」の 1 段になり、範囲の端の数 cm で止まり方が変わりうる。
    端で挟まれて抜けるのを、範囲の箱を厚く（1 m 以上）して防ぐ
- **CPU と GL**: 描き手は触らない。当たり判定の表示は night_apartment の `ColliderMesh` 相当を `CollisionShape3d.debugMesh(boxes, color): Mesh3d` として足す（`Mesh3d.fromPolygons` の線の箱。調べる時の表示に、どのゲームも同じ物を書くので）。
- **テスト**（期待値は式から導く。`/quality-assurance`）:
  - 箱の押し出し（横から・角で 2 枚・真上から）
  - 段差（stepHeight より低い箱は乗る・高い箱は壁）
  - 坂の角（44° は床・46° は壁）
  - 落ちる（重力で y が式どおり）
  - 速く走っても薄い壁を抜けない（maxSubstep）
  - 動かない時に位置が震えない
  - 格子の `boxesNear` が、全部の箱を距離で絞った物と**並びまで**同じ
  - 壁・薄い壁・手すり・階段・柱のある部屋をたくさんの向きと速さで歩き、どのコマでも食い込まず抜けない（night_apartment の `TestWalkProperty` と同じ性質。移す前と後の足元の一致は求めない）
- **文書**: `docs/modules/<3D の分野>.md` に「一人称で歩く」の節（体の寸法・坂の角・動く箱の渡し方・地面の平面は箱で）。`docs/glossary.md` に Box3d / CapsuleShape3d。
- **早見表**: 「3D の部屋を一人称で歩く（壁で止まる・段差を上る・坂・落ちる） | 箱は `CollisionShape3d.boxOfNode`（glb の `COL_*` のノード）→ `CollisionWorld3d.build` → 毎コマ `CharacterBody3d.moveAndSlide`（自前で押し出しを書かない） |」
- **お題** `walk-3d-collide`:
  - prompt「Blender で当たり判定の箱を置いた glb がある。この中を一人称で歩き、壁で止まり、階段を上れるようにしたい」
  - expect `moveAndSlide` ／ `boxOfNode|CollisionWorld3d`
  - avoid `pushOut|resolve\(boxes`（自前の押し出し。弱いので 1 回流して決める）

### 3.4 見ている物を調べるレイ（段 3）

- **型**（`engine/src/scene3d/Ray3d.flix`・Bevy の `Ray3d` と同じ形）:
  - `Ray3d = { origin, direction }`（direction は長さ 1 に直して持つ。閉じた型にして `ray3d(origin, toward)` から作る）
  - `RayHit = { distance, point, normal }`
- **カメラから**:
  - `Camera3d.forwardRay(c): Ray3d`（目から見ている向き）
  - `Camera3d.screenPointToRay(c, size, p): Ray3d`（描き物の中の px。Unity の `ScreenPointToRay`。`worldToScreen` の逆）
- **交わり**:
  - `Ray3d.hitBox(ray, maxDistance, Box3d): Option[RayHit]`（箱の向きの座標で slab の判定。night_apartment の `hitBelow` を一般にした物）
  - `hitSphere`
  - `hitTriangle`（Möller–Trumbore・表裏とも）
  - `hitMesh(ray, maxDistance, mesh, world)`（境界の箱で先に外し、当たる物だけ三角形を全部見る。調べる物 1 つに 1 回の想定）
  - `hitInstance(ray, maxDistance, Instance3d)`（骨つきは境界だけで判定し、doc に書く）
- **名前つきの物から一番近い物**:
  ```
  pub enum RayTarget { case Shape(CollisionShape3d.CollisionShape3d)  case Mesh(Mesh3d.Mesh3d, Mat4.Mat4) }
  pub def pickNearest(ray: Ray3d, maxDistance: Float64, targets: List[(a, RayTarget)]): Option[(a, RayHit)]
  ```
  - `a` はゲームが決める鍵（調べる物の enum・ノードの名前）
  - 遮る物（壁）も同じ並びに入れ、`a` を「壁」の case にすれば、壁の向こうは選ばれない（物理の層の仕組みを足さずに済む）
  - 同じ距離なら並びの前
- **CPU / GL**: 触らない。
- **テスト**:
  - 箱（正面・斜め・中から・平行で外れる・maxDistance の外）
  - 三角形（表・裏・縁）
  - 回した箱
  - `screenPointToRay` の真ん中が `forwardRay` と同じ
  - `worldToScreen(p)` の点のレイが p を通る
  - `pickNearest` で手前の壁が奥の物を隠す
- **文書**: 3D の分野の doc に「見ている物を調べる」の節（クロスヘアの考え方・壁を遮る物に入れる・調べた文言は Doc へ）。
- **早見表**: 「一人称で見ている物を調べる（照準の先の物の名前・E で調べる） | `Camera3d.forwardRay(cam)` → `Ray3d.pickNearest(ray, 距離, [(鍵, RayTarget.Shape(BoxShape3d(b)))…])`（b は `CollisionShape3d.boxOfNode(n)`）（壁も入れて遮る。距離と向きの内積で代わりにしない） |」
- **お題** `inspect-ray`:
  - prompt「一人称の部屋で、画面の真ん中に見えている物の名前を出し、E を押したらその物の説明を出したい」
  - expect `forwardRay|screenPointToRay` ／ `pickNearest|hitBox`

### 3.11 空のグラデーション（段 4）

- **型**:
  - `Sky3d`（閉じた型）を `Scene3dCmd` の新しい欄 `sky = Option[Sky3d]` に持つ
  - `Environment3d` には足さない。ゲームが `environment = { ambient = .., background = None }` と字で書いているので、欄を足すと止まる
  - `Scene3dCmd` は `{ .. | Scene3d.scene(..) }` の更新で書く決まり（doc にある）なので、欄を足しても止まらない。字で全部の欄を書いた所は実装の最初に grep で数える
  ```
  pub def gradientSky(zenith: Color, horizon: Color, ground: Color): Sky3d     // 曲がり 1・地平の幅 0
  pub def withSkyCurve(curve: Float64, s: Sky3d): Sky3d                       // 天頂へ向かう色の寄り方（Godot の sky_curve）
  ```
- **式**（画素ごと）:
  - d = 画素を通る目からのレイの向き（射影 × view の逆行列から）
  - d.y ≧ 0 なら `mix(horizon, zenith, pow(d.y, curve))`、d.y < 0 なら `mix(horizon, ground, pow(−d.y, curve))`
  - pitch と yaw と画角が全部合う（night_apartment が手で計算している地平の高さが要らなくなる）
- **かすみ**: 空にはかけない（距離が無限）。地平の色をかすみの色にそろえると継ぎ目が消える、と doc に書く。
- **background との関係**: `sky` が Some なら `environment.background` は使わない（両方 Some なら 1 回知らせる）。
- **Output.Depth**: 空は白（一番奥）。
- **GL**: `beginScene` の直後、深度を書かずに画面いっぱいの三角形 1 枚を描く。scissor の中だけ。Design の解像度の FBO でも同じ。
- **CPU**: `renderLayer` の `fill` を、画素の (x, y) から同じ式で求める関数にする。
- **既定**: None で今と同じ（beginScene の分岐が増えるだけ）。
- **鍵**: `putSceneCmd` のパターンに `sky` を足す。None は何も書かない、Some は印と 3 色と曲がり。
- **gl-parity**: B 段階 `skyGradient3d`（見下ろし 20° の場面で地平が画面の真ん中より上に来る）。
- **テスト**: 真上で zenith・真横で horizon・真下で ground・曲がり 2 の真ん中の値。CPU の画素で、地平の行が pitch から計算した行と同じ。
- **早見表**: 「3D の場面の背景を空のグラデーション（天頂・地平・地面）にする | `{ sky = Some(Scene3d.gradientSky(天頂, 地平, 地面)) \| Scene3d.scene(..) }`（2D の面を下に敷いて地平を手で計算しない） |」
- **お題** `sky-gradient-3d`:
  - prompt「3D の屋外の場面で、空を上は濃い藍・地平は明るい色のグラデーションにしたい」
  - expect `gradientSky`

### 3.9 半透明（段 4）

- **材質**: `Scene3d.withAlphaBlend(on, m)`。`MaterialFields` に `blend = Bool` を足す。
  - 材質は閉じた型で、`MaterialFields` は読むための型。字で組むゲームは無いはず → 実装の最初に grep で確かめる
  - `cutout` と両方真なら、α < 0.5 を捨ててから混ぜる
  - 混ぜ方は「上に重ねる」1 通り: 色は `src.a` と `1 − src.a`、α は 1 と `1 − src.a`（Pass の α が場面の重なりの元になるので、`glBlendFuncSeparate`）。加算の光（additive）は §7
- **表裏**: `Scene3d.withDoubleSided(on, m)` も足す（ガラスの板・網は裏から見ても見える）。`MaterialFields.doubleSided`。
  - GL は材質ごとに `GL_CULL_FACE` を切る。CPU は `screenTris` の cull をその物だけ止める
  - 裏の面の法線は光の計算で反転する（GL は `gl_FrontFacing`、CPU は巡りの向き）
- **glTF**:
  - `GltfMaterial.alphaMode = Blend` → `withAlphaBlend(true)`
  - `Mask` → `withCutout(true)`。`alphaCutoff` が 0.5 でなければ 1 回知らせる（v1 は 0.5 の固定）
  - **ここで BLEND・MASK の glb の絵が変わる**（移行メモ。workspace では night_apartment の `alpha_net`・`alpha_chainlink` だけ。ゲームは今 cutout を自分で当てている）
  - **`doubleSided` は既定で当てない**。workspace の glb 40 本は全部の材質が `doubleSided: true`（Blender の書き出しの既定。レビューで数えた）なので、当てると glb を読む全部のゲームで裏の面が描かれ、光の当たり方と重さが変わる。
    作者の意図の印にならないので、ゲームが `part#gltfMaterial` の `doubleSided` を見て、要る物（網・葉・ガラスの板）にだけ `withDoubleSided(true, ..)` を当てる。読み込みで当てる旗は §10 の Q10
- **描く順**（GL）:
  1. 不透明（今の順のまま）
  2. ビルボード（cutout で深度を書く）
  3. 半透明の物を world の境界の真ん中と目の距離で遠い順に並べて（同じ距離なら並びの前）、深度を読むが書かずに混ぜる
  - 半透明が 1 つも無い場面は今と同じ順 → 絵は変わらない
  - ビルボードを半透明より前に回すのは半透明がある時だけ
  - 1 つの物の中の三角形は並べ替えない（Unity・Godot と同じ。doc に書く）
- **影**: 半透明の物は影を落とさない（cutout を兼ねる物も落とさない。v1）。lightmap つきの半透明（ガラスに焼いた光）は使える。
- **CPU**: `renderLayer` の行ごとの処理に 2 つ目の段を足す。
  - 1 段目（今の処理）で不透明の深度と色を決める
  - 2 段目でその行にかかる半透明の三角形を、物の遠い順に塗る。不透明の深度より手前の画素だけを、塗るその場で光を計算して混ぜる
  - 半透明の三角形は不透明の勝者の選びに入れない
- **Output.Depth**: 半透明は深度を書かない（ピントの Pass はガラスの奥にピントが合う）。doc に書く。
- **鍵**: `putMaterial` のパターンに `blend`・`doubleSided` を足す。偽は何も書かない、真は印。
- **gl-parity**: B 段階 `glassPane3d`（色つきの板 2 枚が奥と手前で重なり、奥に不透明の箱）と `doubleSided3d`。
- **テスト**:
  - 混ぜの式（α 0.5 の赤を青の上に）
  - 並べ替え（遠い順・同じ距離は並びの前）
  - 半透明は深度を書かない（後ろの半透明も見える）
  - cutout と blend の両方
  - 裏の面の法線の反転
  - glTF の alphaMode の 3 通り
  - 半透明の無い場面の絵が今と同じ（CPU の固定値）
- **早見表**: 「3D の窓ガラス・網・水面（向こうが透ける物） | `Scene3d.withAlphaBlend(true, m)`（裏から見えるなら `withDoubleSided(true, ..)`）・glb の `alphaMode: BLEND` はそのまま読まれる（cutout で代わりにしない） |」
- **お題** `glass-3d`:
  - prompt「3D の部屋の窓に、向こうが少し透けて見える色つきのガラスを入れたい」
  - expect `withAlphaBlend|alphaMode`

### 3.10 細い物の欠けを抑える（MSAA）（段 4）

- **口**: `RenderTarget.Descriptor` に `samples = Int32` の欄（既定 1）と、それを書く `RenderTarget.withMsaa(samples, d)`（1・2・4・8。それ以外は近い下の値に直し、GPU の `GL_MAX_SAMPLES` で頭打ち）。`Descriptor` は doc で「`{ scale = 0.5 | RenderTarget.defaultDescriptor() }` の形で書く（欄を足してもゲームの字が止まらないように）」と決めてある開いたレコードなので、欄を足してよい（字で全部の欄を書いた所は実装の最初に grep で数え、あれば移行メモ）。
- **GL**:
  - samples > 1 の Pass は、色と深度がマルチサンプルの renderbuffer の FBO に描く
  - Pass を読む前（次の Pass の入力・画面へ写す時）に `glBlitFramebuffer` で今の色のテクスチャへ resolve する
  - Rgba16Float でも同じ（GL 3.3 で使える）。Design の解像度の 3D の FBO には掛けない（ドット絵と合わせる場面に縁のならしは要らない）
- **alpha to coverage**（10b）: samples > 1 の Pass で、cutout の材質は `discard` の代わりに `GL_SAMPLE_ALPHA_TO_COVERAGE` を使う（金網・葉の縁がなめらかになる）。
  - 深度の段（`Output.Depth`）と影の段は今の discard のまま
  - coverage に使った α がそのまま Pass の α に書かれると、場面を下地へ重ねる時（Design・background None）に縁が透ける。cutout の材質は出す α を 1 にし、coverage は `GL_SAMPLE_ALPHA_TO_ONE` と組にする（出す α を coverage にだけ使い、書く α は 1）
- **鍵**: 触らない。CPU はマルチサンプルしないので、CPU の絵は samples によらず同じ（描き出しの鍵は CPU の絵のキャッシュ）。
- **画面に直に描く時**（Pass を使わない 3D）: v1 はしない。窓のマルチサンプルは 2D の縁も変える（`GLFW_SAMPLES`）ので、別の口として後に回す（§7）。
- **CPU**: マルチサンプルしない（§10 の Q7 の推し）。CPU の絵は MSAA の無い絵のまま。FXAA の Pass は CPU でも効く。
- **gl-parity**: MSAA の行は CPU と比べない（GL どうしで、samples 1 と 4 の差が縁の画素だけに出ることを GL の側だけで確かめる行 `msaaEdges` を足す）。
- **既定**: samples 1 で今と同じ。
- **テスト**: samples の丸め。GL の FBO の作り（`GlOffscreen` の画面なしの GL で、縁の画素が中間の色になる）。
- **重さ**: 窓の画素の HDR の Pass で 4× は、メモリ（色と深度）が 4 倍・塗りがほぼ縁の分だけ増える。13 で測り、doc に数字を書く。
- **早見表**: 「3D の手すり・金網・電線のような細い物が欠ける・ちらつく | 場面の Pass を `RenderTarget.withMsaa(4, RenderTarget.windowDescriptor() \|> RenderTarget.withHdr)`（cutout の縁もなめらかになる）・それでも残る縁は `PostProcess.fxaaSpec` |」
- **お題** `msaa-thin-3d`:
  - prompt「3D の外階段の細い手すりが、歩くとちらちら欠けて見える」
  - expect `withMsaa`

### 3.6 色を線形の空間で計算する（段 5）

下書きは `plans/engine-round8-linear-color.md`（段 G の G1〜G6）。この計画では範囲を足し、順番を決める。詳しい設計は段 5 の始めに round8 を rev1 に書き直してレビューに回す。

- **round8 に足す物**（この計画の段 1〜4 で増えた物）:
  - 空の 3 色（`Sky3d`）は sRGB の値として受け取り、読む時に線形へ（`Color` の決まりと同じ）
  - glb の emissive の factor × strength（40 のような値）は glTF の決まりどおり線形の量。段 2 では「今の式のまま足す」ので明るすぎる。段 5 で線形の計算に入って正しくなる。移行メモで合わせ直しを知らせる
  - 半透明の混ぜは線形の Pass（Rgba16Float）の上で行う（混ぜの式は同じ。値の意味が変わる）
  - MSAA の resolve は線形の値で平均する（Rgba16Float の Pass なら自然にそうなる）
  - スポットの縁の smoothstep は式のまま（光の量に掛かるので、線形でも同じ見え方の意図）
  - lightmap: `Lightmap.colorSpace` を `Texture3d` の側へ移す。露出を `intensity` から `exposureStops` へ戻す（`docs/lightmap.md` の予告）
- **既定**: 3D を使う全部のゲームの絵が変わる。2D の絵は変えない（round8 の G4）。§10 の Q3 で、1 版だけ project.json `scene3dLinearColor: false` で戻せる口を残すかを聞く。
- **gl-parity**: round8 の G5 の 3 行に、`skyGradient3d`・`glassPane3d` の線形の版を足す（既存の 3D の行は全部撮り直し＝B 段階の上限の取り直し）。

---

## 4. 足す pub の口の一覧（名前の確かめ用）

| 段 | モジュール | 口 | そろえた先 |
|---|---|---|---|
| 1 | ProjectLoader / GameEngine | project.json `scene3dTextureBudgetCount`・`defaultScene3dTextureBudgetCount()` | 0.75.0 の MB のキー |
| 1 | Scene3d | `SpotLight.innerFovY`・`spotLight(p, t, fovY)`・`spotConeOf`・`spotInnerRatio`（Render3d と SoftRaster3d から移す） | Unity Inner Spot Angle・Bevy inner_angle |
| 1 | GameEngine.Game | `setMouseCaptured`・`consumeMouseDelta`・`isWindowFocused` | Godot MOUSE_MODE_CAPTURED |
| 1 | App | `withMouseCapture`・`Frame.mouseDelta`・`Frame.windowFocused`・`withDiagnostics`・`Frame.diagnostics` | `withCursor` の作法 |
| 1 | FrameDiagnostics | `gpuNs`・`gpuPasses`・`scene3dCounts`・`summaryLines` | Unity FrameTimingManager の gpuFrameTime |
| 2 | Model3d | `ModelNode`・`nodes`・`ModelPart.node`・`findNode`・`nodesByName`・`nodesWithPrefix`・`partsOfNode`・`nodeOrigin`・`partLocalToNode` | Godot find_child・Unity Transform.Find |
| 2 | Gltf / Model3d | `GltfMaterial`・`AlphaMode`・`ModelPart.gltfMaterial` | glTF の材質の欄名 |
| 2 | Scene3d | `withoutEmission`・`withSpecName`・`worldBoundsOf` | |
| 2 | Camera3d / Frustum | `frustum`・`intersectsBox`・`intersectsSphere` | Bevy Frustum |
| 3 | CollisionShape3d | `CollisionShape3d`（enum）・`Box3d`・`box3d`・`boxOfNode`・`boxOfMesh`・`transformBox`・`closestPoint`・`penetration`・`debugMesh` | 2D の CollisionShape2D |
| 3 | CollisionWorld3d | `build`・`boxesNear` | |
| 3 | CharacterBody3d | `Settings`・`settings`・`Body`・`Footing`・`moveAndSlide`・`snapToFloor`・`overlapDepth` | Godot CharacterBody3D・Unity CharacterController |
| 3 | Ray3d / Camera3d | `Ray3d`・`ray3d`・`RayHit`・`hitBox`・`hitSphere`・`hitTriangle`・`hitMesh`・`hitInstance`・`RayTarget`・`pickNearest`・`forwardRay`・`screenPointToRay` | Bevy Ray3d・Unity ScreenPointToRay / RaycastHit |
| 4 | Scene3d | `Sky3d`・`Scene3dCmd.sky`・`gradientSky`・`withSkyCurve` | Godot ProceduralSkyMaterial |
| 4 | Scene3d | `withAlphaBlend`・`withDoubleSided`・`MaterialFields.blend`・`doubleSided` | glTF alphaMode / doubleSided |
| 4 | RenderTarget | `Descriptor.samples`・`withMsaa` | |

`get*` を使っていない（探すのは `find*`、計算は `build*`/`box*Of`）。比喩の名前は無い。`bin/fge jargon` は実装の時のコミットで走る。

---

## 5. テストの回し方（段ごと）

- 段 1:
  - `make test-engine`（Scene3d の spotConeOf）
  - `make sync-layers` → `.layers/engine_world` で `flix test`（App の宣言・PropertyTest）
  - `.layers/engine_tools`（SoftRaster3d の cone）
  - `make gl-parity`
- 段 2: `make test-engine`（Gltf・Model3d・Frustum）・`.layers/engine_tools`（間引きの前後の一致）・`.layers/render_gl`・`make gl-parity`
- 段 3: `make test-engine`（CollisionShape3d・Ray3d）・`.layers/engine_world`（CharacterBody3d）。描き手は触らないので gl-parity は回さない
- 段 4: 全部の層と `make gl-parity`。テンプレートの reference
- 段 5: round8 の段取り。リリースの前に全量

各段のデモの追従は、night_apartment の `make test` と実機で歩く（マウス・調べる・扉）。

---

## 6. 文書の置き場

- 3D の分野の doc: 今は `docs/modules/engine.md` の 3D の節と `docs/lightmap.md`。この計画で節が 5 つ増える（一人称の視点・歩く・調べる・空・半透明と MSAA）。
  - **`docs/scene3d.md` を 1 本作り、lightmap と同じ並びで置く**ことを §10 の Q8 で聞く（推し: 作る。engine.md の 3D の節が長くなりすぎる）。
- `make module Q=<語>` で引ける行を `docs/module-index.md` に足す。
- `docs/api-digest` は生成物（`make api-digest`）。
- 移行メモ: 段ごとの版の `docs/migrations/<版>.md`。

---

## 7. 後に回す物（この計画の外）

- 光の境での点滅の抑え（8 番目と 9 番目を薄くつなぐ・優先度）。8 本を超える場面の絵が変わるので、口を分けて入れる時に決める
- 8 本を超える点光源（clustered / forward+）
- glTF の `extras`（Blender のカスタムプロパティ）・`KHR_lights_punctual`（glb の中の光を読む）。night_apartment は manifest から灯りを読んでいる
- 正確なカプセル × 箱（線分と箱の最近点）。v1 は球を縦に並べる近似
- 三角形の当たり判定で歩く（メッシュの壁）。v1 は箱だけ
- 加算の半透明（光の筋・炎）。v1 はビルボードの unlit で足りている
- 窓のマルチサンプル（Pass を使わない 3D・2D の縁も変わる）
- glTF の MASK の `alphaCutoff` を 0.5 以外で
- スポットの影の 2 本目
- 前もって作る口（`Scene3d.prewarm`。fps3d_lab の `warmPlan`）。§3.5 で間引きが悪化させないようにしただけで、口そのものは別

---

## 8. リリースの切り方（提案）

**推し: lightmap は 0.75.0 で先に出し（範囲を広げない）、この計画は段ごとに 1 版ずつ上げる（0.76.0〜0.80.0）。**

理由:
1. lightmap（WIP 7 コミット）は L4 と移行メモの下書きまで来ている。14 個を待つと 1 か月以上止まり、night_apartment が lightmap を使えるのも遅れる。
2. 段ごとに絵の変わり方が違う。
   - 段 1・3 は変わらない
   - 段 2 は emissive の glb だけ・段 4 は BLEND の glb だけ
   - 段 5 は全部の 3D
   - 版を分ければ、移行メモが「その版で何が変わったか」だけになり、ゲームの追従（reference の撮り直し）も段ごとに小さく済む。`make agent-eval-release` で前の版と比べる時も、差の原因が絞れる
3. #12 は 0.75.0 の `scene3dTextureBudgetMB` と組に見えるが、`EngineConfig` を字で組むゲームとテンプレートは無い（レビューで確かめた）。0.75.0 に入れても得が無いので、0.75.0 の範囲を広げず段 1 に置く。
4. 段 1 の 7 は `SpotLight` を字で書いた所を止める。0.75.0 に混ぜると lightmap の移行と重なり、lightmap の懐中電灯（`spotLights`）を書いたばかりのゲームが同じ版で 2 回直すことになる。だから 0.76.0。

代わりの案: 段 1 も 0.75.0 に入れる（マウスの閉じ込めをすぐ使える）。lightmap のリリースが段 1 の分（約 1 週）遅れる。§10 の Q2。

---

## 9. 絵が変わる物の表（移行メモの元）

| 段 | 変わる物 | 変わらない理由 / 変わる時の手当て |
|---|---|---|
| 1 | なし | 12・14・2・13 は絵を描かない。7 は None で今の式 |
| 2 | emissive つきの glb を `loadTextured` で読む物が光る（baseColorTexture の無い emissive だけの材質も） | 移行メモ。止めるなら `Scene3d.withoutEmission`。emission の無い材質の spec 名は替えない（描き出しの鍵も今のまま）。`+em` は絵を変えない。1 と 5 は変えない |
| 3 | なし | 描き手に触らない |
| 4 | glb の `alphaMode: BLEND` / `MASK` の物 | 移行メモ。`doubleSided` は既定で当てない（全部の glb が真なので）。sky と MSAA と withAlphaBlend は既定で使わない |
| 5 | 3D を使う全部 | round8 の G6 の合わせ直し。2D は変えない |

---

## 10. 人に決めてほしいこと（推しつき）

- **Q1. この計画と段 I（2D と 3D を混ぜる・`plans/engine-round10-2d3d-mix.md`）の順** — 推し: **この計画の段 1〜3 を先**。night_apartment を動かしながら進められ、段 I の HD-2D も段 2 の名前つきノード・段 4 の空を使える。番号の重なりは、こちらを `engine-round11-3d-kit.md` にすると直る（名前はこの依頼の指定に従って round10 のままにしてある）。
- **Q2. リリースの切り方** — 推し: §8（0.75.0 は lightmap だけ、段ごとに 0.76.0〜0.80.0）。
- **Q3. 段 5 で 3D の絵を一斉に線形へ替えるか** — 推し: **替える。1 版だけ project.json `scene3dLinearColor: false` で戻せる口を残し、次の版で消す**。night_apartment と fps3d_lab は段 5 の中で合わせ直す。
- **Q4. night_apartment のクロスヘアと名前の 1 行**（`AGENTS.local.md` は「画面に字や HUD を出さない」） — 推し: クロスヘアは 2 px の点を閉じ込めている間だけ。名前と調べた文言は、見ている物を調べた時だけ出す（読む物として必要。終了の確認と同じ例外）。人の注文なので `AGENTS.local.md` を直すかを聞く。
- **Q5. Studio の中で走らせた時のマウスの閉じ込め** — 推し: 同じ動き（窓は GLFW）。Studio の「止める」で放す。段 1 の実装で 1 回触って確かめ、困るなら Studio から走らせた時は閉じ込めない旗を App に渡す。
- **Q6. MSAA の掛け方** — 推し: **Pass ごと（`RenderTarget.withMsaa`）だけ**。窓そのもの（`GLFW_SAMPLES`）に掛ける口は 2D の縁も変えるので v1 では作らない（§7）。
- **Q7. CPU の描き手の MSAA** — 推し: **しない**。画面なしの絵は縁がならされないまま（FXAA の Pass は効く）。CPU で 4 倍の塗りは描き出しが 4 倍重くなり、agent-eval と render-loop の時間に効く。
- **Q8. `docs/scene3d.md` を作るか** — 推し: 作る（§6）。
- **Q9. 段 2 で emissive を既定で読むか** — 推し: **読む**（glTF の決まり・Godot も Unity も読む。止める口 `withoutEmission` を添える）。代わりの案は `loadTexturedWith` の新しい旗で選ばせる形（`TextureLimits` に欄を足すと字で書いたゲームが止まるので、別の引数になる）。

- **Q10. glTF の `doubleSided` を読み込みで当てる旗を作るか** — 推し: **v1 は作らない**（ゲームが `part#gltfMaterial#doubleSided` を見て当てる）。Blender の書き出しは全部の材質を `doubleSided: true` にするので、旗を作っても「網だけ」を選べない。要るなら材質の名前（`gltfMaterial#name`）の決まりで選ぶ関数をゲームに書く。

---

## レビューの記録

### 1 回目: 72 点（rev0）
重い指摘と直した所:
1. 描き出しの鍵（DrawHash）の手当てが無い → §1 に決まり（既定値は何も書かない）を足し、各節に「鍵」の行。emission の無い glb の spec 名は替えない形にした（キャッシュの描き直しを起こさない）
2. glTF の `doubleSided` は workspace の全部の glb が真 → 既定で当てない。ゲームが `gltfMaterial` を見て当てる。Q10
3. カリングで形が GPU から捨てられる・不安定な並べ替えで順が変わる → 間引いた物も `lastUsed` を進める・全部で並べてから飛ばす
4. emissive の穴（baseColorTexture の無い材質・絵の無い emissive・spec 名の衝突・fromGlb）→ 4 通りの表と名前の決まり
5. 工数（段 2・段 4・gl-parity の道具）→ 段 2 は 7 日・段 4 は 11 日（内訳つき）
6. CharacterBody3d の一致 → `floorMaxAngleDeg = 90`・範囲は厚い箱・一致の対象外を明記
### 2 回目: 84 点（rev1）
重い指摘と直した所:
1. emissive の名前の穴（ゲームが emission を差し替えると同じ名前で木が違う・emissive の絵の filter・読めない絵を Solid に倒すと真っ白）→ `Scene3d.withSpecName` を足しデモはそれを使う・名前に emissive の filter・読めない時は付けずに知らせる
2. 押し出しの順 → `boxesNear` は元の並びで返す・静的の後に moving・テストは並びまで比べる
軽い指摘（spotInnerRatio の使う所・mipCopiesRef と法線マップと lightmap の絵・ビルボードの半径・sloped のしきい値・範囲の箱の高さ・Capsule の二重・TEXCOORD_0 の無い形・meshOfParts）も入れた

### 3 回目: 88 点（rev2）— 85 点を超えた
新しい重い指摘は無し。軽い指摘 3 件（§3.8 の `Stage.renamed` の文の食い違い・TEXCOORD_0 の有無は部品ごとなので emission の判定は部品へ割り当てる所で・`withSpecName` は木ごとに名前を分ける）を直して rev3 とした。
残した物: なし（`withSpecName` で替えた名前が描き出しの鍵に入るのは正しい振る舞いで、移行メモは要らない、とレビュー役も同意）。

### 1 回目の軽い指摘
軽い指摘も全部入れた（alpha to coverage の α・閉じ込め中の cursor・withDiagnostics が診断を有効にする・nodesByName・mesh の無い glb・partLocalToNode の None・形の enum・名前（snapToFloor・boxesNear・scene3dCounts）・spotInnerRatio の一本化・usedImages の WhyNot・行数・#12 を 0.76.0 へ・2 回の合わせ直し）
