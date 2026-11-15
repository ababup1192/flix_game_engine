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
    pub def rowsOf(text: String): Option[List[Result[(String, String), Shot]]] =
        DocJson.decodeObject(decodeRows, text)

    def decodeRows(root: Map[String, Json]): List[Result[(String, String), Shot]] =
        Map.get("shots", root) |> Option.flatMap(JsonCodec.decodeList(Some)) |> Option.getWithDefault(Nil)
            |> List.mapWithIndex((i, row) -> decodeShot(i, row))

    def fromRoot(root: Map[String, Json]): Doc =
        Doc.Doc({ version = JsonCodec.intOr("version", 1, root),
                  shots = decodeRows(root) |> List.filterMap(r -> skipBroken(r)) })

    def skipBroken(r: Result[(String, String), Shot]): Option[Shot] = match r {
        case Ok(shot)             => Some(shot)
        case Err((which, reason)) => Log.fellBackThen("shots", "${path()} の ${which}", "その場面を飛ばす", reason, None)
    }

    /// i 番目（0 から）の行の場面。読めない時は (どの場面か, 理由)。
    def decodeShot(i: Int32, row: Json): Result[(String, String), Shot] =
        let which = "shots[${i}]";
        forM (
            obj    <- JsonCodec.expectObject(row) |> Option.toOk((which, "object でない"));
            name   <- stringAt("name", obj) |> Option.filter(n -> not String.isEmpty(n)) |> Option.toOk((which, "name が無い"));
            place  <- placeOf(obj) |> Result.mapErr(reason -> (name, reason));
            open   <- openOf(obj) |> Result.mapErr(reason -> (name, reason))
        ) yield {
            name = name,
            node = stringAt("node", obj),
            place = place,
            vars = Map.get("vars", obj) |> Option.flatMap(JsonCodec.decodeStringMap(JsonCodec.expectString)) |> Option.getWithDefault(Map.empty()),
            open = open,
            pointer = Map.get("pointer", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.flatMap(pointOf),
            at = JsonCodec.floatOr("at", 0.0, obj)
        }

    def stringAt(key: String, obj: Map[String, Json]): Option[String] = Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString)

    def pointOf(xs: List[Float64]): Option[Vec2.Vec2] = match xs {
        case x :: y :: Nil => Some({ x = x, y = y })
        case _             => None
    }

    def placeOf(obj: Map[String, Json]): Result[String, Place] =
        let say = Map.get("say", obj) |> Option.flatMap(JsonCodec.expectInt);
        match (say, stringAt("until", obj)) {
            case (Some(_), Some(_))         => Err("say と until は片方だけ書く")
            case (Some(n), None)            => Ok(Place.NthSay(n))
            case (None, Some("choices"))    => Ok(Place.ToChoices)
            case (None, Some(other))        => Err("until の '${other}' を知らない（choices だけ）")
            case (None, None)               => Ok(Place.Head)
        }

    def openOf(obj: Map[String, Json]): Result[String, Option[Screen]] = match stringAt("open", obj) {
        case None         => Ok(None)
        case Some(word)   => screenOf(word) |> Option.map(Some) |> Option.toOk("open の '${word}' を知らない（${String.intercalate("・", screenWords())}）")
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
