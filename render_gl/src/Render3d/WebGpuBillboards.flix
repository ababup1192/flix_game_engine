// Render3d.WebGpuBillboards — 3D のビルボードの WebGPU の backend（GL の Render3d.drawBillboards と対）。場面の行（Render3d.SceneList）のビルボードの行を 1 行 1 つ描く。
// bind group は 0 = 場面（WebGpuRenderer の group 0。光・かすみ・奥行きの書き出しの値とカメラの向き）・1 = 貼る絵（2D の描き手の絵の group をそのまま借りる）。
// ビルボードの値は行の values（Render3d.SceneList.billboardValueFloats）を、材質の値の buffer から stride 0 の instance の頂点の buffer 0 として読む。
// WhyNot: ビルボードの絵を材質の絵の表（Render3d.TextureTable3d）へ載せない — 2D の描き手の絵の group は絵と sampler を GL の 2D の絵と同じ組で持ち、
//   借りれば絵ごとの group を作らずに済む（材質の絵の表は段つきの写しと置き場の上限のための物）。
// WhyNot: 値を行ごとの uniform の区画で読まない — 区画ごとに group を作ることになる。2D の行の値（12.18）と同じく頂点の buffer の位置だけを替える。
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
    pub type alias Billboards = {
        gpu = WebGpu, sceneLayout = BindGroupLayout, imageLayout = BindGroupLayout, vertexModule = ShaderModule, fragmentModule = ShaderModule,
        pipelines = Ref[Map[(Int32, Int32), RenderPipeline], Static]
    }

    /// device の上に shader module を作る（layout 2 つは持ち主が手放す）。
    pub def create(gpu: WebGpu, sceneLayout: BindGroupLayout, imageLayout: BindGroupLayout): Billboards \ IO =
        { gpu = gpu, sceneLayout = sceneLayout, imageLayout = imageLayout,
          vertexModule = gpu.createShaderModule("fge scene3d billboard vs", Render3dWgsl.billboardVertexSource()),
          fragmentModule = gpu.createShaderModule("fge scene3d billboard fs", Render3dWgsl.billboardFragmentSource()),
          pipelines = Ref.fresh(Static, Map.empty()) }

    /// device の上に作った物を全部手放す（layout は持ち主が）。この後 b は使えない。
    pub def release(b: Billboards): Unit \ IO =
        Map.forEach((_, p) -> p.release(), Ref.get(b#pipelines));
        Ref.put(Map.empty(), b#pipelines);
        b#vertexModule.release();
        b#fragmentModule.release()

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
