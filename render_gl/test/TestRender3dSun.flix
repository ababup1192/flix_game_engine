// 3D の描き手の太陽の光（Scene3d.directionalLight）: 影の地図を描くか・何枚描くか・知らせ・シェーダーの字（記録する GL と字で確かめる）。
mod Render3d.TestRender3dSun {
    use Render3d.FakeGl.{cmdOf, freshRecorded, freshState, paint, recordingGl, sceneOf, shadowSpot, stderrOf, timesCalled}

    def sunLight(shadow: Option[Scene3d.DirectionalShadow]): Scene3d.DirectionalLight =
        { shadow = shadow | Scene3d.directionalLight(Vec3.v3(0.3, -1.0, 0.4)) }

    def smallShadow(): Scene3d.DirectionalShadow = { mapSize = 64, pcfRadius = 1 | Scene3d.directionalShadow() }

    def sunScene(sun: Option[Scene3d.DirectionalLight]): Scene3d.Scene3dCmd =
        { directionalLight = sun | sceneOf(Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) :: Nil) }

    def materialSource(kind: Render3d.ProgramKind): String =
        Render3dGlsl.materialFragmentSource({ uniforms = "uniform float uTime;\n", functions = "void materialEval(out vec4 albedo, out vec3 emission) {}\n",
                                              paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }, kind)

    def plainKind(): Render3d.ProgramKind =
        { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false }

    def indexOf(part: String, s: String): Int32 = String.indexOf(substr = part, s) |> Option.getWithDefault(-1)

    /// 影を落とす太陽は、地図を 1 枚作って描く（色の draw に地図の draw が 1 つ足される）。
    @Test
    def testShadowedSunDrawsOneMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(sunScene(Some(sunLight(Some(smallShadow()))))) :: Nil);
        Assert.assertEq(expected = (1, 2), (timesCalled("texImageDepth24", log), timesCalled("drawElementsInstanced", log)))

    /// 影を落とさない太陽は地図を作らない。
    @Test
    def testSunWithoutShadowDrawsNoMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(sunScene(Some(sunLight(None)))) :: Nil);
        Assert.assertEq(expected = (0, 1), (timesCalled("texImageDepth24", log), timesCalled("drawElementsInstanced", log)))

    /// mapSize 0 以下は影なし。
    @Test
    def testSunMapSizeZeroDrawsNoMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(sunScene(Some(sunLight(Some({ mapSize = 0 | smallShadow() }))))) :: Nil);
        Assert.assertEq(expected = 0, timesCalled("texImageDepth24", log))

    /// 使わない太陽（intensity 0）は、影を付けても地図を描かない（太陽なしと同じ）。
    @Test
    def testUnusableSunDrawsNoMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let scene = sunScene(Some({ intensity = 0.0 | sunLight(Some(smallShadow())) }));
        discard stderrOf(() -> paint(recordingGl(log), freshState(), cmdOf(scene) :: Nil));
        Assert.assertEq(expected = (0, 1), (timesCalled("texImageDepth24", log), timesCalled("drawElementsInstanced", log)))

    /// 影を落とすスポットと太陽が 1 つの場面に並ぶと、地図は 2 枚。
    @Test
    def testSunAndSpotShadowDrawTwoMaps(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let scene = { spotLights = shadowSpot() :: Nil | sunScene(Some(sunLight(Some(smallShadow())))) };
        paint(recordingGl(log), freshState(), cmdOf(scene) :: Nil);
        Assert.assertEq(expected = (2, 3), (timesCalled("texImageDepth24", log), timesCalled("drawElementsInstanced", log)))

    /// 使わない太陽は理由を 1 回だけ知らせる（2 コマ描いても 1 行）。
    @Test
    def testUnusableSunWarnsOnce(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let scene = sunScene(Some({ intensity = 0.0 | sunLight(None) }));
        let text = stderrOf(() -> { paint(gl, state, cmdOf(scene) :: Nil); paint(gl, state, cmdOf(scene) :: Nil) });
        Assert.assertEq(expected = 1, List.count(l -> String.contains(substr = "太陽の intensity", l), String.lines(text)))

    /// 頂点の色・材質のどちらの frag も、光の式を呼ぶ前に太陽の影の割合を main で求める（光の式の木は r3d_sunLit を読む）。
    @Test
    def testFragmentsSetSunLitBeforeLighting(): Unit \ Assert =
        let lit = Render3dGlsl.litFragmentSource();
        let material = materialSource(plainKind());
        Assert.assertTrue(indexOf("r3d_sunLit = sunLitAt(vWorld, n, n);", lit) >= 0 and indexOf("r3d_sunLit = sunLitAt(vWorld, n, n);", lit) < indexOf("lightAt(vWorld, n)", lit)
                          and indexOf("r3d_sunLit = sunLitAt(vWorld, normalize(vNormal), n);", material) >= 0
                          and indexOf("r3d_sunLit = sunLitAt(vWorld, normalize(vNormal), n);", material) < indexOf("lightAt(vWorld, n)", material))

    /// 法線マップを当てた面は、地図を引く点のずらしに当てる前の法線・光の計算に当てた後の法線を使う。
    @Test
    def testNormalMapShiftsByTheUnmappedNormal(): Unit \ Assert =
        let source = materialSource({ uv = true, normalMap = true | plainKind() });
        Assert.assertTrue(indexOf("vec3 n = normalMapped(normalize(vNormal));", source) >= 0
                          and indexOf("r3d_sunLit = sunLitAt(vWorld, normalize(vNormal), n);", source) >= 0)

    /// 裏の面を描く両面の材質は、点のずらしにも裏返した法線を使う。
    @Test
    def testDoubleSidedShiftsByTheFlippedNormal(): Unit \ Assert =
        let source = materialSource({ doubleSided = true | plainKind() });
        Assert.assertTrue(indexOf("r3d_sunLit = sunLitAt(vWorld, facingNormal, n);", source) >= 0)

    /// ビルボードは影を受けない（sunLitAt を呼ばず、太陽の影の割合は 1 のまま）。
    @Test
    def testBillboardDoesNotReceiveSunShadow(): Unit \ Assert =
        let source = Render3dGlsl.billboardFragmentSource();
        Assert.assertEq(expected = (false, true), (indexOf("r3d_sunLit = sunLitAt(", source) >= 0, indexOf("float r3d_sunLit = 1.0;", source) >= 0))
}
