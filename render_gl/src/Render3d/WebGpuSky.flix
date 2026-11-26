// Render3d.WebGpuSky — 3D の空の WebGPU の backend（GL の Render3d.drawSky と対）。場面の色の pass の頭で、深度を書かずに描き先いっぱいを空で塗る。
// bind group は 0 = 場面だけ（WebGpuRenderer の group 0）。空の 3 色と曲がりと画素の向きの材料を R3dScene から読む（Render3dWgsl.skyFragmentSource）。
mod Render3d.WebGpuSky {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.TextureFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer

    /// 空の backend の状態。sceneLayout = group 0 の layout（3D の描き手の持ち物）・pipelines = SkyPipelineKey → pipeline。
    pub type alias Sky = {
        gpu = WebGpu, sceneLayout = BindGroupLayout, vertexModule = ShaderModule, fragmentModule = ShaderModule,
        pipelines = Ref[Map[SkyPipelineSlot, RenderPipeline], Static]
    }

    /// device の上に shader module を作る。sceneLayout = 場面の group 0 の layout（持ち主が手放す）・shaders = 字を引く API。
    pub def create(gpu: WebGpu, sceneLayout: BindGroupLayout, shaders: Render3d.ShaderLibrary.ShaderSources): Sky \ IO =
        { gpu = gpu, sceneLayout = sceneLayout,
          vertexModule = gpu.createShaderModule("fge scene3d sky vs", Render3d.ShaderLibrary.wgslOrBug(shaders, Render3d.ShaderSourceKey.SkyVertex)),
          fragmentModule = gpu.createShaderModule("fge scene3d sky fs", Render3d.ShaderLibrary.wgslOrBug(shaders, Render3d.ShaderSourceKey.SkyFragment)),
          pipelines = Ref.fresh(Static, Map.empty()) }

    /// device の上に作った物を全部手放す（sceneLayout は持ち主が）。この後 sky は使えない。
    pub def release(sky: Sky): Unit \ IO =
        Map.forEach((_, p) -> p.release(), Ref.get(sky#pipelines));
        Ref.put(Map.empty(), sky#pipelines);
        sky#vertexModule.release();
        sky#fragmentModule.release()

    /// 場面 scene の空の向きの材料（Scene3d.skyBasisOf）と描き先の大きさ width・height を、R3dScene の末尾の uSkyForward・uSkyRight・uSkyUp の並び
    /// （xyz に forward・right・up、w に幅・高さ・景色を背景に描くかのフラグ（Scene3d.backgroundEnvironmentOf が Some なら 1））で buf へ詰める（位置は Render3d.UniformLayout の表）。
    // WhyNot: 景色を背景に描くかを R3dScene の uEnvOn で見ない — uEnvOn は環境マップがあれば立ち（材質の映り込み）、sky と背景の景色が両方ある場面は空の坂を描く。
    // WhyNot: 空の無い場面で詰めるのを飛ばさない — buf は場面をまたいで使い回し、書く欄の組を場面ごとに変えない（Render3d.WebGpuSceneValues.packSceneValues と同じ決まり）。
    /// o = R3dScene の欄の位置（Render3d.UniformLayout.sceneOffsets）。
    pub def packValues(buf: ByteBuffer, o: Map[Render3d.UniformLayout.SceneField, Int32], scene: Scene3d.Scene3dCmd, width: Int32, height: Int32): Unit \ IO =
        let at = f -> Render3d.UniformLayout.offsetOf(o, f);
        let basis = Scene3d.skyBasisOf(scene);
        putVec3(buf, at(Render3d.UniformLayout.SceneField.SkyForward), basis#forward);
        Render3d.WebGpuSceneValues.putFloatAt(buf, at(Render3d.UniformLayout.SceneField.SkyForward), 3, Int32.toFloat32(width));
        putVec3(buf, at(Render3d.UniformLayout.SceneField.SkyRight), basis#right);
        Render3d.WebGpuSceneValues.putFloatAt(buf, at(Render3d.UniformLayout.SceneField.SkyRight), 3, Int32.toFloat32(height));
        putVec3(buf, at(Render3d.UniformLayout.SceneField.SkyUp), basis#up);
        Render3d.WebGpuSceneValues.putFloatAt(buf, at(Render3d.UniformLayout.SceneField.SkyUp), 3,
                                              if (Option.isEmpty(Scene3d.backgroundEnvironmentOf(scene))) 0.0f32 else 1.0f32)

    def putVec3(buf: ByteBuffer, at: Int32, v: Vec3.Vec3): Unit \ IO =
        discard buf.putFloat(at, RenderUtil.f32(v#x));
        discard buf.putFloat(at + 4, RenderUtil.f32(v#y));
        discard buf.putFloat(at + 8, RenderUtil.f32(v#z))

    /// 色の pass で空を描く場面か（sky がある場面と、sky が無く景色を背景に描く場面。GL の Render3d.drawSky と同じ Scene3d.drawnSkyOf）。
    pub def isDrawn(scene: Scene3d.Scene3dCmd): Bool = Option.nonEmpty(Scene3d.drawnSkyOf(scene))

    /// 開いた pass p へ空を描く（group 0 は付いている前提・pipeline は付け替える）。形式 format・標本 samples は描き先の物・
    /// group0 = 場面の group 0 の (形の番号, layout)（変種の場面は R3dLight を足した layout。空の frag は読まない）。
    pub def draw(sky: Sky, p: RenderPass, format: RenderTarget.Format, samples: Int32, group0: (Int32, BindGroupLayout)): Unit \ IO =
        p.setPipeline(pipelineOf(sky, format, samples, group0));
        p.draw(3, 1, 0, 0)

    /// 空の pipeline の鍵。format = 描き先の形式の番号・samples = 標本の数・sceneLayout = 場面の group 0 の形の番号。
    type alias SkyPipelineKey = { format = Int32, samples = Int32, sceneLayout = Int32 }

    // WhyNot: レコードを Map の鍵に直に使わない — レコードは Order を持てない。並べ方は skyPipelineSlotOf の 1 か所だけにして、呼ぶ側は欄の名前で書く。
    enum SkyPipelineSlot with Eq, Order {
        case SkyPipelineSlot(Int32, Int32, Int32)
    }

    def skyPipelineSlotOf(k: SkyPipelineKey): SkyPipelineSlot = SkyPipelineSlot.SkyPipelineSlot(k#format, k#samples, k#sceneLayout)

    /// 形式 format・標本 samples・場面の group 0 の空の pipeline（無ければ作る）。
    /// 深度は読まず書かない（GL の drawSky が深度の判定を切って描く）。描き先の pass は深度を持つので、形式だけ合わせる。
    // WhyNot: 変種の場面でも既定の layout で作らない — pass の頭で付けた group 0 は変種の layout で、layout の違う pipeline へは付けられない。
    def pipelineOf(sky: Sky, format: RenderTarget.Format, samples: Int32, group0: (Int32, BindGroupLayout)): RenderPipeline \ IO =
        let (code, layout) = group0;
        let key = skyPipelineSlotOf({ format = RenderPaint.Internal.WebGpuPipelines.formatCode(format), samples = samples, sceneLayout = code });
        match Map.get(key, Ref.get(sky#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d sky");
                discard desc.bindGroupLayout(layout);
                discard desc.vertex(sky#vertexModule, "vs_main").fragment(sky#fragmentModule, "fs_main");
                discard desc.colorTarget(RenderPaint.Internal.WebGpuPipelines.textureFormatOf(format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, false, CompareFunction.ALWAYS).multisample(samples);
                let made = sky#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(sky#pipelines)), sky#pipelines);
                made
        }
}
