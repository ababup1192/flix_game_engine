# 3D の表現力を上げる仕組み — 後がけの値（PostStack）と、3D が出す名前つきの絵（prepass）

状態: S0・S1a・S1b の前半を実装した（§11）。AgX・Filmic（Blender の LUT）はライセンスが分からず止めている。作業場 worktree `worktree-agent-ad56639e9d8579117`（v0.100.0 起点）。rev2（レビュー 1 回目 68 点・2 回目 78 点の指摘を反映。記録は付録 B）。
**engine の拡張なので、実装の前にこの文書で人と決める（AGENTS.md）。** 人に決めてほしい事は §10。
印: 【確】= コード・数で確かめた / 【推】= 推測 / 【未確認】= 確かめていない。

前提の文書: `plans/webgpu/analysis-render-structure.md`（11-14 の分析。以下「分析」）・`plans/webgpu/survey/K-light-units-calibration.md`（光の単位と Blender の手本。以下「K」）・
`plans/engine-webgpu.md` 12.41〜12.42（PC とブラウザの既定が WebGPU）・`docs/art-ref/visual-dict/reference-3d.md`（見た目の名前 → 値の組）・`docs/z-bands.md`。

範囲: **後がけと画面空間の効果**（トーンマップ・露出・ブルーム・色の仕上げ・DoF・AO・光の筋）と、そのための 3D の prepass。
光の式の単位（拡散の 1/π・逆二乗・lux / candela・環境マップの HDR）は K の別の計画で、ここでは扱わない（§6.4 で順だけ決める）。

---

## 0. 要約

- 願い: 影 MOD のような絵（やわらかい影・すき間の暗さ・映り込み・水・空・光の筋・雲・ブルーム・トーンマップ）をエンジンで出す。
  **方針（人の確認）: 物理ベースで、Blender に合わせていく。** 名前と数の意味は Blender（Color Management・compositor・EEVEE / Cycles）と glTF に寄せ、
  「Blender で同じ場面を描いた絵」を正解の絵として比べる。
- スパイク 4 つの結果（§1）:
  - (a) lamplighter の後がけ 98 行を値の列に置き換えて、**CPU・WebGPU・GL の 3 つとも 0 px 差**。ただしこれは「今の式（画面の値の ACES・ゲームが渡す奥行きの絵）を値で書ける」証拠で、
    Blender に寄せた後の API（線形・fStop）の絵の一致ではない。スパイクの語彙で ws の 3 本（lamplighter・ome_city・plateau_city）＋ほぼ 1 本が書け、FilmGrain・ColorGrade・ビネットの中心を足すと 7 本【推】。
  - (b) 法線と奥行きを 1 枚に出す prepass（別 pass）を 3 つの描き手に通し（engine 側 約 140 行）、**SSAO を式の木だけで書けた**。今の絵は 3 つとも不変。
    PC の WebGPU で submit +0.33 ms・GL の GPU +0.57 ms。スマホは 1 辺半分・12 点だと 9〜14 ms 上乗せの見込みで、**読む絵の大きさを画素の数で頭打ちにする品質の段が要る**【推】。
  - (b') 同じ部屋を Blender で組み直して AO を比べた: Cycles と相関 0.80（数を寄せても 0.81）・差の中央値 0.082 → 0.055。**明るさの平均は寄せられるが形は寄らない**（隅の落ち方・画面の外・厚み）。
  - (c) vec3 を足すと後がけの木は 59% 減（696 → 286 節。うち 218 は engine の FXAA 1 本）。材質は 0%。SSAO は vec3 で 2 割、**let か taps の輪で 87% 減**【推】。
- 推す構造: 分析のとおり **後がけの値の束（案 1）を先に、prepass と効果の登録（案 2）を段で**。render graph の全面の作り替えは取らない。
- 段（§3）: S0 CPU の 16F の pass の遅さ → S1a PostStack（今の式のまま・0 px の錨）→ S1b 線形化と Blender の view transform（LUT）→ S2 式の木の let・taps（と vec3）→ S3 prepass と AO → S4 空・かすみ・光の筋 → S5 水 → S6 影。
  **最初の段に推す物【推】: S1（S0 → S1a → S1b）**。3D のゲーム約 10 本の手書きを 1 か所にし、Blender の Color Management と 1 対 1 に比べられ、描き手を触らない。
- pub API（§4）: 足す物は mod `PostStack`（閉じた型 `Stack`・`withBloom` などの `with*`・`Preset`・`Quality`・`build`・`App.withPostStack`）と `Field.Lut3d`（S1b）・`Field.Let`・`Field.Taps`（S2）・`Scene3d.Output.DepthNormal`（S3）。
  消す・寄せる物は `App.withPasses`（使用 0）・`PostProcess.defaultExposure` の +0.4。

---

## 1. スパイクの結果

### 1.1 (a) 後がけを値の列に（別 worktree `worktree-agent-acd506d76c0982810`・コミット `9f09894b`・`spikes/render-expression/a-poststack/`）

| 項目 | 結果 |
|---|---|
| 絵の差（同じ描き手の前後・alley 夕暮れ / night 夜 / arrival） | CPU 3 枚・WebGPU 9 枚・GL 9 枚とも **SHA 一致（0 px）**【確】。対照: ビネットの inner を 0.35→0.36 にすると CPU 170,073 px・WebGPU 43,058 px 変わる |
| 試作の API | 効果の enum の列（`DepthOfField{depth = 奥行きの items, band, soft, blur, taps}`・`Bloom{threshold, knee, strength, radius, taps, scale}`・`Vignette`・`Saturation`・`Tonemap{curve, exposure, whitePoint}`・`Fxaa`）。順は固定（DoF → Bloom → Vignette → Tonemap → 彩度 → FXAA） |
| 行数 | PostView 98 行 → ゲーム側 21 行 + View の 1 行。試作 156 行 |
| 版の追随 | 0.91.0 → 0.100.0 はソースの直し 0。`upgrade-game` が flix.toml の `flix =` を上げない【確】→ 別件 |
| 描き手どうしの差（参考） | WebGPU と GL で 27〜33% の画素が違う（最大 ±137。MSAA・ぼかし）。CPU と GPU は大きさが違い比べていない【未確認】 |
| 形で分かった事 | View は Pass の計画と画面の層を別に組むので `plan` と `present` に列を 2 回渡した → §4 で `App.withPostStack` 1 か所に |

他のゲームの語彙（読んだだけ）: 書ける 2（ome_city・plateau_city）・ほぼ 1（stepdown: ビネットの中心）・一部 3（conduit_hive: FilmGrain／sea_cave_walk: 毎コマの露出／night_apartment: ColorGrade・FilmGrain・毎コマの明るさ）・
書けない 3（fps3d_lab・dungeon3d_lab・hd2d_lab: 場面の前後の Pass・design の大きさの場面・奥行きを名前で受ける DoF・Haze・熱のゆらぎ・LDR の並び・画面の行で決めるピント）。
効果の出現（10 本）: Bloom 10・Vignette 10・Tonemap（全部 Narkowicz の ACES・白の点 4.0）8・FXAA 8・MSAA 6・DoF 4・彩度だけ 4・ColorGrade 4・Grain 2・Haze 2・熱 2・毎コマの明るさ 2。
使われた値: exposure −0.6〜+0.1・bloomThreshold 0.62〜2.0・knee 0.12〜0.7・strength 0.25〜1.0・radius 0.03〜0.05・taps 12〜24・vignette 0.18〜0.5・saturation −0.05〜+0.18。
**スキーマの min・max は使われた幅の 3〜10 倍で、ゲームごとに決め直している**（例 exposure ±3〜±4）。

### 1.2 (b) 法線と奥行きの prepass と SSAO（別 worktree `worktree-agent-adda5afff61d0ee1a`・コミット `a3a81e0e`・`30d3d9fd`）

- 足した物: `Scene3d.Output.DepthNormal({near, range})`（r・g = view 空間の法線 x・y を 0..1 に・b = `Output.Depth` と同じ灰色・α = 1）。
  α に奥行きを入れないのは CPU の描き出しが 3D の層を α で 2D へ重ねるため。法線マップは当てない・両面は裏で反転・cutout は捨てた後・半透明は入れない・ビルボードは (0,0,1)。
  **pipeline の鍵と `ProgramKind` の変種は増えない**（depth の pipeline の中で場面の値で枝を分けた）【確】。
- 手間（`git show a3a81e0e --stat`）: Scene3d +17・ScenePlan / StaticRows +12・GL +20・WebGpuRenderer +4・GLSL +23・WGSL +28・SoftRaster3d +33・DrawHash +1（engine 側 約 140 行）。
  MRT（色と同時に 2 枚目へ）は 600〜800 行の見積もり【推】（2D・3D・空・ビルボードの全 pipeline の鍵に描き先の組・MSAA の resolve・CPU の 2 枚の層）。
  `RenderList.PassTarget.Target(ColorAttachment, List[ColorAttachment])` と Java 側の `colorTargets` は既に複数枚を受けられる形【確】。
- SSAO（`bench/scene3d/src/Ssao.flix`）: 法線と奥行き → 色 → 暗さ（scale 0.5 = 1 辺半分・12 点）→ 最後の面（暗さを TexBlur 8 点でぼかし、色に掛ける）。
  **木だけで書けた**。`Shift` の中で `Ref` を引くと真ん中の値が返るので、読む点の式を Shift 1 つに入れられた。暗さの面は 3,153 節・GLSL 164 行・WGSL 191 行。
- 絵の差（320×180・カメラ固定）:

| 絵 | WebGPU と GL | WebGPU と CPU | GL と CPU |
|---|---|---|---|
| 法線と奥行き | 0 px | 2.9%・最大 255（縁の 9 px は差 > 8） | 同じ |
| 暗さ（ぼかす前） | 60.6%・最大 107・差 > 8 は 6.6% | 43.8%・最大 81・差 > 8 は 7.7% | 68.8%・差 > 8 は 12.2% |
| 最後の色 | 48.0%・差 > 8 は 1.3% | 33.6%・差 > 8 は 1.2% | 57.0%・差 > 8 は 1.6% |
| AO 無し（参考） | 0 px | 82 px | 同じ |

  差の大半は読む点が奥行きの段差で隣の画素を拾うかどうかの縁の差（回しを 0 にしても 42〜60%）。**1 場面・1 解像度の数**で、線を決める材料としては薄い（§5）。
  **今の絵は不変**: gl-capture の scene3d 6 コマが WebGPU・GL とも前後でバイト一致・CPU の still も SHA 一致【確】。
- 時間（960×540・中央値）:

| | AO 無し | prepass | prepass + SSAO |
|---|---|---|---|
| WebGPU の submit（CPU） | 0.554 ms | 0.758 ms | 0.883 ms |
| WebGPU の draw call（3D + 2D） | 10 + 0 | 20 + 0 | 20 + 2 |
| GL の GPU | 0.294 ms | 0.393 ms | 0.865 ms |
| CPU（SoftRaster）1 枚 | 45 ms | 441 ms（Rgba8 なら 75 ms） | 1,271 ms |

  WebGPU の GPU の時間は取れていない（timestamp query を使う口が無い）【未確認】。**CPU で Rgba16Float の pass へ 3D を描くと 1 枚 約 370 ms 重い**（S0 で直す）。

### 1.3 (c) `Field` に vec3（この worktree の `spikes/render-expression/c-vec3/`）

| Spec | 今の節 | vec3 で括る | 減り |
|---|---|---|---|
| 後がけの本編（DoF・ブルーム・ビネット・ACES・彩度） | 246 | 78 | 68% |
| 明るい所 / ぼかし / FXAA（engine の `fxaaSpec`） | 30 / 12 / 408 | 12 / 6 / 190 | 60 / 50 / 53% |
| 材質 5 本（tidepool の 3・pbr_room・plateau_city） | 77 | 77 | 0% |
| SSAO の暗さ | 3,153 | 約 2,500（vec3 だけ）/ 約 400（let か taps の輪）【推】 | 20% / 87% |

ws の 16 本の src に `chan ->` 77 か所・`Shade.Rgb(` 97 か所・`luma709` 16 か所（字の数え）。材質は `Ramp`・`Gradient` で色にしていて減らない。
S1 の後は AI が後がけを手で書かなくなるので、**vec3 の得は「読みやすさと手で書く面」に限られ、S3 に要るのは let と taps**。
`LightModel3d.Vec3Expr` は vec3・`Let`・決まった回数の輪（`SumPoints`）を既に持つ【確】。`eqSpec` の時間・生成した shader の行の前後は【未確認】。

### 1.4 (b') Blender の AO と並べる（同じ worktree・コミット `ff3a3689`・`spikes/render-expression/b-ssao/blender_ao.py`・`aocompare.py`）

部屋を簡単な場面に替えず、`RoomObj.write` が置いた物を world の三角形のまま OBJ に書き出し（座標 (−x, −z, y) ÷ 16）、Blender 5.2.3 で全部の材質を「AO 節（distance 0.875 m = radius 14）→ Emission」に替えて描いた（色の変換は Raw・320×180）。
View Layer の AO の pass そのものではなく同じ距離の AO 節【未確認: pass と同じか】。

| エンジン | 正解 | 平均（エ / B） | 相関 | 差の中央値 | 差の p95 | 差 > 0.1 |
|---|---|---|---|---|---|---|
| CPU 既定（radius 14・strength 2.6） | Cycles | 0.903 / 0.792 | 0.803 | 0.082 | 0.392 | 44.6% |
| WebGPU 既定 | Cycles | 0.906 / 0.792 | 0.807 | 0.082 | 0.392 | 45.7% |
| CPU 既定 | EEVEE | 0.903 / 0.923 | 0.780 | 0.024 | 0.173 | 14.6% |
| CPU 合わせ込み（radius 20・strength 4・maxScreen 0.3） | Cycles | 0.807 / 0.792 | 0.810 | 0.055 | 0.282 | 30.7% |
| 参考: EEVEE | Cycles | 0.923 / 0.792 | 0.853 | 0.106 | 0.392 | 51.4% |

- ずれる所: 隅（エンジンは隅のすぐそばの細い帯だけ暗い・Cycles は 0.875 m まで広くなだらか。落ち方の式 1 − v²/R² と「距離の中で当たったか」の違い）・画面の上下の端（画面の外の読む点が端の画素に張り付いて偽の暗さ）・机の下（画面に映らない物と厚みを知らない）・本棚（読む点の縞）。
- 読み: **AO の正解の絵は Cycles**（EEVEE 自体が画面空間の近似で、Cycles と相関 0.853）。`distance` は Blender の AO distance と同じ意味（world の m）にし、内部の係数（今は 1.4 倍）で吸収。
  `factor` 1.0 が同じ distance の Cycles の平均に合うよう較正する。形まで寄せるには、落ち方を「距離の中で当たったか」に近づけ、画面の外の読む点を数えない。**門は 0 px でなく「相関と差の p95 の線」**。

---

## 2. 構造

1. **ゲームに見せる面は値の束 1 つ**（Unity の Volume / Post-processing Stack・Godot の Environment・Bevy の camera の `Bloom`・`Tonemapping`）。
   ゲームは「どの効果をどの値で」を言い、順・Pass・描き先の大きさと形式・Spec はエンジンが決める。
2. **効果の中身は今の `Render.Pass` と `ShaderDoc` に展開する純粋な関数**。GL・WebGPU・CPU の描き手は触らない（S1・S2・S4 の後がけは描き手 0 行）。
   木に乗らない物だけ描き手に入る（S0・S3 の prepass・S6 の影）。
3. **後がけに通すのは world の帯だけ**（§2.2）。UI・Transition・HUD・デバッグは後がけの後に重ねる（トーンマップもぼかしも掛からない）。
4. **3D の場面が後の段へ出す絵は名前つき**（Bevy の `DepthPrepass` / `NormalPrepass`）。ゲームは頼まない — **効果が要る物をエンジンが足す**
   （AO で法線と奥行き・DoF で奥行き）。ゲームが「奥行きのために場面を 2 回組む」手間は消える（描き手は prepass で 2 回描く）。
5. **数の意味は Blender に寄せる**（§6）。調整の数は全部 `Param`（uniform）で渡し、Spec の鍵は構造（どの効果が有効か・品質・view transform）だけ（§2.3）。
6. **CPU の描き手との合わせ方は効果ごとに 3 つのどれか**（§5）。

WebGPU の後で効く事: (i) `RenderList` の pass の区切りに描き先が並ぶので、prepass は pass を 1 つ足すだけで乗る（スパイク (b) の WebGPU の差分 +4・WGSL +28）。
(ii) render bundle と `staticGroup` は prepass でも使い回せる【推】。(iii) WGSL は `ShaderGen.Wgsl` が木から出すので、木に乗る効果は WGSL 0 行。

### 2.1 順と色の空間

Blender の流れ: 描画（DoF はカメラ側）→ compositor（Glare・Color Balance・ビネットはどれも scene-linear）→ Color Management（Exposure → view transform → look → 表示の OETF）。
**Blender では Exposure がブルームの後**（Unity・Bevy・Filament は pre-exposure で露出が先）。PostStack は Blender の順を取る【推・§10 の 2】。

| 順 | 効果 | 掛ける値 | Blender で対応する段 |
|---|---|---|---|
| 0 | 場面の Pass を読み、線形へ戻す（S1b） | 画面の値 → 線形 | （Blender は最初から線形） |
| 1 | AmbientOcclusion（S3・後がけで掛ける形の時） | 線形 | Cycles の AO の pass（shading の一部・ぼけの前。§10 の 7） |
| 2 | LightShafts（S4） | 線形 | （Blender に無い。compositor の Sun Beams が近い） |
| 3 | DepthOfField | 線形 | Camera の Depth of Field（描画の中） |
| 4 | Bloom | 線形 | compositor の Glare（Bloom） |
| 5 | ColorGrade（lift・gamma・gain・saturation） | 線形（Blender の式どおり中で往復） | compositor の Color Balance・Hue/Saturation/Value |
| 6 | Vignette | 線形 | compositor（Ellipse Mask × Mix） |
| 7 | Exposure | 線形 × 2^e | Color Management の Exposure |
| 8 | ViewTransform（+ look） | 線形 → 表示の値（OETF まで込み） | View Transform・Look |
| 9 | FilmGrain | 表示の値 | （compositor の後・Blender に無い） |
| 10 | Fxaa | 表示の値・Rgba8 の窓の画素の Pass | （無い） |

- 8 の出力は「表示の値（sRGB の OETF を掛けた値）」で、Rgba8Unorm の Pass にそのまま入れる。S1a は今と同じ（画面の値のままトーンマップし、OETF を掛け直さない）。
- `Custom` の置き場は `BeforeBloom`（線形）・`AfterViewTransform`（表示の値）の 2 つ。

### 2.2 後がけに通す物の境目（層で決める・z の数で決めない）

`ZBand` が持つ底は `hudBase`（10 億）と `debugBase`（20 億）だけで、world・ui.json の層（layer × 10000）・Transition（100000）・ゲームの `SortingLayer` は同じ範囲の中にいる【確: レビュー 2 回目】。
z の数で「world の帯」を切る線はコードに無いので、新しい底は足さず、**後がけを掛ける範囲は View と HUD の分け目で決める**（案 A【推】）。

- `App.withPostStack` が掛けるのは **View が返す全部**（`withHudView` とデバッグの外）。会話の窓・確認・メニュー・字幕など、トーンマップもぼかしも掛けたくない物は `withHudView` に置く決まりにする。
  早見表に 1 行・`bin/fge view` の匂い（View の中に UI の窓がありかつ PostStack を使う）に 1 行足す。z-bands.md の「world の範囲」の言い方は「後がけは View の全部・HUD は外」に直す。
- 帰結: Transition の幕（View の中・z 100000）には後がけが掛かる（暗転は露出とトーンマップの後でも黒のまま・ワイプの色は view transform を通る）。幕を後がけの外にしたいゲームは幕を HUD に置く。
- 別案 B（取らない）: ゲームが境目の z を言う（`PostStack.withCeiling(z)`）。窓を HUD へ移さずに済むが、AI が z の数を覚える事になり z-bands の決まり（z を数で書かせない）とぶつかる。
- ゲームの `withPassPlan` と同時に使う時: ゲームの Pass が先、PostStack の Pass が後。PostStack の Pass の名前は予約の接頭辞 `ps_`（今の `pp_` と同じ扱い・ゲームが同じ名前を書くと `PassPlanIssue`）。
  ゲームの Pass は `Custom` から名前で読める。2 つの `PassPlan` は名前の衝突が無い時だけ足す（`Render.mergePassPlans`（新）・衝突は issue）。
- 低い口 `PostStack.build` は App を通さない人（bench・自前の並び）向け。戻り値の `plan` を自分の計画に足し、`present` を後がけを掛けたい items の代わりに置く。
- history（前のコマ）を読む効果は S1〜S3 に無いので、描き出しと実機の絵は同じ式で出る（TAA を入れる時に決め直す）。

### 2.3 Spec と数（毎コマ組み直さない）

- `Render.cachedBySpec` は参照の一致で引く表で、Const の値が変わると program を作り直す（分析 A6）。**PostStack の調整の数は全部 `Param`**（`Render.withShaderParams`）で渡し、
  Spec は構造の鍵（有効な効果の組・品質・view transform・taps の数）が変わった時だけ作る。`Stack` が閉じた型なのは、作った Spec を中に持っておくため。
- 毎コマ露出を変える（sea_cave_walk）・Studio で保存して即反映、のどちらも program を作り直さない。構造の鍵が毎コマ変わる時は 1 回だけ知らせる（`hitch-shader-rebuild` と同じ口）。

---

## 3. 段

見積もりは実時間。直近の実績: スパイク (a) の試作と 0 px の比べ 約 15 分・(b) の 3 描き手の prepass と SSAO 約 40 分・(b') の Blender の組み直し 約 8 分（担当 1 人の時間）。
エンジンに入れる時はテスト・文書・早見表・eval・門・レビューで 4〜8 倍かかってきた。人の目が要る物（preset の値の決め直し・スマホの端末）は別に書く。

| 段 | 何を | 門 | 見積もり |
|---|---|---|---|
| **S0** | CPU（SoftRaster）で Rgba16Float の Pass へ 3D を描く道の 370 ms を直す。HDR が要らない Stack（`Standard` だけ・Bloom 無し）は Rgba8 で描く選び方 | bench/scene3d の prepass の CPU 1 枚 441 → 100 ms 以下・既存の絵はバイト不変 | 2〜3 時間 |
| **S1a** | `PostStack`（Bloom・ViewTransform（今の式 `AcesNarkowicz` と `Standard`）・Exposure・Vignette・ColorGrade・FilmGrain・DepthOfField（奥行きの prepass を自分で足す）・Fxaa・Custom）・z の帯の境目・`Param` で数を渡す・`App.withPostStack`・`post.json` とエンジンの schema・`Quality` | (1) lamplighter の写しを S1a に移して **0 px**（回帰の錨）。錨の Stack は互換の欄だけで組む: `AcesNarkowicz({ whitePoint = 4.0, saturationAfter = 0.06 })`（トーンマップの後の足し算の彩度）・`DepthOfField.DepthBand`（ゲームが渡す奥行きの絵の 0.5 を中心とする帯）・Quality は `Fixed`（Bloom の taps と縮みをスパイクと同じ値に固定）。(2) 許す差の表（§5）で gl-parity に 2 場面。(3) PC で `FLIX_GE_NO_VSYNC=1` のコマの時間の p95 と cpu の ms の前後の差を出す。(4) eval 2 題・早見表 2 行 | 6〜9 時間 |
| **S1b** | 読む所で線形へ戻す（§6.2）・`Field.Lut3d`（2D に並べた 3D の LUT。NEAREST で読み中で補間・CPU と同じ重み。絵は engine の fpkg の中に入れ、engine が登録する組み込みの絵（`pp_` と同じ予約の名前・project.json の textures への登録は要らない・CPU の texEnv と web の書き出しにも engine が載せる））・Blender が書き出した LUT で `AgX`（look つき）・`KhronosNeutral`・`Filmic`・Blender の式の ColorGrade・preset 8 つの値の決め直し（Blender の手本と並べて人が見る） | (1) 曲線の門（§6.3）: 最大 2/255。(2) 露出の門。(3) preset ごとに Blender と並べた 1 枚を人が見る。(4) スマホの頁の数（§7.1） | 8〜12 時間（+ 人の目 1〜2 時間） |
| S2 | 式の木: `Field.Let`・`Field.Taps`・`Field.ScreenUv`（S3 の前提）→ `Field3`（vec3）・`Shade.Vec`。生成器（GLSL・WGSL）・`ShaderEval`・`ShaderJson`・schema。`LightModel3d` の生成器と部品を共有する一歩（§4.2） | 既存の shader.json と後がけの絵が前後で 0 px・古い JSON はそのまま読める・WebGPU の pipeline を作る時間と `eqSpec` の時間の前後 | 6〜9 時間（let・taps 4〜5・vec3 3〜4） |
| S3 | prepass（`Scene3d.Output.DepthNormal`）を本体へ（法線の詰め方は octahedral を検討）・`AmbientOcclusion`（S2 の taps・落ち方を「距離の中で当たったか」に寄せる・画面の外の点を数えない・奥行きで縁を残すぼかし）・CPU は Approx | AO 無しの絵が 3 描き手でバイト不変・許す差の表の線・Blender の Cycles との相関と差の p95 を **EEVEE からの相対の線**で（相関 ≥ EEVEE と Cycles の相関 − 0.03・p95 ≤ EEVEE の p95。§1.4 では 0.853 − 0.03 = 0.82・0.392）。内部の係数 1.4 と factor の較正は 1 場面・1 カメラの数なので、pbr_room でもう 1 場面確かめるまで仮・スマホの数 | 8〜12 時間 |
| S4 | 空とかすみ: 太陽の円と大気の色の空（`Scene3d.Sky.Physical`）・高さのかすみ・光の筋（`LightShafts`・奥行きの prepass で遮る）・雲（空に 2D の fbm の層） | Blender の Sky Texture（Multiple Scattering）と並べた色の差（K の D 節）・光の筋は Neighborhood | 8〜12 時間 |
| S5 | 水: 材質の出口に法線（`Out.Surface{ albedo, normal, roughness, emission }`）・法線マップの uv の倍率とずらし・画面の座標で色の Pass を読む（屈折）・平面の映り込み。前提: §6.2 の残るずれ（半透明の blend が画面の値のまま） | 時刻を変えた 3 枚・Blender の Principled BSDF（transmission）と並べる | 10〜14 時間 |
| S6 | 影: 光の大きさで柔らかさ（Blender の light の Radius・PCSS）・太陽の段（cascade 2〜3）・点光源の影 1 本 | 影の端の幅を Cycles と並べる・gl-parity・スマホ | 10〜14 時間 |
| 後 | MRT（prepass の draw call が数千本の場面で効いてから）・TAA・モーションブラー（GpuOnly）・SSR | — | — |

段ごとに: レビュー役 1〜2 回（80 点・必須が直っていれば GO）・`make gl-capture-check` の既存の絵の不変・テンプレの reference-check・早見表と eval・リリースは区切りで。
Studio（別のリポジトリ）の preset の見せ方（継いだ値と上書きの区別・書かない欄を保つ）は S1a の後に Studio 側の仕事として 2〜3 時間【推】。


### 3.0 進める順（人の決め 2026-11-17）

人が「手間の割に見返りが大きい順」を了承した: **S1b 後半（自前の AgX・preset の決め直し） → S2（式の木。S3 の前提） → S3（AO） → SSR**。
SSR は S3 の奥行きと法線の絵を使い回すので、S3 のすぐ後に「後」の行から前へ出す。

HD-2D（`plans/engine-hd2d.md`）の下準備も同じ列に入れる（人の言葉「HD-2D に必要なものは事前に作っておこう」）:
- S2 の後・S3 の前に、PostStack の部品 2 つを足す: **TiltShift**（`DepthOfField.TiltShift`・hd2d の E2）と **画面の歪み**（`Distortion`。時間で動くノイズで場面の絵を読む座標をずらす 1 Pass。熱のゆらぎ・水の中・魔法に使い回す。`Field.ScreenUv` を使うので S2 の後）。
- PostStack の外の HD-2D の下準備（ビルボードの影 E1・mip の上限 E4・画素スナップ E5・点光源の 8 本の上限の確かめ）は、この列と別の担当で並べて進める（触るファイルが重ならないため）。

その後の順の推し【推】: S6 のうち光の大きさで影の縁をぼかす所 → S4（空とかすみ・光の筋） → TAA → S5（水）。リアルタイムの GI は焼き込みとプローブ止まり。

### 3.0.1 cat-garden から取る物の順（人の決め 2026-11-17・「お任せ」）

元は https://github.com/BubbleBrainBB/awesome-fable-5.2/tree/main/cat-garden（自前のパストレーサーで 1080p・110 秒を 1 コマ 3.3 秒で描いたオフラインのムービー）。
描き方そのものは取らず、1 コマの時間に関係しない物だけを取る。3 つのスパイク（どれも worktree の枝・engine は無改修）の相性と手間で順を決めた。どれも engine の拡張なので、作る前に段ごとに相談する。

| 順 | 段 | 中身 | 相性 | 手間 | スパイク |
|---|---|---|---|---|---|
| 1 | **S1c レンズの小物**（S1b の後・S2 の前） | PostStack の面に時刻とコマ番号を配る・`CustomPass` に Param・色ずれを本編の面に・フィルムグレインを present の面（Fxaa の後）に・`ExposureAdaptation`（ゲームが狙いの明るさを決める露出の追い方） | 65〜78 | 12〜20 時間 | 枝 `worktree-agent-a136923d1c3615a98` の `spikes/lens-post/` |
| 2 | **カメラの頭の動き**（engine_world・HD-2D のスパイクの前） | `SpringInterp`（2 次のバネ）・`Curve.monotoneCubic`・`HeadBob`・`CameraAim`。注目の台本はゲームの側。ロールは別の相談 | 64 | 5.5〜7.5 時間 | 枝 `worktree-agent-a098f5187672e7b1c` の `spikes/camera-rig/` |
| 3 | 樽型の歪み（S2 の後の TiltShift・Distortion の段） | Panini Projection と見比べてから、カメラの射影の欄か PostStack かを決める | 42 | 12〜20 時間 | 同じ `spikes/lens-post/` |
| 4 | 植物と風（S3 の後） | `Mesh3d.fromArrays` で葉の面を組む `PlantMesh`・頂点を時刻で動かす `Scene3d.Wind3d`（今は時刻が頂点の段に届かない）・拡散の透過 | 63 | 植物 5〜8・風 12〜18・透過 4〜6 時間 | 枝 `worktree-agent-abcfae2ad7b307740` の `spikes/foliage/` |
| 後 | 絵から測る自動露出（TAA と一緒に）・楕円の絞り（DoF を点で撒く形にした時）・モーションブラー（入れない推し） | — | — | — | — |

1 の時刻の口は §3.0 の Distortion（熱のゆらぎ）と共用、`ExposureAdaptation` は HD-2D の入りの白飛び（plans/engine-hd2d.md §3.2）にも使う。2 は HD-2D の追従と寄り（同 §3.2.7 の 1）にも使う。

### 3.1 最初の段に S1 を推す理由【推】

物差し: (1) 何本のゲームの絵が変わるか (2) 描き手に入るか (3) 正解の絵と比べられるか (4) スマホの値段。

| 候補 | (1) | (2) | (3) | (4) |
|---|---|---|---|---|
| **S1 トーンマップ（AgX）・露出・ブルーム・色の仕上げ** | 3D のゲーム約 10 本（今は手書き）と、これから作る 3D | 入らない（S0 だけ CPU） | Blender の view transform と LUT で 1 対 1 | 全画面 2〜3 回分。§7.1 |
| AO | 3D の部屋・町 | 入る（prepass） | Cycles と相関 0.8（§1.4） | 重い（§7.1） |
| 空・かすみ | 屋外だけ | 空の式は木の外 | Blender の空 | 軽い |
| 柔らかい影 | 3D 全部 | 入る（3 描き手に手書き） | 近い | 中 |

テンプレ 4 本は 2D（ドット絵）で、AgX を掛けると色票が崩れる（写実でない絵は物差しの外・K の D5）。S1 が効くのは 3D の場面に限る。
トーンマップが Blender と同じ曲線になると、Blender で作った glb と lightmap の色が Blender の画面の色に近づく（今は HDR の Pass が画面の値で、露出 −0.6 で合わせている。K の A4）。

---

## 4. pub API の増減（名前の案。型検査はしていない）

### 4.1 S1 で足す物

```flix
mod PostStack {
    /// 後がけの全部の欄（Godot の Environment・Unity の Volume と同じく、効果ごとの欄を持つ値 1 つ）。外から作らせない。
    pub type alias Stack = StackImpl
    pub def preset(p: Preset): Stack

    // 欄を替えた新しい値を返す（Scene3d.Material3d と同じ流儀）
    pub def withExposure(stops: Float64, s: Stack): Stack                       // 必ずある欄
    pub def withViewTransform(v: ViewTransform, s: Stack): Stack               // 必ずある欄
    pub def withBloom(b: Option[Bloom], s: Stack): Stack                       // threshold・smoothness・size・strength
    pub def withColorGrade(c: Option[ColorGrade], s: Stack): Stack             // lift・gamma・gain（中立 1）・saturation（中立 1）
    pub def withVignette(v: Option[Vignette], s: Stack): Stack                 // strength・inner・outer・center
    pub def withFilmGrain(g: Option[FilmGrain], s: Stack): Stack               // amount・rate
    pub def withDepthOfField(d: Option[DepthOfField], s: Stack): Stack
    pub def withFxaa(on: Bool, s: Stack): Stack
    pub def withCustom(c: List[CustomPass], s: Stack): Stack                   // 複数可（後の物が勝つ、の外）
    pub def withQuality(q: Quality, s: Stack): Stack

    pub enum ViewTransform { case Standard  case AgX(AgxLook)  case KhronosNeutral  case Filmic  case AcesNarkowicz({ whitePoint = Float64, saturationAfter = Float64 }) }   // AcesNarkowicz は今のゲームとの互換（Blender の門の外）
    pub enum AgxLook { case Base  case Punchy  case Greyscale  case HighContrast  case MediumHighContrast
                       case MediumContrast  case MediumLowContrast  case LowContrast }          // Blender 5.2.3 の Look の名前（S1b で版の名前を確かめる）
    pub enum DepthOfField { case Physical({ focusDistance = Float64, fStop = Float64 })     // m・Blender の Camera の DoF
                            case DepthBand({ focusDistance = Float64, band = Float64, soft = Float64, blur = Float64 })   // 互換: ピントの奥行きを中心とする帯（今のゲームの形）
                            case TiltShift({ row = Float64, band = Float64, blur = Float64 }) }  // 画面の行で決めるピント（hd2d_lab）
    pub enum Quality { case Auto  case Low  case Medium  case High  case Fixed({ bloomTaps = Int32, bloomScale = Float64 }) }   // Auto = 画面の区分から（§7.1）・Fixed は錨と移行用
    pub enum Msaa { case Off  case X4 }                                    // WebGPU は 1 か 4
    pub type alias CustomPass = { name = String, at = CustomAt, spec = ShaderDoc.Spec, reads = List[Read], scale = Float64 }
    pub enum CustomAt { case BeforeBloom  case AfterViewTransform }
    pub enum Read { case SceneLinear  case SceneDepth  case SceneNormal  case Pass(String) }   // 読める物と、要る prepass の宣言（engine の Input と字を分ける）
    pub enum Preset { case Neutral  case DuskOutdoor  case NightOutdoor  case SunnyCity  case EveningBeach  case Cave  case NightCorridor  case TorchRoom }
    pub enum DebugView { case Final  case Linear  case Bloom  case Depth  case Normal  case Occlusion }
    pub enum Issue { ... }                                                  // §7.2

    pub def load(path: String): Result[JsonError, Stack] \ Fs.FileRead     // post.json
    pub def loadOr(fallback: Stack, path: String): Stack \ Fs.FileRead     // fail-open（Log.fellBack）
    pub def issues(s: Stack): List[Issue]
    pub def withDebugView(v: DebugView, s: Stack): Stack

    /// 低い口（App を通さない人）。計画と、world の帯の代わりに置く面を 1 回で返す。
    pub def build(input: BuildInput, s: Stack): { plan = Render.PassPlan, present = Render.PlacedItem }
    pub type alias BuildInput = { size = Vec2.Vec2, clear = Color, world = List[Render.PlacedItem], msaa = Msaa }
}
// App の欄（Bevy の camera の component に当たる）。View は world の帯の items を返すだけ。
App.withPostStack(w -> PostStack.Stack \ ef)
// Render（低い口の合わせ）
Render.mergePassPlans(a: Render.PassPlan, b: Render.PassPlan): Result[List[PassPlanIssue], Render.PassPlan]   // （新）名前が衝突しない時だけ
// Scene3d（場面の性質。DoF・AO・後の光の Radius が同じ物を読む）
Scene3d.withUnitsPerMeter(k: Float64, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd                       // （新）既定 1
```

- 欄を持つ閉じた型にしたので「Tonemap が無い・2 つある」は型で起きない。`ViewTransform` と `Exposure` は必ずある（Blender も常に何かの view transform を掛ける）。
- **3D の場面の元は 1 つ**: prepass は world の帯の items の中の `Render.Item.Scene3d` から作る（`scene3d` を別に渡さない）。
  1 つなら全画面でも矩形でもその場面・その矩形で作る。2 つ以上なら一番大きい矩形の物を使い `Issue.SeveralScenes` を 1 回知らせる。0 なら DoF の `Physical` と AO は掛けずに `Issue.NoScene3d`。
- **単位**: 場面の性質として `Scene3dCmd` の欄に置く（`Scene3d.withUnitsPerMeter`・既定 1 = glTF・Blender と同じ）。DoF の focusDistance・AO の distance・後の光の Radius は m で受け、PostStack は prepass の元の場面からこの値を読む（`App.withPostStack` の道でも言える）。fps3d_lab の家具（1 m = 16）は 16。§10 の 6。
- `Preset.Neutral` が「Standard・露出 0・ほかは無し」（別の `neutral()` は置かない）。
- 名前: `PostStack` は Unity の Post-processing Stack と同じ言い方。既存の `PostProcess`（低い部品: トーンマップの式・FXAA・luma）との使い分けは、`PostProcess` の頭の doc と早見表に 1 行（「画面全体の後がけは PostStack・式の部品が要る時だけ PostProcess」）。
  効果の enum を作らない（Flix の effect と字が重なる・欄の型で足りる）。

### 4.2 S2・S3 で足す物

```flix
// ShaderDoc（S2）
Field.Let({ name = String, value = Field, body = Field })              // 読む点の中の局所の束ね（欄名 in は避ける: bin/fge flix-reserved で確かめる）
Field.Taps({ points = List[Vec2.Vec2], scale = Vec2.Vec2, of = Field, combine = Combine })   // 決まった点で of を読み、足すか平均する
Field.TapOffset({ axis = Axis })                                       // Taps の中の今の点
Field.ScreenUv({ axis = Axis })
Field.Lut3d({ name = String, size = Int32, r = Field, g = Field, b = Field, out = TexChan })   // S1b
pub enum Field3 { case Make(Field, Field, Field)  case Tex3({ name = String })  case Add(Field3, Field3)  case Sub(Field3, Field3)
                  case Mul(Field3, Field3)  case Scale(Field3, Field)  case Mix(Field3, Field3, Field)  case Normalize(Field3)  case Ref3(String) }
Field.Dot(Field3, Field3)  Field.Length(Field3)  Field.Comp({ of = Field3, axis = Axis3 })  Shade.Vec(Field3)
// Scene3d（S3）
Scene3d.Output.DepthNormal({ near = Float64, range = Float64 })        // ゲームは直に使わず PostStack が使う
```

- `Field3` を別の enum にするのは、スカラーの所に vec3 を渡す取り違えを型で止めるため（`LightModel3d.Vec3Expr` と同じ分け方）。
  3 本目の木にしないために、S2 で GLSL・WGSL の書き出しの部品（vec3 の算術・let・輪）を `LightModel3d.Codegen` と共有する（分析の「式の木を 1 本へ寄せる」の一歩）。完全な 1 本化はこの計画の外。
- JSON は `{"kind":"vec3", ...}`・`"let"`・`"taps"` を足し、古い形はそのまま読む。

### 4.3 消す・寄せる物

| 物 | 扱い |
|---|---|
| `App.withPasses` | 使用 0（分析 §3）。消す（`forbid.json` で `withPassPlan` へ）・`Light.lightMapPass` の doc の「App.withPasses へ」も替える |
| `PostProcess.defaultExposure`（+0.4） | 8bit の画面の値向けの既定で 3D の HDR と噛み合わない（K の A4）。PostStack の既定は 0。古い口は残し doc で PostStack へ |
| `PostProcess.Tonemap.AcesFitted` | 中身は Narkowicz の式（Hill / MJP の ACESFitted とは別）。PostStack では `AcesNarkowicz`（Blender の門の外・今のゲームとの互換用）と呼ぶ。`PostProcess` の名前は据え置き、doc に書く。Reinhard は PostStack に出さない |
| `PostProcess.tonemapped` / `tonemappedWith` / `fxaaSpec` | 低い口として残す（PostStack の中身が使う） |
| reference-3d.md の「Pass の並びの手本」・AGENTS.core の後がけの 2 行 | PostStack の手本と行に置き換える |
| ゲームの `PostView.flix`・`LookDoc` の後がけの欄 | 移すかはゲームを触る時（強制しない）。lint は「View で `tonemappedWith` を直に組んでいる」を知らせる（止めない） |

---

## 5. CPU の描き手（SoftRaster）と絵を合わせる決まり

`docs/backend-parity.md` の決まりを後がけへ広げる。**効果ごとに 3 つのどれかを宣言し、許す差の表で数を守る。**

| 区分 | 何が入るか | 線 | 測る組と道具 |
|---|---|---|---|
| **Pointwise**（画素ごとの式） | Exposure・ViewTransform（LUT は NEAREST で読み中で補間・CPU と同じ重み）・ColorGrade・Vignette | ±1/255 | GL − CPU・WebGPU − CPU を gl-parity の行で（落とす行） |
| **Neighborhood**（近くを読む） | Bloom・DoF・AO・LightShafts・Fxaa・FilmGrain（hash は float32 と float64 で割れるので、NEAREST で読む noise の絵に替える） | 効果ごと: 奥行きの段差（法線と奥行きの絵の縁）を除いた画素で「差 > 8/255 の割合」と「ぼかした後の平均と相関」。初めの線は S1a・S3 で 3 場面 × 2 解像度を測って決める（今の 1 場面の数: 最後の色 1.2〜1.6%・暗さ 6.6〜12.2%） | 3 組（WebGPU − GL・WebGPU − CPU・GL − CPU）。gl-parity の近似の行は今は「数を出すだけ」なので、`bench/webgpu_v1/tolerance.tsv` と同じ形の表を足して落とす |
| **GpuOnly** | MSAA・TAA・モーションブラー・（後）SSR | CPU は掛けずに `SoftRaster.dropped` に名前を出す | 今の MSAA と同じ |

- 描き出し（画面なし）の `Quality.Auto` は `Medium` に固定（gallery の絵が機械で変わらない）。
- CPU の時間の線: 描き出し 1 枚に S1 の Stack で +200 ms まで（S0 の後の数で決め直す）。AO の CPU は S2 の taps で木の評価を減らす。
- **Blender の手本との線**は別に持つ（§6.3）。描き手どうしが合っていても Blender と離れていれば直す対象。

---

## 6. Blender にそろえる

版は Blender 5.2.3（`/nix/store/2rqcqsp3ww61r0qw46izbppssz3bnqxg-blender-5.2.3/bin/blender`）に固定する。名前は UI の語と Python の欄で書く。
下の表の Blender 側の式と欄は S1b の最初に Blender のソースと UI で確かめる【未確認の所あり】。

### 6.1 名前と数の対応

| PostStack | Blender（UI / Python） | 数の意味 | 正解を取る相手 |
|---|---|---|---|
| `withExposure(e)` | Color Management → Exposure（`scene.view_settings.exposure`） | 線形に 2^e。ブルームの後（§2.1） | Blender の Color Management（式が同じ） |
| `ViewTransform` | View Transform（`view_settings.view_transform`）: Standard・AgX・Khronos PBR Neutral・Filmic | 曲線そのもの（LUT） | 同上 |
| `AgxLook` | Look（`view_settings.look`） | 同じ名前 | 同上 |
| `ColorGrade.lift/gamma/gain` | compositor の Color Balance（Lift/Gamma/Gain） | **中立は 1**。Blender の式（lift は 2 − lift で効き、中で linear → sRGB → 戻すの往復）に合わせる【未確認: ソースで式を写す】 | Blender の compositor |
| `ColorGrade.saturation` | Hue/Saturation/Value の Saturation | 掛け算・中立 1（今のゲームの「足し算・中立 0」とは別。移す時に換算） | 同上 |
| `Bloom.threshold/smoothness/size/strength` | compositor の Glare（Bloom）の Threshold・Smoothness・Size・Strength | threshold・strength は同じ意味。size はぼかしの広さでカーネルは別物 | Blender（Neighborhood の比べ）。4.x の途中で Glare の欄の意味と型が変わったので 5.2.3 の物で【未確認】 |
| `AmbientOcclusion.distance/factor` | Cycles の AO（World の `light_settings.distance`・AO 節の Distance） | distance は m（§1.4・内部の係数で吸収）。factor 1 = 同じ distance の Cycles の平均 | Cycles（EEVEE は 4.2 以降の horizon scan で、それ自体が近似） |
| `DepthOfField.Physical{focusDistance, fStop}` | Camera → Depth of Field（`camera.data.dof.focus_distance`・`aperture_fstop`） | 薄いレンズの式でぼけの半径へ。センサーは `sensor_fit` に合わせる（エンジンは縦の画角を持つので VERTICAL・`sensor_height` 既定 24 mm【未確認】）。奥行きの Pass は 16F（8bit の灰色では m に戻すと粗い） | Cycles（物理のカメラのぼけ）。EEVEE は参考に並べる |
| （S6）影の柔らかさ | Light → Radius（`shadow_soft_size`） | 光の大きさの m | Cycles |
| （S4）空 | World → Sky Texture（Multiple Scattering） | 太陽の高さ・空気の濃さ | Cycles |

画面空間の効果（DoF・AO の見え方）は EEVEE の方が近い相手になる事もあるが、**正解の絵は物理の答え（Cycles・Color Management の式）に取り**、EEVEE は参考に並べる。

### 6.2 トーンマップの入力を線形にする（S1b）

今は HDR の Pass の値が「画面の値（sRGB の曲線で縮めた値）」で、トーンマップはその上に掛かる（K の A4・露出 −0.6 の理由）【確: K】。
Blender の view transform は線形のシーンの値に掛かるので、**PostStack は場面の Pass を読む所で線形へ戻してから** §2.1 の 1〜8 を掛ける。描き手と 3D の出口は触らない。

- 結果: 同じ露出 0 で、今の手書き（露出 −0.6 の ACES）と絵が変わる。今のゲームを S1b の Stack へ移すと 0 px にはならない（錨は S1a の `AcesNarkowicz` の preset で持つ）。
- **残るずれ（Blender と合わない既知の差）**: 2D の半透明の重ね・3D の半透明（ガラス・水）の blend・MSAA の resolve は画面の値のまま混ざる（K の A5: 白 50% で 0.5 と 0.735）。
  場面の Pass を線形で持つ（描き手の出口を替える）のは別の段で、S5（水）の前提に入れる。

### 6.3 Blender の絵を正解にする門（pbr_room の手本の作り方を使い回す）

土台は `~/Documents/flix_ge_workspace/pbr_room/modeling/render_ref.py`（Cycles・CPU・128 サンプル・denoise・960×540・座標 `ep(x,y,z) = (−x, −z, y)`・`sensor_fit = VERTICAL`）と K の D 節、
スパイク (b') の `blender_ao.py`（エンジンの場面を OBJ に書き出して Blender で組み直す・material override で AO だけを描く）。
手本の絵はリポジトリに入れず、作るスクリプトと SHA を入れる。Blender の設定は Dither 0・Display Device sRGB・Look と版を固定。

| 門 | 何を比べるか | 線 | いつ |
|---|---|---|---|
| 曲線（S1b） | 同じ式で作る帯の絵（明るさ 2^−8〜2^4 × 色相 12 × 彩度 3。**エンジンは EXR を読めないので、Blender の Python とエンジンの Field で同じ式から作る**）を、Blender の view transform ごとの PNG と PostStack の CPU の出力で | 最大 2/255 | S1b の門・Blender の版を上げた時 |
| 露出（S1b） | 同じ帯に Exposure ±2 | 最大 2/255 | 同上 |
| LUT の書き出し | Blender の Python で、log2 で詰めた格子の絵（33³）を view transform + look に通して PNG にし、エンジンの `Lut3d` の絵にする（**LUT は Blender が書き出す**。式を自分で書いて近似しない） | 書き出した LUT で曲線の門を通る | S1b・版を上げた時 |
| AO（S3） | bench/scene3d の部屋を `blender_ao.py` で組み直し、Cycles の AO と PostStack の AO の暗さ | 相関 ≥ 0.85・差の p95 ≤ 0.25（§3） | S3 の門 |
| 場面（S4 以降） | pbr_room・bench/scene3d の部屋の全部の効果（Cycles・同じ光） | 線形の輝度の相対差の中央値と 95 パーセンタイル（K の C4） | 知らせるだけ（光の単位の計画の後でゲート化を決める） |

- Blender の OCIO の設定（AgX・Filmic の LUT と行列）を書き出した LUT をエンジンに入れてよいかは、ライセンスを S1b の最初に確かめる【未確認】。だめなら門を Standard・Khronos PBR Neutral（式で書ける）と自前の AgX に絞る。
- Neighborhood の効果（ブルーム・AO）は Blender とカーネルが違うので、相関と差の p95 で「同じ向きか」を見る（0 px ではない）。写実でない絵（ドット絵・トゥーン）はこの物差しの外。

### 6.4 光の単位の計画との順

場面を Blender と比べた時の差の大半は光の式にある（拡散に 1/π が無い・逆二乗でない・環境マップが 8bit。K の要約 1〜4）。
**後がけ（S1〜S3）の門は「後がけだけ」を比べる形**（曲線の門は帯の絵・AO の門は AO だけの絵）にして、光の式の差を混ぜない。S4 以降の「場面」の門は、光の単位の計画（K の案 (i)）が入るまで知らせるだけ。順は §10 の 8。

---

## 7. スマホの時間の予算と AI から見た書き味

### 7.1 予算（Galaxy S24 Ultra・Chrome・WebGPU。今日の実測: fps3d の部屋 60 fps・cpu 12.6 ms）

ブラウザ版の canvas は CSS の大きさ × devicePixelRatio（`engine_web/js/fge-web.js`）で、窓の画素の Pass はほぼ端末の画素（FHD+ 2340×1080 なら 2.53 MP = 960×540 の約 4.9 倍）【確: js / 端末の既定の解像度は未確認】。

見込みの計算（AO の例）【推】: PC の GL で SSAO の分は 0.865 − 0.393 = 0.47 ms（960×540・暗さは 1 辺半分 = 480×270・12 点）。
Adreno 750 を M4 Pro の 4〜6 倍遅いとし、画素を 4.9 倍とすると **9〜14 ms**（1 辺半分のまま）。60 fps（16.7 ms）の残りは 4 ms ほどなので入らない。
→ **品質は「読む絵の大きさを画素の数で頭打ち」にする**。Low の AO:
- prepass も 0.13 MP（480×270）で描く: PC の GL で prepass は +0.10 ms（960×540・0.52 MP）→ 0.13 MP なら約 0.03 ms × 5 ≈ 0.15 ms。wasm の draw call は物の batch の数だけ倍（PC の submit で +0.2 ms → スマホ 10〜15 倍で +2〜3 ms の CPU。**CPU の側が先に詰まる**【推】。staticGroup の render bundle を prepass でも使い回すのが前提）。
- 暗さの Pass は 0.13 MP・8 点・ぼかしは暗さの Pass の中で 1 回: 暗さの分（PC 0.47 ms のうち最後の面を除いた約 0.3 ms）× 8/12 × 5 ≈ 1.0 ms。
- 暗さを掛けるのは本編の面（§2.1 の順の中で 1 回だけ全画面を描く面）の中に畳み、全画面の Pass を 1 つ増やさない（スパイクの最後の面は TexBlur 8 点を全画面で読み、そのまま縮めると 4 ms 級になる）。本編の面の上乗せは 1 回の読み（約 0.1〜0.2 ms【推】）。
- 合わせて GPU 約 1.3〜1.5 ms・CPU +2〜3 ms【推】。

| 区分 | 予算（GPU） | 中身 |
|---|---|---|
| S1 の標準の Stack | 2.5 ms | 明るい所を 1 辺 1/2（上限 0.5 MP）・ぼかし 2 回 1/4・本編 1 回（ここに LUT の読み 8 回 × 3 チャンネルが入る・S1b）・FXAA 1 回 |
| AO（S3） | Low 1.5 ms / High 3 ms（PC 向け） | Low = 0.13 MP まで・8 点。スマホ（`Display.SizeClass.Small`）の `Auto` は Low |
| 空・光の筋（S4） | 1 ms | 光の筋は 0.13 MP まで・16 点 |
| CPU（wasm） | +1 ms まで | Spec は構造の鍵が変わった時だけ作る（§2.3） |

- 値の意味は品質で変えず、点の数と読む絵の大きさだけを変える。
- 測り方: PC は `FLIX_GE_NO_VSYNC=1` でコマの時間の p95 と cpu の ms の前後の差（60 fps は垂直同期に張り付き上乗せが見えない）。
  スマホは timestamp query が無いので、bench/scene3d の field の物の数を上げて 60 fps を割る数を、Stack あり・なしで比べる（`make bench-web BENCH=scene3d ARGS='scene=field&n=…'`。人が端末で開く）。
- WebGL2 に戻った時に Rgba16F を描き先にするには `EXT_color_buffer_float`（か half float）が要る。無い時は Rgba8 + `Standard` に落とし 1 行言う。iOS Safari は【未確認】。

### 7.2 AI から見た書き味

| 条件 | 案 |
|---|---|
| 選ぶ物が少ない部品 | `PostStack.preset(..)` 1 つから始め、要る欄だけ `with*`。順・Pass・描き先・Spec・単位の換算は言わない。`Custom` は 1 つの逃げ道 |
| 見た目の名前から引ける preset | `Preset` 8 つ（visual-dict の reference-3d の行の名前と同じ）。`PostStack.preset(Preset.DuskOutdoor) \|> PostStack.withExposure(-0.3)` |
| 数の範囲がスキーマにある | エンジンが `docs/post.schema.json` を持つ（min・max は §1.1 の使われた幅と Blender の UI の範囲。例 exposure −4〜+4・bloom.strength 0〜2）。ゲームごとに決め直さない |
| 間違えた組み合わせを止める | 型: `Stack` は外から作れない・ViewTransform は必ず 1 つ・AgX の look は AgX にだけ付く・DoF は `Physical` か `TiltShift`・`Msaa` は Off か X4・`Field3` とスカラーは別。`PostStack.issues`（make の lint・F3・描き出しの時は止める）: `NoScene3d`（DoF の Physical / AO があるのに 3D が無い）・`SeveralScenes`・`HdrNeeded`（Bloom があるのに場面の Pass が Rgba8 で 1 を超えない）・`FxaaOnScaledPass`・`ReservedPassName`（`ps_`）・`SpecRebuiltEveryFrame`（構造の鍵が毎コマ変わる） |
| 途中の絵を見る | `PostStack.withDebugView(DebugView.Bloom)` を `make render` で 1 枚（Bevy の debug と同じ考え）。`HeadlessRender.renderPassImage` を早見表へ |
| 手本 | 3D と後がけの手本を bench/scene3d の部屋に（`App.withPostStack`）。テンプレに 3D は無いので、3D のテンプレを足すかは別に人と決める |
| eval | S1a: 「夕方の町の 3D に写真のような仕上げ」・S1b: 「Blender で見た色と違う（露出と view transform）」 |

---

## 8. Doc（`post.json`）のスキーマ

`/doc-design` と `docs/doc-conventions.md` の外形（`version`・`title`・sections 方言）。値だけを持ち、効果の式は持たない（振る舞いはコード）。
名前は `post.json`（場面ごとに替えるなら `<名前>.post.json`）。schema は engine の `docs/post.schema.json`（fx・sprite と同じ置き場）で、ゲームの `editor.resources[]` から指す。

```json
{
  "version": 1,
  "title": "夕方の町の仕上げ",
  "preset": "DuskOutdoor",
  "quality": "Auto",
  "exposure": -0.3,
  "viewTransform": { "kind": "AgX", "look": "Base" },
  "bloom": { "threshold": 1.0, "smoothness": 0.5, "size": 0.04, "strength": 0.6 },
  "vignette": { "strength": 0.3 },
  "colorGrade": null,
  "depthOfField": { "kind": "Physical", "focusDistance": 8.0, "fStop": 2.8 }
}
```

- `preset` が出発点で、**書いた欄だけが上書き**。上書きは効果の欄ごとの深い merge（`"vignette": { "strength": 0.3 }` は strength だけ替え、inner・outer・center は preset の値）。`kind` を持つ欄（viewTransform・depthOfField）は、**kind が preset と同じ時だけ欄ごとに混ぜ、違えば丸ごと替える**（書いていない欄は新しい kind の既定）。
  `null` はその効果を外す。コードの `with*` は効果ごとに丸ごと替える（Doc と違う所なので doc に書く）。
- 欄は効果ごとの組に入れて、一番上のスカラーを 5 つ以内に保つ（目安の 30 を超えない）。lift・gamma・gain は 1 を超えるので色（hex）でなく `[r, g, b]` の数で持つ。
- 読み方は `load`（Result）→ `loadOr`（fail-open・`Log.fellBack`）。知らない `preset`・`viewTransform`・`look` は既定へ落として 1 行言う。
- schema の `description` に Blender の欄の名前を書く（Studio のフォームでスライダー・保存で即反映）。Studio は継いだ値と上書きを分けて見せ、書いていない欄を書き戻さない（Studio 側の仕事・§3）【未確認: 今の Studio のフォームは全部の欄を書く】。
- 毎コマ変える数（ピント・場所ごとの明るさ）は Doc でなく View の `with*`（数は Param なので program は作り直さない・§2.3）。

---

## 9. 確かめていない事・危険

- WebGPU の GPU の時間（timestamp query を使う口が無い）・スマホの実機の値段（§7.1 は計算の見込み）・端末の canvas の画素数【未確認】。
- Blender の OCIO の LUT を書き出して入れてよいか（ライセンス）・Color Balance と Glare の 5.2.3 の式・AgX の Look の名前・センサーの辺【未確認】→ S1b の最初。
- vec3 の `eqSpec` と生成した shader の行の前後・Let と Taps を WGSL に出した時の pipeline を作る時間【未確認】。
- MRT が要る場面（draw call が数千本の prepass）【未確認】。
- 法線を x・y だけで持つと透視の端で z < 0 の面を取り違える（S3 で octahedral を検討）。
- 語彙が足りないとゲームは手書きへ戻る（fps3d_lab の 8 項目）。`Custom` で逃がし、2 本のゲームが同じ Custom を書いたら欄へ上げる。
- (a) の CPU と GPU の比べ（大きさが違う）・View Layer の AO の pass と AO 節が同じか【未確認】。

---

## 10. 人に決めてほしい事

1. **最初の段は S1（S0 → S1a → S1b）でよいか**【推】。AO（S3）を先にしたい場合は S2 の let・taps を前に置く。
2. **Exposure をブルームの後に掛ける（Blender の順）か、前に掛ける（Unity・Bevy の pre-exposure）か**【推: Blender の順】。前にすると threshold の意味が露出で変わらない代わりに、Blender の手本と順がずれる。
3. **トーンマップの入力を線形にする（§6.2）か**【推: する】。今のゲームの見え方とは変わる（移すかはゲームを触る時・`AcesNarkowicz` で今の見え方を残す）。
4. **Blender の曲線の門と、Blender が書き出した LUT を使うか**（Blender 5.2.3 を手元の門の道具にする・CI では回さない）【推: 使う・ライセンスを先に確かめる】。
5. 法線は**別 pass**（スパイク (b)・約 140 行）で始め、MRT は後か【推: 別 pass】。
6. **単位の決まり: 1 = 1 m（glTF・Blender の既定）を既定にし、違う場面は `Scene3d.withUnitsPerMeter` で言う**でよいか【推】。
11. **後がけを掛ける範囲を「View の全部・HUD は外」にする（§2.2 の案 A）**でよいか【推】。会話の窓などを HUD へ置く決まりになる（今のゲームで View に窓を描いている物は、PostStack に移す時に窓を HUD へ移す）。
7. **AO の掛け方**: 後がけで最後の色に掛ける（絵作りの近道・直接光と emission も暗くなる）か、材質の ambient と間接の項にだけ効かせる（Cycles・EEVEE と同じ・材質が画面の座標で AO の絵を読む口が要り S3 が 4〜6 時間増える）か【推: S3 は後がけで入れ、材質の ambient に効かせるのは光の単位の計画と一緒に】。
8. 光の単位の計画（K の案 (i)）を S1 の後・S3 の前に挟むか【推: S3 の後。後がけの門は光の式と切り離して測れる】。制約: 2 で Blender の順（Exposure がブルームの後）を選ぶと、K の案 (i)（光の側へ先に露出を掛ける Filament 式）とぶつかるので、光の単位の計画では露出を光に掛けず「Exposure の欄に EV100 から換算した stops を入れる」形に寄せ直す。S1b で決め直す preset の値も、光の単位の計画の後でもう 1 度動く。
9. スマホの既定の品質（AO は Low・ブルームは標準）と、Studio 側の preset の見せ方を S1a の後にやるか。
10. 外のゲーム（ws の約 10 本）の `PostView` を移すか・いつか【推: 触る時に】。

---

## 付録 A. スパイクの置き場

| スパイク | ブランチとコミット | 文書と数 | 絵（git の外） |
|---|---|---|---|
| (a) | `worktree-agent-acd506d76c0982810` `9f09894b` | `spikes/render-expression/a-poststack/` | `/Users/abab/Desktop/flix_game_engine/.claude/worktrees/agent-acd506d76c0982810/build/spike-poststack-shots/` |
| (b) | `worktree-agent-adda5afff61d0ee1a` `a3a81e0e`・`30d3d9fd` | `spikes/render-expression/b-ssao/README.md` | `/Users/abab/Desktop/flix_game_engine/.claude/worktrees/agent-adda5afff61d0ee1a/build/ssao-spike/` |
| (b') | 同 `ff3a3689` | 同 `blender_ao.py`・`aocompare.py` | 同 `build/ssao-spike/blender/`（エンジン \| Blender \| 差）・`fit/` |
| (c) | `worktree-agent-ad56639e9d8579117` | `spikes/render-expression/c-vec3/` | — |

## 付録 B. レビューの記録

- **1 回目: 68 点**。必須 12・推奨 13・任意 7。主な指摘と直した所:
  - M1 順と色の空間が無い・Blender は Exposure がブルームの後 → §2.1 の表・§10 の 2。
  - M2 後がけに通す物の境目（UI・Transition にも掛かる）・Pass の名前の衝突 → §2.2（world の帯・`ps_`）。
  - M3 `Input.scene3d` と App の口が噛み合わない → 3D の元は world の帯の items の 1 つ（§4.1）。
  - M4 Const だと毎コマ作り直し → 数は全部 Param（§2.3）。
  - M5 `with` は Flix の予約語 → 欄を持つ閉じた型と `with*`（推奨 R1 と一緒に）。
  - M6 Blender の Color Balance は中立 1・式も別 → §6.1 を直し、式は S1b で写す。
  - M7 view transform を 2/255 で合わせる道（LUT）が無い・エンジンは EXR を読めない → `Field.Lut3d` と Blender が書き出す LUT・帯の絵は同じ式から（§6.3）。
  - M8 CPU の 16F の 370 ms → S0。
  - M9 スマホの見込みの計算 → §7.1（9〜14 ms・画素の数で頭打ちの品質）。
  - M10 門が測れるか（gl-parity の近似の行は落ちない・60 fps は垂直同期）→ 許す差の表・NO_VSYNC の p95・負荷を上げる測り方（§5・§7.1）。
  - M11 言い過ぎ（6 本・0 px の持ち越し・テンプレに効く・WebGPU 2 行）→ §0・§1・§3.1 を直した。
  - M12 AO の掛け方と単位 → §10 の 6・7。
  - 推奨: R1 閉じた型・R2 型で止める（AgxLook・DoF の enum・Msaa）・R3 `AcesNarkowicz`・R4 S1a / S1b に分ける・R5 Doc（名前・title・深い merge・Studio・schema の置き場・load / loadOr）・R6 FilmGrain を Neighborhood へ・R7 版を固定・R8 センサーの辺・R9 線形化で残るずれ・R10 光の単位の範囲（§6.4）・R11 Neighborhood の線の決め方・R12 WebGL2 の 16F と描き出しの品質・R13 API の一覧 → 全部反映。
  - 任意: O1 `PostProcess` との使い分け・effect の字（enum を作らない）・O2 S2 を let / taps と vec3 に分ける・O3 生成器の部品を共有・O4 octahedral・O5 消す物の連鎖・O6 言い方・O7 `Look.None` → 反映（O7 は `AgxLook.Base`・欄名 `body`）。
- **2 回目: 78 点**（rev1 に対して）。必須 2・推奨 8。1 回目の必須は M2 を除いて直った（M1・M3〜M12）。rev2 で直した所:
  - N1（必須・M2 の残り）`ZBand` に world の底は無く、z で「world の帯」を切れない → §2.2 を「層で決める」に書き直し、案 A（View の全部に掛け、窓は HUD へ）を推した。Transition の帰結・案 B を取らない理由・§10 の 11。
  - N2（必須）S1a の 0 px の錨が rev1 の API で届かない（彩度がトーンマップの後・DoF が奥行きの帯・白の点が無い）→ `AcesNarkowicz({ whitePoint, saturationAfter })`・`DepthOfField.DepthBand`・`Quality.Fixed` を足し、S1a の門 (1) に錨の Stack の形を書いた。
  - P1 AO の見込みに prepass と draw call の倍化が無い・最後の面の根拠が無い → §7.1 に足し、暗さを本編の面に畳む形にした（CPU の側が先に詰まる見込み）。
  - P2 AO と光の筋は DoF の前 → §2.1 の順を AO → LightShafts → DoF → Bloom に。
  - P3 S3 の門の相関 ≥ 0.85 は無理筋 → EEVEE からの相対の線にし、係数の較正は仮と書いた。
  - P4 `unitsPerMeter` が App の道から言えない → `Scene3d.withUnitsPerMeter`（場面の性質）へ。
  - P5 LUT の絵の置き場 → engine の fpkg の組み込みの絵・予算の行に LUT の読みを足した。
  - P6 kind を持つ欄の merge → kind が同じ時だけ欄ごと・違えば丸ごと。
  - P7 Blender の順と K の案 (i) の衝突 → §10 の 8 に制約を足した。
  - P8 小物: DoF の正解の相手を Cycles にそろえた・`Render.mergePassPlans` を §4.1 に・`neutral()` を消し `Preset.Neutral` に・`Input` を `Read` に・history を読む効果が無い事を §2.2 に。
- 3 回目は取っていない（「レビューは最大 3 回・80 点以上で必須が直っていれば GO」の決まりに対し、2 回目の必須 2 つを直した所で止めた。点は 2 回目の 78 点のまま）。

## 11. 実装の記録（S0・S1a・S1b の前半）

枝 `worktree-agent-a2e50307607c366f3`。コミットは S0 `1d68d5a9`・S1a `bb87be73`・S1b 前半 `bd5e4c69` と、レビュー（1 回目 72 点）の直し。

### 11.1 S0 の門

- 遅さの元は `ShaderEval.hdrTextureOf` の 1 回の呼び出しの中の長い輪（JVM が途中から JIT しない）で、`SoftRaster.frozenHdr` が Java の stream で丸めて `hdrTextureOfHalves` に渡す形に直した。値は同じ。
- 測った物はスパイク (b) の prepass そのものではない（prepass はまだ本体に無い）。同じ形（3D の部屋を窓の画素の Pass に描き、本編でも描く・960×540・`FGE_SOFT_SERIAL=1`・12 回の中央値）で、
  Rgba16Float の Pass の上乗せ（Rgba8 の Pass との差）が **170〜350 ms → 約 40 ms**。門の「441 → 100 ms 以下」は prepass の 1 枚の数なので、S3 で prepass を入れた時に測り直す【未確認】。
  残る 40 ms は `fillClearHdr` と `drawSceneHdr` の画素ごとの組（tuple）で、門に要るなら同じ直し方で減らせる【推】。

### 11.2 設計からのずれ（§4.1 を実装に合わせて読む）

| 設計 | 実装 | 理由 |
|---|---|---|
| `DepthBand({ focusDistance, band, soft, blur })` | `range` を足した（band と soft は range に対する割合） | 奥行きの絵を PostStack が作るので帯の幅が要る。lamplighter の 0 px の錨 |
| `Quality.Fixed({ bloomTaps, bloomScale })` | `blurTaps` を足し、Fixed は縮みを design の解像度に対して取る（ほかは窓の画素） | 今のゲームの手書きの Pass と同じ大きさ（0 px の錨） |
| `BuildInput.msaa` | Stack の欄（`withMsaa`）。`withBackground`（場面の Pass を消す色）も Stack | App の道ではゲームが BuildInput を組まない |
| `build` は `{ plan, present }`・`PostStack.issues(s)` | `build` が `issues` も返す・`issues(s)` は無い | 問題の大半（3D の場面の数）は world を見ないと分からない |
| `Read.SceneLinear`・`DebugView.Linear` | `Read.SceneColor`・`DebugView.Scene` | Custom の BeforeBloom は描き手が書いた画面の値を読む（線形へ戻すのは本編の面） |
| Stack が組んだ Spec を持つ | 持たない。毎コマ動かす数（露出・ブルームとビネットの強さ・彩度・Physical のピントと F 値）は Param | Stack は毎コマ返る値。描き手は Spec を中身で比べる（重さは未計測・下の残り） |

### 11.3 先送りにした物（残り）

- S1a の範囲: FilmGrain（noise の絵を engine が登録する口が要る・LUT と同じ道）・TiltShift（使うゲームが無い）。
- S1b の後半の残り: AgX の Look（Punchy など。Blender の値を写さずには合わない）・Filmic（下の 11.6）・preset の値を人の目で決めること・スマホの数（§7.1・未計測）・ColorGrade と Blender の比べ（式は `colorbalance_lgg` を写したが未比較）。`Field.Lut3d` は LUT を配らないので作らない。
- 検査: `HdrNeeded`・`FxaaOnScaledPass`・`SpecRebuiltEveryFrame`・描き出しの lint で止める口・`bin/fge view` の匂い・「View で tonemappedWith を直に組む」の知らせ。ゲームの計画の `ps_` の Pass は実機で 1 行知らせるだけ。
- 中身の比べの重さ: 毎コマ新しい Spec を描き手が中身で比べる。wasm の CPU の予算（+1 ms）に効くかは bench/scene3d の POST=1 を web で測ってから。

### 11.4 Blender の LUT のライセンス（S1b の前に止めた所）

- Blender 5.2.3 の `datafiles/colormanagement/config.ocio` の頭は「See ocio-license.txt for details.」と書くが、その file は配られた Blender に入っていない。
  AgX の作り手の repo（EaryChow/AgX・sobotka/AgX）にも LICENSE が見当たらない。Blender の本体は GPL-3.0 以上で、engine は MIT。
- LUT（AgX・Filmic・Khronos Neutral の .cube）を engine の fpkg に入れてゲームへ配ってよいか分からないので、作る前に止めた（人の決定 4）。
- Standard と Khronos PBR Neutral は式で書ける（Neutral は Khronos の仕様の式）ので入れ、Blender の絵と比べる門を通した。

### 11.5 測った数

- lamplighter の写し（`build/ps-lamplighter`・git の外）: alley・night・arrival が S1a の前後で CPU 3 枚・WebGPU 9 枚・GL 9 枚ともバイト一致。S1b の後も AcesNarkowicz の道は変わらない。
- gl-parity: postStackLook 2,188 px（±4）・postStackDepthBand 547 px（±72・縁の帯）。上限 3,000・800。
- bench/scene3d（隠し窓・`FLIX_GE_NO_VSYNC=1`・240 コマ × 2 区間 × 2 回・負荷の高い機械）: 後がけなし frame p95 1.04〜1.63 ms → POST=1（DuskOutdoor）1.69〜3.33 ms。submit p50 0.31〜0.49 → 0.47〜1.02 ms・2D の draw call 0 → 5。
- 曲線の門（`TestPostStackBlender`）: Standard（露出 0・±2）・Khronos PBR Neutral（0・±2）が 2/255 以内。Neutral は Blender が log2 の 2^-9〜2^10 の LUT で 0 の成分を 2^-9 と読むので、暗い色で成分に 0 がある物（最大 6/255）は比べない。

### 11.6 S1b の後半（人の決め: Blender の LUT は配らず、AgX は公開の式で自前に組む）

- `ViewTransform.AgX`（Look は Base）: Rec.709 → Rec.2020・inset・log2 で中間の灰色の −10〜+6.5 stop を 0..1 に詰める・S 字の曲線（中間の灰色で傾き 2.4・
  両端は 1.5 乗の双曲線で 0 と 1 に届く）・2.4 乗で線形へ・outset・sRGB へ。inset と outset の行列は three.js（MIT）と Filament（Apache-2.0）が公開している物。
  ShaderDoc の `math1` に `log2` を足した（2^-40 で下切り）。
- Blender 5.2.3 の AgX との近さ（`TestPostStackBlender`・帯 468 点）: 灰色は全部 2/255 以内（曲線は合っている）。全部の点では露出 0 で 86%・+2 で 83%・−2 で 89% が 2/255 以内・最大 18/255。
  残る差は彩度 1 の原色の緑と青。順を「outset → 2.4 乗」に入れ替えると最大 35/255 に増える（python の写しで測った）ので、順ではなく行列の違いと見ている。
  Blender の config.ocio の inset と outset の数（LUT ではない）を使えば 2/255 に届く見込みだが、Blender 由来の値を持ち込まない決めなので使っていない（伺い事）。門は 80% と 20/255。
- Filmic は入れない: Blender の Filmic は LUT（spi1d）で作られていて、自前で組む元になる公開の式が無い。
- preset（Neutral 以外の 7 つ）は AgX にし、露出・ブルーム・ビネット・彩度は reference-3d.md の場面の行の値を線形の値に掛ける前提で置いた。人の目で見る前の値（bench/scene3d の `make presets`）。
- `withBackground` の既定は画面の地の色（実機は起動で project.json の clearColor・描き出しは `App.withScreenClear`）。
- `Quality.Auto` はスマホで Low（明るい所 1/4・読む点 8）。スマホの実機の数は未計測（`make bench-web BENCH=scene3d ARGS='post=1'`・`post=agx`）。
- 見比べの場面: bench/scene3d の `SCENE=orb`（暗い部屋の丸い卓に強く光る緑の球・ろうそく・赤い瓶・本）。`POST=standard|agx|neutral` で view transform だけを替える。

