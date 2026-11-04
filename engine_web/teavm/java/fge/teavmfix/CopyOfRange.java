package fge.teavmfix;

/**
 * Arrays.copyOfRange の付け替え先（Rewrite が呼び出しを向ける）。TeaVM 0.14.1 の wasm-gc 版は to が長さを超える時
 * （Java の決まりでは後ろを 0 / null で埋める）に配列の外を読んで落ちる。
 */
public final class CopyOfRange {
    private CopyOfRange() { }

    public static Object[] copyOfRange(Object[] a, int from, int to) {
        Object[] r = (Object[]) java.lang.reflect.Array.newInstance(a.getClass().getComponentType(), to - from);
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static int[] copyOfRange(int[] a, int from, int to) {
        int[] r = new int[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static long[] copyOfRange(long[] a, int from, int to) {
        long[] r = new long[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static double[] copyOfRange(double[] a, int from, int to) {
        double[] r = new double[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static float[] copyOfRange(float[] a, int from, int to) {
        float[] r = new float[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static byte[] copyOfRange(byte[] a, int from, int to) {
        byte[] r = new byte[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static short[] copyOfRange(short[] a, int from, int to) {
        short[] r = new short[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static char[] copyOfRange(char[] a, int from, int to) {
        char[] r = new char[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }

    public static boolean[] copyOfRange(boolean[] a, int from, int to) {
        boolean[] r = new boolean[to - from];
        System.arraycopy(a, from, r, 0, Math.min(a.length, to) - from);
        return r;
    }
}
