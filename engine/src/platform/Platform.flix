// Platform — 機種（ウィンドウ・入力・GPU・時計）に触る effect を役割ごとに分けて置く所。2D と 3D で共通。
//
// WhyNot 1 つの大きな effect に戻さない: op を 1 つ足すと、その effect を張る全部の handler
// （実機・オフスクリーン・テストの偽物）が止まる。役割ごとに分ければ止まるのはその役割の handler だけで、
// 関数の型にも「何に触るか」がそのまま出る。
//
// Input は PropertyTest.Input（enum）と名前が重なるので、外からは必ず Platform.Input と mod 名を付けて書く。
//
// 積む op と出す op: Draw2d.drawSurface と Draw3d.drawScene3d は描かずに列へ積むだけで、
// 次の Draw2d.renderCommands が z の順で合流させて出す。だから Draw2d・Draw3d・GpuResources は
// 同じ handler の組から張る（違う組の物を混ぜると、積んだ物が出ない）。Input と Window も
// マウスの押したフラグを分け合うので同じ組から張る。

pub mod Platform {

    /// キー・マウス・ゲームパッドの今の状態を読む。
    pub eff Input {
        def isKeyPressed(key: GameEngine.Key): Bool
        def getMousePosition(): Vec2.Vec2
        def isMouseButtonPressed(button: GameEngine.MouseButton): Bool
        /// 1 台目のゲームパッドのボタン・十字キー・スティックのどれかがいま押されて（倒されて）いるか。
        /// パッドの入力はキーへ読み替えて isKeyPressed にも出るので、読み替えた後のキーからは
        /// キーボードと見分けられない —— 案内の絵をパッドのボタンへ替える判断はここを読む（App が Frame#padTouched に置く）。
        def isGamepadTouched(): Bool
        /// 1 台目のゲームパッドの機種（Xbox 配置の一般・Steam Input を通した物・つないでいない）。
        /// App が Frame#padKind に置く。
        def gamepadKind(): GamepadMap.PadKind
        /// 前回呼び出し以降に蓄積されたマウスホイールの y 方向 delta を返し、
        /// 内部アキュムレータを 0 にリセットする。1 ティックぶんの値が +1.0 / -1.0 程度
        /// （プラットフォーム依存）。スクロールアップで正、ダウンで負。
        def consumeScrollDelta(): Float64
        /// 前に呼んでからマウスが動いた量（design px・小数のまま。右と下が正）。キャプチャしている間（Window.setMouseCaptured(true)）も
        /// ウィンドウの端で止まらずに出る。キャプチャを切り替えた直後と、ウィンドウがフォーカスを取り戻した直後の 1 回は 0（跳んだ量を入れない）。
        /// ウィンドウにフォーカスが無い間も 0（ほかのアプリの上の動きで視点を回さない）。
        /// App が毎フレーム読み切って Frame#mouseDelta に置くので、ゲームは直接呼ばない。
        def consumeMouseDelta(): Vec2.Vec2
        /// ウィンドウがキーとマウスの入力を受け取る状態（フォーカスがある）か。App が Frame#windowFocused に置く。
        def isWindowFocused(): Bool
    }

    /// ウィンドウの状態と見た目（閉じるフラグ・大きさ・カーソル・全画面・タイトルの表示）。
    pub eff Window {
        /// OS からのイベント（キー・マウス・ホイール・窓の大きさ・閉じるボタン）とゲームパッドの状態を取り込む。1 フレームに 1 回だけ呼ぶ
        /// （入力を読む前でも後でもよい。App はそのコマの入力を読んだ後に呼ぶ）。
        /// マウスの「このコマで押された」フラグ（Input.isMouseButtonPressed が 1 コマだけ真で返す短い押し）もここで新しいコマへ切り替わる。
        def pollEvents(): Unit
        /// ウィンドウの閉じるフラグが立っているか（問うだけ。イベントは pollEvents が取り込む）。
        def shouldClose(): Bool
        /// ウィンドウの閉じるフラグを立てる・下ろす（GLFW の glfwSetWindowShouldClose）。false で閉じる要求を取り消す
        /// （App.withCloseRequest が「終了しますか？」を出す間、ウィンドウを開けておくのに使う）。
        def setShouldClose(close: Bool): Unit
        /// design 座標の描き場の矩形。
        def getViewportRect(): Rect2.Rect2
        /// 今の画面の情報（大きさ・画素の細かさ・最後の pointer の種類・端末の区分）。App が毎コマ読んで
        /// ViewCtx#display（全部）と Frame#sizeClass（区分だけ）に置く。デスクトップは区分 Large・pointer Mouse。
        def getDisplay(): Display.Display
        /// マウスカーソル形状を切り替える。連続して同じ Cursor を渡しても問題ない（冪等）
        def setCursor(cursor: GameEngine.Cursor): Unit
        /// マウスカーソルの表示/非表示を切り替える。形状(setCursor)は「どんな絵か」、
        /// これは「絵を出すか出さないか」で役割が別。連続して同じ値を渡しても問題ない（冪等）
        def setCursorVisible(visible: Bool): Unit
        /// マウスをウィンドウにキャプチャする（真）・放す（偽）。キャプチャしている間は矢印が消え、動きは Input.consumeMouseDelta だけに出る
        /// （GLFW の GLFW_CURSOR_DISABLED。使えれば raw の動きも入れる）。放すと矢印は setCursorVisible の宣言どおりに戻り、
        /// 位置はキャプチャする前の所に戻る（GLFW の決まり）。フォーカスが外れると OS が放し、戻るとキャプチャし直す。同じ値を続けて渡してよい（冪等）。
        /// ゲームからは呼ばず、App.withMouseCapture で World から宣言する。
        def setMouseCaptured(captured: Bool): Unit
        /// ウィンドウ⇄ボーダーレスフルスクリーンを切り替える。フルスクリーンはプライマリ
        /// モニタの現在の解像度を使う（解像度そのものは変えない）。連続して同じ値を渡しても
        /// 問題ない（冪等）。ゲームからは呼ばず、App.withFullscreen で World から宣言する
        def setFullscreen(on: Bool): Unit
        /// 直近の setFullscreen で今フルスクリーン中かを返す
        def isFullscreen(): Bool
        /// Draw2d.renderCommands で塗ったコマを画面へ出す（バッファの入れ替え）。1 フレームの終わりに 1 回だけ呼ぶ。
        /// 画面へ塗ったコマが無ければ（レンダーターゲットへ塗っただけ・窓の無い描き手）何もしない。レンダーターゲットを閉じてから呼ぶ。
        def presentFrame(): Unit
        /// デバッグモード中であることをウィンドウタイトルで示す。
        /// true でタイトル末尾に「 (Debug)」を付け、false で元のタイトルへ戻す。
        def setDebugBadge(enabled: Bool): Unit
    }

    /// 1 コマの経過時間。WhyNot Time と呼ばない: engine_world の Clock.Time と重なる。
    pub eff FrameClock {
        /// 前フレームからの経過時間。EngineConfig#maxDeltaTime で上限クランプ済み。
        /// App のループは 1 周に 1 回だけ、その周の入力を読む前に呼ぶ（呼んだ数でコマを数える handler がある: 入力の台本 FLIX_GE_INPUT_SCRIPT）。
        def getDeltaTime(): Duration.Duration
    }

    /// 2D の描き物の列を出す口。
    pub eff Draw2d {
        /// zIndex 混合で sprites・tileMaps・polygons を 1 フレーム描画する（積んだ面と 3D の場面も z の位置で合流させる）。
        /// 画面へは出さない（出すのは Window.presentFrame）。レンダーターゲットが開いていればそこへ描く。
        /// staticLayer は「1 度だけ GPU へ生成して使い回す静的多角形」の依頼（無ければ None）。
        /// エンジンがキーでキャッシュし、動的な polygons と同じ z 安定ソート列にレンジを混ぜて
        /// 描くので重なり順は壊れない。ゲームは GL ハンドルを触らずキーと中身を宣言するだけ。
        def renderCommands(sprites: List[GameEngine.Drawable], tileMaps: List[GameEngine.TileMapRenderCmd],
                           polygons: List[GameEngine.PolygonRenderCmd],
                           staticLayer: Option[GameEngine.StaticLayerCmd]): Unit
        /// 宣言シェーダーの面 1 枚を、次の renderCommands の列へ積む。
        def drawSurface(cmd: DrawCmd.SurfaceRenderCmd): Unit
    }

    /// 3D の場面を出す口。
    pub eff Draw3d {
        /// 3D の場面 1 つを、次の Draw2d.renderCommands の列へ積む（深度で前後を決め、2D の並びの中では cmd#scene#zIndex の 1 点に入る）。
        def drawScene3d(cmd: Scene3d.RenderCmd): Unit
    }

    /// 3D を描かない handler の組（ブラウザ版・テストの偽物）が張る、3D の場面を捨てる handler。
    pub def runNoopDraw3d(f: Unit -> a \ ef): a \ ef - Draw3d =
        run f() with handler Draw3d {
            def drawScene3d(_cmd, k) = k(())
        }

    /// GPU に置く資源（タイルのバッファ・テクスチャ・字・シェーダーのプログラム）を用意し、寸法を引く。
    pub eff GpuResources {
        /// タイルインスタンスデータを GPU VBO にアップロードし (vaoハンドル, count) を返す
        def initTileBuffer(instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32)
        /// 既存のタイル VAO のインスタンス VBO へ中身を入れ直す（VAO は増やさない）。
        /// key の変わりやすい層（照明・カメラ追随で生成し直す地形など）が、生成し直しの
        /// たびに initTileBuffer で VAO を積み増して GPU メモリを漏らさないための関数。
        /// 未知の VAO（理論上来ない）は新規に生成して返す — 返った vaoハンドルを保存し直すこと。
        def updateTileBuffer(vaoId: GpuHandle.TileVao,
                             instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32)
        /// 実行時に生成した画素を、名前付きテクスチャとして使えるようにする。
        /// key はその画素の中身を決める全入力を 1 文字列にまとめた物（テーマ名・世代番号など）。
        /// 同じ名前で key が前回と同じなら、描画部は何もしない（毎フレーム呼んでよい）。
        /// argb は width×height の行優先（PxSpriteAtlas.bake の出力そのまま）。
        def ensureTexture(name: String, key: String, width: Int32, height: Int32,
                          argb: Vector[Int32]): Unit
        /// アトラスにまだ無い字を、いま生成してアトラスに足す。
        /// textureName は FontAtlas#textureName（どのフォントかの目印）。
        /// 実行中に計算で作った字やプレイヤーが入れた名前を、消さずにここで追加生成する。
        /// 初めて出る字は 1 コマ遅れて現れる。呼ぶ側は毎フレーム「足りない字」を渡してよい（足りていなければ何もしない）。
        def ensureGlyphs(textureName: String, codepoints: Set[Int32]): Unit
        def getFontAtlas(name: String): FontAtlas
        /// 指定したテクスチャ名の元画像サイズ等を取得する。
        /// 登録されていないテクスチャ名なら None
        def getTextureInfo(name: String): Option[GameEngine.TextureInfo]
        /// Spec を GLSL プログラムへコンパイルしハンドルを返す（起動時/リロード時に 1 回）。
        /// 失敗時は bug! でなく単色フォールバックプログラムを返す（fail-open）— theme 由来の
        /// codegen ミスで全体がクラッシュしないように。
        def buildProgram(spec: ShaderDoc.Spec): GpuHandle.ShaderProgram
    }

    /// 1 コマごとの、描く側の診断（FrameDiagnostics）。
    pub eff Diagnostics {
        /// 集めるかを切り替える。切っている間は数えない。入れるのは DEBUG の起動だけ（本番で数える負担を作らない）。
        def setDiagnosticsEnabled(on: Bool): Unit
        /// 前に取り出してから溜まった診断を返し、空に戻す（Input.consumeScrollDelta と同じ取り出し方）。
        /// 集めていない間は FrameDiagnostics.empty()。
        def consumeDiagnostics(): FrameDiagnostics.Diagnostics
    }

    /// F8 の注釈を書き出す開発の道具。WhyNot Services に入れない: 開発の道具の入口へ寄せて、持たない handler の組
    /// （ブラウザ版など）でも App を走らせられるようにする。
    pub eff Annotation {
        /// 注釈一式（screenshot.png / highlighted.png / annotation.json / README.md）を
        /// debug/annotations/ 配下の新しいディレクトリへ書き出し、そのパスを返す。失敗時 None。
        /// 保存に成功するとシャッター風の効果音を鳴らす。
        /// screenshot.png は直前に画面へ塗ったコマ — 呼ぶ前に等倍のコマを塗っておく（App の pausedStep）。
        def saveAnnotation(req: GameEngine.AnnotationRequest): Option[String]
    }

    /// 描く effect の束（同じ handler の組から張る 3 つ。上の「積む op と出す op」）。
    pub type alias Rendering = Draw2d + Draw3d + GpuResources

    /// App.launch が要る機種の effect の束。
    pub type alias Services = Input + Window + FrameClock + Rendering + RenderTarget.Target + GameEngine.Audio + Diagnostics
}
