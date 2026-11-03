// TestSoftRaster3dLight — LightModel3d の木から生成した CPU の光の関数（gen/SoftRaster3dLight.flix）が、入っている物と木で食い違わないこと・
// 空の式の値（SoftRaster3d が空の画素に使う道）。
mod SoftRaster3d.TestSoftRaster3dLight {

    /// 入っている gen/SoftRaster3dLight.flix が、今の木から作り直した字と同じ（違えば `make gen-light3d`）。
    @Test
    def testGeneratedSourceMatchesLightModel(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(LightModel3d.Codegen.generateFlix(SoftRaster3dLightGen.hooks())), SoftRaster3dLightGen.readCurrent())

    /// 入っている test/gen/SoftRaster3dLightCases.flix（生成器の角の形。この作業場で組めることが確かめになる）が、今の生成器の字と同じ。
    @Test
    def testGeneratedCasesMatchGenerator(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(LightModel3d.Codegen.generateFlixCases(SoftRaster3dLightGen.hooks())), SoftRaster3dLightGen.readCases())

    /// 引数は書いた並び（法線が先）のまま渡る（値は 点 − 法線）。
    @Test
    def testCasesDeclaredOrderTakesNormalFirst(): Unit \ Assert =
        Assert.assertEq(expected = (9.0, 18.0, 27.0), SoftRaster3dLightCases.declaredOrder(1.0, 2.0, 3.0, 10.0, 20.0, 30.0))

    /// 文のある枝の vec3 の Select は、条件が真なら枝の Let の値（法線 × 2）、偽なら法線。
    @Test
    def testCasesVec3BranchTakesBothSides(): Unit \ Assert =
        Assert.assertEq(expected = ((2.0, 4.0, 6.0), (1.0, -2.0, 3.0)),
                        (SoftRaster3dLightCases.vec3BranchWithLet(1.0, 2.0, 3.0), SoftRaster3dLightCases.vec3BranchWithLet(1.0, -2.0, 3.0)))

    /// 同じエントリの中身の違う 2 つのループ: 点光源 1 本（color × intensity = (1, 2, 3)）なら color × 2 + color。
    @Test
    def testCasesTwoLoopsAddBothLoops(): Unit \ Assert =
        let points = LightModel3d.packPointLights({ position = Vec3.zero(), color = Color.rgb(1.0, 2.0, 3.0), intensity = 1.0, range = 1.0 } :: Nil);
        Assert.assertEq(expected = (3.0, 6.0, 9.0), SoftRaster3dLightCases.twoLoops(points))

    /// スポットのループは 外の cos・内の cos・range² の欄を読み、toon で丸める（白・強さ 1・range 1 の 1 本で 外 + 内 + 1 を 4 段に）。
    @Test
    def testCasesSpotFieldsReadTheRightSlots(): Unit \ Assert =
        let spot = { color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = 1.0 | Scene3d.spotLight(Vec3.v3(0.0, 1.0, 0.0), Vec3.zero(), 1.0) };
        let edge = Scene3d.spotConeOf(spot);
        let v = Float64.floor((edge#outerCos + edge#innerCos + 1.0) * 4.0 + 0.5) / 4.0;
        Assert.assertEq(expected = (v, v, v), SoftRaster3dLightCases.spotFields(4, LightModel3d.packSpotLights(spot :: Nil)))

    /// 成分が同じ式の Make と負の数: y² × −2。
    @Test
    def testCasesSameComponentsWithNegativeNumber(): Unit \ Assert =
        Assert.assertEq(expected = (-18.0, -18.0, -18.0), SoftRaster3dLightCases.sameComponents(0.0, 3.0, 0.0))

    /// 真上が青・地平が白・真下が茶の空。
    def threeColorSky(): Scene3d.Sky3d =
        Scene3d.gradientSky(Color.rgb(0.0, 0.0, 1.0), Color.rgb(1.0, 1.0, 1.0), Color.rgb(0.5, 0.25, 0.0))

    def skyColorOf(s: Scene3d.Sky3d, dir: Vec3.Vec3): (Float64, Float64, Float64) =
        SoftRaster3d.skyColorWith(SoftRaster3d.skyColorsWith(c -> c, s), dir)

    /// 真上を向くと zenith の色。
    @Test
    def testSkyStraightUpIsZenith(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 0.0, 1.0), skyColorOf(threeColorSky(), Vec3.v3(0.0, 1.0, 0.0)))

    /// 真横を向くと horizon の色。
    @Test
    def testSkyHorizontalIsHorizon(): Unit \ Assert =
        Assert.assertEq(expected = (1.0, 1.0, 1.0), skyColorOf(threeColorSky(), Vec3.v3(0.0, 0.0, 1.0)))

    /// 真下を向くと ground の色。
    @Test
    def testSkyStraightDownIsGround(): Unit \ Assert =
        Assert.assertEq(expected = (0.5, 0.25, 0.0), skyColorOf(threeColorSky(), Vec3.v3(0.0, -1.0, 0.0)))

    /// 曲がり 2 で上へ 30°（d.y = 0.5）は、地平と天頂の間を 0.5² = 0.25 だけ寄せた色（白から青へ 1/4）。
    @Test
    def testSkyCurveTwoAtThirtyDegrees(): Unit \ Assert =
        let sky = Scene3d.withSkyCurve(2.0, threeColorSky());
        Assert.assertEq(expected = (0.75, 0.75, 1.0), skyColorOf(sky, Vec3.v3(0.0, 0.5, Num.sqrt(0.75))))
}
