// Talk — シナリオ（assets/talk/*.yarn）とコードの繋ぎ。
// 話し手・変数の表示名・最初に開くノードの正は novel.story.json（StoryDoc）、描き出しの場面が指すノードは novel.shots.json、
// コマンドと引数の表の正は Commands（テンプレートの表 + GameCommands）。
// bin/fge yarn build の check は assets/talk/vocab.json と、隣の vocab.std.json（テンプレートの命令の表 Commands.all()）を合わせて読み、
// 名前を Doc から集め、コマンドの引数を表で検査する（vocab.json が書くのは Doc のどこを見るかとゲームの命令の表 GameCommands.all() だけ。
// 書き直すのは make talk-vocab。TestDocs が一致を見る）。vocab.std.json はテンプレートの追随で上書きされる物で、ゲームでは直さない。
//
//   assets/talk/yukidoke.yarn ──bin/fge yarn build assets/talk──▶ assets/talk/dialogue.json ──load──▶ World#dialogue
mod Talk {
    use fge::{JsonCodec, Yarn, YarnCommands, YarnRunner}
    use Util.Json.Json

    pub def dialoguePath(): String = "assets/talk/dialogue.json"

    pub def vocabPath(): String = "assets/talk/vocab.json"

    pub def stdVocabPath(): String = "assets/talk/vocab.std.json"

    /// シナリオを読む。読めない・壊れている時はノードの無いシナリオ（World が直し方を語る 1 行を出す）。
    pub def load(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), dialoguePath())

    /// ノードの全部の文（選択肢と <<if>> の枝の中身も。書いた順）。
    def statementsOf(node: Yarn.Node): List[Yarn.Statement] = flatten(node#body)

    def flatten(body: List[Yarn.Statement]): List[Yarn.Statement] =
        body |> List.flatMap(statement -> statement :: flatten(innerOf(statement)))

    def innerOf(statement: Yarn.Statement): List[Yarn.Statement] = match statement {
        case Yarn.Statement.Choose(choices) => choices |> List.flatMap(choice -> choice#body)
        case Yarn.Statement.If(branches, _) => branches |> List.flatMap(branch -> branch#body)
        case _                              => Nil
    }

    /// 文の .yarn の行（選択肢の並びは最初の選択肢の行）。
    def sourceOf(statement: Yarn.Statement): Option[Yarn.Source] = match statement {
        case Yarn.Statement.Say(line)         => Some(line#source)
        case Yarn.Statement.Choose(choices)   => List.head(choices) |> Option.map(choice -> choice#line#source)
        case Yarn.Statement.Jump(_, source)   => Some(source)
        case Yarn.Statement.Stop(source)      => Some(source)
        case Yarn.Statement.Command(command)  => Some(command#source)
        case Yarn.Statement.Set(_, _, source) => Some(source)
        case Yarn.Statement.If(_, source)     => Some(source)
    }

    /// 実行器の出来事の .yarn の行（選択肢は最初の選択肢の行。Done は無い）。
    pub def eventSourceOf(event: YarnRunner.Event): Option[Yarn.Source] = match event {
        case YarnRunner.Event.Line(line)       => sourceOf(Yarn.Statement.Say(line))
        case YarnRunner.Event.Choices(options) => List.head(options) |> Option.map(option -> option#line#source)
        case YarnRunner.Event.Command(command) => sourceOf(Yarn.Statement.Command(command))
        case YarnRunner.Event.Done             => None
    }

    /// .yarn の「ファイル:行」→ その行を持つノードの名前（選択肢と <<if>> の中身の行も）。
    pub def nodesBySource(program: Yarn.Program): Map[String, String] =
        Yarn.nodeNames(program) |> List.filterMap(name -> Yarn.nodeOf(name, program)) |> List.flatMap(node ->
            statementsOf(node) |> List.filterMap(sourceOf) |> List.map(source -> (Yarn.sourceText(source), node#title)))
            |> List.toMap

    /// シナリオの全部のコマンド（<<wait>> も）。
    pub def commandsOf(program: Yarn.Program): List[Yarn.Command] =
        Yarn.nodeNames(program) |> List.filterMap(name -> Yarn.nodeOf(name, program)) |> List.flatMap(statementsOf)
            |> List.filterMap(statement -> match statement {
                case Yarn.Statement.Command(command) => Some(command)
                case _                               => None
            })

    /// vocab.json から見た Doc のパス（vocab.json は assets/talk/、Doc は assets/ に置く）。
    def fromVocab(docPath: String): String =
        "../" + (String.stripPrefix(substr = "assets/", docPath) |> Option.getWithDefault(docPath))

    /// build の check が読む語彙（vocab.json の版 2）。名前の正が Doc にある欄は from で Doc の場所だけを書く。
    pub def vocabJson(): String =
        let story = fromVocab(StoryDoc.path());
        let vocab = Json.JObject(Map#{
            "version"  => Json.JNumber(JsonCodec.intToBd(2)),
            "speakers" => docField(story, "keys", "names"),
            "vars"     => docField(story, "keys", "vars"),
            "nodes"    => docField(story, "path", "opening"),
            "nodeRefs" => docField(fromVocab(ShotsDoc.path()), "path", "shots[].node"),
            "tags"     => Gate.tagsJson(fromVocab(PromptsDoc.path())),
            "commands" => YarnCommands.toJson(GameCommands.all() |> List.map(c -> c#spec))
        });
        Util.Json.toPrettyString(2, vocab) + "\n"

    /// テンプレートの命令の表（vocab.std.json。go が vocab.json の commands と合わせて読む。同じ名前があると止める）。
    pub def stdVocabJson(): String =
        let vocab = Json.JObject(Map#{
            "version"  => Json.JNumber(JsonCodec.intToBd(2)),
            "commands" => YarnCommands.toJson(Commands.all() |> List.map(c -> c#spec))
        });
        Util.Json.toPrettyString(2, vocab) + "\n"

    /// 欄 1 つの from（Doc の docPath の、how = keys か path の place を見る）。
    def docField(docPath: String, how: String, place: String): Json =
        Json.JObject(Map#{ "from" => Json.JArray(Vector#{ Json.JObject(Map#{ "doc" => Json.JString(docPath), how => Json.JString(place) }) }) })

    /// 語彙を assets/talk/vocab.json と vocab.std.json に書く（make talk-vocab）。
    pub def vocab(): Unit \ IO =
        let report = (path, wrote) -> println(if (wrote) "[talk] 語彙を書いた: ${path}" else "[talk] 語彙を書けない: ${path}");
        report(vocabPath(), run { writeText(vocabPath(), vocabJson()) } with Fs.FileWrite.runWithIO);
        report(stdVocabPath(), run { writeText(stdVocabPath(), stdVocabJson()) } with Fs.FileWrite.runWithIO)

    def writeText(path: String, text: String): Bool \ Fs.FileWrite =
        run { Fs.WriteFile.write({str = text}, path) |> Result.isOk } with Fs.WriteFile.runWithFileWrite
}
