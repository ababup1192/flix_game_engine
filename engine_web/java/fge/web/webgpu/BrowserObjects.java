package fge.web.webgpu;

import fge.webgpu.IndexFormat;
import fge.webgpu.PresentMode;
import fge.webgpu.RenderPassDesc;
import fge.webgpu.SurfaceStatus;
import fge.webgpu.TextureFormat;
import org.teavm.jso.JSBody;
import org.teavm.jso.typedarrays.Int32Array;
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

    /** pass の記録の中で JS の物を指す番号（同じ pass の 2 回目からは JS へ渡し直さない）。 */
    static class PassSlot {
        int passEpoch;
        int passSlot;
    }

    /**
     * 一生の長い物（buffer・pipeline）は初めて pass で使う時に JS の表 fgeGpuObjs へ置き、負の番号（-1 - 表の位置）で指す。
     * buffer は destroy で表から外す。pipeline は作った物を控えて使い回すので数が増えない。
     */
    static class LongSlot extends PassSlot {
        int longSlot = -1;

        int longSlotOf(org.teavm.jso.JSObject object) {
            if (longSlot < 0) longSlot = putLong(object);
            return -1 - longSlot;
        }

        void dropLong() {
            if (longSlot >= 0) dropLong(longSlot);
            longSlot = -1;
        }

        @JSBody(params = {"object"}, script = "var i = fgeGpuFree.length > 0 ? fgeGpuFree.pop() : fgeGpuObjs.length; fgeGpuObjs[i] = object; return i;")
        private static native int putLong(org.teavm.jso.JSObject object);

        @JSBody(params = {"slot"}, script = "fgeGpuObjs[slot] = null; fgeGpuFree.push(slot);")
        private static native void dropLong(int slot);
    }

    static final class BrowserBuffer extends LongSlot implements fge.webgpu.Buffer {
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
            dropLong();
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

    static final class BrowserBindGroup extends PassSlot implements fge.webgpu.BindGroup {
        final GPUBindGroup group;

        BrowserBindGroup(GPUBindGroup group) { this.group = group; }

        @Override public void release() { }
    }

    static final class BrowserRenderPipeline extends LongSlot implements fge.webgpu.RenderPipeline {
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

    /**
     * pass の命令を Int32 の列に積み、end で fge-web.js の fgeRunPass へ 1 回で渡す（JS がその場で pass に流す）。
     * 命令の形は fgeRunPass と組（番号を変える時は両方を直す）。物（pipeline・group・buffer）は pass の中の番号で指し、
     * 初めて使う時だけ JS の表 fgePassObjs へ置く。
     * WhyNot: 命令ごとに JS の pass を呼ばない — 1 回の行き来ごとに引数の包み直しが付き、3D の場面は 1 コマに数百の命令を積む。
     * WhyNot: 物の番号を device の一生で振らない — release で JS の物を手放さない（上の決まり）ので、表が毎コマの group で伸び続ける。
     */
    static final class BrowserRenderPass implements fge.webgpu.RenderPass {
        static final int PIPELINE = 1, BIND_GROUP = 2, VERTEX_BUFFER = 3, INDEX_BUFFER = 4, VIEWPORT = 5, SCISSOR = 6,
                         STENCIL = 7, DRAW = 8, DRAW_INDEXED = 9;
        private static int epochs;

        final GPURenderPassEncoder pass;
        private final int epoch = ++epochs;
        private int objects;
        private int[] ops = new int[512];
        private int count;

        BrowserRenderPass(GPURenderPassEncoder pass) { this.pass = pass; }

        private int slotOf(PassSlot owner, org.teavm.jso.JSObject object) {
            if (owner.passEpoch != epoch) {
                owner.passEpoch = epoch;
                owner.passSlot = objects++;
                putObject(owner.passSlot, object);
            }
            return owner.passSlot;
        }

        private void room(int n) {
            if (count + n > ops.length) ops = java.util.Arrays.copyOf(ops, Math.max(ops.length * 2, count + n));
        }

        private void op1(int code, int a) { room(2); ops[count++] = code; ops[count++] = a; }

        private void flush(boolean end) {
            if (count > 0 || end) runPass(pass, Int32Array.copyFromJavaArray(java.util.Arrays.copyOf(ops, count)), count, end);
            count = 0;
        }

        private static boolean fitsInt(long v) { return v >= 0 && v <= Integer.MAX_VALUE; }

        @Override public void setPipeline(fge.webgpu.RenderPipeline pipeline) {
            BrowserRenderPipeline p = (BrowserRenderPipeline) pipeline;
            op1(PIPELINE, p.longSlotOf(p.pipeline));
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group) {
            BrowserBindGroup g = (BrowserBindGroup) group;
            int slot = slotOf(g, g.group);
            room(3); ops[count++] = BIND_GROUP; ops[count++] = index; ops[count++] = slot;
        }

        @Override public void setVertexBuffer(int slot, fge.webgpu.Buffer buffer, long offset, long size) {
            BrowserBuffer b = (BrowserBuffer) buffer;
            if (!fitsInt(offset) || !fitsInt(size)) {
                flush(false);
                pass.setVertexBuffer(slot, b.buffer, offset, size);
                return;
            }
            int at = b.longSlotOf(b.buffer);
            room(5); ops[count++] = VERTEX_BUFFER; ops[count++] = slot; ops[count++] = at; ops[count++] = (int) offset; ops[count++] = (int) size;
        }

        @Override public void setIndexBuffer(fge.webgpu.Buffer buffer, IndexFormat format, long offset, long size) {
            BrowserBuffer b = (BrowserBuffer) buffer;
            if (!fitsInt(offset) || !fitsInt(size)) {
                flush(false);
                pass.setIndexBuffer(b.buffer, format == IndexFormat.UINT16 ? "uint16" : "uint32", offset, size);
                return;
            }
            int at = b.longSlotOf(b.buffer);
            room(5); ops[count++] = INDEX_BUFFER; ops[count++] = at; ops[count++] = format == IndexFormat.UINT16 ? 0 : 1;
            ops[count++] = (int) offset; ops[count++] = (int) size;
        }

        // WhyNot: 位置と大きさを float の bit で渡す — GPU は viewport を float で持つので、double から落とす所が JS の手前に移るだけ。
        @Override public void setViewport(double x, double y, double width, double height, double minDepth, double maxDepth) {
            room(7); ops[count++] = VIEWPORT;
            ops[count++] = Float.floatToRawIntBits((float) x); ops[count++] = Float.floatToRawIntBits((float) y);
            ops[count++] = Float.floatToRawIntBits((float) width); ops[count++] = Float.floatToRawIntBits((float) height);
            ops[count++] = Float.floatToRawIntBits((float) minDepth); ops[count++] = Float.floatToRawIntBits((float) maxDepth);
        }

        @Override public void setScissorRect(int x, int y, int width, int height) {
            room(5); ops[count++] = SCISSOR; ops[count++] = x; ops[count++] = y; ops[count++] = width; ops[count++] = height;
        }

        @Override public void setStencilReference(int reference) { op1(STENCIL, reference); }

        @Override public void setBlendConstant(double r, double g, double b, double a) {
            flush(false);
            pass.setBlendConstant(BrowserWebGpu.color(r, g, b, a));
        }

        @Override public void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) {
            room(5); ops[count++] = DRAW; ops[count++] = vertexCount; ops[count++] = instanceCount; ops[count++] = firstVertex; ops[count++] = firstInstance;
        }

        @Override public void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance) {
            room(6); ops[count++] = DRAW_INDEXED; ops[count++] = indexCount; ops[count++] = instanceCount; ops[count++] = firstIndex;
            ops[count++] = baseVertex; ops[count++] = firstInstance;
        }

        @Override public void end() { flush(true); }

        @JSBody(params = {"slot", "object"}, script = "fgePassObjs[slot] = object;")
        private static native void putObject(int slot, org.teavm.jso.JSObject object);

        @JSBody(params = {"pass", "ops", "count", "end"}, script = "fgeRunPass(pass, ops, count, end);")
        private static native void runPass(GPURenderPassEncoder pass, Int32Array ops, int count, boolean end);
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
