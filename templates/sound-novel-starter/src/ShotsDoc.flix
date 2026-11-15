// ShotsDoc — novel.shots.json（描き出しの場面: make render の SHOT とギャラリーの並びの正）の宣言ドキュメント層。
// 場面ごとの値（ノード・何番目の台詞か・変数・開く画面・マウス・秒）だけを持ち、World の組み立ては Shots のコードが受け持つ。
// fail-open — Doc が読めなければ場面は無し。1 場面が読めない（名前が無い・知らない画面）時は 1 行言ってその場面だけ飛ばす。
mod ShotsDoc {
    use fge::{DocJson, JsonCodec, Log, Vec2}
    use Util.Json.Json

    /// 場面で開く画面（Doc の open。title はタイトル画面のまま・hold は次の写真を待っている所）。
    pub enum Screen with Eq, ToString {
        case Title
        case Log
        case Save
        case Load
        case Settings
        case Ask
        case Credits
        case Hold
    }

    /// ノードのどこまで進めるか（Doc の say と until。どちらも無ければノードの頭）。
    pub enum Place with Eq, ToString {
        case Head
        case NthSay(Int32)
        case ToChoices
    }

    /// 1 場面。node = 開くノード（無ければ起動した時の World から）、vars = シナリオの変数（$ を付けない名前 → 値）、
    /// open = 開く画面、pointer = マウスの位置（design px）、at = 時計を据える秒。
    pub type alias Shot = {
        name = String,
        node = Option[String],
        place = Place,
        vars = Map[String, String],
        open = Option[Screen],
        pointer = Option[Vec2.Vec2],
        at = Float64
    }

    pub type alias Rec = { version = Int32, shots = List[Shot] }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.shots.json"

    pub def defaults(): Doc = Doc.Doc({ version = 1, shots = Nil })

    /// 名前の場面。
    pub def shotOf(name: String, doc: Doc): Option[Shot] = rec(doc)#shots |> List.find(s -> s#name == name)

    /// 場面の名前（Doc の並び）。
    pub def namesOf(doc: Doc): List[String] = rec(doc)#shots |> List.map(s -> s#name)

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    /// 場面の行ごとの読めた物と読めない理由（(どの場面か, 理由)）。fromJson は読めない行を 1 行言って飛ばす。
    /// 同じ名前の 2 つ目からは読めない行にする（SHOT=<名前> で引けるのは 1 つだけ）。
    pub def rowsOf(text: String): Option[List[Result[(String, String), Shot]]] =
        DocJson.decodeObject(decodeRows, text)

    def decodeRows(root: Map[String, Json]): List[Result[(String, String), Shot]] =
        let rows = Map.get("shots", root) |> Option.flatMap(JsonCodec.decodeList(Some)) |> Option.getWithDefault(Nil)
            |> List.mapWithIndex((i, row) -> decodeShot(i, row));
        let (_, checked) = rows |> List.foldLeft((state, r) -> {
            let (seen, acc) = state;
            let (nextSeen, row) = markRepeated(seen, r);
            (nextSeen, row :: acc)
        }, (Set.empty(), Nil));
        List.reverse(checked)

    def markRepeated(seen: Set[String], r: Result[(String, String), Shot]): (Set[String], Result[(String, String), Shot]) = match r {
        case Ok(shot) if Set.memberOf(shot#name, seen) => (seen, Err((shot#name, "同じ名前の場面が前にある")))
        case Ok(shot)                                  => (Set.insert(shot#name, seen), r)
        case Err(_)                                    => (seen, r)
    }

    def fromRoot(root: Map[String, Json]): Doc =
        Doc.Doc({ version = JsonCodec.intOr("version", 1, root),
                  shots = decodeRows(root) |> List.filterMap(r -> skipBroken(r)) })

    def skipBroken(r: Result[(String, String), Shot]): Option[Shot] = match r {
        case Ok(shot)             => Some(shot)
        case Err((which, reason)) => Log.fellBackThen("shots", "${path()} の ${which}", "その場面を飛ばす", reason, None)
    }

    /// i 番目（0 から）の行の場面。読めない時（欄の型の違いも）は (どの場面か, 理由)。
    def decodeShot(i: Int32, row: Json): Result[(String, String), Shot] =
        let which = "shots[${i}]";
        forM (
            obj     <- JsonCodec.expectObject(row) |> Option.toOk((which, "object でない"));
            name    <- stringAt("name", obj) |> Option.filter(n -> not String.isEmpty(n)) |> Option.toOk((which, "name が無い"));
            node    <- optional("node", JsonCodec.expectString, "文字列", obj) |> Result.mapErr(reason -> (name, reason));
            place   <- placeOf(obj) |> Result.mapErr(reason -> (name, reason));
            open    <- openOf(obj) |> Result.mapErr(reason -> (name, reason));
            vars    <- optional("vars", JsonCodec.decodeStringMap(scalarText), "名前 → 文字・数・真偽の object", obj) |> Result.mapErr(reason -> (name, reason));
            pointer <- optional("pointer", j -> JsonCodec.decodeList(JsonCodec.expectFloat, j) |> Option.flatMap(pointOf), "[x, y] の数 2 つ", obj) |> Result.mapErr(reason -> (name, reason));
            at      <- Map.get("at", obj) |> Option.flatMap(JsonCodec.expectFloat) |> Option.toOk((name, "at（時計を据える秒の数）が無い"))
        ) yield {
            name = name,
            node = node,
            place = place,
            vars = Option.getWithDefault(Map.empty(), vars),
            open = open,
            pointer = pointer,
            at = at
        }

    /// 無ければ None、有って decode が読めなければ「key は what で書く」。
    def optional(key: String, decode: Json -> Option[a], what: String, obj: Map[String, Json]): Result[String, Option[a]] =
        match Map.get(key, obj) {
            case None    => Ok(None)
            case Some(j) => decode(j) |> Option.map(Some) |> Option.toOk("${key} は ${what} で書く")
        }

    /// 変数の値の字（YarnStorage.withArgs が宣言の型で読み直す。数と真偽はそのまま字にする）。
    def scalarText(j: Json): Option[String] =
        match (JsonCodec.expectString(j), JsonCodec.expectBool(j), JsonCodec.expectFloat(j)) {
            case (Some(text), _, _)  => Some(text)
            case (_, Some(b), _)     => Some(if (b) "true" else "false")
            case (_, _, Some(x))     => Some(Float64.toString(x))
            case _                   => None
        }

    def stringAt(key: String, obj: Map[String, Json]): Option[String] = Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString)

    def pointOf(xs: List[Float64]): Option[Vec2.Vec2] = match xs {
        case x :: y :: Nil => Some({ x = x, y = y })
        case _             => None
    }

    def placeOf(obj: Map[String, Json]): Result[String, Place] =
        forM (
            say   <- optional("say", sayIndex, "0 以上の整数", obj);
            until <- optional("until", JsonCodec.expectString, "文字列", obj);
            place <- placeFrom(say, until)
        ) yield place

    def sayIndex(j: Json): Option[Int32] =
        JsonCodec.expectFloat(j) |> Option.filter(x -> x >= 0.0 and Float64.floor(x) == x) |> Option.flatMap(Float64.tryToInt32)

    def placeFrom(say: Option[Int32], until: Option[String]): Result[String, Place] = match (say, until) {
        case (Some(_), Some(_))      => Err("say と until は片方だけ書く")
        case (Some(n), None)         => Ok(Place.NthSay(n))
        case (None, Some("choices")) => Ok(Place.ToChoices)
        case (None, Some(other))     => Err("until の '${other}' を知らない（choices だけ）")
        case (None, None)            => Ok(Place.Head)
    }

    def openOf(obj: Map[String, Json]): Result[String, Option[Screen]] =
        forM (
            word   <- optional("open", JsonCodec.expectString, "文字列", obj);
            screen <- screenOfWord(word)
        ) yield screen

    def screenOfWord(word: Option[String]): Result[String, Option[Screen]] = match word {
        case None    => Ok(None)
        case Some(w) => screenOf(w) |> Option.map(Some) |> Option.toOk("open の '${w}' を知らない（${String.intercalate("・", screenWords())}）")
    }

    def screenWords(): List[String] = "title" :: "log" :: "save" :: "load" :: "settings" :: "ask" :: "credits" :: "hold" :: Nil

    def screenOf(word: String): Option[Screen] = match word {
        case "title"    => Some(Screen.Title)
        case "log"      => Some(Screen.Log)
        case "save"     => Some(Screen.Save)
        case "load"     => Some(Screen.Load)
        case "settings" => Some(Screen.Settings)
        case "ask"      => Some(Screen.Ask)
        case "credits"  => Some(Screen.Credits)
        case "hold"     => Some(Screen.Hold)
        case _          => None
    }

    /// path の Doc を読む。読めない・壊れているときは場面の無い defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
