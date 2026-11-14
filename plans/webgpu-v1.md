# WebGPU 移行の段階 V1（縦に 1 本・2D）— 設計（第 1 版・未レビュー・未着手）

親の文書は `plans/engine-webgpu.md`（以下「親」。章の番号は親の物）。V1 の中身は親の 9 章の表の V1 の行と、P4b から回した「起動の時の選び分け」（親 5.5・12.12）。
【確】= コードか手元の試しで確かめた ／【推】= 読みや割り算からの見積もり ／【未確認】= まだ確かめていない。

## 0. 何を作るか（範囲）

- WebGPU の backend に、2D のスプライト・字・箱（今の 1 本の instanced のプログラム）と、それに要る最小の物: 絵とフォントのアトラスを上げる・Pass を 1 つ挟む・画面へ出す。
- お題: rpg-starter の題名の画面（親 9 章: スプライト 7 個だけ・多角形と面が無い）と、それを Pass 1 つに通した物（形は 11 章の伺う事 1）。PC とブラウザで出す。
- 選び分け: 既定は GL のまま（リリース 2 まで）。PC は `FLIX_GE_BACKEND=webgpu`、ブラウザは `?backend=webgpu`。使えない時は理由を 1 行知らせて GL で起動する。
- **V1 で描かない物**（WebGPU を選んだ時だけ。名前ごとに初めの 1 回だけ知らせて描かない）: 多角形・タイルの層・static layer・面（`ShaderDoc`）・3D の場面・mask つきスプライト・Pass の history（`<名前>@prev`）・MSAA（標本 2 以上は 1 で描いて知らせる）・F8 の注釈。どれも親 9 章の R1b ⇄ P6 以降の物。
- **V1 で変えない物**: `RenderFrame`（`Frame.flix`）の中身・`RenderList` の形・GL の backend の流し方・engine の pub・`render_gl/java`（GL の層の jar のハッシュを動かさない。12.9 の 8 の直しも V1 ではしない）。

## 1. 置き場とモジュールの分け方

| 新しい物 | 置き場 | 中身 |
|---|---|---|
| `RenderFrame.WebGpu` | `render_gl/src/RenderFrame/WebGpu.flix`（`pub mod`） | 1 回の `renderCommands` を、GL と同じ前半（`mergedByZ` → `emitSprite` が `RenderList` を作る）で行にし、行を WebGPU の render pass へ流す |
| `WebGpuShader` | `render_gl/src/WebGpuShader.flix` | WGSL の字（スプライト・字・箱を 1 本、画面へ写す 1 本）。`RenderShader`（GLSL）と対 |
| `WebGpuPaint` | `render_gl/src/WebGpuPaint.flix` | `RenderPaint` の V1 の分: device・pipeline・buffer・絵の表・描き先・1 コマの encoder・画面へ出す |
| `WebGpuPaintHandlers` | `render_gl/src/WebGpuPaintHandlers.flix` | `RenderPaintHandlers` と同じ 5 つの handler（Draw2d・Draw3d・GpuResources・Diagnostics・Target）を `WebGpuPaint` で受ける |
| `LwjglLayer.WebGpu` | `render_gl/src/LwjglLayer/WebGpu.flix`（`pub mod`） | PC のウィンドウの WebGPU 版（`WebGpuWindow` の上）。音・入力・仕事・時計・読み込みの知らせは `LwjglLayer` の物をそのまま使う |
| ブラウザの分 | `engine_web/src/WebLayer.flix` の `withWeb` の中で分ける・`engine_web/java/fge/web/webgpu/BrowserWebGpu.java` に 3 つ足す・`engine_web/js/fge-web.js` | 6.2・2.7・3 章 |

- **前半は共有し、GL の物とは混ぜない。** 前半の `mergedByZ`・`emitSprite`・`pushSpriteKeyed`・`writeInstAt`・`closeSpriteRun`・`calcViewport`・`DrawCmd.clipPixels` と
  `RenderList` は pub でない。Flix 0.78 では**子の mod から親の pub でない物が見える**ので（下の試し）、WebGPU の流し方を `RenderFrame` の子に置けば、
  `RenderFrame` の pub を 1 つも増やさず、`Frame.flix`（1,162 行。上限 1,200 行）にも足さずに済む。増える pub は子の入口 1 つ（`RenderFrame.WebGpu.renderFrame`）。
  - 試し【確】: `build/vis-test`（commit しない）で、`src/Outer.flix` の `mod Outer` の pub でない `type alias` と `def` を、
    `src/Outer/Child.flix` の `pub mod Outer.Child` から呼んで `42` が出た（`java -jar bin/flix.jar run`・Flix 0.78.0）。
    子を `pub` でない `mod` にすると「inaccessible module」、ファイル名が mod 名と合わないと「unexpected location」で止まる。
- **新しい抽象（trait・関数の record・backend の enum）は足さない。** GL と WebGPU の選び分けは、入口が差す handler の組（`RenderPaintHandlers` か
  `WebGpuPaintHandlers`）だけで決まる。`Fs`・`WebGpuDevice` と同じ形で、境目は今ある `Platform.Services` の handler 一式（実装 3 つ: 実機・ブラウザ・画面なし）。
  `RenderList` は 2 つの流し方（GL の `drawRow`・WebGPU）が読む**値**で、interface ではない。「層を置く物差し」に照らして、2 つ目の実装が無い層は増えない。
- `RenderPaint` との重なり（登録簿・`ensureTexture` の key・描き先の表・溜めた面と場面・`lastFrame`）は V1 では写す（約 300 行の見込み【推】）。
  1 本にまとめるのは親の R1b の「物の上げ下ろしと寿命の表」（12 章の持ち越し 5）。V1 で先にまとめると GL の道を触ることになる。
- 置き場を render_gl にするのは親 11 章の 7（パッケージは分けない）と同じ。ブラウザの書き出しに Dawn は入らない（`WebGpuPaint` が使うのは `fge.webgpu.WebGpu` だけで、
  Dawn を名指すのは `LwjglLayer.WebGpu` と `WebGpuDevice.runDawn`）。

## 2. 1 コマの流れ（`RenderList` の行 → WebGPU）

1 回の `Draw2d.renderCommands` を、今の GL と同じく**その場で**流す（親 5.1）。違いは「submit はコマの終わりに 1 回」だけ。

1. `WebGpuPaint` はコマの最初の `renderCommands` で `CommandEncoder` を 1 つ作り、コマの終わり（`Window.presentFrame`）まで持つ。
2. 描き先（Pass が開いていればその texture・無ければ中間の texture。2.4）に render pass を 1 つ開く。clear は 2.5。
3. `mergedByZ` で並べ、`MSprite`（mask 無し）だけ `emitSprite` で `RenderList` へ積む。ほかの種類は知らせて飛ばす（0 章）。
   `targetNames` には空の Set を渡す（2.6）。
4. 行を流す: `instances` の使った範囲を、コマで 1 本の instance buffer の「このコマで次に空いている位置」へ `writeBuffer` 1 回で送り、行ごとに下を積む。
   - pipeline: blend（行の欄 4）× 描き先の形式で引く（2.3）。前の行と同じなら積まない。
   - 絵: 行の欄 3（`textureId`）→ 絵の表 → bind group（group 1）。0（絵の無い箱）は前の bind group のままでよい（シェーダーは読むが使わない。pass の頭で 1×1 の透明な黒を付けておく）。前と同じなら積まない。
   - clip: 欄 5〜9 → `setScissorRect`（2.6）。
   - `draw(6, count, 0, base + first)`。`base` は 4 で送った位置（instance の番号）。
   - draw の数は今の `countSpriteDraw`（子から呼べる）で数える。診断の数は GL と同じ物差し。
5. render pass を閉じる（`end`）。submit しない。
6. `presentFrame` で、中間の texture を画面の texture へ写す pass を積み、`finish`・`submit`・`present`。

### 2.1 instance の 38 float は、そのまま instance の頂点バッファに上げる

- GL と同じ並び（stride 152 バイト・location 1〜10）を `vertexBuffer(152, perInstance = true)` で読む。`RenderList` の `instances` を詰め替えない。
- `firstInstance` は instance の頂点バッファの読み始めにも反映される（WebGPU の決まり。indirect でない `draw` は機能を求めない）。12.7・12.12 の 20,000 本の試しは storage buffer と
  `instance_index` で引く形だったが、draw を続けて呼ぶ代金は同じ形【推】。V1 の門（`sprite_stress`）で測る。
- storage buffer にしない理由: 並びが GL と同じなので WGSL と GLSL を 1 行ずつ対で読め、門で差が出た時に追いやすい。頂点の属性は 11 本（上限の既定 16）、
  頂点バッファは 1 本（既定 8）、頂点と塗りの間の値は vec4 8 本（既定 16）で、上限に当たらない。draw ごとの値を行に入れる形（親 6.1 の 1）は面と材質（P5・P6）の物で、
  そこで storage buffer に替えるかは形のレビューで決める（12 章の持ち越し 12）。
- 四角の 6 頂点は WGSL の定数の配列にし、`vertex_index` で引く（値は `RenderSprite.initSpriteRenderer` と同じ。頂点バッファを 1 本減らす）。

### 2.2 bind group

| group | 中身 | 作り直す時 |
|---|---|---|
| 0 | 射影の行列（uniform・64 バイト） | 作らない。design の大きさは起動で決まる（GL も `setProjectionMatrix` を起動で 1 回） |
| 1 | 絵の view と sampler | 絵を作った時に 1 つ。`ensureTexture` で大きさが同じなら texture も bind group もそのまま（`writeTexture` だけ） |

group を 3 つに分ける形（親 6.1 の 2）は、行のバッファを storage にする時の物。V1 は頂点バッファなので 2 つ。

### 2.3 pipeline

- 鍵 = blend（Normal・Add・Multiply）× 描き先の形式（`RGBA8_UNORM`・`RGBA16_FLOAT`）。最大 6 本。ほかに画面へ写す 1 本（画面の形式ごと）。
- blend は `glBlendFunc`（色と alpha で同じ因子）と同じにする: Normal = (src-alpha, one-minus-src-alpha)・Add = (src-alpha, one)・Multiply = (dst, one-minus-src-alpha)。
  alpha の成分にも同じ因子を書く（2D の道は `blendFuncSeparate` を使わない。使うのは 3D の `Render3d` だけ）。Pass の texture の alpha まで GL と同じになる。
- Multiply の「rgb × a」（GL は uniform `multiplyBlend`）は、同じ module の 2 つ目の入口 `fs_multiply` にする。Multiply の pipeline はこちらを指す。
- 作る時: `RGBA8_UNORM` の 3 本と画面へ写す 1 本は起動の時（起動画面より前）。`RGBA16_FLOAT` は初めて要る Pass で作る。
  ブラウザで 1 本 65〜93 ms（親 4.3 の試作で、作り終わるまで待った値）。V1 の `WebGpu` は同期の `createRenderPipeline` だけで、ブラウザの同期版は
  すぐ返って最初の draw で待つ【推】。起動で作る分は起動画面の間に済む。コマの途中の 1 本（Rgba16Float の Pass）で 1 コマ落ちうるのは V1 では認める（親 8 章の async は P6）。

### 2.4 render pass の切り方（親 5.4）

- **画面へは直に描かない。** コマは中間の texture（`RGBA8_UNORM`・描き先の画素の大きさ・`RENDER_ATTACHMENT | TEXTURE_BINDING | COPY_SRC`）へ描き、
  `presentFrame` で 1 回だけ画面の texture へ写す（全面の三角形 1 枚・NEAREST）。理由:
  - ブラウザ: TeaVM はコマの途中で手を返すことがあり、`getCurrentTexture` はそこで切れる（親 5.4）。
  - PC: 画面へ出す待ちは `getCurrentTexture` で起きる（12.7）。最後に 1 回だけ取れば、待ちはコマの CPU の仕事の後ろに 1 か所で寄る。
  - 画面の形式（Mac の Dawn・Chrome とも `BGRA8_UNORM` の見込み【推】）と pipeline の形式を切り離せる。F8・frame shot・`?capture` は中間の texture から読む（2.7）。
- `renderCommands` 1 回 = render pass 1 つ。Pass（`beginTarget`〜`endTarget` の間の `renderCommands`）は、その texture への別の render pass。
- 同じ texture を描き先と絵の両方に使う行は、WebGPU では pass 全体が検証の誤りで落ちる（GL は結果が決まらないだけ）。その行は飛ばして 1 回知らせる。

### 2.5 clear

- 画面: render pass の load を (0, 0, 0, 1) の clear にし、design の矩形を `clearColor`（alpha 1）で塗る。黒帯が無い時（矩形 = 描き先の全面。画面なしと gl-capture はいつもこれ）は
  load の clear の色を `clearColor` にして終わり。黒帯がある時は、箱 1 個（Normal・alpha 1。結果は src そのもの）を instance の頭に書いて最初に描く。
- Pass: `LoadOp.Clear(c)` → (c, 1)・`ClearTransparent` → (0, 0, 0, 0)・`Keep` → load。GL と同じく `renderCommands` のたびに op を効かせる。

### 2.6 座標と clip

- 射影の行列は GL の物（`RenderShader.setProjectionMatrix`）をそのまま使う。z は 0 なので clip の z の範囲（0〜1）の違いは出ない。clip の y は GL と同じく上向き。
- viewport: `calcViewport` の (vpX, vpY, vpW, vpH) は GL の左下が原点。WebGPU は左上が原点なので `setViewport(vpX, fbH - vpY - vpH, vpW, vpH, 0, 1)`。
- scissor: 行の clip 矩形（viewport の左上が原点）を viewport と交わしてから、`(vpX + cx0, (fbH - vpY - vpH) + cy0, w, h)`。clip が無い行は描き先の全面。
  `setScissorAt` の交わし方（0 以下の幅は何も描かない）は同じ式を子で書く。
- **描き先の texture の上下**: GL の Pass の texture は下の行が先なので、前半は `targetNames` にある絵の uv を上下に返す（`targetUvFlipped`）。
  WebGPU の texture は上の行が先なので返さない。V1 は `targetNames` に空の Set を渡して済ませる（`emitSprite` で `targetNames` を読むのはここだけ【確】）。
  前半が backend に「描き先は上下逆か」を聞く形（親 5.3）は形のレビューへ（12 章の持ち越し 1）。

### 2.7 読み戻し（V1 は frame shot と `?capture` だけ）

- PC: `FLIX_GE_FRAME_SHOT` は `presentFrame` の中で、中間の texture を `copyTextureToBuffer` → `readBuffer`（Dawn は待って返す）→ PNG。GL の `frameShot` と同じ名前・同じ枚数の上限。
  行は上が先なので、GL の `readBoundPng`（下が先）と同じ向きの PNG にそろえる。
- ブラウザ: `window.fgeCapture()` に、n コマ目の中間の texture を読んだ物を置く（`origin: "top-left"`。`docs/web-capture.md` の約束のまま）。`renderer` には `"webgpu: <adapter>"` を入れる（8.1 の門が「本当に WebGPU で描いたか」を見る）。
  ブラウザの読み戻しは `mapAsync` を待つ（`BrowserWebGpu.readBuffer` は main の糸の上で `await`。`?capture` の時はコマが止まってよい）。
- F8 の注釈・隠して起動した時の隅の 1 画素の検査は V1 ではしない（WebGPU は中間の texture を design の大きさで作るので、隅の検査が守っていた「drawable が design に届かない」は起きない）。

## 3. 物の寿命

| 物 | 作る | 差し替え・伸ばす | 捨てる |
|---|---|---|---|
| 絵（project.json の textures） | PC: 今の読み込みで解いたバイトを `RGBA8_UNORM` へ `writeTexture`（RGB の 3 バイトの絵は解く所で 4 バイトに頼む）。ブラウザ: 解いた `ImageBitmap` を `copyExternalImageToTexture`（`premultipliedAlpha: false`）。sampler は NEAREST・REPEAT（`RenderTexture.uploadBytes` と同じ） | — | 終わる時 |
| 生成の絵（`ensureTexture`・ARGB の int） | `BGRA8_UNORM`。ARGB の int を little-endian で並べたバイトは B・G・R・A なので、詰め替えずに `writeTexture` できる。NEAREST・REPEAT | 大きさが同じなら `writeTexture` だけ・違えば作り直し（古い方は `destroy`）。key が同じなら何もしない（今と同じ） | 同左 |
| フォントのアトラス（距離場・1 画素 1 バイト） | `R8_UNORM`・LINEAR・REPEAT（GL は wrap を指定せず既定の REPEAT）。シェーダーは `.r` を読む（GL は swizzle で `.a`） | 字が増えた時は増えた行だけ `writeTexture`（`GlyphGrow` の CPU の側を共有し、上げる所だけ WebGPU 版にする。分け方は段階 2 で決める） | — |
| Pass の texture | `beginTarget` で（形式・大きさが変われば作り直す）。NEAREST・CLAMP_TO_EDGE（`RenderTargetGl` と同じ）。登録簿には design の大きさで載せる（今と同じ） | — | 作り直す時 |
| 中間の texture | 起動の時 | 描き先の画素の大きさが変わった時に作り直す | 同左 |
| instance buffer | 起動の時（`4096 × 152` バイト。GL の `RenderBuf` の初めの大きさと同じ） | 足りなければ倍に。**コマの途中で伸ばす時は、先にそのコマの encoder を submit してから**作り直す（積んだ pass が古い buffer を指したまま submit すると誤り） | 古い方は submit の後に `destroy`（WebGPU は GPU が使い終わるまで実体を残す） |
| pipeline・sampler・layout | 起動の時（2.3） | — | 終わる時に `release` |

- **コマの途中の上げ物の順**: GL は描いたそばから GPU へ行くので、Pass A を描いた後に `ensureTexture` で絵を替えても A は古い絵で描かれる。
  WebGPU は submit がコマの終わりなので、そのままだと A も新しい絵で描かれる。**そのコマに積んだ pass があれば、上げる前に submit する**（`writeTexture`・絵を作る・buffer を伸ばす の前）。
  まれな事なので代金は小さい【推】。
- instance の入れ物（CPU の側）: GL の `RenderBuf` は `gl.allocFloats` で作るので使えない。`WebGpuPaint` が `ByteBuffer.allocateDirect` と、その `asFloatBuffer()` の組を持ち、
  `writeInstAt` は float の方へ、`writeBuffer` はバイトの方を渡す（12 章の持ち越し 4）。
- **device lost**: PC は理由を 1 行出して終わる（コマの途中で GL へ移るには絵を全部上げ直すことになり、V1 ではしない）。ブラウザは今の `webglcontextlost` と同じ文で頁の読み直しを案内する（親 3 章の決め事のまま）。
  `device.lost` を受ける口は `BrowserWebGpu` に足す（JSO の `lost` の Promise）。Dawn の device lost の callback が jWebGPU で取れるかは【未確認】（取れなければ submit の誤りの数で気づく）。

## 4. Pass を 1 つ挟む

今の GL の Pass（`RenderPaint.beginTarget`・`submitFrame` の `Some(target)` の枝・`endTarget`）と同じ順で受ける。

1. `beginTarget(spec)`: 表に無いか形が違えば texture を作る。登録簿に `name` → (表の番号, design の幅と高さ) を載せる。開いているフラグを立てる。
2. 開いている間の `renderCommands`: その texture の render pass に描く（2.5 の op）。溜めた面と場面はここで取り出して捨てる（V1 は描かない。今の GL と同じく画面の方へ漏らさない）。
3. `endTarget`: フラグを下ろす（標本 1 なので resolve は無い）。
4. 本編の `renderCommands` は `Render.sprite(name)` を普通の絵として描く。uv は返さない（2.6）。sampler は NEAREST（`Render.Pass` の doc の約束）。

- 自分を読む Pass（`<名前>@prev`）は、今の GL が `glBlitFramebuffer` で前のコマを写す所。`WebGpu` の interface に texture から texture への写しが無いので V1 では描かない（親 R1b ⇄ P6 の history）。
- 同じ見た目かは 8.1 の門で GL と画素で比べる。

## 5. ウィンドウ

### 5.1 PC（`LwjglLayer.WebGpu`）

- 起動の順: device を開く（ウィンドウより先）→ ウィンドウを `GLFW_NO_API` で作る（`WebGpuWindow.open`）→ surface を `configure`。どこかで落ちたら 6 章の道で GL へ。
- 大きさ: `WebGpuWindow` は GLFW の framebuffer の大きさの callback で surface を作り直す（12.7: Dawn は知らせない）。その callback の中で `lastFrame` を描き直して出す（GL の
  `glfwSetFramebufferSizeCallback` と同じ役。macOS はリサイズの間 `pollEvents` が戻らない）。中間の texture もここで作り直す。
- 隠して起動（`FLIX_GE_HIDDEN`）: 中間の texture を design の大きさで作り、ウィンドウの大きさは見ない（GL の「fb = design に固定」と同じ結果）。Retina の 2 倍はウィンドウを見せる時だけの話になる。
- Retina: `WebGpuWindow.backingScaleOf`・framebuffer の大きさで中間の texture を画素の大きさで作る。ウィンドウを見せて Retina で絵が正しく出るかは【未確認】（12.7 の残り）。段階 3 で目で見る。
- vsync: 既定は `FIFO`。`FLIX_GE_NO_VSYNC`・隠して起動・読み込みの間は `IMMEDIATE`（GL の `glfwSwapInterval(0)` の 3 か所と同じ）。Dawn の Metal で `IMMEDIATE` が使えるかは【未確認】。
  使えなければ `FIFO` のまま 1 行知らせる（`sprite_stress` の比べが vsync に縛られるので、段階 5 の前に確かめる）。
- 1 コマの時間: `noteFrame(submitNs, swapNs)` の submit を「encoder を積み終えるまで」、swap を「`getCurrentTexture` から `present` まで」にする。画面へ出す待ちは swap 側に入る（12.7）。
- `finishAfterSwap`（Windows だけの `glFinish`）は、Windows を確かめる時（判断 9）に `onSubmittedWorkDone` で同じ事をする。V1 は Mac だけ。
- 起動画面: `RenderSplash.install(gl)` は GL で絵を上げる。WebGPU 版は同じ絵（`RenderSplash` の画素）を `WebGpuPaint` の API で上げる小さな関数を足す（`RenderSplash` が画素を外に出していなければ、出す形を段階 3 で決める）。

### 5.2 ブラウザ（canvas）

- canvas は今の `fge-canvas` 1 つ。WebGPU を選んだ時は JS が `getContext("webgl2")` を呼ばずに `main` へ進み、Java が `createCanvasSurface("fge-canvas")` で `webgpu` の文脈を取る。
- 大きさ: 今の `fgeResizeCanvas`（css の大きさ × `devicePixelRatio`・`?capture` の時は design）のまま JS が canvas の大きさを持つ。Flix はコマごとに `Browser.canvasWidth/Height` を読み、
  変わっていれば surface を `configure` し直し、中間の texture を作り直す。`BrowserSurface.configure` は canvas の大きさを書くが、同じ値を書くだけなので食い違わない。
- canvas の alpha は `opaque`（今の WebGL2 の `alpha: false` と同じ）。形式は `getPreferredCanvasFormat()`。

## 6. 起動の選び分け

### 6.1 PC

- `LwjglEnv.Settings` に `backend` を足す（`FLIX_GE_BACKEND`: 無い・`gl` → GL／`webgpu` → WebGPU を試す／ほか → 1 行知らせて GL）。
- `LwjglLayer.withLwjgl` の頭で分ける。GL の枝は今の本文をそのまま（関数の中身を動かさない）。WebGPU の枝で落ちる所と知らせ:

| 落ちる所 | 知らせる文（1 行・stdout） |
|---|---|
| Dawn のネイティブが読めない（jar が無い・置き場の誤り） | `[backend] WebGPU を使えない: Dawn のネイティブを読めない（<理由>）— GL で起動する` |
| `WebGpuDevice.requestDevice` が `Err` | `[backend] WebGPU を使えない: <Err の文> — GL で起動する` |
| `core-features-and-limits` が無い | 同じ形 |
| ウィンドウか surface が作れない | ウィンドウを壊し、device を手放してから GL の枝へ（GL のウィンドウは作り直す） |

- 選べた時も 1 行出す（`[backend] webgpu: <adapterInfo>`）。gl-capture と sprite_stress の門はこの行を見て「本当に WebGPU で撮ったか」を確かめる。

### 6.2 ブラウザ

- JS（`fgeBoot`）: `?backend=webgpu` があり `navigator.gpu` があれば、webgl2 の文脈を取らずに `main` を呼ぶ。それ以外は**今と同じ順**（webgl2 の文脈 → `main`）。
- Java（`WebLayer.withWeb`）: WebGPU を頼まれていれば `BrowserWebGpu.open()` → 条件（`core-features-and-limits`）→ `createCanvasSurface`。どこかで落ちたら、
  JS の `fgeInitWebGl2()`（今の L1496〜1500 を関数に出した物）を呼んで webgl2 の文脈を取り、GL の枝へ進む。canvas は `webgpu` の文脈を取る前なので取り直せる。
- 知らせ: `console.warn("[backend] WebGPU を使えない: <理由> — WebGL2 で起動する")`。`?capture` の `renderer` にも出る（2.7）。画面には出さない（伺う事 4）。
- `WebLayer.withProject3d` は頼まれても GL のまま起動し、同じ形で理由を知らせる（親 9 章のリリース 2 の行）。

### 6.3 書き出しは 1 つ（wasm 1 本に両方を入れる）

| 案 | wasm の大きさ | 手間 |
|---|---|---|
| A. 1 本に両方。起動で選ぶ | WebGPU の分だけ全部のゲームで増える。`bench/webgpu_check` の書き出しが丸ごと 419,903 バイト【確・`ls -la build/bench-web/webgpu_check/classes.wasm`（main の作業場）】で、これは `BrowserWebGpu` と JSO と Flix の門と TeaVM の土台を全部含む上限。V1 の backend の Flix（約 1,000 行の見込み）を足して +0.3〜0.6 MB（rpg-starter の 8,256,469 バイトの 4〜7%）【推】 | `export-web` は変えない。JS と `withWeb` の分け目だけ |
| B. 2 本作り、JS が片方だけ読む（親 5.5） | 読む方は増えない | 書き出しの時間が倍（rpg-starter で 43 秒 → 約 86 秒【推】）・束と頁が 2 組・Go の `export-web` と ⑨ の確かめを 2 回・入口を 2 本に分ける Flix |

**A にする。** 増える分は書き出しの差の揺れ（0.14.1 → 0.16 で +4.5%）と同じくらいで、B の手間（書き出しが倍・入口が 2 本）に見合わない。
段階 4 の終わりに rpg-starter の wasm の前後を測り、+10% を超えたら B を伺い直す。親 5.5 の文は、リリース 2 の文書の直しの時に A へ書き換える。

### 6.4 GL の道を壊さない事の確かめ

- PC: 環境変数が無い時に通る関数は、`LwjglEnv.load` の 1 欄を除いて今と同じ。門: `make gl-capture-check`（SHA が前と同じ）・render_gl のテスト（`make sync-layers` の後に `.layers/render_gl` で）・テンプレ 3 本の `reference-check`。
- ブラウザ: クエリが無い時の JS の順は今と同じ。門: `bin/fge web-capture` で rpg-starter と sound-novel-starter の題名の画面の SHA が前と同じ・`export-web` の ⑨。

## 7. WGSL

### 7.1 対にする GLSL

| WGSL（`WebGpuShader`） | 対の GLSL（`RenderShader`） |
|---|---|
| `sprite`（`vs_main`・`fs_main`・`fs_multiply`） | `spriteInstancedVertexShaderSource`・`spriteInstancedFragmentShaderSource`（`multiplyBlend` は `fs_multiply` に） |
| `present`（全面の三角形で中間の texture を写す） | 対は無い（GL は既定の framebuffer へ直に描く） |

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
- **前乗せの alpha は使わない。** 絵は straight alpha のまま上げる（PC は解いたバイトのまま・ブラウザは `ImageBitmap` を `premultiplyAlpha: "none"` で作っていて【確・fge-web.js】、
  `copyExternalImageToTexture` も `premultipliedAlpha: false`）。blend の因子は 2.3。Multiply だけシェーダーで rgb × a（GL と同じ）。
- filter と address（今の値を写す）:

| 絵 | GL | WebGPU |
|---|---|---|
| project.json の絵・生成の絵 | NEAREST・REPEAT・mip 無し | sampler NEAREST・REPEAT・mip NEAREST（段階 1 つ） |
| フォントのアトラス | LINEAR・wrap は既定（REPEAT） | LINEAR・REPEAT |
| Pass の texture | NEAREST・CLAMP_TO_EDGE | NEAREST・CLAMP_TO_EDGE |
| 1×1 の透明な黒 | — | NEAREST・REPEAT |

## 8. 門

### 8.1 GL の backend と画素を比べる

- **PC**: `bin/gl-capture.sh` を同じ機械で 2 回（既定と `FLIX_GE_BACKEND=webgpu`）流し、撮った PNG を画素で比べる。
  比べる道具を `fge-go` に足す（`go/internal/compare` の `readPNG`・`pixelAt` を使う。差の最大と差のある画素の数と、差の所の絵を書く）。
  許容は場面ごとに `bench/webgpu_v1/tolerance.tsv`（場面・許す差・理由）に書く。既定は 0、字の距離場（`fwidth`）など丸めが出る場面だけ 2/255。
  撮った側が本当に WebGPU だったかを、起動のログの `[backend] webgpu:` の行で確かめる（無ければ門を落とす。GL へ落ちた絵を比べて緑にしない）。
  - 場面: rpg-starter の `title`（お題）・Pass に通した `title`（伺う事 1）・`bench/gl_parity` の `passPaste`（画面へ出す場面で、Pass 1 つを貼る）と、スプライト・字・箱だけの場面。
  - `bench/gl_parity` を `FLIX_GE_BACKEND=webgpu` で流せば、SoftRaster とも比べられる。ただし「target に描いて読む」場面（`ViaTarget`）は GL の `GlReadback` を直に呼ぶので
    V1 では流さない（画面の場面 `ViaScreen` だけ）。
- **ブラウザ**: `bin/fge web-capture` で `?capture=N` と `?capture=N&backend=webgpu` を同じ機械で撮り、同じ道具で比べる。`renderer` に `webgpu:` が無ければ落とす。
  ブラウザの WebGPU の絵は PC の WebGPU とも比べる（`webgpu-check-same` で三角形の digest が同じだった事の続き）。
- 門は GPU が要るので CI に載せない（`webgpu-check` と同じ）。make の入口は `make webgpu-v1-check`（PC）と `make webgpu-v1-check-web`（ブラウザ）。

### 8.2 `sprite_stress` の同じ絵 20,000 個

- PC: `cd bench/sprite_stress && make run TEX=1 COUNTS=20000,20000` を、GL と `FLIX_GE_BACKEND=webgpu` で **交互に 2 回ずつ**（GL・WebGPU・GL・WebGPU）。
  比べる値は frame の p50 と cpu の p50（`RESULTS.md` の流儀）。合格は WebGPU が GL の 1.05 倍以内。
- ブラウザ: `make bench-web BENCH=sprite_stress ARGS='n=20000&tex=1'` と `ARGS='n=20000&tex=1&backend=webgpu'` を交互に 2 回ずつ。cpu p50 と submit p50。
- 測る前に毎回 `pgrep -fl 'java|Chrome|flix'` で、ほかの重いプロセス（別の作業のビルド・ベンチ）が無い事を見て、結果の表に書く。熱の水増しを避けるため、重い区間の直後に測らない。
- 垂直同期を切る（PC は `FLIX_GE_NO_VSYNC=1` が `IMMEDIATE` になる事が前提。5.1 の【未確認】）。

## 9. 段階と見積もり

| 段階 | 中身 | 門 | 見積もり |
|---|---|---|---|
| 1 | `WebGpuShader`・`RenderFrame.WebGpu`・`WebGpuPaint` の中核（device・pipeline・instance buffer・中間の texture・絵の表）。画面なしの session（`WebGpuOffscreen`）で、`gl_parity` の箱とスプライトの場面を GL の `GlOffscreen` と比べる render_gl のテスト | 差 0（字は 2/255）・`errorCount` 0 | 1〜1.5 時間 |
| 2 | 絵とフォントのアトラスを上げる（PC の読み込み・`ensureTexture`・字が増えた時）と Pass（`beginTarget`〜`endTarget`）。`WebGpuPaintHandlers` | 段階 1 のテストに Pass の場面と生成の絵を足す | 1 時間 |
| 3 | PC のウィンドウ（`LwjglLayer.WebGpu`・選び分け・frame shot・起動画面・大きさの変化・vsync）。`engine_full` に Dawn のネイティブ（伺う事 2） | 8.1 の PC（rpg-starter の title と Pass）。GL へ落ちる道 3 つを手で起こす（ネイティブを外す・頼む値の誤り・ウィンドウの誤り） | 1〜1.5 時間 |
| 4 | ブラウザ（JS の分け目・`withWeb` の分け目・`ImageBitmap` の写し・`?capture` の読み戻し・device lost の案内）と wasm の大きさの前後 | 8.1 のブラウザ・WebGPU の無い頁（`navigator.gpu` を消した頁）で WebGL2 で起動する・6.4 | 1〜1.5 時間 |
| 5 | 比べる道具と `make` の入口・`sprite_stress` の PC とブラウザ・レビュー役（1 回目で全部の指摘を出させ、まとめて直して 2 回目） | 8.1・8.2・6.4 の全部・レビュー 90 点 | 1〜1.5 時間 |

**合わせて 5〜7 時間**【推】。親の 9 章の見積もり（6〜9 時間）の下の方。直近の実績は P4a が 9〜13 時間の見積もりに対し約 3 時間、P4b が 4〜6 時間に対し約 1 時間で、
見積もりの 1/4〜1/3 で済んでいる。V1 はウィンドウ・JS・読み込み・門の道具と触る所が広く、P4a・P4b より散らばるので、同じ割合までは縮まないと見る。

## 10. 危ない所と逃げ道

| 危ない所 | 逃げ道 |
|---|---|
| `firstInstance` で instance の頂点バッファを引く形の代金が、試した storage buffer の形と違う | 段階 1 で `webgpu-check` の 20,000 本の試しに頂点バッファの形を足して測る。遅ければ storage buffer と `instance_index` に替える（WGSL の入口の差だけ） |
| `sprite_stress` で WebGPU が GL より 5% 以上遅い（ブラウザの `writeBuffer` の写し・PC の `getCurrentTexture` の待ち） | 内訳（積む・写す・出す）を取って人に伺う。V1 の門を緩めずに、形のレビューの材料にする |
| 字の距離場（`fwidth`）が 2/255 を超えてずれる | 差の所の絵を出し、場面ごとの許容に理由を書いて人に見せる（親 11 章の 6）。式は変えない |
| 中間の texture から写す 1 枚の代金（4K の画面で毎コマ全面） | `sprite_stress` と題名の画面で GPU の時間を見る（timestamp-query があれば）。重ければ「Pass も 3D も無いコマは画面へ直に描く」を形のレビューへ |
| Dawn の Metal に `IMMEDIATE` が無い | `FIFO` で測り、8.2 の比べを GL も vsync ありにそろえる |
| ブラウザの `copyExternalImageToTexture` が色の変換を掛ける | `ImageBitmap` は `colorSpaceConversion: "none"`。門で差が出たら、解いたバイトを `writeTexture` で上げる道に替える |
| `RGBA16_FLOAT` の Pass を作る 1 本の pipeline でコマが落ちる | 起動の時に作る物へ足す（6 本全部を起動で作っても、ブラウザで 0.4〜0.6 秒【推】） |

【未確認】の物: Retina の 2 倍でウィンドウに出る絵・Dawn の Metal の `IMMEDIATE`・Dawn の device lost の callback・画面の形式が `_SRGB` だけの端末・
Safari と iPhone・Windows と Linux（判断 9）・WebGPU の無いブラウザで WebGL2 版が起動する事（段階 4 で `navigator.gpu` を消した頁で代える）・TeaVM がコマの途中で手を返した時の中間の texture の扱い（親 5.4 の理由をそのまま信じている）。

## 11. 人に伺う事

1. **「Pass に通した題名の画面」の作り方**。rpg-starter は Pass を使わない（`templates/rpg-starter/src` に `withPasses`・`passPlan` が無い【確・grep】）。
   - (a) rpg-starter の `Starts` に「題名を Pass 1 枚に描いて貼る」始まりを足す（テンプレの src と reference に乗る）
   - (b) engine に開発用の入口（環境変数。例 `FLIX_GE_WRAP_PASS=1`）を足し、どのゲームでも本編を Pass 1 枚に描いて `Render.blit` で貼る（engine 拡張・相談が要る。gl-capture の全部の場面を「Pass に通して」両方の backend で比べられる）
   - (c) Pass のお題は `bench/gl_parity` の `passPaste` で代え、rpg-starter は題名の画面だけにする（engine もテンプレも触らない）
   - **おすすめは (c)** で V1 を進め、(b) は R1b ⇄ P6（history と MSAA で Pass の場面が増える所）で改めて伺う。(c) は親 9 章の文と違うので、了承をいただきたい。
2. **Dawn のネイティブを `engine_full` に載せる時期**。V1 の門は rpg-starter（ゲームの lib の fpkg）を WebGPU で動かすので、ネイティブが要る。
   - (a) V1 で `engine_full/flix.toml` に macOS arm64 だけ足す（全部のゲームの配る物が Mac で 2.6 MB 増える。Windows・Linux はリリース 2）
   - (b) テンプレの `flix.toml` にだけ足す（新しく作るゲームに乗る。外のゲームには乗らない）
   - (c) 門を流す時だけ一時の `flix.toml` で足す（何も増えないが、門の道具が flix.toml を書き換える）
   - **おすすめは (a)**。12.8 の WhyNot（選べないうちは載せない）は、V1 で試しに選べる口ができるので理由が無くなる。
3. **PC で 3D を使うゲームが `FLIX_GE_BACKEND=webgpu` を付けた時**。ブラウザは入口（`withProject3d`）で分かるが、PC は入口が 1 つで起動の時に分からない。
   - (a) V1 は場面を描かずに 1 回知らせる（遊べるが 3D が欠ける）
   - (b) project.json の `scene3d` などの目印で起動の時に GL へ落とす（目印をどこに持つかを決める要がある）
   - **おすすめは (a)**（試しに選ぶ口なので欠けを知らせれば足りる）。リリース 2 の文「入口が 3D のゲームは GL のまま」を PC でどう満たすかは、リリース 2 の前に決める。
4. **GL へ落ちた理由の出し方**。PC は stdout の 1 行、ブラウザは console と `?capture` の `renderer`。画面（頁）には出さない案。
   試しに選ぶ口なので画面に出すほどではない、が**おすすめ**。リリース 2 で既定を替える前に見直す。

## 12. 形のレビュー（2D）への持ち越し（V1 では作り替えない）

1. 描き先の上下を `targetNames` で知らせている（V1 は空の Set を渡して済ませた）→ 前半が backend に聞く capability（親 5.3）。
2. `RenderList` の instance の番号が `renderCommands` ごとに 0 から → WebGPU はコマで 1 本の buffer の位置を足している。前半がコマで 1 本の入れ物に書く形か、行に起点を持つか。
3. run の状態の配列 `st` に GL の物（program・VAO・buffer の番号・欄 0〜6 と 26）と前半の run の状態と draw の数が同居している → 分ける。
4. `RenderBuf` が `gl.allocFloats` で入れ物を作る → instance の入れ物の持ち主を backend にするか、前半にするか。
5. `RenderPaint` と `WebGpuPaint` の重なり（登録簿・`ensureTexture` の key・描き先の表・溜めた面と場面・`lastFrame`）→ CPU の側の表を前半へ（親 R1b の寿命の表）。
6. `AssetLoader`・`FontsLoaded.grow`・`RenderSplash.install` が `GlContext` を受ける → 「上げる行」か、上げる口の小さな record。
7. 画面の clear（黒帯と `clearColor`）が `renderFrameMixed` の中の GL の呼び出しで、行になっていない → pass の区切りの行に clear を持たせる。
8. pipeline の鍵の半分（描き先の形式）は pass の性質で、行は blend だけを持つ。今の形で足りるかを 3D の前に見る。
9. mask つきスプライトが GL を直に呼ぶ（`drawMaskedOne`）→ 行の種類にする（親 8 章の stencil の ref を進める形）。
10. Pass の history の写し（`copyTo`）が行にも `WebGpu` にも無い → pass の区切りの行に「前のコマを写す」を持たせ、`WebGpu` に texture の写しを足す。
11. 1 回の `renderCommands` ごとに流し、submit はコマの終わり → コマの途中の上げ物の前に submit する決まり（3 章）を、「上げる行」を列に入れる形と比べる（親 9.1 の「いつ流すか」）。
12. instance を頂点バッファで読むか、storage buffer と `instance_index` で読むか（2.1）。draw ごとの値（面・材質）を入れる時にどちらにそろえるか。
13. 字の絵だけシェーダーが読む成分が違う（GL は swizzle で `.a`・WebGPU は `.r`）→ 絵の種類を行か表に持つか。
14. 絵ごとの filter と address を表の番号の裏（bind group）に持たせた → 行は番号だけでよいか。アトラスの頁（親 6.1 の 3）にした時の sampler の持ち方。
15. 中間の texture へ描いてから画面へ写す 1 枚 → Pass も 3D も無いコマで省くか（10 章）。
