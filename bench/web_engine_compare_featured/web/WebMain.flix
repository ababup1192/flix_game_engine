// ブラウザ版の入口（bin/fge export-web だけが組む）。assets/Fox.glb を読んで狐の app を起こすだけ。
mod WebMain {
    use fge::{App, Model3d, WebFs, WebLayer}

    import fge.web.Browser

    pub def main(): Unit \ IO =
        run {
            match Model3d.load(Model3d.loader(), "assets/Fox.glb") {
                case Err(why) => Browser.log("[featured] 狐を読めない: ${why}")
                case Ok(fox)  => App.launchWithDevTools(App.DevTools.none(), FeaturedFox.app(fox))
            }
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
