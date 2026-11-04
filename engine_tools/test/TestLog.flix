// 何を守るか（LogCapture を使うので engine_tools のテストに置く）: 純粋な関数の中から *Then の口で知らせた行が、本当に stderr へ出ること
// （`let _ = Log.warn(..)` は Flix が呼び出しごと消すので、出た文面まで確かめる）と、
// LogCapture.capture が知らせた行を出た順に集め、stderr へは出さないこと（出ればテストの実行器がこのテストを FAIL にする）。
mod TestLog {

    def decodeWithWarning(n: Int32): Int32 =
        if (n < 0) Log.fellBackThen("probe", "n=${n}", "0", "負の数です", 0) else n

    @Test
    def warnThenPrintsFromPureCode(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (7, "probe: 1 行" :: Nil), LogCapture.capture(() -> Log.warnThen("probe: 1 行", 7)))

    @Test
    def fellBackThenUsesTheFixedSentence(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0, "probe fail-open: n=-3 を0に替えました — 負の数です" :: Nil), LogCapture.capture(() -> decodeWithWarning(-3)))

    @Test
    def warnAllThenPrintsEveryLineInOrderAndNothingWhenEmpty(): Unit \ {Assert, IO} =
        let (_, lines) = LogCapture.capture(() -> Log.warnAllThen("probe-a" :: "probe-b" :: Nil, ()));
        let (_, quiet) = LogCapture.capture(() -> Log.warnAllThen(Nil, 1));
        Assert.assertEq(expected = ("probe-a" :: "probe-b" :: Nil, Nil), (lines, quiet))

    @Test
    def captureOfQuietCodeKeepsTheValueAndCollectsNothing(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (5, Nil), LogCapture.capture(() -> decodeWithWarning(5)))

    /// せん断のある world のノードは外接箱に倒し、ノードの名前を入れた 1 行を知らせる。
    @Test
    def testBoxOfNodeOnShearWarnsWithNodeName(): Unit \ {Assert, IO} =
        let shear = Mat4.ofLinearRows(Vec3.v3(1.0, 1.0, 0.0), Vec3.v3(0.0, 1.0, 0.0), Vec3.v3(0.0, 0.0, 1.0));
        let node = { name = "COL_bent", parent = None, local = shear, world = shear, localBounds = Some({ min = Vec3.v3(-1.0, -1.0, -1.0), max = Vec3.v3(1.0, 1.0, 1.0) }), parts = Nil };
        let (box, lines) = LogCapture.capture(() -> CollisionShape3d.boxOfNode(node));
        Assert.assertEq(expected = (Some((2000, 1000, 1000)), 1, true),
            (box |> Option.map(b -> (Num.roundInt(b#half#x * 1000.0), Num.roundInt(b#half#y * 1000.0), Num.roundInt(b#half#z * 1000.0))),
             List.length(lines), List.exists(String.contains(substr = "COL_bent"), lines)))
}
