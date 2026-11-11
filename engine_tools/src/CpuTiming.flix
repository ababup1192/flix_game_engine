// CpuTiming — CPU の仕事 1 回の時間を、JIT を温めてから何回か測って並べる。2D と 3D のどちらの描き手にも使う。
// 1 回だけ測ると、冷えた JIT と初めての読み込みが入って、同じ機械でも数倍ぶれる。
pub mod CpuTiming {
    import java.lang.System

    /// 測り方: warmup は捨てる回数、runs は測る回数。
    pub type alias Plan = { warmup = Int32, runs = Int32 }

    /// 測った結果（ミリ秒）。samples は小さい順。
    pub type alias Summary = { median = Float64, min = Float64, max = Float64, samples = Vector[Float64] }

    // WhyNot: 純粋な work を受けない — 値を捨てる純粋な呼び出しは Flix が消すので、0 ms を測ってしまう。
    // WhyNot: 測った回の値を捨てない — 使われない値は JIT が計算ごと消しうる（docs/performance.md の「時間で測るとき」）。
    /// work を warmup 回流して捨て、runs 回流して 1 回ずつの時間を測る（runs が 0 以下なら 1 回）。
    /// 最後の回の work の値も返す。
    pub def measure(plan: Plan, work: Unit -> a \ IO): (Summary, a) \ IO =
        List.range(0, plan#warmup) |> List.forEach(_ -> discard work());
        // 測った回の値は最後の 1 つだけ持つ（全部持つと、描いた絵の山の GC が測る時間に混ざる）。
        let timeOnce = () -> {
            let started = System.nanoTime();
            let value = work();
            (Int64.toFloat64(System.nanoTime() - started) / 1000000.0, value)
        };
        let (firstMs, firstValue) = timeOnce();
        let (restMs, lastValue) = List.range(1, Int32.max(1, plan#runs))
            |> List.foldLeft((acc, _) -> { let (ms, value) = timeOnce(); (ms :: fst(acc), value) }, (Nil, firstValue));
        (summarize(Nel.Nel(firstMs, restMs)), lastValue)

    /// 時間の列（ミリ秒）を中央値と幅にまとめる。偶数個の中央値は真ん中の 2 つの平均。
    pub def summarize(samples: Nel[Float64]): Summary =
        let sorted = Nel.toList(samples) |> Sort.sortStable |> List.toVector;
        let count = Vector.length(sorted);
        let at = i -> Vector.get(i, sorted);
        let median = if (Int32.modulo(count, 2) == 1) at(count / 2) else (at(count / 2 - 1) + at(count / 2)) / 2.0;
        { median = median, min = at(0), max = at(count - 1), samples = sorted }
}
