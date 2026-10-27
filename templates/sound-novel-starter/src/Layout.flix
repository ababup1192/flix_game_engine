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

    /// 0 から count − 1 のうち、r(i) が p を含む最初の番号。
    pub def hitOf(count: Int32, r: Int32 -> Rect2.Rect2, p: { x = Float64, y = Float64 }): Option[Int32] =
        List.range(0, count) |> List.find(i -> contains(r(i), p))

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

    // ── クイックメニュー（下の帯） ──

    /// i 番目のボタン（count 個を画面の真ん中に並べる）。
    pub def button(i: Int32, count: Int32): Rect2.Rect2 =
        let w = 64.0;
        let x0 = (World.width() - Int32.toFloat64(count) * w) / 2.0;
        rect(x0 + Int32.toFloat64(i) * w, 512.0, w, 24.0)

    // ── タイトル ──

    pub def titleItem(i: Int32): Rect2.Rect2 = rect(380.0, 282.0 + Int32.toFloat64(i) * 36.0, 200.0, 32.0)

    // ── 画面の枠（セーブ・ロード・設定・バックログで同じ） ──

    /// 見出しの左上。
    pub def heading(): { x = Float64, y = Float64 } = { x = 64.0, y = 30.0 }

    /// 見出しの下の線の高さ。
    pub def rule(): Float64 = 78.0

    /// 右上の「戻る」。
    pub def back(): Rect2.Rect2 = rect(800.0, 32.0, 96.0, 32.0)

    /// 画面の下の案内の高さ。
    pub def hintY(): Float64 = 508.0

    // ── セーブ・ロード ──

    /// ページのタブ j（左から）。
    pub def tab(j: Int32): Rect2.Rect2 = rect(64.0 + Int32.toFloat64(j) * 92.0, 90.0, 86.0, 30.0)

    /// 枠 i（2 列 × 3 行）。
    pub def slot(i: Int32): Rect2.Rect2 =
        let col = Int32.remainder(i, 2);
        let row = i / 2;
        rect(64.0 + Int32.toFloat64(col) * 424.0, 132.0 + Int32.toFloat64(row) * 124.0, 408.0, 114.0)

    /// 枠の中のサムネ（画面と同じ 16:9）。
    pub def thumb(i: Int32): Rect2.Rect2 =
        let s = slot(i);
        rect(s#position#x + 9.0, s#position#y + 9.0, 171.0, 96.0)

    /// 枠の右上の削除。
    pub def remove(i: Int32): Rect2.Rect2 =
        let s = slot(i);
        rect(s#position#x + s#size#x - 30.0, s#position#y + 6.0, 24.0, 24.0)

    // ── バックログ ──

    /// 読む範囲（名前の列 + 本文の列）。
    pub def logView(): Rect2.Rect2 = rect(64.0, 92.0, 800.0, 404.0)

    /// 名前の列の右端（名前は右へ寄せる）と、本文の列の左端と幅。
    pub def logNameRight(): Float64 = 196.0

    pub def logText(): { x = Float64, width = Float64 } = { x = 220.0, width = 630.0 }

    /// スクロールバーの溝。
    pub def logTrack(): Rect2.Rect2 = rect(884.0, 92.0, 4.0, 404.0)

    // ── 設定（2 列） ──

    /// 列 col（0 = 左・1 = 右）の左端。
    def columnX(col: Int32): Float64 = 64.0 + Int32.toFloat64(col) * 432.0

    /// 列の見出しの左上。
    pub def group(col: Int32): { x = Float64, y = Float64 } = { x = columnX(col), y = 92.0 }

    /// 設定の i 行目（World.settings の並び。左の列に World.leftColumnRows 行、残りは右の列）。
    pub def settingRow(i: Int32): Rect2.Rect2 =
        let left = World.leftColumnRows();
        let (col, row) = if (i < left) (0, i) else (1, i - left);
        rect(columnX(col), 126.0 + Int32.toFloat64(row) * 56.0, 400.0, 44.0)

    /// 行 i のつまみの帯（左端 = 最小・右端 = 最大）。
    pub def settingBar(i: Int32): Rect2.Rect2 =
        let r = settingRow(i);
        rect(r#position#x + 160.0, r#position#y + 19.0, 172.0, 6.0)

    /// 行 i の 2 つから選ぶボタンの side 側（0 = 左・1 = 右）。
    pub def settingSide(i: Int32, side: Int32): Rect2.Rect2 =
        let r = settingRow(i);
        rect(r#position#x + 160.0 + Int32.toFloat64(side) * 122.0, r#position#y + 6.0, 116.0, 32.0)

    /// 押す行（初期設定に戻す）のボタン。
    pub def settingAction(i: Int32): Rect2.Rect2 =
        let r = settingRow(i);
        rect(r#position#x, r#position#y + 6.0, 238.0, 32.0)

    /// 文字の速さの見本（左の列の下）。
    pub def preview(): Rect2.Rect2 = rect(64.0, 412.0, 400.0, 84.0)

    // ── 確認の窓 ──

    pub def askBox(): Rect2.Rect2 = rect(270.0, 186.0, 420.0, 168.0)

    /// はい（0）・いいえ（1）。
    pub def askButton(i: Int32): Rect2.Rect2 = rect(316.0 + Int32.toFloat64(i) * 172.0, 290.0, 156.0, 40.0)
}
