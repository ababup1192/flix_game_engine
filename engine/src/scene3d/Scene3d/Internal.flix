// Scene3d.Internal — Scene3d の中身を置く子のモジュールの親。外から呼ぶ関数は Scene3d に残す。
// WhyNot: 子の関数を非 pub にしない — Flix では親（Scene3d）から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
pub mod Scene3d.Internal {
}
