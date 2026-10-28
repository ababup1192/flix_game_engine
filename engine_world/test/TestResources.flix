// TestResources — 描く元と World の組: World だけを替える口は描く元をそのまま渡し、
// 読み直しの行は新しい描く元で World を収め、始まり・出力の持ち上げは World の側だけを見る。
mod TestResources {

    /// 描く元 = 倍率、World = 数。
    def pair(): Resources.With[Int32, Int32] = Resources.of(10, 1)

    @Test
    def testMapWorldKeepsResources(): Unit \ Assert =
        Assert.assertEq(expected = 10, Resources.mapWorld((res, w) -> res + w, pair())#resources)

    @Test
    def testMapWorldReadsResources(): Unit \ Assert =
        Assert.assertEq(expected = 11, Resources.mapWorld((res, w) -> res + w, pair())#world)

    @Test
    def testReadPassesBoth(): Unit \ Assert =
        Assert.assertEq(expected = (10, 1), Resources.read((res, w) -> (res, w), pair()))

    /// 読み直しの行は reload の後の描く元で settle を呼ぶ（10 → 20 にしてから World に足す）。
    @Test
    def testReloadRowSettlesWithNewResources(): Unit \ {Assert, IO} =
        let row = Resources.reloadRow("scale", "a.scale.json", res -> checked_ecast(res * 2), (res, w) -> res + w);
        let got = run { row#reload(pair()) } with Fs.FileRead.runWithIO;
        Assert.assertEq(expected = 21, got#world)

    @Test
    def testReloadUnnamedRowDoesNotNameItself(): Unit \ Assert =
        let row = Resources.reloadUnnamedRow("a.scale.json", res -> checked_ecast(res), (_, w) -> w);
        Assert.assertEq(expected = None, row#docId)

    /// 始まりの build は描く元を読み、World だけを替える。
    @Test
    def testLiftStartBuildsWorldFromResources(): Unit \ Assert =
        let start = Resources.liftStart({ name = "s", doc = "", args = Map.empty(), build = (res, w, _) -> Ok(res * w) });
        Assert.assertEq(expected = Ok(10), start#build(pair(), Map.empty()) |> Result.map(h -> h#world))

    @Test
    def testLiftStartPassesBuildError(): Unit \ Assert =
        let start = Resources.liftStart({ name = "s", doc = "", args = Map.empty(), build = (_, _, _) -> (Err("no level"): Result[String, Int32]) });
        Assert.assertEq(expected = Err("no level"), start#build(pair(), Map.empty()) |> Result.map(h -> h#world))

    // ── 時計（World の欄の時計を App が進める）──

    pub enum Play

    enum Halt { case Menu }

    /// 描く元 = 進めるか、World = 時計。
    def clocked(): App.App[Resources.With[Bool, Clock.Clock[Play]], {}] =
        App.make(Resources.of(true, Clock.start()))
            |> Resources.addClock({ clockOf = c -> c, withClock = (c, _) -> c,
                                    paceOf = (running, _) -> Clock.paceOf(if (running) Clock.Run.Running else Clock.Run.Paused(Halt.Menu)) })

    @Test
    def testAddClockAdvancesWorldClock(): Unit \ Assert =
        let ticked = App.tickClocks(clocked(), 0.5, Resources.of(true, Clock.start()));
        Assert.assertEq(expected = 0.5, Clock.secondsOf(Clock.nowOf(ticked#world)))

    @Test
    def testAddClockPaceReadsResources(): Unit \ Assert =
        let ticked = App.tickClocks(clocked(), 0.5, Resources.of(false, Clock.start()));
        Assert.assertEq(expected = 0.0, Clock.secondsOf(Clock.nowOf(ticked#world)))

    @Test
    def testLiftOutputKeysByWorld(): Unit \ Assert =
        let output = Resources.liftOutput({ keyOf = (w: Int32) -> Int32.toString(w), write = _ -> checked_ecast(()), onJump = App.OnJump.Skip });
        Assert.assertEq(expected = "1", output#keyOf(pair()))
}
