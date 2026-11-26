package fge.teavmfix;

/**
 * Float.float16ToFloat・Float.floatToFloat16（Java 20）の付け替え先。TeaVM 0.16.0 の classlib には無い。
 * WhyNot: 近い値で済ませない — PC（JDK）とブラウザで half の bit が 1 つでも違うと、.hdr の mip と描き出しの絵が機種で分かれる。
 * JDK 25 と同じ丸め（最近接・偶数）・NaN は quiet の bit を立てて上の payload だけ残す・非正規化数を写した。
 * 全部の half（65,536）と全部の float（2^32）を JDK 25 と bit で比べて一致を確かめてある（2026-11-26）。
 */
public final class HalfFloats {
    private HalfFloats() { }

    public static float float16ToFloat(short bits) {
        int signBit = 0x8000 & bits;
        int expBits = 0x7c00 & bits;
        int signifBits = 0x03ff & bits;
        float sign = signBit != 0 ? -1.0f : 1.0f;
        int exp = (expBits >> 10) - 15;
        if (exp == -15) {
            return sign * (0x1p-24f * signifBits);
        }
        if (exp == 16) {
            return signifBits == 0
                ? sign * Float.POSITIVE_INFINITY
                : Float.intBitsToFloat((signBit << 16) | 0x7fc0_0000 | (signifBits << 13));
        }
        return Float.intBitsToFloat((signBit << 16) | ((exp + 127) << 23) | (signifBits << 13));
    }

    public static short floatToFloat16(float f) {
        int doppel = Float.floatToRawIntBits(f);
        short signBit = (short) ((doppel & 0x8000_0000) >> 16);
        if (Float.isNaN(f)) {
            return (short) (signBit | 0x7e00 | (doppel & 0x007f_e000) >> 13);
        }
        float abs = Math.abs(f);
        if (abs >= (0x1.ffcp15f + 0x0.002p15f)) {
            return (short) (signBit | 0x7c00);
        }
        if (abs <= 0x1.0p-24f * 0.5f) {
            return signBit;
        }
        int exp = Math.getExponent(f);
        int expDelta = 0;
        int msb = 0;
        if (exp < -14) {
            expDelta = -14 - exp;
            exp = -15;
            msb = 0x0080_0000;
        }
        int fSignif = doppel & 0x007f_ffff | msb;
        short signif = (short) (fSignif >> (13 + expDelta));
        int lsb = fSignif & (1 << 13 + expDelta);
        int round = fSignif & (1 << 12 + expDelta);
        int sticky = fSignif & ((1 << 12 + expDelta) - 1);
        if (round != 0 && ((lsb | sticky) != 0)) {
            signif++;
        }
        return (short) (signBit | (((exp + 15) << 10) + signif));
    }
}
