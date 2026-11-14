// BenchEnv — デスクトップの入口だけが使う物（環境変数・時計・標準出力）。
// 直すのは bench/common の物。engine の根の make bench-common が sprite_stress・crowd2d・scene3d の src へ写す。
// WhyNot: BenchRun に入れない — ブラウザの組み立てが JVM の System へ届く。
mod BenchEnv {
    import java.lang.System

    /// (環境変数の名前, つまみの鍵) の表を読んでつまみの表にする。置いていない・空の環境変数は入れない。
    pub def knobs(names: List[(String, String)]): Map[String, String] \ IO =
        names |> List.foldLeft((acc, pair) -> {
            let value = System.getenv(fst(pair));
            if (Object.isNull(value) or value == "") acc else Map.insert(snd(pair), value, acc)
        }, Map.empty())

    /// 今の時刻（ms）。差だけに意味がある。
    pub def nowMs(): Float64 \ IO = Int64.toFloat64(System.nanoTime()) / 1.0e6

    pub def emit(line: String): Unit \ IO = println(line)
}
