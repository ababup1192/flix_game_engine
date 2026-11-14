// WebGPU の窓なしの session の、GPU を呼ばない所（読み戻しの行の長さ・行の上下の入れ替え・ARGB から rgba8unorm の並び）を固定する。
// WhyNot: mod TestWebGpuOffscreen にしない — 固定したい関数は WebGpuOffscreen の中の pub でない関数で、子のモジュールからしか呼べない。
mod WebGpuOffscreen.TestWebGpuOffscreen {
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

    /// device を開けない handler の上で open した結果（開けた時は "opened"）。
    def openWithoutDevice(): Result[String, String] \ IO =
        run {
            WebGpuOffscreen.open({ width = 8, height = 8 }) |> Result.map(_ -> "opened")
        } with handler WebGpuOffscreen.GpuDevice {
            def requestDevice(k) = k(Err("no device here"))
        }

    @Test
    def testOpenReturnsTheHandlersErrorWhenNoDevice(): Unit \ Assert =
        Assert.assertEq(expected = Err("no device here"), unchecked_cast(openWithoutDevice() as _ \ {}))

    @Test
    def testRowsAreCopiedBottomFirstWithoutPadding(): Unit \ Assert =
        Assert.assertEq(expected = 16 :: 17 :: 18 :: 19 :: 8 :: 9 :: 10 :: 11 :: 0 :: 1 :: 2 :: 3 :: Nil,
                        unchecked_cast(flipped() as _ \ {}))
}
