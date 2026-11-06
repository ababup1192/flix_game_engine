package fge.gl;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;

/**
 * render_gl の 2D と 3D の描き手が呼ぶ GL の関数の集まり。実装はデスクトップの LWJGL（{@link LwjglGl}）とブラウザの WebGL2（engine_web の fge.web.WebGl2）。
 * 関数は GL 3.3 と WebGL2 に共通する形と、両者で中身が違う所の意図の名前の関数（texImageArgb など）だけを持つ。
 * 名前と定数は Rust の glow（と WebGL2）にそろえる: 頭の gl / GL_ を外し、作る関数は create*。ハンドルは int のまま。
 * uniform の location も int（-1 は何もしない）。WebGL2 版は int と WebGLUniformLocation の表を持ち、-1 を null に写す。
 * 定数は GlConst に置く。
 *
 * WhyNot: ジェネリックにしない — Flix 0.78 は型引数を持つ interface へ primitive を渡す所で VerifyError を出す。
 * WhyNot: 実装の作り口（lwjgl() など）を interface の static に置かない — ブラウザの道から LWJGL の類へ静的に届かせないため。
 */
public interface GlContext {

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
    void depthMask(boolean flag);
    void depthFunc(int func);
    void clearDepth(double depth);
    void cullFace(int mode);
    void frontFace(int mode);
    void blendFuncSeparate(int srcRgb, int dstRgb, int srcAlpha, int dstAlpha);
    /** SAMPLE_ALPHA_TO_ONE を enable できるか（WebGL2 には無い）。偽の時に呼ぶ側は alpha to coverage を使わず discard で抜く。 */
    boolean hasAlphaToOne();

    // ── バッファと頂点の配列 ──
    int createBuffer();
    void deleteBuffer(int buffer);
    void bindBuffer(int target, int buffer);
    void bufferData(int target, float[] data, int usage);
    /** data の position から limit までを送る（WebGL2 版は subarray）。 */
    void bufferData(int target, FloatBuffer data, int usage);
    void bufferData(int target, int[] data, int usage);
    int createVertexArray();
    void deleteVertexArray(int array);
    void bindVertexArray(int array);
    void enableVertexAttribArray(int index);
    void vertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset);
    /** 整数のまま読む属性（ivec4 など）。vertexAttribPointer は float に直すので番号を渡せない。 */
    void vertexAttribIPointer(int index, int size, int type, int stride, int offset);
    void vertexAttribDivisor(int index, int divisor);
    void drawArrays(int mode, int first, int count);
    void drawArraysInstanced(int mode, int first, int count, int instanceCount);
    void drawElementsInstanced(int mode, int count, int type, int offset, int instanceCount);

    // ── テクスチャと sampler ──
    int createTexture();
    void deleteTexture(int texture);
    void bindTexture(int target, int texture);
    void activeTexture(int unit);
    void texParameteri(int target, int pname, int param);
    /** 画素の列（int ごとに ARGB）を、今 bind している TEXTURE_2D へ内部形式 RGBA（1 成分 8 ビット）で上げる（置き場も確保し直す）。 */
    void texImageArgb(int width, int height, IntBuffer argb);
    /** texImageArgb を段 level へ上げる。 */
    void texImageArgbLevel(int level, int width, int height, IntBuffer argb);
    /**
     * texture の段 0（width × height）を ARGB の int 列で argb へ読み戻す。行の並びは上げた時と同じ。RGBA8 のテクスチャだけ。
     * 呼んだ後の TEXTURE_2D の bind は実装で違う（デスクトップは texture・WebGL2 は元のまま）ので、続けて使う所は bind し直す。
     * WhyNot: 今 bind している物を読む形にしない — WebGL2 に glGetTexImage が無く、FBO へ付けて読むので texture を名指す。
     */
    void readTextureArgb(int texture, int width, int height, int[] argb);
    /**
     * texImageArgb と同じ形式で置き場を確保し、0（透明な黒）で埋める。
     * WhyNot: GL へ null を渡さない — デスクトップの GL では中身が決まらず、レンダーターゲットの「全画素透明から始まる」が崩れる（WebGL2 は null で 0 になる）。
     */
    void texImageArgbZero(int width, int height);
    /** 1 画素 1 バイトの濃さを、今 bind している TEXTURE_2D へ上げる。シェーダーが .a で読める形にする。
     *  rgb は実装で違う（デスクトップは 1・WebGL2 の ALPHA 形式は 0）ので、.a だけを読む SDF の字の道で使う。 */
    void texImageAlphaMask(int width, int height, ByteBuffer alpha);
    /** texImageAlphaMask で作ったテクスチャの (x, y) から width × height を差し替える。 */
    void texSubImageAlphaMask(int x, int y, int width, int height, ByteBuffer alpha);
    /** 画像のバイト列（1 画素 3 か 4 バイト・format は RGB か RGBA）を、今 bind している TEXTURE_2D へ上げる。 */
    void texImageBytes(int format, int width, int height, ByteBuffer pixels);
    /** 今 bind している TEXTURE_2D の置き場を RGBA16F で確保し、0 で埋める。 */
    void texImageRgba16fZero(int width, int height);
    /** 今 bind している TEXTURE_2D の置き場を 24 ビットの深度で確保する（中身は描いて決める）。 */
    void texImageDepth24(int width, int height);
    /**
     * 今 bind している TEXTURE_2D の置き場を RGBA32F で確保する（中身は texSubImageRgba32f で書く。書いていない所の値は決まらない）。
     * 読む時の filter は NEAREST にする。WebGL2 の RGBA32F は LINEAR で読むと不完全なテクスチャになり、読むと 0 が返る。
     */
    void texImageRgba32f(int width, int height);
    /** texImageRgba32f で作ったテクスチャの (x, y) から width × height を、pixels の position から差し替える（1 画素 4 個の float）。 */
    void texSubImageRgba32f(int x, int y, int width, int height, FloatBuffer pixels);
    int createSampler();
    void bindSampler(int unit, int sampler);
    void samplerParameteri(int sampler, int pname, int param);

    // ── framebuffer と renderbuffer ──
    int createFramebuffer();
    void deleteFramebuffer(int framebuffer);
    void bindFramebuffer(int target, int framebuffer);
    int checkFramebufferStatus(int target);
    void framebufferTexture2D(int target, int attachment, int textarget, int texture, int level);
    void framebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer);
    /** 今 bind している FBO の色の出口を切る（深度だけを描く FBO）。 */
    void useNoColorBuffer();
    void blitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter);
    int createRenderbuffer();
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
    void uniform4f(int location, float v0, float v1, float v2, float v3);
    void uniform1fv(int location, float[] value);
    void uniform2fv(int location, float[] value);
    void uniform3fv(int location, float[] value);
    void uniformMatrix4fv(int location, boolean transpose, float[] value);

    // ── GPU へ渡す直接バッファ（取ったら必ず返す）──
    // 使うのは毎コマか 1 回ずつ取って返す物と、持ち回す RenderBuf だけ。長く持って GC に任せる物は java.nio の allocateDirect で取る
    // （返す人がいないまま漏れるのと、純粋な関数に gl を渡すことになるのを避ける）。
    FloatBuffer allocFloats(int count);
    void freeFloats(FloatBuffer buffer);
    IntBuffer allocInts(int count);
    void freeInts(IntBuffer buffer);
    ByteBuffer allocBytes(int count);
    void freeBytes(ByteBuffer buffer);
}
