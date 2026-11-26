// compute の Java の API（createComputePipeline・beginComputePass・clearBuffer・compute の pass の timestamp）を PC の Dawn で流し、
// 答えを CPU の答えと比べて固定する（layout は明示・ブラウザの BrowserCompute と同じ API の形）。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（`[compute-dawn] SKIP:` の行を出す）。
mod TestComputeDawn {
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.ComputePipelineDesc
    import fge.webgpu.QuerySet
    import fge.webgpu.ShaderStage
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    def count(): Int32 = 10000

    def sumWgsl(): String = String.unlines(
        "@group(0) @binding(0) var<storage, read> src: array<u32>;" ::
        "@group(0) @binding(1) var<storage, read_write> dstU: array<u32>;" ::
        "@group(0) @binding(2) var<storage, read_write> dstF: array<f32>;" ::
        "@group(0) @binding(3) var<storage, read_write> total: atomic<u32>;" ::
        "@compute @workgroup_size(64)" ::
        "fn cs_main(@builtin(global_invocation_id) id: vec3u) {" ::
        "  let i = id.x;" ::
        "  if (i >= arrayLength(&src)) { return; }" ::
        "  let v = src[i];" ::
        "  dstU[i] = v * v + 7u;" ::
        "  dstF[i] = sin(f32(v) * 0.01) * 0.5 + sqrt(f32(v));" ::
        "  atomicAdd(&total, v);" ::
        "}" :: Nil)

    def sourceAt(i: Int32): Int32 = Int64.truncateToInt32(Int64.remainder(Int32.toInt64(i) * 2654435761i64, 1000i64))

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    /// Dawn の device で f を流す（開けなければ SKIP の行を出して通す）。
    def withDawn(f: WebGpu -> Unit \ {Assert, IO}): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[compute-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                f(gpu);
                gpu.destroy()
        }

    def littleEndian(size: Int32): ByteBuffer \ IO = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN)

    def storage(gpu: WebGpu, label: String, size: Int32): Buffer \ IO =
        gpu.createBuffer(label, Int32.toInt64(size), Int32.bitwiseOr(BufferUsage.STORAGE, Int32.bitwiseOr(BufferUsage.COPY_SRC, BufferUsage.COPY_DST)))

    /// buffer の頭から size バイトを読み戻す。
    def readBack(gpu: WebGpu, buffer: Buffer, size: Int32): ByteBuffer \ IO =
        let staging = gpu.createBuffer("test compute read", Int32.toInt64(size), Int32.bitwiseOr(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let encoder = gpu.createCommandEncoder("test compute read");
        encoder.copyBufferToBuffer(buffer, 0i64, staging, 0i64, Int32.toInt64(size));
        gpu.submit(encoder.finish());
        let out = littleEndian(size);
        gpu.readBuffer(staging, 0i64, size, out);
        staging.destroy();
        out

    /// 1 万個の和・u32 の式・f32 の式を 1 回の dispatch で求め、(GPU の和, u32 の式の食い違いの数, f32 の式の 1e-4 を超える数) を返す。
    def runSum(gpu: WebGpu): (Int64, Int32, Int32) \ IO =
        let n = count();
        let src = storage(gpu, "src", n * 4);
        let dstU = storage(gpu, "dstU", n * 4);
        let dstF = storage(gpu, "dstF", n * 4);
        let total = storage(gpu, "total", 16);
        let up = littleEndian(n * 4);
        List.range(0, n) |> List.forEach(i -> discard up.putInt(i * 4, sourceAt(i)));
        gpu.writeBuffer(src, 0i64, up, 0, n * 4);
        gpu.writeBuffer(total, 0i64, littleEndian(16), 0, 16);
        let rw = BufferBindingType.STORAGE;
        let layoutDesc = new BindGroupLayoutDesc("test sum");
        discard layoutDesc.buffer(0, ShaderStage.COMPUTE, BufferBindingType.READ_ONLY_STORAGE);
        List.range(1, 4) |> List.forEach(b -> discard layoutDesc.buffer(b, ShaderStage.COMPUTE, rw));
        let layout = gpu.createBindGroupLayout(layoutDesc);
        let module = gpu.createShaderModule("test sum", sumWgsl());
        let pipeline = gpu.createComputePipeline(new ComputePipelineDesc("test sum").bindGroupLayout(layout).compute(module, "cs_main"));
        let groupDesc = new BindGroupDesc("test sum", layout);
        discard groupDesc.buffer(0, src, 0i64, Int32.toInt64(n * 4));
        discard groupDesc.buffer(1, dstU, 0i64, Int32.toInt64(n * 4));
        discard groupDesc.buffer(2, dstF, 0i64, Int32.toInt64(n * 4));
        discard groupDesc.buffer(3, total, 0i64, 4i64);
        let group = gpu.createBindGroup(groupDesc);
        let encoder = gpu.createCommandEncoder("test sum");
        let pass = encoder.beginComputePass("test sum", (checked_cast(null): QuerySet), 0, 0);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        pass.dispatchWorkgroups((n + 63) / 64, 1, 1);
        pass.end();
        gpu.submit(encoder.finish());
        let outU = readBack(gpu, dstU, n * 4);
        let outF = readBack(gpu, dstF, n * 4);
        let outT = readBack(gpu, total, 16);
        let badU = List.range(0, n) |> List.count(i -> outU.getInt(i * 4) != sourceAt(i) * sourceAt(i) + 7);
        let badF = List.range(0, n) |> List.count(i -> {
            let v = Int32.toFloat64(sourceAt(i));
            let cpu = Num.sin(v * 0.01) * 0.5 + Num.sqrt(v);
            Float64.abs(cpu - Float32.toFloat64(outF.getFloat(i * 4))) > 1.0e-4
        });
        group.release();
        pipeline.release();
        module.release();
        layout.release();
        src.destroy(); dstU.destroy(); dstF.destroy(); total.destroy();
        (Int64.bitwiseAnd(Int32.toInt64(outT.getInt(0)), 0xffffffffi64), badU, badF)

    def cpuTotal(): Int64 = List.range(0, count()) |> List.foldLeft((acc, i) -> acc + Int32.toInt64(sourceAt(i)), 0i64)

    @Test
    def testAtomicSumOfTenThousandMatchesCpu(): Unit \ {Assert, IO} =
        withDawn(gpu -> { let (t, _, _) = runSum(gpu); Assert.assertEq(expected = cpuTotal(), t) })

    @Test
    def testU32ExpressionMatchesCpuByteForByte(): Unit \ {Assert, IO} =
        withDawn(gpu -> { let (_, badU, _) = runSum(gpu); Assert.assertEq(expected = 0, badU) })

    @Test
    def testF32ExpressionIsWithinOneTenThousandthOfCpu(): Unit \ {Assert, IO} =
        withDawn(gpu -> { let (_, _, badF) = runSum(gpu); Assert.assertEq(expected = 0, badF) })

    /// 64 個の u32（全部 0xffffffff）の 16 番目から 32 個を clearBuffer で 0 にし、読み戻した 64 個を返す。
    def clearedWords(gpu: WebGpu): List[Int32] \ IO =
        let buffer = storage(gpu, "test clear", 256);
        let ones = littleEndian(256);
        List.range(0, 64) |> List.forEach(i -> discard ones.putInt(i * 4, -1));
        gpu.writeBuffer(buffer, 0i64, ones, 0, 256);
        let encoder = gpu.createCommandEncoder("test clear");
        encoder.clearBuffer(buffer, 64i64, 128i64);
        gpu.submit(encoder.finish());
        let out = readBack(gpu, buffer, 256);
        buffer.destroy();
        List.range(0, 64) |> List.map(i -> out.getInt(i * 4))

    @Test
    def testClearBufferZeroesOnlyTheGivenRange(): Unit \ {Assert, IO} =
        let expected = List.range(0, 64) |> List.map(i -> if (i >= 16 and i < 48) 0 else -1);
        withDawn(gpu -> Assert.assertEq(expected = expected, clearedWords(gpu)))

    /// compute の pass の始めと終わりの時刻（timestamp-query の無い device は None）。
    def passTimes(gpu: WebGpu): Option[(Int64, Int64)] \ IO =
        if (not gpu.hasTimestampQuery()) None
        else {
            let n = 65536;
            let buffer = storage(gpu, "test ts", n * 4);
            let layout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("test ts").buffer(0, ShaderStage.COMPUTE, BufferBindingType.STORAGE));
            let module = gpu.createShaderModule("test ts", String.unlines(
                "@group(0) @binding(0) var<storage, read_write> data: array<u32>;" ::
                "@compute @workgroup_size(64) fn cs_main(@builtin(global_invocation_id) id: vec3u) {" ::
                "  var x = id.x; for (var k = 0u; k < 256u; k++) { x = x * 1664525u + 1013904223u; } data[id.x] = x; }" :: Nil));
            let pipeline = gpu.createComputePipeline(new ComputePipelineDesc("test ts").bindGroupLayout(layout).compute(module, "cs_main"));
            let group = gpu.createBindGroup(new BindGroupDesc("test ts", layout).buffer(0, buffer, 0i64, Int32.toInt64(n * 4)));
            let querySet = gpu.createTimestampQuerySet("test ts", 2);
            let resolved = gpu.createBuffer("test ts resolve", 16i64, Int32.bitwiseOr(BufferUsage.QUERY_RESOLVE, BufferUsage.COPY_SRC));
            let encoder = gpu.createCommandEncoder("test ts");
            let pass = encoder.beginComputePass("test ts", querySet, 0, 1);
            pass.setPipeline(pipeline);
            pass.setBindGroup(0, group);
            pass.dispatchWorkgroups(n / 64, 1, 1);
            pass.end();
            encoder.resolveQuerySet(querySet, 0, 2, resolved, 0i64);
            gpu.submit(encoder.finish());
            let out = readBack(gpu, resolved, 16);
            querySet.destroy(); resolved.destroy(); buffer.destroy();
            group.release(); pipeline.release(); module.release(); layout.release();
            Some((out.getLong(0), out.getLong(8)))
        }

    @Test
    def testComputePassTimestampsAreWrittenInOrder(): Unit \ {Assert, IO} =
        withDawn(gpu -> match passTimes(gpu) {
            case None => println("[compute-dawn] SKIP: timestamp-query が無い device"); Assert.assertEq(expected = 0, 0)
            case Some((begin, end)) => Assert.assertEq(expected = (true, true), (begin > 0i64, end >= begin))
        })
}
