// WebLayer — ブラウザ版の handler 一式（LwjglLayer と同じ役）。canvas の WebGL2 へ同じ塗りのコア（RenderPaint）で描き、
// キー・マウス・音・時計を fge.web（JS を閉じ込めた Java）から受ける。ゲームのループは止まる形のまま回り、
// presentFrame でブラウザの描き替え（requestAnimationFrame）まで待つ間だけブラウザへ手を返す。
// 利用例（web/WebMain.flix）: `run { ... App.launchWithDevTools(App.DevTools.none(), app) } with WebLayer.withProject(".") with WebFs.runFileRead with WebFs.runFileWrite`
// Scene3d を描くゲームは withProject の代わりに withProject3d を使う。
// WhyNot: 開発の道具（注釈・RemoteDebug・Doc の監視）の handler を持たない — ブラウザ版は配る出力先の 1 つで、開発はデスクトップでする。
pub mod WebLayer {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import fge.web.AnimationFrame
    import fge.web.Browser
    import fge.web.Deferred
    import fge.web.Keys
    import fge.web.Pointer
    import fge.web.WebAudio
    import fge.web.WebImages
    import fge.web.WebGl2

    /// 1 秒に進めるコマの上限。速い画面（120Hz・165Hz）では描き替えを間引いてこの数に近づける（遊びの速さは dt で同じ・電池のため）。
    pub def tickRate(): Float64 = 60.0

    /// 2D のゲームの入口。3D の描き手を持たないので、Scene3d の場面は描かず初回に 1 回知らせる。
    // WhyNot: 2D の入口を withProject3d に寄せて 1 本にしない — ここから Render3d へ届くと、3D を使わないゲームの wasm まで太る。
    pub def withProject(rootDir: String, f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO + Fs.FileRead =
        withProjectUsing(rootDir, (_, _) -> makeWarningRenderer(), f)

    /// Scene3d を描くゲームの入口。
    pub def withProject3d(rootDir: String, f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO + Fs.FileRead =
        withProjectUsing(rootDir, (gl, config) -> Render3d.makeRenderer(gl, config, Render3d.DrawMode.Instanced), f)

    /// `rootDir` 直下の project.json を読んで withWeb を起動する。読めなければ止める（LwjglLayer.withProject と同じ）。
    def withProjectUsing(rootDir: String, makeRenderer: (GlContext, GameEngine.EngineConfig) -> Scene3dRenderer.Renderer \ IO,
                         f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO + Fs.FileRead =
        match ProjectLoader.loadProject(rootDir) {
            case Ok(proj) => withWeb(makeRenderer, bootConfigOf(proj), f)
            case Err(msg) => bug!("Failed to load project.json: ${msg}")
        }

    /// 場面を描かない描き手。場面が来たら初回に 1 回だけ、withProject3d へ替えるよう知らせる。
    def makeWarningRenderer(): Scene3dRenderer.Renderer \ IO =
        let warned = Ref.fresh(Static, false);
        { prepare = (_, _, _, cmds) -> {
              if (List.isEmpty(cmds) or Ref.get(warned)) ()
              else {
                  Ref.put(true, warned);
                  Log.warn("scene3d: WebLayer.withProject は 3D を描かない — web/WebMain.flix を WebLayer.withProject3d へ替える")
              };
              Scene3dRenderer.noScenes()
          } | Scene3dRenderer.none() }

    // WhyNot: 頁を開いた時（素材を取る前）に測らない — 読み込みの間に回した端末で、古い向きのまま起動する。押して始めた後の main で測る。
    /// 起動に使う設定。縦の design を選ぶ時（スマホを縦に持って開いた・頁の ?orientation=portrait）で、project.json に
    /// web.portraitDesign があれば、その時の描き先の比から決めた縦の design に替える（Display#orientation が Portrait になる）。
    def bootConfigOf(proj: ProjectLoader.Project): GameEngine.EngineConfig \ IO =
        let wanted = Browser.wantsPortrait();
        match proj#portraitDesign {
            case Some(spec) if wanted => applyPortraitDesign(proj, spec)
            case _                    => proj#config
        }

    /// 描き先を切り欠きの内側へ寄せて測り、その比から縦の design を決めて、描き先の比を縦の design に替える。
    def applyPortraitDesign(proj: ProjectLoader.Project, spec: ProjectLoader.PortraitDesign): GameEngine.EngineConfig \ IO =
        Browser.preparePortraitView();
        let view = { x = Browser.portraitViewWidth(), y = Browser.portraitViewHeight() };
        let (w, h) = ProjectLoader.portraitDesignOf(spec, view);
        Browser.usePortraitDesign(Int32.toFloat64(w) / Int32.toFloat64(Int32.max(1, h)));
        { designWidth = w, designHeight = h | proj#config }

    /// canvas の WebGL2 で塗りのコアを作り、素材を上げ、handler を重ねて f を流す。f を抜けたら頁に「おわり」を出す。
    /// makeRenderer = 3D の描き手の作り方。
    def withWeb(makeRenderer: (GlContext, GameEngine.EngineConfig) -> Scene3dRenderer.Renderer \ IO, config: GameEngine.EngineConfig,
                f: Unit -> a \ ef): a \ ef - Platform.Services - LoadProgress + IO =
        Browser.setTitle(config#title);
        let gl: GlContext = checked_cast(new WebGl2());
        // 塗りのコアは混ぜ方が普通（SRC_ALPHA, ONE_MINUS_SRC_ALPHA）で始まっている前提で描く（LwjglLayer と同じ始め方）。
        gl.enable(GlConst.BLEND);
        gl.blendFunc(GlConst.SRC_ALPHA, GlConst.ONE_MINUS_SRC_ALPHA);
        let paint = RenderPaint.create(gl, { designWidth = config#designWidth, designHeight = config#designHeight,
                                             clearColor = config#clearColor, screenFramebuffer = 0,
                                             scene3d = makeRenderer(gl, config), gpuTimer = RenderPaint.noFrameTimer() });
        // 組み込みフォント（fps の表示・名前が合わないフォントの受け皿）とロゴも登録簿へ。
        RenderPaint.addTextures(RenderSplash.install(gl), paint);
        let design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) };
        let framebufferSize = () -> (Browser.canvasWidth(), Browser.canvasHeight());
        let state = {
            design = design, maxDeltaTime = config#maxDeltaTime,
            looping = Ref.fresh(Static, false), closeRequested = Ref.fresh(Static, false),
            lastDt = Ref.fresh(Static, 1.0 / tickRate()), fullscreenAsked = Ref.fresh(Static, FullscreenAsk.NotAsked),
            cursor = Ref.fresh(Static, GameEngine.Cursor.Default), cursorVisible = Ref.fresh(Static, true),
            yieldedAt = Ref.fresh(Static, Browser.now()), warnedSounds = Ref.fresh(Static, Set.empty()),
            budget = Ref.fresh(Static, initialBudget()), spentMs = Ref.fresh(Static, 0.0), pendingTextures = Ref.fresh(Static, Nil),
            pendingSounds = Ref.fresh(Static, Map.empty())
        };
        let fonts = RenderPaint.loadAssets(gl, paint, WebAssets.loader(), config, showProgress(state));
        Ref.put(config#textureManifest |> List.filter(e -> Deferred.isDeferred(e#path) and Deferred.state(e#path) != "loaded"), state#pendingTextures);
        let onPoll = () -> { registerArrivedTextures(gl, paint, state); playArrivedSounds(state) };
        let result =
            handleLoadProgress(state, () ->
            handleAudio(state, () ->
            RenderPaintHandlers.handleTarget(gl, paint, framebufferSize, () ->
            RenderPaintHandlers.handleDiagnostics(paint, () ->
            RenderPaintHandlers.handleDraw3d(paint, () ->
            Platform.runTasksInPlace(() ->
            handleFrameClock(state, () ->
            handleWindow(state, onPoll, () ->
            RenderPaintHandlers.handleDraw2d(gl, paint, framebufferSize, (_, _) -> checked_ecast(()), () ->
            handleInput(state, () ->
            RenderPaintHandlers.handleGpuResources(gl, paint, fonts, f)))))))))));
        Browser.ended();
        result

    // WhyNot: 例外を Flix の try で受けて頁に出さない — effect の続きで再開した後の例外はその try の外で投げられる（bug! で確かめた）。
    //   頁に出すのは fge-web.js の window の error（wasm の外へ抜けた例外を全部受ける）。

    /// 前に頼んだ全画面（まだ頼んでいない・窓・全画面）。
    enum FullscreenAsk with Eq {
        case NotAsked
        case Windowed
        case Fullscreen
    }

    /// handler が分け合う状態。looping = ループが回り始めたか（最初の pollEvents の後）・lastDt = 前のコマからの経過（秒）・
    /// fullscreenAsked = 前に頼んだ全画面（同じ値を毎コマ頼み直さない）・yieldedAt = 起動中に最後にブラウザへ手を返した時刻（ms）・
    /// budget = 届いた 2D の絵を登録する予算（AssetDownloads#setBudget が替える）・spentMs = このコマに絵の登録に使った ms・
    /// pendingTextures = まだ登録していない後回しの絵・pendingSounds = 届く前に鳴らせと言われた後回しの音（名前 → 最後に言われた鳴らし方）。
    type alias State = {
        design = Vec2.Vec2, maxDeltaTime = Float64,
        looping = Ref[Bool, Static], closeRequested = Ref[Bool, Static],
        lastDt = Ref[Float64, Static], fullscreenAsked = Ref[FullscreenAsk, Static],
        cursor = Ref[GameEngine.Cursor, Static], cursorVisible = Ref[Bool, Static],
        yieldedAt = Ref[Float64, Static], warnedSounds = Ref[Set[String], Static],
        budget = Ref[LoadProgress.DecodeBudget, Static], spentMs = Ref[Float64, Static], pendingTextures = Ref[List[RenderAsset.TextureEntry], Static],
        pendingSounds = Ref[Map[String, LoadProgress.Deferred.PendingSound], Static]
    }

    /// 最初の setBudget より前の予算（App.withDecodeBudget の既定と同じ）。
    // WhyNot: 部屋を解く長さ（100 ms 前後）にしない — 予算を渡さないゲームでは文字送りの間も毎コマ使われ、届いた絵が重なったコマで止まりが見える。1 本の道は必ず登録するので遅れは出ない。
    def initialBudget(): LoadProgress.DecodeBudget = LoadProgress.DecodeBudget.Idle(4.0)

    /// Platform.Window を頁と canvas で受ける。presentFrame で次の描き替えまで待つ（ブラウザが絵を出すのは手を返した後）。
    /// onPoll = コマの頭（pollEvents）でする事（後から届いた素材を使えるようにする）。
    def handleWindow(st: State, onPoll: Unit -> Unit \ IO, f: Unit -> a \ ef): a \ (ef - Platform.Window) + IO =
        run f() with handler Platform.Window {
            def pollEvents(k) = {
                if (not Ref.get(st#looping)) { Ref.put(true, st#looping); Browser.started() } else ();
                Browser.beginFrame();
                onPoll();
                k(())
            }
            def shouldClose(k) = k(Ref.get(st#closeRequested))
            def setShouldClose(close, k) = { Ref.put(close, st#closeRequested); k(()) }
            def getViewportRect(k) = k({ position = Vec2.zero(), size = st#design })
            def getDisplay(k) = k(display(st#design))
            def presentFrame(k) = {
                Browser.frameDrawn();
                let dt = AnimationFrame.waitTick(tickRate());
                Ref.put(if (Browser.isFrameCapture()) 1.0 / tickRate() else dt, st#lastDt);
                k(())
            }
            def setCursor(cursor, k) = { Ref.put(cursor, st#cursor); applyCursor(st); k(()) }
            def setCursorVisible(visible, k) = { Ref.put(visible, st#cursorVisible); applyCursor(st); k(()) }
            def setMouseCaptured(captured, k) = { Pointer.setCaptured(captured); k(()) }
            def setFullscreen(on, k) = {
                // WhyNot: 同じ値を毎コマ頼み直さない — Esc でブラウザが全画面を抜けた後、次のキーでまた入ってしまう。
                let asked = if (on) FullscreenAsk.Fullscreen else FullscreenAsk.Windowed;
                if (Ref.get(st#fullscreenAsked) != asked) { Ref.put(asked, st#fullscreenAsked); Browser.requestFullscreen(on) } else ();
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

    /// 頁の画面の情報。canvas の画素は CSS px × devicePixelRatio。区分は fge-web.js が起動の時に決めた物。
    def display(design: Vec2.Vec2): Display.Display \ IO =
        let (fbW, fbH) = (Browser.canvasWidth(), Browser.canvasHeight());
        let (_, _, vpW, vpH) = RenderFrame.calcViewport(fbW, fbH, design#x, design#y);
        let dpr = Float64.max(0.01, Browser.devicePixelRatio());
        let scale = Float64.min(Int32.toFloat64(vpW) / design#x, Int32.toFloat64(vpH) / design#y) / dpr;
        { size = { x = Int32.toFloat64(fbW) / dpr, y = Int32.toFloat64(fbH) / dpr }, scaleFactor = dpr,
          designScale = if (scale > 0.0) scale else 1.0,
          pointer = if (Pointer.isTouch()) Display.PointerKind.Touch else Display.PointerKind.Mouse,
          sizeClass = sizeClass(), orientation = Display.orientationOf(design) }

    /// 端末の区分。頁の URL の ?size=small|medium|large があればそれ（PC で小さい画面の並べ方を確かめる時）、
    /// 無ければ主な pointer が指か（?input= で上書きできる）と、起動の時に測った画面の短い辺から決める。
    def sizeClass(): Display.SizeClass \ IO = match Browser.sizeOverride() {
        case "small"  => Display.SizeClass.Small
        case "medium" => Display.SizeClass.Medium
        case "large"  => Display.SizeClass.Large
        case _        => Display.sizeClassOf(Browser.isCoarsePointer(), Browser.screenShortSide())
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
    /// 後回しでまだ届いていない音は鳴らさず、鳴らし方（playAudio・setLooping・setVolume・setPitch）を覚えて stopAudio で忘れる。
    /// 届いた時にまだ覚えていて、ループする音なら最後の音量・高さで鳴らす（playArrivedSounds）。取れなかった後回しの音は名前ごとに 1 度言う。
    /// audioSeconds は届く前の音に 0 を返す（使う側は AssetDownloads#missing で届いていない名前を見る）。
    // WhyNot: setLowpass で高い音を削らない — 今は OpenAL の EFX と同じ聞こえ方にする対応の式が決まっていない（素通しのまま）。
    def handleAudio(st: State, f: Unit -> a \ ef): a \ (ef - GameEngine.Audio) + IO =
        let warnOnce = (name: String, message: String) ->
            if (Set.memberOf(name, Ref.get(st#warnedSounds))) ()
            else {
                Ref.put(Set.insert(name, Ref.get(st#warnedSounds)), st#warnedSounds);
                Log.warn(message)
            };
        let known = (op: String, name: String) ->
            if (WebAudio.has(name)) true
            else if (Deferred.isDeferred(name)) {
                match LoadProgress.Deferred.loadStateOfText(Deferred.state(name)) {
                    case LoadProgress.LoadState.Failed(why) => warnOnce(name, "audio: 後回しの音 '${name}' を取れなかった — ${op} は何もしない（${why}）")
                    case _                                  => ()
                };
                false
            }
            else { warnOnce(name, "audio: 知らない音 '${name}' — ${op} は何もしない（project.json の sounds に同名の宣言があるか確認）"); false };
        let note = (name: String, call: LoadProgress.Deferred.SoundCall) ->
            if (WebAudio.has(name) or not Deferred.isDeferred(name)) ()
            else Ref.put(LoadProgress.Deferred.notePendingSound(name, call, Ref.get(st#pendingSounds)), st#pendingSounds);
        run f() with handler GameEngine.Audio {
            def playAudio(name, k) = { note(name, LoadProgress.Deferred.SoundCall.Play); if (known("playAudio", name)) WebAudio.play(name) else (); k(()) }
            def stopAudio(name, k) = { note(name, LoadProgress.Deferred.SoundCall.Stop); if (known("stopAudio", name)) WebAudio.stop(name) else (); k(()) }
            def setVolume(name, volume, k) = { note(name, LoadProgress.Deferred.SoundCall.SetVolume(volume)); if (known("setVolume", name)) WebAudio.setVolume(name, volume) else (); k(()) }
            def setPitch(name, pitch, k) = { note(name, LoadProgress.Deferred.SoundCall.SetPitch(pitch)); if (known("setPitch", name)) WebAudio.setPitch(name, pitch) else (); k(()) }
            def setLooping(name, loop, k) = { note(name, LoadProgress.Deferred.SoundCall.SetLooping(loop)); if (known("setLooping", name)) WebAudio.setLooping(name, loop) else (); k(()) }
            def setMasterVolume(gain, k) = { WebAudio.setMaster(Float64.max(0.0, Float64.min(1.0, gain))); k(()) }
            def setLowpass(name, _gainHF, k) = { discard known("setLowpass", name); k(()) }
            def audioSeconds(name, k) = k(WebAudio.seconds(name))
            def reloadAudio(_name, _path, k) = k(())
        }

    /// 覚えていた音のうち届いた物に、最後の鳴らし方を当てる（ループする音で鳴らせと言われていれば鳴らす）。
    def playArrivedSounds(st: State): Unit \ IO =
        let pending = Ref.get(st#pendingSounds);
        if (Map.isEmpty(pending)) ()
        else {
            let arrived = Map.filterWithKey((name: String, _) -> WebAudio.has(name), pending);
            Ref.put(Map.filterWithKey((name: String, _) -> not Map.memberOf(name, arrived), pending), st#pendingSounds);
            Map.forEach((name: String, p: LoadProgress.Deferred.PendingSound) -> {
                p#looping |> Option.forEach(loop -> WebAudio.setLooping(name, loop));
                p#volume |> Option.forEach(volume -> WebAudio.setVolume(name, volume));
                p#pitch |> Option.forEach(pitch -> WebAudio.setPitch(name, pitch));
                if (LoadProgress.Deferred.playsOnArrival(p, WebAudio.isLooping(name))) WebAudio.play(name) else ()
            }, arrived)
        }

    /// 届いた後回しの 2D の絵を、予算の内で道ごとに登録する（Paused なら登録しない・Idle と Covered は 1 本の道は必ず、
    /// 2 本目からは ms に収まるまで）。1 本の道の名前は全部同じコマで登録し、登録し終えた道を fge-web.js に知らせる。使った ms は spentMs へ。
    def registerArrivedTextures(gl: GlContext, paint: RenderPaint.Paint, st: State): Unit \ IO =
        Ref.put(0.0, st#spentMs);
        let pending = Ref.get(st#pendingTextures);
        let limit = match Ref.get(st#budget) {
            case LoadProgress.DecodeBudget.Paused     => None
            case LoadProgress.DecodeBudget.Idle(ms)    => Some(ms)
            case LoadProgress.DecodeBudget.Covered(ms) => Some(ms)
        };
        match limit {
            case Some(ms) if not List.isEmpty(pending) =>
                let (ready, waiting) = List.partition(e -> WebImages.has(e#path), pending);
                let began = Browser.now();
                let left = registerWithin(gl, paint, began, ms, true, LoadProgress.Deferred.groupByPath(e -> e#path, ready));
                Ref.put(Browser.now() - began, st#spentMs);
                Ref.put(List.append(left, waiting), st#pendingTextures)
            case _ => ()
        }

    def registerWithin(gl: GlContext, paint: RenderPaint.Paint, began: Float64, ms: Float64, first: Bool,
                       ready: List[(String, List[RenderAsset.TextureEntry])]): List[RenderAsset.TextureEntry] \ IO = match ready {
        case Nil => Nil
        case (path, entries) :: rest =>
            if (not first and Browser.now() - began >= ms) List.flatMap(snd, ready)
            else {
                entries |> List.forEach(e -> RenderPaint.putTexture(e#name, WebAssets.uploadImageOf(gl, e), paint));
                Deferred.markLoaded(path);
                registerWithin(gl, paint, began, ms, false, rest)
            }
    }

    /// 後回しの素材を引く関数の組（fge.web.Deferred を包む）。setBudget は登録の予算を替え、spentMs はこのコマの登録に使った ms。
    def downloadsOf(st: State): LoadProgress.AssetDownloads =
        { stateOf = path -> LoadProgress.Deferred.loadStateOfText(Deferred.state(path)),
          missing = () -> linesOf(Deferred.missing()) |> List.toSet,
          request = paths -> if (List.isEmpty(paths)) () else Deferred.request(String.intercalate("\n", paths)),
          release = paths -> if (List.isEmpty(paths)) () else Deferred.release(String.intercalate("\n", paths)),
          setBudget = budget -> Ref.put(budget, st#budget),
          spentMs = () -> Ref.get(st#spentMs) }

    def linesOf(text: String): List[String] =
        if (String.isEmpty(text)) Nil else String.split(regex = "\n", text)

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
    /// project.json の textures の画像は起動の前に fge-web.js が解いておく。imageDecoder はゲームの中で読んだバイト（glb の中の絵など）を解く。
    def handleLoadProgress(st: State, f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO =
        let report = showProgress(st);
        run f() with handler LoadProgress {
            def report(phase, done, total, k) = { report(phase, done, total); k(()) }
            def runTasks(phase, tasks, k) = { LoadProgress.runTasksInOrder(report, phase, tasks); k(()) }
            def imageDecoder(k) = k({ decode = decodeImage, platformImage = platformImageOf, versionedKey = versionedKeyOf })
            def downloads(k) = k(downloadsOf(st))
        }

    /// 道の絵を ImageBitmap に解いて JS の側に持ち、その key を返す（解くまでゲームのループごと止まる）。束に無い・解けない道は None。
    def platformImageOf(path: String): Option[ImageData.PlatformImage] \ IO =
        if (WebImages.holdPlatformImage(path)) Some({ key = WebImages.platformKey(path), width = WebImages.width(path), height = WebImages.height(path) })
        else None

    /// 道と書き出しの版の字（束の中身は版ごとに変わらない）。
    def versionedKeyOf(path: String): Option[String] \ IO = Some(WebImages.platformKey(path))

    /// PNG か JPEG か WebP のバイトを画素へ解く（WebP は書き出しが替えた絵）。解き終わるまでゲームのループごと止まる。
    def decodeImage(bytes: Vector[Int8]): Result[String, ImageData.ImageData] \ IO =
        let image = WebImages.decode(unchecked_cast(bytes as Array[Int8, Static]));
        let error = image.error();
        if (String.isEmpty(error)) Ok({ width = image.width(), height = image.height(), argb = Array.toVector(image.argb()) })
        else Err(error)
}
