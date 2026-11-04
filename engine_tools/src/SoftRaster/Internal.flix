// SoftRaster.Internal — SoftRaster の中身（描く物の並べ方・絵とフォントの読み込み・2D の描き物・重ね方・Rgba16Float の描き先・
// シェーダーの面・頂点色の多角形）を置く子のモジュールの親。ゲームとほかのパッケージが呼ぶ関数は全部 SoftRaster に残す。
// WhyNot: 子の関数を非 pub にしない — Flix では親（SoftRaster）から子の関数を呼ぶには pub が要り、パッケージの中だけで見える pub が無い。
pub mod SoftRaster.Internal {
}
