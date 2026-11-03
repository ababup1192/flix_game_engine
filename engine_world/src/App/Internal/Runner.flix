// App.Internal.Runner — 実機のループ: 起動の World を決め、閉じるまで 1 コマずつ回す（入力の取り込み・閉じる要求・リモートデバッグ・F8・Doc の読み直し・進める・鳴らす・描く）。
// ループの状態（LoopState）はここだけが持つ。ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Runner {
    import java.lang.System

    /// 記録する起動の World と、start の行に載せるファイルの中身。
    /// captured（App を組む間に読んだ物）があり、読み直しが読むパスも分かる時は Doc を読み直さず、
    /// captured と起動の World を組む間に読んだ物に、読み直しのパスのうち未だ無い物を読んで足す（同じパスは captured を使う）。
    /// それ以外は freshWorld で読み直して拾う。
    def buildBootRecord(app: App[w, ef], design: Vec2.Vec2, env: Map[String, String], captured: Option[Map[String, Flow.File]]):
            (Result[String, (w, Option[(String, Map[String, String])])], Map[String, Flow.File]) \ ef + Fs.FileRead =
        match (captured, App.rec(app)#reloadPaths) {
            case (Some(loaded), Some(paths)) =>
                let (booted, bootRead) = Flow.Record.captureReads(() -> bootWorld(app, design, env, false));
                let known = Map.unionWith((first, _) -> first, loaded, bootRead);
                let missing = paths |> List.filter(path -> not Map.memberOf(path, known));
                let (_, extra) = Flow.Record.captureReads(() -> List.forEach(path -> discard Fs.FileRead.read(path), missing));
                (booted, Map.unionWith((first, _) -> first, known, extra))
            case _ => Flow.Record.captureReads(() -> bootWorld(app, design, env, true))
        }

    /// 起動の World: 登録簿が無ければ init + 起動時の系、あれば START（無ければ先頭の始まり）。
    /// 始まりの下地は、reread なら freshWorld（Doc を全部読み直す）、そうでなければ init + 起動時の系。
    /// 返すのは起動の World と、通った始まり（名前と書いた引数。登録簿が無ければ None）。
    // WhyNot: 記録しない起動で Doc を読み直さない — main が読んだばかりの物をもう一度読むだけで、重い Doc（3D の形）では起動が秒単位で延びる。
    def bootWorld(app: App[w, ef], design: Vec2.Vec2, env: Map[String, String], reread: Bool): Result[String, (w, Option[(String, Map[String, String])])] \ ef + Fs.FileRead =
        let r = App.rec(app);
        let base = () -> if (reread) App.freshWorld(app, design) else App.initialWorld(app, design);
        match List.head(r#starts) {
            case None => Ok((App.initialWorld(app, design), None))
            case Some(first) =>
                let line = Map.getWithDefault("START", "", env);
                let wanted = if (String.isEmpty(String.trim(line))) Ok((first#name, Map.empty()))
                             else App.parseStartLine(line) |> Result.mapErr(why -> "START: ${why}");
                forM (
                    chosen <- wanted;
                    world <- { let (name, args) = chosen; App.buildStartOn(app, base(), name, args) |> Result.mapErr(why -> "START: ${why}") }
                ) yield (world, Some(chosen))
        }

    /// 指紋の元の文字（withFingerprint を繋いだゲームだけ）。
    def fingerprintText(r: App.Rec[w, ef], world: w): Option[String] =
        r#fingerprint |> Option.map(f -> f(world))

    /// 記録に跳んだ拍の行（rewind・close）を書き、その後の World の指紋を覚え直す。
    def recordJump(app: App[w, ef], recorder: Option[Flow.Record.Recorder], text: Option[String], world: w): Unit \ IO =
        match recorder {
            case None => ()
            case Some(recording) =>
                Option.forEach(t -> Flow.Record.line(recording, t), text);
                Flow.Record.resetFingerprint(recording, fingerprintText(App.rec(app), world))
        }

    /// リモートの口が返した記録の材料（行と流したフレーム）を書き、その後の World の指紋を覚え直す。
    def recordItems(app: App[w, ef], recorder: Option[Flow.Record.Recorder], items: List[Flow.Record.Item], world: w): Unit \ IO =
        match recorder {
            case None => ()
            case Some(recording) =>
                items |> List.forEach(item -> match item {
                    case Flow.Record.Item.Line(text)          => Flow.Record.line(recording, text)
                    case Flow.Record.Item.Started(text)       => Flow.Record.started(recording, text)
                    case Flow.Record.Item.Played(frame, text) => Flow.Record.frame(recording, frame, text)
                });
                Flow.Record.resetFingerprint(recording, fingerprintText(App.rec(app), world))
        }

    /// 監視中パスのうち「World を作り直すべき物」を watch の登録順で返す: current で見えて
    /// prev と更新時刻が違うパスと、prev に無く current に現れたパス（新規出現）。
    /// current に無いパス（消えた・読めない）は発火しない — 保存の途中で一瞬読めなくなる
    /// エディタがあるので、見えなくなった事実では作り直さない。
    pub def changedPaths(watch: List[String], prev: Map[String, Int64], current: Map[String, Int64]): List[String] =
        watch |> List.filter(p -> match Map.get(p, current) {
            case None    => false
            case Some(t) => Map.get(p, prev) |> Option.forAll(prevT -> prevT != t)
        })

    /// launch の本体。captured = App を組む間に読んだファイルの中身（控えていなければ None）。
    pub def launchWith(app: App[w, ef], captured: Option[Map[String, Flow.File]], env: Map[String, String]): Unit \ (ef + Platform.Services + Platform.Annotation + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // 下ごしらえの間、画面にはバックエンドが最後に出した起動画面（「preparing game...」）が出たまま残る。
        // 長い下ごしらえは、ゲームが LoadProgress.report で区切りを知らせ、バックエンドの handler が起動画面を進める。
        // WhyNot: ここで起動画面を出し直さない — 間引きも中止スイッチも持たない 2 つ目の経路が生まれる。
        let recorder = if (r#debug) Flow.Record.pathOf(env) |> Option.flatMap(Flow.Record.open) else None;
        let design = Platform.Window.getViewportRect()#size;
        // 記録するなら、起動の World を組む間に読んだ中身も拾い、start の行に載せる（再生が同じ Doc で始まる）。
        let (booted, files) = match recorder {
            case Some(_) => buildBootRecord(app, design, env, captured)
            case None    => (bootWorld(app, design, env, false), Map.empty())
        };
        match booted {
            // 知らない始まりの名前で黙って先頭の場面から始めると、別の場面を見て直していることに気づけない。
            case Err(why)  => System.err.println("[App] ${why}"); Option.forEach(Flow.Record.close, recorder)
            case Ok((world0, started)) =>
                Option.forEach(recording -> {
                    match started {
                        case Some((name, args)) =>
                            Flow.Record.started(recording, Flow.Record.startLine(name, args, files));
                            Option.forEach(Flow.Record.expectStart(recording), fingerprintText(r, world0))
                        case None => Flow.Record.line(recording, "# App.withStarts が無いので、再生は flow の既定の World（init）から")
                    };
                    Flow.Record.resetFingerprint(recording, fingerprintText(r, world0))
                }, recorder);
                launchFrom(app, world0, recorder, env);
                Option.forEach(Flow.Record.close, recorder)
        }

    /// 起動の World が決まった後の launch（リモートデバッグ・監視・ループ）。
    def launchFrom(app: App[w, ef], world0: w, recorder: Option[Flow.Record.Recorder], env: Map[String, String]): Unit \ (ef + Platform.Services + Platform.Annotation + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let bridge = if (canDebug(r)) Option.map(port -> App.RemoteDebug.start(port, r#remoteRender),
                                                   App.RemoteDebug.portToOpenOf(env))
                     else None;
        // 起動時点の更新時刻を「発火なしで」用意しておく — 用意しないと最初のポーリングが
        // 全パスを新規出現と見なし、init 直後にもう一度リロードが走ってしまう。
        // 窓の宣言（withFullscreen）は最初のコマを描く前に当てる（起動した拍からその窓で見せる）。
        App.Internal.Output.applyFullscreen(r, world0);
        if (r#diagnostics) Platform.Diagnostics.setDiagnosticsEnabled(true) else ();
        let watch0 = if (r#debug and not List.isEmpty(r#watch))
                         { sincePoll = 0.0, mtimes = statMtimes(List.map(fst, r#watch)) }
                     else freshWatchState();
        // キーと同じく、起動時にすでに押されているボタンは一度離すまでエッジにならない。
        // カーソルの「前の位置」はまだ無い（None）ので、最初のフレームの mouseMoved は false。
        // 固定ステップの状態（持ち越し秒と未消費エッジ）は空から始める。
        loop(app, { world = world0, prevKeys = InputEvent.currentKeys(),
                    prevMouseDown = Platform.Input.isMouseButtonPressed(GameEngine.MouseButton.Left),
                    prevCursor = None, anno = Annotate.initial(), history = Nil,
                    bridge = bridge, remoteHold = false, stepState = App.freshStepState(),
                    watchState = watch0, sustaining = Nil, mixState = AudioMixer.initial(),
                    soundUses = { oneShot = Set.empty(), looped = Set.empty() },
                    tileCache = App.Internal.Paint.freshTileCache(),
                    glyphSeen = None, budgetWarned = false,
                    warnOnce = App.warnOnceWith(Ref.fresh(Static, Set.empty())),
                    cursorShown = App.CursorLook.State.Stale, captureShown = None, lastDiagnostics = None,
                    outputKeys = App.Internal.Output.keysAfterJump(app, world0, Nil), recorder = recorder,
                    hitches = if (canDebug(r)) Some(App.Internal.Hitch.startHitchWatch()) else None });
        Option.forEach(App.RemoteDebug.shutdown, bridge)

    /// loop が次のフレームへ渡し続ける物。app（不変）は入れない — 状態に混ぜると
    /// 「フレームごとに変わりうる物」に見える。
    // 平らな 1 枚にしている。種類ごとに入れ子へ畳むと、更新が
    // { debug = { hold = x | st#debug } | st } になって呼ぶ側が短くならない。
    type alias LoopState[w] = {
        world = w,
        prevKeys = Set[GameEngine.Key], prevMouseDown = Bool, prevCursor = Option[Vec2.Vec2],
        anno = Annotate.State, history = List[w],
        bridge = Option[App.RemoteDebug.Bridge], remoteHold = Bool,
        stepState = App.StepState, watchState = WatchState, sustaining = List[String],
        mixState = AudioMixer.State, soundUses = App.Internal.Output.SoundUses,
        tileCache = App.Internal.Paint.TileCache, glyphSeen = Option[Int64],
        // 「絵の値段が予算を超えていると 1 回だけ知らせた」印。毎フレーム出すと
        // 遅い画面がさらに遅くなり、ログも読めなくなる。
        budgetWarned = Bool,
        // View の組み立てが既定値で続けたことを 1 回だけ知らせる口（ViewCtx#warnOnce。見た文面はゲームの間ずっと覚える）。
        warnOnce = String -> Unit,
        // withCursor の宣言を最後にどう当てたか（止めている拍は Stale にして、動き出した拍に当て直させる）。
        cursorShown = App.CursorLook.State,
        // withMouseCapture の宣言を最後に当てた値（None = まだ当てていない・止めた画面が放した）。
        captureShown = Option[Bool],
        // 前の Running のフレームで引き取った診断（withDiagnostics の間だけ Some。次のフレームの Frame#diagnostics）。
        lastDiagnostics = Option[FrameDiagnostics.Diagnostics],
        // 出力（addOutput）ごとの最後に書いた鍵（outputs と同じ順）。
        outputKeys = List[String],
        // 遊んだ記録（DEBUG の起動・FLOW_RECORD=0 で止まる）。None = 書かない。
        recorder = Option[Flow.Record.Recorder],
        // ヒッチの記録（DEBUG の起動だけ）。None = 見張らない。
        hitches = Option[App.Internal.Hitch.HitchWatch]
    }

    /// リモートコマンドを捌いた後に残る 3 つの進み方。
    pub enum Branch with Eq, ToString {
        /// 時間が止まっている。World には触れず、凍結した絵の上で注釈とスクラブだけが動く
        case Paused
        /// 停止を抜けるフレーム。スクラブ位置の World から再開するので、まだ World を進めない
        case Resuming
        /// ふつうのフレーム。World を進めて描く
        case Running
    }

    /// ウィンドウの閉じるボタンへの答え方。
    pub enum CloseAnswer with Eq, ToString {
        /// 閉じるボタンは押されていない
        case Ignore
        /// ゲームの withCloseRequest へ渡す（確認を出すかはゲームが決める）
        case AskGame
        /// その場で閉じる
        case Close
    }

    /// 閉じるボタンが押されたか・withCloseRequest があるか・F8 で止めているかから、閉じるボタンへの答え方を決める。
    ///
    /// WhyNot: F8 で止めている間はゲームへ渡さない — 止めている間の World は再開の時に履歴から取り直すので、
    /// 渡すと知らせが消える。持ち越すと、F8 を解いた最初のフレームで思い出したように確認が出る。
    pub def decideClose(input: { closing = Bool, hasCloseRequest = Bool, paused = Bool }): CloseAnswer =
        if (not input#closing) CloseAnswer.Ignore
        else if (input#paused or not input#hasCloseRequest) CloseAnswer.Close
        else CloseAnswer.AskGame

    /// F8 と停止状態から、このフレームの進み方と「F8 が今トグルされたか」を決める。
    ///
    /// - `remoteHold`（HTTP 側が停止の主導権を持っている間）は F8 を殺す。/resume で戻す
    /// - デバッグ機能が使えない構成（canDebug が偽）でも F8 は効かない
    /// - 停止を抜けるフレームは Running でなく Resuming。ここで World を進めると、
    ///   スクラブで巻き戻した瞬間が 1 フレーム分だけ飛ぶ
    pub def decideBranch(input: { f8Pressed = Bool, canDebug = Bool,
                                  remoteHold = Bool, wasPaused = Bool }):
                        { branch = Branch, toggled = Bool } =
        let toggled = input#f8Pressed and input#canDebug and not input#remoteHold;
        let pausedNow = if (toggled) not input#wasPaused else input#wasPaused;
        let branch = if (pausedNow) Branch.Paused
                     else if (input#wasPaused) Branch.Resuming
                     else Branch.Running;
        { branch = branch, toggled = toggled }

    /// 毎フレーム: キーを読み Frame に埋め込む → 終了判定 → リモートコマンド → リロード →
    /// 1 フレームの中身（traceFrame。時計と系で World を進め、音の名前を導く。trace・台本・/step と同じ 1 本）→ 音を鳴らす →
    /// 描画（renderFrame。進んだ World を絵に写す）→ 末尾再帰。前フレームのキー集合・
    /// アノテーション状態・直近の World 履歴は引数で次のフレームへ渡し続ける。
    /// 「進める（advanceFrame）」と「描く（renderFrame）」がこの順で必ず分かれているのが芯 —
    /// 描画は進んだ後の World を読むだけで、World を書き換えない（App のモジュール冒頭の 2 役割を参照）。
    ///
    /// F8 で時間停止をトグルできる（view を繋いだゲームのみ）。停止中は World に触れず、
    /// 凍結した絵の上でズーム・パン・矩形ドラッグ（注釈の書き出し）と、← → での時間スクラブ
    /// （直近 historyLimit コマ・約 30 秒を 1 フレーム単位で戻る / 進む）だけが動く。解除するとスクラブ位置の
    /// World から再開するので、狙った瞬間へ巻き戻してやり直せる。
    /// 停止中もキーと dt は毎フレーム読み続けるので、解除時に押しっぱなしキーの
    /// 誤エッジや巨大な dt は発生しない。
    ///
    /// bridge はリモートデバッグの HTTP エンドポイント（無効なら None）。どの分岐に入るかの規則は
    /// decideBranch（テストで pin してある）。
    ///
    /// stepState は withFixedStep の持ち回し（持ち越し秒 + 未消費エッジ。未使用なら初期値のまま）。
    /// 一時停止中・リモート処理中・一時停止からの再開フレームはどの分岐でも world を進めないので
    /// stepState も動かさず素通しする（巻き戻すのは World の見た目であって、貯まっていた
    /// 実時間の端数や取り置いたエッジではない）。watchState（watchFile の保存検知）も同じ扱い —
    /// World に触れない分岐では監視も動かさず素通しする。
    def loop(app: App[w, ef], st0: LoopState[w]): Unit \ (ef + Platform.Services + Platform.Annotation + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // ヒッチの記録が測る 1 周の始まり（入力の取り込みから。nanoTime は軽いので見張らない時も取る）。
        let iterStart = System.nanoTime();
        let frame = readFrame(st0);
        let wantsQuit = r#quit;
        // shouldClose は入力の取り込み（poll）も兼ねるので 1 フレームに 1 回だけ呼ぶ。
        let closing = Platform.Window.shouldClose();
        let answer = decideClose({ closing = closing, hasCloseRequest = Option.nonEmpty(r#closeRequest),
                                   paused = st0#anno#paused });
        let st = if (answer == CloseAnswer.AskGame) noticeCloseRequest(app, st0) else st0;
        if (answer == CloseAnswer.Close or wantsQuit(frame, st#world)) ()
        else {
            // 入力の持ち越しはどの分岐でも同じなので、ここで 1 度だけ差し替える。
            let carried = { prevKeys = frame#down, prevMouseDown = frame#mouseDown,
                            prevCursor = Some(frame#cursor) | st };
            let remoteRaw = match st#bridge {
                case Some(b) => App.RemoteDebug.pollRequest(b)
                case None    => None
            };
            match (remoteRaw, st#bridge) {
                case (Some(raw), Some(b)) if String.startsWith(prefix = "POST /perf", raw) =>
                    // /perf はウィンドウへ塗る（renderFrame）ので、塗れない handleRemote ではなくここで受ける。World は変えない。
                    let painted = App.Internal.Hitch.perfRun(app, st#warnOnce, b, App.RemoteDebug.parseRequest(raw), st#hitches,
                        { tileCache = st#tileCache, glyphSeen = st#glyphSeen, budgetWarned = st#budgetWarned });
                    loop(app, { tileCache = painted#tileCache, glyphSeen = painted#glyphSeen,
                                budgetWarned = painted#budgetWarned | carried })
                case (Some(raw), Some(b)) =>
                    // リモートコマンドを処理した実フレームは通常の進行を休む
                    // （停止中は元々進まないし、実行中でも 1 フレームの息継ぎに過ぎない）。
                    let next = App.RemoteDebug.handleRemote(app, b, raw,
                        { world = st#world, anno = st#anno, history = st#history, hold = st#remoteHold,
                          stepState = st#stepState, record = Nil });
                    // リモートの口が World を差し替えた拍は跳んだ拍（セーブを作り物で上書きしない）。
                    // /halt・/resume が矢印とキャプチャを上書きするので、宣言は次に動く拍で当て直す。
                    recordItems(app, st#recorder, next#record, next#world);
                    loop(app, { world = next#world, anno = next#anno, history = next#history,
                                remoteHold = next#hold, stepState = next#stepState,
                                cursorShown = App.CursorLook.State.Stale, captureShown = None,
                                outputKeys = App.Internal.Output.keysAfterJump(app, next#world, st#outputKeys) | carried })
                case _ => {
                    let decided = decideBranch({ f8Pressed = App.justPressed(GameEngine.Key.F8, frame),
                                                 canDebug = canDebug(r), remoteHold = st#remoteHold,
                                                 wasPaused = st#anno#paused });
                    // デバッグモードの出入りをウィンドウタイトルとカーソル形状で示す
                    // （停止中は正確に囲うための十字カーソル）
                    if (decided#toggled) match decided#branch {
                        case Branch.Paused   => App.Internal.Output.applyHaltLook(App.CursorLook.haltEnterLook())
                        case Branch.Resuming => App.Internal.Output.applyHaltLook(App.CursorLook.haltLeaveLook())
                        case Branch.Running  => ()
                    } else ();
                    match decided#branch {
                        case Branch.Paused =>
                            let (nextAnno, ticket, painted) = App.Internal.Halt.pausedStep(app, st#warnOnce, st#world, st#history, frame,
                                { paused = true | st#anno },
                                { tileCache = st#tileCache, glyphSeen = st#glyphSeen, budgetWarned = st#budgetWarned });
                            // チケットに、ここまでの遊んだ記録の写し（再生すると表示中の瞬間で止まる）を入れる。
                            match (ticket, st#recorder) {
                                case (Some(dir), Some(recorder)) => discard Flow.Record.copyInto(recorder, dir, nextAnno#scrub)
                                case _                      => ()
                            };
                            loop(app, { anno = nextAnno, cursorShown = App.CursorLook.State.Stale, captureShown = None,
                                        tileCache = painted#tileCache, glyphSeen = painted#glyphSeen,
                                        budgetWarned = painted#budgetWarned | carried })
                        case Branch.Resuming => loop(app, resumingStep(app, carried))
                        case Branch.Running  => loop(app, runningStep(app, frame, iterStart, carried))
                    }
                }
            }
        }

    /// このフレームの入力を読んで Frame を組む（キー・マウス・ホイール・動いた量・パッド・フォーカスと、前のフレームの診断）。
    /// キャプチャしている間の GLFW の仮の位置は窓の外へ流れるので、cursor はキャプチャした時の位置で止める（UI のホバーと mouseMoved を狂わせない）。
    /// realNow は前のフレームまでの実時間（quit・リロード・F8 の停止が読む）。系へ渡す前に advanceFrame が進めて置き直す。
    /// マウスの動いた量は止めている拍も読み切る（溜めると、動き出した拍に一度に入る）。
    def readFrame(st0: LoopState[w]): App.Frame \ (Platform.Input + Platform.Window + Platform.FrameClock) =
        let cursorNow = App.Internal.Frame.heldCursor(st0#captureShown, st0#prevCursor, Platform.Input.getMousePosition());
        { realNow = Clock.nowOf(st0#stepState#real), padTouched = Platform.Input.isGamepadTouched(),
          padKind = Platform.Input.gamepadKind(), mouseDelta = Platform.Input.consumeMouseDelta(),
          windowFocused = Platform.Input.isWindowFocused(), diagnostics = st0#lastDiagnostics
          | App.frameOf(prev = st0#prevKeys, current = InputEvent.currentKeys(), readDt(),
                    Platform.Window.getViewportRect()#size,
                    { prevCursor = st0#prevCursor, cursor = cursorNow },
                    { prevDown = st0#prevMouseDown, down = Platform.Input.isMouseButtonPressed(GameEngine.MouseButton.Left),
                      wheel = Platform.Input.consumeScrollDelta() }) }

    /// 止めた画面を抜けるフレーム: スクラブ位置の World から再開する。巻き戻したぶんの履歴と
    /// フレーム番号も、そこを現在として数え直す。World はまだ進めない。
    def resumingStep(app: App[w, ef], st: LoopState[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + IO) =
        let r = App.rec(app);
        let resumed = App.resumePoint(st#anno, st#history, st#world);
        recordJump(app, st#recorder, if (st#anno#scrub > 0) Some("rewind ${Int32.toString(st#anno#scrub)}") else None,
                   resumed#world);
        let design = Platform.Window.getViewportRect()#size;
        let (cache1, seen1, warned1) = App.Internal.Paint.renderFrame(app, st#warnOnce, design, resumed#world, App.Internal.Paint.plainLook(App.Internal.Paint.fpsOverlayOf(r, design, resumed#anno)), st#tileCache, st#glyphSeen, st#budgetWarned);
        let declared = applyDeclared(r, resumed#world, st);
        { world = resumed#world, anno = resumed#anno, history = resumed#history,
          tileCache = cache1, glyphSeen = seen1, budgetWarned = warned1,
          cursorShown = declared#cursorShown, captureShown = declared#captureShown,
          outputKeys = App.Internal.Output.keysAfterJump(app, resumed#world, st#outputKeys) | st }

    /// ふつうのフレーム: World を進めて（traceFrame）、音を鳴らし、描き、見張り・履歴・出力・窓の宣言を済ませた次の状態。
    def runningStep(app: App[w, ef], frame: App.Frame, frameStart: Int64, st: LoopState[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // 止めていた間・リモートのコマで塗った分は、このコマの診断に混ぜない。
        let collecting = r#diagnostics or Option.nonEmpty(st#hitches);
        if (collecting) discard Platform.Diagnostics.consumeDiagnostics() else ();
        Option.forEach(recorder -> Flow.Record.checkExternalChange(recorder, fingerprintText(r, st#world)), st#recorder);
        let (watched, nextWatchState, watchFired) = applyWatch(r, frame#dt, st#watchState, st#world, st#recorder);
        let (reloaded, reloadFired) = applyReload(r, frame, watched, st#recorder);
        // 1 フレームの中身は trace・台本・/step と同じ traceFrame の 1 本（音の名前もここで導く）。
        let (traced, nextStepState) = App.traceFrame(app, frame, st#stepState, reloaded);
        let updatedAt = System.nanoTime();
        let advanced = traced#after;
        Option.forEach(recorder -> Flow.Record.frame(recorder, frame, fingerprintText(r, advanced)), st#recorder);
        let (nextSustaining, nextMix, nextUses) = App.Internal.Output.applyAudio(r, frame#dt, traced,
                                                   st#sustaining, st#mixState, st#soundUses, st#warnOnce);
        // fps は debug 有効時だけ計測する（本番ビルドは履歴を積まず無負荷）。
        let measuredAnno = if (r#debug) Annotate.recordDt(frame#dt, st#anno) else st#anno;
        // Doc の読み直しが起きたフレームはタイル層の世代を進め、同じ key でも作り直す。
        let renderStart = System.nanoTime();
        let (cache1, seen1, warned1) = App.Internal.Paint.renderFrame(app, st#warnOnce, frame#viewport, advanced, App.Internal.Paint.plainLook(App.Internal.Paint.fpsOverlayOf(r, frame#viewport, measuredAnno)),
                                          App.Internal.Paint.bumpTileGen(watchFired or reloadFired, st#tileCache),
                                          st#glyphSeen, st#budgetWarned);
        let renderNs = System.nanoTime() - renderStart;
        // 診断はここで 1 回だけ引き取り、ヒッチの記録と次のフレームの Frame#diagnostics へ配る。
        let diag = if (collecting) Some(Platform.Diagnostics.consumeDiagnostics()) else None;
        let nextHitches = App.Internal.Hitch.watchHitches(app, st#hitches, st#recorder,
            { frame = measuredAnno#frame, start = frameStart, updateNs = updatedAt - frameStart,
              renderNs = renderNs,
              pressed = frame#justPressed, reloaded = watchFired or reloadFired }, diag, advanced);
        // 時間スクラブ用の履歴（debug が無効なら一切持たない = 本番ビルドは無負荷）
        let nextHistory = if (canDebug(r))
                              List.take(App.historyLimit(), advanced :: st#history)
                          else Nil;
        // 外への出力とマウスの矢印・キャプチャ・窓は、実機のフレームの後の World からだけ当てる。
        let written = App.Internal.Output.writeOutputs(app, advanced, st#outputKeys);
        let declared = applyDeclared(r, advanced, st);
        { world = advanced, history = nextHistory,
          outputKeys = written, cursorShown = declared#cursorShown, captureShown = declared#captureShown,
          lastDiagnostics = if (r#diagnostics) diag else None,
          anno = { frame = measuredAnno#frame + 1i64 | measuredAnno },
          stepState = nextStepState, watchState = nextWatchState,
          sustaining = nextSustaining, mixState = nextMix, soundUses = nextUses, tileCache = cache1,
          glyphSeen = seen1, budgetWarned = warned1, hitches = nextHitches | st }

    /// World から宣言された窓の見た目（withCursor の矢印・withMouseCapture のキャプチャ・withFullscreen の窓）をまとめて当てる。
    /// 返すのは当てた後の矢印とキャプチャの状態（次のフレームの比べる元）。
    def applyDeclared(r: App.Rec[w, ef], world: w, st: LoopState[w]): { cursorShown = App.CursorLook.State, captureShown = Option[Bool] } \ Platform.Window =
        let shown = App.Internal.Output.applyCursor(r, world, st#cursorShown);
        let captureNow = App.Internal.Output.applyCapture(r, world, st#captureShown);
        App.Internal.Output.applyFullscreen(r, world);
        { cursorShown = shown, captureShown = captureNow }

    /// デバッグ機能が使える構成か（debug 有効 かつ 凍結画面を描く手段 = view か debugView がある）。
    def canDebug(r: App.Rec[w, ef]): Bool =
        r#debug and (Option.nonEmpty(r#view) or Option.nonEmpty(r#debugView))

    /// reloadOn で繋いだキーが押された瞬間だけ、リロード関数で World を作り直す。
    /// 第 2 要素は「このフレームで読み直しが起きたか」（タイル層の世代を進める合図）。
    def applyReload(r: App.Rec[w, ef], frame: App.Frame, world: w, recorder: Option[Flow.Record.Recorder]): (w, Bool) \ {Fs.FileRead, IO} =
        match r#reload {
            case Some((key, f)) => if (App.justPressed(key, frame)) (recordedReload(recorder, "key", () -> f(world)), true) else (world, false)
            case None           => (world, false)
        }

    /// 読み直し 1 回を流し、記録しているならその読んだファイルの中身つきで reload の行を書く。
    def recordedReload(recorder: Option[Flow.Record.Recorder], target: String, f: Unit -> w \ Fs.FileRead): w \ {Fs.FileRead, IO} =
        match recorder {
            case None => f()
            case Some(recording) =>
                let (reloaded, files) = Flow.Record.captureReads(f);
                Flow.Record.line(recording, Flow.Record.reloadLine(target, files));
                reloaded
        }

    /// watchFile がフレームをまたいで持ち回す状態（前回ポーリングからの経過秒と、
    /// 前回見えた各パスの更新時刻）。監視しないゲームでは常に初期値のまま動かない。
    type alias WatchState = { sincePoll = Float64, mtimes = Map[String, Int64] }

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

    /// 閉じる要求を World へ渡し、窓の閉じる印を下ろす（withCloseRequest が無ければそのまま）。
    def noticeCloseRequest(app: App[w, ef], st: LoopState[w]): LoopState[w] \ (ef + Platform.Window + IO) =
        match App.rec(app)#closeRequest {
            case None    => st
            case Some(f) =>
                Platform.Window.setShouldClose(false);
                let closed = f(st#world);
                recordJump(app, st#recorder, Some("close"), closed);
                { world = closed | st }
        }

    /// 時計は World の外に住む。エンジンが値をクランプするので、長いカクつきでも先へワープしない。
    def readDt(): Float64 \ Platform.FrameClock =
        Duration.toSeconds(Platform.FrameClock.getDeltaTime())
}
