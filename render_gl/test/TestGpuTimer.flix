// TestGpuTimer — GPU の時間の query の輪の読み方（GL を呼ばない純粋な部分）を具体値で固定する。
// query の番号は 1 から振り、結果が出ている番号の集合と、番号 → 時刻の表で GL の代わりをする。

mod TestGpuTimer {

    /// 描き先 name を query begin・end で測った Span。
    def span(name: String, begin: Int32, end: Int32): GpuTimer.Span = { name = name, begin = begin, end = end }

    /// 3 つのコマ（古い順）: 1 コマ目は query 1〜2・2 コマ目は 3〜4・3 コマ目は 5〜6。
    def threeFrames(): List[List[GpuTimer.Span]] =
        (span("screen", 1, 2) :: Nil) :: (span("screen", 3, 4) :: Nil) :: (span("screen", 5, 6) :: Nil) :: Nil

    // ── 結果の出たコマだけ読む ──

    // 古い 2 コマの結果が出ていて 3 コマ目はまだなら、2 コマを読み、3 コマ目は待ちに残す（GPU を待たない）。
    @Test
    def testHarvestReadsOnlyReadyFrames(): Unit \ Assert =
        let h = GpuTimer.harvest(id -> id <= 4, threeFrames());
        Assert.assertEq(expected = (2, 1, 0), (List.length(h#ready), List.length(h#waiting), List.length(h#dropped)))

    // 古いコマの結果がまだなら、後ろのコマの結果が出ていても読まない（古い順に読む）。
    @Test
    def testHarvestStopsAtFirstPendingFrame(): Unit \ Assert =
        let h = GpuTimer.harvest(id -> id >= 3, threeFrames());
        Assert.assertEq(expected = (0, 3), (List.length(h#ready), List.length(h#waiting)))

    // 結果が出ないまま ringDepth()（3）を超えたコマは、古い物から読まずに捨てる。
    @Test
    def testHarvestDropsFramesBeyondRingDepth(): Unit \ Assert =
        let four = List.append(threeFrames(), (span("screen", 7, 8) :: Nil) :: Nil);
        let h = GpuTimer.harvest(_ -> false, four);
        Assert.assertEq(expected = (0, 3, (1, 2) :: Nil),
                        (List.length(h#ready), List.length(h#waiting), List.flatten(h#dropped) |> List.map(s -> (s#begin, s#end))))

    // ── 読めたコマの時間 ──

    // Pass（bloom: 100〜400 ns）の後に画面（500〜1500 ns）を描いたコマ: 全体は 100〜1500 の 1400 ns・描き先ごとは描いた順。
    @Test
    def testSummarizeTotalsFromFirstBeginToLastEnd(): Unit \ Assert =
        let times = Map#{1 => 100i64, 2 => 400i64, 3 => 500i64, 4 => 1500i64};
        let frame = span("bloom", 1, 2) :: span("screen", 3, 4) :: Nil;
        Assert.assertEq(expected = Some((1400i64, ("bloom", 300i64) :: ("screen", 1000i64) :: Nil)),
                        GpuTimer.summarize(id -> Map.getWithDefault(id, 0i64, times), frame) |> Option.map(t -> (t#gpuNs, t#passes)))
}
