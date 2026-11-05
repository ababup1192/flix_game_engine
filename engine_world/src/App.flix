// App — ゲームを「宣言」で組み立てて走らせるランナー。ゲーム側は初期 World にシステムと
// 絵と音を繋いで launch を呼ぶだけで、ウィンドウ・時計・入力・描画・ループはすべてここが引き受ける。
// 外の世界に触れる処理（effect）をこのモジュールが独占するので、ゲームのシステムは
// (Frame, w) -> w の純粋関数として書ける（毎フレームの入力と dt は Frame に埋め込んで渡す）。
//
// 更新系（addSystem）が World を進め、描画（withView）は進んだ後の World を読むだけで
// 変えない — 1 フレームは必ずこの順（1 周の全手順は App.Internal.Runner.loop の doc を見る）。

pub mod App {

    /// ゲーム 1 本の宣言。make で作り、addSystem / withView などのビルダーで部品を繋いで launch へ渡す。
    /// 中身は Rec。record のままにしないのは、37 欄の record の型が App を受ける全部の def とゲームのビルダーの列で
    /// 展開され、型検査が重くなるため（docs/flix-conventions.md）。
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
        mouseButtons = Set[GameEngine.MouseButton],        // いま押されているボタン（左・右・中。左は mouseDown と同じ）
        mouseClickedButtons = Set[GameEngine.MouseButton], // このフレームで新しく押されたボタン（エッジ。左は mouseClicked と同じ）
        mouseMoved = Bool,                 // このフレームでマウスが動いたか（前フレームとの座標比較）
        wheel = Float64,                   // このフレームのホイール量（上が正・下が負。無ければ 0。
                                           // ランナーが毎フレーム consumeScrollDelta を読み切るので、
                                           // ゲーム側が直接 consume すると常に 0 が返る — 必ずここから読む）
        realNow = Clock.Time[Clock.Real],  // 実時間の今（起動からの秒。ポーズメニューの点滅・背景の雨のように
                                           // 遊びの時計が止まっても動く物が読む。App が advanceFrame で置く —
                                           // ゲームは実時間の時計を持たないので、止める・2 度進めるができない）
        padTouched = Bool,                 // ゲームパッドのどこかにいま触っているか（案内のキーの絵をパッドの物へ替える判断に。
                                           // パッドの入力そのものはキーへ読み替えて down / justPressed に入っている。
                                           // 読み替えの表は GamepadMap.table）
        padKind = GamepadMap.PadKind,      // つないだパッドの機種（Generic = Xbox 配置の一般・Steam = Steam Input を通した物・
                                           // Unknown = つないでいない）。案内に出すボタンの絵を機種で替える判断に
        mouseDelta = Vec2.Vec2,            // 前のフレームからマウスが動いた量（design px・小数・右と下が正）。withMouseCapture で
                                           // キャプチャしている間も窓の端で止まらずに出る（一人称の視点はこれで回す。cursor の差で回さない）。
                                           // キャプチャを切り替えた拍・フォーカスが戻った拍は 0
        windowFocused = Bool,              // 窓にフォーカスがあるか（外れている間にキャプチャの宣言を出し続けても OS はキャプチャしない）
        sizeClass = Display.SizeClass,     // 端末の区分（Small = スマホ・Medium = タブレット・Large = PC とデスクトップ版）。起動の時に決まり、
                                           // 遊んでいる間は変わらない。View で並べ方を替えたら、当たりを取る所もこれで同じ並べ方を引く。
                                           // WhyNot: 画面の大きさ・倍率・最後の pointer をここに置かない — 窓の大きさや入力で
                                           // 同じ遊びの中でも変わり、World に入ると録って再生した結果が食い違う（View は ViewCtx#display で読む）。
                                           // ブラウザ版で遊んだ記録は Flow に載らない（録る・流すはデスクトップだけ・いつも Large）
        diagnostics = Option[FrameDiagnostics.Diagnostics] // 前のフレームを描いた診断（CPU・GPU の時間・3D の数）。withDiagnostics の
                                           // 間だけ Some（F8 で止めていた拍の後は止める前の値）。画面に出すなら View・HUD で ViewCtx#diagnostics から。
                                           // 系で読んで World を変えない（遊んだ記録に残らず、再生では None。lint-forbid の frame-diagnostics-in-system）
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
    /// diagnostics は前のフレームを描いた診断（CPU・GPU の時間・3D の数）。実機で withDiagnostics を宣言した間だけ Some で、
    /// 画面なしの描き出し（viewCtxOf / viewCtxOfFonts）と pickCtx では None。F3 の行は FrameDiagnostics.summaryLines(d) を
    /// ゲームの字の部品で描く。View の中で読むだけなので、遊んだ記録と再生は食い違わない。
    /// display は今の画面の情報（大きさ・倍率・最後の pointer・端末の区分）。小さい画面（sizeClass が Small）だけ字とボタンを
    /// 大きくする・指の時だけ案内を「タップ」にする、のように使う。当たりの並べ方を替えるなら、入力の側は Frame#sizeClass で
    /// 同じ並べ方を引く。画面なしの描き出しと pickCtx では Display.desktop(design)（Large・Mouse）で、小さい画面を描き出すなら
    /// `{ display = { sizeClass = Display.SizeClass.Small | ctx#display } | ctx }` で差し替える。
    pub type alias ViewCtx = { atlas = FontAtlas, fontOf = String -> FontAtlas, visible = Rect2.Rect2,
                               warnOnce = String -> Unit, diagnostics = Option[FrameDiagnostics.Diagnostics],
                               display = Display.Display }

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
          warnOnce = Log.warn, diagnostics = None, display = Display.desktop(design) }

    /// 入力の側（update・テスト）で、押せる物の当たりを出すために View の木を組むときの ViewCtx
    /// （`SortingLayer.pickFrom(点, View.layers(App.pickCtx(design), w))`）。字の形を持たないフォントで、
    /// 知らせは黙る（同じ木を描く compose の側で出る）。当たりの矩形は字の幅から作らない —— この ctx では幅が 0 になる。
    pub def pickCtx(design: Vec2.Vec2): ViewCtx =
        let blank = { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0,
                      lineGap = 0.0, glyphs = Map.empty() };
        { atlas = blank, fontOf = _ -> blank,
          visible = { position = { x = 0.0, y = 0.0 }, size = design },
          warnOnce = _ -> (), diagnostics = None, display = Display.desktop(design) }

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

    /// App の中身（欄の意味は右の // コメント）。ゲームからは読まず、ビルダー（addSystem / withView など）で組む。
    /// w はゲームが持ち込む World の型、ef はシステム・絵・音・終了判定が帯びる効果（外の世界に触れる処理）の行
    /// （純粋なゲームは ef = {}）。
    pub type alias Rec[w: Type, ef: Eff] = {
        init = Vec2.Vec2 -> w \ ef,                                // design 解像度 → 出発点の World（launch が画面サイズを渡して呼ぶ）
        startupSystems = List[w -> w \ ef],                        // 起動時に 1 回だけ・追加順
        updateSystems = List[(Frame, w) -> w \ ef],                // 毎フレーム・追加順
        reload = Option[(GameEngine.Key, w -> w \ {Fs.FileRead})], // ホットリロード（キーと、ファイル読みの副作用）
        watch = List[(String, w -> w \ {Fs.FileRead})],            // 保存検知のホットリロード（パスと関数）の列・追加順
        reloadPaths = Option[List[String]],                        // freshWorld の読み直しが読む Doc のパス（自前の reloadOn で分からない時は None）
        // World を (置き場所, 見せたい物) の列へ投影する。None のゲームは App に描画させず自分の
        // システム内で描く（タイルマップ等の複数チャンネルを直接組むゲーム向け）。
        view = Option[(ViewCtx, w) -> List[Render.PlacedItem] \ ef],
        // 本編より先にレンダーターゲットへ描く計画（列は追加順に描く・名前ごとの倍率）。各ターゲットは名前の
        // テクスチャになり、view から Render.sprite(名前, z) で貼れる。カメラ・zoom は
        // 掛からない（ターゲットの中は常に design 座標そのまま — カメラを効かせたい絵は
        // view と同じ composeScene をゲーム側で通してから渡す）。
        passes = w -> Render.PassPlan \ ef,
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
        // withPreload3d の宣言。
        preload3d = Option[{ key = w -> GameEngine.StaticKey, instances = w -> List[Scene3d.Instance3d], textures = w -> List[Texture3d.Texture3d] }],
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
        // 次のコマの World を別のスレッドで進めながら、1 つ前の World を描くか（withPipelinedRendering）。
        pipelinedRendering = Bool,
        // 遊びの時計（addClock で宣言）を 1 フレームぶん進める関数の列・追加順。引数は実時間の dt。
        clocks = List[(Float64, w) -> w],
        // 毎フレームの「マウスの矢印をどう見せたいか」の宣言（withCursor）。None = App は触らない（F8 の十字だけ）。
        cursor = Option[w -> CursorSpec],
        // 毎フレームの「窓をフルスクリーンにしたいか」の宣言（withFullscreen）。None = App は触らない。
        fullscreen = Option[w -> Bool],
        // 毎フレームの「マウスを窓にキャプチャしたいか」の宣言（withMouseCapture）。None = App は触らない（F8 で放すだけ）。
        mouseCapture = Option[w -> Bool],
        // 描く側の診断を集めて Frame#diagnostics へ渡すか（withDiagnostics）。
        diagnostics = Bool,
        // 鍵が変わったフレームに 1 回書く外への出力（addOutput・withDocTable）の列・追加順。
        outputs = List[Output[w]],
        // 始まりの登録簿（withStarts）。START・/start・flow の start・テストが名前で場面を組む。
        starts = List[Start[w]],
        // ギャラリーの場面の始まり（withShots）。名前は shot:<場面> で引く（starts の一覧と先頭には混ぜない）。
        shots = List[Start[w]],
        // flow（e2e/<名前>.flow）の語彙の表: 役・問い・名前付きの操作・入力を受けられるか・返事の通し番号（withFlow）。
        flow = Flow.Table[w],
        // World の指紋の元の文字（withFingerprint）。記録の 60 フレームごとの expect fp= と、再生の食い違いの指し示し。
        fingerprint = Option[w -> String],
        // World 全体の要約（expect world=）を取る前に、記録の外から来る値を決まった値へ置き換える（withWorldSummaryMask）。
        summaryMask = w -> w
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
          reloadPaths = Some(Nil),
          view = None,
          passes = _ -> checked_ecast(Render.passPlan(Nil)),
          fonts = Nil,
          camera = None,
          zoom = None,
          cameraBounds = None,
          parallaxLayers = Nil,
          hudView = None,
          staticLayer = None,
          preload3d = None,
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
          pipelinedRendering = false,
          clocks = Nil,
          cursor = None,
          fullscreen = None,
          mouseCapture = None,
          diagnostics = false,
          outputs = Nil,
          starts = Nil,
          shots = Nil,
          flow = Flow.emptyTable(),
          fingerprint = None,
          summaryMask = w -> w })

    /// 起動時に 1 回だけ走るシステムを末尾へ繋ぐ（追加順に適用される）。
    pub def addStartup(sys: w -> w \ ef, app: App[w, ef]): App[w, ef] =
        let r = rec(app);
        App.App({ startupSystems = List.append(r#startupSystems, sys :: Nil) | r })

    /// 毎フレーム走るシステムを末尾へ繋ぐ（追加順に適用される）。
    pub def addSystem(sys: (Frame, w) -> w \ ef, app: App[w, ef]): App[w, ef] =
        let r = rec(app);
        App.App({ updateSystems = List.append(r#updateSystems, sys :: Nil) | r })

    /// key が押された瞬間に World を作り直すホットリロードを繋ぐ（ファイル読みの副作用つき）。
    /// 遊びながら設定ファイルを編集し、キー一発で効きを変える用途に。
    pub def reloadOn(key: GameEngine.Key, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef] =
        App.App({ reload = Some((key, f)), reloadPaths = None | rec(app) })

    /// path の保存（更新時刻の変化）を検知して World を作り直すホットリロードを繋ぐ。
    /// reloadOn と同型の関数を渡せるので、F1 と保存検知に同じ関数を繋げる。
    /// 監視は withDebug 有効時のみ・約 0.5 秒間隔。読めない・壊れたときの扱いは f の責務
    /// （今の World をそのまま返す fail-open を推奨）。
    /// 同じパスを複数回登録すると、保存のたびに登録順で全部発火する。
    pub def watchFile(path: String, f: w -> w \ {Fs.FileRead}, app: App[w, ef]): App[w, ef] =
        let r = rec(app);
        App.App({ watch = List.append(r#watch, (path, f) :: Nil),
                  reloadPaths = Option.map(paths -> List.append(paths, path :: Nil), r#reloadPaths) | r })

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
    /// 倍率（RenderTarget.Descriptor）を付けるなら withPassPlan を使う。
    pub def withPasses(f: w -> List[Render.Pass] \ ef, app: App[w, ef]): App[w, ef] =
        withPassPlan(w -> Render.passPlan(f(w)), app)

    /// withPasses の、名前ごとのターゲットの作り方（倍率）も付ける形。描き出しは同じ PassPlan を
    /// Render.passSpecsOf に渡す（倍率を 2 か所に書かない）。Pass の中の読みは Render.resolvePassReads の決まりに従う。
    pub def withPassPlan(f: w -> Render.PassPlan \ ef, app: App[w, ef]): App[w, ef] =
        App.App({ passes = f | rec(app) })

    /// 既定フォント以外に使うフォントの名前を宣言する（project.json の fonts[].name と同じ字）。
    /// ここで宣言した名前だけが view の ViewCtx#fontOf で引ける（宣言していない名前は既定
    /// フォントが返る）。話し手ごとに字を変えるようなゲームで使う。
    /// project.json に無い名前を宣言すると起動時に落ちる — 綴りは fonts[] と揃えること。
    pub def withFonts(names: List[String], app: App[w, ef]): App[w, ef] =
        let r = rec(app);
        App.App({ fonts = List.append(r#fonts, names) | r })

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

    /// 遊びの途中で初めて出る物（形・絵・材質のプログラム）を GPU へ先に上げる宣言。初めて出るコマに mipmap 作りとプログラムの組み立てが乗って
    /// コマが跳ねるのを、起動（と読み直し）の 1 コマへまとめる。key は毎コマ読み、中身を決める全入力を 1 文字列にまとめた物。
    /// instances と textures は key が変わった時と Doc の読み直しの時だけ読む純粋関数。instances は描かないので置く場所は何でもよい。
    /// 骨つきの物は姿勢を付けたまま渡すと、骨つきの版のプログラムまで組める。view の中で後から作る絵と、材質が読まない絵は上がらない。
    /// textures = 材質が "tex3d:" の名前で読む絵（Instance3d は名前しか持たない。その物を描く場面の textures にも載せる）。
    /// 上げた物は置き場の上限で捨てられにくくなる。形と絵は上限に足りなければ捨て、1 回知らせる。
    /// 描き手が GPU の 3D を持たない時（CPU の描き手・窓の無い描き手・WebLayer.withProject）は何もしない。view = None のゲームでは効かない。
    pub def withPreload3d(plan: { key = w -> GameEngine.StaticKey, instances = w -> List[Scene3d.Instance3d], textures = w -> List[Texture3d.Texture3d] }, app: App[w, ef]): App[w, ef] =
        App.App({ preload3d = Some(plan) | rec(app) })

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
        let r = rec(app);
        App.App({ parallaxLayers = List.append(r#parallaxLayers, (factor, v) :: Nil) | r })

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
    /// F8 で止めている間（注釈・巻き戻しの作業中）の閉じるボタンは、f を呼ばずにその場で閉じる（decideClose）。
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

    /// デバッグ機能が使える構成か（debug 有効 かつ 凍結画面を描く手段 = view か debugView がある）。
    def canDebug(r: Rec[w, ef]): Bool =
        r#debug and (Option.nonEmpty(r#view) or Option.nonEmpty(r#debugView))

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
        let r = rec(app);
        App.App({ remoteHandlers = List.append(r#remoteHandlers, (path, f) :: Nil) | r })

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

    /// 実機のループで、次のコマの World を別のスレッドで進めながら、1 つ前の World を描いて画面へ出す（Bevy の pipelined rendering と同じ考え）。
    /// 進める時間が描く時間（と GPU を待つ時間）の陰に隠れる。代わりに、入力が画面に出るまでが 1 コマ遅れ、
    /// 音は進めた World から鳴るので絵より 1 コマ早い。World の並びは変わらない（trace・台本・/step・描き出しは今まで通り 1 本で進める）。
    /// 効果の無い App だけが使える（別のスレッドには handler が無いので、効果のある系を持ち込めない）。
    /// F8 で止めた画面とリモートの撮影（/shot）は、その時の World（画面より 1 コマ先）を描く。
    /// 重ねるのは機種の Platform.Tasks の handler（デスクトップは描く手と別のスレッド 1 本・ブラウザ版と窓の無い描き手はその場で順に）。
    pub def withPipelinedRendering(app: App[w, {}]): App[w, {}] =
        App.App({ pipelinedRendering = true | rec(app) })

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
        let r = rec(app);
        let tick = (dt, world) -> spec#withClock(Clock.advance(spec#paceOf(world), dt, spec#clockOf(world)), world);
        App.App({ clocks = List.append(r#clocks, tick :: Nil) | r })

    // ── 外への出力（系は IO を持たず、App が実機のフレームの後でだけ触る）──

    /// マウスの矢印の見せ方（withCursor の宣言）。icon = 形・visible = 見せるか。
    pub type alias CursorSpec = { icon = GameEngine.Cursor, visible = Bool }

    /// 毎フレーム「マウスの矢印をどう見せたいか」を World から宣言する。App は宣言が変わったフレームだけ当て、
    /// F8 で止めている間は十字に上書きする（再開した拍に宣言を当て直す）。系の中で setCursor を呼ばない ——
    /// 呼ぶと /step・台本・F8 の再開で矢印の形が World とずれる。
    pub def withCursor(f: w -> CursorSpec, app: App[w, ef]): App[w, ef] =
        App.App({ cursor = Some(f) | rec(app) })

    /// 毎フレーム「窓をボーダーレスのフルスクリーンにしたいか」を World から宣言する（true = フルスクリーン・
    /// false = project.json の大きさのウィンドウ）。App は起動の拍と実機のフレームの後に宣言を当てる
    /// （Platform.Window.setFullscreen は同じ値なら何もしない）。F8 で止めている間・/step・台本・trace は当てない。
    /// 系の中で setFullscreen を呼ばない —— 系は純粋で、呼ぶ口が無い。設定の画面で切り替えたら、その場で窓が替わる。
    pub def withFullscreen(f: w -> Bool, app: App[w, ef]): App[w, ef] =
        App.App({ fullscreen = Some(f) | rec(app) })

    /// 毎フレーム「マウスを窓にキャプチャしたいか」を World から宣言する（一人称の視点。Godot の MOUSE_MODE_CAPTURED・
    /// Bevy の CursorGrabMode::Locked）。キャプチャしている間は矢印が消え、動きは Frame#mouseDelta だけに出る
    /// （Frame#cursor はキャプチャした時の位置で止まり、mouseMoved は偽）。App は宣言が変わったフレームだけ当て、
    /// F8 で止めている間は放す（再開した拍に宣言を当て直す）。放すと矢印はキャプチャする前の位置（止めていた cursor と同じ所）に戻る。
    /// 慣習: 窓をクリックしたらキャプチャ、Esc で放す（放した状態の Esc で終わる・確かめる）。Esc で放すなら quitWhen で既定の Esc の終了を外す。
    /// フォーカスが外れると OS が放し、戻るとキャプチャし直す（Frame#windowFocused で分かる。App は触らない）。
    /// 系の中で setMouseCaptured を呼ばない —— 呼ぶと /step・台本・F8 の再開でキャプチャが World とずれる。
    pub def withMouseCapture(f: w -> Bool, app: App[w, ef]): App[w, ef] =
        App.App({ mouseCapture = Some(f) | rec(app) })

    /// 描く側の診断（CPU・GPU の 1 コマの時間・3D の数）を集め、次のフレームの Frame#diagnostics と ViewCtx#diagnostics に渡す。
    /// 画面に出すなら view か hudView で ctx#diagnostics を FrameDiagnostics.summaryLines に通し、ゲームの字の部品で描く
    /// （出す所と見た目はゲームが決める。出すかどうかの切り替えだけを World に置く）。
    /// WhyNot: 系で Frame#diagnostics を World へ写さない — 遊んだ記録に残らず、再生と食い違う（lint-forbid の frame-diagnostics-in-system）。
    /// GPU の時間は 1〜2 コマ遅れの値で、測れない描き手（窓なしの描き出し）では None。自前で nanoTime を測らない。
    pub def withDiagnostics(app: App[w, ef]): App[w, ef] =
        App.App({ diagnostics = true | rec(app) })

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
        let r = rec(app);
        App.App({ outputs = List.append(r#outputs, output :: Nil) | r })

    /// Doc の一覧表（DocTable）から、保存即反映の監視（watchFile）・F1 の一括読み直し（reloadOn）・
    /// Studio へ「表示中」を名乗る出力（debug/active-docs.json。跳んだ先も名乗る）を 1 度に配線する。
    /// App.game の reloads と一緒に使わない（同じ Doc を 2 度読み直す）。
    pub def withDocTable(rows: List[DocTable.Entry[w]], app: App[w, ef]): App[w, ef] =
        DocTable.reloads(rows)
            |> List.foldLeft((acc, entry) -> { let (path, f) = entry; watchFile(path, f, acc) }, app)
            |> reloadOn(GameEngine.Key.F1, world -> DocTable.reloadAll(rows, world))
            |> withReloadPaths(rows |> List.map(row -> row#path))
            |> addOutput({ keyOf = world -> ActiveDocs.fingerprint(DocTable.activeDocs(rows, world)),
                           write = world -> ActiveDocs.write(DocTable.activeDocs(rows, world)),
                           onJump = OnJump.Write })

    /// freshWorld の読み直しが読む Doc のパスを置き直す（DocTable の一括読み直しは表の全部の行を読みうる）。
    def withReloadPaths(paths: List[String], app: App[w, ef]): App[w, ef] =
        App.App({ reloadPaths = Some(paths) | rec(app) })

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

    /// ギャラリーの場面（make render-all が描く 1 枚）を組む関数を、始まりとして繋ぐ。name は場面の名前（gallery/<名前>.png と同じ字）で、
    /// 引くときは `shot:<名前>`（START・flow の start・POST /start・`SHOT=<名前> make run`）。描き出しと実機が同じ関数で World を組むので、
    /// 実機で開いた場面はギャラリーの絵と同じ World から始まる（実機の起動では F8 で止めた状態で窓が開く）。
    /// 実機の START で引けるのは DEBUG の起動だけ（配る版の起動で場面の作り物を開かない）。画面なしの道（flow・テスト）はいつも引ける。
    /// withStarts の一覧（GET /starts・起動の既定の先頭）には混ぜない。build は withStarts と同じく純粋に書く
    /// （新しく作った初期の World を受けるが、ギャラリーと同じ World にするには、描き出しと同じ初めの World から組む）。
    pub def withShots(shots: List[Start[w]], app: App[w, ef]): App[w, ef] =
        App.App({ shots = shots | rec(app) })

    /// ギャラリーの場面の始まりの名前（`shot:<場面>`）。
    pub def shotStartName(scene: String): String = "${shotPrefix()}${scene}"

    /// 始まりの名前がギャラリーの場面（`shot:` で始まる）か。
    pub def isShotName(name: String): Bool = String.startsWith(prefix = shotPrefix(), name)

    def shotPrefix(): String = "shot:"

    /// withShots で繋いだ場面の名前（登録順・shot: を付けない字）。
    pub def shotNames(app: App[w, ef]): List[String] =
        rec(app)#shots |> List.map(shot -> shot#name)

    /// 名前の始まり（shot: で始まればギャラリーの場面）。無ければ、近い名前の案つきの理由。
    def findStart(app: App[w, ef], name: String): Result[String, Start[w]] =
        let r = rec(app);
        if (isShotName(name)) {
            let scene = String.dropLeft(String.length(shotPrefix()), name);
            r#shots |> List.find(shot -> shot#name == scene)
                |> Option.toOk("ギャラリーの場面 '${scene}' は App.withShots に無い${Suggest.hint(scene, shotNames(app))}")
        } else
            r#starts |> List.find(start -> start#name == name)
                |> Option.toOk("始まり '${name}' は登録簿に無い${Suggest.hint(name, startNames(app))}")

    /// 新しく作った初期の World: init（design 解像度から）+ 起動時の系 + Doc を全部読み直した物
    /// （F1 の reloadOn の関数 = DocTable.reloadAll、無ければ監視の関数を登録順に）。
    /// 読み直すのは、main が起動の時に読んだ Doc ではなく今のファイルで場面を組むため（/start・記録の再生）。
    pub def freshWorld(app: App[w, ef], design: Vec2.Vec2): w \ ef + Fs.FileRead =
        let r = rec(app);
        let started = initialWorld(app, design);
        match r#reload {
            case Some((_, reloadAll)) => reloadAll(started)
            case None => List.foldLeft((acc, entry) -> { let (_, f) = entry; f(acc) }, started, r#watch)
        }

    /// 登録簿の名前の列（登録順）。
    pub def startNames(app: App[w, ef]): List[String] =
        rec(app)#starts |> List.map(start -> start#name)

    /// 名前の始まりを、新しく作った初期の World から組む。args は既定の引数を上書きし、値が `@パス` の
    /// 引数はそのファイルの中身にする（無いファイルの引数は外す）。知らない名前・組めない引数は理由つきの Err。
    pub def buildStart(app: App[w, ef], design: Vec2.Vec2, name: String, args: Map[String, String]): Result[String, w] \ ef + Fs.FileRead =
        match findStart(app, name) {
            case Err(why)    => Err(why)
            case Ok(start)   => buildStartFrom(start, freshWorld(app, design), name, args)
        }

    /// init（design 解像度から）+ 起動時の系。Doc は読み直さない。
    def initialWorld(app: App[w, ef], design: Vec2.Vec2): w \ ef =
        let r = rec(app);
        let init = r#init;
        List.foldLeft((acc, sys) -> sys(acc), init(design), r#startupSystems)

    /// buildStart の、初期の World を渡す形（窓なしのゲームが Doc の読み直しを取り置いた World から組む）。
    /// fresh は freshWorld(app, design) か、同じ Doc で組んだ init + 起動時の系であること。
    pub def buildStartOn(app: App[w, ef], fresh: w, name: String, args: Map[String, String]): Result[String, w] \ Fs.FileRead =
        findStart(app, name) |> Result.flatMap(start -> buildStartFrom(start, fresh, name, args))

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

    /// World 全体の要約（遊んだ記録の最後の `expect world=`・決定性の門）を取る前に、World を f で写す。
    /// App を組む時にだけ読む外の値（起動した時のその土地の時刻など）は記録に残らず、画面なしの再生は別の値で組むので、
    /// その欄だけを決まった値へ置き換える。進行に効く欄は置き換えない（置き換えた欄の食い違いは門が拾わなくなる）。
    pub def withWorldSummaryMask(f: w -> w, app: App[w, ef]): App[w, ef] =
        App.App({ summaryMask = f | rec(app) })

    /// World 全体の要約を取る World（withWorldSummaryMask で写した物）。
    pub def summaryWorldOf(app: App[w, ef], world: w): w =
        let mask = rec(app)#summaryMask;
        mask(world)

    /// addClock で宣言した時計を、実時間 dt で 1 回ずつ進める（advanceFrame が系の前に呼ぶ）。
    /// ゲームのコードからは呼ばない（2 回進めると 1 回目の区間の音が消える。lint-forbid の clock-advance）。
    /// テストで系を直に呼ぶときだけ、実機と同じ順（tickClocks → 系）を組むのに使う。
    pub def tickClocks(app: App[w, ef], dt: Float64, world: w): w =
        List.foldLeft((acc, tick) -> tick(dt, acc), world, rec(app)#clocks)

    // ── 純粋な芯（テストはここを直接叩く）──

    /// 左ボタンだけの集合（押していなければ空）。frameOf が mouseDown・mouseClicked から mouseButtons・mouseClickedButtons を組む。
    def leftOnly(on: Bool): Set[GameEngine.MouseButton] =
        if (on) Set#{GameEngine.MouseButton.Left} else Set.empty()

    /// 前フレームと今フレームのキー集合から Frame を組む。justPressed は差分
    /// （今あって前に無いキー）なので、押しっぱなしはエッジにならない。
    /// マウスも同じ考え方: mouseClicked は「今押されていて前は押されていない」エッジ、
    /// mouseMoved は前フレームとの座標比較（最初のフレームは prevCursor = None で false）。
    /// wheel はバックエンドが貯めた 1 フレームぶんの量を素通しする。
    /// mouseButtons・mouseClickedButtons は左だけで組む（右と中も読むなら withMouseButtons で置き直す）。
    /// mouseDelta は前フレームとの座標の差（最初のフレームは 0。実機のループはキャプチャしても出るバックエンドの量で置き直す）。
    /// realNow は 0 秒で組み、advanceFrame が StepState の実時間の時計で置き直す。
    /// windowFocused は真・sizeClass は Large・diagnostics は None で組む（実機のループが置き直す）。
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
          mouseButtons = leftOnly(mouse#down),
          mouseClickedButtons = leftOnly(mouse#down and not mouse#prevDown),
          mouseMoved = Option.exists(p -> p#x != cursor#cursor#x or p#y != cursor#cursor#y, cursor#prevCursor),
          wheel = mouse#wheel,
          realNow = Clock.zero(),
          padTouched = false,
          padKind = GamepadMap.PadKind.Unknown,
          mouseDelta = App.Internal.Frame.cursorDelta(cursor#prevCursor, cursor#cursor),
          windowFocused = true,
          sizeClass = Display.SizeClass.Large,
          diagnostics = None }

    /// 何も押していない・動いていない・dt 0 のフレーム（全部の欄が既定の値。viewport と cursor は (0, 0)）。
    /// テストや台本で Frame を組む時は、字で全部の欄を書かず `{ down = Set#{Key.Space}, dt = 0.016 | App.emptyFrame() }` の形で替える
    /// （Frame に欄が増えても止まらない。押した瞬間を作るなら justPressed も、前のフレームとの差から作るなら frameOf）。
    pub def emptyFrame(): Frame =
        frameOf(prev = Set.empty(), current = Set.empty(), 0.0, Vec2.zero(),
                { prevCursor = None, cursor = Vec2.zero() }, { prevDown = false, down = false, wheel = 0.0 })

    /// 押しているボタンの丸ごと（左・右・中）を置く: mouseButtons = held・mouseClickedButtons = 前のフレームに無く今あるボタン。
    /// mouseDown・mouseClicked は左の分に合わせて置き直す（どちらで読んでも食い違わない）。
    pub def withMouseButtons(prev: Set[GameEngine.MouseButton], held: Set[GameEngine.MouseButton], frame: Frame): Frame =
        let clicked = Set.difference(held, prev);
        { mouseButtons = held, mouseClickedButtons = clicked,
          mouseDown = Set.memberOf(GameEngine.MouseButton.Left, held),
          mouseClicked = Set.memberOf(GameEngine.MouseButton.Left, clicked) | frame }

    /// 0 サブステップのフレームで捨てられそうになったエッジのバッファ。エッジは prev との
    /// 差分なので、同じ押下は次の実フレームでは二度と立たない — 消費されるまでここに
    /// 残し、最初のサブステップが来た瞬間に合流させる（fixedDt がフレーム間隔より
    /// 長い構成でも入力を取り逃さないためのバッファ）。
    pub type alias PendingEdges = {
        justPressed = Set[GameEngine.Key],
        mouseClicked = Bool,
        mouseClickedButtons = Set[GameEngine.MouseButton],
        mouseMoved = Bool,
        wheel = Float64,
        mouseDelta = Vec2.Vec2
    }

    /// withFixedStep がフレームをまたいで持ち回す状態（持ち越し秒 + 未消費エッジ）。
    /// 可変 dt（fixedStep = None）のゲームでは常に初期値のまま動かない。
    /// real は実時間の時計（advanceFrame が毎フレーム進め、Frame#realNow に置く）。
    pub type alias StepState = { carry = Float64, pending = PendingEdges, real = Clock.Clock[Clock.Real] }

    /// 起動直後の StepState（貯金ゼロ・未消費エッジなし）。
    pub def freshStepState(): StepState =
        { carry = 0.0, pending = App.Internal.Frame.noPending(), real = Clock.start() }

    /// 1 実フレームぶんの updateSystems 適用。fixedStep 未指定なら現行どおり frame を 1 回
    /// そのまま流すだけ（挙動不変・pending も動かない）。指定していれば fixedSteps で回数を
    /// 決め、取り置いたエッジを合流した Frame（dt は固定値）で 0〜5 回サブステップする
    /// （2 回目以降は suppressEdges でエッジを消す）。
    /// 0 回のフレームは World をそのまま返し、合流済みエッジを次フレームへ取り置く —
    /// そうしないと prev 差分ゆえ二度と立たないエッジがそのまま失われる。
    /// 系より先に、実時間の時計（Frame#realNow に置く）と addClock の時計を実時間の dt で 1 回進める
    /// （刻みが 0 回のフレームも進む —— 止めていないのに時計が止まると、次のフレームで区間が飛ぶ）。
    pub def advanceFrame(app: App[w, ef], frame: Frame, state: StepState, world: w): (w, StepState) \ ef =
        let r = rec(app);
        let real = Clock.advance(Clock.paceOf(Clock.Run.Running), frame#dt, state#real);
        let stamped = { realNow = Clock.nowOf(real) | frame };
        let ticked = tickClocks(app, frame#dt, world);
        match r#fixedStep {
            case None => (App.Internal.Frame.applySystems(stamped, r#updateSystems, ticked), { real = real | state })
            case Some(fixedDt) =>
                let (steps, nextCarry) = App.Internal.Frame.fixedSteps(state#carry, frame#dt, fixedDt);
                let merged = App.Internal.Frame.mergeEdges(state#pending, stamped);
                if (steps == 0)
                    (ticked, { carry = nextCarry, pending = App.Internal.Frame.pendingOf(merged), real = real })
                else {
                    let firstFrame = { dt = fixedDt | merged };
                    let laterFrame = App.Internal.Frame.suppressEdges(firstFrame);
                    let advanced = List.range(0, steps) |> List.foldLeft((acc, i) -> {
                        let subFrame = if (i == 0) firstFrame else laterFrame;
                        App.Internal.Frame.applySystems(subFrame, r#updateSystems, acc)
                    }, ticked);
                    (advanced, { carry = nextCarry, pending = App.Internal.Frame.noPending(), real = real })
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
        let r = rec(app);
        let derive = r#audio;
        let declare = r#sustained;
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

    // ── 1 コマの絵の組み立てと、F8 で止めた画面の履歴 ──

    // WhyNot: sceneItems・resumePoint・worldAt を子（App.Internal.*）へ移さない — 子に置くと兄弟の子と App.RemoteDebug から使うのに
    //   pub が要り、ゲームから引ける。親に非 pub で置けば子からだけ引けて、外の mod からは E0237 で止まる。

    /// 確定した camera（中心と zoom）を World から 1 回だけ導く: zoom-only の正規化
    /// （zoomedCenter）→ cameraBounds クランプ。主 view と静的レイヤーがこの同じ値から
    /// 派生するので、動的な絵と静的な絵の視点が必ず一致する（1px もずれない）。
    def resolvedCamera(r: Rec[w, ef], world: w, design: Vec2.Vec2): (Option[Vec2.Vec2], Float64) \ ef =
        let z = match r#zoom {
            case None    => 1.0
            case Some(f) => f(world)
        };
        let center0 = match r#camera {
            case Some(f) => Some(f(world))
            case None    => None
        };
        let center = match (zoomedCenter(center0, z, design), r#cameraBounds) {
            case (Some(c), Some(fb)) =>
                let seen = Vec2.div(design, CameraRig.safeZoom(z));
                Some(CameraRig.clampCenter(bounds = fb(world), seen = seen, c))
            case (c, _) => c
        };
        // 画素の升目に吸着させる（静的な絵と動く絵が同じ値を見るので、両者はずれない）。
        let snap = (r#pixelSnap)(world);
        // 画面の画素に載せたいので、zoom を掛けた後の値で丸める（world 座標で丸めるだけでは
        // zoom が整数でないときに半画素ずれが残る）。
        let unit = snap * CameraRig.safeZoom(z);
        let snapped = if (not Float64.isFinite(unit) or unit <= 0.0) center
                      else Option.map(c -> { x = Float64.round(c#x * CameraRig.safeZoom(z)) / CameraRig.safeZoom(z),
                                             y = Float64.round(c#y * CameraRig.safeZoom(z)) / CameraRig.safeZoom(z) }, center);
        (snapped, z)

    /// ViewCtx を 1 つ受けて、view・hudView・視差レイヤの絵に camera を掛けて 1 コマぶん並べる（窓なしで呼べる）。
    /// base の visible は層ごとに見えている矩形へ置き換わり、ほかの欄（字・知らせ・診断）はどの層にも同じ値で渡る。
    pub def buildSceneItems(app: App[w, ef], design: Vec2.Vec2, base: ViewCtx, world: w,
                            toItems: (ViewCtx, w) -> List[Render.PlacedItem] \ ef): List[Render.PlacedItem] \ ef =
        let r = rec(app);
        let (center, z) = resolvedCamera(r, world, design);
        let hud = match r#hudView {
            case None    => Nil
            // HUD は画面固定なので、見えている矩形は常に design 全体（原点起点）で zoom も掛けない。
            case Some(h) => h({ visible = visibleOf(None, 1.0, design) | base }, world)
        };
        // 視差レイヤ: 見かけの center（parallaxCenter）で culling も合成も行う。hud は混ぜない。
        let layers = r#parallaxLayers |> List.flatMap(fl -> {
            let (factor, lview) = fl;
            let lcenter = Option.map(c -> CameraRig.parallaxCenter(factor, c, design = design), center);
            composeScene(lcenter, z, design, { world = lview({ visible = visibleOf(lcenter, z, design) | base }, world), hud = Nil })
        });
        let ctx = { visible = visibleOf(center, z, design) | base };
        List.append(layers, composeScene(center, z, design, { world = toItems(ctx, world), hud = hud }))

    /// 一時停止を抜ける地点: スクラブで表示していた瞬間の World を現在とし、
    /// 履歴とフレーム番号もそこを基準に数え直す（未来側の履歴は捨てる）。
    def resumePoint(anno: Annotate.State, history: List[w], world: w): { world = w, anno = Annotate.State, history = List[w] } =
        { world = worldAt(history, anno#scrub, world),
          history = List.drop(anno#scrub, history),
          anno = { frame = anno#frame - Int32.toInt64(anno#scrub) | Annotate.resetView(anno) } }

    /// 履歴の back フレーム前の World（範囲外なら fallback）。先頭が「停止した瞬間」。
    def worldAt(history: List[w], back: Int32, fallback: w): w =
        history |> List.drop(back) |> List.head |> Option.getWithDefault(fallback)

    /// 時間スクラブ用に持ち回す直近の World の数（60fps で約 30 秒）。
    /// World は不変値なので、保持しているのは共有構造への参照だけで軽い。
    /// flow の実行器も同じ数だけ持つ（rewind が F8 と同じ所まで戻れるように）。
    pub def historyLimit(): Int32 = 1800

    // ── ランナー: 起動して、閉じるまで回す ──

    // 開発の道具の組の中身: App を受けて、ループが呼ぶフックの組を作る関数。
    // WhyNot: 道具の組を record のまま pub にしない — 外で組めると、道具のフックを直に書いたゲームが App の中の型に縛られる。
    enum DevToolsFactory[w: Type, efTools: Eff](App[w, {}] -> App.Internal.DevTools.Hooks[w, {}, efTools])

    /// 開発の道具（リモートデバッグの命令口・ゲームの名簿・flow の記録・ヒッチの見張り・Doc の保存検知・F8 の注釈の書き出し・
    /// 環境変数の表）の組。App.DevTools.none()（道具なし）か App.DevTools.desktop(env)（デスクトップの道具）で作り、
    /// launchWithDevTools へ渡す。efTools は道具が加える機種の effect（デスクトップは Platform.Annotation・道具なしは {}）。
    pub type alias DevTools[w: Type, efTools: Eff] = DevToolsFactory[w, efTools]

    /// デスクトップの道具の組。captured = App を組む間に読んだファイルの中身（flow の記録の start の行に載せる。控えていなければ None）。
    def desktopTools(env: Map[String, String], captured: Option[Map[String, Flow.File]]): DevTools[w, Platform.Annotation] =
        DevToolsFactory.DevToolsFactory(app -> App.Internal.DevTools.desktopOf(env, captured, app))

    /// App を実機で走らせる。startup を 1 回だけ畳み込み、いま押されているキーを prev の
    /// 種にしてループへ入る（起動時にすでに押されているキーは、一度離すまでエッジにならない）。
    ///
    /// 受けるのは系と View が純粋な App（App[w, {}]）だけ。系が外の世界に触れないことを型で守る
    /// （ゲームの src の unsafe と、effect を消す unchecked_cast は lint-forbid が止める）。
    /// effect を持つ App は画面なしの道（App.trace・App.traceFrame・flow）とテストで流す。
    /// 機種の effect（Platform.Services と Platform.Annotation）と Fs は Main が `with` で明示的に張る。
    /// 開発の道具はデスクトップの組（App.DevTools.desktop）: デバッグ有効（withDebug）かつ環境変数 DEBUG_HTTP_PORT があれば、
    /// リモートデバッグの HTTP エンドポイントも一緒に立ち上がる（例: `DEBUG=1 DEBUG_HTTP_PORT=7777 flix run`）。
    /// 組み終えた App を渡すこの形では、flow を記録する起動は Doc を読み直して start の行に載せる（App.loadAndLaunch は読み直さない）。
    pub def launch(app: App[w, {}]): Unit \ (Platform.Services + Platform.Annotation + Fs.FileRead + Fs.FileWrite + IO) =
        launchWithDevTools(App.DevTools.desktop(ProcessEnv.snapshot()), app)

    /// loadApp で App を組んで launch する。flow を記録する起動では、loadApp が Fs.FileRead で読んだ中身を start の行に載せ、
    /// Doc を読み直さない。loadApp の中の効果（LoadProgress など）は、外の handler が受ける。組んだ App は launch と同じく純粋な物だけ。
    pub def loadAndLaunch(loadApp: Unit -> App[w, {}] \ ef2): Unit \ (ef2 + Platform.Services + Platform.Annotation + Fs.FileRead + Fs.FileWrite + IO) =
        let env = ProcessEnv.snapshot();
        // WhyNot: 記録しないと env で分かる起動で中身を控えない — 3D の形などの大きな字を、起動の World が決まるまで抱えることになる。
        if (not debugOf(env) or Option.isEmpty(Flow.Record.pathOf(env))) launchWithDevTools(App.DevTools.desktop(env), loadApp())
        else {
            let (app, read) = Flow.Record.captureReads(loadApp);
            launchWithDevTools(desktopTools(env, Some(read)), app)
        }

    /// 開発の道具の組を選んで App を実機で走らせる（launch はデスクトップの道具の組でこれを呼ぶ）。
    /// 道具を持たない起動（ブラウザ版の入口など）は `App.launchWithDevTools(App.DevTools.none(), app)` と書く:
    /// 命令口・記録・名簿・ヒッチの見張り・保存検知・F8 の注釈の書き出しのコードへ呼び出しが届かず、Platform.Annotation も要らない。
    /// 道具なしでは環境変数を読まないので、START も効かない（いつも先頭の始まりから）。F8 で止めて囲んでも注釈は書き出さない。
    /// 道具なしの入口では App.debugFromEnv も呼ばない（環境変数を読む JVM の API（System.getenv）が残る）。withDebug は値で渡す。
    pub def launchWithDevTools(tools: DevTools[w, efTools], app: App[w, {}]): Unit \ (efTools + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        let DevToolsFactory.DevToolsFactory(attach) = tools;
        App.Internal.Runner.runLoop(app, attach(app))

    /// 系の中で IO を測る bench のための launch（effect を持つ App も受ける）。開発の道具は持たない。ゲームからは呼ばない
    /// （ゲームの src で書くと lint-forbid の launch-for-bench が止める）。
    // WhyNot: launch を効果多相に戻さない — 実機の入口が effect を持つ App を受けると、系が IO に触らないことを型で言えなくなる。
    pub def launchForBench(app: App[w, ef]): Unit \ (ef + Platform.Services + Fs.FileRead + Fs.FileWrite + IO) =
        App.Internal.Runner.runLoop(app, App.Internal.DevTools.none())

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
            case Render.Item.Scene3d(s) => Render.Item.Scene3d({ zIndex = f(s#zIndex) | s })
            case Render.Item.Clipped(c) => Render.Item.Clipped({ inner = zMapped(f, c#inner) | c })
        }
}
