// App.CursorLook — マウスの矢印・キャプチャとタイトルのバッジを、ウィンドウへ当てる前の値で決める（純粋）。
// 当てるのは App（applyHaltLook と、withCursor・withMouseCapture の宣言を当てる拍）。ここは何を当てるかだけを返す。

pub mod App.CursorLook {

    /// withCursor の宣言を最後にどう当てたか。Stale = まだ当てていない・止めた画面の見た目が上書きした
    /// （どちらも次に動く拍で当て直す）。
    pub enum State {
        case Applied(App.CursorSpec)
        case Stale
    }

    /// 矢印を見せるか。LeaveToApp = 触らない（今の見せ方のまま）。
    pub enum Visibility with Eq, ToString {
        case Show
        case Hide
        case LeaveToApp
    }

    /// ウィンドウへ当てる矢印の見た目（形・見せるか）。
    pub enum Look with Eq, ToString {
        case Look(GameEngine.Cursor, Visibility)
    }

    /// ウィンドウタイトルの「止めている」のバッジ。
    pub enum Badge with Eq, ToString {
        case Shown
        case Hidden
    }

    /// マウスのキャプチャをどうするか。Release = 放す・LeaveToApp = 触らない（動き出した拍に宣言を当て直す）。
    pub enum Capture with Eq, ToString {
        case Release
        case LeaveToApp
    }

    /// 止めた画面の出入りの見た目（タイトルのバッジ・矢印・キャプチャ）。
    pub enum HaltLook with Eq, ToString {
        case HaltLook(Badge, Look, Capture)
    }

    /// withCursor の宣言 want を当てるなら、その見た目（前に当てた物と同じなら None）。
    /// Stale（まだ当てていない・止めた画面の見た目が上書きした）なら必ず当てる — 止めた画面を抜けた拍に
    /// ゲームの「隠す」が戻るのはここ。
    pub def cursorChange(want: App.CursorSpec, state: State): Option[Look] =
        let look = Look.Look(want#icon, if (want#visible) Visibility.Show else Visibility.Hide);
        match state {
            case State.Applied(was) if was#icon == want#icon and was#visible == want#visible => None
            case _ => Some(look)
        }

    /// withMouseCapture の宣言 want を当てるなら、その値（前に当てた値 applied と同じなら None）。
    /// applied = None は、まだ当てていない・止めた画面が放した（どちらも次に動く拍で当て直す）。
    pub def captureChange(want: Bool, applied: Option[Bool]): Option[Bool] =
        if (applied == Some(want)) None else Some(want)

    /// 止めた画面に入る時の見た目: バッジを出し、十字を見せ、マウスのキャプチャを放す — withCursor で矢印を隠している・
    /// withMouseCapture でキャプチャしているゲームでも、矩形を囲うのに要る（F8 と /halt・/step）。
    pub def haltEnterLook(): HaltLook =
        HaltLook.HaltLook(Badge.Shown, Look.Look(GameEngine.Cursor.Crosshair, Visibility.Show), Capture.Release)

    /// 止めた画面を抜ける時の見た目: バッジを外し、形だけ戻す。見せるか隠すかは触らない（動き出した拍に
    /// cursorChange が withCursor の宣言を、captureChange が withMouseCapture の宣言を当て直す。宣言の無いゲームは
    /// 見せたまま・放したままが元の姿）（F8 と /resume）。
    pub def haltLeaveLook(): HaltLook =
        HaltLook.HaltLook(Badge.Hidden, Look.Look(GameEngine.Cursor.Default, Visibility.LeaveToApp), Capture.LeaveToApp)
}
