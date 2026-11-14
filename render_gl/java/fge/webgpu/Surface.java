package fge.webgpu;

/**
 * ウィンドウ（PC）か canvas（ブラウザ）の描き先。作るのは実装ごとの関数（PC は DawnWebGpu.createMacSurface）。
 * 大きさが変わっても知らせは来ないので、ウィンドウの側で受けて configure し直す。
 */
public interface Surface {
    /** getCurrentTexture が返す texture の形として一番よい物。 */
    TextureFormat preferredFormat();

    void configure(int width, int height, TextureFormat format, PresentMode presentMode, int textureUsage);

    /**
     * 次の描き先。取れない時は null（理由は lastStatus）。画面に出す待ちはここで起きる。
     * present の前にもう一度呼ぶと、前に渡した texture は手放される（同じコマに 2 枚は持たない）。描くのは defaultView で。
     */
    Texture getCurrentTexture();

    SurfaceStatus lastStatus();

    /** 描き先を画面へ出し、getCurrentTexture で渡した texture と view を手放す。ブラウザでは何もしない（コマの終わりに出る）。 */
    void present();

    void release();
}
