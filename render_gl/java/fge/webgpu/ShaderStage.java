package fge.webgpu;

/** bind group の項目が見える段の旗（値は WebGPU の GPUShaderStage と同じ。or でつなぐ）。 */
public final class ShaderStage {
    private ShaderStage() {}

    public static final int VERTEX = 0x1;
    public static final int FRAGMENT = 0x2;
    public static final int COMPUTE = 0x4;
}
