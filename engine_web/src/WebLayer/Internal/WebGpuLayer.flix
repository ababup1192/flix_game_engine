// WebLayer.Internal.WebGpuLayer — ブラウザ版の WebGPU で描く頁（既定。?backend=webgl2 で開いた頁と navigator.gpu の無い頁は使わない）の handler 一式。塗りは RenderPaint.Internal.WebGpuPaint の handler で受け、
// 音・時計・入力・読み込みの知らせは WebLayer の WebGL2 の頁と同じ物を使う。
// 落ちうる準備（device・core-features-and-limits・pipeline・絵とフォントを上げる・中間の texture）を全部 canvas の webgpu の文脈を取る前に済ませ、
// その前に落ちたら作った物を捨てて Err(理由) を返す（呼ぶ側が WebGL2 の文脈を取って GL で描く）。
// 絵は頁が解いた ImageBitmap を BrowserWebGpu.copyImageBitmap で RGBA にして上げる（hasAlpha が偽なら alpha を 255 で埋める）。
// フォントは書き出しが事前生成したアトラス（RenderFontCache の形式）を R8 で上げる。起動の後に出た字は足さない（WebGpuPaint が欠けの表に「起動の後に足せなかった字」と数える）。
// ?capture=<n> は n コマ目の中間の texture を読んで Browser.publishCapture に置く（renderer は "webgpu: <adapter>"）。
pub mod WebLayer.Internal.WebGpuLayer {
    import fge.web.AnimationFrame
    import fge.web.AssetTable
    import fge.web.Browser
    import fge.web.Deferred
    import fge.web.Pointer
    import fge.web.WebImages
    import fge.web.webgpu.BrowserWebGpu
    import fge.webgpu.PresentMode
    import fge.webgpu.Surface
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import java.lang.Throwable
    import java.nio.ByteBuffer
    use RenderPaint.Internal.WebGpuPaint
    use WebLayer.{FullscreenAsk, State, applyCursor, display, freshState, handleAudio, handleFrameClock, handleInput,
                  handleLoadProgress, playArrivedSounds, registerArrivedFont, showProgress, tickRate}

    /// 画面へ出す所の状態。size = 今の描き先（canvas）の画素の大きさ・drawn = 画面へ出したコマの数（?capture の数え）。
    type alias Screen = {
        gpu = BrowserWebGpu, paint = WebGpuPaint.Paint, surface = Surface, format = TextureFormat,
        size = Ref[(Int32, Int32), Static], drawn = Ref[Int32, Static], captureFrame = Int32
    }

    /// WebGPU で描く頁を起動して f を回す。canvas の webgpu の文脈を取る前に落ちたら Err(理由)（f はまだ呼んでいない）。
    @DontInline
    pub def withWeb(config: GameEngine.EngineConfig, f: Unit -> a \ ef): Result[String, a] \ ef - Platform.Services - LoadProgress + IO =
        Browser.setTitle(config#title);
        match openDevice() {
            case Err(why) => Err(why)
            case Ok(gpu)  => prepare(config, gpu, f)
        }

    /// adapter と device を取る。WebGPU の無いブラウザ・取れない時・core-features-and-limits が無い時は Err。
    def openDevice(): Result[String, BrowserWebGpu] \ IO =
        let opened = try { Ok(BrowserWebGpu.open()) } catch { case e: Throwable => Err("device を開けない: ${e.toString()}") };
        match opened {
            case Err(why) => Err(why)
            case Ok(gpu)  =>
                if (gpu.hasCoreFeaturesAndLimits()) Ok(gpu)
                else {
                    gpu.destroy();
                    Err("device に core-features-and-limits が無い")
                }
        }

    /// 塗りのコアを作り、絵とフォントを上げ、誤りが無ければ canvas に描き先を作って f を回す。落ちたら作った物を捨てて Err。
    /// 頁の ?webgpuFail=prepare|canvas は、webgpu の文脈を取る前・取った後に落ちる道を起こす（GL へ落ちる道の確かめ用。無ければ何もしない）。
    @DontInline
    def prepare(config: GameEngine.EngineConfig, gpu: BrowserWebGpu, f: Unit -> a \ ef): Result[String, a] \ ef - Platform.Services - LoadProgress + IO =
        let design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) };
        let state = freshState(config, design);
        let size = (Int32.max(1, Browser.canvasWidth()), Int32.max(1, Browser.canvasHeight()));
        let queryPairs = Array.toList(Browser.queryPairs());
        let failMode = queryValueOf("webgpuFail", queryPairs);
        let ready = prepareAssets(config, gpu, size, showProgress(state), failMode)
            |> Result.flatMap(assets -> attachOrRelease(gpu, assets, size, failMode));
        match ready {
            case Err(why) =>
                gpu.destroy();
                Err(why)
            case Ok((paint, fonts, surface, format)) =>
                Ref.put(config#textureManifest |> List.filter(e -> Deferred.isDeferred(e#path) and Deferred.state(e#path) != "loaded"), state#pendingTextures);
                Ref.put(WebAssets.pendingFontsOf(config#fontManifest), state#pendingFonts);
                let screen = { gpu = gpu, paint = paint, surface = surface, format = format, size = Ref.fresh(Static, size),
                               drawn = Ref.fresh(Static, 0),
                               captureFrame = queryValueOf("capture", queryPairs) |> Int32.fromString |> Option.getWithDefault(0) };
                Ok(runPage(state, screen, fonts, f))
        }

    /// 塗りのコア（pipeline）を作り、絵とフォントを上げ、誤りの数を見る（全部 canvas の webgpu の文脈を取る前）。落ちたら塗りのコアを手放して Err。
    def prepareAssets(config: GameEngine.EngineConfig, gpu: BrowserWebGpu, size: (Int32, Int32),
                      progress: (String, Int32, Int32) -> Unit \ IO, failMode: String): Result[String, (WebGpuPaint.Paint, RenderPaint.Fonts)] \ IO =
        let webGpu: WebGpu = checked_cast(gpu);
        let made: Ref[Option[WebGpuPaint.Paint], Static] = Ref.fresh(Static, None);
        let outcome = try {
            let paint = WebGpuPaint.create(webGpu, { designWidth = config#designWidth, designHeight = config#designHeight,
                                                     clearColor = config#clearColor, width = fst(size), height = snd(size) });
            Ref.put(Some(paint), made);
            println("Loading textures...");
            loadTextures(gpu, paint, config#textureManifest, (done, total) -> progress("loading images...", done, total));
            let fonts = loadFonts(paint, config#fontManifest, progress);
            let errors = webGpu.errorCount();
            if (failMode == "prepare") Err("準備で落ちた（?webgpuFail=prepare で起こした）")
            else if (errors > 0) Err("準備で WebGPU の誤りが ${Int32.toString(errors)} 個（${webGpu.lastError()}）")
            else Ok((paint, fonts))
        } catch {
            case e: Throwable => Err("準備で落ちた: ${e.toString()}")
        };
        if (Result.isErr(outcome)) Option.forEach(WebGpuPaint.release, Ref.get(made)) else ();
        outcome

    /// canvas に描き先を作る。作れなければ塗りのコアを手放して Err。
    def attachOrRelease(gpu: BrowserWebGpu, assets: (WebGpuPaint.Paint, RenderPaint.Fonts), size: (Int32, Int32), failMode: String):
            Result[String, (WebGpuPaint.Paint, RenderPaint.Fonts, Surface, TextureFormat)] \ IO =
        let (paint, fonts) = assets;
        let attached = attachCanvas(gpu, size)
            |> Result.flatMap(sf -> if (failMode == "canvas") Err("canvas の描き先を作った後に落ちた（?webgpuFail=canvas で起こした）") else Ok(sf));
        match attached {
            case Ok((surface, format)) => Ok((paint, fonts, surface, format))
            case Err(why) =>
                WebGpuPaint.release(paint);
                Err(why)
        }

    /// canvas（fge-canvas）の webgpu の文脈を取って configure する。これより後に落ちた時は、同じ canvas から WebGL2 を取れない。
    def attachCanvas(gpu: BrowserWebGpu, size: (Int32, Int32)): Result[String, (Surface, TextureFormat)] \ IO =
        try {
            let surface = gpu.createCanvasSurface("fge-canvas");
            let format = surface.preferredFormat();
            surface.configure(fst(size), snd(size), format, PresentMode.FIFO, TextureUsage.RENDER_ATTACHMENT);
            Ok((surface, format))
        } catch {
            case e: Throwable => Err("canvas の描き先を作れない: ${e.toString()}")
        }

    /// 頁の URL のクエリ（[鍵1, 値1, 鍵2, 値2, …]）の key の値（無ければ空）。
    def queryValueOf(key: String, flat: List[String]): String = match flat {
        case k :: value :: rest => if (k == key) value else queryValueOf(key, rest)
        case _                  => ""
    }

    @DontInline
    def runPage(state: State, screen: Screen, fonts: RenderPaint.Fonts, f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO =
        let paint = screen#paint;
        screen#gpu.onDeviceLost();
        println("[backend] webgpu: ${screen#gpu.adapterInfo()}");
        let onPoll = () -> { registerArrivedTextures(screen#gpu, paint, state); registerArrivedFont(entry -> uploadAtlas(paint, entry), fonts, state); playArrivedSounds(state) };
        let result =
            handleLoadProgress(state, () ->
            handleAudio(state, () ->
            WebGpuPaint.handleTarget(paint, () ->
            WebGpuPaint.handleDiagnostics(paint, () ->
            WebGpuPaint.handleDraw3d(paint, () ->
            Platform.runTasksInPlace(() ->
            handleFrameClock(state, () ->
            handleWindow(state, screen, onPoll, () ->
            WebGpuPaint.handleDraw2d(paint, (_, _, _) -> checked_ecast(()), () ->
            handleInput(state, () ->
            WebGpuPaint.handleGpuResources(paint, fonts, f)))))))))));
        Browser.ended();
        WebGpuPaint.release(paint);
        result

    // ── 絵とフォント ──

    /// 絵を全部上げる。後回しの絵（web.deferred）は、もう届いていれば上げ、まだなら飛ばす（届いた時に registerArrivedTextures が上げる）。
    def loadTextures(gpu: BrowserWebGpu, paint: WebGpuPaint.Paint, manifest: List[RenderAsset.TextureEntry],
                     onProgress: (Int32, Int32) -> Unit \ IO): Unit \ IO =
        let total = List.length(manifest);
        onProgress(0, total);
        let uploaded = List.zipWithIndex(manifest) |> List.foldLeft((acc, indexed) -> {
            let (index, entry) = indexed;
            let next = if (Deferred.isDeferred(entry#path) and not WebImages.has(entry#path)) acc
                else {
                    WebGpuPaint.putTexture(entry#name, uploadImageOrBug(gpu, paint, entry), paint);
                    entry :: acc
                };
            onProgress(index + 1, total);
            next
        }, Nil);
        // WhyNot: 名前ごとに知らせない — 知らせた後に頁が ImageBitmap を捨てるので、同じ道の 2 つ目の名前が上げられなくなる。
        uploaded |> List.map(e -> e#path) |> List.distinct |> List.filter(path -> Deferred.isDeferred(path)) |> List.forEach(path -> Deferred.markLoaded(path))

    /// 解いておいた絵 1 枚を RGBA で読み、宣言の hasAlpha で上げる（偽なら alpha を 255 で埋める）。束に無い絵は起動時に要る素材なので止める。
    def uploadImageOrBug(gpu: BrowserWebGpu, paint: WebGpuPaint.Paint, entry: RenderAsset.TextureEntry): RenderAsset.TextureInfo \ IO =
        let path = entry#path;
        if (not WebImages.has(path)) bug!("Failed to load texture: ${path}（書き出しの束に無い）")
        else {
            let width = WebImages.width(path);
            let height = WebImages.height(path);
            let rgba = ByteBuffer.allocateDirect(Int32.max(4, width * height * 4));
            gpu.copyImageBitmap(path, width, height, rgba);
            if (entry#hasAlpha) () else WebGpuPaint.makeOpaque(rgba, width * height);
            WebGpuPaint.uploadRgba(paint, width, height, rgba)
        }

    /// 書き出しが事前生成したアトラスを読んで R8 で上げる。読めないフォントは 1 行言って飛ばす（組み込みフォントで代わりに出す）。
    def loadFonts(paint: WebGpuPaint.Paint, manifest: List[RenderAsset.FontEntry], progress: (String, Int32, Int32) -> Unit \ IO): RenderPaint.Fonts \ IO =
        let total = List.length(manifest);
        let pending = WebAssets.pendingFontsOf(manifest);
        let atlases = List.zipWithIndex(manifest) |> List.foldLeft((acc, indexed) -> {
            let (index, entry) = indexed;
            progress("loading font ${entry#name}...", index, total);
            if (List.exists(p -> p#name == entry#name, pending)) acc
            else uploadAtlas(paint, entry) |> Option.map(atlas -> Map.insert(entry#name, atlas, acc)) |> Option.getWithDefault(acc)
        }, Map#{BootFont.name() => BootFont.atlas()});
        { atlases = Ref.fresh(Static, WebAssets.withPlaceholderFonts(manifest, pending, atlases)), grow = (atlas, _) -> checked_ecast(atlas),
          missing = Ref.fresh(Static, Set.empty()) }

    /// 素材の表のアトラスを読んで R8 で上げる。束に無いか壊れていれば 1 行言って None（組み込みフォントか仮の当てで出す）。
    def uploadAtlas(paint: WebGpuPaint.Paint, entry: RenderAsset.FontEntry): Option[FontAtlas] \ IO =
        let path = WebAssets.atlasPathOf(entry);
        let bytes = AssetTable.bytes(path);
        let baked = if (Object.isNull(bytes)) None else RenderFontCache.decode(bytes, "font_${entry#name}");
        match baked {
            case Some(font) =>
                println("  Font '${entry#name}' read from ${path} (${font#side}x${font#side})");
                WebGpuPaint.putTexture(font#atlas#textureName, WebGpuPaint.uploadR8(paint, font#side, font#side, font#pixels), paint);
                Some(font#atlas)
            case None =>
                Log.warnThen("font: '${entry#name}' のアトラス ${path} が束に無いか壊れている — 組み込みフォントで出す（bin/fge export-web で書き出し直す）", None)
        }

    /// 届いた後回しの絵を、予算の内で道ごとに上げる（WebLayer.registerArrivedTextures と同じ予算の決まり）。
    def registerArrivedTextures(gpu: BrowserWebGpu, paint: WebGpuPaint.Paint, st: State): Unit \ IO =
        Ref.put(0.0, st#spentMs);
        let pending = Ref.get(st#pendingTextures);
        let limit = match Ref.get(st#budget) {
            case LoadProgress.DecodeBudget.Paused     => None
            case LoadProgress.DecodeBudget.Idle(ms)    => Some(ms)
            case LoadProgress.DecodeBudget.Covered(ms) => Some(ms)
        };
        match limit {
            case Some(ms) if not List.isEmpty(pending) =>
                let (ready, waiting) = List.partition(e -> WebImages.has(e#path), pending);
                let began = Browser.now();
                let left = registerWithin(gpu, paint, began, ms, true, LoadProgress.Deferred.groupByPath(e -> e#path, ready));
                Ref.put(Browser.now() - began, st#spentMs);
                Ref.put(List.append(left, waiting), st#pendingTextures)
            case _ => ()
        }

    def registerWithin(gpu: BrowserWebGpu, paint: WebGpuPaint.Paint, began: Float64, ms: Float64, first: Bool,
                       ready: List[(String, List[RenderAsset.TextureEntry])]): List[RenderAsset.TextureEntry] \ IO = match ready {
        case Nil => Nil
        case (path, entries) :: rest =>
            if (not first and Browser.now() - began >= ms) List.flatMap(snd, ready)
            else {
                entries |> List.forEach(e -> WebGpuPaint.putTexture(e#name, uploadImageOrBug(gpu, paint, e), paint));
                Deferred.markLoaded(path);
                registerWithin(gpu, paint, began, ms, false, rest)
            }
    }

    // ── 画面 ──

    /// canvas の大きさが変わっていれば、描き先を configure し直して中間の texture を作り直す（コマの頭で）。
    def followCanvasSize(screen: Screen): Unit \ IO =
        let now = (Int32.max(1, Browser.canvasWidth()), Int32.max(1, Browser.canvasHeight()));
        if (now == Ref.get(screen#size)) ()
        else {
            Ref.put(now, screen#size);
            screen#surface.configure(fst(now), snd(now), screen#format, PresentMode.FIFO, TextureUsage.RENDER_ATTACHMENT);
            WebGpuPaint.resize(screen#paint, fst(now), snd(now))
        }

    /// コマを締めて canvas へ出し、?capture=<n> の n コマ目なら中間の texture を読んで頁に置く。
    def presentToCanvas(screen: Screen): Unit \ IO =
        WebGpuPaint.present(screen#paint, Some(screen#surface.getCurrentTexture()));
        screen#surface.present();
        let drawn = Ref.get(screen#drawn) + 1;
        Ref.put(drawn, screen#drawn);
        if (screen#captureFrame <= 0 or drawn != screen#captureFrame) ()
        else {
            let (w, h) = Ref.get(screen#size);
            let pixels = ByteBuffer.allocateDirect(w * h * 4);
            WebGpuPaint.readFrame(screen#paint, pixels);
            Browser.publishCapture(pixels, w, h, "webgpu: ${screen#gpu.adapterInfo()}")
        }

    /// Platform.Window を頁と canvas で受ける（WebLayer.handleWindow の WebGPU 版。presentFrame で canvas へ出してから次の描き替えまで待つ）。
    def handleWindow(st: State, screen: Screen, onPoll: Unit -> Unit \ IO, f: Unit -> a \ ef): a \ (ef - Platform.Window) + IO =
        run f() with handler Platform.Window {
            def pollEvents(k) = {
                if (not Ref.get(st#looping)) { Ref.put(true, st#looping); Browser.started() } else ();
                Browser.beginFrame();
                followCanvasSize(screen);
                onPoll();
                k(())
            }
            def shouldClose(k) = k(Ref.get(st#closeRequested))
            def setShouldClose(close, k) = { Ref.put(close, st#closeRequested); k(()) }
            def getViewportRect(k) = k({ position = Vec2.zero(), size = st#design })
            def getDisplay(k) = k(display(st#design))
            def presentFrame(k) = {
                presentToCanvas(screen);
                let dt = AnimationFrame.waitTick(tickRate());
                Ref.put(if (Browser.isFrameCapture()) 1.0 / tickRate() else dt, st#lastDt);
                k(())
            }
            def setCursor(cursor, k) = { Ref.put(cursor, st#cursor); applyCursor(st); k(()) }
            def setCursorVisible(visible, k) = { Ref.put(visible, st#cursorVisible); applyCursor(st); k(()) }
            def setMouseCaptured(captured, k) = { Pointer.setCaptured(captured); k(()) }
            def setFullscreen(on, k) = {
                let asked = if (on) FullscreenAsk.Fullscreen else FullscreenAsk.Windowed;
                if (Ref.get(st#fullscreenAsked) != asked) { Ref.put(asked, st#fullscreenAsked); Browser.requestFullscreen(on) } else ();
                k(())
            }
            def isFullscreen(k) = k(Browser.isFullscreen())
            def setDebugBadge(_enabled, k) = k(())
        }
}
