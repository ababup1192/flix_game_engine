// PartyDoc — assets/rpg.party.json（仲間ごとの値の catalog。鍵は Member.idOf の名前）の Doc 層。
// 顔ぶれ（誰がいるか）はコードの Member.Member。ここは仲間ごとの値だけ。
// fail-open — 読めない・欠けた行は、その仲間だけコードの既定の値で出す。
mod PartyDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 仲間 1 人の値。name = 画面に出す名前、sprite = フィールドで描く rpg.chars.sprite.json の絵の名前、
    /// placeholder = 絵が無い時の仮の四角の色（色票の鍵。誰がどこにいるか見分ける）、
    /// hp / mp / atk / defense / agi = Lv1 の最大 HP・最大 MP・ちから・みのまもり・すばやさ（装備を除く。Doc の欄は def）、
    /// weapon / armor = 加わった時に付けている物（rpg.items.json の鍵。空なら何も付けない）、joinLv = 加わった時の Lv、
    /// hpUp / mpUp / atkUp / defUp / agiUp = 1 Lv ごとの伸び（Lv1 の値に (Lv − 1) 回足す）。
    pub type alias Member = { name = String, sprite = String, placeholder = String, joinLv = Int32,
                              hp = Int32, mp = Int32, atk = Int32, defense = Int32, agi = Int32,
                              hpUp = Int32, mpUp = Int32, atkUp = Int32, defUp = Int32, agiUp = Int32,
                              weapon = String, armor = String }

    /// 呪文を覚える行。member が lv に着くと spell（rpg.spells.json の鍵）を唱えられる。
    pub type alias Learn = { member = Member.Member, spell = String, lv = Int32 }

    /// members = 仲間の名前 → 値、exp = Lv ごとの経験値の累計（Lv2 から。並びは Lv の順）、
    /// learns = 呪文を覚える行（Doc の並びの順）、problems = 読めずに飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, members = Map[String, Member], exp = List[(Int32, Int32)], learns = List[Learn], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum PartyDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = PartyDocOf

    pub def rec(d: Doc): Rec = match d { case PartyDocOf.PartyDocOf(r) => r }

    pub def path(): String = "assets/rpg.party.json"

    def defaults(): Doc = PartyDocOf.PartyDocOf({ version = 1, members = Map.empty(), exp = expDefaults(), learns = Nil, problems = Nil })

    /// m が lv までに覚える呪文の鍵（Doc の並びの順）。
    pub def spellKeysAt(m: Member.Member, lv: Int32, d: Doc): List[String] =
        rec(d)#learns |> List.filter(row -> row#member == m and row#lv <= lv) |> List.map(row -> row#spell)

    /// m が ちょうど lv で覚える呪文の鍵（レベルアップの伝言）。
    pub def spellKeysLearnedAt(m: Member.Member, lv: Int32, d: Doc): List[String] =
        rec(d)#learns |> List.filter(row -> row#member == m and row#lv == lv) |> List.map(row -> row#spell)

    /// Lv ごとの経験値の累計のコードの既定（Doc に exp の行が無い時）。
    def expDefaults(): List[(Int32, Int32)] =
        (2, 12) :: (3, 35) :: (4, 75) :: (5, 140) :: (6, 240) :: (7, 420) :: (8, 600) :: (9, 820) :: (10, 1100) :: Nil

    /// Lv の上限（経験値の表の一番上の Lv。表が空なら 1）。
    pub def maxLvOf(d: Doc): Int32 = rec(d)#exp |> List.map(fst) |> List.maximum |> Option.getWithDefault(1)

    /// その Lv に着くのに要る経験値の累計（Lv1 は 0。表に無い Lv は表の上限の値）。
    pub def expFor(lv: Int32, d: Doc): Int32 =
        if (lv <= 1) 0
        else rec(d)#exp |> List.filter(row -> fst(row) <= lv) |> List.map(snd) |> List.maximum |> Option.getWithDefault(0)

    /// 経験値の累計 total で着く Lv（表の上限で止める）。
    pub def lvFor(total: Int32, d: Doc): Int32 =
        rec(d)#exp |> List.filter(row -> snd(row) <= total) |> List.map(fst) |> List.maximum |> Option.getWithDefault(1) |> Int32.max(1)

    /// コードの既定の値（Doc に行が無い仲間）。
    def memberDefaultOf(m: Member.Member): Member = match m {
        case Member.Member.Luka => { name = "ルカ", sprite = "hero", placeholder = "fc12", joinLv = 1,
                                     hp = 28, mp = 6, atk = 11, defense = 6, agi = 8,
                                     hpUp = 6, mpUp = 2, atkUp = 3, defUp = 2, agiUp = 2, weapon = "hinoki", armor = "tabibito" }
        case Member.Member.Mina => { name = "ミナ", sprite = "mina", placeholder = "fc27", joinLv = 1,
                                     hp = 34, mp = 0, atk = 13, defense = 8, agi = 5,
                                     hpUp = 7, mpUp = 0, atkUp = 3, defUp = 2, agiUp = 1, weapon = "tsuruhashi", armor = "tabibito" }
        case Member.Member.Toto => { name = "トト", sprite = "toto", placeholder = "fc14", joinLv = 2,
                                     hp = 18, mp = 12, atk = 6, defense = 4, agi = 10,
                                     hpUp = 4, mpUp = 4, atkUp = 1, defUp = 1, agiUp = 2, weapon = "kashinotsue", armor = "robe" }
    }

    /// 仲間の値（Doc に行が無ければコードの既定）。
    pub def memberOf(m: Member.Member, d: Doc): Member =
        Map.get(Member.idOf(m), rec(d)#members) |> Option.getWithDefault(memberDefaultOf(m))

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rows = Map.get("members", root) |> Option.flatMap(JsonCodec.decodeStringMap(json -> Some(json))) |> Option.getWithDefault(Map.empty());
        let decoded = rows |> Map.mapWithKey(memberRowOf);
        let problems = decoded |> Map.toList |> List.filterMap(match (key, row) ->
            if (Option.isEmpty(row)) Some("[party] '${key}' の行を読めない（知らない仲間か sprite が無い）ので既定の値で出す") else None);
        let (exp, expProblems) = expTableOf(root);
        let (learns, learnProblems) = learnsOf(root);
        PartyDocOf.PartyDocOf({ version = JsonCodec.intOr("version", rec(defaults())#version, root),
                  members = decoded |> Map.filterMap(x -> x), exp = exp, learns = learns,
                  problems = List.flatten(problems :: expProblems :: learnProblems :: Nil) })

    /// learns の list（{member, spell, lv}）。無ければ誰も覚えない。読めない行（知らない仲間・spell が無い）は飛ばして 1 行ずつ言う。
    def learnsOf(root: Map[String, Json]): (List[Learn], List[String]) =
        let read = Map.get("learns", root) |> Option.flatMap(JsonCodec.decodeList(json -> Some(json))) |> Option.getWithDefault(Nil)
            |> List.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(obj ->
                forM (member <- Map.get("member", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.flatMap(Member.memberOf);
                      spell <- Map.get("spell", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.filter(s -> not String.isEmpty(s)))
                yield { member = member, spell = spell, lv = JsonCodec.intOr("lv", 1, obj) }));
        let bad = read |> List.filter(Option.isEmpty) |> List.map(_ -> "[party] learns の行を読めない（member が仲間の名前でないか spell が無い）ので飛ばす");
        (read |> List.filterMap(x -> x), bad)

    /// exp の list（{lv, total}）。無ければコードの既定。読めない行は飛ばして 1 行ずつ言う。並びは Lv の順に直す。
    def expTableOf(root: Map[String, Json]): (List[(Int32, Int32)], List[String]) =
        match Map.get("exp", root) |> Option.flatMap(JsonCodec.decodeList(json -> Some(json))) {
            case None       => (expDefaults(), Nil)
            case Some(rows) =>
                let read = rows |> List.map(json -> JsonCodec.expectObject(json) |> Option.flatMap(obj ->
                    forM (lv <- Map.get("lv", obj) |> Option.flatMap(JsonCodec.expectInt);
                          total <- Map.get("total", obj) |> Option.flatMap(JsonCodec.expectInt)) yield (lv, total)));
                let good = read |> List.filterMap(x -> x) |> List.sortBy(fst);
                let bad = read |> List.filter(Option.isEmpty) |> List.map(_ -> "[party] exp の行を読めない（lv と total の数）ので飛ばす");
                (good, bad)
        }

    /// 1 行（sprite が無い行・知らない鍵は None。その仲間はコードの既定で出る）。ほかの欄は省けばコードの既定。
    def memberRowOf(key: String, json: Json): Option[Member] =
        forM (
            member <- Member.memberOf(key);
            obj <- JsonCodec.expectObject(json);
            sprite <- Map.get("sprite", obj) |> Option.flatMap(JsonCodec.expectString)
        ) yield {
            let d = memberDefaultOf(member);
            { name = JsonCodec.stringOr("name", d#name, obj), sprite = sprite,
              placeholder = JsonCodec.stringOr("placeholder", d#placeholder, obj),
              joinLv = JsonCodec.intOr("joinLv", d#joinLv, obj),
              hp = JsonCodec.intOr("hp", d#hp, obj), mp = JsonCodec.intOr("mp", d#mp, obj),
              atk = JsonCodec.intOr("atk", d#atk, obj), defense = JsonCodec.intOr("def", d#defense, obj),
              agi = JsonCodec.intOr("agi", d#agi, obj),
              hpUp = JsonCodec.intOr("hpUp", d#hpUp, obj), mpUp = JsonCodec.intOr("mpUp", d#mpUp, obj),
              atkUp = JsonCodec.intOr("atkUp", d#atkUp, obj), defUp = JsonCodec.intOr("defUp", d#defUp, obj),
              agiUp = JsonCodec.intOr("agiUp", d#agiUp, obj),
              weapon = JsonCodec.stringOr("weapon", d#weapon, obj), armor = JsonCodec.stringOr("armor", d#armor, obj) }
        }

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
