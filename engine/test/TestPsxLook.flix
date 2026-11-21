// TestPsxLook — PS1 風の描き方の値（Scene3d.PsxLook）: 既定は切・色の丸めの式（Scene3d.Psx.quantize）・ディザの表・値のそろえ方・先に組む変種の鍵。
mod TestPsxLook {

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    def plain(): Scene3d.Scene3dCmd = Scene3d.scene(camera(), Vec2.v2(320.0, 240.0))

    @Test
    def testSceneStartsWithPsxOff(): Unit \ Assert =
        Assert.assertFalse(Scene3d.Psx.isOn(plain()#psx))

    @Test
    def testPresetTurnsPsxOn(): Unit \ Assert =
        Assert.assertTrue(Scene3d.Psx.isOn(Scene3d.withPsx(Scene3d.psxPreset(), plain())#psx))

    @Test
    def testColorDepthAloneTurnsPsxOn(): Unit \ Assert =
        Assert.assertTrue(Scene3d.Psx.isOn({ colorDepth = 5 | Scene3d.psxOff() }))

    @Test
    def testNegativeColorDepthIsOff(): Unit \ Assert =
        Assert.assertEq(expected = 0, Scene3d.Psx.colorDepthOf({ colorDepth = -3 | Scene3d.psxOff() }))

    @Test
    def testColorDepthIsClampedToEightBits(): Unit \ Assert =
        Assert.assertEq(expected = 8, Scene3d.Psx.colorDepthOf({ colorDepth = 12 | Scene3d.psxOff() }))

    @Test
    def testColorDepthInRangeIsKept(): Unit \ Assert =
        Assert.assertEq(expected = 5, Scene3d.Psx.colorDepthOf({ colorDepth = 5 | Scene3d.psxOff() }))

    @Test
    def testNanSnapAndAffineAreOff(): Unit \ Assert =
        let look = { vertexSnap = Float64.nan(), affineTextureMapping = Float64.nan() | Scene3d.psxOff() };
        Assert.assertFalse(Scene3d.Psx.isOn(look))

    @Test
    def testAffineIsClampedToOne(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, Scene3d.Psx.affineOf({ affineTextureMapping = 3.0 | Scene3d.psxOff() }))

    /// 5 ビット・ディザなしでは、8 bit の値 100（0.392）は 100 / 8 = 12 段 → 12 / 31。
    @Test
    def testQuantizeFiveBitsWithoutDither(): Unit \ Assert =
        Assert.assertEq(expected = 12.0 / 31.0, Scene3d.Psx.quantize(5, 0.0, 100.0 / 255.0))

    /// ディザ +3（PS1 の表の最大 × 8）は 8 bit の値 100 を 103 にし、まだ 12 段のまま。
    @Test
    def testQuantizeDitherBelowTheStepKeepsTheStep(): Unit \ Assert =
        Assert.assertEq(expected = 12.0 / 31.0, Scene3d.Psx.quantize(5, 3.0 / 8.0, 100.0 / 255.0))

    /// +4 段相当（0.5 段）なら 104 で 13 段。
    @Test
    def testQuantizeDitherReachingTheStepMovesUp(): Unit \ Assert =
        Assert.assertEq(expected = 13.0 / 31.0, Scene3d.Psx.quantize(5, 0.5, 100.0 / 255.0))

    @Test
    def testQuantizeKeepsWhite(): Unit \ Assert =
        Assert.assertEq(expected = 1.0, Scene3d.Psx.quantize(5, 0.375, 1.0))

    @Test
    def testQuantizeKeepsBlack(): Unit \ Assert =
        Assert.assertEq(expected = 0.0, Scene3d.Psx.quantize(5, -0.5, 0.0))

    @Test
    def testZeroBitsLeavesColor(): Unit \ Assert =
        Assert.assertEq(expected = 0.4242, Scene3d.Psx.quantize(0, 0.3, 0.4242))

    /// PS1 の表の左上は −4（÷ 8 で −0.5）。
    @Test
    def testPsxDitherTopLeft(): Unit \ Assert =
        Assert.assertEq(expected = -0.5, Scene3d.Psx.ditherAt(Scene3d.DitherPattern.Psx, 0, 0))

    /// (1, 1) は −2。
    @Test
    def testPsxDitherDiagonal(): Unit \ Assert =
        Assert.assertEq(expected = -0.25, Scene3d.Psx.ditherAt(Scene3d.DitherPattern.Psx, 1, 1))

    /// (2, 0) は −3。
    @Test
    def testPsxDitherTopRow(): Unit \ Assert =
        Assert.assertEq(expected = -0.375, Scene3d.Psx.ditherAt(Scene3d.DitherPattern.Psx, 2, 0))

    /// 格子は 4 で繰り返す（(4, 8) は (0, 0) と同じ）。
    @Test
    def testPsxDitherRepeatsEveryFour(): Unit \ Assert =
        Assert.assertEq(expected = -0.5, Scene3d.Psx.ditherAt(Scene3d.DitherPattern.Psx, 4, 8))

    @Test
    def testBayerDitherIsCentered(): Unit \ Assert =
        let all = List.range(0, 16) |> List.map(i -> Scene3d.Psx.ditherAt(Scene3d.DitherPattern.Bayer4x4, Int32.remainder(i, 4), i / 4));
        Assert.assertEq(expected = 0.0, List.foldLeft((a, b) -> a + b, 0.0, all))

    @Test
    def testOffDitherIsZero(): Unit \ Assert =
        Assert.assertEq(expected = 0.0, Scene3d.Psx.ditherAt(Scene3d.DitherPattern.Off, 3, 2))

    @Test
    def testPreloadVariantKeyOfPlainSceneIsEmpty(): Unit \ Assert =
        Assert.assertEq(expected = "", Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(plain())))

    @Test
    def testPreloadVariantKeyHasPsx(): Unit \ Assert =
        Assert.assertEq(expected = "+psx", Scene3d.preloadVariantKey(Scene3d.preloadVariantOf(Scene3d.withPsx(Scene3d.psxPreset(), plain()))))
}
