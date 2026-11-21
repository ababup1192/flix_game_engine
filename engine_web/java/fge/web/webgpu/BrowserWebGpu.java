package fge.web.webgpu;

import fge.web.webgpu.BrowserObjects.*;
import fge.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.browser.Navigator;
import org.teavm.jso.core.JSArray;
import org.teavm.jso.core.JSArrayReader;
import org.teavm.jso.core.JSPromise;
import org.teavm.jso.core.JSUndefined;
import org.teavm.jso.dom.events.EventListener;
import org.teavm.jso.typedarrays.ArrayBuffer;
import org.teavm.jso.typedarrays.Uint8Array;
import org.teavm.jso.webgpu.GPUAdapter;
import org.teavm.jso.webgpu.GPUBuffer;
import org.teavm.jso.webgpu.GPUCanvasContext;
import org.teavm.jso.webgpu.GPUDescriptor;
import org.teavm.jso.webgpu.GPUDevice;
import org.teavm.jso.webgpu.GPUQueue;
import org.teavm.jso.webgpu.GPUShaderModule;
import org.teavm.jso.webgpu.GPUTexture;

/**
 * ブラウザの WebGpu の実装（TeaVM の JSO で navigator.gpu を呼ぶ。PC の Dawn は DawnWebGpu）。作るのは {@link #open()}。
 * 待つ関数（open・getCompilationInfo・readBuffer・waitIdle・errorCount）は中で JSPromise.await を使い、呼び手には止まる形に見せる。
 * 呼べるのはコマの描き（requestAnimationFrame）の外、main から続く糸の上だけ。
 */
public final class BrowserWebGpu implements WebGpu {
    private final GPUDevice device;
    private final GPUQueue queue;
    private final Limits limits;
    private final boolean timestampQuery;
    private final boolean coreFeaturesAndLimits;
    private final String adapterInfo;
    private int errors;
    private String lastError = "";
    private boolean destroyed;

    private BrowserWebGpu(GPUDevice device, Limits limits, boolean timestampQuery, boolean coreFeaturesAndLimits, String adapterInfo) {
        this.device = device;
        this.queue = device.getQueue();
        this.limits = limits;
        this.timestampQuery = timestampQuery;
        this.coreFeaturesAndLimits = coreFeaturesAndLimits;
        this.adapterInfo = adapterInfo;
    }

    // ── 開く ──

    /** adapter と device を取る（待つ）。WebGPU の無いブラウザ・adapter か device が取れなければ IllegalStateException。 */
    public static BrowserWebGpu open() {
        if (!Navigator.isWebGPUSupported()) throw new IllegalStateException("このブラウザには navigator.gpu が無い");
        GPUDescriptor.RequestAdapterOptions options = GPUDescriptor.create();
        options.setPowerPreference("high-performance");
        GPUAdapter adapter;
        GPUDevice device;
        try {
            adapter = Navigator.getGPU().requestAdapter(options).await();
            if (isNullish(adapter)) throw new IllegalStateException("WebGPU の adapter が無い");
            // WhyNot: requiredLimits を渡さない形にしない — 渡さないと device の上限は仕様の既定（2D の texture 8192 など）に下がる（Dawn の側と同じ）。
            device = adapter.requestDevice(deviceDescriptor(adapter)).await();
        } catch (IllegalStateException e) {
            throw e;
        } catch (Throwable e) {
            throw new IllegalStateException("WebGPU の device を作れない: " + e);
        }
        BrowserWebGpu gpu = new BrowserWebGpu(device, readLimits(device), hasFeature(device, "timestamp-query"),
            hasFeature(device, "core-features-and-limits"), describe(adapter));
        device.addEventListener("uncapturederror", (EventListener<GPUDevice.UncapturedErrorEvent>) e -> gpu.noteError(errorMessage(e)));
        return gpu;
    }

    @JSBody(params = {"a"}, script =
        "var limits = {};"
        + "for (var k in a.limits) { if (typeof a.limits[k] === 'number') limits[k] = a.limits[k]; }"
        + "var features = [];"
        + "if (a.features.has('core-features-and-limits')) features.push('core-features-and-limits');"
        + "if (a.features.has('timestamp-query')) features.push('timestamp-query');"
        + "return { label: 'fge device', requiredLimits: limits, requiredFeatures: features };")
    private static native GPUDescriptor.Device deviceDescriptor(GPUAdapter adapter);

    @JSBody(params = {"o"}, script = "return o === null || o === undefined;")
    private static native boolean isNullish(JSObject o);

    @JSBody(params = {"d", "name"}, script = "return d.features.has(name);")
    private static native boolean hasFeature(GPUDevice device, String name);

    @JSBody(params = {"a"}, script =
        "var i = a.info || {};"
        + "return 'WebGPU ' + (i.vendor || '?') + ' ' + (i.architecture || '?') + ' (' + (i.description || '') + ')';")
    private static native String describe(GPUAdapter adapter);

    @JSBody(params = {"e"}, script = "var m = e.error || {}; return (m.constructor ? m.constructor.name + ': ' : '') + (m.message || String(m));")
    private static native String errorMessage(JSObject event);

    private static Limits readLimits(GPUDevice device) {
        GPUAdapter.SupportedLimits l = device.getLimits();
        return new Limits(
            l.getMaxTextureDimension2D(), l.getMaxTextureArrayLayers(), l.getMaxBindGroups(),
            l.getMaxSampledTexturesPerShaderStage(), l.getMaxSamplersPerShaderStage(),
            l.getMaxStorageBuffersPerShaderStage(), l.getMaxUniformBuffersPerShaderStage(),
            l.getMaxVertexBuffers(), l.getMaxVertexAttributes(),
            l.getMinUniformBufferOffsetAlignment(), l.getMinStorageBufferOffsetAlignment(),
            (long) l.getMaxUniformBufferBindingSize(), (long) l.getMaxStorageBufferBindingSize(), (long) l.getMaxBufferSize());
    }

    void noteError(String message) {
        errors++;
        lastError = message;
        System.err.println("[webgpu] " + message);
    }

    // ── device ──

    @Override public String adapterInfo() { return adapterInfo; }
    @Override public Limits limits() { return limits; }
    @Override public boolean hasTimestampQuery() { return timestampQuery; }
    @Override public boolean hasCoreFeaturesAndLimits() { return coreFeaturesAndLimits; }

    // WhyNot: 待たずに数を返さない — uncapturederror はブラウザのタスクで届き、submit した仕事が終わってイベントの輪へ 1 度手を返すまで数に入らない。
    //   Chrome では wire の順で onSubmittedWorkDone より先に届く。他のブラウザは【未確認】。
    //   submit した仕事の終わりまで待つので毎コマ呼ばない（門と読み戻しの後に 1 回）。
    @Override public int errorCount() {
        if (!destroyed) {
            queue.onSubmittedWorkDone().await();
            nextTask().await();
        }
        return errors;
    }

    @JSBody(script = "return new Promise(function (r) { setTimeout(r, 0); });")
    private static native JSPromise<JSUndefined> nextTask();

    @Override public String lastError() { return lastError; }

    @Override public void destroy() {
        if (destroyed) return;
        destroyed = true;
        device.destroy();
    }

    // ── 物を作る ──

    @Override public fge.webgpu.Buffer createBuffer(String label, long size, int usage) {
        GPUDescriptor.Buffer desc = GPUDescriptor.create();
        desc.setLabel(label);
        desc.setSize(size);
        desc.setUsage(usage);
        return new BrowserBuffer(device.createBuffer(desc), size);
    }

    @Override public fge.webgpu.Texture createTexture(String label, int width, int height, TextureFormat format, int usage,
                                                      int mipLevelCount, int sampleCount) {
        GPUDescriptor.Texture desc = GPUDescriptor.create();
        desc.setLabel(label);
        desc.setSize(extent(width, height));
        desc.setDimension("2d");
        desc.setFormat(BrowserFormats.textureFormat(format));
        desc.setUsage(usage);
        desc.setMipLevelCount(mipLevelCount);
        desc.setSampleCount(sampleCount);
        return new BrowserTexture(device.createTexture(desc), width, height, format, true);
    }

    // WhyNot: 比べる sampler（compare）を作れる形にしない — Dawn の側と同じく使う所がまだ無い。
    @Override public fge.webgpu.Sampler createSampler(String label, FilterMode filter, FilterMode mipmapFilter, AddressMode address) {
        GPUDescriptor.Sampler desc = GPUDescriptor.create();
        desc.setLabel(label);
        String mode = BrowserFormats.token(address);
        desc.setAddressModeU(mode);
        desc.setAddressModeV(mode);
        desc.setAddressModeW(mode);
        desc.setMagFilter(BrowserFormats.token(filter));
        desc.setMinFilter(BrowserFormats.token(filter));
        desc.setMipmapFilter(BrowserFormats.token(mipmapFilter));
        desc.setLodMinClamp(0);
        desc.setLodMaxClamp(32);
        desc.setMaxAnisotropy(1);
        return new BrowserSampler(device.createSampler(desc));
    }

    @Override public fge.webgpu.ShaderModule createShaderModule(String label, String wgsl) {
        GPUDescriptor.ShaderModule desc = GPUDescriptor.create();
        desc.setLabel(label);
        desc.setCode(wgsl);
        return new BrowserShaderModule(device.createShaderModule(desc));
    }

    /** 1 行ずつ「種類 行:桁 文」（種類は Dawn と同じ Error・Warning・Info）。 */
    @Override public String getCompilationInfo(fge.webgpu.ShaderModule module) {
        GPUShaderModule m = ((BrowserShaderModule) module).module;
        JSArrayReader<GPUShaderModule.CompilationMessage> messages = m.getCompilationInfo().await().getMessages();
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < messages.getLength(); i++) {
            GPUShaderModule.CompilationMessage msg = messages.get(i);
            out.append(BrowserFormats.messageType(msg.getType())).append(' ')
               .append((long) msg.getLineNum()).append(':').append((long) msg.getLinePos())
               .append(' ').append(msg.getMessage()).append('\n');
        }
        return out.toString();
    }

    @Override public fge.webgpu.BindGroupLayout createBindGroupLayout(BindGroupLayoutDesc desc) {
        List<BindGroupLayoutDesc.Entry> list = desc.entries();
        GPUDescriptor.BindGroupLayoutEntry[] entries = new GPUDescriptor.BindGroupLayoutEntry[list.size()];
        for (int i = 0; i < entries.length; i++) entries[i] = layoutEntry(list.get(i));
        GPUDescriptor.BindGroupLayout d = GPUDescriptor.create();
        d.setLabel(desc.label());
        d.setEntries(entries);
        return new BrowserBindGroupLayout(device.createBindGroupLayout(d));
    }

    private static GPUDescriptor.BindGroupLayoutEntry layoutEntry(BindGroupLayoutDesc.Entry e) {
        GPUDescriptor.BindGroupLayoutEntry entry = GPUDescriptor.create();
        entry.setBinding(e.binding);
        entry.setVisibility(e.visibility);
        switch (e.kind) {
            case BUFFER -> {
                GPUDescriptor.BufferBindingLayout b = GPUDescriptor.create();
                b.setType(BrowserFormats.token(e.bufferType));
                entry.setBuffer(b);
            }
            case TEXTURE -> {
                GPUDescriptor.TextureBindingLayout t = GPUDescriptor.create();
                t.setSampleType(BrowserFormats.token(e.sampleType));
                t.setViewDimension("2d");
                t.setMultisampled(false);
                entry.setTexture(t);
            }
            case SAMPLER -> {
                GPUDescriptor.SamplerBindingLayout s = GPUDescriptor.create();
                s.setType(BrowserFormats.token(e.samplerType));
                entry.setSampler(s);
            }
        }
        return entry;
    }

    @Override public fge.webgpu.BindGroup createBindGroup(BindGroupDesc desc) {
        List<BindGroupDesc.Entry> list = desc.entries();
        GPUDescriptor.BindGroupEntry[] entries = new GPUDescriptor.BindGroupEntry[list.size()];
        for (int i = 0; i < entries.length; i++) entries[i] = groupEntry(list.get(i));
        GPUDescriptor.BindGroup d = GPUDescriptor.create();
        d.setLabel(desc.label());
        d.setLayout(((BrowserBindGroupLayout) desc.layout()).layout);
        d.setEntries(entries);
        return new BrowserBindGroup(device.createBindGroup(d));
    }

    private static GPUDescriptor.BindGroupEntry groupEntry(BindGroupDesc.Entry e) {
        GPUDescriptor.BindGroupEntry entry = GPUDescriptor.create();
        entry.setBinding(e.binding);
        if (e.buffer != null) {
            GPUDescriptor.BufferBinding b = GPUDescriptor.create();
            b.setBuffer(((BrowserBuffer) e.buffer).buffer);
            b.setOffset(e.offset);
            b.setSize(e.size);
            entry.setResource(b);
        } else if (e.view != null) {
            entry.setResource(((BrowserTextureView) e.view).view);
        } else {
            entry.setResource(((BrowserSampler) e.sampler).sampler);
        }
        return entry;
    }

    @Override public fge.webgpu.RenderPipeline createRenderPipeline(RenderPipelineDesc desc) {
        List<fge.webgpu.BindGroupLayout> layoutList = desc.bindGroupLayouts();
        org.teavm.jso.webgpu.GPUBindGroup.Layout[] layouts = new org.teavm.jso.webgpu.GPUBindGroup.Layout[layoutList.size()];
        for (int i = 0; i < layouts.length; i++) layouts[i] = ((BrowserBindGroupLayout) layoutList.get(i)).layout;
        GPUDescriptor.PipelineLayout layoutDesc = GPUDescriptor.create();
        layoutDesc.setLabel(desc.label());
        layoutDesc.setBindGroupLayouts(layouts);

        GPUDescriptor.RenderPipeline d = GPUDescriptor.create();
        d.setLabel(desc.label());
        d.setLayout(device.createPipelineLayout(layoutDesc));
        d.setVertex(vertexState(desc));
        GPUDescriptor.PrimitiveState primitive = GPUDescriptor.create();
        primitive.setTopology(BrowserFormats.token(desc.topology()));
        primitive.setFrontFace(BrowserFormats.token(desc.frontFace()));
        primitive.setCullMode(BrowserFormats.token(desc.cullMode()));
        d.setPrimitive(primitive);
        if (desc.fragmentModule() != null) d.setFragment(fragmentState(desc));
        if (desc.depthFormat() != null) d.setDepthStencil(depthStencilState(desc));
        GPUDescriptor.MultisampleState multisample = GPUDescriptor.create();
        multisample.setCount(desc.sampleCount());
        d.setMultisample(multisample);
        // WhyNot: createRenderPipelineAsync を待たない — 誤りの道が Dawn の側（uncapturederror と無効な pipeline）と分かれ、errorCount で拾えなくなる。
        return new BrowserRenderPipeline(device.createRenderPipeline(d));
    }

    private static GPUDescriptor.VertexState vertexState(RenderPipelineDesc desc) {
        List<RenderPipelineDesc.VertexBuffer> list = desc.vertexBuffers();
        GPUDescriptor.VertexBufferLayout[] buffers = new GPUDescriptor.VertexBufferLayout[list.size()];
        for (int i = 0; i < buffers.length; i++) {
            RenderPipelineDesc.VertexBuffer vb = list.get(i);
            GPUDescriptor.VertexAttribute[] attributes = new GPUDescriptor.VertexAttribute[vb.attributes.size()];
            for (int j = 0; j < attributes.length; j++) {
                RenderPipelineDesc.Attribute at = vb.attributes.get(j);
                GPUDescriptor.VertexAttribute a = GPUDescriptor.create();
                a.setFormat(BrowserFormats.token(at.format));
                a.setOffset(at.offset);
                a.setShaderLocation(at.location);
                attributes[j] = a;
            }
            GPUDescriptor.VertexBufferLayout bl = GPUDescriptor.create();
            bl.setArrayStride(vb.arrayStride);
            bl.setStepMode(vb.perInstance ? "instance" : "vertex");
            bl.setAttributes(attributes);
            buffers[i] = bl;
        }
        GPUDescriptor.VertexState vertex = GPUDescriptor.create();
        vertex.setModule(((BrowserShaderModule) desc.vertexModule()).module);
        vertex.setEntryPoint(desc.vertexEntry());
        vertex.setBuffers(buffers);
        return vertex;
    }

    private static GPUDescriptor.FragmentState fragmentState(RenderPipelineDesc desc) {
        List<RenderPipelineDesc.ColorTarget> list = desc.colorTargets();
        GPUDescriptor.ColorTargetState[] targets = new GPUDescriptor.ColorTargetState[list.size()];
        for (int i = 0; i < targets.length; i++) {
            RenderPipelineDesc.ColorTarget ct = list.get(i);
            GPUDescriptor.ColorTargetState target = GPUDescriptor.create();
            target.setFormat(BrowserFormats.textureFormat(ct.format));
            target.setWriteMask(0xF);
            if (ct.color != null) {
                GPUDescriptor.BlendState blend = GPUDescriptor.create();
                blend.setColor(blendComponent(ct.color));
                blend.setAlpha(blendComponent(ct.alpha));
                target.setBlend(blend);
            }
            targets[i] = target;
        }
        GPUDescriptor.FragmentState fragment = GPUDescriptor.create();
        fragment.setModule(((BrowserShaderModule) desc.fragmentModule()).module);
        fragment.setEntryPoint(desc.fragmentEntry());
        fragment.setTargets(targets);
        return fragment;
    }

    private static GPUDescriptor.BlendComponent blendComponent(RenderPipelineDesc.BlendComponent b) {
        GPUDescriptor.BlendComponent c = GPUDescriptor.create();
        c.setSrcFactor(BrowserFormats.token(b.src));
        c.setDstFactor(BrowserFormats.token(b.dst));
        c.setOperation(BrowserFormats.token(b.operation));
        return c;
    }

    private static GPUDescriptor.DepthStencilState depthStencilState(RenderPipelineDesc desc) {
        RenderPipelineDesc.Stencil s = desc.stencilState();
        GPUDescriptor.DepthStencilState depth = GPUDescriptor.create();
        depth.setFormat(BrowserFormats.textureFormat(desc.depthFormat()));
        depth.setDepthWriteEnabled(desc.depthWrite());
        depth.setDepthCompare(BrowserFormats.token(desc.depthCompare()));
        depth.setStencilFront(stencilFace(s));
        depth.setStencilBack(stencilFace(s));
        // WhyNot: 読む mask の既定を WebGPU の 0xFFFFFFFF にしない — Dawn の側が 0xFF を渡しており、2 つの実装で比べる値をそろえる。
        depth.setStencilReadMask(s == null ? 0xFF : s.readMask);
        depth.setStencilWriteMask(s == null ? 0 : s.writeMask);
        return depth;
    }

    private static GPUDescriptor.StencilFaceState stencilFace(RenderPipelineDesc.Stencil s) {
        GPUDescriptor.StencilFaceState face = GPUDescriptor.create();
        face.setCompare(s == null ? "always" : BrowserFormats.token(s.compare));
        face.setFailOp(s == null ? "keep" : BrowserFormats.token(s.failOp));
        face.setDepthFailOp(s == null ? "keep" : BrowserFormats.token(s.depthFailOp));
        face.setPassOp(s == null ? "keep" : BrowserFormats.token(s.passOp));
        return face;
    }

    @Override public fge.webgpu.QuerySet createTimestampQuerySet(String label, int count) {
        GPUDescriptor.QuerySet desc = GPUDescriptor.create();
        desc.setLabel(label);
        desc.setType("timestamp");
        desc.setCount(count);
        return new BrowserQuerySet(device.createQuerySet(desc), count);
    }

    @Override public fge.webgpu.CommandEncoder createCommandEncoder(String label) {
        GPUDescriptor.CommandEncoder desc = GPUDescriptor.create();
        desc.setLabel(label);
        return new BrowserCommandEncoder(device.createCommandEncoder(desc));
    }

    @Override public fge.webgpu.RenderBundleEncoder createRenderBundleEncoder(String label, TextureFormat colorFormat, TextureFormat depthFormat, int sampleCount) {
        return new BrowserRenderBundleEncoder(createBundleEncoder(device, label, colorFormat == null ? null : BrowserFormats.textureFormat(colorFormat),
            depthFormat == null ? null : BrowserFormats.textureFormat(depthFormat), sampleCount));
    }

    @JSBody(params = {"device", "label", "color", "depth", "samples"},
            script = "var d = { label: label, colorFormats: color ? [color] : [], sampleCount: samples }; if (depth) d.depthStencilFormat = depth; return device.createRenderBundleEncoder(d);")
    private static native org.teavm.jso.JSObject createBundleEncoder(GPUDevice device, String label, String color, String depth, int samples);

    static GPUDescriptor.RenderPass renderPass(RenderPassDesc desc) {
        List<RenderPassDesc.ColorAttachment> colors = desc.colors();
        GPUDescriptor.RenderPassColorAttachment[] attachments = new GPUDescriptor.RenderPassColorAttachment[colors.size()];
        for (int i = 0; i < attachments.length; i++) {
            RenderPassDesc.ColorAttachment c = colors.get(i);
            GPUDescriptor.RenderPassColorAttachment ca = GPUDescriptor.create();
            ca.setView(((BrowserTextureView) c.view).view);
            if (c.resolveTarget != null) ca.setResolveTarget(((BrowserTextureView) c.resolveTarget).view);
            ca.setLoadOp(c.clear ? "clear" : "load");
            ca.setStoreOp("store");
            ca.setClearValue(color(c.r, c.g, c.b, c.a));
            attachments[i] = ca;
        }
        GPUDescriptor.RenderPass pass = GPUDescriptor.create();
        pass.setLabel(desc.label());
        pass.setColorAttachments(attachments);
        if (desc.depthView() != null) pass.setDepthStencilAttachment(depthAttachment(desc));
        if (desc.timestamps() != null) {
            GPUDescriptor.RenderPassTimestampWrites writes = GPUDescriptor.create();
            writes.setQuerySet(((BrowserQuerySet) desc.timestamps()).querySet);
            writes.setBeginningOfPassWriteIndex(desc.timestampBegin());
            writes.setEndOfPassWriteIndex(desc.timestampEnd());
            pass.setTimestampWrites(writes);
        }
        return pass;
    }

    // WhyNot: 深度だけの形に stencil の load と store を書かない — WebGPU は stencil の無い形にそれを渡すと検証の誤りにする。
    private static GPUDescriptor.RenderPassDepthStencilAttachment depthAttachment(RenderPassDesc desc) {
        GPUDescriptor.RenderPassDepthStencilAttachment d = GPUDescriptor.create();
        d.setView(((BrowserTextureView) desc.depthView()).view);
        d.setDepthLoadOp(desc.depthClear() ? "clear" : "load");
        d.setDepthStoreOp("store");
        if (desc.depthClear()) d.setDepthClearValue(desc.depthClearValue());
        if (desc.hasStencil()) {
            d.setStencilLoadOp(desc.depthClear() ? "clear" : "load");
            d.setStencilStoreOp("store");
            d.setStencilClearValue(desc.stencilClearValue());
        }
        return d;
    }

    static GPUDescriptor.Color color(double r, double g, double b, double a) {
        GPUDescriptor.Color c = GPUDescriptor.create();
        c.setR(r);
        c.setG(g);
        c.setB(b);
        c.setA(a);
        return c;
    }

    static GPUDescriptor.Extent3D extent(int width, int height) {
        GPUDescriptor.Extent3D e = GPUDescriptor.create();
        e.setWidth(width);
        e.setHeight(height);
        e.setDepthOrArrayLayers(1);
        return e;
    }

    static GPUDescriptor.TexelCopyTextureInfo texelCopy(GPUTexture texture, int mip, int x, int y) {
        GPUDescriptor.Origin3D origin = GPUDescriptor.create();
        origin.setX(x);
        origin.setY(y);
        origin.setZ(0);
        GPUDescriptor.TexelCopyTextureInfo info = GPUDescriptor.create();
        info.setTexture(texture);
        info.setMipLevel(mip);
        info.setOrigin(origin);
        return info;
    }

    // ── queue ──

    @Override public void writeBuffer(fge.webgpu.Buffer buffer, long offset, ByteBuffer data, int dataOffset, int size) {
        if (dataOffset < 0 || size < 0 || dataOffset + size > data.capacity())
            throw new IllegalArgumentException("writeBuffer の data が短い: " + dataOffset + "+" + size + " > " + data.capacity());
        queue.writeBuffer(((BrowserBuffer) buffer).buffer, offset, bytesOf(data), dataOffset, size);
    }

    @Override public void writeTexture(fge.webgpu.Texture texture, int mip, int x, int y, int width, int height,
                                       ByteBuffer data, int dataOffset, int bytesPerRow) {
        int size = bytesPerRow * (height - 1) + width * texture.format().bytesPerTexel();
        // WhyNot: 足りない data を切り詰めて渡さない — 下の行が黙って欠けた絵になる（Dawn の側と同じ）。
        if (dataOffset < 0 || dataOffset + size > data.capacity())
            throw new IllegalArgumentException("writeTexture の data が短い: " + dataOffset + "+" + size + " > " + data.capacity());
        GPUDescriptor.TexelCopyBufferLayout layout = GPUDescriptor.create();
        layout.setOffset(dataOffset);
        layout.setBytesPerRow(bytesPerRow);
        layout.setRowsPerImage(height);
        queue.writeTexture(texelCopy(((BrowserTexture) texture).texture, mip, x, y), bytesOf(data), layout, extent(width, height));
    }

    @Override public void submit(fge.webgpu.CommandBuffer commands) {
        JSArray<org.teavm.jso.webgpu.GPUCommandEncoder.CommandBuffer> list = new JSArray<>();
        list.push(((BrowserCommandBuffer) commands).commands);
        queue.submit(list);
    }

    @Override public void readBuffer(fge.webgpu.Buffer buffer, long offset, int size, ByteBuffer dst) {
        if (size < 0 || size > dst.capacity())
            throw new IllegalArgumentException("readBuffer の dst が短い: " + size + " > " + dst.capacity());
        GPUBuffer b = ((BrowserBuffer) buffer).buffer;
        try {
            b.mapAsync(GPU_MAP_READ, offset, size).await();
        } catch (Throwable e) {
            throw new IllegalStateException("buffer を map できない: " + e);
        }
        ByteBuffer direct = dst.isDirect() ? dst : ByteBuffer.allocateDirect(dst.capacity()).order(ByteOrder.nativeOrder());
        try {
            copyMapped(b.getMappedRange(offset, size), bytesOf(direct), size);
        } finally {
            b.unmap();
        }
        if (direct != dst) {
            ByteBuffer from = direct.duplicate();
            from.position(0).limit(size);
            ByteBuffer to = dst.duplicate();
            to.position(0);
            to.put(from);
        }
    }

    private static final int GPU_MAP_READ = 1;

    // WhyNot: getMappedRange の ArrayBuffer を unmap の後まで持たない — unmap で中身が空になる。
    @JSBody(params = {"src", "dst", "n"}, script = "dst.set(new Uint8Array(src, 0, n), 0);")
    private static native void copyMapped(ArrayBuffer src, Uint8Array dst, int size);

    @Override public void waitIdle() { queue.onSubmittedWorkDone().await(); }

    /** data の頭から容量の終わりまでを見る Uint8Array（position は見ない）。direct でなければ写す。 */
    private static Uint8Array bytesOf(ByteBuffer data) {
        ByteBuffer whole;
        if (data.isDirect()) {
            whole = data.duplicate();
        } else {
            whole = ByteBuffer.allocateDirect(data.capacity()).order(ByteOrder.nativeOrder());
            ByteBuffer from = data.duplicate();
            from.position(0).limit(from.capacity());
            whole.put(from);
        }
        whole.position(0).limit(whole.capacity());
        return Uint8Array.fromJavaBuffer(whole);
    }

    // ── canvas ──

    /** id の canvas（無ければ作って body の終わりに足す）に描き先を作る。作れなければ IllegalStateException。 */
    public fge.webgpu.Surface createCanvasSurface(String canvasId) {
        GPUCanvasContext context = canvasContext(canvasId);
        if (isNullish(context)) throw new IllegalStateException("canvas " + canvasId + " から webgpu の文脈を取れない（WebGL2 を取った canvas は使えない）");
        return new BrowserSurface(context, device);
    }

    @JSBody(params = {"id"}, script =
        "var c = document.getElementById(id);"
        + "if (!c) { c = document.createElement('canvas'); c.id = id; document.body.appendChild(c); }"
        + "var ctx = c.getContext('webgpu'); if (ctx) window.fgeWebGpuTaken = true; return ctx;")
    private static native GPUCanvasContext canvasContext(String id);

    // ── 頁の素材と知らせ ──

    /**
     * 頁が起動の前に解いておいた道の絵（ImageBitmap・width × height）を、copyExternalImageToTexture（premultipliedAlpha: false）で GPU へ写してから読み戻し、
     * dst へ RGBA（1 画素 4 バイト・上の行から）で置く（読めるまで待つ）。dst は幅 × 高さ × 4 バイト以上。絵が無ければ IllegalStateException。
     * WhyNot: 写した texture をそのまま描く絵にしない — 描く側（WebGpuPaint）の絵の表に載せる口が無く、上げる口は画素を受ける形だけ。
     * WhyNot: 読み戻しを JS の中で待たない — 待つ間に wasm のメモリが伸びると、待つ前に作ったメモリの view が使えなくなる。JS は写して積むまで・待つのは readBuffer。
     */
    public void copyImageBitmap(String path, int width, int height, ByteBuffer dst) {
        int row = (width * 4 + 255) / 256 * 256;
        fge.webgpu.Buffer readback = createBuffer("fge image read", (long) row * height, BufferUsage.COPY_DST | BufferUsage.MAP_READ);
        try {
            String error = copyBitmapToBuffer(device, path, ((BrowserBuffer) readback).buffer, row);
            if (!error.isEmpty()) throw new IllegalStateException("絵 " + path + " を写せない: " + error);
            ByteBuffer padded = ByteBuffer.allocateDirect(row * height);
            readBuffer(readback, 0, row * height, padded);
            for (int y = 0; y < height; y++) {
                ByteBuffer line = padded.duplicate();
                line.position(y * row).limit(y * row + width * 4);
                ByteBuffer to = dst.duplicate();
                to.position(y * width * 4);
                to.put(line);
            }
        } finally {
            readback.destroy();
        }
    }

    @JSBody(params = {"device", "path", "buffer", "row"}, script = "return fgeCopyImageBitmap(device, path, buffer, row);")
    private static native String copyBitmapToBuffer(GPUDevice device, String path, GPUBuffer buffer, int row);

    /**
     * 頁が持つ機種の側の絵（key = WebImages.platformKey の字）を、gpu（BrowserWebGpu）の texture のレベル 0 の左上へ copyExternalImageToTexture で写す（待たない）。
     * 写した値は ImageBitmap のまま（premultipliedAlpha: false・色の変換なし・行 0 が絵の上）。絵が無い・大きさが texture と違う・写せなければ偽。texture は COPY_DST と RENDER_ATTACHMENT を持つ RGBA8。
     * WhyNot: 写した後に ImageBitmap を手放さない — 同じ key を別の部屋がまた写す（WebGL2 の texImagePlatform と同じ）。
     */
    public static boolean copyPlatformImage(fge.webgpu.WebGpu gpu, String key, fge.webgpu.Texture texture) {
        return copyPlatformImageToTexture(((BrowserWebGpu) gpu).device, key, ((BrowserObjects.BrowserTexture) texture).texture);
    }

    @JSBody(params = {"device", "key", "texture"}, script = "return fgeCopyPlatformImage(device, key, texture);")
    private static native boolean copyPlatformImageToTexture(GPUDevice device, String key, GPUTexture texture);

    /** 頁が機種の側の絵 key を width × height の ImageBitmap で今も持っているか（copyPlatformImage で写せるか）。 */
    @JSBody(params = {"key", "width", "height"}, script = "return fgeHasPlatformImage(key, width, height);")
    public static native boolean hasPlatformImage(String key, int width, int height);

    /** device を失ったら、頁に WebGL の時と同じ文で読み直しを案内する。 */
    public void onDeviceLost() { watchLost(device); }

    @JSBody(params = {"device"}, script = "fgeWatchDeviceLost(device);")
    private static native void watchLost(GPUDevice device);
}
