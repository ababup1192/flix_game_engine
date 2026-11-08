// LoadProgress の知らせの並び・結果の並び・例外を、知らせを集める handler の中で確かめる。
// 並列の handler（LwjglLoad・HeadlessLoad）の決まりは、それぞれの層のテストが LoadProgress.Conformance で確かめる。
mod TestLoadProgress {
    import java.lang.{RuntimeException, System, Thread}
    import java.util.concurrent.atomic.AtomicBoolean
    import java.util.concurrent.{Callable, Executors}

    /// f を流し、届いた知らせを (phase, done, total) の並びで結果と一緒に返す。
    pub def collecting(f: Unit -> a \ ef): (a, List[(String, Int32, Int32)]) \ (ef - LoadProgress) + IO =
        region rc {
            let seen = MutList.empty(rc);
            let push = (phase, done, total) -> MutList.push((phase, done, total), seen);
            let result = run f() with handler LoadProgress {
                def report(phase, done, total, k) = { push(phase, done, total); k(()) }
                def runTasks(phase, tasks, k) = { LoadProgress.runTasksInOrder(push, phase, tasks); k(()) }
                def imageDecoder(k) = k(ImageData.failingDecoder("テストの handler は絵を解かない"))
                def downloads(k) = k(LoadProgress.localDownloads())
            };
            (result, MutList.toList(seen))
        }

    /// 順に回す handler（runTasksInOrder）を LoadProgress.Conformance へ渡す道具。
    def harness(): LoadProgress.Conformance.Harness = {
        handle = collecting,
        sleepMs = ms -> Thread.sleep(ms),
        fail = message -> throw new RuntimeException(message),
        nowMs = () -> System.currentTimeMillis(),
        newFlag = () -> {
            let flag = new AtomicBoolean(false);
            { raise = () -> flag.set(true), isRaised = () -> flag.get() }
        }
    }

    def threeChars(): List[String] = "a" :: "b" :: "c" :: Nil

    @Test
    def testMapReportsEachStep(): Unit \ {Assert, IO} =
        let (_, seen) = collecting(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, threeChars()));
        Assert.assertEq(expected = ("p", 0, 3) :: ("p", 1, 3) :: ("p", 2, 3) :: ("p", 3, 3) :: Nil, seen)

    @Test
    def testMapKeepsResultOrder(): Unit \ {Assert, IO} =
        let (ys, _) = collecting(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, threeChars()));
        Assert.assertEq(expected = "A" :: "B" :: "C" :: Nil, ys)

    @Test
    def testMapOfEmptyReportsNothing(): Unit \ {Assert, IO} =
        let (_, seen) = collecting(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, (Nil: List[String])));
        Assert.assertEq(expected = Nil, seen)

    @Test
    def testRunNoopReturnsValue(): Unit \ {Assert, IO} =
        let ys = LoadProgress.runNoop(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, threeChars()));
        Assert.assertEq(expected = "A" :: "B" :: "C" :: Nil, ys)

    @Test
    def testInOrderHandlerKeepsTheOrderRules(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, LoadProgress.Conformance.orderViolations(harness()))

    @Test
    def testInOrderHandlerEndsOnTheFirstException(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Nil, LoadProgress.Conformance.failureViolations(harness()))

    /// 順に回す handler は何も終わらない間に知らせないので、50 ms ごとの決まりの検査に引っかかる（検査が handler の違いを見分ける）。
    @Test
    def testPollingCheckCatchesAnInOrderHandler(): Unit \ {Assert, IO} =
        Assert.assertFalse(List.isEmpty(LoadProgress.Conformance.pollingViolations(harness())))

    /// 仕事の例外を包み直して投げる handler（同じ例外で抜けない）。
    def wrappingFailures(f: Unit -> a \ ef): (a, List[(String, Int32, Int32)]) \ (ef - LoadProgress) + IO =
        let result = run f() with handler LoadProgress {
            def report(_phase, _done, _total, k) = k(())
            def runTasks(phase, tasks, k) = {
                try { LoadProgress.runTasksInOrder((_, _, _) -> (), phase, tasks) } catch {
                    case e: RuntimeException => throw new RuntimeException("wrapped: ${e.getMessage()}")
                };
                k(())
            }
            def imageDecoder(k) = k(ImageData.failingDecoder("テストの handler は絵を解かない"))
            def downloads(k) = k(LoadProgress.localDownloads())
        };
        (result, Nil)

    /// 例外を包み直す handler は、例外の決まりの検査に引っかかる（検査が handler の違いを見分ける）。
    @Test
    def testFailureCheckCatchesAWrappingHandler(): Unit \ {Assert, IO} =
        Assert.assertFalse(List.isEmpty(LoadProgress.Conformance.failureViolations({ handle = wrappingFailures | harness() })))

    /// 2 本目からを別のスレッドで始め、1 本目の例外で抜ける時に残りを止めない handler。
    def leavingTheRestRunning(f: Unit -> a \ ef): (a, List[(String, Int32, Int32)]) \ (ef - LoadProgress) + IO =
        let result = run f() with handler LoadProgress {
            def report(_phase, _done, _total, k) = k(())
            def runTasks(_phase, tasks, k) = {
                let pool = Executors.newCachedThreadPool();
                List.drop(1, tasks) |> List.forEach(task -> discard pool.submit(new Callable[Bool] {
                    def call(_this: Callable[Bool]): Bool \ IO = { task(); true }
                }));
                List.take(1, tasks) |> List.forEach(task -> task());
                k(())
            }
            def imageDecoder(k) = k(ImageData.failingDecoder("テストの handler は絵を解かない"))
            def downloads(k) = k(LoadProgress.localDownloads())
        };
        (result, Nil)

    /// 例外の後に残りを止めない handler は、例外の決まりの検査に引っかかる。
    @Test
    def testFailureCheckCatchesAHandlerThatLeavesTheRestRunning(): Unit \ {Assert, IO} =
        Assert.assertFalse(List.isEmpty(LoadProgress.Conformance.failureViolations({ handle = leavingTheRestRunning | harness() })))

    @Test
    def testRunNoopRunsTasksInOrder(): Unit \ {Assert, IO} =
        let ys = LoadProgress.runNoop(() -> LoadProgress.parMapWithProgress("p", x -> checked_ecast(x * 10), List.range(0, 3)));
        Assert.assertEq(expected = 0 :: 10 :: 20 :: Nil, ys)

    @Test
    def testLocalDownloadsSaysEveryPathIsLoaded(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = LoadProgress.LoadState.Loaded, (LoadProgress.localDownloads()#stateOf)("assets/bgm/sea.wav"))

    @Test
    def testLocalDownloadsMissesNothing(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Set.empty(), (LoadProgress.localDownloads()#missing)())

    @Test
    def testRunNoopHandsOutLocalDownloads(): Unit \ {Assert, IO} =
        let state = LoadProgress.runNoop(() -> (LoadProgress.downloads()#stateOf)("assets/walk/gate.glb"));
        Assert.assertEq(expected = LoadProgress.LoadState.Loaded, state)
}
