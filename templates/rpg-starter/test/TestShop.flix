// 道具屋・宿・セーブ・「つづきから」の決まり（お金とふくろの帳尻・全快・セーブの中身・再開の場所）。
// 店は道具屋の売り台の前（6, 5）から店の人に話して開き、宿は宿屋の帳場の前（7, 5）から宿の人に話して泊まる。
// キーは実機と同じ道（App.trace）で 1/60 秒ずつ流す。
mod TestShop {
    use fge::{Dir4}
    use fge::GameEngine.Key

    /// 道具屋の売り台の前で店の人と話し、あいさつを出し切って送り、店（かう / うる / やめる）を開いた所。
    def shopOpened(args: Map[String, String]): Fixtures.Run \ Fs.FileRead =
        let h = Fixtures.started("talk", Map.union(Map#{"node" => "Shopkeeper", "map" => "shop", "x" => "6", "y" => "5", "facing" => "up"}, args));
        Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), h)

    /// Top のカーソルのまま決定で品の一覧 → 先頭の品 → 個数（down の数だけ増やす）→ はい。
    def tradeFirst(more: Int32): List[Set[Key]] =
        Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) :::
        List.flatten(List.repeat(more, Fixtures.tap(Fixtures.down()))) :::
        Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm())

    /// 宿屋の帳場の前で宿の人と話し、問いを出し切って はい / いいえ を出し、はいを選んで、暗転が晴れるまで待った所。
    def stayedAtTheInn(args: Map[String, String]): Fixtures.Run \ Fs.FileRead =
        let h = Fixtures.started("talk", Map.union(Map#{"node" => "Innkeeper", "map" => "inn", "x" => "7", "y" => "5", "facing" => "up"}, args));
        Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(150), h)

    /// タイトルで下（つづきから）を選び、暗転が晴れるまで待った所。
    def continued(h: Fixtures.Run): Fixtures.Run =
        Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(30), h)

    // ══════════════════════════════════════════════════════
    // 道具屋
    // ══════════════════════════════════════════════════════

    /// 店の人に話して送ると、店が かう / うる / やめる の Top で開く。
    @Test
    def testShopkeeperOpensTheShop(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some(World.ShopPage.Top(0)), Fixtures.shopPageOf(shopOpened(Map.empty())))

    /// お金 0 では先頭の品（やくそう）を選んでも買えず、お金もふくろも変わらない。
    @Test
    def testBuyWithoutEnoughGoldChangesNothing(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(tradeFirst(0), shopOpened(Map#{"gold" => "0"}));
        Assert.assertEq(expected = (0, Some(0)), (Fixtures.goldOf(after), Fixtures.itemCountOf("yakusou", after)))

    /// やくそうを 2 つ買うと、お金が値段の 2 倍だけ減り、ふくろに 2 つ入る（お金 100 から）。
    @Test
    def testBuyPaysThePriceTimesTheCount(): Unit \ Assert + Fs.FileRead =
        let h = shopOpened(Map#{"gold" => "100"});
        let price = Fixtures.itemOf("yakusou", h) |> Option.map(item -> item#price);
        let after = Fixtures.play(tradeFirst(1), h);
        Assert.assertEq(expected = (price |> Option.map(p -> 100 - 2 * p), Some(2)),
            (Some(Fixtures.goldOf(after)), Fixtures.itemCountOf("yakusou", after)))

    /// やくそうを 1 つ売ると、お金が値段の半分（切り捨て）だけ増え、ふくろから無くなる（お金 0 から）。
    @Test
    def testSellPaysHalfThePrice(): Unit \ Assert + Fs.FileRead =
        let h = shopOpened(Map#{"gold" => "0", "items" => "yakusou:1"});
        let price = Fixtures.itemOf("yakusou", h) |> Option.map(item -> item#price);
        let after = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: tradeFirst(0), h);
        Assert.assertEq(expected = (price |> Option.map(p -> p / 2), Some(0)),
            (Some(Fixtures.goldOf(after)), Fixtures.itemCountOf("yakusou", after)))

    /// やめるで店を閉じると、店の人の会話の続き（あいさつの次の台詞）へ戻る。
    @Test
    def testLeavingTheShopResumesTheTalk(): Unit \ Assert + Fs.FileRead =
        let h = shopOpened(Map.empty());
        let after = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(2), h);
        Assert.assertEq(expected = ("Talk", Some("Shopkeeper")), (Fixtures.layerOf(after), Fixtures.talkNodeOf(after)))

    // ══════════════════════════════════════════════════════
    // 宿とセーブ
    // ══════════════════════════════════════════════════════

    /// HP 1 で泊まると全快し、セーブを書く合図（saveRev）が 1 進み、セーブの中身（書く字）は泊まった後の World の中身。
    @Test
    def testInnRestoresAndWritesTheSave(): Unit \ Assert + Fs.FileRead =
        let after = stayedAtTheInn(Map#{"gold" => "100", "hp" => "1"});
        Assert.assertEq(expected = (Some(Fixtures.maxHpOf(Member.Member.Luka, after)), 1, Some(Saves.toText(World.saveDataOf(after#world)))),
            (Fixtures.hpOf(Member.Member.Luka, after), after#world#saveRev, after#world#save |> Option.map(Saves.toText)))

    /// 泊まると宿代（rpg.shops.json の innPrice）だけお金が減る（お金 100 から）。
    @Test
    def testInnChargesTheInnPrice(): Unit \ Assert + Fs.FileRead =
        let after = stayedAtTheInn(Map#{"gold" => "100"});
        Assert.assertEq(expected = 100 - ShopsDoc.rec(after#resources#shops)#innPrice, Fixtures.goldOf(after))

    /// 宿代に足りない（お金 0）と、断られて泊まらない（HP 1 のまま・セーブは書かない）。
    @Test
    def testInnWithoutEnoughGoldDoesNotRest(): Unit \ Assert + Fs.FileRead =
        let after = stayedAtTheInn(Map#{"gold" => "0", "hp" => "1"});
        Assert.assertEq(expected = (Some(1), 0), (Fixtures.hpOf(Member.Member.Luka, after), after#world#saveRev))

    /// セーブの中身は JSON の字にして読み戻すと同じ（仲間 2 人・道具・お金・依頼の段階・乱数の回数。比べるのは書く字どうし）。
    @Test
    def testSaveRoundTripsThroughJson(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"party" => "luka,mina", "quest" => "accepted", "gold" => "120",
                                               "items" => "yakusou:3,dounotsurugi:1", "seed" => "10", "hp" => "5"});
        let data = World.saveDataOf(h#world);
        Assert.assertEq(expected = Ok(Saves.toText(data)), Saves.fromText(h#resources#items, h#resources#maps, Saves.toText(data)) |> Result.map(Saves.toText))

    /// 名前付きの旗はセーブの JSON を往復しても立ったまま（Starts の flags= で立てた旗）。
    @Test
    def testFlagSurvivesTheSave(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"flags" => "lever"});
        let back = Saves.fromText(h#resources#items, h#resources#maps, Saves.toText(World.saveDataOf(h#world)));
        Assert.assertEq(expected = Ok(true), back |> Result.map(data -> Progress.isFlagSet(Fixtures.flagId("lever"), Saves.rec(data)#progress)))

    // ══════════════════════════════════════════════════════
    // つづきから
    // ══════════════════════════════════════════════════════

    /// 壊れたセーブを読んで起動すると「つづきから」は選べず、下を押してもカーソルは「はじめから」のまま。
    @Test
    def testBrokenSaveCannotBeContinued(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.launchedWith(Saves.fromText(ItemsDoc.load(ItemsDoc.path()), MapDoc.loadTable(ItemsDoc.load(ItemsDoc.path())), "{ broken") |> Result.toOption);
        Assert.assertEq(expected = Some(World.TitleItem.NewGame), Fixtures.titleCursorOf(Fixtures.play(Fixtures.tap(Fixtures.down()), h)))

    /// 「つづきから」は宿の前（rules の homeMap・homeX・homeY）に下を向いて立つ。
    @Test
    def testContinueStandsInFrontOfTheInn(): Unit \ Assert + Fs.FileRead =
        let after = continued(Fixtures.started("title", Map#{"saved" => "yes"}));
        let rules = RulesDoc.rec(after#resources#rules);
        Assert.assertEq(expected = (Some(rules#homeMap), Some(((rules#homeX, rules#homeY), Dir4.Dir4.Down)), "Walking"),
            (Fixtures.mapOf(after), Fixtures.heroOf(after), Fixtures.layerOf(after)))

    /// 宿で泊まってから起動し直して「つづきから」を選ぶと、泊まった時のお金と道具と仲間で遊べる。
    @Test
    def testContinueRestoresWhatTheInnSaved(): Unit \ Assert + Fs.FileRead =
        let stayed = stayedAtTheInn(Map#{"gold" => "100", "items" => "yakusou:4", "party" => "luka,mina", "quest" => "accepted"});
        let after = continued(Fixtures.relaunch(stayed));
        Assert.assertEq(expected = (Fixtures.goldOf(stayed), Some(4), Member.Member.Luka :: Member.Member.Mina :: Nil, Progress.Quest.Accepted),
            (Fixtures.goldOf(after), Fixtures.itemCountOf("yakusou", after), Fixtures.membersOf(after), Fixtures.questOf(after)))
}
