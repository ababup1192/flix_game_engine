// LevelsDoc — tidepool.levels.json（面ごとの 2 枚の格子・満ち引きの表・最少手数と解き方）の Doc 層。
// 盤の値へ組むのは Board.fromRows。par・solution・solvedHash は make solve（Solve）が書く。
// fail-open — 読めない・組めない面は飛ばし（Res.stagesOf が 1 行ずつ言う）、1 面も無ければ defaults() の 1 面で起動する。
mod LevelsDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 1 面の書き物（Doc の字のまま）。cycle が None なら rules の既定の満ち引き。
    /// solution は手の列（U D L R W）。solvedHash は make solve が確かめた時の面の中身の指紋。
    pub type alias Level = {
        name = String,
        heights = List[String],
        props = List[String],
        cycle = Option[List[Int32]],
        parMoves = Int32,
        solution = String,
        solvedHash = String
    }

    pub type alias Rec = { version = Int32, levels = List[Level] }

    /// 型検査が record を展開しないため、Res が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/tidepool.levels.json"

    /// コード側の既定（assets の面 1 と同じ、引き潮の間に浅瀬を渡る 1 面）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, levels =
            { name = "引き潮の間に渡る", cycle = None, parMoves = 0, solution = "", solvedHash = "",
              heights = "000000" :: "321123" :: "000000" :: Nil,
              props   = "......" :: "@....*" :: "......" :: Nil } :: Nil })

    /// テキストから Doc へ（fail-open）。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let levels = Map.get("levels", root)
            |> Option.flatMap(json -> JsonCodec.decodeList(j -> Some(j), json))
            |> Option.getWithDefault(Nil)
            |> List.filterMap(json -> JsonCodec.expectObject(json) |> Option.flatMap(levelOf));
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root), levels = levels })

    def levelOf(obj: Map[String, Json]): Option[Level] =
        let rows = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString));
        forM (heights <- rows("heights"); props <- rows("props")) yield
            { name = JsonCodec.stringOr("name", "", obj), heights = heights, props = props,
              cycle = RulesDoc.cycleAt("cycle", obj),
              parMoves = JsonCodec.intOr("par", 0, obj),
              solution = JsonCodec.stringOr("solution", "", obj),
              solvedHash = JsonCodec.stringOr("solvedHash", "", obj) }

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    /// 面の満ち引きの表（面に無ければ rules の既定）。
    pub def cycleOf(rules: RulesDoc.Doc, level: Level): Vector[Int32] =
        level#cycle |> Option.getWithDefault(RulesDoc.rec(rules)#cycle) |> List.toVector

    /// 面の盤。盤の規則に合わない面は理由を返す（面の名前つき）。
    pub def boardOf(rules: RulesDoc.Doc, level: Level): Result[String, Board.Board] =
        Board.fromRows(cycleOf(rules, level), level#heights, level#props)
            |> Result.mapErr(why -> "面「${level#name}」: ${why}")

    /// 遊べる面の列と、飛ばした面の理由。1 面も組めなければ既定の 1 面（その旨も理由に足す）。
    pub def boardsOf(rules: RulesDoc.Doc, doc: Doc): { boards = List[(Level, Board.Board)], problems = List[String] } =
        let built = rec(doc)#levels |> List.map(level -> (level, boardOf(rules, level)));
        let problems = built |> List.filterMap(e -> match snd(e) { case Err(why) => Some("[levels] ${why}（飛ばします）") case Ok(_) => None });
        let boards = built |> List.filterMap(e -> match e { case (level, Ok(b)) => Some((level, b)) case _ => None });
        if (not List.isEmpty(boards)) { boards = boards, problems = problems }
        else { boards = rec(defaults())#levels |> List.filterMap(level -> boardOf(rules, level) |> Result.toOption |> Option.map(b -> (level, b))),
               problems = List.append(problems, "[levels] 遊べる面が無いので既定の 1 面で始めます" :: Nil) }

    /// 遊べる面の名前（並びのまま。題名の画面の面選び・テストが読む）。
    pub def playableNames(rules: RulesDoc.Doc, doc: Doc): List[String] =
        boardsOf(rules, doc)#boards |> List.map(e -> fst(e)#name)

    /// 面の中身（heights・props・使う満ち引きの表）の指紋。make solve が確かめた時の物と比べ、
    /// 面を直したのに解き直していないのを見つける。
    /// WhyNot: cycle を面の字のままでなく使う表で数える。rules の既定を変えても最少手数は変わりうるので。
    pub def contentHash(rules: RulesDoc.Doc, level: Level): String =
        let text = List.join("/", level#heights) + "|" + List.join("/", level#props) + "|"
            + (cycleOf(rules, level) |> Vector.map(Int32.toString) |> Vector.join(","));
        let hash = String.toList(text) |> List.foldLeft((h, ch) ->
            Int64.bitwiseAnd(Int64.bitwiseXor(h, Int32.toInt64(Char.toBmpCodePoint(ch))) * 16777619i64, 4294967295i64),
            2166136261i64);
        Int64.toString(hash)

    /// 解いた結果（最少手数・解き方・指紋）を面の Json に書き足した Doc のテキスト。面の他の欄はそのまま残す。
    /// solved は面の並びと同じ順（None の面は書き換えない）。数が合わない（読めない面がある）ときは None。
    pub def withSolved(solved: List[Option[{ parMoves = Int32, solution = String, solvedHash = String }]], text: String): Option[String] =
        forM (
            json <- DocJson.parse(text);
            root <- JsonCodec.expectObject(json);
            levels <- Map.get("levels", root) |> Option.flatMap(JsonCodec.decodeList(j -> Some(j)))
                |> Option.filter(ls -> List.length(ls) == List.length(solved))
        ) yield {
            let written = List.zip(levels, solved) |> List.map(match (level, answer) -> match (level, answer) {
                case (Json.JObject(obj), Some(a)) => Json.JObject(obj
                    |> Map.insert("par", Json.JNumber(JsonCodec.intToBd(a#parMoves)))
                    |> Map.insert("solution", Json.JString(a#solution))
                    |> Map.insert("solvedHash", Json.JString(a#solvedHash)))
                case _ => level
            });
            Util.Json.toPrettyString(2, Json.JObject(Map.insert("levels", Json.JArray(List.toVector(written)), root))) + "\n"
        }
}
