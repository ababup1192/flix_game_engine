// Render3d.WebGpuBillboards — 3D のビルボードの WebGPU の backend（GL の Render3d.drawBillboards と対）。場面の行（Render3d.SceneList）のビルボードの行（同じ絵の板の並び）を
// 1 行 1 回の instanced draw で描く。
// bind group は 0 = 場面（WebGpuRenderer の group 0。光・かすみ・奥行きの書き出しの値とカメラの向き）・1 = 貼る絵（2D の描き手の絵の group をそのまま借りる）。
// ビルボードの値は行の values（Render3d.SceneList.billboardValueFloats）を、材質の値の buffer から instance ごとの頂点の buffer 0（stride = 値 1 つ）として読む。
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
    /// pipelines = BillboardPipelineKey → pipeline・variantModules = 変種の鍵（Render3d.variantKeyOf(billboardVariantOf(..))）→ その頂点シェーダーと frag（初めて要る時に作る）。
    /// shadowFragmentModule = 影の地図へ描く frag（Render3dWgsl.billboardShadowFragmentSource）・shadowPipeline = 影の地図の pipeline（初めて要る時に作る）・
    /// rowRightVertexModule と rowRightShadowPipeline = 板の横の向きを行の値から読む頂点シェーダーと、その影の地図の pipeline（点光源の面・初めて要る時に作る）。
    pub type alias Billboards = {
        gpu = WebGpu, sceneLayout = BindGroupLayout, imageLayout = BindGroupLayout, vertexModule = ShaderModule, fragmentModule = ShaderModule,
        variantModules = Ref[Map[String, (ShaderModule, ShaderModule)], Static],
        pipelines = Ref[Map[BillboardPipelineSlot, RenderPipeline], Static], shadowFragmentModule = ShaderModule, shadowPipeline = Ref[Option[RenderPipeline], Static],
        rowRightVertexModule = Ref[Option[ShaderModule], Static], rowRightShadowPipeline = Ref[Option[RenderPipeline], Static]
    }

    /// device の上に shader module を作る（layout 2 つは持ち主が手放す）。
    pub def create(gpu: WebGpu, sceneLayout: BindGroupLayout, imageLayout: BindGroupLayout): Billboards \ IO =
        { gpu = gpu, sceneLayout = sceneLayout, imageLayout = imageLayout,
          vertexModule = gpu.createShaderModule("fge scene3d billboard vs", Render3dWgsl.billboardVertexSource()),
          fragmentModule = gpu.createShaderModule("fge scene3d billboard fs", Render3dWgsl.billboardFragmentSource()),
          variantModules = Ref.fresh(Static, Map.empty()),
          pipelines = Ref.fresh(Static, Map.empty()),
          shadowFragmentModule = gpu.createShaderModule("fge scene3d billboard shadow fs", Render3dWgsl.billboardShadowFragmentSource()),
          shadowPipeline = Ref.fresh(Static, None), rowRightVertexModule = Ref.fresh(Static, None), rowRightShadowPipeline = Ref.fresh(Static, None) }

    /// device の上に作った物を全部手放す（layout は持ち主が）。この後 b は使えない。
    pub def release(b: Billboards): Unit \ IO =
        Map.forEach((_, p) -> p.release(), Ref.get(b#pipelines));
        Ref.put(Map.empty(), b#pipelines);
        Ref.get(b#shadowPipeline) |> Option.forEach(p -> p.release());
        Ref.put(None, b#shadowPipeline);
        Ref.get(b#rowRightShadowPipeline) |> Option.forEach(p -> p.release());
        Ref.put(None, b#rowRightShadowPipeline);
        Ref.get(b#rowRightVertexModule) |> Option.forEach(m -> m.release());
        Ref.put(None, b#rowRightVertexModule);
        b#vertexModule.release();
        b#fragmentModule.release();
        Map.forEach((_, vf) -> { let (vm, fm) = vf; vm.release(); fm.release() }, Ref.get(b#variantModules));
        Ref.put(Map.empty(), b#variantModules);
        b#shadowFragmentModule.release()

    /// ビルボードを影の地図へ描く pipeline（無ければ作る）。group 0 = 影の地図の光の目（shadowLayout・Render3d.WebGpuShadows の持ち物）・group 1 = 貼る絵。
    /// 色の描き先を持たず、深度（depthFormat）を LESS で書く。裏を間引かない（GL の影の地図と同じ）。
    /// rightPerBillboard なら板の横の向きを行の値の tint の rgb から読む頂点シェーダーの版（点光源の面・Render3d.SceneList.putBillboardValues）。
    pub def shadowPipelineOf(b: Billboards, shadowLayout: BindGroupLayout, depthFormat: TextureFormat, rightPerBillboard: Bool): RenderPipeline \ IO =
        let held = if (rightPerBillboard) b#rowRightShadowPipeline else b#shadowPipeline;
        match Ref.get(held) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d billboard shadow");
                discard desc.bindGroupLayout(shadowLayout).bindGroupLayout(b#imageLayout);
                discard desc.vertex(if (rightPerBillboard) rowRightVertexModuleOf(b) else b#vertexModule, "vs_main").fragment(b#shadowFragmentModule, "fs_main");
                discard desc.vertexBuffer(valueStride(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 0).attribute(VertexFormat.FLOAT32X4, 16, 1);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 2).attribute(VertexFormat.FLOAT32X4, 48, 3);
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(depthFormat, true, CompareFunction.LESS).multisample(1);
                let made = b#gpu.createRenderPipeline(desc);
                Ref.put(Some(made), held);
                made
        }

    def rowRightVertexModuleOf(b: Billboards): ShaderModule \ IO = match Ref.get(b#rowRightVertexModule) {
        case Some(m) => m
        case None    =>
            let made = b#gpu.createShaderModule("fge scene3d billboard vs row right", Render3dWgsl.billboardRowRightVertexSource());
            Ref.put(Some(made), b#rowRightVertexModule);
            made
    }

    /// ビルボードの pipeline の鍵。format = 描き先の形式の番号・samples = 標本の数・sceneLayout = 場面の group 0 の形の番号・variant = ビルボードの変種の鍵。
    type alias BillboardPipelineKey = { format = Int32, samples = Int32, sceneLayout = Int32, variant = String }

    // WhyNot: レコードを Map の鍵に直に使わない — レコードは Order を持てない。並べ方は billboardPipelineSlotOf の 1 か所だけにして、呼ぶ側は欄の名前で書く。
    enum BillboardPipelineSlot with Eq, Order {
        case BillboardPipelineSlot(Int32, Int32, Int32, String)
    }

    def billboardPipelineSlotOf(k: BillboardPipelineKey): BillboardPipelineSlot =
        BillboardPipelineSlot.BillboardPipelineSlot(k#format, k#samples, k#sceneLayout, k#variant)

    /// 形式 format・標本 samples・場面の変種 variant のビルボードの pipeline（無ければ作る）。裏を間引かず（四角はいつもカメラを向く）、深度は LESS で書く
    /// （GL のビルボードと同じく不透明の物の後・半透明の物の前に描く）。奥行きの書き出しの pass も同じ pipeline で、frag が場面の値の uDepthOut で灰色を書く。
    /// group0 = 場面の group 0 の (形の番号, layout)。frag は Render3d.billboardVariantOf(variant) の字（点光源の影は受けない）。
    pub def pipelineOf(b: Billboards, format: RenderTarget.Format, samples: Int32, variant: Render3d.ShaderVariant, group0: (Int32, BindGroupLayout)): RenderPipeline \ IO =
        let (code, layout) = group0;
        let key = billboardPipelineSlotOf({ format = WebGpuPipelines.formatCode(format), samples = samples, sceneLayout = code, variant = Render3d.variantKeyOf(Render3d.billboardVariantOf(variant)) });
        match Map.get(key, Ref.get(b#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d billboard");
                discard desc.bindGroupLayout(layout).bindGroupLayout(b#imageLayout);
                let (vertex, fragment) = modulesOf(b, variant);
                discard desc.vertex(vertex, "vs_main").fragment(fragment, "fs_main");
                discard desc.vertexBuffer(valueStride(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 0).attribute(VertexFormat.FLOAT32X4, 16, 1);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 2).attribute(VertexFormat.FLOAT32X4, 48, 3);
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, true, CompareFunction.LESS).multisample(samples);
                let made = b#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(b#pipelines)), b#pipelines);
                made
        }

    /// 変種 variant のビルボードの頂点シェーダーと frag（既定でない変種の版は初めて要る時に作る）。
    def modulesOf(b: Billboards, variant: Render3d.ShaderVariant): (ShaderModule, ShaderModule) \ IO =
        let bv = Render3d.billboardVariantOf(variant);
        let key = Render3d.variantKeyOf(bv);
        if (key == "") (b#vertexModule, b#fragmentModule)
        else match Map.get(key, Ref.get(b#variantModules)) {
            case Some(vf) => vf
            case None     =>
                // WhyNot: +pu だけの時に b#vertexModule を使い回さない — release は変種の表の頂点シェーダーも離すので、共有すると既定の物を 2 回離す。
                let vertex = if (bv#psx) b#gpu.createShaderModule("fge scene3d billboard vs" + key, Render3dWgsl.billboardVertexSourceFor(bv))
                             else b#gpu.createShaderModule("fge scene3d billboard vs" + key, Render3dWgsl.billboardVertexSource());
                let made = (vertex, b#gpu.createShaderModule("fge scene3d billboard fs" + key, Render3dWgsl.billboardFragmentSourceFor(variant)));
                Ref.put(Map.insert(key, made, Ref.get(b#variantModules)), b#variantModules);
                made
        }

    /// ビルボードの値 1 つのバイト数（頂点の buffer 0 に渡す大きさ）。
    pub def valueBytes(): Int64 = Int32.toInt64(valueStride())

    /// 頂点の buffer 0 の instance 1 つ分の stride（バイト）。
    def valueStride(): Int32 = 4 * Render3d.SceneList.billboardValueFloats()
}
