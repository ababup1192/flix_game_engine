// ProcessEnv — プロセスの境目。環境変数の表を読むのと、終了コードでプロセスを終えるのはここだけ。
// 入口の頭（ゲームの main・描き出しの入口・App.launch など）で 1 回だけ snapshot を読み、要る値を引数で奥へ渡す。
// 常駐（App.Headless）から呼ばれる入口は snapshot を読まず、要求の表（App.Headless.envOf(req)）を読む。
pub mod ProcessEnv {
    import java.lang.System

    /// 今のプロセスの環境変数を丸ごと表にする。
    // WhyNot: 奥の関数が名前ごとに System.getenv を引かない — 常駐では要求の env ではなく、常駐を起こした時の
    // env が見えてしまう。表にして引数で渡せば、どの値を読んだかが型に出る。
    pub def snapshot(): Map[String, String] \ IO =
        run { Sys.Env.getEnv() } with Sys.Env.runWithIO

    /// 0 ならそのまま戻り、それ以外はその終了コードでプロセスを終える。
    /// 常駐から呼ばれる入口の中では呼ばない（常駐ごと落ちる）。終了コードを返して、入口の頭で呼ぶ。
    pub def exitWith(code: Int32): Unit \ IO =
        if (code == 0) () else System.exit(code)
}
