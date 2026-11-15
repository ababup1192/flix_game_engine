// 描き先の表（TargetTable）が、いつ backend に描き先を作らせ・捨てさせるかと、名前で引く絵の表への載せ方を固定する。
// GPU を呼ばない Targets（呼ばれた順に "create fx 64x64 s1"・"destroy 101" を控え、番号は 101 から）で表を育て、控えと表を読む。

mod TestTargetTable {
    use RenderPaint.Internal.TargetTable
    use RenderPaint.Internal.TargetTable.{Targets}
    use RenderPaint.Internal.TextureTable

    // ── 組み立て ──

    /// 呼ばれた順を控える Targets。作る描き先の番号は 101 から順に。
    def recordingTargets(log: Ref[List[String], Static]): Targets \ IO =
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

    def spec(side: Int32, samples: Int32): RenderTarget.TargetSpec =
        { name = "fx", width = side, height = side, format = RenderTarget.Format.Rgba8Unorm, clear = RenderTarget.LoadOp.Keep, samples = samples }

    def design(): (Float64, Float64) = (320.0, 240.0)

    /// 描き先 "fx" を辺の長さ sides の順に開いて閉じ、呼ばれた順の控え（古い順）を返す。
    def callsOf(sides: List[Int32]): List[String] \ IO =
        let log = Ref.fresh(Static, Nil);
        let targets = recordingTargets(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        List.forEach(side -> { discard TargetTable.begin(targets, textures, table, design(), spec(side, 1)); discard TargetTable.end(table) }, sides);
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
        let targets = recordingTargets(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(targets, textures, table, design(), spec(64, 1));
        discard TargetTable.begin(targets, textures, table, design(), spec(64, 4));
        Assert.assertEq(expected = "create fx 64x64 s1" :: "destroy 101" :: "create fx 64x64 s4" :: Nil, List.reverse(Ref.get(log)))

    /// 開いた描き先は、backend の番号と design の大きさで名前の絵の表に載る。
    @Test
    def testBeginPutsTextureAtDesignSize(): Unit \ {Assert, IO} =
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(recordingTargets(Ref.fresh(Static, Nil)), textures, table, design(), spec(64, 1));
        let put = Map.get("fx", Ref.get(textures#registryRef)) |> Option.map(info -> (GpuHandle.textureIdInt(info#id), info#width, info#height));
        Assert.assertEq(expected = Some((101, 320.0, 240.0)), put)

    // ── end ──

    /// end は開いていた描き先を返し、その後は画面（None）に戻る。
    @Test
    def testEndReturnsClosedRowAndClearsActive(): Unit \ {Assert, IO} =
        let table = TargetTable.fresh();
        discard TargetTable.begin(recordingTargets(Ref.fresh(Static, Nil)), freshTextures(), table, design(), spec(64, 1));
        let closed = TargetTable.end(table) |> Option.map(r -> r#texture);
        Assert.assertEq(expected = (Some(101), None), (closed, TargetTable.activeSpec(table) |> Option.map(s -> s#name)))

    // ── history ──

    /// history は標本 1 で 1 回だけ作り、描き先の標本の数が違っても形（大きさ・形式）が同じなら使い回す。
    @Test
    def testHistoryIsSingleSampleAndKept(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let targets = recordingTargets(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(targets, textures, table, design(), spec(64, 4));
        discard TargetTable.ensureHistory(targets, textures, table, design(), spec(64, 4));
        discard TargetTable.ensureHistory(targets, textures, table, design(), spec(64, 4));
        let history = RenderTarget.historyName("fx");
        Assert.assertEq(expected = ("create fx 64x64 s4" :: "create ${history} 64x64 s1" :: Nil, true),
                        (List.reverse(Ref.get(log)), TargetTable.isTarget(table, history)))

    /// 描き先を作り直すと、その history も捨てて名前の絵の表と描き先の表から外す。
    @Test
    def testRecreateDropsHistory(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let targets = recordingTargets(log);
        let textures = freshTextures();
        let table = TargetTable.fresh();
        discard TargetTable.begin(targets, textures, table, design(), spec(64, 1));
        discard TargetTable.ensureHistory(targets, textures, table, design(), spec(64, 1));
        Ref.put(Nil, log);
        discard TargetTable.begin(targets, textures, table, design(), spec(32, 1));
        let history = RenderTarget.historyName("fx");
        Assert.assertEq(expected = ("destroy 101" :: "destroy 102" :: "create fx 32x32 s1" :: Nil, false, false),
                        (List.reverse(Ref.get(log)), TargetTable.isTarget(table, history), Map.memberOf(history, Ref.get(textures#registryRef))))
}
