// GameEngine — ゲームとエンジンの境界に置く共有の型（描画データ・キー・色など）と、
// 副作用の入口（描画・入力・音・時間の取得）をまとめて定義する。
// 各ゲームはここの型とエフェクトだけを見れば、内部実装を知らずに描画や入力を組める。
// 利用例: 1フレームぶんの描画コマンドを渡す / キー押下を問い合わせる / 経過時間を取る。

pub mod GameEngine {
    import java.lang.ProcessBuilder
    import java.lang.ProcessHandle
    import java.lang.System
    import java.util.ArrayList

    /// テクスチャアセットのマニフェストエントリ
    pub type alias TextureEntry = { name = String, path = String, hasAlpha = Bool }

    /// フォントアセットのマニフェストエントリ
    pub type alias FontEntry = { name = String, path = String, fontSize = Float64 }

    /// サウンドアセットのマニフェストエントリ
    /// looping = true でループ再生する
    pub type alias AudioEntry = { name = String, path = String, looping = Bool }

    /// サウンドの論理名 → OpenAL ソース ID
    pub type alias AudioRegistry = Map[String, Int32]

    /// テクスチャ情報: GPU ハンドル + 元画像サイズ
    pub type alias TextureInfo = { id = GpuHandle.TextureId, width = Float64, height = Float64 }

    /// テクスチャの論理名 → TextureInfo
    pub type alias TextureRegistry = Map[String, TextureInfo]

    /// エンジン初期化に必要な設定
    ///
    /// designWidth / designHeight:
    ///   ゲーム側の論理解像度（カメラのビューポート / 投影行列の基準）。
    ///   ピクセルアートゲームでは小さく固定し、ウィンドウサイズに引き伸ばす運用が定番。
    /// windowWidth / windowHeight:
    ///   起動時の OS ウィンドウサイズ（ピクセル）。design とは独立して指定でき、
    ///   design 側がウィンドウいっぱいに引き伸ばして描画される。
    ///   project.json に任意キー `windowScale`(>0) があると、ProjectLoader が
    ///   window = design × scale を計算してこの値を上書きする（アスペクト維持で拡大）。
    /// maxDeltaTime:
    ///   getDeltaTime が返す値の上限（秒）。初回フレームのウィンドウ初期化遅延や
    ///   フォーカス復帰時の巨大 dt による物理破綻（tunneling 等）を防ぐ。
    ///   クランプ無効化したい場合は Float64.maxValue() を渡す。
    /// rootDir はプロジェクトの根（project.json のある場所）。バックエンドが
    /// 「このゲームが画面に出しうる字」をソースとアセットから集めるのに使う。
    /// glyphs は起動時にどの字を生成するか: "auto"（既定・生成せずに出た字から順に）/
    /// "used"（出しうる字を先に）/ "all"（フォントの全字）。どれを選んでも、
    /// 足りない字は出そうとしたときに追加生成される。
    pub type alias EngineConfig = {
        rootDir         = String,
        glyphs          = String,
        designWidth = Int32,
        designHeight = Int32,
        windowWidth = Int32,
        windowHeight = Int32,
        title = String,
        textureManifest = List[TextureEntry],
        fontManifest = List[FontEntry],
        soundManifest = List[AudioEntry],
        clearColor = Color,
        maxDeltaTime = Float64
    }

    /// 角丸＋枠線スタイル。共有の描画命令型 `DrawCmd.BoxStyle`。
    pub type alias BoxStyle = DrawCmd.BoxStyle

    /// スプライト 1 つ分の描画命令。renderCommands ハンドラに渡す共有型 `DrawCmd.Drawable`。
    pub type alias Drawable = DrawCmd.Drawable

    /// タイルマップのインスタンス描画命令。共有型 `DrawCmd.TileMapRenderCmd`。
    pub type alias TileMapRenderCmd = DrawCmd.TileMapRenderCmd

    /// 凸多角形の塗り潰し命令。共有型 `DrawCmd.PolygonRenderCmd`。
    pub type alias PolygonRenderCmd = DrawCmd.PolygonRenderCmd

    /// 静的多角形バッファのキャッシュキー。共有型 `DrawCmd.StaticKey`。
    pub type alias StaticKey = DrawCmd.StaticKey

    /// 静的レイヤー描画依頼。共有型 `DrawCmd.StaticLayerCmd`。
    pub type alias StaticLayerCmd = DrawCmd.StaticLayerCmd

    /// 注釈 1 件の書き出し依頼。ゲーム画面の気になる場所を矩形で囲んだとき、
    /// その情報一式をファイルに残すために `saveAnnotation` へ渡す。
    /// sprites / tileMaps / polygons は等倍・オーバーレイ無しの 1 フレームぶんの描画命令で、
    /// ハンドラがこれを描き直してスクリーンショットを撮る。
    /// json / readmeBody は呼び側が組み立て済みの本文をそのまま渡す（ハンドラは書くだけ）。
    pub type alias AnnotationRequest = {
        frame = Int64,          // 凍結中のフレーム番号
        rect = Rect2.Rect2,     // 注釈の矩形（デザイン座標系・ズーム非依存）
        json = String,          // annotation.json の本文
        readmeBody = String,    // README.md の中ほどに挟む要約（見出しやコメント欄はハンドラが付ける）
        worldDump = String,     // world.json の本文（ゲームが組んだシム状態のダンプ。"" = 同梱しない）
        sprites = List[Drawable],
        tileMaps = List[TileMapRenderCmd],
        polygons = List[PolygonRenderCmd]
    }

    /// タイルマップ 1 タイル分のインスタンスデータ。共有型 `DrawCmd.TileInstance`。
    /// tilemap loader (ゲーム側の `buildTileInstances` 相当) が生成し、
    /// `initTileBuffer` で GPU にアップロードする。
    pub type alias TileInstance = DrawCmd.TileInstance

    /// 描画物を Drawable のリストに変換する能力を表す trait
    /// Text 等、1 つの描画物から複数 Drawable を生成するケースに対応。
    /// Sprite の region/hframes/vframes/frame から UV を計算するためにテクスチャ
    /// サイズを参照する必要があり、Game eff を要求する。
    pub trait Renderable[n] {
        pub def toDrawables(item: n, globalPos: Vec2.Vec2): List[Drawable] \ Game
    }

    /// キーボードキー。
    /// GLFW のキートークンは US 配列の物理位置基準のため、JIS 固有キー
    /// (無変換・変換・かな)は取れず、記号キーの位置も US 配列基準になる。
    pub enum Key with Eq, Order, ToString {
        // 英字
        case A
        case B
        case C
        case D
        case E
        case F
        case G
        case H
        case I
        case J
        case K
        case L
        case M
        case N
        case O
        case P
        case Q
        case R
        case S
        case T
        case U
        case V
        case W
        case X
        case Y
        case Z
        // 数字(キーボード上段)
        case Digit0
        case Digit1
        case Digit2
        case Digit3
        case Digit4
        case Digit5
        case Digit6
        case Digit7
        case Digit8
        case Digit9
        // 矢印
        case Up
        case Down
        case Left
        case Right
        // 制御・編集
        case Enter
        case Space
        case Escape
        case Tab
        case Backspace
        case Insert
        case Delete
        case PageUp
        case PageDown
        case Home
        case End
        case CapsLock
        // ファンクション
        case F1
        case F2
        case F3
        case F4
        case F5
        case F6
        case F7
        case F8
        case F9
        case F10
        case F11
        case F12
        // 記号(US 配列の刻印)
        case Apostrophe
        case Comma
        case Minus
        case Period
        case Slash
        case Semicolon
        case Equal
        case LeftBracket
        case Backslash
        case RightBracket
        case GraveAccent
        // 修飾
        case LeftShift
        case LeftCtrl
        case LeftAlt
        case LeftSuper
        case RightShift
        case RightCtrl
        case RightAlt
        case RightSuper
        case Menu
        // テンキー
        case Numpad0
        case Numpad1
        case Numpad2
        case Numpad3
        case Numpad4
        case Numpad5
        case Numpad6
        case Numpad7
        case Numpad8
        case Numpad9
        case NumpadDecimal
        case NumpadDivide
        case NumpadMultiply
        case NumpadSubtract
        case NumpadAdd
        case NumpadEnter
        case NumpadEqual
    }

    /// Key の全バリアント。InputEvent などのイベント駆動入力で
    /// 走査対象として使う。新しい Key を追加した際はここにも追加する
    /// (enum と同じグループ順で並べ、突き合わせできるようにしておく)。
    pub def allKeys(): List[Key] =
        // 英字
        Key.A :: Key.B :: Key.C :: Key.D :: Key.E :: Key.F :: Key.G :: Key.H ::
        Key.I :: Key.J :: Key.K :: Key.L :: Key.M :: Key.N :: Key.O :: Key.P ::
        Key.Q :: Key.R :: Key.S :: Key.T :: Key.U :: Key.V :: Key.W :: Key.X ::
        Key.Y :: Key.Z ::
        // 数字(キーボード上段)
        Key.Digit0 :: Key.Digit1 :: Key.Digit2 :: Key.Digit3 :: Key.Digit4 ::
        Key.Digit5 :: Key.Digit6 :: Key.Digit7 :: Key.Digit8 :: Key.Digit9 ::
        // 矢印
        Key.Up :: Key.Down :: Key.Left :: Key.Right ::
        // 制御・編集
        Key.Enter :: Key.Space :: Key.Escape :: Key.Tab :: Key.Backspace ::
        Key.Insert :: Key.Delete :: Key.PageUp :: Key.PageDown :: Key.Home ::
        Key.End :: Key.CapsLock ::
        // ファンクション
        Key.F1 :: Key.F2 :: Key.F3 :: Key.F4 :: Key.F5 :: Key.F6 ::
        Key.F7 :: Key.F8 :: Key.F9 :: Key.F10 :: Key.F11 :: Key.F12 ::
        // 記号(US 配列の刻印)
        Key.Apostrophe :: Key.Comma :: Key.Minus :: Key.Period :: Key.Slash ::
        Key.Semicolon :: Key.Equal :: Key.LeftBracket :: Key.Backslash ::
        Key.RightBracket :: Key.GraveAccent ::
        // 修飾
        Key.LeftShift :: Key.LeftCtrl :: Key.LeftAlt :: Key.LeftSuper ::
        Key.RightShift :: Key.RightCtrl :: Key.RightAlt :: Key.RightSuper ::
        Key.Menu ::
        // テンキー
        Key.Numpad0 :: Key.Numpad1 :: Key.Numpad2 :: Key.Numpad3 :: Key.Numpad4 ::
        Key.Numpad5 :: Key.Numpad6 :: Key.Numpad7 :: Key.Numpad8 :: Key.Numpad9 ::
        Key.NumpadDecimal :: Key.NumpadDivide :: Key.NumpadMultiply ::
        Key.NumpadSubtract :: Key.NumpadAdd :: Key.NumpadEnter :: Key.NumpadEqual :: Nil

    /// マウスボタン
    pub enum MouseButton with Eq, Order, ToString {
        case Left
        case Right
        case Middle
    }

    /// MouseButton の全バリアント。InputEvent でマウス押下/離脱の
    /// 走査対象として使う。
    pub def allMouseButtons(): List[MouseButton] =
        MouseButton.Left :: MouseButton.Right :: MouseButton.Middle :: Nil

    /// マウスカーソル形状（エディタのリサイズハンドルなどで切り替える）。
    /// LWJGL 3.3.4 同梱の GLFW 3.4 で利用可能な shape をエディタ用に列挙。
    /// 4 隅は OS ネイティブの方向別カーソル (NW/NE/SW/SE) を個別に持ち、AWT 側で
    /// 単方向矢印が「逆向き」に見える問題を避ける。GLFW には対角単位の双方向矢印
    /// しか無いので、NW+SE / NE+SW でエイリアスされる。
    pub enum Cursor with Eq, ToString {
        /// 通常の矢印カーソル（エディタ非操作中・ハンドル外）
        case Default
        /// 十字カーソル ＋（ゲーム内アノテーションの矩形指定など、正確に狙う操作）
        case Crosshair
        /// 横方向の伸縮カーソル ←→（左右辺ハンドル）
        case HResize
        /// 縦方向の伸縮カーソル ↕（上下辺ハンドル）
        case VResize
        /// 全方向の伸縮カーソル（CanvasLayer 全体の操作）
        case AllResize
        /// 回転操作中・回転ノブにホバー中のカーソル（Hand）。
        /// 「ここを掴める」という視覚フィードバック
        case Rotate
        /// 北西方向のリサイズ (TopLeft 隅 ↖)
        case NWResize
        /// 北東方向のリサイズ (TopRight 隅 ↗)
        case NEResize
        /// 南西方向のリサイズ (BottomLeft 隅 ↙)
        case SWResize
        /// 南東方向のリサイズ (BottomRight 隅 ↘)
        case SEResize
    }

    /// ゲームエフェクト: 描画・ウィンドウ制御・時間取得・キー入力・マウス入力・フォント・
    /// ビューポート・マウスカーソル形状切り替え
    pub eff Game {
        /// zIndex 混合で sprites・tileMaps・polygons を 1 フレーム描画する。
        /// staticLayer は「1 度だけ GPU へ生成して使い回す静的多角形」の依頼（無ければ None）。
        /// エンジンがキーでキャッシュし、動的な polygons と同じ z 安定ソート列にレンジを混ぜて
        /// 描くので重なり順は壊れない。ゲームは GL ハンドルを触らずキーと中身を宣言するだけ。
        def renderCommands(sprites: List[Drawable], tileMaps: List[TileMapRenderCmd],
                           polygons: List[PolygonRenderCmd],
                           staticLayer: Option[StaticLayerCmd]): Unit
        /// タイルインスタンスデータを GPU VBO にアップロードし (vaoハンドル, count) を返す
        def initTileBuffer(instances: List[TileInstance]): (GpuHandle.TileVao, Int32)
        /// 既存のタイル VAO のインスタンス VBO へ中身を入れ直す（VAO は増やさない）。
        /// key の変わりやすい層（照明・カメラ追随で生成し直す地形など）が、生成し直しの
        /// たびに initTileBuffer で VAO を積み増して GPU メモリを漏らさないための関数。
        /// 未知の VAO（理論上来ない）は新規に生成して返す — 返った vaoハンドルを保存し直すこと。
        def updateTileBuffer(vaoId: GpuHandle.TileVao,
                             instances: List[TileInstance]): (GpuHandle.TileVao, Int32)
        def shouldClose(): Bool
        /// 前フレームからの経過時間。EngineConfig#maxDeltaTime で上限クランプ済み
        def getDeltaTime(): Duration.Duration
        def isKeyPressed(key: Key): Bool
        def getMousePosition(): Vec2.Vec2
        def isMouseButtonPressed(button: MouseButton): Bool
        /// 前回呼び出し以降に蓄積されたマウスホイールの y 方向 delta を返し、
        /// 内部アキュムレータを 0 にリセットする。1 ティックぶんの値が +1.0 / -1.0 程度
        /// （プラットフォーム依存）。スクロールアップで正、ダウンで負。
        def consumeScrollDelta(): Float64
        def getFontAtlas(name: String): FontAtlas

        /// アトラスにまだ無い字を、いま生成してアトラスに足す。
        /// textureName は FontAtlas#textureName（どのフォントかの目印）。
        ///
        /// 起動時に生成するのは「ソースとアセットに書いてある字」なので、実行中に計算で
        /// 作った字やプレイヤーが入れた名前は入っていない。それを出そうとしたとき、
        /// 黙って消えるかわりにここで追加生成する。初めて出る字は 1 コマ遅れて現れる。
        /// 呼ぶ側は毎フレーム「足りない字」を渡してよい（足りていなければ何もしない）。
        def ensureGlyphs(textureName: String, codepoints: Set[Int32]): Unit
        def getViewportRect(): Rect2.Rect2
        /// 指定したテクスチャ名の元画像サイズ等を取得する。
        /// 登録されていないテクスチャ名なら None
        def getTextureInfo(name: String): Option[TextureInfo]

        /// 実行時に生成した画素を、名前付きテクスチャとして使えるようにする。
        /// key はその画素の中身を決める全入力を 1 文字列にまとめた物（テーマ名・世代番号など）。
        /// 同じ名前で key が前回と同じなら、描画部は何もしない（毎フレーム呼んでよい）。
        /// argb は width×height の行優先（PxSpriteAtlas.bake の出力そのまま）。
        /// 用途: ドット絵をアトラスに生成して「1 体 = 1 枚のクアッド」で描く
        /// （画素ごとの矩形を並べるより桁違いに軽い）。
        def ensureTexture(name: String, key: String, width: Int32, height: Int32,
                          argb: Vector[Int32]): Unit
        /// マウスカーソル形状を切り替える。連続して同じ Cursor を渡しても問題ない（冪等）
        def setCursor(cursor: Cursor): Unit
        /// マウスカーソルの表示/非表示を切り替える。形状(setCursor)は「どんな絵か」、
        /// これは「絵を出すか出さないか」で役割が別。連続して同じ値を渡しても問題ない（冪等）
        def setCursorVisible(visible: Bool): Unit
        /// ウィンドウ⇄ボーダーレスフルスクリーンを切り替える。フルスクリーンはプライマリ
        /// モニタの現在の解像度を使う（解像度そのものは変えない）。連続して同じ値を渡しても
        /// 問題ない（冪等）。切替の配線はゲームの system 側 — F8 ポーズ中は system が
        /// 回らず切替キーも効かない点に注意
        def setFullscreen(on: Bool): Unit
        /// 直近の setFullscreen で今フルスクリーン中かを返す
        def isFullscreen(): Bool
        /// 注釈一式（screenshot.png / highlighted.png / annotation.json / README.md）を
        /// debug/annotations/ 配下の新しいディレクトリへ書き出し、そのパスを返す。失敗時 None。
        /// 保存に成功するとシャッター風の効果音を鳴らす。
        def saveAnnotation(req: AnnotationRequest): Option[String]
        /// デバッグモード中であることをウィンドウタイトルで示す。
        /// true でタイトル末尾に「 (Debug)」を付け、false で元のタイトルへ戻す。
        def setDebugBadge(enabled: Bool): Unit
    }

    /// オーディオエフェクト: サウンドの再生・停止・音量・ループ
    pub eff Audio {
        /// 指定した名前のサウンドを先頭から再生する
        def playAudio(name: String): Unit
        /// 指定した名前のサウンドを停止する
        def stopAudio(name: String): Unit
        /// 指定した名前のサウンドの音量（gain）を 0.0〜1.0 で設定する
        def setVolume(name: String, volume: Float64): Unit
        /// 指定した名前のサウンドの高さ（再生速度）を実行時に変える。1.0 = 元のまま・
        /// 2.0 で 1 オクターブ上・0.5 で 1 オクターブ下。鳴っている音にも即座に効くので、
        /// 速度で唸りが変わるエンジン音のような「鳴り続ける音」に使う。
        /// 0 以下は音が止まって聞こえるので、実装は下限でクランプする。
        def setPitch(name: String, pitch: Float64): Unit
        /// 指定した名前のサウンドの AL_LOOPING を実行時に切り替える。
        /// 起動時の `soundManifest#looping` 初期値を上書きする (再生中の音にも反映)
        def setLooping(name: String, loop: Bool): Unit
        /// 全サウンド共通のマスター音量（全体つまみ）を 0.0〜1.0 で設定する。範囲外はクランプ。
        /// 各サウンドの setVolume と乗算で効く（OpenAL の listener gain × source gain）。
        def setMasterVolume(gain: Float64): Unit
        /// すでに登録してある名前の音を、path のファイルから読み直して差し替える。
        /// 音は起動時に一度読むだけなので、生成し直した WAV は本来次の起動まで届かない。
        /// これがあれば、調整しながら鳴らして確かめられる（絵の watchFile と同じ手触り）。
        /// 音源そのもの（音量・ループの設定・再生位置の器）は保たれ、中身だけが入れ替わる。
        /// 知らない名前・読めないファイルは何もしない（鳴っている音を殺さない）。
        def reloadAudio(name: String, path: String): Unit
        /// 指定した名前のサウンドの高い音を削る（ローパス）。gainHF は高い音の残り具合 0.0〜1.0
        /// （1.0 = 素通し）。OpenAL の EFX の lowpass と同じ意味で、5000Hz より上をこの倍率まで落とす。
        /// EFX の無い環境では何もしない（音は素通しのまま鳴る）。AudioMixer のバスの lowpass がここへ届く。
        def setLowpass(name: String, gainHF: Float64): Unit
        /// 指定した名前のサウンドの長さ（秒）。知らない名前は 0.0。
        /// AudioMixer が「効果音が鳴っている間」を知るために使う（ダッキングの長さ）。
        def audioSeconds(name: String): Float64
    }

    // ========================================================================
    // プラットフォーム
    // ========================================================================

    /// macOS では -XstartOnFirstThread 付きでプロセスを再起動する。
    /// すでに -XstartOnFirstThread 付きで動いている場合は何もせず false を返す。
    /// 再起動した場合は true を返す（呼び出し元は終了すべき）。
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
            let javaHome = System.getProperty("java.home");
            let javaBin = "${javaHome}/bin/java";
            let args = new ArrayList();
            discard args.add(javaBin);
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
            let proc = pb.start();
            let code = proc.waitFor();
            System.exit(code);
            true
        }

    /// 今のプロセスがすでに -XstartOnFirstThread 付きで起動しているかを調べる。
    /// java ランチャはそのフラグ付き起動時、環境変数
    /// `JAVA_STARTED_ON_FIRST_THREAD_<pid>` を "1" にセットする
    /// （LWJGL/GLFW が「thread0 で動いているか」の判定に使うのと同じ変数）。
    /// これを見れば、game.relaunched が付いていない起動（bin/flix ラッパー経由の
    /// 通常起動など）でも二重に再起動せずに済む。
    def isStartedOnFirstThread(): Bool \ IO =
        let pid = ProcessHandle.current().pid();
        let value = System.getenv("JAVA_STARTED_ON_FIRST_THREAD_${pid}");
        not Object.isNull(value) and value == "1"
}
