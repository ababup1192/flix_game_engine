// PxShade（ドット絵の塗りの仕上げ）— 光の向き・重み・決定性。
mod TestPxShade {

    /// 中 'm' / 明 'M' / 暗 'n' の 1 材料だけの表。
    def ramp(): PxShade.Ramp = Map#{ 'm' => ('M', 'n') }

    /// 3×3 の塗りつぶし。まわりは透明。
    def block(): List[String] = ".mmm." :: ".mmm." :: ".mmm." :: Nil

    def spec(): PxShade.Spec =
        { rim = 1.0, contact = 1.0, dither = 0.0, grain = 0.0, grainScale = 1,
          lightX = -1, lightY = -1 }

    /// 面の内側だけを見るための、縁の無い広い塗り（5x5 の真ん中は縁でない）。
    def slab(): List[String] = List.repeat(5, "mmmmm")

    @Test
    def testGrainSpecklesTheInside(): Unit \ Assert =
        // 粒を全部入れると、内側の画素は中の色でなくなる（明か暗のどちらか）。
        let out = PxShade.shade({ rim = 0.0, contact = 0.0, grain = 1.0 | spec() }, ramp(), slab());
        let middle = List.nth(2, out) |> Option.getWithDefault("");
        Assert.assertEq(expected = false, String.contains(substr = "m", middle))

    @Test
    def testGrainZeroLeavesTheInsideFlat(): Unit \ Assert =
        let out = PxShade.shade({ rim = 0.0, contact = 0.0, grain = 0.0 | spec() }, ramp(), slab());
        Assert.assertEq(expected = "mmmmm", List.nth(2, out) |> Option.getWithDefault(""))

    @Test
    def testCoarseGrainMakesClumps(): Unit \ Assert =
        // 升目を大きくすると、同じ升目の中は同じ色になる（＝点でなく塊）。
        let coarse = { rim = 0.0, contact = 0.0, grain = 1.0, grainScale = 5 | spec() };
        let out = PxShade.shade(coarse, ramp(), slab());
        Assert.assertEq(expected = 1,
            out |> List.map(row -> String.toList(row) |> List.distinct |> List.length)
                |> List.distinct |> List.length)

    @Test
    def testGrainNeverBeatsTheEdges(): Unit \ Assert =
        // 縁の明暗（形を読ませる側）が粒に負けない。
        let out = PxShade.shade({ grain = 1.0 | spec() }, ramp(), slab());
        Assert.assertEq(expected = "MMMMM", List.nth(0, out) |> Option.getWithDefault(""))

    @Test
    def testRimLightsTheSideTheLightComesFrom(): Unit \ Assert =
        // 左上からの光なら、左の列と上の行が明るくなる。
        let out = PxShade.shade(spec(), ramp(), block());
        Assert.assertEq(expected = ".MMM.", List.nth(0, out) |> Option.getWithDefault(""))

    @Test
    def testContactShadesTheOppositeSide(): Unit \ Assert =
        // 最下行は下が空いているので暗くなる。ただし左下の角は「左が空いている」でもあり、
        // 光と影の両方に当たる — そこはふち光が勝つ（規約）。
        let out = PxShade.shade(spec(), ramp(), block());
        Assert.assertEq(expected = ".Mnn.", List.nth(2, out) |> Option.getWithDefault(""))

    @Test
    def testLightDirectionFollowsTheSpec(): Unit \ Assert =
        // 右下から照らせば、明暗が入れ替わる。
        let flipped = { lightX = 1, lightY = 1 | spec() };
        let out = PxShade.shade(flipped, ramp(), block());
        // 右下からの光なら、角の勝ち負けも鏡になる。
        Assert.assertEq(expected = (".nnM.", ".MMM."),
            (List.nth(0, out) |> Option.getWithDefault(""),
             List.nth(2, out) |> Option.getWithDefault("")))

    @Test
    def testZeroWeightsLeaveTheArtAlone(): Unit \ Assert =
        Assert.assertEq(expected = block(), PxShade.shade(PxShade.none(), ramp(), block()))

    @Test
    def testUnknownCharactersAreUntouched(): Unit \ Assert =
        // 表に無い文字（輪郭など）は変えずそのまま出す。
        let rows = "kkk" :: "kmk" :: "kkk" :: Nil;
        let out = PxShade.shade(spec(), ramp(), rows);
        Assert.assertEq(expected = "kMk", List.nth(1, out) |> Option.getWithDefault(""))

    @Test
    def testHalfWeightPicksTheSamePixelsEveryTime(): Unit \ Assert =
        // 掛ける画素は座標から決まる（スナップショットが安定する）。出来上がりそのものを釘打って、
        // ハッシュの式や salt が変わったら気付けるようにする。
        let half = { dither = 0.5, rim = 0.5 | spec() };
        Assert.assertEq(expected = ".mMM." :: ".mmn." :: ".Mnn." :: Nil,
                        PxShade.shade(half, ramp(), block()))

    @Test
    def testLightSideNeverGoesDarkAtLowRim(): Unit \ Assert =
        // ふち光の密度が低くても、光の側の縁が影で塗られてはいけない
        // （外れたぶんが影に回ると、光の当たる角が暗くなってしまう）。
        let faint = { rim = 0.02, contact = 1.0 | spec() };
        let out = PxShade.shade(faint, ramp(), List.repeat(4, "mmmm"));
        // 光は左上。上端の行と左端の列に暗（'n'）が 1 つも出ない。
        let top = List.nth(0, out) |> Option.getWithDefault("");
        let leftColumn = out |> List.map(row -> String.charAt(0, row));
        Assert.assertEq(expected = (false, false),
            (String.contains(substr = "n", top), List.memberOf('n', leftColumn)))

    @Test
    def testGrainAboveOneStillLeavesDarkPixels(): Unit \ Assert =
        // 1.0 を超える密度でも面が丸ごと明るくならない（Doc から来る値なので要クランプ）。
        let over = { rim = 0.0, contact = 0.0, grain = 4.0 | spec() };
        let out = PxShade.shade(over, ramp(), slab());
        Assert.assertEq(expected = true,
            out |> List.exists(row -> String.contains(substr = "n", row)))

    @Test
    def testRaggedRowsKeepTheirLength(): Unit \ Assert =
        // 短い行を右に詰めるとコマの形が変わる（透明が見える画素に化ける）。
        let out = PxShade.shade(spec(), ramp(), "mm" :: "mmmm" :: Nil);
        Assert.assertEq(expected = 2 :: 4 :: Nil, out |> List.map(String.length))

    @Test
    def testPolishDocTouchesEveryFrame(): Unit \ Assert =
        let doc = { version = 1, note = None, legend = Map#{ 'm' => "metal" },
                    sprites = Map#{ "x" => { anchor = { x = 0.0, y = 0.0 }, clips = Map.empty(),
                                             frames = Map#{ "a" => block(), "b" => block() } } } };
        let out = PxShade.shadeDoc(spec(), ramp(), doc);
        let frameOf = name -> Map.get("x", out#sprites)
            |> Option.flatMap(sp -> Map.get(name, sp#frames))
            |> Option.flatMap(rows -> List.nth(0, rows))
            |> Option.getWithDefault("");
        Assert.assertEq(expected = (".MMM.", ".MMM."), (frameOf("a"), frameOf("b")))
}
