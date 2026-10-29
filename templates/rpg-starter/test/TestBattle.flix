// 戦い（出会い・コマンドバトル・勝ち・全滅・逃げる）の決まりと、敵の Doc の橋渡し。
mod TestBattle {
    use fge::{Resources}

    /// 仲間 members を Lv lv で組む（HP と MP は最大・装備は Doc の初めの物）。
    def partyAt(res: Res.Res, members: List[Member.Member], lv: Int32): Party.Party =
        members |> List.foldLeft((p, m) -> Party.join(res#party, res#items, m, p), Party.empty()) |> Party.atLevel(res#party, lv)

    /// 空のふくろで戦いを始める。
    def startBattle(res: Res.Res, foes: List[FoesDoc.FoeId], party: Party.Party): Battle.Battle = Battle.start(res, foes, party, Bag.withGold(0))

    def nameOf(res: Res.Res, m: Member.Member): String = PartyDoc.memberOf(m, res#party)#name

    def foeNameOf(res: Res.Res, key: String): String = FoesDoc.foeOrBlank(res#foes, Fixtures.foeId(res, key))#name

    def line(res: Res.Res, text: TextDoc.BattleText, values: List[(TextDoc.Placeholder, String)]): String = TextDoc.battleText(text, values, res#text)

    // ══════════════════════════════════════════════════════
    // 始める
    // ══════════════════════════════════════════════════════

    /// 同じ名前の 2 体は出た順に A・B、1 体だけの名前はそのまま。
    @Test
    def testSameNamesGetLetters(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let b = startBattle(res, Fixtures.foeId(res, "koke") :: Fixtures.foeId(res, "koumori") :: Fixtures.foeId(res, "koke") :: Nil,
                             partyAt(res, Member.Member.Luka :: Nil, 1));
        Assert.assertEq(expected = (foeNameOf(res, "koke") + "A") :: foeNameOf(res, "koumori") :: (foeNameOf(res, "koke") + "B") :: Nil,
            Fixtures.foeLabelsOf(b))

    /// 1 戦の敵は rules の maxFoes（3）体まで。4 体で始めても 3 体。
    @Test
    def testABattleHasAtMostThreeFoes(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "20", "y" => "12"});
        let koke = Fixtures.foeId(h#resources, "koke");
        let w = WorldBattle.enter(h#resources, koke :: koke :: koke :: koke :: Nil, None, h#world);
        Assert.assertEq(expected = Some(WorldBattle.maxFoesOf(h#resources)),
            World.battleRecOf(w) |> Option.map(r -> List.length(Fixtures.foeLabelsOf(r#battle))))

    /// 出会うと点滅し、点滅し終える（flashSeconds = 0.5 秒 < 1 秒）と戦いになる。
    @Test
    def testEncounterFlashesThenFights(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "20", "y" => "12"});
        let met = Resources.of(h#resources, World.startEncounter(Fixtures.foeId(h#resources, "koke") :: Nil, None, h#world));
        Assert.assertEq(expected = (World.SceneKind.Field, World.SceneKind.Battle),
            (World.sceneKindOf(met#world), World.sceneKindOf(Fixtures.play(Fixtures.idle(60), met)#world)))

    /// 次の戦いまで 1 歩（steps=1）で上を押したまま: 1 マス歩いた所で出会って止まり、点滅の後の戦いの戻る先はそのマス。
    @Test
    def testEncounterStopsTheWalk(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "20", "y" => "12", "steps" => "1"});
        let after = Fixtures.play(Fixtures.hold(Fixtures.up(), 60), h);
        Assert.assertEq(expected = Some((20, 11)),
            Fixtures.battleOf(after) |> Option.map(r -> World.fieldRecOfState(r#back)) |> Option.map(r -> (r#hero#x, r#hero#y)))

    /// 会話の <<fight 敵>> は会話を閉じて点滅を始め、点滅し終えると戦いになる。
    @Test
    def testFightCommandStartsABattle(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "20", "y" => "12"});
        let opened = Fixtures.openTree(Fixtures.command("fight", "koke") + "," + Fixtures.line("A"), h);
        Assert.assertEq(expected = Some(World.SceneKind.Battle),
            opened |> Option.map(o -> World.sceneKindOf(Fixtures.play(Fixtures.idle(60), o)#world)))

    // ══════════════════════════════════════════════════════
    // 式
    // ══════════════════════════════════════════════════════

    /// ちからが まもりの半分に届かなくても、ダメージは 1。
    @Test
    def testDamageIsAtLeastOne(): Unit \ Assert =
        Assert.assertEq(expected = 1, Battle.damageOf(0.125, 1, 100, 0.0))

    /// 同じ戦い・同じ行動・同じ乱数の回数なら、同じ Beat の列と同じ回数が返る。
    @Test
    def testResolveRoundIsDeterministic(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let b = startBattle(res, Fixtures.foeId(res, "koke") :: Fixtures.foeId(res, "koumori") :: Nil,
                             partyAt(res, Member.Member.Luka :: Member.Member.Mina :: Nil, 2));
        let plans = Map#{Member.Member.Luka => Battle.Plan.Attack(1), Member.Member.Mina => Battle.Plan.Defend};
        Assert.assertEq(expected = Fixtures.roundShapeOf(res, BattleActs.resolveRound(res, b, plans, 50)),
            Fixtures.roundShapeOf(res, BattleActs.resolveRound(res, b, plans, 50)))

    /// guard した敵へのダメージは、guard しない時の半分（切り上げ）。技の行だけを替えた同じ乱数の 2 戦で比べる。
    @Test
    def testGuardHalvesTheDamage(): Unit \ Assert + Fs.FileRead =
        let base = Res.load();
        let lossWith = act -> FoeMovesDoc.fromJson("{\"version\":1,\"moves\":[{\"foe\":\"koke\",\"phase\":1,\"act\":\"${act}\",\"weight\":1}]}")
            |> Option.map(doc -> Res.withFoeMoves(doc, base))
            |> Option.flatMap(res -> {
                let b = startBattle(res, Fixtures.foeId(res, "koke") :: Nil, partyAt(res, Member.Member.Luka :: Nil, 1));
                let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.Attack(0)}, 0);
                Fixtures.foeHpsOf(after) |> List.head |> Option.map(hp -> FoesDoc.foeOrBlank(res#foes, Fixtures.foeId(res, "koke"))#hp - hp)
            });
        Assert.assertEq(expected = lossWith("attack") |> Option.map(n -> (n + 1) / 2), lossWith("guard"))

    /// すばやさの大きい方が先に動く: ルカ（8）はねぼけダケ（3）より先、ひのこコウモリ（14）より後（ぶれは 1.25 倍まで）。
    @Test
    def testFasterActsFirst(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let firstLine = key -> {
            let b = startBattle(res, Fixtures.foeId(res, key) :: Nil, partyAt(res, Member.Member.Luka :: Nil, 1));
            let (_, beats, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.Defend}, 0);
            beats |> List.head |> Option.flatMap(beat -> List.head(Fixtures.beatLinesOf(res, beat)))
        };
        Assert.assertEq(expected = (Some(line(res, TextDoc.BattleText.Defend, (TextDoc.Placeholder.Name, nameOf(res, Member.Member.Luka)) :: Nil)),
                                    Some(line(res, TextDoc.BattleText.Attack, (TextDoc.Placeholder.Name, foeNameOf(res, "hinoko")) :: Nil))),
            (firstLine("neboke"), firstLine("hinoko")))

    /// 倒れた的への たたかう は生きている別の敵へ振り替える: Lv10 の 2 人が同じ B を狙うと、1 ターンで A も倒れて勝つ。
    @Test
    def testDeadTargetIsSwitched(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let b = startBattle(res, Fixtures.foeId(res, "koke") :: Fixtures.foeId(res, "koke") :: Nil,
                             partyAt(res, Member.Member.Luka :: Member.Member.Mina :: Nil, 10));
        let (after, _, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.Attack(1), Member.Member.Mina => Battle.Plan.Attack(1)}, 0);
        Assert.assertEq(expected = Battle.Outcome.Won, Battle.outcomeOf(after))

    /// 逃げる率は 0.1..0.95 に収まる（すばやさ 200 の敵には 0.1・すばやさ 0 の敵へ Lv10 のルカは 0.95）。
    @Test
    def testFleeRateIsClamped(): Unit \ Assert + Fs.FileRead =
        let base = Res.load();
        let foes = "{\"version\":1,\"foes\":{\"fast\":{\"name\":\"F\",\"sprite\":\"bat\",\"hp\":10,\"agi\":200},\"slow\":{\"name\":\"S\",\"sprite\":\"koke\",\"hp\":10,\"agi\":0}}}";
        let rateOf = (key, lv) -> FoesDoc.fromJson(foes) |> Option.map(doc -> Res.withFoes(doc, base))
            |> Option.map(res -> Battle.fleeRateOf(res, startBattle(res, Fixtures.foeId(res, key) :: Nil, partyAt(res, Member.Member.Luka :: Nil, lv))));
        Assert.assertEq(expected = (Some(0.1), Some(0.95)), (rateOf("fast", 1), rateOf("slow", 10)))

    /// noFlee の組（ジェムイーター）で にげる は「にげられない」でその手番を使い、戦いは続く。
    @Test
    def testNoFleeUsesTheTurn(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let b = startBattle(res, Fixtures.foeId(res, "gemeater") :: Nil, partyAt(res, Member.Member.Luka :: Nil, 10));
        let (after, beats, _) = BattleActs.resolveRound(res, b, Map#{Member.Member.Luka => Battle.Plan.Flee}, 0);
        let expected = line(res, TextDoc.BattleText.Run, (TextDoc.Placeholder.Name, nameOf(res, Member.Member.Luka)) :: Nil) :: line(res, TextDoc.BattleText.NoFlee, Nil) :: Nil;
        Assert.assertEq(expected = (true, Battle.Outcome.Ongoing),
            (List.memberOf(expected, Fixtures.transcriptOf(res, beats)), Battle.outcomeOf(after)))

    // ══════════════════════════════════════════════════════
    // 見せ方
    // ══════════════════════════════════════════════════════

    /// 1 ターンの演出の途中は、見せている Beat の後の HP を出す（ターンの最後の結果を先に出さない）。
    /// 決定 6 回 = 現れた を出し切る・送る・ルカの たたかう・的・ミナの たたかう・的。
    @Test
    def testShownHpIsTheCurrentBeat(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "koke,koke", "party" => "luka,mina"});
        let c = Fixtures.tap(Fixtures.confirm());
        let shown = Fixtures.play(List.flatten(c :: c :: c :: c :: c :: c :: Nil), h);
        let hpsOf = b -> (Fixtures.allyHpsOf(b), Fixtures.foeHpsOf(b));
        Assert.assertEq(expected = Some((true, false)),
            Fixtures.battleOf(shown) |> Option.flatMap(r -> WorldBattle.currentBeatOf(r) |> Option.map(current ->
                (hpsOf(WorldBattle.shownBattleOf(r)) == hpsOf(Battle.beatRecOf(fst(current))#after), hpsOf(WorldBattle.shownBattleOf(r)) == hpsOf(r#battle)))))

    // ══════════════════════════════════════════════════════
    // 勝ち・全滅
    // ══════════════════════════════════════════════════════

    /// 勝つと敵の経験値は生きている仲間だけが受け取り（HP 0 のミナは増えない）、お金がふくろへ入ってフィールドへ戻る。
    @Test
    def testWinPaysOnlyTheLiving(): Unit \ Assert + Fs.FileRead =
        let h0 = Fixtures.started("battle", Map#{"foes" => "kusausa", "party" => "luka,mina", "lv" => "5", "gold" => "0"});
        let h = Fixtures.play(Fixtures.confirmEach(12), Fixtures.withBattleHpOf(Member.Member.Mina, 0, h0));
        let kusausa = FoesDoc.foeOrBlank(h#resources#foes, Fixtures.foeId(h#resources, "kusausa"));
        let lv5 = PartyDoc.expFor(5, h#resources#party);
        Assert.assertEq(expected = (World.SceneKind.Field, Some((5, lv5 + kusausa#exp)), Some((5, lv5)), kusausa#gold),
            (World.sceneKindOf(h#world), Fixtures.lvExpOf(Member.Member.Luka, h), Fixtures.lvExpOf(Member.Member.Mina, h), Fixtures.goldOf(h)))

    /// 経験値の表を 2 つまたぐと 2 レベル上がり、上がった Lv を 1 つずつ返す。
    @Test
    def testCrossingTwoRowsGainsTwoLevels(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let (p, ups) = Party.gainExp(res#party, Member.Member.Luka, PartyDoc.expFor(3, res#party), partyAt(res, Member.Member.Luka :: Nil, 1));
        Assert.assertEq(expected = (3, (Member.Member.Luka, 2) :: (Member.Member.Luka, 3) :: Nil),
            (Party.lvOf(Member.Member.Luka, p), ups))

    /// 全滅するとお金は goldKeep 倍（切り捨て）・HP は最大で、宿の前に立つ。
    @Test
    def testWipeHalvesGoldAndHealsAtHome(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.play(Fixtures.confirmEach(12), Fixtures.started("battle", Map#{"foes" => "akabou", "party" => "luka", "hp" => "1", "gold" => "101"}));
        let rules = RulesDoc.rec(h#resources#rules);
        Assert.assertEq(expected = (Some(rules#homeMap), Float64.tryToInt32(Float64.floor(101.0 * rules#goldKeep)), Some(Fixtures.maxHpOf(Member.Member.Luka, h))),
            (Fixtures.mapOf(h), Some(Fixtures.goldOf(h)), Fixtures.hpOf(Member.Member.Luka, h)))

    // ══════════════════════════════════════════════════════
    // FoesDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None（FoesDoc.load はそこで敵の無い表へ落ちる）。
    @Test
    def testFoesBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, FoesDoc.fromJson("{ broken") |> Option.map(doc -> FoesDoc.keysOf(doc)))

    /// name・sprite・hp だけの行は、書いた欄が効き、残りは既定（ちから 0・逃げられる）。
    @Test
    def testFoesRowWithOnlyRequiredFields(): Unit \ Assert =
        Assert.assertEq(expected = Some((50, 0, false)),
            FoesDoc.fromJson("{\"version\":1,\"foes\":{\"a\":{\"name\":\"A\",\"sprite\":\"koke\",\"hp\":50}}}")
                |> Option.flatMap(doc -> FoesDoc.idOf(doc, "a") |> Option.flatMap(FoesDoc.foeOf(doc)))
                |> Option.map(f -> (f#hp, f#atk, f#noFlee)))

    /// 敵の表は行に追随し、読めない行（sprite の無い b）だけ飛ばして問題に挙げる。
    @Test
    def testFoesFollowTheRows(): Unit \ Assert =
        let text = "{\"version\":1,\"foes\":{\"a\":{\"name\":\"A\",\"sprite\":\"koke\",\"hp\":5},\"b\":{\"name\":\"B\",\"hp\":5},\"c\":{\"name\":\"C\",\"sprite\":\"bat\",\"hp\":5}}}";
        Assert.assertEq(expected = Some(("a" :: "c" :: Nil, 1)),
            FoesDoc.fromJson(text) |> Option.map(doc -> (FoesDoc.keysOf(doc), List.length(FoesDoc.rec(doc)#problems))))

    /// 色違いの敵（recolor のある行）は、どれも色を差し替えた自分のアトラスを持つ。
    @Test
    def testEveryRecolorHasItsAtlas(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let recolored = FoesDoc.rec(res#foes)#foes |> Map.filter(f -> not String.isEmpty(f#recolor)) |> Map.keysOf;
        Assert.assertEq(expected = recolored, Map.keysOf(res#foeSheets))
}
