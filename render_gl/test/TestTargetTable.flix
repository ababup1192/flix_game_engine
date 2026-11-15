// レンダーターゲットの表（TargetTable）が、いつ backend にターゲットを作らせ・捨てさせるかと、テクスチャの registry への載せ方を固定する。
// GPU を呼ばない TargetAllocator（呼ばれた順に "create fx 64x64 s1"・"destroy 101" を控え、番号は 101 から）で表を育て、控えと表を読む。

mod TestTargetTable {
    use RenderPaint.Internal.TargetTable
    use RenderFrame.Internal.RenderList.PassHistory
    use RenderPaint.Internal.TargetTable.{TargetAllocator}
    use RenderPaint.Internal.TextureTable

    // ── 組み立て ──

    /// 呼ばれた順を控える TargetAllocator。作るターゲットの番号は 101 から順に。
    def recordingAllocator(log: Ref[List[String], Static]): TargetAllocator \ IO =
        let next = Ref.fresh(Static, 100);
        { create = spec -> {
              Ref.put(Ref.get(next) + 1, next);
              let size = "${Int32.toString(spec#width)}x${Int32.toString(spec#height)}";
              Ref.put("create ${spec#name} ${size} s${Int32.toString(spec#samples)}" :: Ref.get(log), log);
              Ref.get(next)
          },
          destroy = id -> Ref.put("destroy ${Int32.toString(id)}" :: Ref.get(log), log) }

    def freshTextures(): TextureTable.Tables \ IO =
        { registryRef = Ref.fresh(Static, Map.empty()), textureKeyRef = Ref.fresh(Static, Map.empty()) }

    def specNamed(name: String, side: Int32, samples: Int32): RenderTarget.TargetSpec =
        { name = name, width = side, height = side, format = RenderTarget.Format.Rgba8Unorm, clear = RenderTarget.LoadOp.Keep, samples = samples }

    def spec(side: Int32, samples: Int32): RenderTarget.TargetSpec = specNamed("fx", side, samples)

    def design(): (Float64, Float64) = (320.0, 240.0)

    /// ターゲット "fx" を辺の長さ sides の順に開いて閉じ、呼ばれた順の控え（古い順）を返す。
    def callsOf(sides: List[Int32]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        List.forEach(side -> { discard TargetTable.begin(allocator, textures, table, design(), spec(side, 1)); discard TargetTable.end(table) }, sides);
        List.reverse(Ref.get(log))

    // ── begin ──

    /// 同じ形の 2 回目は作らない。
    @Test
    def testSameShapeCreatesOnce(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create fx 64x64 s1" :: Nil, callsOf(64 :: 64 :: Nil))

    /// 大きさが変われば古い方（番号 101）を捨ててから作り直す。
    @Test
    def testSizeChangeDestroysThenCreates(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "create fx 64x64 s1" :: "destroy 101" :: "create fx 32x32 s1" :: Nil, callsOf(64 :: 32 :: Nil))

    /// 標本の数が変わっても作り直す。
    @Test
    def testSamplesChangeRecreates(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(allocator, textures, table, design(), spec(64, 1));
        discard TargetTable.begin(allocator, textures, table, design(), spec(64, 4));
        Assert.assertEq(expected = "create fx 64x64 s1" :: "destroy 101" :: "create fx 64x64 s4" :: Nil, List.reverse(Ref.get(log)))

    /// 開いたターゲットは、backend の番号と design の大きさで registry に載る。
    @Test
    def testBeginPutsTextureAtDesignSize(): Unit \ {Assert, IO} =
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(recordingAllocator(Ref.fresh(Static, Nil)), textures, table, design(), spec(64, 1));
        let put = Map.get("fx", Ref.get(textures#registryRef)) |> Option.map(info -> (GpuHandle.textureIdInt(info#id), info#width, info#height));
        Assert.assertEq(expected = Some((101, 320.0, 240.0)), put)

    /// 開いたまま別のターゲットを開くと、開いている方は後の物に置き換わり、end の 1 回で画面に戻る。
    @Test
    def testNestedBeginReplacesActiveAndOneEndReturnsToScreen(): Unit \ {Assert, IO} =
        let allocator = recordingAllocator(Ref.fresh(Static, Nil));
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(allocator, textures, table, design(), specNamed("a", 64, 1));
        discard TargetTable.begin(allocator, textures, table, design(), specNamed("b", 64, 1));
        let closed = TargetTable.end(table) |> Option.map(r -> r#texture);
        Assert.assertEq(expected = (Some(102), None), (closed, TargetTable.activeSpec(table) |> Option.map(s -> s#name)))

    // ── end ──

    /// end は開いていたターゲットを返し、その後は画面（None）に戻る。
    @Test
    def testEndReturnsClosedRowAndClearsActive(): Unit \ {Assert, IO} =
        let table = TargetTable.fresh();
        discard TargetTable.begin(recordingAllocator(Ref.fresh(Static, Nil)), freshTextures(), table, design(), spec(64, 1));
        let closed = TargetTable.end(table) |> Option.map(r -> r#texture);
        Assert.assertEq(expected = (Some(101), None), (closed, TargetTable.activeSpec(table) |> Option.map(s -> s#name)))

    /// 開いていない時の end は None で、何も捨てない。
    @Test
    def testEndWithoutBeginIsNoneAndDestroysNothing(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let table = TargetTable.fresh();
        discard TargetTable.begin(allocator, freshTextures(), table, design(), spec(64, 1));
        discard TargetTable.end(table);
        Ref.put(Nil, log);
        let closed = TargetTable.end(table) |> Option.map(r -> r#texture);
        Assert.assertEq(expected = (None, Nil), (closed, Ref.get(log)))

    // ── history ──

    /// history は標本 1 で 1 回だけ作り、ターゲットの標本の数が違っても形（大きさ・形式）が同じなら使い回す。
    @Test
    def testHistoryIsSingleSampleAndKept(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(allocator, textures, table, design(), spec(64, 4));
        discard TargetTable.ensureHistory(allocator, textures, table, design(), spec(64, 4));
        discard TargetTable.ensureHistory(allocator, textures, table, design(), spec(64, 4));
        Assert.assertEq(expected = ("create fx 64x64 s4" :: "create fx 64x64 s1" :: Nil, true),
                        (List.reverse(Ref.get(log)), TargetTable.isTarget(table, RenderTarget.historyName("fx"))))

    /// history だけ形が変わった時は、古い history（番号 101）を捨てて新しい形で作り直す。
    @Test
    def testHistoryShapeChangeRecreatesHistory(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.ensureHistory(allocator, textures, table, design(), spec(64, 1));
        discard TargetTable.ensureHistory(allocator, textures, table, design(), spec(32, 1));
        Assert.assertEq(expected = "create fx 64x64 s1" :: "destroy 101" :: "create fx 32x32 s1" :: Nil, List.reverse(Ref.get(log)))

    /// ターゲットを作り直すと、その history も捨てて registry とターゲットの表から外す。
    @Test
    def testRecreateDropsHistory(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(allocator, textures, table, design(), spec(64, 1));
        discard TargetTable.ensureHistory(allocator, textures, table, design(), spec(64, 1));
        Ref.put(Nil, log);
        discard TargetTable.begin(allocator, textures, table, design(), spec(32, 1));
        let history = RenderTarget.historyName("fx");
        Assert.assertEq(expected = ("destroy 101" :: "destroy 102" :: "create fx 32x32 s1" :: Nil, false, false),
                        (List.reverse(Ref.get(log)), TargetTable.isTarget(table, history), Map.memberOf(history, Ref.get(textures#registryRef))))

    // ── 描く前の history の始末（historyFor）──

    /// "fx" を開き、1 コマずつ (reads, keep) で historyFor を呼んだ答えの列と、呼ばれた順の控え（古い順）。
    def historyCalls(frames: List[(Bool, Bool)]): (List[PassHistory], List[String]) \ IO =
        let log = Ref.fresh(Static, Nil);
        let allocator = recordingAllocator(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        let answers = List.map(match (reads, keep) -> {
            discard TargetTable.begin(allocator, textures, table, design(), spec(64, 1));
            let answer = TargetTable.historyFor(allocator, textures, table, design(), spec(64, 1), reads, keep);
            discard TargetTable.end(table);
            answer
        }, frames);
        (answers, List.reverse(Ref.get(log)))

    /// 読まないコマは history を作らない。
    @Test
    def testNoReadMakesNoHistory(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = ("create fx 64x64 s1" :: Nil), snd(historyCalls((false, true) :: Nil)))

    /// 読まないコマの答えは NoHistory。
    @Test
    def testNoReadAnswersNoHistory(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = PassHistory.NoHistory :: Nil, fst(historyCalls((false, true) :: Nil)))

    /// 初めて読むコマで history（番号 102）を作り、窓では今の中身をそこへ写す。
    @Test
    def testFirstReadCreatesAndCopies(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (PassHistory.CopyTo(102) :: Nil, "create fx 64x64 s1" :: "create fx 64x64 s1" :: Nil),
                        historyCalls((true, true) :: Nil))

    /// 読むコマが続いても history は作り直さず、毎コマ同じ番号へ写す。
    @Test
    def testEveryReadCopiesIntoSameHistory(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = PassHistory.CopyTo(102) :: PassHistory.CopyTo(102) :: Nil,
                        fst(historyCalls((true, true) :: (true, true) :: Nil)))

    /// 読まないコマを挟んでも history は捨てず、次に読むコマで同じ番号へ写し直す。
    @Test
    def testSkippedFrameKeepsHistory(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = PassHistory.CopyTo(102) :: PassHistory.NoHistory :: PassHistory.CopyTo(102) :: Nil,
                        fst(historyCalls((true, true) :: (false, true) :: (true, true) :: Nil)))

    /// 前のコマを持たない描き方（1 枚撮り・動画）では、写さずに透明で塗る。
    @Test
    def testNotKeptClearsHistory(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = PassHistory.ClearTransparent(102) :: Nil, fst(historyCalls((true, false) :: Nil)))

    // ── 標本の数（samplesWithin）──

    /// WebGPU（1 と 4）は 8 を 4 に。
    @Test
    def testEightBecomesFourOnWebGpu(): Unit \ Assert =
        Assert.assertEq(expected = 4, TargetTable.samplesWithin(8, 1 :: 4 :: Nil))

    /// WebGPU（1 と 4）は 2 を 1 に（4 へは上げない）。
    @Test
    def testTwoBecomesOneOnWebGpu(): Unit \ Assert =
        Assert.assertEq(expected = 1, TargetTable.samplesWithin(2, 1 :: 4 :: Nil))

    /// 描ける数に頼んだ数があればそのまま。
    @Test
    def testSupportedCountIsKept(): Unit \ Assert =
        Assert.assertEq(expected = 2, TargetTable.samplesWithin(2, 1 :: 2 :: 4 :: 8 :: Nil))

    /// 1 未満を頼まれたら 1。
    @Test
    def testBelowOneBecomesOne(): Unit \ Assert =
        Assert.assertEq(expected = 1, TargetTable.samplesWithin(0, 1 :: 4 :: Nil))
}
