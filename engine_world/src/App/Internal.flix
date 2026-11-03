// App.Internal — App の中身（ループ・入力を組む部品・音とウィンドウへの出力・描く所・F8 で止めた画面・ヒッチの記録）を置く子のモジュールの親。
// ゲームが呼ぶ関数は全部 App に残し、ここの子はゲームの src と test から呼ばない（lint-forbid の app-internal が止める）。
// 呼んでよいのは engine の 4 パッケージ・engine_full・bench（engine の側の道具）。
// WhyNot: 子の関数を非 pub にしない — Flix では親（App）から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
// WhyNot: docs/api-digest に載せない — 載せるとゲームを書く人が引いて呼んでしまう。
pub mod App.Internal {
}
