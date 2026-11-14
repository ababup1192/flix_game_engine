// WebGpuDevice — WebGPU の device を開く effect と、PC（Dawn）の handler。ブラウザ（navigator.gpu）の handler は WebLayer.runBrowserWebGpu。
// WebGPU を使う側（WebGpuOffscreen など）は device をこの effect から取り、入口が差す handler で実装が決まる（Fs の handler と同じ形）。
//
// 使い方: `run { … WebGpuOffscreen.open(…) … } with WebGpuDevice.runDawn`（ブラウザの入口は with WebLayer.runBrowserWebGpu）
//
// WhyNot: 使う側の中で実装（Dawn か JSO）を選ばない — ブラウザの書き出しに Dawn の JNI が、PC に JSO が届く。選ぶのは入口で差す handler の 1 か所。
import fge.webgpu.WebGpu

/// WebGPU の device を取る口。
pub eff WebGpuDevice {
    /// device を開く。開けなければ Err(理由)。開いた device は呼び手が持ち、destroy する。
    def requestDevice(): Result[String, WebGpu]
}

pub mod WebGpuDevice {
    import fge.webgpu.WebGpu
    import fge.webgpu.dawn.DawnWebGpu
    import java.lang.Throwable

    /// WebGpuDevice を Dawn（PC・ネイティブは既定の置き場）で受ける。
    pub def runDawn(f: Unit -> a \ ef): a \ (ef - WebGpuDevice) + IO =
        run f() with handler WebGpuDevice {
            def requestDevice(k) = k(openDawn())
        }

    def openDawn(): Result[String, WebGpu] \ IO =
        try {
            let gpu: WebGpu = checked_cast(DawnWebGpu.open(""));
            Ok(gpu)
        } catch {
            case e: Throwable => Err("WebGPU の device を開けない: ${e.toString()}")
        }
}
