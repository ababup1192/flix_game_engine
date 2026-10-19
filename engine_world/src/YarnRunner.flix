// YarnRunner — 会話のシナリオ（Yarn.Program）の木を直に辿って、台詞・選択肢・コマンドを順に出す実行器（純粋）。
//
//   let (runner, events) = YarnRunner.start(program, "op_desk", now)      ノードの頭から、最初に待つ所まで流す
//   let (runner, events) = YarnRunner.step(Action.Advance, now, runner)   台詞を送る
//   let (runner, events) = YarnRunner.step(Action.Choose(1), now, runner) 選択肢を選ぶ（0 始まり）
//   let (runner, events) = YarnRunner.step(Action.Tick, now, runner)      毎フレーム。<<wait 秒>> の時刻が来たら続きを流す
//
// 出来事（Event）は Line・Choices・Command・Done の 4 つで、返した列はその呼び出しの間に起きた物だけ。
// 今出している物の正は shownOf の 1 つ（出来事の列は World に溜めない。文字送りは UiDialog の仕事）。
// 音を鳴らしたい出来事は、受けた所でゲームが自分の Emit に写す（ここで Emit を使うと、ゲームの Emit と型がぶつかる E6795）。
// <<wait>> の時刻は型で分けた時計の時刻で持つ（止めている間は時計ごと止まるので、待ちも止まる）。
pub mod YarnRunner {

    /// 呼び出しの間に起きた出来事。
    ///   Line     … 台詞を出した（Advance を待つ）
    ///   Choices  … 選択肢を出した（Choose を待つ。並びはシナリオの順）
    ///   Command  … コマンドを通った（wait なら Tick で時刻が来るまで待つ・それ以外は待たずに続ける）
    ///   Done     … 会話が終わった（<<stop>>・ノードの終わり・行き先の無い jump）
    pub enum Event {
        case Line(Yarn.Line)
        case Choices(List[Yarn.Line])
        case Command(Yarn.Command)
        case Done
    }

    /// 実行器への入力。Choose の番号は 0 始まり。
    pub enum Action with Eq, ToString {
        case Advance
        case Choose(Int32)
        case Tick
    }

    /// 今出している物。Closed = 開いていない・終わった、Waiting = <<wait>> の途中。
    pub enum Shown {
        case Closed
        case Line(Yarn.Line)
        case Choices(List[Yarn.Line])
        case Waiting
    }

    /// node = 開いているノード（閉じていれば空）、stack = これから流す文の並び（選択肢の中身を流す間は、
    /// 選択肢の後ろの文がその下に残る）、pending = 出している選択肢、waitUntil = <<wait>> が明ける時刻。
    enum Machine[c]({
        program = Yarn.Program,
        node = String,
        stack = List[List[Yarn.Statement]],
        shown = Shown,
        pending = List[Yarn.Choice],
        waitUntil = Option[Clock.Time[c]]
    })

    /// 実行器。c は <<wait>> を測る時計の名前（ゲームの物語の時計など）。外では start と closed だけが作る。
    pub type alias Runner[c] = Machine[c]

    /// 1 回の呼び出しで流す文の上限。台詞の無いノードどうしが jump し合うシナリオでも必ず止まる。
    def fuel(): Int32 = 10000

    /// 開いていない実行器（World の初期値）。
    pub def closed(): Runner[c] =
        Machine.Machine({ program = Yarn.empty(), node = "", stack = Nil, shown = Shown.Closed, pending = Nil, waitUntil = None })

    /// node の頭から、最初に待つ所（台詞・選択肢・wait）か終わりまで流す。node が無ければすぐ Done。
    pub def start(program: Yarn.Program, node: String, now: Clock.Time[c]): (Runner[c], List[Event]) =
        let begin = Machine.Machine({ program = program, node = node, stack = Nil, shown = Shown.Closed, pending = Nil, waitUntil = None });
        match Yarn.nodeOf(node, program) {
            case Some(found) => flow(fuel(), now, withStack(found#body :: Nil, begin), Nil)
            case None        => finish(begin, Nil)
        }

    /// 入力 1 つ。今の状態で意味の無い入力（台詞の無い時の Advance・範囲の外の Choose・時刻の前の Tick）は何も変えない。
    pub def step(action: Action, now: Clock.Time[c], runner: Runner[c]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = runner;
        match (action, m#shown) {
            case (Action.Advance, Shown.Line(_))     => flow(fuel(), now, runner, Nil)
            case (Action.Choose(i), Shown.Choices(_)) => match List.nth(i, m#pending) {
                case Some(choice) =>
                    let resumed = Machine.Machine({ pending = Nil, stack = choice#body :: m#stack | m });
                    flow(fuel(), now, resumed, Nil)
                case None => (runner, Nil)
            }
            case (Action.Tick, Shown.Waiting) => match m#waitUntil {
                case Some(until) if now >= until => flow(fuel(), now, Machine.Machine({ waitUntil = None | m }), Nil)
                case _                           => (runner, Nil)
            }
            case _ => (runner, Nil)
        }

    /// node の頭から、台詞はすぐ送り・選択肢は picks の順に選び（0 始まり）・<<wait>> は明ける時刻まで飛ばして、
    /// 終わるか picks が尽きた選択肢までの出来事を返す（画面なしのテスト・シナリオの通し読み）。
    pub def trace(program: Yarn.Program, node: String, picks: List[Int32]): List[Event] =
        let (runner, events) = start(program, node, Clock.zero());
        traceFrom(fuel(), runner, picks, events)

    def traceFrom(budget: Int32, runner: Runner[c], picks: List[Int32], acc: List[Event]): List[Event] =
        let Machine.Machine(m) = runner;
        let next = (action, now, rest) -> {
            let (after, events) = step(action, now, runner);
            traceFrom(budget - 1, after, rest, List.append(acc, events))
        };
        if (budget <= 0) acc
        else match (m#shown, picks, m#waitUntil) {
            case (Shown.Line(_), _, _)                 => next(Action.Advance, Clock.zero(), picks)
            case (Shown.Choices(_), pick :: rest, _)   => next(Action.Choose(pick), Clock.zero(), rest)
            case (Shown.Waiting, _, Some(until))       => next(Action.Tick, until, picks)
            case _                                     => acc
        }

    // ── 読む ──

    pub def shownOf(runner: Runner[c]): Shown = let Machine.Machine(m) = runner; m#shown

    /// 開いているノードの名前（閉じていれば None）。
    pub def nodeOf(runner: Runner[c]): Option[String] =
        let Machine.Machine(m) = runner;
        match m#shown {
            case Shown.Closed => None
            case _            => Some(m#node)
        }

    pub def isOpen(runner: Runner[c]): Bool = Option.nonEmpty(nodeOf(runner))

    /// 今の台詞を送ると、次に出るのが選択肢か（選択肢の問いを台詞と同じウィンドウに並べるゲームが、送る前に選択肢を出すため）。
    pub def choicesFollow(runner: Runner[c]): Bool =
        let Machine.Machine(m) = runner;
        match (m#shown, nextOf(m#stack)) {
            case (Shown.Line(_), Some(Yarn.Statement.Choose(_))) => true
            case _                                                => false
        }

    /// <<wait>> が明ける時刻（待っていなければ None）。
    pub def waitUntilOf(runner: Runner[c]): Option[Clock.Time[c]] = let Machine.Machine(m) = runner; m#waitUntil

    // ── 流す ──

    /// 待つ所か終わりまで文を流し、起きた出来事を古い順に返す。
    def flow(budget: Int32, now: Clock.Time[c], runner: Runner[c], acc: List[Event]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = runner;
        if (budget <= 0) finish(runner, acc)
        else match m#stack {
            case Nil              => finish(runner, acc)
            case Nil :: rest      => flow(budget - 1, now, withStack(rest, runner), acc)
            case (statement :: more) :: rest =>
                let next = withStack(more :: rest, runner);
                match statement {
                    case Yarn.Statement.Say(line) =>
                        (show(Shown.Line(line), next), List.reverse(Event.Line(line) :: acc))
                    case Yarn.Statement.Choose(choices) =>
                        let lines = choices |> List.map(choice -> choice#line);
                        let Machine.Machine(n) = show(Shown.Choices(lines), next);
                        (Machine.Machine({ pending = choices | n }), List.reverse(Event.Choices(lines) :: acc))
                    case Yarn.Statement.Jump(target, _) => match Yarn.nodeOf(target, m#program) {
                        case Some(found) =>
                            let Machine.Machine(n) = withStack(found#body :: Nil, runner);
                            flow(budget - 1, now, Machine.Machine({ node = target | n }), acc)
                        case None => finish(next, acc)
                    }
                    case Yarn.Statement.Stop(_) => finish(next, acc)
                    case Yarn.Statement.Command(command) => match waitSecondsOf(command) {
                        case Some(seconds) =>
                            let Machine.Machine(n) = show(Shown.Waiting, next);
                            (Machine.Machine({ waitUntil = Some(Clock.after(seconds, now)) | n }), List.reverse(Event.Command(command) :: acc))
                        case None => flow(budget - 1, now, next, Event.Command(command) :: acc)
                    }
                }
        }

    /// <<wait 秒>> の秒（wait でなければ None。秒の形は build の check が止めているので、読めなければ 0 秒）。
    def waitSecondsOf(command: Yarn.Command): Option[Float64] =
        if (command#name != "wait") None
        else Some(command#args |> List.head |> Option.flatMap(Float64.fromString) |> Option.getWithDefault(0.0) |> Float64.max(0.0))

    /// 次に流れる文（空になった並びは飛ばす）。
    def nextOf(stack: List[List[Yarn.Statement]]): Option[Yarn.Statement] = match stack {
        case Nil                    => None
        case Nil :: rest            => nextOf(rest)
        case (statement :: _) :: _  => Some(statement)
    }

    def finish(runner: Runner[c], acc: List[Event]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = runner;
        (Machine.Machine({ node = "", stack = Nil, shown = Shown.Closed, pending = Nil, waitUntil = None | m }),
         List.reverse(Event.Done :: acc))

    def withStack(stack: List[List[Yarn.Statement]], runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner; Machine.Machine({ stack = stack | m })

    def show(shown: Shown, runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner; Machine.Machine({ shown = shown | m })
}
