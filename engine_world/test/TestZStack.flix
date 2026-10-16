// ZStack の木と SortingLayer.compose の決まり: 積んだ順が描く順になる・葉の中の前後は z のまま・
// zIndex で兄弟の前後を変えられる・topLayer はどの深さからでも送り先の層の手前へ出る・区画を越えない・
// 越えた・奥へ送った・同じ層を 2 回渡した時は続けて 1 回だけ知らせる・pick は描く時と同じ前後で手前の物が当たる。
// 描画物は 1 辺の長さを名札にした箱で作り、描く順は (z, 列の中の位置) で並べた名札の列で見る。
mod TestZStack {

    use ZStack.{leaf, of, zIndex, topLayer, mapItems}

    /// テスト用の層の表（底の順 = 奥 → 手前）。
    enum Tier with Eq, ToString {
        case Back
        case Front
        case Top
    }

    instance SortingLayer[Tier] {
        pub def zRange(tier: Tier): (Int32, Int32) = match tier {
            case Tier.Back  => (0, 99)
            case Tier.Front => (100, 199)
            case Tier.Top   => (200, 209)
        }
    }

    def ctxWith(warnOnce: String -> Unit): App.ViewCtx =
        { atlas = { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0,
                    lineGap = 0.0, glyphs = Map.empty() },
          fontOf = _ -> { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0,
                          lineGap = 0.0, glyphs = Map.empty() },
          visible = { position = { x = 0.0, y = 0.0 }, size = { x = 1.0, y = 1.0 } },
          warnOnce = warnOnce }

    def quiet(): App.ViewCtx = ctxWith(_ -> ())

    /// 名札 tag の箱を z に置く。
    def box(tag: Int32, z: Int32): Render.PlacedItem =
        { at = { x = 0.0, y = 0.0 }, item = RawDraw.box({ x = Int32.toFloat64(tag), y = 1.0 }, Color.rgb(0.0, 0.0, 0.0), z) }

    def tagOf(placed: Render.PlacedItem): Int32 = match placed#item {
        case Render.Item.Box(b) => Float64.round(b#size#x) |> Float64.tryToInt32 |> Option.getWithDefault(-1)
        case _                  => -1
    }

    def zs(items: List[Render.PlacedItem]): List[Int32] = List.map(placed -> Render.zOf(placed#item), items)

    /// 描く順（z が小さい順・同じ z は列の順）の名札。
    def drawOrder(items: List[Render.PlacedItem]): List[Int32] =
        items |> List.zipWithIndex
            |> List.map(entry -> { let (i, placed) = entry; ((Render.zOf(placed#item), i), tagOf(placed)) })
            |> List.sortBy(fst) |> List.map(snd)

    /// 知らせた文面を集める（compose は純粋なので、テストでだけ効果を隠して覚える）。
    def collecting(f: App.ViewCtx -> a): (a, List[String]) \ IO =
        let seen = Ref.fresh(Static, Nil);
        let result = f(ctxWith(line -> unsafe IO { Ref.put(line :: Ref.get(seen), seen) }));
        (result, List.reverse(Ref.get(seen)))

    /// 後に積んだ子は、前の子の中の z がどれだけ大きくても手前。葉の中は z の順のまま。
    @Test
    def testLaterChildIsDrawnInFrontAndLeafKeepsItsOwnOrder(): Unit \ Assert =
        let tree = of(leaf(box(1, 900) :: box(2, 0) :: Nil) :: leaf(box(3, -5) :: Nil) :: Nil);
        Assert.assertEq(expected = 2 :: 1 :: 3 :: Nil, drawOrder(SortingLayer.stack(quiet(), Tier.Back, tree)))

    /// zIndex の小さい子ほど奥・付けない子は 0。
    @Test
    def testZIndexReordersSiblings(): Unit \ Assert =
        let tree = of(zIndex(1, leaf(box(1, 0) :: Nil)) :: leaf(box(2, 0) :: Nil) :: zIndex(-1, leaf(box(3, 0) :: Nil)) :: Nil);
        Assert.assertEq(expected = 3 :: 2 :: 1 :: Nil, drawOrder(SortingLayer.stack(quiet(), Tier.Back, tree)))

    /// 使う z の幅は葉ごとの z の幅の合計（葉の中の差は保つ）で、層の底から詰まる。
    @Test
    def testLeavesArePackedFromTheLayerBottom(): Unit \ Assert =
        let tree = of(leaf(box(1, 10) :: box(2, 13) :: Nil) :: of(leaf(box(3, 7) :: Nil) :: Nil) :: Nil);
        Assert.assertEq(expected = 100 :: 103 :: 104 :: Nil, zs(SortingLayer.stack(quiet(), Tier.Front, tree)))

    /// topLayer は入れ子の中からでも送り先の層の木の手前に出る。送り先の順は層の表、同じ層の中は送った順。
    @Test
    def testTopLayerSendsNestedItemsInFrontOfTheTargetLayer(): Unit \ Assert =
        let back = of(
            topLayer(Tier.Top, leaf(box(5, 0) :: Nil)) ::
            leaf(box(1, 0) :: Nil) ::
            of(topLayer(Tier.Front, of(leaf(box(3, 0) :: Nil) :: topLayer(Tier.Top, leaf(box(6, 0) :: Nil)) :: Nil)) :: Nil) ::
            Nil);
        let front = leaf(box(2, 0) :: Nil);
        let items = SortingLayer.compose(quiet(), (Tier.Front, front) :: (Tier.Back, back) :: Nil);
        Assert.assertEq(expected = 1 :: 2 :: 3 :: 5 :: 6 :: Nil, drawOrder(items))

    /// mapItems の変換は中身と、中から送った物の両方に掛かる。
    @Test
    def testMapItemsAppliesToSentItemsToo(): Unit \ Assert =
        let tree = mapItems(Render.movedAll({ x = 5.0, y = 0.0 }),
                            of(leaf(box(1, 0) :: Nil) :: topLayer(Tier.Top, leaf(box(2, 0) :: Nil)) :: Nil));
        let items = SortingLayer.stack(quiet(), Tier.Back, tree);
        Assert.assertEq(expected = 5.0 :: 5.0 :: Nil, List.map(placed -> placed#at#x, items))

    /// 送った物の中の topLayer も zIndex の順に送られる（層の直下と同じ順）。
    @Test
    def testNestedSendsFollowZIndex(): Unit \ Assert =
        let inner = of(zIndex(1, topLayer(Tier.Top, leaf(box(1, 0) :: Nil))) :: topLayer(Tier.Top, leaf(box(2, 0) :: Nil)) :: Nil);
        let tree = topLayer(Tier.Front, inner);
        Assert.assertEq(expected = 2 :: 1 :: Nil, drawOrder(SortingLayer.stack(quiet(), Tier.Back, tree)))

    /// 区画を越えた分は天井で止まり、層の名前ごとに 1 回だけ知らせる。
    @Test
    def testOverflowStopsAtTheCeilingAndWarnsOnce(): Unit \ { Assert, IO } =
        let tree = of(leaf(box(1, 0) :: box(2, 50) :: Nil) :: leaf(box(3, 0) :: Nil) :: Nil);
        let (items, warned) = collecting(ctx -> SortingLayer.stack(ctx, Tier.Top, tree));
        Assert.assertEq(expected = Some(209), List.maximum(zs(items)));
        Assert.assertEq(expected = 1, List.length(warned))

    /// 奥の層への送りは送り元の層の手前に置いて知らせる。同じ層を 2 回渡したら 1 つにまとめて知らせる。
    @Test
    def testBackwardSendAndDuplicateLayerAreMergedAndWarned(): Unit \ { Assert, IO } =
        let front = of(leaf(box(1, 0) :: Nil) :: topLayer(Tier.Back, leaf(box(2, 0) :: Nil)) :: Nil);
        let again = leaf(box(3, 0) :: Nil);
        let (items, warned) = collecting(ctx -> SortingLayer.compose(ctx, (Tier.Front, front) :: (Tier.Front, again) :: Nil));
        Assert.assertEq(expected = 100 :: 101 :: 102 :: Nil,
                        zs(items) |> List.sortBy(z -> z));
        Assert.assertEq(expected = 1 :: 3 :: 2 :: Nil, drawOrder(items));
        Assert.assertEq(expected = 2, List.length(warned))

    // ── pick: 押す物の当たり ──

    /// 原点から 1 辺 size の正方形。
    def square(size: Float64): Rect2.Rect2 = { position = { x = 0.0, y = 0.0 }, size = { x = size, y = size } }

    /// 重なった所では、列の先に渡しても底の大きい層（Front）の物が当たる。
    @Test
    def testPickPrefersFrontLayerOverListOrder(): Unit \ Assert =
        Assert.assertEq(expected = Some("front"),
            SortingLayer.pick({ x = 5.0, y = 5.0 }, (Tier.Front, ("front", square(10.0)) :: Nil) :: (Tier.Back, ("back", square(10.0)) :: Nil) :: Nil))

    /// 同じ層の中では列の後ろの物が当たる（画面全体を先頭に置いても、後ろのボタンが先に当たる）。
    @Test
    def testPickPrefersLaterTargetInSameLayer(): Unit \ Assert =
        Assert.assertEq(expected = (Some("button"), Some("block")),
            (SortingLayer.pick({ x = 5.0, y = 5.0 }, (Tier.Top, ("block", square(100.0)) :: ("button", square(10.0)) :: Nil) :: Nil),
             SortingLayer.pick({ x = 50.0, y = 50.0 }, (Tier.Back, ("back", square(100.0)) :: Nil) :: (Tier.Top, ("block", square(100.0)) :: ("button", square(10.0)) :: Nil) :: Nil)))

    /// どの矩形にも入らない点は None。
    @Test
    def testPickMissIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None,
            SortingLayer.pick({ x = 50.0, y = 50.0 }, (Tier.Back, ("back", square(10.0)) :: Nil) :: Nil))

    /// 足元の順: 下にある（y が大きい）物ほど大きい数。
    @Test
    def testOrderAtGrowsDownward(): Unit \ Assert =
        Assert.assertEq(expected = true, Depth.orderAt(10.2) < Depth.orderAt(11.0))
}
