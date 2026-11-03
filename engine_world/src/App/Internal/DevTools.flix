// App.Internal.DevTools — 開発の道具（リモートデバッグの命令口・ゲームの名簿・flow の記録・ヒッチの見張り・Doc の保存検知・
// F8 の注釈の書き出し・環境変数の表）を、ループが呼ぶフックの組（Hooks）にまとめる。App.DevTools の中身。
// ループは道具のモジュールを直に呼ばず、Hooks の関数だけを呼ぶ。道具を持たない入口（none）は何もしない関数を渡す。
// WhyNot: ループから道具の関数を直に呼ばない — 道具を持たない入口（ブラウザ版）からも呼び出しが届き、
//   TeaVM が道具のコード（HTTP のサーバ・ファイル・プロセス）まで読んで落ちる。値の中の関数なら、作らない入口からは届かない。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.DevTools {
    import java.lang.System

    /// 道具がコマをまたいで持ち回す状態（ループの LoopState#tools の 1 つの欄）。
    pub type alias State = {
        bridge = Option[App.RemoteDebug.Bridge],          // リモートデバッグの命令口（DEBUG の起動で DEBUG_HTTP_PORT か空いたポートがある時だけ）
        remoteHold = Bool,                                 // 命令口が止める主導権を持っているか（真の間 F8 は効かない。/resume で戻す）
        recorder = Option[Flow.Record.Recorder],           // 遊んだ記録（DEBUG の起動・FLOW_RECORD=0 で止まる）。None = 書かない
        hitches = Option[App.Internal.Hitch.HitchWatch],   // ヒッチの記録（DEBUG の起動だけ）。None = 見張らない
        watch = WatchState                                 // watchFile の保存検知（前のポーリングからの秒と、前に見えた更新時刻）
    }

    /// 起動の World と、通った始まり（名前と書いた引数。登録簿が無ければ None）。
    pub type alias Booted[w] = Result[String, (w, Option[(String, Map[String, String])])]

    /// 命令口の 1 件を捌くのに要る、ループの今の状態。
    pub type alias RemoteInput[w] = {
        world = w, anno = Annotate.State, history = List[w], stepState = App.StepState,
        design = Vec2.Vec2, warnOnce = String -> Unit, painted = App.Internal.Paint.Painted
    }

    /// 命令口の 1 件を捌いた後の進み方。
    pub enum RemoteOutcome[w] {
        /// POST /perf: ウィンドウへ塗っただけ（World は変えない）
        case Painted(App.Internal.Paint.Painted)
        /// ほかの命令: World・止めた状態・履歴・時計の持ち越しと、道具の状態を差し替える（跳んだフレーム）
        case Jumped({ world = w, anno = Annotate.State, history = List[w], stepState = App.StepState, tools = State })
    }

    /// ループが呼ぶフックの組。ef はアプリの系の effect、efTools は道具が加える effect（F8 の注釈の書き出し）。
    /// open の boot は、環境変数の表と「Doc を読み直すか」から起動の World を組む関数（Runner.bootWorld）。
    pub type alias Hooks[w: Type, ef: Eff, efTools: Eff] = {
        open = ((Map[String, String], Bool) -> Booted[w] \ ef + Fs.FileRead) -> (Booted[w], State) \ ef + Fs.FileRead + IO,  // 起動の World を組み、記録と命令口を開く
        start = State -> State \ Platform.Diagnostics + IO,                          // 最初のコマの前（窓の宣言を当てた後）: 保存検知とヒッチの見張りを始める
        close = State -> Unit \ IO,                                                  // ループを抜けた後: 命令口を止め、記録を閉じる
        holdsControl = State -> Bool,                                                // 命令口が止める主導権を持っているか（真の間 F8 は効かない）
        wantsDiagnostics = State -> Bool,                                            // 描く側の診断をコマごとに引き取るか（ヒッチの見張り）
        pollRemote = (RemoteInput[w], State) -> Option[RemoteOutcome[w]] \ Platform.Window + Platform.Rendering + RenderTarget.Target + Platform.Diagnostics + Fs.FileRead + IO,  // 命令口に届いた 1 件を捌く（無ければ None）
        recordJump = (Option[String], w, State) -> Unit \ IO,                        // 跳んだフレーム（巻き戻し・閉じる要求）を記録に書く
        beginFrame = (Float64, w, State) -> (w, State, Bool) \ Fs.FileRead + IO,     // 進める前: 記録の外の変化を見て、保存された Doc を読み直す（第 3 要素 = 読み直したか）
        runReload = (State, String, Unit -> w \ Fs.FileRead) -> w \ Fs.FileRead + IO,  // 読み直し 1 回を流し、記録しているなら読んだ中身つきで書く（第 2 引数は読み直しの元の名前）
        recordFrame = (State, App.Frame, w) -> Unit \ IO,                            // 進めたコマを記録に書く
        endFrame = (State, App.Internal.Hitch.FrameTiming, Option[FrameDiagnostics.Diagnostics], w) -> State \ IO,  // 描いた後: ヒッチの見張りへコマを渡す
        saveAnnotation = GameEngine.AnnotationRequest -> Option[String] \ efTools,  // F8 の矩形の注釈を書き出す（書いたフォルダ。持たない道具は None）
        copyRecordInto = (State, String, Int32) -> Unit \ IO                         // F8 のチケットのフォルダへ記録の写しを入れる（第 3 引数は表示中の瞬間までの戻りコマ数）
    }

    /// watchFile がフレームをまたいで持ち回す状態（前回ポーリングからの経過秒と、
    /// 前回見えた各パスの更新時刻）。監視しないゲームでは常に初期値のまま動かない。
    pub type alias WatchState = { sincePoll = Float64, mtimes = Map[String, Int64] }

    /// 何も開いていない道具の状態。
    def emptyState(): State =
        { bridge = None, remoteHold = false, recorder = None, hitches = None, watch = freshWatchState() }

    // ── 道具なし ──

    /// 道具を持たないフックの組（ブラウザ版・bench）。起動の World は環境変数を読まずに組み、ほかは何もしない。
    pub def none(): Hooks[w, ef, {}] = {
        open           = openNone,
        start          = st -> checked_ecast(st),
        close          = _ -> checked_ecast(()),
        holdsControl   = _ -> false,
        wantsDiagnostics = _ -> false,
        pollRemote     = (_, _) -> checked_ecast(None),
        recordJump     = (_, _, _) -> checked_ecast(()),
        beginFrame     = (_, world, st) -> checked_ecast((world, st, false)),
        runReload      = (_, _, f) -> checked_ecast(f()),
        recordFrame    = (_, _, _) -> checked_ecast(()),
        endFrame       = (st, _, _, _) -> checked_ecast(st),
        saveAnnotation = _ -> None,
        copyRecordInto = (_, _, _) -> checked_ecast(())
    }

    def openNone(boot: (Map[String, String], Bool) -> Booted[w] \ ef + Fs.FileRead): (Booted[w], State) \ ef + Fs.FileRead + IO =
        checked_ecast((boot(Map.empty(), false), emptyState()))

    // ── デスクトップの道具 ──

    /// デスクトップの道具のフックの組を、App を受けて作る関数。env は入口の頭で読んだ環境変数の表、
    /// captured は App を組む間に読んだファイルの中身（控えていなければ None。flow の記録の start の行に載せる）。
    pub def desktopOf(env: Map[String, String], captured: Option[Map[String, Flow.File]], app: App[w, {}]): Hooks[w, {}, Platform.Annotation] = {
        open           = boot -> openDesktop(env, captured, app, boot),
        start          = st -> startDesktop(app, st),
        close          = closeDesktop,
        holdsControl   = st -> st#remoteHold,
        wantsDiagnostics = st -> Option.nonEmpty(st#hitches),
        pollRemote     = (input, st) -> pollRemote(app, input, st),
        recordJump     = (text, world, st) -> recordJump(app, st#recorder, text, world),
        beginFrame     = (dt, world, st) -> beginFrame(app, dt, world, st),
        runReload      = (st, target, f) -> recordedReload(st#recorder, target, f),
        recordFrame    = (st, frame, world) -> recordFrame(app, st, frame, world),
        endFrame       = (st, timing, diag, world) -> { hitches = App.Internal.Hitch.watchHitches(app, st#hitches, st#recorder, timing, diag, world) | st },
        saveAnnotation = req -> Platform.Annotation.saveAnnotation(req),
        copyRecordInto = copyRecordInto
    }

    /// 記録を開き（DEBUG で FLOW_RECORD が 0 でない時）、起動の World を組み、通ったら記録の頭を書いて命令口を開く。
    def openDesktop(env: Map[String, String], captured: Option[Map[String, Flow.File]], app: App[w, {}],
                    boot: (Map[String, String], Bool) -> Booted[w] \ Fs.FileRead): (Booted[w], State) \ Fs.FileRead + IO =
        let r = App.rec(app);
        let recorder = if (r#debug) Flow.Record.pathOf(env) |> Option.flatMap(Flow.Record.open) else None;
        // 記録するなら、起動の World を組む間に読んだ中身も拾い、start の行に載せる（再生が同じ Doc で始まる）。
        let (booted, files) = match recorder {
            case Some(_) => buildBootRecord(app, captured, reread -> boot(env, reread))
            case None    => (boot(env, false), Map.empty())
        };
        let opened = { recorder = recorder | emptyState() };
        match booted {
            case Err(_) => (booted, opened)
            case Ok((world0, started)) =>
                Option.forEach(recording -> writeStart(app, recording, started, files, world0), recorder);
                let bridge = if (App.canDebug(r)) Option.map(port -> App.RemoteDebug.start(port, r#remoteRender),
                                                              App.RemoteDebug.portToOpenOf(env))
                             else None;
                (booted, { bridge = bridge | opened })
        }

    /// 保存検知の起動時点の更新時刻と、ヒッチの見張りを用意する。
    def startDesktop(app: App[w, {}], st: State): State \ Platform.Diagnostics + IO =
        let r = App.rec(app);
        // 起動時点の更新時刻を「発火なしで」用意しておく — 用意しないと最初のポーリングが
        // 全パスを新規出現と見なし、init 直後にもう一度リロードが走ってしまう。
        let watch0 = if (r#debug and not List.isEmpty(r#watch))
                         { sincePoll = 0.0, mtimes = statMtimes(List.map(fst, r#watch)) }
                     else freshWatchState();
        let hitches = if (App.canDebug(r)) Some(App.Internal.Hitch.startHitchWatch()) else None;
        { watch = watch0, hitches = hitches | st }

    /// 記録の頭に、通った始まりと起動の World の指紋を書く。
    def writeStart(app: App[w, {}], recording: Flow.Record.Recorder, started: Option[(String, Map[String, String])],
                   files: Map[String, Flow.File], world0: w): Unit \ IO =
        let fingerprint = fingerprintText(App.rec(app), world0);
        match started {
            case Some((name, args)) =>
                Flow.Record.started(recording, Flow.Record.startLine(name, args, files));
                Option.forEach(Flow.Record.expectStart(recording), fingerprint)
            case None => Flow.Record.line(recording, "# App.withStarts が無いので、再生は flow の既定の World（init）から")
        };
        Flow.Record.resetFingerprint(recording, fingerprint)

    /// 命令口を止め、記録を閉じる。
    def closeDesktop(st: State): Unit \ IO =
        Option.forEach(App.RemoteDebug.shutdown, st#bridge);
        Option.forEach(Flow.Record.close, st#recorder)

    /// 記録する起動の World と、start の行に載せるファイルの中身。
    /// captured（App を組む間に読んだ物）があり、読み直しが読むパスも分かる時は Doc を読み直さず、
    /// captured と起動の World を組む間に読んだ物に、読み直しのパスのうち未だ無い物を読んで足す（同じパスは captured を使う）。
    /// それ以外は Doc を読み直して（boot(true)）拾う。
    pub def buildBootRecord(app: App[w, {}], captured: Option[Map[String, Flow.File]], boot: Bool -> Booted[w] \ Fs.FileRead):
            (Booted[w], Map[String, Flow.File]) \ Fs.FileRead =
        match (captured, App.rec(app)#reloadPaths) {
            case (Some(loaded), Some(paths)) =>
                let (booted, bootRead) = Flow.Record.captureReads(() -> boot(false));
                let known = Map.unionWith((first, _) -> first, loaded, bootRead);
                let missing = paths |> List.filter(path -> not Map.memberOf(path, known));
                let (_, extra) = Flow.Record.captureReads(() -> List.forEach(path -> discard Fs.FileRead.read(path), missing));
                (booted, Map.unionWith((first, _) -> first, known, extra))
            case _ => Flow.Record.captureReads(() -> boot(true))
        }

    /// 命令口に届いた 1 件を捌く。POST /perf はウィンドウへ塗る（World は変えない）。ほかは RemoteDebug が捌き、
    /// World を差し替えた分を記録に書く。
    def pollRemote(app: App[w, {}], input: RemoteInput[w], st: State): Option[RemoteOutcome[w]] \ Platform.Window + Platform.Rendering + RenderTarget.Target + Platform.Diagnostics + Fs.FileRead + IO =
        match st#bridge {
            case None    => None
            case Some(b) => App.RemoteDebug.pollRequest(b) |> Option.map(raw -> answerRemote(app, b, raw, input, st))
        }

    def answerRemote(app: App[w, {}], b: App.RemoteDebug.Bridge, raw: String, input: RemoteInput[w], st: State): RemoteOutcome[w] \ Platform.Window + Platform.Rendering + RenderTarget.Target + Platform.Diagnostics + Fs.FileRead + IO =
        if (String.startsWith(prefix = "POST /perf", raw))
            RemoteOutcome.Painted(App.Internal.Hitch.perfRun(app, input#warnOnce, input#design, b, App.RemoteDebug.parseRequest(raw), st#hitches, input#painted))
        else {
            let next = App.RemoteDebug.handleRemote(app, b, raw,
                { world = input#world, anno = input#anno, history = input#history, hold = st#remoteHold,
                  stepState = input#stepState, record = Nil });
            recordItems(app, st#recorder, next#record, next#world);
            RemoteOutcome.Jumped({ world = next#world, anno = next#anno, history = next#history, stepState = next#stepState,
                                  tools = { remoteHold = next#hold | st } })
        }

    /// 指紋の元の文字（withFingerprint を繋いだゲームだけ）。
    def fingerprintText(r: App.Rec[w, ef], world: w): Option[String] =
        r#fingerprint |> Option.map(f -> f(world))

    /// 記録に跳んだフレームの行（rewind・close）を書き、その後の World の指紋を覚え直す。
    def recordJump(app: App[w, {}], recorder: Option[Flow.Record.Recorder], text: Option[String], world: w): Unit \ IO =
        match recorder {
            case None => ()
            case Some(recording) =>
                Option.forEach(t -> Flow.Record.line(recording, t), text);
                Flow.Record.resetFingerprint(recording, fingerprintText(App.rec(app), world))
        }

    /// 命令口の答えが返した記録の材料（行と流したフレーム）を書き、その後の World の指紋を覚え直す。
    def recordItems(app: App[w, {}], recorder: Option[Flow.Record.Recorder], items: List[Flow.Record.Item], world: w): Unit \ IO =
        match recorder {
            case None => ()
            case Some(recording) =>
                items |> List.forEach(writeItem(recording));
                Flow.Record.resetFingerprint(recording, fingerprintText(App.rec(app), world))
        }

    /// 命令口が返した記録の材料 1 つを書く。
    def writeItem(recording: Flow.Record.Recorder, item: Flow.Record.Item): Unit \ IO = match item {
        case Flow.Record.Item.Line(text)          => Flow.Record.line(recording, text)
        case Flow.Record.Item.Started(text)       => Flow.Record.started(recording, text)
        case Flow.Record.Item.Played(frame, text) => Flow.Record.frame(recording, frame, text)
    }

    /// 進めたコマを記録に書く。
    def recordFrame(app: App[w, {}], st: State, frame: App.Frame, world: w): Unit \ IO =
        Option.forEach(recorder -> Flow.Record.frame(recorder, frame, fingerprintText(App.rec(app), world)), st#recorder)

    /// F8 のチケットへ、記録の写しを入れる（記録していなければ何もしない）。
    def copyRecordInto(st: State, dir: String, back: Int32): Unit \ IO =
        Option.forEach(recorder -> discard Flow.Record.copyInto(recorder, dir, back), st#recorder)

    /// 読み直し 1 回を流し、記録しているならその読んだファイルの中身つきで reload の行を書く。
    def recordedReload(recorder: Option[Flow.Record.Recorder], target: String, f: Unit -> w \ Fs.FileRead): w \ {Fs.FileRead, IO} =
        match recorder {
            case None => f()
            case Some(recording) =>
                let (reloaded, files) = Flow.Record.captureReads(f);
                Flow.Record.line(recording, Flow.Record.reloadLine(target, files));
                reloaded
        }

    /// 進める前: 記録の外で World が変わったか（指紋）を見てから、保存された Doc を読み直す。
    def beginFrame(app: App[w, {}], dt: Float64, world: w, st: State): (w, State, Bool) \ {Fs.FileRead, IO} =
        let r = App.rec(app);
        Option.forEach(recorder -> Flow.Record.checkExternalChange(recorder, fingerprintText(r, world)), st#recorder);
        let (watched, nextWatch, fired) = applyWatch(r, dt, st#watch, world, st#recorder);
        (watched, { watch = nextWatch | st }, fired)

    // ── Doc の保存検知（watchFile） ──

    /// 監視中パスのうち「World を作り直すべき物」を watch の登録順で返す: current で見えて
    /// prev と更新時刻が違うパスと、prev に無く current に現れたパス（新規出現）。
    /// current に無いパス（消えた・読めない）は発火しない — 保存の途中で一瞬読めなくなる
    /// エディタがあるので、見えなくなった事実では作り直さない。
    pub def changedPaths(watch: List[String], prev: Map[String, Int64], current: Map[String, Int64]): List[String] =
        watch |> List.filter(p -> match Map.get(p, current) {
            case None    => false
            case Some(t) => Map.get(p, prev) |> Option.forAll(prevT -> prevT != t)
        })

    /// 監視を持たない・まだ何も見ていない WatchState。
    def freshWatchState(): WatchState =
        { sincePoll = 0.0, mtimes = Map.empty() }

    /// 保存検知のポーリング間隔（秒）。体感の即時性と毎フレーム stat のコストの折り合い。
    def watchPollInterval(): Float64 = 0.5

    /// 監視中パスの更新時刻（epoch ミリ秒）をまとめて読む。読めないパスは黙って除く。
    // Fs.FileTime を launch の効果行に出さないのは、デバッグ専用の内部ポーリングのために
    // 全ゲームの Main へ with 追記を強いないため（ここで IO のハンドラで閉じる）。
    def statMtimes(paths: List[String]): Map[String, Int64] \ IO =
        run {
            run {
                List.foldLeft((acc, p) -> match Fs.ModificationTime.modificationTime(p) {
                    case Ok(t)  => Map.insert(p, t, acc)
                    case Err(_) => acc
                }, Map.empty(), paths)
            } with Fs.ModificationTime.runWithFileTime
        } with Fs.FileTime.runWithIO

    /// 保存検知の 1 フレームぶん: 間隔に達したら更新時刻を読み、変化したパスの関数を
    /// 登録順に適用して World を作り直す（発火は標準エラーへ 1 行知らせる）。
    /// debug 無効・watch 空・間隔未達なら stat を一切しない（フレーム予算ゼロ）。
    /// 第 3 要素は「このフレームでどれかの Doc が読み直されたか」（タイル層の世代を進める合図）。
    def applyWatch(r: App.Rec[w, ef], dt: Float64, state: WatchState, world: w,
                   recorder: Option[Flow.Record.Recorder]): (w, WatchState, Bool) \ {Fs.FileRead, IO} =
        if (not r#debug or List.isEmpty(r#watch))
            (world, state, false)
        else {
            let waited = state#sincePoll + dt;
            if (waited < watchPollInterval())
                (world, { sincePoll = waited | state }, false)
            else {
                let current = statMtimes(List.map(fst, r#watch));
                let changed = changedPaths(List.map(fst, r#watch), state#mtimes, current);
                let next = r#watch |> List.foldLeft((acc, entry) -> {
                    let (path, f) = entry;
                    if (List.memberOf(path, changed)) {
                        System.err.println("watch reload: ${path}");
                        recordedReload(recorder, path, () -> f(acc))
                    } else acc
                }, world);
                (next, { sincePoll = 0.0, mtimes = current }, not List.isEmpty(changed))
            }
        }
}
