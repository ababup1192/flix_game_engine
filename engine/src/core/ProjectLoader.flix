// ProjectLoader — project.json を読み込んで engine 起動用の設定 + scene ファイル列挙を提供する。
//
// project.json は engine / examples が共通で読む唯一の真実 (single source of truth)。
// engine（契約層）に置くことで、バックエンド（render_gl）やゲームのどこからも import できる。
//
// スキーマ (engine の `GameEngine.EngineConfig` と完全一致):
//
//   {
//     "title": String,
//     "designWidth": Int, "designHeight": Int,
//     "windowWidth": Int, "windowHeight": Int,
//     "clearColor": {"r": Float, "g": Float, "b": Float},
//     "maxDeltaTime": Float,
//     "scene3dTextureBudgetMB": Int,   （任意。3D の場面の絵を GPU に持つ量の上限。既定 256）
//     "scene3dTextureBudgetCount": Int,（任意。3D の場面の絵を GPU に持つ枚数の上限。既定 64）
//     "textures": [{"name": String, "path": String, "hasAlpha": Bool}, ...],
//     "fonts":    [{"name": String, "path": String, "fontSize": Float}, ...],
//     "sounds":   [{"name": String, "path": String, "looping": Bool}, ...],
//     "web": { "portraitDesign": {"width": Int, "minHeight": Int, "maxHeight": Int} }
//                                      （任意。縦に持って開いた時の design。Project#portraitDesign へ。ほかの web の欄は書き出しの道具が読む）
//   }
//
// 画像・フォント・サウンドのパスは project root からの相対で記述する。
// IDE は (Java 起動時の) CWD と無関係に動かしたいため、rootDir + relative の絶対パス
// 文字列に書き換えてから返す。examples は CWD = project root で動くので rootDir = "." を
// 渡す慣習。

pub mod ProjectLoader {
    use Util.Json.Json.{JObject, JArray, JString, JNumber, JBool}
    use Util.Json.JsonError
    use Util.Json.JsonError.JsonError.Decode
    use Util.Json.JsonError.DecodeErrorKind.TypeMismatch
    use Util.Json.JsonPath

    /// project.json から組み立てた、engine 起動に渡すための設定。
    /// shape は engine の `GameEngine.EngineConfig` と完全一致させてあり、
    /// Flix の structural record により `LwjglLayer.withLwjgl` 等にそのまま渡せる。
    /// project.json に任意キー `windowScale`(>0) があれば、windowWidth/windowHeight より
    /// 優先して window = design × scale をロード時に解決する（buildProject 参照）。
    pub type alias ProjectConfig = {
        rootDir         = String,
        glyphs          = String,
        designWidth     = Int32,
        designHeight    = Int32,
        windowWidth     = Int32,
        windowHeight    = Int32,
        title           = String,
        textureManifest = List[{name = String, path = String, hasAlpha = Bool}],
        fontManifest    = List[{name = String, path = String, fontSize = Float64}],
        soundManifest   = List[{name = String, path = String, looping = Bool}],
        clearColor      = Color,
        maxDeltaTime    = Float64,
        scene3dTextureBudgetMB = Int32,
        scene3dTextureBudgetCount = Int32
    }

    /// 読み込み結果。シーンは別途 `findSceneFiles` で列挙する。
    /// portraitDesign = web.portraitDesign（縦に持って開いた時の design の決め方。書いていなければ None = いつも横の design）。
    pub type alias Project = {
        rootDir = String,
        config  = ProjectConfig,
        portraitDesign = Option[PortraitDesign]
    }

    /// 縦の design の決め方（project.json の web.portraitDesign）。幅は width に固定し、高さは開いた画面の縦横の比から決めて
    /// minHeight と maxHeight の間に切る（maxHeight は任意・既定は width × 2.4 と minHeight の大きい方）。minHeight は width より大きい。
    // WhyNot: 高さも固定しない — 縦長の比は端末ごとに 16:9〜21:9 と違い、固定すると上下に帯が出る。
    // WhyNot: 幅を画面の比で動かさない — 1 行の字数と字の実際の大きさが端末ごとに変わり、読み物の行の長さが揺れる。
    pub type alias PortraitDesign = { width = Int32, minHeight = Int32, maxHeight = Int32 }

    /// 縦の design の大きさ（幅, 高さ）。view = 描き先の大きさ（CSS px など。比だけを使う）。view が 0 以下なら高さは minHeight。
    pub def portraitDesignOf(spec: PortraitDesign, view: Vec2.Vec2): (Int32, Int32) =
        let fromView = if (view#x > 0.0 and view#y > 0.0)
            Float64.tryToInt32(Float64.round(Int32.toFloat64(spec#width) * view#y / view#x)) |> Option.getWithDefault(spec#minHeight)
            else spec#minHeight;
        (spec#width, Int32.min(spec#maxHeight, Int32.max(spec#minHeight, fromView)))

    /// 縦で起動する時の設定: design を portraitDesignOf に替え、窓の大きさを view にした config。縦の指定が無ければ None（横のまま起動する）。
    pub def portraitConfigOf(proj: Project, view: Vec2.Vec2): Option[ProjectConfig] =
        proj#portraitDesign |> Option.map(spec -> {
            let (w, h) = portraitDesignOf(spec, view);
            let winW = Float64.tryToInt32(Float64.round(view#x)) |> Option.filter(v -> v > 0) |> Option.getWithDefault(w);
            let winH = Float64.tryToInt32(Float64.round(view#y)) |> Option.filter(v -> v > 0) |> Option.getWithDefault(h);
            { designWidth = w, designHeight = h, windowWidth = winW, windowHeight = winH | proj#config }
        })

    /// project.json を読んで Project を組み立てる。
    /// 読めない・JSON が崩れている・欄の型が違うときは Err(message) を返す
    /// (呼び出し側が dialog 表示・終了などを決める)。
    pub def loadProject(rootDir: String): Result[String, Project] \ {Fs.FileRead} =
        let projectJsonPath = joinPath(rootDir, "project.json");
        let readResult = run { Fs.ReadFile.read(projectJsonPath) }
            with Fs.ReadFile.runWithFileRead;
        match readResult {
            case Err(e) => Err("Failed to read ${projectJsonPath}: ${e}")
            case Ok(content) =>
                match (Util.Json.parse(String.trim(content)) |> Result.toOption) {
                    case None    => Err("JSON parse failed: ${projectJsonPath}")
                    case Some(j) =>
                        buildProject(rootDir, j)
                            |> Result.mapErr(e -> "${projectJsonPath}: ${describeErr(e)}")
                }
        }

    def buildProject(rootDir: String, json: Util.Json.Json): Result[JsonError, Project] =
        forM (
            root       <- matchObject(json, "root");
            title      <- getString(root, "title");
            designW    <- getInt(root, "designWidth");
            designH    <- getInt(root, "designHeight");
            window     <- resolveWindow(root, designW, designH);
            clearJson  <- getField(root, "clearColor");
            clearColor <- readColor(clearJson);
            maxDelta   <- getFloat(root, "maxDeltaTime");
            texJson    <- getField(root, "textures");
            textures   <- readTextures(rootDir, texJson);
            fontJson   <- getField(root, "fonts");
            fonts      <- readFonts(rootDir, fontJson);
            soundJson  <- getField(root, "sounds");
            sounds     <- readSounds(rootDir, soundJson);
            portrait   <- readPortraitDesign(root)
        ) yield {
            let config: ProjectConfig = {
                rootDir         = rootDir,
                glyphs          = getGlyphs(root),
                designWidth     = designW,
                designHeight    = designH,
                windowWidth     = fst(window),
                windowHeight    = snd(window),
                title           = title,
                textureManifest = textures,
                fontManifest    = fonts,
                soundManifest   = sounds,
                clearColor      = clearColor,
                maxDeltaTime    = maxDelta,
                scene3dTextureBudgetMB = positiveIntOr("scene3dTextureBudgetMB", GameEngine.defaultScene3dTextureBudgetMB(), root),
                scene3dTextureBudgetCount = positiveIntOr("scene3dTextureBudgetCount", GameEngine.defaultScene3dTextureBudgetCount(), root)
            };
            { rootDir = rootDir, config = config, portraitDesign = portrait }
        }

    /// 任意の整数のキー key（scene3dTextureBudgetMB・scene3dTextureBudgetCount）。無い・数でない・1 未満は既定 fallback。
    def positiveIntOr(key: String, fallback: Int32, root: Map[String, Util.Json.Json]): Int32 =
        match Map.get(key, root) {
            case Some(JNumber(n)) if n.intValue() >= 1 => n.intValue()
            case _                                     => fallback
        }

    /// glyphs（任意）: 起動時にどの字を生成するか。
    ///   "auto"（既定）… 起動時は生成せず、出た字から順に生成する。起動が一番速い
    ///   "used"         … ソースとアセットに書いてある字を先に生成する。最初の画面で引っかからない
    ///   "all"          … フォントが持つ字を全部。日本語だと数十秒かかる
    /// どれでも、足りない字は出そうとしたときに追加生成される（消えることはない）。
    def getGlyphs(root: Map[String, Util.Json.Json]): String =
        match Map.get("glyphs", root) {
            case Some(JString(g)) => g
            case _                => "auto"
        }

    /// windowScale（任意）: あれば window = design × scale をここで解決し、
    /// windowWidth/windowHeight より優先する。アスペクト比を design に合わせたまま
    /// ウィンドウだけ拡大したいとき用（見た目そのままで画面を大きくする）。
    def resolveWindow(root: Map[String, Util.Json.Json], designW: Int32, designH: Int32):
                        Result[JsonError, (Int32, Int32)] =
        let scaleOpt = match Map.get("windowScale", root) {
            case Some(JNumber(n)) => Some(n.doubleValue())
            case _                => None
        };
        match scaleOpt {
            case Some(s) if s > 0.0 =>
                Ok((Float64.tryToInt32(Float64.round(Int32.toFloat64(designW) * s)) |> Option.getWithDefault(designW),
                    Float64.tryToInt32(Float64.round(Int32.toFloat64(designH) * s)) |> Option.getWithDefault(designH)))
            case _ =>
                forM (
                    w <- getInt(root, "windowWidth");
                    h <- getInt(root, "windowHeight")
                ) yield (w, h)
        }

    // ========================================================================

    /// プロジェクトディレクトリを再帰的に走査して *.scene.json を列挙する。
    /// 返るパスは rootDir からの相対形 ("src/scenes/MenuScene.scene.json" 等)。
    /// IDE 側はこれを scene リストに表示し、クリックで loadScene に渡す。
    pub def findSceneFiles(rootDir: String): Result[String, List[String]] \ Fs.Glob =
        Fs.Glob.glob(rootDir, "**/*.scene.json")
            |> Result.mapErr(e -> "Failed to list *.scene.json under ${rootDir}: ${e}")
            |> Result.map(List.map(absPath ->
                // glob は絶対パス or rootDir 相対で返すので、rootDir プレフィックスを剥がす
                if (String.startsWith({prefix = rootDir + "/"}, absPath))
                    absPath.substring(String.length(rootDir) + 1)
                else if (String.startsWith({prefix = rootDir}, absPath))
                    absPath.substring(String.length(rootDir))
                else
                    absPath
            ))

    // ========================================================================
    // JSON 抽出ヘルパー
    // ========================================================================

    def matchObject(elem: Util.Json.Json, ctx: String): Result[JsonError, Map[String, Util.Json.Json]] =
        match elem {
            case JObject(m) => Ok(m)
            case _          => Err(err("${ctx} is not a JSON object"))
        }

    def getField(map: Map[String, Util.Json.Json], key: String): Result[JsonError, Util.Json.Json] =
        match Map.get(key, map) {
            case Some(v) => Ok(v)
            case None    => Err(err("missing key '${key}'"))
        }

    def getString(map: Map[String, Util.Json.Json], key: String): Result[JsonError, String] =
        getField(map, key) |> Result.flatMap(v -> match v {
            case JString(s) => Ok(s)
            case _          => Err(err("'${key}' is not a string"))
        })

    def getInt(map: Map[String, Util.Json.Json], key: String): Result[JsonError, Int32] =
        getField(map, key) |> Result.flatMap(v -> match v {
            case JNumber(n) => Ok(n.intValue())
            case _          => Err(err("'${key}' is not a number"))
        })

    def getFloat(map: Map[String, Util.Json.Json], key: String): Result[JsonError, Float64] =
        getField(map, key) |> Result.flatMap(v -> match v {
            case JNumber(n) => Ok(n.doubleValue())
            case _          => Err(err("'${key}' is not a number"))
        })

    def getBool(map: Map[String, Util.Json.Json], key: String): Result[JsonError, Bool] =
        getField(map, key) |> Result.flatMap(v -> match v {
            case JBool(b) => Ok(b)
            case _        => Err(err("'${key}' is not a boolean"))
        })

    def readColor(elem: Util.Json.Json): Result[JsonError, Color] =
        forM (
            m <- matchObject(elem, "clearColor");
            r <- getFloat(m, "r");
            g <- getFloat(m, "g");
            b <- getFloat(m, "b")
        ) yield ({ r = r, g = g, b = b }: Color)

    def readTextures(rootDir: String, elem: Util.Json.Json):
                       Result[JsonError, List[{name = String, path = String, hasAlpha = Bool}]] =
        match elem {
            case JArray(v) =>
                Vector.toList(v) |> Result.traverse(item ->
                    forM (
                        m        <- matchObject(item, "texture entry");
                        name     <- getString(m, "name");
                        path     <- getString(m, "path");
                        hasAlpha <- getBool(m, "hasAlpha")
                    ) yield { name = name, path = joinPath(rootDir, path), hasAlpha = hasAlpha }
                )
            case _ => Err(err("'textures' is not an array"))
        }

    def readFonts(rootDir: String, elem: Util.Json.Json):
                    Result[JsonError, List[{name = String, path = String, fontSize = Float64}]] =
        match elem {
            case JArray(v) =>
                Vector.toList(v) |> Result.traverse(item ->
                    forM (
                        m        <- matchObject(item, "font entry");
                        name     <- getString(m, "name");
                        path     <- getString(m, "path");
                        fontSize <- getFloat(m, "fontSize")
                    ) yield { name = name, path = joinPath(rootDir, path), fontSize = fontSize }
                )
            case _ => Err(err("'fonts' is not an array"))
        }

    def readSounds(rootDir: String, elem: Util.Json.Json):
                     Result[JsonError, List[{name = String, path = String, looping = Bool}]] =
        match elem {
            case JArray(v) =>
                Vector.toList(v) |> Result.traverse(item ->
                    forM (
                        m       <- matchObject(item, "sound entry");
                        name    <- getString(m, "name");
                        path    <- getString(m, "path");
                        looping <- getBool(m, "looping")
                    ) yield { name = name, path = joinPath(rootDir, path), looping = looping }
                )
            case _ => Err(err("'sounds' is not an array"))
        }

    /// web.portraitDesign（任意）。web か portraitDesign が無ければ None。有るのに形が違えば Err（ゲームの作者が直す物で、起動の時に止める）。
    def readPortraitDesign(root: Map[String, Util.Json.Json]): Result[JsonError, Option[PortraitDesign]] =
        let spec = Map.get("web", root) |> Option.flatMap(web -> match web {
            case JObject(m) => Map.get("portraitDesign", m)
            case _          => None
        });
        match spec {
            case None       => Ok(None)
            case Some(json) => readPortraitSpec(json) |> Result.map(Some)
        }

    def readPortraitSpec(json: Util.Json.Json): Result[JsonError, PortraitDesign] =
        forM (
            m      <- matchObject(json, "web.portraitDesign");
            width  <- getInt(m, "width");
            minH   <- getInt(m, "minHeight");
            maxH   <- optionalInt(m, "maxHeight", Int32.max(minH, width * 12 / 5));
            spec   <- checkPortraitSpec({ width = width, minHeight = minH, maxHeight = maxH })
        ) yield spec

    def optionalInt(map: Map[String, Util.Json.Json], key: String, fallback: Int32): Result[JsonError, Int32] =
        if (Map.memberOf(key, map)) getInt(map, key) else Ok(fallback)

    def checkPortraitSpec(spec: PortraitDesign): Result[JsonError, PortraitDesign] =
        if (spec#width < 1 or spec#minHeight < 1) Err(err("web.portraitDesign の width と minHeight は 1 以上"))
        else if (spec#minHeight <= spec#width) Err(err("web.portraitDesign の minHeight は width より大きい（縦長の design にする）"))
        else if (spec#maxHeight < spec#minHeight) Err(err("web.portraitDesign の maxHeight は minHeight 以上"))
        else Ok(spec)

    def err(msg: String): JsonError =
        Decode(JsonPath.empty(), TypeMismatch(msg))

    /// err が詰めた説明文を、コンテナの定型句を剥がして返す。
    def describeErr(e: JsonError): String =
        match e {
            case Decode(_, TypeMismatch(msg)) => msg
            case other                        => "${other}"
        }

    /// パスを単純連結する (rootDir + "/" + relative)。
    /// 末尾スラッシュの重複は除去する。絶対パス化は OS の File.toAbsolutePath などに
    /// 委ねず、CWD ベースのパスで loadTexture/loadScene が動く前提。
    def joinPath(dir: String, rel: String): String =
        if (String.endsWith({suffix = "/"}, dir))
            "${dir}${rel}"
        else
            "${dir}/${rel}"

    /// flix.toml の依存の行 `"github:ababup1192/flix_game_engine" = { version = "x.y.z", … }` の版。
    pub def engineVersionOf(toml: String): Option[String] =
        String.lines(toml)
            |> List.find(line -> String.contains(substr = "\"github:ababup1192/flix_game_engine\"", line))
            |> Option.flatMap(line -> String.splitOn(substr = "version", line) |> List.drop(1) |> List.head)
            |> Option.flatMap(rest -> String.splitOn(substr = "\"", rest) |> List.drop(1) |> List.head)
            |> Option.filter(v -> not String.isEmpty(v))
}
