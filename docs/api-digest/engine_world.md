<!-- engine v0.34.0 / 生成: 2026-10-10 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine_world

`engine_world/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## ActiveDocs — `engine_world/src/ActiveDocs.flix`
- 書き出し先。debug/ は .gitignore 済みの作業用置き場。
  `pub def path(): String`
- entries(editor 宣言 id → 表示中パスの列)をエディタが読む形の JSON にする。
  `pub def json(entries: List[(String, List[String])]): String`
- entries の指紋(id とパスを区切り文字で 1 本に綴じた文字列)。step はまずこれで
  `pub def fingerprint(entries: List[(String, List[String])]): String`
- 毎フレームのシステムから呼ぶ。一覧の指紋が前回書いた物(World の activeDocsWritten)と
  `pub def step(entries: List[(String, List[String])], w: { activeDocsWritten = String | r }): { activeDocsWritten = String | r } \ Fs.FileWrite`

## Anim — `engine_world/src/Anim.flix`
- クリップ: シート上の 1 行ぶんの連続コマと再生のしかた（純データ）。
  `pub type alias Clip = { row = Int32, frames = Int32, fps = Float64, looping = Bool }`
- 時刻 t（ループは通し秒・単発は開始からの経過秒）でのコマ番号。
  `pub def frameAt(clip: Clip, t: Float64): Int32`
- コマ番号からシート上の矩形を導く（コマ寸法は呼び手が渡す）。Render.sprite の regionRect 用。
  `pub def regionOf(frameW: Float64, frameH: Float64, clip: Clip, frame: Int32): Rect2.Rect2`
- frameAt と regionOf をまとめた近道。
  `pub def regionAt(frameW: Float64, frameH: Float64, clip: Clip, t: Float64): Rect2.Rect2`

## Annotate — `engine_world/src/Annotate.flix`
- 一時停止中の見え方。zoom はデザイン中央を焦点にした一様拡大、pan はその後の平行移動。
  `pub type alias View = { zoom = Float64, pan = Vec2.Vec2, design = Vec2.Vec2 }`
- アノテーションモードの全状態。App のループが毎フレーム持ち回す。
  `pub type alias State = { paused = Bool, frame = Int64, zoom = Float64, pan = Vec2.Vec2, dragStart = Option[Vec2.Vec2], prevLeftDown = Bool, prevPanActive = Bool, prevMouse = Vec2.Vec2, toast = Option[{ message = String, framesLeft = Int32 }], scrub = Int32, scrubHold = Int32, scrubShow = Int32, fpsAvg = Float64 }`
- 一時停止中の 1 フレームぶんのマウスと画面の状態。App が effect で読んで渡す。
  `pub type alias MouseInput = { cursor = Vec2.Vec2, leftDown = Bool, middleDown = Bool, spaceDown = Bool, scroll = Float64, design = Vec2.Vec2 }`
- 起動直後の状態（等倍・停止していない・ドラッグしていない）。
  `pub def initial(): State`
- 状態から見え方を組む。
  `pub def viewOf(design: Vec2.Vec2, state: State): View`
- 一時停止を抜けるときに見え方とドラッグを等倍へ戻す（frame は保つ）。
  `pub def resetView(state: State): State`
- 停止中の ← → で「何フレーム前を見るか」を進める。押した瞬間は 1 フレームずつ、
  `pub def scrubStep(keys: { back = Bool, backEdge = Bool, fwd = Bool, fwdEdge = Bool }, historyLen: Int32, state: State): State`
- スクラブ位置の表示（「<< 42/300」= 300 フレームの履歴のうち 42 フレーム前を見ている）。
  `pub def scrubIndicatorItems(fontAtlas: FontAtlas, fontSize: Float64, design: Vec2.Vec2, scrub: Int32, historyLen: Int32): List[Render.PlacedItem]`
- 保存完了メッセージを表示し始める（60fps で約 4 秒）。
  `pub def showToast(message: String, state: State): State`
- メッセージの残り表示フレームを 1 減らし、尽きたら消す。
  `pub def tickToast(state: State): State`
- 保存完了メッセージの絵。画面左上に固定で置く。
  `pub def toastItems(fontAtlas: FontAtlas, fontSize: Float64, message: String): List[Render.PlacedItem]`
- このフレームの dt を平均へ混ぜる。最初の 1 回は dt をそのまま採用する
  `pub def recordDt(dt: Float64, state: State): State`
- 平均 dt から fps を出す（未計測なら 0）。表示用なので整数へ丸める。
  `pub def fpsOf(state: State): Int32`
- fps の絵。画面右上に固定で置く。
  `pub def fpsItems(fontAtlas: FontAtlas, fontSize: Float64, design: Vec2.Vec2, fps: Int32): List[Render.PlacedItem]`
- パネルの字の大きさの既定。実機のデバッグ表示は組み込みフォントの等倍で出すので、
  `pub def defaultBadgeFontSize(): Float64`
- デザイン座標 → 画面座標。デザイン中央 c を焦点に zoom 倍し、pan だけずらす。
  `pub def toScreen(view: View, p: Vec2.Vec2): Vec2.Vec2`
- 画面座標 → デザイン座標（toScreen の逆写像）。
  `pub def toDesign(view: View, p: Vec2.Vec2): Vec2.Vec2`
- カーソル位置を動かさずに拡大率を変える（虫眼鏡の中心が指先に付いてくる）。
  `pub def zoomAt(cursor: Vec2.Vec2, delta: Float64, view: View): { zoom = Float64, pan = Vec2.Vec2 }`
- pan を「デザイン領域が画面からはみ出さない」範囲に収める。
  `pub def clampPan(zoom: Float64, design: Vec2.Vec2, pan: Vec2.Vec2): Vec2.Vec2`
- 一時停止中のマウス操作をひとつ進める。戻り値は (次の状態, 確定した注釈矩形)。
  `pub def step(input: MouseInput, state: State): (State, Option[Rect2.Rect2])`
- 2 点からどちら向きのドラッグでも同じ「左上 + 幅高さ」の矩形を作る。
  `pub def normRect(a: Vec2.Vec2, b: Vec2.Vec2): Rect2.Rect2`
- 2 つの矩形が重なっているか（辺が触れているだけでも重なり扱い）。
  `pub def rectIntersects(a: Rect2.Rect2, b: Rect2.Rect2): Bool`
- 矩形に重なっていた描画物 1 件の記述。注釈 JSON にそのまま載る。
  `pub type alias Hit = { kind = String, name = String, position = Vec2.Vec2, zIndex = Int32, aabb = Rect2.Rect2 }`
- 注釈矩形に重なる描画物を列挙する。テクスチャの寸法は sizeOf で引く
  `pub def hits(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef, rect: Rect2.Rect2, items: List[Render.PlacedItem]): List[Hit] \ ef`
- 描画物 1 件を覆う矩形（デザイン座標）。回転は無視した外形の近似。
  `pub def itemAabb(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef, placed: Render.PlacedItem): Rect2.Rect2 \ ef`
- 描画命令（Drawable）の列から矩形に重なる物を列挙する。view を持たず生の描画チャンネルを
  `pub def hitsFromDrawables(sizeOf: String -> Option[GameEngine.TextureInfo] \ ef, rect: Rect2.Rect2, ds: List[GameEngine.Drawable]): List[Hit] \ ef`
- annotation.json の本文。デザイン座標の矩形と、重なっていた描画物の一覧を機械可読に残す。
  `pub def annotationJson(meta: { frame = Int64, design = Vec2.Vec2, rect = Rect2.Rect2 }, hitList: List[Hit]): String`
- README.md に挟む人間向けの要約（囲った場所と、そこに描かれていた物）。
  `pub def readmeBody(meta: { frame = Int64, rect = Rect2.Rect2 }, hitList: List[Hit]): String`
- ドラッグ中の矩形オーバーレイ（薄い塗り + 枠線）。デザイン座標の列に混ぜて描く。
  `pub def overlayItems(dragStart: Vec2.Vec2, cursorDesign: Vec2.Vec2): List[Render.PlacedItem]`
- 描画命令の列へ見え方（ズーム・パン）を適用する。位置は toScreen、大きさは zoom 倍。
  `pub def applyInspect(view: View, ds: List[GameEngine.Drawable]): List[GameEngine.Drawable]`
- 多角形の描画命令へ見え方を適用する（頂点は画面 px の絶対座標なので各頂点を写す）。
  `pub def applyInspectPoly(view: View, ps: List[GameEngine.PolygonRenderCmd]): List[GameEngine.PolygonRenderCmd]`
- タイルマップの描画命令へ見え方を適用する（位置は toScreen、タイル倍率は zoom 倍）。
  `pub def applyInspectTiles(view: View, ts: List[GameEngine.TileMapRenderCmd]): List[GameEngine.TileMapRenderCmd]`

## App — `engine_world/src/App.flix`
- このフレームの入力と時計のスナップショット。キーの生読みはランナーが済ませてあるので、
  `pub type alias Frame = { down = Set[GameEngine.Key], justPressed = Set[GameEngine.Key], dt = Float64, viewport = Vec2.Vec2, cursor = Vec2.Vec2, mouseDown = Bool, mouseClicked = Bool, mouseMoved = Bool, wheel = Float64 }`
- key がいま押されているか（押しっぱなしも true）。移動などの連続入力に。
  `pub def isDown(key: GameEngine.Key, frame: Frame): Bool`
- key がこのフレームで新しく押されたか（押しっぱなしは false）。決定・発射などの単発入力に。
  `pub def justPressed(key: GameEngine.Key, frame: Frame): Bool`
- 負方向・正方向のキーの押し下げを -1 / 0 / +1 にまとめる（両押しは打ち消して 0）。
  `pub def axis(negative: {negative = GameEngine.Key}, positive: {positive = GameEngine.Key}, frame: Frame): Float64`
- view / hudView が受け取る「この 1 フレームの見え方」。atlas は文字描画用の既定フォント、
  `pub type alias ViewCtx = { atlas = FontAtlas, fontOf = String -> FontAtlas, visible = Rect2.Rect2 }`
- ヘッドレス描き出しから view を呼ぶときの ViewCtx。画面全体が見えている扱いにする。
  `pub def viewCtxOf(atlas: FontAtlas, design: Vec2.Vec2): ViewCtx`
- viewCtxOf の複数フォント版。fontOf には実機と同じ名前で引ける関数を渡す
  `pub def viewCtxOfFonts(atlas: FontAtlas, fontOf: String -> FontAtlas, design: Vec2.Vec2): ViewCtx`
- 生成したドット絵アトラス 1 枚ぶんの受け渡し。
  `pub type alias AtlasUpload = { texture = String, key = String, baked = PxSpriteAtlas.Baked }`
- ゲーム 1 本の宣言。make で空を作り、addStartup / addSystem / reloadOn / withView /
  `pub type alias App[w: Type, ef: Eff] = { init = Vec2.Vec2 -> w \ ef, startupSystems = List[w -> w \ ef], updateSystems = List[(Frame, w) -> w \ ef], reload = Option[(GameEngine.Key, w -> w \ {Fs.FileRead})], watch = List[(String, w -> w \ {Fs.FileRead})], view = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef], passes = w -> List[Render.Pass] \ ef, fonts = List[String], camera = Option[w -> Vec2.Vec2 \ ef], zoom = Option[w -> Float64 \ ef], cameraBounds = Option[w -> Rect2.Rect2 \ ef], parallaxLayers = List[(Float64, (ViewCtx, w) -> List[Render.PlacedItem] \ ef)], hudView = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef], audio = { before = w, after = w } -> List[String] \ ef, sustained = w -> List[Sustain] \ ef, quit = (Frame, w) -> Bool \ ef, debug = Bool, debugView = Option[(String, w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef)], worldDump = Option[(Rect2.Rect2, w) -> String \ ef], staticLayer = Option[{ key = w -> GameEngine.StaticKey, build = w -> List[Render.PlacedItem] }], tileLayers = Option[w -> List[TileLayerSpec]], spriteAtlases = w -> List[AtlasUpload], pixelSnap = w -> Float64, statusLine = Option[w -> String \ ef], remoteRender = Option[Unit -> List[String] \ IO], remoteHandlers = List[(String, (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead})], fixedStep = Option[Float64] }`
- 初期 World だけを持つ空の App。絵はまだ無い（withView で繋ぐまで何も描かない）。
  `pub def make(init: w): App[w, ef]`
- 初期 World を design 解像度（project.json の designWidth/Height）から組む入口。
  `pub def makeWith(f: Vec2.Vec2 -> w \ ef): App[w, ef]`
- 起動時に 1 回だけ走るシステムを末尾へ繋ぐ（追加順に適用される）。
  `pub def addStartup(sys: w -> w \ ef, app: App[w, ef]): App[w, ef]`
- 毎フレーム走るシステムを末尾へ繋ぐ（追加順に適用される）。
  `pub def addSystem(sys: (Frame, w) -> w \ ef, app: App[w, ef]): App[w, ef]`
- key が押された瞬間に World を作り直すホットリロードを繋ぐ（ファイル読みの副作用つき）。
  `pub def reloadOn(key: GameEngine.Key, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef]`
- path の保存（更新時刻の変化）を検知して World を作り直すホットリロードを繋ぐ。
  `pub def watchFile(path: String, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef]`
- World を絵（(置き場所, 見せたい物) の列）へ投影する関数を繋ぐ。
  `pub def withView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef, app: App[w, ef]): App[w, ef]`
- 本編より先にレンダーターゲット（描いた結果を読み返せる描き込み先）へ描く列を
  `pub def withPasses(f: w -> List[Render.Pass] \ ef, app: App[w, ef]): App[w, ef]`
- 既定フォント以外に使うフォントの名前を宣言する（project.json の fonts[].name と同じ字）。
  `pub def withFonts(names: List[String], app: App[w, ef]): App[w, ef]`
- ゲーム 1 本の標準形を 1 つのレコードで宣言する入口（初学者向け）。
  `pub def game(spec: { init = w, update = (Frame, w) -> w \ ef, view = (ViewCtx, w) -> List[Render.PlacedItem] \ ef, reloads = List[(String, w -> w \ {Fs.FileRead})] }): App[w, ef]`
- カメラを何 px の升目に吸着させるかを World から読む（ドット絵のゲームは 1.0・0 で切る）。
  `pub def withPixelSnap(f: w -> Float64, app: App[w, ef]): App[w, ef]`
- ドット絵のアトラス（PxSpriteAtlas.bake の生成結果）を、名前付きテクスチャとして
  `pub def withSpriteAtlases(f: w -> List[AtlasUpload], app: App[w, ef]): App[w, ef]`
- 「1 度だけ GPU に生成して使い回す静的な絵」を宣言する。key は静的な中身を決める全入力を
  `pub def withStaticLayer(key: w -> GameEngine.StaticKey, build: w -> List[Render.PlacedItem], app: App[w, ef]): App[w, ef]`
- タイルの層（床・壁 1 行目など、格子に敷く静的な絵）を宣言する。エンジンが Spec ごとに
  `pub def withTileLayers(f: w -> List[TileLayerSpec], app: App[w, ef]): App[w, ef]`
- World から「画面中央に映したい world 座標」を導く関数を繋ぐ。view は world 座標のまま
  `pub def withCamera(f: w -> Vec2.Vec2 \ ef, app: App[w, ef]): App[w, ef]`
- World から寄り引き倍率（大きいほど寄る）を導く関数を繋ぐ。絵のずらしと大きさの
  `pub def withZoom(f: w -> Float64 \ ef, app: App[w, ef]): App[w, ef]`
- camera が映してよい world の矩形（レベルの端）を導く関数を繋ぐ。見えている範囲
  `pub def withCameraBounds(f: w -> Rect2.Rect2 \ ef, app: App[w, ef]): App[w, ef]`
- 視差レイヤを末尾へ繋ぐ（addSystem と同じ「列に足す」様式）。view と同じ
  `pub def addParallaxLayer(factor: Float64, v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef, app: App[w, ef]): App[w, ef]`
- カメラを掛けない絵（スコア等の HUD）を繋ぐ。ここに繋いだ絵は常に view の絵より
  `pub def withHudView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef, app: App[w, ef]): App[w, ef]`
- 1 フレームの前後の World（{before, after}）から鳴らす音名を導く関数を繋ぐ
  `pub def withAudio(sfx: { before = w, after = w } -> List[String] \ ef, app: App[w, ef]): App[w, ef]`
- 鳴り続けてほしい音 1 本の宣言。name は project.json の sounds の論理名、
  `pub type alias Sustain = { name = String, volume = Float64, pitch = Float64 }`
- 「このフレームで鳴り続けていてほしい音」を World から導く関数を繋ぐ。
  `pub def withSustained(f: w -> List[Sustain] \ ef, app: App[w, ef]): App[w, ef]`
- 前のフレームの宣言（名前の列）と今のフレームの宣言から、鳴らし始める音・
  `pub def sustainOps(prev: List[String], next: List[Sustain]): { start = List[Sustain], keep = List[Sustain], stop = List[String] }`
- 終了判定を差し替える。既定は「Escape のエッジで終了」だが、モーダル表示中は
  `pub def quitWhen(f: (Frame, w) -> Bool \ ef, app: App[w, ef]): App[w, ef]`
- デバッグ機能（F8 の時間停止・矩形注釈・時間スクラブ）の有効 / 無効を宣言する。
  `pub def withDebug(enabled: Bool, app: App[w, ef]): App[w, ef]`
- 環境変数 DEBUG が空でない値で設定されていれば true（例: `DEBUG=true flix run`）。
  `pub def debugFromEnv(): Bool \ IO`
- 自前描画（view = None）のゲームがデバッグ機能（F8）を使えるようにする生投影を繋ぐ。
  `pub def withDebugView(font: {font = String}, f: w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef, app: App[w, ef]): App[w, ef]`
- 注釈（F8 の矩形）を書き出すとき「囲った瞬間の World」をテキストにしてチケットへ
  `pub def withWorldDump(f: (Rect2.Rect2, w) -> String \ ef, app: App[w, ef]): App[w, ef]`
- World の 1 行サマリ（例: "phase=Playing ball=(163.2,207.9) lives=3"）を繋ぐ。
  `pub def withStatusLine(f: w -> String \ ef, app: App[w, ef]): App[w, ef]`
- リモートデバッグ（HTTP）の POST /render が実行する「描き出しの実体」を繋ぐ。
  `pub def onRenderRequest(f: Unit -> List[String] \ IO, app: App[w, ef]): App[w, ef]`
- リモートデバッグ（HTTP）の任意パス（例: "/save"）に応えるハンドラを繋ぐ。
  `pub def onRequest(path: String, f: (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead}, app: App[w, ef]): App[w, ef]`
- 物理・当たり判定を固定刻み（dtSeconds 秒）で進める accumulator 方式を有効にする。
  `pub def withFixedStep(dtSeconds: Float64, app: App[w, ef]): App[w, ef]`
- 前フレームと今フレームのキー集合から Frame を組む。justPressed は差分
  `pub def frameOf(prev: {prev = Set[GameEngine.Key]}, current: {current = Set[GameEngine.Key]}, dt: Float64, viewport: Vec2.Vec2, cursor: {prevCursor = Option[Vec2.Vec2], cursor = Vec2.Vec2}, mouse: {prevDown = Bool, down = Bool, wheel = Float64}): Frame`
- withFixedStep の accumulator。持ち越し carry と実フレームの経過秒 realDt を足し、
  `pub def fixedSteps(carry: Float64, realDt: Float64, fixedDt: Float64): (Int32, Float64)`
- withFixedStep の 2 サブステップ目以降に渡す Frame: エッジ 4 種（justPressed /
  `pub def suppressEdges(frame: Frame): Frame`
- 0 サブステップのフレームで捨てられそうになったエッジのバッファ。エッジは prev との
  `pub type alias PendingEdges = { justPressed = Set[GameEngine.Key], mouseClicked = Bool, mouseMoved = Bool, wheel = Float64 }`
- withFixedStep がフレームをまたいで持ち回す状態（持ち越し秒 + 未消費エッジ）。
  `pub type alias StepState = { carry = Float64, pending = PendingEdges }`
- 起動直後の StepState（貯金ゼロ・未消費エッジなし）。
  `pub def freshStepState(): StepState`
- バッファしたエッジを今フレームの Frame へ合流させる: justPressed は和集合・
  `pub def mergeEdges(pending: PendingEdges, frame: Frame): Frame`
- Frame からエッジ 4 種を抜き出してバッファの形にする（0 ステップのフレームの持ち越し用）。
  `pub def pendingOf(frame: Frame): PendingEdges`
- システムの列を追加順（左から右）に World へ畳み込む。
  `pub def applySystems(frame: Frame, systems: List[(Frame, w) -> w \ ef], world: w): w \ ef`
- 1 実フレームぶんの updateSystems 適用。fixedStep 未指定なら現行どおり frame を 1 回
  `pub def advanceFrame(app: App[w, ef], frame: Frame, state: StepState, world: w): (w, StepState) \ ef`
- view 由来の絵（world）に camera（center と zoom。等倍は 1.0）を掛け、hud の絵を
  `pub def composeScene(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2, items: { world = List[Render.PlacedItem], hud = List[Render.PlacedItem] }): List[Render.PlacedItem]`
- camera 中心と zoom から、画面に見えている world の矩形を出す（大きさ design/zoom。
  `pub def visibleOf(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2): Rect2.Rect2`
- 監視中パスのうち「World を作り直すべき物」を watch の登録順で返す: current で見えて
  `pub def changedPaths(watch: List[String], prev: Map[String, Int64], current: Map[String, Int64]): List[String]`
- App を走らせる単一の効果多相ランナー。startup を 1 回だけ畳み込み、いま押されているキーを prev の
  `pub def launch(app: App[w, ef]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + IO)`
- 時間スクラブ用に持ち回す直近の World の数（60fps で約 30 秒）。
  `pub def historyLimit(): Int32`
- リモートコマンドを捌いた後に残る 3 つの進み方。
  `pub enum Branch with Eq, ToString { case Paused case Resuming case Running }`
- F8 と停止状態から、このフレームの進み方と「F8 が今トグルされたか」を決める。
  `pub def decideBranch(input: { f8Pressed = Bool, canDebug = Bool, remoteHold = Bool, wasPaused = Bool }): { branch = Branch, toggled = Bool }`
- 一時停止を抜ける地点: スクラブで表示していた瞬間の World を現在とし、
  `pub def resumePoint(anno: Annotate.State, history: List[w], world: w): { world = w, anno = Annotate.State, history = List[w] }`
- 履歴の back フレーム前の World（範囲外なら fallback）。先頭が「停止した瞬間」。
  `pub def worldAt(history: List[w], back: Int32, fallback: w): w`
- reloadOn で繋いだキーが押された瞬間だけ、リロード関数で World を作り直す。
  `pub def applyReload(app: App[w, ef], frame: Frame, world: w): (w, Bool) \ {Fs.FileRead}`
- RemoteDebug 分割用の内部 API — ゲームからは呼ばない。
  `pub def sceneItems(app: App[w, ef], atlas: FontAtlas, world: w, toItems: (ViewCtx, w) -> List[Render.PlacedItem] \ ef): List[Render.PlacedItem] \ (ef + GameEngine.Game)`
- タイル層の GPU 生成結果の持ち回し。ループが引数で持ち回す。
  `pub type alias TileCache =`
- まだ何も生成していない起動時の持ち回し。
  `pub def freshTileCache(): TileCache`
- `pub def bumpTileGen(fired: Bool, cache: TileCache): TileCache`
- スロットに取ってある生成結果を引く。生成した時点の世代と key が今と一致した時だけ使い回せる。
  `pub def tileCacheHit(slot: String, key: String, cache: TileCache): Option[(GpuHandle.TileVao, Int32)]`
- スロットに生成結果があれば、その VAO を返す（世代・key が古くてもよい —
  `pub def tileCacheVaoAt(slot: String, cache: TileCache): Option[GpuHandle.TileVao]`
- 生成した結果をスロットへ上書きで置く（一覧表は宣言中のレイヤーの数までしか育たない）。
  `pub def tileCacheStore(slot: String, key: String, vao: GpuHandle.TileVao, count: Int32, cache: TileCache): TileCache`

## AudioFade — `engine_world/src/AudioFade.flix`
- フェードの端点。start = 進行度 0 のときの音量、target = 進行度 1 のときの音量
  `pub type alias Fade = { start = Float64, target = Float64 }`
- フェードイン（無音 → 全開）の端点。
  `pub def fadeIn(): Fade`
- フェードアウト（全開 → 無音）の端点。
  `pub def fadeOut(): Fade`
- 進行度 t（[0,1] にクランプ）から音量をひとつ決める。start と target の間の直線上の値。
  `pub def volumeOf(fade: Fade, t: Float64): Float64`
- 2 曲の入れ替え: 同じ t で「消える側・現れる側」の音量の組を返す。
  `pub def crossfadeOf(t: Float64): (Float64, Float64)`

## Bezier — `engine_world/src/Bezier.flix`
- 2 次ベジエを steps 分割した折れ線にする（始点・終点を含む steps+1 点）。
  `pub def quadratic(p0: Vec2.Vec2, ctrl: Vec2.Vec2, p1: Vec2.Vec2, steps: Int32): List[Vec2.Vec2]`
- 3 次ベジエを steps 分割した折れ線にする。
  `pub def cubic(p0: Vec2.Vec2, c1: Vec2.Vec2, c2: Vec2.Vec2, p1: Vec2.Vec2, steps: Int32): List[Vec2.Vec2]`
- stroke の引数一式。spine = 背骨の折れ線（quadratic/cubic の出力）、color/z = 塗り。
  `pub type alias Stroke = { spine = List[Vec2.Vec2], color = Color, z = Int32 }`
- 背骨に太さを付けたストリップ。widthOf は背骨上の位置 t（0=始点..1=終点）→ その場所の太さで、
  `pub def stroke(s: Stroke, widthOf: Float64 -> Float64): List[Render.PlacedItem]`
- fill の別名（旧呼び出し向け）。新規コードは fill を使う。
  `pub def convexFill(outline: List[Vec2.Vec2], color: Color, z: Int32): List[Render.PlacedItem]`
- 閉じた輪郭を 1 枚の多角形として塗る。自己交差しない単純多角形なら深くえぐれた形
  `pub def fill(outline: List[Vec2.Vec2], color: Color, z: Int32): List[Render.PlacedItem]`
- 折れ線を一定幅のストリップで描く（節は丸い継ぎ目でつなぐ）。単発の線分 1 本だけなら
  `pub def polyline(points: List[Vec2.Vec2], width: {width = Float64}, color: Color, z: Int32): List[Render.PlacedItem]`
- 5 芒星の輪郭（上向き）。頂点列なので fill で塗る・stroke の背骨にする・加工する、が自由。
  `pub def star(center: Vec2.Vec2, rOut: {rOut = Float64}, rIn: {rIn = Float64}): List[Vec2.Vec2]`
- 楕円の輪郭（segments は 16〜24 で十分丸い）。頂点列なので fill・stroke・加工が自由。
  `pub def ellipse(center: Vec2.Vec2, rx: Float64, ry: Float64, segments: Int32): List[Vec2.Vec2]`
- 回転つき楕円の輪郭（angle ラジアン。y 下向きの画面座標では正 = 時計回り）。
  `pub def ellipseRot(center: Vec2.Vec2, rx: Float64, ry: Float64, angle: Float64, segments: Int32): List[Vec2.Vec2]`

## Calendar — `engine_world/src/Calendar.flix`
- 暦の決まり。1 日の長さ・1 時間の長さ・1 分に掛ける実時間・1 季節の日数・季節の名前。
  `pub type alias Spec = { minutesPerDay = Int32, minutesPerHour = Int32, secondsPerMinute = Float64, daysPerSeason = Int32, seasons = List[String] }`
- いまが世界の何分目か。carry は「次の 1 分までに貯まった実時間の端数」。
  `pub type alias Stamp = { minute = Int32, carry = Float64 }`
- よくある形（24 時間 = 1440 分・1 分 ≒ 0.7 秒 = 1 日約 17 分・1 季節 28 日・四季）。
  `pub def defaults(): Spec`
- day 日目（0 始まり）の minuteOfDay 分に時計を合わせる。起床・寝直しに使う。
  `pub def at(spec: Spec, day: Int32, minuteOfDay: Int32): Stamp`
- 実時間 dt 秒ぶん時を進める。1 フレームで何分進んでも取りこぼさない。
  `pub def advance(spec: Spec, dt: Float64, s: Stamp): Stamp`
- 次の日の minuteOfDay 分へ飛ばす（寝る）。すでにその時刻を過ぎていても必ず翌日になる。
  `pub def sleepTo(spec: Spec, minuteOfDay: Int32, s: Stamp): Stamp`
- 通算の日（0 始まり）。
  `pub def dayOf(spec: Spec, s: Stamp): Int32`
- その日の何分目か（0 〜 minutesPerDay-1）。
  `pub def minuteOfDay(spec: Spec, s: Stamp): Int32`
- 何時か（0 始まり）。
  `pub def hourOf(spec: Spec, s: Stamp): Int32`
- その時の何分目か。
  `pub def minuteOfHour(spec: Spec, s: Stamp): Int32`
- 1 日の進み具合（0.0 = 日付が変わった瞬間、1.0 手前 = その日の終わり）。
  `pub def dayFraction(spec: Spec, s: Stamp): Float64`
- いまが何季節目か（0 始まり・seasons の添字）。
  `pub def seasonIndexOf(spec: Spec, s: Stamp): Int32`
- いまの季節の名前。名前が 1 つも無ければ空文字（fail-open）。
  `pub def seasonOf(spec: Spec, s: Stamp): String`
- その季節の何日目か（1 始まり — 画面に出す数）。
  `pub def dayOfSeason(spec: Spec, s: Stamp): Int32`
- 何年目か（1 始まり — 画面に出す数）。
  `pub def yearOf(spec: Spec, s: Stamp): Int32`
- 週の何日目か（0 始まり）。週の長さは呼び側が決める（7 日なら 7 を渡す）。
  `pub def dayOfWeek(spec: Spec, weekLength: Int32, s: Stamp): Int32`
- 日付が変わったか（before から after の間に日をまたいだか）。
  `pub def dayRolled(spec: Spec, before: Stamp, after: Stamp): Bool`
- "6:30" の形。分は 2 桁に揃える。
  `pub def hhmm(spec: Spec, s: Stamp): String`
- "春 12日目" の形。
  `pub def dateLabel(spec: Spec, s: Stamp): String`

## CameraRig — `engine_world/src/CameraRig.flix`
- zoom の下限。これ未満（0・負・NaN 含む）は safeZoom がここへ丸める。
  `pub def minZoom(): Float64`
- zoom の上限。これ超過（Infinity 含む）は safeZoom がここへ丸める。
  `pub def maxZoom(): Float64`
- zoom の防波堤: minZoom〜maxZoom の外（0 以下・NaN・Infinity・過大値）を範囲内へ丸める。
  `pub def safeZoom(z: Float64): Float64`
- center を画面中央に zoom 倍（大きいほど寄る・等倍は 1.0）で映す:
  `pub def centerOn(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2}, items: List[Render.PlacedItem]): List[Render.PlacedItem]`
- world 座標 → 画面座標（centerOn が各 item の置き場所に使う式そのもの）:
  `pub def toScreenPos(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2}, world: {world = Vec2.Vec2}): Vec2.Vec2`
- center を中央に映したとき画面に見える world 範囲（大きさ design/zoom —
  `pub def visibleRect(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2}): Rect2.Rect2`
- 画面座標 → world 座標（centerOn の逆変換）: world = (screen − design/2) / zoom + center。
  `pub def toWorldPos(center: Vec2.Vec2, zoom: {zoom = Float64}, design: {design = Vec2.Vec2}, screen: {screen = Vec2.Vec2}): Vec2.Vec2`
- camera の center を「見えている範囲（seen = design/zoom）が bounds の内側に収まる」位置へ
  `pub def clampCenter(bounds: {bounds = Rect2.Rect2}, seen: {seen = Vec2.Vec2}, center: Vec2.Vec2): Vec2.Vec2`
- 視差レイヤの見かけの camera 中心: 画面中央と本来の center を factor で混ぜる。
  `pub def parallaxCenter(factor: Float64, center: Vec2.Vec2, design: {design = Vec2.Vec2}): Vec2.Vec2`
- 追従の仕様: 不感帯の幅と寄せ率（1 秒あたり）。
  `pub type alias Follow = { deadzone = Float64, k = Float64 }`
- target が current±deadzone の不感帯を出たぶん × min(1, k×dt) の移動量。
  `pub def followDelta(spec: Follow, dt: Float64, target: Float64, current: Float64): Float64`
- lo..hi へ収める（hi < lo なら lo）。カメラをレベルの内側に留めるのに使う。
  `pub def clampAxis(lo: Float64, hi: Float64, x: Float64): Float64`
- シェイクの調整値。maxOffset は trauma 満タン（1.0）のときの揺れ幅（px）、
  `pub type alias ShakeSpec = { maxOffset = Float64, freq = Float64, decayPerSecond = Float64 }`
- 揺れを積む: trauma に amount を加算する（上限 1.0）。減衰（tick）より速く積めば蓄積し、
  `pub def addTrauma(amount: Float64, state: { trauma = Float64 | r }): { trauma = Float64 | r }`
- 揺れの経年: trauma を減衰させ（下限 0.0）、通し時計 fxClock を進める。毎フレーム 1 回 dt を渡す。
  `pub def tick(dt: Float64, spec: ShakeSpec, state: { trauma = Float64, fxClock = Float64 | r }): { trauma = Float64, fxClock = Float64 | r }`
- trauma からの揺れ幅（px）: trauma² × maxOffset。二乗なので単発の小さな trauma は
  `pub def shakeStrength(trauma: Float64, maxOffset: {maxOffset = Float64}): Float64`
- シェイクのオフセット（px）: 揺れ幅（shakeStrength）× 滑らかノイズ [-1, 1]。
  `pub def shakeOffset(spec: ShakeSpec, state: { trauma = Float64, fxClock = Float64 | r }): Vec2.Vec2`
- 滑らかな 1D ノイズ [-1, 1]: 整数の格子点に Hash01 の値を置き、間を quintic フェード
  `pub def smoothNoise(t: Float64, channel: Int32): Float64`

## CatalogContainer — `engine_world/src/CatalogContainer.flix`
- 1 container の中身。
  `pub enum CatalogContainer[t] { case CatalogContainer({ containerKey = String, entries = Map[String, t], meta = Map[String, Json] }) }`
- entries だけを取り出すアクセサ。
  `pub def entriesOf(catalog: CatalogContainer[t]): Map[String, t]`
- meta フィールド (containerKey 以外の top-level フィールド) を取り出す。
  `pub def metaOf(catalog: CatalogContainer[t]): Map[String, Json]`
- 1 件を id で引く。境界: 未定義 id は None。
  `pub def get(id: String, catalog: CatalogContainer[t]): Option[t]`
- catalog を JSON object として encode する。
  `pub def encode(encodeEntry: t -> Json, catalog: CatalogContainer[t]): Json`
- JSON object から containerKey 配下を entries、残りを meta として decode する。
  `pub def decode(containerKey: String, decodeEntry: Json -> Option[t], element: Json): Option[CatalogContainer[t]]`
- `LoadSpec` の各フィールドを使った起動時の典型処理:
  `pub def loadWithCheck(spec: LoadSpec[t]): Result[String, CatalogContainer[t]] \ Fs.FileRead`
- `loadWithCheck` の引数を 1 つの record にまとめたもの。フィールドが多くなりがちなので
  `pub type alias LoadSpec[t] = { dataPath = String, schemaPath = String, containerKey = String, expectedFields = Set[String], decodeEntry = Json -> Option[t] }`

## Clock — `engine_world/src/Clock.flix`
- 反復タイマー: acc に dt を足し、interval に達したら（== も含む）1回 fire（rest に余りを残す）。
  `pub def tick(acc: Float64, dt: Float64, interval: Float64): {fired = Bool, rest = Float64}`
- カウントダウン: 残り時間を dt 減らし、0 で下げ止める。Timer(oneShot=true) 相当。
  `pub def countdown(remaining: Float64, dt: Float64): Float64`

## Collision — `engine_world/src/Collision.flix`
- 衝突の形（engine の CollisionShape2D を再利用）＋ layer/mask（engine と同じ意味論）。
  `pub type alias Collider = { shape = CollisionShape2D, layer = Int32, mask = Int32 }`
- position と collider を両方持つ entity から、衝突しているペアを列挙する。
  `pub def detectCollisions(positions: Map[EntityId, Vec2.Vec2], colliders: Map[EntityId, Collider]): List[(EntityId, EntityId)]`

## Curve — `engine_world/src/Curve.flix`
- 進行度0から始まり、中央で1、進行度1で0へ戻る放物線。
  `pub def arch01(progress: Float64): Float64`
- 速さ `speed` で増える量を `span` で折り返し、[0, span) に収めた値。落ち物や流れる
  `pub def loop(speed: Float64, span: Float64, t: Float64): Float64`
- 中心 0 のまわりを振幅 `amp` で往復する波。`freq` は 1 秒あたりの角速度（ラジアン）、
  `pub def sine(amp: Float64, freq: Float64, phase: Float64, t: Float64): Float64`
- 一定の角速度 `rate`（ラジアン毎秒）で回り続ける角度。回転する装飾や針に使う。
  `pub def spin(rate: Float64, t: Float64): Float64`
- 周期 `period` で 0→1→0 を往復する三角波。前半で 0 から 1 へ直線で昇り、後半で
  `pub def tri(period: Float64, t: Float64): Float64`
- [-1,1] の三角波（sin の直線版・速さ一定）。0 から立ち上がり、1/4 周期で +1、1/2 で 0、
  `pub def triWave(u: Float64): Float64`
- 減衰バネ: 振幅 `amp` から始まり、`decay`（1 秒あたりの減り・大きいほど早く静まる）で
  `pub def dampedSpring(amp: Float64, decay: Float64, freq: Float64, t: Float64): Float64`
- (時刻, 値) の折れ線を `t` で読んだ値。`keyframes` は時刻の昇順。区間内は線形に
  `pub def pieces(keyframes: List[(Float64, Float64)], t: Float64): Float64`

## Daylight — `engine_world/src/Daylight.flix`
- 空気の色の節。at = 1 日のどこか（0.0〜1.0）、color = そのときの色、
  `pub type alias Key = { at = Float64, color = Color, strength = Float64 }`
- よくある一日（夜明け前の紺 → 朝の淡い青 → 昼は素通し → 夕方の橙 → 夜の紺）。
  `pub def defaults(): List[Key]`
- t（1 日の進み）のときの空気の色と濃さ。節が 1 つも無ければ素通し。
  `pub def sample(keys: List[Key], t: Float64): Key`
- いまの空気を 1 枚の幕で掛ける。at / size = 覆う矩形、z = 掛かる境目。
  `pub def overlay(spec: { keys = List[Key], at = Vec2.Vec2, size = Vec2.Vec2, z = Int32 }, t: Float64): List[Render.PlacedItem]`
- 空気の色を 1 つの色に掛ける。空そのものや遠景など、乗算の幕より手前に置きたい物を
  `pub def tint(keys: List[Key], t: Float64, base: Color): Color`
- 地面に落ちる影の落ち方。dir = 伸びる向き（単位ベクトル）、
  `pub type alias Shadow = { dir = Vec2.Vec2, scale = Float64, alpha = Float64 }`
- 影の落ち方の決まり。
  `pub type alias ShadowSpec = { longest = Float64, shortest = Float64, alphaLow = Float64, alphaHigh = Float64, tilt = Float64 }`
- `pub def shadowDefaults(): ShadowSpec`
- 時刻（1 日の進み 0..1）から影の落ち方を導く。
  `pub def shadowAt(spec: ShadowSpec, t: Float64): Shadow`
- 見下ろしの落ち影を 2 枚で置く（接地の暗がり + 太陽の日影）。
  `pub def groundShadow(spec: { sun = Shadow, at = Vec2.Vec2, radius = Float64, ink = Color, pixelStep = Float64, z = Int32 }): List[Render.PlacedItem]`
- 横から見た絵の落ち影を 2 枚で置く（接地の暗がり + 太陽の日影）。
  `pub def sideShadow(spec: { sun = Shadow, at = Vec2.Vec2, radii = Vec2.Vec2, ink = Color, pixelStep = Float64, z = Int32 }): List[Render.PlacedItem]`
- 太陽の位置。height = 高さ（+1 が真上・0 が地平線・負は夜）、
  `pub def sunAt(t: Float64): { height = Float64, east = Float64 }`
- 太陽の向きを、ドット絵の塗りが使う 8 方向のうち 1 つに丸める（-1 / 0 / +1）。
  `pub def lightStepAt(t: Float64): (Int32, Int32)`
- その時刻の「暗さ」（0 = 素通し、1 = 真っ暗）。空気の色の濃さと同じ 1 つの値。
  `pub def darkness(keys: List[Key], t: Float64): Float64`

## Depth — `engine_world/src/Depth.flix`
- 足元の高さ（world の y）を重なり順に写す z の範囲。
  `pub type alias ZRange = { back = Int32, front = Int32, top = Float64, bottom = Float64 }`
- マス目の盤から ZRange を作る近道。1 行に 1 つの zIndex を割り当てる。
  `pub def forRows(spec: { back = Int32, originY = Float64, rows = Int32, tileSize = Float64 }): ZRange`
- 足元の高さ footY に対する重なり順。範囲の外に出た足元は端で止める
  `pub def zAt(range: ZRange, footY: Float64): Int32`
- 組み上がった絵の集まりを、足元の高さで決まる層へ持ち上げる。
  `pub def place(range: ZRange, footY: Float64, items: List[Render.PlacedItem]): List[Render.PlacedItem]`
- place の 1 個版。置き場所の下端（=足元）を自分で渡す。
  `pub def placeOne(range: ZRange, footY: Float64, placed: Render.PlacedItem): Render.PlacedItem`
- 帯の名前 → その帯の底の zIndex。1 画面を「奥から手前へ」何段かに仕切ったときの地図。
  `pub type alias Bands = Map[String, Int32]`
- 奥から手前へ並べた名前の列から帯の地図を作る。
  `pub def bands(spec: { base = Int32, stride = Int32 }, names: List[String]): Bands`
- 帯 name の底の zIndex。知らない名前は一番奥（base 側 = 地図の最小値）へ落とす。
  `pub def bandZ(map: Bands, name: String): Int32`
- 帯 name の中で「足元が下にある物ほど手前」を作る ZRange。
  `pub def bandRange(map: Bands, name: String, spec: { stride = Int32, top = Float64, bottom = Float64 }): ZRange`

## Dir4 — `engine_world/src/Dir4.flix`
- 四方位のいずれか。斜めも「なし」も無い: 「方向があるかもしれない」を扱う呼び側は
  `pub enum Dir4 with Eq, ToString { case Up case Down case Left case Right }`
- この方向がグリッド上で進む単位ステップ、(列, 行) として。y は下向きゆえ Up は
  `pub def delta(d: Dir4): (Int32, Int32)`
- 逆を向いた方向（Up <-> Down、Left <-> Right）。
  `pub def opposite(d: Dir4): Dir4`
- 左右を反転した方向（Left <-> Right）。Up と Down は変わらない。水平反転の鏡像が
  `pub def mirrorX(d: Dir4): Dir4`
- 画面上で時計回りに 90 度: Up -> Right -> Down -> Left -> Up。
  `pub def rotateCw(d: Dir4): Dir4`
- ステップベクトルから方向を復元する（ちょうど四つの単位ステップのいずれかのとき）。
  `pub def fromDelta(dx: Int32, dy: Int32): Option[Dir4]`
- 四方向すべてを固定順 Up, Down, Left, Right で。テストや隣接セルの走査に便利。
  `pub def all(): List[Dir4]`

## DocJson — `engine_world/src/DocJson.flix`
- flix-json `Json.Path.Path.Root` の代替。`Util.Json` ではパス接頭辞を使わないので
  `pub enum PathTag { case Root }`
- `Json.FromJson.getAtKey(Root, key, map)` 互換。map を JObject に包んで委譲。
  `pub def getAtKey(_p: PathTag, key: String, m: Map[String, Json]): Result[JsonError, a] \ {} with FromJson[a]`
- `Json.FromJson.getAtKeyOpt(Root, key, map)` 互換。
  `pub def getAtKeyOpt(_p: PathTag, key: String, m: Map[String, Json]): Result[JsonError, Option[a]] \ {} with FromJson[a]`
- `JsonError(Root, Set#{...})` 互換。説明文字列群を 1 つの TypeMismatch にまとめる。
  `pub def jsonError(_p: PathTag, msgs: Set[String]): JsonError`
- flix-json `Json.Parse.parse` 互換（Option 返し）。
  `pub def parse(s: String): Option[Json]`
- version が無いか 1 なら OK。それ以外は docName 入りの文で断る。
  `pub def checkVersion(docName: String, top: Map[String, Json]): Result[JsonError, Unit]`
- テキストを JSON オブジェクトとして読み、中身の Map から Doc を組む。
  `pub def decodeObject(fromRoot: Map[String, Json] -> a \ ef, text: String): Option[a] \ ef`
- path の Doc を読む。読めない・壊れているときは fallback（fail-open）。
  `pub def loadOr(decode: String -> Option[a] \ ef, fallback: a, path: String): a \ ef + Fs.FileRead`
- path のファイルを読んで JSON にする。読めない・崩れているときは Err で返す。
  `pub def readJson(path: String): Result[JsonError, Json] \ Fs.FileRead`
- JSON オブジェクトなら中身の Map を返す。違えば label 入りの文で断る。
  `pub def asObject(label: String, json: Json): Result[JsonError, Map[String, Json]]`
- key の数値（必須）。
  `pub def numAt(key: String, m: Map[String, Json]): Result[JsonError, Float64]`
- key の数値（無ければ fallback）。
  `pub def numOr(key: String, fallback: Float64, m: Map[String, Json]): Result[JsonError, Float64]`
- field のオブジェクト（名前 → 配列）を、要素パーサで名前ごとのリストに読む。
  `pub def sheetAt(field: String, itemAt: Json -> Result[JsonError, a], top: Map[String, Json]): Result[JsonError, Map[String, List[a]]]`
- エラーにノードの名前パス（例: "gallery/row1/box"）を前置する。ドキュメント木のパーサが
  `pub def atNode(path: String, r: Result[JsonError, a]): Result[JsonError, a]`
- エラーを編集者向けの一文にする。jsonError / atNode が詰めた文章は `TypeMismatch` のコンテナを
  `pub def describe(e: JsonError): String`

## DocTable — `engine_world/src/DocTable.flix`
- この行がどの読み直しに載るか。Both が既定。
  `pub enum ReloadOn with Eq, ToString { case Both case Watch case ReloadAll }`
- テーブルの 1 行。docId は project.json の editor 宣言 id(ActiveDocs のキー)。
  `pub type alias Entry[w] = { docId = Option[String], path = String, reload = w -> w \ {Fs.FileRead}, reloadOn = ReloadOn, activeWhen = w -> Bool }`
- 既定の 1 行 — 保存即反映にも F1 にも載り、常に表示中を名乗る。
  `pub def row(docId: String, path: String, reload: w -> w \ {Fs.FileRead}): Entry[w]`
- 名乗らない 1 行 — 監視も F1 もするが Studio の「表示中」には出さない。
  `pub def unnamedRow(path: String, reload: w -> w \ {Fs.FileRead}): Entry[w]`
- 保存を検知しても読み直さない。読み直すと今の表示が壊れる Doc に使う
  `pub def withoutWatch(e: Entry[w]): Entry[w]`
- F1 の一括では読み直さない。別の行の読み直しが巻き添えで作り直す Doc に使う
  `pub def withoutReloadAll(e: Entry[w]): Entry[w]`
- 表示中を名乗る条件。場面によって画面から消える Doc に使う
  `pub def withActiveWhen(pred: w -> Bool, e: Entry[w]): Entry[w]`
- App.game の reloads(保存即反映の watchFile)へ渡す形。
  `pub def reloads(rows: List[Entry[w]]): List[(String, w -> w \ {Fs.FileRead})]`
- テーブルの並び順に Doc を読み直す(App.reloadOn の一括リロードへ渡す形)。
  `pub def reloadAll(rows: List[Entry[w]], world: w): w \ Fs.FileRead`
- ActiveDocs.step へ渡す形(id → パスの列)。いま world で activeWhen を満たす行のうち
  `pub def activeDocs(rows: List[Entry[w]], world: w): List[(String, List[String])]`

## DualGrid — `engine_world/src/DualGrid.flix`
- 角のまわり4セルの埋まり方。tl=左上 tr=右上 bl=左下 br=右下。
  `pub type alias Corner = { tl = Bool, tr = Bool, bl = Bool, br = Bool }`
- 角の形。1種類に統一すると「作られた構造物」に見えるため、場所ごとに混ぜる。
  `pub enum CornerStyle with Eq, ToString { case Round case Square case Diamond }`
- 角スタイルの混ぜ具合。round/square の割合(残りがひし形)。
  `pub type alias StyleMix = { round = Float64, square = Float64 }`
- 輪郭の1辺。points = スタイル適用後の折れ線(丸=曲線の折れ線化・揺らぎ=中点をずらした
  `pub type alias Edge = { points = List[Vec2.Vec2], normal = Vec2.Vec2, border = Bool }`
- 解決済みのタイル1枚(ローカル座標 0..size)。polys = 塗れる輪郭(スタイル適用済み)、
  `pub type alias Tile = { caseIndex = Int32, style = CornerStyle, size = Float64, polys = List[List[Vec2.Vec2]], edges = List[List[Edge]] }`
- 角1個ぶんのタイルを解決する。style は呼び側が決めて渡す(混ぜたいなら styleAt)。
  `pub def resolve(spec: { tile = Float64, corner = (Int32, Int32), style = CornerStyle, jitter = Float64 }, flags: Corner): Tile`
- タイルの「輪郭の小さな辺」の列(ローカル座標・タイル境界の辺は除く)。
  `pub def segmentsOf(tile: Tile): List[(Vec2.Vec2, Vec2.Vec2)]`
- 角 (i, j) のタイルの置き場所(ワールド座標の左上)。デュアルタイルはセル境界を
  `pub def originOf(tile: Float64, corner: (Int32, Int32)): Vec2.Vec2`
- corner の4ビット表現(tl=8, tr=4, bl=2, br=1)。検証ステージの網羅チェックも同じ値を見る。
  `pub def caseIndex(corner: Corner): Int32`
- デュアルタイル1枚の多角形(ローカル座標 0..tile・ひし形の素の形)。
  `pub def dualCase(tile: Float64, corner: Corner): List[List[Vec2.Vec2]]`
- セル座標から 0 以上 1 未満のばらついた数を1つ決める。同じ入力は毎回同じ値 —
  `pub def hash(x: Int32, y: Int32, channel: Int32): Float64`
- 角 (i, j) の形を丸/四角/ひし形から選ぶ。比率は mix のノブ、選択は座標ハッシュで
  `pub def styleAt(mix: StyleMix, corner: (Int32, Int32)): CornerStyle`
- 対角辺にタイル中心を実頂点として差す(四角スタイル)。直角の角になる。
  `pub def squareOff(tile: Float64, poly: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 対角辺を「タイル中心を制御点にした二次曲線」として4分割した折れ線(端点含む5点)。
  `pub def roundEdge(tile: Float64, a: Vec2.Vec2, b: Vec2.Vec2): List[Vec2.Vec2]`
- 丸スタイルの輪郭。対角辺だけを折れ線に差し替える(タイル境界の辺は直線のまま)。
  `pub def roundOff(tile: Float64, poly: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 対角辺の中点を法線方向に座標ハッシュでずらした3点の折れ線(洞窟の岩肌)。
  `pub def jitteredEdge(corner: (Int32, Int32), amount: Float64, k: Int32, a: Vec2.Vec2, b: Vec2.Vec2): List[Vec2.Vec2]`
- タイル境界(ローカル座標の外周)上の辺か。隣のデュアルタイルと必ず同じ埋まり方に
  `pub def onTileBorder(tile: Float64, a: Vec2.Vec2, b: Vec2.Vec2): Bool`
- 縦横どちらにも動く辺(=ひし形の対角辺)か。スタイル変形はこの辺にだけ掛かる。
  `pub def isDiagonal(a: Vec2.Vec2, b: Vec2.Vec2): Bool`
- 多角形の辺の列(最後の頂点から先頭へ戻る辺を含む)。
  `pub def edgesOf(poly: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2)]`
- 辺 a→b の外向き(多角形の外を指す)単位法線。中点を少し押した点の内外で機械的に決める。
  `pub def outwardNormal(poly: List[Vec2.Vec2], a: Vec2.Vec2, b: Vec2.Vec2): Vec2.Vec2`
- 折れ線に沿う内側向きの stroke(輪郭のフチ取り)。小辺ごとに自分の法線で
  `pub def strokeQuads(points: List[Vec2.Vec2], refNormal: Vec2.Vec2, width: Float64): List[List[Vec2.Vec2]]`
- 折れ線の最後の点を落とす(輪郭を辺ごとにつなぐとき、次の辺の先頭と重複するため)。
  `pub def initOf(points: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 多角形を軸平行矩形で切り取る(Sutherland–Hodgman)。完全に外なら空。
  `pub def clipPolyRect(rect: Rect2.Rect2, poly: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 多角形の面積(靴ひも公式の絶対値)。クリップの検算と潰れた切れ端の間引きに使う。
  `pub def polygonArea(poly: List[Vec2.Vec2]): Float64`

## EcsCodec — `engine_world/src/EcsCodec.flix`
- component store を JSON 配列 [{id, v}, ...] に encode する。
  `pub def encodeStore(encodeC: c -> Json, store: Map[EntityId, c]): Json`
- JSON 配列 [{id, v}, ...] を component store に decode する。1 要素でも失敗なら全体 None。
  `pub def decodeStore(decodeC: Json -> Option[c], json: Json): Option[Map[EntityId, c]]`
- タグ集合 Set[EntityId] を JSON int 配列に往復する。
  `pub def encodeIdSet(s: Set[EntityId]): Json`
- `pub def decodeIdSet(json: Json): Option[Set[EntityId]]`
- Option[EntityId]（player 等）を JSON へ。None は false、Some(id) は数値。
  `pub def encodeIdOption(o: Option[EntityId]): Json`
- 上の対。数値なら Some(id)、それ以外（false 等）なら None。
  `pub def decodeIdOption(json: Json): Option[EntityId]`

## EcsTween — `engine_world/src/EcsTween.flix`
- Vec2 の線形補間（start→target）。Position/Knockback 等のベクトル軌道。
  `pub type alias VecLerp = { start = Vec2.Vec2, target = Vec2.Vec2 }`
- スカラの線形補間（start→target）。Alpha/Scale 等。全 Float64・narrow は適用境界（Sprite 書込時）で。
  `pub type alias FloatLerp = { start = Float64, target = Float64 }`
- 補間カーブ。0→0・1→1 を保つ（完了時の exact スナップを保証）。
  `pub enum Easing with Eq { case Linear case EaseIn case EaseOut case EaseInOut }`
- 補間する**値の型**だけを表す（意味＝チャンネルは持たない）。
  `pub enum Track { case Vec(VecLerp) case Scalar(FloatLerp) }`
- 補間の**出力値**（呼び出し側が対象 component へ書く）。
  `pub enum Out { case VecOut(Vec2.Vec2) case ScalarOut(Float64) }`
- 進行中の 1 tween。elapsed/duration は実時間秒。
  `pub type alias Entry = { track = Track, elapsed = Float64, duration = Float64, easing = Easing, yoyo = Bool }`
- 複合キー (entity, channel) → Entry。1 entity が複数チャンネルを同時に持てる。
  `pub type alias Tweens[k, c] = Map[(k, c), Entry]`
- tween を開始（既存の同キーは置換）。dur は 0 除算回避で minDuration() にクランプ。
  `pub def start(key: (k, c), track: Track, dur: Float64, easing: Easing, yoyo: Bool, ts: Tweens[k, c]): Tweens[k, c] with Order[k], Order[c]`
- 当該キーが進行中か（input gate 用）。
  `pub def isActive(key: (k, c), ts: Tweens[k, c]): Bool with Order[k], Order[c]`
- 全 tween を dt 秒進める。返り: (更新後 tweens, 補間出力, 今フレーム完了キー)。
  `pub def step(dt: Float64, ts: Tweens[k, c]): (Tweens[k, c], List[((k, c), Out)], List[(k, c)]) with Order[k], Order[c]`

## Flex — `engine_world/src/Flex.flix`
- レイアウトノード。Leaf = 実寸つき描画物、Box = 子を並べる容器、
  `pub enum Node { case Leaf({ size = Vec2.Vec2, draw = Rect2.Rect2 -> List[Render.PlacedItem] }) case Box({ style = UiLayout.Style, draw = Option[Rect2.Rect2 -> List[Render.PlacedItem]], children = List[Node] }) case Keyed({ key = String, inner = Node }) }`
- 実寸 size の葉。draw はレイアウト確定後の rect（左上原点）を受け取る。
  `pub def leaf(size: Vec2.Vec2, draw: Rect2.Rect2 -> List[Render.PlacedItem]): Node`
- 「中心座標を受けて描く」既存語彙（Render.*At 系）をそのまま挿せる近道。
  `pub def leafAtCenter(size: Vec2.Vec2, make: Vec2.Vec2 -> List[Render.PlacedItem]): Node`
- style で子を並べる容器。
  `pub def box(style: UiLayout.Style, children: List[Node]): Node`
- 自分の rect も描く容器（背景パネル + 子、の形）。draw の出力は子より先に並ぶ
  `pub def boxDrawn(style: UiLayout.Style, draw: Rect2.Rect2 -> List[Render.PlacedItem], children: List[Node]): Node`
- 中身にラベルを付ける（レイアウトには影響しない）。rectsOf / placeWithRects が
  `pub def keyed(key: String, node: Node): Node`
- 縦並びの既定 style（= UiLayout.defaultStyle）。`{... | Flex.columnStyle()}` で上書きする。
  `pub def columnStyle(): UiLayout.Style`
- 横並びの既定 style。
  `pub def rowStyle(): UiLayout.Style`
- 木を rootRect に敷いてレイアウトを解決し、各 Leaf の draw を rect で呼んで連結する。
  `pub def place(root: Node, rootRect: Rect2.Rect2): List[Render.PlacedItem]`
- place と同じ描画物に加えて「ラベル → 矩形」の表も返す。1 回のレイアウトで
  `pub def placeWithRects(root: Node, rootRect: Rect2.Rect2): (List[Render.PlacedItem], Map[String, Rect2.Rect2])`
- ラベルの付いたノードの矩形だけを引く（描かずに場所だけ知りたいとき）。
  `pub def rectsOf(root: Node, rootRect: Rect2.Rect2): Map[String, Rect2.Rect2]`
- 各 Leaf に割り当てられた rect を DFS 順で返す（レイアウトだけ検分したいとき・テスト用）。
  `pub def leafRects(root: Node, rootRect: Rect2.Rect2): List[Rect2.Rect2]`

## Fx — `engine_world/src/Fx.flix`
- `count` 個の粒を作り、各粒 `i` に個性の蛇口 `rand`（`rand(k)` = 番号 i・チャンネル k の
  `pub def derive(count: Int32, t: Float64, piece: (Int32, Int32 -> Float64, Float64) -> a): List[a]`
- seed を変えると、同じ番号の粒でも別の個性を引く `derive`。着弾や爆発のような
  `pub def deriveSeeded(spec: {seed = Int32, count = Int32}, t: Float64, piece: (Int32, Int32 -> Float64, Float64) -> a): List[a]`
- fx.json の Spec を、時刻 t 秒の絵（描き物の列）にする。粒はどこにも保存されず、
  `pub def sample(spec: FxDoc.Spec, seed: Int64, t: Float64): List[Render.PlacedItem]`
- sample の絵（原点 (0, 0) 生まれ）を at へ平行移動して置く。
  `pub def sampleAt(spec: FxDoc.Spec, seed: Int64, t: Float64, at: Vec2.Vec2): List[Render.PlacedItem]`
- 進行中の効果 1 つ。「どの spec を・どの種で・どこで」に加え、誕生時刻＋寿命を Lifetime で持つ。
  `pub type alias Burst = { spec = FxDoc.Spec, seed = Int64, at = Vec2.Vec2, life = Lifetime.Lifetime }`
- 時刻 bornAt に at で始まる効果を作る(普段は「今」を渡す。描き出しのように過去生まれを
  `pub def burst(spec: FxDoc.Spec, seed: Int32, at: Vec2.Vec2, bornAt: Float64): Burst`
- 寿命内（経過が寿命まで）の burst だけ残す。毎フレーム呼んで、終わった効果でリストが
  `pub def expire(now: Float64, bursts: List[Burst]): List[Burst]`
- 進行中の burst 全部の、時刻 now の絵。各 burst の生まれた時刻からの経過で sampleAt を
  `pub def drawAll(now: Float64, bursts: List[Burst]): List[Render.PlacedItem]`

## FxDoc — `engine_world/src/FxDoc.flix`
- 正規化寿命 u（0 = 生まれた瞬間, 1 = 消える瞬間）→ 倍率、のカーブ。
  `pub enum CurveSpec { case Constant case Linear({ fromV = Float64, toV = Float64 }) case EaseIn({ power = Float64 }) case EaseOut({ power = Float64 }) case Peak({ at = Float64 }) case Flicker({ rate = Float64, amount = Float64 }) case Pulse({ rate = Float64, minV = Float64 }) }`
- 粒の形。circle は直径 size の円、box は一辺 size の正方形。
  `pub enum Shape with Eq { case Circle case Box case Glow case Streak }`
- 位置の正弦揺らぎ。粒はまっすぐ飛ぶ式しか持たないので、蛍のような「その場でゆらゆら」の
  `pub type alias Wobble = { amp = Vec2.Vec2, freq = Vec2.Vec2, vary = Float64 }`
- ばらつき付きの量。粒ごとに base × (1 ± vary) の範囲で決まり、
  `pub type alias Scalar = { base = Float64, vary = Float64, over = CurveSpec }`
- 射出方向の配り方。Random = 粒ごとに乱数で扇の中から引く（煙・火花）。
  `pub enum DirMode with Eq { case Random case Even }`
- 粒の生まれ方。Burst = 全粒が t=0 で同時に生まれて寿命で消える（爆発・木くず）。
  `pub enum Mode with Eq { case Burst case Loop }`
- 粒の群れ 1 種類ぶんの宣言。既定は burst（全粒が t=0 で同時に生まれる）。
  `pub type alias Emitter = { name = String, count = Int32, mode = Mode, shape = Shape, size = Float64, color = List[Color], life = { base = Float64, vary = Float64 }, speed = Scalar, dir = { base = Float64, spread = Float64, mode = DirMode }, turn = { base = Float64, spread = Float64, spin = Float64, spinSpread = Float64 }, spawnArea = { w = Float64, h = Float64 }, accel = Vec2.Vec2, wobble = Wobble, stretch = Float64, seed = Int32, sizeOver = CurveSpec, alphaOver = CurveSpec, blend = DrawCmd.BlendMode, zIndex = Int32 }`
- fx ドキュメント全体。duration を過ぎた時刻の sample は空になる。
  `pub type alias Spec = { name = String, duration = Float64, note = Option[String], emitters = List[Emitter] }`
- 何も出さない空の Spec。「まだ読み込めていない」「効果なし」の置き場に使う —
  `pub def empty(): Spec`
- ドキュメント（version + name + duration + emitters）を Spec へ読み取る。
  `pub def parse(json: Json): Result[JsonError, Spec]`
- パレット付きの parse。emitter の color に "@名前" と書くと palette から解決する
  `pub def parseWith(palette: Map[String, Color], json: Json): Result[JsonError, Spec]`

## GameLogger — `engine_world/src/GameLogger.flix`
- `pub eff GameLogger`
- プレイヤー側のメッセージを白色で 1 行積む
  `pub eff GameLogger { def playerLog(msg: String): Unit }`
- 敵側のメッセージを赤色で 1 行積む
  `pub eff GameLogger { def enemyLog(msg: String): Unit }`
- ゲームオーバーを濃赤で 1 行積む（プレイヤー HP=0 時の通知）。
  `pub eff GameLogger { def gameOverLog(msg: String): Unit }`
- 1 ターン終わり（味方ターン + 敵ターン = 1 ターン）。
  `pub eff GameLogger { def endTurn(): Unit }`
- engine 内部用: 蓄積された Entry を古→新の順で返し、内部キューを空にする
  `pub eff GameLogger { def drainEntries(): List[Entry] }`
- 1 行のログエントリ。色は color で Text に乗算する。
  `pub type alias Entry = { text = String, color = Color }`
- player 行のデフォルト色（白）
  `pub def playerColor(): Color`
- enemy 行のデフォルト色（赤系・薄め）
  `pub def enemyColor(): Color`
- ゲームオーバー行の色（濃赤）。enemyColor の薄赤と区別して際立たせる。
  `pub def gameOverColor(): Color`
- `Tween.withScheduler` と同じ流儀の handler 注入。
  `pub def withLogger(rc: Region[r]): (Unit -> a \ ef) -> a \ (ef - GameLogger) + r`

## Grid — `engine_world/src/Grid.flix`
- `cell` の中心のピクセル位置。原点 (0, 0) がセル (0, 0) の左上であるグリッド上で。
  `pub def cellCenter(tileSize: Float64, cell: (Int32, Int32)): Vec2.Vec2`
- ピクセル位置がどのセルに入るか — 中心に限らずセル内の任意の点について `cellCenter`
  `pub def cellOf(tileSize: Float64, pos: Vec2.Vec2): (Int32, Int32)`
- `cell` から方向 `d` へ 1 歩進んだセル。
  `pub def neighbor(cell: (Int32, Int32), d: Dir4.Dir4): (Int32, Int32)`
- `cell` が `cols` x `rows` のグリッド内にあるか: 列が [0, cols)、行が [0, rows)。
  `pub def inRect(cell: (Int32, Int32), cols: Int32, rows: Int32): Bool`
- セル座標を名前付き成分で持つための record 型。列 = `x`、行 = `y`。tuple 版
  `pub type alias Cell = { x = Int32, y = Int32 }`
- `cellCenter` の record 版。セルを `{x, y}` で受け取り中心のピクセル位置を返す。
  `pub def cellCenterOf(tileSize: Float64, cell: Cell): Vec2.Vec2`
- `cellOf` の record 版。ピクセル位置がどのセルに入るかを `{x, y}` で返す。floor で
  `pub def cellAt(tileSize: Float64, pos: Vec2.Vec2): Cell`
- 「セル中心が整数・境界が ±0.5」の座標系（1 マス = 1.0）で、世界点 `p` が属するセル。
  `pub def cellAtCentered(p: Vec2.Vec2): Cell`
- 文字の並び（rows）の大きさ。`cols` は**一番長い行**の文字数で、短い行は右が
  `pub def dimsOfRows(rows: List[String]): { cols = Int32, rows = Int32 }`
- 文字の並びを「(セル, その文字)」の列にほどく。並びは上の行から、行の中は左から
  `pub def cellsOfRows(rows: List[String]): List[(Cell, Char)]`
- `neighbor` の record 版。`cell` から方向 `d` へ 1 歩進んだセルを `{x, y}` で返す。
  `pub def neighborOf(cell: Cell, d: Dir4.Dir4): Cell`
- `inRect` の record 版。`cell` が `cols` x `rows`（列 [0,cols)・行 [0,rows)）の内側か。
  `pub def inRectOf(cell: Cell, cols: Int32, rows: Int32): Bool`
- 見えている矩形に重なるマスを並べる（盤の外は含めない）。
  `pub def cellsIn(spec: { tileSize = Float64, area = { position = Vec2.Vec2, size = Vec2.Vec2 }, cols = Int32, rows = Int32, margin = { left = Int32, top = Int32, right = Int32, bottom = Int32 } }): List[Cell]`
- 余分を見ない margin（見えている矩形にちょうど重なるマスだけ）。
  `pub def noMargin(): { left = Int32, top = Int32, right = Int32, bottom = Int32 }`

## GridRay — `engine_world/src/GridRay.flix`
- start → goal の間に solid なマスが挟まるか。両端のマス自身も数えるので、
  `pub def blocked(solidAt: Grid.Cell -> Bool, ignore: Grid.Cell -> Bool, start: Vec2.Vec2, goal: Vec2.Vec2): Bool`

## GridSearch — `engine_world/src/GridSearch.flix`
- 4近傍のうち `canEnter` を満たすマスだけを通って、`start` から `maxSteps` 歩以内に
  `pub def reachable(canEnter: ((Int32, Int32)) -> Bool, start: (Int32, Int32), maxSteps: Int32): List[(Int32, Int32)]`
- `sources` を 0 歩とする多始点の幅優先探索で、`canEnter` を満たして到達できる各マスの
  `pub def distances(canEnter: ((Int32, Int32)) -> Bool, sources: List[(Int32, Int32)], maxSteps: Int32): Map[(Int32, Int32), Int32]`
- 2 マス間のマンハッタン距離 |dx| + |dy|（4方向で辿る最短歩数の下限）。
  `pub def manhattanDistance(a: (Int32, Int32), b: (Int32, Int32)): Int32`
- `center` からマンハッタン距離が `minR`..`maxR`（両端含む）にあるマスの一覧
  `pub def manhattanRing(center: (Int32, Int32), minR: Int32, maxR: Int32): List[(Int32, Int32)]`

## Hash01 — `engine_world/src/Hash01.flix`
- 添字 `index`・チャンネル `channel` に対する [0, 1) の小数。同じ添字の二つの
  `pub def at(index: Int32, channel: Int32): Float64`

## Hit — `engine_world/src/Hit.flix`
- 当たりの形 1 個。dx/dy は持ち主の位置からのずれ（px）で、錨（中心か足元か）は絵に従う。
  `pub enum HitShape { case CircleH({ dx = Float64, dy = Float64, r = Float64 }) case BoxH({ dx = Float64, dy = Float64, w = Float64, h = Float64 }) }`
- 当たり判定に置く物 1 個。tag は当たったとき返してほしい値（敵そのもの等）。
  `pub type alias Body[a] = { tag = a, pos = Vec2.Vec2, shapes = List[HitShape] }`
- 1対1の判定。posA に置いた shapesA と posB に置いた shapesB がどこかで重なるか。
  `pub def overlaps(posA: Vec2.Vec2, shapesA: List[HitShape], posB: Vec2.Vec2, shapesB: List[HitShape]): Bool`
- pos に置いた shapes に最初に触れている body の tag（無ければ None）。
  `pub def firstHit(pos: Vec2.Vec2, shapes: List[HitShape], bodies: List[Body[a]]): Option[a]`
- pos に置いた shapes に触れている全 body の tag。
  `pub def hits(pos: Vec2.Vec2, shapes: List[HitShape], bodies: List[Body[a]]): List[a]`
- pos に置いた shapes がどれかに触れているか。
  `pub def anyHit(pos: Vec2.Vec2, shapes: List[HitShape], bodies: List[Body[a]]): Bool`
- 宣言した寸法を Physics2D 系の Store に流すための変換。オフセットは呼び側が位置に足す。
  `pub def toCollisionShape(shape: HitShape): (Vec2.Vec2, CollisionShape2D)`
- 円×円: 中心間の距離が半径の和より短ければ当たり（ちょうど接するのは外）。
  `pub def circleCircle(ca: Vec2.Vec2, ra: Float64, cb: Vec2.Vec2, rb: Float64): Bool`
- 箱×箱: 軸ごとに中心間のずれが半分幅の和より小さければ当たり（AABB）。
  `pub def boxBox(ca: Vec2.Vec2, wa: Float64, ha: Float64, cb: Vec2.Vec2, wb: Float64, hb: Float64): Bool`
- 点×箱: 点が中心 c・幅 w・高さ h の箱の中か（縁の上は外 — boxBox の点版）。
  `pub def pointBox(p: Vec2.Vec2, c: Vec2.Vec2, w: Float64, h: Float64): Bool`

## HitDoc — `engine_world/src/HitDoc.flix`
- 名前 → 形の列。hitbox.json の "hit" と同じ形。
  `pub type alias Sheet = Map[String, List[HitShape]]`
- 形の種類の一覧。parse の unknown エラーが同じ表を見る。
  `pub def shapeKinds(): List[String]`
- sheet の欠け（必須キーが無い・どのキーでも形が 0 個）を列挙する（空なら欠けなし）。
  `pub def gaps(required: List[String], sheet: Sheet): List[String]`
- リロードの適用: 読めて欠けも無いときだけ差し替え、壊れていれば今の sheet を守る。
  `pub def reloaded(required: List[String], loaded: Result[JsonError, Sheet], current: Sheet): Sheet`
- キーの形を引く。無ければ空 = 何にも当たらない（欠けは gaps が起動時に報せる）。
  `pub def shapesOf(key: String, sheet: Sheet): List[HitShape]`
- hitbox.json 全体を Sheet にする（version 確認 + "hit" の名前 → 形の列）。
  `pub def parse(json: Json): Result[JsonError, Sheet]`
- path を読んで Sheet にする。読めない・崩れているときは位置付きの Err。
  `pub def load(path: String): Result[JsonError, Sheet] \ Fs.FileRead`
- 起動時用: 読めない・必須キーの欠落は bug! で起動を止めて loud に知らせる。
  `pub def loadOrBug(path: String, required: List[String]): Sheet \ Fs.FileRead`

## InputEdge — `engine_world/src/InputEdge.flix`
- キーが押された瞬間のフレームだけ true: 今 (`cur`) は押されていて、前フレーム
  `pub def pressed(prev: Bool, cur: Bool): Bool`

## InputMap — `engine_world/src/InputMap.flix`
- (キー, 意図) の表。同じ意図を複数キーに割り当ててよい（WASD と矢印、Z と Enter）。
  `pub type alias Table[a] = List[(GameEngine.Key, a)]`
- 押した瞬間に発火した意図（表の順・同じ意図は 1 回）。決定・キャンセルなどの単発操作用。
  `pub def taps(table: Table[a], frame: App.Frame): List[a] with Eq[a]`
- 発火した意図の先頭だけ（同時押しは表の順で先勝ち）。メニュー操作はこれで十分。
  `pub def firstTap(table: Table[a], frame: App.Frame): Option[a] with Eq[a]`
- 押している間ずっと発火する意図（表の順・同じ意図は 1 回）。移動などの連続操作用。
  `pub def held(table: Table[a], frame: App.Frame): List[a] with Eq[a]`
- 表とキー集合から発火した意図を引く芯（テストはここを直接叩く）。
  `pub def firedIn(table: Table[a], keys: Set[GameEngine.Key]): List[a] with Eq[a]`
- "z" や "Enter" のようなキー名を Key へ(大文字小文字は区別しない)。
  `pub def keyOf(name: String): Option[GameEngine.Key]`
- 名前の列 → キーの列(順は保つ)。知らない名前はその 1 個だけ捨てる —
  `pub def keysOf(names: List[String]): List[GameEngine.Key]`
- ホイールの生 delta を「目盛り」へまとめる。マウスは 1 目盛りで ±1.0 が届くが、
  `pub def wheelSteps(carry: Float64, delta: Float64): (Int32, Float64)`

## Journey — `engine_world/src/Journey.flix`
- 脚: src から dst へ speed(px/秒)で歩く(純データ)。
  `pub type alias Leg = { src = Vec2.Vec2, dst = Vec2.Vec2, speed = Float64 }`
- 時刻 t の見本。pos は現在地、walking は歩いた累計 px、done は全脚を歩き終えたか。
  `pub type alias Sample = { pos = Vec2.Vec2, walking = Float64, done = Bool }`
- 脚 1 本の所要秒(距離 / 速さ)。速さ 0 以下は 0 秒(その場に着いている扱い)。
  `pub def legDur(leg: Leg): Float64`
- 全脚の合計秒。t がこれ以上なら done。
  `pub def total(legs: List[Leg]): Float64`
- t 秒時点の現在地。脚の途中なら src→dst の直線補間、全脚を過ぎたら
  `pub def at(legs: List[Leg], t: Float64): Sample`

## JsonCodec — `engine_world/src/JsonCodec.flix`
- JSON object なら中身の Map を、そうでなければ None を返す。
  `pub def expectObject(element: Json): Option[Map[String, Json]]`
- JSON 文字列なら中身を返す。
  `pub def expectString(element: Json): Option[String]`
- JSON 数値を Int32 として取り出す。`BigDecimal -> Float64 -> Int32` の 2 段階の変換。
  `pub def expectInt(element: Json): Option[Int32]`
- JSON 数値を Float64 として取り出す。数値以外は None。
  `pub def expectFloat(element: Json): Option[Float64]`
- JSON 真偽値を取り出す。真偽値以外は None。
  `pub def expectBool(element: Json): Option[Bool]`
- `Float64` を `BigDecimal` に。trailing zero 除去で「100」(「100.0」ではなく) として書き出す。
  `pub def floatToBd(value: Float64): BigDecimal`
- `Int32` を `BigDecimal` に。trailing zero 除去で「100」として書き出す。
  `pub def intToBd(value: Int32): BigDecimal`
- `Map[String, T]` を JSON object として encode する。`encodeEntry` は 1 要素 encoder。
  `pub def encodeStringMap(encodeEntry: t -> Json, entries: Map[String, t]): Json`
- JSON object を `Map[String, T]` として decode する。要素のいずれかが None なら全体 None。
  `pub def decodeStringMap(decodeEntry: Json -> Option[t], element: Json): Option[Map[String, t]]`
- `List[T]` を JSON array として encode する。
  `pub def encodeList(encodeEntry: t -> Json, entries: List[t]): Json`
- JSON array を `List[T]` として decode する。要素のいずれかが None なら全体 None。
  `pub def decodeList(decodeEntry: Json -> Option[t], element: Json): Option[List[t]]`
- `{x: Float, y: Float}` の Vec2 を JSON object に encode する。
  `pub def encodeVec2(vec: Vec2.Vec2): Json`
- JSON object を Vec2 に decode する。x/y どちらか欠落でも 0.0 で補完。
  `pub def decodeVec2(element: Json): Option[Vec2.Vec2]`
- `Option[Json]` を Vec2 に。欠落 / 不正なら `(defaultValue, defaultValue)`。
  `pub def decodeVec2OrDefault(optElement: Option[Json], defaultValue: Float64): Vec2.Vec2`
- object から `key` を Float64 として読む。無い・数値でなければ `fallback`。
  `pub def floatOr(key: String, fallback: Float64, obj: Map[String, Json]): Float64`
- object から `key` を Int32 として読む。無い・整数でなければ `fallback`。
  `pub def intOr(key: String, fallback: Int32, obj: Map[String, Json]): Int32`
- object から `key` を String として読む。無い・文字列でなければ `fallback`。
  `pub def stringOr(key: String, fallback: String, obj: Map[String, Json]): String`
- object から `key` を Bool として読む。無い・真偽値でなければ `fallback`。
  `pub def boolOr(key: String, fallback: Bool, obj: Map[String, Json]): Bool`

## Lifetime — `engine_world/src/Lifetime.flix`
- `pub type alias Lifetime = { startedAt = Float64, dur = Float64 }`
- 時刻 now に、長さ dur で発火する。
  `pub def fire(now: Float64, dur: Float64): Lifetime`
- 発火からの経過秒（負にもなり得る＝startedAt を未来に置けば「遅延」になる）。
  `pub def elapsedOf(now: Float64, l: Lifetime): Float64`
- 進行度 0..1（開始で 0・寿命で 1）。
  `pub def progressOf(now: Float64, l: Lifetime): Float64`
- 残り秒（0 未満にはならない）。
  `pub def remaining(now: Float64, l: Lifetime): Float64`
- まだ再生中か（0 ≤ 経過 < 寿命）。
  `pub def alive(now: Float64, l: Lifetime): Bool`

## Light — `engine_world/src/Light.flix`
- 簡易2D光源1個の値。at=位置、radius=光の届く目安半径、color=光の色、
  `pub type alias Light = { at = Vec2.Vec2, radius = Float64, color = Color, halo = Float64 }`
- RadialGlow で生成した既定テクスチャの参照一式。sprite 名・元 px サイズ・穴の広さは
  `pub type alias GlowAssets = { maskSprite = String, maskSourceSize = Float64, maskHoleFrac = Float64, haloSprite = String, haloSourceSize = Float64 }`
- RadialGlow の既定値で生成したときの GlowAssets（sprite名は描き出し側の慣習
  `pub def defaultGlowAssets(): GlowAssets`
- シーン全体の光源設定（items の唯一の入口）。lights は 0〜N 個、occluders は
  `pub type alias SceneLightConfig = { lights = List[Light], occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2, glow = GlowAssets, darkness = Float64, z = Int32, rimWidth = Float64, rimStrength = Float64, haloDiameterFactor = Float64 }`
- haloDiameterFactor の既定の目安。穴（2×radius）よりひとまわり大きい見た目にする
  `pub def defaultHaloDiameterFactor(): Float64`
- シーンの光源一式を絵にする唯一の入口。lights が
  `pub def items(cfg: SceneLightConfig): List[Render.PlacedItem]`
- singleLightItems の設定。maskSprite/haloSprite は RadialGlow で生成したテクスチャ名、
  `pub type alias SingleLightConfig = { light = Light, viewport = Vec2.Vec2, maskSprite = String, maskSourceSize = Float64, maskHoleFrac = Float64, haloSprite = String, haloSourceSize = Float64, darkness = Float64, z = Int32 }`
- 単一光源の真の穴あき描画。中心の穴あきオーバーレイ（Multiply, maskSprite）を「穴の実寸半径が
  `pub def singleLightItems(cfg: SingleLightConfig): List[Render.PlacedItem]`
- multiLightItems の設定。darkness は全面オーバーレイの濃さ0..1（1で真っ黒）。
  `pub type alias MultiLightConfig = { lights = List[Light], darkness = Float64, viewport = Vec2.Vec2, haloSprite = String, haloSourceSize = Float64, z = Int32 }`
- 複数光源の近似。全面オーバーレイ（Multiply, 一様darkness）+各光位置にAddハロ、という
  `pub def multiLightItems(cfg: MultiLightConfig): List[Render.PlacedItem]`
- 光マップ方式の設定。lightMapPass（App.withPasses へ）と lightMapOverlay（view の列へ）の
  `pub type alias LightMapConfig = { lights = List[Light], occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2, ambient = Color, shadowStrength = Float64, extrudeLength = Float64, passName = String, z = Int32 }`
- ambient の既定の目安（#1a1826 の夜の青み。k/255 で割り切れる値なので
  `pub def defaultAmbient(): Color`
- shadowStrength の既定の目安（影がはっきり見えつつ、灯りの気配がわずかに残る濃さ）。
  `pub def defaultShadowStrength(): Float64`
- 光マップの Pass を導く純関数（App.withPasses へ渡す）。並びは
  `pub def lightMapPass(cfg: LightMapConfig): Render.Pass`
- 光マップを本編へ Multiply で 1 枚貼る PlacedItem（view の列の末尾側に足す）。
  `pub def lightMapOverlay(cfg: LightMapConfig): Render.PlacedItem`

## LightDoc — `engine_world/src/LightDoc.flix`
- 1 光源ぶんの宣言。at は初期位置（実行時に World の値で上書きしてよい）。
  `pub type alias LightSpec = { at = Vec2.Vec2, radius = Float64, color = Color, halo = Float64 }`
- ドキュメント全体。darkness/rim/haloDiameterFactor は Light.SceneLightConfig の
  `pub type alias Spec = { darkness = Float64, rimWidth = Float64, rimStrength = Float64, haloDiameterFactor = Float64, ambient = Color, shadowStrength = Float64, lights = List[LightSpec], note = Option[String] }`
- 全フィールド省略時の既定値（lights=Nil の「今は光源なし」ドキュメントも許す —
  `pub def empty(): Spec`
- ドキュメントを Spec へ読み取る。
  `pub def parse(json: Json): Result[JsonError, Spec]`
- Spec の質感パラメータに、ゲーム側が持つ occluders/viewport/glow/z を足して
  `pub def toConfig(spec: Spec, ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2, glow = Light.GlowAssets, z = Int32 }): Light.SceneLightConfig`
- toConfig と同じだが、lights を丸ごと runtimeLights に差し替える
  `pub def toConfigWithLights(spec: Spec, runtimeLights: List[Light.Light], ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2, glow = Light.GlowAssets, z = Int32 }): Light.SceneLightConfig`
- Spec の質感（ambient/shadowStrength/lights）に、ゲームが持つ occluders/viewport/
  `pub def toLightMapConfig(spec: Spec, ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2, passName = String, z = Int32 }): Light.LightMapConfig`
- toLightMapConfig と同じだが、lights を丸ごと runtimeLights に差し替える
  `pub def toLightMapConfigWithLights(spec: Spec, runtimeLights: List[Light.Light], ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2, passName = String, z = Int32 }): Light.LightMapConfig`
- path を読んで Spec にする。DocJson.readJson と同じ fail 経路
  `pub def load(path: String): Result[JsonError, Spec] \ Fs.FileRead`

## MapResource — `engine_world/src/legacy/MapResource.flix`
- Level の中身。フィールドの集合はここに集約し、enum 経由で持ち回す。
  `pub type alias LevelData = { tileSize = Int32, width = Int32, height = Int32, materialId = String, manualTiles = List[ManualTile], decorTiles = List[ManualTile], entities = List[Entity], editorPalette = Option[EditorPalette], intGrid = Vector[Int32] }`
- IDE Maps タブの Palette 設定 (Floor / Walls 各層)。
  `pub type alias EditorPalette = { floor = EditorLayerPalette, walls = EditorLayerPalette }`
- 1 レイヤー分の Palette 設定。
  `pub type alias EditorLayerPalette = { textureName = Option[String], cellW = Int32, cellH = Int32, marginX = Int32, marginY = Int32 }`
- `Saveable[Level]` を実装可能にするための単一 case ラッパ。
  `pub enum Level { case Level(LevelData) }`
- `Level` から内部の record を取り出す。
  `pub def levelData(l: Level): LevelData`
- 描画タイル 1 枚の記述。autotile の上書きにも、autotile 無しの素描画にも使う。
  `pub type alias ManualTile = { x = Int32, y = Int32, srcX = Int32, srcY = Int32, flipH = Bool, flipV = Bool }`
- `pub type alias Entity = { identifier = String, x = Int32, y = Int32, fields = Map[String, FieldValue] }`
- Entity の custom field 値。文字列 / 整数 / Bool の 3 種類だけ MVP で扱う。
  `pub enum FieldValue with Eq, ToString { case StringV(String) case IntV(Int32) case BoolV(Bool) }`
- Material の中身。
  `pub type alias MaterialData = { tileset = String, tileSize = Int32, wallMap = Map[String, (Int32, Int32)], floorPalette = List[(Int32, Int32)], decorPalette = List[(Int32, Int32)], autoRules = List[AutoRule] }`
- AutoRule の pattern セル 1 個の値。LDtk の 5 値セマンティクスに揃える。
  `pub enum PatternCell with Eq, ToString { case Unspecified case Anything case Nothing case Value(Int32) case NotValue(Int32) }`
- AutoRule: パターンマッチで wallMap の上に重ねる装飾タイルを決める。
  `pub type alias AutoRule = { name = String, size = Int32, pattern = Vector[PatternCell], srcX = Int32, srcY = Int32 }`
- `Saveable[Material]` を実装可能にするための単一 case ラッパ。
  `pub enum Material { case Material(MaterialData) }`
- `Material` から内部の record を取り出す。
  `pub def materialData(m: Material): MaterialData`
- "TRBL" 4-bit 文字列キーの完全集合 (フォールバック用)。
  `pub def wallMapKeys(): List[String]`
- PatternCell と intGrid 値 1 個の整合性を判定する。
  `pub def patternCellMatches(cell: PatternCell, intGridValue: Int32): Bool`
- rule#pattern をセル `(col, row)` を中央として intGrid と照合する。
  `pub def ruleMatches(intGrid: Vector[Int32], width: Int32, height: Int32, col: Int32, row: Int32, rule: AutoRule): Bool`
- intGrid の `(col, row)` 値を返す。境界外は 0 (空セル扱い)。
  `pub def intGridAt(intGrid: Vector[Int32], width: Int32, height: Int32, col: Int32, row: Int32): Int32`

## MapResourceCodec — `engine_world/src/legacy/MapResource.flix`
- `pub def encodeLevel(l: Level): Json`
- `pub def decodeLevel(element: Json): Option[Level]`
- `pub def encodeFieldValue(v: FieldValue): Json`
- `pub def decodeFieldValue(element: Json): Option[FieldValue]`
- `pub def encodeMaterial(m: Material): Json`
- `pub def decodeMaterial(element: Json): Option[Material]`

## Material — `engine_world/src/Material.flix`
- 粒の形。Speck = 小さな四角が明滅する(水のきらめき)。
  `pub enum SurfaceShape { case Speck case Scales case Bubble case Glow }`
- 表面の粒のパラメータ1式(fx.json の語彙にそろえた命名)。
  `pub type alias SurfaceFx = { shape = SurfaceShape, count = Int32, color = Color, color2 = Color, color3 = Color, channel = Int32, twinkleRate = Float64, alphaBase = Float64, alphaSpan = Float64, sizeBase = Float64, sizeSpan = Float64, period = Float64, riseSpeed = Float64, sizeTo = Float64, blend = DrawCmd.BlendMode }`
- 静的なむら1式(深い水の暗がり・マグマの冷えた皮)。時間を持たないので
  `pub type alias BlotchFx = { color = Color, channel = Int32, alphaBase = Float64, alphaSpan = Float64, sizeBase = Float64, sizeSpan = Float64 }`
- 地肌の粒。面の中に細かい点をたくさん置いて、ベタ塗りののっぺりを消す。
  `pub def grain(color: Color): SurfaceFx`
- 水のきらめきの設定。粒3個・幅1〜3px・濃さの山0.8 — 個数や幅を固定で絞ると
  `pub def sparkle(color: Color): SurfaceFx`
- 面の鱗パターン。丸の敷き詰めをやめ、下向きの三日月(弧)を整った千鳥格子に
  `pub def scales(tones: { deep = Color, mid = Color, lite = Color }, rate: Float64): SurfaceFx`
- マグマの泡の設定。泡は疎(セルに 0〜1 個・出現はハッシュで間引く)で一生 1 秒未満。
  `pub def bubble(color: Color): SurfaceFx`
- マグマ自身の照り(加算の淡い橙の光の粒)。セルに1〜2個、ゆっくり明滅する。
  `pub def glow(color: Color): SurfaceFx`
- 静的なむらの設定(色だけ差し替えて水にもマグマにも使う)。セルに1〜2個、
  `pub def blotch(color: Color): BlotchFx`
- 輪郭フチの色の決め方。Uniform = 全周同じ色(水の岸辺線)。
  `pub enum EdgeKind { case Uniform(Color) case ByNormal({ top = Color, side = Color, shade = Color }) }`
- 立体感の決め方。Flat = 持ち上げない(水面)。Lifted = 輪郭を height ぶん持ち上げ、
  `pub enum HeightProfile { case Flat case Lifted({ height = Float64, front = Color, shade = Color, clipToFloor = Bool }) }`
- 質感1式。fill = 塗り、edge/edgeWidth = 輪郭フチ、forceStyle = 角の形の固定
  `pub type alias Spec = { fill = Color, edge = EdgeKind, edgeWidth = Float64, forceStyle = Option[DualGrid.CornerStyle], jitter = Float64, surface = List[SurfaceFx], blotch = Option[BlotchFx], mottle = Float64, height = HeightProfile }`
- 解決済みタイル1枚に質感を着せる。多角形ごとに 前面 → 塗り → フチの stroke の順で並べる —
  `pub def place(spec: Spec, tile: DualGrid.Tile, origin: Vec2.Vec2, z: { fill = Int32, stroke = Int32 }): List[Render.PlacedItem]`
- このセルの上下左右の隣も同じ液体か(岸の判定に使う)。true = 液体(そちらは陸地でない)。
  `pub type alias Edges = { n = Bool, s = Bool, e = Bool, w = Bool }`
- 表面の時間演出をセル1個ぶん描く(状態なし — 同じ時刻なら同じ絵)。
  `pub def surfaceItems(fxs: List[SurfaceFx], cell: (Int32, Int32), tile: Float64, time: Float64, z: Int32, edges: Edges): List[Render.PlacedItem]`
- 静的なむらをセル1個ぶん描く(時間なし — prebuilt に生成する前提)。セルに1〜2個
  `pub def blotchItems(fx: BlotchFx, cell: (Int32, Int32), tile: Float64, z: Int32): List[Render.PlacedItem]`

## Mirror — `engine_world/src/Mirror.flix`
- 面の返し方。alpha = 濃さ、lit = これ以上明るい色は光として面に足す、
  `pub type alias Style = { alpha = Float64, lit = Float64, floor = Float64, dim = Float64 }`
- 夜のガラス。明暗を強く分ける（暗い部屋を背にした面の見え方）。
  `pub def glassStyle(): Style`
- 明暗を分けない素の面（磨いた床・ためし置き）。全部を同じ濃さで薄く返す。
  `pub def plainStyle(alpha: Float64): Style`
- 走りの列を面に映す。走りは**面の上の座標に置いてから**渡すこと
  `pub def runs(spec: { runs = List[PxSprite.Run], glass = Rect2.Rect2, style = Style, resolver = String -> Color, z = Int32 }): List[Render.PlacedItem]`

## Motion — `engine_world/src/Motion.flix`
- position を velocity で dt 秒積分する。両方持つ entity だけ動く。
  `pub def integrate(positions: Map[EntityId, Vec2.Vec2], velocities: Map[EntityId, Vec2.Vec2], dt: Float64): Map[EntityId, Vec2.Vec2]`
- 物の往復運動の仕様。基準位置からのずれを時刻の純関数で導く（状態を持たない・振り子）。
  `pub type alias Swing = { axis = Vec2.Vec2, amplitude = Float64, period = Float64, phase = Float64 }`
- 時刻 t での基準位置からのずれ。triWave で駆動するので速さは一定（4×amplitude/period）。
  `pub def swingOffset(osc: Swing, t: Float64): Vec2.Vec2`

## Painter — `engine_world/src/Painter.flix`
- items を距離の遠い順に並べ、(zIndex, item) を返す。zIndex は
  `pub def zOrdered(distOf: a -> Float64, zBase: Int32, zStride: Int32, items: List[a]): List[(Int32, a)]`

## PaletteExport — `engine_world/src/PaletteExport.flix`
- 色票 Doc の version。外形（version / note / colors）が変わるときだけ上げる。
  `pub def version(): Int32`
- 意味色キーの列を resolver に通して「名前 → 実色」の表にする。
  `pub def fromKeys(resolver: String -> Color, keys: List[String]): Map[String, Color]`
- 色票 Doc 1 枚ぶんの JSON テキスト（末尾に改行付き）。
  `pub def build(spec: { note = String, colors = Map[String, Color] }): String`
- 色票 Doc を path へ書き出す。親ディレクトリは作らない（`Fs.WriteFile` の流儀）。
  `pub def write(path: String, spec: { note = String, colors = Map[String, Color] }): Result[String, Unit] \ Fs.FileWrite`

## Persistence — `engine_world/src/Persistence.flix`
- `Saveable` を実装した値を `path` へ JSON で書き出す。
  `pub def save(path: String, value: a): Result[String, Unit] \ Fs.FileWrite with Saveable[a]`
- `Saveable` を実装した型を `path` から読み出す。
  `pub def load(path: String): Option[a] \ Fs.FileRead with Saveable[a]`

## Persp — `engine_world/src/Persp.flix`
- カメラの置き方。pos = 位置（世界座標）、yaw = 向き（ラジアン。
  `pub type alias Camera = { pos = Vec2.Vec2, yaw = Float64 }`
- カメラ空間の 2D 点。fwd = 視線方向の奥行き、lat = 右向きの横ずれ。
  `pub type alias CamPoint = { fwd = Float64, lat = Float64 }`
- 画面への写し方（消失点 + 焦点距離 = 写し方の意見。画面サイズではない）。
  `pub type alias Projection = { center = Vec2.Vec2, fx = Float64, fy = Float64 }`
- 近クリップ済みの線分。camA / camB = 切った後の端点（カメラ空間）、
  `pub type alias Clipped = { camA = CamPoint, camB = CamPoint, t0 = Float64, t1 = Float64, dist = Float64 }`
- h ストリップ（世界の縦のストリップ）を画面に落とした四隅。topA.x == botA.x を保証する
  `pub type alias Corners = { topA = Vec2.Vec2, topB = Vec2.Vec2, botA = Vec2.Vec2, botB = Vec2.Vec2 }`
- 世界の点をカメラ空間へ分解する。fwd = 視線方向の奥行き、lat = 右向きの横ずれ。
  `pub def toCam(cam: Camera, p: Vec2.Vec2): CamPoint`
- カメラからの放射距離（陰影・霧・ソートはこれを使う。fwd だけだと
  `pub def dist(c: CamPoint): Float64`
- 透視除算（x）。fwd が小さいほど大きく横に開く。
  `pub def screenX(proj: Projection, c: CamPoint): Float64`
- 透視除算（y）。h = ストリップの中の高さ（世界単位。- が上・+ が下。
  `pub def screenY(proj: Projection, h: Float64, c: CamPoint): Float64`
- 点の投影（クリップ済みの CamPoint → 画面 px）。大きさの換算は sizeAt へ —
  `pub def projectCam(proj: Projection, h: Float64, c: CamPoint): Vec2.Vec2`
- 世界単位の長さ worldLen が、奥行き c#fwd でどれだけの px に見えるか
  `pub def sizeAt(proj: Projection, worldLen: Float64, c: CamPoint): Float64`
- 点の投影（世界座標から一息に）。fwd が spec#near 未満（真横〜後方）は None。
  `pub def projectPoint(proj: Projection, cam: Camera, spec: { near = Float64, h = Float64 }, p: Vec2.Vec2): Option[Vec2.Vec2]`
- CamPoint の線形補間（線分の途中の点もカメラ空間では直線のまま）。
  `pub def camLerp(a: CamPoint, b: CamPoint, t: Float64): CamPoint`
- 近クリップ。fwd が near 未満の部分（カメラの真横〜後方）を切り落とし、
  `pub def clipSegment(near: Float64, camA: CamPoint, camB: CamPoint): Option[Clipped]`
- 高さの区間（strip#hTop..strip#hBot）を画面の四隅へ。端点ごとに x を 1 回だけ求めるので
  `pub def stripCorners(proj: Projection, strip: { hTop = Float64, hBot = Float64 }, camA: CamPoint, camB: CamPoint): Corners`
- 逆投影: 画面の走査線 sy が、高さ h の水平面のどの奥行きに当たるか。
  `pub def depthAtY(proj: Projection, h: Float64, sy: Float64): Float64`
- 距離霧の混合率。spec#base + d * spec#perDist を 0..spec#cap で止める
  `pub def fogAmount(spec: { base = Float64, perDist = Float64, cap = Float64 }, d: Float64): Float64`

## Physics2D — `engine_world/src/Physics2D.flix`
- `pub type alias Contact = { a = EntityId, b = EntityId, normal = Vec2.Vec2, point = Vec2.Vec2, penetration = Float64 }`
- id が絡む接触だけを残す。「このフレームでボールに起きたこと」を一度で取り出せる。
  `pub def contactsOf(id: EntityId, contacts: List[Contact]): List[Contact]`
- id が 1 つでも接触に絡んでいるか。「パドルに当たったら」の条件をそのまま書ける。
  `pub def touches(id: EntityId, contacts: List[Contact]): Bool`
- 接触の相手側の id。id がその接触に絡んでいなければ None。
  `pub def other(id: EntityId, contact: Contact): Option[EntityId]`
- contact の法線を「id を押し出す向き」に揃える（a 側ならそのまま・b 側なら反転）。
  `pub def normalToward(id: EntityId, contact: Contact): Vec2.Vec2`
- 面に近づく速度の法線成分だけを消す（跳ねずに滑る）。検出順に適用する。bounce の対。
  `pub def slide(id: EntityId, contacts: List[Contact], vel: Vec2.Vec2): Vec2.Vec2`
- normalToward が dir と minDot より強く揃う接触だけ残す
  `pub def contactsAlong(id: EntityId, dir: Vec2.Vec2, minDot: Float64, contacts: List[Contact]): List[Contact]`
- velocities に登録された entity だけ、その速度で位置を進める。登録の無い entity は
  `pub def integrate(dt: Float64, velocities: Map[EntityId, Vec2.Vec2], positions: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2]`
- 位置と形から、重なっている組を接触として返す。broadphase は共有の Collision（一様格子）に
  `pub def detect(positions: Map[EntityId, Vec2.Vec2], shapes: Map[EntityId, CollisionShape2D]): List[Contact]`
- 各接触について、速度を持つ側の速度を反発係数ぶん反射する。相手の速度を基準に取るので、
  `pub def bounce(contacts: List[Contact], restitutions: Map[EntityId, Float64], velocities: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2]`
- 各接触のめり込みを解消するよう位置を押し出す。動かせる側（velocities に居る側）だけを動かし、
  `pub def separate(contacts: List[Contact], velocities: Map[EntityId, Vec2.Vec2], positions: Map[EntityId, Vec2.Vec2]): Map[EntityId, Vec2.Vec2]`

## PxShade — `engine_world/src/PxShade.flix`
- 仕上げの重み。0 にしたものは掛からない。
  `pub type alias Spec = { rim = Float64, contact = Float64, dither = Float64, grain = Float64, grainScale = Int32, lightX = Int32, lightY = Int32 }`
- よくある設定（左上からの光・ふち光と接地影は全部・ディザは半分）。
  `pub def defaults(): Spec`
- 何も掛けない設定（絵をそのまま使いたいとき）。
  `pub def none(): Spec`
- 材料の「中の色 → (明るい色, 暗い色)」の表。文字はその絵の legend に合わせ、
  `pub type alias Ramp = Map[Char, (Char, Char)]`
- 1 コマ（文字格子）に仕上げを掛ける。
  `pub def shade(spec: Spec, ramp: Ramp, rows: List[String]): List[String]`
- 全コマ・全スプライトに同じ仕上げを掛けた Doc を返す（読み込み直後に 1 度だけ呼ぶ）。
  `pub def shadeDoc(spec: Spec, ramp: Ramp, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc`
- スプライトごとに仕上げを変えて掛ける。
  `pub def shadeWith(specOf: String -> Spec, ramp: Ramp, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc`

## PxSprite — `engine_world/src/PxSprite.flix`
- 結合済みの矩形 1 個(セル単位を px へ展開済み・key は未解決の意味色キー)。
  `pub type alias Run = { x = Float64, y = Float64, w = Float64, h = Float64, key = String }`
- コマを描く。出力は box(軸に平行な矩形)の列 — 呼び手の z にすべて載る。
  `pub def draw(doc: PxSpriteDoc.Doc, sprite: String, frame: String, at: Vec2.Vec2, flipX: Bool, scale: Int32, resolver: String -> Color, z: Int32): List[Render.PlacedItem]`
- コマを「アトラス 1 クアッド」で描く(opt-in の GL 実行時最適化)。
  `pub def drawQuad(doc: PxSpriteDoc.Doc, baked: PxSpriteAtlas.Baked, texture: String, sprite: String, frame: String, at: Vec2.Vec2, flipX: Bool, scale: Int32, z: Int32): List[Render.PlacedItem]`
- draw の座標計算だけ(テストと当たり判定用)。矩形は行ごと・左から右の順。
  `pub def runs(doc: PxSpriteDoc.Doc, sprite: String, frame: String, at: Vec2.Vec2, flipX: Bool, scale: Int32): List[Run]`
- 絵の真ん中から anchor（握るところ）へ向かうベクトル（px）。
  `pub def sizeOf(doc: PxSpriteDoc.Doc, sprite: String, frame: String, scale: Int32): Option[Vec2.Vec2]`
- 置き方の規約（anchor セルの左上 = at）はここが唯一の持ち主 — 呼び側で同じ計算を
  `pub def anchorOffsetOf(doc: PxSpriteDoc.Doc, sprite: String, frame: String, scale: Int32): Vec2.Vec2`
- anchor（握るところ）を軸に turn（1 周 = 1.0）だけ回して、アトラスの 1 クアッドで描く。
  `pub def drawQuadTurned(spec: { doc = PxSpriteDoc.Doc, baked = PxSpriteAtlas.Baked, texture = String, sprite = String, frame = String, at = Vec2.Vec2, flipX = Bool, scale = Int32, turn = Float64, z = Int32 }): List[Render.PlacedItem]`
- 文字格子の左上を at に置いて、アトラスの 1 クアッドで描く。
  `pub def drawQuadTopLeft(spec: { doc = PxSpriteDoc.Doc, baked = PxSpriteAtlas.Baked, texture = String, sprite = String, frame = String, at = Vec2.Vec2, scale = Int32, z = Int32 }): List[Render.PlacedItem]`

## PxSpriteAtlas — `engine_world/src/PxSpriteAtlas.flix`
- アトラス内の 1 コマの矩形(px・セル数と同じ)。
  `pub type alias Slot = { x = Int32, y = Int32, w = Int32, h = Int32 }`
- 生成した結果。pixels は side×side の ARGB(行優先)。regions のキーは (スプライト名, コマ名)。
  `pub type alias Baked = { side = Int32, regions = Map[(String, String), Slot], pixels = Vector[Int32] }`
- 何も持たない空のアトラス(「まだ生成していない」の置き場)。
  `pub def empty(): Baked`
- Doc の全スプライト×全コマを 1 枚に生成する。コマの順は Map 順(名前順)で決定的。
  `pub def bake(doc: PxSpriteDoc.Doc, resolver: String -> Color): Baked`
- bake の Result 版。どの辺長でも全コマを詰められないときは Err で、既定値を使うかどうかを
  `pub def bakeChecked(doc: PxSpriteDoc.Doc, resolver: String -> Color): Result[String, Baked]`
- (スプライト名, コマ名) → アトラス内矩形(Rect2・px)。regionRect(Item.Sprite)にそのまま渡せる。
  `pub def regionOf(baked: Baked, sprite: String, frame: String): Option[Rect2.Rect2]`
- 画素 1 個(ARGB)。範囲外・未 bake は透明 0。PNG 書き出し(SoftRaster.writeRadialPng)の
  `pub def pixelAt(baked: Baked, x: Int32, y: Int32): Int32`
- 生成した絵の一覧を「正方形の絵の一覧」へ写す（HeadlessRender.imagePngs / imageTextureInfo 用）。
  `pub def asImages(uploads: List[{ texture = String, baked = Baked | r }]): List[{ name = String, side = Int32, pixelAt = (Int32, Int32) -> Int32 }]`
- シェルフパッキング(棚詰め): items を与えられた順に左→右へ詰め、行に収まらなければ
  `pub def shelfPack(side: Int32, items: List[(k, (Int32, Int32))]): Option[Map[k, (Int32, Int32)]] with Order[k]`
- Color(0..1) → 不透明 ARGB。丸めは SoftRaster.byteOf と同一
  `pub def argbOf(c: Color): Int32`

## PxSpriteDoc — `engine_world/src/PxSpriteDoc.flix`
- コマの回し方。絵そのものには現れないので、Doc が言わないと誰にも分からない。
  `pub enum Loop with Eq, ToString { case Forward case PingPong case Once }`
- 動き 1 つ。どのコマをどの順で、1 秒に何コマで、どう回すか。
  `pub type alias Clip = { frames = List[String], fps = Float64, loop = Loop }`
- スプライト 1 体: anchor(格子内の基準セル — draw の置き場所がこのセルに来る)と、
  `pub type alias Sprite = { anchor = Vec2.Vec2, frames = Map[String, List[String]], clips = Map[String, Clip] }`
- sprite.json 全体。legend は 1 文字 → 意味色キー。
  `pub type alias Doc = { version = Int32, note = Option[String], legend = Map[Char, String], sprites = Map[String, Sprite] }`
- 何も描かない空の Doc。「まだ読めていない」の置き場 — draw は常に空を返す。
  `pub def empty(): Doc`
- コマも何も持たないスプライト。Sprite を組み立てる呼び側の土台
  `pub def emptySprite(): Sprite`
- コマを 1 枚も持たない動き。既定の速さは 8fps(人が歩く絵でだいたい合う)。
  `pub def emptyClip(): Clip`
- テキストから Doc へ(fail-open)。JSON でない・形が違うフィールドは既定へ落とす。
  `pub def fromJson(text: String): Option[Doc]`
- パース済みの Json 値から Doc へ(エディタの doc/path 経路用 — fromJson と同じ fail-open)。
  `pub def fromJsonValue(json: Json): Option[Doc]`
- 動きの t 秒後に出すコマの名前。動きが無い・fps が 0 以下なら None
  `pub def clipFrameAt(doc: Doc, sprite: String, clip: String, seconds: Float64): Option[String]`
- 通し番号 step(0,1,2,…)を、回し方に沿ったコマ番号へ写す。
  `pub def frameIndexAt(kind: Loop, count: Int32, step: Int32): Int32`
- コマの格子の大きさ（列数・行数）。列数は一番長い行の文字数。
  `pub def gridSizeOf(doc: Doc, sprite: String, frame: String): Option[{ cols = Int32, rows = Int32 }]`
- path の Doc を読む。読めない・壊れているときは empty(fail-open)。
  `pub def load(p: String): Doc \ Fs.FileRead`

## PxTerrain — `engine_world/src/PxTerrain.flix`
- 4x4 Bayer の敷居 0..1。同じ (x, y) からは同じ値が出る（何度描いても同じ絵）。
  `pub def bayer4(x: Int32, y: Int32): Float64`
- 上端と下端が場所ごとに動く帯を敷く。
  `pub def fill(spec: { z = Int32, span = { x0 = Float64, x1 = Float64 }, topAt = Float64 -> Float64, bottomAt = Float64 -> Float64, rampAt = Vec2.Vec2 -> Vector[Color], valueAt = Vec2.Vec2 -> Float64, cell = Float64 }) : List[Render.PlacedItem]`

## Quad — `engine_world/src/Quad.flix`
- 幅 `2*halfW`・高さ `2*halfH` の矩形を `center` を中心に `angle` ラジアン回した
  `pub def rotated(center: Vec2.Vec2, halfW: Float64, halfH: Float64, angle: Float64): List[Vec2.Vec2]`
- 向きを角度でなく単位軸ベクトル `axis` で与える `rotated`。`axis` は箱のローカル +x
  `pub def orientedByAxis(center: Vec2.Vec2, axis: Vec2.Vec2, halfLen: Float64, halfThick: Float64): List[Vec2.Vec2]`
- `p0` から `p1` への線分に沿った一定幅のストリップで、中心線の両側の符号つき法線オフセット
  `pub def strip(p0: Vec2.Vec2, p1: Vec2.Vec2, o1: Float64, o2: Float64): List[Vec2.Vec2]`

## Query — `engine_world/src/Query.flix`
- 2 種の component を「両方持つ」entity だけを取り出し、その値の組を返す。
  `pub def with2(a: Map[EntityId, x], b: Map[EntityId, y]): Map[EntityId, (x, y)]`
- target を、other を見ながら更新する。両方持つ entity だけ update を適用し、
  `pub def updateWith2(target: Map[EntityId, x], other: Map[EntityId, y], update: x -> y -> x): Map[EntityId, x]`
- entity レコードのリストから component store を作る（scene→World read-model mirror の核）。
  `pub def indexBy(keyOf: a -> EntityId, valOf: a -> v, xs: List[a]): Map[EntityId, v]`
- entity レコードのリストから id 集合（tag）を作る。
  `pub def tagOf(keyOf: a -> EntityId, xs: List[a]): Set[EntityId]`
- 印（tag）が付いた entity の値だけ f を通す。印の無い entity は値も並びもそのまま。
  `pub def updateTagged(tag: Set[EntityId], f: v -> v, store: Map[EntityId, v]): Map[EntityId, v]`
- 2 store を join し、両方持つ entity だけを f で射影して list 化する（with2 の list 版）。
  `pub def with2List(a: Map[EntityId, x], b: Map[EntityId, y], f: EntityId -> x -> y -> r): List[r]`

## RandomUtil — `engine_world/src/RandomUtil.flix`
- `pub def pick(l: List[a]): Option[a] \ Math.Random`

## RawDraw — `engine_world/src/RawDraw.flix`
- 単色塗りの矩形（左上原点・サイズ指定）。
  `pub def box(size: Vec2.Vec2, color: Color, zIndex: Int32): Item`
- 単色塗りの円（直径 radius×2 の全角丸 Box）。置き場所は外接正方形の左上。
  `pub def circle(radius: Float64, color: Color, zIndex: Int32): Item`
- 中心 center に置いた単色の円（PlacedItem）。外接正方形の左上への換算はここが済ませる。
  `pub def circleAt(center: Vec2.Vec2, radius: Float64, color: Color, zIndex: Int32): PlacedItem`
- 中心 center に置いた単色の矩形（PlacedItem）。左上で置きたいときは box を使う。
  `pub def boxAt(center: Vec2.Vec2, size: Vec2.Vec2, color: Color, zIndex: Int32): PlacedItem`
- items が空なら boxAt の仮色の板 1 枚にする fail-open。スプライトのコマ名違い・
  `pub def orBoxAt(center: Vec2.Vec2, size: Vec2.Vec2, color: Color, zIndex: Int32, items: List[PlacedItem]): List[PlacedItem]`
- 単色塗りの多角形。頂点は置き場所からの相対座標で渡す（絶対座標で組みたいときは
  `pub def polygon(vertices: List[Vec2.Vec2], color: Color, zIndex: Int32): Item`
- 正 n 角形（外接半径 radius・頂点が真上・原点中心）。三角形・ひし形・六角形はこれ。
  `pub def ngon(n: Int32, radius: Float64, color: Color, zIndex: Int32): Item`
- ngon を中心 center に置く近道。
  `pub def ngonAt(center: Vec2.Vec2, n: Int32, radius: Float64, color: Color, zIndex: Int32): PlacedItem`
- 楕円（radii は x/y の半径・原点中心。32 角形の近似）。
  `pub def ellipse(radii: Vec2.Vec2, color: Color, zIndex: Int32): Item`
- ellipse を中心 center に置く近道。
  `pub def ellipseAt(center: Vec2.Vec2, radii: Vec2.Vec2, color: Color, zIndex: Int32): PlacedItem`
- 縁の分割数を選べる楕円。小さく描く楕円（足元の影・遠くの茂み）では、既定の 32 分割は
  `pub def ellipseSegs(radii: Vec2.Vec2, segs: Int32, color: Color, zIndex: Int32): Item`
- ellipseSegs を中心 center に置く近道。
  `pub def ellipseSegsAt(center: Vec2.Vec2, radii: Vec2.Vec2, segs: Int32, color: Color, zIndex: Int32): PlacedItem`
- その大きさの楕円に見合う縁の分割数。頂点の間隔がおよそ 2px になる所で頭打ちにする
  `pub def ellipseSegsFor(radii: Vec2.Vec2): Int32`
- 扇形（パイ。要が原点）。中心角が半周を超える形（パックマン等）も正しく塗れる
  `pub def sector(radius: Float64, sweep: {fromT = Float64, toT = Float64}, color: Color, zIndex: Int32): Item`
- sector を中心 center に置く近道。
  `pub def sectorAt(center: Vec2.Vec2, radius: Float64, sweep: {fromT = Float64, toT = Float64}, color: Color, zIndex: Int32): PlacedItem`
- 円を弦で切った弓形（弧 + 弦。多角形は自動で閉じる・原点中心の円由来）。
  `pub def circleSegment(radius: Float64, sweep: {fromT = Float64, toT = Float64}, color: Color, zIndex: Int32): Item`
- circleSegment を中心 center に置く近道。
  `pub def circleSegmentAt(center: Vec2.Vec2, radius: Float64, sweep: {fromT = Float64, toT = Float64}, color: Color, zIndex: Int32): PlacedItem`
- 星（points 尖り・外径と内径の交互・原点中心）。凹んだ形の代表。
  `pub def star(points: Int32, radii: {outer = Float64, inner = Float64}, color: Color, zIndex: Int32): Item`
- star を中心 center に置く近道。
  `pub def starAt(center: Vec2.Vec2, points: Int32, radii: {outer = Float64, inner = Float64}, color: Color, zIndex: Int32): PlacedItem`
- 線分 a→b の輪郭（太さ width の凸四角形の頂点列）。lineSeg の芯で、時計の針のように
  `pub def lineQuad(a: Vec2.Vec2, b: Vec2.Vec2, width: Float64): List[Vec2.Vec2]`
- 線分 a→b を太さ width の四角形で描く（任意角度の線の代用）。
  `pub def lineSeg(a: Vec2.Vec2, b: Vec2.Vec2, width: Float64, color: Color, zIndex: Int32): PlacedItem`

## RemoteDebug — `engine_world/src/RemoteDebug.flix`
- HTTP サーバ本体と、リクエスト / レスポンスを受け渡す 2 本のキュー。
  `pub type alias Bridge = { server = HttpServer, requests = JQueue[String], responses = JQueue[String] }`
- 環境変数 DEBUG_HTTP_PORT からポート番号を読む。未設定・数値でなければ None。
  `pub def portFromEnv(): Option[Int32] \ IO`
- 127.0.0.1 の port で HTTP サーバを立てて Bridge を返す。
  `pub def start(port: Int32): Bridge \ IO`
- ゲームループが毎フレーム呼ぶ非ブロッキングの受信。届いていなければ None。
  `pub def pollRequest(bridge: Bridge): Option[String] \ IO`
- 応答本文を HTTP スレッドへ返す（pollRequest で受けた 1 件に必ず 1 回対で呼ぶ）。
  `pub def respond(text: String, bridge: Bridge): Unit \ IO`
- サーバを止める（ゲーム終了時）。待機中のリクエストは切断される。
  `pub def shutdown(bridge: Bridge): Unit \ IO`
- パース済みリクエスト。1 行目が "METHOD /path?query"、2 行目以降がボディ（台本 DSL）。
  `pub type alias Request = { method = String, path = String, params = Map[String, String], body = String }`
- Bridge から受けた生文字列をリクエストへ分解する。
  `pub def parseRequest(raw: String): Request`
- ゲーム登録の任意ルート（App.onRequest）から、パスに完全一致する最初の 1 本を選ぶ。
  `pub def findRoute(path: String, routes: List[(String, a)]): Option[a]`
- 観測の詳細度。応答のトークン量を必要最小限に抑えるための選択肢。
  `pub enum View with Eq, ToString { case Status, case Summary, case Full, case Scene, case Silent }`
- /step を台本の途中で止める条件。「意味のある瞬間」で止まることで往復を減らす。
  `pub enum Until with Eq, ToString { case Always, case SfxAny, case SfxNamed(Set[String]), case Quiet(Int32) }`
- /step・/state のクエリを解釈した実行パラメータ。
  `pub type alias StepParams = { view = View, rect = Option[Rect2.Rect2], stopWhen = Until, maxFrames = Int32, traceEvery = Option[Int32], dtSeconds = Float64 }`
- クエリ Map を StepParams へ。不正な値は理由つきの Err（応答にそのまま載せる）。
  `pub def parseParams(queryMap: Map[String, String]): Result[String, StepParams]`
- 1 リクエストで実行できる合成フレーム数の天井（60fps で 1 分ぶん）。
  `pub def frameCap(): Int32`
- until 条件の 1 フレームぶんの判定。このフレームで鳴った音名と「無音が何フレーム
  `pub def stopCheck(stopWhen: Until, soundsThisFrame: List[String], quietRun: Int32): (String, Int32)`
- 台本 1 コマ = そのフレームで押しているキーの集合。リストの並びがフレームの並び。
  `pub type alias Script = List[Set[GameEngine.Key]]`
- 台本 DSL を 1 フレーム 1 コマのキー集合列へ展開する。# 以降はコメント。
  `pub def parseScript(body: String): Result[String, Script]`
- "z" や "Enter" のようなキー名を Key へ。解決は InputMap と同じ 1 本 —
  `pub def keyOf(name: String): Option[GameEngine.Key]`
- 台本で使える全キー名（help と unknown key エラーに載せる）。
  `pub def keyNames(): String`
- /step 応答の 1 行目。何フレーム進んで何故止まったかを 1 行で伝える。
  `pub def stepHeader(info: { stepped = Int32, total = Int32, frame = Int64, stoppedBy = String, quit = Bool }): String`
- 実行中に鳴った音のブロック。「f=フレーム番号 sfx=音名」の行を時系列で並べる。
  `pub def eventsBlock(sounds: List[(Int64, String)]): String`
- trace=status:K で集めた status 行のブロック。
  `pub def traceBlock(lines: List[String]): String`
- scene ビューの本文。矩形に重なる描画物を z 順に 1 行ずつ（多すぎる場合は打ち切る）。
  `pub def sceneBlock(rect: Rect2.Rect2, hitList: List[Annotate.Hit]): String`
- 小数第 1 位までに丸めた表示（座標の長い小数でトークンを浪費しないため）。
  `pub def fmt1(value: Float64): String`
- view=full の本文の安全弁。矩形無指定の worldDump は数万文字になり得る
  `pub def capBody(text: String): String`
- POST /render の成功応答。1 行目に枚数と所要ミリ秒、続く [rendered] ブロックに
  `pub def renderDoneText(ms: Int64, paths: List[String]): String`
- 描き出しの実体（App.onRenderRequest）を登録していないゲームへの応答。
  `pub def renderUnsupportedText(): String`
- GET /help の本文。プロトコルの自己記述（セッション冒頭に 1 回読む想定）。
  `pub def helpText(): String`
- リモートコマンド処理が次の実フレームへ持ち回す状態。
  `pub type alias RemoteNext[w] = { world = w, anno = Annotate.State, history = List[w], hold = Bool }`
- リクエスト 1 件を捌き、応答をブリッジへ書いてから次の状態を返す。
  `pub def handleRemote(app: App.App[w, ef], bridge: RemoteDebug.Bridge, raw: String, ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + GameEngine.Audio + Fs.FileRead + IO)`

## Render — `engine_world/src/Render.flix`
- 傾き（rotation）の単位は「回転数」— 1 周 = 1.0・正で時計回り。ラジアンへの変換は
  `pub enum Item { case Sprite({ texture = String, tint = Color, alpha = Float64, scale = Vec2.Vec2, rotation = Float64, centered = Bool, flipH = Bool, flipV = Bool, regionRect = Option[Rect2.Rect2], zIndex = Int32, blend = DrawCmd.BlendMode, maskPolys = List[List[Vec2.Vec2]] }) case Text({ text = String, fontAtlas = FontAtlas, fontSize = Float64, tint = Color, rotation = Float64, zIndex = Int32, wrapWidth = Option[Float64] }) case Box({ size = Vec2.Vec2, color = Color, alpha = Float64, rotation = Float64, style = Option[GameEngine.BoxStyle], zIndex = Int32, blend = DrawCmd.BlendMode }) case Poly({ vertices = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32, blend = DrawCmd.BlendMode, grad = Option[List[DrawCmd.VertexTint]] }) case Clipped({ rect = Rect2.Rect2, inner = Item }) case Shader({ rect = Rect2.Rect2, spec = ShaderDoc.Spec, t = Float64, mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode }) }`
- 置き場所つきの描画物。View はこの列を組み、draw が描画命令へ変換する。
  `pub type alias PlacedItem = { at = Vec2.Vec2, item = Item }`
- 全テクスチャ・等倍・中心原点のスプライト（最頻ケース）。反転が要るときは spriteFlipped。
  `pub def sprite(texture: String, zIndex: Int32): Item`
- 反転付きスプライト。同型の Bool 2 つは取り違えやすいので名前で渡す。
  `pub def spriteFlipped(texture: String, zIndex: Int32, flip: { flipH = Bool, flipV = Bool }): Item`
- `pub def text(content: String, fontAtlas: FontAtlas, fontSize: Float64, zIndex: Int32): Item`
- 着色テキスト。disabled のグレー表示やカーソル色、見出しの強調色などに使う。
  `pub def textTinted(content: String, fontAtlas: FontAtlas, fontSize: Float64, tint: Color, zIndex: Int32): Item`
- 折り返し付きの着色テキスト。wrapWidth（design px）を超える字は次の行へ送られる。
  `pub def textWrapped(content: String, fontAtlas: FontAtlas, look: { fontSize = Float64, wrapWidth = Float64, tint = Color, zIndex = Int32 }): Item`
- 中心 center に置いた、縁がふわっと消える円の列（ソフトな光の玉）。
  `pub def glowAt(center: Vec2.Vec2, radius: Float64, color: Color, look: { alpha = Float64, blend = DrawCmd.BlendMode }, zIndex: Int32): List[PlacedItem]`
- 中心 at に置いた放射状の明かり 1 枚（松明・スポットライト・光だまり）。
  `pub def lightAt(spec: { at = Vec2.Vec2, radius = Float64, color = Color, strength = Float64, z = Int32 }): PlacedItem`
- 中心 at に置いた放射状の翳り 1 枚（vignette・足元の影だまり・画面の隅を沈める）。
  `pub def darkAt(spec: { at = Vec2.Vec2, radius = Float64, strength = Float64, z = Int32 }): PlacedItem`
- 宣言シェーダーで矩形 rect を塗る面（PlacedItem）。at に rect の左上を入れる —
  `pub def shaderFill(spec: ShaderDoc.Spec, rect: Rect2.Rect2, t: Float64, zIndex: Int32): PlacedItem`
- 宣言シェーダーで rect を塗り、maskPolys（ワールド座標の多角形の列）の内側だけに抜く面。
  `pub def shaderFillMasked(spec: ShaderDoc.Spec, rect: Rect2.Rect2, maskPolys: List[List[Vec2.Vec2]], t: Float64, zIndex: Int32): PlacedItem`
- pass（レンダーターゲット）を、全面でない面（横長のストリップなど）から等倍で読むための dy 場。
  `pub def passStripDy(strip: { top = Float64, height = Float64 }, passH: Float64, flipV: Bool): ShaderDoc.Field`
- 頂点色つきの凸多角形。各頂点に色と濃さを与えると、面の中で滑らかに混ざる
  `pub def gradPolygon(vertices: List[DrawCmd.GradVertex], zIndex: Int32): Item`
- 上下 2 色の縦グラデ矩形（左上原点・サイズ指定）。空や夕暮れの背景の定番形。
  `pub def vgrad(size: Vec2.Vec2, colors: { top = Color, bottom = Color }, zIndex: Int32): Item`
- item を pos（左上）に置く純糖衣 — `{ at = pos, item = item }` と同じ値。
  `pub def at(pos: Vec2.Vec2, item: Item): PlacedItem`
- 飾り終えた「左上原点の item」（box / circle / text）を中心 center に置く
  `pub def atCenter(center: Vec2.Vec2, size: Vec2.Vec2, item: Item): PlacedItem`
- item を rect（スクリーン空間・design px）で切り抜く。clip 矩形の外のピクセルは描かれない。
  `pub def clipped(rect: Rect2.Rect2, item: Item): Item`
- 置き場所つきの列をまとめて切り抜く近道（PiP・パネル内スクロールの出口で使う）。
  `pub def clippedAll(rect: Rect2.Rect2, items: List[PlacedItem]): List[PlacedItem]`
- 角を丸める（Box に効く）。
  `pub def rounded(radius: Float64, item: Item): Item`
- 透明度（alpha）を指定した値にする（Sprite / Box / Poly に効く。Text は tint が濃度を兼ねる）。
  `pub def fade(alpha: Float64, item: Item): Item`
- 置き場所はそのままに、中身（Item）だけ入れ替える。`fade` や `rounded` のような
  `pub def overItem(f: Item -> Item \ ef, placed: PlacedItem): PlacedItem \ ef`
- 組み上がった列を丸ごと薄くする（`fade` の列版）。覆い・淡い層・消えていく残像に使う。
  `pub def fadeAll(alpha: Float64, items: List[PlacedItem]): List[PlacedItem]`
- ピクセルの重ね方を変える（Sprite / Box / Poly に効く。Text は文字の可読性が第一で対象外）。
  `pub def blended(mode: DrawCmd.BlendMode, item: Item): Item`
- 重なり順（zIndex）を delta だけずらす。組み上がった絵の相対的な前後関係は保ったまま、
  `pub def zShifted(delta: Int32, item: Item): Item`
- 重なり順（zIndex）を関数 f で写す（zShifted の一般形）。
  `pub def zMapped(f: Int32 -> Int32, item: Item): Item`
- 置き場所つきの列を丸ごと delta だけずらす（zShifted の列版）。
  `pub def zShiftedAll(delta: Int32, items: List[PlacedItem]): List[PlacedItem]`
- 組み上がった列を丸ごと d だけ動かす（zShiftedAll の位置版）。
  `pub def movedAll(d: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem]`
- 組み上がった列を、pivot（画面座標）を不動点に factor 倍へ伸縮する（ズーム演出・
  `pub def scaledAllAround(factor: Float64, pivot: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem]`
- 置き場所と頂点を step px の升目に載せる（ドット絵の升目に合わせて角を落とす）。
  `pub def snapped(step: Float64, item: Item): Item`
- snapped の列版（置き場所も升目に載せる）。
  `pub def snappedAll(step: Float64, items: List[PlacedItem]): List[PlacedItem]`
- 絵の色を差し替える（Sprite だけに効く。白 = 元の絵のまま）。同じ 1 枚の絵を、
  `pub def tinted(color: Color, item: Item): Item`
- tinted の列版。
  `pub def tintedAll(color: Color, items: List[PlacedItem]): List[PlacedItem]`
- 絵を多角形で型抜きする（Sprite にだけ効く。空 = 抜かない）。ガラス片・ちぎれた紙のような
  `pub def masked(polys: List[List[Vec2.Vec2]], item: Item): Item`
- 飾りの無い箱（角丸・枠線・縞・市松・回転がどれも無い単色）を、同じ形の多角形へ直す。
  `pub def boxAsPoly(item: Item): Item`
- boxAsPoly の列版。
  `pub def boxesAsPolys(items: List[PlacedItem]): List[PlacedItem]`
- 頂点列を左右に鏡映する（縦軸で x を反転・2 回で元に戻る）。polygon や Bezier の
  `pub def flipH(vertices: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 頂点列を上下に鏡映する（横軸で y を反転・2 回で元に戻る）。使い方は flipH と同じ。
  `pub def flipV(vertices: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 頂点列を原点周りに t（1 周 = 1.0・正で時計回り = 画面の見た目どおり）回す。
  `pub def rotated(t: Float64, vertices: List[Vec2.Vec2]): List[Vec2.Vec2]`
- 任意の点 pivot 周りに回す（蝶番・ドア用の近道。pivot へ移して回して戻すのと同じ）。
  `pub def rotatedAround(t: Float64, pivot: Vec2.Vec2, vertices: List[Vec2.Vec2]): List[Vec2.Vec2]`
- item を自分の軸で t（1 周 = 1.0）傾ける。軸は Box / Sprite が自分の中心、Text が置き場所、
  `pub def turned(t: Float64, item: Item): Item`
- 置き場所つきの列を、pivot（画面座標）のまわりに丸ごと t 傾ける。カード 1 枚のように
  `pub def turnedAll(t: Float64, pivot: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem]`
- 置き場所つきの列を、pivot（画面座標）のまわりに t（1 周 = 1.0）回す純関数。
  `pub def rotatedAroundAll(t: Float64, pivot: Vec2.Vec2, items: List[PlacedItem]): List[PlacedItem]`
- 枠線を付ける（Box に効く）。
  `pub def outline(color: Color, width: Float64, item: Item): Item`
- 濃さつきの枠線を付ける（Box に効く）。outline は枠が常に不透明 — 中身を邪魔しない
  `pub def outlineA(border: { color = Color, alpha = Float64, width = Float64 }, item: Item): Item`
- 縞模様を敷く（Box に効く）。dir は 0 = 斜め 45° / 1 = 横縞 / 2 = 縦縞。
  `pub def striped(stripe: { color = Color, alpha = Float64, width = Float64, period = Float64, dir = Int32 }, item: Item): Item`
- 市松のタイルを重ねる（Box に効く）。PC-98 の網ディザ風。
  `pub def checker(c: { color = Color, alpha = Float64, cell = Float64 }, item: Item): Item`
- 大きさ系の属性を factor 倍する（全種類の item に効く）。camera の zoom 適用の芯:
  `pub def scaled(factor: Float64, item: Item): Item`
- zIndex を delta だけ持ち上げる（全種類の item に効く）。組み上がった item の列を
  `pub def raiseZ(delta: Int32, item: Item): Item`
- 本編より先にレンダーターゲットへ描く 1 枚ぶんの宣言（App.withPasses で列を渡す）。
  `pub type alias Pass = { name = String, clear = RenderTarget.LoadOp, items = List[PlacedItem] }`
- レンダーターゲット（Pass の name）を design 全面へ等倍で貼る（中心置き）。ターゲットは
  `pub def blit(name: String, design: Vec2.Vec2, z: Int32): PlacedItem`
- レンダーターゲット name の一部 src（ターゲット上の px 矩形）を、at を中心に size の
  `pub def blitRegion(spec: { name = String, design = Vec2.Vec2, src = Rect2.Rect2, at = Vec2.Vec2, size = Vec2.Vec2, z = Int32 }): PlacedItem`
- Pass 1 枚を描き出し側の宣言（engine_tools の HeadlessRender.PassSpec と同形のレコード）へ
  `pub def passSpecOf(textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef, p: Pass): { name = String, clear = RenderTarget.LoadOp, drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd] } \ ef`
- draw list 全体を描画命令へ（zIndex 順は render_gl が stable sort する）。
  `pub def draw(items: List[PlacedItem]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd])`
- `draw` の atlas 注入版。Sprite の region UV を textureInfoOf で解決しつつ、
  `pub def drawWith(textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef, items: List[PlacedItem]): (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) \ ef`
- そのフレームに描く字の集合の指紋（テクスチャ名と文の codepoint を織り込んだ Int64）。
  `pub def glyphFingerprint(items: List[PlacedItem]): Int64`
- 描く物のうち、フォントのアトラスにまだ無い字を「テクスチャ名 → 字」で集める。
  `pub def missingGlyphs(items: List[PlacedItem]): Map[String, Set[Int32]]`
- Shader 面だけを取り出して eff Shader が食える描画依頼へ変換する（GL 経路専用）。
  `pub def drawShaders(programOf: ShaderDoc.Spec -> GpuHandle.ShaderProgram \ ef, items: List[PlacedItem]): List[ShaderEffect.ShaderRenderCmd] \ ef`
- GL の無い経路（描き出し / SoftRaster）が ShaderEval で面を描くための純データ。
  `pub type alias ShaderSurface = { rect = Rect2.Rect2, spec = ShaderDoc.Spec, time = Float64, mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode }`
- Shader 面を純データ（ShaderSurface）で取り出す（描き出し / SoftRaster 用）。
  `pub def shaderSurfaces(items: List[PlacedItem]): List[ShaderSurface]`
- Shader 面を除いた PlacedItem 列（GL 経路で draw に渡す前に外す — 本物のシェーダーは
  `pub def withoutShaders(items: List[PlacedItem]): List[PlacedItem]`
- World 由来 Drawable 群に camera のズーム倍率を適用する（位置は `Projection.applyToWorldPos` で
  `pub def applyCameraScale(transform: Projection.ViewTransform, ds: List[GameEngine.Drawable]): List[GameEngine.Drawable]`
- 1 アイテム → 複数 Drawable（ボタン等は呼び側で複数アイテムにする）。
  `pub def toDrawables(item: Item, pos: Vec2.Vec2): List[GameEngine.Drawable]`

## RenderManifest — `engine_world/src/RenderManifest.flix`
- 画面の中でその物が何をしているか。**語彙はここで閉じる**（intent と違い、
  `pub enum Role with Eq, ToString { case Subject case Prop case Backdrop case Effect }`
- JSON に出す名前。
  `pub def roleKey(r: Role): String`
- 目録の 1 行 = 描いた物 1 つについての**作者の申告**。
  `pub type alias Claim = { id = String, kind = String, material = String, role = Role, layer = String, zIndex = Int32, at = ViewProjection.WorldPos, src = String, aabb = Rect2.Rect2, colors = List[Color], intent = List[String] }`
- 測れなかった検査と、その理由。黙って落とさないための行。
  `pub type alias Unmeasured = { check = String, why = String }`
- 欠けた欄の落ち先。1 行はこの上に足りる欄だけ載せて組む:
  `pub def blank(): Claim`
- intent は「作者が主張していること」の並び。**既定を「全部検査する」から
  `pub def undeclaredIds(claims: List[Claim]): List[String]`
- 目録 1 枚ぶんの JSON テキスト（末尾に改行付き）。
  `pub def build(meta: { shot = String, projection = ViewProjection.ViewProjection, background = Color }, claims: List[Claim], palette: Map[String, Color], unmeasured: List[Unmeasured]): String`
- PNG の隣に置く目録のパス。
  `pub def pathOf(outDir: String, name: String): String`
- 目録を path へ書き出す。親ディレクトリは作らない（`Fs.WriteFile` の流儀）。
  `pub def write(path: String, text: String): Result[String, Unit] \ Fs.FileWrite`

## Replay — `engine_world/src/Replay.flix`
- Trace の一拍: この input を frames フレームのあいだ保持する。入力型 i は多相
  `pub type alias Cue[i] = { input = i, frames = Int32 }`
- Trace を最後まで駆動し、終端の World を返す。各 Cue について tick を frames 回、
  `pub def play(tick: (i, Float64, w) -> w, dt: Float64, cues: List[Cue[i]], initial: w): w`
- Trace の各フレームを順に並べた列 — GIF・解析・スクラブの原反。initial 自身は
  `pub def timeline(tick: (i, Float64, w) -> w, dt: Float64, cues: List[Cue[i]], initial: w): List[w]`

## Resource — `engine_world/src/legacy/Resource.flix`
- `KindedRefListT` で使う 1 種別ぶんの記述。
  `pub type alias KindSpec = { kindId = String, label = String, target = String }`
- フィールドの値型。IDE はこれと `FieldHint` の組から widget を選ぶ。
  `pub enum FieldType { case TextT case IntT case FloatT case BoolT case TexturePathT case RefT(String) case RefPercentListT(String) case KindedRefListT(List[KindSpec]) case EnumT(List[String]) case SpriteFramesT case WeaponProfT }`
- 編集 UI のヒント。`Plain` は型相応の素直な入力欄（数値スピナー / テキスト等）。
  `pub enum FieldHint { case Plain case Multiline case Slider({min = Float64, max = Float64, step = Float64}) case Spinner({min = Int32, max = Int32}) case FrameGrid({hframesField = String, vframesField = String}) }`
- 1 フィールドぶんの完全記述。
  `pub type alias FieldSchema = { ftype = FieldType, hint = FieldHint, label = String, order = Option[Int32] }`
- レコード 1 件のフィールド木。`Field` は葉、`Nested` はサブレコード。
  `pub enum FieldEntry { case Field(FieldSchema) case Nested(Map[String, FieldEntry]) }`
- catalog 外のトップレベル array (例: `players: ["knight", ...]`) の編集 UI を決めるヒント。
  `pub enum MetaHint with Eq, ToString { case Ref(String) case Text }`
- ファイル単位の schema。fields は catalog 子レコードのフィールド構造、metaHints は data top の
  `pub enum ResourceSchema { case ResourceSchema({ fields = Map[String, FieldEntry], metaHints = Map[String, MetaHint] }) }`
- `ResourceSchema` の中身（フィールド集合）を取り出す。
  `pub def fieldsOf(schema: ResourceSchema): Map[String, FieldEntry]`
- メタフィールドの編集ヒントを取り出す。指定されていなければ空 Map。
  `pub def metaHintsOf(schema: ResourceSchema): Map[String, MetaHint]`
- `Map[String, FieldEntry]` から `ResourceSchema` を作るコンストラクタ。
  `pub def mkSchema(fields: Map[String, FieldEntry]): ResourceSchema`
- fields と metaHints を両方指定するコンストラクタ。
  `pub def mkSchemaWithMeta(fields: Map[String, FieldEntry], metaHints: Map[String, MetaHint]): ResourceSchema`
- `_schema.json` をパースして `ResourceSchema` を返す。形式不一致は `None`。
  `pub def loadSchema(path: String): Option[ResourceSchema] \ Fs.FileRead`
- `loadSchema` の診断つきバリアント。失敗の段階を文字列で返す。
  `pub def loadSchemaDiagnostic(path: String): Result[String, ResourceSchema] \ Fs.FileRead`
- 整合性検査。schema の **トップレベルフィールド集合** が `expected` の部分集合か検証する。
  `pub def checkConsistency(expected: Set[String], schema: ResourceSchema): Result[String, Unit]`

## ResourceCodec — `engine_world/src/legacy/Resource.flix`
- `pub def encodeSchema(s: ResourceSchema): Json`
- `pub def decodeSchema(element: Json): Option[ResourceSchema]`

## RichText — `engine_world/src/RichText.flix`
- 1 スパン。tint = None は呼び側の基本色で描く。bold は同じ字を半ピクセルずらして
  `pub type alias Span = { text = String, tint = Option[Color], bold = Bool }`
- `pub def plain(text: String): Span`
- `pub def colored(text: String, tint: Color): Span`
- `pub def strong(text: String): Span`
- 見た目を除いた素の文章（文字送りの長さ勘定・テストの pin に使う）。
  `pub def plainText(spans: List[Span]): String`
- 全スパンの合計文字数。
  `pub def length(spans: List[Span]): Int32`
- 先頭 n 文字ぶんだけ残す（タイプライター表示用）。スパンの途中でも切れる。
  `pub def take(n: Int32, spans: List[Span]): List[Span]`
- place の引数一式。pos = 左上、maxWidth = 折返し幅（pos#x からの幅）、
  `pub type alias Placement = { atlas = FontAtlas, size = Float64, baseTint = Color, z = Int32, pos = Vec2.Vec2, maxWidth = Float64, lineGap = Float64 }`
- スパン列を最大幅で行の列へ折る。折る規則は描画(place)と同一 — 字単位で、収まらない
  `pub def wrapLinesBy(charWidth: Char -> Float64, maxWidth: Float64, spans: List[Span]): List[List[Span]]`
- スパン列を左上 pos から 1 文字ずつ置いていく。行割りは wrapLinesBy(atlas の実測幅)で、
  `pub def place(p: Placement, spans: List[Span]): List[Render.PlacedItem]`

## SaveManager — `engine_world/src/SaveManager.flix`
- `saves/slot{N}.json` のパス。
  `pub def slotPath(slot: Int32): String`
- スロット `slot` に `data` を書き出す。失敗時は `Err(message)`。
  `pub def write(slot: Int32, data: a): Result[String, Unit] \ Fs.FileWrite with Saveable[a]`
- スロット `slot` から読み出す。ファイル不在・パース失敗・形式不一致は `None`。
  `pub def read(slot: Int32): Option[a] \ Fs.FileRead with Saveable[a]`

## Scatter — `engine_world/src/Scatter.flix`
- 見えている範囲 visible を覆うセルを走査し、各セルに place を呼んで結果を全部つなぐ。
  `pub def field(visible: Rect2.Rect2, spec: {cell = Float64, salt = Int32}, place: ({col = Int32, row = Int32}, Int32 -> Float64) -> List[a]): List[a]`
- field の「ここだけ空ける」版。exclude の矩形（world 座標）に少しでも掛かるセルは
  `pub def fieldExcept(visible: Rect2.Rect2, spec: {cell = Float64, salt = Int32}, exclude: List[Rect2.Rect2], place: ({col = Int32, row = Int32}, Int32 -> Float64) -> List[a]): List[a]`
- 1 本のストリップ（横一列）にセルを敷く。疑似遠近の絵（奥のストリップほど広い世界が画面に入る）では
  `pub def strip(span: {lo = Float64, hi = Float64}, spec: {cell = Float64, salt = Int32, lane = Int32, reach = Float64, cellsMax = Int32}, place: (Int32, Int32 -> Float64) -> List[a]): List[a]`

## SceneSeq — `engine_world/src/SceneSeq.flix`
- perform が返す、カット 1 つの行方。
  `pub enum Status[p] { case Running(p) case Done case Skip(String) }`
- シーンの進行状態。cuts = 残りのカット（先頭が演じている最中の 1 つ）、
  `pub type alias State[c, p] = { cuts = List[c], progress = Option[p], at = Int32, notes = List[String] }`
- カット→コマの対応表の 1 行。cut = 1 始まりの通し番号、
  `pub type alias Mark = { cut = Int32, frame = Int32 }`
- 演じ切った結果。frames = コマの列（先頭 = 始まりの姿）、
  `pub type alias Played[w] = { frames = List[w], marks = List[Mark], notes = List[String] }`
- カットの列から進行状態を作る（1 番から演じ始める）。
  `pub def start(cuts: List[c]): State[c, p]`
- シーンがもう終わっているか。
  `pub def done(s: State[c, p]): Bool`
- シーンを 1 コマ演じる。カットが尽きていれば idle で時間だけを流す。
  `pub def tick(perform: (c, Option[p], Float64, w) -> (Status[p], w), idle: (Float64, w) -> w, dt: Float64, s: State[c, p], w: w): (State[c, p], w)`
- シーンを最初から最後まで演じ、コマの列と報せを返す。
  `pub def play(perform: (c, Option[p], Float64, w) -> (Status[p], w), idle: (Float64, w) -> w, maxFrames: Int32, dt: Float64, cuts: List[c], w0: w): Played[w]`
- 演じ切った終わりの姿だけ（テストの検査用）。
  `pub def finalWorld(perform: (c, Option[p], Float64, w) -> (Status[p], w), idle: (Float64, w) -> w, maxFrames: Int32, dt: Float64, cuts: List[c], w0: w): w`

## Schema — `engine_world/src/Schema.flix`
- フィールドの値の形。JSON では文字列タグ("int" 等)か object 形({"ref": ...} 等)で書く。
  `pub enum FieldType { case TextT case IntT case FloatT case BoolT case ColorT case Vec2T case TextureT case EnumT(List[String]) case RefT(String) case ListT(FieldType) case RecordT(Map[String, Field]) case CustomT(String) }`
- フィールド 1 個の宣言。
  `pub type alias Field = { fieldType = FieldType, label = Option[String], order = Option[Int32], widget = Option[Json], required = Bool, default = Option[Json], min = Option[Float64], max = Option[Float64], step = Option[Float64] }`
- セクションの入れ物の形。catalog = id → レコードの辞書 / list = レコードの配列 /
  `pub enum SectionKind with Eq, ToString { case Catalog case RecordList case Record }`
- セクション 1 個の宣言。kind = 入れ物の形 / fields = フィールド名 → フィールド宣言。
  `pub type alias Section = { kind = SectionKind, fields = Map[String, Field] }`
- スキーマ全体。version = 方言のバージョン(既定 1) / sections = セクション名 → セクション宣言。
  `pub type alias Schema = { version = Int32, sections = Map[String, Section] }`
- スキーマ JSON を読み取る。形が仕様に合わないときは、どのセクション・どのフィールドで
  `pub def fromJson(json: Json): Result[String, Schema]`
- path のスキーマファイルを読んで Schema にする。読めない・崩れている・形が違う、の
  `pub def load(path: String): Result[String, Schema] \ Fs.FileRead`
- ゲームコードが期待するフィールド名集合と、スキーマのセクションを突き合わせる
  `pub def checkSection(sectionKey: String, expected: Set[String], schema: Schema): Result[String, Unit]`
- Schema を JSON に戻す。fromJson と round-trip する(widget / default は原文どおり)。
  `pub def toJson(schema: Schema): Json`
- FieldType を JSON 表現に戻す。fromJson が受け取る形とちょうど対になる。
  `pub def typeToJson(fieldType: FieldType): Json`

## Shadow — `engine_world/src/Shadow.flix`
- 遮蔽物 1 個ぶんの頂点列（絶対座標・閉じたポリゴンとして扱う）に対して光が落とす
  `pub def shadowQuads(lightAt: Vec2.Vec2, occluder: List[Vec2.Vec2], extrudeLength: Float64): List[List[Vec2.Vec2]]`
- occluder の各辺のうち光に正対する辺（前面＝光向きの面）に沿って、幅 rimWidth の
  `pub def rimQuads(lightAt: Vec2.Vec2, occluder: List[Vec2.Vec2], rimWidth: Float64, radius: Float64, allShadowQuads: List[List[Vec2.Vec2]]): List[(List[Vec2.Vec2], Float64)]`
- 影を無限遠まで伸ばしたとみなせる目安の長さ（design解像度が数百px程度のゲーム向け）。
  `pub def infiniteExtrude(): Float64`
- 円をN角形近似した頂点列（絶対座標）。segments が大きいほど滑らかだが影四角形も増える。
  `pub def occluderOfCircle(center: Vec2.Vec2, radius: Float64, segments: Int32): List[Vec2.Vec2]`
- 矩形の4頂点（絶対座標・中心+幅高さ）。左上→右上→右下→左下の順（画面上で時計回り）。
  `pub def occluderOfBox(center: Vec2.Vec2, size: Vec2.Vec2): List[Vec2.Vec2]`
- Hit.HitShape の宣言（持ち主位置からのオフセット）から遮蔽ポリゴンを作る。
  `pub def occluderOf(pos: Vec2.Vec2, shape: Hit.HitShape): List[Vec2.Vec2]`
- itemsFor の設定。darkness は影の濃さ0..1（1で完全な黒）、z は影のzIndex、
  `pub type alias ShadowConfig = { darkness = Float64, z = Int32, extrudeLength = Float64, rimWidth = Float64, rimStrength = Float64 }`
- rimWidth の既定の目安（design px）。壁の輪郭からはみ出さない程度の細さ。
  `pub def defaultRimWidth(): Float64`
- rimStrength の既定の目安（Add の alpha）。フチが白飛びしない程度の強さ。
  `pub def defaultRimStrength(): Float64`
- occluders それぞれについて、(1) 遮蔽物自身の胴体を光と同じ darkness・z の Multiply 黒 Poly、
  `pub def itemsFor(light: Light.Light, occluders: List[List[Vec2.Vec2]], cfg: ShadowConfig): List[Render.PlacedItem]`
- 点 p が凸四角形 quad（4頂点・向きは時計回り/反時計回りのどちらでもよい）の内側にあるか。
  `pub def containsPoint(quad: List[Vec2.Vec2], p: Vec2.Vec2): Bool`

## Steering — `engine_world/src/Steering.flix`
- target から流した距離場を 1 歩下る = target へ最短で近づく隣のマス。
  `pub def chase(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32), target: (Int32, Int32), limit: Int32): Option[(Int32, Int32)]`
- threat から遠ざかる 1 歩。距離場でいまより遠くなる隣のうち、一番遠いものを選ぶ。
  `pub def flee(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32), threat: (Int32, Int32), limit: Int32): Option[(Int32, Int32)]`
- 気の向くままの 1 歩。何歩目か（beat）と塩（salt）のハッシュで向きを引くので、
  `pub def wander(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32), beat: Int32, salt: Int32): Option[(Int32, Int32)]`

## Sway — `engine_world/src/Sway.flix`
- 基本の揺れ。sin(time*freq + phase*2π)、範囲 -1..1。phase(0..1)で個体ごとに位相をずらす。
  `pub def wave(time: Float64, phase: Float64, freq: Float64): Float64`
- 円を描くように漂う 2D オフセット(浮かぶ蓮の葉など)。amp = 振幅(x,y)。
  `pub def drift(time: Float64, phase: Float64, amp: Vec2.Vec2): Vec2.Vec2`

## Terrain — `engine_world/src/Terrain.flix`
- 表の1行(Surfaces.Entry の一般形)。spec = Material.Spec なので、
  `pub type alias Entry = { flagsAt = ((Int32, Int32)) -> DualGrid.Corner, cells = Set[(Int32, Int32)], spec = Material.Spec, z = { fill = Int32, stroke = Int32, surface = Int32 } }`
- rows から「この種のセル」の座標集合を拾う。
  `pub def cellsOf(isKind: Char -> Bool, rows: List[String]): Set[(Int32, Int32)]`
- 角 (i, j) のまわり4セル(左上・右上・左下・右下)の埋まり方。
  `pub def flagsOf(cells: Set[(Int32, Int32)]): ((Int32, Int32)) -> DualGrid.Corner`
- デュアル格子の全角。セル格子 cols×rowCount に対し角は (cols+1)×(rowCount+1)、
  `pub def cornersOf(cols: Int32, rowCount: Int32): List[(Int32, Int32)]`
- 表の全エントリ×渡された角の、静止した見た目。
  `pub def staticItems(opts: { tileSize = Float64, styleMix = DualGrid.StyleMix }, table: List[Entry], corners: List[(Int32, Int32)]): List[Render.PlacedItem]`
- 表面の時間演出(水のきらめきなど)。静止した見た目と違い毎フレーム呼ぶ —
  `pub def surfaceItems(tileSize: Float64, table: List[Entry], time: Float64): List[Render.PlacedItem]`
- 面シェーダー等を地形の形どおりに抜くためのマスク多角形(ワールド座標)。
  `pub def maskPolys(tileSize: Float64, flagsAt: ((Int32, Int32)) -> DualGrid.Corner, corners: List[(Int32, Int32)]): List[List[Vec2.Vec2]]`
- 教科書用の1発 API: Doc 由来の表 + rows → 置き場所つき描画(origin で盤ずらし)。
  `pub def fromRows(opts: { tileSize = Float64, origin = Vec2.Vec2, styleMix = DualGrid.StyleMix }, table: List[{ char = Char, spec = Material.Spec, z = { fill = Int32, stroke = Int32, surface = Int32 } }], rows: List[String]): List[Render.PlacedItem]`

## TerrainDoc — `engine_world/src/TerrainDoc.flix`
- 縁の色の決め方(Material.EdgeKind の色を文字列参照にした Doc 形)。
  `pub enum EdgeRef { case Uniform(String) case ByNormal({ top = String, side = String, shade = String }) }`
- 表の1行の宣言。char = rows の文字、name = パレットに出る名前(Studio の1ボタン)、
  `pub type alias EntryDoc = { char = Char, name = String, fill = String, edge = EdgeRef, edgeWidth = Float64, style = String, jitter = Float64, surface = List[{ preset = String, color = String }], mottle = Float64, height = Option[{ lift = Float64, front = String, shade = String, clipToFloor = Bool }] }`
- 表全体。styleMix = 角の形(丸/四角)の混ぜ具合、entries = セル文字→質感の表
  `pub type alias Doc = { version = Int32, styleMix = DualGrid.StyleMix, entries = List[EntryDoc] }`
- コード側の既定値。石垣('#')と畑(',')の2行 — Doc が読めなくても地形は描ける。
  `pub def defaults(): Doc`
- テキストから Doc へ(fail-open)。entries の char 重複は先勝ちでまとめ(Studio 契約)、
  `pub def fromJson(text: String): Option[Doc]`
- path の Doc を読む。読めない・壊れているときは defaults(fail-open)。
  `pub def load(p: String): Doc \ Fs.FileRead`
- EntryDoc(文字列の色)→ Material.Spec(実色)。resolve は呼び側供給
  `pub def specOf(resolve: String -> Color, e: EntryDoc): Material.Spec`
- Studio パレット供給口: entries の {char, name} だけを並べる(1エントリ=1ボタン)。
  `pub def palette(doc: Doc): List[{ char = Char, name = String }]`

## TextDraw — `engine_world/src/TextDraw.flix`
- `centered` の引数一式。並べると順序を誤りやすい値を名前で束ねるための入れ物
  `pub type alias Centered = { text = String, atlas = FontAtlas, size = Float64, color = Color, z = Int32, centerX = Float64, y = Float64 }`
- 与えた atlas 上で `text` を `size` で描いたときの横幅（ピクセル）。プロポーショナル
  `pub def width(text: String, atlas: FontAtlas, size: Float64): Float64`
- 与えた atlas 上で `text` を `size` で描いたときの幅と高さ（ピクセル、Vec2）。
  `pub def size(text: String, atlas: FontAtlas, size: Float64): Vec2.Vec2`
- `text` を `centerX` に水平中央で揃えたときの左端 x。中央寄せは「幅の半分だけ左へ
  `pub def centerLeft(text: String, atlas: FontAtlas, size: Float64, centerX: Float64): Float64`
- 一行が `centerX` に水平中央で揃い、上端が `y` になるよう配置したテキスト描画
  `pub def centered(a: Centered): Render.PlacedItem`
- `centeredAt` の引数一式。`Centered` の centerX/y の代わりに、縦横とも
  `pub type alias CenteredAt = { text = String, atlas = FontAtlas, size = Float64, color = Color, z = Int32, center = Vec2.Vec2 }`
- 一行を点 `center` のまわりのど真ん中に置いたテキスト描画アイテム。画面中央の
  `pub def centeredAt(a: CenteredAt): Render.PlacedItem`
- リロード失敗などのエラー文を画面左上に赤字で出す（None なら何も出さない）。
  `pub def errorBanner(atlas: FontAtlas, error: Option[String]): List[Render.PlacedItem]`

## TileScene — `engine_world/src/TileScene.flix`
- Spec を regionRect 付き Sprite の PlacedItem 列に写す（world 座標のまま）。
  `pub def toItems(spec: TileLayerSpec): List[Render.PlacedItem]`

## TileState — `engine_world/src/TileState.flix`
- マス → 値 の表。値の型はゲームが決める（畑なら「耕した・濡れ・作物・日数」の record）。
  `pub type alias Table[v] = Map[(Int32, Int32), v]`
- 何も無い表。
  `pub def empty(): Table[v]`
- そのマスの値。無ければ None。
  `pub def get(cell: Grid.Cell, table: Table[v]): Option[v]`
- そのマスに値があるか。
  `pub def has(cell: Grid.Cell, table: Table[v]): Bool`
- そのマスに値を置く（すでにあれば置き換える）。
  `pub def put(cell: Grid.Cell, value: v, table: Table[v]): Table[v]`
- そのマスの値を消す。
  `pub def remove(cell: Grid.Cell, table: Table[v]): Table[v]`
- そのマスの値を作り替える。None を返せば消える、Some を返せば置き換わる。
  `pub def update(cell: Grid.Cell, f: Option[v] -> Option[v] \ ef, table: Table[v]): Table[v] \ ef`
- 値のあるマスの数。
  `pub def size(table: Table[v]): Int32`
- 値のあるマスの列。
  `pub def cells(table: Table[v]): List[Grid.Cell]`
- (マス, 値) の列。描画やセーブで全部をなめるときの入口。
  `pub def entries(table: Table[v]): List[(Grid.Cell, v)]`
- すべての値を一度に作り替える（日が変わったときの一斉更新）。
  `pub def mapValues(f: v -> v \ ef, table: Table[v]): Table[v] \ ef`
- マスの位置も見ながら一度に作り替える（季節や地形で結果が変わるとき）。
  `pub def mapAt(f: (Grid.Cell, v) -> v \ ef, table: Table[v]): Table[v] \ ef`
- 残す値だけを選ぶ（枯れた物を片付ける）。
  `pub def filterValues(pred: v -> Bool \ ef, table: Table[v]): Table[v] \ ef`
- 条件に合うマスの数を数える（水をやった数・実った数）。
  `pub def countValues(pred: v -> Bool, table: Table[v]): Int32`
- 表を JSON の並びにする。encode = 値 1 個を JSON にする関数。
  `pub def toJson(encode: v -> Util.Json.Json, table: Table[v]): Util.Json.Json`
- JSON の並びを表に戻す。decode = JSON 1 個を値にする関数（読めなければ None）。
  `pub def fromJson(decode: Util.Json.Json -> Option[v], element: Util.Json.Json): Table[v]`

## Timeline — `engine_world/src/Timeline.flix`
- 区間: 名前と長さ(秒)。列の順に頭から消化される(純データ)。
  `pub type alias Seg = { name = String, dur = Float64 }`
- `pub def seg(name: String, dur: Float64): Seg`
- 合計の尺(秒)。t がこれ以上なら at は None(終わり)。
  `pub def total(segs: List[Seg]): Float64`
- t 秒時点の区間。u は区間の頭からの経過秒(0 <= u < dur)。
  `pub def at(segs: List[Seg], t: Float64): Option[{ name = String, u = Float64 }]`

## Transition — `engine_world/src/Transition.flix`
- `pub enum Kind with Eq { case FadeOut, case FadeIn, case WipeLeft, case WipeRight }`
- itemsAt へ渡す指定ひとそろい（引数が多いので名前渡しで取り違えを防ぐ）。
  `pub type alias Cover = { kind = Kind, t = Float64, viewport = Vec2.Vec2, color = Color, z = Int32 }`
- 覆いの既定 zIndex。UI（layer × CanvasLayer.layerStride = 10000 台）より手前、
  `pub def defaultZ(): Int32`
- 進行度と種類から、画面を覆う描画物の列を返す。
  `pub def itemsAt(cover: Cover): List[Render.PlacedItem]`
- 遷移の進み具合。所要時間 duration に対して経過秒 elapsed がどれだけ進んだかだけを持つ。
  `pub type alias Progress = { elapsed = Float64, duration = Float64 }`
- 経過 0 から始める。duration が 0 以下だと即座に t=1 になる（一瞬で終わる遷移として扱う）。
  `pub def start(duration: Float64): Progress`
- dt を経過に足す（duration を超えても elapsed は伸び続けない。上限で止める）。
  `pub def advance(dt: Float64, progress: Progress): Progress`
- 現在の進行度 t（[0,1]）。duration が 0 以下なら常に 1.0。
  `pub def tOf(progress: Progress): Float64`
- 遷移が終わっているか（t が 1.0 に達した）。
  `pub def done(progress: Progress): Bool`

## UiBinding — `engine_world/src/UiBinding.flix`
- bindings store を走査し、resolve が Some を返した entity の text を差し替える。
  `pub def apply(resolve: String -> Option[String], ui: UiStore.UiWorld): UiStore.UiWorld`

## UiDialog — `engine_world/src/UiDialog.flix`
- 会話 1 行。speaker = 話者名（空文字なら地の文）、body = 本文のスパン列。
  `pub type alias Line = { speaker = String, body = List[RichText.Span] }`
- 会話の進行状態。lines = 残りの行（先頭が表示中）、reveal = 表示中の行の文字送り。
  `pub type alias Dialog = { lines = List[Line], reveal = UiTypewriter.Reveal }`
- 会話ダイアログの投影先の名前パス束。root = ダイアログ全体（開閉で可視切替）、speaker = 話者の text ノード。
  `pub type alias Paths = { root = String, speaker = String }`
- 閉じた会話ダイアログ。
  `pub def closed(): Dialog`
- 行の列で会話を開く。先頭行の文字送りが 0 文字から始まる。空リストなら閉じたまま。
  `pub def openWith(lines: List[Line]): Dialog`
- ダイアログが開いているか。開いている間はゲーム側で移動などの入力を止める判定に使う。
  `pub def isOpen(dialog: Dialog): Bool`
- 表示中の行（閉じていれば None）。
  `pub def currentLine(dialog: Dialog): Option[Line]`
- 表示中の行の文字送りが終わっているか（閉じていれば true）。
  `pub def lineDone(dialog: Dialog): Bool`
- いま見えている本文（文字送りの途中まで）。視点側が RichText.place で描く。
  `pub def visibleBody(dialog: Dialog): List[RichText.Span]`
- 毎フレーム呼ぶ: 表示中の行の文字送りを進める。閉じていれば何もしない。
  `pub def step(cps: {cps = Float64}, dt: Float64, dialog: Dialog): Dialog`
- 決定キー 1 回分の送り: 文字送り中なら全文へ飛ばし、見え終わっていれば次の行へ、
  `pub def advance(dialog: Dialog): Dialog`
- 会話ダイアログの枠を UiStore へ刻む: 開いていれば root を可視にして話者を流し込み、
  `pub def apply(paths: Paths, dialog: Dialog, ui: UiStore.UiWorld): UiStore.UiWorld`

## UiDoc — `engine_world/src/UiDoc.flix`
- `note`: エディタで表示するノートコメント（描画には影響しない）。
  `pub enum Spec { case Spec({ name = String, widget = Widget, style = UiLayout.Style, visible = Bool, binding = Option[String], meta = Option[String], hover = Option[UiWidget.HoverStyle], note = Option[String], origin = Option[String], layer = Int32, children = List[Spec] }) }`
- `pub enum Widget { case NoneW case BoxW(BoxSpec) case TextW(TextSpec) case SpriteW(UiWidget.SpriteComp) case PolyW(PolySpec) case ShapeW(ShapeSpec) }`
- poly widget（UiWidget.PolyComp の宣言形 + rotation/pivot 拡張）。
  `pub type alias PolySpec = { points = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32, rotation = Float64, pivot = Option[Vec2.Vec2] }`
- box widget（UiWidget.BoxComp + 傾き）。rotation は回転数（1 周 = 1.0）。
  `pub type alias BoxSpec = { box = UiWidget.BoxComp, rotation = Float64, pivot = Option[Vec2.Vec2] }`
- text widget（UiWidget.TextComp + 傾き）。軸の決め方は BoxSpec と同じ。
  `pub type alias TextSpec = { text = UiWidget.TextComp, rotation = Float64, pivot = Option[Vec2.Vec2] }`
- 図形 widget（UiShape.ShapeComp + 傾き）。軸の決め方は BoxSpec と同じ。
  `pub type alias ShapeSpec = { shape = UiShape.ShapeComp, rotation = Float64, pivot = Option[Vec2.Vec2] }`
- `pub def nameOf(spec: Spec): String`
- ドキュメント（version + templates + root）を Spec へ読み取る。instance を含むときは load を使う。
  `pub def parse(json: Json): Result[JsonError, Spec]`
- parse と同じ。加えて resolver（パス → JSON）で instance 参照を解決できる。
  `pub def parseWith(resolver: Map[String, Json], json: Json): Result[JsonError, Spec]`
- 色 1 値のパース（"#rrggbb" / {"hsv":[h,s,v]} / {"rgb":[r,g,b]} / "@パレット名"）。
  `pub def colorOf(palette: Map[String, Color], key: String, json: Json): Result[JsonError, Color]`
- Spec を Flex 木へ。atlasOf はフォント名 → FontAtlas（text の実寸計測と描画に使う）。
  `pub def build(atlasOf: String -> FontAtlas, spec: Spec): Flex.Node`
- build と同じ。加えて textureInfoOf（テクスチャ名 → 寸法）で sprite の frame 格子も解決できる。
  `pub def buildWith(atlasOf: String -> FontAtlas, textureInfoOf: String -> Option[GameEngine.TextureInfo], spec: Spec): Flex.Node`
- 近道: build して place まで。
  `pub def render(atlasOf: String -> FontAtlas, spec: Spec, rootRect: Rect2.Rect2): List[Render.PlacedItem]`
- 敷いた結果の「名前の道（親/子/孫）→ 画面上の矩形」。当たり判定やツールチップの位置を、
  `pub def rectsOf(atlasOf: String -> FontAtlas, spec: Spec, rootRect: Rect2.Rect2): Map[String, Rect2.Rect2]`
- 描画物と名前つき矩形を 1 回のレイアウトで両方返す（毎フレーム 2 度敷かない近道）。
  `pub def renderWithRects(atlasOf: String -> FontAtlas, spec: Spec, rootRect: Rect2.Rect2): (List[Render.PlacedItem], Map[String, Rect2.Rect2])`
- render と同じ。sprite を含むドキュメントはこちら（buildWith して place まで）。
  `pub def renderWith(atlasOf: String -> FontAtlas, textureInfoOf: String -> Option[GameEngine.TextureInfo], spec: Spec, rootRect: Rect2.Rect2): List[Render.PlacedItem]`
- path とそこから instance 参照される全ドキュメントを読み、合成して Spec にする。
  `pub def load(path: String): Result[JsonError, Spec] \ Fs.FileRead`
- メモリ上のドキュメントを、instance / paletteFile の参照ファイルだけ baseDir 起点で読んで
  `pub def parseAt(baseDir: String, json: Json): Result[JsonError, Spec] \ Fs.FileRead`
- 起動時ロード用の近道。失敗はドキュメントの書き損じなので即死してエラーを見せる。
  `pub def loadOrBug(path: String): Spec \ Fs.FileRead`

## UiExtract — `engine_world/src/UiExtract.flix`
- text コンポーネントの内在サイズ（measure）を求める。
  `pub def measureTexts(texts: Map[EntityId, UiWidget.TextComp], atlasOf: String -> FontAtlas \ ef): Map[EntityId, Vec2.Vec2] \ ef`
- 内在サイズの計測に効かせられる折り返しは数値（px）だけ。auto は「自分の矩形の幅」で、
  `pub def intrinsicWrapOf(comp: UiWidget.TextComp): Option[Float64]`
- UI entity を PlacedItem（置き場所つきの描画物）列へ射影する。可視 entity のみ・矩形が確定したもののみ。
  `pub def extract(ui: UiStore.UiWorld, rects: Map[EntityId, Rect2.Rect2], vis: Map[EntityId, Bool], atlasOf: String -> FontAtlas \ ef, textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): List[Render.PlacedItem] \ ef`
- poly entity を (id, rect 左上, ワールド座標へ移した PolyComp) 列へ射影する。可視かつ rect 確定のみ。
  `pub def extractPolys(ui: UiStore.UiWorld, rects: Map[EntityId, Rect2.Rect2], vis: Map[EntityId, Bool]): List[(EntityId, Vec2.Vec2, UiWidget.PolyComp)]`
- shape entity を PlacedItem 列へ射影する。可視かつ rect 確定のみ。
  `pub def extractShapes(ui: UiStore.UiWorld, rects: Map[EntityId, Rect2.Rect2], vis: Map[EntityId, Bool]): List[Render.PlacedItem]`
- box の Item。BoxComp の枠・角丸を BoxStyle へ写す（stripe 系は UI では未使用）。
  `pub def boxItem(box: UiWidget.BoxComp, size: Vec2.Vec2): Render.Item`
- box の PlacedItem 列（`at` は箱の左上からのずれ — 置き場所は呼び手が足す）。
  `pub def boxPlacedItems(box: UiWidget.BoxComp, size: Vec2.Vec2, textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): List[Render.PlacedItem] \ ef`
- text の Item。atlasOf で font 名から FontAtlas を引き、wrap 宣言を実際の折り返し幅へ
  `pub def textItem(comp: UiWidget.TextComp, rectSize: Vec2.Vec2, atlasOf: String -> FontAtlas \ ef): Render.Item \ ef`
- wrap 宣言 → 実際の折り返し幅（px）。auto は自分のレイアウト矩形の幅を使う。
  `pub def resolvedWrapOf(comp: UiWidget.TextComp, rectWidth: Float64): Option[Float64]`
- fit 適用後の fontSize。折った後の縦が rectHeight に収まるまで step 刻みで下げ、
  `pub def fittedFontSize(comp: UiWidget.TextComp, atlas: FontAtlas, wrapW: Option[Float64], rectHeight: Float64): Float64`
- sprite の Item。左上原点（centered=false）でレイアウト矩形の位置に合わせる。
  `pub def spriteItem(sprite: UiWidget.SpriteComp, textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef): Render.Item \ ef`

## UiFocus — `engine_world/src/UiFocus.flix`
- `hitTest` が当たり判定に使う対象シーンの記述。
  `pub type alias HitTestScene = { rects = Map[EntityId, Rect2.Rect2], vis = Map[EntityId, Bool], zOf = EntityId -> Int32, depthOf = EntityId -> Int32 }`
- point を含む可視 entity のうち最前面のものを返す。
  `pub def hitTest(scene: HitTestScene, point: Vec2.Vec2): Option[EntityId]`
- UiWorld 全体を design 空間でレイアウトして最前面ヒットを引く（マウスの hover / click の入口）。
  `pub def hitTestUi(ui: UiStore.UiWorld, design: Vec2.Vec2, point: Vec2.Vec2): Option[EntityId]`
- UiWorld 全体を design 空間でレイアウトした、面積のある entity の画面矩形
  `pub def layoutRects(ui: UiStore.UiWorld, design: Vec2.Vec2): Map[EntityId, Rect2.Rect2]`

## UiFocusNav — `engine_world/src/UiFocusNav.flix`
- 選べる物 1 つ。key = 名前（ゲームが決める。"card:2" のような文字列でも enum でもよい）、
  `pub type alias Target[k] = { key = k, rect = Rect2.Rect2 }`
- いまのフォーカス。key = 乗っている物（無ければ None）、byKey = キーで動かしたか
  `pub type alias Focus[k] = { key = Option[k], byKey = Bool }`
- 1 フレームの入力。step = 矢印の向き（(-1|0|1, -1|0|1)。y は下が正）、
  `pub type alias Input = { pointer = Vec2.Vec2, pointerMoved = Bool, step = (Int32, Int32), tab = Int32 }`
- 何にも乗っていないフォーカス。
  `pub def empty(): Focus[k]`
- キーで置いたフォーカス（ゲーム側のカーソルが指している物を写すとき）。
  `pub def focusByKey(key: k): Focus[k]`
- マウスで乗ったフォーカス。
  `pub def focusByPointer(key: k): Focus[k]`
- 何も押していない入力（マウスは動いていない）。ここからレコード更新で 1 つだけ足して使う。
  `pub def noInput(): Input`
- 入力を当てて次のフォーカスを返す。最後に触った入力が勝つ:
  `pub def update(input: Input, targets: List[Target[k]], focus: Focus[k]): Focus[k] with Eq[k]`
- 点の下にある物の名前（列の前にある物ほど先に当たる）。
  `pub def hitTest(point: Vec2.Vec2, targets: List[Target[k]]): Option[k]`
- フォーカスしている物の枠（乗っていない・列に無いなら None）。
  `pub def rectOf(focus: Focus[k], targets: List[Target[k]]): Option[Rect2.Rect2] with Eq[k]`
- キーで動かしたフォーカスか（カーソルの枠を出すかの判定。マウスで乗った物には枠を出さない）。
  `pub def isFocusVisible(focus: Focus[k]): Bool`
- UiDoc / UiStore で組んだメニュー（listPath の項目列 = UiMenu.itemIds）を Target の列にする。
  `pub def targetsOfUi(listPath: String, ui: UiStore.UiWorld, design: Vec2.Vec2): List[Target[String]]`

## UiHierarchy — `engine_world/src/UiHierarchy.flix`
- parent を親に持つ entity を order 昇順で返す。
  `pub def childrenOf(parent: EntityId, parents: Map[EntityId, EntityId], order: Map[EntityId, Int32]): List[EntityId]`
- entity の階層深さ（root=0）。parents をたどった回数。
  `pub def depthOf(id: EntityId, parents: Map[EntityId, EntityId]): Int32`
- root とその全子孫を集めた集合（root 自身を含む）。
  `pub def descendants(root: EntityId, parents: Map[EntityId, EntityId]): Set[EntityId]`
- 親を隠すと子も隠れる、を反映した各要素の実際の表示可否。
  `pub def resolveInherited(visible: Map[EntityId, Bool], parents: Map[EntityId, EntityId], root: EntityId, order: Map[EntityId, Int32]): Map[EntityId, Bool]`

## UiLayout — `engine_world/src/UiLayout.flix`
- 主軸方向。Row=横並び（主軸=X）、Column=縦並び（主軸=Y）。
  `pub enum Dir with Eq { case Row, case Column }`
- 主軸方向の余白配分。
  `pub enum MainAlign with Eq { case Start, case Center, case End, case SpaceBetween }`
- 交差軸方向の子の寄せ方。Stretch は子を親の交差サイズいっぱいに広げる。
  `pub enum CrossAlign with Eq { case Start, case Center, case End, case Stretch }`
- 軸ごとのサイズ指定。
  `pub enum SizeSpec with Eq { case Auto case Px(Float64) case Grow(Float64) }`
- ノードのレイアウト属性。
  `pub type alias Style = { dir = Dir, gap = Float64, padLeft = Float64, padTop = Float64, padRight = Float64, padBottom = Float64, width = SizeSpec, height = SizeSpec, mainAlign = MainAlign, crossAlign = CrossAlign, wrap = Bool, abs = Option[Vec2.Vec2] }`
- 既定スタイル。縦並び・gap0・pad0・Auto×Auto・Start/Start・折り返しなし・フロー内。
  `pub def defaultStyle(): Style`
- レイアウト解決アルゴリズム全体が引き回す入力の束。パス1・パス2の内部ヘルパーが
  `pub type alias LayoutInput = { styles = Map[EntityId, Style], parents = Map[EntityId, EntityId], order = Map[EntityId, Int32], measures = Map[EntityId, Vec2.Vec2], visible = Map[EntityId, Bool] }`
- レイアウトを解決し、各 entity の画面絶対矩形を返す。
  `pub def computeLayout(input: LayoutInput, root: EntityId, rootRect: Rect2.Rect2): Map[EntityId, Rect2.Rect2]`

## UiMenu — `engine_world/src/UiMenu.flix`
- listPath 配下の「meta を持つ子」を order 順に列挙する（選択カーソルの項目列）。
  `pub def itemIds(listPath: String, ui: UiStore.UiWorld): List[EntityId]`
- 項目列の meta 文字列を order 順に集める。
  `pub def metas(listPath: String, ui: UiStore.UiWorld): List[String]`
- 項目数（meta を持つ子の数）。
  `pub def count(listPath: String, ui: UiStore.UiWorld): Int32`
- 選択カーソル位置の meta を取り出す（範囲外は None）。
  `pub def metaAtSelection(listPath: String, selection: Int32, ui: UiStore.UiWorld): Option[String]`
- 項目列の各 text tint を index → 色の関数で塗る（選択ハイライト・disabled 淡色などを
  `pub def applyItemTints(listPath: String, tintOf: Int32 -> Color, ui: UiStore.UiWorld): UiStore.UiWorld`
- 項目列の各行の子ノード childName の text を index → 文字列の関数で流し込む
  `pub def applyItemLabels(listPath: String, childName: String, textOf: Int32 -> String, ui: UiStore.UiWorld): UiStore.UiWorld`
- `applyHighlight` の引数束。
  `pub type alias HighlightArgs = { listPath = String, highlightPath = String, sel = Int32, rowPitch = Float64, inset = Float64 }`
- 選択行の塗り箱を選択位置へ動かす。箱は listPath 直下に置いた abs 子（highlightPath）で、
  `pub def applyHighlight(args: HighlightArgs, ui: UiStore.UiWorld): UiStore.UiWorld`
- 塗り箱のフロー外オフセットを決める純関数（UiWorld 非依存）。
  `pub def highlightPlacement(itemCount: Int32, sel: Int32, rowPitch: Float64, inset: Float64): Option[Vec2.Vec2]`
- 選択 index を [0, count) へ収める純関数。項目 0 のときは 0。
  `pub def clampIndex(itemCount: Int32, sel: Int32): Int32`
- 項目数が表示スロット数を超えるメニューで、選択 sel が見える範囲の先頭 offset を決める純関数。
  `pub def scrollOffset(sel: {sel = Int32}, count: {count = Int32}, slots: {slots = Int32}): Int32`
- 選択カーソルを項目数 [0, count) の範囲へ収める（防御クランプ）。項目 0 のときは 0。
  `pub def clampSelection(listPath: String, ui: UiStore.UiWorld): UiStore.UiWorld`
- カーソルを delta ぶん動かす（端で反対側へ回り込む）。count<=0 なら cursor のまま。
  `pub def moveCursor(delta: Int32, count: Int32, cursor: Int32): Int32`
- マウス hit の entity が項目列の何番目か（項目列に無ければ None）。
  `pub def hitIndexIn(listPath: String, hit: Option[EntityId], ui: UiStore.UiWorld): Option[Int32]`
- カーソル位置の項目の名前パス（項目 0 個や範囲外は None）。ホバー強調の行き先に使う。
  `pub def cursorPath(listPath: String, cursor: Int32, ui: UiStore.UiWorld): Option[String]`
- キーボードとマウスの両方で選ぶメニューの共通規約。キーボードのカーソルを基準にし、
  `pub def syncCursor(listPath: String, input: { mouseMoved = Bool, hit = Option[EntityId] }, cursor: Int32, ui: UiStore.UiWorld): { cursor = Int32, hoverPath = Option[String] }`

## UiMeta — `engine_world/src/UiMeta.flix`
- meta が "prefix" + 番号なら Some(番号)。それ以外は None。
  `pub def indexOf(prefix: String, meta: String): Option[Int32]`

## UiRender — `engine_world/src/UiRender.flix`
- 渡された `ui` の全 UI root を描画データへ射影する。box/text/sprite は Drawable、poly は
  `pub def renderUi(ui: UiStore.UiWorld, design: Vec2.Vec2): {drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd]} \ GameEngine.Game`
- `renderUi` の注入版。文字実寸を引く `atlasOf`（font 名→FontAtlas）と、スプライトの
  `pub def renderUiWith(atlasOf: String -> FontAtlas \ ef, textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef, ui: UiStore.UiWorld, design: Vec2.Vec2): {drawables = List[GameEngine.Drawable], polygons = List[GameEngine.PolygonRenderCmd]} \ ef`
- UI 全体を PlacedItem（置き場所つきの描画物）の列のまま返す。ゲーム側の絵（View の PlacedItem 列）と
  `pub def itemsWith(atlasOf: String -> FontAtlas \ ef, textureInfoOf: String -> Option[GameEngine.TextureInfo] \ ef, ui: UiStore.UiWorld, design: Vec2.Vec2): List[Render.PlacedItem] \ ef`

## UiScroll — `engine_world/src/UiScroll.flix`
- 遡れる上限。内容がビューポートに収まるなら 0。
  `pub def maxOffset(size: {content = Int32, viewport = Int32}): Int32`
- delta ぶん遡る(正 = 過去へ、負 = 末尾へ)。両端で止まる。
  `pub def scrollBy(delta: Int32, size: {content = Int32, viewport = Int32}, offset: Int32): Int32`
- いま見えている範囲の先頭(内容先頭からの位置)。List.drop にそのまま渡せる。
  `pub def top(size: {content = Int32, viewport = Int32}, offset: Int32): Int32`
- 画面の上にまだ内容があるか(「▲」のような印の出し分けに)。
  `pub def moreAbove(size: {content = Int32, viewport = Int32}, offset: Int32): Bool`
- 画面の下にまだ内容があるか(「▼」)。内容が縮んで古い offset が上限を超えていても
  `pub def moreBelow(size: {content = Int32, viewport = Int32}, offset: Int32): Bool`
- `pub def maxOffsetPx(size: {contentPx = Float64, viewportPx = Float64}): Float64`
- delta ピクセルぶん遡る(正 = 過去へ)。両端で止まる。NaN は 0 扱い(位置を汚染しない)。
  `pub def scrollByPx(delta: Float64, size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Float64`
- いま見えている範囲の先頭(内容先頭からのピクセル位置)。
  `pub def topPx(size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Float64`
- `pub def moreAbovePx(size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Bool`
- `pub def moreBelowPx(size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Bool`
- 行の高さが一定のリストをピクセル位置で覗くときの描画計画:
  `pub def visibleRows(rowH: Float64, size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): { first = Int32, shift = Float64, count = Int32 }`
- 行の格子に揃えて delta 行ぶん動かす(正 = 過去へ)。ピクセル位置が行の途中でも、
  `pub def stepRow(rowH: Float64, delta: Int32, size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Float64`

## UiShape — `engine_world/src/UiShape.flix`
- パラメトリックな図形。座標を持つもの（line/polyline/bezier/poly 由来の点列）は
  `pub enum Shape { case CircleS({ radius = Float64 }) case NgonS({ n = Int32, radius = Float64 }) case StarS({ points = Int32, outer = Float64, inner = Float64, via = Via }) case EllipseS({ radii = Vec2.Vec2, segments = Int32, via = Via }) case SectorS({ radius = Float64, fromT = Float64, toT = Float64 }) case SegmentS({ radius = Float64, fromT = Float64, toT = Float64 }) case LineS({ a = Vec2.Vec2, b = Vec2.Vec2, lineWidth = Float64 }) case PolylineS({ points = List[Vec2.Vec2], lineWidth = Float64 }) case BezierS({ p0 = Vec2.Vec2, ctrl = Vec2.Vec2, p1 = Vec2.Vec2, steps = Int32, widthFrom = Float64, widthTo = Float64 }) }`
- 同じ絵を出す 2 レイヤの選択（star / ellipse）。RenderVia = Item の近道、
  `pub enum Via with Eq { case RenderVia case BezierVia }`
- 図形 widget の描画コンポーネント。alpha は Render.fade、border は円（Box）にのみ効く。
  `pub type alias ShapeComp = { shape = Shape, color = Color, alpha = Float64, zIndex = Int32, borderWidth = Float64, borderColor = Option[Color] }`
- 図形のパラメータから導く内在サイズ（width/height 未指定時に Px として敷かれる）。
  `pub def intrinsicSize(shape: Shape): Vec2.Vec2`
- 図形を rect の中心に描く。修飾は「fade → outline → 置く」の順（ギャラリーの書き味と同順）。
  `pub def placedItems(s: ShapeComp, r: Rect2.Rect2): List[Render.PlacedItem]`
- alpha < 1 のときだけ Render.fade を掛ける（1.0 は無修飾のまま — 既存の絵を変えない）。
  `pub def fadeIf(alpha: Float64, item: Render.Item): Render.Item`

## UiSlots — `engine_world/src/UiSlots.flix`
- スロット 1 個分の項目。text = 表示文字列（スロットの `label` 子へ）、
  `pub type alias Entry = { text = String, meta = Option[String] }`
- スロットの配置規約。slotPath = i 番目のスロット（行コンテナ）の名前パス、maxSlots = 宣言した数。
  `pub type alias SlotSpec = { slotPath = Int32 -> String, maxSlots = Int32 }`
- items を先頭スロットから順に流し込む。maxSlots を超えた項目は入らない（overflows で検知）。
  `pub def fill(spec: SlotSpec, items: List[Entry], ui: UiStore.UiWorld): UiStore.UiWorld`
- スロットが足りないか。足りないまま fill すると末尾の項目が表示されないので、
  `pub def overflows(spec: SlotSpec, items: List[Entry]): Bool`

## UiSpec — `engine_world/src/UiSpec.flix`
- ノードの描画種別。box=単色矩形、text=テキスト、sprite=スプライト、poly=塗り潰し多角形、
  `pub enum Widget with Eq { case BoxW case TextW case SpriteW case PolyW case ShapeW case NoneW }`
- テンプレート解決済みの UI ノード。ツリーは children で再帰する。
  `pub enum Spec { case Spec({ name = String, widget = Widget, style = UiLayout.Style, box = Option[UiWidget.BoxComp], text = Option[UiWidget.TextComp], sprite = Option[UiWidget.SpriteComp], poly = Option[UiWidget.PolyComp], shape = Option[UiShape.ShapeComp], hover = Option[UiWidget.HoverStyle], visible = Bool, binding = Option[String], meta = Option[String], layer = Int32, children = List[Spec] }) }`
- ui.json を Spec へ読み取る。パースは UiDoc.parse（templates/use・スタイル・全 widget・
  `pub def parse(json: Json): Result[JsonError, Spec]`
- ui.json を読み込んで Spec にする。instance の参照先も UiDoc.load が読み集める。
  `pub def load(path: String): Result[JsonError, Spec] \ Fs.FileRead`
- メモリ上のドキュメントを Spec にする。instance / paletteFile の参照ファイルは baseDir 起点で読む。
  `pub def parseAt(baseDir: String, json: Json): Result[JsonError, Spec] \ Fs.FileRead`
- Spec の全ノードを UiStore へ登録し、root の EntityId と更新後の UiWorld を返す。
  `pub def spawnRoot(spec: Spec, ui: UiStore.UiWorld): (EntityId, UiStore.UiWorld)`
- spec 由来 store を root ごと捨ててから spawnRoot し直す。selection/focus は String キーゆえ生存する。
  `pub def respawn(spec: Spec, ui: UiStore.UiWorld): (EntityId, UiStore.UiWorld)`
- ui.json を読み込んで spawnRoot し、root 名パス→アセットパスを sources レジストリへ登録する。
  `pub def spawnAsset(path: String, ui: UiStore.UiWorld): Result[JsonError, (EntityId, UiStore.UiWorld)] \ Fs.FileRead`
- `spawnAsset` の別名 root 版。同じアセットを複数の root として組みたいとき（味方カードと
  `pub def spawnAssetAs(path: String, rootName: String, ui: UiStore.UiWorld): Result[JsonError, (EntityId, UiStore.UiWorld)] \ Fs.FileRead`
- sources レジストリの全 root を走査し、各アセットを読み直して respawn する（F1 ホットリロード）。
  `pub def reloadAll(ui: UiStore.UiWorld): UiStore.UiWorld \ Fs.FileRead`
- reloadAll と同じリロードに加えて、失敗した root の (root 名, エラー文言) のリストを返す。
  `pub def reloadAllWithReport(ui: UiStore.UiWorld): (UiStore.UiWorld, List[(String, String)]) \ Fs.FileRead`
- spec を名前列 path で辿った先のノードの直下で、name が prefix で始まる子の数を返す。
  `pub def countPrefixedChildren(path: List[String], prefix: String, spec: Spec): Int32`

## UiStore — `engine_world/src/UiStore.flix`
- UI 全体の状態。
  `pub type alias UiWorld = { nextId = Int32, parents = Map[EntityId, EntityId], order = Map[EntityId, Int32], styles = Map[EntityId, UiLayout.Style], boxes = Map[EntityId, UiWidget.BoxComp], texts = Map[EntityId, UiWidget.TextComp], sprites = Map[EntityId, UiWidget.SpriteComp], polys = Map[EntityId, UiWidget.PolyComp], shapes = Map[EntityId, UiShape.ShapeComp], hovers = Map[EntityId, UiWidget.HoverStyle], visible = Map[EntityId, Bool], bindings = Map[EntityId, String], metas = Map[EntityId, String], names = Map[String, EntityId], selection = Map[String, Int32], focus = Option[String], hovered = Option[String], layers = Map[EntityId, Int32], sources = Map[String, String] }`
- 空の UI 状態。id 採番は 1 から始める。
  `pub def empty(): UiWorld`
- 次の entity id を採番して返す（nextId を進めた新 UiWorld と組で返す）。
  `pub def alloc(ui: UiWorld): (EntityId, UiWorld)`
- 完全名パスから entity を引く。
  `pub def idOf(path: String, ui: UiWorld): Option[EntityId]`
- entity から完全名パスを逆引きする（names を走査）。
  `pub def pathOf(id: EntityId, ui: UiWorld): Option[String]`
- 名前パスの entity に設定された可視（継承前の生値）を読む。未登録パスは None。
  `pub def visibleOf(path: String, ui: UiWorld): Option[Bool]`
- 名前パスの entity の可視を設定する。未登録パスは no-op。
  `pub def setVisible(path: String, v: Bool, ui: UiWorld): UiWorld`
- 名前パスの entity の識別 metadata（メニュー項目の識別子）を設定する。未登録パスは no-op。
  `pub def setMeta(path: String, meta: String, ui: UiWorld): UiWorld`
- 名前パスの entity の metadata を消す（未使用スロットを項目列から外す）。未登録パスは no-op。
  `pub def clearMeta(path: String, ui: UiWorld): UiWorld`
- 名前パスの text コンポーネントの文字列を読む。text を持たなければ None。
  `pub def textOf(path: String, ui: UiWorld): Option[String]`
- 名前パスの text コンポーネントの文字列を差し替える。text を持たなければ no-op。
  `pub def setText(path: String, text: String, ui: UiWorld): UiWorld`
- 名前パスの text コンポーネントの tint（文字色）を差し替える。text を持たなければ no-op。
  `pub def setTextTint(path: String, tint: Color, ui: UiWorld): UiWorld`
- 名前パスの entity の style 幅を固定 px（`SizeSpec.Px`）へ差し替える。style を持たなければ no-op。
  `pub def setWidthPx(path: String, px: Float64, ui: UiWorld): UiWorld`
- 名前パスの entity の style 幅が固定 px（`SizeSpec.Px`）ならその値を返す。
  `pub def widthPxOf(path: String, ui: UiWorld): Option[Float64]`
- 名前パスの box コンポーネントの色を差し替える。box を持たなければ no-op。
  `pub def setBoxColor(path: String, c: Color, ui: UiWorld): UiWorld`
- 名前パスの box コンポーネントの不透明度（fill alpha）を差し替える。box を持たなければ no-op。
  `pub def setBoxAlpha(path: String, alpha: Float64, ui: UiWorld): UiWorld`
- 名前パスの図形コンポーネントの色を差し替える。図形を持たなければ no-op。
  `pub def setShapeColor(path: String, c: Color, ui: UiWorld): UiWorld`
- 名前パスの図形コンポーネントの枠線色を差し替える。図形を持たなければ no-op
  `pub def setShapeBorderColor(path: String, c: Color, ui: UiWorld): UiWorld`
- 名前パスの box コンポーネントの枠線色を差し替える。box を持たなければ no-op。
  `pub def setBoxBorderColor(path: String, c: Color, ui: UiWorld): UiWorld`
- 名前パスの entity のフロー外オフセット（style#abs）を差し替える。style を持たなければ no-op。
  `pub def setAbs(path: String, pos: Vec2.Vec2, ui: UiWorld): UiWorld`
- 名前パスの poly コンポーネントの凸サブポリゴン列を差し替える。poly を持たなければ no-op。
  `pub def setPolyPolys(path: String, polys: List[List[Vec2.Vec2]], ui: UiWorld): UiWorld`
- `setSprite` の引数束。
  `pub type alias SpriteSpec = { path = String, texture = String, hframes = Int32, vframes = Int32, frame = Int32 }`
- 名前パスの sprite コンポーネントの texture と格子分割（hframes/vframes/frame）を差し替える。
  `pub def setSprite(spec: SpriteSpec, ui: UiWorld): UiWorld`
- 名前パスの sprite コンポーネントの拡大率を差し替える。sprite を持たなければ no-op。
  `pub def setSpriteScale(path: String, scale: Vec2.Vec2, ui: UiWorld): UiWorld`
- 名前パスの sprite コンポーネントの着色（tint）を差し替える。sprite を持たなければ no-op。
  `pub def setSpriteTint(path: String, tint: Color, ui: UiWorld): UiWorld`
- 名前パスの entity の style 高さを固定 px（`SizeSpec.Px`）へ差し替える。style を持たなければ no-op。
  `pub def setHeightPx(path: String, px: Float64, ui: UiWorld): UiWorld`
- 名前パスの box コンポーネントの枠線幅を差し替える。box を持たなければ no-op。
  `pub def setBoxBorderWidth(path: String, width: Float64, ui: UiWorld): UiWorld`
- root 名パスに ui.json アセットパスを紐付ける（reloadAll の走査対象になる）。
  `pub def putSource(rootPath: String, assetPath: String, ui: UiWorld): UiWorld`
- root 名パスをレジストリから外す（恒久削除時に呼ぶ。以後 reloadAll の対象外）。
  `pub def forgetSource(rootPath: String, ui: UiWorld): UiWorld`
- root 配下の各ノードの「名前パス→設定可視（継承前の生値）」を集める。
  `pub def visibleByPath(rootPath: String, ui: UiWorld): Map[String, Bool]`
- 「名前パス→可視」を現存ノードへ適用する。存在しないパス（削除済み）は no-op。
  `pub def applyVisibleByPath(byPath: Map[String, Bool], ui: UiWorld): UiWorld`
- rootPath 配下の全 entity を spec 由来 store から除去する。
  `pub def despawnRoot(rootPath: String, ui: UiWorld): UiWorld`
- hover 中の entity の名前パスを設定する（None = どれも hover していない）。
  `pub def setHovered(path: Option[String], ui: UiWorld): UiWorld`
- 親を持たない entity（= 各サブツリーの root）を列挙する。
  `pub def rootsOf(ui: UiWorld): List[EntityId]`
- 名前パスのリスト選択カーソル値。未登録は 0。
  `pub def selectionOf(path: String, ui: UiWorld): Int32`
- 名前パスのリスト選択カーソル値を設定する。
  `pub def putSelection(path: String, i: Int32, ui: UiWorld): UiWorld`
- フォーカス scope を名前パスに設定する（モーダル占有）。
  `pub def focusOn(path: String, ui: UiWorld): UiWorld`
- フォーカス scope を解除する。
  `pub def clearFocus(ui: UiWorld): UiWorld`

## UiTooltip — `engine_world/src/UiTooltip.flix`
- 窓を出す向き（見ている物から見て）。Over は脇ではなく見ている物の上に重ねる
  `pub enum Side with Eq, ToString { case Right case Left case Bottom case Top case Over }`
- 置き場所の注文。anchor = 見ている物の枠（マウスの指なら大きさ 0 の枠）、size = 窓の大きさ、
  `pub type alias Request = { anchor = Rect2.Rect2, size = Vec2.Vec2, bounds = Rect2.Rect2, avoid = List[Rect2.Rect2], gap = Float64, sides = List[Side] }`
- 窓の左上と大きさ（Request の決まりで選んだ 1 か所）。
  `pub def computePlacement(req: Request): Rect2.Rect2`
- 既定の向きの順（右 → 左 → 下 → 上。横書きの画面で、読んでいる物の続きに出る順）。
  `pub def defaultSides(): List[Side]`
- 画面の真ん中から遠ざかる向きを先に試す順（左半分の物は右 → 左、右半分の物は左 → 右。
  `pub def sidesAwayFromCenter(anchor: Rect2.Rect2, bounds: Rect2.Rect2): List[Side]`

## UiTypewriter — `engine_world/src/UiTypewriter.flix`
- 文字送りの進み具合。text = 表示したい全文、shown = 見えている文字数（dt を足し込むため小数で持つ）。
  `pub type alias Reveal = { text = String, shown = Float64 }`
- 0 文字（何も見えていない）から始める。
  `pub def start(text: String): Reveal`
- 最初から全文が見えている状態を作る。
  `pub def done(text: String): Reveal`
- cps（1 秒あたりの文字数。60 が読みやすい目安）× dt だけ進める。全文で止まる。
  `pub def step(cps: {cps = Float64}, dt: Float64, reveal: Reveal): Reveal`
- 全文表示へ飛ばす（決定キーでの早送り）。
  `pub def skip(reveal: Reveal): Reveal`
- 全文が見え終わったか。
  `pub def isDone(reveal: Reveal): Bool`
- いま見えている文字数（整数）。スパン列など文字列以外の見せ方をする側が
  `pub def visibleCount(reveal: Reveal): Int32`
- いま見えている先頭部分の文字列。UiStore.setText へそのまま渡せる。
  `pub def visibleText(reveal: Reveal): String`
- 表示すべき全文が変わったら最初からやり直し、同じなら現状維持（文言切替の検出）。
  `pub def sync(text: String, reveal: Reveal): Reveal`

## UiWidget — `engine_world/src/UiWidget.flix`
- 単色塗り矩形の描画属性。サイズは layout が決める。
  `pub type alias BoxComp = { color = Color, alpha = Float64, zIndex = Int32, cornerRadius = Float64, borderWidth = Float64, borderColor = Color, skin = Option[String], skinCorner = Option[Float64] }`
- テキストの折り返し宣言。
  `pub enum TextWrap with Eq, Order, ToString { case WrapOff case WrapAuto case WrapPx(Float64) }`
- fit（枠に収める縮小）の規則。
  `pub type alias TextFit = { step = Float64, minSize = Float64 }`
- fit の縮小刻みの既定値（ui.schema.json の fitStep の既定と対）。
  `pub def fitStepDefault(): Float64`
- fit の下限 fontSize の既定値（ui.schema.json の fitMin の既定と対）。
  `pub def fitMinDefault(): Float64`
- テキストの描画属性。
  `pub type alias TextComp = { text = String, font = String, fontSize = Float64, tint = Color, zIndex = Int32, wrap = TextWrap, fit = Option[TextFit] }`
- スプライトの描画属性。
  `pub type alias SpriteComp = { texture = String, regionRect = Option[Rect2.Rect2], scale = Vec2.Vec2, flipH = Bool, flipV = Bool, tint = Color, zIndex = Int32, hframes = Int32, vframes = Int32, frame = Int32 }`
- hover 時の部分上書き（宣言 UI の ":hover" 相当）。全フィールド任意 — Some の
  `pub type alias HoverStyle = { color = Option[Color], borderColor = Option[Color], tint = Option[Color], alpha = Option[Float64] }`
- 塗り潰し凸多角形（の集合）の描画属性。サイズは layout が決め、頂点はその矩形内へ置く。
  `pub type alias PolyComp = { polys = List[List[Vec2.Vec2]], color = Color, alpha = Float64, zIndex = Int32 }`
- リスト選択カーソルを delta だけ動かす（端で反対側へ回り込む）。
  `pub def selectionMove(count: Int32, delta: Int32, current: Int32): Int32`
- disabled 項目を飛ばしてカーソルを 1 つ動かす（端で反対側へ回り込む）。
  `pub def selectionMoveSkipping(count: Int32, delta: Int32, current: Int32, disabledAt: Int32 -> Bool): Int32`

## ViewProjection — `engine_world/src/ViewProjection.flix`
- world → screen の写し方。写し方ごとに要る数が違うので case ごとに持ち物を変える
  `pub enum ViewProjection { case SideOf(FlatSpec) case TopDownOf(FlatSpec) case QuarterOf(QuarterSpec) case FirstPersonOf(FirstPersonSpec) }`
- 4 つの写し方の名前。目録の "view" と、world 配列の長さを決める。
  `pub enum Mode with Eq, ToString { case Side case TopDown case Quarter case FirstPerson }`
- world の 1 点。h（高さ）を使うのは Quarter と FirstPerson だけで、
  `pub type alias WorldPos = { x = Float64, y = Float64, h = Float64 }`
- 高さを持たない world の点。
  `pub def worldPos(x: Float64, y: Float64): WorldPos`
- 高さつきの world の点。
  `pub def worldPosAt(x: Float64, y: Float64, h: Float64): WorldPos`
- Side / TopDown の持ち物。CameraRig と同じ形（映す中心 + zoom）で持つので、
  `pub type alias FlatSpec = { design = Vec2.Vec2, center = Vec2.Vec2, zoom = Float64 }`
- Quarter の持ち物。tile = タイル 1 マスの画面上の幅と高さ、
  `pub type alias QuarterSpec =`
- FirstPerson の持ち物。camera / persp / near はすべて呼ぶ側の意見。
  `pub type alias FirstPersonSpec =`
- screen → world の戻し方を持つ写し方だけを抜き出した形（inverseOf で取り出す）。
  `pub enum Inverse { case FlatInverse(FlatSpec) case QuarterInverse(QuarterSpec) }`
- `pub def all(): List[Mode]`
- 目録や Makefile に出す名前。**視点名の文字列はここだけ**。
  `pub def key(m: Mode): String`
- world の h（高さ）が絵に効くか。Quarter は画面の上へ持ち上がり、
  `pub def usesHeight(m: Mode): Bool`
- 横から見た画面。center を画面の中央に zoom 倍（1 world = zoom px）で映す。
  `pub def side(spec: FlatSpec): ViewProjection`
- 真上から見た画面。持ち物も式も side と同じで、違うのは y の意味だけ
  `pub def topDown(spec: FlatSpec): ViewProjection`
- 斜め見下ろし（クォータービュー）。
  `pub def quarter(spec: QuarterSpec): ViewProjection`
- 一人称。**カメラは呼ぶ側が渡す**（既存の Persp.Camera をそのまま受ける）。
  `pub def firstPerson(spec: FirstPersonSpec): ViewProjection`
- `pub def modeOf(vp: ViewProjection): Mode`
- `pub def designOf(vp: ViewProjection): Vec2.Vec2`
- Quarter の持ち物。取り出せたら coveringCells がそのまま呼べる。
  `pub def quarterOf(vp: ViewProjection): Option[QuarterSpec]`
- FirstPerson の持ち物。取り出せたら yawOf / distanceOf / visibleFraction /
  `pub def firstPersonOf(vp: ViewProjection): Option[FirstPersonSpec]`
- screen → world の戻し方。FirstPerson だけ None — 画面の 1 点に当たる world の点が
  `pub def inverseOf(vp: ViewProjection): Option[Inverse]`
- world の点を画面 px へ。FirstPerson でカメラの真横〜後方に来た点は None
  `pub def toScreen(vp: ViewProjection, at: WorldPos): Option[Vec2.Vec2]`
- 画面 px の点が、高さ h の面のどの world 座標に当たるか。
  `pub def toWorld(inv: Inverse, h: Float64, screen: Vec2.Vec2): WorldPos`
- 画面で delta px だけ動かしたいとき、world の座標をいくら動かせばよいか。
  `pub def toWorldDelta(inv: Inverse, delta: Vec2.Vec2): Vec2.Vec2`
- 画面に重なるマスを盤の内側から並べる（Grid.cellsIn の斜め見下ろし版で、
  `pub def coveringCells(q: QuarterSpec, spec: { maxHeight = Float64, cols = Int32, rows = Int32, margin = { left = Int32, top = Int32, right = Int32, bottom = Int32 } }): List[Grid.Cell]`
- カメラの正面から見て何度ずれているか（- が左・+ が右）。
  `pub def yawOf(f: FirstPersonSpec, at: WorldPos): Float64`
- カメラからの距離（マス何個ぶんか）。
  `pub def distanceOf(f: FirstPersonSpec, at: WorldPos): Float64`
- 幅 width（world 単位）の物が、画面の中にどれだけ入っているか 0..1。
  `pub def visibleFraction(f: FirstPersonSpec, at: WorldPos, width: Float64): Float64`
- 壁 1 枚（足元の線分 a→b を strip の高さの帯まで立ち上げた面）の画面上の四隅と、
  `pub def wallQuad(f: FirstPersonSpec, a: Vec2.Vec2, b: Vec2.Vec2, strip: { hTop = Float64, hBot = Float64 }): Option[{ corners = Persp.Corners, dist = Float64, t0 = Float64, t1 = Float64 }]`
- マス目の上を四方位で歩くゲームのための Persp.Camera の作り方。
  `pub def makeCamera(eye: Vec2.Vec2, facing: Dir4.Dir4): Persp.Camera`
- ラジアンを度へ。人が読む向き（yawOf・目録の "facing"）はこの単位でそろえる。
  `pub def toDegrees(radians: Float64): Float64`

## Viewport — `engine_world/src/Viewport.flix`
- 軸平行の矩形領域。画面なら {0, 0, width, height}。
  `pub type alias Bounds = { minX = Float64, minY = Float64, maxX = Float64, maxY = Float64 }`
- 幅・高さから原点基準の bounds を作る。
  `pub def bounds(width: Float64, height: Float64): Bounds`
- 点が bounds の外（各辺から margin 以上はみ出している）か。
  `pub def isOutside(p: Vec2.Vec2, b: Bounds, margin: Float64): Bool`
- position を持つ entity のうち、bounds の外（margin 付き）に出ているものの id 一覧。
  `pub def offscreenEntities(positions: Map[EntityId, Vec2.Vec2], b: Bounds, margin: Float64): List[EntityId]`

## WallFaces — `engine_world/src/WallFaces.flix`
- 面の足元の 2D 線分（a→b）と、外向き法線・属する壁マス。
  `pub type alias Face = { a = Vec2.Vec2, b = Vec2.Vec2, normal = Vec2.Vec2, cell = Grid.Cell }`
- eye の周囲 radius マスを走査し、壁と空きの境界のうち eye に見える面だけを集める。
  `pub def visibleFaces(solidAt: Grid.Cell -> Bool, radius: Int32, eye: Vec2.Vec2): List[Face]`
- 壁マスの dir 側の面（visibleFaces を通さず 1 枚だけ欲しいとき — 壁掛けの
  `pub def faceOf(cell: Grid.Cell, dir: Dir4.Dir4): Face`
- 面に沿った t（0..1。a が 0・b が 1）の世界座標。目地や飾りを
  `pub def pointAt(face: Face, t: Float64): Vec2.Vec2`
- 面の足元の中点（裏面カリングと「面のわずかに手前」の基準点）。
  `pub def centerOf(face: Face): Vec2.Vec2`

## Worldline — `engine_world/src/Worldline.flix`
- `pub enum Worldline[a] { case Worldline({ past = List[a], current = a, future = List[a], cap = Int32 }) }`
- 初期状態 1 点だけの世界線を作る。past/future は空、cap は past の最大保持数。
  `pub def make(initial: a, cap: Int32): Worldline[a]`
- 今の状態（世界線上の現在地）。
  `pub def current(wl: Worldline[a]): a`
- current だけを差し替える（past/future は不動 = 履歴を刻まない補正）。
  `pub def replaceCurrent(a: a, wl: Worldline[a]): Worldline[a]`
- 新しい現在へ進む。今の current を past へ積み（cap で古い端を切り詰め）、future を捨てる。
  `pub def record(a: a, wl: Worldline[a]): Worldline[a]`
- 1 回遡る。past が空なら何もしない（最古で止まる）。手放した current は future へ積む。
  `pub def undo(wl: Worldline[a]): Worldline[a]`
- 1 回下る（やり直し）。future が空なら何もしない。手放した current は past へ戻す。
  `pub def redo(wl: Worldline[a]): Worldline[a]`
- k 回遡る。past が尽きたら最古で止まる（k が履歴長を超えても最古に clamp）。
  `pub def undoBy(k: Int32, wl: Worldline[a]): Worldline[a]`
- k 回下る。future が尽きたら最新で止まる。undoBy の対。
  `pub def redoBy(k: Int32, wl: Worldline[a]): Worldline[a]`
- 遡れるか（past が空でないか）。
  `pub def canUndo(wl: Worldline[a]): Bool`
- 下れるか（future が空でないか）。
  `pub def canRedo(wl: Worldline[a]): Bool`
- 遡れる回数（past の長さ）。
  `pub def pastLength(wl: Worldline[a]): Int32`
- 下れる回数（future の長さ）。
  `pub def futureLength(wl: Worldline[a]): Int32`
- 世界線上の総状態数（past + current + future）。
  `pub def length(wl: Worldline[a]): Int32`
- 世界線を時間順（最古→最新）に平らにした列。GIF・タイムラインデバッガ・スクラブが
  `pub def toList(wl: Worldline[a]): List[a]`
- 時間順に平らにした列の絶対添字区間 [fromIdx, toIdx) を取り出す（GIF・区間解析用）。
  `pub def slice(fromIdx: Int32, toIdx: Int32, wl: Worldline[a]): List[a]`
- 世界線上の絶対位置 n（0 = 最古、pastLength = 現在地、length-1 = 最新）へ移動する。
  `pub def scrubTo(n: Int32, wl: Worldline[a]): Worldline[a]`
