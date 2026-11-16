// Render3d.WebGpuSky — 3D の空の WebGPU の backend（GL の Render3d.drawSky と対）。場面の色の pass の頭で、深度を書かずに描き先いっぱいを空で塗る。
// bind group: 0 = 場面（WebGpuRenderer の group 0。空の 3 色と曲がりを R3dScene から読む）・1 = R3dSky（画素の向きの材料と描き先の大きさ・描き先ごとに 1 つ）。
// WhyNot: 向きの材料を場面の値の buffer（R3dScene）の空き欄に混ぜない — 空いている欄（pad1〜pad4 の 4 つ）では向きの 9 個が入らず、
//   R3dScene の並びを替えると材質と頂点の色の frag の全部の WGSL に波及する。
mod Render3d.WebGpuSky {
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    /// 空の backend の状態。sceneLayout = group 0 の layout（3D の描き手の持ち物）・layout = group 1（R3dSky）の layout・
    /// pipelines = (形式の番号, 標本の数) → pipeline・cpuValues = R3dSky を詰める入れ物。
    pub type alias Sky = {
        gpu = WebGpu, sceneLayout = BindGroupLayout, layout = BindGroupLayout, vertexModule = ShaderModule, fragmentModule = ShaderModule,
        pipelines = Ref[Map[(Int32, Int32), RenderPipeline], Static], cpuValues = ByteBuffer
    }

    /// 描き先 1 つの R3dSky の buffer と group 1。
    pub type alias Binding = { values = Buffer, group = BindGroup }

    /// device の上に shader module と group 1 の layout を作る。sceneLayout = 場面の group 0 の layout（持ち主が手放す）。
    pub def create(gpu: WebGpu, sceneLayout: BindGroupLayout): Sky \ IO =
        let layoutDesc = new BindGroupLayoutDesc("fge scene3d sky");
        discard layoutDesc.buffer(0, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        { gpu = gpu, sceneLayout = sceneLayout, layout = gpu.createBindGroupLayout(layoutDesc),
          vertexModule = gpu.createShaderModule("fge scene3d sky vs", Render3dWgsl.skyVertexSource()),
          fragmentModule = gpu.createShaderModule("fge scene3d sky fs", Render3dWgsl.skyFragmentSource()),
          pipelines = Ref.fresh(Static, Map.empty()),
          cpuValues = ByteBuffer.allocateDirect(Render3dWgsl.skyValueBytes()).order(ByteOrder.LITTLE_ENDIAN) }

    /// device の上に作った物を全部手放す（描き先ごとの Binding は releaseBinding で・sceneLayout は持ち主が）。この後 sky は使えない。
    pub def release(sky: Sky): Unit \ IO =
        Map.forEach((_, p) -> p.release(), Ref.get(sky#pipelines));
        Ref.put(Map.empty(), sky#pipelines);
        sky#vertexModule.release();
        sky#fragmentModule.release();
        sky#layout.release()

    /// 描き先 1 つの R3dSky の buffer と group 1 を作る。
    pub def createBinding(sky: Sky): Binding \ IO =
        let bytes = Int32.toInt64(Render3dWgsl.skyValueBytes());
        let values = sky#gpu.createBuffer("fge scene3d sky", bytes, Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST));
        let desc = new BindGroupDesc("fge scene3d sky", sky#layout);
        discard desc.buffer(0, values, 0i64, bytes);
        { values = values, group = sky#gpu.createBindGroup(desc) }

    pub def releaseBinding(b: Binding): Unit \ IO =
        b#group.release();
        b#values.destroy()

    /// 場面 scene の空の向きの材料（Scene3d.skyBasisOf）と描き先の大きさを b の buffer へ書く。空を描かない場面は書かない。
    pub def writeValues(sky: Sky, b: Binding, scene: Scene3d.Scene3dCmd, width: Int32, height: Int32): Unit \ IO =
        if (not isDrawn(scene)) ()
        else {
            packValues(sky#cpuValues, scene, width, height);
            sky#gpu.writeBuffer(b#values, 0i64, sky#cpuValues, 0, Render3dWgsl.skyValueBytes())
        }

    /// 場面 scene の空の向きの材料と描き先の大きさ width・height を R3dSky の並び（forward・幅・right・高さ・up・pad）で buf へ詰める。
    pub def packValues(buf: ByteBuffer, scene: Scene3d.Scene3dCmd, width: Int32, height: Int32): Unit \ IO =
        let basis = Scene3d.skyBasisOf(scene);
        putVec3(buf, 0, basis#forward);
        discard buf.putFloat(12, Int32.toFloat32(width));
        putVec3(buf, 16, basis#right);
        discard buf.putFloat(28, Int32.toFloat32(height));
        putVec3(buf, 32, basis#up);
        discard buf.putFloat(44, 0.0f32)

    def putVec3(buf: ByteBuffer, at: Int32, v: Vec3.Vec3): Unit \ IO =
        discard buf.putFloat(at, RenderUtil.f32(v#x));
        discard buf.putFloat(at + 4, RenderUtil.f32(v#y));
        discard buf.putFloat(at + 8, RenderUtil.f32(v#z))

    /// 色の pass で空を描く場面か（sky がある場面）。
    // WhyNot: Scene3d.drawnSkyOf で決めない — sky の無い場面でも景色を背景に描くと Some になるが、その場面の空は景色の絵で、環境マップの絵を上げる道がまだ無い。
    pub def isDrawn(scene: Scene3d.Scene3dCmd): Bool = Option.nonEmpty(scene#sky)

    /// 開いた pass p へ空を描く（group 0 は付いている前提・group 1 と pipeline は付け替える）。形式 format・標本 samples は描き先の物。
    pub def draw(sky: Sky, p: RenderPass, format: RenderTarget.Format, samples: Int32, b: Binding): Unit \ IO =
        p.setPipeline(pipelineOf(sky, format, samples));
        p.setBindGroup(1, b#group);
        p.draw(3, 1, 0, 0)

    /// 形式 format・標本 samples の空の pipeline（無ければ作る）。group 0 は場面の layout。
    /// 深度は読まず書かない（GL の drawSky が深度の判定を切って描く）。描き先の pass は深度を持つので、形式だけ合わせる。
    def pipelineOf(sky: Sky, format: RenderTarget.Format, samples: Int32): RenderPipeline \ IO =
        let key = (RenderPaint.Internal.WebGpuPipelines.formatCode(format), samples);
        match Map.get(key, Ref.get(sky#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d sky");
                discard desc.bindGroupLayout(sky#sceneLayout).bindGroupLayout(sky#layout);
                discard desc.vertex(sky#vertexModule, "vs_main").fragment(sky#fragmentModule, "fs_main");
                discard desc.colorTarget(RenderPaint.Internal.WebGpuPipelines.textureFormatOf(format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, false, CompareFunction.ALWAYS).multisample(samples);
                let made = sky#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(sky#pipelines)), sky#pipelines);
                made
        }
}
