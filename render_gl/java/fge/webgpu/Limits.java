package fge.webgpu;

/** device の上限（backend が見る物だけ）。大きさは long（u64 の上限が 4 GiB を超える GPU がある）。 */
public final class Limits {
    private final int maxTextureDimension2D;
    private final int maxTextureArrayLayers;
    private final int maxBindGroups;
    private final int maxSampledTexturesPerShaderStage;
    private final int maxSamplersPerShaderStage;
    private final int maxStorageBuffersPerShaderStage;
    private final int maxUniformBuffersPerShaderStage;
    private final int maxVertexBuffers;
    private final int maxVertexAttributes;
    private final int minUniformBufferOffsetAlignment;
    private final int minStorageBufferOffsetAlignment;
    private final long maxUniformBufferBindingSize;
    private final long maxStorageBufferBindingSize;
    private final long maxBufferSize;

    public Limits(int maxTextureDimension2D, int maxTextureArrayLayers, int maxBindGroups,
                  int maxSampledTexturesPerShaderStage, int maxSamplersPerShaderStage,
                  int maxStorageBuffersPerShaderStage, int maxUniformBuffersPerShaderStage,
                  int maxVertexBuffers, int maxVertexAttributes,
                  int minUniformBufferOffsetAlignment, int minStorageBufferOffsetAlignment,
                  long maxUniformBufferBindingSize, long maxStorageBufferBindingSize, long maxBufferSize) {
        this.maxTextureDimension2D = maxTextureDimension2D;
        this.maxTextureArrayLayers = maxTextureArrayLayers;
        this.maxBindGroups = maxBindGroups;
        this.maxSampledTexturesPerShaderStage = maxSampledTexturesPerShaderStage;
        this.maxSamplersPerShaderStage = maxSamplersPerShaderStage;
        this.maxStorageBuffersPerShaderStage = maxStorageBuffersPerShaderStage;
        this.maxUniformBuffersPerShaderStage = maxUniformBuffersPerShaderStage;
        this.maxVertexBuffers = maxVertexBuffers;
        this.maxVertexAttributes = maxVertexAttributes;
        this.minUniformBufferOffsetAlignment = minUniformBufferOffsetAlignment;
        this.minStorageBufferOffsetAlignment = minStorageBufferOffsetAlignment;
        this.maxUniformBufferBindingSize = maxUniformBufferBindingSize;
        this.maxStorageBufferBindingSize = maxStorageBufferBindingSize;
        this.maxBufferSize = maxBufferSize;
    }

    public int maxTextureDimension2D() { return maxTextureDimension2D; }
    public int maxTextureArrayLayers() { return maxTextureArrayLayers; }
    public int maxBindGroups() { return maxBindGroups; }
    public int maxSampledTexturesPerShaderStage() { return maxSampledTexturesPerShaderStage; }
    public int maxSamplersPerShaderStage() { return maxSamplersPerShaderStage; }
    public int maxStorageBuffersPerShaderStage() { return maxStorageBuffersPerShaderStage; }
    public int maxUniformBuffersPerShaderStage() { return maxUniformBuffersPerShaderStage; }
    public int maxVertexBuffers() { return maxVertexBuffers; }
    public int maxVertexAttributes() { return maxVertexAttributes; }
    public int minUniformBufferOffsetAlignment() { return minUniformBufferOffsetAlignment; }
    public int minStorageBufferOffsetAlignment() { return minStorageBufferOffsetAlignment; }
    public long maxUniformBufferBindingSize() { return maxUniformBufferBindingSize; }
    public long maxStorageBufferBindingSize() { return maxStorageBufferBindingSize; }
    public long maxBufferSize() { return maxBufferSize; }

    @Override public String toString() {
        return "maxTextureDimension2D=" + maxTextureDimension2D + " maxTextureArrayLayers=" + maxTextureArrayLayers
            + " maxBindGroups=" + maxBindGroups + " maxSampledTexturesPerShaderStage=" + maxSampledTexturesPerShaderStage
            + " maxSamplersPerShaderStage=" + maxSamplersPerShaderStage + " maxStorageBuffersPerShaderStage=" + maxStorageBuffersPerShaderStage
            + " maxUniformBuffersPerShaderStage=" + maxUniformBuffersPerShaderStage + " maxVertexBuffers=" + maxVertexBuffers
            + " maxVertexAttributes=" + maxVertexAttributes + " minUniformBufferOffsetAlignment=" + minUniformBufferOffsetAlignment
            + " minStorageBufferOffsetAlignment=" + minStorageBufferOffsetAlignment
            + " maxUniformBufferBindingSize=" + maxUniformBufferBindingSize + " maxStorageBufferBindingSize=" + maxStorageBufferBindingSize
            + " maxBufferSize=" + maxBufferSize;
    }
}
