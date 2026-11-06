<!-- engine v0.88.0 / 生成: 2026-11-06 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine_tools

`engine_tools/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## AtomicFile — `engine_tools/src/AtomicFile.flix`
- `pub def write(path: String, fill: File -> Unit \ IO): Unit \ IO`

## CpuTiming — `engine_tools/src/CpuTiming.flix`
- 測り方: warmup は捨てる回数、runs は測る回数。
  `pub type alias Plan = { warmup = Int32, runs = Int32 }`
- 測った結果（ミリ秒）。samples は小さい順。
  `pub type alias Summary = { median = Float64, min = Float64, max = Float64, samples = Vector[Float64] }`
- work を warmup 回流して捨て、runs 回流して 1 回ずつの時間を測る（runs が 0 以下なら 1 回）。
  `pub def measure(plan: Plan, work: Unit -> a \ IO): (Summary, a) \ IO`
- 時間の列（ミリ秒）を中央値と幅にまとめる。偶数個の中央値は真ん中の 2 つの平均。
  `pub def summarize(samples: Nel[Float64]): Summary`

## DrawHash — `engine_tools/src/DrawHash.flix`
- 1 コマの鍵。比べるときは `toHex` の字で比べる。
  `pub type alias Key = Digest`
- 鍵を 16 進の字へ（キャッシュのファイル名・知らせに使う）。
  `pub def toHex(key: Key): String`
- PNG の書き方。同じ画素でも書き方でバイト列が違うので鍵に入れる。
  `pub enum PngEncoding with Eq, ToString { case Plain case Filmstrip }`
- 命令に出ない入力の指紋。RenderCache が IO で読んで渡す（ここでは読まない）。
  `pub type alias Inputs = { engine = String, runtime = String, files = Map[String, String], images = Map[String, String] }`
- 1 コマの描き出しに入る、ファイル以外の全部（SoftRaster.renderToImageCached の引数と同じ物）。
  `pub type alias Frame = { req = SoftRaster.RasterReq, surfaces = List[SoftRaster.SurfaceCmd], extraFonts = Map[String, SoftRaster.FontEntry], fontAntialias = SoftRaster.FontAntialias }`
- `pub def usedTextures(frame: Frame): Set[String]`
- 鍵を作るのに中身の指紋が要るファイル（引く絵・既定の TTF・追加の TTF）。
  `pub def filesOf(frame: Frame): List[String]`
- 字のアトラスを畳んだバイト列の覚え。RenderCache の Session が 1 つ持つ。
  `pub type alias AtlasCache = AtlasMemo`
- 空の覚え（糸をまたいで使ってよい）。
  `pub def freshAtlasCache(): AtlasCache \ IO`
- `pub def computeKey(inputs: Inputs, encoding: PngEncoding, frame: Frame): Option[Key]`
- computeKey と同じ鍵（ビット単位で同じ）を、アトラスを畳んだバイト列を `cache` から引いて作る。
  `pub def computeKeyCached(cache: AtlasCache, inputs: Inputs, encoding: PngEncoding, frame: Frame): Option[Key] \ IO`

## Filmstrip — `engine_tools/src/Filmstrip.flix`
- 描き出しの結果（呼び側が HTML ビューアのメタデータに使う）。
  `pub type alias RenderResult = { frameCount = Int32, frameW = Int32, frameH = Int32, width = Int32, height = Int32, indexed = Bool, colors = Int32 }`
- renderFrames の結果（呼び側がビューアのメタデータに使う）。
  `pub type alias FramesResult = { frameCount = Int32, frameW = Int32, frameH = Int32 }`
- `frames` を 1 コマ 1 ファイルのコマ別 PNG として `dirPath` へ書き出す（`0.png` .. `n-1.png`）。
  `pub def renderFrames(frames: List[BufferedImage], dirPath: String): Option[FramesResult] \ IO`
- 1 コマだけをコマ別 PNG に書く（renderFrames の 1 枚ぶんと同じ経路 = 同じバイト列になる）。
  `pub def renderFrame(img: BufferedImage, outPath: String): Unit \ IO`
- `frames`（同寸の BufferedImage 列）を横連結して `outPath` へ PNG で書き出す。
  `pub def render(frames: List[BufferedImage], outPath: String): Option[RenderResult] \ IO`

## GifEncoder — `engine_tools/src/GifEncoder.flix`
- アニメ GIF とコマ送りビューア用のコマ別 PNG（`Filmstrip.renderFrames`）をペアで描き出す。
  `pub def encodeWithFrames(frames: List[BufferedImage], delayMs: Int32, gifPath: String, framesDir: String): Unit \ IO`
- アニメ GIF を `outPath` へ書き出す。`frames` は同寸の BufferedImage 列、`delayMs` は各フレームの
  `pub def encode(frames: List[BufferedImage], delayMs: Int32, outPath: String): Unit \ IO`

## HeadlessFont — `engine_tools/src/HeadlessFont.flix`
- AWT をヘッドレスに固定する。macOS では `-XstartOnFirstThread`（GLFW/AppKit がメインスレッドを
  `pub def ensureHeadless(): Unit \ IO`
- `ttfPath` の TTF から FontAtlas（メトリクス + codepoint↔セル座標の対応表）を組む。
  `pub def buildUiAtlas(ttfPath: String, _joyoPath: String): FontAtlas \ IO`
- 名前つきでアトラスを組む（textureName = "font_${name}"）。実機の RenderFont が
  `pub def buildAtlas(name: String, ttfPath: String): FontAtlas \ IO`

## HeadlessLoad — `engine_tools/src/HeadlessLoad.flix`
- f を流す（知らせは捨てる・仕事は並列・絵は javax.imageio で解く）。
  `pub def handle(f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO`
- handle の、知らせを onReport へ渡す版（進み具合を見るテスト・自前の進み具合の表示）。
  `pub def handleWith(onReport: (String, Int32, Int32) -> Unit \ ef1, f: Unit -> a \ ef): a \ (ef - LoadProgress) + ef1 + IO`
- PNG / JPEG を javax.imageio で画素に戻すデコーダー（スレッドをまたいで使える）。
  `pub def imageIoDecoder(): ImageData.ImageDecoder`

## HeadlessRender — `engine_tools/src/HeadlessRender.flix`
- ゲームごとに 1 回宣言する生成設定。design を `scale` 倍に拡大して出力する。
  `pub type alias RenderConfig = { design = Vec2.Vec2, scale = Int32, background = Color, texturePath = Map[String, String], fontTtf = String, fontAtlas = FontAtlas, outDir = String, frameW = Int32, frameH = Int32, gifDelayMs = Int32, gifFps = Int32, shapeAntialias = Bool, textAntialias = Bool }`
- 欠けた欄の落ち先。ゲームごとに違うのは design / outDir / フォント / 画風のつまみだけなので、
  `pub def defaults(): RenderConfig`
- 走行中に作った正方形の絵（ドット絵アトラスなど）を PNG に落とし、
  `pub def imagePngs(outDir: String, images: List[{ name = String, side = Int32, pixelAt = (Int32, Int32) -> Int32 }]): Map[String, String] \ IO`
- 同じ絵の一覧から「名前 → テクスチャの寸法」を引く関数を作る（Render.drawWith に渡す）。
  `pub def imageTextureInfo(images: List[{ name = String, side = Int32 | r }]): String -> Option[{ id = GpuHandle.TextureId, width = Float64, height = Float64 }]`
- タイル層・静的層を CPU へ投影したぶんを申告する（予算は 動的 = total − static で見る）。
  `pub def noteStaticItems(cfg: RenderConfig, name: String, staticItems: List[a]): Unit \ IO`
- 描画コマンド列を 1 枚の PNG に生成する（World を介さない場面や、投影済みの静止画に使う）。
  `pub def renderPng(cfg: RenderConfig, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO`
- 複数フォントで生成する renderPng。`extraFonts` はテクスチャ名（実機の project.json の
  `pub def renderPngFonts(cfg: RenderConfig, extraFonts: Map[String, SoftRaster.FontEntry], drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO`
- 宣言シェーダー面つきの renderPng。surfaces（Render.shaderSurfaces の出力と同形の
  `pub def renderPngWith(cfg: RenderConfig, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO`
- シルエット生成の絞り方。既定に使うのは WorldBand — 全アイテムを黒にすると画面が
  `pub enum SilhouetteScope { case WorldBand case All case ZWindow({ lo = Int32, hi = Int32 }) }`
- 描画コマンド列を「対象は真っ黒・それ以外は落とす」に写す純関数。背景を白にして
  `pub def silhouette(scope: SilhouetteScope, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd])`
- 宣言シェーダー面も含めた silhouette。面は「rect と mask の形をそのまま黒で塗る」に
  `pub def silhouetteWith(scope: SilhouetteScope, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd], List[SoftRaster.SurfaceCmd])`
- `pub def silhouetteScenes(scope: SilhouetteScope, scenes: List[Scene3d.RenderCmd]): List[Scene3d.RenderCmd]`
- シルエット PNG を生成する（renderPng の変形版）。対象を黒・背景を白で <name>.png に書く。
  `pub def silhouettePng(cfg: RenderConfig, scope: SilhouetteScope, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO`
- silhouettePng の「宣言シェーダー面も写す」版。地面・空・水面を ShaderDoc の面で
  `pub def silhouettePngWith(cfg: RenderConfig, scope: SilhouetteScope, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO`
- pass 1 枚ぶんの宣言（Render.Pass のコマンド列版）。name はそのままテクスチャ名になり、
  `pub type alias PassSpec = { name = String, clear = RenderTarget.LoadOp, drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd], surfaces = List[SoftRaster.SurfaceCmd], scenes = List[Scene3d.RenderCmd], target = RenderTarget.Descriptor }`
- pass 1 枚を描き出す（形式は p#target#format。Rgba8Unorm は Rgba8Unorm・Rgba16Float は Rgba16Float の絵）。Design の基準は design 解像度
  `pub def renderPassImage(cfg: RenderConfig, p: PassSpec, prev: Option[SoftRaster.PassImage]): SoftRaster.PassImage \ IO`
- renderPassImage の「先に生成したターゲットも参照できる」版。`images` は既に生成した pass の
  `pub def renderPassImageWith(cfg: RenderConfig, images: Map[String, SoftRaster.PassImage], p: PassSpec, prev: Option[SoftRaster.PassImage]): SoftRaster.PassImage \ IO`
- 1 枚の絵に要る物の全部。passes = 本編より先に描く pass（後の pass と本編は前の pass の名前を貼れる）、
  `pub type alias Scene = { passes = List[PassSpec], drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd], surfaces = List[SoftRaster.SurfaceCmd], scenes = List[Scene3d.RenderCmd], fonts = Map[String, SoftRaster.FontEntry], fontAntialias = SoftRaster.FontAntialias }`
- pass・ShaderDoc の面・追加フォントを一緒に使って 1 枚の PNG に生成する（他の renderPng* はどれもこれの一部）。
  `pub def renderPngFull(cfg: RenderConfig, scene: Scene, name: String): Unit \ IO`
- CPU で描く 1 枚に要る物（engine_world の Render.softSceneOf が同じ形のレコードを返す）。
  `pub type alias SoftScene = { drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd], surfaces = List[SoftRaster.SurfaceCmd], scenes = List[Scene3d.RenderCmd] }`
- SoftScene を 1 枚の PNG に生成する（3D のゲームはこれを 1 回呼べば済む）。知らせと値段の記録は renderPngFull と同じ。
  `pub def renderPngSoft(cfg: RenderConfig, soft: SoftScene, name: String): Unit \ IO`
- renderPngFull と同じ塗り（pass を先に描いて混ぜる・字の縁は本ごと）で 1 枚描いた画像を返す
  `pub def renderImageFull(cfg: RenderConfig, scene: Scene): BufferedImage \ IO`
- renderImageFull の SoftScene 版（pass も追加の字も無い 1 枚。3D のゲームの場面）。
  `pub def renderImageSoft(cfg: RenderConfig, soft: SoftScene): BufferedImage \ IO`
- SoftScene のシルエット PNG（silhouettePngWith の 3D 込みの版）。3D の場面は silhouetteScenes で黒にする。
  `pub def silhouettePngSoft(cfg: RenderConfig, scope: SilhouetteScope, soft: SoftScene, name: String): Unit \ IO`
- passes を宣言順に生成した画像（毎回透明から。後の pass は前の pass の名前を貼れる）。
  `pub def passImagesOf(cfg: RenderConfig, fonts: Map[String, SoftRaster.FontEntry], fontAntialias: SoftRaster.FontAntialias, passes: List[PassSpec]): Map[String, SoftRaster.PassImage] \ IO`
- 追加の生成済み画像（pass のレンダーターゲットなど）を textures に混ぜて本編を PNG に生成する。
  `pub def renderPngWithImages(cfg: RenderConfig, images: Map[String, SoftRaster.PassImage], drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO`
- passes を宣言順に生成してから本編を PNG に生成する（GL の renderFrame と同じ順序 —
  `pub def renderPngWithPasses(cfg: RenderConfig, passes: List[PassSpec], drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO`
- frames を stride 枚ごとに間引き、各コマを toCmds で描いて GIF ＋ コマ別 PNG に生成する。
  `pub def renderGif(cfg: RenderConfig, frames: List[w], stride: Int32, toCmds: w -> (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]), name: String): ReferenceSite.Filmstrip \ IO`
- 複数フォントで生成する renderGif。`extraFonts` はテクスチャ名（実機の project.json の
  `pub def renderGifFonts(cfg: RenderConfig, extraFonts: Map[String, SoftRaster.FontEntry], frames: List[w], stride: Int32, toCmds: w -> (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]), name: String): ReferenceSite.Filmstrip \ IO`
- シェーダー面つきの renderGif（renderPngWith の GIF 版）。toCmds が各コマの
  `pub def renderGifWith(cfg: RenderConfig, frames: List[w], stride: Int32, toCmds: w -> (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd], List[SoftRaster.SurfaceCmd]), name: String): ReferenceSite.Filmstrip \ IO`
- pass つきの renderGif（renderPngWithPasses の GIF 版）。toCmds が各コマの
  `pub def renderGifWithPasses(cfg: RenderConfig, frames: List[w], stride: Int32, toCmds: w -> (List[PassSpec], List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd], List[SoftRaster.SurfaceCmd]), name: String): ReferenceSite.Filmstrip \ IO`
- renderGifWithPasses の、コマごとの絵を Scene で渡す形（追加フォントも使える）。
  `pub def renderGifFull(cfg: RenderConfig, frames: List[w], stride: Int32, toScene: w -> Scene, name: String): ReferenceSite.Filmstrip \ IO`
- stride 枚ごとに 1 枚を残す（0 番から）。
  `pub def every(stride: Int32, xs: List[a]): List[a]`

## LogCapture — `engine_tools/src/LogCapture.flix`
- `pub def capture(f: Unit -> a \ ef): (a, List[String]) \ ef + IO`

## RadialGlow — `engine_tools/src/RadialGlow.flix`
- Addハロ用の1画素: rgb=白固定、alpha=中心で高く縁で0（straight alpha）。
  `pub def haloPixel(curve: Float64 -> Float64, t: Float64): Int32`
- Multiply穴あきオーバーレイ用の1画素: alpha=255固定（不透明）、
  `pub def maskPixel(curve: Float64 -> Float64, t: Float64): Int32`
- 0(中心)→1(縁)を素通しする既定カーブ（直線減衰）。
  `pub def linearCurve(t: Float64): Float64`
- smoothstep(3t²-2t³) で減衰する既定カーブ。縁の階調がなめらかで、
  `pub def smoothstepCurve(t: Float64): Float64`
- maskPixel が「穴」として使う既定の平坦部の広さ（0..1、画像半径に対する比率）。
  `pub def defaultHoleFrac(): Float64`
- t が holeFrac 以下なら完全に素通し（1.0 固定）、それ以降は残り区間へ curve を
  `pub def maskCurveWithHole(holeFrac: Float64, curve: Float64 -> Float64, t: Float64): Float64`
- size×size の正方形の中で、画素 (x, y) の中心から 0(中心)→1(縁) に正規化した距離。
  `pub def normalizedRadius(size: Int32, x: Int32, y: Int32): Float64`

## ReferenceDiff — `engine_tools/src/ReferenceDiff.flix`
- 環境変数で受け取って描き出す。DIFF_DIR = ゲームのディレクトリ、
  `pub def pairs(): Unit \ IO`
- pairs の中身。env は入口の頭で読んだ環境変数の表。
  `pub def pairsOf(env: Map[String, String]): Unit \ IO`

## ReferenceSite — `engine_tools/src/ReferenceSite.flix`
- サイト全体の設定。1 サイト 1 レコードで名前渡しする。
  `pub type alias Config = { outDir = String, title = String, cssScale = Int32 }`
- カタログ 1 項目の表示情報（生成器が受け取る唯一の入力形）。
  `pub type alias Item = { name = String, desc = String, scenario = String, tags = List[String], ext = String, pxWidth = Int32, generateHint = Option[String], lint = LintBadge, filmstrip = Option[Filmstrip] }`
- フィルムストリップ（コマ送りビューア）に要る情報。素材は 2 形態のどちらか:
  `pub type alias Filmstrip = { strip = String, frameCount = Int32, frameW = Int32, frameH = Int32, fps = Int32 }`
- フィルムストリップ無し（従来カードのままにする項目の既定）。
  `pub def noFilmstrip(): Option[Filmstrip]`
- カード 1 枚に添える幾何リンタの結果（ゲーム非依存の構造データ）。
  `pub type alias LintBadge = { checked = Bool, findingCount = Int32, suppressedCount = Int32, details = List[String] }`
- 未検査バッジ（GIF など lint を通していない項目の既定）。
  `pub def noLint(): LintBadge`
- index.html（ハブ）・各 page_<scenario>.html・各 tag_<tag>.html を outDir に書き出す。
  `pub def generate(config: Config, items: List[Item]): Unit \ IO + Fs.FileWrite`

## RenderCache — `engine_tools/src/RenderCache.flix`
- キャッシュの口。コマ列の前に 1 本作って持ち回る（TTF の指紋を 1 回だけ読む）。
  `pub type alias Session = SessionData`
- キャッシュの口を作る（置き場・エンジンの fpkg の指紋・JVM と OS を読む）。
  `pub def freshSession(): Session \ IO`
- 塗った・写した・鍵なしで塗った枚数を 1 行に（描き出しの終わりに出す）。
  `pub def statsLine(session: Session): String \ IO`
- 動画・GIF のコマを 1 枚 req#outPath へ書く（Filmstrip.renderFrame と同じバイト列）。
  `pub def writeFramePng(session: Session, req: SoftRaster.RasterReq, surfaces: List[SoftRaster.SurfaceCmd], extraFonts: Map[String, SoftRaster.FontEntry], extraImages: Map[String, SoftRaster.PassImage], warnLog: SoftRaster.TexWarnLog, textures: SoftRaster.TextureCache): Unit \ IO`
- SoftRaster.render* の書き方（フルカラー）で req#outPath へ書く。SoftRaster.render* の中身。
  `pub def writePlainPng(req: SoftRaster.RasterReq, surfaces: List[SoftRaster.SurfaceCmd], extraFonts: Map[String, SoftRaster.FontEntry], extraImages: Map[String, SoftRaster.PassImage]): Unit \ IO`
- writePlainPng の、字の縁を本ごとに決める表（SoftRaster.FontAntialias）つき版。
  `pub def writePlainPngAntialias(req: SoftRaster.RasterReq, surfaces: List[SoftRaster.SurfaceCmd], extraFonts: Map[String, SoftRaster.FontEntry], fontAntialias: SoftRaster.FontAntialias, extraImages: Map[String, SoftRaster.PassImage]): Unit \ IO`
- 1 コマの鍵（writeFramePng がキャッシュに使うのと同じ物）。鍵を作れなければ None。
  `pub def keyOf(session: Session, encoding: DrawHash.PngEncoding, frame: DrawHash.Frame, extraImages: Map[String, SoftRaster.PassImage], textures: SoftRaster.TextureCache): Option[DrawHash.Key] \ IO`
- 前に inputs から書いた一式（noteWrittenFiles で控えた物）が、そのままのバイト列で残っているか。
  `pub def writtenFilesKept(inputs: String): Bool \ IO`
- files（パスの列）を inputs から書いたと控える（次の writtenFilesKept が当たるように）。
  `pub def noteWrittenFiles(inputs: String, files: List[String]): Unit \ IO`
- Pass の絵の SHA-256。Rgba8Unorm は imageDigest・Rgba16Float は形式の名前と寸法と half の bit を指紋に入れる
  `pub def passImageDigest(image: SoftRaster.PassImage): String \ IO`
- packages.lock の字から、エンジンの版の fpkg の SHA-256（`fpkg = "sha256:…"`）を取り出す（純粋）。無ければ None。
  `pub def lockedEngineDigestOf(version: String, lock: String): Option[String]`

## RenderLint — `engine_tools/src/RenderLint.flix`
- 要素の描画種別（リンタ内の分類。ゲームの widget 名とは独立）。
  `pub enum Kind with Eq { case Text case Box case Sprite case Poly }`
- 軸並行の外接矩形（design px・左上原点）。
  `pub type alias Rect = { minX = Float64, minY = Float64, maxX = Float64, maxY = Float64 }`
- 検査対象の 1 要素。
  `pub type alias Element = { path = String, kind = Kind, z = Int32, bbox = Rect, ancestors = List[String] }`
- 1 シーンぶんの検査入力。
  `pub type alias Input = { sceneName = String, screenW = Float64, screenH = Float64, elements = List[Element], allow = List[String] }`
- 検出 1 件。`suppressed` が true なら allow で抑制済み（fail させず別掲する）。
  `pub type alias Finding = { rule = String, sceneName = String, path = String, detail = String, severity = String, suppressed = Bool }`
- R1: この px を超えて**両軸で**重なったときだけ交差とみなす。
  `pub def textOverlapEpsilon(): Float64`
- R2: 角丸・枠線の内側食い込みは誤差として許す上限（これを超えるはみ出しだけ報告）。
  `pub def panelOverflowEpsilon(): Float64`
- R3: 画面外へこの px を超えて出たときだけ報告する（端に接する HUD の誤検出を避ける）。
  `pub def screenMarginPx(): Float64`
- 全ルールを走らせ、抑制フラグを立てた Finding 列を返す（宣言順 R1→R2→R3）。
  `pub def check(input: Input): List[Finding]`

## RenderService — `engine_tools/src/RenderService.flix`
- 1 件ぶんの頼まれごと。params はクエリ（query は Flix の予約語なので使えない）。
  `pub type alias Request = { method = String, path = String, params = Map[String, String], body = String }`
- 返す物。body はバイト列なので、WAV でも PNG でも JSON でも返せる。
  `pub type alias Reply = { status = Int32, contentType = String, body = Array[Int8, Static] }`
- 文字列の応答（JSON・エラー文言）。
  `pub def textReply(status: Int32, contentType: String, body: String): Reply \ IO`
- `pub def jsonReply(status: Int32, body: String): Reply \ IO`
- バイト列の応答（描き出した WAV など）。
  `pub def bytesReply(contentType: String, body: Array[Int8, Static]): Reply`
- 環境変数 RENDER_PORT から待ち受けるポートを読む。未設定・数値でなければ None。
  `pub def portFromEnv(): Option[Int32] \ IO`
- portFromEnv の中身。env は入口の頭で読んだ環境変数の表。
  `pub def portOf(env: Map[String, String]): Option[Int32]`
- 放置されたら自分から終わるまでの秒数。編集していない間にメモリを抱えたままに
  `pub def idleSecondsFromEnv(): Int64`
- port で待ち受けて、頼まれるたびに handle を呼ぶ。
  `pub def serve(port: Int32, idleSeconds: Int64, onRequest: Request -> Reply \ IO): Unit \ IO`
- "a=1&b=2" → 表。値の中の + は空白へ戻す（フォーム形式の最小限だけ）。
  `pub def parseParams(raw: String): Map[String, String]`

## SfxSynth — `engine_tools/src/SfxSynth.flix`
- 合成の共通設定。`sampleRate` = 1 秒あたりのサンプル数。
  `pub type alias Config = { sampleRate = Int32 }`
- WAV のバイト列。各要素は 1 バイト（0..255）。
  `pub type alias Bytes = List[Int32]`
- `ms` ミリ秒ぶんのサンプル数。
  `pub def frames(cfg: Config, ms: Int32): Int32`
- 矩形波: `freq` Hz・振幅 `amp` を `ms` ミリ秒ぶん。減衰は持たない生の波（先細りは fade で足す）。
  `pub def tone(cfg: Config, freq: Float64, amp: Float64, ms: Int32): List[Float64]`
- 雑音: 番号をハッシュした擬似乱数を振幅 `amp` で `ms` ミリ秒ぶん。生の波。
  `pub def noise(cfg: Config, amp: Float64, ms: Int32): List[Float64]`
- 線形の減衰: 先頭を 1 倍・末尾を 0 倍へ落として音を先細らせる。二度重ねれば急な減衰になる。
  `pub def fade(samples: List[Float64]): List[Float64]`
- 二つの声を重ねる（同じ位置のサンプルを足す。短い方の長さに揃う）。
  `pub def blend(a: List[Float64], b: List[Float64]): List[Float64]`
- 隣り合うサンプルの差分を取り、低い成分を落として「シャッ」というかすれた質感にする
  `pub def rasp(samples: List[Float64]): List[Float64]`
- 声を順に繋いで一続きにする。
  `pub def sequence(voices: List[List[Float64]]): List[Float64]`
- 一本のモノラル 16bit PCM WAV の全バイト。ヘッダがそのままファイル書式（RIFF サイズ・
  `pub def wavBytes(cfg: Config, samples: List[Float64]): Bytes`
- 左右 2 本のステレオ 16bit PCM WAV の全バイト。data には左・右の順に 1 サンプルずつ交互に並べる。
  `pub def wavBytesStereo(cfg: Config, left: List[Float64], right: List[Float64]): Bytes`
- バイト列をそのままファイルへ書き出す（副作用はここだけ）。
  `pub def writeBytes(path: String, bytes: Bytes): Unit \ IO`
- ループ点つきの WAV の全バイト。wavBytes の後ろに "smpl" チャンク（ループ 1 本）を足す。
  `pub def wavBytesLooped(cfg: Config, samples: List[Float64], loopStart: Int32): Bytes`
- wavBytesLooped のステレオ版（wavBytesStereo の後ろに smpl）。ループ点は左右の組の番号で書くので、
  `pub def wavBytesStereoLooped(cfg: Config, left: List[Float64], right: List[Float64], loopStart: Int32): Bytes`
- 音のセットをまとめて `dir` へ描き出す。`(名前, サンプル列)` ごとに `dir/名前.wav` を書き出す
  `pub def renderSet(cfg: Config, dir: String, sounds: List[(String, List[Float64])]): Unit \ IO`
- renderSet と同じ一式を書くが、同じ `inputs`・同じプログラムで前に書いた一式が `dir` にそのままの
  `pub def renderSetOnce(cfg: Config, dir: String, inputs: String, build: Unit -> List[(String, List[Float64])]): Unit \ IO`
- ループ点つきの曲を `dir/名前.wav` へ書き出す（wavBytesLooped。ディレクトリは無ければ作る）。
  `pub def renderLooped(cfg: Config, dir: String, name: String, samples: List[Float64], loopStart: Int32): Unit \ IO`
- ループ点つきのステレオの曲を `dir/名前.wav` へ書き出す（wavBytesStereoLooped。ディレクトリは無ければ作る）。
  `pub def renderLoopedStereo(cfg: Config, dir: String, name: String, left: List[Float64], right: List[Float64], loopStart: Int32): Unit \ IO`

## SoftRaster — `engine_tools/src/SoftRaster.flix`
- ラスタライズ要求。design 解像度の Drawable 群を `scale` 倍に拡大して `outPath` に PNG 出力。
  `pub type alias RasterReq = { drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd], design = Vec2.Vec2, scale = Int32, background = Color, texturePath = Map[String, String], fontTtf = String, fontAtlas = FontAtlas, outPath = String, shapeAntialias = Bool, textAntialias = Bool, scenes = List[Scene3d.RenderCmd] }`
- 追加フォント 1 本（既定フォント以外も混ぜて描き出すとき）。ttf = 実サイズ描き出し用の TTF、
  `pub type alias FontEntry = { ttf = String, atlas = FontAtlas }`
- 字の縁を本ごとに決める表（テクスチャ名 "font_…" → ならすか）。表に無い本は絵全体の RasterReq#textAntialias に従う
  `pub type alias FontAntialias = Map[String, Bool]`
- 宣言シェーダー面 1 枚の headless ラスタライズ要求（Render.ShaderSurface と同形の
  `pub type alias SurfaceCmd = { rect = Rect2.Rect2, spec = ShaderDoc.Spec, time = Float64, mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode }`
- 描き出した Pass の 1 枚（case の名前は RenderTarget.Format と同じ）。Rgba8Unorm = Java2D の画像・
  `pub enum PassImage { case Rgba8Unorm(BufferedImage) case Rgba16Float(ShaderEval.HdrTexture) }`
- 「絵に出ない指定」1 種類ぶんの報告。attr は指定の名前、count は件数、hint は逃げ道。
  `pub type alias Dropped = { attr = String, count = Int32, hint = String }`
- この経路が描けずに落とす指定を数える（純粋・描き出す前に呼べる）。
  `pub def dropped(ds: List[GameEngine.Drawable]): List[Dropped]`
- 報告を 1 行の文へ（呼び出し側がそのまま出せる形）。
  `pub def droppedLine(x: Dropped): String`
- 要求を 1 枚の PNG に描き出して書き出す。PNG を書く render* は RenderCache を通る
  `pub def render(req: RasterReq): Unit \ IO`
- 追加フォントつきの render。`extraFonts` はテクスチャ名（"font_girl" など。実機の
  `pub def renderFonts(req: RasterReq, extraFonts: Map[String, FontEntry]): Unit \ IO`
- シェーダー面つきの render（面は ShaderEval で画素評価して z 順に合流する）。
  `pub def renderWithSurfaces(req: RasterReq, surfaces: List[SurfaceCmd]): Unit \ IO`
- 追加の描き出し済み画像（pass のレンダーターゲットなど）も混ぜて描き、PNG に書き出す render。
  `pub def renderFull(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, PassImage]): Unit \ IO`
- 要求を 1 枚の BufferedImage に描き出して返す（PNG 書き出しはしない）。
  `pub def renderToImage(req: RasterReq): BufferedImage \ IO`
- renderToImage のシェーダー面つき版。surfaces は Drawable / Polygon と同じ
  `pub def renderToImageWith(req: RasterReq, surfaces: List[SurfaceCmd]): BufferedImage \ IO`
- renderToImageWith の複数フォント版。`extraFonts` はテクスチャ名 → 追加の本。
  `pub def renderToImageFonts(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry]): BufferedImage \ IO`
- renderToImageFonts の「追加の描き出し済み画像」つき版。`extraImages` はテクスチャ名 →
  `pub def renderToImageFull(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, PassImage]): BufferedImage \ IO`
- tex 場の欠け名を知らせた控え。GIF などコマ列の描き出しで同じ物を渡し続けると、
  `pub type alias TexWarnLog = Ref[Set[String], Static]`
- 欠け名の控えを新しく作る（コマ列の描き出しの前に 1 本作って持ち回る）。
  `pub def freshTexWarnLog(): TexWarnLog \ IO`
- renderToImageFull の欠け名控えつき版。控えは知らせの回数にだけ効き、
  `pub def renderToImageLogged(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, PassImage], warnLog: TexWarnLog): BufferedImage \ IO`
- texturePath の画像を 1 回だけ読むためのキャッシュ（ファイルのパス → ARGB にそろえた画像）。
  `pub enum TextureCache(ConcurrentHashMap[String, BufferedImage], ConcurrentHashMap[String, String], ConcurrentHashMap[String, List[FontCtx]], ConcurrentHashMap[String, Vector[ShaderEval.TexData]])`
- 空のキャッシュを作る（コマ列の描き出しの前に 1 本）。
  `pub def freshTextureCache(): TextureCache \ IO`
- キャッシュからパスの画像を引く（無ければ読んで入れる。読み方は塗る時と同じ）。無い・読めないなら None。
  `pub def cachedTexture(cache: TextureCache, path: String): Option[BufferedImage] \ IO`
- renderToImageLogged のテクスチャキャッシュつき版。画素は renderToImageLogged と 1 バイトも
  `pub def renderToImageCached(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, PassImage], warnLog: TexWarnLog, cache: TextureCache): BufferedImage \ IO`
- renderToImageCached の、字の縁を本ごとに決める表つき版（表に無い本は絵全体の設定）。
  `pub def renderToImageCachedAntialias(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias, extraImages: Map[String, PassImage], warnLog: TexWarnLog, cache: TextureCache): BufferedImage \ IO`
- image 全面を c の不透明で塗る（画面の clearColor と LoadOp.Clear の塗りはどれもこれを通す）。
  `pub def fillClear(image: BufferedImage, c: Color): Unit \ IO`
- pass（レンダーターゲット）描き出し用の入口（Rgba8Unorm・等倍）。req#background は使わない — 塗るかどうか
  `pub def renderPassImage(req: RasterReq, base: Option[BufferedImage], extraImages: Map[String, PassImage]): BufferedImage \ IO`
- 追加フォントとシェーダー面も使える renderPassImage（pass の中の字を、本編と同じ本で描く）。
  `pub def renderPassImageFonts(req: RasterReq, base: Option[BufferedImage], surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias, extraImages: Map[String, PassImage]): BufferedImage \ IO`
- Pass 1 枚の描き方。format = 描き先の形式。base = 前の中身（Keep。texels が Some ならテクセル寸法の絵・None ならそのままの寸法で写す）。
  `pub type alias PassDraw = { format = RenderTarget.Format, base = Option[PassImage], clear = Option[Color], texels = Option[(Int32, Int32)] }`
- Pass 1 枚を how の決まりで描き出す（HeadlessRender が Pass ごとに呼ぶ入口）。
  `pub def renderPass(how: PassDraw, req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias, extraImages: Map[String, PassImage]): PassImage \ IO`
- 出力ピクセル寸法（design × scale、最低 1px）。
  `pub def outSize(req: RasterReq): (Int32, Int32)`
- tex 場が読む縮んだターゲットのテクセルの絵の名前（sprite で貼る design 寸法の絵と並べて images に入れる）。
  `pub def texelsName(name: String): String`
- img を w × h へ最近傍で写す。広げるとき（GL が Nearest で貼る式）は元の (floor((x+0.5)·元幅/w), floor((y+0.5)·元高/h))。
  `pub def resampleNearest(img: BufferedImage, w: Int32, h: Int32): BufferedImage \ IO`
- resampleNearest の PassImage 版（形式は変えない）。同じ寸法ならそのまま返す。
  `pub def resampleNearestPass(img: PassImage, w: Int32, h: Int32): PassImage \ IO`
- Pass の絵の寸法（テクセルの数）。
  `pub def passImageSize(img: PassImage): (Int32, Int32) \ IO`
- Pass の絵の 8bit の形（Rgba8Unorm はそのまま・Rgba16Float は各成分を 0..1 に切って 8bit に丸める）。
  `pub def toArgbImage(img: PassImage): BufferedImage \ IO`
- Rgba16Float の描き先の画素 i へ src (sr, sg, sb, sa) を blend で混ぜ、half に丸めて書く。sa は 0..1。
  `pub def blendPixelF(blend: DrawCmd.BlendMode, sr: Float64, sg: Float64, sb: Float64, sa: Float64, rgba: Array[Float64, r], i: Int32): Unit \ r`
- 色の成分 r, g, b（0..1）と alpha（0..1）を ARGB int へ。画素ごとに呼ぶ所（シェーダー面・
  `pub def argbOfRgba(r: Float64, g: Float64, b: Float64, a: Float64): Int32`
- ARGB 1 画素の合成（src を dst に重ねた結果。out の alpha は dst のまま —
  `pub def blendPixel(blend: DrawCmd.BlendMode, srcArgb: Int32, dstArgb: Int32): Int32`
- ARGB int から 8bit チャンネルを取り出す（shift = 24/16/8/0 = A/R/G/B）。
  `pub def channelOf(shift: Int32, argb: Int32): Int32`
- 扇割り三角形列から、点 at を含む三角形の補間色を引く（どの三角形にも入らなければ None）。
  `pub def gradSample(tris: List[(DrawCmd.GradVertex, DrawCmd.GradVertex, DrawCmd.GradVertex)], at: Vec2.Vec2): Option[DrawCmd.VertexTint]`
- size×size の正方形を pixelOf(x, y) で画素ごとに埋めて PNG に書く。
  `pub def writeRadialPng(size: Int32, pixelOf: (Int32, Int32) -> Int32, outPath: String): Unit \ IO`

## SoftRaster3d — `engine_tools/src/SoftRaster3d.flix`
- ビルボードの絵の α がこれ未満の画素は捨てる。
  `pub def billboardCutoff(): Float64`
- cutout の材質で、α がこれ未満の画素は捨てる。
  `pub def materialCutoff(): Float64`
- `pub def lightAt(env: Scene3d.Environment3d, pointLights: List[Scene3d.PointLight], spotLights: List[Scene3d.SpotLight], position: Vec3.Vec3, normal: Vec3.Vec3): Color`
- 目 eye から見た world の点 position の色 c に、距離のかすみを掛けた色（fog が None なら c のまま）。
  `pub def fogAt(env: Scene3d.Environment3d, eye: Vec3.Vec3, position: Vec3.Vec3, c: Color): Color`
- `pub def surfaceOutAt(env: Scene3d.Environment3d, eye: Vec3.Vec3, position: Vec3.Vec3, albedoLinear: Color, tint: Color, light: Color, emission: Color, intensity: Float64, fogOn: Bool): Color`
- 場面の影（影を落とすスポットが無ければ None）。生成した SoftRaster3dLight がスポットごとに shadowFactorAt へ渡す。
  `pub type alias SpotShadow = Option[Shadow]`
- スポットの並びの位置 offset のスポットが、world の点 (px, py, pz) へ届ける光に掛ける割合（影を落とさないスポットは 1）。
  `pub def shadowFactorAt(shadow: SpotShadow, offset: Int32, px: Float64, py: Float64, pz: Float64): Float64`
- `pub def shadowLitFractionAt(m: Vector[Float64], n: Int32, bias: Float64, pcfRadius: Int32, map: Vector[Float64], px: Float64, py: Float64, pz: Float64): Float64`
- スポットの並びの位置 offset のスポットが落とす影（引数は shadowLitFractionAt と同じ・strength = 影の濃さ）。
  `pub def spotShadowOf(offset: Int32, m: Vector[Float64], n: Int32, bias: Float64, pcfRadius: Int32, strength: Float64, map: Vector[Float64]): SpotShadow`
- 行列 m の 16 個（行優先）。shadowLitFractionAt の rows の形。
  `pub def rowMajorOf(m: Mat4.Mat4): Vector[Float64]`
- 場面 cmd を image へ重ねる。sf = design px → 出力の画素の倍率。textures = ビルボードと材質が引く絵（(名前, 段の平均の色空間) → 段の列。
  `pub def drawScene(image: BufferedImage, sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO`
- drawScene の Rgba16Float の描き先版。rgba = 描き先（1 画素に r, g, b, α の 4 つ）・size = その幅と高さ。
  `pub def drawSceneHdr(rgba: Array[Float64, Static], size: (Int32, Int32), sf: Float64, textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO`
- `pub def applyNormalMap(n: Vec3.Vec3, raw: Vec3.Vec3, w: Float64, strength: Float64, c: (Float64, Float64, Float64)): Vec3.Vec3`

## SoftRaster3dLight — `engine_tools/src/gen/SoftRaster3dLight.flix`
- lightingModel の光の量（toon の丸めまで済ませた値）。
  `pub def lightAt(steps: Int32, points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, ambientX: Float64, ambientY: Float64, ambientZ: Float64, hemisphere: Float64): (Float64, Float64, Float64)`
- lightmapLightingModel の光の量（lightmap は段つきで読んだ後の rgb を渡す）。
  `pub def lightmapLightAt(steps: Int32, points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, lightmapX: Float64, lightmapY: Float64, lightmapZ: Float64, lightmapSrgb: Float64, lightmapIntensity: Float64): (Float64, Float64, Float64)`
- fogModel の色（fog が無い場面では呼ばない）。
  `pub def fogAt(pX: Float64, pY: Float64, pZ: Float64, eyeX: Float64, eyeY: Float64, eyeZ: Float64, colorX: Float64, colorY: Float64, colorZ: Float64, fogColorX: Float64, fogColorY: Float64, fogColorZ: Float64, fogNear: Float64, fogFar: Float64): (Float64, Float64, Float64)`
- skyModel の空の色。
  `pub def skyAt(_dirX: Float64, dirY: Float64, _dirZ: Float64, zenithX: Float64, zenithY: Float64, zenithZ: Float64, horizonX: Float64, horizonY: Float64, horizonZ: Float64, groundX: Float64, groundY: Float64, groundZ: Float64, skyCurve: Float64): (Float64, Float64, Float64)`

## ToolsProcessEnv — `engine_tools/src/ToolsProcessEnv.flix`
- 今のプロセスの環境変数を丸ごと表にする。
  `pub def snapshot(): Map[String, String] \ IO`
