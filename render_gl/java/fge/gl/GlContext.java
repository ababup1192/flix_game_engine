package fge.gl;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;

/**
 * render_gl の 2D の描き手が呼ぶ GL の関数の集まり。実装はデスクトップの LWJGL（{@link LwjglGl}）と、後でブラウザの WebGL2。
 * 関数は GL 3.3 と WebGL2 に共通する形と、両者で中身が違う所の意図の名前の関数（texImageArgb など）だけを持つ。
 * 名前と定数は Rust の glow にそろえ、頭の gl / GL_ を外す。ハンドルは int のまま。
 *
 * WhyNot: ジェネリックにしない — Flix 0.78 は型引数を持つ interface へ primitive を渡す所で VerifyError を出す。
 * WhyNot: 実装の作り口（lwjgl() など）を interface の static に置かない — ブラウザの道から LWJGL の類へ静的に届かせないため。
 */
public interface GlContext {
    int FALSE = 0;
    int TRUE = 1;
    int ONE = 1;
    int TRIANGLES = 0x0004;
    int NEVER = 0x0200;
    int LESS = 0x0201;
    int EQUAL = 0x0202;
    int ALWAYS = 0x0207;
    int SRC_ALPHA = 0x0302;
    int ONE_MINUS_SRC_ALPHA = 0x0303;
    int DST_COLOR = 0x0306;
    int KEEP = 0x1E00;
    int REPLACE = 0x1E01;
    int DEPTH_BUFFER_BIT = 0x00000100;
    int STENCIL_BUFFER_BIT = 0x00000400;
    int COLOR_BUFFER_BIT = 0x00004000;
    int CULL_FACE = 0x0B44;
    int DEPTH_TEST = 0x0B71;
    int STENCIL_TEST = 0x0B90;
    int BLEND = 0x0BE2;
    int SCISSOR_TEST = 0x0C11;
    int UNPACK_ALIGNMENT = 0x0CF5;
    int PACK_ALIGNMENT = 0x0D05;
    int MAX_TEXTURE_SIZE = 0x0D33;
    int TEXTURE_2D = 0x0DE1;
    int UNSIGNED_BYTE = 0x1401;
    int INT = 0x1404;
    int UNSIGNED_INT = 0x1405;
    int FLOAT = 0x1406;
    int HALF_FLOAT = 0x140B;
    int RED = 0x1903;
    int RGB = 0x1907;
    int RGBA = 0x1908;
    int NEAREST = 0x2600;
    int LINEAR = 0x2601;
    int TEXTURE_MAG_FILTER = 0x2800;
    int TEXTURE_MIN_FILTER = 0x2801;
    int TEXTURE_WRAP_S = 0x2802;
    int TEXTURE_WRAP_T = 0x2803;
    int REPEAT = 0x2901;
    int CLAMP_TO_EDGE = 0x812F;
    int RGBA8 = 0x8058;
    int TEXTURE0 = 0x84C0;
    int ARRAY_BUFFER = 0x8892;
    int STATIC_DRAW = 0x88E4;
    int DYNAMIC_DRAW = 0x88E8;
    int FRAGMENT_SHADER = 0x8B30;
    int VERTEX_SHADER = 0x8B31;
    int COMPILE_STATUS = 0x8B81;
    int LINK_STATUS = 0x8B82;
    int READ_FRAMEBUFFER = 0x8CA8;
    int DRAW_FRAMEBUFFER = 0x8CA9;
    int FRAMEBUFFER_COMPLETE = 0x8CD5;
    int COLOR_ATTACHMENT0 = 0x8CE0;
    int DEPTH_STENCIL_ATTACHMENT = 0x821A;
    int FRAMEBUFFER = 0x8D40;
    int RENDERBUFFER = 0x8D41;
    int DEPTH24_STENCIL8 = 0x88F0;
    int RGBA16F = 0x881A;
    int MAX_SAMPLES = 0x8D57;

    // ── 状態 ──
    void enable(int cap);
    void disable(int cap);
    void viewport(int x, int y, int width, int height);
    void scissor(int x, int y, int width, int height);
    void clearColor(float r, float g, float b, float a);
    void clearStencil(int s);
    void clear(int mask);
    void blendFunc(int sfactor, int dfactor);
    void colorMask(boolean r, boolean g, boolean b, boolean a);
    void stencilMask(int mask);
    void stencilFunc(int func, int ref, int mask);
    void stencilOp(int sfail, int dpfail, int dppass);
    void pixelStorei(int pname, int param);
    int getInteger(int pname);

    // ── バッファと頂点の配列 ──
    int genBuffer();
    void deleteBuffer(int buffer);
    void bindBuffer(int target, int buffer);
    void bufferData(int target, float[] data, int usage);
    void bufferData(int target, FloatBuffer data, int usage);
    int genVertexArray();
    void deleteVertexArray(int array);
    void bindVertexArray(int array);
    void enableVertexAttribArray(int index);
    void vertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset);
    void vertexAttribDivisor(int index, int divisor);
    void drawArrays(int mode, int first, int count);
    void drawArraysInstanced(int mode, int first, int count, int instanceCount);

    // ── テクスチャと sampler ──
    int genTexture();
    void deleteTexture(int texture);
    void bindTexture(int target, int texture);
    void activeTexture(int unit);
    void texParameteri(int target, int pname, int param);
    /** 画素の列（int ごとに ARGB）を、今 bind している TEXTURE_2D へ RGBA8 で上げる（置き場も確保し直す）。 */
    void texImageArgb(int width, int height, IntBuffer argb);
    /** texImageArgb と同じ形式で置き場を確保し、0（透明な黒）で埋める。 */
    void texImageArgbZero(int width, int height);
    /** 1 画素 1 バイトの濃さを、今 bind している TEXTURE_2D へ上げる。シェーダーが .a で読める形（rgb は問わない）にする。 */
    void texImageAlphaMask(int width, int height, ByteBuffer alpha);
    /** texImageAlphaMask で作ったテクスチャの (x, y) から width × height を差し替える。 */
    void texSubImageAlphaMask(int x, int y, int width, int height, ByteBuffer alpha);
    /** 画像のバイト列（1 画素 3 か 4 バイト・format は RGB か RGBA）を、今 bind している TEXTURE_2D へ上げる。 */
    void texImageBytes(int format, int width, int height, ByteBuffer pixels);
    /** 今 bind している TEXTURE_2D の置き場を RGBA16F で確保し、0 で埋める。 */
    void texImageRgba16fZero(int width, int height);
    int genSampler();
    void bindSampler(int unit, int sampler);
    void samplerParameteri(int sampler, int pname, int param);

    // ── framebuffer と renderbuffer ──
    int genFramebuffer();
    void deleteFramebuffer(int framebuffer);
    void bindFramebuffer(int target, int framebuffer);
    int checkFramebufferStatus(int target);
    void framebufferTexture2D(int target, int attachment, int textarget, int texture, int level);
    void framebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer);
    void blitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter);
    int genRenderbuffer();
    void deleteRenderbuffer(int renderbuffer);
    void bindRenderbuffer(int target, int renderbuffer);
    void renderbufferStorage(int target, int internalformat, int width, int height);
    void renderbufferStorageMultisample(int target, int samples, int internalformat, int width, int height);

    // ── シェーダーと uniform ──
    int createShader(int type);
    void shaderSource(int shader, String source);
    void compileShader(int shader);
    int getShaderi(int shader, int pname);
    String getShaderInfoLog(int shader);
    void deleteShader(int shader);
    int createProgram();
    void attachShader(int program, int shader);
    void linkProgram(int program);
    int getProgrami(int program, int pname);
    String getProgramInfoLog(int program);
    void deleteProgram(int program);
    void useProgram(int program);
    int getUniformLocation(int program, String name);
    void uniform1i(int location, int v0);
    void uniform1f(int location, float v0);
    void uniform2f(int location, float v0, float v1);
    void uniform3f(int location, float v0, float v1, float v2);
    void uniformMatrix4fv(int location, boolean transpose, float[] value);

    // ── GPU へ渡す直接バッファ（取ったら必ず返す）──
    FloatBuffer allocFloats(int count);
    void freeFloats(FloatBuffer buffer);
    IntBuffer allocInts(int count);
    void freeInts(IntBuffer buffer);
    ByteBuffer allocBytes(int count);
    void freeBytes(ByteBuffer buffer);
}
