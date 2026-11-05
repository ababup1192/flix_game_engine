// FlowField のテスト。字で書いた小さな盤で、歩数・下るマス・同じ歩数の時の選び方を固定し、
// 散らした盤で GridSearch.distances と同じ歩数になることを見る。
mod TestFlowField {

    /// 字の盤（'#' は壁）の開いたマスの述語。
    def openCellsOf(board: Vector[String]): (Int32, Int32) -> Bool =
        (col, row) -> String.charAt(col, Vector.get(row, board)) != '#'

    /// board を goal から塗った地図。
    def paint(board: Vector[String], goal: (Int32, Int32), neighbors: FlowField.Neighbors): FlowField.FlowField =
        FlowField.build(String.length(Vector.get(0, board)), Vector.length(board), openCellsOf(board), goal :: Nil, { neighbors = neighbors, maxSteps = 200 })

    /// 真ん中に柱のある 3 × 3 の輪。
    def ring(): Vector[String] = Vector#{"#####", "#...#", "#.#.#", "#...#", "#####"}

    /// 壁の無い 3 × 3。
    def room(): Vector[String] = Vector#{"...", "...", "..."}

    // ---------------------------------------------------------------
    // 塗っていない地図
    // ---------------------------------------------------------------

    /// empty は空で、どのマスも None。
    @Test
    def testEmptyHasNoCells(): Unit \ Assert =
        Assert.assertEq(expected = (true, None, None),
            (FlowField.isEmpty(FlowField.empty()), FlowField.stepsAt(FlowField.empty(), (0, 0)), FlowField.downhill(FlowField.empty(), (0, 0))))

    /// 目的が 1 つも無くても、塗った地図は空ではない。
    @Test
    def testBuildWithoutGoalsIsNotEmpty(): Unit \ Assert =
        let field = FlowField.build(2, 2, (_, _) -> true, Nil, { neighbors = FlowField.Neighbors.Four, maxSteps = 10 });
        Assert.assertEq(expected = (false, None), (FlowField.isEmpty(field), FlowField.stepsAt(field, (0, 0))))

    // ---------------------------------------------------------------
    // 歩数
    // ---------------------------------------------------------------

    /// 輪の向こう角は 4 歩（柱を回る）。
    @Test
    def testStepsWalkAroundWall(): Unit \ Assert =
        Assert.assertEq(expected = Some(4), FlowField.stepsAt(paint(ring(), (1, 1), FlowField.Neighbors.Four), (3, 3)))

    /// Eight でも歩数は 4 方向で塗る（部屋の角から角は 4 歩）。
    @Test
    def testEightStillPaintsFourWaySteps(): Unit \ Assert =
        Assert.assertEq(expected = Some(4), FlowField.stepsAt(paint(room(), (0, 0), FlowField.Neighbors.Eight), (2, 2)))

    /// 地図の外と壁のマスは None。
    @Test
    def testOutsideAndWallAreUnpainted(): Unit \ Assert =
        let field = paint(ring(), (1, 1), FlowField.Neighbors.Four);
        Assert.assertEq(expected = (None, None, None), (FlowField.stepsAt(field, (-1, 0)), FlowField.stepsAt(field, (9, 9)), FlowField.stepsAt(field, (2, 2))))

    /// 壁で分かれた床には届かない。
    @Test
    def testUnreachableFloorIsUnpainted(): Unit \ Assert =
        let field = paint(Vector#{"#####", "#.#.#", "#####"}, (1, 1), FlowField.Neighbors.Four);
        Assert.assertEq(expected = (None, None), (FlowField.stepsAt(field, (3, 1)), FlowField.downhill(field, (3, 1))))

    /// maxSteps より遠いマスは届かない扱い。
    @Test
    def testMaxStepsLimitsPainting(): Unit \ Assert =
        let field = FlowField.build(5, 1, (_, _) -> true, (0, 0) :: Nil, { neighbors = FlowField.Neighbors.Four, maxSteps = 2 });
        Assert.assertEq(expected = (Some(2), None), (FlowField.stepsAt(field, (2, 0)), FlowField.stepsAt(field, (3, 0))))

    /// 目的が 2 つなら近い方までの歩数。
    @Test
    def testManyGoalsUseTheNearest(): Unit \ Assert =
        let field = FlowField.build(5, 1, (_, _) -> true, (0, 0) :: (4, 0) :: Nil, { neighbors = FlowField.Neighbors.Four, maxSteps = 10 });
        Assert.assertEq(expected = (Some(1), Some(2)), (FlowField.stepsAt(field, (3, 0)), FlowField.stepsAt(field, (2, 0))))

    /// 壁の上と外の目的は無視する。
    @Test
    def testGoalsOnWallOrOutsideAreIgnored(): Unit \ Assert =
        let field = FlowField.build(3, 1, (col, _) -> col != 1, (1, 0) :: (9, 9) :: (-1, 0) :: Nil, { neighbors = FlowField.Neighbors.Four, maxSteps = 10 });
        Assert.assertEq(expected = (None, None), (FlowField.stepsAt(field, (0, 0)), FlowField.stepsAt(field, (2, 0))))

    // ---------------------------------------------------------------
    // 下るマス
    // ---------------------------------------------------------------

    /// 目的のマスに下る先は無い。
    @Test
    def testGoalHasNoDownhill(): Unit \ Assert =
        Assert.assertEq(expected = None, FlowField.downhill(paint(ring(), (1, 1), FlowField.Neighbors.Eight), (1, 1)))

    /// 同じ歩数なら上を右より先に選ぶ（輪の (3, 3) は上の (3, 2) と左の (2, 3) が同じ 3 歩）。
    @Test
    def testTiePrefersUpBeforeLeft(): Unit \ Assert =
        Assert.assertEq(expected = Some((3, 2)), FlowField.downhill(paint(ring(), (1, 1), FlowField.Neighbors.Four), (3, 3)))

    /// 部屋の真ん中から 4 方向の同着は、上 → 右の順（目的が右上の角で、上も右も 2 歩から 1 歩）。
    @Test
    def testTiePrefersUpBeforeRight(): Unit \ Assert =
        Assert.assertEq(expected = Some((1, 0)), FlowField.downhill(paint(room(), (2, 0), FlowField.Neighbors.Four), (1, 1)))

    /// Eight は開いた斜めを取る（2 歩小さい (0, 0) へ）。
    @Test
    def testEightTakesOpenDiagonal(): Unit \ Assert =
        Assert.assertEq(expected = Some((0, 0)), FlowField.downhill(paint(room(), (0, 0), FlowField.Neighbors.Eight), (1, 1)))

    /// Four は斜めへ下らない。
    @Test
    def testFourNeverGoesDiagonal(): Unit \ Assert =
        Assert.assertEq(expected = Some((1, 0)), FlowField.downhill(paint(room(), (0, 0), FlowField.Neighbors.Four), (1, 1)))

    /// 脇のマスが壁なら斜めへ抜けない（(1, 1) から目的の (0, 0) へは脇の (1, 0) が壁なので、左の (0, 1) へ下る）。
    @Test
    def testEightDoesNotCutWallCorner(): Unit \ Assert =
        Assert.assertEq(expected = Some((0, 1)), FlowField.downhill(paint(Vector#{".#.", "...", "..."}, (0, 0), FlowField.Neighbors.Eight), (1, 1)))

    // ---------------------------------------------------------------
    // GridSearch と同じ歩数
    // ---------------------------------------------------------------

    /// 3 割が壁の 20 × 20 の散らした盤で、全部のマスの歩数が GridSearch.distances と同じ。
    @Test
    def testScatteredMatchesGridSearchDistances(): Unit \ Assert =
        let isOpen = (col: Int32, row: Int32) -> Hash01.at(row * 20 + col, 7) >= 0.3 or (col == 0 and row == 0);
        let canEnter = (cell: (Int32, Int32)) -> {
            let (col, row) = cell;
            col >= 0 and row >= 0 and col < 20 and row < 20 and isOpen(col, row)
        };
        let expected = GridSearch.distances(canEnter, (0, 0) :: Nil, 100);
        let field = FlowField.build(20, 20, isOpen, (0, 0) :: Nil, { neighbors = FlowField.Neighbors.Four, maxSteps = 100 });
        let cells = List.range(0, 400) |> List.map(i -> (Int32.remainder(i, 20), i / 20));
        Assert.assertEq(expected = cells |> List.map(cell -> Map.get(cell, expected)), cells |> List.map(FlowField.stepsAt(field)))
}
