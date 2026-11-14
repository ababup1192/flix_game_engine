import com.github.xpenatan.webgpu.*;
import org.lwjgl.system.MemoryUtil;

/**
 * jWebGPU 0.3.4 の癖を確かめる。
 *  limits: getter（int を返す）と、WGPULimits の native の中身を webgpu.h の並びで直に読んだ値を並べる。
 *  features: adapter と device の feature を、enum に名前の無い値（CUSTOM）も数で出す。
 */
public class Quirks {
    // webgpu.h（Dawn・2025 以降）の WGPULimits の並び。u64 は 8 バイト境界。
    static final Object[][] LAYOUT = {
        {"maxTextureDimension1D", 8, 4}, {"maxTextureDimension2D", 12, 4}, {"maxTextureDimension3D", 16, 4}, {"maxTextureArrayLayers", 20, 4},
        {"maxBindGroups", 24, 4}, {"maxBindGroupsPlusVertexBuffers", 28, 4}, {"maxBindingsPerBindGroup", 32, 4},
        {"maxDynamicUniformBuffersPerPipelineLayout", 36, 4}, {"maxDynamicStorageBuffersPerPipelineLayout", 40, 4},
        {"maxSampledTexturesPerShaderStage", 44, 4}, {"maxSamplersPerShaderStage", 48, 4}, {"maxStorageBuffersPerShaderStage", 52, 4},
        {"maxStorageTexturesPerShaderStage", 56, 4}, {"maxUniformBuffersPerShaderStage", 60, 4},
        {"maxUniformBufferBindingSize", 64, 8}, {"maxStorageBufferBindingSize", 72, 8},
        {"minUniformBufferOffsetAlignment", 80, 4}, {"minStorageBufferOffsetAlignment", 84, 4}, {"maxVertexBuffers", 88, 4},
        {"maxBufferSize", 96, 8}, {"maxVertexAttributes", 104, 4}, {"maxVertexBufferArrayStride", 108, 4},
        {"maxInterStageShaderVariables", 112, 4}, {"maxColorAttachments", 116, 4}, {"maxColorAttachmentBytesPerSample", 120, 4},
    };

    public static void main(String[] a) {
        Gpu g = Gpu.init(JWebGPUBackend.DAWN);
        WGPULimits al = new WGPULimits();
        WGPUStatus st = g.adapter.getLimits(al);
        WGPULimits dl = new WGPULimits();
        g.device.getLimits(dl);
        System.out.println("adapter.getLimits status=" + st + " native address adapter=0x" + Long.toHexString(al.native_address));
        System.out.printf("%-44s %14s %14s %16s %16s%n", "limit", "adapter.get", "device.get", "adapter.raw", "device.raw");
        for (Object[] f : LAYOUT) {
            String n = (String) f[0];
            int off = (Integer) f[1], sz = (Integer) f[2];
            String getter = "get" + Character.toUpperCase(n.charAt(0)) + n.substring(1);
            Object ga = call(al, getter), gd = call(dl, getter);
            long ra = sz == 8 ? MemoryUtil.memGetLong(al.native_address + off) : Integer.toUnsignedLong(MemoryUtil.memGetInt(al.native_address + off));
            long rd = sz == 8 ? MemoryUtil.memGetLong(dl.native_address + off) : Integer.toUnsignedLong(MemoryUtil.memGetInt(dl.native_address + off));
            System.out.printf("LIMIT %-38s %14s %14s %16d %16d%s%n", n, ga, gd, ra, rd,
                (ga instanceof Integer i && i.longValue() != ra) ? "   <- getter differs from raw" : "");
        }
        WGPUSupportedFeatures sf = new WGPUSupportedFeatures();
        g.device.getFeatures(sf);
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < sf.getFeatureCount(); i++) {
            WGPUFeatureName fn = sf.getFeatureAt(i);
            b.append(fn == WGPUFeatureName.CUSTOM ? "CUSTOM(0x" + Integer.toHexString(fn.getValue()) + ")" : fn.name()).append(' ');
        }
        System.out.println("DEVICE FEATURES (" + sf.getFeatureCount() + "): " + b);
        int known = 0;
        StringBuilder adapterHas = new StringBuilder();
        for (WGPUFeatureName fn : WGPUFeatureName.values()) {
            if (fn == WGPUFeatureName.CUSTOM || fn.name().equals("Force32")) continue;
            known++;
            if (g.adapter.hasFeature(fn)) adapterHas.append(fn.name()).append(' ');
        }
        System.out.println("ADAPTER hasFeature over " + known + " enum names: " + adapterHas);

        // 2 つ目の device: adapter の上限をそのまま requiredLimits に渡し、enum に無い feature（0x1）も数で要る。
        boolean[] done = {false};
        WGPUDevice[] dev2 = {null};
        WGPUDeviceDescriptor dd = WGPUDeviceDescriptor.obtain();
        dd.setRequiredLimits(al);
        WGPUVectorFeatureName fs = WGPUVectorFeatureName.obtain();
        fs.push_back(WGPUFeatureName.CUSTOM.setValue(Integer.getInteger("customFeature", 1)));
        fs.push_back(WGPUFeatureName.TimestampQuery);
        dd.setRequiredFeatures(fs);
        WGPURequestDeviceCallback cb = new WGPURequestDeviceCallback() {
            @Override protected void onCallback(WGPURequestDeviceStatus s, WGPUDevice d, String m) {
                System.out.println("device2 status " + s + " " + m);
                if (s == WGPURequestDeviceStatus.Success) dev2[0] = d;
                done[0] = true;
            }
        };
        WGPUUncapturedErrorCallback ecb = new WGPUUncapturedErrorCallback() {
            @Override protected void onCallback(WGPUErrorType t, String m) { System.err.println("GPU ERROR " + t + ": " + m); }
        };
        // Dawn は 1 つの adapter から device を 1 つしか作らせない（"consumed"）ので、adapter を取り直す。
        boolean[] adone = {false};
        WGPUAdapter[] ad2 = {null};
        WGPURequestAdapterCallback acb = new WGPURequestAdapterCallback() {
            @Override protected void onCallback(WGPURequestAdapterStatus s, WGPUAdapter ad, String m) { if (s == WGPURequestAdapterStatus.Success) ad2[0] = ad; adone[0] = true; }
        };
        g.instance.requestAdapter(WGPURequestAdapterOptions.obtain(), WGPUCallbackMode.AllowProcessEvents, acb);
        Gpu.pump(g, adone);
        ad2[0].requestDevice(dd, WGPUCallbackMode.AllowProcessEvents, cb, ecb);
        Gpu.pump(g, done);
        if (dev2[0] != null) {
            WGPULimits l2 = new WGPULimits();
            dev2[0].getLimits(l2);
            for (String n : new String[]{"maxTextureDimension2D", "maxStorageBufferBindingSize", "maxBufferSize", "maxSampledTexturesPerShaderStage"}) {
                for (Object[] f : LAYOUT) if (f[0].equals(n)) {
                    int off = (Integer) f[1], sz = (Integer) f[2];
                    long raw = sz == 8 ? MemoryUtil.memGetLong(l2.native_address + off) : Integer.toUnsignedLong(MemoryUtil.memGetInt(l2.native_address + off));
                    System.out.println("DEVICE2 " + n + " getter=" + call(l2, "get" + Character.toUpperCase(n.charAt(0)) + n.substring(1)) + " raw=" + raw);
                }
            }
            WGPUSupportedFeatures sf2 = new WGPUSupportedFeatures();
            dev2[0].getFeatures(sf2);
            StringBuilder b2 = new StringBuilder();
            for (int i = 0; i < sf2.getFeatureCount(); i++) {
                WGPUFeatureName fn = sf2.getFeatureAt(i);
                b2.append(fn == WGPUFeatureName.CUSTOM ? "CUSTOM(0x" + Integer.toHexString(fn.getValue()) + ")" : fn.name()).append(' ');
            }
            System.out.println("DEVICE2 FEATURES (" + sf2.getFeatureCount() + "): " + b2);
        }
        System.exit(0);
    }

    static Object call(Object o, String m) {
        try { return o.getClass().getMethod(m).invoke(o); } catch (Exception e) { return "n/a"; }
    }
}
