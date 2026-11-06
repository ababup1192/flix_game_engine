// joint texture（Render3d.JointTexture）の、行の割り当て・高さ・詰め方と、1 回の prepare につき 1 回だけ上げること。GL は呼び出しを控える偽物。
mod Render3d.TestJointTexture {
    import fge.gl.RecordingGl
    import java.nio.FloatBuffer
    use Render3d.DataTexture.{heightFor}
    use Render3d.FakeGl.{cmdOf, dest, freshRecorded, freshState, noTexture, paint, paintTo, passDest, poseAt, recordingGl, sceneOf, shadowSpot, skinnedAt, stderrOf, timesCalled, viewport}
    use Render3d.JointTexture.{assignRow, noRows, packRows, upload, withPoseRow}

    /// n 本のジョイントが親から順につながった姿勢（どの joint 行列も x だけ動く）。
    def poseWithJoints(n: Int32, x: Float64): Pose3d.Pose3d =
        let rest = { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() };
        let indices = List.range(0, n) |> List.toVector;
        match Skin3d.make({ names = Vector.map(i -> "j${i}", indices), parents = Vector.map(i -> i - 1, indices), rest = Vector.map(_ -> rest, indices),
                            inverseBinds = None, rootTransform = Mat4.identity() }) {
            case Ok(skin) => Pose3d.compute(skin, Vector#{ { translation = Vec3.v3(x, 0.0, 0.0) | rest } })
            case Err(e)   => bug!(e)
        }

    def rowsFrom(poses: List[Pose3d.Pose3d]): (List[Int32], Render3d.JointTexture.PoseRows) =
        let (rowsReversed, table) = poses |> List.foldLeft((acc, pose) -> {
            let (seen, rows) = acc;
            let (row, next) = assignRow(pose, rows);
            (row :: seen, next)
        }, (Nil, noRows(1024)));
        (List.reverse(rowsReversed), table)

    // ── 行の割り当て ──

    /// 同じ姿勢の値は同じ行・新しい姿勢は出てきた順に次の行。
    @Test
    def testSamePoseGetsSameRowInFirstSeenOrder(): Unit \ Assert =
        let a = poseAt(1.0);
        let b = poseAt(2.0);
        Assert.assertEq(expected = 0 :: 1 :: 0 :: 1 :: 0 :: Nil, fst(rowsFrom(a :: b :: a :: b :: a :: Nil)))

    /// 中身の同じ別々の姿勢の値も同じ行で、詰める姿勢は 1 つ。
    @Test
    def testEqualContentPosesShareRow(): Unit \ Assert =
        let (rows, table) = rowsFrom(poseAt(1.0) :: poseAt(1.0) :: Nil);
        Assert.assertEq(expected = (0 :: 0 :: Nil, 1), (rows, table#used))

    /// 鍵が同じでも中身の違う姿勢は別の行（a を b の鍵の束へ入れた割り当てで、同じ鍵になった形を作る）。
    @Test
    def testSameKeyDifferentContentGetsOwnRow(): Unit \ Assert =
        let a = poseAt(1.0);
        let b = poseAt(2.0);
        let collided = { buckets = Map#{ Pose3d.keyOf(b) => (a, 0) :: Nil }, poses = a :: Nil, used = 1 | noRows(1024) };
        Assert.assertEq(expected = (1, 2), { let (row, next) = assignRow(b, collided); (row, next#used) })

    /// 上限 2 行で 3 つ目の違う姿勢は最後の行を読み、あふれた数が残る。前の 2 つの行は動かない。
    @Test
    def testPosePastLimitReadsLastRow(): Unit \ Assert =
        let (first, one) = assignRow(poseAt(1.0), noRows(2));
        let (second, two) = assignRow(poseAt(2.0), one);
        let (third, three) = assignRow(poseAt(3.0), two);
        Assert.assertEq(expected = (0, 1, 1, 2, 1), (first, second, third, three#used, three#dropped))

    /// 間引いた物には行を配らず、描く物には配る。
    @Test
    def testCulledDrawGetsNoRow(): Unit \ {Assert, IO} =
        let rows = Ref.fresh(Static, noRows(1024));
        let draw = (x: Float64, culled: Bool) ->
            { fields = Scene3d.instanceFieldsOf(Scene3d.meshInstance(Mesh3d.fromPolygons(Nil), Mat4.identity())), pose = Some(poseAt(x)), poseRow = 0, culled = culled };
        let hidden = withPoseRow(rows, draw(1.0, true));
        let first = withPoseRow(rows, draw(2.0, false));
        let second = withPoseRow(rows, draw(3.0, false));
        Assert.assertEq(expected = (0, 0, 1, 2), (hidden#poseRow, first#poseRow, second#poseRow, Ref.get(rows)#used))

    /// 同じ姿勢の値は同じ値・中身の同じ別々の値は同じ値と見なさない（中身の比べは鍵の後）。
    @Test
    def testSameValueIsNotEqualContent(): Unit \ Assert =
        let p = poseAt(1.0);
        Assert.assertEq(expected = (true, false), (Render3d.JointTexture.isSameValue(p, p), Render3d.JointTexture.isSameValue(poseAt(1.0), poseAt(1.0))))

    // ── 高さと詰め方 ──

    /// 高さは 16 から倍に伸び、ちょうどの数は伸びない（64 → 64・65 → 128）。上限で切る。
    @Test
    def testHeightDoublesPastPowerOfTwo(): Unit \ Assert =
        Assert.assertEq(expected = 16 :: 16 :: 32 :: 64 :: 128 :: 100 :: Nil,
            heightFor(4096, 1) :: heightFor(4096, 16) :: heightFor(4096, 17) :: heightFor(4096, 64) :: heightFor(4096, 65) :: heightFor(100, 100) :: Nil)

    /// 1 行の幅は一番多い姿勢のジョイントの数（1 本・3 本・2 本 → 3 本）。行をもらえなかった姿勢の分も含む（上限 1 行で 5 本 → 5 本）。
    @Test
    def testJointsOfRowIsWidestPoseIncludingDropped(): Unit \ Assert =
        let widest = snd(rowsFrom(poseWithJoints(1, 1.0) :: poseWithJoints(3, 2.0) :: poseWithJoints(2, 3.0) :: Nil))#joints;
        let (_, one) = assignRow(poseWithJoints(2, 1.0), noRows(1));
        let (_, dropped) = assignRow(poseWithJoints(5, 2.0), one);
        Assert.assertEq(expected = (3, 5, 1), (widest, dropped#joints, dropped#used))

    /// 行 r の姿勢の x は、r × 16 + 12 個目（列優先の 4 列目の頭）。読む範囲は全部の行。
    @Test
    def testPackRowsPutsEachPoseInItsRow(): Unit \ {Assert, IO} =
        let out = FloatBuffer.allocate(64);
        packRows(1, poseAt(1.0) :: poseAt(2.0) :: poseAt(3.0) :: Nil, out);
        Assert.assertEq(expected = (1.0f32, 2.0f32, 3.0f32, 48), (out.get(12), out.get(28), out.get(44), out.limit()))

    /// ジョイントの数の違う姿勢が混ざっても、行 r の頭は r × 1 行の数の所（1 行 2 本 = 32 個。1 本の姿勢の x は 12 個目・2 本の姿勢の 2 本目の x は 44 個目）。
    @Test
    def testPackRowsKeepsStrideWithMixedJointCounts(): Unit \ {Assert, IO} =
        let out = FloatBuffer.allocate(64);
        packRows(2, poseWithJoints(1, 1.0) :: poseWithJoints(2, 2.0) :: Nil, out);
        Assert.assertEq(expected = (1.0f32, 2.0f32, 2.0f32, 64), (out.get(12), out.get(44), out.get(60), out.limit()))

    // ── 上げる（呼び出しを控える偽の GL の上で）──

    /// 0.0 から 1.0 ずつ違う姿勢を n 個並べた割り当て。
    def rowsOfCount(n: Int32): Render3d.JointTexture.PoseRows =
        snd(rowsFrom(List.range(0, n) |> List.map(i -> poseAt(Int32.toFloat64(i)))))

    /// 姿勢が無い prepare はテクスチャを作らず、GL を 1 つも呼ばない。
    @Test
    def testNoPosesCreatesNoTexture(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let state = freshState();
        let texture = upload(recordingGl(log), state, 1i64, noRows(4096));
        Assert.assertEq(expected = (None, Nil, 0), (texture, Ref.get(log#calls), Render3d.Counts.takeCounts(state)#jointUploads))

    /// 16 行のテクスチャの次のコマで 17 行を上げても、テクスチャを 32 行に確保し直してから全部の行を 1 回で上げる（0 行目も 16 行目も読める）。
    @Test
    def testGrowthKeepsEarlierRows(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        discard upload(gl, state, 1i64, rowsOfCount(16));
        Render3d.DataTexture.endFrame(gl, state#joints, 1i64);
        Render3d.DataTexture.endFrame(gl, state#joints, 2i64);
        Render3d.DataTexture.endFrame(gl, state#joints, 3i64);
        discard upload(gl, state, 4i64, rowsOfCount(17));
        let (rowCount, xs) = List.head(Ref.get(log#uploaded)) |> Option.getWithDefault((0, Nil));
        Assert.assertEq(expected = (32 :: 16 :: Nil, 17, Some(0.0f32), Some(16.0f32), 1),
            (Ref.get(log#allocated), rowCount, List.head(xs), List.last(xs), Map.size(Ref.get(state#joints#texturesRef))))

    /// 高さが足りるテクスチャは確保し直さない。
    @Test
    def testEnoughHeightIsNotReallocated(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        discard upload(gl, state, 1i64, rowsOfCount(16));
        Render3d.DataTexture.endFrame(gl, state#joints, 1i64);
        Render3d.DataTexture.endFrame(gl, state#joints, 2i64);
        Render3d.DataTexture.endFrame(gl, state#joints, 3i64);
        discard upload(gl, state, 4i64, rowsOfCount(2));
        Assert.assertEq(expected = 16 :: Nil, Ref.get(log#allocated))

    /// endFrame を通らない塗り直しが続いても、テクスチャは 1 コマの順の上限（16）で止まる。
    @Test
    def testPrepareOrderWrapsWithoutEndFrame(): Unit \ {Assert, IO} =
        let gl = recordingGl(freshRecorded());
        let state = freshState();
        List.range(0, 40) |> List.forEach(_ -> discard upload(gl, state, 1i64, rowsOfCount(1)));
        Assert.assertEq(expected = 16, Map.size(Ref.get(state#joints#texturesRef)))

    /// 上限 2 行に 3 つの違う姿勢が来たら、2 行だけ上げる。幅は行をもらえなかった 3 本の姿勢の分まであり、知らせは 1 回だけ。
    @Test
    def testDroppedPosesUploadRowsWithinLimitAndWarnOnce(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let (_, one) = assignRow(poseWithJoints(1, 1.0), noRows(2));
        let (_, two) = assignRow(poseWithJoints(1, 2.0), one);
        let (_, rows) = assignRow(poseWithJoints(3, 3.0), two);
        let warned = stderrOf(() -> {
            discard upload(gl, state, 1i64, rows);
            discard upload(gl, state, 1i64, rows)
        });
        Assert.assertEq(expected = (Some(2), Some(12), 2),
            (List.head(Ref.get(log#uploaded)) |> Option.map(fst), List.head(Ref.get(log#uploadWidths)), List.length(String.split(regex = "最後の行の姿勢", warned))))

    /// 上げる呼び出しは GlCallLog の控えに 1 行ずつ出る。
    @Test
    def testRecordingLogsRgba32fCalls(): Unit \ {Assert, IO} =
        let recording = new RecordingGl(recordingGl(freshRecorded()));
        recording.texImageRgba32f(256, 16);
        recording.texSubImageRgba32f(0, 0, 4, 1, FloatBuffer.allocate(16));
        let lines = String.split(regex = "\n", recording.drainLog());
        Assert.assertEq(expected = ("texImageRgba32f 256 16", true, 2),
            (List.head(lines) |> Option.getWithDefault(""), List.last(lines) |> Option.exists(String.startsWith(prefix = "texSubImageRgba32f 0 0 4 1 ")), List.length(lines)))

    /// 同じコマの prepare は別のテクスチャ・次のコマも別のテクスチャで、3 コマ回ると 1 コマ目のテクスチャへ戻る（prepare 2 回 × 3 枚 = 6 枚）。
    @Test
    def testTexturesRotatePerPrepareAndFrame(): Unit \ {Assert, IO} =
        let gl = recordingGl(freshRecorded());
        let state = freshState();
        let frame = (gen: Int64) -> {
            let first = upload(gl, state, gen, rowsOfCount(1));
            let second = upload(gl, state, gen, rowsOfCount(1));
            Render3d.DataTexture.endFrame(gl, state#joints, gen);
            (first, second)
        };
        let one = frame(1i64);
        let two = frame(2i64);
        discard frame(3i64);
        let four = frame(4i64);
        Assert.assertEq(expected = (true, true, true, 6),
            (fst(one) != snd(one), fst(one) != fst(two), one == four, Map.size(Ref.get(state#joints#texturesRef))))

    /// しばらく使わなかったテクスチャは捨てる。
    @Test
    def testIdleTexturesAreDeleted(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        discard upload(gl, state, 1i64, rowsOfCount(1));
        Render3d.DataTexture.endFrame(gl, state#joints, 1000i64);
        Assert.assertEq(expected = (0, true), (Map.size(Ref.get(state#joints#texturesRef)), List.memberOf("deleteTexture", Ref.get(log#calls))))

    // ── 1 回の prepare につき 1 回（Render3d.prepareNumbered を通して）──

    /// 同じコマに Pass の描き先の場面・Design の場面・影を落とす場面の prepare が 3 回あると、上げるのは 3 回で、テクスチャも 3 枚。
    /// 同じ姿勢を 4 体描いても増えない。draw は Pass・Design・影の場面の色・影の地図の 1 本ずつで、どれも 4 体。影の地図を描いた後は描き先を Pass の番号へ戻さず画面へ戻す。
    @Test
    def testEachPrepareUploadsOnce(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let pose = poseAt(1.0);
        let crowd = skinnedAt(pose) :: skinnedAt(pose) :: skinnedAt(pose) :: skinnedAt(pose) :: Nil;
        paintTo(gl, state, passDest(), cmdOf(sceneOf(crowd)) :: Nil);
        paintTo(gl, state, passDest(), cmdOf({ resolution = Scene3d.Resolution.Design | sceneOf(crowd) }) :: Nil);
        paint(gl, state, cmdOf({ spotLights = shadowSpot() :: Nil | sceneOf(crowd) }) :: Nil);
        Assert.assertEq(expected = (3, 3, 3, 4 :: 4 :: 4 :: 4 :: Nil, 1, Some(0)),
            (Render3d.Counts.takeCounts(state)#jointUploads, List.length(Ref.get(log#uploaded)), Map.size(Ref.get(state#joints#texturesRef)),
             Ref.get(log#instanceCounts), timesCalled("texImageDepth24", log), List.head(Ref.get(log#targets))))

    /// prepare A → prepare B → A の draw の順でも、A の draw は A のテクスチャを貼ってから描く。
    @Test
    def testDrawBindsItsOwnPrepareTexture(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let first = Render3d.prepareNumbered(gl, state, 1i64, noTexture, dest(), cmdOf(sceneOf(skinnedAt(poseAt(1.0)) :: Nil)) :: Nil);
        discard Render3d.prepareNumbered(gl, state, 1i64, noTexture, dest(), cmdOf(sceneOf(skinnedAt(poseAt(2.0)) :: Nil)) :: Nil);
        first#draw(viewport(), 0);
        let binds = Ref.get(log#jointBinds);
        Assert.assertEq(expected = (3, true, true), (List.length(binds), List.head(binds) == List.last(binds), List.nth(1, binds) != List.head(binds)))

    /// 大きさの無い Design の場面は描き先を作らず、何も描かない。
    @Test
    def testZeroSizeDesignDrawsNothing(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let empty = { resolution = Scene3d.Resolution.Design, size = { x = 0.0, y = 0.0 } | sceneOf(skinnedAt(poseAt(1.0)) :: Nil) };
        paint(gl, state, cmdOf(empty) :: Nil);
        Assert.assertEq(expected = (0, 0, 0), (timesCalled("drawElementsInstanced", log), timesCalled("drawArrays", log), timesCalled("createFramebuffer", log)))

    /// 1 画素に満たない Design の場面は 1 画素の描き先へ描く（CPU の描き手と同じ）。
    @Test
    def testSubPixelDesignDrawsIntoOnePixel(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let tiny = { resolution = Scene3d.Resolution.Design, size = { x = 0.4, y = 0.4 } | sceneOf(skinnedAt(poseAt(1.0)) :: Nil) };
        discard Render3d.prepareNumbered(gl, state, 1i64, noTexture, dest(), cmdOf(tiny) :: Nil);
        Assert.assertEq(expected = 1, timesCalled("drawElementsInstanced", log))

    /// 1 回の prepare の 2 つの場面が同じ姿勢なら、行は 1 つで上げるのも 1 回。
    @Test
    def testScenesOfOnePrepareShareRows(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let pose = poseAt(1.0);
        paint(gl, state, cmdOf(sceneOf(skinnedAt(pose) :: Nil)) :: cmdOf(sceneOf(skinnedAt(pose) :: Nil)) :: Nil);
        Assert.assertEq(expected = (1, Some(1)), (Render3d.Counts.takeCounts(state)#jointUploads, List.head(Ref.get(log#uploaded)) |> Option.map(fst)))

    /// 骨の無い場面の prepare はテクスチャを作らない。
    @Test
    def testPrepareWithoutPosesUploadsNothing(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        paint(gl, state, cmdOf(sceneOf(Nil)) :: Nil);
        Assert.assertEq(expected = (0, Nil), (Render3d.Counts.takeCounts(state)#jointUploads, Ref.get(log#allocated)))


}
