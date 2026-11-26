package fge.webgpu;

/** 1 回の submit に積む命令を組む物。finish の後は使わない。 */
public interface CommandEncoder {
    RenderPass beginRenderPass(RenderPassDesc desc);

    /** timestamps が null でなければ pass の始めと終わりの時刻を beginIndex・endIndex 番に書く（timestamp-query がある device だけ）。 */
    ComputePass beginComputePass(String label, QuerySet timestamps, int beginIndex, int endIndex);

    /** buffer の [offset, offset + size) を 0 にする（offset と size は 4 の倍数）。 */
    void clearBuffer(Buffer buffer, long offset, long size);

    void copyBufferToBuffer(Buffer src, long srcOffset, Buffer dst, long dstOffset, long size);

    /** texture の段 mip の (x, y)-(x + width, y + height) を dst の dstOffset から行ごと bytesPerRow 刻みで写す（bytesPerRow は 256 の倍数）。 */
    void copyTextureToBuffer(Texture src, int mip, int x, int y, int width, int height,
                             Buffer dst, long dstOffset, int bytesPerRow);

    void resolveQuerySet(QuerySet querySet, int first, int count, Buffer dst, long dstOffset);

    CommandBuffer finish();
}
