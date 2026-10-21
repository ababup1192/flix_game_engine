/// Box の外（use なし）から欄を読み書きする。口と同じ名前の def（sizeOf）を持つ。
mod Out {
    use Box.Box

    pub def sizeOf(n: Int32): Int32 = n

    pub def sizeTwice(b: Box): Int32 = b#size * 2

    pub def lower(b: Box): Box = { flag = false | b }

    pub def visible(b: Box): Bool = b#flag
}
