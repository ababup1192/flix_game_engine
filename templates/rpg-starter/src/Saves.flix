// Saves — セーブ（1 枠・saves/rune.json）の中身と読み書き。
// 中身は場面をまたぐ遊びの値だけ（仲間・ふくろ・進み具合（依頼の段階・開けた物・名前付きの旗）・乱数の回数）。位置は書かない（再開は宿の前 = rules の home）。
// 読むのは起動の 1 回（Main）、書くのは App.addOutput が「saveRev が変わった実機のフレームの後」でだけ
// （テスト・flow・描き出しでは書かない）。
mod Saves {
    use fge::{DocJson, JsonCodec, Log}
    use Util.Json.Json

    /// セーブの中身。
    pub type alias Rec = { party = Party.Party, bag = Bag.Bag, progress = Progress.Progress, dice = Int32 }

    /// WhyNot: World に record のまま持たない — World を取る全 def の型に中身が展開されて大きくなる。
    enum SaveOf(Rec)

    /// セーブの中身（作るのは of と fromJson だけ）。
    pub type alias SaveData = SaveOf

    pub def of(r: Rec): SaveData = SaveOf.SaveOf(r)

    pub def rec(s: SaveData): Rec = match s { case SaveOf.SaveOf(r) => r }

    def path(): String = "saves/rune.json"

    /// 書く形の版。違う版のファイルは読まない（壊れたのと同じ扱い）。
    def version(): Int32 = 4

    // ── JSON ──

    def toJson(s: SaveData): Json =
        let r = rec(s);
        let int = n -> Json.JNumber(JsonCodec.intToBd(n));
        let itemKey = item -> Json.JString(item |> Option.map(ItemsDoc.keyOf) |> Option.getWithDefault(""));
        let member = row -> {
            let (m, stats) = row;
            Json.JObject(Map#{ "member" => Json.JString(Member.idOf(m)), "lv" => int(stats#lv), "exp" => int(stats#exp), "hp" => int(stats#hp),
                               "mp" => int(stats#mp), "weapon" => itemKey(stats#weapon), "armor" => itemKey(stats#armor) })
        };
        Json.JObject(Map#{
            "version" => int(version()),
            "party" => Json.JArray(Party.statsList(r#party) |> List.map(member) |> List.toVector),
            "gold" => int(Bag.goldOf(r#bag)),
            "items" => Json.JObject(Bag.itemsOf(r#bag) |> List.map(match (id, n) -> (ItemsDoc.keyOf(id), int(n))) |> List.toMap),
            "quest" => Json.JString(Progress.nameOf(Progress.rec(r#progress)#quest)),
            "opened" => Json.JArray(Progress.rec(r#progress)#opened |> Set.toList
                |> List.map(match (map, id) -> Json.JObject(Map#{ "map" => Json.JString(MapDoc.nameOf(map)), "id" => Json.JString(id) }))
                |> List.toVector),
            "flags" => Json.JArray(Progress.flagsOf(r#progress) |> Set.toList |> List.map(flag -> Json.JString(Flag.nameOf(flag))) |> List.toVector),
            "dice" => int(r#dice)
        })

    /// JSON から。形が違えば理由を返す。道具の Doc に無い道具・マップの表に無いマップの旗（読み直しで消えた物）は捨てて続ける。
    def fromJson(items: ItemsDoc.Doc, maps: MapDoc.Table, json: Json): Result[String, SaveData] =
        forM (
            root <- JsonCodec.expectObject(json) |> Option.toOk("JSON の object でない");
            _ <- if (JsonCodec.intOr("version", 0, root) == version()) Ok(()) else Err("版が ${version()} でない");
            rows <- Map.get("party", root) |> Option.flatMap(JsonCodec.decodeList(json1 -> Some(json1))) |> Option.toOk("party が無い");
            party <- rows |> List.map(memberOf(items)) |> List.sequence;
            _ <- if (List.isEmpty(party)) Err("party が空") else Ok(());
            quest <- Progress.questOf(JsonCodec.stringOr("quest", "", root)) |> Option.toOk("quest を読めない")
        ) yield {
            let counts = Map.get("items", root) |> Option.flatMap(JsonCodec.decodeStringMap(JsonCodec.expectInt)) |> Option.getWithDefault(Map.empty())
                |> Map.toList |> List.filterMap(match (key, n) -> ItemsDoc.idOf(items, key) |> Option.map(id -> (id, n))) |> List.toMap;
            let opened = Map.get("opened", root) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectObject)) |> Option.getWithDefault(Nil)
                |> List.filterMap(row -> forM (name <- Map.get("map", row) |> Option.flatMap(JsonCodec.expectString);
                                               map <- MapDoc.idOf(maps, name);
                                               id <- Map.get("id", row) |> Option.flatMap(JsonCodec.expectString)) yield (map, id));
            let flags = Map.get("flags", root) |> Option.flatMap(JsonCodec.decodeList(json1 -> Some(json1))) |> Option.getWithDefault(Nil)
                |> List.filterMap(Flag.fromJson);
            let progress = opened |> List.foldLeft((p, pair) -> Progress.markOpened(fst(pair), snd(pair), p), Progress.withQuest(quest, Progress.initial()))
                |> (p -> flags |> List.foldLeft((acc, flag) -> Progress.withFlag(flag, true, acc), p));
            of({ party = Party.ofStats(party), bag = Bag.of(counts, JsonCodec.intOr("gold", 0, root)),
                 progress = progress, dice = JsonCodec.intOr("dice", 0, root) })
        }

    def memberOf(items: ItemsDoc.Doc, json: Json): Result[String, (Member.Member, Party.Stats)] =
        forM (
            obj <- JsonCodec.expectObject(json) |> Option.toOk("party の行が object でない");
            m <- Member.memberOf(JsonCodec.stringOr("member", "", obj)) |> Option.toOk("party の行の member を読めない")
        ) yield {
            let item = key -> ItemsDoc.idOf(items, JsonCodec.stringOr(key, "", obj));
            (m, { lv = JsonCodec.intOr("lv", 1, obj), exp = JsonCodec.intOr("exp", 0, obj), hp = JsonCodec.intOr("hp", 0, obj), mp = JsonCodec.intOr("mp", 0, obj),
                  weapon = item("weapon"), armor = item("armor") })
        }

    /// 書く字（読みやすく字下げ）。
    pub def toText(s: SaveData): String = Util.Json.toPrettyString(2, toJson(s))

    /// 字から（JSON でない・形が違えば理由）。
    pub def fromText(items: ItemsDoc.Doc, maps: MapDoc.Table, text: String): Result[String, SaveData] =
        DocJson.parse(text) |> Option.toOk("JSON を読めない") |> Result.flatMap(fromJson(items, maps))

    // ── 読み書き ──

    /// 起動の 1 回: 無ければ None（初めて遊ぶ時）。有るのに読めなければ None にして 1 行言う（「つづきから」は灰色）。
    pub def load(items: ItemsDoc.Doc, maps: MapDoc.Table): Option[SaveData] \ Fs.FileRead =
        Fs.FileRead.read(path()) |> Result.toOption |> Option.flatMap(text -> readOrSay(fromText(items, maps, text)))

    def readOrSay(read: Result[String, SaveData]): Option[SaveData] = match read {
        case Ok(s)       => Some(s)
        case Err(reason) => Log.warnThen("[saves] ${path()} を読めない（${reason}）。「つづきから」は選べない", None)
    }

    /// 書く（App.addOutput の write）。書けない時は 1 行知らせて続ける（遊びは止めない）。
    pub def write(s: SaveData): Unit \ Fs.FileWrite =
        let done = forM (
            _ <- Fs.FileWrite.mkDirs("saves");
            _ <- Fs.FileWrite.write({ str = toText(s) }, path())
        ) yield ();
        match done {
            case Ok(_)  => ()
            case Err(e) => Log.warn("[saves] 書けない: ${path()} (${e})")
        }
}
