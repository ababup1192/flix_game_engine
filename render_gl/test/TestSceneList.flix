// 3D の不透明の batch の行（Render3d.SceneList）と、行を作るまでの計画（Render3d.ScenePlan）。計画は GL を呼ばずに決まり、backend の答えは値で渡す。
mod Render3d.TestSceneList {
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.Counts.{BatchBreak, breakSlotOf}
    use Render3d.FakeGl.{cmdOf, freshRecorded, freshState, paint, plainTriangle, poseAt, recordingGl, sceneOf}
    use Render3d.SceneList.{SceneList, buildSceneList, flagCoverage, flagDoubleSided, flagSameBinding, hasFlag, kindMaterial, kindSkinned, kindVertexColor, rowAt, rowCountOf}
    use Render3d.ScenePlan.{PlanCaps, freshPlanner, groupScenes, planScenes}

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
        buildSceneList({ plain = plain, skinned = skinned, opaque = opaque, blended = Nil })

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

    // ── 計画（GL を呼ばない）──

    def caps(alphaToOne: Bool): PlanCaps = { alphaToOne = alphaToOne, poseRowLimit = 4096 }

    def placed(red: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(materialOf(red))

    /// cmds を計画し、backend の答え answer（聞いた材質ごとの順の番号）で分けた最初の場面の材質の順の番号の並び。
    def plannedOrders(cmds: List[Scene3d.RenderCmd], answer: Vector[Int32]): List[Int32] \ IO =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let (grouped, _) = groupScenes(planner, caps(false), 1, cmds);
        let (plans, _) = planScenes(planner, caps(false), answer, grouped);
        plans |> List.head |> Option.map(p -> List.map(d -> d#order, p#draws#opaque)) |> Option.getWithDefault(Nil)

    /// 聞く材質は置いた物が来た順に並ぶ（材質ごとに 1 つ）。
    @Test
    def testRequestsFollowArrivalOrder(): Unit \ {Assert, IO} =
        let (_, requests) = groupScenes(freshPlanner(Render3d.DrawMode.Instanced), caps(false), 1, cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: placed(0.1) :: Nil)) :: Nil);
        Assert.assertEq(expected = "m0.1" :: "m0.9" :: Nil, requests |> Vector.toList |> List.map(r -> fst(r)#spec#name))

    /// 2 つ目の場面の材質は、1 つ目の場面の材質の後ろの番号で聞く。
    @Test
    def testSecondSceneAsksAfterFirst(): Unit \ {Assert, IO} =
        let cmds = cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: Nil)) :: cmdOf(sceneOf(placed(0.5) :: Nil)) :: Nil;
        let (grouped, _) = groupScenes(freshPlanner(Render3d.DrawMode.Instanced), caps(false), 1, cmds);
        Assert.assertEq(expected = 0 :: 2 :: Nil, List.map(s -> s#firstRequest, grouped))

    /// 材質の batch は backend の順の番号の小さい順に並ぶ。
    @Test
    def testMaterialsSortByBackendOrder(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 3 :: 9 :: Nil, plannedOrders(cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: Nil)) :: Nil, Vector#{9, 3}))

    /// backend が使えないと答えた（0）材質の物は、頂点の色の batch になる。
    @Test
    def testUnusableMaterialFallsToVertexColor(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let (grouped, _) = groupScenes(planner, caps(false), 1, cmdOf(sceneOf(placed(0.1) :: placed(0.9) :: Nil)) :: Nil);
        let (plans, _) = planScenes(planner, caps(false), Vector#{0, 7}, grouped);
        Assert.assertEq(expected = (1, 7 :: Nil), plans |> List.head |> Option.map(p -> (List.length(p#draws#plain), List.map(d -> d#order, p#draws#opaque))) |> Option.getWithDefault((0, Nil)))

    /// 標本つきの描き先で alpha to coverage を使える時だけ、cutout の材質を coverage の版で聞く。
    @Test
    def testCoverageNeedsSamplesAndCapability(): Unit \ {Assert, IO} =
        let cutout = Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(materialOf(0.1) |> Scene3d.withCutout(true));
        let asked = (alphaToOne: Bool, samples: Int32) -> {
            let (_, requests) = groupScenes(freshPlanner(Render3d.DrawMode.Instanced), caps(alphaToOne), samples, cmdOf(sceneOf(cutout :: Nil)) :: Nil);
            requests |> Vector.toList |> List.map(r -> snd(r)#coverage)
        };
        Assert.assertEq(expected = (true :: Nil, false :: Nil, false :: Nil), (asked(true, 4), asked(false, 4), asked(true, 1)))

    // ── GL の backend ──

    /// 形は描く前に全部上がる（最後の VAO を作った後に最初の draw が来る）。
    @Test
    def testMeshesUploadBeforeFirstDraw(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let skinned = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity()) |> Scene3d.withPose(poseAt(1.0));
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(Scene3d.meshInstance(triangle(1.0), Mat4.identity()) :: placed(0.1) :: skinned :: Nil)) :: Nil);
        let calls = List.reverse(Ref.get(log#calls));
        let lastVao = calls |> List.mapWithIndex((i, c) -> (i, c)) |> List.filter(ic -> snd(ic) == "createVertexArray") |> List.map(fst) |> List.last;
        let firstDraw = calls |> List.mapWithIndex((i, c) -> (i, c)) |> List.find(ic -> snd(ic) == "drawElementsInstanced") |> Option.map(fst);
        Assert.assertTrue(Option.exists(v -> Option.exists(d -> v < d, firstDraw), lastVao))
}
