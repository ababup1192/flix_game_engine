// SpellsDoc — assets/rpg.spells.json（呪文の catalog）の Doc 層と、呪文を指す名前（SpellId）。
// 効き目の式（ぶれ・まもりを見ない・最大 HP で止める）はコードの Battle。ここは呪文ごとの数と的と絵の名前だけ。
// 誰がどの Lv で覚えるかは rpg.party.json の learns。敵が唱える呪文は rpg.foe_moves.json の act = spell の行の spell。
// fail-open — 読めない・壊れているときは呪文の無い表で続け、読めない行は飛ばして 1 行言う。
mod SpellsDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 呪文を指す名前。作れるのは idOf（Doc の catalog にある鍵）だけ。
    enum SpellKey with Eq, Order, ToString {
        case Key(String)
    }
    pub type alias SpellId = SpellKey

    /// 呪文の的。Foe = 敵 1 体にダメージ / AllFoes = 生きている敵全部にダメージ / Ally = 仲間 1 人の HP を戻す。
    pub enum Aim with Eq, ToString {
        case Foe
        case AllFoes
        case Ally
    }

    /// 呪文 1 つ。name = 画面に出す名前、mp = 唱えるのに使う MP、power = ダメージか戻す HP の真ん中（ぶれは Battle）、
    /// aim = 的、field = フィールドのメニューの じゅもん でも唱えられるか、fx = 戦いの演出の絵（rpg.battlefx.sprite.json の名前）。
    pub type alias Spell = { name = String, mp = Int32, power = Int32, aim = Aim, field = Bool, fx = String }

    /// spells = 鍵 → 呪文、problems = 読む時に飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, spells = Map[String, Spell], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum SpellsDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = SpellsDocOf

    pub def rec(d: Doc): Rec = match d { case SpellsDocOf.SpellsDocOf(r) => r }

    pub def path(): String = "assets/rpg.spells.json"

    def defaults(): Doc = SpellsDocOf.SpellsDocOf({ version = 1, spells = Map.empty(), problems = Nil })

    /// catalog にある鍵なら SpellId。
    pub def idOf(d: Doc, name: String): Option[SpellId] =
        if (Map.memberOf(name, rec(d)#spells)) Some(SpellKey.Key(name)) else None

    /// SpellId の鍵。
    def keyOf(id: SpellId): String = match id { case SpellKey.Key(name) => name }

    /// 呪文の値（読み直しで Doc から消えた呪文は None）。
    pub def spellOf(d: Doc, id: SpellId): Option[Spell] = Map.get(keyOf(id), rec(d)#spells)

    /// 画面に出す名前（Doc から消えた呪文は鍵のまま）。
    pub def nameOf(d: Doc, id: SpellId): String = spellOf(d, id) |> Option.map(s -> s#name) |> Option.getWithDefault(keyOf(id))

    /// catalog の鍵の一覧（名前の順）。
    pub def keysOf(d: Doc): List[String] = rec(d)#spells |> Map.keysOf |> Set.toList

    /// Doc の aim の名前 → 的。
    def aimOf(name: String): Option[Aim] = match name {
        case "foe"     => Some(Aim.Foe)
        case "allFoes" => Some(Aim.AllFoes)
        case "ally"    => Some(Aim.Ally)
        case _         => None
    }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rows = Map.get("spells", root) |> Option.flatMap(JsonCodec.decodeStringMap(json -> Some(json))) |> Option.getWithDefault(Map.empty());
        let decoded = rows |> Map.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(spellRowOf));
        let problems = decoded |> Map.toList |> List.filterMap(match (key, row) ->
            if (Option.isEmpty(row)) Some("[spells] '${key}' の行を読めない（name が無いか aim が foe / allFoes / ally でない）ので飛ばす") else None);
        SpellsDocOf.SpellsDocOf({ version = JsonCodec.intOr("version", rec(defaults())#version, root),
                  spells = decoded |> Map.filterMap(x -> x), problems = problems })

    /// 1 行（name が無い・aim を読めない行は None）。数の欄は省けば 0、field は省けば戦いだけ、fx は省けば当たりの絵。
    def spellRowOf(obj: Map[String, Json]): Option[Spell] =
        forM (
            name <- Map.get("name", obj) |> Option.flatMap(JsonCodec.expectString);
            aim <- aimOf(JsonCodec.stringOr("aim", "foe", obj))
        ) yield {
            name = name, mp = Int32.max(0, JsonCodec.intOr("mp", 0, obj)), power = Int32.max(0, JsonCodec.intOr("power", 0, obj)),
            aim = aim, field = JsonCodec.boolOr("field", false, obj), fx = JsonCodec.stringOr("fx", "hit", obj)
        }

    /// path の Doc を読む。読めない・壊れているときは呪文の無い表。飛ばした行は problems に残す（Res.problemsOf が言う）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
