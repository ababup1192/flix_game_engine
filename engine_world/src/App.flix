// App — ゲームを「宣言」で組み立てて走らせるランナー。ゲーム側は初期 World にシステムと
// 絵と音を繋いで launch を呼ぶだけで、ウィンドウ・時計・入力・描画・ループはすべてここが引き受ける。
// 外の世界に触れる処理（effect）をこのモジュールが独占するので、ゲームのシステムは
// (Frame, w) -> w の純粋関数として書ける（毎フレームの入力と dt は Frame に埋め込んで渡す）。
//
// 更新系（addSystem）が World を進め、描画（withView）は進んだ後の World を読むだけで
// 変えない — 1 フレームは必ずこの順（1 周の全手順は下の loop の doc を見る）。

pub mod App {
    import java.lang.System

    /// ゲーム 1 本の宣言（中身は Rec）。record のままにしないのは、37 欄の record の型が App を受ける
    /// 全部の def とゲームのビルダーの列で展開され、型検査が重くなるため（docs/flix-conventions.md）。
    pub enum App[w: Type, ef: Eff](Rec[w, ef])

    /// App の中身。ゲームからは読まない（ビルダーで組む）。エンジンの中の口（Flow・RemoteDebug など）が読む。
    pub def rec(app: App[w, ef]): Rec[w, ef] = match app { case App.App(r) => r }

    // ── システムが受け取る 1 フレームぶんの外界 ──

    /// このフレームの入力と時計のスナップショット。キーの生読みはランナーが済ませてあるので、
    /// システムは down（押されている）と justPressed（この瞬間押された）を値として引くだけ。
    pub type alias Frame = {
        down = Set[GameEngine.Key],        // いま押されているキー
        justPressed = Set[GameEngine.Key], // このフレームで新しく押されたキー（エッジ）
        dt = Float64,                      // 前フレームからの経過秒（エンジンがクランプ済み。
                                           // withFixedStep 使用時はサブステップ中ずっと固定値）
        viewport = Vec2.Vec2,              // design 解像度の幅・高さ（project.json の designWidth/Height）
        cursor = Vec2.Vec2,                // マウス位置（design 座標。バックエンドがウィンドウ座標→design に変換済み）
        mouseDown = Bool,                  // 左ボタンがいま押されているか
        mouseClicked = Bool,               // 左ボタンがこのフレームで新しく押されたか（エッジ）
        mouseMoved = Bool,                 // このフレームでマウスが動いたか（前フレームとの座標比較）
        wheel = Float64,                   // このフレームのホイール量（上が正・下が負。無ければ 0。
                                           // ランナーが毎フレーム consumeScrollDelta を読み切るので、
                                           // ゲーム側が直接 consume すると常に 0 が返る — 必ずここから読む）
        realNow = Clock.Time[Clock.Real],  // 実時間の今（起動からの秒。ポーズメニューの点滅・背景の雨のように
                                           // 遊びの時計が止まっても動く物が読む。App が advanceFrame で置く —
                                           // ゲームは実時間の時計を持たないので、止める・2 度進めるができない）
        padTouched = Bool                  // ゲームパッドのどこかにいま触っているか（案内のキーの絵をパッドの物へ替える判断に。
                                           // パッドの入力そのものはキーへ読み替えて down / justPressed に入っている）
    }

    /// key がいま押されているか（押しっぱなしも true）。移動などの連続入力に。
    pub def isDown(key: GameEngine.Key, frame: Frame): Bool =
        Set.memberOf(key, frame#down)

    /// key がこのフレームで新しく押されたか（押しっぱなしは false）。決定・発射などの単発入力に。
    pub def justPressed(key: GameEngine.Key, frame: Frame): Bool =
        Set.memberOf(key, frame#justPressed)

    /// 負方向・正方向のキーの押し下げを -1 / 0 / +1 にまとめる（両押しは打ち消して 0）。
    /// 左右移動などの軸入力に。同型のキー 2 つは順序を取り違えやすいので名前で渡す。
    pub def axis(negative: {negative = GameEngine.Key},
                 positive: {positive = GameEngine.Key}, frame: Frame): Float64 =
        (if (isDown(positive#positive, frame)) 1.0 else 0.0) -
        (if (isDown(negative#negative, frame)) 1.0 else 0.0)

    // ── App: 宣言の入れ物 ──

    /// view / hudView が受け取る「この 1 フレームの見え方」。atlas は文字描画用の既定フォント、
    /// visible は camera を通して画面に見えている world の矩形（camera なしなら design 全体。
    /// 背景タイルの敷き詰めなど「見える分だけ組む」計算はここから出す — ゲームが画面サイズを
    /// World に持ち込む必要はない。この範囲を敷き詰めに使うなら Scatter（field / strip）が
    /// セル走査と決定的乱数を持っている）。HUD（画面固定）には常に design 全体が渡る。
    /// fontOf は名前でフォントを引く関数（project.json の fonts[].name）。withFonts で宣言した
    /// 名前だけ引ける — 知らない名前は既定フォントへ落とす（fail-open）。話し手ごとに字を変える
    /// ようなゲームは、名前を直に書かず「自分の enum → 名前」の関数を 1 つ置いて fontOf に
    /// 渡すと、字の増減が 1 か所で済む。
    /// warnOnce は、毎フレーム通る組み立て（SortingLayer.compose など）が既定値で続けたことを知らせる口。
    /// 同じ文面は 1 回だけ出る（実機は App がゲームの間ずっと 1 つの集合で覚える。描き出しはゲームが
    /// 差し替えて、集まった文面で止める）。文面は docs/error-handling.md の決まり 3 の定型にそろえる。
    pub type alias ViewCtx = { atlas = FontAtlas, fontOf = String -> FontAtlas, visible = Rect2.Rect2,
                               warnOnce = String -> Unit }

    /// ヘッドレス描き出しから view を呼ぶときの ViewCtx。画面全体が見えている扱いにする。
    /// フォント 1 本だけの版 — どの名前で引いても同じ本が返る。
    pub def viewCtxOf(atlas: FontAtlas, design: Vec2.Vec2): ViewCtx =
        viewCtxOfFonts(atlas, _ -> atlas, design)

    /// viewCtxOf の複数フォント版。fontOf には実機と同じ名前で引ける関数を渡す
    /// （HeadlessFont.buildAtlas に実機と同じ name を渡して組んだ本を返す関数）。
    /// 名前が実機と食い違うと、描き出した絵だけ別の字になる。
    /// warnOnce は覚えずに毎回 1 行出す（描き出しで止めたいゲームは `{ warnOnce = 集める口 | ctx }` で差し替える）。
    pub def viewCtxOfFonts(atlas: FontAtlas, fontOf: String -> FontAtlas, design: Vec2.Vec2): ViewCtx =
        { atlas = atlas, fontOf = fontOf,
          visible = { position = { x = 0.0, y = 0.0 }, size = design },
          warnOnce = Log.warn }

    /// 入力の側（update・テスト）で、押せる物の当たりを出すために View の木を組むときの ViewCtx
    /// （`SortingLayer.pickFrom(点, View.layers(App.pickCtx(design), w))`）。字の形を持たないフォントで、
    /// 知らせは黙る（同じ木を描く compose の側で出る）。当たりの矩形は字の幅から作らない —— この ctx では幅が 0 になる。
    pub def pickCtx(design: Vec2.Vec2): ViewCtx =
        let blank = { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0,
                      lineGap = 0.0, glyphs = Map.empty() };
        { atlas = blank, fontOf = _ -> blank,
          visible = { position = { x = 0.0, y = 0.0 }, size = design },
          warnOnce = _ -> () }

    /// 見た文面を seen に覚え、初めての文面だけ Log.warn する口（ViewCtx#warnOnce の実機の形）。
    /// View は純粋なので、効果は Log.warn と同じく `unsafe IO` で隠す。
    pub def warnOnceWith(seen: Ref[Set[String], Static]): String -> Unit =
        line -> unsafe IO {
            if (Set.memberOf(line, Ref.get(seen))) ()
            else {
                Ref.put(Set.insert(line, Ref.get(seen)), seen);
                Log.warn(line)
            }
        }

    /// 生成したドット絵アトラス 1 枚ぶんの受け渡し。
    /// texture = 絵を引くときの名前、key = その画素の中身を決める全入力を 1 文字列にまとめた物
    /// （同じ key の間は GPU へ上げ直さない）、baked = PxSpriteAtlas.bake の生成結果。
    pub type alias AtlasUpload = { texture = String, key = String, baked = PxSpriteAtlas.Baked }

    /// ゲーム 1 本の宣言。make で空を作り、addStartup / addSystem / reloadOn / withView /
    /// withAudio / quitWhen で部品を繋ぎ、launch へ渡す。w はゲームが持ち込む World の型、
    /// ef はシステム・絵・音・終了判定が帯びる効果（外の世界に触れる処理）の行
    /// （純粋なゲームは ef = {}）。各フィールドの意味は右の // コメントを参照。
    pub type alias Rec[w: Type, ef: Eff] = {
        init = Vec2.Vec2 -> w \ ef,                                // design 解像度 → 出発点の World（launch が画面サイズを渡して呼ぶ）
        startupSystems = List[w -> w \ ef],                        // 起動時に 1 回だけ・追加順
        updateSystems = List[(Frame, w) -> w \ ef],                // 毎フレーム・追加順
        reload = Option[(GameEngine.Key, w -> w \ {Fs.FileRead})], // ホットリロード（キーと、ファイル読みの副作用）
        watch = List[(String, w -> w \ {Fs.FileRead})],            // 保存検知のホットリロード（パスと関数）の列・追加順
        // World を (置き場所, 見せたい物) の列へ投影する。None のゲームは App に描画させず自分の
        // システム内で描く（タイルマップ等の複数チャンネルを直接組むゲーム向け）。
        view = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef],
        // 本編より先にレンダーターゲットへ描く列（追加順に描く）。各ターゲットは名前の
        // テクスチャになり、view から Render.sprite(名前, z) で貼れる。カメラ・zoom は
        // 掛からない（ターゲットの中は常に design 座標そのまま — カメラを効かせたい絵は
        // view と同じ composeScene をゲーム側で通してから渡す）。
        passes = w -> List[Render.Pass] \ ef,
        // 既定フォント以外に使うフォントの名前（project.json の fonts[].name）。ここに宣言した
        // 名前だけが ViewCtx#fontOf で引ける。withFonts で足す。
        fonts = List[String],
        // World から「画面中央に映したい world 座標」を導く。None = カメラなし（view の座標が
        // そのまま画面座標）。view = None のゲームでは効かない。追従・クランプ・シェイクは
        // ゲーム側システムの責務（導いた値をここで返すだけ）。
        camera = Option[w -> Vec2.Vec2 \ ef],
        // World から寄り引き倍率を導く（大きいほど寄る）。None = 等倍。camera と別フィールドの
        // 合成: camera だけ・zoom だけ・両方、どの組み合わせでも効く（zoom だけなら画面中央に寄る）。
        zoom = Option[w -> Float64 \ ef],
        // camera が映してよい world の矩形（レベルの端で止める）。None = 制限なし。
        // 見えている範囲（design/zoom）がこの矩形を出ないよう center が収められる。
        cameraBounds = Option[w -> Rect2.Rect2 \ ef],
        // 視差レイヤ（factor, view）の列・追加順。camera の動きに factor を掛けた速さで流れる
        // world 空間の絵（factor 0.3 の遠景など）。主 view より先に並ぶが、重なりは zIndex が決める。
        parallaxLayers = List[(Float64, (ViewCtx, w) -> List[Render.PlacedItem] \ ef)],
        // カメラを掛けずに描く絵（スコア等の HUD）。合流時に z が HUD の範囲（ZBand.liftHud）へ
        // 持ち上がるので、world の z に関わらず必ず手前。zIndex が決めるのは HUD の中の前後だけ。
        hudView = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef],
        audio = { before = w, after = w } -> List[String] \ ef,    // 1 フレームの前後から鳴らす音名を導く
        // 「このフレームで鳴り続けていてほしい音」の宣言。宣言が続く間は鳴り続け、消えたフレームで
        // 止まる（風・雨・炎・機械の唸り・足音のループ）。毎フレーム音量と高さを与えられる。
        sustained = w -> List[Sustain] \ ef,
        // 音の通り道（AudioMixer）。None の間は音を名前のまま鳴らす（バス・ダッキング・間引きなし）。
        mixer = Option[w -> AudioMixer.Mixer \ ef],
        quit = (Frame, w) -> Bool \ ef,                            // 終了判定（既定 = Escape のエッジ）
        // 窓の閉じるボタン（OS の閉じる要求）を World へ知らせる関数。None = 押したらすぐ終わる（既定）。
        // Some の間は窓を閉じず、閉じるかはゲームが quit（quitWhen）で決める（withCloseRequest）。
        closeRequest = Option[w -> w \ ef],
        debug = Bool,                                              // デバッグ機能（F8 の時間停止・注釈・巻き戻し）を有効にするか
        // view = None のゲームがデバッグ機能を使うための生投影（フォントアトラス名と、World →
        // 描画チャンネル 3 本）。描画はせずチャンネルを返すだけの関数を繋ぐ。
        debugView = Option[(String, w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef)],
        // 注釈の矩形（デザイン座標）と表示中の瞬間の World からテキストを組む。
        // 注釈チケットに world.json として同梱され、リモートデバッグの view=full にもなる。
        worldDump = Option[(Rect2.Rect2, w) -> String \ ef],
        // 注釈チケットの README 冒頭に載せる「その瞬間の文脈」（場面・台本の行・z の層の名前）。
        annotationContext = Option[w -> Annotate.Table \ ef],
        // 「1 度だけ GPU に生成して使い回す静的な絵」の宣言（無ければ None）。key = 静的な中身を
        // 決める全入力を 1 文字列にまとめたキャッシュキー（フロア id・テーマ・作り直しの世代など。
        // これが変わるとエンジンが古い VBO を捨てて作り直す）、build = ワールド座標の静的 PlacedItem を
        // 組む純粋関数（camera はエンジンが uniform で当てるので触らない。多角形だけが生成の対象になり、
        // それ以外の item は無視される）。GL ハンドルも無効化ロジックもゲームは持たない。
        // 純粋関数に限るのは renderCommands の op を効果多相にしないため（静的な絵は World の
        // 純粋な投影から作れる）。
        staticLayer = Option[{ key = w -> GameEngine.StaticKey, build = w -> List[Render.PlacedItem] }],
        // 「1 度だけ GPU に生成して 1 draw call で敷くタイルの層」の宣言（無ければ None）。
        // Spec の key が変わるとエンジンが作り直す。純粋関数に限る理由は staticLayer と同じ。
        // タイル層は動的な絵より必ず奥に描かれる — キャラを隠す絵（屋根・庇）は置けない。
        tileLayers = Option[w -> List[TileLayerSpec]],
        // ドット絵を生成したアトラス（1 体 = 1 枚のクアッドで描くための下ごしらえ）。
        // 毎フレーム「同じ key なら何もしない」で呼ばれるので、生成する仕事は World 側で 1 度だけ
        // 済ませ、ここは生成結果を渡すだけにする。
        spriteAtlases = w -> List[AtlasUpload],
        // カメラを何 px の升目に吸着させるか（0 = 吸着しない）。ドット絵のゲームは 1 にする。
        // World から読むので、Doc を保存して値が変わればその場で効く。
        pixelSnap = w -> Float64,
        // World の 1 行サマリ。リモートデバッグ（HTTP）の view=status と trace の源。
        statusLine = Option[w -> String \ ef],
        // リモートデバッグ（HTTP）の POST /render が実行する「描き出しの実体」。Docs から決定的な
        // 場面を組み立てて PNG に描き出し、そのファイルパスの列を返す（各ゲームの SceneRender.all の
        // 中身を、温まった JVM で実行するだけ）。走行中のプレイ状態には一切触れないこと。
        // None のゲームへの /render は「未対応」の応答になる（Studio はそれでフォールバック）。
        remoteRender = Option[Unit -> List[String] \ IO],
        // 渡した World を 1 枚の PNG に描き、そのパスを返す（onShotRequest で足す）。リモートデバッグの
        // view=shot（/step・/start・/state）と窓なしのゲーム（App.Headless）が呼ぶ。None なら未対応の応答。
        shot = Option[w -> String \ IO],
        // リモートデバッグ（HTTP）の任意パスに応える、ゲーム登録のハンドラ（onRequest で足す）。
        // (パス, (クエリ, World) -> Ok(次の World) / Err(理由)) の列。既定ルートに無いパスだけが
        // ここへ来て、パスの完全一致・登録順の先勝ちで 1 本選ばれる。
        remoteHandlers = List[(String, (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead})],
        // 物理・当たり判定を実時間でなく固定量子で進めたいゲームの刻み幅（秒）。None = 可変 dt
        // のまま（既定・全既存ゲームはこちら）。withFixedStep で有効化する（詳細は同関数を参照）。
        fixedStep = Option[Float64],
        // 遊びの時計（addClock で宣言）を 1 フレームぶん進める関数の列・追加順。引数は実時間の dt。
        clocks = List[(Float64, w) -> w],
        // 毎フレームの「マウスの矢印をどう見せたいか」の宣言（withCursor）。None = App は触らない（F8 の十字だけ）。
        cursor = Option[w -> CursorSpec],
        // 鍵が変わったフレームに 1 回書く外への出力（addOutput・withDocTable）の列・追加順。
        outputs = List[Output[w]],
        // 始まりの登録簿（withStarts）。START・/start・flow の start・テストが名前で場面を組む。
        starts = List[Start[w]],
        // flow（e2e/<名前>.flow）の語彙の表: 役・問い・名前付きの操作・入力を受けられるか・返事の通し番号（withFlow）。
        flow = Flow.Table[w],
        // World の指紋の元の文字（withFingerprint）。記録の 60 フレームごとの expect fp= と、再生の食い違いの指し示し。
        fingerprint = Option[w -> String]
    }

    /// 初期 World だけを持つ空の App。絵はまだ無い（withView で繋ぐまで何も描かない）。
    /// 初期値を画面サイズから組みたいゲームは makeWith を使う。
    pub def make(init: w): App[w, ef] =
        makeWith(_ -> checked_ecast(init))

    /// 初期 World を design 解像度（project.json の designWidth/Height）から組む入口。
    /// launch が画面サイズを読んで f へ渡すので、ゲーム側はエンジン API に触れない。
    pub def makeWith(f: Vec2.Vec2 -> w \ ef): App[w, ef] =
        // 既定の hook は純粋だが、フィールド型は効果多相 ef。Pure は任意の ef に安全に広げられるので
        // 本体を checked_ecast で ef へ widen して型を合わせる（呼び出し側が ef を絞る）。
        App.App({ init = f,
          startupSystems = Nil,
          updateSystems = Nil,
          reload = None,
          watch = Nil,
          view = None,
          passes = _ -> checked_ecast(Nil),
          fonts = Nil,
          camera = None,
          zoom = None,
          cameraBounds = None,
          parallaxLayers = Nil,
          hudView = None,
          staticLayer = None,
          tileLayers = None,
          spriteAtlases = _ -> Nil,
          pixelSnap = _ -> 0.0,
          audio = _worlds -> checked_ecast(Nil),
          sustained = _world -> checked_ecast(Nil),
          mixer = None,
          quit = (frame, _world) -> checked_ecast(justPressed(GameEngine.Key.Escape, frame)),
          closeRequest = None,
          debug = false,
          debugView = None,
          worldDump = None,
          annotationContext = None,
          statusLine = None,
          remoteRender = None,
          shot = None,
          remoteHandlers = Nil,
          fixedStep = None,
          clocks = Nil,
          cursor = None,
          outputs = Nil,
          starts = Nil,
          flow = Flow.emptyTable(),
          fingerprint = None })

    /// 起動時に 1 回だけ走るシステムを末尾へ繋ぐ（追加順に適用される）。
    pub def addStartup(sys: w -> w \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ startupSystems = List.append(rec(app)#startupSystems, sys :: Nil) | rec(app) })

    /// 毎フレーム走るシステムを末尾へ繋ぐ（追加順に適用される）。
    pub def addSystem(sys: (Frame, w) -> w \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ updateSystems = List.append(rec(app)#updateSystems, sys :: Nil) | rec(app) })

    /// key が押された瞬間に World を作り直すホットリロードを繋ぐ（ファイル読みの副作用つき）。
    /// 遊びながら設定ファイルを編集し、キー一発で効きを変える用途に。
    pub def reloadOn(key: GameEngine.Key, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef] =
        App.App({ reload = Some((key, f)) | rec(app) })

    /// path の保存（更新時刻の変化）を検知して World を作り直すホットリロードを繋ぐ。
    /// reloadOn と同型の関数を渡せるので、F1 と保存検知に同じ関数を繋げる。
    /// 監視は withDebug 有効時のみ・約 0.5 秒間隔。読めない・壊れたときの扱いは f の責務
    /// （今の World をそのまま返す fail-open を推奨）。
    /// 同じパスを複数回登録すると、保存のたびに登録順で全部発火する。
    pub def watchFile(path: String, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef] =
        App.App({ watch = List.append(rec(app)#watch, (path, f) :: Nil) | rec(app) })

    /// World を絵（(置き場所, 見せたい物) の列）へ投影する関数を繋ぐ。
    /// 第 1 引数の ViewCtx から既定フォント（atlas）と見えている world 矩形（visible）が取れる。
    pub def withView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                     app: App[w, ef]): App[w, ef] =
        App.App({ view = Some(v) | rec(app) })

    /// 本編より先にレンダーターゲット（描いた結果を読み返せる描き込み先）へ描く列を
    /// World から導く関数を繋ぐ。1 枚は Render.Pass（名前・クリア指定・絵の列）で、
    /// 名前がそのままテクスチャ名になる — view からは Render.sprite(名前, z) で普通の
    /// スプライトとして貼れる（部分切り出し regionRect・blend・拡大も既存の道がそのまま効く）。
    /// 複数光源の光マップ・画面を素材にする演出・残像（clear = RenderTarget.LoadOp.Keep で
    /// 前フレームを残す）に使う。
    pub def withPasses(f: w -> List[Render.Pass] \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ passes = f | rec(app) })

    /// 既定フォント以外に使うフォントの名前を宣言する（project.json の fonts[].name と同じ字）。
    /// ここで宣言した名前だけが view の ViewCtx#fontOf で引ける（宣言していない名前は既定
    /// フォントが返る）。話し手ごとに字を変えるようなゲームで使う。
    /// project.json に無い名前を宣言すると起動時に落ちる — 綴りは fonts[] と揃えること。
    pub def withFonts(names: List[String], app: App[w, ef]): App[w, ef] =
        App.App({ fonts = List.append(rec(app)#fonts, names) | rec(app) })

    /// ゲーム 1 本の標準形を 1 つのレコードで宣言する入口（初学者向け）。
    /// update は「1 本の合成関数」で渡す決まり: 複数の手続きをゲーム側で
    /// `\f w -> w |> step(f) |> interact(f)` のように中で繋いで 1 個にしてから渡す
    /// （繋ぎが Main に見えて教育的。App.game 側は複数システムを受け取らない）。
    /// reloads の各要素は watchFile 1 本に展開される。内部では
    /// make(init) |> addSystem(update) |> watchFile(各 reload) |> withView(view) に展開されるだけ。
    /// 戻り値は App なので、reloadOn（F1 リロード）・onRenderRequest（走行中の描き出し）・withDebug
    /// などの高度な口は、この後ろに従来どおり pipe で足せる。
    /// この入口が担うのは「最も普通の 1 本道」だけ — 音（withAudio）や HUD（withHudView）や
    /// quit の差し替え・複数システムの明示的な列挙が要る高度なゲームは、make から始める
    /// 従来のビルダー（addSystem / withView / …）へ降りる。
    pub def game(spec: { init = w,
                         update = (Frame, w) -> w \ ef,
                         view = (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                         reloads = List[(String, w -> w \ {Fs.FileRead})] }): App[w, ef] =
        make(spec#init)
            |> addSystem(spec#update)
            |> (app -> List.foldLeft((acc, entry) -> {
                let (path, f) = entry;
                watchFile(path, f, acc)
            }, app, spec#reloads))
            |> withView(spec#view)

    /// カメラを何 px の升目に吸着させるかを World から読む（ドット絵のゲームは 1.0・0 で切る）。
    /// 吸着させないと、主人公が半端な位置に来るたび画面全体が半画素ずれて、
    /// せっかく升目に載せた絵の輪郭がにじむ。
    ///
    /// World から読むのは、絵の側（Render.snapped）が毎フレーム同じ値を読むため —
    /// 起動時に 1 度だけ決めると、Doc を保存したときに絵だけ吸着が変わってカメラが取り残され、
    /// かえって絵がずれる。
    pub def withPixelSnap(f: w -> Float64, app: App[w, ef]): App[w, ef] =
        App.App({ pixelSnap = f | rec(app) })

    /// ドット絵のアトラス（PxSpriteAtlas.bake の生成結果）を、名前付きテクスチャとして
    /// 使えるようにする。これを繋いだうえで PxSprite.drawQuad を使うと、1 体が画素ごとの
    /// 矩形の列ではなく 1 枚のクアッドになる — 草や作物のように画面に何百と出る絵で効く。
    /// key はその画素の中身を決める全入力（色票・世代番号など）を 1 文字列にまとめた物。
    /// 同じ key の間は何も起きないので、毎フレーム呼ばれる前提でよい。
    /// 生成する仕事（bake）は World 側で 1 度だけ済ませ、ここには生成結果を渡すこと。
    pub def withSpriteAtlases(f: w -> List[AtlasUpload], app: App[w, ef]): App[w, ef] =
        App.App({ spriteAtlases = f | rec(app) })

    /// 生成したアトラスを描画部へ渡しておく（同じ key の間は何も起きない）。
    /// 同じ名前が 2 つ来たら後の方だけを使う — 両方渡すと毎フレーム key が入れ替わり、
    /// 大きさが違えば 1 枚ずつ GPU に置き去りになる。
    def uploadAtlases(uploads: List[AtlasUpload]): Unit \ GameEngine.Game =
        uploads
            |> List.foldLeft((acc, a) -> Map.insert(a#texture, a, acc), Map.empty())
            |> Map.forEach((_, a) ->
                if (a#baked#side > 0)
                    GameEngine.Game.ensureTexture(a#texture, a#key,
                        a#baked#side, a#baked#side, a#baked#pixels)
                else ())

    /// 「1 度だけ GPU に生成して使い回す静的な絵」を宣言する。key は静的な中身を決める全入力を
    /// 1 文字列にまとめたキャッシュキー（フロア id・テーマ・作り直しの世代番号など） — これが
    /// 変わったときだけエンジンが古い VBO を捨てて作り直す（テクスチャを名前で 1 度上げるのと同じ
    /// 隠蔽で、ゲームは GL ハンドルを持たない）。build はワールド座標の静的 PlacedItem を組む
    /// 純粋関数（camera はエンジンが uniform で当てるので触らない）。多角形（Poly）だけが生成の対象になり、
    /// それ以外の item は無視される。松明の炎・水面の粒・影・プレイヤーのように毎フレーム変わる
    /// 物は必ず withView 側（動的）に残すこと — 「本当に不変な物だけ」を静的層に入れる。
    /// view = None のゲームでは効かない（App が描画しないため）。
    pub def withStaticLayer(key: w -> GameEngine.StaticKey,
                            build: w -> List[Render.PlacedItem],
                            app: App[w, ef]): App[w, ef] =
        App.App({ staticLayer = Some({ key = key, build = build }) | rec(app) })

    /// タイルの層（床・壁 1 行目など、格子に敷く静的な絵）を宣言する。エンジンが Spec ごとに
    /// 1 度だけ GPU に生成し、以後は毎フレーム 1 draw call で敷く（数百〜千マスでも軽い）。
    /// Spec の tiles はサンク — 毎フレーム呼ばれるのは宣言（key の比較）だけで、
    /// 中身のリスト構築は key が変わった作り直しの時にしか走らない。
    /// key が変わったとき、または watchFile / reloadOn の読み直しが起きたときに作り直す —
    /// key は素のまま（マップ id 等）でよく、Doc の世代番号を key へ混ぜ込む必要はない。
    /// key は頻繁に転がってもよい（照明・カメラのバケツを混ぜた地形など）— GPU バッファは
    /// 層のスロット（リストの並び順）に 1 本で、作り直しは同じ VAO への入れ直しになる。
    /// そのぶん層は毎フレーム同じ並び・同じ本数で宣言すること（スロットがずれると無駄に作り直しが起きる）。
    /// f は純粋関数に限る — 理由は withStaticLayer と同じ（renderCommands の op を
    /// 効果多相にしないため）。camera は動的な絵と同じ値でエンジンが掛ける。
    /// zIndex は動的な絵と同じ z 空間で解釈される — キャラより大きい zIndex を与えれば、
    /// キャラを隠す屋根・庇もタイル層で置ける（同じ zIndex ならタイル層が奥）。CPU 投影
    /// （TileScene.toItems・F8 の凍結画面・ヘッドレス描き出し）は zIndex をそのまま動的アイテムに
    /// 載せるので、GPU と CPU で重なりの解釈は一致する。タイルのコマ替えアニメは持てない —
    /// 水面・旗のように動く絵は動的側かシェーダー面で描く。view = None のゲームでは効かない。
    pub def withTileLayers(f: w -> List[TileLayerSpec], app: App[w, ef]): App[w, ef] =
        App.App({ tileLayers = Some(f) | rec(app) })

    /// World から「画面中央に映したい world 座標」を導く関数を繋ぐ。view は world 座標のまま
    /// 書けばよく、画面へのずらしは App が引き受ける（F8 の凍結画面やリモートの注釈にも同じ
    /// カメラが効く）。追従やシェイクはゲーム側システムで World に持たせ、ここでは読むだけにする。
    pub def withCamera(f: w -> Vec2.Vec2 \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ camera = Some(f) | rec(app) })

    /// World から寄り引き倍率（大きいほど寄る）を導く関数を繋ぐ。絵のずらしと大きさの
    /// 伸縮は App が引き受ける。ズームの補間（なめらかな寄り引き）はゲーム側システムで
    /// World に持たせ、ここでは読むだけにする（withCamera の追従と同じ分担）。
    /// withCamera を繋がずにこれだけ繋ぐと、画面中央（design/2 の world 点）を軸に寄り引きする。
    /// 範囲外の倍率（0 以下・NaN・Infinity）は CameraRig.safeZoom が minZoom〜maxZoom へ
    /// 丸めるので画面は壊れない。
    pub def withZoom(f: w -> Float64 \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ zoom = Some(f) | rec(app) })

    /// camera が映してよい world の矩形（レベルの端）を導く関数を繋ぐ。見えている範囲
    /// （design/zoom）がこの矩形の外に出ないよう center を収める — 端の外の虚空が映らない。
    /// zoom と併用しても正しく効く（引くほど収まる位置が内側になる）。矩形が視界より
    /// 狭い軸は矩形の中央に固定する。withCamera（または withZoom）と併用して効く。
    pub def withCameraBounds(f: w -> Rect2.Rect2 \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ cameraBounds = Some(f) | rec(app) })

    /// 視差レイヤを末尾へ繋ぐ（addSystem と同じ「列に足す」様式）。view と同じ
    /// (ViewCtx, w) -> 絵 の関数だが、camera の動きに factor を掛けた速さで流れる:
    /// factor 1.0 = 主レイヤと同速、0.3 = 遠景、0.0 = 画面固定。ViewCtx の visible は
    /// そのレイヤの見かけの camera で計算されるので、culling もそのまま書ける。
    pub def addParallaxLayer(factor: Float64, v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                             app: App[w, ef]): App[w, ef] =
        App.App({ parallaxLayers = List.append(rec(app)#parallaxLayers, (factor, v) :: Nil) | rec(app) })

    /// カメラを掛けない絵（スコア等の HUD）を繋ぐ。ここに繋いだ絵は常に view の絵より
    /// 手前（HUD の範囲 = ZBand.hudBase 以上へ持ち上がる）。zIndex が決めるのは HUD の中の
    /// 前後だけ（0..ZBand.innerMax。はみ出しは clamp）。
    /// ViewCtx の visible は常に画面全体（position = 原点, size = design）。
    pub def withHudView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                        app: App[w, ef]): App[w, ef] =
        App.App({ hudView = Some(v) | rec(app) })

    /// 1 フレームの前後の World（{before, after}）から鳴らす音名を導く関数を繋ぐ
    /// （再生は App が引き受ける）。同じ名前が同じフレームに 2 回入っても 1 回だけ鳴る。
    pub def withAudio(sfx: { before = w, after = w } -> List[String] \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ audio = sfx | rec(app) })

    /// 鳴り続けてほしい音 1 本の宣言。name は project.json の sounds の論理名、
    /// volume は音量 0.0〜1.0、pitch は高さ（1.0 = 元のまま・2.0 で 1 オクターブ上）。
    pub type alias Sustain = { name = String, volume = Float64, pitch = Float64 }

    /// 「このフレームで鳴り続けていてほしい音」を World から導く関数を繋ぐ。
    /// 宣言に載っている間その音は鳴り続け（ループ再生）、載らなくなったフレームで止まる。
    /// 音量と高さは毎フレーム与え直せるので、速度で唸りが変わるエンジン音・強さで太る風・
    /// 走っている間だけ続く足音のように「止め時をゲームが知っている音」をこれ 1 本で書ける。
    /// 単発の効果音（当たった・取った）は withAudio の方を使う。
    pub def withSustained(f: w -> List[Sustain] \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ sustained = f | rec(app) })

    /// 音の通り道（AudioMixer.Mixer）を World から導く関数を繋ぐ。繋ぐと、withAudio の音と
    /// withSustained の音が名前ごとのバスを通る —— バスの音量・ローパス・ダッキング・連打の間引きが
    /// 掛かる（中身は AudioMixer の doc）。Doc から読んだ 1 つを返すだけでよく、場面ごとに
    /// AudioMixer.withSnapshot・withLowpassGainHF などで差し替えた物を返してもよい。
    /// 繋いだゲームでは一発の音の音量もミキサーが毎回決める（AudioStreamPlayer.setVolume で
    /// 一発の音の音量を変える書き方とは混ぜない）。
    pub def withMixer(f: w -> AudioMixer.Mixer \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ mixer = Some(f) | rec(app) })

    /// 前のフレームの宣言（名前の列）と今のフレームの宣言から、鳴らし始める音・
    /// 鳴らし続ける音・止める音を仕分ける。同じ名前が 2 回宣言されたら先勝ちで 1 本にまとめる
    /// （二重に鳴らすと同じ音源を頭から鳴らし直して途切れる）。
    /// RemoteDebug / App 本体の内部 API — ゲームからは呼ばない。
    pub def sustainOps(prev: List[String], next: List[Sustain]):
            { start = List[Sustain], keep = List[Sustain], stop = List[String] } =
        // 重複の判定は Set で、列そのものは逆順に積んで最後に 1 回戻す。宣言の並びは
        // start / keep / stop の順にそのまま出るので、Set の並びで組み直してはいけない。
        let (rev, _) = next |> List.foldLeft((acc, s) -> {
            let (kept, seen) = acc;
            if (Set.memberOf(s#name, seen)) acc else (s :: kept, Set.insert(s#name, seen))
        }, (Nil, Set.empty()));
        let fresh = List.reverse(rev);
        let living = fresh |> List.map(s -> s#name) |> List.toSet;
        let prevNames = List.toSet(prev);
        { start = List.filter(s -> not Set.memberOf(s#name, prevNames), fresh),
          keep  = List.filter(s -> Set.memberOf(s#name, prevNames), fresh),
          stop  = List.filter(n -> not Set.memberOf(n, living), List.distinct(prev)) }

    /// 終了判定を差し替える。既定は「Escape のエッジで終了」だが、モーダル表示中は
    /// Escape をパネル閉じに使いたい、といったゲームはここで自分の条件を宣言する。
    pub def quitWhen(f: (Frame, w) -> Bool \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ quit = f | rec(app) })

    /// 窓の閉じるボタン（OS の閉じる要求・GLFW の window close）をすぐの終了にせず、World へ知らせる。
    /// 閉じる要求が来たフレームで f(world) を呼び、窓は開いたまま（要求は取り消す）。ゲームはそこで
    /// 「終了しますか？」の確認を出し、はいなら quitWhen の条件を立てて終わる（終了を頼む口は quitWhen）:
    ///
    ///     App.make(init)
    ///         |> App.withCloseRequest(w -> { askingQuit = true | w })
    ///         |> App.quitWhen((_frame, w) -> w#quitConfirmed)
    ///
    /// quitWhen を差し替えると既定の「Escape で終了」は外れる（Esc も確認へ回すならゲームの入力で拾う）。
    /// 確認の窓が開いている間にもう一度閉じるボタンを押すと、f がもう一度呼ばれる。
    pub def withCloseRequest(f: w -> w \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ closeRequest = Some(f) | rec(app) })

    /// デバッグ機能（F8 の時間停止・矩形注釈・時間スクラブ）の有効 / 無効を宣言する。
    /// 既定は無効。プレイヤーに配るビルドで時間巻き戻しや内部情報の書き出しが
    /// 使えてしまわないよう、開発時だけ true を渡す（debugFromEnv と組み合わせる）。
    pub def withDebug(enabled: Bool, app: App[w, ef]): App[w, ef] =
        App.App({ debug = enabled | rec(app) })

    /// 環境変数 DEBUG が空でない値で設定されていれば true（例: `DEBUG=true flix run`）。
    /// Main から `App.withDebug(App.debugFromEnv())` の形で使う。
    pub def debugFromEnv(): Bool \ IO = debugOf(ProcessEnv.snapshot())

    /// debugFromEnv の中身。env は入口の頭で読んだ環境変数の表。
    pub def debugOf(env: Map[String, String]): Bool =
        Map.getWithDefault("DEBUG", "", env) != ""

    /// 自前描画（view = None）のゲームがデバッグ機能（F8）を使えるようにする生投影を繋ぐ。
    /// f は World を描画チャンネル（drawable / tileMap / polygon）へ投影する（描画はしない）。
    /// font は一時停止中のメッセージ表示に使うフォントアトラス名（そのゲームが持つ物を指定）。
    pub def withDebugView(font: {font = String},
                          f: w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef,
                          app: App[w, ef]): App[w, ef] =
        App.App({ debugView = Some((font#font, f)) | rec(app) })

    /// 注釈（F8 の矩形）を書き出すとき「囲った瞬間の World」をテキストにしてチケットへ
    /// world.json として同梱する関数を繋ぐ。絵の情報（annotation.json）とシムの中身を
    /// 突き合わせられるので、見た目と状態の食い違いを注釈だけで特定できるようになる。
    /// f が受け取る矩形はデザイン座標。何をどこまで書くかはゲームが決める
    /// （全フィールドでなく、調査に効く要約でよい）。
    pub def withWorldDump(f: (Rect2.Rect2, w) -> String \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ worldDump = Some(f) | rec(app) })

    /// 注釈（F8 の矩形）を書き出すとき、README の冒頭と annotation.json の "context" に載せる
    /// 「その瞬間の文脈」を繋ぐ。f は表示中の瞬間の World から、場面・台本の id と行・話す人と表情・
    /// 開いている窓のような (見出し, 値) の並びと、層の enum の列（z の名前を引く表は zRange から作る）を返す。
    /// チケットのコメントから「どの Doc のどこを直すか」をスクショと突き合わせずに引けるようにする。
    pub def withAnnotationContext(f: w -> Annotate.Context[t, h] \ ef, app: App[w, ef]): App[w, ef]
        with SortingLayer[t], ToString[t], SortingLayer[h], ToString[h] =
        App.App({ annotationContext = Some(w -> Annotate.toTable(f(w))) | rec(app) })

    /// World の 1 行サマリ（例: "phase=Playing ball=(163.2,207.9) lives=3"）を繋ぐ。
    /// リモートデバッグ（HTTP）の view=status の本文と、/step の trace の行になる。
    /// 調査に効く値だけを短く。長い一覧は withWorldDump（view=full）側に任せる。
    pub def withStatusLine(f: w -> String \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ statusLine = Some(f) | rec(app) })

    /// リモートデバッグ（HTTP）の POST /render が実行する「描き出しの実体」を繋ぐ。
    /// f は Docs から決定的な場面を組み立てて PNG に描き出し、そのファイルパスの列を返す
    /// （SceneRender.all の中身をそのまま渡せる形）。走行中のプレイ状態を読んだり変えたりしない
    /// 関数に限る — /render はゲームの進行に触れず、温まった JVM で描き直すだけのエンドポイント。
    /// f はゲームループではなく描き出し専用のスレッドで呼ばれる（描いている間もゲームは動く）。
    /// だから f の中で GL・音・ゲームと共有する可変の値に触れてはいけない。
    /// 繋がないゲームへの /render は「未対応」の応答になる。
    pub def onRenderRequest(f: Unit -> List[String] \ IO, app: App[w, ef]): App[w, ef] =
        App.App({ remoteRender = Some(f) | rec(app) })

    /// 渡した World を 1 枚の PNG に描き、書いたパスを返す関数を繋ぐ（中身は SceneRender の 1 場面と同じ描き方）。
    /// リモートデバッグの `view=shot`（`POST /step?view=shot` に `start talk node=… line=…` を送ると、
    /// 場面を組んで撮るまでが 1 往復）と、窓なしのゲーム（App.Headless.serve）が呼ぶ。
    /// f はゲームループの中で呼ばれる（撮っている間、窓は止まる）。World を変えない・GL に触れない関数に限る。
    /// 書き先はゲームが決める（例 debug/shot/<名前>.png。gallery/ に書くと reference-check が「増えた絵」と言う）。
    pub def onShotRequest(f: w -> String \ IO, app: App[w, ef]): App[w, ef] =
        App.App({ shot = Some(f) | rec(app) })

    /// リモートデバッグ（HTTP）の任意パス（例: "/save"）に応えるハンドラを繋ぐ。
    /// f はクエリ（?slot=1 → Map。+ と %20 は空白に戻る）と今の World を受け取り、
    /// Ok(次の World) か Err(理由) を返す。Ok なら world を差し替えて "ok"、
    /// Err なら "error: 理由" を応答する。
    /// スレッドの取り決め（RemoteDebug と同じ）: HTTP のスレッドは World に一切触れない。
    /// リクエストはキューに積まれ、ゲームループが 1 フレームに 1 件だけ、このハンドラを
    /// 自分のスレッドで適用して world を差し替える（/step と同じ流儀）。だから f の中で
    /// World を同期に読み書きしてよいが、長い仕事を書くとその間ゲームは止まる。
    /// /help など既定ルートと同じパスは登録しても選ばれない（既定ルートが先に照合される）。
    pub def onRequest(path: String, f: (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead},
                      app: App[w, ef]): App[w, ef] =
        App.App({ remoteHandlers = List.append(rec(app)#remoteHandlers, (path, f) :: Nil) | rec(app) })

    /// 物理・当たり判定を固定刻み（dtSeconds 秒）で進める accumulator 方式を有効にする。
    /// 実フレームの経過秒を貯め、刻みの倍数だけ updateSystems を 0〜5 回サブステップで回し、
    /// 端数は次フレームへ持ち越す（fixedSteps が芯）。5 回を超える貯金は処理落ち時に
    /// ゲームが延々追いつこうとしないよう切り捨てる（エンジン側の maxDeltaTime は 1 フレームの
    /// 実 dt 自体の上限で、こちらはサブステップ回数の上限 — 役割が異なるので併用してよい）。
    /// justPressed / mouseClicked / mouseMoved / wheel は最初のサブステップだけで発火し、
    /// 2 回目以降は suppressEdges で消える（held 系のキー・ボタン押下は全サブステップで生きる）。
    /// 0 サブステップのフレームで立ったエッジは捨てず PendingEdges へバッファし、次にサブステップが
    /// 回るフレームの最初の 1 回へ合流させる（刻みがフレーム間隔より長くても入力を取り逃さない）。
    /// render・音・入力リロード・履歴・quit 判定はサブステップ単位でなく実フレーム単位のまま
    /// （音は reload 後 → 全サブステップ後の World から 1 回だけ導く）。
    /// リモートデバッグの /step は現時点でこの刻みを見ない（台本 1 行 = updateSystems 1 回のまま）。
    /// 規則の出来事で音を鳴らすなら、World の欄は Emit.Events にして audio は Emit.since で読む
    /// （出来事の欄を刻みごとに置き換えると、刻みが 0 回のフレームで前の音がもう一度鳴る）。
    /// 呼ばなければ現行の可変 dt のまま挙動は変わらない。
    pub def withFixedStep(dtSeconds: Float64, app: App[w, ef]): App[w, ef] =
        App.App({ fixedStep = Some(dtSeconds) | rec(app) })

    /// World の欄にある遊びの時計（Clock.Clock[c]）を、App が毎フレーム 1 回だけ進めるよう宣言する。
    /// clockOf / withClock は欄の読み書き、paceOf はこのフレームの進み方（止める理由 Run と
    /// ヒットストップの Slow）を World から導く —— withSustained と同じく、ゲームは宣言するだけで
    /// 適用は App が受け持つ。進めるのは系（addSystem）より先なので、系の中の Clock.dtOf は
    /// このフレームに進んだ秒、Clock.nowOf は進んだ後の今を返す。paceOf が読むのは系を回す前の
    /// World なので、ポーズを開いたフレームはまだ進み、次のフレームから止まる。
    /// withFixedStep と合わせても、時計は刻みごとではなく実フレームに 1 回、実時間の dt で進む
    /// （刻みの中で遊びを進める秒は frame#dt のまま。止めるなら刻みの中で Clock.dtOf(..) == 0.0 を見る）。
    /// 時計が何本あっても宣言の順に進める。テストで系を直に呼ぶなら、先に tickClocks で同じ進め方をする。
    pub def addClock(spec: { clockOf = w -> Clock.Clock[c], withClock = (Clock.Clock[c], w) -> w,
                             paceOf = w -> Clock.Pace[c, r] },
                     app: App[w, ef]): App[w, ef] =
        let tick = (dt, world) -> spec#withClock(Clock.advance(spec#paceOf(world), dt, spec#clockOf(world)), world);
        App.App({ clocks = List.append(rec(app)#clocks, tick :: Nil) | rec(app) })

    // ── 外への出力（系は IO を持たず、App が実機のフレームの後でだけ触る）──

    /// マウスの矢印の見せ方（withCursor の宣言）。icon = 形・visible = 見せるか。
    pub type alias CursorSpec = { icon = GameEngine.Cursor, visible = Bool }

    /// withCursor の宣言を最後にどう当てたか。Stale = まだ当てていない・止めた画面の見た目が上書きした
    /// （どちらも次に動く拍で当て直す）。
    pub enum CursorState {
        case Applied(CursorSpec)
        case Stale
    }

    /// 矢印を見せるか。LeaveToApp = 触らない（今の見せ方のまま）。
    pub enum Visibility with Eq, ToString {
        case Show
        case Hide
        case LeaveToApp
    }

    /// ウィンドウへ当てる矢印の見た目（形・見せるか）。
    pub enum CursorLook with Eq, ToString {
        case CursorLook(GameEngine.Cursor, Visibility)
    }

    /// 止めた画面の出入りの見た目（ウィンドウタイトルのバッジを出すか・矢印）。
    pub enum HaltLook with Eq, ToString {
        case HaltLook(Bool, CursorLook)
    }

    /// 毎フレーム「マウスの矢印をどう見せたいか」を World から宣言する。App は宣言が変わったフレームだけ当て、
    /// F8 で止めている間は十字に上書きする（再開した拍に宣言を当て直す）。系の中で setCursor を呼ばない ——
    /// 呼ぶと /step・台本・F8 の再開で矢印の形が World とずれる。
    pub def withCursor(f: w -> CursorSpec, app: App[w, ef]): App[w, ef] =
        App.App({ cursor = Some(f) | rec(app) })

    /// 跳んだ拍（起動・START・/start・/step・/flow?apply・F8 の巻き戻しからの再開）に、出力をどう扱うか。
    pub enum OnJump with Eq, ToString {
        /// 跳んだ先の鍵を「書いた」ことにする。遊んで変わった時だけ書く（セーブ —— 作り物の場面で上書きしない）
        case Skip
        /// 跳んだ先も次の実機のフレームで書く（表示中の Doc の名乗り —— いま映っている物を言い続ける）
        case Write
    }

    /// 外への出力 1 本: keyOf = 書く中身を決める鍵（"" = 書く物が無い）・write = 書く・onJump = 跳んだ拍の扱い。
    pub type alias Output[w] = { keyOf = w -> String, write = w -> Unit \ Fs.FileWrite, onJump = OnJump }

    /// 鍵が最後に書いた鍵と違う実機のフレームの後で、1 回だけ write を呼ぶ出力を足す（セーブ・名乗り）。
    /// 鍵は読み直しと系の後の World から取る。/step・trace・台本・F8 で止めている間は書かない ——
    /// 系の中で書くと、台本を流すだけ・/step を叩くだけでセーブが書かれる。
    /// 書けなかった時の扱いは write が持つ（docs/error-handling.md の決まり 3: 1 行言って続ける）。
    pub def addOutput(output: Output[w], app: App[w, ef]): App[w, ef] =
        App.App({ outputs = List.append(rec(app)#outputs, output :: Nil) | rec(app) })

    /// Doc の一覧表（DocTable）から、保存即反映の監視（watchFile）・F1 の一括読み直し（reloadOn）・
    /// Studio へ「表示中」を名乗る出力（debug/active-docs.json。跳んだ先も名乗る）を 1 度に配線する。
    /// App.game の reloads と一緒に使わない（同じ Doc を 2 度読み直す）。
    pub def withDocTable(rows: List[DocTable.Entry[w]], app: App[w, ef]): App[w, ef] =
        DocTable.reloads(rows)
            |> List.foldLeft((acc, entry) -> { let (path, f) = entry; watchFile(path, f, acc) }, app)
            |> reloadOn(GameEngine.Key.F1, world -> DocTable.reloadAll(rows, world))
            |> addOutput({ keyOf = world -> ActiveDocs.fingerprint(DocTable.activeDocs(rows, world)),
                           write = world -> ActiveDocs.write(DocTable.activeDocs(rows, world)),
                           onJump = OnJump.Write })

    // ── 始まりの登録簿（好きな場面から起動・テスト・flow の start）──

    /// 始まり 1 つ: name = 名前（START・flow の start で書く字）・doc = 何の場面か（GET /starts と語彙に載る）・
    /// args = 既定の引数（書いた引数が上書きする）・build = 新しく作った初期の World と引数から場面を組む。
    /// build は純粋に書く: 走っている World は渡らないし、ファイルも読まない（読む物は引数を `@パス` にすると
    /// App が読んで中身を渡す。記録はその中身を残すので、再生で同じ場面になる）。
    pub type alias Start[w] = { name = String, doc = String, args = Map[String, String],
                                build = (w, Map[String, String]) -> Result[String, w] }

    /// 始まりの登録簿を繋ぐ。繋いだゲームは起動もここを通る（環境変数 START が無ければ先頭の始まり）。
    /// 場面を組む手順を動画・テスト・flow ごとに手で書くと、同じ場面のはずの物が少しずつずれる。
    pub def withStarts(starts: List[Start[w]], app: App[w, ef]): App[w, ef] =
        App.App({ starts = starts | rec(app) })

    /// 新しく作った初期の World: init（design 解像度から）+ 起動時の系 + Doc を全部読み直した物
    /// （F1 の reloadOn の関数 = DocTable.reloadAll、無ければ監視の関数を登録順に）。
    /// 読み直すのは、main が起動の時に読んだ Doc ではなく今のファイルで場面を組むため（/start・記録の再生）。
    pub def freshWorld(app: App[w, ef], design: Vec2.Vec2): w \ ef + Fs.FileRead =
        let init = rec(app)#init;
        let started = List.foldLeft((acc, sys) -> sys(acc), init(design), rec(app)#startupSystems);
        match rec(app)#reload {
            case Some((_, reloadAll)) => reloadAll(started)
            case None => List.foldLeft((acc, entry) -> { let (_, f) = entry; f(acc) }, started, rec(app)#watch)
        }

    /// 登録簿の名前の列（登録順）。
    pub def startNames(app: App[w, ef]): List[String] =
        rec(app)#starts |> List.map(start -> start#name)

    /// 名前の始まりを、新しく作った初期の World から組む。args は既定の引数を上書きし、値が `@パス` の
    /// 引数はそのファイルの中身にする（無いファイルの引数は外す）。知らない名前・組めない引数は理由つきの Err。
    pub def buildStart(app: App[w, ef], design: Vec2.Vec2, name: String, args: Map[String, String]): Result[String, w] \ ef + Fs.FileRead =
        match rec(app)#starts |> List.find(start -> start#name == name) {
            case None => Err("始まり '${name}' は登録簿に無い${Suggest.hint(name, startNames(app))}")
            case Some(start) => buildStartFrom(start, freshWorld(app, design), name, args)
        }

    /// buildStart の、初期の World を渡す形（窓なしのゲームが Doc の読み直しを取り置いた World から組む）。
    /// fresh は freshWorld(app, design) と同じ物であること。
    pub def buildStartOn(app: App[w, ef], fresh: w, name: String, args: Map[String, String]): Result[String, w] \ Fs.FileRead =
        match rec(app)#starts |> List.find(start -> start#name == name) {
            case None        => Err("始まり '${name}' は登録簿に無い${Suggest.hint(name, startNames(app))}")
            case Some(start) => buildStartFrom(start, fresh, name, args)
        }

    def buildStartFrom(start: Start[w], fresh: w, name: String, args: Map[String, String]): Result[String, w] \ Fs.FileRead =
        let resolved = loadArgs(Map.unionWith((given, _) -> given, args, start#args));
        let build = start#build;
        build(fresh, resolved) |> Result.mapErr(why -> "始まり '${name}': ${why}")

    /// 引数の値が `@パス` ならファイルの中身に置き換える（読めないファイルの引数は外す —— 「無いセーブ」は正常）。
    pub def loadArgs(args: Map[String, String]): Map[String, String] \ Fs.FileRead =
        args |> Map.foldLeftWithKey((acc, key, value) ->
            if (String.startsWith(prefix = "@", value))
                match Fs.FileRead.read(String.dropLeft(1, value)) {
                    case Ok(text) => Map.insert(key, text, acc)
                    case Err(_)   => acc
                }
            else Map.insert(key, value, acc), Map.empty())

    /// `feedHome t=10` の形（flow の start の行・START・POST /start と同じ）を名前と引数に分ける。
    pub def parseStartLine(text: String): Result[String, (String, Map[String, String])] =
        match String.words(text) {
            case Nil => Err("始まりの名前が無い（START=\"名前 key=value…\"）")
            case name :: rest =>
                rest |> List.foldLeft((acc, word) -> forM (
                    args <- acc;
                    pair <- match String.indexOfLeft({substr = "="}, word) {
                        case Some(i) if i > 0 => Ok((String.takeLeft(i, word), String.dropLeft(i + 1, word)))
                        case _ => Err("始まりの引数 '${word}' は key=value で書く")
                    }
                ) yield { let (key, value) = pair; Map.insert(key, value, args) }, Ok(Map.empty()))
                |> Result.map(args -> (name, args))
        }

    /// root の project.json の design 解像度（読めなければ 0×0 —— init が画面の大きさを読まないゲームはそれで足りる）。
    /// 画面を開かない所（テスト・flow の headless の入口）が Frame#viewport と init に渡す。
    pub def loadProjectDesign(root: String): Vec2.Vec2 \ Fs.FileRead =
        match ProjectLoader.loadProject(root) {
            case Ok(loaded) => { x = Int32.toFloat64(loaded#config#designWidth), y = Int32.toFloat64(loaded#config#designHeight) }
            case Err(_)     => Vec2.zero()
        }

    /// テストで名前の始まりを組む（組めなければテストの前提が破れているので bug! で止める）。
    /// design 解像度はゲームの根の project.json から読む（読めなければ 0×0 —— init が画面の大きさを読まないゲームはそれで足りる）。
    pub def startOrBug(app: App[w, ef], name: String, args: Map[String, String]): w \ ef + Fs.FileRead =
        match buildStart(app, loadProjectDesign("."), name, args) {
            case Ok(world) => world
            case Err(why)  => bug!("App.startOrBug: ${why}")
        }

    // ── flow（e2e の手順・動画の手順・遊んだ記録の再生）──

    /// flow の語彙の表を繋ぐ（使い方の全文は engine_world/src/Flow.flix 冒頭）。
    pub def withFlow(table: Flow.Table[w], app: App[w, ef]): App[w, ef] =
        App.App({ flow = table | rec(app) })

    /// World の指紋の元の文字を選ぶ関数を繋ぐ。遊んだ記録が 60 フレームごとに `expect fp=…` を書き、
    /// 再生が最初に食い違ったフレームを指す。入れる欄はゲームが選ぶ —— 進行に効く欄（場面・時計・
    /// 盤・カーソル・種）だけを短く並べ、Doc の中身や絵のアトラスは入れない（長い文字を毎フレーム作ると遅い）。
    pub def withFingerprint(f: w -> String, app: App[w, ef]): App[w, ef] =
        App.App({ fingerprint = Some(f) | rec(app) })

    /// 起動の World: 登録簿が無ければ init + 起動時の系（今までどおり）、あれば START（無ければ先頭の始まり）。
    /// 返すのは起動の World と、通った始まり（名前と書いた引数。登録簿が無ければ None）。
    def bootWorld(app: App[w, ef], design: Vec2.Vec2, env: Map[String, String]): Result[String, (w, Option[(String, Map[String, String])])] \ ef + Fs.FileRead =
        match List.head(rec(app)#starts) {
            case None =>
                let init = rec(app)#init;
                Ok((List.foldLeft((acc, sys) -> sys(acc), init(design), rec(app)#startupSystems), None))
            case Some(first) =>
                let line = Map.getWithDefault("START", "", env);
                let wanted = if (String.isEmpty(String.trim(line))) Ok((first#name, Map.empty()))
                             else parseStartLine(line) |> Result.mapErr(why -> "START: ${why}");
                forM (
                    chosen <- wanted;
                    world <- { let (name, args) = chosen; buildStart(app, design, name, args) |> Result.mapErr(why -> "START: ${why}") }
                ) yield (world, Some(chosen))
        }

    /// 指紋の元の文字（withFingerprint を繋いだゲームだけ）。
    def fingerprintText(app: App[w, ef], world: w): Option[String] =
        rec(app)#fingerprint |> Option.map(f -> f(world))

    /// 記録に跳んだ拍の行（rewind・close）を書き、その後の World の指紋を覚え直す。
    def recordJump(app: App[w, ef], recorder: Option[Flow.Record.Recorder], text: Option[String], world: w): Unit \ IO =
        match recorder {
            case None => ()
            case Some(rec) =>
                Option.forEach(t -> Flow.Record.line(rec, t), text);
                Flow.Record.resetFingerprint(rec, fingerprintText(app, world))
        }

    /// リモートの口が返した記録の材料（行と流したフレーム）を書き、その後の World の指紋を覚え直す。
    def recordItems(app: App[w, ef], recorder: Option[Flow.Record.Recorder], items: List[Flow.Record.Item], world: w): Unit \ IO =
        match recorder {
            case None => ()
            case Some(rec) =>
                items |> List.forEach(item -> match item {
                    case Flow.Record.Item.Line(text)          => Flow.Record.line(rec, text)
                    case Flow.Record.Item.Started(text)       => Flow.Record.started(rec, text)
                    case Flow.Record.Item.Played(frame, text) => Flow.Record.frame(rec, frame, text)
                });
                Flow.Record.resetFingerprint(rec, fingerprintText(app, world))
        }

    /// addClock で宣言した時計を、実時間 dt で 1 回ずつ進める（advanceFrame が系の前に呼ぶ）。
    /// ゲームのコードからは呼ばない（2 回進めると 1 回目の区間の音が消える。lint-forbid の clock-advance）。
    /// テストで系を直に呼ぶときだけ、実機と同じ順（tickClocks → 系）を組むのに使う。
    pub def tickClocks(app: App[w, ef], dt: Float64, world: w): w =
        List.foldLeft((acc, tick) -> tick(dt, acc), world, rec(app)#clocks)

    // ── 純粋な芯（テストはここを直接叩く）──

    /// 前フレームと今フレームのキー集合から Frame を組む。justPressed は差分
    /// （今あって前に無いキー）なので、押しっぱなしはエッジにならない。
    /// マウスも同じ考え方: mouseClicked は「今押されていて前は押されていない」エッジ、
    /// mouseMoved は前フレームとの座標比較（最初のフレームは prevCursor = None で false）。
    /// wheel はバックエンドが貯めた 1 フレームぶんの量を素通しする。
    /// realNow は 0 秒で組み、advanceFrame が StepState の実時間の時計で置き直す。
    pub def frameOf(prev: {prev = Set[GameEngine.Key]},
                    current: {current = Set[GameEngine.Key]}, dt: Float64,
                    viewport: Vec2.Vec2,
                    cursor: {prevCursor = Option[Vec2.Vec2], cursor = Vec2.Vec2},
                    mouse: {prevDown = Bool, down = Bool, wheel = Float64}): Frame =
        { down = current#current,
          justPressed = Set.difference(current#current, prev#prev),
          dt = dt,
          viewport = viewport,
          cursor = cursor#cursor,
          mouseDown = mouse#down,
          mouseClicked = mouse#down and not mouse#prevDown,
          mouseMoved = Option.exists(p -> p#x != cursor#cursor#x or p#y != cursor#cursor#y, cursor#prevCursor),
          wheel = mouse#wheel,
          realNow = Clock.zero(),
          padTouched = false }

    /// withFixedStep の accumulator。持ち越し carry と実フレームの経過秒 realDt を足し、
    /// fixedDt の倍数だけサブステップ回数を出し、端数を次フレームへの持ち越しとして返す。
    /// 回数は 5 を上限にクランプする（暴走防止）。上限に達したフレームは処理落ちの貯金を
    /// 素通しさせず切り捨てる（carry を 0 にする）— そうしないと処理落ちが翌フレーム以降に
    /// 尾を引き、追いつこうとしてさらに重くなる悪循環になる。
    pub def fixedSteps(carry: Float64, realDt: Float64, fixedDt: Float64): (Int32, Float64) =
        let total = carry + realDt;
        let rawSteps = Float64.floor(total / fixedDt);
        if (rawSteps > 5.0)
            (5, 0.0)
        else
            (Float64.tryToInt32(rawSteps) |> Option.getWithDefault(0), total - rawSteps * fixedDt)

    /// withFixedStep の 2 サブステップ目以降に渡す Frame: エッジ 4 種（justPressed /
    /// mouseClicked / mouseMoved / wheel）だけを「今フレームでは既に消費済み」に潰す。
    /// down / mouseDown のような押しっぱなし状態はそのまま残すので、複数サブステップに
    /// またがっても連続入力（移動など）は各回とも効く。
    pub def suppressEdges(frame: Frame): Frame =
        { justPressed = Set.empty(), mouseClicked = false, mouseMoved = false, wheel = 0.0 | frame }

    /// 0 サブステップのフレームで捨てられそうになったエッジのバッファ。エッジは prev との
    /// 差分なので、同じ押下は次の実フレームでは二度と立たない — 消費されるまでここに
    /// 残し、最初のサブステップが来た瞬間に合流させる（fixedDt がフレーム間隔より
    /// 長い構成でも入力を取り逃さないためのバッファ）。
    pub type alias PendingEdges = {
        justPressed = Set[GameEngine.Key],
        mouseClicked = Bool,
        mouseMoved = Bool,
        wheel = Float64
    }

    /// withFixedStep がフレームをまたいで持ち回す状態（持ち越し秒 + 未消費エッジ）。
    /// 可変 dt（fixedStep = None）のゲームでは常に初期値のまま動かない。
    /// real は実時間の時計（advanceFrame が毎フレーム進め、Frame#realNow に置く）。
    pub type alias StepState = { carry = Float64, pending = PendingEdges, real = Clock.Clock[Clock.Real] }

    /// 起動直後の StepState（貯金ゼロ・未消費エッジなし）。
    pub def freshStepState(): StepState =
        { carry = 0.0, pending = noPending(), real = Clock.start() }

    /// 未消費エッジなし。
    def noPending(): PendingEdges =
        { justPressed = Set.empty(), mouseClicked = false, mouseMoved = false, wheel = 0.0 }

    /// バッファしたエッジを今フレームの Frame へ合流させる: justPressed は和集合・
    /// クリックと移動は「どちらかで起きた」・wheel は量なので加算。
    /// held 系（down / mouseDown / cursor / dt）は今フレームの値をそのまま使う。
    pub def mergeEdges(pending: PendingEdges, frame: Frame): Frame =
        { justPressed = Set.union(pending#justPressed, frame#justPressed),
          mouseClicked = pending#mouseClicked or frame#mouseClicked,
          mouseMoved = pending#mouseMoved or frame#mouseMoved,
          wheel = pending#wheel + frame#wheel | frame }

    /// Frame からエッジ 4 種を抜き出してバッファの形にする（0 ステップのフレームの持ち越し用）。
    pub def pendingOf(frame: Frame): PendingEdges =
        { justPressed = frame#justPressed, mouseClicked = frame#mouseClicked,
          mouseMoved = frame#mouseMoved, wheel = frame#wheel }

    /// システムの列を追加順（左から右）に World へ畳み込む。
    pub def applySystems(frame: Frame, systems: List[(Frame, w) -> w \ ef], world: w): w \ ef =
        List.foldLeft((acc, sys) -> sys(frame, acc), world, systems)

    /// 1 実フレームぶんの updateSystems 適用。fixedStep 未指定なら現行どおり frame を 1 回
    /// そのまま流すだけ（挙動不変・pending も動かない）。指定していれば fixedSteps で回数を
    /// 決め、取り置いたエッジを合流した Frame（dt は固定値）で 0〜5 回サブステップする
    /// （2 回目以降は suppressEdges でエッジを消す）。
    /// 0 回のフレームは World をそのまま返し、合流済みエッジを次フレームへ取り置く —
    /// そうしないと prev 差分ゆえ二度と立たないエッジがそのまま失われる。
    /// 系より先に、実時間の時計（Frame#realNow に置く）と addClock の時計を実時間の dt で 1 回進める
    /// （刻みが 0 回のフレームも進む —— 止めていないのに時計が止まると、次のフレームで区間が飛ぶ）。
    pub def advanceFrame(app: App[w, ef], frame: Frame, state: StepState, world: w): (w, StepState) \ ef =
        let real = Clock.advance(Clock.paceOf(Clock.Run.Running), frame#dt, state#real);
        let stamped = { realNow = Clock.nowOf(real) | frame };
        let ticked = tickClocks(app, frame#dt, world);
        match rec(app)#fixedStep {
            case None => (applySystems(stamped, rec(app)#updateSystems, ticked), { real = real | state })
            case Some(fixedDt) =>
                let (steps, nextCarry) = fixedSteps(state#carry, frame#dt, fixedDt);
                let merged = mergeEdges(state#pending, stamped);
                if (steps == 0)
                    (ticked, { carry = nextCarry, pending = pendingOf(merged), real = real })
                else {
                    let firstFrame = { dt = fixedDt | merged };
                    let laterFrame = suppressEdges(firstFrame);
                    let advanced = List.range(0, steps) |> List.foldLeft((acc, i) -> {
                        let subFrame = if (i == 0) firstFrame else laterFrame;
                        applySystems(subFrame, rec(app)#updateSystems, acc)
                    }, ticked);
                    (advanced, { carry = nextCarry, pending = noPending(), real = real })
                }
        }

    /// trace の 1 フレーム: そのフレームの入力・進める前後の World・鳴らす一発の音（同じ名前は 1 つ）・
    /// 鳴り続けていてほしい音の宣言。
    pub type alias TraceStep[w] = { frame = Frame, before = w, after = w, sounds = List[String], sustained = List[Sustain] }

    /// 画面を開かずに、frames を 1 つずつ実機と同じ経路（advanceFrame → audio → sustained）へ流し、
    /// 各フレームの前後を先頭から返す。性質テスト（PropertyTest）と、音の決まりのテストの土台。
    /// 固定刻み（withFixedStep）も実機と同じく効く。Doc の読み直し・F8・ミキサーは通さない。
    pub def trace(app: App[w, ef], frames: List[Frame], w0: w): List[TraceStep[w]] \ ef =
        let (_, _, newestFirst) = frames |> List.foldLeft((acc, frame) -> {
            let (state, world, out) = acc;
            let (step, nextState) = traceFrame(app, frame, state, world);
            (nextState, step#after, step :: out)
        }, (freshStepState(), w0, Nil));
        List.reverse(newestFirst)

    /// trace の 1 フレーム分。次のフレームの入力を World から組む道具（PropertyTest）はこれを回す。
    pub def traceFrame(app: App[w, ef], frame: Frame, state: StepState, world: w): (TraceStep[w], StepState) \ ef =
        let derive = rec(app)#audio;
        let declare = rec(app)#sustained;
        let (after, nextState) = advanceFrame(app, frame, state, world);
        let sounds = List.distinct(derive({ before = world, after = after }));
        ({ frame = { realNow = Clock.nowOf(nextState#real) | frame }, before = world, after = after, sounds = sounds, sustained = declare(after) }, nextState)

    /// view 由来の絵（world）に camera（center と zoom。等倍は 1.0）を掛け、hud の絵を
    /// 後ろに繋ぐ。hud には掛けない。center = None でも zoom ≠ 1.0 なら画面中央
    /// （design/2 の world 点）を軸に寄り引きする（withZoom だけ繋いだゲームと同じ規則）。
    /// 2 つの絵は同型のリストなので record で名前渡しにして取り違えを防ぐ。
    /// hud の z は HUD の範囲（ZBand.liftHud）へ持ち上げる — world がどれだけ大きい z を
    /// 使っても（爆発 z=1000 等）、hud はその手前に出る。hud の中の前後は元の z の
    /// まま（0..ZBand.innerMax に clamp）。world 側の z には触らない。
    pub def composeScene(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2,
                         items: { world = List[Render.PlacedItem], hud = List[Render.PlacedItem] }): List[Render.PlacedItem] =
        let shifted = match zoomedCenter(center, zoom, design) {
            case None    => items#world
            case Some(c) => CameraRig.centerOn(c, zoom = zoom, design = design, items#world)
        };
        let lifted = items#hud |> List.map(placed ->
            { item = zMapped(ZBand.liftHud, placed#item) | placed });
        // hud が空のフレームで List.append に world 全件を cons し直させない。
        // world 側が空のときの分岐は要らない — append は第 1 引数が空なら O(1) で lifted を返す。
        if (List.isEmpty(lifted)) shifted
        else List.append(shifted, lifted)

    /// camera 無しでも zoom があれば「画面中央の world 点 = design/2」を軸に据える正規化。
    /// composeScene と visibleOf が同じ規則を共有するための1点
    /// （NaN も 1.0 と等しくないので Some 側へ落ち、下流の safeZoom が丸める）。
    def zoomedCenter(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2): Option[Vec2.Vec2] =
        match center {
            case Some(c) => Some(c)
            case None    => if (zoom != 1.0) Some(Vec2.div(design, 2.0)) else None
        }

    /// camera 中心と zoom から、画面に見えている world の矩形を出す（大きさ design/zoom。
    /// center = None かつ等倍なら design 全体）。view へ渡す ViewCtx の visible の源。
    /// composeScene と同じ正規化（zoomedCenter）を通るので、culling と絵は必ず一致する。
    pub def visibleOf(center: Option[Vec2.Vec2], zoom: Float64, design: Vec2.Vec2): Rect2.Rect2 =
        match zoomedCenter(center, zoom, design) {
            case Some(c) => CameraRig.visibleRect(c, zoom = zoom, design = design)
            case None    => { position = Vec2.zero(), size = design }
        }

    /// 監視中パスのうち「World を作り直すべき物」を watch の登録順で返す: current で見えて
    /// prev と更新時刻が違うパスと、prev に無く current に現れたパス（新規出現）。
    /// current に無いパス（消えた・読めない）は発火しない — 保存の途中で一瞬読めなくなる
    /// エディタがあるので、見えなくなった事実では作り直さない。
    pub def changedPaths(watch: List[String], prev: Map[String, Int64], current: Map[String, Int64]): List[String] =
        watch |> List.filter(p -> match Map.get(p, current) {
            case None    => false
            case Some(t) => Map.get(p, prev) |> Option.forAll(prevT -> prevT != t)
        })

    // ── ランナー: 起動して、閉じるまで回す ──

    /// App を走らせる単一の効果多相ランナー。startup を 1 回だけ畳み込み、いま押されているキーを prev の
    /// 種にしてループへ入る（起動時にすでに押されているキーは、一度離すまでエッジにならない）。
    ///
    /// ウィンドウ（GameEngine.Game/Audio）・Fs・ゲーム固有の effect（ef）は 隠蔽せず呼び出し側の
    /// Main が `with` で明示的に張る（effect-oriented の素直な形）。効果多相なので純粋なゲーム（ef = {}）も
    /// effect で状態を持つゲームも同じ launch を使う。前者は Main で LwjglLayer + Fs を張り、後者は加えて
    /// 自分の effect ハンドラ束を張った内側で呼ぶ。
    /// デバッグ有効（withDebug）かつ環境変数 DEBUG_HTTP_PORT があれば、リモートデバッグの
    /// HTTP エンドポイントも一緒に立ち上がる（例: `DEBUG=1 DEBUG_HTTP_PORT=7777 flix run`）。
    pub def launch(app: App[w, ef]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + Fs.FileWrite + IO) =
        // 下ごしらえの間、画面には読み込み中の起動画面が出たまま残る（描き直さないので止まって見えるが、
        // 出し直す入口をここに作ると、間引きも中止スイッチも持たない 2 つ目の経路が生まれる）。
        let env = ProcessEnv.snapshot();
        let recorder = if (rec(app)#debug) Flow.Record.pathOf(env) |> Option.flatMap(Flow.Record.open) else None;
        let design = GameEngine.Game.getViewportRect()#size;
        // 記録するなら、起動の World が読んだファイルの中身も拾って start の行に載せる（再生が同じ Doc で始まる）。
        let (booted, files) = match recorder {
            case Some(_) => Flow.Record.captureReads(() -> bootWorld(app, design, env))
            case None    => (bootWorld(app, design, env), Map.empty())
        };
        match booted {
            // 知らない始まりの名前で黙って先頭の場面から始めると、別の場面を見て直していることに気づけない。
            case Err(why)  => System.err.println("[App] ${why}"); Option.forEach(Flow.Record.close, recorder)
            case Ok((world0, started)) =>
                Option.forEach(rec -> {
                    match started {
                        case Some((name, args)) => Flow.Record.started(rec, Flow.Record.startLine(name, args, files))
                        case None => Flow.Record.line(rec, "# App.withStarts が無いので、再生は flow の既定の World（init）から")
                    };
                    Flow.Record.resetFingerprint(rec, fingerprintText(app, world0))
                }, recorder);
                launchFrom(app, world0, recorder, env);
                Option.forEach(Flow.Record.close, recorder)
        }

    /// 起動の World が決まった後の launch（リモートデバッグ・監視・ループ）。
    def launchFrom(app: App[w, ef], world0: w, recorder: Option[Flow.Record.Recorder], env: Map[String, String]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + Fs.FileWrite + IO) =
        let bridge = if (canDebug(app)) Option.map(port -> RemoteDebug.start(port, rec(app)#remoteRender),
                                                   RemoteDebug.portToOpenOf(env))
                     else None;
        // 起動時点の更新時刻を「発火なしで」用意しておく — 用意しないと最初のポーリングが
        // 全パスを新規出現と見なし、init 直後にもう一度リロードが走ってしまう。
        let watch0 = if (rec(app)#debug and not List.isEmpty(rec(app)#watch))
                         { sincePoll = 0.0, mtimes = statMtimes(List.map(fst, rec(app)#watch)) }
                     else freshWatchState();
        // キーと同じく、起動時にすでに押されているボタンは一度離すまでエッジにならない。
        // カーソルの「前の位置」はまだ無い（None）ので、最初のフレームの mouseMoved は false。
        // 固定ステップの状態（持ち越し秒と未消費エッジ）は空から始める。
        loop(app, { world = world0, prevKeys = InputEvent.currentKeys(),
                    prevMouseDown = GameEngine.Game.isMouseButtonPressed(GameEngine.MouseButton.Left),
                    prevCursor = None, anno = Annotate.initial(), history = Nil,
                    bridge = bridge, remoteHold = false, stepState = freshStepState(),
                    watchState = watch0, sustaining = Nil, mixState = AudioMixer.initial(),
                    soundUses = { oneShot = Set.empty(), looped = Set.empty() },
                    tileCache = freshTileCache(),
                    glyphSeen = None, budgetWarned = false,
                    warnOnce = warnOnceWith(Ref.fresh(Static, Set.empty())),
                    cursorShown = CursorState.Stale, outputKeys = keysAfterJump(app, world0, Nil), recorder = recorder });
        Option.forEach(RemoteDebug.shutdown, bridge)

    /// 時間スクラブ用に持ち回す直近の World の数（60fps で約 30 秒）。
    /// World は不変値なので、保持しているのは共有構造への参照だけで軽い。
    /// flow の実行器も同じ数だけ持つ（rewind が F8 と同じ所まで戻れるように）。
    pub def historyLimit(): Int32 = 1800

    /// loop が次のフレームへ渡し続ける物。app（不変）は入れない — 状態に混ぜると
    /// 「フレームごとに変わりうる物」に見える。
    // 平らな 1 枚にしている。種類ごとに入れ子へ畳むと、更新が
    // { debug = { hold = x | st#debug } | st } になって呼ぶ側が短くならない。
    type alias LoopState[w] = {
        world = w,
        prevKeys = Set[GameEngine.Key], prevMouseDown = Bool, prevCursor = Option[Vec2.Vec2],
        anno = Annotate.State, history = List[w],
        bridge = Option[RemoteDebug.Bridge], remoteHold = Bool,
        stepState = StepState, watchState = WatchState, sustaining = List[String],
        mixState = AudioMixer.State, soundUses = SoundUses,
        tileCache = TileCache, glyphSeen = Option[Int64],
        // 「絵の値段が予算を超えていると 1 回だけ知らせた」印。毎フレーム出すと
        // 遅い画面がさらに遅くなり、ログも読めなくなる。
        budgetWarned = Bool,
        // View の組み立てが既定値で続けたことを 1 回だけ知らせる口（ViewCtx#warnOnce。見た文面はゲームの間ずっと覚える）。
        warnOnce = String -> Unit,
        // withCursor の宣言を最後にどう当てたか（止めている拍は Stale にして、動き出した拍に当て直させる）。
        cursorShown = CursorState,
        // 出力（addOutput）ごとの最後に書いた鍵（outputs と同じ順）。
        outputKeys = List[String],
        // 遊んだ記録（DEBUG の起動・FLOW_RECORD=0 で止まる）。None = 書かない。
        recorder = Option[Flow.Record.Recorder]
    }

    /// リモートコマンドを捌いた後に残る 3 つの進み方。
    /// loop から切り出した内部 API — ゲームからは呼ばない。
    pub enum Branch with Eq, ToString {
        /// 時間が止まっている。World には触れず、凍結した絵の上で注釈とスクラブだけが動く
        case Paused
        /// 停止を抜けるフレーム。スクラブ位置の World から再開するので、まだ World を進めない
        case Resuming
        /// ふつうのフレーム。World を進めて描く
        case Running
    }

    /// F8 と停止状態から、このフレームの進み方と「F8 が今トグルされたか」を決める。
    ///
    /// - `remoteHold`（HTTP 側が停止の主導権を持っている間）は F8 を殺す。/resume で戻す
    /// - デバッグ機能が使えない構成（canDebug が偽）でも F8 は効かない
    /// - 停止を抜けるフレームは Running でなく Resuming。ここで World を進めると、
    ///   スクラブで巻き戻した瞬間が 1 フレーム分だけ飛ぶ
    ///
    /// loop から切り出した内部 API — ゲームからは呼ばない。
    pub def decideBranch(input: { f8Pressed = Bool, canDebug = Bool,
                                  remoteHold = Bool, wasPaused = Bool }):
                        { branch = Branch, toggled = Bool } =
        let toggled = input#f8Pressed and input#canDebug and not input#remoteHold;
        let pausedNow = if (toggled) not input#wasPaused else input#wasPaused;
        let branch = if (pausedNow) Branch.Paused
                     else if (input#wasPaused) Branch.Resuming
                     else Branch.Running;
        { branch = branch, toggled = toggled }

    /// 毎フレーム: キーを読み Frame に埋め込む → 終了判定 → リモートコマンド → リロード →
    /// 1 フレームの中身（traceFrame。時計と系で World を進め、音の名前を導く。trace・台本・/step と同じ 1 本）→ 音を鳴らす →
    /// 描画（renderFrame。進んだ World を絵に写す）→ 末尾再帰。前フレームのキー集合・
    /// アノテーション状態・直近の World 履歴は引数で次のフレームへ渡し続ける。
    /// 「進める（advanceFrame）」と「描く（renderFrame）」がこの順で必ず分かれているのが芯 —
    /// 描画は進んだ後の World を読むだけで、World を書き換えない（モジュール冒頭の2役割を参照）。
    ///
    /// F8 で時間停止をトグルできる（view を繋いだゲームのみ）。停止中は World に触れず、
    /// 凍結した絵の上でズーム・パン・矩形ドラッグ（注釈の書き出し）と、← → での時間スクラブ
    /// （直近約 5 秒を 1 フレーム単位で戻る / 進む）だけが動く。解除するとスクラブ位置の
    /// World から再開するので、狙った瞬間へ巻き戻してやり直せる。
    /// 停止中もキーと dt は毎フレーム読み続けるので、解除時に押しっぱなしキーの
    /// 誤エッジや巨大な dt は発生しない。
    ///
    /// bridge はリモートデバッグの HTTP エンドポイント（無効なら None）。どの分岐に入るかの規則は
    /// decideBranch（テストで pin してある）。
    ///
    /// stepState は withFixedStep の持ち回し（持ち越し秒 + 未消費エッジ。未使用なら初期値のまま）。
    /// 一時停止中・リモート処理中・一時停止からの再開フレームはどの分岐でも world を進めないので
    /// stepState も動かさず素通しする（巻き戻すのは World の見た目であって、貯まっていた
    /// 実時間の端数や取り置いたエッジではない）。watchState（watchFile の保存検知）も同じ扱い —
    /// World に触れない分岐では監視も動かさず素通しする。
    def loop(app: App[w, ef], st0: LoopState[w]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + Fs.FileWrite + IO) =
        let currentKeys = InputEvent.currentKeys();
        let mouseDown = GameEngine.Game.isMouseButtonPressed(GameEngine.MouseButton.Left);
        let cursorNow = GameEngine.Game.getMousePosition();
        // realNow は前のフレームまでの実時間（quit・リロード・F8 の停止が読む）。系へ渡す前に advanceFrame が進めて置き直す。
        let frame = { realNow = Clock.nowOf(st0#stepState#real), padTouched = GameEngine.Game.isGamepadTouched()
                      | frameOf(prev = st0#prevKeys, current = currentKeys, readDt(),
                            GameEngine.Game.getViewportRect()#size,
                            { prevCursor = st0#prevCursor, cursor = cursorNow },
                            { prevDown = st0#prevMouseDown, down = mouseDown,
                              wheel = GameEngine.Game.consumeScrollDelta() }) };
        let wantsQuit = rec(app)#quit;
        // shouldClose は入力の取り込み（poll）も兼ねるので 1 フレームに 1 回だけ呼ぶ。
        let closing = GameEngine.Game.shouldClose();
        // F8 で止めている間は印を下ろさずに持ち越す（止めている間の World は再開で履歴から
        // 取り直されるので、ここで渡すと知らせが消える）。動き出した最初のフレームで渡す。
        let st = if (closing and not st0#anno#paused) noticeCloseRequest(app, st0) else st0;
        if ((closing and Option.isEmpty(rec(app)#closeRequest)) or wantsQuit(frame, st#world)) ()
        else {
            // 入力の持ち越しはどの分岐でも同じなので、ここで 1 度だけ差し替える。
            let carried = { prevKeys = currentKeys, prevMouseDown = mouseDown,
                            prevCursor = Some(cursorNow) | st };
            let remoteRaw = match st#bridge {
                case Some(b) => RemoteDebug.pollRequest(b)
                case None    => None
            };
            match (remoteRaw, st#bridge) {
                case (Some(raw), Some(b)) =>
                    // リモートコマンドを処理した実フレームは通常の進行を休む
                    // （停止中は元々進まないし、実行中でも 1 フレームの息継ぎに過ぎない）。
                    let next = RemoteDebug.handleRemote(app, b, raw,
                        { world = st#world, anno = st#anno, history = st#history, hold = st#remoteHold,
                          stepState = st#stepState, record = Nil });
                    // リモートの口が World を差し替えた拍は跳んだ拍（セーブを作り物で上書きしない）。
                    // /halt・/resume が矢印を上書きするので、宣言は次に動く拍で当て直す。
                    recordItems(app, st#recorder, next#record, next#world);
                    loop(app, { world = next#world, anno = next#anno, history = next#history,
                                remoteHold = next#hold, stepState = next#stepState,
                                cursorShown = CursorState.Stale, outputKeys = keysAfterJump(app, next#world, st#outputKeys) | carried })
                case _ => {
                    let decided = decideBranch({ f8Pressed = justPressed(GameEngine.Key.F8, frame),
                                                 canDebug = canDebug(app), remoteHold = st#remoteHold,
                                                 wasPaused = st#anno#paused });
                    // デバッグモードの出入りをウィンドウタイトルとカーソル形状で示す
                    // （停止中は正確に囲うための十字カーソル）
                    if (decided#toggled) {
                        applyHaltLook(haltLook(decided#branch == Branch.Paused))
                    } else ();
                    match decided#branch {
                        case Branch.Paused =>
                            let (nextAnno, ticket) = pausedStep(app, st#warnOnce, st#world, st#history, frame, { paused = true | st#anno });
                            // チケットに、ここまでの遊んだ記録の写し（再生すると表示中の瞬間で止まる）を入れる。
                            match (ticket, st#recorder) {
                                case (Some(dir), Some(rec)) => discard Flow.Record.copyInto(rec, dir, nextAnno#scrub)
                                case _                      => ()
                            };
                            loop(app, { anno = nextAnno, cursorShown = CursorState.Stale | carried })
                        case Branch.Resuming =>
                            // スクラブ位置の World から再開する。巻き戻したぶんの履歴と
                            // フレーム番号も、そこを現在として数え直す。
                            let resumed = resumePoint(st#anno, st#history, st#world);
                            recordJump(app, st#recorder, if (st#anno#scrub > 0) Some("rewind ${Int32.toString(st#anno#scrub)}") else None,
                                       resumed#world);
                            let (cache1, seen1, warned1) = renderFrame(app, st#warnOnce, resumed#world, fpsOverlayOf(app, resumed#anno), st#tileCache, st#glyphSeen, st#budgetWarned);
                            let shown = applyCursor(app, resumed#world, st#cursorShown);
                            loop(app, { world = resumed#world, anno = resumed#anno, history = resumed#history,
                                        tileCache = cache1, glyphSeen = seen1,
                                        budgetWarned = warned1, cursorShown = shown,
                                        outputKeys = keysAfterJump(app, resumed#world, st#outputKeys) | carried })
                        case Branch.Running =>
                            Option.forEach(rec -> Flow.Record.checkExternalChange(rec, fingerprintText(app, st#world)), st#recorder);
                            let (watched, nextWatchState, watchFired) = applyWatch(app, frame#dt, st#watchState, st#world, st#recorder);
                            let (reloaded, reloadFired) = applyReload(app, frame, watched, st#recorder);
                            // 1 フレームの中身は trace・台本・/step と同じ traceFrame の 1 本（音の名前もここで導く）。
                            let (traced, nextStepState) = traceFrame(app, frame, st#stepState, reloaded);
                            let advanced = traced#after;
                            Option.forEach(rec -> Flow.Record.frame(rec, frame, fingerprintText(app, advanced)), st#recorder);
                            let (nextSustaining, nextMix, nextUses) = applyAudio(app, frame#dt, traced,
                                                                       st#sustaining, st#mixState, st#soundUses, st#warnOnce);
                            // fps は debug 有効時だけ計測する（本番ビルドは履歴を積まず無負荷）。
                            let measuredAnno = if (rec(app)#debug) Annotate.recordDt(frame#dt, st#anno) else st#anno;
                            // Doc の読み直しが起きたフレームはタイル層の世代を進め、同じ key でも作り直す。
                            let (cache1, seen1, warned1) = renderFrame(app, st#warnOnce, advanced, fpsOverlayOf(app, measuredAnno),
                                                              bumpTileGen(watchFired or reloadFired, st#tileCache),
                                                              st#glyphSeen, st#budgetWarned);
                            // 時間スクラブ用の履歴（debug が無効なら一切持たない = 本番ビルドは無負荷）
                            let nextHistory = if (canDebug(app))
                                                  List.take(historyLimit(), advanced :: st#history)
                                              else Nil;
                            // 外への出力とマウスの矢印は、実機のフレームの後の World からだけ当てる。
                            let written = writeOutputs(app, advanced, st#outputKeys);
                            let shown = applyCursor(app, advanced, st#cursorShown);
                            loop(app, { world = advanced, history = nextHistory,
                                        outputKeys = written, cursorShown = shown,
                                        anno = { frame = measuredAnno#frame + 1i64 | measuredAnno },
                                        stepState = nextStepState, watchState = nextWatchState,
                                        sustaining = nextSustaining, mixState = nextMix, soundUses = nextUses, tileCache = cache1,
                                        glyphSeen = seen1, budgetWarned = warned1 | carried })
                    }
                }
            }
        }

    /// 跳んだ拍の後の出力の鍵: Skip は跳んだ先の鍵を「書いた」ことにし、Write は前に書いた鍵のまま
    /// （次の実機のフレームで鍵が違えば書く）。written が短い所（起動の拍）は "" = まだ何も書いていない。
    /// ゲームからは呼ばない（launch が起動・リモート・F8 の再開の拍に呼ぶ。テストのために公開）。
    pub def keysAfterJump(app: App[w, ef], world: w, written: List[String]): List[String] =
        rec(app)#outputs |> List.zipWithIndex |> List.map(entry -> {
            let (index, output) = entry;
            match output#onJump {
                case OnJump.Skip  => (output#keyOf)(world)
                case OnJump.Write => List.nth(index, written) |> Option.getWithDefault("")
            }
        })

    /// 実機のフレームの後の World で書くべき出力の番号（outputs の順）: 鍵が最後に書いた鍵と違う物。
    /// ゲームからは呼ばない（launch が呼ぶ。テストのために公開）。
    pub def dueOutputs(app: App[w, ef], world: w, written: List[String]): List[Int32] =
        rec(app)#outputs |> List.zipWithIndex |> List.filterMap(entry -> {
            let (index, output) = entry;
            if (Some((output#keyOf)(world)) == List.nth(index, written)) None else Some(index)
        })

    /// 実機のフレームの後: dueOutputs の出力だけ write を呼び、新しい鍵の列を返す。
    def writeOutputs(app: App[w, ef], world: w, written: List[String]): List[String] \ Fs.FileWrite =
        let due = dueOutputs(app, world, written);
        rec(app)#outputs |> List.zipWithIndex |> List.map(entry -> {
            let (index, output) = entry;
            if (List.memberOf(index, due)) (output#write)(world) else ();
            (output#keyOf)(world)
        })

    /// withCursor の宣言を当てる（前に当てた物と同じなら何もしない）。返すのは当てた後の状態。
    def applyCursor(app: App[w, ef], world: w, state: CursorState): CursorState \ GameEngine.Game =
        match rec(app)#cursor {
            case None    => state
            case Some(f) =>
                let want = f(world);
                Option.forEach(applyLook, cursorChange(want, state));
                CursorState.Applied(want)
        }

    /// withCursor の宣言 want を当てるなら、その見た目（前に当てた物と同じなら None）。
    /// Stale（まだ当てていない・止めた画面の見た目が上書きした）なら必ず当てる — 止めた画面を抜けた拍に
    /// ゲームの「隠す」が戻るのはここ。ゲームからは呼ばない（テストのために公開）。
    pub def cursorChange(want: CursorSpec, state: CursorState): Option[CursorLook] =
        let look = CursorLook.CursorLook(want#icon, if (want#visible) Visibility.Show else Visibility.Hide);
        match state {
            case CursorState.Applied(was) if was#icon == want#icon and was#visible == want#visible => None
            case _ => Some(look)
        }

    /// 止める（halted = true）・抜ける時の見た目。止めた画面は十字を見せる — withCursor で矢印を隠している
    /// ゲームでも、矩形を囲うのに要る。抜ける時は形だけ戻し、見せるか隠すかは触らない（動き出した拍に
    /// cursorChange が withCursor の宣言を当て直す。宣言の無いゲームは見せたままが元の姿）。
    /// ゲームからは呼ばない（F8 と /halt・/resume・/step が使う。テストのために公開）。
    pub def haltLook(halted: Bool): HaltLook =
        if (halted) HaltLook.HaltLook(true, CursorLook.CursorLook(GameEngine.Cursor.Crosshair, Visibility.Show))
        else HaltLook.HaltLook(false, CursorLook.CursorLook(GameEngine.Cursor.Default, Visibility.LeaveToApp))

    /// haltLook の見た目をウィンドウへ当てる。ゲームからは呼ばない（RemoteDebug が呼ぶので公開）。
    pub def applyHaltLook(look: HaltLook): Unit \ GameEngine.Game =
        let HaltLook.HaltLook(badge, cursor) = look;
        GameEngine.Game.setDebugBadge(badge);
        applyLook(cursor)

    def applyLook(look: CursorLook): Unit \ GameEngine.Game =
        let CursorLook.CursorLook(icon, visibility) = look;
        GameEngine.Game.setCursor(icon);
        match visibility {
            case Visibility.Show       => GameEngine.Game.setCursorVisible(true)
            case Visibility.Hide       => GameEngine.Game.setCursorVisible(false)
            case Visibility.LeaveToApp => ()
        }

    /// 一時停止を抜ける地点: スクラブで表示していた瞬間の World を現在とし、
    /// 履歴とフレーム番号もそこを基準に数え直す（未来側の履歴は捨てる）。
    def resumePoint(anno: Annotate.State, history: List[w], world: w): { world = w, anno = Annotate.State, history = List[w] } =
        { world = worldAt(history, anno#scrub, world),
          history = List.drop(anno#scrub, history),
          anno = { frame = anno#frame - Int32.toInt64(anno#scrub) | Annotate.resetView(anno) } }

    /// 履歴の back フレーム前の World（範囲外なら fallback）。先頭が「停止した瞬間」。
    def worldAt(history: List[w], back: Int32, fallback: w): w =
        history |> List.drop(back) |> List.head |> Option.getWithDefault(fallback)

    /// デバッグ機能が使える構成か（debug 有効 かつ 凍結画面を描く手段 = view か debugView がある）。
    def canDebug(app: App[w, ef]): Bool =
        rec(app)#debug and (Option.nonEmpty(rec(app)#view) or Option.nonEmpty(rec(app)#debugView))

    /// 一時停止中に扱う 1 フレームぶんの描画チャンネル（エンジンへそのまま渡せる形）。
    type alias DebugChannels = {
        drawables = List[GameEngine.Drawable],
        tileMaps = List[GameEngine.TileMapRenderCmd],
        polygons = List[GameEngine.PolygonRenderCmd]
    }

    /// 一時停止中の 1 フレーム。← → の時間スクラブで表示する瞬間を選び、マウスを読んで
    /// ズーム・パン・ドラッグを進め、矩形が確定したら「表示中の瞬間」の注釈一式を書き出し、
    /// その World の絵に見え方とドラッグ中の矩形を重ねて描く。
    /// World には一切触れない（凍結中の絵は選んだ World から毎フレーム投影し直す）。
    /// 絵の出どころは view（PlacedItem 投影）か debugView（生チャンネル投影）のどちらか。
    def pausedStep(app: App[w, ef], warnOnce: String -> Unit, world: w, history: List[w], frame: Frame,
                   anno: Annotate.State): (Annotate.State, Option[String]) \ (ef + GameEngine.Game) =
        let design = GameEngine.Game.getViewportRect()#size;
        let historyLen = Int32.max(1, List.length(history));
        let scrubbed = Annotate.scrubStep(
            { back = isDown(GameEngine.Key.Left, frame),
              backEdge = justPressed(GameEngine.Key.Left, frame),
              fwd = isDown(GameEngine.Key.Right, frame),
              fwdEdge = justPressed(GameEngine.Key.Right, frame) },
            historyLen, anno);
        let displayed = worldAt(history, scrubbed#scrub, world);
        let input = { cursor = GameEngine.Game.getMousePosition(),
                      leftDown = GameEngine.Game.isMouseButtonPressed(GameEngine.MouseButton.Left),
                      middleDown = GameEngine.Game.isMouseButtonPressed(GameEngine.MouseButton.Middle),
                      spaceDown = isDown(GameEngine.Key.Space, frame),
                      // ホイールは loop が Frame へ埋め込んだ後なので、二度読みせず frame から引く
                      scroll = frame#wheel,
                      design = design };
        let (next, emitted) = Annotate.step(input, scrubbed);
        // 注釈のフレーム番号は「表示中の瞬間」のもの（スクラブぶんを引く）
        let shownFrame = next#frame - Int32.toInt64(next#scrub);
        // 矩形が確定した瞬間だけ、表示中の World をゲームのダンプ関数でテキスト化する
        // （world.json としてチケットに同梱。繋がれていなければ空 = 同梱しない）
        let dumpText = match (emitted, rec(app)#worldDump) {
            case (Some(rect), Some(f)) => f(rect, displayed)
            case _                     => ""
        };
        let context = match (emitted, rec(app)#annotationContext) {
            case (Some(_), Some(f)) => f(displayed)
            case _                  => Annotate.noContext()
        };
        let dump = { text = dumpText, context = context };
        match rec(app)#view {
            case Some(toItems) =>
                uploadAtlases((rec(app)#spriteAtlases)(world));
                let atlas = GameEngine.Game.getFontAtlas("default");
                // displayed（スクラブで表示中の瞬間）から絵もカメラも導く — 注釈の hits も同じ items を使う。
                // F8 停止中は静的レイヤーも通常の動的アイテムにまとめて描く（F8 のズーム/パンは
                // channels に効く別変換なので、retained の camera uniform では追随できないため）。
                // 停止中は毎フレーム再投影で軽さは問題にならない。
                let items = List.append(tilePausedItems(app, design, displayed),
                            List.append(sceneItems(app, atlas, warnOnce, displayed, toItems),
                                        staticPausedItems(app, design, displayed)));
                let (sprites, polygons) = Render.drawWith(
                    name -> GameEngine.Game.getTextureInfo(name), items);
                let hitList = match emitted {
                    case Some(rect) => Annotate.hits(name -> GameEngine.Game.getTextureInfo(name), rect, items)
                    case None       => Nil
                };
                finishPaused({ design = design, cursor = input#cursor, atlas = atlas,
                               historyLen = historyLen, shownFrame = shownFrame },
                             next, emitted, dump,
                             { drawables = sprites, tileMaps = Nil, polygons = polygons }, hitList)
            case None => match rec(app)#debugView {
                case Some((fontName, toChannels)) =>
                    let atlas = GameEngine.Game.getFontAtlas(fontName);
                    let (drawables, tileMaps, polygons) = toChannels(displayed);
                    let hitList = match emitted {
                        case Some(rect) =>
                            Annotate.hitsFromDrawables(name -> GameEngine.Game.getTextureInfo(name), rect, drawables)
                        case None => Nil
                    };
                    finishPaused({ design = design, cursor = input#cursor, atlas = atlas,
                                   historyLen = historyLen, shownFrame = shownFrame },
                                 next, emitted, dump,
                                 { drawables = drawables, tileMaps = tileMaps, polygons = polygons }, hitList)
                case None => (next, None)
            }
        }

    /// 一時停止フレームの締め: 矩形が確定していれば注釈を書き出してトーストを出し、凍結画面を描く。
    /// 返すのは次の停止の状態と、書き出したチケットのフォルダ（遊んだ記録の写しを入れる所）。
    def finishPaused(ctx: { design = Vec2.Vec2, cursor = Vec2.Vec2, atlas = FontAtlas,
                            historyLen = Int32, shownFrame = Int64 },
                     anno: Annotate.State, emitted: Option[Rect2.Rect2],
                     dump: { text = String, context = Annotate.Table },
                     channels: DebugChannels, hitList: List[Annotate.Hit]): (Annotate.State, Option[String]) \ GameEngine.Game =
        let saved = match emitted {
            case Some(rect) => writeAnnotation(ctx#design, rect, ctx#shownFrame, dump, channels, hitList)
            case None       => None
        };
        let shown = match (emitted, saved) {
            case (Some(_), Some(path)) => Annotate.showToast("Saved debug file\n${path}", anno)
            case (Some(_), None)       => anno
            case (None, _)             => Annotate.tickToast(anno)
        };
        renderPaused(ctx, shown, channels);
        (shown, saved)

    /// 確定した矩形の注釈一式（JSON・README の要約・等倍の描画命令）を組んでエンジンへ渡す。
    /// ファイルへの書き出しとスクリーンショット撮影・シャッター音はエンジンの saveAnnotation が
    /// 引き受ける。戻り値は保存先のディレクトリパス（失敗時 None）。
    def writeAnnotation(design: Vec2.Vec2, rect: Rect2.Rect2, frameNo: Int64,
                        dump: { text = String, context = Annotate.Table },
                        channels: DebugChannels, hitList: List[Annotate.Hit]): Option[String] \ GameEngine.Game =
        let dumpText = dump#text;
        let body = Annotate.readmeBodyWith(dump#context, { frame = frameNo, rect = rect }, hitList);
        GameEngine.Game.saveAnnotation({
            frame = frameNo, rect = rect,
            json = Annotate.annotationJsonWith(dump#context, { frame = frameNo, design = design, rect = rect }, hitList),
            readmeBody = if (dumpText == "") body else body + "\n- シム状態のダンプ: world.json",
            worldDump = dumpText,
            sprites = channels#drawables, tileMaps = channels#tileMaps, polygons = channels#polygons })

    /// 凍結中の絵を描く: ドラッグ中の矩形を重ね、ズーム・パンを適用して描画命令にする。
    /// 保存完了メッセージとスクラブ位置は見え方の適用後に重ねるので、ズーム中も画面に固定される。
    /// 等倍・ずらし無し・表示物無しのときは通常描画と同じ命令列になる。
    def renderPaused(ctx: { design = Vec2.Vec2, cursor = Vec2.Vec2, atlas = FontAtlas,
                            historyLen = Int32, shownFrame = Int64 },
                     anno: Annotate.State, channels: DebugChannels): Unit \ GameEngine.Game =
        let view = Annotate.viewOf(ctx#design, anno);
        let overlay = match anno#dragStart {
            case Some(start) => Annotate.overlayItems(start, Annotate.toDesign(view, ctx#cursor))
            case None        => Nil
        };
        let (overlaySprites, overlayPolygons) = Render.draw(overlay);
        // デバッグの小物はゲームのフォントを使わない。ゲームのフォントは「出た字から順に用意する」
        // ので、まだ用意されていない字は出せず、しかもこの停止中の経路は追加で作ることを頼まない。
        // 組み込みフォント（常に全部そろっているドット絵の字）を決め打ちで使う。
        let debugAtlas = BootFont.atlas();
        let debugSize = debugAtlas#fontSize;
        let toastPlaced = match anno#toast {
            case Some(t) => Annotate.toastItems(debugAtlas, debugSize, t#message)
            case None    => Nil
        };
        let scrubPlaced = if (anno#scrub > 0 and anno#scrubShow > 0)
                              Annotate.scrubIndicatorItems(debugAtlas, debugSize, ctx#design,
                                                           anno#scrub, ctx#historyLen)
                          else Nil;
        let (fixedSprites, fixedPolygons) = Render.draw(List.append(toastPlaced, scrubPlaced));
        // 停止中は静的レイヤーを channels#polygons にまとめて渡す（staticPausedItems）ので、
        // ここでは retained の静的依頼は無し（None）— F8 のズーム/パンが channels に効くため。
        GameEngine.Game.renderCommands(
            List.append(Annotate.applyInspect(view, List.append(channels#drawables, overlaySprites)), fixedSprites),
            Annotate.applyInspectTiles(view, channels#tileMaps),
            List.append(Annotate.applyInspectPoly(view, List.append(channels#polygons, overlayPolygons)), fixedPolygons),
            None)

    /// reloadOn で繋いだキーが押された瞬間だけ、リロード関数で World を作り直す。
    /// 第 2 要素は「このフレームで読み直しが起きたか」（タイル層の世代を進める合図）。
    def applyReload(app: App[w, ef], frame: Frame, world: w, recorder: Option[Flow.Record.Recorder]): (w, Bool) \ {Fs.FileRead, IO} =
        match rec(app)#reload {
            case Some((key, f)) => if (justPressed(key, frame)) (recordedReload(recorder, "key", () -> f(world)), true) else (world, false)
            case None           => (world, false)
        }

    /// 読み直し 1 回を流し、記録しているならその読んだファイルの中身つきで reload の行を書く。
    def recordedReload(recorder: Option[Flow.Record.Recorder], target: String, f: Unit -> w \ Fs.FileRead): w \ {Fs.FileRead, IO} =
        match recorder {
            case None => f()
            case Some(rec) =>
                let (reloaded, files) = Flow.Record.captureReads(f);
                Flow.Record.line(rec, Flow.Record.reloadLine(target, files));
                reloaded
        }

    /// watchFile がフレームをまたいで持ち回す状態（前回ポーリングからの経過秒と、
    /// 前回見えた各パスの更新時刻）。監視しないゲームでは常に初期値のまま動かない。
    type alias WatchState = { sincePoll = Float64, mtimes = Map[String, Int64] }

    /// 監視を持たない・まだ何も見ていない WatchState。
    def freshWatchState(): WatchState =
        { sincePoll = 0.0, mtimes = Map.empty() }

    /// 保存検知のポーリング間隔（秒）。体感の即時性と毎フレーム stat のコストの折り合い。
    def watchPollInterval(): Float64 = 0.5

    /// 監視中パスの更新時刻（epoch ミリ秒）をまとめて読む。読めないパスは黙って除く。
    // Fs.FileTime を launch の効果行に出さないのは、デバッグ専用の内部ポーリングのために
    // 全ゲームの Main へ with 追記を強いないため（ここで IO のハンドラで閉じる）。
    def statMtimes(paths: List[String]): Map[String, Int64] \ IO =
        run {
            run {
                List.foldLeft((acc, p) -> match Fs.ModificationTime.modificationTime(p) {
                    case Ok(t)  => Map.insert(p, t, acc)
                    case Err(_) => acc
                }, Map.empty(), paths)
            } with Fs.ModificationTime.runWithFileTime
        } with Fs.FileTime.runWithIO

    /// 保存検知の 1 フレームぶん: 間隔に達したら更新時刻を読み、変化したパスの関数を
    /// 登録順に適用して World を作り直す（発火は標準エラーへ 1 行知らせる）。
    /// debug 無効・watch 空・間隔未達なら stat を一切しない（フレーム予算ゼロ）。
    /// 第 3 要素は「このフレームでどれかの Doc が読み直されたか」（タイル層の世代を進める合図）。
    def applyWatch(app: App[w, ef], dt: Float64, state: WatchState, world: w,
                   recorder: Option[Flow.Record.Recorder]): (w, WatchState, Bool) \ {Fs.FileRead, IO} =
        if (not rec(app)#debug or List.isEmpty(rec(app)#watch))
            (world, state, false)
        else {
            let waited = state#sincePoll + dt;
            if (waited < watchPollInterval())
                (world, { sincePoll = waited | state }, false)
            else {
                let current = statMtimes(List.map(fst, rec(app)#watch));
                let changed = changedPaths(List.map(fst, rec(app)#watch), state#mtimes, current);
                let next = rec(app)#watch |> List.foldLeft((acc, entry) -> {
                    let (path, f) = entry;
                    if (List.memberOf(path, changed)) {
                        System.err.println("watch reload: ${path}");
                        recordedReload(recorder, path, () -> f(acc))
                    } else acc
                }, world);
                (next, { sincePoll = 0.0, mtimes = current }, not List.isEmpty(changed))
            }
        }

    /// 閉じる要求を World へ渡し、窓の閉じる印を下ろす（withCloseRequest が無ければそのまま）。
    def noticeCloseRequest(app: App[w, ef], st: LoopState[w]): LoopState[w] \ (ef + GameEngine.Game + IO) =
        match rec(app)#closeRequest {
            case None    => st
            case Some(f) =>
                GameEngine.Game.setShouldClose(false);
                let closed = f(st#world);
                recordJump(app, st#recorder, Some("close"), closed);
                { world = closed | st }
        }

    /// 1 フレームの音: ミキサーが無ければ今までどおり名前のまま鳴らし、あればバスを通して鳴らす。
    /// 返すのは次のフレームへ渡す「いま鳴り続けている名前」とミキサーの状態。
    /// uses は一発とループで鳴らした名前の覚え（noteSoundUses）。両方に出た名前は warn で 1 回だけ知らせる。
    def applyAudio(app: App[w, ef], dt: Float64, traced: TraceStep[w],
                   prev: List[String], mixState: AudioMixer.State, uses: SoundUses, warn: String -> Unit):
            (List[String], AudioMixer.State, SoundUses) \ (ef + GameEngine.Audio) =
        let plays = traced#sounds;
        let declared = traced#sustained;
        let after = traced#after;
        let (nextUses, clashes) = noteSoundUses(plays, declared |> List.map(s -> s#name), uses);
        let (living, nextMix) = match rec(app)#mixer {
            case None          => (playPlain(List.distinct(plays), declared, prev), mixState)
            case Some(mixerOf) => applyMixed(mixerOf(after), dt, plays, declared, prev, mixState)
        };
        let lines = clashes |> List.map(name ->
            "音 ${name} を一発（withAudio）とループ（withSustained）の両方で鳴らしている: " +
            "ループの設定が残って一発が止まらない・ループが途中で切れることがある。ループの方は別の名前にする（例: ${name}_loop）");
        warnedAll(warn, lines, (living, nextMix, nextUses))

    /// lines を 1 行ずつ warn で知らせてから value を返す。
    /// WhyNot: `warn(line);` と書かない —— 純粋な型の呼び出しの値を捨てると、コンパイラが呼び出しごと消す。
    def warnedAll(warn: String -> Unit, lines: List[String], value: a): a =
        match lines {
            case Nil          => value
            case line :: rest => match warn(line) {
                case () => warnedAll(warn, rest, value)
            }
        }

    /// 一発で鳴らした名前とループで鳴らした名前の覚え（ゲームの間ずっと持つ）。
    pub type alias SoundUses = { oneShot = Set[String], looped = Set[String] }

    /// このフレームの一発の音 plays とループの音 looped を覚えに足し、初めて両方に出た名前を返す。
    /// 音の名前に「一発用・ループ用」の型が付くまでのつなぎ（同じ名前を両方で使うと、音源に残った
    /// ループの設定で一発が止まらない・ループが切れる）。テストのために公開している（ゲームから呼ぶ物ではない）。
    pub def noteSoundUses(plays: List[String], looped: List[String], uses: SoundUses): (SoundUses, List[String]) =
        let next = { oneShot = Set.union(uses#oneShot, List.toSet(plays)),
                     looped  = Set.union(uses#looped, List.toSet(looped)) };
        let isBoth = (u, name) -> Set.memberOf(name, u#oneShot) and Set.memberOf(name, u#looped);
        let clashes = List.append(plays, looped) |> List.distinct
            |> List.filter(name -> isBoth(next, name) and not isBoth(uses, name));
        (next, clashes)

    /// バスを通して鳴らす。順番: ミキサーを 1 フレーム進める（AudioMixer.step）→ 鳴っている一発の音へ
    /// 今の音量とローパスを流し直す（ダッキングの最中に下がっていく）→ 通った一発の音を鳴らす →
    /// 鳴り続ける音を始める・続ける・止める（宣言の音量 × バスの倍率）。
    def applyMixed(mixer: AudioMixer.Mixer, dt: Float64, plays: List[String], declared: List[Sustain],
                       prev: List[String], mixState: AudioMixer.State):
            (List[String], AudioMixer.State) \ GameEngine.Audio =
        let ops = sustainOps(prev, declared);
        let living = List.map(s -> s#name, List.append(ops#start, ops#keep));
        let (allowed, next) = AudioMixer.step(mixer, name -> GameEngine.Audio.audioSeconds(name), dt,
                                              plays, living, mixState);
        let route = name -> {
            GameEngine.Audio.setVolume(name, AudioMixer.gainOf(mixer, next, name));
            GameEngine.Audio.setLowpass(name, AudioMixer.lowpassGainHFOf(mixer, next, name))
        };
        Map.forEach((name, _) -> route(name), next#voices);
        // 止める → ループを外す → 一発の音 → 鳴らし始め の順（止める音と同じ名前の一発の音を
        // 後から止めて消さないため）。
        ops#stop |> List.forEach(name -> GameEngine.Audio.stopAudio(name));
        unloopedOneShots(allowed, living) |> List.forEach(name -> GameEngine.Audio.setLooping(name, false));
        allowed |> List.forEach(name -> GameEngine.Audio.playAudio(name));
        let level = s -> {
            GameEngine.Audio.setVolume(s#name, s#volume * AudioMixer.gainOf(mixer, next, s#name));
            GameEngine.Audio.setPitch(s#name, s#pitch);
            GameEngine.Audio.setLowpass(s#name, AudioMixer.lowpassGainHFOf(mixer, next, s#name))
        };
        ops#start |> List.forEach(s -> {
            GameEngine.Audio.setLooping(s#name, true);
            level(s);
            GameEngine.Audio.playAudio(s#name)
        });
        ops#keep |> List.forEach(level);
        (living, next)

    /// ミキサーの無いときの 1 フレームの音。一発の音は audio の導いた名前（同じ名前が 2 回返っても
    /// 1 回にまとめる — 同フレームの二重再生は同じ音源を頭から鳴らし直して途切れる）、鳴り続ける音は
    /// sustained の宣言。鳴らし始めだけ playAudio を打ち、続いている音には音量と高さだけ流す
    /// （毎フレーム鳴らし直すと頭から再生され、続く音にならない）。順番は applyMixed と同じ
    /// 「止める → ループを外す → 一発の音 → 鳴らし始め」。返すのは次のフレームへ渡す「いま鳴っている名前」。
    def playPlain(plays: List[String], declared: List[Sustain], prev: List[String]): List[String] \ GameEngine.Audio =
        let ops = sustainOps(prev, declared);
        let living = List.map(s -> s#name, List.append(ops#start, ops#keep));
        ops#stop |> List.forEach(name -> GameEngine.Audio.stopAudio(name));
        unloopedOneShots(plays, living) |> List.forEach(name -> GameEngine.Audio.setLooping(name, false));
        plays |> List.forEach(name -> GameEngine.Audio.playAudio(name));
        ops#start |> List.forEach(s -> {
            GameEngine.Audio.setLooping(s#name, true);
            GameEngine.Audio.setVolume(s#name, s#volume);
            GameEngine.Audio.setPitch(s#name, s#pitch);
            GameEngine.Audio.playAudio(s#name)
        });
        ops#keep |> List.forEach(s -> {
            GameEngine.Audio.setVolume(s#name, s#volume);
            GameEngine.Audio.setPitch(s#name, s#pitch)
        });
        living

    /// 一発の音（audio）のうち、鳴らす前にループを外す名前。鳴り続ける音（sustained）として
    /// 一度鳴らした名前は音源にループの設定が残るので、同じ名前を一発で鳴らすと止まらなくなる。
    /// いま鳴り続けている名前（living）は外さない — 外すと鳴り続ける側が途中で切れる。
    /// テストのために公開している（ゲームから呼ぶ物ではない）。
    pub def unloopedOneShots(plays: List[String], living: List[String]): List[String] =
        let alive = List.toSet(living);
        plays |> List.filter(name -> not Set.memberOf(name, alive))

    /// 時計は World の外に住む。エンジンが値をクランプするので、長いカクつきでも先へワープしない。
    def readDt(): Float64 \ GameEngine.Game =
        Duration.toSeconds(GameEngine.Game.getDeltaTime())

    /// world から画面に出す絵一式を組む: view の絵に camera を掛け、hud を合流する（純粋な芯は
    /// composeScene）。F8 スクラブ中は「表示中の瞬間」の World を渡すこと — 現在の world を
    /// 渡すと絵は過去・カメラは現在のズレた画面になり、注釈の当たり判定も全部ずれる。
    /// 確定した camera（中心と zoom）を World から 1 回だけ導く: zoom-only の正規化
    /// （zoomedCenter）→ cameraBounds クランプ。主 view と静的レイヤーがこの同じ値から
    /// 派生するので、動的な絵と静的な絵の視点が必ず一致する（1px もずれない）。
    def resolvedCamera(app: App[w, ef], world: w, design: Vec2.Vec2): (Option[Vec2.Vec2], Float64) \ ef =
        let z = match rec(app)#zoom {
            case None    => 1.0
            case Some(f) => f(world)
        };
        let center0 = match rec(app)#camera {
            case Some(f) => Some(f(world))
            case None    => None
        };
        let center = match (zoomedCenter(center0, z, design), rec(app)#cameraBounds) {
            case (Some(c), Some(fb)) =>
                let seen = Vec2.div(design, CameraRig.safeZoom(z));
                Some(CameraRig.clampCenter(bounds = fb(world), seen = seen, c))
            case (c, _) => c
        };
        // 画素の升目に吸着させる（静的な絵と動く絵が同じ値を見るので、両者はずれない）。
        let snap = (rec(app)#pixelSnap)(world);
        // 画面の画素に載せたいので、zoom を掛けた後の値で丸める（world 座標で丸めるだけでは
        // zoom が整数でないときに半画素ずれが残る）。
        let unit = snap * CameraRig.safeZoom(z);
        let snapped = if (not Float64.isFinite(unit) or unit <= 0.0) center
                      else Option.map(c -> { x = Float64.round(c#x * CameraRig.safeZoom(z)) / CameraRig.safeZoom(z),
                                             y = Float64.round(c#y * CameraRig.safeZoom(z)) / CameraRig.safeZoom(z) }, center);
        (snapped, z)

    /// withFonts で宣言された名前を先に全部引いておき、名前 → アトラスの純粋な引き当てを作る。
    /// view は純粋（ef）なので、その場で getFontAtlas を呼べない — ここで先に解いておく。
    /// 宣言していない名前は既定フォントへ落とす（字が消えるより既定で出るほうがよい）。
    def fontResolver(app: App[w, ef], dflt: FontAtlas): (String -> FontAtlas) \ GameEngine.Game =
        let table = rec(app)#fonts |> List.foldLeft((acc, n) ->
            Map.insert(n, GameEngine.Game.getFontAtlas(n), acc),
            (Map.empty(): Map[String, FontAtlas]));
        name -> Map.get(name, table) |> Option.getWithDefault(dflt)

    def sceneItems(app: App[w, ef], atlas: FontAtlas, warnOnce: String -> Unit, world: w,
                   toItems: (ViewCtx, w) -> List[Render.PlacedItem] \ ef):
            List[Render.PlacedItem] \ (ef + GameEngine.Game) =
        let design = GameEngine.Game.getViewportRect()#size;
        let fontOf = fontResolver(app, atlas);
        let (center, z) = resolvedCamera(app, world, design);
        let hud = match rec(app)#hudView {
            case None    => Nil
            // HUD は画面固定なので、見えている矩形は常に design 全体（原点起点）で zoom も掛けない。
            case Some(h) => h({ atlas = atlas, fontOf = fontOf, visible = visibleOf(None, 1.0, design), warnOnce = warnOnce }, world)
        };
        // 視差レイヤ: 見かけの center（parallaxCenter）で culling も合成も行う。hud は混ぜない。
        let layers = rec(app)#parallaxLayers |> List.flatMap(fl -> {
            let (factor, lview) = fl;
            let lcenter = Option.map(c -> CameraRig.parallaxCenter(factor, c, design = design), center);
            let lctx = { atlas = atlas, fontOf = fontOf, visible = visibleOf(lcenter, z, design), warnOnce = warnOnce };
            composeScene(lcenter, z, design, { world = lview(lctx, world), hud = Nil })
        });
        let ctx = { atlas = atlas, fontOf = fontOf, visible = visibleOf(center, z, design), warnOnce = warnOnce };
        List.append(layers, composeScene(center, z, design, { world = toItems(ctx, world), hud = hud }))

    /// debug 有効時だけ、画面右上に小さく fps を出す絵を組む（無効なら空 = 本番に一切出ない）。
    /// fps 表示は withView を使うゲームのみ（view = None の自前描画ゲームには出ない）—
    /// renderFrame が App の絵を描かない構成では、ここで組んでも捨てられるだけなので組まない。
    /// 字はゲームのフォントではなく組み込みフォントで出す — ゲームごとにフォント名が違い、
    /// 特定の名前を当てにすると名前が違うゲームで fps 表示が出せなくなる。
    def fpsOverlayOf(app: App[w, ef], anno: Annotate.State): List[Render.PlacedItem] \ GameEngine.Game =
        if (not rec(app)#debug or Option.isEmpty(rec(app)#view)) Nil
        else {
            let atlas = GameEngine.Game.getFontAtlas(BootFont.name());
            let design = GameEngine.Game.getViewportRect()#size;
            // 組み込みフォントはドット絵なので、作った大きさの等倍で出す。
            Annotate.fpsItems(atlas, atlas#fontSize, design, Annotate.fpsOf(anno))
        }

    /// F8 停止中に静的レイヤーを通常の動的アイテムとして描くための PlacedItem 列。
    /// build（ワールド座標）に主 view と同じ camera（resolvedCamera → composeScene）を掛けて、
    /// 動的な絵と重なり順・位置を揃える。静的レイヤーが無ければ空。
    def staticPausedItems(app: App[w, ef], design: Vec2.Vec2, world: w): List[Render.PlacedItem] \ ef =
        match rec(app)#staticLayer {
            case None    => Nil
            case Some(sl) =>
                let (center, z) = resolvedCamera(app, world, design);
                composeScene(center, z, design, { world = (sl#build)(world), hud = Nil })
        }

    /// 静的レイヤー（withStaticLayer）を、この World の camera から解決した描画依頼にする。
    /// key と polys（build → Render.draw の多角形チャンネル）はエンジンがキャッシュに使い、
    /// viewOffset/viewScale/halfDesign は動的な絵と同じ camera 値（resolvedCamera）から出すので、
    /// 静的な絵と動的な絵の視点は 1px もずれない。カメラ無しなら恒等（world 座標そのまま）。
    /// polys は build（純粋）だけを包むので、キャッシュヒット時に呼ばれても副作用は無い。
    def staticLayerCmd(app: App[w, ef], world: w): Option[GameEngine.StaticLayerCmd] \ (ef + GameEngine.Game) =
        match rec(app)#staticLayer {
            case None    => None
            case Some(sl) =>
                let design = GameEngine.Game.getViewportRect()#size;
                let (center, z) = resolvedCamera(app, world, design);
                let (viewOffset, viewScale, halfDesign) = match center {
                    case Some(c) => (c, { x = z, y = z }, Vec2.div(design, 2.0))
                    case None    => (Vec2.zero(), { x = 1.0, y = 1.0 }, Vec2.zero())
                };
                let key = (sl#key)(world);
                let build = sl#build;
                Some({ key = key,
                       // 箱で組んだ絵（ドット絵の走りなど）も生成できるよう、飾りの無い箱は
                       // 多角形へ直してから渡す — 静的層が生成するのは多角形チャンネルだけ。
                       polys = () -> {
                           let (_, polys) = Render.draw(Render.boxesAsPolys(build(world)));
                           polys },
                       viewOffset = viewOffset, viewScale = viewScale, halfDesign = halfDesign })
        }

    /// タイル層の GPU 生成結果の持ち回し。ループが引数で持ち回す。
    /// gen は「Doc の読み直し（watchFile / reloadOn）が起きた回数」= タイル層の世代。
    /// entries は層のスロット（宣言リストの並び順）→ (生成した時点の世代, 生成した時の key, VAO, 数)。
    /// スロットで引くので、key が頻繁に転がる層（照明・カメラ追随で作り直しが多い地形など）でも
    /// VAO は 1 層に 1 本のまま — 作り直しは updateTileBuffer の入れ直しで済む。
    pub type alias TileCache =
        { gen = Int32, entries = Map[String, (Int32, String, GpuHandle.TileVao, Int32)] }

    /// まだ何も生成していない起動時の持ち回し。
    pub def freshTileCache(): TileCache = { gen = 0, entries = Map.empty() }

    /// Doc の読み直しが起きたフレームで世代を進める。ゲームの書く key は素のまま、
    /// 世代の不一致が「作り直しが要る」の判定になる（tileCacheHit が見る）。
    // どの Doc がどのタイル層に効くかの依存表は持たない — 無関係な Doc の保存でも全層が
    // 作り直されるが、保存は人の手の速さでしか起きず、作り直しは 1 回のバッファ転送で済む。
    pub def bumpTileGen(fired: Bool, cache: TileCache): TileCache =
        if (fired) { gen = cache#gen + 1 | cache } else cache

    /// スロットに取ってある生成結果を引く。生成した時点の世代と key が今と一致した時だけ使い回せる。
    pub def tileCacheHit(slot: String, key: String, cache: TileCache): Option[(GpuHandle.TileVao, Int32)] =
        Map.get(slot, cache#entries) |> Option.flatMap(e -> {
            let (g, k, vao, n) = e;
            if (g == cache#gen and k == key) Some((vao, n)) else None
        })

    /// スロットに生成結果があれば、その VAO を返す（世代・key が古くてもよい —
    /// updateTileBuffer で中身を入れ直す先として使う）。
    pub def tileCacheVaoAt(slot: String, cache: TileCache): Option[GpuHandle.TileVao] =
        Map.get(slot, cache#entries) |> Option.map(e -> {
            let (_, _, vao, _) = e;
            vao
        })

    /// 生成した結果をスロットへ上書きで置く（一覧表は宣言中のレイヤーの数までしか育たない）。
    pub def tileCacheStore(slot: String, key: String, vao: GpuHandle.TileVao, count: Int32,
                           cache: TileCache): TileCache =
        { entries = Map.insert(slot, (cache#gen, key, vao, count), cache#entries) | cache }

    /// 宣言されたタイル層を描画コマンドにする。スロット（宣言リストの並び順）に同じ世代・
    /// 同じ key でキャッシュ済みなら使い回し、key か世代が変われば同じ VAO へ中身を
    /// 入れ直す（updateTileBuffer）。新しいスロットだけ initTileBuffer で VAO を作る —
    /// key が毎バケツ転がる層でも GPU バッファは 1 層 1 本のまま。
    /// 位置と倍率は動的な絵と同じ camera 値（resolvedCamera）から出すので視点はずれない。
    def tileLayerCmds(app: App[w, ef], world: w, cache: TileCache):
            (List[GameEngine.TileMapRenderCmd], TileCache) \ (ef + GameEngine.Game) =
        match rec(app)#tileLayers {
            case None    => (Nil, cache)
            case Some(f) =>
                let design = GameEngine.Game.getViewportRect()#size;
                let (center, z) = resolvedCamera(app, world, design);
                let (cmds, nextCache) = List.foldLeft((acc, entry) -> {
                    let (i, spec) = entry;
                    let slot = "${i}";
                    let (done, c) = acc;
                    let (vao, count) = match tileCacheHit(slot, spec#key, c) {
                        case Some(h) => h
                        case None    =>
                            let ts = spec#tileSet#atlasSource#tileSize;
                            let tilesOf = spec#tiles;
                            let instances = TileLayer.buildInstances(tilesOf(), spec#tileSet, ts);
                            match tileCacheVaoAt(slot, c) {
                                case Some(v) => GameEngine.Game.updateTileBuffer(v, instances)
                                case None    => GameEngine.Game.initTileBuffer(instances)
                            }
                    };
                    let (pos, scale) = match center {
                        case Some(c0) => (Vec2.add(Vec2.mul(Vec2.sub(spec#origin, c0), z),
                                                   Vec2.div(design, 2.0)),
                                          ({ x = z, y = z }: Vec2.Vec2))
                        case None     => (spec#origin, ({ x = 1.0, y = 1.0 }: Vec2.Vec2))
                    };
                    let cmd: GameEngine.TileMapRenderCmd = {
                        textureName = spec#tileSet#atlasSource#textureName,
                        tileSize    = spec#tileSet#atlasSource#tileSize,
                        position    = pos,
                        tileScale   = scale,
                        color       = { r = 1.0, g = 1.0, b = 1.0 },
                        zIndex      = spec#zIndex,
                        tileVaoId   = vao,
                        tileCount   = count };
                    (cmd :: done, tileCacheStore(slot, spec#key, vao, count, c))
                }, ((Nil: List[GameEngine.TileMapRenderCmd]), cache), List.zipWithIndex(f(world)));
                (List.reverse(cmds), nextCache)
        }

    /// F8 停止中にタイル層を通常の動的アイテムとして描くための PlacedItem 列。
    /// staticPausedItems と同じ理屈 — F8 のズーム/パンは channels に効く別変換なので、
    /// GPU タイル経路の camera では追随できない。CPU 投影（TileScene.toItems）で普通のアイテムに変換する。
    def tilePausedItems(app: App[w, ef], design: Vec2.Vec2, world: w): List[Render.PlacedItem] \ ef =
        match rec(app)#tileLayers {
            case None    => Nil
            case Some(f) =>
                let (center, z) = resolvedCamera(app, world, design);
                let items = f(world) |> List.flatMap(TileScene.toItems);
                composeScene(center, z, design, { world = items, hud = Nil })
        }

    /// view の投影した絵を描画命令にしてエンジンへ渡す。タイルマップは withTileLayers の
    /// 宣言があるときだけ生成して添える（持ち回しの TileCache を返す）。
    /// view = None のゲームは App では描かない（自分のシステム内で renderCommands を呼ぶ。
    /// camera / hudView もこの場合は効かない）。
    /// fps は debug 有効時だけ隅に重ねる（本番は Nil を渡すので描画に一切現れない）。
    /// 絵の値段の上限（1 フレームに組む描き物の数）。docs/performance.md の R3
    /// 「動的 PlacedItem < 2000 個/フレーム」から借りた既定値で、
    /// bin/check-render-budget.py の DEFAULT_CAP と同じ数。
    def budgetCap(): Int32 = 2000

    /// 予算を超えていたら標準エラーへ 1 回だけ知らせる（戻り値は「もう知らせたか」）。
    /// headless の検査（reference-check の予算判定）は代表フレーム 1 枚しか見ないので、
    /// Fx の最悪化・場面の切り替わり・GIF でしか作らない場面はここでしか捕まらない。
    /// WhyNot: 毎フレーム出さない — 遅い画面をさらに遅くし、ログも読めなくなる。
    /// 面のある画面で、面の後ろに同じ z の描き物を並べた z を知らせてから shaderCmds を返す（面が無ければ見ない）。
    def noteSurfaceZ(note: String -> Unit, items: List[Render.PlacedItem], shaderCmds: List[c]): List[c] =
        if (List.isEmpty(shaderCmds)) shaderCmds
        else match Render.surfaceZShared(items) |> List.forEach(z ->
                note("[render] z=${Int32.toString(z)}: ShaderDoc の面の後ろに同じ z の描き物がある — 同じ z の中では面が一番手前に描かれ、並びの順は効かない。手前に出す物の z を大きくする（docs/z-bands.md）")) {
            case () => shaderCmds
        }

    def warnOverBudget(count: Int32, warned: Bool): Bool \ IO =
        if (warned or count < budgetCap()) warned
        else {
            System.err.println("budget: この 1 フレームで ${count} 個の描き物を組みました"
                + "（上限 ${budgetCap()} 個）。盤や群れを毎フレーム組み直していませんか —"
                + " タイル層は App.withTileLayers（逆引き: make module Q=毎フレーム）");
            true
        }

    def renderFrame(app: App[w, ef], warnOnce: String -> Unit, world: w, fpsOverlay: List[Render.PlacedItem],
                    tileCache: TileCache, glyphSeen: Option[Int64], budgetWarned: Bool):
            (TileCache, Option[Int64], Bool) \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target + IO) =
        match rec(app)#view {
            case None          => (tileCache, glyphSeen, budgetWarned)
            case Some(toItems) =>
                uploadAtlases((rec(app)#spriteAtlases)(world));
                let atlas = GameEngine.Game.getFontAtlas("default");
                let design = GameEngine.Game.getViewportRect()#size;
                let passList = (rec(app)#passes)(world);
                renderPasses(design, passList);
                // fpsOverlay は本番ビルドで Nil — 空の append で本編全件を cons し直さない。
                let scene = sceneItems(app, atlas, warnOnce, world, toItems);
                let items = if (List.isEmpty(fpsOverlay)) scene else List.append(scene, fpsOverlay);
                // 字の欠け照合はレンダーターゲットの中の字も一緒に見る（ターゲットも本編と
                // 同じ「初めて出る字は 1 コマ遅れる」に乗せる）。
                let itemsForGlyphs = List.append(List.flatMap(p -> p#items, passList), items);
                // アトラスに無い字があれば、描く前に用意してもらう（初めて出る字は 1 コマ遅れる）。
                // たいていは空振りで、そのときは何も起きない。glyphSeen は「欠けが無かった
                // フレームの字の指紋」— 同じ指紋の間は 1 字ずつの照合を引き直さない。
                // アトラスは ensureGlyphs でしか育たず、育つのは欠けが出たフレームだけなので、
                // 欠けゼロの指紋を覚えても古い答えを返す余地が無い。欠けが出たフレームは
                // 覚えない（作った直後にアトラスが育ち、同じ字でも答えが変わるため）。
                let fp = Render.glyphFingerprint(itemsForGlyphs);
                let nextSeen = if (glyphSeen == Some(fp)) glyphSeen else {
                    let missing = Render.missingGlyphs(itemsForGlyphs);
                    Map.forEach((textureName, cps) -> GameEngine.Game.ensureGlyphs(textureName, cps),
                                missing);
                    if (Map.isEmpty(missing)) Some(fp) else None
                };
                // 宣言シェーダー面は別チャンネル（eff Shader）へ積む。drawSurface は描画依頼を
                // 溜めるだけで、重なり順は renderFrameMixed が (zIndex, 追加順) の安定ソートで
                // sprites / polygons / タイル / 静的レンジと合流させて決める。通常の絵からは
                // Shader 面を外して二重描きを避ける。
                // 面の後ろに同じ z の物を並べても、面が手前に描かれる（並びは効かない）。z ごとに 1 度だけ言う。
                let shaderCmds = noteSurfaceZ(warnOnce, items,
                    Render.drawShaders(spec -> ShaderEffect.Shader.buildProgram(spec), items));
                List.forEach(cmd -> ShaderEffect.Shader.drawSurface(cmd), shaderCmds);
                let (tileCmds, nextCache) = tileLayerCmds(app, world, tileCache);
                // drawWith(getTextureInfo): regionRect 付き Sprite(PxSprite.drawQuad の
                // アトラス 1 クアッド等)の UV を registry の寸法で解決する。regionRect 無しの
                // 絵は draw と同一の Drawable になる(挙動不変)。
                // シェーダー面 0 枚なら withoutShaders（filter が全件を作り直す）を通さない —
                // drawShaders と withoutShaders は同じ unwrapClip で面を見るので、
                // shaderCmds が空 = 外す物も無い。
                let itemsToDraw = if (List.isEmpty(shaderCmds)) items
                                  else Render.withoutShaders(items);
                let (sprites, polygons) = Render.drawWith(
                    name -> GameEngine.Game.getTextureInfo(name), itemsToDraw);
                GameEngine.Game.renderCommands(sprites, tileCmds, polygons, staticLayerCmd(app, world));
                // 数えるのは itemsForGlyphs（本編 + レンダーターゲットの中）— headless の
                // 検査と同じ量にそろえる。タイル層・静的層は GPU 側で 1 層 1 draw call に
                // なるので、ここには最初から乗っていない（= 正しく静的化した絵は安いまま）。
                // 知らせた後は数えない — List.length も毎フレームの一巡で、答えはもう使われない。
                (nextCache, nextSeen,
                 if (budgetWarned) true
                 else warnOverBudget(List.length(itemsForGlyphs), budgetWarned))
        }

    /// 1 コマだけ描く（窓なしで GPU に塗る 1 枚撮り・動画。render_gl の GlOffscreen.handle の下で呼ぶ）。
    /// 実機の 1 フレームの描く所（renderFrame）と同じ道で、fps の重ねと予算の知らせは無し。
    /// 初めて出る字はこのコマでは欠ける（アトラスを育てるのはこのコマの後）ので、欠けが出たら描き直す（最大 3 回）。
    /// tileCache は同じ GL の文脈の間で持ち回す（最初は freshTileCache()）。
    pub def paintOnce(app: App[w, ef], world: w, tileCache: TileCache):
            TileCache \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target + IO) =
        def go(cache, left) = {
            let (next, seen, _) = renderFrame(app, _ -> (), world, Nil, cache, None, true);
            if (Option.isEmpty(seen) and left > 1) go(next, left - 1) else next
        };
        go(tileCache, 3)

    /// レンダーターゲットの列を本編より先に描く（宣言順）。ターゲットの中は design 座標
    /// そのまま・Shader 面は乗らない（Pass の doc を参照）。design はターゲットの寸法に使う。
    def renderPasses(design: Vec2.Vec2, passList: List[Render.Pass]):
            Unit \ (GameEngine.Game + RenderTarget.Target) =
        List.forEach(p -> {
            RenderTarget.Target.beginTarget(p#name,
                Num.floorInt(design#x), Num.floorInt(design#y), p#clear);
            let (passDs, passPolys) = Render.drawWith(
                name -> GameEngine.Game.getTextureInfo(name),
                Render.withoutShaders(p#items));
            GameEngine.Game.renderCommands(passDs, Nil, passPolys, None);
            RenderTarget.Target.endTarget()
        }, passList)

    // WhyNot: 同じ 10 行を UiRender・SortingLayer・App に 1 つずつ置く。pub にするとゲームから z を書き換えられ、
    //   どの層に入るかが表から読めなくなる（Flix 0.77 にはパッケージの中だけで見える pub が無い）。
    /// 描画物の重なり順（zIndex）を f で写す（Clipped は中身の z）。HUD を HUD の範囲へ持ち上げる所（composeScene）だけで使う。
    def zMapped(f: Int32 -> Int32, item: Render.Item): Render.Item =
        match item {
            case Render.Item.Sprite(s)  => Render.Item.Sprite({ zIndex = f(s#zIndex) | s })
            case Render.Item.Text(x)    => Render.Item.Text({ zIndex = f(x#zIndex) | x })
            case Render.Item.Box(b)     => Render.Item.Box({ zIndex = f(b#zIndex) | b })
            case Render.Item.Poly(p)    => Render.Item.Poly({ zIndex = f(p#zIndex) | p })
            case Render.Item.Shader(s)  => Render.Item.Shader({ zIndex = f(s#zIndex) | s })
            case Render.Item.Clipped(c) => Render.Item.Clipped({ inner = zMapped(f, c#inner) | c })
        }
}
