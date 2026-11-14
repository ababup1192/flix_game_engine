package fge.web.webgpu;

import fge.webgpu.TextureFormat;
import java.util.Locale;

/** fge.webgpu の enum を WebGPU の JS の字の値へ（Dawn の側は DawnFormats）。 */
final class BrowserFormats {
    private BrowserFormats() {}

    /**
     * 名前の "_" を "-" にして小文字にした字（CompareFunction.LESS_EQUAL → "less-equal"・VertexFormat.FLOAT32X2 → "float32x2"）。
     * WhyNot: TextureFormat に使わない — "rgba8unorm" のように区切りを持たない名前があり、この規則では作れない。
     */
    static String token(Enum<?> value) {
        return value.name().toLowerCase(Locale.ROOT).replace('_', '-');
    }

    static String textureFormat(TextureFormat format) {
        switch (format) {
            case R8_UNORM: return "r8unorm";
            case RGBA8_UNORM: return "rgba8unorm";
            case RGBA8_UNORM_SRGB: return "rgba8unorm-srgb";
            case BGRA8_UNORM: return "bgra8unorm";
            case BGRA8_UNORM_SRGB: return "bgra8unorm-srgb";
            case RGBA16_FLOAT: return "rgba16float";
            case RGBA32_FLOAT: return "rgba32float";
            case DEPTH24_PLUS: return "depth24plus";
            case DEPTH24_PLUS_STENCIL8: return "depth24plus-stencil8";
            case DEPTH32_FLOAT: return "depth32float";
            case STENCIL8: return "stencil8";
            default: throw new IllegalArgumentException("知らない TextureFormat: " + format);
        }
    }

    /** canvas が勧める形の字を TextureFormat へ。知らない字は null。 */
    static TextureFormat fromTextureFormat(String format) {
        for (TextureFormat f : TextureFormat.values()) {
            if (textureFormat(f).equals(format)) return f;
        }
        return null;
    }

    /** getCompilationInfo の種類の字（"error"）を Dawn の名前（"Error"）にそろえる。 */
    static String messageType(String type) {
        if (type == null || type.isEmpty()) return "Info";
        return Character.toUpperCase(type.charAt(0)) + type.substring(1);
    }
}
