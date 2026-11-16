// 3D の不透明の batch の行（Render3d.SceneList）と、行を作るまでの計画（Render3d.ScenePlan）。計画は GL を呼ばずに決まり、backend の答えは値で渡す。
mod Render3d.TestSceneList {
    import java.nio.FloatBuffer
    use Render3d.Batch.{MaterialBatch, MeshBatch, SpanBatch, batchKeyOf, groupByTextures, groupInOrder}
    use Render3d.Counts.{BatchBreak, breakSlotOf}
    use Render3d.Instancing.{PackMode, numberSpan}
    use Render3d.FakeGl.{cmdOf, freshRecorded, freshState, paint, plainTriangle, poseAt, recordingGl, sceneOf, timesCalled}
    use Render3d.SceneList.{SceneList, buildSceneList, buildScenePasses, flagCoverage, flagDoubleSided, flagSameBinding, hasFlag, kindMaterial, kindSkinned, kindVertexColor, rowAt, rowCountOf}
    use Render3d.ScenePlan.{PlanCaps, ScenePassSpec, freshPlanner, groupScenes, kindOf, meshDrawOf, planScenes}

    def triangle(side: Float64): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(side, 0.0, 0.0) :: Vec3.v3(0.0, side, 0.0) :: Nil, color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    def drawOf(mesh: Mesh3d.Mesh3d): Render3d.MeshDraw =
        { fields = Scene3d.instanceFieldsOf(Scene3d.meshInstance(mesh, Mat4.identity())), pose = None, poseRow = 0, culled = false }

    def batchOf(mesh: Mesh3d.Mesh3d, first: Int32, count: Int32): MeshBatch = { head = drawOf(mesh), count = count, first = first }

    def plainKind(): Render3d.ProgramKind =
        { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false }

    /// 赤の量 red で木の違う、名前 name の材質。
    def materialOf(red: Float64): Scene3d.Material3d =
        Scene3d.material({ name = "m${red}", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = red, g = 0.5, b = 0.5 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    def fieldsOf(red: Float64): Scene3d.MaterialFields = Scene3d.materialFieldsOf(materialOf(red))

    def materialBatch(handle: Int32, order: Int32, red: Float64, b: MeshBatch): MaterialBatch[MeshBatch] =
        { handle = handle, order = order, kind = plainKind(), material = fieldsOf(red), batch = b }

    def listOf(plain: List[MeshBatch], skinned: List[MeshBatch], opaque: List[MaterialBatch[MeshBatch]]): SceneList \ IO =
        buildSceneList(Render3d.MeshTable.fresh(), 1i64, { plain = plain, skinned = skinned, opaque = opaque, blended = Nil })

    def column(list: SceneList, col: Int32): List[Int32] \ IO =
        List.range(0, rowCountOf(list)) |> List.map(row -> rowAt(list, row, col))

    // ── 行 ──

    /// 行は頂点の色・骨つき・材質の順に並ぶ。
    @Test
    def testRowsKeepVertexColorSkinnedMaterialOrder(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 0, 1) :: Nil, batchOf(triangle(2.0), 1, 1) :: Nil, materialBatch(0, 5, 0.1, batchOf(triangle(3.0), 2, 1)) :: Nil);
        Assert.assertEq(expected = kindVertexColor() :: kindSkinned() :: kindMaterial() :: Nil, column(list, 0))

    /// 材質の行は材質の表の番号と順の番号を持つ。
    @Test
    def testMaterialRowCarriesHandleAndOrder(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(4, 9, 0.1, batchOf(triangle(1.0), 0, 1)) :: Nil);
        Assert.assertEq(expected = (4, 9), (rowAt(list, 0, 1), rowAt(list, 0, 2)))

    /// 行は 1 体ごとの値の先頭と描く物の数を持つ。
    @Test
    def testRowCarriesFirstAndCount(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 7, 3) :: Nil, Nil, Nil);
        Assert.assertEq(expected = (7, 3), (rowAt(list, 0, 3), rowAt(list, 0, 4)))

    /// 頂点の色の行は Mesh・骨つきの行は Skinned で分かれた理由を数える。
    @Test
    def testShapeRowsBreakByMeshAndSkinned(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 0, 1) :: Nil, batchOf(triangle(2.0), 1, 1) :: Nil, Nil);
        Assert.assertEq(expected = breakSlotOf(BatchBreak.Mesh) :: breakSlotOf(BatchBreak.Skinned) :: Nil, column(list, 5))

    /// 同じ材質で形が違う行は Mesh・違う材質の行は Material で分かれる。
    @Test
    def testMaterialRowsBreakByMeshOrMaterial(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1))
                                    :: materialBatch(2, 4, 0.9, batchOf(triangle(2.0), 2, 1)) :: Nil);
        Assert.assertEq(expected = breakSlotOf(BatchBreak.Material) :: breakSlotOf(BatchBreak.Mesh) :: breakSlotOf(BatchBreak.Material) :: Nil, column(list, 5))

    /// 描く物の無い材質の行は前の材質を替えない（その次の同じ材質の別の形は Mesh で分かれる）。
    @Test
    def testCulledMaterialRowKeepsPrevious(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: materialBatch(1, 4, 0.9, batchOf(triangle(2.0), 1, 0))
                                    :: materialBatch(2, 3, 0.1, batchOf(triangle(3.0), 1, 1)) :: Nil);
        Assert.assertEq(expected = breakSlotOf(BatchBreak.Mesh), rowAt(list, 2, 5))

    /// 両面の材質と alpha to coverage の版はフラグに立つ。
    @Test
    def testFlagsCarryDoubleSidedAndCoverage(): Unit \ {Assert, IO} =
        let b = batchOf(triangle(1.0), 0, 1);
        let d = { kind = { coverage = true | plainKind() }, material = { doubleSided = true | fieldsOf(0.1) } | materialBatch(0, 3, 0.1, b) };
        let list = listOf(Nil, Nil, d :: Nil);
        Assert.assertEq(expected = (true, true), (hasFlag(list, 0, flagDoubleSided()), hasFlag(list, 0, flagCoverage())))

    /// 同じ材質の値で形だけ違う 2 つ目の行は、前の行の付け方のまま描ける。
    @Test
    def testSameMaterialOtherMeshKeepsBinding(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1)) :: Nil);
        Assert.assertEq(expected = (false, true), (hasFlag(list, 0, flagSameBinding()), hasFlag(list, 1, flagSameBinding())))

    /// params が前の行と違う行は付け直す。
    @Test
    def testOtherParamsRebind(): Unit \ {Assert, IO} =
        let b = batchOf(triangle(2.0), 1, 1);
        let other = { material = { params = Map#{ "a" => 2.0 } | fieldsOf(0.1) } | materialBatch(1, 3, 0.1, b) };
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: other :: Nil);
        Assert.assertFalse(hasFlag(list, 1, flagSameBinding()))

    /// 絵の名前が前の行と違う行は付け直す。
    @Test
    def testOtherTextureRebinds(): Unit \ {Assert, IO} =
        let textured = (name: String, b: MeshBatch) -> { material = Scene3d.materialFieldsOf(Scene3d.texturedMaterial(name, ShaderDoc.FilterMode.Nearest)) | materialBatch(0, 3, 0.1, b) };
        let list = listOf(Nil, Nil, textured("a", batchOf(triangle(1.0), 0, 1)) :: textured("b", batchOf(triangle(2.0), 1, 1)) :: Nil);
        Assert.assertFalse(hasFlag(list, 1, flagSameBinding()))

    /// lightmap の版の行は、前と同じ材質でも付け直す。
    @Test
    def testLightmappedRebinds(): Unit \ {Assert, IO} =
        let baked = { kind = { lightmap = true | plainKind() } | materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1)) };
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: baked :: Nil);
        Assert.assertFalse(hasFlag(list, 1, flagSameBinding()))

    /// cutout の違う行は付け直す。
    @Test
    def testOtherCutoutRebinds(): Unit \ {Assert, IO} =
        let other = { material = { cutout = true | fieldsOf(0.1) } | materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1)) };
        Assert.assertFalse(hasFlag(listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: other :: Nil), 1, flagSameBinding()))

    /// wrap の違う行は付け直す。
    @Test
    def testOtherWrapRebinds(): Unit \ {Assert, IO} =
        let other = { material = { wrap = Scene3d.Wrap.Clamp | fieldsOf(0.1) } | materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1)) };
        Assert.assertFalse(hasFlag(listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: other :: Nil), 1, flagSameBinding()))

    /// 法線マップの違う行は付け直す。
    @Test
    def testOtherNormalMapRebinds(): Unit \ {Assert, IO} =
        let other = { material = { normalMap = Some({ texture = "n", strength = 1.0 }) | fieldsOf(0.1) } | materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1)) };
        Assert.assertFalse(hasFlag(listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: other :: Nil), 1, flagSameBinding()))

    /// 順の番号の違う行は付け直す。
    @Test
    def testOtherOrderRebinds(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: materialBatch(1, 4, 0.1, batchOf(triangle(2.0), 1, 1)) :: Nil);
        Assert.assertFalse(hasFlag(list, 1, flagSameBinding()))

    /// 絵の補間の違う行は付け直す。
    @Test
    def testOtherFilterRebinds(): Unit \ {Assert, IO} =
        let textured = (filter: ShaderDoc.FilterMode, b: MeshBatch) -> { material = Scene3d.materialFieldsOf(Scene3d.texturedMaterial("a", filter)) | materialBatch(0, 3, 0.1, b) };
        let list = listOf(Nil, Nil, textured(ShaderDoc.FilterMode.Nearest, batchOf(triangle(1.0), 0, 1)) :: textured(ShaderDoc.FilterMode.Linear, batchOf(triangle(2.0), 1, 1)) :: Nil);
        Assert.assertFalse(hasFlag(list, 1, flagSameBinding()))

    // ── 計画（GL を呼ばない）──

    def caps(alphaToOne: Bool): PlanCaps = { alphaToOne = alphaToOne, poseRowLimit = 4096 }

    def placed(red: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(materialOf(red))

    def grouped(cmds: List[Scene3d.RenderCmd]): Render3d.ScenePlan.Grouped \ IO =
        groupScenes(freshPlanner(Render3d.DrawMode.Instanced), caps(false), 1, cmds)

    /// cmds を計画し、backend の答え answer（聞いた材質ごとの順の番号）で分けた場面ごとの材質の batch の (handle, order) の並び。
    def plannedMaterials(cmds: List[Scene3d.RenderCmd], answer: Vector[Int32]): List[List[(Int32, Int32)]] \ IO =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let (plans, _) = planScenes(planner, caps(false), answer, groupScenes(planner, caps(false), 1, cmds));
        plans |> List.map(p -> List.map(d -> (d#handle, d#order), p#draws#opaque))

    /// 聞く材質は置いた物が来た順に並ぶ（材質ごとに 1 つ）。
    @Test
    def testRequestsFollowArrivalOrder(): Unit \ {Assert, IO} =
        let requests = grouped(cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: placed(0.1) :: Nil)) :: Nil)#requests;
        Assert.assertEq(expected = "m0.1" :: "m0.9" :: Nil, requests |> Vector.toList |> List.map(r -> fst(r)#spec#name))

    /// 形の違う物でも、同じ材質は 1 回だけ聞く。
    @Test
    def testSameMaterialOnTwoShapesAsksOnce(): Unit \ {Assert, IO} =
        let on = (mesh: Mesh3d.Mesh3d) -> Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(materialOf(0.1));
        Assert.assertEq(expected = 1, Vector.length(grouped(cmdOf(sceneOf(on(triangle(1.0)) :: on(triangle(2.0)) :: Nil)) :: Nil)#requests))

    /// 2 つ目の場面の材質の batch は、答えの 2 つ目の番号と順の番号を指す。
    @Test
    def testSecondSceneMaterialPointsAtSecondAnswer(): Unit \ {Assert, IO} =
        let cmds = cmdOf(sceneOf(placed(0.1) :: Nil)) :: cmdOf(sceneOf(placed(0.9) :: Nil)) :: Nil;
        Assert.assertEq(expected = ((0, 5) :: Nil) :: ((1, 8) :: Nil) :: Nil, plannedMaterials(cmds, Vector#{5, 8}))

    /// 材質の batch は backend の順の番号の小さい順に並ぶ。
    @Test
    def testMaterialsSortByBackendOrder(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (1, 3) :: (0, 9) :: Nil,
            plannedMaterials(cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: Nil)) :: Nil, Vector#{9, 3}) |> List.head |> Option.getWithDefault(Nil))

    /// backend が使えないと答えた（0）材質の物は、頂点の色の batch になる。
    @Test
    def testUnusableMaterialFallsToVertexColor(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let (plans, _) = planScenes(planner, caps(false), Vector#{0, 7}, groupScenes(planner, caps(false), 1, cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: Nil)) :: Nil));
        Assert.assertEq(expected = (1, 7 :: Nil), plans |> List.head |> Option.map(p -> (List.length(p#draws#plain), List.map(d -> d#order, p#draws#opaque))) |> Option.getWithDefault((0, Nil)))

    /// 標本つきの描き先で alpha to coverage を使える時だけ、cutout の材質を coverage の版で聞く。
    @Test
    def testCoverageNeedsSamplesAndCapability(): Unit \ {Assert, IO} =
        let cutout = Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(materialOf(0.1) |> Scene3d.withCutout(true));
        let asked = (alphaToOne: Bool, samples: Int32) ->
            groupScenes(freshPlanner(Render3d.DrawMode.Instanced), caps(alphaToOne), samples, cmdOf(sceneOf(cutout :: Nil)) :: Nil)#requests
                |> Vector.toList |> List.map(r -> snd(r)#coverage);
        Assert.assertEq(expected = (true :: Nil, false :: Nil, false :: Nil), (asked(true, 4), asked(false, 4), asked(true, 1)))

    /// 間引いた物は batch の描く物に入らない（形 1 つの 3 体のうち真ん中を間引くと、描く物は 2 体で来た順）。
    @Test
    def testCulledDrawLeavesTheSpan(): Unit \ {Assert, IO} =
        let at = (x: Float64, z: Float64) -> Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(x, 0.0, z)));
        let g = grouped(cmdOf(sceneOf(at(0.5, 0.0) :: at(0.0, -50.0) :: at(1.5, 0.0) :: Nil)) :: Nil);
        let worldX = (i: Int32) -> Vector.get(12, Mat4.toColumns(MutList.get(i, g#members)#fields#world));
        Assert.assertEq(expected = (2, 0.5, 1.5), (MutList.size(g#members), worldX(0), worldX(1)))

    // ── 候補の並び（答え合わせの見本と同じか）──

    /// 候補 1 つの (頭の形の鍵の字, 描く物の数, 材質の名前と絵の名前)。
    def describe(head: Render3d.MeshDraw, count: Int32): (String, Int32, String) =
        let material = head#fields#material |> Option.map(Scene3d.materialFieldsOf)
            |> Option.map(m -> m#spec#name + ":" + (ShaderDoc.materialTexReads(m#spec, m#emission, m#metallicRoughnessShade) |> List.map(fst) |> List.join(",")))
            |> Option.getWithDefault("");
        (Mesh3d.contentHash(head#fields#mesh), count, material)

    /// instances を計画の本番（groupScenes）で分けた候補の並び。
    def groupedOrder(instances: List[Scene3d.Instance3d]): List[(String, Int32, String)] \ IO =
        grouped(cmdOf(sceneOf(instances)) :: Nil)#scenes |> List.head
            |> Option.map(s -> List.map(g -> describe(g#batch#head, g#batch#count), s#groups)) |> Option.getWithDefault(Nil)

    /// 同じ instances を答え合わせの見本（Render3d.Batch.groupInOrder と groupByTextures と batchOf）で分けた候補の並び。
    def referenceOrder(instances: List[Scene3d.Instance3d]): List[(String, Int32, String)] \ IO =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let outside = Scene3d.isOutsideFrustum(Scene3d.frustumOf(sceneOf(instances)));
        let draws = instances |> List.map(meshDrawOf(planner, outside));
        let surfaceOf = (d: Render3d.MeshDraw) -> d#fields#material |> Option.map(Scene3d.materialFieldsOf) |> Option.map(m -> (m, kindOf(false, d, m)));
        groupInOrder(d -> Mesh3d.contentHash(d#fields#mesh), d -> batchKeyOf(Render3d.DrawMode.Instanced, d, surfaceOf(d)), draws)
            |> List.flatMap(groupByTextures(d -> Option.map(fst, surfaceOf(d))))
            |> List.filterMap(members -> List.head(members) |> Option.map(head -> { let b = Render3d.Batch.batchOf(head, members); describe(b#head, b#count) }))

    def on(mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d): Scene3d.Instance3d =
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(material)

    def textured(name: String): Scene3d.Material3d = Scene3d.texturedMaterial(name, ShaderDoc.FilterMode.Nearest)

    /// 形・材質・絵の名前・間引きの混ざった入力で、本番の候補の並びは答え合わせの見本と同じ。
    @Test
    def testGroupsMatchTheReference(): Unit \ {Assert, IO} =
        let (x, y) = (triangle(1.0), triangle(2.0));
        let behind = Scene3d.meshInstance(x, Mat4.translate(Vec3.v3(0.0, 0.0, -50.0))) |> Scene3d.withMaterial(materialOf(0.1));
        let instances = on(x, materialOf(0.1)) :: on(y, materialOf(0.1)) :: on(x, textured("a")) :: on(x, textured("b")) :: on(x, materialOf(0.1))
            :: Scene3d.meshInstance(y, Mat4.identity()) :: on(x, textured("a")) :: behind :: on(y, materialOf(0.9)) :: Scene3d.meshInstance(y, Mat4.identity()) :: Nil;
        Assert.assertEq(expected = referenceOrder(instances), groupedOrder(instances))

    /// 同じ 1 つの材質の値を uv の有る形・無い形・骨つきの形に付けても（材質の値の控えに当たる道）、候補の並びは見本と同じ。
    @Test
    def testSharedMaterialOnShapeVariantsMatchesTheReference(): Unit \ {Assert, IO} =
        let shared = materialOf(0.3);
        let uvMesh = match Mesh3d.withUvs(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }, triangle(1.0)) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        };
        let skinned = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity()) |> Scene3d.withPose(poseAt(1.0)) |> Scene3d.withMaterial(shared);
        let instances = on(uvMesh, shared) :: on(triangle(2.0), shared) :: skinned :: on(uvMesh, shared) :: on(triangle(2.0), shared) :: skinned :: Nil;
        Assert.assertEq(expected = referenceOrder(instances), groupedOrder(instances))

    /// 版と木の鍵が同じでも木の違う材質（木の鍵の衝突）は、候補の頭の確かめで別の番号になり、同じ材質は同じ番号のまま。
    @Test
    def testCollidingTreeKeyAsksSeparately(): Unit \ {Assert, IO} =
        let tables = Render3d.ScenePlan.freshTables();
        let colliding = (red: Float64) -> { shaderHash = lazy 1i64 | fieldsOf(red) };
        let asked = Render3d.ScenePlan.requestOf(tables, colliding(0.1), plainKind());
        let same = Render3d.ScenePlan.verifiedHandle(tables, Render3d.ScenePlan.requestOf(tables, colliding(0.1), plainKind()), colliding(0.1), plainKind());
        let other = Render3d.ScenePlan.verifiedHandle(tables, Render3d.ScenePlan.requestOf(tables, colliding(0.9), plainKind()), colliding(0.9), plainKind());
        Assert.assertEq(expected = (0, 0, 1), (asked, same, other))

    /// 形 X・Y・X は、X の 2 体・Y の 1 体の候補になる。
    @Test
    def testXyxGroupsXxThenY(): Unit \ {Assert, IO} =
        let (x, y) = (triangle(1.0), triangle(2.0));
        let plain = (mesh: Mesh3d.Mesh3d) -> Scene3d.meshInstance(mesh, Mat4.identity());
        Assert.assertEq(expected = (Mesh3d.contentHash(x), 2) :: (Mesh3d.contentHash(y), 1) :: Nil,
            groupedOrder(plain(x) :: plain(y) :: plain(x) :: Nil) |> List.map(t -> { let (h, n, _) = t; (h, n) }))

    /// 1 つの鍵の中で、材質の絵の名前の並びが違う物は別の候補（絵 a・b・a は a の 2 体・b の 1 体）。
    @Test
    def testTextureNamesSplitOneKey(): Unit \ {Assert, IO} =
        let x = triangle(1.0);
        Assert.assertEq(expected = 2 :: 1 :: Nil,
            groupedOrder(on(x, textured("a")) :: on(x, textured("b")) :: on(x, textured("a")) :: Nil) |> List.map(t -> { let (_, n, _) = t; n }))

    /// 同じ鍵（同じ材質）でも、形が違えば別の候補。
    @Test
    def testOtherShapeSplitsSameKey(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, List.length(groupedOrder(on(triangle(1.0), materialOf(0.1)) :: on(triangle(2.0), materialOf(0.1)) :: Nil)))

    /// numberSpan は上限で止まる（3 体の範囲を上限 4 で 2 回詰めると、2 回目は 1 体だけ）。
    @Test
    def testNumberSpanStopsAtCapacity(): Unit \ {Assert, IO} =
        let members: MutList[Render3d.MeshDraw, Static] = MutList.empty(Static);
        List.range(0, 3) |> List.forEach(_ -> MutList.push(drawOf(triangle(1.0)), members));
        let span = { head = drawOf(triangle(1.0)), start = 0, count = 3 };
        let out = FloatBuffer.allocate(32 * 4);
        let scratch = Array.repeat(Static, 32, 0.0f32);
        let next = Array#{0} @ Static;
        let first = numberSpan(out, scratch, 4, next, members, PackMode.Lit, span);
        let second = numberSpan(out, scratch, 4, next, members, PackMode.Lit, span);
        Assert.assertEq(expected = (0, 3, 3, 1, 4), (first#first, first#count, second#first, second#count, Array.get(0, next)))

    // ── GL の backend ──

    /// calls（新しい物が頭）の中で、name の最後の呼び出しが最初の drawElementsInstanced より前か。
    def isBeforeFirstDraw(name: String, log: Render3d.FakeGl.Recorded): Bool \ IO =
        let calls = List.reverse(Ref.get(log#calls)) |> List.mapWithIndex((i, c) -> (i, c));
        let last = calls |> List.filter(ic -> snd(ic) == name) |> List.map(fst) |> List.last;
        let firstDraw = calls |> List.find(ic -> snd(ic) == "drawElementsInstanced") |> Option.map(fst);
        Option.exists(v -> Option.exists(d -> v < d, firstDraw), last)

    /// 形は描く前に全部上がる（半透明の物の形も）。
    @Test
    def testMeshesUploadBeforeFirstDraw(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let skinned = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity()) |> Scene3d.withPose(poseAt(1.0));
        let glass = Scene3d.meshInstance(triangle(3.0), Mat4.identity()) |> Scene3d.withMaterial(materialOf(0.5) |> Scene3d.withAlphaBlend(true));
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(Scene3d.meshInstance(triangle(1.0), Mat4.identity()) :: placed(0.1) :: skinned :: glass :: Nil)) :: Nil);
        Assert.assertTrue(isBeforeFirstDraw("createVertexArray", log))

    def argbTexture(): Texture3d.Texture3d = match Texture3d.fromArgb(2, 2, Vector#{0, 0, 0, 0}) {
        case Ok(t)  => t
        case Err(e) => bug!(e)
    }

    /// 材質の絵は描く前に上がる（先に描く頂点の色の物の draw より前）。
    @Test
    def testTexturesUploadBeforeFirstDraw(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let t = argbTexture();
        let textured = Scene3d.meshInstance(triangle(1.0), Mat4.identity()) |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest));
        let plain = Scene3d.meshInstance(triangle(2.0), Mat4.identity());
        paint(recordingGl(log), freshState(), cmdOf({ textures = t :: Nil | sceneOf(textured :: plain :: Nil) }) :: Nil);
        Assert.assertTrue(isBeforeFirstDraw("texImageArgbLevel", log))

    /// instances を 1 回描いた偽の GL の (uInstanceBase を除く uniform1i の数, bindTexture の数)。
    def bindCounts(instances: List[Scene3d.Instance3d], textures: List[Texture3d.Texture3d]): (Int32, Int32) \ IO =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf({ textures = textures | sceneOf(instances) }) :: Nil);
        (timesCalled("uniform1i", log) - List.length(Ref.get(log#instanceBases)), timesCalled("bindTexture", log))

    def texturedOn(t: Texture3d.Texture3d, mesh: Mesh3d.Mesh3d): Scene3d.Instance3d =
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest))

    /// 同じ材質で形の違う 2 行目は、cutout の uniform も絵も付け直さない（1 行だけの時と同じ数）。
    @Test
    def testSecondSameMaterialRowDoesNotRebind(): Unit \ {Assert, IO} =
        let t = argbTexture();
        Assert.assertEq(expected = bindCounts(texturedOn(t, triangle(1.0)) :: Nil, t :: Nil),
            bindCounts(texturedOn(t, triangle(1.0)) :: texturedOn(t, triangle(2.0)) :: Nil, t :: Nil))

    /// 2 本目の uv を持つ三角形。
    def bakedTriangle(side: Float64): Mesh3d.Mesh3d = match Mesh3d.withUvs2(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }, triangle(side)) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    }

    /// lightmap の版の 2 行目は、同じ材質でも絵を付け直す（1 行だけの時より bindTexture が多い）。
    @Test
    def testSecondLightmappedRowRebinds(): Unit \ {Assert, IO} =
        let t = argbTexture();
        let baked = (side: Float64) -> texturedOn(t, bakedTriangle(side)) |> Scene3d.withLightmap(Scene3d.lightmap(Texture3d.name(t)));
        Assert.assertTrue(snd(bindCounts(baked(1.0) :: baked(2.0) :: Nil, t :: Nil)) > snd(bindCounts(baked(1.0) :: Nil, t :: Nil)))

    // ── pass ──

    /// 場面の Output から計画の pass を決め、pass ごとの行の列は 1 つ（色の場面は Color・Output.Depth の場面は同じ near と幅の DepthOut）。
    @Test
    def testScenePassFollowsOutput(): Unit \ {Assert, IO} =
        let depth = { output = Scene3d.Output.Depth({ near = 0.5, range = 12.0 }) | sceneOf(placed(0.1) :: Nil) };
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let (plans, _) = planScenes(planner, caps(false), Vector#{0}, groupScenes(planner, caps(false), 1, cmdOf(sceneOf(placed(0.1) :: Nil)) :: cmdOf(depth) :: Nil));
        let unnumbered = (b: SpanBatch) -> ({ head = b#head, count = 0, first = 0 }: MeshBatch);
        let describe = (spec: ScenePassSpec) -> match spec {
            case ScenePassSpec.Color        => "color"
            case ScenePassSpec.DepthOut(dr) => "depth ${dr#near} ${dr#range}"
        };
        let numbered = (p: Render3d.ScenePlan.ScenePlan[SpanBatch]) ->
            { cmd = p#cmd, mainPass = p#mainPass, draws = { plain = List.map(unnumbered, p#draws#plain), skinned = Nil, opaque = Nil, blended = Nil }, shadowPlans = Nil };
        let passes = plans |> List.map(p -> buildScenePasses(Render3d.MeshTable.fresh(), 1i64, numbered(p)) |> List.map(pl -> describe(fst(pl))));
        Assert.assertEq(expected = ("color" :: Nil) :: ("depth 0.5 12.0" :: Nil) :: Nil, passes)
}
