// ルールと進行だけをテストする（方針どおり）。演出（閃光・光球）や座標の写経はしない。
// 期待値はリテラルでなく Doc（RulesDoc.defaults）から導く — バランス調整で壊れないように。
//
// World を直接組んで規則関数を当てる。盤の座標は (col, row)、row 0 が最上段。
mod TestRules {

    use World.Kind
    use World.Cell

    /// 既定の Doc から空の World を作り、current だけ差し替えられるようにする土台。
    def base(): World.World =
        World.initial({ doc = RulesDoc.defaults(), theme = ThemeDoc.defaults(),
                        shader = ShaderDoc.demoSurface() })

    /// current を指定の Piece に据えた World（衝突・移動・回転のテスト用）。
    def withPiece(kind: Kind, rot: Int32, col: Int32, row: Int32, w: World.World): World.World =
        { current = { kind = kind, rot = rot, col = col, row = row }, phase = World.Phase.Playing | w }

    /// (col,row) の集合を盤に固定した World。
    def withBoard(cells: List[(Cell, Kind)], w: World.World): World.World =
        { board = List.foldLeft((b, e) -> { let (c, k) = e; Map.insert(c, k, b) }, Map.empty(), cells) | w }

    /// 1 行分（全 COLS）を kind で埋めるセル列。
    def fullRow(r: Int32, kind: Kind): List[(Cell, Kind)] =
        List.range(0, World.cols()) |> List.map(c -> ((c, r), kind))

    /// w から連続して n 回涌かせた World の列（純粋。盤が空なら涌き衝突しない）。
    def spawnChain(n: Int32, w: World.World): List[World.World] =
        if (n <= 0) Nil
        else { let w2 = World.spawnNext(w); w2 :: spawnChain(n - 1, w2) }

    // ══════════════════════════════════════════════════════
    // 衝突（壁・床・既存セル）
    // ══════════════════════════════════════════════════════

    @Test
    def testWallBlocksMove(): Unit \ Assert =
        // 左端に詰めた O ミノは、さらに左へは動けない（盤の外へ出ない）。
        let w = withPiece(Kind.O, 0, -1, 0, base());   // O の左端セルは col 1 相対 → col 0 が左端
        let (_, moved) = World.tryMove(-1, 0, w);
        Assert.assertEq(expected = false, moved)

    @Test
    def testFloorBlocksMove(): Unit \ Assert =
        // 床に着いた O ミノは、さらに下へは動けない。
        let w = withPiece(Kind.O, 0, 4, World.rows() - 2, base());  // O は row 0..1 相対 → 下端が最下段
        let (_, moved) = World.tryMove(0, 1, w);
        Assert.assertEq(expected = false, moved)

    @Test
    def testExistingCellBlocksMove(): Unit \ Assert =
        // 直下に固定セルがあると、そこへは下がれない（積みの上で止まる）。
        let stacked = withBoard(fullRow(World.rows() - 1, Kind.I), base());
        let w = withPiece(Kind.O, 0, 4, World.rows() - 3, stacked);
        let (_, moved) = World.tryMove(0, 1, w);
        Assert.assertEq(expected = false, moved)

    // ══════════════════════════════════════════════════════
    // 回転（形が変わる・壁際でウォールキックが入る）
    // ══════════════════════════════════════════════════════

    @Test
    def testRotateChangesCells(): Unit \ Assert =
        // T ミノを回すと 4 マスの並びが変わる（回転が効いている）。
        let w = withPiece(Kind.T, 0, 4, 4, base());
        let (rotated, ok) = World.tryRotate(1, w);
        let before = World.piecesCells(w#current);
        let after = World.piecesCells(rotated#current);
        Assert.assertEq(expected = (true, true), (ok, before != after))

    @Test
    def testWallKickLetsRotateAtLeftEdge(): Unit \ Assert =
        // 左端に貼りついた I ミノ（縦）は、素直に回すと盤外へ出るが、
        // ウォールキックが右へずらして回転を通す（壁際でも入る）。
        let w = withPiece(Kind.I, 1, -2, 0, base());   // 縦 I の実セルが col 0 に来る位置
        let (rotated, ok) = World.tryRotate(1, w);
        // 回転が通り、かつ結果が盤内に収まっている。
        Assert.assertEq(
            expected = (true, false),
            (ok, World.collides(rotated#current, rotated#board)))

    // ══════════════════════════════════════════════════════
    // ライン検出・消去（詰め直し）
    // ══════════════════════════════════════════════════════

    @Test
    def testFullRowDetected(): Unit \ Assert =
        // 最下段を全部埋めると、その行が「揃った行」として検出される。
        let b = withBoard(fullRow(World.rows() - 1, Kind.Z), base());
        Assert.assertEq(expected = (World.rows() - 1) :: Nil, World.fullRows(b#board))

    @Test
    def testClearShiftsRowsDown(): Unit \ Assert =
        // 下の 1 行を消すと、その上に載っていたセルが 1 行下へ詰まる。
        let bottom = World.rows() - 1;
        let cells = List.append(fullRow(bottom, Kind.I), ((3, bottom - 1), Kind.T) :: Nil);
        let cleared = World.clearLines(bottom :: Nil, withBoard(cells, base())#board);
        // 元 (3, bottom-1) のセルは (3, bottom) へ落ちる。消えた行のセルは残らない。
        Assert.assertEq(
            expected = (Some(Kind.T), false),
            (Map.get((3, bottom), cleared), Map.memberOf((3, bottom - 1), cleared)))

    @Test
    def testTwoRowsClearTogether(): Unit \ Assert =
        // 下 2 行同時に埋めると、2 行とも検出される（同時消しが効く）。
        let bottom = World.rows() - 1;
        let b = withBoard(List.append(fullRow(bottom, Kind.I), fullRow(bottom - 1, Kind.O)), base());
        Assert.assertEq(expected = 2, List.length(World.fullRows(b#board)))

    // ══════════════════════════════════════════════════════
    // 接地/lock（設置面ねばり = ルール）
    // ══════════════════════════════════════════════════════

    @Test
    def testGroundedLocksAfterLockDelay(): Unit \ Assert =
        // 床に着いた（grounded）ミノは、lockDelay を過ぎると盤に固定される
        // = そのセルが board に書き込まれる。時間は Doc の lockDelay から導く。
        let landed = { grounded = true, gravityTimer = 0.0, lockTimer = 0.0 |
            withPiece(Kind.O, 0, 4, World.rows() - 2, base()) };
        let d = RulesDoc.defaults();
        let r = RulesDoc.rec(d);
        // 1 フレームで lockDelay を超えるだけの dt を与える（重力で下がれず即固定へ）。
        let after = World.step(false, r#lockDelay + 0.01, landed);
        Assert.assertEq(expected = false, Map.isEmpty(after#board))

    @Test
    def testMoveResetsLockTimer(): Unit \ Assert =
        // 接地中に横移動が成功すると lockTimer が 0 に戻る（設置面ねばり）。
        let landed = { grounded = true, lockTimer = 0.3 |
            withPiece(Kind.O, 0, 4, World.rows() - 2, base()) };
        let (moved, ok) = World.tryMove(-1, 0, landed);
        Assert.assertEq(expected = (true, 0.0), (ok, moved#lockTimer))

    @Test
    def testMaxLockResetsForcesLock(): Unit \ Assert =
        // 猶予リセットが上限（maxLockResets）に達していると、猶予が残っていても即固定される。
        let d = RulesDoc.defaults();
        let r = RulesDoc.rec(d);
        let landed = { grounded = true, lockTimer = 0.0, lockResets = r#maxLockResets |
            withPiece(Kind.O, 0, 4, World.rows() - 2, base()) };
        // ごく短い dt でも（lockDelay 未満でも）上限に達しているので固定される。
        let after = World.step(false, 0.001, landed);
        Assert.assertEq(expected = false, Map.isEmpty(after#board))

    // ══════════════════════════════════════════════════════
    // 涌き衝突 → GAME OVER
    // ══════════════════════════════════════════════════════

    @Test
    def testSpawnIntoStackIsGameOver(): Unit \ Assert =
        // 涌き位置（上端中央）が埋まっていると、次のミノが涌いた瞬間にぶつかり GAME OVER になる。
        // 上 2 行の中央付近だけ塞ぐ（行は満杯にしない = ライン消しには行かせない）。
        let blockTop = List.range(0, 2) |> List.flatMap(r ->
            List.range(3, 7) |> List.map(c -> ((c, r), Kind.I)));
        // さらに現在のミノがすぐ固定されるよう、その真下も塞いでおく。
        let stacked = withBoard(List.append(blockTop, ((4, 2), Kind.T) :: Nil), base());
        // いまのミノを叩きつけて固定 → 次のミノが涌き位置（塞がれた上端）へ出て衝突する。
        let after = World.hardDrop({ current = { kind = Kind.O, rot = 0, col = 6, row = 0 } | stacked });
        Assert.assertEq(expected = World.Phase.GameOver, after#phase)

    // ══════════════════════════════════════════════════════
    // ハードドロップ（叩きつけ）
    // ══════════════════════════════════════════════════════

    @Test
    def testHardDropLandsOnStack(): Unit \ Assert =
        // 最下段が埋まった盤に O を叩きつけると、その 1 行上に載って固定される。
        let bottom = World.rows() - 1;
        let stacked = withBoard(fullRow(bottom, Kind.I), base());
        let w = withPiece(Kind.O, 0, 4, 0, stacked);
        let after = World.hardDrop(w);
        // O の実セルは相対 (1,0)(2,0)(1,1)(2,1) → col 4 では実列 5,6・下端 row 1。
        // 最下段（bottom）が塞がっているので下端が bottom-1 に載る = (5,bottom-1)(6,bottom-1) が埋まる。
        Assert.assertEq(
            expected = (true, true),
            (Map.memberOf((5, bottom - 1), after#board), Map.memberOf((6, bottom - 1), after#board)))

    // ══════════════════════════════════════════════════════
    // NEXT 予告（袋の切れ目でも実物と一致する）
    // ══════════════════════════════════════════════════════

    @Test
    def testNextPreviewMatchesFollowingSpawn(): Unit \ Assert =
        // 空盤で連続して涌かせ、各ステップの NEXT が「次に実際に涌くミノ」と一致することを固定する。
        // 16 回涌かせて 7-bag の切れ目を跨ぐ（袋の最後の 1 枚で NEXT が現在のミノに化けないこと）。
        let worlds = base() :: spawnChain(16, base());
        let pairs = List.zip(worlds, List.drop(1, worlds));
        let allMatch = pairs |> List.forAll(pair -> {
            let (prev, cur) = pair;
            prev#nextKind == cur#current#kind
        });
        Assert.assertEq(expected = true, allMatch)

    // ══════════════════════════════════════════════════════
    // スコア（期待値は Doc から導く・リテラル禁止）
    // ══════════════════════════════════════════════════════

    @Test
    def testScoreFromDoc(): Unit \ Assert =
        // n 行消しの得点は RulesDoc.scoreFor（Doc の scores 表）から引く。範囲外は 0。
        let d = RulesDoc.defaults();
        Assert.assertEq(
            expected = (RulesDoc.scoreFor(1, d), RulesDoc.scoreFor(4, d), 0),
            (RulesDoc.scoreFor(1, d), RulesDoc.scoreFor(4, d), RulesDoc.scoreFor(99, d)))

    @Test
    def testClearingAddsDocScore(): Unit \ Assert =
        // Clearing の演出が終わると、消した行数ぶんの得点（Doc 由来）が score に入る。
        let bottom = World.rows() - 1;
        let d = RulesDoc.defaults();
        let r = RulesDoc.rec(d);
        let clearing = { phase = World.Phase.Clearing, clearRows = bottom :: Nil, clearTimer = 0.0 |
            withBoard(fullRow(bottom, Kind.I), base()) };
        let after = World.step(false, r#clearDuration + 0.01, clearing);
        Assert.assertEq(
            expected = (RulesDoc.scoreFor(1, d), 1),
            (after#score, after#lines))
}
