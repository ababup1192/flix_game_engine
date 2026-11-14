package fge.webgpu;

/** bind group の項目の並び。 */
public interface BindGroupLayout {
    /**
     * GPU の側の物を手放す。この後は使わない。使い終わったら呼ぶ（JNI の実装は GC では手放さない）。
     * ブラウザの実装では何もしない（JS の側の GC に任せる）。
     */
    void release();
}
