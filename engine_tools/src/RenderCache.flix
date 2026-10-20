// RenderCache — 塗った PNG を DrawHash の鍵でキャッシュに入れ、同じ鍵のコマは塗らずに写す。
//
// 置き場は FGE_RENDER_CACHE（既定 ~/.cache/flix-render-cache・"off" で使わない・"verify"（"verify:<置き場>"）で
// 毎回塗ってキャッシュと突き合わせる）。鍵が同じなら塗った PNG も同じ、なので compare の基準と今・reference-check の
// 2 回目・同じ絵が続く動画のコマで塗りを省ける。塗る道（SoftRaster）はそのまま残り、鍵が作れない時は
// 今まで通り塗る。鍵の中身と使い方は docs/render-cache.md。
pub mod RenderCache {
    import java.awt.image.BufferedImage
    import java.io.File
    import java.io.FileOutputStream
    import java.io.IOException
    import java.lang.ClassLoader
    import java.lang.Exception
    import java.lang.RuntimeException
    import java.lang.System
    import java.lang.Thread
    import java.lang.management.ManagementFactory
    import java.net.URI
    import java.nio.ByteBuffer
    import java.nio.file.Files
    import java.nio.file.Paths
    import java.security.MessageDigest
    import java.util.Arrays
    import java.util.HexFormat
    import java.util.concurrent.ConcurrentHashMap
    import java.util.concurrent.atomic.AtomicLong
    import javax.imageio.ImageIO

    /// キャッシュの使い方。
    enum Mode {
        /// 鍵がキャッシュにあれば写す。
        case Reuse
        /// 毎回塗り、キャッシュにあればバイト列を突き合わせる（違えば知らせて塗った方で置き換える）。
        case Verify
    }

    /// 1 回の描き出し（動画 1 本・GIF 1 本）で持ち回る物。中身は外から作らせない（freshSession だけ）。
    enum SessionData({
        root = Option[String],
        mode = Mode,
        engine = String,
        runtime = String,
        fileDigests = ConcurrentHashMap[String, String],
        textures = SoftRaster.TextureCache,
        atlases = DrawHash.AtlasCache,
        painted = AtomicLong,
        reused = AtomicLong,
        uncached = AtomicLong,
        mismatched = AtomicLong
    })

    /// キャッシュの口。コマ列の前に 1 本作って持ち回る（TTF の指紋を 1 回だけ読む）。
    /// 寿命は SoftRaster.TextureCache と同じく 1 回の描き出しの間だけにする。
    pub type alias Session = SessionData

    /// キャッシュの口を作る（置き場・エンジンの fpkg の指紋・JVM と OS を読む）。
    pub def freshSession(): Session \ IO =
        let (root, mode) = settings();
        SessionData.SessionData({
            root = root,
            mode = mode,
            engine = engineDigest(),
            runtime = runtimeId(),
            fileDigests = new ConcurrentHashMap(),
            textures = SoftRaster.freshTextureCache(),
            atlases = DrawHash.freshAtlasCache(),
            painted = new AtomicLong(0i64),
            reused = new AtomicLong(0i64),
            uncached = new AtomicLong(0i64),
            mismatched = new AtomicLong(0i64)
        })

    /// 塗った・写した・鍵なしで塗った枚数を 1 行に（描き出しの終わりに出す）。
    pub def statsLine(session: Session): String \ IO =
        let SessionData.SessionData(s) = session;
        let place = match s#root {
            case Some(dir) => dir
            case None      => "使わない"
        };
        let verify = match s#mode {
            case Mode.Verify => "・突き合わせで違った ${Int64.toString(s#mismatched.get())}"
            case Mode.Reuse  => ""
        };
        "[render-cache] 塗った ${Int64.toString(s#painted.get())}・写した ${Int64.toString(s#reused.get())}"
            + "・鍵なしで塗った ${Int64.toString(s#uncached.get())}${verify}（置き場 ${place}）"

    /// 動画・GIF のコマを 1 枚 req#outPath へ書く（Filmstrip.renderFrame と同じバイト列）。
    /// 引数は SoftRaster.renderToImageCached と同じ。鍵がキャッシュにあれば塗らずに写す。
    pub def writeFramePng(session: Session, req: SoftRaster.RasterReq, surfaces: List[SoftRaster.SurfaceCmd],
                          extraFonts: Map[String, SoftRaster.FontEntry],
                          extraImages: Map[String, BufferedImage],
                          warnLog: SoftRaster.TexWarnLog, textures: SoftRaster.TextureCache): Unit \ IO =
        writePng(session, DrawHash.PngEncoding.Filmstrip,
                 { req = req, surfaces = surfaces, extraFonts = extraFonts, fontAntialias = Map.empty() }, extraImages, warnLog, textures)

    /// SoftRaster.render* の書き方（フルカラー）で req#outPath へ書く。SoftRaster.render* の中身。
    pub def writePlainPng(req: SoftRaster.RasterReq, surfaces: List[SoftRaster.SurfaceCmd],
                          extraFonts: Map[String, SoftRaster.FontEntry],
                          extraImages: Map[String, BufferedImage]): Unit \ IO =
        writePlainPngAntialias(req, surfaces, extraFonts, Map.empty(), extraImages)

    /// writePlainPng の、字の縁を本ごとに決める表（SoftRaster.FontAntialias）つき版。
    pub def writePlainPngAntialias(req: SoftRaster.RasterReq, surfaces: List[SoftRaster.SurfaceCmd],
                                   extraFonts: Map[String, SoftRaster.FontEntry], fontAntialias: SoftRaster.FontAntialias,
                                   extraImages: Map[String, BufferedImage]): Unit \ IO =
        let session = freshSession();
        let SessionData.SessionData(s) = session;
        writePng(session, DrawHash.PngEncoding.Plain,
                 { req = req, surfaces = surfaces, extraFonts = extraFonts, fontAntialias = fontAntialias }, extraImages,
                 SoftRaster.freshTexWarnLog(), s#textures)

    /// 1 コマの鍵（writeFramePng がキャッシュに使うのと同じ物）。鍵を作れなければ None。
    /// テクスチャの指紋は `textures` の中の画像（塗る時に使う物）から取る。
    pub def keyOf(session: Session, encoding: DrawHash.PngEncoding, frame: DrawHash.Frame,
                  extraImages: Map[String, BufferedImage], textures: SoftRaster.TextureCache): Option[DrawHash.Key] \ IO =
        let SessionData.SessionData(s) = session;
        let used = DrawHash.usedTextures(frame);
        let texturePaths = frame#req#texturePath
            |> Map.filterWithKey((name, _) -> Set.memberOf(name, used)) |> Map.valuesOf |> List.toSet;
        try {
            let files = DrawHash.filesOf(frame) |> List.filterMap(p -> {
                let digest = if (Set.memberOf(p, texturePaths)) Some(textureDigest(textures, p))
                             else fileDigest(s#fileDigests, p);
                digest |> Option.map(d -> (p, d))
            }) |> List.toMap;
            let images = extraImages
                |> Map.filterWithKey((name, _) -> Set.memberOf(name, used))
                |> Map.map(imageDigest);
            DrawHash.computeKeyCached(s#atlases, { engine = s#engine, runtime = s#runtime, files = files, images = images }, encoding, frame)
        } catch {
            case ex: RuntimeException =>
                warnOnce("key", "鍵を作れない（${ex.getMessage()}）— その絵は塗る");
                None
        }

    // WhyNot: 鍵と塗りを別の関数に分けない — 鍵に入れる値（frame・extraImages・textures）と塗りに渡す値が
    // 同じ 1 か所から出ていないと、塗りにだけ入力を足して鍵に入れ忘れる（偽の緑）。
    def writePng(session: Session, encoding: DrawHash.PngEncoding, frame: DrawHash.Frame,
                 extraImages: Map[String, BufferedImage],
                 warnLog: SoftRaster.TexWarnLog, textures: SoftRaster.TextureCache): Unit \ IO =
        let SessionData.SessionData(s) = session;
        let outPath = frame#req#outPath;
        let paint = () -> SoftRaster.renderToImageCachedAntialias(frame#req, frame#surfaces, frame#extraFonts, frame#fontAntialias,
                                                                  extraImages, warnLog, textures);
        let key = match s#root {
            case None    => None
            case Some(_) => keyOf(session, encoding, frame, extraImages, textures)
        };
        match (s#root, key) {
            case (Some(dir), Some(k)) =>
                let stored = storedPath(dir, k);
                let reusable = match s#mode {
                    case Mode.Reuse  => new File(stored).isFile() and copyFile(stored, outPath)
                    case Mode.Verify => false
                };
                if (reusable) {
                    discard new File(stored).setLastModified(System.currentTimeMillis());
                    discard s#reused.incrementAndGet()
                } else {
                    let image = paint();
                    discard s#painted.incrementAndGet();
                    // キャッシュへは塗った画像を符号化したバイト列を直接入れ、outPath はそこから写す
                    // （outPath を読み直すと、書き損ねた前の中身を新しい鍵でキャッシュに入れてしまう）。
                    if (putIntoStore(s#mismatched, encoding, image, stored) and copyFile(stored, outPath)) ()
                    else encode(encoding, image, outPath)
                }
            case _ =>
                encode(encoding, paint(), outPath);
                discard s#uncached.incrementAndGet()
        }

    def encode(encoding: DrawHash.PngEncoding, image: BufferedImage, path: String): Unit \ IO = match encoding {
        case DrawHash.PngEncoding.Plain     => AtomicFile.write(path, file -> discard ImageIO.write(image, "png", file))
        case DrawHash.PngEncoding.Filmstrip => Filmstrip.renderFrame(image, path)
    }

    // ── 絵でない書き出しの一式（効果音の WAV など） ─────────

    /// 前に inputs から書いた一式（noteWrittenFiles で控えた物）が、そのままのバイト列で残っているか。
    /// 残っていれば true（作り直さなくてよい）。鍵には inputs と、動いているプログラム（jar）の指紋・JVM と OS が入る。
    /// 置き場が無い・鍵を作れない（jar から動いていない）・verify の時は false（いつも作る）。
    pub def writtenFilesKept(inputs: String): Bool \ IO =
        let (root, mode) = settings();
        match (mode, filesStampPath(root, inputs)) {
            case (Mode.Reuse, Some(stamp)) =>
                try {
                    let file = new File(stamp);
                    if (not file.isFile()) false
                    else {
                        let lines = String.lines(Files.readString(file.toPath()));
                        let kept = not List.isEmpty(lines) and List.forAll(fileMatchesLine, lines);
                        if (kept) discard file.setLastModified(System.currentTimeMillis()) else ();
                        kept
                    }
                } catch {
                    case ex: IOException => warnOnce("files-read", "一式の控えを読めない（${ex.getMessage()}）— 作り直す"); false
                }
            case _ => false
        }

    /// files（パスの列）を inputs から書いたと控える（次の writtenFilesKept が当たるように）。
    /// verify の時は前の控えと突き合わせ、違えば知らせる（鍵に入っていない入力がある）。
    pub def noteWrittenFiles(inputs: String, files: List[String]): Unit \ IO =
        let (root, mode) = settings();
        match filesStampPath(root, inputs) {
            case None        => ()
            case Some(stamp) =>
                try {
                    let lines = files |> List.map(p -> "${sha256(Files.readAllBytes(Paths.get(p)))} ${p}");
                    let text = String.intercalate("\n", lines);
                    let target = new File(stamp);
                    discard target.getParentFile().mkdirs();
                    let verifying = match mode {
                        case Mode.Verify => target.isFile()
                        case Mode.Reuse  => false
                    };
                    if (verifying and Files.readString(target.toPath()) != text)
                        Log.warn("[render-cache] 前に同じ鍵で書いた一式と違う: ${stamp} — 今の方で置き換える（鍵に入っていない入力がある）")
                    else ();
                    let bytes = text.getBytes("UTF-8");
                    AtomicFile.write(stamp, tmp -> discard writeBytes(tmp, bytes))
                } catch {
                    case ex: IOException => warnOnce("files-write", "一式の控えを書けない（${ex.getMessage()}）— 次も作り直す")
                }
        }

    /// 控えの 1 行（"<SHA-256> <パス>"）のファイルが、今もその中身か。
    def fileMatchesLine(line: String): Bool \ IO =
        match String.splitOn(substr = " ", line) {
            case digest :: rest =>
                let path = String.intercalate(" ", rest);
                let file = new File(path);
                not String.isEmpty(path) and file.isFile() and sha256(Files.readAllBytes(file.toPath())) == digest
            case Nil => false
        }

    /// inputs の一式の控えの置き場。置き場が無い・プログラムの指紋が無い時は None。
    def filesStampPath(root: Option[String], inputs: String): Option[String] \ IO =
        match root {
            case None      => None
            case Some(dir) =>
                let program = programDigest();
                if (String.isEmpty(program)) {
                    warnOnce("files-program", "jar から動いていない（flix run・テスト）— 書き出しの一式はいつも作る");
                    None
                } else {
                    let key = sha256("files;${program};${runtimeId()};${inputs}".getBytes("UTF-8"));
                    Some("${dir}/files/${String.takeLeft(2, key)}/${key}.txt")
                }
        }

    /// 動いているプログラム（Main.class を持つ jar）の SHA-256。JVM の中で 1 回だけ取る。
    /// jar から動いていない（flix run は組んだクラスをメモリに持つ）・JVM が起きた後に jar が差し替わった時は空。
    // WhyNot: エンジンの fpkg の指紋（engineDigest）で済ませない — 書き出す中身はゲームのコードでも決まる。
    def programDigest(): String \ IO =
        let memoKey = "fge.renderCache.program";
        let memo = System.getProperty(memoKey);
        if (not Object.isNull(memo)) memo
        else {
            let digest = loadProgramDigest();
            discard System.setProperty(memoKey, digest);
            digest
        }

    def loadProgramDigest(): String \ IO =
        let url = ClassLoader.getSystemResource("Main.class");
        if (Object.isNull(url) or url.getProtocol() != "jar") ""
        else try {
            let spec = url.getPath();
            let cut = String.indexOf(substr = "!/", spec) |> Option.getWithDefault(String.length(spec));
            let jar = Paths.get(new URI(String.takeLeft(cut, spec))).toFile();
            let started = ManagementFactory.getRuntimeMXBean().getStartTime();
            if (not jar.isFile() or jar.lastModified() > started) ""
            else sha256(Files.readAllBytes(jar.toPath()))
        } catch {
            case ex: Exception => warnOnce("program", "動いている jar を読めない（${ex.getMessage()}）— 書き出しの一式はいつも作る"); ""
        }

    // ── 置き場 ───────────────────────────────────────────

    /// 置き場と使い方。相対パスは使わない（JVM とゲームの根・fge の居場所で指す所が変わる）。
    def settings(): (Option[String], Mode) \ IO =
        // WhyNot: 引数で受けない — SoftRaster.render* の奥で 1 枚ごとに呼ばれるので、通すと描き出しの pub の口の型が
        // 全部変わる。常駐はこのキーを起動時に通し、要求の値と違えば立て直す（go/internal/resident の renderCacheKey）。
        let env = Map.get("FGE_RENDER_CACHE", ProcessEnv.snapshot()) |> Option.getWithDefault("");
        let home = "${System.getProperty("user.home")}/.cache/flix-render-cache";
        if (String.isEmpty(env)) (Some(home), Mode.Reuse)
        else if (env == "off" or env == "0") (None, Mode.Reuse)
        else if (env == "verify") (Some(home), Mode.Verify)
        else if (String.startsWith(prefix = "verify:", env) and new File(String.dropLeft(7, env)).isAbsolute())
            (Some(String.dropLeft(7, env)), Mode.Verify)
        else if (new File(env).isAbsolute()) (Some(env), Mode.Reuse)
        else {
            warnOnce("relative", "FGE_RENDER_CACHE=${env} は絶対パスではないので使わない — いつも塗る");
            (None, Mode.Reuse)
        }

    def storedPath(dir: String, key: DrawHash.Key): String =
        let hex = DrawHash.toHex(key);
        "${dir}/${String.takeLeft(2, hex)}/${hex}.png"

    /// src を dst へ写す（dst は書き終えてから置き換える）。写せなければ false。
    def copyFile(src: String, dst: String): Bool \ IO =
        try {
            let bytes = Files.readAllBytes(Paths.get(src));
            let ok = new AtomicLong(0i64);
            AtomicFile.write(dst, tmp -> if (writeBytes(tmp, bytes)) discard ok.incrementAndGet() else ());
            ok.get() == 1i64 and new File(dst).length() == Int32.toInt64(Array.length(bytes))
        } catch {
            case ex: IOException => warnOnce("read", "キャッシュを読めない（${ex.getMessage()}）— 塗る"); false
        }

    def writeBytes(file: File, bytes: Array[Int8, Static]): Bool \ IO =
        let sink = new FileOutputStream(file);
        let ok = try { sink.write(bytes); true } catch { case _: IOException => false };
        sink.close();
        ok

    /// 塗った画像をキャッシュへ入れる。前のキャッシュ（Verify で塗り直した時）と違えば知らせる。
    /// 入れられなければ false（呼ぶ側が outPath へ直接書く）。
    // WhyNot: キャッシュの名前へ AtomicFile.write で直接書かない — 書く前に同じ名前の一時ファイルを消すので、
    // 同じ鍵のコマを 2 本の糸が同時に入れると、相手の書きかけを消し合う。糸ごとに別の名前で書いてから移す。
    def putIntoStore(mismatched: AtomicLong, encoding: DrawHash.PngEncoding, image: BufferedImage, stored: String): Bool \ IO =
        let target = new File(stored);
        let part = "${stored}.${Int64.toString(System.nanoTime())}-${Int64.toString(Thread.currentThread().threadId())}.part";
        try {
            discard target.getParentFile().mkdirs();
            encode(encoding, image, part);
            let fresh = new File(part);
            if (not fresh.isFile()) false
            else {
                if (target.isFile() and not Arrays.equals(Files.readAllBytes(target.toPath()), Files.readAllBytes(fresh.toPath()))) {
                    discard mismatched.incrementAndGet();
                    Log.warn("[render-cache] キャッシュと塗った絵が違う: ${stored} — 塗った方で置き換える（鍵に入っていない入力がある）")
                } else ();
                if (fresh.renameTo(target)) true
                else { discard fresh.delete(); target.isFile() }
            }
        } catch {
            case ex: IOException =>
                discard new File(part).delete();
                warnOnce("write", "キャッシュへ書けない（${ex.getMessage()}）— 塗った絵を直接書く");
                false
        }

    // ── 命令に出ない入力の指紋 ──────────────────────────

    /// テクスチャの指紋 = 塗る時に使うキャッシュの中の画像の画素（無いファイルは "missing"）。
    // WhyNot: ファイルのバイト列を別に読まない — 鍵と塗りが別の時点で読むと、その間に保存された絵が
    // 古い中身の鍵の下に入る。塗りが見る画像そのものから取る。
    def textureDigest(cache: SoftRaster.TextureCache, path: String): String \ IO =
        let SoftRaster.TextureCache.TextureCache(_, memo, _) = cache;
        let hit: String = memo.get(path);
        if (not Object.isNull(hit)) hit
        else {
            let digest = match SoftRaster.cachedTexture(cache, path) {
                case Some(img) => imageDigest(img)
                case None      => "missing"
            };
            discard memo.putIfAbsent(path, digest);
            memo.get(path)
        }

    /// TTF の中身の SHA-256（無いファイルは "missing"）。読めなければ None（鍵を作らない）。
    def fileDigest(memo: ConcurrentHashMap[String, String], path: String): Option[String] \ IO =
        let hit: String = memo.get(path);
        if (not Object.isNull(hit)) Some(hit)
        else {
            let file = new File(path);
            let digest = if (not file.exists()) Some("missing")
                else try { Some(sha256(Files.readAllBytes(file.toPath()))) }
                catch { case ex: IOException => warnOnce("ttf", "${path} を読めない（${ex.getMessage()}）— 鍵を作らず塗る"); None };
            digest |> Option.forEach(d -> discard memo.put(path, d));
            digest
        }

    /// 描き出し済み画像の画素の SHA-256（型・幅・高さも入れる）。
    def imageDigest(image: BufferedImage): String \ IO = region rc {
        let w = image.getWidth();
        let h = image.getHeight();
        let md = MessageDigest.getInstance("SHA-256");
        md.update("${Int32.toString(image.getType())}:${Int32.toString(w)}x${Int32.toString(h)}".getBytes("UTF-8"));
        let row = Array.repeat(rc, w, 0);
        let bytes = ByteBuffer.allocate(w * 4);
        List.range(0, h) |> List.forEach(y -> {
            discard image.getRGB(0, y, w, 1, row, 0, w);
            discard bytes.clear();
            discard bytes.asIntBuffer().put(row);
            md.update(bytes.array())
        });
        HexFormat.of().formatHex(md.digest())
    }

    /// ゲームの lib/ にあるエンジンの fpkg（flix.toml が指す版）の SHA-256。JVM の中で 1 回だけ取る。
    /// 見つからない・JVM が起きた後に差し替わった時は空（鍵を作らない = いつも塗る）。
    // WhyNot: エンジンの版の字（0.49.0）を使わない — use-engine でブランチの作業場へ向けると、
    // 版の字は同じまま SoftRaster が変わる。組んだ物そのものの指紋を使う。
    // WhyNot: 呼ぶたびに読み直さない — 起動したままの JVM（make run・窓なしの常駐）の裏で fpkg を
    // 組み直すと、古いコードで塗った絵を新しい fpkg の鍵でキャッシュに入れてしまう。
    def engineDigest(): String \ IO =
        let memoKey = "fge.renderCache.engine";
        let memo = System.getProperty(memoKey);
        if (not Object.isNull(memo)) memo
        else {
            let digest = loadEngineDigest();
            discard System.setProperty(memoKey, digest);
            digest
        }

    def loadEngineDigest(): String \ IO =
        let toml = new File("flix.toml");
        if (not toml.isFile()) ""
        else try {
            match engineVersionOf(Files.readString(toml.toPath())) {
                case None          => ""
                case Some(version) =>
                    let fpkg = new File("lib/github/ababup1192/flix_game_engine/${version}/flix_game_engine-${version}.fpkg");
                    let started = ManagementFactory.getRuntimeMXBean().getStartTime();
                    if (not fpkg.isFile()) {
                        warnOnce("fpkg", "${fpkg.getPath()} が無い — 鍵を作らず塗る");
                        ""
                    } else if (fpkg.lastModified() > started) {
                        warnOnce("fpkg", "${fpkg.getPath()} が JVM の起動より新しい（動いているコードと違う）— 鍵を作らず塗る");
                        ""
                    } else sha256(Files.readAllBytes(fpkg.toPath()))
            }
        } catch {
            case ex: IOException => warnOnce("fpkg", "エンジンの fpkg を読めない（${ex.getMessage()}）— 鍵を作らず塗る"); ""
        }

    /// flix.toml の依存の行 `"github:ababup1192/flix_game_engine" = { version = "x.y.z", … }` の版。
    def engineVersionOf(toml: String): Option[String] =
        String.lines(toml)
            |> List.find(line -> String.contains(substr = "\"github:ababup1192/flix_game_engine\"", line))
            |> Option.flatMap(line -> String.splitOn(substr = "version", line) |> List.drop(1) |> List.head)
            |> Option.flatMap(rest -> String.splitOn(substr = "\"", rest) |> List.drop(1) |> List.head)
            |> Option.filter(v -> not String.isEmpty(v))

    /// JVM と OS と起動旗（Java2D の文字と縁の塗りは JDK・OS・旗で変わりうる）。
    def runtimeId(): String \ IO =
        let props = ("java.vendor" :: "java.runtime.version" :: "java.vm.version" :: "os.name" :: "os.version"
                     :: "os.arch" :: "java.awt.headless" :: "sun.java2d.uiScale" :: Nil)
            |> List.map(k -> { let v = System.getProperty(k); "${k}=${if (Object.isNull(v)) "" else v}" });
        let flags = ManagementFactory.getRuntimeMXBean().getInputArguments().toString();
        String.intercalate(";", props) + ";args=" + flags

    def sha256(bytes: Array[Int8, Static]): String \ IO =
        HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes))

    /// 既定値で続けたことを、理由ごとに JVM で 1 回だけ知らせる（コマごとに同じ行を並べない）。
    def warnOnce(reason: String, line: String): Unit \ IO =
        let flag = "fge.renderCache.warned.${reason}";
        if (Object.isNull(System.getProperty(flag))) {
            discard System.setProperty(flag, "1");
            Log.warn("[render-cache] ${line}")
        } else ()
}
