/// ゲームパッド（Xbox 配置）の入力とキーの対応表と、つないだパッドの機種の見分け。
/// GLFW を触らない部分だけをここに置き、読み取りは render_gl の LwjglLayer がする。
pub mod GamepadMap {
    use GameEngine.Key

    /// パッドの入力 1 つ。ボタンは Xbox 配置の名前（Back は Select / View、Start は Menu の物）。
    /// 上下左右は十字キーと左スティックのどちらでも入る。
    pub enum PadInput with Eq, Order, ToString {
        case DirUp
        case DirDown
        case DirLeft
        case DirRight
        case A
        case B
        case X
        case Y
        case LeftBumper
        case Back
        case Start
    }

    /// つないだパッドの機種。案内に出すボタンの絵や、Steam Input を通っているかの判断に使う。
    pub enum PadKind with Eq, ToString {
        /// Xbox 配置の一般のパッド（GLFW が gamepad として読めた物）。
        case Generic
        /// Steam Input を通したパッド（Steam Deck・Steam Controller・Steam が仮想にしたパッド）。USB のベンダーが Valve（28de）。
        case Steam
        /// つないでいない・gamepad として読めない。
        case Unknown
    }

    /// キーとパッドの入力の対応表。**1 ボタン = 1 キー**。
    ///
    /// WhyNot: 1 ボタンを複数キーへ渡さない — 1 押しで複数キーが同じフレームに新しく押された扱いになり、
    /// 決定が 2 連発する（A を Z と Enter に渡すと、メニューを開いた直後に確定する）。
    /// WhyNot: Start を Enter へ渡さない — 決定（Enter）と見分けられず、Start でメニューを開けない。
    /// WhyNot: Escape は渡さない — マップの上でゲームの終了を呼ぶ。戻るは B（X キー）で足りる。
    pub def table(): List[(Key, PadInput)] =
        (Key.Up, PadInput.DirUp) :: (Key.Down, PadInput.DirDown) ::
        (Key.Left, PadInput.DirLeft) :: (Key.Right, PadInput.DirRight) ::
        (Key.Z, PadInput.A) :: (Key.X, PadInput.B) :: (Key.M, PadInput.X) :: (Key.C, PadInput.Y) ::
        (Key.LeftShift, PadInput.LeftBumper) ::
        (Key.Backspace, PadInput.Back) :: (Key.Menu, PadInput.Start) :: Nil

    /// table をキーで引く形。1 フレームに全キーを引くので Map にしておく。
    pub def byKey(): Map[Key, PadInput] = List.toMap(table())

    /// GLFW の joystick の GUID（SDL の形の 32 字の 16 進）とパッドの名前から機種を決める。
    /// 名前で見るのは、GUID にベンダーの入らない機械（古い Linux の仮想パッドなど）のため。
    pub def kindOf(guid: String, name: String): PadKind =
        if (String.isEmpty(guid) and String.isEmpty(name)) PadKind.Unknown
        else if (vendorOf(guid) == Some("28de") or String.contains(substr = "Steam", name)) PadKind.Steam
        else PadKind.Generic

    /// USB のベンダー（数・0 は分からない）とパッドの名前から機種を決める。SDL3 で読む時の形。
    pub def kindOfVendor(vendor: Int32, name: String): PadKind =
        if (vendor == 0x28de or String.contains(substr = "Steam", name)) PadKind.Steam
        else PadKind.Generic

    /// スティックの生の軸（GLFW・SDL とも右が +・下が +）から、遊び（デッドゾーン）を外した向きと強さを返す。右が +x・上が +y。
    /// 丸い遊び: 長さが deadzone 以下なら (0, 0)・超えたら (長さ - deadzone) / (1 - deadzone) へ伸ばし直して向きは保つ。長さは 1 で頭打ち。
    /// 小数 4 桁に丸めて返す（遊んだ記録の字と同じ精度にして、実機と再生で同じ値にする。-0 は 0 にそろえる）。
    /// WhyNot: 軸ごとに切らない — 斜めが強く出て、十字に吸い付く。
    pub def stickOf(deadzone: Float64, rawX: Float64, rawY: Float64): Vec2.Vec2 =
        let len = Num.sqrt(rawX * rawX + rawY * rawY);
        if (len <= deadzone or len <= 0.0) Vec2.zero()
        else {
            let stretched = Float64.min(1.0, (len - deadzone) / (1.0 - deadzone));
            { x = round4(rawX / len * stretched), y = round4(-rawY / len * stretched) }
        }

    /// 小数 4 桁に丸める（-0 は 0 にそろえる）。
    pub def round4(v: Float64): Float64 = Float64.round(v * 10000.0) / 10000.0 + 0.0

    /// スティックの遊びの既定（0.18）。
    pub def defaultDeadzone(): Float64 = 0.18

    /// GUID の USB のベンダー（4 字の 16 進・小文字）。9〜12 字目に 2 バイトが小さい方から並ぶ。形が違えば None。
    def vendorOf(guid: String): Option[String] =
        if (String.length(guid) != 32) None
        else {
            let lower = String.toLowerCase(guid);
            let byteAt = (start: Int32) -> String.takeLeft(2, String.dropLeft(start, lower));
            Some(byteAt(10) + byteAt(8))
        }
}
