// 1 体ごとの値（Render3d.Instancing）を、場面の準備から draw まで通した試験。GL は呼び出しを控える偽物。
mod Render3d.TestInstancing {
    use Render3d.FakeGl.{Recorded, cmdOf, dest, freshOneByOne, freshRecorded, freshState, noTexture, paint, plainTriangle, poseAt, recordingGl, sceneOf, skinnedAt, stderrOf, timesCalled, viewport}

    def solidMaterial(): Scene3d.Material3d =
        Scene3d.material({ name = "solid", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.5, g = 0.5, b = 0.5 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    /// 控えた最後の 1 体ごとの値の i 個目。
    def instanceFloat(log: Recorded, i: Int32): Option[Float32] \ IO =
        List.head(Ref.get(log#instanceData)) |> Option.flatMap(floats -> List.head(List.drop(i, floats)))

    /// 違う姿勢の 2 体は、1 体ごとの値にそれぞれの行が入る（1 体 32 個の 24 個目）。
    @Test
    def testEachDrawPointsAtItsPoseRow(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(skinnedAt(poseAt(1.0)) :: skinnedAt(poseAt(2.0)) :: Nil)) :: Nil);
        Assert.assertEq(expected = (Some(0.0f32), Some(1.0f32)), (instanceFloat(log, 23), instanceFloat(log, 55)))

    /// 同じ形の 12 体は instance 数 12 の draw が 1 本で、番号は 0 から。
    @Test
    def testCrowdIsOneInstancedDraw(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(List.range(0, 12) |> List.map(i -> skinnedAt(poseAt(Int32.toFloat64(i)))))) :: Nil);
        Assert.assertEq(expected = (12 :: Nil, 0 :: Nil), (Ref.get(log#instanceCounts), Ref.get(log#instanceBases)))

    /// emissionIntensity だけが違う 2 体は 1 本の draw で、それぞれの値が 1 体ごとの値に入る。
    @Test
    def testEmissionIntensityGoesPerInstanceInOneDraw(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let lit = (k: Float64) -> Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(solidMaterial() |> Scene3d.withEmissionIntensity(k));
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(lit(2.0) :: lit(6.0) :: Nil)) :: Nil);
        Assert.assertEq(expected = (2 :: Nil, Some(2.0f32), Some(6.0f32)), (Ref.get(log#instanceCounts), instanceFloat(log, 19), instanceFloat(log, 51)))

    /// FGE_INSTANCING=off の描き方は同じ形の物も 1 体ずつの draw で、番号は来た順。数える draw も体の数。
    @Test
    def testOneByOneDrawsEachInstanceAlone(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let state = freshOneByOne();
        paint(recordingGl(log), state, cmdOf(sceneOf(List.range(0, 3) |> List.map(i -> skinnedAt(poseAt(Int32.toFloat64(i)))))) :: Nil);
        Assert.assertEq(expected = (1 :: 1 :: 1 :: Nil, 2 :: 1 :: 0 :: Nil, 3),
            (Ref.get(log#instanceCounts), Ref.get(log#instanceBases), Render3d.Counts.takeCounts(state)#drawCalls))

    /// on と off は同じ物を同じ順で描く時、同じ 1 体ごとの値を上げる。
    @Test
    def testOneByOneUploadsSameValuesForOneShape(): Unit \ {Assert, IO} =
        let crowd = () -> sceneOf(List.range(0, 3) |> List.map(i -> skinnedAt(poseAt(Int32.toFloat64(i)))));
        let singly = freshRecorded();
        paint(recordingGl(singly), freshOneByOne(), cmdOf(crowd()) :: Nil);
        let instanced = freshRecorded();
        paint(recordingGl(instanced), freshState(), cmdOf(crowd()) :: Nil);
        Assert.assertTrue(Ref.get(singly#instanceData) == Ref.get(instanced#instanceData))

    /// prepare A → prepare B → A の draw の順でも、A の draw は A の 1 体ごとの値のテクスチャを貼ってから描く。B の送りは A のテクスチャへ書かない。
    @Test
    def testLaterPrepareKeepsEarlierInstanceValues(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let first = Render3d.prepareNumbered(gl, state, 1i64, noTexture, dest(), cmdOf(sceneOf(skinnedAt(poseAt(1.0)) :: Nil)) :: Nil);
        discard Render3d.prepareNumbered(gl, state, 1i64, noTexture, dest(), cmdOf(sceneOf(skinnedAt(poseAt(2.0)) :: Nil)) :: Nil);
        first#draw(viewport(), 0);
        let binds = Ref.get(log#instanceBinds);
        Assert.assertEq(expected = (true, true, 2), (List.head(binds) == List.last(binds), List.nth(1, binds) != List.head(binds), Map.size(Ref.get(state#instances#texturesRef))))

    /// 視錐台の外の形だけの batch は、draw を出さないが形を今のコマで使った物として数える。
    @Test
    def testCulledBatchKeepsMeshInUse(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let behind = Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(0.0, 0.0, -50.0)));
        let draw = (gen: Int64) -> {
            let prepared = Render3d.prepareNumbered(gl, state, gen, noTexture, dest(), cmdOf(sceneOf(behind :: Nil)) :: Nil);
            prepared#draw(viewport(), 0)
        };
        draw(1i64);
        draw(7i64);
        let used = Ref.get(state#meshesRef) |> Map.valuesOf |> List.map(e -> Array.get(0, e#lastUsed));
        Assert.assertEq(expected = (Nil, 7i64 :: Nil), (Ref.get(log#instanceCounts), used))

    /// 真ん中の物だけ間引いた batch は 2 体の draw で、番号は 0 から、値は描く物の world が並ぶ（平行移動の x が 12 個目と 44 個目）。
    @Test
    def testPartlyCulledBatchPacksVisibleDraws(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let at = (x: Float64, z: Float64) -> Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(x, 0.0, z)));
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(at(0.5, 0.0) :: at(0.0, -50.0) :: at(1.5, 0.0) :: Nil)) :: Nil);
        Assert.assertEq(expected = (2 :: Nil, 0 :: Nil, Some(0.5f32), Some(1.5f32)),
            (Ref.get(log#instanceCounts), Ref.get(log#instanceBases), instanceFloat(log, 12), instanceFloat(log, 44)))

    /// テクスチャに入り切らない物は描かず、1 回知らせる（高さの上限 1 行 = 32 体に 40 体）。
    @Test
    def testUploadPastCapacityDropsTheRest(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        Ref.put(1, log#textureLimit);
        let crowd = sceneOf(List.range(0, 40) |> List.map(_ -> Scene3d.meshInstance(plainTriangle(), Mat4.identity())));
        let warned = stderrOf(() -> paint(recordingGl(log), freshState(), cmdOf(crowd) :: Nil));
        Assert.assertEq(expected = (32 :: Nil, true), (Ref.get(log#instanceCounts), String.contains(substr = "入り切らない物を描かない", warned)))

    /// count 体を x = 番号の所に並べて描いた偽の GL の控え。
    def paintedRow(count: Int32): Recorded \ IO =
        let log = freshRecorded();
        let row = List.range(0, count) |> List.map(i -> Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(Int32.toFloat64(i) * 0.01, 0.0, 0.0))));
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(row)) :: Nil);
        log

    /// 1 行に収まる物は使う幅だけ上げる（3 体 = 24 texel・96 個）。
    @Test
    def testOneRowUploadsUsedWidth(): Unit \ {Assert, IO} =
        let log = paintedRow(3);
        Assert.assertEq(expected = (24 :: Nil, Some(96)), (Ref.get(log#instanceWidths), List.head(Ref.get(log#instanceData)) |> Option.map(List.length)))

    /// 32 体はちょうど 1 行（256 texel）で、1 本の draw。
    @Test
    def testFullRowIsOneRow(): Unit \ {Assert, IO} =
        let log = paintedRow(32);
        Assert.assertEq(expected = (256 :: Nil, Some(1024), 32 :: Nil), (Ref.get(log#instanceWidths), List.head(Ref.get(log#instanceData)) |> Option.map(List.length), Ref.get(log#instanceCounts)))

    /// 33 体は 2 行で、33 体目は 2 行目の頭に入る。
    @Test
    def testNextRowHoldsTheLastInstance(): Unit \ {Assert, IO} =
        let log = paintedRow(33);
        Assert.assertEq(expected = (256 :: Nil, Some(2048), 33 :: Nil, Some(RenderUtil.f32(0.32))),
            (Ref.get(log#instanceWidths), List.head(Ref.get(log#instanceData)) |> Option.map(List.length), Ref.get(log#instanceCounts), instanceFloat(log, 1024 + 12)))

    /// 形の違う 2 つの物は、同じ材質でも draw が 2 本。
    @Test
    def testSameMaterialOnTwoShapesIsTwoDraws(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let shared = solidMaterial();
        let on = (mesh: Mesh3d.Mesh3d) -> Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(shared);
        paint(recordingGl(log), freshState(), cmdOf(sceneOf(on(plainTriangle()) :: on(otherTriangle()) :: Nil)) :: Nil);
        Assert.assertEq(expected = 1 :: 1 :: Nil, Ref.get(log#instanceCounts))

    def otherTriangle(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(2.0, 0.0, 0.0) :: Vec3.v3(0.0, 2.0, 0.0) :: Nil, color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    /// 名前 name の別の木の材質（プログラムが別になる）。
    def namedMaterial(red: Float64): Scene3d.Material3d =
        Scene3d.material({ name = "m${red}", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = red, g = 0.5, b = 0.5 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    /// 材質 A・B・A の物の場面。
    def abaScene(mesh: Mesh3d.Mesh3d, other: Mesh3d.Mesh3d): Scene3d.Scene3dCmd =
        let on = (m: Mesh3d.Mesh3d, red: Float64) -> Scene3d.meshInstance(m, Mat4.identity()) |> Scene3d.withMaterial(namedMaterial(red));
        sceneOf(on(mesh, 0.1) :: on(other, 0.9) :: on(other, 0.1) :: Nil)

    /// 2 コマ目に描く時に使ったプログラムの並び（組むのは 1 コマ目に済む）。
    def programsDrawn(state: Render3d.State): List[Int32] \ IO =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let cmd = cmdOf(abaScene(plainTriangle(), otherTriangle()));
        paint(gl, state, cmd :: Nil);
        Ref.put(Nil, log#usedPrograms);
        paint(gl, state, cmd :: Nil);
        List.reverse(Ref.get(log#usedPrograms))

    /// on は同じプログラムの batch をつなげて描く（材質 A・B・A でプログラムの切り替えは 2 つ）。
    @Test
    def testInstancedSortsMaterialsByProgram(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, List.length(programsDrawn(freshState())))

    /// off は材質を来た順のまま描く（材質 A・B・A でプログラムの切り替えは 3 つ）。
    @Test
    def testOneByOneKeepsMaterialsInArrivalOrder(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 3, List.length(programsDrawn(freshOneByOne())))

    /// 名前の順の (材質の名前, プログラムの番号) のうち、番号の順に並べた名前。
    def namesInBuildOrder(state: Render3d.State): List[String] \ IO =
        Ref.get(state#materialsRef) |> Map.valuesOf |> List.map(e -> (e#locs#mesh#program, e#spec#name)) |> List.sortBy(fst) |> List.map(snd)

    def threeMaterials(): List[Scene3d.Instance3d] =
        (0.1 :: 0.5 :: 0.9 :: Nil) |> List.map(red -> Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(namedMaterial(red)))

    /// 材質のプログラムは置いた物が来た順に組む。
    @Test
    def testProgramsBuildInArrivalOrder(): Unit \ {Assert, IO} =
        let state = freshState();
        paint(recordingGl(freshRecorded()), state, cmdOf(sceneOf(threeMaterials())) :: Nil);
        Assert.assertEq(expected = "m0.1" :: "m0.5" :: "m0.9" :: Nil, namesInBuildOrder(state))

    /// 先に上げる道も、材質のプログラムを来た順に組む。
    @Test
    def testPreloadBuildsInArrivalOrder(): Unit \ {Assert, IO} =
        let state = freshState();
        Render3d.Preload.upload(recordingGl(freshRecorded()), state, 1i64, noTexture, { key = "three", instances = () -> threeMaterials(), textures = () -> Nil });
        Assert.assertEq(expected = "m0.1" :: "m0.5" :: "m0.9" :: Nil, namesInBuildOrder(state))

    /// 描く物が 1 つも無い prepare は 1 体ごとの値のテクスチャを作らない。
    @Test
    def testPrepareWithoutDrawsCreatesNoInstanceTexture(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let state = freshState();
        paint(recordingGl(log), state, cmdOf(sceneOf(Nil)) :: Nil);
        Assert.assertEq(expected = (Nil, 0), (Ref.get(log#instanceData), Map.size(Ref.get(state#instances#texturesRef))))

    /// 先に上げた物を描いても、プログラムを組み直さない（batch も 1 体の物も同じ版）。
    @Test
    def testPreloadedDrawsBuildNoProgram(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let tinted = Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(solidMaterial());
        let crowd = () -> skinnedAt(poseAt(1.0)) :: tinted :: Scene3d.meshInstance(plainTriangle(), Mat4.identity()) :: Nil;
        Render3d.Preload.upload(gl, state, 1i64, noTexture, { key = "crowd", instances = crowd, textures = () -> Nil });
        let built = timesCalled("createProgram", log);
        paint(gl, state, cmdOf(sceneOf(crowd())) :: Nil);
        Assert.assertEq(expected = (true, built), (built > 0, timesCalled("createProgram", log)))
}
