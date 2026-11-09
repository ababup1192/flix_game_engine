// ブラウザ版の入口（bin/fge export-web だけが組む。src の外に置くのは、デスクトップの make check / make test の木に入れないため）。
// Main と同じ App を、開発の道具なし（App.DevTools.none）でブラウザの handler 一式（WebLayer・WebFs）の上に走らせる。
// セーブ・既読・設定は localStorage（saves/ の道のまま。鍵の頭にゲームの id）。
mod WebMain {
    use fge::{App, LoadProgress, Resources, WebFs, WebLayer}
    import fge.web.Browser

    pub def main(): Unit \ IO =
        run {
            // 後回しの絵と音（project.json の web.deferred）は押した後も裏で届く。届いていない名前を Res に置いて始める。
            let downloads = LoadProgress.downloads();
            let res = Res.withMissing(downloads#missing(), Controls.loadRes());
            let app = Game.app(res, Saves.load(res#kind), localEpochSeconds())
                |> Game.withAssetLoading(downloads)
                |> App.addOutput(Resources.liftOutput({ keyOf = w -> if (w#saveRev == 0) "" else Int32.toString(w#saveRev),
                                                        write = w -> Saves.write(w#saves), onJump = App.OnJump.Skip }));
            App.launchWithDevTools(App.DevTools.none(), app)
        } with WebLayer.withProject(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite

    // WhyNot: Main の localEpochSeconds（java.util.TimeZone）を使わない — TeaVM で時差の表を持たないので、ブラウザの Date から取る。
    /// 今のその土地の時刻（1970-01-01 00:00 からの秒）。
    def localEpochSeconds(): Int64 \ IO =
        Float64.tryToInt64(Browser.localEpochSeconds()) |> Option.getWithDefault(0i64)
}
