// ItemsDoc — assets/rpg.items.json（道具の catalog）の Doc 層と、道具を指す名前（ItemId）。
// 効き目の決まり（誰に使えるか・装備の付け替え・売値）はコード。ここは道具の名前と数だけ。
// fail-open — 読めない・壊れているときは道具の無い表で続け、読めない行は飛ばして 1 行言う。
mod ItemsDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 道具を指す名前。作れるのは idOf（Doc の catalog にある鍵）だけ。
    enum ItemKey with Eq, Order, ToString {
        case Key(String)
    }
    pub type alias ItemId = ItemKey

    /// 道具の種類。Use = 使う物 / Weapon・Armor = 装備（ぶき・よろい）/ Key = だいじなもの（使えない・売れない）。
    pub enum Kind with Eq, ToString {
        case Use
        case Weapon
        case Armor
        case Key
    }

    /// 道具 1 つ。name = 画面に出す名前、price = 店の値段（売値はその半分）、heal / mpHeal = 使うと戻る HP / MP、
    /// atk / def = 装備した時に足す ちから / みのまもり、equip = 装備できる仲間、
    /// lightSteps = 暗いマップでフィールドで使うと明かりが続く歩数（0 なら明かりにならない）、burn = 戦いで使うと敵 1 体に与えるダメージ（戦いの道具は P6）。
    pub type alias Item = { name = String, kind = Kind, price = Int32, heal = Int32, mpHeal = Int32,
                            atk = Int32, defense = Int32, equip = Set[Member.Member], lightSteps = Int32, burn = Int32 }

    /// items = 鍵 → 道具、problems = 読む時に飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, items = Map[String, Item], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum ItemsDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = ItemsDocOf

    pub def rec(d: Doc): Rec = match d { case ItemsDocOf.ItemsDocOf(r) => r }

    pub def path(): String = "assets/rpg.items.json"

    pub def defaults(): Doc = ItemsDocOf.ItemsDocOf({ version = 1, items = Map.empty(), problems = Nil })

    /// catalog にある鍵なら ItemId。
    pub def idOf(d: Doc, name: String): Option[ItemId] =
        if (Map.memberOf(name, rec(d)#items)) Some(ItemKey.Key(name)) else None

    /// ItemId の鍵（セーブに書く名前）。
    pub def keyOf(id: ItemId): String = match id { case ItemKey.Key(name) => name }

    /// 道具の値（読み直しで Doc から消えた道具は None）。
    pub def itemOf(d: Doc, id: ItemId): Option[Item] = Map.get(keyOf(id), rec(d)#items)

    /// 画面に出す名前（Doc から消えた道具は鍵のまま）。
    pub def nameOf(d: Doc, id: ItemId): String = itemOf(d, id) |> Option.map(item -> item#name) |> Option.getWithDefault(keyOf(id))

    /// だいじなもの（kind = key）の一覧（鍵の名前の順）。会話の変数 $has_<鍵> はこの並び。
    pub def keyItemsOf(d: Doc): List[ItemId] =
        rec(d)#items |> Map.toList |> List.filter(pair -> snd(pair)#kind == Kind.Key) |> List.map(pair -> ItemKey.Key(fst(pair)))

    /// catalog の鍵の一覧（名前の順）。
    pub def keysOf(d: Doc): List[String] = rec(d)#items |> Map.keysOf |> Set.toList

    /// Doc の kind の名前 → 種類。
    def kindOf(name: String): Option[Kind] = match name {
        case "use"    => Some(Kind.Use)
        case "weapon" => Some(Kind.Weapon)
        case "armor"  => Some(Kind.Armor)
        case "key"    => Some(Kind.Key)
        case _        => None
    }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rows = Map.get("items", root) |> Option.flatMap(JsonCodec.decodeStringMap(json -> Some(json))) |> Option.getWithDefault(Map.empty());
        let decoded = rows |> Map.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(itemRowOf));
        let problems = decoded |> Map.toList |> List.filterMap(match (key, row) ->
            if (Option.isEmpty(row)) Some("[items] '${key}' の行を読めない（name が無いか kind が use / weapon / armor / key でない）ので飛ばす") else None);
        ItemsDocOf.ItemsDocOf({ version = JsonCodec.intOr("version", rec(defaults())#version, root),
                  items = decoded |> Map.filterMap(x -> x), problems = problems })

    /// 1 行（name が無い・kind を読めない行は None）。数の欄は省けば 0、装備できる仲間は省けば誰も付けられない。
    def itemRowOf(obj: Map[String, Json]): Option[Item] =
        forM (
            name <- Map.get("name", obj) |> Option.flatMap(JsonCodec.expectString);
            kind <- kindOf(JsonCodec.stringOr("kind", "use", obj))
        ) yield {
            name = name, kind = kind, price = JsonCodec.intOr("price", 0, obj),
            heal = JsonCodec.intOr("heal", 0, obj), mpHeal = JsonCodec.intOr("mpHeal", 0, obj),
            atk = JsonCodec.intOr("atk", 0, obj), defense = JsonCodec.intOr("def", 0, obj),
            equip = Member.all() |> List.filter(m -> JsonCodec.boolOr(Member.idOf(m), false, obj)) |> List.toSet,
            lightSteps = JsonCodec.intOr("lightSteps", 0, obj),
            burn = JsonCodec.intOr("burn", 0, obj)
        }

    /// path の Doc を読む。読めない・壊れているときは道具の無い表。飛ばした行は problems に残す（Res.problemsOf が言う）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
