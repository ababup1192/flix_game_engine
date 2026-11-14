package spike.wgpu;

import com.github.xpenatan.webgpu.*;

public final class WgPipeline { final WGPURenderPipeline p; final String label; WgPipeline(WGPURenderPipeline p, String l) { this.p = p; label = l; } public String label() { return label; } }
