// WorldShop — 道具屋と宿の規則（すべて純粋）。
// 店は会話の <<shop>> が開き（WorldTalk.handToShop）、かう / うる → 品 → 個数 → はい / いいえ。閉じるとウィンドウを
// 開いた会話へ戻すだけ（続きは WorldTalk.tick が流す）。売値は値段の半分（切り捨て）・だいじなものは売れない。
// 買えない品（お金が足りない・ふくろの種類が一杯）は灰色で、選ぶと Denied を出すだけ。
// 宿は会話の <<inn>> が宿代を払って暗転（TransitionThen.InnRest）を始め、覆い切ったら rest が全快してセーブを書く。
mod WorldShop {
    use fge::{Dir4, Emit, Grid, Log, Num}
    use World.{Answer, FieldWindow, ShopMode, ShopPage}

    /// 一覧の 1 行: 道具・1 つの値段（売る時は売値）・選べるか。
    pub type alias Goods = { item = ItemsDoc.ItemId, price = Int32, open = Bool }

    /// 1 度に買う・売る個数の上限。
    def maxCount(): Int32 = 9

    // ── 店を開く・閉じる ──

    /// 店を開く（shop = rpg.shops.json の品の shop の名前。空は村の道具屋 / talk = 閉じた時に戻る会話）。[遷移: Talk→Shop]
    pub def open(shop: String, talk: World.TalkState, w: World.World): World.World =
        World.withWindow(FieldWindow.Shop(shop, ShopPage.Top(0), talk), w)

    /// 開いている店のページと、戻る会話（店でなければ None）。
    pub def openShopOf(w: World.World): Option[(ShopPage, World.TalkState)] =
        World.fieldRecOf(w) |> Option.flatMap(r -> match r#window {
            case FieldWindow.Shop(_, page, talk) => Some((page, talk))
            case _                               => None
        })

    /// 開いている店の名前（店でなければ空 = 村の道具屋）。
    pub def shopOf(w: World.World): String =
        World.fieldRecOf(w) |> Option.flatMap(r -> match r#window {
            case FieldWindow.Shop(shop, _, _) => Some(shop)
            case _                            => None
        }) |> Option.getWithDefault("")

    def withPage(page: ShopPage, w: World.World): World.World =
        openShopOf(w) |> Option.map(match (_, talk) -> World.withWindow(FieldWindow.Shop(shopOf(w), page, talk), w)) |> Option.getWithDefault(w)

    /// 店を閉じて会話へ戻る。[遷移: Shop→Talk]
    def leave(w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Cancel);
        openShopOf(w) |> Option.map(match (_, talk) -> World.withWindow(FieldWindow.Talk(talk), w)) |> Option.getWithDefault(w)

    // ── 一覧 ──

    /// Top のページの並び（かう / うる / やめる）。Top の番号はこの並びの位置。
    pub def topModes(): List[Option[ShopMode]] = Some(ShopMode.Buy) :: Some(ShopMode.Sell) :: None :: Nil

    def topIndexOf(mode: ShopMode): Int32 = List.indexOf(Some(mode), topModes()) |> Option.getWithDefault(0)

    /// 品の一覧。かう = rpg.shops.json の、その店（shop の名前）の品（値段は rpg.items.json）、うる = ふくろの中（売値は半分。どの店でも同じ）。
    pub def goodsOf(res: Res.Res, shop: String, mode: ShopMode, bag: Bag.Bag): List[Goods] = match mode {
        case ShopMode.Buy  => ShopsDoc.goodsOf(shop, res#shops) |> List.filterMap(key -> ItemsDoc.idOf(res#items, key))
            |> List.filterMap(id -> ItemsDoc.itemOf(res#items, id) |> Option.map(item ->
                { item = id, price = item#price, open = item#price <= Bag.goldOf(bag) and Bag.hasRoomFor(id, bag) }))
        case ShopMode.Sell => Bag.listOf(res#items, bag)
            |> List.filterMap(match (id, _) -> ItemsDoc.itemOf(res#items, id) |> Option.map(item ->
                { item = id, price = item#price / 2, open = item#kind != ItemsDoc.Kind.Key }))
    }

    def goodsAt(res: Res.Res, mode: ShopMode, i: Int32, w: World.World): Option[Goods] = List.nth(i, goodsOf(res, shopOf(w), mode, w#bag))

    def goodsOfItem(res: Res.Res, mode: ShopMode, item: ItemsDoc.ItemId, w: World.World): Option[Goods] =
        goodsOf(res, shopOf(w), mode, w#bag) |> List.find(g -> g#item == item)

    def indexOfItem(res: Res.Res, mode: ShopMode, item: ItemsDoc.ItemId, w: World.World): Int32 =
        goodsOf(res, shopOf(w), mode, w#bag) |> List.map(g -> g#item) |> List.indexOf(item) |> Option.getWithDefault(0)

    /// 1 度に選べる個数の上限（かう = 払える数・うる = 持っている数。どちらも maxCount まで）。
    def maxCountOf(mode: ShopMode, goods: Goods, bag: Bag.Bag): Int32 =
        let limit = match mode {
            case ShopMode.Buy  => if (goods#price <= 0) maxCount() else Bag.goldOf(bag) / goods#price
            case ShopMode.Sell => Bag.countOf(goods#item, bag)
        };
        Num.clampInt(1, maxCount(), limit)

    // ── 入力 ──

    /// 上下: カーソル（個数のページは個数）を動かす。端で回る（個数は 1 と上限で回る）。
    pub def move(res: Res.Res, delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match openShopOf(w) |> Option.map(fst) {
            case Some(ShopPage.Top(i)) => cursorTo(ShopPage.Top(Int32.modulo(i + delta, List.length(topModes()))), w)
            case Some(ShopPage.Goods(mode, i)) =>
                cursorTo(ShopPage.Goods(mode, Int32.modulo(i + delta, Int32.max(1, List.length(goodsOf(res, shopOf(w), mode, w#bag))))), w)
            case Some(ShopPage.Count(mode, item, n)) =>
                let top = goodsOfItem(res, mode, item, w) |> Option.map(g -> maxCountOf(mode, g, w#bag)) |> Option.getWithDefault(1);
                cursorTo(ShopPage.Count(mode, item, Int32.modulo(n - 1 + delta, top) + 1), w)
            case Some(ShopPage.Confirm(mode, item, n, answer)) =>
                cursorTo(ShopPage.Confirm(mode, item, n, if (answer == Answer.Yes) Answer.No else Answer.Yes), w)
            case None => w
        }

    def cursorTo(page: ShopPage, w: World.World): World.World \ Emit[World.Event] =
        if (openShopOf(w) |> Option.map(fst) == Some(page)) w
        else { Emit.emit(World.Event.Cursor); withPage(page, w) }

    /// 決定: Top → 品の一覧（やめるなら閉じる）→ 個数 → 確かめ → はいで買う・売って品の一覧へ（いいえは品の一覧へ）。
    pub def confirm(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match openShopOf(w) |> Option.map(fst) {
            case Some(ShopPage.Top(i)) => confirmTop(i, w)
            case Some(ShopPage.Goods(mode, i)) => pickGoods(goodsAt(res, mode, i, w), mode, w)
            case Some(ShopPage.Count(mode, item, n)) => { Emit.emit(World.Event.Confirm); withPage(ShopPage.Confirm(mode, item, n, Answer.Yes), w) }
            case Some(ShopPage.Confirm(mode, item, n, Answer.Yes)) => trade(res, mode, item, n, w)
            case Some(ShopPage.Confirm(mode, item, _, Answer.No)) =>
                Emit.emit(World.Event.Cancel);
                withPage(ShopPage.Goods(mode, indexOfItem(res, mode, item, w)), w)
            case None => w
        }

    def confirmTop(i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match List.nth(i, topModes()) {
            case Some(Some(mode)) => { Emit.emit(World.Event.Confirm); withPage(ShopPage.Goods(mode, 0), w) }
            case _                => leave(w)
        }

    def pickGoods(goods: Option[Goods], mode: ShopMode, w: World.World): World.World \ Emit[World.Event] =
        match goods {
            case Some(g) if g#open => { Emit.emit(World.Event.Confirm); withPage(ShopPage.Count(mode, g#item, 1), w) }
            case _                 => { Emit.emit(World.Event.Denied); w }
        }

    /// はい: お金とふくろを動かして品の一覧へ戻る。読み直しで品や値段が変わって払えなくなっていたら何もせずに戻る。
    def trade(res: Res.Res, mode: ShopMode, item: ItemsDoc.ItemId, n: Int32, w: World.World): World.World \ Emit[World.Event] =
        let goods = goodsOfItem(res, mode, item, w) |> Option.filter(g -> g#open and n <= maxCountOf(mode, g, w#bag));
        let traded = goods |> Option.map(g -> match mode {
            case ShopMode.Buy  => { bag = Bag.give(item, n, Bag.addGold(-(g#price * n), w#bag)) | w }
            case ShopMode.Sell => { bag = Bag.give(item, -n, Bag.addGold(g#price * n, w#bag)) | w }
        });
        Emit.emit(if (Option.isEmpty(traded)) World.Event.Denied else World.Event.Confirm);
        let after = traded |> Option.getWithDefault(w);
        let count = List.length(goodsOf(res, shopOf(w), mode, after#bag));
        withPage(ShopPage.Goods(mode, Num.clampInt(0, Int32.max(0, count - 1), indexOfItem(res, mode, item, w))), after)

    /// 取消: 1 つ前のページへ（Top なら店を閉じて会話へ戻る）。
    pub def cancel(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match openShopOf(w) |> Option.map(fst) |> Option.flatMap(page -> parentOf(res, page, w)) {
            case Some(parent) => { Emit.emit(World.Event.Cancel); withPage(parent, w) }
            case None         => leave(w)
        }

    /// 取消で戻る先（Top は無い = 閉じる）。
    def parentOf(res: Res.Res, page: ShopPage, w: World.World): Option[ShopPage] = match page {
        case ShopPage.Top(_)                => None
        case ShopPage.Goods(mode, _)        => Some(ShopPage.Top(topIndexOf(mode)))
        case ShopPage.Count(mode, item, _)  => Some(ShopPage.Goods(mode, indexOfItem(res, mode, item, w)))
        case ShopPage.Confirm(mode, item, n, _) => Some(ShopPage.Count(mode, item, n))
    }

    // ── 宿 ──

    /// 宿代を払って泊まり始める（暗転を覆い始める）。払えない時は何もせずに 1 行言う（会話は払える時だけ <<inn>> を流す）。
    pub def startInn(res: Res.Res, w: World.World): World.World =
        let price = ShopsDoc.rec(res#shops)#innPrice;
        if (Bag.goldOf(w#bag) < price)
            Log.warnThen("[talk] <<inn>> を流したが宿代 ${price}G に足りない（会話の <<if $gold >= $innPrice>> で分ける）。泊めない", w)
        else { bag = Bag.addGold(-price, w#bag) | w }
            |> World.mapField(r -> { transition = Some({ startedAt = World.now(w), then = World.TransitionThen.InnRest }) | r })

    /// 覆い切った: 全員の HP と MP を最大にし、今の中身をセーブにする。
    pub def rest(res: Res.Res, w: World.World): World.World =
        World.writeSave({ party = Party.restoreAll(res#party, w#party) | w })

    /// rules の宿の前のマップとマス（下を向く。マップが無ければ None）。「つづきから」と全滅の後に立つ所。
    pub def homeOf(res: Res.Res): Option[(MapDoc.MapId, Grid.Cell, Dir4.Dir4)] =
        let rules = RulesDoc.rec(res#rules);
        MapDoc.idOf(res#maps, rules#homeMap) |> Option.map(id -> (id, { x = rules#homeX, y = rules#homeY }, Dir4.Dir4.Down))
}
