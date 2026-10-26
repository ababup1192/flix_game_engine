// Yarn — 会話のシナリオ（Yarn Spinner の .yarn の部分集合）を、bin/fge yarn build が書き出した木の JSON から読む。
// .yarn を読むのは Go の build だけ（読み手を 1 つにする）。ここは木を読み、YarnRunner が木を直に辿る。
//
//   assets/talk/*.yarn ──bin/fge yarn build──▶ assets/talk/dialogue.json ──Yarn.loadOr──▶ Yarn.Program
//   ゲームの enum ──Yarn.vocabJson（ゲームの Talk.vocab・make talk-vocab）──▶ assets/talk/vocab.json ──build の check が読む
//
// シナリオに書く物: 台詞・話し手・タグ（表情・後ろの場面など。値はゲームの enum の名前）・変数と <<if>>（会話の中で数えて分ける物）。
// コードに書く物: どのノードを開くか・演出の順番。文字送りの速さ・ウィンドウの出入り・立ち絵・呼び名は Doc。
// 変数の値は YarnRunner が持つ YarnStorage にあり、ゲームは YarnRunner.valueOf・withStorage で読み書きする。
// 読める文法と断る文法は bin/fge yarn help、木の形は go/internal/yarn/tree.go。
pub mod Yarn {
    use Util.Json.Json

    /// 行がどこにあるか。file = ゲームのルートからの .yarn のパス、line = 1 始まりの行番号。
    pub type alias Source = { file = String, line = Int32 }

    /// #key:value のタグ（値の無い #key は value が空）。
    pub type alias Tag = { key = String, value = String }

    /// 台詞 1 行。speaker = 話し手の id（地の文は空）、text = 出す字（エスケープは解いてある）、
    /// parts = 字と {式} の並び（YarnRunner が式を値にして text へ入れる。出来事の Line では text 1 切れ）。
    pub type alias Line = { speaker = String, text = String, parts = List[Part], tags = List[Tag], source = Source }

    /// 行の 1 切れ。Literal = 書いたとおりの字、Insert = {式}（値を字にして差し込む）、
    /// Markup(名前, 値) = [名前=値] の始まり、Close(名前) = [/名前] の終わり（字の並びの範囲は markupOf で読む）。
    pub enum Part {
        case Literal(String)
        case Insert(Expr)
        case Markup(String, String)
        case Close(String)
    }

    /// マークアップ 1 つ（公式の MarkupAttribute）。start = text の何文字目から（0 始まり・String.length の数え方）、
    /// length = 何文字か、value = [名前=値] の値。ruby なら字の範囲が親字・value がふりがな。
    pub type alias Markup = { name = String, value = String, start = Int32, length = Int32 }

    /// 変数と式の値（公式と同じ 3 つの型。型は build の check が合わせてある）。
    pub enum Value with Eq, ToString {
        case Number(Float64)
        case Bool(Bool)
        case Text(String)
    }

    /// 式。Visited / VisitCount はノードを出た回数を見る（公式の visited("…")・visited_count("…")）。
    pub enum Expr {
        case Constant(Value)
        case Variable(String)
        case Visited(String)
        case VisitCount(String)
        case Not(Expr)
        case Negate(Expr)
        case And(Expr, Expr)
        case Or(Expr, Expr)
        case Binary(Operator, Expr, Expr)
    }

    /// and / or の他の、2 つの値をとる演算（and / or は右を見るのが左で決まらない時だけなので Expr の case に分けてある）。
    pub enum Operator with Eq {
        case Add
        case Subtract
        case Multiply
        case Divide
        case Remainder
        case Equal
        case NotEqual
        case Less
        case LessEqual
        case Greater
        case GreaterEqual
    }

    /// <<名前 引数…>>。エンジンが自分で扱うのは wait（YarnRunner が待つ）だけ。
    pub type alias Command = { name = String, args = List[String], tags = List[Tag], source = Source }

    /// 本文の 1 文。
    ///   Say     … 台詞を出して、送られるまで待つ
    ///   Choose  … 選択肢を出して、選ばれたらその中身を流し、終わると選択肢の後ろへ戻る
    ///   Jump    … 別のノードの頭へ移る
    ///   Stop    … 会話を終える
    ///   Command … コマンド
    ///   Set     … 変数（$ から書く名前）に式の値を入れる
    ///   If      … 上の枝から順に条件を見て、最初に真になった枝の中身を流す（<<else>> は条件が真の定数の枝）
    pub enum Statement {
        case Say(Line)
        case Choose(List[Choice])
        case Jump(String, Source)
        case Stop(Source)
        case Command(Command)
        case Set(String, Expr, Source)
        case If(List[Branch], Source)
    }

    /// 選択肢 1 つ。line = 出す字と話し手・タグ、condition = 行末の <<if>>（偽なら選べない印で並ぶ）、body = 選んだ時に流す中身。
    pub type alias Choice = { line = Line, condition = Option[Expr], body = List[Statement] }

    /// <<if>> の枝 1 つ。
    pub type alias Branch = { condition = Expr, body = List[Statement] }

    /// <<declare>> 1 つ。value = 初めの値（型もこれで決まる）。
    pub type alias Declaration = { value = Value, source = Source }

    /// ノード（title: 〜 === の 1 つ）。headers は title 以外のヘッダ（読むだけ）。
    pub type alias Node = { title = String, headers = List[(String, String)], body = List[Statement], source = Source }

    /// ノード名 → ノードと、変数名 → 宣言。外では作らない（木の JSON を読むか empty）。
    enum Nodes({ nodes = Map[String, Node], variables = Map[String, Declaration] })

    /// シナリオ 1 つ分（フォルダの .yarn 全部）。
    pub type alias Program = Nodes

    /// 木の JSON の形の版（go/internal/yarn/tree.go の Version と同じ）。これ以下の版を読む。
    pub def version(): Int32 = 3

    /// ノードの無いシナリオ（どのノードを開いても、すぐ終わる）。
    pub def empty(): Program = Nodes.Nodes({ nodes = Map.empty(), variables = Map.empty() })

    pub def nodeOf(name: String, program: Program): Option[Node] =
        let Nodes.Nodes(p) = program; Map.get(name, p#nodes)

    /// ノード名の一覧（名前の順）。
    pub def nodeNames(program: Program): List[String] =
        let Nodes.Nodes(p) = program; Map.keysOf(p#nodes) |> Set.toList

    /// 変数の宣言（<<declare>> が無ければ None）。
    pub def declarationOf(name: String, program: Program): Option[Declaration] =
        let Nodes.Nodes(p) = program; Map.get(name, p#variables)

    /// 宣言した変数の名前と初めの値（名前の順）。
    pub def variablesOf(program: Program): List[(String, Value)] =
        let Nodes.Nodes(p) = program; p#variables |> Map.map(declaration -> declaration#value) |> Map.toList

    /// 値を台詞に差し込む字にする（公式と同じ: 数は整数なら小数点を付けない・真偽は True / False）。
    pub def toText(value: Value): String = match value {
        case Value.Number(n) =>
            if (Float64.floor(n) == n and Float64.abs(n) < 1.0e15) Float64.tryToInt64(n) |> Option.map(Int64.toString) |> Option.getWithDefault(Float64.toString(n))
            else Float64.toString(n)
        case Value.Bool(b)   => if (b) "True" else "False"
        case Value.Text(t)   => t
    }

    /// file の line 行を中に持つノードの名前（そのファイルで title: の行が line 以下の、いちばん後のノード）。
    /// エディタのカーソルの行からノードを引く（Studio の会話の画面・bin/fge talk goto と同じ決まり）。
    pub def nodeAtLine(file: String, line: Int32, program: Program): Option[String] =
        let Nodes.Nodes(p) = program;
        Map.valuesOf(p#nodes)
            |> List.filter(node -> node#source#file == file and node#source#line <= line)
            |> List.maximumBy((a, b) -> a#source#line <=> b#source#line)
            |> Option.map(node -> node#title)

    /// 行のマークアップ（書いた順）。{式} は値の字の長さで数える（YarnRunner の出来事の Line は値を入れてある）。
    pub def markupOf(line: Line): List[Markup] =
        let step = (acc, part) -> {
            let (pos, opened, done) = acc;
            match part {
                case Part.Literal(literal) => (pos + String.length(literal), opened, done)
                case Part.Insert(_)        => (pos, opened, done)
                case Part.Markup(name, value) => (pos, (name, value, pos) :: opened, done)
                case Part.Close(name) => match opened {
                    case (n, value, start) :: rest if n == name => (pos, rest, { name = name, value = value, start = start, length = pos - start } :: done)
                    case _ => (pos, opened, done)
                }
            }
        };
        let (_, _, done) = List.foldLeft(step, (0, Nil, Nil), line#parts);
        done |> List.sortWith((a, b) -> a#start <=> b#start)

    /// 行のルビ（[ruby=よみ]字[/ruby]）を RichText.placeRuby に渡す形で。
    pub def rubiesOf(line: Line): List[RichText.Ruby] =
        markupOf(line) |> List.filter(markup -> markup#name == "ruby")
                       |> List.map(markup -> { start = markup#start, length = markup#length, text = markup#value })

    /// 字の切れだけをつないだ字（{式} とマークアップは字にしない）。
    pub def plainTextOf(parts: List[Part]): String =
        parts |> List.map(part -> match part {
            case Part.Literal(literal) => literal
            case _                     => ""
        }) |> String.intercalate("")

    /// タグの値（そのキーのタグが無ければ None・値の無いタグは Some("")）。
    pub def tagOf(key: String, tags: List[Tag]): Option[String] =
        tags |> List.find(tag -> tag#key == key) |> Option.map(tag -> tag#value)

    /// 「ファイル:行」（F8 のチケットやログに出す形）。
    pub def sourceText(source: Source): String = "${source#file}:${Int32.toString(source#line)}"

    // ── 読む ──

    /// 木の JSON の文字からシナリオへ。形が違う・版が違う時は None（文を 1 つ落として続けると、台詞が知らせずに欠ける）。
    pub def fromJson(text: String): Option[Program] =
        DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(programFrom)

    /// path の木を読む。読めない・壊れている時は fallback（fail-open）。
    pub def loadOr(fallback: Program, path: String): Program \ Fs.FileRead =
        DocJson.loadOr(fromJson, fallback, path)

    def programFrom(root: Map[String, Json]): Option[Program] =
        let shape = JsonCodec.intOr("version", 0, root);
        if (shape < 1 or shape > version()) None
        else forM (
            nodes <- Map.get("nodes", root) |> Option.flatMap(JsonCodec.decodeList(nodeFrom));
            variables <- listOr("variables", root, variableFrom)
        ) yield Nodes.Nodes({ nodes = nodes |> List.map(node -> (node#title, node)) |> List.toMap, variables = List.toMap(variables) })

    def variableFrom(json: Json): Option[(String, Declaration)] = forM (
        obj <- JsonCodec.expectObject(json);
        value <- Map.get("value", obj) |> Option.flatMap(valueFromJson)
    ) yield (JsonCodec.stringOr("name", "", obj),
             { value = value, source = { file = JsonCodec.stringOr("file", "", obj), line = JsonCodec.intOr("line", 0, obj) } })

    /// JSON の数・真偽・文字列を値に（YarnStorage のセーブも同じ形）。
    pub def valueFromJson(json: Json): Option[Value] = match json {
        case Json.JNumber(_) => JsonCodec.expectFloat(json) |> Option.map(Value.Number)
        case Json.JBool(b)   => Some(Value.Bool(b))
        case Json.JString(t) => Some(Value.Text(t))
        case _               => None
    }

    /// 値を JSON の数・真偽・文字列に。
    pub def valueToJson(value: Value): Json = match value {
        case Value.Number(n) => Json.JNumber(JsonCodec.floatToBd(n))
        case Value.Bool(b)   => Json.JBool(b)
        case Value.Text(t)   => Json.JString(t)
    }

    def exprFrom(json: Json): Option[Expr] = forM (
        obj <- JsonCodec.expectObject(json);
        args <- listOr("args", obj, exprFrom);
        expr <- {
            let name = JsonCodec.stringOr("name", "", obj);
            match (JsonCodec.stringOr("kind", "", obj), args) {
                case ("value", _)              => Map.get("value", obj) |> Option.flatMap(valueFromJson) |> Option.map(Expr.Constant)
                case ("variable", _)           => Some(Expr.Variable(name))
                case ("visited", _)            => Some(Expr.Visited(name))
                case ("visited_count", _)      => Some(Expr.VisitCount(name))
                case ("not", operand :: Nil)   => Some(Expr.Not(operand))
                case ("neg", operand :: Nil)   => Some(Expr.Negate(operand))
                case ("and", left :: right :: Nil) => Some(Expr.And(left, right))
                case ("or", left :: right :: Nil)  => Some(Expr.Or(left, right))
                case (kind, left :: right :: Nil) => operatorOf(kind) |> Option.map(op -> Expr.Binary(op, left, right))
                case _                         => None
            }
        }
    ) yield expr

    def operatorOf(kind: String): Option[Operator] = match kind {
        case "+"   => Some(Operator.Add)
        case "-"   => Some(Operator.Subtract)
        case "*"   => Some(Operator.Multiply)
        case "/"   => Some(Operator.Divide)
        case "%"   => Some(Operator.Remainder)
        case "=="  => Some(Operator.Equal)
        case "!="  => Some(Operator.NotEqual)
        case "<"   => Some(Operator.Less)
        case "<="  => Some(Operator.LessEqual)
        case ">"   => Some(Operator.Greater)
        case ">="  => Some(Operator.GreaterEqual)
        case _     => None
    }

    /// key の式（無ければ Some(None)・読めなければ None）。
    def exprOr(key: String, obj: Map[String, Json]): Option[Option[Expr]] = match Map.get(key, obj) {
        case None       => Some(None)
        case Some(json) => exprFrom(json) |> Option.map(Some)
    }

    def nodeFrom(json: Json): Option[Node] = forM (
        obj <- JsonCodec.expectObject(json);
        headers <- listOr("headers", obj, headerFrom);
        file = JsonCodec.stringOr("file", "", obj);
        body <- Map.get("body", obj) |> Option.flatMap(JsonCodec.decodeList(statementFrom(file)))
    ) yield { title = JsonCodec.stringOr("title", "", obj), headers = headers, body = body,
              source = { file = file, line = JsonCodec.intOr("line", 0, obj) } }

    /// key の配列を読む（無ければ空・配列でなければ None）。
    def listOr(key: String, obj: Map[String, Json], decode: Json -> Option[t]): Option[List[t]] = match Map.get(key, obj) {
        case None       => Some(Nil)
        case Some(json) => JsonCodec.decodeList(decode, json)
    }

    def headerFrom(json: Json): Option[(String, String)] =
        JsonCodec.expectObject(json) |> Option.map(obj -> (JsonCodec.stringOr("key", "", obj), JsonCodec.stringOr("value", "", obj)))

    def statementFrom(file: String, json: Json): Option[Statement] = forM (
        obj <- JsonCodec.expectObject(json);
        statement <- {
            let source = { file = file, line = JsonCodec.intOr("line", 0, obj) };
            match JsonCodec.stringOr("kind", "", obj) {
                case "line"    => lineFrom(file, obj) |> Option.map(Statement.Say)
                case "options" => Map.get("options", obj) |> Option.flatMap(JsonCodec.decodeList(choiceFrom(file))) |> Option.map(Statement.Choose)
                case "jump"    => Some(Statement.Jump(JsonCodec.stringOr("node", "", obj), source))
                case "stop"    => Some(Statement.Stop(source))
                case "command" => forM (
                        tags <- tagsFrom(obj);
                        args <- listOr("args", obj, JsonCodec.expectString)
                    ) yield Statement.Command({ name = JsonCodec.stringOr("name", "", obj), args = args, tags = tags, source = source })
                case "set"     => Map.get("expr", obj) |> Option.flatMap(exprFrom) |> Option.map(expr -> Statement.Set(JsonCodec.stringOr("name", "", obj), expr, source))
                case "if"      => Map.get("clauses", obj) |> Option.flatMap(JsonCodec.decodeList(branchFrom(file))) |> Option.map(branches -> Statement.If(branches, source))
                case _         => None
            }
        }
    ) yield statement

    def choiceFrom(file: String, json: Json): Option[Choice] = forM (
        obj <- JsonCodec.expectObject(json);
        line <- lineFrom(file, obj);
        condition <- exprOr("condition", obj);
        body <- listOr("body", obj, statementFrom(file))
    ) yield { line = line, condition = condition, body = body }

    /// <<else>> の枝（条件の無い枝）は、真の定数を条件にする。
    def branchFrom(file: String, json: Json): Option[Branch] = forM (
        obj <- JsonCodec.expectObject(json);
        condition <- exprOr("condition", obj);
        body <- listOr("body", obj, statementFrom(file))
    ) yield { condition = Option.getWithDefault(Expr.Constant(Value.Bool(true)), condition), body = body }

    def lineFrom(file: String, obj: Map[String, Json]): Option[Line] = forM (
        tags <- tagsFrom(obj);
        parts <- listOr("parts", obj, partFrom)
    ) yield {
        let text = JsonCodec.stringOr("text", "", obj);
        { speaker = JsonCodec.stringOr("speaker", "", obj), text = text,
          parts = if (List.isEmpty(parts)) Part.Literal(text) :: Nil else parts, tags = tags,
          source = { file = file, line = JsonCodec.intOr("line", 0, obj) } }
    }

    def partFrom(json: Json): Option[Part] = forM (
        obj <- JsonCodec.expectObject(json);
        part <- match (Map.get("expr", obj), JsonCodec.stringOr("markup", "", obj), JsonCodec.stringOr("close", "", obj)) {
            case (Some(expr), _, _) => exprFrom(expr) |> Option.map(Part.Insert)
            case (None, "", "")     => Some(Part.Literal(JsonCodec.stringOr("text", "", obj)))
            case (None, "", close)  => Some(Part.Close(close))
            case (None, name, _)    => Some(Part.Markup(name, JsonCodec.stringOr("value", "", obj)))
        }
    ) yield part

    def tagsFrom(obj: Map[String, Json]): Option[List[Tag]] =
        listOr("tags", obj, json ->
            JsonCodec.expectObject(json) |> Option.map(tag -> { key = JsonCodec.stringOr("key", "", tag), value = JsonCodec.stringOr("value", "", tag) }))

    // ── 語彙（bin/fge yarn build の check が読む名前の一覧。正はゲームのコードの enum）──

    /// speakers = 話し手の id、nodes = コードが開くノード、tags = タグのキーと取れる値（空なら値を書かない #key）、
    /// commands = wait の他にシナリオに書けるコマンド（エンジンが読むのは wait だけなので、ふつうは空）。
    pub type alias Vocab = {
        speakers = List[String],
        nodes = List[String],
        tags = List[(String, List[String])],
        commands = List[String]
    }

    /// enum の全部の値を名前の一覧にする（語彙の欄を作る所で使う）。
    pub def namesOf(name: a -> String, values: List[a]): List[String] = values |> List.map(name)

    /// 語彙を vocab.json の形にする（キーの順は固定。flow の e2e/vocab.json と同じ書き方）。
    pub def vocabJson(vocab: Vocab): String =
        let quote = text -> "\"" + escape(text) + "\"";
        let list = xs -> "[" + (xs |> List.map(quote) |> String.intercalate(", ")) + "]";
        let tags = vocab#tags |> List.map(row -> { let (key, values) = row; "    ${quote(key)}: ${list(values)}" });
        "{\n" +
        "  \"speakers\": ${list(vocab#speakers)},\n" +
        "  \"nodes\": ${list(vocab#nodes)},\n" +
        "  \"tags\": " + (if (List.isEmpty(tags)) "{}" else "{\n" + String.intercalate(",\n", tags) + "\n  }") + ",\n" +
        "  \"commands\": ${list(vocab#commands)}\n" +
        "}\n"

    /// 語彙を path に書く（書けたか）。ゲームの Talk.vocab が呼ぶ（bin/headless-run が jar を作った時・make talk-vocab）。
    pub def writeVocab(path: String, vocab: Vocab): Bool \ Fs.FileWrite =
        run { Fs.WriteFile.write({str = vocabJson(vocab)}, path) |> Result.isOk } with Fs.WriteFile.runWithFileWrite

    def escape(text: String): String =
        text |> String.replace(src = "\\", dst = "\\\\") |> String.replace(src = "\"", dst = "\\\"")
             |> String.replace(src = "\n", dst = "\\n")
}
