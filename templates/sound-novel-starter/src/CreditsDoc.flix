// CreditsDoc — novel.credits.json（クレジットに流す行）の宣言ドキュメント層。
// 写真（CC BY は作者と許諾を画面に出すのが条件）とフォント（SIL OFL）の表記はここに書き、
// 同じ物を CREDITS.md にも書く（配る物の中で、遊ぶ人にも読む人にも見える所に置く）。
// 行の style は heading（見出し）/ body（本文）/ small（出典の URL など）/ gap（空き）。
mod CreditsDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    pub enum Style with Eq, ToString {
        case Heading
        case Body
        case Small
        case Gap
    }

    pub type alias Row = { text = String, style = Style }

    pub type alias Rec = { version = Int32, rows = List[Row] }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.credits.json"

    pub def defaults(): Doc = Doc.Doc({ version = 1, rows = { text = "夏草の駅", style = Style.Heading } :: Nil })

    pub def styleOf(text: String): Style = match text {
        case "heading" => Style.Heading
        case "small"   => Style.Small
        case "gap"     => Style.Gap
        case _         => Style.Body
    }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rowOf = j -> JsonCodec.expectObject(j) |> Option.map(obj ->
            { text = JsonCodec.stringOr("text", "", obj), style = styleOf(JsonCodec.stringOr("style", "body", obj)) });
        Doc.Doc({ version = JsonCodec.intOr("version", 1, root),
                  rows = Map.get("rows", root) |> Option.flatMap(JsonCodec.decodeList(rowOf))
                      |> Option.getWithDefault(rec(defaults())#rows) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
