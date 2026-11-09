// TestAppBackgroundLoad — App.withBackgroundLoad・withMissingAssets・withDecodeBudget を、偽の downloads と App.stepBackgroundLoad
// （実機のふつうのコマが進める前に当てる物）で確かめる。偽の downloads は道ごとの状態と missing を Ref に持ち、テストがコマの間に書き替える。
mod TestAppBackgroundLoad {

    /// テストの World。covered = 予算を Covered にするか（偽なら Paused）・stored = store が受けた結果・
    /// writes = withPending と withMissing を呼んだ回数（同じ World を返したかを数える）。
    type alias World = {
        pending = BackgroundLoad.Pending,
        missing = Set[String],
        covered = Bool,
        stored = List[(String, Result[String, String])],
        writes = Int32
    }

    /// 偽の downloads と、テストが書き替える口・受けた予算と捨てた道の記録。
    type alias Fake = {
        downloads = LoadProgress.AssetDownloads,
        states = Ref[Map[String, LoadProgress.LoadState], Static],
        missing = Ref[Set[String], Static],
        budgets = Ref[List[LoadProgress.DecodeBudget], Static],
        released = Ref[List[String], Static]
    }

    /// 道ごとの状態（表に無い道は Loaded）と missing を Ref から引く偽の downloads。
    def fakeOf(states: List[(String, LoadProgress.LoadState)], missing: Set[String]): Fake \ IO =
        let table = Ref.fresh(Static, List.toMap(states));
        let missingNow = Ref.fresh(Static, missing);
        let budgets = Ref.fresh(Static, Nil);
        let released = Ref.fresh(Static, Nil);
        { downloads = { stateOf = path -> Map.getWithDefault(path, LoadProgress.LoadState.Loaded, Ref.get(table)),
                        missing = () -> Ref.get(missingNow),
                        request = _ -> checked_ecast(()),
                        release = paths -> Ref.put(List.append(Ref.get(released), paths), released),
                        setBudget = budget -> Ref.put(List.append(Ref.get(budgets), budget :: Nil), budgets),
                        spentMs = () -> checked_ecast(0.0) },
          states = table, missing = missingNow, budgets = budgets, released = released }

    def setState(path: String, state: LoadProgress.LoadState, fake: Fake): Unit \ IO =
        Ref.put(Map.insert(path, state, Ref.get(fake#states)), fake#states)

    /// 鍵 a・b（道は <鍵>.glb）。decode は字を大文字にする。見込みは 10 ms。
    def group(): BackgroundLoad.Group[String, String] =
        { name = "rooms", keys = "a" :: "b" :: Nil, pathsOf = key -> "${key}.glb" :: Nil,
          read = key -> checked_ecast(key), decode = raw -> checked_ecast(Ok(String.toUpperCase(raw))), costMs = 10.0 }

    /// fake の downloads で起動の読み込みを流し、待ちの表を持つ World を作る。
    def worldOf(fake: Fake): World \ {Fs.FileRead, IO} =
        let pending = run snd(BackgroundLoad.start(group())) with handler LoadProgress {
            def report(_phase, _done, _total, k) = k(())
            def runTasks(phase, tasks, k) = { LoadProgress.runTasksInOrder((_, _, _) -> (), phase, tasks); k(()) }
            def imageDecoder(k) = k(ImageData.failingDecoder("テストの handler は絵を解かない"))
            def downloads(k) = k(fake#downloads)
        };
        { pending = pending, missing = Ref.get(fake#missing), covered = true, stored = Nil, writes = 0 }

    /// 部屋のグループを読む App（予算は World の covered で Covered(50) か Paused）。
    def roomsApp(fake: Fake): App.App[World, {}] =
        App.make(({ pending = { group = "", states = Map.empty(), sentPriority = Nil, costMs = 0.0, idleSinceMs = -1.0 }, missing = Set.empty(), covered = true, stored = Nil, writes = 0 }: World))
            |> App.withDecodeBudget(w -> if (w#covered) LoadProgress.DecodeBudget.Covered(50.0) else LoadProgress.DecodeBudget.Paused)
            |> App.withBackgroundLoad({ group = group(), downloads = fake#downloads,
                                        pendingOf = w -> w#pending,
                                        withPending = (p, w) -> { pending = p, writes = w#writes + 1 | w },
                                        store = (key, result, w) -> { stored = List.append(w#stored, (key, result) :: Nil) | w },
                                        priority = _ -> "a" :: "b" :: Nil })

    /// 届いていない名前を写すだけの App（予算は既定）。
    def missingApp(fake: Fake): App.App[World, {}] =
        App.make(({ pending = { group = "", states = Map.empty(), sentPriority = Nil, costMs = 0.0, idleSinceMs = -1.0 }, missing = Set.empty(), covered = true, stored = Nil, writes = 0 }: World))
            |> App.withMissingAssets({ downloads = fake#downloads, missingOf = w -> w#missing,
                                      withMissing = (m, w) -> { missing = m, writes = w#writes + 1 | w } })

    // ========================================================================
    // 全部 Loaded: 毎コマ同じ World を返す
    // ========================================================================

    /// 後回しの無い機種（全部の道が Loaded）では、3 コマ回しても withPending を 1 度も呼ばない
    @Test
    def testAllLoadedKeepsTheSameWorld(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(Nil, Set.empty());
        let app = roomsApp(fake);
        let w = worldOf(fake) |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app);
        Assert.assertEq(expected = (0, Nil), (w#writes, w#stored))

    /// missing が空なら withMissingAssets も withMissing を呼ばない
    @Test
    def testEmptyMissingKeepsTheSameWorld(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(Nil, Set.empty());
        let app = missingApp(fake);
        let w = worldOf(fake) |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app);
        Assert.assertEq(expected = 0, w#writes)

    // ========================================================================
    // 届いていない → 届いた → Loaded（予算は World から）
    // ========================================================================

    /// b が Queued の間は store されず、Downloaded になったコマで解かれて B が置かれる
    @Test
    def testKeyIsStoredAfterItArrives(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil, Set.empty());
        let app = roomsApp(fake);
        let w1 = worldOf(fake) |> App.stepBackgroundLoad(app);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        let w2 = App.stepBackgroundLoad(app, w1);
        Assert.assertEq(expected = (Nil, ("b", Ok("B")) :: Nil, true),
                        (w1#stored, w2#stored, BackgroundLoad.isLoaded("b", w2#pending)))

    /// 予算が Paused の間は届いていても解かず、Covered に替えたコマで解く
    @Test
    def testPausedWaitsAndCoveredLoads(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil, Set.empty());
        let app = roomsApp(fake);
        let w0 = { covered = false | worldOf(fake) };
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        let paused = w0 |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app);
        let covered = App.stepBackgroundLoad(app, { covered = true | paused });
        Assert.assertEq(expected = (Nil, ("b", Ok("B")) :: Nil), (paused#stored, covered#stored))

    /// 取れなかった鍵は store に Err を 1 回だけ渡す
    @Test
    def testFailureIsStoredOnce(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil, Set.empty());
        let app = roomsApp(fake);
        let w0 = worldOf(fake);
        setState("b.glb", LoadProgress.LoadState.Failed("404"), fake);
        let w = w0 |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app);
        Assert.assertEq(expected = ("b", Err("404")) :: Nil, w#stored)

    // ========================================================================
    // withMissingAssets: 変わった時だけ書く・予算を届ける
    // ========================================================================

    /// bg・bgm が missing の World へ、bg が届いた（missing が bgm だけ）知らせを 2 コマ流すと、書くのは 1 回目だけ
    @Test
    def testMissingIsWrittenOnlyWhenItChanges(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(Nil, Set#{"bg", "bgm"});
        let app = missingApp(fake);
        let w0 = worldOf(fake);
        Ref.put(Set#{"bgm"}, fake#missing);
        let w = w0 |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app);
        Assert.assertEq(expected = (Set#{"bgm"}, 1), (w#missing, w#writes))

    /// withMissingAssets だけの App でも、毎コマ予算（既定の Idle(4)。ブラウザの登録の初めの予算と同じ）をブラウザへ届ける（missing が空でも）
    @Test
    def testMissingOnlyAppStillSendsTheBudget(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(Nil, Set.empty());
        let app = missingApp(fake);
        discard worldOf(fake) |> App.stepBackgroundLoad(app) |> App.stepBackgroundLoad(app);
        Assert.assertEq(expected = LoadProgress.DecodeBudget.Idle(4.0) :: LoadProgress.DecodeBudget.Idle(4.0) :: Nil, Ref.get(fake#budgets))

    /// 解いて置いた鍵の道の生のバイトを捨てる（b を置いたコマで b.glb だけ）
    @Test
    def testStoredKeyReleasesItsPaths(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil, Set.empty());
        let app = roomsApp(fake);
        let w0 = worldOf(fake);
        let before = Ref.get(fake#released);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        discard App.stepBackgroundLoad(app, w0);
        Assert.assertEq(expected = ("a.glb" :: Nil, "a.glb" :: "b.glb" :: Nil), (before, Ref.get(fake#released)))
}
