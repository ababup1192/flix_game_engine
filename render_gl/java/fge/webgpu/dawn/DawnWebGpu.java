package fge.webgpu.dawn;

import com.github.xpenatan.jParser.api.NativeObject;
import com.github.xpenatan.webgpu.*;
import fge.webgpu.*;
import fge.webgpu.dawn.DawnObjects.*;
import java.io.File;
import java.nio.ByteBuffer;
import org.lwjgl.system.MemoryUtil;

/**
 * PC の WebGpu の実装（jWebGPU の JNI 版の Dawn。macOS は Metal）。作るのは {@link #open(String)}。
 * device lost の知らせは jWebGPU 0.3.4 に無いので、捨てた後は {@link #reopen()} で同じ instance の adapter から取り直す。
 */
public final class DawnWebGpu implements WebGpu {
    /** jWebGPU の版。ネイティブの置き場の名前に入れる。 */
    public static final String JWEBGPU_VERSION = "0.3.4";

    private static boolean nativesLoaded;

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
    // WhyNot: callback を局所の変数にしない — Java の側の物が GC で消えると、ネイティブが呼び返す先が無くなる。
    private WGPUUncapturedErrorCallback errorCallback;
    private WGPUBuffer idleSrc;
    private WGPUBuffer idleDst;

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
     * ネイティブを読み、Dawn の device を開く。nativeDir が空なら版と backend ごとの既定の置き場（{@link #defaultNativeDir()}）。
     * 開けなければ IllegalStateException。
     */
    public static DawnWebGpu open(String nativeDir) {
        loadNatives(nativeDir.isEmpty() ? defaultNativeDir() : nativeDir);
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

    // WhyNot: jParser の既定の置き場（${java.io.tmpdir}/jParser${user.name}）のままにしない — 版や backend の違う物が
    // 同じ名前の dylib をその場で上書きし、開いている側のプロセスを macOS が署名の不一致で落とす。
    // WhyNot: java.io.tmpdir を差し替えたままにしない — 同じプロセスの他の部品（音・画像の一時ファイル）の置き場まで動く。
    private static synchronized void loadNatives(String dir) {
        if (nativesLoaded) return;
        new File(dir).mkdirs();
        String saved = System.getProperty("java.io.tmpdir");
        boolean[] ok = {false};
        Throwable[] why = {null};
        System.setProperty("java.io.tmpdir", dir);
        try {
            JWebGPULoader.init(JWebGPUBackend.DAWN, (success, e) -> { ok[0] = success; why[0] = e; });
        } finally {
            System.setProperty("java.io.tmpdir", saved);
        }
        if (!ok[0]) throw new IllegalStateException("jWebGPU のネイティブを読めない（" + dir + "）", why[0]);
        nativesLoaded = true;
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
        WGPUAdapter adapter = gotAdapter[0];
        if (adapter == null) throw new IllegalStateException("WebGPU の adapter が無い");

        WGPULimits adapterLimits = new WGPULimits();
        adapter.getLimits(adapterLimits);
        checkLimitsLayout(adapterLimits);
        WGPUDeviceDescriptor deviceDesc = new WGPUDeviceDescriptor();
        deviceDesc.setLabel("fge device");
        // WhyNot: requiredLimits を渡さない形にしない — 渡さないと device の上限は仕様の既定（2D の texture 8192 など）に下がる。
        deviceDesc.setRequiredLimits(adapterLimits);
        boolean wantCore = adapter.hasFeature(coreFeaturesAndLimitsName());
        boolean wantTimestamp = adapter.hasFeature(WGPUFeatureName.TimestampQuery);
        WGPUVectorFeatureName features = new WGPUVectorFeatureName();
        // WhyNot: core-features-and-limits を名前で要らない — jWebGPU の enum に名前が無く、数でしか渡せない。
        if (wantCore) features.push_back(coreFeaturesAndLimitsName());
        if (wantTimestamp) features.push_back(WGPUFeatureName.TimestampQuery);
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
        WGPUDevice device = gotDevice[0];
        if (device == null) throw new IllegalStateException("WebGPU の device を作れない: " + deviceMessage[0]);

        WGPULimits deviceLimits = new WGPULimits();
        device.getLimits(deviceLimits);
        boolean[] has = deviceFeatures(device);
        DawnWebGpu gpu = new DawnWebGpu(instance, adapter, device, readLimits(deviceLimits), has[1], has[0], describe(adapter));
        gpu.errorCallback = errorCallback;
        made[0] = gpu;
        return gpu;
    }

    // WhyNot: CUSTOM を使い回したまま返さない — jWebGPU の CUSTOM は 1 つの値を持ち回る作りで、次に setValue した所で値が変わる。
    private static WGPUFeatureName coreFeaturesAndLimitsName() { return WGPUFeatureName.CUSTOM.setValue(0x1); }

    /** [core-features-and-limits, timestamp-query] を device が持つか。 */
    private static boolean[] deviceFeatures(WGPUDevice device) {
        WGPUSupportedFeatures supported = new WGPUSupportedFeatures();
        device.getFeatures(supported);
        boolean core = false;
        boolean timestamp = false;
        for (int i = 0; i < supported.getFeatureCount(); i++) {
            WGPUFeatureName name = supported.getFeatureAt(i);
            if (name == WGPUFeatureName.CUSTOM && name.getValue() == 0x1) core = true;
            if (name == WGPUFeatureName.TimestampQuery) timestamp = true;
        }
        return new boolean[]{core, timestamp};
    }

    private static String describe(WGPUAdapter adapter) {
        WGPUAdapterInfo info = new WGPUAdapterInfo();
        if (!adapter.getInfo(info)) return "?";
        return "Dawn " + info.getBackendType() + " " + info.getAdapterType() + " " + info.getDevice().c_str()
            + " (" + info.getDescription().c_str() + ")";
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

    @Override public void destroy() { device.destroy(); }

    // ── 物を作る ──

    @Override public fge.webgpu.Buffer createBuffer(String label, long size, int usage) {
        WGPUBufferDescriptor desc = new WGPUBufferDescriptor();
        desc.setLabel(label);
        desc.setSize(size);
        desc.setUsage(WGPUBufferUsage.CUSTOM.setValue(usage));
        desc.setMappedAtCreation(false);
        WGPUBuffer buffer = new WGPUBuffer();
        device.createBuffer(desc, buffer);
        desc.dispose();
        return new DawnBuffer(buffer, size);
    }

    @Override public fge.webgpu.Texture createTexture(String label, int width, int height, TextureFormat format, int usage,
                                                      int mipLevelCount, int sampleCount) {
        WGPUTextureDescriptor desc = new WGPUTextureDescriptor();
        desc.setLabel(label);
        desc.setUsage(WGPUTextureUsage.CUSTOM.setValue(usage));
        desc.setDimension(WGPUTextureDimension._2D);
        desc.getSize().setWidth(width);
        desc.getSize().setHeight(height);
        desc.getSize().setDepthOrArrayLayers(1);
        desc.setFormat(textureFormat(format));
        desc.setMipLevelCount(mipLevelCount);
        desc.setSampleCount(sampleCount);
        desc.setViewFormats(WGPUVectorTextureFormat.NULL);
        WGPUTexture texture = new WGPUTexture();
        device.createTexture(desc, texture);
        desc.dispose();
        return new DawnTexture(texture, width, height, format, true);
    }

    @Override public fge.webgpu.Sampler createSampler(String label, FilterMode filter, FilterMode mipmapFilter, AddressMode address) {
        WGPUSamplerDescriptor desc = new WGPUSamplerDescriptor();
        desc.setLabel(label);
        WGPUAddressMode mode = switch (address) {
            case CLAMP_TO_EDGE -> WGPUAddressMode.ClampToEdge;
            case REPEAT -> WGPUAddressMode.Repeat;
            case MIRROR_REPEAT -> WGPUAddressMode.MirrorRepeat;
        };
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
        for (BindGroupLayoutDesc.Entry e : desc.entries()) {
            WGPUBindGroupLayoutEntry entry = new WGPUBindGroupLayoutEntry();
            entry.setNextInChain(WGPUChainedStruct.NULL);
            entry.setBinding(e.binding);
            entry.setVisibility(WGPUShaderStage.CUSTOM.setValue(e.visibility));
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
                case BUFFER -> entry.getBuffer().setType(switch (e.bufferType) {
                    case UNIFORM -> WGPUBufferBindingType.Uniform;
                    case STORAGE -> WGPUBufferBindingType.Storage;
                    case READ_ONLY_STORAGE -> WGPUBufferBindingType.ReadOnlyStorage;
                });
                case TEXTURE -> entry.getTexture().setSampleType(switch (e.sampleType) {
                    case FLOAT -> WGPUTextureSampleType.Float;
                    case UNFILTERABLE_FLOAT -> WGPUTextureSampleType.UnfilterableFloat;
                    case DEPTH -> WGPUTextureSampleType.Depth;
                    case SINT -> WGPUTextureSampleType.Sint;
                    case UINT -> WGPUTextureSampleType.Uint;
                });
                case SAMPLER -> entry.getSampler().setType(switch (e.samplerType) {
                    case FILTERING -> WGPUSamplerBindingType.Filtering;
                    case NON_FILTERING -> WGPUSamplerBindingType.NonFiltering;
                    case COMPARISON -> WGPUSamplerBindingType.Comparison;
                });
            }
            entries.push_back(entry);
        }
        WGPUBindGroupLayoutDescriptor d = new WGPUBindGroupLayoutDescriptor();
        d.setLabel(desc.label());
        d.setEntries(entries);
        WGPUBindGroupLayout layout = new WGPUBindGroupLayout();
        device.createBindGroupLayout(d, layout);
        return new DawnBindGroupLayout(layout);
    }

    @Override public fge.webgpu.BindGroup createBindGroup(BindGroupDesc desc) {
        WGPUVectorBindGroupEntry entries = new WGPUVectorBindGroupEntry();
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
        }
        WGPUBindGroupDescriptor d = new WGPUBindGroupDescriptor();
        d.setLabel(desc.label());
        d.setLayout(((DawnBindGroupLayout) desc.layout()).layout);
        d.setEntries(entries);
        WGPUBindGroup group = new WGPUBindGroup();
        device.createBindGroup(d, group);
        return new DawnBindGroup(group);
    }

    @Override public fge.webgpu.RenderPipeline createRenderPipeline(RenderPipelineDesc desc) {
        WGPUVectorBindGroupLayout layouts = new WGPUVectorBindGroupLayout();
        for (fge.webgpu.BindGroupLayout l : desc.bindGroupLayouts()) layouts.push_back(((DawnBindGroupLayout) l).layout);
        WGPUPipelineLayoutDescriptor layoutDesc = new WGPUPipelineLayoutDescriptor();
        layoutDesc.setLabel(desc.label());
        layoutDesc.setBindGroupLayouts(layouts);
        WGPUPipelineLayout layout = new WGPUPipelineLayout();
        device.createPipelineLayout(layoutDesc, layout);

        WGPURenderPipelineDescriptor d = new WGPURenderPipelineDescriptor();
        d.setLabel(desc.label());
        d.setLayout(layout);
        WGPUVectorVertexBufferLayout buffers = new WGPUVectorVertexBufferLayout();
        // WhyNot: 属性の列をループの中の局所に捨てない — 頂点の buffer の形は列の中身を指すだけで、作り終わるまで生きている必要がある。
        java.util.List<WGPUVectorVertexAttribute> keep = new java.util.ArrayList<>();
        for (RenderPipelineDesc.VertexBuffer vb : desc.vertexBuffers()) {
            WGPUVectorVertexAttribute attributes = new WGPUVectorVertexAttribute();
            for (RenderPipelineDesc.Attribute at : vb.attributes) {
                WGPUVertexAttribute attribute = new WGPUVertexAttribute();
                attribute.setFormat(vertexFormat(at.format));
                attribute.setOffset(at.offset);
                attribute.setShaderLocation(at.location);
                attributes.push_back(attribute);
            }
            keep.add(attributes);
            WGPUVertexBufferLayout bl = new WGPUVertexBufferLayout();
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
        d.getPrimitive().setTopology(switch (desc.topology()) {
            case TRIANGLE_LIST -> WGPUPrimitiveTopology.TriangleList;
            case TRIANGLE_STRIP -> WGPUPrimitiveTopology.TriangleStrip;
            case LINE_LIST -> WGPUPrimitiveTopology.LineList;
            case LINE_STRIP -> WGPUPrimitiveTopology.LineStrip;
            case POINT_LIST -> WGPUPrimitiveTopology.PointList;
        });
        d.getPrimitive().setStripIndexFormat(WGPUIndexFormat.Undefined);
        d.getPrimitive().setFrontFace(desc.frontFace() == FrontFace.CCW ? WGPUFrontFace.CCW : WGPUFrontFace.CW);
        d.getPrimitive().setCullMode(switch (desc.cullMode()) {
            case NONE -> WGPUCullMode.None;
            case FRONT -> WGPUCullMode.Front;
            case BACK -> WGPUCullMode.Back;
        });

        WGPUFragmentState fragment = new WGPUFragmentState();
        WGPUVectorColorTargetState targets = new WGPUVectorColorTargetState();
        java.util.List<WGPUBlendState> blends = new java.util.ArrayList<>();
        if (desc.fragmentModule() != null) {
            for (RenderPipelineDesc.ColorTarget ct : desc.colorTargets()) {
                WGPUColorTargetState target = new WGPUColorTargetState();
                target.setNextInChain(WGPUChainedStruct.NULL);
                target.setFormat(textureFormat(ct.format));
                target.setWriteMask(WGPUColorWriteMask.All);
                if (ct.color != null) {
                    WGPUBlendState blend = new WGPUBlendState();
                    setBlend(blend.getColor(), ct.color);
                    setBlend(blend.getAlpha(), ct.alpha);
                    target.setBlend(blend);
                    blends.add(blend);
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

        WGPUDepthStencilState depth = null;
        if (desc.depthFormat() != null) {
            depth = new WGPUDepthStencilState();
            depth.setNextInChain(WGPUChainedStruct.NULL);
            depth.setFormat(textureFormat(desc.depthFormat()));
            depth.setDepthWriteEnabled(desc.depthWrite() ? WGPUOptionalBool.True : WGPUOptionalBool.False);
            depth.setDepthCompare(compare(desc.depthCompare()));
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
        keep.clear();
        blends.clear();
        return new DawnRenderPipeline(pipeline);
    }

    private static void setBlend(WGPUBlendComponent c, RenderPipelineDesc.BlendComponent b) {
        c.setSrcFactor(blendFactor(b.src));
        c.setDstFactor(blendFactor(b.dst));
        c.setOperation(switch (b.operation) {
            case ADD -> WGPUBlendOperation.Add;
            case SUBTRACT -> WGPUBlendOperation.Subtract;
            case REVERSE_SUBTRACT -> WGPUBlendOperation.ReverseSubtract;
            case MIN -> WGPUBlendOperation.Min;
            case MAX -> WGPUBlendOperation.Max;
        });
    }

    private static void setStencilFace(WGPUStencilFaceState face, RenderPipelineDesc.Stencil s) {
        face.setCompare(s == null ? WGPUCompareFunction.Always : compare(s.compare));
        face.setFailOp(s == null ? WGPUStencilOperation.Keep : stencilOp(s.failOp));
        face.setDepthFailOp(s == null ? WGPUStencilOperation.Keep : stencilOp(s.depthFailOp));
        face.setPassOp(s == null ? WGPUStencilOperation.Keep : stencilOp(s.passOp));
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
        WGPUCommandEncoder encoder = new WGPUCommandEncoder();
        device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, encoder);
        return new DawnCommandEncoder(encoder, this);
    }

    // 1 コマに何度も通るので、descriptor は device ごとに 1 組を使い回す（全部の欄を毎回書き直す）。
    private final WGPURenderPassDescriptor passDesc = new WGPURenderPassDescriptor();
    private final WGPURenderPassColorAttachment[] colorScratch = {
        new WGPURenderPassColorAttachment(), new WGPURenderPassColorAttachment(),
        new WGPURenderPassColorAttachment(), new WGPURenderPassColorAttachment()};
    private final WGPUVectorRenderPassColorAttachment colorVector = new WGPUVectorRenderPassColorAttachment();
    private final WGPURenderPassDepthStencilAttachment depthScratch = new WGPURenderPassDepthStencilAttachment();

    fge.webgpu.RenderPass beginRenderPass(WGPUCommandEncoder encoder, RenderPassDesc desc) {
        java.util.List<RenderPassDesc.ColorAttachment> colors = desc.colors();
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
        if (desc.timestamps() != null) {
            // WhyNot: 欄に 1 つ持たない — jWebGPU はこの型を obtain（共有の 1 個）でしか作らせない。
            WGPUPassTimestampWrites timestampScratch = WGPUPassTimestampWrites.obtain();
            timestampScratch.setQuerySet(((DawnQuerySet) desc.timestamps()).querySet);
            timestampScratch.setBeginningOfPassWriteIndex(desc.timestampBegin());
            timestampScratch.setEndOfPassWriteIndex(desc.timestampEnd());
            passDesc.setTimestampWrites(timestampScratch);
        } else passDesc.setTimestampWrites(WGPUPassTimestampWrites.NULL);
        WGPURenderPassEncoder pass = new WGPURenderPassEncoder();
        encoder.beginRenderPass(passDesc, pass);
        return new DawnRenderPass(pass);
    }

    // ── queue ──

    @Override public void writeBuffer(fge.webgpu.Buffer buffer, long offset, ByteBuffer data, int dataOffset, int size) {
        // WhyNot: data の position で範囲を渡さない — jWebGPU は ByteBuffer の先頭の番地をそのまま使い、position を見ない。
        ByteBuffer from = dataOffset == 0 ? data : data.slice(dataOffset, size);
        queue.writeBuffer(((DawnBuffer) buffer).buffer, Math.toIntExact(offset), from, size);
    }

    @Override public void writeTexture(fge.webgpu.Texture texture, int mip, int x, int y, int width, int height,
                                       ByteBuffer data, int dataOffset, int bytesPerRow) {
        int size = bytesPerRow * height;
        ByteBuffer from = dataOffset == 0 ? data : data.slice(dataOffset, Math.min(size, data.capacity() - dataOffset));
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
        queue.writeTexture(dst, from, Math.min(size, from.capacity()), layout, extent);
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
            idleSrc = ((DawnBuffer) createBuffer("fge idle src", 16, BufferUsage.COPY_SRC | BufferUsage.COPY_DST)).buffer;
            idleDst = ((DawnBuffer) createBuffer("fge idle dst", 16, BufferUsage.COPY_DST | BufferUsage.MAP_READ)).buffer;
        }
        fge.webgpu.CommandEncoder encoder = createCommandEncoder("fge idle");
        ((DawnCommandEncoder) encoder).encoder.copyBufferToBuffer(idleSrc, 0, idleDst, 0, 16);
        submit(encoder.finish());
        readBuffer(new DawnBuffer(idleDst, 16), 0, 16, ByteBuffer.allocateDirect(16));
    }

    // ── ウィンドウ（macOS） ──

    /** GLFW のウィンドウの NSWindow（glfwGetCocoaWindow の値）に描き先を作る。Dawn がウィンドウの view に CAMetalLayer を付ける。 */
    public fge.webgpu.Surface createMacSurface(long nsWindow) {
        NativeObject handle = NativeObject.native_new().native_setAddress(nsWindow);
        WGPUSurface surface = instance.createMacSurface(handle);
        if (surface == null) throw new IllegalStateException("surface を作れない");
        return new DawnSurface(surface, adapter, device);
    }

    // ── 形の対応 ──

    static WGPUTextureFormat textureFormat(TextureFormat f) {
        return switch (f) {
            case R8_UNORM -> WGPUTextureFormat.R8Unorm;
            case RGBA8_UNORM -> WGPUTextureFormat.RGBA8Unorm;
            case RGBA8_UNORM_SRGB -> WGPUTextureFormat.RGBA8UnormSrgb;
            case BGRA8_UNORM -> WGPUTextureFormat.BGRA8Unorm;
            case BGRA8_UNORM_SRGB -> WGPUTextureFormat.BGRA8UnormSrgb;
            case RGBA16_FLOAT -> WGPUTextureFormat.RGBA16Float;
            case RGBA32_FLOAT -> WGPUTextureFormat.RGBA32Float;
            case DEPTH24_PLUS -> WGPUTextureFormat.Depth24Plus;
            case DEPTH24_PLUS_STENCIL8 -> WGPUTextureFormat.Depth24PlusStencil8;
            case DEPTH32_FLOAT -> WGPUTextureFormat.Depth32Float;
            case STENCIL8 -> WGPUTextureFormat.Stencil8;
        };
    }

    /** Dawn の形をこちらの形へ。こちらに無い形は null。 */
    static TextureFormat fromTextureFormat(WGPUTextureFormat f) {
        for (TextureFormat t : TextureFormat.values()) if (textureFormat(t) == f) return t;
        return null;
    }

    private static WGPUVertexFormat vertexFormat(VertexFormat f) {
        return switch (f) {
            case FLOAT32 -> WGPUVertexFormat.Float32;
            case FLOAT32X2 -> WGPUVertexFormat.Float32x2;
            case FLOAT32X3 -> WGPUVertexFormat.Float32x3;
            case FLOAT32X4 -> WGPUVertexFormat.Float32x4;
            case UINT32 -> WGPUVertexFormat.Uint32;
            case UINT32X2 -> WGPUVertexFormat.Uint32x2;
            case UINT32X4 -> WGPUVertexFormat.Uint32x4;
            case UNORM8X4 -> WGPUVertexFormat.Unorm8x4;
        };
    }

    private static WGPUBlendFactor blendFactor(BlendFactor f) {
        return switch (f) {
            case ZERO -> WGPUBlendFactor.Zero;
            case ONE -> WGPUBlendFactor.One;
            case SRC -> WGPUBlendFactor.Src;
            case ONE_MINUS_SRC -> WGPUBlendFactor.OneMinusSrc;
            case SRC_ALPHA -> WGPUBlendFactor.SrcAlpha;
            case ONE_MINUS_SRC_ALPHA -> WGPUBlendFactor.OneMinusSrcAlpha;
            case DST -> WGPUBlendFactor.Dst;
            case ONE_MINUS_DST -> WGPUBlendFactor.OneMinusDst;
            case DST_ALPHA -> WGPUBlendFactor.DstAlpha;
            case ONE_MINUS_DST_ALPHA -> WGPUBlendFactor.OneMinusDstAlpha;
            case CONSTANT -> WGPUBlendFactor.Constant;
            case ONE_MINUS_CONSTANT -> WGPUBlendFactor.OneMinusConstant;
        };
    }

    private static WGPUCompareFunction compare(CompareFunction f) {
        return switch (f) {
            case NEVER -> WGPUCompareFunction.Never;
            case LESS -> WGPUCompareFunction.Less;
            case EQUAL -> WGPUCompareFunction.Equal;
            case LESS_EQUAL -> WGPUCompareFunction.LessEqual;
            case GREATER -> WGPUCompareFunction.Greater;
            case NOT_EQUAL -> WGPUCompareFunction.NotEqual;
            case GREATER_EQUAL -> WGPUCompareFunction.GreaterEqual;
            case ALWAYS -> WGPUCompareFunction.Always;
        };
    }

    private static WGPUStencilOperation stencilOp(StencilOperation o) {
        return switch (o) {
            case KEEP -> WGPUStencilOperation.Keep;
            case ZERO -> WGPUStencilOperation.Zero;
            case REPLACE -> WGPUStencilOperation.Replace;
            case INVERT -> WGPUStencilOperation.Invert;
            case INCREMENT_CLAMP -> WGPUStencilOperation.IncrementClamp;
            case DECREMENT_CLAMP -> WGPUStencilOperation.DecrementClamp;
            case INCREMENT_WRAP -> WGPUStencilOperation.IncrementWrap;
            case DECREMENT_WRAP -> WGPUStencilOperation.DecrementWrap;
        };
    }
}
