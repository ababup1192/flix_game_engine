// Render3d.Internal.SimulationRunner — 見た目の仕事の宣言（Simulation3d）を WebGPU の compute で回す層: id ごとの状態の buffer の組（ping-pong）・
// 構造の値が変わった時の作り直し・1 コマの刻みの数（engine の Simulation3d.Internal.Step）・出口の 1 体ごとの値の buffer。

/// id → GPU の状態。描き手が 1 コマに 1 回 encode し、出口を instancesOf で引く。ゲームからは呼ばない。
/// 初めの状態は CPU（Simulation3d.Internal.Cpu.initialState）で作って上げ、prewarm の刻みは GPU で進める。
// WhyNot: GPU から状態を読み戻す口を置かない — 遊びの規則に使える道になる（読み戻しは待ちを生み、ブラウザのコマの中では待てない）。
pub mod Render3d.Internal.SimulationRunner {
    import fge.webgpu.BindGroup
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.CommandEncoder
    import fge.webgpu.ComputePass
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.Internal.Compute.{Compute}
    use Render3d.Internal.Kernels.{FlockKernel}
    use Simulation3d.Internal.{PresetRules, Structure}
    use Simulation3d.Internal.Step.{Progress, StepPlan}

    /// 群れ 1 つの bind group。A・B = 最新の状態がどちらの buffer にあるか（toA・toB = 規則の書き先）。
    type alias FlockGroups = { countA = BindGroup, countB = BindGroup, scanBlocks = BindGroup, scanSums = BindGroup, scanAdd = BindGroup,
                               scatterA = BindGroup, scatterB = BindGroup, toA = BindGroup, toB = BindGroup, packA = BindGroup, packB = BindGroup }

    /// 群れ 1 つの buffer。
    type alias FlockBuffers = { params = Buffer, stateA = Buffer, stateB = Buffer, cellCount = Buffer, cellStart = Buffer, cellSlot = Buffer,
                                sortedId = Buffer, sortedState = Buffer, blockSums = Buffer, instances = Buffer }

    /// id 1 つの状態。latestInA = 最新の状態が stateA にあるか・progress = 状態の刻みと構造の値・seenFrame = 最後に encode したコマの番号・
    /// seenAt = 最後に encode した時刻（秒）。
    type alias Slot = { count = Int32, buffers = FlockBuffers, groups = FlockGroups, latestInA = Ref[Bool, Static],
                        progress = Ref[Progress, Static], seenFrame = Ref[Int64, Static], seenAt = Ref[Float64, Static] }

    /// 描き手が持つ物。frame = encode の数え・warned = 構造の値の食い違いを知らせた id。
    pub type alias Runner = { compute = Compute, slots = Ref[Map[String, Slot], Static], frame = Ref[Int64, Static], warned = Ref[Set[String], Static] }

    /// 1 つの宣言と、出口に書く emissionIntensity（材質の値）。
    pub type alias Request = { sim = Simulation3d.Simulation3d[Simulation3d.Elements], emission = Float64 }

    /// 出口の 1 体ごとの値の buffer（頂点の buffer の 1 番に差す・1 体 Render3d.InstanceValues.floatsPerInstance 個）と体の数。
    pub type alias Instances = { buffer = Buffer, count = Int32 }

    /// これより長く encode しなかった id の buffer を手放す（秒）。
    // WhyNot: 描かなかったコマですぐ手放さない — メニューを開いた数コマで状態を失い、閉じた時に作り直しになる。
    pub def idleSeconds(): Float64 = 3.0

    pub def create(gpu: WebGpu): Runner \ IO =
        { compute = Render3d.Internal.Compute.create(gpu), slots = Ref.fresh(Static, Map.empty()),
          frame = Ref.fresh(Static, 0i64), warned = Ref.fresh(Static, Set.empty()) }

    /// 全部のプリセットの pipeline を先に作る（描き手を作る時に呼ぶ）。
    pub def buildPipelines(runner: Runner): Unit \ IO =
        Render3d.Internal.Compute.buildPipelines(runner#compute,
            Render3d.Internal.Kernels.kernelsOf(PresetRules.Flock(Simulation3d.Internal.defaultFlockRules())))

    /// 全部の buffer と pipeline を手放す。この後 runner は使えない。
    pub def release(runner: Runner): Unit \ IO =
        Map.forEach((_, s) -> releaseSlot(s), Ref.get(runner#slots));
        Ref.put(Map.empty(), runner#slots);
        Render3d.Internal.Compute.release(runner#compute)

    /// id の出口（今のコマで encode した物）。
    pub def instancesOf(runner: Runner, id: String): Option[Instances] \ IO =
        Map.get(id, Ref.get(runner#slots)) |> Option.map(s -> { buffer = s#buffers#instances, count = s#count })

    /// requests を encoder へ 1 つの compute の pass で積む（刻みと出口の pack）。同じ id は 1 コマに 1 回だけ進め、
    /// 同じ id で構造の値が違う宣言はコマで最初に見た方を使って 1 回知らせる。now = 今の時刻（秒・手放す判定だけに使う）。
    pub def encode(runner: Runner, encoder: CommandEncoder, now: Float64, requests: List[Request]): Unit \ IO =
        let frame = Ref.get(runner#frame) + 1i64;
        Ref.put(frame, runner#frame);
        let work = requests |> List.filterMap(r -> prepareOne(runner, frame, now, r));
        if (List.isEmpty(work)) ()
        else {
            let pass = Render3d.Internal.Compute.beginPass(encoder, "fge simulations", None);
            work |> List.forEach(w -> { let (slot, steps) = w; encodeSlot(runner#compute, pass, slot, steps) });
            pass.end()
        }

    /// コマの終わりに呼ぶ: idleSeconds より長く encode しなかった id を手放す。
    pub def endFrame(runner: Runner, now: Float64): Unit \ IO =
        let slots = Ref.get(runner#slots);
        let stale = Map.toList(slots) |> List.filter(p -> now - Ref.get(snd(p)#seenAt) > idleSeconds());
        stale |> List.forEach(p -> releaseSlot(snd(p)));
        Ref.put(List.foldLeft((m, p) -> Map.remove(fst(p), m), slots, stale), runner#slots)

    /// r の slot を用意して params を上げ、このコマで進める刻みの数と組にする（このコマで既に見た id は None）。
    def prepareOne(runner: Runner, frame: Int64, now: Float64, r: Request): Option[(Slot, Int64)] \ IO =
        let f = Simulation3d.Internal.fieldsOf(r#sim);
        let structure = Simulation3d.Internal.structureOf(f#count, r#sim);
        let held = Map.get(f#id, Ref.get(runner#slots));
        let seenThisFrame = held |> Option.map(s -> Ref.get(s#seenFrame) == frame) |> Option.getWithDefault(false);
        if (seenThisFrame) {
            held |> Option.forEach(s -> if (Ref.get(s#progress)#structure != structure) warnMismatch(runner, f#id) else ());
            None
        } else {
            let reusable = held |> Option.filter(s -> Ref.get(s#progress)#structure == structure);
            if (Option.isEmpty(reusable)) held |> Option.forEach(releaseSlot) else ();
            let slot = match reusable {
                case Some(s) => s
                case None    => allocate(runner#compute, f#count, structure)
            };
            Ref.put(Map.insert(f#id, slot, Ref.get(runner#slots)), runner#slots);
            Ref.put(frame, slot#seenFrame);
            Ref.put(now, slot#seenAt);
            let gpu = runner#compute#gpu;
            let p = Simulation3d.Internal.Cpu.paramsOf(f#count, r#sim);
            gpu.writeBuffer(slot#buffers#params, 0i64, Render3d.Internal.Kernels.flockParamsBytes(p, r#emission), 0, Render3d.Internal.Kernels.paramsBytes());
            let step = Simulation3d.Internal.Step.stepIndexOf(f#time);
            let prev = if (Option.nonEmpty(reusable)) Some(Ref.get(slot#progress)) else None;
            let steps = match Simulation3d.Internal.Step.planOf(f#prewarmSteps, prev, structure, step) {
                case StepPlan.Reset(_, n) =>
                    uploadState(gpu, slot#buffers#stateA, Simulation3d.Internal.Cpu.initialState(p, f#seed));
                    Ref.put(true, slot#latestInA);
                    n
                case StepPlan.Advance(n) => n
            };
            Ref.put({ step = step, structure = structure }, slot#progress);
            if (slot#count > 0) Some((slot, steps)) else None
        }

    def warnMismatch(runner: Runner, id: String): Unit \ IO =
        if (Set.memberOf(id, Ref.get(runner#warned))) ()
        else {
            Ref.put(Set.insert(id, Ref.get(runner#warned)), runner#warned);
            Log.warn("[Simulation3d] @simulation-id-mismatch: id '${id}' を数・seed・プリセットの違う 2 つの宣言で描いた（コマで最初に見た方を使う）")
        }

    def uploadState(gpu: WebGpu, buffer: Buffer, state: Vector[Float32]): Unit \ IO =
        let n = Vector.length(state);
        if (n == 0) ()
        else {
            let bytes = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.LITTLE_ENDIAN);
            Vector.forEachWithIndex((i, v) -> discard bytes.putFloat(i * 4, v), state);
            gpu.writeBuffer(buffer, 0i64, bytes, 0, n * 4)
        }

    def kernel(k: FlockKernel): Render3d.Internal.Compute.Kernel = Render3d.Internal.Kernels.flockKernelOf(k)

    /// count 個の群れの buffer と bind group を作る（0 個でも 1 個分の大きさで作る）。
    def allocate(c: Compute, count: Int32, structure: Structure): Slot \ IO =
        let gpu = c#gpu;
        let n = Int64.max(1i64, Int32.toInt64(count));
        let storage = Int32.bitwiseOr(Int32.bitwiseOr(BufferUsage.STORAGE, BufferUsage.COPY_DST), BufferUsage.COPY_SRC);
        let cells = Int32.toInt64(Render3d.Internal.Kernels.maxCells());
        let make = (label: String, size: Int64, usage: Int32) -> gpu.createBuffer("fge flock ${label}", size, usage);
        let bf = {
            params = make("params", Int32.toInt64(Render3d.Internal.Kernels.paramsBytes()), Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST)),
            stateA = make("state a", n * 32i64, storage), stateB = make("state b", n * 32i64, storage),
            cellCount = make("cell count", cells * 4i64, storage), cellStart = make("cell start", (cells + 1i64) * 4i64, storage),
            cellSlot = make("cell slot", n * 8i64, storage), sortedId = make("sorted id", n * 4i64, storage),
            sortedState = make("sorted state", n * 32i64, storage),
            blockSums = make("block sums", Int32.toInt64(Render3d.Internal.Kernels.scanBlocks()) * 4i64, storage),
            instances = make("instances", n * Int32.toInt64(Render3d.InstanceValues.floatsPerInstance() * 4),
                             Int32.bitwiseOr(Int32.bitwiseOr(BufferUsage.STORAGE, BufferUsage.VERTEX), BufferUsage.COPY_SRC))
        };
        let group = (k: FlockKernel, buffers: List[Buffer]) -> Render3d.Internal.Compute.bindGroupOf(c, kernel(k), bf#params :: buffers);
        let groups = {
            countA = group(FlockKernel.Count, bf#stateA :: bf#cellCount :: bf#cellSlot :: Nil),
            countB = group(FlockKernel.Count, bf#stateB :: bf#cellCount :: bf#cellSlot :: Nil),
            scanBlocks = group(FlockKernel.ScanBlocks, bf#cellCount :: bf#cellStart :: bf#blockSums :: Nil),
            scanSums = group(FlockKernel.ScanSums, bf#blockSums :: Nil),
            scanAdd = group(FlockKernel.ScanAdd, bf#cellStart :: bf#blockSums :: bf#cellCount :: Nil),
            scatterA = group(FlockKernel.Scatter, bf#stateA :: bf#cellSlot :: bf#cellStart :: bf#sortedState :: bf#sortedId :: Nil),
            scatterB = group(FlockKernel.Scatter, bf#stateB :: bf#cellSlot :: bf#cellStart :: bf#sortedState :: bf#sortedId :: Nil),
            toA = group(FlockKernel.RulesGrid, bf#sortedState :: bf#sortedId :: bf#cellStart :: bf#stateA :: Nil),
            toB = group(FlockKernel.RulesGrid, bf#sortedState :: bf#sortedId :: bf#cellStart :: bf#stateB :: Nil),
            packA = group(FlockKernel.Pack, bf#stateA :: bf#instances :: Nil),
            packB = group(FlockKernel.Pack, bf#stateB :: bf#instances :: Nil)
        };
        { count = Int32.max(0, count), buffers = bf, groups = groups, latestInA = Ref.fresh(Static, true),
          progress = Ref.fresh(Static, { step = 0i64, structure = structure }),
          seenFrame = Ref.fresh(Static, -1i64), seenAt = Ref.fresh(Static, 0.0) }

    def releaseSlot(s: Slot): Unit \ IO =
        let g = s#groups;
        (g#countA :: g#countB :: g#scanBlocks :: g#scanSums :: g#scanAdd :: g#scatterA :: g#scatterB :: g#toA :: g#toB :: g#packA :: g#packB :: Nil)
            |> List.forEach(x -> x.release());
        let b = s#buffers;
        (b#params :: b#stateA :: b#stateB :: b#cellCount :: b#cellStart :: b#cellSlot :: b#sortedId :: b#sortedState :: b#blockSums :: b#instances :: Nil)
            |> List.forEach(x -> x.destroy())

    /// slot を steps 刻み進め、出口を pack する dispatch を pass へ積む。
    def encodeSlot(c: Compute, pass: ComputePass, slot: Slot, steps: Int64): Unit \ IO =
        encodeSteps(c, pass, slot, steps);
        let g = slot#groups;
        Render3d.Internal.Compute.dispatch(c, pass, kernel(FlockKernel.Pack), if (Ref.get(slot#latestInA)) g#packA else g#packB,
                                           Render3d.Internal.Compute.groupsFor(slot#count))

    def encodeSteps(c: Compute, pass: ComputePass, slot: Slot, steps: Int64): Unit \ IO =
        if (steps <= 0i64) ()
        else {
            encodeStep(c, pass, slot);
            encodeSteps(c, pass, slot, steps - 1i64)
        }

    /// 1 刻み: 最新の状態を読み、もう片方へ書く。
    def encodeStep(c: Compute, pass: ComputePass, slot: Slot): Unit \ IO =
        let g = slot#groups;
        let inA = Ref.get(slot#latestInA);
        let elements = Render3d.Internal.Compute.groupsFor(slot#count);
        let d = (k: FlockKernel, group: BindGroup, n: Int32) -> Render3d.Internal.Compute.dispatch(c, pass, kernel(k), group, n);
        d(FlockKernel.Count, if (inA) g#countA else g#countB, elements);
        d(FlockKernel.ScanBlocks, g#scanBlocks, Render3d.Internal.Kernels.scanBlocks());
        d(FlockKernel.ScanSums, g#scanSums, 1);
        d(FlockKernel.ScanAdd, g#scanAdd, Render3d.Internal.Kernels.maxCells() / Render3d.Internal.Compute.workgroupSize());
        d(FlockKernel.Scatter, if (inA) g#scatterA else g#scatterB, elements);
        d(FlockKernel.RulesGrid, if (inA) g#toB else g#toA, elements);
        Ref.put(not inA, slot#latestInA)
}
