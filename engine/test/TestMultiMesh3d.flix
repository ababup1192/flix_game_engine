// 同じ形をたくさん置く物（MultiMesh3d）の作り方・境界・材質・1 体ずつへの作り直しと、場面の描く物の数え方（Scene3d.instancesOf・hasDrawnInstance）。
mod TestMultiMesh3d {

    def box(): Mesh3d.Mesh3d =
        Mesh3d.fromPolygons({ points = Vec3.v3(-0.5, -0.5, -0.5) :: Vec3.v3(0.5, -0.5, -0.5) :: Vec3.v3(0.5, 0.5, 0.5) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil)

    // i 体目: 回して軸ごとに伸ばし、格子に置いた行列。
    def worldAt(i: Int32): Mat4.Mat4 =
        let f = Int32.toFloat64(i);
        Mat4.mul(Mat4.translate(Vec3.v3(f * 2.0 - 5.0, 0.5 * f, 3.0 - f)), Mat4.mul(Mat4.rotateY(0.7 * f), Mat4.scale(Vec3.v3(1.0 + 0.1 * f, 0.5, 2.0))))

    def crowd(n: Int32): MultiMesh3d.MultiMesh3d = MultiMesh3d.build(box(), n, worldAt)

    def glass(): Scene3d.Material3d =
        Scene3d.material({ name = "glass", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.2, g = 0.5, b = 0.9 }), alpha = ShaderDoc.Field.Const(0.5) }) })
            |> Scene3d.withAlphaBlend(true)

    /// 体の数は build の数・並びは 1 体 12 個で、i 体目の行列の上の 3 行と同じ。
    @Test
    def testBuildKeepsTheTopThreeRows(): Unit \ Assert =
        let mm = crowd(5);
        let rows = (i: Int32) -> Mat4.asRows(worldAt(i)) |> Vector.toList |> List.take(12);
        let held = (i: Int32) -> MultiMesh3d.fieldsOf(mm)#transforms |> Vector.toList |> List.drop(i * 12) |> List.take(12);
        Assert.assertEq(expected = (5, rows(0), rows(4)), (MultiMesh3d.countOf(mm), held(0), held(4)))

    /// 0 体と負の数は 0 体・境界は無い。
    @Test
    def testZeroOrNegativeCountIsEmpty(): Unit \ Assert =
        Assert.assertEq(expected = (0, 0, true), (MultiMesh3d.countOf(crowd(0)), MultiMesh3d.countOf(crowd(-3)), Option.isEmpty(MultiMesh3d.fieldsOf(crowd(0))#bounds)))

    /// 群れ全体の境界は、どの体の形の角も中に含む。
    @Test
    def testBoundsHoldEveryCorner(): Unit \ Assert =
        let mm = crowd(7);
        let corners = List.range(0, 7) |> List.flatMap(i -> Mesh3d.cornersOf(Mesh3d.bounds(box())) |> List.map(Mat4.apply(worldAt(i))));
        let inside = (b: Mesh3d.Bounds, p: Vec3.Vec3) ->
            p#x >= b#min#x and p#y >= b#min#y and p#z >= b#min#z and p#x <= b#max#x and p#y <= b#max#y and p#z <= b#max#z;
        let held = MultiMesh3d.fieldsOf(mm)#bounds |> Option.map(b -> List.forAll(inside(b), corners));
        Assert.assertEq(expected = Some(true), held)

    /// 半透明の材質は、blend を落とした材質で持ち、頼まれた事を残す。不透明の材質はそのまま。
    @Test
    def testBlendIsDroppedOnceAndRemembered(): Unit \ Assert =
        let seeThrough = MultiMesh3d.fieldsOf(crowd(2) |> MultiMesh3d.withMaterial(glass()));
        let opaque = MultiMesh3d.fieldsOf(crowd(2) |> MultiMesh3d.withMaterial(Scene3d.withAlphaBlend(false, glass())));
        let blendOf = (r: MultiMesh3d.MultiMeshFields) -> r#material |> Option.map(m -> Scene3d.materialFieldsOf(m)#blend);
        Assert.assertEq(expected = (Some(false), true, Some(false), false), (blendOf(seeThrough), seeThrough#blendRequested, blendOf(opaque), opaque#blendRequested))

    /// 1 体ずつに作り直した物は、行列・色・材質が build と withColors と withMaterial のとおり。
    @Test
    def testToInstancesRebuildsEachOne(): Unit \ Assert =
        let colorOf = (i: Int32) -> Color.rgb(0.1 * Int32.toFloat64(i), 0.5, 1.0);
        let mm = crowd(3) |> MultiMesh3d.withColors(colorOf) |> MultiMesh3d.withMaterial(glass());
        let fields = MultiMesh3d.toInstances(mm) |> List.map(Scene3d.instanceFieldsOf);
        let worlds = fields |> List.map(f -> Mat4.asRows(f#world));
        let tints = fields |> List.map(f -> (f#tint#r, f#tint#g, f#tint#b));
        let blends = fields |> List.map(f -> f#material |> Option.map(m -> Scene3d.materialFieldsOf(m)#blend));
        Assert.assertEq(expected = (List.range(0, 3) |> List.map(i -> Mat4.asRows(worldAt(i))), List.range(0, 3) |> List.map(colorOf) |> List.map(c -> (c#r, c#g, c#b)), List.repeat(3, Some(false))),
                        (worlds, tints, blends))

    /// 場面の描く物の全部は、instances・集まりの物・MultiMesh の体の順。
    @Test
    def testInstancesOfPutsMultiMeshesLast(): Unit \ Assert =
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() };
        let one = Scene3d.meshInstance(box(), Mat4.translate(Vec3.v3(9.0, 9.0, 9.0)));
        let group = Scene3d.staticGroup("g", ("a", one) :: Nil);
        let scene = { instances = one :: Nil, groups = group :: Nil, multiMeshes = crowd(2) :: Nil | Scene3d.scene(camera, Vec2.v2(64.0, 64.0)) };
        let worlds = Scene3d.instancesOf(scene) |> List.map(i -> Vector.get(3, Mat4.asRows(Scene3d.instanceFieldsOf(i)#world)));
        Assert.assertEq(expected = 9.0 :: 9.0 :: -5.0 :: -3.0 :: Nil, worlds)

    /// MultiMesh だけの場面は描く物がある（影を落とす光が場面を見る）。0 体の MultiMesh だけなら無い。
    @Test
    def testMultiMeshOnlySceneHasDrawnInstance(): Unit \ Assert =
        let camera = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() };
        let sceneWith = (mm: MultiMesh3d.MultiMesh3d) -> { multiMeshes = mm :: Nil | Scene3d.scene(camera, Vec2.v2(64.0, 64.0)) };
        Assert.assertEq(expected = (true, false), (Scene3d.hasDrawnInstance(sceneWith(crowd(1))), Scene3d.hasDrawnInstance(sceneWith(crowd(0)))))
}
