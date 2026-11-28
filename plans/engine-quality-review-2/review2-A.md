# 2 回目の比較レビュー (A) — engine・engine_world・engine_tools の作りと API（2026-11-26・main e44d8a0d8 = v0.116.0）

範囲は途中で 2 回変わった。(1) 見るのは作りのきれいさだけ。点を付けるのは 1 回目の 4 観点（1 コア・2 境界と依存・3 API・7 保守）。(2) 人の了承で、アーキテクチャの観点 5〜11 を足し、相手とも並べた。観点 12 は自分で足した。
正しさ・体験・機種は点を付けず、作りに関わる事だけメモした。描き手（render_gl）の中身は B の担当なので、境目しか見ていない。
行番号は main の作業ツリーの物。refactor の索引は `src/`（4 パッケージの symlink の木）の道で出るので、`src/engine_world/X.flix` は `engine_world/src/X.flix` と同じファイル。

---

## 1. 1 回目の総評 15 行の判定（担当範囲の行）

| # | 1 回目の行（要約） | 判定 | 根拠 |
|---|---|---|---|
| 1 | コアは 3D に活きている（Render.Item.Scene3d の 1 項目） | **残る（良いまま）** | `engine_world/src/Render.flix:64` の `Item.Scene3d`。auto-preload も同じ道に乗った（`App/Internal/AutoPreload.flix:1-7`: View が返した場面から staticGroup を拾う） |
| 2 | 材質は ShaderDoc を使い回し、GLSL と CPU の 2 つの出口 | **残る（広がった）** | WGSL も同じ木から出る（`engine/src/shader/ShaderGen/Wgsl.flix`・`docs/flix-conventions.md` の「層を置く物差し」の節） |
| 3a | 3D の光の式を GLSL と Flix で手書き 2 回 | **直った（一部残る）** | `engine/src/scene3d/LightModel3d.flix:1-45` に式の木を 1 本だけ置き、`LightModel3d/Codegen.flix`（1,062 行）が GL の字と CPU の Flix ソースを作る。ただし「木の外」に残る物（PCF・TBN・絵の読み・裏の面の法線）は今も描き手がそれぞれ書く（`LightModel3d.flix:38-41`）。描き手は 3 本に増えたので、この残りの重さは前より増えた |
| 3b | 2D の GL の道が Render3d を静的に抱える | **直った** | `render_gl/src/Scene3dRenderer.flix:1-2` の WhyNot と `Renderer` の値（関数のレコード）。`Frame.flix:21-28` の `MScene3d(Int32)` は番号だけ持つ |
| 3c | F8・注釈は 3D を 1 枚の矩形としか見ない | **直った（真ん中の 1 つだけ）** | `engine_world/src/Annotate.flix:267-280` の `named3d` が、真ん中の点から Ray3d を飛ばして置いた物の名前（`Scene3d.withName`）を引く。囲んだ中の全部は出さない（WhyNot あり）。`Hit#kind` は今も String（§3 の悪い所） |
| 8 | API の作法がそろっている（`xxx` + `withXxx`・閉じた型・業界の語） | **残る（良いまま）** | `Scene3d.flix` の閉じた型（`Material3d = MaterialData`:337・`Instance3d = InstanceData`:532・`StaticGroup`:834・`EnvironmentMap`:891・`Sky3d`:955）、`LoadProgress.Preparsed`（`LoadProgress.flix:87-90`） |
| 9 | 材質の GPU の鍵がゲームの付けた名前 | **直った** | `render_gl/src/Render3d.flix:227-234` の鍵は `m#shaderHash`（中身の鍵）。`Scene3d.withSpecName`（`Scene3d.flix:419-424`）の doc も「別の名前を付けなくてよい」。src で呼ぶのは `Gltf.materialOf` の 1 か所だけ |
| 10 | 保守の仕組みは厚いが、描画の属性 1 つに 5 か所の税 | **残る（形が変わった）** | 光の式の 2 重は消えた。代わりに描き手が GL・WebGPU・CPU の 3 本になり、「木の外」の物と `materialKey` の旗（`Render3d.flix:231-233` の旗 9 個）は描き手ごとに払う。実例で数えるのは B の担当 |
| 11 | 2D と 3D でゲームのトップの形が同じ | **残る**（今回はゲームを読んでいない。`App.game`（`App.flix:401`）の形は変わっていない） | — |
| 12 | 3D のゲームはブルーム・読み込み画面・GPU を温める処理を自前で書いた | **engine 側は直った** | `PostStack.bloom`（`engine_world/src/PostStack.flix:165`）、既定の待ちの表示（`App/Internal/LoadingView.flix:1-4`）、`withPreload3d` と `withAutoPreload3d`（`App.flix:453-462`）。ゲームが乗り換えたかは見ていない |
| 13 | ブラウザへ持っていけない。契約層が javax.imageio を import し、起動し直しも抱える | **直った（作りの面）** | engine/src で import する Java は `java.lang`・`java.nio`・`java.security`・`java.math` だけになり、awt・imageio は 0 件。`ensureMainThread` は `render_gl/src/LwjglLayer.flix:226` へ移った。開発の道具は `App.DevTools.none()` で起動の道から外せる（`App.flix:1152-1196`）。ブラウザは `engine_web`（`WebLayer`） |
| 14 | 点数 55 | **付け直し** | §2 |
| 15 | 一番効く直し 5 つ | 光の式の 1 本化 = 直った・材質の鍵 = 直った・Scene3dRenderer = 直った・まとめ描き = engine 側に口がある（`engine/src/scene3d/MultiMesh3d.flix:1-5`・`Scene3d/StaticBatch.flix`。中身は B）・ブルームと温め = 直った | 上の各行 |

ほかにあった 1 回目の指摘:
- `Vec2.sqrt`・`cos`・`atan2` を 3D が呼ぶ → **直った**。`Vec2.sqrt` は索引に無く、`Num.sqrt` が 73 か所（30 ファイル）から呼ばれる。
- 3D の描き口が `eff Shader` という名前 → **直った**。`eff Game` も役ごとに `Platform.Input / Window / FrameClock / Draw2d / Draw3d / Tasks / GpuResources / Diagnostics / Annotation` へ分かれた（`engine/src/platform/Platform.flix:1-12` の WhyNot）。
- `App.flix` 2,508 行 → **1,220 行**。上限 1,200 行の lint があり、App は例外として 1,221 行で止めてある（`bin/lint-rules/max-lines.json`）。
- 2D の形が `render/` にいる → **一部直った**。`engine/src/physics2d/CollisionShape2D.flix` へ移った。ただし 2D の当たりは今も `Physics2D`・`Collision`・`Hit`・`SpatialGrid`（engine_world）と `CollisionShape2D`（engine）の 5 つのモジュールに分かれている。
- `App.Frame` のマウスが左ボタンだけ → **直った**（`mouseButtons`・`mouseClickedButtons`・`App.flix:32-33`）。ただし `mouseDown`・`mouseClicked` も残り、同じ事を 2 通りに持つ。

## 2. 点の表（10 点満点）

| 観点 | このエンジン 1 回目 → 今回 | Godot 4.x | Bevy | LÖVE |
|---|:--:|:--:|:--:|:--:|
| 1 コアの設計 | 7.5 → **8.5** | 8 | 9 | 5 |
| 2 モジュールの境界と依存 | 6 → **7.5** | 8 | 8.5 | 8 |
| 3 API の設計と命名 | 7 → **7.5** | 8 | 7.5 | 8.5 |
| 7 拡張しやすさと保守 | 7.5 → **8** | 8.5 | 7.5 | 7 |
| 5 データの流れ（新） | **8.5** | 6 | 9 | 4 |
| 6 副作用の閉じ込め（新） | **8.5** | 4.5 | 7 | 3 |
| 7' 機種の切れ目（新） | **8** | 8.5 | 8 | 7.5 |
| 8 真実が 1 か所か（新） | **7** | 7 | 7.5 | 6.5 |
| 9 不正な状態を型で書けなくする（新） | **8** | 4 | 8.5 | 2 |
| 10 依存の結合と循環（新） | **6.5** | 6 | 8 | 7.5 |
| 11 拡張の口（新） | **7** | 8.5 | 9 | 6.5 |
| 12 作りの決まりを機械で守るか（足した観点） | **9** | 6 | 7 | 3 |

1 回目の 4 観点の合計: 28 → 31.5（40 点満点）。相手の 4 観点は 1 回目のまま据え置いた（理由は §5）。

### 動いた所の理由（1 回目の 4 観点）
- **1 コア +1**: 3D を足して生まれた歪み 3 つのうち 2 つが消え、残りの 1 つも大半が直った。effect を役ごとに分けた。pipelined rendering が `Platform.Tasks` の handler 1 つで入り（`App.flix:677`）、render-from-World の 1 本道を崩していない。減点で残る物: `Render.Item` に case を 1 つ足すと網羅の match を 14 か所直すことになる（下の §3-10）。`GameEngine` という名前のモジュールが、別名の置き場として残っている。
- **2 境界 +1.5**: 契約層から awt・imageio・ProcessBuilder が消えた。開発の道具を外せる口ができた。native image 向けの直し（未取り込み 95467c3ac）は 4 ファイルとも render_gl の中で済み、engine には触れていない。減点で残る物: engine_world の 123 モジュールが 1 つのフォルダに平らに並ぶ。開発の道具（`App/RemoteDebug.flix` 1,053 行・`App/Headless.flix` 796 行）が engine_world の同じパッケージにいる。engine_web が engine の `*.Internal` を直に呼ぶ（`Gltf.Internal.preparse`・`LoadProgress.Internal.makePreparsed`。Flix にパッケージの中だけで見える pub が無いため）。
- **3 API +0.5**: 材質の鍵が中身から作られるようになり、マウスの全部のボタンが取れるようになり、Preparsed のような閉じた型が増えた。減点: `App.Frame` が同じ事を 2 通りに持つ。`Annotate.Hit#kind` が String（`Annotate.flix:377-386`）。`LoadProgress.AssetDownloads` に関数が 12 個たまっている（`LoadProgress.flix:71-84`）。`GpuResources.buildProgram` の doc が今も「GLSL へコンパイル」と言う（`Platform.flix` の GpuResources。既定の描き手は WebGPU）。`App` の組み立て口（with・add・on など）が 58 個ある。
- **7 保守 +0.5**: max-lines の lint（1,200 行）で、大きいファイルが機械で止まるようになった。光の式の 2 重の税が消えた。減点: App は上限ちょうど（1,220 / 1,221）で、次に with* を 1 つ足すと鳴る。`Scene3d.flix` も 1,192 行で上限に近く、L5（SSAO・点光源・fog）の欄はここに入る。同じ処理の写しが残る（§3-8）。

## 3. 観点ごとの良い所と悪い所

### 1 コアの設計 (8.5)
- 良い: 式の木を 1 本だけ書き、GL・WGSL・CPU の出口を作る（`LightModel3d.flix:3-45`。木が vec3 とスカラーを型で分ける WhyNot が :43-44）。3D の描き手を値で渡す（`Scene3dRenderer.flix:13-19`）。effect を役割で分けた（`Platform.flix:1-12`）。
- 悪い: 「木の外」の物を描き手ごとに書く（`LightModel3d.flix:38-41`）。`GameEngine`（`engine/src/platform/GameEngine.flix`）が `DrawCmd` の別名 7 つ（:76-109）・`Key` の enum・`eff Audio`（:311）の置き場になった。名前は前の神 effect のなごりで、中身と合わない。

### 2 モジュールの境界と依存 (7.5)
- 良い: 層の向きは gates.json の `feeds` と `.layers/<層>` の木で、型検査が守る（render_gl と engine_world は互いを見ない）。engine/src を `core / platform / scene3d / shader / render2d / physics2d` に分けた。DevTools は `App.DevTools.none()` で、呼び出しの届かない形で外せる（`App.flix:1186-1196`）。
- 悪い: engine_world は平らな 123 ファイル（`Ui*` 20 本・`Yarn*` 4 本・ECS の `Query`・`EntityId`・`EcsCodec` が同じ所にいる）。engine_core・engine_ecs・render_core の空のフォルダが根に残る（git の外。lib と artifact だけ）。

### 3 API の設計と命名 (7.5)
- 良い: 閉じた型と `*Fields` で読む形（`Scene3d.flix` の 5 組）。`App[w, {}]` だけを `launch` が受ける（`App.flix:1175`）。多相 effect の `Emit[e]`・`Loop[s]`・`Sfx[s]` で、音の取り違えを型で止める（`Loop.flix:1-13`）。
- 悪い: `App.Frame` の欄が 20 個あり、`mouseDown`・`mouseClicked` と `mouseButtons`・`mouseClickedButtons` が重なる（`App.flix:23-62`）。`AssetDownloads` は読み込みの状態・予算・ロゴを出している間か・wasm の状態・待ちの知らせ・Preparsed を 1 つのレコードに混ぜている（`LoadProgress.flix:71-84`）。`Platform.Tasks` は `JObject` を返し、使う側が cast する（`Platform.flix` の Tasks）。

### 7 拡張しやすさと保守 (8)
- 良い: `max-lines.json` に例外と理由が 1 行ずつ書いてあり、伸びたら鳴る。WhyNot が層の判断を残している（`Platform.flix` の Tasks と Annotation、`Scene3dRenderer.flix:1`）。
- 悪い: `App.zMapped`（`App.flix:1210-1219`）・`SortingLayer.zMapped`（:310）・`UiRender.zMapped`（:90）の 3 つの写し（WhyNot で「pub にするとゲームから z を書ける」と言い訳している。ただ、lint-forbid の `app-internal` が `Render.Internal` を止めるので、そこへ置けば 1 つにできる）。参照の同一を見る処理が 5 つある（`ShaderEval`・`ShaderGen/Internal/SpecKey`・`App/Internal/AutoPreload.flix:102-107`・render_gl の `Render3d/Material`・`Render3d/WebGpuStatic`）。

### 5 データの流れ (8.5)
- 良い: 系は `(Frame, w) -> w`、View は進んだ後の World を読むだけ。trace・Flow・/step が `App.traceFrame` 1 本を通る（`App.flix:1079`）。診断を系で読ませない（`App.Frame#diagnostics` の lint-forbid・`App.flix:59-62`）。auto-preload は View の結果から宣言を作り、World に書かない（`AutoPreload.flix:1-7`）。
- 悪い: `Render.shadersReadingWorld3d` と `missingShaderParams` が、純粋なはずの Render の中で `unsafe IO` と `IdentityHashMap` を使う（`Render.flix:223-262`）。AutoPreload が描き手の都合（参照が同じかの見方）を App の中に写している（:95-107）。

### 6 副作用の閉じ込め (8.5)
- 良い: 窓・入力・時計・2D・3D・GPU・診断・注釈・音・ファイル・読み込み・仕事が全部 effect。`launch` の型が 7 つの effect を名前で並べる（`App.flix:1175`）。スレッドを App が立てない WhyNot（`Platform.flix` の Tasks）。
- 悪い: `Log` は `java.lang.System` を直に呼ぶ（`engine/src/core/Log.flix:10`）。`Model3d.loader` が中で `ProjectLoader.loadProject(".")` を読む（`Model3d.flix:119-124`。道が決め打ちで、呼ぶ側から見えない）。`ProcessEnv.snapshot()` が `launch` の中にある（道具なしの入口は避けられる）。

### 7' 機種の切れ目 (8)
- 良い: 切れ目の表が 1 か所にある（`docs/flix-conventions.md`「層を置く物差し」）。抽象は実装が 2 つある所だけ（GlContext・WebGpuDevice・Scene3dRenderer・RenderList の backend）。Worker の道は機種の handler（`engine_web/src/WebLayer/Internal/GlbWorker.flix` 90 行）の中に閉じ、engine は `AssetDownloads#preparsedOf` を読むだけ。読むのは `Model3d.loader` の 1 か所だけ（refactor usages で確かめた）。解き方（`Gltf.Internal.Parse`）は 1 本。native の直しも handler の中で済んだ。
- 悪い: `LoadProgress` の op は「ループの前だけ」呼べ、`downloads()` が返す関数の組は「ループの中でも」呼べる。同じ effect に寿命の違う 2 つの口がある（`LoadProgress.flix:1-4`）。`PreparsedParts` は型の無い並び（strings・ints・floats・f64s・i32s）で、書く順は書く側と読む側の約束だけ（`LoadProgress/Internal.flix:6-9`。同じ wasm が書いて読むので今は破れない）。

### 8 真実が 1 か所か (7)
- 良い: 光の式・WGSL と GLSL・材質の鍵（中身の hash）は、それぞれ元が 1 か所にある。切れ目の表と max-lines の例外の表は、どちらも JSON や docs の 1 か所にある。
- 悪い: zMapped が 3 つ・参照の同一を見る処理が 5 つ・木の外の物は描き手ごと・`App.Frame` のマウスが 2 通り・`GameEngine.Drawable` などが `DrawCmd` の別名として同じ物に名前を 2 つ与えている（`GameEngine.flix:76-109`）。

### 9 不正な状態を型で書けなくする (8)
- 良い: 非 pub の enum は engine に 40 個・engine_world に 30 個。`Clock.Time[Clock.Real]`。`App[w, {}]`。AutoPreload の状態を enum の case と payload で持つ（`AutoPreload.flix:11-16`）。
- 悪い: `Annotate.Hit#kind = "sprite" | "scene3d" …` の String（`.claude/rules/flix.md` の「取りうる値は enum」に反する）。`unchecked_cast` は src に 77 か所（engine 26・engine_world 30・engine_tools 21。大半は Java の境目と `checked_ecast` の周り）。`Tasks` の `JObject`。

### 10 依存の結合と循環 (6.5)
- 良い: パッケージの間に循環は無い（層の木で型検査が止める）。上限 1,200 行の lint がある。
- 悪い: 中心のファイルが多くのモジュールを参照する（大文字の `Mod.` を数えた概算で、App.flix 49・Runner 34・Render 28・Annotate 25）。`Render.flix`（1,163 行）は Item を作る口・修飾・頂点の幾何（`flipH`・`rotated`:572-595）・Pass の計画（:735-809）・診断（:223-262）を 1 つに抱える。`Scene3d.flix`（1,192 行）は光・影・霧・PSX・材質・置いた物・ビルボード・集まり・環境マップ・空・描く依頼を抱える。1,000 行を超えるのは 8 本（下の §4）。

### 11 拡張の口 (7)
- 良い: ゲームは engine を直さずに足せる。系は `App.addSystem`、出来事・音は `Emit`・`Loop`・`Sfx`、見た目は ShaderDoc の Doc と `PostStack`、新しい機種は `Platform.Services` と Fs と `LoadProgress` の handler を書く。
- 悪い: `Render.Item` は閉じた enum で、新しい描き物の種類は engine を直すしかない（網羅の match が 14 か所。ほかに描き手 3 本）。Plugin の口（Bevy の `Plugin`・Godot の GDExtension）に当たる物は無く、App の Rec（52 欄）に欄を足すのも engine の仕事。

### 12 作りの決まりを機械で守るか（足した観点）(9)
- 根拠: `.layers/<層>` の木（render_gl から engine_world を引けない）、`max-lines.json`、lint-forbid の `app-internal`・`launch-for-bench`・`frame-diagnostics-in-system`、`bin/lint-rules/` に 46 本の設定（1 回目は 43 本。`hooks`・`precommit`・`status` のような lint 以外の配線も含む）。相手は、Godot が clang-format と CI、Bevy が clippy と型。設計の決まり（層・大きさ・内側の口）を lint にしている物は、どの相手にも見当たらない（記憶）。

### 点を付けない観点のメモ（作りに関わる物だけ）
- 正しさ: 式の木に `with Eq` が付き、GPU と CPU の答えを式の行で突き合わせる（v0.75 の後のコミット adfe1e4a5 の題）。作りの面では、2 重を消したことで食い違いの余地が減った。
- 体験: `App` の組み立て口が 58 個あり、選ぶのが大変になってきた（§3）。
- 機種: §3 の「7' 機種の切れ目」に入れた。
- 性能・描画（B が主）: `materialKey` は旗 9 個の掛け算を字で繋ぐ（`Render3d.flix:231-233`）。変種の数が増えるほど、program の数が掛け算で増える。

## 4. 規模（作りに関わる物だけ）

| パッケージ | src の行数 v0.75.0 → v0.116.0 | src のファイル数 |
|---|---|---|
| engine | 12,647 → 20,366（+61%） | 95 |
| engine_world | 24,306 → 30,793（+27%） | 156（根に 123） |
| engine_tools | 6,100 → 7,657（+26%） | 34 |
| （参考）render_gl | 8,444 → 24,322（約 2.9 倍） | 92 |
| （参考）engine_web | — → 1,360 | 6 |

1,000 行を超える .flix（担当の 3 パッケージ）: `engine/scene3d/Scene3d.flix` 1,192・`engine/shader/ShaderEval.flix` 1,083・`engine/scene3d/LightModel3d/Codegen.flix` 1,062・`engine_world/App.flix` 1,220（lint の例外）・`engine_world/Render.flix` 1,163・`engine_world/UiDoc.flix` 1,143・`engine_world/App/RemoteDebug.flix` 1,053・`engine_tools/SoftRaster3d.flix` 1,182。全部で 8 本（1 回目に挙げた 2,000 行級の App・SoftRaster は割れた）。
900〜1,000 行: `ShaderJson` 970・`Gltf/Internal/Parse` 936・`ShaderGen` 923・`CollisionShape2D` 916。

層の向きの違反: 型検査が通る範囲では **0**。engine/src の Java の import は `java.lang`・`java.nio`・`java.security`・`java.math` だけ。awt・imageio は engine_tools（画面なしの道具の層）にだけある。パッケージの内側の口（`*.Internal`）を外から呼ぶ所は、engine_web から engine への 4 つ（`Gltf.Internal.preparse`・`warmUpWire`・`warmUpCodec`・`LoadProgress.Internal.makePreparsed`）。物差しの範囲の使い方。
重複: zMapped 3 つ・参照の同一を見る処理 5 つ（担当の外の render_gl の 2 つを含む）・`GameEngine` の `DrawCmd` の別名 7 つ。
移行メモ: 186 → 264 本（手書き 115・`.auto.md` 149）。

## 5. 相手の点の見直し（記憶。新しくソースは取っていない）

- **Bevy**（記憶: 0.15 の required components、0.16 の relationships と GPU を使う描き方、0.17〜0.18 の observers の作り直しと headless の UI の部品）。コア（9）と拡張の口（Plugin・relationships）はもう少し強くなった。ただ版ごとの移行は今も重く、API（7.5）と保守（7.5）は据え置いた。
- **Godot 4.4〜4.5**（記憶: Jolt を物理の既定に・型つきの Dictionary・エディタに埋め込むゲームの窓・shader baker）。機能と体験は進んだが、作り（Node の木・Variant・RID のサーバー）は変わっていない。4 観点は据え置き。
- **LÖVE 12**: 正式版が出たかは記憶ではっきりしない（未確認）。作りは 1 回目と同じと見て据え置き。
- 新しい観点の相手の点は記憶と、1 回目に読んだ clone の範囲での評価。±1 の幅で読んでほしい。

## 6. 直す物の候補（作りのきれいさに効く順・最大 8）

| # | 直す物 | 実時間 | engine 拡張か | L5 の前か後か |
|---|---|---|---|---|
| 1 | `Scene3d.flix`（1,192 行）の中身を `Scene3d.Internal.*` へ分ける（光・影・霧・空・環境マップ）。pub は Scene3d に残す | 2〜3 時間 | いいえ（pub は変えない） | **前**（L5 の SSAO・点光源・fog の欄がここに入り、上限を越える） |
| 2 | `App.flix` の上限ちょうど（1,220 / 1,221）を解く。待ちの with* 5 つを 1 つの spec のレコードで受ける口へまとめ、F8・debug の with* と一緒に中身を `App.Internal.*` へ | 3〜4 時間 + 移行メモ | はい（pub の形が変わる） | 前が望ましい（L5 で with* を足すと鳴る） |
| 3 | `zMapped` の 3 つを `Render.Internal` の 1 つにする（app-internal の lint が外から止めるので、WhyNot の理由はもう成り立たない）。`Render.Item` を網羅で回す所を 1 つの写しの関数（葉と clip を辿る物）へ寄せ、case を足す時に直す所を減らす | 1.5〜2 時間 | いいえ（内側だけ） | 前（安い・L5 の前に直す所が減る） |
| 4 | 参照の同一を見る処理 5 つを engine/core の 1 つの関数へ | 1 時間 | はい（pub を 1 つ足す） | どちらでも |
| 5 | `Annotate.Hit#kind` を enum に、`App.Frame` の `mouseDown`・`mouseClicked` を `mouseButtons` へ一本化（forbid で古い書き方を止める・移行メモ） | 2〜3 時間 | はい（API が変わる） | 後 |
| 6 | `LoadProgress.AssetDownloads`（12 個の関数）を役で分ける: 素材の取り具合 ／ 待ちの知らせとロゴ ／ Preparsed。ループの前だけの op と、ループの中で呼べる口の寿命を型で分ける | 3〜5 時間 | はい | 後 |
| 7 | `GameEngine` モジュールを畳む: `DrawCmd` の別名 7 つを消す、`Key` と `Cursor` を `Input` の側へ、`eff Audio` を `Platform` へ。古い名前は forbid で止める | 4〜6 時間 + 移行メモ（ゲームの字に広く当たる） | はい | 後 |
| 8 | `Render.flix` の役を分ける: 頂点の幾何（`flipH`・`rotated*`）を `Polygon` か `Vec2` の側へ、Pass の計画を `Render.Pass` の側へ、`unsafe IO` の診断 2 つを開発の道具の側へ | 3〜4 時間 | はい（pub の置き場が変わる） | 後 |

番外（候補に入れない）: 2D の当たりの 5 モジュール（Physics2D・Collision・Hit・SpatialGrid・CollisionShape2D）は、`plans/engine-physics2d.md` の `PhysicsWorld2d` が入る時に置き場をそろえる。`LightModel3d` の「木の外」の 3 重は B の担当。

## 7. 評価の限界
- 読んだ所: 各ファイルの頭・宣言の一覧（outline）・名前を挙げた関数の本文。UI 群・Yarn・Timeline・Flow の本文と、ゲーム・テンプレートは読んでいない。
- 走らせていない: ビルド・テスト。行数は `wc`、依存の数は大文字の `Mod.` を字で数えた概算。
- 点は筆者の物差しで ±1。新しい観点の相手の点は記憶に頼った所が多い。
