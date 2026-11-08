/// ImageData — 解いた絵の画素（幅・高さ・ARGB）と、PNG / JPEG のバイトを画素に戻す口（デコーダー）の型。
/// 2D と 3D のどちらでも使う。3D の材質の絵にするなら Texture3d.fromImage で包む。
/// デコーダーは機種の物（デスクトップは javax.imageio・ブラウザは createImageBitmap）なので engine では作らず、
/// 読み込みの handler が LoadProgress.imageDecoder() で渡す。
pub mod ImageData {

    /// width × height・argb = ARGB（行優先・行 0 が絵の上）。数の食い違いは使う側（Texture3d.fromImage など）が確かめる。
    pub type alias ImageData = { width = Int32, height = Int32, argb = Vector[Int32] }

    /// 機種が自分の側に解いて持つ絵（ブラウザの ImageBitmap）。key = 描き手が GPU へ上げる時に渡す字（同じ key なら同じ画素）。
    pub type alias PlatformImage = { key = String, width = Int32, height = Int32 }

    /// 絵を解く口の組。スレッドをまたいで使える（並列の仕事の中から呼んでよい）。
    /// decode = PNG / JPEG のバイトを画素に戻す（読めないバイトは Err）。
    /// platformImage = 道の絵を機種の側に解いて持ち、その key を返す。持てない機種（デスクトップ）・道に絵が無い時は None。
    /// versionedKey = 道の中身が変わらない間だけ同じ字を返す鍵（ブラウザは道と書き出しの版）。読み直すと中身が変わりうる機種
    /// （デスクトップの開発中の読み直し）は None。
    pub type alias ImageDecoder = { decode = Vector[Int8] -> Result[String, ImageData] \ IO,
                                    platformImage = String -> Option[PlatformImage] \ IO,
                                    versionedKey = String -> Option[String] \ IO }

    /// decode だけを持つデコーダー（platformImage と versionedKey はいつも None）。デスクトップ・画面なし・テストの handler 用。
    pub def decoderOf(decode: Vector[Int8] -> Result[String, ImageData] \ IO): ImageDecoder =
        { decode = decode, platformImage = _ -> checked_ecast(None), versionedKey = _ -> checked_ecast(None) }

    /// 何も解かず、いつも Err を返すデコーダー（絵を読まないテストの handler 用）。
    pub def failingDecoder(reason: String): ImageDecoder = decoderOf(_ -> checked_ecast(Err(reason)))
}
