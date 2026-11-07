package fge.web;

import java.util.HashMap;
import java.util.Map;

/** 書き出しの時に wasm へ埋め込んだ素材（EmbeddedData）を道で引き、初めて引いた時に復号して持っておく。 */
public final class Embedded {
    private Embedded() { }

    private static Map<String, int[]> spans;
    private static final Map<String, byte[]> decoded = new HashMap<>();

    private static Map<String, int[]> spans() {
        if (spans != null) return spans;
        Map<String, int[]> found = new HashMap<>();
        String[] table = EmbeddedData.table();
        int i = 0;
        int index = 0;
        while (i + 1 < table.length) {
            int count = Integer.parseInt(table[i + 1]);
            found.put(table[i], new int[] {i + 2, count, index});
            i += 2 + count;
            index++;
        }
        spans = found;
        return spans;
    }

    public static boolean has(String path) { return spans().containsKey(path); }

    /** 埋め込んだ素材のバイト列（呼び手が書き換えてよい写し）。無いか壊れていれば null。 */
    public static byte[] bytes(String path) {
        byte[] plain = decoded.get(path);
        if (plain == null) {
            int[] span = spans().get(path);
            if (span == null) return null;
            plain = EmbeddedCodec.decode(EmbeddedData.table(), span[0], span[1], EmbeddedData.seed(), span[2]);
            if (plain == null) return null;
            decoded.put(path, plain);
        }
        return plain.clone();
    }
}
