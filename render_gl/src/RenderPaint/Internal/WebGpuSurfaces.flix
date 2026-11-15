// RenderPaint.Internal.WebGpuSurfaces — WebGPU の塗りのコア（WebGpuPaint）の面（ShaderDoc）の分: 面の program の表（ShaderGen.Wgsl の WGSL を組んだ shader module）・
// 面の pipeline・面の行 1 つを描く draw（面の値を uniform として読む bind group を draw ごとに作る）。
// program は Spec の名前で引き、中身が同じなら作り直さない（GL の RenderPaint.buildProgram と同じ決まり）。組めない Spec は単色の代わり（WebGpuShader.surfaceFallbackWgsl）で塗る。
// pipeline は program × blend × 描き先の形式 × 標本の数 × stencil の使い方ごとに 1 本で、初めて要る時に作って控える。
pub mod RenderPaint.Internal.WebGpuSurfaces {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.FilterMode
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Sampler
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    use RenderFrame.Internal.RenderList
    use RenderPaint.Internal.WebGpuPipelines
    use RenderPaint.Internal.WebGpuShader

    /// 組んだ面 1 つ: shader module・面の値の数（ShaderGen.Wgsl の SgValues の欄の数）・読む絵の数。
    type alias Program = { module = ShaderModule, slots = Int32, reads = Int32 }

    /// 面の表。frameLayout・frameGroup・blankGroup・nearestClamp は WebGpuPaint の持ち物（ここでは手放さない）。
    /// byName = Spec の名前 → (組んだ時の Spec, program の番号)・programs = 番号 → 組んだ面・layouts = 読む絵の数 → group 0 の layout・
    /// pipelines の鍵 = program の番号 × 64 + ((blend の番号 × 2 + 形式) × 2 + 標本（0 = 1・1 = 4）) × 4 + stencil の使い方・
    /// retired = 同じ名前で作り直して表から外した番号（コマの終わりに手放す）・drawGroups = 今の encoder に積んだ draw の bind group（submit の後に手放す）。
    pub type alias Surfaces = {
        gpu = WebGpu,
        frameLayout = BindGroupLayout,
        frameGroup = BindGroup,
        blankGroup = BindGroup,
        nearestClamp = Sampler,
        linearClamp = Sampler,
        black = Texture,
        byName = Ref[Map[String, (ShaderDoc.Spec, Int32)], Static],
        programs = Ref[Map[Int32, Program], Static],
        layouts = Ref[Map[Int32, BindGroupLayout], Static],
        pipelines = Ref[Map[Int32, RenderPipeline], Static],
        nextId = Array[Int32, Static],
        retired = Ref[List[Int32], Static],
        drawGroups = Ref[List[BindGroup], Static],
        warned = Ref[Set[String], Static]
    }

    /// 単色の代わりの program の番号（表を作る時に組んである）。
    pub def fallbackProgram(): Int32 = 1

    /// 単色の代わりを組んだ表。
    pub def fresh(gpu: WebGpu, frame: { layout = BindGroupLayout, group = BindGroup }, blankGroup: BindGroup, nearestClamp: Sampler): Surfaces \ IO =
        let black = gpu.createTexture("fge surface black", 1, 1, TextureFormat.RGBA8_UNORM,
                                      Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        let opaque = ByteBuffer.allocateDirect(4);
        discard opaque.put(3, -1i8);
        gpu.writeTexture(black, 0, 0, 0, 1, 1, opaque, 0, 4);
        let module = gpu.createShaderModule("fge surface fallback", WebGpuShader.surfaceFallbackWgsl());
        { gpu = gpu, frameLayout = frame#layout, frameGroup = frame#group, blankGroup = blankGroup, nearestClamp = nearestClamp,
          linearClamp = gpu.createSampler("fge linear clamp", FilterMode.LINEAR, FilterMode.NEAREST, AddressMode.CLAMP_TO_EDGE),
          black = black, byName = Ref.fresh(Static, Map.empty()),
          programs = Ref.fresh(Static, Map#{fallbackProgram() => { module = module, slots = 6, reads = 0 }}),
          layouts = Ref.fresh(Static, Map.empty()), pipelines = Ref.fresh(Static, Map.empty()), nextId = Array#{fallbackProgram() + 1} @ Static,
          retired = Ref.fresh(Static, Nil), drawGroups = Ref.fresh(Static, Nil), warned = Ref.fresh(Static, Set.empty()) }

    // ── program ──

    /// Platform.GpuResources.buildProgram の中身。name で引き、中身が同じなら前の番号を返す（ShaderGen.compile と WGSL の組み立てを呼ばない）。
    /// 中身が違えば組み直して差し替え、前の番号はコマの終わりに手放す（同じコマの前の面がまだ描く）。WGSL を組めなければ単色の代わりの番号。
    pub def buildProgram(surfaces: Surfaces, spec: ShaderDoc.Spec): Int32 \ IO =
        let named = Ref.get(surfaces#byName);
        match Map.get(spec#name, named) {
            case Some((stored, id)) if ShaderGen.isSameSpec(stored, spec) => id
            case Some((stored, id)) if ShaderGen.eqSpec(stored, spec) =>
                // 中身が同じ別の物は、来た方を持ち直す — 古い方を持ち続けると次のコマも参照の一致で抜けられず、毎コマ木を丸ごと比べ続ける。
                Ref.put(Map.insert(spec#name, (spec, id), named), surfaces#byName);
                id
            case old =>
                let id = compileProgram(surfaces, spec);
                Option.forEach(match (_, oldId) -> if (oldId == id or oldId == fallbackProgram()) () else Ref.put(oldId :: Ref.get(surfaces#retired), surfaces#retired), old);
                Ref.put(Map.insert(spec#name, (spec, id), named), surfaces#byName);
                id
        }

    /// Spec の WGSL を組んで表に足し、番号を返す。組めなければ単色の代わりの番号（名前ごとに 1 回知らせる）。
    def compileProgram(surfaces: Surfaces, spec: ShaderDoc.Spec): Int32 \ IO =
        let out = ShaderGen.Wgsl.compile(spec);
        let module = surfaces#gpu.createShaderModule("fge surface ${spec#name}", out#module);
        let errors = String.lines(surfaces#gpu.getCompilationInfo(module)) |> List.filter(l -> String.startsWith({ prefix = "Error" }, l));
        match errors {
            case first :: _ =>
                module.release();
                let warned = Ref.get(surfaces#warned);
                if (Set.memberOf(spec#name, warned)) ()
                else {
                    Ref.put(Set.insert(spec#name, warned), surfaces#warned);
                    Log.fellBack("shader", spec#name, "単色の代わり", "WGSL を組めない（${first}）")
                };
                fallbackProgram()
            case Nil =>
                let id = Array.get(0, surfaces#nextId);
                Array.put(id + 1, 0, surfaces#nextId);
                let program = { module = module, slots = List.length(out#slots), reads = List.length(out#texReads) };
                Ref.put(Map.insert(id, program, Ref.get(surfaces#programs)), surfaces#programs);
                id
        }

    /// group 0 の layout（面の値の uniform と、読む絵の数ぶんの texture と sampler。ShaderGen.Wgsl.compile の binding の並び）。読む絵の数ごとに 1 つ作って控える。
    def layoutOf(surfaces: Surfaces, reads: Int32): BindGroupLayout \ IO =
        match Map.get(reads, Ref.get(surfaces#layouts)) {
            case Some(layout) => layout
            case None =>
                let desc = new BindGroupLayoutDesc("fge surface values").buffer(0, Int32.bitwiseOr(ShaderStage.VERTEX, ShaderStage.FRAGMENT), BufferBindingType.UNIFORM);
                List.forEach(k -> {
                    discard desc.texture(1 + 2 * k, ShaderStage.FRAGMENT, TextureSampleType.FLOAT);
                    discard desc.sampler(2 + 2 * k, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING)
                }, List.range(0, reads));
                let layout = surfaces#gpu.createBindGroupLayout(desc);
                Ref.put(Map.insert(reads, layout, Ref.get(surfaces#layouts)), surfaces#layouts);
                layout
        }

    /// program id の pipeline（無ければ作る）。blendC = RenderFrame.blendCode・stencil = WebGpuRows.stencil*。
    def pipelineOf(surfaces: Surfaces, id: Int32, program: Program, blendC: Int32, format: RenderTarget.Format, samples: Int32, stencil: Int32): RenderPipeline \ IO =
        let key = id * 64 + ((blendC * 2 + WebGpuPipelines.formatCode(format)) * 2 + (if (samples > 1) 1 else 0)) * 4 + stencil;
        match Map.get(key, Ref.get(surfaces#pipelines)) {
            case Some(pipeline) => pipeline
            case None =>
                let desc = new RenderPipelineDesc("fge surface ${Int32.toString(id)}");
                discard desc.bindGroupLayout(layoutOf(surfaces, program#reads)).bindGroupLayout(surfaces#frameLayout);
                discard desc.vertex(program#module, "vs_main").fragment(program#module, "fs_main");
                WebGpuPipelines.describeTarget(blendC, WebGpuPipelines.textureFormatOf(format), samples, stencil, desc);
                let pipeline = surfaces#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, pipeline, Ref.get(surfaces#pipelines)), surfaces#pipelines);
                pipeline
        }

    // ── draw ──

    /// 面の行 row（RenderList の面の行）の面を、pass に draw 1 本で塗る。target = 描き先の形式と標本の数・stencil = WebGpuRows.stencil*・
    /// values と bytes = 行の面の値を置いた buffer とその位置（RenderList.surfaceValueAlign の 4 倍の倍数）・textureOf = 絵の表の番号 → texture。
    /// 描いた後は group 0 を射影・group 1 を空の絵に戻す（スプライトの形の pipeline の並び）。表に無い program と、面の値が program の欄より少ない行は描かずに知らせる。
    // WhyNot: bind group を番号と位置と絵の組で控えて使い回さない — 位置は前の行の values の数で毎コマ動き、絵と buffer を捨てる・作り直す時に控えを外す決まりが要る
    //   （比べた結果は plans/engine-webgpu.md の 12.22）。
    pub def draw(surfaces: Surfaces, pass: RenderPass, target: (RenderTarget.Format, Int32), stencil: Int32, values: Buffer, bytes: Int32,
                 textureOf: Int32 -> Option[Texture] \ IO, skip: String -> Unit \ IO,
                 rows: Array[Int32, Static], row: Int32, reads: Array[Int32, Static]): Unit \ IO =
        let id = RenderList.rowAt(rows, row, 1);
        match Map.get(id, Ref.get(surfaces#programs)) {
            case None => skip("面（組んでいない program）")
            case Some(program) =>
                let size = (4 * program#slots + 15) / 16 * 16;
                if (size > 4 * RenderList.surfaceValuesTaken(RenderList.rowAt(rows, row, 2))) skip("面（program の値の欄が行の値より多い）")
                else {
                    let (format, samples) = target;
                    let group = groupOf(surfaces, program, values, bytes, size, textureOf, reads, RenderList.rowAt(rows, row, 6), RenderList.rowAt(rows, row, 7));
                    pass.setPipeline(pipelineOf(surfaces, id, program, RenderList.rowAt(rows, row, 4), format, samples, stencil));
                    pass.setBindGroup(0, group);
                    pass.setBindGroup(1, surfaces#frameGroup);
                    pass.draw(6, 1, 0, 0);
                    pass.setBindGroup(0, surfaces#frameGroup);
                    pass.setBindGroup(1, surfaces#blankGroup)
                }
        }

    /// 面の値（values の bytes から size バイト）と、reads の [first, first + count) の絵を読む group 0。絵の数が program#reads に足りなければ、残りは不透明な黒
    /// （GL が絵の無い unit で読む値）。今の encoder の draw の物として控え、submit の後に手放す。
    def groupOf(surfaces: Surfaces, program: Program, values: Buffer, bytes: Int32, size: Int32, textureOf: Int32 -> Option[Texture] \ IO,
                reads: Array[Int32, Static], first: Int32, count: Int32): BindGroup \ IO =
        let desc = new BindGroupDesc("fge surface", layoutOf(surfaces, program#reads)).buffer(0, values, Int32.toInt64(bytes), Int32.toInt64(size));
        List.forEach(k -> {
            let base = (first + k) * RenderList.readFields();
            let texture = if (k < count) textureOf(Array.get(base, reads)) |> Option.getWithDefault(surfaces#black) else surfaces#black;
            let sampler = if (k < count and Array.get(base + 1, reads) == 1) surfaces#linearClamp else surfaces#nearestClamp;
            discard desc.textureView(1 + 2 * k, texture.defaultView()).sampler(2 + 2 * k, sampler)
        }, List.range(0, program#reads));
        let group = surfaces#gpu.createBindGroup(desc);
        Ref.put(group :: Ref.get(surfaces#drawGroups), surfaces#drawGroups);
        group

    // ── 手放す ──

    /// encoder を submit した後に呼ぶ: その encoder の draw の bind group を手放す。
    pub def afterSubmit(surfaces: Surfaces): Unit \ IO =
        List.forEach(g -> g.release(), Ref.get(surfaces#drawGroups));
        Ref.put(Nil, surfaces#drawGroups)

    /// コマの終わり（submit の後）に呼ぶ: 作り直して表から外した program と、その pipeline を手放す。
    pub def endFrame(surfaces: Surfaces): Unit \ IO =
        let retired = List.toSet(Ref.get(surfaces#retired));
        if (Set.isEmpty(retired)) ()
        else {
            Ref.put(Nil, surfaces#retired);
            let pipelines = Ref.get(surfaces#pipelines);
            Map.forEach((key, pipeline) -> if (Set.memberOf(key / 64, retired)) pipeline.release() else (), pipelines);
            Ref.put(Map.filterWithKey((key, _) -> not Set.memberOf(key / 64, retired), pipelines), surfaces#pipelines);
            Set.forEach(id -> Map.get(id, Ref.get(surfaces#programs)) |> Option.forEach(p -> p#module.release()), retired);
            Ref.put(Map.filterWithKey((id, _) -> not Set.memberOf(id, retired), Ref.get(surfaces#programs)), surfaces#programs)
        }

    /// 作った物（bind group・pipeline・layout・shader module・sampler・黒の絵）を全部手放す。この後 surfaces は使えない。
    pub def release(surfaces: Surfaces): Unit \ IO =
        afterSubmit(surfaces);
        Map.forEach((_, pipeline) -> pipeline.release(), Ref.get(surfaces#pipelines));
        Ref.put(Map.empty(), surfaces#pipelines);
        Map.forEach((_, layout) -> layout.release(), Ref.get(surfaces#layouts));
        Ref.put(Map.empty(), surfaces#layouts);
        Map.forEach((_, p) -> p#module.release(), Ref.get(surfaces#programs));
        Ref.put(Map.empty(), surfaces#programs);
        surfaces#linearClamp.release();
        surfaces#black.destroy()
}
