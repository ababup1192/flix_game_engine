// ブラウザ版の入口（bin/fge export-web だけが組む。src の外に置くのは、デスクトップの make check / make test の木に入れないため）。
// Main と同じ App を、ブラウザの handler 一式（WebLayer・WebFs）の上に走らせる。
// WebLayer.devTools は URL のクエリから始まりを選ぶだけ（?at=1&x=-24.04&z=-1.5&yaw=180 で中央の階段の前など・クエリが無ければ昇降口）。
mod WebMain {
    use fge::{App, Resources, WebFs, WebLayer}

    pub def main(): Unit \ IO =
        run {
            // 終わるのはデスクトップと同じく終了の確認で「はい」を選んだ時だけ（既定の「Esc ですぐ終了」を外す。Esc はマウスを放す・確認を出す）。
            App.launchWithDevTools(WebLayer.devTools(), Game.app(Controls.loadDocs())
                |> App.quitWhen((_, h) -> Resources.read((_, w) -> World.isQuitting(w), h)))
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
