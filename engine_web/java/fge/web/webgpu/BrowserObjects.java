package fge.web.webgpu;

import fge.webgpu.IndexFormat;
import fge.webgpu.PresentMode;
import fge.webgpu.RenderPassDesc;
import fge.webgpu.SurfaceStatus;
import fge.webgpu.TextureFormat;
import org.teavm.jso.JSBody;
import org.teavm.jso.webgpu.GPUBindGroup;
import org.teavm.jso.webgpu.GPUBuffer;
import org.teavm.jso.webgpu.GPUCanvasContext;
import org.teavm.jso.webgpu.GPUCommandEncoder;
import org.teavm.jso.webgpu.GPUDescriptor;
import org.teavm.jso.webgpu.GPUDevice;
import org.teavm.jso.webgpu.GPUPipeline;
import org.teavm.jso.webgpu.GPURenderPassEncoder;
import org.teavm.jso.webgpu.GPUSampler;
import org.teavm.jso.webgpu.GPUShaderModule;
import org.teavm.jso.webgpu.GPUTexture;

/**
 * ブラウザの WebGPU の物を包む小さな型。外へは fge.webgpu の interface で見せる（Dawn の側は DawnObjects）。
 * WhyNot: JS の物を Flix へ直に渡さない — Flix の総称のデータや Object を受ける所へ JS の物が入ると、TeaVM は通るのに
 *   ブラウザが wasm を読む所でモジュールごと落ちる。包みの欄は JS の物の型のまま持つ（Java の欄に持つのは通る）。
 * WhyNot: release で JS の物を手放さない — WebGPU の JS には buffer・texture・query set の destroy しか無く、ほかは GC に任せる。
 */
final class BrowserObjects {
    private BrowserObjects() {}

    static final class BrowserBuffer implements fge.webgpu.Buffer {
        final GPUBuffer buffer;
        final long size;
        private boolean destroyed;

        BrowserBuffer(GPUBuffer buffer, long size) {
            this.buffer = buffer;
            this.size = size;
        }

        @Override public long size() { return size; }

        @Override public void destroy() {
            if (destroyed) return;
            destroyed = true;
            buffer.destroy();
        }
    }

    static final class BrowserTexture implements fge.webgpu.Texture {
        final GPUTexture texture;
        final int width;
        final int height;
        final TextureFormat format;
        /** canvas の texture は canvas が持ち主（コマの終わりに入れ替わる）。 */
        final boolean owned;
        private BrowserTextureView defaultView;
        private boolean destroyed;

        BrowserTexture(GPUTexture texture, int width, int height, TextureFormat format, boolean owned) {
            this.texture = texture;
            this.width = width;
            this.height = height;
            this.format = format;
            this.owned = owned;
        }

        @Override public int width() { return width; }
        @Override public int height() { return height; }
        @Override public TextureFormat format() { return format; }

        @Override public fge.webgpu.TextureView createView() { return new BrowserTextureView(texture.createView()); }

        @Override public fge.webgpu.TextureView defaultView() {
            if (defaultView == null) defaultView = new BrowserTextureView(texture.createView());
            return defaultView;
        }

        @Override public void destroy() {
            if (destroyed) return;
            destroyed = true;
            if (owned) texture.destroy();
        }
    }

    static final class BrowserTextureView implements fge.webgpu.TextureView {
        final GPUTexture.View view;

        BrowserTextureView(GPUTexture.View view) { this.view = view; }

        @Override public void release() { }
    }

    static final class BrowserSampler implements fge.webgpu.Sampler {
        final GPUSampler sampler;

        BrowserSampler(GPUSampler sampler) { this.sampler = sampler; }

        @Override public void release() { }
    }

    static final class BrowserShaderModule implements fge.webgpu.ShaderModule {
        final GPUShaderModule module;

        BrowserShaderModule(GPUShaderModule module) { this.module = module; }

        @Override public void release() { }
    }

    static final class BrowserBindGroupLayout implements fge.webgpu.BindGroupLayout {
        final GPUBindGroup.Layout layout;

        BrowserBindGroupLayout(GPUBindGroup.Layout layout) { this.layout = layout; }

        @Override public void release() { }
    }

    static final class BrowserBindGroup implements fge.webgpu.BindGroup {
        final GPUBindGroup group;

        BrowserBindGroup(GPUBindGroup group) { this.group = group; }

        @Override public void release() { }
    }

    static final class BrowserRenderPipeline implements fge.webgpu.RenderPipeline {
        final GPUPipeline.Render pipeline;

        BrowserRenderPipeline(GPUPipeline.Render pipeline) { this.pipeline = pipeline; }

        @Override public void release() { }
    }

    static final class BrowserQuerySet implements fge.webgpu.QuerySet {
        final GPUDevice.QuerySet querySet;
        final int count;
        private boolean destroyed;

        BrowserQuerySet(GPUDevice.QuerySet querySet, int count) {
            this.querySet = querySet;
            this.count = count;
        }

        @Override public int count() { return count; }

        @Override public void destroy() {
            if (destroyed) return;
            destroyed = true;
            querySet.destroy();
        }
    }

    static final class BrowserCommandBuffer implements fge.webgpu.CommandBuffer {
        final GPUCommandEncoder.CommandBuffer commands;

        BrowserCommandBuffer(GPUCommandEncoder.CommandBuffer commands) { this.commands = commands; }
    }

    static final class BrowserRenderPass implements fge.webgpu.RenderPass {
        final GPURenderPassEncoder pass;

        BrowserRenderPass(GPURenderPassEncoder pass) { this.pass = pass; }

        @Override public void setPipeline(fge.webgpu.RenderPipeline pipeline) {
            pass.setPipeline(((BrowserRenderPipeline) pipeline).pipeline);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group) {
            pass.setBindGroup(index, ((BrowserBindGroup) group).group);
        }

        @Override public void setVertexBuffer(int slot, fge.webgpu.Buffer buffer, long offset, long size) {
            pass.setVertexBuffer(slot, ((BrowserBuffer) buffer).buffer, offset, size);
        }

        @Override public void setIndexBuffer(fge.webgpu.Buffer buffer, IndexFormat format, long offset, long size) {
            pass.setIndexBuffer(((BrowserBuffer) buffer).buffer, format == IndexFormat.UINT16 ? "uint16" : "uint32", offset, size);
        }

        @Override public void setViewport(double x, double y, double width, double height, double minDepth, double maxDepth) {
            pass.setViewport(x, y, width, height, minDepth, maxDepth);
        }

        @Override public void setScissorRect(int x, int y, int width, int height) { pass.setScissorRect(x, y, width, height); }

        @Override public void setStencilReference(int reference) { pass.setStencilReference(reference); }

        @Override public void setBlendConstant(double r, double g, double b, double a) {
            pass.setBlendConstant(BrowserWebGpu.color(r, g, b, a));
        }

        @Override public void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) {
            pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
        }

        @Override public void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance) {
            pass.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
        }

        @Override public void end() { pass.end(); }
    }

    static final class BrowserCommandEncoder implements fge.webgpu.CommandEncoder {
        final GPUCommandEncoder encoder;

        BrowserCommandEncoder(GPUCommandEncoder encoder) { this.encoder = encoder; }

        @Override public fge.webgpu.RenderPass beginRenderPass(RenderPassDesc desc) {
            return new BrowserRenderPass(encoder.beginRenderPass(BrowserWebGpu.renderPass(desc)));
        }

        @Override public void copyBufferToBuffer(fge.webgpu.Buffer src, long srcOffset, fge.webgpu.Buffer dst, long dstOffset, long size) {
            encoder.copyBufferToBuffer(((BrowserBuffer) src).buffer, srcOffset, ((BrowserBuffer) dst).buffer, dstOffset, size);
        }

        @Override public void copyTextureToBuffer(fge.webgpu.Texture src, int mip, int x, int y, int width, int height,
                                                  fge.webgpu.Buffer dst, long dstOffset, int bytesPerRow) {
            GPUDescriptor.TexelCopyBufferInfo to = GPUDescriptor.create();
            to.setBuffer(((BrowserBuffer) dst).buffer);
            to.setOffset(dstOffset);
            to.setBytesPerRow(bytesPerRow);
            to.setRowsPerImage(height);
            encoder.copyTextureToBuffer(BrowserWebGpu.texelCopy(((BrowserTexture) src).texture, mip, x, y), to,
                BrowserWebGpu.extent(width, height));
        }

        @Override public void resolveQuerySet(fge.webgpu.QuerySet querySet, int first, int count, fge.webgpu.Buffer dst, long dstOffset) {
            encoder.resolveQuerySet(((BrowserQuerySet) querySet).querySet, first, count, ((BrowserBuffer) dst).buffer, dstOffset);
        }

        @Override public fge.webgpu.CommandBuffer finish() { return new BrowserCommandBuffer(encoder.finish()); }
    }

    /** canvas の描き先。present は何もしない（ブラウザがコマの終わりに出す）。 */
    static final class BrowserSurface implements fge.webgpu.Surface {
        private final GPUCanvasContext context;
        private final GPUDevice device;
        private int width;
        private int height;
        private TextureFormat format = TextureFormat.BGRA8_UNORM;

        BrowserSurface(GPUCanvasContext context, GPUDevice device) {
            this.context = context;
            this.device = device;
        }

        @Override public TextureFormat preferredFormat() {
            TextureFormat f = BrowserFormats.fromTextureFormat(preferredCanvasFormat());
            return f == null ? TextureFormat.BGRA8_UNORM : f;
        }

        // WhyNot: presentMode を渡さない — canvas の WebGPU には present の待ち方を選ぶ口が無く、画面の描き替えに合わせて出る。
        @Override public void configure(int width, int height, TextureFormat format, PresentMode presentMode, int textureUsage) {
            this.width = width;
            this.height = height;
            this.format = format;
            setCanvasSize(context, width, height);
            GPUDescriptor.CanvasConfiguration config = GPUDescriptor.create();
            config.setDevice(device);
            config.setFormat(BrowserFormats.textureFormat(format));
            config.setUsage(textureUsage);
            config.setAlphaMode("opaque");
            context.configure(config);
        }

        @Override public fge.webgpu.Texture getCurrentTexture() {
            return new BrowserTexture(context.getCurrentTexture(), width, height, format, false);
        }

        @Override public SurfaceStatus lastStatus() { return SurfaceStatus.SUCCESS_OPTIMAL; }

        @Override public void present() { }

        @Override public void release() { context.unconfigure(); }

        @JSBody(script = "return navigator.gpu.getPreferredCanvasFormat();")
        private static native String preferredCanvasFormat();

        @JSBody(params = {"c", "w", "h"}, script = "c.canvas.width = w; c.canvas.height = h;")
        private static native void setCanvasSize(GPUCanvasContext context, int width, int height);
    }
}
