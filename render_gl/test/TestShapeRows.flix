// 多角形の run・タイルの層・static layer の範囲が RenderList の行になる所（GL を呼ばない前半）を固定する。
// 並べた物（Merged）を emitRowItem へ順に渡して run を閉じ、行の欄と values を読む（倍率 1・Pass の絵は無し）。
// WhyNot: mod TestShapeRows にしない — 行を作る関数は RenderFrame の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderFrame.TestShapeRows {
    import java.nio.FloatBuffer
    use RenderFrame.{Merged, blendCode, closeRuns, emitRowItem, stateSize}
    use RenderFrame.Internal.RenderList.{RenderList, clearRenderList, instanceFloats, kindPoly, kindSprite, kindStatic, kindTile, newRenderList,
                                         nextVertexOf, rowAt, rowCountOf, rowsOf, valueCountOf, valuesOf, vertexFloats, viewValueFloats}

    // ── 組み立て ──

    def v(x: Float64, y: Float64): Vec2.Vec2 = { x = x, y = y }

    def polyWith(blend: DrawCmd.BlendMode, clip: Option[Rect2.Rect2]): DrawCmd.PolygonRenderCmd =
        { vertices = v(0.0, 0.0) :: v(10.0, 0.0) :: v(10.0, 10.0) :: v(0.0, 10.0) :: Nil, color = { r = 1.0, g = 0.5, b = 0.25 }, alpha = 1.0,
          zIndex = 0, clip = clip, blend = blend, grad = None, triangles = None }

    /// 四角（三角形 2 枚 = 6 頂点）の多角形。
    def poly(): Merged = Merged.MPoly(polyWith(DrawCmd.BlendMode.Normal, None))

    def box(): Merged =
        Merged.MSprite(DrawCmd.make({
          texture = "", position = v(0.0, 0.0), scale = v(4.0, 4.0), rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = v(0.0, 0.0), uvScale = v(1.0, 1.0), zIndex = 0, style = None, clip = None,
          blend = DrawCmd.BlendMode.Normal, mask = Nil }))

    /// 絵 "tiles"（番号 9）・buffer 33・12 枚の層。
    def tile(): Merged =
        Merged.MTile({ textureName = "tiles", tileSize = 8.0, position = v(3.0, 4.0), tileScale = v(2.0, 2.0), color = { r = 0.5, g = 0.25, b = 1.0 },
                       zIndex = 0, tileVaoId = GpuHandle.wrapTileVao(33), tileCount = 12 })

    /// buffer 44 の頂点 [6, 6 + 9)・Add の範囲。
    def staticRange(): Merged =
        Merged.MStatic({ buffer = 44, first = 6, count = 9, blend = DrawCmd.BlendMode.Add, clip = None, zIndex = 0,
                         viewOffset = v(20.0, 10.0), viewScale = v(1.5, 1.5), halfDesign = v(160.0, 90.0) })

    def registry(): RenderAsset.TextureRegistry =
        Map#{"tiles" => { id = GpuHandle.wrapTextureId(9), width = 16.0, height = 16.0 }}

    /// 並べた物を順に積んで run を閉じた RenderList（"missing" は知らせ済み）。
    def listOf(items: List[Merged]): RenderList \ IO =
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        let list = newRenderList(FloatBuffer.allocate(instanceFloats() * 8), FloatBuffer.allocate(vertexFloats() * 64));
        let warnLog = Ref.fresh(Static, Set#{"missing"});
        List.forEach(item -> discard emitRowItem(st, list, 1.0, 1.0, registry(), Set.empty(), warnLog, item), items);
        closeRuns(st, list);
        list

    def cell(list: RenderList, row: Int32, col: Int32): Int32 \ IO = rowAt(rowsOf(list), row, col)

    def kindsOf(list: RenderList): List[Int32] \ IO = List.range(0, rowCountOf(list)) |> List.map(row -> cell(list, row, 0))

    /// values の [at, at + n)。
    def valuesAt(list: RenderList, at: Int32, n: Int32): List[Float32] \ IO = List.range(at, at + n) |> List.map(i -> Array.get(i, valuesOf(list)))

    // ── 多角形 ──

    /// 同じ鍵の多角形 2 個は 1 行で、頂点は 12（四角 2 つ）。
    @Test
    def testSameKeyPolygonsAreOneRow(): Unit \ {Assert, IO} =
        let list = listOf(poly() :: poly() :: Nil);
        Assert.assertEq(expected = (1, kindPoly(), 12), (rowCountOf(list), cell(list, 0, 0), cell(list, 0, 2)))

    /// 多角形・箱・多角形は、列の順のまま 3 行（多角形・スプライト・多角形）。
    @Test
    def testPolygonAndSpriteKeepOrder(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = kindPoly() :: kindSprite() :: kindPoly() :: Nil, kindsOf(listOf(poly() :: box() :: poly() :: Nil)))

    /// 2 本目の多角形の run の頭の頂点は、1 本目の後ろ（6）。
    @Test
    def testSecondPolygonRunStartsAfterFirst(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 6, cell(listOf(poly() :: box() :: poly() :: Nil), 2, 1))

    /// blend が替わると次の行になり、その行の blend は Multiply。
    @Test
    def testPolygonBlendChangeStartsRow(): Unit \ {Assert, IO} =
        let list = listOf(poly() :: Merged.MPoly(polyWith(DrawCmd.BlendMode.Multiply, None)) :: Nil);
        Assert.assertEq(expected = (2, blendCode(DrawCmd.BlendMode.Multiply)), (rowCountOf(list), cell(list, 1, 4)))

    /// 多角形の行の view は values の頭（動かない view・0）を指す。
    @Test
    def testPolygonRowPointsAtIdentityView(): Unit \ {Assert, IO} =
        let list = listOf(poly() :: Nil);
        Assert.assertEq(expected = (0, 0.0f32 :: 0.0f32 :: 1.0f32 :: 1.0f32 :: 0.0f32 :: 0.0f32 :: Nil),
                        (cell(list, 0, 11), valuesAt(list, 0, viewValueFloats())))

    /// 頂点の書く位置は、閉じた run の頂点の数の合計。
    @Test
    def testNextVertexAfterRuns(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 12, nextVertexOf(listOf(poly() :: box() :: poly() :: Nil)))

    // ── タイルの層 ──

    /// タイルの層の行は 種類・枚数・絵の番号・buffer の番号を持つ。
    @Test
    def testTileRowColumns(): Unit \ {Assert, IO} =
        let list = listOf(tile() :: Nil);
        Assert.assertEq(expected = (kindTile(), 12, 9, 33), (cell(list, 0, 0), cell(list, 0, 2), cell(list, 0, 3), cell(list, 0, 10)))

    /// タイルの層の values は position・tileSize・tileScale・color の 8 個。
    @Test
    def testTileRowValues(): Unit \ {Assert, IO} =
        let list = listOf(tile() :: Nil);
        Assert.assertEq(expected = 3.0f32 :: 4.0f32 :: 8.0f32 :: 2.0f32 :: 2.0f32 :: 0.5f32 :: 0.25f32 :: 1.0f32 :: Nil,
                        valuesAt(list, cell(list, 0, 11), 8))

    /// 多角形の run はタイルの層の前で閉じる（多角形・タイル・多角形の 3 行）。
    @Test
    def testTileClosesPolygonRun(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = kindPoly() :: kindTile() :: kindPoly() :: Nil, kindsOf(listOf(poly() :: tile() :: poly() :: Nil)))

    /// 表に無い絵のタイルの層は行を作らない。
    @Test
    def testUnregisteredTileMakesNoRow(): Unit \ {Assert, IO} =
        let missing = Merged.MTile({ textureName = "missing", tileSize = 8.0, position = v(0.0, 0.0), tileScale = v(1.0, 1.0),
                                     color = { r = 1.0, g = 1.0, b = 1.0 }, zIndex = 0, tileVaoId = GpuHandle.wrapTileVao(1), tileCount = 1 });
        Assert.assertEq(expected = 0, rowCountOf(listOf(missing :: Nil)))

    // ── static layer ──

    /// static の行は 種類・頭の頂点・頂点の数・blend・buffer の番号を持つ。
    @Test
    def testStaticRowColumns(): Unit \ {Assert, IO} =
        let list = listOf(staticRange() :: Nil);
        Assert.assertEq(expected = (kindStatic(), 6, 9, blendCode(DrawCmd.BlendMode.Add), 44),
                        (cell(list, 0, 0), cell(list, 0, 1), cell(list, 0, 2), cell(list, 0, 4), cell(list, 0, 10)))

    /// static の行の view は values の頭の後ろに置き、viewOffset・viewScale・halfDesign の 6 個。
    @Test
    def testStaticRowView(): Unit \ {Assert, IO} =
        let list = listOf(staticRange() :: Nil);
        let at = cell(list, 0, 11);
        Assert.assertEq(expected = (viewValueFloats(), 20.0f32 :: 10.0f32 :: 1.5f32 :: 1.5f32 :: 160.0f32 :: 90.0f32 :: Nil),
                        (at, valuesAt(list, at, viewValueFloats())))

    // ── values ──

    /// values は初めに取った 64 個を超えても足せる（タイルの層 10 枚 = 6 + 80 個）。
    @Test
    def testValuesGrowPastFirstRoom(): Unit \ {Assert, IO} =
        let list = listOf(List.repeat(10, tile()));
        Assert.assertEq(expected = (10, viewValueFloats() + 80, 3.0f32), (rowCountOf(list), valueCountOf(list), Array.get(cell(list, 9, 11), valuesOf(list))))

    /// 空にした列の values は頭の動かない view だけ・頂点の書く位置は頭。
    @Test
    def testClearKeepsOnlyIdentityView(): Unit \ {Assert, IO} =
        let list = listOf(poly() :: staticRange() :: Nil);
        clearRenderList(list);
        Assert.assertEq(expected = (viewValueFloats(), 0), (valueCountOf(list), nextVertexOf(list)))

    /// 面と 3D の場面は行にならない（emitRowItem が false を返し、行を足さない）。
    @Test
    def testSceneIsNotARow(): Unit \ {Assert, IO} =
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        let list = newRenderList(FloatBuffer.allocate(instanceFloats()), FloatBuffer.allocate(vertexFloats()));
        let made = emitRowItem(st, list, 1.0, 1.0, registry(), Set.empty(), Ref.fresh(Static, Set.empty()), Merged.MScene3d(0));
        Assert.assertEq(expected = (false, 0), (made, rowCountOf(list)))
}
