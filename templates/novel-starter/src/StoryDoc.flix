// StoryDoc — novel.story.json（台本: 文章・分岐・結末の rows）の宣言ドキュメント層。
// 文章と分岐先は全部この Doc にあり、書き換えれば別の事件になる。
// 進め方の規則（どのビートを出すか・灯りをいつ消すか）はコード（World）側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod StoryDoc {
    use Util.Json.Json

    /// 選択肢 1 つ。label = 画面に出す言葉、goto = 選んだ先の節 id、
    /// suspect = 「誰かを疑う」選択か（true なら館の灯りがひとつ消える）。
    pub type alias Choice = { label = String, goto = String, suspect = Bool }

    /// 質問（選択肢を出すビート）。beats を読み終えた節がこれを出し、options から 1 つ選ばせる。
    pub type alias Ask = { speaker = String, text = String, options = List[Choice] }

    /// 地の文・セリフの 1 ビート。speaker が空文字なら地の文。
    pub type alias Beat = { speaker = String, text = String }

    /// 台本の 1 節。beats を順に読み、読み終えたら ask（あれば）で分岐する。
    /// ask が無ければ next の節へ流れ、ask も next も無い節が結末（読み終わりで表紙へ戻る）。
    pub type alias Section = { id = String, beats = List[Beat], ask = Option[Ask], next = String }

    /// 台本全体。title / subtitle / hint = 表紙の文言（事件の名前・一行・はじめ方のヒント）、
    /// start = 最初に読む節の id、lamps = 館の灯りの数（疑うたびに 1 つ消える）。
    pub type alias Rec = {
        version = Int32,
        title = String,
        subtitle = String,
        hint = String,
        start = String,
        lamps = Int32,
        sections = List[Section]
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.story.json"

    /// コード側の既定値。台本が読めなくても「直し方を語る 1 節」でゲームは必ず起動する。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
                  title = "消えた絵", subtitle = "雨の夜、洋館の書斎から一枚の絵が消えた",
                  hint = "クリックではじめる",
                  start = "start", lamps = 3,
                  sections =
                      { id = "start",
                        beats = { speaker = "", text = "（台本が読めない。assets/novel.story.json を直すと、ここに物語が流れる）" } :: Nil,
                        ask = None, next = "" } :: Nil })

    /// id の節を引く（無ければ None）。
    pub def sectionOf(id: String, doc: Doc): Option[Section] =
        List.find(section -> section#id == id, rec(doc)#sections)

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  title = JsonCodec.stringOr("title", d#title, root),
                  subtitle = JsonCodec.stringOr("subtitle", d#subtitle, root),
                  hint = JsonCodec.stringOr("hint", d#hint, root),
                  start = JsonCodec.stringOr("start", d#start, root),
                  lamps = JsonCodec.intOr("lamps", d#lamps, root),
                  sections = Map.get("sections", root)
                      |> Option.flatMap(JsonCodec.decodeList(sectionFromJson))
                      |> Option.getWithDefault(d#sections) })

    /// 節 1 行。欠けたフィールドは行の中で既定へ落とす（行がオブジェクトでない台本は
    /// decodeList が全体を None にし、defaults の台本へ落ちる）。
    def sectionFromJson(json: Json): Option[Section] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { id = JsonCodec.stringOr("id", "", obj),
              beats = Map.get("beats", obj)
                  |> Option.flatMap(JsonCodec.decodeList(beatFromJson))
                  |> Option.getWithDefault(Nil),
              ask = Map.get("ask", obj) |> Option.flatMap(askFromJson),
              next = JsonCodec.stringOr("next", "", obj) })

    def beatFromJson(json: Json): Option[Beat] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { speaker = JsonCodec.stringOr("speaker", "", obj),
              text = JsonCodec.stringOr("text", "", obj) })

    def askFromJson(json: Json): Option[Ask] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { speaker = JsonCodec.stringOr("speaker", "", obj),
              text = JsonCodec.stringOr("text", "", obj),
              options = Map.get("options", obj)
                  |> Option.flatMap(JsonCodec.decodeList(choiceFromJson))
                  |> Option.getWithDefault(Nil) })

    def choiceFromJson(json: Json): Option[Choice] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { label = JsonCodec.stringOr("label", "", obj),
              goto = JsonCodec.stringOr("goto", "", obj),
              suspect = JsonCodec.boolOr("suspect", false, obj) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
