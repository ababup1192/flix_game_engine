<!-- engine v0.34.0 / 生成: 2026-10-08 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine_tools

`engine_tools/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

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
- シルエット PNG を生成する（renderPng の変形版）。対象を黒・背景を白で <name>.png に書く。
  `pub def silhouettePng(cfg: RenderConfig, scope: SilhouetteScope, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO`
- silhouettePng の「宣言シェーダー面も写す」版。地面・空・水面を ShaderDoc の面で
  `pub def silhouettePngWith(cfg: RenderConfig, scope: SilhouetteScope, drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO`
- pass 1 枚ぶんの宣言（Render.Pass のコマンド列版）。name はそのままテクスチャ名になり、
  `pub type alias PassSpec = { name = String, clear = RenderTarget.LoadOp, drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd] }`
- pass 1 枚を design 解像度（scale = 1）の画像に生成する。GL のターゲットが design ×1 の
  `pub def renderPassImage(cfg: RenderConfig, p: PassSpec, prev: Option[BufferedImage]): BufferedImage \ IO`
- renderPassImage の「先に生成したターゲットも参照できる」版。`images` は既に生成した pass の
  `pub def renderPassImageWith(cfg: RenderConfig, images: Map[String, BufferedImage], p: PassSpec, prev: Option[BufferedImage]): BufferedImage \ IO`
- 追加の生成済み画像（pass のレンダーターゲットなど）を textures に混ぜて本編を PNG に生成する。
  `pub def renderPngWithImages(cfg: RenderConfig, images: Map[String, BufferedImage], drawables: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd], surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO`
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
- stride 枚ごとに 1 枚を残す（0 番から）。
  `pub def every(stride: Int32, xs: List[a]): List[a]`

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
- 放置されたら自分から終わるまでの秒数。編集していない間にメモリを抱えたままに
  `pub def idleSecondsFromEnv(): Int64`
- port で待ち受けて、頼まれるたびに handle を呼ぶ。
  `pub def serve(port: Int32, idleSeconds: Int64, onRequest: Request -> Reply \ IO): Unit \ IO`
- "a=1&b=2" → 表。値の中の + は空白へ戻す（フォーム形式の最小限だけ）。
  `pub def parseParams(raw: String): Map[String, String]`

## ReplayScript — `engine_tools/src/ReplayScript.flix`
- 意味入力。メニューの ↑↓←→ と決定 / 取消 / 印付け。
  `pub enum Key with Eq, ToString { case Up case Down case Left case Right case Confirm case Cancel case Shift }`
- スクリプトの 1 手。KeyPress は 1 入力＋間フレーム、Wait は入力なしで n フレーム進める。
  `pub enum Step { case KeyPress(Key) case Wait(Int32) }`
- `Step` を任意の入力型 `k` へ一般化した 1 手。engine_world の Replay.Cue[i] と同じく、
  `pub enum PlayStep[k] { case Press(k) case Wait(Int32) }`
- スクリプトを実行する（入力型は `Key` に固定）。
  `pub def execute(betweenFrames: Int32, script: List[Step], applyKey: Key -> Unit \ ef1, tick: Unit -> Unit \ ef2): Unit \ ef1 + ef2`
- `execute` の多相版。入力アルファベット `k` を呼び側が選べる（方向 record・列挙・
  `pub def executeWith(betweenFrames: Int32, script: List[PlayStep[k]], applyKey: k -> Unit \ ef1, tick: Unit -> Unit \ ef2): Unit \ ef1 + ef2`

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
- バイト列をそのままファイルへ書き出す（副作用はここだけ）。
  `pub def writeBytes(path: String, bytes: Bytes): Unit \ IO`
- 音のセットをまとめて `dir` へ描き出す。`(名前, サンプル列)` ごとに `dir/名前.wav` を書き出す
  `pub def renderSet(cfg: Config, dir: String, sounds: List[(String, List[Float64])]): Unit \ IO`

## SoftRaster — `engine_tools/src/SoftRaster.flix`
- ラスタライズ要求。design 解像度の Drawable 群を `scale` 倍に拡大して `outPath` に PNG 出力。
  `pub type alias RasterReq = { drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd], design = Vec2.Vec2, scale = Int32, background = Color, texturePath = Map[String, String], fontTtf = String, fontAtlas = FontAtlas, outPath = String, shapeAntialias = Bool, textAntialias = Bool }`
- 追加フォント 1 本（既定フォント以外も混ぜて描き出すとき）。ttf = 実サイズ描き出し用の TTF、
  `pub type alias FontEntry = { ttf = String, atlas = FontAtlas }`
- 宣言シェーダー面 1 枚の headless ラスタライズ要求（Render.ShaderSurface と同形の
  `pub type alias SurfaceCmd = { rect = Rect2.Rect2, spec = ShaderDoc.Spec, time = Float64, mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode }`
- 「絵に出ない指定」1 種類ぶんの報告。attr は指定の名前、count は件数、hint は逃げ道。
  `pub type alias Dropped = { attr = String, count = Int32, hint = String }`
- この経路が描けずに落とす指定を数える（純粋・描き出す前に呼べる）。
  `pub def dropped(ds: List[GameEngine.Drawable]): List[Dropped]`
- 報告を 1 行の文へ（呼び出し側がそのまま出せる形）。
  `pub def droppedLine(x: Dropped): String`
- 要求を 1 枚の PNG に描き出して書き出す。
  `pub def render(req: RasterReq): Unit \ IO`
- 追加フォントつきの render。`extraFonts` はテクスチャ名（"font_girl" など。実機の
  `pub def renderFonts(req: RasterReq, extraFonts: Map[String, FontEntry]): Unit \ IO`
- シェーダー面つきの render（面は ShaderEval で画素評価して z 順に合流する）。
  `pub def renderWithSurfaces(req: RasterReq, surfaces: List[SurfaceCmd]): Unit \ IO`
- 追加の描き出し済み画像（pass のレンダーターゲットなど）も混ぜて描き、PNG に書き出す render。
  `pub def renderFull(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, BufferedImage]): Unit \ IO`
- 要求を 1 枚の BufferedImage に描き出して返す（PNG 書き出しはしない）。
  `pub def renderToImage(req: RasterReq): BufferedImage \ IO`
- renderToImage のシェーダー面つき版。surfaces は Drawable / Polygon と同じ
  `pub def renderToImageWith(req: RasterReq, surfaces: List[SurfaceCmd]): BufferedImage \ IO`
- renderToImageWith の複数フォント版。`extraFonts` はテクスチャ名 → 追加の本。
  `pub def renderToImageFonts(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry]): BufferedImage \ IO`
- renderToImageFonts の「追加の描き出し済み画像」つき版。`extraImages` はテクスチャ名 →
  `pub def renderToImageFull(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, BufferedImage]): BufferedImage \ IO`
- tex 場の欠け名を知らせた控え。GIF などコマ列の描き出しで同じ物を渡し続けると、
  `pub type alias TexWarnLog = Ref[Set[String], Static]`
- 欠け名の控えを新しく作る（コマ列の描き出しの前に 1 本作って持ち回る）。
  `pub def freshTexWarnLog(): TexWarnLog \ IO`
- renderToImageFull の欠け名控えつき版。控えは知らせの回数にだけ効き、
  `pub def renderToImageLogged(req: RasterReq, surfaces: List[SurfaceCmd], extraFonts: Map[String, FontEntry], extraImages: Map[String, BufferedImage], warnLog: TexWarnLog): BufferedImage \ IO`
- pass（レンダーターゲット）描き出し用の入口。req#background は使わない — 塗るかどうか
  `pub def renderPassImage(req: RasterReq, base: Option[BufferedImage], extraImages: Map[String, BufferedImage]): BufferedImage \ IO`
- ARGB 1 画素の合成（src を dst に重ねた結果。out の alpha は dst のまま —
  `pub def blendPixel(blend: DrawCmd.BlendMode, srcArgb: Int32, dstArgb: Int32): Int32`
- 扇割り三角形列から、点 at を含む三角形の補間色を引く（どの三角形にも入らなければ None）。
  `pub def gradSample(tris: List[(DrawCmd.GradVertex, DrawCmd.GradVertex, DrawCmd.GradVertex)], at: Vec2.Vec2): Option[DrawCmd.VertexTint]`
- size×size の正方形を pixelOf(x, y) で画素ごとに埋めて PNG に書く。
  `pub def writeRadialPng(size: Int32, pixelOf: (Int32, Int32) -> Int32, outPath: String): Unit \ IO`
