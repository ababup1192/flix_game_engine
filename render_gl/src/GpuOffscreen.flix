// GpuOffscreen — 窓を見せずに GPU で塗る session（人が見る絵だけ GPU で塗る: 会話のプレビューの 1 枚撮り）を、描き手を選んで開く。
// WebGPU は RenderPaint.Internal.WebGpuPaint を Dawn の device の上で、GL は GlOffscreen をそのまま使う。塗る道は窓ありで遊ぶ時と同じ。
// 比べ（reference-check・compare）には使わない —— GPU と SoftRaster は文字と多角形の縁が近似の関係（docs/backend-parity.md）。
//
// 使い方（open から close まで同じ糸で呼ぶ）:
//   match GpuOffscreen.open(LwjglEnv.Backend.WebGpu, { config = 読んだ project.json の config, scale = 2 }) {
//       case Err(why)   => SoftRaster の道へ（画面の無い所・WebGPU も GL も作れない）
//       case Ok(session) =>
//           GpuOffscreen.handle(session, () -> App のコマを描く);
//           let image = GpuOffscreen.readImage(session);   // 最後に塗った画面のコマ
//           GpuOffscreen.close(session)
//   }
pub mod GpuOffscreen {
    import fge.webgpu.WebGpu
    import java.awt.image.BufferedImage
    import java.lang.Throwable
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use RenderPaint.Internal.WebGpuPaint

    /// WebGPU の側の 1 本。stamps = テクスチャのファイルの (パス, 大きさ, 更新時刻)（refreshTextures が見る）。
    type alias WebGpuData = {
        gpu = WebGpu, paint = WebGpuPaint.Paint, fonts = RenderPaint.Fonts, width = Int32, height = Int32, design = Vec2.Vec2,
        stamps = Ref[Map[String, (String, Int64, Int64)], Static]
    }

    /// 開いた 1 本。外から作らせない（open だけが作る）。
    enum SessionData {
        case Gl(GlOffscreen.Session)
        case WebGpu(WebGpuData)
    }

    pub type alias Session = SessionData

    /// handle が受け持つ effect の束（GL の session と同じ）。
    pub type alias HandledEffects = GlOffscreen.HandledEffects

    /// backend の描き手で design × scale の描き先を作り、テクスチャとフォントを読む。WebGPU を開けなければ理由を 1 行言って GL で開く。
    /// どちらも作れなければ Err(理由)（呼ぶ側は SoftRaster で塗る）。
    // WhyNot: WebGPU を開けない時に Err で止めない — 窓（LwjglLayer.withLwjgl）と同じく、WebGPU の無い機械では GL で塗る。
    pub def open(backend: LwjglEnv.Backend, cfg: { config = GameEngine.EngineConfig, scale = Int32 }): Result[String, Session] \ IO =
        match backend {
            case LwjglEnv.Backend.Gl     => GlOffscreen.open(cfg) |> Result.map(SessionData.Gl)
            case LwjglEnv.Backend.WebGpu => openWebGpuOrGl(cfg)
        }

    /// WebGPU だけで開く（開けなければ Err。GL へは戻さない）。描き手が回によって替わってはいけない塗り（移行の比べの PNG）向け。
    // WhyNot: open の GL へ戻す道を通さない — 比べの記録は描き手の素性で分けるので、WebGPU を頼んで GL の絵が混ざると、
    //   同じ機械でも回によって描き手が替わる。GL は入口の頭で窓サーバへ繋いでいないと作れない（VideoOut.settingsOf）。
    pub def openWebGpuOnly(cfg: { config = GameEngine.EngineConfig, scale = Int32 }): Result[String, Session] \ IO =
        openWebGpu(cfg) |> Result.map(SessionData.WebGpu)

    /// 塗った描き手の素性（`webgpu <アダプターの名前>`・`gl`）。描き手が違う絵を比べないための印。
    pub def painterOf(session: Session): String \ IO = match session {
        case SessionData.Gl(_)     => "gl"
        case SessionData.WebGpu(w) => "webgpu ${w#gpu.adapterInfo()}"
    }

    /// 今のフォントのアトラス（名前 → アトラス。GL は字が育つと中身が変わるので、コマごとに引き直す）。
    pub def fontTable(session: Session): Map[String, FontAtlas] \ IO = match session {
        case SessionData.Gl(s)     => GlOffscreen.fontTable(s)
        case SessionData.WebGpu(w) => Ref.get(w#fonts#atlases)
    }

    /// WebGPU の誤りの数と最後の誤りの文（GL は (0, "")）。誤りの出た命令は描かれないので、0 でなければ絵は欠けている。
    pub def errorsOf(session: Session): (Int32, String) \ IO = match session {
        case SessionData.Gl(_)     => (0, "")
        case SessionData.WebGpu(w) => (w#gpu.errorCount(), w#gpu.lastError())
    }

    def openWebGpuOrGl(cfg: { config = GameEngine.EngineConfig, scale = Int32 }): Result[String, Session] \ IO =
        match openWebGpu(cfg) {
            case Ok(data) => Ok(SessionData.WebGpu(data))
            case Err(why) =>
                println("[backend] WebGPU を使えない: ${why} — GL で塗る");
                GlOffscreen.open(cfg) |> Result.map(SessionData.Gl)
        }

    /// Dawn の device を開き、塗りのコアとテクスチャ・フォントを用意する。
    def openWebGpu(cfg: { config = GameEngine.EngineConfig, scale = Int32 }): Result[String, WebGpuData] \ IO =
        match run { WebGpuDevice.requestDevice() } with WebGpuDevice.runDawn {
            case Err(why) => Err(why)
            case Ok(gpu)  => prepareWebGpu(gpu, cfg)
        }

    def prepareWebGpu(gpu: WebGpu, cfg: { config = GameEngine.EngineConfig, scale = Int32 }): Result[String, WebGpuData] \ IO =
        if (not gpu.hasCoreFeaturesAndLimits()) {
            gpu.destroy();
            Err("device に core-features-and-limits が無い")
        } else try {
            let config = cfg#config;
            let width = config#designWidth * cfg#scale;
            let height = config#designHeight * cfg#scale;
            println("[backend] webgpu: ${gpu.adapterInfo()}");
            let paint = WebGpuPaint.create(gpu, { designWidth = config#designWidth, designHeight = config#designHeight,
                                                  clearColor = config#clearColor, width = width, height = height,
                                                  scene3d = Render3d.WebGpuRenderer.makeScenes }) |> WebGpuPaint.withoutHistory;
            LwjglLayer.Internal.WebGpuWindowLayer.loadTextures(paint, config#textureManifest, (_, _) -> checked_ecast(()));
            let fonts = LwjglLayer.Internal.WebGpuWindowLayer.loadFonts(paint, config, (_, _, _) -> checked_ecast(()));
            let stamps = config#textureManifest
                |> List.foldLeft((acc, entry) -> Map.insert(entry#name, GlOffscreen.stampOf(entry#path), acc), Map.empty());
            Ok({ gpu = gpu, paint = paint, fonts = fonts, width = width, height = height,
                 design = { x = Int32.toFloat64(config#designWidth), y = Int32.toFloat64(config#designHeight) },
                 stamps = Ref.fresh(Static, stamps) })
        } catch {
            case e: Throwable =>
                gpu.destroy();
                Err("WebGPU の用意に失敗: ${e.toString()}")
        }

    /// 画面のコマの画素の大きさ。
    pub def sizeOf(session: Session): (Int32, Int32) = match session {
        case SessionData.Gl(s)     => GlOffscreen.sizeOf(s)
        case SessionData.WebGpu(w) => (w#width, w#height)
    }

    /// 片付ける。
    pub def close(session: Session): Unit \ IO = match session {
        case SessionData.Gl(s)     => GlOffscreen.close(s)
        case SessionData.WebGpu(w) =>
            WebGpuPaint.release(w#paint);
            w#gpu.destroy()
    }

    /// manifest のうち、開いた時から描き直された・足された絵を読み直す（GlOffscreen.refreshTextures と同じ見方）。戻り値は読み直した枚数。
    pub def refreshTextures(session: Session, manifest: List[RenderAsset.TextureEntry]): Int32 \ IO = match session {
        case SessionData.Gl(s)     => GlOffscreen.refreshTextures(s, manifest)
        case SessionData.WebGpu(w) => List.foldLeft((count, entry) -> count + refreshOne(w, entry), 0, manifest)
    }

    def refreshOne(w: WebGpuData, entry: RenderAsset.TextureEntry): Int32 \ IO =
        let now = GlOffscreen.stampOf(entry#path);
        let (_, size, _) = now;
        if (Map.get(entry#name, Ref.get(w#stamps)) == Some(now)) 0
        else {
            Ref.put(Map.insert(entry#name, now, Ref.get(w#stamps)), w#stamps);
            if (size < 0i64) 0
            else {
                let uploads = WebGpuPaint.webGpuUploads(w#paint);
                Option.forEach(uploads#drop, textureInfoOf(w, entry#name));
                WebGpuPaint.putTexture(entry#name, LwjglAssets.loadTexture(uploads, entry#path, entry#hasAlpha), w#paint);
                1
            }
        }

    def textureInfoOf(w: WebGpuData, name: String): Option[RenderAsset.TextureInfo] \ IO =
        WebGpuPaint.handleGpuResources(w#paint, w#fonts, () -> Platform.GpuResources.getTextureInfo(name))

    // ── 塗る ──

    /// f の中の Platform の effect と Target を、この session の描き先へ塗る形で受ける（App の 1 コマを描く口をそのまま呼べる）。
    /// 入力・カーソル・窓の問いには「何も起きていない」で答える。最後の 1 枚が描き先に残る（readImage・readRgba で読む）。
    pub def handle(session: Session, f: Unit -> a \ ef): a \ (ef - HandledEffects) + IO = match session {
        case SessionData.Gl(s)     => GlOffscreen.handle(s, f)
        case SessionData.WebGpu(w) => handleWebGpu(w, f)
    }

    // WhyNot 並びを変えない: op は内側の handler から順にたどるので、sprite ごとに呼ぶ GpuResources を一番内側に置く（GL の handle と同じ）。
    // WhyNot: コマを締める（present）のを presentFrame に任せない — App.Internal.Paint.paintOnce は presentFrame を呼ばずに描き終える。
    def handleWebGpu(w: WebGpuData, f: Unit -> a \ ef): a \ (ef - HandledEffects) + IO =
        let paint = w#paint;
        let result =
            WebGpuPaint.handleTarget(paint, () ->
            GlOffscreen.handleWindowless(w#design, () ->
            WebGpuPaint.handleDiagnostics(paint, () ->
            Platform.runTasksInPlace(() ->
            WebGpuPaint.handleDraw3d(false, paint, () ->
            WebGpuPaint.handleDraw2d(paint, (_, _, _) -> (), () ->
            WebGpuPaint.handleGpuResources(paint, w#fonts, f)))))));
        WebGpuPaint.present(paint, None);
        result

    // ── 読み戻す ──

    /// 画面のコマの大きさの読み戻しの入れ物（直のメモリ）。
    def freshBuffer(session: Session): ByteBuffer \ IO =
        let (w, h) = sizeOf(session);
        ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())

    /// 最後に塗った画面のコマを、左上原点の RGB の画像にする（PNG に書く 1 枚撮り用。GL の session と同じく α は捨てる）。
    pub def readImage(session: Session): BufferedImage \ IO = match session {
        case SessionData.Gl(s)     => GlOffscreen.readImage(s)
        case SessionData.WebGpu(w) =>
            let buf = freshBuffer(session);
            WebGpuPaint.readFrame(w#paint, buf);
            let argb = LwjglLayer.Internal.WebGpuWindowLayer.imageOf(buf, w#width, w#height);
            // 1i32 = TYPE_INT_RGB。
            let image = new BufferedImage(w#width, w#height, 1i32);
            let noArray: Array[Int32, Static] = checked_cast(null);
            image.setRGB(0, 0, w#width, w#height, argb.getRGB(0, 0, w#width, w#height, noArray, 0, w#width), 0, w#width);
            image
    }
}
