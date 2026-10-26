// SdlPad — ゲームパッドを SDL3 の gamepad API で読む。ウィンドウと GL は GLFW のまま、パッドの読み取りだけを受け持つ。
// LwjglLayer はボタンと軸を GLFW の番号（GLFW_GAMEPAD_BUTTON_* / GLFW_GAMEPAD_AXIS_*）で引くので、
// ここで SDL の番号へ置き換え、値も GLFW の幅（軸は -1..1）にそろえて返す。
// WhyNot: GLFW だけで読まない — GLFW は SDL_GameControllerDB の対応表に載った機械しか gamepad にできず、
// Steam なしの Steam Controller（2026 年の 2 代目を含む）は本体がキーボード・マウスのふり（lizard mode）をして
// gamepad として見えない。SDL3 は HIDAPI で本体と直に話し、開いている間は lizard mode を止める。
pub mod SdlPad {
    import java.lang.Integer
    import java.lang.Throwable
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.sdl.SDLGamepad
    import org.lwjgl.sdl.SDLInit
    import org.lwjgl.sdl.SDLStdinc
    import org.lwjgl.sdl.SDLVersion

    /// SDL の gamepad を使えるようにする。native が読めないなどで失敗したら false を返し、呼び手は GLFW で読む。
    /// 呼べるのは GLFW と同じスレッド（macOS は main thread）だけ。
    pub def start(): Bool \ IO =
        try {
            if (SDLInit.SDL_Init(SDLInit.SDL_INIT_GAMEPAD))
                Log.warnThen("[gamepad] SDL3 ${versionOf()} で読む", true)
            else
                Log.warnThen("[gamepad] SDL3 の gamepad を始められない — GLFW で読む", false)
        } catch {
            case _: Throwable => Log.warnThen("[gamepad] SDL3 の native が読めない — GLFW で読む", false)
        }

    /// 1 フレームに 1 回。パッドの状態を読み直し、使うパッドを返す（0 はつないでいない）。
    /// held は前のフレームで使っていたパッド。抜けていれば閉じて、つながっている 1 台目を開く。
    pub def poll(held: Int64): Int64 \ IO = {
        SDLGamepad.SDL_UpdateGamepads();
        if (held != 0i64 and SDLGamepad.SDL_GamepadConnected(held)) held
        else {
            if (held != 0i64) SDLGamepad.SDL_CloseGamepad(held) else ();
            // WhyNot: 毎フレーム SDL_GetGamepads を呼ばない — 返す配列を SDL_free する必要があり、無い時は SDL_HasGamepad で足りる。
            if (not SDLGamepad.SDL_HasGamepad()) 0i64
            else {
                let ids = SDLGamepad.SDL_GetGamepads();
                if (Object.isNull(ids)) 0i64
                else {
                    let pad = if (ids.remaining() > 0) SDLGamepad.SDL_OpenGamepad(ids.get(0)) else 0i64;
                    SDLStdinc.SDL_free(ids);
                    pad
                }
            }
        }
    }

    /// GLFW の番号のボタンが押されているか。SDL は Xbox 配置の位置（下 = A）で名前が付いている。
    pub def button(pad: Int64, glfwButton: Int32): Bool \ IO =
        sdlButtonOf(glfwButton) |> Option.exists(b -> SDLGamepad.SDL_GetGamepadButton(pad, b))

    /// GLFW の番号の軸を GLFW の幅で。スティックは -1..1（上が負）、トリガーは離して -1・握って 1。
    /// 軸の番号は SDL と GLFW で同じ並び（左 X・左 Y・右 X・右 Y・左トリガー・右トリガー）。
    pub def axis(pad: Int64, glfwAxis: Int32): Float32 \ IO = {
        let raw = Int32.toFloat32(Int16.toInt32(SDLGamepad.SDL_GetGamepadAxis(pad, glfwAxis))) / 32767.0f32;
        if (glfwAxis == GLFW.GLFW_GAMEPAD_AXIS_LEFT_TRIGGER or glfwAxis == GLFW.GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER)
            raw * 2.0f32 - 1.0f32
        else raw
    }

    /// パッドの名前と USB のベンダーから機種を決める。
    pub def kindOf(pad: Int64): GamepadMap.PadKind \ IO =
        GamepadMap.kindOfVendor(vendorOf(pad), nameOf(pad))

    /// ログに出す 1 行。
    pub def describe(pad: Int64): String \ IO =
        "[gamepad] SDL3: name=\"${nameOf(pad)}\" vendor=${Integer.toHexString(vendorOf(pad))}"

    /// 使っていたパッドを閉じて SDL を終える。
    pub def stop(held: Int64): Unit \ IO = {
        if (held != 0i64) SDLGamepad.SDL_CloseGamepad(held) else ();
        SDLInit.SDL_Quit()
    }

    def versionOf(): String \ IO = {
        let v = SDLVersion.SDL_GetVersion();
        "${v / 1000000}.${Int32.remainder(v / 1000, 1000)}.${Int32.remainder(v, 1000)}"
    }

    def nameOf(pad: Int64): String \ IO = {
        let name = SDLGamepad.SDL_GetGamepadName(pad);
        if (Object.isNull(name)) "" else name
    }

    def vendorOf(pad: Int64): Int32 \ IO =
        Int32.bitwiseAnd(Int16.toInt32(SDLGamepad.SDL_GetGamepadVendor(pad)), 0xFFFF)

    def sdlButtonOf(glfwButton: Int32): Option[Int32] =
        if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_A) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_SOUTH)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_B) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_EAST)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_X) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_WEST)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_Y) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_NORTH)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_LEFT_BUMPER) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_BACK) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_BACK)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_START) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_START)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_GUIDE) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_GUIDE)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_LEFT_THUMB) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_LEFT_STICK)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_RIGHT_THUMB) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_RIGHT_STICK)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_DPAD_UP) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_DPAD_UP)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_DPAD_DOWN) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_DPAD_DOWN)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_DPAD_LEFT) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_DPAD_LEFT)
        else if (glfwButton == GLFW.GLFW_GAMEPAD_BUTTON_DPAD_RIGHT) Some(SDLGamepad.SDL_GAMEPAD_BUTTON_DPAD_RIGHT)
        else None
}
