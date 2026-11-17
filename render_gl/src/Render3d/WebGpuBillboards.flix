// Render3d.WebGpuBillboards — 3D のビルボードの WebGPU の backend（GL の Render3d.drawBillboards と対）。場面の行（Render3d.SceneList）のビルボードの行を 1 行 1 つ描く。
// bind group は 0 = 場面（WebGpuRenderer の group 0。光・かすみ・奥行きの書き出しの値とカメラの向き）・1 = 貼る絵（2D の描き手の絵の group をそのまま借りる）。
// ビルボードの値は行の values（Render3d.SceneList.billboardValueFloats）を、材質の値の buffer から stride 0 の instance の頂点の buffer 0 として読む。
// WhyNot: ビルボードの絵を材質の絵の表（Render3d.TextureTable3d）へ載せない — 2D の描き手の絵の group は絵と sampler を GL の 2D の絵と同じ組で持ち、
//   借りれば絵ごとの group を作らずに済む（材質の絵の表は段つきの写しと置き場の上限のための物）。
// WhyNot: 値を行ごとの uniform の区画で読まない — 区画ごとに group を作ることになる。頂点の buffer の位置だけを替えれば group は絵の物だけで済む。
mod Render3d.WebGpuBillboards {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.TextureFormat
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    use RenderPaint.Internal.WebGpuPipelines

    /// ビルボードの backend の状態。sceneLayout = group 0 の layout（3D の描き手の持ち物）・imageLayout = group 1 の layout（2D の描き手の絵の group の layout・2D の描き手の持ち物）・
    /// pipelines = (形式の番号, 標本の数) → pipeline。
    /// shadowFragmentModule = 影の地図へ描く frag（Render3dWgsl.billboardShadowFragmentSource）・shadowPipeline = 影の地図の pipeline（初めて要る時に作る）。
    pub type alias Billboards = {
        gpu = WebGpu, sceneLayout = BindGroupLayout, imageLayout = BindGroupLayout, vertexModule = ShaderModule, fragmentModule = ShaderModule,
        pipelines = Ref[Map[(Int32, Int32), RenderPipeline], Static], shadowFragmentModule = ShaderModule, shadowPipeline = Ref[Option[RenderPipeline], Static]
    }

    /// device の上に shader module を作る（layout 2 つは持ち主が手放す）。
    pub def create(gpu: WebGpu, sceneLayout: BindGroupLayout, imageLayout: BindGroupLayout): Billboards \ IO =
        { gpu = gpu, sceneLayout = sceneLayout, imageLayout = imageLayout,
          vertexModule = gpu.createShaderModule("fge scene3d billboard vs", Render3dWgsl.billboardVertexSource()),
          fragmentModule = gpu.createShaderModule("fge scene3d billboard fs", Render3dWgsl.billboardFragmentSource()),
          pipelines = Ref.fresh(Static, Map.empty()),
          shadowFragmentModule = gpu.createShaderModule("fge scene3d billboard shadow fs", Render3dWgsl.billboardShadowFragmentSource()),
          shadowPipeline = Ref.fresh(Static, None) }

    /// device の上に作った物を全部手放す（layout は持ち主が）。この後 b は使えない。
    pub def release(b: Billboards): Unit \ IO =
        Map.forEach((_, p) -> p.release(), Ref.get(b#pipelines));
        Ref.put(Map.empty(), b#pipelines);
        Ref.get(b#shadowPipeline) |> Option.forEach(p -> p.release());
        Ref.put(None, b#shadowPipeline);
        b#vertexModule.release();
        b#fragmentModule.release();
        b#shadowFragmentModule.release()

    /// ビルボードを影の地図へ描く pipeline（無ければ作る）。group 0 = 影の地図の光の目（shadowLayout・Render3d.WebGpuShadows の持ち物）・group 1 = 貼る絵。
    /// 色の描き先を持たず、深度（depthFormat）を LESS で書く。裏を間引かない（GL の影の地図と同じ）。
    pub def shadowPipelineOf(b: Billboards, shadowLayout: BindGroupLayout, depthFormat: TextureFormat): RenderPipeline \ IO =
        match Ref.get(b#shadowPipeline) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d billboard shadow");
                discard desc.bindGroupLayout(shadowLayout).bindGroupLayout(b#imageLayout);
                discard desc.vertex(b#vertexModule, "vs_main").fragment(b#shadowFragmentModule, "fs_main");
                discard desc.vertexBuffer(0, true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 0).attribute(VertexFormat.FLOAT32X4, 16, 1);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 2).attribute(VertexFormat.FLOAT32X4, 48, 3);
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(depthFormat, true, CompareFunction.LESS).multisample(1);
                let made = b#gpu.createRenderPipeline(desc);
                Ref.put(Some(made), b#shadowPipeline);
                made
        }

    /// 形式 format・標本 samples のビルボードの pipeline（無ければ作る）。裏を間引かず（四角はいつもカメラを向く）、深度は LESS で書く（GL のビルボードと同じく不透明の物の後・半透明の物の前に描く）。
    /// 奥行きの書き出しの pass も同じ pipeline で、frag が場面の値の uDepthOut で灰色を書く。
    pub def pipelineOf(b: Billboards, format: RenderTarget.Format, samples: Int32): RenderPipeline \ IO =
        let key = (WebGpuPipelines.formatCode(format), samples);
        match Map.get(key, Ref.get(b#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d billboard");
                discard desc.bindGroupLayout(b#sceneLayout).bindGroupLayout(b#imageLayout);
                discard desc.vertex(b#vertexModule, "vs_main").fragment(b#fragmentModule, "fs_main");
                discard desc.vertexBuffer(0, true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 0).attribute(VertexFormat.FLOAT32X4, 16, 1);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 2).attribute(VertexFormat.FLOAT32X4, 48, 3);
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, true, CompareFunction.LESS).multisample(samples);
                let made = b#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(b#pipelines)), b#pipelines);
                made
        }

    /// ビルボードの値 1 つのバイト数（頂点の buffer 0 に渡す大きさ）。
    pub def valueBytes(): Int64 = Int32.toInt64(4 * Render3d.SceneList.billboardValueFloats())
}
