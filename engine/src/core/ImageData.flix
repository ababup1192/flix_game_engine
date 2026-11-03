/// ImageData — 解いた絵の画素（幅・高さ・ARGB）と、PNG / JPEG のバイトを画素に戻す口（デコーダー）の型。
/// 2D と 3D のどちらでも使う。3D の材質の絵にするなら Texture3d.fromImage で包む。
/// デコーダーは機種の物（デスクトップは javax.imageio・ブラウザは createImageBitmap）なので engine では作らず、
/// 読み込みの handler が LoadProgress.imageDecoder() で渡す。
pub mod ImageData {

    /// width × height・argb = ARGB（行優先・行 0 が絵の上）。数の食い違いは使う側（Texture3d.fromImage など）が確かめる。
    pub type alias ImageData = { width = Int32, height = Int32, argb = Vector[Int32] }

    /// PNG / JPEG のバイトを画素に戻す。読めないバイトは Err。スレッドをまたいで使える（並列の仕事の中から呼んでよい）。
    pub type alias ImageDecoder = { decode = Vector[Int8] -> Result[String, ImageData] \ IO }

    /// 何も解かず、いつも Err を返すデコーダー（絵を読まないテストの handler 用）。
    pub def failingDecoder(reason: String): ImageDecoder = { decode = _ -> checked_ecast(Err(reason)) }
}
