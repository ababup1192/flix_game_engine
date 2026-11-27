// 形の置き場の表（Render3d.MeshTable）と絵の置き場の表（Render3d.TextureTable3d）が、いつ番号を振り・backend に作らせ・捨てさせるかを固定する。
// GPU を呼ばない関数（呼ばれた順に "create 0"・"destroy 0" を控える）で表を育て、控えと表を読む。

mod Render3d.TestMeshTable {
    use Render3d.MeshTable
    use Render3d.TextureSlot
    use Render3d.TextureTable3d

    // ── 組み立て ──

    /// 辺 side の三角形（頂点 3 つ。辺が違えば鍵が違う）。
    def triangle(side: Float64): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = { x = 0.0, y = 0.0, z = 0.0 } :: { x = side, y = 0.0, z = 0.0 } :: { x = 0.0, y = side, z = 0.0 } :: Nil,
                              color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    /// 呼ばれた順を控える MeshAllocator（頂点の数は形のまま）。
    def recordingAllocator(log: Ref[List[String], Static]): MeshTable.MeshAllocator =
        { create = (h, mesh) -> { Ref.put("create ${h}" :: Ref.get(log), log); Mesh3d.vertexCount(mesh) },
          destroy = h -> Ref.put("destroy ${h}" :: Ref.get(log), log) }

    def destroyRecorder(log: Ref[List[String], Static]): Int32 -> Unit \ IO = h -> Ref.put("destroy ${h}" :: Ref.get(log), log)

    def noDestroy(): Int32 -> Unit \ IO = _ -> checked_ecast(())

    def made(levels: Int32): Int32 -> Option[{ levels = Int32, bytes = Int64 }] \ IO = _ -> checked_ecast(Some({ levels = levels, bytes = 16i64 }))

    // ── 形 ──

    /// 番号を振るだけでは作らず、同じ形は同じ番号。
    @Test
    def testNumberingDoesNotCreate(): Unit \ {Assert, IO} =
        let table = MeshTable.fresh();
        let a = MeshTable.numberOf(table, 1i64, triangle(1.0));
        let b = MeshTable.numberOf(table, 1i64, triangle(2.0));
        let again = MeshTable.numberOf(table, 2i64, triangle(1.0));
        Assert.assertEq(expected = (0, 1, 0, 0), (a, b, again, Map.size(MeshTable.createdOf(table))))

    /// ensure は振った番号のまま 1 回だけ作り、頂点の合計を足す。
    @Test
    def testEnsureCreatesOnceWithTheNumberedHandle(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = MeshTable.fresh();
        let numbered = MeshTable.numberOf(table, 1i64, triangle(1.0));
        let first = MeshTable.ensure(table, recordingAllocator(log), 1i64, triangle(1.0));
        let second = MeshTable.ensure(table, recordingAllocator(log), 2i64, triangle(1.0));
        Assert.assertEq(expected = (numbered, numbered, "create 0" :: Nil, 3), (first, second, List.reverse(Ref.get(log)), MeshTable.vertexTotalOf(table)))

    /// 上限を超えたら古い形を捨て、捨てた番号を次の新しい形に使い回す。
    @Test
    def testTrimDropsOldAndReusesHandle(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = MeshTable.fresh();
        let allocator = recordingAllocator(log);
        discard MeshTable.ensure(table, allocator, 1i64, triangle(1.0));
        discard MeshTable.ensure(table, allocator, 9i64, triangle(2.0));
        let victims = MeshTable.trim(table, allocator, 10i64, 3, Set.empty());
        let reused = MeshTable.numberOf(table, 10i64, triangle(3.0));
        Assert.assertEq(expected = (1, "destroy 0", 0, 3), (List.length(victims), List.head(Ref.get(log)) |> Option.getWithDefault(""), reused, MeshTable.vertexTotalOf(table)))

    /// 上限の内なら何も捨てない。
    @Test
    def testTrimUnderLimitKeepsAll(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = MeshTable.fresh();
        discard MeshTable.ensure(table, recordingAllocator(log), 1i64, triangle(1.0));
        Assert.assertEq(expected = Nil, MeshTable.trim(table, recordingAllocator(log), 100i64, 3, Set.empty()))

    // ── 絵 ──

    /// 同じ stamp の間は作り直さず、stamp が変われば前の物を捨ててから同じ番号で作る。
    @Test
    def testTextureStampChangeRecreates(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = TextureTable3d.fresh();
        let slot = TextureSlot.Copy("wall:box");
        let make = (h: Int32) -> { Ref.put("make ${h}" :: Ref.get(log), log); Some({ levels = 3, bytes = 16i64 }) };
        discard TextureTable3d.ensure(table, destroyRecorder(log), 1i64, slot, "1:a", make);
        discard TextureTable3d.ensure(table, destroyRecorder(log), 2i64, slot, "1:a", make);
        discard TextureTable3d.ensure(table, destroyRecorder(log), 3i64, slot, "1:b", make);
        Assert.assertEq(expected = "make 0" :: "destroy 0" :: "make 0" :: Nil, List.reverse(Ref.get(log)))

    /// 作れなかった絵は控えず、retryFrames の間は作り直しを試さない。
    @Test
    def testTextureFailureWaitsBeforeRetry(): Unit \ {Assert, IO} =
        let tries = Ref.fresh(Static, 0);
        let table = TextureTable3d.fresh();
        let slot = TextureSlot.Scene("k");
        let failing = (_: Int32) -> { Ref.put(Ref.get(tries) + 1, tries); (None: Option[{ levels = Int32, bytes = Int64 }]) };
        discard TextureTable3d.ensure(table, noDestroy(), 1i64, slot, "", failing);
        discard TextureTable3d.ensure(table, noDestroy(), 2i64, slot, "", failing);
        discard TextureTable3d.ensure(table, noDestroy(), 1i64 + TextureTable3d.retryFrames(), slot, "", failing);
        Assert.assertEq(expected = (2, 0), (Ref.get(tries), Map.size(TextureTable3d.createdOf(table))))

    /// 番号を振った後に作った物は、振った時の番号と levels を返す。
    @Test
    def testTextureEnsureUsesNumberedHandle(): Unit \ {Assert, IO} =
        let table = TextureTable3d.fresh();
        let slot = TextureSlot.Scene("k");
        discard TextureTable3d.numberOf(table, 1i64, TextureSlot.Scene("other"));
        let numbered = TextureTable3d.numberOf(table, 1i64, slot);
        let got = TextureTable3d.ensure(table, noDestroy(), 1i64, slot, "", made(4)) |> Option.map(hc -> (fst(hc), snd(hc)#levels));
        Assert.assertEq(expected = Some((numbered, 4)), got)

    /// 枚数の上限を超えたら、前のコマより古い場面の絵を捨てる。
    @Test
    def testTextureSweepDropsOldOverCount(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = TextureTable3d.fresh();
        discard TextureTable3d.ensure(table, destroyRecorder(log), 1i64, TextureSlot.Scene("old"), "", made(1));
        discard TextureTable3d.ensure(table, destroyRecorder(log), 10i64, TextureSlot.Scene("new"), "", made(1));
        let (victims, over) = TextureTable3d.sweep(table, destroyRecorder(log), 10i64, { count = 1, size = 1000i64 }, Set.empty());
        Assert.assertEq(expected = (TextureSlot.Scene("old") :: Nil, false, "destroy 0" :: Nil), (victims, over, Ref.get(log)))

    /// 上限の内で、作っていない古い番号も無ければ、何も捨てず番号も残す。
    @Test
    def testTextureSweepUnderBudgetKeepsAll(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = TextureTable3d.fresh();
        discard TextureTable3d.ensure(table, destroyRecorder(log), 1i64, TextureSlot.Scene("old"), "", made(1));
        let result = TextureTable3d.sweep(table, destroyRecorder(log), 10i64, { count = 4, size = 1000i64 }, Set.empty());
        Assert.assertEq(expected = ((Nil, false), Nil, 1), (result, Ref.get(log), Map.size(TextureTable3d.createdOf(table))))

    /// 上限の内でも、作っていない古い番号は外し、その番号を次の鍵に使い回す。
    @Test
    def testTextureSweepUnderBudgetFreesStaleNumber(): Unit \ {Assert, IO} =
        let table = TextureTable3d.fresh();
        discard TextureTable3d.numberOf(table, 1i64, TextureSlot.Scene("never-made"));
        discard TextureTable3d.sweep(table, noDestroy(), 10i64, { count = 4, size = 1000i64 }, Set.empty());
        Assert.assertEq(expected = 0, TextureTable3d.numberOf(table, 10i64, TextureSlot.Scene("next")))

    /// 同じ鍵を同じコマに何度引いても、使った世代は最後に引いた世代になる（上限を超えた時に捨てる順は、この世代で決まる）。
    @Test
    def testTextureTouchKeepsLatestGeneration(): Unit \ {Assert, IO} =
        let table = TextureTable3d.fresh();
        let slot = TextureSlot.Scene("k");
        discard TextureTable3d.ensure(table, noDestroy(), 1i64, slot, "", made(1));
        discard TextureTable3d.numberOf(table, 5i64, slot);
        discard TextureTable3d.numberOf(table, 5i64, slot);
        Assert.assertEq(expected = Some(5i64), Map.get(slot, TextureTable3d.createdOf(table)) |> Option.map(e -> { let (_, _, used) = e; used }))

    /// mip の作り方の鍵の字は Mip.Average の ToString と同じ（先に上げた絵の鍵と合わせる）。
    @Test
    def testMipKeyMatchesAverageName(): Unit \ Assert =
        Assert.assertEq(expected = (ToString.toString(Mip.Average.SrgbCurve), ToString.toString(Mip.Average.Raw), "gpu"),
                        (TextureTable3d.mipKeyOf(false, Mip.Average.SrgbCurve), TextureTable3d.mipKeyOf(false, Mip.Average.Raw), TextureTable3d.mipKeyOf(true, Mip.Average.Raw)))

    // ── 材質の値と版 ──

    /// 段の数は 1 × 1 まで半分ずつ（8 × 4 → 8×4・4×2・2×1・1×1 の 4 段）。
    @Test
    def testLevelsHalveToOne(): Unit \ Assert =
        Assert.assertEq(expected = (4, 1, 6), (TextureTable3d.levelsOf(8, 4), TextureTable3d.levelsOf(1, 1), TextureTable3d.levelsOf(33, 2)))

    /// 材質の値は物ごとの区画 64 個と、sg の欄（uTime・絵の数・params）を 64 個の倍数に切り上げた区画。
    @Test
    def testValueSizeRoundsSgBlock(): Unit \ Assert =
        let size = (reads, params) -> Render3d.MaterialValues.valueSizeOf({ readCount = reads, paramNames = List.range(0, params) |> List.map(Int32.toString) });
        Assert.assertEq(expected = (128, 128, 192), (size(0, 0), size(6, 57), size(6, 58)))

    def plainKind(): Render3d.ProgramKey.ProgramKind =
        { skinned = false, uv = true, normalMap = true, lightmap = false, blend = false, doubleSided = true, coverage = false, metallicRoughness = true, screenAoOnBlend = false, variant = { pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = false } }

    /// WebGPU が描く版は alpha to coverage の無い版（骨つき・uv・法線マップ・lightmap・半透明・両面・metallic と roughness は描く）。
    @Test
    def testDrawableKinds(): Unit \ Assert =
        let k = plainKind();
        let drawable = Render3d.WebGpuMaterials.isDrawable;
        Assert.assertEq(expected = (true, true, true, true, false),
                        (drawable(k), drawable({ skinned = true | k }), drawable({ lightmap = true | k }), drawable({ blend = true | k }), drawable({ coverage = true | k })))
}
