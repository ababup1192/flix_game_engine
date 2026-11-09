// Layout — 画面の置き場所（design の中の矩形）と、押せる物の字の大きさ。View が描く所と Controls がクリックを当てる所は、
// どちらもここの同じ関数から、同じ Fit を渡して引く（描いた所と押せる所がずれない）。
// 置き場所は「振り付け」なのでコードに置く。本文の字の大きさ・行の数のような手触りは novel.kind.json、
// 小さい画面（スマホ）の時の大きさは novel.small.json、縦の画面の時の大きさは novel.portrait.json。
mod Layout {
    use fge::{Display, Rect2, Vec2}

    /// 並べ方の組。Regular = PC・タブレット・デスクトップ版（マウスで押す大きさ）、
    /// Small = 横に持ったスマホ（指で押せる大きさ。大きさは novel.small.json）。どちらも design は 960×540。
    /// Portrait = 縦の design で起動した時（大きさは novel.portrait.json・画面の大きさは起動の時に決まった縦の design）。
    /// NVL の頁の切れ目は World が横の幅で数えるので、どの組でも同じ（nvlText は Fit を受けない）。
    pub enum Fit {
        case Regular
        case Small(SmallScreenDoc.Rec)
        case Portrait(PortraitDoc.Rec, Vec2.Vec2)
    }

    /// 並べ方の組を選ぶ。orientation = design の向き（View は ViewCtx#display#orientation、Controls は Display.orientationOf(Frame#viewport)）、
    /// screen = design の大きさ（View は ViewCtx#visible#size、Controls は Frame#viewport）、sizeClass = 端末の区分。
    /// WhyNot: Medium（タブレット）に Small の組を使わない — 倍率が 1 を超える横持ちなら 960×540 のままでも押せる大きさに近い。
    /// 縦持ちの小さいタブレットと下の帯のボタンは 44 CSS px に届かないので、足りなければ Medium の組を novel.small.json に足す。
    // WhyNot: 向きだけで Portrait にしない — 画面の大きさが縦長でなければ（読めない・0）、縦の置き場所の計算が崩れる。横の組へ落とす。
    pub def fitOf(sizeClass: Display.SizeClass, orientation: Display.Orientation, screen: Vec2.Vec2,
                  small: SmallScreenDoc.Doc, portrait: PortraitDoc.Doc): Fit =
        if (orientation == Display.Orientation.Portrait and screen#y > screen#x and screen#x > 0.0)
            Fit.Portrait(PortraitDoc.rec(portrait), screen)
        else match sizeClass {
            case Display.SizeClass.Small  => Fit.Small(SmallScreenDoc.rec(small))
            case Display.SizeClass.Medium => Fit.Regular
            case Display.SizeClass.Large  => Fit.Regular
        }

    /// 横の画面の大きさ（project.json の designWidth / designHeight と同じ値）。
    def landscapeSize(): Vec2.Vec2 = { x = 960.0, y = 540.0 }

    /// 画面の大きさ（横は 960×540、縦は起動の時に決まった縦の design）。
    pub def size(fit: Fit): Vec2.Vec2 = match fit {
        case Fit.Portrait(_, s) => s
        case _                  => landscapeSize()
    }

    pub def width(fit: Fit): Float64 = size(fit)#x
    pub def height(fit: Fit): Float64 = size(fit)#y

    /// 縦の画面か。
    pub def isPortrait(fit: Fit): Bool = match fit {
        case Fit.Portrait(_, _) => true
        case _                  => false
    }

    /// 縦の画面の左右の余白。
    def margin(): Float64 = 32.0

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

    pub def screen(fit: Fit): Rect2.Rect2 = rect(0.0, 0.0, width(fit), height(fit))

    pub def contains(r: Rect2.Rect2, p: { x = Float64, y = Float64 }): Bool =
        p#x >= r#position#x and p#x < r#position#x + r#size#x and p#y >= r#position#y and p#y < r#position#y + r#size#y

    /// 0 から count − 1 のうち、r(i) が p を含む最初の番号。
    pub def hitOf(count: Int32, r: Int32 -> Rect2.Rect2, p: { x = Float64, y = Float64 }): Option[Int32] =
        List.range(0, count) |> List.find(i -> contains(r(i), p))

    // ── 文章 ──

    /// ADV のウィンドウ。Small は下の帯のボタンのすぐ上に置く（縦の画面は頁に出すので使わない）。
    pub def advPanel(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Regular        => rect(40.0, 348.0, 880.0, 160.0)
        case Fit.Small(s)       => rect(40.0, buttonTop(fit) - 4.0 - s#advPanelHeight, 880.0, s#advPanelHeight)
        case Fit.Portrait(_, _) => page(fit, 0)
    }

    /// ADV の名前の左上。
    pub def advName(fit: Fit): { x = Float64, y = Float64 } = { x = 72.0, y = advPanel(fit)#position#y + 12.0 }

    /// ADV の本文の左上と折り返す幅（1 行目のルビは左上より上に出る）。
    pub def advText(fit: Fit): { x = Float64, y = Float64, width = Float64 } =
        let top = advPanel(fit)#position#y;
        match fit {
            case Fit.Regular        => { x = 72.0, y = top + 52.0, width = 816.0 }
            case Fit.Small(s)       => { x = 72.0, y = top + 34.0 + s#advNameSize, width = 816.0 }
            case Fit.Portrait(_, _) => { x = margin(), y = top, width = width(fit) - 2.0 * margin() }
        }

    /// ADV の本文・ルビ・名前の字の大きさ（Regular は novel.kind.json の値のまま）。
    pub def advTextSizes(fit: Fit, kind: KindDoc.Rec): { body = Float64, ruby = Float64, name = Float64 } = match fit {
        case Fit.Regular        => { body = kind#bodySize, ruby = kind#rubySize, name = kind#nameSize }
        case Fit.Small(s)       => { body = s#advBodySize, ruby = s#advRubySize, name = s#advNameSize }
        case Fit.Portrait(p, _) => { body = p#bodySize, ruby = p#rubySize, name = p#nameSize }
    }

    /// NVL の頁の左上と折り返す幅（横の画面）。World が頁の切れ目をこの幅で数えるので、並べ方の組では変えない。
    pub def nvlText(): { x = Float64, y = Float64, width = Float64 } = { x = 110.0, y = 62.0, width = 740.0 }

    // ── 縦の画面の頁 ──

    /// 縦の画面の頁（文を上から積む範囲。幅は折り返す幅）。choiceCount 個の選択肢を出している間は、その上までに縮める。
    // WhyNot: 折り返す幅を余白いっぱいにしない — 行末の句読点はぶら下げで幅の外へ出るので、右の余白が左より狭く見える。
    pub def page(fit: Fit, choiceCount: Int32): Rect2.Rect2 =
        let top = 96.0;
        let bottom = if (choiceCount > 0) choice(fit, 0, choiceCount)#position#y - 20.0 else buttonTop(fit) - 18.0;
        rect(margin(), top, width(fit) - 2.0 * margin() - 16.0, Float64.max(0.0, bottom - top))

    /// 縦の画面の頁で、行と行の間の空き。
    pub def paragraphGap(): Float64 = 26.0

    // ── 選択肢 ──

    /// i 番目（count 個のうち）の選択肢の矩形。横は ADV のウィンドウに被らないよう、ウィンドウの上の空きの真ん中へ並べる。
    /// 縦は頁の下（操作の列の上）へ下から積む。
    pub def choice(fit: Fit, i: Int32, count: Int32): Rect2.Rect2 = match fit {
        case Fit.Regular        => landscapeChoice(fit, { x = 220.0, w = 520.0, h = 46.0, gap = 12.0 }, i, count)
        case Fit.Small(s)       => landscapeChoice(fit, { x = 180.0, w = 600.0, h = s#choiceHeight, gap = 10.0 }, i, count)
        case Fit.Portrait(p, _) =>
            let gap = 12.0;
            let total = Int32.toFloat64(count) * p#choiceHeight + Int32.toFloat64(count - 1) * gap;
            let top = buttonTop(fit) - 20.0 - total;
            rect(margin(), top + Int32.toFloat64(i) * (p#choiceHeight + gap), width(fit) - 2.0 * margin(), p#choiceHeight)
    }

    /// 横の画面の選択肢: ADV のウィンドウの上の空きの真ん中へ、幅 w・高さ h・間 gap で並べる。
    def landscapeChoice(fit: Fit, shape: { x = Float64, w = Float64, h = Float64, gap = Float64 }, i: Int32, count: Int32): Rect2.Rect2 =
        let total = Int32.toFloat64(count) * shape#h + Int32.toFloat64(count - 1) * shape#gap;
        let top = advPanel(fit)#position#y / 2.0 + 4.0 - total / 2.0;
        rect(shape#x, top + Int32.toFloat64(i) * (shape#h + shape#gap), shape#w, shape#h)

    pub def choiceTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 20.0
        case Fit.Small(s)       => s#choiceTextSize
        case Fit.Portrait(p, _) => p#choiceTextSize
    }

    // ── クイックメニュー（下の帯） ──

    /// 下の帯の上端。
    def buttonTop(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 512.0
        case Fit.Small(s)       => height(fit) - s#buttonHeight
        case Fit.Portrait(p, _) => height(fit) - 26.0 - p#buttonHeight
    }

    /// i 番目のボタン（count 個を画面の真ん中に並べる）。Small は左右に 8px ずつ残して画面の幅を同じ幅で分ける。
    /// 縦は丸いアイコンの直径に間 35 px を足した幅で真ん中に寄せる（375 幅の画面で丸の中心どうしが 58 CSS px・押せる幅は buttonHeight 以上）。
    pub def button(fit: Fit, i: Int32, count: Int32): Rect2.Rect2 =
        let n = Int32.toFloat64(Int32.max(1, count));
        let (w, h) = match fit {
            case Fit.Regular        => (64.0, 24.0)
            case Fit.Small(s)       => (Float64.min(96.0, (width(fit) - 16.0) / n), s#buttonHeight)
            case Fit.Portrait(p, _) => (Float64.max(p#buttonHeight, p#iconSize + 35.0), p#buttonHeight)
        };
        let x0 = (width(fit) - Int32.toFloat64(count) * w) / 2.0;
        rect(x0 + Int32.toFloat64(i) * w, buttonTop(fit), w, h)

    /// 横の画面のボタンの字の大きさ（縦の画面は字の無いアイコン）。
    pub def buttonTextSize(fit: Fit): Float64 = match fit {
        case Fit.Small(s) => s#buttonTextSize
        case _            => 13.0
    }

    /// 縦の画面の i 番目のボタンの丸いアイコンの中心と半径（押せる矩形 button の真ん中）。
    pub def icon(fit: Fit, i: Int32, count: Int32): { center = Vec2.Vec2, radius = Float64 } =
        let r = button(fit, i, count);
        let diameter = match fit {
            case Fit.Portrait(p, _) => p#iconSize
            case _                  => Float64.min(r#size#x, r#size#y)
        };
        { center = { x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 }, radius = diameter / 2.0 }

    // ── 縦の画面の歯車のメニュー ──

    /// メニューの i 番目（count 個のうち）の項目。歯車（操作の列の最後）の右端にそろえ、列の上へ下から積む。
    pub def menuItem(fit: Fit, i: Int32, count: Int32, buttonCount: Int32): Rect2.Rect2 =
        let gear = button(fit, buttonCount - 1, buttonCount);
        let h = match fit {
            case Fit.Portrait(p, _) => p#menuItemHeight
            case _                  => 44.0
        };
        let w = 240.0;
        let right = Float64.min(width(fit) - margin(), gear#position#x + gear#size#x);
        let top = gear#position#y - 16.0 - Int32.toFloat64(count) * h;
        rect(right - w, top + Int32.toFloat64(i) * h, w, h)

    /// メニューの地（項目を囲む余白つきの矩形）。
    pub def menuBox(fit: Fit, count: Int32, buttonCount: Int32): Rect2.Rect2 =
        let first = menuItem(fit, 0, count, buttonCount);
        let last = menuItem(fit, count - 1, count, buttonCount);
        rect(first#position#x - 8.0, first#position#y - 8.0, first#size#x + 16.0, last#position#y + last#size#y - first#position#y + 16.0)

    pub def menuItemTextSize(fit: Fit): Float64 = match fit {
        case Fit.Portrait(p, _) => p#menuItemTextSize
        case _                  => 18.0
    }

    // ── タイトル ──

    /// 題の上端。
    pub def titleHeadingY(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 130.0
        case Fit.Small(_)       => 18.0
        case Fit.Portrait(_, _) => Float64.floor(height(fit) * 0.2)
    }

    /// subtitle の上端。
    pub def titleSubtitleY(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 222.0
        case Fit.Small(_)       => 112.0
        case Fit.Portrait(_, _) => titleHeadingY(fit) + 96.0
    }

    /// タイトル画面のメニューを並べる下の端（Small と縦は subtitle の下からここまでの真ん中へ寄せる）。
    pub def titleMenuBottomY(fit: Fit): Float64 = match fit {
        case Fit.Portrait(_, _) => height(fit) - 48.0
        case _                  => 512.0
    }

    /// i 番目（count 個のうち）のメニューの項目。Small と縦は subtitle の下から titleMenuBottomY までの真ん中へ並べる。
    pub def titleItem(fit: Fit, i: Int32, count: Int32): Rect2.Rect2 =
        let centered = (itemHeight, x, w) -> {
            let step = itemHeight + 2.0;
            let total = Int32.toFloat64(count) * step - 2.0;
            let top = (titleSubtitleY(fit) + 22.0 + titleMenuBottomY(fit) - 4.0) / 2.0 - total / 2.0;
            rect(x, top + Int32.toFloat64(i) * step, w, itemHeight)
        };
        match fit {
            case Fit.Regular        => rect(380.0, 282.0 + Int32.toFloat64(i) * 36.0, 200.0, 32.0)
            case Fit.Small(s)       => centered(s#titleItemHeight, 340.0, 280.0)
            case Fit.Portrait(p, _) => centered(p#titleItemHeight, (width(fit) - 300.0) / 2.0, 300.0)
        }

    pub def titleItemTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 21.0
        case Fit.Small(s)       => s#titleItemTextSize
        case Fit.Portrait(p, _) => p#titleItemTextSize
    }

    // ── 画面の枠（セーブ・ロード・設定・バックログで同じ） ──

    /// 見出しの左上。
    pub def heading(fit: Fit): { x = Float64, y = Float64 } = match fit {
        case Fit.Portrait(_, _) => { x = margin(), y = 44.0 }
        case _                  => { x = 64.0, y = 30.0 }
    }

    /// 見出しの下の線の高さ。
    pub def rule(fit: Fit): Float64 = match fit {
        case Fit.Portrait(_, _) => 96.0
        case _                  => 78.0
    }

    /// 右上の「戻る」。Small と縦は見出しの下の線より上に収める。
    pub def back(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Regular        => rect(800.0, 32.0, 96.0, 32.0)
        case Fit.Small(s)       => rect(780.0, rule(fit) - 4.0 - s#backHeight, 140.0, s#backHeight)
        case Fit.Portrait(p, _) => rect(width(fit) - margin() - 120.0, rule(fit) - 6.0 - p#backHeight, 120.0, p#backHeight)
    }

    pub def backTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 15.0
        case Fit.Small(s)       => s#backTextSize
        case Fit.Portrait(p, _) => p#backTextSize
    }

    /// 画面の下の案内の高さ。
    pub def hintY(fit: Fit): Float64 = match fit {
        case Fit.Portrait(_, _) => height(fit) - 40.0
        case _                  => 508.0
    }

    // ── セーブ・ロード ──

    /// ページのタブ j（左から・count 個のうち）。縦は count 個（5 つ以上の幅にはしない）を横いっぱいに分ける。
    pub def tab(fit: Fit, count: Int32, j: Int32): Rect2.Rect2 = match fit {
        case Fit.Regular        => rect(64.0 + Int32.toFloat64(j) * 92.0, 90.0, 86.0, 30.0)
        case Fit.Small(s)       => rect(64.0 + Int32.toFloat64(j) * 116.0, rule(fit) + 6.0, 110.0, s#tabHeight)
        case Fit.Portrait(p, _) =>
            let n = Int32.toFloat64(Int32.max(count, 4));
            let w = (width(fit) - 2.0 * margin() - (n - 1.0) * 6.0) / n;
            rect(margin() + Int32.toFloat64(j) * (w + 6.0), rule(fit) + 10.0, w, p#tabHeight)
    }

    pub def tabTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 15.0
        case Fit.Small(s)       => s#tabTextSize
        case Fit.Portrait(p, _) => p#tabTextSize
    }

    /// 枠の列の数（横は 2 列 × 3 行、縦は 1 列 × 6 行）。上下のキーはこの数だけ枠を動かす。
    pub def slotColumns(fit: Fit): Int32 = if (isPortrait(fit)) 1 else 2

    /// 枠 i。Small と縦はタブの下から案内の上までを行の数で分ける。
    pub def slot(fit: Fit, i: Int32): Rect2.Rect2 =
        let columns = slotColumns(fit);
        let rows = Saves.perPage() / columns;
        let col = Int32.remainder(i, columns);
        let row = i / columns;
        let fill = () -> {
            let t = tab(fit, 1, 0);
            let first = t#position#y + t#size#y + 6.0;
            let each = (hintY(fit) - 4.0 - first) / Int32.toFloat64(rows);
            (first, each, each - 8.0)
        };
        let (top, step, h) = match fit {
            case Fit.Regular => (132.0, 124.0, 114.0)
            case _           => fill()
        };
        match fit {
            case Fit.Portrait(_, _) => rect(margin(), top + Int32.toFloat64(row) * step, width(fit) - 2.0 * margin(), h)
            case _                  => rect(64.0 + Int32.toFloat64(col) * 424.0, top + Int32.toFloat64(row) * step, 408.0, h)
        }

    /// 枠の中のサムネ（画面と同じ縦横の比。横は 171×96、縦は枠の高さに合わせる）。
    pub def thumb(fit: Fit, i: Int32): Rect2.Rect2 =
        let s = slot(fit, i);
        match fit {
            case Fit.Portrait(_, _) =>
                let h = s#size#y - 18.0;
                rect(s#position#x + 9.0, s#position#y + 9.0, h * width(fit) / height(fit), h)
            case _ => rect(s#position#x + 9.0, s#position#y + 9.0, 171.0, 96.0)
        }

    /// 枠の右上の削除（縦は指で押せる大きさ）。
    pub def remove(fit: Fit, i: Int32): Rect2.Rect2 =
        let s = slot(fit, i);
        match fit {
            case Fit.Portrait(_, _) => rect(s#position#x + s#size#x - 68.0, s#position#y + 2.0, 66.0, 66.0)
            case _                  => rect(s#position#x + s#size#x - 30.0, s#position#y + 6.0, 24.0, 24.0)
        }

    // ── バックログ ──

    /// 読む範囲（横は名前の列 + 本文の列、縦は名前を本文の上に置く 1 列）。
    pub def logView(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Portrait(_, _) =>
            let top = rule(fit) + 14.0;
            rect(margin(), top, width(fit) - 2.0 * margin() - 12.0, hintY(fit) - 10.0 - top)
        case _ => rect(64.0, 92.0, 800.0, 404.0)
    }

    /// 名前の列の右端（横。名前は右へ寄せる）。
    pub def logNameRight(): Float64 = 196.0

    /// 本文の列の左端と幅。
    pub def logText(fit: Fit): { x = Float64, width = Float64 } = match fit {
        case Fit.Portrait(_, _) => { x = margin(), width = logView(fit)#size#x - 8.0 }
        case _                  => { x = 220.0, width = 630.0 }
    }

    /// スクロールバーの溝。
    pub def logTrack(fit: Fit): Rect2.Rect2 =
        let view = logView(fit);
        match fit {
            case Fit.Portrait(_, _) => rect(width(fit) - margin() - 4.0, view#position#y, 4.0, view#size#y)
            case _                  => rect(884.0, 92.0, 4.0, 404.0)
        }

    // ── 設定（横は 2 列・縦は 1 列） ──

    /// 列 col（0 = 左・1 = 右）の左端。
    def columnX(col: Int32): Float64 = 64.0 + Int32.toFloat64(col) * 432.0

    /// 設定の左の列（文章）に並べる行の数。残りは右の列（音と画面）。縦は同じ順で 1 列に積む。
    pub def leftColumnRows(): Int32 = 5

    /// 縦の画面で、群 col の見出しの上端。
    def portraitGroupY(fit: Fit, rowHeight: Float64, col: Int32): Float64 =
        let first = rule(fit) + 14.0;
        if (col == 0) first else first + 34.0 + Int32.toFloat64(leftColumnRows()) * (rowHeight + 4.0) + 10.0

    /// 群の見出しの左上（横は列の頭、縦は群の頭）。
    pub def group(fit: Fit, col: Int32): { x = Float64, y = Float64 } = match fit {
        case Fit.Portrait(p, _) => { x = margin(), y = portraitGroupY(fit, p#settingRowHeight, col) }
        case _                  => { x = columnX(col), y = 92.0 }
    }

    /// 群の見出しの下の線の長さ。
    pub def groupRuleWidth(fit: Fit): Float64 = if (isPortrait(fit)) width(fit) - 2.0 * margin() else 400.0

    /// 設定の i 行目（WorldSettings.settings の並び。左の列に leftColumnRows 行、残りは右の列）。
    pub def settingRow(fit: Fit, i: Int32): Rect2.Rect2 =
        let left = leftColumnRows();
        let (col, row) = if (i < left) (0, i) else (1, i - left);
        match fit {
            case Fit.Regular        => rect(columnX(col), 126.0 + Int32.toFloat64(row) * 56.0, 400.0, 44.0)
            case Fit.Small(s)       => rect(columnX(col), 120.0 + Int32.toFloat64(row) * (s#settingRowHeight + 4.0), 420.0, s#settingRowHeight)
            case Fit.Portrait(p, _) =>
                let top = portraitGroupY(fit, p#settingRowHeight, col) + 34.0;
                rect(margin(), top + Int32.toFloat64(row) * (p#settingRowHeight + 4.0), width(fit) - 2.0 * margin(), p#settingRowHeight)
        }

    /// 行の中で、つまみの帯と 2 つから選ぶボタンが始まる所（行の左端から）。
    def settingControlX(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 160.0
        case Fit.Small(_)       => 156.0
        case Fit.Portrait(_, _) => 176.0
    }

    /// スライダーの値の字で一番長い物の幅（字の大きさを 1 とした時）。「ノーウェイト」の全角 6 字。
    pub def settingValueEms(): Float64 = 6.0

    /// つまみの帯の右端から値の字の左端までの空き（選んだ時のつまみの半径 8 と、その外の 16）。
    pub def settingValueGap(): Float64 = 24.0

    /// 行 i のつまみの帯（左端 = 最小・右端 = 最大）。右端は、行の右に寄せた一番長い値の字に、最大にしたつまみが重ならない所。
    pub def settingBar(fit: Fit, i: Int32): Rect2.Rect2 =
        let r = settingRow(fit, i);
        let valueWidth = settingValueEms() * settingText(fit)#value;
        let w = r#size#x - settingControlX(fit) - valueWidth - settingValueGap();
        rect(r#position#x + settingControlX(fit), r#position#y + (r#size#y - 6.0) / 2.0, w, 6.0)

    /// 行 i のつまみの帯をクリックで受ける範囲（帯より一回り大きい。Small と縦は行の高さいっぱい）。
    pub def settingBarReach(fit: Fit, i: Int32): Rect2.Rect2 =
        let bar = settingBar(fit, i);
        let row = settingRow(fit, i);
        match fit {
            case Fit.Regular => rect(bar#position#x - 10.0, bar#position#y - 16.0, bar#size#x + 20.0, bar#size#y + 32.0)
            case _           => rect(bar#position#x - 10.0, row#position#y, bar#size#x + 20.0, row#size#y)
        }

    /// 行 i の 2 つから選ぶボタンの side 側。
    pub def settingSide(fit: Fit, i: Int32, side: Side): Rect2.Rect2 =
        let r = settingRow(fit, i);
        let x = r#position#x + settingControlX(fit);
        let col = Int32.toFloat64(columnOf(side));
        match fit {
            case Fit.Regular        => rect(x + col * 122.0, r#position#y + 6.0, 116.0, 32.0)
            case Fit.Small(_)       => rect(x + col * 134.0, r#position#y, 130.0, r#size#y)
            case Fit.Portrait(_, _) =>
                let w = (r#position#x + r#size#x - x - 6.0) / 2.0;
                rect(x + col * (w + 6.0), r#position#y, w, r#size#y)
        }

    /// 押す行（初期設定に戻す）のボタン。
    pub def settingAction(fit: Fit, i: Int32): Rect2.Rect2 =
        let r = settingRow(fit, i);
        match fit {
            case Fit.Regular => rect(r#position#x, r#position#y + 6.0, 238.0, 32.0)
            case _           => rect(r#position#x, r#position#y, 238.0, r#size#y)
        }

    /// 設定の字: 行の名前・スライダーの値・2 つから選ぶボタン・押す行のボタンの大きさと、名前と値の字の行の上端からの下がり。
    pub type alias SettingText = { name = Float64, value = Float64, pair = Float64, action = Float64, nameTop = Float64, valueTop = Float64 }

    pub def settingText(fit: Fit): SettingText =
        let fitted = (size, rowHeight) -> {
            let top = (rowHeight - size) / 2.0;
            { name = size, value = size, pair = size, action = size, nameTop = top, valueTop = top }
        };
        match fit {
            case Fit.Regular        => { name = 16.0, value = 14.0, pair = 14.0, action = 15.0, nameTop = 12.0, valueTop = 13.0 }
            case Fit.Small(s)       => fitted(s#settingTextSize, s#settingRowHeight)
            case Fit.Portrait(p, _) => fitted(p#settingTextSize, p#settingRowHeight)
        }

    /// 文字の速さの見本（横は左の列の下・縦は最後の行の下）。縦で 70 px の高さが取れない時は None（出さない）。
    pub def preview(fit: Fit): Option[Rect2.Rect2] = match fit {
        case Fit.Regular        => Some(rect(64.0, 412.0, 400.0, 84.0))
        case Fit.Small(_)       =>
            let last = settingRow(fit, leftColumnRows() - 1);
            let top = last#position#y + last#size#y + 8.0;
            Some(rect(64.0, top, 400.0, hintY(fit) - 10.0 - top))
        case Fit.Portrait(_, _) =>
            let last = settingRow(fit, List.length(WorldSettings.settings()) - 1);
            let top = last#position#y + last#size#y + 14.0;
            let h = Float64.min(110.0, height(fit) - 24.0 - top);
            if (h < 70.0) None else Some(rect(margin(), top, width(fit) - 2.0 * margin(), h))
    }

    /// 見本の文の、見本の枠の上端からの下がり。
    pub def previewTextInset(fit: Fit): Float64 = match fit {
        case Fit.Regular => 18.0
        case _           => 8.0
    }

    // ── 確認のウィンドウ ──

    pub def askBox(fit: Fit): Rect2.Rect2 = match fit {
        case Fit.Portrait(_, _) => rect(margin(), Float64.floor(height(fit) * 0.38), width(fit) - 2.0 * margin(), 200.0)
        case _                  => rect(270.0, 186.0, 420.0, 168.0)
    }

    /// 左がはい・右がいいえ。Small と縦はボタンの下端をウィンドウの下端から 10px 上にそろえる。
    pub def askButton(fit: Fit, side: Side): Rect2.Rect2 =
        let box = askBox(fit);
        let col = Int32.toFloat64(columnOf(side));
        match fit {
            case Fit.Regular        => rect(316.0 + col * 172.0, 290.0, 156.0, 40.0)
            case Fit.Small(s)       => rect(316.0 + col * 172.0, box#position#y + box#size#y - 10.0 - s#askButtonHeight, 156.0, s#askButtonHeight)
            case Fit.Portrait(p, _) =>
                let w = (box#size#x - 3.0 * 16.0) / 2.0;
                rect(box#position#x + 16.0 + col * (w + 16.0), box#position#y + box#size#y - 14.0 - p#askButtonHeight, w, p#askButtonHeight)
        }

    pub def askButtonTextSize(fit: Fit): Float64 = match fit {
        case Fit.Regular        => 17.0
        case Fit.Small(s)       => s#askButtonTextSize
        case Fit.Portrait(p, _) => p#askButtonTextSize
    }
}
