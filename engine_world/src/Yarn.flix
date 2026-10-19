// Yarn — 会話のシナリオ（Yarn Spinner の .yarn の部分集合）を、bin/fge yarn build が書き出した木の JSON から読む。
// .yarn を読むのは Go の build だけ（読み手を 1 つにする）。ここは木を読み、YarnRunner が木を直に辿る。
//
//   assets/talk/*.yarn ──bin/fge yarn build──▶ assets/talk/dialogue.json ──Yarn.loadOr──▶ Yarn.Program
//   ゲームの enum ──Yarn.vocabJson（ゲームの Talk.vocab・make talk-vocab）──▶ assets/talk/vocab.json ──build の check が読む
//
// シナリオに書く物: 台詞・話し手・タグ（表情・後ろの場面など。値はゲームの enum の名前）。
// コードに書く物: どのノードを開くか・演出の拍の順番。文字送りの速さ・ウィンドウの出入り・立ち絵・呼び名は Doc。
// 読める文法と断る文法は bin/fge yarn help、木の形は go/internal/yarn/tree.go。
pub mod Yarn {
    use Util.Json.Json

    /// 行がどこにあるか。file = ゲームのルートからの .yarn のパス、line = 1 始まりの行番号。
    pub type alias Source = { file = String, line = Int32 }

    /// #key:value のタグ（値の無い #key は value が空）。
    pub type alias Tag = { key = String, value = String }

    /// 台詞 1 行。speaker = 話し手の id（地の文は空）、text = 出す字（エスケープは解いてある）。
    pub type alias Line = { speaker = String, text = String, tags = List[Tag], source = Source }

    /// <<名前 引数…>>。エンジンが自分で扱うのは wait（YarnRunner が待つ）だけ。
    pub type alias Command = { name = String, args = List[String], tags = List[Tag], source = Source }

    /// 本文の 1 文。
    ///   Say     … 台詞を出して、送られるまで待つ
    ///   Choose  … 選択肢を出して、選ばれたらその中身を流し、終わると選択肢の後ろへ戻る
    ///   Jump    … 別のノードの頭へ移る
    ///   Stop    … 会話を終える
    ///   Command … コマンド
    pub enum Statement {
        case Say(Line)
        case Choose(List[Choice])
        case Jump(String, Source)
        case Stop(Source)
        case Command(Command)
    }

    /// 選択肢 1 つ。line = 出す字と話し手・タグ、body = 選んだ時に流す中身。
    pub type alias Choice = { line = Line, body = List[Statement] }

    /// ノード（title: 〜 === の 1 つ）。headers は title 以外のヘッダ（読むだけ）。
    pub type alias Node = { title = String, headers = List[(String, String)], body = List[Statement], source = Source }

    /// ノード名 → ノード。外では作らない（木の JSON を読むか empty）。
    enum Nodes(Map[String, Node])

    /// シナリオ 1 つ分（フォルダの .yarn 全部）。
    pub type alias Program = Nodes

    /// 木の JSON の形の版（go/internal/yarn/tree.go の Version と同じ）。
    pub def version(): Int32 = 1

    /// ノードの無いシナリオ（どのノードを開いても、すぐ終わる）。
    pub def empty(): Program = Nodes.Nodes(Map.empty())

    pub def nodeOf(name: String, program: Program): Option[Node] = match program {
        case Nodes.Nodes(nodes) => Map.get(name, nodes)
    }

    /// ノード名の一覧（名前の順）。
    pub def nodeNames(program: Program): List[String] = match program {
        case Nodes.Nodes(nodes) => Map.keysOf(nodes) |> Set.toList
    }

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
        if (JsonCodec.intOr("version", 0, root) != version()) None
        else Map.get("nodes", root)
            |> Option.flatMap(JsonCodec.decodeList(nodeFrom))
            |> Option.map(nodes -> Nodes.Nodes(nodes |> List.map(node -> (node#title, node)) |> List.toMap))

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
                case _         => None
            }
        }
    ) yield statement

    def choiceFrom(file: String, json: Json): Option[Choice] = forM (
        obj <- JsonCodec.expectObject(json);
        line <- lineFrom(file, obj);
        body <- listOr("body", obj, statementFrom(file))
    ) yield { line = line, body = body }

    def lineFrom(file: String, obj: Map[String, Json]): Option[Line] =
        tagsFrom(obj) |> Option.map(tags ->
            { speaker = JsonCodec.stringOr("speaker", "", obj), text = JsonCodec.stringOr("text", "", obj), tags = tags,
              source = { file = file, line = JsonCodec.intOr("line", 0, obj) } })

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
