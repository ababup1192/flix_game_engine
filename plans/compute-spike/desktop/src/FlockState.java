/** 群れの初めの状態（デスクトップとブラウザの測りで同じ物を使う）。1 個 = pos(xyz, 1) と vel(xyz, 0) の 8 float。 */
public final class FlockState {
    private FlockState() {}

    /** 箱の中に一様・速さの各成分は ±maxSpeed/2 の一様（LCG）。 */
    public static float[] initialState(int n, long seed, float[] lo, float[] hi, float maxSpeed) {
        float[] s = new float[n * 8];
        long x = seed * 0x9E3779B97F4A7C15L + 1;
        for (int i = 0; i < n; i++) {
            for (int k = 0; k < 3; k++) { x = x * 6364136223846793005L + 1442695040888963407L; s[i * 8 + k] = lo[k] + (hi[k] - lo[k]) * ((x >>> 40) / (float) (1 << 24)); }
            s[i * 8 + 3] = 1f;
            for (int k = 0; k < 3; k++) { x = x * 6364136223846793005L + 1442695040888963407L; s[i * 8 + 4 + k] = (((x >>> 40) / (float) (1 << 24)) * 2f - 1f) * maxSpeed * 0.5f; }
        }
        return s;
    }
}
