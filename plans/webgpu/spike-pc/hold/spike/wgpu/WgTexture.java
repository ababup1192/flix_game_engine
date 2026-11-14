package spike.wgpu;

import com.github.xpenatan.webgpu.*;

public final class WgTexture { final WGPUTexture t; final int w, h; WgTexture(WGPUTexture t, int w, int h) { this.t = t; this.w = w; this.h = h; } }
