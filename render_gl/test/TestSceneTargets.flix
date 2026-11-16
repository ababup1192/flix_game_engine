// 場面の描き先の寿命の表（Render3d.SceneTargets）の作り直しと捨てる時を、GPU を使わない Allocator で固定する。
// WhyNot: mod TestSceneTargets にしない — Render3d.SceneTargets は pub でなく、子の mod からだけ見える。
mod Render3d.SceneTargets.TestSceneTargets {
    use Render3d.SceneTargets.{Allocator, Shape, Table, createdOf, ensure, fresh, sweep}

    def shape(w: Int32): Shape = { width = w, height = 32, format = RenderTarget.Format.Rgba8Unorm, samples = 1 }

    /// 作った番号を 1 から振り、捨てた番号を控える Allocator。
    def counting(made: Ref[Int32, Static], dropped: Ref[List[Int32], Static]): Allocator[Int32] =
        { create = _ -> { Ref.put(Ref.get(made) + 1, made); Ref.get(made) }, destroy = n -> Ref.put(n :: Ref.get(dropped), dropped) }

    /// 同じ鍵と同じ形なら、2 回目は作らずに前の描き先を返す。
    @Test
    def testSameShapeReusesTarget(): Unit \ {Assert, IO} =
        let made = Ref.fresh(Static, 0);
        let dropped = Ref.fresh(Static, Nil);
        let table: Table[Int32, Int32] = fresh();
        discard ensure(table, counting(made, dropped), 0i64, 7, shape(64));
        Assert.assertEq(expected = (1, false), ensure(table, counting(made, dropped), 1i64, 7, shape(64)))

    /// 形が変われば前の描き先を捨てて作り直す。
    @Test
    def testShapeChangeRebuildsAndDropsOld(): Unit \ {Assert, IO} =
        let made = Ref.fresh(Static, 0);
        let dropped = Ref.fresh(Static, Nil);
        let table: Table[Int32, Int32] = fresh();
        discard ensure(table, counting(made, dropped), 0i64, 7, shape(64));
        let again = ensure(table, counting(made, dropped), 1i64, 7, shape(48));
        Assert.assertEq(expected = ((2, true), 1 :: Nil), (again, Ref.get(dropped)))

    /// idleTargetFrames の数のコマまでは残し、それを超えて使わなかった描き先だけを捨てる。
    @Test
    def testSweepDropsOnlyIdleTargets(): Unit \ {Assert, IO} =
        let made = Ref.fresh(Static, 0);
        let dropped = Ref.fresh(Static, Nil);
        let table: Table[Int32, Int32] = fresh();
        discard ensure(table, counting(made, dropped), 0i64, 1, shape(64));
        discard ensure(table, counting(made, dropped), 10i64, 2, shape(64));
        let kept = sweep(table, counting(made, dropped), Render3d.idleTargetFrames());
        let swept = sweep(table, counting(made, dropped), Render3d.idleTargetFrames() + 1i64);
        Assert.assertEq(expected = (0, 1, 1 :: Nil, Map#{2 => 10i64}), (kept, swept, Ref.get(dropped), createdOf(table)))
}
