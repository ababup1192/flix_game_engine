// GpuTimer — 1 コマの GPU の時間を GL_TIMESTAMP の query で測る（FrameDiagnostics.Diagnostics.gpuNs・gpuPasses）。
// 描き先（Pass か画面）を描く前後に timestamp を 1 つずつ打ち、コマの終わりに結果の出た古いコマから読む。
// 結果を待たないので、出てくるのは 1〜2 コマ前の値。glGenQueries が 0 を返した時は以後打たず、値は None のまま。
// timer query は GL 3.3 の core にあり、窓は 3.3 core で作るので、query を打てない GL はここまで来ない。
// 輪の読み方（どのコマを読むか・どれを捨てるか）は GL を呼ばない純粋な関数に分けてある（TestGpuTimer）。
mod GpuTimer {
    import org.lwjgl.opengl.GL15
    import org.lwjgl.opengl.GL33

    /// 描き先 1 つ（Pass の名前か "screen"）を描いた前後の query の番号。
    pub type alias Span = { name = String, begin = Int32, end = Int32 }

    /// waiting = 打ち終えて結果を待つコマ（古い順。中の Span は描いた順）・current = 今のコマの Span（新しい順）・
    /// free = 読み終えて使い回す query・broken = query を作れなかった（以後は打たない）。
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
        let frameReady = (frame: List[Span]) -> List.forAll(s -> isReady(s#begin) and isReady(s#end), frame);
        let readyCount = List.takeWhile(frameReady, waiting) |> List.length;
        let ready = List.take(readyCount, waiting);
        let rest = List.drop(readyCount, waiting);
        let over = Int32.max(0, List.length(rest) - ringDepth());
        { ready = ready, waiting = List.drop(over, rest), dropped = List.take(over, rest) }

    /// 読めたコマ 1 つの時間。gpuNs = 最初の描き先の始まりから最後の描き先の終わりまで・passes = 描き先ごとの時間（描いた順）。
    /// timeOf = query の番号 → GPU の時刻（ナノ秒）。Span が無いコマは None。
    pub def summarize(timeOf: Int32 -> Int64 \ ef, frame: List[Span]): Option[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ ef =
        match (List.head(frame), List.last(frame)) {
            case (Some(first), Some(last)) =>
                Some({ gpuNs = timeOf(last#end) - timeOf(first#begin),
                       passes = frame |> List.map(s -> (s#name, timeOf(s#end) - timeOf(s#begin))) })
            case _ => None
        }

    /// コマの Span が使っていた query の番号。
    def queriesOf(frames: List[List[Span]]): List[Int32] =
        frames |> List.flatMap(List.flatMap(s -> s#begin :: s#end :: Nil))

    // ── GL を呼ぶ部分 ──

    /// timestamp を 1 つ打ち、その query の番号を返す（作れなければ None。以後は打たない）。
    pub def stamp(ringRef: Ref[Ring, Static]): Option[Int32] \ IO =
        let ring = Ref.get(ringRef);
        if (ring#broken) None
        else {
            let (id, free) = match ring#free {
                case head :: tail => (head, tail)
                case Nil          => (GL15.glGenQueries(), Nil)
            };
            if (id == 0) { Ref.put({ broken = true | ring }, ringRef); None }
            else {
                GL33.glQueryCounter(id, GL33.GL_TIMESTAMP);
                Ref.put({ free = free | ring }, ringRef);
                Some(id)
            }
        }

    /// 描き先 name を描いた前後の query を今のコマに足す（どちらかが打てなかったら足さない）。
    pub def addSpan(ringRef: Ref[Ring, Static], name: String, begin: Option[Int32], end: Option[Int32]): Unit \ IO =
        match (begin, end) {
            case (Some(b), Some(e)) =>
                let ring = Ref.get(ringRef);
                Ref.put({ current = { name = name, begin = b, end = e } :: ring#current | ring }, ringRef)
            case _ => ()
        }

    /// 画面のコマの終わり: 今のコマを待ちに回し、結果の出たコマのうち一番新しい物の時間を返す（無ければ None）。
    /// 読んだコマと捨てたコマの query は使い回す。
    pub def endFrame(ringRef: Ref[Ring, Static]): Option[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ IO =
        let ring = Ref.get(ringRef);
        let pushed = if (List.isEmpty(ring#current)) ring#waiting else List.append(ring#waiting, List.reverse(ring#current) :: Nil);
        let isReady = (id: Int32) -> GL15.glGetQueryObjecti(id, GL15.GL_QUERY_RESULT_AVAILABLE) != 0;
        let h = harvest(isReady, pushed);
        let timeOf = (id: Int32) -> GL33.glGetQueryObjecti64(id, GL15.GL_QUERY_RESULT);
        let newest = List.last(h#ready) |> Option.flatMap(summarize(timeOf));
        Ref.put({ waiting = h#waiting, current = Nil,
                  free = List.append(queriesOf(h#ready), List.append(queriesOf(h#dropped), ring#free)) | ring }, ringRef);
        newest
}
