# エンジンのコードと作りの質の評価（Godot 4.x・Bevy・LÖVE と並べて）（2026-11-03）

対象: worktree `.claude/worktrees/asset-import-design-9784f5`（ブランチ feat/3d-kit = 0.75.0 + 3D 拡張の段 1・段 2 の WIP コミット + 作業中の段 3）。
比べる相手: Godot（master・浅い sparse clone: servers/rendering・scene/3d・scene/main・core/object・tests/scene）、Bevy（main・bevy_ecs・bevy_render・bevy_pbr・bevy_app・bevy_asset・bevy_core_pipeline・bevy_camera）、
LÖVE（main = 12.0 の開発版・src/modules の graphics・audio・event・filesystem・love・timer・keyboard・physics と testing/）。
評価だけで、エンジン・ゲームのファイルは変えていない。行番号は 2026-11-03 の作業ツリーの物（段 3 は作業中なので動く）。

---

## 総評（15 行）

1. **コアは 3D に活きている。** 3D の場面は 2D の描き物の列の中の 1 項目（`Render.Item.Scene3d`・`engine_world/src/Render.flix:61`）で、View → PlacedItem → 2 つの描き手、という 2D の流れにそのまま乗った。Pass・後処理・Doc の読み直し・Flow の再生・F8・描き出しの鍵・gl-parity は、3D のために作り直していない。
2. 材質は 2D の宣言シェーダー（`ShaderDoc`）を使い回し、GLSL（`ShaderGen`）と CPU（`ShaderEval`）の 2 つの出口もそのまま使っている。これは良い再利用。
3. 歪みは 3 か所: (a) 3D の光の式を GLSL と Flix に**手で 2 回**書いている（`Render3d.flix:4-21` と `SoftRaster3d.flix:5-30` のコメントで同期をとっている）、(b) 2D の GL の道が `Render3d` を静的に抱えている（`Paint.flix:52`・`Frame.flix:23`）、(c) F8 と注釈は 3D の場面を 1 枚の矩形としか見ない（`Annotate.flix:294,357`）。
4. **正しさの守りは 4 者の中で一番厚い。** 純粋な update と view、決定的な再生（`App.traceFrame` 1 本）、テストは 2,373 件（engine 749・engine_world 1,334・engine_tools 204・render_gl 86）、2 つの描き手の画素の突き合わせ（gl-parity 39 場面）、描き出しの鍵のテスト。Godot・Bevy・LÖVE のどれも、描画を画素で突き合わせる仕組みをこの密度では持っていない。
5. **性能の作りは一番弱い。** 1 スレッド、3D は置いた物ごとに draw call 1 回、インスタンシングなし、カリングは線形の判定だけ、毎コマ不変の列を組み直す。今の規模（一人称の 1 棟・数百の置いた物）では足りているが、伸びしろは小さい。
6. 描画の機能は桁が違う。Lambert・半球光・トゥーン・点 8・スポット 2・影 1 本・lightmap・法線マップ・スキン・HDR・トーンマップ・FXAA はある。線形の色・半透明・MSAA・PBR・平行光と段の影・GI は無い（段 4・5 の計画にある物もある）。
7. 2D の機能と作りは LÖVE と同じくらいか、上回る所がある（Doc・UI・音のミキサー・Flow・描き出し）。ただし 1 コマで描ける物の数は LÖVE の自動のまとめ描きより 1 桁少ない（予算 2,000 個）。
8. API の作法は揃っている: `xxx(..)` で作り `withXxx` で替える、外から作らせない型は enum で包む（`Scene3d.Material3d`・`Instance3d`・`Mesh3d`）、Godot・Unity の語に揃える（`moveAndSlide`・`snapToFloor`・`innerFovY`）。
9. API の穴は小さいが鋭い: 材質の GPU のキャッシュの鍵が**ゲームの付けた名前**（`Render3d.materialKey`・`withSpecName`）で、名前と中身が食い違うと毎コマ組み直す。Godot も Bevy も中身か handle で鍵を作る。
10. 保守の仕組み（移行メモ 181 本・生成した API の目次・lint 30 種・agent-eval 99 題・3 つの門・計画のレビュー点数）は、1〜2 人のプロジェクトとしては異例に厚い。その分、描画の属性を 1 つ足すたびに「GL・CPU・鍵・対応表・gl-parity」の 5 か所を払う税がある。
11. ゲームを作る側: 2D のテンプレと 3D のゲームはトップの形が同じ（`App.game` + `Controls.step` + `View.frame`）。この型がそろっていることが、コアが活きている一番の証拠。
12. ただし 3D のゲームは、後処理（ブルーム）・読み込み画面・GPU を温める処理・当たり判定を 2 本とも自前で書いた。エンジンが後から吸い上げている途中（段 1〜3）で、ゲーム側はまだ置き換えていない。
13. ブラウザ・他の機種へは**まだ持っていけない**（デスクトップの JVM だけ）。effect の後ろに窓・入力・音・ファイルを隠した作りは良い骨格だが、契約層が `javax.imageio` を import し（`Texture3d.flix:6,10`）、開発の道具が起動の道に入っている。計画（TeaVM）は 13〜21 週。
14. 点数（10 点満点 × 9 観点）: Godot 73・Bevy 70・LÖVE 57・このエンジン 55。合計はこの順だが、観点ごとに見ると「正しさ」でこのエンジンが一番、「性能・機能・持ち運び」で一番下になる。
15. 一番効く直し: 3D の光の式を 1 つの元から GL と CPU へ出す・材質の鍵を中身から作る・3D を `Scene3dRenderer` の口で 2D から外す・同じ形の物をまとめて 1 回で描く・後処理（ブルーム）と GPU を温める処理をエンジンへ。

### 点数の表

| 観点 | このエンジン | Godot 4.x | Bevy | LÖVE |
|---|:--:|:--:|:--:|:--:|
| 1 コアの設計 | 7.5 | 8 | 9 | 5 |
| 2 モジュールの境界と依存 | 6 | 8 | 8.5 | 8 |
| 3 API の設計と命名 | 7 | 8 | 7.5 | 8.5 |
| 4 正しさの守り | **8.5** | 6.5 | 7 | 5 |
| 5 性能の作り | 4.5 | 8 | 8.5 | 6.5 |
| 6 描画の質と機能の広さ | 4 | 9 | 8.5 | 3 |
| 7 拡張しやすさと保守 | 7.5 | 8.5 | 7.5 | 7 |
| 8 ゲームを作る側の体験 | 6.5 | 9 | 6 | 7.5 |
| 9 ブラウザ・他の機種 | 3.5 | 8 | 7.5 | 6.5 |
| **合計（90 点満点）** | **55** | **73** | **70** | **57** |

物差しの決め方:
- 1 つの物差しを 4 者に当てる。機能の量の差は 6 だけに効かせ、ほかの観点では「今の規模で作りが筋の通った物か」を見る。
- 規模の差を言い訳にしない（6 と 5 は今の数字のまま低く付けた）。逆に、Godot・Bevy の規模を作りの良さと取り違えない（4 は Godot・Bevy より上にした）。
- LÖVE は 2D のフレームワークで、3D とエディタを**持たない**。1 と 6 は 3D の分が 0 になるのでそのまま低い。2D だけの比べは §10 に分けた。

---

## 1. コアの設計

### 良い所
- **render-from-World の 1 本道**: 系は `(Frame, w) -> w` の純粋な関数で、View は進んだ後の World を読むだけ（`engine_world/src/App.flix:1-7`）。3D もこの道に乗り、`Render.scene3d(at, cmd)`（`Render.flix:200-203`）で 2D の列に入る。2D の z の並びの 1 点に入り、その中だけ深度で前後を決める（`Render.flix:54-61`）。Bevy の「main world から描く物を抜き出す」（`bevy_render/src/lib.rs:105-110` の `ExtractSchedule`・<https://bevyengine.org/learn/quick-start/getting-started/ecs/>）と同じ考え方を、もっと単純な形（毎コマ値の列を作る）で持っている。
- **effect と handler で外の世界を隔てた**: `eff Game`・`eff Audio`（`engine/src/GameEngine.flix:316,416`）、`eff Shader`（`engine/src/ShaderEffect.flix:37`）。3D の描き口 `drawScene3d` は `eff Shader` に足したので、`eff Game` を張る全部の handler は無傷のまま（`ShaderEffect.flix:3-6` の WhyNot）。`runNoop` で「描けない」を素直に表せる（`:51-55`）。
- **フレームを流す所が 1 つ**: 実機・trace・性質テスト・Flow・リモートの /step が全部 `App.traceFrame` を呼ぶ（`docs/flow.md:22-26`）。3D のゲームも e2e の flow（night 7 本・fps 5 本）をそのまま使っている。
- **3D の値は閉じた型 + 作る関数**: `Scene3dCmd` は開いたレコードで `{ instances = .. | s }`、置いた物・材質・ビルボードは閉じた型（`engine/src/scene3d/Scene3d.flix:92,170,311,338`）。
- **形を中身の hash で引く**: `Mesh3d` は作る時に hash を計算し（`engine/src/scene3d/Mesh3d.flix:20-23`）、GL はその鍵で VBO を持ち回す。値を毎コマ作り直しても GPU には上げ直さない。Bevy の `RenderAsset`（`bevy_render/src/render_asset.rs`）の役を、hash で代わりにしている。

### 悪い所
- **3D の光の式が 2 つある**: GLSL（`render_gl/src/Render3d.flix:4-21` の式と本文）と Flix（`engine_tools/src/SoftRaster3d.flix:5-30` と本文）。同期はコメントの「式を変える時は両方を直す」と gl-parity の B 段階（許す差 100〜800 px・`bench/gl_parity/src/Scenes.flix:66-90`）だけ。2D の宣言シェーダーは 1 つの木から 2 つの出口を出す作り（`ShaderGen` / `ShaderEval`）なのに、3D の光の本体はその作りに乗っていない。
- **3D を足したことで 2D の描き手が太った**: `Paint` のレコードが `render3d = Render3d.State` を持ち（`render_gl/src/Paint.flix:52`）、2D の並べ替えの型が `MScene3d(Render3d.SceneItem)` を持つ（`render_gl/src/Frame.flix:23`）。2D だけのゲームでも Render3d の GL の呼び出し 255 か所が静的につながる（ブラウザの計画 `plans/engine-browser.md` のフェーズ 1 でも同じ指摘）。
- **F8・注釈は 3D の中に入れない**: 3D の場面は `{ position, size }` の矩形 1 つ（`engine_world/src/Annotate.flix:294-295`）、ヒットも `kind = "scene3d", name = ""`（`:357-358`）。2D の「指した物の名前と z」が、3D の置いた物には出ない。

Godot との比べ: Godot は Node の木（`scene/main/node.h`）と RenderingServer（`servers/rendering/rendering_server.h:66`）を RID で分け、2D（`renderer_canvas_cull.cpp`）と 3D（`renderer_scene_cull.cpp`）は別の道。2D と 3D の混ぜ方は Viewport の重ね合わせで、このエンジンの「2D の列の 1 項目として 3D を置く」ほうが軽い。ただし Godot は状態を持つ場面（保持型）なので、毎コマ全部を値で作り直す代金が無い。

点: このエンジン 7.5（1 本道と effect の切り方は Bevy と並ぶ。光の式の二重と静的な抱え込みで減点）・Godot 8・Bevy 9（main world と render world の分け方・抜き出しの段が型と schedule で決まっている）・LÖVE 5（`love.run` のコールバックだけ。設計と呼べる物は小さく、3D は持たない）。

---

## 2. モジュールの境界と依存

### 良い所
- 4 つのパッケージ（契約層 engine・GL の render_gl・ランタイムの engine_world・CPU の描き手と描き出しの engine_tools）。上の 3 層は `.layers/<層>/` で engine と自分のソースだけを 1 本の木にして検査するので、render_gl から engine_world は引けない（`Makefile:28-38`）。
- 3D は `engine/src/scene3d/`（17 ファイル・3,753 行）に集まり、2D の型と混ざっていない。歩く体は engine_world（`CharacterBody3d.flix`）、形と格子は engine（`CollisionShape3d`・`CollisionWorld3d`）。Godot の `scene/3d/physics/character_body_3d.cpp` と `servers/physics_3d` の分け方に近い。
- `eff Game` に描画の口を足さない判断が、コメントに理由つきで残っている（`ShaderEffect.flix:3-6`）。

### 悪い所
- **契約層が JVM の画像の部品を import している**: `engine/src/scene3d/Texture3d.flix:6,10`（`java.awt.image.BufferedImage`・`javax.imageio.ImageIO`）。`GameEngine.ensureMainThread` は `ProcessBuilder` で自分を起動し直す（`GameEngine.flix:456-485`）。「依存ゼロの契約層」（`Makefile:24`）と言いながら、デコードと起動の仕方を抱えている。
- **3D の描き口の名前が `eff Shader`**: `drawScene3d` が「シェーダー面の描画チャンネル」（`ShaderEffect.flix:36-46`）に入っている。理由（handler を壊さない）は正しいが、名前が中身と合わなくなった。
- **大きなファイル**: `engine_world/src/App.flix` 2,508 行（`with*` が 30 個）、`render_gl/src/Render3d.flix` 2,022 行、`engine_tools/src/SoftRaster.flix` 1,815 行、`engine_world/src/Render.flix` 1,442 行。App は 37 欄の Rec を enum で包んで型検査の重さを避けている（`App.flix:13-16`）が、ファイルの責務は広い。
- **数の関数が `Vec2` にいる**: `Vec2.sqrt`・`Vec2.cos`・`Vec2.atan2` を 3D の箱・カメラ・光が呼ぶ（`Scene3d.flix` の `spotConeOf`・`shadowCamera`、`CharacterBody3d.flix:73`、全部で 37 か所・16 ファイル）。`Num` か `Math` の役。
- **2D の形が `render/` にいる**: `engine/src/render/CollisionShape2D.flix`（916 行）は描画のフォルダにあり、3D の形は `scene3d/`、2D の体は engine_world の `Physics2D`。2D と 3D で置き場の決まりが揃っていない。

比べ: Godot は RenderingServer の後ろに RenderingDevice（`servers/rendering/rendering_device.h`）と描き方の差し替え（Forward+ / Mobile / Compatibility）を置く。Bevy は crate と Plugin で切り、描き手は wgpu の後ろ。LÖVE は module ごとに `conf.lua` で外せ（`t.modules.physics = false`）、各 module が C++ の本体と `wrap_*.cpp`（Lua の口）に分かれる（`src/modules/graphics/wrap_Graphics.cpp` など）。描き手も `graphics/opengl`・`metal`・`vulkan` に分かれた。

点: このエンジン 6・Godot 8・Bevy 8.5・LÖVE 8。

---

## 3. API の設計と命名

### 良い所
- **作る関数 + `with*` の作法が 2D と 3D で同じ**: `Scene3d.spotLight(p, t, fov)` を `{ innerFovY = Some(..) | .. }` で替える（`Scene3d.flix:24-27`）、`meshInstance |> withMaterial |> withLightmap`、`CharacterBody3d.settings(r, h)` を `{ stepHeight = .. | }` で替える（`CharacterBody3d.flix:18-27`）。欄が増えてもゲームの字が止まらない、という理由が doc に書いてある。
- **業界の語に揃えた**: `moveAndSlide`・`snapToFloor`・`floorMaxAngleDeg = 45`（Godot と同じ既定）・`innerFovY`（Unity の Inner Spot Angle・Bevy の `inner_angle`）・`Frustum.intersectsBox`・`Ray3d.pickNearest`・`Model3d.findNode` / `nodesWithPrefix`。`docs/scene3d.md` に「Godot の何に当たるか」が書いてある。
- **型で誤りを止める**: 時計の種類を型で分ける（`Clock.Time[Clock.Real]`・`App.flix:39`）、uv とタンジェントを 1 つの Option にまとめて「uv だけある形」を作れなくする（`Mesh3d.flix:15-17`）、同じ型の Bool 2 つは名前つきレコードで渡す（`Render.spriteFlipped`・`Render.flix:73-79`）。
- 不正な値の直し方が 1 か所に集まっている（`Scene3d.spotConeOf`・`lightmapOf`・`CollisionWorld3d.build` の NaN の扱い）。

### 悪い所
- **材質のキャッシュの鍵がゲームの付けた名前**: `Render3d.materialKey` は `"3d" + 頂点の形 + "+em" + ":" + spec#name`（`render_gl/src/Render3d.flix:1016-1018`）。名前が同じで木が違う材質が並ぶと毎コマ組み直すので、ゲームが `Scene3d.withSpecName` で名前を替える決まりになっている（`Scene3d.flix:108-125`・`docs/scene3d.md` の emissive の節）。night_apartment の `Stage.renamed` はこの回り道。Godot は Material の RID、Bevy は `Handle<M>` と bind group の中身で鍵を作るので、利用者に鍵の衝突を考えさせない。
- 光の上限（点 8・スポット 2・影 1 本）が API に出ていて、超えた分は黙って目に近い順に選ぶ（`Scene3d.maxPointLights`・`pickLights`）。doc に書いてあるが、型や診断では知らせない。
- `App.Frame` のマウスは左ボタンだけ（`mouseDown`・`mouseClicked`・`App.flix:27-30`）。右と中のボタンは無い。
- 3D の値の一部は開いたレコード（`Scene3dCmd`・`SpotLight`・`Settings`）、一部は閉じた型で、どちらにするかの決まりが「欄が増えそうか」の判断に任されている。段 1 で `SpotLight` に欄を足し、移行メモが要った（`docs/migrations/0.76.0.md`）。

比べ: Godot は Node の property と signal で一貫しているが、`Variant` の動的な型で誤りは走らせて分かる。Bevy は型で止める力が強いが、版ごとに名前が大きく変わる（0.15 → 0.16 → 0.17 の移行ガイドは毎回数十項目）。LÖVE は `love.graphics.draw(drawable, x, y, r, sx, sy, ox, oy)` の位置引数の並びで、型の守りは無いが覚える物が少ない。

点: このエンジン 7・Godot 8・Bevy 7.5・LÖVE 8.5。

---

## 4. 正しさの守り

### 良い所
- **テストの量**: engine 749 件（43 ファイル）・engine_world 1,334 件（115）・engine_tools 204 件（17）・render_gl 86 件（11）。3D だけでも Scene3d 19・ShaderWorld3d 39・Gltf 25+15+14+3・Mesh3dUv 20・Ray3d 14・CollisionShape3d 12・CharacterBody3d 20・SoftRaster3d 36+18+3 など。
- **2 つの描き手の突き合わせ**: gl-parity の 39 場面（`bench/gl_parity/src/Scenes.flix:44-50`）。A 段階はバイト一致、B 段階は「違う画素の数の上限」と、その上限の根拠（式を取り違えた時は桁が変わる）をコメントで書く（`:52-90`）。カリングは画素では見えないので「描いた数」を期待値で確かめる（`expectedDrawnOf`・`:93-96`）。`docs/backend-parity.md` に対応表と「SoftRaster が黙って落とすのは禁止」の決まり。
- **描き出しのキャッシュの鍵を型で守る**: `DrawHash` はレコードの全部の欄をパターンで書くので、欄を足すとコンパイルで止まる（`plans/engine-round10-3d-kit.md` §1）。偽の緑を型で防いでいる。
- **決定性**: 系が純粋、時計は App が置く、押し出しは並びの順で足す（`CharacterBody3d` の doc・`docs/scene3d.md`）。ゲームのテストも決定的な性質テスト（night `TestWalkProperty`: 480 件 + 端の 25 件で食い込み 2 cm 以下）と、18,000 コマを自動で歩かせる筋書きのテスト（`TestPilot`）を持つ。
- **エラー処理の決まりが 3 択で 1 本**（`docs/error-handling.md`）: 既定値で続けて 1 行言う・`Err`・`bug!`。3D の新しい口も `Log.fellBackThen` / `warnThen` で揃っている（`CollisionWorld3d.flix:35-40`）。毎コマ通る知らせは鍵ごとに初回 1 回（`Render3d.warnTextureOnce`）。

### 悪い所
- **3D の突き合わせは近似だけ**: 3D の場面は全部 B 段階（`Scenes.flix:52-90`）。上限 100〜800 px の中で、光の式の小さな食い違い（例えば減衰の 2 乗の位置）は見逃しうる。
- **GL の描き手のテストが薄い**: render_gl は 86 件。GL の状態（blend・深度・sampler の戻し）は gl-parity を手で回した時だけ見る（CI に載せない判断・`docs/backend-parity.md` の最後）。
- **`List.sortBy` が安定でないことを前提にした回り道**（`Render3d.flix:763-765` の WhyNot）。並べる鍵に元の番号を足せば済む物を、間引いた物も並べてから飛ばす形で避けている。
- 3D の game 側のテストに effect のモックは無く（調べた範囲で `with handler` 0 件）、描き出しは `@Test` ではなく gallery のスナップショットで見ている。

比べ: Godot は doctest の単体テスト（`tests/scene` だけで 80 ファイル・TEST_CASE 361 個）と、描画の画素の回帰は持たない（描画は手と issue で見る）。Bevy は Rust の型と所有で多くを止め、bevy_ecs だけで `#[test]` が約 1,000 個、bevy_render と bevy_pbr は約 75 個。例のスクリーンショットを CI で撮る仕組みはあるが、2 つの描き手を突き合わせる形ではない。LÖVE は C++ の単体テストを持たず、Lua の lövetest（`testing/`・graphics 105 件など。絵を期待の PNG と比べる）がある。

点: このエンジン 8.5・Godot 6.5・Bevy 7・LÖVE 5。

---

## 5. 性能の作り

### 良い所
- **重さの道具が揃っている**: GPU の時間（`render_gl/src/GpuTimer.flix`・段 1）、`FrameDiagnostics` の 3D の数（置いた物・描いた物・draw call）を `App.withDiagnostics` でゲームの画面に出せる、ヒッチの記録、絵の値段の自動検査（`docs/performance.md` §9・§11）。
- **作り直さない仕掛け**: 形は hash で GPU に持ち回す、材質のプログラムはキャッシュ（`Render3d.materialEntry`・`:1021-1030`）、使わなくなった物は世代で引退させる、2D は sprite のインスタンス描き（`Frame.flix:461`）と静的な層（`StaticLayerCmd`）を持つ。
- **カリング**: 視錐台の外の置いた物を GL・CPU・影の地図で同じ判定で間引く（`Scene3d.isOutsideFrustum`・`:223-231`）。外れる側に倒し、間引いた物も GPU に残す（振り向いた時に上げ直さない）判断が doc にある。
- **二乗を書かない決まりと一覧**（`docs/performance.md` §7）。当たり判定は xz の格子（`CollisionWorld3d.build`・`:35-51`）。

### 悪い所
- **1 スレッド**: 系・View・描き手・SoftRaster が同じスレッドで流れる（engine と engine_world の src に並列の処理は見当たらない）。Bevy は系を自動で並列に回し（`bevy_ecs/src/schedule/executor/multi_threaded.rs`）、描くのを次のコマの更新と重ねる（`bevy_render/src/pipelined_rendering.rs`）。Godot は描画を別のスレッドに出せ、カリングを WorkerThreadPool で割る。
- **3D はまとめて描かない**: 置いた物ごとに draw call 1 回。プログラムの順に並べるだけで（`Render3d.flix:765`）、同じ形 × 同じ材質をインスタンスで 1 回に描く処理は無い（render_gl で `Instanced` を使うのは 2D の sprite とタイルだけ）。
- **カリングが線形**: 置いた物を毎コマ全部判定する。Godot は場面の中の物を BVH（`renderer_scene_cull.cpp:1222-1271` の `indexers[...].aabb_query / convex_query`）で引き、遮蔽のカリングも持つ（`renderer_scene_occlusion_cull.cpp`）。Bevy は GPU でカリングする道も持つ（`bevy_camera/src/visibility/mod.rs:748,884` の `check_visibility_cpu_culling` / `gpu_culling`）。
- **毎コマ値を組み直す**: View は毎コマ不変の `List[PlacedItem]` と `Scene3dCmd` を作り、2D の予算は動的な描き物 2,000 個（`docs/performance.md` §1 の予算の門）。LÖVE は 1 コマに数万の sprite を自動のまとめ描きで出せる（`src/modules/graphics/Graphics.h:916-917` の `requestBatchedDraw` / `flushBatchedDraws`）。
- 点光源は 8 本でフォワード（場面全体で 8 本を選ぶ）。部屋の数が増えると、ゲームが部屋ごとに描くかを決める（night `Rooms.isDrawn`）しかない。Godot の Forward+ と Bevy は光をクラスタに分ける（`bevy_pbr/src/cluster`）。

今の規模での十分さ: night_apartment（1 棟・数百の置いた物・lightmap）と fps3d_lab は、計画の数字（部屋 8.8 ms）で 60 fps に入っている。大きな屋外・数千の置いた物・十数の動く光では、まとめ描き・空間の索引・光のクラスタの 3 つが要る。

点: このエンジン 4.5・Godot 8・Bevy 8.5・LÖVE 6.5（自動のまとめ描きと SpriteBatch は強い。1 スレッドの Lua で、カリングは利用者の仕事）。

---

## 6. 描画の質と機能の広さ

### ある物（このエンジン）
- 2D: sprite・字（SDF）・箱（角丸・枠・縞・市松）・多角形（頂点の色）・型抜き・宣言シェーダーの面・レンダーターゲット（縮小・HDR の Rgba16Float）・光のマップ・倒した影・トーンマップ・FXAA（`docs/backend-parity.md` の表）。
- 3D: 頂点の色と材質（ShaderDoc）、Lambert + 半球光 + トゥーンの段、点 8・スポット 2（内側の角）、スポットの影 1 本（PCF）、距離のかすみ、法線マップ、mip、スキン（glTF のアニメーション）、ビルボード、Blender でベイクした lightmap、glTF のノードと emissive、深度の書き出し（ピントの Pass 用）（`Render3d.flix:4-21`・`docs/scene3d.md`）。
- 当たり判定: 2D の形（カプセル・坂・多角形）、3D は箱だけ（`CharacterBody3d` は球の列 × 向きのある箱・`Ray3d` は箱・球・カプセル・三角形）。

### 無い物
- 線形の色で光を計算すること（sRGB の式は lightmap の中だけ。段 5 の計画）。emissive の強さは今の式では明るすぎる（`docs/scene3d.md` の emissive の節）。
- 半透明（3D は cutout だけ）・MSAA（FXAA だけ）・空のグラデーション（段 4 の計画）。
- PBR の材質（金属・粗さ）・平行光・段に分けた影・点光源の影・環境マップ・SSAO・GI・ブルーム（ゲームが 2D の Pass で自前）・パーティクル（3D）・3D の物理（箱以外の形・跳ぶ・剛体）。

比べ: Godot は PBR・SDFGI / VoxelGI / LightmapGI・Volumetric fog・decal・GPU パーティクル・Jolt の物理（`scene/3d/` の一覧）。Bevy は PBR・クラスタの光・段の影・SSAO・SSR・大気・Volumetric fog・meshlet・TonyMcMapface などのトーンマップ（`bevy_pbr/src/` の一覧・`bevy_core_pipeline/src/tonemapping/mod.rs:259`）。LÖVE は 2D の描画（Mesh・SpriteBatch・Shader・Canvas・ParticleSystem）と Box2D の物理（`src/modules/physics/box2d`）で、**3D は持たない**（Mesh とシェーダーで自分で書けば描けるが、カメラも深度の場面も無い）。

公平に言える所: このエンジンの 3D は「一人称で歩いて調べる、暗い室内」に向けて絞った物で、その範囲（lightmap + 懐中電灯 + 点の灯り + かすみ + トゥーン）では絵は筋が通っている。2D の描画は LÖVE と同じくらいの幅に、宣言シェーダーと HDR の Pass を足した所まである。

点: このエンジン 4・Godot 9・Bevy 8.5・LÖVE 3（2D だけなら 6〜7 の作りだが、物差しが 3D を含む）。

---

## 7. 拡張しやすさと保守

### 良い所
- **移行メモ** 181 本（`docs/migrations/`）、**生成した API の目次**（`docs/api-digest.md` と `docs/api-digest/*.md`）、**逆引き**（`make module Q=`・`docs/module-index.md`）。
- **lint 30 種**（`bin/lint-rules/*.json`: 予約語・f32・二乗・record を包む・ジャーゴン・forbid・描画の予算など）と、コミット時の門。
- **新しい口を入れたら早見表に 1 行と agent-eval のお題 1 本**（`agents-pack/agent-eval/engine.json` は 99 題）。AI の作業者が新しい口を本当に使えるかを確かめる仕組みは、ほかの 3 者には無い。
- **計画のレビューに点数を付ける**（`plans/engine-round10-3d-kit.md` の rev0 72 → rev3）・段ごとに「使わないゲームの絵は 1 bit も変えない」の 3 つの確かめ（`:94-98`）。
- WhyNot のコメントが「なぜこうしなかったか」を残すので、リファクタの時に前の判断を辿れる（例 `Render3d.flix:730`・`:763`・`Scene3d.flix:346`）。

### 悪い所
- **描画の属性を足す税**: GL と CPU の両方・`SoftRaster.dropped`・対応表・gl-parity・`DrawHash`（`docs/backend-parity.md` の「エンジンを拡張するときの手順」5 つ）。3D の式は 2 つの言語で書くので、1 つの直しが 2 倍になる。
- **作り手が 1〜2 人**。文書と仕組みは厚いが、知識の多くが日本語の文書と計画にあり、外の人が入る道（英語の文書・issue の流れ）は無い。Godot・Bevy は数百人の貢献者と提案の流れ（godot-proposals・Bevy の RFC と移行ガイド）を持つ。
- 同じ物の写し: engine のソースを `engine_full/src/` と `src/` へ symlink で集める（`Makefile:8-15`）。仕組みとしては正しいが、git status に同じファイルが 3 回出る（段 3 の新しいファイル 4 本が 3 か所ずつ）。
- 段 3 の物（`CharacterBody3d`・`CollisionWorld3d`・`Ray3d`）はまだ未追跡のファイルで、ゲームは誰も使っていない。吸い上げた元（night の `Collider` 251 行 + `Walker` 165 行）が二重に残っている。

比べ: Godot は GDExtension とモジュールで本体を組み直さずに足せる。Bevy は Plugin で足すのが一番楽だが、版ごとの破壊的な変更が多い。LÖVE は C++ の本体が小さく読みやすいが、足すには自分で組むか LuaJIT の FFI。12.0 は何年も開発版のまま。

点: このエンジン 7.5・Godot 8.5・Bevy 7.5・LÖVE 7。

---

## 8. ゲームを作る側の体験

調べた事実（ゲームは読むだけ）:

| ゲーム | src | テスト | Doc |
|---|---|---|---|
| night_apartment（3D） | 40 本・4,205 行 | 14 本・918 行・74 件 | 13 本 |
| fps3d_lab（3D） | 35 本・5,430 行 | 6 本・271 行・29 件 | 13 本 |
| game-starter（2D） | 14 本・1,077 行 | 4 本・158 行・17 件 | 6 本 |
| tidepool-starter（2D） | 24 本・3,100 行 | 9 本・658 行・60 件 | 10 本 |
| sound-novel-starter（2D） | 27 本・4,174 行 | 4 本・851 行・65 件 | 8 本 |
| rpg-starter（2D） | 69 本・10,616 行 | 13 本・2,475 行・209 件 | 18 本 + 地図 |

### 良い所
- **2D と 3D でトップの形が同じ**: `App.game({ init, update = Resources.system(Controls.step), view = Resources.view(View.frame) }) |> App.with…`。`Controls.step: (App.Frame, Res, World) -> World`・`View.frame: (App.ViewCtx, Res, World) -> List[Render.PlacedItem]`（night `Game.flix:16-43`・`Controls.flix:30`・`View.flix:112`、fps `Game.flix:20-45`、game-starter・tidepool も同じ）。main だけが handler を張り、ゲームの中は純粋。
- **3D のゲームが 2D のコアを使っている**: 後処理を 2D の `Render.PassPlan` と `Render.shaderFill` で組む（night `PostView.flix:22-55`）、Doc の読み直し（night `Controls.flix:95-110` の 11 行）、Flow と F8 と START、音のミキサー（`withAudio`・`withSustained`・`withMixer`）、画面なしの描き出し（night `src/render/SceneRender.flix:4`）。
- 値の調整は Doc（歩く速さ・マウスの感度・lightmap・ブルーム・霧・灯り・寸法）。走らせながら変えられる。
- テストの書き方が素直（純粋な関数に入力を渡して比べる）。night の性質テストと筋書きのテストは良い手本。

### 悪い所（回り道）
- 後処理（ブルームとぼかしの並び）・読み込み画面・GPU を温める処理（`warmPlan`: 誰も読まない Pass に描いてシェーダーと絵を先に作らせる）を 2 本とも自前で書き、中身もほぼ別物（PostView の差 199 行・LoadingView の差 168 行）。エンジンの `PostProcess` は tonemap・FXAA・luma だけ。
- 3D の材質の Spec を Flix に直書き（fps `DungeonShader.flix` 560 行）。2D のテンプレはシェーダーを Doc（`*.shader.json`）にしているのに、3D は Doc で触れない。
- `stage.kind.json`（glb の場所・絵の上限）は IO が要るので読み直しの表に載らない（night `Controls.flix:96`）。
- 段 1〜3 の口（`withMouseCapture` 以外の `CharacterBody3d`・`Ray3d`・`findNode`）はゲームでまだ使われていない（ゲームの版は night 0.75.0・fps 0.74.0）。fps は独自の `Camera3d` を持ち、エンジンの `Camera3d` と名前が重なる。
- Flix の型検査の重さを避けるため、大きなレコードを enum で包む決まりがゲームにも及ぶ（`docs/flix-conventions.md`「型の設計」）。言語の都合がゲームの書き方に出ている。

比べ: Godot はエディタ（場面・材質・アニメーション・ライトのベイク・デバッガ）が一式で、3D の部屋の配置を Blender に頼らない。Bevy はエディタが無く、組むたびのコンパイルが重いが、ECS の書き味は良い。LÖVE は `love .` で即座に動き、Lua で書き直しが速いが、構造・テスト・調整の道具は全部自分で作る。

点: このエンジン 6.5・Godot 9・Bevy 6・LÖVE 7.5（小さく作る範囲で）。

---

## 9. ブラウザ・他の機種へ持っていける作り

### 良い所（effect の後ろに隠れている物）
- 窓・入力・時計・カーソル・全画面・字・テクスチャの登録（`eff Game`・`GameEngine.flix:316-412`）、音（`eff Audio`・`:416-456`）、シェーダー面と 3D（`eff Shader`）、レンダーターゲット（`eff Target`）、ファイル（`Fs.FileRead` / `Fs.FileWrite`）。`App.launch` の effect の列はこの 7 つ（`App.flix:1116`）。系と View は純粋なので、TeaVM のスパイクで rpg とノベルの「World を進めて描く物を作る所」が JVM と同じ答えを出した（`plans/engine-browser.md` 結論 1）。
- 生成した GLSL は `#version` 行を替えるだけで WebGL2 のコンパイルを通った（同 結論 4）。

### 悪い所（隠れていない物）
- 契約層の `javax.imageio` / `java.awt`（`Texture3d.flix:6,10`）、`ProcessBuilder`（`GameEngine.flix:479`）。
- 開発の道具（RemoteDebug・GameRegistry・Flow.Record・HitchDetector・ProcessEnv）が起動の道に入っている（同 フェーズ 2 の 9 件）。
- render_gl の GL の呼び出しが LWJGL の静的な関数に直に書かれ（2D で約 470 か所・Render3d で 255 か所）、層が無い。2D の道が Render3d を静的に抱えている（§1）。
- 窓と入力は GLFW、音は OpenAL、パッドは SDL（`render_gl/flix.toml` の LWJGL の 6 つ）。機種はデスクトップの 3 つ（macOS・Windows・Linux）だけ。スマホ・家庭用機の道は無い。

比べ: Godot はデスクトップ・Android・iOS・Web（WASM・WebGL2）を公式に出せる（家庭用機は外の会社）。Bevy は WASM（WebGL2 / WebGPU）を公式に支え、Android・iOS は動くが若い。LÖVE はデスクトップ・Android・iOS が公式、Web は外の love.js（Emscripten・版が遅れがち）。

点: このエンジン 3.5・Godot 8・Bevy 7.5・LÖVE 6.5。

---

## 10. LÖVE と 2D の土台を並べる（人の追加の依頼）

LÖVE は「小さく作る道具」で、エンジン（場面・エディタ・3D）ではない。並べるのはこのエンジンの 2D の側（engine_world・render_gl の 2D・templates）。

| | このエンジン（2D） | LÖVE |
|---|---|---|
| 1 コマの回し方 | `App.launch` が入力 → 時計 → 系（固定刻みも）→ 音の導出 → View → 描く、を持つ。系は `(Frame, w) -> w` の純粋な関数（`App.flix:1-7,1299`）。同じ 1 コマを trace・Flow・性質テストで再生できる | `love.run`（`src/modules/love/callbacks.lua:168-205`）: event を汲む → `love.update(dt)` → `love.draw()` → present → 1 ms 寝る。利用者が丸ごと替えられる。状態は Lua の大域に持つのが普通で、再生の仕組みは無い |
| 描画の API | 宣言: `List[PlacedItem]` を返す。Item は Sprite・Text・Box・Poly・Shader・Clipped（`Render.flix:18-61`）。z の安定ソート。宣言シェーダーは Doc（JSON）で GLSL と CPU の 2 つへ出る | 命令: `love.graphics.draw / rectangle / print`、変換の stack、Canvas、GLSL の Shader。自動のまとめ描き（`Graphics.h:916-917`）と SpriteBatch（`:493`）。描く順 = 呼んだ順 |
| 1 コマで描ける量 | 予算は動的な描き物 2,000 個（`docs/performance.md` §1）。sprite のインスタンス描き・静的な層で補う | 数万の sprite を自動のまとめ描きで。こちらが 1 桁上 |
| 音 | `eff Audio`（OpenAL・ピッチ・ループ・lowpass・読み直し）+ engine_world の `AudioMixer`（バス・ダッキング・Doc）と `Sfx` の効果音の合成。系は音を直に鳴らさず、World から宣言する（`withAudio`・`withSustained`） | `love.audio`（OpenAL・`src/modules/audio/openal`）: Source・Effect・Filter・録音。ミキサーと宣言の層は利用者が作る |
| 入力 | `Frame` の値（`down`・`justPressed`・マウス・ホイール・パッドはキーへ読み替え・`mouseDelta`）、`InputMap`。マウスは左ボタンだけ | コールバック（`love.keypressed` など）と問い合わせ（`love.keyboard.isDown`）。マウスの全部のボタン・タッチ・ジョイスティック・センサ |
| ファイル | `Fs.FileRead` / `FileWrite` の effect（テストで差し替えられる）、`SaveManager`・`Persistence`、Doc の監視と読み直し | PhysFS の砂場（`src/modules/filesystem/physfs`・`Filesystem.h:144-164` の `setIdentity` と `mount`）。.love の zip から読み、保存先は 1 か所。読み直しは無い |
| 配り方 | engine_full の fpkg 1 つ + LWJGL のネイティブ（デスクトップ 3 つ）。JVM が要る。ブラウザは計画中（TeaVM） | .love（zip）を本体と束ねる。デスクトップ・Android・iOS。Web は外の love.js |
| 道具 | Doc の読み直し・Studio（フォームとスライダー）・F8 の止めと注釈・Flow の記録と再生・画面なしの描き出しと gallery・agent-eval | 本体には無い（エディタ・デバッガ・アセットの読み込みの管理は外の物） |
| テスト | 純粋な系を直に比べる・PropertyTest・描き出しの鍵・gl-parity | 本体の lövetest（API の確かめと絵の比較）。ゲームのテストは利用者が用意 |

まとめ: 2D の「作りの守り」と「調整の道具」はこのエンジンが上、「描く量・即座に始められる軽さ・持っていける機種」は LÖVE が上。LÖVE は小さく、何でも利用者に任せることで一貫している。このエンジンは同じ小ささの所から、構造（純粋な系・宣言の描画・Doc）を最初から持たせた。

---

## 11. 「今までのコアが（3D の追加で）活かせてる？」への直接の答え

**活きている（大部分）。**

活きている所:
- 描く物の流れ: View → `PlacedItem` → GL と CPU。3D は `Render.Item.Scene3d` の 1 項目として同じ列に入り、z の並び・clip・Pass・後処理がそのまま効く（`Render.flix:54-61`）。
- 宣言シェーダー: 3D の材質は `ShaderDoc.Spec`（`Scene3d.flix:86-92`）で、GLSL と CPU の 2 つの出口を 2D と共有する。
- effect と handler: 3D の描き口を `eff Shader` に足しただけで、ゲーム・テスト・handler を壊していない。
- 2 つの描き手と gl-parity: 3D の場面も CPU で描けるので、画面なしの描き出し・テスト・agent-eval が 3D でも動く。`DrawHash` の鍵も 3D の欄まで伸ばした。
- Flow・Doc の読み直し・F8 の止め・診断（`FrameDiagnostics` に 3D の数を足した）・入力（`mouseDelta` は 2D と 3D の共通の口にした）。
- ゲームの形: 2D のテンプレと 3D のゲームでトップの形が同じ。

活きていない所:
- F8 と注釈は 3D の中の物を指せない（場面全体で 1 つの矩形）。
- 3D の材質を Doc（`*.shader.json`）で外に出す道が使われていない（2D はしている）。
- 後処理（ブルーム）と読み込みの温め（warmPlan）は、2D の Pass の上にゲームが自前で組んでいて、エンジンの部品になっていない。

3D の追加で歪んだ所:
- 光の式が GLSL と Flix の 2 つになった（2D の「1 つの木から 2 つの出口」の作りから外れた）。
- 2D の GL の描き手が `Render3d` を静的に抱えた（`Paint.flix:52`・`Frame.flix:23`）。
- `eff Shader` の名前が中身（3D の場面も描く）と合わなくなった。
- 材質の GPU のキャッシュの鍵を 2D の Shader 面と同じく spec の名前にしたため、名前の衝突をゲームが避ける決まりが生まれた（`withSpecName`）。

---

## 12. 直すと効く物の上位 10 個

| # | 直す物 | 分類 | 効き目 | 手間の見積もり |
|---|---|---|---|---|
| 1 | 3D の光の式を 1 つの元（ShaderDoc の木か、小さな式の IR）から GLSL と CPU へ出し、2 つの手書きをやめる。gl-parity の 3D の場面のいくつかを A 段階へ寄せる | 3D | 大: 段 4・5（半透明・線形の色）のたびに 2 倍払う税が消える。食い違いの見逃しが減る | 大（2〜3 週）。式の範囲を光・かすみ・トゥーンに絞れば 1.5 週 |
| 2 | 材質の GPU の鍵を spec の中身の hash から作る（`Mesh3d` と同じ作り）。`withSpecName` の決まりを外す | 3D | 中: ゲームの回り道（`Stage.renamed`）と毎コマ組み直す事故が消える | 小（2〜3 日）。hash の計算を作る時 1 回にする |
| 3 | 3D を `Scene3dRenderer` の口で 2D の描き手から外す（ブラウザの計画のフェーズ 1 の一部） | 共通 | 中: 2D だけのゲームが 3D を抱えない。ブラウザの前提。差し替えやすさが上がる | 中（1 週・計画どおり） |
| 4 | 同じ形 × 同じ材質の置いた物をインスタンスで 1 回に描く（GL）。CPU は今のまま | 3D | 大（大きな場面）: draw call が置いた物の数から種類の数に減る | 中（1〜1.5 週。gl-parity で絵が変わらないことを確かめる） |
| 5 | 後処理の部品（ブルーム・ぼかしの並び）と GPU を温める口（`warmPlan` の代わり）をエンジンへ | 共通 | 中: 2 本のゲームの重複（PostView・LoadingView・warmPlan）が消え、次の 3D のゲームが速く立つ | 中（1 週） |
| 6 | 契約層から JVM の画像のデコードと起動し直しを外へ出す（`Texture3d` の `ImageIO` → handler、`ensureMainThread` → render_gl） | 共通 | 中: 契約層が本当に依存ゼロになり、ブラウザの道が短くなる | 小〜中（3〜5 日） |
| 7 | F8 と注釈を 3D の中へ: 画面の点からレイ（`Camera3d.screenPointToRay` + `Ray3d`）で置いた物を引き、名前（glTF のノード名）を出す | 3D | 中: 3D のゲームで「指して直す」流れが 2D と同じになる | 中（1 週。置いた物に名前の欄を足す相談が要る） |
| 8 | 数の関数を `Vec2` から `Num`（か `Math`）へ移し、`eff Shader` の 3D の口の名前を直す（別の effect に分けるか、名前を `Render3dChannel` などに） | 共通 | 小〜中: 読み手が迷わない。grep で辿れる | 小（移行メモと forbid の 1 行で 2〜3 日） |
| 9 | 置いた物のカリングに空間の索引（BVH か格子。`CollisionWorld3d` の格子を流用できる）を足す | 3D | 中（大きな場面）: 毎コマの線形の判定が消える | 中（1 週） |
| 10 | 3D の材質を Doc（`*.shader.json`）で外に出せるようにし、テンプレか手本を 1 本置く | 3D | 中: 2D と同じく走らせながら材質を調整できる | 小〜中（ShaderJson は既にある。3D の欄の読み書きと手本で 3〜5 日） |

番外（効き目は大きいが手間も大きい）: 線形の色（段 5・計画済み）・半透明と MSAA（段 4・計画済み）・系の並列化（Flix の純粋さで作りやすいが、World が 1 つの値なので分け方の設計から）。

---

## 13. 評価の限界

- **読んでいない所**: engine_world の 2D の UI 群（Ui*）・Yarn・Terrain・Px*・RemoteDebug の本文、render_gl の Sprite・Font・Target の本文、SoftRaster（2D）の本文、ShaderGen / ShaderEval の本文、Gltf の本文。3D の評価は Scene3d・Mesh3d の頭・Render3d の頭と材質の所・SoftRaster3d の頭・CollisionWorld3d・CharacterBody3d の頭を読んだ範囲。
- **ゲームの読み**: night_apartment・fps3d_lab・templates は、サブエージェントが読んで行番号つきで報告した事実を使った（行番号の一部だけ自分で確かめた）。
- **走らせていない**: ビルド・テスト・gl-parity・ゲームは流していない。テストの数は `@Test` の字の数で、緑かどうかは見ていない。性能の数字は計画と文書の記録（部屋 8.8 ms など）で、測り直していない。
- **Godot・Bevy・LÖVE**: 浅い sparse clone の関係する所と、記憶にある公式の文書・設計の知識で評価した。Godot のテスト数は `tests/scene` だけを数えた（全体はもっと多い）。Bevy の extract の本体（`extract_plugin`）は clone の範囲の外で、`bevy_render/src/lib.rs` の import から辿った。LÖVE は 12.0 の開発版（main）で、配られている 11.5 と違う所がある。love.js・各機種の対応は記憶による。
- **推測の所**: 点数は筆者の物差しで、±1 の幅で読んでほしい。特に 7（保守）と 8（体験）は主観が大きい。「大きな場面で足りなくなる」は作りからの推測で、測っていない。
- 段 3 は別の人が作業中で、読んだ時点から変わりうる。

---

## 付記: 道具の使い方の記録

- `bin/fge refactor` で引いた回数: 3 回（`show Render.scene3d`・`search Vec2.sqrt`・`usages Vec2.sqrt`）+ hook が grep の代わりに自動で引いた `usages Scene3d` が 1 回。ゲーム側はサブエージェントが 22 回引いた。
- .flix に grep / sed を使った所と理由:
  - `GameEngine.flix`・`ShaderEffect.flix` の `eff` と `def` の行の一覧（ファイルの中の目次を一度に見るため）
  - `App.flix` の `pub def with` の数・`launch` と `loop` の行（数の棚卸し）
  - パッケージごとの `import java` / `org.lwjgl` / `java.awt` の棚卸し（依存の字の棚卸し）
  - `Render3d.flix` の `glDrawElements` / `sortBy` / `materialKey` / GL の呼び出しの数、render_gl の `Instanced`（呼び出しの形の棚卸し）
  - 並列の処理（`Thread` など）の有無の棚卸し
  - `@Test` の数、gl-parity の場面の名前の行
  - `Annotate.flix`・`Scenes.flix`・`Paint.flix`・`Frame.flix` を `sed -n` で行の範囲だけ読んだ（`usages` の答えで場所が分かった後に本文を読むため。1 回目の grep は hook が索引の答えに置き換えた）
- 常駐: 動いている `flixlint.Resident` の java 2 本（09:30・09:36 に起動）は、この評価を始める前から動いていた物なので止めていない。clone の git は全部終わったことを ps で確かめた。
