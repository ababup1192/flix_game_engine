// 入口。bench/scene3d の部屋（Room）を GL（GlOffscreen）と WebGPU（RenderPaint.Internal.WebGpuPaint・Dawn）の両方で、ウィンドウを開かずに 960×540 で描き
// （warmup のコマの後に 1 コマ）、画素を比べて 1 行 1 場面の表を出す（"[webgpu-v2] <場面> …"）。
// 続けて 1 コマの時間（GL は glFinish まで・WebGPU は waitIdle まで）を GL・WebGPU・貼る形 A・B の順に何回か交互に測って中央値を出す（記録。門ではない）。
// 許す差を超えた場面がある・WebGPU の誤りの数が 0 でない、のどちらかで exit 1。絵は debug/gl・debug/webgpu に書く。
mod V2Main {
    use RenderPaint.Internal.WebGpuPaint
    use Render3d.WebGpuRenderer.SplitPassTrial

    import fge.webgpu.WebGpu
    import java.lang.System
    import java.nio.ByteBuffer
    import org.lwjgl.opengl.GL11

    /// design 320×180 を何倍で描くか（bench/scene3d の窓と同じ 960×540）。
    def scale(): Int32 = 3

    def warmupFrames(): Int32 = 30

    /// 1 回の区間で測るコマの数と、GL・WebGPU を交互に回す回数。
    def timedFrames(): Int32 = 300
    def rounds(): Int32 = 5

    /// 比べる場面。name・yaw = カメラの向き（ラジアン）・design = Design の解像度で描くか。
    type alias Case = { name = String, yaw = Float64, design = Bool }

    def cases(): List[Case] =
        { name = "room", yaw = 0.0, design = false } ::
        { name = "roomTurned", yaw = 0.5, design = false } ::
        { name = "roomDesign", yaw = 0.0, design = true } :: Nil

    /// 場面ごとの許す差: 成分の差が 2 以上の画素の数（差が 1 の画素は数えない）。無い場面は 0。
    /// room と roomTurned（2026-11-16・Apple M4 Pro の実測で 7 px と 6 px）: 同じ深さに重なる面（燭台の台と卓の天板）と三角形のふちの画素で、
    /// 勝つ面が奥行きの丸めで入れ替わる（GL は clip の z を driver の固定の段で 0..1 へ移し、WebGPU は頂点シェーダーの sg_clipFromGl で移すので、最後の bit が違う）。
    /// 式の取り違え（光・かすみ・色の空間・面の向き）なら面の中が丸ごと違い、千 px の桁になる。
    def tolerances(): Map[String, Int32] = Map#{"room" => 32, "roomTurned" => 32}

    def itemsOf(kit: Room.Kit, c: Case): List[Render.PlacedItem] =
        let scene = Room.scene(kit, c#yaw);
        let resolution = if (c#design) Scene3d.Resolution.Design else Scene3d.Resolution.Native;
        Render.scene3d(Vec2.zero(), { resolution = resolution | scene }) :: Nil

    def drawFrame(items: List[Render.PlacedItem]): Unit \ Platform.Rendering + Platform.Window =
        App.Internal.Paint.submitGpuItems(_ -> (), items, Nil, None);
        Platform.Window.presentFrame()

    // ── GL ──

    def shootGl(session: GlOffscreen.Session, items: List[Render.PlacedItem]): ByteBuffer \ IO =
        List.range(0, warmupFrames()) |> List.forEach(_ -> GlOffscreen.handle(session, () -> drawFrame(items)));
        let buf = GlOffscreen.freshBuffer(session);
        GlOffscreen.readRgba(session, buf);
        buf

    def timeGl(session: GlOffscreen.Session, kit: Room.Kit): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let items = Room.items(kit, yawAt(i));
            let started = System.nanoTime();
            GlOffscreen.handle(session, () -> drawFrame(items));
            GL11.glFinish();
            System.nanoTime() - started
        })

    /// i コマ目のカメラの向き（bench/scene3d の窓と同じ振れ幅）。
    def yawAt(i: Int32): Float64 = 0.6 * Num.sin(Int32.toFloat64(i) / 60.0 * 0.4)

    // ── WebGPU ──

    def shootWebGpu(paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts, items: List[Render.PlacedItem], width: Int32, height: Int32): ByteBuffer \ IO =
        List.range(0, warmupFrames()) |> List.forEach(_ -> handle(paint, fonts, () -> drawFrame(items)));
        let buf = ByteBuffer.allocateDirect(width * height * 4);
        WebGpuPaint.readFrame(paint, buf);
        buf

    def timeWebGpu(gpu: WebGpu, paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts, kit: Room.Kit): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let items = Room.items(kit, yawAt(i));
            let started = System.nanoTime();
            handle(paint, fonts, () -> drawFrame(items));
            gpu.waitIdle();
            System.nanoTime() - started
        })

    /// 貼る形 A か B（SplitPassTrial）で i コマ目を組んで GPU を待つ時間。
    def timeTrial(gpu: WebGpu, trial: SplitPassTrial.Trial, kit: Room.Kit, splitPass: Bool): List[Int64] \ IO =
        List.range(0, timedFrames()) |> List.map(i -> {
            let cmds = Render.drawScenes3d(Room.items(kit, yawAt(i)));
            let started = System.nanoTime();
            if (splitPass) SplitPassTrial.frameB(trial, cmds) else SplitPassTrial.frameA(trial, cmds);
            gpu.waitIdle();
            System.nanoTime() - started
        })

    /// f の中の Platform の effect と Target を WebGpuPaint で受ける（bench/webgpu_v1 の handle と同じ並び）。
    def handle(paint: WebGpuPaint.Paint, fonts: RenderPaint.Fonts, f: Unit -> a \ ef): a \ (ef - GlOffscreen.HandledEffects) + IO =
        WebGpuPaint.handleTarget(paint, () ->
        windowless(paint, () ->
        WebGpuPaint.handleDiagnostics(paint, () ->
        Platform.runTasksInPlace(() ->
        WebGpuPaint.handleDraw3d(paint, () ->
        WebGpuPaint.handleDraw2d(paint, (_, _, _) -> (), () ->
        WebGpuPaint.handleGpuResources(paint, fonts, f)))))))

    def windowless(paint: WebGpuPaint.Paint, f: Unit -> a \ ef):
            a \ (ef - Platform.Input - Platform.Window - Platform.FrameClock - Platform.Annotation) + IO =
        let design = Room.design();
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

    /// 2 枚の差: 違う画素の数・成分の差の最大（0〜255）・差が 2 以上の画素の数。
    type alias Diff = { pixels = Int32, maxDelta = Int32, overOne = Int32 }

    def diffOf(a: ByteBuffer, b: ByteBuffer, count: Int32): Diff \ IO = diffFrom(a, b, count, 0, { pixels = 0, maxDelta = 0, overOne = 0 })

    def diffFrom(a: ByteBuffer, b: ByteBuffer, count: Int32, i: Int32, acc: Diff): Diff \ IO =
        if (i >= count) acc
        else {
            let d = Int32.max(Int32.max(channelDelta(a, b, i * 4), channelDelta(a, b, i * 4 + 1)),
                              Int32.max(channelDelta(a, b, i * 4 + 2), channelDelta(a, b, i * 4 + 3)));
            let next = if (d == 0) acc
                       else { pixels = acc#pixels + 1, maxDelta = Int32.max(acc#maxDelta, d), overOne = acc#overOne + (if (d >= 2) 1 else 0) };
            diffFrom(a, b, count, i + 1, next)
        }

    def channelDelta(a: ByteBuffer, b: ByteBuffer, at: Int32): Int32 \ IO =
        Int32.abs(Int32.bitwiseAnd(Int8.toInt32(a.get(at)), 255) - Int32.bitwiseAnd(Int8.toInt32(b.get(at)), 255))

    def pad(s: String, n: Int32): String = if (String.length(s) >= n) s else pad(s + " ", n)

    def judge(width: Int32, height: Int32, c: Case, gl: ByteBuffer, gpu: ByteBuffer): (String, Bool) \ IO =
        LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.writePng(gl, width, height, "debug/gl/${c#name}.png");
        LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.writePng(gpu, width, height, "debug/webgpu/${c#name}.png");
        let diff = diffOf(gl, gpu, width * height);
        let limit = Map.getWithDefault(c#name, 0, tolerances());
        let ok = diff#overOne <= limit;
        ("[webgpu-v2] ${pad(c#name, 12)} ${if (ok) "OK" else "NG"}  差 ${Int32.toString(diff#pixels)} px・±2 以上 ${Int32.toString(diff#overOne)} px（許容 ${Int32.toString(limit)}）"
            + "・max ±${Int32.toString(diff#maxDelta)}・全 ${Int32.toString(width * height)} px", ok)

    /// ns の列の中央値（ms・小数 3 桁の字）。
    def medianMs(xs: List[Int64]): String =
        let sorted = Sort.sortStable(xs);
        let mid = List.drop(List.length(sorted) / 2, sorted) |> List.head |> Option.getWithDefault(0i64);
        let ms = Int64.toFloat64(mid) / 1000000.0;
        Float64.toString(Float64.round(ms * 1000.0) / 1000.0)

    pub def go(): Unit \ IO =
        let config = match (run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO) {
            case Ok(loaded) => loaded#config
            case Err(why)   => bug!("project.json を読めない: ${why}")
        };
        let kit = match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Ok(meshes) => Room.kitOf(meshes)
            case Err(why)   => bug!("家具を読めない: ${why}")
        };
        let width = config#designWidth * scale();
        let height = config#designHeight * scale();
        let session = match GlOffscreen.open({ config = config, scale = scale() }) {
            case Ok(opened) => opened
            case Err(why)   => bug!("GL を開けない: ${why}")
        };
        let outcome = run { compareAndTime(config, kit, session, width, height) } with WebGpuDevice.runDawn;
        GlOffscreen.close(session);
        let ok = match outcome {
            case Ok(passed) => passed
            case Err(why)   => bug!("WebGPU を開けない: ${why}")
        };
        println("[webgpu-v2] ${if (ok) "OK" else "NG"}");
        if (ok) () else System.exit(1)

    def compareAndTime(config: GameEngine.EngineConfig, kit: Room.Kit, session: GlOffscreen.Session, width: Int32, height: Int32): Result[String, Bool] \ IO + WebGpuDevice =
        match WebGpuDevice.requestDevice() {
            case Err(why) => Err(why)
            case Ok(gpu)  =>
                let paint = WebGpuPaint.create(gpu, { designWidth = config#designWidth, designHeight = config#designHeight, clearColor = config#clearColor,
                                                      width = width, height = height });
                let fonts = LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.loadAll(paint, config);
                println("[webgpu-v2] adapter: ${gpu.adapterInfo()}");
                let rows = cases() |> List.map(c -> {
                    let items = itemsOf(kit, c);
                    judge(width, height, c, shootGl(session, items), shootWebGpu(paint, fonts, items, width, height))
                });
                List.forEach(r -> println(fst(r)), rows);
                let trial = SplitPassTrial.open(gpu, width, height, (Int32.toFloat64(config#designWidth), Int32.toFloat64(config#designHeight)));
                List.range(0, rounds()) |> List.forEach(round -> {
                    let gl = timeGl(session, kit);
                    let webgpu = timeWebGpu(gpu, paint, fonts, kit);
                    let a = timeTrial(gpu, trial, kit, false);
                    let b = timeTrial(gpu, trial, kit, true);
                    println("[webgpu-v2] 1 コマ（${Int32.toString(round + 1)} 回目・${Int32.toString(timedFrames())} コマの中央値・ms）: GL ${medianMs(gl)}・WebGPU ${medianMs(webgpu)}"
                        + "・貼る形 A ${medianMs(a)}・B ${medianMs(b)}")
                });
                SplitPassTrial.close(trial);
                let errors = gpu.errorCount();
                let lastError = gpu.lastError();
                println("[webgpu-v2] errors ${Int32.toString(errors)}${if (errors == 0) "" else " last=[${lastError}]"}");
                WebGpuPaint.release(paint);
                gpu.destroy();
                Ok(errors == 0 and List.forAll(snd, rows))
        }
}

def main(): Unit \ IO = V2Main.go()
