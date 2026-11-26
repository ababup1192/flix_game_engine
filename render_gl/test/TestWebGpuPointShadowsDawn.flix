// WebGPU の 3D の描き手の点光源の影（+ps）と Physical の光（+pu）の変種: 面の viewport の y と、変種の場面を PC の Dawn で描いて device の誤りが 0 件か（画素は読まない）。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（TestWgslDawn と同じ。`[scene3d-dawn] SKIP:` の行を出す）。
// WhyNot: mod TestWebGpuPointShadowsDawn にしない — Render3d.WebGpuRenderer の Host と prepare を、2D の描き手を通さずに呼ぶ。
mod Render3d.WebGpuRenderer.TestWebGpuPointShadowsDawn {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureSampleType
    import fge.webgpu.WebGpu
    use Render3d.WebGpuRenderer.{Dest, Host, prepare}

    // ── 面の viewport の y ──

    @Test
    def testBottomTileIsDrawnAtTheBottomRowsOfTheAtlas(): Unit \ Assert =
        Assert.assertEq(expected = (32, 32, 32), Render3d.WebGpuShadows.tileViewportOf(64, { x = 32, y = 0, size = 32 }))

    @Test
    def testTopTileIsDrawnAtTheTopRowsOfTheAtlas(): Unit \ Assert =
        Assert.assertEq(expected = (64, 0, 32), Render3d.WebGpuShadows.tileViewportOf(64, { x = 64, y = 32, size = 32 }))

    // ── 変種の場面を Dawn で描く ──

    def dest(): Dest =
        { key = 0, format = RenderTarget.Format.Rgba8Unorm, samples = 1, height = 64,
          viewport = { x = 0, y = 0, width = 64, height = 64, scaleX = 1.0, scaleY = 1.0 } }

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    def imageLayout(gpu: WebGpu): BindGroupLayout \ IO =
        let layoutDesc = new BindGroupLayoutDesc("test image");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(1, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        gpu.createBindGroupLayout(layoutDesc)

    def pasteLayout(gpu: WebGpu): BindGroupLayout \ IO =
        let layoutDesc = new BindGroupLayoutDesc("test paste");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        gpu.createBindGroupLayout(layoutDesc)

    def lamp(): Scene3d.PointLight = { position = Vec3.v3(0.0, 1.0, 0.0), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 }

    /// 骨つきの三角・骨の無い三角・絵と metallic と roughness の材質の三角を、点光源 1 本と空で照らす場面。
    def lampScene(pointShadows: Bool, units: Scene3d.LightUnits): Scene3d.RenderCmd =
        let tex = match Texture3d.fromArgb(4, 4, Vector.range(0, 16) |> Vector.map(i -> if (Int32.remainder(i, 2) == 0) -1 else -16777216)) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        };
        let glossy = Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Linear) |> Scene3d.withMetallicRoughness(0.5, 0.4);
        let textured = Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, Render3d.FakeGl.plainTriangle()), Mat4.translate(Vec3.v3(0.5, 0.0, 0.0)))
            |> Scene3d.withMaterial(glossy);
        let skinned = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity()) |> Scene3d.withPose(Render3d.FakeGl.poseAt(0.5));
        let plain = Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.translate(Vec3.v3(-1.0, 0.0, 0.0)));
        let base = { pointLights = lamp() :: Nil, textures = tex :: Nil,
                     sky = Some(Scene3d.gradientSky(Color.rgb(0.2, 0.3, 0.6), Color.rgb(0.7, 0.7, 0.8), Color.rgb(0.3, 0.2, 0.1))) |
                     Render3d.FakeGl.sceneOf(skinned :: plain :: textured :: Nil) } |> Scene3d.withLightUnits(units);
        let scene = if (pointShadows) Scene3d.withPointShadows({ maxShadowedLights = 1, mapSize = 32 | Scene3d.pointShadowMap() }, base) else base;
        Render3d.FakeGl.cmdOf(scene)

    /// 場面 cmd を 1 回の prepare で描いた時の (積んだ pass の数, device の誤りの数)。
    def passesAndErrors(gpu: WebGpu, cmd: Scene3d.RenderCmd): (Int32, Int32) \ IO = passesAndErrorsWith(gpu, _ -> None, cmd)

    /// passesAndErrors の、ビルボードの絵の名前 → 登録した絵 textureOf を渡す版。
    def passesAndErrorsWith(gpu: WebGpu, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture], cmd: Scene3d.RenderCmd): (Int32, Int32) \ IO =
        let layout = pasteLayout(gpu);
        let image = imageLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, image);
        let encoder = gpu.createCommandEncoder("test");
        let passes = Ref.fresh(Static, 0);
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> Ref.put(Ref.get(passes) + 1, passes), flush = () -> checked_ecast(()),
                           skip = (_, _) -> checked_ecast(()), textureOf = name -> checked_ecast(textureOf(name)), textureById = _ -> checked_ecast(None), groupById = _ -> checked_ecast(None), stamp = (_, _) -> checked_ecast(()) };
        discard prepare(renderer, host, dest(), cmd :: Nil);
        gpu.submit(encoder.finish());
        let errors = gpu.errorCount();
        Render3d.WebGpuRenderer.release(renderer);
        image.release();
        layout.release();
        (Ref.get(passes), errors)

    /// 影を落とす灯り 1 本の場面は、atlas の面 6 つの pass と場面の pass 1 つを積み、+ps・+pu・+ps+pu のどの変種でも device の誤りが無い。
    @Test
    def testVariantScenesDrawWithoutDeviceErrors(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let shadowed = passesAndErrors(gpu, lampScene(true, Scene3d.LightUnits.Legacy));
                let physical = passesAndErrors(gpu, lampScene(false, Scene3d.LightUnits.Physical));
                let both = passesAndErrors(gpu, lampScene(true, Scene3d.LightUnits.Physical));
                gpu.destroy();
                Assert.assertEq(expected = ((7, 0), (1, 0), (7, 0)), (shadowed, physical, both))
        }

    /// 影を落とす灯り 4 本と、影を落とすビルボード 300 枚の場面（面ごとの行の値の合計が値の buffer の始めの 64 KB を超える）。
    def crowdScene(): Scene3d.RenderCmd =
        let lampAt = (x: Float64, z: Float64) -> { position = Vec3.v3(x, 1.0, z), color = { r = 1.0, g = 1.0, b = 1.0 }, intensity = 1.0, range = 10.0 };
        let boards = List.range(0, 300) |> List.map(i -> {
            let x = Int32.toFloat64(Int32.remainder(i, 20)) * 0.2 - 2.0;
            let z = Int32.toFloat64(i / 20) * 0.2 - 1.5;
            Scene3d.billboard("chars", { position = { x = 0.0, y = 0.0 }, size = { x = 16.0, y = 24.0 } }, Vec3.v3(x, 0.0, z), { x = 0.1, y = 0.2 })
                |> Scene3d.withCastShadows(true)
        });
        let base = { pointLights = lampAt(-1.0, -1.0) :: lampAt(1.0, -1.0) :: lampAt(-1.0, 1.0) :: lampAt(1.0, 1.0) :: Nil, billboards = boards
                   | Render3d.FakeGl.sceneOf(Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.identity()) :: Nil) };
        Render3d.FakeGl.cmdOf(Scene3d.withPointShadows({ maxShadowedLights = 4, mapSize = 32 | Scene3d.pointShadowMap() }, base))

    /// 面ごとの行の値の合計が値の buffer より大きい場面でも、値の buffer を先に場面の分だけ取るので device の誤り（書く範囲が buffer に入らない）が無い。
    @Test
    def testManyShadowFacesFitTheValueBuffer(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let registered = (_: String) -> Some({ texId = 1, width = 16.0, height = 24.0, flipped = false, version = "1" });
                let (_, errors) = passesAndErrorsWith(gpu, registered, crowdScene());
                gpu.destroy();
                Assert.assertEq(expected = 0, errors)
        }
}
