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

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 }

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

    /// cmds を 1 コマずつ prepare して submit し（encoder は捨てる）、コマを締める。vertices = 形の頂点の上限。
    /// 返すのは (コマごとの、締める前の持ち越しの数と、作り直して手放す buffer の数, 最後のコマの描いた物の数)。
    def framesOf(gpu: WebGpu, vertices: Int32, cmds: List[Scene3d.RenderCmd]): (List[(Int32, Int32)], Int32) \ IO =
        let paste = layoutOf(gpu, true);
        let renderer = Render3d.WebGpuRenderer.create(gpu, paste, layoutOf(gpu, false));
        let RendererData.RendererData(s) = renderer;
        let drawn = Ref.fresh(Static, 0);
        let seen = cmds |> List.map(cmd -> {
            let encoder = gpu.createCommandEncoder("test");
            let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> checked_ecast(()),
                               skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None),
                               groupById = _ -> checked_ecast(None) };
            discard prepare(renderer, host, dest(), cmd :: Nil);
            let held = (Render3d.StaticRows.sizeOf(s#statics#cache), List.length(Ref.get(s#statics#retired)));
            discard encoder.finish();
            Ref.put(takeCounts(renderer)#drawn, drawn);
            afterSubmit(renderer);
            endFrameWithin(renderer, { vertices = vertices, textures = { count = 64, size = 67108864i64 } });
            held
        });
        Render3d.WebGpuRenderer.release(renderer);
        paste.release();
        (seen, Ref.get(drawn))

    /// 同じ集まりの値を 3 コマ続けて描くと、持ち越しは 1 つのままで作り直さない（手放す buffer が出ない）。
    @Test
    def testSameGroupIsCarriedAcrossFrames(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        Assert.assertEq(expected = (1, 0) :: (1, 0) :: (1, 0) :: Nil, fst(framesOf(gpu, 4000000, sceneWith(g) :: sceneWith(g) :: sceneWith(g) :: Nil)))
    })

    /// 外す鍵が変わったコマは作り直し、前の buffer 2 本（1 体ごとの値と材質の値）を submit の後に手放す。
    @Test
    def testRemovedKeyRebuildsAndRetires(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let frames = sceneWith(g) :: sceneWith(Scene3d.withoutItems(Set#{"b"}, g)) :: Nil;
        Assert.assertEq(expected = (1, 0) :: (1, 2) :: Nil, fst(framesOf(gpu, 4000000, frames)))
    })

    /// 形の置き場が上限を超えて形を捨てたコマの後は、持ち越しを全部作り直す（行の形の番号が別の形を指しうる）。
    /// 2・3 コマ目は集まりを描かずに別の四角だけを描き、3 コマ目を締める時に 1 コマ目の集まりの形が捨てられる（今と前のコマで使った形は捨てない）。
    @Test
    def testMeshEvictionDropsCarried(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let other = { at = Vec2.zero(), clip = None, scene = { instances = quadAt(4.0) :: Nil | Scene3d.scene(camera(), { x = 64.0, y = 64.0 }) } };
        let seen = Ref.fresh(Static, Nil);
        discard Render3d.FakeGl.stderrOf(() -> Ref.put(fst(framesOf(gpu, 6, sceneWith(g) :: other :: other :: sceneWith(g) :: Nil)), seen));
        Assert.assertEq(expected = (1, 0) :: (1, 0) :: (1, 0) :: (1, 2) :: Nil, Ref.get(seen))
    })

    /// 太陽の影のある場面を 3 コマ描いても（色の pass と影の地図の pass の bundle を積んで流す）、device の誤りは出ず、持ち越しも作り直さない。
    @Test
    def testShadowedBundlesRaiseNoDeviceErrors(): Unit \ {Assert, IO} = withDawn(gpu -> {
        let g = town();
        let sun = { shadow = Some(Scene3d.directionalShadow()) | Scene3d.directionalLight(Vec3.v3(-0.4, -1.0, 0.3)) };
        let sunlit = (cmd: Scene3d.RenderCmd) -> { scene = { directionalLight = Some(sun) | cmd#scene } | cmd };
        let frames = fst(framesOf(gpu, 4000000, sunlit(sceneWith(g)) :: sunlit(sceneWith(g)) :: sunlit(sceneWith(g)) :: Nil));
        Assert.assertEq(expected = ((1, 0) :: (1, 0) :: (1, 0) :: Nil, 0), (frames, gpu.errorCount()))
    })

    /// 持ち越した物も描いた物の数に入る。
    @Test
    def testCarriedItemsAreCountedAsDrawn(): Unit \ {Assert, IO} = withDawn(gpu ->
        Assert.assertEq(expected = 3, snd(framesOf(gpu, 4000000, sceneWith(town()) :: Nil))))
}
