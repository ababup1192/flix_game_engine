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
        { skinned = false, uv = false, normalMap = false, lightmap = false, blend = false, doubleSided = false, coverage = false, metallicRoughness = false, pointShadows = false, physicalUnits = false }

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

    /// 全体の登録の絵 "chars"（番号 3）だけがある絵の引き先。
    def charsTexture(name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO =
        checked_ecast(if (name == "chars") Some({ texId = 3, width = 16.0, height = 16.0, flipped = false, version = "" }) else None)

    /// 1 回の prepare で絵 "chars" を引ける場面を準備して描く。
    def paintWithChars(log: Render3d.FakeGl.Recorded, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let prepared = Render3d.prepareNumbered(recordingGl(log), freshState(), 1i64, charsTexture, Render3d.FakeGl.dest(), cmdOf(scene) :: Nil);
        prepared#draw(Render3d.FakeGl.viewport(), 0)

    /// 目の前（z = 0）に立てた絵 "chars" のビルボード。
    def charBoard(): Scene3d.Billboard3d =
        Scene3d.billboard("chars", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } }, Vec3.v3(0.3, 0.0, 0.0), { x = 0.5, y = 0.8 })

    /// castShadows のビルボードは、色の pass の 1 回に加えて太陽の影の地図にも 1 回描く。
    @Test
    def testCastingBillboardIsDrawnIntoSunMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paintWithChars(log, { billboards = (charBoard() |> Scene3d.withCastShadows(true)) :: Nil | sunScene(Some(sunLight(Some(smallShadow())))) });
        Assert.assertEq(expected = 2, timesCalled("drawArraysInstanced", log))

    /// castShadows でないビルボードは影の地図に描かない（色の pass の 1 回だけ）。
    @Test
    def testPlainBillboardIsNotDrawnIntoSunMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paintWithChars(log, { billboards = charBoard() :: Nil | sunScene(Some(sunLight(Some(smallShadow())))) });
        Assert.assertEq(expected = 1, timesCalled("drawArraysInstanced", log))

    /// スポットの影の地図には castShadows のビルボードも描かない（太陽の地図の 1 回だけが足される）。
    @Test
    def testCastingBillboardSkipsSpotMap(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let base = sunScene(Some(sunLight(Some(smallShadow()))));
        paintWithChars(log, { billboards = (charBoard() |> Scene3d.withCastShadows(true)) :: Nil, spotLights = shadowSpot() :: Nil | base });
        Assert.assertEq(expected = 2, timesCalled("drawArraysInstanced", log))

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

    /// ビルボードは receiveShadows の物（uReceive = 1）で光を当てる時だけ太陽の影を引き、ほかは太陽の影の割合が 1 のまま。
    @Test
    def testBillboardReceivesSunShadowOnlyWhenAsked(): Unit \ Assert =
        let source = Render3dGlsl.billboardFragmentSource();
        Assert.assertTrue(indexOf("if (vLit == 2) r3d_sunLit = sunLitAt(", source) >= 0)
}
