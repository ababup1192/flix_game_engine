// 性質テスト: 種で決まるでたらめなキー操作を App.trace の道（PropertyTest・画面なし）に流し、
// どう遊んでも崩れない決まりを見る。升の数は置いたミノと消した行だけで決まる・行を消したフレームだけ
// 消した音が 1 回鳴る・固めたフレームだけ固めた音が 1 回鳴る。
// 盤は下 4 行を 1 列だけ空けて始める（でたらめに落としても行が消える場面が早く来る）。
mod TestTrace {

    use fge::{App, Emit, Flow, PropertyTest, ShaderDoc}
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq {
        case Left, Right, Ccw, Cw, Drop, Soft
    }

    def keyOf(role: Role, _w: World.World): Key = match role {
        case Role.Left  => Key.Left
        case Role.Right => Key.Right
        case Role.Ccw   => Key.Z
        case Role.Cw    => Key.X
        case Role.Drop  => Key.Space
        case Role.Soft  => Key.Down
    }

    def setup(): PropertyTest.Setup[Role, World.World] =
        { keyOf = keyOf, viewport = { x = 256.0, y = 352.0 }, dt = 1.0 / 60.0 }

    /// 種 12 個 × 600 入力。押しっぱなしはそっと落とすだけ。
    def cases(): PropertyTest.Cases[Role] =
        { seeds = 12, length = 600,
          spec = { taps = List#{Role.Left, Role.Right, Role.Ccw, Role.Cw, Role.Drop},
                   holds = List#{Role.Soft}, idle = 4 | PropertyTest.emptySpec() } }

    /// 実機（Main）と同じ更新と音の部品だけを繋いだ App。
    def app(): App.App[World.World, {}] =
        App.make(start()) |> App.addSystem(Controls.step) |> App.withAudio(Controls.sounds)

    def start(): World.World =
        let w = World.initial({ doc = RulesDoc.defaults(), theme = ThemeDoc.defaults(),
                                shader = ShaderDoc.demoSurface() });
        let cells = List.range(World.rows() - 4, World.rows()) |> List.flatMap(r ->
            List.range(0, World.cols()) |> List.filter(c -> c != 4) |> List.map(c -> ((c, r), World.Kind.I)));
        { board = List.foldLeft((b, e) -> { let (c, k) = e; Map.insert(c, k, b) }, Map.empty(), cells) | w }

    /// そのフレームに溜まった出来事（音と同じ読み方）。
    def eventsOf(step: App.TraceStep[World.World]): List[World.Event] =
        Emit.since(step#before#events, step#after#events)

    def lockedIn(step: App.TraceStep[World.World]): Int32 =
        List.count(e -> e == World.Event.Locked, eventsOf(step))

    def clearedIn(step: App.TraceStep[World.World]): Int32 = step#after#lines - step#before#lines

    def heard(sound: Controls.Sound, step: App.TraceStep[World.World]): Int32 =
        List.count(name -> name == Controls.soundName(sound), step#sounds)

    def clearSoundsIn(step: App.TraceStep[World.World]): Int32 =
        heard(Controls.Sound.LineA, step) + heard(Controls.Sound.LineB, step) + heard(Controls.Sound.Tetris, step)

    /// GAME OVER から仕切り直したフレーム（盤と行数を作り直すので、数の決まりの外）。
    def restartedIn(step: App.TraceStep[World.World]): Bool =
        step#before#phase == World.Phase.GameOver and step#after#phase != World.Phase.GameOver

    /// 升の数 = 前の升 + 固めたミノ × 4 − 消した行 × 列の数。
    @Test
    def testCellsFollowLockedPiecesAndClearedRows(): Unit \ Assert =
        let rule = (step: App.TraceStep[World.World]) -> {
            let wanted = Map.size(step#before#board) + 4 * lockedIn(step) - World.cols() * clearedIn(step);
            let got = Map.size(step#after#board);
            if (restartedIn(step) or got == wanted) None
            else Some("升 ${got}（欲しいのは ${wanted}: 固めた ${lockedIn(step)}・消した行 ${clearedIn(step)}）")
        };
        Assert.assertEq(expected = None, PropertyTest.forAll(app(), setup(), cases(), start(), rule))

    /// 行を消したフレームだけ、消した音がちょうど 1 回鳴る。固めたフレームだけ、固めた音が 1 回鳴る。
    @Test
    def testOneSoundPerLockAndClear(): Unit \ Assert =
        let rule = (step: App.TraceStep[World.World]) -> {
            let wanted = (Int32.min(1, lockedIn(step)), Int32.min(1, clearedIn(step)));
            let got = (heard(Controls.Sound.Lock, step), clearSoundsIn(step));
            if (restartedIn(step) or got == wanted) None
            else Some("固めた音・消した音が ${got}（欲しいのは ${wanted}）")
        };
        Assert.assertEq(expected = None, PropertyTest.forAll(app(), setup(), cases(), start(), rule))

    /// /step と同じ flow: 落ちるのを待って叩きつけ、左へ 1 マス寄せてもう一度叩きつける。
    def stepFlow(): String =
        "ready off\nwait 10f\ntap Space\nwait 10f\ntap Left\nwait 5f\ntap Space\nwait 30f"

    /// 同じ Frame の列を App.trace と /step の中身（Flow.play）へ流すと、盤・点・音が同じ
    /// （どちらも App.traceFrame の 1 本を通る。/step は前は固定刻みと時計を見ずに系を直に呼んでいた）。
    /// trace に渡す Frame は、Flow.play が流した Frame をそのまま使う。
    @Test
    def testStepCoreMatchesTrace(): Unit \ Assert + Fs.FileRead =
        let script = match Flow.Parse.parseText(Flow.vocabOf(app(), start()), "body", stepFlow()) {
            case Ok(parsed) => parsed
            case Err(problems) => bug!(Flow.Parse.problemsText(problems))
        };
        let played = match Flow.play(app(), { design = setup()#viewport, limit = 1000 }, script,
                                     { world = start(), state = App.freshStepState() }) {
            case Ok(outcome)  => outcome
            case Err(failure) => bug!(failure#why)
        };
        let traced = App.trace(app(), played#frames |> List.map(entry -> entry#step#frame), start());
        let last = traced |> List.last |> Option.map(step -> step#after) |> Option.getWithDefault(start());
        Assert.assertEq(expected = (last#board, last#score, List.flatMap(step -> step#sounds, traced)),
                        (played#last#board, played#last#score, List.flatMap(entry -> entry#step#sounds, played#frames)))

    /// 上の決まりが空振りでないこと: どれかの種の列で、固めたフレームも行を消したフレームもある。
    @Test
    def testSomeSeedLocksAndClears(): Unit \ Assert =
        let stepsOf = seed -> PropertyTest.traceOf(app(), setup(), PropertyTest.generate(seed, cases()#length, cases()#spec), start());
        let seeds = List.range(1, cases()#seeds + 1) |> List.map(Int32.toInt64);
        Assert.assertEq(expected = (true, true),
            (List.exists(seed -> List.exists(step -> lockedIn(step) > 0, stepsOf(seed)), seeds),
             List.exists(seed -> List.exists(step -> clearedIn(step) > 0, stepsOf(seed)), seeds)))
}
