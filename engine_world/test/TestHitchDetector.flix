// TestHitchDetector — ヒッチの切り出しと報告の判定を、作った行で固定する:
// 開く条件（vsync の待ちは数えない・起動直後は数えない）・閉じる時（落ち着いたコマの尾を除く）・
// 1 実行の上限・直前の手の探し方・推定原因の振り分け。

mod TestHitchDetector {

    use App.HitchDetector.{Row, Config}

    def config(): Config =
        { budgetNs = 16000000i64, warmup = 0i64, context = 3, calm = 2, maxRows = 50, maxHitches = 2 }

    /// totalMs のコマ（swap・作ったシェーダー・手は既定で無し）。
    def row(frame: Int64, totalMs: Int64): Row =
        { frame = frame, totalNs = totalMs * 1000000i64, updateNs = 0i64, renderNs = totalMs * 1000000i64, diag = FrameDiagnostics.empty(),
          gc = 0, gcMs = 0i64, pressed = "", status = "", reloaded = false }

    def withSwap(swapMs: Int64, r: Row): Row = { diag = { swapNs = swapMs * 1000000i64 | r#diag } | r }

    def withBuild(name: String, reason: FrameDiagnostics.BuildReason, r: Row): Row =
        { diag = { shaderBuilds = { name = name, reason = reason } :: Nil | r#diag } | r }

    def withPress(key: String, r: Row): Row = { pressed = key | r }

    /// 行を順に流し、閉じた件を集める。
    def detectAll(cfg: Config, rows: List[Row]): List[App.HitchDetector.Hitch] =
        let (_, closed) = rows |> List.foldLeft((acc, r) -> {
            let (det, found) = acc;
            let (next, hitch) = App.HitchDetector.step(r, det);
            (next, List.append(found, Option.toList(hitch)))
        }, (App.HitchDetector.fresh(cfg), Nil));
        closed

    def calm(start: Int64, n: Int64): List[Row] = List.range(0, Int64.tryToInt32(n) |> Option.getWithDefault(0)) |> List.map(i -> row(start + Int32.toInt64(i), 5i64))

    // ── 開く・閉じる ──

    @Test
    def testVsyncWaitDoesNotOpen(): Unit \ Assert =
        let vsynced = List.range(0, 20) |> List.map(i -> withSwap(12i64, row(Int32.toInt64(i), 17i64)));
        Assert.assertEq(expected = 0, List.length(detectAll(config(), vsynced)))

    @Test
    def testSlowWorkOpensAndCloses(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: (row(3i64, 40i64) :: calm(4i64, 2i64));
        Assert.assertEq(expected = 1, List.length(detectAll(config(), rows)))

    @Test
    def testClosedHitchDropsTheCalmTail(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: (row(3i64, 40i64) :: row(4i64, 30i64) :: calm(5i64, 2i64));
        Assert.assertEq(expected = Some(2), detectAll(config(), rows) |> List.head |> Option.map(h -> List.length(h#rows)))

    @Test
    def testShaderBuildOpensEvenWithinBudget(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: (withBuild("water", FrameDiagnostics.BuildReason.First, row(3i64, 5i64)) :: calm(4i64, 2i64));
        Assert.assertEq(expected = 1, List.length(detectAll(config(), rows)))

    @Test
    def testWarmupFramesDoNotOpen(): Unit \ Assert =
        let rows = row(0i64, 300i64) :: calm(1i64, 3i64);
        Assert.assertEq(expected = 0, List.length(detectAll({ warmup = 1i64 | config() }, rows)))

    /// 2 コマ続けて重い（単発ではない）件。
    def burst(f: Int64): List[Row] = row(f, 40i64) :: row(f + 1i64, 40i64) :: calm(f + 2i64, 2i64)

    @Test
    def testStopsAtMaxHitches(): Unit \ Assert =
        let rows = burst(0i64) ::: burst(4i64) ::: burst(8i64);
        Assert.assertEq(expected = 2, List.length(detectAll(config(), rows)))

    @Test
    def testSingleSlowFramesDoNotUseUpTheLimit(): Unit \ Assert =
        let single = (f: Int64) -> { gc = 1, gcMs = 30i64 | row(f, 40i64) } :: calm(f + 1i64, 2i64);
        let rows = single(0i64) ::: single(3i64) ::: single(6i64) ::: burst(9i64);
        Assert.assertEq(expected = 1, detectAll(config(), rows) |> List.count(h -> not App.HitchDetector.isMinor(config(), h)))

    @Test
    def testSingleGcFrameIsMinor(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: ({ gc = 1, gcMs = 30i64 | row(3i64, 40i64) } :: calm(4i64, 2i64));
        Assert.assertEq(expected = Some(true), detectAll(config(), rows) |> List.head |> Option.map(App.HitchDetector.isMinor(config())))

    @Test
    def testSingleSlowUpdateIsNotMinor(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: ({ updateNs = 200000000i64, gc = 1, gcMs = 1i64 | row(3i64, 210i64) } :: calm(4i64, 2i64));
        Assert.assertEq(expected = Some(false), detectAll(config(), rows) |> List.head |> Option.map(App.HitchDetector.isMinor(config())))

    @Test
    def testFullHitchKeepsItsTail(): Unit \ Assert =
        let slow = List.range(0, 6) |> List.map(i -> row(Int32.toInt64(i), 40i64));
        let rows = slow ::: calm(6i64, 2i64);
        Assert.assertEq(expected = Some(5), detectAll({ maxRows = 5 | config() }, rows) |> List.head |> Option.map(h -> List.length(h#rows)))

    // ── 直前の手 ──

    @Test
    def testPressAfterOpeningFrameIsFound(): Unit \ Assert =
        let rows = calm(0i64, 3i64) :::
            (row(3i64, 26i64) :: withPress("Right", row(4i64, 5i64)) ::
             withBuild("water", FrameDiagnostics.BuildReason.Changed("1.4 → 0.8"), row(5i64, 90i64)) :: calm(6i64, 2i64));
        let press = detectAll(config(), rows) |> List.head |> Option.flatMap(App.HitchDetector.pressBefore) |> Option.map(r -> r#pressed);
        Assert.assertEq(expected = Some("Right"), press)

    @Test
    def testPressAfterAnchorIsNotTaken(): Unit \ Assert =
        let rows = calm(0i64, 3i64) :::
            (withBuild("water", FrameDiagnostics.BuildReason.Changed("1.4 → 0.8"), row(3i64, 90i64)) ::
             withPress("Left", row(4i64, 40i64)) :: calm(5i64, 2i64));
        let press = detectAll(config(), rows) |> List.head |> Option.flatMap(App.HitchDetector.pressBefore) |> Option.map(r -> r#pressed);
        Assert.assertEq(expected = None, press)

    // ── 報告 ──

    def reportOf(rows: List[Row]): String =
        detectAll(config(), rows) |> List.head |> Option.map(App.HitchDetector.report(config(), None)) |> Option.getWithDefault("")

    @Test
    def testReportTellsLeakWhenNothingIsDeleted(): Unit \ Assert =
        let live = (n: Int32, r: Row) -> { diag = { liveShaders = n | r#diag } | r };
        let rows = calm(0i64, 3i64) :::
            (live(3, withBuild("water", FrameDiagnostics.BuildReason.Changed("1.4 → 0.8"), row(3i64, 90i64))) ::
             live(7, withBuild("water", FrameDiagnostics.BuildReason.Changed("0.8 → 0.4"), row(4i64, 90i64))) :: calm(5i64, 2i64));
        Assert.assertTrue(String.contains(substr = "漏れ", reportOf(rows)))

    @Test
    def testReportTellsChangedSpecToMoveValueOut(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: (withBuild("water", FrameDiagnostics.BuildReason.Changed("1.4 → 0.8"), row(3i64, 90i64)) :: calm(4i64, 2i64));
        Assert.assertTrue(String.contains(substr = "Spec の外へ出す", reportOf(rows)))

    @Test
    def testReportTellsFirstBuildToPrewarm(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: (withBuild("water", FrameDiagnostics.BuildReason.First, row(3i64, 90i64)) :: calm(4i64, 2i64));
        Assert.assertTrue(String.contains(substr = "作っておく", reportOf(rows)))

    @Test
    def testReportTellsSwapWhenGpuWaits(): Unit \ Assert =
        let rows = calm(0i64, 3i64) ::: (withSwap(60i64, row(3i64, 70i64)) :: withSwap(60i64, row(4i64, 70i64)) :: calm(5i64, 2i64));
        Assert.assertTrue(String.contains(substr = "swap", reportOf(rows)))
}
