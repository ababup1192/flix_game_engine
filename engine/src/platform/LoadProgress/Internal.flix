// LoadProgress.Internal — メインの外（ブラウザの Web Worker）で解いた結果の中身を、機種と engine の間で受け渡す口。

/// LoadProgress の中身。ゲームからは呼ばない。
pub mod LoadProgress.Internal {

    /// 解いた結果の並び。ints・floats・strings = 数と字を書いた順に・f64s・i32s = 頂点などの配列（書いた順の番号で指す）。
    /// 何をどの順に書くかは書く側が決める（glb は Gltf.Internal.Codec）。
    pub type alias PreparsedParts = { strings = Vector[String], ints = Vector[Int32], floats = Vector[Float64],
                                      f64s = Vector[Vector[Float64]], i32s = Vector[Vector[Int32]] }
}
