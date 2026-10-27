// YarnRunner — 会話のシナリオ（Yarn.Program）の木を直に辿って、台詞・選択肢・コマンドを順に出す実行器（純粋）。
//
//   let (runner, events) = YarnRunner.start(program, "op_desk", now)      ノードの頭から、最初に待つ所まで流す
//   let (runner, events) = YarnRunner.step(Action.Advance, now, runner)   台詞を送る
//   let (runner, events) = YarnRunner.step(Action.Choose(1), now, runner) 選択肢を選ぶ（0 始まり）
//   let (runner, events) = YarnRunner.step(Action.Tick, now, runner)      毎フレーム。<<wait 秒>> の時刻が来たら続きを流す
//   let (runner, events) = YarnRunner.startAt(program, "op_desk", 40, now) ノードの頭から .yarn の 40 行目を出している所まで（プレビュー・goto）
//   let (runner, events) = YarnRunner.startWith(YarnRunner.storageOf(old), program, "station2", now)  変数と訪れた数を持ち越して始める
//   YarnRunner.valueOf("$tickets", runner)                                 変数を読む（書くのは withStorage と YarnStorage.set）
//
// 出来事（Event）は Line・Choices・Command・Done の 4 つで、返した列はその呼び出しの間に起きた物だけ。
// 今出している物の正は shownOf の 1 つ（出来事の列は World に溜めない。文字送りは UiDialog の仕事）。
// 音を鳴らしたい出来事は、受けた所でゲームが自分の Emit に写す（ここで Emit を使うと、ゲームの Emit と型がぶつかる E6795）。
// <<wait>> の時刻は型で分けた時計の時刻で持つ（止めている間は時計ごと止まるので、待ちも止まる）。
// 変数の正は実行器の YarnStorage の 1 つ。ゲームが World にも同じ値を持つなら、どちらを正にするか決めて片方から写す。
// ノードを出た回数（visited）は、jump・<<stop>>・ノードの終わりでそのノードを出た時に数える（公式と同じ。途中で閉じた会話は数えない）。
pub mod YarnRunner {

    /// 呼び出しの間に起きた出来事。
    ///   Line     … 台詞を出した（Advance を待つ）
    ///   Choices  … 選択肢を出した（Choose を待つ。並びはシナリオの順。条件が偽の物も available = false で並ぶ）
    ///   Command  … コマンドを通った（wait なら Tick で時刻が来るまで待つ・それ以外は待たずに続ける）
    ///   Done     … 会話が終わった（<<stop>>・ノードの終わり・行き先の無い jump）
    pub enum Event {
        case Line(Yarn.Line)
        case Choices(List[DialogueOption])
        case Command(Yarn.Command)
        case Done
    }

    /// 出した選択肢 1 つ（公式の DialogueOption）。available = 行末の <<if>> が真か。偽の物も並びに残し、
    /// 灰色で見せるか隠すかはゲームが決める（Choose の番号はこの並びで数え、選べない物を選んでも何も変わらない）。
    /// まとまりの全部が偽なら、選択肢は出さずに後ろへ進む。
    pub type alias DialogueOption = { line = Yarn.Line, available = Bool }

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
        case Choices(List[DialogueOption])
        case Waiting
    }

    /// node = 開いているノード（閉じていれば空）、stack = これから流す文の並び（選択肢と <<if>> の中身を流す間は、
    /// その後ろの文がその下に残る）、pending = 出している選択肢、waitUntil = <<wait>> が明ける時刻、storage = 変数と訪れた数。
    enum Machine[c]({
        program = Yarn.Program,
        node = String,
        stack = List[List[Yarn.Statement]],
        shown = Shown,
        pending = List[Yarn.Choice],
        waitUntil = Option[Clock.Time[c]],
        storage = YarnStorage.Storage,
        entry = Bookmark
    })

    /// 読んでいる所のブックマーク（セーブに入れる物）。node = 開いているノード、storage = そのノードに入った時の変数と訪れた数、
    /// steps = 入ってから受けた入力（Advance と Choose だけ。<<wait>> は待たずに越える）。resume が node の頭から
    /// steps を当て直して同じ所へ戻す（行の番号で探さないので、選んだ枝の中の <<set>> も同じに通る）。
    /// .yarn をセーブの後に書き直すと、当て直した先は書き直した木の上の同じ入力の先になる。
    pub type alias Bookmark = { node = String, storage = YarnStorage.Storage, steps = List[Action] }

    /// 実行器。c は <<wait>> を測る時計の名前（ゲームの物語の時計など）。外では start と closed だけが作る。
    pub type alias Runner[c] = Machine[c]

    /// 1 回の呼び出しで流す文の上限。台詞の無いノードどうしが jump し合うシナリオでも必ず止まる。
    def fuel(): Int32 = 10000

    /// 開いていない実行器（World の初期値）。
    pub def closed(): Runner[c] =
        Machine.Machine({ program = Yarn.empty(), node = "", stack = Nil, shown = Shown.Closed, pending = Nil, waitUntil = None,
                          storage = YarnStorage.empty(), entry = { node = "", storage = YarnStorage.empty(), steps = Nil } })

    /// node の頭から、最初に待つ所（台詞・選択肢・wait）か終わりまで流す。node が無ければすぐ Done。
    /// 変数は全部 <<declare>> の初めの値から始まる（前の会話の値を持ち越すなら startWith）。
    pub def start(program: Yarn.Program, node: String, now: Clock.Time[c]): (Runner[c], List[Event]) =
        startWith(YarnStorage.empty(), program, node, now)

    /// start と同じだが、変数と訪れた数を storage から始める（前の会話の storageOf・セーブから読んだ物）。
    pub def startWith(storage: YarnStorage.Storage, program: Yarn.Program, node: String, now: Clock.Time[c]): (Runner[c], List[Event]) =
        let begin = opened -> Machine.Machine({ program = program, node = opened, stack = Nil, shown = Shown.Closed, pending = Nil,
                                                waitUntil = None, storage = storage, entry = { node = opened, storage = storage, steps = Nil } });
        match Yarn.nodeOf(node, program) {
            case Some(found) => flow(fuel(), now, withStack(found#body :: Nil, begin(node)), Nil)
            case None        => finish(begin(""), Nil)
        }

    /// 入力 1 つ。今の状態で意味の無い入力（台詞の無い時の Advance・範囲の外の Choose・時刻の前の Tick）は何も変えない。
    pub def step(action: Action, now: Clock.Time[c], runner: Runner[c]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = runner;
        match (action, m#shown) {
            case (Action.Advance, Shown.Line(_))     => flow(fuel(), now, record(action, runner), Nil)
            case (Action.Choose(i), Shown.Choices(options)) => match List.nth(i, m#pending) {
                case Some(choice) if isAvailable(i, options) =>
                    let Machine.Machine(r) = record(action, runner);
                    let resumed = Machine.Machine({ pending = Nil, stack = choice#body :: r#stack | r });
                    flow(fuel(), now, resumed, Nil)
                case _ => (runner, Nil)
            }
            case (Action.Tick, Shown.Waiting) => match m#waitUntil {
                case Some(until) if now >= until => flow(fuel(), now, Machine.Machine({ waitUntil = None | m }), Nil)
                case _                           => (runner, Nil)
            }
            case _ => (runner, Nil)
        }

    /// node の頭から、台詞はすぐ送り・選択肢は picks の順に選び（0 始まり）・<<wait>> は明ける時刻まで飛ばして、
    /// 終わるか picks が尽きた選択肢までの出来事を返す（画面なしのテスト・シナリオの通し読み）。
    /// 選べない選択肢の番号はその pick を使い切るだけで、同じ選択肢に次の pick を当てる。
    pub def trace(program: Yarn.Program, node: String, picks: List[Int32]): List[Event] =
        let (runner, events) = start(program, node, Clock.zero());
        traceFrom(fuel(), runner, picks, events)

    /// node の頭から流し、シナリオの line 行（.yarn の 1 始まりの行番号）を出している所まで進める
    /// （Studio の会話のプレビュー・bin/fge talk goto・始まり `talk node=… line=…` が使う）。
    /// 台詞は送り、選択肢はその行を中に持つ物を選び（どれも持たず、行が選択肢より後なら先頭を選んで抜ける）、
    /// <<wait>> は明ける時刻まで飛ばす。止まるのは、出した台詞の行が line 以上になった所・line の選択肢を出した所
    /// （その直前に台詞があれば、問いとして並べられるよう台詞の所で止まる。choicesFollow が真）・会話が終わった所。
    /// line が node の頭より前なら start と同じ。
    /// 変数は全部初めの値から流す（<<if>> の偽の枝の中の行へは届かず、その後ろで止まる。値を渡すなら startAtWith）。
    pub def startAt(program: Yarn.Program, node: String, line: Int32, now: Clock.Time[c]): (Runner[c], List[Event]) =
        startAtWith(YarnStorage.empty(), program, node, line, now)

    /// startAt と同じだが、変数と訪れた数を storage から始める（プレビューで $切符=0 の場面を出す。YarnStorage.withArgs）。
    pub def startAtWith(storage: YarnStorage.Storage, program: Yarn.Program, node: String, line: Int32, now: Clock.Time[c]): (Runner[c], List[Event]) =
        let (runner, events) = startWith(storage, program, node, now);
        seek(fuel(), line, now, runner, events)

    def seek(budget: Int32, target: Int32, now: Clock.Time[c], runner: Runner[c], acc: List[Event]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = runner;
        let next = (action, at) -> {
            let (after, events) = step(action, at, runner);
            seek(budget - 1, target, now, after, List.append(acc, events))
        };
        if (budget <= 0) (runner, acc)
        else match m#shown {
            // 次が target の行を持つ選択肢なら、問いの台詞で止める（choicesFollow で問いと選択肢を並べるゲームの形のまま）。
            case Shown.Line(line) if line#source#line < target =>
                if (upcomingChoices(runner) |> List.exists(choice -> choice#source#line == target)) (runner, acc) else next(Action.Advance, now)
            case Shown.Choices(options) =>
                if (List.exists(option -> option#line#source#line == target, options)) (runner, acc)
                else match choiceToward(target, List.zip(m#pending, options |> List.map(option -> option#available))) {
                    case Some(i) => next(Action.Choose(i), now)
                    case None    => (runner, acc)
                }
            case Shown.Waiting => match m#waitUntil {
                case Some(until) => next(Action.Tick, until)
                case None        => (runner, acc)
            }
            case _ => (runner, acc)
        }

    /// 行 target へ向かうには何番目の選択肢を選ぶか（選べる物だけから）。中に target を持つ選択肢・
    /// 無ければ target が全部の選択肢より後なら最初の選べる物・前なら None（もう通り過ぎている）。
    def choiceToward(target: Int32, choices: List[(Yarn.Choice, Bool)]): Option[Int32] =
        let open = choices |> List.zipWithIndex |> List.filter(match (_, (_, available)) -> available);
        let inside = open |> List.find(match (_, (choice, _)) ->
            choice#line#source#line == target or List.exists(statement -> List.memberOf(target, linesOf(statement)), choice#body));
        match inside {
            case Some((i, _)) => Some(i)
            case None =>
                let lastLine = choices |> List.flatMap(match (choice, _) -> choice#line#source#line :: List.flatMap(linesOf, choice#body))
                                       |> List.maximum |> Option.getWithDefault(0);
                if (target > lastLine) open |> List.head |> Option.map(fst) else None
        }

    /// 並びの i 番目が選べる選択肢か。
    def isAvailable(i: Int32, options: List[DialogueOption]): Bool =
        List.nth(i, options) |> Option.exists(option -> option#available)

    /// 今の台詞を送った時、台詞もコマンドも挟まずに選択肢が出るなら、その選択肢（でなければ空）。
    /// <<if>> と <<set>> と条件の偽の選択肢を越えて決まるので、送った先を流して確かめる（流した結果は捨てる）。
    def upcomingChoices(runner: Runner[c]): List[Yarn.Line] =
        let Machine.Machine(m) = runner;
        match m#shown {
            case Shown.Line(_) => match flow(fuel(), Clock.zero(), runner, Nil) {
                case (_, Event.Choices(options) :: Nil) => options |> List.map(option -> option#line)
                case _                                => Nil
            }
            case _ => Nil
        }

    /// 文が持つ行（選択肢と <<if>> は中身も）。
    def linesOf(statement: Yarn.Statement): List[Int32] = match statement {
        case Yarn.Statement.Say(line)        => line#source#line :: Nil
        case Yarn.Statement.Choose(choices)  => choices |> List.flatMap(choice -> choice#line#source#line :: List.flatMap(linesOf, choice#body))
        case Yarn.Statement.Jump(_, source)  => source#line :: Nil
        case Yarn.Statement.Stop(source)     => source#line :: Nil
        case Yarn.Statement.Command(command) => command#source#line :: Nil
        case Yarn.Statement.Set(_, _, source) => source#line :: Nil
        case Yarn.Statement.If(branches, source) => source#line :: List.flatMap(branch -> List.flatMap(linesOf, branch#body), branches)
    }

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
    /// 間の <<if>>・<<set>> は越えて見る。条件が全部偽で飛ばされる選択肢は数えない。
    pub def choicesFollow(runner: Runner[c]): Bool = not List.isEmpty(upcomingChoices(runner))

    /// <<wait>> が明ける時刻（待っていなければ None）。
    pub def waitUntilOf(runner: Runner[c]): Option[Clock.Time[c]] = let Machine.Machine(m) = runner; m#waitUntil

    // ── 読んでいる所のブックマーク（セーブ・ロード）──

    /// 読んでいる所のブックマーク（開いていなければ None）。
    pub def bookmarkOf(runner: Runner[c]): Option[Bookmark] =
        let Machine.Machine(m) = runner;
        if (isOpen(runner)) Some(m#entry) else None

    /// ブックマークのノードの頭から steps を当て直し、セーブした時と同じ所（同じ台詞・選択肢）を出す。返す出来事は当て直す間に
    /// 起きた全部で、ゲームはコマンドを畳んで背景や曲を今の形に戻す（演出の途中は飛ばして終わりの形にする）。
    /// <<wait>> は明ける時刻まで飛ばす（待っている間に取ったブックマークも、明けた後の台詞から始まる）。ノードが無ければ start と同じくすぐ Done。
    pub def resume(program: Yarn.Program, bookmark: Bookmark, now: Clock.Time[c]): (Runner[c], List[Event]) =
        let (runner, events) = startWith(bookmark#storage, program, bookmark#node, now);
        replay(fuel(), bookmark#steps, now, runner, events)

    def replay(budget: Int32, steps: List[Action], now: Clock.Time[c], runner: Runner[c], acc: List[Event]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = runner;
        let next = (action, at, rest) -> {
            let (after, events) = step(action, at, runner);
            replay(budget - 1, rest, now, after, List.append(acc, events))
        };
        if (budget <= 0) (runner, acc)
        else match (m#shown, m#waitUntil, steps) {
            case (Shown.Waiting, Some(until), _)       => next(Action.Tick, until, steps)
            case (_, _, Nil)                           => (runner, acc)
            case (_, _, action :: rest)                => next(action, now, rest)
        }

    /// ブックマークを JSON に（セーブ）。steps は Advance を "a"、Choose(i) を i の数で並べる。
    pub def bookmarkToJson(bookmark: Bookmark): Util.Json.Json =
        let step1 = action -> match action {
            case Action.Choose(i) => Util.Json.Json.JNumber(JsonCodec.floatToBd(Int32.toFloat64(i)))
            case _                => Util.Json.Json.JString("a")
        };
        Util.Json.Json.JObject(Map#{
            "node" => Util.Json.Json.JString(bookmark#node),
            "storage" => YarnStorage.toJson(bookmark#storage),
            "steps" => Util.Json.Json.JArray(bookmark#steps |> List.filter(action -> action != Action.Tick) |> List.map(step1) |> List.toVector)
        })

    /// JSON からブックマークへ（ロード）。形が違えば None（違う所から始めるより、ゲームがセーブを読めないと知らせる方がよい）。
    pub def bookmarkFromJson(json: Util.Json.Json): Option[Bookmark] =
        let stepOf = j -> match j {
            case Util.Json.Json.JString("a") => Some(Action.Advance)
            case Util.Json.Json.JNumber(_)   => JsonCodec.expectFloat(j) |> Option.map(f -> Action.Choose(Float64.round(f) |> Float64.tryToInt32 |> Option.getWithDefault(0)))
            case _                           => None
        };
        forM (
            obj <- JsonCodec.expectObject(json);
            node <- Map.get("node", obj) |> Option.flatMap(JsonCodec.expectString);
            storage <- Map.get("storage", obj) |> Option.flatMap(YarnStorage.fromJson);
            steps <- Map.get("steps", obj) |> Option.flatMap(JsonCodec.decodeList(stepOf))
        ) yield { node = node, storage = storage, steps = steps }

    // ── 変数 ──

    /// 変数と訪れた数（セーブや次の会話の startWith へ渡す）。
    pub def storageOf(runner: Runner[c]): YarnStorage.Storage = let Machine.Machine(m) = runner; m#storage

    /// 変数と訪れた数を差し替える（ゲームの World の値をシナリオへ渡す・セーブから戻す）。
    pub def withStorage(storage: YarnStorage.Storage, runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner; Machine.Machine({ storage = storage | m })

    /// 変数の今の値（書いていなければ <<declare>> の初めの値。宣言も値も無ければ None）。
    pub def valueOf(name: String, runner: Runner[c]): Option[Yarn.Value] =
        let Machine.Machine(m) = runner;
        variableOf(m#program, m#storage, name)

    /// 書いてある値が宣言と同じ型ならそれ、でなければ初めの値（ゲームが型の違う値を書いても式の型が崩れない）。
    def variableOf(program: Yarn.Program, storage: YarnStorage.Storage, name: String): Option[Yarn.Value] =
        match (YarnStorage.get(name, storage), Yarn.declarationOf(name, program)) {
            case (Some(value), Some(declared)) => if (sameType(value, declared#value)) Some(value) else Some(declared#value)
            case (Some(value), None)           => Some(value)
            case (None, Some(declared))        => Some(declared#value)
            case (None, None)                  => None
        }

    def sameType(a: Yarn.Value, b: Yarn.Value): Bool = match (a, b) {
        case (Yarn.Value.Number(_), Yarn.Value.Number(_)) => true
        case (Yarn.Value.Bool(_), Yarn.Value.Bool(_))     => true
        case (Yarn.Value.Text(_), Yarn.Value.Text(_))     => true
        case _                                            => false
    }

    /// 式の値。型は build の check が合わせてあるので、合わない組（手で直した木）は偽・0・空の字へ落とす。
    def evaluate(m: { program = Yarn.Program, storage = YarnStorage.Storage | r }, expr: Yarn.Expr): Yarn.Value = match expr {
        case Yarn.Expr.Constant(value) => value
        case Yarn.Expr.Variable(name)  => variableOf(m#program, m#storage, name) |> Option.getWithDefault(Yarn.Value.Number(0.0))
        case Yarn.Expr.Visited(node)   => Yarn.Value.Bool(YarnStorage.visitCountOf(node, m#storage) > 0)
        case Yarn.Expr.VisitCount(node) => Yarn.Value.Number(Int32.toFloat64(YarnStorage.visitCountOf(node, m#storage)))
        case Yarn.Expr.Not(operand)    => Yarn.Value.Bool(not isTrue(evaluate(m, operand)))
        case Yarn.Expr.Negate(operand) => Yarn.Value.Number(0.0 - numberOf(evaluate(m, operand)))
        case Yarn.Expr.And(left, right) => Yarn.Value.Bool(isTrue(evaluate(m, left)) and isTrue(evaluate(m, right)))
        case Yarn.Expr.Or(left, right)  => Yarn.Value.Bool(isTrue(evaluate(m, left)) or isTrue(evaluate(m, right)))
        case Yarn.Expr.Binary(op, left, right) => binary(op, evaluate(m, left), evaluate(m, right))
    }

    def binary(op: Yarn.Operator, left: Yarn.Value, right: Yarn.Value): Yarn.Value =
        let a = numberOf(left);
        let b = numberOf(right);
        match op {
            case Yarn.Operator.Add => match (left, right) {
                case (Yarn.Value.Text(x), Yarn.Value.Text(y)) => Yarn.Value.Text(x + y)
                case _                                        => Yarn.Value.Number(a + b)
            }
            case Yarn.Operator.Subtract     => Yarn.Value.Number(a - b)
            case Yarn.Operator.Multiply     => Yarn.Value.Number(a * b)
            case Yarn.Operator.Divide       => Yarn.Value.Number(a / b)
            // 公式（C# の %）と同じく、割った商を 0 の側へ切り捨てた余り（負の数で floor の余りと違う）。
            case Yarn.Operator.Remainder    =>
                let quotient = a / b;
                Yarn.Value.Number(a - b * (if (quotient >= 0.0) Float64.floor(quotient) else Float64.ceil(quotient)))
            case Yarn.Operator.Equal        => Yarn.Value.Bool(left == right)
            case Yarn.Operator.NotEqual     => Yarn.Value.Bool(left != right)
            case Yarn.Operator.Less         => Yarn.Value.Bool(a < b)
            case Yarn.Operator.LessEqual    => Yarn.Value.Bool(a <= b)
            case Yarn.Operator.Greater      => Yarn.Value.Bool(a > b)
            case Yarn.Operator.GreaterEqual => Yarn.Value.Bool(a >= b)
        }

    def isTrue(value: Yarn.Value): Bool = match value {
        case Yarn.Value.Bool(b) => b
        case _                  => false
    }

    def numberOf(value: Yarn.Value): Float64 = match value {
        case Yarn.Value.Number(n) => n
        case _                    => 0.0
    }

    /// {式} を値の字にして、台詞の字を作る（出来事の Line の parts は字とマークアップだけ。マークアップの無い行は字 1 切れ）。
    def substitute(m: { program = Yarn.Program, storage = YarnStorage.Storage | r }, line: Yarn.Line): Yarn.Line =
        match line#parts {
            case Yarn.Part.Literal(_) :: Nil => line
            case parts =>
                let resolved = parts |> List.map(part -> match part {
                    case Yarn.Part.Insert(expr) => Yarn.Part.Literal(Yarn.toText(evaluate(m, expr)))
                    case other                  => other
                });
                let text = Yarn.plainTextOf(resolved);
                let marked = resolved |> List.exists(part -> match part {
                    case Yarn.Part.Markup(_, _) => true
                    case _                      => false
                });
                { text = text, parts = if (marked) resolved else Yarn.Part.Literal(text) :: Nil | line }
        }

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
                        let shown = substitute(m, line);
                        (show(Shown.Line(shown), next), List.reverse(Event.Line(shown) :: acc))
                    case Yarn.Statement.Choose(choices) =>
                        let options = choices |> List.map(choice ->
                            { line = substitute(m, choice#line),
                              available = Option.forAll(condition -> isTrue(evaluate(m, condition)), choice#condition) });
                        if (not List.exists(option -> option#available, options)) flow(budget - 1, now, next, acc)
                        else {
                            let Machine.Machine(n) = show(Shown.Choices(options), next);
                            (Machine.Machine({ pending = choices | n }), List.reverse(Event.Choices(options) :: acc))
                        }
                    case Yarn.Statement.Jump(target, _) => match Yarn.nodeOf(target, m#program) {
                        case Some(found) =>
                            let Machine.Machine(n) = withStack(found#body :: Nil, leave(runner));
                            flow(budget - 1, now, Machine.Machine({ node = target, entry = { node = target, storage = n#storage, steps = Nil } | n }), acc)
                        case None => finish(next, acc)
                    }
                    case Yarn.Statement.Set(name, expr, _) =>
                        let Machine.Machine(n) = next;
                        flow(budget - 1, now, Machine.Machine({ storage = YarnStorage.set(name, evaluate(m, expr), n#storage) | n }), acc)
                    case Yarn.Statement.If(branches, _) =>
                        let body = branches |> List.find(branch -> isTrue(evaluate(m, branch#condition))) |> Option.map(branch -> branch#body) |> Option.getWithDefault(Nil);
                        flow(budget - 1, now, withStack(body :: more :: rest, runner), acc)
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

    def finish(runner: Runner[c], acc: List[Event]): (Runner[c], List[Event]) =
        let Machine.Machine(m) = leave(runner);
        (Machine.Machine({ node = "", stack = Nil, shown = Shown.Closed, pending = Nil, waitUntil = None | m }),
         List.reverse(Event.Done :: acc))

    /// 開いているノードを出た回数を 1 つ足す（ノードが開いていなければそのまま）。
    def leave(runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner;
        if (m#node == "") runner
        else Machine.Machine({ storage = YarnStorage.addVisit(m#node, m#storage) | m })

    /// 受けた入力をブックマークに足す（steps は新しい物が後ろ。1 つの台詞を読む間に足すのは 1 つなので append でよい）。
    def record(action: Action, runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner;
        Machine.Machine({ entry = { steps = List.append(m#entry#steps, action :: Nil) | m#entry } | m })

    def withStack(stack: List[List[Yarn.Statement]], runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner; Machine.Machine({ stack = stack | m })

    def show(shown: Shown, runner: Runner[c]): Runner[c] =
        let Machine.Machine(m) = runner; Machine.Machine({ shown = shown | m })
}
