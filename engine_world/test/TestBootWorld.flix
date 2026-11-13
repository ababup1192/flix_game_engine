// 起動の World（非 pub の App.Internal.Runner.bootFrom・App.Internal.Runner.buildBootRecord）が、記録しない起動では Doc を読み直さず、
// 記録する起動では start の行に載せた中身で、再生（Flow.play の start）が同じ World から始まること。
// デスクトップの組（START の行）とブラウザ版の組（URL のクエリから組んだ始まり）が、頼む始まりをどう渡すか。
mod App.Internal.Runner.TestBoot {
    use Flow.File

    type alias Disk = Map[String, String]

    /// デスクトップの組と同じく、環境変数の表の START で起動の World を組む。
    def bootWorld(app: App.App[w, ef], design: Vec2.Vec2, env: Map[String, String], reread: Bool): App.Internal.DevTools.Booted[w] \ ef + Fs.FileRead =
        App.Internal.DevTools.bootOfEnv(env, (request, again) -> App.Internal.Runner.bootFrom(app, design, request, again), reread)

    /// 起動の Doc の中身。World はその長さ。
    def docText(): String = "abcd"

    def disk(): Disk = Map#{"doc.json" => docText()}

    /// 始まり "here"（World をそのまま使う・引数 k は字の長さを足す）と指紋。
    def withHere(app: App.App[Int32, {}]): App.App[Int32, {}] =
        app
            |> App.withStarts({ name = "here", doc = "そのまま", args = Map#{"k" => ""},
                                build = (w, args) -> Ok(w + String.length(Map.getWithDefault("k", "", args))) } :: Nil)
            |> App.withFingerprint(w -> Int32.toString(w))

    def readLength(path: String, w: Int32): Int32 \ Fs.FileRead =
        Fs.FileRead.read(path) |> Result.map(String.length) |> Result.getWithDefault(w)

    /// main が読んだ Doc の長さから始まり、doc.json を保存即反映で読み直す App。
    def watchedApp(text: String): App.App[Int32, {}] =
        App.make(String.length(text)) |> App.watchFile("doc.json", w -> readLength("doc.json", w)) |> withHere

    /// 起動の前に読む doc.json と、F1 の一括にだけ載る extra.json（起動の前には読まない）を DocTable で持つ App。
    def tableApp(text: String): App.App[Int32, {}] =
        App.make(String.length(text))
            |> App.withDocTable(DocTable.row("doc", "doc.json", w -> readLength("doc.json", w))
                                :: DocTable.withoutWatch(DocTable.row("extra", "extra.json", w -> { discard Fs.FileRead.read("extra.json"); w })) :: Nil)
            |> withHere

    /// 自前の reloadOn で読み直す App（読み直しが読むパスは App から分からない）。
    def customReloadApp(text: String): App.App[Int32, {}] =
        App.make(String.length(text)) |> App.reloadOn(GameEngine.Key.F1, w -> readLength("doc.json", w)) |> withHere

    /// 起動の前に読んだ Doc を使わずに 0 から始まり、読み直しで初めて Doc を入れる App（読み直さない起動と再生がずれる）。
    def driftingApp(_text: String): App.App[Int32, {}] =
        App.make(0) |> App.watchFile("doc.json", w -> readLength("doc.json", w)) |> withHere

    /// f を disk の上で流し、結果と読んだ回数を返す。
    def onDisk(d: Disk, f: Unit -> a \ ef + Fs.FileRead): (a, Int32) \ ef =
        region rc {
            let reads = Ref.fresh(rc, 0);
            let found = path -> Map.get(path, d) |> Option.toOk(IoError.IoError(IoError.ErrorKind.NotFound, path));
            let result = run f() with handler Fs.FileRead {
                def read(path, k)      = { Ref.put(Ref.get(reads) + 1, reads); k(found(path)) }
                def readLines(path, k) = { Ref.put(Ref.get(reads) + 1, reads); k(found(path) |> Result.map(String.lines)) }
                def readBytes(path, k) = { Ref.put(Ref.get(reads) + 1, reads); k(found(path) |> Result.map(String.toBytes)) }
            };
            (result, Ref.get(reads))
        }

    /// main の形: doc.json を読んで App を組む。読んだ中身を控える。
    def loadedOn(d: Disk, makeApp: String -> App.App[Int32, {}]): (App.App[Int32, {}], Map[String, File]) =
        fst(onDisk(d, () -> Flow.Record.captureReads(() ->
            makeApp(Fs.FileRead.read("doc.json") |> Result.getWithDefault("")))))

    /// 記録する起動: 控えた中身（captured）から起動の World と start の行のファイルを作る。
    def recordOn(d: Disk, makeApp: String -> App.App[Int32, {}], env: Map[String, String], keepCaptured: Bool):
            (Result[String, (Int32, Option[(String, Map[String, String])])], Map[String, File]) =
        let (app, loaded) = loadedOn(d, makeApp);
        fst(onDisk(d, () -> App.Internal.DevTools.buildBootRecord(app, if (keepCaptured) Some(loaded) else None, reread -> bootWorld(app, Vec2.zero(), env, reread))))

    /// 記録の start の行と、その直後の確かめの行からなる flow。
    def flowOf(booted: Result[String, (Int32, Option[(String, Map[String, String])])], files: Map[String, File]): String =
        match booted {
            case Ok((world, Some((name, args)))) =>
                String.unlines("ready off" :: Flow.Record.startLine(name, args, files) :: Flow.Record.startCheckLines(Int32.toString(world)))
            case _ => ""
        }

    /// 再生: 再生する側の main（d から読む）で App を組み、flow を d の上で流す。始まりの直後の確かめが通れば Ok。
    def replayOn(d: Disk, makeApp: String -> App.App[Int32, {}], text: String): Result[String, Int32] =
        let (app, _) = loadedOn(d, makeApp);
        let outcome = fst(onDisk(d, () -> match Flow.Parse.parseText(Flow.vocabOf(app, 0), "record", text) {
            case Err(problems) => Err(Flow.Parse.problemsText(problems))
            case Ok(script) =>
                Flow.play(app, { design = Vec2.zero(), limit = 100 }, script, { world = 0, state = App.freshStepState() })
                    |> Result.map(played -> played#last) |> Result.mapErr(failure -> failure#why)
        }));
        outcome

    def worldOf(booted: Result[String, (Int32, Option[(String, Map[String, String])])]): Result[String, Int32] =
        Result.map(fst, booted)

    @Test
    def testBootWithoutRecordingReadsNoFile(): Unit \ Assert =
        let (_, reads) = onDisk(disk(), () -> bootWorld(watchedApp(docText()), Vec2.zero(), Map.empty(), false));
        Assert.assertEq(expected = 0, reads)

    @Test
    def testBootWhileRecordingWithoutCapturedRereadsTheDocs(): Unit \ Assert =
        let (_, reads) = onDisk(disk(), () -> bootWorld(watchedApp(docText()), Vec2.zero(), Map.empty(), true));
        Assert.assertEq(expected = 1, reads)

    @Test
    def testBootWithoutRecordingStartsLikeTheReplay(): Unit \ Assert =
        let (booted, _) = onDisk(disk(), () -> bootWorld(watchedApp(docText()), Vec2.zero(), Map.empty(), false));
        let (replayed, _) = onDisk(disk(), () -> App.buildStart(watchedApp(docText()), Vec2.zero(), "here", Map.empty()));
        Assert.assertEq(expected = replayed, worldOf(booted))

    @Test
    def testRecordWithCapturedDoesNotRereadTheDocs(): Unit \ Assert =
        let (app, loaded) = loadedOn(disk(), watchedApp);
        let (_, reads) = onDisk(disk(), () -> App.Internal.DevTools.buildBootRecord(app, Some(loaded), reread -> bootWorld(app, Vec2.zero(), Map.empty(), reread)));
        Assert.assertEq(expected = 0, reads)

    @Test
    def testRecordWithCapturedPutsTheMainReadOnTheStartLine(): Unit \ Assert =
        let (_, files) = recordOn(disk(), watchedApp, Map.empty(), true);
        Assert.assertEq(expected = Some(File.Text(docText())), Map.get("doc.json", files))

    @Test
    def testReplayAfterTheDocChangedStartsFromTheRecordedDoc(): Unit \ Assert =
        let (booted, files) = recordOn(disk(), watchedApp, Map.empty(), true);
        let changed = Map#{"doc.json" => "abcdefgh"};
        Assert.assertEq(expected = worldOf(booted), replayOn(changed, watchedApp, flowOf(booted, files)))

    @Test
    def testReplayOfTheOldRecordingPathAlsoMatches(): Unit \ Assert =
        let (booted, files) = recordOn(disk(), watchedApp, Map.empty(), false);
        let changed = Map#{"doc.json" => "abcdefgh"};
        Assert.assertEq(expected = worldOf(booted), replayOn(changed, watchedApp, flowOf(booted, files)))

    @Test
    def testReloadAllOnlyRowNotReadByMainIsOnTheStartLine(): Unit \ Assert =
        let withExtra = Map.insert("extra.json", "x", disk());
        let (_, files) = recordOn(withExtra, tableApp, Map.empty(), true);
        Assert.assertEq(expected = Some(File.Text("x")), Map.get("extra.json", files))

    @Test
    def testStartArgumentFileIsOnTheStartLine(): Unit \ Assert =
        let withArg = Map.insert("arg.txt", "zz", disk());
        let (_, files) = recordOn(withArg, watchedApp, Map#{"START" => "here k=@arg.txt"}, true);
        Assert.assertEq(expected = Some(File.Text("zz")), Map.get("arg.txt", files))

    @Test
    def testCustomReloadOnRereadsWhileRecording(): Unit \ Assert =
        let (app, loaded) = loadedOn(disk(), customReloadApp);
        let (_, reads) = onDisk(disk(), () -> App.Internal.DevTools.buildBootRecord(app, Some(loaded), reread -> bootWorld(app, Vec2.zero(), Map.empty(), reread)));
        Assert.assertEq(expected = 1, reads)

    @Test
    def testReplayStopsRightAfterStartWhenTheWorldDrifts(): Unit \ Assert =
        let (booted, files) = recordOn(disk(), driftingApp, Map.empty(), true);
        Assert.assertTrue(Result.isErr(replayOn(disk(), driftingApp, flowOf(booted, files))))

    @Test
    def testCaptureReadsPassesLoadProgressToTheOuterHandler(): Unit \ Assert =
        let seen = region rc {
            let got = MutList.empty(rc);
            discard run onDisk(disk(), () -> Flow.Record.captureReads(() -> { LoadProgress.report("docs", 0, 0); 1 })) with handler LoadProgress {
                def report(phase, done, total, k) = { MutList.push((phase, done, total), got); k(()) }
                def runTasks(_phase, _tasks, _k) = bug!("このテストは仕事を回さない")
                def imageDecoder(k) = k(ImageData.failingDecoder("このテストは絵を解かない"))
                def downloads(k) = k(LoadProgress.localDownloads())
            };
            MutList.toList(got)
        };
        Assert.assertEq(expected = ("docs", 0, 0) :: Nil, seen)

    @Test
    def testRecordingCapturesTheDocForTheStartLine(): Unit \ Assert =
        let ((_, files), _) = onDisk(disk(), () -> Flow.Record.captureReads(() -> bootWorld(watchedApp(docText()), Vec2.zero(), Map.empty(), true)));
        Assert.assertEq(expected = Some(File.Text(docText())), Map.get("doc.json", files))

    type alias Asked = Option[(String, Map[String, String])]

    /// 頼まれた始まりをそのまま「通った始まり」として返す boot（World は 0）。
    def echoBoot(request: App.Internal.DevTools.StartRequest, _reread: Bool): Result[String, (Int32, Asked)] =
        request |> Result.map(asked -> (0, asked))

    /// 名前のある始まりは組めず、先頭の始まりだけ組める boot（知らない始まりの名前の代わり）。
    def onlyFirstBoot(request: App.Internal.DevTools.StartRequest, _reread: Bool): Result[String, (Int32, Asked)] =
        request |> Result.flatMap(asked -> if (Option.isEmpty(asked)) Ok((0, None)) else Err("知らない始まり"))

    /// boot を hooks の open に渡して、起動の結果を返す。
    def openWith(hooks: App.Internal.DevTools.Hooks[Int32, {}, efTools],
                 boot: (App.Internal.DevTools.StartRequest, Bool) -> Result[String, (Int32, Asked)]): Result[String, (Int32, Asked)] \ IO =
        let (booted, tools) = run { hooks#open((request, reread) -> checked_ecast(boot(request, reread))) } with Fs.FileRead.runWithIO;
        hooks#close(tools, None);
        booted

    /// 道具なしの組は環境変数を読まず、先頭の始まりを頼む。
    @Test
    def testNoToolsAskForTheFirstStart(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((0, None)), openWith(App.Internal.DevTools.none(), echoBoot))

    /// デスクトップの組は START の行を名前と引数に解いて頼む（withDebug が無くても効く）。
    @Test
    def testDesktopToolsAskForTheStartLine(): Unit \ {Assert, IO} =
        let hooks = App.Internal.DevTools.desktopOf(Map#{"START" => "here k=ab n=2"}, None, App.make(0));
        Assert.assertEq(expected = Ok((0, Some(("here", Map#{"k" => "ab", "n" => "2"})))), openWith(hooks, echoBoot))

    /// デスクトップの組は START の行が読めなければ起動の誤りにする（訳の頭は START:）。
    @Test
    def testDesktopToolsRejectABrokenStartLine(): Unit \ {Assert, IO} =
        let hooks = App.Internal.DevTools.desktopOf(Map#{"START" => "here oops"}, None, App.make(0));
        let prefix = openWith(hooks, echoBoot) |> Result.mapErr(String.takeLeft(6));
        Assert.assertEq(expected = Err("START:"), prefix)

    /// ブラウザ版の組は、空白と改行の入った引数の値を切らずに頼む。
    @Test
    def testBrowserToolsKeepSpacesInArgs(): Unit \ {Assert, IO} =
        let asked = Some(("talk", Map#{"talk" => "Lair", "edit.38" => "おや、\nそう だね"}));
        Assert.assertEq(expected = Ok((0, asked)), openWith(App.Internal.DevTools.browserOf(asked), echoBoot))

    /// ブラウザ版の組は、頼んだ始まりを組めなければ先頭の始まりで開く。
    @Test
    def testBrowserToolsFallBackToTheFirstStart(): Unit \ {Assert, IO} =
        let hooks = App.Internal.DevTools.browserWith(Some(("nowhere", Map.empty())), _ -> checked_ecast(()));
        Assert.assertEq(expected = Ok((0, None)), openWith(hooks, onlyFirstBoot))
    /// ブラウザ版の組は、クエリに始まりが無ければ先頭の始まりを頼む。
    @Test
    def testBrowserToolsWithoutQueryAskForTheFirstStart(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((0, None)), openWith(App.Internal.DevTools.browserOf(None), echoBoot))

    /// 頼んだ始まりの引数は、空白と改行を含んだまま始まりの build に届く（k の字の長さを足す）。
    @Test
    def testBootFromPassesArgsWithSpaces(): Unit \ {Assert, IO} =
        let app = withHere(App.make(0));
        let booted = run { App.Internal.Runner.bootFrom(app, Vec2.zero(), Ok(Some(("here", Map#{"k" => "a b\nc"}))), false) } with Fs.FileRead.runWithIO;
        Assert.assertEq(expected = Ok((5, Some(("here", Map#{"k" => "a b\nc"})))), booted)

    /// 知らない始まりの名前は起動の誤りになる（ブラウザ版はこれを受けて先頭の始まりへ戻る）。
    @Test
    def testBootFromRejectsAnUnknownStart(): Unit \ {Assert, IO} =
        let app = withHere(App.make(0));
        let booted = run { App.Internal.Runner.bootFrom(app, Vec2.zero(), Ok(Some(("nowhere", Map.empty()))), false) } with Fs.FileRead.runWithIO;
        Assert.assertTrue(Result.isErr(booted))

    /// ギャラリーの場面 ten（10）と、始まり play（0）を持つ App。
    def shotApp(debug: Bool): App.App[Int32, {}] =
        App.make(0)
            |> App.withStarts({ name = "play", doc = "", args = Map.empty(), build = (w, _) -> Ok(w) } :: Nil)
            |> App.withShots({ name = "ten", doc = "", args = Map.empty(), build = (_, _) -> Ok(10) } :: Nil)
            |> App.withDebug(debug)

    /// DEBUG の起動なら START=shot:<場面> でギャラリーの場面から始まる。
    @Test
    def testShotStartOpensInDebug(): Unit \ {Assert, IO} =
        let booted = run { bootWorld(shotApp(true), Vec2.zero(), Map#{"START" => "shot:ten"}, false) } with Fs.FileRead.runWithIO;
        Assert.assertEq(expected = Ok((10, Some(("shot:ten", Map.empty())))), booted)

    /// 配る版の起動（DEBUG でない）では、ギャラリーの場面を開かない。
    @Test
    def testShotStartNeedsDebug(): Unit \ {Assert, IO} =
        let booted = run { bootWorld(shotApp(false), Vec2.zero(), Map#{"START" => "shot:ten"}, false) } with Fs.FileRead.runWithIO;
        Assert.assertTrue(Result.isErr(booted))
}
