// 影の地図の pass の計画と描き先の寿命の表（Render3d.ShadowMaps）が、どの鍵の描き先へ描かせ・いつ作らせ・捨てさせるかを固定する。
// GPU を呼ばない関数（呼ばれた順に "create 64/0"・"destroy 64/0" を控える）で表を育て、控えと表を読む。

mod Render3d.TestShadowMaps {
    use Render3d.ShadowMaps
    use Render3d.ShadowMaps.{ShadowMapUse, ShadowSampling}

    // ── 組み立て ──

    def planner(): Render3d.ScenePlan.Planner \ IO = Render3d.ScenePlan.freshPlanner(Render3d.DrawMode.Instanced)

    /// 一辺 size・pcfRadius pcf の影を落とすスポット（pickLights の後の並びの index 番目）の材料（物は無い）。
    def spotPlan(size: Int32, pcf: Int32, index: Int32): Render3d.ShadowPlan[Int32] =
        let spot = { shadow = Some({ mapSize = size, bias = 0.001, pcfRadius = pcf, strength = 1.0 }) | Scene3d.spotLight(Vec3.v3(0.0, 5.0, 0.0), Vec3.zero(), 1.0) };
        let settings = { mapSize = size, bias = 0.001, pcfRadius = pcf, strength = 1.0 };
        { caster = { matrix = Scene3d.shadowMatrix(spot), frustum = Scene3d.shadowFrustumOf(spot), settings = settings },
          light = Render3d.ShadowLight.Spot(index), plain = Nil, skinned = Nil }

    def keysOf(uses: List[List[ShadowMapUse]]): List[List[(Int32, Int32)]] = uses |> List.map(List.map(u -> u#key))

    def pcfOf(u: ShadowMapUse): Int32 = match u#sampling {
        case ShadowSampling.Spot(s) => s#pcfRadius
        case ShadowSampling.Sun(s)  => s#pcfRadius
    }

    /// f の答え（f が標準エラーへ書く知らせは捨てる）。
    def quietly(f: Unit -> List[List[ShadowMapUse]] \ IO): List[List[ShadowMapUse]] \ IO =
        let out = Ref.fresh(Static, Nil);
        discard Render3d.FakeGl.stderrOf(() -> Ref.put(f(), out));
        Ref.get(out)

    /// 呼ばれた順を控える Allocator。
    def recordingAllocator(log: Ref[List[String], Static]): ShadowMaps.Allocator =
        { create = key -> Ref.put("create ${fst(key)}/${snd(key)}" :: Ref.get(log), log),
          destroy = key -> Ref.put("destroy ${fst(key)}/${snd(key)}" :: Ref.get(log), log) }

    // ── 計画 ──

    /// 同じ一辺の地図は、場面をまたいでも同じ prepare の中で何枚目かの番号で分かれる（一辺が違えば 0 から）。
    @Test
    def testSameSizeAcrossScenesGetsNextOrdinal(): Unit \ {Assert, IO} =
        let uses = ShadowMaps.assign(planner(), (spotPlan(64, 0, 0) :: Nil) :: (spotPlan(64, 0, 0) :: spotPlan(128, 0, 1) :: Nil) :: Nil);
        Assert.assertEq(expected = ((64, 0) :: Nil) :: ((64, 1) :: (128, 0) :: Nil) :: Nil, keysOf(uses))

    /// 上限を超える一辺は上限の一辺の鍵で描く。
    @Test
    def testOversizedMapUsesTheLimit(): Unit \ {Assert, IO} =
        let uses = quietly(() -> ShadowMaps.assign(planner(), (spotPlan(Scene3d.maxShadowMapSize() * 2, 0, 0) :: Nil) :: Nil));
        Assert.assertEq(expected = ((Scene3d.maxShadowMapSize(), 0) :: Nil) :: Nil, keysOf(uses))

    /// スポットの pcfRadius は上限で頭打ちにし、負は 0 にする。
    @Test
    def testSpotPcfIsClamped(): Unit \ {Assert, IO} =
        let uses = quietly(() -> ShadowMaps.assign(planner(), (spotPlan(64, Scene3d.maxShadowPcfRadius() + 3, 0) :: spotPlan(32, -2, 1) :: Nil) :: Nil));
        Assert.assertEq(expected = (Scene3d.maxShadowPcfRadius() :: 0 :: Nil) :: Nil, uses |> List.map(List.map(pcfOf)))

    // ── 寿命 ──

    /// 同じ鍵は 1 回だけ作らせる（2 回目の ensure は作らない）。
    @Test
    def testEnsureCreatesOnce(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = ShadowMaps.fresh();
        let first = ShadowMaps.ensure(table, recordingAllocator(log), 1i64, (64, 0));
        let second = ShadowMaps.ensure(table, recordingAllocator(log), 2i64, (64, 0));
        Assert.assertEq(expected = (true, false, "create 64/0" :: Nil), (first, second, Ref.get(log)))

    /// Render3d.idleTargetFrames() を超えて使わなかった描き先だけを捨てさせる。
    @Test
    def testSweepDropsOnlyIdleTargets(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = ShadowMaps.fresh();
        let idle = Render3d.idleTargetFrames();
        discard ShadowMaps.ensure(table, recordingAllocator(log), 1i64, (64, 0));
        discard ShadowMaps.ensure(table, recordingAllocator(log), 1i64 + idle, (64, 1));
        let dropped = ShadowMaps.sweep(table, recordingAllocator(log), 2i64 + idle);
        Assert.assertEq(expected = (1, "destroy 64/0" :: "create 64/1" :: "create 64/0" :: Nil, Map#{ (64, 1) => 1i64 + idle }),
                        (dropped, Ref.get(log), ShadowMaps.createdOf(table)))

    /// 捨てた鍵をもう一度使うと作り直させる。
    @Test
    def testSweptKeyIsCreatedAgain(): Unit \ {Assert, IO} =
        let log = Ref.fresh(Static, Nil);
        let table = ShadowMaps.fresh();
        discard ShadowMaps.ensure(table, recordingAllocator(log), 1i64, (64, 0));
        discard ShadowMaps.sweep(table, recordingAllocator(log), 2i64 + Render3d.idleTargetFrames());
        Assert.assertTrue(ShadowMaps.ensure(table, recordingAllocator(log), 3i64 + Render3d.idleTargetFrames(), (64, 0)))
}
