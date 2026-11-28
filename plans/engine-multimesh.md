# 同じ形の動く物をたくさん描く（MultiMesh3d）と instances の道の手直し — 計画（レビュー 2 回目用・未着手）

状態: 計画（git に入れない）。人の決め「A: 案 2 と案 1 の両方を入れる」（2026-11-26）。レビューで 90 点を超えたら実装する。engine の拡張（Scene3d の口を足す）。
**事実**はソースか実測（スパイクの枝 `worktree-agent-aa7a62051242ca97d`・worktree `/Users/abab/Desktop/flix_game_engine/.claude/worktrees/agent-aa7a62051242ca97d`・fbb169854 の上の 9 コミット・main にマージしない）。**推測**は「推測:」と書く。
段の前提は main の **09f04cef8（0.114.0）**。fbb169854 から 10 コミット（段 A・段 B・doubleSided・glb の口の 1 本化・束の分け直し・版上げ）。

## 0. 結論

1. **新しい口 `MultiMesh3d`**（Godot の MultiMesh と同じ物）を足す。ゲームは `MultiMesh3d.build(mesh, n, i -> Mat4)` で作り、場面の `multiMeshes` に載せる。
   - GL と WebGPU は計画を通さず、並びを 1 体ごとの値へ直に詰めて 1 回の instanced draw で描く。
   - 影の pass は場面の pass と同じ並びを読む（詰めるのは 1 回）。
   - **参照が同じ値は詰め直さずに持ち越す**（Godot と同じ）。
   - ブラウザ WebGPU で 1 万個の箱の 1 コマの CPU は、毎コマ動かして 20.9 → 4.9〜5.2 ms・止めて同じ値を渡せば 1.6 ms（1.2・1.4）。
2. **instances の道の手直し（案 1）も入れる**。今のゲームはそのまま速くなる（同じ場面で 20.9 → 13.6 ms）。
3. **使い分けの守りを中心の段にする**（4 節）。型で書けない物を先に塞ぐ（並びの長さ・骨・lightmap・色の数）。
   塞げない物は、今ある 2 つの知らせ（`@static-group-hint`・`@draw-call-hint`）の文を 2 択に替え、足す知らせを 4 つ（①③④⑤）に絞る。docs は「動くか → 同じ形がたくさんか」の質問の木にし、agent-eval に選び間違いを外れにするお題を 3 本足す。
4. **`Mobility` を必須の引数にする形は採らない**（2.2）。
5. **半透明の材質は (a) 不透明として描き、④で知らせる**（4.1）。

新しい pub は 11（3.1）。ゲームが書く行は 1 万個の群れで 2 行。移行（欄を写して場面を作り直す所の直し）は src に 3 か所（3.3）。

## 1. 測った事実

機械は M4 Pro・Chrome 156 ヘッドレス・1280×720・vsync あり。値は rAF の中の CPU で、3 回の中央値 [最小–最大]。比べる組は N ごと・回ごとに交互に流した。
ベンチは `~/Documents/flix_ge_workspace/web_bench/crowd/flix`（箱 N 個を毎コマ回しながら上下させる・床 1 枚・太陽 1 つ）。
生の値は `web_bench/results/crowd/` の `spike-main/`（元・案 1・案 2 の生の並び）・`spike-build/`（生の並びと `build`）・`spike-carry/`（持ち越し）にある。同じ組でも回によって 0.3 ms ほど揺れる（mm2 の 1 万個が spike-build で 4.9・spike-carry で 5.2）。

### 1.1 元の道の内訳（N=10000・元の engine・含む時間 ms/コマ・CPU プロファイル）

| 段 | WebGPU（計 21.5） | WebGL2（計 18.6） |
|---|---|---|
| GC | 5.5 | 3.8 |
| ゲームの `sceneOf`（Mat4 を 3 つ・`meshInstance`・List） | 2.1 | 2.2 |
| 計画 `ScenePlan.groupScenesWith` | 7.4 | 7.0 |
| ├ `placeOne` | 6.3 | 6.0 |
| ├─ 視錐台 `Scene3d.isOutsideFrustumFields`（角 8 つを写す） | 2.3 | 2.3 |
| ├─ `plainPlacement`（`batchKeyOf` と表の引きを 1 体ずつ） | 1.2 | 1.2 |
| ├─ `levelOf`・`subOf`（形の鍵の字と Map） | 1.1 | 0.9 |
| └ `spansOf` | 0.6 | 0.6 |
| 詰め `InstanceValues.packDraw`（`toColumns`・`normalMatrix` の Vector・tint の pow） | 3.6 | 3.8 |
| GPU へ送る（writeBuffer / texSubImage） | 0.3 | 0.04 |

- 並べ替えや二乗は、もとから残っていない。重いのは 1 体ごとの確保と、1 体ごとにやり直す引き当て。
- PC（Dawn の WebGPU・bench/scene3d の field・N=10000・材質つき・動く物 100%）の CPU の区間は次のとおり。frame は 120 Hz に張り付くので比べに使わない。元の値は 1 回だけ取った値。

| | split | draw | submit |
|---|---|---|---|
| 元 | 4.65 | 2.3 | 7.0 |
| 案 1 | 2.7〜3.3 | 1.3〜1.7 | 4.2〜5.1 |
| 案 2（`MULTI=1`） | 0.14〜0.19 | 0.55〜0.70 | 0.8〜1.0 |

### 1.2 毎コマ動かす群れ（rAF 内 CPU p50 / p99 ms）

| N | 描き手 | 元 | 案 1 | 案 2 生の並び（`spike-main`） | 案 2 `build`（`spike-build`） |
|---|---|---|---|---|---|
| 1000 | WebGPU | 3.3 [3.1–3.3] / 4.5 | 2.5 [2.5–2.6] / 4.5 | 1.6 [1.0–1.6] / 4.4 | 測っていない |
| 10000 | WebGPU | 20.9 [20.7–21.0] / 25.8 | 13.6 [13.2–13.8] / 20.8 | 3.9 [3.9–4.1] / 4.4 | 4.9 [4.9–5.0] / 5.4 |
| 20000 | WebGPU | 41.2 [39.9–41.6] / 50.0 | 29.9 [29.5–31.2] / 41.3 | 6.9 [6.8–6.9] / 7.6 | 8.4 [8.3–8.6] / 9.0 |
| 1000 | WebGL2 | 3.0 [2.7–3.1] / 4.4 | 2.1 [2.1–2.2] / 3.7 | 1.2 [0.9–1.2] / 3.8 | 測っていない |
| 10000 | WebGL2 | 17.2 [17.1–18.5] / 21.5 | 12.9 [12.1–13.8] / 19.9 | 3.4 [3.2–3.4] / 3.8 | 4.4 [4.3–4.6] / 4.8 |
| 20000 | WebGL2 | 39.2 [38.8–40.4] / 46.0 | 28.0 [27.8–29.1] / 38.2 | 5.8 [5.8–5.9] / 6.4 | 7.7 [7.6–7.7] / 8.5 |

- 比べの相手の Godot 4.6.2 の MultiMesh（WebGL2・`godot-crowd-webgl2-n10000`）は 10000 で 3.4 ms。`results/crowd/raw/` の **1 回だけの値**（3 回ではない）。WebGL2 の行と比べる。
- 「生の並び」と「`build`」は別の回の測り。同じ回に交互に流した両者の差は、10000 で 0.8〜1.0 ms・20000 で 1.4〜1.9 ms（`build` が重い）。
- 絵は、元・案 1・案 2 の 3 つとも WebGPU・WebGL2 の両方でバイトまで同じ（web-capture の 150 コマ目・`spike-main/compare-n10000-*.png`）。`make gl-capture-check SCENES=scene3d` も 6 枚がバイトまで同じ。
- テストは render_gl 764・engine 1117・engine_tools 345 が緑。

### 1.3 落とし穴（事実）

- **毎コマ `Scene3d.instancesOf` を呼ぶ所**が MultiMesh を 1 体ずつに開くと、それだけで元に戻る。WebGL2 が 3.4 ms のはずの所で 11 ms になった（`Render3d.drawScene` が数えるために 2 回呼んでいた）。14 か所の扱いは 3.4 の表に書く。
- **欄を写して場面を作り直す所は、新しい欄を黙って落とす**。`PostStack.Internal.Passes.depthItemOf` が奥行きの場面を作る時に `multiMeshes` を写さず、奥行きのぼかしで MultiMesh が消える。逆に `HeadlessRender.silhouetteScenes` は instancesOf で開いた上に `| sc` で `multiMeshes` を残すので、二重に描く。洗い出しは 3.3 の表。
- **スポットライトの影が落ちない**。`ScenePlan.spotCasterOf` が見る `StaticRows.hasDrawnItem` は instances と groups しか見ない。
- **案 1 の使い回しは、材質の値の参照が同じ時だけ効く**。最初の版（材質の無い物だけ）は bench/scene3d の field に効かず、0ea27c628 で (材質の参照, 形の参照) に広げた。
- **Float32 を pub 面に出すと lint-f32 が止める**。並びは Float64 にし、Float32 へは詰める時に変える。
- **行の数の上限（1200）に近いファイルがある**。main の行の数は、Scene3d.flix 1192・SoftRaster3d.flix 1182・WebGpuRenderer.flix 1163・Render3d.flix 1159。どこに置くかは 3.2 の表に書く。

### 1.4 同じ値を続けて渡す群れ（7 の別案のスパイク・62a0f0ca6・WebGPU・`spike-carry`）

箱を読み込みで 1 回 `build` して World に持ち、毎コマ同じ値を `multiMeshes` に渡す（動かない群れ）。5 つの組を交互に流した。

| 組 | 10000 p50 / p99 | 20000 p50 / p99 |
|---|---|---|
| 動かない MultiMesh・毎コマ詰め直す（P） | 3.7 [3.5–3.7] / 4.8 | 5.8 [5.7–5.8] / 6.6 |
| 動かない MultiMesh・**参照が同じなら持ち越す** | **1.6 [1.6–1.7] / 4.4** | **2.2 [2.2–2.2] / 5.0** |
| 同じ箱を staticGroup で渡す | 1.1 [1.1–1.2] / 3.6 | 1.0 [1.0–1.0] / 3.7 |
| 毎コマ `build` する群れ（P） | 5.2 [5.1–5.3] / 6.3 | 8.3 [8.2–8.3] / 8.9 |
| 毎コマ `build` する群れ（持ち越しあり） | 5.2 [5.0–5.3] / 6.1 | 8.3 [8.2–8.3] / 8.9 |

- 持ち越しは、毎コマ作る群れを遅くしない。2 コマ続けて同じ参照を見るまで並びを控えないので、使わない写しを作らない。
- 持ち越しても staticGroup より 0.5〜1.2 ms 重く、差は N とともに開く（推測: 並びを毎コマ GPU へ送り直すため）。動かない物は今まで通り staticGroup を勧める。
- **ちょうど 2 コマだけ生きる値（レビューの必須 A・39d83a8e8・`spike-alt`）**: 刻みより速い画面（120 Hz と刻み 60）では World の値が 2 コマずつ同じ参照で来る。
  最初の持ち越し（62a0f0ca6）は 2 コマ目に新しい並びを作って詰め直していたので、控えが一度も使われないこの形で P より遅くなりうる。
  直した形（39d83a8e8）は、2 コマ目に out へ詰めた所を控えに写し（詰めるのは 1 回）、並びは使い終えた控えから使い回す（確保を消す）。
  「1 コマおきに build する群れ」で 5 つの組を交互に流した（WebGPU・3 回）:

| 組 | 1 万個 p50 / p99 | 2 万個 p50 / p99 |
|---|---|---|
| 1 コマおきに build・P | 5.3 [4.8–5.5] / 6.9 | 9.6 [9.2–9.6] / 10.9 |
| 1 コマおきに build・最初の持ち越し | 5.5 [5.4–5.6] / 6.4 | 9.3 [9.2–9.6] / 10.3 |
| 1 コマおきに build・直した持ち越し | 5.5 [5.2–5.7] / 6.3 | 9.5 [9.5–9.5] / 10.2 |
| 動かない・P | 3.5 [3.4–3.8] / 3.9 | 5.6 [5.5–5.8] / 6.1 |
| 動かない・直した持ち越し | 1.8 [1.7–1.9] / 2.1 | 2.2 [2.1–2.4] / 2.5 |

  3 つの組の差は 3 回の幅の中（1 万個で +0.2・2 万個で −0.1 ms）で、最初の形の遅さも測りでは見えなかった（推測: 確保の代金が wasm の GC で小さく、重いコマが半分しかないので p50 に出にくい）。直した形は、どちらにしても詰め直しと確保が無い。
- 影の pass の詰め直しを消した直しも 62a0f0ca6 に入れた。SHADOW=1 の測りは段 4（7 節）で取る。
  推測: 点光源の影は面 6 つ × 灯りの数だけ詰め直していたので、影ありの場面ほど効く。

## 2. 案の比べ

### 2.1 口の形

| 案 | 形 | 新しい pub | ゲームが書く行 | 1 万個（WebGPU）動く / 止まる | 選び間違えた時の害 |
|---|---|---|---|---|---|
| 今のまま（instances） | `List.map(i -> meshInstance(...))` | 0 | 2 | 20.9 / 20.9 | — |
| 案 1 だけ | 同じ | 0 | 2 | 13.6 / 13.6 | — |
| P. 並べる・`build` だけ・毎コマ詰める | `MultiMesh3d.build(mesh, n, i -> Mat4)` | 11 | 2 | 4.9〜5.2 / 3.7 | 止まる群れを MultiMesh に置くと staticGroup の 3 倍（知らせ ② が要る） |
| **P＋持ち越し（参照が同じなら詰めない）** | 同じ | 11 | 2 | **4.9〜5.2 / 1.6**（WebGPU の値。GL は段 2 で入れて段 4 で測る） | 止まる群れを MultiMesh に置くと staticGroup の 1.5 倍（1 万個）〜2.2 倍（2 万個）。② と「動かない MultiMesh」の知らせが要らない |
| P'. 生の並び `of(mesh, Vector[Float64])` も足す | 並びを直に書く | 12 | 4〜6 | 3.9 / — | 長さの誤り（12 の倍数でない）を型で止められない |
| M. 動くかを必須の引数で（2.2） | `Scene3d.crowd(mesh, n, i -> Mat4, Mobility.Movable)` | 13 以上 | 2 | 4.9 / staticGroup と同じ | 誤った答えは型を通る |

**P＋持ち越しを採る。**
- 持ち越しは描き手の中の約 60 行（`InstanceValues.MultiCarry`・描き手の状態の欄 1 つ）。pub は増えない。ちょうど 2 コマだけ生きる値で P より遅くならない（1.4）。
- ② の知らせ（ポーズで誤って鳴る・「同じ MultiMesh」の決め方が要る）が丸ごと要らなくなる。
- 止まる群れを誤って MultiMesh に置いた時の害が、1 万個で 3.4 倍 → 1.5 倍・2 万個で 5.8 倍 → 2.2 倍に縮む（WebGPU）。
- GL は描き手の `State` に同じ控えを持たせる（スパイクは毎回作り直しで、持ち越していない）。

### 2.2 「動くか」を型で答えさせる形（人の案）との比べ

業界の語は Unreal の **Mobility**（Static / Stationary / Movable）と Unity の Static のチェック。どちらも既定値つきで、エディターの欄と実行時の警告で守る。
案 M は、既定値の無い必須の引数にして型で必ず答えさせる形。名前を付けるなら `Motion` ではなく Unreal に合わせた `Mobility.Static` / `Mobility.Movable`。

| 点 | P＋持ち越し | M（Mobility を必須に） |
|---|---|---|
| 同じ形で動かない物 | staticGroup。形が同じ物は描き手が 1 回の draw にまとめて持ち越す（performance.md §12 の staticGroup の行・bench/scene3d/RESULTS.md の 12,000 個で draw 2）。MultiMesh に置いても持ち越すので 1.6 ms（1.4） | `Mobility.Static` の中身は staticGroup の持ち越しと同じ物を、並びの値を鍵にもう 1 本作る |
| staticGroup との関係 | 並べる。今の呼び手 18 か所＋テンプレート 2・bench 8・手元のゲーム 3 本はそのまま | 置き換えるなら移行が上の全部（名前つきの集まり・`withoutItems`・`withGroupTint`・preload の groups も直す）。並べるなら「Static の crowd と staticGroup のどちらか」という迷いが増える |
| 新しい pub | 11 | 13 以上 |
| 一部だけ動く物 | 動く物を MultiMesh・動かない物を staticGroup | 2 つの crowd に分ける |
| AI の選び間違い（推測） | 木の 1 問目が「動くか」なので、M と同じ問いを docs と agent-eval で先に立てる | 引数で必ず答えるが、誤った答えは型を通る |
| Stationary に当たる物 | 要らない。動かないが色や有無が変わる物は `withGroupTint`・`withoutItems` が受け持つ | 同じ |

**採らない。**
- 「動くか」で変わるのは、描き手が持ち越すかどうかだけ。その差は、staticGroup の持ち越しと MultiMesh の持ち越し（参照が同じなら詰めない）の 2 つで、もう受け止められる。
- 新しい enum の得は「書く前に一度考えさせる」だけ。それは木の 1 問目と agent-eval で取る。

### 2.3 名前（`MultiMesh3d` で良いか）

| エンジン | 同じ物の名前 |
|---|---|
| Godot | `MultiMesh`（資源）と `MultiMeshInstance3D`（置く物） |
| three.js | `InstancedMesh` |
| Unity | `Graphics.RenderMeshInstanced`（関数）・`BatchRendererGroup` |
| Unreal | `InstancedStaticMeshComponent`（ISM・HISM） |
| Bevy | 名前の付いた口は無い。同じ mesh と material の entity を描き手が自動で instancing する（案 1 と同じ考え） |

**`MultiMesh3d` を採る。**
- このリポでは「Instance」がもう「置いた 1 体」（`Scene3d.Instance3d`・`meshInstance`）の意味で使われている。`InstancedMesh3d` は「Instance3d の Mesh」と読み違える。
- 3D の部品は `Mesh3d`・`Pose3d`・`Skin3d` の形にそろっている。
- docs/scene3d.md も Godot・Unity・Unreal の語に寄せている。

## 3. 決めた形と段

### 3.1 口（新しい pub 11）

| pub | 誰が使う | 形 |
|---|---|---|
| `MultiMesh3d.MultiMesh3d` | ゲーム | 外から作れない型（非 pub の enum + `pub type alias`） |
| `MultiMesh3d.build(mesh: Mesh3d, n: Int32, worldOf: Int32 -> Mat4): MultiMesh3d` | ゲーム | 唯一の作り方。i 体目の行列の上の 3 行を読み、作る時に群れ全体の境界を 1 巡で出す。骨の重みを持つ形を渡すと、描き手が形ごとに 1 回知らせる（バインドポーズで描く） |
| `MultiMesh3d.withColors(colorOf: Int32 -> Color, mm)` | ゲーム | i 体目の色（頂点の色に掛ける・tint と同じ sRGB）。関数の形なので色の数が食い違わない |
| `MultiMesh3d.withMaterial(m: Scene3d.Material3d, mm)` | ゲーム | 半透明の材質は、ここで 1 回だけ blend を落として持つ。④のために「半透明を頼まれた」の Bool だけを残す（4.1 の (a)） |
| `MultiMesh3d.MultiMeshFields`・`fieldsOf`・`countOf`・`colorAt` | 描き手と engine_tools 専用（doc にそう書く） | render_gl と engine_tools は別の層なので pub が要る |
| `MultiMesh3d.toInstances(mm): List[Instance3d]` | CPU の描き手・撮りの鍵 | 1 体ずつ作る（doc に「毎コマ呼ばない・描き手は使わない」）。スパイクの `instancesOf` から名前を替える（`to*` は作り直す） |
| `Scene3dCmd.multiMeshes: List[MultiMesh3d]` | ゲーム | 既定は `Scene3d.scene` の Nil |
| `Scene3d.hasDrawnInstance`（pub にする） | 描き手 | 今の `StaticRows.hasDrawnItem` を消し、これ 1 つにする（1.3 のスポットの影） |

スパイクの `Scene3d.placedCountOf` と生の並びの `of` は消す（数えるのは render_gl の `StaticRows.placedCountOf` に multiMeshes を足す形・3.4）。
視錐台は群れ全体を 1 つの境界で間引く（場面の pass は場面の視錐台・影の pass は光の視錐台）。1 体ずつは間引かない。

### 3.2 足す物をどこへ置くか（行の数の上限）

| 足す物 | 置き場 | 理由 |
|---|---|---|
| 型・`build`・`withColors`・`withMaterial`・`toInstances`・境界の計算 | `engine/src/scene3d/MultiMesh3d.flix`（新しいファイル・スパイクで 70 行） | Scene3d.flix（1192 行）に入らない |
| `Scene3dCmd` の欄・`instancesOf` の 2 行・`hasDrawnInstance` の pub | Scene3d.flix（＋3 行で 1195） | 型の欄は動かせない |
| 計画（材質を聞く・境界で間引く・MultiMesh の draw の記録） | `render_gl/src/Render3d/MultiMeshPlan.flix`（新しいファイル） | ScenePlan.flix は main で 710 行で、ほかの手直しと重なりやすい |
| 詰める・持ち越す（`MultiCarry`） | `Render3d/InstanceValues.flix`（main の 87 行 → スパイクで 245 行） | 1 体ごとの値の並びを持つ所 |
| 知らせ ①③④ と、今の 2 つの知らせの文 | `Render3d/ScenePlan.flix` の今の `noteStaticGroupHint`・`noteDrawCallHint` の隣（4.2） | 同じ作り（場面ごとに数えて続いた数で鳴らす）にそろえる |
| WebGpuRenderer（1163）・Render3d.flix（1159）の手直し | 呼ぶ所の数行だけ（持ち越しの控えの欄 1 つ・数える行） | 上限に近いので、中身は上の 2 つのファイルへ |
| SoftRaster3d（1182） | 触らない（`instancesOf` が開いた物を描く） | — |

### 3.3 欄を写して場面を作り直す所（`refactor usages "Scene3d.Scene3dCmd#groups" --write` で洗い直した・src だけ）

| 所 | 今の形 | 直し |
|---|---|---|
| `Scene3d.scene` | 組み立て | 欄 `multiMeshes = Nil` を足す（スパイクで済） |
| `DrawHash.putSceneCmd` | 全部の欄の match | `multiMeshes = _` を足す（スパイクで済）。鍵の扱いは 3.4 |
| `PostStack.Internal.Passes.depthItemOf`（engine_world・204〜209 行） | instances・groups ほかを写して奥行きの場面を作る | `multiMeshes = cmd#multiMeshes` を足す。テスト: MultiMesh だけの場面で奥行きのぼかしの奥行きの絵に MultiMesh が写る |
| `HeadlessRender.silhouetteScenes` | `instancesOf` で開いて `groups = Nil` にし、ほかは `| sc` で残す | `multiMeshes = Nil` を足す（開いた分と二重になる）。テスト: 影絵の絵で MultiMesh の物の所の画素が黒（影絵の色）になる |

テストと bench（groups を書くテスト 12 か所・hd2d_town 2・scene3d 2・gl_parity 2）は record の更新なので、新しい欄は既定のまま残り、直す所は無い。

### 3.4 `Scene3d.instancesOf` を呼ぶ 14 か所の扱い（`refactor usages`）

| 呼ぶ所 | 毎コマか | 扱い |
|---|---|---|
| `Render3d.drawScene`（2 か所） | 毎コマ | `StaticRows.placedCountOf` を使う（知らせに渡す数は instances と groups だけ・診断の置いた物の数には MultiMesh の体を足す） |
| `ScenePlan.groupScenes` | テストだけ（`TestSceneList` の 9 か所） | MultiMesh を含まない `scene#instances` と groups を読む形に替える |
| `SoftRaster3d.renderLayer`・`SoftRaster.Internal.Texture.sceneTexturesOf`（4 か所）・`DrawList.argbReadNames` | CPU の描き手の毎コマ | 開いたまま（CPU は描く代金の方が大きい） |
| `DrawHash.putSceneCmd`・`usedTextures` | 撮り（テープ・headless）の毎コマ | 開かずに並びの数をそのまま鍵に入れる（同じ版どうしでしか比べないので、instances に開いた場面と鍵が違っても害は無い） |
| `HeadlessRender.silhouetteScenes` | 撮りの道具 | 開いたまま（3.3 の直しと一緒に） |
| `Annotate.named3d` | F8 で囲んだ時だけ | 開いたまま（名前は空なので MultiMesh は注釈に出ない。docs に 1 行） |
| `WebLayer.sceneTextureNamesOf` | `?fge=usedassets` の時だけ | MultiMesh の材質の絵だけを足す形に替える（開かない） |

ほかに MultiMesh を見ない物（docs に 1 行ずつ）:
- `Scene3dCheck.check` は置いた物の見た目と当たりを比べるが、MultiMesh の物は見ない（当たりはゲームが持つ）。
- 先に用意するのは `App.withPreload3d` の `App.preload3d(key, Scene3d.meshInstance(形, Mat4.identity()) |> Scene3d.withMaterial(材質) :: Nil)` でできる（同じ形と材質のプログラム。`toInstances` は全部の体を作るので使わない・docs に 1 行）。`preloadVariantOf` は場面の変種で決まり、MultiMesh で変わらない。

### 3.5 案 1 の中身と条件

| 直し | 条件 | WhyNot（コードのコメントに残す物） |
|---|---|---|
| 視錐台: 箱を囲む球が 6 面の内側に余裕を持って収まれば、角を写さない | 球の半径 = 箱の対角の半分 × 3×3 の Frobenius の長さ（どの向きの伸びよりも大きい）。余裕は 0（角の判定の margin より内側） | margin を足さない — 角の判定は「margin より外」で外と言うので、0 の内側に収めれば丸めがずれても答えが食い違わない |
| 計画: 前に分けた物の分け方と候補の番号を使い回す | 姿勢と lightmap が無く、**材質の値の参照と形の値の参照が同じ**で、分けた答えに batch の鍵がある（半透明・`DrawMode.OneByOne` は鍵が無いので毎回分ける） | 材質を中身で比べない — 中身の比べ（木・params）が物の数だけ要り、それを避けるための控え。毎コマ材質を作り直すゲームは当たらないが、答えは同じ（今の `cachedPlacement` と同じ決まり）。docs/performance.md §11 の「材質は読み込みで 1 回作って持つ」に、この効き目の条件を 1 行足す |
| 詰め: `Mat4.toColumns`・`normalMatrix` の Vector を作らずに書く・白の tint で pow を回さない | いつも | `toColumns` を通さない — 1 体ごとに 16 個の Vector を作り、物が万を超える場面で確保と GC が 1 コマの何割にもなる |

### 3.6 段（main 09f04cef8 の上・段ごとにこの枝へコミット・画素の差が出たら入れる前に止めて報告・`--no-verify` は使わない）

段 0 の重なり（`git diff --stat fbb169854 main` から、スパイクが触る所と重なる物）:

| main で変わった所 | 変わり | スパイクとの重なり |
|---|---|---|
| `render_gl/src/Render3d.flix` | +4（drawScene に `countInstances` の行と `noteDrawCallHint`） | スパイクの drawScene の数える行の隣 |
| `render_gl/src/Render3d/ScenePlan.flix` | +25（`Planner` に `shapeSplitScenesRef`・`noteDrawCallHint`） | スパイクは Split と placeOne。知らせ（段 3）はこの隣 |
| `render_gl/src/Render3d/StaticRows.flix` | 85 行（段 A のつなぎ） | `placedCountOf`・消す `hasDrawnItem` |
| `render_gl/src/Render3d/WebGpuRenderer.flix` | +5（countRows の数え） | 持ち越しの欄と numberInstances は別の場所 |
| `render_gl/src/Render3d/Counts.flix` | +4 | 触らない |
| `bench/scene3d/src/First.flix`・`Main.flix` | 4 行・2 行 | スパイクの `Delivery`・`MULTI` のつまみ |
| `engine_tools/test/TestDrawHash.flix` | 9 行 | DrawHash の欄 |
| `docs/modules/engine.md`・`docs/api-digest/engine.md`・`docs/scene3d.md`・`docs/performance.md`・`agents-pack/AGENTS.core.md`・`agents-pack/agent-eval/engine.json` | 8・58・72・9・22・19 行 | 生成物は作り直す。早見表とお題は末尾に足す |

| 段 | 中身 | 緑とする測り | 大きさ（実時間） |
|---|---|---|---|
| **0. 載せ替え** | 09f04cef8 から新しい枝を切り、スパイクの 9 コミットを上の重なりに合わせて載せ直す | `make test-render_gl`・`make test-engine`・engine_tools のテストが緑 | 1〜1.5 時間 |
| **1. 案 1** | 3.5 の 3 つ。テスト: ① 使い回しありと無しで計画の答え（groups・spans・handle）が同じ（材質なし・同じ材質・中身が同じで値が別の材質・半透明・OneByOne・骨・lightmap を混ぜた場面）② 球の先の判定と角の判定が、ばらまいた 1,000 個の箱と面にかかる箱で同じ答え ③ 詰めた 32 個が `Mat4.toColumns` と `normalMatrix` の答えとビットで同じ | テスト緑・`make gl-capture-check SCENES=scene3d` と `make gl-parity` が 0 px。web_bench の crowd の 10000 で、交互に流した元に対して **WebGPU 70% 以下・WebGL2 80% 以下**（3 回とも。スパイクは WebGPU 65%・WebGL2 75%）。bench/scene3d の field（材質つき）の split が元の 75% 以下 | 2〜3 時間 |
| **2. 案 2 の中身** | 3.1 の口・3.2 の置き場。計画が MultiMesh ごとに 1 本の draw を作る（材質は `requestOf` で聞いて `MaterialBatch` に・半透明は 4.1 の (a)）。境界で間引く。影の pass は同じ並びを読む（点光源の面も）。持ち越し（GL の State にも）。`Output.Depth` は今の決まり（cutout と両面の材質だけ材質の道）。3.3 の 2 か所・3.4 の表・`hasDrawnInstance` | テスト（9 本）: ①〜③ 描き手ごとに「MultiMesh の場面 ＝ 同じ物を instances に開いた場面」が画素で同じ（自分自身との比べ。不透明・cutout・太陽の影の 3 つ。GL は gl-capture の場面の組・WebGPU は Dawn のテスト・ブラウザは web-capture の webgl2 と webgpu）④〜⑥ スポット・太陽・点光源の影を MultiMesh だけの場面で落とす ⑦ 奥行きのぼかしの奥行きの絵に写る（3.3）⑧ 影絵の絵で MultiMesh の物の所が黒 ⑨ 境界の外は draw 0・影は落とす。crowd の 10000（`build`）が元の 30% 以下 | **8〜11 時間** |
| **3. 使い分けの守り**（中心の段） | 4 節の全部: 型（3.1）・今の 2 つの知らせの文・足す知らせ ①③④⑤・docs の木と目安の数・早見表 1 行・agent-eval 3 本 | 知らせのテスト 10 本（4.2 の表の 10 行の「鳴る」「鳴らない」）・`make agent-eval ONLY=<3 本>` が当たる・`make check-docs-sync` 緑 | 3〜4 時間 |
| **4. 測り直しと境目** | crowd を元・案 1・案 2 で N=500・1000・2000・5000・10000 で測り、MultiMesh を勧める数の境目を決める（4.3 の「推測: 1,000」を測った値に替える）。持ち越しの組（WebGPU と WebGL2 の両方で、動かない群れの P と持ち越し・**1 コマおきに build する群れの P と持ち越し**）。PC の field で `SHADOW=1`（太陽）と点光源の影の前後。bench/scene3d/RESULTS.md に表・docs/performance.md の §12 に 1 行 | 1 コマおきに build する群れで、持ち越しが P の +5% 以内（3 回の中央値・1 万と 2 万）。動かない群れで、持ち越しが P の 60% 以下（GL も）。そのほかは 7 節 | 1.5〜2 時間 |

**合計 16〜22 時間。**
- 見積もりの根拠: スパイクの案 2（頂点の色だけ・テスト無し）は約 1.5 時間で 250 行だった。段 2 は材質・間引き・影・Depth・持ち越し・3 つの描き手の自分自身との比べのテストで、推測: 700〜900 行。同じ速さに直しとレビューの往復を足して 8〜11 時間と見た。
- 段 1 は段 2 と独立しているので、先に出してよい。

## 4. 穴の塞ぎ方（型 → lint → docs）

### 4.1 型で書けなくする物

| 塞ぐ物 | 形 |
|---|---|
| 並びの長さの誤り（12 の倍数でない・色の数の食い違い） | 作り方は `build(mesh, n, i -> Mat4)` と `withColors(i -> Color)` だけ。生の並びを受ける口を作らない |
| 骨・lightmap・名前を持つ MultiMesh | `MultiMesh3d` に欄が無い。骨の重みを持つ形は描き手が形ごとに 1 回知らせ、バインドポーズで描く（instances に pose 無しで置いた時と同じ） |
| 外から中身を作る・書き換える | 非 pub の enum + `pub type alias`（`Mesh3d`・`StaticGroup` と同じ） |
| 群れ全体の境界の付け忘れ | `build` が作る時に計算して中に持つ（境界 = 各体の平行移動の最小と最大 ± 形の境界の半径 × 3×3 の Frobenius の長さ） |

**半透明の材質は (a) 不透明として描き、④で知らせる。**

| 道 | (a) の扱い |
|---|---|
| 落とす所 | `withMaterial` の 1 か所だけ（blend を落とした材質を持ち、「半透明を頼まれた」の Bool を残す）。計画と `toInstances` はその材質をそのまま使う |
| GL・WebGPU の計画 | 持った材質で聞くので `SceneDraws.opaque` に入る（`blended` には入らない） |
| CPU の描き手 | `toInstances` も同じ材質を付けるので不透明（3 つの描き手の絵がそろう） |
| 影 | 不透明と同じく落とす |
| `Output.Depth` | 不透明と同じく書く（cutout と両面の材質だけ材質の道・ほかは形だけ） |

(b) CPU も群れを 1 つの塊として並べる、(c) 一致のテストから外す、は採らない。(b) は CPU の描き手に MultiMesh を知らせる道が要り、(c) は描き手の違いを残す。
型で止めない理由: 型で止めるには「半透明でない材質」の型を新しく作り、材質を使う全部の所に変換を足すことになる。

### 4.2 知らせ（今の知らせの隣・`warnOnce`）

forbid.json の正規表現と比べ、実行時を採る。正規表現が見えるのは字だけで、「同じ形が何個あるか」「散らばっているか」は実行してみないと分からない。また、消す口が無いので forbid に書く行が無い。

**`noteCrowdHints` にはまとめない。** 今の `noteStaticGroupHint`・`noteDrawCallHint` と同じく、1 つの条件に 1 つの関数で、場面ごとに数えて `staticHintScenes()`（120）回続いたら 1 回鳴らす。数える時の決まり（続いた数を 0 に戻す・小さな場面）がもう 2 つでそろっているので、まとめると 2 つの直しが要る。

| 知らせ | 鳴る条件 | 文の要点 | 数える代金 |
|---|---|---|---|
| `@static-group-hint`（今ある・**残す**） | 置いた物（**instances と groups だけ**・MultiMesh の体は入れない）が 2,000 超・groups が無い | 文を 2 択に替える:「動かない物は Scene3d.staticGroup・同じ形で毎コマ動く物は MultiMesh3d.build」 | 0 |
| `@draw-call-hint`（今ある・main で入った） | draw call が 300 超で、半分超が形の違いで分かれた | 替えない（形が違う物の話で、MultiMesh は効かない） | 0 |
| ① 同じ形が instances にたくさん | instances の中の同じ (材質の参照, 形の参照) の組が 1,000 体以上（推測: 1,000・段 4 で決める） | 「同じ形が N 体 instances にある — 毎コマ動くなら MultiMesh3d.build、動かないなら staticGroup」 | 段 1 の使い回しの表に数を足すだけ |
| ③ 散らばりすぎた MultiMesh | 群れの境界の対角が、カメラの far の 2 倍を超えるコマが 600 回続いた | 「見えない所の物まで描いている — 区画（数十 m 角）ごとの MultiMesh に分ける・弾は届かない距離で消す」 | 0（境界はもう持っている） |
| ⑤ 骨の重みを持つ形の MultiMesh | `build` に渡した形が骨の重みを持つ（初めて描くコマ・形ごとに 1 回） | 「骨で曲げずにバインドポーズで描く — 骨で動く物は instances に `withPose` で置く」 | 0 |
| ④ 半透明の材質の MultiMesh | `withMaterial` に半透明の材質を渡した（初めて描くコマ） | 「半透明の材質は MultiMesh3d では不透明として描く — 透けて重なって見せたい大きな板は instances へ。細い粒（雨・火の粉）は cutout の材質で MultiMesh のままで良い」 | 0 |

場面ごとに何が鳴るか（鳴る・鳴らないのテスト 10 本はこの表から作る）:

| 場面 | static | draw-call | ① | ③ | ④ | ⑤ |
|---|---|---|---|---|---|---|
| 町（形 30 種・8,000 個・動かない）を instances に | **鳴る** | 鳴らない（draw 30 前後） | 鳴らない（1 つの形が 1,000 未満） | — | — | — |
| 同じ形の魚 5,000 匹を instances に | **鳴る**（2 択の文） | 鳴らない | **鳴る** | — | — | — |
| 同じ形の魚 5,000 匹を MultiMesh に | 鳴らない（MultiMesh の体を数えない） | 鳴らない | 鳴らない | 鳴らない | 鳴らない | 鳴らない |
| 形の違う小物 800 個を instances に | 鳴らない | **鳴る** | 鳴らない | — | — | — |
| マップ全体の草 1 つの MultiMesh（far の 2 倍を超える） | 鳴らない | 鳴らない | 鳴らない | **鳴る** | 鳴らない | 鳴らない |
| 半透明の板の MultiMesh | 鳴らない | 鳴らない | 鳴らない | 鳴らない | **鳴る** | 鳴らない |
| 骨つきの人物の形の MultiMesh | 鳴らない | 鳴らない | 鳴らない | 鳴らない | 鳴らない | **鳴る** |
| 弾の MultiMesh（届かない距離で消す） | 鳴らない | 鳴らない | 鳴らない | 鳴らない（境界が far の 2 倍に届かない） | 鳴らない | 鳴らない |
| 弾の MultiMesh（消さずに撃ち続ける） | 鳴らない | 鳴らない | 鳴らない | **鳴る**（見えない所の弾まで描いている。文に「届かない距離で消す」を入れる） | 鳴らない | 鳴らない |
| ポーズ中に同じ MultiMesh を渡し続ける | 鳴らない | 鳴らない | 鳴らない | 鳴らない | 鳴らない | 鳴らない（② は持ち越しで要らなくなった） |

鳴らさない物と理由:
- **数百個以下の MultiMesh**: 誤りではない（速さは同じか速い）。docs の目安で書く。
- **1 体ずつ選ぶ・光らせる物**: 実行時に意図は分からない。docs の住み分けと agent-eval で受ける。
- **毎コマ材質を作り直すゲームの ①**: ① は材質の参照で数えるので鳴らない。案 1 の使い回しも効かないので、`@static-group-hint`（数だけで鳴る）が受ける。

### 4.3 docs

docs/scene3d.md の「描く量」の頭に、質問の木（葉 3 つ ＝ 口 3 つ）を書く。

1. 動くか → 動かない → `staticGroup`（形が同じ物は描き手が 1 回の draw にまとめて持ち越す）
2. 動く → 同じ形と材質の物がたくさんか（推測: 1,000 体以上・段 4 で決める） → いいえ → `instances`（素直で、1 体ずつ色・材質・名前を変えられる）
3. はい → `MultiMesh3d.build`

一部だけ動く物は、動く物を MultiMesh・残りを staticGroup に分ける。

| 口 | 目安（推測: 段 4 で決める） | 向かない物 |
|---|---|---|
| `instances` | 同じ形が 1,000 体未満・1 体ずつ違う物 | 同じ形の動く物が 1,000 体以上（知らせ ①） |
| `staticGroup` | 動かない物（数の上限は無い） | 毎コマ動く物（毎コマ作り直しになる） |
| `MultiMesh3d` | 同じ形の動く物が 1,000 体以上（群れ・弾・草・雨・火の粉） | 1 体ずつ選ぶ・光らせる・材質を変える物（番号でしか呼べない）・透けて重なる大きな板（不透明で描く）・骨で動く物（バインドポーズで描く）・マップ全体に散らばった 1 つ（区画に分ける）・遠近で細かさ（LOD）を変えたい物 |

ほかの docs:
- docs/performance.md の §12 の表に 1 行・§11 に案 1 の条件を 1 行。
- agents-pack/AGENTS.core.md の早見表に 1 行（木を 1 行に縮めた物）。
- 移行メモ（docs/migrations）は要らない（足すだけで壊れない）。

### 4.4 agent-eval のお題（agents-pack/agent-eval/engine.json・選び間違えたら外れる形）

今あるお題 `static-group-many-buildings`（形が 1 棟ずつ違う建物）・`static-group-room-props`（形が違う小物）と重ならないよう、「同じ形」で動くかどうかだけを替えた組にする。

| id | prompt（依頼の言葉だけ） | expect | avoid |
|---|---|---|---|
| `same-shape-moving` | 同じ形の魚を 5,000 匹、群れで泳がせたい。毎コマ全部が動く。ブラウザでも 60 fps を保ちたい | `MultiMesh3d\.build` | `staticGroup`（打ち消しの無い行） |
| `same-shape-still` | 同じ形の石灯籠を 8,000 基、参道に並べる。遊んでいる間は動かない。毎コマ重い | `staticGroup` | `MultiMesh3d` |
| `few-pickable` | 敵が 40 体いて、弾が当たった 1 体だけを赤く光らせたい | `withTint\|meshInstance` | `MultiMesh3d` |

お題を通すには、早見表の 1 行が木の形になっている事が要る（AI は早見表を引く）。

## 5. やらない事

- **生の並びを受ける口（`of(mesh, Vector[Float64])`）**: `build` より 1 万個で約 1 ms 速いが、長さの誤りを型で止められない。数万個で足りない時に、計った数を添えて相談する。
- **`Mobility` を必須の引数にする形**（2.2）。
- **1 体ずつの視錐台の間引き**: 間引く判定が詰める代金とほぼ同じ（元の内訳で視錐台 2.3 ms）。区画に分ける指針と知らせ ③ で受ける。
- **LOD（遠近で細かさを変える）**: 将来。今は区画ごとに別の形の MultiMesh を載せ替えればよい。
- **半透明の 1 体ずつの並べ替え**: Godot も持たない。4.1 の (a)。
- **影を落とさない指定**: instances にも無い欄なので、MultiMesh だけに足さない（要るなら instances と一緒に材質の欄で相談）。
- **CPU の描き手を速くする事**: CPU は開いて描く。撮りの道具で、描く代金の方が大きい。

## 6. 人に決めてほしい事（推す答えつき）

1. **作る口を `build(mesh, n, i -> Mat4)` だけにするか**（推す: はい。生の並びより 1 万個で約 1 ms 重いが、長さの誤りを書けない）
2. **`Mobility` を採らず、並べる形＋持ち越し＋知らせ＋質問の木にするか**（推す: はい。2.1・2.2 の比べ）
3. **半透明の材質を (a) 不透明として描き、④で知らせるか**（推す: はい。3 つの描き手の絵がそろう）
4. **今の `@static-group-hint` を ① に置き換えるか**（推す: **いいえ。残して文だけ 2 択に**。町の場面（形 30 種）は ① では鳴らず、今の知らせだけが拾う）
5. **知らせ ③ の線を「境界の対角 > カメラの far × 2 が 600 コマ」にするか**（推す: はい。推測の線なので、段 4 で鳴り方を見て直す）
6. **`withColors` を初めから入れるか**（推す: はい。チームの色・弾の色で使う。入れないなら pub は 10）
7. **段 1（案 1）を段 2 より先に別の版で出すか**（推す: はい。今のゲームがそのまま速くなり、MultiMesh の口と独立している）

## 7. 測り方

- **ブラウザ（主）**: `~/Documents/flix_ge_workspace/web_bench/crowd/` の下にゲームを別名で写す。
  - 写し: `flix-spike`＝元の書き方・`flix-spike-mm2`＝毎コマ `build`・`flix-spike-still`＝1 回 `build` して持つ・`flix-spike-group`＝同じ箱を staticGroup で
  - 書き出し: engine の根で `make sync-engine-full-web` の後、`bin/fge export-web <ゲーム> --engine <worktree> --draft --out builds/flix/crowd-spike-<組>`
  - 測り: `VARIANTS="<組…>" NS="<N…>" RUNS=3 run_spike.sh <名前>` で組を交互に流し、`sumspike.py <名前>` で中央値 [最小–最大] を出す（道具は `results/crowd/spike-main/profiles/` に写してある）
  - 元の `results/crowd/raw/` には書かない
- **内訳**: `harness-prof`（webbench に `-profile` の旗を足した写し）で BENCH_PLAY の 3 秒後から CPU のプロファイルを取り、`NAMES=<書き出し>/classes.names profsum.py` で関数の名前に引き当てて、含む時間を ms/コマで出す
- **PC**: bench/scene3d で `make run SCENE=field COUNT=10000 MOVING=100 REPEAT=2 MULTI=0|1 [SHADOW=1]`（`MULTI=1` はスパイクで足したつまみ）。点光源の影は `SCENE=lamps` に MultiMesh のつまみを足して測る。frame は 120 Hz に張り付くので、`cpu_phases` の split・draw と submit で比べる
- **絵**: 描き手ごとに自分自身と比べる（3.6 の段 2 のテスト ①〜③）。ブラウザは `bin/fge web-capture "index.html?n=10000&mode=multi|instances" <png> --dir <書き出し> --dev capture:150[,webgl2]` で SHA が同じかを見る。engine の側は `make gl-capture-check SCENES=scene3d`・`make gl-parity`
- 同じ機械で別の担当が仕事をしているので、比べる組は必ず交互に流し、3 回の幅で読む
