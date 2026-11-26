// 置き方の使い分けの知らせ（docs/scene3d.md の「物の置き方を選ぶ」）: staticGroup を勧める知らせ（@static-group-hint）・draw call の知らせ（@draw-call-hint）・
// 同じ形が instances に多い知らせ（@same-shape-hint）・散らばりすぎた MultiMesh の知らせ（@multimesh-spread-hint）が、場面ごとに鳴るか鳴らないか。
mod Render3d.TestCrowdHints {
    use Render3d.FakeGl.{cmdOf, plainTriangle, sceneOf, stderrOf}
    use Render3d.ScenePlan.{Planner, freshPlanner, groupScenes, noteDrawCallHint, noteStaticGroupHint, staticHintScenes}

    def caps(): Render3d.ScenePlan.PlanCaps = { alphaToOne = false, poseRowLimit = 4096 }

    def triangle(side: Float64): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(side, 0.0, 0.0) :: Vec3.v3(0.0, side, 0.0) :: Nil, color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    // 場面 scene を frames 回続けて計画して、そのあいだに出た知らせの字。
    def saidOver(frames: Int32, scene: Scene3d.Scene3dCmd): String \ IO =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        stderrOf(() -> List.range(0, frames) |> List.forEach(_ -> {
            discard groupScenes(planner, caps(), 1, cmdOf(scene) :: Nil);
            noteStaticGroupHint(planner, Render3d.StaticRows.itemCountOf(scene), scene)
        }))

    // n 体を k 種類の形で、カメラの前に格子に置いた instances。
    def placedOf(n: Int32, kinds: Int32): List[Scene3d.Instance3d] =
        let shapes = Vector.range(0, kinds) |> Vector.map(k -> triangle(0.1 + 0.01 * Int32.toFloat64(k)));
        List.range(0, n) |> List.map(i -> Scene3d.meshInstance(Vector.get(Int32.modulo(i, kinds), shapes),
            Mat4.translate(Vec3.v3(0.01 * Int32.toFloat64(Int32.modulo(i, 100)), 0.01 * Int32.toFloat64(i / 100), 0.0))))

    def has(key: String, said: String): Bool = String.contains(substr = key, said)

    /// 形 30 種の町を instances に置くと staticGroup の知らせだけが鳴り、文は動かない物と動く物の 2 択（同じ形の知らせは鳴らない）。
    @Test
    def testTownRingsStaticGroupOnly(): Unit \ {Assert, IO} =
        let said = saidOver(staticHintScenes(), sceneOf(placedOf(2100, 30)));
        Assert.assertEq(expected = (true, true, false), (has("Scene3d.staticGroup", said), has("MultiMesh3d.build で 1 つにする（engine", said), has("同じ形と材質の物が", said)))

    /// 同じ形の物を 2,000 体 instances に置き続けると、同じ形の知らせが鳴る。
    @Test
    def testSameShapeCrowdRingsSameShapeHint(): Unit \ {Assert, IO} =
        Assert.assertTrue(has("同じ形と材質の物が 2000 体 instances にある", saidOver(staticHintScenes(), sceneOf(placedOf(2000, 1)))))

    /// 同じ形の物が 2,000 体に届かなければ、同じ形の知らせは鳴らない。
    @Test
    def testFewSameShapesStayQuiet(): Unit \ {Assert, IO} =
        Assert.assertFalse(has("同じ形と材質の物が", saidOver(staticHintScenes(), sceneOf(placedOf(1999, 1)))))

    /// 続く場面が 1 つ足りなければ、同じ形の知らせは鳴らない。
    @Test
    def testSameShapeNeedsTheFullStreak(): Unit \ {Assert, IO} =
        Assert.assertFalse(has("同じ形と材質の物が", saidOver(staticHintScenes() - 1, sceneOf(placedOf(2000, 1)))))

    /// 同じ形の物 5,000 体を MultiMesh で渡すと、どの知らせも鳴らない（MultiMesh の体は置いた物に数えない）。
    @Test
    def testMultiMeshCrowdStaysQuiet(): Unit \ {Assert, IO} =
        let crowd = MultiMesh3d.build(plainTriangle(), 5000, i -> Mat4.translate(Vec3.v3(0.001 * Int32.toFloat64(i), 0.0, 0.0)));
        Assert.assertEq(expected = "", saidOver(staticHintScenes(), { multiMeshes = crowd :: Nil | sceneOf(Nil) }))

    /// 形の違う小物で draw call が多い場面は draw call の知らせが鳴り、同じ形の知らせは鳴らない。
    @Test
    def testShapeSplitRingsDrawCallHintOnly(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let said = stderrOf(() -> List.range(0, staticHintScenes()) |> List.forEach(_ -> {
            discard groupScenes(planner, caps(), 1, cmdOf(sceneOf(placedOf(800, 800))) :: Nil);
            noteDrawCallHint(planner, 800, 799)
        }));
        Assert.assertEq(expected = (true, false), (has("draw call が 800", said), has("同じ形と材質の物が", said)))

    // 2 体を x = 0 と x = gap に置いた MultiMesh（群れ全体の境界の対角はほぼ gap）。
    def pairApart(gap: Float64): MultiMesh3d.MultiMesh3d =
        MultiMesh3d.build(plainTriangle(), 2, i -> Mat4.translate(Vec3.v3(gap * Int32.toFloat64(i), 0.0, 0.0)))

    /// 境界がカメラの far（100）の 2 倍を超える MultiMesh が 600 場面続くと、散らばりの知らせが鳴る。
    @Test
    def testSpreadMultiMeshRings(): Unit \ {Assert, IO} =
        Assert.assertTrue(has("区画（数十 m 角）ごとの MultiMesh に分ける", saidOver(Render3d.MultiMeshPlan.spreadHintScenes(), { multiMeshes = pairApart(250.0) :: Nil | sceneOf(Nil) })))

    /// 境界が far の 2 倍に届かない群れ（届かない距離で消す弾）は、何場面続いても散らばりの知らせは鳴らない。
    @Test
    def testBoundedMultiMeshStaysQuiet(): Unit \ {Assert, IO} =
        Assert.assertFalse(has("区画（数十 m 角）", saidOver(Render3d.MultiMeshPlan.spreadHintScenes(), { multiMeshes = pairApart(150.0) :: Nil | sceneOf(Nil) })))

    /// 散らばった群れでも 600 場面に届かなければ鳴らない（遠くへ飛んでから消える弾）。
    @Test
    def testSpreadNeedsTheFullStreak(): Unit \ {Assert, IO} =
        Assert.assertFalse(has("区画（数十 m 角）", saidOver(Render3d.MultiMeshPlan.spreadHintScenes() - 1, { multiMeshes = pairApart(250.0) :: Nil | sceneOf(Nil) })))

    /// ポーズの間に同じ MultiMesh の値を渡し続けても、何も鳴らない。
    @Test
    def testPausedMultiMeshStaysQuiet(): Unit \ {Assert, IO} =
        let held = MultiMesh3d.build(plainTriangle(), 50, i -> Mat4.translate(Vec3.v3(0.01 * Int32.toFloat64(i), 0.0, 0.0)));
        Assert.assertEq(expected = "", saidOver(Render3d.MultiMeshPlan.spreadHintScenes(), { multiMeshes = held :: Nil | sceneOf(Nil) }))
}
