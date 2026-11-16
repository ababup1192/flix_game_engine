// Offscreen — 画面なしの WebGPU（Dawn）でコマを塗り、画素を BufferedImage で読む口（VideoOut の比べのコマの塗り）。
// 絵とフォントの読み込みは実機の WebGPU のウィンドウ（LwjglLayer.Internal.WebGpuWindowLayer）と同じ物を使う。
// WhyNot: WebGpuWindowLayer の読み込みを pub に開かない — 子孫の mod からは pub でない物が見えるので、ここに置けば足りる。
pub mod LwjglLayer.Internal.WebGpuWindowLayer.Offscreen {
    use LwjglLayer.Internal.WebGpuWindowLayer.{loadFonts, loadTextures}
    use RenderPaint.Internal.WebGpuPaint

    import fge.webgpu.WebGpu
    import java.awt.image.BufferedImage
    import java.nio.ByteBuffer

    enum SessionData({ gpu = WebGpu, paint = WebGpuPaint.Paint, fonts = RenderPaint.Fonts, width = Int32, height = Int32,
                       design = Vec2.Vec2, pixels = ByteBuffer })

    /// 開いた device・塗り先・読み込んだ絵とフォント。close で閉じる。
    pub type alias Session = SessionData

    /// device を開き、project の絵とフォントを上げる。width・height は出力の画素、clear は地の色。
    pub def open(config: GameEngine.EngineConfig, width: Int32, height: Int32, clear: Color): Result[String, Session] \ IO =
        match run { WebGpuDevice.requestDevice() } with WebGpuDevice.runDawn {
            case Err(why) => Err(why)
            case Ok(gpu)  =>
                let paint = WebGpuPaint.create(gpu, { designWidth = config#designWidth, designHeight = config#designHeight,
                                                      clearColor = clear, width = width, height = height });
                loadTextures(paint, config#textureManifest, (_, _) -> checked_ecast(()));
                let fonts = loadFonts(paint, config, (_, _, _) -> checked_ecast(()));
                Ok(SessionData.SessionData({ gpu = gpu, paint = paint, fonts = fonts, width = width, height = height,
                                             design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) },
                                             pixels = ByteBuffer.allocateDirect(width * height * 4) }))
        }

    /// アダプターの名前（Dawn が返す字）。
    pub def adapterOf(session: Session): String \ IO =
        let SessionData.SessionData(s) = session;
        s#gpu.adapterInfo()

    /// WebGPU の誤りの数と最後の誤りの文。
    pub def errorsOf(session: Session): (Int32, String) \ IO =
        let SessionData.SessionData(s) = session;
        (s#gpu.errorCount(), s#gpu.lastError())

    /// 今のフォントのアトラス（名前 → アトラス）。
    pub def fontTable(session: Session): Map[String, FontAtlas] \ IO =
        let SessionData.SessionData(s) = session;
        Ref.get(s#fonts#atlases)

    pub def close(session: Session): Unit \ IO =
        let SessionData.SessionData(s) = session;
        WebGpuPaint.release(s#paint);
        s#gpu.destroy()

    /// f の中の Platform の effect と Target を塗り先で受ける。入力・窓の問いには「何も起きていない」で答え、presentFrame でコマを締める。
    pub def handle(session: Session, f: Unit -> a \ ef): a \ (ef - GlOffscreen.HandledEffects) + IO =
        let SessionData.SessionData(s) = session;
        let paint = s#paint;
        WebGpuPaint.handleTarget(paint, () ->
        windowless(paint, s#design, () ->
        WebGpuPaint.handleDiagnostics(paint, () ->
        Platform.runTasksInPlace(() ->
        WebGpuPaint.handleDraw3d(paint, () ->
        WebGpuPaint.handleDraw2d(paint, (_, _, _) -> (), () ->
        WebGpuPaint.handleGpuResources(paint, s#fonts, f)))))))

    def windowless(paint: WebGpuPaint.Paint, design: Vec2.Vec2, f: Unit -> a \ ef):
            a \ (ef - Platform.Input - Platform.Window - Platform.FrameClock - Platform.Annotation) + IO =
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

    /// 最後に締めたコマを左上原点の RGB の絵で読む。
    // WhyNot: α を絵に残さない — 塗り先の α は重ねた半透明の分だけ 1 より下がっていて、実機の窓は α を見ない（VideoOut の GPU の道の rgb0 と同じ）。
    pub def readImage(session: Session): BufferedImage \ IO = region rc {
        let SessionData.SessionData(s) = session;
        let w = s#width;
        let h = s#height;
        WebGpuPaint.readFrame(s#paint, s#pixels);
        let ints = s#pixels.asIntBuffer();
        let rgb: Array[Int32, rc] = Array.empty(rc, w * h);
        List.forEach(y -> discard ints.get((h - 1 - y) * w, rgb, y * w, w), List.range(0, h));
        toRgb(rgb, 0, w * h);
        let image = new BufferedImage(w, h, 1i32);
        image.setRGB(0, 0, w, h, rgb, 0, w);
        image
    }

    /// RGBA（ビッグエンディアンの int）を RGB の int へ並べ替える。
    def toRgb(px: Array[Int32, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            Array.put(Int32.bitwiseAnd(Int32.rightShift(Array.get(i, px), 8), 16777215), i, px);
            toRgb(px, i + 1, n)
        }
}
