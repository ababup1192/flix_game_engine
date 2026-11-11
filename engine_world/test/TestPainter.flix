// Painter（画家の順）— 遠い物が先（小さい zIndex）・近い物が後（大きい zIndex）に
// 並ぶこと、zStride の刻みが効くこと、同距離の並びが決定的なこと。
mod TestPainter {

    @Test
    def testFarthestComesFirstWithZBase(): Unit \ Assert =
        // いちばん遠い 3.0 が先頭に来て、zBase をもらう。
        let ordered = Painter.zOrdered(d -> d, 10, 1, 1.0 :: 3.0 :: 2.0 :: Nil);
        Assert.assertEq(expected = (10, 3.0),
            List.nth(0, ordered) |> Option.getWithDefault((-1, -1.0)))

    @Test
    def testNearestComesLastWithBiggestZ(): Unit \ Assert =
        // いちばん近い 1.0 が末尾に来て、いちばん大きい zIndex をもらう（上塗りで手前）。
        let ordered = Painter.zOrdered(d -> d, 10, 1, 1.0 :: 3.0 :: 2.0 :: Nil);
        Assert.assertEq(expected = (12, 1.0),
            List.nth(2, ordered) |> Option.getWithDefault((-1, -1.0)))

    @Test
    def testZStrideLeavesRoomForLayers(): Unit \ Assert =
        // 1 個が 4 層使うなら zIndex は 100・104・108 と 4 刻みで進む。
        let zs = Painter.zOrdered(d -> d, 100, 4, 3.0 :: 2.0 :: 1.0 :: Nil) |> List.map(fst);
        Assert.assertEq(expected = 100 :: 104 :: 108 :: Nil, zs)

    // 同距離のタイを 3 組ふくむ 8 要素の並びを具体値で固定する（距離は it mod 3）。
    // 距離の遠い順というだけでは決まらない、タイの中の並び（渡した順）まで押さえる。
    @Test
    def testTiedDistancesKeepExactOrder(): Unit \ Assert =
        let items = 1 :: 2 :: 3 :: 4 :: 5 :: 6 :: 7 :: 8 :: Nil;
        let ordered = Painter.zOrdered(it -> Int32.toFloat64(Int32.modulo(it, 3)), 0, 1, items);
        Assert.assertEq(expected = 2 :: 5 :: 8 :: 1 :: 4 :: 7 :: 3 :: 6 :: Nil,
            ordered |> List.map(snd))

    @Test
    def testEqualDistanceIsDeterministic(): Unit \ Assert =
        // 全部同距離でも、同じ列なら呼ぶたびに同じ並び（画面がちらつかない）。
        let once = Painter.zOrdered(_ -> 1.0, 0, 1, 7 :: 8 :: 9 :: Nil) |> List.map(snd);
        let again = Painter.zOrdered(_ -> 1.0, 0, 1, 7 :: 8 :: 9 :: Nil) |> List.map(snd);
        Assert.assertEq(expected = once, again)
}
