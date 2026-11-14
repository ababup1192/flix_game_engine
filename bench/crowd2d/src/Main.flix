// 入口。敵の数 × 探し方の区間を順に回し、区間ごとに 1 行の JSON（BenchRun）を出して閉じる。
use fge::LwjglLayer

mod CrowdBench {
    use fge::{App, LwjglLayer, Render}
    use Crowd.NearSearch

    /// つまみ。segments = 区間ごとの敵の数と近くの敵の探し方・plan = 区間の段取り。
    pub type alias Config = { segments = Vector[(Int32, NearSearch)], plan = BenchRun.Plan }

    /// 外から来る物。now = 今の時刻（ms）・emit = 結果の行の出し先。
    pub type alias Host = { now = Unit -> Float64 \ IO, emit = String -> Unit \ IO }

    pub type alias World = { segments = Vector[(Int32, NearSearch)], plan = BenchRun.Plan, crowd = Crowd.Crowd, progress = BenchRun.Run, nearSum = Float64 }

    /// つまみの表（n = 敵の数のカンマ区切り・search = scan / grid / both・frames = 測るコマ数）を読む。
    // WhyNot: 全部と比べる形を既定から外さない — SpatialGrid の得を見るベンチで、比べる相手が黙って消える。20,000 体では search=grid を付ける。
    pub def configOf(knobs: Map[String, String]): Config =
        let searches = match Map.get("search", knobs) {
            case Some("scan") => NearSearch.ScanAll :: Nil
            case Some("grid") => NearSearch.Grid :: Nil
            case _            => NearSearch.ScanAll :: NearSearch.Grid :: Nil
        };
        let segments = BenchRun.intsKnob("n", Crowd.counts(), knobs)
            |> List.flatMap(n -> searches |> List.map(search -> (n, search))) |> List.toVector;
        { segments = segments, plan = BenchRun.planOf({ warmup = warmupFrames(), frames = 300, segments = Vector.length(segments) }, knobs) }

    /// 区間の頭の JIT と、群れが目標へ寄る前の形を捨てる。
    def warmupFrames(): Int32 = 120

    pub def initialWorld(config: Config): World =
        { segments = config#segments, plan = config#plan,
          crowd = Crowd.start(fst(Vector.get(0, config#segments))), progress = BenchRun.start(), nearSum = 0.0 }

    def knobsOf(w: World, segment: Int32): List[(String, String)] =
        let (n, search) = Vector.get(segment, w#segments);
        let near = w#nearSum / Int32.toFloat64(Int32.max(1, w#plan#measured));
        ("bench", BenchRun.quoted("crowd2d")) :: ("n", Int32.toString(n)) :: ("search", BenchRun.quoted("${search}")) ::
        ("near", BenchRun.fmt3(near)) :: Nil

    /// work = 規則 1 コマの時間。
    pub def step(host: Host, frame: App.Frame, w: World): World \ IO =
        if (w#progress#done) w
        else {
            let search = snd(Vector.get(w#progress#segment, w#segments));
            let (moved, stepMs) = BenchRun.timed(host#now, () -> checked_ecast(Crowd.advance(search, w#crowd)));
            let measuring = w#progress#frameInSegment >= w#plan#warmup;
            let counted = { nearSum = if (measuring) w#nearSum + Crowd.nearPerEnemy(moved) else w#nearSum | w };
            let progress = BenchRun.advance(w#plan, host#emit, knobsOf(counted), BenchRun.sampleOf(frame, stepMs), w#progress);
            if (progress#segment == w#progress#segment) { crowd = moved, progress = progress | counted }
            else { crowd = if (progress#done) moved else Crowd.start(fst(Vector.get(progress#segment, w#segments))),
                   progress = progress, nearSum = 0.0 | w }
        }

    pub def view(w: World): List[Render.PlacedItem] =
        let xs = w#crowd#xs;
        let ys = w#crowd#ys;
        List.range(0, Vector.length(xs))
            |> List.map(i -> { at = { x = Vector.get(i, xs), y = Vector.get(i, ys) }, item = Render.sprite("enemy", 10) })

    pub def go(): Unit \ IO =
        let config = configOf(BenchEnv.knobs(("COUNTS", "n") :: ("SEARCH", "search") :: ("FRAMES", "frames") :: ("DIAG", "diag") :: Nil));
        let host = { now = BenchEnv.nowMs, emit = BenchEnv.emit };
        run {
            App.make(initialWorld(config))
                |> App.addSystem(step(host))
                |> BenchRun.withDiagnostics(config#plan)
                |> App.withView((_ctx, w) -> checked_ecast(view(w)))
                |> App.quitWhen((_frame, w) -> checked_ecast(w#progress#done))
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
