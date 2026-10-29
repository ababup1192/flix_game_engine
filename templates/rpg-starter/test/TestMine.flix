// 坑道 B1〜B3 の仕掛け: トロッコと分かれ目・岩と床のスイッチ・暗さとたいまつ・落とし穴・水晶と飛び石・番をする者・坑道の店・全快・セーブ。
// 場所の数（マス）は assets/maps/mine_b*.map.json の物の行と同じ。
mod TestMine {
    use fge::{Dir4, Emit}
    use fge::GameEngine.Key

    /// B1 で、仲間 3 人・依頼の後に立った所（args は足す・上書きする引数）。
    def inB1(x: String, y: String, facing: String, more: Map[String, String]): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map.union(more, Map#{"map" => "mine_b1", "x" => x, "y" => y, "facing" => facing,
                                                       "party" => "luka,mina,toto", "quest" => "accepted", "steps" => "999"}))

    def inMap(map: String, x: String, y: String, facing: String, more: Map[String, String]): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map.union(more, Map#{"map" => map, "x" => x, "y" => y, "facing" => facing,
                                                       "party" => "luka,mina,toto", "quest" => "accepted", "steps" => "999"}))

    /// トロッコの会話（台詞 → はい）を送って、走り終えるまで待つ。
    def ride(): List[Set[Key]] = Fixtures.confirmEach(3) ::: Fixtures.idle(150)

    // ══════════════════════════════════════════════════════
    // B1: トロッコと分かれ目のレバー
    // ══════════════════════════════════════════════════════

    /// 広間のトロッコ（9, 16）の左で乗ると、レバーの旗が下りている間は分かれ目で北へ曲がり、北の行き止まりのレールの終わり（14, 6）で降りる。
    @Test
    def testCartRidesNorthWhileTheSwitchIsDown(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(ride(), inB1("8", "16", "right", Map.empty()));
        Assert.assertEq(expected = (Some(((14, 6), Dir4.Dir4.Up)), false), (Fixtures.heroOf(after), Fixtures.isRidingOf(after)))

    /// 旗 b1_switch が立っていれば、分かれ目で南へ曲がり、東の坑道の前のレールの終わり（24, 20）で降りる。
    @Test
    def testCartRidesEastWithTheSwitchUp(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(ride(), inB1("8", "16", "right", Map#{"flags" => "b1_switch"}));
        Assert.assertEq(expected = Some(((24, 20), Dir4.Dir4.Right)), Fixtures.heroOf(after))

    /// 広間の北の壁のレバー（5, 11）を調べると、分かれ目の旗 b1_switch が立つ。
    @Test
    def testLeverTurnsTheJunction(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = true, Fixtures.isFlagSetOf("b1_switch", Fixtures.play(Fixtures.tap(Fixtures.confirm()), inB1("5", "12", "up", Map.empty()))))

    /// 走っている間は入力を受けない（Busy）。走り出してすぐに方向を押しても道を外れない。
    @Test
    def testRidingIgnoresInput(): Unit \ Assert + Fs.FileRead =
        let started = Fixtures.play(Fixtures.confirmEach(2) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(2), inB1("8", "16", "right", Map.empty()));
        let pushed = Fixtures.play(Fixtures.hold(Fixtures.down(), 10), started);
        Assert.assertEq(expected = (true, "Busy", true), (Fixtures.isRidingOf(started), Fixtures.layerOf(started), Fixtures.isRidingOf(pushed)))

    /// 帰りのトロッコ（11, 4）は、北の行き止まりから広間の北の端のレールの終わり（4, 11）へ走る。
    @Test
    def testReturnCartGoesBackToTheHall(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(ride(), inB1("12", "4", "left", Map.empty()));
        Assert.assertEq(expected = Some((4, 11)), Fixtures.heroOf(after) |> Option.map(fst))

    /// レールのマスは歩けない（分かれ目のレバーを使わずに先へ行けない）。北の行き止まり（14, 5）から下のレールの終わりへは進めない。
    @Test
    def testRailsCannotBeWalked(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(20), inB1("14", "5", "down", Map.empty()));
        Assert.assertEq(expected = Some((14, 5)), Fixtures.heroOf(after) |> Option.map(fst))

    // ══════════════════════════════════════════════════════
    // B1: 岩と床のスイッチ
    // ══════════════════════════════════════════════════════

    /// 岩（14, 24）の左から右へ押すと、岩が 1 マス右へ動き、先頭は岩のいたマスへ進む。
    @Test
    def testRockMovesWhenPushed(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), inB1("13", "24", "right", Map.empty()));
        Assert.assertEq(expected = (Some((15, 24)), Some((14, 24))), (Fixtures.objectCellOf("b1_rock", after), Fixtures.heroOf(after) |> Option.map(fst)))

    /// 岩の先が壁なら、岩も先頭も動かない（岩を部屋の右上の角 18, 23 に置いて右へ押す）。
    @Test
    def testRockStopsAtTheWall(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), inB1("17", "23", "right", Map#{"rocks" => "b1_rock:18:23"}));
        Assert.assertEq(expected = (Some((18, 23)), Some((17, 23))), (Fixtures.objectCellOf("b1_rock", after), Fixtures.heroOf(after) |> Option.map(fst)))

    /// 岩を床のスイッチ（16, 24）へ押し載せると、その旗 b1_room が立つ。
    @Test
    def testRockOnThePlateRaisesTheFlag(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), inB1("14", "24", "right", Map#{"rocks" => "b1_rock:15:24"}));
        Assert.assertEq(expected = true, Fixtures.isFlagSetOf("b1_room", after))

    /// 旗 b1_room が立っていれば部屋の格子（19, 24）を通れ、下りていれば通れない。
    @Test
    def testRoomBarsFollowThePlateFlag(): Unit \ Assert + Fs.FileRead =
        let walk = h -> Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), h) |> Fixtures.heroOf |> Option.map(fst);
        Assert.assertEq(expected = (Some((18, 24)), Some((19, 24))),
            (walk(inB1("18", "24", "right", Map.empty())), walk(inB1("18", "24", "right", Map#{"flags" => "b1_room"}))))

    /// 動かした岩は、マップを出て戻ると Doc の位置（14, 24）へ戻る（詰まない）。
    @Test
    def testRocksResetWhenLeavingTheMap(): Unit \ Assert + Fs.FileRead =
        let h = inB1("3", "27", "down", Map#{"rocks" => "b1_rock:18:23"});
        let back = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(90) ::: Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(90), h);
        Assert.assertEq(expected = (Some("mine_b1"), Some((14, 24))), (Fixtures.mapOf(back), Fixtures.objectCellOf("b1_rock", back)))

    /// 坑道の出会いの歩数はマップの minSteps..maxSteps から引く（rules の範囲ではない）。
    @Test
    def testMineDrawsStepsFromTheMap(): Unit \ Assert + Fs.FileRead =
        let h = inB1("5", "24", "up", Map#{"steps" => "0"});
        let after = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), h);
        let range = Map.get("mine_b1", h#resources#maps) |> Option.flatMap(map -> MapDoc.rec(map)#steps);
        Assert.assertEq(expected = Some(true),
            forM (n <- Fixtures.stepsToFightOf(after); r <- range) yield n >= fst(r) - 1 and n <= snd(r) - 1)

    // ══════════════════════════════════════════════════════
    // B2: 暗さ・たいまつ・落とし穴・番をする者・坑道の店
    // ══════════════════════════════════════════════════════

    /// 暗いマップの明かりは、たいまつが無ければ rules の darkRadius・残りがあれば torchRadius。明るいマップには明かりが無い。
    @Test
    def testDarkMapLightsAroundTheLeader(): Unit \ Assert + Fs.FileRead =
        let dark = inMap("mine_b2", "3", "2", "down", Map.empty());
        let lit = inMap("mine_b2", "3", "2", "down", Map#{"light" => "10"});
        let rules = RulesDoc.rec(dark#resources#rules);
        Assert.assertEq(expected = (Some(rules#darkRadius), Some(rules#torchRadius), None),
            (Fixtures.lightRadiusOf(dark), Fixtures.lightRadiusOf(lit), Fixtures.lightRadiusOf(inB1("5", "24", "up", Map.empty()))))

    /// 描き物の数: 暗いマップの墨（明かりの外のマスごとの矩形）を足しても、B2 の迷路の真ん中と B3 の湖の前で 1 フレーム 800 未満。
    @Test
    def testMineMovingItemsStayUnderTheBudget(): Unit \ Assert + Fs.FileRead + IO =
        let b2 = Fixtures.worldItemCountOf(inMap("mine_b2", "24", "12", "down", Map#{"light" => "10"}));
        let b3 = Fixtures.worldItemCountOf(inMap("mine_b3", "16", "21", "up", Map#{"flags" => "b3_crystals"}));
        Assert.assertEq(expected = (true, true), (b2 < 800, b3 < 800))

    /// メニューの どうぐ で たいまつ を使うと、1 つ減って残りの歩数が items の lightSteps になる。
    @Test
    def testTorchLightsTheDarkMap(): Unit \ Assert + Fs.FileRead =
        let h = inMap("mine_b2", "3", "2", "down", Map#{"items" => "taimatsu:1"});
        let keys = Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.right()) :::
                   Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm());
        let after = Fixtures.play(keys, h);
        Assert.assertEq(expected = (Fixtures.itemOf("taimatsu", h) |> Option.map(i -> i#lightSteps), Some(0)),
            (Fixtures.lightOf(after), Fixtures.itemCountOf("taimatsu", after)))

    /// 明るいマップでは たいまつ を使っても減らない。
    @Test
    def testTorchIsKeptOnABrightMap(): Unit \ Assert + Fs.FileRead =
        let h = inB1("5", "24", "up", Map#{"items" => "taimatsu:1"});
        let keys = Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.right()) :::
                   Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm());
        let after = Fixtures.play(keys, h);
        Assert.assertEq(expected = (Some(1), Some(0)), (Fixtures.itemCountOf("taimatsu", after), Fixtures.lightOf(after)))

    /// 暗いマップで 1 マス歩くと、たいまつの残りの歩数が 1 減る。
    @Test
    def testLightBurnsOneStepAtATime(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(20), inMap("mine_b2", "3", "2", "down", Map#{"light" => "10"}));
        Assert.assertEq(expected = Some(9), Fixtures.lightOf(after))

    /// 割れた床（19, 13）を踏むと落とし穴の出入口で B3 の西の小部屋（3, 3）へ落ちる。
    @Test
    def testCrackedFloorDropsToTheWestRoom(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(90), inMap("mine_b2", "19", "12", "down", Map.empty()));
        let pit = Fixtures.exitOf("mine_b2", "pit1", after);
        Assert.assertEq(expected = pit |> Option.map(e -> (Some(e#to), Some((e#spawnX, e#spawnY)))),
            Some((Fixtures.mapOf(after), Fixtures.heroOf(after) |> Option.map(fst))))

    /// くろがねゴブリン（31, 26）に話しかけて会話を送ると、くろがねゴブリンと戦い、勝った後に KuroganeWon を開く。
    @Test
    def testKuroganeGuardsTheSword(): Unit \ Assert + Fs.FileRead =
        let h = inMap("mine_b2", "32", "26", "left", Map.empty());
        let fighting = Fixtures.play(Fixtures.confirmEach(3), h);
        Assert.assertEq(expected = Fixtures.foeNameOf("kurogane", h) |> Option.map(name -> (name :: Nil, Some("KuroganeWon"))),
            Fixtures.battleOf(fighting) |> Option.map(r -> (Fixtures.foeLabelsOf(r#battle), r#afterWin)))

    /// 中ボスとひとくいばこは逃げられない（foes Doc の noFlee）。
    @Test
    def testMidBossesCannotBeFled(): Unit \ Assert + Fs.FileRead =
        let res = inB1("5", "24", "up", Map.empty())#resources;
        Assert.assertEq(expected = (Some(true), Some(true)),
            (FoesDoc.foeOf(res#foes, Fixtures.foeId(res, "kurogane")) |> Option.map(f -> f#noFlee),
             FoesDoc.foeOf(res#foes, Fixtures.foeId(res, "mimic")) |> Option.map(f -> f#noFlee)))

    /// <<shop mine>> は坑道の店（名前 mine。品は rpg.shops.json の shop = mine の行）を開き、<<shop>> は村の道具屋（名前の無い店）を開く。
    @Test
    def testTwoShopsOpenByName(): Unit \ Assert + Fs.FileRead =
        let h = inMap("mine_b2", "4", "2", "right", Map.empty());
        let shopIn = command -> Fixtures.openTree(command + "," + Fixtures.line("x"), h) |> Option.map(opened ->
            (Option.nonEmpty(WorldShop.openShopOf(opened#world)), WorldShop.shopOf(opened#world) |> Option.map(ShopsDoc.nameOf)));
        let village = "{\"kind\":\"command\",\"line\":2,\"name\":\"shop\",\"args\":[]}";
        Assert.assertEq(expected = (Some((true, Some("mine"))), Some((true, None))), (shopIn(Fixtures.command("shop", "mine")), shopIn(village)))

    // ══════════════════════════════════════════════════════
    // B3: 水晶と飛び石・ひとくいばこ・ミナの父・セーブ
    // ══════════════════════════════════════════════════════

    /// 東・西の水晶を点けた後に北の水晶（5, 8）を調べると、全部点いて旗 b3_crystals が立つ。
    @Test
    def testCrystalsInOrderRaiseTheFlag(): Unit \ Assert + Fs.FileRead =
        let h = inMap("mine_b3", "5", "9", "up", Map#{"opened" => "b3_crystal_e,b3_crystal_w"});
        Assert.assertEq(expected = true, Fixtures.isFlagSetOf("b3_crystals", Fixtures.play(Fixtures.tap(Fixtures.confirm()), h)))

    /// 東の水晶だけ点けて北の水晶を調べると順番が違うので、点いていた東の水晶も消え、旗は立たない。
    @Test
    def testCrystalOutOfOrderPutsThemOut(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.confirm()), inMap("mine_b3", "5", "9", "up", Map#{"opened" => "b3_crystal_e"}));
        Assert.assertEq(expected = (Some(false), false), (Fixtures.isOpenedOf("mine_b3", "b3_crystal_e", after), Fixtures.isFlagSetOf("b3_crystals", after)))

    /// 南の岸（16, 21）から湖へは、旗 b3_crystals が立つと飛び石（16, 20）へ進め、立つ前は進めない。
    @Test
    def testStonesAppearWithTheFlag(): Unit \ Assert + Fs.FileRead =
        let walk = h -> Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), h) |> Fixtures.heroOf |> Option.map(fst);
        Assert.assertEq(expected = (Some((16, 21)), Some((16, 20))),
            (walk(inMap("mine_b3", "16", "21", "up", Map.empty())), walk(inMap("mine_b3", "16", "21", "up", Map#{"flags" => "b3_crystals"}))))

    /// 岩の部屋 2 の床 2 つに岩を 1 つずつ載せ終えると旗 b3_room が立つ（片方だけでは立たない）。
    @Test
    def testBothPlatesAreNeeded(): Unit \ Assert + Fs.FileRead =
        let one = Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), inMap("mine_b3", "24", "25", "right", Map#{"rocks" => "b3_rock_b:25:25"}));
        let both = Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20),
            inMap("mine_b3", "24", "25", "right", Map#{"rocks" => "b3_rock_b:25:25,b3_rock_a:26:27"}));
        Assert.assertEq(expected = (false, true), (Fixtures.isFlagSetOf("b3_room", one), Fixtures.isFlagSetOf("b3_room", both)))

    /// ひとくいばこの勝ちのノード MimicWon を送り切ると、ひとくいばこは消えて 300G が入る。
    @Test
    def testBeatingTheMimicPays(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("talk", Map#{"node" => "MimicWon", "map" => "mine_b3", "x" => "30", "y" => "26", "facing" => "down",
                                              "party" => "luka,mina,toto", "quest" => "accepted", "flags" => "b3_room", "gold" => "0"});
        let sent = Fixtures.play(Fixtures.confirmEach(3), h);
        Assert.assertEq(expected = (300, Some(true)), (Fixtures.goldOf(sent), Fixtures.isOpenedOf("mine_b3", "b3_mimic", sent)))

    /// ミナの父に話して会話を送り切ると、仲間全員の HP が最大に戻る（<<heal>>）。
    @Test
    def testMinaFatherHealsEveryone(): Unit \ Assert + Fs.FileRead =
        let h = inMap("mine_b3", "14", "25", "left", Map#{"hp" => "1"});
        let after = Fixtures.play(Fixtures.confirmEach(10), h);
        Assert.assertEq(expected = Some(Fixtures.maxHpOf(Member.Member.Toto, after)), Fixtures.hpOf(Member.Member.Toto, after))

    /// 点けた水晶（開けた物）と解いた旗はセーブを往復しても残る。
    @Test
    def testPuzzleProgressSurvivesTheSave(): Unit \ Assert + Fs.FileRead =
        let h = inMap("mine_b3", "16", "21", "up", Map#{"opened" => "b3_crystal_e", "flags" => "b3_crystals,b1_switch"});
        let back = Saves.fromText(h#resources#items, h#resources#maps, Saves.toText(World.saveDataOf(h#world)));
        let b3 = MapDoc.idOf(h#resources#maps, "mine_b3");
        Assert.assertEq(expected = Ok((Some(true), true, true)), back |> Result.map(data -> {
            let p = Saves.rec(data)#progress;
            (b3 |> Option.map(m -> Progress.isOpened(m, "b3_crystal_e", p)), Progress.isFlagSet(Fixtures.flagId("b3_crystals"), p),
             Progress.isFlagSet(Fixtures.flagId("b1_switch"), p))
        }))

    // ══════════════════════════════════════════════════════
    // 種類の旗（profileOf の steps / pushable）と onArrive / onPush の枝
    // steps / pushable が真の種類ごとに、onArrive / onPush が Some を返す場面を 1 本ずつ持つ。
    // 種類の旗を真にしたら、ここに同じ形の 1 本を足す（WorldObject の onArrive / onPush は case _ で畳むので、枝の書き忘れはここで止める）。
    // ══════════════════════════════════════════════════════

    /// B1 の床（13, 24）に置いた、踏むだけの床のスイッチ（hold = false・旗 test_flag）。
    def floorPlate(): WorldObject.Placed =
        { object = { id = "test_plate", x = 13, y = 24, sprite = "plate", kind = MapDoc.ObjectKind.Plate({ flag = Fixtures.flagId("test_flag"), hold = false }) },
          cell = { x = 13, y = 24 }, state = WorldObject.ObjectState.Closed }

    /// 床のスイッチ（steps が真）に着くと、onArrive が Some を返し、その旗が立つ。
    @Test
    def testFloorPlateActsOnArrive(): Unit \ Assert + Fs.FileRead =
        let h = inB1("13", "24", "down", Map.empty());
        let plate = floorPlate();
        let arrived = MapDoc.idOf(h#resources#maps, "mine_b1") |> Option.flatMap(map ->
            Emit.collect(() -> WorldObject.onArrive(h#resources, map, plate, h#world)) |> fst);
        Assert.assertEq(expected = (true, Some(true)),
                        (MapDoc.profileOf(plate#object#kind)#steps, arrived |> Option.map(w -> Progress.isFlagSet(Fixtures.flagId("test_flag"), w#progress))))

    /// 岩（pushable が真。B1 の 14, 24）を右へ押すと、onPush が Some を返し、岩の今のマスが 1 つ右になる。
    @Test
    def testRockActsOnPush(): Unit \ Assert + Fs.FileRead =
        let h = inB1("13", "24", "right", Map.empty());
        let pushed = forM (map <- MapDoc.idOf(h#resources#maps, "mine_b1"); doc <- MapDoc.docOf(h#resources#maps, map);
                           r <- World.fieldRecOf(h#world);
                           rock <- WorldObject.objectsNow(doc, r, h#world#progress) |> List.find(p -> p#object#id == "b1_rock");
                           w <- Emit.collect(() -> WorldObject.onPush(h#resources, map, rock, Dir4.Dir4.Right, h#world)) |> fst;
                           after <- World.fieldRecOf(w)) yield Map.get("b1_rock", after#rocks) |> Option.map(c -> (c#x, c#y));
        Assert.assertEq(expected = (true, Some(Some((15, 24)))), (MapDoc.profileOf(MapDoc.ObjectKind.Rock)#pushable, pushed))
}
