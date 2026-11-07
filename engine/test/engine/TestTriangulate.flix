// TestTriangulate — 耳切り三角形分割を具体値で固定する:
// 枚数（単純多角形は必ず n−2 枚）と面積保存（分割前後で面積が変わらない）が不変条件。
// 凹の代表として星（fan 塗りだと崩れる形）を使い、GL と SoftRaster の一致の根拠にする。
mod TestTriangulate {

    def tau(): Float64 = 6.283185307179586

    /// 三角形1枚の面積（外積の絶対値の半分）。
    def triArea(t: (Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)): Float64 =
        let (a, b, c) = t;
        let cr = (b#x - a#x) * (c#y - a#y) - (b#y - a#y) * (c#x - a#x);
        Float64.abs(cr) / 2.0

    def sumArea(tris: List[(Vec2.Vec2, Vec2.Vec2, Vec2.Vec2)]): Float64 =
        List.foldLeft((s, t) -> s + triArea(t), 0.0, tris)

    /// 小数4桁へ丸める（浮動小数の比較用）。
    def round4(x: Float64): Float64 = Float64.floor(x * 10000.0 + 0.5) / 10000.0

    /// 星（n 尖り・外径 ro・内径 ri）— 凹多角形の代表。
    def star(n: Int32, ro: Float64, ri: Float64): List[Vec2.Vec2] =
        List.range(0, n * 2) |> List.map(i -> {
            let r = if (Int32.modulo(i, 2) == 0) ro else ri;
            let t = Int32.toFloat64(i) / Int32.toFloat64(n * 2);
            { x = r * Num.cos(tau() * t), y = r * Num.sin(tau() * t) }
        })

    // 割り方の列を頂点へ戻すと、耳切りと同じ三角形になる（凹の形でも）。
    @Test
    def testIndicesRebuildSameTriangles(): Unit \ Assert =
        let points = star(5, 10.0, 4.0);
        Assert.assertEq(expected = List.map(triArea, Triangulate.triangles(points)),
                        List.map(triArea, Triangulate.fromIndices(Triangulate.indices(points), points)))

    // 形を動かしても、同じ列のまま面積が保たれる（読み込みの時に 1 度割る使い方の根拠）。
    @Test
    def testIndicesFollowMovedShape(): Unit \ Assert =
        let points = star(5, 10.0, 4.0);
        let moved = points |> List.map(p -> ({ x = p#x + 30.0, y = p#y - 7.0 }: Vec2.Vec2));
        Assert.assertEq(expected = round4(sumArea(Triangulate.triangles(points))),
                        round4(sumArea(Triangulate.fromIndices(Triangulate.indices(points), moved))))

    // 列が頂点の数に合わない時は割り直す（fail-open）。
    @Test
    def testBrokenIndicesFallBackToTriangles(): Unit \ Assert =
        let points = star(5, 10.0, 4.0);
        Assert.assertEq(expected = List.map(triArea, Triangulate.triangles(points)),
                        List.map(triArea, Triangulate.fromIndices(Vector#{ 0, 1, 99 }, points)))

    // 凸（正方形）: 2枚に割れ、面積 1 がそのまま保存される。
    @Test
    def testConvexSquareSplitsInTwo(): Unit \ Assert =
        let square = { x = 0.0, y = 0.0 } :: { x = 1.0, y = 0.0 }
                  :: { x = 1.0, y = 1.0 } :: { x = 0.0, y = 1.0 } :: Nil;
        let tris = Triangulate.triangles(square);
        Assert.assertEq(expected = (2, 1.0), (List.length(tris), round4(sumArea(tris))))

    // 凹（5尖の星・10頂点）: n−2 = 8 枚で、面積が靴ひも公式の値と一致する。
    // fan 分割だと面積が合わない（凹みを跨いで塗る）ので、これが耳切りの証拠になる。
    @Test
    def testConcaveStarPreservesArea(): Unit \ Assert =
        let s = star(5, 21.0, 9.0);
        let tris = Triangulate.triangles(s);
        let expected = Float64.abs(Triangulate.signedArea(s));
        Assert.assertEq(expected = (8, round4(expected)),
            (List.length(tris), round4(sumArea(tris))))

    // 頂点の並びが逆向き（時計回り）でも同じ結果になる（向きの正規化）。
    @Test
    def testReversedWindingGivesSameArea(): Unit \ Assert =
        let s = star(5, 21.0, 9.0);
        let a = sumArea(Triangulate.triangles(s));
        let b = sumArea(Triangulate.triangles(List.reverse(s)));
        Assert.assertEq(expected = round4(a), round4(b))

    // 3頂点未満は空・ちょうど3頂点はそのまま1枚。
    @Test
    def testDegenerateAndTriangle(): Unit \ Assert =
        let two = { x = 0.0, y = 0.0 } :: { x = 1.0, y = 0.0 } :: Nil;
        let tri = { x = 0.0, y = 0.0 } :: { x = 2.0, y = 0.0 } :: { x = 0.0, y = 2.0 } :: Nil;
        Assert.assertEq(expected = (0, 1, 2.0),
            (List.length(Triangulate.triangles(two)),
             List.length(Triangulate.triangles(tri)),
             sumArea(Triangulate.triangles(tri))))
}
