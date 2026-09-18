// StageDoc — stages.stage.json(面データ)の宣言ドキュメント層。
// 面は rows(文字格子・1 文字 = 1 タイル)で書く。どの文字が何かは note と
// Stage モジュールの対応表が正。fail-open — 読めない・壊れているときは
// defaults()(組み込みの小さな 1 面)へ落とし、ゲームは必ず起動する。
mod StageDoc {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString}

    /// 1 面の宣言。kind は空気(空の色・照明・背後壁)を選ぶ: outdoor / cave / tower。
    pub type alias Spec = { name = String, kind = String, rows = List[String] }

    pub type alias Rec = { version = Int32, stages = List[Spec] }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/stages.stage.json"

    /// 組み込みの 1 面(stage.json が無くても遊べる最小の丘)。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          stages = { name = "HILL", kind = "outdoor", rows =
                "........................"
             :: "........................"
             :: "..........o.o........G.."
             :: "......=.....~~.......##."
             :: "..P........o......a....."
             :: "###...####......####..##"
             :: "###...####......####..##"
             :: "########################"
             :: Nil } :: Nil })

    /// テキストから Doc へ(fail-open)。stages が空・rows が欠けたら既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let stages = match Map.get("stages", root) {
            case Some(JArray(xs)) => xs |> Vector.toList |> List.filterMap(specOf)
            case _                => Nil
        };
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          stages  = if (List.isEmpty(stages)) d#stages else stages })

    def specOf(json: Json): Option[Spec] =
        match json {
            case JObject(obj) =>
                let rows = match Map.get("rows", obj) {
                    case Some(JArray(xs)) => xs |> Vector.toList |> List.filterMap(x -> match x {
                        case JString(s) => Some(s)
                        case _          => None
                    })
                    case _ => Nil
                };
                if (List.isEmpty(rows)) None
                else Some({ name = JsonCodec.stringOr("name", "?", obj),
                            kind = JsonCodec.stringOr("kind", "outdoor", obj),
                            rows = rows })
            case _ => None
        }

    /// path の Doc を読む。読めない・壊れているときは defaults(fail-open)。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
