package fge.gl;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import org.lwjgl.BufferUtils;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL12;
import org.lwjgl.opengl.GL13;
import org.lwjgl.opengl.GL14;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL20;
import org.lwjgl.opengl.GL30;
import org.lwjgl.opengl.GL31;
import org.lwjgl.opengl.GL33;
import org.lwjgl.system.MemoryUtil;

/** デスクトップの GL 3.3（LWJGL）。GL の文脈が今の糸に付いている間だけ呼べる。 */
public final class LwjglGl implements GlContext {
    public void enable(int cap) { GL11.glEnable(cap); }
    public void disable(int cap) { GL11.glDisable(cap); }
    public void viewport(int x, int y, int width, int height) { GL11.glViewport(x, y, width, height); }
    public void scissor(int x, int y, int width, int height) { GL11.glScissor(x, y, width, height); }
    public void clearColor(float r, float g, float b, float a) { GL11.glClearColor(r, g, b, a); }
    public void clearStencil(int s) { GL11.glClearStencil(s); }
    public void clear(int mask) { GL11.glClear(mask); }
    public void blendFunc(int sfactor, int dfactor) { GL11.glBlendFunc(sfactor, dfactor); }
    public void colorMask(boolean r, boolean g, boolean b, boolean a) { GL11.glColorMask(r, g, b, a); }
    public void stencilMask(int mask) { GL11.glStencilMask(mask); }
    public void stencilFunc(int func, int ref, int mask) { GL11.glStencilFunc(func, ref, mask); }
    public void stencilOp(int sfail, int dpfail, int dppass) { GL11.glStencilOp(sfail, dpfail, dppass); }
    public void pixelStorei(int pname, int param) { GL11.glPixelStorei(pname, param); }
    public int getInteger(int pname) { return GL11.glGetInteger(pname); }
    public void depthMask(boolean flag) { GL11.glDepthMask(flag); }
    public void depthFunc(int func) { GL11.glDepthFunc(func); }
    public void clearDepth(double depth) { GL11.glClearDepth(depth); }
    public void cullFace(int mode) { GL11.glCullFace(mode); }
    public void frontFace(int mode) { GL11.glFrontFace(mode); }
    public void blendFuncSeparate(int srcRgb, int dstRgb, int srcAlpha, int dstAlpha) { GL14.glBlendFuncSeparate(srcRgb, dstRgb, srcAlpha, dstAlpha); }
    public boolean hasAlphaToOne() { return true; }

    public int createBuffer() { return GL15.glGenBuffers(); }
    public void deleteBuffer(int buffer) { GL15.glDeleteBuffers(buffer); }
    public void bindBuffer(int target, int buffer) { GL15.glBindBuffer(target, buffer); }
    public void bufferData(int target, float[] data, int usage) { GL15.glBufferData(target, data, usage); }
    public void bufferData(int target, FloatBuffer data, int usage) { GL15.glBufferData(target, data, usage); }
    public void bufferData(int target, int[] data, int usage) { GL15.glBufferData(target, data, usage); }
    public int createVertexArray() { return GL30.glGenVertexArrays(); }
    public void deleteVertexArray(int array) { GL30.glDeleteVertexArrays(array); }
    public void bindVertexArray(int array) { GL30.glBindVertexArray(array); }
    public void enableVertexAttribArray(int index) { GL20.glEnableVertexAttribArray(index); }
    public void vertexAttribPointer(int index, int size, int type, boolean normalized, int stride, int offset) {
        GL20.glVertexAttribPointer(index, size, type, normalized, stride, (long) offset);
    }
    public void vertexAttribIPointer(int index, int size, int type, int stride, int offset) {
        GL30.glVertexAttribIPointer(index, size, type, stride, (long) offset);
    }
    public void vertexAttribDivisor(int index, int divisor) { GL33.glVertexAttribDivisor(index, divisor); }
    public void drawArrays(int mode, int first, int count) { GL11.glDrawArrays(mode, first, count); }
    public void drawArraysInstanced(int mode, int first, int count, int instanceCount) {
        GL31.glDrawArraysInstanced(mode, first, count, instanceCount);
    }
    public void drawElements(int mode, int count, int type, int offset) { GL11.glDrawElements(mode, count, type, (long) offset); }

    public int createTexture() { return GL11.glGenTextures(); }
    public void deleteTexture(int texture) { GL11.glDeleteTextures(texture); }
    public void bindTexture(int target, int texture) { GL11.glBindTexture(target, texture); }
    public void activeTexture(int unit) { GL13.glActiveTexture(unit); }
    public void texParameteri(int target, int pname, int param) { GL11.glTexParameteri(target, pname, param); }
    public void texImageArgb(int width, int height, IntBuffer argb) { texImageArgbLevel(0, width, height, argb); }
    public void texImageArgbLevel(int level, int width, int height, IntBuffer argb) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, level, GL11.GL_RGBA, width, height, 0, GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, argb);
    }
    public void readTextureArgb(int texture, int width, int height, int[] argb) {
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, texture);
        GL11.glGetTexImage(GL11.GL_TEXTURE_2D, 0, GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, argb);
    }
    public void texImageArgbZero(int width, int height) {
        texImageArgb(width, height, BufferUtils.createIntBuffer(Math.max(1, width * height)));
    }
    public void texImageAlphaMask(int width, int height, ByteBuffer alpha) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL30.GL_R8, width, height, 0, GL11.GL_RED, GL11.GL_UNSIGNED_BYTE, alpha);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_R, GL11.GL_ONE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_G, GL11.GL_ONE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_B, GL11.GL_ONE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_A, GL11.GL_RED);
    }
    public void texSubImageAlphaMask(int x, int y, int width, int height, ByteBuffer alpha) {
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, x, y, width, height, GL11.GL_RED, GL11.GL_UNSIGNED_BYTE, alpha);
    }
    public void texImageBytes(int format, int width, int height, ByteBuffer pixels) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, format, width, height, 0, format, GL11.GL_UNSIGNED_BYTE, pixels);
    }
    public void texImageRgba16fZero(int width, int height) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL30.GL_RGBA16F, width, height, 0, GL11.GL_RGBA, GL30.GL_HALF_FLOAT,
                          BufferUtils.createShortBuffer(Math.max(1, width * height) * 4));
    }
    public void texImageDepth24(int width, int height) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL14.GL_DEPTH_COMPONENT24, width, height, 0, GL11.GL_DEPTH_COMPONENT, GL11.GL_FLOAT, 0L);
    }
    public void texImageRgba32f(int width, int height) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL30.GL_RGBA32F, width, height, 0, GL11.GL_RGBA, GL11.GL_FLOAT, 0L);
    }
    public void texSubImageRgba32f(int x, int y, int width, int height, FloatBuffer pixels) {
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, x, y, width, height, GL11.GL_RGBA, GL11.GL_FLOAT, pixels);
    }
    public int createSampler() { return GL33.glGenSamplers(); }
    public void bindSampler(int unit, int sampler) { GL33.glBindSampler(unit, sampler); }
    public void samplerParameteri(int sampler, int pname, int param) { GL33.glSamplerParameteri(sampler, pname, param); }

    public int createFramebuffer() { return GL30.glGenFramebuffers(); }
    public void deleteFramebuffer(int framebuffer) { GL30.glDeleteFramebuffers(framebuffer); }
    public void bindFramebuffer(int target, int framebuffer) { GL30.glBindFramebuffer(target, framebuffer); }
    public int checkFramebufferStatus(int target) { return GL30.glCheckFramebufferStatus(target); }
    public void framebufferTexture2D(int target, int attachment, int textarget, int texture, int level) {
        GL30.glFramebufferTexture2D(target, attachment, textarget, texture, level);
    }
    public void framebufferRenderbuffer(int target, int attachment, int renderbuffertarget, int renderbuffer) {
        GL30.glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer);
    }
    public void useNoColorBuffer() {
        GL11.glDrawBuffer(GL11.GL_NONE);
        GL11.glReadBuffer(GL11.GL_NONE);
    }
    public void blitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, int mask, int filter) {
        GL30.glBlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
    }
    public int createRenderbuffer() { return GL30.glGenRenderbuffers(); }
    public void deleteRenderbuffer(int renderbuffer) { GL30.glDeleteRenderbuffers(renderbuffer); }
    public void bindRenderbuffer(int target, int renderbuffer) { GL30.glBindRenderbuffer(target, renderbuffer); }
    public void renderbufferStorage(int target, int internalformat, int width, int height) {
        GL30.glRenderbufferStorage(target, internalformat, width, height);
    }
    public void renderbufferStorageMultisample(int target, int samples, int internalformat, int width, int height) {
        GL30.glRenderbufferStorageMultisample(target, samples, internalformat, width, height);
    }

    public int createShader(int type) { return GL20.glCreateShader(type); }
    public void shaderSource(int shader, String source) { GL20.glShaderSource(shader, source); }
    public void compileShader(int shader) { GL20.glCompileShader(shader); }
    public int getShaderi(int shader, int pname) { return GL20.glGetShaderi(shader, pname); }
    public String getShaderInfoLog(int shader) { return GL20.glGetShaderInfoLog(shader, 1024); }
    public void deleteShader(int shader) { GL20.glDeleteShader(shader); }
    public int createProgram() { return GL20.glCreateProgram(); }
    public void attachShader(int program, int shader) { GL20.glAttachShader(program, shader); }
    public void linkProgram(int program) { GL20.glLinkProgram(program); }
    public int getProgrami(int program, int pname) { return GL20.glGetProgrami(program, pname); }
    public String getProgramInfoLog(int program) { return GL20.glGetProgramInfoLog(program, 1024); }
    public void deleteProgram(int program) { GL20.glDeleteProgram(program); }
    public void useProgram(int program) { GL20.glUseProgram(program); }
    public int getUniformLocation(int program, String name) { return GL20.glGetUniformLocation(program, name); }
    public void uniform1i(int location, int v0) { GL20.glUniform1i(location, v0); }
    public void uniform1f(int location, float v0) { GL20.glUniform1f(location, v0); }
    public void uniform2f(int location, float v0, float v1) { GL20.glUniform2f(location, v0, v1); }
    public void uniform3f(int location, float v0, float v1, float v2) { GL20.glUniform3f(location, v0, v1, v2); }
    public void uniform4f(int location, float v0, float v1, float v2, float v3) { GL20.glUniform4f(location, v0, v1, v2, v3); }
    public void uniform1fv(int location, float[] value) { GL20.glUniform1fv(location, value); }
    public void uniform2fv(int location, float[] value) { GL20.glUniform2fv(location, value); }
    public void uniform3fv(int location, float[] value) { GL20.glUniform3fv(location, value); }
    public void uniformMatrix4fv(int location, boolean transpose, float[] value) { GL20.glUniformMatrix4fv(location, transpose, value); }

    public FloatBuffer allocFloats(int count) { return MemoryUtil.memAllocFloat(count); }
    public void freeFloats(FloatBuffer buffer) { MemoryUtil.memFree(buffer); }
    public IntBuffer allocInts(int count) { return MemoryUtil.memAllocInt(count); }
    public void freeInts(IntBuffer buffer) { MemoryUtil.memFree(buffer); }
    public ByteBuffer allocBytes(int count) { return MemoryUtil.memAlloc(count); }
    public void freeBytes(ByteBuffer buffer) { MemoryUtil.memFree(buffer); }
}
