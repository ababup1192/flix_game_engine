import com.github.xpenatan.jParser.api.NativeObject;
import com.github.xpenatan.webgpu.*;
import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.ByteBuffer;
import java.util.Arrays;
import javax.imageio.ImageIO;
import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.glfw.GLFWNativeCocoa.glfwGetCocoaWindow;

/**
 * GLFW（engine と同じ LWJGL 3.4.1・GLFW_NO_API）の窓に Dawn で三角形を描き、
 * (a) present の前に surface の texture を読み戻す (b) screencapture -l で窓を撮る、の 2 通りで確かめる。
 * 設定は -D: fmt=bgra|srgb|auto present=fifo|immediate|mailbox retina=true|false visible=true|false
 *            w=640 h=360 resize=true shot=<出力の頭>
 */
public class WinCheck {
    static final String WGSL = """
        @vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
            var p = vec2f(0.0, 0.5);
            if (i == 0u) { p = vec2f(-0.5, -0.5); } else if (i == 1u) { p = vec2f(0.5, -0.5); }
            return vec4f(p, 0.0, 1.0);
        }
        @fragment fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.5, 0.25, 1.0); }
        """;
    static final float CLEAR = 0.2f;
    static int fails = 0;

    public static void main(String[] a) throws Exception {
        String fmtOpt = System.getProperty("fmt", "bgra");
        String pm = System.getProperty("present", "fifo");
        boolean retina = Boolean.parseBoolean(System.getProperty("retina", "true"));
        boolean visible = Boolean.parseBoolean(System.getProperty("visible", "true"));
        boolean doResize = Boolean.parseBoolean(System.getProperty("resize", "true"));
        int ww = Integer.getInteger("w", 640), wh = Integer.getInteger("h", 360);
        String shot = System.getProperty("shot", "shots/win");
        System.out.println("main thread=" + Thread.currentThread().getName() + " JAVA_STARTED_ON_FIRST_THREAD="
            + System.getenv("JAVA_STARTED_ON_FIRST_THREAD_" + ProcessHandle.current().pid()));

        if (!glfwInit()) throw new IllegalStateException("glfwInit");
        glfwDefaultWindowHints();
        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
        glfwWindowHint(GLFW_COCOA_RETINA_FRAMEBUFFER, retina ? GLFW_TRUE : GLFW_FALSE);
        glfwWindowHint(GLFW_VISIBLE, visible ? GLFW_TRUE : GLFW_FALSE);
        long win = glfwCreateWindow(ww, wh, "webgpu wincheck", 0, 0);
        if (visible) { glfwShowWindow(win); glfwFocusWindow(win); }
        for (int i = 0; i < 20; i++) { glfwPollEvents(); Thread.sleep(5); }
        long cocoa = glfwGetCocoaWindow(win);
        long wid = Mac.windowNumber(cocoa);
        System.out.printf("NSWindow=0x%x windowNumber=%d backingScale=%.1f layer(before)=%s%n",
            cocoa, wid, Mac.backingScale(cocoa), Mac.className(Mac.viewLayer(cocoa)));

        boolean worker = System.getProperty("surfaceThread", "main").equals("worker");
        Gpu[] gh = {null};
        WGPUSurface[] sh = {null};
        Runnable mk = () -> {
            gh[0] = Gpu.init(JWebGPUBackend.DAWN);
            NativeObject h = NativeObject.native_new().native_setAddress(cocoa);
            sh[0] = gh[0].instance.createMacSurface(h);
            System.out.println("device+surface made on thread " + Thread.currentThread().getName());
        };
        if (worker) { Thread t = new Thread(mk, "worker"); t.start(); t.join(); } else mk.run();
        Gpu g = gh[0];
        WGPUSurface surface = sh[0];
        long layer = Mac.viewLayer(cocoa);
        System.out.printf("layer(after)=%s contentsScale=%.1f%n", Mac.className(layer), Mac.contentsScale(layer));
        WGPUSurfaceCapabilities caps = new WGPUSurfaceCapabilities();
        surface.getCapabilities(g.adapter, caps);
        StringBuilder fs = new StringBuilder();
        for (int i = 0; i < caps.getFormats().size(); i++) fs.append(caps.getFormats().get(i)).append(' ');
        System.out.println("surface formats: " + fs);
        WGPUTextureFormat fmt = switch (fmtOpt) {
            case "srgb" -> WGPUTextureFormat.BGRA8UnormSrgb;
            case "auto" -> caps.getFormats().get(0);
            default -> WGPUTextureFormat.BGRA8Unorm;
        };
        boolean srgb = fmt == WGPUTextureFormat.BGRA8UnormSrgb;
        WGPUPresentMode mode = switch (pm) {
            case "immediate" -> WGPUPresentMode.Immediate;
            case "mailbox" -> WGPUPresentMode.Mailbox;
            default -> WGPUPresentMode.Fifo;
        };
        int[] fb = fbSize(win);
        System.out.println("framebuffer " + fb[0] + "x" + fb[1] + " fmt=" + fmt + " present=" + mode);
        configure(surface, g, fb, fmt, mode);
        WGPURenderPipeline pipe = g.pipeline(g.shader(WGSL), fmt, null, false);

        // 120 コマ描く。60 コマ目は present の前に読み戻す。
        int N = Integer.getInteger("frames", 120);
        double[] frameMs = new double[N], acqMs = new double[N], presMs = new double[N];
        int[] statusCount = new int[16];
        long prev = System.nanoTime();
        for (int f = 0; f < N; f++) {
            glfwPollEvents();
            long ta = System.nanoTime();
            WGPUTexture tex = frame(g, surface, pipe, statusCount);
            acqMs[f] = (System.nanoTime() - ta) / 1e6;
            if (tex == null) continue;
            if (f == 60) checkReadback(g, tex, fb, srgb, shot + "_readback.png", "readback");
            long tp = System.nanoTime();
            surface.present();
            presMs[f] = (System.nanoTime() - tp) / 1e6;
            tex.release();
            g.instance.processEvents();
            long now = System.nanoTime();
            frameMs[f] = (now - prev) / 1e6; prev = now;
        }
        double[] s = Arrays.copyOfRange(frameMs, 10, N); Arrays.sort(s);
        System.out.printf("RESULT present %s: frame interval median=%.3f ms p10=%.3f p90=%.3f (frames 10..%d) status=%s%n",
            mode, s[s.length / 2], s[s.length / 10], s[s.length * 9 / 10], N, statusStr(statusCount));
        double[] sa = Arrays.copyOfRange(acqMs, 10, N); Arrays.sort(sa);
        double[] sp = Arrays.copyOfRange(presMs, 10, N); Arrays.sort(sp);
        System.out.printf("RESULT present %s: acquire+encode+submit median=%.3f ms max=%.3f | present() median=%.3f ms max=%.3f%n",
            mode, sa[sa.length / 2], sa[sa.length - 1], sp[sp.length / 2], sp[sp.length - 1]);

        // 窓を撮る。撮っている間も描き続ける（main thread を止めない）。
        if (visible) {
            String cap = shot + "_screencapture.png";
            String sck = shot + "_sck.png";
            new File(cap).delete();
            new File(sck).delete();
            runWhileDrawing(g, surface, pipe, statusCount, "screencapture", "-x", "-o", "-l" + wid, "-t", "png", cap);
            runWhileDrawing(g, surface, pipe, statusCount, System.getProperty("wincap", "out/wincap"), Long.toString(wid), sck);
            checkCapture(cap, fb, srgb);
            checkCapture(sck, fb, srgb);
        }

        if (doResize) {
            int nw = ww + 160, nh = wh + 90;
            glfwSetWindowSize(win, nw, nh);
            for (int i = 0; i < 30; i++) { glfwPollEvents(); Thread.sleep(5); }
            int[] fb2 = fbSize(win);
            System.out.println("resized window to " + nw + "x" + nh + " pt, framebuffer " + fb2[0] + "x" + fb2[1]);
            int[] sc = new int[16];
            WGPUTexture stale = frame(g, surface, pipe, sc);
            System.out.println("before reconfigure: getCurrentTexture status=" + statusStr(sc));
            if (stale != null) { surface.present(); stale.release(); }
            configure(surface, g, fb2, fmt, mode);
            int[] sc2 = new int[16];
            WGPUTexture tex = frame(g, surface, pipe, sc2);
            System.out.println("after reconfigure: status=" + statusStr(sc2));
            if (tex != null) {
                checkReadback(g, tex, fb2, srgb, shot + "_resized_readback.png", "resized");
                surface.present(); tex.release();
            } else fails++;
        }
        g.instance.processEvents();
        if (Boolean.getBoolean("lsof")) {
            new ProcessBuilder("sh", "-c", "lsof -p " + ProcessHandle.current().pid() + " | awk '{print $NF}' | grep dylib | grep -v -e ^/System -e ^/usr/lib").inheritIO().start().waitFor();
        }
        System.out.println("RESULT wincheck fmt=" + fmt + " retina=" + retina + " visible=" + visible + " present=" + mode
            + " fails=" + fails + " gpuErrors=" + Gpu.errors);
        glfwDestroyWindow(win);
        glfwTerminate();
        System.exit(fails == 0 && Gpu.errors == 0 ? 0 : 1);
    }

    /** 外のプロセスを走らせ、終わるまで描いて present し続ける（窓の main thread を止めない）。 */
    static void runWhileDrawing(Gpu g, WGPUSurface surface, WGPURenderPipeline pipe, int[] statusCount, String... cmd) throws Exception {
        Process p = new ProcessBuilder(cmd).inheritIO().start();
        long t0 = System.nanoTime();
        while (p.isAlive() && System.nanoTime() - t0 < 15_000_000_000L) {
            glfwPollEvents();
            WGPUTexture tex = frame(g, surface, pipe, statusCount);
            if (tex != null) { surface.present(); tex.release(); }
            Thread.sleep(4);
        }
        System.out.println(cmd[0] + " exit=" + (p.isAlive() ? "timeout" : p.exitValue()));
        if (p.isAlive()) p.destroyForcibly();
    }

    static int[] fbSize(long win) { int[] w = new int[1], h = new int[1]; glfwGetFramebufferSize(win, w, h); return new int[]{w[0], h[0]}; }

    static void configure(WGPUSurface surface, Gpu g, int[] fb, WGPUTextureFormat fmt, WGPUPresentMode mode) {
        WGPUSurfaceConfiguration cfg = WGPUSurfaceConfiguration.obtain();
        cfg.setWidth(fb[0]); cfg.setHeight(fb[1]);
        cfg.setFormat(fmt);
        cfg.setViewFormats(WGPUVectorTextureFormat.NULL);
        cfg.setUsage(WGPUTextureUsage.RenderAttachment.or(WGPUTextureUsage.CopySrc));
        cfg.setDevice(g.device);
        cfg.setPresentMode(mode);
        cfg.setAlphaMode(WGPUCompositeAlphaMode.Auto);
        surface.configure(cfg);
    }

    /** 描き先を取り、三角形を描いて submit する。present はしない。 */
    static WGPUTexture frame(Gpu g, WGPUSurface surface, WGPURenderPipeline pipe, int[] statusCount) {
        WGPUSurfaceTexture st = WGPUSurfaceTexture.obtain();
        surface.getCurrentTexture(st);
        int sv = st.getStatus().getValue();
        statusCount[Math.min(Math.max(sv, 0), 15)]++;
        WGPUTexture tex = new WGPUTexture();
        st.getTexture(tex);
        if (!tex.isValid()) return null;
        WGPUTextureView view = new WGPUTextureView();
        tex.createView(WGPUTextureViewDescriptor.NULL, view);
        WGPUCommandEncoder enc = new WGPUCommandEncoder();
        g.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
        WGPURenderPassEncoder pass = g.beginPass(enc, view, CLEAR, CLEAR, CLEAR);
        pass.setPipeline(pipe);
        pass.draw(3, 1, 0, 0);
        pass.end(); pass.release();
        g.submit(enc);
        view.release();
        return tex;
    }

    static String statusStr(int[] c) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < c.length; i++) if (c[i] > 0) b.append(i).append('=').append(c[i]).append(' ');
        return b.toString().trim() + " (1=SuccessOptimal 2=SuccessSuboptimal 3=Timeout 4=Outdated 5=Lost 6=Error)";
    }

    static int[] expected(boolean srgb, boolean tri) {
        // 1.0, 0.5, 0.25 / 0.2 を 8 ビットに。sRGB の view では書く時に sRGB の曲線が掛かる。
        if (!srgb) return tri ? new int[]{255, 128, 64} : new int[]{51, 51, 51};
        return tri ? new int[]{255, 188, 137} : new int[]{124, 124, 124};
    }

    static boolean near(int[] got, int[] exp, int tol) {
        for (int i = 0; i < 3; i++) if (Math.abs(got[i] - exp[i]) > tol) return false;
        return true;
    }

    /** BGRA で読み戻した画素を確かめ PNG にする。(0.3w,0.7h) が三角形の中・(0.3w,0.3h) が外・中心の下も中なら上下も合っている。 */
    static void checkReadback(Gpu g, WGPUTexture tex, int[] fb, boolean srgb, String path, String tag) throws Exception {
        int W = fb[0], H = fb[1], bpr = Gpu.rowBytes(W);
        ByteBuffer px = g.readTexture(tex, W, H);
        BufferedImage img = new BufferedImage(W, H, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int o = y * bpr + x * 4;
            int b = px.get(o) & 255, gg = px.get(o + 1) & 255, r = px.get(o + 2) & 255;
            img.setRGB(x, y, (r << 16) | (gg << 8) | b);
        }
        new File(path).getParentFile().mkdirs();
        ImageIO.write(img, "png", new File(path));
        int[][] pts = {{(int) (0.3 * W), (int) (0.7 * H)}, {W / 2, (int) (0.6 * H)}, {(int) (0.3 * W), (int) (0.3 * H)}, {3, 3}};
        boolean[] inTri = {true, true, false, false};
        StringBuilder sb = new StringBuilder();
        boolean ok = true;
        for (int i = 0; i < pts.length; i++) {
            int[] c = rgb(img.getRGB(pts[i][0], pts[i][1]));
            boolean m = near(c, expected(srgb, inTri[i]), 1);
            ok &= m;
            sb.append(String.format(" (%d,%d)=%d,%d,%d%s", pts[i][0], pts[i][1], c[0], c[1], c[2], m ? "" : "!"));
        }
        if (!ok) fails++;
        System.out.println("RESULT " + tag + " " + W + "x" + H + (ok ? " OK" : " NG") + sb + " -> " + path);
    }

    static int[] rgb(int v) { return new int[]{(v >> 16) & 255, (v >> 8) & 255, v & 255}; }

    /** screencapture の絵は題名の帯を含む。中身は下の fb の高さ（倍率は絵の幅 / fb の幅で合わせる）。 */
    static void checkCapture(String path, int[] fb, boolean srgb) throws Exception {
        File f = new File(path);
        if (!f.exists()) { System.out.println("RESULT capture NG: file missing"); fails++; return; }
        BufferedImage img = ImageIO.read(f);
        int W = img.getWidth(), H = img.getHeight();
        double sc = (double) W / fb[0];
        int ch = (int) Math.round(fb[1] * sc), top = H - ch;
        int triCount = 0, clearCount = 0, black = 0, total = 0;
        for (int y = top; y < H; y++) for (int x = 0; x < W; x++) {
            int[] c = rgb(img.getRGB(x, y));
            total++;
            if (c[0] > 200 && c[1] > 90 && c[1] < 220 && c[2] < 170 && c[0] > c[1] && c[1] > c[2]) triCount++;
            else if (Math.abs(c[0] - c[1]) < 6 && Math.abs(c[1] - c[2]) < 6 && c[0] > 30 && c[0] < 150) clearCount++;
            if (c[0] + c[1] + c[2] < 10) black++;
        }
        int[] in = rgb(img.getRGB((int) (0.3 * W), top + (int) (0.7 * ch)));
        int[] out = rgb(img.getRGB((int) (0.3 * W), top + (int) (0.3 * ch)));
        double triFrac = triCount / (double) total;
        // 三角形の面積は中身の 1/8（底 0.5w × 高さ 0.5h / 2）。
        boolean ok = triFrac > 0.10 && triFrac < 0.15 && in[0] > 200 && out[0] < 150;
        if (!ok) fails++;
        System.out.printf("RESULT capture %dx%d scale=%.2f content-top=%d tri=%.4f clear=%.4f black=%.4f in=%d,%d,%d out=%d,%d,%d (expect tri~%s clear~%s) %s -> %s%n",
            W, H, sc, top, triFrac, clearCount / (double) total, black / (double) total, in[0], in[1], in[2], out[0], out[1], out[2],
            Arrays.toString(expected(srgb, true)), Arrays.toString(expected(srgb, false)), ok ? "OK" : "NG", path);
    }
}
