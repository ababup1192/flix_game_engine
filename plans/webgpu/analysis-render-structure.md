# 描画と表現を載せる構造の分析（影 MOD 級の表現をいずれ出すために）

日付 2026-11-14。読んだだけ（直していない・ビルドもテストもベンチも流していない）。
印: 【確】= コードか文書で確かめた / 【推】= 推測 / 【不明】。パスは engine の根から。ゲームは `~/Documents/flix_ge_workspace/`（以下 ws）。

## 要約
弱点の上位 5 つ:
1. **3D の描きは色 1 枚しか後の pass へ渡さない。** 深度は場面をもう 1 回描いて取り、法線・roughness・motion vector・shadow map は名前の付いた絵として出ない。SSAO・SSR・体積の光・TAA・屈折はここで止まる。
2. **post process に完成品の部品が無い。** あるのはトーンマップと FXAA と場のノードだけ。ブルーム・DoF・ビネット・彩度は 9〜10 本のゲームが `PostView.flix`（計 約 1,100 行）と `LookDoc.flix`（計 1,688 行）を手で書いている。テンプレ 4 本に Pass と 3D の手本は 0。
3. **式の木が 2 つある。** ゲームに開いた `ShaderDoc.Field`（スカラーだけ・輪なし・画面の座標も深度も読めず、出せるのは色と α だけ）と、エンジンの中の `LightModel3d`（vec3 あり）。その外に手書きの GLSL（影の PCF・TBN・mip 選び）。WGSL で出口がもう 1 つ増える。
4. **効果 1 つの代金が大きい。** PBR 1,523 行・43 ファイル、太陽と影 1,371 行・34、環境マップ 912 行・29。宣言の型・式の木・GL・CPU・gl-parity・テスト・文書・eval の 8 か所を毎回触る。
5. **同じ役目の口が並び、黙って落ちる約束が多い。** 2D の光は 9 通り（うち 4 つは使用 0）。知らない `kind` で Doc 全体が既定へ・無い絵の名前は黒・同じ z では面と 3D が必ず手前・Spec の名前が program の鍵、など型で止まらない。

推す構造: **案 1（post process を値の列で宣言する `PostStack`）を先に入れ、その下に案 2（3D が名前つきの attachment を出し、効果は「読む物・書く物・CPU との合わせ方」を宣言して登録する）を段で足す。** render graph への全面の作り替え（案 3）は取らない。式の木の型付けと 1 本化だけ、WGSL の出口を足す時（`engine-webgpu.md` 7 章・P5）に合わせる。

先に試す事: (a) lamplighter の `PostView` 98 行を preset の値に置き換えて 0 px 差になるか (b) `bench/scene3d` の部屋に法線の attachment を 1 枚足し、深度と法線を読む SSAO を場の木で書けるか・CPU との差は何 px か (c) `Field` に vec3 を足すと `chan ->` の 3 回書きと木の大きさがどれだけ減るか。

## 1. 見た目を作る口の全体像【確: `refactor outline`・docs/shader-doc.md・docs/scene3d.md】
| 口 | 形 | Doc（JSON）から | Studio | 備考 |
|---|---|---|---|---|
| `Render.Item`（Sprite・Text・Box・Poly・Clipped・Shader・Scene3d）+ `Render.*` の加工（fade・tinted・blended・turned・clipped・masked・outline…） | 値 | 一部（ui.json・sprite.json） | フォーム | View が `List[PlacedItem]` を返す。`engine_world/src/Render.flix:18` |
| `RawDraw`（box・circle・star・ellipse・sector・ngon・線） | 値（材料） | × | × | lint-view が box と circle だけの View を止める |
| `ZStack`・`SortingLayer`・`Depth.orderAt` | 値（木） | × | × | z を数で書かせない。docs/z-bands.md |
| `ShaderDoc`（`Field` 41 種・`Shade` 5 種・`Out.Fill` 1 種） | 値（式の木） | ○ `*.shader.json` | フォーム（schema を隣に置く） | 入力: uv・時刻・`Param`・`Tex`（絵か pass）・`TexBlur`・`TexSize`・3D の材質だけ `World`・`Normal`・`VertexColor`。出力: 色と α だけ。`engine/src/shader/ShaderDoc.flix:65-220` |
| `ShaderGen`（GLSL）・`ShaderEval`（CPU） | エンジンの中 | — | — | 1,218 行と 1,079 行。同じ木から両方 |
| Pass（`Render.Pass`・`PassPlan`・`RenderTarget.Descriptor`） | 値 | × | × | 描き先は scale・basis・format（Rgba8Unorm / Rgba16Float）・samples。前に宣言した pass を `Tex` で読む。自分の名前 = 前のコマ（history）。`Render.flix:722-822` |
| `PostProcess`（`tonemapped`・`tonemappedWith`・`fxaaSpec`・`luma709`） | 値（Spec を包む関数） | × | × | 201 行。ブルーム・DoF は無い |
| ぼかし | `Field.TexBlur`（円状・64 taps まで） | ○ | ○ | 専用の pass は無く、面の中で読む |
| 2D の光 | `Render.glowAt`・`lightAt`・`darkAt`、`Light.items`・`singleLightItems`・`multiLightItems`・`lightMapPass`、`LightDoc`、`Daylight.overlay` | `LightDoc` だけ ○ | 【不明】 | 値。光マップは Add で集めて Multiply で貼る pass |
| 2D の影 | `Shadow.itemsFor`・`projectedRuns`、`Daylight.groundShadow`・`sideShadow` | × | × | 多角形で作る |
| `Scene3d`（instance・material・点 8・スポット 2・太陽 1・影（スポット 1 + 太陽 1）・`Environment3d`（ambient・hemisphere・toon・fog）・sky・environmentMap・lightmap・billboard・`Output.Color/Depth`） | 値（1 コマ 1 つの `Scene3dCmd`） | ×（`refactor search` で Scene3d・材質・look の JSON の読みは 0 件） | × | ゲームが `LookDoc` を自前で書いて schema を付けている |
| `Material3d`（Spec + params + cutout + blend + 両面 + emission + metallicRoughness + normalMap + wrap） | 値（閉じた型） | Spec の所だけ ○ | Spec だけ | 光の式は選べない |
| `LightModel3d`（`ScalarExpr`・`Vec3Expr`・`Cond`） | エンジンの中の式の木 | × | × | lightAt・fogAt・pbrAt・skyAt など。GLSL と CPU 用の Flix を生成。ゲームは差し替えられない【推】 |
| 粒子 `Fx`・`FxDoc` | 値（時刻の純粋な関数） | ○ fx.json | ○ | CPU で 1 粒 1 Item |
| `Transition`・`CameraRig`・`TimeScale`・`Timeline` | 値 | × | × | |
| 動かない物 `App.withStaticLayer`（2D の多角形だけ）・`withPreload3d`・`withTileLayers`・`withSpriteAtlases` | 宣言（App の欄） | × | × | |

手続きで描く口はゲームに無い（GLSL も書けない）。全部「値を返す」で貫けている。これは強みで、下の案もここを崩さない。

## 2. 影 MOD の技法との対応【確は場所つき・ほかは推】
| 技法 | 今 | 理由・場所 |
|---|---|---|
| やわらかい影（PCF） | ある | スポット 1 本 + 太陽 1 本。PCF は半径 8 まで・手書きの GLSL と CPU（`Render3dGlsl.shadowSource`・`SoftRaster3d/Sun.flix`）。距離で変わる柔らかさ（PCSS）・点光源の影は無い |
| カスケード | 無い | 1 段・bias は m で固定（`Scene3d.sunShadowSetupOf`。plans/engine-city-scale.md #7）。構造の壁ではない（影の計画は光ごとに 1 枚を作る形）【推】 |
| すき間の暗さ（SSAO） | 無い・今の構造では筋が悪い | 法線を出す道が無い（MRT 不使用・survey C §4 #8）。深度は `Output.Depth` で場面をもう 1 回描けば pass で読める（8bit か 16F の灰色）。多点読みは `use` で括れず全部インライン（docs/shader-doc.md「use の意味」）。ベイクの AO は lightmap である |
| 映り込み（SSR） | 無い・作れない | 色・深度・法線・roughness を同じ画素で読む段が要る。場に輪が無い（固定の展開だけ）。似た物: 環境マップ + 箱の補正（3D）・`Mirror`（2D） |
| 水（波・屈折・映り） | 一部 | 半透明・Fresnel（`pbrModel`）はある。波は不可: `NormalMap = { texture, strength }` に uv の倍率とずらしが無く、`Out.Fill` は法線を出せない。屈折と平面の映り込みは、材質が画面の座標で pass を読む場（Godot の SCREEN_UV）が無いので不可（city-scale #4） |
| 空 | 一部 | 3 色のグラデーション（`gradientSky`）か環境マップを背景に。太陽の円・大気散乱・星は、空の式（`skyAt`）がエンジンの固定の木なので足せない【推】 |
| 雲 | 2D だけ | `fbm`・`warp` の面。3D の空に乗せる口が無い。体積の雲は無い |
| 光の筋（god rays）・体積の光 | 無い・作れない | shadow map は `Render3d` の中の FBO で名前が無く、後の pass が読めない。画面空間の放射ぼかしは `Shift` を手で展開すれば近い物は組める【推】 |
| ブルーム | 部品だけ | HDR の pass・縮んだ pass・`TexBlur` はある。組むのはゲーム（ws の 9 本が手書き） |
| トーンマップ・FXAA | ある | `PostProcess`。自動の露出は無い（画面の平均の明るさを読む口が無い） |
| DoF | 組める | `Output.Depth` の pass + ぼかし（fps3d_lab・lamplighter）。場面を 2 回組む |
| TAA・モーションブラー | 無い・作れない | 前のコマは「自分の名前の pass」だけ。motion vector が無い。カメラをコマごとに少しずらす口が無い。描き出しでは history は透明なので CPU と合わない |
| かすみ | ある（距離の線形） | 高さのかすみ・体積は無い |
| 色の仕上げ | 手書き | `tonemappedWith` の `after`。LUT は無い |
| GI | ベイクだけ | lightmap（Blender）。骨なしの物だけ |

## 3. 使われ方（テンプレ 4・bench 6・ws 19 の計 29 フォルダの src と test を字で数えた）【確】
- **よく使われる**: `RawDraw.box` 25 フォルダ 375 か所・`Render.fade` 21・`Render.shaderFill` 21・`Field` を Flix で直に組む 20（347 か所）・`ZStack` 16・`Render.blended` 13・`Scene3d.withMaterial` 13・`withPassPlan` 12・`gradPolygon` 12・`vgrad` 11・`PostProcess` 10・`withHdr` 10・`PxShade` 10。
- **使われない（0）**: `Light.items`・`singleLightItems`・`multiLightItems`・`LightDoc`・`FxDoc`・`Scatter`・2D の `Material`（SurfaceFx）・`Render.masked`・`App.withPasses`・`Render.spriteFlipped`。**ほぼ 0**: `Render.striped`（bench だけ）・`checker`（1）・`Daylight`（1）・`Mirror`（1）・`lightMapPass`（1）・`atWorld`（bench だけ）・`Timeline`（1）。`unused-parts.md` の 14 行のうち、`PxShade`・`vgrad`・`gradPolygon`・`clipped`・`withSpriteAtlases` は載せた後に広まり、`Scatter`・`FxDoc`・`Material`・`Daylight`・`Mirror`・`striped` は載せても使われていない。
- **`refactor usages --unused`**（engine の根で 1 回）: 外から使われない pub の def 1,407（参照 0 が 875）。描画に関わるファイルに絞ると **382**（`Render.flix` 30・`Scene3d.flix` 26・`ShaderDoc.flix` 10・`PostProcess.flix` 6・`Light.flix` 6・`LightDoc.flix` 8・`Fx.flix` 11・`Daylight.flix` 11 など）。ただし engine は配るライブラリで、使い手は索引の外にいる（上の字の数えで補った）。
- **毎回手で書いている組み方**:
- 後がけの鎖。`scene`（窓の画素・HDR・MSAA）→ `depth` → `soft` → `bright` → `bloomA` → `bloomB` → `post` → FXAA。`ws/lamplighter/src/PostView.flix`（98 行）とほぼ同じ物が conduit_hive・dungeon3d_lab・fps3d_lab・hd2d_lab・night_apartment・ome_city・plateau_city・sea_cave_walk・stepdown にある（35〜163 行）。
- その値の Doc。`LookDoc.flix` が 9 本（87〜260 行）。露出・白の点・ブルームのしきい・彩度の欄と `min`・`max` を各ゲームが決め直している（`ws/lamplighter/assets/look.schema.json`）。
- `def k`・`add`・`sub`・`mul`・`linear` の小さな関数と、`chan -> …` を R・G・B に 3 回当てる書き方（`PostView.flix:52-72`）。`Field` がスカラーだけのため。
- **回り道**: 深度のために場面を 2 回組む（`fps3d_lab/src/RoomView.flix:168`・`lamplighter/src/SceneView.flix:194`）。3D の材質の Spec は Flix に直書きで、shader.json は ws 全体で 4 個。
- **手本の穴**: テンプレ 4 本は `withPassPlan`・`Scene3d`・`PostProcess` を 1 度も使わない（sound-novel-starter の `Backdrop.flix` に `blur` が 1 か所だけ）。3D と後がけは、AI が前のゲームを写して広めている【推】。

## 4. AI への案内の今【確: agents-pack・bin/lint-rules・docs】
| 渡している物 | 中身 |
|---|---|
| 早見表 `agents-pack/AGENTS.core.md`（190 行） | 「したい事 → 口」。3D と後がけは 20 行ほど（HDR・トーンマップ・MSAA・PBR・環境マップ・太陽・preload・draw call の切れ目） |
| `docs/art-ref/visual-dict.md` と `reference.md`・`unused-parts.md`・`recipes.md` | 画風を決める手順・web の技法 → 部品 17 行・画風の例 4 つ。**全部 2D の話で、3D と post process の行は無い** |
| lint | lint-view（box と circle が 80% を超える View）・lint-style（描いた PNG の階調の段と格子）・check-render-budget（1 場面の描き物 2,000 個）・z-table・z-audit・render-lint（字の被り）・lint-quadratic・lint-hoist・forbid（`List.sortBy` → `Sort.sortStable*` を含む） |
| 周回 | `make render SHOT=`（1 枚）・`/render-loop`（1 つ直して前後を並べる）・`/critique-render`（5 性質で批評）・`HeadlessRender.silhouettePng`・`make compare` |
| 診断 | `App.withDiagnostics`（`draw2dCounts#batchBreaks`・`scene3dCounts`・`cpuPhases`）・`hitch.md`（重いコマの推定原因）・`SoftRaster.dropped`・`warnOnce` の知らせ |
| eval | `agent-eval/engine.json` 157 題。答えに出た道具の名前を正規表現で採点する |

`docs/agent-eval.md` に残る記録: 外れのほとんどは採点の誤りで、答えは正しかった。**「早見表をなぞる測りになりやすい」「書いたコードの出来は見ない」**と自分で書いている。AI が絵でつまずいた記録はこの文書には無い【確】。お題の名前（`hitch-shader-rebuild`・`shader-param-per-frame`・`dropped-lights-3d`・`scene3d-linear-color-retune`）は、実際に起きた回り道から足した物と読める【推】。

## A. 今のコードの弱点（大きい順）
### A1. 入力の壁 — 後の段が 3D の結果を読めない【確】
- `Scene3d.Output` は `Color` と `Depth` の 2 つ（`Scene3d.flix:191`）。1 回の描きで出るのは色 1 枚。MRT は使っていない。深度は別の pass で場面を組み直す（影と合わせて 1 コマ 3 回。plans/engine-scene3d-cpu.md）。
- `ShaderDoc.Out` は `Fill{shade, alpha}` だけ（`ShaderDoc.flix:218`）。材質は法線・roughness を画素ごとに出せない（roughness は別の欄 `metallicRoughness` の Shade）。
- `Field` に画面の座標・深度・視線・前のコマを読むノードが無い。pass は色だけを名前で読む。shadow map・lightmap・環境マップは `Render3d` の中の物で、pass の名前を持たない。
- 前のコマは「自分の名前を読む pass」だけ。窓で遊ぶ時だけ効き、描き出しでは透明（docs/shader-doc.md「pass の連鎖」）。

### A2. 継ぎ足しの跡【確】
| 役目 | 並んでいる口 |
|---|---|
| 2D の光 | `Render.glowAt`（同心円 24 輪）・`lightAt`・`darkAt`（組み込みの絵）・`Light.items`・`singleLightItems`・`multiLightItems`・`lightMapPass`・`LightDoc`・`Daylight.overlay`。3D の光（`Scene3d` の欄）とは別の世界で、2D のスプライトに 3D の光は当たらない |
| 影 | `Shadow.itemsFor`・`projectedRuns`・`Daylight.groundShadow`・`Scene3d.ShadowMap`・`DirectionalShadow`。`Shadow` は 2D の mod の名前で、描き手の `Render3d.Shadow` と同じ字 |
| material | `engine_world/Material.flix`（タイル地形の SurfaceFx）と `Scene3d.Material3d`。同じ語で別の物 |
| 式の木 | `ShaderDoc.Field`（ゲーム用）と `LightModel3d.ScalarExpr/Vec3Expr`（エンジン用）。生成器も `ShaderGen` と `LightModel3d.Codegen` の 2 本、CPU も `ShaderEval` と生成した Flix の 2 本 |
| pass の宣言 | `App.withPasses`（使用 0）と `App.withPassPlan` |
| 動かない物 | `withStaticLayer` と `withPreload3d` が同じ `StaticKey` を取るが役目は別。`withStaticLayer` は多角形以外を黙って捨てる（`App.flix:423-444` の doc） |
| 回す・反転 | `Render.rotated`・`flipH` は頂点の列用、Item は `turned`・`spriteFlipped`（単位は回転数） |
| 3D の後がけ | エンジンに無く、2D の pass を借りる。HUD はトーンマップしない等の順はゲームが覚える |

### A3. 組み合わせの壁【確: docs/backend-parity.md・shader-doc.md・scene3d.md】
- 透明から始める pass（`ClearTransparent`）の中の 3D の場面は、CPU の描き出しで出ない（既知の穴）。
- FXAA は窓の画素・scale 1・トーンマップ済みの pass が前提。縮んだ pass では縁がずれる。
- lightmap は骨なしだけ・法線マップは uv つきだけ・影はスポット 1 + 太陽 1・ビルボードは影を受けない。
- 同じ z では面と 3D の場面が必ず手前（並べた順は効かない。知らせは出る）。
- 角丸・枠・縞を絵や字に付けると CPU では落ちる（`SoftRaster.dropped` に出る）。
- MSAA は GL だけ。WebGPU では標本数が 1 か 4 になる（今は 1・2・4・8）。

### A4. 3 つ書く代金【確: `git show --numstat`】
| コミット | 合計 | 宣言の型（engine） | 式の木 | ShaderGen/Eval | render_gl | SoftRaster | gl-parity | test | 文書・eval |
|---|---|---|---|---|---|---|---|---|---|
| PBR（49362dd3） | +1,523 −320・43 ファイル | +269 | +203 | +83 | +86 | +145 | +177 | +470 | +80 |
| 太陽と影（f9598dce） | +1,371 −236・34 | +123 | +46 | 0 | +237 | +212 | +278 | +363 | +66 |
| 環境マップ（302805d7） | +912 −82・29 | （内訳は未集計） | | | | | | | |

式の木に乗った所（PBR の `pbrAt`）は GL 側が +86 で済み、木の外の手書き（太陽の影）は GL +237・CPU +212 と両方に書いている。**木に乗るかどうかで、描き手 2 本の代金が約 3 倍違う。** WebGPU が入ると、木の外の物は WGSL でもう 1 回書く。Doc のスキーマと Studio は今は 0 行（3D は Doc に出ていないため）で、出せば増える。

### A5. 変種の数【確: `Render3d.ProgramKind`・survey C §3.2】
`ProgramKind` は bool 8 個（skinned・uv・normalMap・lightmap・blend・doubleSided・coverage・metallicRoughness）。制約を入れて材質の木 1 つにつき最大 144 通り × 木の種類。鍵は `"3d" + kind + shaderHash`・LRU は `max(64, pinned×2)`。2D の面は Spec の name が鍵で、当たっても毎コマ `eqSpec` で中身を比べる。WebGPU では blend・描き先の形式・標本数が pipeline の鍵に掛かる（`engine-webgpu.md` 7 章）。G-buffer の出力や影の段を bool で足すと、この掛け算が続く。

### A6. 暗黙の約束（型で止まらない物）【確】
| 約束 | 外すとどうなるか |
|---|---|
| shader.json の知らない `kind` | Doc 全体が既定値へ。エラーなし（docs/shader-doc.md 冒頭） |
| 無い絵・まだ描いていない pass の名前 | 黒。1 回知らせるだけ |
| Spec の `name` が program の鍵・`pp_` で始まる名前は予約 | 同じ名前で中身が違うと毎コマ作り直し・予約名があるとトーンマップせず元のまま |
| `Const` に動く値を書く | 毎コマ program を作り直す（`Param` と `withShaderParams` が正） |
| `use` は面の基準 uv で 1 回だけ評価・`atWorld` は定義の側に書く | 外から包んでも world を読まない |
| 色の空間 | 2D はガンマのまま混ぜる・3D は線形で計算して出口で戻す・HDR の pass はガンマの値のままトーンマップ（既定の露出 +0.4 で白っぽくなり、−0.6 が目安と文書にある） |
| α | straight alpha。pass の α は blend の副産物で、`chan:"a"` は近似 |
| 葉の中の z は 0..31・同じ z の種類の順 | コードでは縛らない（知らせと lint） |
| 単位 | `turned` は回転数・uv の v は下向き・法線マップは OpenGL 流・`Viewport` は左下原点 |
| pass の上下 | GL は逆さに持ち、貼る側が反転。WebGPU では逆になる |

### A7. AI から見た書きにくさ（見本の文書の指摘を確かめた）
| 指摘（plans/webgpu/samples/） | 確かめた結果 |
|---|---|
| 白く光らせる口が無い | 【確】`refactor search` で flash・whiten は 0 件。`tinted` は掛け算 |
| y で並べる近道が無い | **ある**【確】`Depth.orderAt(footY)`（`Depth.flix:11`）。hd2d_lab と rpg-starter が使う。見本の文書の側の見落としで、名前から引けない事の方が問題 |
| `Render.rotated`・`flipH` は頂点用 | 【確】Item は `turned`・`spriteFlipped`。`spriteFlipped` の使用は 0 |
| アトラスのコマを番号で指せない | 【確】`regionRect` を 1 個ずつ持つ |
| `withStaticLayer` は多角形だけ・黙って捨てる・1 つだけ | 【確】doc に「それ以外の item は無視される」 |
| `withPreload3d` と `StaticKey` | 【確】同じ型の鍵で役目が別 |
| `instances` が `List` で `++` の向き | 【確】`Scene3dCmd#instances: List[Instance3d]` |
| 3D の「読んで持っておく場所」の手本が無い | 【確】テンプレに 3D が無い |

ほかに見つけた物: (a) `Field` がスカラーだけなので色の式を 3 回書く (b) ブルームのような定番に名前が無く「pass 6 枚と Spec 4 つ」を覚える必要がある (c) `Light`・`Shadow`・`Material` が 2D と 3D で別の物 (d) `PostProcess.tonemapped` の露出の既定が、文書の勧める値と違う (e) 3D の値は Doc に出す型がエンジンに無く、「値は Doc へ」の方針をゲームごとに作り直している。

### A8. 性能の罠（survey I の指針に照らす）
| 素直に書くと | 代金 | 根拠 |
|---|---|---|
| View で毎コマ Spec の木を組む | `buildProgram → eqSpec` の構造比較が 1 コマの約 1 割（lamplighter の jstack）。`Render.cachedBySpec` が参照一致の表で逃がしている | survey C §5.2・`Render.flix:258-261` |
| `Scene3dCmd#instances` を `List` の `++` で組む・`Instance3d` は record | 欄の引き当てが最上位のフレームの 4 割強。857 個で 14.1 ms | plans/engine-scene3d-cpu.md |
| `withParams(Map[String, Float64])` を材質ごとに毎コマ | `Map[String]` の get は 28〜137 ns | survey I C5 |
| 深度・影・色で場面を 3 回組む | 物の数 × 3 | A1 |
| `List.sortBy` | 並んだ入力で二乗。ws の 10 フォルダに 53 か所・`sortWith` は 0。forbid が `Sort.sortStable*` へ送るが、今あるゲームは未追随 | 字の数え・`forbid.json:398` |
| `Render.Item` を 1 個ずつ作る | 1 個 約 1.3 µs | `engine-webgpu.md` 6.2 の 11 |
| 全面の `TexBlur` 64 taps | 画素 × taps。縮んだ pass を使うのは文書の助言だけ | docs/shader-doc.md「ぼかしのコスト」 |
輪の中で effect を呼ばせる API は、ゲームが触る口には見当たらなかった（View は純粋）【確: outline の範囲】。

## B. 汎用性が高い構造 — 他のエンジンの形（自分の知識。細部は【推】）
| 形 | 値として宣言させる物 / エンジンが決める物 | 効果を足す時に触る所 | 組み替えられる範囲 | 6 つの考えとの相性 |
|---|---|---|---|---|
| 影 MOD（OptiFine・Iris の決まり） | 利用者: 段ごとの GLSL と buffer の形式。エンジン: 段の順（shadow → gbuffers → deferred → composite → final）・何をどの program で描くか・uniform の一式 | GLSL のファイル 1 つ（composite を 1 段足す） | 段の中は自由・段の順と入力（colortex・depthtex・shadowtex）は固定 | 「固定の段 + 名前の決まった入力」は合う。GLSL を書かせる所が (3) とぶつかる。CPU の答えを持てない (2) |
| Unity SRP + Volume + Renderer Feature | Volume: 効果ごとの値の束を場所・重み・優先度で混ぜる。Renderer Feature: 決まった差し込み点に pass を足す。pass は読む物と書く物を render graph に言う | C# の pass 1 つ + Volume の component 1 つ + shader | 差し込み点の列の中。pipeline ごと差し替えも可 | **Volume（値の束を混ぜる）は (6) の Doc と (1) にそのまま合う。** pass を手続きで書く所は (3) とぶつかる |
| Unreal（post process volume + material graph） | volume: 固定の効果一覧の値。material: 決まった出力（base color・normal・roughness・emissive…）へつなぐ node の木。光と deferred はエンジン | 効果そのものはエンジンの C++。利用者は post process material を差し込み位置つきで足す | material の木と、決まった位置の全画面 material | **「material は決まった出力を埋めるだけ・光はエンジン」は (3)(5) と同じ考え。** 今の `Out.Fill` を広げる手本 |
| Godot 4（Environment・Compositor・shader 言語） | Environment: 空・ambient・tonemap・SSR・SSAO・glow・fog を 1 つの resource の欄で。shader: `ALBEDO`・`NORMAL`・`ROUGHNESS` に書き、`SCREEN_TEXTURE`・`DEPTH_TEXTURE`・`SCREEN_UV` を読む。Compositor: 決まった段で低い API を呼ぶ | 組み込みはエンジン。利用者は shader か CompositorEffect | Environment の欄の on/off と値。それ以上は低い API | **Environment（1 つの値に全部の欄）は Doc と Studio に一番近い。** 画面の絵と深度を名前で読む入力は A1 の答えの形 |
| Bevy（render graph + plugin） | camera に component を付けて頼む（`Bloom`・`DepthPrepass`・`NormalPrepass`・`MotionVectorPrepass`）。plugin が node を graph に足し、前後を label で言う | plugin 1 つ（node・pipeline・抜き出し） | graph の node の足し引き。prepass は要る物だけ出る | **「要る attachment を値で頼むと、その prepass が出る」は (5) そのもの。** render-from-World も今と同じ。node は手続きで (3) とぶつかる |
| three.js（EffectComposer → TSL） | 旧: pass の配列を順に通す。新: `pass(scene)` の出力（色・深度・MRT で法線）を node として受け、`bloom(node)`・`ao(depth, normal)` のように関数でつなぐ。node の木から WGSL と GLSL の両方を出す | 効果 = node を返す関数 1 つ | 木を自由に組める | **木 1 本から 2 つの shader 言語を出す所が、このエンジンの `ShaderGen` + WGSL の課題と同じ。** CPU の出口は無い |
| Frostbite の frame graph | pass が「作る・読む・書く」資源を宣言。エンジンが、使われない pass を落とし、資源の寿命を決め、メモリを使い回す | pass 1 つ（宣言 + 実行） | 全部 | 宣言と実行を分ける所は (1)(5) に合う。今の `resolvePassReads`（読みの順の検査）はこれの小さな版。実行の側は手続き |
| Blender の compositor | Render Layers の node が pass（色・深度・法線・AO・mist）を出し、利用者が node をつなぐ。出す pass は view layer で選ぶ | node 1 つ | 木を自由に | 「描き手が名前つきの pass を出し、後は木」は合う。実時間ではない |

読み取れる事: (i) **利用者に見せる面は「値の束」（Volume・Environment・component）か「決まった出力を埋める木」（material）に収れんしている。** (ii) 後の段が読める物（色・深度・法線・前のコマ・影）は、どの形でも**名前が決まった入力**で、頼んだ物だけ作る。(iii) 効果の実装そのものを利用者に書かせるかは分かれる（影 MOD・three は書かせる、Godot・Unreal は書かせない）。このエンジンは (3) から後者。

## C. このエンジンに適した構造の案（見本は型検査をしていない。（新）= 今は無い名前）
### 案 1 — 伸ばす: post process を値の列で宣言する `PostStack`（新）
一言: ブルーム・DoF・ビネット・色の仕上げ・トーンマップ・FXAA を、エンジンが持つ効果の値の列にする。中身は今の Pass と `ShaderDoc` に展開する純粋な関数。新しい入力は足さない。
```flix
// View の隣（今の PostView.flix 98 行の代わり）
let post = PostStack.of(                                        // （新）
  PostStack.Effect.DepthOfField({ focus = hero, band = 0.2, blur = look#tiltBlur }) ::
  PostStack.Effect.Bloom({ threshold = 1.0, strength = 0.4, radius = 0.02 }) ::
  PostStack.Effect.Vignette(0.3) :: PostStack.Effect.Saturation(0.1) ::
  PostStack.Effect.Tonemap(PostProcess.Tonemap.AcesFitted, { exposure = -0.6, whitePoint = 4.0 }) ::
  PostStack.Effect.Fxaa :: Nil);
PostStack.plan({ scene = sceneItems, msaa = 4, size = size }, post)   // Render.PassPlan と最後の面を返す（新）
```
Doc は `post.kind.json`（効果の列と値）をエンジンが schema ごと持つ。
- エンジンで要る物: 効果 → Pass の列と Spec を作る関数・Doc の読みと schema・深度の pass を要る時だけ足す決まり・gl-parity の場面。
- 6 つの考え: 全部に合う。CPU は今と同じ扱い（`ShaderEval` で評価する近似）。効果ごとに新しい決まりは要らない。
- WebGPU: 触らない（`DrawList` の pass の区切りに今と同じ形で乗る）。
- 触る所: 今は「ゲームごとに約 100 行 + LookDoc」。案 1 ではエンジンの 1 か所（効果 → Spec）+ schema + 文書 + eval 1 題 + gl-parity 1 場面。GLSL・CPU・WGSL は 0（木から出る）。
- 危険: 語彙が足りないとゲームが結局手書きへ戻る（逃げ道として `Effect.Custom(Spec)`（新）を残す）。A1 は何も解けない。

### 案 2 — 間: 3D が名前つきの attachment を出し、効果は読む物を宣言して登録する
一言: 場面が「色のほかに何を出すか」を値で頼める。後の段はそれを名前で読む。効果は「読む物・書く物・式・CPU との合わせ方」の値として表に登録する。順と描き先はエンジンが決める。
```flix
// 場面: 要る attachment を頼む（Bevy の prepass の component と同じ考え）
let cmd = { outputs = Scene3d.Attachment.Depth :: Scene3d.Attachment.Normal :: Nil | Scene3d.scene(cam, size) };  // （新）
// 効果の登録（エンジンの中。ゲームは名前で選ぶだけ）
let ssao = { name = "ssao", reads = Input.SceneDepth :: Input.SceneNormal :: Nil,            // （新）
           writes = Target.scaled(0.5), kernel = Kernel.Field(ssaoSpec),                    // 式の木なら 3 出口は生成
           cpu = CpuParity.Approx };                                                        // Exact | Approx | GpuOnly（新）
// ゲーム
PostStack.Effect.AmbientOcclusion({ radius = 0.5, strength = 0.8 })                           // （新）
```
- エンジンで要る物: (a) 3D の描きに MRT（色 + 法線と roughness）と、深度を絵として読める形（WebGL2 も `drawBuffers` は標準） (b) `Field` に `ScreenUv`・`SceneDepth`・`SceneNormal`・`History(name)`（新）と、決まった回数の輪（taps）を持つノード (c) 材質の出口を `Out.Surface{ albedo, normal, roughness, emission }`（新）に広げる（水の波がここで書ける） (d) `resolvePassReads` を伸ばし、読まれない attachment と pass を作らない・同じ形の一時の描き先を使い回す (e) 途中の絵を名前で 1 枚描き出す口（今の `HeadlessRender.renderPassImage` を案内に載せる）。
- CPU との合わせ方（立場）: **効果ごとに 3 段を宣言させ、既定は Approx。** Exact = 0 px を gl-parity で守る（今のトーンマップ・光の式）。Approx = 同じ木を `ShaderEval` で評価し、差の上限を数で持つ（SSAO・ブルーム）。GpuOnly = CPU の絵には掛けず `SoftRaster.dropped` に報告する（TAA・モーションブラー。今の MSAA と同じ扱いで、docs/backend-parity.md の決まり 2 の延長）。`SoftRaster3d` は深度を持つ（`depthMapOf`）ので、法線を足せば Approx の相手になれる【推】。
- WebGPU: `DrawList` の「pass の区切り」の行に attachment の組を足す。pipeline の鍵に「描き先の形式の組」が入る。5.4 の「3D は自分のテクスチャへ描いて 2D に貼る」は、その絵を複数にするだけで済むので相性が良い。深度は `texture_depth_2d` で後の pass に bind する。
- 触る所: 式の木で書ける効果は「登録 1 つ + schema + gl-parity + 文書 + eval」。木で書けない物（影の PCF の類）だけ GLSL・WGSL・CPU の 3 つを手で書く。A4 の表で言うと、render_gl +237・SoftRaster +212 の型の仕事が、木に乗る分だけ消える。
- 危険: 材質の変種に「法線も書く」が掛かる（A5）。MRT で fill rate が上がる（スマホ 46.5 fps の基準を割らないか）。CPU の法線の絵を足す仕事。半透明は G-buffer に乗らない（順は今のまま forward）。

### 案 3 — 作り替え: 全部を render graph にし、式の木を 1 本にする
一言: 2D・3D・影・後がけを全部 node にして、`DrawList` の pass を graph から作る。`ShaderDoc.Field` と `LightModel3d` を型つきの 1 本の木（scalar・vec2・vec3）にまとめ、GLSL・WGSL・Flix の 3 出口を 1 つの生成器から出す。光は deferred か forward+ をエンジンが選ぶ。
```flix
let g = RenderGraph.of(                                              // （新）
  Node.shadow("sun", sun) :: Node.scene3d("scene", cmd) ::
  Node.effect("ssao", reads("scene.depth", "scene.normal")) ::
  Node.lighting("lit", reads("scene", "ssao", "sun")) :: Node.post("final", post) :: Nil);
```
- 6 つの考え: (1)(5) には一番きれいに合う。(2) が重い — deferred の G-buffer を CPU の描き手でも持つので `SoftRaster3d`（1,190 行）を書き直す。gl-parity の 0 px の門を全部通し直す。
- WebGPU: `DrawList` の前半（何を描くか決める所）を graph の実行に置き換える。今の移行（R1・R2 で「絵を 1 画素も変えない」）と同時にはできない。
- 触る所: 一番減る（効果 = node 1 つ・式は 1 本の木）。
- 危険: 大きい。2D のゲームに得が無い。スマホで deferred は重い【推】。graph を値で組ませると、順を人が覚える問題（A6）が形を変えて残る。

### 推す物
**案 1 → 案 2 の順。案 3 からは「式の木を型つきにして 1 本へ寄せる」だけを取る。**
- 案 1 は今日の重複（約 2,800 行）を消し、AI の書き味を一番変える。WebGPU の移行と並べて進められる（描き手を触らない）。
- 案 2 は A1 を解く唯一の道。ただし描き手に MRT を足すので、WebGPU の backend ができた後（P8 の後）に置く。`DrawList` の pass の行を決める時に、attachment を 1 枚と決め打ちしない事だけ先に守る。
- 式の木の 1 本化は、WGSL の出口を足す P5 が「`ShaderGen` に小さな書き手を挟む」と決めているので、その書き手に型（scalar・vec3）を持たせる所から始められる。

### 決める前に小さく試す事
1. **`PostStack` の語彙が足りるか。** lamplighter の `PostView.flix` を preset の値に置き換え、reference と 0 px 差になるか。同じ語彙で ome_city と fps3d_lab（一番長い 163 行）も書けるか。書けない所が `Custom` の要る範囲。
2. **法線の attachment 1 枚の値段と、SSAO が木で書けるか。** `bench/scene3d` の部屋で、GL に法線の出力を足して 1 コマの時間と変種の数を前後で比べる。`Field` に `ScreenUv`・`SceneDepth`・`SceneNormal` と 8〜16 taps の輪を足して SSAO を書き、`ShaderEval` との差が何 px か見る。木で書けなければ、案 2 の `kernel` は手書き 3 本が前提になる。
3. **`Field` の vec3。** `Rgb` の 3 回書きを vec3 のノードで書き直し、Spec の木の節の数・`eqSpec` の時間・生成した GLSL の行が減るか。`LightModel3d.Vec3Expr` を流用できるかも同時に見る。

## D. AI が表現力と性能を発揮できる形
### 条件と、今の位置
| 条件 | 今 | 根拠 |
|---|---|---|
| 選ぶ物が少なく意味がはっきりした部品 | **2D は効いている / 3D と後がけは無い** | lint-view と辞書の後、`vgrad`・`gradPolygon`・`PxShade` は 10〜12 フォルダへ広まった。後がけは部品が無く、9 本が同じ鎖を手書き |
| 見た目の名前から部品の組を引く辞書・preset | **あるが 2D だけ** | `reference.md` 17 行・`recipes.md` 4 例に、3D・post process・「夕方の海辺」のような組は無い。lamplighter の `look.kind.json` は夕暮れと夜の値を自前で持つ |
| 数値の妥当な範囲が schema にある | **仕組みはある / 中身はゲームごと** | sections 方言に `min`・`max`。露出やブルームの範囲はゲームが毎回決め直す |
| 間違えた組み合わせを型か lint が止める | **半分** | 閉じた型（`Material3d`・`Instance3d`）・`PassPlanIssue`・z の lint は効く。Doc の知らない `kind`・無い絵の名前・`Const` に動く値・色の空間は止まらない（A6） |
| 1 枚描いて自分で見て直せる速い周回 | **効いている** | `make render SHOT=`・常駐の描き出し・`RenderCache`・`/render-loop`。ただし GPU だけの物（MSAA）は CPU の絵に出ない |
| 途中の段の絵（深度・法線・光だけ・pass 1 枚） | **あるが案内が無い / 一部無い** | `HeadlessRender.renderPassImage` は pub だが、早見表と skill に字が無い（出るのは api-digest と migrations だけ）。深度は `Output.Depth`。法線・光だけの絵は無い |
| 見た目の出来を機械で言う口 | **一部** | lint-style（階調の段・格子）・lint-view・silhouette・render-lint。「主役が背景から分離しているか」「暗すぎる・白飛び」を数で言う口は無い。eval は道具の名前だけを見る |
| 遅い時に理由が出る | **効いている（2D・切れ目）/ 3D は荒い** | `batchBreaks`・`hitch.md`・`cpuPhases`。「場面を 3 回組んでいる」「Spec を毎コマ比べている」は出ない |
| 「この書き方は遅い」を止める lint | **一部** | lint-quadratic・lint-hoist・forbid の `sortBy`・check-render-budget。View の中で Spec を組む・全面の 64 taps・`instances` の `++` は止まらない |
| 手本 | **3D と後がけに無い** | テンプレ 4 本に Pass・Scene3d が 0。AI は前のゲームを写す |
| 使われない部品を知らせる | **効いた物と効かない物** | `unused-parts.md` 14 行のうち約半分は今も使用 0〜1（§3）。載せるだけでは足りず、lint-view の `destinations` のように「止まった所で代わりを示す」方が効いている【推】 |

### 案ごとの AI から見た書き味
- 案 1: 「ブルームを足す」が 1 行になり、値の範囲と preset（夕方・夜・曇り）を Doc から引ける。辞書に 3D と後がけの行を足せる。eval のお題も「道具の名前」で当てやすい。
- 案 2: 「すき間を暗く」「水面を波立たせる」が、頼む attachment と効果の名前で書ける。途中の絵を 1 枚ずつ描き出して自分で見られる。CPU に出ない効果は `dropped` で分かるので、描き出しの絵を信じてよい範囲がはっきりする。
- 案 3: 自由度は一番高いが、AI が graph の順を組む事になり、A6 の「順を覚える」負担が戻る。preset を上に被せない限り書き味は悪くなる【推】。

### 道具の側で足すと効く物（構造の案とは別に）
1. 辞書に「3D の場面の光と後がけ」の表（見た目の名前 → 光の色と強さ・空・かすみ・露出・ブルームの組）。今の `LookDoc` 9 本から値を集められる。
2. テンプレに 3D と Pass の手本を 1 本（今は ws のゲームが事実上の手本）。
3. 描き出した絵の明るさの分布（黒つぶれ・白飛びの割合・主役と背景の明るさの差）を数で出す口。5 性質の「分離」を機械で言える。
4. 知らない `kind`・無い絵の名前を、描き出しの時は知らせでなく止める（今も `warnOnce` を集めて止める口はある）。
5. `renderPassImage` を早見表と `/render-loop` に載せる。

## 確かめられなかった事
- Studio（flix_ge_studio）の側で何が触れるか。コードを読んでいない。表の Studio の欄は schema の有無からの推測【不明】。
- `LightModel3d` をゲームが差し替えられないと書いた所は、outline と survey C からの読み。`lightingModel` の呼び手は引いていない【推】。
- 環境マップのコミットの層ごとの内訳・ws の blood-scale（src が無く数えの外）・`plans/deferred/` の patch の中身。
- AI が実際につまずいた記録。`docs/agent-eval.md` には採点の誤りの記録しか無く、`agent-eval/history/` と `debug/agent-eval/` の答えは読んでいない。
- SoftRaster3d が法線の絵を安く出せるか・MRT のスマホでの値段。試作 2 で測る。
- §3 の数は字の一致（コメントの中の字も数える）。`refactor usages` の索引は engine の根だけなので、ゲーム 29 フォルダは字で数えた。
