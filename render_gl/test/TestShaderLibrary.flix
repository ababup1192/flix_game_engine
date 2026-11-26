// ブラウザ版の前もって作るシェーダーの字（Render3d.ShaderLibrary）: 部品の所が空いた材質の frag に部品を入れた字が直に print した字と同じこと・
// 記録のファイルの読み書き・記録から広げた表だけで描き手が全部の字を引けること。
mod Render3d.TestShaderLibrary {
    import java.lang.Throwable
    import java.lang.System
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream

    use Render3d.FakeGl.{cmdOf, dest, freshRecorded, passDest, paintTo, plainTriangle, recordingGl, sceneOf, shadowSpot, skinnedAt, poseAt, stderrOf}
    use Render3d.ShaderLibrary.{CollectionKeys, collectionKeysOf, collectionOfJson, collectionToJson, emptyCollection, unionCollection, variantKeys}
    use ShaderDoc.{Field, Shade, TexChan, BinOp}

    def flags(): List[Bool] = false :: true :: Nil

    def fill(name: String, shade: Shade, alpha: Field): ShaderDoc.Spec =
        { name = name, cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = shade, alpha = alpha }) }

    /// 絵を読まない材質（cutout の α は albedo.a）と、絵を読む材質（cutout の α は materialCutoutAlpha の呼び出し）。
    def specs(): List[ShaderDoc.Spec] =
        let tint = (chan: TexChan, name: String) -> Field.Bin({ op = BinOp.Mul, a = Field.VertexColor({ chan = chan }), b = Field.Param({ name = name }) });
        let tex = (chan: TexChan) -> Field.Tex({ name = "albedo", chan = chan });
        fill("field", Shade.Rgb({ r = tint(TexChan.R, "r"), g = tint(TexChan.G, "g"), b = tint(TexChan.B, "b") }), Field.Param({ name = "a" })) ::
        fill("textured", Shade.Rgb({ r = tex(TexChan.R), g = tex(TexChan.G), b = tex(TexChan.B) }), tex(TexChan.A)) :: Nil

    def kindsOf(v: Render3d.ProgramKey.ShaderVariant): List[Render3d.ProgramKey.ProgramKind] =
        let surfaces = (false, false) :: (true, false) :: (true, true) :: Nil;
        surfaces |> List.flatMap(un -> {
            let (uv, normalMap) = un;
            flags() |> List.flatMap(lightmap -> flags() |> List.flatMap(blend -> flags() |> List.flatMap(doubleSided ->
                flags() |> List.flatMap(coverage -> flags() |> List.map(metallic ->
                    { skinned = false, uv = uv, normalMap = normalMap, lightmap = lightmap, blend = blend, doubleSided = doubleSided,
                      coverage = coverage, metallicRoughness = metallic, variant = v })))))
        })

    def metalOf(k: Render3d.ProgramKey.ProgramKind): Option[Shade] =
        if (k#metallicRoughness) Some(Shade.Rgb({ r = Field.Param({ name = "metal" }), g = Field.Param({ name = "rough" }), b = Field.Const(0.0) })) else None

    def variants(): List[Render3d.ProgramKey.ShaderVariant] =
        Render3d.ProgramKey.defaultShaderVariant() ::
        { pointShadows = true, physicalUnits = false, psx = true, skyIrradiance = true, ambientOcclusion = true } :: Nil

    /// (鍵, 直に print した字, 部品を入れた字) の組。
    def materialPairs(): List[(String, String, String)] =
        variants() |> List.flatMap(v -> kindsOf(v) |> List.flatMap(k -> specs() |> List.flatMap(spec -> {
            let glsl = ShaderGen.compile3d(spec, None, metalOf(k));
            let wgsl = ShaderGen.Wgsl.compile3d(spec, None, metalOf(k), 1);
            let name = spec#name + ":" + Render3d.ShaderSourceKey.toKeyString(Render3d.ShaderSourceKey.MaterialFragmentTemplate(k, false));
            ("glsl:" + name, Render3dGlsl.materialFragmentSource(glsl, k),
             Render3d.ShaderLibrary.withMaterialPart(Render3dGlsl.materialFragmentTemplate(k, not List.isEmpty(glsl#texReads)), Render3d.ShaderLibrary.glslPartText(glsl), glsl#cutoutAlpha)) ::
            ("wgsl:" + name, Render3dWgsl.materialFragmentSource(wgsl, k),
             Render3d.ShaderLibrary.withMaterialPart(Render3dWgsl.materialFragmentTemplate(k, not List.isEmpty(wgsl#texReads)), Render3d.ShaderLibrary.wgslPartText(wgsl), wgsl#cutoutAlpha)) :: Nil
        })))

    @Test
    def testMaterialPartInTemplateEqualsDirectPrint(): Unit \ Assert =
        Assert.assertEq(expected = Nil, materialPairs() |> List.filter(t -> { let (_, direct, filled) = t; direct != filled }) |> List.map(t -> { let (k, _, _) = t; k }))

    @Test
    def testNonAtomCutoutAlphaStops(): Unit \ {Assert, IO} =
        let template = "a " + Render3d.ShaderLibrary.cutoutAlphaPlaceholder() + " " + Render3d.ShaderLibrary.materialPartPlaceholder();
        let saved = System.err;
        System.setErr(new PrintStream(new ByteArrayOutputStream(), true, "UTF-8"));
        let stopped = try { String.isEmpty(Render3d.ShaderLibrary.withMaterialPart(template, "", "albedo.a * 0.5")) and false } catch { case _: Throwable => true };
        System.setErr(saved);
        Assert.assertTrue(stopped)

    @Test
    def testBillboardFragmentDependsOnlyOnBillboardVariant(): Unit \ Assert =
        let all = flags() |> List.flatMap(ao -> flags() |> List.flatMap(ps -> flags() |> List.flatMap(pu -> flags() |> List.flatMap(psx -> flags() |> List.map(sh ->
            { pointShadows = ps, physicalUnits = pu, psx = psx, skyIrradiance = sh, ambientOcclusion = ao })))));
        let differs = all |> List.filter(v -> {
            let bv = Render3d.ProgramKey.billboardVariantOf(v);
            Render3dWgsl.billboardFragmentSourceFor(v) != Render3dWgsl.billboardFragmentSourceFor(bv) or
            Render3dGlsl.billboardFragmentSourceFor(v) != Render3dGlsl.billboardFragmentSourceFor(bv)
        });
        Assert.assertEq(expected = Nil, differs |> List.map(Render3d.ProgramKey.variantKeyOf))

    // ── 記録のファイル ──

    def sampleCollection(): CollectionKeys =
        let kind = { skinned = false, uv = true, normalMap = false, lightmap = false, blend = false, doubleSided = true, coverage = false,
                     metallicRoughness = false, variant = { psx = true | Render3d.ProgramKey.defaultShaderVariant() } };
        unionCollection(Render3d.ShaderLibrary.shapeKeys(kind, true, true), variantKeys({ pointShadows = true | Render3d.ProgramKey.defaultShaderVariant() }))

    def keysOf(c: CollectionKeys): (Set[String], Set[String]) = (Map.keysOf(c#variants), Map.keysOf(c#materialShapes))

    @Test
    def testCollectionJsonRoundTrips(): Unit \ Assert =
        Assert.assertEq(expected = Ok(keysOf(sampleCollection())), collectionOfJson(collectionToJson(sampleCollection())) |> Result.map(keysOf))

    @Test
    def testUnknownFieldsAndFlagsAreSkipped(): Unit \ Assert =
        let text = "{ \"version\": 1, \"future\": 3, \"variants\": [\"+psx+zz\"], \"materialShapes\": [{ \"uv\": true, \"glow\": true }] }";
        Assert.assertEq(expected = Ok((Set#{ "+psx" }, Set#{ "uv" })), collectionOfJson(text) |> Result.map(keysOf))

    @Test
    def testNewerVersionIsErr(): Unit \ Assert =
        Assert.assertTrue(Result.isErr(collectionOfJson("{ \"version\": 2, \"variants\": [], \"materialShapes\": [] }")))

    @Test
    def testFlagKeysThatSharePrefixAreRead(): Unit \ Assert =
        Assert.assertEq(expected = "+ps+psx", Render3d.ProgramKey.variantKeyOf(Render3d.ShaderLibrary.variantOfKey("+ps+psx")))

    @Test
    def testCutoutShapeExpandsToBothCoverages(): Unit \ Assert =
        let names = Render3d.ShaderLibrary.requiredKeysOf(sampleCollection()) |> List.map(Render3d.ShaderSourceKey.toKeyString) |> List.toSet;
        Assert.assertEq(expected = (true, true),
                        (Set.memberOf("material.fs+uv+ds+cov+tex/+psx", names), Set.memberOf("material.fs+uv+ds+tex/+psx", names)))

    // ── 記録から広げた表だけで描ける ──

    def textured(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear)

    def at(m: Scene3d.Material3d): Scene3d.Instance3d = Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(m)

    def depth(scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd = { output = Scene3d.Output.Depth({ near = 0.5, range = 12.0 }) | scene }

    def board(): Scene3d.Billboard3d =
        Scene3d.billboard("chars", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } }, Vec3.v3(0.0, 0.0, 0.0), { x = 1.0, y = 2.0 })

    /// 材質の形・変種・奥行きの場面・動かない物の集まり・MultiMesh・影を落とす灯り・骨つきを全部通す場面。
    def scenes(): List[Scene3d.Scene3dCmd] =
        let lit = Scene3d.meshInstance(plainTriangle(), Mat4.identity());
        let mixed = sceneOf(lit :: at(textured() |> Scene3d.withCutout(true)) :: at(textured() |> Scene3d.withAlphaBlend(true)) ::
                            at(textured() |> Scene3d.withDoubleSided(true)) :: at(textured() |> Scene3d.withMetallicRoughness(0.5, 0.5)) :: skinnedAt(poseAt(0.2)) :: Nil);
        let grouped = { groups = Scene3d.staticGroup("g", ("a", at(textured() |> Scene3d.withCutout(true) |> Scene3d.withDoubleSided(true))) :: Nil) :: Nil,
                        multiMeshes = MultiMesh3d.build(plainTriangle(), 3, _ -> Mat4.identity()) |> MultiMesh3d.withMaterial(textured()) |> (mm -> mm :: Nil),
                        billboards = board() :: Nil, spotLights = shadowSpot() :: Nil | mixed };
        let lamp = { position = Vec3.v3(0.0, 1.0, 0.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 };
        let shadowed = { pointLights = lamp :: Nil | grouped } |> Scene3d.withPointShadows({ maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() });
        grouped :: Scene3d.withPsx(Scene3d.psxPreset(), grouped) :: shadowed :: depth(grouped) :: Nil

    /// 場面 all を、記録から広げた表だけを引く描き手で描いた時の標準エラー。
    def paintedFromTable(target: Scene3dRenderer.Dest, all: List[Scene3d.Scene3dCmd]): String \ IO =
        let collection = all |> List.foldLeft((acc, s) -> unionCollection(acc, collectionKeysOf(s)), emptyCollection());
        let table = Render3d.ShaderLibrary.bakeTableOf(Render3dShaders.makeRuntimeProvider(), collection) |> List.toMap;
        let shaders = Render3d.ShaderLibrary.withoutRecording(Render3d.ShaderLibrary.providerOfTable(table));
        let state = Render3d.fresh({ megabytes = 64, count = 64 }, Render3d.DrawMode.Instanced, shaders);
        let gl = recordingGl(freshRecorded());
        stderrOf(() -> paintTo(gl, state, target, all |> List.map(cmdOf)))

    @Test
    def testRendererFindsEverySourceInTheTable(): Unit \ {Assert, IO} =
        Assert.assertFalse(String.contains(substr = "shader-variants.json", paintedFromTable(dest(), scenes())))

    @Test
    def testMultisampledRendererFindsEverySourceInTheTable(): Unit \ {Assert, IO} =
        Assert.assertFalse(String.contains(substr = "shader-variants.json", paintedFromTable(passDest(), scenes())))

    @Test
    def testMissingVariantIsReportedNotDrawn(): Unit \ {Assert, IO} =
        let table = Render3d.ShaderLibrary.bakeTableOf(Render3dShaders.makeRuntimeProvider(), emptyCollection()) |> List.toMap;
        let state = Render3d.fresh({ megabytes = 64, count = 64 }, Render3d.DrawMode.Instanced,
                                   Render3d.ShaderLibrary.withoutRecording(Render3d.ShaderLibrary.providerOfTable(table)));
        let said = stderrOf(() -> paintTo(recordingGl(freshRecorded()), state, dest(), cmdOf(Scene3d.withPsx(Scene3d.psxPreset(), sceneOf(Scene3d.meshInstance(plainTriangle(), Mat4.identity()) :: Nil))) :: Nil));
        Assert.assertTrue(String.contains(substr = "lit.fs+psx", said))
}
