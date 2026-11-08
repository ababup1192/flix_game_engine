package fge.web;

import fge.gl.GlContext;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.typedarrays.Float32Array;
import org.teavm.jso.typedarrays.Int32Array;
import org.teavm.jso.typedarrays.Uint8Array;

/**
 * GlContext の WebGL2 版。GL の物（テクスチャ・バッファ・program・uniform の location など）は fge-web.js の表（fgeH）に置き、
 * Java と Flix には int のハンドルだけを見せる（0 は null・uniform の location の -1 も null）。
 * 呼べるのは fge-web.js が canvas から WebGL2 の文脈（fgeGl）を取った後だけ。
 *
 * WhyNot: JS の物（WebGLTexture など）を Java の欄や配列に持たない — TeaVM の wasm-gc では JS の物は Java の Object の木に入らず、
 *   総称のデータや Object を受ける所へ渡すと wasm のコンパイルで落ちる。表は JS の側に置き、引くのも JS の中でする。
 */
public final class WebGl2 implements GlContext {

    // ── 状態 ──
    @JSBody(params = {"cap"}, script = "fgeGl.enable(cap);")
    private static native void jsEnable(int cap);
    public void enable(int cap) { jsEnable(cap); }
    @JSBody(params = {"cap"}, script = "fgeGl.disable(cap);")
    private static native void jsDisable(int cap);
    public void disable(int cap) { jsDisable(cap); }
    @JSBody(params = {"x", "y", "w", "h"}, script = "fgeGl.viewport(x, y, w, h);")
    private static native void jsViewport(int x, int y, int width, int height);
    public void viewport(int x, int y, int width, int height) { jsViewport(x, y, width, height); }
    @JSBody(params = {"x", "y", "w", "h"}, script = "fgeGl.scissor(x, y, w, h);")
    private static native void jsScissor(int x, int y, int width, int height);
    public void scissor(int x, int y, int width, int height) { jsScissor(x, y, width, height); }
    @JSBody(params = {"r", "g", "b", "a"}, script = "fgeGl.clearColor(r, g, b, a);")
    private static native void jsClearColor(float r, float g, float b, float a);
    public void clearColor(float r, float g, float b, float a) { jsClearColor(r, g, b, a); }
    @JSBody(params = {"s"}, script = "fgeGl.clearStencil(s);")
    private static native void jsClearStencil(int s);
    public void clearStencil(int s) { jsClearStencil(s); }
    @JSBody(params = {"mask"}, script = "fgeGl.clear(mask);")
    private static native void jsClear(int mask);
    public void clear(int mask) { jsClear(mask); }
    @JSBody(params = {"s", "d"}, script = "fgeGl.blendFunc(s, d);")
    private static native void jsBlendFunc(int sfactor, int dfactor);
    public void blendFunc(int sfactor, int dfactor) { jsBlendFunc(sfactor, dfactor); }
    @JSBody(params = {"r", "g", "b", "a"}, script = "fgeGl.colorMask(r, g, b, a);")
    private static native void jsColorMask(boolean r, boolean g, boolean b, boolean a);
    public void colorMask(boolean r, boolean g, boolean b, boolean a) { jsColorMask(r, g, b, a); }
    @JSBody(params = {"mask"}, script = "fgeGl.stencilMask(mask);")
    private static native void jsStencilMask(int mask);
    public void stencilMask(int mask) { jsStencilMask(mask); }
    @JSBody(params = {"f", "r", "m"}, script = "fgeGl.stencilFunc(f, r, m);")
    private static native void jsStencilFunc(int func, int ref, int mask);
    public void stencilFunc(int func, int ref, int mask) { jsStencilFunc(func, ref, mask); }
    @JSBody(params = {"a", "b", "c"}, script = "fgeGl.stencilOp(a, b, c);")
    private static native void jsStencilOp(int sfail, int dpfail, int dppass);
    public void stencilOp(int sfail, int dpfail, int dppass) { jsStencilOp(sfail, dpfail, dppass); }
    @JSBody(params = {"p", "v"}, script = "fgeGl.pixelStorei(p, v);")
    private static native void jsPixelStorei(int pname, int param);
    public void pixelStorei(int pname, int param) { jsPixelStorei(pname, param); }
    /** 数を返す pname だけ（render_gl の 2D の道が引くのは MAX_SAMPLES）。物を返す pname は 0。 */
    @JSBody(params = {"p"}, script = "var v = fgeGl.getParameter(p); return (typeof v === 'number') ? v : 0;")
    private static native int jsGetInteger(int pname);
    public int getInteger(int pname) { return jsGetInteger(pname); }
    @JSBody(params = {"f"}, script = "fgeGl.depthMask(f);")
    private static native void jsDepthMask(boolean flag);
    public void depthMask(boolean flag) { jsDepthMask(flag); }
    @JSBody(params = {"f"}, script = "fgeGl.depthFunc(f);")
    private static native void jsDepthFunc(int func);
    public void depthFunc(int func) { jsDepthFunc(func); }
    @JSBody(params = {"d"}, script = "fgeGl.clearDepth(d);")
    private static native void jsClearDepth(double depth);
    public void clearDepth(double depth) { jsClearDepth(depth); }
    @JSBody(params = {"m"}, script = "fgeGl.cullFace(m);")
    private static native void jsCullFace(int mode);
    public void cullFace(int mode) { jsCullFace(mode); }
    @JSBody(params = {"m"}, script = "fgeGl.frontFace(m);")
    private static native void jsFrontFace(int mode);
    public void frontFace(int mode) { jsFrontFace(mode); }
    @JSBody(params = {"a", "b", "c", "d"}, script = "fgeGl.blendFuncSeparate(a, b, c, d);")
    private static native void jsBlendFuncSeparate(int srcRgb, int dstRgb, int srcAlpha, int dstAlpha);
    public void blendFuncSeparate(int srcRgb, int dstRgb, int srcAlpha, int dstAlpha) { jsBlendFuncSeparate(srcRgb, dstRgb, srcAlpha, dstAlpha); }
    public boolean hasAlphaToOne() { return false; }

    // ── バッファと頂点の配列 ──
    @JSBody(script = "return fgeNew(fgeGl.createBuffer());")
    private static native int jsCreateBuffer();
    public int createBuffer() { return jsCreateBuffer(); }
    @JSBody(params = {"id"}, script = "fgeGl.deleteBuffer(fgeH[id]); fgeFree(id);")
    private static native void jsDeleteBuffer(int buffer);
    public void deleteBuffer(int buffer) { jsDeleteBuffer(buffer); }
    @JSBody(params = {"t", "id"}, script = "fgeGl.bindBuffer(t, fgeH[id]);")
    private static native void jsBindBuffer(int target, int buffer);
    public void bindBuffer(int target, int buffer) { jsBindBuffer(target, buffer); }

    @JSBody(params = {"t", "data", "usage"}, script = "fgeGl.bufferData(t, data, usage);")
    private static native void bufferDataView(int target, JSObject data, int usage);
    @JSBody(params = {"t", "size", "usage"}, script = "fgeGl.bufferData(t, size, usage);")
    private static native void bufferDataSize(int target, int size, int usage);
    @JSBody(params = {"t", "data", "usage", "from", "count"}, script = "fgeGl.bufferData(t, data, usage, from, count);")
    private static native void bufferDataRange(int target, JSObject data, int usage, int from, int count);

    public void bufferData(int target, float[] data, int usage) {
        bufferDataView(target, Float32Array.copyFromJavaArray(data), usage);
    }

    public void bufferData(int target, FloatBuffer data, int usage) {
        FloatBuffer direct = data.isDirect() ? data : copyFloats(data);
        int from = direct.position();
        int count = direct.remaining();
        // WhyNot: 0 個を範囲つきで渡さない — WebGL2 は length 0 を「最後まで」と読む。
        if (count == 0) { bufferDataSize(target, 0, usage); return; }
        // WhyNot: 送る範囲を view の作り方に任せない — fromJavaBuffer が position を見るかは版で揺れうるので、頭から終わりの view を作って範囲を渡す。
        bufferDataRange(target, Float32Array.fromJavaBuffer(whole(direct)), usage, from, count);
    }

    public void bufferData(int target, int[] data, int usage) {
        bufferDataView(target, Int32Array.copyFromJavaArray(data), usage);
    }

    @JSBody(script = "return fgeNew(fgeGl.createVertexArray());")
    private static native int jsCreateVertexArray();
    public int createVertexArray() { return jsCreateVertexArray(); }
    @JSBody(params = {"id"}, script = "fgeGl.deleteVertexArray(fgeH[id]); fgeFree(id);")
    private static native void jsDeleteVertexArray(int array);
    public void deleteVertexArray(int array) { jsDeleteVertexArray(array); }
    @JSBody(params = {"id"}, script = "fgeGl.bindVertexArray(fgeH[id]);")
    private static native void jsBindVertexArray(int array);
    public void bindVertexArray(int array) { jsBindVertexArray(array); }
    @JSBody(params = {"i"}, script = "fgeGl.enableVertexAttribArray(i);")
    private static native void jsEnableVertexAttribArray(int index);
    public void enableVertexAttribArray(int index) { jsEnableVertexAttribArray(index); }
    @JSBody(params = {"i", "size", "type", "norm", "stride", "offset"}, script = "fgeGl.vertexAttribPointer(i, size, type, norm, stride, offset);")
    private static native void jsVertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset);
    public void vertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset) { jsVertexAttribPointer(index, size, type, normalized, stride, offset); }
    @JSBody(params = {"i", "size", "type", "stride", "offset"}, script = "fgeGl.vertexAttribIPointer(i, size, type, stride, offset);")
    private static native void jsVertexAttribIPointer(int index, int size, int type, int stride, int offset);
    public void vertexAttribIPointer(int index, int size, int type, int stride, int offset) { jsVertexAttribIPointer(index, size, type, stride, offset); }
    @JSBody(params = {"i", "d"}, script = "fgeGl.vertexAttribDivisor(i, d);")
    private static native void jsVertexAttribDivisor(int index, int divisor);
    public void vertexAttribDivisor(int index, int divisor) { jsVertexAttribDivisor(index, divisor); }
    @JSBody(params = {"m", "f", "c"}, script = "fgeGl.drawArrays(m, f, c);")
    private static native void jsDrawArrays(int mode, int first, int count);
    public void drawArrays(int mode, int first, int count) { jsDrawArrays(mode, first, count); }
    @JSBody(params = {"m", "f", "c", "n"}, script = "fgeGl.drawArraysInstanced(m, f, c, n);")
    private static native void jsDrawArraysInstanced(int mode, int first, int count, int instanceCount);
    public void drawArraysInstanced(int mode, int first, int count, int instanceCount) { jsDrawArraysInstanced(mode, first, count, instanceCount); }
    @JSBody(params = {"m", "c", "t", "o", "n"}, script = "fgeGl.drawElementsInstanced(m, c, t, o, n);")
    private static native void jsDrawElementsInstanced(int mode, int count, int type, int offset, int instanceCount);
    public void drawElementsInstanced(int mode, int count, int type, int offset, int instanceCount) { jsDrawElementsInstanced(mode, count, type, offset, instanceCount); }

    // ── テクスチャと sampler ──
    @JSBody(script = "return fgeNew(fgeGl.createTexture());")
    private static native int jsCreateTexture();
    public int createTexture() { return jsCreateTexture(); }
    @JSBody(params = {"id"}, script = "fgeGl.deleteTexture(fgeH[id]); fgeFree(id);")
    private static native void jsDeleteTexture(int texture);
    public void deleteTexture(int texture) { jsDeleteTexture(texture); }
    @JSBody(params = {"t", "id"}, script = "fgeGl.bindTexture(t, fgeH[id]);")
    private static native void jsBindTexture(int target, int texture);
    public void bindTexture(int target, int texture) { jsBindTexture(target, texture); }
    @JSBody(params = {"u"}, script = "fgeGl.activeTexture(u);")
    private static native void jsActiveTexture(int unit);
    public void activeTexture(int unit) { jsActiveTexture(unit); }
    @JSBody(params = {"t", "p", "v"}, script = "fgeGl.texParameteri(t, p, v);")
    private static native void jsTexParameteri(int target, int pname, int param);
    public void texParameteri(int target, int pname, int param) { jsTexParameteri(target, pname, param); }

    /** ARGB の int 列を RGBA のバイトへ並べ替えて RGBA8 で上げる（WebGL2 に BGRA と 8_8_8_8_REV が無い）。 */
    @JSBody(params = {"level", "w", "h", "argb", "from"}, script = "fgeTexImageArgbLevel(level, w, h, argb, from);")
    private static native void texImageArgbView(int level, int width, int height, JSObject argb, int from);

    public void texImageArgb(int width, int height, IntBuffer argb) { texImageArgbLevel(0, width, height, argb); }

    public void texImageArgbLevel(int level, int width, int height, IntBuffer argb) {
        IntBuffer direct = argb.isDirect() ? argb : copyInts(argb);
        texImageArgbView(level, width, height, Int32Array.fromJavaBuffer(whole(direct)), direct.position());
    }

    @JSBody(params = {"id", "w", "h", "argb"}, script = "fgeReadTextureArgb(id, w, h, argb);")
    private static native void readTextureArgbView(int texture, int width, int height, JSObject argb);

    public void readTextureArgb(int texture, int width, int height, int[] argb) {
        int count = width * height;
        IntBuffer direct = directInts(count);
        readTextureArgbView(texture, width, height, Int32Array.fromJavaBuffer(whole(direct)));
        direct.get(argb, 0, count);
    }

    public boolean prefersGpuMipmap() { return true; }

    @JSBody(params = {"target"}, script = "fgeGl.generateMipmap(target);")
    private static native void jsGenerateMipmap(int target);
    public void generateMipmap(int target) { jsGenerateMipmap(target); }

    @JSBody(params = {"key"}, script = "return fgeTexImagePlatform(key);")
    private static native boolean jsTexImagePlatform(String key);
    public boolean texImagePlatform(String key) { return jsTexImagePlatform(key); }

    @JSBody(params = {"id", "w", "h"}, script = "return fgeCopyTextureLevel0(id, w, h);")
    private static native boolean jsCopyTextureLevel0(int texture, int width, int height);
    public boolean copyTextureLevel0(int texture, int width, int height) { return jsCopyTextureLevel0(texture, width, height); }

    @JSBody(params = {"w", "h"}, script = "fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, w, h, 0, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, null);")
    private static native void jsTexImageArgbZero(int width, int height);
    public void texImageArgbZero(int width, int height) { jsTexImageArgbZero(width, height); }

    /** 旧来の ALPHA 形式（読むと (0,0,0,a)）。シェーダーは .a だけを読むので、デスクトップの R8＋swizzle と同じ字になる。 */
    @JSBody(params = {"w", "h", "px", "from"}, script = "fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.ALPHA, w, h, 0, fgeGl.ALPHA, fgeGl.UNSIGNED_BYTE, px, from);")
    private static native void texImageAlphaView(int width, int height, JSObject pixels, int from);
    @JSBody(params = {"x", "y", "w", "h", "px", "from"}, script = "fgeGl.texSubImage2D(fgeGl.TEXTURE_2D, 0, x, y, w, h, fgeGl.ALPHA, fgeGl.UNSIGNED_BYTE, px, from);")
    private static native void texSubImageAlphaView(int x, int y, int width, int height, JSObject pixels, int from);

    public void texImageAlphaMask(int width, int height, ByteBuffer alpha) {
        ByteBuffer direct = alpha.isDirect() ? alpha : copyBytes(alpha);
        texImageAlphaView(width, height, Uint8Array.fromJavaBuffer(whole(direct)), direct.position());
    }

    public void texSubImageAlphaMask(int x, int y, int width, int height, ByteBuffer alpha) {
        ByteBuffer direct = alpha.isDirect() ? alpha : copyBytes(alpha);
        texSubImageAlphaView(x, y, width, height, Uint8Array.fromJavaBuffer(whole(direct)), direct.position());
    }

    @JSBody(params = {"f", "w", "h", "px", "from"}, script = "fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, f, w, h, 0, f, fgeGl.UNSIGNED_BYTE, px, from);")
    private static native void texImageBytesView(int format, int width, int height, JSObject pixels, int from);

    public void texImageBytes(int format, int width, int height, ByteBuffer pixels) {
        ByteBuffer direct = pixels.isDirect() ? pixels : copyBytes(pixels);
        texImageBytesView(format, width, height, Uint8Array.fromJavaBuffer(whole(direct)), direct.position());
    }

    @JSBody(params = {"w", "h"}, script = "fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA16F, w, h, 0, fgeGl.RGBA, fgeGl.HALF_FLOAT, null);")
    private static native void jsTexImageRgba16fZero(int width, int height);
    public void texImageRgba16fZero(int width, int height) { jsTexImageRgba16fZero(width, height); }

    /** WebGL2 の DEPTH_COMPONENT24 は UNSIGNED_INT とだけ組める（デスクトップの FLOAT は通らない）。 */
    @JSBody(params = {"w", "h"}, script = "fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.DEPTH_COMPONENT24, w, h, 0, fgeGl.DEPTH_COMPONENT, fgeGl.UNSIGNED_INT, null);")
    private static native void jsTexImageDepth24(int width, int height);
    public void texImageDepth24(int width, int height) { jsTexImageDepth24(width, height); }

    @JSBody(params = {"w", "h"}, script = "fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA32F, w, h, 0, fgeGl.RGBA, fgeGl.FLOAT, null);")
    private static native void jsTexImageRgba32f(int width, int height);
    public void texImageRgba32f(int width, int height) { jsTexImageRgba32f(width, height); }

    @JSBody(params = {"x", "y", "w", "h", "px", "from"}, script = "fgeGl.texSubImage2D(fgeGl.TEXTURE_2D, 0, x, y, w, h, fgeGl.RGBA, fgeGl.FLOAT, px, from);")
    private static native void texSubImageRgba32fView(int x, int y, int width, int height, JSObject pixels, int from);
    public void texSubImageRgba32f(int x, int y, int width, int height, FloatBuffer pixels) {
        FloatBuffer direct = pixels.isDirect() ? pixels : copyFloats(pixels);
        texSubImageRgba32fView(x, y, width, height, Float32Array.fromJavaBuffer(whole(direct)), direct.position());
    }

    @JSBody(script = "return fgeNew(fgeGl.createSampler());")
    private static native int jsCreateSampler();
    public int createSampler() { return jsCreateSampler(); }
    @JSBody(params = {"u", "id"}, script = "fgeGl.bindSampler(u, fgeH[id]);")
    private static native void jsBindSampler(int unit, int sampler);
    public void bindSampler(int unit, int sampler) { jsBindSampler(unit, sampler); }
    @JSBody(params = {"id", "p", "v"}, script = "fgeGl.samplerParameteri(fgeH[id], p, v);")
    private static native void jsSamplerParameteri(int sampler, int pname, int param);
    public void samplerParameteri(int sampler, int pname, int param) { jsSamplerParameteri(sampler, pname, param); }

    // ── framebuffer と renderbuffer ──
    @JSBody(script = "return fgeNew(fgeGl.createFramebuffer());")
    private static native int jsCreateFramebuffer();
    public int createFramebuffer() { return jsCreateFramebuffer(); }
    @JSBody(params = {"id"}, script = "fgeGl.deleteFramebuffer(fgeH[id]); fgeFree(id);")
    private static native void jsDeleteFramebuffer(int framebuffer);
    public void deleteFramebuffer(int framebuffer) { jsDeleteFramebuffer(framebuffer); }
    @JSBody(params = {"t", "id"}, script = "fgeGl.bindFramebuffer(t, fgeH[id]);")
    private static native void jsBindFramebuffer(int target, int framebuffer);
    public void bindFramebuffer(int target, int framebuffer) { jsBindFramebuffer(target, framebuffer); }
    @JSBody(params = {"t"}, script = "return fgeGl.checkFramebufferStatus(t);")
    private static native int jsCheckFramebufferStatus(int target);
    public int checkFramebufferStatus(int target) { return jsCheckFramebufferStatus(target); }
    @JSBody(params = {"t", "a", "tt", "id", "lv"}, script = "fgeGl.framebufferTexture2D(t, a, tt, fgeH[id], lv);")
    private static native void jsFramebufferTexture2D(int target, int attachment, int textarget, int texture, int level);
    public void framebufferTexture2D(int target, int attachment, int textarget, int texture, int level) { jsFramebufferTexture2D(target, attachment, textarget, texture, level); }
    @JSBody(params = {"t", "a", "rt", "id"}, script = "fgeGl.framebufferRenderbuffer(t, a, rt, fgeH[id]);")
    private static native void jsFramebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer);
    public void framebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer) { jsFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer); }
    @JSBody(script = "fgeGl.drawBuffers([fgeGl.NONE]); fgeGl.readBuffer(fgeGl.NONE);")
    private static native void jsUseNoColorBuffer();
    public void useNoColorBuffer() { jsUseNoColorBuffer(); }
    @JSBody(params = {"a", "b", "c", "d", "e", "f", "g", "h", "m", "fl"}, script = "fgeGl.blitFramebuffer(a, b, c, d, e, f, g, h, m, fl);")
    private static native void jsBlitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter);
    public void blitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter) { jsBlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter); }
    @JSBody(script = "return fgeNew(fgeGl.createRenderbuffer());")
    private static native int jsCreateRenderbuffer();
    public int createRenderbuffer() { return jsCreateRenderbuffer(); }
    @JSBody(params = {"id"}, script = "fgeGl.deleteRenderbuffer(fgeH[id]); fgeFree(id);")
    private static native void jsDeleteRenderbuffer(int renderbuffer);
    public void deleteRenderbuffer(int renderbuffer) { jsDeleteRenderbuffer(renderbuffer); }
    @JSBody(params = {"t", "id"}, script = "fgeGl.bindRenderbuffer(t, fgeH[id]);")
    private static native void jsBindRenderbuffer(int target, int renderbuffer);
    public void bindRenderbuffer(int target, int renderbuffer) { jsBindRenderbuffer(target, renderbuffer); }
    @JSBody(params = {"t", "f", "w", "h"}, script = "fgeGl.renderbufferStorage(t, f, w, h);")
    private static native void jsRenderbufferStorage(int target, int internalformat, int width, int height);
    public void renderbufferStorage(int target, int internalformat, int width, int height) { jsRenderbufferStorage(target, internalformat, width, height); }
    @JSBody(params = {"t", "s", "f", "w", "h"}, script = "fgeGl.renderbufferStorageMultisample(t, s, f, w, h);")
    private static native void jsRenderbufferStorageMultisample(int target, int samples, int internalformat, int width, int height);
    public void renderbufferStorageMultisample(int target, int samples, int internalformat, int width, int height) { jsRenderbufferStorageMultisample(target, samples, internalformat, width, height); }

    // ── シェーダーと uniform ──
    @JSBody(params = {"type"}, script = "return fgeNew(fgeGl.createShader(type));")
    private static native int jsCreateShader(int type);
    public int createShader(int type) { return jsCreateShader(type); }
    /** デスクトップの #version 330 core 行を GLSL ES 3.00 の頭（と precision）へ替えて渡す。 */
    @JSBody(params = {"id", "src"}, script = "fgeGl.shaderSource(fgeH[id], fgeEsSource(src));")
    private static native void jsShaderSource(int shader, String source);
    public void shaderSource(int shader, String source) { jsShaderSource(shader, source); }
    @JSBody(params = {"id"}, script = "fgeGl.compileShader(fgeH[id]);")
    private static native void jsCompileShader(int shader);
    public void compileShader(int shader) { jsCompileShader(shader); }
    @JSBody(params = {"id", "p"}, script = "var v = fgeGl.getShaderParameter(fgeH[id], p); return (v === true) ? 1 : (v === false || v === null) ? 0 : v;")
    private static native int jsGetShaderi(int shader, int pname);
    public int getShaderi(int shader, int pname) { return jsGetShaderi(shader, pname); }
    @JSBody(params = {"id"}, script = "return fgeGl.getShaderInfoLog(fgeH[id]) || '';")
    private static native String jsGetShaderInfoLog(int shader);
    public String getShaderInfoLog(int shader) { return jsGetShaderInfoLog(shader); }
    @JSBody(params = {"id"}, script = "fgeGl.deleteShader(fgeH[id]); fgeFree(id);")
    private static native void jsDeleteShader(int shader);
    public void deleteShader(int shader) { jsDeleteShader(shader); }
    @JSBody(script = "return fgeNew(fgeGl.createProgram());")
    private static native int jsCreateProgram();
    public int createProgram() { return jsCreateProgram(); }
    @JSBody(params = {"p", "s"}, script = "fgeGl.attachShader(fgeH[p], fgeH[s]);")
    private static native void jsAttachShader(int program, int shader);
    public void attachShader(int program, int shader) { jsAttachShader(program, shader); }
    @JSBody(params = {"id"}, script = "fgeGl.linkProgram(fgeH[id]);")
    private static native void jsLinkProgram(int program);
    public void linkProgram(int program) { jsLinkProgram(program); }
    @JSBody(params = {"id", "p"}, script = "var v = fgeGl.getProgramParameter(fgeH[id], p); return (v === true) ? 1 : (v === false || v === null) ? 0 : v;")
    private static native int jsGetProgrami(int program, int pname);
    public int getProgrami(int program, int pname) { return jsGetProgrami(program, pname); }
    @JSBody(params = {"id"}, script = "return fgeGl.getProgramInfoLog(fgeH[id]) || '';")
    private static native String jsGetProgramInfoLog(int program);
    public String getProgramInfoLog(int program) { return jsGetProgramInfoLog(program); }
    @JSBody(params = {"id"}, script = "fgeDeleteProgram(id);")
    private static native void jsDeleteProgram(int program);
    public void deleteProgram(int program) { jsDeleteProgram(program); }
    @JSBody(params = {"id"}, script = "fgeGl.useProgram(fgeH[id]);")
    private static native void jsUseProgram(int program);
    public void useProgram(int program) { jsUseProgram(program); }
    /** program と名前ごとに 1 つの int を返す（同じ組は同じ int）。無い名前は -1。 */
    @JSBody(params = {"id", "name"}, script = "return fgeUniformLocation(id, name);")
    private static native int jsGetUniformLocation(int program, String name);
    public int getUniformLocation(int program, String name) { return jsGetUniformLocation(program, name); }
    @JSBody(params = {"l", "v"}, script = "if (l >= 0) fgeGl.uniform1i(fgeU[l], v);")
    private static native void jsUniform1i(int location, int v0);
    public void uniform1i(int location, int v0) { jsUniform1i(location, v0); }
    @JSBody(params = {"l", "v"}, script = "if (l >= 0) fgeGl.uniform1f(fgeU[l], v);")
    private static native void jsUniform1f(int location, float v0);
    public void uniform1f(int location, float v0) { jsUniform1f(location, v0); }
    @JSBody(params = {"l", "a", "b"}, script = "if (l >= 0) fgeGl.uniform2f(fgeU[l], a, b);")
    private static native void jsUniform2f(int location, float v0, float v1);
    public void uniform2f(int location, float v0, float v1) { jsUniform2f(location, v0, v1); }
    @JSBody(params = {"l", "a", "b", "c"}, script = "if (l >= 0) fgeGl.uniform3f(fgeU[l], a, b, c);")
    private static native void jsUniform3f(int location, float v0, float v1, float v2);
    public void uniform3f(int location, float v0, float v1, float v2) { jsUniform3f(location, v0, v1, v2); }
    @JSBody(params = {"l", "a", "b", "c", "d"}, script = "if (l >= 0) fgeGl.uniform4f(fgeU[l], a, b, c, d);")
    private static native void jsUniform4f(int location, float v0, float v1, float v2, float v3);
    public void uniform4f(int location, float v0, float v1, float v2, float v3) { jsUniform4f(location, v0, v1, v2, v3); }
    @JSBody(params = {"l", "v"}, script = "fgeGl.uniform1fv(fgeU[l], v);")
    private static native void uniform1fvView(int location, JSObject value);
    public void uniform1fv(int location, float[] value) {
        if (location >= 0) uniform1fvView(location, Float32Array.copyFromJavaArray(value));
    }
    @JSBody(params = {"l", "v"}, script = "fgeGl.uniform2fv(fgeU[l], v);")
    private static native void uniform2fvView(int location, JSObject value);
    public void uniform2fv(int location, float[] value) {
        if (location >= 0) uniform2fvView(location, Float32Array.copyFromJavaArray(value));
    }
    @JSBody(params = {"l", "v"}, script = "fgeGl.uniform3fv(fgeU[l], v);")
    private static native void uniform3fvView(int location, JSObject value);
    public void uniform3fv(int location, float[] value) {
        if (location >= 0) uniform3fvView(location, Float32Array.copyFromJavaArray(value));
    }
    @JSBody(params = {"l", "t", "v"}, script = "if (l >= 0) fgeGl.uniformMatrix4fv(fgeU[l], t, v);")
    private static native void uniformMatrix4fvView(int location, boolean transpose, JSObject value);

    public void uniformMatrix4fv(int location, boolean transpose, float[] value) {
        if (location >= 0) uniformMatrix4fvView(location, transpose, Float32Array.copyFromJavaArray(value));
    }

    // ── GPU へ渡す直接バッファ（GC に任せるので返す所は何もしない）──
    public FloatBuffer allocFloats(int count) { return ByteBuffer.allocateDirect(count * 4).order(ByteOrder.nativeOrder()).asFloatBuffer(); }
    public void freeFloats(FloatBuffer buffer) { }
    public IntBuffer allocInts(int count) { return directInts(count); }
    public void freeInts(IntBuffer buffer) { }
    public ByteBuffer allocBytes(int count) { return ByteBuffer.allocateDirect(count).order(ByteOrder.nativeOrder()); }
    public void freeBytes(ByteBuffer buffer) { }

    // ── 下請け ──

    /** 最低でも 1 個ぶんの直接バッファ（0 個の view を JS へ渡さない）。 */
    static IntBuffer directInts(int count) {
        return ByteBuffer.allocateDirect(Math.max(1, count) * 4).order(ByteOrder.nativeOrder()).asIntBuffer();
    }

    /** 頭から容量の終わりまでを見る複製（元の position と limit は変えない）。 */
    private static <B extends Buffer> B whole(B buffer) {
        @SuppressWarnings("unchecked")
        B dup = (B) duplicateOf(buffer);
        dup.position(0);
        dup.limit(dup.capacity());
        return dup;
    }

    private static Buffer duplicateOf(Buffer buffer) {
        if (buffer instanceof FloatBuffer) return ((FloatBuffer) buffer).duplicate();
        if (buffer instanceof IntBuffer) return ((IntBuffer) buffer).duplicate();
        return ((ByteBuffer) buffer).duplicate();
    }

    private static FloatBuffer copyFloats(FloatBuffer src) {
        FloatBuffer dst = ByteBuffer.allocateDirect(src.capacity() * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        FloatBuffer from = src.duplicate();
        from.position(0);
        from.limit(from.capacity());
        dst.put(from);
        dst.position(src.position());
        dst.limit(src.limit());
        return dst;
    }

    private static IntBuffer copyInts(IntBuffer src) {
        IntBuffer dst = directInts(src.capacity());
        IntBuffer from = src.duplicate();
        from.position(0);
        from.limit(from.capacity());
        dst.put(from);
        dst.position(src.position());
        dst.limit(src.limit());
        return dst;
    }

    private static ByteBuffer copyBytes(ByteBuffer src) {
        ByteBuffer dst = ByteBuffer.allocateDirect(src.capacity()).order(ByteOrder.nativeOrder());
        ByteBuffer from = src.duplicate();
        from.position(0);
        from.limit(from.capacity());
        dst.put(from);
        dst.position(src.position());
        dst.limit(src.limit());
        return dst;
    }
}
