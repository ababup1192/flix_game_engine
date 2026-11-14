package spike.wgpu;

import com.github.xpenatan.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Flix から持つための薄い口。jWebGPU の物は外に出さず、下の小さな型（WgDevice・WgBuffer・WgPipeline・WgTexture）に包んで返す。
 * 呼ぶのは全部同じスレッドから（Dawn の物はスレッドをまたいで使わない）。
 */
public final class Wg {
    private Wg() {}

    private static volatile boolean flag;
    private static volatile int errors;
    private static WGPUAdapter gotAdapter;
    private static WGPUDevice gotDevice;

    /** Dawn の device を開く。nativeDir が空でなければ、ネイティブをその下に書き出す。失敗は例外。 */
    public static WgDevice open(String nativeDir) {
        String saved = System.getProperty("java.io.tmpdir");
        boolean[] ok = {false};
        if (!nativeDir.isEmpty()) { new java.io.File(nativeDir).mkdirs(); System.setProperty("java.io.tmpdir", nativeDir); }
        try { JWebGPULoader.init(JWebGPUBackend.DAWN, (s, e) -> ok[0] = s); }
        finally { System.setProperty("java.io.tmpdir", saved); }
        if (!ok[0]) throw new IllegalStateException("jWebGPU natives failed to load");
        WGPUInstance inst = WGPU.setupInstance(new WGPUInstanceDescriptor());
        WGPURequestAdapterOptions op = WGPURequestAdapterOptions.obtain();
        op.setPowerPreference(WGPUPowerPreference.HighPerformance);
        flag = false;
        WGPURequestAdapterCallback acb = new WGPURequestAdapterCallback() {
            @Override protected void onCallback(WGPURequestAdapterStatus st, WGPUAdapter a, String m) { if (st == WGPURequestAdapterStatus.Success) gotAdapter = a; flag = true; }
        };
        inst.requestAdapter(op, WGPUCallbackMode.AllowProcessEvents, acb);
        pump(inst);
        if (gotAdapter == null) throw new IllegalStateException("no adapter");
        flag = false;
        WGPURequestDeviceCallback dcb = new WGPURequestDeviceCallback() {
            @Override protected void onCallback(WGPURequestDeviceStatus st, WGPUDevice d, String m) { if (st == WGPURequestDeviceStatus.Success) gotDevice = d; flag = true; }
        };
        WGPUUncapturedErrorCallback ecb = new WGPUUncapturedErrorCallback() {
            @Override protected void onCallback(WGPUErrorType t, String m) { errors++; System.err.println("GPU ERROR " + t + ": " + m); }
        };
        gotAdapter.requestDevice(WGPUDeviceDescriptor.obtain(), WGPUCallbackMode.AllowProcessEvents, dcb, ecb);
        pump(inst);
        if (gotDevice == null) throw new IllegalStateException("no device");
        return new WgDevice(inst, gotAdapter, gotDevice);
    }

    public static int errorCount() { return errors; }

    private static void pump(WGPUInstance inst) {
        long t0 = System.nanoTime();
        while (!flag) {
            inst.processEvents();
            Thread.onSpinWait();
            if (System.nanoTime() - t0 > 10_000_000_000L) throw new IllegalStateException("timeout");
        }
    }

    public static WgBuffer createBuffer(WgDevice d, long size) {
        WGPUBufferDescriptor bd = WGPUBufferDescriptor.obtain();
        bd.setSize(size);
        bd.setUsage(WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopyDst));
        bd.setMappedAtCreation(false);
        return new WgBuffer(d.device.createBuffer(bd), size);
    }

    /** 単色の三角形を描く pipeline（RGBA8Unorm へ）。 */
    public static WgPipeline createTrianglePipeline(WgDevice d, String label, double r, double g, double b) {
        String wgsl = String.format(java.util.Locale.ROOT, """
            @vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
                var p = vec2f(0.0, 0.5);
                if (i == 0u) { p = vec2f(-0.5, -0.5); } else if (i == 1u) { p = vec2f(0.5, -0.5); }
                return vec4f(p, 0.0, 1.0);
            }
            @fragment fn fs_main() -> @location(0) vec4f { return vec4f(%f, %f, %f, 1.0); }
            """, r, g, b);
        WGPUShaderModuleDescriptor sd = WGPUShaderModuleDescriptor.obtain();
        WGPUShaderSourceWGSL w = WGPUShaderSourceWGSL.obtain();
        w.getChain().setNext(WGPUChainedStruct.NULL);
        w.getChain().setSType(WGPUSType.ShaderSourceWGSL);
        w.setCode(wgsl);
        sd.setNextInChain(w.getChain());
        WGPUShaderModule m = new WGPUShaderModule();
        d.device.createShaderModule(sd, m);
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
        ct.setFormat(WGPUTextureFormat.RGBA8Unorm);
        ct.setWriteMask(WGPUColorWriteMask.All);
        WGPUVectorColorTargetState cts = WGPUVectorColorTargetState.obtain();
        cts.push_back(ct);
        fs.setTargets(cts);
        pd.setFragment(fs);
        pd.setDepthStencil(WGPUDepthStencilState.NULL);
        pd.getMultisample().setCount(1);
        pd.getMultisample().setMask(-1);
        pd.getMultisample().setAlphaToCoverageEnabled(false);
        pd.setLayout(WGPUPipelineLayout.NULL);
        WGPURenderPipeline p = new WGPURenderPipeline();
        d.device.createRenderPipeline(pd, p);
        return new WgPipeline(p, label);
    }

    public static WgTexture createTarget(WgDevice d, int w, int h) {
        WGPUTextureDescriptor td = WGPUTextureDescriptor.obtain();
        td.setUsage(WGPUTextureUsage.RenderAttachment.or(WGPUTextureUsage.CopySrc));
        td.setDimension(WGPUTextureDimension._2D);
        td.getSize().setWidth(w); td.getSize().setHeight(h); td.getSize().setDepthOrArrayLayers(1);
        td.setFormat(WGPUTextureFormat.RGBA8Unorm);
        td.setMipLevelCount(1); td.setSampleCount(1);
        WGPUTexture t = new WGPUTexture();
        d.device.createTexture(td, t);
        return new WgTexture(t, w, h);
    }

    /** 灰色で消して p の三角形を描き、(x, y) の画素を 0xRRGGBBAA で返す。 */
    public static long drawAndReadPixel(WgDevice d, WgTexture t, WgPipeline p, int x, int y) {
        WGPUTextureView view = new WGPUTextureView();
        t.t.createView(WGPUTextureViewDescriptor.NULL, view);
        WGPUCommandEncoder enc = new WGPUCommandEncoder();
        d.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
        WGPURenderPassColorAttachment ca = WGPURenderPassColorAttachment.obtain();
        ca.setView(view);
        ca.setResolveTarget(WGPUTextureView.NULL);
        ca.setLoadOp(WGPULoadOp.Clear);
        ca.setStoreOp(WGPUStoreOp.Store);
        ca.getClearValue().setColor(0.2f, 0.2f, 0.2f, 1f);
        WGPUVectorRenderPassColorAttachment v = WGPUVectorRenderPassColorAttachment.obtain();
        v.push_back(ca);
        WGPURenderPassDescriptor rd = WGPURenderPassDescriptor.obtain();
        rd.setColorAttachments(v);
        rd.setDepthStencilAttachment(WGPURenderPassDepthStencilAttachment.NULL);
        rd.setTimestampWrites(WGPUPassTimestampWrites.NULL);
        WGPURenderPassEncoder pass = new WGPURenderPassEncoder();
        enc.beginRenderPass(rd, pass);
        pass.setPipeline(p.p);
        pass.draw(3, 1, 0, 0);
        pass.end(); pass.release();
        int bpr = (t.w * 4 + 255) / 256 * 256;
        WGPUBufferDescriptor bd = WGPUBufferDescriptor.obtain();
        bd.setSize((long) bpr * t.h);
        bd.setUsage(WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        bd.setMappedAtCreation(false);
        WGPUBuffer out = d.device.createBuffer(bd);
        WGPUTexelCopyTextureInfo src = WGPUTexelCopyTextureInfo.obtain();
        src.setTexture(t.t); src.setMipLevel(0); src.setAspect(WGPUTextureAspect.All);
        src.getOrigin().set(0, 0, 0);
        WGPUTexelCopyBufferInfo dst = WGPUTexelCopyBufferInfo.obtain();
        dst.setBuffer(out);
        dst.getLayout().setOffset(0); dst.getLayout().setBytesPerRow(bpr); dst.getLayout().setRowsPerImage(t.h);
        WGPUExtent3D ext = WGPUExtent3D.obtain();
        ext.setWidth(t.w); ext.setHeight(t.h); ext.setDepthOrArrayLayers(1);
        enc.copyTextureToBuffer(src, dst, ext);
        WGPUCommandBuffer cb = new WGPUCommandBuffer();
        enc.finish(WGPUCommandBufferDescriptor.NULL, cb);
        enc.release();
        d.queue.submit(cb);
        cb.release();
        int size = bpr * t.h;
        ByteBuffer px = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN);
        flag = false;
        WGPUBufferMapCallback mcb = new WGPUBufferMapCallback() {
            @Override protected void onCallback(WGPUMapAsyncStatus st, String m) {
                if (st == WGPUMapAsyncStatus.Success) { out.getConstMappedRange(0, size, px); out.unmap(); }
                flag = true;
            }
        };
        out.mapAsync(WGPUMapMode.Read, 0, size, WGPUCallbackMode.AllowProcessEvents, mcb);
        pump(d.instance);
        out.release();
        view.release();
        int o = y * bpr + x * 4;
        return ((long) (px.get(o) & 255) << 24) | ((px.get(o + 1) & 255) << 16) | ((px.get(o + 2) & 255) << 8) | (px.get(o + 3) & 255);
    }
}
