// 3D の描き手の 1 コマの数と CPU の区間（Render3d.Counts）。GL を呼ばずに State だけで決まる所。
mod Render3d.TestCounts {
    import java.lang.System
    use Render3d.Counts.{Counter, Phase}

    def freshState(): Render3d.State \ IO = Render3d.fresh({ megabytes = 64, count = 64 }, Render3d.DrawMode.Instanced)

    @Test
    def testNewCountersStartAtZero(): Unit \ {Assert, IO} =
        let c = Render3d.Counts.takeCounts(freshState());
        Assert.assertEq(expected = (0, 0, 0, 0, 0, 0, 0, Nil),
                        (c#meshUploads, c#meshEvictions, c#texture3dUploads, c#mipCopies, List.length(c#materialBuilds), c#jointUploads, c#targetRebuilds, c#cpuPhases))

    @Test
    def testCountedValuesAreTaken(): Unit \ {Assert, IO} =
        let s = freshState();
        Render3d.Counts.count(s, Counter.JointUploads, 3);
        Render3d.Counts.count(s, Counter.MipCopies, 1);
        Render3d.Counts.countDrawCall(s);
        let c = Render3d.Counts.takeCounts(s);
        Assert.assertEq(expected = (3, 1, 1), (c#jointUploads, c#mipCopies, c#drawCalls))

    @Test
    def testTakeCountsResetsToZero(): Unit \ {Assert, IO} =
        let s = freshState();
        Render3d.Counts.count(s, Counter.MeshUploads, 2);
        Render3d.Counts.timed(s, Phase.Draw, () -> spin(1000i64));
        discard Render3d.Counts.takeCounts(s);
        let c = Render3d.Counts.takeCounts(s);
        Assert.assertEq(expected = (0, Nil), (c#meshUploads, c#cpuPhases))

    @Test
    def testNestedPhaseIsNotCountedTwice(): Unit \ {Assert, IO} =
        let s = freshState();
        Render3d.Counts.timed(s, Phase.Draw, () -> Render3d.Counts.timed(s, Phase.Split, () -> spin(2000000i64)));
        let c = Render3d.Counts.takeCounts(s);
        let ns = (name: String) -> List.find(p -> fst(p) == name, c#cpuPhases) |> Option.map(snd) |> Option.getWithDefault(0i64);
        Assert.assertTrue(ns("split") >= 2000000i64 and ns("draw") < ns("split"))

    @Test
    def testMaterialBuildsAreTakenInOrder(): Unit \ {Assert, IO} =
        let s = freshState();
        Render3d.Counts.noteMaterialBuild(s, "a", FrameDiagnostics.BuildReason.First);
        Render3d.Counts.noteMaterialBuild(s, "b", FrameDiagnostics.BuildReason.First);
        let c = Render3d.Counts.takeCounts(s);
        Assert.assertEq(expected = "a" :: "b" :: Nil, c#materialBuilds |> List.map(b -> b#name))

    @Test
    def testMaterialBuildsResetAfterTake(): Unit \ {Assert, IO} =
        let s = freshState();
        Render3d.Counts.noteMaterialBuild(s, "a", FrameDiagnostics.BuildReason.First);
        discard Render3d.Counts.takeCounts(s);
        Assert.assertEq(expected = 0, List.length(Render3d.Counts.takeCounts(s)#materialBuilds))

    /// ns ナノ秒以上を過ごす。
    def spin(ns: Int64): Unit \ IO =
        spinUntil(System.nanoTime() + ns)

    def spinUntil(deadline: Int64): Unit \ IO =
        if (System.nanoTime() >= deadline) () else spinUntil(deadline)
}
