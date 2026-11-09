// Rail — 縦の画面の右端の操作の列（しおり・ログ・オート）と右上の …、そこから開く小さなメニューの矩形と、押しの判定（純粋）。
// View が描く所と Controls が当てる所は、どちらもここの同じ関数から引く（Layout と同じ決まり）。
// 判定（judge）は World を受けず、押しの続き（画面を開く・ツールチップを出す）は Controls が Outcome で分けて行う。
// 大きさと積み方は novel.rail.json（PortraitDoc.Rec の rail）。横の画面に列は出さない（横は下の帯の字のボタン）。
mod Rail {
    use fge::{App, Clock, Rect2, Vec2}

    def rect(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 =
        { position = { x = x, y = y }, size = { x = w, y = h } }

    /// 縦の画面の列の Doc（横の画面は既定値。横に列と … は出さないので使われない）。
    pub def recOf(fit: Layout.Fit): RailDoc.Rec = match fit {
        case Layout.Fit.Portrait(p, _) => p#rail
        case _                         => RailDoc.rec(RailDoc.defaults())
    }

    /// … のメニューとしおりの選びの 1 項目の高さ（横の画面は使わない）。
    def menuItemHeight(fit: Layout.Fit): Float64 = match fit {
        case Layout.Fit.Portrait(p, _) => p#menuItemHeight
        case _                         => 44.0
    }

    /// 列のボタンの数（WorldMenu.buttonsOf の縦の並び）。
    def buttonCount(fit: Layout.Fit): Int32 = List.length(WorldMenu.buttonsOf(fit))

    // ── 列と … ──

    /// 列と … の丸の中心の x（右端から railRight の余白を空けた所に丸の右端が来る）。
    def centerX(fit: Layout.Fit): Float64 =
        let r = recOf(fit);
        Layout.width(fit) - r#railRight - r#iconSize / 2.0

    /// 列の i 番目（上から）の押せる正方形（辺 buttonHeight）。Top は … のすぐ下から下へ、Bottom は画面の下から上へ積む。
    // WhyNot: 列の並びを Doc で選ばせない — 並びを替えると、しおりの選びが開く高さと長押しの意味の付き方が作品ごとに崩れる。
    pub def button(fit: Layout.Fit, i: Int32): Rect2.Rect2 =
        let r = recOf(fit);
        let s = r#buttonHeight;
        let top = match r#anchor {
            case RailDoc.Anchor.Top(gap)       => r#moreTop + r#moreHeight + gap
            case RailDoc.Anchor.Bottom(bottom) => Layout.height(fit) - bottom - Int32.toFloat64(buttonCount(fit)) * s
        };
        rect(centerX(fit) - s / 2.0, top + Int32.toFloat64(i) * s, s, s)

    /// 列の i 番目の丸いアイコンの中心と半径（押せる正方形の真ん中）。
    pub def icon(fit: Layout.Fit, i: Int32): { center = Vec2.Vec2, radius = Float64 } =
        let hit = button(fit, i);
        { center = { x = hit#position#x + hit#size#x / 2.0, y = hit#position#y + hit#size#y / 2.0 }, radius = recOf(fit)#iconSize / 2.0 }

    /// 列の左端（頁・選択肢・しおりの選び・ツールチップはこれより左に置く）。
    pub def left(fit: Layout.Fit): Float64 = centerX(fit) - recOf(fit)#buttonHeight / 2.0

    /// 右上の … の丸（中心と半径）と押せる正方形。中心の x は列と同じ（列と 1 本の縦にそろう）。
    pub def moreButton(fit: Layout.Fit): { center = Vec2.Vec2, radius = Float64, hit = Rect2.Rect2 } =
        let r = recOf(fit);
        let s = r#moreHeight;
        let c = { x = centerX(fit), y = r#moreTop + s / 2.0 };
        { center = c, radius = r#moreSize / 2.0, hit = rect(c#x - s / 2.0, c#y - s / 2.0, s, s) }

    // ── … のメニュー・しおりの選び・ツールチップ ──

    /// … のメニューの i 番目の項目。… の下に、右端を画面の右の余白にそろえて縦に並べる。
    pub def menuItem(fit: Layout.Fit, i: Int32): Rect2.Rect2 =
        let r = recOf(fit);
        let more = moreButton(fit)#hit;
        let h = menuItemHeight(fit);
        let right = Layout.width(fit) - r#railRight;
        rect(right - r#menuWidth, more#position#y + more#size#y + 10.0 + Int32.toFloat64(i) * h, r#menuWidth, h)

    /// … のメニューの地（count 個の項目を囲む余白つきの矩形）。
    pub def menuBox(fit: Layout.Fit, count: Int32): Rect2.Rect2 = boxAround(menuItem(fit, 0), menuItem(fit, count - 1))

    /// しおりのボタンの列の中の番号。
    def saveLoadIndex(fit: Layout.Fit): Int32 =
        WorldMenu.buttonsOf(fit) |> List.zipWithIndex |> List.find(match (_, b) -> b == World.Button.SaveLoad)
            |> Option.map(fst) |> Option.getWithDefault(0)

    /// しおりの選びの i 番目（左から [セーブ｜ロード]）。しおりのボタンの左に、丸の高さの真ん中で横に並べる。
    pub def saveLoadItem(fit: Layout.Fit, i: Int32, count: Int32): Rect2.Rect2 =
        let mark = button(fit, saveLoadIndex(fit));
        let w = recOf(fit)#saveLoadItemWidth;
        let h = menuItemHeight(fit);
        let right = left(fit) - 12.0;
        rect(right - Int32.toFloat64(count) * w + Int32.toFloat64(i) * w, mark#position#y + mark#size#y / 2.0 - h / 2.0, w, h)

    /// しおりの選びの地（count 個の項目を囲む余白つきの矩形）。
    pub def saveLoadBox(fit: Layout.Fit, count: Int32): Rect2.Rect2 = boxAround(saveLoadItem(fit, 0, count), saveLoadItem(fit, count - 1, count))

    /// 最初と最後の項目を 8 px の余白で囲む矩形。
    def boxAround(first: Rect2.Rect2, last: Rect2.Rect2): Rect2.Rect2 =
        rect(first#position#x - 8.0, first#position#y - 8.0,
             last#position#x + last#size#x - first#position#x + 16.0, last#position#y + last#size#y - first#position#y + 16.0)

    /// 長押しのツールチップの右端と真ん中の高さ（i 番目のボタンの押せる正方形の左）。
    pub def tooltipAnchor(fit: Layout.Fit, i: Int32): Vec2.Vec2 =
        let r = button(fit, i);
        { x = r#position#x - 4.0, y = r#position#y + r#size#y / 2.0 }

    pub def tooltipTextSize(fit: Layout.Fit): Float64 = recOf(fit)#tooltipTextSize

    // ── 押しの判定 ──

    /// このフレームの押し（マウスの左ボタンとブラウザ版の指）。Pressed = このフレームで押し始めた、Down = 押したまま、Up = 押していない。
    pub enum Pointer with Eq, ToString {
        case Pressed
        case Down
        case Up
    }

    /// 判定に使うこのフレームの入力。touchHold = 指の長押しのキー（KeysDoc の touchHold）がこのフレームに届いた。
    pub type alias Input = { cursor = { x = Float64, y = Float64 }, pointer = Pointer, touchHold = Bool }

    /// フレームから判定の入力を作る。
    pub def inputOf(frame: App.Frame, touchHold: Bool): Input =
        let pointer = if (frame#mouseClicked) Pointer.Pressed else if (frame#mouseDown) Pointer.Down else Pointer.Up;
        { cursor = frame#cursor, pointer = pointer, touchHold = touchHold }

    /// 判定の結果。Begin(i) = 列の i 番目で押し始めた、Tap(i) = 長押しの秒に届く前に離した、Long(i) = 押したまま長押しの秒を越えている、
    /// Held(i) = まだ押している（長押しの秒の前）、Released = 長押しの後に離した、TouchLong(i) = 列の i 番目の上で指の長押しが届いた、
    /// MoreOpen = … を押した、Swallow = … の上の指の長押し（何もしない）、Pass = 列とも … とも関係が無い。
    pub enum Outcome with Eq, ToString {
        case Begin(Int32)
        case Tap(Int32)
        case Long(Int32)
        case Held(Int32)
        case Released
        case TouchLong(Int32)
        case MoreOpen
        case Swallow
        case Pass
    }

    /// 縦の画面の読む間の押しを判定する。grab = 押している間の掴み（LongPress なら押し始めた時刻）、now = このフレームの実時間。
    pub def judge(fit: Layout.Fit, input: Input, grab: World.Grab, now: Clock.Time[Clock.Real]): Outcome = match grab {
        case World.Grab.LongPress(i, since) => pressing(fit, input, i, Clock.since(since, now))
        case _                              => fresh(fit, input)
    }

    /// 列の i 番目を held 秒押している。
    def pressing(fit: Layout.Fit, input: Input, i: Int32, held: Float64): Outcome =
        let long = held >= recOf(fit)#longPressSeconds;
        let up = input#pointer == Pointer.Up;
        if (up and long) Outcome.Released
        else if (up) Outcome.Tap(i)
        else if (long) Outcome.Long(i)
        else Outcome.Held(i)

    /// 列を押していない時の判定。
    // WhyNot: … の上の指の長押しで隠すにしない — … を押そうとした指で、文章のウィンドウが消える。
    def fresh(fit: Layout.Fit, input: Input): Outcome =
        let onRail = Layout.hitOf(buttonCount(fit), button(fit), input#cursor);
        let overMore = Layout.contains(moreButton(fit)#hit, input#cursor);
        let pressed = input#pointer == Pointer.Pressed;
        match onRail {
            case Some(i) if pressed         => Outcome.Begin(i)
            case Some(i) if input#touchHold => Outcome.TouchLong(i)
            case _ =>
                if (pressed and overMore) Outcome.MoreOpen
                else if (input#touchHold and overMore) Outcome.Swallow
                else Outcome.Pass
        }
}
