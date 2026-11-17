// TestPointShadows — 点光源の影（Scene3d.PointShadows.atlasOf と面の写し）と、光の式の木の変種（LightModel3d.LightVariant）。
mod TestPointShadows {
    use LightModel3d.Vec3Input

    // ════════════════════════════════════════════════════════════════════
    // 共通
    // ════════════════════════════════════════════════════════════════════

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(0.0, 2.0, -10.0), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 }

    def lamp(x: Float64): Scene3d.PointLight =
        { position = Vec3.v3(x, 2.0, 0.0), color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = 6.0 }

    def floorTriangle(): Scene3d.Instance3d =
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(-5.0, 0.0, -5.0) :: Vec3.v3(0.0, 0.0, 5.0) :: Vec3.v3(5.0, 0.0, -5.0) :: Nil,
                                         color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        Scene3d.meshInstance(mesh, Mat4.identity())

    def sceneWith(lamps: List[Scene3d.PointLight], m: Scene3d.PointShadowMap): Scene3d.Scene3dCmd =
        { instances = floorTriangle() :: Nil, pointLights = lamps | Scene3d.scene(camera(), Vec2.v2(160.0, 90.0)) } |> Scene3d.withPointShadows(m)

    def atlasOf(lamps: List[Scene3d.PointLight], m: Scene3d.PointShadowMap): Scene3d.PointShadows.Atlas =
        match Scene3d.PointShadows.atlasOf(sceneWith(lamps, m)) {
            case Some(a) => a
            case None    => bug!("atlasOf が None")
        }

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 1.0e-9

    // ════════════════════════════════════════════════════════════════════
    // 有無
    // ════════════════════════════════════════════════════════════════════

    /// 既定の場面（pointShadows = None）では点光源の影の材料を作らない。
    @Test
    def testDefaultSceneHasNoPointShadows(): Unit \ Assert =
        let scene = { instances = floorTriangle() :: Nil, pointLights = lamp(0.0) :: Nil | Scene3d.scene(camera(), Vec2.v2(160.0, 90.0)) };
        Assert.assertEq(expected = true, Option.isEmpty(Scene3d.PointShadows.atlasOf(scene)))

    /// 置いた物が無い場面では、設定が Some でも影の材料を作らない。
    @Test
    def testEmptySceneHasNoPointShadows(): Unit \ Assert =
        let scene = { pointLights = lamp(0.0) :: Nil | Scene3d.scene(camera(), Vec2.v2(160.0, 90.0)) } |> Scene3d.withPointShadows(Scene3d.pointShadowMap());
        Assert.assertEq(expected = true, Option.isEmpty(Scene3d.PointShadows.atlasOf(scene)))

    /// 影を落とす灯りが 0 本の場面でも、設定が Some なら材料は Some（灯りの出入りでプログラムを替えない）。
    @Test
    def testNoLampStillGivesAtlas(): Unit \ Assert =
        Assert.assertEq(expected = 0, List.length(atlasOf(Nil, Scene3d.pointShadowMap())#lights))

    // ════════════════════════════════════════════════════════════════════
    // 選びと atlas
    // ════════════════════════════════════════════════════════════════════

    /// 上限 2 本なら、画面の真ん中に近い 2 本に slot 0・1 を振る（並びの番号は pickLights の後の番号）。
    @Test
    def testPicksLampsNearestTheScreenCenter(): Unit \ Assert =
        let a = atlasOf(lamp(-8.0) :: lamp(0.0) :: lamp(1.0) :: Nil, { maxShadowedLights = 2 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = (1, 0) :: (2, 1) :: Nil, a#lights |> List.map(l -> (l#pointIndex, l#slot)))

    /// 8 本の上限の atlas は面 512 で 3072 × 4096（4096 に収まる）。
    @Test
    def testEightLightAtlasSize(): Unit \ Assert =
        let a = atlasOf(Nil, { maxShadowedLights = 8 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = (512, 3072, 4096), (a#tileSize, a#width, a#height))

    /// 1 本で mapSize 2048 を頼むと、atlas の幅 3S が 4096 に収まるよう 1365 に縮める。
    @Test
    def testOneLightAtlasShrinksTile(): Unit \ Assert =
        let a = atlasOf(Nil, { maxShadowedLights = 1, mapSize = 2048 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = (1365, 4095, 2730), (a#tileSize, a#width, a#height))

    /// mapSize 16 では pcfRadius を S / 4 − 2 = 2 に縮める（guard band が面の中に収まる）。
    @Test
    def testTinyTileClampsPcf(): Unit \ Assert =
        let a = atlasOf(Nil, { mapSize = 4, pcfRadius = 8 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = (16, 2), (a#tileSize, a#pcfRadius))

    /// 塊の原点: 2 列の並びで slot 3 の面 4（−Y の次の +Z・塊の中の列 1・行 1）は (3S + S, 2S + S)。
    @Test
    def testTileOrigin(): Unit \ Assert =
        let a = atlasOf(Nil, { maxShadowedLights = 4, mapSize = 64 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = (256, 192), Scene3d.PointShadows.tileOriginOf(a, 3, 4))

    // ════════════════════════════════════════════════════════════════════
    // 境の重み
    // ════════════════════════════════════════════════════════════════════

    /// 候補が上限より多い時、最後の 1 本の strength は 1 未満（次の候補に近いほど 0 へ寄る）。前の灯りは 1 のまま。
    @Test
    def testLastShadowedLightFades(): Unit \ Assert =
        let a = atlasOf(lamp(0.0) :: lamp(1.5) :: lamp(1.6) :: Nil, { maxShadowedLights = 2, strength = 1.0 | Scene3d.pointShadowMap() });
        let strengths = a#lights |> List.map(l -> l#strength);
        Assert.assertEq(expected = (1.0, true), (List.head(strengths) |> Option.getWithDefault(0.0), List.last(strengths) |> Option.map(s -> s < 1.0) |> Option.getWithDefault(false)))

    /// 次の候補と同じ点数（入れ替わる瞬間）では、最後の 1 本の strength は 0。
    @Test
    def testSwapWithNextCandidateIsZero(): Unit \ Assert =
        let a = atlasOf(lamp(0.0) :: lamp(3.0) :: lamp(-3.0) :: Nil, { maxShadowedLights = 2, strength = 1.0 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = Some(0.0), a#lights |> List.last |> Option.map(l -> l#strength))

    /// 1 つ前と同じ点数（入れ替わる瞬間）では、両方の strength が 1。
    @Test
    def testSwapWithPreviousKeepsBothFull(): Unit \ Assert =
        let a = atlasOf(lamp(3.0) :: lamp(-3.0) :: lamp(5.0) :: Nil, { maxShadowedLights = 2, strength = 1.0 | Scene3d.pointShadowMap() });
        Assert.assertEq(expected = 1.0 :: 1.0 :: Nil, a#lights |> List.map(l -> l#strength))

    // ════════════════════════════════════════════════════════════════════
    // 面の写し
    // ════════════════════════════════════════════════════════════════════

    /// 6 面とも R × U = F（Camera3d の right × up = forward と同じ向き）。
    @Test
    def testFaceBasesAreRightHandedLikeCamera(): Unit \ Assert =
        let ok = List.range(0, 6) |> List.forAll(f -> {
            let b = Scene3d.PointShadows.basisOf(f);
            let c = Vec3.cross(b#right, b#up);
            near(c#x, b#forward#x) and near(c#y, b#forward#y) and near(c#z, b#forward#z)
        });
        Assert.assertEq(expected = true, ok)

    /// 面の選び: 6 方向のそれぞれが自分の面に写る。
    @Test
    def testFaceOfAxisDirections(): Unit \ Assert =
        let dirs = Vec3.v3(1.0, 0.2, 0.1) :: Vec3.v3(-1.0, 0.2, 0.1) :: Vec3.v3(0.2, 1.0, 0.1) :: Vec3.v3(0.2, -1.0, 0.1) ::
                   Vec3.v3(0.2, 0.1, 1.0) :: Vec3.v3(0.2, 0.1, -1.0) :: Nil;
        Assert.assertEq(expected = 0 :: 1 :: 2 :: 3 :: 4 :: 5 :: Nil, dirs |> List.map(Scene3d.PointShadows.faceOf))

    /// 受ける点の写し（sampleOf の画素と ref）は、面の行列で写した NDC と同じ画素・同じ値（bias 0・normalBias 0）。
    @Test
    def testSampleMatchesFaceMatrix(): Unit \ Assert =
        let a = { bias = 0.0, normalBias = 0.0 | atlasOf(lamp(0.0) :: Nil, { mapSize = 64 | Scene3d.pointShadowMap() }) };
        let light = match List.head(a#lights) { case Some(l) => l case None => bug!("灯りが無い") };
        let points = Vec3.v3(1.3, 0.0, 0.4) :: Vec3.v3(-0.5, 3.5, 0.2) :: Vec3.v3(0.3, 1.0, -2.2) :: Vec3.v3(-2.0, 1.1, 0.9) :: Nil;
        let ok = points |> List.forAll(p -> match Scene3d.PointShadows.sampleOf(a, light, p, Vec3.v3(0.0, 1.0, 0.0)) {
            case None    => false
            case Some(s) => match Mat4.applyPerspective(Vector.get(s#face, light#faces), p) {
                case None      => false
                case Some(ndc) =>
                    let size = Int32.toFloat64(a#tileSize);
                    let tx = Float64.floor((ndc#x * 0.5 + 0.5) * size);
                    let ty = Float64.floor((ndc#y * 0.5 + 0.5) * size);
                    near(tx, Int32.toFloat64(s#x)) and near(ty, Int32.toFloat64(s#y)) and Float64.abs((ndc#z * 0.5 + 0.5) - s#ref) < 1.0e-9
            }
        });
        Assert.assertEq(expected = true, ok)

    /// guard band: 面の端（|d·R| = depth）の点も、地図の外周 pcfRadius + 1 画素の内側に写る。
    @Test
    def testGuardBandKeepsEdgeInside(): Unit \ Assert =
        let a = { normalBias = 0.0 | atlasOf(lamp(0.0) :: Nil, { mapSize = 64, pcfRadius = 2 | Scene3d.pointShadowMap() }) };
        let light = match List.head(a#lights) { case Some(l) => l case None => bug!("灯りが無い") };
        let corner = Vec3.add(light#position, Vec3.v3(1.0, 0.999999, 0.999999));
        let inside = match Scene3d.PointShadows.sampleOf(a, light, corner, Vec3.v3(0.0, 1.0, 0.0)) {
            case Some(s) => s#x >= 3 and s#x <= 60 and s#y >= 3 and s#y <= 60
            case None    => false
        };
        Assert.assertEq(expected = true, inside)

    // ════════════════════════════════════════════════════════════════════
    // 木の変種
    // ════════════════════════════════════════════════════════════════════

    def legacyShaderText(): String =
        let p = Vec3Input.Position;
        let n = Vec3Input.Normal;
        let pbrIn = p :: n :: Vec3Input.Albedo :: Vec3Input.Light :: Vec3Input.MetallicRoughness :: Vec3Input.EnvironmentColor :: Nil;
        LightModel3d.Codegen.toGlsl("lightAt", p :: n :: Nil, LightModel3d.lightingModel()) +
        LightModel3d.Codegen.toGlsl("lightmapLightAt", p :: n :: Vec3Input.LightmapColor :: Nil, LightModel3d.lightmapLightingModel()) +
        LightModel3d.Codegen.toGlsl("pbrAt", pbrIn, LightModel3d.pbrModel()) +
        LightModel3d.Codegen.toWgsl("lightAt", p :: n :: Nil, LightModel3d.lightingModel()) +
        LightModel3d.Codegen.toWgsl("lightmapLightAt", p :: n :: Vec3Input.LightmapColor :: Nil, LightModel3d.lightmapLightingModel()) +
        LightModel3d.Codegen.toWgsl("pbrAt", pbrIn, LightModel3d.pbrModel())

    /// 既定の変種の GLSL と WGSL の字は、変種を足す前の字と同じ（長さと Java の hashCode を変える前の物で固定）。
    @Test
    def testLegacyShaderTextIsUnchanged(): Unit \ Assert =
        let text = legacyShaderText();
        Assert.assertEq(expected = (33498, -1230461854), (String.length(text), text.hashCode()))

    /// 点光源の影の変種は、木の外で埋めた r3d_pointLit[i] を読む。
    @Test
    def testPointShadowVariantReadsPointLit(): Unit \ Assert =
        let v = { pointShadows = true | LightModel3d.legacyVariant() };
        let glsl = LightModel3d.Codegen.toGlsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModelFor(v));
        Assert.assertEq(expected = true, String.contains(substr = "r3d_pointLit[i]", glsl))

    /// Physical の変種は 1 / unitsPerMeter² の uniform を読む（Legacy は読まない）。
    @Test
    def testPhysicalVariantReadsUnitsPerMeter(): Unit \ Assert =
        let physical = { lightUnits = Some(Scene3d.LightUnits.Physical) | LightModel3d.legacyVariant() };
        let glsl = LightModel3d.Codegen.toGlsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModelFor(physical));
        let legacy = LightModel3d.Codegen.toGlsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModel());
        Assert.assertEq(expected = (true, false), (String.contains(substr = "uInverseUnitsPerMeterSquared", glsl),
                                                   String.contains(substr = "uInverseUnitsPerMeterSquared", legacy)))

    /// variantOf は場面の設定どおり（pointShadows が Some なら影を読み、光の量の読み方は場面のまま）。
    @Test
    def testVariantOfScene(): Unit \ Assert =
        let scene = sceneWith(Nil, Scene3d.pointShadowMap()) |> Scene3d.withLightUnits(Scene3d.LightUnits.Physical);
        Assert.assertEq(expected = (true, Some(Scene3d.LightUnits.Physical)), { let v = LightModel3d.variantOf(scene); (v#pointShadows, v#lightUnits) })
}
