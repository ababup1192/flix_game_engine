// 入口。同じ場面（V1Scenes）を GL（GlOffscreen）と WebGPU（RenderPaint.Internal.WebGpuPaint・Dawn）の両方で、ウィンドウを開かずに描き（warmup のコマの後に 1 コマ）、
// 画素を比べて 1 行 1 場面の表を出す（"[webgpu-v1] <場面> …"）。場面ごとの許す差は tolerance.tsv（無ければ 0）。
// 許す差を超えた場面がある・WebGPU の誤りの数が 0 でない・submit の数が場面の期待と違う、のどれかで exit 1。
// 絵は debug/gl・debug/webgpu に書く。差の所の絵は bin/fge pixel-diff debug/gl/<場面>.png debug/webgpu/<場面>.png で見る。
// WebGPU の側の読み込みは実機のウィンドウと同じ 3.1 の PC の道（LwjglLayer.Internal.WebGpuWindowLayer）: 絵は stb で 4 成分・hasAlpha が偽なら alpha を 255 で埋めて RGBA8・
// フォントは RenderFontCache.loadOrBake の距離場を R8。組み込みの字・ロゴ・放射の絵と生成の絵（BGRA8）は WebGpuPaint が上げる。
mod V1Main {
    use RenderPaint.Internal.WebGpuPaint

    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.file.Files
    import java.nio.file.Paths

    // ── 場面を描く（GL と WebGPU で同じ）──

    /// 場面の warmup のコマ（Pass と描き先の作り方だけ替えた場面）と、比べるコマの列。
    def framesOf(sc: V1Scenes.Scene): List[V1Scenes.Scene] =
        List.append(List.map(st -> { passes = st#passes, targets = st#targets | sc }, sc#warmup), sc :: Nil)

    /// 1 場面を 1 コマ描く: Pass を描いてから本編を渡し、画面へ出す。
    // WhyNot: Pass と本編を 1 つの def に書き下さない — effect の続きが畳み込まれて 8,000 バイトを超え、lint-huge-methods がこの jar で鳴る。
    def drawScene(sc: V1Scenes.Scene): Unit \ Platform.Rendering + RenderTarget.Target + Platform.Window =
        drawPasses(sc);
        submitMain(sc);
        Platform.Window.presentFrame()

    @DontInline
    def drawPasses(sc: V1Scenes.Scene): Unit \ Platform.Rendering + RenderTarget.Target =
        let design = { x = V1Scenes.designW(), y = V1Scenes.designH() };
        if (List.isEmpty(sc#passes)) ()
        else discard App.Internal.Paint.drawPassPlan(_ -> (), design, Set.empty(), { targets = sc#targets | Render.passPlan(sc#passes) })

    @DontInline
    def submitMain(sc: V1Scenes.Scene): Unit \ Platform.Rendering =
        let items = sc#items();
        App.Internal.Paint.submitGpuItems(_ -> (), items, sc#tiles(), sc#staticLayer)

    // ── GL ──

    /// 全部の場面を GL で描き、場面ごとの画素（RGBA・下の行から）と、そのコマの 2D の draw call の数を返す。
    def shootGl(config: GameEngine.EngineConfig): Result[String, List[(ByteBuffer, FrameDiagnostics.Draw2dCounts)]] \ IO =
        match GlOffscreen.open({ config = config, scale = 1 }) {
            case Err(why)    => Err(why)
            case Ok(opened) =>
                let session = GlOffscreen.withHistoryKept(opened);
                let shots = V1Scenes.all() |> List.map(sc -> {
                    List.forEach(frame -> GlOffscreen.handle(session, () -> drawScene(frame)), framesOf(sc));
                    let buf = GlOffscreen.freshBuffer(session);
                    GlOffscreen.readRgba(session, buf);
                    (buf, GlOffscreen.lastDraw2dCounts(session))
                });
                GlOffscreen.close(session);
                Ok(shots)
        }

    // ── WebGPU ──

    /// 1 場面の結果: 画素（RGBA・下の行から）と、そのコマの submit の数と 2D の draw call の数。
    type alias GpuShot = { pixels = ByteBuffer, submits = Int32, draws = FrameDiagnostics.Draw2dCounts }

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
                    List.forEach(frame -> handle(paint, fonts, () -> drawScene(frame)), framesOf(sc));
                    let buf = ByteBuffer.allocateDirect(width * height * 4);
                    WebGpuPaint.readFrame(paint, buf);
                    { pixels = buf, submits = WebGpuPaint.submitCount(paint), draws = WebGpuPaint.lastDraw2dCounts(paint) }
                });
                // まだ描かない物（面と 3D の場面）を 2 コマ渡す: 名前ごとに 1 回だけ知らせ、誤りを出さずに捨てる。
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

    def pad(s: String, n: Int32): String = if (String.length(s) >= n) s else pad(s + " ", n)

    /// draw call の数と、切れた理由ごとの数（target・kind・texture・blend・clip・mask）。
    def drawKey(c: FrameDiagnostics.Draw2dCounts): (Int32, Int32, Int32, Int32, Int32, Int32, Int32) =
        let b = c#batchBreaks;
        (c#drawCalls, b#target, b#kind, b#texture, b#blend, b#clip, b#mask)

    def drawText(c: FrameDiagnostics.Draw2dCounts): String =
        let (n, target, kind, texture, blend, clip, mask) = drawKey(c);
        "draw ${Int32.toString(n)}（target ${Int32.toString(target)}・kind ${Int32.toString(kind)}・texture ${Int32.toString(texture)}・"
            + "blend ${Int32.toString(blend)}・clip ${Int32.toString(clip)}・mask ${Int32.toString(mask)}）"

    /// 場面ごとの 2D の draw call の数の期待（GL と WebGPU の両方がこの数である事）。無い場面は GL と WebGPU が同じかだけを見る。
    /// sceneBetween: 箱・箱・市松の絵の 3 本。同じ色・同じ blend の 2 つの箱の間に 3D の場面があるので、後の箱は kind で切れる
    ///   （場面が無ければ 2 つの箱は 1 本にまとまる）。市松の絵は絵が替わるので texture で切れる。
    def expectedDraws(): Map[String, (Int32, Int32, Int32, Int32, Int32, Int32, Int32)] =
        Map#{"sceneBetween" => (3, 0, 1, 1, 0, 0, 0)}

    /// 1 場面の表の行と合否。
    def judge(width: Int32, height: Int32, limits: Map[String, Int32],
              sc: V1Scenes.Scene, glShot: (ByteBuffer, FrameDiagnostics.Draw2dCounts), gpu: GpuShot): (String, Bool) \ IO =
        let (gl, glDraws) = glShot;
        LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.writePng(gl, width, height, "debug/gl/${sc#name}.png");
        LwjglLayer.Internal.WebGpuWindowLayer.V1Assets.writePng(gpu#pixels, width, height, "debug/webgpu/${sc#name}.png");
        let diff = diffOf(gl, gpu#pixels, width * height);
        let limit = Map.getWithDefault(sc#name, 0, limits);
        let submitsOk = Option.forAll(n -> n == gpu#submits, sc#submits);
        let drawsSame = drawKey(glDraws) == drawKey(gpu#draws);
        let drawsAsExpected = Option.forAll(e -> e == drawKey(glDraws), Map.get(sc#name, expectedDraws()));
        let ok = diff#maxDelta <= limit and submitsOk and drawsSame and drawsAsExpected;
        let drawNote = if (drawsSame and drawsAsExpected) "  ${drawText(glDraws)}"
                       else "  GL ${drawText(glDraws)}・WebGPU ${drawText(gpu#draws)}${if (drawsAsExpected) "" else "（期待と違う）"}";
        let verdict = if (ok) "OK" else "NG";
        let expectedSubmits = sc#submits |> Option.map(n -> "（期待 ${Int32.toString(n)}）") |> Option.getWithDefault("");
        ("[webgpu-v1] ${pad(sc#name, 18)} ${verdict}  差 ${Int32.toString(diff#pixels)} px max ±${Int32.toString(diff#maxDelta)}（許容 ${Int32.toString(limit)}）"
            + " submits ${Int32.toString(gpu#submits)}${expectedSubmits}${drawNote}", ok)

    pub def go(): Unit \ IO =
        let config = match (run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO) {
            case Ok(loaded) => loaded#config
            case Err(why)   => bug!("project.json を読めない: ${why}")
        };
        let glShots = match shootGl(config) {
            case Ok(shots) => shots
            case Err(why)  => bug!("GL を開けない: ${why}")
        };
        let gl = List.map(fst, glShots);
        let gpuOutcome = run { shootWebGpu(config) } with WebGpuDevice.runDawn;
        let (gpuShots, errors, lastError, adapter) = match gpuOutcome {
            case Ok(r)    => r
            case Err(why) => bug!("WebGPU を開けない: ${why}")
        };
        println("[webgpu-v1] adapter: ${adapter}");
        let limits = tolerances();
        let rows = List.zip(V1Scenes.all(), List.zip(glShots, gpuShots)) |> List.map(row -> {
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
        let pixelCount = config#designWidth * config#designHeight;
        let byName = List.zip(List.map(sc -> sc#name, V1Scenes.all()), List.zip(gl, List.map(g -> g#pixels, gpuShots))) |> List.toMap;
        let msaaDiff = match (Map.get("msaaPass", byName), Map.get("msaaOff", byName)) {
            case (Some((glOn, gpuOn)), Some((glOff, gpuOff))) => (diffOf(glOn, glOff, pixelCount)#pixels, diffOf(gpuOn, gpuOff, pixelCount)#pixels)
            case _                                            => (0, 0)
        };
        let msaaOk = fst(msaaDiff) > 0 and snd(msaaDiff) > 0;
        println("[webgpu-v1] 標本 4 と 1 の差 GL ${Int32.toString(fst(msaaDiff))} px・WebGPU ${Int32.toString(snd(msaaDiff))} px（0 なら MSAA が掛かっていない）");
        // WebGPU は標本 2 を 4 で描くので、標本 2 の場面の WebGPU の絵は標本 4 の場面と画素まで同じはず。
        let twoAsFour = match (Map.get("msaaTwo", byName), Map.get("msaaPass", byName)) {
            case (Some((_, gpuTwo)), Some((_, gpuFour))) => diffOf(gpuTwo, gpuFour, pixelCount)#pixels
            case _                                       => -1
        };
        println("[webgpu-v1] WebGPU の標本 2 と 4 の差 ${Int32.toString(twoAsFour)} px（0 でなければ標本 2 を 4 で描いていない）");
        let ok = errorsOk and controlOk and msaaOk and twoAsFour == 0 and List.forAll(snd, rows) and List.length(rows) == List.length(V1Scenes.all());
        println("[webgpu-v1] ${if (ok) "OK" else "NG"}");
        if (ok) () else System.exit(1)
}

def main(): Unit \ IO = V1Main.go()
