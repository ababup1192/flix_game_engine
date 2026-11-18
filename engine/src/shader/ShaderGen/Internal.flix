// ShaderGen.Internal — ShaderGen の中身を置く子のモジュールの親。外から呼ぶ関数は ShaderGen に残す。
// WhyNot: 子の関数を非 pub にしない — Flix では親（ShaderGen）から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
pub mod ShaderGen.Internal {
}
