// TestMip — 3D の材質が読む絵の段（Mip.build）と、読む段の番号（Mip.lodOf）の式。
mod TestMip {

    def tex(w: Int32, h: Int32, pixels: Vector[Int32]): ShaderEval.TexData = { width = w, height = h, pixels = pixels }

    def sizes(chain: List[ShaderEval.TexData]): List[(Int32, Int32)] = chain |> List.map(t -> (t#width, t#height))

    def flat(w: Int32, h: Int32): ShaderEval.TexData = tex(w, h, Vector.repeat(w * h, 0))

    /// 奇数の辺は floor(n / 2) へ縮み、1 × 1 で止まる（5 × 3 → 2 × 1 → 1 × 1）。
    @Test
    def testBuildHalvesOddSidesDownToOne(): Unit \ Assert =
        Assert.assertEq(expected = (5, 3) :: (2, 1) :: (1, 1) :: Nil, sizes(Mip.build(flat(5, 3))))

    /// 1 × 1 の絵は段 0 だけ。
    @Test
    def testBuildOfOneTexelIsItself(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(Mip.build(flat(1, 1))))

    /// 次の段のテクセルは 2 × 2 の成分ごとの平均（(和 + 2) / 4 の切り捨て）。赤 0・85・170・255 の 2 × 2 → 赤 128。
    @Test
    def testBuildAveragesFourTexels(): Unit \ Assert =
        let level1 = Mip.build(tex(2, 2, Vector#{ 0x00000000, 0x00550000, 0x00aa0000, 0x00ff0000 })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x00800000 }), Option.map(t -> t#pixels, level1))

    /// はみ出す行は端の行を繰り返す（高さ 1 の 2 × 1 は、同じ行を 2 回足した平均）。
    @Test
    def testBuildRepeatsEdgeRow(): Unit \ Assert =
        let level1 = Mip.build(tex(2, 1, Vector#{ 0x00000000, 0x00550000 })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x002b0000 }), Option.map(t -> t#pixels, level1))

    def still(): Mip.Derivatives = { dudx = 0.0, dvdx = 0.0, dudy = 0.0, dvdy = 0.0 }

    /// ρ = 1 画素で動くテクセルの数。16 テクセルの絵で 1 画素に u が 0.25 動けば ρ = 4・lod = 2。
    @Test
    def testLodIsLog2OfTexelsPerPixel(): Unit \ Assert =
        Assert.assertEq(expected = 2.0, Mip.lodOf({ dudx = 0.25 | still() }, 16, 16, 5))

    /// ρ は x と y の向きの大きい方（y の向きに v が 0.5 動く 16 × 16 は ρ = 8・lod = 3）。
    @Test
    def testLodTakesLargerAxis(): Unit \ Assert =
        Assert.assertEq(expected = 3.0, Mip.lodOf({ dudx = 0.0625, dvdy = 0.5 | still() }, 16, 16, 5))

    /// REPEAT の継ぎ目で座標が 1 跳ぶ画素（差 0.98）は floor(d + 0.5) を引いて −0.02 として扱い、段 0 のまま。
    @Test
    def testLodRemovesRepeatSeam(): Unit \ Assert =
        Assert.assertEq(expected = 0.0, Mip.lodOf({ dudx = 0.98 | still() }, 16, 16, 5))

    /// lod は段の数 − 1 で頭打ち（ρ = 16 でも段が 3 つなら 2）。
    @Test
    def testLodClampsToLastLevel(): Unit \ Assert =
        Assert.assertEq(expected = 2.0, Mip.lodOf({ dudx = 0.25 | still() }, 64, 64, 3))

    /// 拡大（ρ ≦ 1）と段が 1 つの絵は lod 0。
    @Test
    def testLodIsZeroWhenMagnifiedOrSingleLevel(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 0.0), (Mip.lodOf({ dudx = 0.01 | still() }, 16, 16, 5), Mip.lodOf({ dudx = 0.25 | still() }, 16, 16, 1)))
}
