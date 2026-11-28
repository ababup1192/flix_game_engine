# 2 回目の比較レビュー (B) — render_gl・描き手 3 本（GL・WebGPU・CPU）・engine の 3D（scene3d・shader）

対象: main = e44d8a0d8（v0.116.0）。保守の税の実例 1 つ目は main の 36b9884fc（影の地図の使い回し 1d）、
2 つ目は `.claude/worktrees/agent-a1f871b0b7a2d4ac2` の 149bfe1c0（SH の withSkyContribution・**main にはまだ入っていない**）。
評価だけで、ファイルは変えていない。範囲は途中の指示どおり**作りのきれいさだけ**。性能（旧観点 5）と描画の機能の広さ（旧観点 6）は点を付けていない。
シェーダーの 2 回書きの細かい棚卸しは `plans/engine-shader-single-source.md`（案 C・10〜15 時間）にあるので、ここでは数と判定だけにした。

---

## 1. 1 回目の総評のうち担当範囲の行の判定

| 1 回目の行 | 判定 | 根拠 |
|---|---|---|
| 1 コアは 3D に活きている | **残る（良い方）** | 3D は今も 2D の並びの 1 項目。2D の描き手は `Scene3dRenderer.Prepared` の番号を z の並びに混ぜるだけ（`render_gl/src/Scene3dRenderer.flix:4-19`）。行の列 `RenderList` は GL と WebGPU が同じ物を流す（`render_gl/src/RenderFrame/Internal/RenderList.flix:1-3`） |
| 2 材質は ShaderDoc を使い回す | **良くなった** | 出口が 3 つになった: GLSL（`ShaderGen`）・WGSL（`ShaderGen.Wgsl.compile3d`、`Render3dWgsl.flix:277-279`）・CPU（`ShaderEval`） |
| 3(a) 光の式を GLSL と Flix に手で 2 回 | **直った。ただし 2 回書きが別の所へ移った** | 光・かすみ・空・PBR の式は `LightModel3d` の木だけにあり（`engine/src/scene3d/LightModel3d.flix:46-171`）、`LightModel3d.Codegen` が GLSL・WGSL・Flix を出す（`Codegen.flix:3`）。CPU の物は生成物（`engine_tools/src/gen/SoftRaster3dLight.flix:1-2`）で、作り直しとの一致をテストが確かめる。**材質の frag・影・PS1 風・ビルボード・空・vertex の組み立ては GLSL と WGSL に手で 2 回**: 同じ名前の関数の組が 34 個・GLSL 553 行 / WGSL 412 行（`Render3dGlsl.flix` と `Render3dWgsl.flix` の outline を突き合わせた数。例 `materialFragmentSource` `Render3dGlsl.flix:384-453` と `Render3dWgsl.flix:277-333`） |
| 3(b) 2D の GL の道が Render3d を静的に抱える | **直った** | `RenderPaint` が持つのは `Scene3dRenderer.Renderer`（関数の record）だけ（`Paint.flix:61`・`:116`）。WhyNot に理由が書いてある（`Scene3dRenderer.flix:1`）。`Paint.flix` と `Frame.flix` に `Render3d` の名前は出てこない |
| 3(c) F8 と注釈は 3D を矩形 1 つとしか見ない | **ほぼ直った** | `Annotate.named3d` が、囲んだ矩形の真ん中の点からレイを飛ばして当たった置いた物の名前を入れる（`engine_world/src/Annotate.flix:267-280`）。テストあり（`TestAnnotate.testScene3dHitNamesTheInstanceAtTheCenter`）。残り: 真ん中の 1 点だけで、矩形の中にある物の一覧は出ない（WhyNot で意図して止めている） |
| 5 性能の作り（点は付けない） | （参考）大きく直った | 同じ形と材質の物を batch にして instanced draw（`Render3d.flix` の頭のコメント・`Render3d/Batch.flix`）、動かない物の持ち越し（`Render3d/StaticRows.flix`・`GlStatic`・`WebGpuStatic`）、影の地図の使い回し（`GlShadowCache`・`WebGpuShadowCache`） |
| 6 描画の機能（点は付けない） | （参考）広がった | PBR の metallic / roughness・環境マップ・太陽と段の影・点光源の影・半透明・MSAA・alpha to coverage・PS1 風・空。範囲外なのでここまで |
| 9 材質の鍵がゲームの付けた名前 | **直った** | 鍵は `MaterialFields#shaderHash`（spec と emission の中身の hash）と変種の欄（`render_gl/src/Render3d.flix:227-234`）。テスト `testMaterialKeyIgnoresFieldsOutsideTheTree` などあり |
| 10 属性を 1 つ足す税（5 か所） | **悪くなった（描き手が 3 本になった分）** | 3 節。SH の例で、新しい中身とは別に配線だけで 16 ファイル・8 種類の場所。影の使い回しの例でも、同じ LRU の処理を 2 回書いた |
| 13 ブラウザへ持っていけない（契約層の imageio） | **直った** | `engine/src/scene3d` と `engine/src/shader` の import は `java.lang`・`java.nio`・`java.security`・`java.math` だけ（`Texture3d.flix` から `javax.imageio` と `java.awt` が消えた）。WebGPU の描き手とブラウザの層（`engine_web/src/WebLayer.flix:148-212`）がある |
| 15 一番効く直し 5 つ | 光の式の 1 本化 = **直った**・材質の鍵 = **直った**・Scene3dRenderer の口 = **直った**・まとめ描き = **直った**（範囲外の参考）・後処理と温め = (A) の範囲 | 上の各行 |

---

## 2. 点の表（作りのきれいさ・描き手とシェーダーの側から）

1 回目の 4 観点は横に 1 回目の点を置いた。5〜12 は今回足した観点（5〜11 はまとめ役の指定・12 は私が足した）。
相手の点は 1 回目の sparse clone の読みと、2026 年までの相手の進みの**記憶**による（ソースは取り直していない）。±1 の幅で読んでほしい。

| 観点 | このエンジン（1 回目 → 今） | Godot 4.x | Bevy | LÖVE |
|---|:--:|:--:|:--:|:--:|
| 1 コアの設計 | 7.5 → **8** | 8 | 9 | 5 |
| 2 モジュールの境界と依存 | 6 → **7** | 8 | 8.5 | 8 |
| 3 API の設計と命名 | 7 → **7.5** | 8 | 7.5 | 8.5 |
| 7 拡張しやすさと保守 | 7.5 → **7** | 8.5 | 7.5 | 7 |
| 5' データの流れ | **8** | 7 | 9 | 5 |
| 6' 副作用の閉じ込め | **7** | 7 | 8 | 6 |
| 7' 機種の切れ目 | **6.5** | 7.5 | 9 | 7 |
| 8' 真実が 1 か所か | **6** | 6 | 8 | 7 |
| 9' 不正な状態を型で書けなくする | **5.5** | 5 | 7.5 | 3 |
| 10' 依存の結合と循環 | **6** | 6.5 | 8 | 7.5 |
| 11' 拡張の口 | **6** | 8.5 | 8.5 | 6 |
| 12' 描き手どうしの一致を機械で守る（足した） | **9** | 5 | 6 | 5 |

（5'〜11' の「'」は旧観点 5・6・7 との取り違えを避けるための印。）

---

## 3. 観点ごとの良い所・悪い所（根拠つき）

### 1 コアの設計（7.5 → 8）
- 良い: 「何を描くか」の計画が GL を呼ばない（`Render3d/ScenePlan.flix:1-2` の WhyNot）。GL と WebGPU が同じ計画（`ScenePlan`）と行（`SceneList`）を使う（`Render3d/WebGpuRenderer.flix:1-4`）。
- 良い: 光の式は 1 本の木から 3 つの出口（`Codegen.flix:3`）。2D の宣言シェーダーと同じ作りになった。
- 悪い: CPU の描き手は `ScenePlan` に乗らない（engine_tools から render_gl は引けない層の向き）。CPU の「何を描くか」は engine の `Scene3d` の関数（`blendOrderOf`・`isOutsideFrustum`）で、GPU 側の計画とは 2 本ある。
- 点を上げた理由: (a)(b) が直り、計画と描きの分け方が GPU の 2 本で揃った。

### 2 モジュールの境界と依存（6 → 7）
- 良い: 契約層から `javax.imageio` が消えた（上の表）。backend ごとに要る物だけを関数の record で受ける形が何か所かある: `Render3d.MeshTable.MeshAllocator`（`Render3d/MeshTable.flix:1-4`・WhyNot で「表を backend ごとに持たない」）、`TargetTable`、`StaticRows.BuildSteps`（`GlStatic.stepsOf` と `WebGpuStatic.stepsOf` が同じ型を埋める）。
- 悪い: **GL と WebGPU が共有する約束（`ProgramKind`・`ShaderVariant`・`materialKey`・`variantKeyOf`）が GL の描き手のファイル `Render3d.flix:193-234` にある**。`WebGpuMaterials` は GL のファイルの `Render3d.materialKey` を呼ぶ。WebGPU のモジュールも `Render3d.WebGpu*` と GL の名前の下にあり、パッケージの名前も `render_gl` のまま。
- 悪い: `VariantPrograms.flix:1` の頭のコメントは変種を「+ps・+pu・+psx」と書いている（+sh の枝では古くなる）。

### 3 API の設計と命名（7 → 7.5）
- 良い: 材質の鍵が中身になり、ゲームの `withSpecName` の回り道が要らなくなった（`Render3d.flix:227-229` の doc）。
- 良い: `Scene3dRenderer.Renderer` の 5 つの口（prepare・endFrame・takeCounts・readsTexture・preload）は doc に 1 コマの使い方がそろっている（`Scene3dRenderer.flix:4-19`）。
- 悪い: `ProgramKind` が Bool 12 個の record（`Render3d.flix:193-194`）。描き手の中の型だが、組の数と、作れてしまう組（uv の無い法線マップ）を呼ぶ側の `surface#uv and surface#normalMap` で消している（`Render3dGlsl.flix:394`）。

### 7 拡張しやすさと保守（7.5 → 7）
- 良い: render_gl のテストが 86 → 823 件（`@Test` の数）。シェーダーの字の SHA を留めるテスト・生成物の一致のテストがある。
- 悪い: 描き手が 3 本になり、属性 1 つの税が増えた（5 節）。GLSL と WGSL の組 34 個。
- 悪い: CPU の光の入力が位置で並べた 13 個の enum（`engine_tools/src/SoftRaster3d.flix:121-126`。SH の枝では 15 個）。欄を 1 つ足すと分解の字が 7 か所動く（149bfe1c0 の SoftRaster3d と PointShadows の差分）。
- 下げた理由: 構造は良くなったが、足すたびに払う所の数が 1 回目より増えた。

### 5' データの流れ（8）
- 良い: 2D の描き手と 3D の描き手の受け渡しは値（`List[Scene3d.RenderCmd]` を渡し `Prepared` を受ける・`Scene3dRenderer.flix:13-17`）。2D の行は backend を知らない数の列（`RenderList.flix:1-3`）。Bevy の extract → prepare → render に近い形が、計画（`ScenePlan`）→ 行（`SceneList`）→ backend の流し（`GlRows` / `WebGpuRows`）でそろった。
- 悪い: CPU の流れは別（上の 1）。
- 比べ: Bevy 9（extract の段が schedule で決まる）。Godot 7（RenderingServer は保持型で、場面の状態を RID の中に持つ。毎コマ値から作る形ではない・記憶）。LÖVE 5（命令の呼び順がそのまま描く順）。

### 6' 副作用の閉じ込め（7）
- 良い: 計画・行・表（`ScenePlan`・`SceneList`・`MeshTable`・`UniformLayout`・`RenderList`）は GL も WebGPU も呼ばない。GL を import するのは render_gl の 92 ファイル中 35、WebGPU は 21（import の数を数えた）。
- 悪い: 時計が直に `System.nanoTime()`（`Render3d/Counts.flix:96-106`）。負荷の高い時だけ落ちる 2 本のテストの根はこれ: `testNestedPhaseIsNotCountedTwice` は実際に 2 ms 回して比べ（`render_gl/test/TestRender3dCounts.flix:55-61`）、`testMinimumStepGoesToOneWorkPerFrame` は `Thread.sleep(1)` で予算を使い切らせる（`render_gl/test/TestStaticRows.flix:324-335`）。時計を引数で渡せばテストは決定的にできる。
- 悪い: `LwjglLayer.flix`（1,080 行・def 43）が窓・音・カーソル・PNG とテキストの書き出し・起動の画面・注釈の保存を 1 つで持つ。
- 比べ: Bevy 8（wgpu の後ろ・`RenderDevice`/`RenderQueue`・記憶）。Godot 7（RenderingDevice の後ろだが、Compatibility の GLES3 の道は GL を直に呼ぶ・記憶）。LÖVE 6。

### 7' 機種の切れ目（6.5）
- 良い: GPU の 2 本は計画・行・形の表・描き先の表・持ち越しの段を共有する（2 の良い所）。
- 悪い: 切れ目が 1 か所ではなく 3 か所: 3D は `Scene3dRenderer.Renderer`、2D は `RenderPaintHandlers` の effect の handler（`PaintHandlers.flix:1-7`）、窓は `LwjglLayer` と `WebGpuWindowLayer`。窓の 2 本は `handleWindow` が 50 行ほぼ同じ（`LwjglLayer.flix:633-687` と `LwjglLayer/Internal/WebGpuWindowLayer.flix:427-476`。違うのは `pollEvents` の 2 行と `presentFrame` の 1 行）。
- 悪い: 影の地図の控えの LRU は `MeshTable` の形（表は 1 つ・作る / 捨てるだけ backend）に乗らず、`ensure` と `endFrame` を 2 回書いた（`GlShadowCache.flix:25-62` と `WebGpuShadowCache.flix:68-130`。同じ処理が約 25 行ずつ。WebGPU は捨てるのを 1 コマ遅らせる所だけ違う）。
- 比べ: Bevy 9（wgpu 1 か所で全機種）。Godot 7.5（Forward+ と Mobile は RenderingDevice を共有するが、Compatibility は別の道・記憶）。LÖVE 7（`Graphics` の抽象クラスと opengl・metal・vulkan の子・12.0 の開発版の記憶）。

### 8' 真実が 1 か所か（6）
- 良い: 光の式は 1 か所。WGSL の uniform の struct とバイト位置は表 1 つ（`Render3d/UniformLayout.flix:1-2`）。
- 悪い: **uniform の表は WGSL の側だけ**。GLSL は宣言の字（例 SH の枝の `Render3dGlsl` の `"uniform vec3 uSh[9];..."`）・location の record（`Render3d.flix:98` の `LightLocs`）・`loc(gl, program, "uSh")`（`VariantPrograms`）・差す所（`Render3d/Light.flix`）を手で 4 か所書く。
- 悪い: シェーダーの組 34 個（上）・影の控えの LRU 2 回・`handleWindow` 2 回。
- 悪い: 2 回書きでもう食い違いが出ている: 診断の取り出しで GL は 3D の材質の組み立て（`counts#materialBuilds`）を `shaderBuilds` に足し `liveShaders` を数えるが、WebGPU は足さない（`Paint.flix:727-739` と `RenderPaint/Internal/WebGpuPaint.flix:1057-1065`）。F8 の数が backend で違う。
- 比べ: Bevy 8（WGSL を 1 本だけ書き、`#ifdef` の shader defs で変種）。Godot 6（RD 用の GLSL と Compatibility の GLES3 の scene シェーダーを別に持つ・記憶）。LÖVE 7（GLSL 1 本を各 backend へ訳す・記憶）。

### 9' 不正な状態を型で書けなくする（5.5）
- 良い: `UniformLayout` の欄は enum（`LightField`）、光の式は木（`ScalarExpr`/`Vec3Expr`）。`DrawHash` は全部の欄をパターンで書くので欄の書き忘れはコンパイルで止まる（1 回目と同じ）。WebGPU の資源は Java の型（`Texture` など）。
- 悪い: シェーダーは字の `+` で組み、関数の重複を字の検索で避ける（`Render3dGlsl.flix:396` の `String.contains(substr = "vec4 sg_texMip(", ...)`）。
- 悪い: GL の資源は全部 `Int32`（`ShadowTarget = { fbo = Int32, tex = Int32, ... }` `Render3d.flix:88`・`RegisteredTexture.texId`）。テクスチャとプログラムと FBO を取り違えても通る。
- 悪い: `ProgramKind` の Bool 12 個・CPU の光の位置で並べた enum（上）。
- 比べ: Bevy 7.5（`Handle<T>`・`AsBindGroup` の derive。ただし WGSL は字）。Godot 5（RID は型を持たない・記憶）。LÖVE 3（Lua）。

### 10' 依存の結合と循環（6）
- 良い: 2D と 3D は `Scene3dRenderer` の口で切れた。`Frame.flix`（1,018 行）は backend を持たない front-end で、太いのは中身の量で、絡みではない。
- 悪い: 1,000 行前後の 6 本のうち、責務が混ざっているのは 3 本:
  - `Render3d.flix`（1,161）: GL と WebGPU が共有する約束（`:193-234`）＋ GL の texture unit の決め（`:357-381`）＋ GL の描き手の本体。共有の約束を外へ出せば WebGPU が GL のファイルに依存しなくなる。
  - `LwjglLayer.flix`（1,080）: 上の 6' のとおり。
  - `WebGpuPaint.flix`（1,182・def 91）: 2D の塗り・上げ・present・history・handler 5 つ。頭のコメントで `WebGpuSurfaces`・`Scenes` へは切り出してあり、残りは「上げる」と「handler」で割れる。
  - `WebGpuRenderer`（1,166）と `Paint`（911）は 1 つの責務で太いだけ。
- 循環は見つからなかった（層の向きは gates.json のとおり・render_gl の中で GL → WebGPU の呼び出しは無い）。
- 比べ: Bevy 8（crate で切る）。Godot 6.5（`renderer_scene_cull.cpp`・`rendering_server.h` など大きな物が多い・記憶）。LÖVE 7.5。

### 11' 拡張の口（6）
- 属性を足す口: 5 節のとおり 8 種類・16 ファイル。変種の旗 1 つは、変種の欄を全部書き並べる所 10 か所ほど（`defaultShaderVariant`・`shaderVariantOfKind`・`billboardVariantOf`・`lightVariantOf`（`Render3d.flix:202-225`）・`Counts` の bit・`VariantPrograms`・`layoutCodeOf`・`Render3dWgsl.variantDeclarations` の「全部偽か」・`Render3dGlsl.lightSourceFor`・`Scene3d.preloadVariantOf`/`preloadVariantKey`）。L5〜L7 で SSAO・多数の点光源・fog を足すと、ここを毎回払う。
- 新しい描き手を足す口: `Scene3dRenderer.Renderer` ＋ 2D の handler ＋ 窓の layer の 3 つを埋める。`MeshTable`/`TargetTable` の allocator の形はそのまま使える。
- 後処理: 2D の Pass の計画（`PostProcess`・(A) の範囲）。
- 比べ: Godot 8.5（Compositor effect・RenderingDevice・visual shader・記憶）。Bevy 8.5（`Material` trait・render graph の node・Plugin・記憶）。LÖVE 6。

### 12' 描き手どうしの一致を機械で守る（9・足した観点）
足した理由: 描き手が 3 本になった今、作りのきれいさの不足（2 回書き）を、どれだけ機械が拾うかが保守の実際を決める。
- 良い: 生成物と作り直しの一致のテスト（`gen/SoftRaster3dLight.flix:2`）、GLSL の字の SHA を留めるテスト（`TestRender3dGlslPinned`・1 本化の計画の 0 節）、gl-parity、WebGPU を Dawn で描くテスト群（`render_gl/test/TestWebGpu*Dawn.flix` 7 本）。
- 悪い: 上の診断の食い違いのような「描かない所の差」はどの門も見ていない。
- 比べ: Godot 5・Bevy 6（例のスクリーンショットを CI で撮るが、描き手どうしは突き合わせない・記憶）・LÖVE 5。

---

## 4. 組のファイルの重なり（同じ名前の関数の組を outline で突き合わせた）

| 組（行数） | 同じ名前の組 | 実際に似ている所 |
|---|---|---|
| `Render3dGlsl`（704）/ `Render3dWgsl`（657） | 34 組・553 / 412 行 | 組み立ての筋は同じで言語だけ違う。1 本化の計画の範囲 |
| `GlShadowCache`（70）/ `WebGpuShadowCache`（149） | `ensure` 15/14・`endFrame` 15/17・`copyInto`・`minKept`・`sizeOf` | **`ensure` と `endFrame` の LRU がほぼ同じ字**（約 25 行ずつ）。`MeshTable` の形に乗せられる |
| `LwjglLayer`（1,080）/ `WebGpuWindowLayer`（477） | `handleWindow` 56/50・`frameShot` 11/10 | **`handleWindow` が 3 行違うだけ**。`applyMouseCaptured` などはすでに共有 |
| `Paint`（911）/ `WebGpuPaint`（1,182） | 13 組（`applyHistory` 15/15・`fillLetterbox` 20/14・`consumeDiagnostics` 13/14・`submitFrame` 36/29 など） | `fillLetterbox` の前半（絵を引いて `letterboxFillOf`）と `consumeDiagnostics` の骨は同じ。`consumeDiagnostics` は中身が食い違っている（8' の悪い所） |
| `RenderFrame/Internal/GlRows`（280）/ `WebGpuRows`（503） | `drawRow` などの 10 組 | 同じ `RenderList` の行を読む。読む欄の名前は共有の読み出し口を使い、GPU の呼び方だけ違う。**正当な組** |
| `Render3d/GlRows`（273）/ `WebGpuRows`（192） | `drawRow`・`uploadRows` など 6 組 | 同上。正当 |
| `GlStatic`（133）/ `WebGpuStatic`（266） | 9 組（`stepsOf` 15/26 など） | `StaticRows.BuildSteps` を埋める形がそろっていて、違うのは材質の絵の上げ方（WhyNot あり）。**正当** |
| `Material`（581）/ `WebGpuMaterials`（651） | 2 組だけ | 作りが違う（GL は描く時に引く・WebGPU は bind group）。重複は小さい |
| `ShadowMaps`（211）/ `WebGpuShadows`（314） | 1 組 | 計画（`ShadowMaps`）と WebGPU の流しに分かれている。GL の流しは `Shadow.flix`。正当 |
| `GlOffscreen`（711）/ `WebGpuOffscreen`（261） | 8 組 | 小さい関数の組。`GlOffscreen` は CGL・GLFW の窓なしの開き方を抱えて太い |
| `GpuTimer`（205）/ `WebGpuTimer`（161） | 1 組 | 測り方が違う。正当 |

まとめ: **残った重複で直す価値がはっきりあるのは 3 つ（影の控えの LRU・`handleWindow`・`consumeDiagnostics`）と、シェーダーの 34 組**。ほかは同じ共有の型を backend ごとに埋めている正当な組。

### 変種の旗の分岐の数
- 変種の旗: `ShaderVariant` = 3 個（main・+ps・+pu・+psx）、SH の枝で 4 個。材質の `ProgramKind` = Bool 11 個（SH の枝で 12 個）。字の上の組の数は 2^12 だが、実際に組むのは使った組だけ。
- 分岐の数（字を数えた）: `Render3dGlsl.flix` の `if (` 55 個・`surface#` 24・`psx` 46・`v#pointShadows` 5・`v#physicalUnits` 2。`Render3dWgsl.flix` の `if (` 70・`surface#` 21・`psx` 38・`v#pointShadows` 5・`v#physicalUnits` 1。**PS1 風の旗だけで分岐の 4 割ほど**を占める。
- 変種の欄を全部書き並べる所が約 10 か所（11' のとおり）。欄の表が 1 つ無い。

---

## 5. 保守の税: 描画の属性を 1 つ足すと何か所払うか

### 実例 1: SH の `withSkyContribution`（149bfe1c0・枝の上）
新しい中身（SH を求める `SphericalHarmonics`・`Scene3d.Internal.SkyIrradiance`・`Texture3d` の Lazy）の他に、**配線だけで 16 ファイル・8 種類の場所**を直した（docs・テスト・symlink・生成物は数えない）:

| 種類 | ファイル | 払った物 |
|---|---|---|
| 1 光の木 | `LightModel3d.flix`・`LightModel3d/Codegen.flix` | 入力 2 つと、3 つの出口での名前（GLSL の uniform・WGSL の `r3dLight.uSh[i]`・Flix の引数） |
| 2 API と変種 | `Scene3d.flix` | `withSkyContribution` と `PreloadVariant` の欄 |
| 3 GL | `Render3d.flix`・`Render3d/Light.flix`・`VariantPrograms.flix`・`Counts.flix`・`ScenePlan.flix`・`Render3dGlsl.flix` | 変種の欄の書き並べ 4 か所・uniform の宣言・location・差す所・鍵の bit・知らせ |
| 4 WebGPU | `UniformLayout.flix`（共有）・`WebGpuRenderer.flix`・`WebGpuShadows.flix`・`Render3dWgsl.flix` | 表の 2 行・layout の番号・詰める所・binding の条件 |
| 5 CPU | `SoftRaster3d.flix`・`SoftRaster3d/PointShadows.flix`・`SoftRaster/Internal/Texture.flix` | 位置で並べた `Lights` の分解 7 か所 |
| 6 描き出しの鍵 | `DrawHash.flix` | 12 行 |
| 7 gl-parity | `bench/gl_parity/src/Scenes.flix`・`ExprRows.flix` | 場面 1 つ |
| 8 早見表とお題 | `agents-pack/AGENTS.core.md`・`agent-eval/engine.json` | 1 行と 1 題 |

**1 回目の 5 か所（GL・CPU・鍵・対応表・gl-parity）→ 8 種類・16 ファイル**。ただし**光の式そのものは 1 回しか書いていない**（1 回目なら GLSL と Flix に 2 回）。税の中身が「式を 2 回書く」から「名前と値を 5〜6 か所へ配る」に変わった。配る所のうち、GL の uniform の 4 か所・変種の書き並べ・CPU の位置の分解は、表を 1 つ置けば消せる。

### 実例 2: 影の地図の使い回し 1d（36b9884fc・main）
render_gl の 10 ファイル＋`FrameDiagnostics`。共有の部分（見逃しの数え `noteCacheMisses`）は `ShadowMaps` に置いたが、**LRU の本体は GL と WebGPU に 2 回**（`GlShadowCache` 70 行・`WebGpuShadowCache` 149 行）。同じ枝の前の段で作った `MeshTable` の allocator の形があったのに使っていない。

---

## 6. 直す物の候補（作りのきれいさに効く物だけ・効く順）

| # | 直す物 | 効き目 | 実時間 | engine 拡張か | L5 の前 / 後 |
|---|---|---|---|---|---|
| 1 | **シェーダーの 1 本化**（`plans/engine-shader-single-source.md` の案 C）。ここで重ねて設計しない。GL の uniform の宣言と location も表から作る所まで入るかだけ、計画に確かめる（下の 3） | 大: 組 34 個と 8' の大半が消える | 10〜15（計画の見積もり） | render_gl の中（engine の型は変えないと計画にある） | 前（計画どおり） |
| 2 | **変種の欄を表 1 つにする**: `ShaderVariant`・`ProgramKind` の旗を 1 つの表（名前・鍵の字・bit・layout の扱い）から引き、書き並べ 10 か所を消す。あわせて共有の約束（`ProgramKind`・`ShaderVariant`・`materialKey`・`variantKeyOf`）を `Render3d.flix:193-234` から別の mod（例 `Render3d.ProgramKey`）へ出す | 大: L5〜L7 で旗を足すたびの 10 か所が 1〜2 か所に。WebGPU が GL のファイルに依存しなくなる | 3〜4 | `ShaderVariant` は engine の `Scene3d.PreloadVariant` の alias なので、そこを変えるなら**相談**。render_gl の中だけで閉じる形もとれる | 前（1 本化と同じ時期・1 本化の 4.2「変種の膨らみ」と重ねて決める） |
| 3 | **GL の uniform を表から**: `UniformLayout` の表を GLSL の宣言・location の record・差す所にも使う（今は手で 4 か所） | 中: 属性 1 つの GL の分が 4 か所 → 1 か所 | 3〜5 | render_gl の中 | 前。1 本化の計画に入っていなければ足す |
| 4 | **CPU の光の入力を位置の enum から名前つきの record へ**（`SoftRaster3d.flix:121-126`） | 中: 欄 1 つで分解 7 か所が動く税が消える | 1〜2 | engine_tools の中 | 前（SSAO・fog で欄が増える） |
| 5 | **影の控えの LRU を 1 つに**: `MeshTable` の形（表は 1 つ・作る / 捨てる / 遅らせて捨てるを backend の関数で受ける）で `GlShadowCache` と `WebGpuShadowCache` をまとめる | 小〜中: 約 25 行の 2 回書きが消え、作りが `MeshTable`・`TargetTable` とそろう | 1〜1.5 | render_gl の中 | どちらでも（安いので前） |
| 6 | **時計を引数で渡す**: `Render3d.Counts.timed` と持ち越しの予算が `System.nanoTime()` を直に読むのをやめ、state に時計の関数を持たせる。落ちる 2 本のテストを決定的にする | 中: 負荷で落ちるテストが消える | 1.5〜2 | render_gl の中 | どちらでも |
| 7 | **窓の handler と診断の取り出しを 1 本に**: `handleWindow` を `pollEvents` の始めと present を引数にした 1 つへ。`consumeDiagnostics` の骨を共有にし、WebGPU も 3D の材質の組み立てを数える（今は F8 の数が backend で違う） | 小: 約 50 行の 2 回書きと、食い違い 1 つが消える | 1〜1.5 | render_gl の中 | 後でよい（食い違いの直しだけは前でもよい） |
| 8 | **責務で割る**: `LwjglLayer`（窓・音・ファイルの書き出し・起動の画面）と `WebGpuPaint`（上げる所と handler）。GL の資源の番号（`Int32`）に型を付ける（テクスチャ・プログラム・FBO を取り違えられなくする）のもこの時に | 小〜中: 読み手と、取り違えの事故 | 割る 3〜4・型 4〜6 | render_gl の中 | 後 |

---

## 7. 評価の限界
- ゲームと 2D の UI・engine_world は読んでいない（(A) の範囲）。WebGPU の Java 側（`render_gl/java`）と engine_web の JS は読んでいない。
- ビルド・テスト・gl-parity は流していない。分岐とテストの数は字の数。
- 相手の点は記憶による（ソースは取り直していない）。特に Godot の Compatibility の道の重複・LÖVE 12.0 の backend の分け方・Bevy の shader defs は記憶。
- SH の例は main に入っていない枝の物。main に入る時に形が変わるかもしれない。
