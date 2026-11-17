# 点光源の影と光の単位（engine-render-expression.md §3.0.0 の 1・2）

人の言葉（2026-11-18）:「（点光源の影を）エンジンに足していいよ　そこら辺の光の表現が前から弱いので」。
engine の拡張は了承済み。範囲は (A) 点光源の影（実装する）と (B) 光の単位（選べる形で実装して比べまで。既定の切り替えと preset の決め直しは人）。

印: 【確】= コードで確かめた / 【推】= 推測 / 【未確認】。

## 0. 要約

- (A) 点光源の影は **cube の 6 方向を 1 枚の深度の絵（atlas）に並べる**。3 つの描き手（GL・WebGPU・CPU）が同じ「面の選び方・座標・比べ・PCF」を使う。
  場面に `pointShadows = Option[Scene3d.PointShadowMap]`（既定 None）。影を落とす灯りは `pickLights` で選んだ 8 本のうち画面の真ん中に近い順に `casters` 本。
- (B) 光の単位は `lightUnits = Scene3d.LightUnits`（既定 `Legacy`）。`Physical` で 点・スポットの落ち方を **逆二乗 × range の窓**、点・スポット・太陽の拡散に **1/π**。
- 既定（どちらも使わない）では、GPU のシェーダーの字は今と 1 字も同じ（変種のプログラムを別の鍵で組む）。CPU は同じ木に「選ぶ（Select）」と「× 1.0」が増えるだけで値はビットまで同じ。
  `DrawHash` は既定の欄を書かないので鍵も同じ。

## 1. 今の作り（読んだ所）

- 光の式は `LightModel3d` の木 1 本。GLSL・WGSL は走る時に木から作り（`Render3dGlsl.lightSource`・`Render3dWgsl`）、CPU は木から生成した `engine_tools/src/gen/SoftRaster3dLight.flix` を回す【確】。
- スポットの影は「木の外の PCF」を木が `ScalarInput.ShadowLit`（SumSpots の中）で読む。GLSL は `spotShadow(i, p)`、CPU は `CpuHooks#shadowFunction(shadow, i, px, py, pz)`【確】。
- 影の地図は正方形 1 枚ずつ（`Render3d.ShadowMaps.Key(size, ordinal)`）。GL は深度テクスチャ + FBO、WebGPU は DEPTH32_FLOAT、CPU は `SoftRaster3d.ShadowMaps.buildShadowMap`（Vector[Float64]）【確】。
- GL の材質のプログラムは `Render3d.ProgramKind` の欄ごとに別の鍵で組み、「使わない欄は 1 字も変えない」決まり（`ProgramKind` の WhyNot）【確】。
- GL の `GlContext`（Java）に `texImage3D`・`framebufferTextureLayer` は無い【確】。2D の配列の絵や cube の絵を使うと Java の口（PC と WebGL2 の 2 つ）と gl-jar の作り直しが要る。

## 2. (A) 点光源の影

### 2.1 形の選び（atlas を採る）

| 案 | GL | WebGPU | CPU | 弱み |
|---|---|---|---|---|
| cube の絵（samplerCube） | Java の口が要る | cube の view | 6 枚の配列 | Java と gl-jar・WebGL2 版の口・PCF の縁が GPU の cube の継ぎ目任せで CPU と合わせにくい |
| 2D の配列の絵 | Java の口が要る（texImage3D・framebufferTextureLayer） | 配列の view | 6N 枚 | 同上 |
| **1 枚の atlas（採る）** | 今の口だけ（texImageDepth24 は縦横を別に取る・viewport で面ごとに描く） | 1 枚の深度の絵・面ごとに viewport | 面ごとの Vector | 面の縁の PCF がはみ出す → guard band で消す（2.3） |
| 双放物面（dual paraboloid） | 今の口 | 今の口 | 2 枚 | 頂点の段で歪めるので粗い形の物で影が曲がる。Unity・Unreal・Godot の今の既定ではない |

Unity（HDRP）と Unreal も点光源の影を atlas に並べる。Godot 4 は cube と双放物面を選べる。

### 2.2 API（engine/src/scene3d/Scene3d.flix）

```flix
/// 点光源の影（6 方向を 1 枚の atlas に並べる。Unity・Unreal の Shadow Atlas・Bevy の PointLightShadowMap）。
pub type alias PointShadowMap = { maxShadowedLights = Int32, mapSize = Int32, bias = Float64, normalBias = Float64, pcfRadius = Int32, strength = Float64 }
pub def pointShadowMap(): PointShadowMap =   // maxShadowedLights 4・mapSize 512・bias 0.05・normalBias 1.0・pcfRadius 1・strength 0.8
pub def maxShadowedPointLights(): Int32 = 8
pub def withPointShadows(m: PointShadowMap, scene: Scene3dCmd): Scene3dCmd
// Scene3dCmd に欄 pointShadows = Option[PointShadowMap]（scene() の既定 None）
```

- `casters` = 影を落とす灯りの数の上限（0 以下で影なし・`maxPointShadowCasters()` で頭打ち）。スマホは 1〜2 を勧める。
- `mapSize` = 面 1 つの一辺の画素（atlas はその 3 × 2 の塊を並べる。2.4）。`pcfRadius` = 周りを平均する幅（太陽・スポットと同じ (2r+1)² の箱）。
- `bias`・`normalBias` は太陽と同じ単位（bias = world の長さ・normalBias = 面 1 画素の world の幅の何倍）。スポットの bias（地図の値）とは違う。
- 灯り 1 本ごとの「影を落とす / 落とさない」は持たない（`PointLight` は閉じたレコードで、欄を足すと全部のゲームの字が壊れる）。選び方は 2.5。

描き手の側が使う材料（pub。3 つの描き手と DrawHash・テストが読む）:

```flix
pub type alias ShadowedPointLight = { pointIndex = Int32, slot = Int32, position = Vec3.Vec3, near = Float64, far = Float64,
                                     strength = Float64, faces = Vector[{ matrix = Mat4.Mat4, frustum = Frustum.Frustum }] }
pub type alias PointShadowAtlas = { tileSize = Int32, blocksPerRow = Int32, width = Int32, height = Int32, pcfRadius = Int32,
                                    bias = Float64, normalBias = Float64, guardScale = Float64, lights = List[ShadowedPointLight] }
pub def pointShadowsOf(scene: Scene3dCmd): Option[PointShadowAtlas]            // pickLights の後の場面を受ける
pub def pointShadowFaceOf(d: Vec3.Vec3): Int32                                   // 面の選び（2.3）
pub def pointShadowSampleOf(atlas, caster, p, n): Option[{ face, x, y, depth }]   // 受ける点 → 面・地図の画素・比べる値（2.3）
```

### 2.3 約束（3 つの描き手で同じ）

面の順は GL の cube と同じ +X・−X・+Y・−Y・+Z・−Z。面 f の基底 (R_f, U_f, F_f) は Scene3d の定数（+Y・−Y の上は +Z）。

- 描く: 面 f の行列 M_f = `Mat4.perspective({ xScale = s, yScale = s, near, far })` × `Mat4.ofLinearRows(R_f, U_f, −F_f)` × `Mat4.translate(−位置)`。
  `far = max(2, range)`・`near = min(1, far / 100)`（`Scene3d.shadowCamera` と同じ式）。
- **guard band**: s = (S − 2(r + 1)) / S（S = mapSize・r = pcfRadius）。面の角は 90° より少し広く、面の中で選ばれる点は地図の外周 r + 1 画素の内側に写る。
  PCF の周りの画素が隣の面の塊へはみ出さないので、面の継ぎ目に筋が出ない（HDRP の guard band と同じ考え）。周りの読みは塊の中へ寄せる（保険）。
- 受ける点 p（法線 n = 光の計算の法線）:
  1. d0 = p − 位置。major0 = max(|d0.x|, |d0.y|, |d0.z|)。
  2. q = p + n × normalBias × 2 major0 / (s S)（面 1 画素の world の幅の normalBias 倍だけ法線へずらす）。d = q − 位置。
  3. 面の選び: ax ≥ ay かつ ax ≥ az なら X（d.x ≥ 0 で +X）・ほかに ay ≥ az なら Y・ほかは Z。
  4. depth = d·F_f。depth ≤ near なら影にしない（1）。ndc = (s (d·R_f) / depth, s (d·U_f) / depth)。
  5. 比べる値 ref = (A − B / max(depth − bias, near)) × 0.5 + 0.5（A = (far + near)/(far − near)・B = 2 far near/(far − near)。地図の値 = GL の ndc.z × 0.5 + 0.5 と同じ目盛り）。
  6. 画素 c = clamp(floor((ndc × 0.5 + 0.5) × S), 0, S − 1)（行 0 が ndc.y = −1）。atlas の画素 = 塊の原点 + 面の原点 + clamp(c + (dx, dy), 0, S − 1)。
  7. 照らされる割合 f = (2r+1)² 個のうち ref ≤ 地図の値の数 ÷ 個数。灯りの量に 1 − strength_i × (1 − f) を掛ける（拡散と鏡面の両方。木の `PointShadowLit`）。
- 影を落とす物: 不透明の置いた物（骨つきも曲がった形で）。半透明は落とさない。ビルボードは落とさず受けない（スポットの影と同じ。HD-2D のキャラの点光源の影は後で別に）。
- 影を受ける物: 頂点の色の物と材質の物（lightmap の面も。点光源はベイクの上に足す光なので影も掛ける）。

### 2.4 atlas の並び

- 塊 = 灯り 1 本の 6 面を 3 × 2 に並べた物（面 f は塊の中の列 f mod 3・行 f / 3）。
- 塊の並び: casters ≤ 1 なら 1 列、ほかは 2 列。幅 W = 3 S × 列・高さ H = 2 S × ceil(casters / 列)。
- S は W・H が `maxShadowMapSize()`（4096）に収まるよう縮める（8 本なら S ≤ 512・4 本なら S ≤ 682・1 本なら S ≤ 1365）。縮めたら 1 回知らせる。
- 大きさは「今のコマに影を落とす本数」でなく **設定の casters** で決める（カメラが動いて本数が変わるたびに絵を作り直さない）。

| 設定 | atlas | 深度 4 バイトの量 |
|---|---|---|
| casters 1・mapSize 256（スマホの勧め） | 768 × 512 | 1.5 MB |
| casters 2・mapSize 512 | 3072 × 1024 | 12 MB |
| casters 4・mapSize 512（既定） | 3072 × 2048 | 24 MB |
| casters 8・mapSize 512 | 3072 × 4096 | 48 MB |

### 2.5 影を落とす灯りの選び

- 候補 = `pickLights` の後の点光源（8 本まで・重みを掛けた後）。`pointPickScoreOf`（画面の真ん中からの角）が None の物（画面に光が届かない・range か intensity が 0 以下）は落とす。
- 点数の小さい順に `casters` 本へ slot 0, 1, … を振る。
- 境のなめらかさ: 候補が casters 本より多い時、最後の 1 本（casters ≥ 2 の時）の strength に `clamp01((次の候補の点数 − 点数) / (次の候補の点数 − 1 つ前の点数))` を掛ける（`pointPickWeightOf` と同じ形）。
  入れ替わる瞬間は strength が 0 なので、影がぱっと出たり消えたりしない。casters = 1 は入れ替わりで切り替わる（灯りの重みの境と違い、影の境は 1 本なので幅を取れない。【推】困れば casters 2 にする）。

### 2.6 木とコード生成（engine/src/scene3d/LightModel3d.flix・Codegen.flix）

- `ScalarInput.PointShadowLit`（SumPoints の中だけ）を足す。点光源 1 本の拡散と鏡面に `lit = Select(k > 0, PointShadowLit, 1)` を掛ける（スポットの `spotGate` と同じ形）。
- 木を作る関数に変種を渡す: `pub type alias LightVariant = { pointShadows = Bool, lightUnits = Branch }`・`pub enum Branch { case Static(Bool) case Dynamic }`
  （Unity の static branching と dynamic branching）。`lightingModelFor(v)`・`lightmapLightingModelFor(v)`・`pbrModelFor(v)`。今の `lightingModel()` などは `legacyVariant()` を渡すだけ（同じ木）。
- GLSL・WGSL: `pointShadow(i, p, n)`。CPU: `CpuHooks` に `pointShadowFunction` を足し、`${fn}(shadow, i, px, py, pz, nx, ny, nz)`（i = 並びの欄の位置）。
- GPU は場面ごとの変種のプログラム（鍵に `+ps`・`+pu`）。どちらも偽の変種は今の字のまま。CPU は `{ pointShadows = true, lightUnits = Dynamic }` で 1 本だけ生成する
  （影を落とさない灯りは関数が 1.0 を返し、`× 1.0` と Select は値を変えない）。

### 2.7 描き手ごとの仕事

| 描き手 | 地図を描く | 受ける | 鍵・寿命 |
|---|---|---|---|
| GL（render_gl） | atlas 1 枚（深度テクスチャ + FBO）を 1 回消し、面ごとに viewport を置いて行を流す（`Render3d.Shadow` の影の行を使い回す） | 変種のプログラムの `pointShadow`・uniform（2.8）・unit を 1 つ足す | ShadowMaps の寿命の表に atlas の鍵（幅・高さ）を足す |
| WebGPU（render_gl） | 1 枚の DEPTH32_FLOAT・面ごとに setViewport（1 つの pass か面ごとの pass。光の目の値は面ごとに別の buffer — writeBuffer が encoder の全部の pass より先に効くため） | 変種の pipeline の `pointShadow`。既定の pipeline の WGSL の字と uniform の並びは変えない（点光源の影の値は変種だけが読む別の binding） | 同上 |
| CPU（engine_tools） | 面ごとに `buildShadowMap`（Perspective(near)・S × S） | `pointShadowSampleOf` の後に PCF | — |

### 2.8 GPU の uniform（変種だけ）

点光源の番号 i ごと（8 本）: `uPointShadowSlot[i]`（int・−1 で影なし）・`uPointShadowDepth[i]`（vec2: A, B）・`uPointShadowNear[i]`・`uPointShadowStrength[i]`。
場面で 1 つ: `uPointShadowMap`・`uPointShadowTile`（S）・`uPointShadowBlocks`（列）・`uPointShadowScale`（s）・`uPointShadowBias`・`uPointShadowNormalBias`・`uPointShadowPcf`。灯りの位置は `uPointPos[i]`。

### 2.9 重さ（スマホ）

- 影の地図の draw は面 6 × 灯り × 範囲に入る物（面ごとに視錐台で間引く）。PCF は画素 × 光 1 本ごとに (2r+1)² 回（影を落とす灯りの光が届く画素だけ）。
- スマホの勧め: casters 1〜2・mapSize 256・pcfRadius 1。PC の数は 0・1・4・8 本で測る（§5）。

## 3. (B) 光の単位（K の案 (i) のうち式の側）

```flix
pub enum LightUnits with Eq { case Legacy  case Physical }      // Godot の「Use Physical Light Units」に当たる切り替え
pub def withLightUnits(u: LightUnits, scene: Scene3dCmd): Scene3dCmd
// Scene3dCmd に欄 lightUnits = LightUnits（scene() の既定 Legacy）
```

`Physical` の式（`Legacy` は今のまま）:

| 項 | Legacy（今） | Physical |
|---|---|---|
| 点・スポットの落ち方 | (max(0, 1 − d²/r²))² | clamp01(1 − (d²/r²)²)² / max(d_m², 1e−4)（d_m = d / unitsPerMeter。Filament・UE4 の窓 × 逆二乗） |
| 点・スポット・太陽の拡散 | albedo × E × facing | albedo / π × E × facing |
| 鏡面 | D G F / (4 n·v) × E | 同じ（もとから D に 1/π がある） |
| ambient・hemisphere・lightmap・emission | albedo × L | 同じ（入る放射輝度 L の意味。一様な L の空の拡散は albedo × L で、1/π と相殺） |

- intensity の読み: Physical の点・スポットは「1 m の所の照度」（cd に当たる。単位の型は付けない）、太陽は照度（lux に当たる）。lux / cd / EV100 の型と換算の口（K の C3）は後の段。
- 「ambient の見直し」は式を変えず値の決め直し（拡散の直接光が 1/π になる分、同じ ambient は相対的に π 倍強くなる）。ambient を空のグラデーションで方向つきにする案（Unity の Gradient）は人に上げる。
- 木: `ScalarInput.PhysicalUnits`（Dynamic の時だけ・0/1）と `ScalarInput.InverseUnitsPerMeterSquared`（1 / unitsPerMeter²）。
- 既定の切り替え・preset の値の決め直しは人（全部のゲームの絵が変わる）。

## 4. 既定で今の絵のまま（バイト一致）

| 所 | どう保つか | 確かめ |
|---|---|---|
| GLSL・WGSL | 変種が偽なら今の関数（`lightSource()` など）と同じ字。テストで字を比べる | render_gl のテスト（既定の字 = 変える前の字の SHA） |
| CPU | 生成物は変わるが、既定の値は Select と × 1.0 だけ | engine_tools の今の絵のテスト・templates の reference の SHA・`make gl-parity` |
| DrawHash | `pointShadows = None`・`Legacy` は書かない | TestDrawHash に「既定の鍵は変えない」 |
| GL の窓の絵 | 同じ字のプログラム | `make gl-capture-check`【未確認: 回せる環境か】 |

## 5. 比べと測り

- 絵（CPU と GPU）: 影なし / ありの部屋（bench/scene3d）・夜の街灯を並べた場面（放射状の影）・光の単位の今 / 新（部屋と Blender の手本 `spikes/agx-presets` の room）。日本語の大きなラベル。
- 動画: 灯りかカメラを動かす短い物（影の動き・入れ替わりのなめらかさ）。
- GPU の重さ（PC）: 影を落とす灯り 0・1・4・8 本。bench/scene3d に場面を足す（`make run SCENE=lamps SHADOWS=n`）。

## 6. テスト

- engine: `pointShadowsOf`（既定 None・選びと slot・本数の頭打ち・atlas の大きさの縮め・最後の 1 本の重み）・面の行列と `pointShadowSampleOf` の写しが同じ点に落ちる・面の選び・`LightUnits` の木の値（Legacy は今の木と同じ）。
- engine_tools: 床と箱と点光源で、影ありの床の画素が暗い・影なしは今と同じ画素・Physical の距離の比（逆二乗）・DrawHash の既定の鍵。
- render_gl: 既定の字が変わらない・変種の鍵・FakeGl で uniform と atlas の pass。gl-parity に 2 場面（点光源の影・Physical）。

## 7. 入れない物（WhyNot）

- 灯りごとの影の切り替え（`PointLight` の欄）— 閉じたレコードの型が変わり全部のゲームが壊れる。要るなら別の型の口で後から。
- 光の大きさで縁をぼかす（PCSS）— S6 の別の項。今は PCF の幅だけ。
- ビルボードが点光源の影を落とす・受ける — HD-2D の町の話で、太陽の影の板の向きと別の約束が要る。
- 影を落とす灯りを毎コマ全部描き直さない工夫（動かない灯りの地図の持ち越し）— 計ってから。

## 8. レビュー 1 回目（72 点）を受けた直し（この節が上の本文より優先）

名前: 灯りの本数の欄は `maxShadowedLights`（`casters` は業界では影を落とす「物」）。型は `ShadowedPointLight`・上限は `maxShadowedPointLights()`。本文の「casters」は全部この意味に読み替える。

1. **木の外で 1 画素 1 回だけ引く**（PBR で拡散と鏡面の 2 つのループが両方引かないように・太陽の `r3d_sunLit` と同じ形）。
   - GLSL・WGSL: 変種のプログラムの main が光の計算の前に `r3d_pointShadowsAt(p, g, n)` で `float r3d_pointLit[8]`（WGSL は `var<private>`）を埋める。木の `PointShadowLit` は `r3d_pointLit[i]` を読むだけ。
   - CPU: 生成する関数の引数に `pointLit: Vector[Float64]`（8 個・点光源の番号で引く。木の中は `Vector.get(i / pointStride, pointLit)`）。影の無い場面は全部 1.0 の 1 本を使い回す（画素ごとに作らない）。影のある場面は画素ごとに 8 個を作る。
   - 1 本ごとに引かない条件（1 を入れる）: slot が −1・|p − 位置|² ≥ range²・dot(n, 位置 − p) ≤ 0（wrap = 0 の facing が 0。太陽の `dot(n, l) <= 0` と同じ）。
   - normal offset は **形の法線 g**（法線マップの前・裏の面は返した後）。facing の判定は光の計算の法線 n。
2. **6 面の基底**（独自の基底。R × U = F を満たす。GL の cube の向きには合わせない — atlas なので要らない）:

   | f | 面 | F | U | R |
   |---|---|---|---|---|
   | 0 | +X | (1, 0, 0) | (0, 1, 0) | (0, 0, −1) |
   | 1 | −X | (−1, 0, 0) | (0, 1, 0) | (0, 0, 1) |
   | 2 | +Y | (0, 1, 0) | (0, 0, 1) | (−1, 0, 0) |
   | 3 | −Y | (0, −1, 0) | (0, 0, 1) | (1, 0, 0) |
   | 4 | +Z | (0, 0, 1) | (0, 1, 0) | (1, 0, 0) |
   | 5 | −Z | (0, 0, −1) | (0, 1, 0) | (−1, 0, 0) |

   （R × U = F は Camera3d の right × up = forward と同じ向き。テストで 6 面とも確かめる。）
3. **WebGPU の行の向き**: atlas の画素の (x, y) は GL の数え方（行 0 = ndc.y = −1 側・塊の原点も下から）で決める。WebGPU の面の viewport と scissor は `(ox, H − (oy + S), S, S)`、読む時は塊の中へ寄せた後で `H − 1 − y`（H = atlas の高さ）。CPU は面ごとの Vector で行 0 = ndc.y = −1。
4. **DrawHash**: `putSceneCmd` の閉じたパターンに欄 2 つを足す。`pointShadows` が Some の時だけ印 0x50 と中身、`Physical` の時だけ印 0x55 と `unitsPerMeter`（Physical では絵が変わるので鍵に入れる。WhyNot を直す）。既定は何も書かない（今の鍵のまま）。PostStack の Passes.flix は `{ .. | Scene3d.scene(..) }` で組むので直さない。
5. **変種のプログラムの範囲**（鍵は場面の設定で決める: `pointShadows` が Some なら `+ps`・`Physical` なら `+pu`。このコマで影を落とす灯りが 0 本でも `+ps` のまま — 灯りの出入りでシェーダーを組み直さない）:

   | プログラム | +ps | +pu |
   |---|---|---|
   | 頂点の色（lit）・材質（uv・nm・lm・bl・ds・cov・mr）・骨つき | 持つ | 持つ |
   | ビルボード（lit） | 持たない（影を受けない） | 持つ（無いと Physical でビルボードだけ π 倍明るい） |
   | Output.Depth・空・影の地図の depth | 持たない | 持たない |

   GL は `ProgramKind` に `pointShadows`・`physicalUnits` を足し `materialKey` に `+ps`・`+pu`。頂点の色とビルボードの組み（`Programs`）は変種 → 組みの表で持つ。どちらも偽なら今と同じ字。
6. **WebGPU の bundle**: 持ち越した集まりの bundle の鍵に変種の字（`+ps`・`+pu`）を入れる。影の地図の bundle は「灯り × 面」の鍵（最大 48）。持ち越した集まりは面ごとの視錐台で間引かない（今の太陽と同じ扱い）。
7. **置き場所**: GLSL は `+ps` の時だけ `uniform vec4 uPointShadow[8]`（slot・A・B・strength。near = B / (A + 1)）と場面の 1 つの値（`uniform vec4 uPointShadowAtlas` = (S, 列, s, pcf)・`uniform vec2 uPointShadowBias` = (bias, normalBias)）・`uniform sampler2D uPointShadowMap`、`+pu` の時だけ `uniform float uInverseUnitsPerMeterSquared`。
   WGSL は既定の `R3dScene` の struct と group 0 の layout を変えず、変種の pipeline だけ group 0 に binding を 2 つ足す（uniform の buffer `r3dLight` と atlas の `texture_depth_2d`）。番号は今の最後の次。変種でない pipeline の layout は今のまま。
8. **GL の unit**: atlas は unit 14（`pointShadowTextureUnit()`）。影の無い場面は blank の unit を指す。`sunShadowTextureUnit` の doc の使用中の範囲を直す。
9. **`pointShadowsOf` が None**: Output.Depth・置いた物が無い（hasDrawnInstance）・`maxShadowedLights ≤ 0`・`mapSize ≤ 0`・設定が None。Some なら影を落とす灯りが 0 本でも Some（lights = Nil）。
10. **大きさの下限**: S は 16 以上（下回れば 16）・pcfRadius は `maxShadowPcfRadius()` で頭打ちし、さらに 2(r + 1) < S / 2 になるよう縮める。atlas は `maxShadowMapSize()`（4096）で頭打ち（今の太陽・スポットの地図と同じ上限。WebGL2 の最低 2048 は今の地図と同じ扱いで別の話）。
11. **atlas の鍵**: `ShadowMaps.Key` に case `Atlas(幅, 高さ, 何枚目か)` を足す（`sizeOf` は (幅, 高さ) を返す `extentOf` に替え、GL と WebGPU の createTarget を幅と高さで作る）。1 回の prepare に影つきの場面が 2 つなら atlas も 2 枚。
12. **hemisphere**: `hemisphere × max(0, n.y)` は向きを持つ空の光だが「入る放射輝度」として足す値なので Physical でも 1/π を掛けない（ambient と同じ目盛り。拡散の 1/π は点・スポット・太陽の照度 E にだけ掛かる）。
13. **変種の名前**: `LightVariant = { pointShadows = Bool, lightUnits = Option[LightUnits] }`（None = uniform で選ぶ。CPU の生成物が使う）。`Branch` は作らない。
14. **CPU の生成物の大きさ**: 生成した関数のメソッドが 8,000 バイトを超えると JIT されない（docs/performance.md）。変える前と後で `javap -c` のメソッドの大きさと `make cpu-time`（bench/scene3d）を比べる。
15. **F3 の診断**: 影の地図の draw は今の `shadowPass` に入る。atlas の大きさを縮めた時は 1 回知らせる（warnShadowOnce）。
16. **比べの絵**: Physical は intensity を同じままの版と、拡散が今と同じ明るさになるよう intensity × π（点・スポットは 1 m の所で合わせる）の版の 2 つを並べる。
17. **テスト**: 最後の 1 本の重みは「1 つ前と入れ替わる瞬間に両方 1」「次の候補と入れ替わる瞬間に 0」。CPU のテストの場面は mapSize 32〜64。WebGPU の面の viewport の y のテストを 1 本。
