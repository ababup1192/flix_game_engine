// Render3d.Internal.Compute — WebGPU の compute の汎用の層: kernel（WGSL の字と binding の並び）から pipeline を作って持つ・
// bind group・dispatch・計時の pass（群れのような仕事のことは知らない）。

/// compute の pipeline の置き場と、dispatch の道具。ゲームからは呼ばない。
pub mod Render3d.Internal.Compute {
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.CommandEncoder
    import fge.webgpu.ComputePass
    import fge.webgpu.ComputePipeline
    import fge.webgpu.ComputePipelineDesc
    import fge.webgpu.QuerySet
    import fge.webgpu.ShaderStage
    import fge.webgpu.WebGpu

    /// binding 1 つの種類（番号は並びの位置）。
    pub enum Access with Eq, ToString {
        case Uniform
        case ReadOnly
        case ReadWrite
    }

    /// kernel 1 本: name = pipeline の鍵と label・bindings = group 0 の binding 0, 1, … の種類・source = WGSL の字（入口は cs_main・pipeline を作る時だけ組む）。
    pub type alias Kernel = { name = String, bindings = List[Access], source = Lazy[String] }

    /// 作った pipeline と、その group 0 の layout。
    pub type alias Built = { pipeline = ComputePipeline, layout = BindGroupLayout }

    /// device と、kernel の名前 → 作った pipeline。
    pub type alias Compute = { gpu = WebGpu, built = Ref[Map[String, Built], Static] }

    /// workgroup の大きさ（WGSL の @workgroup_size と同じ）。
    // WhyNot: 128 や 256 にしない — compatibility の上限 128・core の 256 のどちらにも入り、共有メモリに読む数とそろえて 1 か所で決める。
    pub def workgroupSize(): Int32 = 64

    /// n 個を 1 本ずつ受け持つ時の workgroup の数。
    pub def groupsFor(n: Int32): Int32 = (Int32.max(n, 0) + workgroupSize() - 1) / workgroupSize()

    pub def create(gpu: WebGpu): Compute \ IO = { gpu = gpu, built = Ref.fresh(Static, Map.empty()) }

    /// 作った pipeline と layout を全部手放す。この後 c は使えない。
    pub def release(c: Compute): Unit \ IO =
        Map.forEach((_, b) -> { b#pipeline.release(); b#layout.release() }, Ref.get(c#built));
        Ref.put(Map.empty(), c#built)

    def bufferTypeOf(a: Access): BufferBindingType = match a {
        case Access.Uniform   => BufferBindingType.UNIFORM
        case Access.ReadOnly  => BufferBindingType.READ_ONLY_STORAGE
        case Access.ReadWrite => BufferBindingType.STORAGE
    }

    /// kernels を先に全部作る（初めて使うコマで止まらないように、描き手を作る時に呼ぶ）。
    pub def buildPipelines(c: Compute, kernels: List[Kernel]): Unit \ IO =
        kernels |> List.forEach(k -> discard pipelineOf(c, k))

    /// kernel の pipeline（置き場に無ければ作る）。
    pub def pipelineOf(c: Compute, k: Kernel): Built \ IO =
        match Map.get(k#name, Ref.get(c#built)) {
            case Some(b) => b
            case None =>
                let desc = new BindGroupLayoutDesc(k#name);
                List.zipWithIndex(k#bindings) |> List.forEach(p -> discard desc.buffer(fst(p), ShaderStage.COMPUTE, bufferTypeOf(snd(p))));
                let layout = c#gpu.createBindGroupLayout(desc);
                let module = c#gpu.createShaderModule(k#name, force k#source);
                let pipeline = c#gpu.createComputePipeline(new ComputePipelineDesc(k#name).bindGroupLayout(layout).compute(module, "cs_main"));
                module.release();
                let b = { pipeline = pipeline, layout = layout };
                Ref.put(Map.insert(k#name, b, Ref.get(c#built)), c#built);
                b
        }

    /// kernel の group 0 に buffers（binding 0, 1, … の順・各 buffer の頭から全部）を差した bind group。
    pub def bindGroupOf(c: Compute, k: Kernel, buffers: List[Buffer]): BindGroup \ IO =
        let desc = new BindGroupDesc(k#name, pipelineOf(c, k)#layout);
        List.zipWithIndex(buffers) |> List.forEach(p -> discard desc.buffer(fst(p), snd(p), 0i64, snd(p).size()));
        c#gpu.createBindGroup(desc)

    /// pass に kernel の dispatch を 1 つ積む（workgroups 個・1 次元）。
    pub def dispatch(c: Compute, pass: ComputePass, k: Kernel, group: BindGroup, workgroups: Int32): Unit \ IO =
        if (workgroups <= 0) ()
        else {
            pass.setPipeline(pipelineOf(c, k)#pipeline);
            pass.setBindGroup(0, group);
            pass.dispatchWorkgroups(workgroups, 1, 1)
        }

    /// encoder に compute の pass を開く。timestamps = Some((query set, 始めの番号, 終わりの番号)) なら pass の時刻を書く。
    pub def beginPass(encoder: CommandEncoder, label: String, timestamps: Option[(QuerySet, Int32, Int32)]): ComputePass \ IO =
        match timestamps {
            case Some((qs, begin, end)) => encoder.beginComputePass(label, qs, begin, end)
            case None                   => encoder.beginComputePass(label, (checked_cast(null): QuerySet), 0, 0)
        }

    /// encoder で buffer の [offset, offset + size) を 0 にする（pass の外で）。
    pub def clearBuffer(encoder: CommandEncoder, buffer: Buffer, offset: Int64, size: Int64): Unit \ IO =
        encoder.clearBuffer(buffer, offset, size)
}
