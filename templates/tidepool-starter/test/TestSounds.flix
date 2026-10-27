// 音: 出来事ごとに正しい音が 1 つ鳴る（World が溜めた出来事 → Controls.sounds）。潮の音は満ち切り・引き切りの手だけ。
// 盤の手は面 1（Fixtures.world・満ち引きは rules の既定 0 1 2 3 2 1）か、格子で書いた小さな盤で指す。
mod TestSounds {

    use Fixtures.board
    use World.Move

    /// w に f を当てたフレームで鳴る音。
    def heard(f: World.World -> World.World, w: World.World): List[String] =
        Controls.sounds({ before = w, after = f(w) })

    /// 盤 b の初めから move を 1 手指した時の出来事（動けなければ None）。
    def eventsOfMove(b: Board.Board, move: Move): Option[List[World.Event]] =
        World.act(b, move, World.startOf(b)) |> Option.map(next -> World.eventsOf(b, World.startOf(b), next))

    def wait(w: World.World): World.World = World.play(Move.Wait, w)

    /// 高さ 0 のマスへは砂、高さ 1 のマスへは岩の足音。潮位がいつも 0 の盤なので潮の音は混ざらない。
    @Test
    def testStepSoundFollowsTheGround(): Unit \ Assert =
        let sand = board(0 :: Nil, "0000" :: Nil, "@..*" :: Nil);
        let rock = board(0 :: Nil, "1111" :: Nil, "@..*" :: Nil);
        Assert.assertEq(expected = (Some(World.Event.WalkedOnSand :: Nil), Some(World.Event.WalkedOnRock :: Nil)),
            (eventsOfMove(sand, Move.Right), eventsOfMove(rock, Move.Right)))

    /// 小石を押した手は押す音だけ（ヤドカリも動くが足音は重ねない）。乾いた流木のマスへ乗った手は流木の音だけ。
    @Test
    def testPushAndDriftwoodReplaceTheStep(): Unit \ Assert =
        let pebble = board(0 :: Nil, "0000" :: Nil, "@o.*" :: Nil);
        let driftwood = board(0 :: 1 :: 2 :: 3 :: 2 :: 1 :: Nil, "0000" :: "1033" :: "0000" :: Nil, "...." :: "@=.*" :: "...." :: Nil);
        Assert.assertEq(expected = (Some(World.Event.PushedPebble :: Nil), Some(World.Event.MovedDriftwood :: Nil)),
            (eventsOfMove(pebble, Move.Right), eventsOfMove(driftwood, Move.Right)))

    /// 面 1 で 6 手待つ: 潮位 1 2 3 2 1 0 のうち、3 に着いた 3 手目に満ち切った音、0 に戻った 6 手目に引き切った音。ほかの手は無音。
    @Test
    def testTideSoundsOnlyAtTheTurn(): Unit \ Assert =
        let w0 = Fixtures.world();
        Assert.assertEq(expected = (Nil, Nil, "tide_high" :: Nil, Nil, Nil, "tide_low" :: Nil),
            (heard(wait, w0), heard(wait, w0 |> wait), heard(wait, w0 |> wait |> wait),
             heard(wait, w0 |> wait |> wait |> wait), heard(wait, w0 |> wait |> wait |> wait |> wait),
             heard(wait, w0 |> wait |> wait |> wait |> wait |> wait)))

    /// 面 1 で岩を 1 歩は岩の足音。もう 1 歩で沈むマスへ下りると流された音だけ。4 手待って右へ 5 歩の最後は巻き貝のクリアの音だけ。
    @Test
    def testWalkWashedAndClearEachPlayOneSound(): Unit \ Assert =
        let w0 = Fixtures.world();
        let right = World.play(Move.Right);
        let nearGoal = w0 |> wait |> wait |> wait |> wait |> right |> right |> right |> right;
        Assert.assertEq(expected = ("step_rock" :: Nil, "washed" :: Nil, "clear" :: Nil),
            (heard(right, w0), heard(right, right(w0)), heard(right, nearGoal)))

    /// 取り消し・やり直しは戻す音。戻す手が無い取り消しは無音。題名から面へ入るのは選ぶ音。
    @Test
    def testUndoRestartAndEnterSounds(): Unit \ Assert =
        let w0 = Fixtures.world();
        let title = World.withScreen(World.Screen.Title, w0);
        Assert.assertEq(expected = ("undo" :: Nil, "undo" :: Nil, Nil, "select" :: Nil),
            (heard(World.undo, wait(w0)), heard(World.restart, wait(w0)), heard(World.undo, w0), heard(World.enterLevel(0), title)))
}
