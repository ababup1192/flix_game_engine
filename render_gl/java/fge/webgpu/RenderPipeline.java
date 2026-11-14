package fge.webgpu;

/** 描く手順の組（シェーダー・頂点の形・blend・深度）。 */
public interface RenderPipeline {
    /**
     * GPU の側の物を手放す。この後は使わない。使い終わったら呼ぶ（JNI の実装は GC では手放さない）。
     * ブラウザの実装では何もしない（JS の側の GC に任せる）。
     */
    void release();
}
