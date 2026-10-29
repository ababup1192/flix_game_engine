// ボス・帰村・報告・エンディング: ジェムイーターの固定の戦い（逃げられない・HP 半分で phase 2）・勝ちのノードと <<warp>>・
// 依頼の段階で出る人と小物・報告のお礼・エンディングからタイトルへ。場所の数（マス）は assets/maps の mine_b3・village の行と同じ。
mod TestBoss {
    use fge::{Dir4, Resources}

    /// B3 の開いた扉のマス（16, 5）で、奥のジェムイーターの方を向いて立った所（args は足す・上書きする引数）。
    def atBossDoor(more: Map[String, String]): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map.union(more, Map#{"map" => "mine_b3", "x" => "16", "y" => "5", "facing" => "up",
                                                       "party" => "luka,mina,toto", "quest" => "accepted", "steps" => "999", "opened" => "b3_door"}))

    /// 村の泉の上の村長の右（8, 5）で、村長の方を向いて立った所。
    def atSpring(quest: String, gold: String): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map#{"map" => "village", "x" => "8", "y" => "5", "facing" => "left",
                                      "party" => "luka,mina,toto", "quest" => quest, "gold" => gold})

    /// 泉の上の村長（chief_spring）に話しかけ、決定を n 回送った所。
    def reportWith(n: Int32, h: Fixtures.Run): Fixtures.Run =
        Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(60) ::: Fixtures.confirmEach(n), h)

    // ══════════════════════════════════════════════════════
    // ボスの戦い
    // ══════════════════════════════════════════════════════

    /// 扉の奥のジェムイーター（guard・b3_boss）を調べると Boss の会話が開き、台詞を送ると逃げられない戦いが始まる（勝ちのノードは BossWon）。
    @Test
    def testBossTalkStartsTheBossFight(): Unit \ Assert + Fs.FileRead =
        let after = reportWith(6, atBossDoor(Map.empty()));
        let res = after#resources;
        Assert.assertEq(expected = Some((Some("BossWon"), true, 1)),
            Fixtures.battleOf(after) |> Option.map(r -> (r#afterWin, Battle.isNoFlee(res, r#battle), List.length(Battle.aliveFoes(r#battle)))))

    /// ボスの HP が phase2At を切った手番の後のターンから phase 2 の技を選ぶ。
    /// HP をばくだんいし 3 発ぶん + 1 にすると、2 発目の後に残る 1 発ぶん + 1 が HP の半分（phase2At = 0.5）を切り、3 発目でも倒れない。
    /// 技を phase 1 = attack・phase 2 = sweep にし、ルカが毎ターン 1 発投げる: 1・2 ターン目は attack（技はターンの頭に引く）、3 ターン目に sweep。
    @Test
    def testBossSwitchesToPhaseTwoAfterHalfHp(): Unit \ Assert + Fs.FileRead =
        let base = Res.load();
        let bomb = Fixtures.itemId(base, "bakudanishi");
        let foesJson = burn -> "{\"version\":1,\"foes\":{\"gemeater\":{\"name\":\"ジェムイーター\",\"sprite\":\"boss\",\"hp\":${3 * burn + 1},\"atk\":1,\"def\":0,\"agi\":1,\"noFlee\":true,\"phase2At\":0.5}}}";
        let movesJson = "{\"version\":1,\"moves\":[{\"foe\":\"gemeater\",\"phase\":1,\"act\":\"attack\",\"weight\":1},{\"foe\":\"gemeater\",\"phase\":2,\"act\":\"sweep\",\"weight\":1}]}";
        let sweeps = forM (
            item <- Fixtures.itemOf("bakudanishi", Fixtures.started("title", Map.empty()));
            foes <- FoesDoc.fromJson(foesJson(item#burn));
            moves <- FoeMovesDoc.fromJson(movesJson)
        ) yield {
            let res = Res.withFoeMoves(moves, Res.withFoes(foes, base));
            let party = Party.join(res#party, res#items, Member.Member.Luka, Party.empty()) |> Party.atLevel(res#party, 10);
            let b0 = Battle.start(res, Fixtures.foeId(res, "gemeater") :: Nil, party, Bag.give(bomb, 3, Bag.withGold(0)));
            let plans = Map#{Member.Member.Luka => Battle.Plan.UseItem(bomb, Battle.Target.Foe(0))};
            let sweep = TextDoc.battleText(TextDoc.BattleText.Sweep, (TextDoc.Placeholder.Name, "ジェムイーター") :: Nil, res#text);
            let swept = beats -> List.memberOf(sweep, List.flatten(Fixtures.transcriptOf(res, beats)));
            let (b1, beats1, d1) = BattleActs.resolveRound(res, b0, plans, 0);
            let (b2, beats2, d2) = BattleActs.resolveRound(res, b1, plans, d1);
            let (_, beats3, _) = BattleActs.resolveRound(res, b2, plans, d2);
            (swept(beats1), swept(beats2), swept(beats3))
        };
        Assert.assertEq(expected = Some((false, false, true)), sweeps)

    /// ボスに負けると宿の前で全快し、段階は accepted のまま・ボスも残る。もう一度扉の奥で調べると、また戦いが始まる。
    @Test
    def testBossCanBeFoughtAgainAfterAWipe(): Unit \ Assert + Fs.FileRead =
        let wiped = reportWith(40, atBossDoor(Map#{"party" => "luka", "lv" => "1", "hp" => "1"}));
        let res = wiped#resources;
        let back = MapDoc.idOf(res#maps, "mine_b3")
            |> Option.map(b3 -> Resources.of(res, World.placeField(b3, { x = 16, y = 5 }, Dir4.Dir4.Up, wiped#world)));
        let again = back |> Option.map(h -> reportWith(6, h));
        Assert.assertEq(expected = (Some("village"), Quest.Quest.Accepted, Some(false), Some("Battle")),
            (Fixtures.mapOf(wiped), Fixtures.questOf(wiped), Fixtures.isOpenedOf("mine_b3", "b3_boss", wiped),
             again |> Option.map(h -> "${World.sceneKindOf(h#world)}")))

    // ══════════════════════════════════════════════════════
    // 勝った後: BossWon と <<warp>>
    // ══════════════════════════════════════════════════════

    /// 勝ちのノード BossWon を送り切ると、段階が bossdown になり、ボスが消え、歩いては通らない出口 to_surface で坑道の入口
    /// （ワールドマップの to_surface の行き先のマス）へ移る。
    @Test
    def testBossWonWarpsToTheMineEntrance(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("talk", Map#{"node" => "BossWon", "map" => "mine_b3", "x" => "16", "y" => "5", "facing" => "up",
                                             "party" => "luka,mina,toto", "quest" => "accepted", "opened" => "b3_door"});
        let after = Fixtures.play(Fixtures.confirmEach(8), h);
        let arrival = Fixtures.exitOf("mine_b3", "to_surface", h) |> Option.map(e -> (e#to, (e#spawnX, e#spawnY)));
        Assert.assertEq(expected = (Quest.Quest.BossDown, Some(true), arrival),
            (Fixtures.questOf(after), Fixtures.isOpenedOf("mine_b3", "b3_boss", after),
             Fixtures.mapOf(after) |> Option.flatMap(map -> Fixtures.heroOf(after) |> Option.map(hero -> (map, fst(hero))))))

    /// 歩いては通らない出口（edge = none）はどのマスにも置かれない（着いても端から出ても移らない）。
    @Test
    def testNowhereExitHasNoCell(): Unit \ Assert + Fs.FileRead =
        let h = atBossDoor(Map.empty());
        Assert.assertEq(expected = Some(None), Fixtures.exitOf("mine_b3", "to_surface", h) |> Option.map(MapDoc.cellOf))

    // ══════════════════════════════════════════════════════
    // 依頼の段階で出る人と小物
    // ══════════════════════════════════════════════════════

    /// 泉の上（7, 5）の村長と、泉の右（9, 6）の人は段階で入れ替わる: 依頼の間は村長が居らず長老が立ち、ボスを倒した後は村長と子どもが立つ。
    @Test
    def testVillagePeopleChangeAfterTheBoss(): Unit \ Assert + Fs.FileRead =
        let idAt = (x, y, h) -> Fixtures.npcAt("village", x, y, h) |> Option.map(npc -> npc#id);
        let before = atSpring("accepted", "0");
        let after = atSpring("bossdown", "0");
        Assert.assertEq(expected = ((None, Some("elder")), (Some("chief_spring"), Some("child_spring"))),
            ((idAt(7, 5, before), idAt(9, 6, before)), (idAt(7, 5, after), idAt(9, 6, after))))

    /// 枯れた泉はボスを倒すまで、水の戻った泉はボスを倒した後から出る（小物の questUntil / questFrom。大きな木はいつでも）。
    @Test
    def testSpringPropFollowsTheQuest(): Unit \ Assert + Fs.FileRead =
        let h = atSpring("accepted", "0");
        Assert.assertEq(expected = (Some("spring_dry" :: "big_tree" :: Nil), Some("spring_full" :: "big_tree" :: Nil), Some("spring_full" :: "big_tree" :: Nil)),
            (Fixtures.propSpritesOf("village", Quest.Quest.Accepted, h), Fixtures.propSpritesOf("village", Quest.Quest.BossDown, h),
             Fixtures.propSpritesOf("village", Quest.Quest.Reported, h)))

    /// 人の questFrom に知らない段階の名前を書いた行は読めない扱いで飛ばし、問題に挙げる（書き損じで早く出ない）。
    @Test
    def testUnknownQuestNameSkipsTheRow(): Unit \ Assert =
        let text = "{\"version\":1, \"rows\":[\"...\"], \"npcs\":[" +
            "{\"id\":\"a\", \"sprite\":\"woman\", \"x\":0, \"y\":0, \"questFrom\":\"bossdown\"}," +
            "{\"id\":\"b\", \"sprite\":\"child\", \"x\":1, \"y\":0, \"questFrom\":\"finished\"}]}";
        Assert.assertEq(expected = Some((1, "[map] x の npcs の 2 行目を読めないので飛ばす" :: Nil)),
            MapDoc.fromJson(ItemsDoc.defaults(), "x", text) |> Option.map(doc -> (List.length(MapDoc.rec(doc)#npcs), MapDoc.rec(doc)#problems)))

    // ══════════════════════════════════════════════════════
    // 報告とお礼
    // ══════════════════════════════════════════════════════

    /// ボスを倒した後に泉の上の村長へ話すと、段階が reported になり、お金が rules の reward だけ増える。
    @Test
    def testReportPaysTheReward(): Unit \ Assert + Fs.FileRead =
        let after = reportWith(2, atSpring("bossdown", "100"));
        Assert.assertEq(expected = (Quest.Quest.Reported, 100 + RulesDoc.rec(after#resources#rules)#reward), (Fixtures.questOf(after), Fixtures.goldOf(after)))

    /// ボスを倒す前の <<quest report>> は段階もお金も変えない（前の段階が bossdown の時だけ進む）。
    @Test
    def testReportBeforeTheBossDoesNothing(): Unit \ Assert + Fs.FileRead =
        let opened = Fixtures.openTree(Fixtures.command("quest", "report") + "," + Fixtures.line("x"), atSpring("accepted", "100"));
        Assert.assertEq(expected = Some((Quest.Quest.Accepted, 100)), opened |> Option.map(h -> (Fixtures.questOf(h), Fixtures.goldOf(h))))

    /// 報告の台詞のお礼の額は $reward（rules の reward）で埋まる。
    @Test
    def testRewardLineShowsTheRuleValue(): Unit \ Assert + Fs.FileRead =
        let after = reportWith(2, atSpring("bossdown", "0"));
        let reward = RulesDoc.rec(after#resources#rules)#reward;
        Assert.assertEq(expected = Some(true), Fixtures.lineTextOf(after) |> Option.map(text -> String.contains(substr = "${reward}G", text)))

    // ══════════════════════════════════════════════════════
    // エンディング
    // ══════════════════════════════════════════════════════

    /// 報告を送り切ると暗転してエンディングに入る（セーブは書かない）。
    @Test
    def testReportEndsInTheEnding(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.idle(120), reportWith(10, atSpring("bossdown", "0")));
        Assert.assertEq(expected = ("Ending", 0), ("${World.sceneKindOf(after#world)}", after#world#saveRev))

    /// <<ending>> の後、スタッフの字が流れている間の決定ではタイトルへ戻らず、rules の creditSeconds を過ぎた後の決定で戻る。
    @Test
    def testEndingReturnsToTitleAfterTheCredits(): Unit \ Assert + Fs.FileRead =
        let opened = Fixtures.openTree(Fixtures.bareCommand("ending"), atSpring("reported", "0"));
        let ending = opened |> Option.map(h -> Fixtures.play(Fixtures.idle(120), h));
        let early = ending |> Option.map(h -> Fixtures.play(Fixtures.tap(Fixtures.confirm()), h));
        let wait = ending |> Option.flatMap(h -> Fixtures.framesOf(RulesDoc.rec(h#resources#rules)#creditSeconds));
        let late = forM (h <- early; n <- wait) yield Fixtures.play(Fixtures.idle(n) ::: Fixtures.tap(Fixtures.confirm()), h);
        let kindOf = h -> "${World.sceneKindOf(h#world)}";
        Assert.assertEq(expected = (Some("Ending"), Some("Title")), (early |> Option.map(kindOf), late |> Option.map(kindOf)))

    /// rules の creditSkipAfter 秒の後、字が流れている間の決定は字を流れ切った所まで早送りし（エンディングのまま）、
    /// もう一度の決定でタイトルへ戻る。
    @Test
    def testConfirmFastForwardsTheCreditsThenReturnsToTitle(): Unit \ Assert + Fs.FileRead =
        let opened = Fixtures.openTree(Fixtures.bareCommand("ending"), atSpring("reported", "0"));
        let ending = opened |> Option.map(h -> Fixtures.play(Fixtures.idle(120), h));
        let guard = ending |> Option.flatMap(h -> Fixtures.framesOf(RulesDoc.rec(h#resources#rules)#creditSkipAfter));
        let skipped = forM (h <- ending; n <- guard) yield Fixtures.play(Fixtures.idle(n) ::: Fixtures.tap(Fixtures.confirm()), h);
        let again = skipped |> Option.map(h -> Fixtures.play(Fixtures.idle(2) ::: Fixtures.tap(Fixtures.confirm()), h));
        Assert.assertEq(expected = (Some(1.0), Some("Title")),
            (skipped |> Option.map(h -> WorldTitle.creditProgressOf(h#resources, h#world)), again |> Option.map(h -> "${World.sceneKindOf(h#world)}")))
}
