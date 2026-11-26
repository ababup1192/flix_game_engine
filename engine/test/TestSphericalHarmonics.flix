// 景色の拡散の光（SphericalHarmonics）と Scene3d.withSkyContribution の約束。座標の約束: X = 東・Y = 上・Z = 北。
mod TestSphericalHarmonics {

    /// 横 w・縦 h の正距円筒の絵（行 y の上半分は top・下半分は bottom の 8bit の灰）。
    def panorama(w: Int32, h: Int32, top: Int32, bottom: Int32): Texture3d.Texture3d =
        let grey = (v: Int32) -> Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(v, 16), Int32.bitwiseOr(Int32.leftShift(v, 8), v)));
        let pixels = Vector.range(0, w * h) |> Vector.map(k -> if (k / w < h / 2) grey(top) else grey(bottom));
        match Texture3d.fromArgb(w, h, pixels) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        }

    def redOf(sh: SphericalHarmonics.SphericalHarmonics, n: Vec3.Vec3): Float64 =
        let (r, _, _) = SphericalHarmonics.irradianceAt(sh, n);
        r

    def shOf(t: Texture3d.Texture3d): SphericalHarmonics.SphericalHarmonics = match SphericalHarmonics.fromEquirectangular(t) {
        case Some(sh) => sh
        case None     => bug!("求められない")
    }

    /// 明るさ 1 の一様な白の景色は、どの向きの面にも 1 の拡散の光を当てる（ambient 1.0 と同じ明るさ）。
    @Test
    def testUniformWhiteGivesOne(): Unit \ Assert =
        let sh = shOf(panorama(64, 32, 255, 255));
        let worst = (Vec3.v3(0.0, 1.0, 0.0) :: Vec3.v3(0.0, -1.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 0.0, -1.0) :: Nil)
            |> List.map(n -> Float64.abs(redOf(sh, n) - 1.0)) |> List.foldLeft(Float64.max, 0.0);
        Assert.assertTrue(worst < 1.0e-3)

    /// 上半分だけ明るい景色では、上向きの面が下向きの面より明るい。
    @Test
    def testBrightSkyLightsUpwardFaces(): Unit \ Assert =
        let sh = shOf(panorama(64, 32, 255, 0));
        Assert.assertTrue(redOf(sh, Vec3.v3(0.0, 1.0, 0.0)) > 0.8 and redOf(sh, Vec3.v3(0.0, -1.0, 0.0)) < 0.2)

    /// 2 回目は同じ絵の控えを返す（係数が同じ）。
    @Test
    def testSecondCallReturnsSameCoefficients(): Unit \ Assert =
        let t = panorama(32, 16, 200, 40);
        let flat = (sh: SphericalHarmonics.SphericalHarmonics) -> SphericalHarmonics.coefficientsOf(sh) |> List.map(c -> (c#x, c#y, c#z));
        Assert.assertEq(expected = flat(shOf(t)), flat(shOf(t)))

    /// 係数が 9 個でなければ Err。
    @Test
    def testEightCoefficientsAreRejected(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(SphericalHarmonics.fromCoefficients(List.repeat(8, Vec3.zero()))))

    /// NaN の係数は Err。
    @Test
    def testNanCoefficientIsRejected(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(SphericalHarmonics.fromCoefficients(Vec3.v3(Float64.nan(), 0.0, 0.0) :: List.repeat(8, Vec3.zero()))))

    /// 割合は 0..1 に丸める（2 は 1・NaN は 0）。
    @Test
    def testSkyContributionIsClamped(): Unit \ Assert =
        let e = Scene3d.environmentMap(panorama(8, 4, 255, 255));
        Assert.assertEq(expected = (1.0, 0.0), (Scene3d.skyContributionOf(Scene3d.withSkyContribution(2.0, e)),
                                               Scene3d.skyContributionOf(Scene3d.withSkyContribution(Float64.nan(), e))))

    /// irradianceOf は withIrradiance で渡した物だけを返す（絵から求めはしない）。
    @Test
    def testIrradianceOfReturnsOnlyGiven(): Unit \ Assert =
        let e = Scene3d.environmentMap(panorama(8, 4, 255, 255));
        Assert.assertTrue(Option.isEmpty(Scene3d.irradianceOf(e)))

    /// 割合が 0 の場面は既定の変種（+sh の鍵が付かない）。
    @Test
    def testZeroContributionKeepsDefaultVariant(): Unit \ Assert =
        let t = panorama(8, 4, 255, 255);
        let scene = { environmentMap = Some(Scene3d.environmentMap(t)) | Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 10.0, lensShift = Vec2.zero() }, Vec2.v2(64.0, 48.0)) };
        Assert.assertEq(expected = "", Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(scene)))

    /// 割合が 0 より大きい場面は +sh の変種。
    @Test
    def testPositiveContributionUsesShVariant(): Unit \ Assert =
        let t = panorama(8, 4, 255, 255);
        let scene = { environmentMap = Some(Scene3d.environmentMap(t) |> Scene3d.withSkyContribution(1.0)) | Scene3d.scene({ eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 10.0, lensShift = Vec2.zero() }, Vec2.v2(64.0, 48.0)) };
        Assert.assertEq(expected = "+sh", Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(scene)))
}
