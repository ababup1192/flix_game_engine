# Godot の描き手と機種の切れ目をソースで読み直した点（G2）

対象: Godot master 8f2e46b（2026-11-25）の浅い sparse。読んだ範囲は servers/rendering（Forward+・Mobile・RenderingDevice・dummy）・servers の根・drivers/vulkan・gles3・d3d12・metal・platform/web。
芯とシーンの木（core・scene・modules）はもう 1 人の担当なので、ここでは描き手の範囲で見えた事だけを書いた。
数は字の数（ビルドはしていない）。関数の切り出しと似ている度合いは、自作の小さな python（`scratchpad/g2tools/fnpair.py`・`linesim.py`）で数えた。
似ている度合いは「空行とコメントを除いた行が、同じ並びで一致する数」。5 行以上続く一致だけを数えた値も並べた。

比べる物差しは review2-B.md（この engine の描き手の側）と同じにした。有名だから甘くはせず、規模が大きいからといって辛くもしない。数は「規模に対する割合」で読む。

---

## 点の表

| 観点 | 前回の Godot（記憶・2 人の平均） | 今回（ソース） | この engine の B（参考） |
|---|:--:|:--:|:--:|
| 1 コアの設計 | 8 | **7.5** | 8 |
| 2 モジュールの境界と依存 | 8 | **6.5** | 7 |
| 3 API の設計と命名 | 8 | **7** | 7.5 |
| ★4 拡張しやすさと保守 | 8.5 | **6** | 7 |
| ★5 データの流れ | 6.5 | **7** | 8 |
| ★6 副作用の閉じ込め | 5.75 | **7** | 7 |
| ★7 機種の切れ目 | 8 | **7** | 6.5 |
| ★8 真実が 1 か所か | 6.5 | **5.5** | 6 |
| ★9 不正な状態を型で書けなくする | 4.5 | **5** | 5.5 |
| ★10 結合と循環 | 6.25 | **5** | 6 |
| ★11 拡張の口 | 8.5 | **7.5** | 6 |
| 合計（1〜11・110 点） | 78.5 | **71** | 74.5 |
| 12 作りの決まりを機械で守る | 5.5 | **5**（tests/ と CI は sparse に無く、確かめていない） | 9 |

大きく動いたのは 4（−2.5）・2（−1.5）・10（−1.25）・11（−1）。上がったのは 6（+1.25）・5（+0.5）・9（+0.5）。
前回は「Godot は保守が楽で拡張の口が広い」という印象で付けていた。読むと、**描き手が 3 本（Forward+・Mobile・Compatibility）あって、同じ式と同じ処理を手で 3 回書いている税**が大きい。この engine の GLSL と WGSL の 34 組と同じ種類の税が、Godot では数千行の単位で残っている。
逆に、**GPU の呼び出しを端へ寄せる作り（RenderingDevice と driver の切れ目・コマンドの graph）**は前回の点より良かった。

---

## 規模（数えた物）

- 読んだ範囲の C++・GLSL は 438 ファイル・約 25 万行。**1,000 行を超えるファイルは 57 本（13%）・3,000 行超は 17 本**。最大は `servers/rendering/shader_language.cpp` 12,329 行、次が `rendering_device.cpp` 10,559 行、`rendering_device_driver_vulkan.cpp` 7,605 行。
- 150 行を超える関数は 164 個・300 行超は 53 個（全 4,482 個中）。描き手の本体では `RenderForwardClustered::_render_scene` 891 行（`render_forward_clustered.cpp:1782`）、`RasterizerSceneGLES3::_render_list_template` 922 行（`rasterizer_scene_gles3.cpp:3255`）。
- 描き手 3 本の行数: servers/rendering 全体 138,719 行（C++）、GLES3 の driver 32,647 行（C++）＋ 7,806 行（GLSL）。RD と GLES3 の GLSL を合わせると 36,485 行。

### 3 本の描き手の重なり（同じ名前の関数の組と行の一致）

| 組 | 同じ名前の関数 | よく似ている組（一致 0.6 以上） | 行の一致（5 行以上続く分） |
|---|---|---|---|
| `render_forward_clustered.cpp`（4,336）/ `render_forward_mobile.cpp`（2,883） | 55 組 | **35 組・2,060 / 1,842 行**（`_render_shadow_pass` 190/186 行・0.96、`_geometry_instance_update` 159/155・0.95、`_setup_lightmaps` 0.97 など） | 1,258（879） |
| `scene_shader_forward_clustered.cpp` / `scene_shader_forward_mobile.cpp` | 25 組 | **20 組・897 / 895 行**（`init` 390/381・`set_code` 208/214・`_create_pipeline` 179/179） | ほぼ全体 |
| `scene_forward_clustered.glsl`（2,460）/ `scene_forward_mobile.glsl`（1,919） | — | — | **1,159（782）**。光の関数は `scene_forward_lights_inc.glsl` を共有しているのに、本体の半分ほどがまだ写し |
| `scene_forward_clustered.glsl` / GLES3 の `scene.glsl`（2,615） | — | — | 513（231）。GLES3 は書き直した別物 |
| RD / GLES3 の `material_storage.cpp`（2,354 / 2,901） | — | — | **1,638（1,465）** |
| RD / GLES3 の `mesh_storage.cpp` | — | — | 1,138（943） |
| RD / GLES3 の `light_storage.cpp` | — | — | 939（779） |
| RD / GLES3 の `particles_storage.cpp` | — | — | 783（688） |
| RD / GLES3 の `texture_storage.cpp` | — | — | 1,211（783） |
| RD / GLES3 の `area_lights_inc.glsl`（322 / 200） | — | — | 192（185）。GLES3 の側はほぼ全部が写し |

つまり、Forward+ と Mobile の C++ で約 3,900 行、シェーダー本体で約 1,100 行、RD と GLES3 の storage で約 4,600 行（5 行以上続く分）が、手で保っている組になっている。この engine の B（GLSL 553 行 / WGSL 412 行の 34 組＋小さな組 3 つ）と同じ種類の税で、量は 1 桁多い。規模の比で見ても軽くはない。

---

## 観点ごとの根拠

### 1 コアの設計（8 → 7.5）
- 良い: 層がはっきりしている。`RenderingServer`（公開の口）→ `RenderingServerDefault`（スレッドをまたぐ queue）→ `RenderingMethod`（cull・`rendering_method.h:49`）→ `RendererSceneRender`（描き手）→ `RenderingDevice` → `RenderingDeviceDriver`。storage は `servers/rendering/storage/*.h` の抽象クラスで、RD・GLES3・dummy の 3 本が実装する（dummy は 1,598 行で headless を支える）。
- 悪い: 描き手の口 `RendererSceneRender::render_scene` が引数 26 個（`renderer_scene_render.h:325`）。場面の中身を 1 つの値にまとめず、`PagedArray<RID>` の並びを 6 本と RID を 7 個並べて渡す。
- 悪い: 中身への道は `RSG::` の static な 15 個（`rendering_server_globals.h:51-67`）と各 storage の `get_singleton()`。

### 2 モジュールの境界と依存（8 → 6.5）
- 良い: storage の抽象（light 132・texture 116・mesh 79・particles 70・material 39 の純粋仮想）で、描き手と storage を切る形はある。`servers` の C++ に Vulkan・GL の呼び出しは 0 件。
- 悪い: **共有の storage が描き手の本体へ戻って依存している**。`storage_rd` と `environment` が `RendererSceneRenderRD::get_singleton()` を 126 回呼ぶ（sky 37・gi 35・fog 29・light_storage 18・texture_storage 6・render_scene_data 1）。
- 悪い: 共有の `storage_rd/material_storage.cpp:2662-2672` が Forward+ と Mobile の `ShaderData` へ `dynamic_cast` して cull mode を取る（`#ifdef` 2 本）。下の層が上の 2 本を名前で知っている。この engine の B で指摘した「WebGPU が GL のファイルの `Render3d.materialKey` を呼ぶ」と同じ種類。

### 3 API の設計と命名（8 → 7）
- 良い: 動詞と名詞の並びがそろっている（`texture_create`・`light_set_param`・`instance_set_base`）。RD の口も Vulkan 風の語でそろう（`render_pipeline_create` `rendering_device.h:1284`・`uniform_set_create` `:1200`）。
- 悪い: `RenderingServer` の仮想関数 593 個（`rendering_server.h`）で、1 つの class が全部の口を持つ。`render_pipeline_create` は引数 11 個。
- 悪い: シェーダーの版 `ShaderVersion` は enum でなく `uint16_t` の定数の並び（`scene_shader_forward_clustered.h:53-66`。コメントで「数として足すため」と理由は書いてある）。

### ★4 拡張しやすさと保守（8.5 → 6）
- 実例 1（小）: **lightmap の specular**（`use_lightmap_specular`）。描き手の側だけで 12 ファイル。Forward+ と Mobile が同じ組を 6 ファイルずつ（`scene_shader_*.h` の bit・`render_forward_*.h` の bit と bool・`render_forward_*.cpp` の詰める所 4〜5 か所・`scene_forward_*_inc.glsl` の `sc_use_lightmap_specular()`・`scene_forward_*.glsl` の式）、GLES3 が 2 ファイル（`scene.glsl:45` の表と `:2704-2752` の式・`rasterizer_scene_gles3.cpp:3682-3915` の旗と uniform）。**式そのものが 3 回書いてある**（`scene_forward_clustered.glsl:1876-` / `scene_forward_mobile.glsl:1771-`（half 精度の手直し入り）/ `scene.glsl:2704-`）。この engine の SH の例（16 ファイル・式は 1 回）と比べると、ファイルは少ないが式の 2 回書きが残っている。
- 実例 2（大）: **area light**。servers と drivers の 51 ファイル（RD の storage・cluster・gi・fog・volumetric fog・voxel gi・SDFGI のシェーダー、Forward+ と Mobile の両方、GLES3 の 8 ファイル、dummy 3 本、公開の口 4 本）。`area_lights_inc.glsl` は RD と GLES3 に 2 本あり、192 行が一致する。
- 悪い: 変種の bit を手で詰めていて、もう詰まっている。`render_forward_clustered.h:536` のコメント「"uses_lightmap_specular" is excluded as there are no more available bits」。
- 良い: 3 本のうちどれかだけに機能を入れる、という逃げ道は作りとして許されている（GLES3 は area light の一部や SDFGI を持たない）。

### ★5 データの流れ（6.5 → 7）
- 良い: ゲームの側の呼び出しは `CommandQueueMT` に積まれ（`rendering_server_default.h:80`）、描き手のスレッドで流れる。口ごとの写しはマクロ `FUNC*` が 501 個で作る（`server_wrap_mt_common.h:44-85`）。呼び出しの流れが 1 本で、スレッドをまたぐ所が 1 か所。
- 良い: RD の上の命令は `RenderingDeviceGraph`（`rendering_device_graph.h:49`）がいったん記録し、barrier と並びを決めてから driver へ流す。描き手が barrier を手で書かない。
- 悪い: 保持型で、場面の状態は RID の持ち主（`RID_Owner`。servers/rendering で 69 か所）の中にある。毎コマ値から作り直す形ではないので、1 コマの入力を値として取り出して比べることができない（この engine の `List[Scene3d.RenderCmd]` → `Prepared` とは逆）。
- 悪い: cull の結果は `PagedArray` の並び 6 本で描き手へ渡す（1 の 26 引数）。描き手の中ではさらに `RenderDataRD` に詰め直す。

### ★6 副作用の閉じ込め（5.75 → 7）
- 良い: Vulkan・D3D12・Metal の呼び出しは driver の 3 フォルダだけ。servers の C++ で `vk*`・`gl*` を呼ぶファイルは 0。描き手（renderer_rd）は RD を 6,351 か所で呼ぶが、RD 自体は graph に記録するだけの層。
- 良い: スレッドの境界が queue 1 つ（5 の良い所）。
- 悪い: **GLES3 の道は GL を直に呼び、呼ぶ場所が散っている**。GLES3 の .cpp 20 本中 18 本・1,753 か所。`rasterizer_scene_gles3.cpp` の中で並べ替え・cull の結果の詰め・GL の呼び出しが同じ関数にある（`_render_list_template` 922 行）。
- 悪い: 隠れた状態の口が多い。renderer_rd の `get_singleton()` は 3,098 回（34 種類）、GLES3 で 541 回、`RSG::` が 628 回。

### ★7 機種の切れ目（8 → 7）
- 良い: `RenderingDeviceDriver`（`rendering_device_driver.h:90`・純粋仮想 175 個）を Vulkan・D3D12・Metal が実装する（override 147・142・144 個）。シェーダーは SPIR-V を `RenderingShaderContainer`（`rendering_shader_container.h:40`・`_set_code_from_spirv` `:277`）で各機種の形へ変える。D3D12 は NIR 経由で DXIL（`rendering_shader_container_d3d12.cpp:38`）、Metal は SPIRV-Cross で MSL（`rendering_shader_container_metal.cpp:324-664`）。切れ目は 1 か所で、ここはこの engine より良い。
- 悪い: **GL（とブラウザの WebGL2）は RD の下の driver ではなく、描き手まるごと別の 1 本**（C++ 32,647 行＋GLSL 7,806 行）。storage も RD と別に書いてあり、上の表のとおり約 4,600 行が手で保たれた組。
- 悪い: ブラウザは Compatibility だけ（`platform/web/display_server_web.cpp:1010-1013` で使える driver は `opengl3` だけ）。Forward+ と Mobile の機能はブラウザへ出ない。切れ目が「API の違い」ではなく「描き手の違い」になっている。
- 比べ: この engine は切れ目が 3 か所（3D の口・2D の handler・窓）で 6.5。Godot は RD の側の切れ目がきれいな分を上げ、GL の道が別の描き手である分を下げて 7。

### ★8 真実が 1 か所か（6.5 → 5.5）
- 良い: ゲームが書くシェーダー言語は 1 本で、`ShaderCompiler` が RD と GLES3 の両方へ出す（GLES3 の `material_storage.cpp`、RD の `scene_shader_forward_*.cpp`・`renderer_canvas_render_rd.cpp`・`sky.cpp`）。RD の中では GLSL 1 本から SPIR-V・DXIL・MSL を作る（7 の良い所）。
- 良い: GLES3 は変種と uniform を GLSL の頭の表（`scene.glsl:2-45` の `#[modes]`・`#[specializations]`）に書き、ビルドで `*.glsl.gen.h` の C++ の enum を作る（gen.h の include が 96 か所）。uniform の名前を手で 4 か所に配る、というこの engine の GL の税は Godot の GLES3 には無い。
- 悪い: 描き手の内側のシェーダーは 3 本ある。Forward+ と Mobile のシェーダー本体の写しは 1,159 行、GLES3 は書き直した別物。lightmap の specular の式は 3 回（4 の実例 1）、area light の関数は 2 回。
- 悪い: ゲームのシェーダーの組み込みの名前の表（`actions.renames`）が Forward+ と Mobile に 95 行ずつ写してある（`scene_shader_forward_clustered.cpp`・`scene_shader_forward_mobile.cpp`）。GLES3 にも 223 行の別の表。
- 悪い: uniform buffer の struct を C++ と GLSL で 2 回書く。`LightData` は `light_storage.h:140` と `light_data_inc.glsl:5`、`DirectionalLightData` は `light_storage.h:199`・`light_data_inc.glsl:62`・`sky.glsl:86` の 3 か所。大きさを確かめる `static_assert(sizeof` は renderer_rd の .h 全体で 1 か所だけ。この engine の WGSL 側の `UniformLayout`（表 1 つ）の方が良い。

### ★9 不正な状態を型で書けなくする（4.5 → 5）
- 良い: driver の層は資源の種類ごとに別の型の ID を持つ（`DEFINE_ID` 19 種類・`rendering_device_driver.h:101-144`。Buffer・Texture・Pipeline・Shader などを取り違えるとコンパイルで止まる）。この engine の GL の資源が全部 `Int32` なのより良い。
- 悪い: その上の RD と RenderingServer の口は型の無い `RID`（`rendering_server.h` に `RID p_` の引数 481 個・`rendering_device.h` に 115 個）。テクスチャの RID を pipeline の所へ渡しても通り、実行時に `get_or_null` と `ERR_FAIL` で止まる。
- 悪い: RID の種類は実行時の「持ち主に聞く」梯子で決める。`RenderingServerDefault::_free` が 4 段（`rendering_server_default.cpp:52-68`）、その中の `Utilities::free` が 8 段（`storage_rd/utilities.cpp:92-111`）、`get_base_type` が 11 段（`:54-90`）、依存の登録 `base_update_dependency` も 9 段（`:119-160`）、GLES3 の `free` も同じ形（`rasterizer_scene_gles3.cpp:4626-4641`）。
- 悪い: シェーダーの変種の並びは、`push_back` の順番と行末のコメント（`// SHADER_VERSION_DEPTH_PASS`）を合わせることで保っている（`scene_shader_forward_clustered.cpp:651-659`）。順番を入れ替えても通る。specialization は手で詰めた bitfield の union（`scene_shader_forward_clustered.h:101-144`）。変種の組み立ては `#define` の字の連結で、この engine の「字の `+` で組む」と同じ種類。

### ★10 結合と循環（6.25 → 5）
- 悪い: 1,000 行超のファイル 57 本（13%）・3,000 行超 17 本・300 行超の関数 53 個（規模の節）。この engine の B（1,000 行前後 6 本・責務が混ざるのは 3 本）より割合が高い。
- 悪い: **循環がある**。描き手の本体（`RendererSceneRenderRD` と Forward+ / Mobile）が storage を使い、storage と environment が `RendererSceneRenderRD::get_singleton()` で描き手へ戻る（126 回）。`material_storage.cpp` は Forward+ と Mobile の型を名前で知っている（2 の悪い所）。この engine の B では循環は見つかっていない。
- 悪い: 3 本の描き手が同じ処理の写しで結ばれている（規模の節の表）。片方だけ直して食い違う危険が、組の数（Forward+ と Mobile で 35 組）だけある。
- 良い: Forward+ と Mobile の .cpp どうしは互いを include しない（include するのは `renderer_compositor_rd.cpp:38-39` と `material_storage.cpp:38-39` だけ）。

### ★11 拡張の口（8.5 → 7.5）
- 良い: `CompositorEffect` で、ゲームの側から描き手の途中へ処理を差し込める。差し込む所は 5 か所（`rendering_server_enums.h:643-647`）。中身に触る口として `RenderDataExtension`・`RenderSceneBuffersExtension`（`storage/render_data_extension.h:38-97`）があり、GDExtension からも使える。RD 自体をスクリプトへ出している（`rendering_device.cpp` の `_bind_methods` 814 行）ので、compute を自分で書ける。ゲームのシェーダー言語も口として広い。
- 悪い: 差し込む所の数が描き手で違う。Forward+ は 5 か所（`render_forward_clustered.cpp:2257-2562`）、Mobile は 3 か所（`render_forward_mobile.cpp:1193-1426`。POST_OPAQUE と POST_SKY が無い）、GLES3 は 0（`rasterizer_scene_gles3.cpp:280` に「compositor ができたら」のコメントだけ）。ブラウザでは後処理の口が無い。
- 悪い: 新しい描き手の道を足す口は事実上無い。`RenderingMethod` の実装は cull の 1 本だけで、描き手を足すには `RendererSceneRender` の 26 引数の口と storage 5 種の純粋仮想（約 440 個）を埋めることになる。
- 比べ: この engine の 6（属性の口が 16 ファイル・後処理は 2D の Pass だけ）よりは広い。ただし前回の 8.5 は「どの描き手でも使える」前提で付けていた。

### 12 作りの決まりを機械で守る（5.5 → 5・確かめは浅い）
- 良い: GLES3 の変種と uniform は表から C++ を作る（8 の良い所）。シェーダーの組み立てを各機種へ変える所は 1 本（7 の良い所）。
- 悪い: C++ と GLSL の struct の大きさを確かめるのは `static_assert` 1 か所だけ。Forward+ と Mobile の写しの一致や、3 本の描き手の画素を比べる仕組みは、読んだ範囲には無い。
- 限界: `tests/` と `.github/` は sparse に入っていないので、CI の画素の比べがあるかは確かめていない（記憶では、描き手どうしを画素で比べる仕組みは無い）。この観点は ±1 の幅で読んでほしい。

---

## 評価の限界
- sparse の範囲だけ（scene・core・modules・tests・CI は見ていない）。ビルドしていないので、`#ifdef` で外れる部分も行に数えている。
- 関数の切り出しは字の上の簡単な読みで、`#ifdef` の中の括弧で区切りを外す事がある（明らかに外れた 1 件は数から除いた）。似ている度合いは行の一致で、意味の一致ではない。
- 変更の履歴が無い sparse なので、「属性を足す税」は今のソースに残る名前の散らばりで数えた（area light・lightmap の specular）。実際の PR の差分とは少し違う可能性がある。
