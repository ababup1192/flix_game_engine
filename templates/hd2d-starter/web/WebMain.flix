// ブラウザ版の入口（bin/fge export-web だけが組む。src の外に置くのは、デスクトップの make check / make test の木に入れないため）。
// Main と同じ App を、開発の道具なし（App.DevTools.none）でブラウザの handler 一式（WebLayer・WebFs）の上に走らせる。
// 描き方の重さは頁の URL の query（?shadow=2048&dof=0&post=0）で差し替える。
mod WebMain {
    use fge::{App, LoadProgress, WebFs, WebLayer}

    import fge.web.Browser

    pub def main(): Unit \ IO =
        let knobs = Knobs.ofPairs(Array.toList(Browser.queryPairs()));
        run {
            let decoder = LoadProgress.imageDecoder();
            let loaded = Res.loadDocs() |> Result.flatMap(Res.load(Images.readImageWith(decoder), TownScene.TextureNames.ProjectTextures, knobs));
            match loaded {
                case Ok(res)  => App.launchWithDevTools(App.DevTools.none(), Game.app(res))
                case Err(why) => Browser.log("[hd2d] 町を組めない: ${why}")
            }
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
