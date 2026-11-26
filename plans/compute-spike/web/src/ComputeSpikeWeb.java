import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.browser.Navigator;
import org.teavm.jso.core.JSArray;
import org.teavm.jso.typedarrays.ArrayBuffer;
import org.teavm.jso.typedarrays.Float32Array;
import org.teavm.jso.typedarrays.Int32Array;
import org.teavm.jso.typedarrays.Uint8Array;
import org.teavm.jso.webgpu.GPUAdapter;
import org.teavm.jso.webgpu.GPUBindGroup;
import org.teavm.jso.webgpu.GPUBuffer;
import org.teavm.jso.webgpu.GPUCommandEncoder;
import org.teavm.jso.webgpu.GPUComputePassEncoder;
import org.teavm.jso.webgpu.GPUDescriptor;
import org.teavm.jso.webgpu.GPUDevice;
import org.teavm.jso.webgpu.GPUPipeline;
import org.teavm.jso.webgpu.GPUQueue;
import org.teavm.jso.webgpu.GPURenderPassEncoder;
import org.teavm.jso.webgpu.GPUShaderModule;
import org.teavm.jso.webgpu.GPUTexture;

/**
 * TeaVM（WasmGC）の JSO から navigator.gpu の compute を回すスパイク。デスクトップの ComputeSpike と同じ 4 つ:
 * sum（1 万個）・tex（storage texture → 描画の pass → 読み戻し）・time（compute → 描画 1 コマの値段）・part（100 万個）。
 * compute の道（pipeline・pass・dispatch・mapAsync）は TeaVM の型付きの JSO で呼び、記述子の組み立てだけ @JSBody の object literal にする。
 * 結果は window.__bench（bin/fge web-bench が読む形）と console に出す。
 */
public final class ComputeSpikeWeb {
    static final int N = 10_000, W = 256, H = 256, PARTICLES = 1_000_000;
    static GPUDevice device;
    static GPUQueue queue;
    static boolean timestamps;
    static boolean allOk = true;

    public static void main(String[] args) {
        benchInit();
        try {
            if (!Navigator.isWebGPUSupported()) { fail("navigator.gpu が無い"); return; }
            double t0 = now();
            GPUDescriptor.RequestAdapterOptions op = GPUDescriptor.create();
            op.setPowerPreference("high-performance");
            GPUAdapter adapter = Navigator.getGPU().requestAdapter(op).await();
            timestamps = adapterHas(adapter, "timestamp-query");
            device = adapter.requestDevice(deviceDesc(timestamps)).await();
            queue = device.getQueue();
            watchErrors(device);
            result("init", true, "ms=" + fmt(now() - t0) + " timestamps=" + timestamps + " adapter=" + adapterInfo(adapter));
            sum();
            tex();
            timing();
            if (timestamps) amortized();
            particles();
            result("gpu-errors", errorCount() == 0, "count=" + errorCount());
            result("all", allOk && errorCount() == 0, "");
        } catch (Throwable e) {
            fail(String.valueOf(e));
        }
        benchDone();
    }

    // ---------- 1. 1 万個 ----------
    static final String SUM_WGSL = """
        @group(0) @binding(0) var<storage, read> src: array<u32>;
        @group(0) @binding(1) var<storage, read_write> dstU: array<u32>;
        @group(0) @binding(2) var<storage, read_write> dstF: array<f32>;
        @group(0) @binding(3) var<storage, read_write> total: atomic<u32>;
        @compute @workgroup_size(256)
        fn cs_main(@builtin(global_invocation_id) id: vec3u) {
            let i = id.x;
            if (i >= arrayLength(&src)) { return; }
            let v = src[i];
            dstU[i] = v * v + 7u;
            dstF[i] = sin(f32(v) * 0.01) * 0.5 + sqrt(f32(v));
            atomicAdd(&total, v);
        }
        """;

    static void sum() {
        int[] src = new int[N];
        Int32Array up = Int32Array.create(N);
        for (int i = 0; i < N; i++) { src[i] = (int) ((i * 2654435761L) % 1000L); up.set(i, src[i]); }
        GPUBuffer bSrc = buffer(N * 4, STORAGE | COPY_DST), bU = buffer(N * 4, STORAGE | COPY_SRC), bF = buffer(N * 4, STORAGE | COPY_SRC);
        GPUBuffer bT = buffer(16, STORAGE | COPY_SRC | COPY_DST);
        GPUBuffer rU = buffer(N * 4, COPY_DST | MAP_READ), rF = buffer(N * 4, COPY_DST | MAP_READ), rT = buffer(16, COPY_DST | MAP_READ);
        queue.writeBuffer(bSrc, 0, up);
        queue.writeBuffer(bT, 0, Int32Array.create(4));
        GPUPipeline.Compute pipe = computePipeline(SUM_WGSL);
        GPUBindGroup bg = bindBuffers(pipe, JSArray.of(bSrc, bU, bF, bT));
        GPUCommandEncoder enc = device.createCommandEncoder();
        GPUComputePassEncoder cp = enc.beginComputePass();
        cp.setPipeline(pipe);
        cp.setBindGroup(0, bg);
        cp.dispatchWorkgroups((N + 255) / 256);
        cp.end();
        enc.copyBufferToBuffer(bU, 0, rU, 0, N * 4);
        enc.copyBufferToBuffer(bF, 0, rF, 0, N * 4);
        enc.copyBufferToBuffer(bT, 0, rT, 0, 16);
        queue.submit(JSArray.of(enc.finish()));
        Int32Array outU = Int32Array.create(readMapped(rU));
        Float32Array outF = Float32Array.create(readMapped(rF));
        Int32Array outT = Int32Array.create(readMapped(rT));
        long cpuTotal = 0;
        int badU = 0, badF = 0;
        double maxErr = 0;
        for (int i = 0; i < N; i++) {
            int v = src[i];
            cpuTotal += v;
            if (outU.get(i) != v * v + 7) badU++;
            float cpuF = (float) (Math.sin(v * 0.01f) * 0.5 + Math.sqrt(v));
            double e = Math.abs(cpuF - outF.get(i));
            maxErr = Math.max(maxErr, e);
            if (e > 1e-4) badF++;
        }
        long gpuTotal = outT.get(0) & 0xffffffffL;
        boolean ok = gpuTotal == cpuTotal && badU == 0 && badF == 0;
        result("sum", ok, "N=" + N + " gpu=" + gpuTotal + " cpu=" + cpuTotal + " u32-mismatch=" + badU + " f32-maxerr=" + maxErr + " f32-over-1e-4=" + badF);
    }

    // ---------- 2. storage texture → 描画 ----------
    static final String TEX_CS = """
        struct P { t: f32, _a: f32, _b: f32, _c: f32 };
        @group(0) @binding(0) var dst: texture_storage_2d<rgba8unorm, write>;
        @group(0) @binding(1) var<uniform> p: P;
        @compute @workgroup_size(8, 8)
        fn cs_main(@builtin(global_invocation_id) id: vec3u) {
            if (id.x >= 256u || id.y >= 256u) { return; }
            let r = f32(id.x) / 255.0;
            let g = f32(id.y) / 255.0;
            let b = f32((id.x ^ id.y) & 255u) / 255.0;
            let fx = f32(id.x) * 0.05 + p.t;
            let fy = f32(id.y) * 0.07;
            let a = 0.5 + 0.25 * sin(fx) + 0.25 * cos(fy);
            textureStore(dst, vec2i(id.xy), vec4f(r, g, b, a));
        }
        """;
    static final String TEX_DRAW = """
        @group(0) @binding(0) var src: texture_2d<f32>;
        @vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
            let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
            return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
        }
        @fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
            return textureLoad(src, vec2i(pos.xy), 0);
        }
        """;

    static GPUTexture stTex, rtTex;
    static GPUBuffer texParam;
    static GPUPipeline.Compute texPipe;
    static GPUPipeline.Render drawPipe;
    static GPUBindGroup texBg, drawBg;
    static JSObject querySet;

    static void texSetup() {
        stTex = texture(device, W, H, 0x08 | 0x04);          // STORAGE_BINDING | TEXTURE_BINDING
        rtTex = texture(device, W, H, 0x10 | 0x01);          // RENDER_ATTACHMENT | COPY_SRC
        texParam = buffer(16, UNIFORM | COPY_DST);
        texPipe = computePipeline(TEX_CS);
        texBg = bindTexAndBuffer(device, texPipe, stTex, texParam);
        drawPipe = drawPipeline(device, shader(TEX_DRAW));
        drawBg = bindTex(device, drawPipe, stTex);
    }

    static GPUCommandEncoder encodeFrame(float t, boolean ts) {
        Float32Array pb = Float32Array.create(4);
        pb.set(0, t);
        queue.writeBuffer(texParam, 0, pb);
        GPUCommandEncoder enc = device.createCommandEncoder();
        GPUComputePassEncoder cp = ts ? enc.beginComputePass(computePassTs(querySet, 0, 1)) : enc.beginComputePass();
        cp.setPipeline(texPipe);
        cp.setBindGroup(0, texBg);
        cp.dispatchWorkgroups(W / 8, H / 8, 1);
        cp.end();
        GPURenderPassEncoder rp = enc.beginRenderPass(renderPassDesc(rtTex, ts ? querySet : null));
        rp.setPipeline(drawPipe);
        rp.setBindGroup(0, drawBg);
        rp.draw(3);
        rp.end();
        return enc;
    }

    static Uint8Array readRt() {
        GPUBuffer out = buffer(W * 4 * H, COPY_DST | MAP_READ);
        GPUCommandEncoder enc = device.createCommandEncoder();
        copyTexToBuf(enc, rtTex, out, W, H);
        queue.submit(JSArray.of(enc.finish()));
        Uint8Array px = Uint8Array.create(Uint8Array.create(readMappedKeep(out)));
        out.unmap();
        out.destroy();
        return px;
    }

    static void tex() {
        texSetup();
        float t = 1.25f;
        queue.submit(JSArray.of(encodeFrame(t, false).finish()));
        Uint8Array px = readRt();
        int badExact = 0, badWave = 0, maxWave = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int o = (y * W + x) * 4;
            int r = px.get(o), g = px.get(o + 1), b = px.get(o + 2), a = px.get(o + 3);
            if (r != x || g != y || b != ((x ^ y) & 255)) badExact++;
            double av = 0.5 + 0.25 * Math.sin(x * 0.05f + t) + 0.25 * Math.cos(y * 0.07f);
            int d = Math.abs((int) Math.round(Math.max(0, Math.min(1, av)) * 255.0) - a);
            maxWave = Math.max(maxWave, d);
            if (d > 1) badWave++;
        }
        int stale = 0;
        for (int f = 0; f < 30; f++) {
            float tf = 0.37f * f;
            queue.submit(JSArray.of(encodeFrame(tf, false).finish()));
            Uint8Array q = readRt();
            for (int x = 0; x < W; x += 17) {
                double av = 0.5 + 0.25 * Math.sin(x * 0.05f + tf) + 0.25;
                if (Math.abs((int) Math.round(Math.min(1, av) * 255.0) - q.get(x * 4 + 3)) > 1) { stale++; break; }
            }
        }
        boolean ok = badExact == 0 && badWave == 0 && stale == 0;
        result("tex", ok, W + "x" + H + " rgb-exact-mismatch=" + badExact + " wave-alpha-maxdiff=" + maxWave + " over1=" + badWave + " stale-frames=" + stale + "/30");
    }

    // ---------- 3. 順番と値段 ----------
    static void timing() {
        GPUBuffer qRes = null, qRead = null;
        if (timestamps) {
            querySet = createQuerySet(device, 4);
            qRes = buffer(32, QUERY_RESOLVE | COPY_SRC);
            qRead = buffer(32, COPY_DST | MAP_READ);
        }
        int warm = 30, meas = 200;
        double[] enc = new double[meas], waitDone = new double[meas], waitMap = new double[meas], gpuCs = new double[meas], gpuRp = new double[meas];
        for (int f = 0; f < warm + meas; f++) {
            double a0 = now();
            GPUCommandEncoder e = encodeFrame(f * 0.016f, timestamps);
            if (timestamps) { resolve(e, querySet, 4, qRes); e.copyBufferToBuffer(qRes, 0, qRead, 0, 32); }
            queue.submit(JSArray.of(e.finish()));
            double a1 = now();
            queue.onSubmittedWorkDone().await();
            double a2 = now();
            double cs = 0, rp = 0;
            if (timestamps) {
                ArrayBuffer ab = readMappedKeep(qRead);
                cs = tsDiffMs(ab, 0, 1); rp = tsDiffMs(ab, 2, 3);
                qRead.unmap();
            }
            double a3 = now();
            if (f >= warm) { int k = f - warm; enc[k] = a1 - a0; waitDone[k] = a2 - a1; waitMap[k] = a3 - a2; gpuCs[k] = cs; gpuRp[k] = rp; }
        }
        result("time-cpu", true, "encode+submit(compute+render) median=" + fmt(med(enc)) + " ms p95=" + fmt(p95(enc))
            + " ; onSubmittedWorkDone median=" + fmt(med(waitDone)) + " ms p95=" + fmt(p95(waitDone))
            + " ; then mapAsync(timestamps) median=" + fmt(med(waitMap)) + " ms");
        if (timestamps) result("time-gpu", true, "compute-pass 256x256 median=" + fmt(med(gpuCs)) + " ms ; render-pass median=" + fmt(med(gpuRp)) + " ms");
    }

    static void amortized() {
        JSObject qs = createQuerySet(device, 2);
        GPUBuffer qRes = buffer(16, QUERY_RESOLVE | COPY_SRC), qRead = buffer(16, COPY_DST | MAP_READ);
        int K = 200;
        double[] per = new double[30];
        for (int r = 0; r < 40; r++) {
            GPUCommandEncoder e = device.createCommandEncoder();
            GPUComputePassEncoder cp = e.beginComputePass(computePassTs(qs, 0, 1));
            cp.setPipeline(texPipe); cp.setBindGroup(0, texBg);
            for (int k = 0; k < K; k++) cp.dispatchWorkgroups(W / 8, H / 8, 1);
            cp.end();
            resolve(e, qs, 2, qRes); e.copyBufferToBuffer(qRes, 0, qRead, 0, 16);
            queue.submit(JSArray.of(e.finish()));
            ArrayBuffer ab = readMappedKeep(qRead);
            if (r >= 10) per[r - 10] = tsDiffMs(ab, 0, 1) / K;
            qRead.unmap();
        }
        result("time-gpu-amortized", true, "one 256x256 dispatch (over " + K + ") median=" + fmt4(med(per)) + " ms");
    }

    // ---------- 4. 100 万個 ----------
    static final String PART_CS = """
        struct Particle { pos: vec4f, vel: vec4f };
        struct P { dt: f32, n: u32, _a: f32, _b: f32 };
        @group(0) @binding(0) var<storage, read_write> ps: array<Particle>;
        @group(0) @binding(1) var<uniform> p: P;
        @compute @workgroup_size(256)
        fn cs_main(@builtin(global_invocation_id) id: vec3u, @builtin(num_workgroups) nw: vec3u) {
            let i = id.x + id.y * nw.x * 256u;
            if (i >= p.n) { return; }
            var q = ps[i];
            q.vel = vec4f(q.vel.xyz + vec3f(0.0, -9.8, 0.0) * p.dt, 0.0);
            q.pos = vec4f(q.pos.xyz + q.vel.xyz * p.dt, 1.0);
            if (q.pos.y < 0.0) { q.pos.y = -q.pos.y; q.vel.y = -q.vel.y * 0.8; }
            ps[i] = q;
        }
        """;

    static void particles() {
        int size = PARTICLES * 32;
        GPUBuffer ps = buffer(size, STORAGE | COPY_DST | COPY_SRC), pr = buffer(16, UNIFORM | COPY_DST), rd = buffer(32, COPY_DST | MAP_READ);
        Float32Array init = Float32Array.create(PARTICLES * 8);
        fillParticles(init, PARTICLES);
        double w0 = now();
        queue.writeBuffer(ps, 0, init);
        queue.onSubmittedWorkDone().await();
        double upMs = now() - w0;
        float dt = 1f / 60f;
        ArrayBuffer pab = ArrayBuffer.create(16);
        Float32Array.create(pab).set(0, dt);
        Int32Array.create(pab).set(1, PARTICLES);
        queue.writeBuffer(pr, 0, pab);
        GPUPipeline.Compute pipe = computePipeline(PART_CS);
        GPUBindGroup bg = bindBuffers(pipe, JSArray.of(ps, pr));
        JSObject qs = timestamps ? createQuerySet(device, 2) : null;
        GPUBuffer qRes = timestamps ? buffer(16, QUERY_RESOLVE | COPY_SRC) : null, qRead = timestamps ? buffer(16, COPY_DST | MAP_READ) : null;
        int steps = 120, warm = 20;
        double[] gms = new double[steps - warm], wall = new double[steps - warm];
        for (int s = 0; s < steps; s++) {
            double t0 = now();
            GPUCommandEncoder e = device.createCommandEncoder();
            GPUComputePassEncoder cp = timestamps ? e.beginComputePass(computePassTs(qs, 0, 1)) : e.beginComputePass();
            cp.setPipeline(pipe); cp.setBindGroup(0, bg);
            cp.dispatchWorkgroups((PARTICLES + 255) / 256);
            cp.end();
            if (timestamps) { resolve(e, qs, 2, qRes); e.copyBufferToBuffer(qRes, 0, qRead, 0, 16); }
            queue.submit(JSArray.of(e.finish()));
            double g = 0;
            if (timestamps) { ArrayBuffer ab = readMappedKeep(qRead); g = tsDiffMs(ab, 0, 1); qRead.unmap(); }
            else queue.onSubmittedWorkDone().await();
            if (s >= warm) { gms[s - warm] = g; wall[s - warm] = now() - t0; }
        }
        GPUCommandEncoder e = device.createCommandEncoder();
        e.copyBufferToBuffer(ps, 0, rd, 0, 32);
        queue.submit(JSArray.of(e.finish()));
        Float32Array p0 = Float32Array.create(readMapped(rd));
        float y = 10f, vy = 0f;
        for (int s = 0; s < steps; s++) { vy = vy + (-9.8f) * dt; y = y + vy * dt; if (y < 0f) { y = -y; vy = -vy * 0.8f; } }
        double err = Math.max(Math.abs(y - p0.get(1)), Math.abs(vy - p0.get(5)));
        result("particles", err < 1e-3, "n=" + PARTICLES + " upload(32MB write+done)=" + fmt(upMs) + " ms gpu-dispatch median=" + fmt(med(gms))
            + " ms p95=" + fmt(p95(gms)) + " wall(submit+wait) median=" + fmt(med(wall)) + " ms ; p0.y gpu=" + p0.get(1) + " cpu=" + y + " err=" + err);
    }

    // ---------- 補助（型付きの JSO） ----------
    static final int MAP_READ = 1, COPY_SRC = 4, COPY_DST = 8, UNIFORM = 64, STORAGE = 128, QUERY_RESOLVE = 512;

    static GPUBuffer buffer(int size, int usage) {
        GPUDescriptor.Buffer d = GPUDescriptor.create();
        d.setSize(size);
        d.setUsage(usage);
        return device.createBuffer(d);
    }

    static GPUShaderModule shader(String code) {
        GPUDescriptor.ShaderModule d = GPUDescriptor.create();
        d.setCode(code);
        return device.createShaderModule(d);
    }

    static GPUPipeline.Compute computePipeline(String code) {
        GPUDescriptor.ProgrammableStage st = GPUDescriptor.create();
        st.setModule(shader(code));
        st.setEntryPoint("cs_main");
        GPUDescriptor.ComputePipeline d = GPUDescriptor.create();
        d.setLayout("auto");
        d.setCompute(st);
        return device.createComputePipeline(d);
    }

    /** map して ArrayBuffer を写して unmap する（写さないと unmap で中身が切り離される）。 */
    static ArrayBuffer readMapped(GPUBuffer b) {
        ArrayBuffer view = readMappedKeep(b);
        ArrayBuffer copy = sliceCopy(view);
        b.unmap();
        return copy;
    }

    static ArrayBuffer readMappedKeep(GPUBuffer b) {
        b.mapAsync(MAP_READ).await();
        return b.getMappedRange();
    }

    static double med(double[] v) { double[] c = v.clone(); java.util.Arrays.sort(c); return c[c.length / 2]; }
    static double p95(double[] v) { double[] c = v.clone(); java.util.Arrays.sort(c); return c[(int) (c.length * 0.95)]; }
    static String fmt(double v) { return String.valueOf(Math.round(v * 1000) / 1000.0); }
    static String fmt4(double v) { return String.valueOf(Math.round(v * 10000) / 10000.0); }

    static void fillParticles(Float32Array a, int n) {
        for (int i = 0; i < n; i++) {
            int o = i * 8;
            a.set(o, i % 1000); a.set(o + 1, 10f + (i % 7)); a.set(o + 2, i / 1000); a.set(o + 3, 1f);
        }
    }

    static void result(String name, boolean ok, String detail) {
        if (!ok) allOk = false;
        benchResult(name, ok, detail);
    }

    static void fail(String msg) { allOk = false; benchResult("error", false, msg); benchDone(); }

    // ---------- 補助（記述子の object literal と頁） ----------
    @JSBody(script = "return performance.now();")
    static native double now();

    @JSBody(params = {"a", "name"}, script = "return a.features.has(name);")
    static native boolean adapterHas(GPUAdapter a, String name);

    @JSBody(params = {"a"}, script = "var i = a.info || {}; return (i.vendor || '') + '/' + (i.architecture || '') + '/' + (i.description || '');")
    static native String adapterInfo(GPUAdapter a);

    @JSBody(params = {"ts"}, script = "return ts ? { requiredFeatures: ['timestamp-query'] } : {};")
    static native GPUDescriptor.Device deviceDesc(boolean ts);

    @JSBody(params = {"d"}, script = "window.__gpuErrors = 0; d.addEventListener('uncapturederror', function (e) { window.__gpuErrors++; console.error('GPU ERROR ' + e.error.message); });")
    static native void watchErrors(GPUDevice d);

    @JSBody(script = "return window.__gpuErrors | 0;")
    static native int errorCount();

    @JSBody(params = {"pipe", "bufs"}, script =
        "var es = []; for (var i = 0; i < bufs.length; i++) es.push({ binding: i, resource: { buffer: bufs[i] } });"
        + "return window.__dev.createBindGroup({ layout: pipe.getBindGroupLayout(0), entries: es });")
    static native GPUBindGroup bindBuffersJs(JSObject pipe, JSArray<GPUBuffer> bufs);

    @JSBody(params = {"d"}, script = "window.__dev = d;")
    static native void keepDevice(GPUDevice d);

    static GPUBindGroup bindBuffers(GPUPipeline.Compute pipe, JSArray<GPUBuffer> bufs) {
        keepDevice(device);
        return bindBuffersJs(pipe, bufs);
    }

    @JSBody(params = {"d", "w", "h", "usage"}, script = "return d.createTexture({ size: [w, h], format: 'rgba8unorm', usage: usage });")
    static native GPUTexture texture(GPUDevice d, int w, int h, int usage);

    @JSBody(params = {"d", "pipe", "tex", "buf"}, script =
        "return d.createBindGroup({ layout: pipe.getBindGroupLayout(0), entries: ["
        + "{ binding: 0, resource: tex.createView() }, { binding: 1, resource: { buffer: buf } }] });")
    static native GPUBindGroup bindTexAndBuffer(GPUDevice d, JSObject pipe, GPUTexture tex, GPUBuffer buf);

    @JSBody(params = {"d", "pipe", "tex"}, script =
        "return d.createBindGroup({ layout: pipe.getBindGroupLayout(0), entries: [{ binding: 0, resource: tex.createView() }] });")
    static native GPUBindGroup bindTex(GPUDevice d, JSObject pipe, GPUTexture tex);

    @JSBody(params = {"d", "m"}, script =
        "return d.createRenderPipeline({ layout: 'auto', vertex: { module: m, entryPoint: 'vs_main' },"
        + " fragment: { module: m, entryPoint: 'fs_main', targets: [{ format: 'rgba8unorm' }] }, primitive: { topology: 'triangle-list' } });")
    static native GPUPipeline.Render drawPipeline(GPUDevice d, GPUShaderModule m);

    @JSBody(params = {"tex", "qs"}, script =
        "var d = { colorAttachments: [{ view: tex.createView(), loadOp: 'clear', storeOp: 'store', clearValue: [0, 0, 0, 1] }] };"
        + "if (qs) d.timestampWrites = { querySet: qs, beginningOfPassWriteIndex: 2, endOfPassWriteIndex: 3 }; return d;")
    static native GPUDescriptor.RenderPass renderPassDesc(GPUTexture tex, JSObject qs);

    @JSBody(params = {"qs", "b", "e"}, script = "return { timestampWrites: { querySet: qs, beginningOfPassWriteIndex: b, endOfPassWriteIndex: e } };")
    static native GPUDescriptor.ComputePass computePassTs(JSObject qs, int b, int e);

    @JSBody(params = {"d", "n"}, script = "return d.createQuerySet({ type: 'timestamp', count: n });")
    static native JSObject createQuerySet(GPUDevice d, int n);

    @JSBody(params = {"enc", "qs", "n", "buf"}, script = "enc.resolveQuerySet(qs, 0, n, buf, 0);")
    static native void resolve(GPUCommandEncoder enc, JSObject qs, int n, GPUBuffer buf);

    @JSBody(params = {"ab", "a", "b"}, script = "var v = new BigUint64Array(ab); return Number(v[b] - v[a]) / 1e6;")
    static native double tsDiffMs(ArrayBuffer ab, int a, int b);

    @JSBody(params = {"enc", "tex", "buf", "w", "h"}, script =
        "enc.copyTextureToBuffer({ texture: tex }, { buffer: buf, bytesPerRow: w * 4, rowsPerImage: h }, [w, h]);")
    static native void copyTexToBuf(GPUCommandEncoder enc, GPUTexture tex, GPUBuffer buf, int w, int h);

    @JSBody(params = {"ab"}, script = "return ab.slice(0);")
    static native ArrayBuffer sliceCopy(ArrayBuffer ab);

    @JSBody(script = "window.__bench = { query: location.search, env: { ua: navigator.userAgent }, results: [], done: false };")
    static native void benchInit();

    @JSBody(params = {"name", "ok", "detail"}, script =
        "window.__bench.results.push({ name: name, ok: ok, detail: detail }); console.log('[bench] result ' + name + ' ' + (ok ? 'OK' : 'NG') + ' ' + detail);")
    static native void benchResult(String name, boolean ok, String detail);

    @JSBody(script = "window.__bench.done = true;")
    static native void benchDone();
}
