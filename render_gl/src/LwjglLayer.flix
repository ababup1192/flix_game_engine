// LwjglLayer — ウィンドウ表示・入力の読み取り・音の再生を実機で受け持ち、GameEngine.Game / Audio の
// effect ハンドラを提供する。ゲーム側はこの入口越しに描画や入力を頼むだけで、GL や OpenAL の
// 細部を知らずに済む。
// 利用例: `withLwjgl(config, ...)` でウィンドウを開き、ゲームループを回す。
// 注意: GL / OpenAL / シェーダ / テクスチャ / フォントベイク / フレーム描画 / 音声デコードは
//   同じ render_gl 内の各 mod（Render / Shader / Texture / Font / Frame / Audio 等）にあり、
//   このファイルは GLFW 外周だけを持って各 effect の本体から呼ぶ。
//   `withLwjgl` の第1引数 EngineConfig と戻り値の effect 制約は公開 API として固定（ゲーム側を変えずに済む）。

pub mod LwjglLayer {
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.glfw.GLFWGamepadState
    import org.lwjgl.glfw.Callbacks
    import org.lwjgl.glfw.GLFWFramebufferSizeCallbackI
    import org.lwjgl.glfw.GLFWMouseButtonCallbackI
    import org.lwjgl.glfw.GLFWScrollCallbackI
    import org.lwjgl.glfw.GLFWVidMode
    import org.lwjgl.opengl.GL
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL20
    import org.lwjgl.openal.AL
    import org.lwjgl.openal.AL10
    import org.lwjgl.openal.EXTEfx
    import org.lwjgl.openal.ALC
    import org.lwjgl.openal.ALC10
    import org.lwjgl.system.MemoryStack
    import org.lwjgl.system.MemoryUtil
    import java.lang.System
    import java.lang.Exception
    import java.lang.Math
    import java.awt.BasicStroke
    import java.awt.{Color => AwtColor}
    import java.awt.image.BufferedImage
    import java.io.File
    import java.io.FileWriter
    import java.time.LocalDateTime
    import java.time.format.DateTimeFormatter
    import javax.imageio.ImageIO

    // ========================================================================
    // GLFW Code Mapping (engine の論理キー → GLFW 数値コード)
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

    /// GLFW 3.4 (LWJGL 3.4.1 同梱) の cursor shape 定数。
    /// 4 隅は GLFW では対角単位 (NWSE / NESW) の 2 種しか無いので、
    /// NW + SE → GLFW_RESIZE_NWSE_CURSOR、NE + SW → GLFW_RESIZE_NESW_CURSOR にエイリアス。
    def cursorShapeToGlfw(cursor: GameEngine.Cursor): Int32 = match cursor {
        case GameEngine.Cursor.Default    => 0x36001  // GLFW_ARROW_CURSOR
        case GameEngine.Cursor.Crosshair  => 0x36003  // GLFW_CROSSHAIR_CURSOR
        case GameEngine.Cursor.HResize    => 0x36005  // GLFW_HRESIZE_CURSOR
        case GameEngine.Cursor.VResize    => 0x36006  // GLFW_VRESIZE_CURSOR
        case GameEngine.Cursor.AllResize  => 0x36009  // GLFW_RESIZE_ALL_CURSOR
        case GameEngine.Cursor.Rotate     => 0x36004  // GLFW_POINTING_HAND_CURSOR
        case GameEngine.Cursor.NWResize   => 0x36007  // GLFW_RESIZE_NWSE_CURSOR
        case GameEngine.Cursor.SEResize   => 0x36007  // GLFW_RESIZE_NWSE_CURSOR
        case GameEngine.Cursor.NEResize   => 0x36008  // GLFW_RESIZE_NESW_CURSOR
        case GameEngine.Cursor.SWResize   => 0x36008  // GLFW_RESIZE_NESW_CURSOR
    }

    // ========================================================================
    // 注釈の書き出し（saveAnnotation ハンドラの下請け）
    // ========================================================================

    /// タイトルをディレクトリ名に使える形へ整える（英数字以外は "_" に置換）。
    def sanitizeName(name: String): String =
        name |> String.map(c -> if (Char.isLetter(c) or Char.isDigit(c)) c else '_')

    /// 四捨五入で Int32 へ（非負前提。注釈矩形の px 変換用）。
    def roundToInt(v: Float64): Int32 =
        Float64.tryToInt32(v + 0.5) |> Option.getWithDefault(0)

    /// 起動画面の見た目を目で確かめるための書き出し口。環境変数 FLIX_GE_SPLASH_SHOT に
    /// 保存先（`.../splash.png`）を入れて起動すると、間を空けて数枚だけ `splash-1.png` …
    /// と落とす。ゲージが伸びているかを並べて確かめられる。
    /// **枚数と間隔を絞ってあるのが肝** — 毎回書くと画面全体の読み出しと PNG 圧縮が
    /// 読み込みの合間ごとに挟まり、起動が止まったように見えるほど遅くなる。
    def splashShotLimit(): Int32 = 4
    def splashShotGapMillis(): Int64 = 700i64

    def splashShot(fbW: Int32, fbH: Int32, taken: Array[Int32, Static],
                   lastNanos: Array[Int64, Static]): Unit \ IO =
        let path = System.getenv("FLIX_GE_SPLASH_SHOT");
        let count = Array.get(0, taken);
        let now = System.nanoTime();
        let gap = (now - Array.get(0, lastNanos)) / 1000000i64;
        if (Object.isNull(path) or count >= splashShotLimit() or gap < splashShotGapMillis()) ()
        else {
            Array.put(count + 1, 0, taken);
            Array.put(now, 0, lastNanos);
            let stem = if (String.endsWith({ suffix = ".png" }, path))
                           String.dropRight(4, path)
                       else path;
            discard ImageIO.write(framebufferImage(fbW, fbH), "png",
                                  new File("${stem}-${count + 1}.png"))
        }

    /// 画面 1 フレームの絵を確かめるための書き出し口。環境変数 FLIX_GE_FRAME_SHOT に
    /// 保存先ディレクトリを入れて起動すると、swap の直前の絵を `frame-1.png` … と落とす
    /// （GL 突き合わせ harness の画面口。swap の後の back buffer は GL 仕様上 undefined
    /// なので、外から読む形にはできない）。
    /// 枚数上限は env の消し忘れ保険 — 実機 run に残ると毎フレームの全画面読み出しと
    /// PNG 圧縮が挟まり、ゲームが止まったように見えるほど遅くなる。
    def frameShotLimit(): Int32 = 16

    def frameShot(fbW: Int32, fbH: Int32, taken: Array[Int32, Static]): Unit \ IO =
        let dir = System.getenv("FLIX_GE_FRAME_SHOT");
        let count = Array.get(0, taken);
        if (Object.isNull(dir) or count >= frameShotLimit()) ()
        else {
            Array.put(count + 1, 0, taken);
            GlReadback.readBoundPng(fbW, fbH, "${dir}/frame-${count + 1}.png")
        }

    /// 現在のフレームバッファを読み出して画像にする（読み出しの核は GlReadback）。
    /// RGB に落とすのは、splashShot・注釈スクショの出力 PNG のバイト列を変えないため。
    def framebufferImage(fbW: Int32, fbH: Int32): BufferedImage \ IO =
        GlReadback.readBoundImageRgb(fbW, fbH)

    /// デザイン座標の矩形を、書き出し画像（左上原点）上の px 矩形へ変換する。
    /// 黒帯（レターボックス / ピラーボックス）ぶんのオフセットも織り込む。
    def designRectToImage(rect: Rect2.Rect2, fbW: Int32, fbH: Int32,
                          designW: Float64, designH: Float64): {x = Int32, y = Int32, w = Int32, h = Int32} =
        let (vpX, vpY, vpW, vpH) = RenderFrame.calcViewport(fbW, fbH, designW, designH);
        let sx = Int32.toFloat64(vpW) / designW;
        let sy = Int32.toFloat64(vpH) / designH;
        // glViewport の vpY は下端基準。上下反転済みの画像では上端 = fbH - vpY - vpH
        let topOffset = fbH - vpY - vpH;
        { x = vpX + roundToInt(rect#position#x * sx),
          y = topOffset + roundToInt(rect#position#y * sy),
          w = roundToInt(rect#size#x * sx),
          h = roundToInt(rect#size#y * sy) }

    /// 画像に注釈矩形の赤枠を描き込む（人間が見てすぐ分かる用。書き込み先は上書き）。
    def burnHighlight(image: BufferedImage, rectPx: {x = Int32, y = Int32, w = Int32, h = Int32}): Unit \ IO =
        let g = image.createGraphics();
        g.setColor(new AwtColor(255, 32, 32));
        g.setStroke(new BasicStroke(3.0f32));
        g.drawRect(rectPx#x, rectPx#y, rectPx#w, rectPx#h);
        g.dispose()

    /// 画像を PNG として書く（親ディレクトリは呼び側が作成済み）。
    def writePngFile(image: BufferedImage, path: String): Unit \ IO =
        discard ImageIO.write(image, "png", new File(path))

    /// テキストをファイルに書く。
    def writeTextFile(path: String, content: String): Unit \ IO =
        let writer = new FileWriter(path);
        writer.write(content);
        writer.close()

    /// カメラのシャッター風の短い効果音を合成して OpenAL のソースにする。
    /// 音の形: 硬い立ち上がりのノイズがすぐ減衰（幕が走る）→ 少し遅れて小さな
    /// ノイズがもう 1 発（幕が戻る）。注釈の保存が成功したときに鳴らす。
    def buildShutterSource(): Int32 \ IO =
        let rate = 44100;
        let sampleCount = rate * 15 / 100;  // 0.15 秒
        let buf = MemoryUtil.memAlloc(sampleCount * 2);
        def fill(i: Int32, seed: Int32): Unit \ IO = {
            if (i >= sampleCount) ()
            else {
                // 線形合同法の白色ノイズ（-1.0〜1.0）
                let nextSeed = seed * 1103515245 + 12345;
                let noise = Int32.toFloat64(Int32.remainder(nextSeed, 10000)) / 10000.0;
                let t = Int32.toFloat64(i) / Int32.toFloat64(rate);
                // 1 発目: 0 秒から 12ms で減衰 / 2 発目: 70ms から 20ms で減衰・小さめ
                let env1 = Math.exp(0.0 - t / 0.012);
                let env2 = if (t > 0.07) Math.exp(0.0 - (t - 0.07) / 0.02) * 0.55 else 0.0;
                let sample = noise * (env1 + env2) * 0.5;
                let s16 = Float64.tryToInt32(sample * 32000.0)
                    |> Option.getWithDefault(0)
                    |> Int32.tryToInt16
                    |> Option.getWithDefault(0i16);
                buf.putShort(i * 2, s16);
                fill(i + 1, nextSeed)
            }
        };
        fill(0, 20260710);
        let alBuffer = AL10.alGenBuffers();
        AL10.alBufferData(alBuffer, AL10.AL_FORMAT_MONO16, buf, rate);
        MemoryUtil.memFree(buf);
        let source = AL10.alGenSources();
        AL10.alSourcei(source, AL10.AL_BUFFER, alBuffer);
        source

    /// README.md の全文（見出し・画像埋め込み・要約・リンク・コメント欄）を組み立てる。
    def readmeText(args: {title = String, stamp = String, frame = Int64, body = String}): String =
        "# 注釈: ${args#title} — frame ${args#frame}（${args#stamp}）\n\n"
        + "![highlighted](highlighted.png)\n\n"
        + "${args#body}\n\n"
        + "- 機械可読データ: [annotation.json](annotation.json)\n"
        + "- 素のフレーム: [screenshot.png](screenshot.png)\n\n"
        + "## コメント\n\n"
        + "（ここに修正指示を書いてください）\n"

    // ========================================================================
    // LWJGL Handler for GameEngine.Game / GameEngine.Audio effects
    // ========================================================================

    /// `rootDir` 直下の project.json を読んで `withLwjgl` を起動する便利ラッパ。
    /// examples の Main.flix からは `with LwjglLayer.withProject(".")` の形で
    /// 直接 with-chain に並べて使う。loadProject 失敗時は bug! で停止する
    /// (project.json が壊れているのは開発者が直すべき状態)。
    pub def withProject(rootDir: String, f: Unit -> a \ ef):
            a \ ef - GameEngine.Game - GameEngine.Audio - ShaderEffect.Shader - RenderTarget.Target + IO + Fs.FileRead =
        match ProjectLoader.loadProject(rootDir) {
            case Ok(proj)  => withLwjgl(proj#config, f)
            case Err(msg) => bug!("Failed to load project.json: ${msg}")
        }

    pub def withLwjgl(config: GameEngine.EngineConfig, f: Unit -> a \ ef): a \ ef - GameEngine.Game - GameEngine.Audio - ShaderEffect.Shader - RenderTarget.Target + IO =
        // GLFW と AWT は macOS で同じメインスレッド・GL を取り合って固まるため、
        // このウィンドウ（GLFW）のプロセスでは AWT を headless に固定する。注釈のスクリーンショット
        // 保存（BufferedImage / Graphics2D / ImageIO）はオフスクリーン描画なので headless でも動く。
        discard System.setProperty("java.awt.headless", "true");
        if (not GLFW.glfwInit()) {
            println("GLFW init failed");
            bug!("GLFW failed")
        } else ();

        GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR, 3);
        GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR, 3);
        GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE, GLFW.GLFW_OPENGL_CORE_PROFILE);
        GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_FORWARD_COMPAT, GL11.GL_TRUE);
        GLFW.glfwWindowHint(GLFW.GLFW_RESIZABLE, GL11.GL_TRUE);
        // シェーダー面を任意形（丸い池など）に抜くステンシル用に、既定フレームバッファへ
        // 8bit のステンシルを確保する。使うのはマスク描画のときだけ（通常描画は無影響）。
        GLFW.glfwWindowHint(GLFW.GLFW_STENCIL_BITS, 8);

        // 隠しウィンドウモード（GL 突き合わせ harness 用）。Retina の 2 倍化を切るのは、
        // フレームバッファ = design 寸に固定しないと letterbox 補間が乗り、
        // 画素の突き合わせが成立しないため。
        let hidden = not Object.isNull(System.getenv("FLIX_GE_HIDDEN"));
        if (hidden) {
            GLFW.glfwWindowHint(GLFW.GLFW_VISIBLE, GL11.GL_FALSE);
            GLFW.glfwWindowHint(GLFW.GLFW_COCOA_RETINA_FRAMEBUFFER, GL11.GL_FALSE)
        } else ();

        // 隠しウィンドウは design 寸（ポイント）で作る。この開発機の実測では、隠しウィンドウの drawable は
        // Retina 倍にならずウィンドウのポイント寸のままなので、これで drawable = design になる。
        // Retina 倍になる環境でも drawable は design より大きいだけで、描画も読み出しも
        // 左下 design 領域の 1:1 で完結する（下の隅印の門番が実測で確かめる）。
        let (createW, createH) = if (hidden) (config#designWidth, config#designHeight)
                                 else (config#windowWidth, config#windowHeight);
        let window = GLFW.glfwCreateWindow(createW, createH, config#title, MemoryUtil.NULL, MemoryUtil.NULL);
        GLFW.glfwMakeContextCurrent(window);
        // 隠しウィンドウでは垂直同期を待たない — 見えないウィンドウ・画面ロック中は swap 1 回が
        // 1 秒級に落ちることがあり、harness の実行時間と安定性を壊す。
        GLFW.glfwSwapInterval(if (hidden) 0 else 1);
        // Sticky mouse buttons: 1 フレーム未満の press→release（macOS の
        // トラックパッド「タップでクリック」など）が polling で取りこぼされる
        // のを防ぐ。次回 `glfwGetMouseButton` 呼び出し時に PRESS を 1 度返してから
        // RELEASE に落ちる。
        GLFW.glfwSetInputMode(window, GLFW.GLFW_STICKY_MOUSE_BUTTONS, GL11.GL_TRUE);
        discard GL.createCapabilities();

        let fbStack = MemoryStack.stackPush();
        let fbWidthBuf = fbStack.mallocInt(1);
        let fbHeightBuf = fbStack.mallocInt(1);
        GLFW.glfwGetFramebufferSize(window, fbWidthBuf, fbHeightBuf);
        let fbMeasuredW = fbWidthBuf.get(0);
        let fbMeasuredH = fbHeightBuf.get(0);
        discard MemoryStack.stackPop();
        println("Framebuffer size: ${fbMeasuredW}x${fbMeasuredH}");

        // 隠しウィンドウでは glfwGetFramebufferSize を信用せず fb 寸 = design 寸に固定する。
        // この開発機の実測では、隠しウィンドウの実 drawable はウィンドウのポイント寸のままなのに、
        // 問い合わせは Retina 倍を返して嘘をつく — 嘘の寸で描くと絵が 1/4 に潰れる。
        let (fbWidth, fbHeight) = if (hidden) (config#designWidth, config#designHeight)
                                  else (fbMeasuredW, fbMeasuredH);

        // fb == design の門番(隠しウィンドウモードのみ)。design の右上隅 1px に scissor で印を塗り、
        // 読み戻して実測で確かめる — 実 drawable が design 寸に届かない環境だと、絵の欠けが
        // 「全画素不一致」に化けて原因が突き合わせ経路の差に見えてしまうため、ここで落とす。
        if (hidden) {
            GL11.glViewport(0, 0, fbWidth, fbHeight);
            GL11.glClearColor(0.0f32, 0.0f32, 0.0f32, 1.0f32);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
            GL11.glEnable(GL11.GL_SCISSOR_TEST);
            GL11.glScissor(fbWidth - 1, fbHeight - 1, 1, 1);
            GL11.glClearColor(1.0f32, 0.0f32, 0.0f32, 1.0f32);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            let probe = MemoryUtil.memAlloc(4);
            GL11.glReadPixels(fbWidth - 1, fbHeight - 1, 1, 1,
                GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, probe);
            let probeR = Int32.bitwiseAnd(Int8.toInt32(probe.get(0)), 255);
            let probeG = Int32.bitwiseAnd(Int8.toInt32(probe.get(1)), 255);
            MemoryUtil.memFree(probe);
            if (probeR != 255 or probeG != 0) {
                println("[gl-parity] FAIL: drawable が design 寸 ${fbWidth}x${fbHeight} に"
                    + "届かない（右上隅の印 (255,0,0) が (${probeR},${probeG},…) で返った）— 突き合わせ不成立");
                System.exit(1)
            } else ()
        } else ();

        // フレームバッファサイズ。毎フレーム MemoryStack で問い合わせると呼び出しコストが積み上がるため、
        // 起動時に実測した値を持ち回り、変化はリサイズ callback だけが更新する。
        let framebufferSizeHolder = Array#{(fbWidth, fbHeight)} @ Static;

        GL11.glEnable(GL11.GL_BLEND);
        GL11.glBlendFunc(GL11.GL_SRC_ALPHA, GL11.GL_ONE_MINUS_SRC_ALPHA);

        // ウィンドウは既に出ているのに、ここまで一度も塗っていないと中身は未定義（白やゴミ）のまま。
        // シェーダの用意を待たずにまず一掃しておく。色はこの先のフレームと同じ物を使う —
        // 別の色で塗ると、起動画面の 1 枚目が出た瞬間に画面の色がパッと変わって見える。
        let clear = config#clearColor;
        GL11.glViewport(0, 0, fbWidth, fbHeight);
        GL11.glClearColor(RenderUtil.f32(clear#r), RenderUtil.f32(clear#g), RenderUtil.f32(clear#b), 1.0f32);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
        GLFW.glfwSwapBuffers(window);
        GLFW.glfwPollEvents();

        let screenW = Int32.toFloat64(config#designWidth);
        let screenH = Int32.toFloat64(config#designHeight);

        // GL リソース構築は各描画 mod（RenderShader 等）に委譲
        let spriteShader = RenderShader.createShaderProgram(
            RenderShader.vertexShaderSource(),
            RenderShader.fragmentShaderSource());
        RenderShader.setProjectionMatrix(spriteShader, screenW, screenH);

        let tileShader = RenderShader.createShaderProgram(
            RenderShader.tileVertexShaderSource(),
            RenderShader.tileFragmentShaderSource());
        RenderShader.setProjectionMatrix(tileShader, screenW, screenH);

        // 連続する同テクスチャのスプライトを 1 draw call にまとめる instanced 描画用。
        let instShader = RenderShader.createShaderProgram(
            RenderShader.spriteInstancedVertexShaderSource(),
            RenderShader.spriteInstancedFragmentShaderSource());
        RenderShader.setProjectionMatrix(instShader, screenW, screenH);

        // 連続する同 blend / 切り抜き clip 矩形の多角形を 1 draw call にまとめるバッチ描画用（頂点色）。
        let polyBatchShader = RenderShader.createShaderProgram(
            RenderShader.polyBatchVertexShaderSource(),
            RenderShader.polyBatchFragmentShaderSource());
        RenderShader.setProjectionMatrix(polyBatchShader, screenW, screenH);

        // location はリンク後に不変なので起動時に 1 回だけ引く（RenderShader.spriteUniformsOf 参照）。
        let spriteUniforms = RenderShader.spriteUniformsOf(spriteShader);
        let tileUniforms = RenderShader.tileUniformsOf(tileShader);
        let instMultiplyBlend = GL20.glGetUniformLocation(instShader, "multiplyBlend");
        let polyBatchUniforms = RenderShader.polyBatchUniformsOf(polyBatchShader);

        let (vao, quadVBO) = RenderSprite.initSpriteRenderer();
        let (polyBatchVao, polyBatchVbo) = RenderSprite.initPolygonBatchRenderer();
        let (instVao, instVbo) = RenderSprite.initSpriteInstancedRenderer(quadVBO);
        // 1 フレームぶんの instance / 頂点を書き溜める入れ物（毎フレーム作り直さず貸し出す）。
        // 初めの大きさは「よくある画面」の見当で、足りなければ描画側が広げる。
        let instBuf = RenderBuf.make(4096 * 38);
        let polyBuf = RenderBuf.make(16384 * 6);
        // タイル VAO → インスタンス VBO のレジストリ。updateTileBuffer（既存 VAO への
        // 入れ直し）が再アップロード先の VBO をここから引く。
        let tileVboRegistry: Ref[Map[Int32, Int32], Static] = Ref.fresh(Static, Map.empty());

        // 宣言シェーダー面（eff Shader）用: codegen が吐いた GLSL のコンパイル失敗時に
        // 差し替える単色フォールバックプログラム（起動時に 1 回だけ作る）。
        let fallbackShader = RenderShader.createShaderProgram(
            ShaderGen.vertexSource(), RenderShader.fallbackFragmentSource());
        RenderShader.setProjectionMatrix(fallbackShader, screenW, screenH);
        // Spec の name → (組んだときの Spec, コンパイル済みプログラム + uniform location)。
        // buildProgram は毎フレーム呼ばれ得るので、同じ Spec の再コンパイルをここで防ぐ。
        // 鍵を GLSL ソースにしない — 鍵を組むだけで毎フレーム GLSL 全文の組み立てを払う。
        // name だけで返さず、当たりでも eqSpec で中身を確かめる — 同名で中身が変わる
        // ホットリロード（shader.json の保存し直し）が絵に反映されなくなる。
        let shaderProgramCache: Ref[Map[String, (ShaderDoc.Spec, RenderShaderCache.ProgramEntry)], Static] = Ref.fresh(Static, Map.empty());
        // 描いたフレームの通し番号。ShaderGen.compile は Doc の数値を GLSL に書き込むので、
        // shader.json を保存し直すたびに別の鍵になる — LRU で古い方を追い出すために、
        // 「どの program をいつ使ったか」を数えるものさしが要る。
        let frameGenHolder = Array#{0i64} @ Static;
        // program 番号 → 最後に使った世代。鍵ではなく program 番号で持つのは、
        // コンパイルに失敗した Spec が全部同じ fallbackShader を値にして入るため。
        let programUsedAtRef: Ref[Map[Int32, Int64], Static] = Ref.fresh(Static, Map.empty());
        // このフレームに溜まったシェーダー面の描画依頼（drawSurface が積み、renderFrame が描いて空にする）。
        let pendingShaderHolder = Array#{(Nil: List[ShaderEffect.ShaderRenderCmd])} @ Static;
        // program ハンドル → (uRectPos, uRectSize, uTime, texLocs) の逆引き（drawSurface が
        // uniform 設定に使う）。texLocs = tex 場の (uTexN, uTexFlipN) の location 列（正典順）。
        let shaderUniformCache: Ref[Map[Int32, (Int32, Int32, Int32, List[(Int32, Int32)])], Static] = Ref.fresh(Static, Map.empty());
        // tex 場の標本規約（NEAREST + CLAMP）を bind 中の unit へ強制する sampler（起動時に 1 個）。
        let surfaceSampler = RenderSprite.createSurfaceSampler();
        // 見つからないと知らせた tex 場のテクスチャ名（missingFontRef と同じ「一度だけ鳴らす」控え）。
        let missingSurfaceTexRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());

        // レンダーターゲット（eff RenderTarget.Target の FBO）のレジストリ: 名前 → GL 実体。
        // ターゲットは初回の beginTarget で作られ、寸法が変わらない限り使い回す。
        let targetsRef: Ref[Map[String, RenderTargetGl.Entry], Static] = Ref.fresh(Static, Map.empty());
        // いま開いているターゲット (幅, 高さ, clear 指定)。renderCommands がこれを見て
        // 「画面へのフレーム」と「ターゲットへのフレーム」を切り替える。
        let activeTargetHolder = Array#{(None: Option[(Int32, Int32, RenderTarget.LoadOp)])} @ Static;

        // テクスチャ表は実行時に増える（ensureTexture が生成したアトラスを足す）ので可変で持つ。
        // 起動画面が読み込みの最中に絵を出すため、ゲームのテクスチャより先に作って
        // 組み込みフォントとロゴだけを入れておく。
        // 併せて「名前 → 最後に上げた key」を持ち、同じ key の再アップロードを弾く。
        let registryRef: Ref[RenderAsset.TextureRegistry, Static] = Ref.fresh(Static, Map.empty());
        let textureKeyRef: Ref[Map[String, String], Static] = Ref.fresh(Static, Map.empty());
        // 見つからないと知らせたフォント名。同じ名前で毎フレーム鳴らさないための控え。
        let missingFontRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());
        // 見つからないと知らせたテクスチャ名（renderFrameMixed へ毎フレーム貸す）。
        // フレームごとに作り直すと、同じ知らせが 60 回/秒 出てしまう。
        let missingTextureRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());

        // 静的多角形バッファのキャッシュ（キー → 生成した VBO とレンジ目次）。テクスチャ registry と
        // 同じくエンジン内部に隠し、ゲームは GameEngine.StaticLayerCmd のキーと中身を宣言するだけ。
        // キー一致で使い回し・不一致で古い VBO を free して作り直す（RenderStatic.resolve）。
        let staticCacheCell = Array#{(None: Option[RenderStatic.Entry])} @ Static;

        // リサイズ中の再描画用に最後のフレームの描画コマンドを保持する
        // (sprites + tileMaps + polygons + 静的レイヤー依頼 + シェーダー面)
        let renderStateHolder = Array#{((Nil: List[GameEngine.Drawable]),
                                         (Nil: List[GameEngine.TileMapRenderCmd]),
                                         (Nil: List[GameEngine.PolygonRenderCmd]),
                                         (None: Option[GameEngine.StaticLayerCmd]),
                                         (Nil: List[ShaderEffect.ShaderRenderCmd]))} @ Static;

        // シェーダー面 1 枚を GL へ描くクロージャ。program の uniform location を逆引きして差す。
        // z の合流（sprites/polygons/静的レンジとの重なり順）は renderFrameMixed が受け持つので、
        // ここは 1 枚の描画だけに徹する。
        // cmd#texNames と texLocs の長さ不一致は List.zip が短い方に合わせて黙って吸収する —
        // コンパイル失敗した複数 Spec が同じ fallback program を鍵に uniform cache を上書きし合い、
        // fallback では texLocs が空（または全 -1）になるため、names 2 本 × locs 0 本は正常系
        //（glUniform の location -1 も無視される）。
        let drawSurface = (cmd: ShaderEffect.ShaderRenderCmd) -> {
            let program = GpuHandle.shaderProgramInt(cmd#program);
            // buildProgram だけで使用を刻むと足りない — ShaderEffect の doc は
            // 「起動時/リロード時に 1 回 compile」と約束していて、その通りに 1 回だけ
            // compile してハンドルを持ち回るゲームの program が「未使用」に見えて
            // 追い出される。追い出された program は下の uniform 逆引きが
            // (-1,-1,-1,Nil) で握り潰すので、エラーも例外も出ず絵だけ違う形で壊れる。
            Ref.put(Map.insert(program, Array.get(0, frameGenHolder), Ref.get(programUsedAtRef)),
                    programUsedAtRef);
            let (uRectPos, uRectSize, uTime, texLocs) =
                Map.get(program, Ref.get(shaderUniformCache))
                |> Option.getWithDefault((-1, -1, -1, (Nil: List[(Int32, Int32)])));
            // 名前 → GL テクスチャ id。無い名前は 0（黒）を bind して一度だけ知らせる —
            // pass をこのフレームで宣言せず名前だけ読むと、ずっと 0 bind（黒）のままになる。
            // registry / targets はこの 1 枚の描画中は変わらないので、名前ごとに読み直さない。
            let registry = Ref.get(registryRef);
            let targets = Ref.get(targetsRef);
            let texBinds = List.zip(cmd#texNames, texLocs) |> List.zipWithIndex
                |> List.map(itb -> {
                    let (i, nameLocs) = itb;
                    let (name, locs) = nameLocs;
                    let (_samplerLoc, flipLoc) = locs;
                    let texId = match Map.get(name, registry) {
                        case Some(info) => GpuHandle.textureIdInt(info#id)
                        case None =>
                            let warned = Ref.get(missingSurfaceTexRef);
                            if (Set.memberOf(name, warned)) ()
                            else {
                                System.err.println("shader tex '${name}' が見つからない — 黒(0)を貼る"
                                    + "（pass ならこのフレームで宣言されているか確認）");
                                Ref.put(Set.insert(name, warned), missingSurfaceTexRef)
                            };
                            0
                    };
                    // pass ターゲットは上下逆格納なので flip=1（貼る側で吸収する既存規約と同型）。
                    let flip = if (Map.memberOf(name, targets)) 1.0 else 0.0;
                    ({ texUnit = i, texId = texId, flipLoc = flipLoc, flip = flip }: RenderSprite.SurfaceTexBind)
                });
            // mask が空なら矩形そのまま、非空なら多角形の内側だけにステンシルで抜く
            // （多角形描画は poly バッチ経路を借りる）。
            if (List.isEmpty(cmd#mask))
                RenderSprite.drawShaderSurface(program, vao, uRectPos, uRectSize, uTime,
                                               texBinds, surfaceSampler,
                                               cmd#rect, cmd#time, cmd#blend)
            else
                RenderSprite.drawShaderSurfaceMasked(program, vao, uRectPos, uRectSize, uTime,
                                               texBinds, surfaceSampler,
                                               cmd#rect, cmd#time, cmd#blend,
                                               polyBatchShader, polyBatchVao, polyBatchVbo,
                                               polyBatchUniforms, cmd#mask)
        };
        // 使わなくなったシェーダープログラムを LRU で追い出す。
        let evictShaderPrograms = () -> {
            let gen = Array.get(0, frameGenHolder);
            let usedAt = Ref.get(programUsedAtRef);
            let cache0 = Ref.get(shaderProgramCache);
            // 現世代が刻まれている program は必ず守る。Render.drawShaders は 1 フレームの
            // 全ての面の buildProgram を先に全部呼ぶので、pin しないと面の数が上限を
            // 超えたときに、いまから描く面の program を自分で捨ててしまう。
            let liveNow = Map.toList(usedAt)
                |> List.filterMap(pa -> { let (prog, at) = pa; if (at == gen) Some(prog) else None })
                |> List.toSet;
            // 上限は「生きている面の数」から決める。固定の数にすると、面を多く出すゲームで
            // 毎フレーム作っては捨てるだけになる（面の数はゲームが決めるのでエンジンは知らない）。
            let cap = Int32.max(16, Set.size(liveNow) * 2);
            let (_, _, _, _, lastSurfaces) = Array.get(0, renderStateHolder);
            let pinned = lastSurfaces
                |> List.foldLeft((acc, cmd: ShaderEffect.ShaderRenderCmd) ->
                    Set.insert(GpuHandle.shaderProgramInt(cmd#program), acc), liveNow)
                |> Set.insert(fallbackShader);
            let entries = Map.toList(cache0) |> List.map(ke -> {
                let (key, se) = ke;
                let (_, e) = se;
                (key, e#program, Map.get(e#program, usedAt) |> Option.getWithDefault(0i64))
            });
            let victims = RenderShaderCache.computeEvictions(
                { entries = entries, pinned = pinned, cap = cap });
            if (List.isEmpty(victims)) ()
            else {
                // 鍵ごとの「その番号を指す鍵がまだ何本あるか」。コンパイルに失敗した Spec は
                // 全部同じ fallback program を値にして入るので、鍵を抜いても番号が
                // 生きていることがある。数えずに毎回探し直すと鍵の数の二乗になる。
                let counts0 = Map.valuesOf(cache0) |> List.foldLeft((acc, se) -> {
                    let (_, e) = se;
                    Map.insert(e#program, 1 + Option.getWithDefault(0, Map.get(e#program, acc)), acc)
                }, Map.empty());
                let (_, deleted) = List.foldLeft((acc, key) -> {
                    let (counts, n) = acc;
                    match Map.get(key, cache0) {
                        case None     => (counts, n)
                        case Some(se) =>
                            let (_, e) = se;
                            let prog = e#program;
                            Ref.put(Map.remove(key, Ref.get(shaderProgramCache)), shaderProgramCache);
                            let left = Option.getWithDefault(0, Map.get(prog, counts)) - 1;
                            let counts1 = Map.insert(prog, left, counts);
                            // uniform を先に消してはいけない。番号がまだ別の鍵で生きていると、
                            // その面が drawSurface で (-1,-1,-1,Nil) に落ちて、エラーも出ないまま
                            // uniform の差さらない絵になる。
                            if (left > 0) (counts1, n)
                            else {
                                RenderShader.deleteProgram(prog);
                                Ref.put(Map.remove(prog, Ref.get(shaderUniformCache)), shaderUniformCache);
                                Ref.put(Map.remove(prog, Ref.get(programUsedAtRef)), programUsedAtRef);
                                (counts1, n + 1)
                            }
                    }
                }, (counts0, 0), victims);
                // 捨てた番号が bind されたままだと次の描画が未定義になる。毎フレームの経路では
                // ないので、実際に捨てたときだけ 1 回外す。
                if (deleted > 0) GL20.glUseProgram(0) else ();
                Log.warn("shader: プログラムキャッシュから ${List.length(victims)} 個追い出した"
                    + "（GPU から捨てた program ${deleted} 個・残り ${Map.size(Ref.get(shaderProgramCache))} 個 / 上限 ${cap}）")
            }
        };
        // renderFrameMixed への FrameArgs は固定値（シェーダ・VAO・buf・uniforms 等）が
        // 大半なので、共通ベースを 1 つ組み、呼び出し側は変わる所だけ上書きする。
        // registry / targetNames は毎フレーム育つ Ref から読むため、ベースの値は仮
        // （空）に置き、呼び出し時に必ず上書きする。
        let frameArgsBase: RenderFrame.FrameArgs = {
            spriteShader = spriteShader, tileShader = tileShader, vao = vao,
            registry = Map.empty(), clearColor = config#clearColor,
            designW = screenW, designH = screenH, fbW = 0, fbH = 0,
            sprites = Nil, tileMaps = Nil, polygons = Nil,
            staticRanges = Nil,
            polyBatchShader = polyBatchShader, polyBatchVao = polyBatchVao,
            polyBatchVbo = polyBatchVbo, polyBatchUniforms = polyBatchUniforms,
            instShader = instShader, instVao = instVao, instVbo = instVbo,
            instBuf = instBuf, polyBuf = polyBuf,
            spriteUniforms = spriteUniforms, tileUniforms = tileUniforms,
            instMultiplyBlend = instMultiplyBlend,
            surfaces = Nil, drawSurface = drawSurface,
            targetClear = None, targetNames = Set.empty(),
            texWarnLog = missingTextureRef
        };
        // 画面への 1 フレーム。静的レイヤーはここで resolve（キャッシュ照合・必要なら
        // 作り直し）し、レンジ列を FrameArgs に載せる。None なら Nil（従来と同じ経路）。
        let renderFrame = (fbW: Int32, fbH: Int32,
                            sprites: List[GameEngine.Drawable],
                            tileMaps: List[GameEngine.TileMapRenderCmd],
                            polygons: List[GameEngine.PolygonRenderCmd],
                            staticLayer: Option[GameEngine.StaticLayerCmd],
                            surfaces: List[ShaderEffect.ShaderRenderCmd]) -> {
            let staticRanges = match staticLayer {
                case None    => Nil
                case Some(l) => RenderStatic.resolve(staticCacheCell, l)
            };
            RenderFrame.renderFrameMixed({
                registry = Ref.get(registryRef),
                fbW = fbW, fbH = fbH,
                sprites = sprites, tileMaps = tileMaps, polygons = polygons,
                staticRanges = staticRanges,
                surfaces = surfaces,
                targetNames = Map.keysOf(Ref.get(targetsRef)) | frameArgsBase })
        };
        // レンダーターゲットへの 1 フレーム。画面用の renderFrame と違い、黒帯 clear を
        // せず（targetClear）、タイル層・静的レンジ・シェーダー面は乗らない（Pass の doc の
        // 決まり）。ターゲットは design と同寸なので投影行列はそのままでよい。
        let renderTargetFrame = (tw: Int32, th: Int32, op: RenderTarget.LoadOp,
                                  sprites: List[GameEngine.Drawable],
                                  polygons: List[GameEngine.PolygonRenderCmd]) -> {
            RenderFrame.renderFrameMixed({
                registry = Ref.get(registryRef),
                designW = Int32.toFloat64(tw), designH = Int32.toFloat64(th),
                fbW = tw, fbH = th,
                sprites = sprites, polygons = polygons,
                targetClear = Some(op),
                targetNames = Map.keysOf(Ref.get(targetsRef)) | frameArgsBase })
        };

        // macOS ではリサイズ中に glfwPollEvents がブロックされるため、
        // フレームバッファサイズ変更コールバックで再描画を行う。
        // **読み込みを始める前に付ける** — 読み込み中も起動画面が出ているぶんウィンドウを掴まれる。
        // 付いていないと、その間のサイズ変更が誰にも拾われず、読み込み後もずれたまま描き続ける。
        discard GLFW.glfwSetFramebufferSizeCallback(window, new GLFWFramebufferSizeCallbackI {
            def invoke(_this: GLFWFramebufferSizeCallbackI, cbWindow: Int64, width: Int32, height: Int32): Unit \ IO = {
                // 隠しウィンドウでは無視する — fb 寸は design 寸に固定済みで、この callback が
                // 万一発火すると（問い合わせ同様に嘘をつく）実測値で上書きされてしまう。
                if (hidden) ()
                else {
                    Array.put((width, height), 0, framebufferSizeHolder);
                    let (sprites, tileMaps, polygons, staticLayer, surfaces) = Array.get(0, renderStateHolder);
                    renderFrame(width, height, sprites, tileMaps, polygons, staticLayer, surfaces);
                    GLFW.glfwSwapBuffers(cbWindow)
                }
            }
        });

        // ===== 起動画面 =====
        // ここから下は読み込みで数秒〜十数秒止まる。ウィンドウは既に出ているので、何も描かないと
        // 固まったように見える。組み込みの絵だけで進み具合を出し続ける。
        Ref.put(RenderSplash.install(), registryRef);
        let splashState = RenderSplash.newState();
        let splashShotTaken = Array#{0} @ Static;
        let splashShotAt = Array#{0i64} @ Static;
        let frameShotTaken = Array#{0} @ Static;
        let splashDesign = { x = screenW, y = screenH };
        // 起動画面も renderStateHolder へ入れる。読み込み中にウィンドウの大きさを変えると
        // リサイズ callback が holder の中身で描き直すので、空だと真っ黒に落ちる。
        // macOS では画面を出すたびにイベントを汲まないとウィンドウが「応答なし」になる。
        let drawSplash = (ds: List[GameEngine.Drawable]) -> {
            Array.put((ds, Nil, Nil, None, Nil), 0, renderStateHolder);
            let (splashW, splashH) = Array.get(0, framebufferSizeHolder);
            renderFrame(splashW, splashH, ds, Nil, Nil, None, Nil);
            splashShot(splashW, splashH, splashShotTaken, splashShotAt);
            GLFW.glfwSwapBuffers(window);
            GLFW.glfwPollEvents()
        };
        let splash = (phase: String, done: Int32, total: Int32) ->
            RenderSplash.tick(splashState, drawSplash, splashDesign, phase, done, total);
        // 読み込み中は画面の垂直同期を待たない（1 枚 16ms の待ちが読み込みそのものを遅くする）。
        GLFW.glfwSwapInterval(0);
        RenderSplash.show(splashState, drawSplash, splashDesign, "starting up...", 0, 0);

        println("Loading textures...");
        let registry0 = RenderTexture.loadTextureRegistry(config#textureManifest,
            (done, total) -> splash("loading images...", done, total));

        // このゲームが出しうる字を先に集める（数十ミリ秒）。フォントが持つ字を全部用意すると
        // 日本語 1 本で数千〜2万字になり、起動が数十秒止まる。
        let wantedGlyphs = RenderFont.startupGlyphs(config#rootDir, config#glyphs);
        Option.forEach(cps -> println("[RenderFont] このゲームが出しうる字: ${Set.size(cps)} 字"),
                       wantedGlyphs);

        println("Baking font atlases...");
        // 文言はフォントごとに 1 回だけ組み立てる（進捗は字ごとに数千回来る）。
        let fontPhases: Ref[Map[String, String], Static] = Ref.fresh(Static, Map.empty());
        let fontPhaseOf = (name: String) -> match Map.get(name, Ref.get(fontPhases)) {
            case Some(text) => text
            case None =>
                let text = "loading font ${name}...";
                Ref.put(Map.insert(name, text, Ref.get(fontPhases)), fontPhases);
                text
        };
        let (gameAtlases, registry) = RenderFont.bakeFontAtlases(config#fontManifest, registry0,
            wantedGlyphs, (name, done, total) -> splash(fontPhaseOf(name), done, total));
        // 組み込みフォントも名前で引けるようにする（fps 表示・フォント名が合わないときの受け皿）。
        // アトラスは実行中に育つ（起動時に用意しなかった字を後から足す）ので可変で持つ。
        let fontAtlasesRef = Ref.fresh(Static,
            Map.insert(BootFont.name(), BootFont.atlas(), gameAtlases));
        let growTable = RenderGlyphGrow.newTable();
        List.forEach(entry -> {
            match Map.get(entry#name, gameAtlases) {
                case None =>
                    Log.warn("font: フォント '${entry#name}' のアトラスが用意できていない"
                        + " — 起動時に用意しなかった字は後から足せない（project.json の fonts の path を確認）")
                case Some(atlas) =>
                    match Map.get(atlas#textureName, registry) {
                        case None =>
                            Log.warn("font: フォント '${entry#name}' のアトラス画像"
                                + " '${atlas#textureName}' が registry に無い"
                                + " — 起動時に用意しなかった字は後から足せない")
                        case Some(texInfo) =>
                            RenderGlyphGrow.register(growTable, atlas,
                                { path = entry#path, texId = GpuHandle.textureIdInt(texInfo#id) })
                    }
            }
        }, config#fontManifest);
        // 起動画面の分（組み込みフォント・ロゴ）を残したままゲームのテクスチャを足す。
        Ref.put(Map.union(registry, Ref.get(registryRef)), registryRef);

        // 組み込みの放射テクスチャ（Render.lightAt / darkAt が引く）。ゲームの manifest には
        // 載らない名前なので、ここで足さないと「アセット配線をしたゲームだけ光が出る」に
        // なってしまう — どのゲームでも配線ゼロで使えるよう起動時に必ず上げる。
        let radialSide = RadialBuiltin.size();
        let radialLight = RenderTexture.loadTextureFromPixels(radialSide, radialSide,
            RadialBuiltin.lightPixels());
        let radialDark = RenderTexture.loadTextureFromPixels(radialSide, radialSide,
            RadialBuiltin.darkPixels());
        Ref.put(Ref.get(registryRef)
            |> Map.insert(RadialBuiltin.lightName(), radialLight)
            |> Map.insert(RadialBuiltin.darkName(), radialDark), registryRef);

        // ===== OpenAL audio init =====
        println("Initializing audio...");
        RenderSplash.show(splashState, drawSplash, splashDesign, "starting audio...", 0, 0);
        let alDevice = ALC10.nalcOpenDevice(MemoryUtil.NULL);
        if (alDevice == 0i64) {
            println("Failed to open OpenAL device");
            bug!("Failed to open OpenAL device")
        } else ();
        let alcCaps = ALC.createCapabilities(alDevice);
        let alContext = ALC10.nalcCreateContext(alDevice, MemoryUtil.NULL);
        if (alContext == 0i64) {
            println("Failed to create OpenAL context");
            bug!("Failed to create OpenAL context")
        } else ();
        if (not ALC10.alcMakeContextCurrent(alContext)) {
            println("Failed to make OpenAL context current");
            bug!("Failed to make OpenAL context current")
        } else ();
        discard AL.createCapabilities(alcCaps);

        println("  Loading sounds...");
        let audioRegistry = RenderAudio.loadAudioRegistry(config#soundManifest,
            (done, total) -> splash("loading sounds...", done, total));
        // 知らせた音の名前の控え（missingFontRef と同じ「名前ごとに一度だけ」）。
        // 何も知らせずに捨てると、名前の打ち間違いが「ずっと無音」としてしか現れない。
        // 毎フレーム呼ばれる口なので、名前が registry にある間は Set を一度も触らない。
        let missingSoundRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());
        let warnMissingSound = (op: String, name: String) -> {
            let warned = Ref.get(missingSoundRef);
            if (Set.memberOf(name, warned)) ()
            else {
                let _ = Log.warn("audio: 知らない音 '${name}' — ${op} は何もしない"
                    + "（project.json の sounds に同名の宣言があるか確認）");
                Ref.put(Set.insert(name, warned), missingSoundRef)
            }
        };
        // ローパス（setLowpass）は EFX の lowpass フィルタを音源ごとに 1 つ作って付ける。
        // EFX の無い環境では何もしない（音は素通しのまま）。フィルタは初めて削る音にだけ作る。
        let hasEfx = ALC10.alcIsExtensionPresent(alDevice, "ALC_EXT_EFX");
        let lowpassRef: Ref[Map[String, Int32], Static] = Ref.fresh(Static, Map.empty());
        // 最後に送った gainHF（音源ごと）。同じ値なら AL へ送り直さない（毎フレーム呼ばれる口なので）。
        let lastGainHFRef: Ref[Map[String, Float64], Static] = Ref.fresh(Static, Map.empty());
        // 注釈保存時のシャッター音（合成なのでゲーム側の音声マニフェストに依存しない）
        let shutterSource = buildShutterSource();
        println("  Audio ready");

        // 読み込みは済んだので画面の垂直同期を戻す。ここから先（ゲームの下ごしらえ）も
        // 起動画面は出続けるが、枚数が知れているので待ちは体感に出ない。
        // 隠しウィンドウでは戻さない（swap の 1 秒級の待ちを避ける理由が本編でも変わらないため）。
        GLFW.glfwSwapInterval(if (hidden) 0 else 1);

        // Windows だけ、毎フレームの受け渡し後に GPU の完了を待つ。ドライバが 2〜3 フレーム
        // 先まで絵を貯め込むことがあり、60fps のままでも入力から表示までがその分遅れて
        // 重く感じるため。vsync 待ちでどのみち止まる場所なので、待つ相手が変わるだけで
        // フレームレートは落ちない。他の OS には貯め込みの癖が無いので付けない。
        let finishAfterSwap = {
            let osName = System.getProperty("os.name");
            not Object.isNull(osName) and String.contains({substr = "Windows"}, osName)
        };

        let timeHolder = Array#{System.nanoTime()} @ Static;

        // フルスクリーンからウィンドウへ戻すとき、起動時のウィンドウ位置・サイズへ復元する
        // （フルスクリーン中に glfwSetWindowMonitor(NULL) で消える情報なので事前に確保しておく）。
        let originalWindowRectHolder = {
            let posStack = MemoryStack.stackPush();
            let xBuf = posStack.mallocInt(1);
            let yBuf = posStack.mallocInt(1);
            GLFW.glfwGetWindowPos(window, xBuf, yBuf);
            let x = xBuf.get(0);
            let y = yBuf.get(0);
            discard MemoryStack.stackPop();
            Array#{(x, y, config#windowWidth, config#windowHeight)} @ Static
        };
        let fullscreenHolder = Array#{false} @ Static;

        // 6 種のスタンダードカーソルを起動時に作成して再利用する。
        // setCursor 呼び出しの度に都度作成 / 破棄すると重く、リーク源にもなる
        let arrowCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.Default));
        let crosshairCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.Crosshair));
        let hResizeCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.HResize));
        let vResizeCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.VResize));
        let allResizeCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.AllResize));
        let rotateCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.Rotate));
        // 4 隅: GLFW では対角単位 (NWSE/NESW) しか無いので、NW+SE と NE+SW は同じ
        // ハンドルを共有する。AWT 側は方向別の 4 種を持っており、IDE では AWT 経路の方が
        // ホバー時に表示されるためここの集約は問題にならない。
        let nwseResizeCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.NWResize));
        let neswResizeCursor = GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(GameEngine.Cursor.NEResize));
        // 同じ Cursor を毎フレーム渡されたときに glfwSetCursor を抑制するためのキャッシュ
        let lastCursorHolder = Array#{(GameEngine.Cursor.Default: GameEngine.Cursor)} @ Static;
        let cursorOf = cursor -> match cursor {
            case GameEngine.Cursor.Default    => arrowCursor
            case GameEngine.Cursor.Crosshair  => crosshairCursor
            case GameEngine.Cursor.HResize    => hResizeCursor
            case GameEngine.Cursor.VResize    => vResizeCursor
            case GameEngine.Cursor.AllResize  => allResizeCursor
            case GameEngine.Cursor.Rotate     => rotateCursor
            case GameEngine.Cursor.NWResize   => nwseResizeCursor
            case GameEngine.Cursor.SEResize   => nwseResizeCursor
            case GameEngine.Cursor.NEResize   => neswResizeCursor
            case GameEngine.Cursor.SWResize   => neswResizeCursor
        };

        // マウスホイールの y 方向 delta を 1 フレームぶん蓄積する。
        // consumeScrollDelta ハンドラが値を読み出して 0 に戻す。
        let scrollDeltaHolder = Array#{0.0} @ Static;
        discard GLFW.glfwSetScrollCallback(window, new GLFWScrollCallbackI {
            def invoke(_this: GLFWScrollCallbackI, _w: Int64, _xoffset: Float64, yoffset: Float64): Unit \ IO = {
                let prev = Array.get(0, scrollDeltaHolder);
                Array.put(prev + yoffset, 0, scrollDeltaHolder)
            }
        });

        // マウスボタンの「PRESS が来た」フラグを 1 フレームぶん保持する。
        // [0]=Left, [1]=Right, [2]=Middle. `shouldClose` が glfwPollEvents の **直前**
        // にリセットし、polling 中に来た callback が立てる。
        let mouseButtonPressedHolder = Array#{false, false, false} @ Static;
        discard GLFW.glfwSetMouseButtonCallback(window, new GLFWMouseButtonCallbackI {
            def invoke(_this: GLFWMouseButtonCallbackI, _w: Int64,
                        button: Int32, action: Int32, _mods: Int32): Unit \ IO = {
                // GLFW_PRESS = 1。0..2 範囲外は無視。
                if (action == 1 and button >= 0 and button <= 2)
                    Array.put(true, button, mouseButtonPressedHolder)
                else ()
            }
        });

        // ===== Gamepad (Xbox レイアウト) =====
        // GLFW gamepad API でコントローラ入力を読み、isKeyPressed に OR する。
        // これにより Key を参照する全 Scene を無改修でコントローラ対応にできる
        // (currentKeys() も isKeyPressed 経由なので onKeyPressed のエッジ検出も反映される)。
        // GLFWGamepadState.create() は GC 管理のダイレクトバッファ上に確保されるため明示解放は不要。
        // 状態は shouldClose で 1 フレーム 1 回更新し、padPressed が読み出す。
        let gamepadState = GLFWGamepadState.create();
        let gamepadConnectedHolder = Array#{false} @ Static;
        let padBtn = (idx: Int32) -> gamepadState.buttons(idx) != 0i8;
        let padAxis = (idx: Int32) -> gamepadState.axes(idx);
        // 方向は D-pad と左スティック（デッドゾーン 0.5）の両方で受ける。
        // GLFW のスティック Y 軸は上が負。
        let padUp    = () -> padBtn(GLFW.GLFW_GAMEPAD_BUTTON_DPAD_UP)    or (padAxis(GLFW.GLFW_GAMEPAD_AXIS_LEFT_Y) < -0.5f32);
        let padDown  = () -> padBtn(GLFW.GLFW_GAMEPAD_BUTTON_DPAD_DOWN)  or (padAxis(GLFW.GLFW_GAMEPAD_AXIS_LEFT_Y) >  0.5f32);
        let padLeft  = () -> padBtn(GLFW.GLFW_GAMEPAD_BUTTON_DPAD_LEFT)  or (padAxis(GLFW.GLFW_GAMEPAD_AXIS_LEFT_X) < -0.5f32);
        let padRight = () -> padBtn(GLFW.GLFW_GAMEPAD_BUTTON_DPAD_RIGHT) or (padAxis(GLFW.GLFW_GAMEPAD_AXIS_LEFT_X) >  0.5f32);
        // 物理キー → ゲームパッド入力の対応。**1 ボタン = 1 キー**を厳守する。
        // 1 ボタンを複数キーに割り当てると、その 1 押しで複数キーが同フレームに「新規押下」
        // 扱いになり onKeyPressed が複数回発火する。例えば A→Z/Space/Enter にすると Confirm が
        // 3 連発し、メニューを開いた直後に確定して行動を消費してしまう
        // (キーボードは 1 キー 1 入力なのでこの問題は出ない)。
        // 例: 決定=Z=A / メニュー確定=Enter=Start / キャンセル=X=B /
        // ミニマップ=M=Y / 危険範囲トグル=LeftShift=LB。
        // Escape はマップ上でゲーム終了を誘発するためパッドには **割り当てない**。
        // キャンセル / メニュー戻りは X=B で十分 (dispatchMenuKey が X→Cancel を全サブメニューで処理)。
        // 方向は arrows のみ (CursorScene は W/A/S/D と Up/Down/Left/Right の両対応なので arrows で足りる)。
        let padPressed = (key: GameEngine.Key) ->
            if (not Array.get(0, gamepadConnectedHolder)) false
            else match key {
                case GameEngine.Key.Up        => padUp()
                case GameEngine.Key.Down      => padDown()
                case GameEngine.Key.Left      => padLeft()
                case GameEngine.Key.Right     => padRight()
                case GameEngine.Key.Z         => padBtn(GLFW.GLFW_GAMEPAD_BUTTON_A)
                case GameEngine.Key.X         => padBtn(GLFW.GLFW_GAMEPAD_BUTTON_B)
                case GameEngine.Key.Enter     => padBtn(GLFW.GLFW_GAMEPAD_BUTTON_START)
                // Y = 集合ショートカット(Key.C)、ミニマップ(Key.M)は X ボタンへ移動。
                case GameEngine.Key.C         => padBtn(GLFW.GLFW_GAMEPAD_BUTTON_Y)
                case GameEngine.Key.M         => padBtn(GLFW.GLFW_GAMEPAD_BUTTON_X)
                case GameEngine.Key.LeftShift => padBtn(GLFW.GLFW_GAMEPAD_BUTTON_LEFT_BUMPER)
                case _                        => false
            };

        let result = run {
            f()
        } with handler GameEngine.Audio {
            def playAudio(name, k) = {
                match Map.get(name, audioRegistry) {
                    case Some(src) => AL10.alSourceStop(src); AL10.alSourcePlay(src)
                    case None      => warnMissingSound("playAudio", name)
                };
                k(())
            }
            def stopAudio(name, k) = {
                match Map.get(name, audioRegistry) {
                    case Some(src) => AL10.alSourceStop(src)
                    case None      => warnMissingSound("stopAudio", name)
                };
                k(())
            }
            def setVolume(name, volume, k) = {
                match Map.get(name, audioRegistry) {
                    case Some(src) => AL10.alSourcef(src, AL10.AL_GAIN, RenderUtil.f32(volume))
                    case None      => warnMissingSound("setVolume", name)
                };
                k(())
            }
            def setPitch(name, pitch, k) = {
                match Map.get(name, audioRegistry) {
                    // 0 以下は OpenAL がエラーにして音が止まるので、聞こえる下限で止める。
                    case Some(src) => AL10.alSourcef(src, AL10.AL_PITCH, RenderUtil.f32(Float64.max(0.01, pitch)))
                    case None      => warnMissingSound("setPitch", name)
                };
                k(())
            }
            def setLooping(name, loop, k) = {
                match Map.get(name, audioRegistry) {
                    case Some(src) =>
                        let v = if (loop) AL10.AL_TRUE else AL10.AL_FALSE;
                        AL10.alSourcei(src, AL10.AL_LOOPING, v)
                    case None      => warnMissingSound("setLooping", name)
                };
                k(())
            }
            def setMasterVolume(gain, k) = {
                // listener gain は全ソースに乗算で効く = マスター音量。範囲外は契約どおりクランプ。
                AL10.alListenerf(AL10.AL_GAIN, RenderUtil.f32(Float64.max(0.0, Float64.min(1.0, gain))));
                k(())
            }
            def setLowpass(name, gainHF, k) = {
                let g = Float64.max(0.0, Float64.min(1.0, gainHF));
                let unchanged = Map.get(name, Ref.get(lastGainHFRef)) == Some(g);
                match Map.get(name, audioRegistry) {
                    case Some(_) if hasEfx and unchanged => ()
                    case Some(src) if hasEfx =>
                        Ref.put(Map.insert(name, g, Ref.get(lastGainHFRef)), lastGainHFRef);
                        let made = Map.get(name, Ref.get(lowpassRef));
                        if (g >= 0.999) {
                            // 素通しへ戻すときはフィルタを外す（削らない音は OpenAL の素の道を通す）。
                            if (Option.isEmpty(made)) () else AL10.alSourcei(src, EXTEfx.AL_DIRECT_FILTER, EXTEfx.AL_FILTER_NULL)
                        } else {
                            let filter = match made {
                                case Some(existing) => existing
                                case None    =>
                                    let fresh = EXTEfx.alGenFilters();
                                    EXTEfx.alFilteri(fresh, EXTEfx.AL_FILTER_TYPE, EXTEfx.AL_FILTER_LOWPASS);
                                    Ref.put(Map.insert(name, fresh, Ref.get(lowpassRef)), lowpassRef);
                                    fresh
                            };
                            EXTEfx.alFilterf(filter, EXTEfx.AL_LOWPASS_GAINHF, RenderUtil.f32(g));
                            // 音源はフィルタの値を写し取るので、値を変えるたびに付け直す。
                            AL10.alSourcei(src, EXTEfx.AL_DIRECT_FILTER, filter)
                        }
                    case Some(_) => ()
                    case None    => warnMissingSound("setLowpass", name)
                };
                k(())
            }
            def audioSeconds(name, k) = {
                let seconds = match Map.get(name, audioRegistry) {
                    case Some(src) =>
                        let buffer = AL10.alGetSourcei(src, AL10.AL_BUFFER);
                        // バッファが外れている音源（0）には問い合わせない（AL のエラーになる）。
                        if (buffer == 0) 0.0
                        else {
                            let size = AL10.alGetBufferi(buffer, AL10.AL_SIZE);
                            let bytesPerFrame = AL10.alGetBufferi(buffer, AL10.AL_CHANNELS) * AL10.alGetBufferi(buffer, AL10.AL_BITS) / 8;
                            let freq = AL10.alGetBufferi(buffer, AL10.AL_FREQUENCY);
                            if (bytesPerFrame <= 0 or freq <= 0) 0.0
                            else Int32.toFloat64(size / bytesPerFrame) / Int32.toFloat64(freq)
                        }
                    case None => 0.0
                };
                k(seconds)
            }
            def reloadAudio(name, path, k) = {
                // 音源（ソース）は作り直さず、載っているバッファだけ差し替える —
                // ソース ID が変わらないので、registry も音量・ループの設定もそのまま生きる。
                match Map.get(name, audioRegistry) {
                    case None      =>
                        println("[reloadAudio] 知らない音 '${name}' — 読み直さない")
                    case Some(src) =>
                        if (not (new File(path)).exists()) {
                            println("[reloadAudio] ${path} が無い — 鳴っている音をそのまま残す")
                        } else {
                            let old = AL10.alGetSourcei(src, AL10.AL_BUFFER);
                            AL10.alSourceStop(src);
                            // 差し替え前に外す（載せたままのバッファは削除できない）。
                            AL10.alSourcei(src, AL10.AL_BUFFER, 0);
                            let buffer = RenderAudio.loadBuffer(path);
                            AL10.alSourcei(src, AL10.AL_BUFFER, buffer);
                            if (old != 0) AL10.alDeleteBuffers(old) else ()
                        }
                };
                k(())
            }
        } with handler GameEngine.Game {
            def renderCommands(sprites, tileMaps, polygons, staticLayer, k) = {
                match Array.get(0, activeTargetHolder) {
                    case Some((tw, th, op)) =>
                        // ターゲットが開いている間の描画は画面でなくそこに着く。swap も
                        // renderStateHolder（リサイズ再描画の控え）も触らない —
                        // 画面のフレームは同じ絵のフレームの末尾に必ず別で来る。
                        renderTargetFrame(tw, th, op, sprites, polygons);
                        k(())
                    case None =>
                        // drawSurface が積んだこのフレームのシェーダー面を取り出して holder を空にする。
                        // 順序は積んだ順（drawShaders の列順）に戻す。z の合流は renderFrameMixed が行う。
                        let surfaces = List.reverse(Array.get(0, pendingShaderHolder));
                        Array.put(Nil, 0, pendingShaderHolder);
                        Array.put((sprites, tileMaps, polygons, staticLayer, surfaces), 0, renderStateHolder);
                        // 進めるのはここ 1 箇所だけ。上のレンダーターゲットへの分岐でも進めると、
                        // Pass を N 枚描くゲームでは絵 1 枚あたり N+1 回進み、「現世代 = いま描いて
                        // いる面」という数え方が壊れる。
                        Array.put(Array.get(0, frameGenHolder) + 1i64, 0, frameGenHolder);
                        let (fbW, fbH) = Array.get(0, framebufferSizeHolder);
                        renderFrame(fbW, fbH, sprites, tileMaps, polygons, staticLayer, surfaces);
                        frameShot(fbW, fbH, frameShotTaken);
                        GLFW.glfwSwapBuffers(window);
                        if (finishAfterSwap) GL11.glFinish() else ();
                        k(())
                }
            }
            def initTileBuffer(instances, k) = {
                let instanceVBO = RenderSprite.buildTileInstanceVBO(instances);
                let tileVao = RenderSprite.buildTileMapVAO(quadVBO, instanceVBO);
                Ref.put(Map.insert(tileVao, instanceVBO, Ref.get(tileVboRegistry)), tileVboRegistry);
                k((GpuHandle.wrapTileVao(tileVao), List.length(instances)))
            }
            def updateTileBuffer(vaoId, instances, k) = {
                let tileVao = GpuHandle.tileVaoInt(vaoId);
                match Map.get(tileVao, Ref.get(tileVboRegistry)) {
                    case Some(vbo) => {
                        RenderSprite.uploadTileInstances(vbo, instances);
                        k((vaoId, List.length(instances)))
                    }
                    case None => {
                        // レジストリに無い VAO（理論上来ない）: 新規に作って返す。
                        let instanceVBO = RenderSprite.buildTileInstanceVBO(instances);
                        let fresh = RenderSprite.buildTileMapVAO(quadVBO, instanceVBO);
                        Ref.put(Map.insert(fresh, instanceVBO, Ref.get(tileVboRegistry)), tileVboRegistry);
                        k((GpuHandle.wrapTileVao(fresh), List.length(instances)))
                    }
                }
            }
            def shouldClose(k) = {
                // glfwPollEvents の **直前** に PRESS フラグをリセット。
                // poll 中に発火した callback が立てたフラグが、その後の
                // `isMouseButtonPressed` 経路で 1 フレーム間だけ true として読まれ、
                // 次フレーム冒頭でクリアされる。
                Array.put(false, 0, mouseButtonPressedHolder);
                Array.put(false, 1, mouseButtonPressedHolder);
                Array.put(false, 2, mouseButtonPressedHolder);
                GLFW.glfwPollEvents();
                // ゲームパッド状態を 1 フレーム 1 回更新（接続かつ gamepad マッピング有効時のみ）。
                let padConnected = GLFW.glfwJoystickIsGamepad(GLFW.GLFW_JOYSTICK_1);
                if (padConnected) discard GLFW.glfwGetGamepadState(GLFW.GLFW_JOYSTICK_1, gamepadState) else ();
                Array.put(padConnected, 0, gamepadConnectedHolder);
                k(GLFW.glfwWindowShouldClose(window))
            }
            def getDeltaTime(k) = {
                let currentTime = System.nanoTime();
                let prev = Array.get(0, timeHolder);
                Array.put(currentTime, 0, timeHolder);
                let dtNanos = currentTime - prev;
                let dtSec = Int64.toFloat64(dtNanos) / 1000000000.0;
                let clamped = Float64.min(dtSec, config#maxDeltaTime);
                k(clamped |> Duration.seconds)
            }
            def isKeyPressed(key, k) = {
                let code = keyToGlfw(key);
                let kb = GLFW.glfwGetKey(window, code) == 1;
                // キーボード OR ゲームパッド。エッジ検出は Scene 側 (prevKeyState) が行うため
                // ここでは押下状態を返すだけでよい。
                k(kb or padPressed(key))
            }
            def getMousePosition(k) = {
                let mStack = MemoryStack.stackPush();
                let xBuf = mStack.mallocDouble(1);
                let yBuf = mStack.mallocDouble(1);
                GLFW.glfwGetCursorPos(window, xBuf, yBuf);
                let cursorX = xBuf.get(0);
                let cursorY = yBuf.get(0);
                discard MemoryStack.stackPop();
                // ウィンドウサイズからデザイン座標に変換
                let wStack = MemoryStack.stackPush();
                let winW = wStack.mallocInt(1);
                let winH = wStack.mallocInt(1);
                GLFW.glfwGetWindowSize(window, winW, winH);
                let windowW = Int32.toFloat64(winW.get(0));
                let windowH = Int32.toFloat64(winH.get(0));
                discard MemoryStack.stackPop();
                let designX = cursorX / windowW * screenW;
                let designY = cursorY / windowH * screenH;
                k({x = designX, y = designY})
            }
            def isMouseButtonPressed(button, k) = {
                let code = mouseButtonToGlfw(button);
                // 物理状態 OR 当フレーム内に callback が観測した PRESS。
                let polled = GLFW.glfwGetMouseButton(window, code) == 1;
                let buffered = Array.get(code, mouseButtonPressedHolder);
                k(polled or buffered)
            }
            def consumeScrollDelta(k) = {
                let v = Array.get(0, scrollDeltaHolder);
                Array.put(0.0, 0, scrollDeltaHolder);
                k(v)
            }
            def ensureGlyphs(textureName, codepoints, k) = {
                // 起動時に用意しなかった字を出そうとした。いま作って足す（無ければ何も起きない）。
                let atlases = Ref.get(fontAtlasesRef);
                let hit = atlases |> Map.findLeft((_n, a) -> a#textureName == textureName);
                match hit {
                    case None         => k(())
                    case Some((n, a)) =>
                        let grown = RenderGlyphGrow.ensure(growTable, a, codepoints);
                        Ref.put(Map.insert(n, grown, atlases), fontAtlasesRef);
                        k(())
                }
            }
            def getFontAtlas(name, k) = {
                match Map.get(name, Ref.get(fontAtlasesRef)) {
                    case Some(atlas) => k(atlas)
                    // 名前が合わないだけでゲームが落ちるより、組み込みフォントで出す方がまし。
                    // ただし黙って既定へ落ちると打ち間違いに気付けないので、名前ごとに 1 度だけ知らせる。
                    case None =>
                        let warned = Ref.get(missingFontRef);
                        if (not Set.memberOf(name, warned)) {
                            println("[engine] フォント '${name}' は project.json にありません"
                                + "（組み込みフォントで代用します）");
                            Ref.put(Set.insert(name, warned), missingFontRef)
                        } else ();
                        k(BootFont.atlas())
                }
            }
            def getViewportRect(k) = {
                k({position = Vec2.zero(), size = {x = screenW, y = screenH}})
            }
            def getTextureInfo(name, k) = {
                k(Map.get(name, Ref.get(registryRef)))
            }
            def ensureTexture(name, key, width, height, argb, k) = {
                // key が前と同じなら何もしない（毎フレーム呼ばれる前提の関数）。
                if (Map.get(name, Ref.get(textureKeyRef)) == Some(key)) k(())
                else {
                    let prev = Map.get(name, Ref.get(registryRef));
                    let sameSize = Option.exists(info ->
                        info#width == Int32.toFloat64(width)
                            and info#height == Int32.toFloat64(height), prev);
                    // 辺長が同じなら画素だけ差し替える（GL ハンドルを作り直さない）。
                    // 名前の取り違え避け: マニフェストで読んだ絵と同じ名前だと、辺長が同じ
                    // ときに元の絵の中身を上書きしてしまう。key を持たない名前 = 生成した
                    // アトラスではないので、そこへは書かない。
                    let taken = not Option.isEmpty(prev)
                        and Option.isEmpty(Map.get(name, Ref.get(textureKeyRef)));
                    if (taken) {
                        println("[ensureTexture] 名前 '${name}' はすでに別の絵が使っています（上書きしません）");
                        k(())
                    } else {
                    let info = match prev {
                        case Some(old) =>
                            if (sameSize) {
                                RenderTexture.updateTexturePixels(old, width, height, argb);
                                old
                            } else {
                                // 辺長が変わったので作り直す。古い方は捨てる（漏らすと作り直す
                                // たびに GPU のメモリが増え続ける）。
                                RenderTexture.deleteTexture(old);
                                RenderTexture.loadTextureFromPixels(width, height, argb)
                            }
                        case None => RenderTexture.loadTextureFromPixels(width, height, argb)
                    };
                    Ref.put(Map.insert(name, info, Ref.get(registryRef)), registryRef);
                    Ref.put(Map.insert(name, key, Ref.get(textureKeyRef)), textureKeyRef);
                    k(())
                    }
                }
            }
            def setCursor(cursor, k) = {
                let prev = Array.get(0, lastCursorHolder);
                if (prev != cursor) {
                    GLFW.glfwSetCursor(window, cursorOf(cursor));
                    Array.put(cursor, 0, lastCursorHolder)
                } else ();
                k(())
            }
            def setCursorVisible(visible, k) = {
                let mode = if (visible) GLFW.GLFW_CURSOR_NORMAL else GLFW.GLFW_CURSOR_HIDDEN;
                GLFW.glfwSetInputMode(window, GLFW.GLFW_CURSOR, mode);
                k(())
            }
            def setFullscreen(on, k) = {
                let wasFullscreen = Array.get(0, fullscreenHolder);
                if (on == wasFullscreen) ()
                else if (on) {
                    // 現在のウィンドウ位置・サイズを復元用に確保してから、プライマリモニタの
                    // 現在の解像度でボーダーレス化する（解像度そのものは変えないので、
                    // 既存の letterbox/pillarbox な calcViewport がそのまま吸収できる）。
                    let posStack = MemoryStack.stackPush();
                    let xBuf = posStack.mallocInt(1);
                    let yBuf = posStack.mallocInt(1);
                    GLFW.glfwGetWindowPos(window, xBuf, yBuf);
                    let sizeStack = MemoryStack.stackPush();
                    let wBuf = sizeStack.mallocInt(1);
                    let hBuf = sizeStack.mallocInt(1);
                    GLFW.glfwGetWindowSize(window, wBuf, hBuf);
                    Array.put((xBuf.get(0), yBuf.get(0), wBuf.get(0), hBuf.get(0)), 0, originalWindowRectHolder);
                    discard MemoryStack.stackPop();
                    discard MemoryStack.stackPop();
                    // glfwSetWindowMonitor はモード切替のたびに glfwSetFramebufferSizeCallback を
                    // 発火させる（GLFW の仕様）ので、framebufferSizeHolder は既存の callback が
                    // 自然に拾って更新する。calcViewport はここを明示的に叩き直す必要はない。
                    let monitor = GLFW.glfwGetPrimaryMonitor();
                    let vidMode = GLFW.glfwGetVideoMode(monitor);
                    GLFW.glfwSetWindowMonitor(window, monitor, 0, 0,
                        vidMode.width(), vidMode.height(), vidMode.refreshRate())
                } else {
                    // 保存値を検証してから戻す — 壊れた保存値でウィンドウが見えない場所に
                    // 行くと、ユーザーはフルスクリーンから二度と戻れなくなる。
                    let (x, y, w, h) = Array.get(0, originalWindowRectHolder);
                    let width = if (w < 1) config#windowWidth else w;
                    let height = if (h < 1) config#windowHeight else h;
                    let monitor = GLFW.glfwGetPrimaryMonitor();
                    let vidMode = GLFW.glfwGetVideoMode(monitor);
                    let clampedX = Int32.max(0, Int32.min(x, Int32.max(0, vidMode.width() - width)));
                    let clampedY = Int32.max(0, Int32.min(y, Int32.max(0, vidMode.height() - height)));
                    GLFW.glfwSetWindowMonitor(window, MemoryUtil.NULL, clampedX, clampedY,
                        width, height, GLFW.GLFW_DONT_CARE)
                };
                Array.put(on, 0, fullscreenHolder);
                k(())
            }
            def isFullscreen(k) = {
                k(Array.get(0, fullscreenHolder))
            }
            def saveAnnotation(req, k) = {
                let saved = try {
                    let now = LocalDateTime.now();
                    let dirStamp = now.format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss"));
                    let readableStamp = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));
                    let dirPath = "debug/annotations/${dirStamp}_${sanitizeName(config#title)}_f${req#frame}";
                    discard (new File(dirPath)).mkdirs();
                    // 等倍のフレームを back buffer に描き直して読む。swap しないので画面には
                    // 映らず、次のフレーム描画がそのまま上書きする。
                    let stack = MemoryStack.stackPush();
                    let wBuf = stack.mallocInt(1);
                    let hBuf = stack.mallocInt(1);
                    GLFW.glfwGetFramebufferSize(window, wBuf, hBuf);
                    let fbW = wBuf.get(0);
                    let fbH = hBuf.get(0);
                    discard MemoryStack.stackPop();
                    // 注釈のスクリーンショットにも静的レイヤーを含める（壁が消えないように）。
                    // AnnotationRequest は静的レイヤーを運ばないので、直近フレームの依頼を使う
                    // （キャッシュ済みなので作り直しは起きない）。シェーダー面は本物を使わず、
                    // req#sprites に含まれる代表色ベタ塗り（App が Render.draw で出す・スクラブ中の
                    // 表示中の瞬間に一致）を使う。live の面を混ぜると巻き戻し位置とズレるため空で渡す。
                    let (_, _, _, lastStatic, _) = Array.get(0, renderStateHolder);
                    renderFrame(fbW, fbH, req#sprites, req#tileMaps, req#polygons, lastStatic, Nil);
                    let image = framebufferImage(fbW, fbH);
                    writePngFile(image, "${dirPath}/screenshot.png");
                    burnHighlight(image, designRectToImage(req#rect, fbW, fbH, screenW, screenH));
                    writePngFile(image, "${dirPath}/highlighted.png");
                    writeTextFile("${dirPath}/annotation.json", req#json);
                    if (req#worldDump != "")
                        writeTextFile("${dirPath}/world.json", req#worldDump)
                    else ();
                    writeTextFile("${dirPath}/README.md",
                        readmeText({title = config#title, stamp = readableStamp,
                                    frame = req#frame, body = req#readmeBody}));
                    println("annotation saved: ${dirPath}");
                    AL10.alSourceStop(shutterSource);
                    AL10.alSourcePlay(shutterSource);
                    Some(dirPath)
                } catch {
                    case ex: Exception =>
                        println("annotation save failed: ${ex.getMessage()}");
                        None
                };
                k(saved)
            }
            def setDebugBadge(enabled, k) = {
                let title = if (enabled) "${config#title} (Debug)" else config#title;
                GLFW.glfwSetWindowTitle(window, title);
                k(())
            }
        } with handler ShaderEffect.Shader {
            def buildProgram(spec, k) = {
                // name で引き、当たりは eqSpec（Spec の構造比較）で確かめてから返す —
                // 当たったフレームでは ShaderGen.compile（GLSL 全文の組み立て）を呼ばない。
                // eqSpec が偽（同名で中身が違う = ホットリロード）なら作り直して差し替える。
                // コンパイル/リンク失敗時は単色フォールバックプログラムに落ちる（黒画面でなく色は出る）。
                let cache0 = Ref.get(shaderProgramCache);
                let gen = Array.get(0, frameGenHolder);
                let hit = match Map.get(spec#name, cache0) {
                    case Some((stored, found)) =>
                        if (ShaderGen.eqSpec(stored, spec)) Some(found) else None
                    case None => None
                };
                let entry = match hit {
                    case Some(found) => found
                    case None =>
                        let source = ShaderGen.compile(spec);
                        let prog = match RenderShader.tryCreateProgram(
                                ShaderGen.vertexSource(), source, "surface:${spec#name}") {
                            case Some(p) => RenderShader.setProjectionMatrix(p, screenW, screenH); p
                            case None    => fallbackShader
                        };
                        let up = GL20.glGetUniformLocation(prog, "uRectPos");
                        let us = GL20.glGetUniformLocation(prog, "uRectSize");
                        let ut = GL20.glGetUniformLocation(prog, "uTime");
                        // tex 場の sampler / flip の location（正典順）。sampler 番号 = unit 番号を
                        // リンク直後に 1 回だけ差す（毎フレーム差し直さない）。fallback に落ちた
                        // program では全て -1 になり、glUniform が無視するのでそのまま通す。
                        let texLocs = ShaderDoc.texNames(spec) |> List.zipWithIndex
                            |> List.map(iname -> {
                                let (i, _) = iname;
                                (GL20.glGetUniformLocation(prog, "uTex${i}"),
                                 GL20.glGetUniformLocation(prog, "uTexFlip${i}"))
                            });
                        if (List.isEmpty(texLocs)) ()
                        else {
                            GL20.glUseProgram(prog);
                            List.forEachWithIndex((i, locs) -> {
                                let (samplerLoc, _) = locs;
                                GL20.glUniform1i(samplerLoc, i)
                            }, texLocs)
                        };
                        let fresh: RenderShaderCache.ProgramEntry =
                            { program = prog, uRectPos = up, uRectSize = us, uTime = ut };
                        Ref.put(Map.insert(spec#name, (spec, fresh), cache0), shaderProgramCache);
                        Ref.put(Map.insert(prog, (up, us, ut, texLocs), Ref.get(shaderUniformCache)), shaderUniformCache);
                        fresh
                };
                Ref.put(Map.insert(entry#program, gen, Ref.get(programUsedAtRef)), programUsedAtRef);
                // 追い出しは新しく作ったときだけ。キャッシュに当たったフレームでは鍵が増えて
                // いないので、走らせても捨てる物が出ない。
                if (Option.isEmpty(hit)) evictShaderPrograms() else ();
                k(GpuHandle.wrapShaderProgram(entry#program))
            }
            def drawSurface(cmd, k) = {
                // 実描画はこのフレームの clear 直後（renderFrameMixed 内）で行う。ここでは溜めるだけ。
                Array.put(cmd :: Array.get(0, pendingShaderHolder), 0, pendingShaderHolder);
                k(())
            }
        } with handler RenderTarget.Target {
            def beginTarget(name, w, h, clearOp, k) = {
                // レジストリから引く。無い・寸法が変わったら作り直す（古い方は必ず捨てる）。
                let freshEntry = () -> {
                    let fresh = RenderTargetGl.create(w, h);
                    Ref.put(Map.insert(name, fresh, Ref.get(targetsRef)), targetsRef);
                    fresh
                };
                let entry = match Map.get(name, Ref.get(targetsRef)) {
                    case Some(e) =>
                        if (e#width == w and e#height == h) e
                        else { RenderTargetGl.destroy(e); freshEntry() }
                    case None => freshEntry()
                };
                // ターゲットのテクスチャを registry へ登録する（同じ Entry なら同じ値の
                // 上書きで無害）。以降 Render.sprite(name, z) が普通のスプライトとして引ける。
                Ref.put(Map.insert(name,
                            ({ id = GpuHandle.wrapTextureId(entry#tex),
                               width = Int32.toFloat64(w), height = Int32.toFloat64(h) }: RenderAsset.TextureInfo),
                            Ref.get(registryRef)), registryRef);
                RenderTargetGl.bind(entry);
                // clear は renderCommands（renderFrameMixed の targetClear）が行う — GL の
                // clear 手順を 1 箇所に保つため、ここでは開いた印を残すだけ。
                Array.put(Some((w, h, clearOp)), 0, activeTargetHolder);
                k(())
            }
            def endTarget(k) = {
                RenderTargetGl.unbind();
                Array.put(None, 0, activeTargetHolder);
                k(())
            }
        };

        // セッション終了時にカーソルハンドルを開放
        GLFW.glfwDestroyCursor(arrowCursor);
        GLFW.glfwDestroyCursor(crosshairCursor);
        GLFW.glfwDestroyCursor(hResizeCursor);
        GLFW.glfwDestroyCursor(vResizeCursor);
        GLFW.glfwDestroyCursor(allResizeCursor);
        GLFW.glfwDestroyCursor(nwseResizeCursor);
        GLFW.glfwDestroyCursor(neswResizeCursor);

        // OpenAL cleanup
        AL10.alDeleteSources(shutterSource);
        Map.forEach((_, src) -> AL10.alDeleteSources(src), audioRegistry);
        Map.forEach((_, filter) -> EXTEfx.alDeleteFilters(filter), Ref.get(lowpassRef));
        ALC10.alcDestroyContext(alContext);
        discard ALC10.alcCloseDevice(alDevice);

        Callbacks.glfwFreeCallbacks(window);
        GLFW.glfwDestroyWindow(window);
        GLFW.glfwTerminate();
        result
}
