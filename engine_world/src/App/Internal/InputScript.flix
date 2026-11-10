// App.Internal.InputScript — 台本（FLIX_GE_INPUT_SCRIPT=<flow のパス>）を、実機のキー・マウス・パッド・フォーカスの代わりに読ませる。
// 実機のループ（Runner）の外に Platform.Input と Platform.FrameClock の handler を 1 枚ずつ重ねるだけなので、
// ループの実機の道（固定刻みの持ち越し・読み直し・F8・記録を書く所）は全部そのまま通る。決定性の門（make determinism）が、
// 隠しウィンドウに決まった操作を流して遊んだ記録を書かせるのに使う。
//
// 台本は flow の文法のうち、World を読まない手だけ（tap・hold・release・wait・mark とキー・点の的、押している状態を書く付け足し）。
// 役の名前・start・until・expect と、押した瞬間だけを指す付け足し（new=・click・moved）・dt を決める付け足し（ns=・dt=）は読む時に止める
// （ループの外の handler からは World が見えず、答えられるのは「今押している物」だけ）。各フレームの入力は flow の再生と同じ Frame（at=・look=・focus= などの読み方も同じ）。
// コマの切れ目は Platform.FrameClock.getDeltaTime を呼んだ数で数える（ループは 1 周に 1 回、入力を読む前に呼ぶ。Runner.readFrame）。
// dt は外の時計（実時間か FLIX_GE_FIXED_DT）のまま投げ直す — 台本の ns= は使わない。
// 台本を流し終えた次の周で、ループは窓を閉じた時と同じに抜ける（Runner.loop が isFinished を見る）。
// GLFW のキーの読み替え（LwjglInput の keyToGlfw）はこの道を通らない（そこは LwjglInput のテストが見る）。
pub mod App.Internal.InputScript {

    /// 流している途中の台本。frames = フレームごとの入力・ticks = getDeltaTime を呼んだ数（今のフレームは frames の ticks - 1 番）・
    /// wheelTaken / deltaTaken = このフレームのホイールと動いた量を読み切ったか（consume の op は 1 フレームに 1 回だけ値を返す）。
    pub type alias Playback = Ref[Cursor, Static]

    type alias Cursor = { frames = Vector[App.Frame], ticks = Int32, wheelTaken = Bool, deltaTaken = Bool }

    /// 台本を読み、フレームごとの入力に開く。読めない・World を読む手がある時は理由。
    pub def load(path: String): Result[String, Playback] \ Fs.FileRead + IO =
        framesOf(path) |> Result.map(frames -> Ref.fresh(Static, { frames = frames, ticks = 0, wheelTaken = false, deltaTaken = false }))

    /// 台本のフレームごとの入力（flow の再生と同じ Frame）。World の代わりに何もしない App で流す。
    pub def framesOf(path: String): Result[String, Vector[App.Frame]] \ Fs.FileRead =
        let blank: App.App[Unit, {}] = App.make(());
        let vocab = Flow.vocabOf(blank, ());
        match Flow.Parse.parseFile(vocab, path, Flow.Cli.readText) {
            case Err(problems) => Err(Flow.Parse.problemsText(problems) + "\n（台本に書けるのは tap・hold・release・wait とキー・点の的。役の名前・start・until・expect は World が要るので書けない）")
            case Ok(script) =>
                match script#lines |> List.findMap(line -> problemOf(line#step) |> Option.map(why -> "${line#file}:${Int32.toString(line#number)}: ${why}")) {
                    case Some(why) => Err(why)
                    case None      => playFrames(path, blank, script)
                }
        }

    /// 台本に書けない手（World を読む手・記録と再生だけの手）と、押している状態で答えられない付け足し。
    def problemOf(step: Flow.Step): Option[String] = match step {
        case Flow.Step.Tap(_, opt)     => edgeProblem(opt)
        case Flow.Step.Hold(_, _, opt) => edgeProblem(opt)
        case Flow.Step.Release(_, opt) => edgeProblem(opt)
        case Flow.Step.Wait(_, opt)    => edgeProblem(opt)
        case Flow.Step.Mark(_)         => None
        case _                         => Some("台本に書けるのは tap・hold・release・wait・mark だけ（ほかの手は World が要るか、記録の再生だけの物）")
    }

    /// handler は「今押している物」しか答えられないので、押した瞬間だけを指す付け足しと、dt を決める付け足しは効かない。
    def edgeProblem(opt: Flow.Opt): Option[String] =
        if (Option.nonEmpty(opt#pressed) or Option.nonEmpty(opt#click) or Option.nonEmpty(opt#otherClicks) or Option.nonEmpty(opt#moved))
            Some("new=・click・noclick・click=・moved・still は台本では効かない（押した瞬間は前のコマとの差から App が出す）")
        else if (not List.isEmpty(opt#ns) or Option.nonEmpty(opt#dt))
            Some("ns=・dt= は台本では効かない（dt は外の時計のまま）")
        else None

    def playFrames(path: String, blank: App.App[Unit, {}], script: Flow.Script): Result[String, Vector[App.Frame]] \ Fs.FileRead =
        Flow.play(blank, { design = Vec2.zero(), limit = 100000000 }, script, { world = (), state = App.freshStepState() })
                    |> Result.mapErr(failure -> "${path}:${Int32.toString(failure#at#number)}: ${failure#why}")
                    |> Result.map(outcome -> outcome#frames |> List.map(played -> played#step#frame) |> List.toVector)

    /// 台本を流し終えたか（最後のフレームの次の周に入った）。
    pub def isFinished(p: Playback): Bool \ IO =
        let c = Ref.get(p);
        c#ticks > Vector.length(c#frames)

    /// body の Platform.Input を台本から答え、Platform.FrameClock はコマを数えてから外の時計へ投げ直す。
    pub def drive(p: Playback, body: Unit -> a \ ef + Platform.Input + Platform.FrameClock): a \ ef + Platform.FrameClock + IO =
        run { body() } with handler Platform.Input {
            def isKeyPressed(key, k)          = k(Set.memberOf(key, current(p)#down))
            def getMousePosition(k)           = k(current(p)#cursor)
            def isMouseButtonPressed(b, k)    = k(Set.memberOf(b, current(p)#mouseButtons))
            def isGamepadTouched(k)           = k(current(p)#padTouched)
            def gamepadKind(k)                = k(current(p)#padKind)
            def gamepadSticks(k)              = k({ left = current(p)#leftStick, right = current(p)#rightStick })
            def consumeScrollDelta(k)         = k(takeWheel(p))
            def consumeMouseDelta(k)          = k(takeDelta(p))
            def isWindowFocused(k)            = k(current(p)#windowFocused)
        } with handler Platform.FrameClock {
            def getDeltaTime(k) = {
                Ref.put({ ticks = Ref.get(p)#ticks + 1, wheelTaken = false, deltaTaken = false | Ref.get(p) }, p);
                k(Platform.FrameClock.getDeltaTime())
            }
        }

    /// 今のフレームの入力。最初の getDeltaTime の前と、流し終えた後は何も触っていないフレーム（記録の再生の始まりと同じ手の様子）。
    def current(p: Playback): App.Frame \ IO =
        let c = Ref.get(p);
        Vector.nth(c#ticks - 1, c#frames) |> Option.getWithDefault(restFrame())

    def restFrame(): App.Frame =
        { cursor = { x = -100.0, y = -100.0 } | App.emptyFrame() }

    def takeWheel(p: Playback): Float64 \ IO =
        let c = Ref.get(p);
        if (c#wheelTaken) 0.0
        else {
            Ref.put({ wheelTaken = true | c }, p);
            current(p)#wheel
        }

    def takeDelta(p: Playback): Vec2.Vec2 \ IO =
        let c = Ref.get(p);
        if (c#deltaTaken) Vec2.zero()
        else {
            Ref.put({ deltaTaken = true | c }, p);
            current(p)#mouseDelta
        }
}
