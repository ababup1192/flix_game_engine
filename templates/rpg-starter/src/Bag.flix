// Bag — ふくろ（道具 → 個数）とお金。3 人で 1 つ。個数 0 の道具は持たない。種類は maxKinds まで。
mod Bag {

    pub type alias Rec = { items = Map[ItemsDoc.ItemId, Int32], gold = Int32 }

    enum BagOf(Rec)

    /// ふくろ（外では下の関数を通す）。
    pub type alias Bag = BagOf

    def rec(b: Bag): Rec = match b { case BagOf.BagOf(r) => r }

    /// 入れられる道具の種類の数。
    def maxKinds(): Int32 = 12

    /// 空のふくろと gold のお金。
    pub def withGold(gold: Int32): Bag = BagOf.BagOf({ items = Map.empty(), gold = Int32.max(0, gold) })

    /// 道具と個数とお金から（セーブから戻す・Starts の items=）。個数 0 以下の道具は持たない。
    pub def of(items: Map[ItemsDoc.ItemId, Int32], gold: Int32): Bag =
        BagOf.BagOf({ items = Map.filter(n -> n > 0, items), gold = Int32.max(0, gold) })

    pub def goldOf(b: Bag): Int32 = rec(b)#gold

    pub def countOf(item: ItemsDoc.ItemId, b: Bag): Int32 = Map.getWithDefault(item, 0, rec(b)#items)

    /// 持っている道具と個数（鍵の名前の順。セーブと flow の問いの並び）。
    pub def itemsOf(b: Bag): List[(ItemsDoc.ItemId, Int32)] = Map.toList(rec(b)#items)

    /// 画面に並べる順の道具と個数: 使う物 → ぶき → よろい → だいじなもの、同じ種類は値段の安い順（Doc から消えた道具は最後）。
    pub def listOf(items: ItemsDoc.Doc, b: Bag): List[(ItemsDoc.ItemId, Int32)] =
        itemsOf(b)
            |> List.map(entry -> (ItemsDoc.itemOf(items, fst(entry)) |> Option.map(item -> (kindRank(item#kind), item#price)) |> Option.getWithDefault((4, 0)), entry))
            |> List.sortBy(match ((rank, price), (id, _)) -> (rank, price, ItemsDoc.keyOf(id)))
            |> List.map(snd)

    def kindRank(kind: ItemsDoc.Kind): Int32 = match kind {
        case ItemsDoc.Kind.Use    => 0
        case ItemsDoc.Kind.Weapon => 1
        case ItemsDoc.Kind.Armor  => 2
        case ItemsDoc.Kind.Key    => 3
    }

    /// item を 1 つ入れられるか（もう持っている種類か、種類に空きがある）。
    pub def hasRoomFor(item: ItemsDoc.ItemId, b: Bag): Bool =
        Map.memberOf(item, rec(b)#items) or Map.size(rec(b)#items) < maxKinds()

    /// お金を足す（引いて 0 を下回る分は 0 で止める）。
    pub def addGold(amount: Int32, b: Bag): Bag = BagOf.BagOf({ gold = Int32.max(0, rec(b)#gold + amount) | rec(b) })

    /// 道具を count 個足す（引いて 0 以下になったら持たない）。
    pub def give(item: ItemsDoc.ItemId, count: Int32, b: Bag): Bag =
        let left = countOf(item, b) + count;
        let items = if (left > 0) Map.insert(item, left, rec(b)#items) else Map.remove(item, rec(b)#items);
        BagOf.BagOf({ items = items | rec(b) })

    /// 道具の Doc を読み直した後に収める: Doc から消えた道具を捨てる。
    pub def settle(items: ItemsDoc.Doc, b: Bag): Bag =
        BagOf.BagOf({ items = Map.filterWithKey((id, _) -> Option.nonEmpty(ItemsDoc.itemOf(items, id)), rec(b)#items) | rec(b) })
}
