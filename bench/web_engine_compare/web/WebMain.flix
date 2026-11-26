// ブラウザ版の入口（bin/fge export-web だけが組む）。URL の query のつまみ（CompareBench の頭）で場面を選んで測り、結果を頁の上に残す。
// 比べる相手の harness の頁で開かれた時（query に engine=flix）は、場面の時刻を harness から受け、場面の更新の ms を console の 1 行で返す
// （受け渡しは harness/flix-adapter.ts が頁の fgeQueryPairs と console.log を包んで行う）。
mod WebMain {
    use fge::{App, WebFs, WebLayer}

    import fge.web.Browser

    /// harness が渡す場面の時刻（秒）の鍵。
    def harnessTimeKey(): String = "harness_t"

    def harnessTime(fallback: Float64): Float64 \ IO =
        BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()))
            |> Map.get(harnessTimeKey()) |> Option.flatMap(Float64.fromString) |> Option.getWithDefault(fallback)

    /// harness の pick の頼み（鍵 pick_seq・pick_x・pick_y）。
    def harnessPick(): Option[CompareBench.PickRequest] \ IO =
        let pairs = BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()));
        let num = key -> Map.get(key, pairs) |> Option.flatMap(Float64.fromString);
        Map.get("pick_seq", pairs) |> Option.flatMap(Int32.fromString)
            |> Option.flatMap(seq -> num("pick_x") |> Option.flatMap(x -> num("pick_y") |> Option.map(y -> { seq = seq, x = x, y = y })))

    def hooksOf(knobs: Map[String, String]): CompareBench.Hooks =
        if (Map.get("engine", knobs) == Some("flix"))
            { sceneTime = harnessTime, now = () -> Browser.now(), noteSim = ms -> Browser.log("[wec] sim ${ms}"),
              pickRequest = harnessPick, notePick = (seq, slot, ms) -> Browser.log("[wec] pick ${seq} ${slot} ${ms}") }
        else CompareBench.standalone(() -> Browser.now())

    pub def main(): Unit \ IO =
        let knobs = BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()));
        let scenario = CompareBench.scenarioOf(knobs);
        run {
            match Draw.kitOf(CompareBench.pathOf(scenario, knobs), Scenes.build(scenario, CompareBench.levelOf(scenario, knobs))) {
                case Err(why) => Browser.log("[web_engine_compare] 形を作れない: ${why}")
                case Ok(kit)  =>
                    CompareBench.app(CompareBench.planOf(knobs), line -> Browser.log(line), hooksOf(knobs), kit, scenario)
                        |> App.quitWhen((_frame, _w) -> checked_ecast(false))
                        |> App.launchForBench
            }
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
