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

    /// 広場のにぎやかしの 3 件（park の屋台・pass の馬車・行き来する馬）を足した地図。
    def withDecor(): TownMap =
        let props = ", \"props\": [{\"sprite\": \"market_stall.png\", \"at\": [1, 2], \"off\": [0.1, 0.2], \"frames\": 2, \"seq\": [0, 1, 1]}," +
                    " {\"variant\": \"pass\", \"sprite\": \"carriage.png\", \"at\": [0, 0]}," +
                    " {\"variant\": \"park\", \"sprite\": \"horse.png\", \"at\": [2, 0], \"move\": [0, 0, 0.9]}]}";
        let json = String.dropRight(1, miniJson()) + props;
        match DocJson.parse(json) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownMap.decode("step")) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    @Test
    def testDecorKeepsOnlyParkWithoutMove(): Unit \ Assert =
        Assert.assertEq(expected = "sprites/market_stall.png" :: Nil, withDecor()#decor |> List.map(d -> d#sprite))

    @Test
    def testDecorReadsTheFrameSequence(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: 1 :: 1 :: Nil, withDecor()#decor |> List.flatMap(d -> d#seq))

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

    /// 前線が 4 行先・奥の行は 2.5 行毎秒の決まり（既定値が変わってもこのテストの数は変わらない）。
    def fixedTiming(): Buildup.Timing = { lead = 4.0, afterRowsPerSec = 2.5 | Buildup.defaultTiming() }

    /// 先頭が 20 行目から 1 秒に 2 行ずつ 10 行目まで北へ歩く（5 秒）。
    def leaderRows(): Vector[(Float64, Float64)] =
        Vector.range(0, 300) |> Vector.map(f -> { let t = Int32.toFloat64(f) / 30.0; (t, Float64.max(10.0, 20.0 - 2.0 * t)) })

    @Test
    def testRowsAroundThePartyExistBeforeItWalks(): Unit \ Assert =
        Assert.assertTrue(Buildup.rowTimeOf(Buildup.defaultTiming(), leaderRows(), 17) < 1.0)

    @Test
    def testFrontRowAppearsWhenTheLeaderIsLeadRowsAway(): Unit \ Assert =
        // 12 行目は先頭が 16 行目（lead 4 行の手前）に来た 2 秒に出来る
        Assert.assertTrue(Float64.abs(Buildup.rowTimeOf(fixedTiming(), leaderRows(), 12) - 2.0) < 0.05)

    @Test
    def testRowsBeyondTheWalkAppearAfterTheLeaderArrives(): Unit \ Assert =
        // 先頭が 10 行目に着くのは 5 秒・前線は 6 行目。2 行目はそこから 4 行 / 2.5 行毎秒
        Assert.assertTrue(Float64.abs(Buildup.rowTimeOf(fixedTiming(), leaderRows(), 2) - (5.0 + 4.0 / 2.5)) < 0.05)

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

    // ── 歩きながら変わる時刻 ──

    def dusk(): TownScene.Look = { exposure = -0.2, sunAzimuth = -75.0, sunIntensity = 8.0 | TownLook.defaults() }

    def night(): TownScene.Look =
        { exposure = -2.0, sunAzimuth = -35.0, sunIntensity = 0.2, lampIntensity = 260.0,
          boardLight = TownScene.BoardLight.Unlit | TownLook.defaults() }

    def fogNight(): TownScene.Look =
        { heightFog = Some({ color = TownLook.defaults()#fog, density = 0.8, baseHeight = 1.0, heightFalloff = 1.2, startDistance = 0.0,
                             maxOpacity = 0.5, noise = None, lightGlow = 0.02 }) | night() }

    def schedule(): TownLook.Schedule =
        { day = TownLook.defaults(), dusk = dusk(), night = night(), fog = fogNight(),
          rows = { dayToDusk = (50.0, 44.0), duskToNight = (36.0, 24.0), moonRow = 29.0, lampOn = (36.0, 25.0), nightToFog = (17.0, 8.0) },
          mode = TownLook.Transition.Blend, transitionSec = 0.0, transitionRows = 0.0 }

    /// 同じ境目で、区間の真ん中の行（47・30・12.5）で 1 コマで替える移り方。
    def cutSchedule(): TownLook.Schedule = { mode = TownLook.Transition.Cut | schedule() }

    /// 同じ境目で、真ん中の行の前後 2 行（± 1 行）だけでつなぐ移り方。
    def shortSchedule(): TownLook.Schedule = { transitionRows = 2.0 | cutSchedule() }

    @Test
    def testShortTransitionKeepsTheDayBeforeItsWindow(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(shortSchedule(), 48.05)#exposure, TownLook.defaults()#exposure))

    @Test
    def testShortTransitionIsHalfwayAtTheMiddleRow(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(shortSchedule(), 47.0)#exposure, (TownLook.defaults()#exposure + -0.2) / 2.0))

    @Test
    def testShortTransitionIsTheWholeDuskAfterItsWindow(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(shortSchedule(), 45.95)#exposure, -0.2))

    @Test
    def testShortNightfallLightsTheLampsBeforeTheSunIsGone(): Unit \ Assert =
        let look = TownLook.atRow(shortSchedule(), 30.0);
        Assert.assertTrue(near(look#lampIntensity, 260.0) and look#sunIntensity > 0.0)

    @Test
    def testShortNightfallIsTheWholeNightAfterItsWindow(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(shortSchedule(), 28.95)#exposure, -2.0))

    @Test
    def testTransitionSecondsBecomeRowsAtTheWalkSpeed(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.withWalkSpeed(3.5, { transitionSec = 0.4 | cutSchedule() })#transitionRows, 1.4))

    @Test
    def testWalkSpeedSkipsTheWait(): Unit \ Assert =
        Assert.assertTrue(near(BuildVideo.walkSpeedOf(route()), 2.0))

    @Test
    def testCutKeepsTheDayJustSouthOfRow47(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(cutSchedule(), 47.05)#sunAzimuth, 35.0))

    @Test
    def testCutIsTheWholeDuskJustNorthOfRow47(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(cutSchedule(), 46.95)#exposure, -0.2))

    @Test
    def testCutKeepsTheDuskJustSouthOfRow30(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(cutSchedule(), 30.05)#sunAzimuth, -75.0))

    @Test
    def testCutTakesTheMoonJustNorthOfRow30(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(cutSchedule(), 29.95)#sunAzimuth, -35.0))

    @Test
    def testCutMakesTheBoardsUnlitJustNorthOfRow30(): Unit \ Assert =
        Assert.assertEq(expected = TownScene.BoardLight.Unlit, TownLook.atRow(cutSchedule(), 29.95)#boardLight)

    @Test
    def testCutLightsTheLampsFullyJustNorthOfRow30(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(cutSchedule(), 29.95)#lampIntensity, 260.0))

    @Test
    def testCutHasNoHeightFogJustSouthOfRow12AndAHalf(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(TownLook.atRow(cutSchedule(), 12.55)#heightFog))

    @Test
    def testCutHasTheWholeHeightFogJustNorthOfRow12AndAHalf(): Unit \ Assert =
        let density = TownLook.atRow(cutSchedule(), 12.45)#heightFog |> Option.map(h -> h#density) |> Option.getWithDefault(0.0);
        Assert.assertTrue(near(density, 0.8))

    @Test
    def testTimeOfDayWithoutModeCuts(): Unit \ Assert =
        Assert.assertEq(expected = TownLook.Transition.Cut, TownLook.timeOfDayOf(Map.empty())#mode)

    @Test
    def testBlendAtZeroKeepsTheFirstLook(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.blend(dusk(), night(), 0.0)#exposure, -0.2))

    @Test
    def testBlendAtOneReachesTheSecondLook(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.blend(dusk(), night(), 1.0)#exposure, -2.0))

    @Test
    def testHalfwayToFogHasHalfTheHeightFogDensity(): Unit \ Assert =
        let density = TownLook.blend(night(), fogNight(), 0.5)#heightFog |> Option.map(h -> h#density) |> Option.getWithDefault(0.0);
        Assert.assertTrue(near(density, 0.4))

    @Test
    def testJustBeforeTheMoonRowTheSunKeepsTheDuskDirection(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(schedule(), 29.05)#sunAzimuth, -75.0))

    @Test
    def testJustAfterTheMoonRowTheLightTakesTheMoonDirection(): Unit \ Assert =
        Assert.assertTrue(near(TownLook.atRow(schedule(), 28.95)#sunAzimuth, -35.0))

    @Test
    def testAtTheMoonRowTheSunIsOff(): Unit \ Assert =
        Assert.assertTrue(TownLook.atRow(schedule(), 29.0)#sunIntensity < 0.001)

    @Test
    def testJustBeforeTheMoonRowTheBoardsAreLit(): Unit \ Assert =
        Assert.assertEq(expected = TownScene.BoardLight.Lit, TownLook.atRow(schedule(), 29.05)#boardLight)

    @Test
    def testJustAfterTheMoonRowTheBoardsAreUnlit(): Unit \ Assert =
        Assert.assertEq(expected = TownScene.BoardLight.Unlit, TownLook.atRow(schedule(), 28.95)#boardLight)

    @Test
    def testAtTheMoonRowTheLampsAreAlreadyMostlyOn(): Unit \ Assert =
        let k = TownLook.atRow(schedule(), 29.0)#lampIntensity / 260.0;
        Assert.assertTrue(k >= 0.5 and k <= 0.75)

    @Test
    def testJustAfterTheMoonRowTheBoardsStillLookLit(): Unit \ Assert =
        Assert.assertTrue(TownLook.atRow(schedule(), 28.95)#litToUnlit < 0.05)

    // ── 洞窟の地図（段・足の高さ・path・地図ごとの板・地図の外） ──

    /// 1 列 × 3 行の洞窟（南の平らなマス → 北へ上る段 → 北の平らなマス・0.5 m 刻み・北のマスに結晶 K と高さ 2 m の岩の塊・地図の外は岩で森なし）。
    def caveJson(): String =
        "{\"ground\": [\"p\", \"p\", \"p\"], \"height\": [\"2\", \"1\", \"1\"], \"shape\": [\".\", \"^\", \".\"], \"objects\": [\"K\", \".\", \".\"]," +
        " \"buildings\": [], \"heightStep\": 0.5, \"margin\": {\"cells\": 2, \"level\": -6, \"ground\": \"r\", \"objects\": \"none\"}," +
        " \"groundTiles\": {\"p\": \"tiles/lava_path.png\", \"r\": \"tiles/basalt_top.png\"}, \"tileOverrides\": {\"water\": \"tiles/lava.png\"}," +
        " \"objectSprites\": {\"K\": {\"sprite\": \"lava_crystal.png\", \"height\": 1.2}}, \"rockBoxes\": [[0, 0, 1.0, 1.0, 2.0]], \"rockBoxTop\": \"r\"," +
        " \"camera\": {\"targetZ\": 1.25, \"target\": [0.5, 1.0], \"frame\": {\"anchor\": [0.5, 2.0], \"v\": 0.72, \"width\": 16.3}}," +
        " \"walk\": {\"path\": [[0, 2], [0, 0]], \"endFace\": \"n\", \"camZLagK\": 2.5, \"followZoom\": 1.35, \"party\": [{\"strip\": \"a.png\", \"idleStrip\": \"b.png\"}]}}"

    def cave(): TownMap =
        match DocJson.parse(caveJson()) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownMap.decode("step")) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    def caveQuads(material: String): Int32 =
        TileMap3d.build(cave(), Map#{ "sprites/lava_crystal.png" => (42, 48) }, None)#quads |> List.filter(q -> q#material == material) |> List.length

    @Test
    def testFlatCellFootIsItsTop(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.groundZAt(cave(), 0.5, 0.5), 0.5))

    @Test
    def testStairFootIsOnTheFrontEdgeOfTheTread(): Unit \ Assert =
        // 段のマスの真ん中は 3 段目の踏み面の前の縁: 0.5 + (0.5 + 0.25) × 0.5
        Assert.assertTrue(near(TownMap.groundZAt(cave(), 0.5, 1.5), 0.875))

    @Test
    def testCellBeforeTheStairsRisesInItsLastQuarter(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.groundZAt(cave(), 0.5, 0.9), 0.575))

    @Test
    def testFootHeightHasNoJumpAcrossTheStairs(): Unit \ Assert =
        let m = cave();
        let zs = List.range(0, 300) |> List.map(i -> TownMap.groundZAt(m, 0.5, Int32.toFloat64(i) / 100.0));
        Assert.assertTrue(List.zip(zs, List.drop(1, zs)) |> List.forAll(pair -> Float64.abs(snd(pair) - fst(pair)) < 0.01))

    @Test
    def testWalkPathIsRead(): Unit \ Assert =
        let path = cave()#walkPath |> Option.map(pw -> pw#path |> List.map(w -> (w#col, w#row))) |> Option.getWithDefault(Nil);
        Assert.assertEq(expected = (0, 2) :: (0, 0) :: Nil, path)

    @Test
    def testWalkEndFaceIsRead(): Unit \ Assert =
        Assert.assertEq(expected = Some(Route.Dir.North), cave()#walkPath |> Option.map(pw -> pw#endFace))

    @Test
    def testWalkWithoutPathHasNoPathWalk(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(mini("")#walkPath))

    @Test
    def testObjectSpriteLetterBecomesASprite(): Unit \ Assert =
        Assert.assertEq(expected = Prop.Sprite('K'), TownMap.propAt(cave(), 0, 0))

    @Test
    def testObjectSpriteReadsThePictureUnderSprites(): Unit \ Assert =
        Assert.assertEq(expected = Some("sprites/lava_crystal.png"), Map.get('K', cave()#objectSprites) |> Option.map(o -> o#sprite))

    @Test
    def testMarginGroundIsTheRockTop(): Unit \ Assert =
        Assert.assertEq(expected = Ground.RockTop, TownMap.groundAt(cave(), -1, 0))

    @Test
    def testMarginNoneLeavesOnlyTheMapsBoards(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(TileMap3d.build(cave(), Map#{ "sprites/lava_crystal.png" => (42, 48) }, None)#boards))

    @Test
    def testStairsHaveFourTreadsBesideTheTwoFloors(): Unit \ Assert =
        Assert.assertEq(expected = 6, caveQuads("path"))

    @Test
    def testTallRockBoxGetsACapBesideTheFourMarginPlanes(): Unit \ Assert =
        Assert.assertEq(expected = 6, caveQuads("rock_top"))

    @Test
    def testTileOverrideReplacesTheWaterPicture(): Unit \ Assert =
        Assert.assertEq(expected = Some("tiles/lava.png"), Map.get("water", TileMap3d.materialTableOf(cave())) |> Option.map(fst))

    @Test
    def testFireCaveReadsAllRockBoxes(): Unit \ {Assert, IO} =
        match (run { TownMap.load("step", "assets/fire_cave.map.json") } with Fs.FileRead.runWithIO) {
            case Ok(m)    => Assert.assertEq(expected = 172, List.length(m#rockBoxes))
            case Err(why) => bug!(why)
        }

    // ── 炎・氷の見た目の欄（StageFx） ──

    def fireMap(): (TownMap, StageFx.Fx) \ IO =
        match (run { TownMap.load("step", "assets/fire_cave.map.json") |> Result.flatMap(m -> StageFx.load("assets/fire_cave.map.json") |> Result.map(fx -> (m, fx))) } with Fs.FileRead.runWithIO) {
            case Ok(mf)   => mf
            case Err(why) => bug!(why)
        }

    @Test
    def testFireLavaGlowsWithoutLight(): Unit \ {Assert, IO} =
        let (_, fx) = fireMap();
        let unlit = match Map.get("water", fx#glows) {
            case Some(StageFx.Glow.Unlit(_)) => true
            case _                           => false
        };
        Assert.assertTrue(unlit)

    @Test
    def testFireFloorCracksGlowRed(): Unit \ {Assert, IO} =
        let (_, fx) = fireMap();
        let cracks = match Map.get("path", fx#glows) {
            case Some(StageFx.Glow.Cracks(c)) => near(c#k, 1.6)
            case _                            => false
        };
        Assert.assertTrue(cracks)

    @Test
    def testFireLavaLightsAreThinnedToAtMostEight(): Unit \ {Assert, IO} =
        let (m, fx) = fireMap();
        let n = List.length(StageFx.lightsAt(m, fx, 1.0, 0.0));
        Assert.assertTrue(n >= 4 and n <= 10)

    @Test
    def testFireHasFiveEmbers(): Unit \ {Assert, IO} =
        let (m, fx) = fireMap();
        let n = fx#particles |> Option.map(p -> List.length(StageFx.particlesAt(m, p, 1.0, (0.0, 0.0, 0.0)))) |> Option.getWithDefault(0);
        Assert.assertEq(expected = 5, n)

    @Test
    def testFireRimStandsBesideTheLava(): Unit \ {Assert, IO} =
        let (m, fx) = fireMap();
        Assert.assertTrue(List.length(StageFx.rimQuads(m, fx)) > 10)

    @Test
    def testFireHeatComesFromTheLava(): Unit \ {Assert, IO} =
        let (_, fx) = fireMap();
        Assert.assertTrue(fx#heat |> Option.map(h -> Set.memberOf(Ground.Water, h#grounds)) |> Option.getWithDefault(false))

    @Test
    def testTownHasNoStageFx(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(StageFx.none()#heat) and Map.isEmpty(StageFx.none()#glows))
}
