package fge.webgpu;

/** compute の手順の組（シェーダーと bind group の layout）。 */
public interface ComputePipeline {
    /**
     * GPU の側の物を手放す。この後は使わない。使い終わったら呼ぶ（JNI の実装は GC では手放さない）。
     * ブラウザの実装では何もしない（JS の側の GC に任せる）。
     */
    void release();
}
