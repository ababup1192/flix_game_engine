// 何を守るか（LogCapture を使うので engine_tools のテストに置く）: 当たり判定の箱を作る時に倒した形を、ノード名つきの 1 行で知らせること。
mod TestCollisionShape3dWarn {

    /// せん断のある world のノードは外接箱に倒し、ノードの名前を入れた 1 行を知らせる。
    @Test
    def testBoxOfNodeOnShearWarnsWithNodeName(): Unit \ {Assert, IO} =
        let shear = Mat4.ofLinearRows(Vec3.v3(1.0, 1.0, 0.0), Vec3.v3(0.0, 1.0, 0.0), Vec3.v3(0.0, 0.0, 1.0));
        let node = { name = "COL_bent", parent = None, local = shear, world = shear, localBounds = Some({ min = Vec3.v3(-1.0, -1.0, -1.0), max = Vec3.v3(1.0, 1.0, 1.0) }), parts = Nil };
        let (box, lines) = LogCapture.capture(() -> CollisionShape3d.boxOfNode(node));
        Assert.assertEq(expected = (Some((2000, 1000, 1000)), 1, true),
            (box |> Option.map(b -> (Num.roundInt(b#half#x * 1000.0), Num.roundInt(b#half#y * 1000.0), Num.roundInt(b#half#z * 1000.0))),
             List.length(lines), List.exists(String.contains(substr = "COL_bent"), lines)))
}
