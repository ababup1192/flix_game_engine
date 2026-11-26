// TestLightAnalytic — 答えが式で決まる場面で、3D の光の式（CPU の SoftRaster3dLight と SoftRaster3d.surfaceOutAt・PostProcess の tonemap）の値を確かめる。
// 「今の値」のテストは今の式の答えで緑にする。「標準からの開き」のテストは、物理の標準の答え（standard*）と今の値の差を確かめる。
// 光の単位の型（Lux・Candela・Ev100）を入れて式を標準と同じにしたら、「今の値」のテストを消し、「標準からの開き」の期待を 1 倍（差なし）へ替える。
mod SoftRaster3d.TestLightAnalytic {

    // ════════════════════════════════════════════════════════════════════
    // 標準と今の式（期待値の式）
    // ════════════════════════════════════════════════════════════════════

    /// 標準の Lambert: 反射率 a の拡散の面が照度 e を受けた時の明るさ（a / π × e）。
    def standardDiffuse(a: Float64, e: Float64): Float64 = a / Num.pi() * e

    /// 今の式の拡散: 1/π を掛けない（a × e）。
    def currentDiffuse(a: Float64, e: Float64): Float64 = a * e

    /// 標準の逆二乗: 距離 d と 2d の明るさの比（(d / 2d)² = 1/4）。
    def standardDistanceRatio(): Float64 = 0.25

    /// 今の式の減り方 (1 − d²/range²)² での、距離 2d と d の明るさの比。
    def currentDistanceRatio(d: Float64, range: Float64): Float64 =
        let att = (x: Float64) -> { let f = 1.0 - x * x / (range * range); f * f };
        att(2.0 * d) / att(d)

    /// Narkowicz の ACES の近似 x(2.51x + 0.03) / (x(2.43x + 0.59) + 0.14)。
    def narkowicz(x: Float64): Float64 = x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14)

    /// sRGB の曲線（入力は 0.0031308 より上だけを使うので、直線の区間は書かない）。
    def srgbEncode(x: Float64): Float64 = 1.055 * Float64.pow(base = x, 1.0 / 2.4) - 0.055

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))

    /// 標準: 線形の明るさ l に ACES を掛け、その後で sRGB の曲線（露出 0・白の点で割らない）。
    def standardTonemap(l: Float64): Float64 = srgbEncode(clamp01(narkowicz(l)))

    /// 今の式: 先に sRGB の曲線を掛けた値（HDR の Pass の値）に、既定の露出を掛けて ACES・白の点の値で割って 0..1 に切る。
    def currentTonemap(l: Float64): Float64 =
        let exposure = Float64.pow(base = 2.0, PostProcess.defaultExposure());
        clamp01(narkowicz(srgbEncode(l) * exposure) / narkowicz(PostProcess.defaultWhitePoint()))

    /// tonemap の曲線を確かめる線形の明るさ（暗部・中間の灰・白・白の点・白の点の先）。
    def tonemapInputs(): List[Float64] = 0.01 :: 0.18 :: 1.0 :: 4.0 :: 16.0 :: Nil

    // ════════════════════════════════════════════════════════════════════
    // CPU の描き手の値を取り出す
    // ════════════════════════════════════════════════════════════════════

    def noLights(): Vector[Float64] = Vector.empty()

    /// 原点の上向きの面に、真上から color × intensity = e の太陽を当てた光の量（r）。環境光・半球光は 0。
    def sunAboveLight(e: Float64): Float64 =
        let (r, _, _) = SoftRaster3dLight.lightAt(0, noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                  0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, e, e, e, 1.0, 0.0, 1.0, Scene3d.Internal.SkyIrradiance.zeros(), 0.0);
        r

    /// 同じ面を、反射率 albedo・metallic 0・roughness 1 の PBR の材質で塗った色（r・かすみの前）。空と環境は 0。
    def sunAbovePbr(albedo: Float64, e: Float64): Float64 =
        let light = sunAboveLight(e);
        let (r, _, _) = SoftRaster3dLight.pbrAt(noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                albedo, albedo, albedo, light, light, light, 0.0, 1.0, 0.0,
                                                0.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
                                                0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, e, e, e, 1.0, 0.0, 1.0);
        r

    /// 原点の白・強さ 1・range の点光源の、真下 d の上向きの面が受ける光の量（r）。
    def pointBelowLight(d: Float64, range: Float64): Float64 =
        let points = LightModel3d.packPointLights({ position = Vec3.zero(), color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = range } :: Nil);
        let (r, _, _) = SoftRaster3dLight.lightAt(0, points, noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0 - d, 0.0, 0.0, 1.0, 0.0,
                                                  0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, Scene3d.Internal.SkyIrradiance.zeros(), 0.0);
        r

    def emptyEnvironment(): Scene3d.Environment3d =
        Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() }, Vec2.zero())#environment

    /// 白い材質が線形の光の量 l を受けた時に HDR の Pass へ書く値（r・GL の r3d_surfaceOut と同じ式）。
    def hdrPassValue(l: Float64): Float64 =
        let white = Color.rgb(1.0, 1.0, 1.0);
        SoftRaster3d.surfaceOutAt(emptyEnvironment(), Vec3.zero(), Vec3.zero(), white, white, Color.rgb(l, l, l), Color.rgb(0.0, 0.0, 0.0), 0.0, false)#r

    def solidSpec(v: Float64): ShaderDoc.Spec =
        { name = "s", cycleRate = 0.0, bindings = Nil,
          out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(Color.rgb(v, v, v)), alpha = ShaderDoc.Field.Const(1.0) }) }

    /// 線形の光の量 l の白い面が、HDR の Pass から既定の AcesFitted の tonemap（既定の露出・白の点）を通って出る値（r）。
    def tonemappedScene(l: Float64): Float64 =
        let spec = PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, PostProcess.defaultExposure(), PostProcess.defaultWhitePoint(), solidSpec(hdrPassValue(l)));
        ShaderEval.evalPixel(spec, { x = 0.5, y = 0.5 }, 0.0)#r

    /// tonemap の値どうしが 1.0e-6 の内でそろうか（ShaderEval は GPU と同じ単精度で回すので、倍精度の式と 1.0e-7 の桁で離れる）。
    def closeAll(actual: List[Float64], expected: List[Float64]): Bool =
        List.length(actual) == List.length(expected) and
            List.forAll(match (a, e) -> Float64.abs(a - e) < 1.0e-6, List.zip(actual, expected))

    // ════════════════════════════════════════════════════════════════════
    // 拡散の板
    // ════════════════════════════════════════════════════════════════════

    /// 反射率 0.5 の拡散の板に真上から強さ 2 の太陽: 今の式は 1/π を掛けず 0.5 × 2（拡散の項 = 反射率 0.5 と 0 の差。鏡面は反射率に依らず消える）。
    @Test
    def testDiffusePlateIsAlbedoTimesLight(): Unit \ Assert =
        let diffuse = sunAbovePbr(0.5, 2.0) - sunAbovePbr(0.0, 2.0);
        Assert.assertTrue(Float64.abs(diffuse - currentDiffuse(0.5, 2.0)) < 1.0e-9)

    /// 同じ板の拡散は、標準の Lambert（a / π × e）の π 倍明るい。
    @Test
    def testDiffusePlateIsPiTimesStandard(): Unit \ Assert =
        let diffuse = sunAbovePbr(0.5, 2.0) - sunAbovePbr(0.0, 2.0);
        Assert.assertTrue(Float64.abs(diffuse / standardDiffuse(0.5, 2.0) - Num.pi()) < 1.0e-9)

    // ════════════════════════════════════════════════════════════════════
    // 距離と明るさ
    // ════════════════════════════════════════════════════════════════════

    /// range 4 の点光源の距離 2 と 1 の明るさの比は、今の式では (1 − 2²/4²)² / (1 − 1²/4²)²。
    @Test
    def testPointLightDistanceRatioFollowsRangeWindow(): Unit \ Assert =
        let ratio = pointBelowLight(2.0, 4.0) / pointBelowLight(1.0, 4.0);
        Assert.assertTrue(Float64.abs(ratio - currentDistanceRatio(1.0, 4.0)) < 1.0e-9)

    /// 同じ比は、標準の逆二乗の 1/4 より大きい（離れても標準ほど暗くならない）。
    @Test
    def testPointLightDistanceRatioAboveStandard(): Unit \ Assert =
        let ratio = pointBelowLight(2.0, 4.0) / pointBelowLight(1.0, 4.0);
        Assert.assertTrue(ratio > standardDistanceRatio())

    // ════════════════════════════════════════════════════════════════════
    // tonemap の曲線
    // ════════════════════════════════════════════════════════════════════

    /// 線形の 0.01・0.18・1・4・16 は、sRGB の曲線 → 既定の露出 → ACES → 白の点で割る、の順の式どおりに出る。
    @Test
    def testTonemapFollowsEncodeThenAces(): Unit \ Assert =
        Assert.assertTrue(closeAll(List.map(tonemappedScene, tonemapInputs()), List.map(currentTonemap, tonemapInputs())))

    /// 既定の露出では、標準（ACES の後で sRGB の曲線）より暗部 0.01 が明るく、白 1 が暗い。
    @Test
    def testTonemapLiftsShadowsAndDimsWhiteAgainstStandard(): Unit \ Assert =
        Assert.assertTrue(tonemappedScene(0.01) > standardTonemap(0.01) and tonemappedScene(1.0) < standardTonemap(1.0))

    // ════════════════════════════════════════════════════════════════════
    // 景色の拡散の光（SH）
    // ════════════════════════════════════════════════════════════════════

    /// 上が空色・下が茶の 32 × 16 の景色から求めた拡散の光。
    def skyHarmonics(): SphericalHarmonics.SphericalHarmonics =
        let argb = (r: Int32, g: Int32, b: Int32) -> Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(r, 16), Int32.bitwiseOr(Int32.leftShift(g, 8), b)));
        let pixels = Vector.range(0, 32 * 16) |> Vector.map(k -> if (k / 32 < 8) argb(90, 140, 230) else argb(150, 90, 40));
        match Texture3d.fromArgb(32, 16, pixels) |> Result.toOption |> Option.flatMap(SphericalHarmonics.fromEquirectangular) {
            case Some(sh) => sh
            case None     => bug!("求められない")
        }

    /// 割合 1・ambient 0 の光の式の値（CPU の木）は、どの向きでも SphericalHarmonics.irradianceAt と 1e−6 以内で同じ。
    @Test
    def testTreeMatchesIrradianceAt(): Unit \ Assert =
        let sh = skyHarmonics();
        let packed = SphericalHarmonics.coefficientsOf(sh) |> List.flatMap(c -> c#x :: c#y :: c#z :: Nil) |> List.toVector;
        let normals = Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(0.0, -1.0, 0.0) :: Vec3.normalized(Vec3.v3(0.3, 0.5, -0.8)) :: Vec3.normalized(Vec3.v3(-0.7, -0.2, 0.4)) :: Nil;
        let worst = normals |> List.map(n -> {
            let (r, g, b) = SoftRaster3dLight.lightAt(0, noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, n#x, n#y, n#z,
                                                      0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, packed, 1.0);
            let (er, eg, eb) = SphericalHarmonics.irradianceAt(sh, n);
            Float64.max(Float64.abs(r - er), Float64.max(Float64.abs(g - eg), Float64.abs(b - eb)))
        }) |> List.foldLeft(Float64.max, 0.0);
        Assert.assertTrue(worst < 1.0e-6)

    /// 割合 0 なら係数を読まず ambient のまま（同じビット）。
    @Test
    def testZeroContributionKeepsAmbient(): Unit \ Assert =
        let packed = Vector.repeat(27, 5.0);
        let (r, _, _) = SoftRaster3dLight.lightAt(0, noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                  0.3, 0.3, 0.3, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, packed, 0.0);
        Assert.assertEq(expected = 0.3, r)

}
