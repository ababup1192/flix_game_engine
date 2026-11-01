# HD-2D の試作 2 本の重なりを engine へ移す — 3 回目の拡張の設計

状態: 設計のみ（未実装）。作業場 `fge-postfx`（ブランチ `feat/postfx-spike`）。
改訂 2（レビュー 71 点 → 指摘 1〜15 と §7 の推奨を反映）。改訂 3（再レビュー 84 点 → 指摘 N1〜N8 を反映・段の番号を実装の並びに振り直し）。どちらも末尾 §8 の表。

土台は 1 回目（`plans/postfx-spike.md`。Pass の中の Shader 面・`Render.PassPlan`・倍率・`Field.Sampler`・`div`）と
2 回目の round2a（`plans/engine-round2.md`。`Field.Param`・`Render.withShaderParams`）。
2 回目で入れた口のうち、輪郭光・`CameraRig.follow` 系・`withPassPlanView` 系・`Light.worldLightMapPass`・`Shadow.projectedBox` は
使われていないので別の担当が外している。**この文書はそれらが無い物として書く。**

**engine/ の拡張なので、実装の前にこの文書で相談する（AGENTS.md）。** 推奨と、人に決めてほしい所は §7 にまとめた。

後方互換の決まり（1・2 回目と同じ）: **今のゲーム・テンプレートは 1 文字も変えずにコンパイルが通り、同じ絵を出す**。
破る所は各節の「後方互換」と §6 の表に全部書く。

試作 2 本:

| 呼び名 | 場所 |
|---|---|
| 港 | `/Users/abab/Desktop/hd2d_lab` |
| ダンジョン | `/Users/abab/Documents/flix_ge_workspace/dungeon3d_lab` |

**行番号は 2026-10-30 に読んだ時点の物。** 別の担当がゲーム側を片付けていて動くので、def の名前で引き直すこと
（`bin/fge refactor show <Mod.名前>`）。読んでいる間にも、港の `Harbor3dShader.mixRgb` は `a + (b − a) × t` の手書きから
`Field.Blend` に替わった。ダンジョンの索引は片付けの途中で名前解決が通らない（`DungeonShader.depthOnly` が未定義）。

---

## 0. 実装の順と合格条件

### 0.1 順（小さい物から）

| 段 | 中身 | 節 | 触る package |
|---|---|---|---|
| 1 | 小さい口 5 つ（`Num.smoothstep`・`Geometry2D.convexHull`・`PxSpriteAtlas.contentKey`・`RenderTarget.scaledDescriptor`・`CameraRig.followTo`） | §3 | engine・engine_world |
| 2 | ShaderDoc の組み立ての口（`ShaderDoc.Nodes`） | §1 | engine |
| 3 | 色の Param（`ShaderDoc.ColorParam`・`ShaderDoc.withColorParam`） | §2 | engine |
| 4a | 1 枚の描き出しが Pass を描く（`HeadlessFrame.renderPlanPng`） | §5 | engine_full |
| 4b | 動画が Pass を描く（`VideoOut.writeFramesWithPasses`・`App.drawPassPlan`・`DrawHash` の Pass の鍵） | §5 | engine_world・engine_tools・engine_full |
| 5a | 後処理の口（`PostFx`。Settings はコードで渡す） | §4 | engine_world |
| 5b | 後処理の Doc（`PostFxDoc`・`docs/postfx.schema.json`・Studio の登録の手順） | §4.3 | engine_world・docs |
| 6 | シェーダーを前もって作る口（`App.withShaderWarmup`・`ZBand.warmupCoverZ`） | §W | engine・engine_world（render_gl は触らない） |

段の番号が実装の並び（1 → 2 → 3 → 4a → 4b → 5a → 5b → 6）。節の番号とは別（warmup の節は §W）。

- 段 2 を段 5a より前に置くのは、PostFx の中身をこの組み立ての口で書くため（engine の中で 1 回目の使い手になる）。
- 段 4a・4b を段 5a より前に置くのは、PostFx を入れた後の静止画と動画を同じ口で確かめるため。
- 段 5a と 5b を分けるのは、5a で「Settings をコードで渡してバイト一致」を先に確かめ、Doc の読み書きの誤りと式の写し違いを混ぜないため。
- 段 6（warmup）は PostFx の後。PostFx の Spec も 1 回で warmup の列に入れられる。
- **engine の package を直した段では、試作に差す前に `make sync`（fpkg の作り直しと symlink の張り直し）を回す**（`make sync-engine` では shader まわりの変更が反映されない所がある）。

### 0.2 各段の合格条件（全部の段で同じ 3 つ + 段ごとの物）

1. **静止画がバイト単位で同じ**: 港とダンジョンの描き出し（試作の `make render-all`）を、段の前と後で回し、
   gallery の PNG の SHA256 が全部一致する。段の前の PNG は engine を差し替える前に 1 回撮っておく。
   ゲームを新しい口へ書き換える段では、**書き換える前の PNG と書き換えた後の PNG** を比べる（engine だけ差し替えた時点でも 1 回比べる）。
2. **実機の速さが前と同じ**: 港とダンジョンで同じ flow（試作の `e2e/video.flow`・`e2e/tour.flow`）を `POST /perf?warmup=60` で流し、
   塗る側の **avg が段の前の ±5%・p99 が ±10%**（どちらも 3 回の中央値で比べる）に入る。
3. **今のテンプレートが 1 文字も変えずに通り、同じ絵を出す**: 段ごとの門は `make test-<テンプレート名>` を 4 本（game-starter・rpg-starter・
   sound-novel-starter・tidepool-starter）と、各テンプレートの `reference/SHA256SUMS.txt` の一致。engine の変わった package は `make test-<name>`。
   **`make test-all`（全量）は全部の段が終わった後の 1 回だけ**（AGENTS.md「全量の検証はリリース直前の 1 回だけ」）。

段ごとに足す条件:

| 段 | 足す条件 |
|---|---|
| 4b | 試作の動画の SoftRaster の道（`FGE_GPU=off`）のコマが、今の自前の道とバイト一致（§5.5） |
| 5a | Settings を試作の look.json の値と同じにコードで渡し、静止画がバイト一致 |
| 5b | 試作の `*.postfx.json` を読んだ Settings が 5a のコードの値と同じ（テスト）で、静止画がバイト一致 |
| 6 | **GL**: warmup が終わった後、場面を出入りしても `FrameDiagnostics` の `shaderBuilds` が 0 件（港の 3D の港への出入り・ダンジョンのフロアの移動を 3 回ずつ） |

gl_parity（`bench/gl_parity`）は新しい描き物の種類を増やす段が無いので回さない
（§4 の PostFx は既存の Field だけで組むので、1 回目の passChain・linearRead・paramRead の範囲に入る）。

---

## 1. ShaderDoc の組み立ての口（小）— 段 2

### 1.1 今の困りごと

`Field` の木をそのまま書くと 1 行が長いので、どの Spec のファイルも頭に同じ 20〜30 行の小道具を持っている。

| 場所 | 中身 |
|---|---|
| 港 `src/Harbor3dShader.flix:10-37` | `k` `prm` `ref` `add` `sub` `mul` `div` `floorF` `fract` `sat` `step` `oneMinus` `blend` `inside`・`Rgb`・`rgbConst` `rgbParam` `mixRgb`・`hashAt` |
| ダンジョン `src/DungeonShader.flix:20-50` | `k` `prm` `ref` `add` `sub` `mul` `div` `floorF` `fract` `sat` `sqrtF` `step` `oneMinus` `blend` `sq` `i2s`・`Rgb`・`rgbParam` `mixRgb` `scaleRgb`・`hashAt` |
| 港 `src/PostView.flix:50-53, 113`・ダンジョン `src/PostView.flix:44-47, 114` | `k` `add` `sub` `mul`・`linear`（Sampler Linear） |
| 港 `src/HarborView.flix`（`sea` の近く） | `k` `add` `sub` |
| 港 `src/Harbor3dView.flix`（`copyLow`）・ダンジョンの写しの面 | `Out.Fill({ shade = Shade.Rgb({ r = …, g = …, b = … }), alpha = k(1.0) })` と `cycleRate = 0.0` を毎回書く |

名前もファイルごとに少しずつ違う（`floorF` / `sqrtF` は Flix の名前とぶつけないための逃げ・`mixRgb` の 3 つ目の引数が `by` と `t`）。
`hashAt` は 2 本とも同じ 5 行（`Shift` で升目の中心へ寄せて `Hash1` を読む）。

### 1.2 置き場と名前

**`ShaderDoc.Nodes`（`engine/src/ShaderDoc/Nodes.flix` の `pub mod ShaderDoc.Nodes`）** に置く。
`App.Headless`（`engine_world/src/App/Headless.flix`）と同じ「入れ子の mod を別のファイルに置く」形。

- ShaderDoc の中に直に足さない: ShaderDoc は型と書き換え（`renameTex` `bindParams`）の置き場で、組み立ての小道具まで入れると
  `use fge::ShaderDoc.{…}` で型を入れた時に `add` `min` `floor` まで一緒に見えてしまう。
- 別の top-level の mod（`ShaderGraph` など）にしない: 製品の名前を借りることになり、`ShaderDoc` の語彙だと分からなくなる。
- 名前は **Unity Shader Graph のノードの名前**（Constant・Time・Add・Subtract・Multiply・Divide・Minimum・Maximum・Step・Floor・Fraction・Saturate・
  Absolute・One Minus・Square Root・Lerp・Smoothstep・UV・Sample Texture 2D・Property・Length・Normalize）を、
  GLSL / Godot の Visual Shader の短い字にそろえる（`fract` `sqrt` `lerp`）。Field の case の名前（`Bin` `Un`）とは別の層。

```flix
// engine/src/ShaderDoc/Nodes.flix
/// ShaderDoc.Field の木を短く組む道具（Unity Shader Graph のノード・Godot の Visual Shader の式と同じ語）。
/// どれも Field の case を 1 つ作るだけで、木の形は手で書いた時と同じ（GLSL・描き出しの答えも同じ）。
/// WhyNot: 式を短くするために木を作り替えない（a − b を a + (−b) にする等）— 手書きの Spec を置き換えた時に描き出しのバイトが変わる。
pub mod ShaderDoc.Nodes {
    use ShaderDoc.{Field, BinOp, UnOp, Axis, TexChan, FilterMode, Shade, Out, Spec}

    // ── 値 ──
    /// どこでも同じ数（Shader Graph の Constant / Float）。
    pub def constant(v: Float64): Field                    // Field.Const
    /// 面を置く時に渡す数（Shader Graph の Property）。値は Render.withShaderParams。
    pub def param(name: String): Field                     // Field.Param
    /// bindings に置いた名前の場。
    pub def ref(name: String): Field                       // Field.Ref
    /// 面の中の横・縦の位置 0..1（Shader Graph の UV の x / y）。
    pub def u(): Field
    pub def v(): Field
    /// 今の時刻（秒。面に渡す time）。Field.Time({ scale = 1.0, offset = Const(0.0) }) と同じ木。
    pub def time(): Field

    // ── 四則と比べ ──
    pub def add(a: Field, b: Field): Field
    pub def sub(a: Field, b: Field): Field
    pub def mul(a: Field, b: Field): Field
    /// 0 で割ると 0（BinOp.Div の決まり）。
    pub def div(a: Field, b: Field): Field
    pub def min(a: Field, b: Field): Field
    pub def max(a: Field, b: Field): Field
    /// x が edge 以上なら 1（GLSL の step(edge, x) と同じ引数の順）。
    pub def step(edge: Field, x: Field): Field

    // ── 1 つの場に掛ける ──
    pub def floor(a: Field): Field
    pub def fract(a: Field): Field
    /// 0..1 に収める（Shader Graph の Saturate）。
    pub def saturate(a: Field): Field
    pub def abs(a: Field): Field
    pub def oneMinus(a: Field): Field
    /// 負の数は 0 として扱う（UnOp.Sqrt の決まり）。
    pub def sqrt(a: Field): Field
    pub def neg(a: Field): Field
    pub def sin(a: Field): Field
    pub def cos(a: Field): Field

    // ── 混ぜる ──
    /// t で a と b の間をつなぐ（Field.Blend。t = 0 で a・1 で b）。
    /// t は 0..1 に収めてから使う — Shader Graph の Lerp・Godot の mix は収めないが、engine の Blend は収める。
    pub def lerp(a: Field, b: Field, t: Field): Field
    /// lo..hi の間でなめらかに 0 → 1（Field.Smoothstep。lo / hi は数）。
    pub def smoothstep(lo: Float64, hi: Float64, x: Field): Field

    // ── テクスチャ ──
    /// 名前の付いたテクスチャ（Pass も）の 1 チャンネル（Sample Texture 2D）。補間なし。
    pub def tex(name: String, chan: TexChan): Field
    /// of の中の tex / blur を Linear で読む（Field.Sampler。Shader Graph の Sampler State）。
    pub def linear(of: Field): Field

    // ── ベクトル（今の ShaderDoc.lengthOf / normalized をここへ） ──
    /// 成分を並べたベクトルの長さ（Shader Graph の Length）。空なら 0。
    pub def length(parts: List[Field]): Field
    /// 長さ 1 にそろえた成分（Normalize）。長さ 0 は 0 のまま。
    pub def normalize(parts: List[Field]): List[Field]

    // ── 乱数 ──
    /// 升目ごとに決まる乱数 0..1。cu / cv は升目の中心（floor(座標) + 0.5 の形）を渡す —
    /// 中心でない値を渡すと、升目の境で Hash1 の格子をまたいで隣の升目の値を拾うことがある。
    pub def cellHash(cu: Field, cv: Field, seed: Int32): Field

    // ── 色の 3 本組 ──
    /// r・g・b の 3 本の場（Shade.Rgb に渡す形）。
    pub type alias Rgb = { r = Field, g = Field, b = Field }
    pub def rgbConst(c: Color): Rgb
    /// 面を置く時に渡す色（§2 の ColorParam。ShaderDoc.withColorParam と組）。
    pub def rgbParam(p: ShaderDoc.ColorParam): Rgb
    pub def lerpRgb(a: Rgb, b: Rgb, t: Field): Rgb
    pub def scaleRgb(a: Rgb, s: Field): Rgb
    /// 3 本の全部に同じ f を掛ける。
    pub def mapRgb(f: Field -> Field, a: Rgb): Rgb
    /// テクスチャの r・g・b（補間なし）。
    pub def texRgb(name: String): Rgb

    // ── Spec ──
    /// 面全体を rgb で塗る Spec（alpha 1・cycleRate 0）。
    pub def rgbFill(name: String, bindings: List[(String, Field)], rgb: Rgb): Spec
}
```

`step` の引数の順は GLSL（`step(edge, x)`）に合わせる。今の `BinOp.Step` は「b が a 以上なら 1」で、`a = edge, b = x` にすれば同じになる
（2 本の試作の `step` も同じ並び）。`smoothstep` の lo / hi を `Float64` にするのは、`Field.Smoothstep` がそう持っているから
（場で受ける形は `Field` の case を足すことになるので入れない — §1.8）。
`constant` は Flix 0.78 の予約語ではない（再レビューで check して確かめた）。

### 1.3 今の `lengthOf` / `normalized`

**`Nodes.length` / `Nodes.normalize` へ移し、`ShaderDoc.lengthOf` / `normalized` はその 1 行の呼び出しにして 1 リリースの間残す**。
`bin/lint-rules/forbid.json` に「`ShaderDoc.lengthOf` → `ShaderDoc.Nodes.length`」「`ShaderDoc.normalized` → `ShaderDoc.Nodes.normalize`」の 2 行を足す。

- 使う所: `lengthOf` は `normalized` の中だけ・`normalized` は 0 か所（`refactor usages`）。リポジトリの外のゲーム 11 本は分からないので、すぐには消さない。
- 木の形は変えない（`mul(p, p)` を `reduceLeft` で `add` → `sqrt`）。`normalized` の doc の WhyNot（長さの式を成分ごとに複製する）はそのまま移す。

### 1.4 ゲーム側の あと

```flix
// 港 Harbor3dShader（頭の 28 行が use 1 行になる）
mod Harbor3dShader {
    use fge::{Color, ShaderDoc}
    use fge::ShaderDoc.{Field, Shade, Out}
    use fge::ShaderDoc.Nodes.{constant, param, ref, add, sub, mul, div, floor, fract, saturate, step, oneMinus, lerp, cellHash,
                              rgbConst, rgbParam, lerpRgb, rgbFill}
    use fge::ShaderDoc.Nodes.Rgb

    def inside(lo: Float64, hi: Float64, x: Field): Field = mul(step(constant(lo), x), step(x, constant(hi)))   // ゲームに残す
    …
}

// 写しの面（港 Harbor3dView.copyLow）
let r = Nodes.mapRgb(of -> Field.Shift({ dx = dx, dy = dy, of = of }), Nodes.texRgb(lowName()));
Render.shaderFill(Nodes.rgbFill(Harbor3dShader.copyLowName(), Nil, r), full, 0.0, 0)
```

置き換えは名前の付け替えだけ（`k` → `constant`・`prm` → `param`・`sat` → `saturate`・`floorF` → `floor`・`sqrtF` → `sqrt`・`hashAt` → `cellHash`・
`mixRgb` → `lerpRgb`）。`sq`・`i2s`・`inside`（港）はゲームの小道具として残す（§1.8）。

### 1.5 後方互換

足すだけ。`lengthOf` / `normalized` は残る（中身は Nodes を呼ぶだけで、返す木は同じ）。
Flix は `use` で入れた名前とゲームの mod の中の同じ名前の def がぶつかると止まるので、**ゲームは小道具を消してから use する**（消さずに use だけ足すと型検査が落ちる。足さなければ何も起きない）。

### 1.6 テスト（engine/test/TestShaderNodes.flix）

| 確かめること（1 テスト 1 アサート） |
|---|
| `add(constant(1.0), constant(2.0))` = `Field.Bin({ op = Add, a = Const(1.0), b = Const(2.0) })`（`ShaderGen.eqSpec` で包んで比べる — Field に Eq が無いため。以下同じ） |
| `step(e, x)` が `Bin({ op = Step, a = e, b = x })`（引数の順） |
| `lerp(a, b, t)` が `Field.Blend({ a, b, by = t })` |
| `time()` が `Field.Time({ scale = 1.0, offset = Const(0.0) })` |
| `cellHash(cu, cv, 7)` が試作の `hashAt` と同じ木（試作から写した期待値の木と eqSpec） |
| `rgbFill("n", Nil, rgbConst(c))` を `ShaderEval` で評価した 1 画素が c（評価の値で 1 回） |
| `length(x :: y :: Nil)` の木が今の `ShaderDoc.lengthOf` と eqSpec で同じ |
| `normalize(Nil)` = `Nil`・`length(Nil)` を評価すると 0 |

**描き出し**: 港とダンジョンを書き換えて §0.2 の 1（バイト一致）。木が同じなら GLSL の字も同じになるので、実機の 1 枚撮り（GPU）も前と同じになる見込み（見るだけ）。

### 1.7 消える行の目安・汎用性

- 港 約 28 行（`Harbor3dShader` 頭）+ 6 行（`PostView`）+ 3 行（`HarborView.sea` 周り）・ダンジョン 約 30 行 + 6 行。合わせて 70 行ほど。
- engine の中: `ShaderDoc.waterVeins` / `lavaVeins` などの組み込みの Spec はそのまま（書き換えると TestShader の GLSL の字の期待値を見直すことになる。今回はしない）。
- 汎用性: Shader 面を手で組む全部のゲーム。テンプレートでは sound-novel-starter の Backdrop が Field を手で組んでいる。

### 1.8 入れない物と理由

- **演算子の多重定義（`a + b` で Field を足す）**: Flix の `Add` の trait を `Field` に付けることになり、`+` が Float64 と Field で別の意味を持つ。読む人が型を追わないと分からない。
- **場で受ける smoothstep（lo / hi が Field）**: `Field.Smoothstep` の case を足すか、`Bin` で組み直すことになる。組み直すと木が変わり、今の Spec を置き換えた時にバイトが変わる。要るゲームが出てから。
- **`lerpUnclamped`（`a + (b − a) × t`）**: 2 本の試作は Blend に寄った（1.1 の注記）。要るゲームが出てから。
- **`inside(lo, hi, x)`（範囲の中なら 1）**: 港だけ・2 行。`step` 2 つの積で書ける。
- **輝度（luma）**: 2 本の試作で重みが違う（`brightSpec` は Rec.709 の 0.2126/0.7152/0.0722・`postSpecWith` は Rec.601 の 0.299/0.587/0.114）。どちらかに寄せると絵が変わる。PostFx の中で 2 つを別の名前で持つ（§4）。

---

## 2. 色の Param — 段 3

### 2.1 今の困りごと

`Field.Param` は数 1 つなので、色は 3 つの Param に割って、渡す側と読む側で同じ字を手で作る。

| 渡す側 | 読む側 |
|---|---|
| 港 `Harbor3dView.paramsOf`（`"lr" => l#r, "lg" => l#g, "lb" => l#b, "hr" …, "c0r" … "c2b"` の 15 個） | 港 `Harbor3dShader.rgbParam("l")`・`rgbParam("h")`・`rgbParam("c0")` |
| ダンジョン `DungeonShader.colorParams`（c0・c1・c2・苔 m の 12 個）・`Dungeon3dView.lampParams`（`"${n}r"` …）・`built` の `"Sr" "Sg" "Sb" "Er" "Eg" "Eb"` | ダンジョン `DungeonShader.rgbParam("c0")` … `"L${i}"` |

字が 1 つ違うと、GL も描き出しもその Param を 0 で読み（知らせは `Render.drawShaders` / `shaderSurfaces` の 1 行）、色が黒く欠ける。
渡す側と読む側が別のファイルにあり、字を合わせる物が何も無い。

### 2.2 口の形 — 型の付いた鍵（採る形）

2 案を比べた。

| | 案 A: 字の頭（prefix）を両側で書く | 案 B: 型の付いた鍵を 1 か所で作る |
|---|---|---|
| 打ち間違い | 走らせて知らせを見るまで分からない | 両側が同じ def を呼ぶので起きない（鍵を作る所の 1 か所だけ） |
| ゲームの手間 | 無い | 色ごとに `def lampColor(): ShaderDoc.ColorParam = ShaderDoc.colorParam("l")` を 1 行 |
| 今の字との互換 | 同じ | 同じ（prefix は今の字をそのまま渡す） |
| 決まり（AGENTS.md「取り違えは型で止める」） | 当たらない | 当たる（非 pub の enum + pub type alias） |

**案 B を採る。** 置く側の口は `ShaderDoc.withColorParam`（数の表に足す）だけにし、`Render.withShaderColor` は足さない —
表に足してから既存の `Render.withShaderParams` に渡せば足り、Shader 面の木を色ごとに作り直す道を作らずに済む（§2.5 の速さ）。

```flix
// engine/src/ShaderDoc.flix
/// 面に渡す色の Param の鍵（<prefix>r / g / b の 3 つの Param）。colorParam で作り、Spec の側（Nodes.rgbParam）と
/// 置く側（withColorParam）が同じ値を使う — 字を 2 か所で書かない。
/// WhyNot: 素の String を両側で書かせない — 片方の打ち間違いが黙って 0（黒）になる。
enum ColorParamKey with Eq, Order, ToString { case ColorParamKey(String) }
pub type alias ColorParam = ColorParamKey

/// prefix から鍵を作る。prefix + "r" が paramNameOk でない（英数字と '_' 以外を含む・空）なら bug!
/// — 鍵はコードの字で書く物で、読み込んだデータから作らないため（docs/error-handling.md の「bug! で止める」）。
pub def colorParam(prefix: String): ColorParam
/// 鍵の 3 つの Param の名前（r, g, b の順）。
pub def colorParamNames(p: ColorParam): (String, String, String)
/// 数の表に色を足す（同じ名前は後の値）。結果は Render.withShaderParams に渡す。
pub def withColorParam(p: ColorParam, color: Color, params: Map[String, Float64]): Map[String, Float64]
```

鍵の名前の決まりは **`<prefix>r` / `<prefix>g` / `<prefix>b`**（2 本の試作の今の字と同じ）。字が同じなので、置き換えても uniform の名前と
描き出しの Const が変わらず、バイトも変わらない。全部 engine の `ShaderDoc` に置くので、段 3 は engine だけを触る。

### 2.3 ゲーム側の あと

```flix
// 港 Harbor3dShader（鍵は Spec の側に置く）
pub def light(): ShaderDoc.ColorParam = ShaderDoc.colorParam("l")
pub def horizon(): ShaderDoc.ColorParam = ShaderDoc.colorParam("h")
pub def tone(i: Int32): ShaderDoc.ColorParam = ShaderDoc.colorParam("c${Int32.toString(i)}")
// specOf の中: rgbParam(light()) …

// 港 Harbor3dView.paramsOf（毎コマ・面ごと。表を 1 枚にする）
Map#{ "bx" => bx, … }
    |> ShaderDoc.withColorParam(Harbor3dShader.light(), l)
    |> ShaderDoc.withColorParam(Harbor3dShader.horizon(), hz)
    |> ShaderDoc.withColorParam(Harbor3dShader.tone(0), c0) …
// 面には今と同じく Render.withShaderParams(Map.union(d#geometry, paramsOf(w, d#face)))
```

### 2.4 後方互換

足すだけ。`Field.Param` と `withShaderParams` は今のまま。

### 2.5 テスト・速さ

| どこ | 確かめること |
|---|---|
| TestShaderDoc（engine） | `colorParamNames(colorParam("c0"))` = `("c0r", "c0g", "c0b")` |
| 同 | `withColorParam(colorParam("l"), rgb(0.25, 0.5, 0.75), Map.empty())` = `Map#{ "lr" => 0.25, "lg" => 0.5, "lb" => 0.75 }` |
| 同 | 同じ鍵で 2 回足すと後の色（Map で 1 回） |
| 同 | `rgbParam(colorParam("l"))` を、`withColorParam` で作った表で `bindParams` してから評価した 1 画素が色 |
| 同 | `colorParam("a-b")` が止まる（bug! を捕まえるテストの書き方は `/quality-assurance` の例外のテストの形） |

**速さ**: 港は面ごとに毎コマ Param の表を組む（`paramsOf`）。`withColorParam` は `Map.insert` 3 回で、今の `Map#{ … }` の字で 15 個並べるのと
同じ数の挿入になる。§0.2 の 2 で確かめる。

### 2.6 消える行・汎用性・入れない物

- 消える行は少ない（港・ダンジョン合わせて 10 行ほど）。効き目は行ではなく、黒く欠ける誤りが型で止まること。
- 汎用性: 色を面に渡す全部のゲーム（灯りの色・チームの色・時間帯の色）。
- **入れない: `Render.withShaderColor`**。面ごとに色を 1 つずつ足すと、`withParamsItem` が Shader 面を色の数だけ作り直す。表に足してから 1 回渡す形で足りる。
- **入れない: 数 1 つの鍵（`ShaderDoc.FloatParam`）**。数の Param は名前が 1 つで両側の字を合わせる所が少なく、2 本の試作の取り違えは色の 3 つ組で起きていた。色の鍵が使われてから、同じ形で足すか決める。
- **入れない: `Field.Param` に色の case（vec3 の uniform）**: ShaderGen・ShaderEval・`paramNames` の正典順・GL の uniform の型が全部変わる。3 つの float で困っていない。

---

## 3. 小さい口 — 段 1

### 3.1 `Num.smoothstep`

**困りごと**: `t * t * (3.0 - 2.0 * t)` が手書きで 6 か所（港 `Camera3d.flix:61, 69`・`View.flix:1115`・`Harbor3dView.flix:335`・
ダンジョン `World.flix:128`（`ease`）・`Dungeon3dView.flix:340`）。engine の中にも同じ式が 3 つある（`ShaderDoc.smoothstepF`（非 pub）・
`ShaderEval.smoothstep`（非 pub）・`RadialGlow.smoothstepCurve`（`1 − t` を掛けた形））。

```flix
// engine/src/core/Num.flix
/// lo..hi の間でなめらかに 0 → 1（GLSL・Godot の smoothstep(from, to, x) と同じ引数の順と式）。lo = hi なら x < lo で 0、それ以外 1。
/// Unity の Mathf.SmoothStep(from, to, t) は「from と to の間を t でつなぐ」別の関数。
pub def smoothstep(lo: Float64, hi: Float64, x: Float64): Float64
```

式は `ShaderEval.smoothstep` と同じ（`clamp01((x − lo) / (hi − lo))` → `t·t·(3 − 2t)`）。`ShaderDoc.smoothstepF` と `ShaderEval.smoothstep` は
同じ式なのでこれを呼ぶ形にする（引き算・割り算・clamp の順が同じなので、描き出しの値も変わらない）。

試作の置き換え:

| 所 | 置き換え | バイト |
|---|---|---|
| 港 `Camera3d.flix:61` | `Num.smoothstep(lo, hi, camHeight)`（今の式と同じ順の引き算・割り算） | 変わらない |
| 港 `View.flix:1115`・ダンジョン `World.flix:128` | 0..1 に収めた k に掛ける所は `Num.smoothstep(0.0, 1.0, k)`（`(k − 0) / 1` は k と同じ値） | 変わらない |
| 港 `Camera3d.quaynessOf`（`:69`） | `/ Float64.max(0.001, lo − hi)` の守りの値が式に入るので**置き換えない** | — |
| 港 `Harbor3dView`・ダンジョン `Dungeon3dView` の occluderAlpha（`1 − (1 − a) × k × k × (3 − 2k)`） | 掛け算の順が `(1 − a) × k × k × …` で、smoothstep の値を先に作ると丸めの順が変わる。**置き換えない**（置き換えるなら「バイトが変わりうる」として、その段の比べから外して見る） | 変わりうる |

テスト（TestNum）: `smoothstep(0, 1, 0.5)` = 0.5・`(0, 1, −1)` = 0・`(0, 1, 2)` = 1・`(2, 2, 1)` = 0・`(2, 2, 3)` = 1・`(0, 2, 0.5)` = 0.15625。

### 3.2 `Geometry2D.convexHull`

**困りごと**: 凸包が 2 本に 1 つずつ（港 `SunShadow.convexHull`（`SunShadow.flix:71-95`。pub・`halfHull` / `popWhileClockwise` / `cross`）・
ダンジョン `Dungeon3dView.hull`（`Dungeon3dView.flix:577-591`））。どちらも Andrew の monotone chain で、(x, y) の順に並べ、外積 ≤ 0 の点を捨て、
下の縁と上の縁の最後の点を 1 つずつ落としてつなぐ。返す点の列は 2 本で同じ。

正方形の 4 隅で確かめた答えは (0,0) → (1,0) → (1,1) → (0,1)。**y が上向きの数学の座標では反時計回りだが、y が下向きの画面では時計回り**で、
始まりは x がいちばん小さい点の中で y がいちばん小さい点（**画面の左の上**）。縮退の時は: 1 点 → 空・同じ点 2 つ → `[p, p]`（重なりを除かない）。

engine では重なりを先に除いて、縮退の答えを読みやすくする（先に `List.distinct` に当たる事をしてから並べる）。
2 本の試作は 3 点以上の重ならない点しか渡していないので、置き換えても答えは同じ（§0.2 の 1 で確かめる）。

```flix
// engine/src/core/Geometry2D.flix
/// 2D の幾何の小道具（Godot の Geometry2D と同じ置き場）。
pub mod Geometry2D {
    /// 点の列を囲む凸の多角形。重なる点は先に 1 つにまとめ、一直線に並ぶ途中の点は落とす。
    /// 始まりは x がいちばん小さい点の中で y がいちばん小さい点（画面の左の上）。並びは画面（y 下向き）で時計回り
    /// （y 上向きの座標では反時計回り）。最初の点を最後に繰り返さない（Godot の convex_hull は繰り返す）。
    /// 違う点が 1 つ → その 1 点・2 つ → その 2 点・全部が一直線 → 両端の 2 点。空 → 空。
    /// 当たりの形にするなら CollisionShape2D.PolygonShape2D の points にそのまま渡せる（巻き順は不問）。
    pub def convexHull(points: List[Vec2.Vec2]): List[Vec2.Vec2]
}
```

置き場: engine に幾何の mod が無く（`Geometry` 0 件）、`Polygon` は描く物の enum・`CollisionShape2D` は当たりの形。凸包は影・光の筋の多角形にも
使うので、当たりの mod でなく Godot と同じ名前の `Geometry2D` を新しく作る（`engine/src/core/` — Vec2 と同じ層で、どこからでも呼べる）。

テスト: 正方形の 4 隅 + 中の 1 点 → (0,0) (1,0) (1,1) (0,1)（順も）・同じ点 2 つ → 1 点・違う 1 点 → その点・一直線の 3 点 → 両端・空 → 空。

### 3.3 `PxSpriteAtlas.contentKey`

**困りごと**: アトラスを GPU へ上げる時の鍵（`App.AtlasUpload#key`）を、画素の畳み込みで手で作る 2 行が 6 か所。

| 場所 |
|---|
| 港 `Res.keyOf`（`Res.flix:129-131`） |
| ダンジョン `Res.bakedOf`（`Res.flix:177`） |
| `templates/game-starter/src/Res.flix:63`・`templates/tidepool-starter/src/Res.flix:76`・`templates/rpg-starter/src/Sheet.flix:43, 52` |

どれも `baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17)` → `"<名前>:<side>:<hash>"`。

```flix
// engine_world/src/PxSpriteAtlas.flix
/// GPU へ上げる時の鍵（App.withSpriteAtlases の key）。名前・辺の長さ・画素の中身から作る — 同じ絵の間は同じ字、
/// 色票や Doc を直して画素が変わると、ほぼ必ず別の字になる（Int32 の畳み込みなので、ぶつかる組はありうる）。
/// WhyNot: 鍵を名前だけにしない — 保存し直して絵が変わっても GPU の古いテクスチャが使われ続ける。
pub def contentKey(name: String, baked: Baked): String
```

字は今の手書きと同じ（`"${name}:${side}:${hash}"`・同じ畳み込み）。鍵は GPU へ上げ直すかの判断にだけ使い、絵には入らない。
同じ字にしておけば置き換えの前後で上げ直しも起きない。regions（コマの位置）は鍵に入れない（今と同じ。画素が同じなら GPU の中身は同じ）。

テスト: 同じ Baked で 2 回 → 同じ字・画素を 1 つ変える → 違う字・`contentKey("px", b)` が今の手書きの式で作った字と同じ。
**テンプレート 3 本の書き換えはこの回に入れない**（テンプレートは今のままで通る。別の回で `/add-template` の手順に沿ってまとめて）。

### 3.4 `RenderTarget.scaledDescriptor`

**困りごと**: 倍率だけを変えた作り方を `{ scale = s | RenderTarget.defaultDescriptor() }` と書く所が、港 `PostView.chain` の `at`・
ダンジョン `PostView.chain` の `at`・`Dungeon3dView.half`。`Descriptor` の doc がこの字を勧めている（欄が増えても止まらないため）。

```flix
// engine/src/RenderTarget.flix
/// 倍率だけを s にした作り方（ほかの欄は defaultDescriptor）。
pub def scaledDescriptor(s: Float64): Descriptor
```

名前を `scaled` にしないのは、`Render.scaled`（描き物を拡大する口）と字がぶつかり、`use` で両方を入れた所で読み違えるため。
`Descriptor` の doc の「組む時は `{ scale = 0.5 | defaultDescriptor() }`」を「倍率だけなら `scaledDescriptor(0.5)`・ほかの欄も変えるならこの字」に替える。
テスト: `scaledDescriptor(0.5)#scale` = 0.5。範囲の外は `RenderTarget.sizeOf` が丸めている。ここでは丸めない（丸める所を 2 つにしない）。

### 3.5 `CameraRig.followTo`

**困りごと**: 港 `World.followCamera`（`World.flix:384-391`）は `followDelta` を x と y に 1 回ずつ呼んで足す。

```flix
// engine_world/src/CameraRig.flix
/// current を target へ、軸ごとの不感帯と寄せ率で寄せた次の位置（followDelta を x・y に掛けて足した物）。
pub def followTo(spec: Follow, dt: Float64, target: Vec2.Vec2, current: Vec2.Vec2): Vec2.Vec2
```

`followDelta`（1 軸の移動量）は残す。`followTo` は「移動量でなく次の位置」を返す 2D の形で、中は
`{ x = current#x + followDelta(spec, dt, target#x, current#x), y = … }`（港の今の式と同じ順の足し算 — 値も同じ）。

**ダンジョンの `Camera3d.follow`（`Camera3d.flix:87-89`。`1 − exp(−rate·dt)` の割合で寄せる・不感帯なし）はゲームに残す。**
`followDelta` と式が違い（`min(1, k·dt)` と `1 − exp(−k·dt)`）、置き換えると camera の位置が変わる。指数の形の口（`smoothTo`）は、2 つ目のゲームで要ってから。

テスト: 不感帯 10・k 5・dt 0.1・current (0, 0)・target (30, 5) → (10, 0)（x は不感帯を出た 20 × 0.5・y は不感帯の中）。

### 3.6 小さい口の後方互換・汎用性・入れない物

- 足すだけ（`ShaderDoc.smoothstepF` と `ShaderEval.smoothstep` の中を `Num.smoothstep` 呼びにするのは、式が同じなので振る舞いは変わらない）。
- 汎用性: smoothstep・凸包（影・光の筋・当たりの形）・contentKey（ドット絵のアトラスを使う全部 — テンプレート 3 本）・scaledDescriptor（Pass を縮める全部）・
  followTo（camera が主人公を追う全部。今は各ゲームが followDelta を 2 回書く）。
- 消える行: smoothstep 0（読みやすさ）・凸包 約 35・contentKey 約 4（試作だけ）・scaledDescriptor 3・followTo 3。
- **入れない: `CameraRig.follow`（写し）の名前の再利用**。外した口と取り違えないよう、次の位置を返す物は `followTo`。
- **入れない: `CameraRig.smoothTo`**（上の理由）。

---

## 4. 後処理の口 PostFx（中〜大）— 段 5a・5b

### 4.1 今の困りごと

`PostView.flix` が 2 本でほぼ同じ 140 行（港 `src/PostView.flix` 全体・ダンジョン `src/PostView.flix` 全体）。

| 部分 | 港 | ダンジョン | 違い |
|---|---|---|---|
| Pass の並び `chain` | 14-33 | 14-32 | 無し（字まで同じ） |
| 明るい所を抜く `brightSpec` | 116-123 | 117-124 | Spec の名前だけ（`hd2d_bright` / `dg_bright`） |
| ぼかし `blurOf` | 125-130 | 126-131 | Spec の名前だけ |
| 色調補正 `graded` | 133-139 | 134-140 | 無し |
| 本編の面 `postSpecWith` | 90-111 | 80-110 | ダンジョンだけ熱のゆらぎ（`wobble`）とかすみ（`hazed`） |
| ピント（帯）`postSpec` / `post` | 37-38, 80-88 | 無し | 港は画面の縦の帯でぼかす形も持つ（ピントの位置を `Field.Time` に入れる逃げ） |
| ピント（深さ）`postDepthSpec` / `postDepth` / `DepthFocus` | 60-78 | 54-78 | ダンジョンは熱の矩形の Param を足す |

値の Doc も 2 本で同じ欄を持つ: 港 `assets/hd2d_lab.look.json`・`assets/hd2d_lab.harbor.look.json`・ダンジョン `assets/dungeon3d_lab.look.json`・
`*.meadow.look.json`・`*.volcano.look.json` の `bloom*`（6）・`grade*`（6）・`tilt*`（2）・`blurScale`・`vignette`・`focus*`（3）・`nearBlur`。
光（灯り・霧・環境光）と同じ Doc に入っていて、`bloom` で始まる欄が 6・`grade` で始まる欄が 6 並ぶ
（`docs/doc-conventions.md`「同じ接頭辞のキーが 5 個以上並んだら割れの合図」）。
ピントの距離は camera の Doc（港 `hd2d_lab.harbor3d.view.json` の `dof`・ダンジョン `dungeon3d_lab.camera.json` の `dof`）。

もう 1 つ: どちらも `chain` と `postDepth` を**毎コマ組み直す**（`blurOf` などが Spec を毎コマ作る）。Spec の値は同じなので GL は作り直さないが、
`RenderPaint.buildProgram` は参照が違うので毎コマ `eqSpec`（木を丸ごと比べる）を通る。

### 4.2 口の形（段 5a）

```flix
// engine_world/src/PostFx.flix
/// HD-2D の後処理（ブルーム・被写界深度・ビネット・色調補正・距離のかすみ）を Pass の列と本編の面 1 枚で組む。
/// 中身は既存の Pass と Shader 面だけ（GL と描き出しの一致は Pass・Linear の読み・Param の範囲のまま — docs/backend-parity.md）。
/// 使い方: Doc を読み直した時に build で 1 回組み、毎コマは chain と composite に渡すだけ。
/// Pass の名前・Spec の名前・Param の名前は全部 postfx_ で始まる（ゲームの Pass・Param とぶつけない）。
pub mod PostFx {

    /// ブルーム（明るさが threshold を越えた所を抜き、2 段でぼかして足す）。
    /// knee = しきいから元の色に戻り切るまでの幅・radius = ぼかしの半径（画面の高さ比）・taps = 標本の数・
    /// intensity = 足す強さ・scale = 明るい所を抜く Pass の倍率（ぼかしはその半分）。
    pub type alias Bloom = { threshold = Float64, knee = Float64, radius = Float64, taps = Int32, intensity = Float64, scale = Float64 }

    /// 被写界深度（ピントの外を、縮めた Pass で先にぼかした 1 枚と混ぜる）。
    /// radius / taps / scale = ぼかしの半径・標本の数・Pass の倍率。nearScale = 手前のぼけを奥の何倍にするか（どのピントの決め方でも同じ値）。
    /// bandHalf / bandTransition = TiltShift の帯の半分の幅とぼけ切るまでの幅（画面の縦 0..1。buildTiltShift の時だけ読む）。
    pub type alias DepthOfField = { radius = Float64, taps = Int32, scale = Float64, nearScale = Float64,
                                    bandHalf = Float64, bandTransition = Float64 }

    /// 四隅を落とす量（0 = 落とさない）。
    pub type alias Vignette = { intensity = Float64 }

    /// 色調補正: 暗部を shadows の色へ shadowsMix だけ寄せ・明部を highlights の向きへ highlightsMix だけ掛け・
    /// 底を lift だけ持ち上げ・彩度を saturation だけ戻す（Unity の Split Toning と Lift の組に近い）。
    pub type alias Grade = { shadows = Color, shadowsMix = Float64, highlights = Color, highlightsMix = Float64,
                             lift = Float64, saturation = Float64 }

    /// 距離のかすみ（buildDepth の時だけ効く）: 深さ start から 1 にかけて color へ amount だけ寄せる。amount 0 で木に何も足さない。
    pub type alias Fog = { color = Color, start = Float64, amount = Float64 }

    /// 後処理の値（5a ではゲームがコードで組む・5b から PostFxDoc が JSON から作る）。
    pub type alias Settings = { bloom = Bloom, depthOfField = DepthOfField, vignette = Vignette, grade = Grade, fog = Fog }

    /// 既定（掛けても絵が崩れない控えめな値。PostFxDoc の欄が欠けた時もこれ）。
    pub def defaults(): Settings

    /// ピントの決め方の型の印（値を持たない・case の無い enum）。build* が返す Built の型の引数になり、
    /// 違う決め方の composite* に渡すと型検査で止まる（Built[DepthFocus] を compositeNone に渡すと E7685）。
    /// 名前の意味: NoFocus = ピントを掛けない（ぼかしの Pass も描かない）・TiltShiftFocus = 画面の縦の帯・DepthFocus = 深さの Pass を読む。
    pub enum NoFocus
    pub enum TiltShiftFocus
    pub enum DepthFocus

    /// build に渡す、Doc に出さない形の決め事。screen = design 解像度。
    /// distortion = 場面を読む所をずらす量（uv。熱のゆらぎ・水の中の揺れ）。None なら木に何も足さない。
    /// 中で Param を読むなら、値は composite が返す面に Render.withShaderParams で足す（名前は postfx_ で始めない）。
    pub type alias Options = { screen = Vec2.Vec2, distortion = Option[{ dx = ShaderDoc.Field, dy = ShaderDoc.Field }] }

    /// 組んだ Spec の束（Doc を読み直した時だけ作り直す）。f はピントの決め方の型の印。
    /// 中は非 pub の enum（engine の Clock.Stamp[_: Type] と同じ形 — 外から作らせず、型の引数で取り違えを止める）。
    enum BuiltData[_: Type](BuiltRec)
    pub type alias Built[f] = BuiltData[f]

    pub def buildNone(fx: Settings, opts: Options): Built[NoFocus]
    pub def buildTiltShift(fx: Settings, opts: Options): Built[TiltShiftFocus]
    /// depthPass = 読む深さの Pass の名前（chain の before に入れる）。
    pub def buildDepth(fx: Settings, depthPass: String, opts: Options): Built[DepthFocus]

    /// 本編より先に描く Pass の列: before → 場面 → 明るい所 → ぼかし 2 段 → ピントの外のぼけ（Built[NoFocus] では描かない）。
    /// scene = 場面の描き物（clear の色で消してから描く）・bloomSources = 明るい所の Pass に足す描き物（光の筋など、場面の明るさに依らず光らせたい物）。
    /// 深さの Pass（buildDepth の depthPass）は before に入れる。before に無い時は 1 回だけ知らせる
    /// （Log.fellBack。読む所は黒＝全部くっきりになる — 1 回目の「まだ描いていない Pass は黒」の決まり）。
    pub def chain(built: Built[f], input: { before = List[Render.Pass], clear = Color, scene = List[Render.PlacedItem],
                                           bloomSources = List[Render.PlacedItem] }): Render.PassPlan

    /// 本編の面 1 枚（画面全面・z 0）。time = 面に渡す時刻（distortion が Nodes.time() を読む時に効く）。
    pub def compositeNone(built: Built[NoFocus], time: Float64): Render.PlacedItem
    /// center = 帯の中心（画面の縦 0 上〜1 下）。
    pub def compositeTiltShift(built: Built[TiltShiftFocus], center: Float64, time: Float64): Render.PlacedItem
    /// 深さの Pass の目盛り（0..1）でのピントの深さ・手前 / 奥のくっきりの幅・ぼけ切るまでの幅・
    /// sampleOffset = 深さの Pass を読む所のずれ（design px。縮めた Pass を升目へ寄せた分）。
    pub def compositeDepth(built: Built[DepthFocus], focus: { focus = Float64, nearHalf = Float64, farHalf = Float64,
                                                              transition = Float64, sampleOffset = Vec2.Vec2 }, time: Float64): Render.PlacedItem

    /// Pass の名前（描き出しで 1 枚だけ見たい時・ゲームが自分の面から読みたい時）。
    pub def scenePass(): String     // "postfx_scene"
    pub def brightPass(): String    // "postfx_bright"
    /// build が組んだ Spec 全部（App.withShaderWarmup に渡す — §W）。
    pub def specsOf(built: Built[f]): List[ShaderDoc.Spec]
}
```

**build の時のピントの決め方と毎コマのピントの取り違えは型で止める。** 改訂 1 は 1 つの `composite(built, Focus)` で、違う Focus を渡すと Param を 0 で
読む（くっきりのまま）黙った誤りになっていた。`Built` を型の印で分け、composite も 3 つに分ける（AGENTS.md「取り違えは型で止める」）。

型の印の書き方（Flix 0.78。レビュー役が scratchpad の `flix check` で確かめた）:
- 印は **case の無い `pub enum`**（`pub enum NoFocus` など）。「非 pub の enum + pub の別名」で印を書くと、使われない enum として E8176（Unused enum）で止まる。
- 本体は **`enum BuiltData[_: Type](…)` + `pub type alias Built[f] = BuiltData[f]`**（engine の `Clock.Real` / `Clock.Stamp[_: Type]` と同じ形）。
- この形で `compositeNone(buildDepth(…))` が E7685 で止まることも確かめてある。テストは「止まること」を書けないので、§4.9 に型の印ごとの通る組だけを書く。

改訂 2 の `pub enum FocusMode` は使い手がいなくなるので消す（「ピントの決め方」の語は doc の言葉としてだけ残す）。`Options` は `{ screen, distortion }` にそろえ、3 つの `build*` の引数の型にする。

中の式は 2 本の試作の今の式をそのまま写す（明るさの重みが 2 種類ある所も含めて — §1.8）。式を整理し直すと静止画が変わるので、整理は別の回に回す。
**PostFx の中の Param の名前は全部 `postfx_` で始める**（`postfx_focus`・`postfx_nearHalf`…）。ゲームが distortion で使う Param（ダンジョンの `hu0` など）とぶつけない。
名前を変えても描き出しは `bindParams` で Const に置き換えるので、バイトは変わらない。

**Doc に出す物と出さない物（AGENTS.md の Doc の流儀）**

| 出す（PostFxDoc） | 出さない |
|---|---|
| bloom の 6 つ・depthOfField の 6 つ・vignette・grade の 6 つ・fog の 3 つ（繰り返し調整する数と色） | ピントの位置と距離（毎コマ camera から計算する値）・ピントの決め方（build* のどれを呼ぶか。Spec の形を決める構造）・distortion（振る舞い）・ビネットの中心と曲がり（0.55・0.45〜1.05。一度決めたら触らない形）・暗部と明部の境（0〜0.45・0.35〜1） |

camera の Doc の `dof` の距離（`nearHalf` `farHalf` `ramp` `open*` `depthNear` `depthRange`）は**ゲームの camera の Doc に残す**。
world の距離で書いた値を深さの Pass の目盛りに直す（`depthRange` で割る）・岸壁で開く（`open*` へ寄せる）はゲームの camera の振る舞いで、
`compositeDepth` に入れる前にゲームが計算する。

**手前のぼけの倍率は `depthOfField.nearScale` 1 つ。** camera の Doc の `dof.nearBlur` は毎コマ変わらない定数なので毎コマの値にせず、PostFxDoc へ移す。
港は今、帯の形（look の `nearBlur` 0.5）と深さの形（camera の `dof.nearBlur` 0.8）で別の値を使っている。港は 2D の村（TiltShift）と 3D の港（Depth）で
別の PostFxDoc（`hd2d_lab.postfx.json` と `hd2d_lab.harbor.postfx.json`）を読むので、それぞれの値をそれぞれの Doc に書けば値は変わらない。

### 4.3 PostFxDoc（JSON とスキーマ）— 段 5b

engine に置く Doc の前例に `AudioMixerDoc` があるが、`load(fallback, path)` で読めない時に黙って既定値で続ける古い形で、
`docs/error-handling.md` の決まり 1（「読み込みの関数は Result を返す・既定値で続けるかは呼ぶ側が選ぶ」）に合わない。手本にしない。

```flix
// engine_world/src/PostFxDoc.flix
pub mod PostFxDoc {
    /// JSON の文字から。JSON として読めない・version が違う時は Err。欠けた欄・型の違う欄は defaults() の値で埋める（欄ごとの fail-open）。
    pub def fromJson(text: String): Result[Util.Json.JsonError, PostFx.Settings]
    /// ファイルから。ファイルが無い・読めない時も Err（呼ぶ側が決める）。
    pub def load(path: String): Result[Util.Json.JsonError, PostFx.Settings] \ Fs.FileRead
    /// load の、続けるならこの値で続ける形。ファイルが無い時は黙って fallback（Doc を置かないゲームは後処理の既定で動く）。
    /// ファイルが有るのに読めない時だけ Log.fellBack で 1 行知らせて fallback。
    pub def loadOr(fallback: PostFx.Settings, path: String): PostFx.Settings \ Fs.FileRead
}
```

誤りの型は `Util.Json.JsonError`（engine_world の他の Doc の読み込みと同じ字。`DocJson.jsonError` / `DocJson.describe` で作る・読む）。

```json
{
  "version": 1,
  "title": "港の街（朝）の後処理",
  "note": "いじると何が変わるか: bloom=灯りのにじみ / depthOfField=ピントの外のぼけ / vignette=四隅の落ち / grade=色調補正 / fog=遠くのかすみ（深さでピントを決める画面だけ）",
  "bloom": { "threshold": 0.82, "knee": 0.12, "radius": 0.035, "taps": 24, "intensity": 0.5, "scale": 0.5 },
  "depthOfField": { "radius": 0.01, "taps": 16, "scale": 0.5, "nearScale": 0.8, "bandHalf": 0.22, "bandTransition": 0.22 },
  "vignette": { "intensity": 0.25 },
  "grade": { "shadows": "#4a5aa8", "shadowsMix": 0.1, "highlights": "#ffe0a8", "highlightsMix": 0.08, "lift": 0.06, "saturation": 0.1 },
  "fog": { "color": "#a8c0e0", "start": 0.3, "amount": 0.0 }
}
```

- 外形 7 点（`docs/doc-conventions.md`）: `version`・`title`・`note`・スキーマ `docs/postfx.schema.json`（`$id` は `postfx.schema.json`）・fail-open（欄ごと）・
  `project.json` の `editor.resources[]` への登録はゲームが書く（`{ "id": "postfx", "pattern": "*.postfx.json", "title": "後処理", "schema": … }`。段 5b の手順に書く）・
  保存で即反映（ゲームが `Controls.docTable` で監視し、読み直したら `PostFx.build*` をし直す）。
- 大きさ: タブ 5 枚・スカラー 22 個（目安 30 以下）・入れ子 1 階層。
- 欄の名前は Unity URP / Godot の Environment の語に寄せた: `bloom.threshold` / `intensity`（URP の Bloom）・`vignette.intensity`（URP）・
  `depthOfField`（URP の Depth of Field）・`transition`（Godot の `dof_blur_far_transition`）・`grade.shadows` / `highlights`（URP の Split Toning）・
  `lift`（Lift Gamma Gain）・`saturation`（Color Adjustments）・`fog`（Godot の Environment の depth fog）。試作の字からの読み替えは §4.5 の表。
- `focusCenter`（帯の中心の既定）は Doc に入れない。毎コマ `compositeTiltShift(…, center, …)` で渡す（港は今も Doc の値を毎コマ読んで渡している。値はゲームの look.json に残る）。

### 4.4 熱のゆらぎ・かすみ

| | 判断 | 理由 |
|---|---|---|
| かすみ（ダンジョン `hazed`・`haze`） | **口に入れる**（`fog`） | 深さの Pass がある画面なら、どのゲームでも同じ式で効く（Godot の depth fog・Unity の Fog の後処理版）。値は Doc の数と色だけ |
| 熱のゆらぎ（ダンジョン `wobble`・`heatRect`） | **ゲームに残す**。口は「場面を読む所をずらす場」`Options#distortion` だけ | 溶岩の池の画面の矩形・行ごとの sin は、そのゲームの物の配置と振る舞い。ずらす場を外から受ければ、水の中の揺れ・衝撃波も同じ口で書ける |

**ずらす場の木の順は今のダンジョンと同じにする**: くっきりの読みは `shift(tex(scene))`、ぼけの読みは **`linear(shift(tex(sceneBlur)))`**（Sampler が外・Shift が内）。
順を入れ替えると木が変わり、静止画のバイトが変わる。ブルームの読み（`linear(tex(bloomB))`）にはずらしを掛けない（今と同じ）。

ダンジョンの あと:

```flix
// Res（Doc を読み直した時）
let distortion = if (look#heat <= 0.0) None else Some({ dx = Heat.shiftField(look#heat), dy = Nodes.constant(0.0) });
let post = PostFx.buildDepth(postFx, depthName(), { screen = World.size(), distortion = distortion });

// 毎コマ
PostFx.compositeDepth(res#post, depthFocus(w, shift), w#t)
    |> Render.withShaderParams(Heat.rectParams(heatRect(w)))     // hu0 hv0 hu1 hv1（ゲームの Param。postfx_ で始めない）
```

かすみの amount が 0 の時は木に何も足さない（ダンジョンの今は 0 でも `c + (target − c) × 0` を木に入れている）。
`c + x × 0` は浮動小数でも c と同じ値なので、描き出しのバイトは変わらない（GLSL の字は変わる — 実機の絵は同じ見込み）。

### 4.5 ゲーム側の あと

```flix
// 港 Res（Doc を読み直した時だけ）
let fx3d = PostFxDoc.loadOr(PostFx.defaults(), "assets/hd2d_lab.harbor.postfx.json");
{ post3d = PostFx.buildDepth(fx3d, Harbor3dView.depthName(), { screen = World.size(), distortion = None }),
  post2d = PostFx.buildTiltShift(fxVillage, { screen = World.size(), distortion = None }) | res }

// 港 View.passPlanOf（毎コマ）
PostFx.chain(res#post3d, { before = depthPass :: lowPasses, clear = sky, scene = sceneItems(w), bloomSources = shafts(w) })

// 港 Harbor3dView.frameTree（毎コマ）
ZStack.leaf(PostFx.compositeDepth(res#post3d, depthFocus(w, shift), w#t) :: Nil)
```

段 5a では `fx3d` をゲームのコードで組む（今の look.json の値を Settings に写す）。段 5b で `loadOr` に替える。

PostView.flix は 2 本とも消える。残るのはピントの値を camera から作る `depthFocus`（今も各ゲームの View にある）と、ダンジョンの熱の場。
look.json の後処理の欄は `<名前>.postfx.json` へ移す（光の欄は look.json に残る）。読み替え:

| 試作の欄 | PostFxDoc |
|---|---|
| `bloomThreshold` `bloomKnee` `bloomRadius` `bloomTaps` `bloomStrength` `bloomScale` | `bloom.threshold` `knee` `radius` `taps` `intensity` `scale` |
| `tiltRadius` `tiltTaps` `blurScale` `focusHalf` `focusRamp` | `depthOfField.radius` `taps` `scale` `bandHalf` `bandTransition` |
| look の `nearBlur`（TiltShift の画面）・camera の `dof.nearBlur`（Depth の画面） | `depthOfField.nearScale`（画面ごとの Doc に） |
| `vignette` | `vignette.intensity` |
| `gradeShadow` `gradeShadowMix` `gradeHighlight` `gradeHighlightMix` `gradeLift` `gradeSaturation` | `grade.shadows` `shadowsMix` `highlights` `highlightsMix` `lift` `saturation` |
| `hazeColor` `hazeStart` `hazeAmount`（ダンジョン） | `fog.color` `start` `amount` |
| `heat`（ダンジョン） | 残る（ゲームの look.json） |
| `focusCenter` | 残る（ゲームが毎コマ `compositeTiltShift` に渡す） |

### 4.6 z-bands と 1 回目の後処理との関係

- composite は z 0 の画面全面の Shader 面 1 枚を返すだけ。どの層に置くかはゲームが決める（2 本とも `SortingLayer` の場面の層の葉に置いている）。
  会話・確認・切り替え（Transition の 100000）・HUD（`ZBand.liftHud`）は composite の上に重なり、**後処理を受けない**（今と同じ。HUD の字がぼけない）。
  HUD まで後処理に入れたい時は、ゲームが HUD を scene の Pass に描く（PostFx は何もしない）。
- 1 回目の拡張（Pass の中の Shader 面・倍率・`Sampler`・history・`div`）は PostFx の下の層で、PostFx は新しい描き物の種類も backend の変更も持たない。
  Pass・Spec・Param の名前は `postfx_` で始める（`@` は使わない — history の別名の決まり）。
  同じ名前の Pass を 2 回宣言すると 2 回目を描かない決まり（1 回目 §2.1 の 5）があるので、PostFx を 1 コマに 2 回 chain しない（doc に書く）。

### 4.7 GL と CPU の一致

PostFx が使う物は全部 `docs/backend-parity.md` の表の中: Pass（宣言順・まだ描いていない Pass は黒）・縮んだ Pass（scale 0.5 の偶数の座標は一致）・
tex の Linear（近似・この Mac で 0 px）・TexBlur・Param（Const と同じ扱い）・Smoothstep / RadialAspect（宣言シェーダーの面の近似）。
新しい行は足さない。gl_parity も回さない（場面 passChain・linearRead・paramRead が同じ物を見ている）。

### 4.8 後方互換

足すだけ（新しい mod 2 つと `docs/postfx.schema.json`）。

### 4.9 テスト

| 段 | どこ | 確かめること |
|---|---|---|
| 5a | TestPostFx | `chain`（buildDepth）の Pass の名前の並び = before の名前 ++ `postfx_scene` `postfx_bright` `postfx_bloomA` `postfx_bloomB` `postfx_sceneBlur`（List で 1 回） |
| 5a | 同 | `chain`（buildNone）に `postfx_sceneBlur` が無い |
| 5a | 同 | `chain` の `targets` の倍率 = bright は bloom.scale・bloomA / B はその半分・sceneBlur は depthOfField.scale（Map で 1 回） |
| 5a | 同 | buildDepth の深さの Pass が before に無い chain は、知らせの行を 1 つ返す（知らせを集める純粋な関数 `PostFx.issuesOf(built, before)` を分けて確かめる） |
| 5a | 同 | fog.amount 0 の build の Spec に、fog の色の Const が出てこない（`ShaderDoc.foldField` で数える） |
| 5a | 同 | distortion = Some の Spec で、ぼけの読みが `Sampler(Linear, Shift(…, Tex(postfx_sceneBlur)))` の形（外から順に） |
| 5a | 同 | `ShaderDoc.paramNames` の全部が `postfx_` で始まる（distortion = None の時） |
| 5a | 同 | `specsOf` の名前が重ならない（Set の大きさ = List の長さ） |
| 5a | 同 | 評価: 真っ黒の scene（tex の画素表を全部 0）で vignette 0・lift 0.1 → compositeNone の 1 画素が 0.1（`ShaderEval` で 1 回） |
| 5b | TestPostFxDoc | 例の JSON → 期待値の Settings のレコードと 1 回で比べる |
| 5b | 同 | `bloom` の欄が丸ごと欠けた JSON → bloom は defaults() の値・ほかは JSON の値 |
| 5b | 同 | 色が読めない（`"#zz"`）→ その欄だけ defaults() の値 |
| 5b | 同 | 壊れた JSON → Err・`loadOr` は fallback |
| 5b | 同 | 無いファイル → `loadOr` は fallback（知らせの行は出ない — 知らせを返す純粋な形で確かめる） |
| 5b | 同 | 試作の `*.postfx.json` を読んだ Settings = 段 5a でコードに書いた Settings |
| 5a・5b | 描き出し | 港・ダンジョンを書き換えた前後で §0.2 の 1（バイト一致）。Spec・Param の名前は `postfx_*` に変わるが、描き出しの画素は名前に依らない |
| 5a | 速さ | §0.2 の 2。build を Doc の読み直しの時だけにするので、毎コマの `eqSpec` が参照の一致で抜ける分だけ速くなる見込み（遅くならないことを見る） |

### 4.10 消える行・汎用性

- 消える行: `PostView.flix` 2 本（139 + 140 行）→ ゲームに残るのは build と chain と composite の呼び出しで 15 行ほど。合わせて 約 250 行。
- 汎用性: Pass と Shader 面で後処理を掛ける全部のゲーム。HD-2D 風の 2 本のほか、テンプレートの夜の場面（rpg-starter の夜・tidepool の水の中）が
  `buildNone` でブルーム・ビネット・色調補正だけを使える（ぼかしの Pass は描かない）。

### 4.11 入れない物と理由

- **HDR の色の形式（RGBA16F）**: 1 回目の §8 の 9 と同じ。8bit のターゲットは 1.0 で切れるので、しきいの上の明るさは残らない。PostFx の口の形は変えずに後から入れられる（Pass の Descriptor に欄を足す）。
- **ガウスの重み・横と縦に分けたぼかし・mipmap の縮小の連鎖**: 式が変わり静止画が変わる。今の 2 本の絵を写すのが先。
- **後処理を何段でも並べる口（Unity の Volume のスタック・Godot の CompositorEffect）**: 2 本の試作の並びは 1 通り。並べ替えたいゲームが出てから。
- **Pass・Param の名前の頭の字を受ける口**: 1 コマに 2 つの PostFx を chain するゲームが無い。`postfx_` に固定する。
- **ダンジョンの熱のゆらぎそのもの**（§4.4）。
- **Doc の数を Param にして、スライダーを動かしても GLSL を作り直さない形**: `Field.Smoothstep` の lo / hi が数なので、しきいを Param にすると木を組み直すことになり、静止画が変わる。保存の 1 回ごとに 1 回作り直すのは 1 コマの止まりで済む。

---

## 5. 1 枚の描き出しと動画が Pass を描く — 段 4a・4b

### 5.1 今の困りごと

- `VideoOut.writeFrames` の GPU の道（`paintOne`）も SoftRaster の道（`softFrame`）も、`video#scene` の描き物だけを描き、Pass を描かない。
  港・ダンジョンの `src/render/VideoRender.flix`（128 / 130 行）は、そのため頭に WhyNot を書いて自前でコマを描いている（`writeVideo`・`paint`。CPU で 4 本の糸）。
  GPU の道・ffmpeg へ直に流す道・`drawhash.txt` / `frames.json`・塗るコマを選ぶ `FGE_VIDEO_PAINT` が使えない。
- 1 枚の描き出しも、2 本の `SceneRender.paint`（港 `SceneRender.flix:400-406`・ダンジョン `SceneRender.flix:155-161`）が同じ 5 行
  （`Render.passSpecsOf` → 知らせを println → `shaderSurfaces` → `drawWith(withoutShaders)` → `HeadlessRender.renderPngWithPasses`）。
  `docs/headless-render-recipe.md` の「pass を使う場面」も同じ 3 行を写させている。港は `specsOf`（`SceneRender.flix:408`）も別に持つ。

すでにある物（改訂 1 で見落としていた）:

- **`App.paintOnce`（`App.flix:2287-2297`）** は、GL の 1 枚撮り・動画用に「実機の `renderFrame` と同じ道」で 1 コマを描く。`renderFrame` は Pass まで描くので、
  **GL の道ではすでに Pass を描ける**（App を持っていれば）。tileCache を持ち回すので、`passTargets`（コマをまたいで増える knownTargets）も持ち回っている。
- **`GpuShot`（`engine_full/src/full/GpuShot.flix`）** は窓なしの 1 枚撮り（Studio の会話のプレビュー・`bin/fge talk shot`）を、App の view → `paintOnce` の道で GPU に塗り、
  使えない所では渡された SoftRaster の撮り方に戻る。

足りないのは: (1) App を持たずに「計画と描き物」から 1 枚を SoftRaster で描く口、(2) VideoOut の両方の道が Pass を描くこと、(3) 動画の鍵に Pass を入れること。

### 5.2 口の形

#### 段 4a — 1 枚の描き出し（SoftRaster）

```flix
// engine_full/src/full/HeadlessFrame.flix（新しい小さな mod）
/// 窓なしで 1 コマを描く SoftRaster の道（比べ・reference-check に使う方）。GPU の 1 枚撮りは GpuShot（App の paintOnce の道）。
pub mod HeadlessFrame {
    /// 1 枚を PNG に描く（Pass を宣言順に描いてから本編と Shader 面）。計画の知らせ（PassPlanIssue）は 1 行ずつ出す。
    /// history は読まない（Pass の自分の名前は透明 — 描き出しの決まり）。
    pub def renderPlanPng(cfg: HeadlessRender.RenderConfig, texInfo: String -> Option[GameEngine.TextureInfo],
                          plan: Render.PassPlan, items: List[Render.PlacedItem], name: String): Unit \ IO
}
```

engine_tools（`HeadlessRender`）に置けないのは、engine_tools が engine_world を読まない（`Render.PassPlan` が engine_world）ため（1 回目 §9 の `RenderTarget.historyName` と同じ理由）。
VideoOut に置かないのは、VideoOut は動画の口で、1 枚の描き出しを探す人が VideoOut を開かないため。GPU で 1 枚撮りたい所は今の GpuShot を使う（ここでは足さない）。

#### 段 4b — 動画（GPU と SoftRaster の両方）

**`VideoOut.Video` に `passes` の欄を足す形は取らない。** `Video[w]` は閉じたレコードで、テンプレート 3 本が字で組んでいる
（`templates/rpg-starter/src/render/VideoRender.flix:137`・`templates/tidepool-starter/src/render/VideoRender.flix:174`・
`templates/sound-novel-starter/src/render/FlowVideo.flix:75`）。欄を足すと 3 本が止まる。代わりに関数を 1 つ足す。

```flix
// engine_full/src/full/VideoOut.flix
/// writeFrames の、本編より先に Pass を描く形。passes = 字のアトラスの引き口 → World → Pass の計画（実機の App.withPassPlan と同じ物を渡す）。
/// GPU の道は App.drawPassPlan で、SoftRaster の道は HeadlessFrame と同じ道で描く。
/// 鍵（drawhash.txt）には Pass ごとの描く命令も順に畳んで入れる（Pass の画像は塗らない — DrawHash.withPasses）。
/// history は動画でも毎コマ透明（どのコマから見ても同じ絵 — 1 回目 §2.1 の 3 の決まり）。
/// bakeSurfaces は本編の面にだけ効き、Pass の中の面は毎コマ評価する（時刻で変わる後処理を止めない）。
pub def writeFramesWithPasses(settings: Settings, video: Video[w],
                              passes: (String -> FontAtlas) -> w -> Render.PassPlan, worlds: List[w]): Painter \ IO
```

```flix
// engine_world/src/App.flix
/// Pass の計画を、本編より先に今の描き先へ描く（実機の毎コマと同じ道: resolvePassReads → 倍率 → drawShaders → renderCommands）。
/// known = これまでに作ったターゲットの名前（コマをまたいで増える。実機の TileCache#passTargets と同じ役）。返すのは次の known。
/// 実機の外で GL に描く所（VideoOut の GPU の道）が、App を持たずに同じ道を通るための口。
pub def drawPassPlan(warnOnce: String -> Unit \ ef, design: Vec2.Vec2, known: Set[String], plan: Render.PassPlan):
        Set[String] \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target)
```

- 中は今の非 pub の `App.renderPasses`（`App.flix:2299-2315`）の前に `resolvePassReads(known, plan)` を足した物。実機の道は今のまま
  （`renderFrame` が `tileCache#passTargets` で解決してから `renderPasses` を呼ぶ）で、二重に解決しない。
- **`warnOnce` の効果**: 今の `renderPasses` と `noteSurfaceZ`（どちらも非 pub）は `String -> Unit`（純粋）を受ける。VideoOut から `println` を渡すには IO が要るので、
  **2 つの型を `warnOnce: String -> Unit \ ef` に広げ、`ef` を外の効果に足す**。`drawPassPlan` も同じ型を受ける。外に出ない口なので互換は崩れず、
  実機の `warnOnce`（純粋）はそのまま渡せる。
- **GPU の道の字の欠け**: `paintOne` は本編の items の `Render.missingGlyphs` を見て字を足してから描き直す。**Pass の中の items も同じ集まりに入れる**
  （Pass の中の字が欠けたまま描かれないように）。
- `GlOffscreen.handle` は `RenderTarget.Target` を処理するので、GPU の道は `drawPassPlan` を呼んでから今の本編の描き方を続けるだけ。

#### 段 4b — 動画の鍵（engine_tools を触る）

今の鍵は `DrawHash.Frame`（`req`・`surfaces`・`extraFonts`・`fontAntialias`）から作り、Pass の欄が無い。Pass の絵を鍵に入れる今の道は
`RenderCache.keyOf` の extraImages（**塗った画像の画素の指紋**）で、鍵を作るために Pass を全部塗ることになる（round2b の指摘 7）。2 案:

| | (a) DrawHash に Pass の鍵を畳む口を足す（**採る**） | (b) 鍵のために Pass を塗る |
|---|---|---|
| 中身 | `DrawHash.withPasses(frameKey, passKeys)`: Pass ごとに「名前・倍率・LoadOp・その Pass の RasterReq と surfaces」から鍵を作り、宣言順に本編の鍵へ畳む | 今の extraImages の道に、塗った Pass の画像を入れる |
| 値段 | 鍵だけを流す回（`FGE_VIDEO_PAINT=none`）でも塗らない | 鍵だけの回でも全部の Pass を CPU で塗る（1 コマ数秒） |
| 触る所 | engine_tools の `DrawHash`（**段 4b は engine_tools を触る段**） | engine_full だけ |
| 今の鍵 | Pass の無い計画では今の鍵と同じ字（畳む物が空なら畳まない） | 同じ |

**(a) を採る（決めた事）。** 条件は次の 2 つ。

**1. Pass 1 枚の鍵を作る所を RenderCache に置く。** Pass の鍵には、その Pass の描く命令のほかに「その Pass が読む絵のファイルの指紋」が要る
（命令が同じでも、読む PNG が書き換わったら絵が変わる）。指紋は今 `RenderCache.keyOf` が `fileDigests`（セッションの持ち回し）と
`textureDigest`（塗る時のテクスチャの表）から取っているので、同じ所から取る:

```flix
// engine_tools/src/RenderCache.flix
/// Pass の列の鍵（宣言順）。1 枚ごとに「名前・倍率・LoadOp・その Pass の RasterReq と surfaces（DrawHash.Frame と同じ形）」と、
/// その Pass が読む絵のファイルの指紋（keyOf と同じ取り方）から作る。前に宣言した Pass を読む所は、その Pass の鍵を混ぜる（画素は塗らない）。
/// 鍵を作れない Pass が 1 枚でもあれば None（keyOf と同じ — 塗り直しに倒す）。
pub def passKeysOf(session: Session, passes: List[HeadlessRender.PassSpec], textures: SoftRaster.TextureCache): Option[List[DrawHash.Key]] \ IO
```

```flix
// engine_tools/src/DrawHash.flix
/// 本編の鍵に、Pass の鍵を宣言順に畳む。passKeys が空なら frameKey のまま（Pass の無いコマの鍵の字は今と同じ）。
pub def withPasses(frameKey: Key, passKeys: List[Key]): Key
```

**2. `RenderCache.writeFramePng` の「鍵がキャッシュにあれば塗らずに写す」鍵も (a) の鍵に寄せる（(i) を採る）。**
今の `writeFramePng` は `keyOf`（extraImages の画素の指紋込み）で引くので、Pass を持つコマでは鍵のために Pass を塗っている。
`writeFramePng` に Pass の列を受ける形（`writeFramePngWithPasses(session, passes, req, …)`）を足し、`passKeysOf` → `withPasses` で作った鍵で引く —
**drawhash.txt に書く鍵と、塗らずに写すかを決める鍵を同じ 1 か所から出す**（RenderCache の WhyNot「鍵と塗りを 1 か所から出す」と同じ考え）。
当たらなかった時だけ Pass を塗り、本編を塗って書く。今の `writeFramePng`（Pass の無い形）は今のまま残す（呼び手の鍵は変わらない）。

寄せられない時（実装で `PassSpec` の中の物が鍵に入らないと分かった時）は (ii): drawhash.txt の鍵は (a)、キャッシュの鍵は今の extraImages の道、と
**別物と明記して** 2 つを持つ。その時はキャッシュに当たっても Pass は塗ることになる（動画の速さは今と同じ）。

Pass の中の Shader 面の鍵は、本編と同じく Spec の JSON（Param は値の入った Const）から作る（round2a の Param の決まりと同じ）。
history は毎コマ透明なので、前のコマの鍵は混ぜない。

### 5.3 ゲーム側の あと

```flix
// 2 本の SceneRender.paint（5 行 → 呼び出し 1 行。specsOf も消える）
HeadlessFrame.renderPlanPng(cfg, texInfo, View.passPlanOf(input), View.frameOf(ctx, input), name)

// 2 本の VideoRender.writeVideo（自前の糸と paint → writeFramesWithPasses）
let painter = VideoOut.writeFramesWithPasses(VideoOut.settingsOf(env),
    { outDir = take#outDir, fps = fps, soft = cfg, softFonts = _ -> atlas, extraFonts = Map.empty(), images = images,
      scene = _ -> Resources.read((r, w) -> View.frameOf(ctx, View.inputOf(r, w))), wanted = _ -> true, bakeSurfaces = false, encoders = Nil },
    _ -> Resources.read((r, w) -> View.passPlanOf(View.inputOf(r, w))), painted)
```

flow の区間（mark の `in_` / `out_`）を選ぶ所は試作に残る（`segmentsOf`。VideoOut の外の決まり）。

`docs/headless-render-recipe.md` の「pass を使う場面」は、engine_full を借りる時の `HeadlessFrame.renderPlanPng` の 1 行と、engine_tools だけを借りる時の今の 3 行を表に並べる。
GPU で 1 枚撮りたい時は GpuShot を案内する 1 文を足す。

### 5.4 後方互換

足すだけ。`writeFrames` と `Video[w]` は今のまま。`App.renderPasses` と `App.noteSurfaceZ` は非 pub のまま、`warnOnce` の型だけを `String -> Unit \ ef` に広げる（外に出ない口なので互換は崩れない。実機の `warnOnce` は純粋なので `\ ef` にそのまま入る）。
`DrawHash` は畳む口を足すだけで、Pass の無いコマの鍵の字は変わらない（今の動画の `drawhash.txt` と compare は前と同じ）。

### 5.5 テスト

| 段 | どこ | 確かめること |
|---|---|---|
| 4a | engine_full の test | Pass 1 枚（赤で Clear）と、その Pass を貼る本編の計画で `renderPlanPng` → PNG の真ん中の画素が赤 |
| 4a | 試作 | `SceneRender.paint` を置き換えた前後で §0.2 の 1 |
| 4b | engine_tools の test | `DrawHash.withPasses(k, Nil)` = k |
| 4b | 同 | 中身の同じ Pass の並びを入れ替えると鍵が違う（順に畳む） |
| 4b | engine_world の test | `drawPassPlan` の返す known = 前の known ∪ このコマの Pass の名前（ハンドラを stub にして 1 回） |
| 4b | engine_full の test | `writeFramesWithPasses` を鍵だけ（`FGE_VIDEO_PAINT=none`）で 2 コマ: Pass の中身だけが違う 2 つの World → 鍵が違う |
| 4b | 同 | 同じ World 2 つ → 鍵が同じ |
| 4b | 同 | Pass の無い計画（`Render.passPlan(Nil)`）の鍵 = `writeFrames` の鍵 |
| 4b | 試作 | 港とダンジョンの `make video` を前後で回し、SoftRaster の道（`FGE_GPU=off`）のコマの PNG が前の自前の道とバイト一致。GPU の道は見るだけ |
| 4b | 速さ | 動画は「作る人が払う」1 回だけの物（`docs/performance.md` §1 の予算の門）。合否線は実時間の背中合わせで 1 割。GPU の道に乗れば今の CPU 4 本より速くなる見込み |

### 5.6 消える行・汎用性・入れない物

- 消える行: 港 約 40（`VideoRender` の `writeVideo` / `paint` / `frameName` と `SceneRender.paint` / `specsOf`）・ダンジョン 約 35。
- 汎用性: Pass を使う全部のゲームの動画と描き出し（今 Pass を使うテンプレートは無いが、PostFx を使えばすぐ要る）。
- **入れない: `App.frameOf`（1 コマで描く物を 1 か所で組む）**。round2b の D1 と同じで App の中心の組み直しになる。
  タイル層・静的層を Pass と一緒に動画へ入れる件（round2b の指摘 2）もそこで扱う。今回は「ゲームが組んだ計画と描き物を受けて描く」だけ。
- **入れない: 動画で history を写す**。どのコマから見ても同じ絵、の決まり（GIF と同じ）を変えることになる。

---

## W. シェーダーを前もって作る口 — 段 6

### W.1 今の困りごと

GL は Spec を初めて描くコマで GLSL を組んでリンクする（`RenderPaint.buildProgram`）。3D の面の Spec は 1 本で数十 ms〜数百 ms かかり、
全部が同じコマに来るとそのコマが止まる。2 本の試作は自分で「1 コマに 1 本ずつ描かせ、その間は黒で覆う」を書いている。

| 場所 | 中身 |
|---|---|
| 港 `Harbor3dShader.warmOrder`（`Harbor3dShader.flix:96-97`）・`Harbor3dView.enterFrame` / `WarmStage` / `warmStage` / `warming` / `coverAlpha`（`Harbor3dView.flix:137-171`）・`built` の中の分かれ（`Harbor3dView.flix:212-224`） | 入った直後の n コマは、その Spec の面だけを描く。その後 2 コマで置き物・人を足す。覆いは 0.3 秒で外す |
| ダンジョン `DungeonShader.warmOrder`・`Dungeon3dView.warming` / `coverAlpha`（`Dungeon3dView.flix:113-122`）・`built` の中の分かれ（`Dungeon3dView.flix:193-200`） | 同じ（覆いは 0.4 秒） |

困る所:
- **描かせて作る**ので、作るためだけに面を選び分ける分かれが場面の組み立てに入る（`faces |> List.filter(… name == name or name == depthName())`）。
- 作ったプログラムは LRU（`RenderPaint.evictShaderPrograms`）の対象。**前もって作っても、使われないコマが続くと追い出されうる**（下の W.2 の LRU の動き）。
- World が「何コマ目か」を数える欄（`enterFrames` / `frames`）を、作り分けのためだけに持つ。

### W.2 LRU の今の動き（決まりの前提）

`RenderPaint.evictShaderPrograms` と `buildProgram` を読んだ所:

- **追い出しは `buildProgram` が miss した時（新しく作った時）にだけ走る。** 当たりの時は使用の印（`programUsedAt` を今の世代 gen に）を付けるだけ。
- 追い出しで守られるのは、**`usedAt == gen`（今の世代で使った物）** と **前のコマに画面へ出した面（`lastFrameHolder#surfaces`）** と fallback だけ。
- **gen が進むのは画面の submit の 1 か所だけ**（1 コマに 1 回。Pass の中の描きでは進まない）。
- 上限は「今の世代で使った数 × 2（最低 16）」。

だから「作ったコマの次から使われないコマが続いた物」は、別の Spec の miss の時に追い出されうる。守るには、**そのコマで miss が起きる前に、守りたい物全部に
今の世代の印を付けておく**ことが要る。

### W.3 口の形

```flix
// engine_world/src/App.flix
/// 前もって GPU に作っておく Spec の列（Unity の ShaderVariantCollection.WarmUpProgressively と同じ考え方）。
/// 実機は 1 コマに 1 本ずつ、まだ作っていない Spec を作る（描かない）。作り終えた Spec は、この列に載っている間は追い出さない。
/// 列は毎コマ読み直す — Doc を読み直して Spec が変わった（同じ名前で中身が違う）ら、それを作り直す。
/// 列には描く物と同じ Spec を同じ参照で載せる（Res に作り置いた値をそのまま）。
/// Pass の中で他の Pass を読む Spec は載せない — resolvePassReads が renameTex で書き換えた別の値を描くので、ここで作っても当たらない。
/// 描き出し・GL の 1 枚撮り（paintOnce・GpuShot）・動画・flow・テストでは何もしない。
pub def withShaderWarmup(f: w -> List[ShaderDoc.Spec] \ ef, app: App[w, ef]): App[w, ef]

/// 作り終えるまで画面を覆う色と、作り終えてから覆いを外すまでの秒（付けなければ覆わない）。
pub type alias WarmupCover = { color = Color, fadeSeconds = Float64 }
pub def withShaderWarmupCover(cover: WarmupCover, app: App[w, ef]): App[w, ef]
```

```flix
// engine/src/core/ZBand.flix
/// warmup の覆いの z（HUD の範囲より手前・デバッグ表示より奥）。Transition（100000）と HUD（hudBase 〜）も覆う。
pub def warmupCoverZ(): Int32 = 1_500_000_000
```

`docs/z-bands.md` の表に 1 行足す: 「warmup の覆い | 1,500,000,000 | `App.withShaderWarmupCover` の覆い | HUD より手前・デバッグより奥 | engine が窓の時だけ描く」。

**1 コマの中の順（決まり）:**

1. 実機のループ（`App.loop`。窓の時だけ）は、そのコマの `renderFrame` の**前**（`renderPasses` より前）に、`f(w)` と作った表から
   `ShaderWarmup.plan` を出す。
2. **先に `touch` の全部を `buildProgram` に渡す。** 作った表の Spec と同じ参照なので `isSameSpec` で当たり、miss は起きず、今の世代の印だけが付く。
3. **その後で `build` の 1 本を `buildProgram` に渡す。** これが miss で追い出しを走らせても、2 で印を付けた物は `usedAt == gen` で守られる。
4. その後で `renderFrame`（Pass → 本編 → submit で gen が進む）。

`touch` の印は「このコマの世代で使った数」に入るので、`evictShaderPrograms` の上限（× 2）も一緒に上がる。列に何百本も載せると
GPU のメモリを持ち続けるので、doc に「今の場面と次に行きうる場面の分だけ」と書く。

```flix
// engine_world/src/App/ShaderWarmup.flix（非 pub の mod で、App.loop が呼ぶ）
/// 作った表と今の列から、このコマに渡す順。touch を全部渡してから build を渡す（逆にすると build の miss の追い出しが touch の物を捨てうる）。
/// touch = 作り終えた Spec（列の順）・build = まだ作っていない最初の 1 本・pending = 作り終えていない本数（build を含む）。
def plan(built: Map[String, ShaderDoc.Spec], wanted: List[ShaderDoc.Spec]):
        { touch = List[ShaderDoc.Spec], build = Option[ShaderDoc.Spec], pending = Int32, built = Map[String, ShaderDoc.Spec] }
```

**`plan` の比べ方**（`RenderPaint.buildProgram` の当たりの決め方と同じ順）: 列の Spec ごとに、表の同じ名前の Spec と

1. **まず `ShaderGen.isSameSpec`（参照が同じか）。** 当たれば touch へ。毎コマはほぼ全部ここで抜ける（Res に作り置いた値をそのまま載せるので）。
2. **外れたら `ShaderGen.eqSpec`（木を丸ごと比べる）。** 中身が同じなら、**表の値を新しい方の参照に替えて** touch へ（次のコマから 1 で抜ける。
   古い方を持ち続けると毎コマ木を比べ続ける — `buildProgram` の doc と同じ理由）。表を替えるので、`plan` は新しい表も返す
   （返り値の `built`。build に渡した Spec は、次のコマに `buildProgram` が返った後で表に入れる）。
3. **中身が違えば build の候補へ**（同じ名前で中身の違う物 = Doc の読み直し）。候補の最初の 1 本だけを build にし、残りは pending に数える。

**止めた時と /perf**:

- **`pausedStep`（F8 で止めている間のコマ）**: 描き続けるので touch は回す（止めている間に LRU が他の面を作ると、touch しない物が追い出されうる）。build は回さない
  （止めた絵を調べている間に止まりを足さない。覆いも今の濃さのまま）。
- **`perfPaint`（`POST /perf` で flow を流して塗る側を測る）**: touch も build も回さない。測る前の `warmup` のコマで初めてのシェーダーは作り終わり、
  測る区間で warmup の口が 1 本作ると、その 1 コマの止まりが測りに入る。§0.2 の 2 の速さの比べは、warmup の口の有る無しで変わらない形にする。

**覆い**:

- `withShaderWarmupCover` を付けた時だけ。まだ作っていない Spec が列にある間は不透明、全部作ったら `fadeSeconds` で 0 へ（実時間の時計で進める
  — 遊びの時計が止まっていても外れる。`docs/clock.md`）。
- **覆いは `Look#fixed`（実機のループが `renderFrame` に渡す「画面に付いた描き物」の欄）に乗せる。** `App.loop` の側（窓の時だけ）が
  `ZBand.warmupCoverZ()` の画面全面の box を 1 枚 `Look#fixed` に足す。`renderFrame` の中身には何も足さない。
  `paintOnce`（GL の 1 枚撮り・GpuShot・動画）は `plainLook(Nil)` を渡すので、**1 枚撮りには覆いが写らない**。
- 覆いは**本番のビルドでも入れる**（デバッグの道具ではない。遊ぶ人が初めの数コマの止まりの代わりに見る物）。fps の重ねなど `debug` の時だけの物とは分けて、
  `App.debug` を見ない。
- z が HUD の範囲より手前なので、Transition も HUD も覆う。デバッグ表示（`debugBase` 2,000,000,000 〜）は覆わない（作り中でも fps と知らせは見える）。

**だから静止画は変わらない**（描き出し・1 枚撮りでは warmup も覆いも動かない。今の試作も、描き出しは `frames = 1000` で作り分けの外にいる）。

### W.4 ゲーム側の あと

```flix
// 港 Main
|> App.withShaderWarmup(Resources.read((res, _) -> List.append(Harbor3dShader.specList(res#harbor3dSpecs), PostFx.specsOf(res#post3d))))
|> App.withShaderWarmupCover({ color = Color.rgb(0.0, 0.0, 0.0), fadeSeconds = 0.3 })
```

- `PostFx.specsOf` のうち、Pass を読む Spec（bright・blur・composite）は `resolvePassReads` が読みの名前を書き換えうる。書き換えが起きない計画
  （読む Pass が全部前に宣言されている）なら同じ値のまま描かれるので載せてよい。**書き換えが起きる計画（後ろの Pass を読む・自分の history を読む）の Spec は載せない**
  （doc と `PostFx.specsOf` の doc に書く。PostFx の chain は前の Pass しか読まないので、深さの Pass を before に入れていれば当たる）。
- 港の `warming` / `WarmStage.Shader` / ダンジョンの `warming` と `built` の中の分かれが消える。
- 港の「その後 2 コマで置き物と人を足す」（`FacesOnly` / `FacesAndProps`。初めて通る組み立ての CPU の重さを分ける）はシェーダーの話ではないので**ゲームに残る**。
  `enterFrames` もその 2 コマを数えるために残る。
- 黒の覆いは engine の覆いに替える。港の「入るたびに覆う」（3D の港へ入った時だけ）は、列を「今の場面の Spec」にすれば、入った時に初めて列に載るので
  その時に覆いが掛かる。起動時に全部載せれば、起動の時に 1 回だけ覆う（以後は W.2 の守りで追い出されない）。

### W.5 後方互換

足すだけ。付けないゲームは今のまま（初めてのコマで作る）。`ZBand` は定数を 1 つ足すだけ。

### W.6 テスト

| どこ | 確かめること |
|---|---|
| TestShaderWarmup（engine_world） | 空の表・列 [A, B] → build = A・touch = []・pending = 2 |
| 同 | 表 {A}・列 [A, B] → build = B・touch = [A]・pending = 1 |
| 同 | 表 {A（古い中身）}・列 [A（新しい中身）] → build = 新しい A・touch = []（中身が変わったら作り直す） |
| 同 | 表 {A}・列 [A と中身が同じ別の値 A'] → touch = [A']・build = None・返す表の A の値が A'（参照を新しい方に替える） |
| 同 | 表 {A, B}・列 [A] → touch = [A]・build = None（列から外れた B は印を付けない — LRU に任せる） |
| 同 | 覆いの濃さ（純粋な関数に出す）: pending > 0 → 1・作り終えて fadeSeconds の半分 → 0.5 |
| render_gl の test（既存の `RenderShaderCache.computeEvictions` の形で） | pinned に touch の program が入っていれば、上限を超えても victims に入らない（今の関数のまま確かめる — 新しい振る舞いではなく、前提の確かめ） |
| 実機（GL） | §0.2 の段 6 の条件: warmup が終わった後、港の 3D の港の出入り・ダンジョンのフロアの移動を 3 回ずつしても `FrameDiagnostics` の `shaderBuilds` が 0 件 |
| 実機（GL） | 入った直後の止まり（`App.HitchDetector` の知らせ）が、今の自前の作り分けと同じか少ない（見るだけ・3 回） |

### W.7 消える行・汎用性・入れない物

- 消える行: 港 約 30（`warming` / `WarmStage.Shader` / `coverAlpha` / 分かれ / `warmOrder`）・ダンジョン 約 20。
- 汎用性: 宣言シェーダーの面を多く持つ全部のゲーム（3D の面・後処理・Backdrop）。Shader 面の多い画面に入る時の止まりはどのゲームでも出る。
- **入れない: 描き出しでの事前評価**。SoftRaster は面を画素ごとに評価するだけで「作る」段が無い（作り置きの代わりは VideoOut の `bakeSurfaces`）。
- **入れない: GLSL を別の糸で組む・プログラムのバイナリを保存する（`glGetProgramBinary`）**: GL の文脈は 1 本の糸にしか無く、バイナリは GPU と
  ドライバの版ごとに作り直しになる。1 コマに 1 本で足りている。
- **入れない: render_gl にピン留めの表を足す**: W.3 の順（touch → build）で今の LRU のまま守れる。`eff Shader` に op を足すと全部のハンドラが波及する（`ShaderEffect` の doc）。
- **入れない: 準備ができたかを World へ知らせる口（`App.Frame` に欄）**: `Frame` は閉じたレコードで、テストが字で組んでいる所を全部止める。
  覆いを engine が描けば、ゲームが知る必要は無い。

---

## 6. 振る舞いが変わる所（後方互換の例外）

| 変わる所 | 誰に効くか |
|---|---|
| `ShaderDoc.smoothstepF` / `ShaderEval.smoothstep` の中を `Num.smoothstep` に | 無い（非 pub・同じ式） |
| `ShaderDoc.lengthOf` / `normalized` の中を `Nodes` に | 無い（返す木が同じ）。`forbid.json` が新しく書いた行を止める |
| `Descriptor` の doc の書き方の勧め | 無い（字は今のままでも通る） |
| `DrawHash` に Pass の鍵を畳む口（段 4b） | 無い（Pass の無いコマの鍵の字は同じ） |

ほかは全部「足すだけ」。`VideoOut.Video`・`App.Frame`・`eff Shader`・`Field`・render_gl は変えない。

---

## 7. 推奨（採った形）と、人に決めてほしい事

### 7.1 採った形（レビューの推奨）

| # | 採った形 | 節 |
|---|---|---|
| 1 | `ShaderDoc.Nodes`・`saturate`・`lerp` = Blend（0..1 に収めると doc に書く）・数は `constant`・`time()` を足す | §1.2 |
| 2 | `lengthOf` / `normalized` は 1 リリース残し、`forbid.json` で止める | §1.3 |
| 3 | 色は型の付いた鍵（案 B）。`Render.withShaderColor` は入れない（`ShaderDoc.withColorParam` + 既存の `withShaderParams`）。`FloatParam` は後回し | §2 |
| 4 | 凸包は `Geometry2D.convexHull` | §3.2 |
| 5 | ダンジョンの指数の寄せはゲームに残す（`smoothTo` は足さない） | §3.5 |
| 6 | テンプレートの `contentKey` への書き換えはこの回に入れない | §3.3 |
| 7 | 手前のぼけは `depthOfField.nearScale` 1 つ（画面ごとの Doc に） | §4.2 |
| 8 | fog は入れる。熱のゆらぎは distortion の場だけ受ける | §4.4 |
| 9 | ピントを掛けない形（改訂 3 で `buildNone` / `Built[NoFocus]`）を足す | §4.2 |
| 10 | Pass・Spec・Param の名前は `postfx_*` に固定 | §4.2・§4.6 |
| 11 | 動画は欄を足さず関数を足す。1 枚の描き出しは engine_full の新しい `HeadlessFrame`（GPU の 1 枚撮りは今の GpuShot） | §5.2 |
| 12 | 覆いは engine が描く。`ZBand.warmupCoverZ` を足し、`App.loop` の側だけで描く。`Frame` の欄は入れない | §W.3 |
| 13 | warmup（段 5）は PostFx（段 5a・5b）の後 | §0.1 |

### 7.2 まだ人に決めてほしい事

無い（改訂 2 の 3 つは改訂 3 で決まり、§7.1 の 14〜16 に移した）。実装の途中で §5.2 の (i) が通らないと分かった時だけ、(ii) にするかを相談する。

---

## 8. レビューの指摘への答え

### 8.1 レビュー（71 点）→ 改訂 2

この表の段の番号・節の名前・§7.2 の番号は改訂 2 の時の物（改訂 3 で 段 5 → 段 6・段 6a / 6b → 段 5a / 5b・§5b → §W・§7.2 の 3 つは §7.1 の 14〜16 へ）。

| 指摘 | 直した所 |
|---|---|
| 1 warmup の LRU（追い出しは miss の時だけ・守りは `usedAt == gen` と前のコマの面だけ・gen は submit の 1 か所） | §W.2 に今の動きを書いた。§W.3 に「renderFrame の前に touch を全部 → その後で build 1 本」の順を決まりとして書き、`ShaderWarmup.plan` の返り値（touch / build / pending）に順の意味を持たせた。列には描く物と同じ Spec を同じ参照で載せ、`resolvePassReads` が書き換える Pass の Spec は載せない（§W.3 の doc・§W.4） |
| 2 動画の鍵に Pass の欄が無い | §5.2「段 4b — 動画の鍵」に (a) `DrawHash.withPasses` と (b) 鍵のために塗る、を比べて (a) を採った。段 4b を engine_tools を触る段と明記（§0.1）。テスト §5.5・決めてほしい事 §7.2 の 1 |
| 3 `drawPassPlan` の knownTargets・字の欠け・history・warnOnce の効果 | §5.2: `drawPassPlan(warnOnce, design, known, plan): Set[String]` で持ち回す形に。GPU の道の `missingGlyphs` に Pass の items も入れる。history は動画でも毎コマ透明。`warnOnce` は `String -> Unit \ ef` にし、通らない時の逃げ道も書いた。テスト §5.5 |
| 4 凸包の説明が逆 | §3.2: 画面（y 下向き）では時計回り・始まりは左の上・1 点 → 空・同じ 2 点 → [p,p] を書き、engine は重なりを先に除く形にして doc と縮退の答えを直した |
| 5 `PostFxDoc.load` が error-handling の決まり 1 に反する | §4.3: `fromJson` / `load` は Result・`loadOr(fallback, path)` を分けた。ファイルが無いのは黙り、有るのに読めない時だけ `Log.fellBack`。AudioMixerDoc を手本にしないと書いた |
| 6 Focus のずれ・Param の名前・深さの Pass が無い時 | §4.2: `Built` を FocusMode ごとの型の印で分け、composite を 3 つにした（`bug!` の案は §7.2 の 2）。Param は全部 `postfx_` で始める。`buildDepth` の Pass が before に無い時は chain で 1 回知らせる（テスト §4.9） |
| 7 覆いの z | §W.3: `ZBand.warmupCoverZ()` = 1,500,000,000 を足し、`docs/z-bands.md` に 1 行。覆いは `App.loop` の側（窓だけ）で描き、`renderFrame`（paintOnce・GpuShot）には入れない。Transition と HUD も覆う |
| 8 GpuShot と `App.paintOnce` が既にある | §5.1 に「すでにある物」として書き、§5.2 を書き直した: GPU の 1 枚撮りは GpuShot のまま、SoftRaster の 1 枚は engine_full の新しい `HeadlessFrame.renderPlanPng`、動画の GPU の道は `drawPassPlan` |
| 9 合格条件の 3 | §0.2 の 3 を `make test-all`（または `make test-<テンプレート名>` 4 本）と `reference/SHA256SUMS.txt` の一致に替えた。game-starter の記述は消した |
| 10 `cellHash` の doc | §1.2: cu / cv は升目の中心（floor + 0.5）と書いた |
| 11 smoothstep の掛け算の順 | §3.1 の表: 2 か所の occluderAlpha は置き換えない（置き換えるなら「バイトが変わりうる」） |
| 12 `Focus.Depth#nearScale` | §4.2: 毎コマの値から外し、`depthOfField.nearScale`（画面ごとの PostFxDoc）へ移した。§4.5 の読み替え表も直した |
| 13 段を分ける・ゆらぎの木の順 | §0.1: 段 6 → 6a / 6b、段 4 → 4a / 4b。§0.2 に段ごとの条件。§4.4 にぼけの読みは `linear(shift(tex))` の順と書き、テスト §4.9 に足した |
| 14 GL の合格条件・速さの許し幅 | §0.2: 段 5 は「warmup の後、場面を出入りしても `shaderBuilds` が 0 件」。速さは avg ±5%・p99 ±10%（3 回の中央値） |
| 15 名前と細かい直し | `scaledDescriptor`（§3.4）・`TiltShift` / `bloomSources` / `sampleOffset`（§4.2）・`contentKey` の doc を「ほぼ」に（§3.3）・`colorParam` の使えない prefix は `bug!`（§2.2）・Nodes に `time()`（§1.2）・`Num.smoothstep` は「Godot の smoothstep と同じ」（§3.1）・段 2 などで `make sync`（§0.1） |
| §7 の推奨 | §7.1 の表に採った形を並べ、§7.2 に残りの 3 つだけを置いた |

### 8.2 再レビュー（84 点）→ 改訂 3

| 指摘 | 直した所 |
|---|---|
| N1 型の印の書き方（非 pub の enum + pub の別名は E8176） | §4.2: 印は case の無い `pub enum NoFocus` / `TiltShiftFocus` / `DepthFocus`、本体は `enum BuiltData[_: Type](…)` + `pub type alias Built[f]`（`Clock.Stamp` と同じ形）。`pub enum FocusMode` は消して doc の語だけに。`Options` は `{ screen, distortion }` にそろえ、3 つの `build*` の引数の型に |
| N2 `renderPasses` / `noteSurfaceZ` の効果の型 | §5.2: 2 つ（非 pub）の `warnOnce` を `String -> Unit \ ef` に広げると書き、「通らなければ後で println」の逃げ道を消した。§5.4 の「中身も変えない」を直した |
| N3 Pass 1 枚の鍵・`writeFramePng` との関係 | §5.2: `RenderCache.passKeysOf(session, passes, textures)` で読む絵のファイルの指紋ごと鍵を作る。`writeFramePng` の写しの鍵も (a) に寄せる (i) を採り（`writeFramePngWithPasses`）、通らない時の (ii) を別物と明記 |
| N4 `plan` の比べ方・止めた時と /perf | §W.3: `isSameSpec` → `eqSpec` の順、中身が同じなら表を新しい参照に替える（返り値に `built`）、違えば build へ。`pausedStep` は touch だけ・`perfPaint` は回さない。テストに 1 行（§W.6） |
| N5 覆いの乗せ所 | §W.3: `Look#fixed` に乗せる（`paintOnce` は `plainLook(Nil)` なので 1 枚撮りに写らない）。本番のビルドでも入れる |
| N6 段ごとの門 | §0.2 の 3: 段ごとは `make test-<テンプレート名>` 4 本と SHA256SUMS の一致。`make test-all` は全部の段の後の 1 回だけ |
| N7 段の番号 | §0.1 と本文: 1 → 2 → 3 → 4a → 4b → 5a（PostFx）→ 5b（PostFxDoc）→ 6（warmup）に振り直し。warmup の節は段の番号とぶつからないよう §W に改名 |
| N8 誤りの型の字 | §4.3: `Util.Json.JsonError` にそろえた |
| 決めた事 1〜3 | §7.1 の 14〜16 に移し、§7.2 は「無い」に |
