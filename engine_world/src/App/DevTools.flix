// App.DevTools — 開発の道具の組（App.DevTools の型）を作る口。Bevy の bevy_dev_tools と同じ考えで、App は渡された組の道具だけを動かし、
// 組が「無し」なら道具のコードへ呼び出しが届かない。中身（ループが呼ぶフックの組）は App.Internal.DevTools。
pub mod App.DevTools {

    /// 道具なしの組。命令口・flow の記録・ゲームの名簿・ヒッチの見張り・Doc の保存検知・F8 の注釈の書き出しのどれも動かさず、
    /// 環境変数も読まない。ブラウザ版の入口と、開発の道具を持たない配る版の起動で `App.launchWithDevTools` へ渡す。
    /// withDebug が真なら F8 で止めて巻き戻せるが、囲んだ注釈は書き出さない。
    pub def none(): App.DevTools[w, {}] =
        App.DevToolsFactory.DevToolsFactory(_ -> App.Internal.DevTools.none())

    /// デスクトップの道具の組。env は入口の頭で読んだ環境変数の表（ProcessEnv.snapshot()。DEBUG_HTTP_PORT・FLOW_RECORD・START を読む）。
    /// 記録と保存検知は App の withDebug が真の時だけ、命令口とヒッチの見張りはさらに view か debugView がある時だけ動く。START はいつも効く。
    pub def desktop(env: Map[String, String]): App.DevTools[w, Platform.Annotation] =
        App.desktopTools(env, None)
}
