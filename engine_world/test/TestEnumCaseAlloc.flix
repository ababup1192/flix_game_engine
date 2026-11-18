// TestEnumCaseAlloc — payload の無い enum の case を番号から作って比べる形が、回数に比例して割り当てないかを見る。
//
// render_gl の行の列（Render3d.SceneList.kindAt・RenderFrame.Internal.RenderList.kindAt）は、行の Int32 の欄から種類の enum を
// 行ごとに作って match する。行は描く物の数だけあるので、1 回ごとに割り当てると 1 コマに乗る。render_gl は engine_world の
// AllocMeter を引けないので、同じ形（番号 → payload の無い case を返す match）をここで測る。

mod TestEnumCaseAlloc {

    enum Kind with Eq {
        case First
        case Second
        case Third
        case Fourth
    }

    def kindOfCode(code: Int32): Kind = match code {
        case 1 => Kind.First
        case 2 => Kind.Second
        case 3 => Kind.Third
        case _ => Kind.Fourth
    }

    /// 番号を n 回 enum にし、Third だった回数を数える。
    def countThird(n: Int32): Int32 = countFrom(0, n, 0)

    def countFrom(i: Int32, n: Int32, acc: Int32): Int32 =
        if (i >= n) acc
        else countFrom(i + 1, n, if (kindOfCode(Int32.remainder(i, 4) + 1) == Kind.Third) acc + 1 else acc)

    /// 1,000 回と 100,000 回の割り当ての差が 100 倍に伸びない（case を作るたびに割り当てるなら 100 倍前後になる）。
    /// 線は 4 倍（暖機の残りと測る道具の揺れを吸う幅）。
    @Test
    def testPayloadFreeCaseDoesNotAllocatePerCall(): Unit \ Assert =
        let small = AllocMeter.measureBytes(3, _ -> countThird(1000));
        let large = AllocMeter.measureBytes(3, _ -> countThird(100000));
        Assert.assertTrue(Int64.toFloat64(large) < 4.0 * Int64.toFloat64(Int64.max(small, 1024i64)))
}
