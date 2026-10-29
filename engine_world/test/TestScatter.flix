// Scatter のテスト。同じ入力なら同じ配置が出る決定性と、無限の配置（visible をずらしても
// 同じセルの物は同じ位置）を固定する。加えて、星空相当の place を書いたときに旧 Starfield が
// 出していた星の絶対座標が再現されることを pin し、機構の互換性を保証する。

mod TestScatter {

    def smallVisible(): Rect2.Rect2 =
        { position = { x = 0.0, y = 0.0 }, size = { x = 64.0, y = 64.0 } }

    def spec(): {cell = Float64, salt = Int32} =
        { cell = 32.0, salt = 11 }

    // 星空相当の place: rand(0) が閾値を超えたセルには何も置かない。置くセルはセル内の
    // 相対位置を rand(1), rand(2) で決め、絶対座標 (x, y) だけを返す。
    def starPlace(cell: {col = Int32, row = Int32}, rand: Int32 -> Float64): List[(Float64, Float64)] =
        if (rand(0) > 0.5) Nil
        else
            let cs = spec()#cell;
            let px = (Int32.toFloat64(cell#col) + rand(1)) * cs;
            let py = (Int32.toFloat64(cell#row) + rand(2)) * cs;
            (px, py) :: Nil

    /// 決定性：同じ visible + spec + place を2回呼ぶと、結果列が完全に一致する。
    @Test
    def testDeterministic(): Unit \ Assert =
        Assert.assertEq(
            expected = Scatter.field(smallVisible(), spec(), starPlace),
            Scatter.field(smallVisible(), spec(), starPlace))

    /// salt を変えるとパターンが変わる（同じ visible でも別の配置になる＝レイヤを重ねられる）。
    @Test
    def testSaltChangesPattern(): Unit \ Assert =
        let otherSpec = { salt = 47 | spec() };
        let a = Scatter.field(smallVisible(), spec(), starPlace);
        let b = Scatter.field(smallVisible(), otherSpec, starPlace);
        Assert.assertEq(expected = false, a == b)

    /// 無限の配置：visible をセル1個分だけ右へずらしても、共通するセルの物は同じ絶対位置に
    /// 現れる（スクロールしても物が動かない＝seamless の核）。
    @Test
    def testSameCellSameResultAcrossShiftedVisible(): Unit \ Assert =
        let shifted = { position = { x = 32.0, y = 0.0 }, size = { x = 64.0, y = 64.0 } };
        let a = Scatter.field(smallVisible(), spec(), starPlace);
        let b = Scatter.field(shifted, spec(), starPlace);
        let shared = List.filter(xy -> List.memberOf(xy, b), a);
        Assert.assertEq(expected = true, List.length(shared) > 0)

    /// 総数を pin する（実測値。小さい visible + cell=32 の格子ぶん、星空相当の place）。
    @Test
    def testResultCount(): Unit \ Assert =
        Assert.assertEq(expected = 11, List.length(Scatter.field(smallVisible(), spec(), starPlace)))

    /// 空ける帯を渡さなければ field と 1 個も変わらない（既存の絵が動かない）。
    @Test
    def testFieldExceptWithNoBandsMatchesField(): Unit \ Assert =
        Assert.assertEq(
            expected = Scatter.field(smallVisible(), spec(), starPlace),
            Scatter.fieldExcept(smallVisible(), spec(), Nil, starPlace))

    /// 帯に掛かるセルだけが落ち、残るセルの物は帯を足す前と同じ位置のまま
    /// （帯を足しても他の草が入れ替わらない＝セル単位で落とす理由）。
    @Test
    def testFieldExceptDropsOnlyCellsTouchingTheBand(): Unit \ Assert =
        let band = { position = { x = 0.0, y = 0.0 }, size = { x = 32.0, y = 200.0 } };
        let all = Scatter.field(smallVisible(), spec(), starPlace);
        let kept = Scatter.fieldExcept(smallVisible(), spec(), band :: Nil, starPlace);
        let outsideBand = List.filter(xy -> fst(xy) >= 32.0, all);
        Assert.assertEq(expected = (true, outsideBand), (List.length(kept) < List.length(all), kept))

    /// 旧 Starfield と同じ星空 place を書いたとき、旧 TestStarfield が pin していた先頭星の
    /// 座標が再現される（機構＋チャンネル割当の互換性 pin）。
    @Test
    def testFirstResultMatchesOldStarfieldPin(): Unit \ Assert =
        let results = Scatter.field(smallVisible(), spec(), starPlace);
        Assert.assertEq(
            expected = Some((1.8463446096617102, 8.344069677909662)),
            List.head(results))

    // ── strip（ストリップ 1 本の敷き詰め） ──

    def stripSpec(cm: Int32): {cell = Float64, salt = Int32, lane = Int32,
                               reach = Float64, cellsMax = Int32} =
        { cell = 10.0, salt = 5, lane = 2, reach = 0.0, cellsMax = cm }

    // セル番号と乱数チャンネル 0 の対を返す place。番号と個性の両方を観測できる。
    def colRand(col: Int32, rand: Int32 -> Float64): List[(Int32, Float64)] =
        (col, rand(0)) :: Nil

    /// 決定性：同じ span + spec + place を 2 回呼ぶと、結果列が完全に一致する。
    @Test
    def testStripDeterministic(): Unit \ Assert =
        Assert.assertEq(
            expected = Scatter.strip({ lo = 0.0, hi = 55.0 }, stripSpec(100), colRand),
            Scatter.strip({ lo = 0.0, hi = 55.0 }, stripSpec(100), colRand))

    /// 歩く範囲：span を含むセルに加え、高い側だけ 1 セル余分（field と同じ流儀）。
    @Test
    def testStripWalksSpanCells(): Unit \ Assert =
        Assert.assertEq(
            expected = 0 :: 1 :: Nil,
            Scatter.strip({ lo = 5.0, hi = 5.0 }, stripSpec(100), (col, _r) -> col :: Nil))

    /// reach：セル 1 個ぶんの余白を足すと、span の外側のセルまで歩くようになる。
    @Test
    def testStripReachExpandsWalk(): Unit \ Assert =
        Assert.assertEq(
            expected = -1 :: 0 :: 1 :: 2 :: Nil,
            Scatter.strip({ lo = 5.0, hi = 5.0 }, { reach = 10.0 | stripSpec(100) },
                (col, _r) -> col :: Nil))

    /// span が空（lo > hi）なら 1 セルも歩かない。
    @Test
    def testStripEmptySpanIsNil(): Unit \ Assert =
        Assert.assertEq(
            expected = (Nil: List[Int32]),
            Scatter.strip({ lo = 1.0, hi = 0.0 }, stripSpec(100), (col, _r) -> col :: Nil))

    /// cellsMax の間引き：約 8 セルぶんの span を上限 4 に収めると間隔が 2 倍になり、
    /// 残るセルの番号は元の番号のまま（0,2,4,…）。
    @Test
    def testStripThinnedColsKeepNumbers(): Unit \ Assert =
        Assert.assertEq(
            expected = 0 :: 2 :: 4 :: 6 :: 8 :: Nil,
            Scatter.strip({ lo = 0.0, hi = 79.9 }, stripSpec(4), (col, _r) -> col :: Nil))

    /// 間引かれても、残ったセルの乱数は間引き前と同じ（番号が鍵なので個性がずれない）。
    @Test
    def testStripThinnedKeepsCellIdentity(): Unit \ Assert =
        let full = Scatter.strip({ lo = 0.0, hi = 79.9 }, stripSpec(100), colRand);
        let survivors = List.filter(cr -> Int32.modulo(fst(cr), 2) == 0, full);
        Assert.assertEq(
            expected = survivors,
            Scatter.strip({ lo = 0.0, hi = 79.9 }, stripSpec(4), colRand))

    /// 乱数の鍵の合成（col + lane * 37 + salt）を実測値で pin する。ここが変わると
    /// strip を使う既存の絵がバイト単位でずれる。
    @Test
    def testStripRandKeyPinned(): Unit \ Assert =
        let got = Scatter.strip({ lo = 35.0, hi = 35.0 }, stripSpec(100), colRand)
            |> List.head
            |> Option.map(snd);
        Assert.assertEq(expected = Some(0.9800205993820186), got)
}
