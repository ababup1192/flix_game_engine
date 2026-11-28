mod TestScenes {

    /// 種 1 の最初の値は mulberry32 の値と同じ。
    @Test
    def testRngSeed1FirstValueMatchesMulberry32(): Unit \ Assert =
        Assert.assertEq(expected = 0.6270739405881613, Rng.at(1, 0))

    /// 種 1 の 3 番目の値は mulberry32 の値と同じ（前の値を回さずに引いても同じ）。
    @Test
    def testRngSeed1ThirdValueMatchesMulberry32(): Unit \ Assert =
        Assert.assertEq(expected = 0.5274470399599522, Rng.at(1, 2))

    /// 大きな種でも mulberry32 の値と同じ。
    @Test
    def testRngSeed2100FirstValueMatchesMulberry32(): Unit \ Assert =
        Assert.assertEq(expected = 0.5739800236187875, Rng.at(2100, 0))

    /// intAt は 0 以上 n 未満。
    @Test
    def testIntAtStaysBelowBound(): Unit \ Assert =
        Assert.assertTrue(Vector.range(0, 200) |> Vector.forAll(k -> { let n = Rng.intAt(7, k, 8); n >= 0 and n < 8 }))

    /// 8 つの形の頂点の数は比べる相手の形と同じ。
    @Test
    def testFieldShapesVertexCounts(): Unit \ Assert =
        Assert.assertEq(expected = Vector#{24, 425, 148, 99, 561, 60, 24, 63}, Geometry.fieldShapes() |> Vector.map(s -> Vector.length(s#positions) / 3))

    /// 8 つの形の三角形の数は比べる相手の形と同じ。
    @Test
    def testFieldShapesTriangleCounts(): Unit \ Assert =
        Assert.assertEq(expected = Vector#{12, 720, 96, 48, 1024, 20, 8, 80}, Geometry.fieldShapes() |> Vector.map(Geometry.triangleCount))

    /// K2 の 500 個は 8 個ずつの親 63 個に入る。
    @Test
    def testK2GroupsOfEight(): Unit \ Assert =
        Assert.assertEq(expected = Some(63), Scenes.build(Scenes.Scenario.K2, 500)#groups |> Option.map(g -> g#count))

    /// 左手系の行列は、右手系の行列の Z の行と列だけの符号を替えた物（Z と Z の交わりはそのまま）。
    @Test
    def testMirroredWorldColumnsFlipsZRowAndColumnOnly(): Unit \ Assert =
        let f = Scenes.build(Scenes.Scenario.K2, 500);
        let flipped = Scenes.worldColumns(f, 1.25, 37) |> Vector.mapWithIndex((i, x) -> if ((Int32.remainder(i, 4) == 2) != (i / 4 == 2)) 0.0 - x else x);
        Assert.assertEq(expected = flipped, Scenes.mirroredWorldColumns(f, 1.25, 37))

    /// K3 のコマ 101 は組 1（物 20..39）だけを作り直す。
    @Test
    def testK3Frame101RebuildsOnlyBatchOne(): Unit \ Assert =
        let f = Scenes.build(Scenes.Scenario.K3, 2000);
        let g = Scenes.churnAt(101, f);
        let changed = Vector.range(0, 2000) |> Vector.filter(i -> Vector.get(i, f#scale) != Vector.get(i, g#scale));
        Assert.assertEq(expected = Vector.range(20, 40), changed)

    /// K3 の絵は一辺 128 の画素の数。
    @Test
    def testK3PixelsAre128Square(): Unit \ Assert =
        Assert.assertEq(expected = 16384, Vector.length(Scenes.churnPixels(7)))
}
