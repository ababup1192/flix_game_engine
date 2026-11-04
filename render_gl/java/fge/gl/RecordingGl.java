package fge.gl;

import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;

/**
 * 呼ばれた関数と引数を 1 行ずつ控えてから inner へ渡す GlContext。描く手順を替える前と後で、呼び出しの並びを比べるのに使う。
 * バッファと配列は長さだけを控える（中身の違いは絵のバイトで見る）。字は長さだけ。
 * GlContext に関数を足したら、ここにも同じ形の 1 行を足す（足さないと javac が止める）。
 */
public final class RecordingGl implements GlContext {
    private final GlContext inner;
    private final StringBuilder log = new StringBuilder();

    public RecordingGl(GlContext inner) { this.inner = inner; }

    /** 控えた行の全部（1 行 1 呼び出し）。 */
    public String log() { return log.toString(); }

    /** 控えを空にする。 */
    public void clearLog() { log.setLength(0); }

    private static String buf(Buffer b) { return b == null ? "null" : "buf" + b.remaining(); }
    private static String arr(float[] a) { return a == null ? "null" : "float" + a.length; }

    public void enable(int cap) { log.append("enable").append(' ').append(cap).append('\n'); inner.enable(cap); }
    public void disable(int cap) { log.append("disable").append(' ').append(cap).append('\n'); inner.disable(cap); }
    public void viewport(int x, int y, int width, int height) { log.append("viewport").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append('\n'); inner.viewport(x, y, width, height); }
    public void scissor(int x, int y, int width, int height) { log.append("scissor").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append('\n'); inner.scissor(x, y, width, height); }
    public void clearColor(float r, float g, float b, float a) { log.append("clearColor").append(' ').append(r).append(' ').append(g).append(' ').append(b).append(' ').append(a).append('\n'); inner.clearColor(r, g, b, a); }
    public void clearStencil(int s) { log.append("clearStencil").append(' ').append(s).append('\n'); inner.clearStencil(s); }
    public void clear(int mask) { log.append("clear").append(' ').append(mask).append('\n'); inner.clear(mask); }
    public void blendFunc(int sfactor, int dfactor) { log.append("blendFunc").append(' ').append(sfactor).append(' ').append(dfactor).append('\n'); inner.blendFunc(sfactor, dfactor); }
    public void colorMask(boolean r, boolean g, boolean b, boolean a) { log.append("colorMask").append(' ').append(r).append(' ').append(g).append(' ').append(b).append(' ').append(a).append('\n'); inner.colorMask(r, g, b, a); }
    public void stencilMask(int mask) { log.append("stencilMask").append(' ').append(mask).append('\n'); inner.stencilMask(mask); }
    public void stencilFunc(int func, int ref, int mask) { log.append("stencilFunc").append(' ').append(func).append(' ').append(ref).append(' ').append(mask).append('\n'); inner.stencilFunc(func, ref, mask); }
    public void stencilOp(int sfail, int dpfail, int dppass) { log.append("stencilOp").append(' ').append(sfail).append(' ').append(dpfail).append(' ').append(dppass).append('\n'); inner.stencilOp(sfail, dpfail, dppass); }
    public void pixelStorei(int pname, int param) { log.append("pixelStorei").append(' ').append(pname).append(' ').append(param).append('\n'); inner.pixelStorei(pname, param); }
    public int getInteger(int pname) { log.append("getInteger").append(' ').append(pname).append('\n'); return inner.getInteger(pname); }
    public int genBuffer() { log.append("genBuffer").append('\n'); return inner.genBuffer(); }
    public void deleteBuffer(int buffer) { log.append("deleteBuffer").append(' ').append(buffer).append('\n'); inner.deleteBuffer(buffer); }
    public void bindBuffer(int target, int buffer) { log.append("bindBuffer").append(' ').append(target).append(' ').append(buffer).append('\n'); inner.bindBuffer(target, buffer); }
    public void bufferData(int target, float[] data, int usage) { log.append("bufferData").append(' ').append(target).append(' ').append(arr(data)).append(' ').append(usage).append('\n'); inner.bufferData(target, data, usage); }
    public void bufferData(int target, FloatBuffer data, int usage) { log.append("bufferData").append(' ').append(target).append(' ').append(buf(data)).append(' ').append(usage).append('\n'); inner.bufferData(target, data, usage); }
    public int genVertexArray() { log.append("genVertexArray").append('\n'); return inner.genVertexArray(); }
    public void deleteVertexArray(int array) { log.append("deleteVertexArray").append(' ').append(array).append('\n'); inner.deleteVertexArray(array); }
    public void bindVertexArray(int array) { log.append("bindVertexArray").append(' ').append(array).append('\n'); inner.bindVertexArray(array); }
    public void enableVertexAttribArray(int index) { log.append("enableVertexAttribArray").append(' ').append(index).append('\n'); inner.enableVertexAttribArray(index); }
    public void vertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset) { log.append("vertexAttribPointer").append(' ').append(index).append(' ').append(size).append(' ').append(type).append(' ').append(normalized).append(' ').append(stride).append(' ').append(offset).append('\n'); inner.vertexAttribPointer(index, size, type, normalized, stride, offset); }
    public void vertexAttribDivisor(int index, int divisor) { log.append("vertexAttribDivisor").append(' ').append(index).append(' ').append(divisor).append('\n'); inner.vertexAttribDivisor(index, divisor); }
    public void drawArrays(int mode, int first, int count) { log.append("drawArrays").append(' ').append(mode).append(' ').append(first).append(' ').append(count).append('\n'); inner.drawArrays(mode, first, count); }
    public void drawArraysInstanced(int mode, int first, int count, int instanceCount) { log.append("drawArraysInstanced").append(' ').append(mode).append(' ').append(first).append(' ').append(count).append(' ').append(instanceCount).append('\n'); inner.drawArraysInstanced(mode, first, count, instanceCount); }
    public int genTexture() { log.append("genTexture").append('\n'); return inner.genTexture(); }
    public void deleteTexture(int texture) { log.append("deleteTexture").append(' ').append(texture).append('\n'); inner.deleteTexture(texture); }
    public void bindTexture(int target, int texture) { log.append("bindTexture").append(' ').append(target).append(' ').append(texture).append('\n'); inner.bindTexture(target, texture); }
    public void activeTexture(int unit) { log.append("activeTexture").append(' ').append(unit).append('\n'); inner.activeTexture(unit); }
    public void texParameteri(int target, int pname, int param) { log.append("texParameteri").append(' ').append(target).append(' ').append(pname).append(' ').append(param).append('\n'); inner.texParameteri(target, pname, param); }
    public void texImageArgb(int width, int height, IntBuffer argb) { log.append("texImageArgb").append(' ').append(width).append(' ').append(height).append(' ').append(buf(argb)).append('\n'); inner.texImageArgb(width, height, argb); }
    public void texImageArgbZero(int width, int height) { log.append("texImageArgbZero").append(' ').append(width).append(' ').append(height).append('\n'); inner.texImageArgbZero(width, height); }
    public void texImageAlphaMask(int width, int height, ByteBuffer alpha) { log.append("texImageAlphaMask").append(' ').append(width).append(' ').append(height).append(' ').append(buf(alpha)).append('\n'); inner.texImageAlphaMask(width, height, alpha); }
    public void texSubImageAlphaMask(int x, int y, int width, int height, ByteBuffer alpha) { log.append("texSubImageAlphaMask").append(' ').append(x).append(' ').append(y).append(' ').append(width).append(' ').append(height).append(' ').append(buf(alpha)).append('\n'); inner.texSubImageAlphaMask(x, y, width, height, alpha); }
    public void texImageBytes(int format, int width, int height, ByteBuffer pixels) { log.append("texImageBytes").append(' ').append(format).append(' ').append(width).append(' ').append(height).append(' ').append(buf(pixels)).append('\n'); inner.texImageBytes(format, width, height, pixels); }
    public void texImageRgba16fZero(int width, int height) { log.append("texImageRgba16fZero").append(' ').append(width).append(' ').append(height).append('\n'); inner.texImageRgba16fZero(width, height); }
    public int genSampler() { log.append("genSampler").append('\n'); return inner.genSampler(); }
    public void bindSampler(int unit, int sampler) { log.append("bindSampler").append(' ').append(unit).append(' ').append(sampler).append('\n'); inner.bindSampler(unit, sampler); }
    public void samplerParameteri(int sampler, int pname, int param) { log.append("samplerParameteri").append(' ').append(sampler).append(' ').append(pname).append(' ').append(param).append('\n'); inner.samplerParameteri(sampler, pname, param); }
    public int genFramebuffer() { log.append("genFramebuffer").append('\n'); return inner.genFramebuffer(); }
    public void deleteFramebuffer(int framebuffer) { log.append("deleteFramebuffer").append(' ').append(framebuffer).append('\n'); inner.deleteFramebuffer(framebuffer); }
    public void bindFramebuffer(int target, int framebuffer) { log.append("bindFramebuffer").append(' ').append(target).append(' ').append(framebuffer).append('\n'); inner.bindFramebuffer(target, framebuffer); }
    public int checkFramebufferStatus(int target) { log.append("checkFramebufferStatus").append(' ').append(target).append('\n'); return inner.checkFramebufferStatus(target); }
    public void framebufferTexture2D(int target, int attachment, int textarget, int texture, int level) { log.append("framebufferTexture2D").append(' ').append(target).append(' ').append(attachment).append(' ').append(textarget).append(' ').append(texture).append(' ').append(level).append('\n'); inner.framebufferTexture2D(target, attachment, textarget, texture, level); }
    public void framebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer) { log.append("framebufferRenderbuffer").append(' ').append(target).append(' ').append(attachment).append(' ').append(renderbuffertarget).append(' ').append(renderbuffer).append('\n'); inner.framebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer); }
    public void blitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter) { log.append("blitFramebuffer").append(' ').append(srcX0).append(' ').append(srcY0).append(' ').append(srcX1).append(' ').append(srcY1).append(' ').append(dstX0).append(' ').append(dstY0).append(' ').append(dstX1).append(' ').append(dstY1).append(' ').append(mask).append(' ').append(filter).append('\n'); inner.blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter); }
    public int genRenderbuffer() { log.append("genRenderbuffer").append('\n'); return inner.genRenderbuffer(); }
    public void deleteRenderbuffer(int renderbuffer) { log.append("deleteRenderbuffer").append(' ').append(renderbuffer).append('\n'); inner.deleteRenderbuffer(renderbuffer); }
    public void bindRenderbuffer(int target, int renderbuffer) { log.append("bindRenderbuffer").append(' ').append(target).append(' ').append(renderbuffer).append('\n'); inner.bindRenderbuffer(target, renderbuffer); }
    public void renderbufferStorage(int target, int internalformat, int width, int height) { log.append("renderbufferStorage").append(' ').append(target).append(' ').append(internalformat).append(' ').append(width).append(' ').append(height).append('\n'); inner.renderbufferStorage(target, internalformat, width, height); }
    public void renderbufferStorageMultisample(int target, int samples, int internalformat, int width, int height) { log.append("renderbufferStorageMultisample").append(' ').append(target).append(' ').append(samples).append(' ').append(internalformat).append(' ').append(width).append(' ').append(height).append('\n'); inner.renderbufferStorageMultisample(target, samples, internalformat, width, height); }
    public int createShader(int type) { log.append("createShader").append(' ').append(type).append('\n'); return inner.createShader(type); }
    public void shaderSource(int shader, String source) { log.append("shaderSource").append(' ').append(shader).append(' ').append(source.length()).append('\n'); inner.shaderSource(shader, source); }
    public void compileShader(int shader) { log.append("compileShader").append(' ').append(shader).append('\n'); inner.compileShader(shader); }
    public int getShaderi(int shader, int pname) { log.append("getShaderi").append(' ').append(shader).append(' ').append(pname).append('\n'); return inner.getShaderi(shader, pname); }
    public String getShaderInfoLog(int shader) { log.append("getShaderInfoLog").append(' ').append(shader).append('\n'); return inner.getShaderInfoLog(shader); }
    public void deleteShader(int shader) { log.append("deleteShader").append(' ').append(shader).append('\n'); inner.deleteShader(shader); }
    public int createProgram() { log.append("createProgram").append('\n'); return inner.createProgram(); }
    public void attachShader(int program, int shader) { log.append("attachShader").append(' ').append(program).append(' ').append(shader).append('\n'); inner.attachShader(program, shader); }
    public void linkProgram(int program) { log.append("linkProgram").append(' ').append(program).append('\n'); inner.linkProgram(program); }
    public int getProgrami(int program, int pname) { log.append("getProgrami").append(' ').append(program).append(' ').append(pname).append('\n'); return inner.getProgrami(program, pname); }
    public String getProgramInfoLog(int program) { log.append("getProgramInfoLog").append(' ').append(program).append('\n'); return inner.getProgramInfoLog(program); }
    public void deleteProgram(int program) { log.append("deleteProgram").append(' ').append(program).append('\n'); inner.deleteProgram(program); }
    public void useProgram(int program) { log.append("useProgram").append(' ').append(program).append('\n'); inner.useProgram(program); }
    public int getUniformLocation(int program, String name) { log.append("getUniformLocation").append(' ').append(program).append(' ').append(name.length()).append('\n'); return inner.getUniformLocation(program, name); }
    public void uniform1i(int location, int v0) { log.append("uniform1i").append(' ').append(location).append(' ').append(v0).append('\n'); inner.uniform1i(location, v0); }
    public void uniform1f(int location, float v0) { log.append("uniform1f").append(' ').append(location).append(' ').append(v0).append('\n'); inner.uniform1f(location, v0); }
    public void uniform2f(int location, float v0, float v1) { log.append("uniform2f").append(' ').append(location).append(' ').append(v0).append(' ').append(v1).append('\n'); inner.uniform2f(location, v0, v1); }
    public void uniform3f(int location, float v0, float v1, float v2) { log.append("uniform3f").append(' ').append(location).append(' ').append(v0).append(' ').append(v1).append(' ').append(v2).append('\n'); inner.uniform3f(location, v0, v1, v2); }
    public void uniformMatrix4fv(int location, boolean transpose, float[] value) { log.append("uniformMatrix4fv").append(' ').append(location).append(' ').append(transpose).append(' ').append(arr(value)).append('\n'); inner.uniformMatrix4fv(location, transpose, value); }
    public FloatBuffer allocFloats(int count) { log.append("allocFloats").append(' ').append(count).append('\n'); return inner.allocFloats(count); }
    public void freeFloats(FloatBuffer buffer) { log.append("freeFloats").append(' ').append(buf(buffer)).append('\n'); inner.freeFloats(buffer); }
    public IntBuffer allocInts(int count) { log.append("allocInts").append(' ').append(count).append('\n'); return inner.allocInts(count); }
    public void freeInts(IntBuffer buffer) { log.append("freeInts").append(' ').append(buf(buffer)).append('\n'); inner.freeInts(buffer); }
    public ByteBuffer allocBytes(int count) { log.append("allocBytes").append(' ').append(count).append('\n'); return inner.allocBytes(count); }
    public void freeBytes(ByteBuffer buffer) { log.append("freeBytes").append(' ').append(buf(buffer)).append('\n'); inner.freeBytes(buffer); }
}
