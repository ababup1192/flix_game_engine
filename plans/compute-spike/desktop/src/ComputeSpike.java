import com.github.xpenatan.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * jWebGPU 0.3.4（Dawn）で compute を回すスパイク。
 *   1. sum   : 1 万個の u32 を atomicAdd で足す + 要素ごとの式（u32 と f32）を CPU の答えと比べる
 *   2. tex   : 256×256 の storage texture に compute で式を書き、同じ command encoder の描画の pass で textureLoad して読み戻す
 *   3. time  : 1 コマ = compute → 描画 を 300 回。CPU 側の時間と GPU の timestamp
 *   4. part  : 100 万個の粒子（vec4f 2 本）を 1 dispatch で進める GPU 時間
 */
public final class ComputeSpike {
    static final int N = 10_000;
    static final int W = 256, H = 256;
    static final int PARTICLES = 1_000_000;

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

    // 整数の式（バイト一致を見る）と浮動小数の式（波の高さ・±1 で見る）を 1 枚に入れる。
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

    static Gpu g;

    public static void main(String[] a) throws Exception {
        long t0 = System.nanoTime();
        g = Gpu.init(JWebGPUBackend.DAWN, true);
        System.out.printf("init ms=%.1f timestamps=%s%n", (System.nanoTime() - t0) / 1e6, g.timestamps);
        boolean ok = sum();
        ok &= tex();
        timing("sleep1"); Gpu.SPIN = true; timing("spin"); Gpu.SPIN = false; amortized();
        particles();
        System.out.println("RESULT gpu-errors " + Gpu.errors);
        System.out.println(ok && Gpu.errors == 0 ? "RESULT ALL OK" : "RESULT NG");
        System.exit(ok && Gpu.errors == 0 ? 0 : 1);
    }

    // ---------- 1. 1 万個の数 ----------
    static boolean sum() {
        int[] src = new int[N];
        for (int i = 0; i < N; i++) src[i] = (int) ((i * 2654435761L) % 1000L);
        WGPUBuffer bSrc = g.buffer(N * 4L, WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopyDst));
        WGPUBuffer bU = g.buffer(N * 4L, WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopySrc));
        WGPUBuffer bF = g.buffer(N * 4L, WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopySrc));
        WGPUBuffer bT = g.buffer(16, WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopySrc).or(WGPUBufferUsage.CopyDst));
        WGPUBuffer rU = g.buffer(N * 4L, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        WGPUBuffer rF = g.buffer(N * 4L, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        WGPUBuffer rT = g.buffer(16, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        ByteBuffer bb = direct(N * 4);
        for (int v : src) bb.putInt(v);
        bb.flip();
        g.queue.writeBuffer(bSrc, 0, bb, N * 4);
        g.queue.writeBuffer(bT, 0, direct(16), 16);

        WGPUBindGroupLayout bgl = layout(new Entry[]{
            Entry.buf(0, WGPUBufferBindingType.ReadOnlyStorage, WGPUShaderStage.Compute),
            Entry.buf(1, WGPUBufferBindingType.Storage, WGPUShaderStage.Compute),
            Entry.buf(2, WGPUBufferBindingType.Storage, WGPUShaderStage.Compute),
            Entry.buf(3, WGPUBufferBindingType.Storage, WGPUShaderStage.Compute)});
        WGPUComputePipeline pipe = computePipeline(SUM_WGSL, bgl);
        WGPUBindGroup bg = bindGroup(bgl, new Object[]{bSrc, N * 4L, bU, N * 4L, bF, N * 4L, bT, 4L});

        WGPUCommandEncoder enc = encoder();
        WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
        enc.beginComputePass(WGPUComputePassDescriptor.NULL, cp);
        cp.setPipeline(pipe);
        cp.setBindGroup(0, bg);
        cp.setDispatchWorkgroups((N + 255) / 256, 1, 1);
        cp.end(); cp.release();
        enc.copyBufferToBuffer(bU, 0, rU, 0, N * 4);
        enc.copyBufferToBuffer(bF, 0, rF, 0, N * 4);
        enc.copyBufferToBuffer(bT, 0, rT, 0, 16);
        g.submit(enc);
        ByteBuffer outU = g.readMapped(rU, N * 4), outF = g.readMapped(rF, N * 4), outT = g.readMapped(rT, 16);

        long cpuTotal = 0;
        int badU = 0, badF = 0;
        double maxErrF = 0;
        for (int i = 0; i < N; i++) {
            int v = src[i];
            cpuTotal += v;
            if (outU.getInt(i * 4) != v * v + 7) badU++;
            float cpuF = (float) (Math.sin(v * 0.01f) * 0.5 + Math.sqrt(v));
            float gpuF = outF.getFloat(i * 4);
            double e = Math.abs(cpuF - gpuF);
            maxErrF = Math.max(maxErrF, e);
            if (e > 1e-4) badF++;
        }
        long gpuTotal = outT.getInt(0) & 0xffffffffL;
        boolean ok = gpuTotal == cpuTotal && badU == 0 && badF == 0;
        System.out.printf("RESULT sum N=%d gpu=%d cpu=%d u32-mismatch=%d f32-maxerr=%.3g f32-over-1e-4=%d %s%n",
            N, gpuTotal, cpuTotal, badU, maxErrF, badF, ok ? "OK" : "NG");
        return ok;
    }

    // ---------- 2. storage texture → 描画の pass ----------
    static WGPUTexture stTex, rtTex;
    static WGPUTextureView stView, rtView;
    static WGPUBuffer texParam;
    static WGPUComputePipeline texPipe;
    static WGPURenderPipeline drawPipe;
    static WGPUBindGroup texBg, drawBg;

    static void texSetup() {
        stTex = texture(WGPUTextureUsage.StorageBinding.or(WGPUTextureUsage.TextureBinding));
        rtTex = texture(WGPUTextureUsage.RenderAttachment.or(WGPUTextureUsage.CopySrc));
        stView = new WGPUTextureView(); stTex.createView(WGPUTextureViewDescriptor.NULL, stView);
        rtView = new WGPUTextureView(); rtTex.createView(WGPUTextureViewDescriptor.NULL, rtView);
        texParam = g.buffer(16, WGPUBufferUsage.Uniform.or(WGPUBufferUsage.CopyDst));
        WGPUBindGroupLayout cl = layout(new Entry[]{
            Entry.storageTex(0, WGPUShaderStage.Compute),
            Entry.buf(1, WGPUBufferBindingType.Uniform, WGPUShaderStage.Compute)});
        texPipe = computePipeline(TEX_CS, cl);
        texBg = bindGroup(cl, new Object[]{stView, 0L, texParam, 16L});
        WGPUBindGroupLayout dl = layout(new Entry[]{Entry.sampledTex(0, WGPUShaderStage.Fragment)});
        drawPipe = g.pipeline(g.shader(TEX_DRAW), WGPUTextureFormat.RGBA8Unorm, pipelineLayout(dl), false);
        drawBg = bindGroup(dl, new Object[]{stView, 0L});
    }

    /** 1 コマ分: compute pass → render pass を同じ encoder に積む。qs があれば 0..3 に時刻。 */
    static WGPUCommandEncoder encodeFrame(float t, WGPUQuerySet qs) {
        ByteBuffer pb = direct(16);
        pb.putFloat(t).putFloat(0).putFloat(0).putFloat(0).flip();
        g.queue.writeBuffer(texParam, 0, pb, 16);
        WGPUCommandEncoder enc = encoder();
        WGPUComputePassDescriptor cd = new WGPUComputePassDescriptor();
        if (qs != null) {
            WGPUPassTimestampWrites tw = WGPUPassTimestampWrites.obtain();
            tw.setQuerySet(qs); tw.setBeginningOfPassWriteIndex(0); tw.setEndOfPassWriteIndex(1);
            cd.setTimestampWrites(tw);
        } else cd.setTimestampWrites(WGPUPassTimestampWrites.NULL);
        WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
        enc.beginComputePass(cd, cp);
        cp.setPipeline(texPipe);
        cp.setBindGroup(0, texBg);
        cp.setDispatchWorkgroups(W / 8, H / 8, 1);
        cp.end(); cp.release();
        WGPURenderPassEncoder rp = qs != null ? beginPassTs(enc, qs) : g.beginPass(enc, rtView, 0f, 0f, 0f);
        rp.setPipeline(drawPipe);
        rp.setBindGroup(0, drawBg);
        rp.draw(3, 1, 0, 0);
        rp.end(); rp.release();
        return enc;
    }

    static WGPURenderPassEncoder beginPassTs(WGPUCommandEncoder enc, WGPUQuerySet qs) {
        WGPURenderPassColorAttachment ca = WGPURenderPassColorAttachment.obtain();
        ca.setView(rtView); ca.setResolveTarget(WGPUTextureView.NULL);
        ca.setLoadOp(WGPULoadOp.Clear); ca.setStoreOp(WGPUStoreOp.Store);
        ca.getClearValue().setColor(0f, 0f, 0f, 1f);
        WGPUVectorRenderPassColorAttachment v = WGPUVectorRenderPassColorAttachment.obtain();
        v.push_back(ca);
        WGPURenderPassDescriptor rd = WGPURenderPassDescriptor.obtain();
        rd.setColorAttachments(v);
        rd.setDepthStencilAttachment(WGPURenderPassDepthStencilAttachment.NULL);
        WGPUPassTimestampWrites tw = WGPUPassTimestampWrites.obtain();
        tw.setQuerySet(qs); tw.setBeginningOfPassWriteIndex(2); tw.setEndOfPassWriteIndex(3);
        rd.setTimestampWrites(tw);
        WGPURenderPassEncoder pass = WGPURenderPassEncoder.obtain();
        enc.beginRenderPass(rd, pass);
        return pass;
    }

    static boolean tex() {
        texSetup();
        float t = 1.25f;
        g.submit(encodeFrame(t, null));
        ByteBuffer px = g.readTexture(rtTex, W, H);
        int bpr = Gpu.rowBytes(W);
        int badExact = 0, badWave = 0, maxWave = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            int o = y * bpr + x * 4;
            int r = px.get(o) & 255, gg = px.get(o + 1) & 255, b = px.get(o + 2) & 255, al = px.get(o + 3) & 255;
            if (r != x || gg != y || b != ((x ^ y) & 255)) badExact++;
            float fx = x * 0.05f + t, fy = y * 0.07f;
            double av = 0.5 + 0.25 * Math.sin(fx) + 0.25 * Math.cos(fy);
            int cpuA = (int) Math.round(Math.max(0, Math.min(1, av)) * 255.0);
            int d = Math.abs(cpuA - al);
            maxWave = Math.max(maxWave, d);
            if (d > 1) badWave++;
        }
        // 古いコマの値を読んでいないか: t を毎回変え、その場で読み戻した alpha が同じ t の CPU の答えか
        int stale = 0;
        for (int f = 0; f < 30; f++) {
            float tf = 0.37f * f;
            g.submit(encodeFrame(tf, null));
            ByteBuffer q = g.readTexture(rtTex, W, H);
            for (int x = 0; x < W; x += 17) {
                double av = 0.5 + 0.25 * Math.sin(x * 0.05f + tf) + 0.25 * Math.cos(0f);
                if (Math.abs((int) Math.round(Math.min(1, av) * 255.0) - (q.get(x * 4 + 3) & 255)) > 1) { stale++; break; }
            }
        }
        System.out.println("RESULT order 30 frames (compute t -> draw -> readback same submit) stale-frames=" + stale);
        boolean ok = badExact == 0 && badWave == 0 && stale == 0;
        System.out.printf("RESULT tex %dx%d compute->storage-texture->render-pass rgb-exact-mismatch=%d wave-alpha-maxdiff=%d over1=%d %s%n",
            W, H, badExact, maxWave, badWave, ok ? "OK" : "NG");
        return ok;
    }

    // ---------- 3. 順番と値段 ----------
    static void timing(String pump) {
        System.out.println("--- pump=" + pump);
        WGPUQuerySet qs = null;
        WGPUBuffer qRes = null, qRead = null;
        if (g.timestamps) {
            WGPUQuerySetDescriptor qd = new WGPUQuerySetDescriptor();
            qd.setType(WGPUQueryType.Timestamp); qd.setCount(4);
            qs = new WGPUQuerySet();
            g.device.createQuerySet(qd, qs);
            qRes = g.buffer(32, WGPUBufferUsage.QueryResolve.or(WGPUBufferUsage.CopySrc));
            qRead = g.buffer(32, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        }
        int warm = 60, meas = 300;
        double[] encMs = new double[meas], waitMs = new double[meas], gpuCs = new double[meas], gpuRp = new double[meas], gap = new double[meas];
        double[] emptyWait = new double[meas];
        for (int f = 0; f < warm + meas; f++) {
            long a0 = System.nanoTime();
            WGPUCommandEncoder enc = encodeFrame(f * 0.016f, qs);
            if (qs != null) { enc.resolveQuerySet(qs, 0, 4, qRes, 0); enc.copyBufferToBuffer(qRes, 0, qRead, 0, 32); }
            g.submit(enc);
            long a1 = System.nanoTime();
            if (qs != null) {
                ByteBuffer ts = g.readMapped(qRead, 32);
                long c0 = ts.getLong(0), c1 = ts.getLong(8), r0 = ts.getLong(16), r1 = ts.getLong(24);
                if (f >= warm) { gpuCs[f - warm] = (c1 - c0) / 1e6; gpuRp[f - warm] = (r1 - r0) / 1e6; gap[f - warm] = (r0 - c1) / 1e6; }
            } else g.waitIdle();
            long a2 = System.nanoTime();
            // 比べ: 何も積まずに待つだけ（同期の床）
            long b0 = System.nanoTime();
            g.waitIdle();
            long b1 = System.nanoTime();
            if (f >= warm) { encMs[f - warm] = (a1 - a0) / 1e6; waitMs[f - warm] = (a2 - a1) / 1e6; emptyWait[f - warm] = (b1 - b0) / 1e6; }
        }
        System.out.printf("RESULT time cpu encode+submit(compute+render) median=%.3f ms p95=%.3f%n", med(encMs), p95(encMs));
        System.out.printf("RESULT time cpu submit->readback(timestamps map) median=%.3f ms p95=%.3f%n", med(waitMs), p95(waitMs));
        System.out.printf("RESULT time cpu empty waitIdle(copy 16B + map) median=%.3f ms p95=%.3f%n", med(emptyWait), p95(emptyWait));
        if (qs != null) {
            System.out.printf("RESULT time gpu compute-pass 256x256 median=%.4f ms p95=%.4f%n", med(gpuCs), p95(gpuCs));
            System.out.printf("RESULT time gpu render-pass median=%.4f ms ; gap compute-end->render-begin median=%.4f ms (>=0 means ordered)%n", med(gpuRp), med(gap));
            int neg = 0; for (double d : gap) if (d < 0) neg++;
            System.out.println("RESULT order render-begin-before-compute-end count=" + neg + "/" + meas);
        }
    }

    /** Apple の timestamp は約 65 µs 刻みなので、256×256 の dispatch を K 回まとめて 1 回の dispatch の値段を割り出す。 */
    static void amortized() {
        WGPUQuerySet qs = new WGPUQuerySet();
        WGPUQuerySetDescriptor qd = new WGPUQuerySetDescriptor();
        qd.setType(WGPUQueryType.Timestamp); qd.setCount(2);
        g.device.createQuerySet(qd, qs);
        WGPUBuffer qRes = g.buffer(16, WGPUBufferUsage.QueryResolve.or(WGPUBufferUsage.CopySrc));
        WGPUBuffer qRead = g.buffer(16, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        int K = 200;
        double[] per = new double[30];
        for (int r = 0; r < 40; r++) {
            WGPUCommandEncoder enc = encoder();
            WGPUComputePassDescriptor cd = new WGPUComputePassDescriptor();
            WGPUPassTimestampWrites tw = WGPUPassTimestampWrites.obtain();
            tw.setQuerySet(qs); tw.setBeginningOfPassWriteIndex(0); tw.setEndOfPassWriteIndex(1);
            cd.setTimestampWrites(tw);
            WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
            enc.beginComputePass(cd, cp);
            cp.setPipeline(texPipe); cp.setBindGroup(0, texBg);
            for (int k = 0; k < K; k++) cp.setDispatchWorkgroups(W / 8, H / 8, 1);
            cp.end(); cp.release();
            enc.resolveQuerySet(qs, 0, 2, qRes, 0); enc.copyBufferToBuffer(qRes, 0, qRead, 0, 16);
            g.submit(enc);
            ByteBuffer ts = g.readMapped(qRead, 16);
            if (r >= 10) per[r - 10] = (ts.getLong(8) - ts.getLong(0)) / 1e6 / K;
        }
        System.out.printf("RESULT time gpu one 256x256 dispatch (amortized over %d) median=%.4f ms%n", K, med(per));
    }

    // ---------- 4. 100 万個 ----------
    static void particles() {
        long size = PARTICLES * 32L;
        WGPUBuffer ps = g.buffer(size, WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopyDst).or(WGPUBufferUsage.CopySrc));
        WGPUBuffer pr = g.buffer(16, WGPUBufferUsage.Uniform.or(WGPUBufferUsage.CopyDst));
        WGPUBuffer rd = g.buffer(64, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        ByteBuffer bb = direct((int) size);
        for (int i = 0; i < PARTICLES; i++) {
            bb.putFloat(i % 1000).putFloat(10f + (i % 7)).putFloat(i / 1000).putFloat(1f);
            bb.putFloat(0f).putFloat(0f).putFloat(0f).putFloat(0f);
        }
        bb.flip();
        long w0 = System.nanoTime();
        g.queue.writeBuffer(ps, 0, bb, (int) size);
        g.waitIdle();
        double upMs = (System.nanoTime() - w0) / 1e6;
        float dt = 1f / 60f;
        ByteBuffer pb = direct(16);
        pb.putFloat(dt).putInt(PARTICLES).putFloat(0).putFloat(0).flip();
        g.queue.writeBuffer(pr, 0, pb, 16);
        WGPUBindGroupLayout bgl = layout(new Entry[]{
            Entry.buf(0, WGPUBufferBindingType.Storage, WGPUShaderStage.Compute),
            Entry.buf(1, WGPUBufferBindingType.Uniform, WGPUShaderStage.Compute)});
        WGPUComputePipeline pipe = computePipeline(PART_CS, bgl);
        WGPUBindGroup bg = bindGroup(bgl, new Object[]{ps, size, pr, 16L});
        int groups = (PARTICLES + 255) / 256; // 3907: 1 次元の上限 65535 に収まる
        WGPUQuerySet qs = null; WGPUBuffer qRes = null, qRead = null;
        if (g.timestamps) {
            WGPUQuerySetDescriptor qd = new WGPUQuerySetDescriptor();
            qd.setType(WGPUQueryType.Timestamp); qd.setCount(2);
            qs = new WGPUQuerySet(); g.device.createQuerySet(qd, qs);
            qRes = g.buffer(16, WGPUBufferUsage.QueryResolve.or(WGPUBufferUsage.CopySrc));
            qRead = g.buffer(16, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        }
        int steps = 120, warm = 20;
        double[] gms = new double[steps - warm], wall = new double[steps - warm];
        for (int s = 0; s < steps; s++) {
            long t0 = System.nanoTime();
            WGPUCommandEncoder enc = encoder();
            WGPUComputePassDescriptor cd = new WGPUComputePassDescriptor();
            if (qs != null) {
                WGPUPassTimestampWrites tw = WGPUPassTimestampWrites.obtain();
                tw.setQuerySet(qs); tw.setBeginningOfPassWriteIndex(0); tw.setEndOfPassWriteIndex(1);
                cd.setTimestampWrites(tw);
            } else cd.setTimestampWrites(WGPUPassTimestampWrites.NULL);
            WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
            enc.beginComputePass(cd, cp);
            cp.setPipeline(pipe); cp.setBindGroup(0, bg);
            cp.setDispatchWorkgroups(groups, 1, 1);
            cp.end(); cp.release();
            if (qs != null) { enc.resolveQuerySet(qs, 0, 2, qRes, 0); enc.copyBufferToBuffer(qRes, 0, qRead, 0, 16); }
            g.submit(enc);
            double gpu = Double.NaN;
            if (qs != null) { ByteBuffer ts = g.readMapped(qRead, 16); gpu = (ts.getLong(8) - ts.getLong(0)) / 1e6; }
            else g.waitIdle();
            if (s >= warm) { gms[s - warm] = gpu; wall[s - warm] = (System.nanoTime() - t0) / 1e6; }
        }
        // 1 個目（i=0）と 777777 個目を CPU で同じ手数だけ進めて比べる
        WGPUCommandEncoder enc = encoder();
        enc.copyBufferToBuffer(ps, 0, rd, 0, 32);
        g.submit(enc);
        ByteBuffer p0 = g.readMapped(rd, 64);
        float[] cpu = simulate(0, steps, dt);
        double err = Math.max(Math.abs(cpu[0] - p0.getFloat(4)), Math.abs(cpu[1] - p0.getFloat(20)));
        System.out.printf("RESULT particles n=%d upload(32MB write+wait)=%.1f ms gpu-dispatch median=%.3f ms p95=%.3f wall(submit+wait) median=%.3f ms ; p0.y gpu=%.4f cpu=%.4f err=%.2g%n",
            PARTICLES, upMs, med(gms), p95(gms), med(wall), p0.getFloat(4), cpu[0], err);
    }

    static float[] simulate(int i, int steps, float dt) {
        float y = 10f + (i % 7), vy = 0f;
        for (int s = 0; s < steps; s++) {
            vy = vy + (-9.8f) * dt;
            y = y + vy * dt;
            if (y < 0f) { y = -y; vy = -vy * 0.8f; }
        }
        return new float[]{y, vy};
    }

    // ---------- 補助 ----------
    static ByteBuffer direct(int n) { return ByteBuffer.allocateDirect(n).order(ByteOrder.LITTLE_ENDIAN); }

    static double med(double[] v) { double[] c = v.clone(); Arrays.sort(c); return c[c.length / 2]; }
    static double p95(double[] v) { double[] c = v.clone(); Arrays.sort(c); return c[(int) (c.length * 0.95)]; }

    static WGPUCommandEncoder encoder() {
        WGPUCommandEncoder enc = new WGPUCommandEncoder();
        g.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
        return enc;
    }

    static WGPUTexture texture(WGPUTextureUsage usage) {
        WGPUTextureDescriptor td = new WGPUTextureDescriptor();
        td.setUsage(usage);
        td.setDimension(WGPUTextureDimension._2D);
        td.getSize().setWidth(W); td.getSize().setHeight(H); td.getSize().setDepthOrArrayLayers(1);
        td.setFormat(WGPUTextureFormat.RGBA8Unorm);
        td.setMipLevelCount(1); td.setSampleCount(1);
        WGPUTexture t = new WGPUTexture();
        g.device.createTexture(td, t);
        return t;
    }

    record Entry(int binding, WGPUShaderStage vis, WGPUBufferBindingType buf, int kind) {
        static Entry buf(int b, WGPUBufferBindingType t, WGPUShaderStage v) { return new Entry(b, v, t, 0); }
        static Entry storageTex(int b, WGPUShaderStage v) { return new Entry(b, v, null, 1); }
        static Entry sampledTex(int b, WGPUShaderStage v) { return new Entry(b, v, null, 2); }
    }

    static WGPUBindGroupLayout layout(Entry[] es) {
        WGPUVectorBindGroupLayoutEntry les = new WGPUVectorBindGroupLayoutEntry();
        for (Entry e : es) {
            WGPUBindGroupLayoutEntry le = new WGPUBindGroupLayoutEntry();
            le.setBinding(e.binding());
            le.setVisibility(e.vis());
            switch (e.kind()) {
                case 0 -> { WGPUBufferBindingLayout bl = new WGPUBufferBindingLayout(); bl.setType(e.buf()); bl.setHasDynamicOffset(0); le.setBuffer(bl); }
                case 1 -> {
                    WGPUStorageTextureBindingLayout sl = new WGPUStorageTextureBindingLayout();
                    sl.setAccess(WGPUStorageTextureAccess.WriteOnly);
                    sl.setFormat(WGPUTextureFormat.RGBA8Unorm);
                    sl.setViewDimension(WGPUTextureViewDimension._2D);
                    le.setStorageTexture(sl);
                }
                default -> {
                    WGPUTextureBindingLayout tl = new WGPUTextureBindingLayout();
                    tl.setSampleType(WGPUTextureSampleType.UnfilterableFloat);
                    tl.setViewDimension(WGPUTextureViewDimension._2D);
                    tl.setMultisampled(0);
                    le.setTexture(tl);
                }
            }
            les.push_back(le);
        }
        WGPUBindGroupLayoutDescriptor d = new WGPUBindGroupLayoutDescriptor();
        d.setEntries(les);
        WGPUBindGroupLayout l = new WGPUBindGroupLayout();
        g.device.createBindGroupLayout(d, l);
        return l;
    }

    static WGPUPipelineLayout pipelineLayout(WGPUBindGroupLayout bgl) {
        WGPUVectorBindGroupLayout v = new WGPUVectorBindGroupLayout();
        v.push_back(bgl);
        WGPUPipelineLayoutDescriptor d = new WGPUPipelineLayoutDescriptor();
        d.setBindGroupLayouts(v);
        WGPUPipelineLayout pl = new WGPUPipelineLayout();
        g.device.createPipelineLayout(d, pl);
        return pl;
    }

    static WGPUComputePipeline computePipeline(String wgsl, WGPUBindGroupLayout bgl) {
        WGPUComputePipelineDescriptor d = new WGPUComputePipelineDescriptor();
        d.setLayout(pipelineLayout(bgl));
        d.getCompute().setModule(g.shader(wgsl));
        d.getCompute().setEntryPoint("cs_main");
        d.getCompute().setConstants(WGPUVectorConstantEntry.NULL);
        WGPUComputePipeline p = new WGPUComputePipeline();
        g.device.createComputePipeline(d, p);
        if (!p.isValid()) throw new RuntimeException("compute pipeline invalid");
        return p;
    }

    /** pairs は (WGPUBuffer か WGPUTextureView, size) の並び。binding は順に 0,1,2… */
    static WGPUBindGroup bindGroup(WGPUBindGroupLayout bgl, Object[] pairs) {
        WGPUVectorBindGroupEntry es = new WGPUVectorBindGroupEntry();
        for (int i = 0; i < pairs.length / 2; i++) {
            WGPUBindGroupEntry e = new WGPUBindGroupEntry();
            e.setBinding(i);
            Object o = pairs[i * 2];
            if (o instanceof WGPUBuffer b) { e.setBuffer(b); e.setOffset(0); e.setSize((Long) pairs[i * 2 + 1]); }
            else e.setTextureView((WGPUTextureView) o);
            es.push_back(e);
        }
        WGPUBindGroupDescriptor d = new WGPUBindGroupDescriptor();
        d.setLayout(bgl); d.setEntries(es);
        WGPUBindGroup bg = new WGPUBindGroup();
        g.device.createBindGroup(d, bg);
        return bg;
    }
}
