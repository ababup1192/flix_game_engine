// 3D の当たり判定の形（CollisionShape3d）: 箱の作り方（行列・せん断・ノード）・最近点・球の押し出し・カプセルの食い込み・調べる時の表示。
// 期待値は式から手で出せる区切りの良い数（一辺 2 の箱・半径 0.5）。
mod TestCollisionShape3d {

    /// 位置と向きを 1 mm に丸めた値（三角関数の誤差を落として比べる）。
    def mm(v: Vec3.Vec3): (Int32, Int32, Int32) =
        let r = (f: Float64) -> Float64.tryToInt32(Float64.round(f * 1000.0)) |> Option.getWithDefault(-999999);
        (r(v#x), r(v#y), r(v#z))

    def boxMm(b: CollisionShape3d.Box3d): List[(Int32, Int32, Int32)] = mm(b#center) :: mm(b#ax) :: mm(b#ay) :: mm(b#az) :: mm(b#half) :: Nil

    def unitBounds(): Mesh3d.Bounds = { min = Vec3.v3(-1.0, -1.0, -1.0), max = Vec3.v3(1.0, 1.0, 1.0) }

    def quarterTurn(): Float64 = Num.pi() / 2.0

    // ════════════════════════════════════════════════════════════════════
    // 作る
    // ════════════════════════════════════════════════════════════════════

    /// 平行移動 (1, 2, 3)・Y まわり 90°・x を 2 倍の行列で一辺 2 の箱を写すと、真ん中が (1, 2, 3)・x の向きが −Z（rotateY は +Z を +X へ回す）・
    /// 半分の長さが (2, 1, 1) の向きのある箱になる（倍率は half に入り、向きは長さ 1 のまま）。
    @Test
    def testBoxOfBoundsKeepsRotationAndScale(): Unit \ Assert =
        let world = Mat4.mul(Mat4.translate(Vec3.v3(1.0, 2.0, 3.0)), Mat4.mul(Mat4.rotateY(quarterTurn()), Mat4.scale(Vec3.v3(2.0, 1.0, 1.0))));
        Assert.assertEq(expected = (1000, 2000, 3000) :: (0, 0, -1000) :: (0, 1000, 0) :: (1000, 0, 0) :: (2000, 1000, 1000) :: Nil,
            boxMm(CollisionShape3d.boxOfBounds(world, unitBounds())))

    /// せん断（x' = x + y）のある行列では、8 つの角を囲む軸にそろった箱に倒す（x は −2..2・y と z は −1..1）。
    @Test
    def testBoxOfBoundsFallsBackToEnclosingBoxOnShear(): Unit \ Assert =
        let shear = Mat4.ofLinearRows(Vec3.v3(1.0, 1.0, 0.0), Vec3.v3(0.0, 1.0, 0.0), Vec3.v3(0.0, 0.0, 1.0));
        Assert.assertEq(expected = (0, 0, 0) :: (1000, 0, 0) :: (0, 1000, 0) :: (0, 0, 1000) :: (2000, 1000, 1000) :: Nil,
            boxMm(CollisionShape3d.boxOfBounds(shear, unitBounds())))

    /// y を 0 に潰した行列（影の板のような物）では、厚さ 0 の軸にそろった箱に倒す（x と z は −1..1）。
    @Test
    def testBoxOfBoundsFallsBackOnFlattenedAxis(): Unit \ Assert =
        Assert.assertEq(expected = (0, 0, 0) :: (1000, 0, 0) :: (0, 1000, 0) :: (0, 0, 1000) :: (1000, 0, 1000) :: Nil,
            boxMm(CollisionShape3d.boxOfBounds(Mat4.scale(Vec3.v3(1.0, 0.0, 1.0)), unitBounds())))

    /// mesh を持つノードは局所の境界 × world の箱（1 m 上へ置いた一辺 1 の箱）。mesh の無いノード（empty）は None。
    @Test
    def testBoxOfNodeUsesLocalBoundsAndWorld(): Unit \ Assert =
        let node = (bounds: Option[Mesh3d.Bounds]) ->
            { name = "COL_wall", parent = None, local = Mat4.identity(), world = Mat4.translate(Vec3.v3(0.0, 1.0, 0.0)), localBounds = bounds, parts = Nil };
        let half = Some({ min = Vec3.v3(-0.5, -0.5, -0.5), max = Vec3.v3(0.5, 0.5, 0.5) });
        Assert.assertEq(expected = (Some((0, 1000, 0) :: (1000, 0, 0) :: (0, 1000, 0) :: (0, 0, 1000) :: (500, 500, 500) :: Nil), 0),
            (CollisionShape3d.boxOfNode(node(half)) |> Option.map(boxMm), List.length(CollisionShape3d.boxesOfNodes(node(None) :: Nil))))

    /// せん断のある world のノードは外接箱に倒し、ノードの名前を入れた 1 行を知らせる。
    @Test
    def testBoxOfNodeOnShearWarnsWithNodeName(): Unit \ {Assert, IO} =
        let shear = Mat4.ofLinearRows(Vec3.v3(1.0, 1.0, 0.0), Vec3.v3(0.0, 1.0, 0.0), Vec3.v3(0.0, 0.0, 1.0));
        let node = { name = "COL_bent", parent = None, local = shear, world = shear, localBounds = Some(unitBounds()), parts = Nil };
        let (box, lines) = Log.capture(() -> CollisionShape3d.boxOfNode(node));
        Assert.assertEq(expected = (Some((2000, 1000, 1000)), 1, true),
            (box |> Option.map(b -> (Num.roundInt(b#half#x * 1000.0), Num.roundInt(b#half#y * 1000.0), Num.roundInt(b#half#z * 1000.0))),
             List.length(lines), List.exists(String.contains(substr = "COL_bent"), lines)))

    /// 原点の蝶番のまわりに 90° 回すと、x = 1 にあった扉の板は z = −1 へ移り、向きも同じだけ回る（大きさはそのまま）。
    @Test
    def testTransformBoxRotatesAroundOrigin(): Unit \ Assert =
        let leaf = CollisionShape3d.box3d(Vec3.v3(1.0, 0.0, 0.0), Vec3.v3(0.5, 1.0, 0.1));
        Assert.assertEq(expected = (0, 0, -1000) :: (0, 0, -1000) :: (0, 1000, 0) :: (1000, 0, 0) :: (500, 1000, 100) :: Nil,
            boxMm(CollisionShape3d.transformBox(Mat4.rotateY(quarterTurn()), leaf)))

    /// NaN の入った行列の箱は None（壊れた箱を当たり判定に入れない）。頂点の無い形も None。
    @Test
    def testBoxOfMeshRejectsEmptyAndNaN(): Unit \ Assert =
        let quad = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 1.0) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        let nan = Mat4.translate(Vec3.v3(Float64.nan(), 0.0, 0.0));
        Assert.assertEq(expected = (true, false, false),
            (Option.nonEmpty(CollisionShape3d.boxOfMesh(quad, Mat4.identity())), Option.nonEmpty(CollisionShape3d.boxOfMesh(quad, nan)),
             Option.nonEmpty(CollisionShape3d.boxOfMesh(Mesh3d.fromPolygons(Nil), Mat4.identity()))))

    // ════════════════════════════════════════════════════════════════════
    // 問い
    // ════════════════════════════════════════════════════════════════════

    /// 箱の外の点は面の上の一番近い点へ、中の点はそのまま。
    @Test
    def testClosestPointClampsToBox(): Unit \ Assert =
        let b = CollisionShape3d.box3d(Vec3.zero(), Vec3.v3(1.0, 1.0, 1.0));
        Assert.assertEq(expected = ((1000, 500, 0), (200, -300, 400)),
            (mm(CollisionShape3d.closestPoint(b, Vec3.v3(3.0, 0.5, 0.0))), mm(CollisionShape3d.closestPoint(b, Vec3.v3(0.2, -0.3, 0.4)))))

    /// 半径 0.5 の球が x = 1 の面に 0.3 食い込むと、+x へ 0.3 出す。離れた球は None。
    @Test
    def testPushOutHorizontalFromSide(): Unit \ Assert =
        let b = CollisionShape3d.box3d(Vec3.zero(), Vec3.v3(1.0, 1.0, 1.0));
        Assert.assertEq(expected = (Some((300, 0, 0)), None),
            (CollisionShape3d.pushOutHorizontal(b, Vec3.v3(1.2, 0.0, 0.0), 0.5) |> Option.map(mm),
             CollisionShape3d.pushOutHorizontal(b, Vec3.v3(2.0, 0.0, 0.0), 0.5) |> Option.map(mm)))

    /// 真上から触れた球（水平の差が無い）は、足元の一番浅い縁の向き（x の縁まで 0.7・z の縁まで 1.0 → +x）へ、
    /// 1 回に半径 0.5 までだけ出す（縦には動かさない）。
    @Test
    def testPushOutHorizontalFromAboveGoesToShallowEdge(): Unit \ Assert =
        let b = CollisionShape3d.box3d(Vec3.zero(), Vec3.v3(1.0, 1.0, 1.0));
        Assert.assertEq(expected = Some((500, 0, 0)), CollisionShape3d.pushOutHorizontal(b, Vec3.v3(0.3, 1.2, 0.0), 0.5) |> Option.map(mm))

    /// 足元 0・半径 0.5・高さ 2 のカプセルの球は 0.5・1.0・1.5 の高さ（間は半径以下）。高さが直径より低ければ球 1 つ。
    @Test
    def testSphereCentersOfCapsule(): Unit \ Assert =
        let ys = (c: CollisionShape3d.Capsule3d) -> CollisionShape3d.sphereCentersOf(c) |> List.map(v -> mm(v));
        Assert.assertEq(expected = ((0, 500, 0) :: (0, 1000, 0) :: (0, 1500, 0) :: Nil, (0, 500, 0) :: Nil),
            (ys({ feet = Vec3.zero(), radius = 0.5, height = 2.0 }), ys({ feet = Vec3.zero(), radius = 0.5, height = 0.5 })))

    /// x = 0.3 に面のある箱へ半径 0.5 のカプセルが 0.2 食い込む。面が 0.8 なら 0。
    @Test
    def testPenetrationOfCapsule(): Unit \ Assert =
        let capsule = { feet = Vec3.zero(), radius = 0.5, height = 2.0 };
        let near = CollisionShape3d.box3d(Vec3.v3(0.8, 1.0, 0.0), Vec3.v3(0.5, 0.5, 0.5));
        let far = CollisionShape3d.box3d(Vec3.v3(1.3, 1.0, 0.0), Vec3.v3(0.5, 0.5, 0.5));
        Assert.assertEq(expected = (200, 0), (Num.roundInt(CollisionShape3d.penetration(near, capsule) * 1000.0), Num.roundInt(CollisionShape3d.penetration(far, capsule) * 1000.0)))

    // ════════════════════════════════════════════════════════════════════
    // 調べる時の表示
    // ════════════════════════════════════════════════════════════════════

    /// 箱 1 つの線の形は 12 本の辺 × 4 つの横の面 × 2 つの三角形 = 96 個の三角形。
    @Test
    def testDebugMeshDrawsTwelveBars(): Unit \ Assert =
        Assert.assertEq(expected = 96,
            Mesh3d.triangleCount(CollisionShape3d.debugMesh(CollisionShape3d.box3d(Vec3.zero(), Vec3.v3(1.0, 1.0, 1.0)) :: Nil, Color.rgb(0.2, 1.0, 0.4))))
}
