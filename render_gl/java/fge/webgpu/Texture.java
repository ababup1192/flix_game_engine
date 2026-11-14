package fge.webgpu;

/** GPU の上の 2D の texture。 */
public interface Texture {
    int width();

    int height();

    TextureFormat format();

    /** 段 0 から全部の段・全部の面を見る view。 */
    TextureView createView();

    void destroy();
}
