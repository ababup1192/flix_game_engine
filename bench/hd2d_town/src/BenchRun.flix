// BenchRun — 区間を順に回して 1 コマの値を集め、区間ごとに 1 行の JSON にする。
// デスクトップとブラウザの入口が同じ物を使う（JVM だけの API を呼ばない）。
// 直すのは bench/common の物。engine の根の make bench-common が sprite_stress・crowd2d・scene3d の src へ写す。
// WhyNot: src へ symlink しない — flix build（headless-run・gl-capture が使う）は symlink の .flix を読まない。
mod BenchRun {
    use fge::{App, FrameDiagnostics, RenderUtil, Sort}

    /// 1 コマの値。frameMs = 前のコマの全部・workMs = ベンチが自分で測った区間（無ければ 0）・diagnostics = 前のコマの診断。
    pub type alias Sample = { frameMs = Float64, workMs = Float64, diagnostics = Option[FrameDiagnostics.Diagnostics] }

    /// warmup = 区間の頭で捨てるコマ数・measured = 測るコマ数・segments = 区間の数・diagnostics = 描く側の診断を集めるか。
    pub type alias Plan = { warmup = Int32, measured = Int32, segments = Int32, diagnostics = Bool }

    /// つまみの表から段取りを作る（frames = 1 区間で測るコマ数・diag = 0 で診断を集めない）。
    // WhyNot: 診断をいつも付けない — GPU の時間の query が 1 コマを重くする。その重さを見るには付けない回と比べる。
    pub def planOf(shape: { warmup = Int32, frames = Int32, segments = Int32 }, knobs: Map[String, String]): Plan =
        { warmup = shape#warmup, measured = intKnob("frames", shape#frames, knobs), segments = shape#segments,
          diagnostics = Map.get("diag", knobs) != Some("0") }

    /// 段取りが診断を集めるなら App.withDiagnostics を付ける。
    pub def withDiagnostics(plan: Plan, app: App.App[w, ef]): App.App[w, ef] =
        if (plan#diagnostics) App.withDiagnostics(app) else app

    pub type alias Run = { segment = Int32, frameInSegment = Int32, samples = List[Sample], done = Bool }

    pub def start(): Run = { segment = 0, frameInSegment = 0, samples = Nil, done = false }

    pub def sampleOf(frame: App.Frame, workMs: Float64): Sample =
        { frameMs = frame#dt * 1000.0, workMs = workMs, diagnostics = frame#diagnostics }

    /// 1 コマ進める。出す行は 3 つ: 測り始めのコマに `[bench] begin`・区間の終わりに `[bench] result {…}`・全部の終わりに `[bench] done`。
    /// knobsOf = 区間の番号 → その区間のつまみ（値は JSON の字。数はそのまま・字は quoted で包む）。
    pub def advance(plan: Plan, emit: String -> Unit \ ef, knobsOf: Int32 -> List[(String, String)], sample: Sample, r: Run): Run \ ef =
        if (r#done) r
        else {
            let measuring = r#frameInSegment >= plan#warmup;
            if (r#frameInSegment == plan#warmup) emit("[bench] begin") else ();
            let samples = if (measuring) sample :: r#samples else r#samples;
            if (r#frameInSegment + 1 >= plan#warmup + plan#measured) {
                emit("[bench] result ${jsonObject(List.append(knobsOf(r#segment), summaryFields(samples)))}");
                let next = r#segment + 1;
                let done = next >= plan#segments;
                if (done) emit("[bench] done") else ();
                { segment = next, frameInSegment = 0, samples = Nil, done = done }
            } else
                { frameInSegment = r#frameInSegment + 1, samples = samples | r }
        }

    /// work の値と、かかった時間（ms）。now = 今の時刻（ms）。
    // WhyNot: 純粋な呼び出しを let で 2 つの時計の間に書かない — コンパイラが使う所まで動かして、時間が 0 に見える。
    pub def timed(now: Unit -> Float64 \ ef, work: Unit -> a \ ef): (a, Float64) \ ef =
        let began = now();
        let value = work();
        (value, now() - began)

    // ── 集計 ──

    /// 値の列の q パーセント点（q は 0〜100）。空なら 0。
    pub def percentile(q: Int32, values: List[Float64]): Float64 =
        let sorted = Sort.sortStable(values) |> List.toVector;
        let count = Vector.length(sorted);
        if (count == 0) 0.0 else Vector.get(Int32.min(count - 1, count * q / 100), sorted)

    def mean(values: List[Float64]): Float64 =
        if (List.isEmpty(values)) 0.0 else List.foldLeft((acc, x) -> acc + x, 0.0, values) / Int32.toFloat64(List.length(values))

    def nsToMs(ns: Int64): Float64 = Int64.toFloat64(ns) / 1.0e6

    /// 区間の集計（鍵と JSON の値）。時間は ms。診断の無い描き手では submit・swap が 0・gpu が null。
    pub def summaryFields(samples: List[Sample]): List[(String, String)] =
        let diagnostics = samples |> List.filterMap(s -> s#diagnostics);
        let frames = samples |> List.map(s -> s#frameMs);
        let work = samples |> List.map(s -> s#workMs);
        let submit = diagnostics |> List.map(d -> nsToMs(d#submitNs));
        let swap = diagnostics |> List.map(d -> nsToMs(d#swapNs));
        // WhyNot: 測れないコマを 0 として数えない — timer query の結果が出ないコマが続くと中央値が嘘になる。
        let gpu = diagnostics |> List.filterMap(d -> d#gpuNs) |> List.filter(ns -> ns > 0i64) |> List.map(nsToMs);
        let counts = diagnostics |> List.map(d -> d#scene3dCounts);
        let draw2d = diagnostics |> List.map(d -> d#draw2dCounts);
        let middle = pick -> middleOf(List.map(pick, counts));
        ("diag", if (List.isEmpty(diagnostics)) "0" else "1") ::
        ("frames", Int32.toString(List.length(samples))) ::
        ("frame_avg", fmt3(mean(frames))) :: ("frame_p50", fmt3(percentile(50, frames))) ::
        ("frame_p95", fmt3(percentile(95, frames))) :: ("frame_p99", fmt3(percentile(99, frames))) ::
        ("work_p50", fmt3(percentile(50, work))) :: ("work_p95", fmt3(percentile(95, work))) ::
        ("submit_p50", fmt3(percentile(50, submit))) :: ("submit_p95", fmt3(percentile(95, submit))) ::
        ("swap_p50", fmt3(percentile(50, swap))) ::
        ("gpu_p50", if (List.isEmpty(gpu)) "null" else fmt3(percentile(50, gpu))) ::
        ("gpu_frames", Int32.toString(List.length(gpu))) ::
        ("draw_items", Int32.toString(diagnostics |> List.head |> Option.map(d -> d#drawItems) |> Option.getWithDefault(0))) ::
        ("instances", middle(c -> c#instances)) :: ("drawn", middle(c -> c#drawn)) :: ("draw_calls", middle(c -> c#drawCalls)) ::
        ("cpu_phases", jsonObject(phaseFields(counts))) ::
        ("draw2d_calls", middleOf(List.map(c -> c#drawCalls, draw2d))) ::
        ("draw2d_breaks", jsonObject(breakFields(List.map(c -> FrameDiagnostics.draw2dBreakList(c#batchBreaks), draw2d)))) ::
        ("draw3d_breaks", jsonObject(breakFields(List.map(c -> FrameDiagnostics.scene3dBreakList(c#batchBreaks), counts)))) :: Nil

    /// 数の列の中央値の字（空なら 0）。
    def middleOf(values: List[Int32]): String =
        Int32.toString(RenderUtil.floatToInt32(percentile(50, List.map(Int32.toFloat64, values))))

    /// draw call がまとまらなかった理由ごとの中央値（コマごとの (理由, 数) の並びから。0 の理由は出さない・理由の順は診断の欄の順）。
    def breakFields(frames: List[List[(String, Int32)]]): List[(String, String)] =
        let byName = frames
            |> List.flatten
            |> List.foldLeft((acc, reason) -> Map.insertWith(List.append, fst(reason), snd(reason) :: Nil, acc), Map.empty());
        let names = frames |> List.head |> Option.getWithDefault(Nil) |> List.map(fst);
        names |> List.map(name -> (name, middleOf(Map.getWithDefault(name, Nil, byName)))) |> List.filter(field -> snd(field) != "0")

    /// 3D の描き手の CPU の区間ごとの中央値（初めて出た順）。
    def phaseFields(counts: List[FrameDiagnostics.Scene3dCounts]): List[(String, String)] =
        let byName = counts
            |> List.flatMap(c -> c#cpuPhases)
            |> List.foldLeft((acc, phase) -> Map.insertWith(List.append, fst(phase), nsToMs(snd(phase)) :: Nil, acc), Map.empty());
        let names = counts |> List.flatMap(c -> c#cpuPhases |> List.map(fst)) |> List.distinct;
        names |> List.map(name -> (name, fmt3(percentile(50, Map.getWithDefault(name, Nil, byName)))))

    // ── JSON の字 ──

    /// 小数 3 桁の字。
    pub def fmt3(x: Float64): String =
        let thousandths = RenderUtil.floatToInt32(Float64.abs(x) * 1000.0);
        let sign = if (x < 0.0 and thousandths > 0) "-" else "";
        "${sign}${thousandths / 1000}.${String.padLeft(3, '0', "${Int32.modulo(thousandths, 1000)}")}"

    /// JSON の字の値。
    // WhyNot: 逆斜線と引用符を逃がさない — つまみの値は、ここへ来る前に数か決まった語へ読み替えてある。
    pub def quoted(text: String): String = "\"${text}\""

    pub def jsonObject(fields: List[(String, String)]): String =
        "{${fields |> List.map(f -> "${quoted(fst(f))}:${snd(f)}") |> String.intercalate(",")}}"

    // ── つまみ ──

    /// [鍵1, 値1, 鍵2, 値2, …] の並びをつまみの表にする（ブラウザの URL の query）。
    pub def knobsOfPairs(flat: List[String]): Map[String, String] = match flat {
        case key :: value :: rest => Map.insert(key, value, knobsOfPairs(rest))
        case _                    => Map.empty()
    }

    /// 数のつまみ。無い・数でない時は fallback。
    pub def intKnob(key: String, fallback: Int32, knobs: Map[String, String]): Int32 =
        Map.get(key, knobs) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(fallback)

    /// カンマで区切った数のつまみ。無い・1 つも読めない時は fallback。
    pub def intsKnob(key: String, fallback: List[Int32], knobs: Map[String, String]): List[Int32] =
        let read = Map.get(key, knobs)
            |> Option.map(text -> String.split(regex = ",", text) |> List.filterMap(Int32.fromString))
            |> Option.getWithDefault(Nil);
        if (List.isEmpty(read)) fallback else read
}
