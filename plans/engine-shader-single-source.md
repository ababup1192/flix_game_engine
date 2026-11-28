# 3D のシェーダーを 1 つの元から GLSL と WGSL へ出す — 計画（相談用・未着手）

L5 SSAO・L6 多数の点光源・L7 volumetric fog（`plans/engine-render-look-stage.md` の 9 節）の前に、
`render_gl/src/Render3dGlsl.flix` と `render_gl/src/Render3dWgsl.flix` に 2 回書いてある 3D の frag・vertex を 1 つの元から作る形へ移す。
あわせて、属性を 1 つ足すたびに払う配線（GL の uniform を手で 4 か所・変種の欄の書き並べ約 10 か所）を表 1 つにする。
コードはまだ書いていない。数字は 2026-11-26 の main（v0.116.0 の後・e44d8a0d8）で引いた。

## 0. 結論

1. **推す案は C: render_gl に小さな型つきのシェーダーの AST（仮の名前 `ShaderAst`）と、GLSL・WGSL の 2 つの printer を作る。**
   材質・影・PS1 風・ビルボード・空・頂点の組み立てを AST で 1 回だけ書く。
   すでに生成している所（`LightModel3d.Codegen`・`PointShadowCodegen`・`ShaderGen` の材質の部品）は今の字のまま、
   依存（読む関数・大域の変数・uniform）を宣言した **extern 関数**として AST に差し込む。engine の型は変えない。
2. GLSL と WGSL の**意味の違い**は 19 個（2 節）。printer の決まりか、言語ごとに中身の違う組み込みの関数に閉じ込める。
   構文だけの違い（`let`・`vec3f`・`select`・`{ }`）は printer が吸収する。
3. **範囲に入れる**: (a) シェーダーの 1 本化、(b) GL の uniform の宣言と location を同じ表の handle から作る（今は手で 4 か所。location は `Map[handle, Int32]` 1 つにして 10 個の `*Locs` の record と `loc(…)` 99 か所を消す）、
   (c) 変種の欄を表 1 つにし、GL と WebGPU が共有する約束（`ProgramKind`・`ShaderVariant`・`materialKey`）を `Render3d.flix` から別の mod へ出す。
   (b)(c) は (a) の uniform の handle と feature の関数の土台なので、分けると 2 回直すことになる。
   **範囲の外（別の段階として並べる）**: (d) CPU の光の入力を位置の enum から record へ（engine_tools・シェーダーの字と独立）。7 節。
4. 段階は S0〜S7 の 8 つ。**S1 は GLSL の字を 1 バイトも変えない**（書き出した全部の版の字の差が空）。S2 以降は差を読んで意図した物だけと確かめ、
   gl-parity の全場面 0 px・webgpu_v2・scene3d の gl-capture-check（PS1 風の版も）・ブラウザで確かめて、SHA を同じコミットで直す。
5. 見積もりは **27.5〜38.5 時間**（レビュー 3 回と門を含む。内訳は 5.1・元にした実績は 5.3）。段階ごとに見積もりの 2 倍を超えたら止めて相談する（止めた時の形は 5.4）。
   L4 と段 1 の 1d が main に入った後に始める（同じファイルを直すため）。
6. 正直に書いておく事: AST が役に立つのは **L5・L7 の GPU 側の新しいシェーダー**と、L1 の `+sh` のような**フラグと uniform を足す配線**。
   **L6 の光ごとのループは engine の `LightModel3d.Codegen` の中**なので、AST はほとんど役に立たない（3 節の案 C の弱み）。

## 1. 今の棚卸し

### 1.1 2 回書かれている物

2 ファイルの合計は 1,361 行（GLSL 704・WGSL 657）。うちシェーダーの字の行は GLSL 379・WGSL 322、コメントは 122・110。
同じ名前の関数の組は **34 個**（GLSL 553 行・WGSL 412 行。outline の突き合わせ）。主な物（行は doc コメントを含む関数の行の数）:

| 関数（GLSL の名前） | GLSL | WGSL | 違いの種類（2 節の番号） |
|---|---|---|---|
| `colorSpaceSource`（sRGB と線形の行き来） | 9 | 9 | 構文だけ（スカラーの式は `Texture3d` が両方を生成） |
| `surfaceOutSource`・`r3d_surfaceOutLit` | 6・4 | 6・4 | 構文だけ |
| `shadowSource` の `shadowLitFraction`（PCF） | 20 | 21 | 2.1 行の向き |
| `spotShadow`・`sunLitAt`・`depthGraySource` | 4・7・5 | 4・8・4 | 2.2 uniform の置き場 |
| `pointShadowSource` の包み（中身は `PointShadowCodegen`） | 11 | 7 | 大域の配列の置き場（`var<private>`） |
| `colorDepthSource`（PS1 風の色の丸め） | 19 | 18 | 2.5 画素の原点・2.6 表の置き場 |
| `vertexSnapSource`（PS1 風の頂点の丸め） | 8 | 8 | 2.7 |
| `applyNormalMapSource`・`environmentUvSource` | 10・5 | 10・6 | 2.11 `?:` と `select` |
| `normalMapSource`・`lightmapSource` | 10・18 | 5・6 | 2.3・2.12 |
| `environmentSource` の `environmentColorAt` | 17 | 9 | `textureLod` と sampler（構文） |
| `lightSourceFor`（uniform の宣言・`fogged`・変種の置き場） | 29 | 14 | 1.2 の uniform の宣言・置く順 |
| `materialFragmentSource` ＋ WGSL の `inputStruct` | 62 | 55 + 14 | 2.4・2.10・表裏の取り方 |
| `litFragmentSourceFor`・`depthFragmentSource` | 15・12 | 18・7 | 入口の形・WGSL の depth は vWorld だけを受ける |
| 頂点（`meshVertexSourceOf`・`materialVertexSourceFor`・1 体ごとの値・骨） | 約 196 | 約 128 | 2.8・2.9・2.6 |
| ビルボードの vertex | 34 | 49 | 2.13・2.16・2.17 |
| ビルボードの frag（WGSL は影の地図の frag が別に 1 本） | 27 | 23 + 6 | 2.13・2.18 |
| 空の frag と `skyLightSource`・空の vertex（GL は `blitVertexSource`） | 36 + 8 | 33 + 6 | 2.14・2.19 |

Render3dWgsl の頭の「式は Render3dGlsl と 1 行ずつ同じに書き」を機械で守っているのは `TestRender3dWgslPairs` の 3 本
（PCF・法線マップ・環境マップの読みで、数のリテラルの並びが同じか）だけ。

ほかに WGSL の字を持つ render_gl のファイルが 2 つある: `Render3d/WebGpuMipmaps.flix`（mip を作る全画面の Pass）・`Render3d/WebGpuShadowCache.flix`（影の地図の写し）。
どちらも WebGPU だけの物で GL に対の字が無いので、この計画では移さない（4.3 の lint から外す）。

### 1.2 すでに 1 つの元から作っている所と、表を通らない所

| 元 | 出口 | 中身 |
|---|---|---|
| `LightModel3d`（engine。`ScalarExpr`・`Vec3Expr`・`Cond` の木） | `LightModel3d.Codegen.toGlsl`・`toWgsl`・`generateFlix`（CPU） | 光・かすみ・空・PBR・環境の向き・lightmap の光。光ごとのループ（`Stmt.Loop`）と光の uniform の名前（`glslUniformOf`・`wgslScalarField`）もここ。式だけで、絵の読み・discard は無い |
| `PointShadowCodegen`（engine。小さな `Expr`・`Step` の木と `Dialect`） | GLSL・WGSL・Flix | 点光源の影の地図を引く式 |
| `ShaderGen`（engine。ShaderDoc → 字を直に組む。WGSL かどうかは `Map` の鍵 `@mode:wgsl` で切り替え） | `compile3d`・`Wgsl.compile3d` | 材質の `materialEval` とノイズの関数。GLSL 版は大域の `vUv`・`vWorld`・`vNormal`・`vColor` と自分の uniform を読む。`cutoutAlpha` は main の中の `albedo` を読む式の字 |
| `Render3d.UniformLayout`（render_gl） | WGSL の `R3dScene`・`R3dLight` の struct と、詰める側のバイト位置 | **GLSL の側は表を通らない** |

GL の uniform は 1 つの欄を **手で 4 か所**に書く: GLSL の宣言の字（`lightSourceFor`・`shadowSource`・`environmentSource` などに散る）・
location の record（`Render3d.LightLocs` ほか）・location を引く字（`loc(gl, program, "uShadowOn")`。`Shadow.flix`・`Material.flix`・`Light.flix`・`Render3d.flix`・`VariantPrograms.flix`）・値を差す所（`Render3d/Light.flix`）。
綴りを違えると location が `-1` になり、エラーを出さずに読み飛ばされる。

同じ欄でも言語ごとに型と読み方が違う物がある（uniform の handle が言語ごとの宣言の型と読む式を持つ理由）:
- `uPointRange`・`uSpotRange`・`uSpotCone`: GLSL は `float[N]`・`vec2[N]`、WGSL は 16 バイト刻みに合わせた `Vec4Array` を `.x`・`.y` で読む（`UniformLayout.sceneFields`・`Codegen.wgslScalarField`）。
- 空: GLSL は `uEnvOn` と `uViewport`、WGSL は `r3d.uSkyUp.w > 0.5` と `uSkyForward.w`・`uSkyRight.w`（別の欄の w に詰めてある）。
- cutout: GLSL は `int`、WGSL は `f32`（2.4）。

### 1.3 変種のフラグが分かれている所

`Render3d.ShaderVariant`（= engine の `Scene3d.PreloadVariant`。`pointShadows`・`physicalUnits`・`psx` の 3 つ）と、材質の版 `Render3d.ProgramKind`（Bool 11 個）。
字の上の分岐: Render3dGlsl は `if (` 55 個（`psx` を含む行 46・`v#pointShadows` 5・`v#physicalUnits` 2）、Render3dWgsl は `if (` 70 個（`psx` 38・`v#pointShadows` 5・`v#physicalUnits` 1）。
**PS1 風のフラグだけで分岐の 4 割ほど**。

変種の欄を全部書き並べる所が約 10 か所ある: `defaultShaderVariant`・`shaderVariantOfKind`・`billboardVariantOf`・`lightVariantOf`（`Render3d.flix:202-225`）・`Counts` の bit・
`VariantPrograms`・`WebGpuRenderer.layoutCodeOf`・`Render3dWgsl.variantDeclarations` の「全部偽か」・`Render3dGlsl.lightSourceFor`・`Scene3d.preloadVariantOf`・`preloadVariantKey`。
共有の約束（`ProgramKind`・`ShaderVariant`・`materialKey`・`variantKeyOf`）は GL の描き手のファイル `Render3d.flix:193-234` にあり、`WebGpuMaterials` はそれを呼ぶ。

属性を 1 つ足した実例（L1 の `withSkyContribution`・SH。worktree の 149bfe1c0・main には未取り込み）: 新しい中身の他に**配線だけで 8 種類・16 ファイル**。
重いのは GL の uniform の 4 か所・変種の書き並べ・CPU の光の入力の分解 7 か所（`SoftRaster3d.Lights` が位置で並べた 13 個の case の引数）。
L1 の `+sh`・段 1 の `+ssi`・L6 の `+cl` が足されると、毎回これを払う（L6 の節の推測では組み合わせは最大 64）。

### 1.4 気づいた事（この計画の段階で一緒に直す）

- `sg_texMip` を足すかの判定が 2 通り: GLSL は `String.contains(substr = "vec4 sg_texMip(", glsl#functions)`、WGSL は `List.isEmpty(m#texReads)`。
  今は同じ答え（`ShaderGen` が絵を読む材質だけ `texMipSource` を入れる）だが、GLSL 側は字の検索。AST の「使った関数を 1 回ずつ並べる」で判定が要らなくなる。
- CPU の描き手（`SoftRaster3d.materialPixel`・`applyNormalMap`・`Psx.quantized`・`Psx.snapVertex`）が 3 本目の手書き。gl-parity の式の行が守っている。この計画では触らない（6 節の決め 7）。

## 2. GLSL と WGSL の意味の違い（printer か組み込みの関数に閉じ込める物）

| # | 違い | 今の書き方 | 閉じ込め方 |
|---|---|---|---|
| 2.1 | 影の地図・点光源の atlas の行の向き（GL は行 0 が NDC の y = −1・WebGPU で描いた地図は行 0 が上） | WGSL だけ `last.y - t.y` | 組み込みの `targetTexel(map, texel)`（GPU が描いた描き先を画素で読む。GL の行で数え、WGSL の printer だけ読む直前に返す）。L5・L7 で奥行きと太陽の地図を後がけから読む時も同じ物 |
| 2.2 | uniform の置き場（GL は裸の名前・WGSL は `r3d.`・`r3dDraw.`・`r3dLight.`・`r3dCamera.` の struct の欄） | 手で書き分け | handle が group と言語ごとの読む式を持つ（1.2） |
| 2.3 | 法線マップの上下返し `uNormalFlip`（GL のレンダーターゲットだけ） | GLSL だけ uniform | 組み込みの `normalMapTexel(uv)` |
| 2.4 | cutout の値の型（GL は int・WGSL は Float32 の values） | `uCutout == 1` / `r3dDraw.uCutout > 0.5` | `Bool` の handle。printer が比べ方を選ぶ（GL の uniform の型は変えない） |
| 2.5 | 画素の位置（GL は `gl_FragCoord` が左下原点で描き先の原点を引く・WGSL は左上原点） | GLSL は `uPsxTarget` で直す | 組み込みの `pixelFromTopLeft()`。要る uniform は言語ごとに集める |
| 2.6 | PS1 風のアフィンの uv と表（GL ES に `noperspective` が無い・WGSL は決まった配列を実行時の添字で引けない実装がある） | GLSL は uv × w を送って割り戻す・`const` 配列。WGSL は `@interpolate(linear)`・関数の中の `var` 配列 | varying の補間 `Affine`（GLSL は w を掛けて割る 2 行・WGSL は `@interpolate(linear)`）・決まった値の配列の node（置き場は printer が選ぶ） |
| 2.7 | 頂点を丸める格子と描き先の大きさ | GLSL は `uPsxTarget.zw`・`uVertexSnap`、WGSL は `r3dCamera.uSnap` | handle 2 つ。置き場は言語ごとに表で決める |
| 2.8 | 1 体ごとの値（GL はデータのテクスチャを `gl_InstanceID` で `texelFetch`・WGSL は頂点の属性 location 3〜10）と姿勢（GL は joint のテクスチャ・WGSL は storage） | 別々の prelude | 言語ごとの prelude を extern 関数で持ち、出口（`model`・`normalMatrix`・`tint`・`emissionIntensity`・`poseRow`）だけ型つきで AST に渡す |
| 2.9 | clip の z（GL は −w..w・WebGPU は 0..w） | WGSL だけ `sg_clipFromGl` | 頂点の出口を組み込みの `clipOut(p)` |
| 2.10 | 材質の部品の受け方（GLSL は `out` の引数・WGSL は struct を返す） | 別々の呼び方 | 組み込みの `materialEval()`。返り値は albedo・emission・metalRough の値 |
| 2.11 | 条件の式（GLSL `?:` は片側だけ計算・WGSL `select` は両側を計算） | `applyNormalMap`・`environmentUv` は捨てる側が NaN になるだけなので `select` | `Select` は両側を計算してよい式だけ（`LightModel3d.Codegen.selectComputesCall` と同じ考え）。危ない側は `If` の文 |
| 2.12 | varying を helper から読めるか（GLSL は大域・WGSL は入口の引数だけ） | WGSL は helper に uv・タンジェントを引数で渡す | WGSL の printer は入口の頭で使う varying を `var<private>` へ写す。helper は両方の言語で同じ名前を読む |
| 2.13 | ビルボードのスポットの影（GL は `uShadowOn = 0` のプログラム・WGSL は `spotShadow` が 1 を返す版） | 別々 | feature の関数「スポットの影を受けない」が `spotShadow` を差し替える（両方の言語でそろう。GLSL の字が変わる・S5） |
| 2.14 | 空の NDC の y（GL は下から・WebGPU は上から）と、奥行きの書き出しの枝（WebGPU は空を描かず地の色の白で消す） | 別々 | 組み込みの `pixelFromTopLeft()`（2.5 と同じ）から NDC を作る・枝は WGSL で出さないフラグ |
| 2.15 | 微分（WGSL の `dpdy` は GL の `dFdy` と上下が逆）と一様でない分岐（WGSL は微分と `textureSample` を一様でない分岐の中に書くとコンパイルで落ち、GLSL は値が決まらないまま通る） | `ShaderGen.Wgsl.texMipSource` の WhyNot で直している | 組み込みの `dFdx`・`dFdy`（向きは GL にそろえる）・暗黙の段で読む `sample`。式は「一様か」（uniform・定数・それらだけの式）を持ち、AST を組む時に WGSL の uniformity の規則で確かめる: 一様でない条件の `If`・`For` の中、または一様でない条件の早い `return` の後で、微分・暗黙の段の読み・それらを使う関数（呼ぶ関係を辿る。`normalMapped`・`lightmapColor` の `sg_texMip`）を使うと止める（`bug!`・全部の組のテストで当たる）。WGSL の `discard` は helper へ落とすだけで一様さを崩さないので、その後は止めない（今の材質の frag は cutout の discard の後で `normalMapped`・`lightmapColor` を呼び、Dawn が通している）。条件が一様な `If`（`uEnvOn == 1`・`uDepthOut == 1`）と、段を明示した読み（`textureLod`。L7 の raymarch のループの中）は許す。SSAO が奥行きから法線を作る時に要る |
| 2.16 | ビルボードの板の横の向き（GL は uniform `uRightPerBillboard` で分ける・WGSL は別のシェーダー `billboardRowRightVertexSource`） | 別々 | feature の関数「板ごとの横の向き」。GLSL の uniform の分岐を残すか別プログラムにそろえるかは S5 で字の差を見て決める |
| 2.17 | ビルボードの向き（GL は uniform `uFacing`・WGSL は flat な varying `vFacing`） | 別々 | handle（GL は uniform・WGSL は varying）。読む側は 1 つの名前。WGSL の vertex の varying の表へ `vFacing` を足すのはビルボードの feature の関数（printer は表に無い varying を足さない） |
| 2.18 | `vLit` の型（GL は `flat int` で `== 2`・`>= 1`・WGSL は f32 で `> 1.5`・`> 0.5`） | 別々 | 光の当て方を 3 値の enum で持ち、printer が比べ方を選ぶ |
| 2.19 | 空の頂点（GL は `blitVertexSource` の 6 点の buffer・WGSL は `vertex_index` の 3 点）と、ビルボードの四角の角（GL は 6 点の buffer・WGSL は `vertex_index` の表） | 別々 | 全画面の三角形と四角の角を組み込みに（`fullscreenVertex`・`quadCorner()`。どちらも S1 の組み込みの枠で作る）。L5・L7 の全画面の Pass も同じ物を使う。GL の `blitVertexSource` は空のほか `Render3d.buildPrograms` の blit のプログラムも使うので、blit は S5 で同じ全画面の三角形に替えるか、今の 6 点のまま残すかを字の差で決める |

flat の値をどの頂点から取るか（GL は最後・WGSL は最初）は違うが、`vTint`・`vEmissionIntensity` は置いた物 1 つで同じ値なので扱わない（今の WhyNot のまま）。

## 3. 案

### 案 A: `LightModel3d` の木を材質の frag まで広げる

- 利点: GLSL・WGSL・Flix（CPU）の 3 つの出口が既にある。CPU の 3 本目の手書きまで同じ元にできる見込み。L6 のループも同じ木の中。
- 弱み: 木は「光の式」で、入力は `Vec3Input`・`ScalarInput` の決まった enum。材質の frag に要る文（discard・早い return）・絵の読み・varying・binding・
  `vec2`・`vec4`・`i32`・`mat4` を足すと、光の意味と配線が 1 つの enum に混ざる。`Codegen` のパターン 46 か所と CPU の生成が新しい case を全部扱うか拒む必要がある。
- engine の型の変更: `pub enum ScalarExpr`・`Vec3Expr`・`Vec3Input` に case を足す（engine の拡張。事前の相談）。大。

### 案 B: `ShaderGen` と合わせる

- 利点: 2D・後がけ・3D の材質まで、全部のシェーダーの字が 1 つの作りになる。終わりの形としては一番きれい。
- 弱み: `ShaderGen` は木ではなく、ShaderDoc から字を直に組む 1 回の変換。先に `ShaderGen` を AST へ書き直すことになり、2D の SHA・`ShaderEval`（CPU）との比べ・`PostProcess` まで波及する。
- engine の型の変更: `ShaderGen.MaterialGlsl`・`Wgsl.MaterialWgsl` を AST の型へ（engine の拡張）。最大。

### 案 C（推す）: render_gl に小さな型つきの AST と 2 つの printer を新しく作る

- 形:
  - 型: `F32`・`I32`・`Bool`・`Vec2`・`Vec3`・`Vec4`・`Mat3`・`Mat4` と絵（`Texture2d`・`DepthTexture`）。
  - 式: 型を持つ組み立ての関数（`add`・`mul`・`scale`・`mulMV`・`dot`…）でしか作れない。演算子 `+`・`*` は Flix の trait が同じ型どうしだけなので使わない前提（S0 で確かめる）。
  - 文: `Let`・`Var`・`Assign`・`If`・`For`（上限は定数）・`Return`・`Discard`。大域の変数（`r3d_sunLit`・`r3d_pointLit[N]`・psx の `vUv`）と決まった値の配列の node。
  - 関数: 名前・型つきの引数・本文。呼んだ関数を辿り、定義を使う前に 1 回ずつ並べる。**鍵は名前**（Flix の関数の値は比べられない）。
    同じ名前で中身の違う物が 2 つ集まったら止める（`bug!`）。中身の差し替え（ビルボードの `spotShadow`・変種ごとの `lightAt`）は feature の関数だけが、集める前に行う。
  - extern 関数: 名前・型の並び・**依存（読む関数・大域の変数・uniform・varying）**・本文の字（GLSL・WGSL の片方だけでもよい。GL の描き手は `MaterialGlsl`・WebGPU の描き手は `MaterialWgsl` しか持たないため）。
    print する言語の本文が無ければ止める。式の字（`cutoutAlpha`）は `RawExpr[t]` の node（読む名前を宣言する）。
  - 入口: vertex と frag を別々に組む（`litVertexSource` は lit と depth の frag に、`meshVertexSource` は depth と uv の無い材質に共有されているため）。
    varying の表は vertex が持ち（location・型・補間 `Smooth | Flat | Affine`）、frag は読む varying の名前を宣言する。「frag が読む物 ⊆ vertex が書く物」を組の検査で確かめる。
    入口の種類は 3 つ: 置いた物の vertex（instance の prelude あり）・全画面の vertex（L5・L7 の後がけ）・frag。
  - uniform の handle（`Order` を持つ enum。`UniformLocations` の鍵にする）: group（Scene・Draw・Light・Camera）・名前・**言語ごとの宣言の型と読む式**。Scene の handle は `UniformLayout.SceneField` の表から作り、
    GLSL の `uniform` の行と、GL の location を引く名前も同じ handle から取る（範囲の (b)）。片方の言語にしか無い欄（WGSL だけの `pad0〜4`・`uSky*`、GL だけの `uViewport`・`uNormalFlip`・`uPsxTarget` など）は、handle に「この言語では宣言しない」を持たせる。
    WGSL の struct の字は今の `UniformLayout.structSource`（16 バイト単位の詰め）を printer が使い続ける。
  - GL の location（範囲の (b) の形）: 今は `Render3d.loc` の呼び出しが 99 か所・5 ファイル（Light 30・Render3d 28・Shadow 20・Material 18・VariantPrograms 5）、Int32 の record が 10 種類（`LightLocs`・`MeshLocs`・`LitLocs`・`DepthLocs`・`BillboardLocs`・`SkyLocs`・`MaterialLocs`・`ShadowLocs`・`SunShadowLocs`・`PointShadowLocs`）。
    プログラムを組んだ時に、そのプログラムが集めた uniform の handle だけを引いて `Map[handle, Int32]` の 1 つ（仮 `UniformLocations`）にし、値を差す所は `set(locs, handle, 値)` で handle を渡す。10 個の record と 99 か所の `loc(…, "名前")` は消える。
    WhyNot: record の欄を残して名前だけ handle から引く形にしない — 宣言の型・欄・差す所の 3 か所が手書きで残り、「4 か所 → 表 1 つ」にならない。Map を引く代金は 1 コマに uniform の数だけで、今の record の欄を読むのと桁は同じ（S3 で gl_parity の CPU 時間を前後で見る）。
  - printer: `ShaderAst.Glsl.print`・`ShaderAst.Wgsl.print`。2 節の違いはここと組み込みの関数だけに書く。
  - 今の pub の関数（`Render3dGlsl.*`・`Render3dWgsl.*`）は名前と型を変えず、AST を組んで print するラッパーにする。呼び手（`materialFragmentSource` は 29 か所でうち 27 がテスト）は直さない。
- 利点: engine の型を変えない。意味の違いが 1 か所の表になる。L5・L7 の GPU 側のシェーダー（SSAO・raymarch の後がけ）を最初から 1 回で書ける
  （L7 の節の「ShaderDoc の Spec にループが無いので描き手ごとに GLSL・WGSL を書く」がこの AST で 1 回になる）。フラグと uniform を足す配線が render_gl の中では 1 か所になる（engine・engine_world に 3〜4 か所は残る。4.2）。
- 弱み:
  - 新しいモジュールが 1 つ（推測 900〜1,200 行: AST 400〜500・printer 2 つで 350〜450・組み込みと検査 150〜250）。
  - 1 行が長くなる（`add(mul(a, b), c)`）。
  - **L6 にはほとんど役に立たない**: 光ごとのループと光の uniform の名前は engine の `LightModel3d.Codegen` の中（`Stmt.Loop`・`glslUniformOf`・`wgslScalarField`）。
    cluster の表を引くループは engine の木を直す。uniform の名前を知る所が Codegen と handle の表の 2 つになるので、S2 で「Codegen が読む名前は全部 handle の表にある」を確かめるテストを置く（決め 4）。
  - 後がけの Pass を engine の `PostProcess`・ShaderDoc の側に置くなら、render_gl の AST は使えない（決め 3）。
  - 生成の時間と wasm の大きさが増える（S0 で今の値を控え、上限を決める。5.2）。
- engine の型の変更: なし。

### 案 D（推さない）: WGSL を元にして naga で GLSL へ写す

- WGSL → GLSL ES 3.00 / GLSL 330 は naga の出口にある（逆向きの GLSL 330 → WGSL は入口が無い。`plans/engine-webgpu.md` の 4.2）。
- 推さない理由:
  - 材質の部品は ShaderDoc から実行時に作る（Studio で保存すると変わる）ので、組み立ての時に全部を写しておく道が無い。実行時に写すには、
    PC では OS ごとの native の lib、ブラウザの WebGL2 の fallback（WebGPU が使えない約 11% の人）では別の wasm を読むことになり、wasm の大きさの見張りに逆らう（naga の wasm の大きさは推測で 1〜2 MB。測っていない）。
  - 2.1・2.3・2.5・2.7・2.14 は写しても消えない（GL の行の向き・原点は意味の違い）。WGSL の元に uniform のフラグを足して表すことになる。
  - 写した GLSL の字は今の手書きと違い、gl-parity の 0 px を保ったまま移す道が「全部を 1 回で替える」しか無い。
  - `plans/engine-webgpu.md` の 4.2 で「機械訳には頼らず、生成の所に WGSL の出口を足す」と決めてある。

### 業界との比べ（短く）

- **Bevy**: WGSL を元に `naga_oil` の `#import` と `#ifdef`（shader defs）で組み、naga が WebGL2 向けの GLSL ES・SPIR-V・MSL・HLSL へ写す。変種は shader defs の組で pipeline を分ける。
  この engine は生成を Flix の中（JVM と TeaVM の wasm）で走らせ、CPU の描き手とビットで比べるので、外の変換器を挟めない。案 C は naga の IR の出口の側だけを小さく持つ形。
- **Godot**: ゲームが書くシェーダーは Godot のシェーダー言語で、エンジンのコンパイラが GLSL へ写す。エンジンの組み込みのシェーダーは GLSL の手書きで、変種は `#ifdef` と specialization constant。
  RenderingDevice の側と Compatibility（GLES3）の側で組み込みの scene シェーダーを別に持つ（今のこの engine と同じ 2 回書き。記憶による）。
- **Unity**: HLSL を元に DXC と SPIRV-Cross で GLSL・MSL へ写す。変種は `multi_compile` の keyword で、膨らみは使わない組を外して抑える。
- 変種の膨らみの抑え方はどこも「使う組だけを作る」。この engine も今それをしている（`Scene3d.PreloadVariant`）。案 C はそこを変えない。

### 推す: 案 C

決め手は 3 つ。engine の型を変えずに済む・意味の違いが 1 つの表に集まる・L5・L7 の GPU 側のシェーダーと、フラグと uniform を足す配線が 1 回で済む。
案 B の終わりの形（`ShaderGen` も同じ AST）は L7 の後に別の段階として残す（決め 6）。

## 4. 型で守る所（型 → lint → 文書の順）

### 4.1 型で止める

| 書き間違い | 止め方 |
|---|---|
| uniform・varying の名前の綴り違い（GLSL では location が `-1` のまま通る） | 名前は handle の中にだけ書く。Scene の handle は `UniformLayout.SceneField` の enum から作る。**GL の location も handle で引く**（`UniformLocations`・範囲の (b)。ここまでやらないと「書けない」とは言えない） |
| uniform の group の取り違え（`r3d.` と `r3dDraw.`）・言語ごとの型の違い（`float[N]` と `Vec4Array`） | handle が group と言語ごとの宣言の型・読む式を持つ |
| `f32` と `vec3` と `i32` の取り違え（WGSL は暗黙の変換が無いので Dawn で初めて落ちる） | 式が型を持つ。数のリテラルも `f32(…)`・`i32(…)` |
| 同じ関数の 2 回の定義・置く順の約束（「lightSource の後に置く」） | 使った物を辿って 1 回ずつ並べる。同じ名前で中身の違う物は止める。`needsMip` の判定と WhyNot の 1 つが要らなくなる |
| vertex の出口と frag の入口のずれ | vertex の varying の表と frag の読む名前を組の検査で比べる |
| 微分・暗黙の段の読みを一様でない分岐に置く（2.15） | 式が「一様か」を持ち、呼ぶ関係を辿って、一様でない分岐・早い return の後で使うと組む時に止める（2.15） |
| 外から AST の node を直に作る | AGENTS.md の 4 の形: pub mod の中の非 pub の enum と `pub type alias`。作れるのは型を持つ組み立ての関数だけ |

式の型の持たせ方は S0 で 30 分だけ確かめる。
- 第 1 案: `Expr[t]` の phantom の型の引数。Flix 0.78 は使わない型の引数をコンパイルで止める（`RedundancyError` の `UnusedTypeParam`）見込みが高いので、中身に `t` を使う欄（例: 標準の `Proxy[t]` があればそれ・無ければ空の case の enum）を持たせて試す。
- 第 2 案: `LightModel3d` と同じく型ごとの enum（8 つ）。swizzle・`mat × vec` の組み合わせの関数が増えるので、S1 の見積もりに +1 時間。

### 4.2 変種の膨らみ（範囲の (c)）

- engine の `Scene3d.PreloadVariant`（= `ShaderVariant`）は変えない（変えるなら相談。決め 5）。render_gl の中に**変種のフラグの表 1 つ**を置く:
  フラグ 1 つ = 1 行（enum の case・鍵の字 `+ps` など・`Counts` の bit・WebGPU の layout の扱い・ビルボードが受けるか・feature の関数）。
  書き並べ約 10 か所（1.3）のうち render_gl の中の物（`defaultShaderVariant`・`shaderVariantOfKind`・`billboardVariantOf`・`passVariantOf`・`lightVariantOf`・`Counts` の bit・`VariantPrograms`・`layoutCodeOf`・`variantDeclarations`・`lightSourceFor`）はこの表を回す形にする。
  engine と engine_world の物（`Scene3d.PreloadVariant` の record・`Scene3d.preloadVariantOf`・`preloadVariantKey`・`App.Internal.AutoPreload.variantKeyOf`）は残る。
  **フラグを 1 つ足す時に直す所は、render_gl の中は表の 1 行・engine と engine_world に 3〜4 か所**（今は合わせて約 10 か所）。
  render_gl へ入る所で `PreloadVariant` を 1 回だけ `Set[VariantFlag]`（表の enum）へ変え、内側は Set で回す。engine の側も表にするのは `PreloadVariant`（ゲームへ出している pub の record）を変える事になるので、L1 の `+sh` を入れる時に相談する（決め 5）。
- `ProgramKind` に変種の 3 欄を平らに並べず、`variant` の欄に入れ子にする（変種の欄の 2 回書きが消える）。
- 共有の約束（`ProgramKind`・`ShaderVariant`・`materialKey`・`variantKeyOf`・`shaderVariantOfKind`・`billboardVariantOf`・`passVariantOf`・`lightVariantOf`）を
  `Render3d.flix:193-234` から別の mod（仮 `Render3d.ProgramKey`）へ出し、WebGPU の描き手が GL のファイルに依存しないようにする。
- feature の関数: AST を受けて AST を返す。差し込む所は名前のある点に限る（`declarations`・`beforeLight`・`colorOut`・`clipOut`・`spotShadow`）。
- `ProgramKind` の作れてしまう組（uv の無い法線マップ）は、呼ぶ側の `surface#uv and surface#normalMap` で消している。この計画では型を変えず、組の検査のテストで覆う。
- 全部の組み合わせ（`ProgramKind` の正しい組 × 変種）を回すテストを 1 本足す: 両方の言語で print できる・同じ名前の衝突が無い・varying の組がそろう・
  GLSL ES の予約語の検査（`TestGlslEsKeywords`）・Dawn で WGSL が通る（`TestWgslDawn` の材質の版を全部の組へ広げる）。

### 4.3 lint と文書

- `bin/lint-rules/forbid.json` に 1 行: `Render3dGlsl`・`Render3dWgsl`・`Render3d/` の中で `"#version 330"`・`"@fragment"`・`"@vertex"` の字のリテラルを書かない（代わりは `ShaderAst`）。forbid は .flix の文字列とコメントを除いてから当てるので、この行は `rawLine: true` にする。
  外すのは printer と extern 関数の本文を置くファイル（forbid はパス単位でしか外せないので、本文は `ShaderAst` の下の決まったファイルに置く）・`Render3d/WebGpuMipmaps.flix`・`Render3d/WebGpuShadowCache.flix`（WebGPU だけの物）。S7 で入れる。
- engine のリポでだけ使う lint なので、AGENTS.md の「検証」の節の決まりどおり、その節に 1 行と `testdata/agent-eval/engine-repo.json` にお題を 1 本足す（ゲームへ配る早見表には入れない）。
- 文書は `docs/api-digest.md` の生成し直しと、`Render3dGlsl` の頭の「木の外に残る GLSL」の段落を AST の説明へ書き直すだけ。

## 5. 段階

どの段階も同じ手順: 直す前に全部の版の字を `build/shader-dump/before/` へ書き出す → 直す → `after/` へ書き出して `diff -r` →
差を読んで意図した物だけか確かめる → 門（5.2）。書き出す範囲は `ProgramKind` の正しい組 × 変種 × 言語の材質の frag・vertex と、
lit・depth・ビルボード（vertex・frag・影の地図の frag・板ごとの横の向きの版）・空（vertex・frag）・blit の全部。

### 5.1 段階の表（実時間）

| 段階 | 中身 | 見積もり | GLSL の字 | WGSL の字 |
|---|---|---|---|---|
| S0 | 字の書き出しのテスト（環境変数があれば `build/shader-dump/` へ全部・無ければ版の数を確かめる）・式の型の持たせ方の確かめ・今の生成の時間と wasm の大きさを控える・gl-parity・webgpu_v2・scene3d の gl-capture-check が覆う変種の表（覆わない版は Dawn と字の差の読みだけが守り、と書いておく）・**PS1 風の WebGPU の絵を撮る道を作る**（今は無い。scene3d の `PSX=` の knob で PS1 風を `bin/gl-capture.sh --backend webgpu` で撮る。置き場の名前は game の basename で決まり既定の `scene3d` とぶつかるので、出力のフォルダと基準の SHA のファイルを別にする。だめなら webgpu_v2 の `cases` に PS1 風の部屋を 1 つ足す）・式の型の持たせ方の確かめ（`Proxy[t]` の有無・使わない型の引数を `_` で始めれば通るか）・wasm の大きさは `bin/fge wasm-size` で測って上限を実測から決める | 2.5〜3.5 | 変えない | 変えない |
| S1 | AST・2 つの printer・関数を辿って並べる所・組み込みの枠（`fullscreenVertex`・`quadCorner` を含む）・式の「一様か」と呼ぶ関係を辿る検査（2.15）・printer の単体テスト（1 本に 1 assert）。移すのは純粋な式の関数（`surfaceOut`・`surfaceOutLit`・`applyNormalMap`・`environmentUv`・`depthGray`・`colorDepth`・`vertexSnap`・`colorSpace` の vec3 の版） | 5〜7 | **書き出しの差が空**（意味の無い括弧・`1e-12` の綴り・`for` の 1 行と `{ }` を合わせるため、括弧と数の字と `for` の書き方を node に持たせる） | 変わってよい |
| S2 | 変種のフラグの表・入る所で `Set[VariantFlag]` へ変える所・`ProgramKind` の `variant` の入れ子・共有の約束の mod（4.2・範囲の (c)） | 3〜4 | 変えない | 変えない |
| S3 | uniform の handle（言語ごとの型と読む式・片方の言語だけの欄）・GLSL の uniform の行を handle から・`UniformLocations` へ替えて 10 個の `*Locs` と `loc(…)` 99 か所を消す（範囲の (b)）・影（PCF と行の向き・スポット・太陽・点光源の包み）と `lightSourceFor`。Codegen が読む uniform の名前が handle の表にある事のテスト | 7〜9（うち (b) 4〜5） | 差は `uniform` の行の並べ替えと、使わない行が消える事だけ。SHA を直す | 変わってよい |
| S4 | 材質の frag・lit の frag・depth の frag・varying の表・`materialEval`・cutout・表裏の組み込み・feature の関数（`psx`・`pointShadows`・`physicalUnits`） | 4〜5 | 変わってよい | 変わってよい |
| S5 | ビルボード（vertex・frag・影の地図の frag）と空（vertex・frag）（2.13・2.14・2.16〜2.19） | 2〜3 | 変わる（ビルボードのスポットの影） | 変わってよい |
| S6 | 置いた物・材質・lit の vertex。1 体ごとの値と姿勢の prelude は言語ごとの extern 関数 | 2〜3 | 変わってよい | 変わってよい |
| S7 | 手書きの字の関数を消す・lint の 1 行とお題・`TestRender3dWgslPairs` を消す（同じ AST なので数の並びの比べは要らない）・文書 | 0.5〜1 | — | — |

段階の合計 26〜35.5 時間。レビュー（S1 の後・S4 の後・S7 の後の 3 回）を各 0.5〜1 時間足して、計画全体は **27.5〜38.5 時間**（担当 1 人で順に進める前提。重ねて引かない）。
範囲の (b) は S3 のうち 4〜5 時間、(c) は S2 の全部（3〜4 時間）。(a) だけなら 19〜26.5 時間（レビュー込みで 20.5〜29.5）。

### 5.2 門（段階ごと）

| 門 | いつ | 確かめる事 |
|---|---|---|
| 前提: `make sync-engine-full` | webgpu_v2・gl-capture-check の前に毎回 | webgpu_v2 の木は `engine_full/src` を symlink で読む。流さずに run すると古い render_gl で比べ、誤って緑になる |
| `make sync-layers` の後、`.layers/render_gl` で `flix test`（render_gl は層なので `make test-render_gl` ではなくこちら） | 毎回 | `TestRender3dGlslPinned`・`TestRender3dMaterial`・`TestPsxVariant`・`TestPointShadowVariants`・`TestGlslEsKeywords`・`TestWgslDawn`・`TestWebGpuScene3dDawn`・S0 の書き出しのテスト・4.2 の全部の組のテスト |
| `make gl-parity`（18 秒） | 毎回 | GL と SoftRaster の全場面 0 px と式の行 |
| `make -C bench/webgpu_v2 run`（手動・GPU が要る） | S1〜S6 | WebGPU の 3D（部屋の場面）を GL と画素で比べる。**3D の WGSL を絵で比べる門は今これだけ**（`make webgpu-v1-check` は 2D と V1 の scene で、webgpu_v2 は組めるかしか見ない） |
| `make gl-capture-check SCENES=scene3d` と、S0 で足す PS1 風の scene3d の撮り | S3〜S6 | WebGPU で撮った 3D の場面（`bin/gl-capture.sh` が 3D を撮るのは `bench/scene3d:` だけ。テンプレートの名前では撮れない）。gl-capture-check は基準との小さい差を通すので、**合格の条件はログに「[gl-capture] 一致: N 枚がバイトまで同じ」が出て、「小さい差で通した」の行が 1 つも無い事**（`build/gl-capture/diff` は前の回の絵が残り、差のあるコマしか書かれないので頼らない） |
| `make sync-engine-full-web` と、3D のテンプレートを `bin/fge export-web` → `bin/fge web-capture` で撮る | S1・S4・S7 | ブラウザ版の束が組めるか・wasm の中の生成で WebGPU の 3D が描けるか（`make webgpu-v1-check-web` は rpg-starter の 2D なので 3D の代わりにならない）。PC の WebGPU の絵と `bin/fge pixel-diff` |
| wasm の大きさ（`bin/fge wasm-size`） | S1・S4・S7 | S0 の実測から上限を決める（目安 +3%・推測。超えたら止めて相談） |
| 生成の時間 | S1・S4・S7 | 全部の版を組む時間が S0 の 1.5 倍以内（JVM。ブラウザは S4 で 1 回） |
| `make verify SUITE=affected` | 毎回のコミットの前 | 差分から選んだ門 |
| `make gl-capture-check`（12 分） | S7 の後に 1 回 | WebGPU の基準の SHA |

`TestRender3dGlslPinned` の SHA（既定の変種の `lightSource` 1・材質の frag 8・材質の vertex 4）が固めている範囲は狭い（psx・lightmap・PBR・ビルボード・空・lit・depth を含まない）。
**合格の条件は SHA でなく `build/shader-dump` の差**にする:
- S0〜S2: GLSL の差が空。
- S3: GLSL の差が `uniform` の行の並べ替えと、使わない行が消える事だけ。
- S4〜S6: 差を全部読んで意図した物だけと確かめ、gl-parity 0 px・webgpu_v2・scene3d と PS1 風の scene3d の gl-capture-check・ブラウザの絵の緑を見てから SHA を直す。差の中身はコミットの本文に Why として書く。
- `count("vec4 sg_texMip(") == 1` などの中身のテストは残す（AST の並べ方が守る性質を外から確かめる）。

画素の差が出たら（gl-parity・webgpu_v2・gl-capture-check のどれかが赤）入れる前に止めて報告する。差を「意図した差」として基準を直す事は、この計画ではしない（絵は 1 画素も変えない計画）。

### 5.3 見積もりの元にした実績（git の時刻）

- `PointShadowCodegen`（小さな式の木と GLSL・WGSL・Flix の出口・477 行・2 ファイルの手書き約 120 行を置き換え）は、前のコミット（層 3）から約 1 時間（11-18 20:32 → 21:29）。
  ただし閉じた式の木で、uniform・varying・binding・文を持たない。この計画の AST はそれらを全部持つので、行あたり 2 倍以上かかると見た。
- WebGPU の 3D を 1 つずつ足した段階（11-16 の材質・骨・lightmap・空）は 1 つ 0.7〜2 時間。WGSL の出口を足した P5 はレビューの直しまで 1 時間弱。
- この計画は新しく書く行が推測 900〜1,200 行・置き換える手書きが約 1,100 行（`PointShadowCodegen` の 3〜4 倍の量）。
  加えて S1 の書き出しの差を空にする合わせ（1〜1.5 時間）と、段階ごとの差を読む時間（1 回 15〜30 分）。

### 5.4 止める基準と、止めた時の形

段階ごとに見積もりの 2 倍を超えたら止めて相談する。止めた時に残る形はどれも動く（今の pub の関数のラッパーが段階ごとに切り替わるだけなので、途中でも手書きと AST が混ざって動く）:
- S1 で止める: AST は純粋な式の関数だけ。残りは手書き。得る物は printer と 8 つの関数の 1 本化。
- S4 で止める: frag は全部 AST・頂点（S6）とビルボード・空（S5）は手書き。L5・L7 には足りる（後がけの frag と全画面の vertex は S1 の組み込み `fullscreenVertex` で書ける）。
- S5 で止める: 頂点だけ手書き。

## 6. 決めること

1. **案 C で進めるか** → 推す。
2. **範囲**: (a) 1 本化・(b) GL の uniform を表から・(c) 変種の表と共有の約束の mod を 1 本の計画にするか → する（(b)(c) は (a) の handle と feature の関数の土台）。(d) CPU の光の入力の record は別の段階（7 節）。
3. **AST の置き場**: render_gl（推す・engine の型を変えない）か、最初から `engine/src/shader`（`ShaderGen`・`PostProcess` を後で移す時に動かさずに済むが、engine の拡張になる）。
   あわせて、**L5 の SSAO の Pass と L7 の raymarch の GPU 側のシェーダーを render_gl に置くか**（置くなら render_gl の AST で足りる・engine の `PostProcess` の側に置くなら置き場を engine にする）。
4. **uniform の名前を持つ所**: この計画では Codegen は自分の名前を持ったまま、handle の表にある事をテストで確かめる（推す）。名前を engine の側へ 1 本にするのは L6 の時に相談。
5. **`ShaderVariant`（engine の `Scene3d.PreloadVariant`）は変えず、render_gl の中の表で閉じる**でよいか → よい。この形ではフラグを足す時に engine・engine_world の 3〜4 か所が残る（4.2）。engine の側も表にするのは L1 の `+sh` の時に相談。
5b. **GL の location を `Map[handle, Int32]`（`UniformLocations`）にして 10 個の `*Locs` の record を消す**でよいか → よい（4.1・案 C）。record の欄を残すと手書きが 3 か所残る。
6. **`ShaderGen.compile3d` を同じ AST へ移す**のは L7 の後の別の段階でよいか → よい（2D の SHA と `ShaderEval` まで波及するため）。
7. **CPU の描き手（3 本目の手書き）**をこの AST の出口に足すのはこの計画の外でよいか → よい。gl-parity が守っており、L5〜L7 の前に要る物ではない。
8. **始める時期**: L4 と段 1 の 1d（`UniformLayout`・影の地図を触る）が main に取り込まれた後でよいか → よい。L1 の `+sh` が先に入るなら、S2 の変種の表の最初の追加の見本にする。
9. **S6（頂点）までこの計画に入れるか** → 入れる（varying の表で vertex と frag をつなぐ利点が S6 で初めて出る）。止めるなら 5.4 の S5 の形。
10. **S1 で GLSL の字を 1 バイトも変えないために、括弧・数の字・`for` の書き方を AST に持たせるか** → 持たせる（+1〜1.5 時間）。今の門が psx・lightmap・PBR などの版を全部は覆わないので、printer を確かめる道が字の一致しか無い。
    持たせないなら、S1 から GLSL の字が動き、覆わない版は Dawn と字の差の読みだけが守りになる。

## 7. 範囲の外に並べる段階

| 段階 | 中身 | 見積もり | 順 |
|---|---|---|---|
| X1 | CPU の光の入力（`SoftRaster3d.Lights` の位置で並べた 13 個の引数・`Shadow`・`Fog`）を名前つきの record へ。欄を 1 つ足すたびに動く分解 7 か所が消える | 1〜2 | engine_tools の中だけでシェーダーの字と独立。この計画と並べて別の担当で進めてよい（同じパッケージに触らない）。L1 の `+sh` が main に入った後 |

## 出典にした engine の場所

- `render_gl/src/Render3dGlsl.flix`（704 行）・`render_gl/src/Render3dWgsl.flix`（657 行）・`render_gl/src/Render3d.flix:97-106`（`LightLocs`）・`:193-234`（共有の約束）
- `engine/src/scene3d/LightModel3d.flix`・`LightModel3d/Codegen.flix`（`Target`・`Stmt`・`toGlsl`・`toWgsl`・`selectCode`・`glslUniformOf`・`wgslScalarField`）・`LightModel3d/PointShadowCodegen.flix`
- `engine/src/shader/ShaderGen.flix`（`compile3d`・`MaterialGlsl`・`isWgsl`）・`ShaderGen/Wgsl.flix`（`compile3d`・`MaterialWgsl`・`texMipSource`）
- `render_gl/src/Render3d/UniformLayout.flix`（`FieldType`・`SceneField`・`sceneFields`・`structSource`）・`Render3d/VariantPrograms.flix`・`Render3d/WebGpuRenderer.flix`（`layoutCodeOf`）・`Render3d/Light.flix`
- `engine_tools/src/SoftRaster3d.flix:121-133`（`Lights`・`Shadow`）
- テスト: `render_gl/test/TestRender3dGlslPinned.flix`・`TestRender3dWgslPairs.flix`・`TestWgslDawn.flix`・`TestGlslEsKeywords.flix`・`TestPsxVariant.flix`・`TestPointShadowVariants.flix`
- `plans/engine-render-look-stage.md` の 2・9・10 節・`plans/engine-webgpu.md` の 4.2・`gates.json` と `Makefile`（`gl-parity`・`webgpu-v1-check` の中身・`bench/webgpu_v2/Makefile`・`gl-capture-check`）
- 比べのレビュー（属性 1 つの配線の実例・34 組・分岐の数）: worktree の 149bfe1c0 の差分

## 人の決め（2026-11-26）

「おすすめ案で」。6 節の 1〜10 は推す答えのとおり（案 C・範囲 (a)(b)(c)・AST は render_gl・L5 の SSAO と L7 の raymarch の GPU 側のシェーダーも render_gl に置く・S6 まで・S1 は字を 1 バイトも変えない）。
始めるのは見た目の段 L0〜L4 が main に入った後。X1（CPU の光の入力の record）は並べて別の担当で。
