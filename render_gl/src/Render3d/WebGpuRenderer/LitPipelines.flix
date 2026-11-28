// Render3d.WebGpuRenderer.LitPipelines — WebGPU の 3D の描き手の、頂点の色の pipeline と、その頂点シェーダーと frag（変種の物は初めて要る時に作る）。
// WebGpuRenderer の中身（ゲームは呼ばない）。
pub mod Render3d.WebGpuRenderer.LitPipelines {
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.VertexFormat
    use Render3d.ProgramKey.{ShaderVariant, variantKeyOf}
    use Render3d.ScenePlan.ScenePassSpec
    use Render3d.WebGpuRenderer.{LitPipelineSlot, Renderer, RendererData, layoutCodeOf, litPipelineSlotOf, passCodeOf, sceneDepthFormat, sceneLayoutOf}
    use RenderPaint.Internal.WebGpuPipelines

    /// pass の種類の frag（色の pass は変種 variant の光の frag・奥行きの書き出しは灰色の frag）。変種の光の frag は初めて要る時に作る（字が無ければ None）。
    def fragmentOf(r: Renderer, spec: ScenePassSpec, variant: ShaderVariant): Option[ShaderModule] \ IO =
        let RendererData.RendererData({depthModule = depthModule, fragmentModule = fragmentModule | _}) = r;
        let key = variantKeyOf(variant);
        match spec {
            case ScenePassSpec.Color if key == "" => Some(fragmentModule)
            case ScenePassSpec.Color              => variantFragmentOf(r, variant, key)
            case ScenePassSpec.DepthOut(_) => Some(depthModule)
        }

    /// PS1 風の変種の頂点の色の頂点シェーダー（skinned なら骨つきの版。初めて要る時に作って控える・字が無ければ None）。
    def psxVertexModuleOf(r: Renderer, skinned: Bool): Option[ShaderModule] \ IO =
        let RendererData.RendererData({gpu = gpu, psxVertexModules = psxVertexModules, shaders = shaders | _}) = r;
        match Map.get(skinned, Ref.get(psxVertexModules)) {
            case Some(m) => m
            case None    =>
                let made = Render3d.ShaderLibrary.optionalWgsl(shaders, Render3d.ShaderSourceKey.LitVertex(skinned, true))
                    |> Option.map(source -> gpu.createShaderModule("fge scene3d lit vs+psx", source));
                Ref.put(Map.insert(skinned, made, Ref.get(psxVertexModules)), psxVertexModules);
                made
        }

    /// 変種 variant（鍵 key）の光の frag（初めて要る時に作って控える・字が無ければ None）。
    def variantFragmentOf(r: Renderer, variant: ShaderVariant, key: String): Option[ShaderModule] \ IO =
        let RendererData.RendererData({gpu = gpu, shaders = shaders, variantFragments = variantFragments | _}) = r;
        match Map.get(key, Ref.get(variantFragments)) {
            case Some(m) => m
            case None    =>
                Render3d.ShaderLibrary.recordVariant(shaders, variant);
                let made = Render3d.ShaderLibrary.optionalWgsl(shaders, Render3d.ShaderSourceKey.LitFragment(variant))
                    |> Option.map(source -> gpu.createShaderModule("fge scene3d lit fs" + key, source));
                Ref.put(Map.insert(key, made, Ref.get(variantFragments)), variantFragments);
                made
        }

    /// 形式 format・標本 samples・pass spec・頂点のバイト数 stride（Render3d.WebGpuRows の形の版）の頂点の色の pipeline（無ければ作る）。
    /// skin = 骨つきの版なら形の版のジョイントの番号の位置（バイト。group 1 は空・group 2 に姿勢）。表の面は時計回り（Render3d の頭の約束）で裏を間引き、深度は LESS で書く。variant = 場面の pass の変種（frag と group 0 の layout）。
    // WhyNot: 鍵にジョイントの番号の位置を入れない — 位置は形の版の末尾の 8 float（Render3d.WebGpuRows.floatsPerVertex）で、頂点のバイト数から 1 つに決まる。
    pub def pipelineOf(r: Renderer, format: RenderTarget.Format, samples: Int32, spec: ScenePassSpec, stride: Int32, skin: Option[Int32], variant: ShaderVariant): Option[RenderPipeline] \ IO =
        let RendererData.RendererData(s) = r;
        let {pipelines = pipelines, skinnedModule = skinnedModule | _} = s;
        let key = litPipelineSlotOf({ format = WebGpuPipelines.formatCode(format), samples = samples, pass = passCodeOf(spec), stride = stride, skinned = Option.nonEmpty(skin), variant = variantKeyOf(variant) });
        match Map.get(key, Ref.get(pipelines)) {
            case Some(p) => Some(p)
            case None =>
                let vertexOf = if (variant#psx) psxVertexModuleOf(r, Option.nonEmpty(skin)) else Some(if (Option.nonEmpty(skin)) skinnedModule else s#vertexModule);
                match (vertexOf, fragmentOf(r, spec, variant)) {
                    case (Some(vertexModule), Some(fragmentModule)) => Some(buildLitPipeline(r, key, format, samples, stride, skin, variant, vertexModule, fragmentModule))
                    case _                                          => None
                }
        }

    /// 頂点の色の pipeline を作って控える（pipelineOf の作る所）。
    def buildLitPipeline(r: Renderer, key: LitPipelineSlot, format: RenderTarget.Format, samples: Int32, stride: Int32, skin: Option[Int32], variant: ShaderVariant,
                         vertexModule: ShaderModule, fragmentModule: ShaderModule): RenderPipeline \ IO =
        let RendererData.RendererData({emptyLayout = emptyLayout, gpu = gpu, pipelines = pipelines, poseLayout = poseLayout | _}) = r;
        let desc = new RenderPipelineDesc("fge scene3d lit");
        discard desc.bindGroupLayout(sceneLayoutOf(r, layoutCodeOf(variant))).vertex(vertexModule, "vs_main").fragment(fragmentModule, "fs_main");
        if (Option.nonEmpty(skin)) discard desc.bindGroupLayout(emptyLayout).bindGroupLayout(poseLayout) else ();
        discard desc.vertexBuffer(stride, false).attribute(VertexFormat.FLOAT32X3, 0, 0).attribute(VertexFormat.FLOAT32X3, 12, 1).attribute(VertexFormat.FLOAT32X3, 24, 2);
        skin |> Option.forEach(at -> discard desc.attribute(VertexFormat.FLOAT32X4, at, 14).attribute(VertexFormat.FLOAT32X4, at + 16, 15));
        discard desc.vertexBuffer(Render3dWgsl.instanceBytes(), true);
        discard desc.attribute(VertexFormat.FLOAT32X4, 0, 3).attribute(VertexFormat.FLOAT32X4, 16, 4);
        discard desc.attribute(VertexFormat.FLOAT32X4, 32, 5).attribute(VertexFormat.FLOAT32X4, 48, 6);
        discard desc.attribute(VertexFormat.FLOAT32X4, 64, 7).attribute(VertexFormat.FLOAT32X4, 80, 8);
        discard desc.attribute(VertexFormat.FLOAT32X4, 96, 9).attribute(VertexFormat.FLOAT32X4, 112, 10);
        discard desc.colorTarget(WebGpuPipelines.textureFormatOf(format));
        discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.BACK);
        discard desc.depthStencil(sceneDepthFormat(), true, CompareFunction.LESS).multisample(samples);
        let made = gpu.createRenderPipeline(desc);
        Ref.put(Map.insert(key, made, Ref.get(pipelines)), pipelines);
        made
}
