// TestDeterminism — 決定性の門の部品: 記録が Frame の窓のフォーカスとパッドの機種を残すこと・閉じる時の World 全体の要約・
// 入力の台本（App.Internal.InputScript）・ギャラリーの場面の始まり（App.withShots）。
mod TestDeterminism {
    use GameEngine.Key

    import java.io.File

    /// 1 フレームの dt 0.02 秒・何も押していないフレームに、フォーカスと機種と pad を足した物。
    def frameWith(focused: Bool, kind: GamepadMap.PadKind, touched: Bool): App.Frame =
        { windowFocused = focused, padKind = kind, padTouched = touched, dt = 0.02 | App.emptyFrame() }

    /// 見た Frame の (フォーカス, 機種) をフレームごとに並べる World。
    def seenApp(): App.App[List[(Bool, GamepadMap.PadKind)], {}] =
        App.make(Nil) |> App.addSystem((frame, seen) -> List.append(seen, (frame#windowFocused, frame#padKind) :: Nil))

    def framesSeen(): List[App.Frame] =
        frameWith(true, GamepadMap.PadKind.Unknown, false) :: frameWith(false, GamepadMap.PadKind.Unknown, false) ::
        frameWith(false, GamepadMap.PadKind.Steam, true) :: frameWith(true, GamepadMap.PadKind.Steam, false) ::
        frameWith(true, GamepadMap.PadKind.Generic, true) :: Nil

    def recordInto(path: String, frames: List[App.Frame]): Unit \ IO =
        let rec = match Flow.Record.open(path) {
            case Some(opened) => opened
            case None         => bug!("記録を開けない")
        };
        frames |> List.forEach(frame -> Flow.Record.frame(rec, frame, None));
        Flow.Record.close(rec)

    def replayed(app: App.App[w, {}], w0: w, path: String): Result[String, w] \ Fs.FileRead =
        match Flow.Parse.parseFile(Flow.vocabOf(app, w0), path, Flow.Cli.readText) {
            case Err(problems) => Err(Flow.Parse.problemsText(problems))
            case Ok(script) => Flow.play(app, { design = Vec2.zero(), limit = 100 }, script, { world = w0, state = App.freshStepState() })
                                   |> Result.map(outcome -> outcome#last) |> Result.mapErr(failure -> failure#why)
        }

    // 記録に残した窓のフォーカスとパッドの機種は、再生で同じ Frame の欄に戻る。
    @Test
    def testRecordedFocusAndPadKindReplay(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/focus-pad.flow";
        recordInto(path, framesSeen());
        Assert.assertEq(expected = Ok(framesSeen() |> List.map(f -> (f#windowFocused, f#padKind))),
                        replayed(seenApp(), Nil, path))

    // フォーカスは変わったフレームにだけ focus= を書き、pad から出せない機種だけ padkind= を書く。
    @Test
    def testRecordWritesFocusAndPadKindOnlyWhenChanged(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/focus-lines.flow";
        recordInto(path, framesSeen());
        Assert.assertEq(expected = "wait 1f at=0.0,0.0 ns=20000000" :: "wait 1f focus=0 ns=20000000" ::
                                   "wait 1f pad padkind=steam ns=20000000" :: "wait 1f focus=1 ns=20000000" ::
                                   "wait 1f pad padkind=generic ns=20000000" :: Nil,
                        Fs.FileRead.readLines(path) |> Result.getWithDefault(Nil) |> List.drop(2))

    // 閉じる時の finish は、最後の指紋と World 全体の要約を書き、再生はそこまで通る。
    @Test
    def testFinishWritesWorldSummaryThatReplays(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/finish.flow";
        let rec = match Flow.Record.open(path) {
            case Some(opened) => opened
            case None         => bug!("記録を開けない")
        };
        let last = framesSeen() |> List.foldLeft((seen, frame) -> {
            Flow.Record.frame(rec, frame, None);
            List.append(seen, (frame#windowFocused, frame#padKind) :: Nil)
        }, Nil);
        Flow.Record.finish(rec, None, last);
        Flow.Record.close(rec);
        Assert.assertEq(expected = Ok(last), replayed(seenApp(), Nil, path))

    // 別の World で終わったなら、World 全体の要約の expect で止まる。
    @Test
    def testWorldSummaryCatchesADifferentWorld(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/finish-differs.flow";
        let rec = match Flow.Record.open(path) {
            case Some(opened) => opened
            case None         => bug!("記録を開けない")
        };
        Flow.Record.frame(rec, frameWith(true, GamepadMap.PadKind.Unknown, false), None);
        Flow.Record.finish(rec, None, (false, GamepadMap.PadKind.Unknown) :: Nil);
        Flow.Record.close(rec);
        Assert.assertTrue(Result.isErr(replayed(seenApp(), Nil, path)))

    // 画面なしで同じ flow を 2 回流すと、World 全体の要約が同じ（決定性の門の軽い方）。
    @Test
    def testSameFlowTwiceGivesSameWorld(): Unit \ Assert + Fs.FileRead =
        let twice = List.range(0, 2) |> List.map(_ -> match Flow.Parse.parseText(Flow.vocabOf(seenApp(), Nil), "twice",
                                                       "wait 3f pad\nwait 2f focus=0 padkind=steam\ntap Z\n") {
            case Err(problems) => Err(Flow.Parse.problemsText(problems))
            case Ok(script) => Flow.play(seenApp(), { design = Vec2.zero(), limit = 100 }, script, { world = Nil, state = App.freshStepState() })
                                   |> Result.map(outcome -> WorldHash.sha256Of(outcome#last)) |> Result.mapErr(failure -> failure#why)
        });
        Assert.assertEq(expected = 1, twice |> List.distinct |> List.filter(Result.isOk) |> List.length)

    // ========================================================================
    // World 全体の要約（WorldHash）
    // ========================================================================

    // 組んだ欄の順が違っても、同じ中身なら同じ字。
    @Test
    def testWorldHashIgnoresFieldOrder(): Unit \ Assert =
        Assert.assertEq(expected = WorldHash.sha256Of({ a = 1, b = "x", c = Some(2.5) }),
                        WorldHash.sha256Of({ c = Some(2.5), b = "x", a = 1 }))

    // 中身が 1 つ違えば違う字。
    @Test
    def testWorldHashSeesNestedValues(): Unit \ Assert =
        Assert.assertTrue(WorldHash.sha256Of({ a = 1, m = Map#{"k" => 1.0 :: Nil} }) !=
                          WorldHash.sha256Of({ a = 1, m = Map#{"k" => 1.5 :: Nil} }))

    // 作ったかどうかで変わる Lazy の中身は見ない（実機は描く時に作り、画面なしの再生は作らない）。
    @Test
    def testWorldHashSkipsLazy(): Unit \ Assert =
        let forced = lazy 1;
        let n = force forced;
        Assert.assertEq(expected = WorldHash.sha256Of({ a = n, l = lazy 1 }), WorldHash.sha256Of({ a = 1, l = forced }))

    // ========================================================================
    // 入力の台本（FLIX_GE_INPUT_SCRIPT）
    // ========================================================================

    def writeScript(path: String, text: String): Unit \ IO =
        discard (new File(path)).getParentFile().mkdirs();
        discard run { Fs.WriteFile.write({str = text}, path) } with Fs.WriteFile.runWithFileWrite with Fs.FileWrite.runWithIO

    // 台本は Flow.play と同じ Frame に開く（tap は 1 フレーム・focus= は書いた行から続く）。
    @Test
    def testScriptFramesFollowFlow(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/script.flow";
        writeScript(path, "ready off\ntap Z\nwait 2f focus=0\n");
        Assert.assertEq(expected = Ok((Set#{Key.Z} :: Set#{} :: Set#{} :: Nil, true :: false :: false :: Nil)),
                        App.Internal.InputScript.framesOf(path) |> Result.map(frames -> {
                            let list = Vector.toList(frames);
                            (List.map(f -> f#down, list), List.map(f -> f#windowFocused, list))
                        }))

    // 役の名前は World が要るので台本に書けない（読む時に理由つきで止まる）。
    @Test
    def testScriptRejectsRoles(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/script-role.flow";
        writeScript(path, "tap confirm\n");
        Assert.assertTrue(Result.isErr(App.Internal.InputScript.framesOf(path)))

    /// 外の handler の代わり: dt はいつも 0.5 秒・入力は何も押していない。
    def outside(f: Unit -> a \ ef + Platform.Input + Platform.FrameClock): a \ ef =
        run { f() } with handler Platform.Input {
            def isKeyPressed(_, k)         = k(false)
            def getMousePosition(k)        = k(Vec2.zero())
            def isMouseButtonPressed(_, k) = k(false)
            def isGamepadTouched(k)        = k(false)
            def gamepadSticks(k)           = k({ left = Vec2.zero(), right = Vec2.zero() })
            def gamepadKind(k)             = k(GamepadMap.PadKind.Unknown)
            def consumeScrollDelta(k)      = k(0.0)
            def consumeMouseDelta(k)       = k(Vec2.zero())
            def isWindowFocused(k)         = k(true)
        } with handler Platform.FrameClock {
            def getDeltaTime(k) = k(Duration.seconds(0.5))
        }

    // getDeltaTime を呼ぶたびに台本の次のフレームへ進み、dt は外の時計のまま。流し終えると isFinished。
    @Test
    def testDriveCountsFramesByDeltaTime(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/script-drive.flow";
        writeScript(path, "ready off\nwait 1f\ntap Z\nwait 1f wheel=2\n");
        match App.Internal.InputScript.load(path) {
            case Err(why) => bug!(why)
            case Ok(player) =>
                let seen = outside(() -> App.Internal.InputScript.drive(player, () ->
                    List.range(0, 4) |> List.map(_ -> {
                        let dt = Duration.toSeconds(Platform.FrameClock.getDeltaTime());
                        let z = Platform.Input.isKeyPressed(Key.Z);
                        let wheel = Platform.Input.consumeScrollDelta();
                        let again = Platform.Input.consumeScrollDelta();
                        (dt, z, wheel + again)
                    })));
                Assert.assertEq(expected = ((0.5, false, 0.0) :: (0.5, true, 0.0) :: (0.5, false, 2.0) :: (0.5, false, 0.0) :: Nil, true),
                                (seen, App.Internal.InputScript.isFinished(player)))
        }

    // InputScript の lstick= / rstick= は、系が読む前の Platform.Input.gamepadSticks に戻る（実機のランナーが毎コマ読む op）。
    @Test
    def testDriveAnswersSticksFromScript(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/script-sticks.flow";
        writeScript(path, "ready off\nwait 1f lstick=0.5,-0.25 rstick=0.0,1.0\nwait 1f\n");
        match App.Internal.InputScript.load(path) {
            case Err(why) => bug!(why)
            case Ok(player) =>
                let seen = outside(() -> App.Internal.InputScript.drive(player, () ->
                    List.range(0, 2) |> List.map(_ -> {
                        discard Platform.FrameClock.getDeltaTime();
                        let sticks = Platform.Input.gamepadSticks();
                        ((sticks#left#x, sticks#left#y), (sticks#right#x, sticks#right#y))
                    })));
                Assert.assertEq(expected = (((0.5, -0.25), (0.0, 1.0)) :: ((0.0, 0.0), (0.0, 0.0)) :: Nil), seen)
        }

    /// 見た Frame のスティックを足していく World（左の x と y・右の x と y）。
    def stickApp(): App.App[List[(Float64, Float64, Float64, Float64)], {}] =
        App.make(Nil) |> App.addSystem((frame, seen) ->
            List.append(seen, (frame#leftStick#x, frame#leftStick#y, frame#rightStick#x, frame#rightStick#y) :: Nil))

    def stickFrames(): List[App.Frame] =
        { leftStick = { x = 0.5, y = -0.25 }, dt = 0.02 | App.emptyFrame() } ::
        { dt = 0.02 | App.emptyFrame() } ::
        { rightStick = { x = -1.0, y = 0.0625 }, dt = 0.02 | App.emptyFrame() } :: Nil

    // 記録に残したスティックは、再生で同じ値の Frame が系へ届く。
    @Test
    def testRecordedSticksReplay(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/sticks.flow";
        recordInto(path, stickFrames());
        Assert.assertEq(expected = Ok((0.5, -0.25, 0.0, 0.0) :: (0.0, 0.0, 0.0, 0.0) :: (0.0, 0.0, -1.0, 0.0625) :: Nil),
                        replayed(stickApp(), Nil, path))

    // (0, 0) のコマには lstick= も rstick= も書かない（スティックを使わない記録の字は変わらない）。
    @Test
    def testRecordOmitsZeroSticks(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/sticks-zero.flow";
        recordInto(path, stickFrames());
        let lines = Fs.FileRead.readLines(path) |> Result.getWithDefault(Nil);
        let withLeft = List.count(line -> String.contains(substr = "lstick=0.5,-0.25", line), lines);
        let withRight = List.count(line -> String.contains(substr = "rstick=-1.0,0.0625", line), lines);
        let anyStick = List.count(line -> String.contains(substr = "stick=", line), lines);
        Assert.assertEq(expected = (1, 1, 2), (withLeft, withRight, anyStick))

    // ========================================================================
    // ギャラリーの場面の始まり（App.withShots）
    // ========================================================================

    def shotApp(): App.App[Int32, {}] =
        App.make(0)
            |> App.withStarts({ name = "play", doc = "", args = Map.empty(), build = (w, _) -> Ok(w) } :: Nil)
            |> App.withShots({ name = "ten", doc = "10 の場面", args = Map.empty(), build = (_, _) -> Ok(10) } :: Nil)

    // shot:<名前> で場面を組め、始まりの一覧には混ざらない。
    @Test
    def testShotStartBuildsTheScene(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = (Ok(10), "play" :: Nil, "shot:ten" :: Nil),
                        (App.buildStart(shotApp(), Vec2.zero(), "shot:ten", Map.empty()), App.startNames(shotApp()),
                         App.shotNames(shotApp()) |> List.map(App.shotStartName)))

    // 知らない場面は shot の名前の案つきで止まる。
    @Test
    def testUnknownShotSuggests(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("ギャラリーの場面 'tem' は App.withShots に無い（もしかして: ten）"),
                        App.buildStart(shotApp(), Vec2.zero(), "shot:tem", Map.empty()))

    // withWorldSummaryMask で置き換えた欄は、World 全体の要約に効かない。
    @Test
    def testSummaryMaskHidesTheField(): Unit \ Assert =
        let app: App.App[{ clock = Int64, n = Int32 }, {}] =
            App.make({ clock = 0i64, n = 1 }) |> App.withWorldSummaryMask(w -> { clock = 0i64 | w });
        Assert.assertEq(expected = Flow.valueOf(app, "world", { clock = 0i64, n = 1 }),
                        Flow.valueOf(app, "world", { clock = 1786735920i64, n = 1 }))

    // Resources.shotsOf の始まりは、描き出しと同じ worldOf の World を組み、描く元はそのまま。
    @Test
    def testShotsOfBuildsWorldOf(): Unit \ Assert + Fs.FileRead =
        let app = App.make(Resources.of("res", 0))
            |> App.withShots(Resources.shotsOf("seven" :: Nil, (name, res) -> if (name == "seven" and res == "res") Some(7) else None));
        Assert.assertEq(expected = Ok(("res", 7)),
                        App.buildStart(app, Vec2.zero(), "shot:seven", Map.empty()) |> Result.map(h -> (h#resources, h#world)))

    // 押した瞬間だけを指す付け足しは、台本では効かないので読む時に止める。
    @Test
    def testScriptRejectsEdgeOptions(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/script-edge.flow";
        writeScript(path, "wait 1f new=Z\n");
        Assert.assertTrue(Result.isErr(App.Internal.InputScript.framesOf(path)))

    // gallery/<名前>.json は shot:<名前> の始まりと 8 字の指紋と版を書く。
    @Test
    def testShotRecordText(): Unit \ Assert =
        Assert.assertEq(expected = "{\n  \"start\": \"shot:quit\",\n  \"args\": {},\n  \"flow\": null,\n  \"frames\": 0,\n" +
                                   "  \"fingerprint\": \"${Flow.fingerprintOf("Title")}\",\n  \"engineVersion\": \"0.83.0\"\n}\n",
                        App.Headless.shotRecordText("quit", Some("Title"), "0.83.0"))

    // GET /shots はギャラリーの場面を shot:<場面> の名前で並べる。
    @Test
    def testShotsText(): Unit \ Assert =
        Assert.assertEq(expected = "shot:ten\t10 の場面\n", App.RemoteDebug.shotsText(shotApp()))

    // 数の配列（Vector）は中身ごと要約に入る: 1 つ違えば違う字。
    @Test
    def testWorldHashSeesNumberArrays(): Unit \ Assert =
        Assert.assertTrue(WorldHash.sha256Of({ v = Vector#{1, 2, 3}, d = Vector#{0.5, 1.5} }) !=
                          WorldHash.sha256Of({ v = Vector#{1, 2, 4}, d = Vector#{0.5, 1.5} }))

    // 同じ中身の数の配列は、別に作っても同じ字。
    @Test
    def testWorldHashSameNumberArrays(): Unit \ Assert =
        Assert.assertEq(expected = WorldHash.sha256Of({ d = Vector#{0.5, 1.5} }),
                        WorldHash.sha256Of({ d = List.toVector(0.5 :: 1.5 :: Nil) }))

    // 記録が書く要約（summaryOf）と再生が比べる要約（sha256Of）は同じ字。
    @Test
    def testSummaryMatchesSha(): Unit \ Assert =
        let world = { a = 1, v = Vector#{1.5, 2.5}, m = Map#{"k" => Some(3)} };
        Assert.assertEq(expected = WorldHash.sha256Of(world), fst(WorldHash.summaryOf(world, 3)))
}
