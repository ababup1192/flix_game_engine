// ViewMenu — フィールドのメニュー（どうぐ・つよさ・そうび）と店のウィンドウの In を、開いているウィンドウから組む（純粋）。
mod ViewMenu {
    use World.{FieldWindow, MenuPage, NoticeThen, ShopMode, ShopPage}
    use TextDoc.MenuText

    def text(res: Res.Res, m: MenuText): String = TextDoc.menuText(m, res#text)

    // ── メニュー ──

    /// メニューのウィンドウ（知らせの間は戻る先のページを出し、つよさは知らせの下に隠れるので出さない）。
    pub def menuIn(res: Res.Res, party: Party.Party, bag: Bag.Bag, window: FieldWindow): Option[MenuView.In] = match window {
        case FieldWindow.Menu(page) => Some(menuOf(res, party, bag, page))
        case FieldWindow.Notice(n)  => backPageOf(n#then) |> Option.map(page -> { status = None | menuOf(res, party, bag, page) })
        case _                      => None
    }

    def backPageOf(then: NoticeThen): Option[MenuPage] = match then {
        case NoticeThen.BackTo(page) => Some(page)
        case NoticeThen.Close        => None
    }

    def menuOf(res: Res.Res, party: Party.Party, bag: Bag.Bag, page: MenuPage): MenuView.In =
        let members = Party.membersOf(party);
        let memberAt = i -> List.nth(i, members);
        let rootOf = item -> List.indexOf(item, WorldMenu.rootItems()) |> Option.getWithDefault(0);
        let (rootCursor, list, picker, status) = match page {
            case MenuPage.Root(i)               => (i, None, None, None)
            case MenuPage.SpellWho(i)           => (rootOf(WorldMenu.RootItem.Spell), None, Some(membersBox(res, members, i, true)), memberAt(i))
            case MenuPage.Spells(m, i)          =>
                (rootOf(WorldMenu.RootItem.Spell), Some(spellsBox(res, party, m, i, true)), Some(membersBox(res, members, indexOf(m, members), false)), Some(m))
            case MenuPage.SpellTarget(m, id, i) =>
                let at = Party.spellsOf(res#party, res#spells, m, party) |> List.indexOf(id) |> Option.getWithDefault(0);
                (rootOf(WorldMenu.RootItem.Spell), Some(spellsBox(res, party, m, at, false)), Some(membersBox(res, members, i, true)), memberAt(i))
            case MenuPage.Items(i)             => (rootOf(WorldMenu.RootItem.Items), Some(bagBox(res, bag, i, true)), None, List.head(members))
            case MenuPage.ItemTarget(id, i)     =>
                let at = WorldMenu.bagItemsOf(res, bag) |> List.indexOf(id) |> Option.getWithDefault(0);
                (rootOf(WorldMenu.RootItem.Items), Some(bagBox(res, bag, at, false)), Some(membersBox(res, members, i, true)), memberAt(i))
            case MenuPage.Status(m)             => (rootOf(WorldMenu.RootItem.Status), None, None, Some(m))
            case MenuPage.EquipWho(i)           => (rootOf(WorldMenu.RootItem.Equip), None, Some(membersBox(res, members, i, true)), memberAt(i))
            case MenuPage.EquipSlot(m, i)       =>
                (rootOf(WorldMenu.RootItem.Equip), Some(slotsBox(res, i)), Some(membersBox(res, members, indexOf(m, members), false)), Some(m))
            case MenuPage.EquipPick(m, slot, i) =>
                (rootOf(WorldMenu.RootItem.Equip), Some(pickBox(res, bag, m, slot, i)), Some(membersBox(res, members, indexOf(m, members), false)), Some(m))
        };
        let isRoot = match page {
            case MenuPage.Root(_) => true
            case _                => false
        };
        { root = WorldMenu.rootItems() |> List.map(item -> (text(res, rootTextOf(item)), WorldMenu.isRootOpen(res, party, item))),
          rootCursor = rootCursor, rootActive = isRoot, picker = picker, list = list,
          status = status |> Option.flatMap(m -> statusBox(res, party, bag, m)) }

    def indexOf(m: Member.Member, members: List[Member.Member]): Int32 = List.indexOf(m, members) |> Option.getWithDefault(0)

    def rootTextOf(item: WorldMenu.RootItem): MenuText = match item {
        case WorldMenu.RootItem.Talk   => MenuText.Talk
        case WorldMenu.RootItem.Spell  => MenuText.Spell
        case WorldMenu.RootItem.Status => MenuText.Status
        case WorldMenu.RootItem.Items  => MenuText.Items
        case WorldMenu.RootItem.Equip  => MenuText.Equip
        case WorldMenu.RootItem.Search => MenuText.Search
    }

    def slotTextOf(slot: Party.Slot): MenuText = match slot {
        case Party.Slot.Weapon => MenuText.Weapon
        case Party.Slot.Armor  => MenuText.Armor
    }

    /// ふくろの一覧（題は「どうぐ」。ふくろは 3 人で 1 つ）。
    def bagBox(res: Res.Res, bag: Bag.Bag, cursor: Int32, active: Bool): WindowView.ListBox =
        { title = text(res, MenuText.Items), cursor = cursor, active = active,
          rows = Bag.listOf(res#items, bag) |> List.map(match (id, n) -> { text = ItemsDoc.nameOf(res#items, id), right = "×${n}", open = true }) }

    /// m の覚えた呪文の一覧（題は「じゅもん」・右に使う MP。フィールドで唱えられない呪文と MP の足りない呪文は灰色）。
    def spellsBox(res: Res.Res, party: Party.Party, m: Member.Member, cursor: Int32, active: Bool): WindowView.ListBox =
        let rowOf = id -> {
            let spell = SpellsDoc.spellOf(res#spells, id);
            let cost = spell |> Option.map(s -> s#mp) |> Option.getWithDefault(0);
            let usable = spell |> Option.exists(s -> s#field and s#aim == SpellsDoc.Aim.Ally) and Party.mpOf(m, party) >= cost;
            { text = SpellsDoc.nameOf(res#spells, id), right = "${cost}", open = usable }
        };
        { title = text(res, MenuText.Spell), cursor = cursor, active = active,
          rows = Party.spellsOf(res#party, res#spells, m, party) |> List.map(rowOf) }

    def membersBox(res: Res.Res, members: List[Member.Member], cursor: Int32, active: Bool): WindowView.ListBox =
        { title = "", cursor = cursor, active = active,
          rows = members |> List.map(m -> { text = PartyDoc.memberOf(m, res#party)#name, right = "", open = true }) }

    /// ぶき / よろい（いま付けている物は下のつよさのウィンドウに出る）。
    /// WhyNot: 付けている物の名前を行の右に並べない — 一覧の幅は 15 マスで、「よろい」と 7 字の名前が重なる。
    def slotsBox(res: Res.Res, cursor: Int32): WindowView.ListBox =
        { title = text(res, MenuText.Equip), cursor = cursor, active = true,
          rows = Party.slots() |> List.map(slot -> { text = text(res, slotTextOf(slot)), right = "", open = true }) }

    /// 「はずす」と、ふくろの中の付けられる物（右に足す ちから / みのまもり）。
    def pickBox(res: Res.Res, bag: Bag.Bag, m: Member.Member, slot: Party.Slot, cursor: Int32): WindowView.ListBox =
        let rowOf = choice -> match choice {
            case None     => { text = text(res, MenuText.Unequip), right = "", open = true }
            case Some(id) =>
                let bonus = ItemsDoc.itemOf(res#items, id) |> Option.map(item -> item#atk + item#defense) |> Option.getWithDefault(0);
                { text = ItemsDoc.nameOf(res#items, id), right = "+${bonus}", open = true }
        };
        { title = text(res, slotTextOf(slot)), cursor = cursor, active = true,
          rows = WorldMenu.candidatesOf(res, m, slot, bag) |> List.map(rowOf) }

    def gearName(res: Res.Res, item: Option[ItemsDoc.ItemId]): String =
        item |> Option.map(ItemsDoc.nameOf(res#items)) |> Option.getWithDefault("")

    /// つよさ（Lv・HP / 最大・MP / 最大・装備・ちから・すばやさ・みのまもり・お金）。
    def statusBox(res: Res.Res, party: Party.Party, bag: Bag.Bag, m: Member.Member): Option[MenuView.StatusBox] =
        Party.statsOf(m, party) |> Option.map(s ->
            { name = PartyDoc.memberOf(m, res#party)#name, level = (text(res, MenuText.Level), "${s#lv}"),
              left = (text(res, MenuText.Hp), "${s#hp}/${Party.maxHpOf(res#party, m, party)}") ::
                     (text(res, MenuText.Mp), "${s#mp}/${Party.maxMpOf(res#party, m, party)}") ::
                     (text(res, MenuText.Weapon), gearName(res, s#weapon)) ::
                     (text(res, MenuText.Armor), gearName(res, s#armor)) :: Nil,
              right = (text(res, MenuText.Atk), "${Party.atkOf(res#party, res#items, m, party)}") ::
                      (text(res, MenuText.Agi), "${Party.agiOf(res#party, m, party)}") ::
                      (text(res, MenuText.Defense), "${Party.defenseOf(res#party, res#items, m, party)}") ::
                      (text(res, MenuText.Gold), "${Bag.goldOf(bag)}G") :: Nil })

    // ── 店 ──

    /// 店のウィンドウ。
    pub def shopIn(res: Res.Res, bag: Bag.Bag, window: FieldWindow): Option[ShopView.In] = match window {
        case FieldWindow.Shop(shop, page, _) => Some(shopOf(res, bag, shop, page))
        case _                               => None
    }

    def shopOf(res: Res.Res, bag: Bag.Bag, shop: String, page: ShopPage): ShopView.In =
        let modeIndex = mode -> List.indexOf(Some(mode), WorldShop.topModes()) |> Option.getWithDefault(0);
        let goodsIndex = (mode, item) -> WorldShop.goodsOf(res, shop, mode, bag) |> List.map(g -> g#item) |> List.indexOf(item) |> Option.getWithDefault(0);
        let priceOf = (mode, item) -> WorldShop.goodsOf(res, shop, mode, bag) |> List.find(g -> g#item == item) |> Option.map(g -> g#price) |> Option.getWithDefault(0);
        let (topCursor, goods, count) = match page {
            case ShopPage.Top(i)                  => (i, None, None)
            case ShopPage.Goods(mode, i)          => (modeIndex(mode), Some(goodsBox(res, bag, shop, mode, i, true)), None)
            case ShopPage.Count(mode, item, n)    =>
                (modeIndex(mode), Some(goodsBox(res, bag, shop, mode, goodsIndex(mode, item), false)), Some(("×${n}", "${priceOf(mode, item) * n}G", true)))
            case ShopPage.Confirm(mode, item, n, _) =>
                (modeIndex(mode), Some(goodsBox(res, bag, shop, mode, goodsIndex(mode, item), false)), Some(("×${n}", "${priceOf(mode, item) * n}G", false)))
        };
        let isTop = match page {
            case ShopPage.Top(_) => true
            case _               => false
        };
        let topText = mode -> match mode {
            case Some(ShopMode.Buy)  => text(res, MenuText.Buy)
            case Some(ShopMode.Sell) => text(res, MenuText.Sell)
            case None                => text(res, MenuText.Leave)
        };
        { top = { title = "", cursor = topCursor, active = isTop,
                  rows = WorldShop.topModes() |> List.map(mode -> { text = topText(mode), right = "", open = true }) },
          gold = (text(res, MenuText.Gold), "${Bag.goldOf(bag)}G"), goods = goods, count = count }

    /// 品の一覧（右に 1 つの値段。買えない・売れない物は灰色）。
    def goodsBox(res: Res.Res, bag: Bag.Bag, shop: String, mode: ShopMode, cursor: Int32, active: Bool): WindowView.ListBox =
        let title = match mode {
            case ShopMode.Buy  => text(res, MenuText.Buy)
            case ShopMode.Sell => text(res, MenuText.Sell)
        };
        { title = title, cursor = cursor, active = active,
          rows = WorldShop.goodsOf(res, shop, mode, bag) |> List.map(g -> { text = ItemsDoc.nameOf(res#items, g#item), right = "${g#price}G", open = g#open }) }
}
