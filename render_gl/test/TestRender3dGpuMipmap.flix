// GPU に段を作らせる描き手（GlContext.prefersGpuMipmap が真・ブラウザ）の上げ方と、法線マップの材質の時だけタンジェントを上げること。
mod Render3d.TestGpuMipmap {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3d.FakeGl.{freshRecorded, freshState, paint, plainTriangle, recordingGl, sceneOf, cmdOf, stderrOf, timesCalled, Recorded}

    /// prefersGpuMipmap と、名前ごとの Bool の答えを足した偽の GL。
    def gpuGl(answers: List[(String, Bool)]): (GlContext, Recorded) \ IO =
        let log = freshRecorded();
        Ref.put(List.toMap(("prefersGpuMipmap", true) :: answers), log#booleans);
        (recordingGl(log), log)

    def argbTexture(w: Int32, h: Int32): Texture3d.Texture3d = match Texture3d.fromArgb(w, h, Vector.repeat(w * h, 0)) {
        case Ok(t)  => t
        case Err(e) => bug!(e)
    }

    def platformTexture(): Texture3d.Texture3d = match Texture3d.fromPlatformImage({ key = "rooms/wall.jpg@v1", width = 4, height = 2 }) {
        case Ok(t)  => t
        case Err(e) => bug!(e)
    }

    def sourceWith(own: List[Texture3d.Texture3d], registered: String): Render3d.TextureSource =
        { textureOf = name -> checked_ecast(if (name == registered) Some({ texId = 9, width = 4.0, height = 2.0, flipped = false, version = "" }) else None),
          own = own |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap }

    /// 場面の絵 t を使い方 textureUse で 1 回貼る。
    def bindOwn(gl: GlContext, state: Render3d.State, t: Texture3d.Texture3d, textureUse: Texture3d.TextureUse): Unit \ IO =
        discard Render3d.Material.resolveTextureAs(gl, state, 1i64, sourceWith(t :: Nil, ""), "材質の絵", Texture3d.name(t), textureUse)

    // ── 場面の絵 ──

    /// 4 × 2 の絵は段 0 だけを上げ、残りは generateMipmap に 1 回で作らせる
    @Test
    def testGpuMipmapUploadsOnlyLevelZero(): Unit \ {Assert, IO} =
        let (gl, log) = gpuGl(Nil);
        bindOwn(gl, freshState(), argbTexture(4, 2), Texture3d.TextureUse.MaterialTexture);
        Assert.assertEq(expected = (1, 1), (timesCalled("texImageArgbLevel", log), timesCalled("generateMipmap", log)))

    /// 4 × 2 の段は 4 × 2・2 × 1・1 × 1 の 3 つなので、TEXTURE_MAX_LEVEL は 2
    @Test
    def testGpuMipmapSetsMaxLevelToTheLastLevel(): Unit \ {Assert, IO} =
        let (gl, log) = gpuGl(Nil);
        bindOwn(gl, freshState(), argbTexture(4, 2), Texture3d.TextureUse.MaterialTexture);
        Assert.assertEq(expected = Some(2), Ref.get(log#texParams) |> List.find(p -> fst(p) == GlConst.TEXTURE_MAX_LEVEL) |> Option.map(snd))

    /// 同じ絵を色と法線に貼っても、GPU の段は平均の仕方を選べないので置き場は 1 枚
    @Test
    def testGpuMipmapKeepsOneUploadForBothUses(): Unit \ {Assert, IO} =
        let (gl, _) = gpuGl(Nil);
        let state = freshState();
        bindOwn(gl, state, argbTexture(4, 2), Texture3d.TextureUse.MaterialTexture);
        bindOwn(gl, state, argbTexture(4, 2), Texture3d.TextureUse.NormalMap);
        Assert.assertEq(expected = 1, Map.size(Ref.get(state#textures3dRef)))

    /// CPU で段を作る描き手は平均の仕方ごとに段が違うので、色と法線で 2 枚
    @Test
    def testCpuMipmapKeepsOneUploadPerUse(): Unit \ {Assert, IO} =
        let gl = recordingGl(freshRecorded());
        let state = freshState();
        bindOwn(gl, state, argbTexture(4, 2), Texture3d.TextureUse.MaterialTexture);
        bindOwn(gl, state, argbTexture(4, 2), Texture3d.TextureUse.NormalMap);
        Assert.assertEq(expected = 2, Map.size(Ref.get(state#textures3dRef)))

    /// 機種が持っていない機種の側の絵は置き場に控えない（後から持てば次に貼る時に上がる）
    @Test
    def testMissingPlatformImageIsNotKept(): Unit \ {Assert, IO} =
        let (gl, _) = gpuGl(("texImagePlatform", false) :: Nil);
        let state = freshState();
        discard stderrOf(() -> bindOwn(gl, state, platformTexture(), Texture3d.TextureUse.MaterialTexture));
        Assert.assertEq(expected = 0, Map.size(Ref.get(state#textures3dRef)))

    /// 機種が持っていない機種の側の絵は、上げられないと 1 行知らせる
    @Test
    def testMissingPlatformImageIsReported(): Unit \ {Assert, IO} =
        let (gl, _) = gpuGl(("texImagePlatform", false) :: Nil);
        let text = stderrOf(() -> bindOwn(gl, freshState(), platformTexture(), Texture3d.TextureUse.MaterialTexture));
        Assert.assertTrue(String.contains(substr = "機種の側から上げられない", text))

    /// 上げられなかった機種の側の絵は、次のコマには試し直さず、platformRetryFrames（60）たったコマで試し直す（世代 1・2・61 で 2 回）
    @Test
    def testMissingPlatformImageIsRetriedAfterAWhile(): Unit \ {Assert, IO} =
        let (gl, log) = gpuGl(("texImagePlatform", false) :: Nil);
        let state = freshState();
        let t = platformTexture();
        let bindAt = (gen: Int64) -> discard Render3d.Material.resolveTextureAs(gl, state, gen, sourceWith(t :: Nil, ""), "材質の絵", Texture3d.name(t), Texture3d.TextureUse.MaterialTexture);
        discard stderrOf(() -> { bindAt(1i64); bindAt(2i64); bindAt(61i64) });
        Assert.assertEq(expected = 2, timesCalled("texImagePlatform", log))

    /// 機種が持っている機種の側の絵は、段 0 を上げて段を作り、置き場に控える
    @Test
    def testPlatformImageIsKept(): Unit \ {Assert, IO} =
        let (gl, _) = gpuGl(("texImagePlatform", true) :: Nil);
        let state = freshState();
        bindOwn(gl, state, platformTexture(), Texture3d.TextureUse.MaterialTexture);
        Assert.assertEq(expected = 1, Map.size(Ref.get(state#textures3dRef)))

    // ── 全体の登録の絵の段つきの写し ──

    def bindRegistered(gl: GlContext): Unit \ IO =
        discard Render3d.Material.resolveTextureAs(gl, freshState(), 1i64, sourceWith(Nil, "wall"), "材質の絵", "wall", Texture3d.TextureUse.MaterialTexture)

    /// GPU の中で写せれば、登録の絵を読み戻さない
    @Test
    def testGpuMipCopyDoesNotReadBack(): Unit \ {Assert, IO} =
        let (gl, log) = gpuGl(("copyTextureLevel0", true) :: Nil);
        bindRegistered(gl);
        Assert.assertEq(expected = 0, timesCalled("readTextureArgb", log))

    /// GPU の中で写せなければ、読み戻して上げる
    @Test
    def testGpuMipCopyFallsBackToReadBack(): Unit \ {Assert, IO} =
        let (gl, log) = gpuGl(("copyTextureLevel0", false) :: Nil);
        bindRegistered(gl);
        Assert.assertEq(expected = 1, timesCalled("readTextureArgb", log))

    // ── タンジェント ──

    def uvTriangle(): Mesh3d.Mesh3d = match Mesh3d.withUvs(Vector#{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0 }, plainTriangle()) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    }

    /// uv つきの三角形を材質 m で 2 コマ描いた時に、タンジェントの location 6 を有効にした回数。
    def tangentUploadsAfterTwoFrames(m: Scene3d.Material3d): Int32 \ IO =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let cmd = cmdOf(sceneOf((Scene3d.meshInstance(uvTriangle(), Mat4.identity()) |> Scene3d.withMaterial(m)) :: Nil));
        discard stderrOf(() -> { paint(gl, state, cmd :: Nil); paint(gl, state, cmd :: Nil) });
        Ref.get(log#attribs) |> List.count(i -> i == 6)

    /// 法線マップの材質は、最初のコマでタンジェントを 1 回だけ上げ、次のコマは上げ直さない
    @Test
    def testTangentsAreUploadedOnceForANormalMappedMaterial(): Unit \ {Assert, IO} =
        let bumped = Scene3d.texturedMaterial("wall", ShaderDoc.FilterMode.Nearest) |> Scene3d.withNormalMap({ texture = "bump", strength = 1.0 });
        Assert.assertEq(expected = 1, tangentUploadsAfterTwoFrames(bumped))

    /// 法線マップの無い材質は、uv があってもタンジェントを上げない
    @Test
    def testTangentsAreNotUploadedWithoutANormalMap(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0, tangentUploadsAfterTwoFrames(Scene3d.texturedMaterial("wall", ShaderDoc.FilterMode.Nearest)))
}
