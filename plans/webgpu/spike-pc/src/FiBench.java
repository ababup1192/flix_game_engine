import com.github.xpenatan.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Arrays;

/**
 * 1 つの render pass に N 本の draw を積む形の 1 コマの代金。行は storage buffer に置き、instance_index で引く。
 *   inst   : draw(6, N, 0, 0) を 1 回
 *   fi     : draw(6, 1, 0, k) を N 回（firstInstance で行を選ぶ）
 *   fi_bg  : fi の各 draw の前に同じ bind group を setBindGroup し直す
 *   fi_mix : pipeline 2 本を 8 本ごとに切り替え、切り替えのたびに setBindGroup
 *   dyn    : uniform を dynamic offset で 1 本ずつ（setBindGroup を毎回呼ぶ形・前の試作の (a)）
 * usage: FiBench <mode,mode,...> [N,N,...]
 */
public class FiBench {
    static final int TARGET = 1024;
    static final String STO2 = Bench.STO.replace("return v.col;", "return v.col * vec4f(0.9, 0.9, 0.9, 1.0);");

    public static void main(String[] a) throws Exception {
        String[] modes = a[0].split(",");
        int[] Ns = a.length > 1 ? Arrays.stream(a[1].split(",")).mapToInt(Integer::parseInt).toArray() : new int[]{1000, 5000, 20000};
        int warm = Integer.getInteger("warm", 40), meas = Integer.getInteger("meas", 200);
        Gpu g = Gpu.init(JWebGPUBackend.DAWN, true);
        System.out.println("timestamp-query=" + g.timestamps);
        WGPUTextureDescriptor td = WGPUTextureDescriptor.obtain();
        td.setUsage(WGPUTextureUsage.RenderAttachment.or(WGPUTextureUsage.CopySrc));
        td.setDimension(WGPUTextureDimension._2D);
        td.getSize().setWidth(TARGET); td.getSize().setHeight(TARGET); td.getSize().setDepthOrArrayLayers(1);
        td.setFormat(WGPUTextureFormat.RGBA8Unorm);
        td.setMipLevelCount(1); td.setSampleCount(1);
        WGPUTexture tex = new WGPUTexture();
        g.device.createTexture(td, tex);
        WGPUTextureView view = new WGPUTextureView();
        tex.createView(WGPUTextureViewDescriptor.NULL, view);

        WGPUQuerySet qs = null;
        WGPUBuffer qResolve = null, qRead = null;
        if (g.timestamps) {
            WGPUQuerySetDescriptor qd = WGPUQuerySetDescriptor.obtain();
            qd.setType(WGPUQueryType.Timestamp); qd.setCount(2);
            qs = new WGPUQuerySet();
            g.device.createQuerySet(qd, qs);
            qResolve = g.buffer(16, WGPUBufferUsage.QueryResolve.or(WGPUBufferUsage.CopySrc));
            qRead = g.buffer(16, WGPUBufferUsage.CopyDst.or(WGPUBufferUsage.MapRead));
        }

        for (int N : Ns) {
            for (String mode : modes) {
                boolean dyn = mode.equals("dyn");
                int stride = dyn ? 256 : 64;
                long size = (long) N * stride;
                WGPUBuffer buf = g.buffer(size, (dyn ? WGPUBufferUsage.Uniform : WGPUBufferUsage.Storage).or(WGPUBufferUsage.CopyDst));
                WGPUBindGroupLayout bgl = layout(g, dyn);
                WGPUVectorBindGroupLayout bgls = WGPUVectorBindGroupLayout.obtain();
                bgls.push_back(bgl);
                WGPUPipelineLayoutDescriptor pld = WGPUPipelineLayoutDescriptor.obtain();
                pld.setBindGroupLayouts(bgls);
                WGPUPipelineLayout pl = new WGPUPipelineLayout();
                g.device.createPipelineLayout(pld, pl);
                WGPUBindGroupEntry e0 = WGPUBindGroupEntry.obtain();
                e0.setBinding(0); e0.setBuffer(buf); e0.setOffset(0); e0.setSize(dyn ? 64 : size);
                WGPUVectorBindGroupEntry es = WGPUVectorBindGroupEntry.obtain();
                es.push_back(e0);
                WGPUBindGroupDescriptor bgd = WGPUBindGroupDescriptor.obtain();
                bgd.setLayout(bgl); bgd.setEntries(es);
                WGPUBindGroup bg = new WGPUBindGroup();
                g.device.createBindGroup(bgd, bg);
                WGPURenderPipeline pipe = g.pipeline(g.shader(dyn ? Bench.DYN : Bench.STO), WGPUTextureFormat.RGBA8Unorm, pl, false);
                WGPURenderPipeline pipe2 = mode.equals("fi_mix") ? g.pipeline(g.shader(STO2), WGPUTextureFormat.RGBA8Unorm, pl, false) : null;

                ByteBuffer bb = ByteBuffer.allocateDirect((int) size).order(ByteOrder.LITTLE_ENDIAN);
                FloatBuffer fb = bb.asFloatBuffer();
                Bench.fill(fb, N, stride / 4, 0);
                WGPUVectorInt offs = WGPUVectorInt.obtain();
                double[] wb = new double[meas], enc = new double[meas], sub = new double[meas], gpu = new double[meas], wait = new double[meas];
                for (int f = 0; f < warm + meas; f++) {
                    long t0 = System.nanoTime();
                    g.queue.writeBuffer(buf, 0, bb, (int) size);
                    long t1 = System.nanoTime();
                    WGPUCommandEncoder ce = new WGPUCommandEncoder();
                    g.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, ce);
                    WGPURenderPassEncoder pass = g.beginPass(ce, view, 0.05f, 0.05f, 0.08f, qs);
                    pass.setPipeline(pipe);
                    switch (mode) {
                        case "inst" -> { pass.setBindGroup(0, bg); pass.draw(6, N, 0, 0); }
                        case "fi" -> { pass.setBindGroup(0, bg); for (int k = 0; k < N; k++) pass.draw(6, 1, 0, k); }
                        case "fi_bg" -> { for (int k = 0; k < N; k++) { pass.setBindGroup(0, bg); pass.draw(6, 1, 0, k); } }
                        case "fi_mix" -> {
                            for (int k = 0; k < N; k++) {
                                if (k % 8 == 0) { pass.setPipeline((k / 8) % 2 == 0 ? pipe : pipe2); pass.setBindGroup(0, bg); }
                                pass.draw(6, 1, 0, k);
                            }
                        }
                        case "dyn" -> {
                            for (int k = 0; k < N; k++) { offs.clear(); offs.push_back(k * 256); pass.setBindGroup(0, bg, offs); pass.draw(6, 1, 0, 0); }
                        }
                        default -> throw new IllegalArgumentException(mode);
                    }
                    pass.end(); pass.release();
                    if (qs != null) ce.resolveQuerySet(qs, 0, 2, qResolve, 0);
                    if (qs != null) ce.copyBufferToBuffer(qResolve, 0, qRead, 0, 16);
                    long t2 = System.nanoTime();
                    g.submit(ce);
                    long t3 = System.nanoTime();
                    double gms = Double.NaN;
                    if (qs != null) {
                        ByteBuffer ts = g.readMapped(qRead, 16);
                        gms = (ts.getLong(8) - ts.getLong(0)) / 1e6;
                    } else g.waitIdle();
                    long t4 = System.nanoTime();
                    if (f >= warm) {
                        int i = f - warm;
                        wb[i] = (t1 - t0) / 1e6; enc[i] = (t2 - t1) / 1e6; sub[i] = (t3 - t2) / 1e6; gpu[i] = gms; wait[i] = (t4 - t3) / 1e6;
                    }
                }
                long hash = imageHash(g, tex);
                System.out.printf("RESULT fi %s N=%d frames=%d | writeBuffer med=%.3f | encode med=%.3f p90=%.3f | finish+submit med=%.3f | cpu(enc+submit) med=%.3f | gpu pass med=%.3f p90=%.3f | wait med=%.3f | img=%016x%n",
                    mode, N, meas, med(wb), med(enc), pct(enc, 0.9), med(sub), med(sum(enc, sub)), med(gpu), pct(gpu, 0.9), med(wait), hash);
                buf.release();
            }
        }
        System.out.println("gpuErrors=" + Gpu.errors);
        System.exit(0);
    }

    static WGPUBindGroupLayout layout(Gpu g, boolean dyn) {
        WGPUBufferBindingLayout bl = WGPUBufferBindingLayout.obtain();
        bl.setType(dyn ? WGPUBufferBindingType.Uniform : WGPUBufferBindingType.ReadOnlyStorage);
        bl.setHasDynamicOffset(dyn ? 1 : 0);
        bl.setMinBindingSize(0);
        WGPUBindGroupLayoutEntry le = WGPUBindGroupLayoutEntry.obtain();
        le.setBinding(0);
        le.setVisibility(WGPUShaderStage.Vertex);
        le.setBuffer(bl);
        WGPUVectorBindGroupLayoutEntry les = WGPUVectorBindGroupLayoutEntry.obtain();
        les.push_back(le);
        WGPUBindGroupLayoutDescriptor bld = WGPUBindGroupLayoutDescriptor.obtain();
        bld.setEntries(les);
        WGPUBindGroupLayout bgl = new WGPUBindGroupLayout();
        g.device.createBindGroupLayout(bld, bgl);
        return bgl;
    }

    /** 描いた絵の FNV-1a。inst と fi が同じ絵を描いたかを見る。 */
    static long imageHash(Gpu g, WGPUTexture tex) {
        ByteBuffer px = g.readTexture(tex, TARGET, TARGET);
        long h = 0xcbf29ce484222325L;
        for (int i = 0; i < px.capacity(); i++) { h ^= px.get(i) & 0xff; h *= 0x100000001b3L; }
        return h;
    }

    static double[] sum(double[] x, double[] y) { double[] r = new double[x.length]; for (int i = 0; i < x.length; i++) r[i] = x[i] + y[i]; return r; }
    static double med(double[] x) { return pct(x, 0.5); }
    static double pct(double[] x, double p) { double[] c = x.clone(); Arrays.sort(c); return c[(int) Math.min(c.length - 1, c.length * p)]; }
}
