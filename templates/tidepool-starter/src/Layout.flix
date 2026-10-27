// Layout — 盤のマスと画面の位置の対応（描く側の部品どうしが共有する寸法）。
// 盤の絵は 1 マス cell() の盤の座標で組み、最後に fitOf の倍率と置き場所で画面へ写す。
mod Layout {

    use fge::{Color, Vec2}

    /// 盤の座標の 1 マスの大きさ（px）。
    pub def cell(): Float64 = 44.0

    /// 盤を置ける画面の範囲の左上と高さ（幅は画面ごとに渡す）。
    def areaAt(): Vec2.Vec2 = { x = 8.0, y = 8.0 }


    /// 盤の座標 → 画面の座標の写し方（倍率と、盤の左上を置く所）。
    pub type alias Fit = { scale = Float64, offset = Vec2.Vec2 }

    /// 盤の大きさから、周りに外海を半マスずつ残して、幅 width の範囲の真ん中へ収める倍率と置き場所。
    pub def fitOf(cols: Int32, rows: Int32, width: Float64): Fit =
        let areaSize = { x = width, y = 344.0 };
        let span = { x = Int32.toFloat64(cols) * cell(), y = Int32.toFloat64(rows) * cell() };
        let scale = Float64.min(areaSize#x / (span#x + cell()), areaSize#y / (span#y + cell()));
        { scale = scale, offset = Vec2.add(areaAt(), Vec2.mul(Vec2.sub(areaSize, Vec2.mul(span, scale)), 0.5)) }

    /// マスの中心（盤の座標）。
    pub def centerOf(c: Board.Cell): Vec2.Vec2 =
        let (x, y) = c;
        { x = (Int32.toFloat64(x) + 0.5) * cell(), y = (Int32.toFloat64(y) + 0.5) * cell() }

    /// 先読み（次の 1 手の水際）の色。盤の上の破線と潮見表の破線を同じ色でつなぐ。
    pub def forecastColor(theme: ThemeDoc.Doc): Color =
        let t = ThemeDoc.rec(theme);
        Color.mix(t#sea, t#foam, 0.45)
}
