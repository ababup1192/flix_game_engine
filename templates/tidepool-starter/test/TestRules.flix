// 1 手の規則（World）: 立つ高さ・行ける条件・押す表・流された・クリア・取り消し・やり直し・貝殻。
// 盤は格子で書く。満ち引きの表を 1 つの値にした盤（cycle = [L]）は潮位がいつも L。
mod TestRules {

    use fge::Worldline
    use Fixtures.{board, placesAfter, res}
    use World.Move

    def start(b: Board.Board): World.State = World.startOf(b)

    // ══════════════════════════════════════════════════════
    // 立つ高さと行ける条件
    // ══════════════════════════════════════════════════════

    /// 高さ 1 から高さ 3 へは立つ高さの差が 2 なので登れない（手に数えない）。
    @Test
    def testCannotClimbTwoLevels(): Unit \ Assert =
        let b = board(0 :: Nil, "3333" :: "3133" :: "3333" :: Nil, "...." :: ".@.." :: "...*" :: Nil);
        Assert.assertEq(expected = None, placesAfter(b, Move.Right, start(b)))

    /// 面 1 の道で 2 手待つと潮位 2: 隣の高さ 1 のマスは沈んでいるので入れない。
    @Test
    def testCannotEnterASubmergedCell(): Unit \ Assert =
        let b = Fixtures.crossing();
        let waited = World.actAll(b, Move.Right :: Move.Wait :: Nil, start(b));
        Assert.assertEq(expected = None, placesAfter(b, Move.Right, waited))

    /// 高さ 0 の着地した流木に乗り、2 手待つと潮位 3: 流木が浮いて立つ高さが 3 になり、隣の高さ 3 の岩へ移れる。
    @Test
    def testDriftwoodLiftsTheCrabOnTheRisingTide(): Unit \ Assert =
        let b = board(0 :: 1 :: 2 :: 3 :: 2 :: 1 :: Nil, "0000" :: "1033" :: "0000" :: Nil, "...." :: "@=.*" :: "...." :: Nil);
        let lifted = World.actAll(b, Move.Right :: Move.Wait :: Move.Wait :: Nil, start(b));
        Assert.assertEq(expected = (3, Some(((2, 1), Set.empty(), Set#{(1, 1)}))),
            (World.standHeight(b, lifted, lifted#crab), placesAfter(b, Move.Right, lifted)))

    /// 面 1 の道で右へ 2 手: 高さ 1 のマスに立った手の後が潮位 2 なので流された。
    @Test
    def testCrabIsWashedAwayWhenItsCellFloods(): Unit \ Assert =
        let b = Fixtures.crossing();
        Assert.assertEq(expected = World.Phase.Washed, World.actAll(b, Move.Right :: Move.Right :: Nil, start(b))#phase)

    /// 流された後とクリアの後は、どの手も受けない。
    @Test
    def testNoMovesAfterTheCrabIsWashed(): Unit \ Assert =
        let b = Fixtures.crossing();
        let washed = World.actAll(b, Move.Right :: Move.Right :: Nil, start(b));
        Assert.assertEq(expected = None, placesAfter(b, Move.Wait, washed))

    /// 巻き貝のマスに入ると、その手の後に沈んでもクリア（潮位 0 → 1、巻き貝は縁の高さ 0）。
    @Test
    def testEnteringTheShellClearsEvenIfItFloods(): Unit \ Assert =
        let b = board(0 :: 1 :: Nil, "10" :: "11" :: Nil, "@*" :: ".." :: Nil);
        let next = World.actAll(b, Move.Right :: Nil, start(b));
        Assert.assertEq(expected = (World.Phase.Cleared, true), (next#phase, Tide.isSubmerged((1, 0), next#water, b)))

    // ══════════════════════════════════════════════════════
    // 押す表（設計書 2.5 の行ごと）
    // ══════════════════════════════════════════════════════

    /// 小石・押せる: 高さ 2 の小石を高さ 1 へ落とせる。ヤドカリは小石のいたマスへ進む。
    @Test
    def testPushPebbleDownAStep(): Unit \ Assert =
        let b = board(0 :: Nil, "2210" :: "2222" :: Nil, "@o.." :: "...*" :: Nil);
        Assert.assertEq(expected = Some(((1, 0), Set#{(2, 0)}, Set.empty())), placesAfter(b, Move.Right, start(b)))

    /// 小石・押せる: 押し先は沈んだマスでもよい（潮位 1 の盤の右上の高さ 0）。
    @Test
    def testPushPebbleIntoWater(): Unit \ Assert =
        let b = board(1 :: Nil, "22220" :: "22222" :: Nil, "..@o." :: "*...." :: Nil);
        Assert.assertEq(expected = Some(((3, 0), Set#{(4, 0)}, Set.empty())), placesAfter(b, Move.Right, start(b)))

    /// 小石・押せない: 押し先が盤の外・押し先に物（流木）・押し先が高い（登らせない）。どれも動かず手に数えない。
    @Test
    def testPebbleThatCannotBePushedBlocks(): Unit \ Assert =
        let edge = board(0 :: Nil, "222" :: "222" :: Nil, ".@o" :: "*.." :: Nil);
        let blocked = board(0 :: Nil, "2222" :: "2222" :: Nil, "@o=." :: "...*" :: Nil);
        let uphill = board(0 :: Nil, "2223" :: "2222" :: Nil, ".@o." :: "...*" :: Nil);
        Assert.assertEq(expected = (None, None, None),
            (placesAfter(edge, Move.Right, start(edge)), placesAfter(blocked, Move.Right, start(blocked)),
             placesAfter(uphill, Move.Right, start(uphill))))

    /// 浮いた流木・押し先が沈んでいて物が無い: 流木だけ 1 マス進み、ヤドカリはその場に残る（潮位 2・水路は高さ 0）。
    @Test
    def testPushFloatingDriftwoodAlongWater(): Unit \ Assert =
        let b = board(2 :: Nil, "20000" :: "22222" :: Nil, "@=..." :: "*...." :: Nil);
        Assert.assertEq(expected = Some(((0, 0), Set.empty(), Set#{(2, 0)})), placesAfter(b, Move.Right, start(b)))

    /// 浮いた流木・押せない（押し先が乾いた岩）: 乗る。流木の立つ高さは水面 2 で、高さ 2 から差 0。
    /// 押し先に小石があって押せず、高さ 3 から水面 1 の流木へは差 2 なので乗れもしない（潮位 1）。
    @Test
    def testRideFloatingDriftwoodThatCannotBePushed(): Unit \ Assert =
        let ride = board(2 :: Nil, "2022" :: "2222" :: Nil, "@=.." :: "...*" :: Nil);
        let low = board(1 :: Nil, "3000" :: "3333" :: Nil, "@=o." :: "...*" :: Nil);
        Assert.assertEq(expected = (Some(((1, 0), Set.empty(), Set#{(1, 0)})), None),
            (placesAfter(ride, Move.Right, start(ride)), placesAfter(low, Move.Right, start(low))))

    /// 着地した流木: 地面と同じ。押せず、そのマスへ歩いて乗る（潮位 0）。
    @Test
    def testLandedDriftwoodIsGround(): Unit \ Assert =
        let b = board(0 :: Nil, "2222" :: "2222" :: Nil, "@=.." :: "...*" :: Nil);
        Assert.assertEq(expected = Some(((1, 0), Set.empty(), Set#{(1, 0)})), placesAfter(b, Move.Right, start(b)))

    // ══════════════════════════════════════════════════════
    // 取り消し・やり直し・面の進行（World）
    // ══════════════════════════════════════════════════════

    /// 手 → 取り消しで、手の前の状態に戻る。
    @Test
    def testUndoRestoresThePreviousState(): Unit \ Assert =
        let w = Fixtures.world();
        Assert.assertEq(expected = World.toTuple(World.state(res(), w)), World.toTuple(World.state(res(), World.undo(res(), World.play(res(), Move.Wait, w)))))

    /// 動けなかった手（盤の外へ）は何も変えない: 手数は 0 のまま、取り消しの履歴も積まない。
    @Test
    def testBlockedMoveDoesNotCount(): Unit \ Assert =
        let w = World.play(res(), Move.Left, Fixtures.world());
        Assert.assertEq(expected = (0, Some(false)), (World.state(res(), w)#t, undoableOf(w)))

    /// 流された後も取り消しで戻れる。やり直しは面の初めを積むので、取り消しでやり直しの前へ戻れる。
    @Test
    def testUndoAfterWashedAndRestart(): Unit \ Assert =
        let washed = Fixtures.world() |> World.play(res(), Move.Right) |> World.play(res(), Move.Right);
        let restarted = World.restart(res(), washed);
        Assert.assertEq(expected = (World.Phase.Playing, 0, World.Phase.Washed),
            (World.state(res(), World.undo(res(), washed))#phase, World.state(res(), restarted)#t, World.state(res(), World.undo(res(), restarted))#phase))

    /// 最後の面をクリアして決定すると終わりの画面（既定の Doc は面 1 だけ。4 手待って引き潮の間に右へ 5 手）。
    @Test
    def testAdvanceAfterTheLastLevelEnds(): Unit \ Assert =
        let cleared = Fixtures.world() |> World.play(res(), Move.Wait) |> World.play(res(), Move.Wait) |> World.play(res(), Move.Wait)
            |> World.play(res(), Move.Wait) |> World.play(res(), Move.Right) |> World.play(res(), Move.Right) |> World.play(res(), Move.Right)
            |> World.play(res(), Move.Right) |> World.play(res(), Move.Right);
        Assert.assertEq(expected = (World.Phase.Cleared, World.ScreenKind.Ending),
            (World.state(res(), cleared)#phase, World.screenKindOf(World.advance(res(), cleared))))

    /// 貝殻: par 以下で 3・par + 幅 以下で 2・それより多いと 1（par 10・幅は rules の既定）。
    @Test
    def testShellsFollowParAndWidth(): Unit \ Assert =
        let rules = RulesDoc.defaults();
        let width = RulesDoc.rec(rules)#shellWidth;
        Assert.assertEq(expected = (3, 2, 1),
            (World.shellsFor(rules, 10, 10), World.shellsFor(rules, 10, 10 + width), World.shellsFor(rules, 10, 11 + width)))

    // ══════════════════════════════════════════════════════
    // 1 手の動き・題名の面選び
    // ══════════════════════════════════════════════════════

    /// 1 手の動きの途中で次の手が来ると、動きは前の手の終わり（前の手の後の状態）から始め直す。
    @Test
    def testNextMoveSkipsTheRunningMotionToItsEnd(): Unit \ Assert =
        let once = World.play(res(), Move.Wait, Fixtures.world());
        let twice = World.play(res(), Move.Wait, World.tick(0.1, once));
        Assert.assertEq(expected = Some((World.toTuple(World.state(res(), once)), 0.0)),
            World.sessionRecOf(twice) |> Option.map(s -> (World.toTuple(s#before), s#blend)))

    /// 動きは rules の tweenSeconds で終わりまで進む。
    @Test
    def testMotionEndsAfterTweenSeconds(): Unit \ Assert =
        let w = World.play(res(), Move.Wait, Fixtures.world());
        Assert.assertEq(expected = Some(1.0),
            World.sessionRecOf(World.tick(RulesDoc.rec(RulesDoc.defaults())#tweenSeconds, w)) |> Option.map(s -> s#blend))

    /// 題名の画面の面選びは、クリアしていない面の先へは進まない（既定の Doc は面 1 だけ）。
    @Test
    def testTitleSelectsOnlyOpenedLevels(): Unit \ Assert =
        let title = World.backToTitle(Fixtures.world());
        Assert.assertEq(expected = (0, 0), (World.levelOf(World.selectLevel(res(), 1, title)), World.levelOf(World.selectLevel(res(), -1, title))))

    // ══════════════════════════════════════════════════════
    // 面の Doc の差し替え（settleStages）・題名へ戻る
    // ══════════════════════════════════════════════════════

    /// 取り消しの履歴があるか（Play の外は None）。
    def undoableOf(w: World.World): Option[Bool] = World.sessionRecOf(w) |> Option.map(s -> Worldline.canUndo(s#line))

    /// 面の Doc を全部、Doc の解き方で解いて終わりの画面へ着いた World（読めない解き方があれば None）。
    def endingOf(r: Res.Res): Option[World.World] =
        LevelsDoc.rec(r#levels)#levels |> List.foldLeft((started, level) ->
            Option.flatMap(w -> World.movesOf(level#solution) |> Option.map(moves ->
                moves |> List.foldLeft((acc, move) -> World.play(r, move, acc), w) |> World.advance(r)), started),
            Some(World.enterLevel(r, 0, World.initial())))

    /// 遊んでいる面は、面の列が組み直されると初めから: Play のまま・手数 0・取り消しの履歴なし。
    @Test
    def testSettleStagesRestartsThePlayedLevel(): Unit \ Assert =
        let settled = World.settleStages(res(), World.play(res(), Move.Wait, Fixtures.world()));
        Assert.assertEq(expected = (World.ScreenKind.Play, 0, Some(false)),
            (World.screenKindOf(settled), World.state(res(), settled)#t, undoableOf(settled)))

    /// 題名で選んでいる面が面の列より後ろなら、最後の面に収まる（既定の Doc は面 1 だけ）。
    @Test
    def testSettleStagesKeepsTheTitleLevelInRange(): Unit \ Assert =
        let far = { screen = World.Screen.Title(5) | Fixtures.world() };
        Assert.assertEq(expected = (World.ScreenKind.Title, 0), (World.screenKindOf(World.settleStages(res(), far)), World.levelOf(World.settleStages(res(), far))))

    /// 終わりの画面で面の列が短くなると、面の番号だけ収まり、終えた状態とその時刻はそのまま。
    @Test
    def testSettleStagesInTheEndingKeepsTheFinishedState(): Unit \ Assert + Fs.FileRead =
        let full = Res.build(Controls.loadDocs());
        let ended = endingOf(full);
        let settled = ended |> Option.map(World.settleStages(res()));
        Assert.assertEq(
            expected = ended |> Option.map(e -> (World.ScreenKind.Ending, 0, World.toTuple(World.shownOf(full, e)#now), World.shownOf(full, e)#since)),
            settled |> Option.map(s -> (World.screenKindOf(s), World.levelOf(s), World.toTuple(World.shownOf(res(), s)#now), World.shownOf(res(), s)#since)))

    /// 終わりの画面から題名へ戻ると、最後の面を選んでいる。
    @Test
    def testBackToTitleFromTheEndingSelectsTheLastLevel(): Unit \ Assert + Fs.FileRead =
        let full = Res.build(Controls.loadDocs());
        Assert.assertEq(expected = Some((World.ScreenKind.Ending, World.ScreenKind.Title, Vector.length(full#stages) - 1)),
            endingOf(full) |> Option.map(ended -> {
                let back = World.backToTitle(ended);
                (World.screenKindOf(ended), World.screenKindOf(back), World.levelOf(back))
            }))
}
