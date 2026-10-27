// 1 手の規則（World）: 立つ高さ・行ける条件・押す表・流された・クリア・取り消し・やり直し・貝殻。
// 盤は格子で書く。満ち引きの表を 1 つの値にした盤（cycle = [L]）は潮位がいつも L。
mod TestRules {

    use fge::Worldline
    use Fixtures.{board, placesAfter}
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
        Assert.assertEq(expected = World.toTuple(World.state(w)), World.toTuple(World.state(World.undo(World.play(Move.Wait, w)))))

    /// 動けなかった手（盤の外へ）は何も変えない: 手数は 0 のまま、取り消しの履歴も積まない。
    @Test
    def testBlockedMoveDoesNotCount(): Unit \ Assert =
        let w = World.play(Move.Left, Fixtures.world());
        Assert.assertEq(expected = (0, false), (World.state(w)#t, Worldline.canUndo(w#line)))

    /// 流された後も取り消しで戻れる。やり直しは面の初めを積むので、取り消しでやり直しの前へ戻れる。
    @Test
    def testUndoAfterWashedAndRestart(): Unit \ Assert =
        let washed = Fixtures.world() |> World.play(Move.Right) |> World.play(Move.Right);
        let restarted = World.restart(washed);
        Assert.assertEq(expected = (World.Phase.Playing, 0, World.Phase.Washed),
            (World.state(World.undo(washed))#phase, World.state(restarted)#t, World.state(World.undo(restarted))#phase))

    /// 最後の面をクリアして決定すると終わりの画面（既定の Doc は面 1 だけ。4 手待って引き潮の間に右へ 5 手）。
    @Test
    def testAdvanceAfterTheLastLevelEnds(): Unit \ Assert =
        let cleared = Fixtures.world() |> World.play(Move.Wait) |> World.play(Move.Wait) |> World.play(Move.Wait)
            |> World.play(Move.Wait) |> World.play(Move.Right) |> World.play(Move.Right) |> World.play(Move.Right)
            |> World.play(Move.Right) |> World.play(Move.Right);
        Assert.assertEq(expected = (World.Phase.Cleared, World.Screen.Ending),
            (World.state(cleared)#phase, World.advance(cleared)#screen))

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
        let once = World.play(Move.Wait, Fixtures.world());
        let twice = World.play(Move.Wait, World.tick(0.1, once));
        Assert.assertEq(expected = (World.toTuple(World.state(once)), 0.0), (World.toTuple(twice#before), twice#blend))

    /// 動きは rules の tweenSeconds で終わりまで進む。
    @Test
    def testMotionEndsAfterTweenSeconds(): Unit \ Assert =
        let w = World.play(Move.Wait, Fixtures.world());
        Assert.assertEq(expected = 1.0, World.tick(RulesDoc.rec(RulesDoc.defaults())#tweenSeconds, w)#blend)

    /// 題名の画面の面選びは、クリアしていない面の先へは進まない（既定の Doc は面 1 だけ）。
    @Test
    def testTitleSelectsOnlyOpenedLevels(): Unit \ Assert =
        let title = World.withScreen(World.Screen.Title, Fixtures.world());
        Assert.assertEq(expected = (0, 0), (World.selectLevel(1, title)#level, World.selectLevel(-1, title)#level))
}
