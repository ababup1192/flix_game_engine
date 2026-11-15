// RenderPaint.Internal — 塗りのコアの WebGPU の分（WGSL・device と pipeline・5 つの handler）を置く子のモジュールの親。
// ゲームの src と test からは使わない（lint-forbid の app-internal が止める。版を上げると名前も形も知らせずに変わる）。
// WhyNot: 子の関数を非 pub にしない — 兄弟のウィンドウの層（LwjglLayer）から使うには pub が要り、パッケージの中だけで見える pub が無い。
// WhyNot: docs/api-digest に載せない — 載せるとゲームを書く人が引いて呼んでしまう。
pub mod RenderPaint.Internal {
}
