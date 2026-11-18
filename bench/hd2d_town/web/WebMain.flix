// ブラウザ版の入口（bin/fge export-web だけが組む。src の外に置くのは、デスクトップの make check / make test の木に入れないため）。
// 昼の町を歩き回る場面（Explore.appOf）を、開発の道具なしでブラウザの handler 一式（WebLayer・WebFs）の上に走らせる。
// 描き方の重さは頁の URL の query（?shadow=2048&dof=0&post=0）で差し替える。
mod WebMain {
    use fge::{App, LoadProgress, WebFs, WebLayer}

    import fge.web.Browser

    pub def main(): Unit \ IO =
        let knobs = BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()));
        run {
            let decoder = LoadProgress.imageDecoder();
            match Explore.load(Images.readImageWith(decoder), knobs) {
                case Ok(res)  => App.launchWithDevTools(App.DevTools.none(), Explore.appOf(res))
                case Err(why) => Browser.log("[hd2d_town] 町を組めない: ${why}")
            }
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
