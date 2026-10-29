// WorldMenu — フィールドのメニューと、その知らせ（Notice）の規則（すべて純粋）。
// 取消のキーで Root を開き、ページ（World.MenuPage）を 1 つずつ進む。取消で戻る先は parentOf の 1 か所。
//   どうぐ … Items → ItemTarget（HP / MP が戻る物だけ）→ 戻った数の知らせ → Items。装備品・だいじなもの・戻る物の無い道具は知らせだけ
//   つよさ … Status（左右で仲間を替える）
//   そうび … EquipWho → EquipSlot → EquipPick（今の物はふくろへ戻し、選んだ物をふくろから出す）→ EquipSlot
//   はなす / しらべる … 決定（WorldField.tryInteract）と同じ。話せる人がいなければ知らせ
//   じゅもん … SpellWho → Spells → SpellTarget（回復の呪文だけフィールドで唱えられる）→ 戻った数の知らせ → Spells。
//             呪文を覚えていない人・フィールドで唱えられない呪文・MP の足りない呪文は知らせだけ
mod WorldMenu {
    use fge::{Dir4, Emit, Num, UiTypewriter}
    use World.{FieldWindow, MenuPage, NoticeThen}

    /// Root の項目（2 列 × 3 行。左上から右へ、行ごとに並べた順）。
    pub enum RootItem with Eq, ToString {
        case Talk
        case Spell
        case Status
        case Items
        case Equip
        case Search
    }

    pub def rootItems(): List[RootItem] =
        RootItem.Talk :: RootItem.Spell :: RootItem.Status :: RootItem.Items :: RootItem.Equip :: RootItem.Search :: Nil

    /// 選べる項目か（じゅもん は誰か 1 人でも呪文を覚えている時だけ）。
    pub def isRootOpen(res: Res.Res, party: Party.Party, item: RootItem): Bool = match item {
        case RootItem.Spell => Party.membersOf(party) |> List.exists(m -> not List.isEmpty(Party.spellsOf(res#party, res#spells, m, party)))
        case _             => true
    }

    /// m の覚えた呪文（じゅもんのページの並び）。
    pub def spellsOf(res: Res.Res, m: Member.Member, w: World.World): List[SpellsDoc.SpellId] =
        Party.spellsOf(res#party, res#spells, m, w#party)

    def rootIndexOf(item: RootItem): Int32 = List.indexOf(item, rootItems()) |> Option.getWithDefault(0)

    /// Root の列の数。
    def rootCols(): Int32 = 2

    // ── 開く・読む ──

    /// メニューを開く。[遷移: Closed→Menu]
    pub def open(w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Confirm);
        toPage(MenuPage.Root(0), w)

    /// 開いているメニューのページ（メニューでなければ None）。
    pub def openPageOf(w: World.World): Option[MenuPage] =
        World.fieldRecOf(w) |> Option.flatMap(r -> match r#window {
            case FieldWindow.Menu(page) => Some(page)
            case _                      => None
        })

    /// 開いている知らせ（無ければ None）。
    def openNoticeOf(w: World.World): Option[World.NoticeState] =
        World.fieldRecOf(w) |> Option.flatMap(r -> match r#window {
            case FieldWindow.Notice(notice) => Some(notice)
            case _                          => None
        })

    def toPage(page: MenuPage, w: World.World): World.World = World.withWindow(FieldWindow.Menu(page), w)

    /// ふくろの道具（どうぐのページの並び = Bag.listOf）。
    pub def bagItemsOf(res: Res.Res, bag: Bag.Bag): List[ItemsDoc.ItemId] = Bag.listOf(res#items, bag) |> List.map(fst)

    /// 置き場に付けられる物（先頭は「はずす」= None。ふくろの中の、その置き場の種類で m が付けられる物）。
    pub def candidatesOf(res: Res.Res, m: Member.Member, slot: Party.Slot, bag: Bag.Bag): List[Option[ItemsDoc.ItemId]] =
        None :: (bagItemsOf(res, bag) |> List.filter(id -> ItemsDoc.itemOf(res#items, id)
            |> Option.exists(item -> item#kind == Party.kindOf(slot) and Set.memberOf(m, item#equip))) |> List.map(Some))

    // ── カーソル ──

    /// 方向キー: Root は 2 列 × 3 行のグリッド、つよさは仲間を替え、ほかの一覧は上下。端で回る。
    pub def move(res: Res.Res, dir: Dir4.Dir4, w: World.World): World.World \ Emit[World.Event] =
        let members = Party.membersOf(w#party);
        let next = openPageOf(w) |> Option.map(page -> match page {
            case MenuPage.Root(i)               => MenuPage.Root(rootMove(dir, i))
            case MenuPage.SpellWho(i)           => MenuPage.SpellWho(listMove(dir, i, List.length(members)))
            case MenuPage.Spells(m, i)          => MenuPage.Spells(m, listMove(dir, i, List.length(spellsOf(res, m, w))))
            case MenuPage.SpellTarget(m, id, i) => MenuPage.SpellTarget(m, id, listMove(dir, i, List.length(members)))
            case MenuPage.Items(i)            => MenuPage.Items(listMove(dir, i, List.length(bagItemsOf(res, w#bag))))
            case MenuPage.ItemTarget(id, i)     => MenuPage.ItemTarget(id, listMove(dir, i, List.length(members)))
            case MenuPage.Status(m)             => MenuPage.Status(memberMove(dir, m, members))
            case MenuPage.EquipWho(i)           => MenuPage.EquipWho(listMove(dir, i, List.length(members)))
            case MenuPage.EquipSlot(m, i)       => MenuPage.EquipSlot(m, listMove(dir, i, List.length(Party.slots())))
            case MenuPage.EquipPick(m, slot, i) => MenuPage.EquipPick(m, slot, listMove(dir, i, List.length(candidatesOf(res, m, slot, w#bag))))
        });
        match next {
            case Some(page) if Some(page) != openPageOf(w) => { Emit.emit(World.Event.Cursor); toPage(page, w) }
            case _                                         => w
        }

    /// 2 列 × 3 行のグリッド: 上下は行、左右は列（どちらも端で回る）。
    def rootMove(dir: Dir4.Dir4, i: Int32): Int32 =
        let count = List.length(rootItems());
        let col = Int32.modulo(i, rootCols());
        match dir {
            case Dir4.Dir4.Up    => Int32.modulo(i - rootCols(), count)
            case Dir4.Dir4.Down  => Int32.modulo(i + rootCols(), count)
            case Dir4.Dir4.Left  => i - col + Int32.modulo(col - 1, rootCols())
            case Dir4.Dir4.Right => i - col + Int32.modulo(col + 1, rootCols())
        }

    /// 縦の一覧: 上下で 1 つ（端で回る）。左右では動かない。
    def listMove(dir: Dir4.Dir4, i: Int32, count: Int32): Int32 =
        let delta = match dir {
            case Dir4.Dir4.Up   => -1
            case Dir4.Dir4.Down => 1
            case _              => 0
        };
        if (count <= 0) 0 else Int32.modulo(i + delta, count)

    /// つよさ: どの方向でも隣の仲間へ（左と上は前・右と下は次）。
    def memberMove(dir: Dir4.Dir4, m: Member.Member, members: List[Member.Member]): Member.Member =
        let delta = match dir {
            case Dir4.Dir4.Up   => -1
            case Dir4.Dir4.Left => -1
            case _              => 1
        };
        let at = List.indexOf(m, members) |> Option.getWithDefault(0);
        List.nth(Int32.modulo(at + delta, Int32.max(1, List.length(members))), members) |> Option.getWithDefault(m)

    // ── 決定・取消 ──

    /// 決定: そのページの選んだ物へ進む（行き先はページの case ごと）。
    pub def confirm(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        let members = Party.membersOf(w#party);
        match openPageOf(w) {
            case Some(MenuPage.Root(i)) => confirmRoot(res, List.nth(i, rootItems()), w)
            case Some(MenuPage.SpellWho(i)) => confirmCaster(res, List.nth(i, members), i, w)
            case Some(MenuPage.Spells(m, i)) => confirmSpell(res, m, List.nth(i, spellsOf(res, m, w)), i, w)
            case Some(MenuPage.SpellTarget(m, id, i)) => castOn(res, m, id, List.nth(i, members), w)
            case Some(MenuPage.Items(i)) => confirmItem(res, List.nth(i, bagItemsOf(res, w#bag)), i, w)
            case Some(MenuPage.ItemTarget(id, i)) => useItem(res, id, List.nth(i, members), w)
            case Some(MenuPage.Status(_)) => cancel(res, w)
            case Some(MenuPage.EquipWho(i)) => forward(List.nth(i, members) |> Option.map(m -> MenuPage.EquipSlot(m, 0)), w)
            case Some(MenuPage.EquipSlot(m, i)) => forward(List.nth(i, Party.slots()) |> Option.map(slot -> MenuPage.EquipPick(m, slot, 0)), w)
            case Some(MenuPage.EquipPick(m, slot, i)) => equip(m, slot, List.nth(i, candidatesOf(res, m, slot, w#bag)), w)
            case None => w
        }

    /// page へ進む（行けるページが無ければ何もしない）。
    def forward(page: Option[MenuPage], w: World.World): World.World \ Emit[World.Event] = match page {
        case Some(p) => { Emit.emit(World.Event.Confirm); toPage(p, w) }
        case None    => w
    }

    def confirmRoot(res: Res.Res, item: Option[RootItem], w: World.World): World.World \ Emit[World.Event] =
        let lead = List.head(Party.membersOf(w#party));
        match item {
            case Some(RootItem.Talk)   => talkOrSay(res, TextDoc.NoticeText.Nobody, w)
            case Some(RootItem.Search) => talkOrSay(res, TextDoc.NoticeText.Nothing, w)
            case Some(RootItem.Spell) if isRootOpen(res, w#party, RootItem.Spell) => forward(Some(MenuPage.SpellWho(0)), w)
            case Some(RootItem.Spell)  => { Emit.emit(World.Event.Denied); w }
            case Some(RootItem.Status) => forward(lead |> Option.map(MenuPage.Status), w)
            case Some(RootItem.Items)  => forward(Some(MenuPage.Items(0)), w)
            case Some(RootItem.Equip)  => forward(Some(MenuPage.EquipWho(0)), w)
            case None                  => w
        }

    /// はなす・しらべる: 前の人の会話を開く（メニューは会話に替わる）。話せる人がいなければ知らせて閉じる。
    def talkOrSay(res: Res.Res, nobody: TextDoc.NoticeText, w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Confirm);
        WorldField.tryInteract(res, w)
            |> Option.getWithDefault(notice(TextDoc.noticeText(nobody, Nil, res#text), NoticeThen.Close, w))

    /// じゅもん → 唱える人: 呪文を覚えていれば一覧へ、覚えていなければ知らせ（SpellWho へ戻る）。
    def confirmCaster(res: Res.Res, caster: Option[Member.Member], i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match caster {
            case Some(m) if not List.isEmpty(spellsOf(res, m, w)) => forward(Some(MenuPage.Spells(m, 0)), w)
            case Some(m) =>
                Emit.emit(World.Event.Confirm);
                notice(TextDoc.noticeText(TextDoc.NoticeText.NoSpells, (TextDoc.Placeholder.Name, PartyDoc.memberOf(m, res#party)#name) :: Nil, res#text),
                       NoticeThen.BackTo(MenuPage.SpellWho(i)), w)
            case None => w
        }

    /// 呪文を選んだ: フィールドで唱えられる回復の呪文で MP が足りれば誰にかへ。ほかは知らせ（Spells へ戻る）。
    def confirmSpell(res: Res.Res, m: Member.Member, id: Option[SpellsDoc.SpellId], i: Int32, w: World.World): World.World \ Emit[World.Event] =
        let back = NoticeThen.BackTo(MenuPage.Spells(m, i));
        let say = text -> { Emit.emit(World.Event.Confirm); notice(TextDoc.noticeText(text, Nil, res#text), back, w) };
        match id |> Option.flatMap(sid -> SpellsDoc.spellOf(res#spells, sid) |> Option.map(s -> (sid, s))) {
            case Some((_, spell)) if not spell#field or spell#aim != SpellsDoc.Aim.Ally => say(TextDoc.NoticeText.NotHere)
            case Some((_, spell)) if Party.mpOf(m, w#party) < spell#mp                  => say(TextDoc.NoticeText.NoMp)
            case Some((sid, _))                                                          => forward(Some(MenuPage.SpellTarget(m, sid, 0)), w)
            case None                                                                    => w
        }

    /// 回復の呪文を target に唱える: MP を使って HP を power だけ戻し（最大で止める）、戻った数を知らせる（Spells へ戻る）。
    /// 減らさずに知らせるのは、HP が最大の人（「ひつようない」）と倒れている人（「なにも おこらなかった」）。
    def castOn(res: Res.Res, m: Member.Member, id: SpellsDoc.SpellId, target: Option[Member.Member], w: World.World): World.World \ Emit[World.Event] =
        let index = spellsOf(res, m, w) |> List.indexOf(id) |> Option.getWithDefault(0);
        let back = NoticeThen.BackTo(MenuPage.Spells(m, index));
        let heal = forM (
            t <- target;
            spell <- SpellsDoc.spellOf(res#spells, id)
        ) yield (t, spell, Int32.min(spell#power, Party.maxHpOf(res#party, t, w#party) - Party.hpOf(t, w#party)), Party.isAlive(t, w#party));
        Emit.emit(World.Event.Confirm);
        match heal {
            case Some((t, spell, gained, true)) if gained > 0 =>
                let paid = Party.recover(res#party, m, { hp = 0, mp = 0 - spell#mp }, w#party);
                let after = { party = Party.recover(res#party, t, { hp = gained, mp = 0 }, paid) | w };
                let name = PartyDoc.memberOf(t, res#party)#name;
                notice(TextDoc.noticeText(TextDoc.NoticeText.Healed, (TextDoc.Placeholder.Name, name) :: (TextDoc.Placeholder.N, "${gained}") :: Nil, res#text), back, after)
            case Some((t, _, _, true)) =>
                notice(TextDoc.noticeText(TextDoc.NoticeText.NotNeeded, (TextDoc.Placeholder.Name, PartyDoc.memberOf(t, res#party)#name) :: Nil, res#text), back, w)
            case _ => notice(TextDoc.noticeText(TextDoc.NoticeText.NoEffect, Nil, res#text), back, w)
        }

    /// どうぐ: HP か MP が戻る物は誰に使うかへ、ほかは知らせだけ（Items へ戻る）。
    def confirmItem(res: Res.Res, id: Option[ItemsDoc.ItemId], i: Int32, w: World.World): World.World \ Emit[World.Event] =
        let back = NoticeThen.BackTo(MenuPage.Items(i));
        let say = text -> { Emit.emit(World.Event.Confirm); notice(TextDoc.noticeText(text, Nil, res#text), back, w) };
        match id |> Option.flatMap(it -> ItemsDoc.itemOf(res#items, it) |> Option.map(item -> (it, item))) {
            case Some((it, item)) if item#kind == ItemsDoc.Kind.Use and (item#heal > 0 or item#mpHeal > 0) =>
                forward(Some(MenuPage.ItemTarget(it, 0)), w)
            case Some((it, item)) if item#kind == ItemsDoc.Kind.Use and item#lightSteps > 0 => lightTorch(res, it, item, back, w)
            case Some((_, item)) if item#kind == ItemsDoc.Kind.Use    => say(TextDoc.NoticeText.NotHere)
            case Some((_, item)) if item#kind == ItemsDoc.Kind.Key    => say(TextDoc.NoticeText.KeyItem)
            case Some(_)                                              => say(TextDoc.NoticeText.UseEquip)
            case None                                                 => w
        }

    /// 明かりの道具（lightSteps のある物）: 暗いマップなら 1 つ減らして残りの歩数を lightSteps にし、メニューを閉じて知らせる
    /// （残っている明かりは足さずに置き換える）。明るいマップでは減らさずに知らせて一覧へ戻る。
    def lightTorch(res: Res.Res, id: ItemsDoc.ItemId, item: ItemsDoc.Item, back: NoticeThen, w: World.World): World.World \ Emit[World.Event] =
        let dark = World.fieldRecOf(w) |> Option.flatMap(r -> MapDoc.docOf(res#maps, r#map)) |> Option.exists(map -> MapDoc.rec(map)#dark);
        Emit.emit(World.Event.Confirm);
        if (not dark) notice(TextDoc.noticeText(TextDoc.NoticeText.TorchNotHere, Nil, res#text), back, w)
        else {
            let lit = World.mapField(r -> { light = item#lightSteps | r }, { bag = Bag.give(id, -1, w#bag) | w });
            notice(TextDoc.noticeText(TextDoc.NoticeText.TorchLit, (TextDoc.Placeholder.Item, item#name) :: Nil, res#text), NoticeThen.Close, lit)
        }

    /// m に道具を使う: HP と MP を戻して 1 つ減らし、戻った数を知らせる。減らさずに知らせるのは、
    /// HP も MP も最大の人（「ひつようない」）と倒れている人（「なにも おこらなかった」）。
    def useItem(res: Res.Res, id: ItemsDoc.ItemId, target: Option[Member.Member], w: World.World): World.World \ Emit[World.Event] =
        let used = forM (
            m <- target;
            item <- ItemsDoc.itemOf(res#items, id);
            stats <- Party.statsOf(m, w#party)
        ) yield {
            let gainHp = Int32.min(item#heal, Party.maxHpOf(res#party, m, w#party) - stats#hp);
            let gainMp = Int32.min(item#mpHeal, Party.maxMpOf(res#party, m, w#party) - stats#mp);
            (m, gainHp, gainMp, stats#hp > 0)
        };
        let index = bagItemsOf(res, w#bag) |> List.indexOf(id) |> Option.getWithDefault(0);
        Emit.emit(World.Event.Confirm);
        match used {
            case Some((m, gainHp, gainMp, true)) if gainHp > 0 or gainMp > 0 =>
                let after = { party = Party.recover(res#party, m, { hp = gainHp, mp = gainMp }, w#party), bag = Bag.give(id, -1, w#bag) | w };
                let name = PartyDoc.memberOf(m, res#party)#name;
                let text = if (gainHp > 0) TextDoc.noticeText(TextDoc.NoticeText.Healed, (TextDoc.Placeholder.Name, name) :: (TextDoc.Placeholder.N, "${gainHp}") :: Nil, res#text)
                           else TextDoc.noticeText(TextDoc.NoticeText.MpHealed, (TextDoc.Placeholder.Name, name) :: (TextDoc.Placeholder.N, "${gainMp}") :: Nil, res#text);
                let left = List.length(bagItemsOf(res, after#bag));
                notice(text, NoticeThen.BackTo(MenuPage.Items(Num.clampInt(0, Int32.max(0, left - 1), index))), after)
            case Some((m, _, _, true)) =>
                let name = PartyDoc.memberOf(m, res#party)#name;
                notice(TextDoc.noticeText(TextDoc.NoticeText.NotNeeded, (TextDoc.Placeholder.Name, name) :: Nil, res#text), NoticeThen.BackTo(MenuPage.Items(index)), w)
            case _ =>
                notice(TextDoc.noticeText(TextDoc.NoticeText.NoEffect, Nil, res#text), NoticeThen.BackTo(MenuPage.Items(index)), w)
        }

    /// そうび: 今の物をふくろへ戻し、選んだ物をふくろから出して付ける（None ははずす）。ふくろに戻す空きが無ければ Denied。
    def equip(m: Member.Member, slot: Party.Slot, choice: Option[Option[ItemsDoc.ItemId]], w: World.World): World.World \ Emit[World.Event] =
        let back = MenuPage.EquipSlot(m, List.indexOf(slot, Party.slots()) |> Option.getWithDefault(0));
        let worn = Party.equipOf(m, slot, w#party);
        let swapped = choice |> Option.flatMap(next -> {
            let taken = next |> Option.map(id -> Bag.give(id, -1, w#bag)) |> Option.getWithDefault(w#bag);
            let roomy = worn |> Option.forAll(id -> Bag.hasRoomFor(id, taken));
            if (roomy) Some({ party = Party.withEquip(m, slot, next, w#party),
                              bag = worn |> Option.map(id -> Bag.give(id, 1, taken)) |> Option.getWithDefault(taken) | w })
            else None
        });
        match swapped {
            case Some(after) => { Emit.emit(World.Event.Confirm); toPage(back, after) }
            case None        => { Emit.emit(World.Event.Denied); w }
        }

    /// 取消: 1 つ前のページへ（Root ならメニューを閉じる）。
    pub def cancel(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Cancel);
        match openPageOf(w) |> Option.flatMap(page -> parentOf(res, page, w)) {
            case Some(parent) => toPage(parent, w)
            case None         => World.mapField(World.closeWindow, w)
        }

    /// 取消で戻る先（Root は無い = 閉じる）。戻ったページのカーソルは、来た時に選んだ項目。
    def parentOf(res: Res.Res, page: MenuPage, w: World.World): Option[MenuPage] =
        let memberIndex = m -> Party.membersOf(w#party) |> List.indexOf(m) |> Option.getWithDefault(0);
        match page {
            case MenuPage.Root(_)              => None
            case MenuPage.SpellWho(_)          => Some(MenuPage.Root(rootIndexOf(RootItem.Spell)))
            case MenuPage.Spells(m, _)         => Some(MenuPage.SpellWho(memberIndex(m)))
            case MenuPage.SpellTarget(m, id, _) => Some(MenuPage.Spells(m, spellsOf(res, m, w) |> List.indexOf(id) |> Option.getWithDefault(0)))
            case MenuPage.Items(_)            => Some(MenuPage.Root(rootIndexOf(RootItem.Items)))
            case MenuPage.ItemTarget(id, _)    => Some(MenuPage.Items(bagItemsOf(res, w#bag) |> List.indexOf(id) |> Option.getWithDefault(0)))
            case MenuPage.Status(_)            => Some(MenuPage.Root(rootIndexOf(RootItem.Status)))
            case MenuPage.EquipWho(_)          => Some(MenuPage.Root(rootIndexOf(RootItem.Equip)))
            case MenuPage.EquipSlot(m, _)      => Some(MenuPage.EquipWho(memberIndex(m)))
            case MenuPage.EquipPick(m, slot, _) => Some(MenuPage.EquipSlot(m, List.indexOf(slot, Party.slots()) |> Option.getWithDefault(0)))
        }

    // ── 知らせ ──

    /// 知らせを出す（then = 送った後に行く所）。
    def notice(text: String, then: NoticeThen, w: World.World): World.World = World.showNotice(text, then, w)

    /// 知らせの文字送りを遊びの時計の 1 フレームぶん進める。
    pub def tickNotice(res: Res.Res, dt: Float64, w: World.World): World.World =
        openNoticeOf(w) |> Option.map(n -> World.withWindow(FieldWindow.Notice(
            { reveal = UiTypewriter.step({ cps = RulesDoc.rec(res#rules)#cps }, dt, n#reveal) | n }), w)) |> Option.getWithDefault(w)

    /// 決定・取消: 出している途中なら出し切る → 送った後に行く所へ（閉じる・メニューのページへ戻る）。
    pub def confirmNotice(w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.TalkNext);
        match openNoticeOf(w) {
            case Some(n) if not UiTypewriter.isDone(n#reveal) =>
                World.withWindow(FieldWindow.Notice({ reveal = UiTypewriter.skip(n#reveal) | n }), w)
            case Some(n) => afterNotice(n#then, w)
            case None    => w
        }

    def afterNotice(then: NoticeThen, w: World.World): World.World = match then {
        case NoticeThen.Close        => World.mapField(World.closeWindow, w)
        case NoticeThen.BackTo(page) => toPage(page, w)
    }
}
