package fge.gl;

/**
 * GlContext に渡す GL の定数（名前は glow にそろえ、頭の GL_ を外す）。2D の描き手と、後で 3D（C9）と画面なしの描き手が使う物まで持つ。
 * WhyNot: interface の中に置かない — Flix 0.78 は interface の static の欄を名前で引けない（類の static の欄は引ける）。
 */
public final class GlConst {
    private GlConst() {}

    public static final int FALSE = 0;
    public static final int TRUE = 1;
    public static final int ONE = 1;
    public static final int TRIANGLES = 0x0004;
    public static final int NEVER = 0x0200;
    public static final int LESS = 0x0201;
    public static final int EQUAL = 0x0202;
    public static final int ALWAYS = 0x0207;
    public static final int SRC_ALPHA = 0x0302;
    public static final int ONE_MINUS_SRC_ALPHA = 0x0303;
    public static final int DST_COLOR = 0x0306;
    public static final int KEEP = 0x1E00;
    public static final int REPLACE = 0x1E01;
    public static final int DEPTH_BUFFER_BIT = 0x00000100;
    public static final int STENCIL_BUFFER_BIT = 0x00000400;
    public static final int COLOR_BUFFER_BIT = 0x00004000;
    public static final int CULL_FACE = 0x0B44;
    public static final int DEPTH_TEST = 0x0B71;
    public static final int STENCIL_TEST = 0x0B90;
    public static final int BLEND = 0x0BE2;
    public static final int SCISSOR_TEST = 0x0C11;
    public static final int UNPACK_ALIGNMENT = 0x0CF5;
    public static final int PACK_ALIGNMENT = 0x0D05;
    public static final int MAX_TEXTURE_SIZE = 0x0D33;
    public static final int TEXTURE_2D = 0x0DE1;
    public static final int UNSIGNED_BYTE = 0x1401;
    public static final int INT = 0x1404;
    public static final int UNSIGNED_INT = 0x1405;
    public static final int FLOAT = 0x1406;
    public static final int HALF_FLOAT = 0x140B;
    public static final int RED = 0x1903;
    public static final int RGB = 0x1907;
    public static final int RGBA = 0x1908;
    public static final int NEAREST = 0x2600;
    public static final int LINEAR = 0x2601;
    public static final int TEXTURE_MAG_FILTER = 0x2800;
    public static final int TEXTURE_MIN_FILTER = 0x2801;
    public static final int TEXTURE_WRAP_S = 0x2802;
    public static final int TEXTURE_WRAP_T = 0x2803;
    public static final int REPEAT = 0x2901;
    public static final int CLAMP_TO_EDGE = 0x812F;
    public static final int RGBA8 = 0x8058;
    public static final int TEXTURE0 = 0x84C0;
    public static final int ARRAY_BUFFER = 0x8892;
    public static final int STATIC_DRAW = 0x88E4;
    public static final int DYNAMIC_DRAW = 0x88E8;
    public static final int FRAGMENT_SHADER = 0x8B30;
    public static final int VERTEX_SHADER = 0x8B31;
    public static final int COMPILE_STATUS = 0x8B81;
    public static final int LINK_STATUS = 0x8B82;
    public static final int READ_FRAMEBUFFER = 0x8CA8;
    public static final int DRAW_FRAMEBUFFER = 0x8CA9;
    public static final int FRAMEBUFFER_COMPLETE = 0x8CD5;
    public static final int COLOR_ATTACHMENT0 = 0x8CE0;
    public static final int DEPTH_STENCIL_ATTACHMENT = 0x821A;
    public static final int FRAMEBUFFER = 0x8D40;
    public static final int RENDERBUFFER = 0x8D41;
    public static final int DEPTH24_STENCIL8 = 0x88F0;
    public static final int RGBA16F = 0x881A;
    public static final int MAX_SAMPLES = 0x8D57;
}
