// TestLightModel3d — 光の式の木の GLSL の出口と、CPU の描き手へ渡す光の並び。

/// 白・強さ 2・range 4 の点光源を (1, 2, 3) に置いた物。
def pointAt123(): Scene3d.PointLight =
    { position = Vec3.v3(1.0, 2.0, 3.0), color = Color.rgb(1.0, 0.5, 0.25), intensity = 2.0, range = 4.0 }

/// 点光源 1 本は 位置 3・color × intensity 3・range² の 7 個に並ぶ。
@Test
def testPackPointLightsLayout(): Unit \ Assert =
    Assert.assertEq(expected = Vector#{ 1.0, 2.0, 3.0, 2.0, 1.0, 0.5, 16.0 }, LightModel3d.packPointLights(pointAt123() :: Nil))

/// スポット 1 本は spotStride() 個に並ぶ。
@Test
def testPackSpotLightsStride(): Unit \ Assert =
    let spot = Scene3d.spotLight(Vec3.v3(0.0, 4.0, 0.0), Vec3.zero(), 1.0);
    Assert.assertEq(expected = LightModel3d.spotStride() * 2, Vector.length(LightModel3d.packSpotLights(spot :: spot :: Nil)))

/// 画素ごとの入力は引数、場面の値は今の Render3d の uniform の名前で読む。
@Test
def testToGlslReadsUniformsAndPerPixelInputs(): Unit \ Assert =
    let e = LightModel3d.Vec3Expr.Add(LightModel3d.Vec3Expr.In(LightModel3d.Vec3Input.Ambient), LightModel3d.Vec3Expr.In(LightModel3d.Vec3Input.Normal));
    Assert.assertEq(expected = "vec3 f(vec3 n) {\n    return vec3((uAmbient.x + n.x), (uAmbient.y + n.y), (uAmbient.z + n.z));\n}\n",
                    LightModel3d.Codegen.toGlsl("f", LightModel3d.Vec3Input.Normal :: Nil, e))

/// 光の式の GLSL は、点光源とスポットの上限の回数の for で足し、影を spotShadow で読む。
@Test
def testToGlslLightingModelLoopsOverLights(): Unit \ Assert =
    let glsl = LightModel3d.Codegen.toGlsl("lightAt", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: Nil, LightModel3d.lightingModel());
    Assert.assertTrue(String.startsWith(prefix = "vec3 lightAt(vec3 p, vec3 n) {", glsl) and
                      String.contains(substr = "for (int i = 0; i < ${Scene3d.maxPointLights()}; i++)", glsl) and
                      String.contains(substr = "for (int i = 0; i < ${Scene3d.maxSpotLights()}; i++)", glsl) and
                      String.contains(substr = "spotShadow(i, p)", glsl))

/// スポット 1 本は 位置 3・向き 3・外の cos・内の cos・color × intensity 3・range² の順に並ぶ。
@Test
def testPackSpotLightsLayout(): Unit \ Assert =
    let spot = { color = Color.rgb(1.0, 0.5, 0.25), intensity = 2.0, range = 3.0 | Scene3d.spotLight(Vec3.v3(0.0, 4.0, 0.0), Vec3.zero(), 1.0) };
    let edge = Scene3d.spotConeOf(spot);
    Assert.assertEq(expected = Vector#{ 0.0, 4.0, 0.0, 0.0, -1.0, 0.0, edge#outerCos, edge#innerCos, 2.0, 1.0, 0.5, 9.0 },
                    LightModel3d.packSpotLights(spot :: Nil))

/// lightmap・かすみ・空の式も GLSL に生成でき、今の Render3d の uniform を読む。
@Test
def testToGlslOtherModelsReadTheirUniforms(): Unit \ Assert =
    let lightmap = LightModel3d.Codegen.toGlsl("lightmapLightAt", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Normal :: LightModel3d.Vec3Input.LightmapColor :: Nil,
                                                LightModel3d.lightmapLightingModel());
    let fog = LightModel3d.Codegen.toGlsl("fogged", LightModel3d.Vec3Input.Position :: LightModel3d.Vec3Input.Color :: Nil, LightModel3d.fogModel());
    let sky = LightModel3d.Codegen.toGlsl("skyColor", LightModel3d.Vec3Input.SkyDirection :: Nil, LightModel3d.skyModel());
    Assert.assertTrue(String.contains(substr = "float(uLightmapSrgb)", lightmap) and String.contains(substr = "uLightmapIntensity", lightmap) and
                      String.contains(substr = "uFogRange.x", fog) and String.contains(substr = "uFogColor.x", fog) and
                      String.contains(substr = "uCurve", sky) and String.contains(substr = "uZenith.x", sky))
