import com.github.xpenatan.webgpu.*;
import java.awt.image.BufferedImage;
import java.io.File;
import java.nio.ByteBuffer;
import javax.imageio.ImageIO;

public class Offscreen {
    static final String WGSL = """
        @vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
            var p = vec2f(0.0, 0.5);
            if (i == 0u) { p = vec2f(-0.5, -0.5); } else if (i == 1u) { p = vec2f(0.5, -0.5); }
            return vec4f(p, 0.0, 1.0);
        }
        @fragment fn fs_main() -> @location(0) vec4f { return vec4f(0.0, 0.4, 1.0, 1.0); }
        """;

    public static void main(String[] a) throws Exception {
        JWebGPUBackend be = a.length > 0 && a[0].equals("dawn") ? JWebGPUBackend.DAWN : JWebGPUBackend.WGPU;
        long t0 = System.nanoTime();
        Gpu g = Gpu.init(be);
        System.out.println("init ms=" + (System.nanoTime() - t0) / 1e6);
        int W = 256, H = 256;
        WGPUTextureDescriptor td = WGPUTextureDescriptor.obtain();
        td.setUsage(WGPUTextureUsage.RenderAttachment.or(WGPUTextureUsage.CopySrc));
        td.setDimension(WGPUTextureDimension._2D);
        td.getSize().setWidth(W); td.getSize().setHeight(H); td.getSize().setDepthOrArrayLayers(1);
        td.setFormat(WGPUTextureFormat.RGBA8Unorm);
        td.setMipLevelCount(1); td.setSampleCount(1);
        WGPUTexture tex = new WGPUTexture();
        g.device.createTexture(td, tex);
        WGPUTextureView view = WGPUTextureView.obtain();
        tex.createView(WGPUTextureViewDescriptor.NULL, view);

        WGPUShaderModule m = g.shader(WGSL);
        WGPURenderPipeline pipe = g.pipeline(m, WGPUTextureFormat.RGBA8Unorm, null, false);
        int bpr = 256 * 4;
        WGPUBuffer out = g.buffer((long) bpr * H, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));

        WGPUCommandEncoder enc = new WGPUCommandEncoder();
        g.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
        WGPURenderPassEncoder pass = g.beginPass(enc, view, 0.1f, 0.1f, 0.1f);
        pass.setPipeline(pipe);
        pass.draw(3, 1, 0, 0);
        pass.end(); pass.release();
        WGPUTexelCopyTextureInfo src = WGPUTexelCopyTextureInfo.obtain();
        src.setTexture(tex); src.setMipLevel(0); src.setAspect(WGPUTextureAspect.All);
        WGPUTexelCopyBufferInfo dst = WGPUTexelCopyBufferInfo.obtain();
        dst.setBuffer(out);
        dst.getLayout().setOffset(0); dst.getLayout().setBytesPerRow(bpr); dst.getLayout().setRowsPerImage(H);
        WGPUExtent3D ext = WGPUExtent3D.obtain();
        ext.setWidth(W); ext.setHeight(H); ext.setDepthOrArrayLayers(1);
        enc.copyTextureToBuffer(src, dst, ext);
        g.submit(enc);
        ByteBuffer px = g.readMapped(out, bpr * H);
        BufferedImage img = new BufferedImage(W, H, BufferedImage.TYPE_INT_ARGB);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int o = y * bpr + x * 4;
            int r = px.get(o) & 255, gg = px.get(o + 1) & 255, b = px.get(o + 2) & 255, al = px.get(o + 3) & 255;
            img.setRGB(x, y, (al << 24) | (r << 16) | (gg << 8) | b);
        }
        String path = a.length > 1 ? a[1] : "triangle.png";
        ImageIO.write(img, "png", new File(path));
        System.out.println("wrote " + path + " center=" + Integer.toHexString(img.getRGB(128, 150)) + " corner=" + Integer.toHexString(img.getRGB(2, 2)));
    }
}
