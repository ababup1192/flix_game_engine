// Layout — 画面の置き場所（design 960×540 の中の矩形）。View が描く所と Controls がクリックを当てる所は、
// どちらもここの同じ関数から引く（描いた所と押せる所がずれない）。
// 置き場所は「振り付け」なのでコードに置く（字の大きさ・行の数のような手触りは novel.kind.json）。
mod Layout {
    use fge::{Rect2}

    def rect(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 =
        { position = { x = x, y = y }, size = { x = w, y = h } }

    pub def screen(): Rect2.Rect2 = rect(0.0, 0.0, World.width(), World.height())

    pub def contains(r: Rect2.Rect2, p: { x = Float64, y = Float64 }): Bool =
        p#x >= r#position#x and p#x < r#position#x + r#size#x and p#y >= r#position#y and p#y < r#position#y + r#size#y

    // ── 文章 ──

    /// ADV の窓。
    pub def advPanel(): Rect2.Rect2 = rect(40.0, 348.0, 880.0, 160.0)

    /// ADV の名前の左上。
    pub def advName(): { x = Float64, y = Float64 } = { x = 72.0, y = 360.0 }

    /// ADV の本文の左上と折り返す幅（1 行目のルビは左上より上に出る）。
    pub def advText(): { x = Float64, y = Float64, width = Float64 } = { x = 72.0, y = 400.0, width = 816.0 }

    /// NVL の頁の左上と折り返す幅。
    pub def nvlText(): { x = Float64, y = Float64, width = Float64 } = { x = 110.0, y = 62.0, width = 740.0 }

    // ── 選択肢 ──

    /// i 番目（count 個のうち）の選択肢の矩形。ADV の窓に被らないよう、窓の上の空きの真ん中へ並べる。
    pub def choice(i: Int32, count: Int32): Rect2.Rect2 =
        let h = 46.0;
        let gap = 12.0;
        let total = Int32.toFloat64(count) * h + Int32.toFloat64(count - 1) * gap;
        let top = 178.0 - total / 2.0;
        rect(220.0, top + Int32.toFloat64(i) * (h + gap), 520.0, h)

    // ── 読んでいる間のボタン（下の帯） ──

    /// i 番目のボタン（count 個を右寄せで並べる）。
    pub def button(i: Int32, count: Int32): Rect2.Rect2 =
        let w = 62.0;
        let x0 = World.width() - 40.0 - Int32.toFloat64(count) * w;
        rect(x0 + Int32.toFloat64(i) * w, 512.0, w, 22.0)

    // ── 表紙 ──

    pub def titleItem(i: Int32): Rect2.Rect2 = rect(360.0, 300.0 + Int32.toFloat64(i) * 40.0, 240.0, 34.0)

    // ── 窓（セーブ・ロード・設定・ログ） ──

    /// 栞の枠 i（2 列 × 3 行）。
    pub def slot(i: Int32): Rect2.Rect2 =
        let col = Int32.remainder(i, 2);
        let row = i / 2;
        rect(70.0 + Int32.toFloat64(col) * 420.0, 104.0 + Int32.toFloat64(row) * 116.0, 400.0, 100.0)

    /// 窓の「戻る」。
    pub def back(): Rect2.Rect2 = rect(420.0, 470.0, 120.0, 36.0)

    /// 設定の行 i（つまみの帯は settingBar）。
    pub def settingRow(i: Int32): Rect2.Rect2 = rect(180.0, 120.0 + Int32.toFloat64(i) * 64.0, 600.0, 48.0)

    /// 設定の行 i のつまみの帯（左端 = 最小・右端 = 最大）。
    pub def settingBar(i: Int32): Rect2.Rect2 = rect(420.0, 140.0 + Int32.toFloat64(i) * 64.0, 320.0, 10.0)

    /// ログの読む範囲。
    pub def logView(): Rect2.Rect2 = rect(110.0, 80.0, 740.0, 380.0)
}
