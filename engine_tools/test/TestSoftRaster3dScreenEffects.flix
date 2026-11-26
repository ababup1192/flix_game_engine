// CPU の SSAO の mask（SoftRaster3d.ScreenEffects）を具体値で固定する: 何も無い画素は暗くしない・目を囲む凹んだ面は暗くなる・
// 場面の画素が読む mask の画素・R32Float の Pass の値を half に丸めない。
mod TestSoftRaster3dScreenEffects {

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 50.0, lensShift = Vec2.zero() }

    def scene(): Scene3d.Scene3dCmd = Scene3d.scene(camera(), { x = 32.0, y = 16.0 })

    /// 32 × 16 の奥行きの絵（全部の画素が値 d）。
    def flatDepth(d: Float64): ShaderEval.HdrTexture =
        ShaderEval.hdrTextureOfHalves(32, 16, Vector.range(0, 32 * 16) |> Vector.flatMap(_ -> Vector#{RenderUtil.f32(d), 0.0f32, 0.0f32, 1.0f32}))

    def maskOf(depth: ShaderEval.HdrTexture): SoftRaster3d.ScreenEffects.Mask \ IO =
        SoftRaster3d.ScreenEffects.maskOf({ depth = depth, rect = (0, 0, 32, 16), layer = (32, 16), scene = scene(), depthRange = 60.0,
                                            ao = { scale = 1.0 | ScreenEffects3d.ambientOcclusion() } })

    @Test
    def testEmptyDepthIsNotDarkened(): Unit \ Assert + IO =
        Assert.assertTrue(Vector.forAll(v -> v == 1.0, maskOf(flatDepth(1.0))#values))

    @Test
    def testConcaveSurfaceAroundTheEyeIsDarkened(): Unit \ Assert + IO =
        Assert.assertTrue(SoftRaster3d.ScreenEffects.valueAt(maskOf(flatDepth(0.02)), 16, 8) < 1.0)

    @Test
    def testMaskValuesAreEightBit(): Unit \ Assert + IO =
        Assert.assertTrue(Vector.forAll(v -> Float64.floor(v * 255.0 + 0.5) / 255.0 == v, maskOf(flatDepth(0.02))#values))

    @Test
    def testHalfScaleMaskIsHalfTheLayer(): Unit \ Assert =
        Assert.assertEq(expected = (16, 8), ScreenEffects3d.maskSizeOf({ scale = 0.5 | ScreenEffects3d.ambientOcclusion() }, 32, 16))

    @Test
    def testLayerPixelReadsTheMaskPixelUnderItsCenter(): Unit \ Assert =
        let m = { width = 2, height = 2, values = Vector#{0.1, 0.2, 0.3, 0.4}, layer = (4, 4), lightAffect = 0.0 };
        Assert.assertEq(expected = 0.4, SoftRaster3d.ScreenEffects.valueAt(m, 3, 3))

    @Test
    def testDirectLightIsUntouchedWithoutLightAffect(): Unit \ Assert =
        let m = { width = 1, height = 1, values = Vector#{0.5}, layer = (1, 1), lightAffect = 0.0 };
        Assert.assertEq(expected = 1.0, SoftRaster3d.ScreenEffects.directOf(m, 0.5))

    @Test
    def testTapsAreRoundedIntoFourToSixteen(): Unit \ Assert =
        Assert.assertEq(expected = (4, 16), (ScreenEffects3d.tapsOf({ taps = 1 | ScreenEffects3d.ambientOcclusion() }),
                                             ScreenEffects3d.tapsOf({ taps = 99 | ScreenEffects3d.ambientOcclusion() })))
}
