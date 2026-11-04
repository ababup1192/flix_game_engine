// TestFrameDiagnostics — 画面の隅に出す診断の行（summaryLines）の字を固定する。

mod TestFrameDiagnostics {

    // GPU の時間が出たコマ: ms は小数 2 桁に四捨五入（1,234,567 ns → 1.23）・描き先ごとの時間を括弧に並べる。
    @Test
    def testSummaryLinesWithGpuTime(): Unit \ Assert =
        let d = { submitNs = 2000000i64, swapNs = 500000i64, gpuNs = Some(1234567i64),
                  gpuPasses = ("bloom", 1000000i64) :: ("screen", 234567i64) :: Nil,
                  scene3dCounts = { instances = 12, drawn = 12, drawCalls = 30 | FrameDiagnostics.emptyScene3dCounts() }, drawItems = 40, liveShaders = 5
                  | FrameDiagnostics.empty() };
        Assert.assertEq(expected = "CPU submit 2.00 ms / swap 0.50 ms" :: "GPU 1.23 ms (bloom 1.00, screen 0.23)"
                                   :: "3D placed 12 / drawn 12 / draw calls 30" :: "2D draw items 40 / shaders 5" :: Nil,
                        FrameDiagnostics.summaryLines(d))

    // 上限を超えて落とした光があれば、3D の行の末尾に種類ごとの数が出る。
    @Test
    def testSummaryLinesShowDroppedLights(): Unit \ Assert =
        let d = { scene3dCounts = { instances = 3, drawn = 3, drawCalls = 4, droppedPointLights = 2, droppedSpotLights = 1 } | FrameDiagnostics.empty() };
        Assert.assertEq(expected = Some("3D placed 3 / drawn 3 / draw calls 4 / dropped lights point 2 / spot 1"),
                        List.nth(2, FrameDiagnostics.summaryLines(d)))

    // GPU の時間を測れない（None）なら "GPU -"（0 ms と取り違えない）。
    @Test
    def testSummaryLinesWithoutGpuTime(): Unit \ Assert =
        Assert.assertEq(expected = Some("GPU -"), List.nth(1, FrameDiagnostics.summaryLines(FrameDiagnostics.empty())))

    // 欧文だけのフォントでも化けないよう、どの行も ASCII の字だけで組む（光を落とし GPU の描き先もあるコマで）。
    @Test
    def testSummaryLinesAreAscii(): Unit \ Assert =
        let d = { gpuNs = Some(1i64), gpuPasses = ("scene", 1i64) :: Nil,
                  scene3dCounts = { instances = 1, drawn = 1, drawCalls = 1, droppedPointLights = 1, droppedSpotLights = 1 }
                  | FrameDiagnostics.empty() };
        let isAscii = (line: String) -> String.toList(line) |> List.forAll(ch -> Char.toBmpCodePoint(ch) < 128);
        Assert.assertTrue(FrameDiagnostics.summaryLines(d) |> List.forAll(isAscii))
}
