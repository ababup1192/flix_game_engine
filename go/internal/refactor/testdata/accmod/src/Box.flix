/// field-to-accessor の口の書き方のお手本: 口を置く mod（Box）の中は素の名前、外（Out）は Box. の修飾つき、
/// use で取り込んだ外（Imp）は素の名前で呼ぶ。欄 flag は読みの口が在り、欄 size は口が無い（道具が作る）。
mod Box {
    pub type alias Box = {
        flag = Bool,
        size = Int32
    }

    pub def flagOf(b: Box): Bool = b#flag

    pub def make(): Box = { flag = false, size = 1 }

    pub def grow(b: Box): Box = { size = b#size + 1 | b }

    pub def raise(b: Box): Box = { flag = true | b }

    pub def shown(b: Box): Bool = b#flag

    pub def reset(b: Box): Box = { flag = false, size = 0 | b }
}
