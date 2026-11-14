package spike.wgpu;

import com.github.xpenatan.webgpu.*;

public final class WgBuffer { final WGPUBuffer b; final long size; WgBuffer(WGPUBuffer b, long s) { this.b = b; size = s; } public long size() { return size; } }
