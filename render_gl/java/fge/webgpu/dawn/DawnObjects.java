package fge.webgpu.dawn;

import com.github.xpenatan.webgpu.*;
import fge.webgpu.*;

/** Dawn の物を包む小さな型。外へは fge.webgpu の interface で見せる。 */
final class DawnObjects {
    private DawnObjects() {}

    /** values を into へ詰め直して返す（encoder ごとに 1 つを使い回す・setBindGroup の中で写されるので次の呼び出しで書き換えてよい）。 */
    static WGPUVectorInt offsetsOf(WGPUVectorInt into, int[] values) {
        into.clear();
        for (int v : values) into.push_back(v);
        return into;
    }

    static final class DawnBuffer implements fge.webgpu.Buffer {
        final WGPUBuffer buffer;
        final long size;
        private boolean destroyed;

        DawnBuffer(WGPUBuffer buffer, long size) {
            this.buffer = buffer;
            this.size = size;
        }

        @Override public long size() { return size; }

        @Override public void destroy() {
            if (destroyed) return;
            destroyed = true;
            buffer.destroy();
            buffer.release();
        }
    }

    static final class DawnTexture implements fge.webgpu.Texture {
        final WGPUTexture texture;
        final int width;
        final int height;
        final TextureFormat format;
        /** surface の texture は surface が持ち主（present が手放す）。 */
        final boolean owned;
        private DawnTextureView defaultView;
        private boolean destroyed;

        DawnTexture(WGPUTexture texture, int width, int height, TextureFormat format, boolean owned) {
            this.texture = texture;
            this.width = width;
            this.height = height;
            this.format = format;
            this.owned = owned;
        }

        @Override public int width() { return width; }
        @Override public int height() { return height; }
        @Override public TextureFormat format() { return format; }

        @Override public fge.webgpu.TextureView createView() {
            WGPUTextureView view = new WGPUTextureView();
            texture.createView(WGPUTextureViewDescriptor.NULL, view);
            return new DawnTextureView(view);
        }

        @Override public fge.webgpu.TextureView createView(int baseMip, int mipCount) {
            WGPUTextureViewDescriptor desc = new WGPUTextureViewDescriptor();
            desc.setFormat(DawnFormats.textureFormat(format));
            desc.setDimension(WGPUTextureViewDimension._2D);
            desc.setBaseMipLevel(baseMip);
            desc.setMipLevelCount(mipCount);
            desc.setBaseArrayLayer(0);
            desc.setArrayLayerCount(1);
            desc.setAspect(WGPUTextureAspect.All);
            WGPUTextureView view = new WGPUTextureView();
            texture.createView(desc, view);
            desc.dispose();
            return new DawnTextureView(view);
        }

        @Override public fge.webgpu.TextureView defaultView() {
            if (defaultView == null) defaultView = (DawnTextureView) createView();
            return defaultView;
        }

        @Override public void destroy() {
            if (destroyed) return;
            destroyed = true;
            if (defaultView != null) defaultView.release();
            if (owned) {
                texture.destroy();
                texture.release();
            }
        }

        /** surface が present の後に呼ぶ（呼び手が destroy した後でも 2 回は手放さない）。 */
        void releaseSurfaceTexture() {
            if (!destroyed && defaultView != null) defaultView.release();
            destroyed = true;
            texture.release();
        }
    }

    static final class DawnTextureView implements fge.webgpu.TextureView {
        final WGPUTextureView view;
        private boolean released;

        DawnTextureView(WGPUTextureView view) { this.view = view; }

        @Override public void release() {
            if (released) return;
            released = true;
            view.release();
        }
    }

    static final class DawnSampler implements fge.webgpu.Sampler {
        final WGPUSampler sampler;
        private boolean released;

        DawnSampler(WGPUSampler sampler) { this.sampler = sampler; }

        @Override public void release() {
            if (released) return;
            released = true;
            sampler.release();
        }
    }

    static final class DawnShaderModule implements fge.webgpu.ShaderModule {
        final WGPUShaderModule module;
        private boolean released;

        DawnShaderModule(WGPUShaderModule module) { this.module = module; }

        @Override public void release() {
            if (released) return;
            released = true;
            module.release();
        }
    }

    static final class DawnBindGroupLayout implements fge.webgpu.BindGroupLayout {
        final WGPUBindGroupLayout layout;
        private boolean released;

        DawnBindGroupLayout(WGPUBindGroupLayout layout) { this.layout = layout; }

        @Override public void release() {
            if (released) return;
            released = true;
            layout.release();
        }
    }

    static final class DawnBindGroup implements fge.webgpu.BindGroup {
        final WGPUBindGroup group;
        private boolean released;

        DawnBindGroup(WGPUBindGroup group) { this.group = group; }

        @Override public void release() {
            if (released) return;
            released = true;
            group.release();
        }
    }

    static final class DawnRenderPipeline implements fge.webgpu.RenderPipeline {
        final WGPURenderPipeline pipeline;
        private boolean released;

        DawnRenderPipeline(WGPURenderPipeline pipeline) { this.pipeline = pipeline; }

        @Override public void release() {
            if (released) return;
            released = true;
            pipeline.release();
        }
    }

    static final class DawnQuerySet implements fge.webgpu.QuerySet {
        final WGPUQuerySet querySet;
        final int count;
        private boolean destroyed;

        DawnQuerySet(WGPUQuerySet querySet, int count) {
            this.querySet = querySet;
            this.count = count;
        }

        @Override public int count() { return count; }

        @Override public void destroy() {
            if (destroyed) return;
            destroyed = true;
            querySet.destroy();
            querySet.release();
        }
    }

    static final class DawnCommandBuffer implements fge.webgpu.CommandBuffer {
        final WGPUCommandBuffer commands;

        DawnCommandBuffer(WGPUCommandBuffer commands) { this.commands = commands; }
    }

    static final class DawnRenderBundle implements fge.webgpu.RenderBundle {
        final WGPURenderBundle bundle;
        private boolean released;

        DawnRenderBundle(WGPURenderBundle bundle) { this.bundle = bundle; }

        @Override public void release() {
            if (released) return;
            released = true;
            bundle.release();
        }
    }

    static final class DawnRenderBundleEncoder implements fge.webgpu.RenderBundleEncoder {
        final WGPURenderBundleEncoder encoder;
        private final WGPUVectorInt offsets = new WGPUVectorInt();

        DawnRenderBundleEncoder(WGPURenderBundleEncoder encoder) { this.encoder = encoder; }

        @Override public void setPipeline(fge.webgpu.RenderPipeline pipeline) {
            encoder.setPipeline(((DawnRenderPipeline) pipeline).pipeline);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group) {
            encoder.setBindGroup(index, ((DawnBindGroup) group).group);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group, int[] dynamicOffsets) {
            encoder.setBindGroup(index, ((DawnBindGroup) group).group, offsetsOf(offsets, dynamicOffsets));
        }

        @Override public void setVertexBuffer(int slot, fge.webgpu.Buffer buffer, long offset, long size) {
            encoder.setVertexBuffer(slot, ((DawnBuffer) buffer).buffer, Math.toIntExact(offset), Math.toIntExact(size));
        }

        @Override public void setIndexBuffer(fge.webgpu.Buffer buffer, fge.webgpu.IndexFormat format, long offset, long size) {
            encoder.setIndexBuffer(((DawnBuffer) buffer).buffer,
                format == fge.webgpu.IndexFormat.UINT16 ? WGPUIndexFormat.Uint16 : WGPUIndexFormat.Uint32,
                Math.toIntExact(offset), Math.toIntExact(size));
        }

        @Override public void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) {
            encoder.draw(vertexCount, instanceCount, firstVertex, firstInstance);
        }

        @Override public void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance) {
            encoder.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
        }

        @Override public fge.webgpu.RenderBundle finish() {
            WGPURenderBundle bundle = new WGPURenderBundle();
            encoder.finish(WGPURenderBundleDescriptor.NULL, bundle);
            encoder.release();
            return new DawnRenderBundle(bundle);
        }
    }

    static final class DawnRenderPass implements fge.webgpu.RenderPass {
        final WGPURenderPassEncoder pass;
        private final WGPUVectorInt offsets = new WGPUVectorInt();
        private final WGPUColor blendConstant = new WGPUColor();
        private WGPUVectorRenderBundle bundles;

        DawnRenderPass(WGPURenderPassEncoder pass) { this.pass = pass; }

        @Override public void setPipeline(fge.webgpu.RenderPipeline pipeline) {
            pass.setPipeline(((DawnRenderPipeline) pipeline).pipeline);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group) {
            pass.setBindGroup(index, ((DawnBindGroup) group).group);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group, int[] dynamicOffsets) {
            pass.setBindGroup(index, ((DawnBindGroup) group).group, offsetsOf(offsets, dynamicOffsets));
        }

        @Override public void setVertexBuffer(int slot, fge.webgpu.Buffer buffer, long offset, long size) {
            pass.setVertexBuffer(slot, ((DawnBuffer) buffer).buffer, Math.toIntExact(offset), Math.toIntExact(size));
        }

        @Override public void setIndexBuffer(fge.webgpu.Buffer buffer, fge.webgpu.IndexFormat format, long offset, long size) {
            pass.setIndexBuffer(((DawnBuffer) buffer).buffer,
                format == fge.webgpu.IndexFormat.UINT16 ? WGPUIndexFormat.Uint16 : WGPUIndexFormat.Uint32,
                Math.toIntExact(offset), Math.toIntExact(size));
        }

        @Override public void setViewport(double x, double y, double width, double height, double minDepth, double maxDepth) {
            pass.setViewport((float) x, (float) y, (float) width, (float) height, (float) minDepth, (float) maxDepth);
        }

        @Override public void setScissorRect(int x, int y, int width, int height) { pass.setScissorRect(x, y, width, height); }

        @Override public void setStencilReference(int reference) { pass.setStencilReference(reference); }

        @Override public void setBlendConstant(double r, double g, double b, double a) {
            blendConstant.setColor((float) r, (float) g, (float) b, (float) a);
            pass.setBlendConstant(blendConstant);
        }

        @Override public void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) {
            pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
        }

        @Override public void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance) {
            pass.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
        }

        @Override public void executeBundle(fge.webgpu.RenderBundle bundle) {
            if (bundles == null) bundles = new WGPUVectorRenderBundle();
            bundles.clear();
            bundles.push_back(((DawnRenderBundle) bundle).bundle);
            pass.executeBundles(bundles);
        }

        @Override public void end() {
            pass.end();
            pass.release();
            blendConstant.dispose();
            if (bundles != null) bundles.dispose();
        }
    }

    static final class DawnCommandEncoder implements fge.webgpu.CommandEncoder {
        final WGPUCommandEncoder encoder;
        private final DawnWebGpu gpu;

        DawnCommandEncoder(WGPUCommandEncoder encoder, DawnWebGpu gpu) {
            this.encoder = encoder;
            this.gpu = gpu;
        }

        @Override public fge.webgpu.RenderPass beginRenderPass(RenderPassDesc desc) {
            return gpu.beginRenderPass(encoder, desc);
        }

        @Override public void copyBufferToBuffer(fge.webgpu.Buffer src, long srcOffset, fge.webgpu.Buffer dst, long dstOffset, long size) {
            encoder.copyBufferToBuffer(((DawnBuffer) src).buffer, Math.toIntExact(srcOffset),
                ((DawnBuffer) dst).buffer, Math.toIntExact(dstOffset), Math.toIntExact(size));
        }

        @Override public void copyTextureToBuffer(fge.webgpu.Texture src, int mip, int x, int y, int width, int height,
                                                  fge.webgpu.Buffer dst, long dstOffset, int bytesPerRow) {
            WGPUTexelCopyTextureInfo from = new WGPUTexelCopyTextureInfo();
            from.setTexture(((DawnTexture) src).texture);
            from.setMipLevel(mip);
            from.getOrigin().set(x, y, 0);
            from.setAspect(WGPUTextureAspect.All);
            WGPUTexelCopyBufferInfo to = new WGPUTexelCopyBufferInfo();
            to.setBuffer(((DawnBuffer) dst).buffer);
            to.getLayout().setOffset(Math.toIntExact(dstOffset));
            to.getLayout().setBytesPerRow(bytesPerRow);
            to.getLayout().setRowsPerImage(height);
            WGPUExtent3D extent = new WGPUExtent3D();
            extent.setWidth(width);
            extent.setHeight(height);
            extent.setDepthOrArrayLayers(1);
            encoder.copyTextureToBuffer(from, to, extent);
            from.dispose();
            to.dispose();
            extent.dispose();
        }

        @Override public void resolveQuerySet(fge.webgpu.QuerySet querySet, int first, int count, fge.webgpu.Buffer dst, long dstOffset) {
            encoder.resolveQuerySet(((DawnQuerySet) querySet).querySet, first, count, ((DawnBuffer) dst).buffer, Math.toIntExact(dstOffset));
        }

        @Override public fge.webgpu.CommandBuffer finish() {
            WGPUCommandBuffer commands = new WGPUCommandBuffer();
            encoder.finish(WGPUCommandBufferDescriptor.NULL, commands);
            encoder.release();
            return new DawnCommandBuffer(commands);
        }
    }

    /** GLFW のウィンドウの描き先。 */
    static final class DawnSurface implements fge.webgpu.Surface {
        private final WGPUSurface surface;
        private final WGPUAdapter adapter;
        private final WGPUDevice device;
        private final WGPUSurfaceTexture surfaceTexture = new WGPUSurfaceTexture();
        private final WGPUSurfaceConfiguration config = new WGPUSurfaceConfiguration();
        private int width;
        private int height;
        private TextureFormat format = TextureFormat.BGRA8_UNORM;
        private SurfaceStatus status = SurfaceStatus.SUCCESS_OPTIMAL;
        private DawnTexture current;

        DawnSurface(WGPUSurface surface, WGPUAdapter adapter, WGPUDevice device) {
            this.surface = surface;
            this.adapter = adapter;
            this.device = device;
        }

        @Override public TextureFormat preferredFormat() {
            WGPUSurfaceCapabilities caps = new WGPUSurfaceCapabilities();
            surface.getCapabilities(adapter, caps);
            TextureFormat found = TextureFormat.BGRA8_UNORM;
            for (int i = 0; i < caps.getFormats().size(); i++) {
                TextureFormat f = DawnFormats.fromTextureFormat(caps.getFormats().get(i));
                if (f != null) { found = f; break; }
            }
            caps.dispose();
            return found;
        }

        @Override public void configure(int width, int height, TextureFormat format, PresentMode presentMode, int textureUsage) {
            this.width = width;
            this.height = height;
            this.format = format;
            synchronized (DawnFormats.SHARED) {
                config.setNextInChain(WGPUChainedStruct.NULL);
                config.setWidth(width);
                config.setHeight(height);
                config.setFormat(DawnFormats.textureFormat(format));
                config.setViewFormats(WGPUVectorTextureFormat.NULL);
                config.setUsage(DawnFormats.textureUsage(textureUsage));
                config.setDevice(device);
                config.setPresentMode(DawnFormats.presentMode(presentMode));
                config.setAlphaMode(WGPUCompositeAlphaMode.Auto);
                surface.configure(config);
            }
        }

        @Override public fge.webgpu.Texture getCurrentTexture() {
            dropCurrent();
            surface.getCurrentTexture(surfaceTexture);
            status = DawnFormats.surfaceStatus(surfaceTexture.getStatus());
            WGPUTexture texture = new WGPUTexture();
            surfaceTexture.getTexture(texture);
            if (!texture.isValid()) return null;
            current = new DawnTexture(texture, width, height, format, false);
            return current;
        }

        private void dropCurrent() {
            if (current != null) {
                current.releaseSurfaceTexture();
                current = null;
            }
        }

        @Override public SurfaceStatus lastStatus() { return status; }

        @Override public void present() {
            surface.present();
            dropCurrent();
        }

        @Override public void release() {
            dropCurrent();
            surface.unconfigure();
            surface.release();
        }
    }
}
