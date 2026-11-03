// レイ（Ray3d）と、カメラから伸ばすレイ（Camera3d.forwardRay・screenPointToRay）: 箱・球・カプセル・三角形・形との交わりと、
// 名前つきの的から一番近い物を選ぶ pickNearest。期待値は一辺 2 の箱と、軸に沿ったレイで手で出せる距離。
mod TestRay3d {

    def r1000(f: Float64): Int32 = Num.roundInt(f * 1000.0)

    def mm(v: Vec3.Vec3): (Int32, Int32, Int32) = (r1000(v#x), r1000(v#y), r1000(v#z))

    /// 当たった所を (距離, 点, 面の向き) の mm にした値。
    def hitMm(h: Ray3d.RayHit): (Int32, (Int32, Int32, Int32), (Int32, Int32, Int32)) = (r1000(h#distance), mm(h#point), mm(h#normal))

    def cube(): CollisionShape3d.Box3d = CollisionShape3d.box3d(Vec3.zero(), Vec3.v3(1.0, 1.0, 1.0))

    def alongZ(start: Vec3.Vec3): Ray3d.Ray3d = Ray3d.ray3d(start, Vec3.v3(0.0, 0.0, 1.0))

    // ════════════════════════════════════════════════════════════════════
    // 箱
    // ════════════════════════════════════════════════════════════════════

    /// (0, 0, −5) から +Z へ: z = −1 の面に距離 4 で当たり、面の向きはレイの来た側（−Z）。
    @Test
    def testHitBoxHead(): Unit \ Assert =
        Assert.assertEq(expected = Some((4000, (0, 0, -1000), (0, 0, -1000))),
            Ray3d.hitBox(alongZ(Vec3.v3(0.0, 0.0, -5.0)), 100.0, cube()) |> Option.map(hitMm))

    /// (−3, 0, −2) から (1, 0, 1) の向きへ: x = −1 の面に距離 2√2（≒ 2.828）で当たる。
    @Test
    def testHitBoxOblique(): Unit \ Assert =
        Assert.assertEq(expected = Some((2828, (-1000, 0, 0), (-1000, 0, 0))),
            Ray3d.hitBox(Ray3d.ray3d(Vec3.v3(-3.0, 0.0, -2.0), Vec3.v3(1.0, 0.0, 1.0)), 100.0, cube()) |> Option.map(hitMm))

    /// 箱の中から・面に平行で外れる・maxDistance（3）の外・向きが 0 のレイは、どれも当たらない。
    @Test
    def testHitBoxMisses(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, true, true),
            (Option.isEmpty(Ray3d.hitBox(alongZ(Vec3.zero()), 100.0, cube())), Option.isEmpty(Ray3d.hitBox(alongZ(Vec3.v3(0.0, 2.0, -5.0)), 100.0, cube())),
             Option.isEmpty(Ray3d.hitBox(alongZ(Vec3.v3(0.0, 0.0, -5.0)), 3.0, cube())),
             Option.isEmpty(Ray3d.hitBox(Ray3d.ray3d(Vec3.v3(0.0, 0.0, -5.0), Vec3.zero()), 100.0, cube()))))

    /// Y まわりに 45° 回した一辺 2 の箱は、角が z = −√2 に来るので、(0, 0, −5) からの距離は 5 − √2（≒ 3.586）。
    @Test
    def testHitRotatedBox(): Unit \ Assert =
        let turned = CollisionShape3d.transformBox(Mat4.rotateY(Vec2.pi() / 4.0), cube());
        Assert.assertEq(expected = Some(3586),
            Ray3d.hitBox(alongZ(Vec3.v3(0.0, 0.0, -5.0)), 100.0, turned) |> Option.map(h -> r1000(h#distance)))

    // ════════════════════════════════════════════════════════════════════
    // 球とカプセル
    // ════════════════════════════════════════════════════════════════════

    /// 原点から +Z へ: z = 10・半径 1 の球に距離 9 で当たる。球の中からは当たらない。
    @Test
    def testHitSphere(): Unit \ Assert =
        let s = { center = Vec3.v3(0.0, 0.0, 10.0), radius = 1.0 };
        Assert.assertEq(expected = (Some((9000, (0, 0, 9000), (0, 0, -1000))), None),
            (Ray3d.hitSphere(alongZ(Vec3.zero()), 100.0, s) |> Option.map(hitMm), Ray3d.hitSphere(alongZ(Vec3.v3(0.0, 0.0, 10.0)), 100.0, s) |> Option.map(hitMm)))

    /// 足元 (0, 0, 5)・半径 0.5・高さ 2 のカプセル: 横から（高さ 1）は筒に距離 4.5、真上（高さ 5）から下へは上の端（高さ 2）に距離 3。
    @Test
    def testHitCapsuleSideAndTop(): Unit \ Assert =
        let c = { feet = Vec3.v3(0.0, 0.0, 5.0), radius = 0.5, height = 2.0 };
        Assert.assertEq(expected = (Some((4500, (0, 1000, 4500), (0, 0, -1000))), Some((3000, (0, 2000, 5000), (0, 1000, 0)))),
            (Ray3d.hitCapsule(alongZ(Vec3.v3(0.0, 1.0, 0.0)), 100.0, c) |> Option.map(hitMm),
             Ray3d.hitCapsule(Ray3d.ray3d(Vec3.v3(0.0, 5.0, 5.0), Vec3.v3(0.0, -1.0, 0.0)), 100.0, c) |> Option.map(hitMm)))

    // ════════════════════════════════════════════════════════════════════
    // 三角形と形
    // ════════════════════════════════════════════════════════════════════

    def triangleHit(start: Vec3.Vec3, toward: Vec3.Vec3): Option[(Int32, (Int32, Int32, Int32), (Int32, Int32, Int32))] =
        Ray3d.hitTriangle(Ray3d.ray3d(start, toward), 100.0, Vec3.v3(-1.0, -1.0, 0.0), Vec3.v3(1.0, -1.0, 0.0), Vec3.v3(0.0, 1.0, 0.0)) |> Option.map(hitMm)

    /// z = 0 の三角形: 表（−Z 側）からも裏（+Z 側）からも距離 5 で当たり、面の向きはレイの来た側。縁（y = −1）にも当たり、外（x = 2）は外れる。
    @Test
    def testHitTriangleBothSidesAndEdge(): Unit \ Assert =
        Assert.assertEq(expected = (Some((5000, (0, 0, 0), (0, 0, -1000))), Some((5000, (0, 0, 0), (0, 0, 1000))),
                                    Some((5000, (0, -1000, 0), (0, 0, -1000))), None),
            (triangleHit(Vec3.v3(0.0, 0.0, -5.0), Vec3.v3(0.0, 0.0, 1.0)), triangleHit(Vec3.v3(0.0, 0.0, 5.0), Vec3.v3(0.0, 0.0, -1.0)),
             triangleHit(Vec3.v3(0.0, -1.0, -5.0), Vec3.v3(0.0, 0.0, 1.0)), triangleHit(Vec3.v3(2.0, 0.0, -5.0), Vec3.v3(0.0, 0.0, 1.0))))

    /// z = 0 の四角形を z = 3 へ置いた形に、原点から +Z へ距離 3 で当たる（形の座標から world へ写してから見る）。
    @Test
    def testHitMeshUsesWorld(): Unit \ Assert =
        let quad = Mesh3d.fromPolygons({ points = Vec3.v3(-1.0, -1.0, 0.0) :: Vec3.v3(-1.0, 1.0, 0.0) :: Vec3.v3(1.0, 1.0, 0.0) :: Vec3.v3(1.0, -1.0, 0.0) :: Nil,
                                         color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        Assert.assertEq(expected = Some(3000),
            Ray3d.hitMesh(alongZ(Vec3.zero()), 100.0, quad, Mat4.translate(Vec3.v3(0.0, 0.0, 3.0))) |> Option.map(h -> r1000(h#distance)))

    // ════════════════════════════════════════════════════════════════════
    // カメラから
    // ════════════════════════════════════════════════════════════════════

    def camera(): Camera3d.Camera3d = { eye = Vec3.v3(1.0, 1.5, -2.0), yaw = 0.3, pitch = 0.2, fovY = 1.0, near = 0.1, far = 100.0 }

    /// 描き物の真ん中の点のレイは、目から見ている向きのレイと同じ（向きの差が 1e-9 より小さい）。
    @Test
    def testScreenCenterRayIsForwardRay(): Unit \ Assert =
        let center = Camera3d.screenPointToRay(camera(), Vec2.v2(200.0, 100.0), Vec2.v2(100.0, 50.0));
        let forward = Camera3d.forwardRay(camera());
        Assert.assertTrue(Vec3.length(Vec3.sub(Ray3d.direction(center), Ray3d.direction(forward))) < 1.0e-9
                          and mm(Ray3d.origin(center)) == mm(Ray3d.origin(forward)))

    /// 3D の点 p が写る描き物の点から伸ばしたレイは、p を通る（p とレイの一番近い点の差が 1e-6 より小さい）。
    @Test
    def testScreenPointRayPassesThroughProjectedPoint(): Unit \ Assert =
        let size = Vec2.v2(320.0, 180.0);
        let p = Vec3.v3(2.0, 2.0, 6.0);
        let ray = Camera3d.worldToScreen(camera(), size, p) |> Option.map(Camera3d.screenPointToRay(camera(), size));
        let gap = ray |> Option.map(r -> Vec3.length(Vec3.sub(p, Ray3d.pointAt(r, Vec3.dot(Vec3.sub(p, Ray3d.origin(r)), Ray3d.direction(r))))));
        Assert.assertTrue(gap |> Option.exists(g -> g < 1.0e-6))

    // ════════════════════════════════════════════════════════════════════
    // 名前つきの的から一番近い物
    // ════════════════════════════════════════════════════════════════════

    def boxAt(z: Float64): Ray3d.RayTarget =
        Ray3d.RayTarget.Shape(CollisionShape3d.BoxShape3d(CollisionShape3d.box3d(Vec3.v3(0.0, 0.0, z), Vec3.v3(1.0, 1.0, 0.1))))

    /// 奥の物（z = 5）の手前に壁（z = 2）があると壁を選び、壁が無ければ物を選ぶ。同じ所の 2 つは並びの前。maxDistance（1）の外は None。
    @Test
    def testPickNearestWallHidesItemAndTieKeepsFirst(): Unit \ Assert =
        let ray = alongZ(Vec3.zero());
        let key = (p: Option[(String, Ray3d.RayHit)]) -> Option.map(fst, p);
        Assert.assertEq(expected = (Some("wall"), Some("item"), Some("a"), None),
            (key(Ray3d.pickNearest(ray, 10.0, ("item", boxAt(5.0)) :: ("wall", boxAt(2.0)) :: Nil)),
             key(Ray3d.pickNearest(ray, 10.0, ("item", boxAt(5.0)) :: Nil)),
             key(Ray3d.pickNearest(ray, 10.0, ("a", boxAt(5.0)) :: ("b", boxAt(5.0)) :: Nil)),
             key(Ray3d.pickNearest(ray, 1.0, ("item", boxAt(5.0)) :: Nil))))

    /// 球（z = 3・半径 0.5 → 距離 2.5）とカプセル（z = 2・半径 0.2 → 距離 1.8）を的に入れると、手前のカプセルを選ぶ。
    @Test
    def testPickNearestAcrossShapes(): Unit \ Assert =
        let sphere = Ray3d.RayTarget.Shape(CollisionShape3d.SphereShape3d({ center = Vec3.v3(0.0, 0.0, 3.0), radius = 0.5 }));
        let capsule = Ray3d.RayTarget.Shape(CollisionShape3d.CapsuleShape3d({ feet = Vec3.v3(0.0, -1.0, 2.0), radius = 0.2, height = 2.0 }));
        Assert.assertEq(expected = Some(("capsule", 1800)),
            Ray3d.pickNearest(alongZ(Vec3.zero()), 10.0, ("sphere", sphere) :: ("capsule", capsule) :: Nil) |> Option.map(p -> (fst(p), r1000(snd(p)#distance))))

    /// 置いた物（z = 0 の四角形を z = 3 へ）に原点から +Z へ距離 3 で当たる。
    @Test
    def testHitInstanceUsesInstanceWorld(): Unit \ Assert =
        let quad = Mesh3d.fromPolygons({ points = Vec3.v3(-1.0, -1.0, 0.0) :: Vec3.v3(-1.0, 1.0, 0.0) :: Vec3.v3(1.0, 1.0, 0.0) :: Vec3.v3(1.0, -1.0, 0.0) :: Nil,
                                         color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        Assert.assertEq(expected = Some(3000),
            Ray3d.hitInstance(alongZ(Vec3.zero()), 100.0, Scene3d.meshInstance(quad, Mat4.translate(Vec3.v3(0.0, 0.0, 3.0)))) |> Option.map(h -> r1000(h#distance)))

    /// glTF のノードから作った的: mesh を持つノードだけが的になり、鍵はノードの名前。
    @Test
    def testBoxTargetsOfNodesSkipsEmpties(): Unit \ Assert =
        let node = (name: String, bounds: Option[Mesh3d.Bounds]) ->
            { name = name, parent = None, local = Mat4.identity(), world = Mat4.translate(Vec3.v3(0.0, 0.0, 4.0)), localBounds = bounds, parts = Nil };
        let targets = Ray3d.boxTargetsOf(n -> n#name, node("COL_PRP_box", Some({ min = Vec3.v3(-1.0, -1.0, -1.0), max = Vec3.v3(1.0, 1.0, 1.0) })) :: node("marker", None) :: Nil);
        Assert.assertEq(expected = (1, Some(("COL_PRP_box", 3000))),
            (List.length(targets), Ray3d.pickNearest(alongZ(Vec3.zero()), 10.0, targets) |> Option.map(p -> (fst(p), r1000(snd(p)#distance)))))
}
