package fge.webgpu;

/** GPU の上の 2D の texture。 */
public interface Texture {
    int width();

    int height();

    TextureFormat format();

    /** 段 0 から全部の段・全部の面を見る新しい view。呼び手が release する。 */
    TextureView createView();

    /**
     * texture が持つ view（createView と同じ見え方）。texture と寿命が同じで、呼び手は release しない。
     * 毎コマ描く描き先はこちらを使う（毎コマ view を作って手放す手間を省く）。
     */
    TextureView defaultView();

    /** GPU の側の物と defaultView を手放す。2 回目は何もしない。surface の texture は present が手放すので、ここでは view だけ。 */
    void destroy();
}
