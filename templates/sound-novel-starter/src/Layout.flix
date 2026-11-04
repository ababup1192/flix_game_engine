// Layout — 画面の置き場所（design 960×540 の中の矩形）と、押せる物の字の大きさ。View が描く所と Controls がクリックを当てる所は、
// どちらもここの同じ関数から、同じ Fit を渡して引く（描いた所と押せる所がずれない）。
// 置き場所は「振り付け」なのでコードに置く。本文の字の大きさ・行の数のような手触りは novel.kind.json、
// 小さい画面（スマホ）の時の大きさは novel.small.json。
mod Layout {
    use fge::{Display, Rect2}

    /// 並べ方の組。Regular = PC・タブレット・デスクトップ版（マウスで押す大きさ）、
    /// Small = スマホ（指で押せる大きさ。大きさは novel.small.json）。
    /// NVL の頁は World が行の数を数えるので、どちらの組でも同じ（nvlText は Fit を受けない）。
    pub enum Fit {
        case Regular
        case Small(SmallScreenDoc.Rec)
    }

    /// 端末の sizeClass から並べ方の組を選ぶ（View は ViewCtx#display#sizeClass、Controls は Frame#sizeClass を渡す）。
    /// WhyNot: Medium（タブレット）に Small の組を使わない — 画面の縦と横の短い方が 600 CSS px 以上あれば 960×540 のままで指で押せる。
    pub def fitOf(sizeClass: Display.SizeClass, small: SmallScreenDoc.Doc): Fit = match sizeClass {
        case Display.SizeClass.Small  => Fit.Small(SmallScreenDoc.rec(small))
        case Display.SizeClass.Medium => Fit.Regular
        case Display.SizeClass.Large  => Fit.Regular
    }

    /// 画面の大きさ（project.json の designWidth / designHeight と同じ値）。
    pub def width(): Float64 = 960.0
    pub def height(): Float64 = 540.0

    /// 2 つ並べたボタンのどちら側か（確認のウィンドウのはい・いいえ、設定の 2 択）。
    pub enum Side with Eq, ToString {
        case Left
        case Right
    }

    pub def sides(): List[Side] = Side.Left :: Side.Right :: Nil

    /// 左から数えた番号（左 = 0）。
    def columnOf(side: Side): Int32 = match side {
        case Side.Left  => 0
        case Side.Right => 1
    }

    /// side(s) が p を含む側。
    pub def sideAt(r: Side -> Rect2.Rect2, p: { x = Float64, y = Float64 }): Option[Side] =
        sides() |> List.find(side -> contains(r(side), p))

    def rect(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 =
        { position = { x = x, y = y }, size = { x = w, y = h } }

    pub def screen(): Rect2.Rect2 = rect(0.0, 0.0, width(), height())

    pub def contains(r: Rect2.Rect2, p: { x = Float64, y = Float64 }): Bool =
        p#x >= r#position#x and p#x < r#position#x + r#size#x and p#y >= r#position#y and p#y < r#position#y + r#size#y

    /// 0 から count − 1 のうち、r(i) が p を含む最初の番号。
    pub def hitOf(count: Int32, r: Int32 -> Rect2.Rect2, p: { x = Float64, y = Float64 }): Option[Int32] =
        List.range(0, count) |> List.find(i -> contains(r(i), p))

    // ── 文章 ──

    /// ADV のウィンドウ。Small は下の帯のボタンのすぐ上に置く。
    pub def advPanel(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Regular  => rect(40.0, 348.0, 880.0, 160.0)
        case Fit.Small(s) => rect(40.0, buttonTop(fit) - 4.0 - s#advPanelHeight, 880.0, s#advPanelHeight)
    }

    /// ADV の名前の左上。
    pub def advName(fit: Fit): { x = Float64, y = Float64 } = { x = 72.0, y = advPanel(fit)#position#y + 12.0 }

    /// ADV の本文の左上と折り返す幅（1 行目のルビは左上より上に出る）。
    pub def advText(fit: Fit): { x = Float64, y = Float64, width = Float64 } =
        let top = advPanel(fit)#position#y;
        match fit {
            case Fit.Regular  => { x = 72.0, y = top + 52.0, width = 816.0 }
            case Fit.Small(s) => { x = 72.0, y = top + 34.0 + s#advNameSize, width = 816.0 }
        }

    /// ADV の本文・ルビ・名前の字の大きさ（Regular は novel.kind.json の値のまま）。
    pub def advTextSizes(fit: Fit, kind: KindDoc.Rec): { body = Float64, ruby = Float64, name = Float64 } = match fit {
        case Fit.Regular  => { body = kind#bodySize, ruby = kind#rubySize, name = kind#nameSize }
        case Fit.Small(s) => { body = s#advBodySize, ruby = s#advRubySize, name = s#advNameSize }
    }

    /// NVL の頁の左上と折り返す幅。World が頁の切れ目をこの幅で数えるので、並べ方の組では変えない。
    pub def nvlText(): { x = Float64, y = Float64, width = Float64 } = { x = 110.0, y = 62.0, width = 740.0 }

    // ── 選択肢 ──

    /// i 番目（count 個のうち）の選択肢の矩形。ADV のウィンドウに被らないよう、ウィンドウの上の空きの真ん中へ並べる。
    pub def choice(fit: Fit, i: Int32, count: Int32): Rect2.Rect2 =
        let (x, w, h, gap) = match fit {
            case Fit.Regular  => (220.0, 520.0, 46.0, 12.0)
            case Fit.Small(s) => (180.0, 600.0, s#choiceHeight, 10.0)
        };
        let total = Int32.toFloat64(count) * h + Int32.toFloat64(count - 1) * gap;
        let top = advPanel(fit)#position#y / 2.0 + 4.0 - total / 2.0;
        rect(x, top + Int32.toFloat64(i) * (h + gap), w, h)

    pub def choiceTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 20.0
        case Fit.Small(s) => s#choiceTextSize
    }

    // ── クイックメニュー（下の帯） ──

    /// 下の帯の上端。
    def buttonTop(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 512.0
        case Fit.Small(s) => height() - s#buttonHeight
    }

    /// i 番目のボタン（count 個を画面の真ん中に並べる）。Small は左右に 8px ずつ残して画面の幅を同じ幅で分ける。
    pub def button(fit: Fit, i: Int32, count: Int32): Rect2.Rect2 =
        let (w, h) = match fit {
            case Fit.Regular  => (64.0, 24.0)
            case Fit.Small(s) => (Float64.min(96.0, (width() - 16.0) / Int32.toFloat64(Int32.max(1, count))), s#buttonHeight)
        };
        let x0 = (width() - Int32.toFloat64(count) * w) / 2.0;
        rect(x0 + Int32.toFloat64(i) * w, buttonTop(fit), w, h)

    pub def buttonTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 13.0
        case Fit.Small(s) => s#buttonTextSize
    }

    // ── タイトル ──

    /// 題の上端。
    pub def titleHeadingY(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 130.0
        case Fit.Small(_) => 18.0
    }

    /// subtitle の上端。
    pub def titleSubtitleY(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 222.0
        case Fit.Small(_) => 112.0
    }

    /// i 番目（count 個のうち）のメニューの項目。Small は subtitle の下から下の案内の上までの真ん中へ並べる。
    pub def titleItem(fit: Fit, i: Int32, count: Int32): Rect2.Rect2 = match fit {
        case Fit.Regular  => rect(380.0, 282.0 + Int32.toFloat64(i) * 36.0, 200.0, 32.0)
        case Fit.Small(s) =>
            let step = s#titleItemHeight + 2.0;
            let total = Int32.toFloat64(count) * step - 2.0;
            let top = (titleSubtitleY(fit) + 22.0 + 508.0) / 2.0 - total / 2.0;
            rect(340.0, top + Int32.toFloat64(i) * step, 280.0, s#titleItemHeight)
    }

    pub def titleItemTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 21.0
        case Fit.Small(s) => s#titleItemTextSize
    }

    // ── 画面の枠（セーブ・ロード・設定・バックログで同じ） ──

    /// 見出しの左上。
    pub def heading(): { x = Float64, y = Float64 } = { x = 64.0, y = 30.0 }

    /// 見出しの下の線の高さ。
    pub def rule(): Float64 = 78.0

    /// 右上の「戻る」。Small は見出しの下の線より上に収める。
    pub def back(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Regular  => rect(800.0, 32.0, 96.0, 32.0)
        case Fit.Small(s) => rect(780.0, rule() - 4.0 - s#backHeight, 140.0, s#backHeight)
    }

    pub def backTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 15.0
        case Fit.Small(s) => s#backTextSize
    }

    /// 画面の下の案内の高さ。
    pub def hintY(): Float64 = 508.0

    // ── セーブ・ロード ──

    /// ページのタブ j（左から）。
    pub def tab(fit: Fit, j: Int32): Rect2.Rect2 = match fit {
        case Fit.Regular  => rect(64.0 + Int32.toFloat64(j) * 92.0, 90.0, 86.0, 30.0)
        case Fit.Small(s) => rect(64.0 + Int32.toFloat64(j) * 116.0, rule() + 6.0, 110.0, s#tabHeight)
    }

    pub def tabTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 15.0
        case Fit.Small(s) => s#tabTextSize
    }

    /// 枠 i（2 列 × 3 行）。Small はタブの下から案内の上までを 3 行に分ける。
    pub def slot(fit: Fit, i: Int32): Rect2.Rect2 =
        let col = Int32.remainder(i, 2);
        let row = i / 2;
        let (top, step, h) = match fit {
            case Fit.Regular  => (132.0, 124.0, 114.0)
            case Fit.Small(_) =>
                let t = tab(fit, 0);
                let first = t#position#y + t#size#y + 6.0;
                let each = (hintY() - 4.0 - first) / 3.0;
                (first, each, each - 8.0)
        };
        rect(64.0 + Int32.toFloat64(col) * 424.0, top + Int32.toFloat64(row) * step, 408.0, h)

    /// 枠の中のサムネ（画面と同じ 16:9）。
    pub def thumb(fit: Fit, i: Int32): Rect2.Rect2 =
        let s = slot(fit, i);
        rect(s#position#x + 9.0, s#position#y + 9.0, 171.0, 96.0)

    /// 枠の右上の削除。
    pub def remove(fit: Fit, i: Int32): Rect2.Rect2 =
        let s = slot(fit, i);
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

    /// 設定の左の列（文章）に並べる行の数。残りは右の列（音と画面）。
    pub def leftColumnRows(): Int32 = 5

    /// 設定の i 行目（WorldSettings.settings の並び。左の列に leftColumnRows 行、残りは右の列）。
    pub def settingRow(fit: Fit, i: Int32): Rect2.Rect2 =
        let left = leftColumnRows();
        let (col, row) = if (i < left) (0, i) else (1, i - left);
        match fit {
            case Fit.Regular  => rect(columnX(col), 126.0 + Int32.toFloat64(row) * 56.0, 400.0, 44.0)
            case Fit.Small(s) => rect(columnX(col), 120.0 + Int32.toFloat64(row) * (s#settingRowHeight + 4.0), 420.0, s#settingRowHeight)
        }

    /// 行の中で、つまみの帯と 2 つから選ぶボタンが始まる所（行の左端から）。
    def settingControlX(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 160.0
        case Fit.Small(_) => 156.0
    }

    /// 行 i のつまみの帯（左端 = 最小・右端 = 最大）。
    pub def settingBar(fit: Fit, i: Int32): Rect2.Rect2 =
        let r = settingRow(fit, i);
        let w = match fit {
            case Fit.Regular  => 172.0
            case Fit.Small(_) => 150.0
        };
        rect(r#position#x + settingControlX(fit), r#position#y + (r#size#y - 6.0) / 2.0, w, 6.0)

    /// 行 i のつまみの帯をクリックで受ける範囲（帯より一回り大きい。Small は行の高さいっぱい）。
    pub def settingBarReach(fit: Fit, i: Int32): Rect2.Rect2 =
        let bar = settingBar(fit, i);
        let row = settingRow(fit, i);
        match fit {
            case Fit.Regular  => rect(bar#position#x - 10.0, bar#position#y - 16.0, bar#size#x + 20.0, bar#size#y + 32.0)
            case Fit.Small(_) => rect(bar#position#x - 10.0, row#position#y, bar#size#x + 20.0, row#size#y)
        }

    /// 行 i の 2 つから選ぶボタンの side 側。
    pub def settingSide(fit: Fit, i: Int32, side: Side): Rect2.Rect2 =
        let r = settingRow(fit, i);
        let x = r#position#x + settingControlX(fit);
        let col = Int32.toFloat64(columnOf(side));
        match fit {
            case Fit.Regular  => rect(x + col * 122.0, r#position#y + 6.0, 116.0, 32.0)
            case Fit.Small(_) => rect(x + col * 134.0, r#position#y, 130.0, r#size#y)
        }

    /// 押す行（初期設定に戻す）のボタン。
    pub def settingAction(fit: Fit, i: Int32): Rect2.Rect2 =
        let r = settingRow(fit, i);
        match fit {
            case Fit.Regular  => rect(r#position#x, r#position#y + 6.0, 238.0, 32.0)
            case Fit.Small(_) => rect(r#position#x, r#position#y, 238.0, r#size#y)
        }

    /// 設定の字: 行の名前・スライダーの値・2 つから選ぶボタン・押す行のボタンの大きさと、名前と値の字の行の上端からの下がり。
    pub type alias SettingText = { name = Float64, value = Float64, pair = Float64, action = Float64, nameTop = Float64, valueTop = Float64 }

    pub def settingText(fit: Fit): SettingText = match fit {
        case Fit.Regular  => { name = 16.0, value = 14.0, pair = 14.0, action = 15.0, nameTop = 12.0, valueTop = 13.0 }
        case Fit.Small(s) =>
            let size = s#settingTextSize;
            let top = (s#settingRowHeight - size) / 2.0;
            { name = size, value = size, pair = size, action = size, nameTop = top, valueTop = top }
    }

    /// 文字の速さの見本（左の列の下）。
    pub def preview(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Regular  => rect(64.0, 412.0, 400.0, 84.0)
        case Fit.Small(_) =>
            let last = settingRow(fit, leftColumnRows() - 1);
            let top = last#position#y + last#size#y + 8.0;
            rect(64.0, top, 400.0, hintY() - 10.0 - top)
    }

    /// 見本の文の、見本の枠の上端からの下がり。
    pub def previewTextInset(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 18.0
        case Fit.Small(_) => 8.0
    }

    // ── 確認のウィンドウ ──

    pub def askBox(): Rect2.Rect2 = rect(270.0, 186.0, 420.0, 168.0)

    /// 左がはい・右がいいえ。Small はボタンの下端をウィンドウの下端から 10px 上にそろえる。
    pub def askButton(fit: Fit, side: Side): Rect2.Rect2 =
        let x = 316.0 + Int32.toFloat64(columnOf(side)) * 172.0;
        match fit {
            case Fit.Regular  => rect(x, 290.0, 156.0, 40.0)
            case Fit.Small(s) => rect(x, askBox()#position#y + askBox()#size#y - 10.0 - s#askButtonHeight, 156.0, s#askButtonHeight)
        }

    pub def askButtonTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular  => 17.0
        case Fit.Small(s) => s#askButtonTextSize
    }
}
