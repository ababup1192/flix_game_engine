package fge.teavmfix;

import java.nio.ByteBuffer;

/**
 * ByteBuffer.allocateDirect の付け替え先（Rewrite が呼び出しを向ける）。TeaVM 0.14.1 の Heap.alloc は、heap の末尾が使用中で
 * 大きさがちょうど 64 KiB の倍数の時（512x512 の ARGB など）、ちょうどの分だけ memory を伸ばす。伸ばした所から record の頭の 8 byte が
 * 引かれるので足りず、null を返して OutOfMemoryError になる。memory には余裕がある。
 * 末尾が 8 byte 足りない空きになった後のもう 1 回は、memory を 1 page 伸ばして通る。
 */
public final class DirectBuffers {
    private DirectBuffers() { }

    public static ByteBuffer allocateDirect(int capacity) {
        try {
            return ByteBuffer.allocateDirect(capacity);
        } catch (OutOfMemoryError e) {
            return ByteBuffer.allocateDirect(capacity);
        }
    }
}
