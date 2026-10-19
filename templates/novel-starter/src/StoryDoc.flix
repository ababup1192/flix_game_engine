// StoryDoc — novel.story.json（表紙とメニューの文言・灯りの数・話し手の呼び名）の宣言ドキュメント層。
// 文章・分岐・結末はシナリオ assets/talk/novel.yarn（Talk）にあり、ここは画面に出す言葉と数だけを持つ。
// 進め方の規則（どの行を出すか・灯りをいつ消すか）はコード（World）側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod StoryDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 話し手の呼び名 1 行。id = シナリオの話し手（Talk.Speaker の id）、name = 会話ウィンドウに出す名前。
    pub type alias SpeakerName = { id = String, name = String }

    /// title / subtitle / hint = 表紙の文言（事件の名前・一行・はじめ方のヒント）、
    /// menuTitle / menuHint = メニュー（物語を止めるウィンドウ）の見出しと戻り方のヒント、
    /// lamps = 館の灯りの数（疑うたびに 1 つ消える）、speakers = 話し手の呼び名の rows。
    pub type alias Rec = {
        version = Int32,
        title = String,
        subtitle = String,
        hint = String,
        menuTitle = String,
        menuHint = String,
        lamps = Int32,
        speakers = List[SpeakerName]
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.story.json"

    /// コード側の既定値。呼び名が読めなければ話し手の id をそのまま出す（nameOf）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
                  title = "消えた絵", subtitle = "雨の夜、洋館の書斎から一枚の絵が消えた",
                  hint = "クリックではじめる",
                  menuTitle = "― 一時停止 ―", menuHint = "Esc でつづきへ",
                  lamps = 3, speakers = Nil })

    /// 話し手の id の呼び名（地の文の空の id は空・rows に無い id はそのまま）。
    pub def nameOf(id: String, doc: Doc): String =
        rec(doc)#speakers |> List.find(row -> row#id == id) |> Option.map(row -> row#name) |> Option.getWithDefault(id)

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  title = JsonCodec.stringOr("title", d#title, root),
                  subtitle = JsonCodec.stringOr("subtitle", d#subtitle, root),
                  hint = JsonCodec.stringOr("hint", d#hint, root),
                  menuTitle = JsonCodec.stringOr("menuTitle", d#menuTitle, root),
                  menuHint = JsonCodec.stringOr("menuHint", d#menuHint, root),
                  lamps = JsonCodec.intOr("lamps", d#lamps, root),
                  speakers = Map.get("speakers", root)
                      |> Option.flatMap(JsonCodec.decodeList(speakerFromJson))
                      |> Option.getWithDefault(d#speakers) })

    def speakerFromJson(json: Json): Option[SpeakerName] =
        JsonCodec.expectObject(json) |> Option.map(obj ->
            { id = JsonCodec.stringOr("id", "", obj), name = JsonCodec.stringOr("name", "", obj) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
