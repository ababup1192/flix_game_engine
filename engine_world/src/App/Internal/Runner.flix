// App.Internal.Runner — 実機のループ: 起動の World を決め、閉じるまで 1 コマずつ回す（入力の取り込み・閉じる要求・リモートデバッグ・F8・Doc の読み直し・進める・鳴らす・描く）。
// ループの状態（LoopState）はここだけが持つ。ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Runner {
    import java.lang.System
    import java.lang.{Object => JObject}

    /// 起動の World: 登録簿が無ければ init + 起動時の系、あれば頼まれた始まり（Ok(None) なら先頭の始まり）。
    /// 始まりの下地は、reread なら freshWorld（Doc を全部読み直す）、そうでなければ init + 起動時の系。
    /// 返すのは起動の World と、通った始まり（名前と書いた引数。登録簿が無ければ None）。誤りの訳には出どころ（START など）を付けない。
    // WhyNot: 記録しない起動で Doc を読み直さない — main が読んだばかりの物をもう一度読むだけで、重い Doc（3D の形）では起動が秒単位で延びる。
    /// 始まりがギャラリーの場面（shot:）なら、DEBUG の起動の時だけ通す。
    def bootFrom(app: App[w, ef], design: Vec2.Vec2, request: App.Internal.DevTools.StartRequest, reread: Bool): App.Internal.DevTools.Booted[w] \ ef + Fs.FileRead =
        let r = App.rec(app);
        let base = () -> if (reread) App.freshWorld(app, design) else App.initialWorld(app, design);
        let first = List.head(r#starts) |> Option.map(start -> (start#name, Map.empty()));
        let wanted = if (List.isEmpty(r#starts) and List.isEmpty(r#shots)) Ok(None)
                     else request |> Result.map(asked -> match asked {
                         case None => first
                         // 登録簿の無いゲームが始まりを頼んでも、今までどおり init から始める（ギャラリーの場面だけは引く）。
                         case Some((name, args)) => if (List.isEmpty(r#starts) and not App.isShotName(name)) None else Some((name, args))
                     });
        match wanted {
            case Err(why)    => Err(why)
            case Ok(None)    => Ok((App.initialWorld(app, design), None))
            case Ok(Some((name, args))) =>
                if (App.isShotName(name) and not r#debug) Err("ギャラリーの場面 ${name} は DEBUG の起動だけで開ける（make debug・SHOT=<名前> make run）")
                else App.buildStartOn(app, base(), name, args) |> Result.map(world -> (world, Some((name, args))))
        }

    /// project.json の clearColor を画面の地の色として App に持たせる（後がけの場面の Pass を消す色の既定）。読めなければ黒のまま 1 行言う。
    // WhyNot: backend が読んだ config から取らない — Platform に口が要る（機種ごとの handler を全部触る）。根は "." で、withProject(".") と同じ所を読む。
    def withProjectClear(app: App[w, ef]): App[w, ef] \ Fs.FileRead = match ProjectLoader.loadProject(".") {
        case Ok(loaded) => App.withScreenClear(loaded#config#clearColor, app)
        case Err(why)   => Log.fellBackThen("app", "project.json の clearColor", "黒", why, app)
    }

    /// 開発の道具（hooks）を開いて起動の World を組み、閉じるまでループを回し、道具を閉じる。
    /// downloads = 届いていない後回しの物を待つ時の機種の API（None は待たない: bench）。
    pub def runLoop(app0: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], downloads: Option[LoadProgress.AssetDownloads]): Unit \ (ef + efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        // 下ごしらえの間、画面にはバックエンドが最後に出した起動画面（「preparing game...」）が出たまま残る。
        // 長い下ごしらえは、ゲームが LoadProgress.report で区切りを知らせ、バックエンドの handler が起動画面を進める。
        // WhyNot: ここで起動画面を出し直さない — 間引きも中止スイッチも持たない 2 つ目の経路が生まれる。
        let design = Platform.Window.getViewportRect()#size;
        let app = withProjectClear(app0);
        let (booted, opened) = hooks#open((request, reread) -> bootFrom(app, design, request, reread));
        let (closing, last) = match booted {
            // 知らない始まりの名前で黙って先頭の場面から始めると、別の場面を見て直していることに気づけない。
            case Err(why)  => System.err.println("[App] ${why}"); (opened, None)
            case Ok((world0, started)) =>
                let play = () -> launchFrom(app, hooks, design, world0, isShotStart(started), downloads, opened);
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
    // WhyNot: withPipelinedRendering の App で待たない — 照らす前に次のコマの traceFrame を預けてしまう順で、捨てる道が無い。
    def launchFrom(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], design: Vec2.Vec2, world0: w, halted: Bool,
                   downloads: Option[LoadProgress.AssetDownloads],
                   tools: App.Internal.DevTools.State): (App.Internal.DevTools.State, w) \ (ef + efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let assets = if (r#pipelinedRendering) None else Option.map(assetWatchOf, downloads);
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
                    outputKeys = App.Internal.Output.keysAfterJump(app, world0, Nil), tools = started,
                    assets = assets, loadWait = App.Internal.LoadWait.initial(),
                    waitSettings = App.Internal.LoadWait.defaultSettings(), publishedWait = None })

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
        tools = App.Internal.DevTools.State,
        // 届いていない後回しの物を待つ機種の APIと、届いていない名前の控え（None = 待たない App）。
        assets = Option[AssetWatch],
        // 待ちの状態と押した所の控え（App.Internal.LoadWait）・待ちの決まりの数・最後に機種と World へ知らせた待ち。
        loadWait = App.Internal.LoadWait.State[w], waitSettings = App.Internal.LoadWait.Settings,
        publishedWait = Option[LoadProgress.LoadWait]
    }

    /// 届いていない名前の控え。gen = 最後に読んだ時の missingGen（変わるまで missing と policies を読み直さない）・
    /// policies = 届いていない名前ごとの扱い。
    type alias AssetWatch = { downloads = LoadProgress.AssetDownloads, gen = Int32, missing = Set[String],
                              policies = Map[String, LoadProgress.MissingPolicy] }

    /// 機種の APIから、今の届いていない名前と扱いを読む。
    def assetWatchOf(downloads: LoadProgress.AssetDownloads): AssetWatch \ IO =
        let missing = downloads#missing();
        { downloads = downloads, gen = downloads#missingGen(), missing = missing,
          policies = missing |> Set.toList |> List.map(name -> (name, downloads#policyOf(name))) |> List.toMap }

    /// missingGen が変わった時だけ読み直す。
    def refreshAssetWatch(watch: AssetWatch): AssetWatch \ IO =
        if (watch#downloads#missingGen() == watch#gen) watch else assetWatchOf(watch#downloads)

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
                let (nextAnno, ticket, painted) = App.Internal.Halt.pausedStep(app, hooks#saveAnnotation, st#warnOnce, st#design, Platform.Window.getDisplay(), st#world, st#history, frame,
                    { paused = true | st#anno },
                    { tileCache = st#tileCache, glyphSeen = st#glyphSeen, budgetWarned = st#budgetWarned });
                Platform.Window.presentFrame();
                // チケットに、ここまでの遊んだ記録の写し（再生すると表示中の瞬間で止まる）を入れる。
                Option.forEach(dir -> hooks#copyRecordInto(st#tools, dir, nextAnno#scrub), ticket);
                loop(app, hooks, { anno = nextAnno, cursorShown = App.CursorLook.State.Stale, captureShown = None,
                                   tileCache = painted#tileCache, glyphSeen = painted#glyphSeen,
                                   budgetWarned = painted#budgetWarned | st })
            case Branch.Resuming =>
                let resumed = resumingStep(app, hooks, Platform.Window.getDisplay(), st);
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
    def readFrame(st0: LoopState[w]): App.Frame \ (Platform.Input + Platform.Window + Platform.FrameClock) =
        let dt = readDt();
        let cursorNow = App.Internal.Frame.heldCursor(st0#captureShown, st0#prevCursor, Platform.Input.getMousePosition());
        let held = mouseButtonsHeld();
        let sticks = Platform.Input.gamepadSticks();
        App.withMouseButtons(st0#prevMouseButtons, held, { realNow = Clock.nowOf(st0#stepState#real), padTouched = Platform.Input.isGamepadTouched(),
          padKind = Platform.Input.gamepadKind(), leftStick = sticks#left, rightStick = sticks#right, mouseDelta = Platform.Input.consumeMouseDelta(),
          windowFocused = Platform.Input.isWindowFocused(), sizeClass = Platform.Window.getDisplay()#sizeClass,
          diagnostics = st0#lastDiagnostics
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
    def resumingStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], display: Display.Display, st: LoopState[w]): LoopState[w] \ (ef + Platform.Rendering + RenderTarget.Target + IO) =
        let r = App.rec(app);
        let resumed = App.resumePoint(st#anno, st#history, st#world);
        hooks#recordJump(if (st#anno#scrub > 0) Some("rewind ${Int32.toString(st#anno#scrub)}") else None,
                         resumed#world, st#tools);
        let (cache1, seen1, warned1) = App.Internal.Paint.renderFrame(app, st#warnOnce, st#lastDiagnostics, st#design, display, resumed#world, App.Internal.Paint.plainLook(App.Internal.Paint.fpsOverlayOf(r, st#design, resumed#anno)), st#tileCache, st#glyphSeen, st#budgetWarned);
        { world = resumed#world, anno = resumed#anno, history = resumed#history,
          tileCache = cache1, glyphSeen = seen1, budgetWarned = warned1,
          outputKeys = App.Internal.Output.keysAfterJump(app, resumed#world, st#outputKeys) | st }

    /// ふつうのフレーム: World を進めて（traceFrame）、音を鳴らし、描き、見張り・履歴・出力・窓の宣言を済ませた次の状態。
    def runningStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        // 止めていた間・リモートのコマで塗った分は、このコマの診断に混ぜない。
        let collecting = r#diagnostics or hooks#wantsDiagnostics(st#tools);
        if (collecting) discard Platform.Diagnostics.consumeDiagnostics() else ();
        let (watched, watchedTools, watchFired) = hooks#beginFrame(frame#dt, st#world, st#tools);
        let (reloaded, reloadFired) = applyReload(r, frame, watched, f -> hooks#runReload(watchedTools, "key", f));
        let assets = Option.map(refreshAssetWatch, st#assets);
        let opened = { reloaded = reloaded, tools = watchedTools, fired = watchFired or reloadFired, collecting = collecting };
        match assets |> Option.flatMap(a -> slowWatchOf(a, st#loadWait) |> Option.map(watch -> (a, watch))) {
            case None              => fastStep(app, hooks, frame, frameStart, { assets = assets | st }, opened)
            case Some((a, watch)) => slowStep(app, hooks, frame, frameStart, { assets = Some(a) | st }, opened, a, watch)
        }

    /// 進める前に済ませた物（読み直した World・道具の状態・読み直しが起きたか・診断を集めるか）。
    type alias Opened[w] = { reloaded = w, tools = App.Internal.DevTools.State, fired = Bool, collecting = Bool }

    /// 待ちを見るコマなら、そのための機種の様子（届いていない物も待ちも控えも無く、コードがそろい、ロゴも出ていなければ None）。
    def slowWatchOf(a: AssetWatch, state: App.Internal.LoadWait.State[w]): Option[App.Internal.LoadWait.Watch] \ IO =
        let codeReady = a#downloads#getCodeLoadState() == LoadProgress.LoadState.Loaded;
        let splash = a#downloads#isSplashShowing();
        if (App.Internal.LoadWait.isFastFrame(a#missing, codeReady, splash, state)) None
        else {
            let failed = App.Internal.LoadWait.waitingNames(state) |> Set.filter(name -> isFailed(a#downloads#stateOf(name)));
            Some({ missing = a#missing, failed = failed, codeReady = codeReady, splash = splash, nowSec = nowSec() })
        }

    def isFailed(state: LoadProgress.LoadState): Bool = match state {
        case LoadProgress.LoadState.Failed(_) => true
        case _                                => false
    }

    /// 待ちの秒を数える時刻（秒・差だけを使う）。
    def nowSec(): Float64 \ IO = Int64.toFloat64(System.nanoTime()) / 1000000000.0

    /// 待ちを見ないふつうのコマ: World を進めて（traceFrame）、音を鳴らし、描き、見張り・履歴・出力・窓の宣言を済ませた次の状態。
    def fastStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w], opened: Opened[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let collecting = opened#collecting;
        let watchedTools = opened#tools;
        let fired = opened#fired;
        // WhyNot: 後回しの素材を traceFrame の中で読まない — 系を純粋のまま保ち、trace・台本・/step が同じ World を出すため。
        let loaded = App.stepBackgroundLoad(app, opened#reloaded);
        // WhyNot: 重ねる App で進めた後の World（advanced）を描かない — 進め終わるのを待ってからでないと描けず、重ねる分が無くなる。
        if (r#pipelinedRendering) submitTraceFrame(app, frame, st#stepState, loaded) else ();
        let paintedEarly = if (r#pipelinedRendering) Some(paintAndPresent(app, st, frame, loaded, fired)) else None;
        let waitStart = System.nanoTime();
        // 1 フレームの中身は trace・台本・/step と同じ traceFrame の 1 本（音の名前もここで導く）。
        let (traced, nextStepState) = if (r#pipelinedRendering) joinTraceFrame() else App.traceFrame(app, frame, st#stepState, loaded);
        let updatedAt = System.nanoTime();
        let advanced = traced#after;
        hooks#recordFrame(watchedTools, frame, advanced);
        let (nextSustaining, nextMix, nextUses) = App.Internal.Output.applyAudio(r, frame#dt, traced,
                                                   st#sustaining, st#mixState, st#soundUses, st#warnOnce);
        // fps は debug 有効時だけ計測する（本番ビルドは履歴を積まず無負荷）。
        let measuredAnno = if (r#debug) Annotate.recordDt(frame#dt, st#anno) else st#anno;
        let ((cache1, seen1, warned1), renderNs) = match paintedEarly {
            case Some(done) => done
            case None       => paintAndPresent(app, { anno = measuredAnno | st }, frame, advanced, fired)
        };
        // 診断はここで 1 回だけ引き取り、ヒッチの記録と次のフレームの Frame#diagnostics・ViewCtx#diagnostics へ配る。
        let diag = if (collecting) Some(Platform.Diagnostics.consumeDiagnostics()) else None;
        let nextTools = hooks#endFrame(watchedTools,
            { frame = measuredAnno#frame, start = frameStart, updateNs = if (r#pipelinedRendering) updatedAt - waitStart else updatedAt - frameStart,
              renderNs = renderNs,
              pressed = frame#justPressed, reloaded = fired }, diag, advanced);
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

    /// 待ちを見るコマで出す物。world = 出す World・stepState = 次のコマへ渡す StepState・trace = 当てる音（None は音を当てない）・
    /// recorded = 遊んだ記録に書く入力（World へ入力を渡したコマだけ）・loadWait = 次の待ちの状態。
    type alias Shown[w] = { world = w, stepState = App.StepState, trace = Option[App.TraceStep[w]], recorded = Option[App.Frame],
                            loadWait = App.Internal.LoadWait.State[w] }

    /// 待ちを見るコマ（ブラウザ版で届いていない物があるか、待ちか控えの最中）: 進める前の手を決め（LoadWait.plan）、進めた候補を
    /// 照らし（LoadWait.decide）、答えの World を描いて出す。届いていない名前の集まりは withLoadWait で World へ写した後に進める。
    def slowStep(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w],
                 opened: Opened[w], a: AssetWatch, watch: App.Internal.LoadWait.Watch): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let (step, planned) = App.Internal.LoadWait.plan(st#waitSettings, frame, watch, opened#reloaded, st#stepState, st#loadWait);
        noteGaveUp(st#loadWait, planned, watch#nowSec);
        let published = App.Internal.LoadWait.published(planned, watch#missing, watch#nowSec);
        noticeLoadWait(a, st#publishedWait, published);
        let (stepped, stores) = App.Internal.BackgroundLoad.stepAll(r, opened#reloaded);
        let loaded = viewLoadWait(r, st#publishedWait, published, stepped);
        let held = { real = Clock.advance(Clock.paceOf(Clock.Run.Running), frame#dt, st#stepState#real) | st#stepState };
        let measuredAnno = if (r#debug) Annotate.recordDt(frame#dt, st#anno) else st#anno;
        let base = { anno = measuredAnno, publishedWait = published | st };
        let still = { world = loaded, stepState = held, trace = None, recorded = None, loadWait = planned };
        match step {
            case App.Internal.LoadWait.Step.Splash         => showSlow(app, hooks, frame, frameStart, base, opened, still)
            case App.Internal.LoadWait.Step.Hold           => showSlow(app, hooks, frame, frameStart, base, opened, { trace = Some(stillTrace(r, frame, loaded, Nil)) | still })
            case App.Internal.LoadWait.Step.Advance(input) =>
                let ctx = { missing = watch#missing, policies = a#policies, nowSec = watch#nowSec, frame = givenFrameOf(frame, input),
                            loaded = loaded, stepState = st#stepState, real = held#real, stored = List.map(s -> s#replay, stores),
                            styleOf = r#loadWaitStyle };
                advanceSlow(app, hooks, frame, frameStart, base, opened, ctx, planned)
        }

    /// 進める時に World へ渡す入力。
    def givenFrameOf(frame: App.Frame, input: App.Internal.LoadWait.Input): App.Frame = match input {
        case App.Internal.LoadWait.Input.Live         => frame
        case App.Internal.LoadWait.Input.Idle         => App.Internal.LoadWait.idleFrameOf(frame)
        case App.Internal.LoadWait.Input.Replay(held) => App.Internal.LoadWait.replayFrameOf(frame, held)
    }

    /// 1 コマ進めて組み、その候補を照らして、出すか捨てるかの答えのとおりに描いて出す。
    /// 作る途中で後から取るコードがそろっていなかった候補は捨てる（系と View は純粋なので、途中で捨てても外へ出た物は無い）。
    def advanceSlow(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w],
                    opened: Opened[w], ctx: App.Internal.LoadWait.Context[w], planned: App.Internal.LoadWait.State[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let pressed = App.Internal.LoadWait.isPressFrame(ctx#frame, st#stepState);
        // WhyNot: withLoadGate と出力の鍵をこの外で引かない — どちらもゲームのコードで、後から取るコードに触れうる。
        let attempt = App.Internal.LoadWait.catchCodeNotReady(() -> {
            let (traced, next) = App.traceFrame(app, ctx#frame, st#stepState, ctx#loaded);
            let built = buildFor(app, st, frame, traced#after, planned);
            (traced, next, built, candidateOf(app, st, pressed, traced, built))
        });
        let candidate = attempt |> Option.map(match (_, _, _, c) -> c)
            |> Option.getWithDefault({ names = Set.empty(), sounds = Nil, loops = Nil, failed = true, pressed = pressed, outputsChanged = false });
        let (show, decided) = App.Internal.LoadWait.decide(candidate, ctx, planned);
        match (show, attempt) {
            case (App.Internal.LoadWait.Show.Candidate(sounds), Some((traced, next, built, _))) =>
                let out = { world = traced#after, stepState = next, trace = Some({ sounds = sounds | traced }), recorded = Some(ctx#frame), loadWait = decided };
                emitSlow(app, hooks, frame, frameStart, st, opened, ctx, planned, candidate, out, built)
            case _ => showSlow(app, hooks, frame, frameStart, st, opened, shownOf(r, frame, ctx, show, decided))
        }

    /// 照らす候補（描く物の名前と withLoadGate の名前・音・作れたか・押した入力か・外への出力の鍵が変わるか）。
    def candidateOf(app: App[w, ef], st: LoopState[w], pressed: Bool, traced: App.TraceStep[w],
                    built: Option[App.Internal.Paint.Built]): App.Internal.LoadWait.Candidate \ ef =
        let r = App.rec(app);
        let drawn = built |> Option.map(App.Internal.Paint.assetNamesOf) |> Option.getWithDefault(Set.empty());
        let gated = r#loadGate |> Option.map(f -> f(traced#after)) |> Option.getWithDefault(Nil);
        { names = List.foldLeft((acc, name) -> Set.insert(name, acc), drawn, gated), sounds = traced#sounds,
          loops = List.map(s -> s#name, traced#sustained), failed = false, pressed = pressed,
          outputsChanged = not List.isEmpty(App.Internal.Output.dueOutputs(app, traced#after, st#outputKeys)) }

    /// 候補を出す: 描いて出し、描く途中で後から取るコードがそろっていなかったら、そのコマは画面へ出さず、候補を捨てた時と同じ答えにする
    /// （描き手の今のコマの命令に半分積んだ物が残るので、同じコマで前の World を描き足さない。次のコマで描く）。
    def emitSlow(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w],
                 opened: Opened[w], ctx: App.Internal.LoadWait.Context[w], planned: App.Internal.LoadWait.State[w],
                 candidate: App.Internal.LoadWait.Candidate, out: Shown[w], built: Option[App.Internal.Paint.Built]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let noticed = noticeShown(st, out);
        match paintGuarded(app, noticed, built, out#world, opened#fired) {
            case Some(painted) => finishSlow(app, hooks, frame, frameStart, noticed, opened, out, Some(painted))
            case None          =>
                let (show, decided) = App.Internal.LoadWait.decide({ failed = true, names = Set.empty(), sounds = Nil, loops = Nil | candidate }, ctx, planned);
                let failedOut = shownOf(App.rec(app), frame, ctx, show, decided);
                finishSlow(app, hooks, frame, frameStart, noticeShown(noticed, failedOut), opened, failedOut, None)
        }

    /// 候補を捨てた答えの出す物（進める前の World か、押した所の控えへ戻した World。どちらも系を進めない）。
    def shownOf(r: App.Rec[w, ef], frame: App.Frame, ctx: App.Internal.LoadWait.Context[w], show: App.Internal.LoadWait.Show[w],
                decided: App.Internal.LoadWait.State[w]): Shown[w] \ ef =
        let held = { real = ctx#real | ctx#stepState };
        let (world, stepState, chime) = match show {
            case App.Internal.LoadWait.Show.Restored(w, s, sounds) => (w, s, sounds)
            case App.Internal.LoadWait.Show.Loaded(sounds)         => (ctx#loaded, held, sounds)
            case App.Internal.LoadWait.Show.Candidate(_)           => (ctx#loaded, held, Nil)
        };
        { world = world, stepState = stepState, trace = Some(stillTrace(r, frame, world, chime)), recorded = None, loadWait = decided }

    /// 進めずに出す World の音: 一発の音は chime だけ、鳴り続ける音はその World の宣言（ミキサーのフェードは dt で進む）。
    def stillTrace(r: App.Rec[w, ef], frame: App.Frame, world: w, chime: List[String]): App.TraceStep[w] \ ef =
        { frame = frame, before = world, after = world, sounds = chime, sustained = (r#sustained)(world) }

    /// world を組む（fps の重ねは st#anno から・待ちの表示は st#publishedWait と waitState の押した点から）。
    def buildFor(app: App[w, ef], st: LoopState[w], frame: App.Frame, world: w, waitState: App.Internal.LoadWait.State[w]): Option[App.Internal.Paint.Built] \ (ef + Platform.GpuResources + Platform.Window) =
        let r = App.rec(app);
        let display = Platform.Window.getDisplay();
        let waiting = App.Internal.Paint.loadingOverlayOf(app, st#warnOnce, st#design, display, st#publishedWait, App.Internal.LoadWait.pressPointOf(waitState));
        let fps = App.Internal.Paint.fpsOverlayOf(r, st#design, st#anno);
        App.Internal.Paint.buildPainted(app, st#warnOnce, frame#diagnostics, st#design, display, world,
                                        App.Internal.Paint.plainLook(if (List.isEmpty(waiting)) fps else List.append(waiting, fps)), st#tileCache)

    /// 組んだ World を描いて画面へ出す。後から取るコードがそろう前の例外で描けなかったら None（画面へは出さない）。
    def paintGuarded(app: App[w, ef], st: LoopState[w], built: Option[App.Internal.Paint.Built], world: w, bump: Bool):
            Option[((App.Internal.Paint.TileCache, Option[Int64], Bool), Int64)] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + IO) =
        let start = System.nanoTime();
        App.Internal.LoadWait.catchCodeNotReady(() ->
            App.Internal.Paint.submitPainted(app, st#warnOnce, st#design, world, built, App.Internal.Paint.bumpTileGen(bump, st#tileCache), st#glyphSeen, st#budgetWarned))
            |> Option.map(painted -> { Platform.Window.presentFrame(); (painted, System.nanoTime() - start) })

    /// 進めずに出す World（ロゴの間・描き直す待ち・捨てた候補の代わり）を組んで描いて出す。
    def showSlow(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w],
                 opened: Opened[w], out: Shown[w]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let noticed = noticeShown(st, out);
        let built = buildFor(app, noticed, frame, out#world, out#loadWait);
        finishSlow(app, hooks, frame, frameStart, noticed, opened, out, paintGuarded(app, noticed, built, out#world, opened#fired))

    /// 待ちを見るコマの後半: 音・見張り・記録・履歴・出力・窓の宣言（ふつうのコマと同じ順）。painted が None（描けなかった）なら音を当てない。
    /// 音・出力・窓の宣言で後から取るコードがそろう前の例外が出たら、そのコマは当てずに前の状態のまま（次のコマで当て直す）。
    def finishSlow(app: App[w, ef], hooks: App.Internal.DevTools.Hooks[w, ef, efTools], frame: App.Frame, frameStart: Int64, st: LoopState[w],
                   opened: Opened[w], out: Shown[w], painted: Option[((App.Internal.Paint.TileCache, Option[Int64], Bool), Int64)]): LoopState[w] \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + GameEngine.Audio + Platform.Diagnostics + Platform.Tasks + Fs.FileRead + Fs.FileWrite + IO) =
        let r = App.rec(app);
        let audioBefore = (st#sustaining, st#mixState, st#soundUses);
        let trace = if (Option.isEmpty(painted)) None else out#trace;
        let (nextSustaining, nextMix, nextUses) = trace
            |> Option.flatMap(t -> App.Internal.LoadWait.catchCodeNotReady(() -> App.Internal.Output.applyAudio(r, frame#dt, t, st#sustaining, st#mixState, st#soundUses, st#warnOnce)))
            |> Option.getWithDefault(audioBefore);
        Option.forEach(given -> hooks#recordFrame(opened#tools, given, out#world), out#recorded);
        let ((cache1, seen1, warned1), renderNs) = Option.getWithDefault(((st#tileCache, st#glyphSeen, st#budgetWarned), 0i64), painted);
        let diag = if (opened#collecting) Some(Platform.Diagnostics.consumeDiagnostics()) else None;
        let nextTools = hooks#endFrame(opened#tools,
            { frame = st#anno#frame, start = frameStart, updateNs = System.nanoTime() - frameStart - renderNs, renderNs = renderNs,
              pressed = frame#justPressed, reloaded = opened#fired }, diag, out#world);
        let nextHistory = if (App.canDebug(r)) List.take(App.historyLimit(), out#world :: st#history) else Nil;
        let written = App.Internal.LoadWait.catchCodeNotReady(() -> App.Internal.Output.writeOutputs(app, out#world, st#outputKeys))
            |> Option.getWithDefault(st#outputKeys);
        let declared = App.Internal.LoadWait.catchCodeNotReady(() -> applyDeclared(r, out#world, st))
            |> Option.getWithDefault({ cursorShown = App.CursorLook.State.Stale, captureShown = None });
        { world = out#world, history = nextHistory,
          outputKeys = written, cursorShown = declared#cursorShown, captureShown = declared#captureShown,
          lastDiagnostics = if (r#diagnostics) diag else None,
          anno = { frame = st#anno#frame + 1i64 | st#anno },
          stepState = out#stepState, tools = nextTools, loadWait = out#loadWait,
          sustaining = nextSustaining, mixState = nextMix, soundUses = nextUses, tileCache = cache1,
          glyphSeen = seen1, budgetWarned = warned1 | st }

    /// 待ちを諦めた名前が増えたコマに、名前と待った秒を 1 行言う（その名前は以後、描かず・鳴らさずに進む）。
    def noteGaveUp(before: App.Internal.LoadWait.State[w], after: App.Internal.LoadWait.State[w], nowSec: Float64): Unit \ IO =
        let given = Set.difference(after#gaveUp, before#gaveUp);
        if (Set.isEmpty(given)) ()
        else {
            let waited = App.Internal.LoadWait.published(before, given, nowSec) |> Option.map(lw -> lw#waited) |> Option.getWithDefault(0.0);
            Log.fellBack("load-wait", String.intercalate(", ", Set.toList(given)), "描かず・鳴らさずに進む", "${Float64.toString(waited)} 秒待っても届かない")
        }

    /// 出すコマの待ち（照らした後の状態）を、描いて出す前に機種へ知らせる（頁は待ちのあるコマで起動の画面を外さない）。
    // WhyNot: 進める前の状態の待ちだけを知らせない — 待ちに入ったコマが待ちの無いコマとして出て、頁が起動の画面を外す。
    def noticeShown(st: LoopState[w], out: Shown[w]): LoopState[w] \ IO = match st#assets {
        case None    => st
        case Some(a) =>
            let now = App.Internal.LoadWait.published(out#loadWait, a#missing, nowSec());
            noticeLoadWait(a, st#publishedWait, now);
            { publishedWait = now | st }
    }

    /// 今の待ちが前に知らせた物から変わった時だけ機種へ知らせる（待った秒だけの変化は知らせない）。
    def noticeLoadWait(a: AssetWatch, before: Option[LoadProgress.LoadWait], now: Option[LoadProgress.LoadWait]): Unit \ IO =
        let shape = Option.map(lw -> (lw#reason, lw#names, lw#progress, lw#pressed));
        if (shape(before) == shape(now)) () else a#downloads#setLoadWait(now)

    /// withLoadWait があれば、今の待ちを World へ写す（待っている間は毎コマ・明けたコマに 1 回 None）。
    def viewLoadWait(r: App.Rec[w, ef], before: Option[LoadProgress.LoadWait], now: Option[LoadProgress.LoadWait], world: w): w =
        match r#loadWaitView {
            case Some(f) if Option.nonEmpty(now) or Option.nonEmpty(before) => f(now, world)
            case _                                                          => world
        }

    /// world を描いて画面へ出し、塗りの持ち回しと、描いて出すまでの時間（ns）を返す。fps の重ね書きは st#anno から。
    /// bump = Doc の読み直しが起きたコマ（タイル層の世代を進め、同じ key でも作り直す）。
    // WhyNot: 画面へ出すのをループ（止めた画面・再開のコマと同じ所）へ回さない — ヒッチの記録の描く時間は swap まで含めて測ってきた。
    def paintAndPresent(app: App[w, ef], st: LoopState[w], frame: App.Frame, world: w, bump: Bool):
            ((App.Internal.Paint.TileCache, Option[Int64], Bool), Int64) \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + IO) =
        let r = App.rec(app);
        let start = System.nanoTime();
        let painted = App.Internal.Paint.renderFrame(app, st#warnOnce, frame#diagnostics, st#design, Platform.Window.getDisplay(), world,
                          App.Internal.Paint.plainLook(App.Internal.Paint.fpsOverlayOf(r, st#design, st#anno)),
                          App.Internal.Paint.bumpTileGen(bump, st#tileCache), st#glyphSeen, st#budgetWarned);
        Platform.Window.presentFrame();
        (painted, System.nanoTime() - start)

    /// world から 1 コマ進める traceFrame を Platform.Tasks へ預ける（受け取るのは joinTraceFrame）。
    // WhyNot: traceFrame の効果を型のまま預けない — 預けた先のスレッドには handler が無い。呼ぶのは withPipelinedRendering の App（効果が無いと型で決まった物）だけ。
    def submitTraceFrame(app: App[w, ef], frame: App.Frame, stepState: App.StepState, world: w): Unit \ Platform.Tasks =
        let detached = unchecked_cast((() -> App.traceFrame(app, frame, stepState, world)) as Unit -> (App.TraceStep[w], App.StepState) \ IO);
        Platform.Tasks.startTask(() -> unchecked_cast(detached() as JObject))

    /// submitTraceFrame で預けた traceFrame の結果を受け取る。
    def joinTraceFrame(): (App.TraceStep[w], App.StepState) \ Platform.Tasks = unchecked_cast(Platform.Tasks.finishTask() as (App.TraceStep[w], App.StepState))

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
