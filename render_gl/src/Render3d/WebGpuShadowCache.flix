// Render3d.WebGpuShadowCache — 影の地図に動かない物（staticGroup の持ち越した行）だけを描いた深度の控え（WebGPU の backend。GL は Render3d.GlShadowCache）。
// 控えは地図 1 枚（太陽・スポット）か atlas の面 1 つ（点光源）の大きさの深度の texture で、鍵（Render3d.ShadowMaps.cacheKeyOf）が同じなら描き直さない。
// 毎コマ、影の地図の pass の頭で控えを写し（copy）、その上に動く物だけを描く。深度は小さい方が残るので、全部を 1 回で描いた地図と同じ値になる。
// 写すのは「控えを読んで frag_depth を書く三角形 1 枚」（深度の比べは always）。
// WhyNot: copyTextureToTexture で写さない — 深度の写しは subresource まるごとしか写せず atlas の面へ写せない。WebGpu の interface に足すと GL の層の jar とブラウザの実装も動く。
// WhyNot: 控えを色の pass に直に読ませない — 影の地図を含む group 0 が替わり、持ち越した bundle（Render3d.WebGpuStatic）を積み直す。
mod Render3d.WebGpuShadowCache {
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
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.ShadowCacheTable

    /// 控え 1 つ。depth = 動かない物だけの深度・size = 一辺の画素・origin = 写す先の原点を書く buffer・group = 写す三角形の group 0。
    pub type alias Entry = { depth = Texture, size = Int32, origin = Buffer, group = BindGroup }

    /// 状態。table = 鍵 → 控えの表と描き直しの数え（Render3d.ShadowCacheTable）・retired = コマを締めた後に手放す控え・
    /// layout・pipeline = 写す三角形の物（初めて写す時に作る）・cpuOrigin = 原点を詰める入れ物。
    pub type alias Cache = {
        gpu = WebGpu, table = ShadowCacheTable.Table[Entry], retired = Ref[List[Entry], Static],
        layout = BindGroupLayout, module = ShaderModule, pipeline = Ref[Option[RenderPipeline], Static], cpuOrigin = ByteBuffer
    }

    pub def create(gpu: WebGpu): Cache \ IO =
        let layoutDesc = new BindGroupLayoutDesc("fge scene3d shadow cache");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.DEPTH).buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        { gpu = gpu, table = ShadowCacheTable.fresh(), retired = Ref.fresh(Static, Nil),
          layout = gpu.createBindGroupLayout(layoutDesc), module = gpu.createShaderModule("fge scene3d shadow cache", copyWgsl()),
          pipeline = Ref.fresh(Static, None), cpuOrigin = ByteBuffer.allocateDirect(16).order(ByteOrder.LITTLE_ENDIAN) }

    /// 写す三角形の WGSL。描き先の画素の位置から原点を引いた所の控えの深度を、そのまま frag_depth に書く。
    def copyWgsl(): String =
        "struct Origin { at: vec4f };\n" +
        "@group(0) @binding(0) var cached: texture_depth_2d;\n" +
        "@group(0) @binding(1) var<uniform> origin: Origin;\n" +
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    var c = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));\n" +
        "    return vec4f(c[i], 0.0, 1.0);\n" +
        "}\n" +
        "@fragment fn fs_main(@builtin(position) p: vec4f) -> @builtin(frag_depth) f32 {\n" +
        "    return textureLoad(cached, vec2i(p.xy - origin.at.xy), 0);\n" +
        "}\n"

    /// 鍵 key・一辺 size の控え（無ければ作る）と、今作ったか。作った控えは中身が無いので、呼ぶ側が動かない物を描く。
    pub def ensure(c: Cache, gen: Int64, key: String, size: Int32, depthFormat: TextureFormat): (Entry, Bool) \ IO =
        ShadowCacheTable.ensure(c#table, gen, key, () -> createEntry(c, size, depthFormat))

    /// 控え e の深度の texture（動かない物を描く pass の描き先）。
    pub def depthOf(e: Entry): Texture = e#depth

    def createEntry(c: Cache, size: Int32, depthFormat: TextureFormat): Entry \ IO =
        let depth = c#gpu.createTexture("fge scene3d shadow cache", size, size, depthFormat, Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.TEXTURE_BINDING), 1, 1);
        let origin = c#gpu.createBuffer("fge scene3d shadow cache origin", 16i64, Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST));
        let desc = new BindGroupDesc("fge scene3d shadow cache", c#layout);
        discard desc.textureView(0, depth.defaultView()).buffer(1, origin, 0i64, 16i64);
        { depth = depth, size = size, origin = origin, group = c#gpu.createBindGroup(desc) }

    /// 開いている影の地図の pass rp の、今の viewport（原点 (x, y)・WebGPU の左上が原点）へ控え e を写す。pass の group 0 と pipeline は付け直す事。
    pub def copyInto(c: Cache, e: Entry, rp: RenderPass, x: Int32, y: Int32, depthFormat: TextureFormat): Unit \ IO =
        discard c#cpuOrigin.putFloat(0, Int32.toFloat32(x)).putFloat(4, Int32.toFloat32(y)).putFloat(8, 0.0f32).putFloat(12, 0.0f32);
        c#gpu.writeBuffer(e#origin, 0i64, c#cpuOrigin, 0, 16);
        rp.setPipeline(pipelineOf(c, depthFormat));
        rp.setBindGroup(0, e#group);
        rp.draw(3, 1, 0, 0)

    def pipelineOf(c: Cache, depthFormat: TextureFormat): RenderPipeline \ IO =
        match Ref.get(c#pipeline) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d shadow cache");
                discard desc.bindGroupLayout(c#layout).vertex(c#module, "vs_main").fragment(c#module, "fs_main");
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CCW, CullMode.NONE);
                discard desc.depthStencil(depthFormat, true, CompareFunction.ALWAYS).multisample(1);
                let made = c#gpu.createRenderPipeline(desc);
                Ref.put(Some(made), c#pipeline);
                made
        }

    /// 画面のコマを submit した後に 1 回: 前のコマで手放すと決めた控えを手放し、残す数（Render3d.ShadowCacheTable.endFrame）を超える控えを、古く使った物から手放す物に回す。
    // WhyNot: 超えた控えをその場で手放さない — 同じコマの後の場面の pass がまだ submit されずに読んでいる事がある（Render3d.WebGpuStatic と同じ）。
    pub def endFrame(c: Cache): Unit \ IO =
        Ref.get(c#retired) |> List.forEach(destroyEntry);
        Ref.put(ShadowCacheTable.endFrame(c#table), c#retired)

    def destroyEntry(e: Entry): Unit \ IO =
        e#group.release();
        e#origin.destroy();
        e#depth.destroy()

    /// 控えの数（テストと診断）。
    pub def sizeOf(c: Cache): Int32 \ IO = ShadowCacheTable.sizeOf(c#table)

    /// 全部を手放す（描き手を手放す時。encoder は submit 済み）。
    pub def release(c: Cache): Unit \ IO =
        Ref.get(c#retired) |> List.forEach(destroyEntry);
        Ref.put(Nil, c#retired);
        ShadowCacheTable.takeAll(c#table) |> List.forEach(destroyEntry);
        Ref.get(c#pipeline) |> Option.forEach(p -> p.release());
        c#module.release();
        c#layout.release()
}
