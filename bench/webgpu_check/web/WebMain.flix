// ブラウザの入口（bin/fge export-web だけが組む・make webgpu-check-web）。PC と同じ門（Checks.flix）を WebLayer.runBrowserWebGpu の device で流し、
// 結果を console へ "[bench] result {…}" で出す（bench/common/bench-overlay.js が拾って window.__bench に置き、bin/fge web-bench が取る）。
// ブラウザだけの門: canvas の描き先（Surface）に描いて、出す前の描き先を読む。
mod WebMain {
    use fge::{WebLayer}
    use WebGpuSharedChecks.{drawTriangles, near, paddedRowBytes, readTexture, report, rgbaAt, showPixel}

    import fge.web.Browser
    import fge.web.webgpu.BrowserWebGpu
    import fge.webgpu.PresentMode
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import java.lang.Throwable

    /// JSON の字の値（" と \ と 0x20 未満の字を逃がす）。
    def jsonString(s: String): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            StringBuilder.append("\"", sb);
            String.toList(s) |> List.forEach(ch -> StringBuilder.append(jsonChar(ch), sb));
            StringBuilder.append("\"", sb);
            StringBuilder.toString(sb)
        }

    def jsonChar(ch: Char): String =
        let code = Char.toBmpCodePoint(ch);
        if (ch == '"') "\\\""
        else if (ch == '\\') "\\\\"
        else if (code < 32) "\\u00${hexDigit(code / 16)}${hexDigit(Int32.remainder(code, 16))}"
        else Char.toString(ch)

    def hexDigit(n: Int32): String =
        String.toList("0123456789abcdef") |> List.nth(n) |> Option.map(Char.toString) |> Option.getWithDefault("0")

    def logResult(name: String, passed: Bool, detail: String): Unit \ IO =
        Browser.log("[bench] result {\"name\":${jsonString(name)},\"ok\":${if (passed) "true" else "false"},\"detail\":${jsonString(detail)}}")

    def canvasWgsl(): String =
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    var p = vec2f(0.0, 0.5);\n" +
        "    if (i == 0u) { p = vec2f(-0.5, -0.5); } else if (i == 1u) { p = vec2f(0.5, -0.5); }\n" +
        "    return vec4f(p, 0.0, 1.0);\n" +
        "}\n" +
        "@fragment fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.5, 0.25, 1.0); }\n"

    /// canvas の描き先に三角形を描き、出す前に読む（形が BGRA なら並びを入れ替えて見る）。
    def checkCanvas(): Bool \ IO + WebGpuSharedChecks.CheckLog =
        try {
            let browser = BrowserWebGpu.open();
            let gpu: WebGpu = checked_cast(browser);
            let surface = browser.createCanvasSurface("fge-webgpu-check");
            let format = surface.preferredFormat();
            surface.configure(160, 90, format, PresentMode.FIFO, Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.COPY_SRC));
            let module = gpu.createShaderModule("check canvas", canvasWgsl());
            let desc = new RenderPipelineDesc("check canvas");
            discard desc.vertex(module, "vs_main").fragment(module, "fs_main").colorTarget(format);
            let pipeline = gpu.createRenderPipeline(desc);
            let texture = surface.getCurrentTexture();
            drawTriangles(gpu, texture, pipeline, 3);
            let bytesPerRow = paddedRowBytes(160);
            let buf = readTexture(gpu, texture, 160, 90);
            let swap = format.name() == "BGRA8_UNORM";
            let order = p -> if (swap) { let (b, g, r, a) = p; (r, g, b, a) } else p;
            let inside = order(rgbaAt(buf, bytesPerRow, 80, 54));
            let outside = order(rgbaAt(buf, bytesPerRow, 3, 3));
            let errors = gpu.errorCount();
            let ok = near(inside, (255, 128, 64, 255)) and near(outside, (51, 51, 51, 255)) and errors == 0;
            surface.release();
            gpu.destroy();
            report("canvas-surface", ok, "format=${format.toString()} in=${showPixel(inside)} out=${showPixel(outside)} errors=${errors}")
        } catch {
            case e: Throwable => report("canvas-surface", false, e.toString())
        }

    /// 門を全部流し、全部通ったかを返す。
    def runChecks(): Bool \ IO =
        run {
            let shared = WebGpuSharedChecks.offscreen();
            let canvas = checkCanvas();
            shared and canvas
        } with WebLayer.runBrowserWebGpu
          with handler WebGpuSharedChecks.CheckLog {
              def result(name, passed, detail, k) = { logResult(name, passed, detail); k() }
          }

    // WhyNot: 例外を頁の外へ投げっぱなしにしない — "[bench] done" が出ず、bin/fge web-bench が待つ上限まで止まって見える。
    pub def main(): Unit \ IO =
        Browser.log("[bench] begin");
        try {
            let ok = runChecks();
            logResult("webgpu-check", ok, if (ok) "全部通った" else "NG あり")
        } catch {
            case e: Throwable => logResult("webgpu-check", false, e.toString())
        };
        Browser.log("[bench] done")
}
