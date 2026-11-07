package fge.web;

import java.io.ByteArrayOutputStream;
import java.util.Base64;
import java.util.zip.DataFormatException;
import java.util.zip.Deflater;
import java.util.zip.Inflater;

/**
 * 埋め込む素材の符号（書き出しの道具 fge.teavmfix.Embed が encode し、ブラウザ版の Embedded が decode する）。
 * 鍵と復号の手順は同じ wasm に入るので、守れるのは「通信や wasm の字を眺めて読む」ところまで。
 */
public final class EmbeddedCodec {
    private EmbeddedCodec() { }

    // WhyNot: 1 本の字にまとめない — class ファイルの 1 つの字の定数は 65535 バイトまで。
    public static final int CHUNK = 30000;

    public static String[] encode(byte[] plain, long seed, int index) {
        Deflater deflater = new Deflater(Deflater.BEST_COMPRESSION);
        deflater.setInput(plain);
        deflater.finish();
        ByteArrayOutputStream packed = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        while (!deflater.finished()) {
            int n = deflater.deflate(buf);
            packed.write(buf, 0, n);
        }
        deflater.end();
        byte[] bytes = packed.toByteArray();
        // WhyNot: XOR の後に deflate しない — 符号にした列はほぼ乱数で縮まない。
        xor(bytes, seed, index);
        String text = Base64.getEncoder().encodeToString(bytes);
        int count = Math.max(1, (text.length() + CHUNK - 1) / CHUNK);
        String[] chunks = new String[count];
        for (int i = 0; i < count; i++) {
            chunks[i] = text.substring(i * CHUNK, Math.min(text.length(), (i + 1) * CHUNK));
        }
        return chunks;
    }

    /** table[from] から count 本の切れ端をつないで戻す。壊れていれば null。 */
    public static byte[] decode(String[] table, int from, int count, long seed, int index) {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < count; i++) text.append(table[from + i]);
        byte[] bytes;
        try {
            bytes = Base64.getDecoder().decode(text.toString());
        } catch (IllegalArgumentException e) {
            return null;
        }
        xor(bytes, seed, index);
        Inflater inflater = new Inflater();
        inflater.setInput(bytes);
        ByteArrayOutputStream plain = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        try {
            while (!inflater.finished()) {
                int n = inflater.inflate(buf);
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) return null;
                plain.write(buf, 0, n);
            }
        } catch (DataFormatException e) {
            return null;
        } finally {
            inflater.end();
        }
        return plain.toByteArray();
    }

    private static void xor(byte[] bytes, long seed, int index) {
        int s = (int) (seed ^ (seed >>> 32) ^ (index * 0x9E3779B9L));
        if (s == 0) s = 0x6D2B79F5;
        for (int k = 0; k < bytes.length; k++) {
            s ^= s << 13;
            s ^= s >>> 17;
            s ^= s << 5;
            bytes[k] ^= (byte) s;
        }
    }
}
