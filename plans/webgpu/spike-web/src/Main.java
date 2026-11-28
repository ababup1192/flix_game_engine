import java.util.Arrays;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.browser.Navigator;
import org.teavm.jso.core.JSArray;
import org.teavm.jso.typedarrays.ArrayBuffer;
import org.teavm.jso.typedarrays.Float32Array;
import org.teavm.jso.typedarrays.Uint32Array;
import org.teavm.jso.typedarrays.Uint8Array;
import org.teavm.jso.webgpu.*;
import org.teavm.jso.webgpu.GPUDescriptor.*;

public class Main {
    static GPUDevice device;
    static GPUQueue queue;
    static long calls;
    static final String FMT = "rgba8unorm";
    static final int SZ = 512;

    @JSBody(script = "return performance.now();") static native double now();
    @JSBody(params = {"s"}, script = "(window.__log = window.__log || []).push(s);") static native void log(String s);
    @JSBody(params = {"s"}, script = "window.__result = JSON.parse(s); document.title = 'done';") static native void report(String s);
    @JSBody(params = {"s"}, script = "window.__result = {error: s}; document.title = 'error';") static native void fail(String s);
    @JSBody(params = {"a"}, script = "var i = a.info || {}; return JSON.stringify({vendor: i.vendor, architecture: i.architecture, description: i.description});")
    static native String adapterInfo(JSObject a);
    @JSBody(params = {"id"}, script = "return document.getElementById(id).getContext('webgpu');") static native GPUCanvasContext canvasCtx(String id);

    // ---- W: engine と同じ流儀（fgeGl / fgeU の表を JS 側に置き、Java へは int だけ）----
    @JSBody(params = {"sz"}, script = "fgeSetupGl(sz);") static native void glSetup(int sz);
    @JSBody(script = "fgeGlBegin();") static native void glBegin();
    @JSBody(params = {"l", "t", "v"}, script = "fgeGl.uniformMatrix4fv(fgeU[l], t, v);") static native void glUniformMatrix4fv(int l, boolean t, JSObject v);
    @JSBody(params = {"m", "f", "c"}, script = "fgeGl.drawArrays(m, f, c);") static native void glDrawArrays(int m, int f, int c);
    @JSBody(params = {"l", "t", "v", "o"}, script = "fgeGl.uniformMatrix4fv(fgeU[l], t, v, o, 16);") static native void glUniformMatrix4fvAt(int l, boolean t, JSObject v, int o);
    @JSBody(script = "fgeGl.finish();") static native void glFinish();
    @JSBody(script = "return fgeGlCoverage();") static native int glCoverage();
    @JSBody(script = "return 1;") static native int noop();

    static void matrices(float[] out, int stride, int n, double t) {
        int cols = (int) Math.ceil(Math.sqrt(n));
        float s = 1.0f / cols;
        for (int i = 0; i < n; i++) {
            int gx = i % cols, gy = i / cols;
            float cx = (float) ((gx + 0.5) / cols * 2 - 1 + 0.3 / cols * Math.sin(t + i));
            float cy = (float) ((gy + 0.5) / cols * 2 - 1);
            double ang = t * 2 + i * 0.01;
            float c = (float) Math.cos(ang) * s, sn = (float) Math.sin(ang) * s;
            int o = i * stride;
            out[o] = c; out[o + 1] = sn; out[o + 2] = 0; out[o + 3] = 0;
            out[o + 4] = -sn; out[o + 5] = c; out[o + 6] = 0; out[o + 7] = 0;
            out[o + 8] = 0; out[o + 9] = 0; out[o + 10] = 1; out[o + 11] = 0;
            out[o + 12] = cx; out[o + 13] = cy; out[o + 14] = 0; out[o + 15] = 1;
        }
    }

    static GPUShaderModule shader(String code) {
        ShaderModule d = GPUDescriptor.create();
        d.setCode(code);
        return device.createShaderModule(d);
    }

    static GPUPipeline.Render pipeline(GPUShaderModule m, GPUPipeline.Layout layout) {
        RenderPipeline d = GPUDescriptor.create();
        if (layout == null) d.setLayout("auto"); else d.setLayout(layout);
        VertexState v = GPUDescriptor.create();
        v.setModule(m); v.setEntryPoint("vs");
        d.setVertex(v);
        FragmentState f = GPUDescriptor.create();
        f.setModule(m); f.setEntryPoint("fs");
        ColorTargetState t = GPUDescriptor.create();
        t.setFormat(FMT);
        f.setTargets(new ColorTargetState[] {t});
        d.setFragment(f);
        return device.createRenderPipelineAsync(d).await();
    }

    static GPUTexture texture(int w, int h, int usage) {
        Texture d = GPUDescriptor.create();
        Extent3D e = GPUDescriptor.create();
        e.setWidth(w); e.setHeight(h); e.setDepthOrArrayLayers(1);
        d.setSize(e); d.setFormat(FMT); d.setUsage(usage);
        return device.createTexture(d);
    }

    static GPUBuffer buffer(double size, int usage) {
        Buffer d = GPUDescriptor.create();
        d.setSize(size); d.setUsage(usage);
        return device.createBuffer(d);
    }

    static GPURenderPassEncoder begin(GPUCommandEncoder enc, GPUTexture tex) {
        RenderPass rp = GPUDescriptor.create();
        RenderPassColorAttachment ca = GPUDescriptor.create();
        ca.setView(tex.createView());
        Color c = GPUDescriptor.create();
        c.setR(0); c.setG(0); c.setB(0); c.setA(1);
        ca.setClearValue(c);
        ca.setLoadOp("clear"); ca.setStoreOp("store");
        rp.setColorAttachments(new RenderPassColorAttachment[] {ca});
        return enc.beginRenderPass(rp);
    }

    static void submit(GPUCommandEncoder enc) {
        JSArray<GPUCommandEncoder.CommandBuffer> a = new JSArray<>();
        a.push(enc.finish());
        queue.submit(a);
    }

    /** texture（SZ 以下の w×h）を読み戻して、黒でない画素の数と指定画素の RGBA を返す。 */
    static Uint8Array readback(GPUTexture tex, int w, int h) {
        int bpr = ((w * 4 + 255) / 256) * 256;
        GPUBuffer buf = buffer((double) bpr * h, GPUBuffer.Usage.MAP_READ | GPUBuffer.Usage.COPY_DST);
        GPUCommandEncoder enc = device.createCommandEncoder();
        TexelCopyTextureInfo src = GPUDescriptor.create();
        src.setTexture(tex);
        TexelCopyBufferInfo dst = GPUDescriptor.create();
        dst.setBuffer(buf); dst.setBytesPerRow(bpr); dst.setRowsPerImage(h);
        Extent3D e = GPUDescriptor.create();
        e.setWidth(w); e.setHeight(h); e.setDepthOrArrayLayers(1);
        enc.copyTextureToBuffer(src, dst, e);
        submit(enc);
        buf.mapAsync(1).await();
        ArrayBuffer ab = buf.getMappedRange();
        // 取り出してから unmap する（unmap すると ArrayBuffer が空になる）
        Uint8Array copy = Uint8Array.create(Uint8Array.create(ab));
        buf.unmap();
        return copy;
    }

    static int[] px(Uint8Array u, int w, int x, int y) {
        int bpr = ((w * 4 + 255) / 256) * 256;
        int o = y * bpr + x * 4;
        return new int[] {u.get(o), u.get(o + 1), u.get(o + 2), u.get(o + 3)};
    }

    static String pxs(int[] p) { return "[" + p[0] + "," + p[1] + "," + p[2] + "," + p[3] + "]"; }

    static final String TRI = "@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {"
        + " var p = array<vec2f,3>(vec2f(0.0,0.7), vec2f(-0.8,-0.8), vec2f(0.8,-0.8)); return vec4f(p[i], 0.0, 1.0); }"
        + " @fragment fn fs() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }";

    static final String QUAD_COMMON = "var<private> P: array<vec2f,6> = array<vec2f,6>(vec2f(0,0), vec2f(1,0), vec2f(0,1), vec2f(0,1), vec2f(1,0), vec2f(1,1));"
        + " @fragment fn fs() -> @location(0) vec4f { return vec4f(1.0, 0.5, 0.2, 1.0); }";
    static final String QUAD_UNIFORM = "struct U { m: mat4x4f }  @group(0) @binding(0) var<uniform> u: U;"
        + " @vertex fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f { return u.m * vec4f(P[vi], 0.0, 1.0); } " + QUAD_COMMON;
    static final String QUAD_STORAGE = "@group(0) @binding(0) var<storage, read> ms: array<mat4x4f>;"
        + " @vertex fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> @builtin(position) vec4f { return ms[ii] * vec4f(P[vi], 0.0, 1.0); } " + QUAD_COMMON;

    static GPUBindGroup.Layout layout(String type, boolean dynamic) {
        BindGroupLayoutEntry e = GPUDescriptor.create();
        e.setBinding(0); e.setVisibility(1);
        BufferBindingLayout b = GPUDescriptor.create();
        b.setType(type); b.setHasDynamicOffset(dynamic);
        e.setBuffer(b);
        BindGroupLayout d = GPUDescriptor.create();
        d.setEntries(new BindGroupLayoutEntry[] {e});
        return device.createBindGroupLayout(d);
    }

    static GPUPipeline.Layout pipelineLayout(GPUBindGroup.Layout l) {
        PipelineLayout d = GPUDescriptor.create();
        d.setBindGroupLayouts(new GPUBindGroup.Layout[] {l});
        return device.createPipelineLayout(d);
    }

    static GPUBindGroup bindGroup(GPUBindGroup.Layout l, GPUBuffer buf, double size) {
        BufferBinding bb = GPUDescriptor.create();
        bb.setBuffer(buf); bb.setOffset(0); bb.setSize(size);
        BindGroupEntry e = GPUDescriptor.create();
        e.setBinding(0); e.setResource(bb);
        BindGroup d = GPUDescriptor.create();
        d.setLayout(l); d.setEntries(new BindGroupEntry[] {e});
        return device.createBindGroup(d);
    }

    static double median(double[] a) {
        double[] c = Arrays.copyOf(a, a.length);
        Arrays.sort(c);
        return c[c.length / 2];
    }

    static final int WARM = 30, FRAMES = 200;
    static GPUTexture target;

    interface Frame { void run(double t, double[] out); }  // out[0]=行列計算 out[1]=描き〜提出

    static String measure(String name, int n, Frame f, Runnable settle, java.util.function.IntSupplier coverage) {
        double[] mat = new double[FRAMES], enc = new double[FRAMES], tot = new double[FRAMES];
        double[] o = new double[2];
        for (int i = 0; i < WARM; i++) { f.run(i * 0.016, o); settle.run(); }
        calls = 0;
        for (int i = 0; i < FRAMES; i++) {
            f.run((WARM + i) * 0.016, o);
            mat[i] = o[0]; enc[i] = o[1]; tot[i] = o[0] + o[1];
            settle.run();
        }
        long callsPerFrame = calls / FRAMES;
        int cov = coverage.getAsInt();
        return "{\"name\":\"" + name + "\",\"n\":" + n + ",\"medianTotalMs\":" + median(tot) + ",\"medianMatrixMs\":" + median(mat)
            + ",\"medianEncodeSubmitMs\":" + median(enc) + ",\"minTotalMs\":" + min(tot) + ",\"p90TotalMs\":" + p90(tot)
            + ",\"jsCrossingsPerFrame\":" + callsPerFrame + ",\"nonBlackPixels\":" + cov + "}";
    }

    static double min(double[] a) { double m = a[0]; for (double v : a) if (v < m) m = v; return m; }
    static double p90(double[] a) { double[] c = Arrays.copyOf(a, a.length); Arrays.sort(c); return c[(int) (c.length * 0.9)]; }

    static int coverageGpu() {
        Uint8Array u = readback(target, SZ, SZ);
        int cnt = 0;
        int bpr = SZ * 4;
        for (int y = 0; y < SZ; y++) for (int x = 0; x < SZ; x++) {
            int o = y * bpr + x * 4;
            if (u.get(o) != 0 || u.get(o + 1) != 0 || u.get(o + 2) != 0) cnt++;
        }
        return cnt;
    }

    public static void main(String[] args) {
        StringBuilder sb = new StringBuilder("{");
        try {
            double t0 = now();
            sb.append("\"webgpuSupported\":").append(Navigator.isWebGPUSupported());
            // ---- 2/3: 起動（非同期）と三角形・読み戻し ----
            GPU gpu = Navigator.getGPU();
            GPUAdapter adapter = gpu.requestAdapter().await();
            if (adapter == null) { sb.append(",\"adapter\":null}"); report(sb.toString()); return; }
            sb.append(",\"adapter\":").append(adapterInfo(adapter));
            device = adapter.requestDevice().await();
            queue = device.getQueue();
            sb.append(",\"initMs\":").append(now() - t0);
            sb.append(",\"minUniformAlign\":").append(adapterLimit(adapter, "minUniformBufferOffsetAlignment"));

            double tp = now();
            GPUPipeline.Render tri = pipeline(shader(TRI), null);
            sb.append(",\"triPipelineAsyncMs\":").append(now() - tp);

            // canvas へ表示
            GPUCanvasContext ctx = canvasCtx("gpu-canvas");
            CanvasConfiguration cc = GPUDescriptor.create();
            cc.setDevice(device); cc.setFormat(FMT);
            ctx.configure(cc);
            GPUCommandEncoder e1 = device.createCommandEncoder();
            GPURenderPassEncoder p1 = begin(e1, ctx.getCurrentTexture());
            p1.setPipeline(tri); p1.draw(3); p1.end();
            submit(e1);

            // 読み戻し（offscreen 64x64）
            GPUTexture small = texture(64, 64, 0x10 | 0x01);
            GPUCommandEncoder e2 = device.createCommandEncoder();
            GPURenderPassEncoder p2 = begin(e2, small);
            p2.setPipeline(tri); p2.draw(3); p2.end();
            submit(e2);
            Uint8Array u = readback(small, 64, 64);
            sb.append(",\"readback\":{\"corner00\":").append(pxs(px(u, 64, 0, 0)))
              .append(",\"corner63_0\":").append(pxs(px(u, 64, 63, 0)))
              .append(",\"corner0_63\":").append(pxs(px(u, 64, 0, 63)))
              .append(",\"corner63_63\":").append(pxs(px(u, 64, 63, 63)))
              .append(",\"center\":").append(pxs(px(u, 64, 32, 32))).append("}");

            // ---- 4: 重さの比べ ----
            target = texture(SZ, SZ, 0x10 | 0x01);
            // 橋の値段の目安
            double c0 = now();
            int sink = 0;
            for (int i = 0; i < 100000; i++) sink += noop();
            double crossMs = now() - c0;
            float[] small16 = new float[16];
            c0 = now();
            for (int i = 0; i < 20000; i++) { Float32Array.copyFromJavaArray(small16); }
            double copyMs = now() - c0;
            sb.append(",\"micro\":{\"noopJsBody_100k_ms\":").append(crossMs).append(",\"copyFromJavaArray16_20k_ms\":").append(copyMs).append(",\"sink\":").append(sink).append("}");

            GPUBindGroup.Layout l1 = layout("uniform", true);
            GPUBindGroup.Layout l2 = layout("read-only-storage", false);
            double tq = now();
            GPUPipeline.Render pipe1 = pipeline(shader(QUAD_UNIFORM), pipelineLayout(l1));
            GPUPipeline.Render pipe2 = pipeline(shader(QUAD_STORAGE), pipelineLayout(l2));
            sb.append(",\"quadPipelinesAsyncMs\":").append(now() - tq);
            glSetup(SZ);
            sb.append(",\"results\":[");
            boolean first = true;
            int[] ns = {1000, 5000, 20000};
            for (int n : ns) {
                float[] w16 = new float[n * 16];
                float[] s16 = new float[16];
                // W
                String rw = measure("W", n, (t, out) -> {
                    double a = now();
                    matrices(w16, 16, n, t);
                    double b = now();
                    glBegin();
                    for (int i = 0; i < n; i++) {
                        System.arraycopy(w16, i * 16, s16, 0, 16);
                        glUniformMatrix4fv(0, false, Float32Array.copyFromJavaArray(s16));
                        glDrawArrays(4, 0, 6);
                    }
                    calls += 3L * n;
                    double c = now();
                    out[0] = b - a; out[1] = c - b;
                }, Main::glFinish, Main::glCoverage);
                sb.append(first ? "" : ",").append(rw); first = false;
                log(rw);

                // W2: WebGL2 でも全部の行列を 1 回だけ Float32Array にして srcOffset 付きで渡す（橋は 2 回/個）
                String rw2 = measure("W2", n, (t, out) -> {
                    double a = now();
                    matrices(w16, 16, n, t);
                    double b = now();
                    glBegin();
                    JSObject all = Float32Array.copyFromJavaArray(w16);
                    for (int i = 0; i < n; i++) {
                        glUniformMatrix4fvAt(0, false, all, i * 16);
                        glDrawArrays(4, 0, 6);
                    }
                    calls += 2L * n + 1;
                    double c = now();
                    out[0] = b - a; out[1] = c - b;
                }, Main::glFinish, Main::glCoverage);
                sb.append(",").append(rw2);
                log(rw2);

                // G1: dynamic offset
                float[] g1 = new float[n * 64];
                GPUBuffer ub = buffer((double) n * 256, GPUBuffer.Usage.UNIFORM | GPUBuffer.Usage.COPY_DST);
                GPUBindGroup bg1 = bindGroup(l1, ub, 64);
                Uint32Array offs = new Uint32Array(1);
                String r1 = measure("G1", n, (t, out) -> {
                    double a = now();
                    matrices(g1, 64, n, t);
                    double b = now();
                    queue.writeBuffer(ub, 0, Float32Array.copyFromJavaArray(g1));
                    GPUCommandEncoder en = device.createCommandEncoder();
                    GPURenderPassEncoder pass = begin(en, target);
                    pass.setPipeline(pipe1);
                    for (int i = 0; i < n; i++) {
                        offs.set(0, i * 256);
                        pass.setBindGroup(0, bg1, offs);
                        pass.draw(6);
                    }
                    pass.end();
                    submit(en);
                    calls += 3L * n + 12;
                    double c = now();
                    out[0] = b - a; out[1] = c - b;
                }, () -> queue.onSubmittedWorkDone().await(), Main::coverageGpu);
                sb.append(",").append(r1);
                log(r1);

                // G1b: 同じだが setBindGroup を @JSBody 1 本にして橋を減らす
                Uint32Array allOffs = new Uint32Array(n);
                for (int i = 0; i < n; i++) allOffs.set(i, i * 256);
                String r1b = measure("G1b", n, (t, out) -> {
                    double a = now();
                    matrices(g1, 64, n, t);
                    double b = now();
                    queue.writeBuffer(ub, 0, Float32Array.copyFromJavaArray(g1));
                    GPUCommandEncoder en = device.createCommandEncoder();
                    GPURenderPassEncoder pass = begin(en, target);
                    pass.setPipeline(pipe1);
                    for (int i = 0; i < n; i++) {
                        setBindGroupAt(pass, bg1, allOffs, i);
                        pass.draw(6);
                    }
                    pass.end();
                    submit(en);
                    calls += 2L * n + 12;
                    double c = now();
                    out[0] = b - a; out[1] = c - b;
                }, () -> queue.onSubmittedWorkDone().await(), Main::coverageGpu);
                sb.append(",").append(r1b);
                log(r1b);

                // G2: storage buffer + instancing
                float[] g2 = new float[n * 16];
                GPUBuffer sbuf = buffer((double) n * 64, GPUBuffer.Usage.STORAGE | GPUBuffer.Usage.COPY_DST);
                GPUBindGroup bg2 = bindGroup(l2, sbuf, (double) n * 64);
                String r2 = measure("G2", n, (t, out) -> {
                    double a = now();
                    matrices(g2, 16, n, t);
                    double b = now();
                    queue.writeBuffer(sbuf, 0, Float32Array.copyFromJavaArray(g2));
                    GPUCommandEncoder en = device.createCommandEncoder();
                    GPURenderPassEncoder pass = begin(en, target);
                    pass.setPipeline(pipe2);
                    pass.setBindGroup(0, bg2);
                    pass.draw(6, n, 0, 0);
                    pass.end();
                    submit(en);
                    calls += 12;
                    double c = now();
                    out[0] = b - a; out[1] = c - b;
                }, () -> queue.onSubmittedWorkDone().await(), Main::coverageGpu);
                sb.append(",").append(r2);
                log(r2);
                ub.destroy(); sbuf.destroy();
            }
            sb.append("]}");
            report(sb.toString());
        } catch (Throwable ex) {
            fail(String.valueOf(ex) + " | partial=" + sb);
        }
    }

    @JSBody(params = {"p", "g", "o", "i"}, script = "p.setBindGroup(0, g, o, i, 1);")
    static native void setBindGroupAt(JSObject p, JSObject g, JSObject o, int i);

    @JSBody(params = {"a", "k"}, script = "return a.limits[k];")
    static native double adapterLimit(JSObject a, String k);
}
