// RenderPaint.Internal.WebGpuTimer — WebGPU の pass ごとの GPU の時間を timestamp-query で測る（FrameDiagnostics.Diagnostics.gpuNs・gpuPasses。GL の GpuTimer と対）。
// 測るコマ（GpuTimer.sampleIntervalOf の間隔・FLIX_GE_GPU_TIMER_EVERY）だけ、開く pass の desc に始めと終わりの番号を振り（stamp）、
// コマの終わりに番号を resolve して読み戻しの buffer へ写す（beforeSubmit）。読み戻しは readDelay() コマ後に読む（afterSubmit）。
// 名前の同じ pass（点光源の影の面・場面の pass）は足し合わせる（GpuTimer.mergeByName）。
// WhyNot: ブラウザで入れない — readBuffer は requestAnimationFrame の中で待てない（fge.webgpu.WebGpu の doc）。ウィンドウの層だけが WebGpuPaint.withGpuTimer で入れる。
// WhyNot: pass の間の空きを数えない — timestamp は pass の始めと終わりだけを打つ。gpuNs は pass の時間の和（GL の GpuTimer と同じ物差し）。
// WhyNot: pass の始めから終わりまでをそのまま pass の時間にしない — タイル型の GPU は pass が重なって流れ、和がコマの時間を何倍も超える（GpuTimer.exclusiveTimes）。
// WhyNot: コマの最初の pass を自分の始めから数えない — 垂直同期を待たないウィンドウでは GPU が前のコマを描いている間に始めの時刻が打たれ、前のコマの残りが最初の pass に入る
//   （Bistro の夜で影の地図の控えを使っても shadow:point が 12 ms のままに見えた）。測るコマの前のコマにも番号を振り、その最後の pass の終わりから数える。
// WhyNot: 毎コマ打たない — 読み戻しの写しと map がコマごとに増え、GL の GpuTimer と同じく診断を付けた時だけ遅いゲームになる。
// WhyNot: 診断を集めるだけで入れない（FLIX_GE_GPU_TIMER=1 の時だけ）— readBuffer（Dawn の mapAsync を待つ形）は、それまでに submit した仕事を GPU が終えるまで返らない。
//   垂直同期を待たない Bistro の夜で、読むコマが 90〜320 ms に伸びた（測ったコマの数コマ後に読んでも同じ）。待たない map は WebGpu の interface（GL の層の jar）に足す事になる。
pub mod RenderPaint.Internal.WebGpuTimer {
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.CommandEncoder
    import fge.webgpu.QuerySet
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.WebGpu
    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    /// device の上の物。querySet = timestamp を書く所・resolve = resolve する buffer・readbacks = 読み戻しの buffer の輪・cpu = 読んだ値の入れ物。
    type alias Gear = { querySet = QuerySet, resolve = Buffer, readbacks = Vector[Buffer], cpu = ByteBuffer }

    /// 読み戻しを待つコマ。slot = 読み戻しの buffer の番号・frame = 測ったコマの通し番号・spans = (名前, 始めの番号)（描いた順）。
    type alias Waiting = { slot = Int32, frame = Int32, spans = List[(String, Int32)] }

    /// 測る物。gear = device が timestamp-query を持たない・入れていない時は None（何もしない）・on = 診断を集めているか・
    /// frame = 画面のコマの通し番号・spans = 今のコマに番号を振った pass（新しい順）・waiting = 読み戻しを待つコマ（古い順）・
    /// samples = takeSamples の後に読めたコマの時間（新しい順）・latest = 最後に読めたコマの時間。
    /// lastEnd = 最後に読めたコマの通し番号と、その最後の pass の終わりの時刻（次のコマの最初の pass を数え始める所）。
    pub enum Timer({ gear = Option[Gear], every = Int32, on = Ref[Bool, Static], frame = Ref[Int32, Static],
                     spans = Ref[List[(String, Int32)], Static], used = Ref[Int32, Static], waiting = Ref[List[Waiting], Static],
                     samples = Ref[List[GpuTimer.FrameTime], Static], latest = Ref[Option[GpuTimer.FrameTime], Static],
                     lastEnd = Ref[Option[(Int32, Int64)], Static] })

    /// 1 コマに番号を振る pass の数の上限（超えた pass は測らない）。
    def maxSpans(): Int32 = 256

    /// 読み戻しの buffer の数。
    def ringSize(): Int32 = 4

    /// 測ったコマから何コマ後に読むか（読む時に GPU が終えていなければ待つ）。
    def readDelay(): Int32 = 1

    /// 何もしない物（ブラウザ・1 枚撮り）。
    pub def off(): Timer \ IO = fresh(None)

    /// FLIX_GE_GPU_TIMER=1 で、gpu が timestamp-query を持てば測る物を作る（ほかは off と同じ）。
    pub def create(gpu: WebGpu): Timer \ IO =
        if (not gpu.hasTimestampQuery() or Object.toOption(System.getenv("FLIX_GE_GPU_TIMER")) != Some("1")) off()
        else {
            let bytes = Int32.toInt64(maxSpans() * 16);
            let readUsage = Int32.bitwiseOr(BufferUsage.MAP_READ, BufferUsage.COPY_DST);
            fresh(Some({
                querySet = gpu.createTimestampQuerySet("fge gpu timer", maxSpans() * 2),
                resolve = gpu.createBuffer("fge gpu timer resolve", bytes, Int32.bitwiseOr(BufferUsage.QUERY_RESOLVE, BufferUsage.COPY_SRC)),
                readbacks = Vector.range(0, ringSize()) |> Vector.map(_ -> gpu.createBuffer("fge gpu timer read", bytes, readUsage)),
                cpu = ByteBuffer.allocateDirect(maxSpans() * 16).order(ByteOrder.LITTLE_ENDIAN)
            }))
        }

    def fresh(gear: Option[Gear]): Timer \ IO =
        let every = GpuTimer.sampleIntervalOf(Object.toOption(System.getenv("FLIX_GE_GPU_TIMER_EVERY")));
        Timer.Timer({ gear = gear, every = every, on = Ref.fresh(Static, false), frame = Ref.fresh(Static, 0), spans = Ref.fresh(Static, Nil), used = Ref.fresh(Static, 0),
                      waiting = Ref.fresh(Static, Nil), samples = Ref.fresh(Static, Nil), latest = Ref.fresh(Static, None), lastEnd = Ref.fresh(Static, None) })

    /// device の上の物を手放す。
    pub def release(t: Timer): Unit \ IO =
        let Timer.Timer(s) = t;
        s#gear |> Option.forEach(g -> {
            g#querySet.destroy();
            g#resolve.destroy();
            g#readbacks |> Vector.forEach(b -> b.destroy())
        })

    /// 診断を集め始める・やめる（やめている間は番号を振らない）。
    pub def setOn(t: Timer, on: Bool): Unit \ IO =
        let Timer.Timer(s) = t;
        Ref.put(on, s#on)

    /// 測るコマと、その前のコマ（数え始める時刻を取る）なら、これから開く pass の desc に始めと終わりの番号を振り、区間 name として控える。
    pub def stamp(t: Timer, desc: RenderPassDesc, name: String): Unit \ IO =
        let Timer.Timer(s) = t;
        let used = Ref.get(s#used);
        let frame = Ref.get(s#frame);
        let stamped = GpuTimer.isSampledFrame(s#every, frame) or GpuTimer.isSampledFrame(s#every, frame + 1);
        let sampled = Ref.get(s#on) and stamped and used < maxSpans();
        s#gear |> Option.filter(_ -> sampled) |> Option.forEach(g -> {
            discard desc.timestampWrites(g#querySet, used * 2, used * 2 + 1);
            Ref.put((name, used * 2) :: Ref.get(s#spans), s#spans);
            Ref.put(used + 1, s#used)
        })

    /// コマの最後の submit の前: 番号を振った pass があれば、encoder に resolve と読み戻しの写しを積む（空いた読み戻しの buffer が無ければ、一番古いコマを待って読む）。
    pub def beforeSubmit(t: Timer, gpu: WebGpu, encoder: Unit -> CommandEncoder \ IO): Unit \ IO =
        let Timer.Timer(s) = t;
        let spans = List.reverse(Ref.get(s#spans));
        Ref.put(Nil, s#spans);
        Ref.put(0, s#used);
        s#gear |> Option.filter(_ -> not List.isEmpty(spans)) |> Option.forEach(g -> {
            if (List.length(Ref.get(s#waiting)) >= ringSize()) readOldest(t, gpu, g) else ();
            let busy = Ref.get(s#waiting) |> List.map(w -> w#slot) |> List.toSet;
            let slot = List.range(0, ringSize()) |> List.find(i -> not Set.memberOf(i, busy)) |> Option.getWithDefault(0);
            let count = List.length(spans) * 2;
            let e = encoder();
            e.resolveQuerySet(g#querySet, 0, count, g#resolve, 0i64);
            e.copyBufferToBuffer(g#resolve, 0i64, Vector.get(slot, g#readbacks), 0i64, Int32.toInt64(count * 8));
            Ref.put(List.append(Ref.get(s#waiting), { slot = slot, frame = Ref.get(s#frame), spans = spans } :: Nil), s#waiting)
        })

    /// コマの最後の submit の後: readDelay() コマ経ったコマを読み、コマの通し番号を進めて、最後に読めたコマの時間を返す（まだ無ければ None）。
    pub def afterSubmit(t: Timer, gpu: WebGpu): Option[GpuTimer.FrameTime] \ IO =
        let Timer.Timer(s) = t;
        let now = Ref.get(s#frame);
        s#gear |> Option.forEach(g -> readDue(t, gpu, g, now));
        Ref.put(now + 1, s#frame);
        Ref.get(s#latest)

    /// 前に呼んでから読めたコマの時間（古い順）を返して空にする。
    pub def takeSamples(t: Timer): List[GpuTimer.FrameTime] \ IO =
        let Timer.Timer(s) = t;
        let taken = List.reverse(Ref.get(s#samples));
        Ref.put(Nil, s#samples);
        taken

    def readDue(t: Timer, gpu: WebGpu, g: Gear, now: Int32): Unit \ IO =
        let Timer.Timer(s) = t;
        match Ref.get(s#waiting) {
            case w :: _ if now - w#frame >= readDelay() =>
                readOldest(t, gpu, g);
                readDue(t, gpu, g, now)
            case _ => ()
        }

    /// 一番古い待ちのコマを読み（GPU が終えていなければ待つ）、読めた時間を控える。
    def readOldest(t: Timer, gpu: WebGpu, g: Gear): Unit \ IO =
        let Timer.Timer(s) = t;
        match Ref.get(s#waiting) {
            case Nil       => ()
            case w :: rest =>
                Ref.put(rest, s#waiting);
                let count = List.length(w#spans) * 2;
                g#cpu.clear();
                gpu.readBuffer(Vector.get(w#slot, g#readbacks), 0i64, count * 8, g#cpu);
                let cpu = g#cpu;
                let stamps = w#spans |> List.map(match (name, at) -> (name, cpu.getLong(at * 8), cpu.getLong((at + 1) * 8)));
                let start = Ref.get(s#lastEnd) |> Option.filter(fe -> fst(fe) == w#frame - 1) |> Option.map(snd);
                Ref.put(Some((w#frame, stamps |> List.foldLeft((acc, st) -> { let (_, _, end) = st; Int64.max(acc, end) }, Int64.minValue()))), s#lastEnd);
                if (GpuTimer.isSampledFrame(s#every, w#frame)) noteSample(t, GpuTimer.exclusiveTimesFrom(start, stamps)) else ()
        }

    /// 読めたコマの pass ごとの時間を控える。
    def noteSample(t: Timer, passes: List[(String, Int64)]): Unit \ IO =
        let Timer.Timer(s) = t;
        let time = { gpuNs = passes |> List.foldLeft((acc, p) -> acc + snd(p), 0i64), passes = GpuTimer.mergeByName(passes) };
        Ref.put(Some(time), s#latest);
        Ref.put(List.take(256, time :: Ref.get(s#samples)), s#samples)
}
