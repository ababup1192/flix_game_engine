// LwjglLayer — ウィンドウ表示・入力の読み取り・音の再生を実機で受け持ち、Platform の effect と Audio の
// ハンドラを effect ごとの関数に分けて重ねる（入力は LwjglInput・塗りは RenderPaintHandlers）。ゲーム側はこの入口越しに描画や入力を頼むだけで、GL や OpenAL の
// 細部を知らずに済む。
// 利用例: `withLwjgl(config, ...)` でウィンドウを開き、ゲームループを回す。
// 注意: GL / OpenAL / シェーダ / テクスチャ / フォントベイク / フレーム描画 / 音声デコードは
//   同じ render_gl 内の各 mod（Render / Shader / Texture / Font / Frame / Audio 等）にあり、
//   このファイルは GLFW 外周だけを持って各 effect の本体から呼ぶ。
//   `withLwjgl` の第1引数 EngineConfig と戻り値の effect 制約は公開 API として固定（ゲーム側を変えずに済む）。

pub mod LwjglLayer {
    import fge.gl.GlContext
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.glfw.Callbacks
    import org.lwjgl.glfw.GLFWFramebufferSizeCallbackI
    import org.lwjgl.glfw.GLFWVidMode
    import org.lwjgl.opengl.GL
    import org.lwjgl.opengl.GL11
    import org.lwjgl.openal.AL
    import org.lwjgl.openal.AL10
    import org.lwjgl.openal.EXTEfx
    import org.lwjgl.openal.ALC
    import org.lwjgl.openal.ALC10
    import org.lwjgl.system.MemoryStack
    import org.lwjgl.system.MemoryUtil
    import java.lang.System
    import java.lang.ProcessBuilder
    import java.lang.ProcessHandle
    import java.util.ArrayList
    import java.lang.Exception
    import java.lang.Math
    import java.lang.{Object => JObject, Runnable, Runtime, Thread, Throwable}
    import java.util.concurrent.{Callable, ExecutionException, Executors, Future, ThreadFactory}
    import java.awt.BasicStroke
    import java.awt.{Color => AwtColor}
    import java.awt.image.BufferedImage
    import java.io.File
    import java.io.FileWriter
    import java.time.LocalDateTime
    import java.time.format.DateTimeFormatter
    import javax.imageio.ImageIO

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

    /// キャプチャしていない時の矢印の見せ方（setCursorVisible の宣言）を GLFW の入力モードへ。
    def cursorModeOf(visible: Bool): Int32 =
        if (visible) GLFW.GLFW_CURSOR_NORMAL else GLFW.GLFW_CURSOR_HIDDEN

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

    def splashShot(path: String, fbW: Int32, fbH: Int32, taken: Array[Int32, Static],
                   lastNanos: Array[Int64, Static]): Unit \ IO =
        let count = Array.get(0, taken);
        let now = System.nanoTime();
        let gap = (now - Array.get(0, lastNanos)) / 1000000i64;
        if (count >= splashShotLimit() or gap < splashShotGapMillis()) ()
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
    def frameShotLimit(): Int32 = 64

    def frameShot(dirOpt: Option[String], fbW: Int32, fbH: Int32, taken: Array[Int32, Static]): Unit \ IO =
        let count = Array.get(0, taken);
        match dirOpt {
            case Some(dir) if count < frameShotLimit() =>
                Array.put(count + 1, 0, taken);
                GlReadback.readBoundPng(fbW, fbH, "${dir}/frame-${count + 1}.png")
            case _ => ()
        }

    // WhyNot: withLwjgl の中に match を直に置かない — Log.warn は純粋な Unit で、`;` で捨てると呼び出しごと消える。
    /// dt を固定して起動したことを 1 行言う（実機に残し忘れると、遅い機械で遊びがゆっくりになる）。maxDeltaTime で切った時はそれも言う。
    def announceFixedDt(fixedDt: Option[Float64], maxDt: Float64): Unit \ IO = match fixedDt {
        case Some(dt) =>
            let used = LwjglEnv.frameDt(Some(dt), maxDt, 0i64);
            let capped = if (used < dt) "（${Float64.toString(dt)} は maxDeltaTime で切った）" else "";
            checked_ecast(Log.warn("[lwjgl] FLIX_GE_FIXED_DT: 毎コマの dt を ${Float64.toString(used)} 秒に固定する（実時間を使わない）${capped}"))
        case None     => ()
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
    /// OpenAL のバッファ 1 つの長さ（秒）。バッファが外れている（0）・形が読めないときは 0.0
    /// （0 のバッファへ問い合わせると AL のエラーになるので先に弾く）。
    def bufferSeconds(buffer: Int32): Float64 \ IO =
        if (buffer == 0) 0.0
        else {
            let size = AL10.alGetBufferi(buffer, AL10.AL_SIZE);
            let bytesPerFrame = AL10.alGetBufferi(buffer, AL10.AL_CHANNELS) * AL10.alGetBufferi(buffer, AL10.AL_BITS) / 8;
            let freq = AL10.alGetBufferi(buffer, AL10.AL_FREQUENCY);
            if (bytesPerFrame <= 0 or freq <= 0) 0.0
            else Int32.toFloat64(size / bytesPerFrame) / Int32.toFloat64(freq)
        }

    // 実機の handler
    // ========================================================================

    /// macOS では -XstartOnFirstThread 付きでプロセスを起動し直す（GLFW は窓をプロセスの最初のスレッドで開く）。
    /// すでに付いて動いている・macOS でない時は何もせず false。起動し直した時は子が終わるのを待ち、子の終了コードで
    /// このプロセスを終える（true は返らない）。ゲームの main の頭で `if (LwjglLayer.ensureMainThread()) () else ...` と呼ぶ。
    pub def ensureMainThread(): Bool \ IO =
        let osName = System.getProperty("os.name");
        if (Object.isNull(osName) or not String.contains({substr = "Mac"}, osName))
            false
        else if (not Object.isNull(System.getProperty("game.relaunched")))
            false
        else if (isStartedOnFirstThread())
            false
        else {
            println("Relaunching with -XstartOnFirstThread...");
            let args = new ArrayList();
            discard args.add("${System.getProperty("java.home")}/bin/java");
            discard args.add("-XstartOnFirstThread");
            discard args.add("-Dgame.relaunched=true");
            let projectPath = System.getProperty("projectPath");
            if (not Object.isNull(projectPath))
                discard args.add("-DprojectPath=${projectPath}")
            else ();
            discard args.add("-jar");
            discard args.add(System.getProperty("java.class.path"));
            discard args.add("run");
            let pb = new ProcessBuilder(args);
            discard pb.inheritIO();
            let code = pb.start().waitFor();
            // WhyNot: 終了コードを返して呼び元に終えさせない — 子が 0 で終わっても親はここで必ず終わる（戻ると呼び元が窓を開きにいく）。
            System.exit(code);
            true
        }

    /// java ランチャは -XstartOnFirstThread 付きの起動で、環境変数 `JAVA_STARTED_ON_FIRST_THREAD_<pid>` を "1" にする
    /// （LWJGL / GLFW が最初のスレッドで動いているかを見るのと同じ変数）。game.relaunched の無い起動でも二重に起動し直さない。
    def isStartedOnFirstThread(): Bool \ IO =
        Map.get("JAVA_STARTED_ON_FIRST_THREAD_${ProcessHandle.current().pid()}", LwjglEnv.snapshot()) == Some("1")

    /// `rootDir` 直下の project.json を読んで `withLwjgl` を起動する便利ラッパ。
    /// examples の Main.flix からは `with LwjglLayer.withProject(".")` の形で
    /// 直接 with-chain に並べて使う。loadProject 失敗時は bug! で停止する
    /// (project.json が壊れているのは開発者が直すべき状態)。
    /// 環境変数 FLIX_GE_PORTRAIT（LwjglEnv）があり、project.json に web.portraitDesign があれば、縦に持ったスマホの design と
    /// 窓の大きさで起動する（Display#orientation が Portrait になる。デスクトップで縦の並べ方を確かめる口）。
    pub def withProject(rootDir: String, f: Unit -> a \ ef):
            a \ ef - Platform.Services - Platform.Annotation - LoadProgress + IO + Fs.FileRead =
        match ProjectLoader.loadProject(rootDir) {
            case Ok(proj)  => withLwjgl(bootConfigOf(proj, LwjglEnv.fromMap(LwjglEnv.snapshot())#portraitView), f)
            case Err(msg) => bug!("Failed to load project.json: ${msg}")
        }

    // WhyNot: 縦の起動で録った flow を止めない — 録る・流すの入口（App.loadProjectDesign）は横の design で再生するので食い違うが、
    //   縦の起動は並べ方を目で見る口で、録らないのは使う人の側で選べる。起動の時に 1 行言うだけにする。
    /// FLIX_GE_PORTRAIT の大きさと project の縦の指定から、起動に使う設定。
    def bootConfigOf(proj: ProjectLoader.Project, portraitView: Option[Vec2.Vec2]): GameEngine.EngineConfig \ IO =
        match portraitView {
            case None       => proj#config
            case Some(view) => portraitBootConfig(proj, ProjectLoader.portraitConfigOf(proj, view))
        }

    def portraitBootConfig(proj: ProjectLoader.Project, portrait: Option[GameEngine.EngineConfig]): GameEngine.EngineConfig \ IO =
        match portrait {
            case Some(config) =>
                println("[lwjgl] 縦の design ${Int32.toString(config#designWidth)}x${Int32.toString(config#designHeight)} で起動（FLIX_GE_PORTRAIT）。この起動で録った flow は横の design で再生されて食い違う");
                config
            case None =>
                warnNoPortraitDesign();
                proj#config
        }

    // WhyNot: portraitBootConfig の中で Log.fellBack を文として置かない — 純粋な式の結果を捨てる形になり、新しい Flix が E8956 で止める。
    def warnNoPortraitDesign(): Unit \ IO =
        checked_ecast(Log.fellBack("lwjgl", "FLIX_GE_PORTRAIT", "横の design", "project.json に web.portraitDesign が無い"))

    /// ゲームの本体 f が最初のコマを描くまでに送る LoadProgress.report は、起動画面を進めてウィンドウのイベントを poll する。
    pub def withLwjgl(config: GameEngine.EngineConfig, f: Unit -> a \ ef): a \ ef - Platform.Services - Platform.Annotation - LoadProgress + IO =
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
        // 3D の場面（Scene3d の Native）を窓へ直に描く時の深度。
        GLFW.glfwWindowHint(GLFW.GLFW_DEPTH_BITS, 24);

        // 隠しウィンドウモード（GL 突き合わせ harness 用）。Retina の 2 倍化を切るのは、
        // フレームバッファ = design 寸に固定しないと letterbox 補間が乗り、
        // 画素の突き合わせが成立しないため。
        let env = LwjglEnv.load();
        let hidden = env#hidden;
        // 音を消して起動するか（計測や見回りで隠し窓を流す時）。音の処理は動かしたまま、全体の音量だけ 0 に止める。
        let muted = env#muted;
        let frameStats = if (env#frameStats) Some(RenderFrameStats.fresh()) else None;
        announceFixedDt(env#fixedDt, config#maxDeltaTime);
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
        GLFW.glfwSwapInterval(if (hidden or env#noVsync) 0 else 1);
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

        // 塗りのコア（シェーダー・VAO・テクスチャ・シェーダー面・レンダーターゲット・静的レイヤーの登録簿）。
        // 窓なしで動画を塗る GlOffscreen も同じ RenderPaint で塗る（窓・入力・音・swap はここが持つ）。
        let opened = GlCallLog.open();
        let gl = opened#gl;
        let paint = RenderPaint.create(gl, { designWidth = config#designWidth, designHeight = config#designHeight,
                                         clearColor = config#clearColor, screenFramebuffer = 0,
                                         scene3d = Render3d.makeRenderer(gl, config), gpuTimer = GpuTimer.frameTimer() });

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
                    RenderPaint.paintFrame(gl, paint, width, height, RenderPaint.lastFrame(paint));
                    GLFW.glfwSwapBuffers(cbWindow)
                }
            }
        });

        // ===== 起動画面 =====
        // ここから下は読み込みで数秒〜十数秒止まる。ウィンドウは既に出ているので、何も描かないと
        // 固まったように見える。組み込みの絵だけで進み具合を出し続ける。
        RenderPaint.addTextures(RenderSplash.install(gl), paint);
        let splashState = RenderSplash.newState();
        let splashShotTaken = Array#{0} @ Static;
        let splashShotAt = Array#{0i64} @ Static;
        let frameShotTaken = Array#{0} @ Static;
        let design = { x = screenW, y = screenH };
        // 最後にイベントを poll した時刻（LoadProgress の知らせが、描かない回にも poll するかを決める）。
        let polledAt = Array#{0i64} @ Static;
        // 起動画面も塗りのコアの控えへ入れる。読み込み中にウィンドウの大きさを変えると
        // リサイズ callback が控えの中身で描き直すので、空だと真っ黒に落ちる。
        // macOS では画面を出すたびにイベントを汲まないとウィンドウが「応答なし」になる。
        let drawSplash = (ds: List[GameEngine.Drawable]) -> {
            let splashFrame = { sprites = ds | RenderPaint.emptyFrame() };
            RenderPaint.rememberFrame(paint, splashFrame);
            let (splashW, splashH) = Array.get(0, framebufferSizeHolder);
            RenderPaint.paintFrame(gl, paint, splashW, splashH, splashFrame);
            Option.forEach(path -> splashShot(path, splashW, splashH, splashShotTaken, splashShotAt), env#splashShotPath);
            GLFW.glfwSwapBuffers(window);
            GLFW.glfwPollEvents();
            Array.put(System.nanoTime(), 0, polledAt)
        };
        let splash = (phase: String, done: Int32, total: Int32) ->
            RenderSplash.tick(splashState, drawSplash, design, phase, done, total);
        // 読み込み中は画面の垂直同期を待たない（1 枚 16ms の待ちが読み込みそのものを遅くする）。
        GLFW.glfwSwapInterval(0);
        RenderSplash.show(splashState, drawSplash, design, "starting up...", 0, 0);

        // テクスチャ・フォント・組み込みの放射テクスチャを読み、塗りのコアの登録簿へ載せる（起動画面に進み具合を出しながら）。
        let fonts = RenderPaint.loadAssets(gl, paint, LwjglAssets.loader(), config, splash);

        RenderSplash.show(splashState, drawSplash, design, "starting audio...", 0, 0);
        let audio = openAudio(config, muted, splash);
        // ゲームの本体は LoadProgress で知らせるまで（知らせないゲームは最初のコマまで）描き直さないので、残る字をここで合わせる。
        RenderSplash.show(splashState, drawSplash, design, "preparing game...", 0, 0);

        // 本体が初めて pollEvents を呼んだか（ゲームのループが回り始めたか）。垂直同期はそこで戻す。
        // WhyNot: f() の前に垂直同期を戻さない — 最初のコマまでの LoadProgress の 1 枚ごとに 1 コマ分待つ。
        let looping = Array#{false} @ Static;

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

        let cursors = openCursors();
        // 同じ Cursor を毎フレーム渡されたときに glfwSetCursor を抑制するためのキャッシュ
        let lastCursorHolder = Array#{(GameEngine.Cursor.Default: GameEngine.Cursor)} @ Static;

        // 入力の読む物（ホイール・フォーカス・マウスのボタンの callback とゲームパッド）。
        let devices = LwjglInput.open(window, design);
        let present = { window = window, paint = paint, framebufferSize = framebufferSizeHolder, frameStats = frameStats,
                        frameShotDir = env#frameShotDir, frameShotTaken = frameShotTaken, finishAfterSwap = finishAfterSwap,
                        screenPainted = Ref.fresh(Static, None) };
        let windowState = {
            window = window, config = config, hidden = hidden, noVsync = env#noVsync, looping = looping, devices = devices,
            design = design, cursors = cursors#lookup, lastCursor = lastCursorHolder,
            mouseCaptured = Array#{false} @ Static, cursorVisible = Array#{true} @ Static,
            fullscreen = fullscreenHolder, originalWindowRect = originalWindowRectHolder, present = present
        };
        let framebufferSize = () -> Array.get(0, framebufferSizeHolder);
        let annotation = { window = window, config = config, gl = gl, paint = paint, design = design,
                           shutterSource = audio#shutterSource };

        // WhyNot 並びを変えない: op は内側の handler から順にたどるので、sprite ごとに呼ぶ GpuResources と
        // 毎コマ読む Input を内側に置く。
        let result =
            handleLoadProgress({ looping = looping, splash = splash, polledAt = polledAt, devices = devices }, () ->
            handleAudio(audio#state, () ->
            RenderPaintHandlers.handleTarget(gl, paint, framebufferSize, () ->
            handleAnnotation(annotation, () ->
            RenderPaintHandlers.handleDiagnostics(paint, () ->
            handleTasks(() ->
            RenderPaintHandlers.handleDraw3d(paint, () ->
            handleFrameClock({ fixedDt = env#fixedDt, maxDeltaTime = config#maxDeltaTime, last = timeHolder }, () ->
            handleWindow(windowState, () ->
            RenderPaintHandlers.handleDraw2d(gl, paint, framebufferSize, (paintFrom, paintTo) -> { Ref.put(Some((paintFrom, paintTo)), present#screenPainted); opened#onScreenFrame() }, () ->
            LwjglInput.handleInput(devices, () ->
            RenderPaintHandlers.handleGpuResources(gl, paint, fonts, f))))))))))));

        List.forEach(c -> GLFW.glfwDestroyCursor(c), cursors#handles);
        closeAudio(audio);

        LwjglInput.close(devices);
        Callbacks.glfwFreeCallbacks(window);
        GLFW.glfwDestroyWindow(window);
        GLFW.glfwTerminate();
        result


    // ========================================================================
    // effect ごとの handler（withLwjgl が重ねる）
    // ========================================================================

    /// 仕事を重ねる handler: 預けた仕事を描く手と別のスレッド 1 本で走らせ、finishTask で待って受け取る（仕事の例外は包みを外して投げ直す）。
    /// CPU が 1 つの機械はその場で順に走らせる。
    // WhyNot: 共有のスレッドの組（ForkJoinPool.commonPool）に預けない — ゲームや同じ JVM の道具の仕事と取り合い、1 コマの時間が揺れる。
    pub def handleTasks(f: Unit -> a \ ef): a \ (ef - Platform.Tasks) + IO =
        if (Runtime.getRuntime().availableProcessors() < 2) Platform.runTasksInPlace(f)
        else {
            let pool = Executors.newSingleThreadExecutor(taskThreads());
            let held = Ref.fresh(Static, None);
            let result = try {
                run f() with handler Platform.Tasks {
                    def startTask(task, k) = if (Option.nonEmpty(Ref.get(held))) bug!("Platform.Tasks: 前に預けた仕事を finishTask で受け取る前に、次を預けた") else {
                        Ref.put(Some(pool.submit(new Callable[JObject] { def call(_this: Callable[JObject]): JObject \ IO = task() })), held);
                        k(())
                    }
                    def finishTask(k) = match Ref.get(held) {
                        case Some(future) => { Ref.put(None, held); k(valueOrThrow(future)) }
                        case None         => bug!("Platform.Tasks: finishTask の前に startTask で預けていない")
                    }
                }
            } catch {
                case e: Throwable => { discard pool.shutdownNow(); throw e }
            };
            discard pool.shutdownNow();
            result
        }

    /// 終わった仕事の値（仕事が例外で終わっていたら、包みを外した元の例外を投げる）。
    def valueOrThrow(future: Future[JObject]): JObject \ IO =
        try { future.get() } catch {
            case e: ExecutionException => { let cause = e.getCause(); if (Object.isNull(cause)) throw e else throw cause }
        }

    /// 仕事のスレッドを作る factory（daemon・名前つき。窓を閉じた時にプロセスの終わりを止めない）。
    def taskThreads(): ThreadFactory \ IO =
        new ThreadFactory {
            def newThread(_this: ThreadFactory, task: Runnable): Thread \ IO =
                let thread = new Thread(task, "fge-pipelined-step");
                thread.setDaemon(true);
                thread
        }

    /// Platform.Window の handler の状態。mouseCaptured = キャプチャしているか・cursorVisible = キャプチャを放した時に戻す矢印の見せ方（setCursorVisible の宣言）。
    type alias WindowState = {
        window = Int64, config = GameEngine.EngineConfig, hidden = Bool, noVsync = Bool, looping = Array[Bool, Static],
        devices = LwjglInput.Devices, design = Vec2.Vec2,
        cursors = GameEngine.Cursor -> Int64, lastCursor = Array[GameEngine.Cursor, Static],
        mouseCaptured = Array[Bool, Static], cursorVisible = Array[Bool, Static],
        fullscreen = Array[Bool, Static], originalWindowRect = Array[(Int32, Int32, Int32, Int32), Static],
        present = PresentState
    }

    /// 塗ったコマを画面へ出す（swap・FrameStats・撮る口）ための状態。screenPainted = 前の presentFrame の後に画面へ塗ったコマの塗りの始まりと終わり（無ければ None）。
    /// finishAfterSwap = swap の後に GPU の完了を待つか（Windows だけ。withLwjgl の finishAfterSwap の所）。
    type alias PresentState = {
        window = Int64, paint = RenderPaint.Paint, framebufferSize = Array[(Int32, Int32), Static],
        frameStats = Option[RenderFrameStats.Stats], frameShotDir = Option[String], frameShotTaken = Array[Int32, Static],
        finishAfterSwap = Bool, screenPainted = Ref[Option[(Int64, Int64)], Static]
    }

    /// Platform.Window を GLFW の窓で受ける。
    def handleWindow(ws: WindowState, f: Unit -> a \ ef): a \ (ef - Platform.Window) + IO =
        let window = ws#window;
        let config = ws#config;
        let fullscreenHolder = ws#fullscreen;
        let originalWindowRectHolder = ws#originalWindowRect;
        run f() with handler Platform.Window {
            def pollEvents(k) = {
                // WhyNot: 隠しウィンドウでは 1 に戻さない — 見えないウィンドウの swap は 1 回が 1 秒級に落ちる（ウィンドウを作る所と同じ理由）。
                if (not Array.get(0, ws#looping)) {
                    Array.put(true, 0, ws#looping);
                    GLFW.glfwSwapInterval(if (ws#hidden or ws#noVsync) 0 else 1)
                } else ();
                LwjglInput.poll(ws#devices);
                k(())
            }
            def shouldClose(k) = k(GLFW.glfwWindowShouldClose(window))
            def setShouldClose(close, k) = {
                GLFW.glfwSetWindowShouldClose(window, close);
                k()
            }
            def getViewportRect(k) = k({ position = Vec2.zero(), size = ws#design })
            def getDisplay(k) = k(LwjglInput.displayOf(window, ws#design))
            def presentFrame(k) = {
                presentScreen(ws#present);
                k(())
            }
            def setCursor(cursor, k) = {
                if (Array.get(0, ws#lastCursor) != cursor) {
                    GLFW.glfwSetCursor(window, (ws#cursors)(cursor));
                    Array.put(cursor, 0, ws#lastCursor)
                } else ();
                k(())
            }
            def setCursorVisible(visible, k) = {
                Array.put(visible, 0, ws#cursorVisible);
                // WhyNot: キャプチャしている間に当てない — GLFW_CURSOR_DISABLED を HIDDEN / NORMAL で上書きするとキャプチャが外れる。
                if (Array.get(0, ws#mouseCaptured)) () else GLFW.glfwSetInputMode(window, GLFW.GLFW_CURSOR, cursorModeOf(visible));
                k(())
            }
            def setMouseCaptured(captured, k) = {
                if (captured == Array.get(0, ws#mouseCaptured)) ()
                else {
                    Array.put(captured, 0, ws#mouseCaptured);
                    LwjglInput.rebaseMouse(ws#devices);
                    let raw = GLFW.glfwRawMouseMotionSupported();
                    if (captured) {
                        GLFW.glfwSetInputMode(window, GLFW.GLFW_CURSOR, GLFW.GLFW_CURSOR_DISABLED);
                        if (raw) GLFW.glfwSetInputMode(window, GLFW.GLFW_RAW_MOUSE_MOTION, GLFW.GLFW_TRUE) else ()
                    } else {
                        if (raw) GLFW.glfwSetInputMode(window, GLFW.GLFW_RAW_MOUSE_MOTION, GLFW.GLFW_FALSE) else ();
                        GLFW.glfwSetInputMode(window, GLFW.GLFW_CURSOR, cursorModeOf(Array.get(0, ws#cursorVisible)))
                    }
                };
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
            def isFullscreen(k) = k(Array.get(0, fullscreenHolder))
            def setDebugBadge(enabled, k) = {
                let title = if (enabled) "${config#title} (Debug)" else config#title;
                GLFW.glfwSetWindowTitle(window, title);
                k(())
            }
        }

    /// 前の presentFrame の後に画面へ塗ったコマがあれば、FrameStats と撮る口に渡してから swap する（無ければ何もしない）。
    // WhyNot: 撮る前に既定のフレームバッファを bind し直さない — presentFrame はレンダーターゲットを閉じてから呼ぶ決まり（Platform.Window の doc）で、
    //   App のループもそう呼ぶ。開いたまま呼ぶ誤りを隠すと、撮る口が別の絵を撮っても気づけない。
    def presentScreen(ws: PresentState): Unit \ IO =
        match Ref.get(ws#screenPainted) {
            case None => ()
            case Some((paintFrom, paintTo)) =>
                Ref.put(None, ws#screenPainted);
                let swapFrom = System.nanoTime();
                let (fbW, fbH) = Array.get(0, ws#framebufferSize);
                Option.forEach(stats -> RenderFrameStats.record(stats, paintFrom, paintTo), ws#frameStats);
                frameShot(ws#frameShotDir, fbW, fbH, ws#frameShotTaken);
                GLFW.glfwSwapBuffers(ws#window);
                if (ws#finishAfterSwap) GL11.glFinish() else ();
                RenderPaint.noteFrame(ws#paint, 0i64, System.nanoTime() - swapFrom, () -> 0)
        }

    /// Platform.FrameClock を実時間（FLIX_GE_FIXED_DT があればその値）で受ける。last = 前に読んだ時刻（System.nanoTime）。
    def handleFrameClock(clock: { fixedDt = Option[Float64], maxDeltaTime = Float64, last = Array[Int64, Static] },
                         f: Unit -> a \ ef): a \ (ef - Platform.FrameClock) + IO =
        run f() with handler Platform.FrameClock {
            def getDeltaTime(k) = {
                let currentTime = System.nanoTime();
                let prev = Array.get(0, clock#last);
                Array.put(currentTime, 0, clock#last);
                k(LwjglEnv.frameDt(clock#fixedDt, clock#maxDeltaTime, currentTime - prev) |> Duration.seconds)
            }
        }

    /// Platform.Annotation の handler の状態。
    type alias AnnotationState = {
        window = Int64, config = GameEngine.EngineConfig, gl = GlContext, paint = RenderPaint.Paint, design = Vec2.Vec2, shutterSource = Int32
    }

    /// Platform.Annotation を、直前に塗ったコマの読み戻しとファイルへの書き出しで受ける。
    def handleAnnotation(anno: AnnotationState, f: Unit -> a \ ef): a \ (ef - Platform.Annotation) + IO =
        let window = anno#window;
        let config = anno#config;
        let paint = anno#paint;
        let gl = anno#gl;
        let (screenW, screenH) = (anno#design#x, anno#design#y);
        let shutterSource = anno#shutterSource;
        run f() with handler Platform.Annotation {
            def saveAnnotation(req, k) = {
                let saved = try {
                    let now = LocalDateTime.now();
                    let dirStamp = now.format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss"));
                    let readableStamp = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));
                    let dirPath = "debug/annotations/${dirStamp}_${sanitizeName(config#title)}_f${req#frame}";
                    discard (new File(dirPath)).mkdirs();
                    // 直前に画面へ塗ったコマ（App が等倍で塗った物）を back buffer に塗り直して読む。
                    // swap しないので画面には映らず、次のフレーム描画がそのまま上書きする。
                    let stack = MemoryStack.stackPush();
                    let wBuf = stack.mallocInt(1);
                    let hBuf = stack.mallocInt(1);
                    GLFW.glfwGetFramebufferSize(window, wBuf, hBuf);
                    let fbW = wBuf.get(0);
                    let fbH = hBuf.get(0);
                    discard MemoryStack.stackPop();
                    // WhyNot: 依頼に入れた描画命令から組み直さない — シェーダー面・レンダーターゲット・静的層を
                    // 運べず、スクリーンショットだけが画面と違う規則で描かれる。塗ったコマをそのまま塗り直す。
                    RenderPaint.paintFrame(gl, paint, fbW, fbH, RenderPaint.lastFrame(paint));
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
        }

    /// 標準のカーソルを起動時に 1 回だけ作る（setCursor のたびに作って捨てると重く、漏れの元にもなる）。
    /// lookup = 形 → ハンドル・handles = 閉じる時に捨てる全部。
    // WhyNot: 4 隅を 4 つ作らない — GLFW には対角の 2 種（NWSE・NESW）しか無い。
    def openCursors(): { lookup = GameEngine.Cursor -> Int64, handles = List[Int64] } \ IO =
        let make = (c: GameEngine.Cursor) -> GLFW.glfwCreateStandardCursor(cursorShapeToGlfw(c));
        let arrow = make(GameEngine.Cursor.Default);
        let crosshair = make(GameEngine.Cursor.Crosshair);
        let hResize = make(GameEngine.Cursor.HResize);
        let vResize = make(GameEngine.Cursor.VResize);
        let allResize = make(GameEngine.Cursor.AllResize);
        let rotate = make(GameEngine.Cursor.Rotate);
        let nwse = make(GameEngine.Cursor.NWResize);
        let nesw = make(GameEngine.Cursor.NEResize);
        let lookup = (cursor: GameEngine.Cursor) -> match cursor {
            case GameEngine.Cursor.Default    => arrow
            case GameEngine.Cursor.Crosshair  => crosshair
            case GameEngine.Cursor.HResize    => hResize
            case GameEngine.Cursor.VResize    => vResize
            case GameEngine.Cursor.AllResize  => allResize
            case GameEngine.Cursor.Rotate     => rotate
            case GameEngine.Cursor.NWResize   => nwse
            case GameEngine.Cursor.SEResize   => nwse
            case GameEngine.Cursor.NEResize   => nesw
            case GameEngine.Cursor.SWResize   => nesw
        };
        { lookup = lookup, handles = arrow :: crosshair :: hResize :: vResize :: allResize :: rotate :: nwse :: nesw :: Nil }

    /// OpenAL の装置と文脈・音の登録簿・注釈のシャッター音。openAudio が作り、closeAudio が捨てる。
    type alias AudioSession = { device = Int64, context = Int64, state = AudioState, shutterSource = Int32 }

    /// OpenAL を開き、project.json の音を読む（起動画面に進み具合を出しながら）。開けなければ bug!（起動時に音の実体が要る）。
    def openAudio(config: GameEngine.EngineConfig, muted: Bool, splash: (String, Int32, Int32) -> Unit \ IO): AudioSession \ IO =
        println("Initializing audio...");
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
        if (muted) AL10.alListenerf(AL10.AL_GAIN, 0.0f32) else ();

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
                Ref.put(Set.insert(name, warned), missingSoundRef);
                Log.warn("audio: 知らない音 '${name}' — ${op} は何もしない"
                    + "（project.json の sounds に同名の宣言があるか確認）")
            }
        };
        // ローパス（setLowpass）は EFX の lowpass フィルタを音源ごとに 1 つ作って付ける。
        // EFX の無い環境では何もしない（音は素通しのまま）。フィルタは初めて削る音にだけ作る。
        let hasEfx = ALC10.alcIsExtensionPresent(alDevice, "ALC_EXT_EFX");
        let lowpassRef: Ref[Map[String, Int32], Static] = Ref.fresh(Static, Map.empty());
        // 最後に送った gainHF（音源ごと）。同じ値なら AL へ送り直さない（毎フレーム呼ばれる口なので）。
        let lastGainHFRef: Ref[Map[String, Float64], Static] = Ref.fresh(Static, Map.empty());
        // 音の長さ（audioSeconds）の控え。reloadAudio で中身が替わったらその名前を捨てる。
        let audioSecondsRef: Ref[Map[String, Float64], Static] = Ref.fresh(Static, Map.empty());
        // 注釈保存時のシャッター音（合成なのでゲーム側の音声マニフェストに依存しない）
        let shutterSource = buildShutterSource();
        println("  Audio ready");
        { device = alDevice, context = alContext, shutterSource = shutterSource,
          state = { registry = audioRegistry, muted = muted, warnMissing = warnMissingSound, hasEfx = hasEfx,
                    lowpass = lowpassRef, lastGainHF = lastGainHFRef, seconds = audioSecondsRef } }

    /// openAudio で開いた物を捨てる。
    def closeAudio(audio: AudioSession): Unit \ IO =
        AL10.alDeleteSources(audio#shutterSource);
        Map.forEach((_, src) -> AL10.alDeleteSources(src), audio#state#registry);
        Map.forEach((_, filter) -> EXTEfx.alDeleteFilters(filter), Ref.get(audio#state#lowpass));
        ALC10.alcDestroyContext(audio#context);
        discard ALC10.alcCloseDevice(audio#device)

    /// GameEngine.Audio の handler の状態。lowpass = 音源ごとの EFX のフィルタ・lastGainHF = 最後に送った gainHF・seconds = 音の長さの控え。
    type alias AudioState = {
        registry = Map[String, Int32], muted = Bool, warnMissing = (String, String) -> Unit \ IO, hasEfx = Bool,
        lowpass = Ref[Map[String, Int32], Static], lastGainHF = Ref[Map[String, Float64], Static],
        seconds = Ref[Map[String, Float64], Static]
    }

    /// GameEngine.Audio を OpenAL の音源で受ける。
    def handleAudio(audio: AudioState, f: Unit -> a \ ef): a \ (ef - GameEngine.Audio) + IO =
        let audioRegistry = audio#registry;
        let muted = audio#muted;
        let warnMissingSound = audio#warnMissing;
        let hasEfx = audio#hasEfx;
        let lowpassRef = audio#lowpass;
        let lastGainHFRef = audio#lastGainHF;
        let audioSecondsRef = audio#seconds;
        run f() with handler GameEngine.Audio {
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
                let audible = if (muted) 0.0 else Float64.max(0.0, Float64.min(1.0, gain));
                AL10.alListenerf(AL10.AL_GAIN, RenderUtil.f32(audible));
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
                // 鳴らすたびに AL へ 5 回問い合わせないよう、名前ごとに覚える（reloadAudio で捨てる）。
                let seconds = match Map.get(name, Ref.get(audioSecondsRef)) {
                    case Some(known) => known
                    case None        =>
                        let measured = match Map.get(name, audioRegistry) {
                            case Some(src) => bufferSeconds(AL10.alGetSourcei(src, AL10.AL_BUFFER))
                            case None      => 0.0
                        };
                        Ref.put(Map.insert(name, measured, Ref.get(audioSecondsRef)), audioSecondsRef);
                        measured
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
                            Ref.put(Map.remove(name, Ref.get(audioSecondsRef)), audioSecondsRef);
                            if (old != 0) AL10.alDeleteBuffers(old) else ()
                        }
                };
                k(())
            }
        }

    /// LoadProgress の知らせで起動画面を進める（ループが回り始めた後＝最初の pollEvents の後は何もしない）。
    /// 仕事の pool とデコーダーは LwjglLoad。polledAt = 最後にイベントを poll した時刻。
    def handleLoadProgress(load: { looping = Array[Bool, Static], splash = (String, Int32, Int32) -> Unit \ IO,
                                   polledAt = Array[Int64, Static], devices = LwjglInput.Devices },
                           f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO =
        LwjglLoad.handleWith(showLoadProgress(load), f)

    // WhyNot: ループが回り始めた後は何もしない — コマの途中で poll すると、リサイズの callback が
    // 描いている途中の RenderTarget を開いたまま描き直しと swap をしうる。
    def showLoadProgress(load: { looping = Array[Bool, Static], splash = (String, Int32, Int32) -> Unit \ IO,
                                 polledAt = Array[Int64, Static], devices = LwjglInput.Devices },
                         phase: String, done: Int32, total: Int32): Unit \ IO =
        if (not Array.get(0, load#looping)) {
            (load#splash)(phase, done, total);
            // tick は間引いた回と FLIX_GE_NO_SPLASH の時に poll しないので、描かなくても poll だけはする。
            let now = System.nanoTime();
            if ((now - Array.get(0, load#polledAt)) / 1000000i64 >= RenderSplash.intervalMillis()) {
                GLFW.glfwPollEvents();
                Array.put(now, 0, load#polledAt)
            } else ();
            // 読み込み中のホイールは捨てる（最初のコマで一度に出さない）。
            // WhyNot: 最初の pollEvents で 0 に戻さない — ループは pollEvents より前にホイールを読む。
            LwjglInput.dropScroll(load#devices)
        } else ()
}
