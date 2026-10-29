// FoeMovesDoc — assets/rpg.foe_moves.json（敵の技の重みの list）の Doc 層。
// 1 行 = 1 体の敵の、ある phase で選ぶ技とその重み。技の効き目（式）はコードの Battle、ここは何をどれだけ選ぶかだけ。
// fail-open — 読めない行は飛ばして 1 行言う。行の無い敵は attack だけを選ぶ（FoeMovesDoc.movesOf が空を返し、Battle が attack にする）。
mod FoeMovesDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 敵の技。Attack = 1 人を叩く / Sweep = 生きている仲間全員を ちから × 0.6 で叩く / Guard = その手番のうちに受けるダメージを半分にする /
    /// Sleep = 仲間 1 人を眠らせる（成功率は rules の sleepRate）/ Spell = rpg.spells.json の呪文（鍵）を唱える（MP は使わない）。
    /// WhyNot: 呪文ごとに case（fire / ice）を作らない — 敵に呪文を 1 つ持たせるたびにコードを足すことになる。鍵は Res.problemsOf が確かめる。
    pub enum Act with Eq, ToString {
        case Attack
        case Sweep
        case Guard
        case Sleep
        case Spell(String)
    }

    /// 技の名前（と spell の欄）→ 技（Doc の act の語彙）。spell は呪文の鍵が無ければ読めない。
    def actOf(name: String, spell: String): Option[Act] = match name {
        case "attack"                        => Some(Act.Attack)
        case "sweep"                         => Some(Act.Sweep)
        case "guard"                         => Some(Act.Guard)
        case "sleep"                         => Some(Act.Sleep)
        case "spell" if not String.isEmpty(spell) => Some(Act.Spell(spell))
        case _                               => None
    }

    /// 書ける技の名前。
    def actNames(): List[String] = "attack" :: "sweep" :: "guard" :: "sleep" :: "spell" :: Nil

    /// 呪文を唱える技なら、その呪文の鍵。
    pub def spellKeyOf(act: Act): Option[String] = match act {
        case Act.Spell(key) => Some(key)
        case _              => None
    }

    /// 1 行。foe = rpg.foes.json の鍵、phase = 1 か 2（2 は HP が phase2At を切った後）、weight = 選ぶ重み。
    pub type alias Move = { foe = String, phase = Int32, act = Act, weight = Int32 }

    /// moves = 行の並び、problems = 読む時に飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, moves = List[Move], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum FoeMovesDocOf(Rec)

    pub type alias Doc = FoeMovesDocOf

    pub def rec(d: Doc): Rec = match d { case FoeMovesDocOf.FoeMovesDocOf(r) => r }

    pub def path(): String = "assets/rpg.foe_moves.json"

    def defaults(): Doc = FoeMovesDocOf.FoeMovesDocOf({ version = 1, moves = Nil, problems = Nil })

    /// foe の phase の技と重み（行の順）。
    pub def movesOf(d: Doc, foe: String, phase: Int32): List[(Act, Int32)] =
        rec(d)#moves |> List.filter(m -> m#foe == foe and m#phase == phase) |> List.map(m -> (m#act, m#weight))

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rows = Map.get("moves", root) |> Option.flatMap(JsonCodec.decodeList(json -> Some(json))) |> Option.getWithDefault(Nil);
        let decoded = rows |> List.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(moveRowOf));
        let problems = decoded |> List.zipWithIndex |> List.filterMap(match (i, row) ->
            if (Option.isEmpty(row)) Some("[foe_moves] ${i + 1} 行目を読めない（foe が無いか、act が ${actNames() |> List.join(" / ")} でないか、spell の行に呪文が無い）ので飛ばす") else None);
        FoeMovesDocOf.FoeMovesDocOf({ version = JsonCodec.intOr("version", rec(defaults())#version, root),
                  moves = decoded |> List.filterMap(x -> x), problems = problems })

    def moveRowOf(obj: Map[String, Json]): Option[Move] =
        forM (
            foe <- Map.get("foe", obj) |> Option.flatMap(JsonCodec.expectString);
            act <- Map.get("act", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.flatMap(name -> actOf(name, JsonCodec.stringOr("spell", "", obj)))
        ) yield { foe = foe, phase = JsonCodec.intOr("phase", 1, obj), act = act, weight = JsonCodec.intOr("weight", 1, obj) }

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
