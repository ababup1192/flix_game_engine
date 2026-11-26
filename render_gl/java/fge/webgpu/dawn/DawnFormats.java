package fge.webgpu.dawn;

import com.github.xpenatan.webgpu.*;
import fge.webgpu.*;

/** fge.webgpu の値と jWebGPU の値の対応。 */
final class DawnFormats {
    private DawnFormats() {}

    /**
     * jWebGPU の CUSTOM（旗の組と名前の無い機能）と obtain() はプロセスで 1 つの物を書き換えるので、値を入れてから渡し終わるまでこれで囲む。
     * WhyNot: 糸を 1 本と決めて囲まずに済ませない — device を 2 つ開いた画面なしの描き出しが別の糸から作り始めると、旗の値が混ざる。
     */
    static final Object SHARED = new Object();

    static WGPUBufferUsage bufferUsage(int bits) { return WGPUBufferUsage.CUSTOM.setValue(bits); }

    static WGPUTextureUsage textureUsage(int bits) { return WGPUTextureUsage.CUSTOM.setValue(bits); }

    static WGPUShaderStage shaderStage(int bits) { return WGPUShaderStage.CUSTOM.setValue(bits); }

    static WGPUTextureFormat textureFormat(TextureFormat f) {
        return switch (f) {
            case R8_UNORM -> WGPUTextureFormat.R8Unorm;
            case RGBA8_UNORM -> WGPUTextureFormat.RGBA8Unorm;
            case RGBA8_UNORM_SRGB -> WGPUTextureFormat.RGBA8UnormSrgb;
            case BGRA8_UNORM -> WGPUTextureFormat.BGRA8Unorm;
            case BGRA8_UNORM_SRGB -> WGPUTextureFormat.BGRA8UnormSrgb;
            case RGBA16_FLOAT -> WGPUTextureFormat.RGBA16Float;
            case R32_FLOAT -> WGPUTextureFormat.R32Float;
            case RGBA32_FLOAT -> WGPUTextureFormat.RGBA32Float;
            case DEPTH24_PLUS -> WGPUTextureFormat.Depth24Plus;
            case DEPTH24_PLUS_STENCIL8 -> WGPUTextureFormat.Depth24PlusStencil8;
            case DEPTH32_FLOAT -> WGPUTextureFormat.Depth32Float;
            case STENCIL8 -> WGPUTextureFormat.Stencil8;
        };
    }

    /** Dawn の形をこちらの形へ。こちらに無い形は null。 */
    static TextureFormat fromTextureFormat(WGPUTextureFormat f) {
        for (TextureFormat t : TextureFormat.values()) if (textureFormat(t) == f) return t;
        return null;
    }

    static WGPUVertexFormat vertexFormat(VertexFormat f) {
        return switch (f) {
            case FLOAT32 -> WGPUVertexFormat.Float32;
            case FLOAT32X2 -> WGPUVertexFormat.Float32x2;
            case FLOAT32X3 -> WGPUVertexFormat.Float32x3;
            case FLOAT32X4 -> WGPUVertexFormat.Float32x4;
            case UINT32 -> WGPUVertexFormat.Uint32;
            case UINT32X2 -> WGPUVertexFormat.Uint32x2;
            case UINT32X4 -> WGPUVertexFormat.Uint32x4;
            case UNORM8X4 -> WGPUVertexFormat.Unorm8x4;
        };
    }

    static WGPUBlendFactor blendFactor(BlendFactor f) {
        return switch (f) {
            case ZERO -> WGPUBlendFactor.Zero;
            case ONE -> WGPUBlendFactor.One;
            case SRC -> WGPUBlendFactor.Src;
            case ONE_MINUS_SRC -> WGPUBlendFactor.OneMinusSrc;
            case SRC_ALPHA -> WGPUBlendFactor.SrcAlpha;
            case ONE_MINUS_SRC_ALPHA -> WGPUBlendFactor.OneMinusSrcAlpha;
            case DST -> WGPUBlendFactor.Dst;
            case ONE_MINUS_DST -> WGPUBlendFactor.OneMinusDst;
            case DST_ALPHA -> WGPUBlendFactor.DstAlpha;
            case ONE_MINUS_DST_ALPHA -> WGPUBlendFactor.OneMinusDstAlpha;
            case CONSTANT -> WGPUBlendFactor.Constant;
            case ONE_MINUS_CONSTANT -> WGPUBlendFactor.OneMinusConstant;
        };
    }

    static WGPUBlendOperation blendOperation(BlendOperation o) {
        return switch (o) {
            case ADD -> WGPUBlendOperation.Add;
            case SUBTRACT -> WGPUBlendOperation.Subtract;
            case REVERSE_SUBTRACT -> WGPUBlendOperation.ReverseSubtract;
            case MIN -> WGPUBlendOperation.Min;
            case MAX -> WGPUBlendOperation.Max;
        };
    }

    static WGPUCompareFunction compare(CompareFunction f) {
        return switch (f) {
            case NEVER -> WGPUCompareFunction.Never;
            case LESS -> WGPUCompareFunction.Less;
            case EQUAL -> WGPUCompareFunction.Equal;
            case LESS_EQUAL -> WGPUCompareFunction.LessEqual;
            case GREATER -> WGPUCompareFunction.Greater;
            case NOT_EQUAL -> WGPUCompareFunction.NotEqual;
            case GREATER_EQUAL -> WGPUCompareFunction.GreaterEqual;
            case ALWAYS -> WGPUCompareFunction.Always;
        };
    }

    static WGPUStencilOperation stencilOp(StencilOperation o) {
        return switch (o) {
            case KEEP -> WGPUStencilOperation.Keep;
            case ZERO -> WGPUStencilOperation.Zero;
            case REPLACE -> WGPUStencilOperation.Replace;
            case INVERT -> WGPUStencilOperation.Invert;
            case INCREMENT_CLAMP -> WGPUStencilOperation.IncrementClamp;
            case DECREMENT_CLAMP -> WGPUStencilOperation.DecrementClamp;
            case INCREMENT_WRAP -> WGPUStencilOperation.IncrementWrap;
            case DECREMENT_WRAP -> WGPUStencilOperation.DecrementWrap;
        };
    }

    static WGPUPrimitiveTopology topology(PrimitiveTopology t) {
        return switch (t) {
            case TRIANGLE_LIST -> WGPUPrimitiveTopology.TriangleList;
            case TRIANGLE_STRIP -> WGPUPrimitiveTopology.TriangleStrip;
            case LINE_LIST -> WGPUPrimitiveTopology.LineList;
            case LINE_STRIP -> WGPUPrimitiveTopology.LineStrip;
            case POINT_LIST -> WGPUPrimitiveTopology.PointList;
        };
    }

    static WGPUCullMode cullMode(CullMode c) {
        return switch (c) {
            case NONE -> WGPUCullMode.None;
            case FRONT -> WGPUCullMode.Front;
            case BACK -> WGPUCullMode.Back;
        };
    }

    static WGPUAddressMode addressMode(AddressMode a) {
        return switch (a) {
            case CLAMP_TO_EDGE -> WGPUAddressMode.ClampToEdge;
            case REPEAT -> WGPUAddressMode.Repeat;
            case MIRROR_REPEAT -> WGPUAddressMode.MirrorRepeat;
        };
    }

    static WGPUBufferBindingType bufferBinding(BufferBindingType t) {
        return switch (t) {
            case UNIFORM -> WGPUBufferBindingType.Uniform;
            case STORAGE -> WGPUBufferBindingType.Storage;
            case READ_ONLY_STORAGE -> WGPUBufferBindingType.ReadOnlyStorage;
        };
    }

    static WGPUTextureSampleType sampleType(TextureSampleType t) {
        return switch (t) {
            case FLOAT -> WGPUTextureSampleType.Float;
            case UNFILTERABLE_FLOAT -> WGPUTextureSampleType.UnfilterableFloat;
            case DEPTH -> WGPUTextureSampleType.Depth;
            case SINT -> WGPUTextureSampleType.Sint;
            case UINT -> WGPUTextureSampleType.Uint;
        };
    }

    static WGPUSamplerBindingType samplerBinding(SamplerBindingType t) {
        return switch (t) {
            case FILTERING -> WGPUSamplerBindingType.Filtering;
            case NON_FILTERING -> WGPUSamplerBindingType.NonFiltering;
        };
    }

    static WGPUPresentMode presentMode(PresentMode m) {
        return switch (m) {
            case FIFO -> WGPUPresentMode.Fifo;
            case IMMEDIATE -> WGPUPresentMode.Immediate;
            case MAILBOX -> WGPUPresentMode.Mailbox;
        };
    }

    static SurfaceStatus surfaceStatus(WGPUSurfaceGetCurrentTextureStatus s) {
        if (s == WGPUSurfaceGetCurrentTextureStatus.SuccessOptimal) return SurfaceStatus.SUCCESS_OPTIMAL;
        if (s == WGPUSurfaceGetCurrentTextureStatus.SuccessSuboptimal) return SurfaceStatus.SUCCESS_SUBOPTIMAL;
        if (s == WGPUSurfaceGetCurrentTextureStatus.Timeout) return SurfaceStatus.TIMEOUT;
        if (s == WGPUSurfaceGetCurrentTextureStatus.Outdated) return SurfaceStatus.OUTDATED;
        if (s == WGPUSurfaceGetCurrentTextureStatus.Lost) return SurfaceStatus.LOST;
        return SurfaceStatus.ERROR;
    }
}
