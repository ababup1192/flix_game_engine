// GpuTimer — 1 コマの GPU の時間を GL_TIME_ELAPSED の query で測る（FrameDiagnostics.Diagnostics.gpuNs・gpuPasses）。
// 描き先（Pass か画面）を 1 つ描く間を query 1 つで囲み、コマの終わりに結果の出た古いコマから読む。
// 結果を待たないので、出てくるのは 1〜2 コマ前の値。query を作れない GL では以後囲まず、値は None のまま。
// 囲むのは sampleInterval() コマに 1 回だけで、間のコマは最後に読めた値をそのまま返す（環境変数 FLIX_GE_GPU_TIMER_EVERY=<コマ数> で替える。1 なら毎コマ）。
// WhyNot: 毎コマ囲まない — glEndQuery がドライバに溜めた命令を流させ、GPU の仕事が軽い場面で 1 コマが倍になる（診断を付けた時だけ遅いゲームになる）。
// WhyNot: GL_TIMESTAMP（glQueryCounter）で描き先の前後を打たない — macOS の GL（Metal の上の 4.1）は
//   GL_TIMESTAMP の counter bits が 0 で、結果がいつも 0 になる（GL_TIME_ELAPSED は測れる）。
// 描き先の中で測る区間（3D の影の地図・場面）は、外の query をそこで閉じ、区間を測り、外の名前で開き直す（GL_TIME_ELAPSED は同時に 1 つしか開けない）。
// そのため描き先の時間は中の区間を引いた残りで、同じ名前の切れ端は読む時に足し合わせる（mergeByName）。
// 輪の読み方（どのコマを読むか・どれを捨てるか）は GL を呼ばない純粋な関数に分けてある（TestGpuTimer）。
mod GpuTimer {
    import org.lwjgl.opengl.GL15
    import org.lwjgl.opengl.GL33
    import java.lang.System

    /// 描き先 1 つ（Pass の名前か "screen"）を描いた間を囲んだ query の番号。
    pub type alias Span = { name = String, queryId = Int32 }

    /// waiting = 囲み終えて結果を待つコマ（古い順。中の Span は描いた順）・current = 今のコマの Span（新しい順）・
    /// free = 読み終えて使い回す query・broken = 時間の query を使えない GL（以後は囲まない）・
    /// frame = 画面のコマの通し番号（囲むコマを選ぶ）・latest = 最後に読めたコマの時間（囲まないコマにも返す）。
    /// open = 今囲んでいる名前（内側が頭）・active = query を 1 つ開いているか・samples = takeSamples の後に読めたコマの時間（新しい順）。
    pub type alias Ring = { waiting = List[List[Span]], current = List[Span], free = List[Int32], broken = Bool,
                            frame = Int32, latest = Option[FrameTime], open = List[String], active = Bool, samples = List[FrameTime] }

    /// 読めたコマ 1 つの時間。gpuNs = 描き先ごとの時間の合計・passes = 描き先ごとの時間（描いた順）。
    pub type alias FrameTime = { gpuNs = Int64, passes = List[(String, Int64)] }

    /// 結果を待つコマの数の上限。これより古いコマは読まずに捨てる（GPU が 3 コマ以上遅れても待たない）。
    pub def ringDepth(): Int32 = 3

    /// 空の輪。
    pub def emptyRing(): Ring = { waiting = Nil, current = Nil, free = Nil, broken = false, frame = 0, latest = None,
                                  open = Nil, active = false, samples = Nil }

    /// takeSamples が返すコマの時間の数の上限（古い物から捨てる）。
    def sampleLimit(): Int32 = 256

    /// 何コマに 1 回囲むかの既定。60 fps で 1 秒に 4 回ほど値が替わる。
    pub def defaultSampleInterval(): Int32 = 16

    /// FLIX_GE_GPU_TIMER_EVERY の字から、何コマに 1 回囲むかを決める（無い・数でない時は既定・1 未満は 1）。
    pub def sampleIntervalOf(text: Option[String]): Int32 =
        text |> Option.flatMap(Int32.fromString) |> Option.map(Int32.max(1)) |> Option.getWithDefault(defaultSampleInterval())

    /// 通し番号 frame のコマを囲むか（every コマに 1 回・最初のコマは囲む）。
    pub def isSampledFrame(every: Int32, frame: Int32): Bool = Int32.remainder(frame, every) == 0

    // ── 純粋な部分 ──

    /// 待っているコマを古い順に見て、結果の出たコマ（全部の query が isReady）を先頭から取り出す。
    /// 取り出した後も ringDepth() を超えて残るコマは、古い物から読まずに捨てる。
    /// ready = 読めるコマ（古い順）・waiting = 残り・dropped = 捨てたコマ（query は使い回す）。
    pub def harvest(isReady: Int32 -> Bool \ ef, waiting: List[List[Span]]): { ready = List[List[Span]], waiting = List[List[Span]], dropped = List[List[Span]] } \ ef =
        let frameReady = (frame: List[Span]) -> List.forAll(s -> isReady(s#queryId), frame);
        let readyCount = List.takeWhile(frameReady, waiting) |> List.length;
        let ready = List.take(readyCount, waiting);
        let rest = List.drop(readyCount, waiting);
        let over = Int32.max(0, List.length(rest) - ringDepth());
        { ready = ready, waiting = List.drop(over, rest), dropped = List.take(over, rest) }

    /// 読めたコマ 1 つの時間。elapsedOf = query の番号 → その間に GPU がかけた時間（ナノ秒）。Span が無いコマは None。
    pub def summarize(elapsedOf: Int32 -> Int64 \ ef, frame: List[Span]): Option[FrameTime] \ ef =
        if (List.isEmpty(frame)) None
        else {
            let passes = frame |> List.map(s -> (s#name, elapsedOf(s#queryId)));
            Some({ gpuNs = passes |> List.foldLeft((acc, p) -> acc + snd(p), 0i64), passes = mergeByName(passes) })
        }

    /// pass ごとの始めと終わりの時刻 (名前, 始め, 終わり)（積んだ順）を、前の pass の終わりより後の分だけの時間にする。
    /// タイル型の GPU（M 系・Mali）は次の pass を前の pass の終わりを待たずに始めるので、始めから終わりまでを足すとコマの時間を超える。
    /// 前の pass の終わりから数えると、重なった分は先に終わった pass に入り、和は最初の始めから最後の終わりまで（間の空きを除く）になる。
    pub def exclusiveTimes(stamps: List[(String, Int64, Int64)]): List[(String, Int64)] = exclusiveTimesFrom(None, stamps)

    /// exclusiveTimes の、最初の pass を start（前のコマの最後の pass の終わり。無ければ自分の始め）より後の分だけにする形。
    pub def exclusiveTimesFrom(start: Option[Int64], stamps: List[(String, Int64, Int64)]): List[(String, Int64)] =
        let step = (acc: (Int64, List[(String, Int64)]), s: (String, Int64, Int64)) -> {
            let (lastEnd, out) = acc;
            let (name, begin, end) = s;
            let counted = Int64.max(begin, lastEnd);
            (Int64.max(lastEnd, end), (name, Int64.max(0i64, end - counted)) :: out)
        };
        stamps |> List.foldLeft(step, (Option.getWithDefault(Int64.minValue(), start), Nil)) |> snd |> List.reverse

    /// 同じ名前の時間を足し合わせる（並びは名前が初めて出た順）。
    pub def mergeByName(passes: List[(String, Int64)]): List[(String, Int64)] =
        let totals = passes |> List.foldLeft((m, p) -> Map.insertWith((a, b) -> a + b, fst(p), snd(p), m), Map.empty());
        namesInOrder(passes) |> List.map(name -> (name, Map.getWithDefault(name, 0i64, totals)))

    /// passes の名前（初めて出た順・重なりなし）。
    def namesInOrder(passes: List[(String, Int64)]): List[String] =
        let step = (acc: (Set[String], List[String]), p: (String, Int64)) -> {
            let (seen, names) = acc;
            if (Set.memberOf(fst(p), seen)) acc else (Set.insert(fst(p), seen), fst(p) :: names)
        };
        passes |> List.foldLeft(step, (Set.empty(), Nil)) |> snd |> List.reverse

    /// 読めたコマの時間の列から、名前ごとの中央値（並びは名前が初めて出た順）と全体の中央値。列が空なら None。
    pub def medianOf(samples: List[FrameTime]): Option[FrameTime] =
        if (List.isEmpty(samples)) None
        else {
            let all = samples |> List.flatMap(t -> t#passes);
            let byName = all |> List.foldLeft((m, p) -> Map.insertWith(List.append, fst(p), snd(p) :: Nil, m), Map.empty());
            Some({ gpuNs = median(samples |> List.map(t -> t#gpuNs)),
                   passes = namesInOrder(all) |> List.map(name -> (name, median(Map.getWithDefault(name, Nil, byName)))) })
        }

    def median(xs: List[Int64]): Int64 =
        let sorted = Sort.sortStable(xs);
        List.nth(List.length(sorted) / 2, sorted) |> Option.getWithDefault(0i64)

    /// FrameStats の行に足す字（名前ごとの中央値の ms・小数 2 桁と、読めたコマの数）。読めたコマが無ければ空の字。
    pub def samplesText(samples: List[FrameTime]): String = match medianOf(samples) {
        case None    => ""
        case Some(t) =>
            let ms = (ns: Int64) -> Float64.toString(Float64.round(Int64.toFloat64(ns) / 10000.0) / 100.0);
            let parts = t#passes |> List.map(p -> "${fst(p)} ${ms(snd(p))}") |> String.intercalate(", ");
            "・GPU ${ms(t#gpuNs)}ms（${parts}・${Int32.toString(List.length(samples))} 回）"
    }

    /// コマの Span が使っていた query の番号。
    def queriesOf(frames: List[List[Span]]): List[Int32] =
        frames |> List.flatMap(List.map(s -> s#queryId))

    // ── GL を呼ぶ部分 ──

    /// 塗りのコアへ渡す GPU の時間を測る口（輪を 1 つ持つ）。囲む間隔は環境変数から読む。
    pub def frameTimer(): RenderPaint.FrameTimer \ IO =
        let every = sampleIntervalOf(Object.toOption(System.getenv("FLIX_GE_GPU_TIMER_EVERY")));
        let ringRef = Ref.fresh(Static, emptyRing());
        { measure = (name, f) -> measure(ringRef, every, name, f), endFrame = () -> endFrame(ringRef), takeSamples = () -> takeSamples(ringRef) }

    /// 囲むコマなら、描き先 name を描く f を query で囲んで今のコマに足す（囲まないコマと、query を使えない GL では f だけ呼ぶ）。
    /// 外の measure の中で呼ばれたら、外の query を閉じて f を測り、外の名前で開き直す。
    pub def measure(ringRef: Ref[Ring, Static], every: Int32, name: String, f: Unit -> Unit \ IO): Unit \ IO =
        let ring = Ref.get(ringRef);
        if (ring#broken or not isSampledFrame(every, ring#frame)) f()
        else {
            closeQuery(ringRef);
            let opened = Ref.get(ringRef);
            Ref.put({ open = name :: opened#open | opened }, ringRef);
            openQuery(ringRef, name);
            f();
            closeQuery(ringRef);
            let after = Ref.get(ringRef);
            let outer = List.drop(1, after#open);
            Ref.put({ open = outer | after }, ringRef);
            List.head(outer) |> Option.forEach(openQuery(ringRef))
        }

    /// query を 1 つ取って name の区間として開き、今のコマに足す（取れなければ開かない）。
    def openQuery(ringRef: Ref[Ring, Static], name: String): Unit \ IO =
        match takeQuery(ringRef) {
            case None     => ()
            case Some(id) =>
                GL15.glBeginQuery(GL33.GL_TIME_ELAPSED, id);
                let ring = Ref.get(ringRef);
                Ref.put({ current = { name = name, queryId = id } :: ring#current, active = true | ring }, ringRef)
        }

    /// 開いている query があれば閉じる。
    def closeQuery(ringRef: Ref[Ring, Static]): Unit \ IO =
        let ring = Ref.get(ringRef);
        if (ring#active) {
            GL15.glEndQuery(GL33.GL_TIME_ELAPSED);
            Ref.put({ active = false | ring }, ringRef)
        } else ()

    /// 前に呼んでから読めたコマの時間（古い順）を返して空にする。
    pub def takeSamples(ringRef: Ref[Ring, Static]): List[FrameTime] \ IO =
        let ring = Ref.get(ringRef);
        Ref.put({ samples = Nil | ring }, ringRef);
        List.reverse(ring#samples)

    /// 使い回す query を 1 つ取る。無ければ作る（作れない・時間を数えられない GL なら None。以後は取らない）。
    def takeQuery(ringRef: Ref[Ring, Static]): Option[Int32] \ IO =
        let ring = Ref.get(ringRef);
        if (ring#broken) None
        else match ring#free {
            case head :: tail => Ref.put({ free = tail | ring }, ringRef); Some(head)
            case Nil =>
                let id = GL15.glGenQueries();
                if (id == 0 or GL15.glGetQueryi(GL33.GL_TIME_ELAPSED, GL15.GL_QUERY_COUNTER_BITS) == 0) {
                    Ref.put({ broken = true | ring }, ringRef); None
                } else Some(id)
        }

    /// 画面のコマの終わり: 今のコマを待ちに回し、結果の出たコマのうち一番新しい物の時間を控えて、最後に読めた時間を返す（まだ 1 つも読めていなければ None）。
    /// 読んだコマと捨てたコマの query は使い回す。
    pub def endFrame(ringRef: Ref[Ring, Static]): Option[FrameTime] \ IO =
        let ring = Ref.get(ringRef);
        let pushed = if (List.isEmpty(ring#current)) ring#waiting else List.append(ring#waiting, List.reverse(ring#current) :: Nil);
        let isReady = (id: Int32) -> GL15.glGetQueryObjecti(id, GL15.GL_QUERY_RESULT_AVAILABLE) != 0;
        let h = harvest(isReady, pushed);
        let elapsedOf = (id: Int32) -> GL33.glGetQueryObjecti64(id, GL15.GL_QUERY_RESULT);
        let newest = List.last(h#ready) |> Option.flatMap(summarize(elapsedOf));
        let latest = Option.withDefault(default = ring#latest, newest);
        let samples = match newest {
            case Some(t) => List.take(sampleLimit(), t :: ring#samples)
            case None    => ring#samples
        };
        Ref.put({ waiting = h#waiting, current = Nil, frame = ring#frame + 1, latest = latest, samples = samples,
                  free = List.append(queriesOf(h#ready), List.append(queriesOf(h#dropped), ring#free)) | ring }, ringRef);
        latest
}
