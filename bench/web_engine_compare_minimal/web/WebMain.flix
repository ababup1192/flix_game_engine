// ブラウザ版の入口（bin/fge export-web だけが組む）。最小の箱の app を起こすだけ。
mod WebMain {
    use fge::{App, WebFs, WebLayer}

    pub def main(): Unit \ IO =
        run {
            App.launchWithDevTools(App.DevTools.none(), MinimalCube.app())
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
