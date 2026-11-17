// TestTown — 地図の読み・立体の決まり・面の向きと uv・カメラの式・隊列と追従カメラを具体値で固定する。
mod TestTown {
    use fge::{DocJson, Num, Vec3}
    use Faces.{Quad}
    use TownMap.{Ground, Prop, TownMap}

    /// 3×3 の小さな地図（真ん中だけ石畳・北西の 2 マスに生垣・草を 0.25 m 上げる差分つき）。
    def miniJson(): String =
        "{\"ground\": [\"ggg\", \"gcg\", \"ggg\"], \"height\": [\"111\", \"1a1\", \"111\"], \"shape\": [\"...\", \"...\", \"...\"]," +
        " \"objects\": [\"HH.\", \".2.\", \"...\"], \"buildings\": [], \"heightStep\": 1.0, \"margin\": {\"cells\": 2, \"level\": -2}," +
        " \"camera\": {\"targetZ\": 1.25, \"target\": [1.5, 1.0], \"frame\": {\"anchor\": [1.5, 2.0], \"v\": 0.72, \"width\": 16.3}}," +
        " \"walk\": {\"col\": 1, \"fromRow\": 2, \"toRow\": 0, \"party\": [{\"strip\": \"a.png\"}]}," +
        " \"variants\": {\"step\": {\"curbRaise\": 0.25, \"coping\": true}}}"

    def mini(variant: String): TownMap =
        match DocJson.parse(miniJson()) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownMap.decode(variant)) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    /// 実際の大通りの地図（assets）。
    def avenue(): TownMap \ IO =
        match (run { TownMap.load("step", "assets/town_avenue.map.json") } with Fs.FileRead.runWithIO) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.0001

    // ── 地図の読み ──

    @Test
    def testGroundLetterBecomesCobble(): Unit \ Assert =
        Assert.assertEq(expected = Ground.Cobble, TownMap.groundAt(mini("step"), 1, 1))

    @Test
    def testHeightLetterIsBase36(): Unit \ Assert =
        Assert.assertEq(expected = 10, TownMap.levelAt(mini("step"), 1, 1))

    @Test
    def testObjectLetterTwoIsMerchant(): Unit \ Assert =
        Assert.assertEq(expected = Prop.Npc(2), TownMap.propAt(mini("step"), 1, 1))

    @Test
    def testOutsideTheMapUsesMarginLevel(): Unit \ Assert =
        Assert.assertEq(expected = -2, TownMap.levelAt(mini("step"), -1, 0))

    @Test
    def testStepVariantRaisesGrassByCurb(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.topAt(mini("step"), 0, 0), 1.25))

    @Test
    def testWithoutVariantGrassStaysAtLevel(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.topAt(mini(""), 0, 0), 1.0))

    @Test
    def testRowsOfDifferentSizeAreRefused(): Unit \ Assert =
        let broken = String.replace(src = "\"shape\": [\"...\", \"...\", \"...\"]", dst = "\"shape\": [\"..\"]", miniJson());
        Assert.assertTrue(DocJson.parse(broken) |> Option.map(j -> Result.isErr(TownMap.decode("step", j))) |> Option.getWithDefault(false))

    // ── 立体の決まり ──

    def townOf(m: TownMap): TileMap3d.Town = TileMap3d.build(m, Map.empty(), None)

    def zRange(q: Quad): (Float64, Float64) =
        let zs = q#points |> List.map(p -> p#z);
        (List.foldLeft(Float64.min, 1000.0, zs), List.foldLeft(Float64.max, -1000.0, zs))

    /// 真ん中を 1 段下げた石畳にした地図: 真ん中の高さ 1・まわりの草 1.25。
    def sunkCenter(): TownMap =
        let m = mini("step");
        { levels = Vector#{ Vector#{ 1, 1, 1 }, Vector#{ 1, 1, 1 }, Vector#{ 1, 1, 1 } } | m }

    @Test
    def testCurbStandsOnTheFourEdgesBetweenGrassAndCobble(): Unit \ Assert =
        let curbs = townOf(sunkCenter())#quads |> List.filter(q -> q#material == "stone_cut" and { let (lo, hi) = zRange(q); near(lo, 1.0) and near(hi, 1.25) });
        Assert.assertEq(expected = 4, List.length(curbs))

    @Test
    def testCopingIsPlacedOnEachCurb(): Unit \ Assert =
        // 笠石の箱 1 つは 5 面（上・4 方）で、縁石の 4 辺に 1 つずつ
        let copings = townOf(sunkCenter())#quads |> List.filter(q -> q#material == "stone_cut" and { let (_, hi) = zRange(q); near(hi, 1.3) });
        Assert.assertEq(expected = 20, List.length(copings))

    @Test
    def testAdjacentHedgesShareNoInnerFace(): Unit \ Assert =
        let hedges = townOf(sunkCenter())#quads |> List.filter(q -> q#material == "hedge");
        Assert.assertEq(expected = 8, List.length(hedges))

    @Test
    def testHashMatchesBlenderPrototype(): Unit \ Assert =
        Assert.assertTrue(near(TileMap3d.h01(3, 5, 1), 0.7966430151827267) and near(TileMap3d.h01(-30, 2, 7), 0.5274128328374151))

    // ── 面の向きと uv ──

    def southWall(): Quad =
        Faces.quad("stone", Faces.p3(0.0, 0.0, 0.0) :: Faces.p3(1.0, 0.0, 0.0) :: Faces.p3(1.0, 0.0, 1.0) :: Faces.p3(0.0, 0.0, 1.0) :: Nil, Faces.fullUv(), Nil)

    @Test
    def testFloorQuadFacesUpInEngine(): Unit \ Assert =
        let floor = Faces.quad("grass", Faces.p3(0.0, 0.0, 0.0) :: Faces.p3(1.0, 0.0, 0.0) :: Faces.p3(1.0, 1.0, 0.0) :: Faces.p3(0.0, 1.0, 0.0) :: Nil, Faces.fullUv(), Nil);
        Assert.assertTrue(Faces.engineNormal(floor)#y > 0.999)

    @Test
    def testSouthWallFacesTheCameraInEngine(): Unit \ Assert =
        Assert.assertTrue(Faces.engineNormal(southWall())#z < -0.999)

    @Test
    def testWallUvTopOfThePictureIsAtTheTopOfTheWall(): Unit \ Assert =
        let topVs = Faces.engineVertices(southWall()) |> List.filter(pv -> near(fst(pv)#y, 1.0)) |> List.map(pv -> snd(snd(pv)));
        Assert.assertEq(expected = 0.0 :: 0.0 :: Nil, topVs)

    // ── カメラ ──

    @Test
    def testLensShiftForFifteenToFiftyDegrees(): Unit \ Assert =
        let lens = TownCamera.lensOf(15.0, 50.0);
        let ta = Num.sin(15.0 * Num.pi() / 180.0) / Num.cos(15.0 * Num.pi() / 180.0);
        let tb = Num.sin(50.0 * Num.pi() / 180.0) / Num.cos(50.0 * Num.pi() / 180.0);
        Assert.assertTrue(near(lens#shiftY, 0.0 - (ta + tb) / (2.0 * (tb - ta))) and near(lens#shiftY, -0.79005))

    @Test
    def testScreenTopRowLooksDownFifteenDegrees(): Unit \ Assert =
        // 水平のカメラの画面の上の端（NDC の y = 1）の向きの下がり方の tan は ta
        let lens = TownCamera.lensOf(15.0, 50.0);
        let half = Num.sin(lens#fovY / 2.0) / Num.cos(lens#fovY / 2.0);
        Assert.assertTrue(near(0.0 - (1.0 + 2.0 * lens#shiftY) * half, lens#ta))

    @Test
    def testFrameEyeHeightOfTheAvenue(): Unit \ {Assert, IO} =
        let m = avenue();
        let lens = TownCamera.lensOf(15.0, 50.0);
        let d = 16.3 / ((lens#tb - lens#ta) * 16.0 / 9.0);
        Assert.assertTrue(near(TownCamera.frameEye(m, lens)#height, 1.25 + d * (lens#ta + 0.72 * (lens#tb - lens#ta))))

    // ── 隊列と追従カメラ ──

    def timeline(): Party.Timeline =
        Party.timelineOf({ col = 1, fromRow = 9, toRow = 1, party = Nil, frames = 4, cycleTiles = 1.0, idleSec = 1.0, stopSec = 0.7,
                           holdSec = 1.0, feetV = 0.55, groundFlowH = 0.14 }, 2.0)

    @Test
    def testCameraNeverMovesBackward(): Unit \ Assert =
        let tl = timeline();
        let samples = List.range(0, 400) |> List.map(i -> Party.cameraAt(tl, Int32.toFloat64(i) / 60.0));
        Assert.assertTrue(List.zip(samples, List.drop(1, samples)) |> List.forAll(pair -> snd(pair) >= fst(pair) - 0.0000001))

    @Test
    def testCameraKeepsUpWithLeaderWhileWalking(): Unit \ Assert =
        let tl = timeline();
        Assert.assertTrue(near(Party.cameraAt(tl, 3.0), Party.leaderAt(tl, 3.0)))

    @Test
    def testCameraSettlesOnLeaderAfterStop(): Unit \ Assert =
        let tl = timeline();
        Assert.assertTrue(near(Party.cameraAt(tl, tl#stopAt + tl#settle), tl#length))

    @Test
    def testFollowersStandOneAndTwoMetresBehindAtStart(): Unit \ {Assert, IO} =
        let m = avenue();
        let tl = timeline();
        let y = (i: Int32) -> snd(Party.memberAt(m, tl, 0.0, i));
        Assert.assertTrue(near(y(0) - y(1), 1.0) and near(y(0) - y(2), 2.0))

    @Test
    def testStandingFrameIsTheSecond(): Unit \ Assert =
        let tl = timeline();
        Assert.assertEq(expected = 1, Party.frameOf({ col = 1, fromRow = 9, toRow = 1, party = Nil, frames = 4, cycleTiles = 1.0, idleSec = 1.0,
                                                       stopSec = 0.7, holdSec = 1.0, feetV = 0.55, groundFlowH = 0.14 }, tl, tl#stopAt + 0.5, 0))

    // ── 町が出来ていく演出と曲がり角のある道 ──

    /// 先頭が 20 行目から 1 秒に 2 行ずつ 10 行目まで北へ歩く（5 秒）。
    def leaderRows(): Vector[(Float64, Float64)] =
        Vector.range(0, 300) |> Vector.map(f -> { let t = Int32.toFloat64(f) / 30.0; (t, Float64.max(10.0, 20.0 - 2.0 * t)) })

    @Test
    def testRowsAroundThePartyExistBeforeItWalks(): Unit \ Assert =
        Assert.assertTrue(Buildup.rowTimeOf(Buildup.defaultTiming(), leaderRows(), 17) < 1.0)

    @Test
    def testFrontRowAppearsWhenTheLeaderIsLeadRowsAway(): Unit \ Assert =
        // 12 行目は先頭が 16 行目（lead 4 行の手前）に来た 2 秒に出来る
        Assert.assertTrue(Float64.abs(Buildup.rowTimeOf(Buildup.defaultTiming(), leaderRows(), 12) - 2.0) < 0.05)

    @Test
    def testRowsBeyondTheWalkAppearAfterTheLeaderArrives(): Unit \ Assert =
        // 先頭が 10 行目に着くのは 5 秒・前線は 6 行目。2 行目はそこから 4 行 / 2.5 行毎秒
        Assert.assertTrue(Float64.abs(Buildup.rowTimeOf(Buildup.defaultTiming(), leaderRows(), 2) - (5.0 + 4.0 / 2.5)) < 0.05)

    def route(): Route.Route =
        Route.make(10, { col = 1, row = 8, wait = 0.0 } :: { col = 1, row = 6, wait = 1.0 } :: { col = 4, row = 6, wait = 0.0 } :: Nil, 2.0, 0.5)

    @Test
    def testRouteStandsStillDuringAWait(): Unit \ Assert =
        let r = route();
        Assert.assertTrue(near(Route.distanceAt(r, 1.6), 2.0) and near(Route.distanceAt(r, 2.4), 2.0))

    @Test
    def testRouteTurnsEastAfterTheCorner(): Unit \ Assert =
        Assert.assertEq(expected = Route.Dir.East, snd(Route.pointAt(route(), 3.0)))

    @Test
    def testFollowerBeforeTheStartStandsBehindOnTheFirstSegment(): Unit \ Assert =
        let ((_, y), _) = Route.pointAt(route(), -1.0);
        Assert.assertTrue(near(y, 0.5))

    @Test
    def testHannSmoothKeepsAConstantSpeedLine(): Unit \ Assert =
        let line = Vector.range(0, 40) |> Vector.map(i -> Int32.toFloat64(i) * 0.1);
        Assert.assertTrue(near(Vector.get(20, Route.hannSmooth(5, line)), 2.0))
}

