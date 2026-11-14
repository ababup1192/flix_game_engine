// WebGpuWindow — WebGPU（PC は Dawn）で描く GLFW のウィンドウ（LwjglLayer と同じ LWJGL の GLFW。旗は GLFW_NO_API）。
// まだゲームは通らない（LwjglLayer の GL のウィンドウを置き換える道はまだ無い）。
//
// 使い方（macOS は -XstartOnFirstThread の最初の糸で。LwjglLayer.ensureMainThread を先に呼ぶ）:
//   match WebGpuWindow.open(gpu, { width = 640, height = 360, title = "x", visible = true, presentMode = PresentMode.FIFO }, redraw) {
//       case Err(why)  => ウィンドウか描き先を作れない
//       case Ok(win)   =>
//           毎コマ: WebGpuWindow.pollEvents(); let tex = surfaceOf(win).getCurrentTexture(); 描く; surfaceOf(win).present()
//           WebGpuWindow.close(win)
//   }
// redraw はウィンドウの大きさが変わって描き先を作り直した直後に呼ばれる（macOS は端を掴んでいる間 pollEvents が戻らないので、その間の絵はここで描く）。
pub mod WebGpuWindow {
    import fge.webgpu.PresentMode
    import fge.webgpu.Surface
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.dawn.DawnWebGpu
    import org.lwjgl.glfw.Callbacks
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.glfw.GLFWFramebufferSizeCallbackI
    import org.lwjgl.glfw.GLFWNativeCocoa
    import org.lwjgl.system.JNI
    import org.lwjgl.system.MemoryUtil
    import org.lwjgl.system.macosx.ObjCRuntime
    import java.lang.System
    import java.lang.Throwable

    /// 開いたウィンドウ。外から作らせない（open だけが作る）。
    /// size = 今の描き先の画素の大きさ（大きさが変わった callback が書く）・resizes = 作り直した回数。
    enum WindowData {
        case WindowData({
            window = Int64,
            nsWindow = Int64,
            surface = Surface,
            format = TextureFormat,
            presentMode = PresentMode,
            size = Ref[(Int32, Int32), Static],
            resizes = Ref[Int32, Static]
        })
    }

    pub type alias Window = WindowData

    /// ウィンドウを開く時の値。
    pub type alias Config = { width = Int32, height = Int32, title = String, visible = Bool, presentMode = PresentMode }

    /// 描き先の texture の使い道（描く・present の前に読み戻す）。
    def surfaceUsage(): Int32 = Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.COPY_SRC)

    /// GLFW のウィンドウを開き、gpu の device で描き先を作って configure する。作れなければ Err(理由)。
    /// ウィンドウは大きさを変えられる。大きさが変わると描き先を作り直し、redraw(描き先, 幅, 高さ) を呼ぶ。
    pub def open(gpu: DawnWebGpu, cfg: Config, redraw: (Surface, Int32, Int32) -> Unit \ IO): Result[String, Window] \ IO =
        discard System.setProperty("java.awt.headless", "true");
        if (not GLFW.glfwInit()) Err("GLFW を初期化できない")
        else {
            GLFW.glfwDefaultWindowHints();
            GLFW.glfwWindowHint(GLFW.GLFW_CLIENT_API, GLFW.GLFW_NO_API);
            GLFW.glfwWindowHint(GLFW.GLFW_RESIZABLE, GLFW.GLFW_TRUE);
            GLFW.glfwWindowHint(GLFW.GLFW_VISIBLE, if (cfg#visible) GLFW.GLFW_TRUE else GLFW.GLFW_FALSE);
            let window = GLFW.glfwCreateWindow(cfg#width, cfg#height, cfg#title, MemoryUtil.NULL, MemoryUtil.NULL);
            if (window == 0i64) Err("GLFW のウィンドウを作れない")
            else attachSurface(gpu, window, cfg, redraw)
        }

    def attachSurface(gpu: DawnWebGpu, window: Int64, cfg: Config, redraw: (Surface, Int32, Int32) -> Unit \ IO): Result[String, Window] \ IO =
        try {
            let nsWindow = GLFWNativeCocoa.glfwGetCocoaWindow(window);
            let surface = gpu.createMacSurface(nsWindow);
            let format = surface.preferredFormat();
            let (fbW, fbH) = framebufferSizeOf(window);
            surface.configure(fbW, fbH, format, cfg#presentMode, surfaceUsage());
            let size = Ref.fresh(Static, (fbW, fbH));
            let resizes = Ref.fresh(Static, 0);
            // WhyNot: 毎コマ大きさを問い合わせて作り直すだけにしない — macOS は端を掴んでいる間 pollEvents が戻らず、その間の絵が古い大きさのまま伸びる。
            // WhyNot: Dawn の Suboptimal・Outdated を待たない — Dawn は大きさが変わっても SuccessOptimal を返し続ける。
            discard GLFW.glfwSetFramebufferSizeCallback(window, new GLFWFramebufferSizeCallbackI {
                def invoke(_this: GLFWFramebufferSizeCallbackI, _cbWindow: Int64, width: Int32, height: Int32): Unit \ IO =
                    if (width <= 0 or height <= 0) ()
                    else {
                        surface.configure(width, height, format, cfg#presentMode, surfaceUsage());
                        Ref.put((width, height), size);
                        Ref.put(Ref.get(resizes) + 1, resizes);
                        redraw(surface, width, height)
                    }
            });
            Ok(WindowData.WindowData({ window = window, nsWindow = nsWindow, surface = surface, format = format,
                                       presentMode = cfg#presentMode, size = size, resizes = resizes }))
        } catch {
            case e: Throwable =>
                GLFW.glfwDestroyWindow(window);
                Err("ウィンドウの描き先を作れない: ${e.toString()}")
        }

    def framebufferSizeOf(window: Int64): (Int32, Int32) \ IO =
        let w = Array.empty(Static, 1);
        let h = Array.empty(Static, 1);
        GLFW.glfwGetFramebufferSize(window, w, h);
        (Array.get(0, w), Array.get(0, h))

    /// ウィンドウの描き先。
    pub def surfaceOf(win: Window): Surface =
        let WindowData.WindowData(w) = win;
        w#surface

    /// 描き先の画素の形。
    pub def formatOf(win: Window): TextureFormat =
        let WindowData.WindowData(w) = win;
        w#format

    /// 今の描き先の画素の大きさ。
    pub def sizeOf(win: Window): (Int32, Int32) \ IO =
        let WindowData.WindowData(w) = win;
        Ref.get(w#size)

    /// 大きさが変わって描き先を作り直した回数。
    pub def resizeCount(win: Window): Int32 \ IO =
        let WindowData.WindowData(w) = win;
        Ref.get(w#resizes)

    /// ウィンドウの大きさ（ポイント）。描き先の画素の大きさと比べると Retina の倍率が分かる。
    pub def windowSizeOf(win: Window): (Int32, Int32) \ IO =
        let WindowData.WindowData(w) = win;
        let ww = Array.empty(Static, 1);
        let hh = Array.empty(Static, 1);
        GLFW.glfwGetWindowSize(w#window, ww, hh);
        (Array.get(0, ww), Array.get(0, hh))

    /// ウィンドウが載っている表示の倍率（NSWindow の backingScaleFactor）。
    pub def backingScaleOf(win: Window): Float64 \ IO =
        let WindowData.WindowData(w) = win;
        let msgSend = ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");
        JNI.invokePPD(w#nsWindow, ObjCRuntime.sel_getUid("backingScaleFactor"), msgSend)

    /// screencapture -l に渡すウィンドウの番号（NSWindow の windowNumber）。
    pub def windowNumberOf(win: Window): Int64 \ IO =
        let WindowData.WindowData(w) = win;
        let msgSend = ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");
        JNI.invokePPP(w#nsWindow, ObjCRuntime.sel_getUid("windowNumber"), msgSend)

    /// ウィンドウの大きさ（ポイント）を変える。描き先の作り直しは callback が pollEvents の中で行う。
    pub def setWindowSize(win: Window, width: Int32, height: Int32): Unit \ IO =
        let WindowData.WindowData(w) = win;
        GLFW.glfwSetWindowSize(w#window, width, height)

    /// ウィンドウの出来事を受け取る（大きさが変わった callback もここで走る）。
    pub def pollEvents(): Unit \ IO = GLFW.glfwPollEvents()

    /// ウィンドウの閉じるボタンが押されたか。
    pub def shouldClose(win: Window): Bool \ IO =
        let WindowData.WindowData(w) = win;
        GLFW.glfwWindowShouldClose(w#window)

    /// 描き先を捨て、ウィンドウを閉じる。
    pub def close(win: Window): Unit \ IO =
        let WindowData.WindowData(w) = win;
        w#surface.release();
        Callbacks.glfwFreeCallbacks(w#window);
        GLFW.glfwDestroyWindow(w#window);
        GLFW.glfwTerminate()
}
