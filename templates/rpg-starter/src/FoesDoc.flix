// FoesDoc — assets/rpg.foes.json（敵の catalog）の Doc 層と、敵を指す名前（FoeId）。
// 戦いの式（ダメージ・行動順・にげる）はコードの Battle。ここは敵ごとの数と絵の名前だけ。技の重みは FoeMovesDoc、色違いの色は RecolorsDoc。
// fail-open — 読めない・壊れているときは敵の無い表で続け、読めない行は飛ばして 1 行言う。
mod FoesDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 敵を指す名前。作れるのは idOf（Doc の catalog にある鍵）だけ。
    enum FoeKey with Eq, Order, ToString {
        case Key(String)
    }
    pub type alias FoeId = FoeKey

    /// 敵 1 体。name = 画面に出す名前、sprite = rpg.monsters.sprite.json の絵の名前、recolor = 色違いの名前（rpg.recolors.json の鍵。空なら元の色）、
    /// width / height = 絵が無い時の仮の四角の大きさ（px）、lift = 足元を地面の線から上げる高さ（px。飛ぶ物）、
    /// lv = つり合いの目安と、せいすいで飛ばすかの比べ（戦いの式は使わない）、hp / atk / defense / agi = 最大 HP・ちから・みのまもり・すばやさ、
    /// exp / gold = 倒した時の経験値とお金、noFlee = 逃げられない、phase2At = HP の割合がこれを切ると技を phase 2 の行へ替える（0 なら替えない）。
    pub type alias Foe = { name = String, sprite = String, recolor = String, width = Int32, height = Int32, lift = Int32,
                           lv = Int32, hp = Int32, atk = Int32, defense = Int32, agi = Int32, exp = Int32, gold = Int32,
                           noFlee = Bool, phase2At = Float64 }

    /// foes = 鍵 → 敵、problems = 読む時に飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, foes = Map[String, Foe], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum FoesDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = FoesDocOf

    pub def rec(d: Doc): Rec = match d { case FoesDocOf.FoesDocOf(r) => r }

    pub def path(): String = "assets/rpg.foes.json"

    def defaults(): Doc = FoesDocOf.FoesDocOf({ version = 1, foes = Map.empty(), problems = Nil })

    /// catalog にある鍵なら FoeId。
    pub def idOf(d: Doc, name: String): Option[FoeId] =
        if (Map.memberOf(name, rec(d)#foes)) Some(FoeKey.Key(name)) else None

    /// FoeId の鍵。
    pub def keyOf(id: FoeId): String = match id { case FoeKey.Key(name) => name }

    /// 敵の値（読み直しで Doc から消えた敵は None）。
    pub def foeOf(d: Doc, id: FoeId): Option[Foe] = Map.get(keyOf(id), rec(d)#foes)

    /// 敵の値。Doc から消えた敵は「鍵の名前・HP 1・ほかは 0」の値（戦いの途中で読み直しても止めない）。
    pub def foeOrBlank(d: Doc, id: FoeId): Foe =
        foeOf(d, id) |> Option.getWithDefault({ name = keyOf(id), sprite = "", recolor = "", width = 32, height = 32, lift = 0,
                                                lv = 1, hp = 1, atk = 0, defense = 0, agi = 0, exp = 0, gold = 0,
                                                noFlee = false, phase2At = 0.0 })

    /// catalog の鍵の一覧（名前の順）。
    pub def keysOf(d: Doc): List[String] = rec(d)#foes |> Map.keysOf |> Set.toList

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rows = Map.get("foes", root) |> Option.flatMap(JsonCodec.decodeStringMap(json -> Some(json))) |> Option.getWithDefault(Map.empty());
        let decoded = rows |> Map.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(foeRowOf));
        let problems = decoded |> Map.toList |> List.filterMap(match (key, row) ->
            if (Option.isEmpty(row)) Some("[foes] '${key}' の行を読めない（name か sprite が無いか、hp が 1 より小さい）ので飛ばす") else None);
        FoesDocOf.FoesDocOf({ version = JsonCodec.intOr("version", rec(defaults())#version, root),
                  foes = decoded |> Map.filterMap(x -> x), problems = problems })

    /// 1 行（name・sprite が無い・hp が 1 より小さい行は None）。数の欄は省けば 0（width / height は 32）。
    def foeRowOf(obj: Map[String, Json]): Option[Foe] =
        forM (
            name <- Map.get("name", obj) |> Option.flatMap(JsonCodec.expectString);
            sprite <- Map.get("sprite", obj) |> Option.flatMap(JsonCodec.expectString);
            hp <- Some(JsonCodec.intOr("hp", 0, obj)) |> Option.filter(n -> n >= 1)
        ) yield {
            name = name, sprite = sprite, recolor = JsonCodec.stringOr("recolor", "", obj),
            width = JsonCodec.intOr("width", 32, obj), height = JsonCodec.intOr("height", 32, obj), lift = JsonCodec.intOr("lift", 0, obj),
            lv = JsonCodec.intOr("lv", 1, obj), hp = hp, atk = JsonCodec.intOr("atk", 0, obj), defense = JsonCodec.intOr("def", 0, obj),
            agi = JsonCodec.intOr("agi", 0, obj), exp = JsonCodec.intOr("exp", 0, obj), gold = JsonCodec.intOr("gold", 0, obj),
            noFlee = JsonCodec.boolOr("noFlee", false, obj), phase2At = JsonCodec.floatOr("phase2At", 0.0, obj)
        }

    /// path の Doc を読む。読めない・壊れているときは敵の無い表。飛ばした行は problems に残す（Res.problemsOf が言う）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
