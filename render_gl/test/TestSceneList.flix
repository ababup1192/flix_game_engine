// 3D の不透明の batch の行（Render3d.SceneList）と、行を作るまでの計画（Render3d.ScenePlan）。計画は GL を呼ばずに決まり、backend の答えは値で渡す。
mod Render3d.TestSceneList {
    import java.nio.FloatBuffer
    use Render3d.Batch.{MaterialBatch, MeshBatch, SpanBatch, batchKeyOf, groupByTextures, groupInOrder}
    use Render3d.Counts.{BatchBreak, breakSlotOf}
    use Render3d.InstanceValues.{PackMode, numberSpan}
    use Render3d.FakeGl.{cmdOf, freshRecorded, freshState, paint, plainTriangle, poseAt, recordingGl, sceneOf, timesCalled}
    use Render3d.SceneList.{SceneList, SceneRowKind, breakSlotAt, buildSceneList, buildScenePasses, countAt, firstInstanceAt, flagCoverage, flagDoubleSided, flagSameBinding, hasFlag, kindAt, materialHandleAt, materialOrderAt, readCountAt, rowCountOf, textureIdAt, valuesAt}
    use Render3d.ScenePlan.{PlanCaps, ScenePassSpec, freshPlanner, groupScenes, kindOf, meshDrawOf, planScenes}

    def triangle(side: Float64): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(side, 0.0, 0.0) :: Vec3.v3(0.0, side, 0.0) :: Nil, color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    def drawOf(mesh: Mesh3d.Mesh3d): Render3d.MeshDraw =
        { fields = Scene3d.instanceFieldsOf(Scene3d.meshInstance(mesh, Mat4.identity())), pose = None, poseRow = 0, culled = false }

    def batchOf(mesh: Mesh3d.Mesh3d, first: Int32, count: Int32): MeshBatch = { head = drawOf(mesh), count = count, first = first }

    def plainKind(): Render3d.ProgramKey.ProgramKind =
        { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false, variant = { pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = false } }

    /// 赤の量 red で木の違う、名前 name の材質。
    def materialOf(red: Float64): Scene3d.Material3d =
        Scene3d.material({ name = "m${red}", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = red, g = 0.5, b = 0.5 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    def fieldsOf(red: Float64): Scene3d.MaterialFields = Scene3d.materialFieldsOf(materialOf(red))

    def materialBatch(handle: Int32, order: Int32, red: Float64, b: MeshBatch): MaterialBatch[MeshBatch] =
        { handle = handle, order = order, kind = plainKind(), material = fieldsOf(red), batch = b }

    def listOf(plain: List[MeshBatch], skinned: List[MeshBatch], opaque: List[MaterialBatch[MeshBatch]]): SceneList \ IO =
        buildSceneList(Render3d.SceneList.contextOf(freshTables(), sceneOf(Nil)), { plain = plain, skinned = skinned, opaque = opaque, blended = Nil, billboards = Nil })

    def noRegistered(_name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO = checked_ecast(None)

    /// 空の表で行を作る材料（全体の登録の絵は無い）。
    def freshTables(): Render3d.SceneList.Tables \ IO =
        { meshes = Render3d.MeshTable.fresh(), textures = Render3d.TextureTable3d.fresh(), layouts = Render3d.MaterialValues.freshLayouts(), gen = 1i64,
          gpuMip = false, textureOf = noRegistered, flipsTargetV = false }

    def column(list: SceneList, at: (SceneList, Int32) -> Int32 \ IO): List[Int32] \ IO =
        List.range(0, rowCountOf(list)) |> List.map(row -> at(list, row))

    def kinds(list: SceneList): List[SceneRowKind] \ IO =
        List.range(0, rowCountOf(list)) |> List.map(row -> kindAt(list, row))

    // ── 行 ──

    /// 種類 → 欄 0 の番号 → 種類が全部の種類で元に戻る（番号の振り間違いで黙って別の種類にならない）。
    @Test
    def testRowKindCodeRoundTrips(): Unit \ Assert =
        let all = SceneRowKind.VertexColor :: SceneRowKind.Skinned :: SceneRowKind.Material :: SceneRowKind.Billboard :: Nil;
        Assert.assertEq(expected = all, all |> List.map(k -> Render3d.SceneList.kindOfCode(Render3d.SceneList.kindCodeOf(k))))

    /// 行は頂点の色・骨つき・材質の順に並ぶ。
    @Test
    def testRowsKeepVertexColorSkinnedMaterialOrder(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 0, 1) :: Nil, batchOf(triangle(2.0), 1, 1) :: Nil, materialBatch(0, 5, 0.1, batchOf(triangle(3.0), 2, 1)) :: Nil);
        Assert.assertEq(expected = SceneRowKind.VertexColor :: SceneRowKind.Skinned :: SceneRowKind.Material :: Nil, kinds(list))

    /// 材質の行は材質の表の番号と順の番号を持つ。
    @Test
    def testMaterialRowCarriesHandleAndOrder(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(4, 9, 0.1, batchOf(triangle(1.0), 0, 1)) :: Nil);
        Assert.assertEq(expected = (4, 9), (materialHandleAt(list, 0), materialOrderAt(list, 0)))

    /// 材質の行の値は 2 つの区画を 256 バイトずつそろえて並べ（物ごとの値 64 個・sg 64 個）、cutout を物ごとの値の頭に書く。描く物の無い材質の行と形の行は値を持たない。
    @Test
    def testMaterialRowValuesAreAlignedBlocks(): Unit \ {Assert, IO} =
        let cutout = (b: MeshBatch) -> { material = { cutout = true | fieldsOf(0.1) } | materialBatch(0, 3, 0.1, b) };
        let list = listOf(batchOf(triangle(4.0), 0, 1) :: Nil, Nil,
                          cutout(batchOf(triangle(1.0), 1, 1)) :: materialBatch(1, 4, 0.9, batchOf(triangle(2.0), 2, 0))
                          :: materialBatch(2, 5, 0.5, batchOf(triangle(3.0), 2, 1)) :: Nil);
        let at = (row: Int32) -> valuesAt(list, row);
        Assert.assertEq(expected = (-1, 0, -1, 128, 1.0f32, 0.0f32, 256), (at(0), at(1), at(2), at(3), Array.get(0, list#values), Array.get(128, list#values), Array.length(list#values)))

    /// 行は 1 体ごとの値の先頭と描く物の数を持つ。
    @Test
    def testRowCarriesFirstAndCount(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 7, 3) :: Nil, Nil, Nil);
        Assert.assertEq(expected = (7, 3), (firstInstanceAt(list, 0), countAt(list, 0)))

    /// 頂点の色の行は Mesh・骨つきの行は Skinned で分かれた理由を数える。
    @Test
    def testShapeRowsBreakByMeshAndSkinned(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 0, 1) :: Nil, batchOf(triangle(2.0), 1, 1) :: Nil, Nil);
        Assert.assertEq(expected = breakSlotOf(BatchBreak.Mesh) :: breakSlotOf(BatchBreak.Skinned) :: Nil, column(list, breakSlotAt))

    /// 同じ材質で形が違う行は Mesh・違う材質の行は Material で分かれる。
    @Test
    def testMaterialRowsBreakByMeshOrMaterial(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: materialBatch(1, 3, 0.1, batchOf(triangle(2.0), 1, 1))
                                    :: materialBatch(2, 4, 0.9, batchOf(triangle(2.0), 2, 1)) :: Nil);
        Assert.assertEq(expected = breakSlotOf(BatchBreak.Material) :: breakSlotOf(BatchBreak.Mesh) :: breakSlotOf(BatchBreak.Material) :: Nil, column(list, breakSlotAt))

    /// 描く物の無い材質の行は前の材質を替えない（その次の同じ材質の別の形は Mesh で分かれる）。
    @Test
    def testCulledMaterialRowKeepsPrevious(): Unit \ {Assert, IO} =
        let list = listOf(Nil, Nil, materialBatch(0, 3, 0.1, batchOf(triangle(1.0), 0, 1)) :: materialBatch(1, 4, 0.9, batchOf(triangle(2.0), 1, 0))
                                    :: materialBatch(2, 3, 0.1, batchOf(triangle(3.0), 1, 1)) :: Nil);
        Assert.assertEq(expected = breakSlotOf(BatchBreak.Mesh), breakSlotAt(list, 2))

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
            |> Option.map(m -> m#spec#name + ":" + (Scene3d.materialTexReadsOf(m) |> List.map(fst) |> List.join(",")))
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
        let surfaceOf = (d: Render3d.MeshDraw) -> d#fields#material |> Option.map(Scene3d.materialFieldsOf) |> Option.map(m -> (m, kindOf(false, Render3d.ProgramKey.defaultShaderVariant(), d, m)));
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

    /// 同じ材質の値と同じ形の値を何度も使う入力（分け方を使い回す道）でも、候補の並びは見本と同じ。
    /// 中身が同じで値の違う材質・材質の無い物・半透明（1 体ずつの候補）・間引いた物を混ぜる。
    @Test
    def testReusedValuesMatchTheReference(): Unit \ {Assert, IO} =
        let (x, y) = (triangle(1.0), triangle(2.0));
        let (red, blue) = (materialOf(0.1), materialOf(0.9));
        let glass = materialOf(0.5) |> Scene3d.withAlphaBlend(true);
        let plain = (mesh: Mesh3d.Mesh3d) -> Scene3d.meshInstance(mesh, Mat4.identity());
        let behind = Scene3d.meshInstance(x, Mat4.translate(Vec3.v3(0.0, 0.0, -50.0))) |> Scene3d.withMaterial(red);
        let instances = on(x, red) :: on(x, red) :: on(y, red) :: plain(x) :: on(x, blue) :: on(x, glass) :: on(x, red) :: behind :: on(x, materialOf(0.1))
            :: plain(x) :: on(x, glass) :: on(y, red) :: plain(y) :: on(x, blue) :: Nil;
        Assert.assertEq(expected = referenceOrder(instances), groupedOrder(instances))

    /// DrawMode.OneByOne では、同じ材質の値と同じ形の値の物も 1 体ずつの候補になる（使い回しで 1 つにまとめない）。
    @Test
    def testOneByOneKeepsReusedValuesApart(): Unit \ {Assert, IO} =
        let red = materialOf(0.1);
        let x = triangle(1.0);
        let scenes = groupScenes(freshPlanner(Render3d.DrawMode.OneByOne), caps(false), 1, cmdOf(sceneOf(on(x, red) :: on(x, red) :: Scene3d.meshInstance(x, Mat4.identity()) :: Scene3d.meshInstance(x, Mat4.identity()) :: Nil)) :: Nil)#scenes;
        Assert.assertEq(expected = 1 :: 1 :: 1 :: 1 :: Nil, scenes |> List.flatMap(s -> List.map(g -> g#batch#count, s#groups)))

    /// 詰めた 1 体の 32 個は、Mat4.toColumns（world）と Mat4.normalMatrix の列・tint の線形の値とビットで同じ（軸ごとに違う伸び・白と白でない tint）。
    @Test
    def testPackedValuesMatchMatrixColumns(): Unit \ {Assert, IO} =
        let world = Mat4.mul(Mat4.translate(Vec3.v3(1.5, -2.0, 3.25)), Mat4.mul(Mat4.rotateY(0.7), Mat4.mul(Mat4.rotateX(-0.3), Mat4.scale(Vec3.v3(0.5, 2.0, 1.25)))));
        let packed = (tint: Color) -> {
            let d = { fields = Scene3d.instanceFieldsOf(Scene3d.meshInstance(triangle(1.0), world) |> Scene3d.withTint(tint)), pose = None, poseRow = 0, culled = false };
            let out = FloatBuffer.allocate(32);
            let scratch = Array.repeat(Static, 32, 0.0f32);
            Render3d.InstanceValues.packDraw(out, scratch, PackMode.Lit, d);
            List.range(0, 32) |> List.map(i -> out.get(i))
        };
        let f = RenderUtil.f32;
        let normal = Mat4.toColumns(Mat4.normalMatrix(world));
        let expectedFor = (tint: Color) -> {
            let lin = Texture3d.srgbToLinearColor(tint);
            let cols = Mat4.toColumns(world) |> Vector.toList |> List.map(f);
            let n = List.range(0, 12) |> List.map(i -> if (i == 3) 1.0f32 else if (i == 7) 0.0f32 else f(Vector.get(i, normal)));
            cols ::: n ::: (f(lin#r) :: f(lin#g) :: f(lin#b) :: 0.0f32 :: Nil)
        };
        let white = Color.rgb(1.0, 1.0, 1.0);
        let warm = Color.rgb(0.8, 0.4, 0.2);
        Assert.assertEq(expected = (expectedFor(white), expectedFor(warm)), (packed(white), packed(warm)))

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

    /// lightmap の版の行は、物ごとの値に段の数（maxLevels で切る）・色空間（sRGB は 1）・強さを書き、絵の組の末尾に lightmap を Clamp と Linear で足し、lightmap のフラグを立てる。
    @Test
    def testLightmapRowWritesValuesAndRead(): Unit \ {Assert, IO} =
        let t = argbTexture();
        let lm = { intensity = 2.0, maxLevels = 1 | Scene3d.lightmap(Texture3d.name(t)) };
        let material = Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest);
        let placed = Scene3d.meshInstance(bakedTriangle(1.0), Mat4.identity()) |> Scene3d.withMaterial(material) |> Scene3d.withLightmap(lm);
        let head = { fields = Scene3d.instanceFieldsOf(placed), pose = None, poseRow = 0, culled = false };
        let d = { handle = 0, order = 3, kind = { lightmap = true | plainKind() }, material = Scene3d.materialFieldsOf(material), batch = { head = head, count = 1, first = 0 } };
        let list = buildSceneList(Render3d.SceneList.contextOf(freshTables(), { textures = t :: Nil | sceneOf(Nil) }),
                                  { plain = Nil, skinned = Nil, opaque = d :: Nil, blended = Nil, billboards = Nil });
        let v = (i: Int32) -> Array.get(i, list#values);
        let last = readCountAt(list, 0) - 1;
        Assert.assertEq(expected = (1.0f32, 1.0f32, 2.0f32, 2, true, 1, 1, true),
                        (v(3), v(4), v(5), readCountAt(list, 0), hasFlag(list, 0, Render3d.SceneList.flagLightmap()),
                         Render3d.SceneList.readAt(list, 0, last, 1), Render3d.SceneList.readAt(list, 0, last, 2), Render3d.SceneList.readAt(list, 0, last, 0) >= 0))

    /// 法線マップと lightmap の両方を持つ行の絵の組は 材質の絵 → 法線マップ（材質の読み方 Repeat）→ lightmap（Clamp）の順で、線形の lightmap は色空間の欄が 0。
    @Test
    def testNormalMapThenLightmapReads(): Unit \ {Assert, IO} =
        let t = argbTexture();
        let lm = { colorSpace = Texture3d.ColorSpace.Linear | Scene3d.lightmap(Texture3d.name(t)) };
        let material = Scene3d.texturedMaterial(Texture3d.name(t), ShaderDoc.FilterMode.Nearest) |> Scene3d.withNormalMap({ texture = Texture3d.name(t), strength = 1.0 });
        let placed = Scene3d.meshInstance(bakedTriangle(1.0), Mat4.identity()) |> Scene3d.withMaterial(material) |> Scene3d.withLightmap(lm);
        let head = { fields = Scene3d.instanceFieldsOf(placed), pose = None, poseRow = 0, culled = false };
        let d = { handle = 0, order = 3, kind = { lightmap = true, normalMap = true, uv = true | plainKind() }, material = Scene3d.materialFieldsOf(material),
                  batch = { head = head, count = 1, first = 0 } };
        let list = buildSceneList(Render3d.SceneList.contextOf(freshTables(), { textures = t :: Nil | sceneOf(Nil) }),
                                  { plain = Nil, skinned = Nil, opaque = d :: Nil, blended = Nil, billboards = Nil });
        let wrapAt = (k: Int32) -> Render3d.SceneList.readAt(list, 0, k, 2);
        Assert.assertEq(expected = (3, 0, 0, 1, 0.0f32), (readCountAt(list, 0), wrapAt(0), wrapAt(1), wrapAt(2), Array.get(4, list#values)))

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
            { cmd = p#cmd, mainPass = p#mainPass, draws = { plain = List.map(unnumbered, p#draws#plain), skinned = Nil, opaque = Nil, blended = Nil, billboards = Nil }, shadowPlans = Nil, multis = Nil };
        let passes = plans |> List.map(p -> buildScenePasses(Render3d.SceneList.contextOf(freshTables(), p#cmd#scene), numbered(p)) |> List.map(pl -> describe(fst(pl))));
        Assert.assertEq(expected = ("color" :: Nil) :: ("depth 0.5 12.0" :: Nil) :: Nil, passes)

    // ── 半透明 ──

    def blendedBatch(handle: Int32, order: Int32, red: Float64, b: MeshBatch): MaterialBatch[MeshBatch] =
        { kind = { blend = true | plainKind() }, material = Scene3d.materialFieldsOf(materialOf(red) |> Scene3d.withAlphaBlend(true)) | materialBatch(handle, order, red, b) }

    def listWithBlended(plain: List[MeshBatch], opaque: List[MaterialBatch[MeshBatch]], blended: List[MaterialBatch[MeshBatch]]): SceneList \ IO =
        buildSceneList(Render3d.SceneList.contextOf(freshTables(), sceneOf(Nil)), { plain = plain, skinned = Nil, opaque = opaque, blended = blended, billboards = Nil })

    /// 半透明の行は不透明の行の後ろに来た順のまま並び、firstBlendedRowOf はその頭の行を指す。
    @Test
    def testBlendedRowsFollowOpaqueRows(): Unit \ {Assert, IO} =
        let list = listWithBlended(batchOf(triangle(1.0), 0, 1) :: Nil, materialBatch(0, 5, 0.1, batchOf(triangle(2.0), 1, 1)) :: Nil,
                                   blendedBatch(1, 6, 0.2, batchOf(triangle(3.0), 2, 1)) :: blendedBatch(2, 7, 0.3, batchOf(triangle(4.0), 3, 1)) :: Nil);
        Assert.assertEq(expected = (2, 4, 2 :: 3 :: Nil), (Render3d.SceneList.firstBlendedRowOf(list), rowCountOf(list), column(list, firstInstanceAt) |> List.drop(2)))

    /// 半透明の行が無ければ firstBlendedRowOf は行の数と同じ。
    @Test
    def testNoBlendedRowsPointsAtEnd(): Unit \ {Assert, IO} =
        let list = listOf(batchOf(triangle(1.0), 0, 1) :: Nil, Nil, materialBatch(0, 5, 0.1, batchOf(triangle(2.0), 1, 1)) :: Nil);
        Assert.assertEq(expected = rowCountOf(list), Render3d.SceneList.firstBlendedRowOf(list))

    /// 半透明の頭の行は、前の不透明の行と同じ材質でも付け直す。半透明の行どうしは同じ材質なら付け直さない。
    @Test
    def testFirstBlendedRowRebinds(): Unit \ {Assert, IO} =
        let list = listWithBlended(Nil, materialBatch(0, 5, 0.1, batchOf(triangle(1.0), 0, 1)) :: Nil,
                                   blendedBatch(0, 5, 0.1, batchOf(triangle(1.0), 1, 1)) :: blendedBatch(0, 5, 0.1, batchOf(triangle(1.0), 2, 1)) :: Nil);
        Assert.assertEq(expected = (false, true), (hasFlag(list, 1, flagSameBinding()), hasFlag(list, 2, flagSameBinding())))

    /// 半透明の行も材質の値を持ち、分かれた理由は半透明。
    @Test
    def testBlendedRowHasValuesAndTransparentBreak(): Unit \ {Assert, IO} =
        let list = listWithBlended(Nil, Nil, blendedBatch(0, 5, 0.1, batchOf(triangle(1.0), 0, 1)) :: Nil);
        Assert.assertEq(expected = (true, breakSlotOf(BatchBreak.Transparent)), (Render3d.SceneList.valuesAt(list, 0) >= 0, breakSlotAt(list, 0)))

    def glassAt(red: Float64, z: Float64): Scene3d.Instance3d =
        Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(0.0, 0.0, z))) |> Scene3d.withMaterial(materialOf(red) |> Scene3d.withAlphaBlend(true))

    /// 計画は半透明の材質の batch を目から遠い順に並べる（目は z = −5 で、z = 20・8・1 の順）。
    @Test
    def testPlanSortsBlendedFarToNear(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let cmds = cmdOf(sceneOf(glassAt(0.1, 1.0) :: glassAt(0.2, 20.0) :: glassAt(0.3, 8.0) :: Nil)) :: Nil;
        let (plans, _) = planScenes(planner, caps(false), Vector#{1, 2, 3}, groupScenes(planner, caps(false), 1, cmds));
        Assert.assertEq(expected = ("m0.2" :: "m0.3" :: "m0.1" :: Nil) :: Nil, plans |> List.map(p -> List.map(d -> d#material#spec#name, p#draws#blended)))

    /// 骨つきの半透明の物の姿勢の行は遠い物から振る（遠い z = 20 の物が近い z = 1 の物より小さい行）。
    @Test
    def testPlanGivesPoseRowsFarToNear(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let skinnedGlass = (red: Float64, z: Float64) -> Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.translate(Vec3.v3(0.0, 0.0, z)))
            |> Scene3d.withPose(poseAt(red)) |> Scene3d.withMaterial(materialOf(red) |> Scene3d.withAlphaBlend(true));
        let g = groupScenes(planner, caps(false), 1, cmdOf(sceneOf(skinnedGlass(0.1, 1.0) :: skinnedGlass(0.2, 20.0) :: Nil)) :: Nil);
        let (plans, _) = planScenes(planner, caps(false), Vector#{1, 2}, g);
        let rows = plans |> List.flatMap(p -> p#draws#blended) |> List.map(d -> MutList.get(d#batch#start, g#members)#poseRow);
        Assert.assertEq(expected = true, List.length(rows) == 2 and List.head(rows) < List.last(rows))

    // ── ビルボード ──

    /// 幅 32・高さ 16 の全体の登録の絵（番号 7・flipped = レンダーターゲット）。
    def registered(flipped: Bool): Scene3dRenderer.RegisteredTexture = { texId = 7, width = 32.0, height = 16.0, flipped = flipped, version = "" }

    def tablesWith(texture: Option[Scene3dRenderer.RegisteredTexture]): Render3d.SceneList.Tables \ IO =
        { textureOf = name -> checked_ecast(if (name == "sprite") texture else None) | freshTables() }

    /// 絵 "sprite" の (8, 4) から 16 × 8 を貼る、z = 5 に立てたビルボード（anchor 足元の真ん中・size 2 × 3・tint 白・光を当てる）。
    def billboardDraw(culled: Bool): Render3d.ScenePlan.BillboardDraw =
        let b = Scene3d.billboard("sprite", { position = { x = 8.0, y = 4.0 }, size = { x = 16.0, y = 8.0 } }, Vec3.v3(1.0, 2.0, 5.0), { x = 2.0, y = 3.0 });
        { fields = Scene3d.billboardFieldsOf(b), culled = culled }

    def listWithBillboards(texture: Option[Scene3dRenderer.RegisteredTexture], billboards: List[Render3d.ScenePlan.BillboardDraw]): SceneList \ IO =
        buildSceneList(Render3d.SceneList.contextOf(tablesWith(texture), sceneOf(Nil)),
                       { plain = batchOf(triangle(1.0), 0, 1) :: Nil, skinned = Nil, opaque = materialBatch(0, 5, 0.1, batchOf(triangle(2.0), 1, 1)) :: Nil,
                         blended = blendedBatch(1, 6, 0.2, batchOf(triangle(3.0), 2, 1)) :: Nil, billboards = billboards })

    /// ビルボードの行は不透明の行の後・半透明の行の前に来た順で並び、firstBillboardRowOf と firstBlendedRowOf がその前後を指す。
    @Test
    def testBillboardRowsSitBetweenOpaqueAndBlended(): Unit \ {Assert, IO} =
        let list = listWithTwoTextures(billboardDraw(false) :: boardDraw("other", 6.0, false) :: Nil);
        let bb = SceneRowKind.Billboard;
        Assert.assertEq(expected = (SceneRowKind.VertexColor :: SceneRowKind.Material :: bb :: bb :: SceneRowKind.Material :: Nil, 2, 4),
                        (kinds(list), Render3d.SceneList.firstBillboardRowOf(list), Render3d.SceneList.firstBlendedRowOf(list)))

    /// 絵 "sprite"（番号 7）と "other"（番号 9）を引ける表。
    def tablesWithTwo(): Render3d.SceneList.Tables \ IO =
        let other = { texId = 9 | registered(false) };
        { textureOf = name -> checked_ecast(if (name == "sprite") Some(registered(false)) else if (name == "other") Some(other) else None) | freshTables() }

    /// 絵 texture を z に立てたビルボード（ほかは billboardDraw と同じ）。
    def boardDraw(texture: String, z: Float64, culled: Bool): Render3d.ScenePlan.BillboardDraw =
        let b = billboardDraw(culled);
        { fields = { texture = texture, position = Vec3.v3(1.0, 2.0, z) | b#fields } | b }

    def listWithTwoTextures(billboards: List[Render3d.ScenePlan.BillboardDraw]): SceneList \ IO =
        buildSceneList(Render3d.SceneList.contextOf(tablesWithTwo(), sceneOf(Nil)),
                       { plain = batchOf(triangle(1.0), 0, 1) :: Nil, skinned = Nil, opaque = materialBatch(0, 5, 0.1, batchOf(triangle(2.0), 1, 1)) :: Nil,
                         blended = blendedBatch(1, 6, 0.2, batchOf(triangle(3.0), 2, 1)) :: Nil, billboards = billboards })

    /// ビルボードの行の (絵の番号, 板の数) の並び。
    def billboardRunsIn(list: SceneList): List[(Int32, Int32)] \ IO =
        List.range(Render3d.SceneList.firstBillboardRowOf(list), Render3d.SceneList.firstBlendedRowOf(list)) |> List.map(row -> (textureIdAt(list, row), countAt(list, row)))

    /// 来た順で続く同じ絵の板は 1 つの行（板の数 = 並びの長さ）になり、絵が替わると行が分かれる（来た順は崩さない）。
    @Test
    def testSameTextureBillboardsShareOneRow(): Unit \ {Assert, IO} =
        let list = listWithTwoTextures(boardDraw("sprite", 5.0, false) :: boardDraw("sprite", 6.0, false) :: boardDraw("other", 7.0, false) :: boardDraw("sprite", 8.0, false) :: Nil);
        Assert.assertEq(expected = (7, 2) :: (9, 1) :: (7, 1) :: Nil, billboardRunsIn(list))

    /// 絵 A・A・B・A の板は 3 行で、行の絵は A・B・A（診断の billboardRuns 3・billboardImages 2 の元）。
    @Test
    def testBillboardTexturesListOneEntryPerRow(): Unit \ {Assert, IO} =
        let list = listWithTwoTextures(boardDraw("sprite", 5.0, false) :: boardDraw("sprite", 6.0, false) :: boardDraw("other", 7.0, false) :: boardDraw("sprite", 8.0, false) :: Nil);
        Assert.assertEq(expected = 7 :: 9 :: 7 :: Nil, Render3d.SceneList.billboardTexturesOf(list))

    /// 視錐台の外の板は行を作らず、前後の同じ絵の板はその外の板をまたいで 1 つの行になる。
    @Test
    def testCulledBillboardDoesNotSplitRow(): Unit \ {Assert, IO} =
        let list = listWithTwoTextures(boardDraw("sprite", 5.0, false) :: boardDraw("other", 6.0, true) :: boardDraw("sprite", 7.0, false) :: Nil);
        Assert.assertEq(expected = (7, 2) :: Nil, billboardRunsIn(list))

    /// 並びの板の値は頭の行の値の位置から 1 枚ずつ続く（2 枚目の立てる点の z は頭 + billboardValueFloats の 3 番目）。
    @Test
    def testRowValuesFollowOneAnother(): Unit \ {Assert, IO} =
        let list = listWithTwoTextures(boardDraw("sprite", 5.0, false) :: boardDraw("sprite", 6.0, false) :: Nil);
        let at = Render3d.SceneList.valuesAt(list, 2);
        Assert.assertEq(expected = (5.0f32, 6.0f32), (Array.get(at + 2, list#values), Array.get(at + Render3d.SceneList.billboardValueFloats() + 2, list#values)))

    /// 描くビルボードの行は絵の番号・描く物 1・分かれた理由 Billboard を持ち、値は 立てる点と lit・anchor と size・絵の大きさで割った uv・線形の tint の並び。
    @Test
    def testBillboardRowWritesValues(): Unit \ {Assert, IO} =
        let list = listWithBillboards(Some(registered(false)), billboardDraw(false) :: Nil);
        let at = Render3d.SceneList.valuesAt(list, 2);
        let values = List.range(0, Render3d.SceneList.billboardValueFloats()) |> List.map(i -> Array.get(at + i, list#values));
        Assert.assertEq(expected = (7, 1, breakSlotOf(BatchBreak.Billboard),
                                    1.0f32 :: 2.0f32 :: 5.0f32 :: 1.0f32 :: 0.5f32 :: 1.0f32 :: 2.0f32 :: 3.0f32 ::
                                    0.25f32 :: 0.25f32 :: 0.5f32 :: 0.5f32 :: 1.0f32 :: 1.0f32 :: 1.0f32 :: 0.0f32 :: Nil),
                        (textureIdAt(list, 2), countAt(list, 2), breakSlotAt(list, 2), values))

    /// レンダーターゲット（flipped）の絵でも、v を返さない backend（flipsTargetV 偽・WebGPU）の値の uv は上の行から数える。
    @Test
    def testBillboardUvIsTopDownForTargets(): Unit \ {Assert, IO} =
        let list = listWithBillboards(Some(registered(true)), billboardDraw(false) :: Nil);
        let at = Render3d.SceneList.valuesAt(list, 2);
        Assert.assertEq(expected = (0.25f32, 0.5f32), (Array.get(at + 9, list#values), Array.get(at + 11, list#values)))

    /// v を返す backend（flipsTargetV 真・GL）では、レンダーターゲットの絵の v は 1 − v0・幅は 0 − dv。
    @Test
    def testBillboardUvFlipsForTargetsWhenAsked(): Unit \ {Assert, IO} =
        let tables = { flipsTargetV = true | tablesWith(Some(registered(true))) };
        let list = buildSceneList(Render3d.SceneList.contextOf(tables, sceneOf(Nil)),
                                  { plain = Nil, skinned = Nil, opaque = Nil, blended = Nil, billboards = billboardDraw(false) :: Nil });
        let at = Render3d.SceneList.valuesAt(list, 0);
        Assert.assertEq(expected = (0.75f32, -0.5f32), (Array.get(at + 9, list#values), Array.get(at + 11, list#values)))

    /// v を返す backend でも、レンダーターゲットでない絵の v は返さない。
    @Test
    def testBillboardUvKeepsPlainTextures(): Unit \ {Assert, IO} =
        let tables = { flipsTargetV = true | tablesWith(Some(registered(false))) };
        let list = buildSceneList(Render3d.SceneList.contextOf(tables, sceneOf(Nil)),
                                  { plain = Nil, skinned = Nil, opaque = Nil, blended = Nil, billboards = billboardDraw(false) :: Nil });
        let at = Render3d.SceneList.valuesAt(list, 0);
        Assert.assertEq(expected = (0.25f32, 0.5f32), (Array.get(at + 9, list#values), Array.get(at + 11, list#values)))

    /// ビルボードの値は材質の値の後ろに置く（材質の区画のそろえを崩さない）。
    @Test
    def testBillboardValuesFollowMaterialValues(): Unit \ {Assert, IO} =
        let list = listWithBillboards(Some(registered(false)), billboardDraw(false) :: Nil);
        Assert.assertEq(expected = true, Render3d.SceneList.valuesAt(list, 2) > Render3d.SceneList.valuesAt(list, 3))

    /// 視錐台の外の、絵のあるビルボードは行を作らない（firstBillboardRowOf と firstBlendedRowOf が同じ）。
    @Test
    def testCulledBillboardMakesNoRow(): Unit \ {Assert, IO} =
        let list = listWithBillboards(Some(registered(false)), billboardDraw(true) :: Nil);
        Assert.assertEq(expected = (2, 2), (Render3d.SceneList.firstBillboardRowOf(list), Render3d.SceneList.firstBlendedRowOf(list)))

    /// 絵が見つからないビルボードの行は絵の番号 -1・板の数 0・値なしで、名前を missingBillboardTexturesOf が返す。
    @Test
    def testMissingBillboardTextureIsListed(): Unit \ {Assert, IO} =
        let list = listWithBillboards(None, billboardDraw(false) :: Nil);
        Assert.assertEq(expected = (-1, 0, -1, "sprite" :: Nil),
                        (textureIdAt(list, 2), countAt(list, 2), Render3d.SceneList.valuesAt(list, 2), Render3d.SceneList.missingBillboardTexturesOf(list)))

    /// 絵が見つからない板は視錐台の外でも行に残る（知らせが外の板の分も出る）。
    @Test
    def testMissingCulledBillboardStillListed(): Unit \ {Assert, IO} =
        let list = listWithBillboards(None, billboardDraw(true) :: Nil);
        Assert.assertEq(expected = "sprite" :: Nil, Render3d.SceneList.missingBillboardTexturesOf(list))

    /// ビルボードの行は材質を持たず、後ろの半透明の行の材質は引ける。
    @Test
    def testBillboardRowHasNoMaterial(): Unit \ {Assert, IO} =
        let list = listWithBillboards(Some(registered(false)), billboardDraw(false) :: Nil);
        Assert.assertEq(expected = (true, true), (Option.isEmpty(Render3d.SceneList.materialAt(list, 2)), Option.nonEmpty(Render3d.SceneList.materialAt(list, 3))))

    /// 太陽の影を受けるビルボードの値は、光の当て方が 2 で、末尾に影を受ける点を進める長さ（板の幅の半分）を持つ。
    @Test
    def testReceivingBillboardWritesLeadValue(): Unit \ {Assert, IO} =
        let d = billboardDraw(false);
        let receiving = { fields = { receiveShadows = true | d#fields } | d };
        let list = listWithBillboards(Some(registered(false)), receiving :: Nil);
        let at = Render3d.SceneList.valuesAt(list, 2);
        Assert.assertEq(expected = (2.0f32, 1.0f32), (Array.get(at + 3, list#values), Array.get(at + 15, list#values)))

    /// 影の地図の行は形の行の後に、地図に描くビルボードの行（分かれた理由は影の pass・値あり）を並べる。
    @Test
    def testShadowListPutsBillboardRowsAfterShapes(): Unit \ {Assert, IO} =
        let ctx = Render3d.SceneList.contextOf(tablesWith(Some(registered(false))), sceneOf(Nil));
        let list = Render3d.SceneList.buildShadowList(ctx, batchOf(triangle(1.0), 0, 1) :: Nil, Nil, (billboardDraw(false)#fields, None) :: Nil);
        Assert.assertEq(expected = (SceneRowKind.VertexColor :: SceneRowKind.Billboard :: Nil, 1, breakSlotOf(BatchBreak.ShadowPass), 0),
                        (kinds(list), Render3d.SceneList.firstBillboardRowOf(list), breakSlotAt(list, 1), Render3d.SceneList.valuesAt(list, 1)))

    /// 影の地図の板は絵の名前で並べ替えてからまとめる（来た順で絵が交互でも、絵ごとに 1 行）。
    @Test
    def testShadowListGroupsBillboardsByTexture(): Unit \ {Assert, IO} =
        let ctx = Render3d.SceneList.contextOf(tablesWithTwo(), sceneOf(Nil));
        let boards = ("sprite" :: "other" :: "sprite" :: "other" :: Nil) |> List.map(t -> (boardDraw(t, 5.0, false)#fields, None));
        let list = Render3d.SceneList.buildShadowList(ctx, Nil, Nil, boards);
        Assert.assertEq(expected = (9, 2) :: (7, 2) :: Nil, billboardRunsIn(list))

    /// 点光源の面の板ごとの横の向きは、並べ替えた後も同じ板の値の tint の欄（12〜14）に入る。
    @Test
    def testShadowListKeepsRightWithItsBoard(): Unit \ {Assert, IO} =
        let ctx = Render3d.SceneList.contextOf(tablesWithTwo(), sceneOf(Nil));
        let boards = (boardDraw("sprite", 5.0, false)#fields, Some(Vec3.v3(1.0, 0.0, 0.0))) :: (boardDraw("other", 6.0, false)#fields, Some(Vec3.v3(0.0, 0.0, 1.0))) :: Nil;
        let list = Render3d.SceneList.buildShadowList(ctx, Nil, Nil, boards);
        let at = Render3d.SceneList.valuesAt(list, 0);
        Assert.assertEq(expected = (6.0f32, 0.0f32, 1.0f32), (Array.get(at + 2, list#values), Array.get(at + 12, list#values), Array.get(at + 14, list#values)))

    /// 計画はビルボードを来た順のまま並べ、視錐台の外の物（目の後ろ）に culled を立てる（目は z = −5 で +z を向く）。
    @Test
    def testPlanMarksBillboardsOutsideFrustum(): Unit \ {Assert, IO} =
        let at = (z: Float64) -> Scene3d.billboard("sprite", { position = { x = 0.0, y = 0.0 }, size = { x = 1.0, y = 1.0 } }, Vec3.v3(0.0, 0.0, z), { x = 1.0, y = 1.0 });
        let scene = { billboards = at(5.0) :: at(-50.0) :: at(10.0) :: Nil | sceneOf(Nil) };
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let (plans, _) = planScenes(planner, caps(false), Vector.empty(), groupScenes(planner, caps(false), 1, cmdOf(scene) :: Nil));
        Assert.assertEq(expected = (5.0, false) :: (-50.0, true) :: (10.0, false) :: Nil,
                        plans |> List.flatMap(p -> p#draws#billboards) |> List.map(b -> (b#fields#position#z, b#culled)))
}
