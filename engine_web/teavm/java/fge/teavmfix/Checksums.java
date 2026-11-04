package fge.teavmfix;

import java.util.zip.Checksum;

/** Checksum.update(byte[])（Java 9 の interface の default の関数）の付け替え先。TeaVM の classlib の Checksum には無い。 */
public final class Checksums {
    private Checksums() { }

    public static void update(Checksum checksum, byte[] bytes) {
        checksum.update(bytes, 0, bytes.length);
    }
}
