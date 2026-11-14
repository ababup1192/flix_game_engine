package spike.wgpu;

import com.github.xpenatan.webgpu.*;

public final class WgDevice {
    final WGPUInstance instance; final WGPUAdapter adapter; final WGPUDevice device; final WGPUQueue queue;
    WgDevice(WGPUInstance i, WGPUAdapter a, WGPUDevice d) { instance = i; adapter = a; device = d; queue = d.getQueue(); }
    public String describe() {
        WGPUAdapterInfo ai = WGPUAdapterInfo.obtain();
        return adapter.getInfo(ai) ? ai.getBackendType() + " " + ai.getDevice().c_str() : "?";
    }
}
