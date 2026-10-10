// TestUiTooltip — 説明の窓の置き場所の決まり（脇に出す・はみ出さない・avoid に重ねない）を固定する。
mod TestUiTooltip {

    def rect(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 =
        { position = { x = x, y = y }, size = { x = w, y = h } }

    /// 比べやすい形（左上 x, y と幅・高さ）。
    def flat(r: Rect2.Rect2): (Float64, Float64, Float64, Float64) = (r#position#x, r#position#y, r#size#x, r#size#y)

    def screen(): Rect2.Rect2 = rect(0.0, 0.0, 300.0, 200.0)

    def request(anchor: Rect2.Rect2, avoid: List[Rect2.Rect2]): UiTooltip.Request =
        { anchor = anchor, size = { x = 80.0, y = 40.0 }, bounds = screen(), avoid = avoid, gap = 4.0,
          sides = UiTooltip.defaultSides() }

    @Test
    def testTheWindowGoesBesideTheAnchor(): Unit \ Assert =
        // 右に入るなら右（anchor の右端 + gap、上はそろえる）。
        Assert.assertEq(expected = (54.0, 20.0, 80.0, 40.0),
            flat(UiTooltip.computePlacement(request(rect(10.0, 20.0, 40.0, 40.0), Nil))))

    @Test
    def testTheWindowFlipsWhenTheSideIsOffScreen(): Unit \ Assert =
        // 右端の物は右に入らないので左へ。
        Assert.assertEq(expected = (166.0, 20.0, 80.0, 40.0),
            flat(UiTooltip.computePlacement(request(rect(250.0, 20.0, 40.0, 40.0), Nil))))

    @Test
    def testTheWindowSkipsSidesThatCoverAvoidedThings(): Unit \ Assert =
        // 3 枚並んだ真ん中のカード: 左右は隣のカードに重なるので、その下へ出る。
        let left = rect(10.0, 10.0, 90.0, 100.0);
        let middle = rect(105.0, 10.0, 90.0, 100.0);
        let right = rect(200.0, 10.0, 90.0, 100.0);
        Assert.assertEq(expected = (105.0, 114.0, 80.0, 40.0),
            flat(UiTooltip.computePlacement(request(middle, left :: right :: Nil))))

    @Test
    def testWhenEverySideFailsTheLeastOverflowWins(): Unit \ Assert =
        // 左右は画面に入るが avoid に重なり、下は画面からはみ出す —— はみ出しの無い向き（重なりの少ない右）を採る。
        let anchor = rect(110.0, 150.0, 80.0, 40.0);
        let leftBlock = rect(0.0, 140.0, 105.0, 60.0);
        let rightBlock = rect(260.0, 140.0, 40.0, 60.0);
        let req = { sides = UiTooltip.Side.Bottom :: UiTooltip.Side.Left :: UiTooltip.Side.Right :: Nil
                    | request(anchor, leftBlock :: rightBlock :: Nil) };
        Assert.assertEq(expected = (194.0, 150.0, 80.0, 40.0), flat(UiTooltip.computePlacement(req)))

    @Test
    def testSidesAwayFromCenterTriesTheFarSideFirst(): Unit \ Assert =
        // 右下に寄った物は、左 → 右 → 上 → 下 の順に試す。
        Assert.assertEq(expected = "Left Right Top Bottom",
            UiTooltip.sidesAwayFromCenter(rect(250.0, 150.0, 20.0, 20.0), screen())
                |> List.map(side -> "${side}") |> List.join(" "))

    @Test
    def testTheWindowStaysOnScreenWhenNothingFits(): Unit \ Assert =
        // 画面いっぱいの物の脇はどこも入らない —— 画面の内側へ押し込む。
        let placed = UiTooltip.computePlacement(request(rect(0.0, 0.0, 300.0, 200.0), Nil));
        let inside = placed#position#x >= 0.0 and placed#position#y >= 0.0
            and placed#position#x + 80.0 <= 300.0 and placed#position#y + 40.0 <= 200.0;
        Assert.assertEq(expected = true, inside)
}
