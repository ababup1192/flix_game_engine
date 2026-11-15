# WebGPU 移行の段階 V1（縦に 1 本・2D）— 設計（第 3 版・段階 1〜5 を実装した）

親の文書は `plans/engine-webgpu.md`（以下「親」。章の番号は親の物）。V1 の中身は親の 9 章の表の V1 の行と、P4b から回した「起動の時の選び分け」（親 5.5・12.12）。
【確】= コードか手元の試しで確かめた ／【推】= 読みや割り算からの見積もり ／【未確認】= まだ確かめていない。
レビュー: 第 1 版 78 点（指摘は「実装に入れない」6 件・「直した方が良い」17 件・好み 4 件）→ 第 2 版で全部入れて 91 点（合格）→ 第 3 版で残りの 6 件（A3 の開き直し・lint の skip・`RenderPaint.Internal`・隠したウィンドウ・足す字の門・`Frame.flix` の下の Internal）を入れた。

## 0. 何を作るか（範囲）

- WebGPU の backend に、2D のスプライト・字・箱（今の 1 本の instanced のプログラム）と、それに要る最小の物: 絵とフォントのアトラスを上げる・Pass を 1 つ挟む・画面へ出す。
- お題: rpg-starter の題名の画面（親 9 章: スプライト 7 個だけ・多角形と面が無い）と、Pass 1 つに通した画面（11 章の 1 で `bench/gl_parity` の `passPaste` などに代えると決めた）。PC とブラウザで出す。
- 選び分け: 既定は GL のまま（リリース 2 まで）。PC は `FLIX_GE_BACKEND=webgpu`、ブラウザは `?backend=webgpu`。使えない時は理由を 1 行知らせて GL で起動する。
- **V1 で描かない物**（WebGPU を選んだ時だけ。名前ごとに初めの 1 回だけ知らせて描かない）: 多角形・タイルの層・static layer・面（`ShaderDoc`）・3D の場面・mask つきスプライト・
  Pass の history（`<名前>@history`）・MSAA（標本 2 以上は 1 で描いて知らせる）・F8 の注釈・PC で起動の後に足す字（`ensureGlyphs`。3.1）。どれも親 9 章の R1b ⇄ P6 以降の物。
- **V1 で変えない物**: `RenderFrame` の関数の中身・`RenderList` の形・GL の backend の流し方・engine（`engine`・`engine_world`）の pub・`render_gl/java`
  （GL の層の jar のハッシュを動かさない。12.9 の 8 の直しも V1 ではしない）。`Frame.flix` で直すのはコメント 1 か所だけ（1.3）。
- **増える pub**（render_gl と engine_web の中だけ。ゲームから呼ばない物は `Internal` の下に置く）:

| パッケージ | 増える名前 |
|---|---|
| render_gl（`Internal` の下） | `RenderFrame.Internal`（中身の無い親）・`RenderFrame.Internal.WebGpuRows.renderFrame`・`LwjglLayer.Internal`（中身の無い親）・`LwjglLayer.Internal.WebGpuWindowLayer.withWindow`・`RenderPaint.Internal`（中身の無い親） |
| render_gl（`Internal` の下） | `RenderPaint.Internal.WebGpuShader.spriteWgsl`・`presentWgsl` |
| render_gl（`Internal` の下） | `RenderPaint.Internal.WebGpuPaint` の `Paint`（型）・`create`・`uploadRgba`・`uploadBgra`・`uploadR8`・`putTexture`・`present`・`readFrame`・`resize`・`repaintLast`・`submitCount`・handler 5 本（`handleDraw2d`・`handleDraw3d`・`handleGpuResources`・`handleDiagnostics`・`handleTarget`） |
| render_gl | `LwjglEnv.Backend`（enum: `Gl`・`WebGpu`）と `LwjglEnv.Settings` の欄 `backend` |
| engine_web（`Internal` の下） | `WebLayer.Internal`（中身の無い親）・`WebLayer.Internal.WebGpuLayer.withWeb` |
| engine_web の Java（public） | `BrowserWebGpu.copyImageBitmap`・`BrowserWebGpu.onDeviceLost`・`Browser.backendRequest`・`Browser.initWebGl2`・`Browser.publishCapture` |

  `RenderFrame.Internal`・`LwjglLayer.Internal`・`RenderPaint.Internal`・`WebLayer.Internal` は `bin/lint-rules/forbid.json` の `app-internal` の正規表現に足す（ゲームから呼ぶと止まる）。
  `WebLayer.Internal` を足すので、同じ規則の `skip` に `engine_web/`（索引の道で引っかかるなら `src/engine_web/` も）を足す（engine_web の自分の中から呼ぶため）。`docs/api-digest` には載せない（`App.Internal` と同じ）。
  以下、`RenderPaint.Internal.WebGpuPaint` を `WebGpuPaint`、`RenderPaint.Internal.WebGpuShader` を `WebGpuShader` と略す。

## 1. 置き場とモジュールの分け方

| 新しい物 | 置き場 | 中身 |
|---|---|---|
| `RenderFrame.Internal.WebGpuRows` | `render_gl/src/RenderFrame/Internal/WebGpuRows.flix`（親は `RenderFrame/Internal.flix`） | 1 回の `renderCommands` を、GL と同じ前半（`mergedByZ` → `emitSprite` が `RenderList` を作る）で行にし、行を WebGPU の render pass へ流す |
| `RenderPaint.Internal.WebGpuShader` | `render_gl/src/RenderPaint/Internal/WebGpuShader.flix`（親は `RenderPaint/Internal.flix`） | WGSL の字（スプライト・字・箱を 1 本、画面へ写す 1 本）。`RenderShader`（GLSL）と対 |
| `RenderPaint.Internal.WebGpuPaint` | `render_gl/src/RenderPaint/Internal/WebGpuPaint.flix` | `RenderPaint` と `RenderPaintHandlers` の V1 の分: device・pipeline・buffer・絵の表・描き先・1 コマの encoder・画面へ出す・5 つの handler |
| `LwjglLayer.Internal.WebGpuWindowLayer` | `render_gl/src/LwjglLayer/Internal/WebGpuWindowLayer.flix` | PC のウィンドウの WebGPU 版（5.1） |
| `WebLayer.Internal.WebGpuLayer` | `engine_web/src/WebLayer/Internal/WebGpuLayer.flix` | ブラウザの WebGPU 版（5.2・6.2） |
| Java・JS | `engine_web/java/fge/web/webgpu/BrowserWebGpu.java`・`engine_web/java/fge/web/Browser.java`・`engine_web/js/fge-web.js` | 6.2 |

### 1.1 前半は共有し、GL の物とは混ぜない

前半の `mergedByZ`・`emitSprite`・`pushSpriteKeyed`・`writeInstAt`・`closeSpriteRun`・`calcViewport`・`countSpriteDraw` と `RenderList` は pub でない。
Flix 0.78 では**子孫の mod から先祖の pub でない物が見える**ので、WebGPU の流し方を `RenderFrame.Internal.*` に置けば、`RenderFrame` の関数を pub に開かず、
`Frame.flix`（1,162 行。上限 1,200 行）にも足さずに済む。`LwjglLayer` の pub でない物（`handleAudio`・`openAudio`・`closeAudio`・`handleTasks`・`handleFrameClock`・
`handleLoadProgress`・`announceFixedDt`・`openCursors`・`frameShotLimit`・`WindowState` など）と `LwjglInput` を使う `LwjglLayer.Internal.WebGpuWindowLayer`、
`WebLayer` の pub でない物を使う `WebLayer.Internal.WebGpuLayer` も同じ形。

- 試し【確】（`build/vis-test`・commit しない・`java -jar bin/flix.jar run`・Flix 0.78.0）: `src/Outer.flix` の `mod Outer` の pub でない `type alias` と `def` を、
  `src/Outer/Internal/WebGpuRows.flix` の `pub mod Outer.Internal.WebGpuRows` から呼んで `42` が出た。親の `src/Outer/Internal.flix`（`pub mod Outer.Internal {}`）が無いと「Orphaned module」、
  子を `pub` でない `mod` にすると「inaccessible module」、ファイル名が mod 名と合わないと「unexpected location」で止まる。
- `mod RenderFrame` は `Frame.flix`、`mod RenderPaint` は `Paint.flix` にあり、ファイル名と mod 名が違う。その下に `RenderFrame/Internal.flix` を置いて「unexpected location」が出ないかを試した【確】:
  `src/Frame.flix` の `mod Outer` に対し `src/Outer/Internal.flix`・`src/Outer/Internal/WebGpuRows.flix` を置いて `42` が出た（同じ `build/vis-test`）。ファイル名の決まりは `pub mod` を自分のファイルに置く子にだけ掛かる。段階 1 の最初に render_gl でもう 1 度確かめる。
- 名前を `RenderFrame.WebGpu` にしないのは、Java の `fge.webgpu.WebGpu` を import する mod の中で同じ名前が上の名前を覆い隠すため（mod の中の同名の eff が top-level の module を覆い隠した前例がある）。
  `<元>.Internal.<役>` は `docs/flix-conventions.md` の決まり。

### 1.2 新しい抽象は足さない

GL と WebGPU の選び分けは、入口が差す handler の組（`RenderPaintHandlers` か `WebGpuPaint` の handler）だけで決まる。`Fs`・`WebGpuDevice` と同じ形で、
境目は今ある `Platform.Services` の handler 一式。`RenderList` は 2 つの流し方（GL の `drawRow`・WebGPU）が読む**値**で、interface ではない。
trait・関数の record・backend の enum は足さない（「層を置く物差し」: 2 つ目の実装が無い層を足さない）。
`docs/flix-conventions.md` の「層を置く物差し」の表の 1 行目（handler 一式）の「今ある実装」に、実機の WebGPU（`WebGpuPaint` の handler・`LwjglLayer.Internal.WebGpuWindowLayer`・`WebLayer.Internal.WebGpuLayer`）を足す（段階 5）。

### 1.3 `Frame.flix` のコメント

557 行の WhyNot（「別のモジュールに出さない — 別のモジュールの pub でない関数は呼べず …」）は、子孫の mod からは見えるので事実と合わなくなる。
段階 1 で「兄弟の mod からは呼べない（子孫の `RenderFrame.Internal.*` からは見える）」に直す。564 行（`RenderSprite` は兄弟なので呼べない）は合っているので直さない。

### 1.4 `RenderPaint` との重なり

`WebGpuPaint` を `RenderPaint.Internal` の下に置くので `RenderPaint` の pub でない物も見えるが、見直すと写さずに呼べる物はほとんど無い:
`RenderPaint` の pub でない関数（`sameShape`・`sameTexture`・`warnTargetOnce`・`warnFormatFallback`・`dropHistory`・`takeScenes`・`timedSpan` など）は、どれも GL の `Paint` の record か `RenderTargetGl.Entry` を受ける。
pub の `noteDiagnostics`・`consumeDiagnostics`・`putTexture` も GL の `Paint` を受ける。呼べるのは `Paint` を受けない `pixelScaleOf` の式（`calcViewport` を使う 2 行）くらいで、これは `RenderFrame.calcViewport`（pub）から書く。
そこで登録簿・`ensureTexture` の key・描き先の表・溜めた面と場面・`lastFrame`・診断の溜め方は V1 では写す（約 300 行の見込み【推】）。`RenderPaint.Internal` に置く得は pub の面を増やさない事。
1 本にまとめるのは親の R1b の「物の上げ下ろしと寿命の表」（12 章の 5）で、その時に GL の `Paint` から CPU の側の表を外へ出せば、両方が同じ関数を呼べる。
置き場を render_gl にするのは親 11 章の 7 と同じ。ブラウザの書き出しに Dawn は入らない（Dawn を名指すのは `LwjglLayer.Internal.WebGpuWindowLayer` と `WebGpuDevice.runDawn` だけ）。

## 2. 1 コマの流れ（`RenderList` の行 → WebGPU）

1 回の `Draw2d.renderCommands` を、今の GL と同じく**その場で**流す（親 5.1）。違いは「submit はコマの終わりに 1 回（例外は 3.2）」だけ。

1. `WebGpuPaint` はコマの最初の `renderCommands` で `CommandEncoder` を 1 つ作り、コマの終わり（`Window.presentFrame`）まで持つ。
2. 描き先（Pass が開いていればその texture・無ければ中間の texture。2.4）に render pass を 1 つ開く。clear は 2.5。
3. `mergedByZ` で並べ、`MSprite`（mask 無し）だけ `emitSprite` で `RenderList` へ積む。ほかの種類は知らせて飛ばす（0 章）。`targetNames` には空の Set を渡す（2.6）。
4. 行を流す: `instances` の使った範囲を、コマで 1 本の instance buffer の「このコマで次に空いている位置」へ `writeBuffer` 1 回で送り、行ごとに下を積む。
   - pipeline: blend（行の欄 4）× 描き先の形式で引く（2.3）。前の行と同じなら積まない。
   - 絵: 行の欄 3（`textureId`）→ 絵の表 → bind group（group 1）。0（絵の無い箱）は前の bind group のままでよい（pass の頭で 1×1 の透明な黒を付けておく）。前と同じなら積まない。
   - clip: 欄 5〜9 → `setScissorRect`（2.6）。幅か高さが 0 の行は draw を出さない（数えるのは GL と同じく 1。GL は 0 の scissor で draw を出して何も描かない）。
   - `draw(6, count, 0, base + first)`。`base` は 4 で送った位置（instance の番号）。
   - draw の数は `countSpriteDraw`（子孫から呼べる）で数える。診断の数は GL と同じ物差し。
5. render pass を閉じる（`end`）。submit しない。
6. `presentFrame` で、中間の texture を画面の texture へ写す pass を積み、`finish`・`submit`・`present`（隠して起動した時は 5.1）。

### 2.1 instance の 38 float は、そのまま instance の頂点バッファに上げる

- GL と同じ並び（stride 152 バイト・location 1〜10）を `vertexBuffer(152, perInstance = true)` で読む。`RenderList` の `instances` を詰め替えない。
- `firstInstance` は instance の頂点バッファの読み始めにも反映される（WebGPU の決まり。indirect でない `draw` は機能を求めない）。12.7・12.12 の 20,000 本の試しは storage buffer と
  `instance_index` で引く形だった。頂点バッファの形の代金は段階 1 で `webgpu-check` の試しに足して測る（10 章）。
- storage buffer にしない理由: 並びが GL と同じなので WGSL と GLSL を 1 行ずつ対で読め、門で差が出た時に追いやすい。頂点の属性は 10 本（上限の既定 16）、
  頂点バッファは 1 本（既定 8）、頂点と塗りの間の値は vec4 8 本（既定 16）で、上限に当たらない。draw ごとの値を行に入れる形（親 6.1 の 1）は P5・P6 の物（12 章の 12）。
- 四角の 6 頂点は WGSL の定数の配列にし、`vertex_index` で引く（値は `RenderSprite.initSpriteRenderer` と同じ）。

### 2.2 bind group

| group | 中身 | 作り直す時 |
|---|---|---|
| 0 | 射影の行列（uniform・64 バイト） | 作らない。design の大きさは起動で決まる（GL も `setProjectionMatrix` を起動で 1 回） |
| 1 | 絵の view と sampler | 絵を作った時に 1 つ。`ensureTexture` で大きさが同じなら texture も bind group もそのまま（`writeTexture` だけ） |

### 2.3 pipeline

- 鍵 = blend（Normal・Add・Multiply）× 描き先の形式（`RGBA8_UNORM`・`RGBA16_FLOAT`）。最大 6 本。ほかに画面へ写す 1 本（画面の形式ごと）。
- blend は `glBlendFunc`（色と alpha で同じ因子）と同じにする: Normal = (src-alpha, one-minus-src-alpha)・Add = (src-alpha, one)・Multiply = (dst, one-minus-src-alpha)。
  alpha の成分にも同じ因子を書く（2D の道は `blendFuncSeparate` を使わない。使うのは 3D の `Render3d` だけ）。Pass の texture の alpha まで GL と同じになる。
- Multiply の「rgb × a」（GL は uniform `multiplyBlend`）は、同じ module の 2 つ目の入口 `fs_multiply` にする。
- 作る時: `RGBA8_UNORM` の 3 本と画面へ写す 1 本は起動の時（起動画面より前）。`RGBA16_FLOAT` は初めて要る Pass で作る。
  ブラウザで 1 本 65〜93 ms（親 4.3 の試作で、作り終わるまで待った値）。V1 の `WebGpu` は同期の `createRenderPipeline` だけで、ブラウザの同期版はすぐ返って最初の draw で待つ【推】。
  コマの途中の 1 本（Rgba16Float の Pass）で 1 コマ落ちうるのは V1 では認める（親 8 章の async は P6）。

### 2.4 render pass の切り方（親 5.4）

- **画面へは直に描かない。** コマは中間の texture（`RGBA8_UNORM`・描き先の画素の大きさ・`RENDER_ATTACHMENT | TEXTURE_BINDING | COPY_SRC`）へ描き、
  `presentFrame` で 1 回だけ画面の texture へ写す（全面の三角形 1 枚・`textureLoad` で整数の座標を読む。標本と sampler を使わないので filter の差が出ない）。理由:
  - ブラウザ: TeaVM はコマの途中で手を返すことがあり、`getCurrentTexture` はそこで切れる（親 5.4）。
  - PC: 画面へ出す待ちは `getCurrentTexture` で起きる（12.7）。最後に 1 回だけ取れば、待ちはコマの CPU の仕事の後ろに 1 か所にまとまる。
  - 画面の形式（Mac の Dawn・Chrome とも `BGRA8_UNORM` の見込み【推】）と pipeline の形式を切り離せる。frame shot・`?capture` は中間の texture から読む（2.7）。
- `renderCommands` 1 回 = render pass 1 つ。Pass（`beginTarget`〜`endTarget` の間の `renderCommands`）は、その texture への別の render pass。
- 同じ texture を描き先と絵の両方に使う行は、WebGPU では pass 全体が検証の誤りで落ちる（GL は結果が決まらないだけ）。その行は飛ばして 1 回知らせる。

### 2.5 clear

- 画面: render pass の load を (0, 0, 0, 1) の clear にする。黒帯が無い時（design の矩形 = 描き先の全面。画面なしと gl-capture はいつもこれ）は load の clear の色を `clearColor` にして終わり。
  黒帯がある時は、箱 1 個（Normal・alpha 1。結果は src そのもの）を design の矩形に描く。その instance は、行の instance より前に書く（instance buffer の位置を先に 1 つ進めてから
  `RenderList` の行を送る。行の `first` は 0 から始まるので、同じ位置に書くとスプライトに上書きされる）。
- clear の色は load の値（float）から、箱の色はシェーダーの出力から 8 bit に丸める。GL の `glClear` と丸め方が 1/255 ずれうる【推】ので、黒帯のある場面の許容に書く（8.1）。
- Pass: `LoadOp.Clear(c)` → (c, 1)・`ClearTransparent` → (0, 0, 0, 0)・`Keep` → load。GL と同じく `renderCommands` のたびに op を反映する。

### 2.6 座標と clip

- 射影の行列は GL の物（`RenderShader.setProjectionMatrix`）をそのまま使う。z は 0 なので clip の z の範囲（0〜1）の違いは出ない。clip の y は GL と同じく上向き。
- viewport: `calcViewport` の (vpX, vpY, vpW, vpH) は GL の左下が原点。WebGPU は左上が原点なので `setViewport(vpX, fbH - vpY - vpH, vpW, vpH, 0, 1)`。
- scissor: 行の clip 矩形（viewport の左上が原点）を viewport と交わしてから描き先の座標 `(vpX + cx0, (fbH - vpY - vpH) + cy0)` へ移し、**x を [0, fbW]・y を [0, fbH] に収め、
  幅と高さも描き先の中に収める**（描き先の外へ出た scissor は WebGPU では pass ごと検証の誤り）。clip が無い行は描き先の全面。式は子孫の mod に書き、GPU を呼ばない render_gl のテストで端の場合を見る（8.3）。
- **描き先の texture の上下**: GL の Pass の texture は下の行が先なので、前半は `targetNames` にある絵の uv を上下に返す（`targetUvFlipped`）。
  WebGPU の texture は上の行が先なので返さない。V1 は `targetNames` に空の Set を渡して済ませる（`emitSprite` で `targetNames` を読むのはここだけ【確】）。
  前半が backend に「描き先は上下逆か」を聞く形（親 5.3）は形のレビューへ（12 章の 1）。

### 2.7 読み戻し（V1 は frame shot と `?capture` だけ）

- PC: `FLIX_GE_FRAME_SHOT` は `presentFrame` の中で、中間の texture を `copyTextureToBuffer`（1 行は 256 の倍数にそろえる）→ submit → `readBuffer`（Dawn は待って返す）→ PNG。
  名前は GL の `frameShot` と同じ数え方（`frame-1.png` から・画面へ出したコマごとに 1・上限 `frameShotLimit()` の 64 枚）。GL の `readBoundPng`（下が先）と同じ向きの PNG にそろえる。
- ブラウザの `?capture=N`: N コマ目の `presentFrame` で、下の順に積む。
  1. `getCurrentTexture` → 画面へ写す pass
  2. 中間の texture を `copyTextureToBuffer`（1 行は 256 の倍数）
  3. submit → `readBuffer`（`mapAsync` を待つ。`BrowserWebGpu.readBuffer` は main スレッドの上で `await`）
  4. `Browser.publishCapture(rgba, w, h, "webgpu: <adapter>")` → JS が `window.fgeCapture` と `fgeCaptureReady` を置く（`origin: "top-left"`。`docs/web-capture.md` の約束のまま）

  `presentFrame` の中で待ってよいか（`getCurrentTexture` の texture を出した後に手を返す順で、画面の絵が欠けないか）は【未確認】。欠けても門が読むのは中間の texture なので比べは崩れない。
- F8 の注釈・隠して起動した時の隅の 1 画素の検査は V1 ではしない（WebGPU は隠して起動した時に中間の texture を design の大きさで作るので、隅の検査が守っていた「drawable が design に届かない」は起きない）。

## 3. 物の寿命

### 3.1 V1 の仮の読み込みの道

今の読み込みは全部 `GlContext` を受ける（`RenderPaint.AssetLoader` の `loadTextures`・`loadFonts`・`LwjglAssets.loadTexture`・`RenderFont.bakeFontAtlases`・`RenderGlyphGrow.ensure`・
`RenderSplash.install`・`RenderPaint.loadAssets` の中の `RadialBuiltin` の 2 枚・`WebAssets.uploadImageOf`）。V1 はこれらを触らず、**CPU の側の pub な関数だけを共有して**、
上げる所を WebGPU の側に別に書く（形のレビューで 1 本にする。12 章の 6）。

| 読み込む物 | CPU の側で共有する物（今ある pub） | WebGPU で上げる所 | 増える pub | 行数【推】 |
|---|---|---|---|---|
| PC の project.json の絵 | 無し（stb を呼ぶ 15 行を `WebGpuWindowLayer` に写す。`LwjglAssets.loadTexture` は解いた直後に GL へ上げるので分けられない） | `stbi_load(…, 4)` → `hasAlpha = false` なら alpha を 255 で埋める → `WebGpuPaint.uploadRgba`（`RGBA8_UNORM`） | 無し | 30 |
| PC のフォント | `RenderFontCache.loadOrBake`（アトラスの CPU の作り方とキャッシュ） | `uploadR8`（`R8_UNORM`・LINEAR） | 無し | 25 |
| PC の起動の後に足す字 | — | **V1 では足さない**。ブラウザの `WebAssets.noteMissing` と同じく、フォントごとに 1 回知らせる。`RenderGlyphGrow` は `growOne` の中で GL を直に呼ぶので、分けると GL の道を触る | 無し | 10 |
| 組み込みフォントとロゴ（起動画面） | `BootFont.pixelsArgb`・`BootFont.logoArgb`・`BootFontData.side`・`BootFont.logoSide` | `uploadBgra`（`BGRA8_UNORM`） | 無し | 10 |
| `RadialBuiltin` の 2 枚（`Render.lightAt`・`darkAt` の組み込みの絵） | `RadialBuiltin.lightPixels`・`darkPixels`・`size`・`lightName`・`darkName` | `uploadBgra` | 無し | 8 |
| 生成の絵（`ensureTexture`） | — | `uploadBgra`。大きさが同じなら `writeTexture` だけ | 無し | 30 |
| ブラウザの project.json の絵（`hasAlpha = true`） | `WebImages.has`・`width`・`height`（解いた `ImageBitmap` は JS が持つ） | `BrowserWebGpu.copyImageBitmap(path, texture)` → `copyExternalImageToTexture`（`premultipliedAlpha: false`。行き先の usage に `COPY_DST | RENDER_ATTACHMENT | TEXTURE_BINDING`） | `copyImageBitmap` | 40 |
| ブラウザの絵（`hasAlpha = false`） | 同上 | `copyExternalImageToTexture` は alpha も写すので使わない。`WebImages` の解く道（6.2 の表の 1。隠した canvas の webgl2）で ARGB にし、alpha を 255 で埋めて `uploadBgra` | 無し | 20 |
| ブラウザの後回しの絵（`registerArrivedTextures`） | 上の 2 行と同じ | 同上を `WebGpuLayer` の `onPoll` で呼ぶ | 無し | 20 |
| ブラウザのフォント | `RenderFontCache.decode`・`AssetTable.bytes`・`WebAssets.atlasPathOf` | `uploadR8`。足す字は今と同じく知らせるだけ | 無し | 25 |

### 3.2 物ごとの寿命

| 物 | 作る | 差し替え・伸ばす | 捨てる |
|---|---|---|---|
| 絵（3.1） | 起動の時（後回しの絵は届いた時） | — | 終わる時 |
| 生成の絵 | `BGRA8_UNORM`。ARGB の int を little-endian で並べたバイトは B・G・R・A（3.3）。NEAREST・REPEAT | 大きさが同じなら `writeTexture` だけ・違えば作り直し（古い方は `destroy`）。key が同じなら何もしない（今と同じ） | 同左 |
| フォントのアトラス | `R8_UNORM`・LINEAR・REPEAT（GL は wrap を指定せず既定の REPEAT）。シェーダーは `.r` を読む（GL は swizzle で `.a`） | V1 では足さない（3.1） | — |
| Pass の texture | `beginTarget` で（形式・大きさが変われば作り直す）。NEAREST・CLAMP_TO_EDGE（`RenderTargetGl` と同じ）。登録簿には design の大きさで載せる（今と同じ） | — | 作り直す時 |
| 中間の texture | 起動の時 | 描き先の画素の大きさが変わった時に作り直す | 同左 |
| instance buffer | 起動の時（`4096 × 152` バイト。GL の `RenderBuf` の初めの大きさと同じ） | 足りなければ倍に | 古い方は submit の後に `destroy`（WebGPU は GPU が使い終わるまで実体を残す） |
| pipeline・sampler・layout | 起動の時（2.3） | — | 終わる時に `release` |

**コマの途中で submit する時**: GL は描いたそばから GPU へ行くので、Pass A を描いた後に `ensureTexture` で絵を替えても A は古い絵で描かれる。
WebGPU は submit がコマの終わりなので、そのままだと A も新しい絵で描かれ、伸ばす前の buffer を指したまま submit すると誤りになる。
そこで、**そのコマに積んだ pass があれば、次の前に submit する**: `writeTexture`・絵を作る・Pass の texture を作り直す・古い texture を `destroy` する・instance buffer を伸ばす。

増える場面と代金: Pass の後に初めて出る生成の絵（`ensureTexture` の key が毎コマ変わるゲームは毎コマ 1 回増える）・ブラウザの後回しの絵が届いたコマ。
PC は起動の後に字を足さないので `ensureGlyphs` では増えない（3.1）。比べた 3 案:

| 案 | 選ぶか | 理由 |
|---|---|---|
| 今の案（上げる前に submit） | 選ぶ | 絵が GL と同じ。代金は増えた submit の分だけ |
| staging buffer に書き、encoder の中で `copyBufferToTexture` | 選ばない | 順は保てるが `WebGpu` の interface に無く、足すと GL の層の jar のハッシュが動く。P6 で比べる |
| 上げ物を次のコマへ回す | 選ばない | 1 コマ遅れて GL と絵がずれる |

1 コマの submit の回数は `WebGpuPaint.submitCount` で数え、`FLIX_GE_FRAME_STATS` の出力に `submits` として出す（engine の pub の `FrameDiagnostics` は広げない。広げるかは 12 章の 17）。
段階 5 で `sprite_stress` と題名の画面で数え、表に残す（見込みは 1【推】）。

### 3.3 バイト順

instance の入れ物（CPU の側）は、GL の `RenderBuf` が `gl.allocFloats` で作るので使えない。`WebGpuPaint` が
`ByteBuffer.allocateDirect(n).order(ByteOrder.LITTLE_ENDIAN)` と、その `asFloatBuffer()` の組を持ち、`writeInstAt` は float の方へ、`writeBuffer` はバイトの方を渡す（12 章の 4）。
`allocateDirect` は既定が big-endian なので、`order` を必ず付ける。生成の絵の `BGRA8_UNORM` も、ARGB の int を `order(ByteOrder.LITTLE_ENDIAN).asIntBuffer()` へ写す前提に乗る。

### 3.4 device lost

PC は理由を 1 行出して終わる（コマの途中で GL へ移るには絵を全部上げ直すことになり、V1 ではしない）。ブラウザは今の `webglcontextlost` と同じ文で頁の読み直しを案内する（親 3 章の決め事のまま）。
`device.lost` を受ける所は `BrowserWebGpu.onDeviceLost`（JSO の `lost` の Promise）。Dawn の device lost の callback が jWebGPU で取れるかは【未確認】（取れなければ submit の誤りの数で気づく）。

## 4. Pass を 1 つ挟む

今の GL の Pass（`RenderPaint.beginTarget`・`submitFrame` の `Some(target)` の枝・`endTarget`）と同じ順で受ける。

1. `beginTarget(spec)`: 表に無いか形が違えば texture を作る（3.2 の submit の決まり）。登録簿に `name` → (表の番号, design の幅と高さ) を載せる。開いているフラグを立てる。
2. 開いている間の `renderCommands`: その texture の render pass に描く（2.5 の op）。溜めた面と場面はここで取り出して捨てる（V1 は描かない。今の GL と同じく画面の方へ漏らさない）。
3. `endTarget`: フラグを下ろす（標本 1 なので resolve は無い）。
4. 本編の `renderCommands` は `Render.sprite(name)` を普通の絵として描く。uv は返さない（2.6）。sampler は NEAREST（`Render.Pass` の doc の約束）。

- 自分を読む Pass（`<名前>@history`）は、今の GL が `glBlitFramebuffer` で前のコマを写す所。`WebGpu` の interface に texture から texture への写しが無いので V1 では描かない（親 R1b ⇄ P6 の history）。
- 同じ見た目かは 8.1 の門で GL と画素で比べる。

## 5. ウィンドウ

### 5.1 PC（`LwjglLayer.Internal.WebGpuWindowLayer`）

`LwjglLayer.withLwjgl` の WebGPU の枝。GL の枝が持つ物ごとの扱い:

| GL の枝の物 | WebGPU の枝 |
|---|---|
| ウィンドウの hint・context・`GL.createCapabilities` | 先に device を開き、`WebGpuWindow.open`（`GLFW_NO_API`）・surface を `configure` |
| `announceFixedDt`（gl-capture が grep する `[lwjgl] FLIX_GE_FIXED_DT:` の行） | 同じ関数を呼ぶ（子孫から見える） |
| 隅の 1 画素の検査 | しない（2.7） |
| 大きさの callback（`lastFrame` を描き直して swap） | `WebGpuWindow` の `redraw` で `WebGpuPaint.repaintLast` → `present`。中間の texture もここで作り直す（12.7: Dawn は知らせないので GLFW で受ける） |
| 起動画面（`drawSplash` → `paintFrame` → swap） | 同じ `RenderSplash.tick`・`show` に、`WebGpuPaint` で描いて `present` する `drawSplash` を渡す。絵は 3.1 の組み込みフォントとロゴ |
| `handleWindow`（`PresentState` を握り、swap・frame shot・vsync を受ける） | WebGPU 版の `handleWindow` を書く（`pollEvents`・カーソルなどは `LwjglLayer` の物と同じ式を使う。`presentFrame` が `WebGpuPaint.present`・frame shot） |
| `handleAnnotation`（`Platform.Annotation`・F8） | 何もしない handler（op は 1 回知らせて捨てる）。F8 は V1 の外 |
| `handleAudio`・`openAudio`・`closeAudio`・`handleTasks`・`handleFrameClock`・`handleLoadProgress`・`openCursors`・`LwjglInput` | そのまま使う |
| `RenderPaintHandlers` の 5 本 | `WebGpuPaint` の 5 本 |

- 隠して起動（`FLIX_GE_HIDDEN`）: 中間の texture を design の大きさで作り、**surface を作らず present もしない**（ウィンドウは GLFW の隠したウィンドウのまま）。
  `getCurrentTexture` の待ちと `IMMEDIATE` の有無に門が縛られない。frame shot は中間の texture から読む。
  `WebGpuWindow.open` は必ず surface を付ける所（`attachSurface`）まで進むので、隠した時は `WebGpuWindowLayer` が GLFW の隠したウィンドウ（`GLFW_NO_API`）を直に作り、`WebGpuWindow` を使わない。
- Retina: framebuffer の大きさで中間の texture を画素の大きさで作る。ウィンドウを見せて Retina で絵が正しく出るかは【未確認】（12.7 の残り）。段階 3 で目で見る。
- vsync: 既定は `FIFO`。`FLIX_GE_NO_VSYNC`・読み込みの間は `IMMEDIATE`（GL の `glfwSwapInterval(0)` と同じ所）。Dawn の Metal で `IMMEDIATE` が使えるかは【未確認】。
  使えなければ `FIFO` のまま 1 行知らせる（`sprite_stress` の比べが vsync に縛られるので、段階 5 の前に確かめる）。
- 1 コマの時間: `noteFrame(submitNs, swapNs)` の submit を「encoder を積み終えるまで」、swap を「`getCurrentTexture` から `present` まで」にする。画面へ出す待ちは swap 側に入る（12.7）。
- `finishAfterSwap`（Windows だけの `glFinish`）は、Windows を確かめる時（判断 9）に `onSubmittedWorkDone` で同じ事をする。V1 は Mac だけ。

### 5.2 ブラウザ（canvas）

- canvas は今の `fge-canvas` 1 つ。WebGPU を選んだ時は JS が `getContext("webgl2")` を呼ばずに `main` へ進み、6.2 の準備が全部済んでから Java が `createCanvasSurface("fge-canvas")` で `webgpu` の文脈を取る。
- 大きさ: 今の `fgeResizeCanvas`（css の大きさ × `devicePixelRatio`・`?capture` の時は design）のまま JS が canvas の大きさを持つ。Flix はコマごとに `Browser.canvasWidth/Height` を読み、
  変わっていれば surface を `configure` し直し、中間の texture を作り直す。`BrowserSurface.configure` は canvas の大きさを書くが、同じ値を書くだけなので食い違わない。
- canvas の alpha は `opaque`（今の WebGL2 の `alpha: false` と同じ）。形式は `getPreferredCanvasFormat()`。

## 6. 起動の選び分け

### 6.1 PC

- `LwjglEnv.Settings` に `backend = LwjglEnv.Backend`（`FLIX_GE_BACKEND`: 無い・`gl` → `Gl`／`webgpu` → `WebGpu`／ほか → 1 行知らせて `Gl`）。
- `LwjglLayer.withLwjgl` の頭（`glfwInit` の後・hint の前）で分ける。GL の枝は今の本文をそのまま（関数の中身を動かさない）。WebGPU の枝で落ちる所と知らせ:

| 落ちる所 | 知らせる文（1 行・stdout） | 後始末 |
|---|---|---|
| Dawn のネイティブが読めない（jar が無い・置き場の誤り） | `[backend] WebGPU を使えない: Dawn のネイティブを読めない（<理由>）— GL で起動する` | — |
| `WebGpuDevice.requestDevice` が `Err` | `[backend] WebGPU を使えない: <Err の文> — GL で起動する` | — |
| `core-features-and-limits` が無い | 同じ形 | device を `destroy` |
| ウィンドウか surface が作れない | 同じ形 | ウィンドウを壊し device を手放す |

- どこで落ちても、GL の枝へ入る前に `glfwDefaultWindowHints()` を通す（`GLFW_NO_API` の hint が残ると GL のウィンドウに context が付かない）。
  `WebGpuWindow.close` は `glfwTerminate` まで呼ぶので、落ちた後に使うと GL の枝の `glfwInit` が要る。WebGPU の枝はウィンドウを壊す時に `close` でなく `glfwDestroyWindow` だけを呼ぶ
  （`WebGpuWindow` に壊すだけの関数が無ければ、`LwjglLayer.Internal.WebGpuWindowLayer` で GLFW を直に呼ぶ）。
- 落ちる 3 つの道は、試し用の環境変数 `FLIX_GE_WEBGPU_FAIL=native|device|window` で起こせるようにする（段階 3 の門で使う。値が無ければ何もしない）。
- 選べた時も 1 行出す（`[backend] webgpu: <adapterInfo>`）。gl-capture と sprite_stress の門はこの行を見て「本当に WebGPU で撮ったか」を確かめる。

### 6.2 ブラウザ

- JS（`fgeBoot`）: `?backend=webgpu` があり `navigator.gpu` があれば、webgl2 の文脈を取らずに `main` を呼ぶ。それ以外は**今と同じ順**（webgl2 の文脈 → `main`）。
- Java（`WebLayer.withWeb` → `WebLayer.Internal.WebGpuLayer.withWeb`）: **落ちうる準備を全部 `getContext("webgpu")` より前に済ませる**。順は
  `BrowserWebGpu.open()` → `core-features-and-limits` → shader module と `getCompilationInfo`・pipeline（形式は `getPreferredCanvasFormat()` で決まるので canvas の文脈は要らない）・
  中間の texture・instance buffer を作り、`errorCount` が 0 → ここまで通ったら `createCanvasSurface("fge-canvas")`。
  どこかで落ちたら作った物を捨て、`Browser.initWebGl2()`（今の `fgeBoot` の L1496〜1500 を関数に出した物）で webgl2 の文脈を取り、GL の枝へ進む。canvas はまだ `webgpu` の文脈を持たないので取れる。
  `getContext("webgpu")` と `configure` の後で落ちた時は、同じ canvas から webgl2 は取れないので、`backend` を外した URL で `location.replace` して GL で開き直す
  （次の読み込みは `?backend=webgpu` が無いので同じ失敗を繰り返さない。親の決め事「使えない時は GL へ」を満たす）。開き直す前に理由を `console.warn` に出し、
  `sessionStorage` に 1 行残して開き直した頁の `console.warn` でももう 1 度出す。canvas を作り直す手順は入力と大きさの購読を全部付け直すことになるので取らない。
- 知らせ: `console.warn("[backend] WebGPU を使えない: <理由> — WebGL2 で起動する")`。`?capture` の `renderer` にも出る（2.7）。画面には出さない（11 章の 4）。
- `WebLayer.withProject3d` は頼まれても GL のまま起動し、同じ形で理由を知らせる（親 9 章のリリース 2 の行）。

**`fgeGl` を使う JS の関数と WebGPU の時の扱い**（`fge-web.js` に `fgeGl` は 59 か所【確・`grep -c fgeGl engine_web/js/fge-web.js`】）:

| JS の関数 | 呼ぶ所 | WebGPU の時 |
|---|---|---|
| `fgeBitmapArgb`・`fgeReadGlTextureArgb`（画像を解いて ARGB にする） | `fgeDecodeImage` ← `WebImages.waitDecode`（`WebImages.java:71`。ゲームが画像の画素を読む時・3.1 の `hasAlpha = false`） | 隠した別の canvas（`OffscreenCanvas`）の webgl2 で同じ事をする。2 つの関数に GL の文脈を引数で渡す形に直し、`fgeGl` が無い時は `fgeDecodeGl()`（初めて要った時に作る）を渡す |
| `fgeFrameDrawn`（`?capture` で `readPixels`） | `WebLayer.handleWindow.presentFrame` が毎コマ `Browser.frameDrawn()` | WebGPU の枝は `Browser.frameDrawn()` を呼ばず、2.7 の `Browser.publishCapture` を呼ぶ |
| `fgeTexImageBitmap`・`fgeTexImagePlatform`（`ImageBitmap` を GL へ） | `WebImages.texImage` ← `WebAssets.uploadImage`・`registerArrivedTextures` | 呼ばない。`BrowserWebGpu.copyImageBitmap`（3.1）。`ImageBitmap` を捨てる所（後回しの道の `markLoaded`）は同じ |
| `fgeTexImageArgbLevel`・`fgeCopyTextureLevel0`・`fgeUniformLocation`・`fgeDeleteProgram`・`fgeCheckedGl` | `WebGl2` の中だけ | 呼ばれない（`WebGl2` を作らない） |
| `webglcontextlost` の購読 | 起動の時 | 付けない。`onDeviceLost` で同じ文 |
| `fgeBoot` の webgl2 の文脈を取る所 | 起動の時 | `fgeInitWebGl2()` に出し、GL の時だけ呼ぶ |

### 6.3 書き出しは 1 つ（wasm 1 本に両方を入れる）

| 案 | wasm の大きさ | 手間 |
|---|---|---|
| A. 1 本に両方。起動で選ぶ | WebGPU の分だけ全部の 2D のゲームで増える。増え方は 2 つに分けて測る: (1) `BrowserWebGpu` と JSO の分 = 何も描かない Flix の頁を `bench-web` と同じ道で書き出し、`runBrowserWebGpu` を呼ぶ版と呼ばない版の差（段階 4 の頭で測る。参考: `bench/webgpu_check` の書き出しが丸ごと 419,903 バイト【確・main の作業場の `build/bench-web/webgpu_check/classes.wasm`】で、これには TeaVM の土台と Flix の門も入っているので、(1) はこれより小さい【推】）。(2) V1 の backend の Flix の分 = 段階 4 の終わりに rpg-starter の前後で測る。合わせて rpg-starter の 8,256,469 バイトの 4〜7%【推】 | `export-web` は変えない。JS と `withWeb` の分け目だけ |
| B. 2 本作り、JS が片方だけ読む（親 5.5） | 読む方は増えない | 書き出しの時間が倍（rpg-starter で 43 秒 → 約 86 秒【推】）・束と頁が 2 組・Go の `export-web` と ⑨ の確かめを 2 回・入口を 2 本に分ける Flix |

**A にする。** 増える分は TeaVM 0.14.1 → 0.16 の差（+4.5%）と同じくらいで、B の手間に見合わない。+10% を超えたら B を伺い直す。親 5.5 の文はリリース 2 の文書の直しの時に A へ書き換える。

A の危ない所: TeaVM の JSO が `GPUBufferUsage`・`GPUTextureUsage`・`GPUShaderStage`・`GPUMapMode`・`GPUCanvasContext` などの JS の名前を wasm を読む時（instantiate）に import していると、
WebGPU の無いブラウザで GL の道ごと読めない【未確認】。段階 4 の門で、`navigator.gpu` に加えてこれらの大域の名前も消した頁で rpg-starter を開き、WebGL2 で題名の画面まで出る事を見る。
読めなかったら、それらの名前を JS の頭で空の物に差しておく（WebGPU を選ばない限り使われない）。

### 6.4 GL の道を壊さない事の確かめ

- PC: 環境変数が無い時に通る関数は、`LwjglEnv.load` の 1 欄を除いて今と同じ。門: `make gl-capture-check`（SHA が前と同じ）・render_gl のテスト（`make sync-layers` の後に `.layers/render_gl` で）・テンプレ 3 本の `reference-check`。
- ブラウザ: クエリが無い時の JS の順は今と同じ（`fgeBitmapArgb` に文脈を引数で渡す直しだけが GL の道にも乗る）。門: `bin/fge web-capture` で rpg-starter と sound-novel-starter の題名の画面の SHA が前と同じ・`export-web` の ⑨。
- jWebGPU と Dawn のネイティブを `engine_full` に載せる（11 章の 2）ので、Studio の Maven の種（12.9 の 5）と `stage-engine` の同梱一式にも要る。確かめ: Studio の種を jWebGPU と jParser を含めて取り直す・
  `make studio-parity` が通る・Studio で新しいゲームを作って起動できる。

## 7. WGSL

### 7.1 対にする GLSL

| WGSL（`WebGpuShader`） | 対の GLSL（`RenderShader`） |
|---|---|
| `sprite`（`vs_main`・`fs_main`・`fs_multiply`） | `spriteInstancedVertexShaderSource`・`spriteInstancedFragmentShaderSource`（`multiplyBlend` は `fs_multiply` に） |
| `present`（全面の三角形で中間の texture を `textureLoad` で写す） | 対は無い（GL は既定の framebuffer へ直に描く） |

書き直しで変わる所（式は変えない）:

- **標本と微分を分岐の外へ出す。** WGSL は値で分かれる分岐（`InstFlags`）の中で `textureSample` と `fwidth` を呼べない。全部の画素で 1 回ずつ取ってから分岐で選ぶ。
  式の値は同じで、GL でも 2×2 の画素は同じ instance の中で同じ枝を通る【推】。
- **GLSL の `mod` を書き写す。** WGSL の `%` は 0 の向きに切るので、負の値（縞の `p.x - p.y`）で答えが違う。`x - y * floor(x / y)` の関数にする。
- 三項演算は `select`、`discard` は分岐の中のままでよい（微分を先に取ってある）。
- 字は `.r` を読む（`R8_UNORM` に swizzle が無い。親 7 章）。
- 試し【確】: この節の形で書いた WGSL（`build/wgsl-check/sprite.wgsl`・commit しない）を、main の `engine_full` の fpkg と Dawn で
  `createShaderModule` → `getCompilationInfo` が空・Normal と Multiply の pipeline を作って 64×64 に 2 体描き、`errorCount` が 0。
  画素: 白の上の Multiply の灰色 (0.5) が `128,128,128,255`・枠 `0,0,255,255`・地 `255,0,0,255`・斜めの縞 `0,255,0,255`
  （`cd build/wgsl-check && java --enable-native-access=ALL-UNNAMED -jar <main>/bin/flix.jar run --entrypoint WgslCheck.main`）。GL と並べて比べてはいない（段階 1 の門）。

### 7.2 色と alpha

- **sRGB は使わない。** 今の 2D は sRGB の framebuffer も `GL_FRAMEBUFFER_SRGB` も使わず、8 bit の値をそのまま書いている（2D の道に sRGB の形式も無い。`render_gl`・`engine_web` で SRGB の字が出るのは 3D の `Render3d*` と WebGPU の形式の表だけ【確・grep】）。
  WebGPU も texture・中間・画面の形式を全部 `*_UNORM`（`_SRGB` でない）にする。画面の形式が `_SRGB` しか無い端末は【未確認】（あれば GL へ落とす）。12.6 の光と色の直しは V1 の外。
  CAMetalLayer の色空間の設定が GL の既定のウィンドウと違い、目で見た色が違いうる【未確認】（門は読み戻した値で見るので崩れない。12.7 の「撮った絵には画面の色の設定が掛かる」と同じ）。
- **前乗せの alpha は使わない。** 絵は straight alpha のまま上げる（PC は解いたバイトのまま・ブラウザは `ImageBitmap` を `premultiplyAlpha: "none"` で作っていて【確・fge-web.js】、
  `copyExternalImageToTexture` も `premultipliedAlpha: false`）。blend の因子は 2.3。Multiply だけシェーダーで rgb × a（GL と同じ）。
- `hasAlpha = false` の絵: GL は RGB8 で上げるので読むと alpha は必ず 1。WebGPU は 3.1 のとおり alpha を 255 で埋めてから上げる。
- filter と address（今の値を写す）:

| 絵 | GL | WebGPU |
|---|---|---|
| project.json の絵・生成の絵 | NEAREST・REPEAT・mip 無し | sampler NEAREST・REPEAT・mip NEAREST（mip は 1 枚） |
| フォントのアトラス | LINEAR・wrap は既定（REPEAT） | LINEAR・REPEAT |
| Pass の texture | NEAREST・CLAMP_TO_EDGE | NEAREST・CLAMP_TO_EDGE |
| 1×1 の透明な黒 | — | NEAREST・REPEAT |

## 8. 門

### 8.1 GL の backend と画素を比べる

- 置き場: 新しい `bench/webgpu_v1`（Makefile と許容の表 `tolerance.tsv`）。make の入口は engine の根の `make webgpu-v1-check`（PC）と `make webgpu-v1-check-web`（ブラウザ）。GPU が要るので CI に載せない（`webgpu-check` と同じ）。
- **比べる道具**: `go/internal/compare` に置く（`readPNG`・`writePair` を同じパッケージから使う。`pixelAt` は前乗せの色を返すので使わない）。
  PNG を `image.NRGBA` に直して成分ごとの差の最大と差のある画素の数を出し、差がある時は `writePair` で差の絵も書く。入口は `fge-go pixel-diff <A> <B> [--tolerance tsv]`。
- **gl-capture**: `reset_env` に `FLIX_GE_BACKEND` を足す（呼ぶ人の環境の値で撮り分けが変わらないように）。撮り分けは明示の旗 `bin/gl-capture.sh --backend webgpu`（その時だけ `FLIX_GE_BACKEND=webgpu` を置く）。
  撮った側の起動のログに `[backend] webgpu:` の行が無ければ止める（GL へ落ちた絵を比べて緑にしない）。
  同じログに「足す字」の知らせ（3.1 で V1 は起動の後に字を足さない）が出ていない事も確かめる（出ていれば字が欠けた絵を比べている）。
- 門の順:
  1. **WebGPU どうし 2 回で同じ**（`gl-capture-check` の WebGPU 版。`--backend webgpu` で 2 回撮って SHA が同じ）。揺れがあれば GL との比べより先に分かる
  2. **GL と WebGPU**: 同じ機械で既定と `--backend webgpu` を撮り、`pixel-diff` で比べる
- 許容は場面ごとに `tolerance.tsv`（場面・許す差・理由）。既定は 0。丸めが出る所だけ 2/255:

| 場面 | 許す差 | 理由 |
|---|---|---|
| 字のある場面（rpg-starter の `title` など） | 2/255 | 字の距離場の輪郭で `fwidth` の値が経路で違いうる【推】 |
| 黒帯のある場面 | 1/255 | clear の色と箱の色の丸め（2.5）【推】。gl-capture は隠して起動で黒帯が無いので、ウィンドウを見せた目視の時だけ |
| ほか | 0 | — |

- 場面（PC）: rpg-starter の `title`（gl-capture の既定の場面から）・`bench/gl_parity` の場面（下）。
- **`bench/gl_parity` を WebGPU で流す**: 今の harness は `ViaTarget` の場面で GL の `GlReadback.readBoundPng` を直に呼び、3D と面の場面が多く、`renameFrames` は全部の場面の順で `frame-N.png` に名前を付ける。そこで:
  - 場面を選ぶ環境変数 `PARITY_SCENES=<名前,…>` を足す（無ければ全部・今と同じ）。`renameFrames` は選んだ場面の順で名前を付ける。
  - `PARITY_VIA_SCREEN=1` を足す。`ViaTarget` の場面を、GL と SoftRaster の両方で画面へ描く形（`ViaScreen`）に替える（黒で clear して design の大きさに描くので、読む絵は同じ）。WebGPU の時はこれを必ず置く。
  - V1 で流す場面: `boxes`・`spriteNearest`・`passPaste`・`radial`・`veil`・`passChain`（スプライト・箱・Pass だけの物。段階 1 で中身を見て、多角形・面・mask を含む物は外す）。
    `texField`（面）・`passMask`（mask）・`lightmap`・3D の場面は V1 の外。
  - WebGPU で流すと、GL と比べる門（上の 2）と別に、SoftRaster とも比べられる（`gl_parity` の表）。
- **ブラウザ**: `bin/fge web-capture` で `?capture=N` と `?capture=N&backend=webgpu` を同じ機械で撮り、同じ道具で比べる。`renderer` に `webgpu:` が無ければ落とす。
  ブラウザの WebGPU の絵は PC の WebGPU とも比べる（`webgpu-check-same` で三角形の digest が同じだった事の続き）。

### 8.2 `sprite_stress` の同じ絵 20,000 個

- PC: `cd bench/sprite_stress && make run TEX=1 COUNTS=20000,20000` を、GL と `FLIX_GE_BACKEND=webgpu` で **交互に 3 回ずつ**（GL・WebGPU・GL・WebGPU・GL・WebGPU）。
- ブラウザ: `make bench-web BENCH=sprite_stress ARGS='n=20000&tex=1'` と `ARGS='n=20000&tex=1&backend=webgpu'` を交互に 3 回ずつ。
- 比べる値（両方の backend で同じ区間）:
  - **frame**: 前のコマの `presentFrame` を抜けてから、次のコマの `presentFrame` を抜けるまで（PC は `bench/sprite_stress` の区間の JSON の frame・ブラウザは `bench-web` の頁が出す値。どちらも測る所が GL と WebGPU で同じ関数の前後になる事を段階 5 の頭で確かめる）
  - **cpu**: `renderCommands` に入ってから、`presentFrame` で画面へ出す待ちに入る直前まで（GL は swap の直前・WebGPU は `getCurrentTexture` の直前）
- 合格: 3 回の中央値で、WebGPU が GL の 1.05 倍以内。各 3 回の幅（最大 − 最小）も表に書き、幅が 5% より大きい時は「判定できない」として回数を増やす。
- 測る前に毎回 `pgrep -fl 'java|Chrome|flix'` で、ほかの重いプロセス（別の作業のビルド・ベンチ）が無い事を見て、結果の表に書く。重い区間の直後に測らない（熱の水増し）。
- 垂直同期を切る（PC は `FLIX_GE_NO_VSYNC=1` が `IMMEDIATE` になる事が前提。5.1 の【未確認】）。

### 8.3 GPU を呼ばない render_gl のテスト

render_gl のテスト（`.layers/render_gl`）に置くのは GPU を呼ばない物だけ: 行から draw の引数（pipeline の鍵・bind group の番号・`firstInstance`）を作る関数・scissor の式（描き先の端・幅 0・viewport の外）・
黒帯の箱の位置・viewport の y の反転。WebGPU の device を開く比べ（`WebGpuOffscreen` と `GlOffscreen`）は `bench/webgpu_v1` に置く。

## 9. 段階と見積もり

| 段階 | 中身 | 門 | 見積もり（親の物差し） |
|---|---|---|---|
| 1 | `WebGpuShader`・`RenderFrame.Internal.WebGpuRows`・`WebGpuPaint` の中核（device・pipeline・instance buffer・中間の texture・絵の表）・`Frame.flix` のコメント。`bench/webgpu_v1` に画面なしの session で `gl_parity` の箱とスプライトの場面を GL の `GlOffscreen` と比べる門。8.3 のテスト。`webgpu-check` に頂点バッファの `firstInstance` の試し | 差 0（字は 2/255）・`errorCount` 0・頂点バッファの形が 20,000 本で 3 ms 以内 | 2〜2.5 時間 |
| 2 | 3.1 の PC の読み込み・`ensureTexture`・Pass（`beginTarget`〜`endTarget`）・5 つの handler・3.2 の submit の決まりと数 | 段階 1 の門に Pass の場面と生成の絵を足す | 1.5〜2 時間 |
| 3 | PC のウィンドウ（`LwjglLayer.Internal.WebGpuWindowLayer`・選び分け・GL へ落ちる道と後始末・frame shot・起動画面・大きさの変化・vsync）。`engine_full` に Dawn のネイティブ | 8.1 の PC（WebGPU どうし → GL と）・`FLIX_GE_WEBGPU_FAIL` の 3 つで GL で起動する | 1.5〜2 時間 |
| 4 | ブラウザ（JS の分け目と `fgeGl` の表・`WebGpuLayer`・3.1 のブラウザの読み込み・`?capture`・device lost）と wasm の大きさ（6.3 の 2 つの測り方） | 8.1 のブラウザ・WebGPU の無い頁（`navigator.gpu` と `GPU*` の名前を消した頁）で WebGL2 で起動する・6.4 | 2〜2.5 時間 |
| 5 | `pixel-diff` と make の入口・`gl_parity` の場面を選ぶ旗・`sprite_stress` の PC とブラウザ・Studio の種と `studio-parity`・層を置く物差しの表・lint-forbid・レビュー役（1 回目で全部の指摘を出させ、まとめて直して 2 回目） | 8.1・8.2・6.4 の全部・レビュー 90 点 | 1.5〜2 時間 |

**親の物差しで 8.5〜11 時間**（親の V1 は 6〜9 時間）。増えた分は、読み込みの仮の道（3.1・約 1 時間）・ブラウザの `fgeGl` に寄りかかる所（6.2・約 1 時間）・`gl_parity` を選んで流す旗と比べる道具（約 0.5〜1 時間）。
直近の実績（P4a は 9〜13 時間の見積もりに対し約 3 時間・P4b は 4〜6 時間に対し約 1 時間）の割合をそのまま当てると 2.5〜4 時間になるが、V1 は触る所が広く散らばるので、**実時間は 4〜6 時間**と見る【推】。

## 10. 危ない所と逃げ道

| 危ない所 | 逃げ道 |
|---|---|
| `firstInstance` で instance の頂点バッファを引く形の代金が、試した storage buffer の形と違う | 段階 1 で測る。遅ければ storage buffer と `instance_index` に替える（WGSL の入口の差だけ） |
| `sprite_stress` で WebGPU が GL より 5% 以上遅い（ブラウザの `writeBuffer` の写し・PC の `getCurrentTexture` の待ち） | 内訳（積む・写す・出す）を取って人に伺う。門を緩めずに形のレビューの材料にする |
| 字の距離場（`fwidth`）が 2/255 を超えてずれる | 差の絵を出し、場面ごとの許容に理由を書いて人に見せる（親 11 章の 6）。式は変えない |
| 中間の texture から写す 1 枚の代金（4K の画面で毎コマ全面） | GPU の時間を見る（timestamp-query があれば）。重ければ「Pass も 3D も無いコマは画面へ直に描く」を形のレビューへ |
| Dawn の Metal に `IMMEDIATE` が無い | `FIFO` で測り、8.2 の比べを GL も vsync ありにそろえる |
| ブラウザの `copyExternalImageToTexture` が色の変換を掛ける | `ImageBitmap` は `colorSpaceConversion: "none"`。門で差が出たら、解く道（6.2 の表の 1）で ARGB にして上げる道に替える |
| `RGBA16_FLOAT` の Pass を作る 1 本の pipeline でコマが落ちる | 起動の時に作る物へ足す（6 本全部を起動で作っても、ブラウザで 0.4〜0.6 秒【推】） |
| コマの途中の submit が多いゲーム（`ensureTexture` の key が毎コマ変わり、Pass もある） | `submits` の数で見つける。多ければ P6 で staging の案（3.2）を比べる |
| wasm 1 本だと WebGPU の無いブラウザで読めない（6.3） | 段階 4 の門で見る。読めなければ JS の頭で名前を差す |

【未確認】の物: Retina の 2 倍でウィンドウに出る絵・Dawn の Metal の `IMMEDIATE`・Dawn の device lost の callback・画面の形式が `_SRGB` だけの端末・CAMetalLayer の色空間で目で見た色・
`presentFrame` の中で `mapAsync` を待ってよいか（2.7）・JSO の `GPU*` の名前の import（6.3）・Safari と iPhone・Windows と Linux（判断 9）・WebGPU の無いブラウザで WebGL2 版が起動する事（段階 4 で名前を消した頁で代える）・
TeaVM がコマの途中で手を返した時の中間の texture の扱い（親 5.4 の理由をそのまま信じている）。

## 11. 決めた事（第 1 版の「伺う事」を、おすすめの案で進めると決めた）

1. **Pass のお題**: `bench/gl_parity` の `passPaste` など（8.1 の場面）で代える。rpg-starter は題名の画面だけ。engine に「本編を Pass 1 枚に通す」開発用の環境変数を足す案は、R1b ⇄ P6（history と MSAA で Pass の場面が増える所）で改めて伺う。
2. **Dawn のネイティブ**: V1 で `engine_full/flix.toml` に macOS arm64 だけ足す（全部のゲームの配る物が Mac で 2.6 MB 増える。Windows・Linux はリリース 2）。`engine_full/flix.toml` の WhyNot（選べないうちは載せない）を外す。Studio の種と同梱一式も合わせる（6.4）。
3. **PC で 3D を使うゲームが webgpu を付けた時**: 場面を描かずに 1 回知らせる（遊べるが 3D が欠ける）。リリース 2 の文「入口が 3D のゲームは GL のまま」を PC でどう満たすかは、リリース 2 の前に決める。
4. **GL へ落ちた理由の出し方**: PC は stdout の 1 行、ブラウザは console と `?capture` の `renderer`。画面（頁）には出さない。リリース 2 で既定を替える前に見直す。

## 12. 形のレビュー（2D）への持ち越し（V1 では作り替えない）

1. 描き先の上下を `targetNames` で知らせている（V1 は空の Set を渡して済ませた）→ 前半が backend に聞く capability（親 5.3）。
2. `RenderList` の instance の番号が `renderCommands` ごとに 0 から → WebGPU はコマで 1 本の buffer の位置を足している。前半がコマで 1 本の入れ物に書く形か、行に起点を持つか。
3. run の状態の配列 `st` に GL の物（program・VAO・buffer の番号・欄 0〜6 と 26）と前半の run の状態と draw の数が同居している → 分ける。
   実装: WebGpuRows.renderFrame は draw の数えの欄 28・30 の初めの値を renderFrameMixed から書き写している（分けた時に 1 か所へ）。
4. `RenderBuf` が `gl.allocFloats` で入れ物を作る → instance の入れ物の持ち主を backend にするか、前半にするか（バイト順は 3.3）。
5. `RenderPaint` と `WebGpuPaint` の重なり（登録簿・`ensureTexture` の key・描き先の表・溜めた面と場面・`lastFrame`）→ CPU の側の表を前半へ（親 R1b の寿命の表）。
6. 読み込みが `GlContext` を受ける（`AssetLoader`・`LwjglAssets.loadTexture`・`RenderFont.bakeFontAtlases`・`RenderGlyphGrow.ensure`・`RenderSplash.install`・`loadAssets` の `RadialBuiltin`・`WebAssets.uploadImageOf`）→
   V1 の仮の道（3.1）を、「上げる行」か上げる API の小さな record にまとめる。PC で起動の後に字を足す道（`RenderGlyphGrow.growOne` の GL の呼び出し）もここで分ける。
7. 画面の clear（黒帯と `clearColor`）が `renderFrameMixed` の中の GL の呼び出しで、行になっていない → pass の区切りの行に clear を持たせる。
8. pipeline の鍵の半分（描き先の形式）は pass の性質で、行は blend だけを持つ。今の形で足りるかを 3D の前に見る。
9. mask つきスプライトが GL を直に呼ぶ（`drawMaskedOne`）→ 行の種類にする（親 8 章の stencil の ref を進める形）。
10. Pass の history の写し（`copyTo`）が行にも `WebGpu` にも無い → pass の区切りの行に「前のコマを写す」を持たせ、`WebGpu` に texture の写しを足す。
11. 1 回の `renderCommands` ごとに流し、submit はコマの終わり → コマの途中の上げ物の前に submit する決まり（3.2）を、「上げる行」を列に入れる形と staging の形と比べる（親 9.1 の「いつ流すか」）。
12. instance を頂点バッファで読むか、storage buffer と `instance_index` で読むか（2.1）。draw ごとの値（面・材質）を入れる時にどちらにそろえるか。
13. 字の絵だけシェーダーが読む成分が違う（GL は swizzle で `.a`・WebGPU は `.r`）→ 絵の種類を行か表に持つか。 実装: 字の絵は R8 で上げて `.r` を読み、bench/webgpu_v1 の字の場面は GL と 0 px（許容の 2/255 は使わなかった）。
14. 絵ごとの filter と address を表の番号の裏（bind group）に持たせた → 行は番号だけでよいか。アトラスの頁（親 6.1 の 3）にした時の sampler の持ち方。
15. 中間の texture へ描いてから画面へ写す 1 枚 → Pass も 3D も無いコマで省くか（10 章）。
16. ブラウザで画像を解く所（`fgeBitmapArgb`）と `?capture`（`fgeFrameDrawn`）が WebGL2 に寄りかかる → V1 は隠した canvas の webgl2 と `publishCapture` で逃げた（6.2）。WebGPU の側で解く・読む形にするか（WebGL2 の無いブラウザは WebGPU も無いので急がない）。
17. 1 コマの submit の回数を engine の pub の `FrameDiagnostics` に出すか（V1 は `FLIX_GE_FRAME_STATS` だけ。3.2）。
18. bench が engine の fpkg（mount = "fge"）では `RenderPaint.Internal.WebGpuPaint` を呼べない（`mod RenderPaint` が pub でない）→ `RenderPaint` を pub にするか、
    bench/webgpu_v1 の木（engine_full/src と bench の src をファイルごとの symlink で 1 つのパッケージにする形）のままにするか。
19. `copyImageBitmap` は一時の texture へ写してから読み戻す（WebGpuPaint に外で作った texture を載せる口が無い）→ 絵の表に texture を載せる口を足して、読み戻しを省くか。
20. WebGPU の窓の診断に `swapNs` と GPU の時間を足していない（`noteFrame` の pub が無い）。`FLIX_GE_FRAME_STATS` の行の終わりの `submits` だけ。
21. （済み）PC の `glyphs=auto` のゲームは、WebGPU の枝の中だけ used として起動の時に字を用意する（V1 は起動の後に字を足さない）。
22. （済み）Pass の history（`<名前>@history`）のスプライトは WebGpuRows が「Pass の history」として 1 回知らせて描かない。
23. `make gl-capture-check` の基準（bench/baseline/0.88.4）と sound-novel・tidepool・scene3d の 5 場面・30 枚が違う。V1 の前の engine（設計だけの fef4a2da を
    `git archive` して撮った 54 枚）は今の engine の 54 枚とバイトまで同じで、同じ 30 枚が基準と違うので、V1 の外。基準の撮り直しは人の判断。
24. **【リリースの前に必須】** Studio の Maven の種（flix_ge_studio の server/lib・`--maven-seed`）に jWebGPU（webgpu-desktop-jni・webgpu-jni・jParser の runtime）と
    Dawn の macOS arm64 のネイティブが無い。engine_full/flix.toml が求めるので、手元のキャッシュに無い機械で新しいゲームを作ると Maven から取りに行く。
    Studio のリポジトリで、server/flix.toml の engine を今の版へ上げて server/lib を取り直し、`make studio-parity` を通す（別のリポジトリの作業。V1 では手順だけ）。
    `make studio-parity` は Studio の clone へ git の操作をするので、この作業場からは流していない。
25. `make lint-huge-methods` は ShaderGen.hashMaterial・hashOptField・SoftRaster3d.renderLayer の 3 件で落ちる。V1 の前の engine（fef4a2da）の
    bench/scene3d の jar でも同じ 3 件が出るので V1 の外。V1 で増えた withGl・runWindow は起動の時に 1 回だけ通るので exempt に載せた。
26. 早見表（agents-pack/AGENTS.core.md）と agent-eval のお題は、既定が GL の間（リリース 2 まで）は載せない（P4a と同じ扱い。ゲームが WebGPU を選ぶ口がまだ開発用の環境変数だけのため）。
27. ブラウザの device lost は `BrowserWebGpu.onDeviceLost` で受けて頁に案内を出す。PC は Dawn の device lost の callback を jWebGPU から取れるかを確かめておらず、
    受けていない。代わりに WebGpuWindowLayer が画面へ出したコマごとに誤りの数を見て、増えたら最後の誤りの文を 1 行出す。

## 実装で分かった事（段階 1〜5・2026-11-15）

commit: 段階 1 `4aff67b0`・段階 2 `6eee79e1`・段階 3 `92205618`・段階 4 `d5a5398f`・段階 5 `1a0aea3a` と、その後の文書と測りの commit。

### 設計と食い違った所

| 所 | 設計 | 実装 | 理由 |
|---|---|---|---|
| bench/webgpu_v1 の組み方 | flix.toml で engine の fpkg に依存 | engine_full/src と bench の src をファイルごとの symlink で 1 つのパッケージの木（build/tree）に束ね、fat jar を起こす | `mod RenderPaint` が pub でなく、子の `RenderPaint.Internal.WebGpuPaint` は別のパッケージから見えない（E2544）。engine の pub を増やさないため。フォルダの symlink だと flix は中を探さず緑を返す |
| PC の読み込みの置き場の確かめ | — | bench は `LwjglLayer.Internal.WebGpuWindowLayer` の子孫の mod（bench/webgpu_v1/src/LwjglLayer/Internal/WebGpuWindowLayer/V1Assets.flix）から窓の読み込みを呼ぶ | 写すと、窓の読み込みが崩れても門が緑のままになる |
| `WebGpuWindow.open` | WebGPU の枝はこれでウィンドウを開く | `WebGpuWindowLayer` が GLFW と `createMacSurface` を直に呼ぶ | `open` は隠した時も surface まで作り、`close` は `glfwTerminate` まで呼び、入力に要る GLFW のウィンドウの番号を外へ出さない |
| `copyImageBitmap` | 描く絵の texture へ直に写す | 一時の texture へ写してから読み戻し、RGBA を `WebGpuPaint.uploadRgba` で上げる。`hasAlpha=false` も同じ道で alpha を 255 で埋める | WebGpuPaint の絵の表に外で作った texture を載せる口が無く、足すと 0 章に無い pub が要る（12 章の 19） |
| `?capture` の origin | `"top-left"` | `"bottom-left"`（GL の頁と同じ形）。canvas は opaque なので alpha は 1 で置く | web-capture はどちらも読める。alpha を 1 にしたので WebGL2 の頁と SHA まで同じになる |
| 黒帯の箱の instance の位置 | 行の instance より前 | 行の instance の後ろに書き、draw は行より先に出す | 描く順が同じなので絵は同じ |
| WebGpuRows の `setPipeline`・`setTexture` | 番号だけを受ける | `(RenderPass, 番号)` を受ける | pass は `openPass` の後にしか無い |
| 起動の選び分けの関数 | — | `withGl`・`withWebGpuOrGl`・`withWindow`・`runWindow`（と WebLayer の対）に `@DontInline` | 付けないと rpg-starter の main の閉包が `MethodTooLargeException` で組めなかった |
| `Browser.initWebGl2` | 引数無し | 理由を受け、webgpu の文脈を取った後なら頁を開き直して偽を返す | GL へ落ちる道の 1 本で、取る前と取った後の両方を受ける |
| ブラウザの WGSL の確かめ | 準備で shader module の `getCompilationInfo` を見る | 見ていない。準備の終わりに `errorCount` が 0 かだけを見る（WGSL は PC の Dawn で組める事を門が見ている） | `WebGpuPaint` は shader module を外へ出さず、`create` の中で pipeline まで作る |
| PC の誤りの知らせ | — | 画面へ出したコマごとに `errorCount` を見て、増えたら `lastError` を 1 行出す | device lost を受けられないので（12 章の 27） |
| gl_parity の WebGPU の scene | passChain も | boxes・spriteNearest・passPaste・radial・veil の 5 つ | passChain は面（ShaderDoc）を使う |

### 測った数字

- 画面なしの比べ（bench/webgpu_v1・9 場面）: 全部 0 px（字の許容 2/255 も使わず）・WebGPU の誤り 0・submit は Pass の後に生成の絵を書き替える場面だけ 2・ほかは 1。
- 実機の窓（隠して起動・rpg-starter の title）: WebGPU どうし 2 回で 6 枚とも同じ SHA・GLYPHS=used の GL と 6 枚とも 0 px。窓を見せた起動（768x720）でも GL と frame shot の SHA が同じ。
- gl_parity の V1 の 5 scene: WebGPU と SoftRaster・WebGPU と GL とも 0 px。
- `make webgpu`（`PARITY_VIA_SCREEN=1`）を回した後も、git に入っている `bench/gl_parity/debug/soft/*.items.tsv` は書き替わらない（`git status bench/gl_parity/debug/soft` が clean・2026-11-15）。
- ブラウザ（Chrome 156）: rpg-starter の title で WebGL2 と WebGPU が 0 px（SHA も同じ）。PC の WebGPU とは 22 px・±1（PC の GL とブラウザの GL でも同じ 22 px・±1）。WebGPU の無い頁は WebGL2 で同じ絵。
- firstInstance と instance の頂点バッファで 20,000 本: PC の CPU の中央値 1.45 ms（storage の形と同じ）・ブラウザ 0.8 ms。
- sprite_stress の同じ絵 20,000 個（bench/sprite_stress/RESULTS.md の節）: PC は WebGPU / GL が frame 0.89 倍・submit 0.94 倍（WebGpuRows の欄の読み方を直した後。直す前は submit 1.28 倍）。ブラウザは submit 1.04 倍・cpu 1.02 倍。
- 1 コマの submit: sprite_stress 1・rpg-starter の title 1。
- wasm: 何も描かない頁で `runBrowserWebGpu` を呼ぶ版が +38,817 バイト。rpg-starter 8,259,097 → 8,823,006 バイト（+6.8%）・sound-novel-starter +8.3%。
- 書き出しは同じ 1 本（6.3 の A）のまま。WebGPU の無い頁でも wasm を読めた（JSO の `GPU*` の名前は読む時に要らない）。

### 確かめていない事（V1 の終わり）

Retina の 2 倍の窓（この機械では窓が等倍の表示に出た）・窓を見せた時に画面に出た絵そのもの（読み戻した frame shot は見た）・大きさを変えた時の描き直し・
Dawn の Metal の IMMEDIATE が本当に待たないか（configure の誤りは出ない）・本物の「Dawn のネイティブを読めない」（`FLIX_GE_WEBGPU_FAIL=native` で起こしただけ）・
ブラウザで webgpu の文脈を取った後に落ちて開き直す道と、取る前に落ちて GL へ入る道（わざと起こす口が無い）・device lost・
ブラウザで `hasAlpha=false` の絵を描いた時の画素・Safari と iPhone・Windows と Linux。


## 第 1 版のレビュー（78 点）への対応

| 指摘 | 入れた所 |
|---|---|
| A1 絵とフォントを上げる道が無い | 3.1 の表（読み込む物ごと・共有する pub・増える pub・行数）。起動の後の字は V1 では足さない。12 章の 6 |
| A2 `fge-web.js` の `fgeGl` 依存 | 6.2 の表。画像を解くのは隠した canvas の webgl2・`?capture` は `publishCapture`。12 章の 16 |
| A3 `getContext('webgpu')` の後に落ちる | 6.2: 落ちうる準備を全部その前に。後で落ちたら GL へ戻さず案内 |
| A4 バイト順 | 3.3 |
| A5 GPU の比べを render_gl のテストに置かない | 8.1 の `bench/webgpu_v1`・8.3・9 章の段階 1 |
| A6 `gl_parity` を WebGPU で流せない | 8.1 の `PARITY_SCENES`・`PARITY_VIA_SCREEN` と V1 の場面 |
| 1 scissor の外 | 2.6・2 章の 4 |
| 2 submit の一覧 | 3.2 |
| 3 submit の値段と 3 案・数 | 3.2・12 章の 17 |
| 4 `GPU*` の名前 | 6.3・10 章 |
| 5 wasm の根拠 | 6.3 の 2 つの測り方（今回は測っていない） |
| 6 `LwjglLayer` の WebGPU の範囲 | 5.1 の表・1.1 |
| 7 GLFW の後始末 | 6.1 |
| 8 `hasAlpha = false` と usage | 3.1・7.2 |
| 9 門の (a)〜(d) | 8.1 |
| 10 名前 | 0 章・1 章・1.1 |
| 11 `Frame.flix` の WhyNot と物差しの表 | 1.3・1.2 |
| 12 属性は 10 本 | 2.1 |
| 13 黒帯の箱と丸め | 2.5・8.1 の許容の表 |
| 14 Studio の種 | 6.4・11 章の 2 |
| 15 1.05 倍の判定 | 8.2 |
| 16 `?capture` の順と 256 | 2.7 |
| 17 見積もり | 9 章 |
| 好み 4 件 | 2.4（`textureLoad`）・7.2（CAMetalLayer）・6.1（`FLIX_GE_WEBGPU_FAIL`）・2.7（main スレッド） |
