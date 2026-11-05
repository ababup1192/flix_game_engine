// TestMip — 3D の材質が読む絵の段（Mip.build）と、読む段の番号（Mip.lodOf）の式。
mod TestMip {

    def tex(w: Int32, h: Int32, pixels: Vector[Int32]): ShaderEval.TexData = { width = w, height = h, pixels = pixels }

    def sizes(chain: List[ShaderEval.TexData]): List[(Int32, Int32)] = chain |> List.map(t -> (t#width, t#height))

    def flat(w: Int32, h: Int32): ShaderEval.TexData = tex(w, h, Vector.repeat(w * h, 0))

    /// 奇数の辺は floor(n / 2) へ縮み、1 × 1 で止まる（5 × 3 → 2 × 1 → 1 × 1）。
    @Test
    def testBuildHalvesOddSidesDownToOne(): Unit \ Assert =
        Assert.assertEq(expected = (5, 3) :: (2, 1) :: (1, 1) :: Nil, sizes(Mip.build(Mip.Average.Raw, flat(5, 3))))

    /// 1 × 1 の絵は段 0 だけ。
    @Test
    def testBuildOfOneTexelIsItself(): Unit \ Assert =
        Assert.assertEq(expected = 1, List.length(Mip.build(Mip.Average.Raw, flat(1, 1))))

    /// 次の段のテクセルは 2 × 2 の成分ごとの平均（(和 + 2) / 4 の切り捨て）。赤 0・85・170・255 の 2 × 2 → 赤 128。
    @Test
    def testBuildAveragesFourTexels(): Unit \ Assert =
        let level1 = Mip.build(Mip.Average.Raw, tex(2, 2, Vector#{ 0x00000000, 0x00550000, 0x00aa0000, 0x00ff0000 })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x00800000 }), Option.map(t -> t#pixels, level1))

    /// はみ出す行は端の行を繰り返す（高さ 1 の 2 × 1 は、同じ行を 2 回足した平均）。
    @Test
    def testBuildRepeatsEdgeRow(): Unit \ Assert =
        let level1 = Mip.build(Mip.Average.Raw, tex(2, 1, Vector#{ 0x00000000, 0x00550000 })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x002b0000 }), Option.map(t -> t#pixels, level1))

    /// SrgbCurve: 白と黒の市松（2 × 2）の 1 段上は線形の 0.5 を 8bit の sRGB の値にした 188。
    @Test
    def testSrgbCurveAveragesCheckerTo188(): Unit \ Assert =
        let level1 = Mip.build(Mip.Average.SrgbCurve, tex(2, 2, Vector#{ 0x00ffffff, 0x00000000, 0x00000000, 0x00ffffff })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x00bcbcbc }), Option.map(t -> t#pixels, level1))

    /// SrgbCurve の rgb は 4 つの線形の量の平均を linearToSrgb × 255 の四捨五入へ戻した値（赤 0・85・170・255）。
    @Test
    def testSrgbCurveMatchesLinearMeanRounded(): Unit \ Assert =
        let mean = (Texture3d.srgbToLinear(85.0 / 255.0) + Texture3d.srgbToLinear(170.0 / 255.0) + 1.0) / 4.0;
        let red = Float64.round(Texture3d.linearToSrgb(mean) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(-1);
        let level1 = Mip.build(Mip.Average.SrgbCurve, tex(2, 2, Vector#{ 0x00000000, 0x00550000, 0x00aa0000, 0x00ff0000 })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ Int32.leftShift(red, 16) }), Option.map(t -> t#pixels, level1))

    /// SrgbCurve でも α は 8bit の値のまま平均する（α 0 と 64 の市松 → 32）。
    @Test
    def testSrgbCurveKeepsRawAlphaMean(): Unit \ Assert =
        let level1 = Mip.build(Mip.Average.SrgbCurve, tex(2, 2, Vector#{ 0x40000000, 0x00000000, 0x00000000, 0x40000000 })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x20000000 }), Option.map(t -> t#pixels, level1))

    /// Raw は同じ市松を 8bit の値のまま平均する（128）。
    @Test
    def testRawAveragesCheckerTo128(): Unit \ Assert =
        let level1 = Mip.build(Mip.Average.Raw, tex(2, 2, Vector#{ 0x00ffffff, 0x00000000, 0x00000000, 0x00ffffff })) |> List.drop(1) |> List.head;
        Assert.assertEq(expected = Some(Vector#{ 0x00808080 }), Option.map(t -> t#pixels, level1))

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

    // ── 速い道と素直な道の段がバイトまで同じ ──

    /// seed から決まる w × h の ARGB の絵（添え字を掛けて混ぜた値で埋める）。
    def noise(seed: Int32, w: Int32, h: Int32): ShaderEval.TexData =
        let mix = (i: Int32) -> {
            let x = (seed + i) * -1640531535;
            Int32.bitwiseXor(x, Int32.logicalRightShift(dist = 15, x)) * 1103515245
        };
        tex(w, h, Vector.range(0, w * h) |> Vector.map(mix))

    def sameChain(average: Mip.Average, t: ShaderEval.TexData): Bool =
        tuplesOf(Mip.build(average, t)) == tuplesOf(Reference.build(average, t))

    def tuplesOf(chain: List[ShaderEval.TexData]): List[(Int32, Int32, Vector[Int32])] =
        chain |> List.map(td -> (td#width, td#height, td#pixels))

    /// 奇数・細長・正方の大きさのどれでも、Raw の段の列は素直な道と同じ。
    @Test
    def testRawChainMatchesReference(): Unit \ Assert =
        Assert.assertTrue(List.forAll(wh -> sameChain(Mip.Average.Raw, noise(fst(wh) * 31 + snd(wh), fst(wh), snd(wh))), sampleSizes()))

    /// 奇数・細長・正方の大きさのどれでも、SrgbCurve の段の列は素直な道と同じ。
    @Test
    def testSrgbChainMatchesReference(): Unit \ Assert =
        Assert.assertTrue(List.forAll(wh -> sameChain(Mip.Average.SrgbCurve, noise(fst(wh) * 17 + snd(wh), fst(wh), snd(wh))), sampleSizes()))

    /// 大きすぎる絵を縮めた画素は素直な道と同じ。
    @Test
    def testShrinkToMatchesReference(): Unit \ Assert =
        let t = noise(7, 100, 37);
        Assert.assertEq(expected = tuplesOf(Reference.shrinkTo(16, t) :: Nil), tuplesOf(Mip.shrinkTo(16, t) :: Nil))

    def sampleSizes(): List[(Int32, Int32)] = (7, 5) :: (64, 33) :: (1, 9) :: (9, 1) :: (128, 128) :: (3, 3) :: Nil

    /// 段を Vector で 1 画素ずつ作る素直な道（Mip.build と Mip.shrinkTo の答えの基準）。
    mod Reference {
        pub def build(average: Mip.Average, tex: ShaderEval.TexData): List[ShaderEval.TexData] =
            buildWith(meanOf(average), tex)

        def buildWith(mean: Mean, tex: ShaderEval.TexData): List[ShaderEval.TexData] =
            if (tex#width <= 0 or tex#height <= 0 or (tex#width == 1 and tex#height == 1)) tex :: Nil
            else tex :: buildWith(mean, halve(mean, tex))

        pub def shrinkTo(maxSide: Int32, tex: ShaderEval.TexData): ShaderEval.TexData =
            if (Int32.max(tex#width, tex#height) <= Int32.max(1, maxSide) or (tex#width <= 1 and tex#height <= 1)) tex
            else shrinkTo(maxSide, halve(Mean.RawMean, tex))

        enum Mean {
            case RawMean
            case SrgbCurveMean(Vector[Float64], Vector[Float64])
        }

        def meanOf(average: Mip.Average): Mean = match average {
            case Mip.Average.Raw       => Mean.RawMean
            case Mip.Average.SrgbCurve =>
                Mean.SrgbCurveMean(Vector.range(0, 256) |> Vector.map(v -> Texture3d.srgbToLinear(Int32.toFloat64(v) / 255.0)),
                                   Vector.range(1, 256) |> Vector.map(k -> Texture3d.srgbToLinear((Int32.toFloat64(k) - 0.5) / 255.0)))
        }

        def halve(mean: Mean, tex: ShaderEval.TexData): ShaderEval.TexData = region rc {
            let (w, h) = (tex#width, tex#height);
            let (nw, nh) = (Int32.max(1, w / 2), Int32.max(1, h / 2));
            let out: Array[Int32, rc] = Array.empty(rc, nw * nh);
            let src = tex#pixels;
            List.range(0, nh) |> List.forEach(j -> {
                let row0 = Int32.min(2 * j, h - 1) * w;
                let row1 = Int32.min(2 * j + 1, h - 1) * w;
                List.range(0, nw) |> List.forEach(i -> {
                    let x0 = Int32.min(2 * i, w - 1);
                    let x1 = Int32.min(2 * i + 1, w - 1);
                    let (a, b, c, d) = (Vector.get(row0 + x0, src), Vector.get(row0 + x1, src), Vector.get(row1 + x0, src), Vector.get(row1 + x1, src));
                    let pixel = Int32.bitwiseOr(Int32.bitwiseOr(rawMeanOf(24, a, b, c, d), colorMeanOf(mean, 16, a, b, c, d)),
                                                Int32.bitwiseOr(colorMeanOf(mean, 8, a, b, c, d), colorMeanOf(mean, 0, a, b, c, d)));
                    Array.put(pixel, j * nw + i, out)
                })
            });
            { width = nw, height = nh, pixels = Array.toVector(out) }
        }

        def colorMeanOf(mean: Mean, shift: Int32, a: Int32, b: Int32, c: Int32, d: Int32): Int32 = match mean {
            case Mean.RawMean => rawMeanOf(shift, a, b, c, d)
            case Mean.SrgbCurveMean(toLinear, edges) =>
                let linearOf = (x: Int32) -> Vector.get(channelOf(shift, x), toLinear);
                let m = (linearOf(a) + linearOf(b) + linearOf(c) + linearOf(d)) / 4.0;
                Int32.leftShift(countAtMost(m, edges, 0, Vector.length(edges)), shift)
        }

        def countAtMost(x: Float64, edges: Vector[Float64], lo: Int32, hi: Int32): Int32 =
            if (lo >= hi) lo
            else {
                let mid = (lo + hi) / 2;
                if (Vector.get(mid, edges) <= x) countAtMost(x, edges, mid + 1, hi) else countAtMost(x, edges, lo, mid)
            }

        def channelOf(shift: Int32, x: Int32): Int32 = Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, x), 255)

        def rawMeanOf(shift: Int32, a: Int32, b: Int32, c: Int32, d: Int32): Int32 =
            Int32.leftShift((channelOf(shift, a) + channelOf(shift, b) + channelOf(shift, c) + channelOf(shift, d) + 2) / 4, shift)
    }
}
