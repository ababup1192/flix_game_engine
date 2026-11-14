import com.github.xpenatan.webgpu.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public class Jni {
    public static void main(String[] a) throws Exception {
        JWebGPUBackend be = a.length > 0 && a[0].equals("dawn") ? JWebGPUBackend.DAWN : JWebGPUBackend.WGPU;
        Gpu g = Gpu.init(be);
        WGPUVectorInt v = WGPUVectorInt.obtain();
        for (int rep = 0; rep < 5; rep++) {
            int n = 5_000_000;
            long t0 = System.nanoTime();
            for (int i = 0; i < n; i++) { v.clear(); v.push_back(i); }
            long t1 = System.nanoTime();
            if (rep >= 3) System.out.printf("RESULT jni %s vector clear+push_back: %.1f ns per pair (%.1f ns per call)%n", be, (t1 - t0) / (double) n, (t1 - t0) / (2.0 * n));
        }
        // writeBuffer の代金（direct ByteBuffer）
        for (int mb : new int[]{1, 5, 20}) {
            int size = mb << 20;
            WGPUBuffer buf = g.buffer(size, WGPUBufferUsage.Storage.or(WGPUBufferUsage.CopyDst));
            ByteBuffer bb = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN);
            double[] t = new double[50];
            for (int i = 0; i < 60; i++) {
                long s = System.nanoTime();
                g.queue.writeBuffer(buf, 0, bb, size);
                if (i >= 10) t[i - 10] = (System.nanoTime() - s) / 1e6;
                if (i % 5 == 0) g.waitIdle();
            }
            java.util.Arrays.sort(t);
            System.out.printf("RESULT jni %s writeBuffer %d MB direct: median %.3f ms (%.1f GB/s)%n", be, mb, t[25], mb / 1024.0 / (t[25] / 1000));
        }
        System.exit(0);
    }
}
