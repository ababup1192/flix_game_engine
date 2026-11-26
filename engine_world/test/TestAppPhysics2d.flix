// App.addPhysics2d（物理だけのアキュムレータ・出来事の受け渡し・補間の割合）

mod TestAppPhysics2d {

    pub enum Play
    enum Halt { case Menu }

    type alias World = { physics = PhysicsWorld2d.PhysicsWorld2d, play = Clock.Clock[Play], paused = Bool,
                         log = Emit.Events[CollisionEvent2d.CollisionEvent2d], systemRuns = Int32 }

    def stepSeconds(): Float64 = 1.0 / 60.0

    /// 床と、その上 0.5 m の球（id 10）。
    def world0(): World = worldWith(stepSeconds())

    def worldWith(step: Float64): World =
        let physics = PhysicsWorld2d.empty(PhysicsWorld2d.settings(), step)
            |> PhysicsWorld2d.insert(1, RigidBody2d.fixed({ x = 0.0, y = 0.5 }, Collider2d.box(5.0, 0.5)))
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.5 }, Collider2d.circle(0.2)));
        { physics = physics, play = Clock.start(), paused = false, log = Emit.empty(), systemRuns = 0 }

    def appWith(fixedDt: Float64): App.App[World, {}] =
        App.make(worldWith(fixedDt))
            |> App.withFixedStep(fixedDt)
            |> App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w },
                              paceOf = w -> Clock.paceOf(if (w#paused) Clock.Run.Paused(Halt.Menu) else Clock.Run.Running) })
            |> App.addSystem((_, w) -> { systemRuns = w#systemRuns + 1 | w })
            |> App.addPhysics2d({ physicsOf = w -> w#physics, withPhysics = (p, w) -> { physics = p | w }, clockOf = w -> w#play,
                                  onEvents = (evs, w) -> { log = snd(Emit.collectInto(() -> List.forEach(Emit.emit, evs#collisions), w#log)) | w } })

    def app(): App.App[World, {}] = appWith(stepSeconds())

    def frameOf(dt: Float64): App.Frame = { dt = dt | App.emptyFrame() }

    /// 同じ dt のフレームを n 回流した (World, StepState)。
    def frames(n: Int32, dt: Float64, a: App.App[World, {}], start: (World, App.StepState)): (World, App.StepState) =
        List.range(0, n) |> List.foldLeft((acc, _) -> {
            let (w, s) = acc;
            let (w1, s1) = App.advanceFrame(a, frameOf(dt), s, w);
            (w1, s1)
        }, start)

    /// 1/60 秒のフレームを 600 回流すと、物理はちょうど 600 刻み進む
    @Test
    def testSixHundredFramesSixHundredSteps(): Unit \ Assert =
        let (w, _) = frames(600, 1.0 / 60.0, app(), (world0(), App.freshStepState()));
        Assert.assertEq(expected = 600i64, PhysicsWorld2d.stepCount(w#physics))

    /// 刻みの半分のフレームでは 2 コマに 1 刻み（刻み 0.02 秒・0.01 秒のフレーム 120 回で 60 刻み）
    @Test
    def testFastFramesStepEveryOtherFrame(): Unit \ Assert =
        let (w, _) = frames(120, 0.01, appWith(0.02), (worldWith(0.02), App.freshStepState()));
        Assert.assertEq(expected = 60i64, PhysicsWorld2d.stepCount(w#physics))

    /// 遊びの時計が止まっている間は、物理は進まない
    @Test
    def testPausedClockStopsPhysics(): Unit \ Assert =
        let (w, _) = frames(60, 1.0 / 60.0, app(), ({ paused = true | world0() }, App.freshStepState()));
        Assert.assertEq(expected = 0i64, PhysicsWorld2d.stepCount(w#physics))

    /// 遊びの時計が止まっている間も、系は回る（ポーズを閉じる入力を読める）
    @Test
    def testPausedClockKeepsSystemsRunning(): Unit \ Assert =
        let (w, _) = frames(60, 1.0 / 60.0, app(), ({ paused = true | world0() }, App.freshStepState()));
        Assert.assertEq(expected = 60, w#systemRuns)

    /// 1 フレームに 2 刻み回っても、出来事は 1 回ずつ Emit.Events に残る（Started が 1 つ）
    @Test
    def testTwoStepsPerFrameKeepEachEvent(): Unit \ Assert =
        let (w, _) = frames(20, 2.0 / 60.0, app(), (world0(), App.freshStepState()));
        let started = Emit.since(Emit.empty(), w#log) |> List.filterMap(CollisionEvent2d.startedPair);
        Assert.assertEq(expected = (1, 10) :: Nil, started)

    /// 処理落ちで 5 刻みを超える貯めは捨てる（1 秒のフレームでも 5 刻み）
    @Test
    def testLongFrameIsCappedAtFiveSteps(): Unit \ Assert =
        let (w, _) = frames(1, 1.0, app(), (world0(), App.freshStepState()));
        Assert.assertEq(expected = 5i64, PhysicsWorld2d.stepCount(w#physics))

    /// 半刻みの所で ViewCtx#physicsAlpha は 0.5
    @Test
    def testAlphaIsHalfAtHalfStep(): Unit \ Assert =
        let (_, s) = frames(1, 1.5 / 60.0, app(), (world0(), App.freshStepState()));
        Assert.assertTrue(Float64.abs(App.Internal.Physics.physicsAlphaOf(app(), s) - 0.5) < 1.0e-6)

    /// flow の rewind（実機の F8 の巻き戻しの記録）を流した後は、物理の貯めが 0 に戻る
    @Test
    def testFlowRewindResetsCarry(): Unit \ {Assert, Fs.FileRead} =
        let a = app() |> App.withFlow(Flow.emptyTable());
        let carry = match Flow.Parse.parseText(Flow.vocabOf(a, world0()), "body", "fps 40\nwait 5f\nrewind 2") {
            case Err(_) => -1i64
            case Ok(script) => match Flow.play(a, { design = Vec2.zero(), limit = 100 }, script, { world = world0(), state = App.freshStepState() }) {
                case Ok(outcome) => outcome#state#physicsCarry
                case Err(_) => -2i64
            }
        };
        Assert.assertEq(expected = 0i64, carry)

    // ── docs/physics.md の手本（同じ段の石が触れたら合わせる） ──

    type alias Jar = { physics = PhysicsWorld2d.PhysicsWorld2d, play = Clock.Clock[Play], paused = Bool, stones = Map[EntityId, Int32],
                       nextId = EntityId, hits = Emit.Events[CollisionEvent2d.CollisionEvent2d], seen = Emit.Events[CollisionEvent2d.CollisionEvent2d] }

    def stoneBody(at: Vec2.Vec2, rank: Int32): RigidBody2d.RigidBody2d =
        RigidBody2d.dynamic(at, Collider2d.circle(0.15 + 0.05 * Int32.toFloat64(rank)) |> Collider2d.withMaterial("stone"))

    def mergeTouches(_f: App.Frame, w: Jar): Jar =
        let fresh = Emit.since(w#seen, w#hits) |> List.filterMap(CollisionEvent2d.startedPair);
        fresh |> List.foldLeft((acc, pair) -> mergeIfSameRank(pair, acc), { seen = w#hits | w })

    def mergeIfSameRank(pair: (EntityId, EntityId), w: Jar): Jar =
        let (a, b) = pair;
        match (Map.get(a, w#stones), Map.get(b, w#stones), PhysicsWorld2d.positionOf(a, w#physics), PhysicsWorld2d.positionOf(b, w#physics)) {
            case (Some(ra), Some(rb), Some(pa), Some(pb)) if ra == rb =>
                let mid = { x = (pa#x + pb#x) / 2.0, y = (pa#y + pb#y) / 2.0 };
                let physics = w#physics |> PhysicsWorld2d.remove(a) |> PhysicsWorld2d.remove(b) |> PhysicsWorld2d.insert(w#nextId, stoneBody(mid, ra + 1));
                { physics = physics, stones = w#stones |> Map.remove(a) |> Map.remove(b) |> Map.insert(w#nextId, ra + 1), nextId = w#nextId + 1 | w }
            case _ => w
        }

    def jarApp(): App.App[Jar, {}] =
        let physics = PhysicsWorld2d.empty(PhysicsWorld2d.settings(), stepSeconds())
            |> PhysicsWorld2d.withMaterials(Map#{"stone" => { friction = 0.6, restitution = 0.1, density = 2.0 }})
            |> PhysicsWorld2d.insert(1, RigidBody2d.fixed({ x = 0.0, y = 0.5 }, Collider2d.box(5.0, 0.5)))
            |> PhysicsWorld2d.insert(10, stoneBody({ x = -0.15, y = -0.3 }, 0))
            |> PhysicsWorld2d.insert(11, stoneBody({ x = 0.15, y = -0.3 }, 0));
        App.make({ physics = physics, play = Clock.start(), paused = false, stones = Map#{10 => 0, 11 => 0}, nextId = 100,
                   hits = Emit.empty(), seen = Emit.empty() })
            |> App.withFixedStep(1.0 / 60.0)
            |> App.addSystem(mergeTouches)
            |> App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w },
                              paceOf = w -> Clock.paceOf(if (w#paused) Clock.Run.Paused(Halt.Menu) else Clock.Run.Running) })
            |> App.addPhysics2d({ physicsOf = w -> w#physics, withPhysics = (p, w) -> { physics = p | w }, clockOf = w -> w#play,
                                  onEvents = (evs, w) -> { hits = snd(Emit.collectInto(() -> List.forEach(Emit.emit, evs#collisions), w#hits)) | w } })

    /// 並べて落とした同じ段の石 2 つは、1 秒で 1 つ上の段の石 1 つになる
    @Test
    def testMergeExample(): Unit \ Assert =
        let a = jarApp();
        let w1 = List.range(0, 60) |> List.foldLeft((acc, _) -> {
            let (w, s) = acc;
            App.advanceFrame(a, frameOf(1.0 / 60.0), s, w)
        }, (App.rec(a)#init(Vec2.zero()), App.freshStepState())) |> fst;
        Assert.assertEq(expected = 1 :: Nil, Map.valuesOf(w1#stones))

    /// 貯めは整数のナノ秒で数える（1/60 秒の 3 回でちょうど 3 刻み・端数は 1 ns 以下）
    @Test
    def testStepsForCountsWholeNanos(): Unit \ Assert =
        let stepNanos = App.Internal.Physics.nanosOf(1.0 / 60.0);
        let (steps, rest) = App.Internal.Physics.stepsFor(0i64, stepNanos * 3i64, stepNanos);
        Assert.assertEq(expected = (3, 0i64), (steps, rest))
}
