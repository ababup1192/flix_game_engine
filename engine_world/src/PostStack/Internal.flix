// PostStack.Internal — PostStack の中身（Pass への展開・post.json の読み）を置く子のモジュールの親。
// ゲームが呼ぶ関数は全部 PostStack に残し、ここの子はゲームの src と test から呼ばない。
// WhyNot: 子の関数を非 pub にしない — Flix では親（PostStack）から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
pub mod PostStack.Internal {
}
