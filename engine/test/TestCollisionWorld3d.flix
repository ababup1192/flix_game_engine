// 動かない箱の集まり（CollisionWorld3d）: 格子で引いた周りの箱が、build の並びの順で重複なく返ること・格子の外で持つ大きな箱。
// 全部の箱を距離で絞った物との一致を、たくさんの並びで確かめるのは engine_world の TestCharacterBody3d。
mod TestCollisionWorld3d {

    def boxAtX(x: Float64): CollisionShape3d.Box3d = CollisionShape3d.box3d(Vec3.v3(x, 0.0, 0.0), Vec3.v3(0.5, 0.5, 0.5))

    /// 地面の板（100 m 四方。64 マスより多くに掛かるので格子の外で持つ）。
    def ground(): CollisionShape3d.Box3d = CollisionShape3d.box3d(Vec3.v3(0.0, -0.5, 0.0), Vec3.v3(50.0, 0.5, 50.0))

    def xs(boxes: List[CollisionShape3d.Box3d]): List[Int32] = boxes |> List.map(b -> Num.roundInt(b#center#x * 10.0))

    /// x = 9・地面・x = 3・x = 6 の順に入れ、(3, 0, 0) から 3 m の範囲を引くと、build の並び（地面 → x = 3 → x = 6）で返る
    /// （x = 9 の箱は 8.5 から始まるので 6 m の範囲の外）。マスを 2 つ以上またぐ x = 3 の箱も 1 回だけ。
    @Test
    def testBoxesNearKeepsBuildOrder(): Unit \ Assert =
        let w = CollisionWorld3d.build(2.0, boxAtX(9.0) :: ground() :: boxAtX(3.0) :: boxAtX(6.0) :: Nil);
        Assert.assertEq(expected = 0 :: 30 :: 60 :: Nil, xs(CollisionWorld3d.boxesNear(w, Vec3.v3(3.0, 0.0, 0.0), 3.0)))

    /// 遠くで引くと、地面の板だけ。
    @Test
    def testBoxesNearFarAwayReturnsOnlyWideBox(): Unit \ Assert =
        let w = CollisionWorld3d.build(2.0, boxAtX(3.0) :: ground() :: Nil);
        Assert.assertEq(expected = 0 :: Nil, xs(CollisionWorld3d.boxesNear(w, Vec3.v3(-30.0, 0.0, 30.0), 1.0)))
}
