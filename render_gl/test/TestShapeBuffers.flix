// タイルの層の buffer の表（TileTable）と static layer のキャッシュ（RenderStatic）が、いつ backend に buffer を作らせ・入れ直させ・捨てさせるかを固定する。
// GPU を呼ばない allocator（呼ばれた順に "create 6"・"write 101 4"・"grow 101 5"・"destroy 101" を控え、番号は 101 から）で育て、控えを読む。

mod TestShapeBuffers {
    use RenderPaint.Internal.TileTable
    use RenderPaint.Internal.TileTable.{TileAllocator}

    // ── 組み立て ──

    def nextOf(next: Ref[Int32, Static]): Int32 \ IO =
        Ref.put(Ref.get(next) + 1, next);
        Ref.get(next)

    /// 呼ばれた順を控える TileAllocator（"create 枚数"・"write 番号 枚数"・"grow 番号 枚数"）。
    def recordingTiles(log: Ref[List[String], Static]): TileAllocator \ IO =
        let next = Ref.fresh(Static, 100);
        { create = (_, count) -> { Ref.put("create ${Int32.toString(count)}" :: Ref.get(log), log); nextOf(next) },
          write = (id, _, count) -> Ref.put("write ${Int32.toString(id)} ${Int32.toString(count)}" :: Ref.get(log), log),
          grow = (id, _, count) -> Ref.put("grow ${Int32.toString(id)} ${Int32.toString(count)}" :: Ref.get(log), log) }

    /// 呼ばれた順を控える StaticAllocator（"create 頂点の数"・"destroy 番号"）。
    def recordingStatic(log: Ref[List[String], Static]): RenderStatic.StaticAllocator \ IO =
        let next = Ref.fresh(Static, 100);
        { create = (_, count) -> { Ref.put("create ${Int32.toString(count)}" :: Ref.get(log), log); nextOf(next) },
          destroy = id -> Ref.put("destroy ${Int32.toString(id)}" :: Ref.get(log), log) }

    def tileAt(x: Float64): RenderType.TileInstance =
        { px = { x = x, y = 2.0 }, uvOff = { x = 0.25, y = 0.5 }, uvSc = { x = 0.125, y = 0.0625 }, alpha = 0.75, tint = { r = 1.0, g = 0.5, b = 0.25 } }

    def tilesOf(n: Int32): List[RenderType.TileInstance] = List.range(0, n) |> List.map(i -> tileAt(Int32.toFloat64(i)))

    /// 左上 x・z の四角（三角形 2 枚 = 6 頂点）。
    def squareAt(x: Float64, z: Int32): DrawCmd.PolygonRenderCmd =
        { vertices = { x = x, y = 0.0 } :: { x = x + 4.0, y = 0.0 } :: { x = x + 4.0, y = 4.0 } :: { x = x, y = 4.0 } :: Nil,
          color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0, zIndex = z, clip = None, blend = DrawCmd.BlendMode.Normal,
          grad = None, triangles = None }

    /// id・key の static layer の依頼（中身は polys）。
    def layerOf(id: String, key: String, polys: List[DrawCmd.PolygonRenderCmd]): DrawCmd.StaticLayerCmd =
        { id = id, key = key, polys = () -> polys,
          viewOffset = { x = 0.0, y = 0.0 }, viewScale = { x = 1.0, y = 1.0 }, halfDesign = { x = 0.0, y = 0.0 } }

    /// 四角 1 つの、id "" の static layer の依頼。
    def layer(key: String): DrawCmd.StaticLayerCmd = layerOf("", key, squareAt(0.0, 0) :: Nil)

    /// 四角 1 つの、id の static layer の依頼。
    def chunk(id: String, key: String): DrawCmd.StaticLayerCmd = layerOf(id, key, squareAt(0.0, 0) :: Nil)

    /// 依頼の並びを 1 コマずつ順に解いた時の控え（古い順）。
    def framesCallsOf(frames: List[List[DrawCmd.StaticLayerCmd]]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingStatic(log);
        let cache = RenderStatic.freshCache();
        List.forEach(layers -> discard RenderStatic.resolve(alloc, cache, layers), frames);
        List.reverse(Ref.get(log))

    /// 依頼の鍵 keys を 1 コマに 1 つずつ順に解いた時の控え（古い順）。
    def staticCallsOf(keys: List[String]): List[String] \ IO =
        framesCallsOf(keys |> List.map(key -> layer(key) :: Nil))

    /// 範囲を z の安定な並べ替え（RenderFrame.mergedByZ と同じ: 同じ z は並びの順）に掛け、(z・頂点の数) を、
    /// 同じ z の続きを 1 つに足して並べる（buffer の切れ目を見ない描く順）。
    def drawOrderOf(ranges: List[RenderStatic.Range]): List[(Int32, Int32)] =
        Sort.sortStableBy(r -> r#zIndex, ranges) |> List.foldLeft((acc, r) -> match acc {
            case (z, n) :: rest if z == r#zIndex => (z, n + r#count) :: rest
            case _ => (r#zIndex, r#count) :: acc
        }, Nil) |> List.reverse

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

    /// 作った時の枚数（3）より多い update は、同じ番号（101）のまま大きくする。
    @Test
    def testUpdateThatGrowsKeepsNumber(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingTiles(log);
        let table = TileTable.fresh();
        let (handle, _) = TileTable.init(alloc, table, tilesOf(3));
        let (again, _) = TileTable.update(alloc, table, handle, tilesOf(5));
        Assert.assertEq(expected = (101, "create 3" :: "grow 101 5" :: Nil), (GpuHandle.tileVaoInt(again), List.reverse(Ref.get(log))))

    /// 大きくした後の update は、新しい枚数（5）までなら入れ直す。
    @Test
    def testGrownBufferKeepsNewCapacity(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingTiles(log);
        let table = TileTable.fresh();
        let (handle, _) = TileTable.init(alloc, table, tilesOf(3));
        discard TileTable.update(alloc, table, handle, tilesOf(5));
        discard TileTable.update(alloc, table, handle, tilesOf(5));
        Assert.assertEq(expected = Some("write 101 5"), List.head(Ref.get(log)))

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
        let ranges = RenderStatic.resolve(recordingStatic(Ref.fresh(Static, Nil)), RenderStatic.freshCache(), layer("a") :: Nil);
        Assert.assertEq(expected = (101, 0, 6) :: Nil, ranges |> List.map(r -> (r#buffer, r#first, r#count)))

    /// release は作った buffer を捨て、次の resolve は作り直す。
    @Test
    def testReleaseDestroysAndForgets(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let alloc = recordingStatic(log);
        let cache = RenderStatic.freshCache();
        discard RenderStatic.resolve(alloc, cache, layer("a") :: Nil);
        RenderStatic.release(alloc, cache);
        discard RenderStatic.resolve(alloc, cache, layer("a") :: Nil);
        Assert.assertEq(expected = "create 6" :: "destroy 101" :: "create 6" :: Nil, List.reverse(Ref.get(log)))

    /// 区画 2 つのうち b の鍵だけ替えると、b の buffer（102）だけを捨てて作り直す。
    @Test
    def testKeyChangeRebuildsOnlyThatChunk(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: "create 6" :: "destroy 102" :: "create 6" :: Nil,
                        framesCallsOf((chunk("a", "1") :: chunk("b", "1") :: Nil) ::
                                      (chunk("a", "1") :: chunk("b", "2") :: Nil) :: Nil))

    /// 鍵が替わらなければ、並びの順が入れ替わっても作り直さない。
    @Test
    def testReorderedChunksAreReused(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: "create 6" :: Nil,
                        framesCallsOf((chunk("a", "1") :: chunk("b", "1") :: Nil) ::
                                      (chunk("b", "1") :: chunk("a", "1") :: Nil) :: Nil))

    /// 前のコマにあって今のコマに無い id（a = 101）の buffer は捨てる。
    @Test
    def testMissingIdIsDestroyed(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: "create 6" :: "destroy 101" :: Nil,
                        framesCallsOf((chunk("a", "1") :: chunk("b", "1") :: Nil) ::
                                      (chunk("b", "1") :: Nil) :: Nil))

    /// 空の並び（Pass の中のコマ）は何も捨てず、次のコマも使い回す。
    @Test
    def testEmptyFrameKeepsCache(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: Nil,
                        framesCallsOf((chunk("a", "1") :: Nil) :: Nil :: (chunk("a", "1") :: Nil) :: Nil))

    /// 同じ id が 2 度並んでも、鍵が替わらない間は毎コマ作り直さない。
    @Test
    def testDuplicateIdIsNotRebuiltEveryFrame(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create 6" :: "create 6" :: Nil,
                        framesCallsOf((chunk("a", "1") :: chunk("a", "2") :: Nil) ::
                                      (chunk("a", "1") :: chunk("a", "2") :: Nil) :: Nil))

    /// 中身を区画 2 つに分けても、描く順（z ごとの頂点の数）は 1 層に全部を入れた時と同じ。
    @Test
    def testChunksDrawInSameOrderAsOneLayer(): Unit \ {Assert, IO} =
        let a = squareAt(0.0, 2) :: squareAt(8.0, 1) :: Nil;
        let b = squareAt(16.0, 1) :: squareAt(24.0, 3) :: Nil;
        let alloc = recordingStatic(Ref.fresh(Static, Nil));
        let one = RenderStatic.resolve(alloc, RenderStatic.freshCache(), layerOf("", "k", List.append(a, b)) :: Nil);
        let two = RenderStatic.resolve(alloc, RenderStatic.freshCache(), layerOf("a", "k", a) :: layerOf("b", "k", b) :: Nil);
        Assert.assertEq(expected = drawOrderOf(one), drawOrderOf(two))
}
