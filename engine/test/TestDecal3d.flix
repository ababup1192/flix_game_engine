// TestDecal3d — デカール（Decal3d）: 箱で切った板の形（箱の外・4 隅・浮かせる量・角で落とす面・uv・頂点の色・lightmap）、
// 的ごと・材質ごとのつなぎと並び、飛ばす的の知らせ、材質の鍵、決定性。

mod TestDecal3d {

    def white(): Color = Color.rgb(1.0, 1.0, 1.0)

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 1.0e-9

    def grime(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:grime", ShaderDoc.FilterMode.Nearest)

    /// z = 0 の面に 2h 四方の板（+z を向く・頂点の色 color）。
    def wallMesh(h: Float64, color: Color): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(0.0 - h, 0.0 - h, 0.0) :: Vec3.v3(h, 0.0 - h, 0.0) :: Vec3.v3(h, h, 0.0) :: Vec3.v3(0.0 - h, h, 0.0) :: Nil,
                              color = color } :: Nil)

    def wall(): Scene3d.Instance3d = Scene3d.meshInstance(wallMesh(2.0, white()), Mat4.identity()) |> Scene3d.withName("wall")

    /// y = 0 の床（+y を向く・x, z が −2..2）。
    def floor(): Scene3d.Instance3d =
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(-2.0, 0.0, -2.0) :: Vec3.v3(-2.0, 0.0, 2.0) :: Vec3.v3(2.0, 0.0, 2.0) :: Vec3.v3(2.0, 0.0, -2.0) :: Nil,
                                         color = white() } :: Nil);
        Scene3d.meshInstance(mesh, Mat4.identity())

    /// 正面（+z）から壁の真ん中へ投げる 1 × 1 のデカール。
    def front(): Decal3d.Decal = Decal3d.decal(grime(), Vec3.v3(0.0, 0.0, 0.0), Vec3.v3(0.0, 0.0, 1.0))

    def fieldsOf(i: Scene3d.Instance3d): Scene3d.InstanceFields = Scene3d.instanceFieldsOf(i)

    /// 置いた物の列の全部の頂点の位置。
    def pointsOf(xs: List[Scene3d.Instance3d]): List[Vec3.Vec3] =
        xs |> List.flatMap(i -> {
            let p = Mesh3d.positions(fieldsOf(i)#mesh);
            List.range(0, Vector.length(p) / 3) |> List.map(k -> Vec3.v3(Vector.get(k * 3, p), Vector.get(k * 3 + 1, p), Vector.get(k * 3 + 2, p)))
        })

    def pairsOf(v: Vector[Float64]): List[(Float64, Float64)] =
        List.range(0, Vector.length(v) / 2) |> List.map(k -> (Vector.get(k * 2, v), Vector.get(k * 2 + 1, v)))

    def onlyMesh(xs: List[Scene3d.Instance3d]): Mesh3d.Mesh3d = match xs {
        case i :: Nil => fieldsOf(i)#mesh
        case _        => bug!("置いた物が 1 つでない")
    }

    def round3(x: Float64): Int32 = Float64.round(x * 1000.0) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    // ── 材質 ──

    /// 板の材質は半透明でも画面の上の SSAO を受ける（隅の暗がりの上の汚れが明るく浮かない）。
    @Test
    def testPlateMaterialReceivesScreenAo(): Unit \ Assert =
        let plates = Decal3d.buildInstances(front() :: Nil, wall() :: Nil);
        let received = not List.isEmpty(plates)
            and List.forAll(i -> fieldsOf(i)#material |> Option.exists(m -> Scene3d.materialFieldsOf(m)#screenAoOnBlend), plates);
        Assert.assertTrue(received)

    /// ゲームが作る材質は SSAO を受ける旗が立っていない（半透明の物は奥の面の暗さを拾わない）。
    @Test
    def testPlainMaterialDoesNotReceiveScreenAoOnBlend(): Unit \ Assert =
        Assert.assertFalse(Scene3d.materialFieldsOf(Scene3d.withAlphaBlend(true, grime()))#screenAoOnBlend)

    // ── 切った形 ──

    @Test
    def testNoPointLeavesTheBox(): Unit \ Assert =
        let pts = pointsOf(Decal3d.buildInstances({ size = Vec3.v3(1.0, 0.6, 0.5) | front() } :: Nil, wall() :: Nil));
        Assert.assertTrue(not List.isEmpty(pts) and List.forAll(p -> Float64.abs(p#x) <= 0.5 + 1.0e-9 and Float64.abs(p#y) <= 0.3 + 1.0e-9, pts))

    @Test
    def testFrontalDecalOnAFlatWallCoversTheFourCorners(): Unit \ Assert =
        let corners = pointsOf(Decal3d.buildInstances(front() :: Nil, wall() :: Nil)) |> List.map(p -> (round3(p#x), round3(p#y))) |> List.toSet;
        Assert.assertEq(expected = Set#{(-500, -500), (-500, 500), (500, -500), (500, 500)}, corners)

    @Test
    def testPlateFloatsByOnePercentOfTheShorterSide(): Unit \ Assert =
        let pts = pointsOf(Decal3d.buildInstances({ size = Vec3.v3(2.0, 1.0, 0.5) | front() } :: Nil, wall() :: Nil));
        Assert.assertTrue(not List.isEmpty(pts) and List.forAll(p -> near(p#z, 0.01), pts))

    @Test
    def testOffsetIsInSceneUnitsOnAHundredthScaleTarget(): Unit \ Assert =
        let tiny = Scene3d.meshInstance(wallMesh(200.0, white()), Mat4.scale(Vec3.v3(0.01, 0.01, 0.01)));
        let pts = pointsOf(Decal3d.buildInstances({ offset = Some(0.02) | front() } :: Nil, tiny :: Nil));
        Assert.assertTrue(not List.isEmpty(pts) and List.forAll(p -> near(p#z, 0.02), pts))

    @Test
    def testAngleCutoffDropsTheWallSideOfACorner(): Unit \ Assert =
        let backWall = Scene3d.meshInstance(wallMesh(2.0, white()), Mat4.translate(Vec3.v3(0.0, 0.0, -0.3)));
        let onFloor = { size = Vec3.v3(1.0, 1.0, 1.0) | Decal3d.decal(grime(), Vec3.v3(0.0, 0.0, 0.0), Vec3.v3(0.0, 1.0, 0.0)) };
        let pts = pointsOf(Decal3d.buildInstances(onFloor :: Nil, floor() :: backWall :: Nil));
        Assert.assertTrue(not List.isEmpty(pts) and List.forAll(p -> near(p#y, 0.01), pts))

    @Test
    def testUvStaysInsideTheUvRect(): Unit \ Assert =
        let rect = { position = Vec2.v2(0.5, 0.25), size = Vec2.v2(0.25, 0.25) };
        let uvs = Decal3d.buildInstances({ uvRect = rect | front() } :: Nil, wall() :: Nil) |> onlyMesh |> Mesh3d.uvs |> Option.getWithDefault(Vector#{});
        Assert.assertTrue(Vector.length(uvs) > 0 and List.forAll(match (u, v) -> u >= 0.5 - 1.0e-9 and u <= 0.75 + 1.0e-9 and v >= 0.25 - 1.0e-9 and v <= 0.5 + 1.0e-9, pairsOf(uvs)))

    @Test
    def testTopOfTheDecalReadsTheTopOfTheTexture(): Unit \ Assert =
        let mesh = Decal3d.buildInstances(front() :: Nil, wall() :: Nil) |> onlyMesh;
        let ys = pointsOf(Scene3d.meshInstance(mesh, Mat4.identity()) :: Nil) |> List.map(p -> p#y);
        let vs = Mesh3d.uvs(mesh) |> Option.getWithDefault(Vector#{}) |> pairsOf |> List.map(snd);
        Assert.assertTrue(not List.isEmpty(ys) and List.forAll(match (y, v) -> near(v, 0.5 - y), List.zip(ys, vs)))

    /// +z を向く壁を正面（+z の側）から見ると、左手系では画面の右が −x。
    @Test
    def testLeftOfTheDecalReadsTheLeftOfTheTextureSeenFromTheFront(): Unit \ Assert =
        let mesh = Decal3d.buildInstances(front() :: Nil, wall() :: Nil) |> onlyMesh;
        let xs = pointsOf(Scene3d.meshInstance(mesh, Mat4.identity()) :: Nil) |> List.map(p -> p#x);
        let us = Mesh3d.uvs(mesh) |> Option.getWithDefault(Vector#{}) |> pairsOf |> List.map(fst);
        Assert.assertTrue(not List.isEmpty(xs) and List.forAll(match (x, u) -> near(u, 0.5 - x), List.zip(xs, us)))

    @Test
    def testRotationTurnsTheDecalCounterClockwiseSeenFromTheFront(): Unit \ Assert =
        let mesh = Decal3d.buildInstances({ rotation = 90.0 | front() } :: Nil, wall() :: Nil) |> onlyMesh;
        let ys = pointsOf(Scene3d.meshInstance(mesh, Mat4.identity()) :: Nil) |> List.map(p -> p#y);
        let us = Mesh3d.uvs(mesh) |> Option.getWithDefault(Vector#{}) |> pairsOf |> List.map(fst);
        Assert.assertTrue(not List.isEmpty(ys) and List.forAll(match (y, u) -> near(u, 0.5 + y), List.zip(ys, us)))

    @Test
    def testMirroredTargetStillGetsAFloatingPlate(): Unit \ Assert =
        let mirrored = Scene3d.meshInstance(wallMesh(2.0, white()), Mat4.scale(Vec3.v3(-1.0, 1.0, 1.0)));
        let pts = pointsOf(Decal3d.buildInstances(front() :: Nil, mirrored :: Nil));
        Assert.assertTrue(not List.isEmpty(pts) and List.forAll(p -> near(p#z, 0.01), pts))

    @Test
    def testRotatedUnevenlyScaledTargetFloatsAlongItsWorldNormal(): Unit \ Assert =
        let turned = Scene3d.meshInstance(wallMesh(2.0, white()), Mat4.mul(Mat4.rotateY(PortableMath.pi() / 2.0), Mat4.scale(Vec3.v3(1.0, 3.0, 2.0))));
        let pts = pointsOf(Decal3d.buildInstances(Decal3d.decal(grime(), Vec3.v3(0.0, 0.0, 0.0), Vec3.v3(1.0, 0.0, 0.0)) :: Nil, turned :: Nil));
        Assert.assertTrue(not List.isEmpty(pts) and List.forAll(p -> near(p#x, 0.01), pts))

    @Test
    def testVertexColorIsBlendedByPosition(): Unit \ Assert =
        let mesh = match Mesh3d.fromArrays({ positions = Vector#{-2.0, -2.0, 0.0, -2.0, 2.0, 0.0, 2.0, 2.0, 0.0, 2.0, -2.0, 0.0},
                                              normals = Vector#{0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0},
                                              colors = Vector#{0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0},
                                              indices = Vector#{0, 1, 2, 0, 2, 3}, skin = None }) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        };
        let out = Decal3d.buildInstances(front() :: Nil, Scene3d.meshInstance(mesh, Mat4.identity()) :: Nil) |> onlyMesh;
        let xs = pointsOf(Scene3d.meshInstance(out, Mat4.identity()) :: Nil) |> List.map(p -> p#x);
        let c = Mesh3d.colors(out);
        let reds = List.range(0, Vector.length(c) / 3) |> List.map(k -> Vector.get(k * 3, c));
        Assert.assertTrue(not List.isEmpty(xs) and List.forAll(match (x, r) -> Float64.abs(r - (x + 2.0) / 4.0) < 1.0e-9, List.zip(xs, reds)))

    @Test
    def testPlateCarriesTheTargetTint(): Unit \ Assert =
        let tinted = wall() |> Scene3d.withTint(Color.rgb(0.5, 0.25, 1.0));
        let out = Decal3d.buildInstances(front() :: Nil, tinted :: Nil);
        Assert.assertEq(expected = (0.5, 0.25, 1.0) :: Nil, List.map(i -> (fieldsOf(i)#tint#r, fieldsOf(i)#tint#g, fieldsOf(i)#tint#b), out))

    def litWall(): Scene3d.Instance3d =
        let mesh = match Mesh3d.withUvs2(Vector#{0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0}, wallMesh(2.0, white())) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        };
        let lm = { uvRect = { position = Vec2.v2(0.5, 0.5), size = Vec2.v2(0.5, 0.5) } | Scene3d.lightmap(Texture3d.namePrefix() + "0123456789abcdef") };
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(grime()) |> Scene3d.withLightmap(lm)

    @Test
    def testUv2HasTheTargetLightmapRectApplied(): Unit \ Assert =
        let uv2 = Decal3d.buildInstances(front() :: Nil, litWall() :: Nil) |> onlyMesh |> Mesh3d.uvs2 |> Option.getWithDefault(Vector#{});
        Assert.assertTrue(Vector.length(uv2) > 0 and List.forAll(match (u, v) -> u >= 0.5 + 0.125 - 1.0e-9 and u <= 0.75 + 0.125 + 1.0e-9 and v >= 0.625 - 1.0e-9 and v <= 0.875 + 1.0e-9, pairsOf(uv2)))

    @Test
    def testPlateLightmapReadsTheWholeTexture(): Unit \ Assert =
        let rects = Decal3d.buildInstances(front() :: Nil, litWall() :: Nil)
            |> List.map(i -> Scene3d.lightmapOf(i) |> Option.map(lm -> (lm#uvRect#position#x, lm#uvRect#position#y, lm#uvRect#size#x, lm#uvRect#size#y)));
        Assert.assertEq(expected = Some((0.0, 0.0, 1.0, 1.0)) :: Nil, rects)

    @Test
    def testOpaqueMaterialBecomesBlended(): Unit \ Assert =
        let out = Decal3d.buildInstances(front() :: Nil, wall() :: Nil);
        Assert.assertEq(expected = true :: Nil, List.map(i -> Scene3d.isBlendedFields(fieldsOf(i)), out))

    @Test
    def testCutoutMaterialStaysOpaque(): Unit \ Assert =
        let out = Decal3d.buildInstances({ material = Scene3d.withCutout(true, grime()) | front() } :: Nil, wall() :: Nil);
        Assert.assertEq(expected = false :: Nil, List.map(i -> Scene3d.isBlendedFields(fieldsOf(i)), out))

    // ── つなぎと並び ──

    @Test
    def testTwoDecalsOfOneMaterialOnOneTargetBecomeOneInstance(): Unit \ Assert =
        let second = { center = Vec3.v3(1.0, 0.0, 0.0) | front() };
        Assert.assertEq(expected = 1, List.length(Decal3d.buildInstances(front() :: second :: Nil, wall() :: Nil)))

    @Test
    def testLaterDecalIsDrawnAfter(): Unit \ Assert =
        let second = { size = Vec3.v3(0.2, 0.2, 0.5), center = Vec3.v3(1.5, 1.5, 0.0) | front() };
        let pts = pointsOf(Decal3d.buildInstances(front() :: second :: Nil, wall() :: Nil));
        Assert.assertTrue(List.last(pts) |> Option.exists(p -> p#x > 1.0 and p#y > 1.0))

    @Test
    def testPlatesOnSeparateTargetsAreSeparateInstances(): Unit \ Assert =
        let other = Scene3d.meshInstance(wallMesh(2.0, white()), Mat4.translate(Vec3.v3(1.0, 0.0, 0.0)));
        Assert.assertEq(expected = 2, List.length(Decal3d.buildInstances(front() :: Nil, wall() :: other :: Nil)))

    @Test
    def testDecalsDifferingOnlyInNormalMapAreSeparateInstances(): Unit \ Assert =
        let bumpy = { material = Scene3d.withNormalMap({ texture = "tex3d:bump", strength = 1.0 }, grime()) | front() };
        Assert.assertEq(expected = 2, List.length(Decal3d.buildInstances(front() :: bumpy :: Nil, wall() :: Nil)))

    @Test
    def testNamesCountMaterialsOnATarget(): Unit \ Assert =
        let bumpy = { material = Scene3d.withNormalMap({ texture = "tex3d:bump", strength = 1.0 }, grime()) | front() };
        Assert.assertEq(expected = "wall:decal1" :: "wall:decal2" :: Nil, List.map(Scene3d.nameOf, Decal3d.buildInstances(front() :: bumpy :: Nil, wall() :: Nil)))

    @Test
    def testSingleMaterialPlateIsNamedAfterTheTarget(): Unit \ Assert =
        Assert.assertEq(expected = "wall:decal" :: Nil, List.map(Scene3d.nameOf, Decal3d.buildInstances(front() :: Nil, wall() :: Nil)))

    @Test
    def testPlateWorldIsIdentity(): Unit \ Assert =
        let shifted = Scene3d.meshInstance(wallMesh(2.0, white()), Mat4.translate(Vec3.v3(0.0, 0.0, 1.0)));
        let out = Decal3d.buildInstances({ center = Vec3.v3(0.0, 0.0, 1.0) | front() } :: Nil, shifted :: Nil);
        Assert.assertEq(expected = Mat4.asRows(Mat4.identity()) :: Nil, List.map(i -> Mat4.asRows(fieldsOf(i)#world), out))

    @Test
    def testMissingTheTargetsGivesNothing(): Unit \ Assert =
        Assert.assertEq(expected = 0, List.length(Decal3d.buildInstances({ center = Vec3.v3(9.0, 9.0, 9.0) | front() } :: Nil, wall() :: Nil)))

    @Test
    def testSameInputGivesTheSameShape(): Unit \ Assert =
        let hashOf = () -> Decal3d.buildInstances({ rotation = 30.0 | front() } :: Nil, wall() :: Nil) |> List.map(i -> Mesh3d.contentHash(fieldsOf(i)#mesh));
        Assert.assertEq(expected = hashOf(), hashOf())

    // ── 飛ばす的 ──

    def skinnedWall(): Scene3d.Instance3d =
        let base = wallMesh(2.0, white());
        let mesh = match Mesh3d.fromArrays({ positions = Mesh3d.positions(base), normals = Mesh3d.normals(base), colors = Mesh3d.colors(base),
                                              indices = Mesh3d.indices(base),
                                              skin = Some({ joints = Vector.repeat(16, 0), weights = Vector#{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0} }) }) {
            case Ok(m)  => m
            case Err(e) => bug!(e)
        };
        Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withName("ghost")

    @Test
    def testSkinnedTargetGetsNoPlate(): Unit \ Assert =
        let (placed, _) = Decal3d.Internal.Merge.build(front() :: Nil, skinnedWall() :: Nil);
        Assert.assertEq(expected = 0, List.length(placed))

    @Test
    def testSkinnedTargetIsReportedInOneLine(): Unit \ Assert =
        let (_, lines) = Decal3d.Internal.Merge.build(front() :: Nil, skinnedWall() :: Nil);
        Assert.assertEq(expected = "@decal-skinned-target decal3d: 骨つきの的 ghost には貼らない — 飛ばす" :: Nil, lines)

    @Test
    def testBlendedTargetIsReportedInOneLine(): Unit \ Assert =
        let glass = wall() |> Scene3d.withMaterial(Scene3d.withAlphaBlend(true, grime()));
        let (_, lines) = Decal3d.Internal.Merge.build(front() :: Nil, glass :: Nil);
        Assert.assertEq(expected = "@decal-blended-target decal3d: 半透明の的 wall には貼らない — 飛ばす" :: Nil, lines)

    @Test
    def testSkippedTargetAwayFromTheBoxIsQuiet(): Unit \ Assert =
        let (_, lines) = Decal3d.Internal.Merge.build({ center = Vec3.v3(9.0, 9.0, 9.0) | front() } :: Nil, skinnedWall() :: Nil);
        Assert.assertEq(expected = Nil, lines)

    // ── 材質の鍵 ──

    @Test
    def testFullMaterialKeyChangesWithEveryField(): Unit \ Assert =
        let keyOf = m -> Scene3d.Internal.MaterialKey.fullMaterialKeyOf(Scene3d.materialFieldsOf(m));
        let base = grime();
        let variants = base :: Scene3d.withAlphaBlend(true, base) :: Scene3d.withCutout(true, base) :: Scene3d.withDoubleSided(true, base)
            :: Scene3d.withNormalMap({ texture = "tex3d:bump", strength = 1.0 }, base) :: Scene3d.withNormalMap({ texture = "tex3d:bump", strength = 0.5 }, base)
            :: Scene3d.withMetallicRoughness(0.0, 0.5, base) :: Scene3d.withMetallicRoughness(1.0, 0.5, base)
            :: Scene3d.withMetallicRoughnessTexture("tex3d:mr", Scene3d.withMetallicRoughness(1.0, 0.5, base))
            :: Scene3d.withEmissionIntensity(2.0, base) :: Scene3d.withWrap(Scene3d.Wrap.Clamp, base) :: Scene3d.withMaxMipLevels(1, base)
            :: Scene3d.Internal.MaterialFlags.withScreenAoOnBlend(base) :: Nil;
        Assert.assertEq(expected = List.length(variants), List.map(keyOf, variants) |> List.toSet |> Set.size)
}
