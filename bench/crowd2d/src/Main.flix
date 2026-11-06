// 入口。敵の数 × 探し方の区間を順に回し、区間ごとに時間を出して閉じる。
use fge::LwjglLayer

mod CrowdBench {
    use fge::{App, LwjglLayer, Render}
    use Crowd.NearSearch

    import java.lang.System

    /// 1 コマの時間（ms）。frameMs = 前のコマの全部・stepMs = 規則・submitMs = GL へ送る・swapMs = 画面の入れ替え・gpuMs = GPU。
    type alias Sample = { frameMs = Float64, stepMs = Float64, submitMs = Float64, swapMs = Float64, gpuMs = Option[Float64], drawItems = Int32 }

    pub type alias World = { segments = Vector[(Int32, NearSearch)], crowd = Crowd.Crowd, segment = Int32, frameInSegment = Int32, samples = List[Sample], nearSum = Float64, done = Bool }

    /// 環境変数 COUNTS（例: `COUNTS=6000,10000`）があればその敵の数で、無ければ Crowd.counts で回す。
    def loadCounts(): List[Int32] \ IO =
        let text = System.getenv("COUNTS");
        if (Object.isNull(text) or text == "") Crowd.counts()
        else String.split(regex = ",", text) |> List.filterMap(Int32.fromString)

    def segmentsOf(counts: List[Int32]): Vector[(Int32, NearSearch)] =
        counts
            |> List.flatMap(n -> (n, NearSearch.ScanAll) :: (n, NearSearch.Grid) :: Nil)
            |> List.toVector

    def measuredFrames(): Int32 = 300

    /// 区間の頭の JIT と、群れが目標へ寄る前の形を捨てる。
    def warmupFrames(): Int32 = 120

    pub def initialWorld(segments: Vector[(Int32, NearSearch)]): World =
        { segments = segments, crowd = Crowd.start(fst(Vector.get(0, segments))), segment = 0, frameInSegment = 0, samples = Nil, nearSum = 0.0, done = false }

    def nsToMs(ns: Int64): Float64 = Int64.toFloat64(ns) / 1.0e6

    def sampleOf(frame: App.Frame, stepMs: Float64): Sample =
        let d = frame#diagnostics;
        { frameMs = frame#dt * 1000.0,
          stepMs = stepMs,
          submitMs = d |> Option.map(x -> nsToMs(x#submitNs)) |> Option.getWithDefault(0.0),
          swapMs = d |> Option.map(x -> nsToMs(x#swapNs)) |> Option.getWithDefault(0.0),
          gpuMs = d |> Option.flatMap(x -> x#gpuNs) |> Option.filter(ns -> ns > 0i64) |> Option.map(nsToMs),
          drawItems = d |> Option.map(x -> x#drawItems) |> Option.getWithDefault(0) }

    pub def step(frame: App.Frame, w: World): World \ IO =
        if (w#done) w
        else {
            let (moved, stepMs) = Timing.measureMs(() -> checked_ecast(Crowd.advance(snd(Vector.get(w#segment, w#segments)), w#crowd)));
            let measured = w#frameInSegment >= warmupFrames();
            let samples = if (measured) sampleOf(frame, stepMs) :: w#samples else w#samples;
            let nearSum = if (measured) w#nearSum + Crowd.nearPerEnemy(moved) else w#nearSum;
            if (w#frameInSegment + 1 >= warmupFrames() + measuredFrames()) {
                report(Vector.get(w#segment, w#segments), samples, nearSum);
                let next = w#segment + 1;
                let done = next >= Vector.length(w#segments);
                { crowd = if (done) moved else Crowd.start(fst(Vector.get(next, w#segments))), segment = next, frameInSegment = 0, samples = Nil, nearSum = 0.0, done = done | w }
            }
            else { crowd = moved, frameInSegment = w#frameInSegment + 1, samples = samples, nearSum = nearSum | w }
        }

    def report(segment: (Int32, NearSearch), samples: List[Sample], nearSum: Float64): Unit \ IO =
        let read = (pick, q) -> Timing.fmt3(Timing.percentile(q, samples |> List.map(pick)));
        let gpuSamples = samples |> List.filterMap(s -> s#gpuMs);
        // WhyNot: 測れないコマを 0 として数えない — timer query の結果が出ないコマが続くと中央値が嘘になる。
        let gpuText = if (List.isEmpty(gpuSamples)) "none" else Timing.fmt3(Timing.percentile(50, gpuSamples));
        let drawn = samples |> List.head |> Option.map(s -> s#drawItems) |> Option.getWithDefault(0);
        let near = Timing.fmt3(nearSum / Int32.toFloat64(Int32.max(1, List.length(samples))));
        println("[crowd2d] n=${fst(segment)} search=${snd(segment)} frame_p50=${read(s -> s#frameMs, 50)} frame_p95=${read(s -> s#frameMs, 95)} step_p50=${read(s -> s#stepMs, 50)} step_p95=${read(s -> s#stepMs, 95)} submit_p50=${read(s -> s#submitMs, 50)} swap_p50=${read(s -> s#swapMs, 50)} gpu_p50=${gpuText} draw_items=${drawn} near=${near}")

    pub def view(w: World): List[Render.PlacedItem] =
        let xs = w#crowd#xs;
        let ys = w#crowd#ys;
        List.range(0, Vector.length(xs))
            |> List.map(i -> { at = { x = Vector.get(i, xs), y = Vector.get(i, ys) }, item = Render.sprite("enemy", 10) })

    pub def go(): Unit \ IO =
        let segments = segmentsOf(loadCounts());
        run {
            App.make(initialWorld(segments))
                |> App.addSystem(step)
                |> App.withDiagnostics
                |> App.withView((_ctx, w) -> checked_ecast(view(w)))
                |> App.quitWhen((_frame, w) -> checked_ecast(w#done))
                |> App.launchForBench
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else CrowdBench.go()
