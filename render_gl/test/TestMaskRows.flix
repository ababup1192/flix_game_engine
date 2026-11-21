// mask つきスプライトと mask つきの面が RenderList の行になる所と、stencil の比べる値の決まり（GL を呼ばない前半）を固定する。
// 並べた物（Merged）を emitRowItem へ順に渡して run を閉じ、行の欄を読む（倍率 1・絵は箱だけ）。
// WhyNot: mod TestMaskRows にしない — 行を作る関数は RenderFrame の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderFrame.TestMaskRows {
    import java.nio.FloatBuffer
    use RenderFrame.{Merged, closeRuns, emitRowItem, stateSize, usesStencil}
    use RenderFrame.Internal.RenderList.{ListRowKind, RenderList, instanceFloats, maxMaskRef, newRenderList, nextInstanceOf, nextMaskRef,
                                         nextVertexOf, rowCountOf, rowsOf, stencilRefOf, vertexFloats}

    // ── 組み立て ──

    def v(x: Float64, y: Float64): Vec2.Vec2 = { x = x, y = y }

    /// x に置いた 4 × 4 の箱。mask = 箱のローカル座標の多角形の列。
    def boxAt(x: Float64, mask: List[List[Vec2.Vec2]]): Merged =
        Merged.MSprite(DrawCmd.make({
          texture = "", position = v(x, 0.0), scale = v(4.0, 4.0), rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = v(0.0, 0.0), uvScale = v(1.0, 1.0), zIndex = 0, style = None, clip = None,
          blend = DrawCmd.BlendMode.Normal, mask = mask, squashY = 1.0 }))

    /// 三角形 1 枚の mask。
    def triangle(): List[List[Vec2.Vec2]] = (v(0.0, 0.0) :: v(4.0, 0.0) :: v(0.0, 4.0) :: Nil) :: Nil

    /// 四角（三角形 2 枚）と、その内側の三角形の 2 つの多角形の mask。
    def nested(): List[List[Vec2.Vec2]] =
        (v(0.0, 0.0) :: v(4.0, 0.0) :: v(4.0, 4.0) :: v(0.0, 4.0) :: Nil) :: (v(1.0, 1.0) :: v(3.0, 1.0) :: v(1.0, 3.0) :: Nil) :: Nil

    /// 2 頂点しかない mask（三角形にならない）。
    def degenerate(): List[List[Vec2.Vec2]] = (v(0.0, 0.0) :: v(4.0, 0.0) :: Nil) :: Nil

    def masked(): Merged = boxAt(0.0, triangle())

    def plain(): Merged = boxAt(8.0, Nil)

    /// 並べた物を順に積んで run を閉じた (状態, 列)。
    def emitted(items: List[Merged]): (Array[Int32, Static], RenderList) \ IO =
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        let n = List.length(items) + 1;
        let list = newRenderList(FloatBuffer.allocate(instanceFloats() * n), FloatBuffer.allocate(vertexFloats() * 12 * n));
        List.forEach(item -> emitRowItem(st, list, 1.0, 1.0, Map.empty(), Set.empty(), Ref.fresh(Static, Set.empty()), item), items);
        closeRuns(st, list);
        (st, list)

    def listOf(items: List[Merged]): RenderList \ IO = snd(emitted(items))

    def cell(list: RenderList, row: Int32, col: Int32): Int32 \ IO = RenderFrame.TestRenderList.cellAt(rowsOf(list), row, col)

    /// 行の (種類, 1 番の欄, 2 番の欄, 10 番の欄, 11 番の欄)。
    def maskCells(list: RenderList, row: Int32): (Int32, Int32, Int32, Int32, Int32) \ IO =
        (cell(list, row, 0), cell(list, row, 1), cell(list, row, 2), cell(list, row, 10), cell(list, row, 11))

    // ── 行の欄 ──

    /// mask つきスプライト 1 体は 1 行で、instance 0・三角形 3 頂点（先頭 0）・比べる値 1。
    @Test
    def testMaskedSpriteIsAMaskRow(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (RenderFrame.TestRenderList.codeOf(ListRowKind.Mask), 0, 3, 0, 1), maskCells(listOf(masked() :: Nil), 0))

    /// 2 つの多角形の mask は、両方を三角形にほどいた頂点（6 + 3）を 1 行に持つ。
    @Test
    def testNestedPolygonsShareOneRow(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 9, cell(listOf(boxAt(0.0, nested()) :: Nil), 0, 2))

    /// 続く mask は比べる値が 1 ずつ進む。
    @Test
    def testSecondMaskAdvancesRef(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, cell(listOf(masked() :: masked() :: Nil), 1, 11))

    /// 続く mask の頂点は、前の mask の頂点の後ろから始まる。
    @Test
    def testSecondMaskVerticesFollow(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 3, cell(listOf(masked() :: masked() :: Nil), 1, 10))

    /// 三角形にならない mask は頂点 0・比べる値 0（stencil を使わずに描く）。
    @Test
    def testDegenerateMaskHasNoRef(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (RenderFrame.TestRenderList.codeOf(ListRowKind.Mask), 0, 0, 0, 0), maskCells(listOf(boxAt(0.0, degenerate()) :: Nil), 0))

    /// 三角形にならない mask は比べる値を進めない（次の mask は 1）。
    @Test
    def testDegenerateMaskKeepsRef(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1, cell(listOf(boxAt(0.0, degenerate()) :: masked() :: Nil), 1, 11))

    /// mask の前に溜めたスプライトの run は先に行になる（行は run・mask の順）。
    @Test
    def testRunBeforeMaskIsClosed(): Unit \ {Assert, IO} =
        let list = listOf(plain() :: plain() :: masked() :: Nil);
        Assert.assertEq(expected = (RenderFrame.TestRenderList.codeOf(ListRowKind.Sprite), 2, RenderFrame.TestRenderList.codeOf(ListRowKind.Mask)), (cell(list, 0, 0), cell(list, 0, 2), cell(list, 1, 0)))

    /// mask の後の mask の無いスプライトは、mask の行に混ざらず次の行の頭（instance 1）から始まる。
    @Test
    def testPlainAfterMaskIsOwnRow(): Unit \ {Assert, IO} =
        let list = listOf(masked() :: plain() :: Nil);
        Assert.assertEq(expected = (RenderFrame.TestRenderList.codeOf(ListRowKind.Sprite), 1, 1), (cell(list, 1, 0), cell(list, 1, 1), cell(list, 1, 2)))

    /// 行を積んだ後の次の instance と頂点の番号は、mask の 1 体と 3 頂点の後ろ。
    @Test
    def testMaskAdvancesInstanceAndVertex(): Unit \ {Assert, IO} =
        let list = listOf(masked() :: Nil);
        Assert.assertEq(expected = (1, 3), (nextInstanceOf(list), nextVertexOf(list)))

    /// 上限を超える数の mask を 1 つの pass に積むと、上限の次の mask は 1 に戻る。
    @Test
    def testRefWrapsAfterMax(): Unit \ {Assert, IO} =
        let list = listOf(List.repeat(maxMaskRef() + 1, masked()));
        Assert.assertEq(expected = (maxMaskRef(), 1), (cell(list, maxMaskRef() - 1, 11), cell(list, maxMaskRef(), 11)))

    // ── stencil を使うか ──

    /// mask の無い pass は stencil を使わない。
    @Test
    def testPlainPassUsesNoStencil(): Unit \ {Assert, IO} =
        Assert.assertFalse(usesStencil(fst(emitted(plain() :: Nil))))

    /// mask のある pass は stencil を使う。
    @Test
    def testMaskedPassUsesStencil(): Unit \ {Assert, IO} =
        Assert.assertTrue(usesStencil(fst(emitted(plain() :: masked() :: Nil))))

    /// 三角形にならない mask だけの pass は stencil を使わない。
    @Test
    def testDegenerateOnlyPassUsesNoStencil(): Unit \ {Assert, IO} =
        Assert.assertFalse(usesStencil(fst(emitted(boxAt(0.0, degenerate()) :: Nil))))

    // ── nextMaskRef ──

    /// pass で初めての mask は 1。
    @Test
    def testFirstRefIsOne(): Unit \ Assert =
        Assert.assertEq(expected = 1, nextMaskRef(0))

    /// 前の値の次は 1 大きい。
    @Test
    def testRefAdvancesByOne(): Unit \ Assert =
        Assert.assertEq(expected = 255, nextMaskRef(254))

    /// 上限の次は 1 に戻る。
    @Test
    def testRefAfterMaxIsOne(): Unit \ Assert =
        Assert.assertEq(expected = 1, nextMaskRef(maxMaskRef()))

    // ── mask つきの面（比べる値は mask つきスプライトと同じ数え方）──

    /// 箱 10 × 10 の面。mask = 面を切り抜く多角形の列。
    def surfaceWith(mask: List[List[Vec2.Vec2]]): Merged =
        Merged.MSurface({ program = GpuHandle.wrapShaderProgram(1), texReads = Nil, rect = { position = v(0.0, 0.0), size = v(10.0, 10.0) },
                          mask = mask, time = 0.0, zIndex = 0, blend = DrawCmd.BlendMode.Normal, alpha = 1.0, params = Nil })

    /// mask つきの面だけでも、その pass は stencil を使う。
    @Test
    def testMaskedSurfaceUsesStencil(): Unit \ {Assert, IO} =
        Assert.assertTrue(usesStencil(fst(emitted(surfaceWith(triangle()) :: Nil))))

    /// mask の無い面は stencil を使わず、比べる値 0。
    @Test
    def testPlainSurfaceDoesNotUseStencil(): Unit \ {Assert, IO} =
        let (st, list) = emitted(surfaceWith(Nil) :: Nil);
        Assert.assertEq(expected = (false, 0), (usesStencil(st), cell(list, 0, 10)))

    /// mask つきの面の値も mask つきスプライトの値の続き（スプライト 1・2・面 3・スプライト 4）で、面の後に 1 へ戻さない。
    @Test
    def testMaskedSurfaceContinuesRef(): Unit \ {Assert, IO} =
        let list = listOf(masked() :: masked() :: surfaceWith(triangle()) :: masked() :: Nil);
        Assert.assertEq(expected = (3, 4), (cell(list, 2, 10), cell(list, 3, 11)))

    /// 三角形にならない mask の面は値を進めない（スプライト 1・面 0・スプライト 2）。
    @Test
    def testDegenerateSurfaceMaskKeepsRef(): Unit \ {Assert, IO} =
        let list = listOf(masked() :: surfaceWith(degenerate()) :: masked() :: Nil);
        Assert.assertEq(expected = (0, 2), (cell(list, 1, 10), cell(list, 2, 11)))

    /// backend が stencil を 0 に戻すかを読む値（stencilRefOf）は、mask つきスプライトの行は 11 番・面の行は 10 番・mask の無いスプライトの行は 0。
    @Test
    def testStencilRefOfReadsSurfaceRow(): Unit \ {Assert, IO} =
        let rows = rowsOf(listOf(masked() :: surfaceWith(triangle()) :: plain() :: Nil));
        Assert.assertEq(expected = (1, 2, 0), (stencilRefOf(rows, 0), stencilRefOf(rows, 1), stencilRefOf(rows, 2)))

    /// 255 体の mask つきの後の mask つきの面は値 1 に戻る（backend はその行の前で stencil を 0 に戻す）。
    @Test
    def testSurfaceAfterMaxIsOne(): Unit \ {Assert, IO} =
        let rows = rowsOf(listOf(List.append(List.repeat(maxMaskRef(), masked()), surfaceWith(triangle()) :: Nil)));
        Assert.assertEq(expected = 1, stencilRefOf(rows, maxMaskRef()))

    /// 行の数（上の testRefWrapsAfterMax の前提）。
    @Test
    def testEveryMaskIsARow(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 4, rowCountOf(listOf(List.repeat(4, masked()))))
}
