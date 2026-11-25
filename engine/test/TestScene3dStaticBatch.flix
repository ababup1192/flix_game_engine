// TestScene3dStaticBatch — 動かない物の集まりの、1 回しか使わない形を 1 つの形につなぐ計画（Scene3d.StaticBatch）:
// どの物をつなぐか（1 回しか使わない・つなぐ単位・つながない物）・並びの順・つないだ形の頂点（world・tint の掛け方）・中身の鍵。

mod TestScene3dStaticBatch {
    use Scene3d.StaticBatch.{PlanEntry}

    /// 幅 side の三角形（頂点の色 color）を x に置いた物。
    def triAt(side: Float64, x: Float64, color: Color): Scene3d.Instance3d =
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(side, 0.0, 0.0) :: Vec3.v3(0.0, side, 0.0) :: Nil, color = color } :: Nil);
        Scene3d.meshInstance(mesh, Mat4.translate(Vec3.v3(x, 0.0, 0.0)))

    def white(): Color = Color.rgb(1.0, 1.0, 1.0)

    def plainAt(side: Float64): Scene3d.Instance3d = triAt(side, side, white())

    def textured(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:checker", ShaderDoc.FilterMode.Nearest)

    def texturedAt(side: Float64, tint: Color): Scene3d.Instance3d =
        let i = triAt(side, side, white());
        Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, Scene3d.instanceFieldsOf(i)#mesh), Scene3d.instanceFieldsOf(i)#world)
            |> Scene3d.withMaterial(textured()) |> Scene3d.withTint(tint)

    /// 計画の 1 つを (Single なら 1・Combine なら中の物の数) の字にした並び。
    def shapeOf(plan: Vector[PlanEntry]): List[String] =
        plan |> Vector.toList |> List.map(e -> match e {
            case PlanEntry.Single(_)     => "1"
            case PlanEntry.Combine(list) => "c${List.length(list)}"
        })

    // ── どの物をつなぐか ──

    @Test
    def testOnceUsedPlainShapesBecomeOneCombine(): Unit \ Assert =
        Assert.assertEq(expected = "c3" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(plainAt(1.0) :: plainAt(2.0) :: plainAt(3.0) :: Nil)))

    @Test
    def testShapeUsedTwiceStaysSingle(): Unit \ Assert =
        let twice = plainAt(1.0);
        let again = Scene3d.meshInstance(Scene3d.instanceFieldsOf(twice)#mesh, Mat4.translate(Vec3.v3(9.0, 0.0, 0.0)));
        Assert.assertEq(expected = "1" :: "c2" :: "1" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(twice :: plainAt(2.0) :: again :: plainAt(3.0) :: Nil)))

    @Test
    def testSameContentInAnotherValueCountsAsUsedTwice(): Unit \ Assert =
        Assert.assertEq(expected = "1" :: "1" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(plainAt(1.0) :: triAt(1.0, 5.0, white()) :: Nil)))

    @Test
    def testTexturedShapesWithDifferentTintsAreSeparateUnits(): Unit \ Assert =
        let red = Color.rgb(1.0, 0.5, 0.5);
        let items = texturedAt(1.0, red) :: texturedAt(2.0, white()) :: texturedAt(3.0, red) :: Nil;
        Assert.assertEq(expected = "c2" :: "1" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(items)))

    @Test
    def testPlainAndTexturedAreSeparateUnits(): Unit \ Assert =
        let items = plainAt(1.0) :: texturedAt(2.0, white()) :: plainAt(3.0) :: texturedAt(4.0, white()) :: Nil;
        Assert.assertEq(expected = "c2" :: "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(items)))

    @Test
    def testNormalMappedMaterialIsNotCombinable(): Unit \ Assert =
        let mapped = texturedAt(1.0, white()) |> (i -> Scene3d.withMaterial(textured() |> Scene3d.withNormalMap({ texture = "tex3d:n", strength = 1.0 }), i));
        Assert.assertFalse(Scene3d.StaticBatch.isCombinable(mapped))

    @Test
    def testPlainShapeIsCombinable(): Unit \ Assert =
        Assert.assertTrue(Scene3d.StaticBatch.isCombinable(plainAt(1.0)))

    @Test
    def testBlendedMaterialIsNotCombinable(): Unit \ Assert =
        Assert.assertFalse(Scene3d.StaticBatch.isCombinable(texturedAt(1.0, white()) |> (i -> Scene3d.withMaterial(textured() |> Scene3d.withAlphaBlend(true), i))))

    @Test
    def testPlainShapesWithAndWithoutUvsShareOneUnit(): Unit \ Assert =
        let withUv = Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, Scene3d.instanceFieldsOf(plainAt(1.0))#mesh), Mat4.identity());
        Assert.assertEq(expected = "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(withUv :: plainAt(2.0) :: Nil)))

    @Test
    def testPlainCombinedDropsUvs(): Unit \ Assert =
        let withUv = (side: Float64) -> Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, Scene3d.instanceFieldsOf(plainAt(side))#mesh), Mat4.identity());
        Assert.assertTrue(Option.isEmpty(Mesh3d.uvs(Scene3d.instanceFieldsOf(Scene3d.StaticBatch.combine(withUv(1.0) :: withUv(2.0) :: Nil))#mesh)))

    @Test
    def testTexturedShapesWithAndWithoutUvsAreSeparateUnits(): Unit \ Assert =
        let noUv = plainAt(1.0) |> Scene3d.withMaterial(textured());
        let items = noUv :: texturedAt(2.0, white()) :: (plainAt(3.0) |> Scene3d.withMaterial(textured())) :: texturedAt(4.0, white()) :: Nil;
        Assert.assertEq(expected = "c2" :: "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(items)))

    @Test
    def testMaterialParamsSplitUnits(): Unit \ Assert =
        let other = (side: Float64) -> texturedAt(side, white()) |> Scene3d.withMaterial(textured() |> Scene3d.withParams(Map#{ "k" => 2.0 }));
        Assert.assertEq(expected = "c2" :: "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(texturedAt(1.0, white()) :: other(2.0) :: texturedAt(3.0, white()) :: other(4.0) :: Nil)))

    @Test
    def testEmissionIntensitySplitsUnits(): Unit \ Assert =
        let bright = (side: Float64) -> texturedAt(side, white()) |> Scene3d.withMaterial(textured() |> Scene3d.withEmissionIntensity(3.0));
        Assert.assertEq(expected = "c2" :: "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(texturedAt(1.0, white()) :: bright(2.0) :: texturedAt(3.0, white()) :: bright(4.0) :: Nil)))

    @Test
    def testCutoutSplitsUnits(): Unit \ Assert =
        let cut = (side: Float64) -> texturedAt(side, white()) |> Scene3d.withMaterial(textured() |> Scene3d.withCutout(true));
        Assert.assertEq(expected = "c2" :: "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(texturedAt(1.0, white()) :: cut(2.0) :: texturedAt(3.0, white()) :: cut(4.0) :: Nil)))

    @Test
    def testLightmappedShapeIsNotCombinable(): Unit \ Assert =
        let i = texturedAt(1.0, white());
        let f = Scene3d.instanceFieldsOf(i);
        let baked = Scene3d.meshInstance(Mesh3d.withUvs2(Mesh3d.uvs(f#mesh) |> Option.getWithDefault(Vector.empty()), f#mesh) |> Result.getWithDefault(f#mesh), f#world)
            |> Scene3d.withMaterial(textured()) |> Scene3d.withLightmap(Scene3d.lightmap("tex3d:lm"));
        Assert.assertFalse(Scene3d.StaticBatch.isCombinable(baked))

    @Test
    def testSkinWeightedShapeIsNotCombinable(): Unit \ Assert =
        let skin = { joints = Vector.repeat(12, 0), weights = Vector#{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0} };
        let m = Mesh3d.fromArrays({ positions = Vector#{0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0}, normals = Vector#{0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, -1.0},
                                    colors = Vector.repeat(9, 1.0), indices = Vector#{0, 1, 2}, skin = Some(skin) });
        Assert.assertEq(expected = Ok(false), Result.map(mesh -> Scene3d.StaticBatch.isCombinable(Scene3d.meshInstance(mesh, Mat4.identity())), m))

    /// 頂点 count 個（3 の倍数）の、x にずらした三角形の並び（形の中身は x ごとに違う）。
    def bigAt(count: Int32, x: Float64): Scene3d.Instance3d =
        let positions = Vector.range(0, count * 3) |> Vector.map(k -> Int32.toFloat64(k) * 0.001 + (if (Int32.remainder(k, 3) == 0) x else 0.0));
        let mesh = Mesh3d.fromArrays({ positions = positions, normals = Vector.repeat(count * 3, 0.5), colors = Vector.repeat(count * 3, 1.0),
                                       indices = Vector.range(0, count), skin = None });
        match mesh {
            case Ok(m)  => Scene3d.meshInstance(m, Mat4.identity())
            case Err(e) => bug!(e)
        }

    @Test
    def testUnitOverTheVertexLimitIsSplit(): Unit \ Assert =
        let items = bigAt(3999, 0.0) :: bigAt(3999, 1.0) :: bigAt(3999, 2.0) :: bigAt(3999, 3.0) :: Nil;
        Assert.assertEq(expected = "c2" :: "c2" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(items)))

    // ── 並びの順 ──

    @Test
    def testCombineSitsAtItsFirstMember(): Unit \ Assert =
        let twice = plainAt(1.0);
        let again = Scene3d.meshInstance(Scene3d.instanceFieldsOf(twice)#mesh, Mat4.identity());
        let items = twice :: texturedAt(2.0, white()) :: plainAt(3.0) :: texturedAt(4.0, white()) :: again :: plainAt(5.0) :: Nil;
        Assert.assertEq(expected = "1" :: "c2" :: "c2" :: "1" :: Nil, shapeOf(Scene3d.StaticBatch.planOf(items)))

    @Test
    def testCombineAllKeepsOneDrawnItemPerEntry(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(Scene3d.StaticBatch.combineAll(plainAt(1.0) :: plainAt(2.0) :: plainAt(3.0) :: Nil)))

    // ── つないだ形 ──

    def combined(items: List[Scene3d.Instance3d]): Scene3d.InstanceFields = Scene3d.instanceFieldsOf(Scene3d.StaticBatch.combine(items))

    @Test
    def testCombinedMeshHasEveryVertexAndIndex(): Unit \ Assert =
        let m = combined(plainAt(1.0) :: plainAt(2.0) :: Nil)#mesh;
        Assert.assertEq(expected = (6, 2), (Mesh3d.vertexCount(m), Mesh3d.triangleCount(m)))

    @Test
    def testCombinedPositionsAreInWorld(): Unit \ Assert =
        let m = combined(plainAt(1.0) :: plainAt(2.0) :: Nil)#mesh;
        Assert.assertEq(expected = Some(2.0), Vector.nth(9, Mesh3d.positions(m)))

    @Test
    def testSecondShapeIndicesPointPastTheFirst(): Unit \ Assert =
        let m = combined(plainAt(1.0) :: plainAt(2.0) :: Nil)#mesh;
        Assert.assertEq(expected = Vector#{0, 1, 2, 3, 4, 5}, Mesh3d.indices(m))

    @Test
    def testCombinedPlacementIsIdentity(): Unit \ Assert =
        Assert.assertEq(expected = Mat4.asRows(Mat4.identity()), Mat4.asRows(combined(plainAt(1.0) :: plainAt(2.0) :: Nil)#world))

    @Test
    def testPlainTintIsBakedLinearlyIntoVertexColors(): Unit \ Assert =
        let half = Color.rgb(0.5, 0.5, 0.5);
        let items = triAt(1.0, 0.0, half) |> Scene3d.withTint(half) :: plainAt(2.0) :: Nil;
        let expected = Texture3d.linearToSrgb(Texture3d.srgbToLinear(0.5) * Texture3d.srgbToLinear(0.5));
        Assert.assertEq(expected = Some(expected), Vector.head(Mesh3d.colors(combined(items)#mesh)))

    @Test
    def testPlainCombinedTintIsWhite(): Unit \ Assert =
        let items = plainAt(1.0) |> Scene3d.withTint(Color.rgb(0.2, 0.3, 0.4)) :: plainAt(2.0) :: Nil;
        let t = combined(items)#tint;
        Assert.assertEq(expected = (1.0, 1.0, 1.0), (t#r, t#g, t#b))

    @Test
    def testTexturedKeepsTintOnThePlacement(): Unit \ Assert =
        let red = Color.rgb(1.0, 0.5, 0.5);
        let t = combined(texturedAt(1.0, red) :: texturedAt(2.0, red) :: Nil)#tint;
        Assert.assertEq(expected = (1.0, 0.5, 0.5), (t#r, t#g, t#b))

    @Test
    def testTexturedKeepsVertexColorsUnbaked(): Unit \ Assert =
        let red = Color.rgb(1.0, 0.5, 0.5);
        Assert.assertEq(expected = Some(1.0), Vector.nth(1, Mesh3d.colors(combined(texturedAt(1.0, red) :: texturedAt(2.0, red) :: Nil)#mesh)))

    @Test
    def testTexturedCombinedKeepsUvs(): Unit \ Assert =
        Assert.assertTrue(Option.nonEmpty(Mesh3d.uvs(combined(texturedAt(1.0, white()) :: texturedAt(2.0, white()) :: Nil)#mesh)))

    @Test
    def testNormalsFollowTheRotation(): Unit \ Assert =
        let turned = Scene3d.meshInstance(Scene3d.instanceFieldsOf(plainAt(1.0))#mesh, Mat4.rotateY(3.141592653589793));
        let n = Mesh3d.normals(combined(turned :: plainAt(2.0) :: Nil)#mesh);
        let z = Vector.nth(2, n) |> Option.getWithDefault(0.0);
        let original = Vector.nth(2, Mesh3d.normals(Scene3d.instanceFieldsOf(plainAt(1.0))#mesh)) |> Option.getWithDefault(0.0);
        Assert.assertTrue(Float64.abs(z + original) < 1.0e-9)

    // ── 中身の鍵 ──

    @Test
    def testSameInputsGiveSameContentKey(): Unit \ Assert =
        let items = plainAt(1.0) :: plainAt(2.0) :: Nil;
        Assert.assertEq(expected = Mesh3d.contentHash(combined(items)#mesh), Mesh3d.contentHash(combined(items)#mesh))

    @Test
    def testMovedMemberChangesContentKey(): Unit \ Assert =
        let a = combined(plainAt(1.0) :: plainAt(2.0) :: Nil)#mesh;
        let b = combined(plainAt(1.0) :: triAt(2.0, 7.0, white()) :: Nil)#mesh;
        Assert.assertFalse(Mesh3d.contentHash(a) == Mesh3d.contentHash(b))

    @Test
    def testPlainTintChangesContentKey(): Unit \ Assert =
        let a = combined(plainAt(1.0) :: plainAt(2.0) :: Nil)#mesh;
        let b = combined(plainAt(1.0) |> Scene3d.withTint(Color.rgb(0.5, 1.0, 1.0)) :: plainAt(2.0) :: Nil)#mesh;
        Assert.assertFalse(Mesh3d.contentHash(a) == Mesh3d.contentHash(b))
}
