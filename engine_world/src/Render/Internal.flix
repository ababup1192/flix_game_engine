// Render.Internal — Render の中身（Item を描画命令へ写す所・Pass の読みの書き換え）を置く子のモジュールの親。
// ゲーム向けの関数は全部 Render に残し、ここの子はゲームの src と test から呼ばない。
// WhyNot: 子の関数を非 pub にしない — Flix では親（Render）から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
pub mod Render.Internal {
}
