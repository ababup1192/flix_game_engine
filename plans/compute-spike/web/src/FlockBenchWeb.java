import fge.web.webgpu.BrowserWebGpu;
import fge.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import org.teavm.jso.JSBody;

/**
 * C0 の測り（ブラウザ）: engine の BrowserWebGpu と compute の API（C1）で、群れ 8,000 個を明示の layout で進める。
 * デスクトップの FlockBench と同じ kernel（FlockKernels）・同じ初めの状態・同じ規則。
 * 結果は window.__bench（bin/fge web-bench が読む形）と console に出す。
 */
public final class FlockBenchWeb {
    static WebGpu g;
    static int N = 8000;
    static final float[] LO = {-20f, -10f, -20f}, HI = {20f, 10f, 20f};
    static float R = 2f, SEP = 0.8f, COH = 0.5f, ALI = 1.5f, SEPW = 2f, MAXS = 5f, MAXF = 10f, MARGIN = 3f, DT = 1f / 60f;
    static boolean allOk = true;

    static Buffer params, stateA, stateB, cellCount, cellStart, cellSlot, sorted, sortedState, blockSums, instances;
    static ComputePipeline pCount, pScanBlocks, pScanSums, pScanAdd, pScatter, pGrid, pBrute, pPack;
    static BindGroup gCountA, gCountB, gScanBlocks, gScanSums, gScanAdd, gScatterA, gScatterB, gGridA, gGridB, gBruteAB, gBruteBA;
    static int gx, gy, gz;

    public static void main(String[] args) {
        benchInit();
        try {
            double t0 = now();
            g = BrowserWebGpu.open();
            result("init", true, "ms=" + fmt(now() - t0) + " timestamps=" + g.hasTimestampQuery() + " adapter=" + g.adapterInfo());
            setup();
            float[] init = FlockState.initialState(N, 7, LO, HI, MAXS);
            upload(stateA, init); runSteps(false, 1); float[] grid1 = read(stateB);
            upload(stateA, init); runSteps(true, 1); float[] brute1 = read(stateB);
            result("grid==brute-1", bytesDiffer(grid1, brute1) == 0, "differing=" + bytesDiffer(grid1, brute1));
            upload(stateA, init); runSteps(false, 60); float[] grid60 = read(stateA);
            upload(stateA, init); runSteps(false, 60); float[] grid60b = read(stateA);
            upload(stateA, init); runSteps(true, 60); float[] brute60 = read(stateA);
            result("grid==brute-60", true, "differing=" + bytesDiffer(grid60, brute60));
            result("grid-twice-60", bytesDiffer(grid60, grid60b) == 0, "differing=" + bytesDiffer(grid60, grid60b));
            if (g.hasTimestampQuery()) {
                upload(stateA, init);
                result("time-grid-initial", true, "per-step ms=" + fmt4(timeSteps(false, 4)));
                upload(stateA, init);
                result("time-brute-initial", true, "per-step ms=" + fmt4(timeSteps(true, 4)));
                upload(stateA, init); runSteps(false, 600);
                float[] steady = read(stateA);
                upload(stateA, steady);
                result("time-grid-steady", true, "per-step ms=" + fmt4(timeSteps(false, 4)));
                upload(stateA, steady);
                result("time-brute-steady", true, "per-step ms=" + fmt4(timeSteps(true, 4)));
            }
            double[] pw = new double[5];
            for (int r = 0; r < pw.length; r++) {
                upload(stateA, init);
                g.waitIdle();
                double a = now();
                runSteps(false, 720);
                pw[r] = now() - a;
            }
            result("prewarm-720", true, "wall median ms=" + fmt(med(pw)));
            result("gpu-errors", g.errorCount() == 0, "count=" + g.errorCount() + " " + g.lastError());
            result("all", allOk, "");
        } catch (Throwable e) {
            result("error", false, String.valueOf(e));
        }
        benchDone();
    }

    static void setup() {
        gx = Math.max(1, Math.min(32, (int) Math.floor((HI[0] - LO[0]) / R)));
        gy = Math.max(1, Math.min(32, (int) Math.floor((HI[1] - LO[1]) / R)));
        gz = Math.max(1, Math.min(32, (int) Math.floor((HI[2] - LO[2]) / R)));
        params = g.createBuffer("params", FlockKernels.PARAMS_BYTES, BufferUsage.UNIFORM | BufferUsage.COPY_DST);
        int st = BufferUsage.STORAGE | BufferUsage.COPY_DST | BufferUsage.COPY_SRC;
        stateA = g.createBuffer("stateA", N * 32L, st);
        stateB = g.createBuffer("stateB", N * 32L, st);
        cellCount = g.createBuffer("cellCount", FlockKernels.MAX_CELLS * 4L, st);
        cellStart = g.createBuffer("cellStart", (FlockKernels.MAX_CELLS + 1) * 4L, st);
        cellSlot = g.createBuffer("cellSlot", N * 8L, st);
        sorted = g.createBuffer("sortedId", N * 4L, st);
        sortedState = g.createBuffer("sortedState", N * 32L, st);
        blockSums = g.createBuffer("blockSums", FlockKernels.SCAN_BLOCKS * 4L, st);
        instances = g.createBuffer("instances", N * 128L, st | BufferUsage.VERTEX);
        ByteBuffer b = ByteBuffer.allocateDirect(FlockKernels.PARAMS_BYTES).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(N).putInt(gx).putInt(gy).putInt(gz);
        b.putFloat(LO[0]).putFloat(LO[1]).putFloat(LO[2]).putFloat(DT);
        b.putFloat(HI[0]).putFloat(HI[1]).putFloat(HI[2]).putFloat(R);
        b.putFloat((HI[0] - LO[0]) / gx).putFloat((HI[1] - LO[1]) / gy).putFloat((HI[2] - LO[2]) / gz).putFloat(SEP);
        b.putFloat(0).putFloat(0).putFloat(0).putFloat(0);
        b.putFloat(COH).putFloat(ALI).putFloat(SEPW).putFloat(MAXS);
        b.putFloat(MAXF).putFloat(MARGIN).putInt(0).putFloat(1f);
        g.writeBuffer(params, 0, b, 0, FlockKernels.PARAMS_BYTES);

        BufferBindingType U = BufferBindingType.UNIFORM, RO = BufferBindingType.READ_ONLY_STORAGE, RW = BufferBindingType.STORAGE;
        BindGroupLayout lCount = layout(U, RO, RW, RW), lScanBlocks = layout(U, RO, RW, RW), lScanSums = layout(U, RW),
            lScanAdd = layout(U, RW, RO, RW), lScatter = layout(U, RO, RO, RO, RW, RW), lGrid = layout(U, RO, RO, RO, RW),
            lBrute = layout(U, RO, RW), lPack = layout(U, RO, RW);
        pCount = pipeline(FlockKernels.COUNT, lCount);
        pScanBlocks = pipeline(FlockKernels.SCAN_BLOCKS_WGSL, lScanBlocks);
        pScanSums = pipeline(FlockKernels.SCAN_SUMS, lScanSums);
        pScanAdd = pipeline(FlockKernels.SCAN_ADD, lScanAdd);
        pScatter = pipeline(FlockKernels.SCATTER, lScatter);
        pGrid = pipeline(FlockKernels.RULES_GRID, lGrid);
        pBrute = pipeline(FlockKernels.RULES_BRUTE, lBrute);
        pPack = pipeline(FlockKernels.PACK, lPack);
        long P = FlockKernels.PARAMS_BYTES, S = N * 32L, C = FlockKernels.MAX_CELLS * 4L, C1 = C + 4, B = FlockKernels.SCAN_BLOCKS * 4L;
        gCountA = group(lCount, params, P, stateA, S, cellCount, C, cellSlot, N * 8L);
        gCountB = group(lCount, params, P, stateB, S, cellCount, C, cellSlot, N * 8L);
        gScanBlocks = group(lScanBlocks, params, P, cellCount, C, cellStart, C1, blockSums, B);
        gScanSums = group(lScanSums, params, P, blockSums, B);
        gScanAdd = group(lScanAdd, params, P, cellStart, C1, blockSums, B, cellCount, C);
        gScatterA = group(lScatter, params, P, stateA, S, cellSlot, N * 8L, cellStart, C1, sortedState, S, sorted, N * 4L);
        gScatterB = group(lScatter, params, P, stateB, S, cellSlot, N * 8L, cellStart, C1, sortedState, S, sorted, N * 4L);
        gGridA = group(lGrid, params, P, sortedState, S, sorted, N * 4L, cellStart, C1, stateA, S);
        gGridB = group(lGrid, params, P, sortedState, S, sorted, N * 4L, cellStart, C1, stateB, S);
        gBruteAB = group(lBrute, params, P, stateA, S, stateB, S);
        gBruteBA = group(lBrute, params, P, stateB, S, stateA, S);
    }

    static BindGroupLayout layout(BufferBindingType... types) {
        BindGroupLayoutDesc d = new BindGroupLayoutDesc("flock");
        for (int i = 0; i < types.length; i++) d.buffer(i, ShaderStage.COMPUTE, types[i]);
        return g.createBindGroupLayout(d);
    }

    static ComputePipeline pipeline(String wgsl, BindGroupLayout l) {
        return g.createComputePipeline(new ComputePipelineDesc("flock").bindGroupLayout(l).compute(g.createShaderModule("flock", wgsl), "cs_main"));
    }

    static BindGroup group(BindGroupLayout l, Object... pairs) {
        BindGroupDesc d = new BindGroupDesc("flock", l);
        for (int i = 0; i < pairs.length / 2; i++) d.buffer(i, (Buffer) pairs[i * 2], 0, (Long) pairs[i * 2 + 1]);
        return g.createBindGroup(d);
    }

    static int groups(int n) { return (n + 63) / 64; }

    static void encodeStep(ComputePass cp, boolean brute, int s) {
        boolean ab = s % 2 == 0;
        if (brute) { cp.setPipeline(pBrute); cp.setBindGroup(0, ab ? gBruteAB : gBruteBA); cp.dispatchWorkgroups(groups(N), 1, 1); return; }
        cp.setPipeline(pCount); cp.setBindGroup(0, ab ? gCountA : gCountB); cp.dispatchWorkgroups(groups(N), 1, 1);
        cp.setPipeline(pScanBlocks); cp.setBindGroup(0, gScanBlocks); cp.dispatchWorkgroups(FlockKernels.SCAN_BLOCKS, 1, 1);
        cp.setPipeline(pScanSums); cp.setBindGroup(0, gScanSums); cp.dispatchWorkgroups(1, 1, 1);
        cp.setPipeline(pScanAdd); cp.setBindGroup(0, gScanAdd); cp.dispatchWorkgroups(FlockKernels.MAX_CELLS / 64, 1, 1);
        cp.setPipeline(pScatter); cp.setBindGroup(0, ab ? gScatterA : gScatterB); cp.dispatchWorkgroups(groups(N), 1, 1);
        cp.setPipeline(pGrid); cp.setBindGroup(0, ab ? gGridB : gGridA); cp.dispatchWorkgroups(groups(N), 1, 1);
    }

    static void runSteps(boolean brute, int steps) {
        CommandEncoder enc = g.createCommandEncoder("flock");
        ComputePass cp = enc.beginComputePass("flock", null, 0, 0);
        for (int s = 0; s < steps; s++) encodeStep(cp, brute, s);
        cp.end();
        g.submit(enc.finish());
        g.waitIdle();
    }

    static QuerySet qs;
    static Buffer qRes, qRead;

    static double timeSteps(boolean brute, int K) {
        if (qs == null) {
            qs = g.createTimestampQuerySet("flock ts", 2);
            qRes = g.createBuffer("ts", 16, BufferUsage.QUERY_RESOLVE | BufferUsage.COPY_SRC);
            qRead = g.createBuffer("ts read", 16, BufferUsage.COPY_DST | BufferUsage.MAP_READ);
        }
        float[] base = read(stateA);
        double[] per = new double[20];
        ByteBuffer ts = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN);
        for (int r = 0; r < 25; r++) {
            CommandEncoder enc = g.createCommandEncoder("flock ts");
            ComputePass cp = enc.beginComputePass("flock ts", qs, 0, 1);
            for (int s = 0; s < K; s++) encodeStep(cp, brute, s);
            cp.end();
            enc.resolveQuerySet(qs, 0, 2, qRes, 0);
            enc.copyBufferToBuffer(qRes, 0, qRead, 0, 16);
            g.submit(enc.finish());
            g.readBuffer(qRead, 0, 16, ts);
            if (r >= 5) per[r - 5] = (ts.getLong(8) - ts.getLong(0)) / 1e6 / K;
            upload(stateA, base);
        }
        return med(per);
    }

    static void upload(Buffer b, float[] v) {
        ByteBuffer bb = ByteBuffer.allocateDirect(v.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < v.length; i++) bb.putFloat(i * 4, v[i]);
        g.writeBuffer(b, 0, bb, 0, v.length * 4);
    }

    static float[] read(Buffer b) {
        int bytes = N * 32;
        Buffer r = g.createBuffer("read", bytes, BufferUsage.COPY_DST | BufferUsage.MAP_READ);
        CommandEncoder enc = g.createCommandEncoder("read");
        enc.copyBufferToBuffer(b, 0, r, 0, bytes);
        g.submit(enc.finish());
        ByteBuffer bb = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN);
        g.readBuffer(r, 0, bytes, bb);
        r.destroy();
        float[] out = new float[N * 8];
        for (int i = 0; i < out.length; i++) out[i] = bb.getFloat(i * 4);
        return out;
    }

    static int bytesDiffer(float[] a, float[] b) {
        int d = 0;
        for (int i = 0; i < a.length; i++) if (Float.floatToRawIntBits(a[i]) != Float.floatToRawIntBits(b[i])) d++;
        return d;
    }

    static double med(double[] v) { double[] c = v.clone(); Arrays.sort(c); return c[c.length / 2]; }
    static String fmt(double v) { return String.valueOf(Math.round(v * 1000) / 1000.0); }
    static String fmt4(double v) { return String.valueOf(Math.round(v * 10000) / 10000.0); }

    static void result(String name, boolean ok, String detail) {
        if (!ok) allOk = false;
        benchResult(name, ok, detail);
    }

    @JSBody(script = "return performance.now();")
    static native double now();

    @JSBody(script = "window.__bench = { query: location.search, env: { ua: navigator.userAgent }, results: [], done: false };")
    static native void benchInit();

    @JSBody(params = {"name", "ok", "detail"}, script =
        "window.__bench.results.push({ name: name, ok: ok, detail: detail }); console.log('[bench] result ' + name + ' ' + (ok ? 'OK' : 'NG') + ' ' + detail);")
    static native void benchResult(String name, boolean ok, String detail);

    @JSBody(script = "window.__bench.done = true;")
    static native void benchDone();
}
