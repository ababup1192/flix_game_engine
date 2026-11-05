// 3D の描き手の、描く順（Render3d.inDrawOrder・姿勢の鍵）と、
// 場面の絵と段つきの写しの置き場を上限に収める時に捨てる物（Render3d.Material.budgetEvictions）。GL を呼ばずに決まる所。
mod Render3d.TestDrawOrder {

    /// 鍵の同じ物は来た順のまま、違う物は鍵の順に並ぶ。
    @Test
    def testEqualKeysKeepInputOrder(): Unit \ Assert =
        let xs = (2, "a") :: (1, "b") :: (2, "c") :: (1, "d") :: Nil;
        Assert.assertEq(expected = "b" :: "d" :: "a" :: "c" :: Nil, Render3d.inDrawOrder(x -> (fst(x), 0i64), xs) |> List.map(snd))

    /// 第 1 の鍵が同じ物は、第 2 の鍵（姿勢の鍵）の順に並ぶ。
    @Test
    def testSecondKeyGroupsSamePose(): Unit \ Assert =
        let xs = (7, 30i64, "a") :: (7, 10i64, "b") :: (7, 30i64, "c") :: (7, 10i64, "d") :: Nil;
        Assert.assertEq(expected = "b" :: "d" :: "a" :: "c" :: Nil,
                        Render3d.inDrawOrder(x -> { let (p, k, _) = x; (p, k) }, xs) |> List.map(x -> { let (_, _, n) = x; n }))

    /// 同じ並びを 2 回並べると同じ順になる。
    @Test
    def testSameInputGivesSameOrder(): Unit \ Assert =
        let xs = List.range(0, 40) |> List.map(i -> (Int32.remainder(i * 7, 5), Int32.toInt64(Int32.remainder(i * 3, 4)), i));
        let order = () -> Render3d.inDrawOrder(x -> { let (p, k, _) = x; (p, k) }, xs) |> List.map(x -> { let (_, _, n) = x; n });
        Assert.assertEq(expected = order(), order())

    def poseAt(x: Float64): Pose3d.Pose3d =
        let rest = { translation = Vec3.zero(), rotation = Quat.identity(), scale = Vec3.one() };
        match Skin3d.make({ names = Vector#{ "root" }, parents = Vector#{ -1 }, rest = Vector#{ rest }, inverseBinds = None, rootTransform = Mat4.identity() }) {
            case Ok(skin) => Pose3d.compute(skin, Vector#{ { translation = Vec3.v3(x, 0.0, 0.0) | rest } })
            case Err(e)   => bug!(e)
        }

    def drawOf(pose: Option[Pose3d.Pose3d]): Render3d.MeshDraw =
        { fields = Scene3d.instanceFieldsOf(Scene3d.meshInstance(Mesh3d.fromPolygons(Nil), Mat4.identity())), pose = pose, poseRow = 0, culled = false }

    /// 骨の無い物の姿勢の鍵は 0・骨つきの物は Pose3d.keyOf。
    @Test
    def testPoseKeyOfDraw(): Unit \ Assert =
        let p = poseAt(1.0);
        Assert.assertEq(expected = (0i64, Pose3d.keyOf(p)), (Render3d.poseKeyOf(drawOf(None)), Render3d.poseKeyOf(drawOf(Some(p)))))

    // ── 置き場の上限 ──

    def entry(lastUsed: Int64, size: Int64, counted: Bool): Render3d.Material.BudgetEntry =
        { lastUsed = lastUsed, size = size, counted = counted, preloaded = false }

    /// 上限に収まっていれば、長く使っていない物も捨てない。
    @Test
    def testNothingIsDroppedWithinBudget(): Unit \ Assert =
        let entries = ("old", entry(1i64, 10i64, true)) :: ("copy", entry(2i64, 10i64, false)) :: Nil;
        Assert.assertEq(expected = Nil, Render3d.Material.budgetEvictions({ count = 4, size = 100i64 }, 1000i64, entries))

    /// 大きさを超えたら、段つきの写しも含めて古い物から収まるまで捨てる。
    @Test
    def testBytesOverBudgetDropsOldestIncludingCopies(): Unit \ Assert =
        let entries = ("scene", entry(5i64, 40i64, true)) :: ("copy", entry(2i64, 40i64, false)) :: ("new", entry(9i64, 40i64, true)) :: Nil;
        Assert.assertEq(expected = "copy" :: Nil, Render3d.Material.budgetEvictions({ count = 10, size = 100i64 }, 1000i64, entries))

    /// 枚数だけが超えている間は、枚数に数えない段つきの写しは捨てない。
    @Test
    def testCountOverBudgetSkipsCopies(): Unit \ Assert =
        let entries = ("copy", entry(1i64, 1i64, false)) :: ("a", entry(2i64, 1i64, true)) :: ("b", entry(3i64, 1i64, true)) :: Nil;
        Assert.assertEq(expected = "a" :: Nil, Render3d.Material.budgetEvictions({ count = 1, size = 100i64 }, 1000i64, entries))

    /// keepFrom より後に使った物は、上限を超えていても捨てない。
    @Test
    def testRecentlyUsedIsKept(): Unit \ Assert =
        let entries = ("a", entry(8i64, 80i64, true)) :: ("b", entry(9i64, 80i64, true)) :: Nil;
        Assert.assertEq(expected = Nil, Render3d.Material.budgetEvictions({ count = 10, size = 100i64 }, 8i64, entries))
}
