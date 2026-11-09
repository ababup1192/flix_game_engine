// Gesture — 1 回の押し（押した・動いた・離した）を、離した時にタップ・払い・長押し・ドラッグのどれかに分ける（純粋）。
// 読む画面の送りはタップだけを使う。押している間はどれにも決めず、離したフレームで 1 度だけ決める。
// マウスの左ボタンと、ブラウザ版の指（fge-web.js が離した時のタップを 1 フレームの押しに、横に動かす指を押したままの左ボタンに読み替えた物）が同じ道を通る。
mod Gesture {
    use fge::{App, Clock, Vec2}

    /// 分ける時の数（KindDoc の tapSlop・longPressSeconds・swipeMin・swipeSeconds）。
    /// slop = 押した所からこれより離れたら動いた押し（design px）、longPressSeconds = 動かさずにこれ以上置いたら長押し、
    /// swipeMin / swipeSeconds = 押した所から離した所までこれ以上の長さを、この秒の内に動かしたら払い（それ以外の動いた押しはドラッグ）。
    pub type alias Limits = { slop = Float64, longPressSeconds = Float64, swipeMin = Float64, swipeSeconds = Float64 }

    /// 押している 1 回。at = 押した所、since = 押した実時間、reach = 押した所から一番離れた長さ。
    pub type alias Press = { at = { x = Float64, y = Float64 }, since = Clock.Time[Clock.Real], reach = Float64 }

    /// 押しの記録。Up = 押していない（か、この画面で押し始めていない）、Down = 押している。
    pub enum Track {
        case Up
        case Down(Press)
    }

    /// 払いの向き（押した所から離した所へ、長い方の軸）。
    pub enum Direction with Eq, ToString {
        case Left
        case Right
        case Up
        case Down
    }

    /// 離した時に決まる押しの種類。Tap は押した所（離す時の指のずれで隣を押さない）。
    pub enum Kind {
        case Tap({ x = Float64, y = Float64 })
        case Swipe(Direction)
        case LongPress
        case Drag
    }

    pub def idle(): Track = Track.Up

    pub def isIdle(track: Track): Bool = match track {
        case Track.Up      => true
        case Track.Down(_) => false
    }

    pub def isTap(kind: Kind): Bool = match kind {
        case Kind.Tap(_) => true
        case _           => false
    }

    /// このフレームの入力で記録を進める。離したフレームだけ種類を返す（押し始めを見ていない離しは何も返さない）。
    pub def step(limits: Limits, frame: App.Frame, track: Track): (Option[Kind], Track) =
        if (frame#mouseClicked and frame#mouseDown) (None, Track.Down({ at = frame#cursor, since = frame#realNow, reach = 0.0 }))
        else match track {
            case Track.Up => (None, Track.Up)
            case Track.Down(press) =>
                let moved = { reach = Float64.max(press#reach, Vec2.distanceTo(press#at, frame#cursor)) | press };
                if (frame#mouseDown) (None, Track.Down(moved))
                else (Some(classify(limits, moved, frame#cursor, Clock.since(press#since, frame#realNow))), Track.Up)
        }

    /// 離した押しの種類（end = 離した所、held = 押していた秒）。
    def classify(limits: Limits, press: Press, end: { x = Float64, y = Float64 }, held: Float64): Kind =
        if (press#reach <= limits#slop and held >= limits#longPressSeconds) Kind.LongPress
        else if (press#reach <= limits#slop) Kind.Tap(press#at)
        else if (Vec2.distanceTo(press#at, end) >= limits#swipeMin and held <= limits#swipeSeconds) Kind.Swipe(directionOf(press#at, end))
        else Kind.Drag

    def directionOf(start: { x = Float64, y = Float64 }, finish: { x = Float64, y = Float64 }): Direction =
        let dx = finish#x - start#x;
        let dy = finish#y - start#y;
        if (Float64.abs(dx) >= Float64.abs(dy)) (if (dx < 0.0) Direction.Left else Direction.Right)
        else if (dy < 0.0) Direction.Up
        else Direction.Down
}
