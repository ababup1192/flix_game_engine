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
                                   :: "3D placed 12 / drawn 12 / draw calls 30" :: "2D draw items 40 / shaders 5"
                                   :: "2D draw calls 0"
                                   :: "3D uploads -" :: "3D cpu -" :: "3D batch breaks -" :: Nil,
                        FrameDiagnostics.summaryLines(d))

    // 上限を超えて落とした光があれば、3D の行の末尾に種類ごとの数が出る。
    @Test
    def testSummaryLinesShowDroppedLights(): Unit \ Assert =
        let d = { scene3dCounts = { instances = 3, drawn = 3, drawCalls = 4, droppedPointLights = 2, droppedSpotLights = 1 | FrameDiagnostics.emptyScene3dCounts() } | FrameDiagnostics.empty() };
        Assert.assertEq(expected = Some("3D placed 3 / drawn 3 / draw calls 4 / dropped lights point 2 / spot 1"),
                        List.nth(2, FrameDiagnostics.summaryLines(d)))

    // ビルボードの行があれば、3D の行に行の数と絵の種類の数が出る（落とした光より前）。
    @Test
    def testSummaryLinesShowBillboardRuns(): Unit \ Assert =
        let d = { scene3dCounts = { instances = 3, drawn = 3, drawCalls = 9, billboardRuns = 6, billboardImages = 2, droppedSpotLights = 1
                                    | FrameDiagnostics.emptyScene3dCounts() } | FrameDiagnostics.empty() };
        Assert.assertEq(expected = Some("3D placed 3 / drawn 3 / draw calls 9 / billboard runs 6 / images 2 / dropped lights point 0 / spot 1"),
                        List.nth(2, FrameDiagnostics.summaryLines(d)))

    // GPU の時間を測れない（None）なら "GPU -"（0 ms と取り違えない）。
    @Test
    def testSummaryLinesWithoutGpuTime(): Unit \ Assert =
        Assert.assertEq(expected = Some("GPU -"), List.nth(1, FrameDiagnostics.summaryLines(FrameDiagnostics.empty())))

    // 欧文だけのフォントでも化けないよう、どの行も ASCII の字だけで組む（光を落とし GPU の描き先もあるコマで）。
    @Test
    def testSummaryLinesAreAscii(): Unit \ Assert =
        let d = { gpuNs = Some(1i64), gpuPasses = ("scene", 1i64) :: Nil,
                  scene3dCounts = { instances = 1, drawn = 1, drawCalls = 1, droppedPointLights = 1, droppedSpotLights = 1,
                                    meshUploads = 1, jointUploads = 1, cpuPhases = ("draw", 1i64) :: Nil | FrameDiagnostics.emptyScene3dCounts() }
                  | FrameDiagnostics.empty() };
        let isAscii = (line: String) -> String.toList(line) |> List.forAll(ch -> Char.toBmpCodePoint(ch) < 128);
        Assert.assertTrue(FrameDiagnostics.summaryLines(d) |> List.forAll(isAscii))

    // 3D を置かないコマ（2D だけのゲーム）は、上げ直し・CPU の区間・3D の理由の行を出さない（2D までの 5 行）。
    @Test
    def testSummaryLinesWithout3dHaveFiveLines(): Unit \ Assert =
        Assert.assertEq(expected = 5, List.length(FrameDiagnostics.summaryLines(FrameDiagnostics.empty())))

    // 2D の行は draw call の数と、切れた理由のうち一番多い物（blend 72）を出す。
    @Test
    def testSummaryLinesShowTopDraw2dBreak(): Unit \ Assert =
        let breaks = { blend = 72, kind = 19, mask = 4 | FrameDiagnostics.emptyDraw2dCounts()#batchBreaks };
        let d = { draw2dCounts = { drawCalls = 96, batchBreaks = breaks } | FrameDiagnostics.empty() };
        Assert.assertEq(expected = Some("2D draw calls 96 / top break blend 72"), List.nth(4, FrameDiagnostics.summaryLines(d)))

    // 理由ごとの数は 0 でない欄だけを、Draw2dBatchBreaks の欄の順に並べる。
    @Test
    def testBreaksTextShowsNonZeroInFieldOrder(): Unit \ Assert =
        let breaks = { mask = 4, kind = 19, blend = 72 | FrameDiagnostics.emptyDraw2dCounts()#batchBreaks };
        Assert.assertEq(expected = "kind 19 / blend 72 / mask 4", FrameDiagnostics.breaksText(FrameDiagnostics.draw2dBreakList(breaks)))

    // 一番多い理由が同じ数で並ぶ時は、欄の順で先の物（kind が texture より先）。
    @Test
    def testTopBreakPrefersEarlierFieldOnTie(): Unit \ Assert =
        let breaks = { kind = 3, texture = 3 | FrameDiagnostics.emptyDraw2dCounts()#batchBreaks };
        Assert.assertEq(expected = Some(("kind", 3)), FrameDiagnostics.topBreak(FrameDiagnostics.draw2dBreakList(breaks)))

    // 切れ目が無ければ、一番多い理由は無い（"top break" を出さない）。
    @Test
    def testTopBreakIsNoneWithoutBreaks(): Unit \ Assert =
        Assert.assertEq(expected = None, FrameDiagnostics.topBreak(FrameDiagnostics.draw2dBreakList(FrameDiagnostics.emptyDraw2dCounts()#batchBreaks)))

    // 2 コマぶんの 2D の数を足すと、draw call も理由も欄ごとの和になる（1 + 3 = 4・texture 0 + 2 = 2）。
    @Test
    def testAddDraw2dCountsSumsFields(): Unit \ Assert =
        let a = { drawCalls = 1 | FrameDiagnostics.emptyDraw2dCounts() };
        let b = { drawCalls = 3, batchBreaks = { texture = 2 | FrameDiagnostics.emptyDraw2dCounts()#batchBreaks } };
        let sum = FrameDiagnostics.addDraw2dCounts(a, b);
        Assert.assertEq(expected = (4, 2), (sum#drawCalls, sum#batchBreaks#texture))

    // 2 コマぶんの 3D の数を足すと、分かれた理由も欄ごとの和になる（material 2 + 3 = 5）。
    @Test
    def testAddScene3dCountsSumsBatchBreaks(): Unit \ Assert =
        let a = { batchBreaks = { material = 2 | FrameDiagnostics.emptyScene3dBatchBreaks() } | FrameDiagnostics.emptyScene3dCounts() };
        let b = { batchBreaks = { material = 3, mesh = 1 | FrameDiagnostics.emptyScene3dBatchBreaks() } | FrameDiagnostics.emptyScene3dCounts() };
        let sum = FrameDiagnostics.addScene3dCounts(a, b)#batchBreaks;
        Assert.assertEq(expected = (5, 1), (sum#material, sum#mesh))

    // 上げ直した物と捨てた物は 0 でない欄だけを、Scene3dCounts の欄の順に並べる。
    @Test
    def testUploadsTextShowsNonZeroInFieldOrder(): Unit \ Assert =
        let c = { meshEvictions = 2, mipCopies = 1, jointUploads = 300 | FrameDiagnostics.emptyScene3dCounts() };
        Assert.assertEq(expected = "evict 2 / mip 1 / joints 300", FrameDiagnostics.uploadsText(c))

    // CPU の区間は名前と ms（小数 2 桁）を並べる。
    @Test
    def testCpuPhasesText(): Unit \ Assert =
        let c = { cpuPhases = ("shadows", 1500000i64) :: ("draw", 4000000i64) :: Nil | FrameDiagnostics.emptyScene3dCounts() };
        Assert.assertEq(expected = "shadows 1.50, draw 4.00", FrameDiagnostics.cpuPhasesText(c))

    // 2 コマぶんを足すと、数は和・CPU の区間は同じ名前どうしの和で、初めて出た順に並ぶ。
    @Test
    def testAddScene3dCountsSumsPhasesByName(): Unit \ Assert =
        let a = { jointUploads = 3, cpuPhases = ("split", 1i64) :: ("draw", 2i64) :: Nil | FrameDiagnostics.emptyScene3dCounts() };
        let b = { jointUploads = 4, cpuPhases = ("draw", 5i64) :: ("endFrame", 7i64) :: Nil | FrameDiagnostics.emptyScene3dCounts() };
        let sum = FrameDiagnostics.addScene3dCounts(a, b);
        Assert.assertEq(expected = (7, ("split", 1i64) :: ("draw", 7i64) :: ("endFrame", 7i64) :: Nil), (sum#jointUploads, sum#cpuPhases))

    // 組んだ材質のプログラムは、上げ直しの行に組んだ数で出る。
    @Test
    def testUploadsTextCountsMaterialBuilds(): Unit \ Assert =
        let built = { name = "scene3d:material:a", reason = FrameDiagnostics.BuildReason.First };
        let c = { materialBuilds = built :: built :: Nil | FrameDiagnostics.emptyScene3dCounts() };
        Assert.assertEq(expected = "material 2", FrameDiagnostics.uploadsText(c))
}
