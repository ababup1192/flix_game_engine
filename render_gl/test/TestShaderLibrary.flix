// ブラウザ版の前もって作るシェーダーの字（Render3d.ShaderLibrary）: 部品の所が空いた材質の frag に部品を入れた字が直に print した字と同じこと・
// 記録のファイルの読み書き・記録から広げた表だけで描き手が全部の字を引けること。
mod Render3d.TestShaderLibrary {
    import java.lang.Throwable
    import java.lang.System
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.io.File
    import java.nio.file.Files
    import java.nio.file.Path

    use Render3d.FakeGl.{cmdOf, dest, freshRecorded, passDest, paintTo, plainTriangle, recordingGl, sceneOf, shadowSpot, skinnedAt, poseAt, stderrOf, timesCalled}
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
                      coverage = coverage, metallicRoughness = metallic, screenAoOnBlend = false, variant = v })))))
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
                     metallicRoughness = false, screenAoOnBlend = false, variant = { psx = true | Render3d.ProgramKey.defaultShaderVariant() } };
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

    def decalCollection(): CollectionKeys =
        let kind = { skinned = false, uv = true, normalMap = false, lightmap = false, blend = true, doubleSided = false, coverage = false,
                     metallicRoughness = false, screenAoOnBlend = true, variant = { ambientOcclusion = true | Render3d.ProgramKey.defaultShaderVariant() } };
        Render3d.ShaderLibrary.shapeKeys(kind, false, true)

    /// 記録に SSAO を受ける半透明の形（デカールの板）があれば、書き出しはその +ab の frag を作る。
    @Test
    def testScreenAoOnBlendShapeExpandsToAbFragment(): Unit \ Assert =
        let names = Render3d.ShaderLibrary.requiredKeysOf(decalCollection()) |> List.map(Render3d.ShaderSourceKey.toKeyString) |> List.toSet;
        Assert.assertTrue(Set.memberOf("material.fs+uv+bl+ab+tex/+ao", names))

    /// SSAO を受ける半透明の形は記録のファイルを通しても残る。
    @Test
    def testScreenAoOnBlendShapeRoundTrips(): Unit \ Assert =
        Assert.assertEq(expected = Ok(keysOf(decalCollection())), collectionOfJson(collectionToJson(decalCollection())) |> Result.map(keysOf))

    /// SSAO を受けない形の記録の字には screenAoOnBlend の欄が出ない（デカールを使わないゲームの記録が変わらない）。
    @Test
    def testPlainShapeJsonOmitsScreenAoOnBlend(): Unit \ Assert =
        Assert.assertFalse(String.contains(substr = "screenAoOnBlend", collectionToJson(sampleCollection())))

    def tempPath(name: String): String \ IO =
        let dir = File.createTempFile("fge-shader-variants", "");
        discard dir.delete();
        discard dir.mkdirs();
        new File(dir, name).getPath()

    @Test
    def testMissingFileLoadsAsEmpty(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok((Set.empty(), Set.empty())), Render3d.ShaderLibrary.loadCollection(tempPath("none.json")) |> Result.map(keysOf))

    @Test
    def testRecordingWritesNewKeysToTheFile(): Unit \ {Assert, IO} =
        let path = tempPath("web/shader-variants.json");
        let shaders = Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider());
        shaders#record(sampleCollection());
        Assert.assertEq(expected = Ok(keysOf(sampleCollection())), Render3d.ShaderLibrary.loadCollection(path) |> Result.map(keysOf))

    @Test
    def testRecordingStartsFromTheFile(): Unit \ {Assert, IO} =
        let path = tempPath("shader-variants.json");
        Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider())#record(sampleCollection());
        Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider())#record(variantKeys({ ambientOcclusion = true | Render3d.ProgramKey.defaultShaderVariant() }));
        Assert.assertEq(expected = Ok(Set#{ "+ao", "+ps", "+psx" }), Render3d.ShaderLibrary.loadCollection(path) |> Result.map(c -> fst(keysOf(c))))

    // ── 記録から広げた表だけで描ける ──

    def textured(): Scene3d.Material3d = Scene3d.texturedMaterial("tex3d:a", ShaderDoc.FilterMode.Linear)

    def at(m: Scene3d.Material3d): Scene3d.Instance3d = Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(m)

    def depth(scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd = { output = Scene3d.Output.Depth({ near = 0.5, range = 12.0 }) | scene }

    def board(): Scene3d.Billboard3d =
        Scene3d.billboard("chars", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 16.0 } }, Vec3.v3(0.0, 0.0, 0.0), { x = 1.0, y = 2.0 })

    def uvTriangle(): Mesh3d.Mesh3d = match Mesh3d.withUvs(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }, plainTriangle()) |> Result.flatMap(Mesh3d.withUvs2(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 })) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    }

    def uvAt(m: Scene3d.Material3d): Scene3d.Instance3d = Scene3d.meshInstance(uvTriangle(), Mat4.identity()) |> Scene3d.withMaterial(m)

    /// 材質の形・変種・奥行きの場面・動かない物の集まり・MultiMesh・影を落とす灯り・骨つき・法線マップ・lightmap・+ao を全部通す場面。
    pub def scenes(): List[Scene3d.Scene3dCmd] =
        let lit = Scene3d.meshInstance(plainTriangle(), Mat4.identity());
        let bumped = textured() |> Scene3d.withNormalMap({ texture = "tex3d:b", strength = 1.0 });
        let mixed = sceneOf(lit :: at(textured() |> Scene3d.withCutout(true)) :: at(textured() |> Scene3d.withAlphaBlend(true)) ::
                            at(textured() |> Scene3d.withDoubleSided(true)) :: at(textured() |> Scene3d.withMetallicRoughness(0.5, 0.5)) :: skinnedAt(poseAt(0.2)) ::
                            uvAt(bumped |> Scene3d.withCutout(true)) :: (uvAt(textured()) |> Scene3d.withLightmap(Scene3d.lightmap("tex3d:c"))) ::
                            (skinnedAt(poseAt(0.1)) |> Scene3d.withMaterial(textured())) :: Nil);
        let grouped = { groups = Scene3d.staticGroup("g", ("a", at(textured() |> Scene3d.withCutout(true) |> Scene3d.withDoubleSided(true))) :: Nil) :: Nil,
                        multiMeshes = MultiMesh3d.build(plainTriangle(), 3, _ -> Mat4.identity()) |> MultiMesh3d.withMaterial(textured()) |> (mm -> mm :: Nil),
                        billboards = board() :: Nil, spotLights = shadowSpot() :: Nil | mixed };
        let lamp = { position = Vec3.v3(0.0, 1.0, 0.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 };
        let shadowed = { pointLights = lamp :: Nil | grouped } |> Scene3d.withPointShadows({ maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() });
        let ao = { screenInputs = Some(Scene3d.screenInputs({ depth = "d", depthRange = 10.0, ambientOcclusion = Some(ScreenEffects3d.ambientOcclusion()), show = None })) | grouped };
        grouped :: Scene3d.withPsx(Scene3d.psxPreset(), grouped) :: shadowed :: depth(grouped) :: ao :: Nil

    /// 表 table だけを引く描き手で場面 all を target へ描いた時の (標準エラー, instanced の draw の数)。
    def paintWith(table: Map[String, String], target: Scene3dRenderer.Dest, all: List[Scene3d.Scene3dCmd]): (String, Int32) \ IO =
        let shaders = Render3d.ShaderLibrary.withoutRecording(Render3d.ShaderLibrary.providerOfTable(table));
        let state = Render3d.fresh({ megabytes = 64, count = 64 }, Render3d.DrawMode.Instanced, shaders);
        let log = freshRecorded();
        let said = stderrOf(() -> paintTo(recordingGl(log), state, target, all |> List.map(cmdOf)));
        (said, timesCalled("drawElementsInstanced", log))

    pub def tableOf(c: CollectionKeys): Map[String, String] = Render3d.ShaderLibrary.bakeTableOf(Render3dShaders.makeRuntimeProvider(), c) |> List.toMap

    /// 場面 all を、collectionKeysOf から広げた表だけを引く描き手で描いた時の標準エラー。
    def paintedFromTable(target: Scene3dRenderer.Dest, all: List[Scene3d.Scene3dCmd]): String \ IO =
        let collection = all |> List.foldLeft((acc, s) -> unionCollection(acc, collectionKeysOf(s)), emptyCollection());
        fst(paintWith(tableOf(collection), target, all))

    @Test
    def testRendererFindsEverySourceInTheTable(): Unit \ {Assert, IO} =
        Assert.assertFalse(String.contains(substr = "shader-variants.json", paintedFromTable(dest(), scenes())))

    @Test
    def testMultisampledRendererFindsEverySourceInTheTable(): Unit \ {Assert, IO} =
        Assert.assertFalse(String.contains(substr = "shader-variants.json", paintedFromTable(passDest(), scenes())))

    @Test
    def testKeysRecordedByOneRendererCoverAnother(): Unit \ {Assert, IO} =
        let path = tempPath("recorded.json");
        let state = Render3d.fresh({ megabytes = 64, count = 64 }, Render3d.DrawMode.Instanced, Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider()));
        discard stderrOf(() -> paintTo(recordingGl(freshRecorded()), state, passDest(), scenes() |> List.map(cmdOf)));
        let recorded = Render3d.ShaderLibrary.loadCollection(path) |> Result.getWithDefault(emptyCollection());
        Assert.assertFalse(String.contains(substr = "shader-variants.json", fst(paintWith(tableOf(recorded), dest(), scenes()))))

    def psxLit(): Scene3d.Scene3dCmd = Scene3d.withPsx(Scene3d.psxPreset(), sceneOf(Scene3d.meshInstance(plainTriangle(), Mat4.identity()) :: Nil))

    @Test
    def testMissingVariantIsReported(): Unit \ {Assert, IO} =
        Assert.assertTrue(String.contains(substr = "lit.fs+psx", fst(paintWith(tableOf(emptyCollection()), dest(), psxLit() :: Nil))))

    @Test
    def testMissingVariantIsNotDrawn(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (1, 0), (snd(paintWith(tableOf(collectionKeysOf(psxLit())), dest(), psxLit() :: Nil)),
                                            snd(paintWith(tableOf(emptyCollection()), dest(), psxLit() :: Nil))))

    @Test
    def testMissingVariantIsReportedOnce(): Unit \ {Assert, IO} =
        let said = fst(paintWith(tableOf(emptyCollection()), dest(), psxLit() :: psxLit() :: Nil));
        Assert.assertEq(expected = 2, List.length(String.splitOn({ substr = "lit.fs+psx" }, said)))

    @Test
    def testUnreadableRecordIsNotRewritten(): Unit \ {Assert, IO} =
        let path = tempPath("broken.json");
        discard Files.writeString(Path.of(path), "<<<<<<< HEAD");
        let said = stderrOf(() -> Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider())#record(sampleCollection()));
        Assert.assertEq(expected = (true, "<<<<<<< HEAD"), (String.contains(substr = "記録しない", said), Files.readString(Path.of(path))))

    @Test
    def testTwoRecordersKeepEachOthersKeys(): Unit \ {Assert, IO} =
        let path = tempPath("shared.json");
        let a = Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider());
        let b = Render3d.ShaderLibrary.recordingTo(path, Render3dShaders.makeRuntimeProvider());
        a#record(variantKeys({ psx = true | Render3d.ProgramKey.defaultShaderVariant() }));
        b#record(variantKeys({ ambientOcclusion = true | Render3d.ProgramKey.defaultShaderVariant() }));
        Assert.assertEq(expected = Ok(Set#{ "+ao", "+psx" }), Render3d.ShaderLibrary.loadCollection(path) |> Result.map(c -> fst(keysOf(c))))
}
