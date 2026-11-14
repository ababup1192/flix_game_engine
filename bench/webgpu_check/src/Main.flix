// PC の入口。WebGPU の PC の実装（Dawn）を Flix から WebGpu の interface を通して呼び、描いた絵を読み戻して期待と比べる。
// WEBGPU_CHECK=offscreen（既定）はウィンドウを使わない門、window は GLFW のウィンドウの門（macOS は最初の糸で起動し直す）。
// ウィンドウを使わない門の本体は Checks.flix（ブラウザの入口 web/WebMain.flix と同じコード）。ここにあるのは PC だけの門。
// 門ごとに "RESULT <名前> OK|NG …" を 1 行出し、1 つでも NG なら exit 1。
mod WebGpuCheck {
    use fge::{LwjglLayer, WebGpuOffscreen, WebGpuWindow}
    use WebGpuChecks.{checkTriangles, drawTriangles, fmt, median, near, readTexture, report, rgbaAt, showPixel}

    import fge.webgpu.CullMode
    import fge.webgpu.PresentMode
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Surface
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.WebGpu
    import fge.webgpu.dawn.DawnWebGpu
    import java.io.File
    import java.lang.IllegalStateException
    import java.lang.System
    import java.lang.Thread

    /// ネイティブの置き場（WEBGPU_NATIVE_DIR。無ければ空 = DawnWebGpu の既定）。
    def nativeDir(): String \ IO =
        let dir = System.getenv("WEBGPU_NATIVE_DIR");
        if (Object.isNull(dir)) "" else dir

    /// WEBGPU_BARRIER のファイルができるまで待つ（2 プロセスの門が、device を開く直前でそろえる）。無ければすぐ返る。
    def waitBarrier(): Unit \ IO =
        let path = System.getenv("WEBGPU_BARRIER");
        if (Object.isNull(path)) () else {
            let waitedFrom = System.currentTimeMillis();
            waitFor(new File(path), System.nanoTime());
            println("BARRIER waited=${System.currentTimeMillis() - waitedFrom} ms released-at=${System.currentTimeMillis()}")
        }

    def waitFor(file: File, start: Int64): Unit \ IO =
        if (file.exists() or System.nanoTime() - start > 60000000000i64) ()
        else {
            Thread.onSpinWait();
            waitFor(file, start)
        }


    /// ネイティブを読んだ後に別の置き場を渡すと、黙って無視せず誤りになる。
    def checkNativeDirMismatch(): Bool \ IO + WebGpuChecks.CheckLog =
        let other = "${System.getProperty("java.io.tmpdir")}/fge-webgpu-check-other-dir";
        let outcome = try { DawnWebGpu.open(other).destroy(); "開けた" } catch { case e: IllegalStateException => "誤り: ${e.getMessage()}" };
        report("native-dir-mismatch", String.startsWith({prefix = "誤り"}, outcome), outcome)

    // ── device を捨てて取り直す ──────────────────────────────

    def checkReopen(dawn: DawnWebGpu): Bool \ IO + WebGpuChecks.CheckLog =
        dawn.destroy();
        let again = dawn.reopen();
        let gpu: WebGpu = checked_cast(again);
        let fresh = WebGpuOffscreen.withDevice(gpu, { width = 64, height = 64 });
        let ok = checkTriangles(fresh, "reopen-after-destroy", CullMode.BACK, false);
        WebGpuOffscreen.close(fresh);
        ok

    // ── ウィンドウなしの門 ──────────────────────────────

    // WhyNot: 公開の入口（WebGpuOffscreen.open）より先に DawnWebGpu.open を呼ぶ — 2 プロセスの門は置き場を名指しし、その置き場で読ませたい。
    def offscreen(): Bool \ IO + WebGpuChecks.CheckLog =
        waitBarrier();
        let dawn = DawnWebGpu.open(nativeDir());
        let dirOk = checkNativeDirMismatch();
        let shared = run WebGpuChecks.offscreen() with WebGpuOffscreen.runDawn;
        List.forAll(identity, dirOk :: shared :: checkReopen(dawn) :: Nil)

    // ── ウィンドウの門 ──────────────────────────────

    /// ウィンドウの三角形: 中は (1.0, 0.5, 0.25)・地は 0.2。
    def windowWgsl(): String =
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    var p = vec2f(0.0, 0.5);\n" +
        "    if (i == 0u) { p = vec2f(-0.5, -0.5); } else if (i == 1u) { p = vec2f(0.5, -0.5); }\n" +
        "    return vec4f(p, 0.0, 1.0);\n" +
        "}\n" +
        "@fragment fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.5, 0.25, 1.0); }\n"

    def windowPipeline(gpu: WebGpu, format: TextureFormat): RenderPipeline \ IO =
        let module = gpu.createShaderModule("check window", windowWgsl());
        let desc = new RenderPipelineDesc("check window");
        discard desc.vertex(module, "vs_main").fragment(module, "fs_main").colorTarget(format);
        let pipeline = gpu.createRenderPipeline(desc);
        module.release();
        pipeline

    /// 描き先を取り、三角形を描いて submit する（present はしない）。取れなければ None。
    def drawWindowFrame(gpu: WebGpu, surface: Surface, pipeline: RenderPipeline): Option[Texture] \ IO =
        let texture = surface.getCurrentTexture();
        if (Object.isNull(texture)) None
        else {
            drawTriangles(gpu, texture, pipeline, 3);
            Some(texture)
        }

    /// present の前に描き先を読み、三角形の中 2 点・外 2 点を見る（BGRA の並び）。
    def checkSurfacePixels(gpu: WebGpu, texture: Texture, name: String): Bool \ IO + WebGpuChecks.CheckLog =
        let w = texture.width();
        let h = texture.height();
        let bytesPerRow = (w * 4 + 255) / 256 * 256;
        let buf = readTexture(gpu, texture, w, h);
        let bgra = p -> { let (b, g, r, a) = p; (r, g, b, a) };
        let inA = bgra(rgbaAt(buf, bytesPerRow, w * 3 / 10, h * 7 / 10));
        let inB = bgra(rgbaAt(buf, bytesPerRow, w / 2, h * 6 / 10));
        let outA = bgra(rgbaAt(buf, bytesPerRow, w * 3 / 10, h * 3 / 10));
        let outB = bgra(rgbaAt(buf, bytesPerRow, 3, 3));
        let orange = (255, 128, 64, 255);
        let grey = (51, 51, 51, 255);
        let ok = near(inA, orange) and near(inB, orange) and near(outA, grey) and near(outB, grey);
        report(name, ok, "${w}x${h} in=${showPixel(inA)}/${showPixel(inB)} out=${showPixel(outA)}/${showPixel(outB)}")

    /// ウィンドウの門: 描き先の形・120 コマの間隔・present の前の読み戻し・Retina の倍率・大きさを変えた後の作り直し。
    def window(): Bool \ IO + WebGpuChecks.CheckLog =
        let dawn = DawnWebGpu.open(nativeDir());
        let gpu: WebGpu = checked_cast(dawn);
        // WhyNot: pipeline をウィンドウを開く前に作らない — 描き先の形はウィンドウの surface を作ってからでないと分からない。
        let held = Ref.fresh(Static, None);
        let redrawn = Ref.fresh(Static, 0);
        let redraw = (surface, _w, _h) -> {
            Ref.put(Ref.get(redrawn) + 1, redrawn);
            Ref.get(held) |> Option.forEach(pipeline ->
                drawWindowFrame(gpu, surface, pipeline) |> Option.forEach(_ -> surface.present()))
        };
        match WebGpuWindow.open(dawn, { width = 640, height = 360, title = "webgpu check", visible = true, presentMode = PresentMode.FIFO }, redraw) {
            case Err(why) => report("window-open", false, why)
            case Ok(win)  =>
                let surface = WebGpuWindow.surfaceOf(win);
                let format = WebGpuWindow.formatOf(win);
                let pipeline = windowPipeline(gpu, format);
                Ref.put(Some(pipeline), held);
                let opened = report("window-open", true, "format=${format.toString()} present=FIFO")
                    and reportScale(win);
                let frames = windowFrames(gpu, surface, pipeline, 120);
                let framed = report("window-frames", List.length(frames) == 120 and gpu.errorCount() == 0,
                                    "drawn=${List.length(frames)} interval med=${fmt(median(List.drop(10, frames)))} ms (frames 10..119) errors=${gpu.errorCount()}");
                let readOk = checkOneFrame(gpu, surface, pipeline, "window-readback");
                WebGpuWindow.setWindowSize(win, 800, 450);
                List.range(0, 30) |> List.forEach(_ -> { WebGpuWindow.pollEvents(); Thread.sleep(5i64) });
                let (fbW, fbH) = WebGpuWindow.sizeOf(win);
                let resized = report("window-resize-callback", WebGpuWindow.resizeCount(win) >= 1 and Ref.get(redrawn) >= 1,
                                     "reconfigured=${WebGpuWindow.resizeCount(win)} redrawn=${Ref.get(redrawn)} framebuffer=${fbW}x${fbH}");
                let resizedRead = checkOneFrame(gpu, surface, pipeline, "window-resized-readback");
                WebGpuWindow.close(win);
                opened and framed and readOk and resized and resizedRead
        }

    def reportScale(win: WebGpuWindow.Window): Bool \ IO + WebGpuChecks.CheckLog =
        let (ww, wh) = WebGpuWindow.windowSizeOf(win);
        let (fw, fh) = WebGpuWindow.sizeOf(win);
        match WebGpuWindow.backingScaleOf(win) {
            case Err(why)  => report("window-scale", false, why)
            case Ok(scale) =>
                let expectedW = Float64.round(Int32.toFloat64(ww) * scale);
                report("window-scale", Int32.toFloat64(fw) == expectedW,
                       "window=${ww}x${wh}pt framebuffer=${fw}x${fh}px backingScaleFactor=${scale}")
        }

    /// 1 コマ描いて present の前に読み、present する。
    def checkOneFrame(gpu: WebGpu, surface: Surface, pipeline: RenderPipeline, name: String): Bool \ IO + WebGpuChecks.CheckLog =
        WebGpuWindow.pollEvents();
        match drawWindowFrame(gpu, surface, pipeline) {
            case None          => report(name, false, "描き先を取れない status=${surface.lastStatus().toString()}")
            case Some(texture) =>
                let ok = checkSurfacePixels(gpu, texture, name);
                surface.present();
                ok
        }

    /// n コマ描いて present し、描けたコマの間隔（ms）の列を返す。
    def windowFrames(gpu: WebGpu, surface: Surface, pipeline: RenderPipeline, n: Int32): List[Float64] \ IO =
        let last = Ref.fresh(Static, System.nanoTime());
        let intervals = List.range(0, n) |> List.filterMap(_ -> {
            WebGpuWindow.pollEvents();
            let drawn = drawWindowFrame(gpu, surface, pipeline);
            drawn |> Option.forEach(_ -> surface.present());
            let now = System.nanoTime();
            let ms = Int64.toFloat64(now - Ref.get(last)) / 1000000.0;
            Ref.put(now, last);
            drawn |> Option.map(_ -> ms)
        });
        intervals

    pub def main(): Unit \ IO =
        let mode = System.getenv("WEBGPU_CHECK");
        let windowMode = not Object.isNull(mode) and mode == "window";
        // WhyNot: ウィンドウなしの門まで最初の糸で起動し直さない — ウィンドウを使わない門は糸を選ばず、起動し直す時間だけが増える。
        if (windowMode and LwjglLayer.ensureMainThread()) ()
        else {
            let ok = run {
                if (windowMode) window() else offscreen()
            } with handler WebGpuChecks.CheckLog {
                def result(name, passed, detail, k) = { println("RESULT ${name} ${if (passed) "OK" else "NG"} ${detail}"); k() }
            };
            println("RESULT webgpu-check ${if (ok) "OK" else "NG"}");
            System.exit(if (ok) 0 else 1)
        }
}

def main(): Unit \ IO = WebGpuCheck.main()
