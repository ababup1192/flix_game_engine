package fge.webgpu;

/** texture の画素の形。backend が使う物だけ。 */
public enum TextureFormat {
    R8_UNORM(1), RGBA8_UNORM(4), RGBA8_UNORM_SRGB(4), BGRA8_UNORM(4), BGRA8_UNORM_SRGB(4),
    RGBA16_FLOAT(8), RGBA32_FLOAT(16),
    DEPTH24_PLUS(4), DEPTH24_PLUS_STENCIL8(4), DEPTH32_FLOAT(4), STENCIL8(1);

    private final int bytesPerTexel;

    TextureFormat(int bytesPerTexel) { this.bytesPerTexel = bytesPerTexel; }

    /** 1 画素のバイト数（copyTextureToBuffer の行の長さを組む時に使う。深度の形は写せない物もある）。 */
    public int bytesPerTexel() { return bytesPerTexel; }
}
