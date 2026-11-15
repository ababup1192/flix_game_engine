// Talk — シナリオ（assets/talk/*.yarn）とコードの繋ぎ。
// 話し手・変数の表示名・最初に開くノードの正は novel.story.json（StoryDoc）、描き出しの場面が指すノードは novel.shots.json、
// コマンドと引数の表の正は Commands（テンプレートの表 + GameCommands）。
// bin/fge yarn build の check は assets/talk/vocab.json を読み、名前を Doc から集め、コマンドの引数を表で検査する
// （vocab.json が書くのは Doc のどこを見るかとコマンドの表だけ。書き直すのは make talk-vocab。TestDocs が一致を見る）。
//
//   assets/talk/natsukusa.yarn ──bin/fge yarn build assets/talk──▶ assets/talk/dialogue.json ──load──▶ World#dialogue
mod Talk {
    use fge::{JsonCodec, Yarn, YarnCommands}
    use Util.Json.Json

    pub def dialoguePath(): String = "assets/talk/dialogue.json"

    pub def vocabPath(): String = "assets/talk/vocab.json"

    /// シナリオを読む。読めない・壊れている時はノードの無いシナリオ（World が直し方を語る 1 行を出す）。
    pub def load(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), dialoguePath())

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
            "tags"     => Json.JObject(Map.empty()),
            "commands" => YarnCommands.toJson(Commands.specs())
        });
        Util.Json.toPrettyString(2, vocab) + "\n"

    /// 欄 1 つの from（Doc の docPath の、how = keys か path の place を見る）。
    def docField(docPath: String, how: String, place: String): Json =
        Json.JObject(Map#{ "from" => Json.JArray(Vector#{ Json.JObject(Map#{ "doc" => Json.JString(docPath), how => Json.JString(place) }) }) })

    /// 語彙を assets/talk/vocab.json に書く（make talk-vocab）。
    pub def vocab(): Unit \ IO =
        let wrote = run { writeVocab() } with Fs.FileWrite.runWithIO;
        println(if (wrote) "[talk] 語彙を書いた: ${vocabPath()}" else "[talk] 語彙を書けない: ${vocabPath()}")

    def writeVocab(): Bool \ Fs.FileWrite =
        run { Fs.WriteFile.write({str = vocabJson()}, vocabPath()) |> Result.isOk } with Fs.WriteFile.runWithFileWrite
}
