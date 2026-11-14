import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

import static java.lang.foreign.ValueLayout.*;

/**
 * webgpu.h の C の API を Panama（FFM）で直に呼ぶ小さな確かめ。jextract は使わず、使う struct だけ手で並べる。
 * JDK 21 では FFM は preview（--enable-preview）。JDK 22 からは同じ書き方で preview 無し（getUtf8String が getString に変わる）。
 * usage: java --enable-preview --source 21 FfmProbe.java <libwebgpu の dylib>
 */
public class FfmProbe {
    static final Linker L = Linker.nativeLinker();
    static final StructLayout STRING_VIEW = MemoryLayout.structLayout(ADDRESS.withName("data"), JAVA_LONG.withName("length"));
    // WGPURequestAdapterCallbackInfo { nextInChain*, mode(u32)+pad, callback*, userdata1*, userdata2* }
    static final StructLayout CB_INFO = MemoryLayout.structLayout(ADDRESS, JAVA_INT, MemoryLayout.paddingLayout(4), ADDRESS, ADDRESS, ADDRESS);
    static final StructLayout FUTURE = MemoryLayout.structLayout(JAVA_LONG);
    static volatile MemorySegment adapter = MemorySegment.NULL;
    static volatile boolean done;

    static void onAdapter(int status, MemorySegment ad, MemorySegment message, MemorySegment u1, MemorySegment u2) {
        adapter = ad;
        done = true;
        System.out.println("adapter callback status=" + status);
    }

    public static void main(String[] a) throws Throwable {
        try (Arena arena = Arena.ofConfined()) {
            SymbolLookup lib = SymbolLookup.libraryLookup(a[0], arena);
            MethodHandle createInstance = L.downcallHandle(lib.find("wgpuCreateInstance").orElseThrow(), FunctionDescriptor.of(ADDRESS, ADDRESS));
            MethodHandle requestAdapter = L.downcallHandle(lib.find("wgpuInstanceRequestAdapter").orElseThrow(), FunctionDescriptor.of(FUTURE, ADDRESS, ADDRESS, CB_INFO));
            MethodHandle processEvents = L.downcallHandle(lib.find("wgpuInstanceProcessEvents").orElseThrow(), FunctionDescriptor.ofVoid(ADDRESS));
            MethodHandle getInfo = L.downcallHandle(lib.find("wgpuAdapterGetInfo").orElseThrow(), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));
            MethodHandle getLimits = L.downcallHandle(lib.find("wgpuAdapterGetLimits").orElseThrow(), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));

            MemorySegment inst = (MemorySegment) createInstance.invokeExact(MemorySegment.NULL);
            System.out.println("instance=" + inst);
            MethodHandle cbTarget = MethodHandles.lookup().findStatic(FfmProbe.class, "onAdapter",
                MethodType.methodType(void.class, int.class, MemorySegment.class, MemorySegment.class, MemorySegment.class, MemorySegment.class));
            MemorySegment cbStub = L.upcallStub(cbTarget, FunctionDescriptor.ofVoid(JAVA_INT, ADDRESS, STRING_VIEW, ADDRESS, ADDRESS), arena);
            MemorySegment info = arena.allocate(CB_INFO);
            info.set(JAVA_INT, 8, 2); // WGPUCallbackMode_AllowProcessEvents
            info.set(ADDRESS, 16, cbStub);
            MemorySegment fut = (MemorySegment) requestAdapter.invokeExact((SegmentAllocator) arena, inst, MemorySegment.NULL, info);
            long t0 = System.nanoTime();
            while (!done && System.nanoTime() - t0 < 5_000_000_000L) processEvents.invokeExact(inst);
            if (adapter.equals(MemorySegment.NULL)) throw new IllegalStateException("no adapter");

            MemorySegment ai = arena.allocate(256, 8);
            int st = (int) getInfo.invokeExact(adapter, ai);
            String device = str(ai.asSlice(8 + 16 * 2, 16));
            String desc = str(ai.asSlice(8 + 16 * 3, 16));
            int backend = ai.get(JAVA_INT, 8 + 16 * 4);
            System.out.println("RESULT ffm info status=" + st + " device=" + device + " desc=" + desc + " backendType=0x" + Integer.toHexString(backend));

            MemorySegment lim = arena.allocate(512, 8);
            int sl = (int) getLimits.invokeExact(adapter, lim);
            System.out.println("RESULT ffm limits status=" + sl + " maxTextureDimension2D=" + Integer.toUnsignedLong(lim.get(JAVA_INT, 12))
                + " maxStorageBufferBindingSize=" + lim.get(JAVA_LONG, 72) + " maxBufferSize=" + lim.get(JAVA_LONG, 96));
        }
    }

    static String str(MemorySegment sv) {
        MemorySegment p = sv.get(ADDRESS, 0);
        long n = sv.get(JAVA_LONG, 8);
        if (p.equals(MemorySegment.NULL)) return "";
        byte[] b = p.reinterpret(n == -1 ? 4096 : n).toArray(JAVA_BYTE);
        int len = n == -1 ? indexOfZero(b) : b.length;
        return new String(b, 0, len, java.nio.charset.StandardCharsets.UTF_8);
    }

    static int indexOfZero(byte[] b) { for (int i = 0; i < b.length; i++) if (b[i] == 0) return i; return b.length; }
}
