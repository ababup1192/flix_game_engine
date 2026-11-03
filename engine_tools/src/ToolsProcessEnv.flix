// ToolsProcessEnv — engine_tools の中で環境変数の表を読むのはここだけ（入口の頭で読み、奥へは引数で渡す）。
// WhyNot: engine_world の ProcessEnv.snapshot を呼ばない — 層は engine と自分のソースしか見ないので、engine_tools から
// engine_world は見えない。名前を ProcessEnv にしない — 4 つのパッケージを 1 本に集める engine_full で重なる。
// WhyNot: pub mod にしない — ゲームは engine_world の ProcessEnv を使う（同じ物の API を 2 つ見せない）。
mod ToolsProcessEnv {

    /// 今のプロセスの環境変数を丸ごと表にする。
    pub def snapshot(): Map[String, String] \ IO =
        run { Sys.Env.getEnv() } with Sys.Env.runWithIO
}
