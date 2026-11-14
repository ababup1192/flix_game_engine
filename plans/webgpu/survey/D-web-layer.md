# D: ブラウザの層の組み立てと、機種を差し替える高さ（WebGPU を入れる設計のための下調べ）

読むだけの調査。【確】= 今回ソースを読んで確かめた。【推】= 読んだ物からの推測。【不明】= 確かめていない。
.flix の実体は `src/<パッケージ>/…` の symlink で、本体は `engine/src/…`・`render_gl/src/…`・`engine_web/src/…`・`engine_tools/src/…` にある。

## 0. 先に結論

1. 機種を差し替える高さは `Platform.Services`（effect の束）で、**WebGPU の層はここに同じ高さで足せる**【確】。`WebLayer` は `RenderPaintHandlers`（塗りのコア `RenderPaint` に渡す handler）を `GlContext` だけ替えて **LwjglLayer・GlOffscreen と共有している**【確】。別に書いていない。
2. 差し替えの境目は 3 つ（docs/flix-conventions.md:198-202）。1 行目の機種の handler 一式が WebGPU の高さ。3 行目の `GlContext` は「GL 3.3 と WebGL2 のためだけの層」と明記されていて、**GL の形でない WebGPU のために広げない**決め（flix-conventions.md:205）。plans/engine-browser.md:295 も「WebGPU は GL の形ではないので `GlContext` の隣に別の層が要る」と書く【確】。
3. つまり WebGPU の版は「`RenderPaintHandlers` の下の `RenderPaint`（約 1.1 万行の render_gl の本体）を使わず、`Platform.Draw2d/Draw3d/GpuResources/RenderTarget.Target/Diagnostics` を別の描き手で書く」か「RenderPaint を `GlContext` 以外の層へ抜く」かの二択になる。後者は規約が止めている【確】。前者なら effect の高さは今のまま【推】。
4. 同期で値を返す操作は、effect の作りとしては全部同期（handler が `k(値)` で返す）。ただし TeaVM のコルーチンで **handler の中から `@Async` の native を呼んで止まれる**ことは `presentFrame`（`AnimationFrame.waitTick`）と `showProgress`（`waitFrame`）で実績がある【確】。WebGPU の非同期（シェーダーの診断・読み戻し・デバイスの取得）は、この道で待てる【推】が、止まれる関数の上にいる全部にコルーチン変換の代金が乗る（plans/browser-spike.md §5「フレームの回し方」）。

---

## 1. `Platform.Services`（engine/src/platform/Platform.flix:196）

`Services = Input + Window + FrameClock + Rendering + RenderTarget.Target + GameEngine.Audio + Diagnostics + Tasks`、`Rendering = Draw2d + Draw3d + GpuResources`（:193）。
`Annotation` は Services の外（開発の道具）。`Fs.FileRead`・`Fs.FileWrite`・`LoadProgress` も別に張る。`App.launch` の型は `Platform.Services` を要る（Platform.flix の頭コメント・usages: App.launch ほか 10 か所）。

【描く物は同じ handler の組から張る】Draw2d.drawSurface と Draw3d.drawScene3d は描かず列へ積み、次の Draw2d.renderCommands が z の順で合流して出す。だから Draw2d・Draw3d・GpuResources は同じ paint から張る（Platform.flix:9-12）。Input と Window もマウスの押したフラグを分け合うので同じ組。

### 描画に関わる effect（操作名と型を全部）。★ = 戻り値あり（同期で値を返す）

| effect | 操作 | 型 | 本数 |
|---|---|---|---|
| Draw2d | `renderCommands` | `(List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd], Option[GameEngine.StaticLayerCmd]) -> Unit`。画面へは出さない（出すのは Window.presentFrame）。ターゲットが開いていればそこへ描く | 2 |
| | `drawSurface` | `DrawCmd.SurfaceRenderCmd -> Unit`（次の renderCommands の列へ積むだけ） | |
| Draw3d | `drawScene3d` | `Scene3d.RenderCmd -> Unit`（積むだけ） | 2 |
| | `preload3d` | `Scene3d.PreloadCmd -> Unit`（初めて出る物を GPU へ先に上げる・同じ key なら何もしない） | |
| GpuResources | ★`initTileBuffer` | `List[GameEngine.TileInstance] -> (GpuHandle.TileVao, Int32)` | 7 |
| | ★`updateTileBuffer` | `(GpuHandle.TileVao, List[TileInstance]) -> (GpuHandle.TileVao, Int32)`（未知の VAO は新規に作って返す＝返りを保存し直す約束） | |
| | `ensureTexture` | `(name: String, key: String, width: Int32, height: Int32, argb: Vector[Int32]) -> Unit`（key が前回と同じなら何もしない・毎フレーム呼んでよい） | |
| | `ensureGlyphs` | `(textureName: String, codepoints: Set[Int32]) -> Unit`（初めて出る字は 1 コマ遅れて出る） | |
| | ★`getFontAtlas` | `String -> FontAtlas`（CPU の登録簿を引くだけ） | |
| | ★`getTextureInfo` | `String -> Option[GameEngine.TextureInfo]`（同上） | |
| | ★`buildProgram` | `ShaderDoc.Spec -> GpuHandle.ShaderProgram`（GLSL を作ってコンパイル。**失敗時は bug! でなく単色のフォールバックを返す fail-open**） | |
| RenderTarget.Target | `beginTarget` | `RenderTarget.TargetSpec = { name, width, height, format: Rgba8Unorm\|Rgba16Float, clear: Keep\|Clear(Color)\|ClearTransparent, samples: Int32 } -> Unit` | 3 |
| | ★`pixelScale` | `Unit -> Float64`（描き手の design px → 描き先の画素の倍率） | |
| | `endTarget` | `Unit -> Unit` | |
| Diagnostics | `setDiagnosticsEnabled` | `Bool -> Unit` | 2 |
| | ★`consumeDiagnostics` | `Unit -> FrameDiagnostics.Diagnostics`（溜まった物を返して空に戻す） | |

RenderTarget の補足（engine/src/platform/RenderTarget.flix）: `Format` は wgpu の TextureFormat と同じ名前、`LoadOp` は wgpu / Vulkan の LoadOp と同じ語彙、`samples` は 1・2・4・8（描き手が GPU の上限で頭打ち）。**API の語彙は既に wgpu 寄り**【確】。
`RenderTarget.runNoop`（:117）と `Platform.runNoopDraw3d`（Platform.flix:136）が「描かない」handler。

### 描画以外の effect

| effect | 操作（★ = 戻り値あり） | 本数 |
|---|---|---|
| Input | ★`isKeyPressed(Key)->Bool`・★`getMousePosition()->Vec2`・★`isMouseButtonPressed(MouseButton)->Bool`・★`isGamepadTouched()->Bool`・★`gamepadKind()->PadKind`・★`gamepadSticks()->{left,right: Vec2}`・★`consumeScrollDelta()->Float64`・★`consumeMouseDelta()->Vec2`・★`isWindowFocused()->Bool` | 9 |
| Window | `pollEvents`・★`shouldClose`・`setShouldClose(Bool)`・★`getViewportRect()->Rect2`・★`getDisplay()->Display.Display`・`setCursor`・`setCursorVisible`・`setMouseCaptured`・`setFullscreen`・★`isFullscreen`・`presentFrame`・`setDebugBadge` | 12 |
| FrameClock | ★`getDeltaTime()->Duration`（maxDeltaTime で上限済み） | 1 |
| GameEngine.Audio | `playAudio`・`stopAudio`・`setVolume`・`setPitch`・`setLooping`・`setMasterVolume`・`reloadAudio`・`setLowpass`・★`audioSeconds(String)->Float64` | 9 |
| Tasks | `startTask(Unit -> JObject \ IO)`・★`finishTask()->JObject`。ブラウザは `Platform.runTasksInPlace`（finishTask の時にその場で走らせる） | 2 |
| Annotation（Services 外） | ★`saveAnnotation(AnnotationRequest)->Option[String]` | 1 |
| LoadProgress（Services 外） | `report(phase,done,total)`・`runTasks(phase, List[Unit->Unit\IO])`・★`imageDecoder()->ImageData.ImageDecoder`・★`downloads()->AssetDownloads`（後回しの素材） | 4 |
| Fs.FileRead / FileWrite（Flix 標準の effect） | read / readLines / readBytes ・ write / writeLines / writeBytes / append / appendLines / appendBytes / truncate ほか | — |

`Display.Display = { size, scaleFactor, designScale, pointer: Mouse|Touch, sizeClass: Small|Medium|Large, orientation: Landscape|Portrait }`（engine/src/platform/Display.flix）。

### WebGPU から見た「同期の印」

effect 自体に async は無い。次の 3 群で見る。

A. **GPU の資源を作って番号（ハンドル）を同期で返す**: `initTileBuffer`・`updateTileBuffer`・`buildProgram`。WebGPU の `createBuffer`・`createShaderModule`・`createRenderPipeline` は同期でオブジェクトを返すので、ハンドルを返す形は保てる【推】。**ただし `buildProgram` の「失敗なら単色のフォールバック」は、コンパイルの成否を同期で知る前提**。WebGPU の `getCompilationInfo` は async、`createRenderPipelineAsync` も async。同期の `createRenderPipeline` は検証の誤りを error scope（async）で後から受ける【推】。fail-open を保つには「作る→1 コマ待つ→誤りなら差し替え」か、起動時にコルーチンで待つ設計が要る。
B. **GPU の状態を同期で問う（effect の下の GlContext の呼び出し）**: シェーダーの `getShaderi(COMPILE_STATUS)`・`getProgrami(LINK_STATUS)`（render_gl/src/Shader.flix:336・351・372・392）、`checkFramebufferStatus`（Target.flix:68・126、Render3d/Shadow.flix:143）、`getInteger(MAX_SAMPLES)`（Target.flix:43）・`getInteger(MAX_TEXTURE_SIZE)`（Render3d/DataTexture.flix:52）、`readTextureArgb`（Render3d/Material.flix:277。ブラウザは `prefersGpuMipmap` が真で `copyTextureLevel0` を先に試す＝読み戻しを避ける道が既にある）。WebGPU は FBO の完全性を問う口が無く（作る時に検証される）、上限は `device.limits` で同期に引ける。読み戻し（`mapAsync`）は非同期。
C. **CPU の登録簿・計数を返すだけ**: `getFontAtlas`・`getTextureInfo`・`pixelScale`・`consumeDiagnostics`・Input 群・Display・FrameClock。WebGPU でも同期のまま【推】。GPU 時間（`GpuTimer`）はブラウザ版で `RenderPaint.noFrameTimer()`（WebLayer.flix:92）＝計らない。timestamp-query の読み戻しは async なので、WebGPU でも計らない道なら影響なし。

画面の絵の読み戻し（デスクトップの F8 注釈・`GlReadback`・`GlOffscreen.readImage`・`LwjglLayer.frameShot`）は **effect の外**で、GL11 を直に呼ぶ（LwjglLayer.flix:377 の `GL11.glReadPixels`、GlReadback.flix:17、GlOffscreen.flix:435・450・695）。ブラウザは `fgeFrameDrawn`（fge-web.js:~207-226）が `?capture=<n>` の時だけ `readPixels`【確】。

---

## 2. WebLayer（engine_web/src/WebLayer.flix・462 行）と LwjglLayer（render_gl/src/LwjglLayer.flix・1042 行）

### 入口

| 関数 | 中身 |
|---|---|
| `withProject(rootDir, f)`（:36） | 2D の入口。`withProjectUsing(…, (_, _) -> makeWarningRenderer(), f)`。3D の場面は描かず初回に 1 回知らせる。**WhyNot: 2D の入口を withProject3d に寄せない（Render3d へ届くと 3D を使わないゲームの wasm まで太る）**（:35） |
| `withProject3d(rootDir, f)`（:40） | `Render3d.makeRenderer(gl, config, Render3d.DrawMode.Instanced)` を渡す |
| `withProjectUsing`（:44） | `ProjectLoader.loadProject(rootDir)` → `withWeb(makeRenderer, bootConfigOf(proj), f)`。読めなければ `bug!` |
| `withWeb`（:83） | 下の組み立て |

`makeRenderer: (GlContext, EngineConfig) -> Scene3dRenderer.Renderer \ IO` が 2D の入口と 3D の入口の差し替え点【確】。`Scene3dRenderer.Renderer` は値（2 実装: `Render3d.makeRenderer`・`Scene3dRenderer.none()`・flix-conventions.md:201）。
そのほか入口の外に `bootConfigOf`（縦の design を選ぶ・:66）・`devTools()`（`App.DevTools.browser`・URL のクエリを引数に読む・:22）・`tickRate()=60.0`（:32）。

### `withWeb` が handler に渡す物（:83-122）

1. `Browser.setTitle`。`gl: GlContext = checked_cast(new WebGl2())`（:86）。`gl.enable(BLEND)`・`blendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)`（LwjglLayer と同じ始め方）。
2. `paint = RenderPaint.create(gl, { designWidth, designHeight, clearColor, screenFramebuffer = 0, scene3d = makeRenderer(gl, config), gpuTimer = RenderPaint.noFrameTimer() })`。
3. `RenderPaint.addTextures(RenderSplash.install(gl), paint)`（組み込みフォントとロゴ）。
4. `framebufferSize = () -> (Browser.canvasWidth(), Browser.canvasHeight())`。
5. `state`（Ref の束: looping・closeRequested・lastDt・fullscreenAsked・cursor・cursorVisible・yieldedAt・warnedSounds・budget・spentMs・pendingTextures・pendingSounds）。
6. `fonts = RenderPaint.loadAssets(gl, paint, WebAssets.loader(), config, showProgress(state))`。**`RenderPaint.AssetLoader = { loadTextures, loadFonts }` が素材の読み込みの 4 つ目の差し替え点**【確】（デスクトップは LwjglAssets・stb、ブラウザは WebAssets）。
7. handler の重ね（内側から外へ。:110-120）: `handleLoadProgress` → `handleAudio` → `RenderPaintHandlers.handleTarget` → `handleDiagnostics` → `handleDraw3d` → `Platform.runTasksInPlace` → `handleFrameClock` → `handleWindow` → `RenderPaintHandlers.handleDraw2d(gl, paint, framebufferSize, (_, _) -> checked_ecast(()), …)` → `handleInput` → `RenderPaintHandlers.handleGpuResources(gl, paint, fonts, f)`。終わったら `Browser.ended()`。
   Fs は呼ぶ側（WebMain）が `with WebFs.runFileRead with WebFs.runFileWrite` で張る（WebLayer.flix:4 の利用例）。

### LwjglLayer との違い

| 項目 | LwjglLayer.withLwjgl（:296-548） | WebLayer.withWeb |
|---|---|---|
| 描きの handler | `RenderPaintHandlers.handleTarget/Diagnostics/Draw3d/Draw2d/GpuResources`（render_gl/src/PaintHandlers.flix） | **同じ 5 本をそのまま呼ぶ**（`GlContext` が `WebGl2`） |
| `onScreen` 引数 | 塗りの時刻を `present#screenPainted` へ置く | 何もしない |
| GL の文脈 | GLFW が窓と GL 3.3 core を作る（stencil 8bit・depth 24bit・隠しウィンドウ・Retina の扱い） | JS が canvas から WebGL2 を取る（下 §3） |
| Window / Input / FrameClock | GLFW・`LwjglInput`（ゲームパッドは SDL）。FrameClock は fixedDt 対応 | `Pointer`・`Keys`・`Gamepads`（JS の表）。ゲームパッドは `GamepadMap` でスティックのみ・`isGamepadTouched` は常に false。FrameClock は rAF の時刻の差 |
| `presentFrame` | glfwSwapBuffers（`presentScreen`） | `Browser.frameDrawn()` → `AnimationFrame.waitTick(60)`（rAF まで止まる） |
| Tasks | `handleTasks`（コア数 2 以上なら別スレッド 1 本・未満は `runTasksInPlace`） | `runTasksInPlace` |
| Audio | OpenAL（EFX の lowpass あり） | WebAudio（`setLowpass` 何もしない・`reloadAudio` 何もしない） |
| Annotation | `handleAnnotation`（F8 の注釈） | 持たない（WebLayer.flix:6 WhyNot: 開発の道具は配る出力先に要らない） |
| LoadProgress | 起動画面を進めて poll | 頁の進み具合のバー・`AnimationFrame.waitFrame` で 50ms ごとに手を返す・`imageDecoder` は ImageBitmap を JS に持つ（`PlatformImage`）・`downloads` は後回しの素材 |
| GlOffscreen | — | — |

GlOffscreen.handle（render_gl/src/GlOffscreen.flix:380-393）も同じ 5 本を FBO へ向けて重ねる。つまり **`RenderPaintHandlers` を使う描き手は現在 3 つ（Lwjgl・Web・GlOffscreen）**【確】。

---

## 3. engine_web の Java・TeaVM・JS

### ファイル（engine_web）

- `java/fge/web/*.java`（計 1,682 行）: `WebGl2`（451）・`AnimationFrame`・`Browser`・`Pointer`・`Keys`・`Gamepads`・`WebAudio`・`WebImages`・`Deferred`・`AssetTable`・`LocalStorage`・`EmbeddedCodec`・`EmbeddedData`・`DecodedImage`。JS の関数を `@JSBody` で 1 つずつ呼ぶ薄い層。
- `teavm/java/…`: TeaVM の穴の手当て。`fge.teavmfix.{Rewrite, DirectBuffers, VirtualThreads, CopyOfRange, Checksums, References, Embed}`、classlib の shim（`THexFormat`・`TMessageDigest`・`TCyclicBarrier`・`TConcurrentLinkedQueue`・`TReentrantLock`・`TCondition`）。
- `js/fge-web.js`（1,523 行）・`js/index.html`（140 行）。
- `src/`: `WebLayer.flix`（462）・`WebFs.flix`（141）・`WebAssets.flix`（103）。

### canvas と WebGL2 の context

- 取る所: fge-web.js:1496 `fgeCanvas.getContext("webgl2", { alpha: false, antialias: false, stencil: true, depth: true, premultipliedAlpha: false, preserveDrawingBuffer: false })`。取れなければ `throw new Error("このブラウザは WebGL2 を使えない")`。続けて `getExtension("EXT_color_buffer_float")`・`pixelStorei(UNPACK_COLORSPACE_CONVERSION_WEBGL, NONE)`・`fgeGl = fgeCheckedGl(fgeGl)`（`?glcheck=1` の getError 包み）【確】。
- **取るのは「押して始める」の後**（:1493-1497）。wasm と素材は押す前に取っておく（:1426 のコメント「main は GL の文脈を作った後（押した後）に呼ぶ」）。
- GL の物は JS の表 `fgeH`（id → WebGLTexture 等）に置き、Java と Flix には int のハンドルだけを見せる（0 は null）。WhyNot: JS の物を Java の欄や配列に持たない（TeaVM の wasm-gc では JS の物は Java の Object の木に入らず、総称のデータや Object を受ける所へ渡すと wasm のコンパイルで落ちる）（WebGl2.java 頭のコメント）【確】。**WebGPU の GPUBuffer・GPUTexture・GPUBindGroup も同じ表にするのが前提になる**【推】。

### 1 コマの回し方

- ゲームのループは Flix の「止まる形のまま」。`Window.presentFrame` の handler が `AnimationFrame.waitTick(60)` を呼び、そこで止まる（engine_web/java/fge/web/AnimationFrame.java）。
- `AnimationFrame.waitFrame()` は `@Async public static native double waitFrame()`＋`Window.requestAnimationFrame(time -> callback.complete(time))`。**TeaVM のコルーチン変換**（wasm-gc でも動く・plans/browser-spike.md 結論 3）で、wasm が rAF の間だけブラウザへ手を返す【確】。
- `waitTick(hz)`: rAF の間隔を 16 回ぶん持って下から 4 分の 1 の値を `gap` とし、`gap < interval×0.9`（120/165Hz の画面）なら予定の時刻に乗るまで rAF を飛ばして 60 コマにそろえる。60Hz に近い画面では間引かない（決定: engine-browser.md「高いリフレッシュの画面で 60Hz に間引く」）。経過は `lastTick` との差（秒）。wasm の CPU 時間と rAF からの遅れを `window.fgeStats` へ渡す。
- 起動中は `showProgress` が 50ms（`yieldMillis`）ごとに `waitFrame` で手を返す（WebLayer.flix:427-435）。ループが回り始めた後（最初の `pollEvents`）は何もしない。
- 入力は `pollEvents` で `Browser.beginFrame()`（fgeBeginFrame）を呼び、キー・ボタンの「このコマで押された」を切り替える。

### context が失われた時

fge-web.js:672 `webglcontextlost` を `e.preventDefault()` して `fgeError("画面の描き先（WebGL）が失われました。頁を読み直すと、最後のセーブから続けられます。")` を出すだけ。**復元しない**【確】。決定 8（engine-browser.md:… 「まず案 2（頁を読み直してセーブから）を入れ、実機で起きる回数を見てから案 1（`fge.web` が作った時と状態を決めた時の呼び出しを控えて流し直す・1〜1.5 週）を判断」）【確】。`webglcontextrestored` の listener は無い【確】。WebGPU の device lost（`device.lost` Promise）も同じ扱いにするのが決めに沿う【推】。
致命でない例外は `window` の `error`・`unhandledrejection` が拾って `fgeError`（WebLayer.flix:124-125 の WhyNot: Flix の try で受けない — 再開した後の例外は try の外で投げられる）。

### 画面の大きさ・devicePixelRatio

- `fgeResizeCanvas`（fge-web.js:~228-237）: `dpr = devicePixelRatio`・`rect = canvas.getBoundingClientRect()`・`canvas.width/height = round(rect.size × dpr)`。`ResizeObserver` と `window.resize` で呼ぶ。`?capture=<n>` の時は design の大きさへ固定。
- `Browser.canvasWidth/Height`（画素）を `framebufferSize` として effect の下へ渡す。`display(design)`（WebLayer.flix:229）が `size = canvas/dpr`・`scaleFactor = dpr`・`designScale`（黒帯を除いた design 1px が CSS px で何 px か）・`pointer`（`Pointer.isTouch()`）・`sizeClass`（起動の時に測った `fgeScreenShortSide` と `fgeCoarseAtBoot`・`?size=` の上書き）・`orientation`。
- 黒帯: `RenderFrame.calcViewport(fbW, fbH, designW, designH)` で design の比の矩形を引く。`canvasToDesign` は黒帯を引いて design 座標へ（WebLayer.flix:250）。**canvas の画素の大きさと design の比を使う部分は effect の下ではなく Platform.Window/Input の handler に分散している**ので、WebGPU の層でも Window/Input は共有できる【推】。

### 起動（splash）と素材の読み込み（fge-web.js:1410-1523 ほか）

順序: `fgeBoot()` → bundle.json を読む → `fgeDeferredPrepare`（後回しの素材を分ける）→ `AudioContext` を作る（音は押す前に `decodeAudioData` で解く）→ **`TeaVM.wasmGC.load("classes.wasm")` を押す前に始める**（`wasmLoad`・WebAssembly GC が無いと「Chrome 119 以降・Safari 18.2 以降」の誤り表示）→ 素材を 6 本並列で取る（files・sounds、続けて images を `createImageBitmap(…, { premultiplyAlpha: "none", colorSpaceConversion: "none" })` で解く）→ `fgeSplashReady()` →「タップして開始」を待つ（keydown・click・pointerup(非マウス)・touchend。Safari の `AudioContext.resume` の制約）→ `navigator.storage.persist()` → canvas の大きさ → WebGL2 → `fgeWireInput()` → wasm の完了を待つ → `teavm.exports.main([])`。
splash の絵は JS の 2D canvas（`getContext("2d")`）で描く（fge-web.js:947）。エンジン側にも `RenderSplash.install(gl)`（ロゴ・組み込みフォントを gl に登録）がある。WebGPU でも JS の splash は変わらない【推】。
素材: 起動の前に JS が全部取って表 `fgeAssets`（Uint8Array）と `fgeImages`（ImageBitmap）に持つ。Flix 側は `WebAssets.loader()`（`RenderPaint.AssetLoader`）が画像を JS 内で GL にアップロードし（`WebAssets.uploadImageOf`）、字は書き出しの道具が事前生成したアトラス（`font-atlas/<名前>.fontatlas`）を読む（ブラウザに stb が無いので起動時に用意しなかった字は足せない）。後回し素材（`web.deferred`）は `Deferred` が届いた順に `registerArrivedTextures` が予算（`LoadProgress.DecodeBudget`）の内で登録。

### JS と Java の間のバッファの写しの回数

- 取り決め: GL に渡すのは `ByteBuffer.allocateDirect` 系（`allocFloats`・`allocInts`・`allocBytes`）。TeaVM では direct buffer は wasm の linear memory 上にあり（`teavmfix.DirectBuffers` のコメント:「Heap.alloc は memory を伸ばす…」）、`Float32Array.fromJavaBuffer(whole(direct))` が **その memory の上の view を作る**（コピーしない）【推・コメントから】。
- 頂点・インスタンス（`bufferData(FloatBuffer)`）: wasm memory 上の view を `gl.bufferData(t, view, usage, from, count)` へ → コピーは GL ドライバへの 1 回【確・コード】/ view がゼロコピーなのは【推】。direct でない buffer が来ると `copyFloats` でもう 1 回（WebGl2.java: `data.isDirect() ? data : copyFloats(data)`）。
- `float[]`・`int[]` を渡す `bufferData(float[])`・`uniform1fv/2fv/3fv`・`uniformMatrix4fv`: `Float32Array.copyFromJavaArray(value)`＝**Java の配列 → JS の typed array へ 1 回コピー**してから GL。
- 画素の上げ（`texImageArgbLevel`）: IntBuffer（direct）の view を JS の `fgeTexImageArgbLevel` が ARGB → RGBA のバイトへ並べ替えて `texImage2D`（WebGL2 に BGRA が無いため）。→ JS 内で 1 回並べ替え＋GL への 1 回。
- 読み戻し（`readTextureArgb`）: `readPixels` → JS の Uint8Array →（ARGB の int へ並べ替え）→ wasm 上の Int32Array view → Java `direct.get(argb, 0, count)` で `int[]` へ。**GPU → JS → wasm → int[] の 3 回**。避けるため `prefersGpuMipmap`＝真の機種は `copyTextureLevel0`（GPU の中で `blitFramebuffer`）を使う（WhyNot: readTextureArgb で読んで texImageArgb で上げ直さない — 画素が GPU → wasm → GPU と 2 回運ばれる・GlContext.java:96-99）。
- 解いた画像: `ImageData.PlatformImage`（key）で JS の ImageBitmap を持ち回し、`texImagePlatform(key)` で JS の中から直に GL へ。画素は wasm へ来ない。
- WebGPU の `device.queue.writeBuffer(buf, off, data, dataOffset, size)` と `writeTexture` は TypedArray の view を受けるので、**wasm memory 上の view を渡す今の方式がそのまま使える**【推】。`mapAsync` の読み戻しは非同期。

### TeaVM の版と出力

- **TeaVM 0.14.1**・出力は **WASM GC**（`-t wasm-gc -O 2 -d <dir> -f classes.wasm Main`）。JS 出力ではない（go/cmd_exportweb.go:285-286・go/exportweb_teavm.go:17 `const teavmVersion = "0.14.1"`・Makefile:798 `TEAVM_VERSION := 0.14.1`）。runtime は `org/teavm/backend/wasm/wasm-gc-runtime.js`（teavm-core の jar から取り出す・go/cmd_exportweb.go:1006）。TeaVM は JVM（`-Xmx6g` 既定・`FLIX_GE_TEAVM_XMX` で替える・:1254）で回す。
- jar 23 本を版と SHA-256 つきで固定（exportweb_teavm.go:27-51・Maven から取って照合・`FLIX_GE_TEAVM_DIR` で上書き）。
- **0.16.0 には `org.teavm.jso.webgpu`（101 クラス）が入っているが、`teavm-cli` の jar が無い**。tooling の API で回すと JDK 本物のクラスが流れ込んで 21 件の穴が出た（`VarHandle`・`LockSupport`・`ThreadContainers`）。CLI の「JDK を見せない ClassLoader」を組めば消える見込み【推】。copyOfRange の不具合が直ったかも【不明】（plans/engine-browser-spikes.md:73-75, 118-123・plans/engine-browser.md:295, 328）。決定 2 は「0.14.1 で始め、0.16 以降へは WebGPU のフェーズで上げる（その時に runner と shim を作り直す）」【確】。
- 0.14.1 の穴 4 つは手当て済み: `startVirtualThread`・`Arrays.copyOfRange`・`Heap.alloc`（64KiB の倍数で OutOfMemory・`DirectBuffers`）・classlib の欠け（shim 6 本）。バイトコードの付け替えは `fge.teavmfix.Rewrite`（ASM）。
- wasm の大きさ: game-starter 2.0MB・novel 2.9MB・rpg 6.2MB（gzip -9 で 1.35MB。plans/engine-browser-spikes.md:34）。`bench/scene3d` は 2D の入口 3.8MB・`withProject3d` 5.3MB（docs/backend-parity.md）。

---

## 4. `bin/fge export-web`（go/cmd_exportweb.go・1,259 行ほか `exportweb_*.go`）

### 手順（:195-340）

① ゲームを作業フォルダ（`<ゲーム>/build/web-export`）の `project/` へ写す（lib・build・artifact・saves・reference 等は除く）。`web/WebMain.flix` を `src/` へ入れ、**`build/engine_full_web` の fpkg と flix.toml を lib に置く**。`--check` は `flix check` だけ。
① `flix build-fatjar --entrypoint WebMain.main`（`-Xss64m`）。
② バイトコードの付け替え `fge.teavmfix.Rewrite`（fatjar → rewritten.jar）。
②' `web.embed` の素材を符号にして wasm へ埋め込む（`fge.teavmfix.Embed`）。
③ TeaVM（上の引数）。ERROR の行が 1 件でもあれば失敗。
④ アセットの束（bundle.json: files・sounds・images・splash・touch・deferred）。`web.compress`（WebP 化など）・`web.omit`・`web.embed`・`web.deferred`。
⑤ フォントアトラス（`font-bake` の事前生成）。
⑥ `index.html`・`fge-web.js`・`wasm-gc-runtime.js`・`classes.wasm`・`version.txt` を出力へ。index.html は版を確かめてから js を読む小さな起動役へ替える（置き先の index.html キャッシュ対策）。

### `engine_full_web` の正体

**生成物のパッケージ**（`build/engine_full_web`・Makefile:791-824 `sync-engine-full-web`）。`engine_full` と同じソースの木（`ROOT_SRC_PKGS` と `engine_full/src/full` を symlink で集める）に `engine_web/src/*.flix` を足し、flix.toml は `engine_full/flix.toml` に **fge-web の jar と TeaVM の JSO（jso・jso-apis・interop 0.14.1）の mvn 依存**を awk で足して作る。`fge-gl-*.jar` は消して手元の `GL_JAR` と `WEB_JAR` をコピー。`flix check` と `flix build-pkg` で fpkg を作る。LWJGL の依存は残る（Flix は届くか否かにかかわらず木の全部を型検査するので、LwjglLayer を組む時に LWJGL の jar が要る・配る wasm には入らない: plans/engine-browser.md:152）【確】。
目的: 描く手順の本体（`RenderPaint` など pub でない mod）を外から呼べない制約のため、**同じソースの木に web のファイルを足した 2 本目の束**にした（決定 5(a)・engine-browser.md:331）。デスクトップの engine_full・`flix check`・依存は 1 バイトも変えない。
【確】engine_web は「パッケージではなく engine_full_web の束に足すファイル群」。

### WebGPU の版を足す時に、今の作りから言える事【推】

- **入口の選択は現在ビルドの時**: `web/WebMain.flix` の字（`WebLayer.withProject(` か `WebLayer.withProject3d(`）をツールが読んで 3D の束かを決める（go/cmd_exportweb.go:376-378 `usesScene3dEntry`）。2D と 3D が wasm の大きさのために別の入口になっているのと同じ形で、**WebGL2 / WebGPU も別の入口（`WebLayer.withProject` と別の `WebGpuLayer.withProject…`）にすれば、使わない側のクラスは TeaVM が呼ばれない道として落とす**（WhyNot の理由と同じ: 呼ばれない道もたどる点だけ注意。Platform.flix:116 の Tasks の WhyNot が「ブラウザ版の書き出し（TeaVM）は呼ばれない道もたどるので、使わないゲームにまでスレッドの class が入る」と書く）。
- **1 つの束で起動時に選ぶ**なら、1 つの wasm に WebGL2 と WebGPU の両方の描き手（と ShaderGen の GLSL/WGSL 出力）が入る＝wasm が太る。JS 側（`navigator.gpu` の有無・`requestAdapter`）で選んで Flix の別の入口へ分ける形（`main` を引数で分けるか、`teavm.exports` を 2 本出す）になる。**今の `exports.main([])` は 1 本**（fge-web.js:1506）。
- **束を 2 つ作る**（`engine_full_web` を WebGL2 用・`engine_full_webgpu` を WebGPU 用）場合は、flix.toml の jar の足し方（awk）と `sync-engine-full-web` を複製することになる。「Flix のモジュールをビルドごとに差し替えない」決め（flix-conventions.md:206）の理由が「束ごとに別のファイルを組む手間・片方は普段の型検査を通らない」なので、**同じ木に両方の層のファイルを置いて入口だけ分ける**ほうが決めに合う【推】。
- いずれにしても **TeaVM 0.16 への更新（CLI が無い・runner と shim の作り直し）が WebGPU の前提**として決まっている（決定 2）。
- 書き出しにかかる時間の記録は **見当たらない**【不明】。docs・plans に「export-web が何秒」の数字は無かった（grep の範囲: plans/*.md・docs/*.md・go/cmd_exportweb.go）。`flix build-fatjar` と TeaVM の時間は書いていない。

---

## 5. 画面なしとテストの実装、門が GL の何に頼っているか

### 画面なしの描き手

| 物 | 場所 | 何か |
|---|---|---|
| `GlOffscreen` | render_gl/src/GlOffscreen.flix（701 行） | 隠しの GL（LWJGL）の FBO に塗る描き手。`handle(session, f)`（:380）が `RenderPaintHandlers.handleTarget/Diagnostics/Draw3d/Draw2d/GpuResources` を重ね、`Platform.runTasksInPlace`、`handleWindowless`（入力は何も押されない・窓は閉じない・dt = 1/60・注釈は書かない・`Display.desktop(design)`・`presentFrame` は何もしない）。`glLog#gl` は **`RecordingGl`（呼び出しを控える GlContext の包み）**。読み出しは `GL11.glReadPixels` を直に呼ぶ（GlContext を通らない）。**GL の文脈（LWJGL・GLFW の隠しウィンドウ）が必要** |
| `HeadlessLoad.handle` | engine_tools/src/HeadlessLoad.flix | `LoadProgress` の handler（知らせは捨てる・仕事は並列・絵は javax.imageio で解く）。`LoadProgress.runNoop` の代わり |
| `SoftRaster` | engine_tools/src/SoftRaster.flix（686 行）＋`SoftRaster/Internal`・`SoftRaster3d` | **CPU だけの描き手**。effect の handler ではなく、`DrawCmd` 等の描き物の列を直に画素へ描く関数（`SoftRaster.render`・`renderToImage`・`renderPass`…）。GL 不要。`HeadlessRender`（engine_tools/src/HeadlessRender.flix）が `RasterReq` を組んで呼ぶ。`SoftRaster3d` が 3D |
| 偽物の handler | `RenderTarget.runNoop`（RenderTarget.flix:117）・`Platform.runNoopDraw3d`（Platform.flix:136）・`LoadProgress.runNoop`・`Platform.runTasksInPlace` | 部品ごとの「何もしない」。ただし **usages の索引では `runNoop`・`runNoopDraw3d` を使う所が 0 件**（src・test とも）【確・索引の結果】。engine_world の純粋なテストは World/View を effect なしで走らせる形が主で、`Platform.Services` 全体の偽物は **見当たらない**【不明】（engine_world/test の中身は精読していない） |

つまり effect の handler の組を「GPU 無しで丸ごと」満たす実装は無い。画面なしでも GL を持つ（GlOffscreen）か、effect を通らず SoftRaster を直に呼ぶ（HeadlessRender）の 2 択。**WebGPU のために「effect の高さの 4 つ目の実装」を足してもテストの足場（GL 前提の GlOffscreen・CPU 直の SoftRaster）は壊れない**【推】。

### 門（`make release` が頼る物）

`RELEASE_GATES := release-guard studio-parity sync $(TEST) gl-parity`（Makefile:~932）。`release` = `release-verify`＝上の門を手元で通し、通した commit を `release/verified.txt` に書く。CI の `release-publish` は印を確かめるだけ（全量テストは CI で流し直さない・フォント差で CI ではずれる）。`.github/workflows` は `gl-jar.yml`・`release-gate.yml`（tag で `make sync`＝全パッケージのコンパイルだけ）・`release.yml`。

| 門 | 何に頼るか |
|---|---|
| `gl-parity`（bench/gl_parity） | **LWJGL の隠しウィンドウで GL を 1 コマずつ描き、同じ scene 宣言を SoftRaster でも描いて画素比較**。A 段階（バイト一致層）に不一致があれば exit 1。RELEASE_GATES に入る唯一の GL の門 |
| `gl-capture-check` | 実機の GL でテンプレの場面ごとの頭の 6 コマの SHA-256 を 2 回撮ってバイト比較＋基準（`bench/baseline/0.88.4`）と比較（同じ機械の時だけ）。隠しウィンドウ・`FLIX_GE_FIXED_DT`。release の門ではない |
| `smoke-devtools` | テンプレを隠しウィンドウの DEBUG で起こして名簿・命令口（/help /halt /step /resume /perf）・flow の記録を確かめる。GL の窓が要る。CI に載せない |
| `determinism` | 隠しウィンドウの DEBUG で台本（`testdata/determinism/*.flow`）を流し、書いた記録を画面なしで再生して指紋と World の要約が同じかを見る。窓を開くので CI に載せない |
| `shader-cache-soak` ほか bench | GL の隠しウィンドウ |
| `make test` | 各パッケージの flix test。render_gl・engine_world・engine_tools は `make sync-layers` で `.layers/<名前>` の中でテスト（memory: project_layers_test_workspace） |

### ブラウザ版の絵をデスクトップ版と比べる検査

- **あるが、門ではない手動の道具**【確】: `bin/fge web-capture <URL> <PNG>`（go/cmd_webcapture.go・go/internal/cdp・docs/web-capture.md）。ヘッドレス Chrome を CDP で動かし、頁が `readPixels` で返した画素を PNG にする（Node/Playwright 不使用）。頁の約束は `window.fgeCaptureReady`・`fgeCaptureError`・`fgeCapture()`。書き出した頁は `?capture=<n>`（canvas を design の大きさにして dt 固定 1/60・「押して始める」を飛ばし、n コマ目で読む）。デスクトップの `bin/gl-capture.sh`（`FLIX_GE_HIDDEN=1 FLIX_GE_FRAME_SHOT=<フォルダ> FLIX_GE_FIXED_DT=1/60`）の `frame-<n>.png` と同じコマになる。
- 実測（docs/backend-parity.md「ブラウザ（WebGL2）とデスクトップの絵」・2026-11-05・Chrome 156・ANGLE Metal（Apple M4 Pro））: `bench/scene3d` 320×180 の 1・2・3・6 コマ目は差 2/255 以下が 100.000%・一番大きい差 1/255。fps3d_lab の部屋 480×270 の 45・55・63 コマ目（msaa 4・Rgba16Float の Pass）は 99.938〜99.943%・一番大きい差 45/255。合格線は「RGB の差が 2/255 以下の画素が 99.9% 以上（cutout の縁は除く）」。ほかの機械・Safari・Windows・Android は未測定。
- docs/web-capture.md の「gl_parity とのつなぎ（案）」（`bench/gl_parity` に `web-run` を足して `debug/web/<scene>.png` を作り、SoftRaster・GL と並べる）は **案のまま**。`bench/gl_parity/Makefile` に web の語は 0 件【確】。つまり **ブラウザの絵の退行は release の門に入っていない**。
- 近似の表（backend-parity.md）: cutout の縁（WebGL2 に `SAMPLE_ALPHA_TO_ONE` が無く discard）・mipmap（GPU の `generateMipmap`・CPU の `Mip.build` と色が少し違う）・字（`font-bake` のアトラス）・textures は WebP。**WebGPU の 4 本目の描き手は、同じ表に「WebGPU」の列を足して管理する形が既にある**【推】。

### GL の何に頼っているか（まとめ）

- 門が実際に使う GL は **LWJGL の隠しウィンドウ（GL 3.3 core）だけ**。GlOffscreen・gl-parity・gl-capture・smoke-devtools・determinism の全部がそう。WebGPU を足しても、これらは GL のまま残る（デスクトップの描き手は GL 1 本）【推】。
- ブラウザを headless で開く検査は `web-capture` とその Go のテスト（`go/internal/cdp/testdata/webgl2_known.html` が既知の絵を描く頁・Chrome の無い機械と `-short` では飛ぶ）だけ。**`export-web` を CI/release の門が流している痕跡は無い**【確】（release-gate.yml は `make sync` のみ・Makefile の RELEASE_GATES に web 無し）。`go test` の `exportweb_*_test.go` は組み立ての部品の単体試験。

---

## 6. plans / docs にある今までの決め事（ブラウザ・コンシューマ・WebGPU）

### 「やらないと決めた事」と理由

| 決め | 出典 | 理由 |
|---|---|---|
| 描画は **WebGL2 が先で WebGPU は後**（ゴールの外・名前だけ残す） | plans/engine-browser.md:31-32, 58 | GL 3.3 の handler をほぼ写せる。ShaderGen は前に付ける文字列だけ。WebGPU の性能が要るのは 3D の重い場面だけ（plans/browser-spike.md §4）。「動く物を早く出す」が先 |
| WebGPU 版の ShaderGen は **GLSL と WGSL の 2 本出す（中間表現を挟む）**・書き直しは後回し | browser-spike.md 結論 7・§4・到達点 3 | 今の GLSL は `#version 330 core` の文字列連結（中間表現なし・全部で 19〜24 か所）。WGSL は印字する部分を丸ごと書き直し（uniform は bind group・sampler と texture を分ける）。使っている機能は `textureSize` 18・`glVertexAttribDivisor` 15・`fwidth` 9・UBO 8・sampler object 6・`readPixels` 4・`blitFramebuffer` 2・`texelFetch` 2・RGBA16F 1・DEPTH24 1・`glGetTexImage` 1・`glGenerateMipmap` 1 |
| **`GlContext` を WebGPU のために広げない**・GL の無い機種は `Platform.Services` の高さで自分の描き手を書く | docs/flix-conventions.md:204-205・engine-browser.md:295 | 「WebGPU は GL の形ではないので `GlContext` の隣に別の層が要る」。層は実装が 2 つ以上ある所にだけ置く |
| 機種の差を **ビルドの時にモジュールを差し替えて吸収しない** | flix-conventions.md:206・engine-browser.md:330 | 束ごとに別のファイルを組む手間・片方は普段の型検査を通らない・録る版（RecordingGl）が作れない。値の層（Java の非ジェネリックな interface）にした |
| ブラウザ 3D の範囲: **インスタンス描き・ブラウザの別スレッド・WebGPU・スマホ向けの速さの手当て・スマホの一人称の視点操作（iPhone に Pointer Lock が無い）をやらない** | plans/engine-browser-3d.md:9 | 軽い 3D（部屋 1 つ・モデル数十・影 1 つ）が動けばよい。2D の wasm の大きさを変えない |
| **TeaVM は 0.14.1 で始め、0.16 以降へは WebGPU のフェーズで上げる**（jar は版を固定） | engine-browser.md:328（決定 2）・spikes.md:118-123 | 0.14.1 は穴が 4 つで全部手当て済み。0.16 は CLI の jar が無く runner と shim の作り直しが要る（`org.teavm.jso.webgpu` 101 クラスは 0.16.0 にある） |
| ブラウザは **完成したゲームを配る出力先の 1 つ**・開発の道具（F8・RemoteDebug・Doc の監視・Studio・flow・ヒッチの記録・SceneRender・engine_tools）は外す | engine-browser.md:25-27 | 開発はデスクトップ |
| **context が失われたら頁の読み直し（最後のセーブから）**。呼び出しを控えて流し直す案 1 は実機で起きる回数を見てから | engine-browser.md（決定 8） | 軽い方から。案 1 は 1〜1.5 週 |
| 高いリフレッシュの画面は 60Hz に間引く（既定 60・project.json で変えられる） | engine-browser.md（決定 6）・AnimationFrame.waitTick | 電池 |
| 音は最初 wav のまま配る | 決定 7 | 変換の道具を増やさない |
| WebGL2 版の字は `ALPHA` 形式で上げる（シェーダーとデスクトップは変えない） | 決定 9 | デスクトップの字が変わるのを避ける |
| **コンシューマの切れ目は `Platform.Services` と Fs と `LoadProgress` の handler**（render_gl も `GlContext` も使わない）。コンシューマの切れ目は「GL の層でなく Draw2d/Draw3d の effect の高さ」 | flix-conventions.md:204・memory: project_platform_targets | GL の無い機種のために GlContext を広げない |
| engine_quality_review の評価: 「render_gl の GL の呼び出しが LWJGL の静的な関数に直に書かれ（2D で約 470 か所・Render3d で 255 か所）、層が無い」（→ その後 `GlContext` が入った）。機種はデスクトップの 3 つだけ・スマホ・家庭用機の道が無い | plans/engine-quality-review.md:237 | 比べ: Godot はデスクトップ・Android・iOS・Web（WASM・WebGL2）を公式に出せる。Bevy は WASM（WebGL2 / WebGPU）を公式に支え、描き手は wgpu の後ろ（同 :84）。LÖVE は描き手が `graphics/opengl`・`metal`・`vulkan` に分かれた |
| plans/engine-core-polish.md:339: 「描き手は GPU の 1 つ（WGSL を naga で写す）。GPU なしで…」 | plans/engine-core-polish.md | **C2（光の式の 1 本化）の検査の話。ここで言う WGSL は WebGPU の描き手ではなく、光の式を CPU（SoftRaster）と同じ物にするための道具の話**【推・該当の行だけ見た】 |

### 数字（ブラウザ・スマホ）

docs/performance.md にブラウザ・スマホの数字は **無い**（509 行の Tasks の記述のみ）。数字は plans/engine-browser-spikes.md と docs/backend-parity.md にある。

- wasm の読み込み: PC 15〜32ms・Android 1.3〜1.5 秒（rpg は 6MB を 4G で取った分を含む・rpg の起動 Doc から World が 1,179ms）。
- wasm の 1 コマ: 描き手込みで rpg の戦い 3.1〜3.3ms（p95 3.8ms）・world 3.2ms・ノベル 1.3ms。GL の呼び出しは 1 コマ 47 回・0.05ms。
- Android（Galaxy S24 Ultra・Adreno 750・Android 16・Chrome 156 の WebView）: wasm GC 使える・WebGL2・`MAX_TEXTURE_SIZE` 8192・rAF 8.30ms（120Hz）・`navigator.storage.persist` あり・`audioSession` なし。1 万個のインスタンスを毎コマ書いて上げて描く = 3.26ms（PC 0.93ms・3.5 倍）。内部 dungeon の 1 コマ（internet_dungeon）は PC の WASM 比 0.9〜2.0 倍（戦い 17.1ms）。**wasm は 16MB の上限のため 2 つに割って頁の中でつないだ試験**があった（spikes.md:193 付近）。
- 3D（backend-parity.md）: `bench/scene3d` 1.3 ms・fps3d_lab の部屋 16.6 ms（wasm の 1 コマの CPU の中央値）。デスクトップ GlContext の移し替え前後は p50 0.955 → 0.925 ms。
- memory（project_phone_3d_baseline）: fps3d-room で 46.5 fps・cpu 20.7 ms（S24 Ultra）。

### WebGPU の対応状況（plans/browser-spike.md §4）

Chrome / Edge 113+・Safari 26+・Firefox は Windows 141+ / macOS ARM 145+（Linux・Android の Firefox は途中）。到達点 3「3D と WebGPU（時期は未定）」: KTX2 / Basis・glb の圧縮・遅延読み込み。WebGPU の handler（WGSL）。ShaderGen に中間表現を挟み GLSL と WGSL の 2 本を出す。lightmap・skinning・HDR。
browser-spike.md 結論 6: 「WebGPU の基盤」はリポジトリに見当たらない（当時の確認）。差し替えの層は実在するが中身は Flix の effect。render_gl はそれを GL で handle する 1 実装にすぎない。

---

## 7. WebGPU の設計への含み（推測の整理）

【推】
1. **高さ**: `Platform.Services` に WebGPU の handler の組を足す。入口は `WebLayer.withProject` と別の `WebGpuLayer.withProject…`。`Window`・`Input`・`FrameClock`・`Audio`・`Tasks`・`LoadProgress`・`Fs` は WebLayer のものを共有できる（GL を触らない）。ここは `WebLayer` の `handleWindow`・`handleInput`・`handleAudio` などを GL 非依存の mod へ切り出す余地がある（今は WebLayer の private）。
2. **替わるのは**: `RenderPaintHandlers` の 5 本（`Draw2d.renderCommands/drawSurface`・`Draw3d.drawScene3d/preload3d`・`GpuResources` 7 本・`RenderTarget.Target` 3 本・`Diagnostics` 2 本）＝合計 19 操作。その下の `RenderPaint`（render_gl/src ≒ 1.1 万行・GL 呼び出しは Sprite 240・Render3d 165・Render3d/Material 72・Shader 66・Target 60・Shadow 56 …の概数）は GL 前提で、**WebGPU 版は別の描き手として書く**のが規約に沿う。`Scene3dRenderer.Renderer`（値）は 3D の描き手の差し替え点として既にある。
3. **そのまま使える**: effect が運ぶ値（`Drawable`・`TileMapRenderCmd`・`PolygonRenderCmd`・`StaticLayerCmd`・`SurfaceRenderCmd`・`Scene3d.RenderCmd/PreloadCmd`・`TargetSpec`・`Descriptor`）は GL の語を含まず wgpu の語彙に近い。`Format`・`LoadOp`・`samples` は wgpu 寄り。
4. **同期で返す物のうち WebGPU で性質が変わる**: `buildProgram` の fail-open（コンパイル成否が async）・`GpuResources.getTextureInfo` 等は CPU 登録簿なので問題なし・ブラウザ版は GPU 時間を計らない。読み戻し（`readTextureArgb`・capture の `readPixels`）は `mapAsync` で async。
5. **JS との境界**: `fgeH`（id → JS 物の表）と `@JSBody` の薄い呼び出しの方式を GPU の物にも使う。buffer は wasm memory の view を `queue.writeBuffer/writeTexture` へ渡す形がそのまま使える。TeaVM 0.16 の `org.teavm.jso.webgpu` を使うか自前の `@JSBody` かは未決（0.16 は CLI が無い）。
6. **context lost**: WebGL2 版と同じ「頁を読み直す」で足りる決め。`device.lost` を同じ `fgeError` へつなぐ。
7. **検査の足場**: SoftRaster と GL の突き合わせ（gl-parity）は手元の LWJGL 前提で、WebGPU の描き手の絵を比べる道は `web-capture`（`?capture=<n>`）を WebGPU 版の頁でも話せるようにするのが近い（頁の約束 `fgeCaptureReady`・`fgeCapture()` は描き手を問わない）。ただし `readPixels` に当たる読み戻しは `copyTextureToBuffer`＋`mapAsync`。ブラウザ版の絵の検査は **まだ release の門にない**。
8. **ビルド**: 入口を字で見分ける仕組み（`usesScene3dEntry`）を WebGPU の入口にも広げる。1 束 2 入口か 2 束かは §4 の整理のとおり。TeaVM を 0.16 へ上げる作業（runner・shim 作り直し）は前提。

---

## 参照した主なファイル（絶対パス）

- /Users/abab/Desktop/flix_game_engine/engine/src/platform/Platform.flix
- /Users/abab/Desktop/flix_game_engine/engine/src/platform/RenderTarget.flix
- /Users/abab/Desktop/flix_game_engine/engine/src/platform/GameEngine.flix（`eff Audio` 311-342）
- /Users/abab/Desktop/flix_game_engine/engine/src/platform/Display.flix
- /Users/abab/Desktop/flix_game_engine/engine/src/platform/LoadProgress.flix
- /Users/abab/Desktop/flix_game_engine/engine_web/src/{WebLayer,WebFs,WebAssets}.flix
- /Users/abab/Desktop/flix_game_engine/engine_web/java/fge/web/{WebGl2,AnimationFrame,Browser,…}.java
- /Users/abab/Desktop/flix_game_engine/engine_web/teavm/java/fge/teavmfix/*.java
- /Users/abab/Desktop/flix_game_engine/engine_web/js/fge-web.js・index.html
- /Users/abab/Desktop/flix_game_engine/render_gl/src/{PaintHandlers,LwjglLayer,GlOffscreen,Shader,Target}.flix・Render3d/*.flix
- /Users/abab/Desktop/flix_game_engine/render_gl/java/fge/gl/GlContext.java（178 行）
- /Users/abab/Desktop/flix_game_engine/engine_tools/src/{HeadlessLoad,HeadlessRender,SoftRaster}.flix
- /Users/abab/Desktop/flix_game_engine/go/{cmd_exportweb.go,exportweb_teavm.go,cmd_webcapture.go}・Makefile（791-960）
- /Users/abab/Desktop/flix_game_engine/docs/{flix-conventions,web-capture,backend-parity,performance}.md
- /Users/abab/Desktop/flix_game_engine/plans/{browser-spike,engine-browser,engine-browser-spikes,engine-browser-3d,engine-quality-review,engine-core-polish}.md
