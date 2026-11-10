// 視錐台（Camera3d.frustum・Frustum）と、描き手が使う間引きの判定（Scene3d.isOutsideFrustum・isBillboardOutsideFrustum・worldBoundsOf）。
mod TestFrustum {

    /// 原点から +Z を向くカメラ（縦の画角 90°・near 1・far 100・縦横の比 1）。
    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = Num.pi() / 2.0, near = 1.0, far = 100.0 }

    def frustum(): Frustum.Frustum = Camera3d.frustum(camera(), 1.0)

    /// 一辺 2 の箱（形の座標 −1..1）を center に置いた物。
    def boxAt(center: Vec3.Vec3): Scene3d.Instance3d =
        let cube = Mesh3d.fromPolygons({ points = Vec3.v3(-1.0, -1.0, -1.0) :: Vec3.v3(1.0, -1.0, -1.0) :: Vec3.v3(1.0, 1.0, 1.0) :: Nil,
                                         color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        Scene3d.meshInstance(cube, Mat4.translate(center))

    // ════════════════════════════════════════════════════════════════════
    // 点
    // ════════════════════════════════════════════════════════════════════

    /// 目の前は中・目の後ろ・横の外・far の向こう・near の手前は外。
    @Test
    def testPointsInsideAndOutside(): Unit \ Assert =
        let f = frustum();
        Assert.assertEq(expected = true :: false :: false :: false :: false :: Nil,
            Frustum.containsPoint(f, Vec3.v3(0.0, 0.0, 10.0)) :: Frustum.containsPoint(f, Vec3.v3(0.0, 0.0, -10.0))
                :: Frustum.containsPoint(f, Vec3.v3(20.0, 0.0, 10.0)) :: Frustum.containsPoint(f, Vec3.v3(0.0, 0.0, 200.0))
                :: Frustum.containsPoint(f, Vec3.v3(0.0, 0.0, 0.5)) :: Nil)

    // ════════════════════════════════════════════════════════════════════
    // 箱と球
    // ════════════════════════════════════════════════════════════════════

    /// 横の面（x = z の 45° の面）をまたぐ箱は中、全部外の箱は外。
    @Test
    def testBoxStraddlingAPlaneIsInside(): Unit \ Assert =
        let f = frustum();
        let min = Vec3.v3(-1.0, -1.0, -1.0);
        let max = Vec3.v3(1.0, 1.0, 1.0);
        Assert.assertEq(expected = (true, false),
            (Frustum.intersectsBox(f, min, max, Mat4.translate(Vec3.v3(10.0, 0.0, 10.0))),
             Frustum.intersectsBox(f, min, max, Mat4.translate(Vec3.v3(13.0, 0.0, 10.0)))))

    /// 回した箱: x に長い箱（x ±3・z ±1）を (14.1, 0, 10) に置く。そのままは横の面の外・+45° 回すと角が面の内側へ入って中・−45° は外のまま
    /// （回す向きを取り違えて行列を転置すると、この 2 つが入れ替わる）。
    @Test
    def testRotatedBoxFollowsTheMatrix(): Unit \ Assert =
        let f = frustum();
        let min = Vec3.v3(-3.0, -1.0, -1.0);
        let max = Vec3.v3(3.0, 1.0, 1.0);
        let at = Mat4.translate(Vec3.v3(14.1, 0.0, 10.0));
        let quarter = Num.pi() / 4.0;
        Assert.assertEq(expected = (false, true, false),
            (Frustum.intersectsBox(f, min, max, at), Frustum.intersectsBox(f, min, max, Mat4.mul(at, Mat4.rotateY(quarter))),
             Frustum.intersectsBox(f, min, max, Mat4.mul(at, Mat4.rotateY(0.0 - quarter)))))

    /// asRows は行優先の 16 個（平行移動は 3・7・11 番目）。
    @Test
    def testAsRowsIsRowMajor(): Unit \ Assert =
        let rows = Mat4.asRows(Mat4.translate(Vec3.v3(5.0, 6.0, 7.0)));
        Assert.assertEq(expected = (16, 5.0, 6.0, 7.0), (Vector.length(rows), Vector.get(3, rows), Vector.get(7, rows), Vector.get(11, rows)))

    /// 球は半径の分だけ外へ届く: 中心が横の面から 2 の所の半径 3 は中・半径 1 は外。
    @Test
    def testSphereReachesByRadius(): Unit \ Assert =
        let f = frustum();
        let center = Vec3.v3(10.0 + 2.0 * Num.sqrt(2.0), 0.0, 10.0);
        Assert.assertEq(expected = (true, false), (Frustum.intersectsSphere(f, center, 3.0), Frustum.intersectsSphere(f, center, 1.0)))

    // ════════════════════════════════════════════════════════════════════
    // 描き手の判定
    // ════════════════════════════════════════════════════════════════════

    /// 置いた物: 目の前は描く・後ろは間引く。
    @Test
    def testInstanceBehindIsOutside(): Unit \ Assert =
        let f = frustum();
        Assert.assertEq(expected = (false, true),
            (Scene3d.isOutsideFrustum(f, boxAt(Vec3.v3(0.0, 0.0, 10.0))), Scene3d.isOutsideFrustum(f, boxAt(Vec3.v3(0.0, 0.0, -10.0)))))

    /// 骨つきの物は Pose で形が境界の外へ出うるので、後ろでも間引かない。world の境界も None。
    @Test
    def testSkinnedInstanceIsNeverOutside(): Unit \ Assert =
        let skin = TestFrustum.oneJointSkin();
        let mesh = TestFrustum.oneJointMesh();
        let posed = Scene3d.meshInstance(mesh, Mat4.translate(Vec3.v3(0.0, 0.0, -10.0))) |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin)));
        Assert.assertEq(expected = (false, true), (Scene3d.isOutsideFrustum(frustum(), posed), Option.isEmpty(Scene3d.worldBoundsOf(posed))))

    /// ビルボードは外接球で見る: 足元の真ん中（anchor (0.5, 1)）が後ろでも、高さ 30 の絵は前へ届かないので外、
    /// 横の面のすぐ外に足元がある幅 4 の絵は中。
    @Test
    def testBillboardUsesBoundingSphere(): Unit \ Assert =
        let f = frustum();
        let behind = Scene3d.billboard("tree", { position = Vec2.zero(), size = { x = 8.0, y = 8.0 } }, Vec3.v3(0.0, 0.0, -40.0), { x = 2.0, y = 30.0 });
        let edge = Scene3d.billboard("tree", { position = Vec2.zero(), size = { x = 8.0, y = 8.0 } }, Vec3.v3(11.0, 0.0, 10.0), { x = 4.0, y = 1.0 });
        Assert.assertEq(expected = (true, false), (Scene3d.isBillboardOutsideFrustum(f, behind), Scene3d.isBillboardOutsideFrustum(f, edge)))

    /// worldBoundsOf は形の境界の 8 つの角を world で写した AABB（一辺 2 の箱を (0, 0, 10) へ）。
    @Test
    def testWorldBoundsOfTranslatedBox(): Unit \ Assert =
        Assert.assertEq(expected = Some(((-1.0, -1.0, 9.0), (1.0, 1.0, 11.0))),
            Scene3d.worldBoundsOf(boxAt(Vec3.v3(0.0, 0.0, 10.0))) |> Option.map(b -> ((b#min#x, b#min#y, b#min#z), (b#max#x, b#max#y, b#max#z))))

    // ── 骨つきの形（1 本のジョイントに重み 1）──

    def oneJointSkin(): Skin3d.Skin3d = match Skin3d.make({ names = Vector#{ "root" }, parents = Vector#{ -1 },
                                                            rest = Vector#{ { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() } },
                                                            inverseBinds = None, rootTransform = Mat4.identity() }) {
        case Ok(s)  => s
        case Err(e) => bug!(e)
    }

    def oneJointMesh(): Mesh3d.Mesh3d = match Mesh3d.fromArrays({
        positions = Vector#{ -1.0, -1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0 }, normals = Vector#{ 0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, -1.0 },
        colors = Vector#{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 }, indices = Vector#{ 0, 1, 2 },
        skin = Some({ joints = Vector#{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, weights = Vector#{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0 } }) }) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    }
}
