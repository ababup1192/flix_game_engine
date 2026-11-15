// RenderPaint.Internal.WebGpuPipelines — WebGPU の塗りのコア（WebGpuPaint）の pipeline と mask の stencil の表。
// pipeline は形（WebGpuRows.shape*）× blend × 描き先の形式 × 標本の数 × stencil の使い方（WebGpuRows.stencil*）ごとに 1 本で、初めて要る時に作って控える。
// stencil は描き先ごとに 1 枚（中間の texture は鍵 0・Pass は絵の表の番号）で、初めて mask を描く pass で作る。
pub mod RenderPaint.Internal.WebGpuPipelines {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BlendFactor
    import fge.webgpu.BlendOperation
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CompareFunction
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.StencilOperation
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use RenderFrame.Internal.RenderList
    use RenderFrame.Internal.WebGpuRows
    use RenderPaint.Internal.TileTable
    use RenderPaint.Internal.WebGpuShader

    /// pipeline と stencil の表。frameLayout と imageLayout は WebGpuPaint の持ち物（ここでは手放さない）。
    /// sceneLayout = 3D の場面を貼る形の group 1（場面の texture と貼る矩形の uniform・WebGpuShader.sceneWgsl）。表が作って手放す。
    /// pipelines の鍵 = 形 × targetKeys() + targetKeyOf（blend・形式（0 = RGBA8_UNORM・1 = RGBA16_FLOAT）・標本・stencil の使い方）。
    /// stencils = 描き先の鍵 → DEPTH24_PLUS_STENCIL8 の texture と、その幅・高さ・標本の数。
    pub type alias Pipelines = {
        gpu = WebGpu,
        spriteModule = ShaderModule,
        polyModule = ShaderModule,
        tileModule = ShaderModule,
        sceneModule = ShaderModule,
        sceneLayout = BindGroupLayout,
        frameLayout = BindGroupLayout,
        imageLayout = BindGroupLayout,
        pipelines = Ref[Map[Int32, RenderPipeline], Static],
        stencils = Ref[Map[Int32, (Texture, Int32, Int32, Int32)], Static],
        stencilResetQuad = Buffer
    }

    /// shader module と、stencil を 0 に戻す 6 頂点の buffer を作った空の表。design = 射影の寸。
    pub def fresh(gpu: WebGpu, frameLayout: BindGroupLayout, imageLayout: BindGroupLayout, design: (Float64, Float64)): Pipelines \ IO =
        { gpu = gpu,
          spriteModule = gpu.createShaderModule("fge sprite", WebGpuShader.spriteWgsl()),
          polyModule = gpu.createShaderModule("fge polygon", WebGpuShader.polyWgsl()),
          tileModule = gpu.createShaderModule("fge tile", WebGpuShader.tileWgsl()),
          sceneModule = gpu.createShaderModule("fge scene3d paste", WebGpuShader.sceneWgsl()),
          sceneLayout = createSceneLayout(gpu),
          frameLayout = frameLayout, imageLayout = imageLayout,
          pipelines = Ref.fresh(Static, Map.empty()), stencils = Ref.fresh(Static, Map.empty()),
          stencilResetQuad = createResetQuad(gpu, design) }

    /// 場面を貼る形の group 1 の layout（場面の texture と、貼る矩形の uniform）。
    def createSceneLayout(gpu: WebGpu): BindGroupLayout \ IO =
        let desc = new BindGroupLayoutDesc("fge scene3d paste");
        discard desc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        gpu.createBindGroupLayout(desc)

    /// 起動の時に作る pipeline（RGBA8・標本 1 の、stencil の無い pass と mask のある pass の両方）。RGBA16_FLOAT と標本 4 は初めて要る Pass で作る。
    // WhyNot: mask のある pass の分を初めて mask が出たコマで作らない — Dawn は pipeline を作り終えるまで待つので、そのコマが詰まる。
    //   stencil つきの pass では mask の無い行まで Keep の pipeline に替わるので、スプライトと多角形とタイルの分も要る。
    pub def buildStartupPipelines(pipes: Pipelines): Unit \ IO =
        List.forEach(stencil -> {
            List.forEach(b -> {
                discard pipelineOf(pipes, WebGpuRows.shapeSprite(), b, RenderTarget.Format.Rgba8Unorm, 1, stencil);
                discard pipelineOf(pipes, WebGpuRows.shapePoly(), b, RenderTarget.Format.Rgba8Unorm, 1, stencil)
            }, 0 :: 1 :: 2 :: Nil);
            discard pipelineOf(pipes, WebGpuRows.shapeTile(), 0, RenderTarget.Format.Rgba8Unorm, 1, stencil)
        }, WebGpuRows.stencilNone() :: WebGpuRows.stencilKeep() :: Nil);
        List.forEach(b -> discard pipelineOf(pipes, WebGpuRows.shapeSprite(), b, RenderTarget.Format.Rgba8Unorm, 1, WebGpuRows.stencilEqual()),
                     0 :: 1 :: 2 :: Nil);
        discard pipelineOf(pipes, WebGpuRows.shapePoly(), 0, RenderTarget.Format.Rgba8Unorm, 1, WebGpuRows.stencilWrite())

    /// pipeline・stencil・shader module・6 頂点の buffer を手放す。この後 pipes は使えない。
    pub def release(pipes: Pipelines): Unit \ IO =
        Map.forEach((_, pipeline) -> pipeline.release(), Ref.get(pipes#pipelines));
        Ref.put(Map.empty(), pipes#pipelines);
        Map.forEach((_, e) -> { let (texture, _, _, _) = e; texture.destroy() }, Ref.get(pipes#stencils));
        Ref.put(Map.empty(), pipes#stencils);
        pipes#stencilResetQuad.destroy();
        pipes#spriteModule.release();
        pipes#polyModule.release();
        pipes#tileModule.release();
        pipes#sceneModule.release();
        pipes#sceneLayout.release()

    /// pipeline の鍵のうち描き先と重ね方の分: ((blend の番号 × 2 + 形式) × 2 + 標本（0 = 1・1 = 4）) × 4 + stencil の使い方（0 以上 targetKeys() 未満）。
    /// 鍵の残り（形か面の program の番号）は × targetKeys() して足す。
    pub def targetKeyOf(blendC: Int32, format: RenderTarget.Format, samples: Int32, stencil: Int32): Int32 =
        ((blendC * 2 + formatCode(format)) * 2 + (if (samples > 1) 1 else 0)) * 4 + stencil

    /// targetKeyOf が取る値の数（blend 4（3 つと場面を貼る WebGpuRows.blendScene）× 形式 2 × 標本 2 × stencil 4 = 64 を収める）。
    pub def targetKeys(): Int32 = 64

    pub def formatCode(format: RenderTarget.Format): Int32 = match format {
        case RenderTarget.Format.Rgba8Unorm  => 0
        case RenderTarget.Format.Rgba16Float => 1
    }

    pub def textureFormatOf(format: RenderTarget.Format): TextureFormat = match format {
        case RenderTarget.Format.Rgba8Unorm  => TextureFormat.RGBA8_UNORM
        case RenderTarget.Format.Rgba16Float => TextureFormat.RGBA16_FLOAT
    }

    /// 形（WebGpuRows.shape*）と blend の番号（RenderFrame.blendCode）と描き先の形式と標本の数（1 か 4）と stencil の使い方（WebGpuRows.stencil*）の
    /// pipeline（無ければ作る）。
    pub def pipelineOf(pipes: Pipelines, shape: Int32, blendC: Int32, format: RenderTarget.Format, samples: Int32, stencil: Int32): RenderPipeline \ IO =
        let key = shape * targetKeys() + targetKeyOf(blendC, format, samples, stencil);
        match Map.get(key, Ref.get(pipes#pipelines)) {
            case Some(pipeline) => pipeline
            case None =>
                let pipeline = buildPipeline(pipes, shape, blendC, textureFormatOf(format), samples, stencil);
                Ref.put(Map.insert(key, pipeline, Ref.get(pipes#pipelines)), pipes#pipelines);
                pipeline
        }

    /// glBlendFunc と同じ因子を色と alpha の両方に書く。Normal = (src-alpha, 1 − src-alpha)・Add = (src-alpha, 1)・Multiply = (dst, 1 − src-alpha)・
    /// 場面を貼る（WebGpuRows.blendScene）= (1, 1 − src-alpha)（GL の Render3d.blitDesign と同じ）。
    /// 頂点の buffer の並びは形ごと: スプライト = instance（152 バイト）・多角形 = 頂点（24 バイト）と view（stride 0）・
    /// タイル = タイル 1 枚（40 バイト）と層の値（stride 0）。
    /// stencil の使い方が Write の時は blend を (0, 1) にして色を変えない（glColorMask(false…) の代わり）。
    // WhyNot: Write で色の書き込みの mask を 0 にしない — render_gl/java の RenderPipelineDesc に色の書き込みの mask の口が無く、足すと GL の層の jar のハッシュと
    //   ブラウザの実装が動く。
    def buildPipeline(pipes: Pipelines, shape: Int32, blendC: Int32, format: TextureFormat, samples: Int32, stencil: Int32): RenderPipeline \ IO =
        let entry = if (blendC == 2 and stencil != WebGpuRows.stencilWrite()) "fs_multiply" else "fs_main";
        let desc = new RenderPipelineDesc("fge ${Int32.toString(shape)} ${entry} ${Int32.toString(blendC)} ${Int32.toString(stencil)}");
        if (shape == WebGpuRows.shapePoly()) describePoly(pipes#frameLayout, pipes#polyModule, entry, desc)
        else if (shape == WebGpuRows.shapeTile()) describeTile(pipes#frameLayout, pipes#imageLayout, pipes#tileModule, desc)
        else if (shape == WebGpuRows.shapeScene()) describeScene(pipes#frameLayout, pipes#sceneLayout, pipes#sceneModule, desc)
        else describeSprite(pipes#frameLayout, pipes#imageLayout, pipes#spriteModule, entry, desc);
        describeTarget(blendC, format, samples, stencil, desc);
        pipes#gpu.createRenderPipeline(desc)

    /// 描き先の形式・標本の数・blend の因子・stencil の使い方を pipeline に書く（スプライトの形と面で同じ物）。
    pub def describeTarget(blendC: Int32, format: TextureFormat, samples: Int32, stencil: Int32, desc: RenderPipelineDesc): Unit \ IO =
        let (src, dst) =
            if (stencil == WebGpuRows.stencilWrite()) (BlendFactor.ZERO, BlendFactor.ONE)
            else if (blendC == 1) (BlendFactor.SRC_ALPHA, BlendFactor.ONE)
            else if (blendC == 2) (BlendFactor.DST, BlendFactor.ONE_MINUS_SRC_ALPHA)
            else if (blendC == WebGpuRows.blendScene()) (BlendFactor.ONE, BlendFactor.ONE_MINUS_SRC_ALPHA)
            else (BlendFactor.SRC_ALPHA, BlendFactor.ONE_MINUS_SRC_ALPHA);
        discard desc.colorTarget(format).blend(src, dst, BlendOperation.ADD, src, dst, BlendOperation.ADD).multisample(samples);
        describeStencil(stencil, desc)

    /// stencil の使い方（WebGpuRows.stencil*）を pipeline に書く。None は depth と stencil を持たない。表と裏は同じ・深度は比べず書かない。
    def describeStencil(stencil: Int32, desc: RenderPipelineDesc): Unit \ IO =
        if (stencil == WebGpuRows.stencilNone()) ()
        else {
            discard desc.depthStencil(TextureFormat.DEPTH24_PLUS_STENCIL8, false, CompareFunction.ALWAYS);
            if (stencil == WebGpuRows.stencilWrite())
                discard desc.stencil(CompareFunction.ALWAYS, StencilOperation.KEEP, StencilOperation.KEEP, StencilOperation.REPLACE, 255, 255)
            else if (stencil == WebGpuRows.stencilEqual())
                discard desc.stencil(CompareFunction.EQUAL, StencilOperation.KEEP, StencilOperation.KEEP, StencilOperation.KEEP, 255, 0)
            else
                discard desc.stencil(CompareFunction.ALWAYS, StencilOperation.KEEP, StencilOperation.KEEP, StencilOperation.KEEP, 255, 0)
        }

    def describeSprite(frameLayout: BindGroupLayout, imageLayout: BindGroupLayout, module: ShaderModule, entry: String,
                       desc: RenderPipelineDesc): Unit \ IO =
        discard desc.bindGroupLayout(frameLayout).bindGroupLayout(imageLayout);
        discard desc.vertex(module, "vs_main").fragment(module, entry);
        discard desc.vertexBuffer(4 * RenderList.instanceFloats(), true);
        discard desc.attribute(VertexFormat.FLOAT32X4, 0, 1).attribute(VertexFormat.FLOAT32X2, 16, 2);
        discard desc.attribute(VertexFormat.FLOAT32X4, 24, 3).attribute(VertexFormat.FLOAT32X4, 40, 4);
        discard desc.attribute(VertexFormat.FLOAT32X4, 56, 5).attribute(VertexFormat.FLOAT32X4, 72, 6);
        discard desc.attribute(VertexFormat.FLOAT32X4, 88, 7).attribute(VertexFormat.FLOAT32X4, 104, 8);
        discard desc.attribute(VertexFormat.FLOAT32X4, 120, 9).attribute(VertexFormat.FLOAT32X4, 136, 10)

    def describePoly(frameLayout: BindGroupLayout, module: ShaderModule, entry: String, desc: RenderPipelineDesc): Unit \ IO =
        discard desc.bindGroupLayout(frameLayout);
        discard desc.vertex(module, "vs_main").fragment(module, entry);
        discard desc.vertexBuffer(4 * RenderList.vertexFloats(), false);
        discard desc.attribute(VertexFormat.FLOAT32X2, 0, 0).attribute(VertexFormat.FLOAT32X4, 8, 1);
        discard desc.vertexBuffer(0, true);
        discard desc.attribute(VertexFormat.FLOAT32X2, 0, 2).attribute(VertexFormat.FLOAT32X2, 8, 3).attribute(VertexFormat.FLOAT32X2, 16, 4)

    def describeTile(frameLayout: BindGroupLayout, imageLayout: BindGroupLayout, module: ShaderModule, desc: RenderPipelineDesc): Unit \ IO =
        discard desc.bindGroupLayout(frameLayout).bindGroupLayout(imageLayout);
        discard desc.vertex(module, "vs_main").fragment(module, "fs_main");
        discard desc.vertexBuffer(4 * TileTable.tileFloats(), true);
        discard desc.attribute(VertexFormat.FLOAT32X2, 0, 1).attribute(VertexFormat.FLOAT32X2, 8, 2).attribute(VertexFormat.FLOAT32X2, 16, 3);
        discard desc.attribute(VertexFormat.FLOAT32, 24, 4).attribute(VertexFormat.FLOAT32X3, 28, 5);
        discard desc.vertexBuffer(0, true);
        discard desc.attribute(VertexFormat.FLOAT32X2, 0, 6).attribute(VertexFormat.FLOAT32, 8, 7);
        discard desc.attribute(VertexFormat.FLOAT32X2, 12, 8).attribute(VertexFormat.FLOAT32X3, 20, 9)

    /// 場面を貼る形: 頂点の buffer を持たない（全面の三角形を頂点の番号で作る）。
    def describeScene(frameLayout: BindGroupLayout, sceneLayout: BindGroupLayout, module: ShaderModule, desc: RenderPipelineDesc): Unit \ IO =
        discard desc.bindGroupLayout(frameLayout).bindGroupLayout(sceneLayout);
        discard desc.vertex(module, "vs_main").fragment(module, "fs_main")

    // ── stencil ──

    /// stencil を 0 に戻す 6 頂点（design の全面を 1 px ずつ外へ広げた矩形・色は白・多角形の頂点の並び）。
    def createResetQuad(gpu: WebGpu, design: (Float64, Float64)): Buffer \ IO =
        let (designW, designH) = design;
        let x0 = -1.0f32;
        let y0 = -1.0f32;
        let x1 = RenderUtil.f32(designW + 1.0);
        let y1 = RenderUtil.f32(designH + 1.0);
        let corners = (x0, y0) :: (x1, y0) :: (x1, y1) :: (x0, y0) :: (x1, y1) :: (x0, y1) :: Nil;
        let bytes = 6 * 4 * RenderList.vertexFloats();
        let data = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN);
        List.forEach(match (x, y) -> {
            discard data.putFloat(x).putFloat(y).putFloat(1.0f32).putFloat(1.0f32).putFloat(1.0f32).putFloat(1.0f32)
        }, corners);
        discard data.flip();
        let buffer = gpu.createBuffer("fge stencil reset", Int32.toInt64(bytes), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST));
        gpu.writeBuffer(buffer, 0i64, data, 0, bytes);
        buffer

    /// 描き先 key の stencil（width × height・標本 samples）。無ければ作り、大きさか標本が違えば作り直す
    /// （古い物は、flush で積んだ pass を submit してから捨てる）。
    pub def stencilOf(pipes: Pipelines, flush: Unit -> Unit \ IO, key: Int32, width: Int32, height: Int32, samples: Int32): Texture \ IO =
        match Map.get(key, Ref.get(pipes#stencils)) {
            case Some((texture, w, h, n)) if w == width and h == height and n == samples => texture
            case old =>
                Option.forEach(e -> { let (t, _, _, _) = e; flush(); t.destroy() }, old);
                let texture = pipes#gpu.createTexture("fge stencil", width, height, TextureFormat.DEPTH24_PLUS_STENCIL8, TextureUsage.RENDER_ATTACHMENT, 1, samples);
                Ref.put(Map.insert(key, (texture, width, height, samples), Ref.get(pipes#stencils)), pipes#stencils);
                texture
        }

    /// 描き先 key の stencil を捨てる（flush で積んだ pass を submit してから）。
    pub def dropStencil(pipes: Pipelines, flush: Unit -> Unit \ IO, key: Int32): Unit \ IO =
        Map.get(key, Ref.get(pipes#stencils)) |> Option.forEach(e -> {
            let (texture, _, _, _) = e;
            flush();
            texture.destroy();
            Ref.put(Map.remove(key, Ref.get(pipes#stencils)), pipes#stencils)
        })
}
