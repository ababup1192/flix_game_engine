package fge.webgpu;

/** texture の使い道の旗（値は WebGPU の GPUTextureUsage と同じ。or でつなぐ）。 */
public final class TextureUsage {
    private TextureUsage() {}

    public static final int COPY_SRC = 0x01;
    public static final int COPY_DST = 0x02;
    public static final int TEXTURE_BINDING = 0x04;
    public static final int STORAGE_BINDING = 0x08;
    public static final int RENDER_ATTACHMENT = 0x10;
}
