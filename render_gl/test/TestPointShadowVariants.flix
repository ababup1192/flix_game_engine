// 点光源の影（+ps）と Physical の光（+pu）の変種のプログラム: 既定の GLSL・WGSL の字が変わらないこと・変種の鍵と字・uniform の入れ方・atlas の pass。
mod Render3d.TestPointShadowVariants {
    import java.security.MessageDigest
    import java.util.HexFormat
    use Render3d.FakeGl.{cmdOf, freshRecorded, freshState, paint, recordingGl, sceneOf, timesCalled}

    def sha256(text: String): String = unsafe IO {
        HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(String.toBytes(text)))
    }

    def solidGlsl(): ShaderGen.MaterialGlsl =
        { uniforms = "uniform float uTime;\n", functions = "void materialEval(out vec4 albedo, out vec3 emission) {}\n",
          paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def solidWgsl(): ShaderGen.Wgsl.MaterialWgsl =
        { declarations = "", functions = "fn materialEval(vUv: vec2f, vWorld: vec3f, vNormal: vec3f, vColor: vec3f) -> SgMaterial {}\n",
          slots = Nil, paramNames = Nil, texReads = Nil, cutoutAlpha = "albedo.a" }

    def bits(n: Int32): List[List[Bool]] =
        if (n <= 0) Nil :: Nil
        else bits(n - 1) |> List.flatMap(rest -> (false :: rest) :: (true :: rest) :: Nil)

    def kindOf(b: List[Bool]): Render3d.ProgramKind =
        let at = (i: Int32) -> List.nth(i, b) |> Option.getWithDefault(false);
        { skinned = false, uv = at(0), normalMap = at(1), lightmap = at(2), blend = at(3), doubleSided = at(4), coverage = at(5),
          metallicRoughness = at(6), pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false }

    def defaultGlsl(): String =
        Render3dGlsl.lightSource() + Render3dGlsl.litFragmentSource() + Render3dGlsl.billboardFragmentSource() +
        Render3dGlsl.metallicRoughnessSource() + Render3dGlsl.lightmapLightSource() +
        (bits(7) |> List.map(b -> Render3dGlsl.materialFragmentSource(solidGlsl(), kindOf(b))) |> String.flatten)

    def defaultWgsl(): String =
        Render3dWgsl.lightSource() + Render3dWgsl.litFragmentSource() + Render3dWgsl.billboardFragmentSource() +
        Render3dWgsl.metallicRoughnessSource() + Render3dWgsl.sceneDeclarations() +
        (bits(7) |> List.map(b -> Render3dWgsl.materialFragmentSource(solidWgsl(), kindOf(b))) |> String.flatten)

    @Test
    def testDefaultGlslIsUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "f45f5c7ffdba4eed37a1614aa1831766d4207f1af7cba4ae12b6e15e3a630743", sha256(defaultGlsl()))

    @Test
    def testDefaultWgslIsUnchanged(): Unit \ Assert =
        Assert.assertEq(expected = "52eb2adc8f32a9847b311ffa957fbf4b7a54a3f91ac2ff17eff9dd1dc39bc3d0", sha256(defaultWgsl()))

    // ── 変種の鍵と字（GL）──

    def has(part: String, s: String): Bool = String.contains(substr = part, s)

    def shadowed(): Render3d.ShaderVariant = { pointShadows = true, physicalUnits = false, psx = false, skyIrradiance = false }

    def physical(): Render3d.ShaderVariant = { pointShadows = false, physicalUnits = true, psx = false, skyIrradiance = false }

    def plainKind(): Render3d.ProgramKind = kindOf(Nil)

    def keyPrefix(kind: Render3d.ProgramKind): String =
        let key = Render3d.materialKey(Scene3d.materialFieldsOf(Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear)), kind);
        String.takeWhile(c -> c != ':', key)

    @Test
    def testVariantKeysAppendPsAndPu(): Unit \ Assert =
        Assert.assertEq(expected = "3d" :: "3d+ps" :: "3d+pu" :: "3d+ps+pu" :: Nil,
            keyPrefix(plainKind()) :: keyPrefix({ pointShadows = true | plainKind() }) :: keyPrefix({ physicalUnits = true | plainKind() })
                :: keyPrefix({ pointShadows = true, physicalUnits = true | plainKind() }) :: Nil)

    @Test
    def testPointShadowMaterialFillsPointLitBeforeLight(): Unit \ Assert =
        let source = Render3dGlsl.materialFragmentSource(solidGlsl(), { pointShadows = true | plainKind() });
        let fill = String.indexOf(substr = "    r3d_pointShadowsAt(vWorld, normalize(vNormal), n);\n", source) |> Option.getWithDefault(-1);
        let light = String.indexOf(substr = "    vec3 light = lightAt(vWorld, n);\n", source) |> Option.getWithDefault(-1);
        Assert.assertTrue(fill >= 0 and fill < light)

    @Test
    def testPointShadowDeclaresAtlasUniformsOnlyInPs(): Unit \ Assert =
        Assert.assertEq(expected = (true, false),
            (has("uniform vec4 uPointShadow[8];", Render3dGlsl.lightSourceFor(shadowed())), has("uPointShadow", Render3dGlsl.lightSourceFor(physical()))))

    @Test
    def testPhysicalDeclaresUnitsUniformOnlyInPu(): Unit \ Assert =
        Assert.assertEq(expected = (true, false),
            (has("uniform float uInverseUnitsPerMeterSquared;", Render3dGlsl.lightSourceFor(physical())),
             has("uInverseUnitsPerMeterSquared", Render3dGlsl.lightSourceFor(shadowed()))))

    @Test
    def testPhysicalTreeReadsUnitsUniform(): Unit \ Assert =
        Assert.assertTrue(has("* uInverseUnitsPerMeterSquared", Render3dGlsl.lightSourceFor(physical())))

    @Test
    def testPointShadowTreeReadsPointLit(): Unit \ Assert =
        Assert.assertTrue(has("r3d_pointLit[i]", Render3dGlsl.lightSourceFor(shadowed())))

    @Test
    def testLitFragmentFillsPointLitWithFaceNormal(): Unit \ Assert =
        Assert.assertTrue(has("    r3d_pointShadowsAt(vWorld, n, n);\n", Render3dGlsl.litFragmentSourceFor(shadowed())))

    @Test
    def testBillboardIgnoresPointShadows(): Unit \ Assert =
        Assert.assertEq(expected = Render3dGlsl.billboardFragmentSource(), Render3dGlsl.billboardFragmentSourceFor(shadowed()))

    @Test
    def testBillboardTakesPhysicalUnits(): Unit \ Assert =
        let source = Render3dGlsl.billboardFragmentSourceFor({ pointShadows = true, physicalUnits = true, psx = false, skyIrradiance = false });
        Assert.assertEq(expected = (true, false), (has("uInverseUnitsPerMeterSquared", source), has("uPointShadow", source)))

    @Test
    def testPbrAndLightmapUseTheVariantTree(): Unit \ Assert =
        let v = { pointShadows = true, physicalUnits = true, psx = false, skyIrradiance = false };
        Assert.assertEq(expected = (true, true),
            (has("r3d_pointLit[i]", Render3dGlsl.metallicRoughnessSourceFor(v)), has("uInverseUnitsPerMeterSquared", Render3dGlsl.lightmapLightSourceFor(v))))

    // ── 変種の字（WebGPU）──

    @Test
    def testWgslPointShadowFillsPointLitBeforeLight(): Unit \ Assert =
        let source = Render3dWgsl.materialFragmentSource(solidWgsl(), { pointShadows = true | plainKind() });
        let fill = String.indexOf(substr = "    r3d_pointShadowsAt(vWorld, normalize(vNormal), n);\n", source) |> Option.getWithDefault(-1);
        let light = String.indexOf(substr = "    let light = lightAt(vWorld, n);\n", source) |> Option.getWithDefault(-1);
        Assert.assertTrue(fill >= 0 and fill < light)

    @Test
    def testWgslVariantBindingsFollowTheSceneGroup(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, false),
            (has("@group(0) @binding(6) var<uniform> r3dLight: R3dLight;", Render3dWgsl.variantDeclarations(physical())),
             has("@group(0) @binding(7) var uPointShadowMap: texture_depth_2d;", Render3dWgsl.variantDeclarations(shadowed())),
             has("binding(7)", Render3dWgsl.variantDeclarations(physical()))))

    @Test
    def testWgslAtlasRowIsFlippedOnlyWhenRead(): Unit \ Assert =
        let wgsl = Render3dWgsl.lightSourceFor(shadowed());
        Assert.assertEq(expected = (true, true),
            (has("let t = origin + clamp(center + vec2i(dx, dy), vec2i(0), last);", wgsl), has("textureLoad(uPointShadowMap, vec2i(t.x, top - t.y), 0)", wgsl)))

    @Test
    def testWgslBillboardIgnoresPointShadows(): Unit \ Assert =
        Assert.assertEq(expected = Render3dWgsl.billboardFragmentSource(), Render3dWgsl.billboardFragmentSourceFor(shadowed()))

    @Test
    def testLightValueBytesHoldEightCastersAndTail(): Unit \ Assert =
        Assert.assertEq(expected = 336, Render3dWgsl.lightValueBytes())

    /// +sh の GLSL だけが景色の拡散の光の uniform を持つ（既定の字には無い）。
    @Test
    def testShVariantDeclaresShUniforms(): Unit \ Assert =
        let sky = { skyIrradiance = true | Render3d.defaultShaderVariant() };
        let has = (s: String) -> String.contains(substr = "uniform vec3 uSh[9];", s);
        Assert.assertEq(expected = (true, false), (has(Render3dGlsl.lightSourceFor(sky)), has(Render3dGlsl.lightSource())))

    /// +sh の WGSL は R3dLight を binding 6 で宣言する。
    @Test
    def testShVariantDeclaresLightBuffer(): Unit \ Assert =
        Assert.assertTrue(String.contains(substr = "var<uniform> r3dLight: R3dLight;", Render3dWgsl.variantDeclarations({ skyIrradiance = true | Render3d.defaultShaderVariant() })))

    @Test
    def testLayoutCodesAreDefaultLightAtlas(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: 1 :: 1 :: 2 :: 2 :: Nil,
            Render3d.WebGpuRenderer.layoutCodeOf(Render3d.defaultShaderVariant()) :: Render3d.WebGpuRenderer.layoutCodeOf(physical())
                :: Render3d.WebGpuRenderer.layoutCodeOf({ skyIrradiance = true | Render3d.defaultShaderVariant() })
                :: Render3d.WebGpuRenderer.layoutCodeOf(shadowed()) :: Render3d.WebGpuRenderer.layoutCodeOf({ pointShadows = true, physicalUnits = true, psx = false, skyIrradiance = false }) :: Nil)

    // ── 場面の変種 ──

    def lamp(): Scene3d.PointLight = { position = Vec3.v3(0.0, 1.0, 0.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 }

    def triangle(): Scene3d.Instance3d = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity())

    def smallMap(): Scene3d.PointShadowMap = { maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() }

    def lampScene(lights: List[Scene3d.PointLight]): Scene3d.Scene3dCmd =
        { pointLights = lights | sceneOf(triangle() :: Nil) } |> Scene3d.withPointShadows(smallMap())

    @Test
    def testSceneWithoutShadowedLampsKeepsPs(): Unit \ Assert =
        Assert.assertTrue(Render3d.shaderVariantOf(lampScene(Nil))#pointShadows)

    @Test
    def testDefaultSceneIsDefaultVariant(): Unit \ Assert =
        Assert.assertEq(expected = "", Render3d.variantKeyOf(Render3d.shaderVariantOf(sceneOf(triangle() :: Nil))))

    @Test
    def testPhysicalSceneIsPu(): Unit \ Assert =
        Assert.assertEq(expected = "+pu", Render3d.variantKeyOf(Render3d.shaderVariantOf(Scene3d.withLightUnits(Scene3d.LightUnits.Physical, sceneOf(triangle() :: Nil)))))

    // ── uniform の値 ──

    def atlasOf(scene: Scene3d.Scene3dCmd): Scene3d.PointShadows.Atlas =
        match Scene3d.PointShadows.atlasOf(Scene3d.pickLights(scene)) {
            case Some(a) => a
            case None    => bug!("atlas が無い")
        }

    @Test
    def testCastersPutSlotAtThePointIndex(): Unit \ Assert =
        let side = { position = Vec3.v3(8.0, 1.0, 0.0) | lamp() };
        let values = Render3d.Shadow.pointShadowUseOf(5, atlasOf(lampScene(side :: lamp() :: Nil)));
        let slotAt = (i: Int32) -> { let (slot, _, _, _) = Vector.get(i, values#lights); slot };
        Assert.assertEq(expected = (-1.0f32, 0.0f32), (slotAt(0), slotAt(1)))

    @Test
    def testShadowedCasterCarriesDepthTerms(): Unit \ Assert =
        let atlas = atlasOf(lampScene(lamp() :: Nil));
        let values = Render3d.Shadow.pointShadowUseOf(5, atlas);
        let expected = atlas#lights |> List.map(light -> {
            let (a, b) = Scene3d.PointShadows.depthTermsOf(light);
            (0.0f32, RenderUtil.f32(a), RenderUtil.f32(b), RenderUtil.f32(light#strength))
        });
        Assert.assertEq(expected = expected, Vector.get(0, values#lights) :: Nil)

    @Test
    def testUnusedCastersAreMinusOne(): Unit \ Assert =
        let values = Render3d.Shadow.pointShadowUseOf(5, atlasOf(lampScene(lamp() :: Nil)));
        Assert.assertTrue(Vector.forAll(c -> { let (slot, _, _, _) = c; slot == -1.0f32 }, Vector.drop(1, values#lights)))

    @Test
    def testAtlasUniformIsTileColumnsScalePcf(): Unit \ Assert =
        let atlas = atlasOf(lampScene(lamp() :: Nil));
        let values = Render3d.Shadow.pointShadowUseOf(5, atlas);
        Assert.assertEq(expected = (32.0f32, 1.0f32, RenderUtil.f32(atlas#guardScale), 1.0f32), values#atlas)

    // ── atlas の pass（GL）──

    @Test
    def testAtlasIsOneDepthTextureOfThreeByTwoTiles(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(lampScene(lamp() :: Nil)) :: Nil);
        Assert.assertEq(expected = (96, 64) :: Nil, Ref.get(log#depthTextures))

    @Test
    def testAtlasFacesSetViewportPerTile(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(lampScene(lamp() :: Nil)) :: Nil);
        let tiles = Ref.get(log#viewports) |> List.reverse |> List.filter(v -> { let (_, _, w, _) = v; w == 32 });
        Assert.assertEq(expected = (0, 0, 32, 32) :: (32, 0, 32, 32) :: (64, 0, 32, 32) :: (0, 32, 32, 32) :: (32, 32, 32, 32) :: (64, 32, 32, 32) :: Nil, tiles)

    @Test
    def testAtlasIsClearedOnce(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf({ pointLights = Nil | lampScene(Nil) }) :: Nil);
        let base = timesCalled("clear", log);
        let log2 = freshRecorded();
        paint(recordingGl(log2), freshState(), cmdOf(lampScene(lamp() :: Nil)) :: Nil);
        Assert.assertEq(expected = base + 1, timesCalled("clear", log2))

    @Test
    def testNoShadowedLampDrawsNoAtlas(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(lampScene(Nil)) :: Nil);
        Assert.assertEq(expected = 0, timesCalled("texImageDepth24", log))

    @Test
    def testTwoShadowedScenesUseTwoAtlases(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paint(recordingGl(log), freshState(), cmdOf(lampScene(lamp() :: Nil)) :: cmdOf(lampScene(lamp() :: Nil)) :: Nil);
        Assert.assertEq(expected = 2, timesCalled("texImageDepth24", log))

    @Test
    def testShrunkAtlasWarnsOnce(): Unit \ {Assert, IO} =
        let scene = { pointLights = lamp() :: Nil | sceneOf(triangle() :: Nil) } |> Scene3d.withPointShadows({ maxShadowedLights = 1, mapSize = 4096 | Scene3d.pointShadowMap() });
        let state = freshState();
        let printed = Render3d.FakeGl.stderrOf(() -> {
            paint(recordingGl(freshRecorded()), state, cmdOf(scene) :: Nil);
            paint(recordingGl(freshRecorded()), state, cmdOf(scene) :: Nil)
        });
        Assert.assertEq(expected = 1, String.split(regex = "点光源の影の mapSize", printed) |> List.length |> (n -> n - 1))

    // ── ビルボードの影の板（点光源の面・倍率）──

    def charsTexture(name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO =
        checked_ecast(if (name == "chars") Some({ texId = 3, width = 16.0, height = 16.0, flipped = false, version = "" }) else None)

    def paintWithChars(log: Render3d.FakeGl.Recorded, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let prepared = Render3d.prepareNumbered(recordingGl(log), freshState(), 1i64, charsTexture, Render3d.FakeGl.dest(), cmdOf(scene) :: Nil);
        prepared#draw(Render3d.FakeGl.viewport(), 0)

    def boardAt(x: Float64): Scene3d.Billboard3d =
        Scene3d.billboard("chars", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } }, Vec3.v3(x, 0.0, 0.0), { x = 1.0, y = 2.0 })

    def boardScene(boards: List[Scene3d.Billboard3d]): Scene3d.Scene3dCmd = { billboards = boards | lampScene(lamp() :: Nil) }

    def drawsWith(scene: Scene3d.Scene3dCmd): Int32 \ IO =
        let log = freshRecorded();
        paintWithChars(log, scene);
        timesCalled("drawArraysInstanced", log)

    @Test
    def testCastingBillboardIsDrawnIntoPointFaces(): Unit \ {Assert, IO} =
        let plain = drawsWith(boardScene(boardAt(0.5) :: Nil));
        let casting = drawsWith(boardScene((boardAt(0.5) |> Scene3d.withCastShadows(true)) :: Nil));
        Assert.assertEq(expected = (1, true), (plain, casting > 1))

    @Test
    def testZeroCasterScaleDrawsNoPointShadowBoard(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 1, drawsWith(boardScene((boardAt(0.5) |> Scene3d.withCastShadows(true) |> Scene3d.withShadowCasterScale({ x = 0.0, y = 1.0 })) :: Nil)))

    def rightToward(x: Float64): (Float32, Float32, Float32) =
        let r = Scene3d.billboardShadowRightOf(Vec3.sub(lamp()#position, Vec3.v3(x, 0.0, 0.0)), Camera3d.right(Render3d.FakeGl.camera()));
        (RenderUtil.f32(r#x), RenderUtil.f32(r#y), RenderUtil.f32(r#z))

    @Test
    def testEachPointShadowBoardTurnsToTheLamp(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paintWithChars(log, boardScene((boardAt(0.5) |> Scene3d.withCastShadows(true)) :: (boardAt(-0.7) |> Scene3d.withCastShadows(true)) :: Nil));
        let put = Render3d.FakeGl.boardValuesAt(log, 12, 3) |> List.filterMap(v -> match v {
            case x :: y :: z :: _ => Some((x, y, z))
            case _                => None
        });
        Assert.assertEq(expected = (true, true, false), (List.memberOf(rightToward(0.5), put), List.memberOf(rightToward(-0.7), put), rightToward(0.5) == rightToward(-0.7)))

    def sunBoardScene(scale: Vec2.Vec2): Scene3d.Scene3dCmd =
        let sun = { shadow = Some({ mapSize = 64, pcfRadius = 1 | Scene3d.directionalShadow() }) | Scene3d.directionalLight(Vec3.v3(0.3, -1.0, 0.4)) };
        { billboards = (boardAt(0.5) |> Scene3d.withCastShadows(true) |> Scene3d.withShadowCasterScale(scale)) :: Nil, directionalLight = Some(sun) | sceneOf(triangle() :: Nil) }

    @Test
    def testCasterScaleShrinksTheSunShadowBoard(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paintWithChars(log, sunBoardScene({ x = 0.5, y = 0.25 }));
        let put = boardSizes(log);
        Assert.assertEq(expected = (true, true), (List.memberOf((0.5f32, 0.5f32), put), List.memberOf((1.0f32, 2.0f32), put)))

    @Test
    def testDefaultCasterScaleKeepsTheSunShadowBoard(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        paintWithChars(log, sunBoardScene({ x = 1.0, y = 1.0 }));
        Assert.assertEq(expected = 2, boardSizes(log) |> List.count(v -> v == (1.0f32, 2.0f32)))

    /// 送った板の値の size（欄 6・7）の並び。
    def boardSizes(log: Render3d.FakeGl.Recorded): List[(Float32, Float32)] \ IO =
        Render3d.FakeGl.boardValuesAt(log, 6, 2) |> List.filterMap(v -> match v {
            case w :: h :: _ => Some((w, h))
            case _           => None
        })

    @Test
    def testRowRightVertexSourceOnlyChangesTheRight(): Unit \ Assert =
        let base = Render3dWgsl.billboardVertexSource();
        Assert.assertEq(expected = (true, base), (has("r3dCamera.uRight.xyz * ((corner.x", base),
            String.replace(src = "v.tint.xyz * ((corner.x", dst = "r3dCamera.uRight.xyz * ((corner.x", Render3dWgsl.billboardRowRightVertexSource())))
}
