// 性質テスト: 種で決まるでたらめなキー操作を App.trace の道（PropertyTest・画面なし）に流し、
// どう遊んでも崩れない決まりを見る。先読み（待ったら）の答えと、実際に待った後が一致する。
// 1 フレームの音は動き 1 つと潮 1 つまで・潮の音は手数が 1 進んだフレームだけ。
mod TestTrace {

    use fge::{App, PropertyTest, Resources}
    use fge::GameEngine.Key

    def setup(): PropertyTest.Setup[Key, Run] =
        { keyOf = (key, _) -> key, viewport = { x = World.width(), y = World.height() }, dt = 1.0 / 60.0 }

    /// 種 12 個 × 400 入力。矢印・待つ（Space）・取り消し（Z）・やり直し（R）。
    def cases(): PropertyTest.Cases[Key] =
        { seeds = 12, length = 400,
          spec = { taps = List#{Key.Left, Key.Right, Key.Up, Key.Down, Key.Space, Key.Space, Key.Z, Key.R},
                   idle = 2 | PropertyTest.emptySpec() } }

    /// App の w（描く元と World の組）。
    type alias Run = Resources.With[Res.Res, World.World]

    def app(): App.App[Run, {}] =
        App.make(start()) |> App.addSystem(Resources.system(Controls.step))
            |> App.withAudio(ws -> Controls.sounds({ before = ws#before#world, after = ws#after#world }))

    def start(): Run = Resources.of(Fixtures.res(), Fixtures.world())

    def stateOf(h: Run): World.State = Resources.read(World.state, h)

    /// 待ったフレーム（ヤドカリも小石も流木も動かず、手数が 1 進んだ）。
    def waitedIn(step: App.TraceStep[Run]): Bool =
        let (before, after) = (stateOf(step#before), stateOf(step#after));
        after#t == before#t + 1 and after#crab == before#crab and after#pebbles == before#pebbles
            and after#driftwood == before#driftwood

    /// 待つ前の先読み（沈むマス・流されるか）は、実際に待った後の盤と同じ。
    @Test
    def testForecastMatchesWhatWaitingDoes(): Unit \ Assert =
        let rule = (step: App.TraceStep[Run]) -> {
            let b = Resources.read(World.board, step#before);
            let forecast = World.forecastOf(b, stateOf(step#before));
            let after = stateOf(step#after);
            let flooded = Set.difference(World.submergedCells(b, after), World.submergedCells(b, stateOf(step#before)));
            let got = (forecast#crabWashed, forecast#flooding);
            let wanted = (after#phase == World.Phase.Washed, flooded);
            if (not waitedIn(step) or got == wanted) None
            else Some("先読み ${got}・待った後 ${wanted}")
        };
        Assert.assertEq(expected = None, PropertyTest.forAll(app(), setup(), cases(), start(), rule))

    /// そのフレームに鳴った音のうち names の物の数。
    def heardOf(names: List[String], step: App.TraceStep[Run]): Int32 =
        List.count(name -> List.memberOf(name, names), step#sounds)

    /// どう遊んでも、1 フレームに鳴る動きの音（歩く・押す・流木）と潮の音（満ち切った・引き切った）は 1 つずつまで。
    /// 潮の音は手数がちょうど 1 進んだフレーム（手を指した時）だけで、取り消し・やり直しでは鳴らない。
    @Test
    def testAtMostOneMoveAndOneTideSoundPerFrame(): Unit \ Assert =
        let rule = (step: App.TraceStep[Run]) -> {
            let moves = heardOf("step_sand" :: "step_rock" :: "push" :: "driftwood" :: Nil, step);
            let tides = heardOf("tide_high" :: "tide_low" :: Nil, step);
            let played = stateOf(step#after)#t == stateOf(step#before)#t + 1;
            if (moves <= 1 and tides <= 1 and (tides == 0 or played)) None
            else Some("動きの音 ${moves}・潮の音 ${tides}・手を指した ${played}: ${step#sounds}")
        };
        Assert.assertEq(expected = None, PropertyTest.forAll(app(), setup(), cases(), start(), rule))

    /// 上の決まりが空振りでないこと: どれかの種の列で、待って流されたフレームがある。
    @Test
    def testSomeSeedWaitsIntoTheWater(): Unit \ Assert =
        let stepsOf = seed -> PropertyTest.traceOf(app(), setup(), PropertyTest.generate(seed, cases()#length, cases()#spec), start());
        let washedByWaiting = (step: App.TraceStep[Run]) -> waitedIn(step) and stateOf(step#after)#phase == World.Phase.Washed;
        Assert.assertEq(expected = true,
            List.range(1, cases()#seeds + 1) |> List.exists(seed -> List.exists(washedByWaiting, stepsOf(Int32.toInt64(seed)))))
}
