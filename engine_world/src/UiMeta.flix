// UiMeta — UI の目印（meta 文字列）の共通の読み方。
// "novel/choice/2" のような「接頭辞 + 番号」から番号を取り出す。

pub mod UiMeta {

    /// meta が "prefix" + 番号なら Some(番号)。それ以外は None。
    pub def indexOf(prefix: String, meta: String): Option[Int32] =
        if (String.startsWith(prefix = prefix, meta))
            Int32.fromString(String.dropLeft(String.length(prefix), meta))
        else None
}
