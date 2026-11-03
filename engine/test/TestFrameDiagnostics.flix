// TestFrameDiagnostics — 画面の隅に出す診断の行（summaryLines）の字を固定する。

mod TestFrameDiagnostics {

    // GPU の時間が出たコマ: ms は小数 2 桁に四捨五入（1,234,567 ns → 1.23）・描き先ごとの時間を括弧に並べる。
    @Test
    def testSummaryLinesWithGpuTime(): Unit \ Assert =
        let d = { submitNs = 2000000i64, swapNs = 500000i64, gpuNs = Some(1234567i64),
                  gpuPasses = ("bloom", 1000000i64) :: ("screen", 234567i64) :: Nil,
                  scene3dCounts = { instances = 12, drawn = 12, drawCalls = 30 | FrameDiagnostics.emptyScene3dCounts() }, drawItems = 40, liveShaders = 5
                  | FrameDiagnostics.empty() };
        Assert.assertEq(expected = "CPU 送る 2.00 ms・swap 0.50 ms" :: "GPU 1.23 ms（bloom 1.00・screen 0.23）"
                                   :: "3D 置いた物 12・描いた 12・draw call 30" :: "描く物 40・シェーダー 5" :: Nil,
                        FrameDiagnostics.summaryLines(d))

    // 上限を超えて落とした光があれば、3D の行の末尾に種類ごとの数が出る。
    @Test
    def testSummaryLinesShowDroppedLights(): Unit \ Assert =
        let d = { scene3dCounts = { instances = 3, drawn = 3, drawCalls = 4, droppedPointLights = 2, droppedSpotLights = 1 } | FrameDiagnostics.empty() };
        Assert.assertEq(expected = Some("3D 置いた物 3・描いた 3・draw call 4・落とした光 点 2・スポット 1"),
                        List.nth(2, FrameDiagnostics.summaryLines(d)))

    // GPU の時間を測れない（None）なら "GPU -"（0 ms と取り違えない）。
    @Test
    def testSummaryLinesWithoutGpuTime(): Unit \ Assert =
        Assert.assertEq(expected = Some("GPU -"), List.nth(1, FrameDiagnostics.summaryLines(FrameDiagnostics.empty())))
}
