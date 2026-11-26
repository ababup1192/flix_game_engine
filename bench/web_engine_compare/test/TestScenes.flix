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

    /// 左手系へ写す時は Z の行と列だけの符号を替える（Z と Z の交わりはそのまま）。
    @Test
    def testMirroredColumnsFlipsZRowAndColumnOnly(): Unit \ Assert =
        Assert.assertEq(expected = Vector#{1.0, 2.0, -3.0, 4.0, 5.0, 6.0, -7.0, 8.0, -9.0, -10.0, 11.0, -12.0, 13.0, 14.0, -15.0, 16.0},
                        Draw.mirroredColumns(Vector.range(1, 17) |> Vector.map(Int32.toFloat64)))
}
