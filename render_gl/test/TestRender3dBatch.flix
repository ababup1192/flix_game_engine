// 同じ形と材質の物の batch（Render3d.Batch）の分け方と、1 体ごとの値の詰め方（Render3d.Instancing）。GL を呼ばずに決まる所。
mod Render3d.TestBatch {
    import java.nio.FloatBuffer
    use Render3d.Batch.{BatchKey, batchKeyOf, batchOf, groupByTextures, groupInOrder, shapeBatches}
    use Render3d.DrawMode
    use Render3d.FakeGl.{poseAt}
    use Render3d.Instancing.{PackMode, numberBatch, packDraw, rowsFor}

    def triangle(side: Float64): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(side, 0.0, 0.0) :: Vec3.v3(0.0, side, 0.0) :: Nil, color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil)

    def drawOf(placed: Scene3d.Instance3d, culled: Bool): Render3d.MeshDraw =
        { fields = Scene3d.instanceFieldsOf(placed), pose = None, poseRow = 0, culled = culled }

    def plainDraw(side: Float64, culled: Bool): Render3d.MeshDraw =
        drawOf(Scene3d.meshInstance(triangle(side), Mat4.identity()), culled)

    def solidMaterial(): Scene3d.Material3d =
        Scene3d.material({ name = "batch", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.5, g = 0.5, b = 0.5 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    def solidFields(): Scene3d.MaterialFields = Scene3d.materialFieldsOf(solidMaterial())

    def plainKind(): Render3d.ProgramKind =
        { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false }

    def surfaceKey(m: Scene3d.MaterialFields, kind: Render3d.ProgramKind): Option[BatchKey] =
        batchKeyOf(DrawMode.Instanced, plainDraw(1.0, false), Some((m, kind)))

    def keyOf(m: Scene3d.MaterialFields): Option[BatchKey] = surfaceKey(m, plainKind())

    /// emissionIntensity の違う材質は同じ鍵。
    @Test
    def testEmissionIntensityStaysInOneBatch(): Unit \ Assert =
        Assert.assertTrue(keyOf(solidFields()) == keyOf(Scene3d.materialFieldsOf(solidMaterial() |> Scene3d.withEmissionIntensity(6.0))))

    /// tint の違う物は同じ鍵。
    @Test
    def testTintStaysInOneBatch(): Unit \ Assert =
        let tinted = drawOf(Scene3d.meshInstance(triangle(1.0), Mat4.identity()) |> Scene3d.withTint({ r = 1.0, g = 0.0, b = 0.0 }), false);
        Assert.assertTrue(batchKeyOf(DrawMode.Instanced, plainDraw(1.0, false), None) == batchKeyOf(DrawMode.Instanced, tinted, None))

    /// 形の違う物はバケツで分かれる。
    @Test
    def testDifferentMeshSplits(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, List.length(shapeBatches(DrawMode.Instanced, plainDraw(1.0, false) :: plainDraw(2.0, false) :: Nil)))

    /// 骨つきの物は骨の無い物と違う鍵。
    @Test
    def testSkinnedSplits(): Unit \ Assert =
        let posed = { pose = Some(poseAt(1.0)) | plainDraw(1.0, false) };
        Assert.assertTrue(batchKeyOf(DrawMode.Instanced, posed, None) != batchKeyOf(DrawMode.Instanced, plainDraw(1.0, false), None))

    /// cutout の違う材質は違う鍵。
    @Test
    def testCutoutSplits(): Unit \ Assert =
        Assert.assertTrue(keyOf({ cutout = true | solidFields() }) != keyOf({ cutout = false | solidFields() }))

    /// params の違う材質は違う鍵。
    @Test
    def testParamsSplit(): Unit \ Assert =
        Assert.assertTrue(keyOf({ params = Map#{ "a" => 1.0 } | solidFields() }) != keyOf({ params = Map#{ "a" => 2.0 } | solidFields() }))

    /// wrap の違う材質は違う鍵。
    @Test
    def testWrapSplits(): Unit \ Assert =
        Assert.assertTrue(keyOf({ wrap = Scene3d.Wrap.Clamp | solidFields() }) != keyOf({ wrap = Scene3d.Wrap.Repeat | solidFields() }))

    /// 法線マップの絵の名前の違う材質は違う鍵。
    @Test
    def testNormalNameSplits(): Unit \ Assert =
        let bumped = (name: String) -> keyOf({ normalMap = Some({ texture = name, strength = 1.0 }) | solidFields() });
        Assert.assertTrue(bumped("a") != bumped("b"))

    /// 法線マップの強さの違う材質は違う鍵。
    @Test
    def testNormalStrengthSplits(): Unit \ Assert =
        let bumped = (s: Float64) -> keyOf({ normalMap = Some({ texture = "n", strength = s }) | solidFields() });
        Assert.assertTrue(bumped(1.0) != bumped(0.5))

    /// プログラムの版の欄（skinned・uv・normalMap・doubleSided・coverage）は、どの 2 つも違う鍵になる。
    @Test
    def testEveryProgramKindFieldSplits(): Unit \ Assert =
        let base = plainKind();
        let kinds = base :: { skinned = true | base } :: { uv = true | base } :: { normalMap = true | base } :: { doubleSided = true | base } :: { coverage = true | base } :: Nil;
        Assert.assertEq(expected = 6, kinds |> List.map(k -> surfaceKey(solidFields(), k)) |> List.toSet |> Set.size)

    /// 半透明の物は batch にしない。
    @Test
    def testBlendedStaysAlone(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(keyOf({ blend = true | solidFields() })))

    /// lightmap つきの版は batch にしない。
    @Test
    def testLightmappedStaysAlone(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(surfaceKey(solidFields(), { lightmap = true | plainKind() })))

    /// OneByOne は全部の物を batch にしない。
    @Test
    def testOneByOneHasNoKey(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(batchKeyOf(DrawMode.OneByOne, plainDraw(1.0, false), None)))

    /// batch の中は来た順・batch どうしは頭の物が来た順。鍵の無い物は 1 体の batch。
    @Test
    def testGroupsKeepFirstSeenOrder(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (2 :: 2 :: Nil) :: (1 :: 1 :: 1 :: Nil) :: (3 :: Nil) :: (0 :: Nil) :: (0 :: Nil) :: Nil,
            groupInOrder(_ -> "", x -> if (x == 0) None else Some(x), 2 :: 1 :: 2 :: 3 :: 1 :: 1 :: 0 :: 0 :: Nil))

    /// 同じ鍵でもバケツの字が違えば別の batch。
    @Test
    def testBucketSplitsSameKey(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, List.length(groupInOrder(x -> Int32.toString(x), _ -> Some(0), 1 :: 2 :: 1 :: Nil)))

    /// 形 X・Y・X は、X の 2 体・Y の 1 体の順に描く（同じ深さの面の勝ち方はこの順で決まる）。
    @Test
    def testShapesXyxDrawXxThenY(): Unit \ {Assert, IO} =
        let x = plainDraw(1.0, false);
        let y = plainDraw(2.0, false);
        Assert.assertEq(expected = (Mesh3d.contentHash(x#fields#mesh), 2) :: (Mesh3d.contentHash(y#fields#mesh), 1) :: Nil,
            shapeBatches(DrawMode.Instanced, x :: y :: x :: Nil) |> List.map(b -> (Mesh3d.contentHash(b#head#fields#mesh), b#count)))

    /// 絵の名前だけが違う材質は別の batch で、同じ名前の物は同じ batch。
    @Test
    def testTextureNamesSplitInsideOneKey(): Unit \ {Assert, IO} =
        let fieldsOf = (name: String) -> Some(Scene3d.materialFieldsOf(Scene3d.texturedMaterial(name, ShaderDoc.FilterMode.Nearest)));
        Assert.assertEq(expected = 2 :: 1 :: Nil,
            groupByTextures(identity, fieldsOf("a") :: fieldsOf("b") :: fieldsOf("a") :: Nil) |> List.map(List.length))

    /// 同じ材質の値の物は木を辿らず 1 つの batch。材質の無い物も 1 つの batch。
    @Test
    def testSameMaterialValueIsOneGroup(): Unit \ {Assert, IO} =
        let shared = Some(solidFields());
        Assert.assertEq(expected = (1, 1), (List.length(groupByTextures(identity, shared :: shared :: Nil)), List.length(groupByTextures(identity, None :: None :: Nil))))

    /// 間引いた物は batch の描く物に入らず、頭の物としては残る。
    @Test
    def testCulledDrawIsNotInBatch(): Unit \ Assert =
        let hidden = plainDraw(1.0, true);
        let batch = batchOf(hidden, hidden :: plainDraw(1.0, false) :: Nil);
        Assert.assertEq(expected = (1, 1, true), (batch#count, List.length(batch#draws), batch#head#culled))

    /// 全部間引いた batch は描く物が 0 で残る（形の使った記録を付けるため）。
    @Test
    def testAllCulledBatchRemainsEmpty(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0 :: Nil, shapeBatches(DrawMode.Instanced, plainDraw(1.0, true) :: plainDraw(1.0, true) :: Nil) |> List.map(b -> b#count))

    // ── 1 体ごとの値 ──

    def scratch(): Array[Float32, Static] \ IO = Array.repeat(Static, 32, 0.0f32)

    def packed(mode: PackMode, d: Render3d.MeshDraw): FloatBuffer \ IO =
        let out = FloatBuffer.allocate(32);
        packDraw(out, scratch(), mode, d);
        out

    /// 回した上に軸ごとに違う倍率の world（行列が対称でない）。
    def stretched(): Mat4.Mat4 =
        Transform3d.toMat4({ yaw = 0.7, scale = Vec3.v3(2.0, 3.0, 4.0) | Transform3d.of(Vec3.v3(3.0, 0.0, 0.0)) })

    /// world は 0 個目から列の順。
    @Test
    def testPackPutsWorldColumns(): Unit \ {Assert, IO} =
        let columns = Mat4.toColumns(stretched());
        let out = packed(PackMode.Lit, drawOf(Scene3d.meshInstance(triangle(1.0), stretched()), false));
        Assert.assertEq(expected = (RenderUtil.f32(Vector.get(2, columns)), RenderUtil.f32(Vector.get(8, columns)), 3.0f32), (out.get(2), out.get(8), out.get(12)))

    /// 法線の行列の列は 16・20・24 個目から（行と列を取り違えると値が変わる世界で見る）。
    @Test
    def testPackPutsNormalColumns(): Unit \ {Assert, IO} =
        let n = Mat4.toColumns(Mat4.normalMatrix(stretched()));
        let at = i -> RenderUtil.f32(Vector.get(i, n));
        let out = packed(PackMode.Lit, drawOf(Scene3d.meshInstance(triangle(1.0), stretched()), false));
        Assert.assertEq(expected = (true, at(2), at(8), at(6)), (at(2) != at(8), out.get(18), out.get(24), out.get(22)))

    /// emissionIntensity は 19 個目（材質の無い物は 1）。
    @Test
    def testPackPutsEmissionIntensity(): Unit \ {Assert, IO} =
        let d = drawOf(Scene3d.meshInstance(triangle(1.0), Mat4.identity()) |> Scene3d.withMaterial(solidMaterial() |> Scene3d.withEmissionIntensity(6.0)), false);
        Assert.assertEq(expected = (6.0f32, 1.0f32), (packed(PackMode.Lit, d).get(19), packed(PackMode.Lit, plainDraw(1.0, false)).get(19)))

    /// 姿勢の行は 23 個目で、影の道でも入る。
    @Test
    def testPackPutsPoseRowInBothModes(): Unit \ {Assert, IO} =
        let d = { poseRow = 5 | plainDraw(1.0, false) };
        Assert.assertEq(expected = (5.0f32, 5.0f32), (packed(PackMode.Lit, d).get(23), packed(PackMode.ShadowDepth, d).get(23)))

    /// tint は 28 個目から線形の量で入る（白は 1）。
    @Test
    def testPackPutsLinearTint(): Unit \ {Assert, IO} =
        let c = Texture3d.srgbToLinearColor({ r = 0.5, g = 1.0, b = 0.0 });
        let d = drawOf(Scene3d.meshInstance(triangle(1.0), Mat4.identity()) |> Scene3d.withTint({ r = 0.5, g = 1.0, b = 0.0 }), false);
        Assert.assertEq(expected = (RenderUtil.f32(c#r), 1.0f32, 0.0f32), { let out = packed(PackMode.Lit, d); (out.get(28), out.get(29), out.get(30)) })

    /// 1 体は 32 個。
    @Test
    def testPackWritesOneInstanceWidth(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (32, 32), (packed(PackMode.Lit, plainDraw(1.0, false)).position(), packed(PackMode.ShadowDepth, plainDraw(1.0, false)).position()))

    /// テクスチャの幅は 1 体の幅で割り切れる（1 体が行をまたがない）。
    @Test
    def testInstanceDoesNotCrossRows(): Unit \ Assert =
        Assert.assertEq(expected = 0, Int32.remainder(Render3dGlsl.dataTextureWidth(), Render3dGlsl.texelsPerInstance()))

    /// 行の数は 1 行の体の数で切り上げる。
    @Test
    def testRowsRoundUp(): Unit \ Assert =
        let perRow = Render3dGlsl.instancesPerRow();
        Assert.assertEq(expected = (1, 1, 2), (rowsFor(1), rowsFor(perRow), rowsFor(perRow + 1)))

    /// batch の番号は next から続き、入り切らない物は描く物の数から落ちる。
    @Test
    def testNumberingStopsAtCapacity(): Unit \ {Assert, IO} =
        let out = FloatBuffer.allocate(32 * 4);
        let next = Array#{0} @ Static;
        let three = batchOf(plainDraw(1.0, false), List.repeat(3, plainDraw(1.0, false)));
        let first = numberBatch(out, scratch(), 4, next, PackMode.Lit, three);
        let second = numberBatch(out, scratch(), 4, next, PackMode.Lit, three);
        Assert.assertEq(expected = (0, 3, 3, 1, 4), (first#first, first#count, second#first, second#count, Array.get(0, next)))
}
