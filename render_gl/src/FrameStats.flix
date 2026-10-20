// FrameStats — 実機の道（窓ありで遊ぶ時）の 1 コマの時間を測る。FLIX_GE_FRAME_STATS=1 で起動した時だけ数える。
// 塗る（renderFrame が GL へ命令を出し終えるまで）と、コマの間隔（前のコマの renderCommands からこのコマまで。
// 状態更新・View・塗り・swap の全部）の 2 つを、WINDOW コマごとに平均と p99 で 1 行に出す。
// 塗りのコアを触る前と後で、同じ場面・同じ機械のこの 1 行を比べる（docs/design/render-speed.md の段 4a）。
// 垂直同期で間隔が 16.7ms に張り付くので、間隔を比べる時は FLIX_GE_HIDDEN=1（隠し窓は vsync を待たない）で流す。
mod RenderFrameStats {
    import java.lang.System

    /// 数えている途中の値（外からは start と record だけで触る）。
    /// paint・gap はナノ秒の控え。filled は今の窓に溜まったコマ数、lastAt は前のコマの時刻（0 = まだ無い）。
    pub enum Stats(Array[Int64, Static], Array[Int64, Static], Array[Int32, Static], Array[Int64, Static])

    /// 何コマごとに 1 行出すか（60fps で 10 秒）。
    def window(): Int32 = 600

    /// 数え始める。
    pub def fresh(): Stats \ IO =
        Stats.Stats(Array.repeat(Static, window(), 0i64), Array.repeat(Static, window(), 0i64),
                    Array#{0} @ Static, Array#{0i64} @ Static)

    /// 1 コマ分を記録する。paintFrom・paintTo はそのコマの塗りの始まりと終わり（System.nanoTime）。
    /// 窓が埋まったら 1 行出して数え直す。
    pub def record(stats: Stats, paintFrom: Int64, paintTo: Int64): Unit \ IO =
        let Stats.Stats(paints, gaps, filled, lastAt) = stats;
        let prev = Array.get(0, lastAt);
        Array.put(paintFrom, 0, lastAt);
        if (prev == 0i64) ()
        else {
            let n = Array.get(0, filled);
            Array.put(paintTo - paintFrom, n, paints);
            Array.put(paintFrom - prev, n, gaps);
            if (n + 1 < window()) Array.put(n + 1, 0, filled)
            else {
                Array.put(0, 0, filled);
                println("[frame-stats] ${Int32.toString(window())} コマ: 塗り ${summary(paints)}・間隔 ${summary(gaps)}")
            }
        }

    /// 平均と p99（ミリ秒・小数 2 桁）。
    def summary(samples: Array[Int64, Static]): String \ IO =
        let sorted = Array.toList(samples) |> List.sort;
        let total = List.foldLeft((acc, v) -> acc + v, 0i64, sorted);
        let ms = (v: Int64) -> Int64.toFloat64(v) / 1000000.0;
        let p99 = List.drop(window() * 99 / 100, sorted) |> List.head |> Option.getWithDefault(0i64);
        "avg ${fmt(ms(total) / Int32.toFloat64(window()))}ms / p99 ${fmt(ms(p99))}ms"

    def fmt(v: Float64): String = Float64.toString(Float64.round(v * 100.0) / 100.0)

    /// FLIX_GE_FRAME_STATS が空でない値なら数える（withLwjgl の頭で 1 回だけ読む）。
    pub def enabled(): Bool \ IO =
        let value = System.getenv("FLIX_GE_FRAME_STATS");
        not Object.isNull(value) and value != ""
}
