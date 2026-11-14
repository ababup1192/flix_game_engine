import com.github.xpenatan.jParser.api.NativeObject;
import com.github.xpenatan.webgpu.*;
import java.util.Arrays;
import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.glfw.GLFWNativeCocoa.glfwGetCocoaWindow;

public class Window {
    public static void main(String[] a) throws Exception {
        JWebGPUBackend be = a.length > 0 && a[0].equals("dawn") ? JWebGPUBackend.DAWN : JWebGPUBackend.WGPU;
        boolean vsync = !(a.length > 1 && a[1].equals("novsync"));
        if (!glfwInit()) throw new IllegalStateException("glfwInit");
        glfwDefaultWindowHints();
        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        long win = glfwCreateWindow(800, 600, "wgpu spike", 0, 0);
        for (int i = 0; i < 30; i++) { glfwPollEvents(); Thread.sleep(10); }
        long cocoa = glfwGetCocoaWindow(win);
        System.out.println("cocoa NSWindow=0x" + Long.toHexString(cocoa));
        Gpu g = Gpu.init(be);
        String hm = a.length > 2 ? a[2] : "window";
        long handle = cocoa;
        if (hm.equals("view")) handle = Mac.contentView(cocoa);
        else if (hm.equals("layer")) handle = Mac.installMetalLayer(cocoa);
        System.out.println("handle mode=" + hm + " 0x" + Long.toHexString(handle));
        NativeObject h = NativeObject.native_new().native_setAddress(handle);
        long t0 = System.nanoTime();
        WGPUSurface surface = g.instance.createMacSurface(h);
        System.out.println("createMacSurface ms=" + (System.nanoTime() - t0) / 1e6 + " valid=" + (surface != null));
        WGPUSurfaceCapabilities caps = new WGPUSurfaceCapabilities();
        surface.getCapabilities(g.adapter, caps);
        for (int i = 0; i < caps.getFormats().size(); i++) System.out.println("cap format[" + i + "]=" + caps.getFormats().get(i) + " raw=" + caps.getFormats().get(i).getValue());
        WGPUTextureFormat fmt = a.length > 3 && a[3].equals("bgra") ? WGPUTextureFormat.BGRA8Unorm : caps.getFormats().get(0);
        System.out.println("surface format=" + fmt);
        int[] fw = new int[1], fh = new int[1];
        org.lwjgl.glfw.GLFW.glfwGetFramebufferSize(win, fw, fh);
        System.out.println("framebuffer " + fw[0] + "x" + fh[0]);
        WGPUSurfaceConfiguration cfg = WGPUSurfaceConfiguration.obtain();
        cfg.setWidth(fw[0]); cfg.setHeight(fh[0]);
        cfg.setFormat(fmt);
        cfg.setViewFormats(WGPUVectorTextureFormat.NULL);
        cfg.setUsage(WGPUTextureUsage.RenderAttachment);
        cfg.setDevice(g.device);
        cfg.setPresentMode(vsync ? WGPUPresentMode.Fifo : WGPUPresentMode.Immediate);
        cfg.setAlphaMode(WGPUCompositeAlphaMode.Auto);
        surface.configure(cfg);
        WGPUShaderModule m = g.shader(Offscreen.WGSL);
        WGPURenderPipeline pipe = g.pipeline(m, fmt, null, false);
        int N = Integer.getInteger("frames", 120);
        int hold = Integer.getInteger("holdMs", 0);
        long wall0 = System.nanoTime();
        double[] ms = new double[N], cpu = new double[N];
        for (int f = 0; f < N; f++) {
            long s = System.nanoTime();
            glfwPollEvents();
            WGPUSurfaceTexture st = WGPUSurfaceTexture.obtain();
            surface.getCurrentTexture(st);
            if (f < 3) System.out.println("frame "+f+" status "+st.getStatus()+" raw="+st.getStatus().getValue());
            WGPUTexture tex = WGPUTexture.obtain();
            st.getTexture(tex);
            if (!tex.isValid()) { System.out.println("frame "+f+" texture invalid"); continue; }
            WGPUTextureView view = WGPUTextureView.obtain();
            tex.createView(WGPUTextureViewDescriptor.NULL, view);
            WGPUCommandEncoder enc = new WGPUCommandEncoder();
            g.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
            float t = f / 120f;
            WGPURenderPassEncoder pass = g.beginPass(enc, view, 0.1f + 0.2f * t, 0.1f, 0.2f);
            pass.setPipeline(pipe);
            pass.draw(3, 1, 0, 0);
            pass.end(); pass.release();
            g.submit(enc);
            long c = System.nanoTime();
            view.release();
            surface.present();
            if (be == JWebGPUBackend.DAWN) tex.release();
            ms[f] = (System.nanoTime() - s) / 1e6;
            if (hold > 0) { try { Thread.sleep(hold); } catch (InterruptedException e) {} }
            cpu[f] = (c - s) / 1e6;
        }
        double wall = (System.nanoTime() - wall0) / 1e6;
        System.out.printf("wall for %d frames = %.1f ms (%.2f ms/frame avg)%n", N, wall, wall / N);
        double[] sorted = ms.clone(); Arrays.sort(sorted);
        double[] sc = cpu.clone(); Arrays.sort(sc);
        System.out.printf("%s vsync=%b frames=%d frame ms: median=%.2f p90=%.2f max=%.2f | encode+submit cpu ms median=%.3f%n", be, vsync, N, sorted[N/2], sorted[N*9/10], sorted[N-1], sc[N/2]);
        glfwDestroyWindow(win);
        glfwTerminate();
        System.exit(0);
    }
}
