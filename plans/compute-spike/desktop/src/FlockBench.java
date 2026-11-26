import com.github.xpenatan.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * C0 の測り: 群れ（Boids）8,000 個を Dawn の compute で進める。bind group の layout は全部明示。
 *   1. 総当たりと格子の 1 刻みの GPU 時間（K 刻みを 1 pass に積んで割る）
 *   2. 同じ GPU で 総当たり = 格子（1 刻み・60 刻みのバイト）・格子 2 回 = 同じ（バイト）
 *   3. CPU（Java・Float32・総当たり）の 1 刻みと GPU の差
 *   4. prewarm（720 刻みを 1 回の submit）の壁時計
 *   5. 全部が 1 点に集まった状態で NaN が出ないか
 * usage: run.sh FlockBench [count]
 */
public final class FlockBench {
    static Gpu g;
    static int N = 8000;
    static final float[] LO = {-20f, -10f, -20f}, HI = {20f, 10f, 20f};
    // 規則（Simulation3d.flockRules の既定と同じ値にそろえる）
    static float R = 2f, SEP = 0.8f, COH = 0.5f, ALI = 1.5f, SEPW = 2f, MAXS = 5f, MAXF = 10f, MARGIN = 3f, DT = 1f / 60f;

    static WGPUBuffer params, stateA, stateB, cellCount, cellStart, cellSlot, sorted, sortedState, blockSums, instances;
    static WGPUComputePipeline pCount, pScanBlocks, pScanSums, pScanAdd, pScatter, pGrid, pBrute, pPack;
    static WGPUBindGroup gCountA, gCountB, gScanBlocks, gScanSums, gScanAdd, gScatterA, gScatterB, gGridA, gGridB, gBruteAB, gBruteBA, gPackA, gPackB;
    static int gx, gy, gz;

    public static void main(String[] a) {
        if (a.length > 0) N = Integer.parseInt(a[0]);
        if (a.length > 4) { COH = Float.parseFloat(a[1]); ALI = Float.parseFloat(a[2]); SEPW = Float.parseFloat(a[3]); SEP = Float.parseFloat(a[4]); }
        g = Gpu.init(JWebGPUBackend.DAWN, true);
        ComputeSpike.g = g;
        System.out.println("timestamps=" + g.timestamps + " N=" + N);
        setup();
        float[] init = FlockState.initialState(N, 7, LO, HI, MAXS);
        boolean ok = true;

        // 2. 一致
        upload(stateA, init);
        runSteps(false, 1);
        float[] grid1 = read(stateB, N * 8);
        upload(stateA, init);
        runSteps(true, 1);
        float[] brute1 = read(stateB, N * 8);
        int diff1 = bytesDiffer(grid1, brute1);
        System.out.println("RESULT grid==brute 1 step differing floats=" + diff1);
        upload(stateA, init);
        runSteps(false, 60);
        float[] grid60 = read(stateA, N * 8);
        upload(stateA, init);
        runSteps(false, 60);
        float[] grid60b = read(stateA, N * 8);
        upload(stateA, init);
        runSteps(true, 60);
        float[] brute60 = read(stateA, N * 8);
        System.out.println("RESULT grid==brute 60 steps differing floats=" + bytesDiffer(grid60, brute60)
            + " maxabs=" + maxAbs(grid60, brute60));
        System.out.println("RESULT grid twice 60 steps differing floats=" + bytesDiffer(grid60, grid60b));
        ok &= bytesDiffer(grid60, grid60b) == 0;

        // 3. CPU
        float[] cpu1 = cpuStep(init);
        double e = maxAbs(cpu1, grid1);
        System.out.printf("RESULT cpu vs gpu 1 step maxabs=%.3g (box 40) %s%n", e, e < 1e-4 * 40 ? "OK" : "NG");
        ok &= e < 1e-4 * 40;
        float[] cpu60 = init;
        for (int s = 0; s < 60; s++) cpu60 = cpuStep(cpu60);
        System.out.printf("RESULT cpu vs gpu 60 steps maxabs=%.3g (chaotic; reference only)%n", maxAbs(cpu60, grid60));

        // 1. 時間（初めの散らばり と 600 刻み後の固まった群れ）
        upload(stateA, init);
        System.out.printf("RESULT time gpu grid  N=%d initial per-step median=%.4f ms%n", N, timeSteps(false, 2, 0));
        System.out.printf("RESULT time gpu brute N=%d initial per-step median=%.4f ms%n", N, timeSteps(true, 2, 0));
        upload(stateA, init);
        runSteps(false, 600);
        upload(stateA, read(stateA, N * 8));
        System.out.println("RESULT neighbors after 600 steps " + neighborStats(read(stateA, N * 8)));
        float[] steady = read(stateA, N * 8);
        for (int K : new int[]{2, 4}) {
            upload(stateA, steady);
            System.out.printf("RESULT time gpu grid  N=%d steady per-step median=%.4f ms (K=%d steps per pass)%n", N, timeSteps(false, K, 0), K);
            upload(stateA, steady);
            System.out.printf("RESULT time gpu brute N=%d steady per-step median=%.4f ms (K=%d)%n", N, timeSteps(true, K, 0), K);
        }
        System.out.printf("RESULT time gpu pack N=%d median=%.4f ms%n", N, timePack());

        // 4. prewarm
        double[] pw = new double[5];
        for (int r = 0; r < pw.length; r++) {
            upload(stateA, init);
            g.waitIdle();
            long t0 = System.nanoTime();
            runSteps(false, 720);
            pw[r] = (System.nanoTime() - t0) / 1e6;
        }
        System.out.printf("RESULT prewarm 720 grid steps N=%d wall median=%.1f ms%n", N, med(pw));

        // 5. 1 点
        float[] same = new float[N * 8];
        for (int i = 0; i < N; i++) { same[i * 8 + 3] = 1f; same[i * 8 + 4] = 1f; }
        upload(stateA, same);
        runSteps(false, 3);
        float[] s3 = read(stateB, N * 8);
        int nan = 0;
        for (float f : s3) if (Float.isNaN(f) || Float.isInfinite(f)) nan++;
        System.out.println("RESULT all-at-one-point 3 steps nan=" + nan + " cpu-diff=" + maxAbs(s3, cpuStep(cpuStep(cpuStep(same)))));
        ok &= nan == 0;

        // CPU の値段（参考: Java の総当たり・格子は Flix で測る）
        long c0 = System.nanoTime();
        for (int r = 0; r < 3; r++) cpuStep(init);
        System.out.printf("RESULT cpu java brute N=%d per-step=%.1f ms%n", N, (System.nanoTime() - c0) / 3e6);

        System.out.println("RESULT gpu-errors " + Gpu.errors);
        System.out.println(ok && Gpu.errors == 0 ? "RESULT ALL OK" : "RESULT NG");
        System.exit(ok && Gpu.errors == 0 ? 0 : 1);
    }

    static void setup() {
        int cx = Math.max(1, Math.min(32, (int) Math.floor((HI[0] - LO[0]) / R)));
        int cy = Math.max(1, Math.min(32, (int) Math.floor((HI[1] - LO[1]) / R)));
        int cz = Math.max(1, Math.min(32, (int) Math.floor((HI[2] - LO[2]) / R)));
        gx = cx; gy = cy; gz = cz;
        params = g.buffer(FlockKernels.PARAMS_BYTES, WGPUBufferUsage.Uniform.or(WGPUBufferUsage.CopyDst));
        WGPUBufferUsage st = WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopyDst).or(WGPUBufferUsage.CopySrc);
        stateA = g.buffer(N * 32L, st);
        stateB = g.buffer(N * 32L, st);
        cellCount = g.buffer(FlockKernels.MAX_CELLS * 4L, st);
        cellStart = g.buffer((FlockKernels.MAX_CELLS + 1) * 4L, st);
        cellSlot = g.buffer(N * 8L, st);
        sorted = g.buffer(N * 4L, st);
        sortedState = g.buffer(N * 32L, st);
        blockSums = g.buffer(FlockKernels.SCAN_BLOCKS * 4L, st);
        instances = g.buffer(N * 128L, st.or(WGPUBufferUsage.Vertex));
        writeParams();

        WGPUBufferBindingType U = WGPUBufferBindingType.Uniform, RO = WGPUBufferBindingType.ReadOnlyStorage, RW = WGPUBufferBindingType.Storage;
        WGPUBindGroupLayout lCount = layout(U, RO, RW, RW);
        WGPUBindGroupLayout lScanBlocks = layout(U, RO, RW, RW);
        WGPUBindGroupLayout lScanSums = layout(U, RW);
        WGPUBindGroupLayout lScanAdd = layout(U, RW, RO, RW);
        WGPUBindGroupLayout lScatter = layout(U, RO, RO, RO, RW, RW);
        WGPUBindGroupLayout lGrid = layout(U, RO, RO, RO, RW);
        WGPUBindGroupLayout lBrute = layout(U, RO, RW);
        WGPUBindGroupLayout lPack = layout(U, RO, RW);
        pCount = ComputeSpike.computePipeline(FlockKernels.COUNT, lCount);
        pScanBlocks = ComputeSpike.computePipeline(FlockKernels.SCAN_BLOCKS_WGSL, lScanBlocks);
        pScanSums = ComputeSpike.computePipeline(FlockKernels.SCAN_SUMS, lScanSums);
        pScanAdd = ComputeSpike.computePipeline(FlockKernels.SCAN_ADD, lScanAdd);
        pScatter = ComputeSpike.computePipeline(FlockKernels.SCATTER, lScatter);
        pGrid = ComputeSpike.computePipeline(FlockKernels.RULES_GRID, lGrid);
        pBrute = ComputeSpike.computePipeline(FlockKernels.RULES_BRUTE, lBrute);
        pPack = ComputeSpike.computePipeline(FlockKernels.PACK, lPack);
        long P = FlockKernels.PARAMS_BYTES, S = N * 32L, C = FlockKernels.MAX_CELLS * 4L, C1 = C + 4, B = FlockKernels.SCAN_BLOCKS * 4L;
        gCountA = ComputeSpike.bindGroup(lCount, new Object[]{params, P, stateA, S, cellCount, C, cellSlot, N * 8L});
        gCountB = ComputeSpike.bindGroup(lCount, new Object[]{params, P, stateB, S, cellCount, C, cellSlot, N * 8L});
        gScanBlocks = ComputeSpike.bindGroup(lScanBlocks, new Object[]{params, P, cellCount, C, cellStart, C1, blockSums, B});
        gScanSums = ComputeSpike.bindGroup(lScanSums, new Object[]{params, P, blockSums, B});
        gScanAdd = ComputeSpike.bindGroup(lScanAdd, new Object[]{params, P, cellStart, C1, blockSums, B, cellCount, C});
        gScatterA = ComputeSpike.bindGroup(lScatter, new Object[]{params, P, stateA, S, cellSlot, N * 8L, cellStart, C1, sortedState, S, sorted, N * 4L});
        gScatterB = ComputeSpike.bindGroup(lScatter, new Object[]{params, P, stateB, S, cellSlot, N * 8L, cellStart, C1, sortedState, S, sorted, N * 4L});
        gGridA = ComputeSpike.bindGroup(lGrid, new Object[]{params, P, sortedState, S, sorted, N * 4L, cellStart, C1, stateA, S});
        gGridB = ComputeSpike.bindGroup(lGrid, new Object[]{params, P, sortedState, S, sorted, N * 4L, cellStart, C1, stateB, S});
        gBruteAB = ComputeSpike.bindGroup(lBrute, new Object[]{params, P, stateA, S, stateB, S});
        gBruteBA = ComputeSpike.bindGroup(lBrute, new Object[]{params, P, stateB, S, stateA, S});
        gPackA = ComputeSpike.bindGroup(lPack, new Object[]{params, P, stateA, S, instances, N * 128L});
        gPackB = ComputeSpike.bindGroup(lPack, new Object[]{params, P, stateB, S, instances, N * 128L});
    }

    static WGPUBindGroupLayout layout(WGPUBufferBindingType... types) {
        ComputeSpike.Entry[] es = new ComputeSpike.Entry[types.length];
        for (int i = 0; i < types.length; i++) es[i] = ComputeSpike.Entry.buf(i, types[i], WGPUShaderStage.Compute);
        return ComputeSpike.layout(es);
    }

    static void writeParams() {
        ByteBuffer b = direct(FlockKernels.PARAMS_BYTES);
        b.putInt(N).putInt(gx).putInt(gy).putInt(gz);
        b.putFloat(LO[0]).putFloat(LO[1]).putFloat(LO[2]).putFloat(DT);
        b.putFloat(HI[0]).putFloat(HI[1]).putFloat(HI[2]).putFloat(R);
        b.putFloat((HI[0] - LO[0]) / gx).putFloat((HI[1] - LO[1]) / gy).putFloat((HI[2] - LO[2]) / gz).putFloat(SEP);
        b.putFloat(0).putFloat(0).putFloat(0).putFloat(0);
        b.putFloat(COH).putFloat(ALI).putFloat(SEPW).putFloat(MAXS);
        b.putFloat(MAXF).putFloat(MARGIN).putInt(0).putFloat(1f);
        b.flip();
        g.queue.writeBuffer(params, 0, b, FlockKernels.PARAMS_BYTES);
    }

    static int groups(int n) { return (n + 63) / 64; }

    /** 偶数番目の刻みは A → B。 */
    static void encodeStep(WGPUComputePassEncoder cp, boolean brute, int s) {
        boolean ab = s % 2 == 0;
        if (brute) {
            cp.setPipeline(pBrute); cp.setBindGroup(0, ab ? gBruteAB : gBruteBA); cp.setDispatchWorkgroups(groups(N), 1, 1);
            return;
        }
        cp.setPipeline(pCount); cp.setBindGroup(0, ab ? gCountA : gCountB); cp.setDispatchWorkgroups(groups(N), 1, 1);
        cp.setPipeline(pScanBlocks); cp.setBindGroup(0, gScanBlocks); cp.setDispatchWorkgroups(FlockKernels.SCAN_BLOCKS, 1, 1);
        cp.setPipeline(pScanSums); cp.setBindGroup(0, gScanSums); cp.setDispatchWorkgroups(1, 1, 1);
        cp.setPipeline(pScanAdd); cp.setBindGroup(0, gScanAdd); cp.setDispatchWorkgroups(FlockKernels.MAX_CELLS / 64, 1, 1);
        cp.setPipeline(pScatter); cp.setBindGroup(0, ab ? gScatterA : gScatterB); cp.setDispatchWorkgroups(groups(N), 1, 1);
        cp.setPipeline(pGrid); cp.setBindGroup(0, ab ? gGridB : gGridA); cp.setDispatchWorkgroups(groups(N), 1, 1);
    }

    static void runSteps(boolean brute, int steps) {
        WGPUCommandEncoder enc = ComputeSpike.encoder();
        WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
        enc.beginComputePass(WGPUComputePassDescriptor.NULL, cp);
        for (int s = 0; s < steps; s++) encodeStep(cp, brute, s);
        cp.end(); cp.release();
        g.submit(enc);
        g.waitIdle();
    }

    static WGPUQuerySet qs;
    static WGPUBuffer qRes, qRead;

    static double timeSteps(boolean brute, int K, int unused) {
        if (qs == null) {
            WGPUQuerySetDescriptor qd = new WGPUQuerySetDescriptor();
            qd.setType(WGPUQueryType.Timestamp); qd.setCount(2);
            qs = new WGPUQuerySet(); g.device.createQuerySet(qd, qs);
            qRes = g.buffer(16, WGPUBufferUsage.QueryResolve.or(WGPUBufferUsage.CopySrc));
            qRead = g.buffer(16, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        }
        int reps = 30;
        double[] per = new double[reps];
        float[] base = read(stateA, N * 8);
        for (int r = 0; r < reps + 5; r++) {
            WGPUCommandEncoder enc = ComputeSpike.encoder();
            WGPUComputePassDescriptor cd = new WGPUComputePassDescriptor();
            WGPUPassTimestampWrites tw = WGPUPassTimestampWrites.obtain();
            tw.setQuerySet(qs); tw.setBeginningOfPassWriteIndex(0); tw.setEndOfPassWriteIndex(1);
            cd.setTimestampWrites(tw);
            WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
            enc.beginComputePass(cd, cp);
            for (int s = 0; s < K; s++) encodeStep(cp, brute, s);
            cp.end(); cp.release();
            enc.resolveQuerySet(qs, 0, 2, qRes, 0);
            enc.copyBufferToBuffer(qRes, 0, qRead, 0, 16);
            g.submit(enc);
            ByteBuffer ts = g.readMapped(qRead, 16);
            if (r >= 5) per[r - 5] = (ts.getLong(8) - ts.getLong(0)) / 1e6 / K;
            upload(stateA, base);
        }
        return med(per);
    }

    static String neighborStats(float[] st) {
        long total = 0; int max = 0;
        for (int i = 0; i < N; i++) {
            int n = 0;
            for (int j = 0; j < N; j++) {
                if (j == i) continue;
                float dx = st[j * 8] - st[i * 8], dy = st[j * 8 + 1] - st[i * 8 + 1], dz = st[j * 8 + 2] - st[i * 8 + 2];
                if (dx * dx + dy * dy + dz * dz < R * R) n++;
            }
            total += n; max = Math.max(max, n);
        }
        return "mean=" + (total / (double) N) + " max=" + max;
    }

    static double timePack() {
        double[] per = new double[40];
        for (int r = 0; r < 45; r++) {
            WGPUCommandEncoder enc = ComputeSpike.encoder();
            WGPUComputePassDescriptor cd = new WGPUComputePassDescriptor();
            WGPUPassTimestampWrites tw = WGPUPassTimestampWrites.obtain();
            tw.setQuerySet(qs); tw.setBeginningOfPassWriteIndex(0); tw.setEndOfPassWriteIndex(1);
            cd.setTimestampWrites(tw);
            WGPUComputePassEncoder cp = new WGPUComputePassEncoder();
            enc.beginComputePass(cd, cp);
            for (int k = 0; k < 10; k++) { cp.setPipeline(pPack); cp.setBindGroup(0, gPackA); cp.setDispatchWorkgroups(groups(N), 1, 1); }
            cp.end(); cp.release();
            enc.resolveQuerySet(qs, 0, 2, qRes, 0);
            enc.copyBufferToBuffer(qRes, 0, qRead, 0, 16);
            g.submit(enc);
            ByteBuffer ts = g.readMapped(qRead, 16);
            if (r >= 5) per[r - 5] = (ts.getLong(8) - ts.getLong(0)) / 1e6 / 10;
        }
        return med(per);
    }

    // ---------- CPU（Float32 で 1 演算ずつ・総当たり） ----------
    static final float FIXED_ONE = 1073741824f, SEP_LIMIT = 10f, MIN_SEP_FRACTION = 0.1f;

    static int quantize(float x, float bound) {
        float c = Math.max(-1f, Math.min(1f, x / bound));
        return (int) Math.rint(c * FIXED_ONE);
    }

    static float[] cpuStep(float[] st) {
        float[] out = new float[st.length];
        float vb = Math.max(MAXS, 1e-6f) * 2f;
        for (int i = 0; i < N; i++) {
            float px = st[i * 8], py = st[i * 8 + 1], pz = st[i * 8 + 2];
            float vx = st[i * 8 + 4], vy = st[i * 8 + 5], vz = st[i * 8 + 6];
            long cx = 0, cy = 0, cz = 0, ax = 0, ay = 0, az = 0, sx = 0, sy = 0, sz = 0;
            int n = 0;
            for (int j = 0; j < N; j++) {
                if (j == i) continue;
                float dx = st[j * 8] - px, dy = st[j * 8 + 1] - py, dz = st[j * 8 + 2] - pz;
                float d2 = dx * dx + dy * dy + dz * dz;
                if (d2 >= R * R) continue;
                n++;
                cx += quantize(dx, R); cy += quantize(dy, R); cz += quantize(dz, R);
                ax += quantize(st[j * 8 + 4], vb); ay += quantize(st[j * 8 + 5], vb); az += quantize(st[j * 8 + 6], vb);
                if (d2 < SEP * SEP) {
                    float dmin = SEP * MIN_SEP_FRACTION;
                    float k = SEP / Math.max(d2, dmin * dmin);
                    sx += quantize(-dx * k, SEP_LIMIT); sy += quantize(-dy * k, SEP_LIMIT); sz += quantize(-dz * k, SEP_LIMIT);
                }
            }
            float tx = 0, ty = 0, tz = 0;
            if (n > 0) {
                float inv = 1f / n;
                float kc = R / FIXED_ONE * inv, ka = vb / FIXED_ONE * inv, ks = SEP_LIMIT / FIXED_ONE;
                tx = (float) cx * kc * COH + ((float) ax * ka - vx) * ALI + (float) sx * ks * SEPW;
                ty = (float) cy * kc * COH + ((float) ay * ka - vy) * ALI + (float) sy * ks * SEPW;
                tz = (float) cz * kc * COH + ((float) az * ka - vz) * ALI + (float) sz * ks * SEPW;
            }
            float l2 = tx * tx + ty * ty + tz * tz;
            if (l2 > MAXF * MAXF) { float k = MAXF / (float) Math.sqrt(l2); tx *= k; ty *= k; tz *= k; }
            float[] p = {px, py, pz}, v = {vx, vy, vz}, t = {tx, ty, tz};
            float m = Math.max(MARGIN, 1e-6f);
            for (int k = 0; k < 3; k++) {
                float low = Math.max(0f, Math.min(1f, (LO[k] + m - p[k]) / m));
                float high = Math.max(0f, Math.min(1f, (p[k] - (HI[k] - m)) / m));
                t[k] += (low - high) * MAXF;
                v[k] = v[k] + t[k] * DT;
            }
            float vl2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
            if (vl2 > MAXS * MAXS) { float k = MAXS / (float) Math.sqrt(vl2); v[0] *= k; v[1] *= k; v[2] *= k; }
            for (int k = 0; k < 3; k++) {
                float np = p[k] + v[k] * DT;
                if (np < LO[k]) v[k] = Math.abs(v[k]);
                if (np > HI[k]) v[k] = -Math.abs(v[k]);
                out[i * 8 + k] = Math.max(LO[k], Math.min(HI[k], np));
                out[i * 8 + 4 + k] = v[k];
            }
            out[i * 8 + 3] = 1f;
        }
        return out;
    }

    // ---------- 補助 ----------
    static void upload(WGPUBuffer b, float[] v) {
        ByteBuffer bb = direct(v.length * 4);
        for (float f : v) bb.putFloat(f);
        bb.flip();
        g.queue.writeBuffer(b, 0, bb, v.length * 4);
    }

    static float[] read(WGPUBuffer b, int floats) {
        WGPUBuffer r = g.buffer(floats * 4L, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        WGPUCommandEncoder enc = ComputeSpike.encoder();
        enc.copyBufferToBuffer(b, 0, r, 0, floats * 4);
        g.submit(enc);
        ByteBuffer bb = g.readMapped(r, floats * 4);
        float[] out = new float[floats];
        for (int i = 0; i < floats; i++) out[i] = bb.getFloat(i * 4);
        r.release();
        return out;
    }

    static int bytesDiffer(float[] a, float[] b) {
        int d = 0;
        for (int i = 0; i < a.length; i++) if (Float.floatToRawIntBits(a[i]) != Float.floatToRawIntBits(b[i])) d++;
        return d;
    }

    static double maxAbs(float[] a, float[] b) {
        double m = 0;
        for (int i = 0; i < a.length; i++) m = Math.max(m, Math.abs(a[i] - b[i]));
        return m;
    }

    static ByteBuffer direct(int n) { return ByteBuffer.allocateDirect(n).order(ByteOrder.LITTLE_ENDIAN); }

    static double med(double[] v) { double[] c = v.clone(); Arrays.sort(c); return c[c.length / 2]; }
}
