// TestUniformLayout — WGSL の uniform の struct の欄の表から求めたバイト位置と、表から作った struct の字を固定する。

mod Render3d.TestUniformLayout {
    use Render3d.UniformLayout.{bytesOf, lightFields, lightOffsets, offsetOf, sceneFields, sceneOffsets, structSource}

    /// R3dScene の全部の欄の位置（WGSL の並びの決まり: vec3f の後ろに 4 バイトの欄・pad で 272 まで埋め・mat4 は 64・光の配列は 16 バイト × 点光源 8 本・スポット 2 本）。
    @Test
    def testSceneFieldOffsets(): Unit \ Assert =
        Assert.assertEq(expected =
            ("uAmbient", 0) :: ("uHemisphere", 12) :: ("uEye", 16) :: ("uToonSteps", 28) :: ("uFogColor", 32) :: ("uFogOn", 44) ::
            ("uFogRange", 48) :: ("uPointCount", 56) :: ("uSpotCount", 60) :: ("uSunDir", 64) :: ("uSunShadowOn", 76) :: ("uSunColor", 80) ::
            ("uSunNormalShift", 92) :: ("uSunForward", 96) :: ("uSunBias", 108) :: ("uSunFade", 112) :: ("uSunPcf", 120) :: ("uSunStrength", 124) ::
            ("uZenith", 128) :: ("uCurve", 140) :: ("uHorizon", 144) :: ("uEnvOn", 156) :: ("uGround", 160) :: ("uEnvBoxOn", 172) ::
            ("uEnvBoxMin", 176) :: ("uEnvLevels", 188) :: ("uEnvBoxMax", 192) :: ("uEnvIntensity", 204) :: ("uEnvBoxCenter", 208) :: ("uShadowOn", 220) ::
            ("uDepthRange", 224) :: ("uShadowSpot", 232) :: ("uShadowPcf", 236) :: ("uShadowBias", 240) :: ("uShadowStrength", 244) :: ("uDepthOut", 248) ::
            ("pad0", 252) :: ("pad1", 256) :: ("pad2", 260) :: ("pad3", 264) :: ("pad4", 268) :: ("uShadowMatrix", 272) :: ("uSunMatrix", 336) ::
            ("uPointPos", 400) :: ("uPointColor", 528) :: ("uPointRange", 656) :: ("uSpotPos", 784) :: ("uSpotDir", 816) :: ("uSpotColor", 848) ::
            ("uSpotRange", 880) :: ("uSpotCone", 912) :: ("uSkyForward", 944) :: ("uSkyRight", 960) :: ("uSkyUp", 976) :: Nil,
            namedOffsets(sceneFields(), sceneOffsets()))

    /// 表の (WGSL の欄の名前, 位置) の並び。
    def namedOffsets(fields: List[Render3d.UniformLayout.Field[f]], offsets: Map[f, Int32]): List[(String, Int32)] with Order[f], ToString[f] =
        fields |> List.map(field -> { let (key, name, _) = field; (name, offsetOf(offsets, key)) })

    /// R3dScene は 992 バイト・R3dLight は 160 バイト（どちらも 16 の倍数）。
    @Test
    def testStructBytes(): Unit \ Assert =
        Assert.assertEq(expected = (992, 160), (bytesOf(sceneFields()), bytesOf(lightFields())))

    /// R3dLight の欄の位置: 点光源 8 本の値の後に atlas（128）・bias（144）・1 / unitsPerMeter²（152）・pad0（156）。
    @Test
    def testLightFieldOffsets(): Unit \ Assert =
        Assert.assertEq(expected = ("uPointShadow", 0) :: ("uPointShadowAtlas", 128) :: ("uPointShadowBias", 144) :: ("uInverseUnitsPerMeterSquared", 152) :: ("pad0", 156) :: Nil,
                        namedOffsets(lightFields(), lightOffsets()))

    /// struct の字は 16 バイトの区切りで改行する（R3dLight の 3 行目は vec2f・f32・f32 が 1 行）。
    @Test
    def testStructSourceBreaksEvery16Bytes(): Unit \ Assert =
        Assert.assertEq(expected = "struct R3dLight {\n    uPointShadow: array<vec4f, 8>,\n    uPointShadowAtlas: vec4f,\n" +
                                   "    uPointShadowBias: vec2f, uInverseUnitsPerMeterSquared: f32, pad0: f32,\n};\n",
                        structSource("R3dLight", lightFields()))
}
