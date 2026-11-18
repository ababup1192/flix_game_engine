// TestTown — 地図の読み・立体の決まり・面の向きと uv・カメラの式・段と階段の足の高さを、その場で書いた地図で固定する。
mod TestTown {
    use fge::{DocJson, Num}
    use Faces.{Quad}
    use TownMap.{Ground, Prop, TownMap}

    /// 3×3 の小さな地図（真ん中だけ石畳・北西の 2 マスに生垣・草を 0.25 m 上げる）。
    def miniJson(): String =
        "{\"ground\": [\"ggg\", \"gcg\", \"ggg\"], \"height\": [\"111\", \"1a1\", \"111\"], \"shape\": [\"...\", \"...\", \"...\"]," +
        " \"objects\": [\"HH.\", \".2.\", \"...\"], \"buildings\": [], \"heightStep\": 1.0, \"margin\": {\"cells\": 2, \"level\": -2}," +
        " \"curbRaise\": 0.25, \"coping\": true}"

    def decoded(json: String): TownMap =
        match DocJson.parse(json) |> Option.toOk("JSON が読めない") |> Result.flatMap(TownMap.decode) {
            case Ok(m)    => m
            case Err(why) => bug!(why)
        }

    def mini(): TownMap = decoded(miniJson())

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.0001

    // ── 地図の読み ──

    @Test
    def testGroundLetterBecomesCobble(): Unit \ Assert =
        Assert.assertEq(expected = Ground.Cobble, TownMap.groundAt(mini(), 1, 1))

    @Test
    def testHeightLetterIsBase36(): Unit \ Assert =
        Assert.assertEq(expected = 10, TownMap.levelAt(mini(), 1, 1))

    @Test
    def testObjectLetterTwoIsMerchant(): Unit \ Assert =
        Assert.assertEq(expected = Prop.Npc(2), TownMap.propAt(mini(), 1, 1))

    @Test
    def testOutsideTheMapUsesMarginLevel(): Unit \ Assert =
        Assert.assertEq(expected = -2, TownMap.levelAt(mini(), -1, 0))

    @Test
    def testCurbRaiseLiftsTheGrass(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.topAt(mini(), 0, 0), 1.25))

    @Test
    def testWithoutCurbRaiseGrassStaysAtLevel(): Unit \ Assert =
        let flat = decoded(String.replace(src = "\"curbRaise\": 0.25", dst = "\"curbRaise\": 0.0", miniJson()));
        Assert.assertTrue(near(TownMap.topAt(flat, 0, 0), 1.0))

    @Test
    def testRowsOfDifferentSizeAreRefused(): Unit \ Assert =
        let broken = String.replace(src = "\"shape\": [\"...\", \"...\", \"...\"]", dst = "\"shape\": [\"..\"]", miniJson());
        Assert.assertTrue(DocJson.parse(broken) |> Option.map(j -> Result.isErr(TownMap.decode(j))) |> Option.getWithDefault(false))

    @Test
    def testBuildingRoofFieldsAreReadFlat(): Unit \ Assert =
        let json = String.replace(src = "\"buildings\": []",
                                  dst = "\"buildings\": [{\"id\": \"inn\", \"x\": 0, \"y\": 0, \"w\": 2, \"h\": 1, \"ridge\": \"x\", \"pitchDeg\": 30, \"overhang\": 0.5}]",
                                  miniJson());
        Assert.assertEq(expected = Some((TownMap.Ridge.X, 30.0, 0.5)), decoded(json)#buildings |> List.head |> Option.map(b -> (b#ridge, b#pitchDeg, b#overhang)))

    // ── 立体の決まり ──

    def townOf(m: TownMap): TileMap3d.Town = TileMap3d.build(m, Map.empty())

    def zRange(q: Quad): (Float64, Float64) =
        let zs = q#points |> List.map(p -> p#z);
        (List.foldLeft(Float64.min, 1000.0, zs), List.foldLeft(Float64.max, -1000.0, zs))

    /// 真ん中を 1 段下げた石畳にした地図: 真ん中の高さ 1・まわりの草 1.25。
    def sunkCenter(): TownMap =
        let m = mini();
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
    def testCoordinateHashIsFixed(): Unit \ Assert =
        Assert.assertTrue(near(TileMap3d.h01(3, 5, 1), 0.7966430151827267))

    @Test
    def testCoordinateHashOfANegativeColumnIsFixed(): Unit \ Assert =
        Assert.assertTrue(near(TileMap3d.h01(-30, 2, 7), 0.5274128328374151))

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
        Assert.assertTrue(near(TownCamera.lensOf(15.0, 50.0)#shiftY, -0.79005))

    @Test
    def testScreenTopRowLooksDownFifteenDegrees(): Unit \ Assert =
        // 水平のカメラの画面の上の端（NDC の y = 1）の向きの下がり方の tan は ta
        let lens = TownCamera.lensOf(15.0, 50.0);
        let half = Num.sin(lens#fovY / 2.0) / Num.cos(lens#fovY / 2.0);
        Assert.assertTrue(near(0.0 - (1.0 + 2.0 * lens#shiftY) * half, lens#ta))

    @Test
    def testFrameHeightPutsTheGroundPointAtTheFrameRow(): Unit \ Assert =
        // 目の高さ − 地面の高さ = 奥行き × その行の tan。奥行きは横幅 16.3 m の時の物
        let lens = TownCamera.lensOf(15.0, 50.0);
        let depth = 16.3 / ((lens#tb - lens#ta) * 16.0 / 9.0);
        Assert.assertTrue(near(TownCamera.frameHeight(lens, 16.3, 0.72, 1.25), 1.25 + depth * TownCamera.tanAt(lens, 0.72)))

    // ── 段と階段の足の高さ ──

    /// 1 列 × 3 行（南の平らなマス → 北へ上る段 → 北の平らなマス・0.5 m 刻み）。
    def stairsJson(): String =
        "{\"ground\": [\"c\", \"c\", \"c\"], \"height\": [\"2\", \"1\", \"1\"], \"shape\": [\".\", \"^\", \".\"], \"objects\": [\".\", \".\", \".\"]," +
        " \"buildings\": [], \"heightStep\": 0.5, \"margin\": {\"cells\": 2, \"level\": -6, \"forest\": false}}"

    def stairs(): TownMap = decoded(stairsJson())

    @Test
    def testFlatCellFootIsItsTop(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.groundZAt(stairs(), 0.5, 0.5), 0.5))

    @Test
    def testStairFootIsOnTheFrontEdgeOfTheTread(): Unit \ Assert =
        // 段のマスの真ん中は 3 段目の踏み面の前の縁: 0.5 + (0.5 + 0.25) × 0.5
        Assert.assertTrue(near(TownMap.groundZAt(stairs(), 0.5, 1.5), 0.875))

    @Test
    def testCellBeforeTheStairsRisesInItsLastQuarter(): Unit \ Assert =
        Assert.assertTrue(near(TownMap.groundZAt(stairs(), 0.5, 0.9), 0.575))

    @Test
    def testFootHeightHasNoJumpAcrossTheStairs(): Unit \ Assert =
        let m = stairs();
        let zs = List.range(0, 300) |> List.map(i -> TownMap.groundZAt(m, 0.5, Int32.toFloat64(i) / 100.0));
        Assert.assertTrue(List.zip(zs, List.drop(1, zs)) |> List.forAll(pair -> Float64.abs(snd(pair) - fst(pair)) < 0.01))

    /// 木の絵の大きさを知っている時の町（地図の外の森の板が立つ）。
    def withTrees(m: TownMap): TileMap3d.Town =
        TileMap3d.build(m, Map#{ "sprites/tree_broadleaf.png" => (64, 96), "sprites/tree_cypress.png" => (32, 96) })

    @Test
    def testMarginWithoutForestLeavesNoBoards(): Unit \ Assert =
        Assert.assertEq(expected = 0, List.length(withTrees(stairs())#boards))

    @Test
    def testMarginWithForestStandsTrees(): Unit \ Assert =
        Assert.assertTrue(List.length(withTrees(mini())#boards) > 0)
}
