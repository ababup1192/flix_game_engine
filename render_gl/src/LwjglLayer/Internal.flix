// LwjglLayer.Internal — 実機のウィンドウの層（LwjglLayer）の中身を置く子のモジュールの親（WebGPU のウィンドウ）。
// ゲームの src と test からは使わない（lint-forbid の app-internal が止める。版を上げると名前も形も知らせずに変わる）。
// WhyNot: LwjglLayer の音・仕事・時計・カーソルの handler を pub に開かない — 子孫の mod からは先祖の pub でない物が見えるので、ここに置けば足りる。
pub mod LwjglLayer.Internal {
}
