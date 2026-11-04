// GpuTimer — 1 コマの GPU の時間を GL_TIME_ELAPSED の query で測る（FrameDiagnostics.Diagnostics.gpuNs・gpuPasses）。
// 描き先（Pass か画面）を 1 つ描く間を query 1 つで囲み、コマの終わりに結果の出た古いコマから読む。
// 結果を待たないので、出てくるのは 1〜2 コマ前の値。query を作れない GL では以後囲まず、値は None のまま。
// WhyNot: GL_TIMESTAMP（glQueryCounter）で描き先の前後を打たない — macOS の GL（Metal の上の 4.1）は
//   GL_TIMESTAMP の counter bits が 0 で、結果がいつも 0 になる（GL_TIME_ELAPSED は測れる）。
// WhyNot: 描き先の query を入れ子にしない — GL_TIME_ELAPSED は同時に 1 つしか開けない。描き先は順に描くので足りる。
// 輪の読み方（どのコマを読むか・どれを捨てるか）は GL を呼ばない純粋な関数に分けてある（TestGpuTimer）。
mod GpuTimer {
    import org.lwjgl.opengl.GL15
    import org.lwjgl.opengl.GL33

    /// 描き先 1 つ（Pass の名前か "screen"）を描いた間を囲んだ query の番号。
    pub type alias Span = { name = String, queryId = Int32 }

    /// waiting = 囲み終えて結果を待つコマ（古い順。中の Span は描いた順）・current = 今のコマの Span（新しい順）・
    /// free = 読み終えて使い回す query・broken = 時間の query を使えない GL（以後は囲まない）。
    pub type alias Ring = { waiting = List[List[Span]], current = List[Span], free = List[Int32], broken = Bool }

    /// 結果を待つコマの数の上限。これより古いコマは読まずに捨てる（GPU が 3 コマ以上遅れても待たない）。
    pub def ringDepth(): Int32 = 3

    /// 空の輪。
    pub def emptyRing(): Ring = { waiting = Nil, current = Nil, free = Nil, broken = false }

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

    /// 読めたコマ 1 つの時間。gpuNs = 描き先ごとの時間の合計・passes = 描き先ごとの時間（描いた順）。
    /// elapsedOf = query の番号 → その間に GPU がかけた時間（ナノ秒）。Span が無いコマは None。
    pub def summarize(elapsedOf: Int32 -> Int64 \ ef, frame: List[Span]): Option[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ ef =
        if (List.isEmpty(frame)) None
        else {
            let passes = frame |> List.map(s -> (s#name, elapsedOf(s#queryId)));
            Some({ gpuNs = passes |> List.foldLeft((acc, p) -> acc + snd(p), 0i64), passes = passes })
        }

    /// コマの Span が使っていた query の番号。
    def queriesOf(frames: List[List[Span]]): List[Int32] =
        frames |> List.flatMap(List.map(s -> s#queryId))

    // ── GL を呼ぶ部分 ──

    /// 塗りのコアへ渡す GPU の時間を測る口（輪を 1 つ持つ）。
    pub def frameTimer(): RenderPaint.FrameTimer \ IO =
        let ringRef = Ref.fresh(Static, emptyRing());
        { measure = (name, f) -> measure(ringRef, name, f), endFrame = () -> endFrame(ringRef) }

    /// 描き先 name を描く f を query で囲み、今のコマに足す（query を使えなければ f だけ呼ぶ）。
    pub def measure(ringRef: Ref[Ring, Static], name: String, f: Unit -> Unit \ IO): Unit \ IO =
        match takeQuery(ringRef) {
            case None => f()
            case Some(id) =>
                GL15.glBeginQuery(GL33.GL_TIME_ELAPSED, id);
                f();
                GL15.glEndQuery(GL33.GL_TIME_ELAPSED);
                let ring = Ref.get(ringRef);
                Ref.put({ current = { name = name, queryId = id } :: ring#current | ring }, ringRef)
        }

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

    /// 画面のコマの終わり: 今のコマを待ちに回し、結果の出たコマのうち一番新しい物の時間を返す（無ければ None）。
    /// 読んだコマと捨てたコマの query は使い回す。
    pub def endFrame(ringRef: Ref[Ring, Static]): Option[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ IO =
        let ring = Ref.get(ringRef);
        let pushed = if (List.isEmpty(ring#current)) ring#waiting else List.append(ring#waiting, List.reverse(ring#current) :: Nil);
        let isReady = (id: Int32) -> GL15.glGetQueryObjecti(id, GL15.GL_QUERY_RESULT_AVAILABLE) != 0;
        let h = harvest(isReady, pushed);
        let elapsedOf = (id: Int32) -> GL33.glGetQueryObjecti64(id, GL15.GL_QUERY_RESULT);
        let newest = List.last(h#ready) |> Option.flatMap(summarize(elapsedOf));
        Ref.put({ waiting = h#waiting, current = Nil,
                  free = List.append(queriesOf(h#ready), List.append(queriesOf(h#dropped), ring#free)) | ring }, ringRef);
        newest
}
