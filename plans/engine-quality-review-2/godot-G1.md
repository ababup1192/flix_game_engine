# Godot（master 8f2e46b・2026-11-25）の作りのきれいさ — G1: 芯・シーンの木・拡張の口

読んだ所: sparse clone の core/object・core/variant・core/os・core/templates・core/config・scene/main・scene/3d・scene/resources・servers の根・modules の register_types と config.py。
描き手（servers/rendering・drivers・platform）は G2 の担当なので、境目しか見ていない。観点 7 は G2 の点を待つ（下の表は前回の値を仮に置く）。
物差しは review2-A / B と同じ: ファイル:行で汚れを数える。数は grep と wc の概算（マクロの中や複数行の宣言は落ちる）。

## 規模（担当の範囲）

- core（sparse の 5 フォルダ）+ scene/main・3d・resources + servers の根: **412 ファイル・192,394 行**（servers/rendering を除く）。
- 1,000 行を超えるファイル: **41 本**（うち 2,000 行超が 21 本）。1 万行あたり 2.1 本（この engine の A の範囲は 1 万行あたり約 1.4 本・2,000 行超は 0）。
  大きい順: animation.cpp 6,902・viewport.cpp 5,952・node.cpp 4,312・material.cpp 4,160・window.cpp 3,887・font.cpp 3,833・variant.cpp 3,620・variant_call.cpp 3,181・object.cpp 2,651・scene_tree.cpp 2,290・class_db.cpp 2,145。
- `get_singleton()` の呼び: core + scene の .cpp に **2,683 回**。多い順に RS 822・RenderingServer 525（同じ物に名前 2 つ）・PhysicsServer3D 400・NavigationServer3D 187・Engine 179・DisplayServer 150・OS 75・ProjectSettings 48。
  scene/3d の .cpp の 60/89、scene/resources の 75/107、scene/main の 12/17 が singleton を直に呼ぶ。`static X *get_singleton()` を持つクラスは担当範囲のヘッダに 36 個。
- エディタの混じり: `#if…TOOLS_ENABLED` が core 102・scene/main 46・scene/3d 129・scene/resources 117。`is_editor_hint()` が scene に 126。scene から editor/ の include が 4 本。

## 点の表（10 点満点）

| 観点 | 前回の Godot（2 人の平均・記憶） | 今回（ソースを読んで） | 差 |
|---|:--:|:--:|:--:|
| ★1 コアの設計 | 8 | **7.5** | -0.5 |
| ★2 モジュールの境界と依存 | 8 | **7** | -1 |
| ★3 API の設計と命名 | 8 | **7.5** | -0.5 |
| ★4 拡張しやすさと保守 | 8.5 | **7.5** | -1 |
| ★5 データの流れ | 6.5 | **5.5** | -1 |
| ★6 副作用の閉じ込め | 5.75 | **4.5** | -1.25 |
| 7 機種の切れ目（G2 の担当・仮置き） | 8 | （8） | — |
| 8 真実が 1 か所か（芯の範囲） | 6.5 | **6** | -0.5 |
| ★9 不正な状態を型で書けなくする | 4.5 | **5** | +0.5 |
| ★10 結合と循環 | 6.25 | **5.5** | -0.75 |
| ★11 拡張の口 | 8.5 | **8.5** | 0 |
| 合計（110 点・7 は仮置き） | 78.5 | **72.5** | -6 |
| ★12 作りの決まりを機械で守る | 5.5 | **6** | +0.5 |

前回は「有名で長く使われている」ことに引っ張られて、芯・境界・保守を高く付けていた。ソースを同じ物差しで数えると、
singleton の網・エディタの混じり・巨大ファイルの数で下がる。逆に型（★9）は、C++ の内側が `callable_mp` と `GDVIRTUAL` へ移り切っていて、前回の記憶より良かった。

---

## ★1 コアの設計（7.5）

根拠:
- `core/object/object.h:351` の Object 1 本に、シグナル（:425-426 の `signal_map`・`connections`）・スクリプト（:451）・メタデータ（:452）・GDExtension の実体（:410-411）・エディタの欄（:446-450 `TOOLS_ENABLED`）が載る。
- `object.h:367-385` の `AncestralClass` が、芯の Object の中で `NODE_3D`・`CONTROL`・`MESH_INSTANCE_3D`・`PHYSICS_BODY_3D` など scene のクラスを名前で並べる（速さのための bit。芯が上の層の名前を知っている）。
- `object.h:443` `_is_queued_for_deletion` は pub の欄で、コメントは「SceneTree::queue_delete() が立てる」。芯の型が scene の都合を抱える。
- `scene/main/node.h:199-300` の `Node::Data`（約 100 行）に、multiplayer の権限と `Variant rpc_config`（:238-239）・accessibility（:225）・翻訳（:248, :290-293）・物理の補間（:247, :264-274）・エディタの説明（:221）が同居する。

良い: Object + ClassDB + Variant + RID と抽象のサーバー、という 4 本の柱は 15 年通っていて筋が通る。`callable_mp`（.cpp に 453 か所）で芯の呼び出しが型つきへ移った。
悪い: 芯の Object と Node が、上の層（scene・multiplayer・エディタ・accessibility）の欄を全部抱える。node.h の通知の一覧（:455-513）は 51 個で、窓・OS・エディタ・accessibility の通知まで Node が受ける。

## ★2 モジュールの境界と依存（7）

根拠:
- core → scene の include は **0**、core → servers は **1**（`core/config/engine.cpp:42` が `servers/rendering/rendering_device.h` を読み、:94 で RenderingDevice を引く）。
- scene → editor が **4**（`scene/3d/occluder_instance_3d.cpp:48` は `EditorNode::get_singleton()` を :469 で呼ぶ・`scene/resources/shader.cpp:45`・`skeleton_modification_2d.cpp:38` 他）。`#ifdef TOOLS_ENABLED` で囲ってあるが、向きは逆。
- scene → modules が **13 か所の `#ifdef MODULE_*_ENABLED`**（`scene/resources/streamed_texture.cpp:45-48` が `modules/texture_streaming` を直に include・`dpi_texture.cpp:38-40` が svg・`scene/3d/lightmap_gi.cpp:51-53`）。`core/config/project_settings.cpp:54` も mono のために modules を読む。
- scene/main → scene/gui・2d・3d の include が 19 本（`viewport.cpp:45-81` が gui の Label・Popup、2d/3d のカメラ・音の listener・当たりの物体を読む）。

良い: core が scene を知らない向きは守られている。物理・ナビは抽象のサーバー + Manager で、実装（Godot 物理・Jolt）が modules に分かれる（`servers/register_server_types.cpp:342-373`）。
悪い: 「任意の module」を scene が名前で知る（13 か所）。scene/main が gui と 2d/3d を上から抱え、Viewport が全部の層の合流点になっている。

## ★3 API の設計と命名（7.5）

根拠:
- 命名は `get_`・`set_`・`is_`・`has_` の snake_case でそろう。`get_node` と `get_node_or_null` のように失敗の仕方を名前で分ける。
- 同じ singleton に `RS::get_singleton()`（822）と `RenderingServer::get_singleton()`（525）の 2 つの名前を混ぜて使う。
- 通知は `_notification(int)`（`object.h:549`）で、`node.h:455` は名前の無い `enum {` に「よその node と同じ番号を使うな」というコメント（:456）だけ。
- プロパティの範囲は字の小さな言語で書く（`scene/3d/light_3d.cpp:415` の `"1000,15000.0,1.0,suffix:k"`・`PropertyInfo` の `hint_string` は `core/object/property_info.h:133` の String）。

良い: 名前の決まりが全体でそろい、`GDVIRTUAL`（scene の .cpp で 131 か所呼ぶ）で上書きの口が型つき。`.compat.inc` で古い署名を残してから変える作法がある。
悪い: 通知・プロパティの範囲・シグナル名が字と int で、呼ぶ側から形が見えない。同じ物に名前が 2 つ（RS）。

## ★4 拡張しやすさと保守（7.5）

根拠:
- 互換の作法: `*.compat.inc` が 21 本（`scene/main/node.compat.inc` など）、`node.h:450-451` の `_bind_compatibility_methods`。署名を変えても古いバイナリが動く。
- プロパティの登録は `ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "名前", …), "set_…", "get_…")` が scene に **1,591 か所**。setter と getter は字で書き、型（`Variant::FLOAT`）も setter の本当の型と別に書く。食い違いは起動時の `ERR_FAIL`（`core/object/class_db.cpp:1343-1366`）でしか分からない。
- 「手で合わせ続けろ」のコメントが担当範囲に **36 個**（`core/config/project_settings.cpp:1771, 1774, 1814, 1817`・`core/os/keyboard.h:37`・`core/object/object.cpp:1030`・`scene/3d/cpu_particles_3d.cpp:1615`・`gpu_particles_3d.cpp:909` 他）。
- `servers/register_server_types.cpp:281-373` はサーバーごとに「GDREGISTER → add_singleton → GLOBAL_DEF → Dummy を登録」の同じ 4 段を 4 回写す。

良い: 新しいノード・リソースは GDREGISTER 1 行と `_bind_methods` で足せ、エディタ・スクリプト・保存が自動で付く。互換の作法が厚い。
悪い: 名前と型を字で 2 回書く税が 1,591 か所。「合わせ続けろ」のコメント 36 個は、機械が見ていない約束の数。

## ★5 データの流れ（5.5）

根拠:
- 状態の更新と描く物の組み立てが分かれていない。setter が中で直にサーバーへ書く（`scene/3d/visual_instance_3d.cpp:61, 65, 75, 78, 85, 93, 101, 110, 115` で `instance_set_transform`・`instance_set_scenario` など）。
- `scene/main/scene_tree.cpp:689-` の `process` は、`MessageQueue::flush()` を 2 回（:716, :723・どちらも「small little hack」のコメント）、`flush_transform_notifications()` を 4 回、間にタイマー・tween・削除・accessibility・idle の callback を挟む。:783-784 に「ここにも flush が要るかも」の ToDo。順番が後から足された継ぎ足しで、どこで状態が確定するかは読まないと分からない。
- 更新の順は通知（int）と `call_deferred` と process_priority の 3 本で決まる。`call_deferred` は MessageQueue（singleton）に積まれる。

良い: サーバーの側は RID とコマンドの列（`servers/server_wrap_mt_common.h` 813 行）で、描き手のスレッドとは切れている。木の外から見ると「ノード → サーバー」の一方向。
悪い: 木の中では、どのノードの setter もいつでも全域のサーバーに書ける。1 コマの中で状態が決まる点が 1 か所に無い（flush が散らばる）。この engine の `(Frame, w) -> w` → View と比べると、流れの形がコードに出ていない。

## ★6 副作用の閉じ込め（4.5）

根拠:
- `get_singleton()` の呼びが core + scene の .cpp に 2,683 回。scene/3d の 2/3 のファイルがサーバーの singleton を直に呼ぶ。
- 時計を直に読む: `scene/main/scene_tree.cpp:307`・`scene/resources/animated_texture.cpp:45, 47`・`streamed_texture.cpp:77, 123`・`scene/main/multiplayer_peer.cpp:41`（`OS::get_singleton()->get_ticks_*`）。
- 設定を全域から字で読む: `GLOBAL_GET` が 106 回・`GLOBAL_DEF` が 173 回（core・scene・servers の根）。scene の中から `scene/resources/world_2d.cpp:55-58` のように直に読む。
- `core/os/os.h` の OS は virtual 119 個で、時計（:287）・プロセス（:219-224）・環境変数（:236-238）・ファイルの置き場（:333-334）・動的ライブラリ（:203）・URL を開く（:230）を 1 つの singleton に持つ。

良い: OS・DisplayServer・各サーバーは抽象クラスで、機種ごとの実装に差し替わる。物理・ナビは Dummy の実装を登録する（`register_server_types.cpp:290, 324, 337, 373`）ので、画面なしで回せる。
悪い: 差し替えは「プロセス全体で 1 個」の粒度だけ。ノードの単位で時計や設定を差し込む口は無く、テストでは singleton ごと立てるしかない。

## 8 真実が 1 か所か（6・芯の範囲）

根拠:
- 設定の鍵の字 `"rendering/lights_and_shadows/use_physical_light_units"` が **18 か所**に写されている（`scene/3d/light_3d.cpp:129, 281, 352`・`scene/resources/environment.cpp:120, 1218`・`camera_attributes.cpp:62, 105, 462`・`material.cpp:2218, 2230, 2596`・定義は `servers/rendering/rendering_server.cpp:3689`）。同じ鍵を 2 回以上読む字は 22 種。
- `NOTIFICATION_TRANSFORM_CHANGED = 2000` を `scene/3d/node_3d.h:235` と `scene/main/canvas_item.h:235` の 2 か所に「SceneTree と合わせ続けろ」のコメントつきで書く。`NOTIFICATION_OS_MEMORY_WARNING = 2009` 〜 2020 も `core/os/main_loop.h:50-61` と `scene/main/node.h:497-508` に同じ数を 2 回書く。
- `modules/navigation_3d/config.py:5` が依存を `"navigation"`（今は無い名前）の鍵で登録している。module の依存は字の名前で、誤りを誰も止めない（たぶん効いていない宣言）。
- ClassDB の `ClassInfo` が `inherits_ptr`（`class_db.h:122`）と `gdtype`（:124・親の名前は GDType 側）の 2 つで親を持つ（GDType への移行の途中）。

良い: GDExtension の C の口は生成物（`modules/register_module_types.h:32` の `gdextension_interface.gen.h`）で、元が 1 つ。module の初期化の段も GDExtension の段の値をそのまま使う（:34-39）。
悪い: 通知の番号と設定の鍵は「字と数を写す」で 1 か所にない。

## ★9 不正な状態を型で書けなくする（5）

根拠:
- `core/variant/variant.h:97-147` の Variant は 39 種。scene のヘッダの宣言 7,663 本のうち Variant を受けるか返すのは **259 本（約 3.4%）**。node.h は 224 本中 24 本（約 11%・`call`・`rpc`・メタ・`set_deferred` 周り）。C++ の内側の API の大半は型つき。
- RID は型の引数が無い 1 つの型（`core/templates/rid.h:38`）。scene の宣言 224 本が RID を受け渡し、メッシュの RID を光の関数に渡しても型は止めない（`RID_Alloc::get_or_null`・`rid_owner.h:191` の実行時の検査だけ）。
- 実行時の守り: `ERR_FAIL*` が core + scene の .cpp に **3,523 回**、うち `ERR_FAIL.*is_inside_tree()` が 73 回（木に入る前に呼べてしまう関数の数の目安）。`cast_to<>` が scene に 371 回。
- シグナルは名前の字と Variant の可変長引数（`object.h:775-784`）。`emit_signal(SNAME("…"))` 52 回・`emit_signal("…")` 32 回・定数（`SceneStringName`）87 回。宣言との数や型の食い違いは実行時に分かる。

良い: 字で組む `Callable(this, "…")` は 0 本、`->call("…")` 系は 10 本まで減り、`callable_mp`（453）と `GDVIRTUAL` に置き換わった。`TypedArray` が scene のヘッダに 71 回。前回の記憶（4.5）より良い。
悪い: RID・通知の int・プロパティの範囲の字・シグナルの名前と引数・ProjectSettings の鍵と、境目の 5 本が型を持たない。守りは 3,500 の実行時の検査に頼る。

## ★10 結合と循環（5.5）

根拠:
- 1,000 行超が 41 本・2,000 行超が 21 本（上の規模）。
- `scene/main/viewport.cpp`（5,952 行・include 41）が GUI の入力（`gui_` が 126 か所）・物理の picking（54）・音の listener（62）・2D/3D のカメラ（79）・XR（53）・描画の設定（msaa・scaling・taa など 190）を抱える。`#if` が 57 個、うち 3D・物理・XR を外す分岐が 26。
- Node・SceneTree・Viewport・Window がお互いを include する（`node.cpp:52-54` が scene_tree・viewport・window、`scene_tree.cpp:50-52` が node・viewport・window、`viewport.cpp:50-51`、`window.cpp:43`）。ヘッダは前方宣言で切ってあるが、実装は 4 つで 1 つの塊。
- `scene_tree.cpp:35-73` の include は 32 本で、Tween・音・gui の Control・multiplayer・パックしたシーン・物理 2D/3D・描画・表示・accessibility のサーバーまで届く。

良い: ヘッダの循環は前方宣言で切り、`_3D_DISABLED` などの旗（scene/main に 76 か所）で機能をまとめて外せる。
悪い: 神クラスが 4 つ（Object・Node・Viewport・SceneTree）。singleton 36 個の網を全部のノードが直に掴む。この engine の A（1,000 行超 8 本・2,000 行超 0・パッケージの循環 0 を型で止める）より結合は強い。

## ★11 拡張の口（8.5）

根拠:
- module と GDExtension が同じ初期化の段（CORE・SERVERS・SCENE・EDITOR）を使う（`modules/register_module_types.h:34-39`）。module は `register_types.cpp` の 1 関数と `config.py` の `can_build` だけで足せる（`modules/gridmap/register_types.cpp:43-58`・`modules/gridmap/config.py:1-14`。60 個の module が同じ形）。
- 物理は名前で登録して差し替える: `modules/jolt_physics/register_types.cpp:60` と `modules/godot_physics_3d/register_types.cpp:57` が同じ `PhysicsServer3DManager::register_server` を呼ぶ。設定 1 つで実装を選べる。
- ClassDB への登録は `GDREGISTER_*` で scene・servers・modules に 408 か所、全部が同じマクロ（`core/object/class_db.h:565-586`）。`register_extension_class`（:295）で外のバイナリも同じ表に入る。

良い: エンジンを直さずにノード・リソース・サーバーの実装・スクリプトの言語まで足せる。Bevy の Plugin と並ぶ口の広さ。
悪い: module の間の依存は字の名前（`config.py` の `module_add_dependencies` は 60 個中 12 個だけが書き、上の navigation_3d の誤りもある）。通知の番号は全域で 1 つの int の空間で、拡張が番号を選ぶ規則は node.h:456 のコメントだけ。scene が任意の module を `#ifdef` で名前で知る（★2 の 13 か所）。

## ★12 作りの決まりを機械で守るか（6）

ソースから分かる物:
- `object.h:871` の `static_assert`（GDCLASS を付け忘れた型を止める）など、core/object と core/variant に static_assert が 43 個。
- `*.compat.inc` 21 本と `_bind_compatibility_methods`。互換の決まりはコードの形になっている。
- 設計の層（core が scene を読まない）は守られているが、守っている仕組みはソースの中に見当たらない（SCons の SCsub は include の向きを見ない）。scene → editor の 4 本・scene → modules の 13 本が通っているのは、門が無いことの裏付け。

記憶（CI の設定は手元に無い）:
- CI の静的検査は clang-format・ファイルの形の検査（ライセンスの頭・行末）・一部の clang-tidy・doctest の単体テスト。
- `misc/extension_api_validation/` で、GDExtension の API を壊す変更は理由の行を足さないと CI が落ちる。doctool で ClassDB と doc_classes の食い違いも止める。設計の決まりの中で機械が守る数少ない物で、+0.5 はここ。
- 層・ファイルの大きさ・singleton を新しく呼ぶことを止める lint は無い（と記憶）。

良い: 公開 API の互換は機械で守る。
悪い: 層の向き・大きさ・副作用の置き場は人のレビューだけ。この engine の 9（層の木を型検査・max-lines・lint-forbid）には届かない。

---

## 評価の限界

- sparse の範囲だけ。core/io・core/input・core/extension・scene/gui・scene/2d・editor は読んでいない（core/extension は include の先として名前だけ見た）。
- 数は grep の概算。マクロで作る宣言と複数行の宣言は落ちるので、Variant の割合と宣言の数は ±20% で読んでほしい。
- 観点 7 は G2 の点で置き換える。合計 72.5 は 7 を前回の 8 で仮置きした値。
- 点は筆者の物差しで ±1。前回の点（記憶）との差のうち、5・6・10 の下げは「数えたら思ったより多かった」、9 の上げは「callable_mp への移行が記憶より進んでいた」による。
