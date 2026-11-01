# engine round4 — 3D の描き物（メッシュと深度・ShaderDoc の材質・影）

改訂 3（2026-11-01。レビュー 66 点 → 改訂 2 で 84 点。残り 11 項目を入れた。§12・§13 に対応表）。worktree `fge-postfx`（feat/postfx-spike）で行い、main のエンジンには入れない。
動機の試作: `/Users/abab/Documents/flix_ge_workspace/fps3d_lab`（2D の通路 ↔ 3D の部屋）。

## 0. 目的と範囲

fps3d_lab の部屋は、家具の面（数千枚）を毎コマ CPU で画面へ写し、遠い順に並べて 2D の多角形として描いている。そのため次の 4 つが起きている。

1. 前後が崩れうる（面の真ん中の距離で並べるだけ）
2. 毎コマが重い（家具の組み立てで 15 ms → 光を作り置いて 8 ms）
3. 影が出せない
4. 光の計算が 2 か所にある（壁・床は GPU、家具は CPU）

| 段 | 足す物 | 解く |
|---|---|---|
| A | GPU に置くメッシュを深度で描く描き物 `Render.Item.Scene3d`・置き場所と親子の座標・深度つきのビルボード | 1・2 |
| B | ShaderDoc の材質をメッシュに塗る（world の点と法線の入力）。光は engine が 1 か所で計算する | 4 と、壁・床と家具の前後 |
| C | スポットライト 1 本からの影（shadow map） | 3 |

入れない物: 骨のアニメーション（段 D で別に計画する。型の余地は §10）・glTF・PBR・半透明の並べ替え・物理・3D のエディタ。

## 1. 今の道（調べた結果）

- `Render.Item`（engine_world/src/Render.flix:18）は 6 ケース。Shader 面は `drawShaders`（:910）で命令にして、`ShaderEffect.Shader.drawSurface` で溜める（render_gl `RenderPaint.queueSurface` Paint.flix:681）。
  位置は `placed#at`（左上）、大きさは `rect#size` を使う（:927）。カメラと F8 のパン・ズームは `at` を動かして効かせている。
- `submitFrame`（Paint.flix:331）は、Target が開いていれば溜めた面を `paintTarget`（:284）へ、開いていなければ `paintFrame`（:268）へ渡す。
  `RenderFrame.renderFrameMixed`（Frame.flix:793）が、5 本の列（tiles・sprites・polygons・statics・surfaces）を `mergedByZ`（:68）で z の安定ソート 1 本にし、`emitMerged`（:716）で描く。
- 「drawShaders → drawSurface → withoutShaders → drawWith → renderCommands」の手順が 3 か所に写してある:
  `App.renderFrame`（App.flix:2262）・`App.renderPasses`（:2302）・`VideoOut.paintOne`（engine_full/src/full/VideoOut.flix:365）。
- 効果のハンドラは 3 つだけ: 実機 `LwjglLayer`（Shader は :1050）・窓なし `GlOffscreen`（:416）・`ShaderEffect.runNoop`（:49）。
- 描き先: Target と GlOffscreen の FBO は DEPTH24_STENCIL8 の renderbuffer を持つ。深度判定はどこでも有効にしていない。窓は深度ビットを頼んでいない。
- CPU の道: `SoftRaster.drawAllInto`（:303）が `RItem` を z で並べて塗る。深度の仕組みは無い。`SurfaceCmd` は `renderToImage*` 約 12 本・`HeadlessRender.Scene` / `PassSpec` / `silhouetteWith`（:214）・
  `DrawHash.Frame`・`RenderCache`・`VideoOut`（:153 / :172 / :196）・テンプレートの `SceneRender` 3 本に位置引数で通っている。
- Item を網羅して match している所は 9 つ: Render.flix `zOf` :394・`scaled` :655・`drawInto` :1015・`toDrawables` :1080／App.flix `zMapped` :2337／SortingLayer.flix `zMapped` :323／
  UiRender.flix `zMapped` :89／Annotate.flix `itemAabb` :287・`hitOf` :349。

## 2. 採る形の要点

### 2.1 3D の場面は描き物 1 つ（`Item.Scene3d`）

3D の場面全体を 1 つの描き物にする。中身はカメラ・置いた物・ビルボード・光・環境・影。2D の並びの中では z の 1 点に入り、その中だけ深度で前後を決める。
HUD・通路・幕・Pass とは今の z の決まりのまま同居する。

| 採らない形 | 理由 |
|---|---|
| 三角形を 1 枚ずつ描き物にする | 毎コマ数千件を組み、並べ替えも CPU に残る |
| 3D 専用の別の描画ループ | View が 2 本になり、2D との前後を別の決まりで書くことになる。Pass にも入れられない |
| 新しい効果 `Scene3dEffect` | 効果の行が App の全ループ関数とゲームの main に広がる（ShaderEffect.flix 冒頭の注記と同じ理由） |

**効果は今の `ShaderEffect.Shader` に操作を 1 つ足す**（`drawScene3d(cmd)`）。ハンドラ 3 つだけを直せば済み、App の効果の行は変わらない。

### 2.2 GPU に渡す手順を 1 か所にまとめてから足す

3 か所に写してある手順を、まず `Render.submitGpuItems(warnOnce, items)` 1 つにまとめる。中身は Shader 面・3D の場面・残りの描き物の順。
2D の列（drawWith に渡す物）からは Shader 面と 3D の場面を外す（`withoutShaders` と `withoutScenes3d`）。面も場面も 0 個なら外す処理を通さない（今の速さの工夫を残す）。
外さないと、`toDrawables` の代わりの暗い矩形が同じ z の sprites の列に入り、場面の何も描かれない所に見える。
`renderFrame`・`renderPasses`・`VideoOut.paintOne` はこれを呼ぶ。3D はこの関数の中に 1 行で足す。

### 2.3 メッシュは値で持ち、中身の鍵で GPU に置く

`Instance3d` はメッシュの値（`Mesh3d`）を持つ。`Mesh3d` は作る関数からだけ作れる型にする（§3.1）。作る時に中身から `contentHash` を計算して持つ。
GL の側は `contentHash` で頂点バッファを引き、初めて見た物だけを上げる。128 コマ使われなかった物は捨てる。

- `App.withMeshes` のような上げる口は作らない。値で持てば、上げ忘れも、上げた物と描く物の食い違いも起きない。Flix の不変の値は参照で渡るので、毎コマ渡しても複写は起きない。
- 中身を書き換えて鍵だけ古い、が起きないように型を閉じる（`{ positions = … | m }` が書けない形）。

### 2.4 光は engine が計算する

点光源・スポットライト・環境（環境光・上からの明るさ・距離のかすみ・明るさの段）を engine が画素ごとに計算する。
式は fps3d_lab の DungeonShader と同じ形にそろえ、今の部屋の見た目から大きく外れないようにする。距離で落ちる量は (1 − d²/range²)²、面の向きには wrap を掛ける。
材質（段 B）は「光を当てる前の色」と、任意で「自分で光る色」を返す。

- 光の数の上限は点光源 8・スポットライト 2。
- 超えた時は、カメラの目から近い順に選ぶ（同じ距離なら並びの順）。この選ぶ関数は engine の純粋な関数 1 つ（`Scene3d.pickLights`）にして、GL と CPU の両方が使う。

## 3. 型と置き場

置き場は `engine/src/scene3d/` に 1 mod 1 ファイル（Flix 0.78 は mod の名前とファイル名が違うと E5623 で止まるため）。
core の `DrawCmd` は ShaderDoc を参照していないので、材質（ShaderDoc を持つ）を core に置くと層が崩れる。ShaderEffect（engine/src）から参照できる。

### 3.1 閉じた型（AGENTS.md §4 の形）

外から作らせない物は「pub mod の中の非 pub の enum + `pub type alias`」で持ち、作る関数と読む関数だけを公開する。
書き方は `/flix-docs`。E8176 が出る所は、round3 で使った「case の無い pub enum + 非 pub の enum + `pub type alias`」の形にする。

```flix
// 座標: 左手系（Unity と同じ）。X = 東・Y = 上・Z = 北。yaw = 0 で +Z を向き、増えると +X（東）へ回る。pitch は正で下を向く。
// yaw 0 では +X が画面の右に来る（fps3d_lab の Camera3d と同じ約束）。GL の右手系の clip 空間へは viewMatrix で Z を反転して渡す。
// 表の面 = 外から見て頂点が時計回り（左手系の CW）。Z の反転は画面の x・y を変えないので、GL でも時計回りに写る。GL は glFrontFace(GL_CW) で表を決める（Unity の GL と同じ）。
pub type alias Vec3 = { x = Float64, y = Float64, z = Float64 }          // 開いたまま（Vec2 と同じ）

pub mod Mat4 {                         // 閉じる（長さ 16 を守る）
    pub type alias Mat4 = Mat4Data
    pub def identity(): Mat4
    pub def mul(a: Mat4, b: Mat4): Mat4
    pub def apply(m: Mat4, p: Vec3): Vec3
    pub def applyDir(m: Mat4, d: Vec3): Vec3
    pub def normalMatrix(m: Mat4): Mat4             // 逆行列の転置（scale が軸ごとに違っても法線が曲がらない）
    pub def toColumns(m: Mat4): Vector[Float64]     // GL の uniform に渡す並び（列優先）
}

pub mod Transform3d {                  // 開いたレコード（ゲームが書く値）
    /// 回す順は roll（Z）→ pitch（X）→ yaw（Y）。pivot = 回す中心（形の座標）。
    pub type alias Transform3d = { at = Vec3, yaw = Float64, pitch = Float64, roll = Float64, pivot = Vec3, scale = Vec3 }
    pub def of(at: Vec3): Transform3d
    pub def toMat4(t: Transform3d): Mat4.Mat4
    /// 親の行列の下に子を置いた行列。鎖 → 枠 → 蝋燭のように何段でも重ねられる。
    pub def toWorld(parent: Mat4.Mat4, child: Transform3d): Mat4.Mat4
}

pub mod Mesh3d {                       // 閉じる
    pub type alias Mesh3d = Mesh3dData
    pub type alias Polygon = { points = List[Vec3], color = Color }
    /// 多角形の列から作る（扇に割る・面の法線を各頂点へ・巻き方は §3.1 冒頭の「表の面」の約束）。
    pub def fromPolygons(polys: List[Polygon]): Mesh3d
    /// Wavefront OBJ と .mtl の字から作る（外から来た字なので Result。fps3d_lab の ObjMesh を移す）。
    pub def fromObj(objText: String, mtlText: String): Result[String, Mesh3d]
    pub def contentHash(m: Mesh3d): String
    pub def bounds(m: Mesh3d): { min = Vec3, max = Vec3 }
    pub def triangleCount(m: Mesh3d): Int32
    // 頂点の欄は名前付きのレコードで持つ（段 D で skin を足しても、並びの位置で読む所が壊れない）
}

pub mod Camera3d {                     // 開いたレコード
    pub type alias Camera3d = { eye = Vec3, yaw = Float64, pitch = Float64, fovY = Float64, near = Float64, far = Float64 }
    pub def viewMatrix(c: Camera3d): Mat4.Mat4
    pub def projectionMatrix(c: Camera3d, aspect: Float64): Mat4.Mat4
    /// 3D の点が描き物の中のどこに写るか（名札などの 2D を重ねる時）。カメラの後ろは None。
    pub def worldToScreen(c: Camera3d, size: Vec2, p: Vec3): Option[Vec2]
}
```

### 3.2 場面の中身

```flix
pub mod Scene3d {
    pub type alias PointLight = { position = Vec3, color = Color, intensity = Float64, range = Float64 }
    pub type alias ShadowMap  = { mapSize = Int32, bias = Float64, pcfRadius = Int32, strength = Float64 }   // 段 C
    pub type alias SpotLight  = { position = Vec3, target = Vec3, fovY = Float64, color = Color, intensity = Float64,
                                  range = Float64, shadow = Option[ShadowMap] }
    pub type alias DistanceFog = { color = Color, near = Float64, far = Float64 }
    /// background = 場面の矩形の中で何も描かれない画素の色（None なら下の 2D が見える）。
    pub type alias Environment3d = { ambient = Color, hemisphere = Float64, toonSteps = Int32, fog = Option[DistanceFog], background = Option[Color] }
    pub enum Resolution with Eq { case Native; case Design }      // §5.5
    pub enum Output with Eq { case Color; case Depth({ near = Float64, range = Float64 }) }   // Depth は奥行きの灰色（ピントの Pass 用）

    /// 置いた物（閉じる。段 D の pose を後から足しても、ゲームの書いた値が壊れない）。
    pub type alias Instance3d = InstanceData
    pub def instance(mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Instance3d
    pub def withTint(c: Color, i: Instance3d): Instance3d
    pub def withMaterial(m: Material3d, i: Instance3d): Instance3d      // 段 B

    /// 深度つきのビルボード（ドット絵を 3D に立てる。閉じる — 欄を後から足してもゲームの値が壊れない）。
    pub type alias Billboard3d = BillboardData
    pub def billboard(texture: String, region: Rect2, position: Vec3, size: Vec2): Billboard3d   // anchor 足元の真ん中・tint 白・lit 真
    pub def withAnchor(a: Vec2, b: Billboard3d): Billboard3d
    pub def withBillboardTint(c: Color, b: Billboard3d): Billboard3d
    pub def unlit(b: Billboard3d): Billboard3d          // 光と fog を当てない（炎）

    /// 場面 1 つ。size = 描き物の大きさ（位置は PlacedItem の at。Shader 面と同じ決まり）。
    pub type alias Scene3dCmd = { size = Vec2, camera = Camera3d.Camera3d, instances = List[Instance3d], billboards = List[Billboard3d],
                                  pointLights = List[PointLight], spotLights = List[SpotLight], environment = Environment3d,
                                  resolution = Resolution, output = Output, zIndex = Int32 }
    pub def scene(camera: Camera3d.Camera3d, size: Vec2): Scene3dCmd     // 空の場面。Scene3dCmd は開いたレコードなので { instances = … | s } で足す
    /// 光の上限を超えた時は目に近い物を選ぶ。境をまたいだ光がぱっと点いたり消えたりするのは許す（決まった手順で毎回同じなので、気になれば光を減らす）。

    pub def pickLights(eye: Vec3, cmd: Scene3dCmd): Scene3dCmd           // 上限を超えた光を選ぶ（GL と CPU が同じ物を使う）
}
```

### 3.3 engine_world と ShaderEffect

```flix
// Render.Item に 1 ケース。位置は PlacedItem の at（左上）、大きさは cmd#size。
case Scene3d(Scene3d.Scene3dCmd)
pub def scene3d(at: Vec2, cmd: Scene3d.Scene3dCmd): PlacedItem
// App に置く（Render は Game 効果を持たない純粋な層のため）。§2.2
pub def submitGpuItems(warnOnce: String -> Unit \ ef, items: List[PlacedItem], tiles: List[TileMapRenderCmd], static: Option[StaticLayerCmd]): Unit \ (ef + Game + Shader)
pub def softSceneOf(items: List[PlacedItem]): SoftScene     // CPU に渡す物をまとめて返す（§6.1）

// ShaderEffect.Shader に 1 操作。at は命令の中へ写して渡す。
def drawScene3d(cmd: Scene3d.RenderCmd): Unit      // Scene3d.RenderCmd = { at, clip = Option[Rect2], scene = Scene3dCmd }（core の DrawCmd には置かない）
```

網羅の 9 か所の受け方:

| 所 | 受け方 |
|---|---|
| `zOf` | cmd#zIndex |
| `scaled` | size を倍率で |
| `drawInto` / `toDrawables` | 配線していない描き方（3D を知らない headless など）向けに、場面の大きさの暗い矩形 1 枚を代わりに出し、warnOnce で 1 回知らせる。Shader 面の今の扱いと同じ |
| `zMapped` 3 か所 | zIndex を写す |
| `itemAabb` / `hitOf` | at と size の矩形 |

`fade`・`blended`・`turned` は Scene3d に効かない（場面の上に幕を重ねて暗くする）。`Clipped(Scene3d)` の clip は命令の `clip` に写し、GL では scissor をその矩形と場面の矩形の重なりにする。

## 4. 同じ z の中の順と z の地図

同じ z の中では、tiles → sprites → polygons → statics → surfaces → scenes の順に描く（今の 5 本の後ろに足す）。
Shader 面と 3D の場面が同じ z に並んだ時は、今の `surfaceZShared` と同じ知らせを 1 回出す。`docs/z-bands.md` にこの順を 1 行足す。

## 5. render_gl（GL）

新しい mod `render_gl/src/Render3d.flix`。

### 5.1 合流（触る所の全部）

| 所 | 変更 |
|---|---|
| `Paint` の溜め場 | `pendingScene3dHolder` と `queueScene3d` |
| `submitFrame`（Paint.flix:331） | Target が開いている分岐と開いていない分岐の**両方**で溜め場を取り出す（片方だけだと、Pass の中の 3D が画面のコマに描かれる） |
| `Paint.Frame`・`emptyFrame`・`paintFrame`・`paintTarget` | `scenes` を足す。リサイズの描き直し（`lastFrameHolder`）にも残る |
| `FrameArgs`（Frame.flix:230） | `scenes` と描く閉包 `drawScene` |
| `Merged`（:17） | `MScene3d` |
| `mergedByZ`（:68）・`seatChannels`（:107）・`rangeMerged`（:134）・`zOfMerged`（:203）・`emitMerged`（:716） | 6 本目の列として数える・並べる・振り分ける・描く |
| `renderFrameMixed`（:793） | FrameArgs を渡す |

### 5.2 1 つの場面を描く手順（emitMerged の MScene3d）

1. 走っている 2D の run を flush する
2. 今の描き先と viewport は Paint が知っている物を使う（`screenFramebuffer`・`activeTargetHolder`・状態の 7〜10 番）。glGet は使わない
3. viewport と scissor を「at・size を今の描き先の画素へ換算した矩形」と clip の重なりに合わせる。
   `glDepthMask(true)` の後に、scissor の中だけ `glClear(DEPTH)` する。`glEnable(DEPTH_TEST)`・`glDepthFunc(LESS)`・`glEnable(CULL_FACE)`・`glFrontFace(CW)`・`glCullFace(BACK)`
4. 置いた物を描く（blend は切る）→ ビルボードを描く（α が 0.5 未満の画素は捨てる。並べ替えは要らない。blend は切ったまま）
5. 元へ戻す: `glDisable(DEPTH_TEST)`・`glDisable(CULL_FACE)`・`glDepthMask(true)`・blend を今の既定へ・program・VAO・viewport・scissor
6. stencil には触らない（mask 付きの Shader 面が使うため）

### 5.3 メッシュとプログラム

- メッシュの置き場: contentHash → { vao, vbo, ibo, count, lastUsed }。初めての物は上げ、128 コマ使われない物は捨てる。
  あふれないように、置き場の頂点の合計に上限（既定 400 万頂点）を付け、超えたら古い物から捨てる。新しい鍵が 30 コマ続けて毎コマ上がったら「形を毎コマ作り直している」を 1 回知らせる（波打つ水面などは、形を作り直さず行列か材質で動かす）。
- プログラム:
  - 頂点の色で光を当てる物 1 本
  - ビルボード 1 本
  - 深度だけの物 1 本（影と Output.Depth）
  - 材質ごとの物（段 B）
  頂点シェーダーは `uModel`・`uView`・`uProj`・`uNormal`（normalMatrix）を掛けて、`vWorld`・`vNormal`・`vColor` を frag へ渡す。
- 材質のプログラムの鍵は `"3d:" + spec#name`（2D の buildProgram のキャッシュと分ける）。LRU の捨てない印（pin）は、`lastFrame#surfaces` に加えて `lastFrame#scenes` の材質も見る。

### 5.4 Pass の中（触る所の全部）

| 所 | 変更 |
|---|---|
| `submitFrame` の Target の分岐 | 溜め場を取り出して `paintTarget` へ（§5.1） |
| `paintTarget` | scenes を描く |
| `Render.passReadNames`（Render.flix:813） | ビルボードのテクスチャの名前を読みに入れる（前の Pass を読むビルボード） |
| history を読むかの判定（`readsHistory`） | ビルボードが自分の Pass の名前を読む時も history として扱う |
| `Render.passSpecScaled`（:729） | CPU の Pass に scenes を入れる |
| CPU の縮んだ Pass | 場面の画素を Pass の倍率（texels）で作る |

### 5.5 解像度（`Resolution`）

- `Native`: 今の描き先の画素で描く（縁がなめらか。fps3d_lab の部屋はこれ）。
- `Design`: design の画素の FBO に描き、最も近い画素で拡大して重ねる（ドット絵の 2D と画風をそろえる）。
  FBO への描き込みは、影の地図と同じく `submitFrame` の頭で先に済ませる（§5.6。場面の途中で FBO を替えない）。`emitMerged` ではそのテクスチャを 1 枚のスプライトとして重ねるだけ。
  FBO は大きさごとに使い回し、大きさが変わったら（F8 のズーム・`scaled`）作り直して古い物を捨てる。FBO は透明で消し、α で重ねる。
- 場面の地の色: `environment#background` が Some ならその色で場面の矩形を塗ってから描き、None なら色は消さない（下の 2D が見える）。CPU の blendPixel も同じ決まり。

窓の深度ビットは `Native` で窓に直に描く時だけ要るので、`GLFW_DEPTH_BITS 24` を頼む。

### 5.6 影の地図は先に描く（段 C）

影の地図は、場面の途中で FBO を替えて描かない（タイル型の GPU で重い）。`submitFrame` の頭で、そのコマの全部の場面の影の地図を先に描く。
影の FBO は深度テクスチャ（標本として読む。今の renderbuffer では読めない）を mapSize ごとに 1 枚持つ。

## 6. CPU の道（SoftRaster）

### 6.1 運び方

場面は位置引数を増やさずに運ぶ。`RasterReq` に `scenes` の欄を足し、`Render.softSceneOf(items)` が drawables・polygons・surfaces・scenes をまとめて返す。
`softSceneOf` も、drawables から Shader 面と場面を外して返す（§2.2 と同じ決まり）。3D のゲームは `HeadlessRender.renderPngSoft(cfg, softScene, name)`（足す）を 1 回呼べば済む。
`renderToImage*` と `SurfaceCmd` の位置引数は変えない。ただし `RasterReq` に欄を足すので、レコードをリテラルで組んでいる所は `scenes = Nil` を足す
（`HeadlessRender.flix:57, 104`・`VideoOut.flix:178, 211`・engine_tools のテスト 約 10 か所）。`DrawHash.putReq`（:155）は欄を全部並べて受けるので、ここで止まるのは狙いどおり。

| 所 | 変更 |
|---|---|
| `SoftRaster.RasterReq`（:43）・`RItem`（:110）・`drawAllInto`（:303）・`zOf`（:691） | `scenes` の欄と `RScene` |
| `HeadlessRender.PassSpec`（:280）・`Scene`（:332）・`passImagesOf`（:361） | RasterReq の欄で通す |
| `HeadlessRender.silhouetteWith`（:214） | 場面の三角形が覆う画素を黒で塗る（形の影絵の決まりに合わせる） |
| `VideoOut`（:153 / :172 / :196） | softSceneOf を通す |
| テンプレートの `SceneRender` 3 本 | 変えない（scenes は空のまま） |

### 6.2 中身（新しい mod `engine_tools/src/SoftRaster3d.flix`）

- 場面の画素ぶんの色と深度の配列を作る。三角形ごとに頂点を写し、near の平面で切り、画素ごとに奥行きを比べる。
  world の点・法線・色は、奥行きで補正して補間する。
- 光の式は GL と同じ式を Flix で書く。式が小さいので 2 か所に書き、§8 のテストと gl_parity で同じ値を確かめる。光は `Scene3d.pickLights` で選んだ物を使う。
- 行ごとに並列に塗る（`shadeAll` と同じ）。塗った画像は、Shader 面と同じ blendPixel の道で下地へ重ねる。
- `Resolution.Design` は design の画素で塗ってから最も近い画素で拡大する。`Native` は出力の倍率で塗る。

GL と CPU の絵は画素で一致させない（今の Shader 面と同じ扱い）。比べ（reference-check）は CPU の絵どうしで行う。

## 7. 鍵（DrawHash）

- `DrawHash.Frame` の req（RasterReq）に scenes が入るので、`putReq` に `putScene3d` を足す。
- 入れる物: at・size・clip・カメラ・置いた物（メッシュの contentHash・行列の 16 個・tint・材質の Spec の JSON と Param）・ビルボード（テクスチャの名前・region・位置・大きさ・anchor・tint・lit）・光・環境・Resolution・Output・zIndex。
- `usedTextures` にビルボードのテクスチャを足す。
- Scene3d の無いコマの鍵の字は今と同じ（空なら何も入れない）。

## 8. 段ごとの中身と合格条件

計る機械: このパソコン（Mac mini・Apple Silicon）で、`make debug` の `/perf`（p50・p95）を使う。
固定の場面: repo の中に `bench/scene3d/`（部屋 1 つ・家具 10・松明 4 の場面を Flix のコードで組む）を置き、合格の絵と重さはそこで確かめる。fps3d_lab は追加の確かめに使う。

### 段 A — メッシュと深度・動く物の 3 つ

中身:
- §2.2 の `submitGpuItems` へのまとめ（3D を足す前に、絵が 1 画素も変わらないことを確かめる）
- §3 の型（材質と影の欄は使わない）・Item.Scene3d と網羅 9 か所・`Shader.drawScene3d`
- Render3d（頂点の色・ビルボード・深度だけ）・SoftRaster3d（頂点の色・ビルボード）・DrawHash
- `Mesh3d.fromObj`（ObjMesh を engine へ）

テスト:

| どこ | 確かめること |
|---|---|
| engine | Mat4: identity を掛けても変わらない・Y 軸に 90 度回すと +Z が +X へ・normalMatrix は倍率 (2,1,1) の後でも法線を直交のまま保つ |
| engine | Transform3d: pivot を中心に回すと pivot の点は動かない・toWorld(toWorld(I, 親), 子) = 親 × 子 |
| engine | Camera3d: yaw 0・pitch 0 の目の真っ直ぐ前の点が真ん中に写る・**yaw 0 で +X の点は画面の右**（鏡写しを捕まえる） |
| engine_tools / gl_parity | fromPolygons の表の面は描かれ、裏返した面は捨てられる（CPU と GL の両方） |
| engine | Mesh3d: 同じ中身なら contentHash が同じ・頂点が 1 つ違えば違う・四角 1 枚の OBJ が三角 2 枚・壊れた OBJ は Err |
| engine | pickLights: 9 本の点光源から目に近い 8 本が残る |
| engine_tools | SoftRaster3d: 手前の赤い板と奥の青い板を逆の順で渡しても、真ん中の画素は赤 |
| engine_tools | SoftRaster3d: カメラの後ろの三角形は塗られない |
| engine_tools | DrawHash: Scene3d の無いコマの鍵が今と同じ・行列が違えば鍵が違う |
| engine_world | Scene3d を含む並びで zOf・scaled・zMapped・itemAabb が落ちない |
| bench/gl_parity | Scene3d の場面を足し、「深度で赤が勝つ」と「3D の後の sprite と mask 付きの Shader 面がまだ正しく描ける（状態の漏れが無い）」を許容差つきで CPU と突き合わせる |
| GlOffscreen | Pass の中の Scene3d が、その Target にだけ描かれる（画面のコマに出ない） |

合格:
- テンプレート 4 本の `make test-<名前>` と reference の SHA256SUMS が変わらない
- bench/scene3d の静止画（CPU）に家具が正しい前後で出る
- bench/scene3d の 1 コマ p50 が 3 ms 以下
- fps3d_lab の家具を Scene3d に移した部屋が、今と並べて同等以上

### 段 B — ShaderDoc の材質

足す物:
- `ShaderDoc.Field` に `World({ axis = Axis3 })` と `Normal({ axis = Axis3 })` を足す（`Axis3 = X | Y | Z`）。2D の面で使うと 0 を返し、1 回知らせる。
- 網羅の match（ShaderDoc の Field を全ケース当てる所。`ShaderJson.fieldToJson` を含む 6 か所）・JSON の読み込み・Studio のスキーマに足す。
- `Material3d = { spec = ShaderDoc.Spec, params = Map[String, Float64], cutout = Bool, emission = Option[ShaderDoc.Shade] }`
  - Out の色: 光を当てる前の色
  - α: `cutout` が真なら 0.5 未満の画素を捨て、偽なら見ない
  - emission: 光の計算の後に足す色（自分で光る色。溶岩・目）。bindings の名前の約束では決めない（打ち間違えが黙って消えるため）
- `ShaderGen.compile3d(spec)`: 3D の頂点シェーダーと組む frag を作る。`vUv` は (0, 0) を入れる。
  Fbm・Worley など Uv を読む Field は、`ShaderDoc.atWorld(plane: (Axis3, Axis3), field)`（Shift で world の 2 軸を Uv へ写す小さな関数）で包む。今の `hashAt` は Shift で Uv を打ち消すので、そのまま動く。
  - `Field.Ref`（shared）は面の基準 uv で 1 回だけ評価する決まりなので、`atWorld(plane, ref("x"))` は world を読まない。**`atWorld` は shared の定義の側に書く**（`("x", atWorld(p, fbm))` の形）と決め、docs/shader-doc.md に書く。
  - `World` と `Normal` は `Scaled`・`Tiling` などの uv の変換を受けない（いつも画素の world の値）。
- `ShaderEval.evalCompiled3(compiled, world, normal, t)`。

DungeonShader の書き直しの例（壁は向きで模様の軸を選ぶ）:

```flix
// 壁の横の軸 = 法線が X を向く面なら world の z、Z を向く面なら world の x
let along = Field.Blend({ a = Field.World({ axis = Axis3.X }), b = Field.World({ axis = Axis3.Z }),
                          by = abs(Field.Normal({ axis = Axis3.X })) })
let up = Field.World({ axis = Axis3.Y })
// 以降は今の wallPattern の ref("as") / ref("bs") を along / up に置き換える
```

fps3d_lab では、壁・床・天井を `Mesh3d.fromPolygons` でメッシュにし、面ごとの視線と平面の交わり（rayBindings）・外接矩形 + マスクの描き方・ゲーム側の光の Param を消す。

テスト:
- ShaderEval で World.x を返す Spec が、world の点の x を返す
- 生成された GLSL が World と Normal を varying から読む
- 2D の面で World を使うと 0 を返し、知らせが出る
- emit の bindings が光の後に足される（CPU）

合格: bench/scene3d に壁と床を入れた絵が段 A と同等以上・1 コマ p50 が 3 ms 以下・テンプレートの reference が変わらない。

### 段 C — 影

- `SpotLight.shadow = Some(ShadowMap)` のスポットライトだけが影を落とす（点光源の 6 方向は作らない）。影を落とす光は場面ごとに 1 本まで（2 本目以降は無視して 1 回知らせる）。
- GL: §5.6。frag で光から見た奥行きと比べ、pcfRadius の幅で周りを平均する。
- CPU: SoftRaster3d で光から見た奥行きを同じ mapSize で作り、同じ比べ方をする。
- fps3d_lab: 部屋の真ん中の上に、下を向いた広い角のスポットライトを 1 本置き、松明の光と合わせる。

テスト:
- 光と床の間に板を置くと、板の真下の床の画素が暗い・板を外すと明るい（CPU）
- shadow の無い場面の鍵と絵は段 B と同じ

合格: bench/scene3d の 1 コマ p50 が 5 ms 以下・家具の影が床と壁に落ちる静止画・テンプレートの reference が変わらない。

## 9. 後方互換・汎用性

- 足すだけ。Scene3d を使わないゲームは、描く物も鍵も変わらない。`ShaderEffect.Shader` に操作が 1 つ増えるが、ハンドラは engine の中の 3 つだけ。
- 汎用性:
  - 3D の部屋
  - HD-2D の 3D の地形（港・ダンジョンの面を段 B で置き換えられる）
  - 2D の上の小さな 3D（アイテムの回る見本など）

## 10. 段 D（骨のアニメーション）の余地

- `Mesh3d` は閉じた型で、頂点の欄は名前付きのレコードにする。後から `skin`（ジョイントの番号と重み）を足しても、外の書いた値は壊れない。
- `Instance3d` も閉じた型で、作る関数と `with*` だけで作る。後から `pose`（骨ごとの行列）を足すと、既定値（骨なし）が付く。
- GL は骨の行列の並びを uniform で渡し、頂点シェーダーで曲げる（段 D）。
- glTF の読み込みは段 D で別の mod にする（OBJ の読み込みとは分ける）。

## 11. 作業の目安

配線が約 25 か所あるので、目安を見直した:
- 設計とレビュー: 2〜3 時間
- 段 A: 10〜14 時間
- 段 B: 6〜8 時間
- 段 C: 8〜10 時間

各段の後に bench/scene3d と fps3d_lab で静止画と重さを確かめ、段 C の後に fps3d_lab の動画を撮る。

## 12. レビュー（66 点）への対応（改訂 2）

| 指摘 | 対応した所 |
|---|---|
| 1 Pass の中 | §5.4（6 か所）・§8 段 A の GlOffscreen のテスト |
| 2 GL の合流 | §5.1（全部の所）・§4（同じ z の順・知らせ・z-bands） |
| 3 CPU の配線 | §6.1（RasterReq の欄・softSceneOf・silhouetteWith・VideoOut） |
| 4 3 か所の写し | §2.2 submitGpuItems（VideoOut.paintOne を含む） |
| 5 置き場所の決まり | §3.3（位置は at・大きさは size。Shader 面と同じ） |
| 6 閉じた型 | §3.1・§3.2（Mat4・Mesh3d・Instance3d）・§10 |
| 7 プログラムの鍵 | §5.3（"3d:" + 名前・pin） |
| 8 GL の状態 | §5.2（depthMask / depthFunc / frontFace / cull / stencil / glGet を使わない）・§5.6・Clipped |
| 9 段 B の未定 | §8 段 B（atWorld・例・JSON・emit・cutout・ビルボードの lit・pickLights・normalMatrix） |
| 10 解像度 | §5.5 Resolution |
| 11 検証 | §8（gl_parity・鏡写し・bench/scene3d・計る機械・代わりの矩形・網羅 9 か所・fade） |
| 12 名前 | §3（Vec3・Camera3d・Mesh3d・Transform3d・PointLight.range・Environment3d・SpotLight.shadow・ShadowMap.mapSize / pcfRadius・Instance3d の world・toWorld・viewMatrix / projectionMatrix / worldToScreen・bounds・contentHash・fromObj の Result） |
| 13 置き場 | §3（engine/src/Scene3d.flix）・§11 |

## 13. 再レビュー（84 点）への対応（改訂 3）

| 指摘 | 対応した所 |
|---|---|
| 1 座標の約束 | §3.1 冒頭（左手系・+X が右・viewMatrix で Z を反転・表の面の巻き方）。テストに「表の面は描かれ、裏返した面は捨てられる」を CPU と gl_parity で足す（§8 段 A） |
| 2 Design の FBO | §5.5（submitFrame の頭で先に描く・大きさごとに使い回す） |
| 3 2D の列から外す | §2.2・§6.1（withoutScenes3d・0 個なら通さない） |
| 4 地の色 | §3.2 Environment3d.background・§5.5 |
| 5 RenderCmd の置き場 | §3.3（Scene3d.RenderCmd） |
| 6 submitGpuItems の型 | §3.3（tiles・static を受ける・App に置く） |
| 7 Ref と atWorld | §8 段 B（shared の定義の側に書く・World は uv の変換を受けない・plane の型） |
| 8 自分で光る色 | §8 段 B（Material3d.emission） |
| 9 RasterReq のリテラル | §6.1（直す所と renderPngSoft） |
| 10 メッシュの置き場 | §5.3（頂点の上限・毎コマ作り直しの知らせ） |
| 11 小さな物 | §3.2（with* の代わりにレコードの更新・Billboard3d を閉じる・光の境のちらつきを許す） |
