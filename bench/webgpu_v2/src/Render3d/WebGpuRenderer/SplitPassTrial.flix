// 3D を 2D へ貼る 2 つの形（plans/engine-webgpu.md の 5.4・9.1）を、同じ道具で 1 コマずつ組んで時間を比べる試し（V2 の比べにだけ使う）。
// A = 先に場面を自分の texture へ描き、2D の pass でその texture を貼る（本番の形）。
// B = 2D の pass を場面の所で閉じ、場面を描き先へ直に描いて（色は前の中身に描き足し・深度は場面の物）、2D の pass を開き直す。
// どちらも 2D の中身は持たない（2D の pass を開く・閉じる・貼る代金だけが違う）。描き先は RGBA8・標本 1（画面の中間の texture と同じ）。
// WhyNot: 本番の WebGpuPaint の道で B を組まない — B は 2D の pass を行の途中で開き直す道（viewport・控え・黒帯・stencil の張り直し）が要り、比べるためだけに本番へ足さない。
// WhyNot: 本番の寿命の道（submit の途中で 1 体ごとの値と場面の値を頭から書き直す・同じ描き先の 2 回目で先に submit する）を通さない — Host の flush は何もせず、
//   submit はコマの終わりに 1 回だけ。1 コマに場面 1 つで同じ描き先を 2 回書かないので、時間の比べには効かない（寿命の決まりは render_gl の TestWebGpuScene3dDawn が見る）。
// WhyNot: Render3d.WebGpuRenderer の外に置かない — 子孫の mod からは pub でない物が見えるので、比べをここに置けば engine の pub を増やさずに済む。
pub mod Render3d.WebGpuRenderer.SplitPassTrial {
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CommandEncoder
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    use Render3d.{clipBox, sceneRect}
    use Render3d.ScenePlan.{groupScenes, planScenes}
    use Render3d.WebGpuRenderer.{Host, Prepared, Renderer, RendererData, afterSubmit, encodeScene, endFrame, prepare, stageScene, targetOf, topLeftOf}
    use RenderPaint.Internal.WebGpuPipelines

    /// 試しの道具。frame = 描き先（width × height）・frameGroup = 2D の pass の group 0（読まれない射影の値）。
    pub type alias Trial = {
        gpu = WebGpu, renderer = Renderer, pipes = WebGpuPipelines.Pipelines, frameLayout = BindGroupLayout, imageLayout = BindGroupLayout,
        frameValues = Buffer, frameGroup = BindGroup, frame = Texture, width = Int32, height = Int32, design = (Float64, Float64)
    }

    pub def open(gpu: WebGpu, width: Int32, height: Int32, design: (Float64, Float64)): Trial \ IO =
        openWith(gpu, width, height, design, Render3d.WebGpuMaterials.ValuesBinding.Uniform)

    /// open の、材質の値の binding の形を選ぶ版（uniform と storage の比べ・12.28）。
    pub def openWith(gpu: WebGpu, width: Int32, height: Int32, design: (Float64, Float64), binding: Render3d.WebGpuMaterials.ValuesBinding): Trial \ IO =
        let frameLayout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("trial frame").buffer(0, ShaderStage.VERTEX, BufferBindingType.UNIFORM));
        let imageDesc = new BindGroupLayoutDesc("trial image");
        discard imageDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(1, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        let imageLayout = gpu.createBindGroupLayout(imageDesc);
        let frameValues = gpu.createBuffer("trial frame values", 64i64, Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST));
        let pipes = WebGpuPipelines.fresh(gpu, frameLayout, imageLayout, design);
        { gpu = gpu, renderer = Render3d.WebGpuRenderer.createWith(gpu, pipes#sceneLayout, binding), pipes = pipes, frameLayout = frameLayout, imageLayout = imageLayout,
          frameValues = frameValues, frameGroup = gpu.createBindGroup(new BindGroupDesc("trial frame", frameLayout).buffer(0, frameValues, 0i64, 64i64)),
          frame = gpu.createTexture("trial frame", width, height, TextureFormat.RGBA8_UNORM,
                                    Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.TEXTURE_BINDING), 1, 1),
          width = width, height = height, design = design }

    pub def close(t: Trial): Unit \ IO =
        Render3d.WebGpuRenderer.release(t#renderer);
        WebGpuPipelines.release(t#pipes);
        t#frameGroup.release();
        t#frameValues.destroy();
        t#frame.destroy();
        t#frameLayout.release();
        t#imageLayout.release()

    /// 1 コマぶんの encoder を貸す Host（submit は frameA・frameB の終わりに 1 回だけ）。
    def hostOf(encoder: CommandEncoder): Host =
        { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> checked_ecast(()), skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None) }

    def viewportOf(t: Trial): Scene3dRenderer.Viewport =
        let (dw, dh) = t#design;
        { x = 0, y = 0, width = t#width, height = t#height, scaleX = Int32.toFloat64(t#width) / dw, scaleY = Int32.toFloat64(t#height) / dh }

    /// A の 1 コマを組んで submit する（GPU を待たない）。
    pub def frameA(t: Trial, cmds: List[Scene3d.RenderCmd]): Unit \ IO =
        let encoder = t#gpu.createCommandEncoder("trial A");
        let prepared = prepare(t#renderer, hostOf(encoder),
                               { key = 0, format = RenderTarget.Format.Rgba8Unorm, samples = 1, viewport = viewportOf(t), height = t#height }, cmds);
        let pass = open2d(t, encoder, true);
        pasteAll(t, pass, prepared);
        pass.end();
        finish(t, encoder)

    /// B の 1 コマを組んで submit する（GPU を待たない）。
    pub def frameB(t: Trial, cmds: List[Scene3d.RenderCmd]): Unit \ IO =
        let RendererData.RendererData(s) = t#renderer;
        let encoder = t#gpu.createCommandEncoder("trial B");
        let host = hostOf(encoder);
        open2d(t, encoder, true).end();
        let caps = { alphaToOne = false, poseRowLimit = 0 };
        let grouped = groupScenes(s#planner, caps, 1, cmds);
        let (plans, _) = planScenes(s#planner, caps, Vector.map(_ -> 0, grouped#requests), grouped);
        let vp = viewportOf(t);
        plans |> List.forEachWithIndex((i, plan) -> {
            let rect = sceneRect(vp, plan#cmd);
            let scissor = clipBox(vp, rect, plan#cmd#clip);
            let target = targetOf(t#renderer, host, (0, i), { width = rect#width, height = rect#height, format = RenderTarget.Format.Rgba8Unorm, samples = 1 });
            let staged = stageScene(t#renderer, host, target, { members = grouped#members, poses = None }, plan, Nil);
            // WhyNot: 空を描かない — 空の frag は描き先の左上を場面の左上として向きを作り、画面の途中の矩形へ描く形 B では向きがずれる（比べる部屋の場面に空は無い）。
            staged#passes |> List.forEach(match (spec, list, valuesBase) ->
                encodeScene(t#renderer, host, target, { spec = spec, list = list, instanceBase = staged#instanceBase, valuesBase = valuesBase, poseGroup = staged#poseGroup,
                                                       sceneGroup = target#sceneGroup, sky = false },
                            { color = t#frame.defaultView(), resolve = None, clear = None, depth = target#depth.defaultView(),
                              viewport = topLeftOf(t#height, rect), scissor = topLeftOf(t#height, scissor) }))
        });
        open2d(t, encoder, false).end();
        finish(t, encoder)

    /// 2D の pass を開く（clear が真なら黒で消す・偽なら前の中身に描き足す）。group 0 を積む。
    def open2d(t: Trial, encoder: CommandEncoder, clear: Bool): RenderPass \ IO =
        let desc = new RenderPassDesc("trial 2d");
        if (clear) discard desc.clearColor(t#frame.defaultView(), 0.0, 0.0, 0.0, 1.0) else discard desc.loadColor(t#frame.defaultView());
        let pass = encoder.beginRenderPass(desc);
        pass.setBindGroup(0, t#frameGroup);
        pass

    def pasteAll(t: Trial, pass: RenderPass, prepared: Prepared): Unit \ IO =
        prepared |> Vector.forEach(found -> Option.forEach(paste -> {
            let (x, y, w, h) = paste#scissor;
            pass.setPipeline(WebGpuPipelines.pipelineOf(t#pipes, RenderFrame.Internal.WebGpuRows.shapeScene(), RenderFrame.Internal.WebGpuRows.blendScene(),
                                                        RenderTarget.Format.Rgba8Unorm, 1, RenderFrame.Internal.WebGpuRows.stencilNone()));
            pass.setBindGroup(1, paste#group);
            pass.setScissorRect(x, y, w, h);
            pass.draw(3, 1, 0, 0)
        }, found))

    def finish(t: Trial, encoder: CommandEncoder): Unit \ IO =
        t#gpu.submit(encoder.finish());
        afterSubmit(t#renderer);
        endFrame(t#renderer)
}
