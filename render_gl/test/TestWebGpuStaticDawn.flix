// WebGPU の 3D の描き手が、動かない物の集まりの持ち越し（Render3d.WebGpuStatic）をコマをまたいで使い、置き場が物を捨てたコマに手放す事を、PC の Dawn で device を開いて固定する（画素は読まない）。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（TestWebGpuScene3dDawn と同じ。`[scene3d-dawn] SKIP:` の行を出す）。
// WhyNot: mod TestWebGpuStaticDawn にしない — 描き手の状態（RendererData）の持ち越しの控えを見るのに Render3d.WebGpuRenderer の中から読む。
mod Render3d.WebGpuRenderer.TestWebGpuStaticDawn {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureSampleType
    import fge.webgpu.WebGpu
    use Render3d.WebGpuRenderer.{Dest, Host, RendererData, afterSubmit, endFrameWithin, prepare, takeCounts}

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0, lensShift = Vec2.zero() }

    /// 目の前（z = 10）に置く幅 side の四角。
    def quadAt(side: Float64): Scene3d.Instance3d =
        let quad = { points = Vec3.v3(-side, -side, 10.0) :: Vec3.v3(-side, side, 10.0) :: Vec3.v3(side, side, 10.0) :: Vec3.v3(side, -side, 10.0) :: Nil,
                     color = Color.rgb(0.8, 0.4, 0.2) };
        Scene3d.meshInstance(Mesh3d.fromPolygons(quad :: Nil), Mat4.identity())

    /// 形の違う四角 3 枚の集まりを載せた 64 × 64 の場面。
    def sceneWith(g: Scene3d.StaticGroup): Scene3d.RenderCmd =
        { at = Vec2.zero(), clip = None, scene = { groups = g :: Nil | Scene3d.scene(camera(), { x = 64.0, y = 64.0 }) } }

    def town(): Scene3d.StaticGroup = Scene3d.staticGroup("town", ("a", quadAt(1.0)) :: ("b", quadAt(2.0)) :: ("c", quadAt(3.0)) :: Nil)

    def dest(): Dest =
        { key = 0, format = RenderTarget.Format.Rgba8Unorm, samples = 1, height = 64,
          viewport = { x = 0, y = 0, width = 64, height = 64, scaleX = 1.0, scaleY = 1.0 } }

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    def layoutOf(gpu: WebGpu, paste: Bool): BindGroupLayout \ IO =
        let desc = new BindGroupLayoutDesc("test layout");
        discard desc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT);
        if (paste) discard desc.buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM) else discard desc.sampler(1, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        gpu.createBindGroupLayout(desc)

    /// Dawn で f を流す（device が無い機械では何も比べずに通す）。
    def withDawn(f: WebGpu -> Unit \ {Assert, IO}): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                f(gpu);
                gpu.destroy()
        }

    /// frames を 1 コマずつ prepare して submit し（encoder は捨てる）、コマを締める（1 コマに場面が何個か）。vertices = 形の頂点の上限。
    /// 返すのは コマごとの (締める前の持ち越しの数, 手放すのを待っている物の数, 形を作った回数) と、(bundle を積んだ回数, 最後のコマの描いた物の数, device の誤りの数)。
    def framesOf(gpu: WebGpu, vertices: Int32, frames: List[List[Scene3d.RenderCmd]]): (List[(Int32, Int32, Int32)], (Int32, Int32, Int32)) \ IO =
        let paste = layoutOf(gpu, true);
        let renderer = Render3d.WebGpuRenderer.create(gpu, paste, layoutOf(gpu, false));
        let RendererData.RendererData(s) = renderer;
        let drawn = Ref.fresh(Static, 0);
        let seen = frames |> List.map(cmds -> {
            let encoder = gpu.createCommandEncoder("test");
            let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> checked_ecast(()),
                               skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None),
                               groupById = _ -> checked_ecast(None), stamp = (_, _) -> checked_ecast(()) };
            discard prepare(renderer, host, dest(), cmds);
            let cached = Render3d.StaticRows.sizeOf(s#statics#cache);
            let retired = Render3d.WebGpuStatic.retiredCountOf(s#statics);
            gpu.submit(encoder.finish());
            let counts = takeCounts(renderer);
            Ref.put(counts#drawn, drawn);
            afterSubmit(renderer);
            endFrameWithin(renderer, { vertices = vertices, textures = { count = 64, size = 67108864i64 } });
            (cached, retired, counts#meshUploads)
        });
        let recorded = Render3d.WebGpuStatic.recordedCountOf(s#statics);
        Render3d.WebGpuRenderer.release(renderer);
        paste.release();
        (seen, (recorded, Ref.get(drawn), gpu.errorCount()))

    def cachedOf(seen: List[(Int32, Int32, Int32)]): List[Int32] = List.map(match (c, _, _) -> c, seen)

    /// 同じ集まりの値を 3 コマ続けて描くと、持ち越しは 1 つのまま、bundle も最初のコマに 1 回積むだけ。
    @Test
    def testSameGroupIsCarriedAcrossFrames(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let (seen, (recorded, _, errors)) = framesOf(gpu, 4000000, (sceneWith(g) :: Nil) :: (sceneWith(g) :: Nil) :: (sceneWith(g) :: Nil) :: Nil);
        Assert.assertEq(expected = (1 :: 1 :: 1 :: Nil, 1, 0), (cachedOf(seen), recorded, errors))
    })

    /// 外す鍵が変わったコマは作り直し、前の物（buffer と bundle）は手放すのを待つ（コマを締めるまで手放さない）。
    @Test
    def testRemovedKeyRebuildsAndRetiresAtFrameEnd(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let (seen, (_, _, errors)) = framesOf(gpu, 4000000, (sceneWith(g) :: Nil) :: (sceneWith(Scene3d.withoutItems(Set#{"b"}, g)) :: Nil) :: Nil);
        Assert.assertEq(expected = ((1, 0) :: (1, 2) :: Nil, 0), (List.map(match (c, r, _) -> (c, r), seen), errors))
    })

    /// 同じ集まりを描き先の違う 2 つの場面で描いても、bundle は描き先ごとに 1 回積むだけ（コマごとに積み直さない）。
    @Test
    def testTwoScenesShareCarriedAndKeepTheirBundles(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let both = sceneWith(g) :: sceneWith(g) :: Nil;
        let (seen, (recorded, _, errors)) = framesOf(gpu, 4000000, both :: both :: both :: Nil);
        Assert.assertEq(expected = (1 :: 1 :: 1 :: Nil, 2, 0), (cachedOf(seen), recorded, errors))
    })

    /// 同じ名前で tint の違う集まりを 2 つの場面で描くと、両方を控えて作り直さず、手放す物も出ない。
    @Test
    def testSameNameDifferentTintInTwoScenesKeepsBoth(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let both = sceneWith(g) :: sceneWith(Scene3d.withGroupTint(Color.rgb(1.0, 0.5, 0.5), g)) :: Nil;
        let (seen, (recorded, _, errors)) = framesOf(gpu, 4000000, both :: both :: both :: Nil);
        Assert.assertEq(expected = ((2, 0) :: (2, 0) :: (2, 0) :: Nil, 2, 0), (List.map(match (c, r, _) -> (c, r), seen), recorded, errors))
    })

    /// 形の置き場が上限を超えて形を捨てたコマの後は、持ち越しを全部作り直す（行の形の番号が別の形を指しうる）。
    /// 2・3 コマ目は集まりを描かずに別の四角だけを描き、3 コマ目を締める時に 1 コマ目の集まりの形が捨てられる（今と前のコマで使った形は捨てない）。
    /// 4 コマ目は作り直すので集まりの形を作り直す（作り直さなければ捨てた形の番号を描き、形を作らない）。集まりの形は 3 枚をつないだ 1 つ。
    @Test
    def testMeshEvictionDropsCarried(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let other = { at = Vec2.zero(), clip = None, scene = { instances = quadAt(4.0) :: Nil | Scene3d.scene(camera(), { x = 64.0, y = 64.0 }) } };
        let seen = Ref.fresh(Static, Nil);
        discard Render3d.FakeGl.stderrOf(() -> Ref.put(fst(framesOf(gpu, 6, (sceneWith(g) :: Nil) :: (other :: Nil) :: (other :: Nil) :: (sceneWith(g) :: Nil) :: Nil)), seen));
        let uploadsAtEnd = Ref.get(seen) |> List.last |> Option.map(match (_, _, u) -> u) |> Option.getWithDefault(-1);
        Assert.assertEq(expected = 1, uploadsAtEnd)
    })

    /// 太陽の影のある場面を 3 コマ描いても（色の pass と影の地図の pass の bundle を積んで流す）、device の誤りは出ず、bundle も積み直さない。
    @Test
    def testShadowedBundlesRaiseNoDeviceErrors(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let sun = { shadow = Some(Scene3d.directionalShadow()) | Scene3d.directionalLight(Vec3.v3(-0.4, -1.0, 0.3)) };
        let sunlit = (cmd: Scene3d.RenderCmd) -> { scene = { directionalLight = Some(sun) | cmd#scene } | cmd };
        let frame = sunlit(sceneWith(g)) :: Nil;
        let (seen, (recorded, _, errors)) = framesOf(gpu, 4000000, frame :: frame :: frame :: Nil);
        Assert.assertEq(expected = (1 :: 1 :: 1 :: Nil, 2, 0), (cachedOf(seen), recorded, errors))
    })

    /// 点光源の影の場面の持ち越した物は、色の pass の bundle 1 つと atlas の面ごとの bundle 6 つを積み、続くコマはそれを使い回す（device の誤りは無い）。
    @Test
    def testPointShadowedBundlesAreKeptPerFace(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let lamp = { position = Vec3.v3(0.0, 0.0, 6.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 20.0 };
        let shadowed = { maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() };
        let lit = (cmd: Scene3d.RenderCmd) -> { scene = Scene3d.withPointShadows(shadowed, { pointLights = lamp :: Nil | cmd#scene }) | cmd };
        let frame = lit(sceneWith(town())) :: Nil;
        let (seen, (recorded, _, errors)) = framesOf(gpu, 4000000, frame :: frame :: frame :: Nil);
        Assert.assertEq(expected = (1 :: 1 :: 1 :: Nil, 7, 0), (cachedOf(seen), recorded, errors))
    })

    /// frames を 1 コマずつ描き、コマごとの影の地図の控えの (使い回した数, 描き直した数) と device の誤りの数。
    def shadowCacheCountsOf(gpu: WebGpu, frames: List[List[Scene3d.RenderCmd]]): (List[(Int32, Int32)], Int32) \ IO =
        let paste = layoutOf(gpu, true);
        let renderer = Render3d.WebGpuRenderer.create(gpu, paste, layoutOf(gpu, false));
        let seen = frames |> List.map(cmds -> {
            let encoder = gpu.createCommandEncoder("test");
            let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> checked_ecast(()),
                               skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None),
                               groupById = _ -> checked_ecast(None), stamp = (_, _) -> checked_ecast(()) };
            discard prepare(renderer, host, dest(), cmds);
            gpu.submit(encoder.finish());
            let counts = takeCounts(renderer);
            afterSubmit(renderer);
            endFrameWithin(renderer, { vertices = 4000000, textures = { count = 64, size = 67108864i64 } });
            (counts#shadowMapsReused, counts#shadowMapsRedrawn)
        });
        Render3d.WebGpuRenderer.release(renderer);
        paste.release();
        (seen, gpu.errorCount())

    /// 点光源 1 本の影（atlas の面 6 つ）の場面を 3 コマ描くと、動かない物の控えは最初のコマに 6 面とも描き、続くコマは 6 面とも使い回す（device の誤りは無い）。
    @Test
    def testPointShadowCacheIsReusedAcrossFrames(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let lamp = { position = Vec3.v3(0.0, 0.0, 6.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 20.0 };
        let shadowed = { maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() };
        let frame = { scene = Scene3d.withPointShadows(shadowed, { pointLights = lamp :: Nil | sceneWith(town())#scene }) | sceneWith(town()) } :: Nil;
        Assert.assertEq(expected = ((0, 6) :: (6, 0) :: (6, 0) :: Nil, 0), shadowCacheCountsOf(gpu, frame :: frame :: frame :: Nil))
    })

    /// 灯りが動いたコマは、その灯りの面の控えを描き直す。
    @Test
    def testPointShadowCacheRedrawsWhenLightMoves(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let lampAt = (z: Float64) -> { position = Vec3.v3(0.0, 0.0, z), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 20.0 };
        let shadowed = { maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() };
        let frameAt = (z: Float64) -> { scene = Scene3d.withPointShadows(shadowed, { pointLights = lampAt(z) :: Nil | sceneWith(town())#scene }) | sceneWith(town()) } :: Nil;
        Assert.assertEq(expected = ((0, 6) :: (0, 6) :: Nil, 0), shadowCacheCountsOf(gpu, frameAt(6.0) :: frameAt(5.0) :: Nil))
    })

    /// 持ち越した物も描いた物の数に入る（つないで 1 つの形にした物も 1 つずつ数える）。
    @Test
    def testCarriedItemsAreCountedAsDrawn(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let (_, (_, drawn, _)) = framesOf(gpu, 4000000, (sceneWith(town()) :: Nil) :: Nil);
        Assert.assertEq(expected = 3, drawn)
    })
}
