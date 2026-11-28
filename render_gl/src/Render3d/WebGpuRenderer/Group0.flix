// Render3d.WebGpuRenderer.Group0 — WebGPU の 3D の描き手の場面の group 0 のうち、変種が足す binding の layout と、+ao の SSAO の mask の pass。
// WebGpuRenderer の中身（ゲームは呼ばない）。
pub mod Render3d.WebGpuRenderer.Group0 {
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureView
    use Render3d.PixelBox
    use Render3d.ProgramKey.Group0Binding
    use Render3d.WebGpuRenderer.{Host, Renderer, RendererData, SceneTarget}

    /// 場面の group 0 の layout の作り方。bindings = 変種が足す binding（Render3d.ProgramKey.group0Of。空なら既定）。
    // WhyNot: 既定の layout に変種の binding を足しておかない — 既定の pipeline の group 0 の layout が変わる（変種を使わない場面は今の layout のまま）。
    pub def sceneLayoutDesc(label: String, bindings: Set[Group0Binding]): BindGroupLayoutDesc \ IO =
        let desc = new BindGroupLayoutDesc(label);
        discard desc.buffer(0, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        discard desc.texture(1, ShaderStage.FRAGMENT, TextureSampleType.DEPTH).texture(2, ShaderStage.FRAGMENT, TextureSampleType.DEPTH);
        discard desc.texture(3, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(4, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        discard desc.buffer(5, ShaderStage.VERTEX, BufferBindingType.UNIFORM);
        bindings |> Set.forEach(b -> match b {
            case Group0Binding.LightBuffer      => discard desc.buffer(Render3dWgsl.lightBinding(), ShaderStage.FRAGMENT, BufferBindingType.UNIFORM)
            case Group0Binding.PointShadowAtlas => discard desc.texture(Render3dWgsl.pointShadowMapBinding(), ShaderStage.FRAGMENT, TextureSampleType.DEPTH)
            case Group0Binding.AoMask           =>
                discard desc.texture(Render3dWgsl.aoMaskBinding(), ShaderStage.FRAGMENT, TextureSampleType.FLOAT).buffer(Render3dWgsl.aoMaskBinding() + 1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM)
        });
        desc

    /// group 0 の binding b の、形の番号の bit。
    pub def group0Bit(b: Group0Binding): Int32 = match b {
        case Group0Binding.LightBuffer      => 1
        case Group0Binding.PointShadowAtlas => 2
        case Group0Binding.AoMask           => 4
    }

    /// 場面の SSAO の mask の pass を積み、mask の view を返す（+ao の場面だけが呼ぶ。奥行きの Pass が見つからない場面は 1 回知らせて代わりの絵（1 = 暗くしない）を返す）。
    pub def encodeScreenMask(r: Renderer, host: Host, target: SceneTarget, placed: { key = (Int32, Int32), rect = PixelBox }, scene: Scene3d.Scene3dCmd): TextureView \ IO =
        let RendererData.RendererData(s) = r;
        let depthName = scene#screenInputs |> Option.map(i -> Scene3d.screenInputsFieldsOf(i)#depth) |> Option.getWithDefault("");
        let depth = host#textureOf(depthName) |> Option.flatMap(t -> host#textureById(t#texId));
        let rect = placed#rect;
        writeAoValues(r, target, scene);
        match depth {
            case Some(d) =>
                Render3d.WebGpuScreenPasses.encodeMask(s#screen, host, placed#key, (rect#x, rect#y, rect#width, rect#height), (target#width, target#height), d, scene);
                Render3d.WebGpuScreenPasses.maskViewOf(s#screen, placed#key)
            case None =>
                Render3d.ScenePlan.warnOnce(s#planner, "@screen-effects-depth:" + depthName, Scene3d.Internal.ScreenInputs.missingDepthLine(depthName));
                Render3d.WebGpuScreenPasses.maskViewOf(s#screen, (-1, -1))
        }

    /// R3dAo（場面の描き先の幅・高さ・lightAffect）を target#aoValues へ書く（GL の Render3d.Light.withScreenAo と同じ値）。
    def writeAoValues(r: Renderer, target: SceneTarget, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let RendererData.RendererData({cpuPaste = cpuPaste, gpu = gpu | _}) = r;
        let affect = scene#screenInputs |> Option.flatMap(i -> Scene3d.screenInputsFieldsOf(i)#ambientOcclusion)
                     |> Option.map(ScreenEffects3d.lightAffectOf) |> Option.getWithDefault(0.0);
        let data = cpuPaste;
        discard data.putFloat(0, Int32.toFloat32(target#width)).putFloat(4, Int32.toFloat32(target#height));
        discard data.putFloat(8, RenderUtil.f32(affect)).putFloat(12, 0.0f32);
        gpu.writeBuffer(target#aoValues, 0i64, data, 0, 16)
}
