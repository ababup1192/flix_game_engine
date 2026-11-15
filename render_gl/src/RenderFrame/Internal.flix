// RenderFrame.Internal — 1 コマの並べ替えと行づくり（RenderFrame の前半）を GL 以外の backend へ流す子のモジュールの親。
// ゲームの src と test からは呼ばない（lint-forbid の app-internal が止める）。
// WhyNot: RenderFrame の行を作る関数を pub に開かない — 子孫の mod からは先祖の pub でない物が見えるので、流す側をここに置けば足りる。
pub mod RenderFrame.Internal {
}
