# 初めての 1 回の止まりを消す（staticGroup の計画・後から届く束・骨つき・材質・GC）— 計画（相談用・未着手）

状態: 計画（git に入れない）。engine の v0.112.0 の上。実装はまだ。engine（engine/・render_gl/・engine_world/・engine_web/）に手を入れる段は、どれも着手の前に人へ相談する（AGENTS.md「エンジンを拡張するときは実施前に必ず相談」）。
書き方の約束: **事実**はソースの行（v0.112.0 の main）か実測で裏付けた物。**推測**は「推測:」と書き、どの段の計測で確かめるかを添える。

## 0. 何を解くか

night_school（PS1 風の一人称 3D・WebGPU・M4 Pro）の実測（人から受け取った数字）:

| # | 止まり | 今の値 | 2 回目から |
|---|---|---|---|
| 1 | 動かない物の集まり（`Scene3d.staticGroup`）を初めて描くコマ | 全部の階をまとめて 225 ms（split 213 ms・mesh 137 個を GPU へ）・1 階分で 124〜138 ms（PC） | 0（`Render3d.StaticRows.ensure` の控え） |
| 2 | ブラウザで後から届いた glb の束を受け取ったコマ | ほどく＋組み直しで 130〜170 ms | — |
| 3 | 骨つきの人物が初めて出るコマ | 35 ms（`App.withPreload3d` で形を先に上げても split の 16 ms が残る） | — |
| 4 | 初めて出る材質・形（mesh 1・material 1） | 26 ms 前後 | — |
| 5 | GC の単発 | 20〜30 ms が残りうる（割り当ては 0.112.0 で WebGPU 641→184 MB/s） | — |
| 6 | 字 | 0.111.0 の font-bake で解決済み（参考） | — |

ふだんの 1 コマは PC 2〜5 ms・ブラウザの CPU 約 4.5 ms で余裕がある。残る止まりは「初めての 1 回」だけ。
ゲームは今、遊び始めの 0.25 秒に全部の階を裏で描いて先に払っている（`night_school/src/Res.flix:98-103` の `warmFloorsOf`・`src/View.flix:43` の `withWarmFloors`）。暗転が無いので、この 225 ms は人に見える。

### 0.1 目標（数字）

| 場面 | 機械 | 目標 | 測り方 |
|---|---|---|---|
| 遊んでいる最中（暗転もロゴも無い所）の初めての 1 回 | M4 Pro・PC（JVM・WebGPU の Dawn） | **1 コマ 33 ms 以下**（60 fps の 2 コマ分。1 コマ落ちまでは許す） | `FrameDiagnostics`（`App.withDiagnostics`）の 1 コマの CPU と `cpuPhases`（split・draw・preload）を、決めた手の並び（下の 0.2）で起動し直して 3 回流し、最悪のコマ |
| 同上 | M4 Pro・Chrome（WebGPU・wasm） | **1 コマ 50 ms 以下**（3 コマ分。wasm は JVM の数倍遅いので PC と同じ線は置かない） | 頁の `fgeStats` の 1 コマの cpu の最大（`?fge=fps` が出す値と同じ物）。同じ手で 3 回 |
| 起動・暗転・押した後のロゴの間に払う物 | 両方 | 1 コマの線は置かない。**その間の長さを進み具合で決められる**こと（ゲームが「全部払い終えた」を知れる） | 払い終えるまでの秒を表に出す |
| 毎コマの重さ | 両方 | 悪くしない（今の PC 2〜5 ms・ブラウザ 4.5 ms から 1 割以上増えない。docs/performance.md §3 は速くする直しを採る線で、悪くするのを許す線ではない。その 1 割を許す幅として流用する） | 同上の手で、止まり以外のコマの p50 |

スマホは目標に入れない（測れるのは人に頁を開いてもらう時だけ・docs/web-export.md 461 行）。段 4 の後に 1 回見てもらい、数字を足すだけにする。

### 0.2 測る場（engine の中で再現できる物を先に作る）

engine はゲームに依らずに測れないと、直しの前後を比べられない（docs/performance.md §3「同条件の背中合わせ A/B」）。

- **engine 側**: `bench/scene3d` の `make run SCENE=field GROUP=1`（`bench/scene3d/Makefile` の頭の説明）は、頭の 60 コマを捨てて測る（`RESULTS.md` の頭）。止まりは捨てた 60 コマの中にある。
  そこで **「初めての 1 回」を測る区間**を足す（`FIRST=1`: 物を置かずに 30 コマ回した後、集まりを初めて載せたコマの CPU・split・preload を 1 行の JSON に出す。起動し直して 3 回）。
  形の数を night_school に寄せるつまみ（`SHAPES=137`・`MATS=…`）に加え、**頂点の数**を寄せるつまみ（`VERTS=`・形ごとの頂点の数。SHA-256 と形の作成の重さは頂点の数で決まり、field の箱と柱は頂点が少なく split が小さく出る）で mesh 137 個の場を作る。ブラウザ版は `make bench-web BENCH=scene3d ARGS='scene=field&group=1&first=1'`。
  骨つきの初めて（#3）は同じ bench の room に骨つきを 1 体後から出す区間（`FIRST=skin`）。
- **ゲーム側**: night_school の手の並び（起動 → 1 階を歩く → 2 階へ上がる → 人物に話す）を 1 本、ゲームのリポで録って流す（`POST /perf` と record.flow・docs/performance.md §11）。engine の門には入れない（ゲームは engine の外）。

## 1. 先に調べた事実（ソースの行）

### 1.1 集まりの計画（#1）は 1 コマで全部作る

- `Render3d.StaticRows.ensure`（`render_gl/src/Render3d/StaticRows.flix:149-166`）: 控えに無ければ、その場で `make()` を呼んで全部作る。途中で止めて次のコマへ回す形は無い。
- `make` の中身は WebGPU なら `Render3d.WebGpuStatic.buildCarried`（`WebGpuStatic.flix:75-90`）:
  1. `StaticRows.build`（`StaticRows.flix:64-83`）: 物を候補に分ける（`ScenePlan.groupCarried`・`ScenePlan.flix:171-184`）→ 材質の問い合わせに答える（`resolve`）→ batch → 1 体ごとの値を詰める（`numberSpan`）→ 場面の pass の行と影の地図の行（`buildSceneList`・`buildShadowList`）→ 値の分け合い（`shareSameValues`）→ 形の控え（`slotsOf`）
  2. `resolve` = `WebGpuMaterials.programsFor`（`WebGpuMaterials.flix:201-203`）: 初めての材質はここで program と pipeline を組む
  3. `uploadRows` を 2 回（`WebGpuRows.flix:109-114`）: 初めての形を GPU に作る（`MeshTable.ensure`・`MeshTable.flix:29-38`）
  4. 1 体ごとの値の buffer を作って書く・材質の値の buffer を作る
- これが全部 `Phase.Split` の区間に入る（`WebGpuRenderer.prepare`・`WebGpuRenderer.flix:453-472` の `timed(s, Phase.Split, …)` の中で `WebGpuStatic.carriedOf`）。**「split 213 ms」は計画だけでなく、形を GPU へ作る・材質の program を組む・buffer を書くのを含んだ数**。GL も同じ並び（`Render3d.prepareScenes`・`Render3d.flix:435-477`）。
- 一方、**集まりの絵を GPU へ上げる・描き先の形式ごとの pipeline・render bundle を積むのは `Phase.Draw` の側**（`WebGpuStatic.stage`（`WebGpuStatic.flix:153-160`）の `uploadTexturesAt` を `stageScene`（`WebGpuRenderer.flix:641-672`）が Draw の区間で呼ぶ・`runBundle`（`WebGpuStatic.flix:111-123`））。225 − 213 = 12 ms の多くはこちらと推測。split だけを分けても、この分は初めてのコマに残る。
- 形の中身の鍵を SHA-256 で取らない道は engine に**既にある**: `Gltf.fromGlbKeyed`（`engine/src/scene3d/Gltf.flix:60-66`）が `Mesh3d.withContentKey`（`Mesh3d.flix:531`）で鍵を呼ぶ側の key（ブラウザは `ImageDecoder#versionedKey`・`WebLayer.flix:631`）から作る（WhyNot「ブラウザでは 1 部屋の形 3 つで 30 ms を超え」）。ただし**絵つきの道（`fromGlbTexturedUsingOptions`）に keyed の版が無く**、night_school はこちらを使う（`night_school/src/Bundles.flix:62`）。
- `slotsOf` → `MeshTable.slotOf`（`MeshTable.flix:41-51`）→ `Mesh3d.contentHash`（`Mesh3d.flix:525-526`）は **遅延の SHA-256**（`force recOf(m)#hash`）。glb から読んだ形は、初めて描くコマで頂点の全部を SHA-256 に通す。ブラウザでは SHA-256 は TeaVM の classlib に足した純粋な Java（`engine_web/teavm/java/org/teavm/classlib/java/security/TMessageDigest.java`）で、wasm で回る。
- 視錐台で間引かない（`StaticRows.flix:5` の WhyNot）。集まり 1 つは目の位置に依らず全部を一度に作る。
- 作る時、同じ名前の控えのうち今のコマで使っていない物はすぐ手放す（`StaticRows.flix:158-159`）。**作り直しの間に前の絵を描き続ける**形は今は無い。
- 推測: 213 ms の内訳（候補分け・SHA-256・pipeline・形の作成・値の詰め）は分かっていない。段 0 で測る。

### 1.2 `App.withPreload3d` は集まりの計画を作らない（#1・#3・#4）

- 宣言の型 `Scene3d.PreloadCmd`（`engine/src/scene3d/Scene3d.flix:1160-1164`）= key・instances・textures・variants。**集まり（`StaticGroup`）を渡す欄が無い**。
- WebGPU の `preloadCmd`（`WebGpuRenderer.flix:417-444`）は、形を GPU に作り、材質の program と pipeline を組む。ただし pipeline は **画面の形式（`Rgba8Unorm`）・標本 1・色の pass の物だけ**（`WebGpuRenderer.flix:404-405` の WhyNot「描き先の形式と標本は場面ごとに決まり、宣言の時には分からない」）。場面が別の形式・標本・影の地図の pass で描くと、初めて描くコマで組む。
- `StaticRows.build` の行・1 体ごとの値・`ensure` の控えは、preload では作らない（`preloadCmd` は `StaticRows` を呼ばない）。だから「形を先に上げても split の 16 ms が残る」（#3）。骨つきの物は集まりに入らず毎コマ場面の計画へ通る（`StaticRows.flix:21-22`）ので、#3 の 16 ms は推測: 骨つきの版の pipeline（場面の形式・影の pass の版）と姿勢の行の初回の割り当て。段 0 で確かめる。
- GL の `Render3d.Preload.upload`（`render_gl/src/Render3d/Preload.flix:15-23`）も同じく集まりを知らない。
- `fge.webgpu.WebGpu`（`render_gl/java/fge/webgpu/WebGpu.java:57`）は `createRenderPipeline` だけで、async の版を持たない。わざと使わない WhyNot がある（`engine_web/java/fge/web/webgpu/BrowserWebGpu.java:293`「createRenderPipelineAsync を待たない — 誤りの道が Dawn の側と分かれ、errorCount で拾えなくなる」）。
- preload の骨つきの pipeline は形にジョイントがある時だけ・画面の形式と標本 1 だけ（`preloadShape`・`WebGpuRenderer.flix:446-449`）。

### 1.3 束が届いた時（#2）: ほどく・組み直す・計画し直す、の 3 つが続けて来る

- ゲームは束を `BackgroundLoad` の鍵で解く（`night_school/src/Bundles.flix` の `group`・`costMs = 120`）。解いた後、`Res.withLoaded`（`src/Res.flix:76-90`）が物の替わった階の集まりを組み直す（新しい `staticGroup` の値）。
  → 次のコマで、その階の集まりは `ensure` の控えに当たらず、**1.1 の計画をもう一度作る**（ゲームは `warmAt` で 0.25 秒裏で描いて先に払う・`Res.flix:98-103`）。人の言う「130〜170 ms」は解く＋組み直しで、その後に計画のし直しがもう 1 回来る（推測: 階 1 つ分 = PC で 124〜138 ms・wasm でその数倍。段 0 でブラウザの値を測る）。
- ブラウザの読み込みの handler は仕事を順に流す（`engine_web/src/WebLayer.flix:620-629` の `handleLoadProgress`・`runTasksInOrder`・doc「ブラウザの wasm は 1 本の糸」）。`BackgroundLoad` の解きもループの中の本体の糸で回る（docs/startup.md「ループの中で区切って読む」）。
- **glb の中の絵の解き方**（事実）: `WebLayer.decodeImage`（`WebLayer.flix:640-645`）→ `WebImages.decode`（`engine_web/java/fge/web/WebImages.java` の `decode`）:
  1. wasm の `byte[]` を JS の `Int8Array` へ写す（`Int8Array.copyFromJavaArray`）
  2. `fgeDecodeImage`（`engine_web/js/fge-web.js:215-238`）が `createImageBitmap` で解く（ブラウザの裏の糸）。**待つ間は `@Async` でゲームのループごと止まる**（`WebImages.java` の doc「解き終わるまでゲームのループごと止まる（待つ間はブラウザへ手を返す）」）
  3. `fgeBitmapArgb`（`fge-web.js:193-206`）が `new OffscreenCanvas(1, 1).getContext("webgl2")`（`fge-web.js:186-187`）へ `texImage2D` し、`fgeReadGlTextureArgb` で読み戻す（本体の糸・GPU を待つ）
  4. `Int32Array` → direct buffer → `int[]` → `Array.toVector`（`WebLayer.flix:644`）と 3 回写す
  5. その画素から `Texture3d` を作り（`Texture3d.fromArgb` が `hashOf` で画素の SHA-256 から鍵を作る・`Texture3d.flix:36-39`）、描く時にもう一度 GPU へ上げる。engine 自身が `Texture3d.decodeAtUsing` の WhyNot（`Texture3d.flix:62-63`）に「読み戻し＋SHA-256 で 1 枚 50 ms ほど止まる」と書いている
  つまり glb の中の絵は「ブラウザが GPU 向けに解いた物を GPU から読み戻して wasm へ運び、また GPU へ上げる」往復をしている。
- 道で指す絵（project.json の textures・後回しの画像）は、届いた時に JS が `createImageBitmap` で解いて `fgeImages` に持ち（`fge-web.js:2014-2035` の `fgeDeferredReceive`）、画素を wasm へ運ばずに GPU へ上げる（`WebImages.java` の頭・`ImageData.ImageDecoder#platformImage`・`Texture3d.fromPlatformImage`（`Texture3d.flix:41-45`））。**③ の createImageBitmap はもう使っている。足りないのは glb の中の絵だけ**。
  推測: night_school の束の絵が glb の中か外か（`tools/glb_bundle.py` の作り方）で、この往復が #2 に占める割合が変わる。段 0 で `?fge=loadtime` の `[loadtime] decode` の行（`fge-web.js:216-226`）を数える。
- 後回しの素材のバイトは `fgeFetchBytes`（`fge-web.js:1735-1758`）が `res.arrayBuffer()` で全部届いてから受け取る（ReadableStream で途中から読まない）。glb は素材の表（`fgeAssets`）に生のバイトで置かれ、wasm が読む時に `AssetTable.bytes`（`engine_web/java/fge/web/AssetTable.java`）の `copyToJavaArray` で wasm へ写す。
- wasm は TeaVM の wasm-gc（`fge-web.js:2126-2144` の `TeaVM.wasmGC.load`）。night_school の `classes.wasm` は 9.77 MB（brotli 1.42 MB・`build/mb-web-noblur/`）。

### 1.4 GC（#5）の残りの割り当て（人から受け取った内訳と、その在りか）

| 割り当て | 割合 | 在りか |
|---|---|---|
| GL の行ごとの絵の鍵の字づくり | 約 15% | `Render3d.Material.texture3dBound`（`Material.flix:350-368`）が毎回 `sceneTextureKey`（`Material.flix:370`: `contentHash + ":" + mipKeyOf`）で字をつなぐ |
| WebGPU の `stageScene` と持ち越した行で upload の控えを分け合う | — | `WebGpuRenderer.stageScene`（`WebGpuRenderer.flix:641-672`）・`WebGpuStatic.stage`（`WebGpuStatic.flix:153-160`） |
| 2D の `ShaderDoc.texNames` / `paramNames` | 約 3% | `ShaderDoc.flix:506-509`・`532-534`（毎回 List を作る） |
| F8 で止めた時の `BootFont.atlas` の作り直し | 約 9% | `BootFont.flix:25-33`（呼ぶたびに `decodeGlyphs()`） |

## 2. 候補の案（原因ごと）

各案に: 何が変わるか・効く止まり・見込み（根拠）・大きさ（実時間）・危険・テストと 0 px の確かめ・ゲーム側の変更。
大きさの根拠にする直近の実績: 0.112.0 の割り当て減らし（`4ea21ff2b`）が約 2 時間・0.111.0 の font-bake をデスクトップへ（`757535d25`）が半日弱・staticGroup そのものの見積もりが 4〜6 時間（`plans/engine-static-group.md`）。

### (a) 集まりの計画を数コマに分けて進める（時間の予算で切る）

**変わる物**: `StaticRows.ensure` が「無ければ全部作る」から「無ければ作り始め、このコマの予算（ms）を使い切ったら次のコマへ続きを回す」になる。作りかけの物を控えに持つ（`Entry` に作りかけの状態）。

仕事の切り方（どこで止められるか）:
1. 候補分け（`groupCarried`）: 物の並びを頭から N 個ずつ進める。今は 1 回で並び全体を `groupWith` に通すので、途中の状態（候補の表・問い合わせ・`members`）を持ち回る形に替える
2. 形を GPU に作る（`uploadRows`）: 形 1 つずつ止められる（`MeshTable.ensure` は 1 形ずつ）。SHA-256（`contentHash`）もここで 1 形ずつ払う
3. 材質の pipeline（`programsFor`）: 材質 1 つずつ止められる
4. 値を詰める・行を作る・buffer を書く: 最後に 1 回（行の並びは候補分けが全部済まないと決まらない）。推測: ここは数 ms。段 0 で確かめる

**途中の絵をどう見せるか**（ここが案の要）:

| 場合 | 見せ方 | 0 px |
|---|---|---|
| 作り直し（同じ名前の前の控えがある・束が届いた後の階など） | **前の控えを描き続け**、新しい物ができたコマで差し替える（`StaticRows.flix:158-159` の「使っていない物はすぐ手放す」を「新しい物ができるまで残す」へ） | 作り終えたコマからは同じ。途中のコマは前の絵（ゲームが望んだ新しい絵とは違う） |
| 初めて（前の控えが無い）で、その集まりが今見えている | **今まで通り 1 コマで全部作る**（分けない） | 今と同じ |
| 初めてで、裏で作らせている（(c) の先払い） | 分けて作る。描かない | 描かないので差は無い |

WhyNot（11-25 に決めた範囲）: 前の控えを描きながら分けて作るのは **items の値そのものが替わった時**（staticGroup を作り直した・束が届いた階）だけにする。同じ items の値で withoutItems / withGroupTint だけが替わった時は今まで通り 1 コマで作る — 拾って消した小物が PC で数コマ・ブラウザで 1〜2 秒残って見え（手に持った物と二重になる）、消した物が残る方が害が大きい。

「初めてで見えている物を分けて、できた所から出す」（物が次々に現れる）はしない。半分だけの校舎は壊れた絵で、5 性質の「形が物として読める」を崩す。初めてを見えないうちに済ませるのは (c) の仕事に回す。

- **効く止まり**: #1 の作り直しの分（束が届いた後の階・#2 の後半）と、(c) と組んで #1 の初めての分
- **見込み**: 1 コマの予算を 8 ms（PC）にすると、213 ms は約 27 コマ（0.45 秒）に散る。1 コマの止まりは「予算 + 止められない最後の仕事」。推測: 最後の仕事（値の詰め・行づくり）が 5〜10 ms なら PC で 1 コマ 20 ms 以下。ただし Draw の側の初回（集まりの絵を GPU へ上げる・場面の形式の pipeline・bundle を積む・1.1）は split の外にあり、そのままでは作り終えたコマに乗る。絵も 1 枚ずつ予算の内で先に上げる区切り（`WebGpuMaterials.uploadTexturesAt` を作りかけの間に回す）を (a) に含める。ブラウザは同じ予算で数倍のコマ数（1 秒〜2 秒）。根拠は段 0 の内訳待ち
- **大きさ**: 4〜6 時間（作りかけの状態を持ち回る形への書き換えが中心・GL と WebGPU の両方）
- **危険**:
  - **置き場が何か 1 つでも捨てると、控えを全部捨てる**（`WebGpuStatic.endFrame` の `evicted` → `StaticRows.clear`・`WebGpuStatic.flix:174-180`）。作りかけも捨てて頭からやり直すだけでなく、次のコマで**見えている集まりが全部「初めてで見えている物」になり、1 コマで全部作る** = 今の 225 ms が遊んでいる途中に戻る。段 0 で night_school の手の並びで evicted が起きる回数を数え、起きるなら (a) の範囲で「作り直しの間は前の控え」に当てられないか（番号が別の物を指すので前の控えは描けない）を相談する。(c) で全部の階を持つと置き場の上限に当たりやすくなる（(c) の危険）
  - 前の控えを残すと GPU のメモリが 2 つ分になる時間ができる（階 1 つ分の buffer）
  - 同じ集まりを 2 つの場面で描く時（色の場面と奥行きの書き出し）の `variant` ごとの作りかけ
  - 予算の時計: 1 コマの残りの時間は描き手には分からない。最初は固定の値（private・PC 8 ms 相当）で始め、World から渡す形（`App.withDecodeBudget` と同じ）は pub が増えるので (c) と一緒に相談する
- **テストと 0 px**: 作り終えたコマの絵が「1 コマで作った時」と 1 bit も同じ（`render_gl/test/TestStaticRows.flix` に、予算 0.001 ms で何コマもかけて作った行と 1 回で作った行の値の一致を足す・`bench/gl_parity` に分けて作った場面の対）。作り直しの途中のコマが前の絵と同じ（テストで前の行が描かれる事を見る）。gallery は変わらない（描き出しは予算を持たず 1 コマで作る・headless の道は分けない）
- **ゲーム側**: 無し（作り直しは自動で前の絵を出す）。night_school の `warmAt` の裏描き（`Res.flix:98-103`）は不要になる

### (b) 計画を書き出し・ビルドの時に済ませて束に入れる

**何を保存できるか**（事実から）:
- GPU の物（buffer・pipeline・bundle）は書き出しの時に作れない（機械と描き手ごとに違う）。保存できるのは CPU の答えだけ: 形の中身の鍵（SHA-256）・候補分けの答え（どの物がどの batch か）・1 体ごとの値の詰めたバイト。
- ところが集まりの中身は**ゲームのコードが実行時に組む**（`night_school/src/School.flix:245` の `Scene3d.staticGroup(tag, …)` は Doc の配置と glb の形から作る）。書き出しの時に同じ物を作るには、ゲームの読み込みを headless で流して集まりを取り出す必要がある（font-bake が src の字を集めるのとは違い、値を作るにはゲームを走らせる）。
- 保存した答えが今の集まりと同じかを確かめる鍵が要る（中身を比べると、省きたい仕事と同じ重さになる・`StaticRows.flix:133` の WhyNot と同じ理由）。

**効く止まり**: #1 の CPU の分だけ。形を GPU に作る・pipeline を組むのは残る。
**見込み**: 推測: 213 ms のうち CPU の候補分けと SHA-256 が半分なら、残りは 100 ms 前後。単独では目標に届かない。
**一部だけ取る安い版 (b')**: **形の SHA-256 を払わない**。engine には既に `Gltf.fromGlbKeyed`（`Gltf.flix:60-66`）があり、形の鍵を呼ぶ側の key から作る（1.1）。足りないのは絵つきの道（`fromGlbTexturedUsingOptions`）の keyed の版だけなので、`fromGlbTexturedKeyedUsingOptions(key, decoder, options, bytes)` を足す（今ある形は変えない）。
- WhyNot（`Gltf.LoadOptions` に `contentKey` の欄を足さない）: pub の型に欄を足すのは変更（docs/performance.md §1）で、レコードを全部書いたゲームが壊れる。ブラウザのゲームは `decoder#versionedKey(道)` を渡す。
- WhyNot（形を解く時に `force` して先に払う案を採らない）: `BackgroundLoad` の 1 鍵は 1 コマで解き切るので、ブラウザでは #2 の 130〜170 ms のコマがさらに重くなる。払わない道がある以上、払う所を移す意味が無い
- 鍵の約束: デスクトップの開発中のファイルは読み直しで中身が変わるので key にしない（`Mesh3d.flix:530` の WhyNot）。`versionedKey` はデスクトップで None を返す（`ImageData.flix:13-20`）ので、None の時は今の SHA-256 のまま
- 効く止まり: #1 と #2 の後半の SHA-256 の分（推測: 形の頂点の総数しだい。`Gltf.fromGlbKeyed` の WhyNot の「形 3 つで 30 ms」から、137 個の形なら数十〜百 ms 台もありうる。段 0 で測る）。ブラウザで大きく、PC で小さい
- 大きさ: 1〜1.5 時間（欄 1 つ・`TestGltf.testFromGlbKeyed*` と同じ形のテスト = 鍵が key だけで決まる事）
- pub を 1 つ足す（関数）ので相談の対象（5 節の 9）
- 危険: 呼ぶ側が同じ key で違うバイトを渡すと、前の形を使い続ける（約束は doc に書く。ブラウザの書き出しの道と版なら守られる）
- ゲーム側: night_school の `Bundles.group` の decode に key を 1 つ渡す（1 行）
- **(b) の本体はしない**（ゲームを書き出しの時に走らせる仕組みが大きく、得が CPU の半分に留まる。(c) で起動の間に払えば同じ効果）。(b') は段 1 で先に入れる

### (c) 起動・暗転の間に先に払う口（`App.withPreload3d` の拡張）

**変わる物**: 先に上げる宣言に、集まりと場面の描き先の形を足す。描き手は宣言を受けたら、集まりの計画（`StaticRows.ensure` と同じ控え）・骨つきの版・場面の形式と標本と影の pass の pipeline まで作る。1 コマで全部やらず、(a) の予算で数コマに分けて進め、**進み具合（済んだ数 / 全体）をゲームへ返す**。

形の案（相談で決める・pub の型が増える）:

```flix
App.withPreload3d({ groups = w -> School.groupsOf(res),            // 先に計画を作る集まり（同じ値を毎コマ渡す）
                    scenes = w -> SchoolView.sceneShapeOf(res) :: Nil, // 描き先の形（Output・変種・解像度・形式・標本・影の有無）を決める場面
                    textures = .., variants = ..
                    | App.preload3d(key, instances) })

// ゲームは進み具合を読む（例: 暗転を明けるのを待つ・押した後のロゴの長さ）
frame#preload3d    // { done = Int32, total = Int32 }（全部済めば done == total）
```

- 集まりの計画の控えの鍵は場面の決め方（`carriedKeyOf`・`StaticRows.flix:43-48` = Output・変種・alpha to coverage）で引くので、宣言に「どの場面で描くか」が要る。`PreloadVariant`（`Scene3d.flix:1170-1172`）は変種しか持たない。場面そのもの（`Scene3dCmd`）を渡す形が一番ずれない（推測: `contextOf`（`SceneList.flix:53-56`）が場面の textures と時刻を読むので、場面の値が要る）
- pipeline は場面の解像度・形式・標本で決まる（`WebGpuRenderer.flix:404-405` の WhyNot が「宣言の時には分からない」と言った物）。場面を渡せば分かる
- 進み具合を返す所は ゲームが毎コマ受け取る frame に欄を 1 つ（pub を足す = docs/performance.md §1 の pub 不変の門。相談に入れる）か、`FrameDiagnostics` に載せる（診断を付けたゲームだけ読める・本番で読めない）か。前者を推す
- **効く止まり**: #1 の初めて（起動の間に全部の階）・#3（骨つきの版を場面の形で組む）・#4（場面の形式の pipeline）。#2 の後半（束の後の計画し直し）は、ゲームが届いた階の集まりを宣言へ足せば裏で進む（(a) と同じ道）
- **見込み**: 起動の間に払えれば遊んでいる最中は 0。night_school は暗転が無いが、「押した後のロゴ」（docs/startup.md の splash）か、タイトルから遊びへ移る暗転を 0.5〜1 秒置けば、PC の 225 ms は 1 コマ 8 ms の予算で 28 コマ（0.47 秒）に収まる。ブラウザは推測: 数倍で 1.5〜2 秒。押した後のロゴの上限 3 秒（`web.splash.maxSeconds`）に収まる見込みだが、段 0 のブラウザの値で確かめる
- **大きさ**: 5〜7 時間（宣言の型・App の中継（`App.Internal.Paint.preloadCmd`）・GL と WebGPU の両方の preload・進み具合の欄・docs/scene3d.md の「初めて出る物を先に上げる」）。(a) の作りかけの仕組みを使う前提（(a) の後）
- **危険**:
  - 宣言の key が毎コマ変わると毎コマ作り直す（今も `Preload.noteRebuild` が知らせる・`Preload.flix:31-36`。集まりも同じ知らせに乗せる）
  - 先に作った集まりの控えが、遊んでいる間に描かれず `idleFrames`（128 コマ・`WebGpuStatic.flix:67`）で捨てられる。宣言にある間は捨てない（今の preload の「上げた物は置き場の上限で捨てられにくくなる」と同じ扱い）
  - 階を全部持つとメモリが増える（今も warm で全部描いているので、増えるのは「捨てない」分だけ）
  - 置き場の上限: 宣言の物を捨てないと、上限に当たった時に `evicted` → 控えを全部捨てる（(a) の危険）が起きやすい。宣言の物を捨てる候補から外し、宣言の合計が上限を超える時は宣言の時に 1 行知らせる（決めるのは相談）
  - **計画を持たない描き手**（headless の描き出し・SoftRaster・`Scene3dRenderer.none()`・テストの描き手）は**最初のコマから done == total を返す**。そうしないと、進み具合を待って暗転を明けるゲームが gallery とテストで一生明けない。宣言の key が途中で替わったら done と total を 0 から数え直す（替わる前に済んだ物は控えに当たるので、数え直しは速く進む）
- **テストと 0 px**: 宣言で先に作った後の最初のコマで `Phase.Split` が数 ms に落ちる事（`render_gl/test/TestWebGpuStaticDawn.flix` に、preload の後の最初のコマで `ensure` が作らない事 = `recordedCountOf`・作った回数で見る）。絵は preload の有無で同じ（gallery の SHA は変わらない・preload は描かない）。計画を持たない描き手で最初のコマから done == total（テスト）
- **ゲーム側**: night_school は `withWarmFloors`（`src/View.flix:43`）と `warmFloorsOf` をやめ、`withPreload3d` に階の集まりと場面を渡す。押した後か遊び始めに短い暗転を置き、`frame#preload3d` が済むまで明けない（演出はゲームが決める）

### (d) ブラウザの束のほどき（#2）

人の質問に合わせ、4 つの手段を比べる。先に**境目の事実**:

- wasm（TeaVM の wasm-gc）は頁の本体の糸で 1 つだけ動く（`fge-web.js:2126-2144`・`WebLayer.flix:620-629` の「1 本の糸」）。ゲームの値（`Model3d`・`Mesh3d`・`Texture3d` は Flix の値 = wasm-gc の GC の物）は**この wasm の中でしか作れない**。別の糸で作った物を渡す時は、型つきの配列（`ArrayBuffer`）にして運び、本体の wasm が受け取って Flix の値に組み直す。
- JS から wasm-gc への受け渡しは今も写しになる（`AssetTable.bytes` の `copyToJavaArray`・`WebImages.decode` の 3 回の写し・1.3）。wasm-gc の配列は `ArrayBuffer` を共有できない（線形メモリを持たない）。
- JS の側にある物（届いたバイト `fgeAssets`・解いた絵 `fgeImages` の ImageBitmap）は、JS だけで別の糸へ渡せる。

| 手段 | 何を別の糸へ出すか | 本体の糸に残る物 | 効く分 | 大きさ | 危険・制約 |
|---|---|---|---|---|---|
| **① Web Worker で glb をほどく** | glb の JSON を読む・accessor から頂点と番号の型つき配列を切り出す・形の SHA-256（ただし (b') で消える）。中の絵の `createImageBitmap` は今も本体の糸の外で解かれる（1.3）ので、Worker へ移しても縮まない。`ArrayBuffer` は transferable で 0 コピーで本体の JS へ返す | JS → wasm-gc への写し（頂点と番号のバイト）・`Mesh3d`・`Model3d` を組む・絵を GPU へ上げる | glb の構文を読む分だけ（SHA-256 は (b')・絵は ③' で別に消える）。推測: (b') と ③' の後に残る #2 の一部。段 0 と段 4 の後の内訳で決める | **Worker を JS で書く**: 1〜1.5 日（Gltf の読み方を JS へ 2 本目として書く＝同じ読み方が Flix と JS の 2 か所になる。デスクトップは Flix の `Gltf` のまま）。**wasm をもう 1 つ起こす**: 2〜3 日 | JS で書くと、Flix の `Gltf` と結果がずれる危険（頂点の並び・法線の作り方・頂点の色）→ 両方で同じ glb を読んで値の一致を見るテストが要る。wasm をもう 1 つ起こすと、compile 済みの `WebAssembly.Module` は postMessage で Worker へ渡せる（compile はやり直さない）が、instance と GC のヒープは 2 つ目が要り（推測: メモリが大きく増える・9.77 MB の wasm の初期化）・Worker 用の入口（main 以外）を TeaVM に作る。どちらも `Platform.Services` の handler の外の新しい道 |
| **② fetch の ReadableStream** | 届く途中から読み進める（ダウンロードとほどきを重ねる） | ほどき全部 | **止まりには効かない**: 後回しの束は遊んでいる裏で届き、ほどくのは届いた後の `BackgroundLoad` の予算の中（docs/startup.md）。重ねて縮むのは「届くまでの秒」で、1 コマの重さではない。押した後の待ち（plans/web-loading-p5.md の門の数字）には効く | 半日 | gzip の束は今 `DecompressionStream` に Blob ごと通す（`fge-web.js:1771`）。glb は全体の JSON の後に BIN が来るので、途中から形を作れるのは BIN が届いてから |
| **③ createImageBitmap** | 絵の解き | — | **もう使っている**（道の絵・後回しの絵・glb の中の絵の全部・1.3）。足りないのは **glb の中の絵を GPU から読み戻して wasm へ運ぶ往復**（`fgeBitmapArgb` の `readPixels`・3 回の写し・`Texture3d` の SHA-256・GPU へ上げ直し）。**③' glb の中の絵も ImageBitmap のまま JS に持ち、`platformImage` と同じ道（`Texture3d.fromPlatformImage`）で GPU へ直に上げる**。中身の鍵は glb のバイトの位置と束の版から作る（`versionedKey` と同じ約束） | 読み戻し・写し 3 回・SHA-256 が消える。`@Async` で止まる時間（`createImageBitmap` を待つ間ループが止まる）も、届いた時に JS で先に解いておけば消える（`fgeDeferredReceive` が道の絵にしている事を glb の中の絵にも） | 3〜5 時間（`ImageData.ImageDecoder` に「バイトから機種の側の絵を作る」口を 1 つ足す・`Gltf` がそれを使う・WebGPU と WebGL2 の両方の上げ方） | mipmap: 画素を持たない絵の mipmap を GPU で作る道（`gl.prefersGpuMipmap`・`WebGpuMipmaps`）が glb の絵の材質の使い方（sRGB・法線の絵）で同じ結果になるか。CPU の描き手（SoftRaster）とデスクトップは今まで通り画素で持つ（ブラウザだけの道）。画素を読まないので「絵の中身を見る」処理（alpha の有無で cutout を決める等）があれば壊れる → 段 0 で `Texture3d` の画素を読む所を `refactor usages` で洗う。**`Texture3d.limitSize`（`Texture3d.flix:86-99`）は機種の側の絵を縮めずに 1 行言うだけ**で、`Gltf.fromGlbTexturedBy` は glb の絵に必ず掛ける → `TextureLimits` を指定したゲームの glb の絵が上限を超えたまま上がり `scene3dTextureBudgetMB` を食う。決まり: 上限より大きい glb の絵は画素の道へ戻す（書き出しの時に縮めるのは別の計画）。night_school は `noTextureLimits` なので今は当たらない |
| **④ OffscreenCanvas と WebGPU を Worker で（描き手ごと移す）** | wasm 全体（ゲームのループ・描き手）を Worker へ。本体の糸は入力と音を中継するだけ | 入力・音・頁の UI | 本体の糸が止まらなくなる（頁のスクロールやロゴは滑らか）。ただし**ゲームのコマ自体は同じだけ止まる**（同じ wasm が同じ仕事をする）ので、#1〜#4 の止まりは消えない | 1〜2 週 | Worker では Gamepad API・WebAudio（AudioContext）・localStorage が使えない → 入力・音・セーブを本体の糸と行き来する中継が要る（`Platform.Services` の handler を全部 2 段にする）。`fge-web.js` の 2,444 行の多くが本体の糸の前提。得が「頁が固まらない」だけで、今の問題（ゲームのコマの止まり）に効かない |

**SharedArrayBuffer の制約**: 糸の間でメモリを分け合う `SharedArrayBuffer` は、頁に COOP/COEP のヘッダー（`Cross-Origin-Opener-Policy: same-origin`・`Cross-Origin-Embedder-Policy: require-corp` か `credentialless`）が要る。GitHub Pages ではヘッダーを付けられない。Service Worker が応答にヘッダーを足す手はある（coi-serviceworker の形）が、初めて開いた時は Service Worker がまだ効かず 1 回読み直しが要り、今の Service Worker（`fge-sw.js`・docs/web-export.md「起動の始まりと 2 回目からの起動」）の登録の遅らせ（`fge-web.js:2370` の WhyNot）とぶつかる。さらに wasm-gc の配列は SharedArrayBuffer に置けないので、分け合えても本体の wasm へは写しが残る。**この計画では SharedArrayBuffer を使わない**（transferable の 0 コピーで足りる所までにする）。

**今の handler との関係**: 機種の切れ目は `LoadProgress`（`imageDecoder`・`downloads`）と `Platform.Services`（docs/flix-conventions.md「層を置く物差し」）。③' は `ImageData.ImageDecoder` に口を 1 つ足すだけで、実装はブラウザ（ImageBitmap）とデスクトップ（今の画素の道）の 2 つになり、物差しに沿う。① は「glb をほどく」の 2 本目の実装（JS）を作ることになり、Flix の `Gltf` と同じ答えを 2 か所で保つ代金を払う。

**推し**: **(b')（形の SHA-256 を払わない keyed の道）と ③' を先にやる**。① は ③' の後に段 0 の内訳で「glb の構文を読むのが #2 の何割か」を見て、3 割を超えた時だけ相談する。②は止まりの計画から外し、押した後の待ちの計画（plans/web-loading-p5.md）へ回す。④ はしない。

- **効く止まり**: #2 の前半（ほどく）。後半（計画し直し）は (a)(c)
- **見込み**: 推測: 束 1 つの絵が数枚の 1024 角なら、読み戻しと 3 回の写しと SHA-256 で数十 ms（1024 角 1 枚 = 4 MB を 4 回写す + 4 MB の SHA-256 を wasm で）。段 0 で `[loadtime] decode` の ms と枚数を取ってから見込みを書き直す
- **テストと 0 px**: ③' はブラウザだけの道なので gallery（headless・JVM）は変わらない。`web-capture --dev capture:6,deferred:all`（docs/startup.md 125 行）で、③' の前後の頁の画素を比べる（0 px を求める。mipmap の作り方で差が出たら入れる前に止めて人へ）
- **ゲーム側**: 無し（`Gltf.fromGlbTexturedUsingOptions` を今まで通り呼ぶ）

### (e) 残りの割り当て（#5）

| 直し | 判定（docs/performance.md §2） | 大きさ |
|---|---|---|
| GL の `sceneTextureKey` を毎回つながない: 絵の中身の鍵と mip の鍵の組を `Texture3d` ごと・コマごとに 1 回作って持ち回る（字でなく組 `(String, String)` を表の鍵にする案も） | 3-b（表の鍵の形が変わる）。測る | 1〜2 時間 |
| WebGPU の `stageScene` と `WebGpuStatic.stage` の upload の控えを分け合う（同じコマに同じ絵を 2 回調べない） | 3-b | 1〜2 時間 |
| `ShaderDoc.texNames` / `paramNames` を Spec ごとに 1 回（Spec を作る時に持たせるか、描き手の側の控え） | 3-a に近い（値を 1 回だけ計算して持ち回る）。ただし pub の型に欄を足すなら pub 不変の門 | 1 時間 |
| `BootFont.atlas` を 1 回だけ作る（`Lazy` の top-level の値） | 3-a（値を 1 回だけ計算） | 30 分 |

- **効く止まり**: #5。F8 の分は遊ぶ人の止まりではない（作る人が止めた時だけ）が、3-a なので無条件でやる
- **見込み**: 15% の `sceneTextureKey` は **GL の描き手の物**（`Material.flix:370`）で、WebGPU の night_school の 184 MB/s は減らない。9% の `BootFont.atlas` は F8 で止めた時だけで、遊んでいる最中の割り当てではない。**遊んでいる WebGPU で効くのは `ShaderDoc` の約 3% と、upload の控えの分け合い（割合は段 0 で測る）だけ**。つまり #5 への効きは小さく、段 5 の GL の直しは「GL で描くゲーム（WebGPU の無いブラウザと PC の fallback）向け」。足切り（§3）は「avg か p99 が 1 割」なので、p99 を測って届かなければ 3-b の物はやめて docs/backlog.md に残す
- **テストと 0 px**: 絵は変わらない（鍵の作り方だけ）。gallery の SHA と `make gl-parity`。割り当ては docs/performance.md §5「割り当てバイトで測る」で前後を比べる

### (f) 骨つき・材質の初めて（#3・#4）の小さな直し — (c) に入る

#3・#4 は (c) の「場面の形で pipeline を組む」で消える見込み。(c) を待たずに効かせる手は無い（今の `withPreload3d` は場面の形式を知らない・1.2）。段 0 で、#3 の 16 ms・#4 の 26 ms の中身が pipeline か、それ以外（姿勢の行の初回の buffer・形の SHA-256）かを分ける。pipeline 以外（形の SHA-256 なら (b')・姿勢の行の初回の buffer なら preload で先に作る）で片付く。

## 3. 推奨の順番と段

docs/performance.md の「予算の門」（遊ぶ人 × 1 回だけ = 「1 フレームぶんを丸ごと使ってよいが、超えるならフレームを分けて分割する」）に沿い、**分ける (a)・先に払う (c)・往復を消す (d③')** の順にする。
層は足さない: (a)(c) は今の `StaticRows`（前半）と backend 2 つ（`WebGpuStatic`・`GlStatic`）の中で閉じる。(d③') は `ImageData.ImageDecoder` という既にある機種の口に 1 つ足す（実装はブラウザとデスクトップの 2 つ）。

| 段 | 中身 | 緑とする測り | 大きさ |
|---|---|---|---|
| **0. 測る** | `bench/scene3d` に `FIRST=1`・`FIRST=skin` の区間（0.2）。`Phase.Split` の中を一時的に細かく分けて測る（候補分け・SHA-256・program・形の作成・値の詰め・buffer）。**Draw の側の初回**（集まりの絵の作成と mip・場面の形式の pipeline・bundle の積み）も分ける。#3 は「骨つきの pipeline（`preloadShape` が作らない形式・影の pass）」と「姿勢の行の初回」を名指しで分ける。night_school の手の並びで `evicted`（置き場が捨てた）が起きる回数を数える。ブラウザで `?fge=loadtime` の decode の行と、束が届いたコマの内訳。結果を本書の 1.1・1.3 の「推測」に書き戻し、段 2 以降の見込みを直す。段 1 の (b') を先に入れてから測ると残りの内訳が読みやすい（どちらが先でもよい） | 内訳の表が埋まる（PC とブラウザ・3 回ずつ）。細かい区間の計測はコミットに残さない（`FrameDiagnostics` の区間を増やすかは相談） | 1.5〜2 時間 |
| **1. 安い物** | (b') 絵つきの glb の道に keyed の版（形の SHA-256 を払わない）・(e) の 3-a の 2 つ（`BootFont.atlas`・`texNames`/`paramNames` の控えのうち pub を変えない形）。段 0 の前に入れると、残りの内訳が読みやすい | `FIRST=1`（keyed の形）の split が段 0 の SHA-256 の分だけ縮む。鍵が key だけで決まる（テスト）。gallery と `make gl-parity` が 0 px | 2 時間 |
| **2. 分ける (a)** | 作りかけの控え・予算で止める・作り直しの間は前の控えを描く。初めて見えている物は今まで通り 1 コマ | `FIRST=1` で、作り直し（2 回目の別の値の集まり）の最悪のコマが PC 33 ms 以下・ブラウザ 50 ms 以下。作り終えたコマの行が 1 回で作った物と同じ（テスト）。毎コマの p50 が 1 割以上増えない | 4〜6 時間 |
| **3. 先に払う (c)** | `withPreload3d` に groups と scenes・進み具合の欄。GL と WebGPU。docs/scene3d.md と agents-pack の早見表と agent-eval のお題（AGENTS.md「新しい仕組みを入れたら」） | `FIRST=1` に「preload で先に払ってから載せる」区間を足し、載せたコマの split が 2 ms 以下・骨つきの初めてのコマ（`FIRST=skin`）が PC 33 ms 以下。進み具合が 0 → total と増える（テスト） | 5〜7 時間 |
| **4. ブラウザの往復 (d③')** | 前に `refactor usages ImageData.ImageDecoder` で、`decoderOf` を通さずレコードを直に組む handler（`WebLayer.flix:631`・`LwjglLoad.handleWith`・テストとゲームの自作）を洗う。その後 glb の中の絵を ImageBitmap のまま GPU へ。届いた時に JS で先に解く | ブラウザで束が届いたコマの最悪が 50 ms 以下（(a) と合わせて）。`web-capture` の画素が 0 px | 3〜5 時間 |
| **5. 割り当て (e) の 3-b** | WebGPU の upload の控えの分け合い・GL の絵の鍵（GL のゲーム向け） | 足切り: p99 が 1 割縮む。届かなければやめて docs/backlog.md に数字を残す（§3） | 2〜4 時間 |
| 6. 見直し | ① Web Worker は段 4 の後の内訳で「glb の構文読みが #2 の 3 割超」の時だけ相談 | — | — |

- 段 1〜5 はそれぞれ別のリリースにできる（各段の後に night_school で実機の手を流し、0.1 の目標と照らす）。
- リリースの後、night_school は段 3 の後に `warmFloorsOf` をやめて `withPreload3d` へ移す（ゲームのリポの仕事）。
- 合わせて PC 約 18〜26 時間（段 0〜5）。

## 4. やらない事

- **初めて見えている集まりを、できた所から出す**（物が次々に現れる）。壊れた絵になる（2 の (a)）
- **(b) の本体**: 書き出しの時にゲームを走らせて計画を束に入れる。得が CPU の半分に留まり、(c) で同じ効果が出る
- **④ 描き手ごと Worker へ移す**: ゲームのコマの止まりは消えない・入力と音とセーブの中継が全部要る
- **SharedArrayBuffer**: GitHub Pages で COOP/COEP を付けられない・wasm-gc の配列は置けない
- **② ReadableStream** を止まりの計画で扱う事（押した後の待ちの計画へ回す）
- **pipeline を async で組む**（`createRenderPipelineAsync`）: わざと使っていない（`BrowserWebGpu.java:293` の WhyNot: 誤りの道が Dawn の側と分かれ errorCount で拾えなくなる）。(c) で先に組めば要らない。(c) の後でも初めての材質の止まりが残れば、誤りの拾い方を論点にして相談
- 視錐台で集まりを間引いて作る量を減らす（`StaticRows.flix:5` の WhyNot。目が動くたびに作り直す）
- スマホの数字を目標に入れる事（測れない）

## 5. 人に決めてほしい事

1. **目標の線**: 遊んでいる最中の初めての 1 回を PC 33 ms・Chrome（M4 Pro）50 ms 以下、でよいか。もっと厳しく（PC 16.7 ms = 1 コマも落とさない）にするなら、(c) で全部を先に払う前提になり、ゲームに暗転かロゴの間が要る
2. **(a) の途中の見せ方**: 作り直しの間は前の絵を描き続け、初めて見えている物は今まで通り 1 コマで作る、でよいか
3. **(c) の pub の形**: `withPreload3d` に `groups` と `scenes` を足し、進み具合を frame の欄（`frame#preload3d`）で返す、でよいか（pub を足す = 相談の対象）
4. **night_school の暗転**: 段 3 の後、遊び始めに短い暗転（0.5〜2 秒・進み具合で長さが変わる）を置いてよいか。置かないなら、ブラウザの初めての階は 50 ms の線に収まらない見込み
5. **(d) の順**: ③'（glb の中の絵の往復を消す）を先にし、① Web Worker は内訳を見てから、でよいか
6. (a) の 1 コマの予算: 最初は固定の値（private）で始め、World から渡す形（pub）は (c) と一緒に決める、でよいか
7. 置き場の上限: (c) の宣言の物を捨てる候補から外す、でよいか（外さないと `evicted` で控えが全部捨てられ、225 ms が遊んでいる途中に戻りうる）
8. 段 0 の細かい区間を `FrameDiagnostics` に残すか
9. pub を足す形でよいか: (b') は関数 `Gltf.fromGlbTexturedKeyedUsingOptions` を 1 つ足す・③' は pub のレコード `ImageData.ImageDecoder`（`ImageData.flix:18`）に欄を 1 つ足す（直に組む handler が全部直しになる）（残すと pub が増える・残さないと次に測る人が同じ足し算をやり直す）

## 6. 実装の記録（worktree の枝・数字は bench/scene3d/RESULTS.md の「初めての 1 回」）

### 段 0（測った物で 1.1 の推測を書き戻す）
- 場: `COUNT=300 SHAPES=137 MATS=8 VERTS=600`。PC: 初めて 57〜68 ms・作り直し 29〜32 ms・骨つき初出 18〜24 ms。Chrome cpu: 初めて 57〜59 ms・作り直し 63〜64 ms。
- 1.1 の内訳（PC 初めて）: 候補分け 8〜10・材質の program 8〜9・値を詰める 2・行 5・形を GPU に作る 16〜17・純粋な仕事（中身の鍵・splitGroups）6〜8。Draw の側: bundle を積む 9・場面の形式の材質の pipeline 2。
  ブラウザは純粋な仕事（SHA-256 を含む）が約 35 ms で半分を超える（1.1 の「SHA-256 は推測」は、ブラウザで大きく PC で小さい、で確かめた）。
- 置き場が捨てた回数（meshEvictions）はベンチでは 0。night_school の手の並びでは数えていない（ゲームのリポの仕事）。

### 段 2 の限界（直さずに残した物）
- 作りかけが GPU に作った形の lastUsed は、作りかけを進めないコマには新しくならない。置き場の上限の近くでは作りかけの形が先に捨てられ、evicted で控えが全部捨てられうる（(a) の危険と同じ道）。
- 同じ名前で中身の違う集まりを 2 場面で描くと、作り直しの間に描く前の控えに、もう一方の場面の中身を選びうる（名前の重なりは知らせの文が誤用と言う形）。
- 色の場面と奥行きの書き出しの場面で、作り終えるコマが数コマずれうる。奥行きの絵を色に重ねる後がけ（DoF・HeightFog）を使うゲームでは、その数コマ輪郭がずれて見える。
- 止めない最後の仕事（行を作って置く）が作り直しの最悪のコマを決める（PC 10 ms 前後・ブラウザ 8 ms 前後）。

### 段 3 で変えた置き場（11-25 に決めた）
- 進み具合は計画の `frame#preload3d` でなく **`ViewCtx#preload3d`** に置く（`Scene3d.PreloadProgress = { done, total }`・前のコマの値）。暗転・押した後のロゴは View が描き続ける。
  WhyNot: Frame に置かない — 描き手の実時間で決まる値で、系が読むと遊んだ記録・再生・headless（最初から済んでいる）で暗転を明けるコマが変わり、その後の World が全部ずれる（FrameDiagnostics を系で読まないのと同じ理由）。
- 描き手 → App は `Platform.Draw3d.preload3d` の答えを Unit から `Scene3d.PreloadProgress` に替えて運ぶ（engine の中の handler だけ直す）。
- 場面の描き先の形式ごとの pipeline と bundle（Draw の側の初回）は先に作らない。作り終えた後に初めて載せたコマの Draw は PC 11〜16 ms（線の内）。
- 限界: GL は Pass の場面を前の世代・画面を次の世代で描くので、予算（世代ごと）を preload と画面と Pass が別々に決めうる。暗転の間に Pass の描き先の集まりを作り直すゲームだけ、1 コマに 8 ms × 3 まで乗りうる（根で直すなら予算を画面のコマの初めで決める）。
- 移行: ゲームのテストが Platform.Draw3d の handler を直に書いている所は `k(())` → `k(Scene3d.noPreload())`、ViewCtx を全部の欄で作っている所は `preload3d = Scene3d.noPreload()` を足す（リリースの移行メモに 1 行）。

### 段 4（③'）
- glb の中の絵は ImageData.ImageDecoder の platformImageOfBytes（欄 1 つ）で機種の側に持ち、鍵つきの読み方（fromGlbTexturedKeyedUsingOptions）だけが使う（同じ id を約束できるのは key がある時だけ）。上限より大きい絵は画素へ戻す。
- 届いた glb の中の絵は fge-web.js が届いた時に ImageBitmap へ解いておく（id = fgePlatformKey(道)#image<番号>・ゲームが key に versionedKey(道) を渡した時に当たる）。
- 測り（bench/scene3d の first=glb・束 1 つ 1.5 MB・絵 46 枚）: 解く仕事 230 → 178 ms・初めて描くコマ split 37 → 16 ms・draw 84 → 32 ms。web-capture は WebGPU と WebGL2 で 0 px。
- 線（ブラウザで束が届いたコマ 50 ms 以下）には届かない。残りは glb の構文読み（178 ms・束が届いたコマの 4 分の 3 超）で、① Web Worker の相談の条件（3 割超）に当たる。
