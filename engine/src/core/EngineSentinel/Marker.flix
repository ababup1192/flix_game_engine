pub mod EngineSentinel.Marker {
    pub enum Marker { case M }
}

// `EngineSentinel` の子モジュール。matching-name (mod の末尾 == 中の enum 名 == "Marker") で
// 別ファイル化することが Flix 0.72.0 で cross-package use を成功させる唯一の条件。
// 親 `src/EngineSentinel.flix` (空 pub mod) もセットで必要。
//
// `///` ドキュメントコメントを mod 宣言の前に置くと parser バグで mod が認識されなくなる
// （詳細は src/EngineSentinel.flix のコメント参照）。
