// LwjglInput — GLFW のウィンドウのキー・マウス・ホイール・フォーカスと、ゲームパッド（SDL3 か GLFW）を読み、Platform.Input の handler にする。
// 1 コマに 1 回の取り込み（poll）もここが持つ。マウスの「このコマで押された」フラグとパッドの状態は、
// 取り込む側と読む側で同じ物なので、1 つの状態（Devices）の上に置く。

mod LwjglInput {
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.glfw.GLFWGamepadState
    import org.lwjgl.glfw.GLFWMouseButtonCallbackI
    import org.lwjgl.glfw.GLFWScrollCallbackI
    import org.lwjgl.glfw.GLFWWindowFocusCallbackI
    import org.lwjgl.system.MemoryStack

    // ========================================================================
    // GLFW の数のコード（engine の論理キー → GLFW）
    // ========================================================================

    def keyToGlfw(key: GameEngine.Key): Int32 = match key {
        // 英字
        case GameEngine.Key.A              => 65
        case GameEngine.Key.B              => 66
        case GameEngine.Key.C              => 67
        case GameEngine.Key.D              => 68
        case GameEngine.Key.E              => 69
        case GameEngine.Key.F              => 70
        case GameEngine.Key.G              => 71
        case GameEngine.Key.H              => 72
        case GameEngine.Key.I              => 73
        case GameEngine.Key.J              => 74
        case GameEngine.Key.K              => 75
        case GameEngine.Key.L              => 76
        case GameEngine.Key.M              => 77
        case GameEngine.Key.N              => 78
        case GameEngine.Key.O              => 79
        case GameEngine.Key.P              => 80
        case GameEngine.Key.Q              => 81
        case GameEngine.Key.R              => 82
        case GameEngine.Key.S              => 83
        case GameEngine.Key.T              => 84
        case GameEngine.Key.U              => 85
        case GameEngine.Key.V              => 86
        case GameEngine.Key.W              => 87
        case GameEngine.Key.X              => 88
        case GameEngine.Key.Y              => 89
        case GameEngine.Key.Z              => 90
        // 数字(キーボード上段)
        case GameEngine.Key.Digit0         => 48
        case GameEngine.Key.Digit1         => 49
        case GameEngine.Key.Digit2         => 50
        case GameEngine.Key.Digit3         => 51
        case GameEngine.Key.Digit4         => 52
        case GameEngine.Key.Digit5         => 53
        case GameEngine.Key.Digit6         => 54
        case GameEngine.Key.Digit7         => 55
        case GameEngine.Key.Digit8         => 56
        case GameEngine.Key.Digit9         => 57
        // 矢印
        case GameEngine.Key.Up             => 265
        case GameEngine.Key.Down           => 264
        case GameEngine.Key.Left           => 263
        case GameEngine.Key.Right          => 262
        // 制御・編集
        case GameEngine.Key.Enter          => 257
        case GameEngine.Key.Space          => 32
        case GameEngine.Key.Escape         => 256
        case GameEngine.Key.Tab            => 258
        case GameEngine.Key.Backspace      => 259
        case GameEngine.Key.Insert         => 260
        case GameEngine.Key.Delete         => 261
        case GameEngine.Key.PageUp         => 266
        case GameEngine.Key.PageDown       => 267
        case GameEngine.Key.Home           => 268
        case GameEngine.Key.End            => 269
        case GameEngine.Key.CapsLock       => 280
        // ファンクション
        case GameEngine.Key.F1             => 290
        case GameEngine.Key.F2             => 291
        case GameEngine.Key.F3             => 292
        case GameEngine.Key.F4             => 293
        case GameEngine.Key.F5             => 294
        case GameEngine.Key.F6             => 295
        case GameEngine.Key.F7             => 296
        case GameEngine.Key.F8             => 297
        case GameEngine.Key.F9             => 298
        case GameEngine.Key.F10            => 299
        case GameEngine.Key.F11            => 300
        case GameEngine.Key.F12            => 301
        // 記号(US 配列の刻印)
        case GameEngine.Key.Apostrophe     => 39
        case GameEngine.Key.Comma          => 44
        case GameEngine.Key.Minus          => 45
        case GameEngine.Key.Period         => 46
        case GameEngine.Key.Slash          => 47
        case GameEngine.Key.Semicolon      => 59
        case GameEngine.Key.Equal          => 61
        case GameEngine.Key.LeftBracket    => 91
        case GameEngine.Key.Backslash      => 92
        case GameEngine.Key.RightBracket   => 93
        case GameEngine.Key.GraveAccent    => 96
        // 修飾
        case GameEngine.Key.LeftShift      => 340
        case GameEngine.Key.LeftCtrl       => 341
        case GameEngine.Key.LeftAlt        => 342
        case GameEngine.Key.LeftSuper      => 343
        case GameEngine.Key.RightShift     => 344
        case GameEngine.Key.RightCtrl      => 345
        case GameEngine.Key.RightAlt       => 346
        case GameEngine.Key.RightSuper     => 347
        case GameEngine.Key.Menu           => 348
        // テンキー
        case GameEngine.Key.Numpad0        => 320
        case GameEngine.Key.Numpad1        => 321
        case GameEngine.Key.Numpad2        => 322
        case GameEngine.Key.Numpad3        => 323
        case GameEngine.Key.Numpad4        => 324
        case GameEngine.Key.Numpad5        => 325
        case GameEngine.Key.Numpad6        => 326
        case GameEngine.Key.Numpad7        => 327
        case GameEngine.Key.Numpad8        => 328
        case GameEngine.Key.Numpad9        => 329
        case GameEngine.Key.NumpadDecimal  => 330
        case GameEngine.Key.NumpadDivide   => 331
        case GameEngine.Key.NumpadMultiply => 332
        case GameEngine.Key.NumpadSubtract => 333
        case GameEngine.Key.NumpadAdd      => 334
        case GameEngine.Key.NumpadEnter    => 335
        case GameEngine.Key.NumpadEqual    => 336
    }

    def mouseButtonToGlfw(button: GameEngine.MouseButton): Int32 = match button {
        case GameEngine.MouseButton.Left   => 0
        case GameEngine.MouseButton.Right  => 1
        case GameEngine.MouseButton.Middle => 2
    }

    /// consumeMouseDelta が返す動いた量（ウィンドウの座標）。base = 前に読んだ位置・now = 今の位置。
    /// rebase（キャプチャを切り替えた直後・フォーカスが戻った直後）と、フォーカスが無い間は 0。
    // WhyNot: フォーカスが無い間に差を出さない — OS がキャプチャを放した後も位置は読めるので、ほかのアプリの上でマウスを動かすと視点が回る。
    pub def mouseDeltaInWindow(state: { rebase = Bool, focused = Bool }, base: (Float64, Float64), now: (Float64, Float64)): (Float64, Float64) =
        if (state#rebase or not state#focused) (0.0, 0.0)
        else (fst(now) - fst(base), snd(now) - snd(base))

    /// マウスの位置（ウィンドウの座標・小数）。キャプチャしている間はウィンドウの外まで続く仮の位置。
    def cursorInWindow(window: Int64): (Float64, Float64) \ IO =
        let stack = MemoryStack.stackPush();
        let xBuf = stack.mallocDouble(1);
        let yBuf = stack.mallocDouble(1);
        GLFW.glfwGetCursorPos(window, xBuf, yBuf);
        let pos = (xBuf.get(0), yBuf.get(0));
        discard MemoryStack.stackPop();
        pos

    /// ウィンドウの座標の (x, y) を design px へ（ウィンドウの大きさに対する割合 × design の寸）。getMousePosition と consumeMouseDelta が同じ式を使う。
    def windowToDesign(window: Int64, screenW: Float64, screenH: Float64, x: Float64, y: Float64): Vec2.Vec2 \ IO =
        let stack = MemoryStack.stackPush();
        let winW = stack.mallocInt(1);
        let winH = stack.mallocInt(1);
        GLFW.glfwGetWindowSize(window, winW, winH);
        let design = { x = x / Int32.toFloat64(winW.get(0)) * screenW, y = y / Int32.toFloat64(winH.get(0)) * screenH };
        discard MemoryStack.stackPop();
        design

    // ========================================================================
    // 読む物の状態
    // ========================================================================

    /// 1 台目のゲームパッド。sdlReady = SDL3 で読むか（起動の時に 1 回だけ決める。だめなら GLFW）。
    /// sdlPad = SDL3 で開いているパッド（0 は開いていない）・jid = GLFW で読んでいる joystick の番号（-1 はつないでいない）。
    /// kind = 機種（つないだ時に 1 回だけ読む。GUID と名前は毎フレーム字を作るので）。
    type alias Pad = {
        state = GLFWGamepadState,
        connected = Array[Bool, Static],
        sdlReady = Bool,
        sdlPad = Array[Int64, Static],
        jid = Array[Int32, Static],
        kind = Array[GamepadMap.PadKind, Static],
        table = Map[GameEngine.Key, GamepadMap.PadInput]
    }

    /// ウィンドウ 1 つぶんの読む物。外から作らせない（open だけが作る）。
    /// scrollDelta = ホイールの y を 1 コマぶん溜める・mouseBase = consumeMouseDelta が前に読んだウィンドウの座標・
    /// mouseRebase = 次の 1 回は基準を取り直して 0 を返すフラグ・pressed = マウスのボタンの「このコマで PRESS が来た」フラグ（[0]=左・[1]=右・[2]=中）。
    enum DevicesData {
        case DevicesData({
            window = Int64,
            design = Vec2.Vec2,
            scrollDelta = Array[Float64, Static],
            mouseBase = Array[(Float64, Float64), Static],
            mouseRebase = Array[Bool, Static],
            focused = Array[Bool, Static],
            pressed = Array[Bool, Static],
            pad = Pad
        })
    }

    pub type alias Devices = DevicesData

    /// ウィンドウに読む物の callback（ホイール・フォーカス・マウスのボタン）を付け、パッドを読む元（SDL3 か GLFW）を決める。
    /// design = design px の寸（ウィンドウの座標をここへ写す）。
    pub def open(window: Int64, design: Vec2.Vec2): Devices \ IO =
        let scrollDelta = Array#{0.0} @ Static;
        discard GLFW.glfwSetScrollCallback(window, new GLFWScrollCallbackI {
            def invoke(_this: GLFWScrollCallbackI, _w: Int64, _xoffset: Float64, yoffset: Float64): Unit \ IO = {
                let prev = Array.get(0, scrollDelta);
                Array.put(prev + yoffset, 0, scrollDelta)
            }
        });
        let mouseRebase = Array#{true} @ Static;
        let focused = Array#{true} @ Static;
        // WhyNot: フォーカスを取り戻した時に基準を取り直さずに差を出さない — 外にいた間の動きが一度に入り、視点が跳ねる。
        discard GLFW.glfwSetWindowFocusCallback(window, new GLFWWindowFocusCallbackI {
            def invoke(_this: GLFWWindowFocusCallbackI, _w: Int64, now: Bool): Unit \ IO = {
                Array.put(now, 0, focused);
                if (now) Array.put(true, 0, mouseRebase) else ()
            }
        });
        let pressed = Array#{false, false, false} @ Static;
        discard GLFW.glfwSetMouseButtonCallback(window, new GLFWMouseButtonCallbackI {
            def invoke(_this: GLFWMouseButtonCallbackI, _w: Int64,
                        button: Int32, action: Int32, _mods: Int32): Unit \ IO = {
                // GLFW_PRESS = 1。0..2 範囲外は無視。
                if (action == 1 and button >= 0 and button <= 2)
                    Array.put(true, button, pressed)
                else ()
            }
        });
        // GLFWGamepadState.create() は GC 管理のダイレクトバッファ上に確保されるため明示解放は不要。
        let pad = { state = GLFWGamepadState.create(), connected = Array#{false} @ Static, sdlReady = SdlPad.start(),
                    sdlPad = Array#{0i64} @ Static, jid = Array#{-1} @ Static,
                    kind = Array#{GamepadMap.PadKind.Unknown} @ Static, table = GamepadMap.byKey() };
        DevicesData.DevicesData({ window = window, design = design, scrollDelta = scrollDelta,
                                  mouseBase = Array#{(0.0, 0.0)} @ Static, mouseRebase = mouseRebase,
                                  focused = focused, pressed = pressed, pad = pad })

    /// ウィンドウを閉じる前の片付け（SDL3 で開いたパッドを閉じる）。
    pub def close(devices: Devices): Unit \ IO =
        let DevicesData.DevicesData(d) = devices;
        if (d#pad#sdlReady) SdlPad.stop(Array.get(0, d#pad#sdlPad)) else ()

    /// 次の consumeMouseDelta は基準を取り直して 0 を返す（キャプチャを切り替えた時）。
    pub def rebaseMouse(devices: Devices): Unit \ IO =
        let DevicesData.DevicesData(d) = devices;
        Array.put(true, 0, d#mouseRebase)

    /// 溜めたホイールを捨てる（読み込み中のホイールを最初のコマで一度に出さない）。
    pub def dropScroll(devices: Devices): Unit \ IO =
        let DevicesData.DevicesData(d) = devices;
        Array.put(0.0, 0, d#scrollDelta)

    /// 1 コマの頭の取り込み: マウスの PRESS のフラグを下ろしてから OS のイベントを汲み、パッドの状態を 1 回読む。
    // WhyNot: フラグを poll の後で下ろさない — poll の間に来た短い押し（トラックパッドのタップ）が、このコマの isMouseButtonPressed に出ずに消える。
    pub def poll(devices: Devices): Unit \ IO =
        let DevicesData.DevicesData(d) = devices;
        Array.put(false, 0, d#pressed);
        Array.put(false, 1, d#pressed);
        Array.put(false, 2, d#pressed);
        GLFW.glfwPollEvents();
        Array.put(pollPad(d#pad), 0, d#pad#connected)

    /// パッドの状態を読み、つないでいるかを返す（読むパッドが変わったら機種を読み直して知らせる）。
    def pollPad(pad: Pad): Bool \ IO =
        if (pad#sdlReady) {
            let held = Array.get(0, pad#sdlPad);
            let now = SdlPad.poll(held);
            if (now != held) {
                let kind = if (now != 0i64) Log.warnThen(SdlPad.describe(now), SdlPad.kindOf(now))
                    else Log.warnThen("[gamepad] SDL3: つながっているパッドは無い", GamepadMap.PadKind.Unknown);
                Array.put(kind, 0, pad#kind)
            } else ();
            Array.put(now, 0, pad#sdlPad);
            now != 0i64
        } else {
            let held = Array.get(0, pad#jid);
            let jid = if (held >= 0 and GLFW.glfwJoystickIsGamepad(held)) held else findPad();
            if (jid >= 0) discard GLFW.glfwGetGamepadState(jid, pad#state) else ();
            if (jid != held) Array.put(kindLogged(jid), 0, pad#kind) else ();
            Array.put(jid, 0, pad#jid);
            jid >= 0
        }

    // ========================================================================
    // ゲームパッド（Xbox の配置）
    // ========================================================================

    def padButton(pad: Pad, idx: Int32): Bool \ IO =
        if (pad#sdlReady) SdlPad.button(Array.get(0, pad#sdlPad), idx)
        else pad#state.buttons(idx) != 0i8

    def padAxis(pad: Pad, idx: Int32): Float32 \ IO =
        if (pad#sdlReady) SdlPad.axis(Array.get(0, pad#sdlPad), idx)
        else pad#state.axes(idx)

    /// 方向は D-pad と左スティック（デッドゾーン 0.5）の両方で受ける。GLFW のスティック Y 軸は上が負。
    def padInputDown(pad: Pad, input: GamepadMap.PadInput): Bool \ IO = match input {
        case GamepadMap.PadInput.DirUp      => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_DPAD_UP) or (padAxis(pad, GLFW.GLFW_GAMEPAD_AXIS_LEFT_Y) < -0.5f32)
        case GamepadMap.PadInput.DirDown    => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_DPAD_DOWN) or (padAxis(pad, GLFW.GLFW_GAMEPAD_AXIS_LEFT_Y) > 0.5f32)
        case GamepadMap.PadInput.DirLeft    => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_DPAD_LEFT) or (padAxis(pad, GLFW.GLFW_GAMEPAD_AXIS_LEFT_X) < -0.5f32)
        case GamepadMap.PadInput.DirRight   => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_DPAD_RIGHT) or (padAxis(pad, GLFW.GLFW_GAMEPAD_AXIS_LEFT_X) > 0.5f32)
        case GamepadMap.PadInput.A          => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_A)
        case GamepadMap.PadInput.B          => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_B)
        case GamepadMap.PadInput.X          => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_X)
        case GamepadMap.PadInput.Y          => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_Y)
        case GamepadMap.PadInput.LeftBumper => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_LEFT_BUMPER)
        case GamepadMap.PadInput.Back       => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_BACK)
        case GamepadMap.PadInput.Start      => padButton(pad, GLFW.GLFW_GAMEPAD_BUTTON_START)
    }

    /// 左（軸 0・1）と右（軸 2・3）のスティック。遊びを外し、上が +y に直した値。つないでいなければ (0, 0)。
    def padSticks(pad: Pad): { left = Vec2.Vec2, right = Vec2.Vec2 } \ IO =
        if (not Array.get(0, pad#connected)) { left = Vec2.zero(), right = Vec2.zero() }
        else {
            let stick = (xAxis: Int32) ->
                GamepadMap.stickOf(GamepadMap.defaultDeadzone(), Float32.toFloat64(padAxis(pad, xAxis)), Float32.toFloat64(padAxis(pad, xAxis + 1)));
            { left = stick(GLFW.GLFW_GAMEPAD_AXIS_LEFT_X), right = stick(GLFW.GLFW_GAMEPAD_AXIS_RIGHT_X) }
        }

    /// 物理キーに当てたパッドの入力が押されているか（対応は GamepadMap.table・1 ボタン = 1 キー）。
    def padPressed(pad: Pad, key: GameEngine.Key): Bool \ IO =
        Array.get(0, pad#connected) and
            (Map.get(key, pad#table) |> Option.exists(input -> padInputDown(pad, input)))

    def orEmpty(s: String): String = if (Object.isNull(s)) "" else s

    def readPadKind(jid: Int32): GamepadMap.PadKind \ IO =
        GamepadMap.kindOf(orEmpty(GLFW.glfwGetJoystickGUID(jid)), orEmpty(GLFW.glfwGetGamepadName(jid)))

    // WhyNot: 1 番だけを見ない — Mac の Steam Controller のように、対応表の無い本体が 1 番に、
    // Steam が作った仮想パッドが 2 番以降に並ぶことがある。
    def findPad(): Int32 \ IO =
        List.range(GLFW.GLFW_JOYSTICK_1, GLFW.GLFW_JOYSTICK_LAST + 1)
            |> List.find(jid -> GLFW.glfwJoystickIsGamepad(jid))
            |> Option.getWithDefault(-1)

    /// 読めるパッドが変わった時に、つながっている joystick を全部 stderr へ出してから機種を返す。
    /// gamepad=false の行は GLFW の対応表に無い機械で、ボタンはキーにならない（docs/gamepad.md）。
    def kindLogged(jid: Int32): GamepadMap.PadKind \ IO =
        let present = List.range(GLFW.GLFW_JOYSTICK_1, GLFW.GLFW_JOYSTICK_LAST + 1)
            |> List.filter(j -> GLFW.glfwJoystickPresent(j));
        let line = (j: Int32) ->
            "[gamepad] joystick ${j}: name=\"${orEmpty(GLFW.glfwGetJoystickName(j))}\" guid=${orEmpty(GLFW.glfwGetJoystickGUID(j))} gamepad=${GLFW.glfwJoystickIsGamepad(j)}" +
                (if (j == jid) " <- 使う" else "");
        let lines = if (List.isEmpty(present)) "[gamepad] つながっている joystick は無い" :: Nil else List.map(line, present);
        Log.warnAllThen(lines, if (jid >= 0) readPadKind(jid) else GamepadMap.PadKind.Unknown)

    // ========================================================================
    // handler
    // ========================================================================

    /// Platform.Input を、このウィンドウの読む物で受ける。
    pub def handleInput(devices: Devices, f: Unit -> a \ ef): a \ (ef - Platform.Input) + IO =
        let DevicesData.DevicesData(d) = devices;
        let window = d#window;
        let (screenW, screenH) = (d#design#x, d#design#y);
        run f() with handler Platform.Input {
            def isKeyPressed(key, k) = {
                let kb = GLFW.glfwGetKey(window, keyToGlfw(key)) == 1;
                // キーボード OR ゲームパッド。エッジ検出は App が前のコマのキーと比べてする。
                k(kb or padPressed(d#pad, key))
            }
            def getMousePosition(k) = {
                let (cursorX, cursorY) = cursorInWindow(window);
                k(windowToDesign(window, screenW, screenH, cursorX, cursorY))
            }
            def isMouseButtonPressed(button, k) = {
                let code = mouseButtonToGlfw(button);
                // 物理状態 OR 当フレーム内に callback が観測した PRESS。
                let polled = GLFW.glfwGetMouseButton(window, code) == 1;
                k(polled or Array.get(code, d#pressed))
            }
            def isGamepadTouched(k) =
                if (not Array.get(0, d#pad#connected)) k(false)
                else {
                    let pushed = List.range(0, GLFW.GLFW_GAMEPAD_BUTTON_LAST + 1) |> List.exists(idx -> padButton(d#pad, idx));
                    // 左右のスティック（軸 0..3）だけ。トリガー（軸 4・5）は離した位置が -1 なので入れない。
                    let tilted = List.range(0, 4) |> List.exists(axis -> Float32.abs(padAxis(d#pad, axis)) > 0.5f32);
                    k(pushed or tilted)
                }
            def gamepadKind(k) = k(Array.get(0, d#pad#kind))
            def gamepadSticks(k) = k(padSticks(d#pad))
            def consumeScrollDelta(k) = {
                let v = Array.get(0, d#scrollDelta);
                Array.put(0.0, 0, d#scrollDelta);
                k(v)
            }
            def consumeMouseDelta(k) = {
                let now = cursorInWindow(window);
                let (dx, dy) = mouseDeltaInWindow({ rebase = Array.get(0, d#mouseRebase), focused = Array.get(0, d#focused) },
                                                  Array.get(0, d#mouseBase), now);
                Array.put(now, 0, d#mouseBase);
                Array.put(false, 0, d#mouseRebase);
                // WhyNot: 0 の時にウィンドウの大きさで割らない — 最小化したウィンドウは大きさが 0 で、0 / 0 が NaN になる。
                k(if (dx == 0.0 and dy == 0.0) Vec2.zero() else windowToDesign(window, screenW, screenH, dx, dy))
            }
            def isWindowFocused(k) = k(Array.get(0, d#focused))
        }

    /// デスクトップ版の画面の情報: 大きさはウィンドウの座標（GLFW の画面の座標・mac は point）・倍率は描き先の画素 ÷ ウィンドウの座標。
    /// 区分は Large・pointer は Mouse に決めてある（デスクトップの絵と遊びを区分で変えない）。
    pub def displayOf(window: Int64, design: Vec2.Vec2): Display.Display \ IO =
        let stack = MemoryStack.stackPush();
        let winW = stack.mallocInt(1);
        let winH = stack.mallocInt(1);
        let fbW = stack.mallocInt(1);
        let fbH = stack.mallocInt(1);
        GLFW.glfwGetWindowSize(window, winW, winH);
        GLFW.glfwGetFramebufferSize(window, fbW, fbH);
        let (w, h) = (Int32.toFloat64(winW.get(0)), Int32.toFloat64(winH.get(0)));
        let fw = Int32.toFloat64(fbW.get(0));
        discard MemoryStack.stackPop();
        // WhyNot: 最小化した 0 をそのまま入れない — 0 で割って字の大きさを決める所が無限大になる。
        if (w <= 0.0 or h <= 0.0) Display.desktop(design)
        else { size = { x = w, y = h }, scaleFactor = if (fw > 0.0) fw / w else 1.0,
               designScale = Float64.min(w / design#x, h / design#y) | Display.desktop(design) }
}
