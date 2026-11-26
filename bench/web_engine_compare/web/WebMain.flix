// ブラウザ版の入口（bin/fge export-web だけが組む）。URL の query のつまみ（CompareBench の頭）で場面を選んで測り、結果を頁の上に残す。
mod WebMain {
    use fge::{App, WebFs, WebLayer}

    import fge.web.Browser

    pub def main(): Unit \ IO =
        let knobs = BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()));
        let scenario = CompareBench.scenarioOf(knobs);
        run {
            match Draw.kitOf(Scenes.build(scenario, CompareBench.levelOf(scenario, knobs))) {
                case Err(why) => Browser.log("[web_engine_compare] 形を作れない: ${why}")
                case Ok(kit)  =>
                    CompareBench.app(CompareBench.planOf(knobs), line -> Browser.log(line), kit, scenario)
                        |> App.quitWhen((_frame, _w) -> checked_ecast(false))
                        |> App.launchForBench
            }
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
