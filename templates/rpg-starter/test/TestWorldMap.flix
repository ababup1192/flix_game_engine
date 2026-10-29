// ワールドマップと坑道の決まり（マップの間の出入口・村の端の出口・ほこらのトトと杖・森の岩穴のレバーと鉄格子とほりモグ・坑道の入口の gate・宝箱と扉・
// 次の戦いまでの歩数・カメラの矩形・描き物の数とタイル層の作り直し）。
// 場面は Starts から組み、キーは実機と同じ道（App.trace）で 1/60 秒ずつ流す。期待値はマップと rules の Doc から。
mod TestWorldMap {
    use fge::{Dir4}

    /// ワールドマップのほこらの前（25, 12）で、横のトト（26, 12）の方を向いて立った所（items = ふくろの道具）。
    def facingToto(items: String): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map#{"map" => "world", "x" => "25", "y" => "12", "facing" => "right", "party" => "luka,mina",
                                       "quest" => "accepted", "items" => items})

    /// 決定で話しかけ、決定を 12 回送った所（会話を送り切って閉じるのに足りる数）。
    def talkThrough(h: Fixtures.Run): Fixtures.Run =
        Fixtures.play(List.flatten(List.repeat(13, Fixtures.tap(Fixtures.confirm()))), h)

    /// 森の岩穴（toto_cave）の (x, y) に向きを持って立った所（flags = 立てておく旗）。
    def inCave(x: String, y: String, facing: String, flags: String): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map#{"map" => "toto_cave", "x" => x, "y" => y, "facing" => facing, "party" => "luka,mina",
                                       "quest" => "accepted", "flags" => flags})

    // ══════════════════════════════════════════════════════
    // マップの間の出入口
    // ══════════════════════════════════════════════════════

    /// 村の南の端から出ると、ワールドマップの村の印（出入口 to_village のマス）の隣のマスに立つ。
    @Test
    def testLeavingTheVillageStandsNextToTheTownMark(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "14", "facing" => "down", "party" => "luka,mina", "quest" => "accepted"});
        let out = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(90), h);
        Assert.assertEq(expected = (Some("world"), Some(1)), (Fixtures.mapOf(out), Fixtures.stepsToExitOf("world", "to_village", out)))

    /// 坑道 B1 の下り階段に乗ると、出入口の行き先（B2）の spawn に立つ。
    @Test
    def testStairsGoDownToTheNextFloor(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "mine_b1", "x" => "26", "y" => "9", "facing" => "up"});
        let down = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(90), h);
        let exit = Fixtures.exitOf("mine_b1", "to_b2", h);
        Assert.assertEq(expected = exit |> Option.map(e -> (Some(e#to), Some(((e#spawnX, e#spawnY), e#facing)))),
            Some((Fixtures.mapOf(down), Fixtures.heroOf(down))))

    // ══════════════════════════════════════════════════════
    // 村の端の出口
    // ══════════════════════════════════════════════════════

    /// 村の北の端（7, 0）と西の端（0, 4）から外へ出ても、南と同じくワールドマップの村の印の隣に立つ。
    @Test
    def testEveryVillageEdgeLeadsToTheTownMark(): Unit \ Assert + Fs.FileRead =
        let north = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "0", "facing" => "down", "party" => "luka,mina", "quest" => "accepted"});
        let west = Fixtures.started("field", Map#{"map" => "village", "x" => "0", "y" => "4", "facing" => "down", "party" => "luka,mina", "quest" => "accepted"});
        let up = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(90), north);
        let left = Fixtures.play(Fixtures.tap(Fixtures.left()) ::: Fixtures.idle(90), west);
        Assert.assertEq(expected = ((Some("world"), Some(1)), (Some("world"), Some(1))),
            ((Fixtures.mapOf(up), Fixtures.stepsToExitOf("world", "to_village", up)), (Fixtures.mapOf(left), Fixtures.stepsToExitOf("world", "to_village", left))))

    /// 端のマスへ歩いて着いただけでは移らない（外へ向かって押した時だけ）: (5, 1) から上へ 1 マスで (5, 0) に立つ。
    @Test
    def testReachingTheEdgeCellDoesNotLeave(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "5", "y" => "1", "facing" => "up", "party" => "luka,mina", "quest" => "accepted"});
        let after = Fixtures.play(Fixtures.hold(Fixtures.up(), 1) ::: Fixtures.idle(30), h);
        Assert.assertEq(expected = (Some("village"), Some(((5, 0), Dir4.Dir4.Up))), (Fixtures.mapOf(after), Fixtures.heroOf(after)))

    /// ミナが加わる前は、北の端から出ようとしても出口の gate の会話が開き、村に残る。
    @Test
    def testEveryVillageEdgeIsGatedByMina(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "0", "facing" => "down", "quest" => "accepted"});
        let gateNode = Fixtures.exitOf("village", "to_world", h) |> Option.flatMap(e -> e#gate) |> Option.map(g -> g#node);
        let tried = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(30), h);
        Assert.assertEq(expected = (Some("village"), gateNode), (Fixtures.mapOf(tried), Fixtures.talkNodeOf(tried)))

    // ══════════════════════════════════════════════════════
    // ほこらとトト・坑道の入口
    // ══════════════════════════════════════════════════════

    /// ほこらの前のマス（25, 12）に着いても会話は開かない（トトに話しかけた時だけ開く）。
    @Test
    def testShrineFrontIsAPlainCell(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "24", "y" => "12", "facing" => "right", "party" => "luka,mina", "quest" => "accepted"});
        let after = Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), h);
        Assert.assertEq(expected = (Some(((25, 12), Dir4.Dir4.Right)), "Walking"), (Fixtures.heroOf(after), Fixtures.layerOf(after)))

    /// 杖を持たずにトトへ話しかけると、杖の話を聞くだけでトトは加わらない。
    @Test
    def testTotoWaitsForHisStaff(): Unit \ Assert + Fs.FileRead =
        let h = facingToto("");
        let opened = Fixtures.play(Fixtures.tap(Fixtures.confirm()), h);
        Assert.assertEq(expected = (Some("Shrine"), Member.Member.Luka :: Member.Member.Mina :: Nil),
            (Fixtures.talkNodeOf(opened), Fixtures.membersOf(talkThrough(h))))

    /// トトのつえを持ってトトへ話しかけ、会話を送り切ると、杖を返して（ふくろから無くなり）トトが 3 人目に加わる。
    @Test
    def testReturningTheStaffAddsToto(): Unit \ Assert + Fs.FileRead =
        let after = talkThrough(facingToto("totostaff:1"));
        Assert.assertEq(expected = (Member.Member.Luka :: Member.Member.Mina :: Member.Member.Toto :: Nil, Some(0)),
            (Fixtures.membersOf(after), Fixtures.itemCountOf("totostaff", after)))

    // ══════════════════════════════════════════════════════
    // 森の岩穴（レバー・鉄格子・ほりモグ）
    // ══════════════════════════════════════════════════════

    /// ワールドマップの岩穴（出入口 to_cave のマス）に入ると、出入口の行き先（toto_cave）の spawn に立つ。
    @Test
    def testCaveMouthLeadsIntoTheCave(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "21", "y" => "19", "facing" => "down", "party" => "luka,mina", "quest" => "accepted"});
        let exit = Fixtures.exitOf("world", "to_cave", h);
        let inside = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(90), h);
        Assert.assertEq(expected = exit |> Option.map(e -> (Some(e#to), Some(((e#spawnX, e#spawnY), e#facing)))),
            Some((Fixtures.mapOf(inside), Fixtures.heroOf(inside))))

    /// 鉄格子の前（7, 9）から上へは、レバーの旗が下りている間は進めない。
    @Test
    def testBarsBlockWhileTheFlagIsDown(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), inCave("7", "9", "up", ""));
        Assert.assertEq(expected = Some((7, 9)), Fixtures.heroOf(after) |> Option.map(fst))

    /// レバーの旗（cave_bars）が立っていれば、鉄格子のマス（7, 8）へ進める。
    @Test
    def testBarsOpenWithTheFlag(): Unit \ Assert + Fs.FileRead =
        let after = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), inCave("7", "9", "up", "cave_bars"));
        Assert.assertEq(expected = Some((7, 8)), Fixtures.heroOf(after) |> Option.map(fst))

    /// レバーの前（9, 9）で上を向いて調べると旗が立ち、知らせを送ってもう 1 度調べると旗が下りる。
    @Test
    def testLeverTogglesItsFlag(): Unit \ Assert + Fs.FileRead =
        let pulled = Fixtures.play(Fixtures.tap(Fixtures.confirm()), inCave("9", "9", "up", ""));
        let back = Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), pulled);
        Assert.assertEq(expected = (true, false), (Fixtures.isFlagSetOf("cave_bars", pulled), Fixtures.isFlagSetOf("cave_bars", back)))

    /// ほりモグ（7, 4）の前で調べると、番をする者の会話のノード（Doc の node）が開く。
    @Test
    def testGuardOpensItsTalk(): Unit \ Assert + Fs.FileRead =
        let h = inCave("7", "5", "up", "cave_bars");
        let node = Fixtures.guardNodeOf("toto_cave", "cave_mole", h);
        Assert.assertEq(expected = node, Fixtures.talkNodeOf(Fixtures.play(Fixtures.tap(Fixtures.confirm()), h)))

    /// ほりモグの会話を送ると固定の戦いになり、ほりモグと戦って、勝った後に StaffBack を開く。
    @Test
    def testGuardTalkStartsItsFight(): Unit \ Assert + Fs.FileRead =
        let h = inCave("7", "5", "up", "cave_bars");
        let fighting = Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(60), h);
        Assert.assertEq(expected = Fixtures.foeNameOf("horimogu", h) |> Option.map(name -> (name :: Nil, Some("StaffBack"))),
            Fixtures.battleOf(fighting) |> Option.map(r -> (Fixtures.foeLabelsOf(r#battle), r#afterWin)))

    /// 勝ちのノード StaffBack を送り切ると、ほりモグは消えて（通れる）トトのつえがふくろに入る。
    @Test
    def testWinningTheGuardFightReturnsTheStaff(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("talk", Map#{"node" => "StaffBack", "map" => "toto_cave", "x" => "7", "y" => "5", "facing" => "up",
                                              "party" => "luka,mina", "quest" => "accepted", "flags" => "cave_bars"});
        let sent = Fixtures.play(List.flatten(List.repeat(4, Fixtures.tap(Fixtures.confirm()))), h);
        let walked = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), sent);
        Assert.assertEq(expected = (Some(1), Some((7, 4))), (Fixtures.itemCountOf("totostaff", sent), Fixtures.heroOf(walked) |> Option.map(fst)))

    /// 開く物の旗を立てるレバーがどのマップにも無いと、起動時の問題（Res.problemsOf が束ねる旗の食い違い）に 1 行挙がる。
    @Test
    def testGateWithoutLeverIsAProblem(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let json = "{\"rows\": [\"..\"], \"objects\": [{\"id\": \"g\", \"kind\": \"gate\", \"x\": 1, \"y\": 0, \"flag\": \"nolever\"}]}";
        Assert.assertEq(expected = Some("[map] lonely の物 'g' の旗 'nolever' を立てる物（レバー・床のスイッチ・水晶）がどのマップにも無い" :: Nil),
            MapDoc.fromJson(res#items, "lonely", json) |> Option.map(map -> Res.flagProblemsOf(Map#{"lonely" => map})))

    /// トトが加わる前は坑道の入口（20, 3）へ進めず、その場で gate の会話が開く。
    @Test
    def testMineGateStopsBeforeToto(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "20", "y" => "4", "facing" => "down", "party" => "luka,mina", "quest" => "accepted"});
        let gateNode = Fixtures.exitAt("world", 20, 3, h) |> Option.flatMap(e -> e#gate) |> Option.map(g -> g#node);
        let tried = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(30), h);
        Assert.assertEq(expected = (Some(((20, 4), Dir4.Dir4.Up)), gateNode), (Fixtures.heroOf(tried), Fixtures.talkNodeOf(tried)))

    /// トトが加わった後は坑道の入口を通って B1 へ入る。
    @Test
    def testMineGateOpensWithToto(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "20", "y" => "4", "facing" => "down", "party" => "luka,mina,toto", "quest" => "accepted"});
        let exit = Fixtures.exitAt("world", 20, 3, h);
        Assert.assertEq(expected = exit |> Option.map(e -> e#to), Fixtures.mapOf(Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(90), h)))

    // ══════════════════════════════════════════════════════
    // 宝箱と扉
    // ══════════════════════════════════════════════════════

    /// B1 の宝箱 b1_kawa の右（3, 12）で左を向いた所。
    def facingTheChest(): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map#{"map" => "mine_b1", "x" => "3", "y" => "12", "facing" => "left"})

    /// 宝箱は 1 回だけ開く: 2 回調べても、ふくろには中身の数（Doc の count）だけ入る。
    @Test
    def testChestOpensOnlyOnce(): Unit \ Assert + Fs.FileRead =
        let h = facingTheChest();
        let chest = Fixtures.chestOf("mine_b1", "b1_kawa", h);
        let examine = Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm());
        let twice = Fixtures.play(examine ::: examine, h);
        Assert.assertEq(expected = chest |> Option.map(c -> c#count), chest |> Option.flatMap(c -> c#item) |> Option.map(item -> Fixtures.bagCountOf(item, twice)))

    /// 開けた宝箱は旗が立つ。
    @Test
    def testChestRaisesItsFlag(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some(true), Fixtures.isOpenedOf("mine_b1", "b1_kawa", Fixtures.play(Fixtures.tap(Fixtures.confirm()), facingTheChest())))

    /// メニューの しらべる でも宝箱が開く（Root の右下）。
    @Test
    def testSearchFromTheMenuOpensTheChest(): Unit \ Assert + Fs.FileRead =
        let keys = Fixtures.tap(Fixtures.cancel()) ::: Fixtures.tap(Fixtures.down()) ::: Fixtures.tap(Fixtures.down()) :::
                   Fixtures.tap(Fixtures.right()) ::: Fixtures.tap(Fixtures.confirm());
        Assert.assertEq(expected = Some(true), Fixtures.isOpenedOf("mine_b1", "b1_kawa", Fixtures.play(keys, facingTheChest())))

    /// B3 の扉 b3_door の下（16, 6）で上を向いた所（ふくろは空）。
    def facingTheDoor(): Fixtures.Run \ Fs.FileRead =
        Fixtures.started("field", Map#{"map" => "mine_b3", "x" => "16", "y" => "6", "facing" => "up"})

    /// 鍵が無いと扉は開かない（旗は立たない）。
    @Test
    def testDoorStaysShutWithoutTheKey(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some(false), Fixtures.isOpenedOf("mine_b3", "b3_door", Fixtures.play(Fixtures.tap(Fixtures.confirm()), facingTheDoor())))

    /// 鍵（Doc の key）が有ると扉が開いて旗が立つ。
    @Test
    def testDoorOpensWithTheKey(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.withDoorKey("mine_b3", "b3_door", facingTheDoor());
        Assert.assertEq(expected = Some(true), Fixtures.isOpenedOf("mine_b3", "b3_door", Fixtures.play(Fixtures.tap(Fixtures.confirm()), h)))

    /// 開いた扉のマスへは歩いて入れる（知らせを閉じてから上へ 1 マス）。
    @Test
    def testOpenedDoorCanBeWalkedThrough(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.withDoorKey("mine_b3", "b3_door", facingTheDoor());
        let opened = Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), h);
        let walked = Fixtures.play(Fixtures.idle(1) ::: Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), opened);
        Assert.assertEq(expected = Some((16, 5)), Fixtures.heroOf(walked) |> Option.map(fst))

    // ══════════════════════════════════════════════════════
    // 次の戦いまでの歩数
    // ══════════════════════════════════════════════════════

    /// ワールドマップの道（9, 18）から北へ 1 マス歩いた所（seed = 乱数の回数の始め）。
    def oneStepOnTheWorld(seed: String): Fixtures.Run \ Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "9", "y" => "18", "facing" => "up", "seed" => seed, "party" => "luka,mina", "quest" => "accepted"});
        Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), h)

    /// 出会いの組のあるマップで 1 マス歩くと、rules の minSteps..maxSteps から引いた歩数が 1 減っている。
    @Test
    def testStepsToFightAreDrawnFromTheRules(): Unit \ Assert + Fs.FileRead =
        let h = oneStepOnTheWorld("0");
        let rules = RulesDoc.rec(h#resources#rules);
        Assert.assertEq(expected = Some(true), Fixtures.stepsToFightOf(h) |> Option.map(n -> n >= rules#minSteps - 1 and n <= rules#maxSteps - 1))

    /// 同じ乱数の回数から歩けば、同じ歩数を引く。
    @Test
    def testSameDiceDrawsTheSameSteps(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Fixtures.stepsToFightOf(oneStepOnTheWorld("7")), Fixtures.stepsToFightOf(oneStepOnTheWorld("7")))

    /// 出会いの組の無いマップ（村）では歩数を数えない（引かずに 0 のまま）。
    @Test
    def testNoStepsAreCountedWithoutEncounters(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "0", "y" => "9", "facing" => "right"});
        Assert.assertEq(expected = Some(0), Fixtures.stepsToFightOf(Fixtures.play(Fixtures.tap(Fixtures.right()) ::: Fixtures.idle(20), h)))

    // ══════════════════════════════════════════════════════
    // カメラ・描き物の数・タイル層
    // ══════════════════════════════════════════════════════

    /// ワールドマップのカメラの矩形は、マップの矩形（列 × 行 × 1 マスの px）。
    @Test
    def testCameraBoundsAreTheMapRect(): Unit \ Assert + Fs.FileRead =
        let h = oneStepOnTheWorld("0");
        let size = Map.get("world", h#resources#maps) |> Option.map(MapDoc.rec)
            |> Option.map(m -> (Int32.toFloat64(m#cols) * Autotile.tile(), Int32.toFloat64(m#height) * Autotile.tile()));
        let bounds = View.boundsOf(h#resources, h#world);
        Assert.assertEq(expected = size |> Option.map(wh -> ((0.0, 0.0), wh)),
            Some(((bounds#position#x, bounds#position#y), (bounds#size#x, bounds#size#y))))

    /// ワールドマップで水の一番多い所（東の海辺の 28, 12）でも、動く側の描き物は 1 フレーム 800 未満（地面の止まった絵はタイル層）。
    @Test
    def testWorldMovingItemsStayUnderTheBudget(): Unit \ Assert + Fs.FileRead + IO =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "27", "y" => "12", "facing" => "right", "party" => "luka,mina,toto"});
        Assert.assertEq(expected = true, Fixtures.worldItemCountOf(h) < 800)

    /// 同じマップを歩いている間はタイル層の鍵が変わらない（作り直さない）。
    @Test
    def testTileLayersStayWhileWalkingOnOneMap(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "9", "y" => "18", "facing" => "up", "party" => "luka,mina"});
        Assert.assertEq(expected = Fixtures.tileLayerKeysOf(h), Fixtures.tileLayerKeysOf(Fixtures.play(Fixtures.hold(Fixtures.up(), 40), h)))

    /// マップを移るとタイル層の鍵が替わる（行き先のマップの層を組む）。
    @Test
    def testTileLayersChangeWithTheMap(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "world", "x" => "9", "y" => "18", "facing" => "down", "party" => "luka,mina"});
        let inside = Fixtures.play(Fixtures.tap(Fixtures.down()) ::: Fixtures.idle(90), h);
        Assert.assertEq(expected = false, Fixtures.tileLayerKeysOf(h) == Fixtures.tileLayerKeysOf(inside))
}
