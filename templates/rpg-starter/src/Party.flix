// Party — 加わった順の仲間と、1 人ずつの今の値（Lv・HP・MP・装備）。先頭は加わった順で最初の人。
// 最大 HP・ちから等は Lv と装備から導く（maxHpOf・atkOf…）。導ける値をここに持たない（Doc を直すとずれる）。
// 仲間の加入の正はここの「加わった順」だけ（Progress に別の旗を持たない）。
mod Party {
    use fge::{Num}

    /// 1 人の今の値。exp = 経験値の累計・weapon / armor = 付けている物（付けている物はふくろに入れない）。
    pub type alias Stats = { lv = Int32, exp = Int32, hp = Int32, mp = Int32,
                             weapon = Option[ItemsDoc.ItemId], armor = Option[ItemsDoc.ItemId] }

    /// 装備の置き場。
    pub enum Slot with Eq, Order, ToString {
        case Weapon
        case Armor
    }

    /// 置き場の並び（そうびのページの上から）。
    pub def slots(): List[Slot] = Slot.Weapon :: Slot.Armor :: Nil

    /// その置き場に付ける道具の種類。
    pub def kindOf(slot: Slot): ItemsDoc.Kind = match slot {
        case Slot.Weapon => ItemsDoc.Kind.Weapon
        case Slot.Armor  => ItemsDoc.Kind.Armor
    }

    type alias Rec = { order = List[Member.Member], stats = Map[Member.Member, Stats] }

    /// WhyNot: 外で組ませない — 同じ人が 2 回並ぶと隊列に同じ人が 2 人立ち、order と stats がずれると値の無い人が歩く。
    enum PartyOf(Rec)

    /// 加わった順の仲間と今の値（作るのは empty・join・ofStats だけ）。
    pub type alias Party = PartyOf

    def rec(p: Party): Rec = match p { case PartyOf.PartyOf(r) => r }

    /// 誰もいない（タイトルの間。「はじめから」で starting に替わる）。
    pub def empty(): Party = PartyOf.PartyOf({ order = Nil, stats = Map.empty() })

    /// はじめの仲間（ルカ 1 人）。
    pub def starting(partyDoc: PartyDoc.Doc, items: ItemsDoc.Doc): Party = join(partyDoc, items, Member.Member.Luka, empty())

    /// 加わった順。
    pub def membersOf(p: Party): List[Member.Member] = rec(p)#order

    pub def hasJoined(m: Member.Member, p: Party): Bool = Map.memberOf(m, rec(p)#stats)

    /// 後ろに加える（もう加わっていればそのまま）。Lv は Doc の joinLv（経験値はその Lv の累計）・HP と MP は最大・装備は Doc の初めの物。
    pub def join(partyDoc: PartyDoc.Doc, items: ItemsDoc.Doc, m: Member.Member, p: Party): Party =
        if (hasJoined(m, p)) p
        else {
            let looks = PartyDoc.memberOf(m, partyDoc);
            let lv = Int32.max(1, looks#joinLv);
            let fresh = { lv = lv, exp = PartyDoc.expFor(lv, partyDoc), hp = hpAt(partyDoc, m, lv), mp = mpAt(partyDoc, m, lv),
                          weapon = ItemsDoc.idOf(items, looks#weapon), armor = ItemsDoc.idOf(items, looks#armor) };
            PartyOf.PartyOf({ order = List.append(rec(p)#order, m :: Nil), stats = Map.insert(m, fresh, rec(p)#stats) })
        }

    /// 加わった順の人と値から（セーブから戻す）。同じ人は先の 1 つだけ。
    pub def ofStats(rows: List[(Member.Member, Stats)]): Party =
        rows |> List.foldLeft((acc, row) -> {
            let (m, stats) = row;
            if (hasJoined(m, acc)) acc
            else PartyOf.PartyOf({ order = List.append(rec(acc)#order, m :: Nil), stats = Map.insert(m, stats, rec(acc)#stats) })
        }, empty())

    /// 加わった順の人と値。
    pub def statsList(p: Party): List[(Member.Member, Stats)] =
        membersOf(p) |> List.filterMap(m -> statsOf(m, p) |> Option.map(stats -> (m, stats)))

    /// 1 人の今の値（加わっていなければ None）。
    pub def statsOf(m: Member.Member, p: Party): Option[Stats] = Map.get(m, rec(p)#stats)

    /// 加わった人の id の集まり（マップの人の id と同じ名前の人は、加わったらマップから消える）。
    pub def joinedIds(p: Party): Set[String] = membersOf(p) |> List.map(Member.idOf) |> List.toSet

    def mapStats(m: Member.Member, f: Stats -> Stats, p: Party): Party =
        PartyOf.PartyOf({ stats = Map.adjust(f, m, rec(p)#stats) | rec(p) })

    // ── 導く値（Lv と装備から） ──

    /// 今の Lv（加わっていなければ 1）。
    pub def lvOf(m: Member.Member, p: Party): Int32 = statsOf(m, p) |> Option.map(s -> s#lv) |> Option.getWithDefault(1)

    /// Lv1 の値に、1 Lv ごとの伸びを (lv − 1) 回足す。
    def grown(base: Int32, up: Int32, lv: Int32): Int32 = base + up * Int32.max(0, lv - 1)

    def hpAt(partyDoc: PartyDoc.Doc, m: Member.Member, lv: Int32): Int32 =
        let row = PartyDoc.memberOf(m, partyDoc);
        grown(row#hp, row#hpUp, lv)

    def mpAt(partyDoc: PartyDoc.Doc, m: Member.Member, lv: Int32): Int32 =
        let row = PartyDoc.memberOf(m, partyDoc);
        grown(row#mp, row#mpUp, lv)

    pub def maxHpOf(partyDoc: PartyDoc.Doc, m: Member.Member, p: Party): Int32 = hpAt(partyDoc, m, lvOf(m, p))

    pub def maxMpOf(partyDoc: PartyDoc.Doc, m: Member.Member, p: Party): Int32 = mpAt(partyDoc, m, lvOf(m, p))

    pub def agiOf(partyDoc: PartyDoc.Doc, m: Member.Member, p: Party): Int32 =
        let row = PartyDoc.memberOf(m, partyDoc);
        grown(row#agi, row#agiUp, lvOf(m, p))

    /// ちから: Lv の値 + 付けている物の atk。
    pub def atkOf(partyDoc: PartyDoc.Doc, items: ItemsDoc.Doc, m: Member.Member, p: Party): Int32 =
        let row = PartyDoc.memberOf(m, partyDoc);
        grown(row#atk, row#atkUp, lvOf(m, p)) + gearSum(items, item -> item#atk, m, p)

    /// みのまもり: Lv の値 + 付けている物の def。
    pub def defenseOf(partyDoc: PartyDoc.Doc, items: ItemsDoc.Doc, m: Member.Member, p: Party): Int32 =
        let row = PartyDoc.memberOf(m, partyDoc);
        grown(row#defense, row#defUp, lvOf(m, p)) + gearSum(items, item -> item#defense, m, p)

    /// HP が 0 より多いか（加わっていなければ偽）。
    pub def isAlive(m: Member.Member, p: Party): Bool = statsOf(m, p) |> Option.exists(s -> s#hp > 0)

    /// 加わった順の、HP が 0 より多い人。
    pub def aliveOf(p: Party): List[Member.Member] = membersOf(p) |> List.filter(m -> isAlive(m, p))

    /// m が今の Lv までに覚えた呪文（rpg.party.json の learns の並び。rpg.spells.json に無い鍵は飛ばす）。
    pub def spellsOf(partyDoc: PartyDoc.Doc, spells: SpellsDoc.Doc, m: Member.Member, p: Party): List[SpellsDoc.SpellId] =
        PartyDoc.spellKeysAt(m, lvOf(m, p), partyDoc) |> List.filterMap(SpellsDoc.idOf(spells))

    /// 今の MP。
    pub def mpOf(m: Member.Member, p: Party): Int32 = statsOf(m, p) |> Option.map(s -> s#mp) |> Option.getWithDefault(0)

    /// 今の HP。
    pub def hpOf(m: Member.Member, p: Party): Int32 = statsOf(m, p) |> Option.map(s -> s#hp) |> Option.getWithDefault(0)

    def gearSum(items: ItemsDoc.Doc, f: ItemsDoc.Item -> Int32, m: Member.Member, p: Party): Int32 =
        slots() |> List.filterMap(slot -> equipOf(m, slot, p))
            |> List.filterMap(ItemsDoc.itemOf(items)) |> List.map(f) |> List.sum

    // ── 変える ──

    /// HP と MP を足す（最大で止める。0 で止める）。
    pub def recover(partyDoc: PartyDoc.Doc, m: Member.Member, amount: { hp = Int32, mp = Int32 }, p: Party): Party =
        mapStats(m, s -> { hp = Num.clampInt(0, maxHpOf(partyDoc, m, p), s#hp + amount#hp),
                           mp = Num.clampInt(0, maxMpOf(partyDoc, m, p), s#mp + amount#mp) | s }, p)

    /// 全員の HP と MP を最大に（宿）。
    pub def restoreAll(partyDoc: PartyDoc.Doc, p: Party): Party =
        membersOf(p) |> List.foldLeft((acc, m) -> mapStats(m, s -> { hp = hpAt(partyDoc, m, s#lv), mp = mpAt(partyDoc, m, s#lv) | s }, acc), p)

    /// 置き場に付けている物。
    pub def equipOf(m: Member.Member, slot: Slot, p: Party): Option[ItemsDoc.ItemId] =
        statsOf(m, p) |> Option.flatMap(s -> match slot {
            case Slot.Weapon => s#weapon
            case Slot.Armor  => s#armor
        })

    /// 置き場に item を付ける（None ははずす）。ふくろの出し入れは呼ぶ側（WorldMenu）。
    pub def withEquip(m: Member.Member, slot: Slot, item: Option[ItemsDoc.ItemId], p: Party): Party =
        mapStats(m, s -> match slot {
            case Slot.Weapon => { weapon = item | s }
            case Slot.Armor  => { armor = item | s }
        }, p)

    /// Doc を読み直した後に収める: HP と MP を新しい最大へ、Doc から消えた装備ははずす。
    pub def settle(partyDoc: PartyDoc.Doc, items: ItemsDoc.Doc, p: Party): Party =
        let known = id -> Option.nonEmpty(ItemsDoc.itemOf(items, id));
        membersOf(p) |> List.foldLeft((acc, m) -> mapStats(m, s ->
            { hp = Int32.min(s#hp, hpAt(partyDoc, m, s#lv)), mp = Int32.min(s#mp, mpAt(partyDoc, m, s#lv)),
              weapon = Option.filter(known, s#weapon), armor = Option.filter(known, s#armor) | s }, acc), p)

    // ── 経験値とレベルアップ ──

    /// レベルアップ 1 回ぶん（伝言の材料）: 誰が・上がった後の Lv。
    pub type alias LevelUp = (Member.Member, Int32)

    /// 経験値を amount だけ足す。表をまたいだ分だけ何 Lv でも上げ（上限は表の一番上）、
    /// 最大 HP / MP が増えた分だけ今の HP / MP も足す。上がった Lv を 1 つずつ返す。
    pub def gainExp(partyDoc: PartyDoc.Doc, m: Member.Member, amount: Int32, p: Party): (Party, List[LevelUp]) =
        match statsOf(m, p) {
            case None    => (p, Nil)
            case Some(s) =>
                let total = s#exp + Int32.max(0, amount);
                let lv = Int32.max(s#lv, Int32.min(PartyDoc.maxLvOf(partyDoc), PartyDoc.lvFor(total, partyDoc)));
                let hpGain = hpAt(partyDoc, m, lv) - hpAt(partyDoc, m, s#lv);
                let mpGain = mpAt(partyDoc, m, lv) - mpAt(partyDoc, m, s#lv);
                let next = mapStats(m, st -> { lv = lv, exp = total, hp = st#hp + hpGain, mp = st#mp + mpGain | st }, p);
                (next, List.range(s#lv + 1, lv + 1) |> List.map(n -> (m, n)))
        }

    /// 1 人の HP と MP を置き換える（戦いの式が使う。最大と 0 で止める）。
    pub def withHpMp(partyDoc: PartyDoc.Doc, m: Member.Member, hp: Int32, mp: Int32, p: Party): Party =
        mapStats(m, s -> { hp = Num.clampInt(0, hpAt(partyDoc, m, s#lv), hp), mp = Num.clampInt(0, mpAt(partyDoc, m, s#lv), mp) | s }, p)

    /// 1 人の HP だけを置き換える（最大と 0 で止める。MP はそのまま）。
    pub def withHp(partyDoc: PartyDoc.Doc, m: Member.Member, hp: Int32, p: Party): Party =
        mapStats(m, s -> { hp = Num.clampInt(0, hpAt(partyDoc, m, s#lv), hp) | s }, p)

    /// 全員を Lv にする（経験値はその Lv の累計・HP と MP は最大。Starts の lv= と、つり合いのシミュレーション）。
    pub def atLevel(partyDoc: PartyDoc.Doc, lv: Int32, p: Party): Party =
        membersOf(p) |> List.foldLeft((acc, m) -> mapStats(m, s -> { lv = lv, exp = PartyDoc.expFor(lv, partyDoc),
                                                                      hp = hpAt(partyDoc, m, lv), mp = mpAt(partyDoc, m, lv) | s }, acc), p)
}
