// WebGPU のウィンドウなしの session の、GPU を呼ばない所（読み戻しの行の長さ・行の上下の入れ替え・ARGB から rgba8unorm の並び・
// open の Err の道: device を開けない・大きさが上限の外なら device を捨てる）を固定する。
// WhyNot: mod TestWebGpuOffscreen にしない — 固定したい関数は WebGpuOffscreen の中の pub でない関数で、子のモジュールからしか呼べない。
mod WebGpuOffscreen.TestWebGpuOffscreen {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.CommandBuffer
    import fge.webgpu.CommandEncoder
    import fge.webgpu.FilterMode
    import fge.webgpu.Limits
    import fge.webgpu.QuerySet
    import fge.webgpu.RenderBundleEncoder
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Sampler
    import fge.webgpu.ShaderModule
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    use WebGpuOffscreen.{argbToRgbaBytes, copyRowsFlipped, rowBytes}

    @Test
    def testRowBytesRoundsUpTo256(): Unit \ Assert =
        Assert.assertEq(expected = (256, 256, 512, 1280), (rowBytes(1), rowBytes(256), rowBytes(257), rowBytes(320 * 4)))

    @Test
    def testArgbBecomesRgbaByteOrderLowByteFirst(): Unit \ Assert =
        // 0xAARRGGBB = 0x7F112233 → メモリの並び r=0x11, g=0x22, b=0x33, a=0x7F → 小さい方のバイトから読んだ Int32 は 0x7F332211。
        Assert.assertEq(expected = 0x7F332211, argbToRgbaBytes(0x7F112233))

    @Test
    def testOpaqueWhiteStaysAllOnes(): Unit \ Assert =
        Assert.assertEq(expected = -1, argbToRgbaBytes(-1))

    /// 3 行 × 行の長さ 8 バイト（中身 4 バイト）の src を、行を詰めて上下を入れ替えて読む。
    def flipped(): List[Int32] \ IO =
        let src = ByteBuffer.allocate(24);
        List.range(0, 24) |> List.forEach(i -> discard src.put(i, Int32.clampToInt8(min = 0i8, max = 127i8, i)));
        let dst = ByteBuffer.allocate(12);
        copyRowsFlipped(src, 8, dst, 4, 3, 0);
        List.range(0, 12) |> List.map(i -> Int8.toInt32(dst.get(i)))

    /// handler が返す device の上で width × height を open した結果（開けた時は "opened"）。
    def openOn(device: Result[String, WebGpu], width: Int32, height: Int32): Result[String, String] \ IO =
        run {
            WebGpuOffscreen.open({ width = width, height = height }) |> Result.map(_ -> "opened")
        } with handler WebGpuDevice {
            def requestDevice(k) = k(device)
        }

    @Test
    def testOpenReturnsTheHandlersErrorWhenNoDevice(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err("no device here"), openOn(Err("no device here"), 8, 8))

    @Test
    def testOpenTooLargeIsErrAndDestroysTheDevice(): Unit \ {Assert, IO} =
        let destroyed = Ref.fresh(Static, 0);
        let got = openOn(Ok(fakeGpu(16, destroyed)), 32, 8);
        Assert.assertEq(expected = (Err("描き先の大きさ 32x8 は 1〜16 の外"), 1), (got, Ref.get(destroyed)))

    @Test
    def testOpenZeroWidthIsErrAndDestroysTheDevice(): Unit \ {Assert, IO} =
        let destroyed = Ref.fresh(Static, 0);
        let got = openOn(Ok(fakeGpu(16, destroyed)), 0, 8);
        Assert.assertEq(expected = (Err("描き先の大きさ 0x8 は 1〜16 の外"), 1), (got, Ref.get(destroyed)))

    /// 2D の上限が largest で、destroy を数えるだけの device（ほかの関数は呼ばれない前提）。
    def fakeGpu(largest: Int32, destroyed: Ref[Int32, Static]): WebGpu \ IO =
        new WebGpu {
            def adapterInfo(_this: WebGpu): String = "fake"
            def limits(_this: WebGpu): Limits \ IO = new Limits(largest, 1, 1, 1, 1, 1, 1, 1, 1, 256, 256, 1i64, 1i64, 1i64)
            def hasTimestampQuery(_this: WebGpu): Bool = false
            def hasCoreFeaturesAndLimits(_this: WebGpu): Bool = false
            def errorCount(_this: WebGpu): Int32 = 0
            def lastError(_this: WebGpu): String = ""
            def destroy(_this: WebGpu): Unit \ IO = Ref.put(Ref.get(destroyed) + 1, destroyed)
            def createBuffer(_this: WebGpu, _label: String, _size: Int64, _usage: Int32): Buffer = unused()
            def createTexture(_this: WebGpu, _label: String, _w: Int32, _h: Int32, _f: TextureFormat, _u: Int32, _m: Int32, _s: Int32): Texture = unused()
            def createSampler(_this: WebGpu, _label: String, _f: FilterMode, _m: FilterMode, _a: AddressMode): Sampler = unused()
            def createShaderModule(_this: WebGpu, _label: String, _wgsl: String): ShaderModule = unused()
            def getCompilationInfo(_this: WebGpu, _m: ShaderModule): String = unused()
            def createBindGroupLayout(_this: WebGpu, _d: BindGroupLayoutDesc): BindGroupLayout = unused()
            def createBindGroup(_this: WebGpu, _d: BindGroupDesc): BindGroup = unused()
            def createRenderPipeline(_this: WebGpu, _d: RenderPipelineDesc): RenderPipeline = unused()
            def createTimestampQuerySet(_this: WebGpu, _label: String, _count: Int32): QuerySet = unused()
            def createCommandEncoder(_this: WebGpu, _label: String): CommandEncoder = unused()
            def createRenderBundleEncoder(_this: WebGpu, _label: String, _color: TextureFormat, _depth: TextureFormat, _samples: Int32): RenderBundleEncoder = unused()
            def writeBuffer(_this: WebGpu, _b: Buffer, _o: Int64, _d: ByteBuffer, _do: Int32, _s: Int32): Unit = unused()
            def writeTexture(_this: WebGpu, _t: Texture, _m: Int32, _x: Int32, _y: Int32, _w: Int32, _h: Int32, _d: ByteBuffer, _do: Int32, _r: Int32): Unit = unused()
            def submit(_this: WebGpu, _c: CommandBuffer): Unit = unused()
            def readBuffer(_this: WebGpu, _b: Buffer, _o: Int64, _s: Int32, _d: ByteBuffer): Unit = unused()
            def waitIdle(_this: WebGpu): Unit = unused()
        }

    def unused(): a = bug!("この偽の device では呼ばない")

    @Test
    def testRowsAreCopiedBottomFirstWithoutPadding(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 16 :: 17 :: 18 :: 19 :: 8 :: 9 :: 10 :: 11 :: 0 :: 1 :: 2 :: 3 :: Nil, flipped())
}
