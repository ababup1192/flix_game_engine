/// move のお手本の元: 移す def（area）を、同じ mod の中（total・scaled）・修飾名（Draw・Geometry・テスト）・
/// use（Panel の波括弧・Tile の 1 つだけ・Badge の別名）から呼ぶ。scaled は非 pub の scale を使い、unit は非 pub で
/// この mod の中だけで使う。area は use で入れた px と、この mod の型 Rect を使う。
mod Shapes {
    use Units.{px}

    pub type alias Rect = { w = Int32, h = Int32 }

    /// 面積（px）。
    pub def area(r: Rect): Int32 = px(r#w * r#h)

    pub def perimeter(r: Rect): Int32 = 2 * (r#w + r#h)

    pub def total(r: Rect): Int32 = area(r) + perimeter(r)

    def scale(): Int32 = 2

    pub def scaled(r: Rect): Int32 = area(r) * scale()

    def unit(): Int32 = 1

    pub def one(): Int32 = unit()
}
