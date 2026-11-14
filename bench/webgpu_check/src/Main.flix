// 入口。WebGPU の PC の実装（Dawn）を Flix から WebGpu の interface を通して呼び、描いた絵を読み戻して期待と比べる。
// WEBGPU_CHECK=offscreen（既定）はウィンドウを使わない門、window は GLFW のウィンドウの門（macOS は最初の糸で起動し直す）。
// 門ごとに "RESULT <名前> OK|NG …" を 1 行出し、1 つでも NG なら exit 1。
mod WebGpuCheck {
    use fge::{GlOffscreen, LwjglLayer, Sort, WebGpuOffscreen, WebGpuWindow}

    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PresentMode
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.QuerySet
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderStage
    import fge.webgpu.Surface
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import fge.webgpu.dawn.DawnWebGpu
    import java.io.File
    import java.lang.IllegalStateException
    import java.lang.System
    import java.lang.Thread
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    /// ネイティブの置き場（WEBGPU_NATIVE_DIR。無ければ空 = DawnWebGpu の既定）。
    def nativeDir(): String \ IO =
        let dir = System.getenv("WEBGPU_NATIVE_DIR");
        if (Object.isNull(dir)) "" else dir

    /// WEBGPU_BARRIER のファイルができるまで待つ（2 プロセスの門が、device を開く直前でそろえる）。無ければすぐ返る。
    def waitBarrier(): Unit \ IO =
        let path = System.getenv("WEBGPU_BARRIER");
        if (Object.isNull(path)) () else {
            let waitedFrom = System.currentTimeMillis();
            waitFor(new File(path), System.nanoTime());
            println("BARRIER waited=${System.currentTimeMillis() - waitedFrom} ms released-at=${System.currentTimeMillis()}")
        }

    def waitFor(file: File, start: Int64): Unit \ IO =
        if (file.exists() or System.nanoTime() - start > 60000000000i64) ()
        else {
            Thread.onSpinWait();
            waitFor(file, start)
        }

    // ── 結果の行 ──────────────────────────────

    /// 1 行を出し、合否を返す。
    def report(name: String, ok: Bool, detail: String): Bool \ IO =
        println("RESULT ${name} ${if (ok) "OK" else "NG"} ${detail}");
        ok

    /// 画素 (x, y) の r, g, b, a（buf は 1 行 rowBytes バイト・r が先頭の並び）。
    def rgbaAt(buf: ByteBuffer, rowBytes: Int32, x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO =
        let o = y * rowBytes + x * 4;
        (Int8.toInt32(buf.get(o)) `Int32.bitwiseAnd` 255, Int8.toInt32(buf.get(o + 1)) `Int32.bitwiseAnd` 255,
         Int8.toInt32(buf.get(o + 2)) `Int32.bitwiseAnd` 255, Int8.toInt32(buf.get(o + 3)) `Int32.bitwiseAnd` 255)

    def near(got: (Int32, Int32, Int32, Int32), want: (Int32, Int32, Int32, Int32)): Bool =
        let (r, g, b, a) = got;
        let (wr, wg, wb, wa) = want;
        Int32.abs(r - wr) <= 1 and Int32.abs(g - wg) <= 1 and Int32.abs(b - wb) <= 1 and Int32.abs(a - wa) <= 1

    def showPixel(p: (Int32, Int32, Int32, Int32)): String =
        let (r, g, b, a) = p;
        "${r},${g},${b},${a}"

    def usage2(a: Int32, b: Int32): Int32 = Int32.bitwiseOr(a, b)

    // ── 三角形と面の向き ──────────────────────────────

    /// 左は反時計回り（表）・右は時計回り（裏）の三角形を 1 つずつ。clip の y は上向き。
    def trianglesWgsl(): String =
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    var p = array<vec2f, 6>(vec2f(-0.9, -0.9), vec2f(-0.1, -0.9), vec2f(-0.5, -0.1),\n" +
        "                            vec2f(0.1, -0.9), vec2f(0.5, -0.1), vec2f(0.9, -0.9));\n" +
        "    return vec4f(p[i], 0.0, 1.0);\n" +
        "}\n" +
        "@fragment fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.5, 0.25, 1.0); }\n"

    def trianglePipeline(gpu: WebGpu, format: TextureFormat, cull: CullMode): RenderPipeline \ IO =
        let module = gpu.createShaderModule("check triangles", trianglesWgsl());
        let desc = new RenderPipelineDesc("check triangles");
        discard desc.vertex(module, "vs_main").fragment(module, "fs_main").colorTarget(format);
        discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CCW, cull);
        let pipeline = gpu.createRenderPipeline(desc);
        module.release();
        pipeline

    /// target を灰色（0.2）で消して頂点 vertexCount 個を描き、submit する。
    def drawTriangles(gpu: WebGpu, target: Texture, pipeline: RenderPipeline, vertexCount: Int32): Unit \ IO =
        let encoder = gpu.createCommandEncoder("check triangles");
        let pass = encoder.beginRenderPass(new RenderPassDesc("check triangles").clearColor(target.defaultView(), 0.2, 0.2, 0.2, 1.0));
        pass.setPipeline(pipeline);
        pass.draw(vertexCount, 1, 0, 0);
        pass.end();
        gpu.submit(encoder.finish())

    /// ウィンドウなしの session に面の向きつきで描き、readRgba（下の行から）で読む。cull が BACK なら右の三角形は消える。
    def checkTriangles(session: WebGpuOffscreen.Session, name: String, cull: CullMode, rightDrawn: Bool): Bool \ IO =
        let gpu = WebGpuOffscreen.gpuOf(session);
        let (w, h) = WebGpuOffscreen.sizeOf(session);
        let pipeline = trianglePipeline(gpu, TextureFormat.RGBA8_UNORM, cull);
        drawTriangles(gpu, WebGpuOffscreen.targetOf(session), pipeline, 6);
        pipeline.release();
        let buf = ByteBuffer.allocateDirect(w * h * 4);
        WebGpuOffscreen.readRgba(session, buf);
        // readRgba は下の行から: 描き先の行 y は buf の行 h - 1 - y。
        let row = y -> h - 1 - y;
        let orange = (255, 128, 64, 255);
        let grey = (51, 51, 51, 255);
        let left = rgbaAt(buf, w * 4, w / 4, row(h * 7 / 8));
        let right = rgbaAt(buf, w * 4, w * 3 / 4, row(h * 7 / 8));
        let top = rgbaAt(buf, w * 4, w / 2, row(h / 8));
        let ok = near(left, orange) and near(right, if (rightDrawn) orange else grey) and near(top, grey) and gpu.errorCount() == 0;
        report(name, ok, "left=${showPixel(left)} right=${showPixel(right)} top=${showPixel(top)} errors=${gpu.errorCount()}")

    // ── 上限 ──────────────────────────────

    def checkLimits(gpu: WebGpu): Bool \ IO =
        let l = gpu.limits();
        let fourGiB = 4294967296i64;
        // WhyNot: 4 GiB を超える事を門にしない — 上限が 4 GiB 以下の GPU もあり、この機械の値を見るのは下の 1 行。
        let ok = l.maxTextureDimension2D() >= 8192 and l.maxBufferSize() > 0i64 and l.maxStorageBufferBindingSize() > 0i64
            and l.maxUniformBufferBindingSize() > 0i64 and gpu.hasCoreFeaturesAndLimits();
        report("limits", ok, "${gpu.adapterInfo()} | ${l.toString()} | over4GiB=${l.maxBufferSize() > fourGiB} core-features-and-limits=${gpu.hasCoreFeaturesAndLimits()} timestamp-query=${gpu.hasTimestampQuery()}")

    // ── 式の行の突き合わせ ──────────────────────────────

    def rowFragment(): String =
        "struct U { scale: f32, bias: f32, pad0: f32, pad1: f32 };\n" +
        "@group(0) @binding(0) var<uniform> u: U;\n" +
        "@group(0) @binding(1) var tex0: texture_2d<f32>;\n" +
        "@group(0) @binding(2) var smp0: sampler;\n" +
        "@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {\n" +
        "    let t = textureSampleLevel(tex0, smp0, vec2f(pos.x / 4.0, 0.5), 0.0);\n" +
        "    return vec4f(pos.x * u.scale + u.bias, t.r, t.g, 1.0);\n" +
        "}\n"

    /// 4 × 1 の行を uniform の組 2 つで塗り、式の値と入力の絵の値がそのまま返るか（8 bit に丸めない）。
    def checkFloatRows(session: WebGpuOffscreen.Session): Bool \ IO =
        let texels = Vector#{0.125f32, 1.5f32, 0.0f32, 1.0f32, 2.25f32, -3.0f32, 0.0f32, 1.0f32,
                             0.375f32, 7.0f32, 0.0f32, 1.0f32, -0.5f32, 0.03125f32, 0.0f32, 1.0f32};
        let texture = { sampler = "tex0", levels = { width = 4, height = 1, texels = GlOffscreen.RowTexels.Float32Rgba(texels) } :: Nil, linear = false };
        let sets = Vector#{2.0f32, 0.25f32, 0.0f32, 0.0f32} :: Vector#{-1.0f32, 10.0f32, 0.0f32, 0.0f32} :: Nil;
        let expected = sets |> List.map(set -> Vector.range(0, 4) |> Vector.flatMap(x -> {
            let px = Int32.toFloat32(x) + 0.5f32;
            Vector#{px * Vector.get(0, set) + Vector.get(1, set), Vector.get(x * 4, texels), Vector.get(x * 4 + 1, texels), 1.0f32}
        }));
        match WebGpuOffscreen.drawFloatRows(session, rowFragment(), 4, texture :: Nil, sets) {
            case Err(why) => report("float-rows", false, why)
            case Ok(rows) => report("float-rows", rows == expected, "got=${rows} expected=${expected}")
        }

    def mipFragment(): String =
        "@group(0) @binding(0) var<uniform> u: vec4f;\n" +
        "@group(0) @binding(1) var tex0: texture_2d<f32>;\n" +
        "@group(0) @binding(2) var smp0: sampler;\n" +
        "@group(0) @binding(3) var tex1: texture_2d<f32>;\n" +
        "@group(0) @binding(4) var smp1: sampler;\n" +
        "@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {\n" +
        "    let between = textureSampleLevel(tex1, smp1, vec2f(0.5, 0.5), 0.0);\n" +
        "    let small = textureSampleLevel(tex1, smp1, vec2f(0.5, 0.5), 1.0);\n" +
        "    let first = textureSampleLevel(tex0, smp0, vec2f(0.125, 0.5), 0.0);\n" +
        "    return vec4f(between.r, small.g, small.r, first.r + u.x);\n" +
        "}\n"

    /// Argb8 の絵（2 × 1 と 1 × 1 の 2 段・linear の sampler）を Float32 の絵と並べて読む:
    /// 段 0 の 2 画素（r = 0 と 1）の真ん中は 0.5 前後・段 1 は (r, g) = (0, 1) がそのまま・Float32 の絵の左端は 0.125。
    def checkArgbMipRows(session: WebGpuOffscreen.Session): Bool \ IO =
        let floatTex = { sampler = "tex0", levels = { width = 4, height = 1, texels = GlOffscreen.RowTexels.Float32Rgba(
                             Vector#{0.125f32, 0.0f32, 0.0f32, 1.0f32, 0.5f32, 0.0f32, 0.0f32, 1.0f32,
                                     0.5f32, 0.0f32, 0.0f32, 1.0f32, 0.5f32, 0.0f32, 0.0f32, 1.0f32}) } :: Nil, linear = false };
        let argbTex = { sampler = "tex1",
                        levels = { width = 2, height = 1, texels = GlOffscreen.RowTexels.Argb8(Vector#{-16777216, -65536}) } ::
                                 { width = 1, height = 1, texels = GlOffscreen.RowTexels.Argb8(Vector#{-16711936}) } :: Nil,
                        linear = true };
        match WebGpuOffscreen.drawFloatRows(session, mipFragment(), 1, floatTex :: argbTex :: Nil, Vector#{0.25f32, 0.0f32, 0.0f32, 0.0f32} :: Nil) {
            case Err(why) => report("float-rows-argb-mip", false, why)
            case Ok(rows) =>
                let row = List.head(rows) |> Option.getWithDefault(Vector.empty());
                let at = i -> Vector.nth(i, row) |> Option.map(Float32.toFloat64) |> Option.getWithDefault(-99.0);
                let ok = Float64.abs(at(0) - 0.5) <= 0.01 and at(1) == 1.0 and at(2) == 0.0 and at(3) == 0.375;
                report("float-rows-argb-mip", ok, "got=${row} expected=0.5(±0.01),1.0,0.0,0.375")
        }

    // ── 公開の入口の誤りの道 ──────────────────────────────

    /// 大きさ 0 の描き先は Err（開いた device は手放す）。
    def checkOpenErr(): Bool \ IO = match WebGpuOffscreen.open({ width = 0, height = 64 }) {
        case Err(why) => report("open-err-size", true, why)
        case Ok(s)    => WebGpuOffscreen.close(s); report("open-err-size", false, "大きさ 0 で開けた")
    }

    /// ネイティブを読んだ後に別の置き場を渡すと、黙って無視せず誤りになる。
    def checkNativeDirMismatch(): Bool \ IO =
        let other = "${System.getProperty("java.io.tmpdir")}/fge-webgpu-check-other-dir";
        let outcome = try { DawnWebGpu.open(other).destroy(); "開けた" } catch { case e: IllegalStateException => "誤り: ${e.getMessage()}" };
        report("native-dir-mismatch", String.startsWith({prefix = "誤り"}, outcome), outcome)

    // ── firstInstance で 1 本ずつ積む形の速さ ──────────────────────────────

    def quadsWgsl(): String =
        "@group(0) @binding(0) var<storage, read> rows: array<vec4f>;\n" +
        "struct V { @builtin(position) pos: vec4f, @location(0) shade: f32 };\n" +
        "@vertex fn vs_main(@builtin(vertex_index) i: u32, @builtin(instance_index) k: u32) -> V {\n" +
        "    var c = array<vec2f, 6>(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0), vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));\n" +
        "    let r = rows[k];\n" +
        "    var out: V;\n" +
        "    out.pos = vec4f(r.xy + c[i] * r.z, 0.0, 1.0);\n" +
        "    out.shade = r.w;\n" +
        "    return out;\n" +
        "}\n" +
        "@fragment fn fs_main(v: V) -> @location(0) vec4f { return vec4f(v.shade, 1.0 - v.shade, 0.5, 1.0); }\n"

    /// 1 体の行（中心 x, y・半径・色の濃さ）を 20,000 体ぶん、決まった並びで詰める。
    def fillRows(buf: ByteBuffer, n: Int32, k: Int32): Unit \ IO =
        if (k >= n) ()
        else {
            let fx = Int32.toFloat32(Int32.remainder(k * 37, 199)) / 99.5f32 - 1.0f32;
            let fy = Int32.toFloat32(Int32.remainder(k * 91, 211)) / 105.5f32 - 1.0f32;
            discard buf.putFloat(k * 16, fx);
            discard buf.putFloat(k * 16 + 4, fy);
            discard buf.putFloat(k * 16 + 8, 0.004f32);
            discard buf.putFloat(k * 16 + 12, Int32.toFloat32(Int32.remainder(k, 17)) / 16.0f32);
            fillRows(buf, n, k + 1)
        }

    /// draw(6, 1, 0, k) を k = from..n-1 で積む。
    def drawEach(pass: RenderPass, k: Int32, n: Int32): Unit \ IO =
        if (k >= n) ()
        else {
            pass.draw(6, 1, 0, k);
            drawEach(pass, k + 1, n)
        }

    /// 測った 1 コマ: (CPU の ms（encoder を作る〜submit）, GPU の pass の ms（timestamp が無ければ -1）)。
    type alias FrameTime = { cpuMs = Float64, gpuMs = Float64 }

    /// 1 コマ描いて終わるまで待ち、時間を返す。perInstance が真なら draw を n 本・偽なら 1 本で n 体。
    def benchFrame(gpu: WebGpu, target: Texture, pipeline: RenderPipeline, group: BindGroup, n: Int32,
                   perInstance: Bool, timing: Option[(QuerySet, Buffer, Buffer)], tsBuf: ByteBuffer): FrameTime \ IO =
        let t0 = System.nanoTime();
        let encoder = gpu.createCommandEncoder("check bench");
        let passDesc = new RenderPassDesc("check bench").clearColor(target.defaultView(), 0.05, 0.05, 0.08, 1.0);
        timing |> Option.forEach(t -> { let (qs, _, _) = t; discard passDesc.timestampWrites(qs, 0, 1) });
        let pass = encoder.beginRenderPass(passDesc);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        if (perInstance) drawEach(pass, 0, n) else pass.draw(6, n, 0, 0);
        pass.end();
        timing |> Option.forEach(t -> {
            let (qs, resolve, read) = t;
            encoder.resolveQuerySet(qs, 0, 2, resolve, 0i64);
            encoder.copyBufferToBuffer(resolve, 0i64, read, 0i64, 16i64)
        });
        gpu.submit(encoder.finish());
        let t1 = System.nanoTime();
        let gpuMs = match timing {
            case Some((_, _, read)) =>
                gpu.readBuffer(read, 0i64, 16, tsBuf);
                Int64.toFloat64(tsBuf.getLong(8) - tsBuf.getLong(0)) / 1000000.0
            case None =>
                gpu.waitIdle();
                -1.0
        };
        { cpuMs = Int64.toFloat64(t1 - t0) / 1000000.0, gpuMs = gpuMs }

    def median(xs: List[Float64]): Float64 =
        let sorted = Sort.sortStable(xs);
        List.nth(List.length(sorted) / 2, sorted) |> Option.getWithDefault(0.0)

    def runFrames(gpu: WebGpu, target: Texture, pipeline: RenderPipeline, group: BindGroup, n: Int32,
                  perInstance: Bool, timing: Option[(QuerySet, Buffer, Buffer)], count: Int32): List[FrameTime] \ IO =
        let tsBuf = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN);
        List.range(0, count) |> List.map(_ -> benchFrame(gpu, target, pipeline, group, n, perInstance, timing, tsBuf))

    def fmt(x: Float64): String = Float64.toString(Float64.round(x * 1000.0) / 1000.0)

    /// 20,000 体を「draw 1 本」と「firstInstance で 1 体ずつ draw」で描き、絵が同じかと 1 体ずつの CPU の時間（合格線 3 ms）を見る。
    def checkFirstInstance(gpu: WebGpu): Bool \ IO =
        let n = 20000;
        let size = 1024;
        let rowsBytes = n * 16;
        let rows = gpu.createBuffer("check rows", Int32.toInt64(rowsBytes), usage2(BufferUsage.STORAGE, BufferUsage.COPY_DST));
        let data = ByteBuffer.allocateDirect(rowsBytes).order(ByteOrder.LITTLE_ENDIAN);
        fillRows(data, n, 0);
        gpu.writeBuffer(rows, 0i64, data, 0, rowsBytes);
        let layout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("check rows").buffer(0, ShaderStage.VERTEX, BufferBindingType.READ_ONLY_STORAGE));
        let group = gpu.createBindGroup(new BindGroupDesc("check rows", layout).buffer(0, rows, 0i64, Int32.toInt64(rowsBytes)));
        let module = gpu.createShaderModule("check quads", quadsWgsl());
        let desc = new RenderPipelineDesc("check quads");
        discard desc.bindGroupLayout(layout).vertex(module, "vs_main").fragment(module, "fs_main").colorTarget(TextureFormat.RGBA8_UNORM);
        let pipeline = gpu.createRenderPipeline(desc);
        let target = gpu.createTexture("check bench", size, size, TextureFormat.RGBA8_UNORM, usage2(TextureUsage.RENDER_ATTACHMENT, TextureUsage.COPY_SRC), 1, 1);
        let timing = if (gpu.hasTimestampQuery())
            Some((gpu.createTimestampQuerySet("check bench", 2),
                  gpu.createBuffer("check ts resolve", 16i64, usage2(BufferUsage.QUERY_RESOLVE, BufferUsage.COPY_SRC)),
                  gpu.createBuffer("check ts read", 16i64, usage2(BufferUsage.COPY_DST, BufferUsage.MAP_READ))))
            else None;
        let warm = 40;
        let measured = 200;
        let inst = runFrames(gpu, target, pipeline, group, n, false, timing, warm + measured) |> List.drop(warm);
        let instImage = readTexture(gpu, target, size, size);
        let each = runFrames(gpu, target, pipeline, group, n, true, timing, warm + measured) |> List.drop(warm);
        let eachImage = readTexture(gpu, target, size, size);
        let instCpu = median(inst |> List.map(f -> f#cpuMs));
        let eachCpu = median(each |> List.map(f -> f#cpuMs));
        let instGpu = median(inst |> List.map(f -> f#gpuMs));
        let eachGpu = median(each |> List.map(f -> f#gpuMs));
        let sameImage = instImage.mismatch(eachImage) == -1;
        let ok = sameImage and eachCpu <= 3.0 and gpu.errorCount() == 0;
        timing |> Option.forEach(t -> { let (qs, resolve, read) = t; qs.destroy(); resolve.destroy(); read.destroy() });
        group.release();
        pipeline.release();
        module.release();
        layout.release();
        rows.destroy();
        target.destroy();
        report("first-instance", ok,
               "N=${n} frames=${measured} | draw(6,N) cpu med=${fmt(instCpu)} ms gpu med=${fmt(instGpu)} ms | draw(6,1,0,k)×N cpu med=${fmt(eachCpu)} ms gpu med=${fmt(eachGpu)} ms (limit 3 ms) | same image=${sameImage} errors=${gpu.errorCount()}")

    /// texture を読み戻す（行は 256 バイトにそろえたまま）。
    def readTexture(gpu: WebGpu, texture: Texture, width: Int32, height: Int32): ByteBuffer \ IO =
        let bytesPerRow = (width * 4 + 255) / 256 * 256;
        let out = gpu.createBuffer("check read", Int32.toInt64(bytesPerRow * height), usage2(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let encoder = gpu.createCommandEncoder("check read");
        encoder.copyTextureToBuffer(texture, 0, 0, 0, width, height, out, 0i64, bytesPerRow);
        gpu.submit(encoder.finish());
        let buf = ByteBuffer.allocateDirect(bytesPerRow * height);
        gpu.readBuffer(out, 0i64, bytesPerRow * height, buf);
        out.destroy();
        buf

    // ── device を捨てて取り直す ──────────────────────────────

    def checkReopen(dawn: DawnWebGpu): Bool \ IO =
        dawn.destroy();
        let again = dawn.reopen();
        let gpu: WebGpu = checked_cast(again);
        let fresh = WebGpuOffscreen.withDevice(gpu, { width = 64, height = 64 });
        let ok = checkTriangles(fresh, "reopen-after-destroy", CullMode.BACK, false);
        WebGpuOffscreen.close(fresh);
        ok

    // ── ウィンドウなしの門 ──────────────────────────────

    // WhyNot: 公開の入口（WebGpuOffscreen.open）より先に DawnWebGpu.open を呼ぶ — 2 プロセスの門は置き場を名指しし、その置き場で読ませたい。
    def offscreen(): Bool \ IO =
        waitBarrier();
        let dawn = DawnWebGpu.open(nativeDir());
        let dirOk = checkNativeDirMismatch();
        match WebGpuOffscreen.open({ width = 64, height = 64 }) {
            case Err(why)    => report("open", false, why)
            case Ok(session) =>
                let gpu = WebGpuOffscreen.gpuOf(session);
                let results =
                    dirOk ::
                    report("open", true, "64x64") ::
                    checkOpenErr() ::
                    checkLimits(gpu) ::
                    checkTriangles(session, "triangle-cull-back", CullMode.BACK, false) ::
                    checkTriangles(session, "triangle-cull-none", CullMode.NONE, true) ::
                    checkFloatRows(session) ::
                    checkArgbMipRows(session) ::
                    checkFirstInstance(gpu) :: Nil;
                WebGpuOffscreen.close(session);
                List.forAll(identity, checkReopen(dawn) :: results)
        }

    // ── ウィンドウの門 ──────────────────────────────

    /// ウィンドウの三角形: 中は (1.0, 0.5, 0.25)・地は 0.2。
    def windowWgsl(): String =
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    var p = vec2f(0.0, 0.5);\n" +
        "    if (i == 0u) { p = vec2f(-0.5, -0.5); } else if (i == 1u) { p = vec2f(0.5, -0.5); }\n" +
        "    return vec4f(p, 0.0, 1.0);\n" +
        "}\n" +
        "@fragment fn fs_main() -> @location(0) vec4f { return vec4f(1.0, 0.5, 0.25, 1.0); }\n"

    def windowPipeline(gpu: WebGpu, format: TextureFormat): RenderPipeline \ IO =
        let module = gpu.createShaderModule("check window", windowWgsl());
        let desc = new RenderPipelineDesc("check window");
        discard desc.vertex(module, "vs_main").fragment(module, "fs_main").colorTarget(format);
        let pipeline = gpu.createRenderPipeline(desc);
        module.release();
        pipeline

    /// 描き先を取り、三角形を描いて submit する（present はしない）。取れなければ None。
    def drawWindowFrame(gpu: WebGpu, surface: Surface, pipeline: RenderPipeline): Option[Texture] \ IO =
        let texture = surface.getCurrentTexture();
        if (Object.isNull(texture)) None
        else {
            drawTriangles(gpu, texture, pipeline, 3);
            Some(texture)
        }

    /// present の前に描き先を読み、三角形の中 2 点・外 2 点を見る（BGRA の並び）。
    def checkSurfacePixels(gpu: WebGpu, texture: Texture, name: String): Bool \ IO =
        let w = texture.width();
        let h = texture.height();
        let bytesPerRow = (w * 4 + 255) / 256 * 256;
        let buf = readTexture(gpu, texture, w, h);
        let bgra = p -> { let (b, g, r, a) = p; (r, g, b, a) };
        let inA = bgra(rgbaAt(buf, bytesPerRow, w * 3 / 10, h * 7 / 10));
        let inB = bgra(rgbaAt(buf, bytesPerRow, w / 2, h * 6 / 10));
        let outA = bgra(rgbaAt(buf, bytesPerRow, w * 3 / 10, h * 3 / 10));
        let outB = bgra(rgbaAt(buf, bytesPerRow, 3, 3));
        let orange = (255, 128, 64, 255);
        let grey = (51, 51, 51, 255);
        let ok = near(inA, orange) and near(inB, orange) and near(outA, grey) and near(outB, grey);
        report(name, ok, "${w}x${h} in=${showPixel(inA)}/${showPixel(inB)} out=${showPixel(outA)}/${showPixel(outB)}")

    /// ウィンドウの門: 描き先の形・120 コマの間隔・present の前の読み戻し・Retina の倍率・大きさを変えた後の作り直し。
    def window(): Bool \ IO =
        let dawn = DawnWebGpu.open(nativeDir());
        let gpu: WebGpu = checked_cast(dawn);
        // WhyNot: pipeline をウィンドウを開く前に作らない — 描き先の形はウィンドウの surface を作ってからでないと分からない。
        let held = Ref.fresh(Static, None);
        let redrawn = Ref.fresh(Static, 0);
        let redraw = (surface, _w, _h) -> {
            Ref.put(Ref.get(redrawn) + 1, redrawn);
            Ref.get(held) |> Option.forEach(pipeline ->
                drawWindowFrame(gpu, surface, pipeline) |> Option.forEach(_ -> surface.present()))
        };
        match WebGpuWindow.open(dawn, { width = 640, height = 360, title = "webgpu check", visible = true, presentMode = PresentMode.FIFO }, redraw) {
            case Err(why) => report("window-open", false, why)
            case Ok(win)  =>
                let surface = WebGpuWindow.surfaceOf(win);
                let format = WebGpuWindow.formatOf(win);
                let pipeline = windowPipeline(gpu, format);
                Ref.put(Some(pipeline), held);
                let opened = report("window-open", true, "format=${format.toString()} present=FIFO")
                    and reportScale(win);
                let frames = windowFrames(gpu, surface, pipeline, 120);
                let framed = report("window-frames", List.length(frames) == 120 and gpu.errorCount() == 0,
                                    "drawn=${List.length(frames)} interval med=${fmt(median(List.drop(10, frames)))} ms (frames 10..119) errors=${gpu.errorCount()}");
                let readOk = checkOneFrame(gpu, surface, pipeline, "window-readback");
                WebGpuWindow.setWindowSize(win, 800, 450);
                List.range(0, 30) |> List.forEach(_ -> { WebGpuWindow.pollEvents(); Thread.sleep(5i64) });
                let (fbW, fbH) = WebGpuWindow.sizeOf(win);
                let resized = report("window-resize-callback", WebGpuWindow.resizeCount(win) >= 1 and Ref.get(redrawn) >= 1,
                                     "reconfigured=${WebGpuWindow.resizeCount(win)} redrawn=${Ref.get(redrawn)} framebuffer=${fbW}x${fbH}");
                let resizedRead = checkOneFrame(gpu, surface, pipeline, "window-resized-readback");
                WebGpuWindow.close(win);
                opened and framed and readOk and resized and resizedRead
        }

    def reportScale(win: WebGpuWindow.Window): Bool \ IO =
        let (ww, wh) = WebGpuWindow.windowSizeOf(win);
        let (fw, fh) = WebGpuWindow.sizeOf(win);
        match WebGpuWindow.backingScaleOf(win) {
            case Err(why)  => report("window-scale", false, why)
            case Ok(scale) =>
                let expectedW = Float64.round(Int32.toFloat64(ww) * scale);
                report("window-scale", Int32.toFloat64(fw) == expectedW,
                       "window=${ww}x${wh}pt framebuffer=${fw}x${fh}px backingScaleFactor=${scale}")
        }

    /// 1 コマ描いて present の前に読み、present する。
    def checkOneFrame(gpu: WebGpu, surface: Surface, pipeline: RenderPipeline, name: String): Bool \ IO =
        WebGpuWindow.pollEvents();
        match drawWindowFrame(gpu, surface, pipeline) {
            case None          => report(name, false, "描き先を取れない status=${surface.lastStatus().toString()}")
            case Some(texture) =>
                let ok = checkSurfacePixels(gpu, texture, name);
                surface.present();
                ok
        }

    /// n コマ描いて present し、描けたコマの間隔（ms）の列を返す。
    def windowFrames(gpu: WebGpu, surface: Surface, pipeline: RenderPipeline, n: Int32): List[Float64] \ IO =
        let last = Ref.fresh(Static, System.nanoTime());
        let intervals = List.range(0, n) |> List.filterMap(_ -> {
            WebGpuWindow.pollEvents();
            let drawn = drawWindowFrame(gpu, surface, pipeline);
            drawn |> Option.forEach(_ -> surface.present());
            let now = System.nanoTime();
            let ms = Int64.toFloat64(now - Ref.get(last)) / 1000000.0;
            Ref.put(now, last);
            drawn |> Option.map(_ -> ms)
        });
        intervals

    pub def main(): Unit \ IO =
        let mode = System.getenv("WEBGPU_CHECK");
        let windowMode = not Object.isNull(mode) and mode == "window";
        // WhyNot: ウィンドウなしの門まで最初の糸で起動し直さない — ウィンドウを使わない門は糸を選ばず、起動し直す時間だけが増える。
        if (windowMode and LwjglLayer.ensureMainThread()) ()
        else {
            let ok = if (windowMode) window() else offscreen();
            println("RESULT webgpu-check ${if (ok) "OK" else "NG"}");
            System.exit(if (ok) 0 else 1)
        }
}

def main(): Unit \ IO = WebGpuCheck.main()
