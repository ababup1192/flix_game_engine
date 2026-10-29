<!-- engine v0.71.0 / 生成: 2026-10-29 -->
<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト — engine_world

`engine_world/src` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。索引は [api-digest.md](../api-digest.md)。

## ActiveDocs — `engine_world/src/ActiveDocs.flix`
- 書き出し先。debug/ は .gitignore 済みの作業用置き場。
  `pub def path(): String`
- entries(editor 宣言 id → 表示中パスの列)をエディタが読む形の JSON にする。
  `pub def json(entries: List[(String, List[String])]): String`
- entries の指紋(id とパスを区切り文字で 1 本に綴じた文字列)。App の出力の鍵にして
  `pub def fingerprint(entries: List[(String, List[String])]): String`
- 一覧を debug/active-docs.json に書く（App.withDocTable が、一覧が変わった実機のフレームの後でだけ呼ぶ）。
  `pub def write(entries: List[(String, List[String])]): Unit \ Fs.FileWrite`

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
- 注釈を書き出す瞬間の、ゲーム側の文脈（App.withAnnotationContext で繋ぐ）。
  `pub type alias Context[t, h] = { facts = List[(String, String)], layers = List[t], hudLayers = List[h] }`
- 書き出しが引く形: 層の z の範囲の表 (名前, 底, 天井)（天井は含む）。描画物の z に、最初に
  `pub type alias Table = { facts = List[(String, String)], layers = List[(String, Int32, Int32)], hudLayers = List[(String, Int32, Int32)] }`
- 層の enum の列から書き出しの表を作る。
  `pub def toTable(context: Context[t, h]): Table with SortingLayer[t], ToString[t], SortingLayer[h], ToString[h]`
- 文脈を繋いでいないゲームの既定（README・JSON は従来と同じ形になる）。
  `pub def noContext(): Table`
- z の層の名前（表に無ければ None）。HUD の範囲の z は HUD の表で引く。
  `pub def layerOf(context: Table, z: Int32): Option[String]`
- annotation.json の本文。デザイン座標の矩形と、重なっていた描画物の一覧を機械可読に残す。
  `pub def annotationJson(meta: { frame = Int64, design = Vec2.Vec2, rect = Rect2.Rect2 }, hitList: List[Hit]): String`
- annotationJson に文脈を足した版。hits は字ごとのまま（機械が読む側は束ねない）。
  `pub def annotationJsonWith(context: Table, meta: { frame = Int64, design = Vec2.Vec2, rect = Rect2.Rect2 }, hitList: List[Hit]): String`
- README.md に挟む人間向けの要約（囲った場所と、そこに描かれていた物）。
  `pub def readmeBody(meta: { frame = Int64, rect = Rect2.Rect2 }, hitList: List[Hit]): String`
- readmeBody に文脈を足した版。冒頭に facts を並べ、描画物の z に層の名前を添え、
  `pub def readmeBodyWith(context: Table, meta: { frame = Int64, rect = Rect2.Rect2 }, hitList: List[Hit]): String`
- 同じ行（同じ y・同じ z）に左から右へ続けて置かれた text を 1 件へ束ねる。
  `pub def mergeTextRuns(hitList: List[Hit]): List[Hit]`
- ドラッグ中の矩形オーバーレイ（薄い塗り + 枠線）。デザイン座標の列に混ぜて描く。
  `pub def overlayItems(dragStart: Vec2.Vec2, cursorDesign: Vec2.Vec2): List[Render.PlacedItem]`
- 描く前の絵（PlacedItem）へ見え方（ズーム・パン）を適用する。式は toScreen と同じで、
  `pub def applyInspectItems(view: View, items: List[Render.PlacedItem]): List[Render.PlacedItem]`
- 描画命令の列へ見え方（ズーム・パン）を適用する。位置は toScreen、大きさは zoom 倍。
  `pub def applyInspect(view: View, ds: List[GameEngine.Drawable]): List[GameEngine.Drawable]`
- 多角形の描画命令へ見え方を適用する（頂点は画面 px の絶対座標なので各頂点を写す）。
  `pub def applyInspectPoly(view: View, ps: List[GameEngine.PolygonRenderCmd]): List[GameEngine.PolygonRenderCmd]`
- タイルマップの描画命令へ見え方を適用する（位置は toScreen、タイル倍率は zoom 倍）。
  `pub def applyInspectTiles(view: View, ts: List[GameEngine.TileMapRenderCmd]): List[GameEngine.TileMapRenderCmd]`
- 等倍・ずらし無し（変換しても何も変わらない）か。
  `pub def isIdentity(view: View): Bool`

## App — `engine_world/src/App.flix`
- ゲーム 1 本の宣言。make で作り、addSystem / withView などのビルダーで部品を繋いで launch へ渡す。
  `pub enum App[w: Type, ef: Eff](Rec[w, ef])`
- App の中身。ゲームからは読まない（ビルダーで組む）。エンジンの中の口（Flow・RemoteDebug など）が読む。
  `pub def rec(app: App[w, ef]): Rec[w, ef]`
- このフレームの入力と時計のスナップショット。キーの生読みはランナーが済ませてあるので、
  `pub type alias Frame = { down = Set[GameEngine.Key], justPressed = Set[GameEngine.Key], dt = Float64, viewport = Vec2.Vec2, cursor = Vec2.Vec2, mouseDown = Bool, mouseClicked = Bool, mouseMoved = Bool, wheel = Float64, realNow = Clock.Time[Clock.Real], padTouched = Bool, padKind = GamepadMap.PadKind }`
- key がいま押されているか（押しっぱなしも true）。移動などの連続入力に。
  `pub def isDown(key: GameEngine.Key, frame: Frame): Bool`
- key がこのフレームで新しく押されたか（押しっぱなしは false）。決定・発射などの単発入力に。
  `pub def justPressed(key: GameEngine.Key, frame: Frame): Bool`
- 負方向・正方向のキーの押し下げを -1 / 0 / +1 にまとめる（両押しは打ち消して 0）。
  `pub def axis(negative: {negative = GameEngine.Key}, positive: {positive = GameEngine.Key}, frame: Frame): Float64`
- view / hudView が受け取る「この 1 フレームの見え方」。atlas は文字描画用の既定フォント、
  `pub type alias ViewCtx = { atlas = FontAtlas, fontOf = String -> FontAtlas, visible = Rect2.Rect2, warnOnce = String -> Unit }`
- ヘッドレス描き出しから view を呼ぶときの ViewCtx。画面全体が見えている扱いにする。
  `pub def viewCtxOf(atlas: FontAtlas, design: Vec2.Vec2): ViewCtx`
- viewCtxOf の複数フォント版。fontOf には実機と同じ名前で引ける関数を渡す
  `pub def viewCtxOfFonts(atlas: FontAtlas, fontOf: String -> FontAtlas, design: Vec2.Vec2): ViewCtx`
- 入力の側（update・テスト）で、押せる物の当たりを出すために View の木を組むときの ViewCtx
  `pub def pickCtx(design: Vec2.Vec2): ViewCtx`
- 見た文面を seen に覚え、初めての文面だけ Log.warn する口（ViewCtx#warnOnce の実機の形）。
  `pub def warnOnceWith(seen: Ref[Set[String], Static]): String -> Unit`
- 生成したドット絵アトラス 1 枚ぶんの受け渡し。
  `pub type alias AtlasUpload = { texture = String, key = String, baked = PxSpriteAtlas.Baked }`
- App の中身（欄の意味は右の // コメント）。ゲームからは読まず、ビルダー（addSystem / withView など）で組む。
  `pub type alias Rec[w: Type, ef: Eff] = { init = Vec2.Vec2 -> w \ ef, startupSystems = List[w -> w \ ef], updateSystems = List[(Frame, w) -> w \ ef], reload = Option[(GameEngine.Key, w -> w \ {Fs.FileRead})], watch = List[(String, w -> w \ {Fs.FileRead})], view = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef], passes = w -> List[Render.Pass] \ ef, fonts = List[String], camera = Option[w -> Vec2.Vec2 \ ef], zoom = Option[w -> Float64 \ ef], cameraBounds = Option[w -> Rect2.Rect2 \ ef], parallaxLayers = List[(Float64, (ViewCtx, w) -> List[Render.PlacedItem] \ ef)], hudView = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef], audio = { before = w, after = w } -> List[String] \ ef, sustained = w -> List[Sustain] \ ef, mixer = Option[w -> AudioMixer.Mixer \ ef], quit = (Frame, w) -> Bool \ ef, closeRequest = Option[w -> w \ ef], debug = Bool, debugView = Option[(String, w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef)], worldDump = Option[(Rect2.Rect2, w) -> String \ ef], annotationContext = Option[w -> Annotate.Table \ ef], staticLayer = Option[{ key = w -> GameEngine.StaticKey, build = w -> List[Render.PlacedItem] }], tileLayers = Option[w -> List[TileLayerSpec]], spriteAtlases = w -> List[AtlasUpload], pixelSnap = w -> Float64, statusLine = Option[w -> String \ ef], remoteRender = Option[Unit -> List[String] \ IO], shot = Option[w -> String \ IO], remoteHandlers = List[(String, (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead})], fixedStep = Option[Float64], clocks = List[(Float64, w) -> w], cursor = Option[w -> CursorSpec], fullscreen = Option[w -> Bool], outputs = List[Output[w]], starts = List[Start[w]], flow = Flow.Table[w], fingerprint = Option[w -> String] }`
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
- 音の通り道（AudioMixer.Mixer）を World から導く関数を繋ぐ。繋ぐと、withAudio の音と
  `pub def withMixer(f: w -> AudioMixer.Mixer \ ef, app: App[w, ef]): App[w, ef]`
- 前のフレームの宣言（名前の列）と今のフレームの宣言から、鳴らし始める音・
  `pub def sustainOps(prev: List[String], next: List[Sustain]): { start = List[Sustain], keep = List[Sustain], stop = List[String] }`
- 終了判定を差し替える。既定は「Escape のエッジで終了」だが、モーダル表示中は
  `pub def quitWhen(f: (Frame, w) -> Bool \ ef, app: App[w, ef]): App[w, ef]`
- 窓の閉じるボタン（OS の閉じる要求・GLFW の window close）をすぐの終了にせず、World へ知らせる。
  `pub def withCloseRequest(f: w -> w \ ef, app: App[w, ef]): App[w, ef]`
- デバッグ機能（F8 の時間停止・矩形注釈・時間スクラブ）の有効 / 無効を宣言する。
  `pub def withDebug(enabled: Bool, app: App[w, ef]): App[w, ef]`
- 環境変数 DEBUG が空でない値で設定されていれば true（例: `DEBUG=true flix run`）。
  `pub def debugFromEnv(): Bool \ IO`
- debugFromEnv の中身。env は入口の頭で読んだ環境変数の表。
  `pub def debugOf(env: Map[String, String]): Bool`
- 自前描画（view = None）のゲームがデバッグ機能（F8）を使えるようにする生投影を繋ぐ。
  `pub def withDebugView(font: {font = String}, f: w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef, app: App[w, ef]): App[w, ef]`
- 注釈（F8 の矩形）を書き出すとき「囲った瞬間の World」をテキストにしてチケットへ
  `pub def withWorldDump(f: (Rect2.Rect2, w) -> String \ ef, app: App[w, ef]): App[w, ef]`
- 注釈（F8 の矩形）を書き出すとき、README の冒頭と annotation.json の "context" に載せる
  `pub def withAnnotationContext(f: w -> Annotate.Context[t, h] \ ef, app: App[w, ef]): App[w, ef] with SortingLayer[t], ToString[t], SortingLayer[h], ToString[h]`
- World の 1 行サマリ（例: "phase=Playing ball=(163.2,207.9) lives=3"）を繋ぐ。
  `pub def withStatusLine(f: w -> String \ ef, app: App[w, ef]): App[w, ef]`
- リモートデバッグ（HTTP）の POST /render が実行する「描き出しの実体」を繋ぐ。
  `pub def onRenderRequest(f: Unit -> List[String] \ IO, app: App[w, ef]): App[w, ef]`
- 渡した World を 1 枚の PNG に描き、書いたパスを返す関数を繋ぐ（中身は SceneRender の 1 場面と同じ描き方）。
  `pub def onShotRequest(f: w -> String \ IO, app: App[w, ef]): App[w, ef]`
- リモートデバッグ（HTTP）の任意パス（例: "/save"）に応えるハンドラを繋ぐ。
  `pub def onRequest(path: String, f: (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead}, app: App[w, ef]): App[w, ef]`
- 物理・当たり判定を固定刻み（dtSeconds 秒）で進める accumulator 方式を有効にする。
  `pub def withFixedStep(dtSeconds: Float64, app: App[w, ef]): App[w, ef]`
- World の欄にある遊びの時計（Clock.Clock[c]）を、App が毎フレーム 1 回だけ進めるよう宣言する。
  `pub def addClock(spec: { clockOf = w -> Clock.Clock[c], withClock = (Clock.Clock[c], w) -> w, paceOf = w -> Clock.Pace[c, r] }, app: App[w, ef]): App[w, ef]`
- マウスの矢印の見せ方（withCursor の宣言）。icon = 形・visible = 見せるか。
  `pub type alias CursorSpec = { icon = GameEngine.Cursor, visible = Bool }`
- 毎フレーム「マウスの矢印をどう見せたいか」を World から宣言する。App は宣言が変わったフレームだけ当て、
  `pub def withCursor(f: w -> CursorSpec, app: App[w, ef]): App[w, ef]`
- 毎フレーム「窓をボーダーレスのフルスクリーンにしたいか」を World から宣言する（true = フルスクリーン・
  `pub def withFullscreen(f: w -> Bool, app: App[w, ef]): App[w, ef]`
- 跳んだ拍（起動・START・/start・/step・/flow?apply・F8 の巻き戻しからの再開）に、出力をどう扱うか。
  `pub enum OnJump with Eq, ToString { case Skip case Write }`
- 外への出力 1 本: keyOf = 書く中身を決める鍵（"" = 書く物が無い）・write = 書く・onJump = 跳んだ拍の扱い。
  `pub type alias Output[w] = { keyOf = w -> String, write = w -> Unit \ Fs.FileWrite, onJump = OnJump }`
- 鍵が最後に書いた鍵と違う実機のフレームの後で、1 回だけ write を呼ぶ出力を足す（セーブ・名乗り）。
  `pub def addOutput(output: Output[w], app: App[w, ef]): App[w, ef]`
- Doc の一覧表（DocTable）から、保存即反映の監視（watchFile）・F1 の一括読み直し（reloadOn）・
  `pub def withDocTable(rows: List[DocTable.Entry[w]], app: App[w, ef]): App[w, ef]`
- 始まり 1 つ: name = 名前（START・flow の start で書く字）・doc = 何の場面か（GET /starts と語彙に載る）・
  `pub type alias Start[w] = { name = String, doc = String, args = Map[String, String], build = (w, Map[String, String]) -> Result[String, w] }`
- 始まりの登録簿を繋ぐ。繋いだゲームは起動もここを通る（環境変数 START が無ければ先頭の始まり）。
  `pub def withStarts(starts: List[Start[w]], app: App[w, ef]): App[w, ef]`
- 新しく作った初期の World: init（design 解像度から）+ 起動時の系 + Doc を全部読み直した物
  `pub def freshWorld(app: App[w, ef], design: Vec2.Vec2): w \ ef + Fs.FileRead`
- 登録簿の名前の列（登録順）。
  `pub def startNames(app: App[w, ef]): List[String]`
- 名前の始まりを、新しく作った初期の World から組む。args は既定の引数を上書きし、値が `@パス` の
  `pub def buildStart(app: App[w, ef], design: Vec2.Vec2, name: String, args: Map[String, String]): Result[String, w] \ ef + Fs.FileRead`
- buildStart の、初期の World を渡す形（窓なしのゲームが Doc の読み直しを取り置いた World から組む）。
  `pub def buildStartOn(app: App[w, ef], fresh: w, name: String, args: Map[String, String]): Result[String, w] \ Fs.FileRead`
- 引数の値が `@パス` ならファイルの中身に置き換える（読めないファイルの引数は外す —— 「無いセーブ」は正常）。
  `pub def loadArgs(args: Map[String, String]): Map[String, String] \ Fs.FileRead`
- `feedHome t=10` の形（flow の start の行・START・POST /start と同じ）を名前と引数に分ける。
  `pub def parseStartLine(text: String): Result[String, (String, Map[String, String])]`
- root の project.json の design 解像度（読めなければ 0×0 —— init が画面の大きさを読まないゲームはそれで足りる）。
  `pub def loadProjectDesign(root: String): Vec2.Vec2 \ Fs.FileRead`
- テストで名前の始まりを組む（組めなければテストの前提が破れているので bug! で止める）。
  `pub def startOrBug(app: App[w, ef], name: String, args: Map[String, String]): w \ ef + Fs.FileRead`
- flow の語彙の表を繋ぐ（使い方の全文は engine_world/src/Flow.flix 冒頭）。
  `pub def withFlow(table: Flow.Table[w], app: App[w, ef]): App[w, ef]`
- World の指紋の元の文字を選ぶ関数を繋ぐ。遊んだ記録が 60 フレームごとに `expect fp=…` を書き、
  `pub def withFingerprint(f: w -> String, app: App[w, ef]): App[w, ef]`
- addClock で宣言した時計を、実時間 dt で 1 回ずつ進める（advanceFrame が系の前に呼ぶ）。
  `pub def tickClocks(app: App[w, ef], dt: Float64, world: w): w`
- 前フレームと今フレームのキー集合から Frame を組む。justPressed は差分
  `pub def frameOf(prev: {prev = Set[GameEngine.Key]}, current: {current = Set[GameEngine.Key]}, dt: Float64, viewport: Vec2.Vec2, cursor: {prevCursor = Option[Vec2.Vec2], cursor = Vec2.Vec2}, mouse: {prevDown = Bool, down = Bool, wheel = Float64}): Frame`
- withFixedStep の accumulator。持ち越し carry と実フレームの経過秒 realDt を足し、
  `pub def fixedSteps(carry: Float64, realDt: Float64, fixedDt: Float64): (Int32, Float64)`
- withFixedStep の 2 サブステップ目以降に渡す Frame: エッジ 4 種（justPressed /
  `pub def suppressEdges(frame: Frame): Frame`
- 0 サブステップのフレームで捨てられそうになったエッジのバッファ。エッジは prev との
  `pub type alias PendingEdges = { justPressed = Set[GameEngine.Key], mouseClicked = Bool, mouseMoved = Bool, wheel = Float64 }`
- withFixedStep がフレームをまたいで持ち回す状態（持ち越し秒 + 未消費エッジ）。
  `pub type alias StepState = { carry = Float64, pending = PendingEdges, real = Clock.Clock[Clock.Real] }`
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
- trace の 1 フレーム: そのフレームの入力・進める前後の World・鳴らす一発の音（同じ名前は 1 つ）・
  `pub type alias TraceStep[w] = { frame = Frame, before = w, after = w, sounds = List[String], sustained = List[Sustain] }`
- 画面を開かずに、frames を 1 つずつ実機と同じ経路（advanceFrame → audio → sustained）へ流し、
  `pub def trace(app: App[w, ef], frames: List[Frame], w0: w): List[TraceStep[w]] \ ef`
- trace の 1 フレーム分。次のフレームの入力を World から組む道具（PropertyTest）はこれを回す。
  `pub def traceFrame(app: App[w, ef], frame: Frame, state: StepState, world: w): (TraceStep[w], StepState) \ ef`
- view 由来の絵（world）に camera（center と zoom。等倍は 1.0）を掛け、hud の絵を
  `pub def composeScene(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2, items: { world = List[Render.PlacedItem], hud = List[Render.PlacedItem] }): List[Render.PlacedItem]`
- camera 中心と zoom から、画面に見えている world の矩形を出す（大きさ design/zoom。
  `pub def visibleOf(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2): Rect2.Rect2`
- 監視中パスのうち「World を作り直すべき物」を watch の登録順で返す: current で見えて
  `pub def changedPaths(watch: List[String], prev: Map[String, Int64], current: Map[String, Int64]): List[String]`
- App を走らせる単一の効果多相ランナー。startup を 1 回だけ畳み込み、いま押されているキーを prev の
  `pub def launch(app: App[w, ef]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + Fs.FileWrite + IO)`
- 時間スクラブ用に持ち回す直近の World の数（60fps で約 30 秒）。
  `pub def historyLimit(): Int32`
- リモートコマンドを捌いた後に残る 3 つの進み方。
  `pub enum Branch with Eq, ToString { case Paused case Resuming case Running }`
- ウィンドウの閉じるボタンへの答え方。loop から切り出した内部 API — ゲームからは呼ばない。
  `pub enum CloseAnswer with Eq, ToString { case Ignore case AskGame case Close }`
- 閉じるボタンが押されたか・withCloseRequest があるか・F8 で止めているかから、閉じるボタンへの答え方を決める。
  `pub def decideClose(input: { closing = Bool, hasCloseRequest = Bool, paused = Bool }): CloseAnswer`
- F8 と停止状態から、このフレームの進み方と「F8 が今トグルされたか」を決める。
  `pub def decideBranch(input: { f8Pressed = Bool, canDebug = Bool, remoteHold = Bool, wasPaused = Bool }): { branch = Branch, toggled = Bool }`
- 跳んだ拍の後の出力の鍵: Skip は跳んだ先の鍵を「書いた」ことにし、Write は前に書いた鍵のまま
  `pub def keysAfterJump(app: App[w, ef], world: w, written: List[String]): List[String]`
- 実機のフレームの後の World で書くべき出力の番号（outputs の順）: 鍵が最後に書いた鍵と違う物。
  `pub def dueOutputs(app: App[w, ef], world: w, written: List[String]): List[Int32]`
- 止めた画面の出入りの見た目をウィンドウへ当てる。ゲームからは呼ばない（RemoteDebug が呼ぶので公開）。
  `pub def applyHaltLook(look: CursorLook.HaltLook): Unit \ GameEngine.Game`
- 一発で鳴らした名前とループで鳴らした名前の覚え（ゲームの間ずっと持つ）。
  `pub type alias SoundUses = { oneShot = Set[String], looped = Set[String] }`
- このフレームの一発の音 plays とループの音 looped を覚えに足し、初めて両方に出た名前を返す。
  `pub def noteSoundUses(plays: List[String], looped: List[String], uses: SoundUses): (SoundUses, List[String])`
- 一発の音（audio）のうち、鳴らす前にループを外す名前。鳴り続ける音（sustained）として
  `pub def unloopedOneShots(plays: List[String], living: List[String]): List[String]`
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
- 1 コマだけ描く（窓なしで GPU に塗る 1 枚撮り・動画。render_gl の GlOffscreen.handle の下で呼ぶ）。
  `pub def paintOnce(app: App[w, ef], world: w, tileCache: TileCache): TileCache \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target + IO)`

## App.CursorLook — `engine_world/src/App/CursorLook.flix`
- withCursor の宣言を最後にどう当てたか。Stale = まだ当てていない・止めた画面の見た目が上書きした
  `pub enum State { case Applied(App.CursorSpec) case Stale }`
- 矢印を見せるか。LeaveToApp = 触らない（今の見せ方のまま）。
  `pub enum Visibility with Eq, ToString { case Show case Hide case LeaveToApp }`
- ウィンドウへ当てる矢印の見た目（形・見せるか）。
  `pub enum Look with Eq, ToString { case Look(GameEngine.Cursor, Visibility) }`
- ウィンドウタイトルの「止めている」のバッジ。
  `pub enum Badge with Eq, ToString { case Shown case Hidden }`
- 止めた画面の出入りの見た目（タイトルのバッジ・矢印）。
  `pub enum HaltLook with Eq, ToString { case HaltLook(Badge, Look) }`
- withCursor の宣言 want を当てるなら、その見た目（前に当てた物と同じなら None）。
  `pub def cursorChange(want: App.CursorSpec, state: State): Option[Look]`
- 止めた画面に入る時の見た目: バッジを出し、十字を見せる — withCursor で矢印を隠しているゲームでも、
  `pub def haltEnterLook(): HaltLook`
- 止めた画面を抜ける時の見た目: バッジを外し、形だけ戻す。見せるか隠すかは触らない（動き出した拍に
  `pub def haltLeaveLook(): HaltLook`

## App.GameRegistry — `engine_world/src/App/GameRegistry.flix`
- 書き置き 1 行。
  `pub type alias Entry = { dir = String, pid = String, port = String }`
- 書き置きの中身から行を読む（読めない行は捨てる・読めない中身は空）。
  `pub def entriesOf(text: String): List[Entry]`
- entry を足す（同じ dir の古い行は外す）。
  `pub def withEntry(entry: Entry, entries: List[Entry]): List[Entry]`
- dir の行のうち pid が自分の物だけを外す（後から同じ dir で起こしたゲームの行は残す）。
  `pub def withoutEntry(dir: String, pid: String, entries: List[Entry]): List[Entry]`
- 書き置きの中身。
  `pub def textOf(entries: List[Entry]): String`
- 書き置きの置き場。
  `pub def path(): String \ IO`
- 今いる所（ゲームの根）の実パス。
  `pub def gameDir(): String \ IO`
- `pub def pidText(): String \ IO`
- `pub def register(port: Int32): Unit \ IO`
- このゲームの行を消す（閉じる時）。
  `pub def unregister(): Unit \ IO`

## App.Headless — `engine_world/src/App/Headless.flix`
- `pub type alias Request = RequestData`
- 要求の env（呼ぶ側のプロセスの環境変数を丸ごと）。
  `pub def envOf(req: Request): Map[String, String]`
- 要求の標準出力（子プロセスの出力をここへ写す時に使う）。
  `pub def outOf(req: Request): PrintStream`
- 要求の標準エラー。
  `pub def errOf(req: Request): PrintStream`
- 今のプロセスの env と標準出力・標準エラーで作る要求（素の道の入口が使う）。
  `pub def requestFromProcess(): Request \ IO`
- 静止画（常駐で流す）か、動画（GPU で塗るなら常駐に送らない）か。
  `pub enum JobKind with Eq, ToString { case Still, case Video }`
- `pub type alias Job = { name = String, kind = JobKind, launch = Request -> Int32 \ IO }`
- 素の道の入口の終わり方: 0 ならそのまま戻り、それ以外はその終了コードでプロセスを終える。
  `pub def exitWith(code: Int32): Unit \ IO`
- 静止画の入口。名前は "<モジュール>.<関数>" に組む。
  `pub def job(module: String, fn: String, launch: Request -> Int32 \ IO): Job`
- 動画の入口。
  `pub def videoJob(module: String, fn: String, launch: Request -> Int32 \ IO): Job`
- /run の終わりの印。
  `pub enum RunEnd with Eq, ToString { case Exited(Int32), case Oom, case Stale, case Busy, case UnknownEntry, case NeedsGl }`
- 入口の標準出力の 1 行。
  `pub def outLine(text: String): String`
- 入口の標準エラーの 1 行。
  `pub def errLine(text: String): String`
- 流れの最後の 1 行。
  `pub def endLine(end: RunEnd): String`
- /run の本文（`KEY=VALUE` の行）を env の表へ。`=` の無い行と鍵の空の行は捨てる。値の中の `=` は残す。
  `pub def parseEnvLines(body: String): Map[String, String]`
- /hello に返す env の行: LANG・LC_*・HEADLESS_* の順（同じ組の中は鍵の字の順）。
  `pub def passedEnv(env: Map[String, String]): List[(String, String)]`
- /hello の本文の材料。
  `pub type alias Hello = { pid = String, dir = String, manifest = String, served = Int64, busy = String, idleLeft = Int64, idleWindow = Int64, env = Map[String, String], jobs = List[(String, JobKind)] }`
- /hello の本文。
  `pub def helloText(hello: Hello): String`
- JobKind の字（/hello の job= の行）。
  `pub def kindText(kind: JobKind): String`
- HEADLESS_ENTRIES（空白区切り）に無い束の名前。HEADLESS_ENTRIES が空なら照合しない（空を返す）。
  `pub def missingEntries(declared: String, names: List[String]): List[String]`
- 寿命の幅（秒）: /run の後と、会話の列の要求の後。
  `pub type alias IdleWindows = { work = Int64, talk = Int64 }`
- env から寿命の幅を読む。常駐は /run が 180 秒・会話が 600 秒、常駐でなければどちらも HEADLESS_IDLE_SECS（既定 600 秒）。
  `pub def idleWindowsOf(resident: Bool, env: Map[String, String]): IdleWindows`
- 会話の列の要求（World を組む・進める・見る）か。
  `pub def isTalkPath(path: String): Bool`
- 会話の列の要求 1 件が寿命をどれだけ延ばすか。常駐では /start・/step・/state だけ、常駐でなければ全部。
  `pub def talkWindowOf(resident: Bool, windows: IdleWindows, path: String): Option[Int64]`
- 寿命: 切れる時刻（System.nanoTime の値）と、それを決めた幅の秒。
  `pub type alias Lease = { deadline = Int64, window = Int64 }`
- nowNs から windowSecs の寿命を取る。今の寿命の方が長く残っていれば今のまま（短い幅で縮めない）。
  `pub def extendLease(nowNs: Int64, windowSecs: Int64, lease: Lease): Lease`
- 寿命の残りの秒（切れていれば 0）。
  `pub def idleLeftSecs(nowNs: Int64, lease: Lease): Int64`
- resident.json の 1 件（値は全部文字列。games.json と同じ流儀）。
  `pub type alias ResidentEntry = { pid = String, port = String, dir = String, manifest = String, started = String }`
- resident.json の中身。
  `pub def residentText(entry: ResidentEntry): String`
- resident.json の pid（読めなければ None）。
  `pub def residentPidOf(text: String): Option[String]`
- [shot] の答えの `ok png=<パス>` の行のパス（無ければ None）。
  `pub def pngPathOf(block: String): Option[String]`
- [shot] の答えが書いたファイル: PNG と、隣の描き物の表（<名前>.items.tsv）。撮れていなければ空。
  `pub def shotFilesOf(block: String): List[String]`
- 入口の中身。FGE_SHOT があれば 1 枚撮って終わり、無ければ待ち受ける（/run は無し）。
  `pub def serve(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + IO`
- 窓なしのゲーム（/start・/step・view=shot）+ 入口の束（/run）で待ち受ける。FGE_SHOT があれば 1 枚撮って終わる。
  `pub def serveJobs(app: App.App[w, ef], jobs: List[Job]): Unit \ ef + Fs.FileRead + IO`
- App を持たないゲームの常駐。/start・/step・/state には「未対応」と答える。立てない時は 1 でプロセスを終える。
  `pub def serveJobsOnly(jobs: List[Job]): Unit \ IO`
- `pub def helpText(): String`

## App.HitchDetector — `engine_world/src/App/HitchDetector.flix`
- 1 コマの記録。時間はナノ秒。totalNs はループの 1 周（入力の取り込みから描き終わりの swap まで）、
  `pub type alias Row = { frame = Int64, totalNs = Int64, updateNs = Int64, renderNs = Int64, diag = FrameDiagnostics.Diagnostics, gc = Int32, gcMs = Int64, pressed = String, status = String, reloaded = Bool }`
- 決まり: budgetNs は 1 コマの予算・warmup は数えない起動直後のコマ数・context は前に付けるコマ数・
  `pub type alias Config = { budgetNs = Int64, warmup = Int64, context = Int32, calm = Int32, maxRows = Int32, maxHitches = Int32 }`
- 切り出した 1 件。rows は古い順（落ち着いた尾は除く）、context はその前の数コマ（古い順）。
  `pub type alias Hitch = { rows = List[Row], context = List[Row] }`
- `pub type alias Detector = DetectorState`
- 60fps の予算で、起動直後の 120 コマは数えず、前 10 コマ・落ち着き 30 コマ・1 件 600 コマ・1 実行 10 件。
  `pub def defaultConfig(): Config`
- `pub def fresh(config: Config): Detector`
- 重いコマか: 仕事が予算を超えた・swap まで含めて予算の 2 倍を超えた（GPU やドライバで止まった）・シェーダーを作った。
  `pub def isSlow(config: Config, row: Row): Bool`
- 1 コマ進める。1 件が閉じたらそれを返す。
  `pub def step(row: Row, detector: Detector): (Detector, Option[Hitch])`
- 開いている 1 件があれば今の所で閉じて返す（流し終えた時に使う）。
  `pub def finish(detector: Detector): (Detector, Option[Hitch])`
- 単発か: 重いコマが 1 つだけで、その時間の半分以上が GC か swap（シェーダー・字・テクスチャ・Doc の読み直しは無し）。
  `pub def isMinor(config: Config, hitch: Hitch): Bool`
- 単発の種類と 1 行（summary.md に足す）。
  `pub def minorOf(hitch: Hitch): (String, String)`
- 一番重いコマ（無ければ最初のコマ）。
  `pub def worstOf(hitch: Hitch): Option[Row]`
- 起点のコマか、それより前で一番近い手（前に付けたコマも探す）。
  `pub def pressBefore(hitch: Hitch): Option[Row]`
- 読む側（人・エージェント）向けの報告。dir は record.flow を置いた所（無ければ None）。
  `pub def report(config: Config, replay: Option[(String, Int64)], hitch: Hitch): String`
- この実行のヒッチの置き場 debug/perf/hitches/<起動時刻> を作り、古い実行は新しい keep 個を残して消す。
  `pub def prepareRunDir(keep: Int32): String \ IO`
- 1 件を dir/hitch.md に書く。書けたら true。
  `pub def write(dir: String, text: String): Bool \ IO`
- dir/name に text を書く（dir が無ければ作る）。書けたら true。
  `pub def writeFile(dir: String, name: String, text: String): Bool \ IO`
- 起動からの GC の回数と、止まった時間の合計 ms（並行して走る GC は止めないので数えない）。
  `pub def gcNow(): (Int32, Int64) \ IO`

## App.RemoteDebug — `engine_world/src/App/RemoteDebug.flix`
- HTTP サーバ本体と、リクエスト / レスポンスを受け渡す 2 本のキュー。
  `pub type alias Bridge = { server = HttpServer, requests = JQueue[String], responses = JQueue[String], current = AtomicLong }`
- /render の帳簿。HTTP のスレッドと描き出しのスレッドが共有する（どれもスレッド安全な Java の部品）。
  `pub type alias RenderJobs = { requested = AtomicLong, done = AtomicLong, running = AtomicLong, last = AtomicReference[String], wake = JQueue[String] }`
- 橋の外で、HTTP の糸の中で答える口（App.Headless の /hello・/run）。path が合う依頼はキューへ積まず、
  `pub type alias DirectRoute = { path = String, serve = (Request, OutputStream) -> Unit \ IO }`
- 環境変数 DEBUG_HTTP_PORT からポート番号を読む。未設定・数値でなければ None。
  `pub def portFromEnv(): Option[Int32] \ IO`
- portFromEnv の中身。env は入口の頭で読んだ環境変数の表。
  `pub def portOf(env: Map[String, String]): Option[Int32]`
- 命令口を開くポート: DEBUG_HTTP_PORT があればそれ、無ければ 0（OS に空いたポートを選ばせる）。
  `pub def portToOpen(): Option[Int32] \ IO`
- portToOpen の中身。env は入口の頭で読んだ環境変数の表。
  `pub def portToOpenOf(env: Map[String, String]): Option[Int32]`
- 実際に開けたポート（0 で開いた時に OS が選んだ番号を知る）。
  `pub def boundPort(bridge: Bridge): Int32 \ IO`
- 本文に依頼番号を付ける（キューに積む形）。
  `pub def tagged(id: Int64, text: String): String`
- tagged の逆。番号の無い・読めない形は None。
  `pub def untagged(raw: String): Option[(Int64, String)]`
- `pub def start(port: Int32, render: Option[Unit -> List[String] \ IO]): Bridge \ IO`
- 窓なしのゲーム（App.Headless）の待ち受け: 同じ橋を、名乗らず（listening の行も書き置きも無し）に開く。
  `pub def startQuiet(port: Int32): Bridge \ IO`
- `pub def startQuietWith(port: Int32, direct: List[DirectRoute]): Bridge \ IO`
- startQuiet で開いた橋を閉じる（書き置きに触れない）。
  `pub def stopQuiet(bridge: Bridge): Unit \ IO`
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
  `pub enum View with Eq, ToString { case Status, case Summary, case Full, case Scene, case Shot, case Silent }`
- /step を台本の途中で止める条件。「意味のある瞬間」で止まることで往復を減らす。
  `pub enum Until with Eq, ToString { case Always, case SfxAny, case SfxNamed(Set[String]), case Quiet(Int32) }`
- /step・/state のクエリを解釈した実行パラメータ。
  `pub type alias StepParams = { view = View, rect = Option[Rect2.Rect2], stopWhen = Until, maxFrames = Int32, traceEvery = Option[Int32], dtSeconds = Float64 }`
- クエリ Map を StepParams へ。不正な値は理由つきの Err（応答にそのまま載せる）。
  `pub def parseParams(queryMap: Map[String, String]): Result[String, StepParams]`
- クエリを何も書かなかった時の StepParams（view=status・止めない・max 1200・dt 1/60 秒）。
  `pub def defaultParams(): StepParams`
- 1 リクエストで実行できる合成フレーム数の天井（60fps で 1 分ぶん）。
  `pub def frameCap(): Int32`
- until 条件の 1 フレームぶんの判定。このフレームで鳴った音名と「無音が何フレーム
  `pub def stopCheck(stopWhen: Until, soundsThisFrame: List[String], quietRun: Int32): (String, Int32)`
- /step 応答の 1 行目。何フレーム進んで何故止まったかを 1 行で伝える。
  `pub def stepHeader(info: { stepped = Int32, frame = Int64, stoppedBy = String, quit = Bool }): String`
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
- 1 回の描き出しが済んだときの応答。renderDoneText の 1 行目の末尾に、その回の番号を足した形
  `pub def renderJobDoneText(job: Int64, ms: Int64, paths: List[String]): String`
- 1 回の描き出しが落ちたときの応答（描き出しの中の bug! や例外の文面を 1 行に）。
  `pub def renderFailedText(job: Int64, reason: String): String`
- POST /render?async=1 の応答。番号を受け取った側は GET /render で done がその番号以上になるのを待つ。
  `pub def renderAcceptedText(job: Int64): String`
- GET /render の応答。1 行目に番号 3 つ（受け付けた最後・描き終えた最後・いま描いている回。0 = 無し）、
  `pub def renderStatusText(requested: Int64, done: Int64, running: Int64, last: String): String`
- POST /render のクエリが「すぐ返す」を頼んでいるか（async=1）。
  `pub def wantsAsyncRender(params: Map[String, String]): Bool`
- 描き出しのスレッドが次に描く番号。頼まれた番号が描き終えた番号より先なら、頼まれた番号まで
  `pub def nextRenderTarget(requested: Int64, done: Int64): Option[Int64]`
- 番号 id の依頼が済んだか。後の番号の回でまとめて描き終えていても済んだ扱い
  `pub def isRenderSettled(id: Int64, done: Int64): Bool`
- `pub def answerWaitSecs(params: Map[String, String]): Int64`
- 時間内に答えられなかったときの応答。古い Studio はこの 1 行目を「描いている途中」と読む
  `pub def busyText(): String`
- 描き出しの実体（App.onRenderRequest）を登録していないゲームへの応答。
  `pub def renderUnsupportedText(): String`
- GET /help の本文。プロトコルの自己記述（セッション冒頭に 1 回読む想定）。
  `pub def helpText(): String`
- リモートコマンド処理が次の実フレームへ持ち回す状態。
  `pub type alias RemoteNext[w] = { world = w, anno = Annotate.State, history = List[w], hold = Bool, stepState = App.StepState, record = List[Flow.Record.Item] }`
- リクエスト 1 件を捌き、応答をブリッジへ書いてから次の状態を返す。
  `pub def handleRemote(app: App.App[w, ef], bridge: Bridge, raw: String, ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + Fs.FileRead + IO)`
- GET /starts の本文: 始まりの登録簿（App.withStarts）の名前・既定の引数・説明を 1 行ずつ。
  `pub def startsText(app: App.App[w, ef]): String`
- view=shot の本文: [shot] と、撮れたら `ok png=<パス>`（/render と同じ形）・撮れなければ `error: 理由`。
  `pub def shotBlock(app: App.App[w, ef], world: w): String \ IO`
- /step 1 回ぶんの実行結果。
  `pub type alias StepOutcome[w] = { world = w, stepState = App.StepState, newHistory = List[w], framesRun = Int32, sounds = List[(Int64, String)], stoppedBy = String, quit = Bool, failure = String, traceLines = List[String] }`
- flow が流したフレームの列を、/step の止め方（until=sfx|quiet・quitWhen）で切り、応答の材料にする。
  `pub def stepOutcomeOf(app: App.App[w, ef], played: List[Flow.Played[w]], start: { world = w, state = App.StepState, frame = Int64 }, stepParams: StepParams, flowEnd: String): StepOutcome[w] \ ef`
- flow の結果（流し終えた・止まった）からフレームの列と止まった所の 1 行を取り出す。
  `pub def playedOf(result: Result[Flow.Failure[w], Flow.Outcome[w]]): (List[Flow.Played[w]], String)`
- 止まった所の 1 行（行番号・理由・何フレーム目・使った問いの値）。
  `pub def failureLine(failure: Flow.Failure[w]): String`
- POST /flow 1 回で流せるフレームの上限（60fps で 10 分ぶん）。ゲームのループの中で流すので、その間は窓が止まる。
  `pub def flowFrameCap(): Int32`

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

## AudioMixdown — `engine_world/src/AudioMixdown.flix`
- 1 コマぶんの音の宣言。
  `pub type alias MixFrame = { plays = List[String], sustained = List[App.Sustain], mixer = AudioMixer.Mixer }`
- コマの並びを sampleRate の波形へ書き出す。sounds に無い名前は鳴らない（実機と同じ）。
  `pub def mixdown(sampleRate: Int32, fps: Float64, sounds: Map[String, Vector[Float64]], frames: List[MixFrame]): Vector[Float64]`
- mixdown に、鳴り続ける音のループ点を足した物。loopStarts = 名前 → 繰り返しの頭のサンプル番号
  `pub def mixdownLooped(sampleRate: Int32, fps: Float64, sounds: Map[String, Vector[Float64]], loopStarts: Map[String, Int32], frames: List[MixFrame]): Vector[Float64]`
- 左右 2 本の波形（同じ長さ）。モノラルの素材は左右に同じ列を置く（loadWavStereo がそう読む）。
  `pub type alias Stereo = { left = Vector[Float64], right = Vector[Float64] }`
- mixdownLooped の左右 2 本版（動画の音をステレオで書き出す）。混ぜ方の規則は mixdownLooped と同じで、
  `pub def mixdownStereo(sampleRate: Int32, fps: Float64, sounds: Map[String, Stereo], loopStarts: Map[String, Int32], frames: List[MixFrame]): Stereo`
- WAV（PCM 16bit。モノラル・ステレオ）を sampleRate のモノラル -1〜1 へ読む。
  `pub def loadWav(sampleRate: Int32, path: String): Vector[Float64] \ IO`
- WAV（PCM 16bit）を sampleRate の左右 2 本へ読む（mixdownStereo へ渡す）。モノラルは左右に同じ列。
  `pub def loadWavStereo(sampleRate: Int32, path: String): Stereo \ IO`
- WAV のループ点の頭（smpl チャンク。AudioUtil.loopPointsOf）を、sampleRate で読み直したときの
  `pub def loadLoopStart(sampleRate: Int32, path: String): Option[Int32] \ IO`
- 波形のいちばん大きな振れ幅（0〜）。割れの確かめと、書き出す前の音量合わせに使う。
  `pub def peakOf(samples: Vector[Float64]): Float64`

## AudioMixer — `engine_world/src/AudioMixer.flix`
- バス 1 本。volume は 0.0〜1.0（設定画面の「BGM の音量」のつまみ）、
  `pub type alias Bus = { name = String, volume = Float64, lowpassGainHF = Float64 }`
- 名前の頭が prefixes のどれかに当たる音を bus へ流す（"bgm" → music のように）。
  `pub type alias Route = { bus = String, prefixes = List[String] }`
- by のバスのどれかが鳴っている間、bus の音量を depth 倍へ下げる。
  `pub type alias Duck = { bus = String, by = List[String], depth = Float64, attackSeconds = Float64, holdSeconds = Float64, releaseSeconds = Float64 }`
- 名前の頭が prefix の音は、同じ名前が seconds 以内に続いたら鳴らさない。
  `pub type alias Cooldown = { prefix = String, seconds = Float64 }`
- スナップショットの中のバス 1 本の上書き（None の欄は元のまま）。
  `pub type alias BusOverride = { name = String, volume = Option[Float64], lowpassGainHF = Option[Float64] }`
- 名前つきの「場面ごとの聞こえ方」。会話の間は曲を籠もらせる・ポーズ中は効果音を絞る、
  `pub type alias Snapshot = { name = String, buses = List[BusOverride] }`
- ミキサー全体の宣言（AudioMixerDoc が JSON から作る）。transitionSeconds は
  `pub type alias Mixer = { buses = List[Bus], routes = List[Route], defaultBus = String, ducks = List[Duck], cooldowns = List[Cooldown], snapshots = List[Snapshot], transitionSeconds = Float64 }`
- 持ち回す状態。now は経過秒、lastPlay は名前ごとの最後の鳴り始め、
  `pub type alias State = { now = Float64, lastPlay = Map[String, Float64], busyUntil = Map[String, Float64], ducks = Map[String, Float64], voices = Map[String, Float64], levels = Map[String, Level], sustainedBuses = Set[String], busDucks = Map[String, Float64] }`
- バス 1 本の今の値と、移っている先。移り始めに「1 秒あたりの速さ」を決めて覚えるので、
  `pub type alias Level = { volume = Float64, gainHF = Float64, targetVolume = Float64, targetGainHF = Float64, volumeSpeed = Float64, gainHFSpeed = Float64 }`
- 何もしないミキサー（全部の音が音量 1・素通し・間引きなし）。Doc が無いときの既定。
  `pub def defaults(): Mixer`
- 鳴らし始める前の状態。
  `pub def initial(): State`
- 音の名前が流れるバスの名前（routes の prefixes の一番長い一致。無ければ defaultBus）。
  `pub def busOf(mixer: Mixer, name: String): String`
- バスの宣言（Doc に無いバスは音量 1・素通し）。
  `pub def getBus(mixer: Mixer, bus: String): Bus`
- 音 1 本に掛ける音量の倍率 = 流れるバスの busGainOf。
  `pub def gainOf(mixer: Mixer, state: State, name: String): Float64`
- 音 1 本の高い音の残り具合（流れるバスの今の lowpassGainHF）。
  `pub def lowpassGainHFOf(mixer: Mixer, state: State, name: String): Float64`
- バスの音量の倍率 = バスの今の音量 × そのバスに掛かっているダッキング。
  `pub def busGainOf(mixer: Mixer, state: State, bus: String): Float64`
- バスの今の高い音の残り具合（スナップショットへ移る途中なら途中の値）。
  `pub def busLowpassGainHFOf(mixer: Mixer, state: State, bus: String): Float64`
- バスに掛かっているダッキングの倍率（同じバスへ何本掛かっていても掛け算）。
  `pub def duckGainOf(state: State, bus: String): Float64`
- 名前に掛かるクールダウンの秒（cooldowns の prefix の一番長い一致。無ければ 0 = 間引かない）。
  `pub def cooldownOf(mixer: Mixer, name: String): Float64`
- bus の音量を差し替えた新しいミキサー（Doc に無いバスなら足す）。
  `pub def withBusVolume(bus: String, volume: Float64, mixer: Mixer): Mixer`
- bus の高い音の残り具合を差し替えた新しいミキサー（夜の場面だけ籠もらせる、など）。
  `pub def withLowpassGainHF(bus: String, gainHF: Float64, mixer: Mixer): Mixer`
- 名前のスナップショットを重ねた新しいミキサー（無い名前なら元のまま）。
  `pub def withSnapshot(name: String, mixer: Mixer): Mixer`
- 1 フレームぶんを決まった順で進める: 時計とバスの値を進め（advance）→ 一発の音をクールダウンに
  `pub def step(mixer: Mixer, lengthOf: String -> Float64 \ ef, dt: Float64, plays: List[String], sustained: List[String], state: State): (List[String], State) \ ef`
- このフレームに鳴らしたい一発の音をクールダウンに通す。返すのは「実際に鳴らす名前」と、
  `pub def applyCooldowns(mixer: Mixer, lengthOf: String -> Float64 \ ef, names: List[String], state: State): (List[String], State) \ ef`

## AudioMixerDoc — `engine_world/src/AudioMixerDoc.flix`
- テキストから Mixer へ（JSON でない・オブジェクトでなければ None）。
  `pub def fromJson(text: String): Option[AudioMixer.Mixer]`
- path の mixer.json を読む。読めない・壊れているときは fallback（ふつうは AudioMixer.defaults()）。
  `pub def load(fallback: AudioMixer.Mixer, path: String): AudioMixer.Mixer \ Fs.FileRead`

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

## Clock — `engine_world/src/Clock.flix`
- 反復タイマー: acc に dt を足し、interval に達したら（== も含む）1回 fire（rest に余りを残す）。
  `pub def tick(acc: Float64, dt: Float64, interval: Float64): {fired = Bool, rest = Float64}`
- カウントダウン: 残り時間を dt 減らし、0 で下げ止める。Timer(oneShot=true) 相当。
  `pub def countdown(remaining: Float64, dt: Float64): Float64`
- 実時間の時計の名前。App だけが進め、frame#realNow で配る。
  `pub enum Real`
- 時計 c で測った時刻。Float64 から直には作れない（nowOf / prevOf と zero / never / after が作る）。
  `pub type alias Time[c] = Stamp[c]`
- `pub def eq(a: Stamp[c], b: Stamp[c]): Bool`
- `pub def compare(a: Stamp[c], b: Stamp[c]): Comparison`
- `pub def toString(a: Stamp[c]): String`
- 時計の頭の時刻（start した時計の nowOf と同じ）。World の初期値や、テストで組む Frame の realNow に。
  `pub def zero(): Time[c]`
- まだ起きていない出来事の時刻（どの今から見ても、演出が全部終わった過去）。
  `pub def never(): Time[c]`
- at から seconds 秒あとの時刻（負なら手前）。
  `pub def after(seconds: Float64, at: Time[c]): Time[c]`
- at から now までの秒（now が先なら負）。
  `pub def since(at: Time[c], now: Time[c]): Float64`
- 秒へ戻す。周期の関数（Anim.frameAt・Sway.wave・Fx.derive）に渡す所だけで使う —— 時計の名前は消える。
  `pub def secondsOf(at: Time[c]): Float64`
- 時計 c。
  `pub type alias Clock[c] = Ticker[c]`
- このフレームの時計の進み方。r は止める理由（ゲームの型）。
  `pub enum Run[r] { case Running case Scaled(Float64) case Paused(r) }`
- 時刻 at から掛かるスロー・ヒットストップ（TimeScale の Plan）。Plan の秒は Scaled(k) を掛けた後の秒で
  `pub type alias Slow[c] = { at = Time[c], plan = TimeScale.Plan }`
- World から導く「このフレームの時計の進み方」の宣言。mode が止める・倍速を、slow がヒットストップを決める（run は Flix の予約語）。
  `pub type alias Pace[c, r] = { mode = Run[r], slow = Option[Slow[c]] }`
- スローの掛かっていない進み方。
  `pub def paceOf(mode: Run[r]): Pace[c, r]`
- 時刻 at から plan のスローを掛ける（掛かっている物は置き換える）。
  `pub def withSlow(at: Time[c], plan: TimeScale.Plan, pace: Pace[c, r]): Pace[c, r]`
- 0 秒から始まる時計。
  `pub def start(): Clock[c]`
- seconds 秒から始まる時計（描き出し・テストで決まった瞬間を撮るとき。遊びの中では start を使う）。
  `pub def startAt(seconds: Float64): Clock[c]`
- 今の時刻。
  `pub def nowOf(clock: Clock[c]): Time[c]`
- 前のフレームの時刻（止まっていたフレームは今と同じ）。
  `pub def prevOf(clock: Clock[c]): Time[c]`
- このフレームに進んだ秒（止まっていれば 0・スロー中は縮む）。遊びの更新はこの秒で進める。
  `pub def dtOf(clock: Clock[c]): Float64`
- 1 フレーム進める。App が毎フレーム 1 回だけ呼ぶ（ゲームからは App.addClock で宣言する）。
  `pub def advance(pace: Pace[c, r], dt: Float64, clock: Clock[c]): Clock[c]`
- pace のスローがこの時計の今まだ掛かっているか（ヒットストップの光・揺れの出し入れに）。
  `pub def isSlowed(pace: Pace[c, r], clock: Clock[c]): Bool`

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
- ZStack の木で足元の順に並べるときの zIndex（1 画素ごとに 1 つ・下にある物ほど大きい）。
  `pub def orderAt(footY: Float64): Int32`

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
- App.withDocTable が名乗る形(id → パスの列)。いま world で activeWhen を満たす行のうち
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
- 整数を start から end へ 1 つずつ動かす tween の、進み u（0..1）の時点の値。
  `pub def steppedInt(start: Int32, end: Int32, easing: Easing, u: Float64): Int32`

## Emit — `engine_world/src/Emit.flix`
- f を走らせ、戻り値と、その間に出た出来事の列（出た順）を返す。
  `pub def collect(f: Unit -> a \ ef): (a, List[e]) \ (ef - Emit[e])`
- `pub type alias Events[e] = EventLog[e]`
- 出来事がまだ 1 つも無い溜め（World の初期値）。
  `pub def empty(): Events[e]`
- これまでに溜めへ出た出来事の総数（捨てた古い出来事も数える。増えるだけ）。
  `pub def countOf(events: Events[e]): Int64`
- f を走らせ、その間に出た出来事を溜めの末尾に足す（1 回の collectInto = 通し番号 1 つ）。
  `pub def collectInto(f: Unit -> a \ ef, events: Events[e]): (a, Events[e]) \ (ef - Emit[e])`
- before の後に after へ足された出来事（出た順）。audio に ws#before#events と ws#after#events を渡す。
  `pub def since(before: Events[e], after: Events[e]): List[e]`

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

## Flow — `engine_world/src/Flow.flix`
- 問い 1 つの読み方。Num は < <= = >= > != で比べ、Text は = と != で比べ、Flag はそのまま（!名前 で否定）。
  `pub enum Probe[w] { case Num(w -> Float64) case Text(w -> String) case Flag(w -> Bool) }`
- 入力を受けられるか。Busy の理由は、待ちが 10 秒に当たった時の知らせに載る。
  `pub enum Ready with Eq, ToString { case Ready case Busy(String) }`
- 名前付きの操作の 1 フレームの決め事。Tap = その役を 1 フレーム押す（待った秒は 0 に戻る）・
  `pub enum DriveAct with Eq, ToString { case Tap(String) case Idle case Restart }`
- `pub type alias ProbeRow[w] = { name = String, doc = String, read = Probe[w] }`
- act の引数は (drive の始まりか最後の Tap・Restart から待った秒, いまの World)。
  `pub type alias DriveRow[w] = { name = String, doc = String, act = (Float64, w) -> DriveAct }`
- ゲームが出す表。ready と replies を宣言しないゲームは、自動の待ちと返事の確かめをしない。
  `pub type alias Table[w] = { roles = w -> InputMap.Table[String], probes = List[ProbeRow[w]], drives = List[DriveRow[w]], ready = Option[w -> Ready], replies = Option[w -> Int64], options = List[(String, List[String])] }`
- 何も宣言しない表（{ probes = … | Flow.emptyTable() } で要る欄だけ書く）。
  `pub def emptyTable(): Table[w]`
- ゲームの役の enum の表（InputMap.Table[a]）を、名前の表にする。
  `pub def rolesOf(name: a -> String, table: InputMap.Table[a]): InputMap.Table[String]`
- `pub enum Kind with Eq, ToString { case Num case Text case Flag }`
- 名前の一覧。roles は World から読むので、語彙は World を 1 つ決めて作る（ふつうは新しく作った初期の World）。
  `pub type alias Vocab = { roles = List[String], probes = List[(String, Kind, String)], drives = List[(String, String)], starts = List[(String, String, Map[String, String])], options = List[(String, List[String])], keys = List[String], ready = Bool, replies = Bool, fingerprint = Bool }`
- 手の語（閉じた一覧）。記録が書く語（reload・request・close・rewind）も同じ文法で読める。
  `pub def verbs(): List[String]`
- エンジンが持つ設定の語（ゲームの設定は Table#options）。
  `pub def settings(): List[String]`
- 指紋の問いの名前（App.withFingerprint を繋いだゲームだけ）。
  `pub def fingerprintProbe(): String`
- `pub def vocabOf(app: App.App[w, ef], world: w): Vocab`
- 語彙を e2e/vocab.json の形にする（bin/fge flow check が読む。キーの順は固定）。
  `pub def vocabJson(vocab: Vocab): String`
- 押す物: 役の名前・キーの集合・画面の点（design 座標。クリック）。
  `pub enum Target with Eq, ToString { case Role(String) case Keys(Set[Key]) case Point(Float64, Float64) }`
- 長さ: 秒（fps でフレーム数に丸める）かフレーム数。
  `pub enum Span with Eq, ToString { case Secs(Float64) case Frames(Int32) }`
- フレームの手の付け足し（ほとんどは記録が書く）。ns = フレームごとの経過ナノ秒（数がフレーム数）・dt = 経過秒・
  `pub type alias Opt = { ns = List[Int64], dt = Option[Float64], at = Option[Vec2.Vec2], mouse = Bool, wheel = Float64, pad = Bool, keys = Option[Set[Key]], pressed = Option[Set[Key]], click = Option[Bool], moved = Option[Bool] }`
- `pub def noOpt(): Opt`
- `pub enum Cmp with Eq, ToString { case Lt case Le case Same case Ge case Gt case Differ }`
- 問いの式。Name は真偽の問い・Compare は (名前, 比べ方, 書いた値の文字)。
  `pub enum Expr with Eq, ToString { case Name(String) case Not(Expr) case Both(Expr, Expr) case Compare(String, Cmp, String) }`
- 記録が書いたファイルの中身（再生はこの中身を読ませる）。Missing = 読めなかった（無いセーブ）。
  `pub enum File with Eq, ToString { case Text(String) case Missing }`
- 手 1 つ。tap・hold・release・wait はフレームを使い、expect・mark は使わない。
  `pub enum Step { case Start(String, Map[String, String], Map[String, File]) case Tap(Target, Opt) case Hold(Target, Option[Span], Opt) case Release(Target, Opt) case Wait(Span, Opt) case Until(Expr, Float64) case Drive(String, Expr, Float64) case Expect(Expr) case Mark(String) case Reload(String, Map[String, File]) case Request(String, Map[String, String], Map[String, File]) case Close case Rewind(Int32) }`
- 手 1 つと、その書いてある所（失敗の知らせに載せる）。
  `pub type alias Line = { file = String, number = Int32, text = String, step = Step }`
- 読んだ手順。ready = None は on と同じ（ready off だけが待ちと返事の確かめを止める）。
  `pub type alias Script = { fps = Float64, ready = Option[Bool], options = Map[String, String], lines = List[Line] }`
- 1 フレームとその後の固定刻みの持ち越し（/step が途中で止める時に要る）。
  `pub type alias Played[w] = { step = App.TraceStep[w], state = App.StepState }`
- 流し終えた結果。frames は先頭から。marks = 名前 → その時までのフレーム数・starts = (その時までのフレーム数, 始まりの名前)。
  `pub type alias Outcome[w] = { frames = List[Played[w]], marks = Map[String, Int32], starts = List[(Int32, String)], last = w, state = App.StepState }`
- 止まった所。frame = それまでのフレーム数・why = 理由・seen = 使った問いの今の値と statusLine・upTo = そこまで。
  `pub type alias Failure[w] = { at = Line, frame = Int32, why = String, seen = String, upTo = Outcome[w] }`
- play の設定: design = 解像度（Frame#viewport）・limit = フレーム数の上限（超えたら失敗）。
  `pub type alias Setup = { design = Vec2.Vec2, limit = Int32 }`
- フレームの列（World の列。動画が描く物）。
  `pub def worldsOf(outcome: Outcome[w]): List[w]`
- 手順を流す。start = 最初の手が start でない時に使う World と持ち越し（/step は走っている World、
  `pub def play(app: App.App[w, ef], setup: Setup, script: Script, start: { world = w, state = App.StepState }): Result[Failure[w], Outcome[w]] \ ef + Fs.FileRead`
- 経過秒をナノ秒の整数に丸める。実機の経過秒もナノ秒から来るので、flow で流したフレームを記録して
  `pub def roundToNanos(secs: Float64): Float64`
- 問いの式が今の World で立っているか。表に無い名前・型の違う比べは立たない（読み手と check が先に止める）。
  `pub def holds(app: App.App[w, ef], expr: Expr, world: w): Bool`
- 問いの今の値。
  `pub enum Value with Eq, ToString { case Num(Float64) case Text(String) case Flag(Bool) }`
- `pub def valueOf(app: App.App[w, ef], name: String, world: w): Option[Value]`
- 指紋の元の文字を 8 字の 16 進の指紋にする（記録の expect fp= と同じ物）。
  `pub def fingerprintOf(text: String): String`
- 記録の行に載せるファイルの中身（UTF-8 の Base64。改行や空白を 1 語に収める）。
  `pub def base64Encode(text: String): String`
- base64Encode の逆（戻せなければ None）。
  `pub def base64Decode(text: String): Option[String]`
- "lines>=4" を (名前, 比べ方, 値) に分ける。比べの記号が無ければ None。
  `pub def splitCompare(text: String): Option[(String, Cmp, String)]`
- 式を書いた形に戻す（知らせ用）。
  `pub def showExpr(expr: Expr): String`
- `pub def cmpSymbol(cmp: Cmp): String`

## Flow.Cli — `engine_world/src/Flow/Cli.flix`
- プロセスの環境変数で mainOf を流し、失敗ならその終了コードでプロセスを終える。
  `pub def main(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + Fs.FileWrite + IO`
- main の中身。env は入口の頭で読んだ環境変数の表（常駐なら App.Headless.envOf(req)）。戻り値は終了コード。
  `pub def mainOf(app: App.App[w, ef], env: Map[String, String]): Int32 \ ef + Fs.FileRead + Fs.FileWrite + IO`
- 語彙だけを書く（ゲームの E2e.vocab が呼ぶ。bin/headless-run が jar を作った時・make flow-vocab）。
  `pub def writeVocabOf(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + Fs.FileWrite + IO`
- writeVocabOf の中身。env は入口の頭で読んだ環境変数の表。書けなくても 0 を返す（理由は 1 行出す）。
  `pub def vocabMainOf(app: App.App[w, ef], env: Map[String, String]): Int32 \ ef + Fs.FileRead + Fs.FileWrite + IO`
- 先頭の手が start でない時に流し始める World: 登録簿の先頭の始まり（無ければ新しく作った初期の World）。
  `pub def startWorld(app: App.App[w, ef], design: Vec2.Vec2, fresh: w, script: Flow.Script): w \ ef + Fs.FileRead`
- プロセスの環境変数（無いか空なら fallback）。入口の頭だけで使う。奥では getEnvOr で引数の表を引く。
  `pub def envOr(name: String, fallback: String): String \ IO`
- env の表の値（無いか空なら fallback）。
  `pub def getEnvOr(env: Map[String, String], name: String, fallback: String): String`
- ファイルを読む（読めなければ理由）。
  `pub def readText(path: String): Result[String, String] \ Fs.FileRead`
- ファイルに書く（書けたか）。
  `pub def writeText(path: String, text: String): Bool \ Fs.FileWrite`

## Flow.Parse — `engine_world/src/Flow/Parse.flix`
- 読めない行（file の number 行目。行番号は 1 から。0 = ファイルそのもの）。
  `pub type alias Problem = { file = String, number = Int32, text = String, why = String }`
- 本文だけを読む（run は使えない —— 起動中のゲームへ送った本文に、読みに行くフォルダは無い）。
  `pub def parseText(vocab: Vocab, name: String, text: String): Result[List[Problem], Script]`
- ファイルを読む。run の先は read で同じフォルダから引く（8 段まで）。
  `pub def parseFile(vocab: Vocab, path: String, read: String -> Result[String, String] \ ef): Result[List[Problem], Script] \ ef`
- 知らせの形: 「ファイル:行: 理由」と、次の行に書いてあった手。
  `pub def problemsText(problems: List[Problem]): String`
- b64: で始まる値は Base64 を戻した中身（UTF-8）。それ以外はそのまま。
  `pub def decoded(value: String): Result[String, String]`

## Flow.Record — `engine_world/src/Flow/Record.flix`
- 記録に足す物（リモートの入口が App へ返す）: 書く行そのものか、流したフレームとその後の指紋の元。
  `pub enum Item { case Line(String) case Started(String) case Played(App.Frame, Option[String]) }`
- 書いている途中の記録。同じ入力が続くフレームは pending に貯めて 1 行にまとめる。
  `pub type alias Recorder = { path = String, out = FileWriter, state = Ref[Writing, Static] }`
- 記録を開く。前の回の記録は previous.flow へ残す（既定の置き場の時だけ）。開けなければ None（遊ぶのは止めない）。
  `pub def open(path: String): Option[Recorder] \ IO`
- 記録の置き場（環境変数 FLOW_RECORD: 無し = debug/flow-record/latest.flow・"0" = 書かない・それ以外 = そのパス）。
  `pub def pathFromEnv(): Option[String] \ IO`
- pathFromEnv の中身。env は入口の頭で読んだ環境変数の表。
  `pub def pathOf(env: Map[String, String]): Option[String]`
- まとめている行を書き出す。
  `pub def flush(rec: Recorder): Unit \ IO`
- そのまま 1 行を書く（start・reload・request・close・rewind・# ext）。前にまとめていた行を先に書き出す。
  `pub def line(rec: Recorder, text: String): Unit \ IO`
- start の行を書き、前のフレームの手の様子を初めに戻す（再生の start も手を初めからにする —— 戻さないと、
  `pub def started(rec: Recorder, text: String): Unit \ IO`
- 外から World が変わった（記録の行で説明の付かない変化）か: 指紋の元が前のフレームの後と違えば # ext を書く。
  `pub def checkExternalChange(rec: Recorder, fingerprint: Option[String]): Unit \ IO`
- 記録の行で World を変えた（start・reload…）後の指紋の元を覚え直す（# ext を誤って書かない）。
  `pub def resetFingerprint(rec: Recorder, fingerprint: Option[String]): Unit \ IO`
- 実機のフレーム 1 つ（App.traceFrame に渡した Frame そのもの）と、そのフレームの後の指紋の元。
  `pub def frame(rec: Recorder, frame: App.Frame, fingerprint: Option[String]): Unit \ IO`
- 始まりの行（引数の値が空白や # を含むか b64: で始まるなら b64: にする）と、読んだファイル。
  `pub def startLine(name: String, args: Map[String, String], files: Map[String, Flow.File]): String`
- 保存・F1 で読み直した行（target = 監視のパスか key）。
  `pub def reloadLine(target: String, files: Map[String, Flow.File]): String`
- onRequest のルートが World を変えた行（クエリは b64 にまとめる）。
  `pub def requestLine(path: String, params: Map[String, String], files: Map[String, Flow.File]): String`
- f を流し、その間に Fs.FileRead で読んだファイルの中身（読めなかった物は Missing）を拾う。
  `pub def captureReads(f: Unit -> a \ ef): (a, Map[String, Flow.File]) \ ef + Fs.FileRead`
- F8 のチケットの写し: ここまでの記録に「表示中の瞬間まで戻る」（rewind back）と mark ticket を足して
  `pub def copyInto(rec: Recorder, dir: String, back: Int32): Bool \ IO`
- ここまでの記録を dir/record.flow に写し、末尾に comment・back コマ戻る rewind・mark <name> を足す。
  `pub def copyMarked(rec: Recorder, dir: String, back: Int32, comment: String, name: String): Bool \ IO`
- 記録を閉じる（まとめている行を書き出す）。
  `pub def close(rec: Recorder): Unit \ IO`

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
- 時刻 t に見えている粒 1 つ。絵（sample）と同じ式から出るので、描いた所と当たる所はずれない。
  `pub type alias Particle = { emitter = String, index = Int32, cycle = Int64, center = Vec2.Vec2, size = Float64, alpha = Float64 }`
- 時刻 t 秒に見えている粒の一覧（sample と同じ粒・同じ並び。見えない粒 = 大きさか濃さが 0 の粒は入らない）。
  `pub def particles(spec: FxDoc.Spec, seed: Int64, t: Float64): List[Particle]`
- particles の中心を at へ平行移動した物（sampleAt と同じ置き方）。
  `pub def particlesAt(spec: FxDoc.Spec, seed: Int64, t: Float64, at: Vec2.Vec2): List[Particle]`
- 進行中の burst 全部の、時刻 now の粒（drawAll と同じ時刻の取り方）。
  `pub def particlesOfAll(now: Float64, bursts: List[Burst]): List[Particle]`
- 円（中心と半径）が粒（直径 size の円とみなす）に重なるか。
  `pub def touches(circle: { center = Vec2.Vec2, radius = Float64 }, particle: Particle): Bool`

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
- indexOf / pickBy の鍵。index = 何番目の物か（敵の番号・日付・タイルの通し番号）、
  `pub type alias Key = { index = Int32, channel = Int32 }`
- 鍵から 0..n-1 の添字を 1 つ選ぶ（n <= 0 なら 0）。同じ鍵と n なら毎回同じ。
  `pub def indexOf(key: Key, n: Int32): Int32`
- 鍵で列から 1 つ選ぶ（空なら None）。台詞の差分・敵の出す技・タイルの柄を、乱数の状態を
  `pub def pickBy(key: Key, xs: List[a]): Option[a]`

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

## HoldPress — `engine_world/src/HoldPress.flix`
- 貯まった秒・いま貯めているか（ゲージを出すか）・合図を出した後で離すのを待っているか。
  `pub type alias HoldPress = { charge = Float64, holding = Bool, latched = Bool }`
- seconds = 合図までに押し続ける秒、drain = 離したときに戻る速さ（押す速さの何倍か）。
  `pub type alias Config = { seconds = Float64, drain = Float64 }`
- `pub def empty(): HoldPress`
- 1 フレーム分。held = キーを押しているか、enabled = いま長押しを受け付ける画面か。
  `pub def step(cfg: Config, held: Bool, enabled: Bool, dt: Float64, s: HoldPress): (HoldPress, Bool)`
- ゲージがどこまで満ちたか（0 → 1）。
  `pub def progress(cfg: Config, s: HoldPress): Float64`
- 貯めた秒を捨てる（確認の窓を開いた・場面が切り替わった）。離すのを待つ印は残す。
  `pub def cleared(s: HoldPress): HoldPress`

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
- 時計 c で測る寿命（誕生時刻は Clock.Time[c]）。
  `pub type alias Span[c] = { startedAt = Clock.Time[c], dur = Float64 }`
- 時刻 now（Clock.nowOf(w#play) や frame#realNow）に、長さ dur で発火する。
  `pub def fireOn(now: Clock.Time[c], dur: Float64): Span[c]`
- 進行度 0..1（progressOf と同じ）を、寿命と同じ時計の今で読む。
  `pub def progressOn(now: Clock.Time[c], l: Span[c]): Float64`
- まだ再生中か（alive と同じ）を、寿命と同じ時計の今で読む。
  `pub def aliveOn(now: Clock.Time[c], l: Span[c]): Bool`
- 残り秒（remaining と同じ）を、寿命と同じ時計の今で読む。
  `pub def remainingOn(now: Clock.Time[c], l: Span[c]): Float64`

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

## Loop — `engine_world/src/Loop.flix`
- 鳴り続ける音の音量と高さ。volume は 0.0〜1.0、pitch は 1.0 = 元のまま・2.0 で 1 オクターブ上。
  `pub type alias Mix = { volume = Float64, pitch = Float64 }`
- 元の音量・元の高さ。
  `pub def plain(): Mix`
- f の中で宣言した音を、宣言した順の App.Sustain の列にする（App.withSustained に渡す形）。
  `pub def collect(nameOf: s -> String, f: Unit -> Unit \ ef): List[App.Sustain] \ (ef - Loop[s])`

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
- `pub def write(path: String, spec: { note = String, colors = Map[String, Color] }): Result[String, Unit] \ { Fs.FileRead, Fs.FileWrite }`
- path に text と同じ中身がもうあるか（読めない・無いときは false）。
  `pub def isSameAsOnDisk(path: String, text: String): Bool \ Fs.FileRead`

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

## PropertyTest — `engine_world/src/PropertyTest.flix`
- 1 回分の入力。r はゲームの役の enum。マウスは左ボタン 1 つ。
  `pub enum Input[r] { case Idle(Float64) case Tap(r) case Hold(r) case Release(r) case Move(Vec2.Vec2) case Press(Vec2.Vec2) case Drag(Vec2.Vec2) case Up case Wheel(Float64) }`
- 入力の列の作り方。どの候補も、空ならその種類の入力は出ない。
  `pub type alias Spec[r] = { taps = List[r], holds = List[r], idle = Int32, dts = List[Float64], points = List[Vec2.Vec2], wheels = List[Float64] }`
- 入力を Frame にする材料。keyOf = 役 → いまのキー・viewport = design 解像度・dt = 押すフレームの経過秒。
  `pub type alias Setup[r, w] = { keyOf = (r, w) -> Key, viewport = Vec2.Vec2, dt = Float64 }`
- forAll が試す範囲。種 1..seeds のそれぞれで length 個の入力を spec から作る。
  `pub type alias Cases[r] = { seeds = Int32, length = Int32, spec = Spec[r] }`
- 決まりが崩れた所。frame = 何フレーム目か（0 から。挟んだ離すフレームも数える）・
  `pub type alias Broken[r] = { frame = Int32, why = String, inputs = List[Input[r]] }`
- 何もしない Spec（何も触らないフレームだけ）。{ taps = … | emptySpec() } で必要な欄だけ書く。
  `pub def emptySpec(): Spec[r]`
- 種で決まる length 個の入力の列。
  `pub def generate(seed: Int64, length: Int32, spec: Spec[r]): List[Input[r]]`
- 列を流した全部のフレーム（先頭から）。
  `pub def traceOf(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w): List[App.TraceStep[w]] \ ef with Eq[r]`
- 列を流した後の World。
  `pub def finalOf(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w): w \ ef with Eq[r]`
- 決まり rule が崩れた最初のフレーム。崩れなければ None。
  `pub def firstBroken(app: App.App[w, ef], setup: Setup[r, w], inputs: List[Input[r]], start: w, rule: App.TraceStep[w] -> Option[String]): Option[Broken[r]] \ ef with Eq[r]`
- 種 1, 2, …, count のうち、check が最初に崩れを返した種とその中身。全部通れば None。
  `pub def firstFailingSeed(count: Int32, check: Int64 -> Option[a] \ ef): Option[(Int64, a)] \ ef`
- cases の全部の種で列を作って流し、rule が崩れた最初の所の説明（種・フレーム・入力の数・rule の説明）。
  `pub def forAll(app: App.App[w, ef], setup: Setup[r, w], cases: Cases[r], start: w, rule: App.TraceStep[w] -> Option[String]): Option[String] \ ef with Eq[r]`

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

## Render — `engine_world/src/Render.flix`
- 傾き（rotation）の単位は「回転数」— 1 周 = 1.0・正で時計回り。ラジアンへの変換は
  `pub enum Item { case Sprite({ texture = String, tint = Color, alpha = Float64, scale = Vec2.Vec2, rotation = Float64, centered = Bool, flipH = Bool, flipV = Bool, regionRect = Option[Rect2.Rect2], zIndex = Int32, blend = DrawCmd.BlendMode, maskPolys = List[List[Vec2.Vec2]] }) case Text({ text = String, fontAtlas = FontAtlas, fontSize = Float64, tint = Color, alpha = Float64, rotation = Float64, zIndex = Int32, wrapWidth = Option[Float64] }) case Box({ size = Vec2.Vec2, color = Color, alpha = Float64, rotation = Float64, style = Option[GameEngine.BoxStyle], zIndex = Int32, blend = DrawCmd.BlendMode }) case Poly({ vertices = List[Vec2.Vec2], color = Color, alpha = Float64, zIndex = Int32, blend = DrawCmd.BlendMode, grad = Option[List[DrawCmd.VertexTint]] }) case Clipped({ rect = Rect2.Rect2, inner = Item }) case Shader({ rect = Rect2.Rect2, spec = ShaderDoc.Spec, t = Float64, mask = List[List[Vec2.Vec2]], zIndex = Int32, blend = DrawCmd.BlendMode, alpha = Float64 }) }`
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
- 透明度（alpha）を指定した値にする（Sprite / Box / Poly / Text に効く。Text は字の画素の濃さ）。
  `pub def fade(alpha: Float64, item: Item): Item`
- 置き場所はそのままに、中身（Item）だけ入れ替える。`fade` や `rounded` のような
  `pub def overItem(f: Item -> Item \ ef, placed: PlacedItem): PlacedItem \ ef`
- 組み上がった列を丸ごと薄くする（`fade` の列版）。覆い・淡い層・消えていく残像に使う。
  `pub def fadeAll(alpha: Float64, items: List[PlacedItem]): List[PlacedItem]`
- ピクセルの重ね方を変える（Sprite / Box / Poly に効く。Text は文字の可読性が第一で対象外）。
  `pub def blended(mode: DrawCmd.BlendMode, item: Item): Item`
- 描画物 1 つの重なり順（Clipped は中身の z）。
  `pub def zOf(item: Item): Int32`
- 組み上がった列を丸ごと d だけ動かす。
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
- 面（Item.Shader）の後ろに同じ zIndex の他の描き物を並べた z（小さい順）。描き手は同じ z の中を
  `pub def surfaceZShared(items: List[PlacedItem]): List[Int32]`
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

## Resources — `engine_world/src/Resources.flix`
- 描く元 res と、遊びの状態 w の組。
  `pub type alias With[res, w] = { resources = res, world = w }`
- 組を作る（起動の時・テスト・描き出し）。
  `pub def of(res: res, w: w): With[res, w]`
- 描く元を読み、World だけを返す関数を、組を受けて組を返す関数にする（描く元はそのまま渡る）。
  `pub def mapWorld(f: (res, w) -> w \ ef, h: With[res, w]): With[res, w] \ ef`
- 系: (Frame, res, w) -> w を App の系にする。
  `pub def system(f: (App.Frame, res, w) -> w \ ef, frame: App.Frame, h: With[res, w]): With[res, w] \ ef`
- 絵: ViewCtx・描く元・World から絵を組む。
  `pub def view(f: (App.ViewCtx, res, w) -> List[Render.PlacedItem] \ ef, ctx: App.ViewCtx, h: With[res, w]): List[Render.PlacedItem] \ ef`
- 読むだけの口（組を受けて値を返す App の口）へ渡す包み。
  `pub def read(f: (res, w) -> a \ ef, h: With[res, w]): a \ ef`
- 描く元を替える読み直しの行: reload で描く元を読み直し、settle で替わった描く元に World を収める
  `pub def reloadRow(docId: String, path: String, reload: res -> res \ Fs.FileRead, settle: (res, w) -> w): DocTable.Entry[With[res, w]]`
- reloadRow の、Studio に名乗らない行（Doc の編集口を持たないファイル）。
  `pub def reloadUnnamedRow(path: String, reload: res -> res \ Fs.FileRead, settle: (res, w) -> w): DocTable.Entry[With[res, w]]`
- 時計: App.addClock と同じ形（違うのは paceOf が (res, w) を受けることだけ）。時計は World の欄のまま。
  `pub def addClock(spec: { clockOf = w -> Clock.Clock[c], withClock = (Clock.Clock[c], w) -> w, paceOf = (res, w) -> Clock.Pace[c, why] }, app: App.App[With[res, w], ef]): App.App[With[res, w], ef]`
- 始まりの登録簿の 1 行（App.Start の、build が描く元も受ける形）。build は描く元を読んで World を組む。
  `pub type alias Start[res, w] = { name = String, doc = String, args = Map[String, String], build = (res, w, Map[String, String]) -> Result[String, w] }`
- 始まりの登録簿の 1 行を組の行へ持ち上げる（build は World を組み、描く元はそのまま）。
  `pub def liftStart(start: Start[res, w]): App.Start[With[res, w]]`
- 外へ書く出力を組の出力へ持ち上げる（鍵と書く物は World から）。
  `pub def liftOutput(output: App.Output[w]): App.Output[With[res, w]]`

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
- ルビ 1 つ。start = 親字の頭（plainText の何文字目・0 始まり）、length = 親字の数、text = ふりがな。
  `pub type alias Ruby = { start = Int32, length = Int32, text = String }`
- ルビつきで折った時の行数（ページ割り・窓の高さの勘定。字幅の決まりは wrapLinesBy と同じ）。
  `pub def rubyLineCountBy(charWidth: Char -> Float64, rubyWidth: String -> Float64, rubySize: Float64, maxWidth: Float64, rubies: List[Ruby], spans: List[Span]): Int32`
- ルビつきの字を置く。親字の上に rubySize の字でふりがなを中央そろえで載せる（親字より広ければ親字を中央へ寄せる）。
  `pub def placeRuby(p: Placement, rubySize: Float64, rubies: List[Ruby], visible: Int32, spans: List[Span]): List[Render.PlacedItem]`

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

## Sfx — `engine_world/src/Sfx.flix`
- f の中で鳴らした音を、鳴らした順の名前の列にする（App.withAudio に渡す形）。
  `pub def collect(nameOf: s -> String, f: Unit -> Unit \ ef): List[String] \ (ef - Sfx[s])`

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

## SortingLayer — `engine_world/src/SortingLayer.flix`
- `pub type alias Hits[a] = HitList[a]`
- 当たりの読み出し（hitAt・toList の結果）。rect = None は画面全体（hitAnywhere・modal の窓の外）。
  `pub type alias Picked[a] = { target = a, rect = Option[Rect2.Rect2] }`
- 層の底の z（順番 0）。
  `pub def bottom(layer: t): Int32 with SortingLayer[t]`
- 層の天井の z。
  `pub def top(layer: t): Int32 with SortingLayer[t]`
- 層ごとの木を 1 本の絵の列にする。各層の木はその層の底から積み、topLayer で送った物は送り先の層の
  `pub def compose(ctx: App.ViewCtx, entries: List[(t, Tree[t, a])]): List[Render.PlacedItem] with SortingLayer[t], ToString[t]`
- 木に積んだ当たり（ZStack.hit・hitAnywhere・blocking・modal）の列。前後は compose と同じ道筋で決まる
  `pub def hitsOf(entries: List[(t, Tree[t, a])]): Hits[a] with SortingLayer[t], ToString[t]`
- point の下のいちばん手前の押せる物（無い・窓が塞いでいる所は None）。`pickIn(point, hitsOf(entries))`。
  `pub def pickFrom(point: Vec2.Vec2, entries: List[(t, Tree[t, a])]): Option[a] with SortingLayer[t], ToString[t]`
- point の下のいちばん手前の押せる物。
  `pub def pickIn(point: Vec2.Vec2, hits: Hits[a]): Option[a]`
- point の下のいちばん手前の押せる物と、その矩形（押せる物を光らせる絵に使う）。
  `pub def hitAt(point: Vec2.Vec2, hits: Hits[a]): Option[Picked[a]]`
- front（HUD など、いつも手前の木の当たり）を back の手前に重ねる。
  `pub def over(front: Hits[a], back: Hits[a]): Hits[a]`
- 押せる物の一覧（手前 → 奥。塞ぐだけの当たりは出さない）。描き出しでマウスを置く所を探すとき用。
  `pub def toList(hits: Hits[a]): List[Picked[a]]`
- 0.39 で消す —— 当たりは描く木に ZStack.hit で積み、pickFrom で選ぶ（この口は描く木と別の表を書かせる）。
  `pub def pick(point: Vec2.Vec2, entries: List[(t, List[(a, Rect2.Rect2)])]): Option[a] with SortingLayer[t]`
- 1 つの層だけの compose。
  `pub def stack(ctx: App.ViewCtx, layer: t, tree: Tree[t, a]): List[Render.PlacedItem] with SortingLayer[t], ToString[t]`
- 表の決まりをテストで確かめる用: 奥から手前へ並べた層が、どれも底 <= 天井で、隣どうし交ざらずに上がっていくか。
  `pub def isStacked(layers: List[t]): Bool with SortingLayer[t]`
- 表の決まりをテストで確かめる用: どの層も outer（底, 天井）の中に収まるか。
  `pub def isWithin(outer: (Int32, Int32), layers: List[t]): Bool with SortingLayer[t]`

## Steering — `engine_world/src/Steering.flix`
- target から流した距離場を 1 歩下る = target へ最短で近づく隣のマス。
  `pub def chase(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32), target: (Int32, Int32), limit: Int32): Option[(Int32, Int32)]`
- threat から遠ざかる 1 歩。距離場でいまより遠くなる隣のうち、一番遠いものを選ぶ。
  `pub def flee(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32), threat: (Int32, Int32), limit: Int32): Option[(Int32, Int32)]`
- 気の向くままの 1 歩。何歩目か（beat）と塩（salt）のハッシュで向きを引くので、
  `pub def wander(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32), beat: Int32, salt: Int32): Option[(Int32, Int32)]`

## Suggest — `engine_world/src/Suggest.flix`
- a と b の編集距離（大文字小文字は区別しない）。隣り合う 2 字の入れ替え（tpa → tap）も 1 と数える。
  `pub def distance(a: String, b: String): Int32`
- known のうち name に近い名前（距離 2 以内（3 字以下の名前は 1 以内）か、2 字以上の頭が同じ物）を近い順に 3 つまで。
  `pub def near(name: String, known: List[String]): List[String]`
- 知らせの後ろに付ける 1 句: 近い名前があれば「（もしかして: a / b）」、無ければ使える名前を 12 個まで。
  `pub def hint(name: String, known: List[String]): String`

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

## TimeScale — `engine_world/src/TimeScale.flix`
- 区間 1 つ: dur 実秒のあいだ、時間を scale 倍（0 に近いほど止まる、1 = 等速）で流す。
  `pub type alias Segment = { dur = Float64, scale = Float64 }`
- 区間の列（頭から順）と、最後の区間の速さから等速へなめらかに戻す実秒 ramp。
  `pub type alias Plan = { segments = List[Segment], ramp = Float64 }`
- `pub def segment(dur: Float64, scale: Float64): Segment`
- 「止める → 遅く流す → 戻す」のよくある形の秒と速さ（freeze 秒を freezeScale 倍、
  `pub type alias FreezeThenSlow = { freeze = Float64, freezeScale = Float64, slow = Float64, slowScale = Float64, ramp = Float64 }`
- FreezeThenSlow から区間の列を作る。長さ 0 の区間は無い物として扱う。
  `pub def freezeThenSlow(f: FreezeThenSlow): Plan`
- 区間の合計（実秒）。この後に ramp 秒かけて等速へ戻る（寄りを引く・光を消す拍を合わせるときに読む）。
  `pub def heldOf(p: Plan): Float64`
- 合図から実秒 r までにゲームの時計が進む秒（時間の速さを 0 から r まで足し上げた物。
  `pub def gameAt(p: Plan, r: Float64): Float64`
- ゲームの時計が合図から g 秒進んだのは、実時間で何秒後か（gameAt の逆。
  `pub def realAt(p: Plan, g: Float64): Float64`
- 実時間 dt に対して、ゲームの時計を進める秒。age = いまのゲームの時計 − 合図の時刻。
  `pub def gameDt(p: Plan, age: Float64, dt: Float64): Float64`
- 全部の秒を k 倍する（「はやさ」の設定）。速さ（scale）は変えない。
  `pub def scaled(k: Float64, p: Plan): Plan`

## Timeline — `engine_world/src/Timeline.flix`
- 組み上がった時刻表。sounds は (時刻, 書いた順) の昇順。
  `pub enum Timeline[a] { case Timeline({ clips = Map[a, Clip[a]], segments = Map[a, Int32], sounds = Vector[SoundAt], waits = List[Float64], fitted = Map[String, Float64], duration = Float64 }) }`
- クリップ: start 秒に始まり dur 秒続く。tag = 拍の名前か出来事（ゲームの enum。文字列にしないのは、
  `pub type alias Clip[a] = { tag = a, start = Float64, dur = Float64 }`
- クリップを値として作る（表に無い名前の既定値など。長さは負にしない）。
  `pub def clip(tag: a, start: Float64, dur: Float64): Clip[a]`
- 曲の速さ。拍と小節を秒へ直すのはここだけ（譜面の bpm をそのまま渡す）。
  `pub type alias Tempo = { bpm = Float64, beatsPerBar = Int32, hasBeat = Bool }`
- テンポ。bpm は 1 未満にしない（0 で割らない）・1 小節の拍数は 1 未満にしない。
  `pub def tempo(bpm: Float64, beatsPerBar: Int32): Tempo`
- 拍を書かない表（秒だけで並べる表）に渡すテンポ。拍・小節で書いた行（Beats・Bars・ToNextBar・
  `pub def noTempo(): Tempo`
- 長さの書き方。
  `pub enum Duration with Eq { case Seconds(Float64) case Beats(Float64) case Bars(Float64) case ToNextBar case ToBeat(Float64) case ToPickup(Float64) }`
- クリップを置く基準。
  `pub enum Place[a] { case End case WithPrevious case AtStartOf(a) case AtEndOf(a) case At(Duration) case AfterAll(List[(Place[a], Duration)]) }`
- クリップの中で鳴らす効果音。fitted = 書き出す WAV の長さをこのクリップの長さに合わせる音。
  `pub type alias Cue = { sound = String, offset = Duration, fitted = Bool }`
- 書く人が並べる 1 行。place から delay だけ遅らせて置き、length だけ続く。
  `pub type alias Step[a] = { tag = a, place = Place[a], delay = Duration, length = Duration, cues = List[Cue], isWait = Bool }`
- 書き間違い。tag はコードの enum なので、黙って既定の位置へ置かずに止める。
  `pub enum BuildError[a] with Eq, ToString { case DuplicateTag(a) case UnknownAnchor(a) case SoundOnWait(a) case FittedLengthConflict(String) case PlacedBeforeWait(a) case BeatsWithoutTempo(a) }`
- 表の終わりに並べる。
  `pub def append(tag: a, length: Duration): Step[a]`
- 直前に書いた行と同時に始める。
  `pub def join(tag: a, length: Duration): Step[a]`
- anchor のクリップの頭に置く。
  `pub def atStartOf(anchor: a, tag: a, length: Duration): Step[a]`
- anchor のクリップの終わりに置く。
  `pub def atEndOf(anchor: a, tag: a, length: Duration): Step[a]`
- 表の頭から at の時刻に置く（DOTween の Insert・GSAP の時刻を書いた置き方）。重ねて置くクリップに使う。
  `pub def insert(at: Duration, tag: a, length: Duration): Step[a]`
- anchors の全部が済んだ後に置く（基準ごとに間を書ける）。どれの後に始まるかが拍ごとに変わる表
  `pub def afterAll(anchors: List[(Place[a], Duration)], tag: a, length: Duration): Step[a]`
- 表の終わりで待つ。後ろの行はここから数える。
  `pub def waitFor(tag: a): Step[a]`
- 置き場所から遅らせる（GSAP の "+=0.5"）。
  `pub def withDelay(delay: Duration, s: Step[a]): Step[a]`
- クリップの頭で鳴らす。
  `pub def withSound(name: String, s: Step[a]): Step[a]`
- クリップの頭から offset 遅れて鳴らす。
  `pub def withSoundAt(name: String, offset: Duration, s: Step[a]): Step[a]`
- クリップの頭で鳴らし、書き出す WAV の長さをクリップの長さに合わせる（soundLengthOf で引く）。
  `pub def withFittedSound(name: String, s: Step[a]): Step[a]`
- 時刻表の上の位置。拍の分と秒の分を別々に足し、秒へ直すのは最後の 1 回だけ
  `pub type alias Pos = { beats = Float64, seconds = Float64 }`
- 長さを秒へ直す（表の頭から測る ToNextBar / ToBeat は頭から数えた長さ）。
  `pub def secondsOf(tempo: Tempo, d: Duration): Float64`
- 並べた行を秒の時刻表にする。前の行にしか頼らないので 1 回の走査で決まる。
  `pub def build(tempo: Tempo, steps: List[Step[a]]): Result[List[BuildError[a]], Timeline[a]] with Order[a]`
- build の、書き間違いで止める包み。並びをゲームのコードが書く表（Doc は長さしか持たない）では、Err は
  `pub def buildOrPanic(name: String, tempo: Tempo, steps: List[Step[a]]): Timeline[a] with Order[a], ToString[a]`
- `pub def buildOrBug(name: String, tempo: Tempo, steps: List[Step[a]]): Timeline[a] with Order[a], ToString[a]`
- 鳴らす予定の効果音（秒）。
  `pub type alias SoundAt = { at = Float64, segment = Int32, sound = String }`
- 再生位置: 時刻表の上の時刻 t と、解いた待ちの数 passed。待ちの位置ちょうどでは、
  `pub type alias Playhead = { t = Float64, passed = Int32 }`
- 待ちの無い表の再生位置。
  `pub def playheadAt(t: Float64): Playhead`
- クリップの中のどこにいるか。
  `pub enum ClipState with Eq, ToString { case Before case Active(Float64) case After }`
- フレームの進め方。Enter = 場面の最初のフレーム（頭ちょうどの音も鳴らす）・Play = ふつうに進む・
  `pub enum Playback with Eq { case Enter case Play case Seek }`
- 時刻表が終わる時刻（秒）。クリップより後ろの音も含む。
  `pub def endOf(tl: Timeline[a]): Float64`
- タグのクリップ（秒）。
  `pub def clipOf(tag: a, tl: Timeline[a]): Option[Clip[a]] with Order[a]`
- クリップの列（開始の順。同じ時刻は tag の順）。全部のクリップを順に見る所（索引・ログ）に。
  `pub def clipsOf(tl: Timeline[a]): List[Clip[a]]`
- 時刻 t にタグのクリップのどこにいるか。境目は soundsOn と同じ (start で Active・長さ 0 なら After)。
  `pub def stateOf(tag: a, head: Playhead, tl: Timeline[a]): ClipState with Order[a]`
- 進み 0..1（前は 0・後は 1）。
  `pub def progressOf(tag: a, head: Playhead, tl: Timeline[a]): Float64 with Order[a]`
- 前のフレームの時刻 prev から今の now までに鳴らす効果音。区間は
  `pub def soundsOn(playback: Playback, prev: Playhead, now: Playhead, tl: Timeline[a]): List[String]`
- 待ちの無い表で、前のフレームの秒 prev から今の now までに鳴らす効果音（soundsOn の Play と同じ (prev, now]）。
  `pub def soundsBetween(prev: Float64, now: Float64, tl: Timeline[a]): List[String]`
- 起点 at（演出を始めた World の時刻）から測る時刻表で、1 フレームの前後の時刻
  `pub def soundsSince(at: Float64, beforeNow: Float64, afterNow: Float64, tl: Timeline[a]): List[String]`
- 起点 at から測った時刻 now での、タグのクリップの進み 0..1（progressOf と同じ境目）。
  `pub def progressSince(at: Float64, now: Float64, tag: a, tl: Timeline[a]): Float64 with Order[a]`
- 起点 at（時計 c の時刻）から測る待ちの無い表で、時計 clock のこのフレーム (prev, now] に鳴らす効果音。
  `pub def soundsOnClock(clock: Clock.Clock[c], at: Clock.Time[c], tl: Timeline[a]): List[String]`
- 時計を持たない時刻（App が配る実時間 frame#realNow）で鳴らす口。前後の今は withAudio の before / after の欄から渡す
  `pub def soundsBetweenTimes(at: Clock.Time[c], frame: { before = Clock.Time[c], after = Clock.Time[c] }, tl: Timeline[a]): List[String]`
- 起点 at から測る表の、時計 clock の今でのタグのクリップの進み 0..1（progressSince と同じ境目）。
  `pub def progressOn(clock: Clock.Clock[c], at: Clock.Time[c], tag: a, tl: Timeline[a]): Float64 with Order[a]`
- 長さを合わせる音（withFittedSound）を書き出すときの長さ（秒）。
  `pub def soundLengthOf(name: String, tl: Timeline[a]): Option[Float64]`
- 場面の時計 wall と、待ちが解けた時刻の列から、時刻表の上の時刻を出す。解けていない待ちでは
  `pub def playheadOf(wall: Float64, resumes: List[Float64], tl: Timeline[a]): Playhead`
- いま解けていない待ちで止まっているか。
  `pub def isWaiting(wall: Float64, resumes: List[Float64], tl: Timeline[a]): Bool`
- 決定キーを押した。待ちで止まっている間だけ解いた時刻を記録する（待ちに着く前の早押しは数えない）。
  `pub def resume(wall: Float64, resumes: List[Float64], tl: Timeline[a]): List[Float64]`

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
- 字の実寸を atlasOf で測ってレイアウトする hitTestUi（UiRender.itemsWith と同じ枠なので、描いた所で当たる。
  `pub def hitTestUiWith(atlasOf: String -> FontAtlas \ ef, ui: UiStore.UiWorld, design: Vec2.Vec2, point: Vec2.Vec2): Option[EntityId] \ ef`
- UiWorld 全体を design 空間でレイアウトした、面積のある entity の画面矩形
  `pub def layoutRects(ui: UiStore.UiWorld, design: Vec2.Vec2): Map[EntityId, Rect2.Rect2]`
- 字の実寸を atlasOf で測ってレイアウトした画面矩形（UiRender.itemsWith が描く枠と同じ。字だけの要素も入る）。
  `pub def layoutRectsWith(atlasOf: String -> FontAtlas \ ef, ui: UiStore.UiWorld, design: Vec2.Vec2): Map[EntityId, Rect2.Rect2] \ ef`

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
- 字の実寸を atlasOf で測った枠で組む targetsOfUi（字の兄弟の後ろの項目も、描いた所の枠になる）。
  `pub def targetsOfUiWith(atlasOf: String -> FontAtlas \ ef, listPath: String, ui: UiStore.UiWorld, design: Vec2.Vec2): List[Target[String]] \ ef`

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

## Yarn — `engine_world/src/Yarn.flix`
- 行がどこにあるか。file = ゲームのルートからの .yarn のパス、line = 1 始まりの行番号。
  `pub type alias Source = { file = String, line = Int32 }`
- #key:value のタグ（値の無い #key は value が空）。
  `pub type alias Tag = { key = String, value = String }`
- 台詞 1 行。speaker = 話し手の id（地の文は空）、text = 出す字（エスケープは解いてある）、
  `pub type alias Line = { speaker = String, text = String, parts = List[Part], tags = List[Tag], source = Source }`
- 行の 1 切れ。Literal = 書いたとおりの字、Insert = {式}（値を字にして差し込む）、
  `pub enum Part { case Literal(String) case Insert(Expr) case Markup(String, String) case Close(String) }`
- マークアップ 1 つ（公式の MarkupAttribute）。start = text の何文字目から（0 始まり・String.length の数え方）、
  `pub type alias Markup = { name = String, value = String, start = Int32, length = Int32 }`
- 変数と式の値（公式と同じ 3 つの型。型は build の check が合わせてある）。
  `pub enum Value with Eq, ToString { case Number(Float64) case Bool(Bool) case Text(String) }`
- 式。Visited / VisitCount はノードを出た回数を見る（公式の visited("…")・visited_count("…")）。
  `pub enum Expr { case Constant(Value) case Variable(String) case Visited(String) case VisitCount(String) case Not(Expr) case Negate(Expr) case And(Expr, Expr) case Or(Expr, Expr) case Binary(Operator, Expr, Expr) }`
- and / or の他の、2 つの値をとる演算（and / or は右を見るのが左で決まらない時だけなので Expr の case に分けてある）。
  `pub enum Operator with Eq { case Add case Subtract case Multiply case Divide case Remainder case Equal case NotEqual case Less case LessEqual case Greater case GreaterEqual }`
- <<名前 引数…>>。エンジンが自分で扱うのは wait（YarnRunner が待つ）だけ。
  `pub type alias Command = { name = String, args = List[String], tags = List[Tag], source = Source }`
- 本文の 1 文。
  `pub enum Statement { case Say(Line) case Choose(List[Choice]) case Jump(String, Source) case Stop(Source) case Command(Command) case Set(String, Expr, Source) case If(List[Branch], Source) }`
- 選択肢 1 つ。line = 出す字と話し手・タグ、condition = 行末の <<if>>（偽なら選べない印で並ぶ）、body = 選んだ時に流す中身。
  `pub type alias Choice = { line = Line, condition = Option[Expr], body = List[Statement] }`
- <<if>> の枝 1 つ。
  `pub type alias Branch = { condition = Expr, body = List[Statement] }`
- <<declare>> 1 つ。value = 初めの値（型もこれで決まる）。
  `pub type alias Declaration = { value = Value, source = Source }`
- ノード（title: 〜 === の 1 つ）。headers は title 以外のヘッダ（読むだけ）。
  `pub type alias Node = { title = String, headers = List[(String, String)], body = List[Statement], source = Source }`
- シナリオ 1 つ分（フォルダの .yarn 全部）。
  `pub type alias Program = Nodes`
- 木の JSON の形の版（go/internal/yarn/tree.go の Version と同じ）。これ以下の版を読む。
  `pub def version(): Int32`
- ノードの無いシナリオ（どのノードを開いても、すぐ終わる）。
  `pub def empty(): Program`
- `pub def nodeOf(name: String, program: Program): Option[Node]`
- ノード名の一覧（名前の順）。
  `pub def nodeNames(program: Program): List[String]`
- 変数の宣言（<<declare>> が無ければ None）。
  `pub def declarationOf(name: String, program: Program): Option[Declaration]`
- 宣言した変数の名前と初めの値（名前の順）。
  `pub def variablesOf(program: Program): List[(String, Value)]`
- 値を台詞に差し込む字にする（公式と同じ: 数は整数なら小数点を付けない・真偽は True / False）。
  `pub def toText(value: Value): String`
- file の line 行を中に持つノードの名前（そのファイルで title: の行が line 以下の、いちばん後のノード）。
  `pub def nodeAtLine(file: String, line: Int32, program: Program): Option[String]`
- 行のマークアップ（書いた順）。{式} は値の字の長さで数える（YarnRunner の出来事の Line は値を入れてある）。
  `pub def markupOf(line: Line): List[Markup]`
- 行のルビ（[ruby=よみ]字[/ruby]）を RichText.placeRuby に渡す形で。
  `pub def rubiesOf(line: Line): List[RichText.Ruby]`
- 字の切れだけをつないだ字（{式} とマークアップは字にしない）。
  `pub def plainTextOf(parts: List[Part]): String`
- タグの値（そのキーのタグが無ければ None・値の無いタグは Some("")）。
  `pub def tagOf(key: String, tags: List[Tag]): Option[String]`
- 「ファイル:行」（F8 のチケットやログに出す形）。
  `pub def sourceText(source: Source): String`
- 木の JSON の文字からシナリオへ。形が違う・版が違う時は None（文を 1 つ落として続けると、台詞が知らせずに欠ける）。
  `pub def fromJson(text: String): Option[Program]`
- path の木を読む。読めない・壊れている時は fallback（fail-open）。
  `pub def loadOr(fallback: Program, path: String): Program \ Fs.FileRead`
- JSON の数・真偽・文字列を値に（YarnStorage のセーブも同じ形）。
  `pub def valueFromJson(json: Json): Option[Value]`
- 値を JSON の数・真偽・文字列に。
  `pub def valueToJson(value: Value): Json`
- speakers = 話し手の id、nodes = コードが開くノード、tags = タグのキーと取れる値（空なら値を書かない #key）、
  `pub type alias Vocab = { speakers = List[String], nodes = List[String], tags = List[(String, List[String])], commands = List[String] }`
- enum の全部の値を名前の一覧にする（語彙の欄を作る所で使う）。
  `pub def namesOf(name: a -> String, values: List[a]): List[String]`
- 語彙を vocab.json の形にする（キーの順は固定。flow の e2e/vocab.json と同じ書き方）。
  `pub def vocabJson(vocab: Vocab): String`
- 語彙を path に書く（書けたか）。ゲームの Talk.vocab が呼ぶ（bin/headless-run が jar を作った時・make talk-vocab）。
  `pub def writeVocab(path: String, vocab: Vocab): Bool \ Fs.FileWrite`

## YarnRunner — `engine_world/src/YarnRunner.flix`
- 呼び出しの間に起きた出来事。
  `pub enum Event { case Line(Yarn.Line) case Choices(List[DialogueOption]) case Command(Yarn.Command) case Done }`
- 出した選択肢 1 つ（公式の DialogueOption）。available = 行末の <<if>> が真か。偽の物も並びに残し、
  `pub type alias DialogueOption = { line = Yarn.Line, available = Bool }`
- 実行器への入力。Choose の番号は 0 始まり。
  `pub enum Action with Eq, ToString { case Advance case Choose(Int32) case Tick }`
- 今出している物。Closed = 開いていない・終わった、Waiting = <<wait>> の途中。
  `pub enum Shown { case Closed case Line(Yarn.Line) case Choices(List[DialogueOption]) case Waiting }`
- 読んでいる所のブックマーク（セーブに入れる物）。node = 開いているノード、storage = そのノードに入った時の変数と訪れた数、
  `pub type alias Bookmark = { node = String, storage = YarnStorage.Storage, steps = List[Action] }`
- 実行器。c は <<wait>> を測る時計の名前（ゲームの物語の時計など）。外では start と closed だけが作る。
  `pub type alias Runner[c] = Machine[c]`
- 開いていない実行器（World の初期値）。
  `pub def closed(): Runner[c]`
- node の頭から、最初に待つ所（台詞・選択肢・wait）か終わりまで流す。node が無ければすぐ Done。
  `pub def start(program: Yarn.Program, node: String, now: Clock.Time[c]): (Runner[c], List[Event])`
- start と同じだが、変数と訪れた数を storage から始める（前の会話の storageOf・セーブから読んだ物）。
  `pub def startWith(storage: YarnStorage.Storage, program: Yarn.Program, node: String, now: Clock.Time[c]): (Runner[c], List[Event])`
- 入力 1 つ。今の状態で意味の無い入力（台詞の無い時の Advance・範囲の外の Choose・時刻の前の Tick）は何も変えない。
  `pub def step(action: Action, now: Clock.Time[c], runner: Runner[c]): (Runner[c], List[Event])`
- node の頭から、台詞はすぐ送り・選択肢は picks の順に選び（0 始まり）・<<wait>> は明ける時刻まで飛ばして、
  `pub def trace(program: Yarn.Program, node: String, picks: List[Int32]): List[Event]`
- node の頭から流し、シナリオの line 行（.yarn の 1 始まりの行番号）を出している所まで進める
  `pub def startAt(program: Yarn.Program, node: String, line: Int32, now: Clock.Time[c]): (Runner[c], List[Event])`
- startAt と同じだが、変数と訪れた数を storage から始める（プレビューで $切符=0 の場面を出す。YarnStorage.withArgs）。
  `pub def startAtWith(storage: YarnStorage.Storage, program: Yarn.Program, node: String, line: Int32, now: Clock.Time[c]): (Runner[c], List[Event])`
- `pub def shownOf(runner: Runner[c]): Shown`
- 開いているノードの名前（閉じていれば None）。
  `pub def nodeOf(runner: Runner[c]): Option[String]`
- `pub def isOpen(runner: Runner[c]): Bool`
- 今の台詞を送ると、次に出るのが選択肢か（選択肢の問いを台詞と同じウィンドウに並べるゲームが、送る前に選択肢を出すため）。
  `pub def choicesFollow(runner: Runner[c]): Bool`
- <<wait>> が明ける時刻（待っていなければ None）。
  `pub def waitUntilOf(runner: Runner[c]): Option[Clock.Time[c]]`
- 読んでいる所のブックマーク（開いていなければ None）。
  `pub def bookmarkOf(runner: Runner[c]): Option[Bookmark]`
- ブックマークのノードの頭から steps を当て直し、セーブした時と同じ所（同じ台詞・選択肢）を出す。返す出来事は当て直す間に
  `pub def resume(program: Yarn.Program, bookmark: Bookmark, now: Clock.Time[c]): (Runner[c], List[Event])`
- ブックマークを JSON に（セーブ）。steps は Advance を "a"、Choose(i) を i の数で並べる。
  `pub def bookmarkToJson(bookmark: Bookmark): Util.Json.Json`
- JSON からブックマークへ（ロード）。形が違えば None（違う所から始めるより、ゲームがセーブを読めないと知らせる方がよい）。
  `pub def bookmarkFromJson(json: Util.Json.Json): Option[Bookmark]`
- 変数と訪れた数（セーブや次の会話の startWith へ渡す）。
  `pub def storageOf(runner: Runner[c]): YarnStorage.Storage`
- 変数と訪れた数を差し替える（ゲームの World の値をシナリオへ渡す・セーブから戻す）。
  `pub def withStorage(storage: YarnStorage.Storage, runner: Runner[c]): Runner[c]`
- 変数の今の値（書いていなければ <<declare>> の初めの値。宣言も値も無ければ None）。
  `pub def valueOf(name: String, runner: Runner[c]): Option[Yarn.Value]`

## YarnStorage — `engine_world/src/YarnStorage.flix`
- 変数と訪れた数の置き場。
  `pub type alias Storage = Variables`
- 何も書いていない置き場（変数は全部 <<declare>> の初めの値・どのノードも 0 回）。
  `pub def empty(): Storage`
- 書いてある値（書いていなければ None。<<declare>> の初めの値は見ない）。
  `pub def get(name: String, storage: Storage): Option[Yarn.Value]`
- 値を書く（型はシナリオの宣言と合わせる。合わない値は読む時に初めの値へ戻る）。
  `pub def set(name: String, value: Yarn.Value, storage: Storage): Storage`
- node を出た回数。
  `pub def visitCountOf(node: String, storage: Storage): Int32`
- node を出た回数を 1 つ足す。
  `pub def addVisit(node: String, storage: Storage): Storage`
- 書いてある変数の名前と値（名前の順）。
  `pub def valuesOf(storage: Storage): List[(String, Yarn.Value)]`
- 始まりの引数（`talk node=… line=… $切符=0`）の $ から始まる物を、宣言の型で読んで書く（他の引数は見ない）。
  `pub def withArgs(args: Map[String, String], program: Yarn.Program, storage: Storage): Result[String, Storage]`
- {"variables": {名前: 数・真偽・文字列}, "visits": {ノード: 回数}}。
  `pub def toJson(storage: Storage): Json`
- toJson の形から。欄が無ければ空・形が違えば None。
  `pub def fromJson(json: Json): Option[Storage]`

## ZStack — `engine_world/src/ZStack.flix`
- 積み木の木。p は topLayer の行き先（ゲームの SortingLayer の層の enum）、a は押せる物の名前
  `pub enum Tree[p, a] { case Leaf(List[Render.PlacedItem]) case Stacked(List[Tree[p, a]]) case ZIndexed(Int32, Tree[p, a]) case TopLayer(p, Tree[p, a]) case Mapped(List[Render.PlacedItem] -> List[Render.PlacedItem], Tree[p, a]) case Hit(a, Rect2.Rect2) case Block(Option[a]) }`
- 0.37 までの木の名前（押せる物を持たない木）。0.39 で消す —— 新しく書く所は Tree[p, a]。
  `pub type alias Node[p] = Tree[p, Unit]`
- 葉: 組み上がった絵の列を 1 つの子にする（中の前後は z のまま保つ）。
  `pub def leaf(items: List[Render.PlacedItem]): Tree[p, a]`
- 子を奥 → 手前の順に積む。
  `pub def of(children: List[Tree[p, a]]): Tree[p, a]`
- すぐ外の of の中で child を前後へずらす（小さいほど奥・付けない兄弟は 0・同じ数は積んだ順）。
  `pub def zIndex(order: Int32, child: Tree[p, a]): Tree[p, a]`
- child を、表の層 target の手前（その層の木と、先に送られた物の上）へ送る。
  `pub def topLayer(target: p, child: Tree[p, a]): Tree[p, a]`
- child の絵の列に f を掛ける（`Render.movedAll(d)`・`Render.scaledAllAround(k, pivot)`・
  `pub def mapItems(f: List[Render.PlacedItem] -> List[Render.PlacedItem], child: Tree[p, a]): Tree[p, a]`
- 押せる物 target の当たりを rect に置く（描かない）。ボタンの絵の葉のすぐ後ろ（手前）に積む。
  `pub def hit(target: a, rect: Rect2.Rect2): Tree[p, a]`
- 画面のどこを押しても target（「どこでも次へ」）。これより奥の当たりには届かない。
  `pub def hitAnywhere(target: a): Tree[p, a]`
- child より奥を押せなくする（奥の層も含む）。窓の外を押したら outside（None なら何も起きない）。
  `pub def blocking(outside: Option[a], child: Tree[p, a]): Tree[p, a]`
- 確認の窓・ポーズ: child を層 target の手前へ送り（topLayer）、開いている間は奥を押せなくする（blocking）。
  `pub def modal(target: p, outside: Option[a], child: Tree[p, a]): Tree[p, a]`
