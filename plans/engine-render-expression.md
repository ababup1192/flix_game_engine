# 3D の表現力を上げる仕組み — 後がけの値の列（PostStack）と、3D が出す名前つきの絵（prepass）

状態: 設計とスパイクだけ（engine の本体は変えていない）。作業場 worktree `worktree-agent-ad56639e9d8579117`（v0.100.0 起点）。
**engine の拡張なので、実装の前にこの文書で人と決める（AGENTS.md）。** 人に決めてほしい事は §10。
印: 【確】= コード・数で確かめた / 【推】= 推測 / 【未確認】= 確かめていない。

前提の文書: `plans/webgpu/analysis-render-structure.md`（11-14 の分析。以下「分析」）・`plans/webgpu/survey/K-light-units-calibration.md`（光の単位と Blender の手本。以下「K」）・
`plans/engine-webgpu.md` 12.41〜12.42（PC とブラウザの既定が WebGPU）・`docs/art-ref/visual-dict/reference-3d.md`（見た目の名前 → 値の組）。

---

## 0. 要約

- 願い: 影 MOD のような絵（やわらかい影・すき間の暗さ・映り込み・水・空・光の筋・雲・ブルーム・トーンマップ）を、エンジンで出す。
  **方針（人の確認）: 物理ベースで、Blender に合わせていく。** 名前と数の意味は Blender（EEVEE / Cycles・Color Management）と glTF に寄せ、
  「Blender で同じ場面を描いた絵」を正解の絵として比べる。
- スパイク 3 つの結果（§1）:
  - (a) lamplighter の後がけ 98 行を効果の値の列に置き換えて、**CPU・WebGPU・GL の 3 つとも 0 px 差**。ゲーム側は 21 行。ws の 10 本の後がけのうち 6 本は同じ語彙でほぼ書ける。
  - (b) 法線と奥行きを 1 枚に出す prepass（別 pass）を 3 つの描き手に通し（engine 側 約 130 行）、**SSAO を式の木だけで書けた**。今の絵は 3 つとも不変。
    PC の WebGPU で submit +0.33 ms・GL の GPU +0.57 ms。スマホは半分の解像度 12 点では 60 fps を割る見込み【推】。CPU の SSAO は 1 枚 1.2 s。
  - (c) vec3 を足すと後がけの木は **59% 減**（696 → 286 節）。材質は 0%。SSAO は vec3 では 2 割しか減らず、**読む点の中の let か taps の輪があれば 87% 減**【推】。
- 推す構造: 分析のとおり **案 1（`PostStack`）を先に、案 2（prepass と効果の登録）を段で**。render graph の全面の作り替えは取らない。
- 段（§3）: S1 PostStack と Blender に合わせたトーンマップ → S2 式の木の vec3・let・taps → S3 prepass と AO → S4 空・かすみ・光の筋 → S5 水 → S6 影の柔らかさと段。
  **最初の段に推す物【推】: S1**。どのゲームにも効き（テンプレ 4 本は後がけ 0）、Blender の Color Management と 1 対 1 に比べられ、描き手を触らない。
- pub API（§4）: 足す物は `PostStack`（mod 1 つ・`Effect` の enum・`Stack`・`Preset`・`build`・`App.withPostStack`）、S2 で `ShaderDoc.Field3`・`Field.Let`・`Field.Taps`、
  S3 で `Scene3d.Output.DepthNormal`（または `Prepass`）。消す・寄せる物は `App.withPasses`（使用 0）・`PostProcess.defaultExposure` の +0.4。

---

## 1. スパイクの結果

### 1.1 (a) 後がけを値の列に（`spikes/render-expression/a-poststack/`・別 worktree `worktree-agent-acd506d76c0982810` のコミット `9f09894b`）

| 項目 | 結果 |
|---|---|
| 絵の差（同じ描き手の前後・alley 夕暮れ / night 夜 / arrival） | CPU 3 枚・WebGPU 9 枚・GL 9 枚とも **SHA 一致（0 px）**【確】。対照: ビネットの inner を 0.35→0.36 にすると CPU 170,073 px・WebGPU 43,058 px 変わる（比べが本物） |
| 行数 | PostView 98 行 → ゲーム側 21 行 + View の 1 行。試作の `PostStack` 156 行 |
| 版の追随 | 0.91.0 → 0.100.0 はソースの直し 0。`upgrade-game` が flix.toml の `flix =` を上げない（0.78.0 のままだと refactor の索引が落ちる）【確】→ 別件の直し |
| 描き手どうしの差（参考） | WebGPU と GL で 27〜33% の画素が違う（最大 ±137）。CPU と GPU は大きさが違い比べていない【未確認】 |
| Spec の名前 | `town_post` → `poststack_post` に替えても絵は不変（名前は program の鍵だけ） |
| 形で分かった事 | View は Pass の計画（`passPlan`）と画面の層（`layers`）を別に組むので、`plan` と `present` に効果の列を 2 回渡す形になった → §4 で `build` 1 回か `App.withPostStack` に |

他のゲームの語彙（読んだだけ）:

| ゲーム | 今の語彙で | 足りない物 |
|---|---|---|
| ome_city・plateau_city | 書ける | — |
| stepdown | ほぼ | Vignette の中心 |
| conduit_hive | 一部 | FilmGrain |
| sea_cave_walk | 一部 | 毎コマの露出の倍率（Param） |
| night_apartment | 一部 | ColorGrade（暗部・明部の色・lift）・FilmGrain・毎コマの明るさ |
| fps3d_lab・dungeon3d_lab・hd2d_lab | 書けない | 場面の前後に足す Pass・design の大きさの場面・奥行きを名前で受ける DoF・Haze・熱のゆらぎ・LDR（トーンマップ無し）の並び・画面の行で決めるピント |

効果の出現（10 本）: Bloom 10・Vignette 10・Tonemap（全部 ACES・白の点 4.0）8・FXAA 8・MSAA 6・DoF 4・彩度だけ 4・ColorGrade 4・Grain 2・Haze 2・熱 2・毎コマの明るさ 2。
値の範囲（使われた値）: exposure −0.6〜+0.1・bloomThreshold 0.62〜2.0・knee 0.12〜0.7・strength 0.25〜1.0・radius 0.03〜0.05・taps 12〜24・vignette 0.18〜0.5・saturation −0.05〜+0.18。
**スキーマの min・max は使われた幅の 3〜10 倍で、ゲームごとに決め直している**（例 exposure ±3〜±4）。

### 1.2 (b) 法線と奥行きの prepass と SSAO（別 worktree `worktree-agent-adda5afff61d0ee1a`・コミット `a3a81e0e`・`30d3d9fd`）

- 足した物: `Scene3d.Output.DepthNormal({near, range})`（r・g = view 空間の法線 x・y を 0..1 に・b = `Output.Depth` と同じ灰色・α = 1）。
  α に奥行きを入れないのは、CPU の描き出しが 3D の層を α で 2D へ重ねるため。法線の z は `sqrt(1−x²−y²)`。
  法線マップは当てない・両面は裏で反転・cutout は捨てた後・半透明は入れない・ビルボードは (0,0,1)。
  **pipeline の鍵と `ProgramKind` の変種は増えない**（depth の pipeline の中で場面の値で枝を分けた）【確】。
- 手間: engine 側 約 130 行（Scene3d +17・ScenePlan/StaticRows +12・GL +20・WebGPU +2・GLSL +23・WGSL +18・SoftRaster3d +33・DrawHash +1）。
  MRT（色と同時に 2 枚目へ）の見積もりは 600〜800 行【推】（2D・3D・空・ビルボードの全 pipeline の鍵に描き先の組・MSAA の resolve・CPU の 2 枚の層）。
  `RenderList.PassTarget.Target(ColorAttachment, List[ColorAttachment])` と Java 側の `colorTargets` は既に複数枚を受けられる形【確】。
- SSAO（`bench/scene3d/src/Ssao.flix` 193 行）: 法線と奥行き → 色 → 暗さ（scale 0.5・12 点）→ 最後の面（暗さを TexBlur 8 点でぼかして掛ける）。
  **木だけで書けた**。`Shift` の中で `Ref` を引くと真ん中の値が返るので、読む点の式を Shift 1 つに入れられた。暗さの面は 3,153 節・GLSL 164 行・WGSL 191 行。
- 絵の差（320×180・カメラ固定）:

| 絵 | WebGPU と GL | WebGPU と CPU | GL と CPU |
|---|---|---|---|
| 法線と奥行き | 0 px | 2.9%（差 > 8 は 9 px） | 同じ |
| 暗さ | 60.6%・最大 107・差 > 8 は 3,816 px | 43.8%・最大 81・差 > 8 は 4,442 px | 68.8%・差 > 8 は 7,034 px |
| 最後の色 | 48.0%・差 > 8 は 755 px（1.3%） | 33.6%・差 > 8 は 667 px（1.2%） | 57.0%・差 > 8 は 945 px（1.6%） |
| AO 無し（参考） | 0 px | 82 px | 同じ |

  差の大半は読む点が奥行きの段差で隣の画素を拾うかどうかの縁の差（回しを 0 にしても 42〜60%）。**後がけの「近い」扱い（§5 の Neighborhood）の数の目安になる**。
  **今の絵は不変**: gl-capture の scene3d 6 コマが WebGPU・GL とも前後でバイト一致・CPU の still も SHA 一致【確】。
- 時間（960×540・中央値）:

| | AO 無し | prepass | prepass + SSAO |
|---|---|---|---|
| WebGPU の submit | 0.554 ms | 0.758 ms | 0.883 ms |
| WebGPU の draw call（3D + 2D） | 10 + 0 | 20 + 0 | 20 + 2 |
| GL の GPU | 0.294 ms | 0.393 ms | 0.865 ms |
| CPU 1 枚 | 45 ms | 441 ms（Rgba8 なら 75 ms） | 1,271 ms |

  WebGPU の GPU の時間は query が無く取れていない【未確認】。CPU で Rgba16Float の pass へ 3D を描くと 1 枚 約 370 ms 重い（別件の直しの候補）。
  スマホの見込み【推】: CPU +2〜5 ms・GPU +3〜6 ms（Adreno 750 を M4 Pro の 4〜6 倍 × 画面の大きさ）。**1/4 の解像度か 8 点が要る**。
- Blender の AO との並び: §1.4。

### 1.3 (c) `Field` に vec3（`spikes/render-expression/c-vec3/`・この worktree）

| Spec | 今の節 | vec3 で括る | 減り |
|---|---|---|---|
| 後がけの本編（DoF・ブルーム・ビネット・ACES・彩度） | 246 | 78 | 68% |
| 明るい所 / ぼかし / FXAA | 30 / 12 / 408 | 12 / 6 / 190 | 60 / 50 / 53% |
| 材質 5 本（tidepool の 3・pbr_room・plateau_city） | 77 | 77 | 0% |
| SSAO の暗さ | 3,153 | 約 2,500（vec3 だけ）/ 約 400（let か taps の輪）【推】 | 20% / 87% |

ws の 16 本の src に `chan ->` 77 か所・`Shade.Rgb(` 97 か所・`luma709` 16 か所（字の数え）。
材質が減らないのは、スカラーの場を `Ramp`・`Gradient` で色にしているから。**vec3 の得は後がけ（とそれを書く AI）に集まる**。
`LightModel3d.Vec3Expr` は vec3・`Let`・決まった回数の輪（`SumPoints`）を既に持ち、手本になる【確】。
`eqSpec` の時間と生成した GLSL・WGSL の行の前後は、実装していないので測れていない【未確認】。

### 1.4 Blender の AO と並べる（スパイク (b) の続き）

（追記待ち。§1.4 は Blender の Cycles の AO の pass と今の SSAO の暗さを並べた数を入れる）

---

## 2. 構造

分析の §C の案 1 → 案 2 をそのまま取る。WebGPU が既定になった後で変わった所だけ書く。

1. **ゲームに見せる面は値の束 1 つ**（Unity の Volume / Post-processing Stack・Godot の Environment・Bevy の camera に付ける `Bloom`・`Tonemapping` の component）。
   ゲームは「何の効果をどの値で」を言い、Pass の並び・描き先の大きさ・形式・Spec はエンジンが決める。順は固定（ブルームはトーンマップの前でしか意味が無い）。
2. **効果の中身は今の `Render.Pass` と `ShaderDoc` に展開する純粋な関数**。GL・WebGPU・CPU の描き手は触らない（S1・S2・S4 は描き手 0 行）。
   木に乗らない物だけ描き手に入る（S3 の prepass・S6 の影）。
3. **3D の場面が後の段へ出す絵は名前つき**（Bevy の `DepthPrepass` / `NormalPrepass`）。ゲームは頼まない — **効果が要る物をエンジンが足す**
   （AO を足すと法線と奥行きの prepass が出る・DoF を足すと奥行きの prepass が出る）。今の「深度のために場面を 2 回組む」（fps3d_lab・lamplighter）が消える。
4. **数の意味は Blender に寄せる**（§6）。露出は Blender の Color Management の Exposure（stops）・トーンマップの曲線は Blender の view transform の名前（AgX・Khronos PBR Neutral・Filmic・Standard）。
5. **CPU の描き手との合わせ方は効果ごとに 3 つのどれか**（§5）。

WebGPU の後で効く事: (i) `RenderList` の pass の区切りに描き先が並ぶので、prepass は「pass を 1 つ足す」だけで乗る（スパイク (b) で WebGPU の差分は 2 行）。
(ii) render bundle と `staticGroup` は prepass でも使い回せる【推】（同じ物を同じ順で描く）。(iii) WGSL の出口は `ShaderGen.Wgsl` が木から出すので、木に乗る効果は WGSL 0 行。

---

## 3. 段

見積もりは実時間（直近の実績: スパイク (a) の試作と 0 px の比べ 約 15 分・(b) の 3 描き手の prepass と SSAO 約 40 分は担当 1 人の時間。
エンジンに入れる時はテスト・文書・早見表・eval・門・レビューで 4〜8 倍かかってきた）。

| 段 | 何を | 門 | 見積もり |
|---|---|---|---|
| **S1** | `PostStack`（Bloom・Tonemap・Exposure・Vignette・ColorGrade・FilmGrain・DepthOfField（奥行きの prepass を自分で足す）・Fxaa・Custom）・`post.kind.json` とエンジンが持つ schema・preset 8 つ・`App.withPostStack`・トーンマップの入力を線形に（読む時に戻す・§6.2） | (1) 曲線の門: 線形の EXR の帯の絵を Blender の view transform（AgX・Khronos PBR Neutral・Filmic・Standard）で描いた PNG と、PostStack の CPU の出力の差 ≤ 2/255（§6.3）。(2) lamplighter の写しを preset へ移して、絵の差は人が見る（0 px は求めない・§6.2 の理由）。(3) gl-parity に 2 場面（全部の効果）。(4) eval 2 題・早見表 2 行。(5) スマホの頁で fps3d の部屋 + 標準の stack が 60 fps | 6〜9 時間 |
| S2 | 式の木の型: `Field3`（vec3）・`Field.Let`・`Field.Taps`（決まった点の並びで読む輪）・`Field.ScreenUv`。`PostStack` の中身を書き直す。生成器（GLSL・WGSL）と `ShaderEval`・`ShaderJson`・schema | 生成した GLSL・WGSL と CPU の絵が前後で 0 px（後がけと既存の shader.json 全部）・木の節の数（§1.3 の表）と `eqSpec` の時間が下がる・JSON の古い形はそのまま読める | 6〜8 時間 |
| S3 | prepass（`Scene3d.Output.DepthNormal`）を本体へ・`PostStack.Effect.AmbientOcclusion`（S2 の taps で書く・奥行きで縁を残すぼかし）・CPU は Approx | AO 無しの絵が 3 描き手でバイト不変・AO の差が §5 の Neighborhood の線の内・Blender の Cycles の AO の pass と並べた数（§1.4 の線）・スマホの頁で部屋 + AO（Low）が 60 fps | 6〜8 時間 |
| S4 | 空とかすみ: 太陽の円と大気の色を持つ空（`Scene3d.Sky.Physical`）・高さのかすみ（`Environment3d.fog` に `HeightFog`）・光の筋（`PostStack.Effect.LightShafts`・太陽の画面の位置から放射にぼかす・奥行きの prepass で遮る）・雲（空に 2D の `fbm` を貼る層） | Blender の Nishita / Multiple Scattering の空と並べて色の差（K の D 節の手順）・光の筋は Neighborhood | 8〜12 時間 |
| S5 | 水: 材質の出口に法線（`Out.Surface{ albedo, normal, roughness, emission }`）・法線マップの uv の倍率とずらし・画面の座標で色の pass を読む（屈折）・平面の映り込み | 波の動きの描き出し（時刻を変えた 3 枚）・Blender の Principled BSDF の水（transmission）と並べる | 10〜14 時間 |
| S6 | 影: 光の大きさで柔らかさ（Blender の light の Radius・PCSS）・太陽の段（cascade 2〜3）・点光源の影 1 本 | 影の端の幅を Blender の Cycles の影と並べる・gl-parity・スマホの時間 | 10〜14 時間 |
| 後 | MRT（prepass の draw call が数千本の場面で効いてから）・TAA・モーションブラー（GpuOnly）・SSR（S5 の後の候補） | — | — |

段ごとに: レビュー役 1〜2 回（80 点・必須が直っていれば GO）・`make gl-capture-check` の既存の絵の不変・テンプレの reference-check・早見表と eval・リリースは区切りで。

### 3.1 最初の段に S1 を推す理由【推】

影 MOD の技法のうち、**少ない手間で絵が一番変わる**物を選ぶ物差し: (1) 何本のゲームの絵が変わるか (2) 描き手に入るか (3) 正解の絵と比べられるか (4) スマホの値段。

| 候補 | (1) | (2) | (3) | (4) |
|---|---|---|---|---|
| **S1 トーンマップ（AgX）・露出・ブルーム・色の仕上げ** | 3D のゲーム全部・テンプレ（今は後がけ 0） | 入らない | Blender の view transform と曲線で 1 対 1 | 全画面 3〜4 回（ブルームは縮めた pass）。fps3d の部屋で既に 60 fps |
| AO | 3D の部屋・町 | 入る（prepass） | Cycles の AO で近い | 重い（§1.2） |
| 空・かすみ | 屋外だけ | 空の式は木の外 | Blender の空 | 軽い |
| 柔らかい影 | 全部 | 入る（3 描き手に手書き） | 近い | 中 |

S1 は「今ある 9 本の手書き」を 1 行にし、**テンプレと新しいゲームが最初から写真の見え方を持つ**。トーンマップが Blender と同じ曲線になると、
Blender で作った glb と lightmap の色が、Blender の画面で見た色に近づく（今は HDR の Pass が画面の値で、露出 −0.6 で合わせている。K の A4）。

---

## 4. pub API の増減（名前の案。型検査はしていない）

### 4.1 S1 で足す物

```flix
mod PostStack {
    /// 効果 1 つ。並べた順は使わない（エンジンの順に並べ直す）。同じ効果が 2 つあれば後の物。
    pub enum Effect {
        case Bloom(Bloom)                 // Blender の compositor の Glare（Bloom）: threshold・smoothness・size・strength
        case Tonemap(Tonemap)             // Blender の view transform と look
        case Exposure(Float64)            // stops（Blender の Color Management の Exposure と同じ。線形に 2^e を掛ける）
        case Vignette(Vignette)           // strength・inner・outer・center
        case ColorGrade(ColorGrade)       // lift・gamma・gain（Blender の Color Balance の Lift/Gamma/Gain）・saturation・shadowTint・highlightTint
        case FilmGrain(FilmGrain)         // amount・rate（コマ/秒）
        case DepthOfField(DepthOfField)   // focusDistance（world）・fStop か blur・奥行きの prepass はエンジンが足す
        case Fxaa
        case Custom(CustomPass)           // 逃げ道: 名前と Spec と描き先。順の中の置き場（BeforeTonemap / AfterTonemap）を言う
    }
    pub enum ViewTransform { case AgX case KhronosNeutral case Filmic case AcesFitted case Standard }
    pub enum Look { case None case Punchy case HighContrast case LowContrast }   // AgX の look（Blender の名前）

    pub type alias Stack = StackImpl                 // 外から作らせない（of / preset / loadOr だけが作る）
    pub def of(effects: List[Effect]): Stack
    pub def preset(p: Preset): Stack                 // Preset = DuskOutdoor・NightOutdoor・SunnyCity・EveningBeach・Cave・NightCorridor・TorchRoom・Neutral
    pub def with(e: Effect, s: Stack): Stack         // preset から 1 つだけ替える
    pub def loadOr(fallback: Stack, path: String): Stack \ Fs.FileRead   // post.kind.json（fail-open）
    pub def issues(s: Stack): List[Issue]            // 間違えた組み合わせ（§7）

    /// 低い口（自前の PassPlan と混ぜる人）。計画と画面へ置く面を 1 回で返す。
    pub def build(input: Input, s: Stack): { plan = Render.PassPlan, present = Render.PlacedItem }
}
// App の欄（Bevy の camera の component に当たる。View は場面の items を返すだけ）
App.withPostStack(w -> PostStack.Stack)              // 場面の層の後・HUD の前に掛かる（HUD はトーンマップしない）
```

- 名前: `PostStack` は Unity の Post-processing Stack（v2）と同じ言い方。効果の名前は Unity URP の Volume の override（Bloom・Tonemapping・Vignette・Color Adjustments・Film Grain・Depth Of Field）と Blender の名前の両方で引ける物を選んだ。
- `Input`: `{ size, clear, scene = List[PlacedItem], scene3d = Option[Scene3dCmd], msaa }`。DoF と AO の prepass は `scene3d` から作る（ゲームは場面を 2 回組まない）。
- 値の record の欄は全部 Doc の欄と同じ名前（§8）。preset は `docs/art-ref/visual-dict/reference-3d.md` の表から（表の注記のとおり「評価された値ではない」ので、S1 で Blender の手本と並べて決め直す）。

### 4.2 S2・S3 で足す物

```flix
// ShaderDoc（S2）
pub enum Field3 { case Make(Field, Field, Field)  case Tex3({ name = String })  case Add(Field3, Field3) case Sub(..) case Mul(..)
                  case Scale(Field3, Field)  case Mix(Field3, Field3, Field)  case Normalize(Field3)  case Ref3(String) ... }
Field.Dot(Field3, Field3)  Field.Length(Field3)  Field.Comp({ of = Field3, axis = Axis3 })
Field.Let({ name = String, value = Field, in = Field })                   // 読む点の中の局所の束ね
Field.Taps({ points = List[Vec2], scale = Vec2, of = Field, combine = Combine })   // 決まった点で of を読み、足す・平均する
Field.TapOffset({ axis = Axis })                                          // Taps の中で今の点
Field.ScreenUv({ axis = Axis })
Shade.Vec(Field3)
// Scene3d（S3）
Scene3d.Output.DepthNormal({ near = Float64, range = Float64 })           // スパイク (b) の形。ゲームは直に使わず PostStack が使う
```

`Field3` を別の enum にするのは、vec3 とスカラーを取り違える所（スカラーの所に vec3 を渡す）を型で止めるため。`LightModel3d.Vec3Expr` と同じ分け方。
JSON は `{"kind":"vec3", ...}` を足し、古い形はそのまま読む。

### 4.3 消す・寄せる物

| 物 | 扱い |
|---|---|
| `App.withPasses` | 使用 0（分析 §3）。消す（`forbid.json` で `withPassPlan` へ） |
| `PostProcess.defaultExposure`（+0.4） | 8bit の画面の値向けの既定で、3D の HDR と噛み合わない（K の A4）。`PostStack` の既定は 0 stops。古い口は残し、doc で `PostStack` へ |
| `PostProcess.tonemapped` / `tonemappedWith` / `fxaaSpec` | 低い口として残す（`PostStack` の中身が使う）。早見表の行は `PostStack` に替える |
| ゲームの `PostView.flix`・`LookDoc` の後がけの欄 | 移すかはゲームを触る時（強制しない）。lint は「`tonemappedWith` を View で直に組んでいる」を知らせる（止めない） |

---

## 5. CPU の描き手（SoftRaster）と絵を合わせる決まり

`docs/backend-parity.md` の決まりを後がけへ広げる。**効果ごとに 3 つのどれかを宣言し、gl-parity の場面で数を守る。**

| 区分 | 何が入るか | GL・WebGPU・CPU の間の線 | スパイクの数 |
|---|---|---|---|
| **Pointwise**（画素ごとの式） | Exposure・Tonemap・ColorGrade・Vignette・Saturation・FilmGrain（同じ hash） | ±1/255（今のトーンマップと同じ） | (a) の前後 0 px |
| **Neighborhood**（近くを読む） | Bloom・DoF・AO・LightShafts・Fxaa | 差 > 8/255 の画素 ≤ 2%・最大差は記録だけ | (b) の最後の色 1.2〜1.6% |
| **GpuOnly** | MSAA・TAA・モーションブラー・（後）SSR | CPU は掛けずに `SoftRaster.dropped` に名前を出す | 今の MSAA と同じ |

- CPU の時間の線: 描き出し 1 枚に後がけで +200 ms まで（S1 の stack）。AO の CPU は (b) で 1.2 s → S2 の taps で木の評価を減らし、CPU だけ半分の点で近づける（Approx）【推】。
- **Blender の手本との線**は別に持つ（§6.3）。描き手どうしが合っていても、Blender と離れていれば直す対象。

---

## 6. Blender にそろえる

### 6.1 名前と数の対応

| PostStack | Blender | 数の意味 |
|---|---|---|
| `Exposure(e)` | Color Management → Exposure | 線形のシーンの値に 2^e。同じ |
| `Tonemap.viewTransform` | Color Management → View Transform（AgX・Khronos PBR Neutral・Filmic・Standard） | 曲線そのもの（§6.3 で 2/255 以内） |
| `Tonemap.look` | Look（AgX の Punchy など） | 同じ名前 |
| `ColorGrade.lift/gamma/gain` | compositor の Color Balance（Lift/Gamma/Gain） | 同じ式（ASC CDL でない方） |
| `Bloom.threshold/smoothness/size/strength` | compositor の Glare（Bloom）の Threshold・Smoothness・Size・Strength | threshold と strength は同じ意味。size はぼかしの広さで、カーネルは別物（Neighborhood） |
| `AmbientOcclusion.distance/factor` | Cycles の AO の pass の Distance（World の設定）・EEVEE の AO の距離 | distance は world の m（エンジンの単位へ換算）。§1.4 |
| `DepthOfField.focusDistance/fStop` | Camera → Depth of Field の Focus Distance・F-Stop | 物理のカメラの式で blur の半径へ（センサーの大きさは Blender の既定 36 mm） |
| （S6）影の柔らかさ | Light → Radius（Soft Falloff） | 光の大きさの m |
| （S4）空 | World → Sky Texture（Nishita / Multiple Scattering） | 太陽の高さ・空気の濃さ |

### 6.2 トーンマップの入力を線形にする

今は HDR の Pass の値が「画面の値（sRGB の曲線で縮めた値）」で、トーンマップはその上に掛かる（K の A4・露出 −0.6 の理由）【確: K】。
Blender の view transform は線形のシーンの値に掛かるので、**PostStack は場面の Pass を読む所で線形へ戻してから** Exposure・Tonemap を掛ける。
描き手と 3D の出口は触らない（読む側の 1 回の変換。8bit の 2D の絵も同じ式で線形になる）。

- 結果: 同じ露出 0 で、今の ACES の手書き（露出 −0.6）と絵が変わる。**今のゲームを PostStack へ移すと 0 px にはならない**（(a) の 0 px は「同じ式を値の列で書ける」証拠で、意味を揃えた後の絵ではない）。
- 代わりに: (a) の試作の形（読む所で戻さない）を `ViewTransform.AcesFittedScreen`（移行用・lint で知らせる）として残すかは §10 で人に聞く。

### 6.3 Blender の絵を正解にする門（pbr_room の手本の作り方を使い回す）

土台は `~/Documents/flix_ge_workspace/pbr_room/modeling/render_ref.py`（Cycles・CPU・128 サンプル・denoise・960×540・座標 `ep(x,y,z) = (−x, −z, y)`・`sensor_fit = VERTICAL`）と K の D 節。
Blender は devbox の nix store（`/nix/store/2rqcqsp3ww61r0qw46izbppssz3bnqxg-blender-5.2.3/bin/blender`）。手本はリポジトリに入れず、作るスクリプトと SHA を入れる。

| 門 | 何を比べるか | 線 | いつ |
|---|---|---|---|
| 曲線（S1） | 線形の帯の EXR（0〜16 の明るさ × 色相 12）を Blender の compositor で view transform ごとに PNG に → 同じ EXR を PostStack の Pointwise の効果に通した CPU の絵 | 最大 2/255 | S1 の門・Blender の版を上げた時 |
| 露出（S1） | 同じ EXR に Exposure ±2 | 最大 2/255 | 同上 |
| AO（S3） | bench/scene3d の部屋を Blender で組み直し、Cycles の AO の pass と PostStack の AO の暗さ | §1.4 の数から決める | S3 の門 |
| 場面（S4 以降） | pbr_room・bench/scene3d の部屋の全部の効果（Cycles・同じ光） | 線形の輝度の相対差の中央値と 95 パーセンタイル（K の C4） | 段の門・知らせるだけ（ゲート化は数がたまってから） |

- 比べは**線形の EXR**どうし（トーンマップの差と場面の差を混ぜない）。見せ用の PNG は別に並べる。
- Neighborhood の効果（ブルーム・AO）は Blender とカーネルが違うので、明るさの平均と相関で「同じ向きか」を見る（0 px ではない）。
- 写実でない絵（ドット絵・トゥーン）はこの物差しの外（K と同じ）。

---

## 7. スマホの時間の予算と AI から見た書き味

### 7.1 予算（Galaxy S24 Ultra・Chrome・WebGPU。今日の実測: fps3d の部屋 60 fps・cpu 12.6 ms）

| 区分 | 予算（GPU） | 中身 |
|---|---|---|
| S1 の標準の stack | 2.5 ms | 明るい所を 1/2・ぼかし 2 回 1/4・本編 1 回・FXAA 1 回（全画面 2 回分） |
| AO（S3） | Low 1.5 ms / High 3 ms | Low = 1/4 の解像度・8 点。スマホ（`Display.SizeClass.Small`）の既定は Low |
| 空・光の筋（S4） | 1 ms | 光の筋は 1/4 の解像度・16 点 |
| CPU（JS / wasm） | +1 ms まで | Spec は Stack が変わった時だけ組む（`Render.cachedBySpec` の表に載せる。毎コマ組まない） |

- `PostStack.Quality`（Low・Medium・High）を Stack に持ち、既定は `ctx#display#sizeClass` から（スマホは Low）。値の意味は品質で変えず、点の数と解像度だけを変える。
- 門: S1 と S3 の門に「スマホの頁で fps3d の部屋 + 標準の stack が 60 fps」（人が端末で開く。測れない時は【未確認】で出す）。

### 7.2 AI から見た書き味

| 条件 | 案 |
|---|---|
| 選ぶ物が少ない部品 | 効果 9 つ（S1）。順・Pass・描き先・Spec は言わない。`Custom` は 1 つの逃げ道 |
| 見た目の名前から引ける preset | `Preset` 8 つ（visual-dict の reference-3d の行の名前と同じ）。`PostStack.preset(Preset.DuskOutdoor) |> PostStack.with(Effect.Exposure(-0.3))` |
| 数の範囲がスキーマにある | エンジンが `post.schema.json` を持つ（min・max は §1.1 の使われた幅 + Blender の UI の範囲。例 exposure −4〜+4・bloom.strength 0〜2）。ゲームごとに決め直さない |
| 間違えた組み合わせを止める | 型: `Stack` は外から作れない・`Field3` とスカラーは別の型。`PostStack.issues`（make の lint と F3 に出す）: HDR の場面に Tonemap が無い・Tonemap が 2 つ・Fxaa が縮めた場面・DoF / AO が 3D の無い場面・Bloom の threshold が Exposure の後の 1 より下で全面が光る。描き出しの時は知らせでなく止める（分析 §D の 4） |
| 途中の絵を見る | `PostStack.debugView(DebugView.Bloom | Depth | Normal | Occlusion)`（Bevy の debug と同じ考え）を `make render` で 1 枚に。`HeadlessRender.renderPassImage` を早見表へ |
| 手本 | 3D と後がけの手本をテンプレか bench に 1 本（今は 0）。S1 で bench/scene3d の部屋に `App.withPostStack` を入れる |
| eval | S1: 「夕方の町の 3D に写真のような仕上げ」「Blender で見た色と違う（露出）」の 2 題 |

---

## 8. Doc（`post.kind.json`）のスキーマ

`/doc-design` と `docs/doc-conventions.md` の外形（`version`・sections 方言）。値だけを持ち、効果の式は持たない（振る舞いはコード）。

```json
{
  "version": 1,
  "preset": "DuskOutdoor",
  "quality": "auto",
  "exposure": -0.3,
  "tonemap": { "viewTransform": "AgX", "look": "None" },
  "bloom": { "enabled": true, "threshold": 1.0, "smoothness": 0.5, "size": 0.04, "strength": 0.6 },
  "vignette": { "enabled": true, "strength": 0.3, "inner": 0.35, "outer": 1.05, "center": [0.5, 0.5] },
  "colorGrade": { "enabled": false, "lift": [0,0,0], "gamma": [1,1,1], "gain": [1,1,1], "saturation": 0.0 },
  "filmGrain": { "enabled": false, "amount": 0.02, "rate": 24 },
  "depthOfField": { "enabled": false, "focusDistance": 8.0, "fStop": 2.8 },
  "fxaa": true
}
```

- `preset` が出発点で、書いた欄だけが上書き（Unity の Volume の override と同じ）。知らない `preset`・`viewTransform` は既定へ落として 1 行言う（`Log.fellBack`）。
- schema の `min`・`max`・`description` に Blender の欄の名前を書く（Studio のフォームでスライダーになる・保存で即反映）。
- 毎コマ変える数（ピント・場所ごとの明るさ）は Doc でなく `PostStack.with`（View で）か `Render.withShaderParams`。

---

## 9. 確かめていない事・危険

- WebGPU の GPU の時間（query が無い）・スマホの実機の値段（§7.1 は見込み）【未確認】。
- AgX の曲線を Blender の OCIO の設定から写す時のライセンス（Blender の OCIO config は Blender の配布物。式を自分で書くか、LUT を作るか）【未確認】→ S1 の最初に確かめる。
- vec3 の `eqSpec` と生成した shader の行の前後【未確認】。
- MRT が要る場面（draw call が数千本の prepass）【未確認】。
- (a) の CPU と GPU の比べ（大きさが違う）【未確認】。
- 語彙が足りないとゲームは手書きへ戻る（fps3d_lab の 8 項目）。`Custom` で逃がし、2 本のゲームが同じ Custom を書いたら効果へ上げる。

---

## 10. 人に決めてほしい事

1. **最初の段は S1（PostStack と Blender のトーンマップ）でよいか**【推】。AO（S3）を先にしたい場合は S2 を前に置く（木の大きさの都合）。
2. **トーンマップの入力を線形にする（§6.2）か**。する【推】と今のゲームの見え方とは変わる（移すかはゲームを触る時）。移行用の `AcesFittedScreen` を残すか【推: 残して lint で知らせる】。
3. **Blender の曲線の門（§6.3）を S1 の門にするか**（Blender 5.2.3 を門の道具にする。CI では回せず手元の門）【推: 手元の門】。
4. 法線は**別 pass**（スパイク (b)・約 130 行）で始め、MRT は後か【推: 別 pass】。
5. スマホの既定の品質（AO は Low・ブルームは標準）でよいか。
6. 外のゲーム（ws の 9 本）の `PostView` を移すか・いつか【推: 触る時に】。

---

## 付録 A. スパイクの置き場

| スパイク | ブランチとコミット | 文書と数 | 絵（git の外） |
|---|---|---|---|
| (a) | `worktree-agent-acd506d76c0982810` `9f09894b` | `spikes/render-expression/a-poststack/` | `.claude/worktrees/agent-acd506d76c0982810/build/spike-poststack-shots/` |
| (b) | `worktree-agent-adda5afff61d0ee1a` `a3a81e0e`・`30d3d9fd` | `spikes/render-expression/b-ssao/README.md` | `.claude/worktrees/agent-adda5afff61d0ee1a/build/ssao-spike/` |
| (c) | この worktree | `spikes/render-expression/c-vec3/` | — |

## 付録 B. レビューの記録

（追記待ち）
