// 場面の multiMeshes の計画（Render3d.MultiMeshPlan）と、番号を振って場面の pass・影の地図の pass へ足す所（Render3d.InstanceValues.mapBatchesWithMultiMeshes）・
// 詰めた並びの持ち越し（Render3d.InstanceValues.numberMultiMesh）。GL を呼ばない。
mod Render3d.TestMultiMeshPlan {
    import java.nio.FloatBuffer
    use Render3d.Batch.{MeshBatch}
    use Render3d.FakeGl.{cmdOf, plainTriangle, sceneOf, shadowSpot, stderrOf}
    use Render3d.InstanceValues.{MultiCarry, freshMultiCarry, mapBatchesWithMultiMeshes, numberMultiMesh, numberSpan}
    use Render3d.ScenePlan.{ScenePlan, freshPlanner, groupScenes, planScenes}

    def caps(): Render3d.ScenePlan.PlanCaps = { alphaToOne = false, poseRowLimit = 4096 }

    // カメラ（原点から 5 だけ手前・+Z を見る）の前に、n 体を少しずつずらして置いた群れ。
    def crowdAt(n: Int32, z: Float64): MultiMesh3d.MultiMesh3d =
        MultiMesh3d.build(plainTriangle(), n, i -> Mat4.translate(Vec3.v3(0.1 * Int32.toFloat64(i), 0.0, z)))

    def crowd(n: Int32): MultiMesh3d.MultiMesh3d = crowdAt(n, 0.0)

    def red(): Scene3d.Material3d =
        Scene3d.material({ name = "red", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.9, g = 0.1, b = 0.1 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    def withMulti(mm: MultiMesh3d.MultiMesh3d, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd = { multiMeshes = mm :: Nil | scene }

    /// scene を計画して番号を振った場面と、振った体の数（番号の次）。材質は全部使えると答える。
    def numbered(scene: Scene3d.Scene3dCmd): (ScenePlan[MeshBatch], Int32) \ IO =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let grouped = groupScenes(planner, caps(), 1, cmdOf(scene) :: Nil);
        let answer = Vector.range(0, Vector.length(grouped#requests)) |> Vector.map(k -> k + 1);
        let (plans, _) = planScenes(planner, caps(), answer, grouped);
        let out = FloatBuffer.allocate(32 * 4096);
        let scratch = Array.repeat(Static, 32, 0.0f32);
        let next = Array#{0} @ Static;
        let carry = freshMultiCarry();
        let plan = match List.head(plans) {
            case Some(pl) => pl
            case None     => bug!("plan")
        };
        let mapped = mapBatchesWithMultiMeshes(numberSpan(out, scratch, 4096, next, grouped#members), numberMultiMesh(out, scratch, 4096, next, carry, 1i64), plan);
        (mapped, Array.get(0, next))

    def counts(bs: List[MeshBatch]): List[Int32] = List.map(b -> b#count, bs)

    /// 材質の無い MultiMesh は、頂点の色の batch 1 本（体の数）になる。
    @Test
    def testVertexColorMultiMeshIsOnePlainBatch(): Unit \ {Assert, IO} =
        let (p, used) = numbered(withMulti(crowd(5), sceneOf(Nil)));
        Assert.assertEq(expected = (5 :: Nil, 0, 5), (counts(p#draws#plain), List.length(p#draws#opaque), used))

    /// 材質のある MultiMesh は、材質の batch 1 本になる（頂点の色の batch には入らない）。
    @Test
    def testMaterialMultiMeshIsOneMaterialBatch(): Unit \ {Assert, IO} =
        let (p, _) = numbered(withMulti(crowd(4) |> MultiMesh3d.withMaterial(red()), sceneOf(Nil)));
        Assert.assertEq(expected = (0, 4 :: Nil), (List.length(p#draws#plain), p#draws#opaque |> List.map(d -> d#batch#count)))

    /// 半透明を頼まれた MultiMesh は、不透明の材質の batch で描く（半透明の列に入らない）。
    @Test
    def testBlendRequestDrawsOpaque(): Unit \ {Assert, IO} =
        let glass = red() |> Scene3d.withAlphaBlend(true);
        let lists = Ref.fresh(Static, (0, 0));
        let said = stderrOf(() -> {
            let (p, _) = numbered(withMulti(crowd(3) |> MultiMesh3d.withMaterial(glass), sceneOf(Nil)));
            Ref.put((List.length(p#draws#opaque), List.length(p#draws#blended)), lists)
        });
        Assert.assertEq(expected = ((1, 0), true), (Ref.get(lists), String.contains(substr = "不透明として描く", said)))

    /// 骨の重みを持つ形の MultiMesh は、バインドポーズで描くと 1 回知らせる。
    @Test
    def testSkinnedShapeIsReported(): Unit \ {Assert, IO} =
        let skinned = MultiMesh3d.build(Render3d.FakeGl.skinnedTriangle(), 3, i -> Mat4.translate(Vec3.v3(0.1 * Int32.toFloat64(i), 0.0, 0.0)));
        let said = stderrOf(() -> discard numbered(withMulti(skinned, sceneOf(Nil))));
        Assert.assertTrue(String.contains(substr = "バインドポーズで描く", said))

    /// MultiMesh だけの場面でも、スポットの影の地図に MultiMesh を描く。
    @Test
    def testSpotShadowCastsMultiMesh(): Unit \ {Assert, IO} =
        let (p, _) = numbered({ spotLights = shadowSpot() :: Nil | withMulti(crowd(6), sceneOf(Nil)) });
        Assert.assertEq(expected = (6 :: Nil) :: Nil, p#shadowPlans |> List.map(s -> counts(s#plain)))

    /// MultiMesh だけの場面でも、太陽の影の地図に MultiMesh を描く。
    @Test
    def testSunShadowCastsMultiMesh(): Unit \ {Assert, IO} =
        let sun = { shadow = Some({ mapSize = 64, pcfRadius = 1 | Scene3d.directionalShadow() }) | Scene3d.directionalLight(Vec3.v3(0.3, -1.0, 0.4)) };
        let (p, _) = numbered({ directionalLight = Some(sun) | withMulti(crowd(6), sceneOf(Nil)) });
        Assert.assertEq(expected = (6 :: Nil) :: Nil, p#shadowPlans |> List.map(s -> counts(s#plain)))

    /// 点光源の影の面（6 つ）のうち群れに掛かる面に MultiMesh を描き、並びを詰めるのは 1 回だけ（番号は体の数だけ進む）。
    @Test
    def testPointShadowFacesShareOnePacking(): Unit \ {Assert, IO} =
        let lamp = { position = Vec3.v3(0.2, 1.0, 0.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 };
        let scene = { pointLights = lamp :: Nil | withMulti(crowd(6), sceneOf(Nil)) } |> Scene3d.withPointShadows({ maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() });
        let (p, used) = numbered(scene);
        let faces = p#shadowPlans |> List.filter(s -> List.exists(b -> b#count == 6, s#plain));
        let firsts = faces |> List.flatMap(s -> List.map(b -> b#first, s#plain)) |> List.toSet;
        Assert.assertEq(expected = (true, 6, 1), (List.length(faces) >= 1, used, Set.size(firsts)))

    /// カメラの後ろの群れは場面の pass で描かず、スポットの影の地図には描く。
    @Test
    def testOutsideCameraStillCastsShadow(): Unit \ {Assert, IO} =
        let spot = { position = Vec3.v3(0.0, 5.0, -20.0), target = Vec3.v3(0.0, 0.0, -20.0) | shadowSpot() };
        let (p, _) = numbered({ spotLights = spot :: Nil | withMulti(crowdAt(4, -20.0), sceneOf(Nil)) });
        Assert.assertEq(expected = (Nil, (4 :: Nil) :: Nil), (counts(p#draws#plain), p#shadowPlans |> List.map(s -> counts(s#plain))))

    /// どの pass の視錐台にも掛からない群れは詰めない（番号が進まない）。
    @Test
    def testInvisibleMultiMeshIsNotPacked(): Unit \ {Assert, IO} =
        let (p, used) = numbered(withMulti(crowdAt(4, -20.0), sceneOf(Nil)));
        Assert.assertEq(expected = (Nil, 0), (counts(p#draws#plain), used))

    /// 奥行きの書き出しの場面では、cutout の材質の MultiMesh は材質の batch・ただの材質の MultiMesh は形だけの batch で書く。
    @Test
    def testDepthOutputFollowsTheMaterialRule(): Unit \ {Assert, IO} =
        let depth = (m: Scene3d.Material3d) -> { output = Scene3d.Output.Depth({ near = 0.5, range = 12.0 }) | withMulti(crowd(3) |> MultiMesh3d.withMaterial(m), sceneOf(Nil)) };
        let (cut, _) = numbered(depth(red() |> Scene3d.withCutout(true)));
        let (plain, _) = numbered(depth(red()));
        Assert.assertEq(expected = ((0, 1), (1, 0)), ((List.length(cut#draws#plain), List.length(cut#draws#opaque)), (List.length(plain#draws#plain), List.length(plain#draws#opaque))))

    // ── 持ち越し ──

    // mm を世代 gen で詰めた 32 × 体の数の並び。
    def packedAt(carry: MultiCarry, gen: Int64, mm: MultiMesh3d.MultiMesh3d): List[Float32] \ IO =
        let n = MultiMesh3d.countOf(mm);
        let out = FloatBuffer.allocate(32 * n);
        discard numberMultiMesh(out, Array.repeat(Static, 32, 0.0f32), n, Array#{0} @ Static, carry, gen, mm);
        List.range(0, 32 * n) |> List.map(i -> out.get(i))

    /// 同じ値を続けて渡すと 3 コマ目からは控えを写すが、並びは毎回詰めた物と同じ。
    @Test
    def testCarriedValuesMatchFreshPacking(): Unit \ {Assert, IO} =
        let mm = crowd(5) |> MultiMesh3d.withColors(i -> Color.rgb(0.2 * Int32.toFloat64(i), 0.4, 0.6));
        let fresh = packedAt(freshMultiCarry(), 1i64, mm);
        let carry = freshMultiCarry();
        let runs = List.range(1, 5) |> List.map(gen -> packedAt(carry, Int32.toInt64(gen), mm));
        Assert.assertEq(expected = List.repeat(4, fresh), runs)

    /// 2 コマずつ生きる値を替えながら渡しても（控えを使い回す道）、どのコマの並びも毎回詰めた物と同じ。
    @Test
    def testTwoFrameValuesStayCorrect(): Unit \ {Assert, IO} =
        let carry = freshMultiCarry();
        let values = List.range(0, 4) |> List.map(k -> crowdAt(4, 0.5 * Int32.toFloat64(k)));
        let frames = values |> List.flatMap(mm -> mm :: mm :: Nil) |> List.mapWithIndex((gen, mm) -> (gen, mm));
        let carried = frames |> List.map(match (gen, mm) -> packedAt(carry, Int32.toInt64(gen + 1), mm));
        let fresh = frames |> List.map(match (_, mm) -> packedAt(freshMultiCarry(), 1i64, mm));
        Assert.assertEq(expected = fresh, carried)
}
