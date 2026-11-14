import com.github.xpenatan.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Arrays;

/** 小さな四角を N 個、1 個ずつ別 draw・別行列で描く 1 コマの CPU 時間。 */
public class Bench {
    static final int TARGET = 1024;
    static final String COMMON = """
        struct VOut { @builtin(position) pos: vec4f, @location(0) col: vec4f };
        fn corner(i: u32) -> vec2f {
            var c = array<vec2f, 6>(vec2f(-1,-1), vec2f(1,-1), vec2f(1,1), vec2f(-1,-1), vec2f(1,1), vec2f(-1,1));
            return c[i];
        }
        @fragment fn fs_main(v: VOut) -> @location(0) vec4f { return v.col; }
        """;
    static final String DYN = COMMON + """
        struct U { m: mat4x4f };
        @group(0) @binding(0) var<uniform> u: U;
        @vertex fn vs_main(@builtin(vertex_index) i: u32) -> VOut {
            var o: VOut;
            o.pos = u.m * vec4f(corner(i), 0.0, 1.0);
            o.col = vec4f(u.m[3].xy * 0.5 + 0.5, 0.5, 1.0);
            return o;
        }
        """;
    static final String STO = COMMON + """
        @group(0) @binding(0) var<storage, read> ms: array<mat4x4f>;
        @vertex fn vs_main(@builtin(vertex_index) i: u32, @builtin(instance_index) k: u32) -> VOut {
            var o: VOut;
            let m = ms[k];
            o.pos = m * vec4f(corner(i), 0.0, 1.0);
            o.col = vec4f(m[3].xy * 0.5 + 0.5, 0.5, 1.0);
            return o;
        }
        """;

    static void fill(FloatBuffer fb, int n, int stridePerMatFloats, float phase) {
        int side = (int) Math.ceil(Math.sqrt(n));
        float s = 0.8f / side;
        for (int k = 0; k < n; k++) {
            float tx = ((k % side) + 0.5f) / side * 2f - 1f + phase * 0.0001f;
            float ty = ((k / side) + 0.5f) / side * 2f - 1f;
            int o = k * stridePerMatFloats;
            fb.put(o, s); fb.put(o + 1, 0); fb.put(o + 2, 0); fb.put(o + 3, 0);
            fb.put(o + 4, 0); fb.put(o + 5, s); fb.put(o + 6, 0); fb.put(o + 7, 0);
            fb.put(o + 8, 0); fb.put(o + 9, 0); fb.put(o + 10, 1); fb.put(o + 11, 0);
            fb.put(o + 12, tx); fb.put(o + 13, ty); fb.put(o + 14, 0); fb.put(o + 15, 1);
        }
    }

    static double median(double[] a) { double[] c = a.clone(); Arrays.sort(c); return c[c.length / 2]; }

    public static void main(String[] a) throws Exception {
        String mode = a[0]; // dyn | sto | gl
        JWebGPUBackend be = a.length > 1 && a[1].equals("dawn") ? JWebGPUBackend.DAWN : JWebGPUBackend.WGPU;
        int[] Ns = {1000, 5000, 20000};
        if (mode.equals("gl")) { GlBench.run(Ns); return; }
        Gpu g = Gpu.init(be);
        int W = TARGET;
        WGPUTextureDescriptor td = WGPUTextureDescriptor.obtain();
        td.setUsage(WGPUTextureUsage.RenderAttachment.or(WGPUTextureUsage.CopySrc));
        td.setDimension(WGPUTextureDimension._2D);
        td.getSize().setWidth(W); td.getSize().setHeight(W); td.getSize().setDepthOrArrayLayers(1);
        td.setFormat(WGPUTextureFormat.RGBA8Unorm);
        td.setMipLevelCount(1); td.setSampleCount(1);
        WGPUTexture tex = new WGPUTexture();
        g.device.createTexture(td, tex);
        WGPUTextureView view = new WGPUTextureView();
        tex.createView(WGPUTextureViewDescriptor.NULL, view);

        boolean dyn = mode.equals("dyn");
        for (int N : Ns) {
            int stride = dyn ? 256 : 64;
            long size = (long) N * stride;
            WGPUBuffer buf = g.buffer(size, (dyn ? WGPUBufferUsage.Uniform : WGPUBufferUsage.Storage).or(WGPUBufferUsage.CopyDst));
            WGPUBufferBindingLayout bl = WGPUBufferBindingLayout.obtain();
            bl.setType(dyn ? WGPUBufferBindingType.Uniform : WGPUBufferBindingType.ReadOnlyStorage);
            bl.setHasDynamicOffset(dyn ? 1 : 0);
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
            WGPUVectorBindGroupLayout bgls = WGPUVectorBindGroupLayout.obtain();
            bgls.push_back(bgl);
            WGPUPipelineLayoutDescriptor pld = WGPUPipelineLayoutDescriptor.obtain();
            pld.setBindGroupLayouts(bgls);
            WGPUPipelineLayout pl = new WGPUPipelineLayout();
            g.device.createPipelineLayout(pld, pl);
            WGPUBindGroupEntry be0 = WGPUBindGroupEntry.obtain();
            be0.setBinding(0); be0.setBuffer(buf); be0.setOffset(0); be0.setSize(dyn ? 64 : size);
            WGPUVectorBindGroupEntry bes = WGPUVectorBindGroupEntry.obtain();
            bes.push_back(be0);
            WGPUBindGroupDescriptor bgd = WGPUBindGroupDescriptor.obtain();
            bgd.setLayout(bgl); bgd.setEntries(bes);
            WGPUBindGroup bg = new WGPUBindGroup();
            g.device.createBindGroup(bgd, bg);
            WGPUShaderModule sm = g.shader(dyn ? DYN : STO);
            WGPURenderPipeline pipe = g.pipeline(sm, WGPUTextureFormat.RGBA8Unorm, pl, false);

            ByteBuffer bb = ByteBuffer.allocateDirect((int) size).order(ByteOrder.LITTLE_ENDIAN);
            FloatBuffer fb = bb.asFloatBuffer();
            WGPUVectorInt offs = WGPUVectorInt.obtain();

            int warm = 40, meas = 100;
            double[] cpu = new double[meas], tot = new double[meas], fillT = new double[meas];
            for (int f = 0; f < warm + meas; f++) {
                long tf = System.nanoTime();
                fill(fb, N, stride / 4, f);
                long t0 = System.nanoTime();
                g.queue.writeBuffer(buf, 0, bb, (int) size);
                WGPUCommandEncoder enc = new WGPUCommandEncoder();
                g.device.createCommandEncoder(WGPUCommandEncoderDescriptor.NULL, enc);
                WGPURenderPassEncoder pass = g.beginPass(enc, view, 0.05f, 0.05f, 0.08f);
                pass.setPipeline(pipe);
                if (dyn) {
                    for (int k = 0; k < N; k++) {
                        offs.clear();
                        offs.push_back(k * 256);
                        pass.setBindGroup(0, bg, offs);
                        pass.draw(6, 1, 0, 0);
                    }
                } else {
                    pass.setBindGroup(0, bg);
                    pass.draw(6, N, 0, 0);
                }
                pass.end(); pass.release();
                g.submit(enc);
                long t1 = System.nanoTime();
                g.waitIdle();
                long t2 = System.nanoTime();
                if (f >= warm) { cpu[f - warm] = (t1 - t0) / 1e6; tot[f - warm] = (t2 - t0) / 1e6; fillT[f - warm] = (t0 - tf) / 1e6; }
            }
            double[] s1 = cpu.clone(); Arrays.sort(s1);
            System.out.printf("RESULT %s/%s N=%d cpu_submit_ms median=%.3f p90=%.3f | with_gpu_wait median=%.3f | fill(excluded) median=%.3f | us/object(cpu)=%.3f%n",
                mode, be, N, median(cpu), s1[meas * 9 / 10], median(tot), median(fillT), median(cpu) * 1000 / N);
        }
        System.exit(0);
    }
}
