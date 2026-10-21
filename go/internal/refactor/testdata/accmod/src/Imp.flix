/// Box の外から、読みの口 flagOf を use で取り込んで欄を読む。
mod Imp {
    use Box.Box
    use Box.flagOf

    pub def both(b: Box): Bool = flagOf(b) and b#flag
}
