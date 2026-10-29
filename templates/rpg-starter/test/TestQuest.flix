// 依頼と仲間と門の決まり（依頼の段階・コマンドが World を変える・World → 会話の変数の写し・出口の gate・隊列）。
// 場面は Starts から組み、キーは実機と同じ道（App.trace）で 1/60 秒ずつ流す。
// 1 ノードだけの会話（Fixtures.openTree）は、木の JSON を Talk.fromJson で読んだ物を Res に差し替えて開く。
mod TestQuest {
    use fge::{Dir4}
    use fge::GameEngine.Key

    /// 村長の家の机の前（7, 5）で、村長の会話を開いた所。
    def chiefTalk(): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("talk", Map#{"node" => "ChiefQuest", "map" => "chief_house", "x" => "7", "y" => "5", "facing" => "up"})

    /// 依頼の問いを出し切り、はい / いいえ を出して、「いいえ」を選ぶ。
    def answerNo(): List[Set[Key]] =
        Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.confirm())

    /// 依頼の問いを出し切り、はい / いいえ を出して、「はい」を選ぶ。
    def answerYes(): List[Set[Key]] =
        Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm())

    /// 鍛冶屋の前のミナの下（3, 6）で上を向き、話しかけて台詞を送った所（quest = 依頼の段階）。
    def talkedToMina(quest: String): Fixtures.Run \ Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "smithy", "x" => "3", "y" => "6", "facing" => "up", "quest" => quest});
        Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), h)

    // ══════════════════════════════════════════════════════
    // 依頼
    // ══════════════════════════════════════════════════════

    /// 村長の問いに「いいえ」と答えても、依頼の段階は NotAsked のまま。
    @Test
    def testNoKeepsTheQuestStage(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Quest.Quest.NotAsked, Fixtures.questOf(Fixtures.play(answerNo(), chiefTalk())))

    /// 「いいえ」ではお金も変わらない（rules.startGold のまま）。
    @Test
    def testNoPaysNothing(): Unit \ Assert + Fs.FileRead =
        let h = chiefTalk();
        Assert.assertEq(expected = RulesDoc.rec(h#resources#rules)#startGold, Fixtures.goldOf(Fixtures.play(answerNo(), h)))

    /// 「いいえ」の取消: 選択肢で取消を押すと最後の項目を選ぶ（2 つ目の B の台詞へ進む）。
    @Test
    def testCancelOnChoicesPicksTheLastItem(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8"});
        let tree = Fixtures.line("Q") + "," + Fixtures.options("a", Fixtures.line("A"), "b", Fixtures.line("B"));
        Assert.assertEq(expected = Some(Some("B")),
            Fixtures.openTree(tree, h) |> Option.map(opened -> Fixtures.lineTextOf(Fixtures.play(
                Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.cancel()), opened))))

    /// 「はい」で依頼の段階が Accepted になる。
    @Test
    def testYesAcceptsTheQuest(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Quest.Quest.Accepted, Fixtures.questOf(Fixtures.play(answerYes(), chiefTalk())))

    /// 「はい」で手付け（rules.advance）を受け取る。
    @Test
    def testYesPaysTheAdvance(): Unit \ Assert + Fs.FileRead =
        let h = chiefTalk();
        let rules = RulesDoc.rec(h#resources#rules);
        Assert.assertEq(expected = rules#startGold + rules#advance, Fixtures.goldOf(Fixtures.play(answerYes(), h)))

    /// 「はい」でやくそうを 3 つ受け取る（rune.yarn の <<give yakusou 3>>）。
    @Test
    def testYesGivesThreeHerbs(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some(3), Fixtures.itemCountOf("yakusou", Fixtures.play(answerYes(), chiefTalk())))

    /// 本物の会話（選択肢の中の <<quest accept>> の後）の {$gold} の台詞は、手付けを足した後の手持ちを出す
    /// （「はい」→ 村長の礼を出し切って送った次の台詞）。
    @Test
    def testGoldLineAfterAcceptShowsTheNewGold(): Unit \ Assert + Fs.FileRead =
        let h = chiefTalk();
        let rules = RulesDoc.rec(h#resources#rules);
        let after = Fixtures.play(answerYes() ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), h);
        Assert.assertEq(expected = Some(true),
            Fixtures.lineTextOf(after) |> Option.map(text -> String.contains(substr = "${rules#startGold + rules#advance}G", text)))

    /// <<quest accept>> を 2 回流しても段階は戻らず、手付けは 1 回だけ払う（お金 0 から始めて advance）。
    @Test
    def testQuestAcceptTwicePaysOnce(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8", "gold" => "0"});
        let tree = Fixtures.command("quest", "accept") + "," + Fixtures.command("quest", "accept") + "," + Fixtures.line("A");
        Assert.assertEq(expected = Some((Quest.Quest.Accepted, RulesDoc.rec(h#resources#rules)#advance)),
            Fixtures.openTree(tree, h) |> Option.map(after -> (Fixtures.questOf(after), Fixtures.goldOf(after))))

    // ══════════════════════════════════════════════════════
    // 仲間
    // ══════════════════════════════════════════════════════

    /// 依頼の前に鍛冶屋の前のミナと話し、台詞を送り切っても、仲間はルカ 1 人のまま。
    @Test
    def testMinaDoesNotJoinBeforeTheQuest(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Member.Member.Luka :: Nil, Fixtures.membersOf(talkedToMina("none")))

    /// 依頼の後にミナと話して台詞を送ると、ミナが加わる。
    @Test
    def testMinaJoinsAfterTheQuest(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Member.Member.Luka :: Member.Member.Mina :: Nil, Fixtures.membersOf(talkedToMina("accepted")))

    /// 加わったミナは、マップで立っていたマス（Doc の mina の人のマス）から隊列の 2 人目に入る。
    @Test
    def testMinaJoinsFromWhereSheStood(): Unit \ Assert + Fs.FileRead =
        let after = talkedToMina("accepted");
        Assert.assertEq(expected = Fixtures.npcCellOf("smithy", "mina", after), Fixtures.secondCellOf(after))

    /// 同じ <<join mina>> を 2 回流しても、ミナは 1 人だけ加わる。
    @Test
    def testJoinTwiceAddsOneMember(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8"});
        let tree = Fixtures.command("join", "mina") + "," + Fixtures.command("join", "mina") + "," + Fixtures.line("A");
        Assert.assertEq(expected = Some(Member.Member.Luka :: Member.Member.Mina :: Nil),
            Fixtures.openTree(tree, h) |> Option.map(Fixtures.membersOf))

    // ══════════════════════════════════════════════════════
    // World → 会話の変数
    // ══════════════════════════════════════════════════════

    /// <<gold 10>> の直後の <<if $gold >= 10>> は、当てて写し直した後の値で分かれる（お金 0 から始める）。
    @Test
    def testGoldIsCopiedBeforeTheNextIf(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8", "gold" => "0"});
        let tree = Fixtures.command("gold", "10") + "," + Fixtures.ifGoldAtLeast(10, Fixtures.line("A"), Fixtures.line("B"));
        Assert.assertEq(expected = Some(Some("A")), Fixtures.openTree(tree, h) |> Option.map(Fixtures.lineTextOf))

    // ══════════════════════════════════════════════════════
    // 出口の gate
    // ══════════════════════════════════════════════════════

    /// ミナが加わる前は、村の南の端（20, 14）から外へ出られず、下を向くだけ。
    @Test
    def testGateBlocksBeforeMinaJoins(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "14", "facing" => "up", "quest" => "accepted"});
        Assert.assertEq(expected = Some(((20, 14), Dir4.Dir4.Down)),
            Fixtures.heroOf(Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(20), h)))

    /// 閉じた端の出口から出ようとすると、出口の gate の会話のノードが開く。
    @Test
    def testClosedGateOpensItsNode(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "14", "facing" => "up", "quest" => "accepted"});
        let gateNode = Fixtures.exitOf("village", "to_world", h) |> Option.flatMap(exit -> exit#gate) |> Option.map(gate -> gate#node);
        Assert.assertEq(expected = gateNode, Fixtures.talkNodeOf(Fixtures.play(Fixtures.tap(Fixtures.down()), h)))

    /// ミナが加わった後は、同じ端から出て行き先のマップへ移る。
    @Test
    def testGateOpensAfterMinaJoins(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "14", "facing" => "down",
                                               "quest" => "accepted", "party" => "luka,mina"});
        let destination = Fixtures.exitOf("village", "to_world", h) |> Option.map(exit -> exit#to);
        Assert.assertEq(expected = destination, Fixtures.mapOf(Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(90), h)))

    // ══════════════════════════════════════════════════════
    // 隊列
    // ══════════════════════════════════════════════════════

    /// 2 人目は先頭の前のマスへ順に詰める: (8, 7) から上・右・下と曲がり角を 2 回歩くと、
    /// 2 人目は 1 歩ごとに (8, 7) → (8, 6) → (9, 6) へ移る。
    @Test
    def testSecondFollowsTheLeadersCells(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "smithy", "x" => "8", "y" => "7", "facing" => "up", "party" => "luka,mina"});
        let up = Fixtures.play(Fixtures.hold(Fixtures.up(), 1) ::: Fixtures.idle(20), h);
        let right = Fixtures.play(Fixtures.hold(Fixtures.right(), 1) ::: Fixtures.idle(20), up);
        let down = Fixtures.play(Fixtures.hold(Fixtures.down(), 1) ::: Fixtures.idle(20), right);
        Assert.assertEq(expected = (Some((8, 7)), Some((8, 6)), Some((9, 6))),
            (Fixtures.secondCellOf(up), Fixtures.secondCellOf(right), Fixtures.secondCellOf(down)))

    /// 3 人の隊列は、3 人目が歩き出す 1 つ前のマスまで覚える: (8, 7) から上・右・下と歩くと、trail は新しい順に
    /// (9, 6)（2 人目）・(8, 6)（3 人目）・(8, 7)（3 人目が今の 1 歩で動き出したマス）。
    @Test
    def testThirdMemberKeepsTheCellItWalksFrom(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "smithy", "x" => "8", "y" => "7", "facing" => "up", "party" => "luka,mina,toto"});
        let walked = Fixtures.play(Fixtures.hold(Fixtures.up(), 1) ::: Fixtures.idle(20) ::: Fixtures.hold(Fixtures.right(), 1) ::: Fixtures.idle(20) :::
                                   Fixtures.hold(Fixtures.down(), 1) ::: Fixtures.idle(20), h);
        Assert.assertEq(expected = (Some((9, 6)), Some((8, 6)), Some((8, 7))),
            (Fixtures.trailCellAt(0, walked), Fixtures.trailCellAt(1, walked), Fixtures.trailCellAt(2, walked)))
}
