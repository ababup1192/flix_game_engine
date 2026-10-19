// TestFlow — flow の読み手（Flow.Parse）と実行器（Flow.play）を、数えるだけの小さなゲームで固定する。
// ゲーム: Z（役 confirm）を押すと数が 1 増え、返事の番号が進み、1 秒は受け付けない（busy）。X（役 cancel）は何もしない。
// fps 4（1 フレーム 0.25 秒）で流すと、受け付けない間はちょうど 4 フレーム（時刻が 0.25 の倍数なので丸めが出ない）。
mod TestFlow {
    use GameEngine.Key

    type alias Counter = { n = Int32, t = Float64, busyUntil = Float64, replies = Int64 }

    def start(): Counter = { n = 0, t = 0.0, busyUntil = 0.0, replies = 0i64 }

    def isBusy(w: Counter): Bool = w#t < w#busyUntil

    def step(frame: App.Frame, w: Counter): Counter =
        let pressed = App.justPressed(Key.Z, frame) and not isBusy(w);
        let counted = if (pressed) { n = w#n + 1, busyUntil = w#t + 1.0, replies = w#replies + 1i64 | w } else w;
        { t = counted#t + frame#dt | counted }

    def table(): Flow.Table[Counter] =
        { roles = _ -> (Key.Z, "confirm") :: (Key.X, "cancel") :: Nil,
          probes = { name = "n", doc = "押した数", read = Flow.Probe.Num(w -> Int32.toFloat64(w#n)) } ::
                   { name = "busy", doc = "受け付けない間", read = Flow.Probe.Flag(isBusy) } :: Nil,
          drives = { name = "masher", doc = "1 秒待つごとに決定", act = (waited, _) ->
                       if (waited >= 1.0) Flow.DriveAct.Tap("confirm") else Flow.DriveAct.Idle } :: Nil,
          ready = Some(w -> if (isBusy(w)) Flow.Ready.Busy("数えた直後") else Flow.Ready.Ready),
          replies = Some(w -> w#replies) | Flow.emptyTable() }

    def app(): App.App[Counter, {}] =
        App.make(start()) |> App.addSystem(step) |> App.withFlow(table())

    def vocab(): Flow.Vocab = Flow.vocabOf(app(), start())

    /// 本文を読んで流した結果を (押した数, フレーム数) か (止まった行, 理由) にする。
    def played(text: String): Result[(Int32, String), (Int32, Int32)] \ Fs.FileRead =
        match Flow.Parse.parseText(vocab(), "body", text) {
            case Err(problems) => Err((0, Flow.Parse.problemsText(problems)))
            case Ok(script) => match Flow.play(app(), { design = Vec2.zero(), limit = 1000 }, script,
                                               { world = start(), state = App.freshStepState() }) {
                case Ok(outcome)  => Ok((outcome#last#n, List.length(outcome#frames)))
                case Err(failure) => Err((failure#at#number, failure#why))
            }
        }

    /// 読めない行の理由（1 件目）。
    def problemOf(text: String): String =
        match Flow.Parse.parseText(vocab(), "body", text) {
            case Err(p :: _) => p#why
            case _           => "（読めた）"
        }

    // ========================================================================
    // 読み手: 閉じた手の語・近い名前の案・max の必須
    // ========================================================================

    // 知らない手の語には近い語の案が付く。
    @Test
    def testUnknownVerbSuggestsANearVerb(): Unit \ Assert =
        Assert.assertEq(expected = "手 'tpa' は無い（もしかして: tap）", problemOf("tpa confirm"))

    // 役の書き間違いには、表の役の名前から案が付く。
    @Test
    def testUnknownRoleSuggestsTheRole(): Unit \ Assert =
        Assert.assertEq(expected = "役かキー 'confrm' は無い（もしかして: confirm）", problemOf("tap confrm"))

    // until は max が無いと読まない（打ち切りの無い待ちを書かせない）。
    @Test
    def testUntilNeedsMax(): Unit \ Assert =
        Assert.assertEq(expected = "until は 'until <問い> max <秒>'（max は必須）", problemOf("until n>=1"))

    // 数の問いを真偽のように書くと、比べて書くよう言う。
    @Test
    def testNumberProbeMustBeCompared(): Unit \ Assert =
        Assert.assertEq(expected = "問い n は真偽でない。比べて書く（n=… / n>=…）", problemOf("until n max 1"))

    // 前の /step の書き方（idle N・press K）は、flow の書き方を名指しして断る。
    @Test
    def testOldStepFormsNameTheNewForm(): Unit \ Assert =
        Assert.assertEq(expected = ("idle は無い。'wait 30f' と書く（N フレーム何も触らない）", "press は無い。'tap Z' と書く"),
                        (problemOf("idle 30"), problemOf("press Z")))

    // ========================================================================
    // 実行器: 自動の待ち・返事・打ち切り・操作
    // ========================================================================

    // ready on（ready を宣言したゲームの既定）: 2 回目の tap は受け付ける所まで自動で待つ。
    // 押す 1 + 受け付けない間（押した後 1 秒 = 時刻 1.0 まで）の 3 + 押す 1 = 5 フレームで 2 回数える。
    @Test
    def testTapWaitsUntilReady(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Ok((2, 5)), played("fps 4\ntap confirm\ntap confirm"))

    // ready off: 待たずに押す（同じキーなので間に離す 1 フレームだけ挟む）。受け付けない間の 2 回目は数えない（3 フレームで 1 回）。
    @Test
    def testReadyOffPressesAtOnce(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Ok((1, 3)), played("fps 4\nready off\ntap confirm\ntap confirm"))

    // 押したのに返事の番号が進まない（cancel は何もしない）と、押した行の番号つきで失敗する。
    @Test
    def testUnansweredTapFailsAtItsLine(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err((2, "押したが受け付けられなかった（返事の番号が進まない）")),
                        played("fps 4\ntap cancel"))

    // until の打ち切りは失敗（max 1 秒 = 4 フレーム待っても数が増えない）。
    @Test
    def testUntilFailsAtMax(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err((2, "待ちが max（4 フレーム）に当たった: n>=1")), played("fps 4\nuntil n>=1 max 1"))

    // 名前付きの操作は、待った秒（押すと 0 に戻る）を見て押す: 1 秒（4 フレーム）待って押すのを 2 回 = 10 フレームで n=2
    // （2 回目は時刻 2.25 —— 受け付けない間の 2.0 を過ぎている）。
    @Test
    def testDrivePressesUntilTheProbeHolds(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Ok((2, 10)), played("fps 4\ndrive masher until n>=2 max 5"))

    // expect はフレームを使わずに確かめる。
    @Test
    def testExpectFailsWithoutUsingFrames(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = (Ok((1, 1)), Err((3, "expect が立たない: n=2"))),
                        (played("fps 4\ntap confirm\nexpect n=1"), played("fps 4\ntap confirm\nexpect n=2")))

    // 記録の生のフレーム: ns= の数だけフレームを使い、それぞれの経過秒はナノ秒の値（0.25 秒 × 3 = 3 フレーム）。
    @Test
    def testRecordedFramesUseTheirNanoseconds(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Ok((1, 4)),
                        played("ready off\ntap Z ns=250000000\nwait 3f ns=250000000,250000000,250000000"))

    // ========================================================================
    // Go の bin/fge flow check と同じ文面（testdata/lint/flow-check の見本を両方が読む）
    // ========================================================================

    /// testdata/lint/flow-check/vocab.json と同じ語彙。
    def goVocab(): Flow.Vocab =
        { roles = "confirm" :: "cancel" :: Nil,
          probes = ("n", Flow.Kind.Num, "押した数") :: ("busy", Flow.Kind.Flag, "受け付けない間") :: ("phase", Flow.Kind.Text, "場面") :: Nil,
          drives = ("masher", "1 秒待つごとに決定") :: Nil,
          starts = ("count", "n を足す", Map#{"n" => "1"}) :: Nil,
          options = ("look", "day" :: "night" :: Nil) :: Nil,
          keys = "A" :: "B" :: "X" :: "Z" :: "Up" :: "Down" :: "Left" :: "Right" :: "Enter" :: "Space" :: "Escape" :: Nil,
          ready = true, replies = true, fingerprint = true }

    // 書き間違いの見本を読むと、Go の check の expected.txt（1 行目の件数と最後の終わりの番号を除く）と同じ知らせになる。
    @Test
    def testParseMatchesTheGoCheck(): Unit \ Assert + Fs.FileRead =
        let dir = "../../testdata/lint/flow-check/typos-fire";
        let input = Fs.FileRead.read("${dir}/input.flow") |> Result.getWithDefault("");
        let expected = Fs.FileRead.read("${dir}/expected.txt") |> Result.getWithDefault("")
            |> String.lines |> List.drop(1) |> List.filter(line -> not String.startsWith(prefix = "[exit=", line)) |> String.intercalate("\n");
        let got = match Flow.Parse.parseText(goVocab(), "testdata/lint/flow-check/typos-fire/input.flow", input) {
            case Err(problems) => Flow.Parse.problemsText(problems)
            case Ok(_)         => "（読めた）"
        };
        Assert.assertEq(expected = String.trim(expected), got)

    // ========================================================================
    // 記録（Flow.Record）: 流したフレームを書き、読んで流し直すと同じ World・指紋が合う
    // ========================================================================

    /// 指紋つきの App（記録が 60 フレームごとに expect fp= を書く）。
    def recordedApp(): App.App[Counter, {}] =
        app() |> App.withFingerprint(w -> "n=${w#n}|t=${w#t}")

    // 手書きの flow（決定を 2 回・待ち・決定を押し続ける）を流したフレームを全部記録し、記録を流し直すと
    // （fps 50 = 1 フレーム 0.02 秒。ナノ秒で書いて読み戻しても同じ秒になる —— 実機の経過もナノ秒から来る）
    // 押した数とフレーム数が同じで、途中の expect fp= も全部立つ（指紋が 1 つでも違えば失敗する）。
    @Test
    def testRecordReplaysToTheSameWorld(): Unit \ Assert + Fs.FileRead + IO =
        let path = "build/flow-test/record.flow";
        let original = match Flow.Parse.parseText(vocab(), "body", "fps 50\ntap confirm\nwait 1.5\ntap confirm\nhold confirm 0.5\nwait 1") {
            case Ok(script) => match Flow.play(recordedApp(), { design = Vec2.zero(), limit = 1000 }, script,
                                               { world = start(), state = App.freshStepState() }) {
                case Ok(outcome) => outcome
                case Err(failure) => bug!(failure#why)
            }
            case Err(problems) => bug!(Flow.Parse.problemsText(problems))
        };
        let rec = match Flow.Record.open(path) {
            case Some(opened) => opened
            case None         => bug!("記録を開けない")
        };
        original#frames |> List.forEach(played -> Flow.Record.frame(rec, played#step#frame, Some("n=${played#step#after#n}|t=${played#step#after#t}")));
        Flow.Record.close(rec);
        let replayed = match Flow.Parse.parseFile(Flow.vocabOf(recordedApp(), start()), path, Flow.Cli.readText) {
            case Ok(script) => Flow.play(recordedApp(), { design = Vec2.zero(), limit = 1000 }, script,
                                         { world = start(), state = App.freshStepState() })
                                   |> Result.map(outcome -> (outcome#last#n, List.length(outcome#frames)))
                                   |> Result.mapErr(failure -> failure#why)
            case Err(problems) => Err(Flow.Parse.problemsText(problems))
        };
        Assert.assertEq(expected = Ok((original#last#n, List.length(original#frames))), replayed)
}
