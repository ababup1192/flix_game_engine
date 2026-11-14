// ブラウザ版の入口（bin/fge export-web だけが組む）。つまみは URL の query（例: ?n=20000&tex=16&blend=alt&frames=300）。
// WhyNot: 終わっても閉じない — 結果を頁の上に出したまま、人が読めるようにする。
mod WebMain {
    use fge::{App, WebFs, WebLayer}

    import fge.web.Browser

    pub def main(): Unit \ IO =
        let config = Bench.configOf(BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs())));
        run {
            Bench.app(line -> Browser.log(line), config)
                |> App.quitWhen((_frame, _w) -> checked_ecast(false))
                |> App.launchForBench
        } with WebLayer.withProject(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
