// PerfText — 重さの表示（F3）の字（純粋）。HUD の左上（View・診断つき）と、遠隔の /state の 1 行（E2e.statusLine・fps だけ）が同じ字を使う。
mod PerfText {
    use fge::FrameDiagnostics

    /// fps と low・CPU と GPU の ms・3D の描いた数 / 置いた数と draw call・draw call が分かれた理由。
    /// diagnostics = 前のコマの診断（View は ctx#diagnostics・遠隔の 1 行は無し）。
    pub def linesOf(p: World.Perf, diagnostics: Option[FrameDiagnostics.Diagnostics]): List[String] =
        let ms = (ns: Int64) -> Int64.toFloat64(ns) / 1000000.0;
        let f1 = (v: Float64) -> Float64.toString(Float64.round(v * 10.0) / 10.0);
        let diag = diagnostics |> Option.map(d -> {
            let c = d#scene3dCounts;
            "cpu ${f1(ms(d#submitNs))} swap ${f1(ms(d#swapNs))} gpu ${d#gpuNs |> Option.map(n -> f1(ms(n))) |> Option.getWithDefault("-")} ms" ::
            "3D ${Int32.toString(c#drawn)}/${Int32.toString(c#instances)} calls ${Int32.toString(c#drawCalls)}" ::
            FrameDiagnostics.breaksText(FrameDiagnostics.scene3dBreakList(c#batchBreaks)) :: Nil
        }) |> Option.getWithDefault(Nil);
        "fps ${f1(p#fps)} low ${f1(p#low)}" :: diag
}
