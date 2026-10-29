// じゅもん・どうぐ・眠り（戦いとフィールド）の決まりと、呪文の Doc の橋渡し。
mod TestMagic {
    use fge::Resources

    /// 仲間 members を Lv lv で組む（HP と MP は最大・装備は Doc の初めの物）。
    def partyAt(res: Res.Res, members: List[Member.Member], lv: Int32): Party.Party =
        members |> List.foldLeft((p, m) -> Party.join(res#party, res#items, m, p), Party.empty()) |> Party.atLevel(res#party, lv)

    def nameOf(res: Res.Res, m: Member.Member): String = PartyDoc.memberOf(m, res#party)#name

    def line(res: Res.Res, text: TextDoc.BattleText, values: List[(TextDoc.Placeholder, String)]): String = TextDoc.battleText(text, values, res#text)

    /// コケだまの技を act だけにし、眠りの率を rules の sleepRate = wakeRate = 1.0（必ず効く・起きられる時は必ず起きる）にした描く元。
    def sleepyRes(act: String): Option[Res.Res] \ Fs.FileRead =
        let base = Res.load();
        forM (
            rules <- RulesDoc.fromJson("{\"version\":1,\"sleepRate\":1.0,\"wakeRate\":1.0}");
            moves <- FoeMovesDoc.fromJson("{\"version\":1,\"moves\":[{\"foe\":\"koke\",\"phase\":1,\"act\":\"${act}\",\"weight\":1}]}")
        ) yield Res.withFoeMoves(moves, Res.withRules(rules, base))

    // ══════════════════════════════════════════════════════
    // じゅもん（戦い）
    // ══════════════════════════════════════════════════════

    /// MP が足りない呪文は選べない: MP 0 のトトが じゅもん → ファイア を決めても、呪文の一覧のまま。
    /// 決定 2 回で現れたを送り、ルカとミナは たたかう（決定 2 回ずつ）、トトは下で じゅもん → 決定 → 決定。
    @Test
    def testSpellShortOfMpCannotBeChosen(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "koke", "party" => "luka,mina,toto", "mp" => "0"});
        let c = Fixtures.tap(Fixtures.confirm());
        let keys = List.flatten(c :: c :: c :: c :: c :: c :: Fixtures.tap(Fixtures.down()) :: c :: c :: Nil);
        Assert.assertEq(expected = Some((Member.Member.Toto, World.CommandPage.SpellList(0))), WorldBattle.choosingOf(Fixtures.play(keys, h)#world))

    /// 敵全部の呪文（アイス）は生きている敵全部の HP を減らす（コケだま 3 体。アイスの力ではどれも倒れない）。
    @Test
    def testIceHitsEveryLivingFoe(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let koke = Fixtures.foeId(res, "koke");
        let b = Battle.start(res, koke :: koke :: koke :: Nil, partyAt(res, Member.Member.Toto :: Nil, 5), Bag.withGold(0));
        let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Toto => Battle.Plan.Cast(Fixtures.spellId(res, "ice"), Battle.Target.AllFoes)}, 0);
        let full = FoesDoc.foeOrBlank(res#foes, koke)#hp;
        Assert.assertEq(expected = false, Fixtures.foeHpsOf(after) |> List.exists(hp -> hp >= full))

    /// ヒールは最大 HP で止まる: 最大より 1 少ないルカ（Lv4 でヒールを覚える）に唱えると最大になる（敵は guard だけ）。
    @Test
    def testHealStopsAtMaxHp(): Unit \ Assert + Fs.FileRead =
        let found = sleepyRes("guard") |> Option.map(res -> {
            let party0 = partyAt(res, Member.Member.Luka :: Nil, 4);
            let top = Party.maxHpOf(res#party, Member.Member.Luka, party0);
            let party = Party.withHp(res#party, Member.Member.Luka, top - 1, party0);
            let b = Battle.start(res, Fixtures.foeId(res, "koke") :: Nil, party, Bag.withGold(0));
            let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.Cast(Fixtures.spellId(res, "heal"), Battle.Target.Ally(Member.Member.Luka))}, 0);
            (top, Fixtures.allyHpsOf(after))
        });
        Assert.assertEq(expected = found |> Option.map(pair -> fst(pair) :: Nil), found |> Option.map(snd))

    /// 唱えると MP が呪文の mp だけ減る（トト Lv2 のファイア）。
    @Test
    def testCastingSpendsMp(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let party = partyAt(res, Member.Member.Toto :: Nil, 2);
        let b = Battle.start(res, Fixtures.foeId(res, "koke") :: Nil, party, Bag.withGold(0));
        let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Toto => Battle.Plan.Cast(Fixtures.spellId(res, "fire"), Battle.Target.Foe(0))}, 0);
        Assert.assertEq(expected = Party.maxMpOf(res#party, Member.Member.Toto, party) - Fixtures.spellOf(res, "fire")#mp,
            Party.mpOf(Member.Member.Toto, Battle.rec(after)#party))

    /// Lv をまたいで覚えた呪文は、レベルアップの後に 1 枚ずつ伝言になる（トト Lv2 がジェムイーターの経験値で Lv5 へ: ヒールとアイス）。
    @Test
    def testLearnedSpellsAreAnnounced(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let b = Battle.start(res, Fixtures.foeId(res, "gemeater") :: Nil, partyAt(res, Member.Member.Toto :: Nil, 2), Bag.withGold(0));
        let (_, beats) = Battle.resolveVictory(res, b);
        let learned = key -> line(res, TextDoc.BattleText.Learned, (TextDoc.Placeholder.Name, nameOf(res, Member.Member.Toto)) ::
                                  (TextDoc.Placeholder.Spell, Fixtures.spellOf(res, key)#name) :: Nil) :: Nil;
        let transcript = Fixtures.transcriptOf(res, beats);
        Assert.assertEq(expected = (true, true), (List.memberOf(learned("heal"), transcript), List.memberOf(learned("ice"), transcript)))

    // ══════════════════════════════════════════════════════
    // どうぐ（戦い）
    // ══════════════════════════════════════════════════════

    /// 戦いで使った道具は戦いのふくろから 1 つ減る（やくそう 2 → 1）。
    @Test
    def testUsedItemIsOneLess(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let herb = Fixtures.itemId(res, "yakusou");
        let b = Battle.start(res, Fixtures.foeId(res, "koke") :: Nil, partyAt(res, Member.Member.Luka :: Nil, 1), Bag.give(herb, 2, Bag.withGold(0)));
        let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.UseItem(herb, Battle.Target.Ally(Member.Member.Luka))}, 0);
        Assert.assertEq(expected = 1, Bag.countOf(herb, Battle.rec(after)#bag))

    /// 戦いのどうぐの一覧で、せいすいは灰色・やくそうは選べる（並びは使う物の値段の安い順）。
    @Test
    def testHolyWaterIsGreyInBattle(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "koke", "items" => "seisui:1,yakusou:1"});
        let res = h#resources;
        Assert.assertEq(expected = Some((Fixtures.itemId(res, "yakusou"), true) :: (Fixtures.itemId(res, "seisui"), false) :: Nil),
            Fixtures.battleOf(h) |> Option.map(WorldBattle.itemChoicesOf(res)))

    /// burn の道具（ばくだんいし）は敵 1 体に burn のダメージを、まもりもぶれも無しで与える。
    @Test
    def testBombDealsItsBurn(): Unit \ Assert + Fs.FileRead =
        let found = forM (
            res <- sleepyRes("guard");
            item <- ItemsDoc.itemOf(res#items, Fixtures.itemId(res, "bakudanishi"))
        ) yield {
            let bomb = Fixtures.itemId(res, "bakudanishi");
            let goblin = Fixtures.foeId(res, "goblin");
            let b = Battle.start(res, goblin :: Nil, partyAt(res, Member.Member.Luka :: Nil, 1), Bag.give(bomb, 1, Bag.withGold(0)));
            let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.UseItem(bomb, Battle.Target.Foe(0))}, 0);
            (FoesDoc.foeOrBlank(res#foes, goblin)#hp - item#burn, Fixtures.foeHpsOf(after))
        };
        Assert.assertEq(expected = found |> Option.map(pair -> fst(pair) :: Nil), found |> Option.map(snd))

    /// 勝ってフィールドへ戻ると、戦いで減った道具は World のふくろにも減ったまま書き戻る（やくそう 1 → 0）。
    /// 決定 2 回で現れたを送り、ルカ（Lv5）は どうぐ（下 2 つ）→ やくそう → ルカ、あとは決定で送る。
    @Test
    def testUsedItemIsWrittenBackOnWin(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "kusausa", "lv" => "5", "items" => "yakusou:1"});
        let c = Fixtures.tap(Fixtures.confirm());
        let d = Fixtures.tap(Fixtures.down());
        let after = Fixtures.play(List.flatten(c :: c :: d :: d :: c :: c :: c :: Fixtures.confirmEach(12) :: Nil), h);
        Assert.assertEq(expected = (World.SceneKind.Field, 0), (World.sceneKindOf(after#world), Fixtures.bagCountOf(Fixtures.itemId(h#resources, "yakusou"), after)))

    // ══════════════════════════════════════════════════════
    // 眠り
    // ══════════════════════════════════════════════════════

    /// 眠った人は選ぶ人から外れ、眠った次の自分の手番は（wakeRate = 1.0 でも）必ず眠り、その次の手番で起きる。
    /// ルカ（Lv10）はコケだまより速いので、1 ターン目は ぼうぎょ の後に眠らされる。
    @Test
    def testSleeperSkipsChoosingAndSleepsOneTurn(): Unit \ Assert + Fs.FileRead =
        let found = sleepyRes("sleep") |> Option.map(res -> {
            let b0 = Battle.start(res, Fixtures.foeId(res, "koke") :: Nil, partyAt(res, Member.Member.Luka :: Nil, 10), Bag.withGold(0));
            let (b1, _, d1) = BattleActs.resolveRound(res, b0, Map#{Member.Member.Luka => Battle.Plan.Defend}, 0);
            let (b2, beats2, d2) = BattleActs.resolveRound(res, b1, Map.empty(), d1);
            let (_, beats3, _) = BattleActs.resolveRound(res, b2, Map.empty(), d2);
            let luka = (TextDoc.Placeholder.Name, nameOf(res, Member.Member.Luka)) :: Nil;
            (Battle.choosersOf(b1),
             List.memberOf(line(res, TextDoc.BattleText.Asleep, luka) :: Nil, Fixtures.transcriptOf(res, beats2)),
             List.memberOf(line(res, TextDoc.BattleText.Woke, luka) :: Nil, Fixtures.transcriptOf(res, beats3)))
        });
        Assert.assertEq(expected = Some((Nil, true, true)), found)

    /// 仲間が全員眠っても戦いは止まらない: 1 ターンの伝言を送り切ると、コマンドを待たずに敵だけのターンが流れる
    /// （眠ったルカの「ねむっている」から始まる）。
    @Test
    def testAllAsleepStillFights(): Unit \ Assert + Fs.FileRead =
        let h0 = Fixtures.started("battle", Map#{"foes" => "koke", "lv" => "10"});
        let found = sleepyRes("sleep") |> Option.map(res -> {
            let b0 = Battle.start(res, Fixtures.foeId(res, "koke") :: Nil, partyAt(res, Member.Member.Luka :: Nil, 10), Bag.withGold(0));
            let (b1, _, d1) = BattleActs.resolveRound(res, b0, Map#{Member.Member.Luka => Battle.Plan.Defend}, 0);
            let judged = World.mapBattle(r -> { battle = b1, phase = World.Phase.Show(Battle.openingOf(b1), Nil, World.now(h0#world), World.AfterShow.Judge) | r },
                                         { dice = d1 | h0#world });
            let c = Fixtures.tap(Fixtures.confirm());
            let after = Fixtures.play(List.flatten(c :: c :: Nil), Resources.of(res, judged));
            let current = Fixtures.battleOf(after) |> Option.flatMap(WorldBattle.currentBeatOf) |> Option.map(pair -> Fixtures.beatLinesOf(res, fst(pair)));
            let asleep = line(res, TextDoc.BattleText.Asleep, (TextDoc.Placeholder.Name, nameOf(res, Member.Member.Luka)) :: Nil);
            ((WorldBattle.choosingOf(after#world), current), (None, Some(asleep :: Nil)))
        });
        Assert.assertEq(expected = found |> Option.map(snd), found |> Option.map(fst))

    // ══════════════════════════════════════════════════════
    // じゅもん（フィールド）
    // ══════════════════════════════════════════════════════

    /// フィールドのメニューの じゅもん → トト → ヒール → ルカ: ルカの HP が power だけ戻り（最大で止める）、トトの MP が mp だけ減る。
    /// メニューは取消で開き、右で じゅもん・下 2 つでトト・下 1 つでヒール（覚えた順: ファイア・ヒール）。
    @Test
    def testFieldHealSpendsMpAndHeals(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8", "party" => "luka,mina,toto", "quest" => "accepted", "lv" => "3", "hp" => "10"});
        let c = Fixtures.tap(Fixtures.confirm());
        let d = Fixtures.tap(Fixtures.down());
        let keys = List.flatten(Fixtures.tap(Fixtures.cancel()) :: Fixtures.tap(Fixtures.right()) :: c :: d :: d :: c :: d :: c :: c :: Nil);
        let after = Fixtures.play(keys, h);
        let heal = Fixtures.spellOf(h#resources, "heal");
        let topMp = Party.maxMpOf(h#resources#party, Member.Member.Toto, h#world#party);
        Assert.assertEq(expected = (Some(Int32.min(10 + heal#power, Fixtures.maxHpOf(Member.Member.Luka, h))), Some(topMp - heal#mp)),
            (Fixtures.hpOf(Member.Member.Luka, after), Fixtures.mpOf(Member.Member.Toto, after)))

    /// じゅもん は誰も呪文を覚えていなければ灰色（ルカ Lv1 とミナ）、トトが加わると選べる。
    @Test
    def testSpellMenuOpensWithASpellCaster(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        Assert.assertEq(expected = (false, true),
            (WorldMenu.isRootOpen(res, partyAt(res, Member.Member.Luka :: Member.Member.Mina :: Nil, 1), WorldMenu.RootItem.Spell),
             WorldMenu.isRootOpen(res, partyAt(res, Member.Member.Luka :: Member.Member.Toto :: Nil, 1), WorldMenu.RootItem.Spell)))

    // ══════════════════════════════════════════════════════
    // SpellsDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None（SpellsDoc.load はそこで呪文の無い表へ落ちる）。
    @Test
    def testSpellsBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, SpellsDoc.fromJson("{ broken") |> Option.map(doc -> SpellsDoc.keysOf(doc)))

    /// name と mp だけの行は、書いた欄が効き、残りは既定（力 0・敵 1 体・戦いだけ）。
    @Test
    def testSpellsRowWithOnlyNameAndMp(): Unit \ Assert =
        Assert.assertEq(expected = Some((7, 0, SpellsDoc.Aim.Foe, false)),
            SpellsDoc.fromJson("{\"version\":1,\"spells\":{\"a\":{\"name\":\"A\",\"mp\":7}}}")
                |> Option.flatMap(doc -> SpellsDoc.idOf(doc, "a") |> Option.flatMap(SpellsDoc.spellOf(doc)))
                |> Option.map(s -> (s#mp, s#power, s#aim, s#field)))

    /// 呪文の表は行に追随し、読めない行（aim が知らない名前の b）だけ飛ばして問題に挙げる。
    @Test
    def testSpellsFollowTheRows(): Unit \ Assert =
        let text = "{\"version\":1,\"spells\":{\"a\":{\"name\":\"A\"},\"b\":{\"name\":\"B\",\"aim\":\"sky\"},\"c\":{\"name\":\"C\",\"aim\":\"ally\"}}}";
        Assert.assertEq(expected = Some(("a" :: "c" :: Nil, 1)),
            SpellsDoc.fromJson(text) |> Option.map(doc -> (SpellsDoc.keysOf(doc), List.length(SpellsDoc.rec(doc)#problems))))
}
