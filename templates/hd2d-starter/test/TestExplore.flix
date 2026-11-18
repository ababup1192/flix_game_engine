// TestExplore — 歩き回る規則（格子・円のぶつかりと滑り・建物の北に隠れるマス・隊列の道・向き・先を見せるカメラ・読み直し）を、
// その場で書いた地図と小物で固定する。
mod TestExplore {
    use fge::{DocJson, ImageData}
    use TownDecor.{Decor}
    use TownMap.{TownMap}

    /// 6 列 × 8 行の地図。水路 (4, 2)・生垣 (5, 7)・建物 x 1〜2・y 6〜7（1 階・棟は東西）・(5, 0) と (5, 1) は 1 段高く (5, 1) が階段。草は上げない。
    def gridJson(): String =
        "{\"ground\": [\"gggggg\", \"gggggg\", \"ggggwg\", \"gggggg\", \"gggggg\", \"gggggg\", \"gggggg\", \"gggggg\"]," +
        " \"height\": [\"111112\", \"111112\", \"111111\", \"111111\", \"111111\", \"111111\", \"111111\", \"111111\"]," +
        " \"shape\": [\"......\", \".....^\", \"......\", \"......\", \"......\", \"......\", \"......\", \"......\"]," +
        " \"objects\": [\"......\", \"......\", \"......\", \"......\", \"......\", \"......\", \"......\", \".....H\"]," +
        " \"buildings\": [{\"id\": \"b\", \"x\": 1, \"y\": 6, \"w\": 2, \"h\": 2, \"level\": 1, \"floors\": 1, \"wall\": \"plaster\"," +
        " \"ridge\": \"x\", \"pitchDeg\": 40, \"overhang\": 0.4}]," +
        " \"heightStep\": 1.0, \"margin\": {\"cells\": 2, \"level\": -2}}"

    /// 小物: 屋台 (1, 3)（塞ぐ）と鳩 (4, 4)（通れる）。
    def decorJson(): String =
        "{\"props\": [{\"sprite\": \"market_stall.png\", \"col\": 1, \"row\": 3}, {\"sprite\": \"pigeon.png\", \"col\": 4, \"row\": 4, \"passable\": true}]}"

    def town(): TownMap =
        match DocJson.parse(gridJson()) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownMap.decode) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    def decor(): List[Decor] =
        match DocJson.parse(decorJson()) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownDecor.decode) {
            case Ok(ds)   => ds
            case Err(why) => bug!(why)
        }

    def hideRule(): CollisionGrid.HideRule = { slope = 0.8, seenHeight = 0.9, reach = 8, halfWidth = 0.45, sideDrift = 0.0 }

    def grid(): CollisionGrid.Grid = CollisionGrid.build(town(), decor(), _ -> 1.0, Some(hideRule()))

    def isBlocked(cr: (Int32, Int32)): Bool = Set.memberOf(cr, grid()#blocked)

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.001

    def move(at: (Float64, Float64), delta: (Float64, Float64)): (Float64, Float64) = CollisionGrid.moveAndSlide(grid(), 0.3, at, delta)

    // ── 格子 ──

    @Test
    def testWaterCellIsBlocked(): Unit \ Assert = Assert.assertTrue(isBlocked((4, 2)))

    @Test
    def testHedgeCellIsBlocked(): Unit \ Assert = Assert.assertTrue(isBlocked((5, 7)))

    @Test
    def testGrassCellIsOpen(): Unit \ Assert = Assert.assertFalse(isBlocked((5, 4)))

    @Test
    def testBuildingFootprintIsBlocked(): Unit \ Assert = Assert.assertTrue(isBlocked((2, 7)))

    @Test
    def testStallDecorIsBlocked(): Unit \ Assert = Assert.assertTrue(isBlocked((1, 3)))

    @Test
    def testPassableDecorIsOpen(): Unit \ Assert = Assert.assertFalse(isBlocked((4, 4)))

    @Test
    def testCellOutsideTheMapIsBlocked(): Unit \ Assert = Assert.assertTrue(CollisionGrid.isBlockedFrom(grid(), (0, 0), (-1, 0)))

    @Test
    def testLevelStepWithoutStairsIsBlocked(): Unit \ Assert = Assert.assertTrue(CollisionGrid.isBlockedFrom(grid(), (4, 0), (5, 0)))

    @Test
    def testStairsLetYouChangeLevel(): Unit \ Assert = Assert.assertFalse(CollisionGrid.isBlockedFrom(grid(), (4, 1), (5, 1)))

    // ── 建物の北に隠れるマス ──

    @Test
    def testThirdRowNorthOfOneFloorBuildingIsBlocked(): Unit \ Assert = Assert.assertTrue(isBlocked((2, 3)))

    @Test
    def testFourthRowNorthOfOneFloorBuildingIsOpen(): Unit \ Assert = Assert.assertFalse(isBlocked((2, 2)))

    @Test
    def testColumnBesideBuildingUnderTheEavesIsBlocked(): Unit \ Assert = Assert.assertTrue(isBlocked((3, 5)))

    @Test
    def testSecondColumnBesideBuildingIsOpen(): Unit \ Assert = Assert.assertFalse(isBlocked((4, 5)))

    @Test
    def testWithoutHideRuleRowNorthOfBuildingIsOpen(): Unit \ Assert =
        Assert.assertFalse(Set.memberOf((2, 5), CollisionGrid.build(town(), Nil, _ -> 1.0, None)#blocked))

    // ── ぶつかりと滑り（水路の四角は x 4〜5・y 5〜6） ──

    @Test
    def testCircleStopsRadiusBeforeTheWall(): Unit \ Assert = Assert.assertTrue(near(fst(move((3.5, 5.5), (1.0, 0.0))), 3.7))

    @Test
    def testCircleSlidesAlongTheWall(): Unit \ Assert = Assert.assertTrue(near(snd(move((3.5, 5.5), (0.5, 0.3))), 5.8))

    @Test
    def testFastMoveDoesNotPassThroughTheWall(): Unit \ Assert = Assert.assertTrue(near(fst(move((3.5, 5.5), (5.0, 0.0))), 3.7))

    @Test
    def testCircleStopsAtTheMapEdge(): Unit \ Assert = Assert.assertTrue(near(fst(move((0.5, 0.5), (-2.0, 0.0))), 0.3))

    @Test
    def testOpenMoveGoesTheWholeWay(): Unit \ Assert = Assert.assertTrue(near(snd(move((5.5, 2.5), (0.0, 1.0))), 3.5))

    // ── 隊列の道 ──

    @Test
    def testFollowerStandsSpacingBehindOnAStraightTrail(): Unit \ Assert =
        Assert.assertTrue(near(snd(fst(FollowTrail.pointBack((1.0, 3.0) :: (1.0, 2.0) :: (1.0, 1.0) :: Nil, 1.0))), 2.0))

    @Test
    def testFollowerTurnsTheCornerOfTheTrail(): Unit \ Assert =
        Assert.assertTrue(near(fst(fst(FollowTrail.pointBack((1.0, 2.0) :: (1.0, 1.0) :: (0.0, 1.0) :: Nil, 1.5))), 0.5))

    @Test
    def testFollowerFacesTheWayTheTrailWent(): Unit \ Assert =
        Assert.assertEq(expected = Facing.Dir.East, Facing.nearestOf(snd(FollowTrail.pointBack((1.0, 2.0) :: (1.0, 1.0) :: (0.0, 1.0) :: Nil, 1.5))))

    @Test
    def testShortTrailExtendsBehindTheOldestPoint(): Unit \ Assert =
        Assert.assertTrue(near(snd(fst(FollowTrail.pointBack((1.0, 3.0) :: (1.0, 2.5) :: Nil, 2.0))), 1.0))

    @Test
    def testPushDropsPointsBeyondTheKeptLength(): Unit \ Assert =
        Assert.assertEq(expected = 4, List.length(FollowTrail.push((0.0, 4.0), 2.5, (0.0, 3.0) :: (0.0, 2.0) :: (0.0, 1.0) :: (0.0, 0.0) :: Nil)))

    // ── 動く向きと帯のコマ ──

    @Test
    def testMostlyNorthInputFacesNorth(): Unit \ Assert = Assert.assertEq(expected = Facing.Dir.North, Facing.nearestOf((0.4, 0.6)))

    @Test
    def testMostlyWestInputFacesWest(): Unit \ Assert = Assert.assertEq(expected = Facing.Dir.West, Facing.nearestOf((-0.7, 0.2)))

    @Test
    def testWestIsTheEastRowFlipped(): Unit \ Assert = Assert.assertEq(expected = (1, true), Walkers.rowOf("nes", Facing.Dir.West))

    @Test
    def testSouthIsTheThirdRow(): Unit \ Assert = Assert.assertEq(expected = (2, false), Walkers.rowOf("nes", Facing.Dir.South))

    // ── 先を見せるカメラ ──

    /// 北へ速さ 3.46 m/秒で n コマ（1/60 秒）歩いた後の先へ見せる量の北の成分。
    def aheadAfterWalking(n: Int32): Float64 =
        let dt = 1.0 / 60.0;
        snd(List.range(0, n) |> List.foldLeft((a, _) -> TownCamera.lookAhead(1.5, 2.0, 3.46, (0.0, 3.46 * dt), dt, a), (0.0, 0.0)))

    @Test
    def testLookAheadReachesTheSetLengthAfterWalking(): Unit \ Assert = Assert.assertTrue(near(aheadAfterWalking(600), 1.5))

    @Test
    def testLookAheadMovesOnlyPartWayInOneFrame(): Unit \ Assert = Assert.assertTrue(aheadAfterWalking(1) < 0.1)

    @Test
    def testLookAheadReturnsWhenStopped(): Unit \ Assert =
        let dt = 1.0 / 60.0;
        let back = List.range(0, 600) |> List.foldLeft((a, _) -> TownCamera.lookAhead(1.5, 2.0, 3.46, (0.0, 0.0), dt, a), (0.0, 1.5));
        Assert.assertTrue(near(snd(back), 0.0))

    // ── 描く元と World（その場で書いた Doc と、どの道も 32×32 の白い絵を返す読み口で組む） ──

    /// どの道にも 32×32 の白い絵を返す読み口。
    def blankImage(_path: String): Result[String, ImageData.ImageData] =
        Ok({ width = 32, height = 32, argb = Vector.repeat(32 * 32, -1) })

    /// その場で書いた地図と小物に、立ち始め (0, 3)・速さ 2 m/秒の手触りの Doc の束。
    def docs(): Res.Docs =
        let explore = ExploreDoc.fromJson("{\"startCol\": 0, \"startRow\": 3, \"startFace\": \"n\", \"speed\": 2.0}") |> Option.getWithDefault(ExploreDoc.defaults());
        { map = town(), decor = Map#{ "assets/market.decor.json" => decor() }, look = TownLook.defaults(), explore = explore, keys = KeysDoc.defaults() }

    def res(): Res.Res =
        match Res.load(blankImage, TownScene.TextureNames.SceneTextures, Map.empty(), docs()) {
            case Ok(r)    => r
            case Err(why) => bug!(why)
        }

    def leaderOf(r: Res.Res, w: World.World): Option[(Int32, Int32)] = World.leaderCell(r, w)

    @Test
    def testLeaderStartsOnTheStartCell(): Unit \ Assert =
        let r = res();
        Assert.assertEq(expected = Some((0, 3)), leaderOf(r, World.initial(r)))

    @Test
    def testWalkingNorthForHalfASecondMovesOneMetre(): Unit \ Assert =
        // 立ち始め (0, 3) の真ん中は y = 4.5。北の (0, 2) は通れる
        let r = res();
        let w = List.range(0, 30) |> List.foldLeft((acc, _) -> World.step(r, (0.0, 1.0), 1.0 / 60.0, acc), World.initial(r));
        Assert.assertTrue(World.partyOf(w) |> Option.map(p -> near(snd(p#leader), 5.5)) |> Option.getWithDefault(false))

    @Test
    def testWalkingEastStopsAtTheStall(): Unit \ Assert =
        // 東の (1, 3) は屋台で塞がれ、円は四角の手前 0.3 m（x = 0.7）で止まる
        let r = res();
        let w = List.range(0, 30) |> List.foldLeft((acc, _) -> World.step(r, (1.0, 0.0), 1.0 / 60.0, acc), World.initial(r));
        Assert.assertTrue(World.partyOf(w) |> Option.map(p -> near(fst(p#leader), 0.7)) |> Option.getWithDefault(false))

    @Test
    def testLeaderDoesNotMoveWhileTheQuitPromptIsOpen(): Unit \ Assert =
        let r = res();
        let w = World.step(r, (1.0, 0.0), 0.5, World.askQuit(World.initial(r)));
        Assert.assertEq(expected = Some((0, 3)), leaderOf(r, w))

    @Test
    def testSettleMovesTheLeaderOffABlockedCell(): Unit \ Assert =
        let r = res();
        let onWater = World.placeLeader(r, 4, 2, Facing.Dir.North, World.initial(r));
        let settled = World.settle(r, onWater);
        Assert.assertTrue(leaderOf(r, settled) |> Option.map(cr -> not Set.memberOf(cr, r#grid#blocked)) |> Option.getWithDefault(false))

    @Test
    def testMapReloadRebuildsTheGrid(): Unit \ Assert =
        // 水路 (4, 2) を草にした地図を読み直すと、そのマスは通れる
        let r = res();
        let dried = DocJson.parse(String.replace(src = "\"ggggwg\"", dst = "\"gggggg\"", gridJson())) |> Option.toOk("JSON") |> Result.flatMap(TownMap.decode);
        Assert.assertFalse(Set.memberOf((4, 2), fst(Controls.mapReloaded(dried, r))#grid#blocked))

    @Test
    def testBrokenMapReloadKeepsTheGrid(): Unit \ Assert =
        let r = res();
        Assert.assertTrue(Set.memberOf((4, 2), fst(Controls.mapReloaded(Err("書きかけ"), r))#grid#blocked))

    @Test
    def testBrokenMapReloadTellsWhy(): Unit \ Assert =
        Assert.assertEq(expected = Some("書きかけ"), snd(Controls.mapReloaded(Err("書きかけ"), res())))

    @Test
    def testDecorReloadReplacesTheGrid(): Unit \ Assert =
        let r = res();
        Assert.assertFalse(Set.memberOf((1, 3), fst(Controls.decorReloaded("assets/market.decor.json", Ok(Nil), r))#grid#blocked))

    @Test
    def testBrokenDecorReloadKeepsTheStall(): Unit \ Assert =
        let r = res();
        Assert.assertTrue(Set.memberOf((1, 3), fst(Controls.decorReloaded("assets/market.decor.json", Err("書きかけ"), r))#grid#blocked))

    /// 見下ろす角度を浅くした見た目（建物の北の、足元が屋根に隠れる行が増える）に替えた描く元。
    def shallowRes(r: Res.Res): Res.Res =
        let look = TownLook.fromJson("{\"topDeg\": 5.0, \"bottomDeg\": 20.0}") |> Option.getWithDefault(TownLook.defaults());
        Res.withDocs({ look = look | r#docs }, r)

    @Test
    def testShallowLookHidesTheFifthRowNorthOfTheBuilding(): Unit \ Assert =
        Assert.assertTrue(Set.memberOf((2, 1), shallowRes(res())#grid#blocked))

    @Test
    def testSettleAfterALookReloadMovesTheLeaderOffTheHiddenCell(): Unit \ Assert =
        let r = res();
        let r2 = shallowRes(r);
        let settled = World.settle(r2, World.placeLeader(r, 2, 1, Facing.Dir.North, World.initial(r)));
        Assert.assertTrue(leaderOf(r2, settled) |> Option.map(cr -> not Set.memberOf(cr, r2#grid#blocked)) |> Option.getWithDefault(false))
}
