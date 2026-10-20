// GlOffscreen — 窓を見せずに GL で塗る（人が見る絵だけ GPU で塗る: 会話のプレビュー・動画）。
// 塗るのは窓ありで遊ぶ時と同じ塗りのコア（RenderPaint）で、行き先が画面ではなく design × scale の FBO になるだけ。
// 比べ（reference-check・compare）には使わない — GL と SoftRaster は文字と多角形の縁が近似の関係（docs/backend-parity.md）。
//
// 使い方（GL は 1 本の糸で。open から close まで同じ糸で呼ぶ）:
//   match GlOffscreen.open({ config = 読んだ project.json の config, scale = 2 }) {
//       case Err(why)   => SoftRaster の道へ（画面の無い所・GL が作れない）
//       case Ok(session) =>
//           GlOffscreen.handle(session, () -> App のコマを描く（Game・Shader・Target を使う物）);
//           let image = GlOffscreen.readImage(session);   // 最後に塗った画面のコマ
//           GlOffscreen.close(session)
//   }
//
// 文脈の作り方: macOS は CGL で窓も Dock のアイコンも無い文脈を作る（どの糸からでも作れるので、
// -XstartOnFirstThread も最初の糸の取り合いも要らない）。ほかの OS は GLFW の隠し窓（FLIX_GE_HIDDEN と同じ作り）。
// どちらも作れなければ Err（呼ぶ側は SoftRaster で塗る）。
pub mod GlOffscreen {
    import org.lwjgl.glfw.GLFW
    import org.lwjgl.opengl.CGL
    import org.lwjgl.opengl.GL
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.opengl.GL30
    import org.lwjgl.PointerBuffer
    import org.lwjgl.system.MemoryUtil
    import java.awt.image.BufferedImage
    import java.io.File
    import java.lang.System
    import java.lang.Throwable
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    /// 文脈の持ち主（閉じる時の片付けが違う）。
    enum Context {
        /// macOS の CGL の文脈（窓なし）。
        case Cgl(Int64)
        /// GLFW の隠し窓。
        case Glfw(Int64)
    }

    /// 開いた 1 本。外から作らせない（open だけが作る）。
    /// width・height = FBO の画素（design × scale）。stamps = テクスチャのファイルの (大きさ, 更新時刻)（refreshTextures が見る）。
    enum SessionData {
        case SessionData({
            context = Context,
            fbo = Int32,
            colorTex = Int32,
            depthStencil = Int32,
            width = Int32,
            height = Int32,
            paint = RenderPaint.Paint,
            fonts = RenderPaint.Fonts,
            design = Vec2.Vec2,
            stamps = Ref[Map[String, (String, Int64, Int64)], Static]
        })
    }

    pub type alias Session = SessionData

    /// 画面のコマの画素の大きさ。
    pub def sizeOf(session: Session): (Int32, Int32) =
        let SessionData.SessionData(s) = session;
        (s#width, s#height)

    /// GL の文脈と design × scale の FBO を作り、テクスチャとフォントを読む。作れなければ Err(理由)。
    /// 呼んだ糸が close まで GL を持つ。
    pub def open(cfg: { config = GameEngine.EngineConfig, scale = Int32 }): Result[String, Session] \ IO =
        discard System.setProperty("java.awt.headless", "true");
        let config = cfg#config;
        let width = config#designWidth * cfg#scale;
        let height = config#designHeight * cfg#scale;
        match openContext() {
            case Err(why) => Err(why)
            case Ok(context) =>
                try {
                    discard GL.createCapabilities();
                    let (fbo, colorTex, depthStencil) = makeFramebuffer(width, height);
                    let status = GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER);
                    if (status != GL30.GL_FRAMEBUFFER_COMPLETE) {
                        closeContext(context);
                        Err("FBO が完成しない status=${status}")
                    } else {
                        GL11.glEnable(GL11.GL_BLEND);
                        GL11.glBlendFunc(GL11.GL_SRC_ALPHA, GL11.GL_ONE_MINUS_SRC_ALPHA);
                        let paint = RenderPaint.create({ designWidth = config#designWidth, designHeight = config#designHeight,
                                                         clearColor = config#clearColor, screenFramebuffer = fbo });
                        // 組み込みのフォント（受け皿）とロゴを先に載せる（窓の起動画面と同じ並び）。
                        RenderPaint.addTextures(RenderSplash.install(), paint);
                        let fonts = RenderPaint.loadAssets(paint, config, (_, _, _) -> checked_ecast(()));
                        let stamps = config#textureManifest
                            |> List.foldLeft((acc, entry) -> Map.insert(entry#name, stampOf(entry#path), acc), Map.empty());
                        Ok(SessionData.SessionData({
                            context = context, fbo = fbo, colorTex = colorTex, depthStencil = depthStencil,
                            width = width, height = height, paint = paint, fonts = fonts,
                            design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) },
                            stamps = Ref.fresh(Static, stamps)
                        }))
                    }
                } catch {
                    case e: Throwable =>
                        closeContext(context);
                        Err("GL の用意に失敗: ${e.toString()}")
                }
        }

    /// 窓サーバへの繋がりを先に取る（macOS だけ。ほかの OS では何もしない）。**AWT を使う前に 1 回呼ぶ。**
    /// AWT（HeadlessFont・BufferedImage の字）を先に使うと、その後の CGL は 10017（kCGLBadConnection）で
    /// 必ず失敗する（2026-10-20 にこの Mac で確かめた）。繋がりはプロセスの間残るので、選んだ画素形式はすぐ捨てる。
    /// 入口の頭で作る所（GpuShot.shotOf）が呼ぶ。失敗しても何もしない（open が理由を返す）。
    pub def connect(): Unit \ IO =
        let os = System.getProperty("os.name");
        if (Object.isNull(os) or not String.startsWith(prefix = "Mac", os)) ()
        else try {
            region rc {
                let attribs: Array[Int32, rc] = Array#{
                    CGL.kCGLPFAOpenGLProfile, CGL.kCGLOGLPVersion_3_2_Core, CGL.kCGLPFAAccelerated, 0 } @ rc;
                let count: Array[Int32, rc] = Array#{0} @ rc;
                let pix = MemoryUtil.memAllocPointer(1);
                let chosen = CGL.CGLChoosePixelFormat(attribs, pix, count);
                let format = pix.get(0);
                MemoryUtil.memFree(pix);
                if (chosen == 0 and format != 0i64) discard CGL.CGLDestroyPixelFormat(format) else ()
            }
        } catch {
            case _: Throwable => ()
        }

    /// macOS なら CGL、ほかは GLFW の隠し窓。
    def openContext(): Result[String, Context] \ IO =
        let os = System.getProperty("os.name");
        let mac = not Object.isNull(os) and String.startsWith(prefix = "Mac", os);
        try {
            if (mac) openCgl() else openGlfw()
        } catch {
            case e: Throwable => Err("GL の文脈を作れない: ${e.toString()}")
        }

    /// CGL: 3.2 Core（macOS では 4.1 Core が返る）・ハードウェアの描き手・RGBA。
    def openCgl(): Result[String, Context] \ IO = region rc {
        let attribs: Array[Int32, rc] = Array#{
            CGL.kCGLPFAOpenGLProfile, CGL.kCGLOGLPVersion_3_2_Core,
            CGL.kCGLPFAColorSize, 24, CGL.kCGLPFAAlphaSize, 8,
            CGL.kCGLPFAAccelerated, 0 } @ rc;
        let count: Array[Int32, rc] = Array#{0} @ rc;
        let pix = MemoryUtil.memAllocPointer(1);
        let chosen = CGL.CGLChoosePixelFormat(attribs, pix, count);
        let format = pix.get(0);
        MemoryUtil.memFree(pix);
        if (chosen == 10017) Err("CGLChoosePixelFormat が 10017（窓サーバに繋げない。AWT を先に使った・ログインの外で流している — GlOffscreen.connect を入口の頭で呼ぶ）")
        else if (chosen != 0 or format == 0i64) Err("CGLChoosePixelFormat が ${chosen}（画面・GPU の無い所）")
        else {
            let ctxBuf = MemoryUtil.memAllocPointer(1);
            let made = CGL.CGLCreateContext(format, 0i64, ctxBuf);
            let ctx = ctxBuf.get(0);
            MemoryUtil.memFree(ctxBuf);
            discard CGL.CGLDestroyPixelFormat(format);
            if (made != 0 or ctx == 0i64) Err("CGLCreateContext が ${made}")
            else if (CGL.CGLSetCurrentContext(ctx) != 0) { discard CGL.CGLDestroyContext(ctx); Err("CGLSetCurrentContext に失敗") }
            else Ok(Context.Cgl(ctx))
        }
    }

    /// GLFW の隠し窓（design 寸は FBO が持つので窓は 1×1 でよい）。
    def openGlfw(): Result[String, Context] \ IO =
        if (not GLFW.glfwInit()) Err("glfwInit に失敗（画面の無い所）")
        else {
            GLFW.glfwDefaultWindowHints();
            GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR, 3);
            GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR, 3);
            GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE, GLFW.GLFW_OPENGL_CORE_PROFILE);
            GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_FORWARD_COMPAT, GL11.GL_TRUE);
            GLFW.glfwWindowHint(GLFW.GLFW_VISIBLE, GL11.GL_FALSE);
            let window = GLFW.glfwCreateWindow(1, 1, "flix-ge-offscreen", MemoryUtil.NULL, MemoryUtil.NULL);
            if (window == MemoryUtil.NULL) { GLFW.glfwTerminate(); Err("glfwCreateWindow に失敗") }
            else { GLFW.glfwMakeContextCurrent(window); Ok(Context.Glfw(window)) }
        }

    def closeContext(context: Context): Unit \ IO = match context {
        case Context.Cgl(ctx) =>
            discard CGL.CGLSetCurrentContext(0i64);
            discard CGL.CGLDestroyContext(ctx)
        case Context.Glfw(window) =>
            GLFW.glfwDestroyWindow(window);
            GLFW.glfwTerminate()
    }

    /// 色（RGBA8 のテクスチャ）と深さ・ステンシル（シェーダー面を多角形で抜くのに使う）の FBO。bind したまま返す。
    def makeFramebuffer(width: Int32, height: Int32): (Int32, Int32, Int32) \ IO =
        let tex = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA8, width, height, 0,
                          GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, (MemoryUtil.NULL: Int64));
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        let depthStencil = GL30.glGenRenderbuffers();
        GL30.glBindRenderbuffer(GL30.GL_RENDERBUFFER, depthStencil);
        GL30.glRenderbufferStorage(GL30.GL_RENDERBUFFER, GL30.GL_DEPTH24_STENCIL8, width, height);
        let fbo = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, fbo);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0, GL11.GL_TEXTURE_2D, tex, 0);
        GL30.glFramebufferRenderbuffer(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_STENCIL_ATTACHMENT, GL30.GL_RENDERBUFFER, depthStencil);
        (fbo, tex, depthStencil)

    /// 片付ける（GL の物と文脈）。
    pub def close(session: Session): Unit \ IO =
        let SessionData.SessionData(s) = session;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, 0);
        GL30.glDeleteFramebuffers(s#fbo);
        GL30.glDeleteRenderbuffers(s#depthStencil);
        GL11.glDeleteTextures(s#colorTex);
        closeContext(s#context)

    // ── テクスチャの新しさ ──

    /// ファイルの (パス, 大きさ, 更新時刻)。無ければ (パス, -1, -1)。
    def stampOf(path: String): (String, Int64, Int64) \ IO =
        let file = new File(path);
        if (file.isFile()) (path, file.length(), file.lastModified()) else (path, -1i64, -1i64)

    /// manifest（今の project.json の textures）のうち、開いた時から描き直された・足された絵を読み直す。
    /// 戻り値は読み直した枚数。描き直した PNG が次の 1 枚にすぐ出るように、撮る前に毎回呼ぶ。
    /// WhyNot: 中身の SHA を毎回取らない — プレビュー 1 枚の予算（0.1 秒）に、全部の絵を読む時間が入らない。
    ///   大きさと更新時刻が両方同じまま中身だけ変わる書き方（同じ秒・同じ大きさの上書き）は見逃す。
    pub def refreshTextures(session: Session, manifest: List[RenderAsset.TextureEntry]): Int32 \ IO =
        let SessionData.SessionData(s) = session;
        manifest |> List.foldLeft((count, entry) -> {
            let now = stampOf(entry#path);
            if (Map.get(entry#name, Ref.get(s#stamps)) == Some(now)) count
            else {
                Ref.put(Map.insert(entry#name, now, Ref.get(s#stamps)), s#stamps);
                let (_, size, _) = now;
                if (size < 0i64) count
                else {
                    Option.forEach(RenderTexture.deleteTexture, RenderPaint.textureInfo(s#paint, entry#name));
                    RenderPaint.putTexture(entry#name, RenderTexture.loadTexture(entry#path, entry#hasAlpha), s#paint);
                    count + 1
                }
            }
        }, 0)

    // ── 字と絵（動画の口が、App を通さずに場面を組む時に使う）──

    /// 今のフォントのアトラス（名前 → アトラス。字が育つと中身が変わるので、コマごとに引き直す）。
    pub def fontTable(session: Session): Map[String, FontAtlas] \ IO =
        let SessionData.SessionData(s) = session;
        Ref.get(s#fonts#atlases)

    /// textureName のフォントに字を足す（Game.ensureGlyphs と同じ）。
    pub def ensureGlyphs(session: Session, textureName: String, codepoints: Set[Int32]): Unit \ IO =
        let SessionData.SessionData(s) = session;
        RenderPaint.ensureGlyphs(s#fonts, textureName, codepoints)

    /// ファイルの無い絵（ドット絵のアトラスなど）を名前で載せる。同じ名前・同じ key なら何もしない。
    /// argb = width × height の行優先の ARGB。
    pub def uploadImage(session: Session, name: String, key: String, width: Int32, height: Int32, argb: Vector[Int32]): Unit \ IO =
        let SessionData.SessionData(s) = session;
        RenderPaint.ensureTexture(s#paint, name, key, width, height, argb)

    // ── 塗る ──

    /// f の中の Game・Shader・Target を、このセッションの FBO へ塗る形で受ける（App の 1 コマを描く口をそのまま呼べる）。
    /// 入力・カーソル・窓の問いには「何も起きていない」で答える。画面のコマは最後の 1 枚が FBO に残る（readImage・readRgba で読む）。
    pub def handle(session: Session, f: Unit -> a \ ef): a \ (ef - GameEngine.Game - ShaderEffect.Shader - RenderTarget.Target) + IO =
        let SessionData.SessionData(s) = session;
        let paint = s#paint;
        let fonts = s#fonts;
        let (width, height) = (s#width, s#height);
        let design = s#design;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, s#fbo);
        run {
            f()
        } with handler GameEngine.Game {
            def renderCommands(sprites, tileMaps, polygons, staticLayer, k) = {
                discard RenderPaint.submitFrame(paint, width, height, sprites, tileMaps, polygons, staticLayer);
                k(())
            }
            def initTileBuffer(instances, k) = k(RenderPaint.initTileBuffer(paint, instances))
            def updateTileBuffer(vaoId, instances, k) = k(RenderPaint.updateTileBuffer(paint, vaoId, instances))
            def shouldClose(k) = k(false)
            def setShouldClose(_close, k) = k()
            def getDeltaTime(k) = k(Duration.seconds(1.0 / 60.0))
            def isKeyPressed(_key, k) = k(false)
            def getMousePosition(k) = k(Vec2.zero())
            def isMouseButtonPressed(_button, k) = k(false)
            def isGamepadTouched(k) = k(false)
            def consumeScrollDelta(k) = k(0.0)
            def getFontAtlas(name, k) = k(RenderPaint.fontAtlas(fonts, name))
            def ensureGlyphs(textureName, codepoints, k) = {
                RenderPaint.ensureGlyphs(fonts, textureName, codepoints);
                k(())
            }
            def getViewportRect(k) = k({ position = Vec2.zero(), size = design })
            def getTextureInfo(name, k) = k(RenderPaint.textureInfo(paint, name))
            def ensureTexture(name, key, w, h, argb, k) = {
                RenderPaint.ensureTexture(paint, name, key, w, h, argb);
                k(())
            }
            def setCursor(_cursor, k) = k(())
            def setCursorVisible(_visible, k) = k(())
            def setFullscreen(_on, k) = k(())
            def isFullscreen(k) = k(false)
            def saveAnnotation(_req, k) = k(None)
            def setDebugBadge(_enabled, k) = k(())
        } with handler ShaderEffect.Shader {
            def buildProgram(spec, k) = k(RenderPaint.buildProgram(paint, spec))
            def drawSurface(cmd, k) = {
                RenderPaint.queueSurface(paint, cmd);
                k(())
            }
        } with handler RenderTarget.Target {
            def beginTarget(name, w, h, clearOp, k) = {
                RenderPaint.beginTarget(paint, name, w, h, clearOp);
                k(())
            }
            def endTarget(k) = {
                RenderPaint.endTarget(paint);
                k(())
            }
        }

    // ── 読み戻す ──

    /// 最後に塗った画面のコマを RGBA の生の画素で buf へ読む（width × height × 4 バイト・下の行から）。
    /// 上下は直さない（ffmpeg の vflip に任せる）。buf は呼ぶ側が持ち回す（毎コマ 2.3 MB を作り直さない）。
    pub def readRgba(session: Session, buf: ByteBuffer): Unit \ IO =
        let SessionData.SessionData(s) = session;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, s#fbo);
        GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 1);
        discard buf.clear();
        GL11.glReadPixels(0, 0, s#width, s#height, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, buf)

    /// readRgba の大きさの入れ物（直のメモリ）。
    pub def freshBuffer(session: Session): ByteBuffer \ IO =
        let (w, h) = sizeOf(session);
        ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())

    /// 最後に塗った画面のコマを、左上原点の RGB の画像にする（PNG に書く 1 枚撮り用）。
    pub def readImage(session: Session): BufferedImage \ IO = region rc {
        let SessionData.SessionData(s) = session;
        let (w, h) = (s#width, s#height);
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, s#fbo);
        GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 4);
        let ints = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder()).asIntBuffer();
        // BGRA + 8_8_8_8_REV = int 1 つが 0xAARRGGBB（Java の ARGB と同じ並び）。
        GL11.glReadPixels(0, 0, w, h, GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, ints);
        let pixels: Array[Int32, rc] = Array.empty(rc, w * h);
        // GL は下の行から。行ごとに上下を返して詰める。
        List.range(0, h) |> List.forEach(y -> {
            discard ints.position((h - 1 - y) * w);
            discard ints.get(pixels, y * w, w)
        });
        // 1i32 = TYPE_INT_RGB。
        let image = new BufferedImage(w, h, 1i32);
        image.setRGB(0, 0, w, h, pixels, 0, w);
        image
    }
}
