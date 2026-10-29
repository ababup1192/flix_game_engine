// フィールドのメニューの決まり（ページの行き来・道具を使う・装備を替える・閉じた後の歩き）。
// 場面は村の (7, 8) から始め、取消のキーでメニューを開く。キーは実機と同じ道（App.trace）で 1/60 秒ずつ流す。
mod TestMenu {
    use fge::GameEngine.Key

    def village(args: Map[String, String]): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map.union(Map#{"map" => "village", "x" => "7", "y" => "8", "facing" => "up"}, args))

    /// メニューを開き、そうび（2 列 × 3 行の左下）→ 先頭の仲間 → ぶき と進んだ所の手。
    def toWeaponPick(): List[Set[Key]] =
        Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.down()) :::
        Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm())

    // ══════════════════════════════════════════════════════
    // ページ
    // ══════════════════════════════════════════════════════

    /// 取消は 1 つずつ前のページへ戻る: ぶきを選ぶ → ぶき / よろい → 誰の装備か → そうびにカーソルのある Root → 閉じて歩ける。
    @Test
    def testCancelStepsBackOnePageAtATime(): Unit \ Assert + Fs.FileRead =
        let pick = Fixtures.play(toWeaponPick(), village(Map.empty()));
        let slot = Fixtures.play(Fixtures.tap(Fixtures.cancel()), pick);
        let who = Fixtures.play(Fixtures.tap(Fixtures.cancel()), slot);
        let root = Fixtures.play(Fixtures.tap(Fixtures.cancel()), who);
        let closed = Fixtures.play(Fixtures.tap(Fixtures.cancel()), root);
        Assert.assertEq(expected = (Some(World.MenuPage.EquipSlot(Member.Member.Luka, 0)), Some(World.MenuPage.EquipWho(0)),
                                    Some(World.MenuPage.Root(4)), "Walking"),
            (Fixtures.menuPageOf(slot), Fixtures.menuPageOf(who), Fixtures.menuPageOf(root), Fixtures.layerOf(closed)))

    /// じゅもん（Root の右上）は灰色で、決定してもページは進まない。
    @Test
    def testSpellIsNotSelectable(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.right()) ::: Fixtures.tap(Fixtures.confirm()), village(Map.empty()));
        Assert.assertEq(expected = Some(World.MenuPage.Root(1)), Fixtures.menuPageOf(after))

    /// 下を押したままメニューを閉じても、下のキーを離すまでは歩き出さない。
    @Test
    def testClosingWhileHoldingADirectionDoesNotWalk(): Unit \ Assert + Fs.FileRead =
        let h = village(Map.empty());
        let opened = Fixtures.play(Fixtures.tap(Fixtures.cancel()), h);
        let after = Fixtures.play(Fixtures.hold(Fixtures.down(), 2) ::: Fixtures.tapWhileHolding(Fixtures.down(), Fixtures.cancel()) :::
                                  Fixtures.hold(Fixtures.down(), 30), opened);
        Assert.assertEq(expected = (Some((7, 8)), "Walking"), (Fixtures.heroOf(after) |> Option.map(fst), Fixtures.layerOf(after)))

    // ══════════════════════════════════════════════════════
    // どうぐ
    // ══════════════════════════════════════════════════════

    /// HP 1 のルカにやくそうを使うと、HP がやくそうの heal だけ戻り（最大で止まる）、やくそうは無くなる。
    @Test
    def testHerbHealsAndIsUsedUp(): Unit \ Assert + Fs.FileRead =
        let h = village(Map#{"hp" => "1", "items" => "yakusou:1"});
        let heal = Fixtures.itemOf("yakusou", h) |> Option.map(item -> item#heal);
        let after = Fixtures.play(Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.right()) :::
                                  Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), h);
        Assert.assertEq(expected = (heal |> Option.map(n -> Int32.min(1 + n, Fixtures.maxHpOf(Member.Member.Luka, h))), Some(0)),
            (Fixtures.hpOf(Member.Member.Luka, after), Fixtures.itemCountOf("yakusou", after)))

    /// メニューを開き、どうぐ（Root の右の 2 行目）→ ふくろの先頭 → 仲間の i 人目（下へ i 回）を選んで使う手。
    def useFirstItemOn(i: Int32): List[Set[Key]] =
        Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.right()) :::
        Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) :::
        List.flatten(List.repeat(i, Fixtures.tap(Fixtures.down()))) ::: Fixtures.tap(Fixtures.confirm())

    /// MP 0 のトト（3 人目）に まりょくのみ を使うと、MP が まりょくのみ の mpHeal だけ戻り、まりょくのみ は無くなる。
    @Test
    def testMagicNutRestoresMp(): Unit \ Assert + Fs.FileRead =
        let h = village(Map#{"party" => "luka,mina,toto", "mp" => "0", "items" => "maryoku:1"});
        let mpHeal = Fixtures.itemOf("maryoku", h) |> Option.map(item -> item#mpHeal);
        let after = Fixtures.play(useFirstItemOn(2), h);
        Assert.assertEq(expected = (mpHeal, Some(0)), (Fixtures.mpOf(Member.Member.Toto, after), Fixtures.itemCountOf("maryoku", after)))

    /// MP が最大のトトに まりょくのみ を使おうとすると、減らさずに「ひつようない」と知らせる。
    @Test
    def testMagicNutIsKeptWhenMpIsFull(): Unit \ Assert + Fs.FileRead =
        let h = village(Map#{"party" => "luka,mina,toto", "items" => "maryoku:1"});
        let after = Fixtures.play(useFirstItemOn(2), h);
        let name = PartyDoc.memberOf(Member.Member.Toto, h#resources#party)#name;
        Assert.assertEq(expected = (Some(1), Some(TextDoc.noticeText(TextDoc.NoticeText.NotNeeded, (TextDoc.Placeholder.Name, name) :: Nil, h#resources#text))),
            (Fixtures.itemCountOf("maryoku", after), Fixtures.typingTextOf(after)))

    // ══════════════════════════════════════════════════════
    // そうび
    // ══════════════════════════════════════════════════════

    /// ルカのぶきを どうのつるぎ に替えると、ひのきのぼう がふくろへ戻り、どうのつるぎ はふくろから出て、
    /// ちからが 2 つの atk の差だけ変わる。
    @Test
    def testEquipSwapsThroughTheBag(): Unit \ Assert + Fs.FileRead =
        let h = village(Map#{"items" => "dounotsurugi:1"});
        let sword = Fixtures.itemOf("dounotsurugi", h) |> Option.map(item -> item#atk);
        let stick = Fixtures.itemOf("hinoki", h) |> Option.map(item -> item#atk);
        let after = Fixtures.play(toWeaponPick() ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.confirm()), h);
        let atkBefore = Fixtures.atkOf(Member.Member.Luka, h);
        Assert.assertEq(expected = (Some(1), Some(0), Option.flatMap(s -> Option.map(t -> atkBefore + s - t, stick), sword)),
            (Fixtures.itemCountOf("hinoki", after), Fixtures.itemCountOf("dounotsurugi", after), Some(Fixtures.atkOf(Member.Member.Luka, after))))
}
