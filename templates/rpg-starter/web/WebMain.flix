// ブラウザ版の入口（bin/fge export-web だけが組む。src の外に置くのは、デスクトップの make check / make test の木に入れないため）。
// Main と同じ App を、開発の道具なし（App.DevTools.none）でブラウザの handler 一式（WebLayer・WebFs）の上に走らせる。
// セーブは localStorage（saves/rune.json の道のまま。鍵の頭にゲームの id）。
mod WebMain {
    use fge::{App, Resources, WebFs, WebLayer}

    pub def main(): Unit \ IO =
        run {
            let docs = Res.loadDocs();
            let app = Game.app(docs, Saves.load(docs#items, docs#maps))
                |> App.addOutput(Resources.liftOutput({ keyOf = w -> if (w#saveRev == 0) "" else Int32.toString(w#saveRev),
                                                        write = w -> w#save |> Option.forEach(Saves.write), onJump = App.OnJump.Skip }))
                |> App.withSpriteAtlases(Resources.read((res, _) -> Res.atlases(res)));
            App.launchWithDevTools(App.DevTools.none(), app)
        } with WebLayer.withProject(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
