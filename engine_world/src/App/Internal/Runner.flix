// App.Internal.Runner — 実機のループ: 起動の World を決め、閉じるまで 1 コマずつ回す（入力の取り込み・閉じる要求・リモートデバッグ・F8・Doc の読み直し・進める・鳴らす・描く）。
// ループの状態（LoopState）はここだけが持つ。ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Runner {
    import java.lang.System

    /// 起動の World: 登録簿が無ければ init + 起動時の系、あれば START（無ければ先頭の始まり）。
    /// 始まりの下地は、reread なら freshWorld（Doc を全部読み直す）、そうでなければ init + 起動時の系。
    /// 返すのは起動の World と、通った始まり（名前と書いた引数。登録簿が無ければ None）。
    // WhyNot: 記録しない起動で Doc を読み直さない — main が読んだばかりの物をもう一度読むだけで、重い Doc（3D の形）では起動が秒単位で延びる。
    /// START がギャラリーの場面（shot:）なら、DEBUG の起動の時だけ通す。
    def bootWorld(app: App[w, ef], design: Vec2.Vec2, env: Map[String, String], reread: Bool): App.Internal.DevTools.Booted[w] \ ef + Fs.FileRead =
        let r = App.rec(app);
        let base = () -> if (reread) App.freshWorld(app, design) else App.initialWorld(app, design);
        let line = String.trim(Map.getWithDefault("START", "", env));
        let wanted = if (String.isEmpty(line) or (List.isEmpty(r#starts) and List.isEmpty(r#shots))) Ok(List.head(r#starts) |> Option.map(first -> (first#name, Map.empty())))
                     else App.parseStartLine(line) |> Result.mapErr(why -> "START: ${why}") |> Result.map(chosen -> {
                         // 登録簿の無いゲームが START を置いても、今までどおり init から始める（ギャラリーの場面だけは引く）。
                         let (name, _) = chosen;
                         if (List.isEmpty(r#starts) and not App.isShotName(name)) None else Some(chosen)
                     });
        match wanted {
            case Err(why)    => Err(why)
            case Ok(None)    => Ok((App.initialWorld(app, design), None))
            case Ok(Some((name, args))) =>
                if (App.isShotName(name) and not r#debug) Err("START=${name}: ギャラリーの場面は DEBUG の起動だけで開ける（make debug・SHOT=<名前> make run）")
                else App.buildStartOn(app, base(), name, args) |> Result.mapErr(why -> "START: ${why}")
                    |> Result.map(world -> (world, Some((name, args))))
        }

    /// 開発の道具（hooks）を開いて起動の World を組み、閉じるまでループを回し、道具を閉じる。
    pub def runLoop(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools]): Unit \ (ef + efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        // 下ごしらえの間、画面にはバックエンドが最後に出した起動画面（「preparing game...」）が出たまま残る。
        // 長い下ごしらえは、ゲームが LoadProgress.report で区切りを知らせ、バックエンドの handler が起動画面を進める。
        // WhyNot: ここで起動画面を出し直さない — 間引きも中止スイッチも持たない 2 つ目の経路が生まれる。
        let design = Platform.Window.getViewportRect()#size;
        let (booted, opened) = hooks#open((env, reread) -> bootWorld(app, design, env, reread));
        let (closing, last) = match booted {
            // 知らない始まりの名前で黙って先頭の場面から始めると、別の場面を見て直していることに気づけない。
            case Err(why)  => System.err.println("[App] ${why}"); (opened, None)
            case Ok((world0, started)) =>
                let play = () -> launchFrom(app, hooks, design, world0, isShotStart(started), opened);
                let (tools, world) = match opened#script {
                    case None         => play()
                    case Some(script) => App.Internal.InputScript.drive(script, play)
                };
                (tools, Some(world))
        };
        hooks#close(closing, last)

    /// ギャラリーの場面の始まり（App.withShots・START=shot:<名前>）から起動したか。F8 で止めた状態で窓を開ける。
    def isShotStart(started: Option[(String, Map[String, String])]): Bool =
        started |> Option.exists(match (name, _) -> App.isShotName(name))

    /// 起動の World が決まった後の launch（ウィンドウの宣言・診断・ループ）。返すのはループを抜けた時の道具の状態と最後の World。
    /// halted なら F8 で止めた状態から始める（止められる構成の時だけ。canDebug が偽ならふつうに動く）。
    def launchFrom(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], design: Vec2.Vec2, world0: w, halted: Bool,
                   tools: App.Internal.DevTools.State): (App.Internal.DevTools.State, w) \ (ef + efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // 窓の宣言（withFullscreen）は最初のコマを描く前に当てる（起動した拍からその窓で見せる）。
        App.Internal.Output.applyFullscreen(r, world0);
        if (r#diagnostics) Platform.Diagnostics.setDiagnosticsEnabled(true) else ();
        let started = hooks#start(tools);
        let haltedNow = halted and App.canDebug(r);
        // F8 を押した時と同じ見た目（タイトルの印と十字のカーソル）を、止めた状態で始める時にも最初のコマの前に当てる。
        if (haltedNow) App.Internal.Output.applyHaltLook(App.CursorLook.haltEnterLook()) else ();
        // キーと同じく、起動時にすでに押されているボタンは一度離すまでエッジにならない。
        // カーソルの「前の位置」はまだ無い（None）ので、最初のフレームの mouseMoved は false。
        // 固定ステップの状態（持ち越し秒と未消費エッジ）は空から始める。
        loop(app, hooks, { design = design, world = world0, prevKeys = InputEvent.currentKeys(),
                    prevMouseButtons = mouseButtonsHeld(),
                    prevCursor = None, anno = { paused = haltedNow | Annotate.initial() }, history = Nil,
                    stepState = App.freshStepState(),
                    sustaining = Nil, mixState = AudioMixer.initial(),
                    soundUses = { oneShot = Set.empty(), looped = Set.empty() },
                    tileCache = App.Internal.Paint.freshTileCache(),
                    glyphSeen = None, budgetWarned = false,
                    warnOnce = App.warnOnceWith(Ref.fresh(Static, Set.empty())),
                    cursorShown = App.CursorLook.State.Stale, captureShown = None, lastDiagnostics = None,
                    outputKeys = App.Internal.Output.keysAfterJump(app, world0, Nil), tools = started })

    /// loop が次のフレームへ渡し続ける物。app（不変）は入れない — 状態に混ぜると
    /// 「フレームごとに変わりうる物」に見える。
    // 平らな 1 枚にしている。種類ごとに入れ子へ畳むと、更新が
    // { debug = { hold = x | st#debug } | st } になって呼ぶ側が短くならない。
    type alias LoopState[w] = {
        world = w,
        // design px の描き場の寸。起動の時に 1 回だけ読む（Frame#viewport・描く所・止めた画面・/perf が同じ値を使う）。
        // WhyNot: コマごとに Window.getViewportRect を読み直さない — 窓の大きさが変わっても design は変わらず、
        //   読む所ごとに読み方が分かれると、止めた画面だけ違う寸で描く余地が生まれる。
        design = Vec2.Vec2,
        prevKeys = Set[GameEngine.Key], prevMouseButtons = Set[GameEngine.MouseButton], prevCursor = Option[Vec2.Vec2],
        anno = Annotate.State, history = List[w],
        stepState = App.StepState, sustaining = List[String],
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
        // 開発の道具（命令口・遊んだ記録・ヒッチの見張り・保存検知）の状態。道具なしの起動では何も開いていない。
        tools = App.Internal.DevTools.State
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
    /// 命令口（リモートデバッグ）と記録などの開発の道具は hooks を通してだけ呼ぶ。どの分岐に入るかの規則は
    /// decideBranch（テストで pin してある）。
    ///
    /// stepState は withFixedStep の持ち回し（持ち越し秒 + 未消費エッジ。未使用なら初期値のまま）。
    /// 一時停止中・リモート処理中・一時停止からの再開フレームはどの分岐でも world を進めないので
    /// stepState も動かさず素通しする（巻き戻すのは World の見た目であって、貯まっていた
    /// 実時間の端数や取り置いたエッジではない）。保存検知（watchFile）も同じ扱い —
    /// World に触れない分岐では監視も動かさず素通しする。
    def loop(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], st0: LoopState[w]): (App.Internal.DevTools.State, w) \ (ef + efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // ヒッチの記録が測る 1 周の始まり（入力の取り込みから。nanoTime は軽いので見張らない時も取る）。
        let iterStart = System.nanoTime();
        let frame = readFrame(st0);
        let wantsQuit = r#quit;
        // WhyNot: poll を readFrame の前に動かさない — 押したキーが効くコマが 1 つ前へずれ、実機の手触りと F8 で止まるコマが変わる。
        Platform.Window.pollEvents();
        // 台本を流し終えた周は、閉じるボタンと同じにその場で抜ける（withCloseRequest の確認を出さない）。
        let scriptDone = st0#tools#script |> Option.exists(App.Internal.InputScript.isFinished);
        let closing = Platform.Window.shouldClose();
        let answer = if (scriptDone) CloseAnswer.Close
                     else decideClose({ closing = closing, hasCloseRequest = Option.nonEmpty(r#closeRequest),
                                        paused = st0#anno#paused });
        let st = if (answer == CloseAnswer.AskGame) noticeCloseRequest(app, hooks, st0) else st0;
        if (answer == CloseAnswer.Close or wantsQuit(frame, st#world)) (st#tools, st#world)
        else {
            // 入力の持ち越しはどの分岐でも同じなので、ここで 1 度だけ差し替える。
            let carried = { prevKeys = frame#down, prevMouseButtons = frame#mouseButtons,
                            prevCursor = Some(frame#cursor) | st };
            let remote = hooks#pollRemote({ world = st#world, anno = st#anno, history = st#history, stepState = st#stepState,
                                            design = st#design, warnOnce = st#warnOnce,
                                            painted = { tileCache = st#tileCache, glyphSeen = st#glyphSeen, budgetWarned = st#budgetWarned } },
                                          st#tools);
            match remote {
                case Some(App.Internal.DevTools.RemoteOutcome.Painted(painted)) =>
                    loop(app, hooks, { tileCache = painted#tileCache, glyphSeen = painted#glyphSeen,
                                       budgetWarned = painted#budgetWarned | carried })
                // リモートコマンドを処理した実フレームは通常の進行を休む
                // （停止中は元々進まないし、実行中でも 1 フレームの息継ぎに過ぎない）。
                // 命令口が World を差し替えたフレームは跳んだフレーム（セーブを作り物で上書きしない）。
                // /halt・/resume が矢印とキャプチャを上書きするので、宣言は次に動くフレームで当て直す。
                case Some(App.Internal.DevTools.RemoteOutcome.Jumped(next)) =>
                    loop(app, hooks, { world = next#world, anno = next#anno, history = next#history,
                                       stepState = next#stepState, tools = next#tools,
                                       cursorShown = App.CursorLook.State.Stale, captureShown = None,
                                       outputKeys = App.Internal.Output.keysAfterJump(app, next#world, st#outputKeys) | carried })
                case None => localStep(app, hooks, frame, iterStart, carried)
            }
        }

    /// 命令口が何も捌かなかったフレーム: F8 と停止状態から進み方を決め、止めた画面・再開・ふつうのフレームのどれかを流す。
    def localStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, iterStart: Int64,
                  st: LoopState[w]): (App.Internal.DevTools.State, w) \ (ef + efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let decided = decideBranch({ f8Pressed = App.justPressed(GameEngine.Key.F8, frame),
                                     canDebug = App.canDebug(r), remoteHold = hooks#holdsControl(st#tools),
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
                let (nextAnno, ticket, painted) = App.Internal.Halt.pausedStep(app, hooks#saveAnnotation, st#warnOnce, st#design, st#world, st#history, frame,
                    { paused = true | st#anno },
                    { tileCache = st#tileCache, glyphSeen = st#glyphSeen, budgetWarned = st#budgetWarned });
                Platform.Window.presentFrame();
                // チケットに、ここまでの遊んだ記録の写し（再生すると表示中の瞬間で止まる）を入れる。
                Option.forEach(dir -> hooks#copyRecordInto(st#tools, dir, nextAnno#scrub), ticket);
                loop(app, hooks, { anno = nextAnno, cursorShown = App.CursorLook.State.Stale, captureShown = None,
                                   tileCache = painted#tileCache, glyphSeen = painted#glyphSeen,
                                   budgetWarned = painted#budgetWarned | st })
            case Branch.Resuming =>
                let resumed = resumingStep(app, hooks, st);
                Platform.Window.presentFrame();
                let declared = applyDeclared(r, resumed#world, resumed);
                loop(app, hooks, { cursorShown = declared#cursorShown, captureShown = declared#captureShown | resumed })
            case Branch.Running  => loop(app, hooks, runningStep(app, hooks, frame, iterStart, st))
        }

    /// このフレームの入力を読んで Frame を組む（キー・マウス・ホイール・動いた量・パッド・フォーカスと、前のフレームの診断）。
    /// dt は入力より先に 1 回だけ読む — 1 周に 1 回・入力の前、が Platform.FrameClock を数えてコマを区切る handler（入力の台本）の約束。
    /// キャプチャしている間の GLFW の仮の位置は窓の外へ流れるので、cursor はキャプチャした時の位置で止める（UI のホバーと mouseMoved を狂わせない）。
    /// realNow は前のフレームまでの実時間（quit・リロード・F8 の停止が読む）。系へ渡す前に advanceFrame が進めて置き直す。
    /// マウスの動いた量は止めている拍も読み切る（溜めると、動き出した拍に一度に入る）。
    def readFrame(st0: LoopState[w]): App.Frame \ (Platform.Input + Platform.FrameClock) =
        let dt = readDt();
        let cursorNow = App.Internal.Frame.heldCursor(st0#captureShown, st0#prevCursor, Platform.Input.getMousePosition());
        let held = mouseButtonsHeld();
        App.withMouseButtons(st0#prevMouseButtons, held, { realNow = Clock.nowOf(st0#stepState#real), padTouched = Platform.Input.isGamepadTouched(),
          padKind = Platform.Input.gamepadKind(), mouseDelta = Platform.Input.consumeMouseDelta(),
          windowFocused = Platform.Input.isWindowFocused(), diagnostics = st0#lastDiagnostics
          | App.frameOf(prev = st0#prevKeys, current = InputEvent.currentKeys(), dt,
                    st0#design,
                    { prevCursor = st0#prevCursor, cursor = cursorNow },
                    { prevDown = Set.memberOf(GameEngine.MouseButton.Left, st0#prevMouseButtons),
                      down = Set.memberOf(GameEngine.MouseButton.Left, held),
                      wheel = Platform.Input.consumeScrollDelta() }) })

    /// いま押しているマウスのボタン（左・右・中）。
    def mouseButtonsHeld(): Set[GameEngine.MouseButton] \ Platform.Input =
        GameEngine.allMouseButtons() |> List.filter(b -> Platform.Input.isMouseButtonPressed(b)) |> List.toSet

    /// 止めた画面を抜けるフレーム: スクラブ位置の World から再開する。巻き戻したぶんの履歴と
    /// フレーム番号も、そこを現在として数え直す。World はまだ進めない。塗ったコマを画面へ出す・窓の宣言を当て直すのは呼ぶ側。
    def resumingStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], st: LoopState[w]): LoopState[w] \ (ef + Platform.Rendering + RenderTarget.Target + IO) =
        let r = App.rec(app);
        let resumed = App.resumePoint(st#anno, st#history, st#world);
        hooks#recordJump(if (st#anno#scrub > 0) Some("rewind ${Int32.toString(st#anno#scrub)}") else None,
                         resumed#world, st#tools);
        let (cache1, seen1, warned1) = App.Internal.Paint.renderFrame(app, st#warnOnce, st#design, resumed#world, App.Internal.Paint.plainLook(App.Internal.Paint.fpsOverlayOf(r, st#design, resumed#anno)), st#tileCache, st#glyphSeen, st#budgetWarned);
        { world = resumed#world, anno = resumed#anno, history = resumed#history,
          tileCache = cache1, glyphSeen = seen1, budgetWarned = warned1,
          outputKeys = App.Internal.Output.keysAfterJump(app, resumed#world, st#outputKeys) | st }

    /// ふつうのフレーム: World を進めて（traceFrame）、音を鳴らし、描き、見張り・履歴・出力・窓の宣言を済ませた次の状態。
    def runningStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // 止めていた間・リモートのコマで塗った分は、このコマの診断に混ぜない。
        let collecting = r#diagnostics or hooks#wantsDiagnostics(st#tools);
        if (collecting) discard Platform.Diagnostics.consumeDiagnostics() else ();
        let (watched, watchedTools, watchFired) = hooks#beginFrame(frame#dt, st#world, st#tools);
        let (reloaded, reloadFired) = applyReload(r, frame, watched, f -> hooks#runReload(watchedTools, "key", f));
        // 1 フレームの中身は trace・台本・/step と同じ traceFrame の 1 本（音の名前もここで導く）。
        let (traced, nextStepState) = App.traceFrame(app, frame, st#stepState, reloaded);
        let updatedAt = System.nanoTime();
        let advanced = traced#after;
        hooks#recordFrame(watchedTools, frame, advanced);
        let (nextSustaining, nextMix, nextUses) = App.Internal.Output.applyAudio(r, frame#dt, traced,
                                                   st#sustaining, st#mixState, st#soundUses, st#warnOnce);
        // fps は debug 有効時だけ計測する（本番ビルドは履歴を積まず無負荷）。
        let measuredAnno = if (r#debug) Annotate.recordDt(frame#dt, st#anno) else st#anno;
        // Doc の読み直しが起きたフレームはタイル層の世代を進め、同じ key でも作り直す。
        let renderStart = System.nanoTime();
        let (cache1, seen1, warned1) = App.Internal.Paint.renderFrame(app, st#warnOnce, st#design, advanced, App.Internal.Paint.plainLook(App.Internal.Paint.fpsOverlayOf(r, st#design, measuredAnno)),
                                          App.Internal.Paint.bumpTileGen(watchFired or reloadFired, st#tileCache),
                                          st#glyphSeen, st#budgetWarned);
        // WhyNot: 画面へ出すのをループ（止めた画面・再開のコマと同じ所）へ回さない — ヒッチの記録の描く時間は swap まで含めて測ってきた。
        Platform.Window.presentFrame();
        let renderNs = System.nanoTime() - renderStart;
        // 診断はここで 1 回だけ引き取り、ヒッチの記録と次のフレームの Frame#diagnostics へ配る。
        let diag = if (collecting) Some(Platform.Diagnostics.consumeDiagnostics()) else None;
        let nextTools = hooks#endFrame(watchedTools,
            { frame = measuredAnno#frame, start = frameStart, updateNs = updatedAt - frameStart,
              renderNs = renderNs,
              pressed = frame#justPressed, reloaded = watchFired or reloadFired }, diag, advanced);
        // 時間スクラブ用の履歴（debug が無効なら一切持たない = 本番ビルドは無負荷）
        let nextHistory = if (App.canDebug(r))
                              List.take(App.historyLimit(), advanced :: st#history)
                          else Nil;
        // 外への出力とマウスの矢印・キャプチャ・窓は、実機のフレームの後の World からだけ当てる。
        let written = App.Internal.Output.writeOutputs(app, advanced, st#outputKeys);
        let declared = applyDeclared(r, advanced, st);
        { world = advanced, history = nextHistory,
          outputKeys = written, cursorShown = declared#cursorShown, captureShown = declared#captureShown,
          lastDiagnostics = if (r#diagnostics) diag else None,
          anno = { frame = measuredAnno#frame + 1i64 | measuredAnno },
          stepState = nextStepState, tools = nextTools,
          sustaining = nextSustaining, mixState = nextMix, soundUses = nextUses, tileCache = cache1,
          glyphSeen = seen1, budgetWarned = warned1 | st }

    /// World から宣言された窓の見た目（withCursor の矢印・withMouseCapture のキャプチャ・withFullscreen の窓）をまとめて当てる。
    /// 返すのは当てた後の矢印とキャプチャの状態（次のフレームの比べる元）。
    def applyDeclared(r: App.Rec[w, ef], world: w, st: LoopState[w]): { cursorShown = App.CursorLook.State, captureShown = Option[Bool] } \ Platform.Window =
        let shown = App.Internal.Output.applyCursor(r, world, st#cursorShown);
        let captureNow = App.Internal.Output.applyCapture(r, world, st#captureShown);
        App.Internal.Output.applyFullscreen(r, world);
        { cursorShown = shown, captureShown = captureNow }

    /// reloadOn で繋いだキーが押された瞬間だけ、リロード関数で World を作り直す（record は道具の記録を通して流す口）。
    /// 第 2 要素は「このフレームで読み直しが起きたか」（タイル層の世代を進める合図）。
    def applyReload(r: App.Rec[w, ef], frame: App.Frame, world: w, record: (Unit -> w \ Fs.FileRead) -> w \ {Fs.FileRead, IO}): (w, Bool) \ {Fs.FileRead, IO} =
        match r#reload {
            case Some((key, f)) => if (App.justPressed(key, frame)) (record(() -> f(world)), true) else (world, false)
            case None           => (world, false)
        }

    /// 閉じる要求を World へ渡し、窓の閉じる印を下ろす（withCloseRequest が無ければそのまま）。
    def noticeCloseRequest(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], st: LoopState[w]): LoopState[w] \ (ef + Platform.Window + IO) =
        match App.rec(app)#closeRequest {
            case None    => st
            case Some(f) =>
                Platform.Window.setShouldClose(false);
                let closed = f(st#world);
                hooks#recordJump(Some("close"), closed, st#tools);
                { world = closed | st }
        }

    /// 時計は World の外に住む。エンジンが値をクランプするので、長いカクつきでも先へワープしない。
    def readDt(): Float64 \ Platform.FrameClock =
        Duration.toSeconds(Platform.FrameClock.getDeltaTime())
}
