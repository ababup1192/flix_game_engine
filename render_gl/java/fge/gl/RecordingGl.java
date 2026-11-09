package fge.gl;

import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.util.zip.CRC32;

/**
 * 呼ばれた関数と引数（と戻り値）を 1 行ずつ控えてから inner へ渡す GlContext。描く手順を替える前と後で、呼び出しの並びを比べるのに使う。
 * バッファと配列は長さと、送る範囲（position から limit）の CRC32 を控える。シェーダーの字は長さとハッシュ、uniform の名前はそのまま。
 * 画面のコマの区切りは markFrame で入れ、drainLog で取り出して空にする。setEnabled(false) の間は控えない。
 * GlContext に関数を足したら、ここにも同じ形の 1 行を足す（足さないと javac が止める）。
 */
public final class RecordingGl implements GlContext {
    private final GlContext inner;
    private final StringBuilder log = new StringBuilder();
    private boolean enabled = true;

    public RecordingGl(GlContext inner) { this.inner = inner; }

    /** 控えた行の全部（1 行 1 呼び出し）を返して空にする。 */
    public String drainLog() { String s = log.toString(); log.setLength(0); return s; }

    /** 控えるかどうか。 */
    public void setEnabled(boolean on) { enabled = on; }

    /** 画面のコマの区切りの行（--- frame n）を控える。 */
    public void markFrame(int frame) { if (enabled) log.append("--- frame ").append(frame).append('\n'); }

    private static String crcOf(ByteBuffer b) {
        CRC32 c = new CRC32();
        for (int i = b.position(); i < b.limit(); i++) c.update(b.get(i));
        return Long.toHexString(c.getValue());
    }
    private static String crcOfInts(IntBuffer b) {
        CRC32 c = new CRC32();
        for (int i = b.position(); i < b.limit(); i++) { int v = b.get(i); c.update(v); c.update(v >>> 8); c.update(v >>> 16); c.update(v >>> 24); }
        return Long.toHexString(c.getValue());
    }
    private static String crcOfFloats(FloatBuffer b) {
        CRC32 c = new CRC32();
        for (int i = b.position(); i < b.limit(); i++) { int v = Float.floatToRawIntBits(b.get(i)); c.update(v); c.update(v >>> 8); c.update(v >>> 16); c.update(v >>> 24); }
        return Long.toHexString(c.getValue());
    }
    private static String buf(Buffer b) {
        if (b == null) return "null";
        String crc = b instanceof ByteBuffer ? crcOf((ByteBuffer) b) : b instanceof IntBuffer ? crcOfInts((IntBuffer) b)
            : b instanceof FloatBuffer ? crcOfFloats((FloatBuffer) b) : "?";
        return "buf" + b.remaining() + ":" + crc;
    }
    private static String arr(float[] a) {
        if (a == null) return "null";
        CRC32 c = new CRC32();
        for (float f : a) { int v = Float.floatToRawIntBits(f); c.update(v); c.update(v >>> 8); c.update(v >>> 16); c.update(v >>> 24); }
        return "float" + a.length + ":" + Long.toHexString(c.getValue());
    }

    private static String arrInts(int[] a) {
        if (a == null) return "null";
        CRC32 c = new CRC32();
        for (int v : a) { c.update(v); c.update(v >>> 8); c.update(v >>> 16); c.update(v >>> 24); }
        return "int" + a.length + ":" + Long.toHexString(c.getValue());
    }

    public void enable(int cap) { if (enabled) log.append("enable").append(' ').append(cap).append('\n'); inner.enable(cap); }
    public void disable(int cap) { if (enabled) log.append("disable").append(' ').append(cap).append('\n'); inner.disable(cap); }
    public void viewport(int x, int y, int width, int height) { if (enabled) log.append("viewport").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append('\n'); inner.viewport(x, y, width, height); }
    public void scissor(int x, int y, int width, int height) { if (enabled) log.append("scissor").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append('\n'); inner.scissor(x, y, width, height); }
    public void clearColor(float r, float g, float b, float a) { if (enabled) log.append("clearColor").append(' ').append(r).append(' ').append(g).append(' ').append(b).append(' ').append(a).append('\n'); inner.clearColor(r, g, b, a); }
    public void clearStencil(int s) { if (enabled) log.append("clearStencil").append(' ').append(s).append('\n'); inner.clearStencil(s); }
    public void clear(int mask) { if (enabled) log.append("clear").append(' ').append(mask).append('\n'); inner.clear(mask); }
    public void blendFunc(int sfactor, int dfactor) { if (enabled) log.append("blendFunc").append(' ').append(sfactor).append(' ').append(dfactor).append('\n'); inner.blendFunc(sfactor, dfactor); }
    public void colorMask(boolean r, boolean g, boolean b, boolean a) { if (enabled) log.append("colorMask").append(' ').append(r).append(' ').append(g).append(' ').append(b).append(' ').append(a).append('\n'); inner.colorMask(r, g, b, a); }
    public void stencilMask(int mask) { if (enabled) log.append("stencilMask").append(' ').append(mask).append('\n'); inner.stencilMask(mask); }
    public void stencilFunc(int func, int ref, int mask) { if (enabled) log.append("stencilFunc").append(' ').append(func).append(' ').append(ref).append(' ').append(mask).append('\n'); inner.stencilFunc(func, ref, mask); }
    public void stencilOp(int sfail, int dpfail, int dppass) { if (enabled) log.append("stencilOp").append(' ').append(sfail).append(' ').append(dpfail).append(' ').append(dppass).append('\n'); inner.stencilOp(sfail, dpfail, dppass); }
    public void pixelStorei(int pname, int param) { if (enabled) log.append("pixelStorei").append(' ').append(pname).append(' ').append(param).append('\n'); inner.pixelStorei(pname, param); }
    public int getInteger(int pname) { int r = inner.getInteger(pname); if (enabled) log.append("getInteger").append(' ').append(pname).append(" -> ").append(r).append('\n'); return r; }
    public void depthMask(boolean flag) { if (enabled) log.append("depthMask").append(' ').append(flag).append('\n'); inner.depthMask(flag); }
    public void depthFunc(int func) { if (enabled) log.append("depthFunc").append(' ').append(func).append('\n'); inner.depthFunc(func); }
    public void clearDepth(double depth) { if (enabled) log.append("clearDepth").append(' ').append(depth).append('\n'); inner.clearDepth(depth); }
    public void cullFace(int mode) { if (enabled) log.append("cullFace").append(' ').append(mode).append('\n'); inner.cullFace(mode); }
    public void frontFace(int mode) { if (enabled) log.append("frontFace").append(' ').append(mode).append('\n'); inner.frontFace(mode); }
    public void blendFuncSeparate(int srcRgb, int dstRgb, int srcAlpha, int dstAlpha) { if (enabled) log.append("blendFuncSeparate").append(' ').append(srcRgb).append(' ').append(dstRgb).append(' ').append(srcAlpha).append(' ').append(dstAlpha).append('\n'); inner.blendFuncSeparate(srcRgb, dstRgb, srcAlpha, dstAlpha); }
    public boolean hasAlphaToOne() { boolean r = inner.hasAlphaToOne(); if (enabled) log.append("hasAlphaToOne").append(" -> ").append(r).append('\n'); return r; }
    public int createBuffer() { int r = inner.createBuffer(); if (enabled) log.append("createBuffer").append(" -> ").append(r).append('\n'); return r; }
    public void deleteBuffer(int buffer) { if (enabled) log.append("deleteBuffer").append(' ').append(buffer).append('\n'); inner.deleteBuffer(buffer); }
    public void bindBuffer(int target, int buffer) { if (enabled) log.append("bindBuffer").append(' ').append(target).append(' ').append(buffer).append('\n'); inner.bindBuffer(target, buffer); }
    public void bufferData(int target, float[] data, int usage) { if (enabled) log.append("bufferData").append(' ').append(target).append(' ').append(arr(data)).append(' ').append(usage).append('\n'); inner.bufferData(target, data, usage); }
    public void bufferData(int target, FloatBuffer data, int usage) { if (enabled) log.append("bufferData").append(' ').append(target).append(' ').append(buf(data)).append(' ').append(usage).append('\n'); inner.bufferData(target, data, usage); }
    public void bufferData(int target, int[] data, int usage) { if (enabled) log.append("bufferData").append(' ').append(target).append(' ').append(arrInts(data)).append(' ').append(usage).append('\n'); inner.bufferData(target, data, usage); }
    public int createVertexArray() { int r = inner.createVertexArray(); if (enabled) log.append("createVertexArray").append(" -> ").append(r).append('\n'); return r; }
    public void deleteVertexArray(int array) { if (enabled) log.append("deleteVertexArray").append(' ').append(array).append('\n'); inner.deleteVertexArray(array); }
    public void bindVertexArray(int array) { if (enabled) log.append("bindVertexArray").append(' ').append(array).append('\n'); inner.bindVertexArray(array); }
    public void enableVertexAttribArray(int index) { if (enabled) log.append("enableVertexAttribArray").append(' ').append(index).append('\n'); inner.enableVertexAttribArray(index); }
    public void vertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset) { if (enabled) log.append("vertexAttribPointer").append(' ').append(index).append(' ').append(size).append(' ').append(type).append(' ').append(normalized).append(' ').append(stride).append(' ').append(offset).append('\n'); inner.vertexAttribPointer(index, size, type, normalized, stride, offset); }
    public void vertexAttribIPointer(int index, int size, int type, int stride, int offset) { if (enabled) log.append("vertexAttribIPointer").append(' ').append(index).append(' ').append(size).append(' ').append(type).append(' ').append(stride).append(' ').append(offset).append('\n'); inner.vertexAttribIPointer(index, size, type, stride, offset); }
    public void vertexAttribDivisor(int index, int divisor) { if (enabled) log.append("vertexAttribDivisor").append(' ').append(index).append(' ').append(divisor).append('\n'); inner.vertexAttribDivisor(index, divisor); }
    public void drawArrays(int mode, int first, int count) { if (enabled) log.append("drawArrays").append(' ').append(mode).append(' ').append(first).append(' ').append(count).append('\n'); inner.drawArrays(mode, first, count); }
    public void drawArraysInstanced(int mode, int first, int count, int instanceCount) { if (enabled) log.append("drawArraysInstanced").append(' ').append(mode).append(' ').append(first).append(' ').append(count).append(' ').append(instanceCount).append('\n'); inner.drawArraysInstanced(mode, first, count, instanceCount); }
    public void drawElementsInstanced(int mode, int count, int type, int offset, int instanceCount) { if (enabled) log.append("drawElementsInstanced").append(' ').append(mode).append(' ').append(count).append(' ').append(type).append(' ').append(offset).append(' ').append(instanceCount).append('\n'); inner.drawElementsInstanced(mode, count, type, offset, instanceCount); }
    public int createTexture() { int r = inner.createTexture(); if (enabled) log.append("createTexture").append(" -> ").append(r).append('\n'); return r; }
    public void deleteTexture(int texture) { if (enabled) log.append("deleteTexture").append(' ').append(texture).append('\n'); inner.deleteTexture(texture); }
    public void bindTexture(int target, int texture) { if (enabled) log.append("bindTexture").append(' ').append(target).append(' ').append(texture).append('\n'); inner.bindTexture(target, texture); }
    public void activeTexture(int unit) { if (enabled) log.append("activeTexture").append(' ').append(unit).append('\n'); inner.activeTexture(unit); }
    public void texParameteri(int target, int pname, int param) { if (enabled) log.append("texParameteri").append(' ').append(target).append(' ').append(pname).append(' ').append(param).append('\n'); inner.texParameteri(target, pname, param); }
    public void texImageArgb(int width, int height, IntBuffer argb) { if (enabled) log.append("texImageArgb").append(' ').append(width).append(' ').append(height).append(' ').append(buf(argb)).append('\n'); inner.texImageArgb(width, height, argb); }
    public void texImageArgbLevel(int level, int width, int height, IntBuffer argb) { if (enabled) log.append("texImageArgbLevel").append(' ').append(level).append(' ').append(width).append(' ').append(height).append(' ').append(buf(argb)).append('\n'); inner.texImageArgbLevel(level, width, height, argb); }
    public void readTextureArgb(int texture, int width, int height, int[] argb) { inner.readTextureArgb(texture, width, height, argb); if (enabled) log.append("readTextureArgb").append(' ').append(texture).append(' ').append(width).append(' ').append(height).append(' ').append(arrInts(argb)).append('\n'); }
    public boolean prefersGpuMipmap() { boolean r = inner.prefersGpuMipmap(); if (enabled) log.append("prefersGpuMipmap").append(" -> ").append(r).append('\n'); return r; }
    public void generateMipmap(int target) { if (enabled) log.append("generateMipmap").append(' ').append(target).append('\n'); inner.generateMipmap(target); }
    public boolean texImagePlatform(String key) { boolean r = inner.texImagePlatform(key); if (enabled) log.append("texImagePlatform").append(' ').append(key).append(" -> ").append(r).append('\n'); return r; }
    public boolean copyTextureLevel0(int texture, int width, int height) { boolean r = inner.copyTextureLevel0(texture, width, height); if (enabled) log.append("copyTextureLevel0").append(' ').append(texture).append(' ').append(width).append(' ').append(height).append(" -> ").append(r).append('\n'); return r; }
    public void texImageArgbZero(int width, int height) { if (enabled) log.append("texImageArgbZero").append(' ').append(width).append(' ').append(height).append('\n'); inner.texImageArgbZero(width, height); }
    public void texImageAlphaMask(int width, int height, ByteBuffer alpha) { if (enabled) log.append("texImageAlphaMask").append(' ').append(width).append(' ').append(height).append(' ').append(buf(alpha)).append('\n'); inner.texImageAlphaMask(width, height, alpha); }
    public void texSubImageAlphaMask(int x, int y, int width, int height, ByteBuffer alpha) { if (enabled) log.append("texSubImageAlphaMask").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append(' ').append(buf(alpha)).append('\n'); inner.texSubImageAlphaMask(x, y, width, height, alpha); }
    public void texImageBytes(int format, int width, int height, ByteBuffer pixels) { if (enabled) log.append("texImageBytes").append(' ').append(format).append(' ').append(width).append(' ').append(height).append(' ').append(buf(pixels)).append('\n'); inner.texImageBytes(format, width, height, pixels); }
    public void texImageRgba16fZero(int width, int height) { if (enabled) log.append("texImageRgba16fZero").append(' ').append(width).append(' ').append(height).append('\n'); inner.texImageRgba16fZero(width, height); }
    public void texImageDepth24(int width, int height) { if (enabled) log.append("texImageDepth24").append(' ').append(width).append(' ').append(height).append('\n'); inner.texImageDepth24(width, height); }
    public void texImageRgba32f(int width, int height) { if (enabled) log.append("texImageRgba32f").append(' ').append(width).append(' ').append(height).append('\n'); inner.texImageRgba32f(width, height); }
    public void texSubImageRgba32f(int x, int y, int width, int height, FloatBuffer pixels) { if (enabled) log.append("texSubImageRgba32f").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append(' ').append(buf(pixels)).append('\n'); inner.texSubImageRgba32f(x, y, width, height, pixels); }
    public int createSampler() { int r = inner.createSampler(); if (enabled) log.append("createSampler").append(" -> ").append(r).append('\n'); return r; }
    public void bindSampler(int unit, int sampler) { if (enabled) log.append("bindSampler").append(' ').append(unit).append(' ').append(sampler).append('\n'); inner.bindSampler(unit, sampler); }
    public void samplerParameteri(int sampler, int pname, int param) { if (enabled) log.append("samplerParameteri").append(' ').append(sampler).append(' ').append(pname).append(' ').append(param).append('\n'); inner.samplerParameteri(sampler, pname, param); }
    public int createFramebuffer() { int r = inner.createFramebuffer(); if (enabled) log.append("createFramebuffer").append(" -> ").append(r).append('\n'); return r; }
    public void deleteFramebuffer(int framebuffer) { if (enabled) log.append("deleteFramebuffer").append(' ').append(framebuffer).append('\n'); inner.deleteFramebuffer(framebuffer); }
    public void bindFramebuffer(int target, int framebuffer) { if (enabled) log.append("bindFramebuffer").append(' ').append(target).append(' ').append(framebuffer).append('\n'); inner.bindFramebuffer(target, framebuffer); }
    public int checkFramebufferStatus(int target) { int r = inner.checkFramebufferStatus(target); if (enabled) log.append("checkFramebufferStatus").append(' ').append(target).append(" -> ").append(r).append('\n'); return r; }
    public void framebufferTexture2D(int target, int attachment, int textarget, int texture, int level) { if (enabled) log.append("framebufferTexture2D").append(' ').append(target).append(' ').append(attachment).append(' ').append(textarget).append(' ').append(texture).append(' ').append(level).append('\n'); inner.framebufferTexture2D(target, attachment, textarget, texture, level); }
    public void framebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer) { if (enabled) log.append("framebufferRenderbuffer").append(' ').append(target).append(' ').append(attachment).append(' ').append(renderbuffertarget).append(' ').append(renderbuffer).append('\n'); inner.framebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer); }
    public void useNoColorBuffer() { if (enabled) log.append("useNoColorBuffer").append('\n'); inner.useNoColorBuffer(); }
    public void blitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter) { if (enabled) log.append("blitFramebuffer").append(' ').append(srcX0).append(' ').append(srcY0).append(' ').append(srcX1).append(' ').append(srcY1).append(' ').append(dstX0).append(' ').append(dstY0).append(' ').append(dstX1).append(' ').append(dstY1).append(' ').append(mask).append(' ').append(filter).append('\n'); inner.blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter); }
    public int createRenderbuffer() { int r = inner.createRenderbuffer(); if (enabled) log.append("createRenderbuffer").append(" -> ").append(r).append('\n'); return r; }
    public void deleteRenderbuffer(int renderbuffer) { if (enabled) log.append("deleteRenderbuffer").append(' ').append(renderbuffer).append('\n'); inner.deleteRenderbuffer(renderbuffer); }
    public void bindRenderbuffer(int target, int renderbuffer) { if (enabled) log.append("bindRenderbuffer").append(' ').append(target).append(' ').append(renderbuffer).append('\n'); inner.bindRenderbuffer(target, renderbuffer); }
    public void renderbufferStorage(int target, int internalformat, int width, int height) { if (enabled) log.append("renderbufferStorage").append(' ').append(target).append(' ').append(internalformat).append(' ').append(width).append(' ').append(height).append('\n'); inner.renderbufferStorage(target, internalformat, width, height); }
    public void renderbufferStorageMultisample(int target, int samples, int internalformat, int width, int height) { if (enabled) log.append("renderbufferStorageMultisample").append(' ').append(target).append(' ').append(samples).append(' ').append(internalformat).append(' ').append(width).append(' ').append(height).append('\n'); inner.renderbufferStorageMultisample(target, samples, internalformat, width, height); }
    public int createShader(int type) { int r = inner.createShader(type); if (enabled) log.append("createShader").append(' ').append(type).append(" -> ").append(r).append('\n'); return r; }
    public void shaderSource(int shader, String source) { if (enabled) log.append("shaderSource").append(' ').append(shader).append(' ').append(source.length() + "#" + Integer.toHexString(source.hashCode())).append('\n'); inner.shaderSource(shader, source); }
    public void compileShader(int shader) { if (enabled) log.append("compileShader").append(' ').append(shader).append('\n'); inner.compileShader(shader); }
    public int getShaderi(int shader, int pname) { int r = inner.getShaderi(shader, pname); if (enabled) log.append("getShaderi").append(' ').append(shader).append(' ').append(pname).append(" -> ").append(r).append('\n'); return r; }
    public String getShaderInfoLog(int shader) { String r = inner.getShaderInfoLog(shader); if (enabled) log.append("getShaderInfoLog").append(' ').append(shader).append(" -> ").append(r.length()).append('\n'); return r; }
    public void deleteShader(int shader) { if (enabled) log.append("deleteShader").append(' ').append(shader).append('\n'); inner.deleteShader(shader); }
    public int createProgram() { int r = inner.createProgram(); if (enabled) log.append("createProgram").append(" -> ").append(r).append('\n'); return r; }
    public void attachShader(int program, int shader) { if (enabled) log.append("attachShader").append(' ').append(program).append(' ').append(shader).append('\n'); inner.attachShader(program, shader); }
    public void linkProgram(int program) { if (enabled) log.append("linkProgram").append(' ').append(program).append('\n'); inner.linkProgram(program); }
    public int getProgrami(int program, int pname) { int r = inner.getProgrami(program, pname); if (enabled) log.append("getProgrami").append(' ').append(program).append(' ').append(pname).append(" -> ").append(r).append('\n'); return r; }
    public String getProgramInfoLog(int program) { String r = inner.getProgramInfoLog(program); if (enabled) log.append("getProgramInfoLog").append(' ').append(program).append(" -> ").append(r.length()).append('\n'); return r; }
    public void deleteProgram(int program) { if (enabled) log.append("deleteProgram").append(' ').append(program).append('\n'); inner.deleteProgram(program); }
    public void useProgram(int program) { if (enabled) log.append("useProgram").append(' ').append(program).append('\n'); inner.useProgram(program); }
    public int getUniformLocation(int program, String name) { int r = inner.getUniformLocation(program, name); if (enabled) log.append("getUniformLocation").append(' ').append(program).append(' ').append(name).append(" -> ").append(r).append('\n'); return r; }
    public void uniform1i(int location, int v0) { if (enabled) log.append("uniform1i").append(' ').append(location).append(' ').append(v0).append('\n'); inner.uniform1i(location, v0); }
    public void uniform1f(int location, float v0) { if (enabled) log.append("uniform1f").append(' ').append(location).append(' ').append(v0).append('\n'); inner.uniform1f(location, v0); }
    public void uniform2f(int location, float v0, float v1) { if (enabled) log.append("uniform2f").append(' ').append(location).append(' ').append(v0).append(' ').append(v1).append('\n'); inner.uniform2f(location, v0, v1); }
    public void uniform3f(int location, float v0, float v1, float v2) { if (enabled) log.append("uniform3f").append(' ').append(location).append(' ').append(v0).append(' ').append(v1).append(' ').append(v2).append('\n'); inner.uniform3f(location, v0, v1, v2); }
    public void uniform4f(int location, float v0, float v1, float v2, float v3) { if (enabled) log.append("uniform4f").append(' ').append(location).append(' ').append(v0).append(' ').append(v1).append(' ').append(v2).append(' ').append(v3).append('\n'); inner.uniform4f(location, v0, v1, v2, v3); }
    public void uniform1fv(int location, float[] value) { if (enabled) log.append("uniform1fv").append(' ').append(location).append(' ').append(arr(value)).append('\n'); inner.uniform1fv(location, value); }
    public void uniform2fv(int location, float[] value) { if (enabled) log.append("uniform2fv").append(' ').append(location).append(' ').append(arr(value)).append('\n'); inner.uniform2fv(location, value); }
    public void uniform3fv(int location, float[] value) { if (enabled) log.append("uniform3fv").append(' ').append(location).append(' ').append(arr(value)).append('\n'); inner.uniform3fv(location, value); }
    public void uniformMatrix4fv(int location, boolean transpose, float[] value) { if (enabled) log.append("uniformMatrix4fv").append(' ').append(location).append(' ').append(transpose).append(' ').append(arr(value)).append('\n'); inner.uniformMatrix4fv(location, transpose, value); }
    public FloatBuffer allocFloats(int count) { return inner.allocFloats(count); }
    public void freeFloats(FloatBuffer buffer) { inner.freeFloats(buffer); }
    public IntBuffer allocInts(int count) { return inner.allocInts(count); }
    public void freeInts(IntBuffer buffer) { inner.freeInts(buffer); }
    public ByteBuffer allocBytes(int count) { return inner.allocBytes(count); }
    public void freeBytes(ByteBuffer buffer) { inner.freeBytes(buffer); }
}
