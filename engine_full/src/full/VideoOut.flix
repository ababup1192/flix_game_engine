// VideoOut — 動画のコマを書き出す 1 つの口。塗る物（GPU か SoftRaster）を選び、どちらでも 1 コマごとの鍵（drawhash.txt）と
// コマの表（frames.json）を同じ形で書く。人が見る動画は GPU で塗って、生の画素を ffmpeg へ流す（PNG を通さない）。
// 比べ（compare・reference-check）には SoftRaster の絵と鍵だけを使う（GL の絵は鍵の約束の外。docs/design/render-speed.md 3.5 節）。
//
// 書く物（outDir の中）:
//   GPU      : frames.mkv（ffv1 の可逆・上下はここで直す）・last.png（最後のコマ）・drawhash.txt・frames.json
//   SoftRaster: f0000.png …（今まで通りの連番）・drawhash.txt・frames.json
//   鍵だけ    : drawhash.txt・frames.json（painter=none。FGE_VIDEO_PAINT=none の compare の 1 回目）
//
// 鍵はどの塗り方でも SoftRaster の描く命令（HeadlessFont の字）から作るので、GPU・SoftRaster・画面の無い所で同じになる。
// GL の道は場面を組み直す（GL のフォントのアトラスで scene を呼ぶ）—— 字の並びがアトラスで決まるため。
//
// 環境変数（入口の頭で読んだ表を settingsOf に渡す）:
//   FGE_GPU=auto|on|off          auto（既定）は GPU を試し、駄目なら SoftRaster にして 1 行知らせる
//   FGE_VIDEO_PAINT=all|none|frames:A-B[,C-D]  塗るコア（既定 all）。all 以外は SoftRaster で塗る
//   FFMPEG                       GPU の道で使う ffmpeg（既定は PATH の ffmpeg）
pub mod VideoOut {
    import java.io.File
    import java.io.FileWriter
    import java.io.OutputStream
    import java.lang.Process
    import java.lang.ProcessBuilder
    import java.lang.ProcessBuilder$Redirect
    import java.lang.Throwable
    import java.nio.ByteBuffer
    import java.util.concurrent.ConcurrentHashMap
    import javax.imageio.ImageIO

    /// 何で塗ったか（frames.json の painter）。
    pub enum Painter with Eq, ToString {
        case Gl
        case Soft
        /// 鍵だけを流して塗らなかった（FGE_VIDEO_PAINT=none）
        case KeysOnly
    }

    /// 塗るコマ（FGE_VIDEO_PAINT）。
    pub enum PaintRange with Eq {
        case All
        case Nothing
        /// 両端を含むコマ番号の範囲の列
        case Frames(List[(Int32, Int32)])
    }

    /// 入口の頭で環境変数から作る設定。
    pub type alias Settings = { gpu = GpuShot.Mode, paint = PaintRange, ffmpeg = String }

    /// 環境変数の表から。**入口の頭（AWT を使う前）で呼ぶ** —— GPU で塗る回は、ここで窓サーバへの繋がりを先に取る
    /// （GlOffscreen.connect。AWT の後では GL の文脈が作れない）。
    pub def settingsOf(env: Map[String, String]): Settings \ IO =
        let settings = { gpu = GpuShot.modeOf(env),
                         paint = paintRangeOf(Map.getWithDefault("FGE_VIDEO_PAINT", "all", env)),
                         ffmpeg = Map.getWithDefault("FFMPEG", "ffmpeg", env) };
        if (settings#gpu != GpuShot.Mode.Off and settings#paint == PaintRange.All) GlOffscreen.connect() else ();
        settings

    /// `all`・`none`・`frames:227-640,700-710`。読めない字は all。
    pub def paintRangeOf(text: String): PaintRange =
        if (text == "none") PaintRange.Nothing
        else match String.stripPrefix({substr = "frames:"}, text) {
            case None       => PaintRange.All
            case Some(rest) =>
                let ranges = String.splitOn({substr = ","}, rest) |> List.filterMap(part ->
                    match String.splitOn({substr = "-"}, part) {
                        case a :: b :: Nil => forM (lo <- Int32.fromString(String.trim(a)); hi <- Int32.fromString(String.trim(b))) yield (lo, hi)
                        case a :: Nil      => Int32.fromString(String.trim(a)) |> Option.map(n -> (n, n))
                        case _             => None
                    });
                PaintRange.Frames(ranges)
        }

    def paints(range: PaintRange, index: Int32): Bool = match range {
        case PaintRange.All          => true
        case PaintRange.Nothing      => false
        case PaintRange.Frames(list) => List.exists(r -> { let (lo, hi) = r; index >= lo and index <= hi }, list)
    }

    /// ファイルの無い絵（ドット絵のアトラス）。SoftRaster へは PNG に落として texturePath で、GPU へは画素で載せる。
    pub type alias Image = { name = String, side = Int32, pixelAt = (Int32, Int32) -> Int32 }

    /// 1 本の動画。soft = SoftRaster の設定（design・scale・地の色・字・絵のパス）、softFonts = SoftRaster の字のアトラス
    /// （名前 → HeadlessFont のアトラス）、scene = 字のアトラスの引き口 → World → 絵（GPU では GL のアトラスで呼ぶ）、
    /// wanted = 書くコマ（一部だけ描き直す口。全部でない時は SoftRaster で塗る）。
    /// bakeSurfaces = SoftRaster ではシェーダー面を最初に出たコマで 1 回だけ塗って PNG に書き出し、以降は貼るだけにする
    /// （面の画素の評価が 1 コマ数秒かかる動画用。時刻で変わらない面だけに使う —— 絵は 1 枚目のまま止まる）。
    /// GPU では面をいつも通りコマごとに塗る（速いので書き出さない）。鍵はどちらも書き出した面を貼る SoftRaster の命令から作る。
    pub type alias Video[w] = {
        outDir = String,
        fps = Int32,
        soft = HeadlessRender.RenderConfig,
        softFonts = String -> FontAtlas,
        extraFonts = Map[String, SoftRaster.FontEntry],
        images = List[Image],
        scene = (String -> FontAtlas) -> w -> List[Render.PlacedItem],
        wanted = Int32 -> Bool,
        bakeSurfaces = Bool
    }

    /// 書き出した面: 名前（surface_<幅>_<高さ>_<z>）→ (PNG のパス, 書き出した範囲に合わせた面)。
    type alias Baked = Map[String, (String, Render.ShaderSurface)]

    /// コマを書き、frames.json と drawhash.txt を添える。何で塗ったかを返す。
    pub def writeFrames(settings: Settings, video: Video[w], worlds: List[w]): Painter \ IO =
        discard (new File(video#outDir)).mkdirs();
        let jobs = worlds |> List.zipWithIndex |> List.filter(p -> video#wanted(fst(p)));
        let all = List.length(jobs) == List.length(worlds);
        // 面を書き出す回は、塗る前に順に書き出しておく（どの糸からも読むだけにする）。
        let baked = if (video#bakeSurfaces and settings#paint != PaintRange.Nothing) bakeAll(video, jobs) else Map.empty();
        let chosen =
            if (settings#paint == PaintRange.Nothing) Painter.KeysOnly
            else if (settings#gpu == GpuShot.Mode.Off or settings#paint != PaintRange.All or not all) Painter.Soft
            else Painter.Gl;
        let (painter, keys) = match chosen {
            case Painter.Gl => match writeGl(settings, video, baked, jobs) {
                case Ok(keys) => (Painter.Gl, keys)
                case Err(why) =>
                    if (settings#gpu == GpuShot.Mode.On) bug!("[video] FGE_GPU=on だが GPU で塗れない: ${why}")
                    else {
                        println("[video] GPU が使えない: ${why} — SoftRaster で塗る");
                        (Painter.Soft, writeSoft(settings#paint, video, baked, jobs))
                    }
            }
            case Painter.Soft     => (Painter.Soft, writeSoft(settings#paint, video, baked, jobs))
            case Painter.KeysOnly => (Painter.KeysOnly, writeSoft(PaintRange.Nothing, video, baked, jobs))
        };
        writeKeys(video#outDir, keys);
        writeFramesJson(video, settings#paint, painter, jobs, keys);
        painter

    // ── 鍵（どの塗り方でも SoftRaster の命令から）──

    /// SoftRaster の 1 コマ（鍵と SoftRaster の塗りに同じ値を渡す）。
    /// 面を書き出す回（video#bakeSurfaces）は、面を書き出した PNG の貼り絵に替え、その PNG を texturePath に足す。
    def softFrame(video: Video[w], baked: Baked, index: Int32, world: w): DrawHash.Frame =
        let cfg = video#soft;
        let scene = video#scene;
        let items0 = scene(video#softFonts)(world);
        let (items, surfaces, info, paths) =
            if (video#bakeSurfaces) {
                let found = Render.shaderSurfaces(items0);
                // 書き出した PNG は出力の画素（design の scale 倍）なので、貼るときは 1 / scale に縮める。
                let shrink = 1.0 / Int32.toFloat64(cfg#scale);
                let pasted = found |> List.map(sc -> {
                    let item = match Render.sprite(surfaceName(sc), sc#zIndex) {
                        // 面の rect は左上で置くので、貼り絵も左上で置く（Render.sprite の既定は真ん中で置く —— そのままだと
                        // 面の半分の大きさだけ左上へずれて、机や紙の面が欠ける）。
                        case Render.Item.Sprite(sp) => Render.Item.Sprite({ scale = { x = shrink, y = shrink }, centered = false | sp })
                        case other                  => other
                    };
                    { at = sc#rect#position, item = item } });
                let infoOf = (name: String) -> match Map.get(name, baked) {
                    case Some((_, sc)) => Some({ id = GpuHandle.wrapTextureId(0),
                                                 width = sc#rect#size#x * Int32.toFloat64(cfg#scale),
                                                 height = sc#rect#size#y * Int32.toFloat64(cfg#scale) })
                    case None          => HeadlessRender.imageTextureInfo(video#images)(name)
                };
                let withBaked = Map.foldLeftWithKey((acc, name, entry) -> Map.insert(name, fst(entry), acc), cfg#texturePath, baked);
                (List.append(pasted, Render.withoutShaders(items0)), Nil, infoOf, withBaked)
            } else (Render.withoutShaders(items0), Render.shaderSurfaces(items0), HeadlessRender.imageTextureInfo(video#images), cfg#texturePath);
        let (drawables, polygons) = Render.drawWith(info, items);
        let req = { drawables = drawables, polygons = polygons,
                    design = cfg#design, scale = cfg#scale, background = cfg#background,
                    texturePath = paths, fontTtf = cfg#fontTtf,
                    fontAtlas = cfg#fontAtlas, outPath = framePath(video#outDir, index),
                    shapeAntialias = cfg#shapeAntialias, textAntialias = cfg#textAntialias };
        // 字の縁の表は RenderCache.writeFramePng と同じ空（鍵と SoftRaster の塗りを同じ値から出す）。
        { req = req, surfaces = surfaces, extraFonts = video#extraFonts, fontAntialias = Map.empty() }

    /// 面の名前（同じ大きさ・z の面は同じ PNG。揺れて位置だけ変わった面は貼り直すだけでよい —— 面の絵は rect の中の uv で決まる）。
    def surfaceName(sc: Render.ShaderSurface): String =
        let r = sc#rect;
        "surface_${Int32.toString(roundInt(r#size#x))}_${Int32.toString(roundInt(r#size#y))}_${Int32.toString(sc#zIndex)}"

    def roundInt(v: Float64): Int32 = Float64.tryToInt32(Float64.round(v)) |> Option.getWithDefault(0)

    /// コマの順に面を見て、初めて出た名前の面だけを書き出す（SoftRaster で面 1 枚だけを塗り、面の範囲を切り抜いて outDir に PNG で）。
    def bakeAll(video: Video[w], jobs: List[(Int32, w)]): Baked \ IO =
        let scene = video#scene;
        let warnLog = SoftRaster.freshTexWarnLog();
        let textures = SoftRaster.freshTextureCache();
        jobs |> List.foldLeft((acc, p) -> {
            let (_, w) = p;
            Render.shaderSurfaces(scene(video#softFonts)(w)) |> List.foldLeft((done, sc) -> {
                let name = surfaceName(sc);
                if (Map.memberOf(name, done)) done
                else Map.insert(name, bakeOne(video, warnLog, textures, name, sc), done)
            }, acc)
        }, Map.empty())

    def bakeOne(video: Video[w], warnLog: SoftRaster.TexWarnLog, textures: SoftRaster.TextureCache,
                name: String, sc: Render.ShaderSurface): (String, Render.ShaderSurface) \ IO =
        let cfg = video#soft;
        let r = sc#rect;
        let req = { drawables = Nil, polygons = Nil,
                    design = cfg#design, scale = cfg#scale, background = cfg#background,
                    texturePath = cfg#texturePath, fontTtf = cfg#fontTtf,
                    fontAtlas = cfg#fontAtlas, outPath = "",
                    shapeAntialias = cfg#shapeAntialias, textAntialias = cfg#textAntialias };
        let full = SoftRaster.renderToImageCached(req, sc :: Nil, video#extraFonts, Map.empty(), warnLog, textures);
        // 面の位置と大きさは design px。書き出した絵は出力の画素なので scale 倍で切り抜く。
        let px = v -> roundInt(v * Int32.toFloat64(cfg#scale));
        let x = Int32.max(0, px(r#position#x));
        let y = Int32.max(0, px(r#position#y));
        let width = Int32.max(1, Int32.min(full.getWidth() - x, px(r#size#x)));
        let height = Int32.max(1, Int32.min(full.getHeight() - y, px(r#size#y)));
        // 面の PNG は動画のフォルダごとに置く（同じパスを動画ごとに書き直すと、テクスチャのキャッシュが前の面を貼る）。
        let path = "${video#outDir}/${name}.png";
        discard ImageIO.write(full.getSubimage(x, y, width, height), "png", new File(path));
        let design = v -> Int32.toFloat64(v) / Int32.toFloat64(cfg#scale);
        (path, { rect = { position = { x = design(x), y = design(y) }, size = { x = design(width), y = design(height) } } | sc })

    /// 進みの行を何コマごとに出すか。
    // WhyNot: 書き終わるまで黙らない —— 常駐（bin/fge resident）は出力の行が HEADLESS_SILENT_SECS（既定 120 秒）来ないと
    // 止まったと見なして落とす。910 コマの動画は SoftRaster で書くだけで数分かかる。
    def progressEvery(): Int32 = 60

    def noteProgress(dir: String, index: Int32): Unit \ IO =
        if (Int32.modulo(index, progressEvery()) == 0) println("[video] ${dir}: ${Int32.toString(index)} コマ目を書く") else ()

    def framePath(dir: String, index: Int32): String =
        "${dir}/f${String.padLeft(4, '0', Int32.toString(index))}.png"

    /// 「コマ番号 鍵」（鍵が作れないコマは -）の行。
    def writeKeys(dir: String, keys: Map[Int32, String]): Unit \ IO =
        let out = new FileWriter("${dir}/drawhash.txt");
        Map.forEach((i, key) -> out.write("${Int32.toString(i)} ${key}\n"), keys);
        out.close()

    // ── SoftRaster ──

    /// 何本の糸で並べて描くか（コマは互いに独立なので、糸を分けても絵は変わらない）。
    def lanes(): Int32 = 4

    /// SoftRaster で塗る（paint が真のコマだけ）。全部のコマの鍵を返す。
    def writeSoft(paint: PaintRange, video: Video[w], baked: Baked, jobs: List[(Int32, w)]): Map[Int32, String] \ IO =
        let session = RenderCache.freshSession();
        let warnLog = SoftRaster.freshTexWarnLog();
        let textures = SoftRaster.freshTextureCache();
        let keys: ConcurrentHashMap[Int32, String] = new ConcurrentHashMap();
        region rc {
            List.range(0, lanes()) |> List.forEach(lane ->
                spawn (jobs |> List.filter(p -> Int32.modulo(fst(p), lanes()) == lane) |> List.forEach(p -> {
                    let (i, w) = p;
                    noteProgress(video#outDir, i);
                    let frame = softFrame(video, baked, i, w);
                    let key = RenderCache.keyOf(session, DrawHash.PngEncoding.Filmstrip, frame, Map.empty(), textures)
                        |> Option.map(DrawHash.toHex) |> Option.getWithDefault("-");
                    discard keys.put(i, key);
                    if (paints(paint, i))
                        RenderCache.writeFramePng(session, frame#req, frame#surfaces, frame#extraFonts, Map.empty(), warnLog, textures)
                    else ()
                })) @ rc)
        };
        if (paint == PaintRange.Nothing) () else println(RenderCache.statsLine(session));
        jobs |> List.foldLeft((acc, p) -> {
            let i = fst(p);
            Map.insert(i, Option.getWithDefault("-", Object.toOption(keys.get(i))), acc)
        }, Map.empty())

    // ── GPU ──

    /// GPU で塗って ffmpeg へ生の画素を流す。鍵は SoftRaster の命令から（GL とは別の糸で並べて作る）。
    /// GL の文脈は呼んだ糸が持つ。GL が作れない・ffmpeg が立たない時は何も書かずに Err。
    def writeGl(settings: Settings, video: Video[w], baked: Baked, jobs: List[(Int32, w)]): Result[String, Map[Int32, String]] \ IO =
        let config = run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO;
        match config {
            case Err(why) => Err("project.json を読めない: ${why}")
            case Ok(loaded) =>
                let cfg = video#soft;
                match GlOffscreen.open({ config = { clearColor = cfg#background | loaded#config }, scale = cfg#scale }) {
                    case Err(why) => Err(why)
                    case Ok(session) =>
                        let result = try {
                            paintGl(settings, video, baked, session, jobs)
                        } catch {
                            case e: Throwable => Err("GPU で塗る途中で止まった: ${e.toString()}")
                        };
                        GlOffscreen.close(session);
                        result
                }
        }

    def paintGl(settings: Settings, video: Video[w], baked: Baked, session: GlOffscreen.Session, jobs: List[(Int32, w)]): Result[String, Map[Int32, String]] \ IO =
        let (width, height) = GlOffscreen.sizeOf(session);
        // ファイルの無い絵を画素で載せる。
        video#images |> List.forEach(img -> {
            let side = img#side;
            let pixelAt = img#pixelAt;
            let argb = Vector.range(0, side * side) |> Vector.map(k -> pixelAt(Int32.modulo(k, side), k / side));
            GlOffscreen.uploadImage(session, img#name, "video:${img#name}", side, side, argb)
        });
        match startFfmpeg(settings#ffmpeg, video, width, height) {
            case Err(why) => Err(why)
            case Ok(proc) =>
                let out = proc.getOutputStream();
                let buf = GlOffscreen.freshBuffer(session);
                let keySession = RenderCache.freshSession();
                let keyTextures = SoftRaster.freshTextureCache();
                let keys: ConcurrentHashMap[Int32, String] = new ConcurrentHashMap();
                region rc {
                    // 鍵は別の糸で（SoftRaster の命令を組むのは GL と無関係なので、塗りと重ねる）。region の終わりで待つ。
                    spawn (jobs |> List.forEach(p -> {
                        let (i, w) = p;
                        let key = RenderCache.keyOf(keySession, DrawHash.PngEncoding.Filmstrip, softFrame(video, baked, i, w), Map.empty(), keyTextures)
                            |> Option.map(DrawHash.toHex) |> Option.getWithDefault("-");
                        discard keys.put(i, key)
                    })) @ rc;
                    let bytes: Array[Int8, rc] = Array.empty(rc, width * height * 4);
                    jobs |> List.forEach(p -> {
                        let (i, w) = p;
                        noteProgress(video#outDir, i);
                        paintOne(video, session, w);
                        GlOffscreen.readRgba(session, buf);
                        discard buf.rewind();
                        discard buf.get(bytes);
                        out.write(bytes)
                    });
                    out.close()
                };
                let code = proc.waitFor();
                // 最後のコマ（GL に残っている）を last.png に。
                discard ImageIO.write(GlOffscreen.readImage(session), "png", new File("${video#outDir}/last.png"));
                let table = jobs |> List.foldLeft((acc, p) -> {
                    let i = fst(p);
                    Map.insert(i, Option.getWithDefault("-", Object.toOption(keys.get(i))), acc)
                }, Map.empty());
                if (code != 0) Err("ffmpeg が ${Int32.toString(code)} で終わった") else Ok(table)
        }

    /// 1 コマを GL へ塗る。初めて出る字があればアトラスを育てて組み直す（最大 3 回）。
    def paintOne(video: Video[w], session: GlOffscreen.Session, world: w): Unit \ IO =
        let scene = video#scene;
        def build(left) = {
            let table = GlOffscreen.fontTable(session);
            let fallback = Map.get("default", table) |> Option.getWithDefault(video#soft#fontAtlas);
            let items = scene(name -> Map.get(name, table) |> Option.getWithDefault(fallback))(world);
            let missing = Render.missingGlyphs(items);
            if (Map.isEmpty(missing) or left <= 1) items
            else {
                Map.forEach((textureName, cps) -> GlOffscreen.ensureGlyphs(session, textureName, cps), missing);
                build(left - 1)
            }
        };
        let items = build(3);
        GlOffscreen.handle(session, () -> {
            let shaderCmds = Render.drawShaders(spec -> ShaderEffect.Shader.buildProgram(spec), items);
            List.forEach(cmd -> ShaderEffect.Shader.drawSurface(cmd), shaderCmds);
            let itemsToDraw = if (List.isEmpty(shaderCmds)) items else Render.withoutShaders(items);
            let (sprites, polygons) = Render.drawWith(name -> GameEngine.Game.getTextureInfo(name), itemsToDraw);
            GameEngine.Game.renderCommands(sprites, Nil, polygons, None)
        })

    /// ffmpeg を立てる（標準入力に RGBA の生の画素・下の行から。ffv1 の可逆で frames.mkv へ）。
    /// 4 バイト目は rgb0 で捨てる —— FBO の α は重ねた半透明の分だけ 1 より下がっていて、α として運ぶと
    /// 見る側が白の上に重ねて絵が薄く見える（窓では α を見ないので、実機と同じ絵にするには捨てる）。
    def startFfmpeg(ffmpeg: String, video: Video[w], width: Int32, height: Int32): Result[String, Process] \ IO =
        let target = "${video#outDir}/frames.mkv";
        discard (new File(target)).delete();
        let args = ffmpeg :: "-y" :: "-loglevel" :: "error"
            :: "-f" :: "rawvideo" :: "-pix_fmt" :: "rgb0" :: "-s" :: "${Int32.toString(width)}x${Int32.toString(height)}"
            :: "-r" :: Int32.toString(video#fps) :: "-i" :: "-" :: "-vf" :: "vflip"
            :: "-c:v" :: "ffv1" :: "-level" :: "3" :: "-threads" :: "4" :: "-slices" :: "4" :: target :: Nil;
        try {
            region rc {
                let builder = new ProcessBuilder(List.toArray(rc, args));
                discard builder.redirectError(ProcessBuilder$Redirect.INHERIT);
                discard builder.redirectOutput(ProcessBuilder$Redirect.DISCARD);
                Ok(builder.start())
            }
        } catch {
            case e: Throwable => Err("ffmpeg を立てられない（${ffmpeg}）: ${e.toString()}")
        }

    // ── frames.json ──

    /// コマの表。painter・frames（書いたコマ数）・painted（塗った範囲）・fps・keys（鍵のあるコマ数）・last（最後の画面）。
    /// 音（sfx.txt・bgm.txt）はこの後に入口が書くので、ここでは持たない（mix が読む）。
    def writeFramesJson(video: Video[w], paint: PaintRange, painter: Painter, jobs: List[(Int32, w)],
                        keys: Map[Int32, String]): Unit \ IO =
        let frames = List.length(jobs);
        let lastIndex = jobs |> List.last |> Option.map(fst) |> Option.getWithDefault(-1);
        let last = match painter {
            case Painter.Gl       => "\"last.png\""
            case Painter.Soft     => if (lastIndex >= 0 and paints(paint, lastIndex)) "\"f${String.padLeft(4, '0', Int32.toString(lastIndex))}.png\"" else "null"
            case Painter.KeysOnly => "null"
        };
        let painterName = match painter {
            case Painter.Gl       => "gl"
            case Painter.Soft     => "soft"
            case Painter.KeysOnly => "none"
        };
        let painted = match (painter, paint) {
            case (Painter.KeysOnly, _)               => "[]"
            case (_, PaintRange.Frames(ranges))      =>
                "[" + (ranges |> List.map(r -> { let (lo, hi) = r; "[${Int32.toString(lo)},${Int32.toString(hi)}]" }) |> String.intercalate(",")) + "]"
            case _                                   => "[[0,${Int32.toString(lastIndex)}]]"
        };
        let keyCount = keys |> Map.filter(k -> k != "-") |> Map.size;
        let text = "{\n  \"painter\": \"${painterName}\",\n  \"frames\": ${Int32.toString(frames)},\n"
            + "  \"painted\": ${painted},\n  \"fps\": ${Int32.toString(video#fps)},\n  \"keys\": ${Int32.toString(keyCount)},\n"
            + "  \"last\": ${last}\n}\n";
        let out = new FileWriter("${video#outDir}/frames.json");
        out.write(text);
        out.close()
}
