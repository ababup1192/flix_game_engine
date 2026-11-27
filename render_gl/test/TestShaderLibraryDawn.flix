// ブラウザ版の前もって作るシェーダーの表（Render3d.ShaderLibrary）だけを引く WebGPU の描き手が、記録から広げた表で全部の字を引けることを、PC の Dawn で device を開いて確かめる。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（`[shader-library-dawn] SKIP:` の行を出す）。
// WhyNot: mod TestShaderLibraryDawn にしない — 表の口で描き手を作る Render3d.WebGpuRenderer.createFrom と Host・prepare を、2D の描き手を通さずに呼ぶ。
mod Render3d.WebGpuRenderer.TestShaderLibraryDawn {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureSampleType
    import fge.webgpu.WebGpu
    use Render3d.WebGpuRenderer.{Dest, Host, RendererData, createFrom, prepare}
    use Render3d.ShaderLibrary.{emptyCollection, unionCollection, collectionKeysOf}

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    def layoutOf(gpu: WebGpu, label: String, paste: Bool): BindGroupLayout \ IO =
        let desc = new BindGroupLayoutDesc(label);
        discard desc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT);
        if (paste) discard desc.buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM) else discard desc.sampler(1, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        gpu.createBindGroupLayout(desc)

    def destOf(samples: Int32): Dest =
        { key = samples, format = RenderTarget.Format.Rgba8Unorm, samples = samples, height = 64,
          viewport = { x = 0, y = 0, width = 64, height = 64, scaleX = 1.0, scaleY = 1.0 } }

    /// 表 table だけを引く描き手で、場面を標本 1 と 4 の描き先へ準備し、変種ごとのビルボードの pipeline も作った時の標準エラーと、device の誤りの数。
    def preparedFromTable(gpu: WebGpu, table: Map[String, String]): (String, Int32) \ IO =
        let paste = layoutOf(gpu, "test paste", true);
        let image = layoutOf(gpu, "test image", false);
        let renderer = createFrom(gpu, paste, image, Render3d.WebGpuMaterials.ValuesBinding.Uniform,
                                  Render3d.ShaderLibrary.withoutRecording(Render3d.ShaderLibrary.providerOfTable(table)));
        let RendererData.RendererData(s) = renderer;
        let encoder = gpu.createCommandEncoder("test");
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> checked_ecast(()), skip = (_, _) -> checked_ecast(()),
                           textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None), groupById = _ -> checked_ecast(None), stamp = (_, _) -> checked_ecast(()) };
        let cmds = Render3d.TestShaderLibrary.scenes() |> List.map(scene -> { at = Vec2.zero(), clip = None, scene = scene });
        let said = Render3d.FakeGl.stderrOf(() -> {
            discard prepare(renderer, host, destOf(1), cmds);
            discard prepare(renderer, host, destOf(4), cmds);
            Render3d.TestShaderLibrary.scenes() |> List.forEach(scene -> {
                let v = Render3d.ProgramKey.passVariantOf(scene);
                let code = Render3d.WebGpuRenderer.layoutCodeOf(v);
                discard Render3d.WebGpuBillboards.pipelineOf(s#billboards, RenderTarget.Format.Rgba8Unorm, 1, v, (code, Render3d.WebGpuRenderer.sceneLayoutOf(renderer, code)))
            })
        });
        discard encoder.finish();
        let errors = gpu.errorCount();
        Render3d.WebGpuRenderer.release(renderer);
        image.release();
        paste.release();
        (said, errors)

    @Test
    def testWebGpuRendererFindsEverySourceInTheTable(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[shader-library-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let collection = Render3d.TestShaderLibrary.scenes() |> List.foldLeft((acc, sc) -> unionCollection(acc, collectionKeysOf(sc)), emptyCollection());
                let (said, errors) = preparedFromTable(gpu, Render3d.TestShaderLibrary.tableOf(collection));
                let (saidEmpty, _) = preparedFromTable(gpu, Render3d.TestShaderLibrary.tableOf(emptyCollection()));
                gpu.destroy();
                Assert.assertEq(expected = (false, 0, true, true),
                                (String.contains(substr = "shader-variants.json", said), errors,
                                 String.contains(substr = "material.fs", saidEmpty), String.contains(substr = "billboard.fs+psx", saidEmpty)))
        }
}
