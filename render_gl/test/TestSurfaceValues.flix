// WebGPU の面の draw が、面の行の values を program の欄の数ぶん uniform として読めるかの決まり（canReadValues）を固定する（GPU を呼ばない所）。
// WhyNot: mod TestSurfaceValues にしない — canReadValues は WebGpuSurfaces の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderPaint.Internal.WebGpuSurfaces.TestSurfaceValues {
    use RenderPaint.Internal.WebGpuSurfaces.canReadValues

    /// 欄 6 個の program は、値 6 個の行（64 個取る）を読める。
    @Test
    def testFewSlotsFit(): Unit \ Assert =
        Assert.assertTrue(canReadValues(6, 6))

    /// 行の値が欄より少なくても、行が取った 64 個の内なら読む（欄 20 個・値 6 個）。
    @Test
    def testFewerValuesWithinTakenFit(): Unit \ Assert =
        Assert.assertTrue(canReadValues(20, 6))

    /// 欄 66 個（264 バイト）は、値 7 個の行が取った 64 個（256 バイト）を超えるので読まない。
    @Test
    def testSlotsOverTakenDoNotFit(): Unit \ Assert =
        Assert.assertFalse(canReadValues(66, 7))

    /// 値 65 個の行は 128 個取るので、欄 66 個を読める。
    @Test
    def testLongRowTakesTwoSteps(): Unit \ Assert =
        Assert.assertTrue(canReadValues(66, 65))
}
