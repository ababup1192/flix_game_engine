// LoadProgress の知らせの並び・結果の並び・例外・時間切れの知らせを、知らせを集める handler の中で確かめる。
mod TestLoadProgress {
    import java.lang.Thread

    /// f を流し、届いた知らせを (phase, done, total) の並びで結果と一緒に返す。
    pub def collecting(f: Unit -> a \ ef + LoadProgress): (a, List[(String, Int32, Int32)]) \ ef =
        region rc {
            let seen = MutList.empty(rc);
            let result = run f() with handler LoadProgress {
                def report(phase, done, total, k) = { MutList.push((phase, done, total), seen); k(()) }
            };
            (result, MutList.toList(seen))
        }

    def threeChars(): List[String] = "a" :: "b" :: "c" :: Nil

    @Test
    def testMapReportsEachStep(): Unit \ Assert =
        let (_, seen) = collecting(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, threeChars()));
        Assert.assertEq(expected = ("p", 0, 3) :: ("p", 1, 3) :: ("p", 2, 3) :: ("p", 3, 3) :: Nil, seen)

    @Test
    def testMapKeepsResultOrder(): Unit \ Assert =
        let (ys, _) = collecting(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, threeChars()));
        Assert.assertEq(expected = "A" :: "B" :: "C" :: Nil, ys)

    @Test
    def testMapOfEmptyReportsNothing(): Unit \ Assert =
        let (_, seen) = collecting(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, (Nil: List[String])));
        Assert.assertEq(expected = Nil, seen)

    @Test
    def testRunNoopReturnsValue(): Unit \ Assert =
        let ys = LoadProgress.runNoop(() -> LoadProgress.mapWithProgress("p", String.toUpperCase, threeChars()));
        Assert.assertEq(expected = "A" :: "B" :: "C" :: Nil, ys)

    /// 後ろの要素ほど早く終わる仕事（並びが届いた順でなく xs の順に戻ることを見る）。
    def slowerFirst(x: Int32): Int32 \ IO =
        Thread.sleep(Int32.toInt64((5 - x) * 5));
        x * 10

    @Test
    def testParMapKeepsResultOrder(): Unit \ {Assert, IO} =
        let (ys, _) = collecting(() -> LoadProgress.parMapWithProgress("p", slowerFirst, List.range(0, 5)));
        Assert.assertEq(expected = 0 :: 10 :: 20 :: 30 :: 40 :: Nil, ys)

    @Test
    def testParMapStartsAtZero(): Unit \ {Assert, IO} =
        let (_, seen) = collecting(() -> LoadProgress.parMapWithProgress("p", slowerFirst, List.range(0, 5)));
        Assert.assertEq(expected = Some(("p", 0, 5)), List.head(seen))

    @Test
    def testParMapEndsAtTotal(): Unit \ {Assert, IO} =
        let (_, seen) = collecting(() -> LoadProgress.parMapWithProgress("p", slowerFirst, List.range(0, 5)));
        Assert.assertEq(expected = Some(("p", 5, 5)), List.last(seen))

    @Test
    def testParMapDoneGrowsOneByOne(): Unit \ {Assert, IO} =
        let (_, seen) = collecting(() -> LoadProgress.parMapWithProgress("p", slowerFirst, List.range(0, 5)));
        let dones = List.map(s -> { let (_, done, _) = s; done }, seen);
        Assert.assertEq(expected = List.range(0, 6), List.distinct(dones))

    @Test
    def testParMapOfEmptyReportsNothing(): Unit \ {Assert, IO} =
        let (ys, seen) = collecting(() -> LoadProgress.parMapWithProgress("p", slowerFirst, Nil));
        Assert.assertEq(expected = (Nil, Nil), (ys, seen))
}

// 非 pub の parMapPolling（待つ時間と待つ回数の上限を取る）を、上限つきで確かめる。
mod LoadProgress.TestPolling {
    import java.lang.{InterruptedException, RuntimeException, Thread}
    import java.util.concurrent.atomic.AtomicBoolean

    /// 2 だけ、時間切れの知らせが何度か出た後で投げる（知らせから戻った後の例外を通す）。
    def failOnTwo(x: Int32): Int32 \ IO =
        if (x == 2) { Thread.sleep(20i64); throw new RuntimeException("two") } else x

    @Test
    def testExceptionEndsBeforeTheWaitLimit(): Unit \ {Assert, IO} =
        let outcome = try {
            match LoadProgress.runNoop(() -> LoadProgress.parMapPolling(1i64, 2000, "p", failOnTwo, List.range(0, 4))) {
                case Some(_) => "finished"
                case None    => "hit the wait limit"
            }
        } catch {
            case e: RuntimeException => e.getMessage()
        };
        Assert.assertEq(expected = "two", outcome)

    /// 0 は 20 ms で投げ、1 は長く眠る。1 が途中で起こされたら interrupted に印を付ける。
    def failOrSleep(interrupted: AtomicBoolean, x: Int32): Int32 \ IO =
        if (x == 0) { Thread.sleep(20i64); throw new RuntimeException("zero") }
        else {
            try { Thread.sleep(5000i64) } catch {
                case _: InterruptedException => interrupted.set(true)
            };
            x
        }

    /// interrupted に印が付くまで最大 1 秒待つ。
    def waitForMark(interrupted: AtomicBoolean, left: Int32): Bool \ IO =
        if (interrupted.get() or left <= 0) interrupted.get()
        else { Thread.sleep(10i64); waitForMark(interrupted, left - 1) }

    @Test
    def testExceptionStopsTheRestOfThePool(): Unit \ {Assert, IO} =
        let interrupted = new AtomicBoolean(false);
        discard try {
            discard LoadProgress.runNoop(() -> LoadProgress.parMapPolling(1i64, 2000, "p", failOrSleep(interrupted), 0 :: 1 :: Nil));
            ""
        } catch {
            case e: RuntimeException => e.getMessage()
        };
        Assert.assertTrue(waitForMark(interrupted, 100))

    def sleepy(x: Int32): Int32 \ IO =
        Thread.sleep(30i64);
        x

    @Test
    def testTimeoutRepeatsTheSameDone(): Unit \ {Assert, IO} =
        let (_, seen) = TestLoadProgress.collecting(() -> LoadProgress.parMapPolling(1i64, 2000, "p", sleepy, 0 :: Nil));
        let zeros = List.count(s -> { let (_, done, _) = s; done == 0 }, seen);
        Assert.assertTrue(zeros >= 2)
}
