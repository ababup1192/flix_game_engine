// App — ゲームを「宣言」で組み立てて走らせるランナー。ゲーム側は初期 World にシステムと
// 絵と音を繋いで launch を呼ぶだけで、ウィンドウ・時計・入力・描画・ループはすべてここが引き受ける。
// 外の世界に触れる処理（effect）をこのモジュールが独占するので、ゲームのシステムは
// (Frame, w) -> w の純粋関数として書ける（毎フレームの入力と dt は Frame に埋め込んで渡す）。
//
// 更新系（addSystem）が World を進め、描画（withView）は進んだ後の World を読むだけで
// 変えない — 1 フレームは必ずこの順（1 周の全手順は下の loop の doc を見る）。

pub mod App {
    import java.lang.System

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
        wheel = Float64                    // このフレームのホイール量（上が正・下が負。無ければ 0。
                                           // ランナーが毎フレーム consumeScrollDelta を読み切るので、
                                           // ゲーム側が直接 consume すると常に 0 が返る — 必ずここから読む）
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
    pub type alias ViewCtx = { atlas = FontAtlas, fontOf = String -> FontAtlas, visible = Rect2.Rect2 }

    /// ヘッドレス描き出しから view を呼ぶときの ViewCtx。画面全体が見えている扱いにする。
    /// フォント 1 本だけの版 — どの名前で引いても同じ本が返る。
    pub def viewCtxOf(atlas: FontAtlas, design: Vec2.Vec2): ViewCtx =
        viewCtxOfFonts(atlas, _ -> atlas, design)

    /// viewCtxOf の複数フォント版。fontOf には実機と同じ名前で引ける関数を渡す
    /// （HeadlessFont.buildAtlas に実機と同じ name を渡して組んだ本を返す関数）。
    /// 名前が実機と食い違うと、描き出した絵だけ別の字になる。
    pub def viewCtxOfFonts(atlas: FontAtlas, fontOf: String -> FontAtlas, design: Vec2.Vec2): ViewCtx =
        { atlas = atlas, fontOf = fontOf,
          visible = { position = { x = 0.0, y = 0.0 }, size = design } }

    /// 生成したドット絵アトラス 1 枚ぶんの受け渡し。
    /// texture = 絵を引くときの名前、key = その画素の中身を決める全入力を 1 文字列にまとめた物
    /// （同じ key の間は GPU へ上げ直さない）、baked = PxSpriteAtlas.bake の生成結果。
    pub type alias AtlasUpload = { texture = String, key = String, baked = PxSpriteAtlas.Baked }

    /// ゲーム 1 本の宣言。make で空を作り、addStartup / addSystem / reloadOn / withView /
    /// withAudio / quitWhen で部品を繋ぎ、launch へ渡す。w はゲームが持ち込む World の型、
    /// ef はシステム・絵・音・終了判定が帯びる効果（外の世界に触れる処理）の行
    /// （純粋なゲームは ef = {}）。各フィールドの意味は右の // コメントを参照。
    pub type alias App[w: Type, ef: Eff] = {
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
        debug = Bool,                                              // デバッグ機能（F8 の時間停止・注釈・巻き戻し）を有効にするか
        // view = None のゲームがデバッグ機能を使うための生投影（フォントアトラス名と、World →
        // 描画チャンネル 3 本）。描画はせずチャンネルを返すだけの関数を繋ぐ。
        debugView = Option[(String, w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef)],
        // 注釈の矩形（デザイン座標）と表示中の瞬間の World からテキストを組む。
        // 注釈チケットに world.json として同梱され、リモートデバッグの view=full にもなる。
        worldDump = Option[(Rect2.Rect2, w) -> String \ ef],
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
        // リモートデバッグ（HTTP）の任意パスに応える、ゲーム登録のハンドラ（onRequest で足す）。
        // (パス, (クエリ, World) -> Ok(次の World) / Err(理由)) の列。既定ルートに無いパスだけが
        // ここへ来て、パスの完全一致・登録順の先勝ちで 1 本選ばれる。
        remoteHandlers = List[(String, (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead})],
        // 物理・当たり判定を実時間でなく固定量子で進めたいゲームの刻み幅（秒）。None = 可変 dt
        // のまま（既定・全既存ゲームはこちら）。withFixedStep で有効化する（詳細は同関数を参照）。
        fixedStep = Option[Float64]
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
        { init = f,
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
          debug = false,
          debugView = None,
          worldDump = None,
          statusLine = None,
          remoteRender = None,
          remoteHandlers = Nil,
          fixedStep = None }

    /// 起動時に 1 回だけ走るシステムを末尾へ繋ぐ（追加順に適用される）。
    pub def addStartup(sys: w -> w \ ef, app: App[w, ef]): App[w, ef] =
        { startupSystems = List.append(app#startupSystems, sys :: Nil) | app }

    /// 毎フレーム走るシステムを末尾へ繋ぐ（追加順に適用される）。
    pub def addSystem(sys: (Frame, w) -> w \ ef, app: App[w, ef]): App[w, ef] =
        { updateSystems = List.append(app#updateSystems, sys :: Nil) | app }

    /// key が押された瞬間に World を作り直すホットリロードを繋ぐ（ファイル読みの副作用つき）。
    /// 遊びながら設定ファイルを編集し、キー一発で効きを変える用途に。
    pub def reloadOn(key: GameEngine.Key, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef] =
        { reload = Some((key, f)) | app }

    /// path の保存（更新時刻の変化）を検知して World を作り直すホットリロードを繋ぐ。
    /// reloadOn と同型の関数を渡せるので、F1 と保存検知に同じ関数を繋げる。
    /// 監視は withDebug 有効時のみ・約 0.5 秒間隔。読めない・壊れたときの扱いは f の責務
    /// （今の World をそのまま返す fail-open を推奨）。
    /// 同じパスを複数回登録すると、保存のたびに登録順で全部発火する。
    pub def watchFile(path: String, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef] =
        { watch = List.append(app#watch, (path, f) :: Nil) | app }

    /// World を絵（(置き場所, 見せたい物) の列）へ投影する関数を繋ぐ。
    /// 第 1 引数の ViewCtx から既定フォント（atlas）と見えている world 矩形（visible）が取れる。
    pub def withView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                     app: App[w, ef]): App[w, ef] =
        { view = Some(v) | app }

    /// 本編より先にレンダーターゲット（描いた結果を読み返せる描き込み先）へ描く列を
    /// World から導く関数を繋ぐ。1 枚は Render.Pass（名前・クリア指定・絵の列）で、
    /// 名前がそのままテクスチャ名になる — view からは Render.sprite(名前, z) で普通の
    /// スプライトとして貼れる（部分切り出し regionRect・blend・拡大も既存の道がそのまま効く）。
    /// 複数光源の光マップ・画面を素材にする演出・残像（clear = RenderTarget.LoadOp.Keep で
    /// 前フレームを残す）に使う。
    pub def withPasses(f: w -> List[Render.Pass] \ ef, app: App[w, ef]): App[w, ef] =
        { passes = f | app }

    /// 既定フォント以外に使うフォントの名前を宣言する（project.json の fonts[].name と同じ字）。
    /// ここで宣言した名前だけが view の ViewCtx#fontOf で引ける（宣言していない名前は既定
    /// フォントが返る）。話し手ごとに字を変えるようなゲームで使う。
    /// project.json に無い名前を宣言すると起動時に落ちる — 綴りは fonts[] と揃えること。
    pub def withFonts(names: List[String], app: App[w, ef]): App[w, ef] =
        { fonts = List.append(app#fonts, names) | app }

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
        { pixelSnap = f | app }

    /// ドット絵のアトラス（PxSpriteAtlas.bake の生成結果）を、名前付きテクスチャとして
    /// 使えるようにする。これを繋いだうえで PxSprite.drawQuad を使うと、1 体が画素ごとの
    /// 矩形の列ではなく 1 枚のクアッドになる — 草や作物のように画面に何百と出る絵で効く。
    /// key はその画素の中身を決める全入力（色票・世代番号など）を 1 文字列にまとめた物。
    /// 同じ key の間は何も起きないので、毎フレーム呼ばれる前提でよい。
    /// 生成する仕事（bake）は World 側で 1 度だけ済ませ、ここには生成結果を渡すこと。
    pub def withSpriteAtlases(f: w -> List[AtlasUpload], app: App[w, ef]): App[w, ef] =
        { spriteAtlases = f | app }

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
        { staticLayer = Some({ key = key, build = build }) | app }

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
        { tileLayers = Some(f) | app }

    /// World から「画面中央に映したい world 座標」を導く関数を繋ぐ。view は world 座標のまま
    /// 書けばよく、画面へのずらしは App が引き受ける（F8 の凍結画面やリモートの注釈にも同じ
    /// カメラが効く）。追従やシェイクはゲーム側システムで World に持たせ、ここでは読むだけにする。
    pub def withCamera(f: w -> Vec2.Vec2 \ ef, app: App[w, ef]): App[w, ef] =
        { camera = Some(f) | app }

    /// World から寄り引き倍率（大きいほど寄る）を導く関数を繋ぐ。絵のずらしと大きさの
    /// 伸縮は App が引き受ける。ズームの補間（なめらかな寄り引き）はゲーム側システムで
    /// World に持たせ、ここでは読むだけにする（withCamera の追従と同じ分担）。
    /// withCamera を繋がずにこれだけ繋ぐと、画面中央（design/2 の world 点）を軸に寄り引きする。
    /// 範囲外の倍率（0 以下・NaN・Infinity）は CameraRig.safeZoom が minZoom〜maxZoom へ
    /// 丸めるので画面は壊れない。
    pub def withZoom(f: w -> Float64 \ ef, app: App[w, ef]): App[w, ef] =
        { zoom = Some(f) | app }

    /// camera が映してよい world の矩形（レベルの端）を導く関数を繋ぐ。見えている範囲
    /// （design/zoom）がこの矩形の外に出ないよう center を収める — 端の外の虚空が映らない。
    /// zoom と併用しても正しく効く（引くほど収まる位置が内側になる）。矩形が視界より
    /// 狭い軸は矩形の中央に固定する。withCamera（または withZoom）と併用して効く。
    pub def withCameraBounds(f: w -> Rect2.Rect2 \ ef, app: App[w, ef]): App[w, ef] =
        { cameraBounds = Some(f) | app }

    /// 視差レイヤを末尾へ繋ぐ（addSystem と同じ「列に足す」様式）。view と同じ
    /// (ViewCtx, w) -> 絵 の関数だが、camera の動きに factor を掛けた速さで流れる:
    /// factor 1.0 = 主レイヤと同速、0.3 = 遠景、0.0 = 画面固定。ViewCtx の visible は
    /// そのレイヤの見かけの camera で計算されるので、culling もそのまま書ける。
    pub def addParallaxLayer(factor: Float64, v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                             app: App[w, ef]): App[w, ef] =
        { parallaxLayers = List.append(app#parallaxLayers, (factor, v) :: Nil) | app }

    /// カメラを掛けない絵（スコア等の HUD）を繋ぐ。ここに繋いだ絵は常に view の絵より
    /// 手前（HUD の範囲 = ZBand.hudBase 以上へ持ち上がる）。zIndex が決めるのは HUD の中の
    /// 前後だけ（0..ZBand.innerMax。はみ出しは clamp）。
    /// ViewCtx の visible は常に画面全体（position = 原点, size = design）。
    pub def withHudView(v: (ViewCtx, w) -> List[Render.PlacedItem] \ ef,
                        app: App[w, ef]): App[w, ef] =
        { hudView = Some(v) | app }

    /// 1 フレームの前後の World（{before, after}）から鳴らす音名を導く関数を繋ぐ
    /// （再生は App が引き受ける）。同じ名前が同じフレームに 2 回入っても 1 回だけ鳴る。
    pub def withAudio(sfx: { before = w, after = w } -> List[String] \ ef, app: App[w, ef]): App[w, ef] =
        { audio = sfx | app }

    /// 鳴り続けてほしい音 1 本の宣言。name は project.json の sounds の論理名、
    /// volume は音量 0.0〜1.0、pitch は高さ（1.0 = 元のまま・2.0 で 1 オクターブ上）。
    pub type alias Sustain = { name = String, volume = Float64, pitch = Float64 }

    /// 「このフレームで鳴り続けていてほしい音」を World から導く関数を繋ぐ。
    /// 宣言に載っている間その音は鳴り続け（ループ再生）、載らなくなったフレームで止まる。
    /// 音量と高さは毎フレーム与え直せるので、速度で唸りが変わるエンジン音・強さで太る風・
    /// 走っている間だけ続く足音のように「止め時をゲームが知っている音」をこれ 1 本で書ける。
    /// 単発の効果音（当たった・取った）は withAudio の方を使う。
    pub def withSustained(f: w -> List[Sustain] \ ef, app: App[w, ef]): App[w, ef] =
        { sustained = f | app }

    /// 音の通り道（AudioMixer.Mixer）を World から導く関数を繋ぐ。繋ぐと、withAudio の音と
    /// withSustained の音が名前ごとのバスを通る —— バスの音量・ローパス・ダッキング・連打の間引きが
    /// 掛かる（中身は AudioMixer の doc）。Doc から読んだ 1 つを返すだけでよく、場面ごとに
    /// AudioMixer.withLowpass などで差し替えた物を返してもよい。
    /// 繋いだゲームでは一発の音の音量もミキサーが毎回決める（AudioStreamPlayer.setVolume で
    /// 一発の音の音量を変える書き方とは混ぜない）。
    pub def withMixer(f: w -> AudioMixer.Mixer \ ef, app: App[w, ef]): App[w, ef] =
        { mixer = Some(f) | app }

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
        { quit = f | app }

    /// デバッグ機能（F8 の時間停止・矩形注釈・時間スクラブ）の有効 / 無効を宣言する。
    /// 既定は無効。プレイヤーに配るビルドで時間巻き戻しや内部情報の書き出しが
    /// 使えてしまわないよう、開発時だけ true を渡す（debugFromEnv と組み合わせる）。
    pub def withDebug(enabled: Bool, app: App[w, ef]): App[w, ef] =
        { debug = enabled | app }

    /// 環境変数 DEBUG が空でない値で設定されていれば true（例: `DEBUG=true flix run`）。
    /// Main から `App.withDebug(App.debugFromEnv())` の形で使う。
    pub def debugFromEnv(): Bool \ IO =
        let value = System.getenv("DEBUG");
        not Object.isNull(value) and value != ""

    /// 自前描画（view = None）のゲームがデバッグ機能（F8）を使えるようにする生投影を繋ぐ。
    /// f は World を描画チャンネル（drawable / tileMap / polygon）へ投影する（描画はしない）。
    /// font は一時停止中のメッセージ表示に使うフォントアトラス名（そのゲームが持つ物を指定）。
    pub def withDebugView(font: {font = String},
                          f: w -> (List[GameEngine.Drawable], List[GameEngine.TileMapRenderCmd], List[GameEngine.PolygonRenderCmd]) \ ef,
                          app: App[w, ef]): App[w, ef] =
        { debugView = Some((font#font, f)) | app }

    /// 注釈（F8 の矩形）を書き出すとき「囲った瞬間の World」をテキストにしてチケットへ
    /// world.json として同梱する関数を繋ぐ。絵の情報（annotation.json）とシムの中身を
    /// 突き合わせられるので、見た目と状態の食い違いを注釈だけで特定できるようになる。
    /// f が受け取る矩形はデザイン座標。何をどこまで書くかはゲームが決める
    /// （全フィールドでなく、調査に効く要約でよい）。
    pub def withWorldDump(f: (Rect2.Rect2, w) -> String \ ef, app: App[w, ef]): App[w, ef] =
        { worldDump = Some(f) | app }

    /// World の 1 行サマリ（例: "phase=Playing ball=(163.2,207.9) lives=3"）を繋ぐ。
    /// リモートデバッグ（HTTP）の view=status の本文と、/step の trace の行になる。
    /// 調査に効く値だけを短く。長い一覧は withWorldDump（view=full）側に任せる。
    pub def withStatusLine(f: w -> String \ ef, app: App[w, ef]): App[w, ef] =
        { statusLine = Some(f) | app }

    /// リモートデバッグ（HTTP）の POST /render が実行する「描き出しの実体」を繋ぐ。
    /// f は Docs から決定的な場面を組み立てて PNG に描き出し、そのファイルパスの列を返す
    /// （SceneRender.all の中身をそのまま渡せる形）。走行中のプレイ状態を読んだり変えたりしない
    /// 関数に限る — /render はゲームの進行に触れず、温まった JVM で描き直すだけのエンドポイント。
    /// 繋がないゲームへの /render は「未対応」の応答になる。
    pub def onRenderRequest(f: Unit -> List[String] \ IO, app: App[w, ef]): App[w, ef] =
        { remoteRender = Some(f) | app }

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
        { remoteHandlers = List.append(app#remoteHandlers, (path, f) :: Nil) | app }

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
    /// 呼ばなければ現行の可変 dt のまま挙動は変わらない。
    pub def withFixedStep(dtSeconds: Float64, app: App[w, ef]): App[w, ef] =
        { fixedStep = Some(dtSeconds) | app }

    // ── 純粋な芯（テストはここを直接叩く）──

    /// 前フレームと今フレームのキー集合から Frame を組む。justPressed は差分
    /// （今あって前に無いキー）なので、押しっぱなしはエッジにならない。
    /// マウスも同じ考え方: mouseClicked は「今押されていて前は押されていない」エッジ、
    /// mouseMoved は前フレームとの座標比較（最初のフレームは prevCursor = None で false）。
    /// wheel はバックエンドが貯めた 1 フレームぶんの量を素通しする。
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
          wheel = mouse#wheel }

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
    pub type alias StepState = { carry = Float64, pending = PendingEdges }

    /// 起動直後の StepState（貯金ゼロ・未消費エッジなし）。
    pub def freshStepState(): StepState =
        { carry = 0.0, pending = noPending() }

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
    pub def advanceFrame(app: App[w, ef], frame: Frame, state: StepState, world: w): (w, StepState) \ ef =
        match app#fixedStep {
            case None => (applySystems(frame, app#updateSystems, world), state)
            case Some(fixedDt) =>
                let (steps, nextCarry) = fixedSteps(state#carry, frame#dt, fixedDt);
                let merged = mergeEdges(state#pending, frame);
                if (steps == 0)
                    (world, { carry = nextCarry, pending = pendingOf(merged) })
                else {
                    let firstFrame = { dt = fixedDt | merged };
                    let laterFrame = suppressEdges(firstFrame);
                    let advanced = List.range(0, steps) |> List.foldLeft((acc, i) -> {
                        let subFrame = if (i == 0) firstFrame else laterFrame;
                        applySystems(subFrame, app#updateSystems, acc)
                    }, world);
                    (advanced, { carry = nextCarry, pending = noPending() })
                }
        }

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
            { item = Render.zMapped(ZBand.liftHud, placed#item) | placed });
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
    pub def launch(app: App[w, ef]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + IO) =
        let init = app#init;
        // 下ごしらえの間、画面には読み込み中の起動画面が出たまま残る（描き直さないので止まって見えるが、
        // 出し直す口をここに作ると、間引きも中止スイッチも持たない 2 つ目の経路が生まれる）。
        let world0 = List.foldLeft((acc, sys) -> sys(acc),
                                   init(GameEngine.Game.getViewportRect()#size), app#startupSystems);
        let bridge = if (canDebug(app)) Option.map(RemoteDebug.start, RemoteDebug.portFromEnv())
                     else None;
        // 起動時点の更新時刻を「発火なしで」用意しておく — 用意しないと最初のポーリングが
        // 全パスを新規出現と見なし、init 直後にもう一度リロードが走ってしまう。
        let watch0 = if (app#debug and not List.isEmpty(app#watch))
                         { sincePoll = 0.0, mtimes = statMtimes(List.map(fst, app#watch)) }
                     else freshWatchState();
        // キーと同じく、起動時にすでに押されているボタンは一度離すまでエッジにならない。
        // カーソルの「前の位置」はまだ無い（None）ので、最初のフレームの mouseMoved は false。
        // 固定ステップの状態（持ち越し秒と未消費エッジ）は空から始める。
        loop(app, { world = world0, prevKeys = InputEvent.currentKeys(),
                    prevMouseDown = GameEngine.Game.isMouseButtonPressed(GameEngine.MouseButton.Left),
                    prevCursor = None, anno = Annotate.initial(), history = Nil,
                    bridge = bridge, remoteHold = false, stepState = freshStepState(),
                    watchState = watch0, sustaining = Nil, mixState = AudioMixer.initial(),
                    tileCache = freshTileCache(),
                    glyphSeen = None, budgetWarned = false });
        Option.forEach(RemoteDebug.shutdown, bridge)

    /// 時間スクラブ用に持ち回す直近の World の数（60fps で約 30 秒）。
    /// World は不変値なので、保持しているのは共有構造への参照だけで軽い。
    /// RemoteDebug 分割用の内部 API — ゲームからは呼ばない。
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
        mixState = AudioMixer.State,
        tileCache = TileCache, glyphSeen = Option[Int64],
        // 「絵の値段が予算を超えていると 1 回だけ知らせた」印。毎フレーム出すと
        // 遅い画面がさらに遅くなり、ログも読めなくなる。
        budgetWarned = Bool
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
    /// 更新系システム（advanceFrame。World を進める）→ 音（進んだ World から）→
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
    def loop(app: App[w, ef], st: LoopState[w]): Unit \ (ef + GameEngine.Game + GameEngine.Audio + ShaderEffect.Shader + RenderTarget.Target + Fs.FileRead + IO) =
        let currentKeys = InputEvent.currentKeys();
        let mouseDown = GameEngine.Game.isMouseButtonPressed(GameEngine.MouseButton.Left);
        let cursorNow = GameEngine.Game.getMousePosition();
        let frame = frameOf(prev = st#prevKeys, current = currentKeys, readDt(),
                            GameEngine.Game.getViewportRect()#size,
                            { prevCursor = st#prevCursor, cursor = cursorNow },
                            { prevDown = st#prevMouseDown, down = mouseDown,
                              wheel = GameEngine.Game.consumeScrollDelta() });
        let wantsQuit = app#quit;
        if (GameEngine.Game.shouldClose() or wantsQuit(frame, st#world)) ()
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
                        { world = st#world, anno = st#anno, history = st#history, hold = st#remoteHold });
                    loop(app, { world = next#world, anno = next#anno, history = next#history,
                                remoteHold = next#hold | carried })
                case _ => {
                    let decided = decideBranch({ f8Pressed = justPressed(GameEngine.Key.F8, frame),
                                                 canDebug = canDebug(app), remoteHold = st#remoteHold,
                                                 wasPaused = st#anno#paused });
                    // デバッグモードの出入りをウィンドウタイトルとカーソル形状で示す
                    // （停止中は正確に囲うための十字カーソル）
                    if (decided#toggled) {
                        let pausedNow = decided#branch == Branch.Paused;
                        GameEngine.Game.setDebugBadge(pausedNow);
                        GameEngine.Game.setCursor(
                            if (pausedNow) GameEngine.Cursor.Crosshair else GameEngine.Cursor.Default)
                    } else ();
                    match decided#branch {
                        case Branch.Paused =>
                            let nextAnno = pausedStep(app, st#world, st#history, frame, { paused = true | st#anno });
                            loop(app, { anno = nextAnno | carried })
                        case Branch.Resuming =>
                            // スクラブ位置の World から再開する。巻き戻したぶんの履歴と
                            // フレーム番号も、そこを現在として数え直す。
                            let resumed = resumePoint(st#anno, st#history, st#world);
                            let (cache1, seen1, warned1) = renderFrame(app, resumed#world, fpsOverlayOf(app, resumed#anno), st#tileCache, st#glyphSeen, st#budgetWarned);
                            loop(app, { world = resumed#world, anno = resumed#anno, history = resumed#history,
                                        tileCache = cache1, glyphSeen = seen1,
                                        budgetWarned = warned1 | carried })
                        case Branch.Running =>
                            let (watched, nextWatchState, watchFired) = applyWatch(app, frame#dt, st#watchState, st#world);
                            let (reloaded, reloadFired) = applyReload(app, frame, watched);
                            let (advanced, nextStepState) = advanceFrame(app, frame, st#stepState, reloaded);
                            let (nextSustaining, nextMix) = applyAudio(app, frame#dt, reloaded, advanced,
                                                                       st#sustaining, st#mixState);
                            // fps は debug 有効時だけ計測する（本番ビルドは履歴を積まず無負荷）。
                            let measuredAnno = if (app#debug) Annotate.recordDt(frame#dt, st#anno) else st#anno;
                            // Doc の読み直しが起きたフレームはタイル層の世代を進め、同じ key でも作り直す。
                            let (cache1, seen1, warned1) = renderFrame(app, advanced, fpsOverlayOf(app, measuredAnno),
                                                              bumpTileGen(watchFired or reloadFired, st#tileCache),
                                                              st#glyphSeen, st#budgetWarned);
                            // 時間スクラブ用の履歴（debug が無効なら一切持たない = 本番ビルドは無負荷）
                            let nextHistory = if (canDebug(app))
                                                  List.take(historyLimit(), advanced :: st#history)
                                              else Nil;
                            loop(app, { world = advanced, history = nextHistory,
                                        anno = { frame = measuredAnno#frame + 1i64 | measuredAnno },
                                        stepState = nextStepState, watchState = nextWatchState,
                                        sustaining = nextSustaining, mixState = nextMix, tileCache = cache1,
                                        glyphSeen = seen1, budgetWarned = warned1 | carried })
                    }
                }
            }
        }

    /// 一時停止を抜ける地点: スクラブで表示していた瞬間の World を現在とし、
    /// 履歴とフレーム番号もそこを基準に数え直す（未来側の履歴は捨てる）。
    /// RemoteDebug 分割用の内部 API — ゲームからは呼ばない。
    pub def resumePoint(anno: Annotate.State, history: List[w], world: w): { world = w, anno = Annotate.State, history = List[w] } =
        { world = worldAt(history, anno#scrub, world),
          history = List.drop(anno#scrub, history),
          anno = { frame = anno#frame - Int32.toInt64(anno#scrub) | Annotate.resetView(anno) } }

    /// 履歴の back フレーム前の World（範囲外なら fallback）。先頭が「停止した瞬間」。
    /// RemoteDebug 分割用の内部 API — ゲームからは呼ばない。
    pub def worldAt(history: List[w], back: Int32, fallback: w): w =
        history |> List.drop(back) |> List.head |> Option.getWithDefault(fallback)

    /// デバッグ機能が使える構成か（debug 有効 かつ 凍結画面を描く手段 = view か debugView がある）。
    def canDebug(app: App[w, ef]): Bool =
        app#debug and (Option.nonEmpty(app#view) or Option.nonEmpty(app#debugView))

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
    def pausedStep(app: App[w, ef], world: w, history: List[w], frame: Frame,
                   anno: Annotate.State): Annotate.State \ (ef + GameEngine.Game) =
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
        let dumpText = match (emitted, app#worldDump) {
            case (Some(rect), Some(f)) => f(rect, displayed)
            case _                     => ""
        };
        match app#view {
            case Some(toItems) =>
                uploadAtlases((app#spriteAtlases)(world));
                let atlas = GameEngine.Game.getFontAtlas("default");
                // displayed（スクラブで表示中の瞬間）から絵もカメラも導く — 注釈の hits も同じ items を使う。
                // F8 停止中は静的レイヤーも通常の動的アイテムにまとめて描く（F8 のズーム/パンは
                // channels に効く別変換なので、retained の camera uniform では追随できないため）。
                // 停止中は毎フレーム再投影で軽さは問題にならない。
                let items = List.append(tilePausedItems(app, design, displayed),
                            List.append(sceneItems(app, atlas, displayed, toItems),
                                        staticPausedItems(app, design, displayed)));
                let (sprites, polygons) = Render.drawWith(
                    name -> GameEngine.Game.getTextureInfo(name), items);
                let hitList = match emitted {
                    case Some(rect) => Annotate.hits(name -> GameEngine.Game.getTextureInfo(name), rect, items)
                    case None       => Nil
                };
                finishPaused({ design = design, cursor = input#cursor, atlas = atlas,
                               historyLen = historyLen, shownFrame = shownFrame },
                             next, emitted, dumpText,
                             { drawables = sprites, tileMaps = Nil, polygons = polygons }, hitList)
            case None => match app#debugView {
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
                                 next, emitted, dumpText,
                                 { drawables = drawables, tileMaps = tileMaps, polygons = polygons }, hitList)
                case None => next
            }
        }

    /// 一時停止フレームの締め: 矩形が確定していれば注釈を書き出してトーストを出し、凍結画面を描く。
    def finishPaused(ctx: { design = Vec2.Vec2, cursor = Vec2.Vec2, atlas = FontAtlas,
                            historyLen = Int32, shownFrame = Int64 },
                     anno: Annotate.State, emitted: Option[Rect2.Rect2], dumpText: String,
                     channels: DebugChannels, hitList: List[Annotate.Hit]): Annotate.State \ GameEngine.Game =
        let shown = match emitted {
            case Some(rect) => match writeAnnotation(ctx#design, rect, ctx#shownFrame, dumpText, channels, hitList) {
                case Some(path) => Annotate.showToast("Saved debug file\n${path}", anno)
                case None       => anno
            }
            case None => Annotate.tickToast(anno)
        };
        renderPaused(ctx, shown, channels);
        shown

    /// 確定した矩形の注釈一式（JSON・README の要約・等倍の描画命令）を組んでエンジンへ渡す。
    /// ファイルへの書き出しとスクリーンショット撮影・シャッター音はエンジンの saveAnnotation が
    /// 引き受ける。戻り値は保存先のディレクトリパス（失敗時 None）。
    def writeAnnotation(design: Vec2.Vec2, rect: Rect2.Rect2, frameNo: Int64, dumpText: String,
                        channels: DebugChannels, hitList: List[Annotate.Hit]): Option[String] \ GameEngine.Game =
        let body = Annotate.readmeBody({ frame = frameNo, rect = rect }, hitList);
        GameEngine.Game.saveAnnotation({
            frame = frameNo, rect = rect,
            json = Annotate.annotationJson({ frame = frameNo, design = design, rect = rect }, hitList),
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
    /// RemoteDebug 分割用の内部 API — ゲームからは呼ばない。
    pub def applyReload(app: App[w, ef], frame: Frame, world: w): (w, Bool) \ {Fs.FileRead} =
        match app#reload {
            case Some((key, f)) => if (justPressed(key, frame)) (f(world), true) else (world, false)
            case None           => (world, false)
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
    def applyWatch(app: App[w, ef], dt: Float64, state: WatchState, world: w): (w, WatchState, Bool) \ {Fs.FileRead, IO} =
        if (not app#debug or List.isEmpty(app#watch))
            (world, state, false)
        else {
            let waited = state#sincePoll + dt;
            if (waited < watchPollInterval())
                (world, { sincePoll = waited | state }, false)
            else {
                let current = statMtimes(List.map(fst, app#watch));
                let changed = changedPaths(List.map(fst, app#watch), state#mtimes, current);
                let next = app#watch |> List.foldLeft((acc, entry) -> {
                    let (path, f) = entry;
                    if (List.memberOf(path, changed)) {
                        System.err.println("watch reload: ${path}");
                        f(acc)
                    } else acc
                }, world);
                (next, { sincePoll = 0.0, mtimes = current }, not List.isEmpty(changed))
            }
        }

    /// 1 フレームの音: ミキサーが無ければ今までどおり名前のまま鳴らし、あればバスを通して鳴らす。
    /// 返すのは次のフレームへ渡す「いま鳴り続けている名前」とミキサーの状態。
    def applyAudio(app: App[w, ef], dt: Float64, before: w, after: w,
                   prev: List[String], mixState: AudioMixer.State):
            (List[String], AudioMixer.State) \ (ef + GameEngine.Audio) =
        match app#mixer {
            case None =>
                playSounds(app, before, after);
                (applySustained(app, prev, after), mixState)
            case Some(mixerOf) =>
                let derive = app#audio;
                let declare = app#sustained;
                applyMixed(mixerOf(after), dt, derive({ before = before, after = after }), declare(after), prev, mixState)
        }

    /// バスを通して鳴らす。順番: ミキサーを 1 フレーム進める（AudioMixer.step）→ 鳴っている一発の音へ
    /// 今の音量とローパスを流し直す（ダッキングの最中に下がっていく）→ 通った一発の音を鳴らす →
    /// 鳴り続ける音を始める・続ける・止める（宣言の音量 × バスの倍率）。
    /// RemoteDebug / App 本体の内部 API — ゲームからは呼ばない。
    pub def applyMixed(mixer: AudioMixer.Mixer, dt: Float64, plays: List[String], declared: List[Sustain],
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
        allowed |> List.forEach(name -> GameEngine.Audio.playAudio(name));
        ops#stop |> List.forEach(name -> GameEngine.Audio.stopAudio(name));
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

    /// audio の導いた音名を鳴らす（システム適用の前後の World から導く）。
    /// 同じ名前が 2 回返っても 1 回にまとめる — 同フレームの二重再生は同じ音源を
    /// 頭から鳴らし直して途切れる（sustainOps の先勝ちと同じ理屈）。
    def playSounds(app: App[w, ef], before: w, after: w): Unit \ (ef + GameEngine.Audio) =
        let derive = app#audio;
        derive({ before = before, after = after })
            |> List.distinct
            |> List.forEach(name -> GameEngine.Audio.playAudio(name))

    /// sustained の宣言を音へ反映し、次のフレームへ渡す「いま鳴っている名前」を返す。
    /// 鳴らし始めだけ playAudio を打ち、続いている音には音量と高さだけ流す
    /// （毎フレーム鳴らし直すと頭から再生され、続く音にならない）。
    def applySustained(app: App[w, ef], prev: List[String], world: w): List[String] \ (ef + GameEngine.Audio) =
        let derive = app#sustained;
        let ops = sustainOps(prev, derive(world));
        ops#stop |> List.forEach(name -> GameEngine.Audio.stopAudio(name));
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
        List.map(s -> s#name, List.append(ops#start, ops#keep))

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
        let z = match app#zoom {
            case None    => 1.0
            case Some(f) => f(world)
        };
        let center0 = match app#camera {
            case Some(f) => Some(f(world))
            case None    => None
        };
        let center = match (zoomedCenter(center0, z, design), app#cameraBounds) {
            case (Some(c), Some(fb)) =>
                let seen = Vec2.div(design, CameraRig.safeZoom(z));
                Some(CameraRig.clampCenter(bounds = fb(world), seen = seen, c))
            case (c, _) => c
        };
        // 画素の升目に吸着させる（静的な絵と動く絵が同じ値を見るので、両者はずれない）。
        let snap = (app#pixelSnap)(world);
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
        let table = app#fonts |> List.foldLeft((acc, n) ->
            Map.insert(n, GameEngine.Game.getFontAtlas(n), acc),
            (Map.empty(): Map[String, FontAtlas]));
        name -> Map.get(name, table) |> Option.getWithDefault(dflt)

    /// RemoteDebug 分割用の内部 API — ゲームからは呼ばない。
    pub def sceneItems(app: App[w, ef], atlas: FontAtlas, world: w,
                   toItems: (ViewCtx, w) -> List[Render.PlacedItem] \ ef):
            List[Render.PlacedItem] \ (ef + GameEngine.Game) =
        let design = GameEngine.Game.getViewportRect()#size;
        let fontOf = fontResolver(app, atlas);
        let (center, z) = resolvedCamera(app, world, design);
        let hud = match app#hudView {
            case None    => Nil
            // HUD は画面固定なので、見えている矩形は常に design 全体（原点起点）で zoom も掛けない。
            case Some(h) => h({ atlas = atlas, fontOf = fontOf, visible = visibleOf(None, 1.0, design) }, world)
        };
        // 視差レイヤ: 見かけの center（parallaxCenter）で culling も合成も行う。hud は混ぜない。
        let layers = app#parallaxLayers |> List.flatMap(fl -> {
            let (factor, lview) = fl;
            let lcenter = Option.map(c -> CameraRig.parallaxCenter(factor, c, design = design), center);
            let lctx = { atlas = atlas, fontOf = fontOf, visible = visibleOf(lcenter, z, design) };
            composeScene(lcenter, z, design, { world = lview(lctx, world), hud = Nil })
        });
        let ctx = { atlas = atlas, fontOf = fontOf, visible = visibleOf(center, z, design) };
        List.append(layers, composeScene(center, z, design, { world = toItems(ctx, world), hud = hud }))

    /// debug 有効時だけ、画面右上に小さく fps を出す絵を組む（無効なら空 = 本番に一切出ない）。
    /// fps 表示は withView を使うゲームのみ（view = None の自前描画ゲームには出ない）—
    /// renderFrame が App の絵を描かない構成では、ここで組んでも捨てられるだけなので組まない。
    /// 字はゲームのフォントではなく組み込みフォントで出す — ゲームごとにフォント名が違い、
    /// 特定の名前を当てにすると名前が違うゲームで fps 表示が出せなくなる。
    def fpsOverlayOf(app: App[w, ef], anno: Annotate.State): List[Render.PlacedItem] \ GameEngine.Game =
        if (not app#debug or Option.isEmpty(app#view)) Nil
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
        match app#staticLayer {
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
        match app#staticLayer {
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
        match app#tileLayers {
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
        match app#tileLayers {
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
    def warnOverBudget(count: Int32, warned: Bool): Bool \ IO =
        if (warned or count < budgetCap()) warned
        else {
            System.err.println("budget: この 1 フレームで ${count} 個の描き物を組みました"
                + "（上限 ${budgetCap()} 個）。盤や群れを毎フレーム組み直していませんか —"
                + " タイル層は App.withTileLayers（逆引き: docs/module-index.md）");
            true
        }

    def renderFrame(app: App[w, ef], world: w, fpsOverlay: List[Render.PlacedItem],
                    tileCache: TileCache, glyphSeen: Option[Int64], budgetWarned: Bool):
            (TileCache, Option[Int64], Bool) \ (ef + GameEngine.Game + ShaderEffect.Shader + RenderTarget.Target + IO) =
        match app#view {
            case None          => (tileCache, glyphSeen, budgetWarned)
            case Some(toItems) =>
                uploadAtlases((app#spriteAtlases)(world));
                let atlas = GameEngine.Game.getFontAtlas("default");
                let design = GameEngine.Game.getViewportRect()#size;
                let passList = (app#passes)(world);
                renderPasses(design, passList);
                // fpsOverlay は本番ビルドで Nil — 空の append で本編全件を cons し直さない。
                let scene = sceneItems(app, atlas, world, toItems);
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
                let shaderCmds = Render.drawShaders(spec -> ShaderEffect.Shader.buildProgram(spec), items);
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

}
