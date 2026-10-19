// TestHeadless — 窓なしのゲームの常駐（App.Headless）の純粋な芯: /run の本文の env の解き方・流れの行の形・
// /hello の本文・起動時の入口の照合・寿命の幅と延ばし方・resident.json の読み書き・入口の名前の組み方。

mod TestHeadless {

    // ========================================================================
    // 入口の束: 名前と種類
    // ========================================================================

    /// job は静止画・videoJob は動画で、名前はどちらも "<モジュール>.<関数>"。
    @Test
    def testJobNamesJoinModuleAndFunction(): Unit \ Assert =
        let still = App.Headless.job("SceneRender", "one", _ -> checked_ecast(0));
        let video = App.Headless.videoJob("FlowVideo", "play", _ -> checked_ecast(0));
        Assert.assertEq(
            expected = (("SceneRender.one", App.Headless.JobKind.Still), ("FlowVideo.play", App.Headless.JobKind.Video)),
            ((still#name, still#kind), (video#name, video#kind)))

    // ========================================================================
    // /run の本文と流れの行
    // ========================================================================

    /// 値の中の = は残し、= の無い行と鍵が空の行は捨てる。
    @Test
    def testParseEnvLinesKeepsEqualsInValues(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{ "SHOT" => "title choice", "OPTS" => "-Da=1" },
            App.Headless.parseEnvLines("SHOT=title choice\nOPTS=-Da=1\nnoequals\n=empty-key\n"))

    /// [shot] の答えから ok png= の行のパスを取り出す（行の前後の空白は落とす）。
    @Test
    def testPngPathOfReadsOkPngLine(): Unit \ Assert =
        Assert.assertEq(expected = Some("debug/shot/shot-42.png"),
            App.Headless.pngPathOf("[shot]\nok png=debug/shot/shot-42.png\n"))

    /// 撮った答えが書いたファイルは PNG と隣の items.tsv。
    @Test
    def testShotFilesOfIsPngAndItemsTable(): Unit \ Assert =
        Assert.assertEq(expected = "debug/shot/shot-42.png" :: "debug/shot/shot-42.items.tsv" :: Nil,
            App.Headless.shotFilesOf("[shot]\nok png=debug/shot/shot-42.png\n"))

    /// 撮れなかった答え（ok png= の行が無い）は None。
    @Test
    def testPngPathOfWithoutOkPngIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, App.Headless.pngPathOf("[shot]\nerror: no view\n"))

    /// 空の値（KEY=）は空の字として残る。
    @Test
    def testParseEnvLinesKeepsEmptyValue(): Unit \ Assert =
        Assert.assertEq(expected = Map#{ "FLOW" => "" }, App.Headless.parseEnvLines("FLOW="))

    /// 出力の行は o / e の 1 字と空白を頭に付け、改行で終わる（入口が "x 0" を出しても終わりの印と取り違えない）。
    @Test
    def testOutAndErrLinesArePrefixed(): Unit \ Assert =
        Assert.assertEq(
            expected = ("o x 0\n", "e boom\n"),
            (App.Headless.outLine("x 0"), App.Headless.errLine("boom")))

    /// 終わりの印の字（Go の常駐クライアントと取り決めた形）。
    @Test
    def testEndLinesMatchContract(): Unit \ Assert =
        Assert.assertEq(
            expected = "x 0\n" :: "x 3\n" :: "x oom\n" :: "x stale\n" :: "x busy\n" :: "x unknown-entry\n" :: "x needs-gl\n" :: Nil,
            List.map(App.Headless.endLine,
                App.Headless.RunEnd.Exited(0) :: App.Headless.RunEnd.Exited(3) :: App.Headless.RunEnd.Oom ::
                App.Headless.RunEnd.Stale :: App.Headless.RunEnd.Busy :: App.Headless.RunEnd.UnknownEntry ::
                App.Headless.RunEnd.NeedsGl :: Nil))

    // ========================================================================
    // /hello
    // ========================================================================

    /// env の行は LANG・LC_*・HEADLESS_* の順に出し、それ以外の鍵は出さない。
    @Test
    def testPassedEnvOrdersLangThenLocaleThenHeadless(): Unit \ Assert =
        Assert.assertEq(
            expected = ("LANG", "ja_JP.UTF-8") :: ("LC_ALL", "C") :: ("HEADLESS_PORT", "0") :: ("HEADLESS_RESIDENT", "1") :: Nil,
            App.Headless.passedEnv(Map#{ "HEADLESS_RESIDENT" => "1", "PATH" => "/bin", "LANG" => "ja_JP.UTF-8",
                                         "LC_ALL" => "C", "HEADLESS_PORT" => "0", "HOME" => "/home" }))

    /// 塗りの取り置きの置き場（FGE_RENDER_CACHE）も名乗る（クライアントが要求の値と比べて、違えば立て直す）。
    @Test
    def testPassedEnvNamesRenderCache(): Unit \ Assert =
        Assert.assertEq(
            expected = ("FGE_RENDER_CACHE", "off") :: Nil,
            App.Headless.passedEnv(Map#{ "FGE_RENDER_CACHE" => "off", "SHOT" => "title" }))

    /// /hello の本文は取り決めの順（名乗り・数・寿命・env・job）。
    @Test
    def testHelloTextFollowsContractOrder(): Unit \ Assert =
        let hello = { pid = "123", dir = "/abs/game", manifest = "abc", served = 7i64, busy = "",
                      idleLeft = 170i64, idleWindow = 180i64, env = Map#{ "LANG" => "ja_JP.UTF-8", "PATH" => "/bin" },
                      jobs = ("SceneRender.one", App.Headless.JobKind.Still) :: ("FlowVideo.play", App.Headless.JobKind.Video) :: Nil };
        Assert.assertEq(
            expected = "ok hello\npid=123\ndir=/abs/game\nmanifest=abc\nserved=7\nbusy=\nidle.left=170\nidle.window=180\n"
                     + "env.LANG=ja_JP.UTF-8\njob=SceneRender.one still\njob=FlowVideo.play video\n",
            App.Headless.helloText(hello))

    // ========================================================================
    // 起動時の照合
    // ========================================================================

    /// HEADLESS_ENTRIES が空なら照合しない。
    @Test
    def testMissingEntriesSkipsWhenNotDeclared(): Unit \ Assert =
        Assert.assertEq(expected = Nil, App.Headless.missingEntries("  ", "SceneRender.one" :: Nil))

    /// HEADLESS_ENTRIES に無い束の名前だけを、束の順に返す。
    @Test
    def testMissingEntriesListsUndeclaredNames(): Unit \ Assert =
        Assert.assertEq(
            expected = "SceneRender.all" :: "FlowVideo.play" :: Nil,
            App.Headless.missingEntries("E2e.play SceneRender.one",
                "SceneRender.one" :: "SceneRender.all" :: "FlowVideo.play" :: Nil))

    // ========================================================================
    // 寿命
    // ========================================================================

    /// 常駐の既定は /run の後 180 秒・会話の後 600 秒、常駐でなければどちらも 600 秒。
    @Test
    def testIdleWindowsDefaults(): Unit \ Assert =
        Assert.assertEq(
            expected = ((180i64, 600i64), (600i64, 600i64)),
            (App.Headless.idleWindowsOf(true, Map.empty()) |> (w -> (w#work, w#talk)),
             App.Headless.idleWindowsOf(false, Map.empty()) |> (w -> (w#work, w#talk))))

    /// HEADLESS_IDLE_SECS と HEADLESS_TALK_IDLE_SECS で幅を変えられる（常駐でなければ TALK は見ない）。
    @Test
    def testIdleWindowsReadEnv(): Unit \ Assert =
        let env = Map#{ "HEADLESS_IDLE_SECS" => "30", "HEADLESS_TALK_IDLE_SECS" => "90" };
        Assert.assertEq(
            expected = ((30i64, 90i64), (30i64, 30i64)),
            (App.Headless.idleWindowsOf(true, env) |> (w -> (w#work, w#talk)),
             App.Headless.idleWindowsOf(false, env) |> (w -> (w#work, w#talk))))

    /// 常駐では /start・/step・/state だけが会話の幅で延ばし、常駐でなければどの要求も延ばす。
    @Test
    def testTalkWindowOnlyForTalkPathsWhenResident(): Unit \ Assert =
        let windows = { work = 180i64, talk = 600i64 };
        Assert.assertEq(
            expected = (Some(600i64), None, None, Some(600i64)),
            (App.Headless.talkWindowOf(true, windows, "/step"), App.Headless.talkWindowOf(true, windows, "/starts"),
             App.Headless.talkWindowOf(true, windows, "/help"), App.Headless.talkWindowOf(false, windows, "/help")))

    /// 今の寿命より先まで取れる時だけ取り直し、短い幅で縮めない（会話の 600 秒の途中の /run は 180 秒に戻さない）。
    @Test
    def testExtendLeaseNeverShortens(): Unit \ Assert =
        let talked = App.Headless.extendLease(0i64, 600i64, { deadline = 0i64, window = 180i64 });
        let worked = App.Headless.extendLease(100_000_000_000i64, 180i64, talked);
        let later = App.Headless.extendLease(500_000_000_000i64, 180i64, talked);
        Assert.assertEq(
            expected = ((600_000_000_000i64, 600i64), (600_000_000_000i64, 600i64), (680_000_000_000i64, 180i64)),
            ((talked#deadline, talked#window), (worked#deadline, worked#window), (later#deadline, later#window)))

    /// 残りの秒は切り捨てで、切れた後は 0。
    @Test
    def testIdleLeftSecsFloorsAndStopsAtZero(): Unit \ Assert =
        let lease = { deadline = 10_500_000_000i64, window = 180i64 };
        Assert.assertEq(
            expected = (10i64, 0i64),
            (App.Headless.idleLeftSecs(0i64, lease), App.Headless.idleLeftSecs(20_000_000_000i64, lease)))

    // ========================================================================
    // resident.json
    // ========================================================================

    /// 書いた resident.json から pid を読み戻せる（消すのは自分の pid の時だけ）。
    @Test
    def testResidentTextRoundTripsPid(): Unit \ Assert =
        let text = App.Headless.residentText({ pid = "4321", port = "45678", dir = "/abs/game",
                                               manifest = "abc", started = "2026-10-19T00:00:00Z" });
        Assert.assertEq(expected = Some("4321"), App.Headless.residentPidOf(text))

    /// 壊れた中身からは pid を読まない（他人の常駐の印を消さない）。
    @Test
    def testResidentPidOfBrokenTextIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, App.Headless.residentPidOf("{ not json"))
}
