# B: 2D の描き手とシェーダーの持ち方 — WebGPU へ移す時の見立て

【確】= コードを読んで確かめた事 / 【推】= 読んだ事からの推測。パスは /Users/abab/Desktop/flix_game_engine 起点。
render_gl/src は以下 `rg/` と略す。

## 0. 先に結論
- 2D の描き手の「GL を呼ぶ所」は薄い。毎コマ、描き物を z 順に 1 本へ並べ、同じ状態が続く塊（run）ごとに 1 回描く。**パイプラインの種類は固定の 5 本＋ゲームが宣言した面ごとの本数**で、状態の種類（blend 3 種・scissor・stencil 1 パターン）も少ない。WebGPU に素直に移せる形【確】。
- 難所は 3 つ。(1) 宣言シェーダー面とエンジン内の GLSL を WGSL にする出し分け（GLSL 文字列を直に作っている）。(2) 面ごとの uniform が名前引きの個別 uniform（uTime・uAlpha・uRectPos…）で、WebGPU は uniform buffer + bind group が要る。(3) 描く途中の stencil clear と FBO の resolve/blit・history 写しなど「パスをまたぐ GL 状態の操作」。
- ゲーム作者が GLSL を直に書く口は**無い**【確】。シェーダーは「部品の組み合わせ（ShaderDoc.Spec）→ ShaderGen が GLSL を出す」だけ。だから WGSL へ移す対象は、エンジン内の固定ソースと ShaderGen の 1 か所（＋3D の Render3dGlsl）に閉じている。

## 1. 2D の 1 コマの流れ

### 1.1 effect の高さ【確】
engine/src/platform/Platform.flix:93 `eff Draw2d`
- `renderCommands(sprites, tileMaps, polygons, staticLayer)` : 1 コマ描く。画面へは出さない（swap は `Window.presentFrame`）。レンダーターゲットが開いていればそこへ。
- `drawSurface(cmd: DrawCmd.SurfaceRenderCmd)` : 宣言シェーダー面 1 枚を「積む」だけ。次の renderCommands で z の位置に合流。
Platform.flix:107 `eff Draw3d`（drawScene3d・preload3d。同じく積むだけ）。
Platform.flix:143 `eff GpuResources`（initTileBuffer / updateTileBuffer / ensureTexture / ensureGlyphs / getFontAtlas / getTextureInfo / buildProgram(spec: ShaderDoc.Spec)）。
engine/src/platform/RenderTarget.flix `eff Target`（beginTarget(spec) / pixelScale / endTarget）。`TargetSpec = { name, width, height, format, clear(LoadOp), samples }`。LoadOp は Keep / Clear(c) / ClearTransparent（コメントに「wgpu の LoadOp と同じ語彙」とある）。Format は Rgba8Unorm / Rgba16Float の 2 つだけ。
`ShaderEffect` という名前の物は**無い**（refactor search で 0 件）。面は Render.Item.Shader（engine_world/src/Render.flix:54）→ `Render.drawShaders`（:924）→ `Draw2d.drawSurface`。

つまり WebGPU の描き手が実装する effect の面は **Draw2d(2 op)・Draw3d(2)・GpuResources(7)・Target(3)・Diagnostics(2)** で、`Platform.Services` 側は GL に触れない。

### 1.2 ゲーム → effect まで【確】
ゲームの view → `Render.Item`（Sprite / Text / Shader / Scene3d / Clipped / polygon …）→ engine_world の `App.Internal.Paint`（engine_world/src/App/Internal/Paint.flix）。
- 本編: `submitGpuItems` → Drawable / PolygonRenderCmd / TileMapRenderCmd に落とし、Shader 面は `Render.drawShaders(programOf = GpuResources.buildProgram, items)` で SurfaceRenderCmd にして `drawSurface` を積み、最後に `renderCommands`。
- Pass: `renderPasses`（Paint.flix:354）が Pass の列を `beginTarget → submitGpuItems → endTarget` で回す。Pass の宣言は `Render.Pass = { name, clear, items }`＋`PassPlan { passes, targets: Map[name, Descriptor] }`（Render.flix:722,789）。Descriptor = `{ scale, basis(Design|Window), format, samples }`。
- 字: テキストは「font_ で始まる名前のテクスチャを貼る Drawable」になって sprite と同じ列を通る（Frame.flix `isFont`）。【推】1 字 1 Drawable（TextDraw.flix は未読）。

### 1.3 handler 側【確】
`rg/PaintHandlers.flix` が `handleDraw2d / handleDraw3d / handleGpuResources / handleDiagnostics / handleTarget` を持つ。窓あり(LwjglLayer.flix:525-534)・窓なし GPU(GlOffscreen.flix:387-393)・ブラウザ(engine_web/src/WebLayer.flix:112-120)が**同じ handler 群に `gl: GlContext` を渡して**使う。つまり WebGPU 版を作るなら `GlContext` と対に、`RenderPaint`（Paint.flix の `Paint` レコード＋ submitFrame / beginTarget / buildProgram…）の置き換えが要る。GlContext を実装し直すだけでは足りない（GlContext は GL の API そのままの 178 行で、プログラム番号・location・bind 状態を前提にしているため）【推】。

### 1.4 1 コマの中身（rg/Paint.flix → rg/Frame.flix）【確】
1. `RenderPaint.submitFrame`（Paint.flix:371）: ターゲットが開いていれば `paintTarget`、無ければ `paintFrame`（画面。黒帯 clear・lastFrame 控え・世代 +1）。
2. `RenderFrame.renderFrameMixed`（Frame.flix:812）:
   - clear: 画面は「全面を黒 → design 領域だけ clearColor」の 2 段（scissor 使用）。ターゲットは LoadOp どおり（Keep なら clear しない）。
   - `mergedByZ`（Frame.flix:~80）で tiles / sprites / polygons / static / surfaces / scenes を **1 本の z 安定ソート列**（同 z は tiles→sprites→polygons→static→surfaces→scenes）にする。z の幅が広い（HUD 1e9 など）時は範囲番号で 2 段階。
   - `emitMerged`（:728）が列を先頭から舐め、**run**（スプライト run / 多角形 run）を溜めて、種類が変わる所・キーが変わる所で吐く。順序の入れ替えはしない（「同じ z の bg と文字が逆転して文字が消えた」事故があった旨のコメント）。
3. 末尾で scissor を解除・blend を Normal に戻す。

### 1.5 まとめ描き（batch）の単位と draw call 数【確】
| run 種 | 区切りになるキー | 1 run = |
|---|---|---|
| スプライト（箱・画像・字 すべて） | テクスチャ id・clip 矩形（量子化 int 4 つ+有無）・blend | 1 回の `drawArraysInstanced(TRIANGLES,0,6,count)`。instance は 38 float。単色箱は texId 0 で bind なし |
| 多角形 | clip 矩形・blend | 1 回の `drawArrays(TRIANGLES,0,n)`。三角形化は CPU（耳切り / grad は扇割り）。頂点 6 float |
| タイル層 | 層ごと（TileVao+テクスチャ） | 1 層 1 回の instanced draw |
| 静的レンジ | z・blend・clip ごとのレンジ | 永続 VBO の範囲を 1 回の drawArrays（アップロード無し） |
| シェーダー面 | 面 1 枚ごと | 1 draw（quad 6 頂点） |
| mask 付き sprite / 面 | 1 個ごと | stencil clear + mask 描き込み(drawArrays) + 本体 = 3 draw 以上＋ clear |
| 3D の場面 | 場面ごと | Render3d（別。メッシュごと instanced indexed 等） |
- 1 コマの draw call = 「z 順の列で連続して同じ (種類, テクスチャ, clip, blend) が続く塊の数」+ タイル層数 + 面の数 + mask 付きの数×3+ 静的レンジ数 + 3D。UI で画像と文字が z 順に交互に重なると run が細かく割れる（Frame.flix:723 の「再グループ化禁止」）。【推】ふつうの 2D ゲームでは数十〜数百。
- 頂点データの上げ方: 1 run ごとに `bufferData(ARRAY_BUFFER, buf, DYNAMIC_DRAW)`（orphaning）。同じバッファを 1 コマに何度も差し替える（`RenderBuf` 1 本を使い回し、run を吐くたびに先頭へ戻す。Frame.flix:894-897）。**WebGPU では「1 コマの間に queue.writeBuffer を同じ範囲へ繰り返す」と後の物が先の draw にも効く**ので、run ごとにオフセットを進めて 1 本の大きな buffer に詰め直す必要がある【推】。

### 1.6 頂点の形（attribute）【確】
| 用途 | 形 | 所在 |
|---|---|---|
| 共有 quad | loc0 vec4(x,y,u,v) 6 頂点 / 16 B（三角 2 枚。index buffer 無し） | Sprite.flix:13 |
| インスタンス sprite | quad + loc1..10 の vec4/vec2、1 instance = 38 float = 152 B（変換 2x2・平行移動・uvOffset/Scale・色+α・フラグ 4・rectSize/角丸/枠幅・枠色・ハッチ色・ハッチ幅/周期/向き/市松セル・市松色） | Sprite.flix:550 / Frame.flix:writeInstAt |
| 多角形 | loc0 vec2 + loc1 vec4 / 24 B | Sprite.flix:139 |
| タイル | quad + instance 10 float = 40 B（pos2 uvO2 uvS2 α1 tint3）divisor 1 | Sprite.flix:371 |
| 面 | quad（共有） | — |
| 3D | 別系統（位置・法線・UV・接線・骨 index(vertexAttribIPointer)・weight・instance texture(RGBA32F, texelFetch, gl_InstanceID)） | Render3d.flix:800-900 |
2D は float だけで整数 attribute は無い。WebGPU の vertexBuffers の layout（stepMode: instance）にそのまま書ける【確→推】。

### 1.7 死んだ経路【確】
`RenderSprite.drawSprite`（uniform 1 個ずつ渡す旧スプライト経路）と `drawSpriteInstanced`（Array 版）は呼び手 0（refactor usages）。`Paint.create` は `spriteShader`（`RenderShader.vertexShaderSource/fragmentShaderSource`）と `tileShader` はまだ作る（spriteShader は FrameArgs の `spriteShader`/`spriteUniforms` に載るが使われない【推】。呼び手 1 = Paint.create のみ）。WebGPU 版ではこの uniform 版のシェーダー（約 100 行の frag）は移さなくてよい。`drawPolygonBatch`（Array 版）は mask 描き込みだけが使う。

## 2. シェーダーの出どころ

### 2.1 (a) エンジン組み込みの GLSL（#version 330 core で書かれた Flix 文字列）【確】
| ファイル | 内容 | 本数・行数の目安 |
|---|---|---|
| render_gl/src/Shader.flix | sprite(uniform 版・旧) vs/fs / tile vs/fs / **instanced sprite vs/fs** / **poly batch vs/fs** / fallback fs | #version 9 本。ファイル 534 行のうち GLSL 約 320 行。live なのは instanced(vs 約 35 行・fs 約 75 行)・poly(vs 20・fs 10)・tile(vs 20・fs 12) |
| engine/src/shader/ShaderGen.flix | 面の vertex(固定 9 行)・面の fragment(`compile`)・3D 材質の GLSL 部品(`compile3d`)・noise の prelude(hash/worley/fbm/blur/texMip) | prelude 約 150 行＋Field/Shade ごとの式の組み立て（ファイル 1218 行） |
| render_gl/src/Render3dGlsl.flix | 3D の vs/fs/影/空/ポスト 等 | #version 9 本・579 行・uniform 宣言 約 90 行 |
| render_gl/src/GlOffscreen.flix | CPU 突き合わせ用の補助プログラム（RGBA32F に塗る 546 行付近・深度 627-628） | 3 本・小さい。ゲーム実行では使わない【推】 |
| bench/gl_parity/src/ExprRows.flix | 突き合わせの検査用 | 4 本（エンジン本体ではない） |
GLSL を使う機能: `fwidth`（SDF 文字・角丸・縞の AA）・`discard`・`mod`・`smoothstep`・`for` ループ（worley は 3×3 固定・fbm は octaves 可変・blur は 64 まで）・`dFdx/dFdy`・`textureSize`・`textureLod`・`texelFetch`(3D)・`gl_FrontFacing`(3D)・`flat` varying(3D)。2D の面で使う微分は `fwidth` だけ【確】（WGSL では dpdx/dpdy/fwidth があり **uniform control flow の中でしか呼べない** — instanced fs は `if (InstFlags.x > 0.5)` の分岐の**中**で fwidth を呼んでいる（Shader.flix:236-238 ほか）。WGSL の uniformity 解析に落ちる【確→推】。分岐の外で計算して選ぶ形への書き換えが要る）。

### 2.2 (b) ゲーム・データから GLSL を組む所【確】
- `ShaderDoc.Spec = { name, bindings, cycleRate, out }`（engine/src/shader/ShaderDoc.flix:227）。値の場 `Field`（Const・Uv・Worley・Fbm・FbmTile・Smoothstep・Scaled・Warp・Mix・Blend・Disk・Radial・Quantize・Scales・Glints・Ripples・Sparkle・Bin・Hash1/2・Un・Pow・Time・Tiling・Ref・Tex・Blur・Param・World …）→ 色 `Shade`（Solid・Rgb・Ramp・Gradient・Cosine）→ 出力 `Out.Fill{shade, alpha}`。docs/shader-doc.md が語彙表。
- 先頭コメント（ShaderDoc.flix:1-12）に明記: 「**任意 GLSL は書けない — 語彙の合成だけが GLSL になる**」。docs・templates・examples に、ゲームが GLSL の字を直に書いている例は**無い**（templates は 4 本。`templates/sound-novel-starter/src/Backdrop.flix` が ShaderDoc の `blur` を使う例で GLSL 文字列は無い）。
- 出し分け: `ShaderGen.compile(spec)`（ShaderGen.flix:541）= fragment 全文、`vertexSource()` 固定。3D 材質は `compile3d`（:590）で GLSL 部品。CPU 側に同じ式の評価器 `ShaderEval.flix`（1079 行・SoftRaster 用）があり、「式は 1 つの元から出す」という方針（docs/backend-parity.md 決まり 1）。PostProcess.flix（トーンマップ・FXAA）も ShaderDoc の Spec で組む。
- **示唆【推】**: ShaderGen の出力先を WGSL に増やせば、ゲーム側は無改修。ShaderGen は「Field の木 → 式の文字列」の再帰で、GLSL 特有の書き方（`vec2(...)`, `mod`, `fract`, `for (int ..)`, 三項、`out vec4`、`uniform float uParamN`、`texture(sampler2D)`）に依存する部分が WGSL との差分になる。**WGSL は暗黙の型変換が無い**（int と float の混在不可）ので、`float(i)` などの明示が全箇所で要る。

### 2.3 (c) GL 3.3 と WebGL2 の出し分け【確】
ソースは全部 `#version 330 core` で書き、**ブラウザは実行時に頭だけ替える**: engine_web/js/fge-web.js:72 `fgeEsSource` が `#version 330 core` の行を `#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n` に置き換える（WebGl2.java:311-314 `shaderSource`）。字の出し分けはこれだけ（GLSL 本体は共通）。WebGPU では **GLSL→WGSL は別の生成物**になる（前に付ける字では済まない）。選択肢: (i) ShaderGen と固定ソース約 15 本を WGSL でも書く、(ii) GLSL→SPIR-V→WGSL をビルドで通す（glslang/naga。ブラウザへ運ぶ量が増える・Flix→TeaVM の wasm の側に持ち込む物が増える）【推】。

### 2.4 `ShaderCache.flix` の鍵【確】
rg/ShaderCache.flix は GL を呼ばない純関数 2 本（`computeEvictions` = LRU 追い出し鍵の選択、`retiredToDelete`）。鍵の実体は Paint.flix:
- `shaderProgramCache: Ref[Map[String, (Spec, ProgramEntry)]]`。**鍵は `spec#name`**（Spec の name）。当たりでも `ShaderGen.isSameSpec`（参照一致）→ `eqSpec`（構造比較）で中身を確かめ、違えば作り直し（ホットリロード対応）。GLSL 全文は鍵にしない（組み立てが重いので）。
- LRU の上限 = `max(16, 今コマで使っている面の数 × 2)`。現コマで使った program は pin、前コマの面（lastFrame#surfaces）も pin。同名で作り直して鍵から外れた program は「引退」して 1 コマ遅れで消す（`retireSweep`）。
- コンパイル失敗は `tryCreateProgram` が None → `fallbackShader`（代表色ベタ塗り）。**コンパイルは同期**（`compileShader` → `getShaderi(COMPILE_STATUS)`）。WebGPU のパイプライン作成は `createRenderPipelineAsync` で非同期にできる／できるだけそうしたい（コンパイルでコマが止まる）ので、「できるまで fallback で描く」の形に自然に合う【推】。パイプラインの鍵は (spec 内容, blend, 描き先の format, samples)になり、**今の鍵より次元が増える**（blend 3 種 × 描き先 format 2 × samples 1/2/4/8 → 最大 数十本/面）【推】。

## 3. uniform の渡し方【確】
- すべて **名前で location を引いて 1 つずつ**。ただし起動時（program 作成時）に 1 回だけ引いてレコードに詰める（`SpriteUniforms`/`TileUniforms`/`PolyBatchUniforms`、面は `shaderUniformCache`: program → (uRectPos,uRectSize,uTime,uAlpha, texLocs, paramLocs)）。毎コマの文字列引きは無い。
- 種類: float・vec2/3/4・mat4（projection のみ。2D は起動時 1 回）・int/bool・sampler2D・配列(3D のみ `uniform vec3 uPointPos[8]` 等、spot は 2)。GlContext の uniform 系は `uniform1i/1f/2f/3f/4f/1fv/2fv/3fv/uniformMatrix4fv`。
- 2D の live な各プログラムの uniform 本数:
  | プログラム | uniform |
  |---|---|
  | instanced sprite | projection, image(sampler), multiplyBlend = **3 本**（per-sprite の値は全部 instance attribute） |
  | poly batch | projection, multiplyBlend, viewOffset, viewScale, halfDesign = **5 本** |
  | tile | projection, layerPos, tileSize, tileScale, layerColor, image = **6 本** |
  | 宣言面 | projection, uRectPos, uRectSize, uTime, uAlpha + (uTexN, uTexFlipN)×読むテクスチャ数 + uParamN×param 数。tex 読み・param は Spec で決まる。【推】10〜20 本程度 |
  | （旧 sprite uniform 版・死んだ経路） | 約 23 本 |
  | 3D | Render3dGlsl.flix に uniform 宣言行 約 90（配列含む）。最大の物は材質＋光＋影＋骨 |
- 持ち越しに注意する作法が随所にある（「前の面の濃さが残る」「毎 draw 恒等へ明示リセット」「multiplyBlend を毎回 0 に」）。これは GL の「状態を持ち越す」性質に合わせた防御で、WebGPU（状態は毎 draw 全部渡す）では**不要になって素直になる**【推】。
- WebGPU への写し方【推】: 2D の固定 3 本は「projection + 少数」を 1 つの uniform buffer（フレームごと 1 回書き）にでき、per-draw で変わるのは「テクスチャ（bind group）と scissor」だけ。面は uRectPos/uRectSize/uTime/uAlpha/uParamN を 1 本の uniform buffer（面ごとのオフセット＋dynamic offset）にする。`uTexN` の sampler 番号 = unit 番号という作りは bind group の binding 番号に写る。texture と sampler が別 binding になる（GL は sampler object を `bindSampler(unit, ..)` で上書きしている — Sprite.flix:422-475。WebGPU の model に近い）。

## 4. blend・scissor・stencil・線と点・MSAA・sRGB・premultiplied

### 4.1 blend【確】
- 2D: `gl.blendFunc` 1 本（`blendFuncSeparate` は 3D の一部だけ）。Sprite.flix:36 `applyBlend`:
  - Normal: SRC_ALPHA, ONE_MINUS_SRC_ALPHA（**straight alpha**。α チャンネルも同じ式で混ざるので画面/ターゲットの α は a² 的に混ざる）
  - Add: SRC_ALPHA, ONE
  - Multiply: DST_COLOR, ONE_MINUS_SRC_ALPHA ＋ **フラグメントで `rgb *= a`**（multiplyBlend uniform）
- 3D: `blendFunc(ONE, ONE_MINUS_SRC_ALPHA)`（Render3d.flix:508、場面の FBO を 2D に重ねる時）・`blendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)`（:567）。
- → WebGPU の `GPUBlendState`（color/alpha 各 {srcFactor,dstFactor,operation}）で全部表せる【確→推】。blend が pipeline の一部になるので、**blend 3 種 × シェーダー**がそのままパイプラインの本数になる。`dst-alpha`/`src` 系は `src1` を使っていないので dual-source は不要。
- blend のデフォルトは `GL_BLEND` を LwjglLayer.flix:393 で 1 回 enable。

### 4.2 scissor / clip【確】
clip 矩形（`DrawCmd.clipPixels` で int 量子化）ごとに `glScissor`（y を左下原点へ反転・viewport と交差）。run の分断キー。0 幅・0 高の矩形は「何も描かない」。→ WebGPU の `setScissorRect`（左上原点。**反転が要らなくなる**）。描き先のサイズ内に収める制約（範囲外はバリデーションエラー）があるので viewport と交差させる既存の処理はそのまま使える。clear は `loadOp` で行うので、2 段階 clear（黒帯→design 領域）は「全面 clear → scissor 付きで色だけ塗る四角を描く」か、黒帯を別 clear にできない（1 パスの loadOp は全面）ので**矩形描きに置き換え**が要る【推】。

### 4.3 stencil【確】
使う。mask 付き sprite / mask 付き面だけ（Sprite.flix:503-534, 644-675）。手順: `STENCIL_TEST` enable → `clearStencil(0)`+`clear(STENCIL_BUFFER_BIT)`（**描き途中**で）→ `ALWAYS/REPLACE` で colorMask false にして多角形を描く → `EQUAL ref 1` + stencilMask 0 で本体 → 後始末。フレームバッファには depth24-stencil8 renderbuffer が付いている（Target.flix: createStored の `DEPTH24_STENCIL8`、画面側は窓の既定）。
WebGPU では stencil clear は loadOp 単位なので**パスの途中で clear できない**。(a) mask ごとにレンダーパスを切る（パス内 draw の順序が重い）か、(b) stencil に毎回 ref を変えて（ref = 通し番号, compare EQUAL, passOp replace）clear を避ける（8bit なので 255 回で一巡）か、(c) mask を別テクスチャへ描いて discard で抜く、のどれか【推】。mask は「少数枚の前提」（Frame.flix のコメント）で、gallery テンプレで多用しているかは未確認【推】。
深度: 2D は depth を使わない（z は CPU ソート）。3D の場面と影だけ depth（DEPTH_TEST・depth24 texture）。

### 4.4 線と点【確】
`GL_LINES` / `GL_POINTS` は**使っていない**（render_gl・engine_web に出現 0）。線は `RawDraw.lineQuad`/`lineSeg`（engine_world/src/RawDraw.flix:134,143）が**四角形の多角形**にして三角形 draw。点も同様に多角形/箱。→ WebGPU の `line-list` 等を気にしなくてよい。線の太さ・AA は CPU で形を作る方式。**多角形の縁は MSAA なし・AA なし**（docs/backend-parity.md「縁だけ近似: GL は AA なし」）。角丸は SDF(fwidth)で AA がある（箱のみ）。

### 4.5 MSAA【確】
窓は GLFW_SAMPLES を頼まない（Paint.flix:300 のコメント「窓の MSAA は 2D の縁も変える」）。MSAA は **RenderTarget.Descriptor#samples が 2 以上の Pass だけ**: `RenderTargetGl.createWithSamples`（Target.flix:39）が renderbuffer の multisample FBO を作り、`endTarget` で `blitFramebuffer` resolve（Target.flix:95）。`GL_MAX_SAMPLES` で頭打ち、作れなければ警告して 1 に。標本数は 1・2・4・8（WebGPU は **1 か 4 のみ**）。cutout 材質は `SAMPLE_ALPHA_TO_COVERAGE`（3D の Material.flix:133。WebGL2 版は discard で近似済み＝ `hasAlphaToOne`）。WebGPU は alpha-to-coverage を pipeline の multisample 設定で持てる。

### 4.6 sRGB【確】
使わない。`FRAMEBUFFER_SRGB`・`GL_SRGB*` の出現 0。画面も FBO も全部ガンマ空間のままで混ぜる（HDR の Pass だけ RGBA16F でリニア値扱い）。画像は `premultiplyAlpha:"none", colorSpaceConversion:"none"`（fge-web.js:196,725,1131）で解く＝**画素を変換しない**。WebGPU のキャンバス format は `bgra8unorm`（`-srgb` を選ばない）なら今と同じ。ただし `copyExternalImageToTexture` の `premultipliedAlpha:false`・`colorSpace` の指定を合わせる必要あり【推】。

### 4.7 premultiplied alpha【確】
テクスチャは **straight alpha**（premultiply しない）。ブレンド係数で `SRC_ALPHA` を掛ける。Multiply だけシェーダーで rgb*α。ブラウザの `canvas` の alphaMode は【未確認】（WebGL2 の context 作成オプション。fge-web.js を要確認）。WebGPU は `alphaMode: 'opaque'` が素直【推】。

## 5. 画面の外へ描く物（FBO）

### 5.1 Target / RenderTexture【確】
- `RenderTargetGl.Entry = { fbo, tex, depthStencil, width, height, format, storedFormat, samples, msaa }`。`createStored`: 色テクスチャ（RGBA8 = `texImageArgbZero`・RGBA16F = `texImageRgba16fZero`）NEAREST・CLAMP_TO_EDGE + **DEPTH24_STENCIL8 renderbuffer**（Pass 毎に 1 枚）。RGBA16F の FBO が完成しない機種は RGBA8 へ落ちる（警告 1 回）。
- 寸法: `RenderTarget.texelSizeOf`（Design 基準 or Window 基準 × scale）。**寸法・形式・標本数が変わったら作り直し**（`sameShape`）。
- history（自分の名前を読む Pass 用の前コマの写し）: `prepareHistory`（Paint.flix:342）が `blitFramebuffer` で前コマの中身を別の同サイズ Entry へ写す（窓の時）。1 枚撮り・動画では透明で塗る。→ WebGPU では `copyTextureToTexture`（MSAA resolve 後の tex から）。
- ターゲットは GL の左下原点で「上下逆に格納」され、貼る側の uv 反転（`Frame.targetUvFlipped`）・面は `uTexFlipN` で吸収。WebGPU は上が原点なので、**反転の規約そのものが要らなくなる／逆に既存の反転を全部止める必要がある**（片方だけだと二重反転）【確→推】。
- registry には design の寸法で登録する（縮んだターゲットも design 全面に貼れる）。

### 5.2 後がけ Pass の段数・形式【確/推】
- ポストエフェクトは専用の描き手ではなく、**ふつうの Pass + ShaderDoc の面**で組む: `PostProcess.tonemapped`・`fxaaSpec`（engine/src/shader/PostProcess.flix）、ブルーム・ぼかしは `Field.Blur`（taps 最大 64・円状サンプル）、光マップは `Light.lightMapPass`（engine_world/src/Light.flix:255。灯りを 1 枚の Pass に Add で集めて本編に Multiply で貼る）。典型的な段: 本編 → Rgba16Float の Pass（HDR・任意 MSAA）→ トーンマップ Pass(Rgba8) → FXAA の面 → 画面。**段数はゲームが宣言する数だけ**で固定ではない。
- 形式は 2D の Pass では Rgba8Unorm と Rgba16Float のみ。3D 側に RGBA32F（骨・instance 用データテクスチャ。`texSubImageRgba32f`）・depth24（影の map）。
- 浮動小数 FBO への書き込みの決まり: 面の rgb を [0,65504]・α を [0,1] に切る（ShaderGen.writeRuleStatement）— 8bit の FBO は GL が切るので同じ式。WebGPU は rgba16float を既定でレンダーターゲットに使え、blend も可（float32 は `float32-blendable` 機能が要る。2D は float32 に描かないので不要）。

### 5.3 glReadPixels 等の読み戻し【確】
**ゲームの実行中に使う所（デスクトップ）**:
- F8 注釈のスクショ・止めた画面: `LwjglLayer.framebufferImage` → `GlReadback.readBoundImageRgb`（`glReadPixels` 同期・行逆順の詰め替えを Flix のループで）。デバッグ用。
- `FLIX_GE_FRAME_SHOT` 環境変数: 毎コマ `glReadPixels`（上限 64 枚。LwjglLayer.flix:104-113）。デバッグ用。
- 3D の材質が「登録済みの 2D の絵（ターゲットを含む）」を読む時の mipmap 写し（`Material.mipCopyUpload` → `gl.readTextureArgb`、Material.flix:277）。デスクトップのみ（`prefersGpuMipmap()` が false の時）。絵の version が変わった時だけ【確】。ブラウザは `copyTextureLevel0`（GPU 内）で読み戻さない。
- `hidden` 起動の隅 1 画素プローブ（gl-parity 検査用）。
**ゲーム実行ではなく生成・検査**: `GlOffscreen`（窓なし GPU の描き出し・動画・1 枚撮り）の `glReadPixels`（GlOffscreen.flix:435・450・695 = RGBA/BGRA/浮動小数）、bench の gl-parity / gl-capture。
- **当たり判定・ゲームロジックは GPU の画素を読まない**【確】（ゲームの読み戻しは見当たらない。engine_world に glReadPixels の出現 0）。
- **同期で読む前提**: `GlReadback`・`GlOffscreen` の readPixels は呼んだ所で値が返る前提。WebGPU の `mapAsync` は非同期なので、(a) F8 スクショ・FRAME_SHOT・動画書き出しは「次のコマで受け取る」へ、(b) GlOffscreen は WebGPU ではなく **SoftRaster（CPU）か GL のまま**、(c) 3D の mip 写しは `copyTextureToTexture` で GPU 内に閉じる、の整理になる【推】。ブラウザ（WebGL2）の `readTextureArgb` は既に FBO 経由の読み戻しで WebGl2.java:187 にある（ここだけは同期的に書いてある。JS 側 `readPixels` が同期）。

## 6. テクスチャ【確】
- **アトラス**: 画像は 1 枚 1 テクスチャ（project.json の textures を 1 つずつ `texImageBytes`/`texImageArgb`）。**画像を詰めるアトラスは持たない**（タイルセットの画像・PxSpriteAtlas が生成した 1 枚を ensureTexture で上げる、というゲーム側の生成）。実行時アトラスは `PxSpriteAtlas.bake`（ARGB int 列 → `loadTextureFromPixels`。GL_BGRA/UNSIGNED_INT_8_8_8_8_REV）。同名・同辺長なら**全部上げ直し**（`updateTexturePixels`。bench で部分更新と差が出なかったと WhyNot に記録）。
- **フォント**: SDF の 1 チャンネルアトラス `GL_R8`（`texImageAlphaMask`、swizzle で R=α、**`TEXTURE_SWIZZLE_*` を使う**）。辺は 4096 か 8192（`atlasSizeCandidates`）または Tight。LINEAR フィルタ。
  - 実行中に字を足す: `RenderGlyphGrow`（GlyphGrow.flix）が stb で 1 字ずつ SDF を作り **`glTexSubImage2D`（GL_RED, UNSIGNED_BYTE）で区画だけ**上げる。事前に `pixelStorei(UNPACK_ALIGNMENT, 1)`。1 コマで数字ぶん。→ WebGPU: `queue.writeTexture`（`bytesPerRow` は 256 の倍数の制約は writeTexture には無いが、`copyBufferToTexture` には有る）。**R8 の swizzle は WebGPU に無い**ので、フラグメント側で `.r` を α として読む（font 用 shader の分岐が既に `texture(image, uv).a` を使う所: Shader.flix:236 を `.r` に）【推】。
  - 実行中に字を足す機構はデスクトップのみ（stb が要る）。ブラウザは `font-bake`（FontAtlasBake.flix）で事前生成した `.fontatlas` を使う（字を足さない）【確】。
- **mipmap**: 2D は無し（全テクスチャ NEAREST・REPEAT。pixel art 前提）。3D の材質の絵だけ段つき（CPU `Mip.build` または `generateMipmap`）。
- **フィルタ**: 2D 画像 NEAREST、フォント LINEAR、面の tex は sampler object（Nearest|Linear・CLAMP_TO_EDGE 固定）。**画像の REPEAT** が既定（`loadTextureFromPixels`/`uploadBytes`）— uv が 0..1 を超える使い方が許されるので sampler の addressMode を repeat にする必要。非 2 のべきの寸法（NPOT）は WebGL2/GL3.3 も WebGPU も repeat 可（制限なし）。
- **最大の大きさ**: 2D の画像・アトラスについては `MAX_TEXTURE_SIZE` を**問い合わせていない**（問い合わせは DataTexture.flix:52 の 3D 用データテクスチャのみ）。フォントが 8192 を選ぶことがある。WebGPU の既定上限は `maxTextureDimension2D = 8192`（保証値）。8192 のフォントアトラスは R8 で 64 MB。
- 形式: RGBA8（BGRA 並びの ARGB int 列から）・RGB8（alpha 無し png は 3 バイトで上げている: `texImageBytes(RGB)`。WebGPU に RGB8 は無い → RGBA に詰め直し）・R8・RGBA16F・RGBA32F・depth24。

## 7. SoftRaster と「2D の描き手」の数【確】
- 実装は 2 系統。**GL 系**（render_gl/RenderPaint：LwjglLayer=デスクトップ窓・GlOffscreen=窓なし GPU・engine_web/WebLayer=WebGL2 の 3 つの外側が、同じ `RenderPaintHandlers` と `GlContext` の 3 実装（LwjglGl・WebGl2・RecordingGl(包む物)）を使う）と、**CPU 系**（engine_tools/SoftRaster.flix 686 行＋HeadlessRender.flix 596 行＋ShaderEval。生成・スナップショット・F8 注釈・Studio のプレビューが使う）。
- **差し替わる高さが違う**: GL は `Platform.Draw2d.renderCommands`（effect）の handler。SoftRaster は effect の外で `GameEngine.Drawable` / `PolygonRenderCmd` / `SurfaceCmd`（`Render.shaderSurfaces` が純データにした物）の**列を直に受ける関数**（`SoftRaster.render*`）で、Platform.Draw2d の handler は SoftRaster 側には無い【確】（`handler Platform.Draw2d` の定義は render_gl/PaintHandlers と テストの偽物 2 つのみ）。2 つの描き手は「同じ指定（Drawable・PolygonRenderCmd）を受けて同じ絵になるべき」という約束で並ぶ（docs/backend-parity.md）。
- よって WebGPU の描き手を足すと、**3 本目（GL・WebGL2 を同じ GlContext で数えれば 2 系統→3 系統）**になる。差の対応表（docs/backend-parity.md）は「GL 列」「SoftRaster 列」の 2 本立てで、決まり: (1) 式の所は 1 つの元から（LightModel3d・ShaderDoc）、(2) 退行の元にならない物は「GL だけ」と書く、(3) CPU に足すかは「gallery/reference で止めたいか」。**WebGPU を足す時の最短の道: GL と WebGPU を `make gl-parity`／`gl-capture`（SHA 比較）・`?capture=<n>`（web-capture.md）で比べる**。合格線は RGB 差 2/255 以下の画素 99.9% 以上（ブラウザ版の現行基準）。
- 各系統の近似（表から）: 多角形の縁(GL AA なし・CPU は Java2D AA)、文字(SDF vs 直 drawString)、宣言面（本物 GLSL vs ShaderEval）、MSAA は GL のみ、alpha to one は WebGL2 に無い、など。3D は GL 側が主で CPU も別実装（Scene3d の SoftRaster3d）。

## 8. WebGPU へ移す時の「素直に行く所 / 引っかかる所」（まとめ）
| 項目 | 現状 | WebGPU での見立て |
|---|---|---|
| 描き手の高さ | Draw2d(2 op)・Target(3 op)・GpuResources(7 op)。handler 3 か所が同じ RenderPaintHandlers を共有 | effect はそのまま使える。**RenderPaint（Paint レコードと GL ハンドル前提のコード 約 920 行）と Frame/Sprite/Target の GL 呼び出しは書き直し**。GlContext 差し替えでは足りない【推】 |
| pipeline | program は 5 本固定＋面ごと 1 本。blend は draw 前の状態変更 | pipeline が (shader, blend, 描き先 format, samples, stencil 有無) の鍵になる。面は現状 name 鍵の LRU（上限 max(16, 使用面×2)）を **pipeline 鍵へ拡張** |
| shader | GLSL 330（固定 約 15 本）＋ ShaderGen が文字列で生成 | WGSL 化が必要。ゲームが直に書く口は無いので移行コストは エンジン内に閉じる。fwidth を分岐の中で使っている所は uniformity で落ちる |
| uniform | 名前→location で 1 個ずつ（起動時 1 回引く） | uniform buffer + bind group。2D の固定 3 プログラムは少ない（3/5/6 本）ので易しい。面は uTime/uAlpha/uRect/uParam/uTex の組 |
| 頂点 | float のみ・instanced 中心・6 頂点の非 index quad | layout は書きやすい。per-run の dynamic 書き込みは**オフセットを進めて 1 本の buffer に詰める**形が要る |
| 状態 | scissor・blend・stencil を run の切れ目で変える | scissor は setScissorRect で素直（左上原点で反転が消える）。blend は pipeline 切り替え。**stencil clear が途中で要る mask は設計し直し** |
| 2 段 clear（黒帯） | scissor で design 領域だけ clearColor | loadOp は全面 → 黒帯用の矩形描きに置き換え |
| FBO | Pass 単位。histroy 写しは blitFramebuffer、MSAA は resolve blit、depth24-stencil8 は renderbuffer | 全部 render pass の resolveTarget・copyTextureToTexture・depth24plus-stencil8 に写せる。**MSAA の標本数は 1/4 のみ**（今は 1/2/4/8）、RGB8 無し、Y 反転規約が逆 |
| 読み戻し | デバッグ・生成・3D の mip 写しだけ。ゲーム判定には使わない | 非同期にして問題無い。同期前提は GlReadback・GlOffscreen・Material.mipCopyUpload（デスクトップ分岐） |
| フォント | R8 + swizzle・texSubImage で字を足す（デスクトップのみ） | swizzle を shader 側へ。writeTexture は区画でよい |
| 色・alpha | sRGB 無し・straight alpha・Multiply だけ shader 前掛け | canvas を非 sRGB の format・alphaMode opaque で今と同じ。blend 式は全て GPUBlendState に載る |
| 線・点 | 三角形で作る（GL_LINES 未使用） | 影響なし |

## 9. 未確認（次に見るなら）
- 【未確認】TextDraw.flix（1 字 1 Drawable か）・engine_web の canvas の alpha/premultipliedAlpha 設定・MAX_TEXTURE_SIZE の実機上限・mask 付き描きを実際にどのテンプレが使っているか・`GlOffscreen` の GPU 描き出しが CI/生成のどこで使われているか（SoftRaster との使い分け）。
- 【未確認】1 コマの実際の draw call 数（FrameStats.flix・GlCallLog.flix があるので F3 で測れる【推】）。
- 3D 側（Render3d*.flix 約 2600 行・Render3dGlsl 579 行）は今回の範囲外として読んでいない。範囲は「2D とシェーダーの持ち方」。

## 調べ方の記録
- refactor: search ×8・show ×4・usages ×6・outline ×5（計 約 23 回）。
- .flix への grep: 字列（GLSL: `#version`・`gl_Position`・`uniform`・`texelFetch`・`glReadPixels`・`GL_LINES`・`SRGB` 等）と、`handler Platform.Draw2d` のような構文の字を探すための grep。名前の宣言・呼び手を探すための grep は使っていない（hook が数回「名前探し」と見なして警告したが、全て GLSL 文字列・構文探し）。`sed -n` は .flix には最初の 1 回（LwjglLayer 365-390）が hook で止まり、以後は Read ツールで読んだ。
