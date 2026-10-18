// Emit のテスト。出来事は出た順にそのまま集まること、World に溜めた出来事を audio が前後の差で読むと
// 固定刻み（withFixedStep）でもどの刻みの出来事もちょうど 1 回ずつ読まれること、
// 規則が World を作り直しても出来事を落とさないことを見る。

mod TestEmit {

    /// 刻みごとに 1 つ出来事（何回目の刻みか）を出す World。
    type alias Ticker = { ticks = Int32, events = Emit.Events[Int32] }

    def ticker(): Ticker = { ticks = 0, events = Emit.empty() }

    def tick(w: Ticker): Ticker \ Emit[Int32] =
        Emit.emit(w#ticks + 1);
        { ticks = w#ticks + 1 | w }

    /// 実機と同じ形: 系が collectInto で溜め、audio が前後の差を読む。刻みは 1/60 秒。
    def tickerApp(): App.App[Ticker, {}] =
        App.make(ticker())
            |> App.withFixedStep(1.0 / 60.0)
            |> App.addSystem((_frame, w) -> {
                let (next, events) = Emit.collectInto(() -> tick(w), w#events);
                { events = events | next }
            })
            |> App.withAudio(ws -> Emit.since(ws#before#events, ws#after#events) |> List.map(Int32.toString))

    /// フレームの長さだけを変える入力（刻み 1/60 より短い = 刻み 0 回・長い = 2 回以上）。
    def frameLengths(): PropertyTest.Cases[Int32] =
        { seeds = 20, length = 200,
          spec = { idle = 1, dts = List#{0.004, 0.009, 1.0 / 60.0, 0.03, 0.05, 0.2} | PropertyTest.emptySpec() } }

    def setup(): PropertyTest.Setup[Int32, Ticker] =
        { keyOf = (_role, _w) -> GameEngine.Key.Z, viewport = { x = 320.0, y = 240.0 }, dt = 1.0 / 60.0 }

    /// そのフレームで回った刻みの番号（before の次から after まで）の名前。
    def ticksOf(step: App.TraceStep[Ticker]): List[String] =
        List.range(step#before#ticks + 1, step#after#ticks + 1) |> List.map(Int32.toString)

    // ══════════════════════════════════════════════════════
    // collect
    // ══════════════════════════════════════════════════════

    /// 出た順に並び、同じ出来事が 2 回出れば 2 回とも残る。戻り値はそのまま隣に出る。
    @Test
    def testCollectKeepsOrderAndRepeats(): Unit \ Assert =
        let collected = Emit.collect(() -> {
            Emit.emit("lock");
            Emit.emit("clear");
            Emit.emit("lock");
            10
        });
        Assert.assertEq(expected = (10, List#{"lock", "clear", "lock"}), collected)

    // ══════════════════════════════════════════════════════
    // 固定刻みで溜めて読む
    // ══════════════════════════════════════════════════════

    /// どんなフレームの長さの並びでも、各フレームで聞こえるのはそのフレームで回った刻みの出来事だけ
    /// （刻み 0 回なら何も鳴らない・2 回以上なら全部の刻みの分が出た順に鳴る）。
    @Test
    def testEveryStepIsHeardOnceInItsFrame(): Unit \ Assert =
        let rule = (step: App.TraceStep[Ticker]) ->
            if (step#sounds == ticksOf(step)) None
            else Some("聞こえたのは ${step#sounds}・回った刻みは ${ticksOf(step)}");
        Assert.assertEq(expected = None, PropertyTest.forAll(tickerApp(), setup(), frameLengths(), ticker(), rule))

    /// 上の決まりが空振りでないこと: 刻み 0 回のフレームも、2 回以上のフレームも流れている。
    @Test
    def testFrameLengthsCoverZeroAndManySteps(): Unit \ Assert =
        let steps = PropertyTest.traceOf(tickerApp(), setup(),
            PropertyTest.generate(1i64, 200, frameLengths()#spec), ticker());
        let substeps = steps |> List.map(step -> step#after#ticks - step#before#ticks);
        Assert.assertEq(expected = (true, true),
            (List.exists(n -> n == 0, substeps), List.exists(n -> n >= 2, substeps)))

    /// 規則が World を作り直した刻み（ゲームの仕切り直し）でも、系が collectInto の戻りで events を
    /// 上書きするので、その刻みの出来事は読まれる。
    @Test
    def testRestartInsideRulesKeepsItsEvents(): Unit \ Assert =
        let (_, seen) = Emit.collectInto(() -> Emit.emit(1), Emit.empty());
        let before = { events = seen | ticker() };
        let (next, events) = Emit.collectInto(() -> { Emit.emit(9); ticker() }, before#events);
        let after = { events = events | next };
        Assert.assertEq(expected = List#{9}, Emit.since(before#events, after#events))

    /// 刻みを回さないフレーム（同じ溜めを前後に渡す）は何も読まない。
    @Test
    def testSinceSameEventsIsEmpty(): Unit \ Assert =
        let (_, events) = Emit.collectInto(() -> Emit.emit(1), Emit.empty());
        Assert.assertEq(expected = Nil, Emit.since(events, events))
}
