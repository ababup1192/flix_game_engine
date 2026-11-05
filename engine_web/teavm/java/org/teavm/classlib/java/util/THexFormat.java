package org.teavm.classlib.java.util;

/**
 * TeaVM 0.14.1 の classlib に無い HexFormat（Flix 標準の Util.Codec.encodeHex が使う）。
 * of と formatHex だけを持つ。
 */
public final class THexFormat {
    private static final THexFormat INSTANCE = new THexFormat();
    private static final char[] DIGITS = "0123456789abcdef".toCharArray();

    private THexFormat() { }

    public static THexFormat of() { return INSTANCE; }

    public String formatHex(byte[] bytes) {
        char[] out = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            out[2 * i] = DIGITS[(bytes[i] >> 4) & 15];
            out[2 * i + 1] = DIGITS[bytes[i] & 15];
        }
        return new String(out);
    }
}
