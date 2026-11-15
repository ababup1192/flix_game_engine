// 入口。同じ場面（V1Scenes）を GL（GlOffscreen）と WebGPU（RenderPaint.Internal.WebGpuPaint・Dawn）の両方で、ウィンドウを開かずに 1 コマずつ描き、
// 画素を比べて 1 行 1 場面の表を出す（"[webgpu-v1] <場面> …"）。場面ごとの許す差は tolerance.tsv（無ければ 0）。
// 許す差を超えた場面がある・WebGPU の誤りの数が 0 でない・submit の数が場面の期待と違う、のどれかで exit 1。
// WebGPU の側の読み込みは実機のウィンドウと同じ 3.1 の PC の道（LwjglLayer.Internal.WebGpuWindowLayer）: 絵は stb で 4 成分・hasAlpha が偽なら alpha を 255 で埋めて RGBA8・
// フォントは RenderFontCache.loadOrBake の距離場を R8。組み込みの字・ロゴ・放射の絵と生成の絵（BGRA8）は WebGpuPaint が上げる。
mod V1Main {
    use RenderPaint.Internal.WebGpuPaint

    import java.awt.image.BufferedImage
    import java.io.File
    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.file.Files
    import java.nio.file.Paths
    import javax.imageio.ImageIO

    // ── 場面を描く（GL と WebGPU で同じ）──

    /// 1 場面を 1 コマ描く: Pass を描いてから本編を渡し、画面へ出す。
    def drawScene(sc: V1Scenes.Scene): Unit \ Platform.Rendering + RenderTarget.Target + Platform.Window =
        let design = { x = V1Scenes.designW(), y = V1Scenes.designH() };
        if (List.isEmpty(sc#passes)) ()
        else discard App.Internal.Paint.drawPassPlan(_ -> (), design, Set.empty(), { targets = sc#targets | Render.passPlan(sc#passes) });
        let items = sc#items();
        App.Internal.Paint.submitGpuItems(_ -> (), items, Nil, None);
        Platform.Window.presentFrame()

    // ── GL ──

    /// 全部の場面を GL で描き、場面ごとの画素（RGBA・下の行から）を返す。
    def shootGl(config: GameEngine.EngineConfig): Result[String, List[ByteBuffer]] \ IO =
        match GlOffscreen.open({ config = config, scale = 1 }) {
            case Err(why)    => Err(why)
            case Ok(session) =>
                let shots = V1Scenes.all() |> List.map(sc -> {
                    GlOffscreen.handle(session, () -> drawScene(sc));
                    let buf = GlOffscreen.freshBuffer(session);
                    GlOffscreen.readRgba(session, buf);
                    buf
                });
                GlOffscreen.close(session);
                Ok(shots)
        }

    // ── WebGPU ──

    /// 1 場面の結果: 画素（RGBA・下の行から）と、そのコマの submit の数。
    type alias GpuShot = { pixels = ByteBuffer, submits = Int32 }

    /// 全部の場面を WebGPU で描く。返すのは (場面ごとの結果, 誤りの数, 最後の誤りの文, adapter の名前)。
    def shootWebGpu(config: GameEngine.EngineConfig): Result[String, (List[GpuShot], Int32, String, String)] \ IO + WebGpuDevice =
        match WebGpuDevice.requestDevice() {
            case Err(why) => Err(why)
            case Ok(gpu)  =>
                let width = config#designWidth;
                let height = config#designHeight;
                let paint = WebGpuPaint.create(gpu, { designWidth = width, designHeight = height, clearColor = config#clearColor,
                                                      width = width, height = height });
                let fonts = LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.loadAll(paint, config);
                let shots = V1Scenes.all() |> List.map(sc -> {
                    handle(paint, fonts, () -> drawScene(sc));
                    let buf = ByteBuffer.allocateDirect(width * height * 4);
                    WebGpuPaint.readFrame(paint, buf);
                    { pixels = buf, submits = WebGpuPaint.submitCount(paint) }
                });
                // V1 で描かない物（多角形・mask つきスプライト）を 2 コマ渡す: 名前ごとに 1 回だけ知らせ、誤りを出さずに捨てる。
                handle(paint, fonts, () -> drawScene(V1Scenes.unsupported()));
                handle(paint, fonts, () -> drawScene(V1Scenes.unsupported()));
                let result = (shots, gpu.errorCount(), gpu.lastError(), gpu.adapterInfo());
                gpu.destroy();
                Ok(result)
        }

    /// f の中の Platform の effect と Target を WebGpuPaint で受ける。入力・ウィンドウの問いには「何も起きていない」で答え、presentFrame でコマを締める。
    def handle(paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts,
               f: Unit -> a \ ef): a \ (ef - GlOffscreen.HandledEffects) + IO =
        WebGpuPaint.handleTarget(paint, () ->
        windowless(paint, () ->
        WebGpuPaint.handleDiagnostics(paint, () ->
        Platform.runTasksInPlace(() ->
        WebGpuPaint.handleDraw3d(paint, () ->
        WebGpuPaint.handleDraw2d(paint, (_, _, _) -> (), () ->
        WebGpuPaint.handleGpuResources(paint, fonts, f)))))))

    def windowless(paint: WebGpuPaint.Paint, f: Unit -> a \ ef):
            a \ (ef - Platform.Input - Platform.Window - Platform.FrameClock - Platform.Annotation) + IO =
        let design = { x = V1Scenes.designW(), y = V1Scenes.designH() };
        run f() with handler Platform.Input {
            def isKeyPressed(_key, k) = k(false)
            def getMousePosition(k) = k(Vec2.zero())
            def isMouseButtonPressed(_button, k) = k(false)
            def isGamepadTouched(k) = k(false)
            def gamepadSticks(k) = k({ left = Vec2.zero(), right = Vec2.zero() })
            def gamepadKind(k) = k(GamepadMap.PadKind.Unknown)
            def consumeScrollDelta(k) = k(0.0)
            def consumeMouseDelta(k) = k(Vec2.zero())
            def isWindowFocused(k) = k(true)
        } with handler Platform.Window {
            def pollEvents(k) = k(())
            def shouldClose(k) = k(false)
            def setShouldClose(_close, k) = k()
            def getViewportRect(k) = k({ position = Vec2.zero(), size = design })
            def getDisplay(k) = k(Display.desktop(design))
            def presentFrame(k) = {
                WebGpuPaint.present(paint, None);
                k(())
            }
            def setCursor(_cursor, k) = k(())
            def setCursorVisible(_visible, k) = k(())
            def setMouseCaptured(_captured, k) = k(())
            def setFullscreen(_on, k) = k(())
            def isFullscreen(k) = k(false)
            def setDebugBadge(_enabled, k) = k(())
        } with handler Platform.FrameClock {
            def getDeltaTime(k) = k(Duration.seconds(1.0 / 60.0))
        } with handler Platform.Annotation {
            def saveAnnotation(_req, k) = k(None)
        }

    // ── 比べる ──

    /// 2 枚の差: 違う画素の数と、成分の差の最大（0〜255）。
    type alias Diff = { pixels = Int32, maxDelta = Int32 }

    def diffOf(a: ByteBuffer, b: ByteBuffer, count: Int32): Diff \ IO = diffFrom(a, b, count, 0, { pixels = 0, maxDelta = 0 })

    def diffFrom(a: ByteBuffer, b: ByteBuffer, count: Int32, i: Int32, acc: Diff): Diff \ IO =
        if (i >= count) acc
        else {
            let d = Int32.max(Int32.max(channelDelta(a, b, i * 4), channelDelta(a, b, i * 4 + 1)),
                              Int32.max(channelDelta(a, b, i * 4 + 2), channelDelta(a, b, i * 4 + 3)));
            let next = if (d == 0) acc else { pixels = acc#pixels + 1, maxDelta = Int32.max(acc#maxDelta, d) };
            diffFrom(a, b, count, i + 1, next)
        }

    def channelDelta(a: ByteBuffer, b: ByteBuffer, at: Int32): Int32 \ IO =
        Int32.abs(Int32.bitwiseAnd(Int8.toInt32(a.get(at)), 255) - Int32.bitwiseAnd(Int8.toInt32(b.get(at)), 255))

    /// tolerance.tsv の 場面 → 許す差（# の行と空の行は読まない）。
    def tolerances(): Map[String, Int32] \ IO =
        Files.readString(Paths.get("tolerance.tsv"))
            |> String.splitOn({substr = "\n"})
            |> List.filter(line -> not String.isEmpty(String.trim(line)) and not String.startsWith({prefix = "#"}, line))
            |> List.filterMap(line -> match String.splitOn({substr = "\t"}, line) {
                case name :: limit :: _ => Int32.fromString(String.trim(limit)) |> Option.map(n -> (name, n))
                case _                  => None
            })
            |> List.toMap

    /// RGBA（下の行から）の i 番目の画素を ARGB の int にする。
    def argbAt(pixels: ByteBuffer, i: Int32): Int32 \ IO =
        let byteAt = k -> Int32.bitwiseAnd(Int8.toInt32(pixels.get(i * 4 + k)), 255);
        argbOf(byteAt(3), byteAt(0), byteAt(1), byteAt(2))

    /// 成分（0〜255）を ARGB の int に並べる。
    def argbOf(a: Int32, r: Int32, g: Int32, b: Int32): Int32 = a * 16777216 + r * 65536 + g * 256 + b

    /// 左上原点の (x, y) の色を colorAt で決めて PNG に書く（colorAt が受けるのは下の行からの画素の番号）。
    def writePng(colorAt: Int32 -> Int32 \ IO, width: Int32, height: Int32, path: String): Unit \ IO = region rc {
        let image = new BufferedImage(width, height, 2i32);
        let argb: Array[Int32, rc] = Array.empty(rc, width * height);
        List.range(0, height) |> List.forEach(y -> List.range(0, width) |> List.forEach(x ->
            Array.put(colorAt((height - 1 - y) * width + x), y * width + x, argb)));
        image.setRGB(0, 0, width, height, argb, 0, width);
        let file = new File(path);
        discard file.getParentFile().mkdirs();
        discard ImageIO.write(image, "png", file)
    }

    /// 差のある画素だけ赤く塗った色（ほかは GL の絵を暗くした物）。
    def diffColorAt(gl: ByteBuffer, gpu: ByteBuffer, i: Int32): Int32 \ IO =
        let same = channelDelta(gl, gpu, i * 4) + channelDelta(gl, gpu, i * 4 + 1)
            + channelDelta(gl, gpu, i * 4 + 2) + channelDelta(gl, gpu, i * 4 + 3) == 0;
        let byteAt = k -> Int32.bitwiseAnd(Int8.toInt32(gl.get(i * 4 + k)), 255);
        if (same) argbOf(255, byteAt(0) / 4, byteAt(1) / 4, byteAt(2) / 4)
        else argbOf(255, 255, 0, 0)

    def pad(s: String, n: Int32): String = if (String.length(s) >= n) s else pad(s + " ", n)

    /// 1 場面の表の行と合否。
    def judge(width: Int32, height: Int32, limits: Map[String, Int32],
              sc: V1Scenes.Scene, gl: ByteBuffer, gpu: GpuShot): (String, Bool) \ IO =
        writePng(i -> argbAt(gl, i), width, height, "debug/gl/${sc#name}.png");
        writePng(i -> argbAt(gpu#pixels, i), width, height, "debug/webgpu/${sc#name}.png");
        let diff = diffOf(gl, gpu#pixels, width * height);
        let limit = Map.getWithDefault(sc#name, 0, limits);
        if (diff#pixels > 0) writePng(i -> diffColorAt(gl, gpu#pixels, i), width, height, "debug/diff/${sc#name}.png") else ();
        let submitsOk = Option.forAll(n -> n == gpu#submits, sc#submits);
        let ok = diff#maxDelta <= limit and submitsOk;
        let verdict = if (ok) "OK" else "NG";
        let expectedSubmits = sc#submits |> Option.map(n -> "（期待 ${Int32.toString(n)}）") |> Option.getWithDefault("");
        ("[webgpu-v1] ${pad(sc#name, 18)} ${verdict}  差 ${Int32.toString(diff#pixels)} px max ±${Int32.toString(diff#maxDelta)}（許容 ${Int32.toString(limit)}）"
            + " submits ${Int32.toString(gpu#submits)}${expectedSubmits}", ok)

    pub def go(): Unit \ IO =
        let config = match (run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO) {
            case Ok(loaded) => loaded#config
            case Err(why)   => bug!("project.json を読めない: ${why}")
        };
        let gl = match shootGl(config) {
            case Ok(shots) => shots
            case Err(why)  => bug!("GL を開けない: ${why}")
        };
        let gpuOutcome = run { shootWebGpu(config) } with WebGpuDevice.runDawn;
        let (gpuShots, errors, lastError, adapter) = match gpuOutcome {
            case Ok(r)    => r
            case Err(why) => bug!("WebGPU を開けない: ${why}")
        };
        println("[webgpu-v1] adapter: ${adapter}");
        let limits = tolerances();
        let rows = List.zip(V1Scenes.all(), List.zip(gl, gpuShots)) |> List.map(row -> {
            let (sc, (glShot, gpuShot)) = row;
            judge(config#designWidth, config#designHeight, limits, sc, glShot, gpuShot)
        });
        List.forEach(r -> println(fst(r)), rows);
        let errorsOk = errors == 0;
        println("[webgpu-v1] errors ${Int32.toString(errors)}${if (errorsOk) "" else " last=[${lastError}]"}");
        // 比べる道具が違いを拾えるか: GL の 1 場面目と WebGPU の 2 場面目は違う絵なので、差が 0 なら道具が壊れている。
        let control = match (gl, gpuShots) {
            case (first :: _, _ :: second :: _) => diffOf(first, second#pixels, config#designWidth * config#designHeight)#pixels
            case _                              => 0
        };
        let controlOk = control > 0;
        println("[webgpu-v1] 違う場面どうしの差 ${Int32.toString(control)} px（0 なら比べる道具が壊れている）");
        let ok = errorsOk and controlOk and List.forAll(snd, rows) and List.length(rows) == List.length(V1Scenes.all());
        println("[webgpu-v1] ${if (ok) "OK" else "NG"}");
        if (ok) () else System.exit(1)
}

def main(): Unit \ IO = V1Main.go()
