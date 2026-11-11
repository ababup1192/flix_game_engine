// SpatialGrid のテスト。半径の中の物だけが通ること・回す順・升が広がる端を小さな例で固定し、
// 散らした例で全員を比べた答えと同じ番号が返ることを見る。
mod TestSpatialGrid {

    /// 半径の中を通った順の番号。
    def nearIndices(grid: SpatialGrid.SpatialGrid, x: Float64, y: Float64, radius: Float64): List[Int32] =
        SpatialGrid.foldNearIndex(grid, x, y, radius, Nil, (acc, index, _, _) -> index :: acc) |> List.reverse

    /// 全員を比べて半径の中の番号を小さい順に返す（比べる相手の答え）。
    def nearByScan(xs: Vector[Float64], ys: Vector[Float64], x: Float64, y: Float64, radius: Float64): List[Int32] =
        List.range(0, Vector.length(xs)) |> List.filter(i -> {
            let dx = x - Vector.get(i, xs);
            let dy = y - Vector.get(i, ys);
            dx * dx + dy * dy <= radius * radius
        })

    /// 10 × 10 の広さへ n 個を散らした列。
    def scatteredAxis(n: Int32, salt: Int32): Vector[Float64] =
        Vector.range(0, n) |> Vector.map(i -> Hash01.at(i, salt) * 10.0)

    /// 一辺 1 で (0, 0)・(0.5, 0)・(3, 0)・(0, 3) の 4 つ。
    def fourPoints(): SpatialGrid.SpatialGrid =
        SpatialGrid.build(1.0, Vector#{0.0, 0.5, 3.0, 0.0}, Vector#{0.0, 0.0, 0.0, 3.0})

    // ---------------------------------------------------------------
    // 半径の端
    // ---------------------------------------------------------------

    /// 半径の中の物だけが、自分も含めて通る。
    @Test
    def testFoldNearIndexPassesOnlyThoseInsideRadius(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: 1 :: Nil, nearIndices(fourPoints(), 0.0, 0.0, 1.0))

    /// ちょうど半径の距離の物も通る（(0, 0) から (3, 0) は 3）。
    @Test
    def testFoldNearIndexIncludesExactRadius(): Unit \ Assert =
        Assert.assertEq(expected = 2 :: Nil, nearIndices(fourPoints(), 6.0, 0.0, 3.0))

    /// 負の半径では何も通らない（距離 0 の物も）。
    @Test
    def testFoldNearIndexNegativeRadiusPassesNothing(): Unit \ Assert =
        Assert.assertEq(expected = Nil, nearIndices(fourPoints(), 0.0, 0.0, -1.0))

    /// f には入れた時の位置が渡る。
    @Test
    def testFoldNearIndexPassesPositions(): Unit \ Assert =
        Assert.assertEq(expected = (3.0, 0.0) :: Nil,
            SpatialGrid.foldNearIndex(fourPoints(), 3.0, 0.0, 0.5, Nil, (acc, _, x, y) -> (x, y) :: acc))

    /// 升の一辺より大きな半径でも、遠い升の物まで届く。
    @Test
    def testFoldNearIndexRadiusLargerThanCellReachesFarCells(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: 1 :: 2 :: 3 :: Nil, nearIndices(fourPoints(), 0.0, 0.0, 3.0))

    /// Int32 に収まらない大きさの半径でも、全部の升を見る。
    @Test
    def testFoldNearIndexHugeRadiusReachesEverything(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: 1 :: 2 :: 3 :: Nil, nearIndices(fourPoints(), 0.0, 0.0, 1.0e12))

    /// 格子の外の点からでも、半径の中の物は通る（(-2, 0) から (0, 0) は 2）。
    @Test
    def testFoldNearIndexFromOutsideTheGrid(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: Nil, nearIndices(fourPoints(), -2.0, 0.0, 2.0))

    // ---------------------------------------------------------------
    // 回す順
    // ---------------------------------------------------------------

    /// 行が外側で、同じ行は升の左から。下の行の番号 0 は上の行の番号 1・2 の後に通る。
    @Test
    def testFoldNearIndexVisitsRowsOuterThenColumns(): Unit \ Assert =
        let grid = SpatialGrid.build(1.0, Vector#{0.5, 2.5, 0.5}, Vector#{2.5, 0.5, 0.5});
        Assert.assertEq(expected = 2 :: 1 :: 0 :: Nil, nearIndices(grid, 1.5, 1.5, 3.0))

    /// 同じ升の中は入れた順。
    @Test
    def testFoldNearIndexKeepsInsertionOrderInsideCell(): Unit \ Assert =
        let grid = SpatialGrid.build(10.0, Vector#{3.0, 1.0, 2.0}, Vector#{0.0, 0.0, 0.0});
        Assert.assertEq(expected = 0 :: 1 :: 2 :: Nil, nearIndices(grid, 0.0, 0.0, 5.0))

    // ---------------------------------------------------------------
    // 作る口
    // ---------------------------------------------------------------

    /// 物が 1 つも無い格子では何も通らない。
    @Test
    def testEmptyGridPassesNothing(): Unit \ Assert =
        Assert.assertEq(expected = Nil, nearIndices(SpatialGrid.build(1.0, Vector#{}, Vector#{}), 0.0, 0.0, 10.0))

    /// 同じ点に重なった物も全部通る。
    @Test
    def testSamePointKeepsEveryItem(): Unit \ Assert =
        let grid = SpatialGrid.build(1.0, Vector#{2.0, 2.0, 2.0}, Vector#{2.0, 2.0, 2.0});
        Assert.assertEq(expected = 0 :: 1 :: 2 :: Nil, nearIndices(grid, 2.0, 2.0, 0.0))

    /// 0 以下の一辺を渡しても作れて、引ける。
    @Test
    def testZeroMinCellSizeStillFinds(): Unit \ Assert =
        let grid = SpatialGrid.build(0.0, Vector#{0.0, 1.0}, Vector#{0.0, 0.0});
        Assert.assertEq(expected = 1 :: Nil, nearIndices(grid, 1.0, 0.0, 0.5))

    /// 遠くに 1 体はぐれ、しかも一直線でも作れて、群れの中を引ける（升の数が距離に比例すると 10 億升になる）。
    @Test
    def testStrayOnStraightLineStillFinds(): Unit \ Assert =
        let grid = SpatialGrid.build(0.001, Vector#{0.0, 0.5, 1000000.0}, Vector#{0.0, 0.0, 0.0});
        Assert.assertEq(expected = (0 :: 1 :: Nil, 2 :: Nil), (nearIndices(grid, 0.0, 0.0, 1.0), nearIndices(grid, 1000000.0, 0.0, 1.0)))

    /// buildBy の番号は items の並びの位置。
    @Test
    def testBuildByIndexIsListPosition(): Unit \ Assert =
        let grid = SpatialGrid.buildBy(1.0, ("a", 5.0, 5.0) :: ("b", 0.0, 0.0) :: ("c", 5.0, 5.5) :: Nil, item -> { let (_, x, y) = item; (x, y) });
        Assert.assertEq(expected = 0 :: 2 :: Nil, nearIndices(grid, 5.0, 5.0, 1.0))

    // ---------------------------------------------------------------
    // 全員を比べた答えと同じ
    // ---------------------------------------------------------------

    /// 散らした 300 個で、どの物の周りも全員を比べた番号と同じ（半径は升より小さい 0.7 と升より大きい 2.5）。
    @Test
    def testScatteredMatchesFullScan(): Unit \ Assert =
        let xs = scatteredAxis(300, 1);
        let ys = scatteredAxis(300, 2);
        let grid = SpatialGrid.build(1.0, xs, ys);
        let differing = List.range(0, 300) |> List.filter(i -> {
            let x = Vector.get(i, xs);
            let y = Vector.get(i, ys);
            (nearIndices(grid, x, y, 0.7) |> Sort.sortStable) != nearByScan(xs, ys, x, y, 0.7) or
            (nearIndices(grid, x, y, 2.5) |> Sort.sortStable) != nearByScan(xs, ys, x, y, 2.5)
        });
        Assert.assertEq(expected = Nil, differing)

    /// build と buildBy は同じ列から同じ順で回す。
    @Test
    def testBuildAndBuildByVisitTheSameOrder(): Unit \ Assert =
        let xs = scatteredAxis(300, 3);
        let ys = scatteredAxis(300, 4);
        let items = List.range(0, 300) |> List.map(i -> (Vector.get(i, xs), Vector.get(i, ys)));
        Assert.assertEq(expected = nearIndices(SpatialGrid.build(1.0, xs, ys), 5.0, 5.0, 3.0),
            nearIndices(SpatialGrid.buildBy(1.0, items, item -> item), 5.0, 5.0, 3.0))

    // ---------------------------------------------------------------
    // f が内側のループへ畳み込まれている
    // ---------------------------------------------------------------

    /// その場のラムダの割り当ては、Ref に隠して畳み込めなくしたラムダの 3 分の 1 より少ない。
    /// 畳み込まれないと 1 回の呼び出しごとに値を箱へ詰めるので 1 桁増える（手元で 10 倍以上）。時間で見ないのは揺れるため。
    /// 絶対バイト数は JDK で動くので比で見る。割り当てが 2 つとも同じになったら、Flix の最適化か foldRange の形が変わった。
    @Test
    def testInlineLambdaFoldsIntoTheLoop(): Unit \ Assert = region rc {
        let grid = SpatialGrid.build(1.0, scatteredAxis(1000, 5), scatteredAxis(1000, 6));
        let hidden: Ref[((Float64, Float64), Int32, Float64, Float64) -> (Float64, Float64), _] =
            Ref.fresh(rc, (acc, _, x, y) -> { let (sumX, sumY) = acc; (sumX + x, sumY + y) });
        let unfolded = Ref.get(hidden);
        let inlineBytes = AllocMeter.measureBytes(3, () ->
            SpatialGrid.foldNearIndex(grid, 5.0, 5.0, 3.0, (0.0, 0.0), (acc, _, x, y) -> { let (sumX, sumY) = acc; (sumX + x, sumY + y) }));
        let unfoldedBytes = AllocMeter.measureBytes(3, () -> SpatialGrid.foldNearIndex(grid, 5.0, 5.0, 3.0, (0.0, 0.0), unfolded));
        Assert.assertTrue(inlineBytes * 3i64 < unfoldedBytes)
    }
}
