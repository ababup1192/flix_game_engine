// Timing — 計測の値を並べて読む小物。
mod Timing {
    use fge::Sort
    use fge::RenderUtil

    import java.lang.System

    /// work の値と、かかった時間（ms）。
    // WhyNot: 純粋な呼び出しを let で 2 つの時計の間に書かない — コンパイラが使う所まで動かして、時間が 0 に見える。
    pub def measureMs(work: Unit -> a \ IO): (a, Float64) \ IO =
        let began = System.nanoTime();
        let value = work();
        (value, Int64.toFloat64(System.nanoTime() - began) / 1.0e6)

    /// 値の列の q パーセント点（q は 0〜100）。空なら 0。
    pub def percentile(q: Int32, samples: List[Float64]): Float64 =
        let sorted = Sort.sortStable(samples) |> List.toVector;
        let count = Vector.length(sorted);
        if (count == 0) 0.0 else Vector.get(Int32.min(count - 1, count * q / 100), sorted)

    /// 小数 3 桁の文字列。
    pub def fmt3(x: Float64): String =
        let thousandths = RenderUtil.floatToInt32(x * 1000.0);
        let frac = Int32.modulo(thousandths, 1000);
        let fracText = String.padLeft(3, '0', "${frac}");
        "${thousandths / 1000}.${fracText}"
}
