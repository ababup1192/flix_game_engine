// TestExplore — 歩き回る場面の格子（通れる・通れない・建物の北に隠れるマス）・円のぶつかりと滑り・隊列の道・先を見せるカメラを具体値で固定する。
mod TestExplore {
    use fge::{DocJson}
    use TownMap.{TownMap}

    /// 6 列 × 8 行の地図。水路 (4, 2)・生垣 (5, 7)・建物 x 1〜2・y 6〜7（1 階・棟は東西）・(5, 0) と (5, 1) は 1 段高く (5, 1) が階段・
    /// にぎやかしは屋台 (1, 3) と鳩 (4, 4)。草は上げない。
    def gridJson(): String =
        "{\"ground\": [\"gggggg\", \"gggggg\", \"ggggwg\", \"gggggg\", \"gggggg\", \"gggggg\", \"gggggg\", \"gggggg\"]," +
        " \"height\": [\"111112\", \"111112\", \"111111\", \"111111\", \"111111\", \"111111\", \"111111\", \"111111\"]," +
        " \"shape\": [\"......\", \".....^\", \"......\", \"......\", \"......\", \"......\", \"......\", \"......\"]," +
        " \"objects\": [\"......\", \"......\", \"......\", \"......\", \"......\", \"......\", \"......\", \".....H\"]," +
        " \"buildings\": [{\"id\": \"b\", \"x\": 1, \"y\": 6, \"w\": 2, \"h\": 2, \"level\": 1, \"floors\": 1, \"wall\": \"plaster\"," +
        " \"roof\": {\"kind\": \"gable\", \"ridge\": \"x\", \"pitchDeg\": 40, \"overhang\": 0.4}}]," +
        " \"heightStep\": 1.0, \"margin\": {\"cells\": 2, \"level\": -2}," +
        " \"camera\": {\"targetZ\": 1.25, \"target\": [1.5, 1.0], \"frame\": {\"anchor\": [1.5, 2.0], \"v\": 0.72, \"width\": 16.3}}," +
        " \"walk\": {\"col\": 0, \"fromRow\": 2, \"toRow\": 0, \"party\": [{\"strip\": \"a.png\"}]}," +
        " \"props\": [{\"sprite\": \"market_stall.png\", \"at\": [1, 3]}, {\"sprite\": \"pigeon.png\", \"at\": [4, 4]}]}"

    def town(): TownMap =
        match DocJson.parse(gridJson()) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownMap.decode("")) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    def grid(): CollisionGrid.Grid =
        CollisionGrid.build(town(), None, _ -> 1.0, d -> d#sprite == "sprites/pigeon.png", Some({ slope = 0.8, seenHeight = 0.9, reach = 8, halfWidth = 0.45, sideDrift = 0.0 }))

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
    def testPigeonDecorIsOpen(): Unit \ Assert = Assert.assertFalse(isBlocked((4, 4)))

    @Test
    def testCellOutsideTheMapIsBlocked(): Unit \ Assert = Assert.assertTrue(CollisionGrid.isBlockedFrom(grid(), (0, 0), (-1, 0)))

    @Test
    def testLevelStepWithoutStairsIsBlocked(): Unit \ Assert = Assert.assertTrue(CollisionGrid.isBlockedFrom(grid(), (4, 0), (5, 0)))

    @Test
    def testStairsLetYouChangeLevel(): Unit \ Assert = Assert.assertFalse(CollisionGrid.isBlockedFrom(grid(), (4, 1), (5, 1)))

    // ── 建物の北に隠れるマス（H1） ──

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
        Assert.assertFalse(Set.memberOf((2, 5), CollisionGrid.build(town(), None, _ -> 1.0, _ -> false, None)#blocked))

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
        Assert.assertEq(expected = Route.Dir.East, Explore.dirOf(snd(FollowTrail.pointBack((1.0, 2.0) :: (1.0, 1.0) :: (0.0, 1.0) :: Nil, 1.5))))

    @Test
    def testShortTrailExtendsBehindTheOldestPoint(): Unit \ Assert =
        Assert.assertTrue(near(snd(fst(FollowTrail.pointBack((1.0, 3.0) :: (1.0, 2.5) :: Nil, 2.0))), 1.0))

    @Test
    def testPushDropsPointsBeyondTheKeptLength(): Unit \ Assert =
        Assert.assertEq(expected = 4, List.length(FollowTrail.push((0.0, 4.0), 2.5, (0.0, 3.0) :: (0.0, 2.0) :: (0.0, 1.0) :: (0.0, 0.0) :: Nil)))

    // ── 動く向き ──

    @Test
    def testMostlyNorthInputFacesNorth(): Unit \ Assert = Assert.assertEq(expected = Route.Dir.North, Explore.dirOf((0.4, 0.6)))

    @Test
    def testMostlyWestInputFacesWest(): Unit \ Assert = Assert.assertEq(expected = Route.Dir.West, Explore.dirOf((-0.7, 0.2)))

    // ── 先を見せるカメラ（C3） ──

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

    @Test
    def testHalfStickShowsHalfTheLength(): Unit \ Assert =
        let dt = 1.0 / 60.0;
        let a = List.range(0, 600) |> List.foldLeft((acc, _) -> TownCamera.lookAhead(1.5, 2.0, 3.46, (1.73 * dt, 0.0), dt, acc), (0.0, 0.0));
        Assert.assertTrue(near(fst(a), 0.75))

    // ── クレジット ──

    def music(): ExploreDoc.Music =
        { sound = "bgm", volume = 0.35, credit = "a" :: Nil, creditFrom = 1.5, creditSec = 8.0, fadeSec = 0.8 }

    @Test
    def testCreditIsHiddenBeforeItsStart(): Unit \ Assert = Assert.assertTrue(near(Explore.creditAlpha(music(), 1.0), 0.0))

    @Test
    def testCreditIsFullyShownInTheMiddle(): Unit \ Assert = Assert.assertTrue(near(Explore.creditAlpha(music(), 5.0), 1.0))

    @Test
    def testCreditIsHalfwayThroughItsFadeIn(): Unit \ Assert = Assert.assertTrue(near(Explore.creditAlpha(music(), 1.9), 0.5))

    @Test
    def testCreditIsGoneAfterItsTime(): Unit \ Assert = Assert.assertTrue(near(Explore.creditAlpha(music(), 10.0), 0.0))
}
