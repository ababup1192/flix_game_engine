package fge.webgpu.dawn;

import com.github.xpenatan.jParser.api.NativeObject;
import com.github.xpenatan.webgpu.*;
import fge.webgpu.*;
import fge.webgpu.dawn.DawnObjects.*;
import java.io.File;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import org.lwjgl.system.MemoryUtil;

/**
 * PC の WebGpu の実装（jWebGPU の JNI 版の Dawn。macOS は Metal）。作るのは {@link #open(String)}。
 * device lost の知らせは jWebGPU 0.3.4 に無いので、捨てた後は {@link #reopen()} で同じ instance の adapter から取り直す。
 */
public final class DawnWebGpu implements WebGpu {
    /** jWebGPU の版。ネイティブの置き場の名前に入れる（3 つの flix.toml と Makefile の GL_JAR_JWEBGPU と同じ。gl-jar を組む所が検査する）。 */
    public static final String JWEBGPU_VERSION = "0.3.4";

    private final WGPUInstance instance;
    private final WGPUAdapter adapter;
    private final WGPUDevice device;
    private final WGPUQueue queue;
    private final Limits limits;
    private final boolean timestampQuery;
    private final boolean coreFeaturesAndLimits;
    private final String adapterInfo;
    private int errors;
    private String lastError = "";
    private boolean destroyed;
    // WhyNot: callback を局所の変数にしない — Java の側の物が GC で消えると、ネイティブが呼び返す先が無くなる。
    private WGPUUncapturedErrorCallback errorCallback;
    private DawnBuffer idleSrc;
    private DawnBuffer idleDst;
    private final ByteBuffer idleRead = ByteBuffer.allocateDirect(16);

    private DawnWebGpu(WGPUInstance instance, WGPUAdapter adapter, WGPUDevice device, Limits limits,
                       boolean timestampQuery, boolean coreFeaturesAndLimits, String adapterInfo) {
        this.instance = instance;
        this.adapter = adapter;
        this.device = device;
        this.queue = device.getQueue();
        this.limits = limits;
        this.timestampQuery = timestampQuery;
        this.coreFeaturesAndLimits = coreFeaturesAndLimits;
        this.adapterInfo = adapterInfo;
    }

    // ── 開く ──

    /**
     * ネイティブを読み、Dawn の device を開く。nativeDir が空なら、読み済みの置き場か、まだなら版と backend ごとの既定の置き場（{@link #defaultNativeDir()}）。
     * 開けなければ IllegalStateException。ネイティブを読んだ後に別の置き場を名指ししても IllegalStateException。
     */
    public static DawnWebGpu open(String nativeDir) {
        DawnNatives.load(nativeDir, defaultNativeDir());
        WGPUInstance instance = WGPU.setupInstance(new WGPUInstanceDescriptor());
        if (instance == null || !instance.isValid()) throw new IllegalStateException("WebGPU の instance を作れない");
        return openOn(instance);
    }

    /** 同じ instance で adapter から device を取り直す（Dawn は 1 つの adapter から device を 1 つしか作らせない）。 */
    public DawnWebGpu reopen() { return openOn(instance); }

    /** ネイティブを書き出す既定の置き場。jWebGPU の版と backend を名前に入れる。 */
    public static String defaultNativeDir() {
        String os = System.getProperty("os.name", "");
        String home = System.getProperty("user.home", "");
        String leaf = "jwebgpu" + File.separator + JWEBGPU_VERSION + "-dawn";
        if (os.startsWith("Mac") && !home.isEmpty())
            return home + "/Library/Caches/flix_game_engine/" + leaf;
        return System.getProperty("java.io.tmpdir") + File.separator + "flix_game_engine-" + System.getProperty("user.name", "user") + File.separator + leaf;
    }

    private static DawnWebGpu openOn(WGPUInstance instance) {
        WGPUAdapter[] gotAdapter = {null};
        boolean[] adapterDone = {false};
        WGPURequestAdapterCallback adapterCallback = new WGPURequestAdapterCallback() {
            @Override protected void onCallback(WGPURequestAdapterStatus status, WGPUAdapter a, String message) {
                if (status == WGPURequestAdapterStatus.Success) gotAdapter[0] = a;
                adapterDone[0] = true;
            }
        };
        WGPURequestAdapterOptions options = new WGPURequestAdapterOptions();
        options.setPowerPreference(WGPUPowerPreference.HighPerformance);
        instance.requestAdapter(options, WGPUCallbackMode.AllowProcessEvents, adapterCallback);
        pump(instance, adapterDone);
        options.dispose();
        WGPUAdapter adapter = gotAdapter[0];
        if (adapter == null) throw new IllegalStateException("WebGPU の adapter が無い");

        WGPULimits adapterLimits = new WGPULimits();
        adapter.getLimits(adapterLimits);
        checkLimitsLayout(adapterLimits);
        WGPUDeviceDescriptor deviceDesc = new WGPUDeviceDescriptor();
        deviceDesc.setLabel("fge device");
        // WhyNot: requiredLimits を渡さない形にしない — 渡さないと device の上限は仕様の既定（2D の texture 8192 など）に下がる。
        deviceDesc.setRequiredLimits(adapterLimits);
        WGPUVectorFeatureName features = new WGPUVectorFeatureName();
        synchronized (DawnFormats.SHARED) {
            // WhyNot: core-features-and-limits を名前で要らない — jWebGPU の enum に名前が無く、数でしか渡せない。
            if (adapter.hasFeature(WGPUFeatureName.CUSTOM.setValue(0x1))) features.push_back(WGPUFeatureName.CUSTOM.setValue(0x1));
        }
        if (adapter.hasFeature(WGPUFeatureName.TimestampQuery)) features.push_back(WGPUFeatureName.TimestampQuery);
        deviceDesc.setRequiredFeatures(features);

        DawnWebGpu[] made = {null};
        WGPUDevice[] gotDevice = {null};
        boolean[] deviceDone = {false};
        String[] deviceMessage = {""};
        WGPURequestDeviceCallback deviceCallback = new WGPURequestDeviceCallback() {
            @Override protected void onCallback(WGPURequestDeviceStatus status, WGPUDevice d, String message) {
                if (status == WGPURequestDeviceStatus.Success) gotDevice[0] = d;
                deviceMessage[0] = message == null ? "" : message;
                deviceDone[0] = true;
            }
        };
        WGPUUncapturedErrorCallback errorCallback = new WGPUUncapturedErrorCallback() {
            @Override protected void onCallback(WGPUErrorType type, String message) {
                if (made[0] != null) made[0].noteError(type + ": " + message);
                else System.err.println("[webgpu] " + type + ": " + message);
            }
        };
        adapter.requestDevice(deviceDesc, WGPUCallbackMode.AllowProcessEvents, deviceCallback, errorCallback);
        pump(instance, deviceDone);
        deviceDesc.dispose();
        features.dispose();
        adapterLimits.dispose();
        WGPUDevice device = gotDevice[0];
        if (device == null) {
            adapter.release();
            throw new IllegalStateException("WebGPU の device を作れない: " + deviceMessage[0]);
        }

        WGPULimits deviceLimits = new WGPULimits();
        device.getLimits(deviceLimits);
        Limits limits = readLimits(deviceLimits);
        deviceLimits.dispose();
        boolean[] has = deviceFeatures(device);
        DawnWebGpu gpu = new DawnWebGpu(instance, adapter, device, limits, has[1], has[0], describe(adapter));
        gpu.errorCallback = errorCallback;
        made[0] = gpu;
        return gpu;
    }

    /** [core-features-and-limits, timestamp-query] を device が持つか。 */
    private static boolean[] deviceFeatures(WGPUDevice device) {
        WGPUSupportedFeatures supported = new WGPUSupportedFeatures();
        device.getFeatures(supported);
        boolean core = false;
        boolean timestamp = false;
        synchronized (DawnFormats.SHARED) {
            for (int i = 0; i < supported.getFeatureCount(); i++) {
                WGPUFeatureName name = supported.getFeatureAt(i);
                if (name == WGPUFeatureName.CUSTOM && name.getValue() == 0x1) core = true;
                if (name == WGPUFeatureName.TimestampQuery) timestamp = true;
            }
        }
        supported.dispose();
        return new boolean[]{core, timestamp};
    }

    private static String describe(WGPUAdapter adapter) {
        WGPUAdapterInfo info = new WGPUAdapterInfo();
        String text = adapter.getInfo(info)
            ? "Dawn " + info.getBackendType() + " " + info.getAdapterType() + " " + info.getDevice().c_str() + " (" + info.getDescription().c_str() + ")"
            : "?";
        info.dispose();
        return text;
    }

    // WGPULimits の native の並び（webgpu.h・Dawn 2025 以降）。u64 は 8 バイト境界。
    private static final int OFF_MAX_TEXTURE_DIMENSION_2D = 12;
    private static final int OFF_MAX_TEXTURE_ARRAY_LAYERS = 20;
    private static final int OFF_MAX_BIND_GROUPS = 24;
    private static final int OFF_MAX_SAMPLED_TEXTURES = 44;
    private static final int OFF_MAX_SAMPLERS = 48;
    private static final int OFF_MAX_STORAGE_BUFFERS = 52;
    private static final int OFF_MAX_UNIFORM_BUFFERS = 60;
    private static final int OFF_MAX_UNIFORM_BINDING_SIZE = 64;
    private static final int OFF_MAX_STORAGE_BINDING_SIZE = 72;
    private static final int OFF_MIN_UNIFORM_ALIGNMENT = 80;
    private static final int OFF_MIN_STORAGE_ALIGNMENT = 84;
    private static final int OFF_MAX_VERTEX_BUFFERS = 88;
    private static final int OFF_MAX_BUFFER_SIZE = 96;
    private static final int OFF_MAX_VERTEX_ATTRIBUTES = 104;

    // WhyNot: u64 の上限を jWebGPU の getter で読まない — getter が int を返し、下位 32 bit に切れる（41,747,087,360 が負の数になる）。
    private static Limits readLimits(WGPULimits l) {
        long a = l.native_address;
        return new Limits(
            MemoryUtil.memGetInt(a + OFF_MAX_TEXTURE_DIMENSION_2D), MemoryUtil.memGetInt(a + OFF_MAX_TEXTURE_ARRAY_LAYERS),
            MemoryUtil.memGetInt(a + OFF_MAX_BIND_GROUPS), MemoryUtil.memGetInt(a + OFF_MAX_SAMPLED_TEXTURES),
            MemoryUtil.memGetInt(a + OFF_MAX_SAMPLERS), MemoryUtil.memGetInt(a + OFF_MAX_STORAGE_BUFFERS),
            MemoryUtil.memGetInt(a + OFF_MAX_UNIFORM_BUFFERS), MemoryUtil.memGetInt(a + OFF_MAX_VERTEX_BUFFERS),
            MemoryUtil.memGetInt(a + OFF_MAX_VERTEX_ATTRIBUTES), MemoryUtil.memGetInt(a + OFF_MIN_UNIFORM_ALIGNMENT),
            MemoryUtil.memGetInt(a + OFF_MIN_STORAGE_ALIGNMENT), MemoryUtil.memGetLong(a + OFF_MAX_UNIFORM_BINDING_SIZE),
            MemoryUtil.memGetLong(a + OFF_MAX_STORAGE_BINDING_SIZE), MemoryUtil.memGetLong(a + OFF_MAX_BUFFER_SIZE));
    }

    // WhyNot: 並びの確かめを省かない — jWebGPU の版を上げて webgpu.h の並びが動くと、上の位置から黙って別の欄を読む。
    private static void checkLimitsLayout(WGPULimits l) {
        long a = l.native_address;
        boolean same = l.getMaxTextureDimension2D() == MemoryUtil.memGetInt(a + OFF_MAX_TEXTURE_DIMENSION_2D)
            && l.getMaxBindGroups() == MemoryUtil.memGetInt(a + OFF_MAX_BIND_GROUPS)
            && l.getMinStorageBufferOffsetAlignment() == MemoryUtil.memGetInt(a + OFF_MIN_STORAGE_ALIGNMENT)
            && l.getMaxVertexAttributes() == MemoryUtil.memGetInt(a + OFF_MAX_VERTEX_ATTRIBUTES)
            && (int) MemoryUtil.memGetLong(a + OFF_MAX_BUFFER_SIZE) == l.getMaxBufferSize();
        if (!same) throw new IllegalStateException("WGPULimits の並びが想定（jWebGPU " + JWEBGPU_VERSION + "）と違う");
    }

    // WhyNot: Thread.sleep で待たない — 待つたびに床ができ（試作では約 3 ms）、読み戻しの多い画面なしの描き出しが遅くなる。
    static void pump(WGPUInstance instance, boolean[] done) {
        long start = System.nanoTime();
        while (!done[0]) {
            instance.processEvents();
            Thread.onSpinWait();
            if (System.nanoTime() - start > 10_000_000_000L) throw new IllegalStateException("WebGPU の返事が 10 秒来ない");
        }
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

    @Override public int errorCount() {
        instance.processEvents();
        return errors;
    }

    @Override public String lastError() { return lastError; }

    /** device と、device が持つ物（待つための buffer・queue・adapter）を手放す。2 回目は何もしない。 */
    @Override public void destroy() {
        if (destroyed) return;
        destroyed = true;
        if (idleSrc != null) idleSrc.destroy();
        if (idleDst != null) idleDst.destroy();
        device.destroy();
        instance.processEvents();
        queue.release();
        device.release();
        adapter.release();
    }

    // ── 物を作る ──

    @Override public fge.webgpu.Buffer createBuffer(String label, long size, int usage) {
        WGPUBufferDescriptor desc = new WGPUBufferDescriptor();
        desc.setLabel(label);
        desc.setSize(size);
        desc.setMappedAtCreation(false);
        WGPUBuffer buffer = new WGPUBuffer();
        synchronized (DawnFormats.SHARED) {
            desc.setUsage(DawnFormats.bufferUsage(usage));
            device.createBuffer(desc, buffer);
        }
        desc.dispose();
        return new DawnBuffer(buffer, size);
    }

    @Override public fge.webgpu.Texture createTexture(String label, int width, int height, TextureFormat format, int usage,
                                                      int mipLevelCount, int sampleCount) {
        WGPUTextureDescriptor desc = new WGPUTextureDescriptor();
        desc.setLabel(label);
        desc.setDimension(WGPUTextureDimension._2D);
        desc.getSize().setWidth(width);
        desc.getSize().setHeight(height);
        desc.getSize().setDepthOrArrayLayers(1);
        desc.setFormat(DawnFormats.textureFormat(format));
        desc.setMipLevelCount(mipLevelCount);
        desc.setSampleCount(sampleCount);
        desc.setViewFormats(WGPUVectorTextureFormat.NULL);
        WGPUTexture texture = new WGPUTexture();
        synchronized (DawnFormats.SHARED) {
            desc.setUsage(DawnFormats.textureUsage(usage));
            device.createTexture(desc, texture);
        }
        desc.dispose();
        return new DawnTexture(texture, width, height, format, true);
    }

    // WhyNot: 比べる sampler（compare）を作れる形にしない — 使う所がまだ無く、bind group の項目の種類からも外してそろえた。
    @Override public fge.webgpu.Sampler createSampler(String label, FilterMode filter, FilterMode mipmapFilter, AddressMode address) {
        WGPUSamplerDescriptor desc = new WGPUSamplerDescriptor();
        desc.setLabel(label);
        WGPUAddressMode mode = DawnFormats.addressMode(address);
        desc.setAddressModeU(mode);
        desc.setAddressModeV(mode);
        desc.setAddressModeW(mode);
        WGPUFilterMode f = filter == FilterMode.LINEAR ? WGPUFilterMode.Linear : WGPUFilterMode.Nearest;
        desc.setMagFilter(f);
        desc.setMinFilter(f);
        desc.setMipmapFilter(mipmapFilter == FilterMode.LINEAR ? WGPUMipmapFilterMode.Linear : WGPUMipmapFilterMode.Nearest);
        desc.setLodMinClamp(0f);
        desc.setLodMaxClamp(32f);
        desc.setCompare(WGPUCompareFunction.Undefined);
        desc.setMaxAnisotropy(1);
        WGPUSampler sampler = new WGPUSampler();
        device.createSampler(desc, sampler);
        desc.dispose();
        return new DawnSampler(sampler);
    }

    @Override public fge.webgpu.ShaderModule createShaderModule(String label, String wgsl) {
        WGPUShaderModuleDescriptor desc = new WGPUShaderModuleDescriptor();
        desc.setLabel(label);
        WGPUShaderSourceWGSL source = new WGPUShaderSourceWGSL();
        source.getChain().setNext(WGPUChainedStruct.NULL);
        source.getChain().setSType(WGPUSType.ShaderSourceWGSL);
        source.setCode(wgsl);
        desc.setNextInChain(source.getChain());
        WGPUShaderModule module = new WGPUShaderModule();
        device.createShaderModule(desc, module);
        desc.dispose();
        source.dispose();
        return new DawnShaderModule(module);
    }

    @Override public String getCompilationInfo(fge.webgpu.ShaderModule module) {
        StringBuilder out = new StringBuilder();
        boolean[] done = {false};
        WGPUCompilationInfoCallback callback = new WGPUCompilationInfoCallback() {
            @Override protected void onCallback(WGPUCompilationInfoRequestStatus status, WGPUCompilationInfo info) {
                for (int i = 0; i < info.getMessageCount(); i++) {
                    WGPUCompilationMessage m = info.getMessage(i);
                    out.append(m.getType()).append(' ').append(m.getLineNum()).append(':').append(m.getLinePos())
                       .append(' ').append(m.getMessage().c_str()).append('\n');
                }
                done[0] = true;
            }
        };
        ((DawnShaderModule) module).module.setCallback(WGPUCallbackMode.AllowProcessEvents, callback);
        pump(instance, done);
        return out.toString();
    }

    @Override public fge.webgpu.BindGroupLayout createBindGroupLayout(BindGroupLayoutDesc desc) {
        WGPUVectorBindGroupLayoutEntry entries = new WGPUVectorBindGroupLayoutEntry();
        List<WGPUBindGroupLayoutEntry> made = new ArrayList<>();
        WGPUBindGroupLayout layout = new WGPUBindGroupLayout();
        WGPUBindGroupLayoutDescriptor d = new WGPUBindGroupLayoutDescriptor();
        synchronized (DawnFormats.SHARED) {
            for (BindGroupLayoutDesc.Entry e : desc.entries()) {
                WGPUBindGroupLayoutEntry entry = new WGPUBindGroupLayoutEntry();
                entry.setNextInChain(WGPUChainedStruct.NULL);
                entry.setBinding(e.binding);
                entry.setVisibility(DawnFormats.shaderStage(e.visibility));
                // WhyNot: 使わない種類の欄を書かずに済ませない — 0 で埋まる保証が無く、残った値で別の種類の項目と読まれる。
                entry.getBuffer().setType(WGPUBufferBindingType.BindingNotUsed);
                entry.getBuffer().setHasDynamicOffset(0);
                entry.getBuffer().setMinBindingSize(0);
                entry.getSampler().setType(WGPUSamplerBindingType.BindingNotUsed);
                entry.getTexture().setSampleType(WGPUTextureSampleType.BindingNotUsed);
                entry.getTexture().setViewDimension(WGPUTextureViewDimension._2D);
                entry.getTexture().setMultisampled(0);
                entry.getStorageTexture().setAccess(WGPUStorageTextureAccess.BindingNotUsed);
                switch (e.kind) {
                    case BUFFER -> entry.getBuffer().setType(DawnFormats.bufferBinding(e.bufferType));
                    case TEXTURE -> entry.getTexture().setSampleType(DawnFormats.sampleType(e.sampleType));
                    case SAMPLER -> entry.getSampler().setType(DawnFormats.samplerBinding(e.samplerType));
                }
                entries.push_back(entry);
                made.add(entry);
            }
            d.setLabel(desc.label());
            d.setEntries(entries);
            device.createBindGroupLayout(d, layout);
        }
        d.dispose();
        entries.dispose();
        made.forEach(NativeObject::dispose);
        return new DawnBindGroupLayout(layout);
    }

    @Override public fge.webgpu.BindGroup createBindGroup(BindGroupDesc desc) {
        WGPUVectorBindGroupEntry entries = new WGPUVectorBindGroupEntry();
        List<WGPUBindGroupEntry> made = new ArrayList<>();
        for (BindGroupDesc.Entry e : desc.entries()) {
            WGPUBindGroupEntry entry = new WGPUBindGroupEntry();
            entry.reset();
            entry.setBinding(e.binding);
            if (e.buffer != null) {
                entry.setBuffer(((DawnBuffer) e.buffer).buffer);
                entry.setOffset(e.offset);
                entry.setSize(e.size);
            }
            if (e.view != null) entry.setTextureView(((DawnTextureView) e.view).view);
            if (e.sampler != null) entry.setSampler(((DawnSampler) e.sampler).sampler);
            entries.push_back(entry);
            made.add(entry);
        }
        WGPUBindGroupDescriptor d = new WGPUBindGroupDescriptor();
        d.setLabel(desc.label());
        d.setLayout(((DawnBindGroupLayout) desc.layout()).layout);
        d.setEntries(entries);
        WGPUBindGroup group = new WGPUBindGroup();
        device.createBindGroup(d, group);
        d.dispose();
        entries.dispose();
        made.forEach(NativeObject::dispose);
        return new DawnBindGroup(group);
    }

    @Override public fge.webgpu.RenderPipeline createRenderPipeline(RenderPipelineDesc desc) {
        // 作り終わるまで生かし、最後にまとめて手放す物（頂点の buffer の形は属性の列の中身を指すだけ）。
        List<NativeObject> scratch = new ArrayList<>();
        WGPUVectorBindGroupLayout layouts = new WGPUVectorBindGroupLayout();
        scratch.add(layouts);
        for (fge.webgpu.BindGroupLayout l : desc.bindGroupLayouts()) layouts.push_back(((DawnBindGroupLayout) l).layout);
        WGPUPipelineLayoutDescriptor layoutDesc = new WGPUPipelineLayoutDescriptor();
        scratch.add(layoutDesc);
        layoutDesc.setLabel(desc.label());
        layoutDesc.setBindGroupLayouts(layouts);
        WGPUPipelineLayout layout = new WGPUPipelineLayout();
        device.createPipelineLayout(layoutDesc, layout);

        WGPURenderPipelineDescriptor d = new WGPURenderPipelineDescriptor();
        scratch.add(d);
        d.setLabel(desc.label());
        d.setLayout(layout);
        WGPUVectorVertexBufferLayout buffers = new WGPUVectorVertexBufferLayout();
        scratch.add(buffers);
        for (RenderPipelineDesc.VertexBuffer vb : desc.vertexBuffers()) {
            WGPUVectorVertexAttribute attributes = new WGPUVectorVertexAttribute();
            scratch.add(attributes);
            for (RenderPipelineDesc.Attribute at : vb.attributes) {
                WGPUVertexAttribute attribute = new WGPUVertexAttribute();
                scratch.add(attribute);
                attribute.setFormat(DawnFormats.vertexFormat(at.format));
                attribute.setOffset(at.offset);
                attribute.setShaderLocation(at.location);
                attributes.push_back(attribute);
            }
            WGPUVertexBufferLayout bl = new WGPUVertexBufferLayout();
            scratch.add(bl);
            bl.setArrayStride(vb.arrayStride);
            bl.setStepMode(vb.perInstance ? WGPUVertexStepMode.Instance : WGPUVertexStepMode.Vertex);
            bl.setAttributes(attributes);
            buffers.push_back(bl);
        }
        d.getVertex().setNextInChain(WGPUChainedStruct.NULL);
        d.getVertex().setModule(((DawnShaderModule) desc.vertexModule()).module);
        d.getVertex().setEntryPoint(desc.vertexEntry());
        d.getVertex().setConstants(WGPUVectorConstantEntry.NULL);
        d.getVertex().setBuffers(desc.vertexBuffers().isEmpty() ? WGPUVectorVertexBufferLayout.NULL : buffers);
        d.getPrimitive().setNextInChain(WGPUChainedStruct.NULL);
        d.getPrimitive().setTopology(DawnFormats.topology(desc.topology()));
        d.getPrimitive().setStripIndexFormat(WGPUIndexFormat.Undefined);
        d.getPrimitive().setFrontFace(desc.frontFace() == FrontFace.CCW ? WGPUFrontFace.CCW : WGPUFrontFace.CW);
        d.getPrimitive().setCullMode(DawnFormats.cullMode(desc.cullMode()));

        if (desc.fragmentModule() != null) {
            WGPUFragmentState fragment = new WGPUFragmentState();
            scratch.add(fragment);
            WGPUVectorColorTargetState targets = new WGPUVectorColorTargetState();
            scratch.add(targets);
            for (RenderPipelineDesc.ColorTarget ct : desc.colorTargets()) {
                WGPUColorTargetState target = new WGPUColorTargetState();
                scratch.add(target);
                target.setNextInChain(WGPUChainedStruct.NULL);
                target.setFormat(DawnFormats.textureFormat(ct.format));
                target.setWriteMask(WGPUColorWriteMask.All);
                if (ct.color != null) {
                    WGPUBlendState blend = new WGPUBlendState();
                    scratch.add(blend);
                    setBlend(blend.getColor(), ct.color);
                    setBlend(blend.getAlpha(), ct.alpha);
                    target.setBlend(blend);
                } else target.setBlend(WGPUBlendState.NULL);
                targets.push_back(target);
            }
            fragment.setNextInChain(WGPUChainedStruct.NULL);
            fragment.setModule(((DawnShaderModule) desc.fragmentModule()).module);
            fragment.setEntryPoint(desc.fragmentEntry());
            fragment.setConstants(WGPUVectorConstantEntry.NULL);
            fragment.setTargets(targets);
            d.setFragment(fragment);
        } else d.setFragment(WGPUFragmentState.NULL);

        if (desc.depthFormat() != null) {
            WGPUDepthStencilState depth = new WGPUDepthStencilState();
            scratch.add(depth);
            depth.setNextInChain(WGPUChainedStruct.NULL);
            depth.setFormat(DawnFormats.textureFormat(desc.depthFormat()));
            depth.setDepthWriteEnabled(desc.depthWrite() ? WGPUOptionalBool.True : WGPUOptionalBool.False);
            depth.setDepthCompare(DawnFormats.compare(desc.depthCompare()));
            RenderPipelineDesc.Stencil s = desc.stencilState();
            setStencilFace(depth.getStencilFront(), s);
            setStencilFace(depth.getStencilBack(), s);
            depth.setStencilReadMask(s == null ? 0xff : s.readMask);
            depth.setStencilWriteMask(s == null ? 0 : s.writeMask);
            depth.setDepthBias(0);
            depth.setDepthBiasSlopeScale(0f);
            depth.setDepthBiasClamp(0f);
            d.setDepthStencil(depth);
        } else d.setDepthStencil(WGPUDepthStencilState.NULL);
        d.getMultisample().setNextInChain(WGPUChainedStruct.NULL);
        d.getMultisample().setCount(desc.sampleCount());
        d.getMultisample().setMask(-1);
        d.getMultisample().setAlphaToCoverageEnabled(false);

        WGPURenderPipeline pipeline = new WGPURenderPipeline();
        device.createRenderPipeline(d, pipeline);
        // WhyNot: pipeline layout を pipeline と一緒に持ち回らない — pipeline が自分で参照を持つので、ここで手放してよい。
        layout.release();
        scratch.forEach(NativeObject::dispose);
        return new DawnRenderPipeline(pipeline);
    }

    private static void setBlend(WGPUBlendComponent c, RenderPipelineDesc.BlendComponent b) {
        c.setSrcFactor(DawnFormats.blendFactor(b.src));
        c.setDstFactor(DawnFormats.blendFactor(b.dst));
        c.setOperation(DawnFormats.blendOperation(b.operation));
    }

    private static void setStencilFace(WGPUStencilFaceState face, RenderPipelineDesc.Stencil s) {
        face.setCompare(s == null ? WGPUCompareFunction.Always : DawnFormats.compare(s.compare));
        face.setFailOp(s == null ? WGPUStencilOperation.Keep : DawnFormats.stencilOp(s.failOp));
        face.setDepthFailOp(s == null ? WGPUStencilOperation.Keep : DawnFormats.stencilOp(s.depthFailOp));
        face.setPassOp(s == null ? WGPUStencilOperation.Keep : DawnFormats.stencilOp(s.passOp));
    }

    @Override public fge.webgpu.QuerySet createTimestampQuerySet(String label, int count) {
        WGPUQuerySetDescriptor desc = new WGPUQuerySetDescriptor();
        desc.setLabel(label);
        desc.setType(WGPUQueryType.Timestamp);
        desc.setCount(count);
        WGPUQuerySet querySet = new WGPUQuerySet();
        device.createQuerySet(desc, querySet);
        desc.dispose();
        return new DawnQuerySet(querySet, count);
    }

    @Override public fge.webgpu.CommandEncoder createCommandEncoder(String label) {
        WGPUCommandEncoderDescriptor desc = new WGPUCommandEncoderDescriptor();
        desc.setLabel(label);
        WGPUCommandEncoder encoder = new WGPUCommandEncoder();
        device.createCommandEncoder(desc, encoder);
        desc.dispose();
        return new DawnCommandEncoder(encoder, this);
    }

    @Override public fge.webgpu.RenderBundleEncoder createRenderBundleEncoder(String label, TextureFormat colorFormat, TextureFormat depthFormat, int sampleCount) {
        WGPURenderBundleEncoderDescriptor desc = new WGPURenderBundleEncoderDescriptor();
        desc.setLabel(label);
        WGPUVectorTextureFormat colors = new WGPUVectorTextureFormat();
        if (colorFormat != null) colors.push_back(DawnFormats.textureFormat(colorFormat));
        desc.setColorFormats(colors);
        desc.setDepthStencilFormat(depthFormat == null ? WGPUTextureFormat.Undefined : DawnFormats.textureFormat(depthFormat));
        desc.setSampleCount(sampleCount);
        desc.setDepthReadOnly(0);
        desc.setStencilReadOnly(0);
        WGPURenderBundleEncoder encoder = new WGPURenderBundleEncoder();
        device.createRenderBundleEncoder(desc, encoder);
        desc.dispose();
        colors.dispose();
        return new DawnRenderBundleEncoder(encoder);
    }

    // 1 コマに何度も通るので、descriptor は device ごとに 1 組を使い回す（全部の欄を毎回書き直す）。
    private final WGPURenderPassDescriptor passDesc = new WGPURenderPassDescriptor();
    private final WGPURenderPassColorAttachment[] colorScratch = {
        new WGPURenderPassColorAttachment(), new WGPURenderPassColorAttachment(),
        new WGPURenderPassColorAttachment(), new WGPURenderPassColorAttachment()};
    private final WGPUVectorRenderPassColorAttachment colorVector = new WGPUVectorRenderPassColorAttachment();
    private final WGPURenderPassDepthStencilAttachment depthScratch = new WGPURenderPassDepthStencilAttachment();

    fge.webgpu.RenderPass beginRenderPass(WGPUCommandEncoder encoder, RenderPassDesc desc) {
        List<RenderPassDesc.ColorAttachment> colors = desc.colors();
        if (colors.size() > colorScratch.length) throw new IllegalArgumentException("色の描き先は 4 枚まで");
        for (int i = 0; i < colors.size(); i++) {
            RenderPassDesc.ColorAttachment c = colors.get(i);
            WGPURenderPassColorAttachment ca = colorScratch[i];
            ca.setNextInChain(WGPUChainedStruct.NULL);
            ca.setView(((DawnTextureView) c.view).view);
            ca.setResolveTarget(c.resolveTarget == null ? WGPUTextureView.NULL : ((DawnTextureView) c.resolveTarget).view);
            ca.setLoadOp(c.clear ? WGPULoadOp.Clear : WGPULoadOp.Load);
            ca.setStoreOp(WGPUStoreOp.Store);
            ca.getClearValue().setColor((float) c.r, (float) c.g, (float) c.b, (float) c.a);
            // WhyNot: depthSlice を 0 のままにしない — 0 は 3D の texture の 0 番の面を指す値で、2D の描き先の「無し」は u32 の最大。
            ca.setDepthSlice(-1);
        }
        passDesc.setNextInChain(WGPUChainedStruct.NULL);
        passDesc.setLabel(desc.label());
        // WhyNot: 1 枚用の setColorAttachments の多重定義を使わない — jWebGPU 0.3.4 では beginRenderPass の中で落ちた（SIGSEGV）。
        colorVector.clear();
        for (int i = 0; i < colors.size(); i++) colorVector.push_back(colorScratch[i]);
        passDesc.setColorAttachments(colorVector);
        if (desc.depthView() != null) {
            depthScratch.setView(((DawnTextureView) desc.depthView()).view);
            depthScratch.setDepthLoadOp(desc.depthClear() ? WGPULoadOp.Clear : WGPULoadOp.Load);
            depthScratch.setDepthStoreOp(WGPUStoreOp.Store);
            depthScratch.setDepthClearValue((float) desc.depthClearValue());
            depthScratch.setDepthReadOnly(false);
            depthScratch.setStencilLoadOp(desc.hasStencil() ? (desc.depthClear() ? WGPULoadOp.Clear : WGPULoadOp.Load) : WGPULoadOp.Undefined);
            depthScratch.setStencilStoreOp(desc.hasStencil() ? WGPUStoreOp.Store : WGPUStoreOp.Undefined);
            depthScratch.setStencilClearValue(desc.stencilClearValue());
            depthScratch.setStencilReadOnly(false);
            passDesc.setDepthStencilAttachment(depthScratch);
        } else passDesc.setDepthStencilAttachment(WGPURenderPassDepthStencilAttachment.NULL);
        WGPURenderPassEncoder pass = new WGPURenderPassEncoder();
        if (desc.timestamps() != null) {
            synchronized (DawnFormats.SHARED) {
                // WhyNot: 欄に 1 つ持たない — jWebGPU はこの型を obtain（共有の 1 個）でしか作らせない。
                WGPUPassTimestampWrites timestampScratch = WGPUPassTimestampWrites.obtain();
                timestampScratch.setQuerySet(((DawnQuerySet) desc.timestamps()).querySet);
                timestampScratch.setBeginningOfPassWriteIndex(desc.timestampBegin());
                timestampScratch.setEndOfPassWriteIndex(desc.timestampEnd());
                passDesc.setTimestampWrites(timestampScratch);
                encoder.beginRenderPass(passDesc, pass);
            }
        } else {
            passDesc.setTimestampWrites(WGPUPassTimestampWrites.NULL);
            encoder.beginRenderPass(passDesc, pass);
        }
        return new DawnRenderPass(pass);
    }

    // ── queue ──

    @Override public void writeBuffer(fge.webgpu.Buffer buffer, long offset, ByteBuffer data, int dataOffset, int size) {
        if (dataOffset < 0 || size < 0 || dataOffset + size > data.capacity())
            throw new IllegalArgumentException("writeBuffer の data が短い: " + dataOffset + "+" + size + " > " + data.capacity());
        // WhyNot: data の position で範囲を渡さない — jWebGPU は ByteBuffer の先頭の番地をそのまま使い、position を見ない。
        ByteBuffer from = dataOffset == 0 ? data : data.slice(dataOffset, size);
        queue.writeBuffer(((DawnBuffer) buffer).buffer, Math.toIntExact(offset), from, size);
    }

    @Override public void writeTexture(fge.webgpu.Texture texture, int mip, int x, int y, int width, int height,
                                       ByteBuffer data, int dataOffset, int bytesPerRow) {
        int size = bytesPerRow * (height - 1) + width * texture.format().bytesPerTexel();
        // WhyNot: 足りない data を切り詰めて渡さない — 下の行が黙って欠けた絵になり、どこで欠けたかが分からない。
        if (dataOffset < 0 || dataOffset + size > data.capacity())
            throw new IllegalArgumentException("writeTexture の data が短い: " + dataOffset + "+" + size + " > " + data.capacity());
        ByteBuffer from = data.slice(dataOffset, size);
        WGPUTexelCopyTextureInfo dst = new WGPUTexelCopyTextureInfo();
        dst.setTexture(((DawnTexture) texture).texture);
        dst.setMipLevel(mip);
        dst.getOrigin().set(x, y, 0);
        dst.setAspect(WGPUTextureAspect.All);
        WGPUTexelCopyBufferLayout layout = new WGPUTexelCopyBufferLayout();
        layout.setOffset(0);
        layout.setBytesPerRow(bytesPerRow);
        layout.setRowsPerImage(height);
        WGPUExtent3D extent = new WGPUExtent3D();
        extent.setWidth(width);
        extent.setHeight(height);
        extent.setDepthOrArrayLayers(1);
        queue.writeTexture(dst, from, size, layout, extent);
        dst.dispose();
        layout.dispose();
        extent.dispose();
    }

    @Override public void submit(fge.webgpu.CommandBuffer commands) {
        WGPUCommandBuffer cb = ((DawnCommandBuffer) commands).commands;
        queue.submit(cb);
        cb.release();
    }

    @Override public void readBuffer(fge.webgpu.Buffer buffer, long offset, int size, ByteBuffer dst) {
        WGPUBuffer b = ((DawnBuffer) buffer).buffer;
        int at = Math.toIntExact(offset);
        boolean[] done = {false};
        boolean[] ok = {false};
        String[] why = {""};
        WGPUBufferMapCallback callback = new WGPUBufferMapCallback() {
            @Override protected void onCallback(WGPUMapAsyncStatus status, String message) {
                ok[0] = status == WGPUMapAsyncStatus.Success;
                why[0] = status + " " + message;
                done[0] = true;
            }
        };
        b.mapAsync(WGPUMapMode.Read, at, size, WGPUCallbackMode.AllowProcessEvents, callback);
        pump(instance, done);
        if (!ok[0]) throw new IllegalStateException("buffer を map できない: " + why[0]);
        b.getConstMappedRange(at, size, dst);
        b.unmap();
    }

    // WhyNot: queue.onSubmittedWorkDone で待たない — jWebGPU 0.3.4 に関数が無い。小さな写しを map して、その前の仕事が終わったとみなす。
    @Override public void waitIdle() {
        if (idleSrc == null) {
            idleSrc = (DawnBuffer) createBuffer("fge idle src", 16, BufferUsage.COPY_SRC | BufferUsage.COPY_DST);
            idleDst = (DawnBuffer) createBuffer("fge idle dst", 16, BufferUsage.COPY_DST | BufferUsage.MAP_READ);
        }
        fge.webgpu.CommandEncoder encoder = createCommandEncoder("fge idle");
        encoder.copyBufferToBuffer(idleSrc, 0, idleDst, 0, 16);
        submit(encoder.finish());
        readBuffer(idleDst, 0, 16, idleRead);
    }

    // ── ウィンドウ（macOS） ──

    /** GLFW のウィンドウの NSWindow（glfwGetCocoaWindow の値）に描き先を作る。Dawn がウィンドウの view に CAMetalLayer を付ける。 */
    public fge.webgpu.Surface createMacSurface(long nsWindow) {
        NativeObject handle = NativeObject.native_new().native_setAddress(nsWindow);
        WGPUSurface surface = instance.createMacSurface(handle);
        if (surface == null) throw new IllegalStateException("surface を作れない");
        return new DawnSurface(surface, adapter, device);
    }
}
