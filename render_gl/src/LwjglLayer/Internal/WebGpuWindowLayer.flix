// LwjglLayer.Internal.WebGpuWindowLayer — 実機のウィンドウの WebGPU 版（既定の描き手。LwjglLayer.withLwjgl の枝）。
// device（Dawn）を先に開き、GLFW のウィンドウ（GLFW_NO_API）と surface を作ってから、塗りを RenderPaint.Internal.WebGpuPaint の handler で受ける。
// 音・仕事・時計・読み込みの知らせ・カーソル・入力は GL の枝と同じ物（LwjglLayer の pub でない物と LwjglInput）を使う。
// 開く前に落ちたら（Dawn のネイティブ・device・ウィンドウ）作った物を捨てて Err(理由) を返し、呼ぶ側が GL で起動する。
// FLIX_GE_WEBGPU_FAIL=native|device|window はその 3 つの道をわざと起こす（GL へ落ちる道の確かめ用。無ければ何もしない）。
// 隠して起動（FLIX_GE_HIDDEN）した時は GLFW の隠したウィンドウだけを作り、surface を作らず画面にも出さない（中間の texture は design の大きさ）。
// 描かない物: WebGpuPaint が知らせる物（足せなかった字など）。
pub mod LwjglLayer.Internal.WebGpuWindowLayer {
    import fge.webgpu.PresentMode
    import fge.webgpu.Surface
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import fge.webgpu.dawn.DawnWebGpu
    import org.lwjgl.glfw.Callbacks
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.glfw.GLFWFramebufferSizeCallbackI
    import org.lwjgl.glfw.GLFWNativeCocoa
    import org.lwjgl.system.MemoryUtil
    import java.awt.image.BufferedImage
    import java.io.File
    import java.lang.System
    import java.lang.Throwable
    import java.nio.ByteBuffer
    import javax.imageio.ImageIO
    use LwjglLayer.{announceFixedDt, applyFullscreen, applyMouseCaptured, closeAudio, cursorModeOf, frameShotLimit,
                    handleAudio, handleFrameClock, handleLoadProgress, handleTasks, openAudio, openCursors, saveAnnotationWith}
    use RenderPaint.Internal.WebGpuPaint

    /// 開いたウィンドウ。surface = 画面へ出す描き先（隠して起動した時は None）・format = その形式。
    type alias OpenedWindow = { window = Int64, surface = Option[Surface], format = TextureFormat }

    /// WebGPU で描くウィンドウを開いて f を回す。開く前に落ちたら作った物を捨てて Err(理由)（f はまだ呼んでいない）。
    /// GLFW は初期化済みであること（LwjglLayer.withLwjgl の頭）。env = withLwjgl の頭で読んだ環境変数。
    @DontInline
    pub def withWindow(config: GameEngine.EngineConfig, env: LwjglEnv.Settings, f: Unit -> a \ ef):
            Result[String, a] \ ef - Platform.Services - Platform.Annotation - LoadProgress + IO =
        let failMode = Map.get("FLIX_GE_WEBGPU_FAIL", LwjglEnv.snapshot()) |> Option.getWithDefault("");
        openDevice(failMode)
            |> Result.flatMap(dawn -> openWindowOrDestroy(dawn, config, env#hidden, failMode))
            |> Result.map(opened -> runWindow(config, env, fst(opened), snd(opened), f))

    /// ウィンドウを開く。開けなければ device を捨てて Err。
    def openWindowOrDestroy(dawn: DawnWebGpu, config: GameEngine.EngineConfig, hidden: Bool, failMode: String): Result[String, (DawnWebGpu, OpenedWindow)] \ IO =
        match openWindow(dawn, config, hidden, failMode) {
            case Ok(opened) => Ok((dawn, opened))
            case Err(why)   =>
                dawn.destroy();
                Err(why)
        }

    // ── 開く ──

    /// Dawn の device を開く。ネイティブを読めない・device を開けない・core-features-and-limits が無い時は Err。
    def openDevice(failMode: String): Result[String, DawnWebGpu] \ IO =
        if (failMode == "native") Err("Dawn のネイティブを読めない（FLIX_GE_WEBGPU_FAIL=native で起こした）")
        else {
            let opened = try { Ok(DawnWebGpu.open("")) } catch { case e: Throwable => Err(describeOpenFailure(e)) };
            opened |> Result.flatMap(dawn -> checkDevice(dawn, failMode))
        }

    /// 開いた device が使えるか（core-features-and-limits）。使えなければ捨てて Err。
    def checkDevice(dawn: DawnWebGpu, failMode: String): Result[String, DawnWebGpu] \ IO =
        let gpu: WebGpu = checked_cast(dawn);
        if (failMode == "device") {
            dawn.destroy();
            Err("device を開けない（FLIX_GE_WEBGPU_FAIL=device で起こした）")
        } else if (not gpu.hasCoreFeaturesAndLimits()) {
            dawn.destroy();
            Err("device に core-features-and-limits が無い")
        } else Ok(dawn)

    /// DawnWebGpu.open が投げた物を、ネイティブを読めない時と device を開けない時に分けて 1 行にする。
    // WhyNot: 例外の型だけで分けない — ネイティブの書き出しと初期化の失敗も IllegalStateException で来る。文の頭と、読めない時の型（LinkageError の類）で見る。
    // この見分けは DawnWebGpu と DawnNatives が投げる文（「ネイティブ」「jWebGPU」「この機種」）に頼っている。そちらの文を替えたら、ここも合わせる。
    def describeOpenFailure(e: Throwable): String \ IO =
        let className = e.getClass().getName();
        let message = if (Object.isNull(e.getMessage())) "" else e.getMessage();
        let native = String.contains({substr = "LinkageError"}, className) or String.contains({substr = "NoClassDefFound"}, className)
            or String.contains({substr = "ネイティブ"}, message) or String.contains({substr = "jWebGPU"}, message)
            or String.contains({substr = "この機種"}, message);
        if (native) "Dawn のネイティブを読めない（${e.toString()}）" else "device を開けない: ${e.toString()}"

    /// GLFW のウィンドウ（GLFW_NO_API）を作り、見せる時は surface も作る。作れなければウィンドウを壊して Err。
    // WhyNot: WebGpuWindow.open を使わない — 隠したウィンドウでも surface まで作り、壊す時に glfwTerminate まで呼ぶ（落ちた後に GL の枝で GLFW を使えない）。
    //   入力とカーソルに要る GLFW のウィンドウの番号も外へ出さない。
    def openWindow(dawn: DawnWebGpu, config: GameEngine.EngineConfig, hidden: Bool, failMode: String): Result[String, OpenedWindow] \ IO =
        GLFW.glfwDefaultWindowHints();
        GLFW.glfwWindowHint(GLFW.GLFW_CLIENT_API, GLFW.GLFW_NO_API);
        GLFW.glfwWindowHint(GLFW.GLFW_RESIZABLE, GLFW.GLFW_TRUE);
        if (hidden) {
            GLFW.glfwWindowHint(GLFW.GLFW_VISIBLE, GLFW.GLFW_FALSE);
            GLFW.glfwWindowHint(GLFW.GLFW_COCOA_RETINA_FRAMEBUFFER, GLFW.GLFW_FALSE)
        } else ();
        let (createW, createH) = if (hidden) (config#designWidth, config#designHeight) else (config#windowWidth, config#windowHeight);
        let window = GLFW.glfwCreateWindow(createW, createH, config#title, MemoryUtil.NULL, MemoryUtil.NULL);
        if (window == 0i64) Err("GLFW のウィンドウを作れない")
        else if (failMode == "window") {
            GLFW.glfwDestroyWindow(window);
            Err("ウィンドウを作れない（FLIX_GE_WEBGPU_FAIL=window で起こした）")
        } else if (hidden) Ok({ window = window, surface = None, format = TextureFormat.BGRA8_UNORM })
        else attachSurface(dawn, window)

    /// 見せるウィンドウに surface を付ける。形式が sRGB しか無い時は使わない（2D の道は 8 bit の値をそのまま書く）。
    def attachSurface(dawn: DawnWebGpu, window: Int64): Result[String, OpenedWindow] \ IO =
        let made = try {
            let surface = dawn.createMacSurface(GLFWNativeCocoa.glfwGetCocoaWindow(window));
            Ok(surface)
        } catch {
            case e: Throwable => Err("ウィンドウの描き先を作れない: ${e.toString()}")
        };
        match made {
            case Err(why) =>
                GLFW.glfwDestroyWindow(window);
                Err(why)
            case Ok(surface) =>
                let format = surface.preferredFormat();
                if (isSrgb(format)) {
                    surface.release();
                    GLFW.glfwDestroyWindow(window);
                    Err("画面の形式が sRGB（${format.toString()}）")
                } else Ok({ window = window, surface = Some(surface), format = format })
        }

    def isSrgb(format: TextureFormat): Bool \ IO =
        String.endsWith({suffix = "_SRGB"}, format.toString())

    def framebufferSizeOf(window: Int64): (Int32, Int32) \ IO =
        let w = Array.empty(Static, 1);
        let h = Array.empty(Static, 1);
        GLFW.glfwGetFramebufferSize(window, w, h);
        (Array.get(0, w), Array.get(0, h))

    def surfaceUsage(): Int32 = TextureUsage.RENDER_ATTACHMENT

    /// surface を mode で configure する。IMMEDIATE が誤りになる時は FIFO で configure し直して 1 回知らせる。返すのは使った mode。
    // WhyNot: surface の capabilities から present mode を選ばない — WebGpu の interface（Surface）に capabilities を引く口が無く、足すと GL の層の jar のハッシュが動く。
    //   configure の後の誤りの数で見るのは、Dawn が使えない present mode を検証の誤りとして数える前提に乗っている。
    def configureSurface(gpu: WebGpu, surface: Surface, format: TextureFormat, size: (Int32, Int32), mode: PresentMode,
                         warned: Ref[Bool, Static]): PresentMode \ IO =
        let (w, h) = size;
        let before = gpu.errorCount();
        surface.configure(w, h, format, mode, surfaceUsage());
        if (gpu.errorCount() == before or isFifo(mode)) mode
        else {
            surface.configure(w, h, format, PresentMode.FIFO, surfaceUsage());
            if (Ref.get(warned)) () else {
                Ref.put(true, warned);
                println("[backend] webgpu: IMMEDIATE の present を使えない — FIFO のまま（垂直同期を待つ）")
            };
            PresentMode.FIFO
        }

    def isFifo(mode: PresentMode): Bool \ IO =
        let fifo = PresentMode.FIFO;
        mode.ordinal() == fifo.ordinal()

    // ── 読み込み（3.1 の PC の道）──

    /// project.json の絵を GL と同じ読み込み（LwjglAssets.loadTexture）で解いて WebGPU へ上げ、名前で引けるようにする。
    /// onProgress = 読み終えた枚数・全部の枚数（起動画面が進み具合を出す）。
    pub def loadTextures(paint: WebGpuPaint.Paint, manifest: List[RenderAsset.TextureEntry], onProgress: (Int32, Int32) -> Unit \ IO): Unit \ IO =
        let total = List.length(manifest);
        onProgress(0, total);
        let uploads = WebGpuPaint.webGpuUploads(paint);
        List.forEachWithIndex((i, entry) -> {
            let info = LwjglAssets.loadTexture(uploads, entry#path, entry#hasAlpha);
            WebGpuPaint.putTexture(entry#name, info, paint);
            println("  ${entry#path} loaded (${info#width}x${info#height})");
            onProgress(i + 1, total)
        }, manifest)

    /// project.json のフォントを、GL と同じ RenderFontCache.startupLoader で作り、距離場を R8 で上げる。
    /// 起動の後に出た字は GL と同じ RenderGlyphGrow で作り、R8 の絵の空いた所へ書き足す。
    pub def loadFonts(paint: WebGpuPaint.Paint, config: GameEngine.EngineConfig, progress: (String, Int32, Int32) -> Unit \ IO): RenderPaint.Fonts \ IO =
        let load = RenderFontCache.startupLoader(config#rootDir, config#glyphs);
        println("Baking font atlases...");
        let growTable = RenderGlyphGrow.newTable();
        let atlases = config#fontManifest |> List.foldLeft((acc, entry) -> {
            let phase = "loading font ${entry#name}...";
            let baked = load(entry, (done, total) -> progress(phase, done, total));
            let info = WebGpuPaint.uploadR8(paint, baked#side, baked#side, baked#pixels);
            WebGpuPaint.putTexture(baked#atlas#textureName, info, paint);
            RenderGlyphGrow.register(growTable, baked#atlas, { path = entry#path, texId = GpuHandle.textureIdInt(info#id) });
            println("  Font '${entry#name}' baked (${baked#atlas#textureName})");
            Map.insert(entry#name, baked#atlas, acc)
        }, Map#{BootFont.name() => BootFont.atlas()});
        let writer = glyphWriter(paint);
        { atlases = Ref.fresh(Static, atlases), grow = (atlas, cps) -> RenderGlyphGrow.ensureWith(writer, growTable, atlas, cps),
          missing = Ref.fresh(Static, Set.empty()) }

    /// 足す字を、register で控えた絵の番号（begin で受ける）の R8 の絵へ書く口。
    def glyphWriter(paint: WebGpuPaint.Paint): RenderGlyphGrow.Writer \ IO =
        let slot = Ref.fresh(Static, 0);
        { begin = id -> checked_ecast(Ref.put(id, slot)),
          put = (x, y, w, h, pixels) -> WebGpuPaint.writeR8Region(paint, Ref.get(slot), x, y, w, h, pixels),
          finish = () -> checked_ecast(()) }

    // ── 回す ──

    /// 画面へ出す所の状態。screenPainted = 前の presentFrame の後に画面へ描いたコマの描き始めと描き終わりと 2D の数（無ければ None）。
    /// errorsSeen = 知らせ終えた WebGPU の誤りの数。
    type alias PresentState = {
        gpu = WebGpu, paint = WebGpuPaint.Paint, opened = OpenedWindow, size = Array[(Int32, Int32), Static],
        presentMode = Ref[PresentMode, Static], frameStats = Option[RenderFrameStats.Stats], frameShotDir = Option[String],
        frameShotTaken = Array[Int32, Static], screenPainted = Ref[Option[(Int64, Int64, Unit -> FrameDiagnostics.Draw2dCounts \ IO)], Static],
        errorsSeen = Ref[Int32, Static]
    }

    /// Platform.Window の handler の状態（GL の枝の WindowState と同じ欄に、垂直同期の切り替えと画面へ出す所）。
    type alias WindowState = {
        window = Int64, config = GameEngine.EngineConfig, looping = Array[Bool, Static], devices = LwjglInput.Devices, design = Vec2.Vec2,
        cursors = GameEngine.Cursor -> Int64, lastCursor = Array[GameEngine.Cursor, Static],
        mouseCaptured = Array[Bool, Static], cursorVisible = Array[Bool, Static],
        fullscreen = Array[Bool, Static], originalWindowRect = Array[(Int32, Int32, Int32, Int32), Static],
        onLoopStart = Unit -> Unit \ IO, present = PresentState
    }

    @DontInline
    def runWindow(config: GameEngine.EngineConfig, env: LwjglEnv.Settings, dawn: DawnWebGpu, opened: OpenedWindow,
                  f: Unit -> a \ ef): a \ ef - Platform.Services - Platform.Annotation - LoadProgress + IO =
        let gpu: WebGpu = checked_cast(dawn);
        let window = opened#window;
        println("[backend] webgpu: ${gpu.adapterInfo()}");
        announceFixedDt(env#fixedDt, config#maxDeltaTime);
        let hidden = env#hidden;
        let fbSize = if (hidden) (config#designWidth, config#designHeight) else framebufferSizeOf(window);
        println("Framebuffer size: ${fst(fbSize)}x${snd(fbSize)}");
        let sizeHolder = Array#{fbSize} @ Static;
        let warnedImmediate = Ref.fresh(Static, false);
        // 読み込みの間は画面の垂直同期を待たない（GL の枝の glfwSwapInterval(0) と同じ所）。
        let presentMode = Ref.fresh(Static, PresentMode.IMMEDIATE);
        Option.forEach(s -> Ref.put(configureSurface(gpu, s, opened#format, fbSize, PresentMode.IMMEDIATE, warnedImmediate), presentMode), opened#surface);
        let paint = WebGpuPaint.withGpuTimer(WebGpuPaint.create(gpu, { designWidth = config#designWidth, designHeight = config#designHeight,
                                              clearColor = config#clearColor, width = fst(fbSize), height = snd(fbSize),
                                              scene3d = Render3d.WebGpuRenderer.makeScenes }));
        let frameStats = if (env#frameStats) Some(RenderFrameStats.fresh()) else None;
        let present = { gpu = gpu, paint = paint, opened = opened, size = sizeHolder, presentMode = presentMode, frameStats = frameStats,
                        frameShotDir = env#frameShotDir, frameShotTaken = Array#{0} @ Static, screenPainted = Ref.fresh(Static, None),
                        errorsSeen = Ref.fresh(Static, 0) };
        // macOS は端を掴んでいる間 pollEvents が戻らないので、その間の絵は大きさが変わった callback で描き直す。読み込みを始める前に付ける。
        // WhyNot: 隠したウィンドウで受けない — 中間の texture は design の大きさに固定している。
        if (hidden) () else {
            discard GLFW.glfwSetFramebufferSizeCallback(window, new GLFWFramebufferSizeCallbackI {
                def invoke(_this: GLFWFramebufferSizeCallbackI, _cbWindow: Int64, width: Int32, height: Int32): Unit \ IO =
                    if (width <= 0 or height <= 0) ()
                    else {
                        Array.put((width, height), 0, sizeHolder);
                        Option.forEach(s -> Ref.put(configureSurface(gpu, s, opened#format, (width, height), Ref.get(presentMode), warnedImmediate), presentMode), opened#surface);
                        WebGpuPaint.resize(paint, width, height);
                        WebGpuPaint.repaintLast(paint);
                        discard showOnScreen(present)
                    }
            })
        };
        let design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) };
        let polledAt = Array#{0i64} @ Static;
        // 起動画面: 描いたコマは控えに残るので、読み込み中にウィンドウの大きさを変えても描き直せる。
        let drawSplash = (ds: List[GameEngine.Drawable]) -> {
            WebGpuPaint.handleDraw2d(paint, (_, _, _) -> (), () -> Platform.Draw2d.renderCommands(ds, Nil, Nil, Nil));
            discard showOnScreen(present);
            GLFW.glfwPollEvents();
            Array.put(System.nanoTime(), 0, polledAt)
        };
        let splashState = RenderSplash.newState();
        let splash = (phase: String, done: Int32, total: Int32) -> RenderSplash.tick(splashState, drawSplash, design, phase, done, total);
        RenderSplash.show(splashState, drawSplash, design, "starting up...", 0, 0);
        println("Loading textures...");
        loadTextures(paint, config#textureManifest, (done, total) -> splash("loading images...", done, total));
        let fonts = loadFonts(paint, config, splash);
        RenderSplash.show(splashState, drawSplash, design, "starting audio...", 0, 0);
        let audio = openAudio(config, env#muted, splash);
        RenderSplash.show(splashState, drawSplash, design, "preparing game...", 0, 0);
        let looping = Array#{false} @ Static;
        let cursors = openCursors();
        let devices = LwjglInput.open(window, design);
        let windowState = {
            window = window, config = config, looping = looping, devices = devices, design = design,
            cursors = cursors#lookup, lastCursor = Array#{(GameEngine.Cursor.Default: GameEngine.Cursor)} @ Static,
            mouseCaptured = Array#{false} @ Static, cursorVisible = Array#{true} @ Static,
            fullscreen = Array#{false} @ Static, originalWindowRect = Array#{originalRectOf(window, config)} @ Static,
            onLoopStart = () -> {
                // WhyNot: 隠したウィンドウでは垂直同期に戻さない — surface が無く、画面に出さない。
                let mode = if (env#noVsync) PresentMode.IMMEDIATE else PresentMode.FIFO;
                Option.forEach(s -> Ref.put(configureSurface(gpu, s, opened#format, Array.get(0, sizeHolder), mode, warnedImmediate), presentMode), opened#surface)
            },
            present = present
        };
        let timeHolder = Array#{System.nanoTime()} @ Static;
        let result =
            handleLoadProgress({ looping = looping, splash = splash, polledAt = polledAt, devices = devices }, () ->
            handleAudio(audio#state, () ->
            WebGpuPaint.handleTarget(paint, () ->
            handleAnnotation(config, design, audio#shutterSource, present, () ->
            WebGpuPaint.handleDiagnostics(paint, () ->
            handleTasks(() ->
            WebGpuPaint.handleDraw3d(LwjglEnv.isPreloadAhead(env), paint, () ->
            handleFrameClock({ fixedDt = env#fixedDt, maxDeltaTime = config#maxDeltaTime, last = timeHolder }, () ->
            handleWindow(windowState, () ->
            WebGpuPaint.handleDraw2d(paint, (paintFrom, paintTo, counts) -> Ref.put(Some((paintFrom, paintTo, counts)), present#screenPainted), () ->
            LwjglInput.handleInput(devices, () ->
            WebGpuPaint.handleGpuResources(paint, fonts, f))))))))))));
        List.forEach(c -> GLFW.glfwDestroyCursor(c), cursors#handles);
        closeAudio(audio);
        LwjglInput.close(devices);
        Callbacks.glfwFreeCallbacks(window);
        Option.forEach(s -> s.release(), opened#surface);
        GLFW.glfwDestroyWindow(window);
        WebGpuPaint.release(paint);
        gpu.destroy();
        GLFW.glfwTerminate();
        result

    /// フルスクリーンから戻す時の、起動時のウィンドウの位置と大きさ。
    def originalRectOf(window: Int64, config: GameEngine.EngineConfig): (Int32, Int32, Int32, Int32) \ IO =
        let x = Array.empty(Static, 1);
        let y = Array.empty(Static, 1);
        GLFW.glfwGetWindowPos(window, x, y);
        (Array.get(0, x), Array.get(0, y), config#windowWidth, config#windowHeight)

    /// 描いたコマを締めて画面へ出す（隠して起動した時は submit だけ）。返すのは画面へ出すのに掛かった時間（getCurrentTexture から present まで）。
    def showOnScreen(ps: PresentState): Int64 \ IO =
        match ps#opened#surface {
            case None =>
                WebGpuPaint.present(ps#paint, None);
                0i64
            case Some(surface) =>
                let shownFrom = System.nanoTime();
                let texture = surface.getCurrentTexture();
                if (Object.isNull(texture)) {
                    WebGpuPaint.present(ps#paint, None);
                    0i64
                } else {
                    WebGpuPaint.present(ps#paint, Some(texture));
                    surface.present();
                    System.nanoTime() - shownFrom
                }
        }

    /// FrameStats の行の終わりに足す submit の回数（前に出した行の後のコマで、2 回以上だったコマの数と一番多い回数）。
    def submitsText(counts: { frames = Int32, twoOrMore = Int32, most = Int32 }): String =
        "・submits 2 回以上 ${Int32.toString(counts#twoOrMore)}/${Int32.toString(counts#frames)} コマ（最大 ${Int32.toString(counts#most)}）"

    /// 前の presentFrame の後に画面へ描いたコマがあれば、画面へ出し、撮る口と FrameStats に渡す（無ければ何もしない）。
    def presentIfPainted(ps: PresentState): Unit \ IO =
        match Ref.get(ps#screenPainted) {
            case None => ()
            case Some((paintFrom, paintTo, counts)) =>
                Ref.put(None, ps#screenPainted);
                discard showOnScreen(ps);
                Option.forEach(stats -> RenderFrameStats.record(stats, paintFrom, paintTo, counts,
                                                                () -> submitsText(WebGpuPaint.takeSubmitCounts(ps#paint)) + GpuTimer.samplesText(WebGpuPaint.takeGpuSamples(ps#paint))), ps#frameStats);
                noteNewErrors(ps);
                frameShot(ps)
        }

    /// 前に知らせた時より WebGPU の誤りが増えていたら、増えた数と最後の誤りの文を 1 行出す。
    // WhyNot: 誤りを数えるだけで黙らない — 検証の誤りは絵を欠けさせるだけで止まらず、外から気づけない。
    // WhyNot: device lost を受けない — Dawn の device lost の callback を jWebGPU から取れるかを確かめていない（plans/webgpu-v1.md）。submit の誤りの数で気づく。
    def noteNewErrors(ps: PresentState): Unit \ IO =
        let now = ps#gpu.errorCount();
        let seen = Ref.get(ps#errorsSeen);
        if (now <= seen) ()
        else {
            Ref.put(now, ps#errorsSeen);
            Log.warn("[webgpu] WebGPU の誤りが ${Int32.toString(now - seen)} 個増えた（合わせて ${Int32.toString(now)} 個）: ${ps#gpu.lastError()}")
        }

    /// FLIX_GE_FRAME_SHOT の撮る口（GL の LwjglLayer.frameShot と同じ数え方・同じ PNG の形）。中間の texture から読む。
    def frameShot(ps: PresentState): Unit \ IO =
        let count = Array.get(0, ps#frameShotTaken);
        match ps#frameShotDir {
            case Some(dir) if count < frameShotLimit() =>
                Array.put(count + 1, 0, ps#frameShotTaken);
                writeShot(frameImage(ps), "${dir}/frame-${count + 1}.png")
            case _ => ()
        }

    /// 最後に描いたコマ（中間の texture）を左上原点の ARGB の画像にする。
    def frameImage(ps: PresentState): BufferedImage \ IO =
        let (w, h) = Array.get(0, ps#size);
        let pixels = ByteBuffer.allocateDirect(w * h * 4);
        WebGpuPaint.readFrame(ps#paint, pixels);
        imageOf(pixels, w, h)

    /// RGBA（下の行から）を左上原点の ARGB の画像にする。
    // WhyNot: GlReadback.readBoundPng を呼ばない — bind 中の GL のフレームバッファを読む関数で、WebGPU の画素を渡す口が無い。画素の並べ方と PNG の形は同じにする。
    pub def imageOf(pixels: ByteBuffer, w: Int32, h: Int32): BufferedImage \ IO = region rc {
        let image = new BufferedImage(w, h, 2i32);
        let argb: Array[Int32, rc] = Array.empty(rc, w * h);
        List.forEach(y -> {
            let srcRowStart = (h - 1 - y) * w;
            putRow(pixels, srcRowStart * 4, argb, y * w, w, 0)
        }, List.range(0, h));
        image.setRGB(0, 0, w, h, argb, 0, w);
        image
    }

    /// 画像を PNG に書く（フォルダが無ければ作る）。
    def writeShot(image: BufferedImage, path: String): Unit \ IO =
        let file = new File(path);
        let parent = file.getParentFile();
        if (not Object.isNull(parent)) discard parent.mkdirs() else ();
        discard ImageIO.write(image, "png", file)

    /// RGBA の 1 行（fromByte バイトから）を ARGB の int の列（toIndex から）へ並べる。
    def putRow(pixels: ByteBuffer, fromByte: Int32, argb: Array[Int32, r], toIndex: Int32, w: Int32, x: Int32): Unit \ r + IO =
        if (x >= w) ()
        else {
            let at = fromByte + x * 4;
            let red = Int32.bitwiseAnd(Int8.toInt32(pixels.get(at)), 255);
            let green = Int32.bitwiseAnd(Int8.toInt32(pixels.get(at + 1)), 255);
            let blue = Int32.bitwiseAnd(Int8.toInt32(pixels.get(at + 2)), 255);
            let alpha = Int32.bitwiseAnd(Int8.toInt32(pixels.get(at + 3)), 255);
            Array.put(alpha * 16777216 + red * 65536 + green * 256 + blue, toIndex + x, argb);
            putRow(pixels, fromByte, argb, toIndex, w, x + 1)
        }

    /// F8 の注釈を GL の枝と同じ形で書く。画面の絵は最後に描いたコマ（中間の texture）を読む。
    // WhyNot: GL の枝のように最後のコマを塗り直さない — 中間の texture は画面へ出した後もそのコマを持っている。
    def handleAnnotation(config: GameEngine.EngineConfig, design: Vec2.Vec2, shutterSource: Int32, ps: PresentState,
                         f: Unit -> a \ ef): a \ (ef - Platform.Annotation) + IO =
        run f() with handler Platform.Annotation {
            def saveAnnotation(req, k) = k(saveAnnotationWith(config, design, shutterSource, () -> frameImage(ps), req))
        }

    /// Platform.Window を GLFW のウィンドウで受ける（カーソル・キャプチャ・フルスクリーンは GL の枝と同じ関数）。
    def handleWindow(ws: WindowState, f: Unit -> a \ ef): a \ (ef - Platform.Window) + IO =
        let window = ws#window;
        let config = ws#config;
        run f() with handler Platform.Window {
            def pollEvents(k) = {
                if (not Array.get(0, ws#looping)) {
                    Array.put(true, 0, ws#looping);
                    ws#onLoopStart()
                } else ();
                LwjglInput.poll(ws#devices);
                k(())
            }
            def shouldClose(k) = k(GLFW.glfwWindowShouldClose(window))
            def setShouldClose(close, k) = {
                GLFW.glfwSetWindowShouldClose(window, close);
                k()
            }
            def getViewportRect(k) = k({ position = Vec2.zero(), size = ws#design })
            def getDisplay(k) = k(LwjglInput.displayOf(window, ws#design))
            def presentFrame(k) = {
                presentIfPainted(ws#present);
                k(())
            }
            def setCursor(cursor, k) = {
                if (Array.get(0, ws#lastCursor) != cursor) {
                    GLFW.glfwSetCursor(window, (ws#cursors)(cursor));
                    Array.put(cursor, 0, ws#lastCursor)
                } else ();
                k(())
            }
            def setCursorVisible(visible, k) = {
                Array.put(visible, 0, ws#cursorVisible);
                if (Array.get(0, ws#mouseCaptured)) () else GLFW.glfwSetInputMode(window, GLFW.GLFW_CURSOR, cursorModeOf(visible));
                k(())
            }
            def setMouseCaptured(captured, k) = {
                applyMouseCaptured(window, ws#devices, ws#mouseCaptured, ws#cursorVisible, captured);
                k(())
            }
            def setFullscreen(on, k) = {
                applyFullscreen(window, config, ws#fullscreen, ws#originalWindowRect, on);
                k(())
            }
            def isFullscreen(k) = k(Array.get(0, ws#fullscreen))
            def setDebugBadge(enabled, k) = {
                GLFW.glfwSetWindowTitle(window, if (enabled) "${config#title} (Debug)" else config#title);
                k(())
            }
        }
}
