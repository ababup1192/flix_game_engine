package fge.webgpu;

/**
 * ウィンドウ（PC）か canvas（ブラウザ）の描き先。作るのは実装ごとの関数（PC は DawnWebGpu.createMacSurface）。
 * 大きさが変わっても知らせは来ないので、ウィンドウの側で受けて configure し直す。
 */
public interface Surface {
    /** getCurrentTexture が返す texture の形として一番よい物。 */
    TextureFormat preferredFormat();

    void configure(int width, int height, TextureFormat format, PresentMode presentMode, int textureUsage);

    /** 次の描き先。取れない時は null（理由は lastStatus）。画面に出す待ちはここで起きる。 */
    Texture getCurrentTexture();

    SurfaceStatus lastStatus();

    void present();

    void release();
}
