// RenderPaint.Internal.SkippedDraws — WebGPU の描き手がまだ描けずに飛ばした物の、種類ごとの回数の表。
// 知らせるのは呼ぶ側（add が初めての種類かを返し、endFrame が画面のコマが reportFrame() に届いたコマで表の字を返す）。
// 回数の数え方は種類ごとに呼ぶ側が決める（3D の物は物の数・場面の物は場面の数・2D の行は行の数。コマごとに足す）。
pub mod RenderPaint.Internal.SkippedDraws {

    /// counts = 種類 → 飛ばした回数・frames = 0 番が数えた画面のコマの数。
    pub type alias Counts = { counts = Ref[Map[String, Int64], Static], frames = Array[Int64, Static] }

    /// 表を出す画面のコマ（起動の画面のコマも数える）。
    pub def reportFrame(): Int64 = 300i64

    pub def fresh(): Counts \ IO = { counts = Ref.fresh(Static, Map.empty()), frames = Array#{0i64} @ Static }

    /// kind を n 回飛ばしたと数え、初めての種類なら true（n が 0 以下なら数えず false）。
    pub def add(c: Counts, kind: String, n: Int32): Bool \ IO =
        if (n <= 0) false
        else {
            let held = Ref.get(c#counts);
            let before = Map.get(kind, held);
            Ref.put(Map.insert(kind, Option.getWithDefault(0i64, before) + Int32.toInt64(n), held), c#counts);
            Option.isEmpty(before)
        }

    /// 画面のコマを 1 つ数え、reportFrame() に届いたコマなら表の字を返す（飛ばした物が無ければ None）。
    pub def endFrame(c: Counts): Option[String] \ IO =
        let frames = Array.get(0, c#frames) + 1i64;
        Array.put(frames, 0, c#frames);
        if (frames == reportFrame()) tableOf(c, "起動から ${Int64.toString(frames)} コマ") else None

    /// 今までの表の字（飛ばした物が無ければ None）。when = いつの表か。
    pub def tableOf(c: Counts, when: String): Option[String] \ IO =
        let rows = Map.toList(Ref.get(c#counts));
        if (List.isEmpty(rows)) None else Some(buildTable(when, Array.get(0, c#frames), rows))

    /// 種類ごとの回数の表の字（回数の多い順・同じ回数は種類の名前の順）。frames = 数えた画面のコマの数（1 コマあたりの回数を割り出す）。
    pub def buildTable(when: String, frames: Int64, rows: List[(String, Int64)]): String =
        let sorted = Sort.sortStableBy(row -> 0i64 - snd(row), Sort.sortStableBy(fst, rows));
        let perFrame = (n: Int64) -> if (frames <= 0i64) "-" else {
            let tenths = (n * 10i64) / frames;
            "${Int64.toString(tenths / 10i64)}.${Int64.toString(Int64.remainder(tenths, 10i64))}"
        };
        let lines = sorted |> List.map(match (kind, n) -> "  ${kind}: ${Int64.toString(n)} 回（1 コマあたり ${perFrame(n)}）");
        String.intercalate("\n", "[webgpu] まだ描けずに飛ばした物（${when}・種類ごとの回数）:" :: lines)
}
