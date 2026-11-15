// WebLayer.Internal — ブラウザ版の handler 一式（WebLayer）の中身を置く子のモジュールの親（WebGPU で描く頁）。
// ゲームの src と test からは使わない（lint-forbid の app-internal が止める。版を上げると名前も形も知らせずに変わる）。
// WhyNot: WebLayer の音・時計・入力・読み込みの知らせの handler を pub に開かない — 子孫の mod からは先祖の pub でない物が見えるので、ここに置けば足りる。
pub mod WebLayer.Internal {
}
