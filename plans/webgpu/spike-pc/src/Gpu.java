import com.github.xpenatan.webgpu.*;

/** 同期で device まで取る補助。Metal 指定。 */
public final class Gpu {
    public WGPUInstance instance;
    public WGPUAdapter adapter;
    public WGPUDevice device;
    public WGPUQueue queue;
    public String info = "";
    private final boolean[] adapterDone = {false}, deviceDone = {false};
    private WGPURequestAdapterCallback acb;
    private WGPURequestDeviceCallback dcb;
    private WGPUUncapturedErrorCallback ecb;

    public static Gpu init(JWebGPUBackend backend) {
        Gpu g = new Gpu();
        boolean[] ok = {false};
        Throwable[] err = {null};
        JWebGPULoader.init(backend, (success, e) -> { System.out.println("loader cb "+success+" "+e); if(e!=null) e.printStackTrace(); ok[0] = success; err[0] = e; });
        if (!ok[0]) throw new RuntimeException("loader init failed", err[0]);
        WGPUInstanceDescriptor d = new WGPUInstanceDescriptor();
        WGPUBackendType bt = backend == JWebGPUBackend.WGPU ? WGPUBackendType.Metal : WGPUBackendType.Undefined;
        g.instance = WGPU.setupInstance(d);
        if (!g.instance.isValid()) throw new RuntimeException("instance invalid");
        WGPURequestAdapterOptions op = WGPURequestAdapterOptions.obtain();
        op.setPowerPreference(WGPUPowerPreference.HighPerformance);
        if (backend == JWebGPUBackend.WGPU) op.setBackendType(bt);
        g.acb = new WGPURequestAdapterCallback() {
            @Override protected void onCallback(WGPURequestAdapterStatus status, WGPUAdapter adapter, String message) {
                System.out.println("adapter status " + status + " " + message);
                if (status == WGPURequestAdapterStatus.Success) g.adapter = adapter;
                g.adapterDone[0] = true;
            }
        };
        g.instance.requestAdapter(op, WGPUCallbackMode.AllowProcessEvents, g.acb);
        pump(g, g.adapterDone);
        if (g.adapter == null) throw new RuntimeException("no adapter");
        WGPUAdapterInfo ai = WGPUAdapterInfo.obtain();
        if (g.adapter.getInfo(ai)) {
            g.info = "backend=" + ai.getBackendType() + " type=" + ai.getAdapterType() + " vendor=" + ai.getVendor().c_str()
                + " arch=" + ai.getArchitecture().c_str() + " device=" + ai.getDevice().c_str() + " desc=" + ai.getDescription().c_str();
            System.out.println("ADAPTER: " + g.info);
        }
        WGPUDeviceDescriptor dd = WGPUDeviceDescriptor.obtain();
        dd.setLabel("spike device");
        g.dcb = new WGPURequestDeviceCallback() {
            @Override protected void onCallback(WGPURequestDeviceStatus status, WGPUDevice device, String message) {
                System.out.println("device status " + status + " " + message);
                if (status == WGPURequestDeviceStatus.Success) { g.device = device; g.queue = device.getQueue(); }
                g.deviceDone[0] = true;
            }
        };
        g.ecb = new WGPUUncapturedErrorCallback() {
            @Override protected void onCallback(WGPUErrorType t, String m) { System.err.println("GPU ERROR " + t + ": " + m); }
        };
        g.adapter.requestDevice(dd, WGPUCallbackMode.AllowProcessEvents, g.dcb, g.ecb);
        pump(g, g.deviceDone);
        if (g.device == null) throw new RuntimeException("no device");
        return g;
    }

    static void pump(Gpu g, boolean[] flag) {
        long t0 = System.nanoTime();
        while (!flag[0]) {
            g.instance.processEvents();
            try { Thread.sleep(1); } catch (InterruptedException e) {}
            if (System.nanoTime() - t0 > 10_000_000_000L) throw new RuntimeException("timeout");
        }
    }

    public WGPUShaderModule shader(String wgsl) {
        WGPUShaderModuleDescriptor sd = WGPUShaderModuleDescriptor.obtain();
        WGPUShaderSourceWGSL w = WGPUShaderSourceWGSL.obtain();
        w.getChain().setNext(WGPUChainedStruct.NULL);
        w.getChain().setSType(WGPUSType.ShaderSourceWGSL);
        w.setCode(wgsl);
        sd.setNextInChain(w.getChain());
        WGPUShaderModule m = WGPUShaderModule.obtain();
        device.createShaderModule(sd, m);
        return m;
    }

    /** layout が null なら auto。 */
    public WGPURenderPipeline pipeline(WGPUShaderModule m, WGPUTextureFormat fmt, WGPUPipelineLayout layout, boolean blend) {
        WGPURenderPipelineDescriptor pd = WGPURenderPipelineDescriptor.obtain();
        pd.getVertex().setBuffers(WGPUVectorVertexBufferLayout.NULL);
        pd.getVertex().setModule(m);
        pd.getVertex().setEntryPoint("vs_main");
        pd.getVertex().setConstants(WGPUVectorConstantEntry.NULL);
        pd.getPrimitive().setTopology(WGPUPrimitiveTopology.TriangleList);
        pd.getPrimitive().setStripIndexFormat(WGPUIndexFormat.Undefined);
        pd.getPrimitive().setFrontFace(WGPUFrontFace.CCW);
        pd.getPrimitive().setCullMode(WGPUCullMode.None);
        WGPUFragmentState fs = WGPUFragmentState.obtain();
        fs.setNextInChain(WGPUChainedStruct.NULL);
        fs.setModule(m);
        fs.setEntryPoint("fs_main");
        fs.setConstants(WGPUVectorConstantEntry.NULL);
        WGPUColorTargetState ct = WGPUColorTargetState.obtain();
        ct.setFormat(fmt);
        ct.setWriteMask(WGPUColorWriteMask.All);
        if (blend) {
            WGPUBlendState bs = WGPUBlendState.obtain();
            bs.getColor().setSrcFactor(WGPUBlendFactor.SrcAlpha);
            bs.getColor().setDstFactor(WGPUBlendFactor.OneMinusSrcAlpha);
            bs.getColor().setOperation(WGPUBlendOperation.Add);
            bs.getAlpha().setSrcFactor(WGPUBlendFactor.One);
            bs.getAlpha().setDstFactor(WGPUBlendFactor.Zero);
            bs.getAlpha().setOperation(WGPUBlendOperation.Add);
            ct.setBlend(bs);
        }
        WGPUVectorColorTargetState cts = WGPUVectorColorTargetState.obtain();
        cts.push_back(ct);
        fs.setTargets(cts);
        pd.setFragment(fs);
        pd.setDepthStencil(WGPUDepthStencilState.NULL);
        pd.getMultisample().setCount(1);
        pd.getMultisample().setMask(-1);
        pd.getMultisample().setAlphaToCoverageEnabled(false);
        pd.setLayout(layout == null ? WGPUPipelineLayout.NULL : layout);
        WGPURenderPipeline p = new WGPURenderPipeline();
        device.createRenderPipeline(pd, p);
        return p;
    }

    public WGPURenderPassEncoder beginPass(WGPUCommandEncoder enc, WGPUTextureView view, float r, float g, float b) {
        WGPURenderPassColorAttachment ca = WGPURenderPassColorAttachment.obtain();
        ca.setView(view);
        ca.setResolveTarget(WGPUTextureView.NULL);
        ca.setLoadOp(WGPULoadOp.Clear);
        ca.setStoreOp(WGPUStoreOp.Store);
        ca.getClearValue().setColor(r, g, b, 1f);
        WGPUVectorRenderPassColorAttachment v = WGPUVectorRenderPassColorAttachment.obtain();
        v.push_back(ca);
        WGPURenderPassDescriptor rd = WGPURenderPassDescriptor.obtain();
        rd.setColorAttachments(v);
        rd.setDepthStencilAttachment(WGPURenderPassDepthStencilAttachment.NULL);
        rd.setTimestampWrites(WGPUPassTimestampWrites.NULL);
        WGPURenderPassEncoder pass = WGPURenderPassEncoder.obtain();
        enc.beginRenderPass(rd, pass);
        return pass;
    }

    public void submit(WGPUCommandEncoder enc) {
        WGPUCommandBuffer cb = WGPUCommandBuffer.obtain();
        enc.finish(WGPUCommandBufferDescriptor.NULL, cb);
        enc.release();
        WGPUVectorCommandBuffer v = WGPUVectorCommandBuffer.obtain();
        v.push_back(cb);
        queue.submit(v);
        cb.release();
    }

    public WGPUBuffer buffer(long size, WGPUBufferUsage usage) {
        WGPUBufferDescriptor bd = WGPUBufferDescriptor.obtain();
        bd.setSize(size);
        bd.setUsage(usage);
        bd.setMappedAtCreation(false);
        return device.createBuffer(bd);
    }

    private WGPUBuffer syncSrc, syncDst;
    /** 提出した仕事が終わるまで待つ（4 バイトの写しを map して待つ）。 */
    public void waitIdle() {
        if (syncSrc == null) {
            syncSrc = buffer(16, WGPUBufferUsage.CopySrc.or(WGPUBufferUsage.CopyDst));
            syncDst = buffer(16, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        }
        WGPUCommandEncoder enc = new WGPUCommandEncoder();
        device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
        enc.copyBufferToBuffer(syncSrc, 0, syncDst, 0, 16);
        submit(enc);
        readMapped(syncDst, 16);
    }

    /** MapRead のバッファを map して direct ByteBuffer へ写す。 */
    public java.nio.ByteBuffer readMapped(WGPUBuffer b, int size) {
        boolean[] done = {false};
        java.nio.ByteBuffer out = java.nio.ByteBuffer.allocateDirect(size).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        WGPUBufferMapCallback cb = new WGPUBufferMapCallback() {
            @Override protected void onCallback(WGPUMapAsyncStatus st, String m) {
                if (st == WGPUMapAsyncStatus.Success) { b.getConstMappedRange(0, size, out); b.unmap(); }
                else System.err.println("map failed " + st + " " + m);
                done[0] = true;
            }
        };
        b.mapAsync(WGPUMapMode.Read, 0, size, WGPUCallbackMode.AllowProcessEvents, cb);
        pump(this, done);
        cb.dispose();
        return out;
    }
}
