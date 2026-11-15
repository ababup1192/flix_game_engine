// タイルの層の buffer の表（TileTable）と static layer のキャッシュ（RenderStatic）が、いつ backend に buffer を作らせ・入れ直させ・捨てさせるかを固定する。
// GPU を呼ばない allocator（呼ばれた順に "create 6"・"write 101 4"・"destroy 101" を控え、番号は 101 から）で育て、控えを読む。

mod TestShapeBuffers {
    use RenderPaint.Internal.TileTable
    use RenderPaint.Internal.TileTable.{TileAllocator}

    // ── 組み立て ──

    def nextOf(next: Ref[Int32, Static]): Int32 \ IO =
        Ref.put(Ref.get(next) + 1, next);
        Ref.get(next)

    /// 呼ばれた順を控える TileAllocator（"create 枚数"・"write 番号 枚数"・"destroy 番号"）。
    def recordingTiles(log: Ref[List[String], Static]): TileAllocator \ IO =
        let next = Ref.fresh(Static, 100);
        { create = (_, count) -> { Ref.put("create ${Int32.toString(count)}" :: Ref.get(log), log); nextOf(next) },
          write = (id, _, count) -> Ref.put("write ${Int32.toString(id)} ${Int32.toString(count)}" :: Ref.get(log), log),
          destroy = id -> Ref.put("destroy ${Int32.toString(id)}" :: Ref.get(log), log) }

    /// 呼ばれた順を控える StaticAllocator（"create 頂点の数"・"destroy 番号"）。
    def recordingStatic(log: Ref[List[String], Static]): RenderStatic.StaticAllocator \ IO =
        let next = Ref.fresh(Static, 100);
        { create = (_, count) -> { Ref.put("create ${Int32.toString(count)}" :: Ref.get(log), log); nextOf(next) },
          destroy = id -> Ref.put("destroy ${Int32.toString(id)}" :: Ref.get(log), log) }

    def tileAt(x: Float64): RenderType.TileInstance =
        { px = { x = x, y = 2.0 }, uvOff = { x = 0.25, y = 0.5 }, uvSc = { x = 0.125, y = 0.0625 }, alpha = 0.75, tint = { r = 1.0, g = 0.5, b = 0.25 } }

    def tilesOf(n: Int32): List[RenderType.TileInstance] = List.range(0, n) |> List.map(i -> tileAt(Int32.toFloat64(i)))

    /// 四角（三角形 2 枚 = 6 頂点）1 つの static layer の依頼。
    def layer(key: String): DrawCmd.StaticLayerCmd =
        { key = key,
          polys = () -> ({ vertices = { x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 4.0, y = 4.0 } :: { x = 0.0, y = 4.0 } :: Nil,
                           color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0, zIndex = 0, clip = None, blend = DrawCmd.BlendMode.Normal,
                           grad = None, triangles = None }: DrawCmd.PolygonRenderCmd) :: Nil,
          viewOffset = { x = 0.0, y = 0.0 }, viewScale = { x = 1.0, y = 1.0 }, halfDesign = { x = 0.0, y = 0.0 } }

    /// 依頼の鍵 keys を順に解いた時の控え（古い順）。
    def staticCallsOf(keys: List[String]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingStatic(log);
        let cell = Array#{(None: Option[RenderStatic.Entry])} @ Static;
        List.forEach(key -> discard RenderStatic.resolve(alloc, cell, layer(key)), keys);
        List.reverse(Ref.get(log))

    // ── タイルの層 ──

    /// init は buffer を作り、(番号, 枚数) を返す。
    @Test
    def testInitCreatesAndReturnsCount(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let (handle, count) = TileTable.init(recordingTiles(log), TileTable.fresh(), tilesOf(3));
        Assert.assertEq(expected = (101, 3, "create 3" :: Nil), (GpuHandle.tileVaoInt(handle), count, Ref.get(log)))

    /// 作った時の枚数（5）に入る update は、同じ番号へ入れ直す（作らない）。
    @Test
    def testUpdateThatFitsWrites(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingTiles(log);
        let table = TileTable.fresh();
        let (handle, _) = TileTable.init(alloc, table, tilesOf(5));
        let (again, count) = TileTable.update(alloc, table, handle, tilesOf(3));
        Assert.assertEq(expected = (101, 3, "create 5" :: "write 101 3" :: Nil), (GpuHandle.tileVaoInt(again), count, List.reverse(Ref.get(log))))

    /// 作った時の枚数（3）より多い update は、古い buffer を捨ててから作り直し、新しい番号を返す。
    @Test
    def testUpdateThatGrowsRecreates(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingTiles(log);
        let table = TileTable.fresh();
        let (handle, _) = TileTable.init(alloc, table, tilesOf(3));
        let (again, _) = TileTable.update(alloc, table, handle, tilesOf(5));
        Assert.assertEq(expected = (102, "create 3" :: "destroy 101" :: "create 5" :: Nil), (GpuHandle.tileVaoInt(again), List.reverse(Ref.get(log))))

    /// 作り直した後の update は、新しい枚数（5）までなら新しい番号へ入れ直す。
    @Test
    def testRecreatedBufferKeepsNewCapacity(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingTiles(log);
        let table = TileTable.fresh();
        let (handle, _) = TileTable.init(alloc, table, tilesOf(3));
        let (grown, _) = TileTable.update(alloc, table, handle, tilesOf(5));
        discard TileTable.update(alloc, table, grown, tilesOf(5));
        Assert.assertEq(expected = Some("write 102 5"), List.head(Ref.get(log)))

    /// 知らない番号の update は新しく作り、新しい番号を返す。
    @Test
    def testUpdateOfUnknownCreates(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let (handle, _) = TileTable.update(recordingTiles(log), TileTable.fresh(), GpuHandle.wrapTileVao(7), tilesOf(2));
        Assert.assertEq(expected = (101, "create 2" :: Nil), (GpuHandle.tileVaoInt(handle), Ref.get(log)))

    /// タイル 1 枚の float は px・uvOff・uvSc・alpha・tint の 10 個（2 枚目は 10 個目から）。
    @Test
    def testInstanceFloatsLayout(): Unit \ {Assert, IO} =
        let floats = TileTable.instanceFloats(tilesOf(2));
        Assert.assertEq(expected = 1.0f32 :: 2.0f32 :: 0.25f32 :: 0.5f32 :: 0.125f32 :: 0.0625f32 :: 0.75f32 :: 1.0f32 :: 0.5f32 :: 0.25f32 :: Nil,
                        List.range(10, 20) |> List.map(i -> Array.get(i, floats)))

    // ── static layer ──

    /// 同じ鍵の 2 回目は作らない（四角 1 つ = 6 頂点）。
    @Test
    def testSameKeyBakesOnce(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: Nil, staticCallsOf("a" :: "a" :: Nil))

    /// 鍵が替われば古い buffer（101）を捨ててから作り直す。
    @Test
    def testKeyChangeDestroysThenCreates(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: "destroy 101" :: "create 6" :: Nil, staticCallsOf("a" :: "b" :: Nil))

    /// 範囲は作った buffer の番号を持つ。
    @Test
    def testRangesCarryBufferNumber(): Unit \ {Assert, IO} =
        let cell = Array#{(None: Option[RenderStatic.Entry])} @ Static;
        let ranges = RenderStatic.resolve(recordingStatic(Ref.fresh(Static, Nil)), cell, layer("a"));
        Assert.assertEq(expected = (101, 0, 6) :: Nil, ranges |> List.map(r -> (r#buffer, r#first, r#count)))

    /// release は作った buffer を捨て、次の resolve は作り直す。
    @Test
    def testReleaseDestroysAndForgets(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingStatic(log);
        let cell = Array#{(None: Option[RenderStatic.Entry])} @ Static;
        discard RenderStatic.resolve(alloc, cell, layer("a"));
        RenderStatic.release(alloc, cell);
        discard RenderStatic.resolve(alloc, cell, layer("a"));
        Assert.assertEq(expected = "create 6" :: "destroy 101" :: "create 6" :: Nil, List.reverse(Ref.get(log)))
}
