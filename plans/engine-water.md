# 水と、水に要る汎用の部品（頂点を式で動かす・奥の不透明な面までの距離・半透明の深度・水のプリセット）— 計画（相談用・未着手）

状態: 計画（git に入れない）。engine は読んだだけで書き換えていない。engine の拡張なので、人の了承の後に段ごとに実装する。
書いた日: 2026-11-27。main 60b5b2241（シェーダーの 1 本化 S0〜S5・S7 は main に入り済み・L5 は未着手・W1 は計画だけ）。
前の版（水専用の API 43 個・レビュー 3 回）は scratchpad の `engine-water.v2-before-rewrite.md`、書き直しの 1 回目の版は `engine-water.v3-r1.md` に写して残した。
レビュー: 書き直しの 1 回目 72 点（必須 8・推奨 13・軽微 6）→ 2 回目 86 点（必須 2・推奨 7・軽微 3）→ この版で全部に手を入れた（末尾の「レビューへの答え」）。2 回目の版は scratchpad の `engine-water.v3-r2.md`。
**事実** はソースの引用（`bin/fge refactor` で引いた場所を書く）。**推測** は「推測:」と書く。時間は実時間。
重なる計画（二重に書かず指す）: `plans/engine-render-look-l5-l7.md`（「L 計画」）・`plans/engine-render-stage1.md`（「段 1 計画」）・`plans/engine-wasm-shader-prebake.md`（「W1 計画」）・`plans/engine-cell-sim.md`（セル物理）。

## 書き直しで変えた事（人の指摘: AI が 43 個の API を使い分けられるか・汎用に寄せる・低レイヤーは private に・デモに引っ張られすぎ）

| 前の版 | この版 |
|---|---|
| 水専用の API（`Waves3d` の 21 個・`WaterOptics`・`HeightfieldWater` の 9 個など） | **汎用の部品 3 つ**（頂点を式で動かす `VertexOffset`・Spec の葉 `SceneDepthDifference`・半透明の深度だけ先に描く `withDepthPrepass`）と、それを組んだ **水のプリセット 1 つ**（`Water3d.material`） |
| 格子の ring・浮力の反復・決まった sin・uniform に詰める値が pub | 全部 `*.Internal`。ゲームから呼ぶと forbid の `app-internal` が止める（`Scene3d`・`Water3d`・`ShaderGen` を pattern に足す） |
| カメラに付いてくる海の格子が中心の仕事 | **後ろの段 G4b**（要るゲームが出てから）。v1 の水はゲームの形（池・川・入り江の板）に付ける材質 |
| 波紋の式 `HeightfieldWater` を engine_world に | engine に置くのは「中身を差し替えられる動く Mesh」だけ（測って要る時だけ）。波紋の式はデモのゲームの側と docs の写経元に |
| 白波の葉・光学の record・浮力の pose の record | 落とした。浮力は `computeSurfaceHeight` 1 つ |
| bevy-aqua の機能の表から順を決めていた | このエンジンのゲームで繰り返し要る表現から順を決めた（2 節）。海の FFT・持ち越す泡は compute の後のまま |

**API の数: 43 → ゲームが見る 11 + 型 1（`Scene3d.SwayAnchor`）**（後ろの段 G4b の `Water3d.ocean` +1・条件つきの動く Mesh +2）。`windSway` は今のゲームに使う所が無い（2 節）ので、入れずに docs の例にする案も 18 節に並べた（その時は 10）。engine の層どうしが使う物は `*.Internal` に置き、ゲームの数に入れない。`Scene3d.materialFieldsOf` は pub なので内側の欄（`fresnelAlpha` など）はゲームから読めるが、書き換える API は出さない。

## 0. 結論

1. **ゲームが見る API は 11 + 型 1（`SwayAnchor`）**（13 節に「いつ使うか」を 1 行ずつ）。
   - 頂点を式で動かす: `Scene3d.VertexOffset`・`withVertexOffset`・`windSway`・`computeSurfaceHeight`・`ShaderDoc.Field.GerstnerWaves`。旗・草木の揺れ・浮き沈み・水面に効く。浮力は「CPU で同じ式を引く」の一例として `computeSurfaceHeight` 1 つ。
   - 奥の不透明な面までの距離: `ShaderDoc.Field.SceneDepthDifference`（Unity の Shader Graph の Scene Depth Difference と同じ量）。水の厚みの透け・岸の泡・柔らかい粒子（soft particles）・霧の板の端に効く。L5 の R32F の奥行きの絵を読む。
   - 半透明の深度: `Scene3d.withDepthPrepass`。水に限らず、半透明の物が手前の物に塗られる・自分に重なって透ける崩れに効く（Godot の `depth_prepass_alpha`）。
   - 水のプリセット: `Water3d.Settings`・`defaults`・`loadOr`・`material`（engine_world・Doc は `*.water.json`）。
2. **低レイヤーは Internal**（12 節）: 頂点の段の葉の決め・CPU の変位の評価と決まった sin・浮力の反復・uniform に詰める値・Spec を頂点の字にする所・深度を書くだけの半透明（`Always`）・海の格子（G4b）・水の Doc の `load`。
3. **順（推す）**: `L5 → W1 → リリース → G0〜G4 → リリース → L6 → L7 → リリース → 段 1 の残り`。G2b（変位した物の影）と G4b（海の格子）は後ろの段。L6・L7 と互いに依存しないので、案 2 の「L7 の後」でも中身は同じ（11 節・決め 1）。
4. **見積もり（実時間）**: G0〜G4 で 11.3〜16.3 時間・レビュー 1.5〜3 時間・デモ 2〜3 時間 = **14.8〜22.3 時間**。後ろの段は G2b 1.5〜2.5・G4b 2〜3・G5 1.3〜1.7。計画の物差しは G0〜G4 とデモで 55〜72 時間で、その 1/4〜1/5 に GPU の門の待ちを足した（10 節）。
5. **wasm**: W1 の後は字が表に増えるだけで、Flix の部品とプリセットで推測 +6〜12 KB（W2 の門 +3% ≈ 46 KB の内）。**重さ**: 水が画面の半分で PC の GPU +0.3〜0.6 ms・S24 +1〜2.5 ms（推測・frag の PBR と環境マップが主）。

## 1. 今の engine の事実（この計画で引いた所）

| 事実 | 根拠 |
|---|---|
| 置いた物の頂点シェーダーは手書きの字（`Render3dGlsl.MeshVertex`・`Render3dWgsl.MeshVertex`）。頭の WhyNot は「木の組み立てを足すと wasm の brotli の大きさが上限に届く」。上限は一本化の前の 1,432.8 KB から +6%、今 1,513.1 KB（残り約 5 KB） | `refactor outline render_gl/src/Render3dWgsl/MeshVertex.flix`・`docs/performance.md` 8 節 |
| ShaderAst に頂点の入口 `ShaderAst.Entry.vertexOrBug(lang, VertexEntry)` と入口の検査 `vertexPlacementErrors` がある | `refactor outline render_gl/src/ShaderAst/Entry.flix` |
| Spec の葉（`ShaderDoc.Field`）は 40 個。頂点の段の候補にした物の形: `Const`・`Param({ name })`・`Time({ scale, offset })`・`World({ axis })`・`Uv({ axis })`・`VertexColor({ chan })`・`Bin({ op, a, b })`（`Add`・`Sub`・`Mul`・`Min`・`Max`・`Step`・`Div`）・`Un({ op, of })`（`Neg`・`Abs`・`Fract`・`Floor`・`Sin`・`Cos`・`Sat`・`OneMinus`・`Sqrt`・`Log2` の 10 個。`Log2` は `Math.log` を使う）・`Smoothstep({ lo, hi, of })`・`Mix({ a, b, t })`。hash は `Hash1`・`Hash2` で、ShaderEval と ShaderGen は `fract(sin(…) * 43758.5453)`（`Fbm`・`Worley`・`Hash*` が使う）。`Pow` は `Math.pow`。ShaderDoc に組み立ての helper（`mul` など）は無い | `refactor show ShaderDoc.Field / BinOp / UnOp`・レビューで ShaderEval 967 行・ShaderGen 29 行を確かめ |
| 材質の frag は ShaderGen の字を `Render3dShaders.glslMaterialPart`・`wgslMaterialPart` で木に包む。`ShaderGen.Internal` は既にある | W1 計画 2.2・`refactor search ShaderGen.Internal` |
| `ProgramKind`（欄 9 つ）。`R3dUniform.Time` と `Scene3dCmd#time`（遊びの時計）は既にある | `ProgramKey.flix` 87 行・`Uniforms.flix` 119 行・`Scene3d.flix` 752 行 |
| WebGPU の材質の値の buffer と絵は `ShaderStage.FRAGMENT` だけで bind している | `render_gl/src/Render3d/WebGpuMaterials.flix` 275〜279 行（レビューで確かめ） |
| 影の地図は材質のプログラムを使わず、`Render3d.Shadow.shadowProgramFor(gl, state, skinned)` の骨つきか否かの 2 本で全部の物を描く。動かない物の影は `GlShadowCache`・`WebGpuShadowCache` が持ち越す | `refactor search shadowProgramFor`（Shadow.flix 268 行）・L 計画 1.1 |
| `Render3d.MaterialPass.Depth` は Output.Depth の奥行きの灰色を描き先に描く pass で、色を書かない深度だけの描き込みではない | `refactor search MaterialPass`（Render3d.flix 137 行）・レビュー |
| MultiMesh の draw は材質のプログラムを `ProgramKind` で引く（`MultiMeshPlan.Planned#material` に `ProgramKind`） | `refactor outline render_gl/src/Render3d/MultiMeshPlan.flix` |
| 材質は閉じた型 `Scene3d.Material3d`。描き手は欄を `Scene3d.materialFieldsOf`（pub）で読む | `Scene3d.flix` 232〜259・428 行 |
| PBR は Schlick の Fresnel（metallic 0 で F0 = 0.04）と環境マップの映り込み。半透明は `色 × α + 下 × (1 − α)` で、映り込みも α 倍される | `docs/scene3d.md` 340〜400・584〜600 行 |
| 半透明の物は不透明の後に `Scene3d.blendOrderOf`（目から遠い順）で描き、深度を書かず、物の中の三角形は並べ替えない。奥行きの場面（Output.Depth）に描かない | `refactor show Scene3d.blendOrderOf`（533 行）・`docs/scene3d.md` 592・594 行 |
| CPU の `placedOf` はモデル空間の頂点で、world は後で `instanceTris` が掛ける。`SoftRaster3d.flix` は 1,184 行（上限 1,200）・霧の塊は 219〜236 行 | `refactor outline engine_tools/src/SoftRaster3d.flix` |
| `Mesh3d` の鍵は SHA-256（`Mesh3d.digestOf`）。描き手は鍵で形を控え、`MeshTable.trim` で捨てる | `refactor show Mesh3d.digestOf` |
| forbid の `app-internal` の pattern に `Scene3d`・`ShaderGen` は入っていない（`Mesh3d` は入っている）。ゲームとテンプレートの src で `Scene3d.Internal` を書く所は無い（bench/gl_parity の ExprRows だけで、そこは skip） | `bin/lint-rules/forbid.json` 413 行・レビュー |
| Doc つきのプリセットは engine_world にあり、`DocJson.loadOr` で読む（`PostStack`・`PhysicsDoc2d`） | `refactor search DocJson.loadOr`（DocJson.flix 70 行） |
| L5 の奥行きの絵（`ps_depth_far`・R32F・値 × R = 目からの距離（場面の長さ））・`Scene3d.ScreenInputs`・group 0 の binding の一覧（L5-0b）・texture unit の数え（材質の frag 8 枚 + 絵 6）・材質の frag が `+ao` を受ける事（L 計画 9.1）は、まだ main に無い | L 計画 4.1・9.1・9.2・9.4 |
| W1 の `ShaderSourceKey.MaterialVertex(skinned, uv, lightmap, psx)` は template を持たない決まった鍵。材質の frag だけがプレースホルダーつきの template | W1 計画 3.1 |

## 2. このエンジンで繰り返し要る表現（順の根拠）

| 表現 | ゲームでの出方（調べた所） | 要る部品 |
|---|---|---|
| 揺れる物（草・旗・提灯・吊り物） | **今のゲームでは使う所が無い**（2026-11-27 に引いた: 町 `lamplighter`・校舎 `night_school`・箱庭 `stack_town` で `refactor search sway / wave / grass / flag / swing` は、HUD の手元の揺れ（`night_school` の `FlashlightView.offsetOf`・`LookDoc.Flashlight`、`lamplighter` の `HudView.Bob`）と、鎌の振りの音のテストだけ。3D の物を揺らす所は 0 件）。engine_world に 2D の揺れ `Sway.wave`（sin）はあるが engine の中でも呼び手は `Sway.drift` だけ | VertexOffset（`windSway` は需要が出るまで docs の例でもよい・18 節） |
| 浮き沈み（物ごと） | `lamplighter` の釣りのウキは `View.floatOf` が毎コマ `Num.sin(now × 2.7)` で位置を上下させる（物ごと動かすので今の行列で足りる・頂点を動かす部品は要らない）。水面の波に合わせるなら `computeSurfaceHeight` が要る | computeSurfaceHeight |
| 半透明の物の重なり（ガラス・水・霧の板・煙の板） | `docs/scene3d.md` の半透明の節が「入り組んだ半透明は物を分けて置く」と回避を書いている | withDepthPrepass |
| 水面（池・入り江・水たまり） | `sea_cave_walk` は Spec で空の映り込みと波紋の傾きを手で組み、形を CPU で作り直している（`SeaMaterial`）。`lamplighter`（釣り）・`bench/hd2d_town`（`TownMap.Ground.Water`）・2D の `tidepool-starter`（水位） | VertexOffset・SceneDepthDifference・withDepthPrepass・プリセット |
| 物の端を柔らかく（粒子の板が床に刺さる線・霧の板の端・水際） | 粒子と霧の板を置く 3D のゲームで毎回出る（推測） | SceneDepthDifference |
| 触ると揺れる水 | 2D の液体はセル物理（cinder_lab）が持つ。3D はまだ無い | 動く Mesh（条件つき） |
| カメラに付いてくる海 | 今のゲームで要った所は無い（sea_cave_walk も入り江の板） | G4b（要るゲームが出てから） |
| 外洋の大きな波・持ち越す泡・流体の粒 | 今のゲームに無い | compute の後（14 節） |

→ 調べた事実で一番強い根拠は水面（`sea_cave_walk` の毎コマの形の作り直し）と半透明の重なり。揺れる物は今のゲームに無いので、VertexOffset の値打ちは「水面で使い、同じ部品で揺れにも効く」に置く。順は「多くの表現に効く部品から」: withDepthPrepass と VertexOffset → SceneDepthDifference → それを組む水のプリセット → 変位した物の影・海の格子・動く Mesh は後ろ。

## 3. 部品 1: 頂点を式で動かす（`VertexOffset`）

### 3.1 形

```flix
// 草・旗・吊り物の揺れ（よく使う形のプリセット）
let grass = Scene3d.material(grassSpec)
    |> Scene3d.withVertexOffset(Some(Scene3d.windSway({ amplitude = 0.06, frequency = 1.5, direction = 30.0, anchor = Scene3d.SwayAnchor.VertexColor(TexChan.R) })));
// 自分で式を書く時（Spec の木。sea_cave_walk の SeaMaterial のように、ゲームが小さな組み立ての helper を持つ）
let bob = Scene3d.withVertexOffset(Some({ x = Field.Const(0.0), z = Field.Const(0.0),
            y = Field.Bin({ op = BinOp.Mul, a = Field.Const(0.03),
                            b = Field.Un({ op = UnOp.Sin, of = Field.Time({ scale = 2.0, offset = Field.World({ axis = Axis3.X }) }) }) }),
            reach = 0.03, recomputeNormal = false }), lanternMaterial);
// 浮く物を水面に乗せる（置いた水の物と同じ式を CPU で引く・絶対の高さ）
let y = Scene3d.computeSurfaceHeight(waterInstance, t, x, z);
```

- `Scene3d.VertexOffset = { x: Field, y: Field, z: Field, reach: Float64, recomputeNormal: Bool }`。x・y・z は **world の向きの変位（場面の長さ）**。
- **頂点の段で読める葉（許す一覧）**: `Const`・`Param`・`Time`・`World`・`Uv`・`VertexColor`・`Bin`（全部の op）・`Un`（**`Log2` を除く** 9 個。`Sin`・`Cos` は CPU で決まった近似）・`Smoothstep`・`Mix`・`GerstnerWaves`。**これ以外の葉は全部読めない**。読めない葉を含む変位は、`withVertexOffset` が変位を外して知らせる（fail-open・知らせは材質の鍵ごとに初回 1 回だけ。材質を毎コマ作るゲームで毎コマ出さない）。
  - 外した理由: `Hash1`・`Hash2`・`Fbm`・`FbmTile`・`Worley`・`Ripples`・`Glints`・`Sparkle` は sin の hash か `Num.sin` を使い、JVM と wasm・GPU の float32 と CPU の Float64 で値が分かれる（浮力とテープの決定性が崩れ、GPU の頂点とも合わない）。`Pow` は `Math.pow`、`Un` の `Log2` は `Math.log` で同じ（JVM と JS で最後の bit が合わない。頂点の変位に対数が要る使い方も今は無いので、決まった近似を書かずに外す）。`Tex`・`TexBlur`・`TexSize`・`Sampler`・`Shift`・`Ref` は頂点の段に絵と名前の bindings を持ち込むことになる。`Normal`・`Scaled`・`Warp`・`Tiling`・`Blend`・`Quantize`・`Disk`・`Radial`・`RadialAspect`・`Scales`・`Snap`・`Swirl`・`Angle`・`Rotate` は面の uv の画素の模様の葉で、頂点の変位に要る使い方が今は無い（要るゲームが出たら決定性を見て許す一覧に足す）。
  - 頂点の段の `World` は**動かす前**の world の位置、`Uv`・`VertexColor` はその頂点の値。
- `reach` = 変位の長さの上限（場面の長さ）。境界の箱を上下・横にこれだけ広げる（frustum・半透明の並びの真ん中・staticGroup と MultiMesh の境界）。`GerstnerWaves` だけの時は engine が Σ Aᵢ と Σ Qᵢ Aᵢ から求めて小さい方を使う。
- `recomputeNormal`（真で法線とタンジェントを作り直す）:
  - `GerstnerWaves` だけの変位は、微分の式で作る（前の版の 4.2・安く正確）。
  - それ以外は、頂点の法線に垂直な 2 つの向き t₁・t₂（法線から組む・形のタンジェントは要らない）へ ε（1 cm）だけ動かした点でも変位を引き、`cross(ε t₁ + Δ₁, ε t₂ + Δ₂)` で作る。この時 `World` だけを動かし、`Uv`・`VertexColor` は頂点の値のまま（形にタンジェントが無くても求まる）。だから**傾きは `World` で書いた揺れにだけ出る**。uv だけで書いた変位は法線が変わらない、と docs に書く（`windSway` は `World` で位相を、uv で根元の止まりを書くので傾く）。
- `Scene3d.windSway({ amplitude, frequency, direction, anchor })`: 揺れの `VertexOffset` を返す（許す一覧の葉だけで組む・`World` の位置で位相をずらし、揺れの大きさを `anchor` の重みで掛ける・`recomputeNormal = true`）。AI が `Field.Bin` を何段も手で組まずに済むように 1 つ置く（Unity の wind zone・Godot の草のシェーダーの例と同じ考え）。
  - `Scene3d.SwayAnchor = UvV0 | UvV1 | VertexColor(TexChan)`: 揺れの重みの元。`UvV0` は uv の v が 0 の所を止めて 1 の所を一番揺らす・`UvV1` はその逆・`VertexColor(c)` は頂点の色のその channel を重み（0 で止まる・1 で一番揺れる）にする。草木の揺れの重みを頂点の色に塗るのは Unity・Godot・Unreal の foliage で普通の作り方。
  - **形の下の端（モデル空間の y）で止める案は採らない**: 許す葉ではモデル空間の位置も形の原点も読めず（`World` は world の位置）、MultiMesh の草は 1 本ずつ原点が違うので world の y でも決められない。モデル空間の位置を読む頂点の段だけの葉を足す案は、葉と CPU の評価器と 11 ファイルの直しが 1 つずつ増える割に、uv と頂点の色で同じ事ができるので外した（案 b）。
  - **v の向き**: glTF は v = 0 が絵の上の端。旗を絵の左を根元・上を v = 0 で描いた形なら、根元が uv の u = 0 で、`UvV0`・`UvV1` では止められない（その時は `VertexColor` で重みを塗る）。docs に絵で 1 枚。
- **波の形の葉** `ShaderDoc.Field.GerstnerWaves({ waves: List[{ direction, wavelength, amplitude, steepness, speed }], axis: Axis3 })`: Gerstner の波の和の、指定した向きの成分（場面の長さ）。式は前の版の 4.2（Qᵢ = steepness / (kᵢ Aᵢ N) で面が裏返らない・本数の上限 8）。`speed` を省くと深い水の分散の式 √(g / k) を 1 単位 = 1 m として使う（`unitsPerMeter` が 1 でない場面は `Water3d` が直した speed を入れる・6.1）。
  - 1 つの材質の中の `GerstnerWaves` の葉は全部同じ波の並び（x・y・z の 3 つ）。違う並びが混ざったら変位を外して知らせる（位相の uniform を 1 組にするため・3.2）。
  - **frag の Spec では読めない葉**とする（Gerstner は動かす前の点で決まる式で、動いた後の画素の world で引き直すとずれ、画素ごとに 8 本ぶん重い）。frag で読んだら 0 で読んで知らせる。
- 位相の時刻は `Scene3dCmd#time`（`Time` の葉と同じ時計）。

### 3.2 GPU: 頂点の字と値の置き場

- W1 の後に、**変位のある材質の頂点だけ ShaderAst の木で書く**（前の版の決め 2 の案 A）。波の無い材質は今の手書きの字のまま、既定の字は変わらない。varying の表は手書きの版と共有し、ずれは `TestShaderDump` の照らしに版を足して止める。
- 変位の式は `ShaderGen.Internal.compileVertexOffset`（GLSL と WGSL）が頂点の字に書き出し、`Body.Text` の関数 1 つに包む。
- **W1 の鍵**: 新しく `ShaderSourceKey.MaterialVertexTemplate(skinned = false, uv, psx)` を足す（今の `MaterialVertex` は template を持たない決まった鍵なので）。プレースホルダーは 2 つ: (1) 変位の式が読む uniform・値の宣言、(2) 変位の関数。`+vo` は**頂点の鍵**、部品 2 の `+db` は**frag の鍵**（材質の frag の template）で、別々に入る。記録の `materialShapes` に `"vertexOffset"`・`"sceneDepth"` の 2 つの欄（無い欄は偽で読む）。
- `ProgramKind` に `vertexOffset = Bool`（`+vo`）と `sceneDepth = Bool`（`+db`）を**部品 1 で 2 つとも足す**（`ProgramKind` を全部の欄で書いたテスト約 42 か所を 1 回で直す）。字の控えの鍵: 変位の木は `shaderHash` と同じく `withShaderKeys` で鍵に入れる。
- **値の置き場**:
  - GL: `Param` と `Time` は今の材質の uniform をそのまま頂点からも読む（プログラムの uniform は段を問わない）。波の位相は新しい `R3dUniform.WavePhases`（vec4 × 2 = 8 本分・`UniformSlot` に 1 行）。
  - WebGPU: `+vo` の pipeline だけ、材質の値の buffer の bind の visibility を `VERTEX | FRAGMENT` にする（layout が変わるので、pipeline と bind group layout の鍵に `+vo` を入れる）。波の位相は材質の値の buffer の末尾に 32 バイト。256 バイトの境を越えるかと、越えたら置いた物の値へ置くかを G0 で決める。
  - 位相は CPU（`Scene3d.Internal.VertexOffsets.wavePhasesOf`）が Float64 で求めて 2π で折り返す（長く遊んでも float32 で崩れない）。
- 頂点の順: `world = model × local` の後に world で変位を足し、psx なら最後に今の `Render3dShaders.vertexSnap`。骨つき・lightmap とは組み合わせない（切って知らせる）。
- **MultiMesh**: MultiMesh の draw は材質のプログラムを `ProgramKind` で引くので、`+vo` の材質ならそのまま変位を受ける（GL の instancing の行・WebGPU の頂点の道は今の材質の頂点と同じ入力）。G0 で草 1,000 本の MultiMesh を描いて確かめ、通らなければ v1 は MultiMesh で変位を切って知らせ、2 節の「草」を根拠から外す。1 本ごとの揺れのずれは `World`（その 1 本の world の位置）で出る。
- **ビルボード**: 自分の頂点を持つので、変位は受けない（付けても無視・docs に 1 行）。
- **影**: G2 では、変位のある物も影の地図には**動かす前の形**で描く（影の pass は材質のプログラムを使わないので）。半透明の物は今どおり影も奥行きも描かない。揺れる草と旗の影を動かすのは G2b（3.5）。
- **奥行きの場面（Output.Depth・L5 の `ps_depth_far`）**: 不透明の物の奥行きの pass は材質のプログラムを使うので、変位もそのまま入る（色と奥行きの形がずれない）。

### 3.3 CPU: 同じ式で描く・同じ式を引く

- **描き出し**: `placedOf` はモデル空間なので、`instanceTris` が world を掛けた後の頂点に変位を足す（画面の pass だけ・影の地図の pass は G2 では元の頂点＝GPU と同じ絵）。式の評価は `Scene3d.Internal.VertexOffsets` の小さな評価器（許す一覧の葉だけ・Spec を 1 回組んで材質の値ごとに Lazy で控える）。
  - **CPU の Spec の評価器が 3 つ目になる件**（`ShaderEval`・`LightModel3d` の CPU の式に次ぐ）: `ShaderEval` を使い回す案は、`ShaderEval` の sin を決まった近似に替えると材質の frag の CPU の絵（gallery の SHA）が全部動き、替えなければ決定性が崩れるので採らない。代わりに**許す一覧の全部の葉と op について、新しい評価器と `ShaderEval` を同じ入力で照らすテスト**を置く（三角関数を使わない op は bit まで一致・`Sin`・`Cos` は 1e-12 以内）。葉を許す一覧に足す時は、このテストに行を足さないと通らない形にする。
- **`SoftRaster3d.flix` は上限まで 16 行**: 先に霧の塊（219〜236 行・約 18 行）を `SoftRaster3d/Fog.flix` へ出し（絵は変わらない）、変位は新しい `SoftRaster3d/VertexOffsets.flix` に置く。本体は `instanceTris` を呼ぶ所を `VertexOffsets.trisOf` に替える数行だけ。
- **決まった sin**: 頂点の変位の評価（描き出しと `computeSurfaceHeight`）の sin・cos は、決まった多項式の近似（2π で折り返し・Float64 の四則だけ）。許す一覧の葉は全部 Float64 の四則と sqrt（IEEE で bit まで同じ）と決まった近似で求まるので、**JVM とブラウザで bit まで同じ**（PC で録ったテープをブラウザで再生しても浮く物がずれない）。GPU の float32 との差は、**滑らかな op（四則・`Sin`・`Cos`・`Sqrt`・`Smoothstep`・`Mix`）と `GerstnerWaves` だけで書いた変位**なら 1 mm 以内に収まる（hash の葉を外した理由）。`Fract`・`Floor`・`Step`（と `Min`・`Max`・`Abs`・`Sat` の折れ目）は、境目のちょうど上の頂点で GPU と CPU が別の側に落ちうるので、その頂点だけ段の大きさだけずれる。`Time` の葉は GPU で float32 の時刻なので、数時間遊ぶと 1 mm を超えうる（`GerstnerWaves` は位相を CPU で 2π に折り返して渡すので崩れない）。どちらも docs に書き、1 mm のテストは滑らかな式と `GerstnerWaves` で取る。材質の frag の CPU の色の式は今のまま（gallery の SHA を動かさない）。
- **`computeSurfaceHeight(instance, time, x, z)`**: 置いた物 `instance` の材質の変位を引き、その XZ の**絶対の高さ**（置いた物の world の原点の y + 変位の y）を返す。水平な面の材質を前提にする（形の高さの凹凸は足さない・docs）。変位が横にも動く時（Gerstner）は、元の点を反復で求める（XZ のずれが 0.5 mm を下回るか 16 回で止める・steepness 0.6 で約 12 回）。変位の無い材質なら world の原点の y。角度は返さない（atan が要り、JVM と wasm で bit が違いうる。向きは `recomputeNormal` と同じ式の法線から作る例を docs に）。名前の `compute*` は毎回解く値段を表す。
- 力の計算（3D の剛体）は入れない。

### 3.4 gl-parity と門

- 場面 `vertexOffset3d`（旗 1 枚・草の MultiMesh 少し・波の板 1 枚・決まった時刻）。上限は L 計画 3.4 の (a)（`diffPx` × 1.5・差の出うる画素を結果と独立に数えるテスト）。`ExprRows` に行 2 つ（決まった点の変位と、作り直した法線）。
- 既定の字が変わらない事（`TestRender3dGlslPinned`・`TestShaderDump` の今の行の SHA）。`TestWgslDawn`・`TestGlslEsKeywords` に `+vo` の版。
- テスト: 変位 0 の時に形が同じ／許す一覧の外の葉で外して知らせる（初回 1 回）／`GerstnerWaves` を frag で読むと 0 で知らせる／`computeSurfaceHeight` が描いた頂点の高さと 1 mm 以内／決まった sin が決まった表と bit まで一致／`reach` の分だけ境界の箱が広がる／変位の木が字の鍵に入る／違う波の並びの混ざりで外す。

### 3.5 後ろの段 G2b: 変位した物の影

- 影の pass は今 2 本のプログラム（骨つきか否か）で全部を描く。変位は Spec ごとに式が違うので、`+vo` の材質ごとの影のプログラム（日・spot・点光源の atlas の 3 つ）を作る道が要る。字は 3.2 の頂点の template に影の frag をつないだ物。
- 変位のある物は毎コマ形が変わるので、影の控え（`GlShadowCache`・`WebGpuShadowCache`）が持ち越す「動かない物」から外す（控えの鍵 `ShadowMaps.cacheKeyOf` の入力で除く）。
- CPU も影の地図の pass に変位を足す（`depthMapOf` の手前）。
- 見積もり 1.5〜2.5 時間。G4 の後、揺れる草と旗を置くゲームが出た時か、デモで影の止まりが目立った時に。

## 4. 部品 2: 奥の不透明な面までの距離（`ShaderDoc.Field.SceneDepthDifference`）

### 4.1 形

```flix
// 柔らかい粒子: 床に刺さる所を薄くする
alpha = Field.Bin({ op = BinOp.Mul, a = base,
          b = Field.Smoothstep({ lo = 0.0, hi = 0.3, of = Field.SceneDepthDifference({ vertical = false }) }) })
```

- `Field.SceneDepthDifference({ vertical: Bool })` = この画素から、その奥の**不透明な面**までの距離（場面の長さ）。`vertical = true` なら縦の深さ（距離 × 目の向きの y の大きさ・水際の泡の帯がカメラで太らない）。名前は Unity の Shader Graph の Scene Depth Difference（Unreal の DepthFade の元になる差と同じ量）。
- 値の元: L5 の奥行きの絵（値 × R = 目から底までの距離）と、画素の目からの距離の差。半透明の物は奥行きの場面に描かれないので、奥の値はそのまま不透明な面。
- 読めない所の値は 1000（奥に何も無い扱い）: 2D の Spec・後がけ・奥行きの絵の無い場面（PostStack を使わない・2 つ目からの場面・WebGL2 で R32F の描き先が無い）。WebGL2 の知らせは L 計画の `@screen-effects-no-float-target`。PostStack の無い場面で `Water3d.material` を使うと黙って不透明な水になるので、その時は描き手が 1 回知らせる（「水の透けと岸の泡には PostStack が要る」）。
- 頂点の段では読めない（3.1 の許す一覧の外）。
- **奥行きの絵を描く条件**: PostStack は「一番大きい場面の材質のどれかが `SceneDepthDifference` を読む」時に奥行きの絵を描く（L 計画の AO・霧の条件に 1 つ足す）。読むかどうかは材質ごとに Lazy で 1 回求める（`texReads` と同じ形）。staticGroup の中は群れを作る時に 1 回。

### 4.2 鍵・binding・texture unit・AO・CPU

- **字の鍵**: この葉の字は奥行きの絵を読めるか（`+db`）で変わる（読めない時は定数）。`ShaderGen.compile3d`・`ShaderGen.Wgsl.compile3d` に旗を渡し、材質の字の控えの鍵（`ShaderGen.Internal.SpecKey`）と W1 の材質の frag の template の鍵の両方に入れる。旗が鍵に入る事をテスト 1 本で止める。
- 葉を足すと直す所: `ShaderJson`・`SpecKey`・`PostProcess`・`ShaderGen`・`ShaderGen.Wgsl`・`ShaderEval`・`TestShaderGenFieldKinds.allKinds`・gl_parity の `WgslRows.kinds`（`Field.Time` の usages で 26 か所・11 ファイル）。`GerstnerWaves` も同じ所を G2 で直す。
- binding: L5-0b の group 0 の一覧に「場面の奥行き」の行（`+db` の時だけ）。
- **AO と奥行きの絵に入らない物**: 半透明の物は（深度だけ先に描く物も）奥行きの絵に入らないので、AO の mask はその奥の不透明な面の値になる。だから **半透明の材質は全部 `+ao` を受けない**（受けると水面に海底の AO が、ガラスに奥の壁の隅の AO が塗られる）。L 計画 9.1 の「材質の frag は受ける」に「半透明の材質（`withAlphaBlend`）は受けない」の 1 行を足す。`SceneDepthDifference` は奥の不透明な面までの距離なので、意味を持つのは半透明の材質だけ（不透明の材質で読むと自分が奥行きの絵に入っていて 0 になる・docs に 1 行）。
- **texture unit**（L 計画 9.4 の数え）: 材質の frag は今 8 枚 + 材質の絵 6 = 14。`+ao` は不透明だけ・`+db` は半透明だけなので、2 つは同じ材質に立たない。最悪の組は 2 つ:
  - 不透明: 14 + `+ao` 1 + `+vf` 1 + `+cl` 2 = 18（L 計画 9.4 の数えのまま）。
  - 半透明: 14 + `+db` 1 + `+vf` 1 + `+cl` 2 = 18。
  外す順: 1. `+ao` を外す（不透明の組は 17）→ 2. 材質の絵を後ろから 1 枚ずつ、16 に収まるまで外す（不透明は 1 枚・半透明は 2 枚。今の「0 で読んで材質ごとに 1 回知らせる」道）→ 3. それでも超える組は変種を組む時に `bug!` で止める（全部の組を回すテストで、2 手の後に 16 を超える組が出ない事を保つ）。`+db`・`+vf`・`+cl` は外さない。
  - 9.4 は L5 で実装される（L5-0 で数え、組が無ければテストだけ）。G3 では L 計画の文と、L5 で書いた外す順のコードとテストの両方を直す（G3 の見積もりに入れた）。
- **CPU**: `ScreenInputs#depth` のある場面だけ、L5 で CPU が描く奥行きの絵（`PassImage.R32Float`）を読む。GPU と同じ値の元にし、`blendRow` の NDC の z は使わない。
- gl-parity: 場面 `sceneDepth3d`（床に刺さる板と、坂の岸の水の板・PostStack で奥行きを描く）。差の出うる画素は「距離が smoothstep の幅の内の画素」として結果と独立に数える。

## 5. 部品 3: 半透明の深度を先に描く（`Scene3d.withDepthPrepass`）

半透明の物は奥から手前へ物ごとに並べるが、(1) 真ん中が近い大きな物（水の板・霧の板）が最後に描かれて手前のガラスの上に塗られ、(2) 物の中の三角形は並べ替えないので、波の山の上に奥の谷が透けて重なる。深度を書くだけでは (2) は半分しか消えない（同じ draw の中は index の順に描かれ、奥の三角形が先だと手前の山がその上に blend で重なる）。

- `Scene3d.withDepthPrepass(Bool, Material3d)`: 真なら、その半透明の物は**先に深度だけを描き**、次の色の draw は深度を書かず比べるだけ。三角形の順に依らず (2) が消える。名前は Godot の `depth_prepass_alpha`。不透明の材質に付けても無視する（docs に 1 行）。
- 深度を先に描く半透明の物は、`blendOrderOf` の前に別の組にして**手前から奥へ**描き、その後にほかの半透明を今どおり奥から手前へ。後に描くガラスは水の深度で前後が決まる（(1) が消える）。水の下の半透明の物は隠れる（docs・水の下に見せたい物は不透明か cutout で）。
- **深度だけの pass は新しく足す**: `Render3d.MaterialPass.DepthPrepass`（色の書き込みを止める・WebGPU は color の writeMask 0・GL は `glColorMask` を切る・深度は書く）。今の `MaterialPass.Depth`（Output.Depth の灰色を描く pass）とは別物。
- 色の draw の深度の比べは **LEQUAL**（EQUAL は 2 回の draw で位置の最後の bit がずれると穴になる）。2 回の draw で位置が bit まで同じになるよう、頂点の位置の出口に GLSL の `invariant gl_Position`・WGSL の `@invariant` を付ける（変位の式も同じ字を両方の pass で使う）。
- `depthPrepass` は描き手の pipeline の鍵（深度の書き込みと比べ方・色の writeMask）・staticGroup の束ねる鍵・`DrawHash` に入れる。
- **深度を書くだけの形（Godot の `depth_draw_always`）は Internal**: draw 1 回で済むが、index の順が手前から奥でないと (2) が残る。index を真ん中から外へ並べられる engine の海の格子（G4b）だけが使う（`Scene3d.Internal` の欄・ゲームの API にはしない。池に付ける選び違いを無くす）。
- CPU: 先に深度だけを書いてから色を重ねる。並べ方と深度だけの描き込みは `SoftRaster3d/VertexOffsets.flix` の隣の子のモジュールに置き、本体は呼ぶ 1 行。
- gl-parity: `vertexOffset3d` の波の板を斜めから・手前にガラス 1 枚で見る。

## 6. 水のプリセット（`Water3d`・engine_world）

### 6.1 形

```flix
let water = Water3d.loadOr("assets/cove.water.json")          // 無ければ Water3d.defaults()
let pond = Scene3d.meshInstance(pondMesh, at) |> Scene3d.withMaterial(Water3d.material(water));
{ instances = pond :: others, time = t, environmentMap = Some(env) | base }   // PostStack で奥行きを描く場面に置く
let y = Scene3d.computeSurfaceHeight(pond, t, x, z)                            // 浮く物
```

- 置き場は engine_world（Doc つきのプリセットは `PostStack`・`PhysicsDoc2d` と同じ層で `DocJson.loadOr` を使う。engine の層は部品だけにする「層を置く物差し」）。
- `Water3d.Settings`（record・Doc と同じ欄）: `waves`（`GerstnerWaves` の波の並び）・`shallowColor`・`deepColor`・`absorption`（色ごとの 1 m あたりの吸収）・`foamWidth`（m）・`foamColor`・`roughness`・`unitsPerMeter`（場面の `Scene3dCmd#unitsPerMeter` と同じ値）。
  - record にした理由: Doc（`*.water.json`）の欄と 1 対 1 で、ゲームは Doc で調整するのが主。欄を足した時に全部の欄を書いた record が壊れないよう、**コードでは `{ roughness = 0.1 | Water3d.defaults() }` の形で書く**決まりを docs と早見表に書く。
  - 水面の高さは持たない（置いた物の位置で決まる。`computeSurfaceHeight` は置いた物から絶対の高さを返す）。
- `Water3d.material(s)` が組む物（全部ここまでの部品か今ある API）:
  - Spec: 色 = `shallowColor` と `deepColor` を透け T = exp(−absorption × `SceneDepthDifference` / unitsPerMeter) で混ぜる・α = 1 − T の平均・岸の泡 = `Smoothstep(foamWidth, 0, SceneDepthDifference({ vertical = true }) / unitsPerMeter)` × 泡の模様（`Fbm` と `Time`・frag の葉なので決定性の問題は無い）。白波は v1 では持たない（frag で波の高さを読まない決まり・3.1）。
  - `withVertexOffset`（`GerstnerWaves` の x・y・z・`recomputeNormal = true`・speed は `unitsPerMeter` で直した値）・`withMetallicRoughness(0, roughness)`・`withAlphaBlend(true)`・`withDepthPrepass(true)`。
  - **α の Fresnel**: 浅い角度の映り込みが α で薄くならないよう、α を光の前で `α' = α + (1 − α) F` にする（F = Schlick・F0 は光の式と同じ 0.04。WhyNot: 水の本当の値 0.02 にすると α の立ち上がりと映り込みが別の F0 で動き、角度で明るさの継ぎ目が出る）。材質の内側の欄 `fresnelAlpha` を `Scene3d.Internal` の API で立てる（ゲームの API にはしない）。
- 長さ: `GerstnerWaves`・`SceneDepthDifference` は場面の長さ、`Water3d.Settings` は m。直すのは `Water3d.material` の中の 1 か所（材質に `unitsPerMeter` の欄は持たない）。場面の `unitsPerMeter` と違えば、描き手が場面ごとに 1 回知らせる。
- Doc: `docs/water.schema.json`・`Water3d.loadOr`（中は `Water3d.Internal.Doc.load` が `Result` を返し、`loadOr` が既定値で続けて 1 行言う・`docs/error-handling.md`）。Studio は凍結中なので schema だけ。
- 遠くの水の格子の細かさはゲームの形で決まる（psx の粗い水は粗い板で作る）。泡の模様は `World` で読む（`Uv` で読むと形ごとに泡の大きさが変わる）。

### 6.2 後ろの段 G4b: カメラに付いてくる海

- 要るゲームが出てから（2 節）。形は**目印の付いた置いた物を後で広げる形をとらない**（`scene#instances` を読む所が描き手の外にも 13 か所以上あり、広げる前の目印が漏れるため）。代わりに `Water3d.ocean(water, eye): List[Instance3d]` が**普通の置いた物**を返す。
- 格子（Internal・`Scene3d.Internal.Water`）: 内側 32 m 四方を 0.25 m・外へ 4 つのレベル、レベルごとに間隔と大きさ 2 倍・外の端の先は地平まで波なしの板。形は格子の設定を鍵にした控え（Internal の memo）から引き、毎コマ変わるのは置く行列だけ。置く位置は全部のレベルを一番外のレベルの間隔の 2 倍の倍数に丸める。継ぎ目は内側の外の端の点を外側の 2 点の真ん中へ寄せる。index は真ん中から外へ並べ、深度を書くだけの形（Internal の `Always`）で draw 1 回にする。遠くで短い波を弱める係数 `1 − smoothstep(fadeStart, fadeEnd, d / λ)`。`Water3d.Settings` に格子の細かさ `oceanSpacing` を足す。
- 見積もり 2〜3 時間・API +1。

## 7. 条件つき: 中身を差し替えられる動く Mesh（G5）

- 触ると揺れる池（浅い水の式の格子）は、毎コマ `Mesh3d` を作り直せば今でも描ける。代金は SHA-256 の鍵（65 × 65 の頂点で約 0.3 MB・推測 JVM 0.5〜1 ms・wasm 5〜15 ms）と、毎コマ buffer を作っては捨てる事。
- W-d0 で 64² と 128² を測り、PC 1 ms・ブラウザ CPU 4 倍で 4 ms・たまる形が `trim` の上限の半分、のどれかを超えたら足す:
  - `Mesh3d.makeDynamic(arrays): Mesh3d \ IO` — 番号は engine が振る（呼ぶ側に名前を付けさせず、取り違えで別の池の中身が混ざるのを止める）。
  - `Mesh3d.withVertices(positions, normals, m)` — 番号は同じで版を 1 増やした新しい値。描き手は番号で同じ buffer を使い回し、版が変わった時だけ写す（Godot の ImmediateMesh・Unity の `Mesh.SetVertices` と同じ考え）。
- 波紋の式（高さと縦の速さの格子・減衰つきの波の式・c·dt / 升 ≤ 0.5）は engine に入れない。デモのゲームの側に書き、`docs/scene3d.md` に写経元として載せる。2 本目のゲームが要った時に engine_world へ上げるかを相談する。
- render_gl を触るので W1 の後。

## 8. 触るファイル（まとめ）

- engine: `Scene3d.flix`（`MaterialFields` の欄 `vertexOffset`・`depthPrepass`・`fresnelAlpha`・`VertexOffset`・`SwayAnchor`・`withVertexOffset`・`windSway`・`withDepthPrepass`・`computeSurfaceHeight`・境界の箱・`blendOrderOf` の 2 組）・新しい `Scene3d/Internal/VertexOffsets.flix`（許す一覧の評価器・決まった sin・反復・`reach`・位相）・`ShaderDoc.flix`（葉 2 つ）・`ShaderGen`・`ShaderGen.Wgsl`（旗）・新しい `ShaderGen/Internal/VertexOffset.flix`・`ShaderEval`・`ShaderJson`・`SpecKey`・`PostProcess`・engine_full の symlink。
- engine_world: 新しい `Water3d.flix`・`Water3d/Internal/Doc.flix`・`PostStack/Internal/Passes.flix`（奥行きを描く条件）。
- render_gl: `Render3dShaders.flix`（変位の頂点の木・α の 1 行）・`ProgramKey.flix`（2 欄）・`Uniforms.flix`（`WavePhases`）・`Render3d.flix`（`MaterialPass.DepthPrepass`）・`ScenePlan.flix`（並べ方）・`Material.flix`・`WebGpuMaterials.flix`（visibility・layout と pipeline の鍵・位相）・`MultiMeshPlan.flix`（確かめ）・`ShaderSourceKey.flix`（`MaterialVertexTemplate`）・テスト。G2b は `Shadow.flix`・`WebGpuShadows.flix`・`ShadowMaps.flix`。
- engine_tools: `SoftRaster3d/Fog.flix`（出すだけ）・新しい `SoftRaster3d/VertexOffsets.flix`・`SoftRaster3d.flix`（数行）・`DrawHash`。
- bin: `bin/lint-rules/forbid.json` の `app-internal` の pattern に `Scene3d`・`Water3d`・`ShaderGen` を足す（今ゲームとテンプレートで `Scene3d.Internal` を書く所は無い）。
- docs: `docs/scene3d.md`（頂点を動かす・許す葉の一覧・奥の距離・深度を先に描く・水・波紋の写経元）・`docs/water.schema.json`・`docs/backend-parity.md`・`agents-pack/AGENTS.core.md`・`agents-pack/agent-eval/engine.json`・`docs/migrations/<版>.md`。

## 9. AI が迷わない形（早見表とお題の案）

**早見表（`agents-pack/AGENTS.core.md`）の行の案**:

| したいこと | 使う API | 使わない物 |
|---|---|---|
| 池・川・入り江の板を水にする | `Scene3d.withMaterial(Water3d.material(Water3d.loadOr("….water.json")))`・PostStack のある場面に置く | 水の Spec を手で組まない |
| 旗・草・吊り物を揺らす | `Scene3d.withVertexOffset(Some(Scene3d.windSway({ … })))` | 毎コマ行列や形を作り直さない |
| 自分の式で頂点を動かす | `Scene3d.withVertexOffset`（許す葉だけの Spec） | `Fbm`・`Tex` を変位に使わない（外されて知らせが出る） |
| 浮く物を水面に乗せる | `Scene3d.computeSurfaceHeight(水の置いた物, t, x, z)`（絶対の高さ） | GPU から読まない・自分で波の式を書かない |
| 粒子・霧の板が床に刺さる線を消す | Spec の `Field.SceneDepthDifference` を α に掛ける | — |
| 半透明が手前のガラスに塗られる・自分に重なる | `Scene3d.withDepthPrepass(true)` | 物を細かく分けて並べ直さない |
| 水の値をコードで少し替える | `{ roughness = 0.1 | Water3d.defaults() }` | 全部の欄を書かない |

**agent-eval のお題の案（`agents-pack/agent-eval/engine.json`・当たりと外れは `re` と `why` で）**:
1. 「岩に囲まれた入り江に水を張り、木箱を浮かべる」
   - 当たり: `re: "Water3d\\.material"`・`re: "computeSurfaceHeight"`（why: プリセットと絶対の高さの API を選ぶ）
   - 外れ: `re: "Scene3d\\.Internal"`（why: Internal を書いた）。「毎コマ形を作り直す」は場所の条件が正規表現にならないので外れに入れない
2. 「旗竿の旗を風で揺らす」
   - 当たり: `re: "windSway|withVertexOffset"`
   - 外れ: `re: "Mat4\\.(rotate|translate)[^\\n]*(?:Time|Clock)"`（why: 毎コマ行列で揺らした）
3. 「煙の板が床に刺さる線を柔らかくする」
   - 当たり: `re: "SceneDepthDifference"`
   - 外れ: なし（当たりだけで見る）
4. 「ガラスの窓の向こうに水の板があり、水が窓の手前に塗られる。直す」
   - 当たり: `re: "withDepthPrepass"`
   - 外れ: `re: "Scene3d\\.Internal"`

ゲームの足元で `make agent-eval ONLY=<お題>` が当たるのを各段の後に確かめる。

## 10. 段と見積もり（実時間）

| 段 | 中身 | 物差し | 実時間 | 前に要る物 |
|---|---|---|---|---|
| G0 スパイク | 変位の頂点を木で仮に書く・頂点の段の `vWorld`・`vUv` を attribute から作り直す形・`MaterialVertexTemplate` の 2 つのプレースホルダーと、その鍵に instancing（MultiMesh の 1 本ごとの行）の版の区別が要るか（今の手書きの頂点が instancing でどう分かれているかを見て決める）・WebGPU の visibility と 256 バイトの境・MultiMesh で通るか・`DepthPrepass` の pipeline・invariant と LEQUAL・wasm の前 | 3 | 0.7 | W1 |
| G1 深度を先に描く | `withDepthPrepass`・`MaterialPass.DepthPrepass`・2 組の並べ方・pipeline と staticGroup の鍵・LEQUAL と invariant・CPU・Internal の `Always` の欄だけ | 5〜7 | 1.2〜1.8 | W1 |
| G2 VertexOffset | 型・許す一覧と評価器・`windSway`・葉 `GerstnerWaves`（11 ファイル）・`compileVertexOffset`・変位の頂点の木・`ProgramKind` の 2 欄・GL と WebGPU の値の置き場・境界の箱・MultiMesh・CPU（霧の塊を出す下ごしらえ・world で）・決まった sin・`computeSurfaceHeight`・gl-parity | 20〜26 | 4.5〜6.3 | G1 |
| G3 SceneDepthDifference | 葉（11 ファイル）・PostStack の条件と知らせ・字の鍵の旗・binding・`+ao` を受けない決まり・texture unit の 3 手（L 計画 9.4 の文と L5 のコードとテスト）・CPU・gl-parity | 10〜14 | 2.4〜3.5 | L5・G2 |
| G4 水のプリセット | `Water3d`（engine_world）・Doc と schema・`fresnelAlpha`・lint の pattern・早見表とお題・docs | 9〜12 | 2.5〜4 | G1〜G3 |
| デモ | 17 節（ゲームの側） | 8〜10 | 2〜3 | G1〜G4 |
| レビュー | G2 の後・G3 の後・G4 の後 | — | 1.5〜3 | — |
| （後ろ）G2b 変位した物の影 | 3.5 | 6〜9 | 1.5〜2.5 | G2 |
| （後ろ）G4b カメラに付いてくる海 | 6.2 | 8〜11 | 2〜3 | G4 |
| （条件つき）G5 動く Mesh | W-d0 の測り（0.5）・動く Mesh（0.8〜1.2） | 5〜7 | 1.3〜1.7 | W1 |

- G0〜G4 の和は 11.3〜16.3 時間。デモとレビューを足して **14.8〜22.3 時間**。物差しは G0〜G4 とデモで 55〜72 時間。換算は 1/4〜1/5（L 計画 2 節の実績）に GPU の門の待ち（1 段に 20〜40 分）を足した。段の中で見込みの 2 倍を超えたら止めて相談する。
- 区切りのリリースは G4 の後に 1 回。

## 11. 順と依存（決め 1）

```
W1（main）─→ G0 ─→ G1 ─→ G2 ─┐
L5（main・ScreenInputs・L5-0b・9.4）─→ G3 ─→ G4
G2 ─→ G2b（後ろ）   G4 ─→ G4b（後ろ）   W1 ─→ G5（条件つき）
compute の道 ─→ 14 節
```

- G1・G2 は render_gl の頂点と pipeline を触るので W1 の後（W1 の前に木の頂点を足すと、+6% の残り約 5 KB を L5 と取り合う）。G3 は L5 の奥行きの絵と 9.4 の後。L6・L7 とは互いに依存しない。
- 同じパッケージを 2 人に触らせない: render_gl は L5 → W1 → G0〜G4 を 1 人で順に。G4 の engine_world は L5 の PostStack と同じパッケージなので L5 の後。
- 推す: 案 1 `L5 → W1 → リリース → G0〜G4 → リリース → L6 → L7 → リリース → 段 1 の残り`。W1 で作り替えた template と記録の形を、小さな新しい形（頂点の template 1 つ・欄 2 つ）で最初に確かめられる。了承済みの L6・L7 は 12〜16 時間後ろへずれる。案 2 は `… → L7 → リリース → G0〜G4 → リリース → 段 1 の残り`。

## 12. Internal に入れる物（ゲームから呼ぶと `app-internal` が止める）

| 物 | 置き場 | 理由 |
|---|---|---|
| CPU の変位の評価器（許す一覧）・決まった sin・cos・浮力の反復・`reach` の求め・波の位相を折り返して詰める値 | `Scene3d.Internal.VertexOffsets` | ゲームは `withVertexOffset`・`windSway`・`computeSurfaceHeight` だけを見る。位相は render_gl（別のパッケージ）が読むので pub だが Internal |
| Spec を頂点の字にする所 | `ShaderGen.Internal.VertexOffset` | 描き手だけが使う |
| 深度を書くだけの半透明（`Always`）の欄 | `Scene3d.Internal` | index の順を保てる engine の海の格子だけが使う。ゲームの池に付ける選び違いを無くす |
| `fresnelAlpha` を立てる API | `Scene3d.Internal` | 今は水のプリセットだけが使う |
| 海の格子（レベル・丸め・継ぎ目・index の並び・形の控え）（G4b） | `Scene3d.Internal.Water` | `Water3d.ocean` が組む。数は頂点の弱め方と組で決まる |
| 水の Doc の `load`（`Result`） | `Water3d.Internal.Doc` | ゲームが呼ぶのは `loadOr`（`docs/error-handling.md`） |
| 波紋の式 | engine に入れない（デモと docs の写経元） | 実装が 1 つの所に層を置かない |

速さの代金は動詞で分かるようにする: `compute*`（毎回解く・高い）・`with*`（値を替えた新しい値・安い）・`make*`（作る・`Mesh3d.makeDynamic`）。`get*` は使わない（安く取り出すだけの API が無い）。

## 13. ゲームが見る API（11 + 型 1）

| API | いつ使うか（1 行） |
|---|---|
| `Scene3d.VertexOffset`（record） | 頂点の変位を x・y・z の Spec で書く時の値 |
| `Scene3d.withVertexOffset` | 材質の頂点を式で動かしたい時（旗・草・吊り物・水面） |
| `Scene3d.windSway` | 草・旗・吊り物を風で揺らしたい時（よく使う揺れの形） |
| `Scene3d.computeSurfaceHeight` | 浮く物を、動く面（水）の絶対の高さに乗せたい時 |
| `ShaderDoc.Field.GerstnerWaves` | 盛り上がって尖る波の変位を Spec で書く時（頂点の段だけ） |
| `ShaderDoc.Field.SceneDepthDifference` | 奥の不透明な面までの距離で、厚みの色・端の柔らかさを決めたい時 |
| `Scene3d.withDepthPrepass` | 半透明の物が手前の物に塗られる・自分に重なって透ける時 |
| `Water3d.Settings`（record） | 水の値（波・色・吸収・泡） |
| `Water3d.defaults` | 水の値をコードで書く時の土台（`{ … | defaults() }` の形で） |
| `Water3d.loadOr` | 水の値を Doc（`*.water.json`）から読む時 |
| `Water3d.material` | ゲームの形（池・川・入り江の板）を水にする時 |
| （G4b）`Water3d.ocean` | カメラに付いてくる海を置く時 |
| （条件つき G5）`Mesh3d.makeDynamic`・`withVertices` | 毎コマ中身が変わる形（触ると揺れる池）を作る・差し替える時 |

数は 11 + 型 1（`windSway` の引数の enum `Scene3d.SwayAnchor`（`UvV0`・`UvV1`・`VertexColor`））。名前は Unity（Scene Depth Difference・wind zone）・Unreal（Gerstner Wave）・Godot（`depth_prepass_alpha`・ImmediateMesh）の語。

## 14. compute の道の後（形と前提だけ）

compute の API（別の担当のスパイク中）と、その結果の絵を頂点と frag が読む道が前提。WebGL2 には compute が無いので、そこでは今の式の波へ戻る。

| 段 | 形 | CPU と遊び |
|---|---|---|
| FFT の波（Tessendorf） | 毎コマ逆 FFT で変位の絵を作り、`GerstnerWaves` の代わりに読む葉（許す一覧に足す時に決定性を決める） | 浮力は長い波の成分だけを `GerstnerWaves` に写した近似（読み戻すとテープの決定性が崩れる） |
| 持ち越す泡 | world の XZ に固定した泡の量の絵を compute で足し・減らし・流す | CPU は持たない（`SoftRaster.dropped`） |
| 粒子の流体（SPH） | 粒子を compute で動かし、画面の上で面にする（L5 の奥行きの道） | 数千粒まで CPU で（遊びの小さな水槽） |

画面の控え（`ScreenHistory`）で泡を持ち越す形は採らない（画面の外へ出た泡が消え、隠れていた所で欠ける）。

## 15. 範囲の外

| 物 | 順 |
|---|---|
| 屈折（前のコマの色を法線でずらして読む・段 1 の 2d・4a と同じ道） | 段 1 の 2d・4a の後に相談 |
| 水面の SSR | 奥行きの絵に水面が入らない（深度だけ先に描く半透明も入らない）ので、段 1 の 4a のままでは効かない。水面を奥行きの絵に入れる道と一緒に、4a の後に相談 |
| 置いた物の頂点を全部木へ | W1 の後・G4 の後に別の段として相談 |
| 水の中（カメラが沈む）・平面の鏡 | 需要が出てから・平面の鏡は取らない |
| `fresnelAlpha` の API 化（ガラス） | 要るゲームが出てから |
| 白波 | 頂点で求めた高さを frag へ渡す道（varying と葉）が要る。要るゲームが出てから |

## 16. 重さと wasm（推測は G0・W-d0 で測り直す）

| 物 | PC（M4 Pro・1080p） | S24（Low） | wasm（brotli） |
|---|---|---|---|
| 水の板の頂点（約 1 万頂点・波 8 本・微分の法線） | GPU < 0.1 ms | GPU 0.1〜0.3 ms | 変位の式の字は表に増えるだけ |
| 草の MultiMesh（1 万本 × 数十頂点・windSway・差の法線） | GPU 0.1〜0.3 ms | GPU 0.4〜1 ms | — |
| 水の frag（PBR・環境マップ・半透明が画面の半分） | GPU 0.3〜0.6 ms | GPU 1〜2 ms | 0 |
| `SceneDepthDifference` | GPU +0.05〜0.1 ms（奥行きの場面は L5 と共有。水だけの場面は奥行きの場面の分 +draw） | +0.2〜0.5 ms | — |
| 深度を先に描く池 | draw +1（小さい） | — | — |
| `computeSurfaceHeight` 1 回（最大 16 回 × 8 本） | CPU 0.002〜0.005 ms | — | — |
| Flix の部品とプリセットの合計 | — | — | +6〜12 KB（W2 の門 +3% の内）。デモの書き出しでも `wasm-size --diff` を取る |

S24 の測りは L 計画 8.2 の段取りに乗せる（G4 の後のリリースの時に、デモの「水あり・なし」の URL を人に頼む）。

## 17. 遊びの手本（小さなデモ）

**「小舟の入り江」**（仮・`cove_lab`・`~/Documents/flix_ge_workspace` に新規。テンプレートの `tidepool-starter` とは別物）。夕方の岩に囲まれた入り江（水の板に `Water3d.material`）に、桟橋の旗と岸の草が揺れ（`windSway`・草は MultiMesh）、浮きと木箱が波に乗る（`computeSurfaceHeight`）。小舟で浅瀬に入ると舳先から波紋が広がる（波紋の式はゲームの側・形の作り直し。G5 が入れば動く Mesh）。焚き火の煙の板が岩に刺さる線は `SceneDepthDifference` で消え、窓のある小屋の向こうに水が見える所で `withDepthPrepass` を確かめる。

- 確かめる事: 部品が水以外（旗・草・煙）にも効くか・浮く物が描いた波と合うか・PC とブラウザで浮く物が同じに動くか（テープ）・ブラウザの重さ。カメラに付いてくる海は使わない（G4b を要らせない）。
- 画風は `/style-interview` で決める。絵と音は自前。遊びの中身は作る前に人に見せる。

## 18. 人に決めてほしい事（推す答えつき）

1. **G0〜G4 をどこに挟むか** → 案 1（W1 の後のリリースの直後・L6 の前）。L6・L7 が 12〜16 時間ずれる。順を動かしたくなければ案 2（L7 の後）。
2. **水専用の API をやめ、汎用の部品 3 つ + 水のプリセット 1 つにするか（ゲームが見る API 11）** → そうする。
3. **頂点の変位を Spec で書き、頂点の段で読める葉を決定的な物だけ（許す一覧）に絞るか** → 絞る。hash・`Pow`・`Log2` は変位に使えない（外して知らせる）。CPU の評価器は新しく置き、`ShaderEval` と全部の op で照らすテストで 2 つのずれを止める。
4. **草・旗の揺れのプリセット `windSway`（重みは uv の v か頂点の色）を v1 に入れるか** → **入れず、`withVertexOffset` の docs の例にする**のを推す。今のゲームで 3D の物を揺らす所は 0 件（2 節で refactor で引いた）で、AGENTS の「層を置く物差し」に照らすと需要の前に API を足す理由が弱い。入れるなら API は 11 + 型 1、入れなければ 10。
5. **変位した物の影は G2b に分け、G2 では動かす前の形の影にするか** → そうする（影の pass は材質のプログラムを使わず、新しい道と影の控えの扱いが要る）。
6. **半透明の深度は `withDepthPrepass`（LEQUAL・invariant・新しい `MaterialPass.DepthPrepass`）だけをゲームに見せ、深度を書くだけの形は Internal にするか** → そうする。
7. **`SceneDepthDifference` を読む材質があれば PostStack が自分で奥行きの絵を描き、無い場面で水を置いたら 1 回知らせるか** → そうする。
8. **半透明の材質は全部 `+ao` を受けないか** → 受けない（奥行きの絵に入らないので、奥の面の AO が塗られる。L 計画 9.1 に 1 行）。
9. **texture unit の外す順を 3 手（`+ao` → 絵を後ろから → `bug!`）にし、L 計画 9.4 の文と L5 のコードを G3 で直すか** → そうする。
10. **`Water3d` を engine_world に置き、カメラに付いてくる海（G4b）は要るゲームが出てからにするか** → そうする。
11. **波紋の式を engine に入れず、動く Mesh は測ってから足すか** → そうする。
12. **forbid の `app-internal` に `Scene3d`・`Water3d`・`ShaderGen` を足すか** → 足す。
13. **新しい API 11 + 型 1（`windSway` を入れない時は 10・G4b +1・G5 +2）を了承するか** → 了承を。

## 出典にした engine の場所

- render_gl: `Render3dWgsl/MeshVertex.flix`（頭の WhyNot）・`ShaderAst/Entry.flix`（`vertexOrBug`）・`Render3d/ProgramKey.flix`（87 行）・`Render3d/Uniforms.flix`（119 行）・`Render3d.flix`（`MaterialPass` 137 行）・`Render3d/Shadow.flix`（`shadowProgramFor` 268 行）・`Render3d/WebGpuMaterials.flix`（275〜279 行の visibility）・`Render3d/MultiMeshPlan.flix`・`Render3d/MeshTable.flix`
- engine: `scene3d/Scene3d.flix`（`MaterialFields` 232〜250 行・`materialFieldsOf` 428 行・`blendOrderOf` 533 行・`instancesOf` 815 行）・`scene3d/Mesh3d.flix`（`digestOf`）・`shader/ShaderDoc.flix`（`Field`・`BinOp`・`UnOp`）・`shader/ShaderEval.flix`（hash 967 行）・`shader/ShaderGen.flix`（29 行）
- engine_world: `Sway.flix`・`DocJson.flix`（`loadOr` 70 行）
- engine_tools: `SoftRaster3d.flix`（`placedOf`・`instanceTris`・`blendRow`・霧の塊 219〜236 行・1,184 行）
- `bin/lint-rules/forbid.json`（413 行）・`docs/scene3d.md`・`docs/performance.md` 8 節・`docs/error-handling.md`
- 計画: L 計画（3.4・4.1・8.2・9.1・9.2・9.4）・段 1 計画（2d・4a）・W1 計画（2.2・3.1・10 節）・`plans/engine-cell-sim.md`
- ゲーム: `sea_cave_walk/src/SeaMaterial.flix`・`lamplighter`・`bench/hd2d_town/src/TownMap.flix`・`templates/tidepool-starter`
- 参考: bevy-aqua の README（考え方だけ。機能の並びは順の根拠にしない）

## レビューへの答え（書き直しの 1 回目 72 点）

- 必須 1（影の pass は材質のプログラムを使わない）: G2 では動かす前の形の影にし、影の道と影の控えから外す決まりを G2b（3.5・見積もり 1.5〜2.5）に分けた。
- 必須 2（WebGPU の頂点から値を読む道・前の版から落ちた）: visibility を `VERTEX | FRAGMENT` にし layout と pipeline の鍵へ・GL の `WavePhases`・位相の詰め方・`MaterialVertexTemplate` と 2 つのプレースホルダー・`+vo` は頂点の鍵で `+db` は frag の鍵と分けた（3.2）。
- 必須 3（頂点の段で読める葉）: 実物の名前で許す一覧を決め、それ以外は全部読めない・外した理由・頂点の段の `World`・`Uv` の意味・`GerstnerWaves` は frag で読めない葉・例を実在の constructor に直した（3.1）。
- 必須 4（決まった sin だけでは決定性が守れない）: hash・`Ripples`・`Pow` の葉を許す一覧から外し、残る葉が IEEE の四則と sqrt と決まった近似で求まる事を書いた（3.1・3.3）。
- 必須 5（草の MultiMesh・ビルボード）: MultiMesh は `ProgramKind` で材質のプログラムを引くので変位を受ける形にし、G0 で確かめて通らなければ切って 2 節の根拠から外す。ビルボードは受けない（3.2）。
- 必須 6（`recomputeNormal` の旗の例）: 法線に垂直な 2 つの向きで `World` だけを動かして差を取り、`Uv` は頂点の値のまま。`GerstnerWaves` だけは微分の式（3.1）。
- 必須 7（`Water3d.ocean` の目印・高さ・`computeSurfaceHeight` の誤用）: 海は G4b に分け、目印をやめて普通の置いた物を返す形に。`computeSurfaceHeight` は置いた物を受けて絶対の高さを返す（3.3・6.2）。
- 必須 8（深度を書く半透明と奥行きの絵）: `+db` の材質と深度を先に描く半透明は `+ao` を受けない・水面の SSR の行を取り消して条件を書いた（4.2・15 節）。
- 推奨: 1 `Water3d` を engine_world へ（6.1）／2 海を G4b へ・深度を書くだけの形を Internal に（5・6.2）／3 `windSway` を足した（3.1）／4 `ShaderGen.Internal` と forbid（3.2・12）／5 `MaterialPass.DepthPrepass` を新しく（5）／6 長さは葉が場面の長さ・`Water3d` で直す（3.1・6.1）／7 PostStack の無い場面の知らせ（4.1）／8 お題を `re` と `why` で・誤検知する外れを外した（9）／9 見積もりを足し直した（0・10）／10 格子の細かさは G4b の `oceanSpacing`・泡は `World` で（6）／11 9.4 の書き換えは L5 のコードとテストも（4.2）／12 2 節の根拠の `refactor` は G0 で引くと書いた（推測のまま）／13 Settings が record の理由と `{ … | defaults() }` の決まり（6.1）。
- 軽微: 「器」を消し、格子の「段」は「レベル」に・地の文の「口」は「API」に寄せた／名前を `SceneDepthDifference` にした／不透明に `withDepthPrepass` を付けたら無視／知らせは材質の鍵ごとに初回 1 回／`Ripples` は許す一覧の外になったので例は不要／`materialFieldsOf` で内側の欄が読める事を冒頭に書いた。

## レビューへの答え（書き直しの 2 回目 86 点）

- 必須 1（`Un` の `Log2` は `Math.log`）: 許す一覧の `Un` から `Log2` を外し、外した理由に 1 行足した（3.1）。
- 必須 2（`SwayAnchor.MeshBottom` は許す葉で組めない）: 案 b を選んだ。`MeshBottom` をやめ、重みの元を `UvV0`・`UvV1`・`VertexColor(c)` にした。理由: モデル空間の位置の葉を足すと葉と評価器と 11 ファイルの直しが増える割に、uv と頂点の色（foliage で普通の作り方）で同じ事ができ、MultiMesh の草も 1 本ずつの原点に依らない（3.1）。
- 推奨: 1 1 mm の約束を滑らかな op と `GerstnerWaves` に限り、境目の op と `Time` の float32 を書いた（3.3）／2 新しい評価器を置き、全部の op で `ShaderEval` と照らすテストを選んだ（3.3）／3 お題の正規表現を `(?:Time|Clock)` に包み、場所の条件の外れを外した（9）／4 `+ao` の例外を半透明の材質の全部へ（4.2・18 の 8）／5 texture unit の最悪の組を 18 と数え直した（4.2）／6 G0 に instancing の版の区別を足した（10）／7 2 節の揺れる物の根拠を町・校舎・箱庭で `refactor` で引いて事実にした（3D の揺れは 0 件。`windSway` を docs の例に回す案を 18 の 4 に）。
- 軽微: API の数を「11 + 型 1」に／物差しを 55〜72 時間に戻した／`UvV0` の v の向き（glTF は v = 0 が絵の上）を 1 行（3.1）。

## 測った値（各段の後にここへ足す）

（未）

## 了承（2026-11-27）

人が「ほかは許可」で、最後の節の決め事を全部推す答えのとおり了承した。
