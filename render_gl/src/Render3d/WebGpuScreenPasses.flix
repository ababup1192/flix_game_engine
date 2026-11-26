// Render3d.WebGpuScreenPasses — WebGPU の 3D の描き手の中の、画面の上の pass（Render3d.ScreenPasses の表）を描く。影の地図の pass の後・色の pass の前に、
// 奥行きの Pass（Scene3d.ScreenInputsFields#depth）から R8 の絵 2 枚へ mask → 横 → 縦を全部の画面の三角形で描く render pass を積む。
// mask の絵は描き先の鍵ごとに持ち、大きさが変わった時だけ作り直す（場面の group 0 が mask の view を持つので、毎コマ作り直すと staticGroup の bundle を毎コマ積み直す）。
pub mod Render3d.WebGpuScreenPasses {
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.TextureView
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.ScreenPasses.{ScreenPass, ScreenPassKind}

    /// 描き先 1 つの mask の絵 2 枚と大きさ（a が仕上がり）。values = SsaoValues の buffer（pass ごとに 1 つ・dir と target が違う）。
    pub type alias Masks = { width = Int32, height = Int32, a = Texture, b = Texture, values = Vector[Buffer] }

    /// 描き手が持つ物。layout = group 0（SsaoValues・奥行きの絵・mask）・modules = 種類ごとの shader module（ぼかしは 1 つ）・
    /// pipelines = (種類, 描き先の形式の番号) → pipeline・masks = 描き先の鍵 → mask の絵・cpu = SsaoValues を詰める入れ物・
    /// blankMask = mask を読まない pass の代わりの絵。
    pub type alias ScreenPasses = {
        gpu = WebGpu, layout = BindGroupLayout, vertexModule = ShaderModule, modules = Ref[Map[String, ShaderModule], Static],
        pipelines = Ref[Map[String, RenderPipeline], Static], masks = Ref[Map[(Int32, Int32), Masks], Static], cpu = ByteBuffer, blankMask = Texture,
        groups = Ref[List[BindGroup], Static]
    }

    /// device の上に layout と vertex を作った空の表。
    pub def create(gpu: WebGpu): ScreenPasses \ IO =
        let desc = new BindGroupLayoutDesc("fge scene3d screen passes");
        discard desc.buffer(0, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        discard desc.texture(1, ShaderStage.FRAGMENT, TextureSampleType.UNFILTERABLE_FLOAT).texture(2, ShaderStage.FRAGMENT, TextureSampleType.FLOAT);
        let blank = gpu.createTexture("fge scene3d screen blank", 1, 1, TextureFormat.R8_UNORM, Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        { gpu = gpu, layout = gpu.createBindGroupLayout(desc),
          vertexModule = gpu.createShaderModule("fge scene3d screen vs", ShaderAst.Wgsl.vertex(Render3d.ScreenPasses.vertex())),
          modules = Ref.fresh(Static, Map.empty()), pipelines = Ref.fresh(Static, Map.empty()), masks = Ref.fresh(Static, Map.empty()),
          cpu = ByteBuffer.allocateDirect(Render3d.ScreenPasses.valueBytes()).order(ByteOrder.LITTLE_ENDIAN), blankMask = blank,
          groups = Ref.fresh(Static, Nil) }

    /// 描き先の鍵 key・場面の描き先の大きさ width × height の mask の絵（大きさが違えば作り直す）。
    def masksOf(sp: ScreenPasses, key: (Int32, Int32), width: Int32, height: Int32): Masks \ IO =
        match Map.get(key, Ref.get(sp#masks)) {
            case Some(m) if m#width == width and m#height == height => m
            case old =>
                old |> Option.forEach(destroyMasks);
                let usage = Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.TEXTURE_BINDING);
                let made = { width = width, height = height,
                             a = sp#gpu.createTexture("fge scene3d ao a", width, height, targetFormatOf(Render3d.ScreenPasses.ScreenTargetFormat.R8), usage, 1, 1),
                             b = sp#gpu.createTexture("fge scene3d ao b", width, height, targetFormatOf(Render3d.ScreenPasses.ScreenTargetFormat.R8), usage, 1, 1),
                             values = Vector.range(0, 4) |> Vector.map(_ -> sp#gpu.createBuffer("fge scene3d ao values", Int32.toInt64(Render3d.ScreenPasses.valueBytes()),
                                                                                                 Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST))) };
                Ref.put(Map.insert(key, made, Ref.get(sp#masks)), sp#masks);
                made
        }

    /// 内側の絵の形式の WebGPU の形式。
    def targetFormatOf(f: Render3d.ScreenPasses.ScreenTargetFormat): TextureFormat = match f {
        case Render3d.ScreenPasses.ScreenTargetFormat.R8 => TextureFormat.R8_UNORM
    }

    def destroyMasks(m: Masks): Unit \ IO =
        m#a.destroy();
        m#b.destroy();
        m#values |> Vector.forEach(b -> b.destroy())

    /// mask の仕上がりの絵の view（描き先の鍵 key の物が無ければ代わりの絵）。
    pub def maskViewOf(sp: ScreenPasses, key: (Int32, Int32)): TextureView \ IO =
        Map.get(key, Ref.get(sp#masks)) |> Option.map(m -> m#a.defaultView()) |> Option.getWithDefault(sp#blankMask.defaultView())

    /// 場面 scene の mask の pass を encoder に積む（技が無い・奥行きの Pass が無い場面は何もしない）。key = 描き先の鍵・rect = 場面の矩形（GL の左下が原点・奥行きの Pass の中）・
    /// size = 場面の描き先の大きさ・depth = 奥行きの Pass の texture。
    pub def encodeMask(sp: ScreenPasses, host: Render3d.WebGpuRenderer.Host, key: (Int32, Int32), rect: (Int32, Int32, Int32, Int32), size: (Int32, Int32),
                       depth: Texture, scene: Scene3d.Scene3dCmd): Unit \ IO =
        match Render3d.ScreenPasses.ambientOcclusionOf(scene) {
            case None              => ()
            case Some((inputs, ao)) =>
                let (sw, sh) = size;
                let (mw, mh) = ScreenEffects3d.maskSizeOf(ao, sw, sh);
                let masks = masksOf(sp, key, mw, mh);
                let values = Render3d.ScreenPasses.valuesOf(scene, inputs, ao, rect);
                let target = (0.0f32, 0.0f32, Int32.toFloat32(mw), Int32.toFloat32(mh));
                let scaled = Render3d.ScreenPasses.passesOf(inputs) |> List.filter(p -> p#scaled);
                List.zipWithIndex(scaled) |> List.forEach(ip -> {
                    let (i, p) = ip;
                    let (drawTo, readFrom) = match p#kind {
                        case ScreenPassKind.AoBlurH => (masks#b, masks#a)
                        case _                      => (masks#a, masks#b)
                    };
                    let mask = if (p#readsMask) readFrom.defaultView() else sp#blankMask.defaultView();
                    encodePass(sp, host, p, values, target, Vector.get(i, masks#values), depth.defaultView(), mask,
                               drawTo.defaultView(), targetFormatOf(p#format), (0, 0, mw, mh))
                })
        }

    /// DebugView.AmbientOcclusion: 場面の色の代わりに mask を灰色で onto（場面の描き先・format）へ描く pass を積む。
    pub def encodeShow(sp: ScreenPasses, host: Render3d.WebGpuRenderer.Host, key: (Int32, Int32), rect: (Int32, Int32, Int32, Int32), size: (Int32, Int32),
                       onto: TextureView, format: RenderTarget.Format, scene: Scene3d.Scene3dCmd): Unit \ IO =
        match (Render3d.ScreenPasses.ambientOcclusionOf(scene), Map.get(key, Ref.get(sp#masks))) {
            case (Some((inputs, ao)), Some(masks)) =>
                let (sw, sh) = size;
                let values = Render3d.ScreenPasses.valuesOf(scene, inputs, ao, rect);
                let show = { kind = ScreenPassKind.ShowAo, scaled = false, readsMask = true, dir = (0.0f32, 0.0f32), format = Render3d.ScreenPasses.ScreenTargetFormat.R8 };
                encodePass(sp, host, show, values, (0.0f32, 0.0f32, Int32.toFloat32(sw), Int32.toFloat32(sh)), Vector.get(3, masks#values),
                           sp#blankMask.defaultView(), masks#a.defaultView(), onto, RenderPaint.Internal.WebGpuPipelines.textureFormatOf(format), (0, 0, sw, sh))
            case _ => ()
        }

    /// pass p を onto（形式 format・viewport = 左上が原点の矩形）へ全部の画面の三角形で描く render pass を積む。buffer = この pass の SsaoValues。
    def encodePass(sp: ScreenPasses, host: Render3d.WebGpuRenderer.Host, p: ScreenPass, values: Render3d.ScreenPasses.Values,
                   target: (Float32, Float32, Float32, Float32), buffer: Buffer, depth: TextureView, mask: TextureView, onto: TextureView,
                   format: TextureFormat, viewport: (Int32, Int32, Int32, Int32)): Unit \ IO =
        writeValues(sp, buffer, values, target, p#dir);
        let desc = new BindGroupDesc("fge scene3d screen pass", sp#layout);
        discard desc.buffer(0, buffer, 0i64, Int32.toInt64(Render3d.ScreenPasses.valueBytes())).textureView(1, depth).textureView(2, mask);
        let group = sp#gpu.createBindGroup(desc);
        Ref.put(group :: Ref.get(sp#groups), sp#groups);
        let pass = new RenderPassDesc("fge scene3d screen pass");
        discard pass.clearColor(onto, 1.0, 1.0, 1.0, 1.0);
        host#stamp(pass, "scene3d:screen:" + ToString.toString(p#kind));
        let rp = host#encoder().beginRenderPass(pass);
        host#notePass();
        let (vx, vy, vw, vh) = viewport;
        rp.setViewport(Int32.toFloat64(vx), Int32.toFloat64(vy), Int32.toFloat64(vw), Int32.toFloat64(vh), 0.0, 1.0);
        rp.setScissorRect(vx, vy, vw, vh);
        rp.setPipeline(pipelineOf(sp, p#kind, format));
        rp.setBindGroup(0, group);
        rp.draw(3, 1, 0, 0);
        rp.end()

    /// SsaoValues（Render3d.ScreenPasses の頭の並び）を buffer へ書く。
    def writeValues(sp: ScreenPasses, buffer: Buffer, values: Render3d.ScreenPasses.Values, target: (Float32, Float32, Float32, Float32),
                    dir: (Float32, Float32)): Unit \ IO =
        let data = sp#cpu;
        let (dx, dy) = dir;
        let rows = values#eye :: values#forward :: values#right :: values#up :: values#params :: values#rect :: target :: (dx, dy, 0.0f32, 0.0f32) :: Nil;
        List.zipWithIndex(rows) |> List.forEach(match (i, v) -> {
            let (a, b, c, d) = v;
            discard data.putFloat(i * 16, a).putFloat(i * 16 + 4, b).putFloat(i * 16 + 8, c).putFloat(i * 16 + 12, d)
        });
        sp#gpu.writeBuffer(buffer, 0i64, data, 0, Render3d.ScreenPasses.valueBytes())

    /// 種類 kind・描き先の形式 format の pipeline（無ければ作る。ぼかしの 2 つは同じ module）。
    def pipelineOf(sp: ScreenPasses, kind: ScreenPassKind, format: TextureFormat): RenderPipeline \ IO =
        let shared = sharedKindOf(kind);
        let key = ToString.toString(shared) + ":" + format.name();
        match Map.get(key, Ref.get(sp#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d screen " + key);
                discard desc.bindGroupLayout(sp#layout);
                discard desc.vertex(sp#vertexModule, "vs_main").fragment(moduleOf(sp, shared), "fs_main");
                discard desc.colorTarget(format);
                let made = sp#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(sp#pipelines)), sp#pipelines);
                made
        }

    /// ぼかしの縦は横と同じ frag（向きは uniform）。
    def sharedKindOf(kind: ScreenPassKind): ScreenPassKind = match kind {
        case ScreenPassKind.AoBlurV => ScreenPassKind.AoBlurH
        case other                  => other
    }

    def moduleOf(sp: ScreenPasses, kind: ScreenPassKind): ShaderModule \ IO =
        let key = ToString.toString(kind);
        match Map.get(key, Ref.get(sp#modules)) {
            case Some(m) => m
            case None =>
                let made = sp#gpu.createShaderModule("fge scene3d screen " + key,
                                                     ShaderAst.Wgsl.fragment(Render3d.ScreenPasses.fragment(kind, Render3d.ScreenPasses.wgslBindings() :: Nil)));
                Ref.put(Map.insert(key, made, Ref.get(sp#modules)), sp#modules);
                made
        }

    /// encoder を submit した後に呼ぶ: その encoder の pass の bind group を手放す。
    pub def afterSubmit(sp: ScreenPasses): Unit \ IO =
        Ref.get(sp#groups) |> List.forEach(g -> g.release());
        Ref.put(Nil, sp#groups)

    /// 作った物を全部手放す。
    pub def release(sp: ScreenPasses): Unit \ IO =
        afterSubmit(sp);
        Map.forEach((_, m) -> destroyMasks(m), Ref.get(sp#masks));
        Map.forEach((_, p) -> p.release(), Ref.get(sp#pipelines));
        Map.forEach((_, m) -> m.release(), Ref.get(sp#modules));
        sp#vertexModule.release();
        sp#layout.release();
        sp#blankMask.destroy()
}
