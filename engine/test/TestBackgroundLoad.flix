// BackgroundLoad の起動の読み・1 コマの進め方（状態の引き直し・優先順・予算・失敗）・待ちの判定を、偽の downloads で確かめる。
// 偽の downloads は道ごとの状態を Ref に持ち、テストがコマの間に書き替える。時刻は偽の時計で、decode 1 回が decodeMs（既定 100 ms）進める。
mod TestBackgroundLoad {

    /// 偽の downloads と、テストが状態を書き替える口・頼まれた道と捨てた道の記録・偽の時計。
    /// decodeMs = decode 1 回が進める ms・spent = 機種がこのコマの登録に使った ms（spentMs が返す）。
    type alias Fake = {
        downloads = LoadProgress.AssetDownloads,
        states = Ref[Map[String, LoadProgress.LoadState], Static],
        requested = Ref[List[List[String]], Static],
        released = Ref[List[List[String]], Static],
        clock = Ref[Float64, Static],
        decodeMs = Ref[Float64, Static],
        spent = Ref[Float64, Static]
    }

    /// 道ごとの状態を states から引く偽の downloads（表に無い道は Loaded）。release した道は fge-web.js と同じく Queued と言う。
    def fakeOf(states: List[(String, LoadProgress.LoadState)]): Fake \ IO =
        let table = Ref.fresh(Static, List.toMap(states));
        let requested = Ref.fresh(Static, Nil);
        let released = Ref.fresh(Static, Nil);
        let spent = Ref.fresh(Static, 0.0);
        { downloads = { stateOf = path -> Map.getWithDefault(path, LoadProgress.LoadState.Loaded, Ref.get(table)),
                        missing = () -> checked_ecast(Set.empty()),
                        request = paths -> Ref.put(List.append(Ref.get(requested), paths :: Nil), requested),
                        release = paths -> {
                            Ref.put(List.append(Ref.get(released), paths :: Nil), released);
                            Ref.put(List.foldLeft((acc, path) -> Map.insert(path, LoadProgress.LoadState.Queued, acc), Ref.get(table), paths), table)
                        },
                        setBudget = _ -> checked_ecast(()),
                        spentMs = () -> Ref.get(spent) },
          states = table, requested = requested, released = released, clock = Ref.fresh(Static, 0.0),
          decodeMs = Ref.fresh(Static, 100.0), spent = spent }

    def setState(path: String, state: LoadProgress.LoadState, fake: Fake): Unit \ IO =
        Ref.put(Map.insert(path, state, Ref.get(fake#states)), fake#states)

    /// 鍵 a・b・c（道は <鍵>.glb の 1 本）。decode は字を大文字にし、時計を decodeMs 進める。鍵 bad は解けない。見込みは 100 ms。
    def groupOf(fake: Fake, keys: List[String]): BackgroundLoad.Group[String, String] =
        groupWithPaths(fake, keys, key -> "${key}.glb" :: Nil)

    def groupWithPaths(fake: Fake, keys: List[String], pathsOf: String -> List[String]): BackgroundLoad.Group[String, String] =
        { name = "rooms", keys = keys, pathsOf = pathsOf,
          read = key -> checked_ecast(key),
          decode = raw -> {
              Ref.put(Ref.get(fake#clock) + Ref.get(fake#decodeMs), fake#clock);
              if (raw == "bad") Err("壊れている") else Ok(String.toUpperCase(raw))
          },
          costMs = 100.0 }

    def abc(): List[String] = "a" :: "b" :: "c" :: Nil

    /// downloads を fake の物にして f を流す。
    def withFake(fake: Fake, f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO =
        run f() with handler LoadProgress {
            def report(_phase, _done, _total, k) = k(())
            def runTasks(phase, tasks, k) = { LoadProgress.runTasksInOrder((_, _, _) -> (), phase, tasks); k(()) }
            def imageDecoder(k) = k(ImageData.failingDecoder("テストの handler は絵を解かない"))
            def downloads(k) = k(fake#downloads)
        }

    def started(fake: Fake, keys: List[String]): (Map[String, Result[String, String]], BackgroundLoad.Pending) \ {Fs.FileRead, IO} =
        withFake(fake, () -> BackgroundLoad.start(groupOf(fake, keys)))

    /// 1 コマ進める（優先順は既定の abc）。
    def stepOf(fake: Fake, budget: LoadProgress.DecodeBudget, priority: List[String], pending: BackgroundLoad.Pending): Option[(BackgroundLoad.Pending, List[(String, Result[String, String])])] \ {Fs.FileRead, IO} =
        BackgroundLoad.Internal.step({ group = groupOf(fake, abc()), downloads = fake#downloads, nowMs = () -> Ref.get(fake#clock),
                                       budget = budget, priority = () -> priority, spentMs = 0.0 }, pending)

    /// 1 コマ進めた後の待ちの表（何も変わらなければ前の表）。
    def nextPending(fake: Fake, budget: LoadProgress.DecodeBudget, pending: BackgroundLoad.Pending): BackgroundLoad.Pending \ {Fs.FileRead, IO} =
        stepOf(fake, budget, abc(), pending) |> Option.map(fst) |> Option.getWithDefault(pending)

    def statesOf(pending: BackgroundLoad.Pending): List[LoadProgress.LoadState] =
        abc() |> List.map(key -> BackgroundLoad.stateOf(key, pending))

    // ========================================================================
    // 起動: 届いている鍵だけ読み、残りは頼んで待ちの表に載せる
    // ========================================================================

    /// 後回しの無い機種（全部の道が Loaded）では全部を解き、待ちの表は全部 Loaded
    @Test
    def testStartWithEverythingArrivedDecodesAll(): Unit \ {Assert, Fs.FileRead, IO} =
        let (decoded, pending) = started(fakeOf(Nil), abc());
        Assert.assertEq(expected = (Map#{"a" => Ok("A"), "b" => Ok("B"), "c" => Ok("C")}, LoadProgress.LoadState.Loaded :: LoadProgress.LoadState.Loaded :: LoadProgress.LoadState.Loaded :: Nil),
                        (decoded, statesOf(pending)))

    /// b が Queued・c が Downloading なら a だけ解き、b・c の道を既定の順で頼む
    @Test
    def testStartRequestsTheKeysNotArrived(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: ("c.glb", LoadProgress.LoadState.Downloading) :: Nil);
        let (decoded, pending) = started(fake, abc());
        Assert.assertEq(expected = (Set#{"a"}, LoadProgress.LoadState.Loaded :: LoadProgress.LoadState.Queued :: LoadProgress.LoadState.Downloading :: Nil, ("b.glb" :: "c.glb" :: Nil) :: Nil),
                        (Map.keysOf(decoded), statesOf(pending), Ref.get(fake#requested)))

    // ========================================================================
    // 1 コマ: 届いていない → 届いた → Loaded
    // ========================================================================

    /// 全部 Loaded の表は何もしない（None = 呼ぶ側は同じ World を返す）
    @Test
    def testStepWithAllLoadedChangesNothing(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(Nil);
        let (_, pending) = started(fake, abc());
        Assert.assertEq(expected = None, stepOf(fake, LoadProgress.DecodeBudget.Covered(50.0), abc(), pending) |> Option.map(snd))

    /// b が Queued → Downloaded と進み、Covered のコマで解かれて Loaded になる
    @Test
    def testStepLoadsAKeyOnceItArrives(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        let p1 = nextPending(fake, LoadProgress.DecodeBudget.Covered(50.0), p0);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        let p2 = nextPending(fake, LoadProgress.DecodeBudget.Paused, p1);
        let p3 = nextPending(fake, LoadProgress.DecodeBudget.Covered(50.0), p2);
        Assert.assertEq(expected = (LoadProgress.LoadState.Queued, LoadProgress.LoadState.Downloaded, LoadProgress.LoadState.Loaded),
                        (BackgroundLoad.stateOf("b", p1), BackgroundLoad.stateOf("b", p2), BackgroundLoad.stateOf("b", p3)))

    /// 解いた鍵の結果を store へ渡す
    @Test
    def testStepReturnsTheDecodedValue(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        Assert.assertEq(expected = Some(("b", Ok("B")) :: Nil),
                        stepOf(fake, LoadProgress.DecodeBudget.Covered(50.0), abc(), p0) |> Option.map(snd))

    // ========================================================================
    // 予算: Paused は解かない・Idle は見込みが収まる分だけ・Covered は 1 本は始める
    // ========================================================================

    /// 3 本とも届いた状態から 1 コマ進めた時に解いた鍵の数。
    def decodedCountUnder(budget: LoadProgress.DecodeBudget): Int32 \ {Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: ("b.glb", LoadProgress.LoadState.Queued) :: ("c.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        setState("c.glb", LoadProgress.LoadState.Downloaded, fake);
        stepOf(fake, budget, abc(), p0) |> Option.map(e -> List.length(snd(e))) |> Option.getWithDefault(0)

    /// Paused は届いていても解かない
    @Test
    def testPausedDecodesNothing(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = 0, decodedCountUnder(LoadProgress.DecodeBudget.Paused))

    /// Idle(50): 見込み 100 ms が 50 ms に収まらないので始めない
    @Test
    def testIdleDoesNotStartAKeyOverTheBudget(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = 0, decodedCountUnder(LoadProgress.DecodeBudget.Idle(50.0)))

    /// Idle(250): 1 本 100 ms なので 2 本（200 ms）まで。3 本目は 200 + 100 > 250 で始めない
    @Test
    def testIdleDecodesWhileTheEstimateFits(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = 2, decodedCountUnder(LoadProgress.DecodeBudget.Idle(250.0)))

    /// Covered(50): 1 本目は見込みを問わず始め、100 ms 使った後は 50 ms を超えているので止める
    @Test
    def testCoveredStartsOneKeyEvenOverTheBudget(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = 1, decodedCountUnder(LoadProgress.DecodeBudget.Covered(50.0)))

    /// 解いた順は優先順（c → a）。Covered(150): 1 本目 100 ms の後も 150 ms に満たないので 2 本目まで
    @Test
    def testDecodesInPriorityOrder(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: ("c.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        setState("c.glb", LoadProgress.LoadState.Downloaded, fake);
        Assert.assertEq(expected = Some("c" :: "a" :: Nil),
                        stepOf(fake, LoadProgress.DecodeBudget.Covered(150.0), "c" :: "a" :: Nil, p0) |> Option.map(e -> List.map(fst, snd(e))))

    /// 優先順に同じ鍵が 2 回あっても、1 コマで解くのは 1 回（Covered(500) は 3 本ぶん収まる余裕がある）
    @Test
    def testDuplicatedPriorityDecodesOnce(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        Assert.assertEq(expected = Some("b" :: Nil),
                        stepOf(fake, LoadProgress.DecodeBudget.Covered(500.0), "b" :: "b" :: Nil, p0) |> Option.map(e -> List.map(fst, snd(e))))

    // ========================================================================
    // 優先順: 前に送った物と違うコマだけ頼む
    // ========================================================================

    /// 起動で b・c を頼んだ後、優先順 c・b を 2 コマ続けて渡すと、頼むのは 1 回目のコマだけ
    @Test
    def testPriorityIsSentOnlyWhenItChanges(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: ("c.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        let p1 = stepOf(fake, LoadProgress.DecodeBudget.Paused, "c" :: "b" :: Nil, p0) |> Option.map(fst) |> Option.getWithDefault(p0);
        discard stepOf(fake, LoadProgress.DecodeBudget.Paused, "c" :: "b" :: Nil, p1);
        Assert.assertEq(expected = ("b.glb" :: "c.glb" :: Nil) :: ("c.glb" :: "b.glb" :: Nil) :: Nil, Ref.get(fake#requested))

    // ========================================================================
    // 失敗: store に Err を 1 回・解けない鍵を解き直さない
    // ========================================================================

    /// b が Failed になったコマで Err を 1 回返し、次のコマは何も返さない
    @Test
    def testFailureIsReportedOnce(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("b.glb", LoadProgress.LoadState.Failed("404"), fake);
        let first = stepOf(fake, LoadProgress.DecodeBudget.Covered(50.0), abc(), p0);
        let p1 = first |> Option.map(fst) |> Option.getWithDefault(p0);
        Assert.assertEq(expected = (Some(("b", Err("404")) :: Nil), None),
                        (Option.map(snd, first), stepOf(fake, LoadProgress.DecodeBudget.Covered(50.0), abc(), p1) |> Option.map(snd)))

    /// 解けなかった鍵は Failed のまま、道が届いたままでも次のコマで解き直さない
    @Test
    def testDecodeFailureIsNotRetried(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("bad.glb", LoadProgress.LoadState.Queued) :: Nil);
        let group = groupOf(fake, "bad" :: Nil);
        let (_, p0) = withFake(fake, () -> BackgroundLoad.start(group));
        setState("bad.glb", LoadProgress.LoadState.Downloaded, fake);
        let spec = { group = group, downloads = fake#downloads, nowMs = () -> Ref.get(fake#clock),
                     budget = LoadProgress.DecodeBudget.Covered(50.0), priority = () -> "bad" :: Nil, spentMs = 0.0 };
        let p1 = BackgroundLoad.Internal.step(spec, p0) |> Option.map(fst) |> Option.getWithDefault(p0);
        Assert.assertEq(expected = (LoadProgress.LoadState.Failed("壊れている"), None),
                        (BackgroundLoad.stateOf("bad", p1), BackgroundLoad.Internal.step(spec, p1) |> Option.map(snd)))

    // ========================================================================
    // readiness: 判定だけで待たない
    // ========================================================================

    def waitingPending(): BackgroundLoad.Pending \ {Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Downloading) :: ("c.glb", LoadProgress.LoadState.Failed("404")) :: Nil);
        snd(started(fake, abc()))

    /// Loaded の鍵だけなら Ready・届いていない鍵があれば上限 20 秒の内は Waiting・超えたら GaveUp・Failed の鍵は待たずに GaveUp
    @Test
    def testReadinessFollowsTheStates(): Unit \ {Assert, Fs.FileRead, IO} =
        let pending = waitingPending();
        Assert.assertEq(expected = (BackgroundLoad.Readiness.Ready, BackgroundLoad.Readiness.Waiting,
                                    BackgroundLoad.Readiness.GaveUp("b が 20.0 秒待っても届かない"), BackgroundLoad.Readiness.GaveUp("c: 404")),
                        (BackgroundLoad.readiness("a" :: Nil, pending, 0.0, 20.0), BackgroundLoad.readiness("a" :: "b" :: Nil, pending, 10.0, 20.0),
                         BackgroundLoad.readiness("b" :: Nil, pending, 20.0, 20.0), BackgroundLoad.readiness("b" :: "c" :: Nil, pending, 0.0, 20.0)))

    /// 表に無い鍵は待ち続けずに GaveUp
    @Test
    def testReadinessGivesUpOnAnUnknownKey(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = BackgroundLoad.Readiness.GaveUp("z: z は rooms の鍵に無い"),
                        BackgroundLoad.readiness("z" :: Nil, waitingPending(), 0.0, 20.0))

    // ========================================================================
    // 取り直し: Failed → Queued → Downloaded → Loaded
    // ========================================================================

    /// 取れずに Failed になった b を機種が Queued へ戻すと、届いた後のコマで解かれて Loaded になる
    @Test
    def testFailedKeyRecoversWhenRequeued(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("b.glb", LoadProgress.LoadState.Failed("回線が切れた"), fake);
        let p1 = nextPending(fake, LoadProgress.DecodeBudget.Covered(50.0), p0);
        setState("b.glb", LoadProgress.LoadState.Queued, fake);
        let p2 = nextPending(fake, LoadProgress.DecodeBudget.Covered(50.0), p1);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        let p3 = nextPending(fake, LoadProgress.DecodeBudget.Paused, p2);
        let p4 = nextPending(fake, LoadProgress.DecodeBudget.Covered(50.0), p3);
        Assert.assertEq(expected = (LoadProgress.LoadState.Failed("回線が切れた") :: LoadProgress.LoadState.Queued :: LoadProgress.LoadState.Downloaded :: LoadProgress.LoadState.Loaded :: Nil),
                        List.map(p -> BackgroundLoad.stateOf("b", p), p1 :: p2 :: p3 :: p4 :: Nil))

    /// 優先順が替わったコマに Failed の鍵があれば、機種へ取り直しを頼む（起動の頼みの後に b.glb）
    @Test
    def testPriorityRequestsAFailedKeyAgain(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("b.glb", LoadProgress.LoadState.Failed("回線が切れた"), fake);
        discard stepOf(fake, LoadProgress.DecodeBudget.Paused, "b" :: "a" :: Nil, p0);
        Assert.assertEq(expected = ("b.glb" :: Nil) :: ("b.glb" :: Nil) :: Nil, Ref.get(fake#requested))

    // ========================================================================
    // 予算の続き: Covered の 2 本目・機種が使った ms・見込みの置き換え
    // ========================================================================

    /// Covered(150): 1 本目（100 ms）の後は 150 に満たないので 2 本目を始め、200 ms を使った後の 3 本目は始めない
    @Test
    def testCoveredStopsOnceTheBudgetIsUsed(): Unit \ {Assert, Fs.FileRead, IO} =
        Assert.assertEq(expected = 2, decodedCountUnder(LoadProgress.DecodeBudget.Covered(150.0)))

    /// 機種がこのコマの登録に 100 ms 使っていれば、Idle(150) でも見込み 100 ms の鍵は始めない（1 コマで予算を 2 回使わない）
    @Test
    def testIdleCountsTheMsSpentByThePlatform(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        Ref.put(100.0, fake#spent);
        Assert.assertEq(expected = None, stepOf(fake, LoadProgress.DecodeBudget.Idle(150.0), abc(), p0) |> Option.flatMap(e -> List.head(snd(e))))

    /// Idle で解いた鍵の測った ms（40）が見込み（100 → 70）を置き換え、次のコマの Idle(75) で b を始められる
    @Test
    def testIdleUpdatesTheEstimateForTheNextFrame(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: ("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        Ref.put(40.0, fake#decodeMs);
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        let p1 = nextPending(fake, LoadProgress.DecodeBudget.Idle(150.0), p0);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        let p2 = nextPending(fake, LoadProgress.DecodeBudget.Idle(75.0), p1);
        Assert.assertEq(expected = (70.0, LoadProgress.LoadState.Loaded), (p1#costMs, BackgroundLoad.stateOf("b", p2)))

    /// 1 回だけ重かった（1000 ms）値は見込みの 3 倍（300 ms）で頭打ちにして平均に入れる（100 → 200）
    @Test
    def testOneSlowDecodeIsCappedInTheEstimate(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        Ref.put(1000.0, fake#decodeMs);
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        Assert.assertEq(expected = 200.0, nextPending(fake, LoadProgress.DecodeBudget.Covered(50.0), p0)#costMs)

    /// 見込みが初めの値（100）の 2 倍を超えて Idle(50) で始めない間、estimateResetMs 待った後のコマで見込みを 100 へ戻す（解きはしない）
    @Test
    def testIdleResetsAnInflatedEstimateWithoutDecoding(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, started0) = started(fake, abc());
        let p0 = { costMs = 300.0 | started0 };
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        let p1 = nextPending(fake, LoadProgress.DecodeBudget.Idle(50.0), p0);
        Ref.put(Ref.get(fake#clock) + BackgroundLoad.Internal.estimateResetMs(), fake#clock);
        let p2 = nextPending(fake, LoadProgress.DecodeBudget.Idle(50.0), p1);
        Assert.assertEq(expected = (100.0, LoadProgress.LoadState.Downloaded), (p2#costMs, BackgroundLoad.stateOf("a", p2)))

    /// 既定の Idle(4) で見込み 200 ms の部屋が 3 つ届いていても、16 ms ごとに 6 秒回して解くのは 0 本（遊んでいる間に止まらない）
    @Test
    def testDefaultIdleNeverDecodesAHeavyRoom(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: ("b.glb", LoadProgress.LoadState.Queued) :: ("c.glb", LoadProgress.LoadState.Queued) :: Nil);
        let group = { costMs = 200.0 | groupOf(fake, abc()) };
        let (_, p0) = withFake(fake, () -> BackgroundLoad.start(group));
        List.forEach(k -> setState("${k}.glb", LoadProgress.LoadState.Downloaded, fake), abc());
        let spec = { group = group, downloads = fake#downloads, nowMs = () -> Ref.get(fake#clock),
                     budget = LoadProgress.DecodeBudget.Idle(4.0), priority = () -> abc(), spentMs = 0.0 };
        let last = List.range(0, 375) |> List.foldLeft((p, _) -> {
            Ref.put(Ref.get(fake#clock) + 16.0, fake#clock);
            BackgroundLoad.Internal.step(spec, p) |> Option.map(fst) |> Option.getWithDefault(p)
        }, p0);
        Assert.assertEq(expected = 0, abc() |> List.count(k -> BackgroundLoad.isLoaded(k, last)))

    /// 前の step（ほかのグループ）がこのコマで 100 ms 使っていれば、Idle(150) で見込み 100 ms の鍵は始めない
    @Test
    def testIdleCountsTheMsSpentByAnEarlierGroup(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: Nil);
        let (_, p0) = started(fake, abc());
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        let spec = { group = groupOf(fake, abc()), downloads = fake#downloads, nowMs = () -> Ref.get(fake#clock),
                     budget = LoadProgress.DecodeBudget.Idle(150.0), priority = () -> abc(), spentMs = 100.0 };
        Assert.assertEq(expected = None, BackgroundLoad.Internal.step(spec, p0) |> Option.flatMap(e -> List.head(snd(e))))

    // ========================================================================
    // 生のバイトを捨てる: 解いた鍵の道だけ・まだ解いていない鍵も使う道は残す
    // ========================================================================

    /// a と b が同じ絵 wall.jpg を貼る。a を解いたコマでは a.glb だけ捨て、b を解いたコマで b.glb と wall.jpg を捨てる
    @Test
    def testSharedPathIsReleasedAfterTheLastKey(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: ("b.glb", LoadProgress.LoadState.Queued) :: Nil);
        let group = groupWithPaths(fake, "a" :: "b" :: Nil, key -> "${key}.glb" :: "wall.jpg" :: Nil);
        let (_, p0) = withFake(fake, () -> BackgroundLoad.start(group));
        let step = (p: BackgroundLoad.Pending) -> BackgroundLoad.Internal.step({ group = group, downloads = fake#downloads, nowMs = () -> Ref.get(fake#clock),
                                                                               budget = LoadProgress.DecodeBudget.Covered(50.0), priority = () -> "a" :: "b" :: Nil, spentMs = 0.0 }, p)
                                                   |> Option.map(fst) |> Option.getWithDefault(p);
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        let p1 = step(p0);
        setState("b.glb", LoadProgress.LoadState.Downloaded, fake);
        discard step(p1);
        Assert.assertEq(expected = ("a.glb" :: Nil) :: ("b.glb" :: "wall.jpg" :: Nil) :: Nil, Ref.get(fake#released))

    /// 生のバイトを捨てた道（a.glb）を別のグループが始めると、Failed にならず Waiting で取り直しを頼む
    @Test
    def testReleasedPathIsWaitingForAnotherGroup(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(Nil);
        discard started(fake, abc());
        let other = { name = "doors" | groupWithPaths(fake, "door" :: Nil, _ -> "a.glb" :: Nil) };
        let (_, pending) = withFake(fake, () -> BackgroundLoad.start(other));
        Assert.assertEq(expected = (BackgroundLoad.Readiness.Waiting, Some("a.glb" :: Nil)),
                        (BackgroundLoad.readiness("door" :: Nil, pending, 0.0, 20.0), List.last(Ref.get(fake#requested))))

    /// A が解いて a.glb を捨てた後、同じ道を待つ B（届いていたのに Queued へ戻った）は優先順が変わらなくても頼み直し、届けば Loaded になる
    @Test
    def testRegressedKeyIsRequestedAndLoaded(): Unit \ {Assert, Fs.FileRead, IO} =
        let fake = fakeOf(("a.glb", LoadProgress.LoadState.Queued) :: Nil);
        let groupA = groupOf(fake, "a" :: Nil);
        let groupB = { name = "doors" | groupWithPaths(fake, "door" :: Nil, _ -> "a.glb" :: Nil) };
        let (_, a0) = withFake(fake, () -> BackgroundLoad.start(groupA));
        let (_, b0) = withFake(fake, () -> BackgroundLoad.start(groupB));
        let stepWith = (group: BackgroundLoad.Group[String, String], keys: List[String], budget: LoadProgress.DecodeBudget, p: BackgroundLoad.Pending) ->
            BackgroundLoad.Internal.step({ group = group, downloads = fake#downloads, nowMs = () -> Ref.get(fake#clock),
                                           budget = budget, priority = () -> keys, spentMs = 0.0 }, p) |> Option.map(fst) |> Option.getWithDefault(p);
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        let b1 = stepWith(groupB, "door" :: Nil, LoadProgress.DecodeBudget.Paused, b0);
        discard stepWith(groupA, "a" :: Nil, LoadProgress.DecodeBudget.Covered(50.0), a0);
        let b2 = stepWith(groupB, "door" :: Nil, LoadProgress.DecodeBudget.Paused, b1);
        let requestedAfterRelease = List.last(Ref.get(fake#requested));
        setState("a.glb", LoadProgress.LoadState.Downloaded, fake);
        let b3 = stepWith(groupB, "door" :: Nil, LoadProgress.DecodeBudget.Covered(50.0), b2);
        Assert.assertEq(expected = (Some("a.glb" :: Nil), LoadProgress.LoadState.Queued, LoadProgress.LoadState.Loaded),
                        (requestedAfterRelease, BackgroundLoad.stateOf("door", b2), BackgroundLoad.stateOf("door", b3)))
}
