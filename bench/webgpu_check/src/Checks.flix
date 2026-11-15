// PC とブラウザで同じに流す門（ウィンドウを使わない物）。device は入口が差す WebGpuDevice の handler が開き、
// 結果の 1 行は CheckLog の handler が出す（PC は標準出力の "RESULT …"・ブラウザは console の "[bench] result {…}"）。
// 画素は読み戻した中身の digest も出し、PC とブラウザの行を並べて同じ画素かを見る。
mod WebGpuSharedChecks {
    use fge::{GlOffscreen, Sort, WebGpuDevice, WebGpuOffscreen}

    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.QuerySet
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    /// 門の結果を 1 行ずつ出す口。
    pub eff CheckLog {
        /// name の門の合否と、比べた値の文。
        def result(name: String, ok: Bool, detail: String): Unit
    }

    // ── 結果の行 ──────────────────────────────

    /// 1 行を出し、合否を返す。
    pub def report(name: String, ok: Bool, detail: String): Bool \ CheckLog =
        CheckLog.result(name, ok, detail);
        ok

    /// 画素 (x, y) の r, g, b, a（buf は 1 行 rowBytes バイト・r が先頭の並び）。
    pub def rgbaAt(buf: ByteBuffer, rowBytes: Int32, x: Int32, y: Int32): (Int32, Int32, Int32, Int32) \ IO =
        let o = y * rowBytes + x * 4;
        (Int8.toInt32(buf.get(o)) `Int32.bitwiseAnd` 255, Int8.toInt32(buf.get(o + 1)) `Int32.bitwiseAnd` 255,
         Int8.toInt32(buf.get(o + 2)) `Int32.bitwiseAnd` 255, Int8.toInt32(buf.get(o + 3)) `Int32.bitwiseAnd` 255)

    pub def near(got: (Int32, Int32, Int32, Int32), want: (Int32, Int32, Int32, Int32)): Bool =
        let (r, g, b, a) = got;
        let (wr, wg, wb, wa) = want;
        Int32.abs(r - wr) <= 1 and Int32.abs(g - wg) <= 1 and Int32.abs(b - wb) <= 1 and Int32.abs(a - wa) <= 1

    pub def showPixel(p: (Int32, Int32, Int32, Int32)): String =
        let (r, g, b, a) = p;
        "${r},${g},${b},${a}"

    def usage2(a: Int32, b: Int32): Int32 = Int32.bitwiseOr(a, b)

    /// buf の先頭 bytes バイトを 4 バイトずつ混ぜた数（PC とブラウザの画素を 1 つの数で比べる）。
    def digest(buf: ByteBuffer, bytes: Int32): Int32 \ IO = digestFrom(buf, bytes / 4, 0, 17)

    def digestFrom(buf: ByteBuffer, count: Int32, i: Int32, acc: Int32): Int32 \ IO =
        if (i >= count) acc
        else digestFrom(buf, count, i + 1, acc * 31 + buf.getInt(i * 4))

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
    pub def drawTriangles(gpu: WebGpu, target: Texture, pipeline: RenderPipeline, vertexCount: Int32): Unit \ IO =
        let encoder = gpu.createCommandEncoder("check triangles");
        let pass = encoder.beginRenderPass(new RenderPassDesc("check triangles").clearColor(target.defaultView(), 0.2, 0.2, 0.2, 1.0));
        pass.setPipeline(pipeline);
        pass.draw(vertexCount, 1, 0, 0);
        pass.end();
        gpu.submit(encoder.finish())

    /// ウィンドウなしの session に面の向きつきで描き、readRgba（下の行から）で読む。cull が BACK なら右の三角形は消える。
    pub def checkTriangles(session: WebGpuOffscreen.Session, name: String, cull: CullMode, rightDrawn: Bool): Bool \ IO + CheckLog =
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
        let errors = gpu.errorCount();
        let ok = near(left, orange) and near(right, if (rightDrawn) orange else grey) and near(top, grey) and errors == 0;
        report(name, ok, "left=${showPixel(left)} right=${showPixel(right)} top=${showPixel(top)} digest=${digest(buf, w * h * 4)} errors=${errors}")

    // ── 上限 ──────────────────────────────

    def checkLimits(gpu: WebGpu): Bool \ IO + CheckLog =
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
    def checkFloatRows(session: WebGpuOffscreen.Session): Bool \ IO + CheckLog =
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

    /// Argb8 の絵（2 × 1 と 1 × 1 の mip 2 つ・linear の sampler）を Float32 の絵と並べて読む:
    /// mip 0 の 2 画素（r = 0 と 1）の真ん中は 0.5 前後・mip 1 は (r, g) = (0, 1) がそのまま・Float32 の絵の左端は 0.125。
    def checkArgbMipRows(session: WebGpuOffscreen.Session): Bool \ IO + CheckLog =
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
    def checkOpenErr(): Bool \ IO + WebGpuDevice + CheckLog = match WebGpuOffscreen.open({ width = 0, height = 64 }) {
        case Err(why) => report("open-err-size", true, why)
        case Ok(s)    => WebGpuOffscreen.close(s); report("open-err-size", false, "大きさ 0 で開けた")
    }

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
    def benchFrame(gpu: WebGpu, target: Texture, pipeline: RenderPipeline, bind: RenderPass -> Unit \ IO, n: Int32,
                   perInstance: Bool, timing: Option[(QuerySet, Buffer, Buffer)], tsBuf: ByteBuffer): FrameTime \ IO =
        let t0 = System.nanoTime();
        let encoder = gpu.createCommandEncoder("check bench");
        let passDesc = new RenderPassDesc("check bench").clearColor(target.defaultView(), 0.05, 0.05, 0.08, 1.0);
        timing |> Option.forEach(t -> { let (qs, _, _) = t; discard passDesc.timestampWrites(qs, 0, 1) });
        let pass = encoder.beginRenderPass(passDesc);
        pass.setPipeline(pipeline);
        bind(pass);
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

    pub def median(xs: List[Float64]): Float64 =
        let sorted = Sort.sortStable(xs);
        List.nth(List.length(sorted) / 2, sorted) |> Option.getWithDefault(0.0)

    def runFrames(gpu: WebGpu, target: Texture, pipeline: RenderPipeline, bind: RenderPass -> Unit \ IO, n: Int32,
                  perInstance: Bool, timing: Option[(QuerySet, Buffer, Buffer)], count: Int32): List[FrameTime] \ IO =
        let tsBuf = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN);
        List.range(0, count) |> List.map(_ -> benchFrame(gpu, target, pipeline, bind, n, perInstance, timing, tsBuf))

    pub def fmt(x: Float64): String = Float64.toString(Float64.round(x * 1000.0) / 1000.0)

    /// 1 体の値を頂点バッファ（instance ごと・location 0）から読む形。絵は quadsWgsl と同じ。
    def quadsVertexWgsl(): String =
        "struct V { @builtin(position) pos: vec4f, @location(0) shade: f32 };\n" +
        "@vertex fn vs_main(@builtin(vertex_index) i: u32, @location(0) r: vec4f) -> V {\n" +
        "    var c = array<vec2f, 6>(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0), vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));\n" +
        "    var out: V;\n" +
        "    out.pos = vec4f(r.xy + c[i] * r.z, 0.0, 1.0);\n" +
        "    out.shade = r.w;\n" +
        "    return out;\n" +
        "}\n" +
        "@fragment fn fs_main(v: V) -> @location(0) vec4f { return vec4f(v.shade, 1.0 - v.shade, 0.5, 1.0); }\n"

    /// 1 つの形で測った物: draw 1 本で N 体（inst）と、firstInstance で 1 体ずつ N 本（each）の時間と、それぞれの絵の digest。
    type alias Measured = { inst = List[FrameTime], instDigest = Int32, each = List[FrameTime], eachDigest = Int32 }

    /// 温めの 40 コマを捨て、200 コマを測る。
    def measureShape(gpu: WebGpu, target: Texture, size: Int32, pipeline: RenderPipeline, bind: RenderPass -> Unit \ IO,
                     n: Int32, timing: Option[(QuerySet, Buffer, Buffer)]): Measured \ IO =
        let warm = 40;
        let measured = 200;
        let imageBytes = size * size * 4;
        let inst = runFrames(gpu, target, pipeline, bind, n, false, timing, warm + measured) |> List.drop(warm);
        let instDigest = digest(readTexture(gpu, target, size, size), imageBytes);
        let each = runFrames(gpu, target, pipeline, bind, n, true, timing, warm + measured) |> List.drop(warm);
        let eachDigest = digest(readTexture(gpu, target, size, size), imageBytes);
        { inst = inst, instDigest = instDigest, each = each, eachDigest = eachDigest }

    /// 測った物の 1 行（中央値と小さい方の値）。
    def measuredLine(n: Int32, m: Measured): String =
        let med = (xs: List[FrameTime], f: FrameTime -> Float64) -> fmt(median(List.map(f, xs)));
        "N=${n} frames=${List.length(m#each)} | draw(6,N) cpu med=${med(m#inst, f -> f#cpuMs)} ms gpu med=${med(m#inst, f -> f#gpuMs)} ms" +
        " | draw(6,1,0,k)×N cpu med=${med(m#each, f -> f#cpuMs)} ms gpu med=${med(m#each, f -> f#gpuMs)} ms (limit 3 ms)" +
        " | same image=${m#instDigest == m#eachDigest} digest=${m#eachDigest}" +
        " | draw(6,1,0,k)×N smallest cpu=${smallest(m#each |> List.map(f -> f#cpuMs))} gpu=${smallest(m#each |> List.map(f -> f#gpuMs))}"

    /// 20,000 体を「draw 1 本」と「firstInstance で 1 体ずつ draw」で描き、絵が同じかと 1 体ずつの CPU の時間（合格線 3 ms）を見る。
    /// 1 体の値の読み方を 2 つ測る: storage buffer を instance_index で引く形と、instance の頂点バッファを firstInstance から読む形（2D の道の形）。
    /// 頂点バッファの形は、storage の形と同じ絵になる事も見る。
    def checkFirstInstance(gpu: WebGpu): Bool \ IO + CheckLog =
        let n = 20000;
        let size = 1024;
        let rowsBytes = n * 16;
        let data = ByteBuffer.allocateDirect(rowsBytes).order(ByteOrder.LITTLE_ENDIAN);
        fillRows(data, n, 0);
        let target = gpu.createTexture("check bench", size, size, TextureFormat.RGBA8_UNORM, usage2(TextureUsage.RENDER_ATTACHMENT, TextureUsage.COPY_SRC), 1, 1);
        let timing = if (gpu.hasTimestampQuery())
            Some((gpu.createTimestampQuerySet("check bench", 2),
                  gpu.createBuffer("check ts resolve", 16i64, usage2(BufferUsage.QUERY_RESOLVE, BufferUsage.COPY_SRC)),
                  gpu.createBuffer("check ts read", 16i64, usage2(BufferUsage.COPY_DST, BufferUsage.MAP_READ))))
            else None;
        // storage buffer と instance_index
        let rows = gpu.createBuffer("check rows", Int32.toInt64(rowsBytes), usage2(BufferUsage.STORAGE, BufferUsage.COPY_DST));
        gpu.writeBuffer(rows, 0i64, data, 0, rowsBytes);
        let layout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("check rows").buffer(0, ShaderStage.VERTEX, BufferBindingType.READ_ONLY_STORAGE));
        let group = gpu.createBindGroup(new BindGroupDesc("check rows", layout).buffer(0, rows, 0i64, Int32.toInt64(rowsBytes)));
        let module = gpu.createShaderModule("check quads", quadsWgsl());
        let desc = new RenderPipelineDesc("check quads");
        discard desc.bindGroupLayout(layout).vertex(module, "vs_main").fragment(module, "fs_main").colorTarget(TextureFormat.RGBA8_UNORM);
        let pipeline = gpu.createRenderPipeline(desc);
        let storage = measureShape(gpu, target, size, pipeline, pass -> pass.setBindGroup(0, group), n, timing);
        // instance の頂点バッファと firstInstance
        let vertices = gpu.createBuffer("check vertex rows", Int32.toInt64(rowsBytes), usage2(BufferUsage.VERTEX, BufferUsage.COPY_DST));
        gpu.writeBuffer(vertices, 0i64, data, 0, rowsBytes);
        let vertexModule = gpu.createShaderModule("check quads vertex", quadsVertexWgsl());
        let vertexDesc = new RenderPipelineDesc("check quads vertex");
        discard vertexDesc.vertex(vertexModule, "vs_main").fragment(vertexModule, "fs_main");
        discard vertexDesc.vertexBuffer(16, true).attribute(VertexFormat.FLOAT32X4, 0, 0).colorTarget(TextureFormat.RGBA8_UNORM);
        let vertexPipeline = gpu.createRenderPipeline(vertexDesc);
        let vertex = measureShape(gpu, target, size, vertexPipeline, pass -> pass.setVertexBuffer(0, vertices, 0i64, Int32.toInt64(rowsBytes)), n, timing);
        let errors = gpu.errorCount();
        // WhyNot: ByteBuffer.mismatch で比べない — TeaVM に無く、ブラウザで同じコードが組めない。
        let storageOk = storage#instDigest == storage#eachDigest and median(storage#each |> List.map(f -> f#cpuMs)) <= 3.0 and errors == 0;
        let sameAsStorage = vertex#eachDigest == storage#eachDigest;
        let vertexOk = vertex#instDigest == vertex#eachDigest and sameAsStorage
            and median(vertex#each |> List.map(f -> f#cpuMs)) <= 3.0 and errors == 0;
        timing |> Option.forEach(t -> { let (qs, resolve, read) = t; qs.destroy(); resolve.destroy(); read.destroy() });
        group.release();
        pipeline.release();
        module.release();
        layout.release();
        rows.destroy();
        vertexPipeline.release();
        vertexModule.release();
        vertices.destroy();
        target.destroy();
        let storageReported = report("first-instance", storageOk, "${measuredLine(n, storage)} errors=${errors}");
        let vertexReported = report("first-instance-vertex", vertexOk, "${measuredLine(n, vertex)} same as storage=${sameAsStorage} errors=${errors}");
        storageReported and vertexReported

    /// 測った値のうち小さい方から 6 つ（重なりは 1 つに）。時計の刻みを見るため丸めない。
    def smallest(xs: List[Float64]): String =
        List.toSet(xs) |> Set.toList |> List.take(6) |> List.map(Float64.toString) |> String.intercalate(",")

    /// 4 バイトの画素 width 個の行を readTexture が返す時の 1 行のバイト数（256 の倍数）。
    pub def paddedRowBytes(width: Int32): Int32 = (width * 4 + 255) / 256 * 256

    /// texture を読み戻す（行は paddedRowBytes にそろえたまま）。
    pub def readTexture(gpu: WebGpu, texture: Texture, width: Int32, height: Int32): ByteBuffer \ IO =
        let bytesPerRow = paddedRowBytes(width);
        let out = gpu.createBuffer("check read", Int32.toInt64(bytesPerRow * height), usage2(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let encoder = gpu.createCommandEncoder("check read");
        encoder.copyTextureToBuffer(texture, 0, 0, 0, width, height, out, 0i64, bytesPerRow);
        gpu.submit(encoder.finish());
        let buf = ByteBuffer.allocateDirect(bytesPerRow * height);
        gpu.readBuffer(out, 0i64, bytesPerRow * height, buf);
        out.destroy();
        buf

    // ── まとめ ──────────────────────────────

    /// ウィンドウを使わない門を全部流し、全部通ったかを返す。
    pub def offscreen(): Bool \ IO + WebGpuDevice + CheckLog =
        match WebGpuOffscreen.open({ width = 64, height = 64 }) {
            case Err(why)    => report("open", false, why)
            case Ok(session) =>
                let gpu = WebGpuOffscreen.gpuOf(session);
                let results =
                    report("open", true, "64x64") ::
                    checkOpenErr() ::
                    checkLimits(gpu) ::
                    checkTriangles(session, "triangle-cull-back", CullMode.BACK, false) ::
                    checkTriangles(session, "triangle-cull-none", CullMode.NONE, true) ::
                    checkFloatRows(session) ::
                    checkArgbMipRows(session) ::
                    checkFirstInstance(gpu) :: Nil;
                WebGpuOffscreen.close(session);
                List.forAll(identity, results)
        }
}
