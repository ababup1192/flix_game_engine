// ブラウザ版の入口（bin/fge export-web だけが組む）。つまみは URL の query（例: ?n=6000,20000&search=grid&frames=300）。
// WhyNot: 終わっても閉じない — 結果を頁の上に出したまま、人が読めるようにする。
mod WebMain {
    use fge::{App, WebFs, WebLayer}

    import fge.web.Browser

    pub def main(): Unit \ IO =
        let config = CrowdBench.configOf(BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs())));
        let host = { now = () -> Browser.now(), emit = line -> Browser.log(line) };
        run {
            App.make(CrowdBench.initialWorld(config))
                |> App.addSystem(CrowdBench.step(host))
                |> BenchRun.withDiagnostics(config#plan)
                |> App.withView((_ctx, w) -> checked_ecast(CrowdBench.view(w)))
                |> App.quitWhen((_frame, _w) -> checked_ecast(false))
                |> App.launchForBench
        } with WebLayer.withProject(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
