// WebGPU の描き手がまだ描けずに飛ばした物の、種類ごとの回数の表を固定する。
mod TestSkippedDraws {
    use RenderPaint.Internal.SkippedDraws

    /// 同じ種類を何度足しても、回数は足した数の合計になる。
    @Test
    def testCountsAddUpPerKind(): Unit \ {Assert, IO} =
        let c = SkippedDraws.fresh();
        discard SkippedDraws.add(c, "3D の影", 2);
        discard SkippedDraws.add(c, "3D の影", 3);
        discard SkippedDraws.add(c, "3D の空", 1);
        Assert.assertEq(expected = Some(5i64), Map.get("3D の影", Ref.get(c#counts)))

    /// 初めての種類だけ true（知らせは種類ごとに 1 回）。
    @Test
    def testOnlyFirstAddOfAKindIsNew(): Unit \ {Assert, IO} =
        let c = SkippedDraws.fresh();
        let first = SkippedDraws.add(c, "3D の影", 1);
        let second = SkippedDraws.add(c, "3D の影", 1);
        Assert.assertEq(expected = (true, false), (first, second))

    /// 0 回は種類として残らない（表に 0 回の行を出さない）。
    @Test
    def testZeroCountIsNotAKind(): Unit \ {Assert, IO} =
        let c = SkippedDraws.fresh();
        discard SkippedDraws.add(c, "3D の空", 0);
        Assert.assertTrue(Map.isEmpty(Ref.get(c#counts)))

    /// 表は reportFrame のコマで 1 回だけ返る（その後のコマでは返らない）。
    @Test
    def testTableComesOnceByFrames(): Unit \ {Assert, IO} =
        let c = SkippedDraws.fresh();
        discard SkippedDraws.add(c, "3D の影", 1);
        let frames = Int64.tryToInt32(2i64 * SkippedDraws.reportFrame()) |> Option.getWithDefault(0);
        let tables = List.range(0, frames) |> List.filterMap(_ -> SkippedDraws.endFrame(c));
        Assert.assertEq(expected = 1, List.length(tables))

    /// 飛ばした物が無ければ reportFrame のコマでも表は返らない。
    @Test
    def testNoTableAtReportFrameWithoutSkips(): Unit \ {Assert, IO} =
        let c = SkippedDraws.fresh();
        let frames = Int64.tryToInt32(SkippedDraws.reportFrame()) |> Option.getWithDefault(0);
        let tables = List.range(0, frames) |> List.filterMap(_ -> SkippedDraws.endFrame(c));
        Assert.assertEq(expected = 0, List.length(tables))

    /// 数えたコマが 0 なら 1 コマあたりの回数は "-"。
    @Test
    def testPerFrameIsDashWithoutFrames(): Unit \ Assert =
        Assert.assertEq(expected = "[webgpu] まだ描けずに飛ばした物（終わり・種類ごとの回数）:\n  3D の空: 2 回（1 コマあたり -）",
                        SkippedDraws.buildTable("終わり", 0i64, ("3D の空", 2i64) :: Nil))

    /// 飛ばした物が無ければ表は返らない。
    @Test
    def testNoTableWithoutSkips(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = None, SkippedDraws.tableOf(SkippedDraws.fresh(), "終わり"))

    /// 表の行は回数の多い順で、1 コマあたりの回数を小数 1 桁で添える。
    @Test
    def testTableListsKindsByCount(): Unit \ Assert =
        let table = SkippedDraws.buildTable("終わり", 4i64, ("3D の空", 2i64) :: ("3D の影", 10i64) :: Nil);
        Assert.assertEq(expected = "[webgpu] まだ描けずに飛ばした物（終わり・種類ごとの回数）:\n  3D の影: 10 回（1 コマあたり 2.5）\n  3D の空: 2 回（1 コマあたり 0.5）", table)
}
