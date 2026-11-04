// WebLayer — ブラウザ版の handler 一式（LwjglLayer と同じ役）。canvas の WebGL2 へ同じ塗りのコア（RenderPaint）で描き、
// キー・マウス・音・時計を fge.web（JS を閉じ込めた Java）から受ける。ゲームのループは止まる形のまま回り、
// presentFrame でブラウザの描き替え（requestAnimationFrame）まで待つ間だけブラウザへ手を返す。
// 利用例（web/WebMain.flix）: `run { ... App.launchWithDevTools(App.DevTools.none(), app) } with WebLayer.withProject(".") with WebFs.runFileRead with WebFs.runFileWrite`
// WhyNot: 開発の道具（注釈・RemoteDebug・Doc の監視）の handler を持たない — ブラウザ版は配る出力先の 1 つで、開発はデスクトップでする。
pub mod WebLayer {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import fge.web.AnimationFrame
    import fge.web.Browser
    import fge.web.Keys
    import fge.web.Pointer
    import fge.web.WebAudio
    import fge.web.WebGl2

    /// 1 秒に進めるコマの上限。速い画面（120Hz・165Hz）では描き替えを間引いてこの数に近づける（遊びの速さは dt で同じ・電池のため）。
    pub def tickRate(): Float64 = 60.0

    /// `rootDir` 直下の project.json を読んで withWeb を起動する。読めなければ止める（LwjglLayer.withProject と同じ）。
    pub def withProject(rootDir: String, f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO + Fs.FileRead =
        match ProjectLoader.loadProject(rootDir) {
            case Ok(proj) => withWeb(proj#config, f)
            case Err(msg) => bug!("Failed to load project.json: ${msg}")
        }

    /// canvas の WebGL2 で塗りのコアを作り、素材を上げ、handler を重ねて f を流す。f を抜けたら頁に「おわり」を出す。
    pub def withWeb(config: GameEngine.EngineConfig, f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO =
        Browser.setTitle(config#title);
        let gl: GlContext = checked_cast(new WebGl2());
        // 塗りのコアは混ぜ方が普通（SRC_ALPHA, ONE_MINUS_SRC_ALPHA）で始まっている前提で描く（LwjglLayer と同じ始め方）。
        gl.enable(GlConst.BLEND);
        gl.blendFunc(GlConst.SRC_ALPHA, GlConst.ONE_MINUS_SRC_ALPHA);
        let paint = RenderPaint.create(gl, { designWidth = config#designWidth, designHeight = config#designHeight,
                                             clearColor = config#clearColor, screenFramebuffer = 0,
                                             scene3d = Scene3dRenderer.none(), gpuTimer = RenderPaint.noFrameTimer() });
        // 組み込みフォント（fps の表示・名前が合わないフォントの受け皿）とロゴも登録簿へ。
        RenderPaint.addTextures(RenderSplash.install(gl), paint);
        let design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) };
        let framebufferSize = () -> (Browser.canvasWidth(), Browser.canvasHeight());
        let state = {
            design = design, maxDeltaTime = config#maxDeltaTime,
            looping = Ref.fresh(Static, false), closeRequested = Ref.fresh(Static, false),
            lastDt = Ref.fresh(Static, 1.0 / tickRate()), fullscreenAsked = Ref.fresh(Static, None),
            cursor = Ref.fresh(Static, GameEngine.Cursor.Default), cursorVisible = Ref.fresh(Static, true),
            yieldedAt = Ref.fresh(Static, Browser.now()), warnedSounds = Ref.fresh(Static, Set.empty())
        };
        let fonts = RenderPaint.loadAssets(gl, paint, WebAssets.loader(), config, showProgress(state));
        let result =
            handleLoadProgress(state, () ->
            handleAudio(state, () ->
            RenderPaintHandlers.handleTarget(gl, paint, framebufferSize, () ->
            RenderPaintHandlers.handleDiagnostics(paint, () ->
            Platform.runNoopDraw3d(() ->
            handleFrameClock(state, () ->
            handleWindow(state, () ->
            RenderPaintHandlers.handleDraw2d(gl, paint, framebufferSize, (_, _) -> checked_ecast(()), () ->
            handleInput(state, () ->
            RenderPaintHandlers.handleGpuResources(gl, paint, fonts, f))))))))));
        Browser.ended();
        result

    // WhyNot: 例外を Flix の try で受けて頁に出さない — effect の続きで再開した後の例外はその try の外で投げられる（bug! で確かめた）。
    //   頁に出すのは fge-web.js の window の error（wasm の外へ抜けた例外を全部受ける）。

    /// handler が分け合う状態。looping = ループが回り始めたか（最初の pollEvents の後）・lastDt = 前のコマからの経過（秒）・
    /// fullscreenAsked = 前に頼んだ全画面（同じ値を毎コマ頼み直さない）・yieldedAt = 起動中に最後にブラウザへ手を返した時刻（ms）。
    type alias State = {
        design = Vec2.Vec2, maxDeltaTime = Float64,
        looping = Ref[Bool, Static], closeRequested = Ref[Bool, Static],
        lastDt = Ref[Float64, Static], fullscreenAsked = Ref[Option[Bool], Static],
        cursor = Ref[GameEngine.Cursor, Static], cursorVisible = Ref[Bool, Static],
        yieldedAt = Ref[Float64, Static], warnedSounds = Ref[Set[String], Static]
    }

    /// Platform.Window を頁と canvas で受ける。presentFrame で次の描き替えまで待つ（ブラウザが絵を出すのは手を返した後）。
    def handleWindow(st: State, f: Unit -> a \ ef): a \ (ef - Platform.Window) + IO =
        run f() with handler Platform.Window {
            def pollEvents(k) = {
                if (not Ref.get(st#looping)) { Ref.put(true, st#looping); Browser.started() } else ();
                Browser.beginFrame();
                k(())
            }
            def shouldClose(k) = k(Ref.get(st#closeRequested))
            def setShouldClose(close, k) = { Ref.put(close, st#closeRequested); k(()) }
            def getViewportRect(k) = k({ position = Vec2.zero(), size = st#design })
            def presentFrame(k) = {
                Ref.put(AnimationFrame.waitTick(tickRate()), st#lastDt);
                k(())
            }
            def setCursor(cursor, k) = { Ref.put(cursor, st#cursor); applyCursor(st); k(()) }
            def setCursorVisible(visible, k) = { Ref.put(visible, st#cursorVisible); applyCursor(st); k(()) }
            def setMouseCaptured(_captured, k) = k(())
            def setFullscreen(on, k) = {
                // WhyNot: 同じ値を毎コマ頼み直さない — Esc でブラウザが全画面を抜けた後、次のキーでまた入ってしまう。
                if (Ref.get(st#fullscreenAsked) != Some(on)) { Ref.put(Some(on), st#fullscreenAsked); Browser.requestFullscreen(on) } else ();
                k(())
            }
            def isFullscreen(k) = k(Browser.isFullscreen())
            def setDebugBadge(_enabled, k) = k(())
        }

    def applyCursor(st: State): Unit \ IO =
        Browser.setCursor(if (Ref.get(st#cursorVisible)) cursorCss(Ref.get(st#cursor)) else "none")

    /// GameEngine.Cursor を CSS の cursor の値へ。
    def cursorCss(cursor: GameEngine.Cursor): String = match cursor {
        case GameEngine.Cursor.Default   => "default"
        case GameEngine.Cursor.Crosshair => "crosshair"
        case GameEngine.Cursor.HResize   => "ew-resize"
        case GameEngine.Cursor.VResize   => "ns-resize"
        case GameEngine.Cursor.AllResize => "move"
        case GameEngine.Cursor.Rotate    => "pointer"
        case GameEngine.Cursor.NWResize  => "nwse-resize"
        case GameEngine.Cursor.SEResize  => "nwse-resize"
        case GameEngine.Cursor.NEResize  => "nesw-resize"
        case GameEngine.Cursor.SWResize  => "nesw-resize"
    }

    /// Platform.FrameClock を、前のコマから実際に経った時間（描き替えの時刻の差）で受ける。maxDeltaTime で切る。
    // WhyNot: 描き替えの回数で数えない — 120Hz の画面では 1 回が 8ms で、回数で進めると遊びが倍の速さになる。
    def handleFrameClock(st: State, f: Unit -> a \ ef): a \ (ef - Platform.FrameClock) + IO =
        run f() with handler Platform.FrameClock {
            def getDeltaTime(k) = k(Duration.seconds(Float64.min(Ref.get(st#lastDt), st#maxDeltaTime)))
        }

    /// Platform.Input を fge.web のキーとマウスの表で受ける。
    def handleInput(st: State, f: Unit -> a \ ef): a \ (ef - Platform.Input) + IO =
        run f() with handler Platform.Input {
            def isKeyPressed(key, k) = k(Keys.isDown(keyCode(key)))
            def getMousePosition(k) = k(canvasToDesign(st#design, Pointer.x(), Pointer.y()))
            def isMouseButtonPressed(button, k) = k(Pointer.isDown(buttonIndex(button)))
            def isGamepadTouched(k) = k(false)
            def gamepadKind(k) = k(GamepadMap.PadKind.Unknown)
            def consumeScrollDelta(k) = k(Pointer.consumeWheel())
            def consumeMouseDelta(k) = {
                let dx = Pointer.consumeDx();
                let dy = Pointer.consumeDy();
                k(canvasDeltaToDesign(st#design, dx, dy))
            }
            def isWindowFocused(k) = k(Browser.hasFocus())
        }

    // WhyNot: デスクトップの LwjglInput.windowToDesign の式（ウィンドウの大きさで割るだけ）にそろえない — 黒帯が出る大きさで指した所とずれる。
    /// canvas の描き先の画素（左上原点）を design の座標へ（黒帯を引く）。
    def canvasToDesign(design: Vec2.Vec2, px: Float64, py: Float64): Vec2.Vec2 \ IO =
        let fbW = Browser.canvasWidth();
        let fbH = Browser.canvasHeight();
        let (vpX, vpY, vpW, vpH) = RenderFrame.calcViewport(fbW, fbH, design#x, design#y);
        let top = fbH - vpY - vpH;
        { x = (px - Int32.toFloat64(vpX)) * design#x / Int32.toFloat64(Int32.max(1, vpW)),
          y = (py - Int32.toFloat64(top)) * design#y / Int32.toFloat64(Int32.max(1, vpH)) }

    /// canvas の画素の動きを design の動きへ。
    def canvasDeltaToDesign(design: Vec2.Vec2, dx: Float64, dy: Float64): Vec2.Vec2 \ IO =
        if (dx == 0.0 and dy == 0.0) Vec2.zero()
        else {
            let (_, _, vpW, vpH) = RenderFrame.calcViewport(Browser.canvasWidth(), Browser.canvasHeight(), design#x, design#y);
            { x = dx * design#x / Int32.toFloat64(Int32.max(1, vpW)), y = dy * design#y / Int32.toFloat64(Int32.max(1, vpH)) }
        }

    def buttonIndex(button: GameEngine.MouseButton): Int32 = match button {
        case GameEngine.MouseButton.Left   => 0
        case GameEngine.MouseButton.Middle => 1
        case GameEngine.MouseButton.Right  => 2
    }

    /// GameEngine.Key をブラウザの KeyboardEvent.code へ（US 配列の物理位置。GLFW のキーと同じ考え）。
    def keyCode(key: GameEngine.Key): String = match key {
        case GameEngine.Key.Up             => "ArrowUp"
        case GameEngine.Key.Down           => "ArrowDown"
        case GameEngine.Key.Left           => "ArrowLeft"
        case GameEngine.Key.Right          => "ArrowRight"
        case GameEngine.Key.Enter          => "Enter"
        case GameEngine.Key.Space          => "Space"
        case GameEngine.Key.Escape         => "Escape"
        case GameEngine.Key.Tab            => "Tab"
        case GameEngine.Key.Backspace      => "Backspace"
        case GameEngine.Key.Insert         => "Insert"
        case GameEngine.Key.Delete         => "Delete"
        case GameEngine.Key.PageUp         => "PageUp"
        case GameEngine.Key.PageDown       => "PageDown"
        case GameEngine.Key.Home           => "Home"
        case GameEngine.Key.End            => "End"
        case GameEngine.Key.CapsLock       => "CapsLock"
        case GameEngine.Key.Apostrophe     => "Quote"
        case GameEngine.Key.Comma          => "Comma"
        case GameEngine.Key.Minus          => "Minus"
        case GameEngine.Key.Period         => "Period"
        case GameEngine.Key.Slash          => "Slash"
        case GameEngine.Key.Semicolon      => "Semicolon"
        case GameEngine.Key.Equal          => "Equal"
        case GameEngine.Key.LeftBracket    => "BracketLeft"
        case GameEngine.Key.Backslash      => "Backslash"
        case GameEngine.Key.RightBracket   => "BracketRight"
        case GameEngine.Key.GraveAccent    => "Backquote"
        case GameEngine.Key.LeftShift      => "ShiftLeft"
        case GameEngine.Key.LeftCtrl       => "ControlLeft"
        case GameEngine.Key.LeftAlt        => "AltLeft"
        case GameEngine.Key.LeftSuper      => "MetaLeft"
        case GameEngine.Key.RightShift     => "ShiftRight"
        case GameEngine.Key.RightCtrl      => "ControlRight"
        case GameEngine.Key.RightAlt       => "AltRight"
        case GameEngine.Key.RightSuper     => "MetaRight"
        case GameEngine.Key.Menu           => "ContextMenu"
        case GameEngine.Key.NumpadDecimal  => "NumpadDecimal"
        case GameEngine.Key.NumpadDivide   => "NumpadDivide"
        case GameEngine.Key.NumpadMultiply => "NumpadMultiply"
        case GameEngine.Key.NumpadSubtract => "NumpadSubtract"
        case GameEngine.Key.NumpadAdd      => "NumpadAdd"
        case GameEngine.Key.NumpadEnter    => "NumpadEnter"
        case GameEngine.Key.NumpadEqual    => "NumpadEqual"
        case other                         => namedKeyCode(other)
    }

    /// 英字・数字・F キー・テンキーの数字（名前の形がそのまま code になる物）。
    def namedKeyCode(key: GameEngine.Key): String =
        let name = ToString.toString(key);
        if (String.length(name) == 1) "Key${name}"
        else name

    /// GameEngine.Audio を fge.web.WebAudio で受ける。知らない名前は名前ごとに 1 度だけ言って何もしない。
    // WhyNot: setLowpass で高い音を削らない — 今は OpenAL の EFX と同じ聞こえ方にする対応の式が決まっていない（素通しのまま）。
    def handleAudio(st: State, f: Unit -> a \ ef): a \ (ef - GameEngine.Audio) + IO =
        let known = (op: String, name: String) ->
            if (WebAudio.has(name)) true
            else if (Set.memberOf(name, Ref.get(st#warnedSounds))) false
            else {
                Ref.put(Set.insert(name, Ref.get(st#warnedSounds)), st#warnedSounds);
                Log.warnThen("audio: 知らない音 '${name}' — ${op} は何もしない（project.json の sounds に同名の宣言があるか確認）", false)
            };
        run f() with handler GameEngine.Audio {
            def playAudio(name, k) = { if (known("playAudio", name)) WebAudio.play(name) else (); k(()) }
            def stopAudio(name, k) = { if (known("stopAudio", name)) WebAudio.stop(name) else (); k(()) }
            def setVolume(name, volume, k) = { if (known("setVolume", name)) WebAudio.setVolume(name, volume) else (); k(()) }
            def setPitch(name, pitch, k) = { if (known("setPitch", name)) WebAudio.setPitch(name, pitch) else (); k(()) }
            def setLooping(name, loop, k) = { if (known("setLooping", name)) WebAudio.setLooping(name, loop) else (); k(()) }
            def setMasterVolume(gain, k) = { WebAudio.setMaster(Float64.max(0.0, Float64.min(1.0, gain))); k(()) }
            def setLowpass(name, _gainHF, k) = { discard known("setLowpass", name); k(()) }
            def audioSeconds(name, k) = k(WebAudio.seconds(name))
            def reloadAudio(_name, _path, k) = k(())
        }

    /// 起動中に、手を返さずに続けてよい長さ（ms）。
    def yieldMillis(): Float64 = 50.0

    // WhyNot: 起動中に手を返さずに読み続けない — 頁の進み具合のバーが描き替わらず、タブも固まって見える。
    /// 起動の進み具合を頁のバーに出し、前に手を返してから yieldMillis が経っていれば次の描き替えまでブラウザへ手を返す。ループが回り始めた後は何もしない。
    def showProgress(st: State): (String, Int32, Int32) -> Unit \ IO = (phase, done, total) ->
        if (Ref.get(st#looping)) ()
        else {
            Browser.progress(phase, done, total);
            if (Browser.now() - Ref.get(st#yieldedAt) >= yieldMillis()) {
                discard AnimationFrame.waitFrame();
                Ref.put(Browser.now(), st#yieldedAt)
            } else ()
        }

    /// LoadProgress を頁の進み具合のバーで受ける。仕事は順に流す（ブラウザの wasm は 1 本の糸）。
    /// 画像は起動の前に fge-web.js が解いておくので、ここで解く API は持たない（project.json の textures に載せる）。
    def handleLoadProgress(st: State, f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO =
        let report = showProgress(st);
        run f() with handler LoadProgress {
            def report(phase, done, total, k) = { report(phase, done, total); k(()) }
            def runTasks(phase, tasks, k) = { LoadProgress.runTasksInOrder(report, phase, tasks); k(()) }
            def imageDecoder(k) = k({ decode = _ -> checked_ecast(Err("ブラウザ版はゲームの中で画像を解けない（project.json の textures に載せる）")) })
        }
}
