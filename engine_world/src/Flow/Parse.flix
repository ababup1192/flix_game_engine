// Flow.Parse — 1 行 1 手の flow の読み手。全部の行を読み、読めない行を行番号つきで全部返す
// （知らない名前には近い名前の案を付ける）。手順のファイル・起動中のゲームへ送る本文（POST /step・/flow）・
// 遊んだ記録が同じ文法。bin/fge flow check（Go の go/internal/flow）も同じ決まりで読む —— 片方だけ直さない。
//
// 名前の確かめ方は語彙（Flow.Vocab）で決まる: 役・問い（と型）・操作・始まり・設定・キー・ready の宣言の有無。
pub mod Flow.Parse {
    use GameEngine.Key
    use Flow.{Cmp, Expr, File, Line, Opt, Script, Span, Step, Target, Vocab}

    /// 読めない行（file の number 行目。行番号は 1 から。0 = ファイルそのもの）。
    pub type alias Problem = { file = String, number = Int32, text = String, why = String }

    /// 本文だけを読む（run は使えない —— 起動中のゲームへ送った本文に、読みに行くフォルダは無い）。
    pub def parseText(vocab: Vocab, name: String, text: String): Result[List[Problem], Script] =
        finish(linesInto(vocab, name, text, _ -> Err("本文の flow では run を使えない（POST /flow?path= で送る）"), 0, emptyAcc()))

    /// ファイルを読む。run の先は read で同じフォルダから引く（8 段まで）。
    pub def parseFile(vocab: Vocab, path: String, read: String -> Result[String, String] \ ef): Result[List[Problem], Script] \ ef =
        match read(path) {
            case Err(why) => Err({ file = path, number = 0, text = "", why = why } :: Nil)
            case Ok(text) => finish(linesInto(vocab, path, text, read, 0, emptyAcc()))
        }

    /// 知らせの形: 「ファイル:行: 理由」と、次の行に書いてあった手。
    pub def problemsText(problems: List[Problem]): String =
        problems |> List.map(p -> "${p#file}:${Int32.toString(p#number)}: ${p#why}" + (if (p#text == "") "" else "\n    ${p#text}"))
                 |> String.intercalate("\n")

    type alias Acc = { fps = Float64, ready = Option[Bool], options = Map[String, String],
                       lines = List[Line], problems = List[Problem] }

    def emptyAcc(): Acc = { fps = 60.0, ready = None, options = Map.empty(), lines = Nil, problems = Nil }

    def finish(done: Acc): Result[List[Problem], Script] =
        if (not List.isEmpty(done#problems)) Err(List.reverse(done#problems))
        else if (List.isEmpty(done#lines)) Err({ file = "", number = 0, text = "", why = "手が 1 つも無い" } :: Nil)
        else Ok({ fps = done#fps, ready = done#ready, options = done#options, lines = List.reverse(done#lines) })

    def linesInto(vocab: Vocab, file: String, text: String, read: String -> Result[String, String] \ ef,
                  depth: Int32, acc0: Acc): Acc \ ef =
        String.lines(text) |> List.zipWithIndex |> List.foldLeft((acc, entry) -> {
            let (index, raw) = entry;
            let body = String.trim(stripComment(raw));
            let problem = why -> { problems = { file = file, number = index + 1, text = body, why = why } :: acc#problems | acc };
            if (String.isEmpty(body)) acc
            else match String.words(body) {
                case "run" :: name :: Nil =>
                    let path = siblingOf(file, name);
                    if (depth >= 8) problem("run が 8 段より深い（自分を呼んでいないか）")
                    else match read(path) {
                        case Err(why)  => problem("run の先 ${path} を読めない: ${why}")
                        case Ok(inner) => linesInto(vocab, path, inner, read, depth + 1, acc)
                    }
                case "run" :: _ => problem("run は 'run <名前>.flow'")
                case _ => match lineInto(vocab, depth, body) {
                    case Ok(Some(step)) => { lines = { file = file, number = index + 1, text = body, step = step } :: acc#lines | acc }
                    case Ok(None)       => settingInto(body, acc) |> Result.getWithDefault(acc)
                    case Err(why)       => problem(why)
                }
            }
        }, acc0)

    def siblingOf(file: String, name: String): String =
        match String.indexOfRight({substr = "/"}, file) {
            case Some(i) => "${String.takeLeft(i, file)}/${name}"
            case None    => name
        }

    def stripComment(line: String): String =
        match String.indexOfLeft({substr = "#"}, line) {
            case Some(i) => String.takeLeft(i, line)
            case None    => line
        }

    /// 設定の行（fps・ready・ゲームの設定）を Acc に当てる。lineInto が Ok(None) を返した行だけ来る。
    def settingInto(body: String, acc: Acc): Result[String, Acc] =
        match String.words(body) {
            case "fps" :: value :: Nil => number(value) |> Result.map(fps -> { fps = fps | acc })
            case "ready" :: "on" :: Nil  => Ok({ ready = Some(true) | acc })
            case "ready" :: "off" :: Nil => Ok({ ready = Some(false) | acc })
            case name :: value :: Nil => Ok({ options = Map.insert(name, value, acc#options) | acc })
            case _ => Err("設定の書き方が違う")
        }

    /// 1 行を読む: 手なら Some(手)・設定なら None（settingInto が当てる）・読めなければ理由。
    def lineInto(vocab: Vocab, depth: Int32, body: String): Result[String, Option[Step]] =
        match String.words(body) {
            case "fps" :: value :: Nil => number(value) |> Result.map(_ -> None)
            case "fps" :: _ => Err("fps は 'fps <数>'")
            case "ready" :: value :: Nil => match value {
                case "on"  => if (vocab#ready) Ok(None) else Err("ready on はゲームが ready を宣言していない（App.withFlow の ready）")
                case "off" => Ok(None)
                case other => Err("ready は on か off（'${other}'）")
            }
            case "start" :: name :: args =>
                if (depth > 0) Err("run の先では start を書かない（始まりは呼ぶ側で）")
                else forM (
                    known <- nameIn("始まり", name, vocab#starts |> List.map(match (n, _, _) -> n));
                    parsed <- argsAndFiles(args)
                ) yield { let (values, files) = parsed; Some(Step.Start(known, values, files)) }
            case "tap" :: target :: opts     => forM (t <- targetOf(vocab, target); o <- optsOf(opts)) yield Some(Step.Tap(t, o))
            case "release" :: target :: opts => forM (t <- targetOf(vocab, target); o <- optsOf(opts)) yield Some(Step.Release(t, o))
            case "hold" :: target :: rest =>
                let (span, opts) = match rest {
                    case first :: more if isSpanWord(first) => (Some(first), more)
                    case more                               => (None, more)
                };
                forM (
                    t <- targetOf(vocab, target);
                    s <- match span { case Some(word) => spanOf(word) |> Result.map(Some) case None => Ok(None) };
                    o <- optsOf(opts)
                ) yield Some(Step.Hold(t, s, o))
            case "wait" :: span :: opts => forM (s <- spanOf(span); o <- optsOf(opts)) yield Some(Step.Wait(s, o))
            case "until" :: expr :: "max" :: secs :: Nil =>
                forM (e <- exprOf(vocab, expr); m <- number(secs)) yield Some(Step.Until(e, m))
            case "until" :: _ => Err("until は 'until <問い> max <秒>'（max は必須）")
            case "drive" :: name :: "until" :: expr :: "max" :: secs :: Nil =>
                forM (
                    known <- nameIn("操作", name, vocab#drives |> List.map(fst));
                    e <- exprOf(vocab, expr);
                    m <- number(secs)
                ) yield Some(Step.Drive(known, e, m))
            case "drive" :: _ => Err("drive は 'drive <操作> until <問い> max <秒>'（max は必須）")
            case "expect" :: expr :: Nil => exprOf(vocab, expr) |> Result.map(e -> Some(Step.Expect(e)))
            case "expect" :: _ => Err("expect は 'expect <問い>'")
            case "mark" :: name :: Nil => Ok(Some(Step.Mark(name)))
            case "mark" :: _ => Err("mark は 'mark <名前>'")
            case "reload" :: target :: rest => filesOf(rest) |> Result.map(files -> Some(Step.Reload(target, files)))
            case "request" :: path :: rest =>
                argsAndFiles(rest) |> Result.flatMap(parsed -> {
                    let (values, files) = parsed;
                    queryOf(Map.getWithDefault("q", "", values)) |> Result.map(params -> Some(Step.Request(path, params, files)))
                })
            case "close" :: Nil => Ok(Some(Step.Close))
            case "rewind" :: count :: Nil => match Int32.fromString(count) {
                case Some(n) if n >= 0 => Ok(Some(Step.Rewind(n)))
                case _ => Err("rewind は 'rewind <フレーム数>'")
            }
            case "idle" :: count :: Nil => Err("idle は無い。'wait ${count}f' と書く（N フレーム何も触らない）")
            case "press" :: key :: Nil  => Err("press は無い。'tap ${key}' と書く")
            case verb :: value :: Nil if List.memberOf(verb, vocab#options |> List.map(fst)) =>
                let allowed = vocab#options |> List.find(entry -> fst(entry) == verb) |> Option.map(snd) |> Option.getWithDefault(Nil);
                if (List.isEmpty(allowed) or List.memberOf(value, allowed)) Ok(None)
                else Err("設定 ${verb} の値 '${value}' は無い${Suggest.hint(value, allowed)}")
            case verb :: _ =>
                let known = List.append(Flow.verbs(), List.append(Flow.settings(), vocab#options |> List.map(fst)));
                if (List.memberOf(verb, known)) Err("'${verb}' の書き方が違う")
                else Err("手 '${verb}' は無い${Suggest.hint(verb, known)}")
            case Nil => Err("空の手")
        }

    def nameIn(kind: String, name: String, known: List[String]): Result[String, String] =
        if (List.memberOf(name, known)) Ok(name) else Err("${kind} '${name}' は無い${Suggest.hint(name, known)}")

    def number(text: String): Result[String, Float64] =
        Float64.fromString(text) |> Option.toOk("'${text}' は数でない")

    def isSpanWord(word: String): Bool =
        not String.contains(substr = "=", word) and Option.nonEmpty(spanOf(word) |> Result.toOption)

    /// 長さ: 0.5（秒）か 30f（フレーム数）。
    def spanOf(text: String): Result[String, Span] =
        if (String.endsWith(suffix = "f", text))
            Int32.fromString(String.dropRight(1, text)) |> Option.map(Span.Frames)
                |> Option.toOk("'${text}' はフレーム数でない（30f のように）")
        else number(text) |> Result.map(Span.Secs) |> Result.mapErr(_ -> "長さ '${text}' は秒（0.5）かフレーム数（30f）")

    /// 押す物: 役の名前・キー（Z,Enter）・点（120,80 = クリック）。
    def targetOf(vocab: Vocab, text: String): Result[String, Target] =
        if (List.memberOf(text, vocab#roles)) Ok(Target.Role(text))
        else match String.splitOn({substr = ","}, text) {
            case x :: y :: Nil if Option.nonEmpty(Float64.fromString(x)) =>
                forM (a <- number(x); b <- number(y)) yield Target.Point(a, b)
            case _ => keySet(text) |> Result.map(Target.Keys)
                |> Result.mapErr(_ -> "役かキー '${text}' は無い${Suggest.hint(text, List.append(vocab#roles, vocab#keys))}")
        }

    /// キーの名前の列（Z,Enter）。'-' は何も押さない。
    def keySet(text: String): Result[String, Set[Key]] =
        if (text == "-") Ok(Set.empty())
        else String.splitOn({substr = ","}, text) |> List.foldLeft((acc, name) -> forM (
            keys <- acc;
            key <- InputMap.keyOf(name) |> Option.toOk("キー '${name}' は無い")
        ) yield Set.insert(key, keys), Ok(Set.empty()))

    /// 付け足し: ns=… dt=秒 at=x,y mouse wheel=量 pad keys=Z,X|- new=Z|- click noclick moved still
    def optsOf(words: List[String]): Result[String, Opt] =
        words |> List.foldLeft((acc, word) -> acc |> Result.flatMap(opt -> {
            let valueOf = prefix -> String.dropLeft(String.length(prefix), word);
            if (word == "mouse") Ok({ mouse = true | opt })
            else if (word == "pad") Ok({ pad = true | opt })
            else if (word == "click") Ok({ click = Some(true) | opt })
            else if (word == "noclick") Ok({ click = Some(false) | opt })
            else if (word == "moved") Ok({ moved = Some(true) | opt })
            else if (word == "still") Ok({ moved = Some(false) | opt })
            else if (String.startsWith(prefix = "ns=", word))
                valueOf("ns=") |> String.splitOn({substr = ","}) |> List.foldRight((part, rest) -> forM (
                    n <- Int64.fromString(part) |> Option.toOk("ns= はナノ秒の整数の列（'${part}'）");
                    tail <- rest
                ) yield n :: tail, Ok(Nil)) |> Result.map(ns -> { ns = ns | opt })
            else if (String.startsWith(prefix = "dt=", word)) number(valueOf("dt=")) |> Result.map(v -> { dt = Some(v) | opt })
            else if (String.startsWith(prefix = "wheel=", word)) number(valueOf("wheel=")) |> Result.map(v -> { wheel = v | opt })
            else if (String.startsWith(prefix = "keys=", word)) keySet(valueOf("keys=")) |> Result.map(v -> { keys = Some(v) | opt })
            else if (String.startsWith(prefix = "new=", word)) keySet(valueOf("new=")) |> Result.map(v -> { pressed = Some(v) | opt })
            else if (String.startsWith(prefix = "at=", word)) match String.splitOn({substr = ","}, valueOf("at=")) {
                case x :: y :: Nil => forM (a <- number(x); b <- number(y)) yield { at = Some({ x = a, y = b }) | opt }
                case _             => Err("at は at=x,y")
            }
            else Err("付け足し '${word}' は無い${Suggest.hint(word, "ns=" :: "dt=" :: "at=" :: "mouse" :: "wheel=" :: "pad" :: "keys=" :: "new=" :: "click" :: "moved" :: Nil)}")
        }), Ok(Flow.noOpt()))

    /// 問いの式: 名前（真偽）・!式・式&式・名前<数（< <= = >= > !=）・名前=文字。
    def exprOf(vocab: Vocab, text: String): Result[String, Expr] =
        match String.indexOfLeft({substr = "&"}, text) {
            case Some(i) => forM (a <- exprOf(vocab, String.takeLeft(i, text)); b <- exprOf(vocab, String.dropLeft(i + 1, text)))
                            yield Expr.Both(a, b)
            case None =>
                if (String.startsWith(prefix = "!", text)) exprOf(vocab, String.dropLeft(1, text)) |> Result.map(Expr.Not)
                else match Flow.splitCompare(text) {
                    case Some((name, cmp, value)) => kindOf(vocab, name) |> Result.flatMap(kind -> match kind {
                        case Flow.Kind.Num => number(value) |> Result.map(_ -> Expr.Compare(name, cmp, value))
                            |> Result.mapErr(_ -> "数の問い ${name} と比べる値 '${value}' が数でない")
                        case Flow.Kind.Text => match cmp {
                            case Cmp.Same   => Ok(Expr.Compare(name, cmp, value))
                            case Cmp.Differ => Ok(Expr.Compare(name, cmp, value))
                            case _          => Err("文字の問い ${name} は = か != で比べる")
                        }
                        case Flow.Kind.Flag => Err("真偽の問い ${name} は比べずに書く（${name} か !${name}）")
                    })
                    case None => kindOf(vocab, text) |> Result.flatMap(kind -> match kind {
                        case Flow.Kind.Flag => Ok(Expr.Name(text))
                        case _              => Err("問い ${text} は真偽でない。比べて書く（${text}=… / ${text}>=…）")
                    })
                }
        }

    /// 問いの名前の型（指紋 fp は文字。withFingerprint を繋いだゲームだけ）。
    def kindOf(vocab: Vocab, name: String): Result[String, Flow.Kind] =
        if (name == Flow.fingerprintProbe() and vocab#fingerprint) Ok(Flow.Kind.Text)
        else match vocab#probes |> List.find(match (n, _, _) -> n == name) {
            case Some((_, kind, _)) => Ok(kind)
            case None =>
                let known = vocab#probes |> List.map(match (n, _, _) -> n);
                Err("問い '${name}' は無い${Suggest.hint(name, if (vocab#fingerprint) List.append(known, Flow.fingerprintProbe() :: Nil) else known)}")
        }

    /// key=value の引数と +パス=中身 のファイル。値の b64: は中身に戻す（記録が書く）。
    def argsAndFiles(words: List[String]): Result[String, (Map[String, String], Map[String, File])] =
        words |> List.foldLeft((acc, word) -> acc |> Result.flatMap(parsed -> {
            let (values, files) = parsed;
            if (String.startsWith(prefix = "+", word)) fileOf(String.dropLeft(1, word)) |> Result.map(file -> {
                let (path, content) = file; (values, Map.insert(path, content, files))
            })
            else match String.indexOfLeft({substr = "="}, word) {
                case Some(i) if i > 0 => decoded(String.dropLeft(i + 1, word)) |> Result.map(value ->
                                             (Map.insert(String.takeLeft(i, word), value, values), files))
                case _ => Err("引数 '${word}' は key=value で書く")
            }
        }), Ok((Map.empty(), Map.empty())))

    def filesOf(words: List[String]): Result[String, Map[String, File]] =
        argsAndFiles(words) |> Result.flatMap(parsed -> {
            let (values, files) = parsed;
            if (Map.isEmpty(values)) Ok(files) else Err("reload の後ろはファイル（+パス=b64:…）だけ")
        })

    /// パス=b64:中身 か パス=missing。
    def fileOf(text: String): Result[String, (String, File)] =
        match String.indexOfLeft({substr = "="}, text) {
            case Some(i) if i > 0 =>
                let path = String.takeLeft(i, text);
                let value = String.dropLeft(i + 1, text);
                if (value == "missing") Ok((path, File.Missing))
                else decoded(value) |> Result.map(content -> (path, File.Text(content)))
            case _ => Err("ファイルは +パス=b64:中身 か +パス=missing")
        }

    /// b64: で始まる値は Base64 を戻した中身（UTF-8）。それ以外はそのまま。
    pub def decoded(value: String): Result[String, String] =
        if (String.startsWith(prefix = "b64:", value))
            Flow.base64Decode(String.dropLeft(4, value)) |> Option.toOk("b64: の中身を戻せない")
        else Ok(value)

    /// q= のクエリ（a=1&b=2）を Map にする。
    def queryOf(text: String): Result[String, Map[String, String]] =
        if (text == "") Ok(Map.empty())
        else String.splitOn({substr = "&"}, text) |> List.foldLeft((acc, pair) -> acc |> Result.flatMap(m ->
            match String.indexOfLeft({substr = "="}, pair) {
                case Some(i) => Ok(Map.insert(String.takeLeft(i, pair), String.dropLeft(i + 1, pair), m))
                case None    => Ok(Map.insert(pair, "", m))
            }), Ok(Map.empty()))
}
