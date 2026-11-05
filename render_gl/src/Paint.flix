// RenderPaint — 塗りのコア。GL の資源（シェーダー・VAO・入れ物）と、テクスチャ・シェーダー・
// レンダーターゲット・静的レイヤーの登録簿を 1 つの状態（Paint）にまとめ、1 コマ塗る関数（submitFrame）を出す。
// 窓ありで遊ぶ時（LwjglLayer.withLwjgl）も、窓を見せずに動画を塗る時（GlOffscreen）も、同じ関数で塗る。
// 状態は GL の文脈ごとに 1 つ。窓・入力・音・swap は呼ぶ側が持ち、ここは「今 bind されている
// フレームバッファへ、渡された命令を塗る」ことだけを受け持つ。
// 呼べるのは GL の文脈が今の糸に付いている間だけ（create もそう）。
//
// 1 コマの流れ（呼ぶ側）: queueSurface（シェーダー面を溜める）→ submitFrame（溜めた面と命令を塗る。
// レンダーターゲットが開いていればそこへ）→ 画面なら swap（窓）か読み戻し（GlOffscreen）。
mod RenderPaint {
    import fge.gl.GlContext
    import fge.gl.GlConst
    import java.lang.System

    /// 1 コマの描く命令（画面へのコマ。リサイズで描き直す時・注釈のスクショも同じ物を使う）。
    pub type alias Frame = {
        sprites = List[GameEngine.Drawable],
        tileMaps = List[GameEngine.TileMapRenderCmd],
        polygons = List[GameEngine.PolygonRenderCmd],
        staticLayer = Option[GameEngine.StaticLayerCmd],
        surfaces = List[DrawCmd.SurfaceRenderCmd],
        scenes = List[Scene3d.RenderCmd]
    }

    /// 塗りのコアの状態。作るのは create だけ。
    /// screenW・screenH = design の寸（シェーダーの投影行列もこの寸）。
    /// frameArgsBase = RenderFrame.renderFrameMixed へ毎コマ渡す引数のうち、変わらない所（シェーダー・VAO・入れ物・面を描く閉包）。
    /// ほかは、毎コマ育つ・入れ替わる登録簿と控え（各フィールドのコメント）。
    pub type alias Paint = {
        screenW = Float64,
        screenH = Float64,
        // 画面のフレームバッファ（窓なら既定の 0、GlOffscreen なら動画のコマの FBO）。レンダーターゲットを閉じたらここへ戻す。
        screenFramebuffer = Int32,
        frameArgsBase = RenderFrame.FrameArgs,
        // タイル VAO を作る時に共有する四角の VBO。
        quadVBO = Int32,
        // 組めなかった Spec が落ちる単色のプログラム（追い出さない）。
        fallbackShader = Int32,
        // タイル VAO → インスタンス VBO（updateTileBuffer が入れ直す先）。
        tileVboRegistry = Ref[Map[Int32, Int32], Static],
        // Spec の name → (組んだ時の Spec, プログラム + uniform location)。
        shaderProgramCache = Ref[Map[String, (ShaderDoc.Spec, RenderShaderCache.ProgramEntry)], Static],
        // 画面へ塗ったコマの通し番号（シェーダーの LRU のものさし）。
        frameGenHolder = Array[Int64, Static],
        // program 番号 → 最後に使った世代。
        programUsedAtRef = Ref[Map[Int32, Int64], Static],
        // このコマに溜まったシェーダー面（queueSurface が積み、submitFrame が取り出す。新しい順）。
        pendingShaderHolder = Array[List[DrawCmd.SurfaceRenderCmd], Static],
        // このコマに溜まった 3D の場面（queueScene3d が積み、submitFrame が取り出す。新しい順）。
        pendingScene3dHolder = Array[List[Scene3d.RenderCmd], Static],
        // 3D の場面の描き手（作る側が渡す）。
        scene3d = Scene3dRenderer.Renderer,
        // Pass の頭で unit 0 に貼っておく 1 × 1 の透明な黒。
        blankTexture = Int32,
        // program → (uRectPos, uRectSize, uTime, uAlpha, texLocs, paramLocs)。
        shaderUniformCache = Ref[Map[Int32, (Int32, Int32, Int32, Int32, List[(Int32, Int32)], List[Int32])], Static],
        // レンダーターゲットの名前 → GL 実体。
        targetsRef = Ref[Map[String, RenderTargetGl.Entry], Static],
        // 今開いているターゲットの宣言。None = 画面。
        activeTargetHolder = Array[Option[RenderTarget.TargetSpec], Static],
        // ターゲットの名前 → 前のコマの中身の写し（RenderTarget.historyName で読ませる。自分を読む Pass がある時だけ作る）。
        historyRef = Ref[Map[String, RenderTargetGl.Entry], Static],
        // Rgba16Float で作れず Rgba8Unorm で作り直したことを知らせたターゲットの名前（名前ごとに 1 回）。
        targetWarnedRef = Ref[Set[String], Static],
        // history に前のコマを写すか（窓で遊ぶ時）、毎回透明で塗るか（1 枚撮り・動画 — 描き出しと同じ「1 コマ目」）。
        keepHistory = Bool,
        // テクスチャの名前 → GL の実体（実行中に増える）。
        registryRef = Ref[RenderAsset.TextureRegistry, Static],
        // ensureTexture が上げた名前 → 最後の key（同じ key の上げ直しを弾く）。
        textureKeyRef = Ref[Map[String, String], Static],
        // 静的多角形バッファのキャッシュ（RenderStatic.resolve）。
        staticCacheCell = Array[Option[RenderStatic.Entry], Static],
        // 最後に画面へ塗ったコマの命令（リサイズの描き直し・LRU の pin・注釈のスクショ）。
        lastFrameHolder = Array[Frame, Static],
        // 1 コマぶんの診断（setDiagnosticsEnabled の間だけ Some。consumeDiagnostics が取り出す）。
        diagnosticsRef = Ref[Option[FrameDiagnostics.Diagnostics], Static],
        // 起動から作ったシェーダーと消したシェーダーの数（[作った, 消した]。診断の liveShaders の元）。
        shaderLifeHolder = Array[Int32, Static],
        // 同じ名前で作り直して鍵から外れた program（使われなくなったら evictShaderPrograms が消す）。
        retiredProgramsRef = Ref[Set[Int32], Static],
        // GPU の時間を測る口（診断を集めている間だけ使う。作る側が渡す）。
        gpuTimer = FrameTimer
    }

    /// GPU の時間を測る口。measure(name, f) = f の中の GL の仕事の時間を描き先 name の分として測る・
    /// endFrame() = 画面のコマの終わりに、結果の出た一番新しいコマの GPU の時間（無ければ None）。
    /// 3D の描き手と同じく作る側が渡す（測る GL の関数は GL 3.3 と WebGL2 で持ち方が違う）。
    pub type alias FrameTimer = {
        measure = (String, Unit -> Unit \ IO) -> Unit \ IO,
        endFrame = Unit -> Option[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ IO
    }

    /// 測らない口（f をそのまま呼び、時間は出さない）。
    pub def noFrameTimer(): FrameTimer =
        { measure = (_, f) -> f(), endFrame = () -> checked_ecast(None) }

    /// 空のコマ。
    pub def emptyFrame(): Frame =
        { sprites = Nil, tileMaps = Nil, polygons = Nil, staticLayer = None, surfaces = Nil, scenes = Nil }

    /// GL の資源を作り、空の登録簿で塗りのコアを始める。GL の文脈が今の糸に付いていること。
    /// design = 描く座標の寸（ゲームの designWidth × designHeight）、clearColor = design の中の地の色、
    /// screenFramebuffer = 画面のフレームバッファ（窓なら 0）。scene3d = 3D の場面の描き手（Scene3dRenderer.Renderer）。
    pub def create(gl: GlContext, cfg: { designWidth = Int32, designHeight = Int32, clearColor = Color, screenFramebuffer = Int32,
                          scene3d = Scene3dRenderer.Renderer, gpuTimer = FrameTimer }): Paint \ IO =
        let screenW = Int32.toFloat64(cfg#designWidth);
        let screenH = Int32.toFloat64(cfg#designHeight);

        let spriteShader = RenderShader.createShaderProgram(gl, 
            RenderShader.vertexShaderSource(),
            RenderShader.fragmentShaderSource());
        RenderShader.setProjectionMatrix(gl, spriteShader, screenW, screenH);

        let tileShader = RenderShader.createShaderProgram(gl, 
            RenderShader.tileVertexShaderSource(),
            RenderShader.tileFragmentShaderSource());
        RenderShader.setProjectionMatrix(gl, tileShader, screenW, screenH);

        // 連続する同テクスチャのスプライトを 1 draw call にまとめる instanced 描画用。
        let instShader = RenderShader.createShaderProgram(gl, 
            RenderShader.spriteInstancedVertexShaderSource(),
            RenderShader.spriteInstancedFragmentShaderSource());
        RenderShader.setProjectionMatrix(gl, instShader, screenW, screenH);

        // 連続する同 blend / 切り抜き clip 矩形の多角形を 1 draw call にまとめるバッチ描画用（頂点色）。
        let polyBatchShader = RenderShader.createShaderProgram(gl, 
            RenderShader.polyBatchVertexShaderSource(),
            RenderShader.polyBatchFragmentShaderSource());
        RenderShader.setProjectionMatrix(gl, polyBatchShader, screenW, screenH);

        // location はリンク後に不変なので起動時に 1 回だけ引く（RenderShader.spriteUniformsOf 参照）。
        let spriteUniforms = RenderShader.spriteUniformsOf(gl, spriteShader);
        let tileUniforms = RenderShader.tileUniformsOf(gl, tileShader);
        let instMultiplyBlend = gl.getUniformLocation(instShader, "multiplyBlend");
        let polyBatchUniforms = RenderShader.polyBatchUniformsOf(gl, polyBatchShader);

        let (vao, quadVBO) = RenderSprite.initSpriteRenderer(gl);
        let (polyBatchVao, polyBatchVbo) = RenderSprite.initPolygonBatchRenderer(gl);
        let (instVao, instVbo) = RenderSprite.initSpriteInstancedRenderer(gl, quadVBO);
        // 1 フレームぶんの instance / 頂点を書き溜める入れ物（毎フレーム作り直さず貸し出す）。
        // 初めの大きさは「よくある画面」の見当で、足りなければ描画側が広げる。
        let instBuf = RenderBuf.make(gl, 4096 * 38);
        let polyBuf = RenderBuf.make(gl, 16384 * 6);
        let tileVboRegistry: Ref[Map[Int32, Int32], Static] = Ref.fresh(Static, Map.empty());

        // 宣言シェーダー面（Platform.Draw2d.drawSurface）用: codegen が吐いた GLSL のコンパイル失敗時に
        // 差し替える単色フォールバックプログラム（起動時に 1 回だけ作る）。
        let fallbackShader = RenderShader.createShaderProgram(gl, 
            ShaderGen.vertexSource(), RenderShader.fallbackFragmentSource());
        RenderShader.setProjectionMatrix(gl, fallbackShader, screenW, screenH);
        // buildProgram は毎フレーム呼ばれ得るので、同じ Spec の再コンパイルをここで防ぐ。
        // 鍵を GLSL ソースにしない — 鍵を組むだけで毎フレーム GLSL 全文の組み立てを払う。
        // name だけで返さず、当たりでも eqSpec で中身を確かめる — 同名で中身が変わる
        // ホットリロード（shader.json の保存し直し）が絵に反映されなくなる。
        let shaderProgramCache: Ref[Map[String, (ShaderDoc.Spec, RenderShaderCache.ProgramEntry)], Static] = Ref.fresh(Static, Map.empty());
        // 描いたフレームの通し番号。ShaderGen.compile は Doc の数値を GLSL に書き込むので、
        // shader.json を保存し直すたびに別の鍵になる — LRU で古い方を追い出すために、
        // 「どの program をいつ使ったか」を数えるものさしが要る。
        let frameGenHolder = Array#{0i64} @ Static;
        // 鍵ではなく program 番号で持つのは、コンパイルに失敗した Spec が全部同じ fallbackShader を値にして入るため。
        let programUsedAtRef: Ref[Map[Int32, Int64], Static] = Ref.fresh(Static, Map.empty());
        let pendingShaderHolder = Array#{(Nil: List[DrawCmd.SurfaceRenderCmd])} @ Static;
        // texLocs = tex 場の (uTexN, uTexFlipN) の location 列（正典順）。
        let shaderUniformCache: Ref[Map[Int32, (Int32, Int32, Int32, Int32, List[(Int32, Int32)], List[Int32])], Static] = Ref.fresh(Static, Map.empty());
        // tex 場の標本規約（NEAREST + CLAMP）を bind 中の unit へ強制する sampler（起動時に 1 個）。
        let surfaceSampler = RenderSprite.createSurfaceSampler(gl, false);
        let surfaceSamplerLinear = RenderSprite.createSurfaceSampler(gl, true);
        // 見つからないと知らせた tex 場のテクスチャ名（「一度だけ鳴らす」控え）。
        let missingSurfaceTexRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());

        // ターゲットは初回の beginTarget で作られ、寸法が変わらない限り使い回す。
        let targetsRef: Ref[Map[String, RenderTargetGl.Entry], Static] = Ref.fresh(Static, Map.empty());
        let activeTargetHolder = Array#{(None: Option[RenderTarget.TargetSpec])} @ Static;

        // テクスチャ表は実行時に増える（ensureTexture が生成したアトラスを足す）ので可変で持つ。
        let registryRef: Ref[RenderAsset.TextureRegistry, Static] = Ref.fresh(Static, Map.empty());
        let textureKeyRef: Ref[Map[String, String], Static] = Ref.fresh(Static, Map.empty());
        // 見つからないと知らせたテクスチャ名（renderFrameMixed へ毎フレーム貸す）。
        // フレームごとに作り直すと、同じ知らせが 60 回/秒 出てしまう。
        let missingTextureRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());

        // キー一致で使い回し・不一致で古い VBO を free して作り直す（RenderStatic.resolve）。
        let staticCacheCell = Array#{(None: Option[RenderStatic.Entry])} @ Static;
        let lastFrameHolder = Array#{emptyFrame()} @ Static;

        // シェーダー面 1 枚を GL へ描く閉包。program の uniform location を逆引きして差す。
        // z の合流（sprites/polygons/静的レンジとの重なり順）は renderFrameMixed が受け持つので、
        // ここは 1 枚の描画だけに徹する。
        // cmd#texReads と texLocs の長さ不一致は List.zip が短い方に合わせて黙って吸収する —
        // コンパイル失敗した複数 Spec が同じ fallback program を鍵に uniform cache を上書きし合い、
        // fallback では texLocs が空（または全 -1）になるため、names 2 本 × locs 0 本は正常系
        //（glUniform の location -1 も無視される）。
        let drawSurface = (surfaceGl: GlContext, cmd: DrawCmd.SurfaceRenderCmd) -> {
            let program = GpuHandle.shaderProgramInt(cmd#program);
            // buildProgram だけで使用を刻むと足りない — Platform.GpuResources.buildProgram の doc は
            // 「起動時/リロード時に 1 回 compile」と約束していて、その通りに 1 回だけ
            // compile してハンドルを持ち回るゲームの program が「未使用」に見えて
            // 追い出される。追い出された program は下の uniform 逆引きが
            // (-1,-1,-1,Nil) で握り潰すので、エラーも例外も出ず絵だけ違う形で壊れる。
            Ref.put(Map.insert(program, Array.get(0, frameGenHolder), Ref.get(programUsedAtRef)),
                    programUsedAtRef);
            let (uRectPos, uRectSize, uTime, uAlpha, texLocs, paramLocs) =
                Map.get(program, Ref.get(shaderUniformCache))
                |> Option.getWithDefault((-1, -1, -1, -1, (Nil: List[(Int32, Int32)]), (Nil: List[Int32])));
            // Param の値（uParamN・正典順）。program を使う間だけ効く uniform なので、描く直前に差す。
            // 長さの不一致は List.zip が短い方に合わせて吸収する（fallback の program では locs が空）。
            if (List.isEmpty(paramLocs)) ()
            else {
                surfaceGl.useProgram(program);
                List.zip(paramLocs, cmd#params) |> List.forEach(lv -> {
                    let (loc, value) = lv;
                    surfaceGl.uniform1f(loc, RenderUtil.f32(value))
                })
            };
            // 名前 → GL テクスチャ id。無い名前は 0（黒）を bind して一度だけ知らせる —
            // pass をこのフレームで宣言せず名前だけ読むと、ずっと 0 bind（黒）のままになる。
            // registry / targets はこの 1 枚の描画中は変わらないので、名前ごとに読み直さない。
            let registry = Ref.get(registryRef);
            let targets = Ref.get(targetsRef);
            let texBinds = List.zip(cmd#texReads, texLocs) |> List.zipWithIndex
                |> List.map(itb -> {
                    let (i, readLocs) = itb;
                    let ((name, filter), locs) = readLocs;
                    let (_samplerLoc, flipLoc) = locs;
                    let texId = match Map.get(name, registry) {
                        case Some(info) => GpuHandle.textureIdInt(info#id)
                        case None =>
                            let warned = Ref.get(missingSurfaceTexRef);
                            if (Set.memberOf(name, warned)) ()
                            else {
                                System.err.println("shader tex '${name}' が見つからない — 黒(0)を貼る"
                                    + "（pass ならこのフレームで宣言されているか確認）");
                                Ref.put(Set.insert(name, warned), missingSurfaceTexRef)
                            };
                            0
                    };
                    // pass ターゲットは上下逆格納なので flip=1（貼る側で吸収する既存規約と同型）。
                    let flip = if (Map.memberOf(name, targets)) 1.0 else 0.0;
                    let sampler = if (filter == ShaderDoc.FilterMode.Linear) surfaceSamplerLinear else surfaceSampler;
                    ({ texUnit = i, texId = texId, flipLoc = flipLoc, flip = flip, sampler = sampler }: RenderSprite.SurfaceTexBind)
                });
            // mask が空なら矩形そのまま、非空なら多角形の内側だけにステンシルで抜く
            // （多角形描画は poly バッチ経路を借りる）。
            if (List.isEmpty(cmd#mask))
                RenderSprite.drawShaderSurface(surfaceGl, program, vao, { rectPos = uRectPos, rectSize = uRectSize, time = uTime, alpha = uAlpha },
                                               texBinds,
                                               cmd#rect, cmd#time, cmd#alpha, cmd#blend)
            else
                RenderSprite.drawShaderSurfaceMasked(surfaceGl, program, vao, { rectPos = uRectPos, rectSize = uRectSize, time = uTime, alpha = uAlpha },
                                               texBinds,
                                               cmd#rect, cmd#time, cmd#alpha, cmd#blend,
                                               polyBatchShader, polyBatchVao, polyBatchVbo,
                                               polyBatchUniforms, cmd#mask)
        };
        // renderFrameMixed への FrameArgs は固定値（シェーダ・VAO・buf・uniforms 等）が
        // 大半なので、共通ベースを 1 つ組み、呼び出し側は変わる所だけ上書きする。
        // registry / targetNames は毎フレーム育つ Ref から読むため、ベースの値は仮
        // （空）に置き、呼び出し時に必ず上書きする。
        let frameArgsBase: RenderFrame.FrameArgs = {
            spriteShader = spriteShader, tileShader = tileShader, vao = vao,
            registry = Map.empty(), clearColor = cfg#clearColor,
            designW = screenW, designH = screenH, fbW = 0, fbH = 0,
            sprites = Nil, tileMaps = Nil, polygons = Nil,
            staticRanges = Nil,
            polyBatchShader = polyBatchShader, polyBatchVao = polyBatchVao,
            polyBatchVbo = polyBatchVbo, polyBatchUniforms = polyBatchUniforms,
            instShader = instShader, instVao = instVao, instVbo = instVbo,
            instBuf = instBuf, polyBuf = polyBuf,
            spriteUniforms = spriteUniforms, tileUniforms = tileUniforms,
            instMultiplyBlend = instMultiplyBlend,
            surfaces = Nil, drawSurface = drawSurface,
            scenes = Scene3dRenderer.noScenes(),
            targetClear = None, targetNames = Set.empty(),
            texWarnLog = missingTextureRef
        };
        { screenW = screenW, screenH = screenH, screenFramebuffer = cfg#screenFramebuffer, frameArgsBase = frameArgsBase,
          quadVBO = quadVBO, fallbackShader = fallbackShader,
          tileVboRegistry = tileVboRegistry, shaderProgramCache = shaderProgramCache,
          frameGenHolder = frameGenHolder, programUsedAtRef = programUsedAtRef,
          pendingShaderHolder = pendingShaderHolder, shaderUniformCache = shaderUniformCache,
          pendingScene3dHolder = Array#{(Nil: List[Scene3d.RenderCmd])} @ Static, scene3d = cfg#scene3d,
          blankTexture = GpuHandle.textureIdInt(RenderTexture.loadTextureFromPixels(gl, 1, 1, Vector#{0})#id),
          targetsRef = targetsRef, activeTargetHolder = activeTargetHolder,
          historyRef = Ref.fresh(Static, Map.empty()), targetWarnedRef = Ref.fresh(Static, Set.empty()), keepHistory = true,
          registryRef = registryRef, textureKeyRef = textureKeyRef,
          staticCacheCell = staticCacheCell, lastFrameHolder = lastFrameHolder,
          diagnosticsRef = Ref.fresh(Static, None), shaderLifeHolder = Array#{0, 0} @ Static,
          retiredProgramsRef = Ref.fresh(Static, Set.empty()), gpuTimer = cfg#gpuTimer }

    // ── 1 コマ塗る ──

    /// 画面への 1 フレームを、今 bind されているフレームバッファ（fbW × fbH）へ塗る。静的レイヤーはここで
    /// resolve（キャッシュ照合・必要なら作り直し）し、レンジ列を FrameArgs に載せる。None なら Nil。
    /// 控え（lastFrame）も世代も進めない — リサイズの描き直しと注釈のスクショも同じ物を通る。
    pub def paintFrame(gl: GlContext, paint: Paint, fbW: Int32, fbH: Int32, frame: Frame): Unit \ IO =
        let staticRanges = match frame#staticLayer {
            case None    => Nil
            case Some(l) => RenderStatic.resolve(gl, paint#staticCacheCell, l)
        };
        // WhyNot: 画面に標本の数を問わない — 窓は GLFW_SAMPLES を頼まずに作る（窓の MSAA は 2D の縁も変える）。
        let prepared = prepareScenes(paint, { framebuffer = paint#screenFramebuffer, format = RenderTarget.Format.Rgba8Unorm, samples = 1 }, frame#scenes);
        RenderFrame.renderFrameMixed(gl, {
            registry = Ref.get(paint#registryRef),
            fbW = fbW, fbH = fbH,
            sprites = frame#sprites, tileMaps = frame#tileMaps, polygons = frame#polygons,
            staticRanges = staticRanges,
            surfaces = frame#surfaces, scenes = prepared,
            targetNames = Map.keysOf(Ref.get(paint#targetsRef)) | paint#frameArgsBase })

    /// レンダーターゲットへの 1 フレーム。画面用の paintFrame と違い、黒帯 clear を
    /// せず（targetClear）、タイル層・静的レンジは乗らない。シェーダー面は画面と同じく z で合流する。
    /// 中は design 座標のまま描き、viewport がテクセル寸法へ縮める（投影行列は design 前提のまま）。
    def paintTarget(gl: GlContext, paint: Paint, target: RenderTarget.TargetSpec,
                    sprites: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd],
                    surfaces: List[DrawCmd.SurfaceRenderCmd], scenes: List[Scene3d.RenderCmd]): Unit \ IO =
        let (name, tw, th, op) = (target#name, target#width, target#height, target#clear);
        let history = RenderTarget.historyName(name);
        let readsHistory = List.exists(cmd -> List.exists(read -> fst(read) == history, cmd#texReads), surfaces)
            or List.exists(d -> DrawCmd.textureOf(d) == history, sprites)
            or paint#scene3d#readsTexture(history, scenes);
        if (readsHistory) prepareHistory(gl, paint, target) else ();
        // WhyNot: 前の Pass が貼った絵を unit 0 に残さない — 形だけの描き物は絵を貼り直さず、残った絵が今の描き先だと、読まない枝でも WebGL2 が feedback loop と見て draw を止める。
        // WhyNot: テクスチャ 0 を貼らない — 完全でないテクスチャの読みはドライバ次第になる。
        gl.activeTexture(GlConst.TEXTURE0);
        gl.bindTexture(GlConst.TEXTURE_2D, paint#blankTexture);
        let entry = Map.get(name, Ref.get(paint#targetsRef));
        let framebuffer = entry |> Option.map(RenderTargetGl.drawFramebuffer) |> Option.getWithDefault(paint#screenFramebuffer);
        let samples = entry |> Option.map(RenderTargetGl.drawSamples) |> Option.getWithDefault(1);
        let prepared = prepareScenes(paint, { framebuffer = framebuffer, format = target#format, samples = samples }, scenes);
        RenderFrame.renderFrameMixed(gl, {
            registry = Ref.get(paint#registryRef),
            designW = paint#screenW, designH = paint#screenH,
            fbW = tw, fbH = th,
            sprites = sprites, polygons = polygons,
            surfaces = surfaces, scenes = prepared,
            targetClear = Some(op),
            targetNames = Map.keysOf(Ref.get(paint#targetsRef)) | paint#frameArgsBase })

    /// 開いているターゲット name の history を用意する（clear の前・描く前に呼ぶ）。窓では今の中身（= 前のコマの最後）を写し、
    /// 1 枚撮り・動画では透明で塗る。history は registry とターゲットの表に載せる（上下逆格納なので貼る・読む時の反転も効く）。
    /// history は target と同じ形式で作る（作り直しの鍵は寸法と形式）。
    def prepareHistory(gl: GlContext, paint: Paint, spec: RenderTarget.TargetSpec): Unit \ IO =
        let name = spec#name;
        let history = RenderTarget.historyName(name);
        let existing = Map.get(name, Ref.get(paint#historyRef)) |> Option.filter(sameTexture(spec));
        let entry = match existing {
            case Some(e) => e
            case None =>
                Option.forEach(e -> RenderTargetGl.destroy(gl, e), Map.get(name, Ref.get(paint#historyRef)));
                let fresh = RenderTargetGl.create(gl, spec#width, spec#height, spec#format);
                Ref.put(Map.insert(name, fresh, Ref.get(paint#historyRef)), paint#historyRef);
                fresh
        };
        match Map.get(name, Ref.get(paint#targetsRef)) {
            case Some(target) =>
                if (paint#keepHistory) {
                    // WhyNot: scissor を外さずに blit しない — glBlitFramebuffer は scissor に切られる。renderFrameMixed はコマの
                    // 終わりで外す決まりだが、崩れた時に history が四角く欠けて気づきにくいので、ここで 1 回外す。
                    gl.disable(GlConst.SCISSOR_TEST);
                    RenderTargetGl.copyTo(gl, target, entry)
                } else RenderTargetGl.clearTransparent(gl, entry, target)
            case None => ()
        };
        Ref.put(Map.insert(history, entry, Ref.get(paint#targetsRef)), paint#targetsRef);
        putTexture(history, ({ id = GpuHandle.wrapTextureId(entry#tex),
                               width = paint#screenW, height = paint#screenH }: RenderAsset.TextureInfo), paint)

    /// Platform.Draw2d.renderCommands の中身（swap は Platform.Window.presentFrame）。レンダーターゲットが開いていればそこへ塗って false。
    /// 開いていなければ、溜めたシェーダー面を取り出して画面（今 bind されている fbW × fbH）へ塗り、
    /// 控えと世代を進めて true（呼ぶ側が swap か読み戻しをする）。
    pub def submitFrame(gl: GlContext, paint: Paint, fbW: Int32, fbH: Int32,
                        sprites: List[GameEngine.Drawable], tileMaps: List[GameEngine.TileMapRenderCmd],
                        polygons: List[GameEngine.PolygonRenderCmd],
                        staticLayer: Option[GameEngine.StaticLayerCmd]): Bool \ IO =
        match Array.get(0, paint#activeTargetHolder) {
            case Some(target) =>
                // ターゲットが開いている間の描画は画面でなくそこに着く。swap も
                // 控え（リサイズ再描画の元）も触らない — 画面のフレームは同じ絵のフレームの末尾に必ず別で来る。
                // この Pass で積んだシェーダー面もここで取り出す（残すと画面の方に描かれる）。
                let surfaces = List.reverse(Array.get(0, paint#pendingShaderHolder));
                Array.put(Nil, 0, paint#pendingShaderHolder);
                let scenes = takeScenes(paint);
                timedSpan(paint, target#name, () -> paintTarget(gl, paint, target, sprites, polygons, surfaces, scenes));
                false
            case None =>
                // queueSurface が積んだこのフレームのシェーダー面を取り出して holder を空にする。
                // 順序は積んだ順（drawShaders の列順）に戻す。z の合流は renderFrameMixed が行う。
                let surfaces = List.reverse(Array.get(0, paint#pendingShaderHolder));
                Array.put(Nil, 0, paint#pendingShaderHolder);
                let frame = { sprites = sprites, tileMaps = tileMaps, polygons = polygons,
                              staticLayer = staticLayer, surfaces = surfaces, scenes = takeScenes(paint) };
                Array.put(frame, 0, paint#lastFrameHolder);
                // 進めるのはここ 1 箇所だけ。上のレンダーターゲットへの分岐でも進めると、
                // Pass を N 枚描くゲームでは絵 1 枚あたり N+1 回進み、「現世代 = いま描いて
                // いる面」という数え方が壊れる。
                Array.put(Array.get(0, paint#frameGenHolder) + 1i64, 0, paint#frameGenHolder);
                timedSpan(paint, "screen", () -> paintFrame(gl, paint, fbW, fbH, frame));
                paint#scene3d#endFrame(Array.get(0, paint#frameGenHolder));
                noteGpuTime(paint);
                true
        }

    /// 診断を集めている時だけ、paint を GPU の時間の query で囲んで描き先 name の時間として残す。
    def timedSpan(paint: Paint, name: String, f: Unit -> Unit \ IO): Unit \ IO =
        if (Option.isEmpty(Ref.get(paint#diagnosticsRef))) f()
        else paint#gpuTimer#measure(name, f)

    /// 画面のコマの終わりに、結果の出た一番新しいコマの GPU の時間を診断へ入れる。
    /// 集めていない間は 3D の数を捨てるだけ（誰も引き取らない数を溜め続けない）。
    def noteGpuTime(paint: Paint): Unit \ IO =
        if (Option.isEmpty(Ref.get(paint#diagnosticsRef))) discard paint#scene3d#takeCounts()
        else match paint#gpuTimer#endFrame() {
            case Some(t) => noteDiagnostics(paint, d -> { gpuNs = Some(t#gpuNs), gpuPasses = t#passes | d })
            case None    => ()
        }

    /// このコマ（か Pass）に溜まった 3D の場面を、積んだ順で取り出して溜め場を空にする。
    def takeScenes(paint: Paint): List[Scene3d.RenderCmd] \ IO =
        let scenes = List.reverse(Array.get(0, paint#pendingScene3dHolder));
        Array.put(Nil, 0, paint#pendingScene3dHolder);
        scenes

    /// 溜めた場面を 3D の描き手に準備させ、2D の並びへ混ぜる形を受け取る。dest = 準備の後に戻す描き先・その形式・標本の数。
    def prepareScenes(paint: Paint, dest: Scene3dRenderer.Dest, scenes: List[Scene3d.RenderCmd]): Scene3dRenderer.Prepared \ IO =
        paint#scene3d#prepare(Array.get(0, paint#frameGenHolder), registeredTexture(paint#registryRef, paint#targetsRef, paint#textureKeyRef), dest, scenes)

    /// ビルボードと 3D の材質が貼るテクスチャを名前で引く（レンダーターゲットは上下逆に格納されているので flipped）。
    /// version = ensureTexture の key（同じ GL ハンドルのまま画素を差し替えると変わる。key の無い絵は空の字）。
    def registeredTexture(registryRef: Ref[RenderAsset.TextureRegistry, Static],
                          targetsRef: Ref[Map[String, RenderTargetGl.Entry], Static],
                          textureKeyRef: Ref[Map[String, String], Static],
                          name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO =
        Map.get(name, Ref.get(registryRef)) |> Option.map(info ->
            ({ texId = GpuHandle.textureIdInt(info#id), width = info#width, height = info#height,
               flipped = Map.memberOf(name, Ref.get(targetsRef)),
               version = Map.getWithDefault(name, "", Ref.get(textureKeyRef)) }: Scene3dRenderer.RegisteredTexture))

    /// 最後に画面へ塗ったコマの命令。
    pub def lastFrame(paint: Paint): Frame \ IO = Array.get(0, paint#lastFrameHolder)

    /// 画面のコマの命令を控えに置く（起動画面のように submitFrame を通らず塗る物も、リサイズで描き直せるように）。
    pub def rememberFrame(paint: Paint, frame: Frame): Unit \ IO = Array.put(frame, 0, paint#lastFrameHolder)

    // ── 読み込み（テクスチャ・フォント）──

    /// 読み込んだフォントの引き口（getFontAtlas・ensureGlyphs の中身）。アトラスは実行中に育つので可変で持つ。
    /// atlases = 名前 → アトラス（組み込みフォントを含む）、grow = テクスチャ名の字を足す、missing = 知らせたフォント名。
    pub type alias Fonts = {
        atlases = Ref[Map[String, FontAtlas], Static],
        grow = (GlContext, FontAtlas, Set[Int32]) -> FontAtlas \ IO,
        missing = Ref[Set[String], Static]
    }

    /// 機種ごとの素材の読み込み（デスクトップは LwjglAssets.loader）。画像のデコードと字の生成は機種で違うので、本体は上げる所だけを持つ。
    /// loadTextures(gl, manifest, onProgress) = 画像を全部読んで上げ、名前 → TextureInfo（onProgress は済んだ枚数・全部の枚数）。
    /// loadFonts(gl, request, progress) = ゲームのフォントのアトラスを用意して上げる（progress は文言・済んだ数・全部の数）。
    pub type alias AssetLoader = {
        loadTextures = (GlContext, List[RenderAsset.TextureEntry], (Int32, Int32) -> Unit \ IO) -> RenderAsset.TextureRegistry \ IO,
        loadFonts = (GlContext, FontRequest, (String, Int32, Int32) -> Unit \ IO) -> FontsLoaded \ IO
    }

    /// フォントの読み込みに渡す物。registry = 足す先の登録簿（アトラスの画像を足して返す）・rootDir と glyphs = 出しうる字を集める元。
    pub type alias FontRequest = { manifest = List[RenderAsset.FontEntry], registry = RenderAsset.TextureRegistry, rootDir = String, glyphs = String }

    /// 用意したフォント。atlases = 名前 → アトラス・registry = アトラスの画像を足した登録簿・grow = 起動時に用意しなかった字を足す。
    pub type alias FontsLoaded = { atlases = Map[String, FontAtlas], registry = RenderAsset.TextureRegistry,
                                   grow = (GlContext, FontAtlas, Set[Int32]) -> FontAtlas \ IO }

    /// project.json の textures・fonts を読み、組み込みの放射テクスチャと一緒に登録簿へ載せる。
    /// progress = 進み具合（文言・済んだ数・全部の数。窓では起動画面に出す。出さないなら何もしない関数）。
    pub def loadAssets(gl: GlContext, paint: Paint, loader: AssetLoader,
                       config: { textureManifest = List[RenderAsset.TextureEntry], fontManifest = List[RenderAsset.FontEntry],
                                 rootDir = String, glyphs = String | r },
                       progress: (String, Int32, Int32) -> Unit \ IO): Fonts \ IO =
        let splash = progress;
        println("Loading textures...");
        let registry0 = loader#loadTextures(gl, config#textureManifest,
            (done, total) -> splash("loading images...", done, total));

        let loaded = loader#loadFonts(gl, { manifest = config#fontManifest, registry = registry0, rootDir = config#rootDir, glyphs = config#glyphs },
            splash);
        let gameAtlases = loaded#atlases;
        let registry = loaded#registry;
        // 組み込みフォントも名前で引けるようにする（fps 表示・フォント名が合わないときの受け皿）。
        // アトラスは実行中に育つ（起動時に用意しなかった字を後から足す）ので可変で持つ。
        let fontAtlasesRef = Ref.fresh(Static,
            Map.insert(BootFont.name(), BootFont.atlas(), gameAtlases));
        // 起動画面の分（組み込みフォント・ロゴ）を残したままゲームのテクスチャを足す。
        addTextures(registry, paint);

        // 組み込みの放射テクスチャ（Render.lightAt / darkAt が引く）。ゲームの manifest には
        // 載らない名前なので、ここで足さないと「アセット配線をしたゲームだけ光が出る」に
        // なってしまう — どのゲームでも配線ゼロで使えるよう起動時に必ず上げる。
        let radialSide = RadialBuiltin.size();
        let radialLight = RenderTexture.loadTextureFromPixels(gl, radialSide, radialSide,
            RadialBuiltin.lightPixels());
        let radialDark = RenderTexture.loadTextureFromPixels(gl, radialSide, radialSide,
            RadialBuiltin.darkPixels());
        putTexture(RadialBuiltin.lightName(), radialLight, paint);
        putTexture(RadialBuiltin.darkName(), radialDark, paint);

        { atlases = fontAtlasesRef, grow = loaded#grow,
          missing = Ref.fresh(Static, Set.empty()) }

    /// Game.getFontAtlas の中身。名前が合わないだけでゲームが落ちるより、組み込みフォントで出す方がまし。
    /// ただし黙って既定へ落ちると打ち間違いに気付けないので、名前ごとに 1 度だけ知らせる。
    pub def fontAtlas(fonts: Fonts, name: String): FontAtlas \ IO =
        match Map.get(name, Ref.get(fonts#atlases)) {
            case Some(atlas) => atlas
            case None =>
                let warned = Ref.get(fonts#missing);
                if (not Set.memberOf(name, warned)) {
                    println("[engine] フォント '${name}' は project.json にありません"
                        + "（組み込みフォントで代用します）");
                    Ref.put(Set.insert(name, warned), fonts#missing)
                } else ();
                BootFont.atlas()
        }

    /// Game.ensureGlyphs の中身。起動時に用意しなかった字を出そうとした。いま作って足す（無ければ何も起きない）。
    pub def ensureGlyphs(gl: GlContext, fonts: Fonts, textureName: String, codepoints: Set[Int32]): Unit \ IO =
        let atlases = Ref.get(fonts#atlases);
        match atlases |> Map.findLeft((_n, a) -> a#textureName == textureName) {
            case None         => ()
            case Some((n, a)) =>
                let grow = fonts#grow;
                Ref.put(Map.insert(n, grow(gl, a, codepoints), atlases), fonts#atlases)
        }

    // ── テクスチャ ──

    /// 名前のテクスチャ（無ければ None）。
    pub def textureInfo(paint: Paint, name: String): Option[RenderAsset.TextureInfo] \ IO =
        Map.get(name, Ref.get(paint#registryRef))

    /// 今の登録簿の全部。
    pub def registry(paint: Paint): RenderAsset.TextureRegistry \ IO = Ref.get(paint#registryRef)

    /// 登録簿を足す（同じ名前は渡した方を取る — 起動画面の分を残したままゲームの分を足す時の形）。
    pub def addTextures(textures: RenderAsset.TextureRegistry, paint: Paint): Unit \ IO =
        Ref.put(Map.union(textures, Ref.get(paint#registryRef)), paint#registryRef)

    /// 1 枚を名前で置く（同じ名前は置き換える）。
    pub def putTexture(name: String, info: RenderAsset.TextureInfo, paint: Paint): Unit \ IO =
        Ref.put(Map.insert(name, info, Ref.get(paint#registryRef)), paint#registryRef)

    /// Game.ensureTexture の中身。key が前と同じなら何もしない（毎フレーム呼ばれる前提の関数）。
    pub def ensureTexture(gl: GlContext, paint: Paint, name: String, key: String, width: Int32, height: Int32,
                          argb: Vector[Int32]): Unit \ IO =
        let registryRef = paint#registryRef;
        let textureKeyRef = paint#textureKeyRef;
        if (Map.get(name, Ref.get(textureKeyRef)) == Some(key)) ()
        else {
            noteDiagnostics(paint, d -> { textureUploads = name :: d#textureUploads | d });
            let prev = Map.get(name, Ref.get(registryRef));
            let sameSize = Option.exists(info ->
                info#width == Int32.toFloat64(width)
                    and info#height == Int32.toFloat64(height), prev);
            // 辺長が同じなら画素だけ差し替える（GL ハンドルを作り直さない）。
            // 名前の取り違え避け: マニフェストで読んだ絵と同じ名前だと、辺長が同じ
            // ときに元の絵の中身を上書きしてしまう。key を持たない名前 = 生成した
            // アトラスではないので、そこへは書かない。
            let taken = not Option.isEmpty(prev)
                and Option.isEmpty(Map.get(name, Ref.get(textureKeyRef)));
            if (taken) {
                println("[ensureTexture] 名前 '${name}' はすでに別の絵が使っています（上書きしません）")
            } else {
                let info = match prev {
                    case Some(old) =>
                        if (sameSize) {
                            RenderTexture.updateTexturePixels(gl, old, width, height, argb);
                            old
                        } else {
                            // 辺長が変わったので作り直す。古い方は捨てる（漏らすと作り直す
                            // たびに GPU のメモリが増え続ける）。
                            RenderTexture.deleteTexture(gl, old);
                            RenderTexture.loadTextureFromPixels(gl, width, height, argb)
                        }
                    case None => RenderTexture.loadTextureFromPixels(gl, width, height, argb)
                };
                Ref.put(Map.insert(name, info, Ref.get(registryRef)), registryRef);
                Ref.put(Map.insert(name, key, Ref.get(textureKeyRef)), textureKeyRef)
            }
        }

    // ── タイル層 ──

    /// Game.initTileBuffer の中身: インスタンス VBO と VAO を作り、(VAO, 個数) を返す。
    pub def initTileBuffer(gl: GlContext, paint: Paint, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        let instanceVBO = RenderSprite.buildTileInstanceVBO(gl, instances);
        let tileVao = RenderSprite.buildTileMapVAO(gl, paint#quadVBO, instanceVBO);
        Ref.put(Map.insert(tileVao, instanceVBO, Ref.get(paint#tileVboRegistry)), paint#tileVboRegistry);
        (GpuHandle.wrapTileVao(tileVao), List.length(instances))

    /// Game.updateTileBuffer の中身: 既にある VAO の VBO へ入れ直す（知らない VAO なら作って返す）。
    pub def updateTileBuffer(gl: GlContext, paint: Paint, vaoId: GpuHandle.TileVao, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        let tileVao = GpuHandle.tileVaoInt(vaoId);
        match Map.get(tileVao, Ref.get(paint#tileVboRegistry)) {
            case Some(vbo) =>
                RenderSprite.uploadTileInstances(gl, vbo, instances);
                (vaoId, List.length(instances))
            // レジストリに無い VAO（理論上来ない）: 新規に作って返す。
            case None => initTileBuffer(gl, paint, instances)
        }

    // ── シェーダー面 ──

    /// Platform.GpuResources.buildProgram の中身。name で引き、当たりは eqSpec（Spec の構造比較）で確かめてから返す —
    /// 当たったフレームでは ShaderGen.compile（GLSL 全文の組み立て）を呼ばない。
    /// eqSpec が偽（同名で中身が違う = ホットリロード）なら作り直して差し替える。
    /// コンパイル/リンク失敗時は単色フォールバックプログラムに落ちる（黒画面でなく色は出る）。
    pub def buildProgram(gl: GlContext, paint: Paint, spec: ShaderDoc.Spec): GpuHandle.ShaderProgram \ IO =
        let shaderProgramCache = paint#shaderProgramCache;
        let cache0 = Ref.get(shaderProgramCache);
        let gen = Array.get(0, paint#frameGenHolder);
        let hit = match Map.get(spec#name, cache0) {
            case Some((stored, found)) =>
                if (ShaderGen.isSameSpec(stored, spec)) Some(found)
                else if (ShaderGen.eqSpec(stored, spec)) {
                    // 中身が同じ別の物は、来た方を持ち直す — 古い方を持ち続けると次のコマも参照の一致で
                    // 抜けられず、毎コマ木を丸ごと比べ続ける（Doc の読み直しで Spec が作り直された後など）。
                    Ref.put(Map.insert(spec#name, (spec, found), cache0), shaderProgramCache);
                    Some(found)
                } else None
            case None => None
        };
        let entry = match hit {
            case Some(found) => found
            case None =>
                Array.put(Array.get(0, paint#shaderLifeHolder) + 1, 0, paint#shaderLifeHolder);
                noteDiagnostics(paint, d -> { shaderBuilds = { name = spec#name, reason = buildReason(cache0, spec) } :: d#shaderBuilds | d });
                let source = ShaderGen.compile(spec);
                let prog = match RenderShader.tryCreateProgram(gl, 
                        ShaderGen.vertexSource(), source, "surface:${spec#name}") {
                    case Some(p) => RenderShader.setProjectionMatrix(gl, p, paint#screenW, paint#screenH); p
                    case None    => paint#fallbackShader
                };
                let up = gl.getUniformLocation(prog, "uRectPos");
                let us = gl.getUniformLocation(prog, "uRectSize");
                let ut = gl.getUniformLocation(prog, "uTime");
                let ua = gl.getUniformLocation(prog, "uAlpha");
                // tex 場の sampler / flip の location（正典順）。sampler 番号 = unit 番号を
                // リンク直後に 1 回だけ差す（毎フレーム差し直さない）。fallback に落ちた
                // program では全て -1 になり、glUniform が無視するのでそのまま通す。
                let texLocs = ShaderDoc.texReads(spec) |> List.zipWithIndex
                    |> List.map(iname -> {
                        let (i, _) = iname;
                        (gl.getUniformLocation(prog, "uTex${i}"),
                         gl.getUniformLocation(prog, "uTexFlip${i}"))
                    });
                if (List.isEmpty(texLocs)) ()
                else {
                    gl.useProgram(prog);
                    List.forEachWithIndex((i, locs) -> {
                        let (samplerLoc, _) = locs;
                        gl.uniform1i(samplerLoc, i)
                    }, texLocs)
                };
                let paramLocs = ShaderDoc.paramNames(spec) |> List.zipWithIndex
                    |> List.map(iname -> { let (i, _) = iname; gl.getUniformLocation(prog, "uParam${i}") });
                let fresh: RenderShaderCache.ProgramEntry =
                    { program = prog, uRectPos = up, uRectSize = us, uTime = ut };
                // 同じ名前の古い program は鍵から外れる。すぐ消さず引退させる（同じコマの前の面がまだ描く）。
                Map.get(spec#name, cache0) |> Option.forEach(se -> {
                    let old = snd(se)#program;
                    if (old == prog or old == paint#fallbackShader) ()
                    else Ref.put(Set.insert(old, Ref.get(paint#retiredProgramsRef)), paint#retiredProgramsRef)
                });
                Ref.put(Map.insert(spec#name, (spec, fresh), cache0), shaderProgramCache);
                Ref.put(Map.insert(prog, (up, us, ut, ua, texLocs, paramLocs), Ref.get(paint#shaderUniformCache)), paint#shaderUniformCache);
                fresh
        };
        Ref.put(Map.insert(entry#program, gen, Ref.get(paint#programUsedAtRef)), paint#programUsedAtRef);
        // 追い出しは新しく作ったときだけ。キャッシュに当たったフレームでは鍵が増えて
        // いないので、走らせても捨てる物が出ない。
        if (Option.isEmpty(hit)) evictShaderPrograms(gl, paint) else ();
        GpuHandle.wrapShaderProgram(entry#program)

    /// 作り直した理由: 同じ名前の Spec が前にあれば、JSON の違う所を値ひとつ分の抜き書きで。
    /// 診断を集めている時だけ呼ばれる（noteDiagnostics の中）。
    def buildReason(cache: Map[String, (ShaderDoc.Spec, RenderShaderCache.ProgramEntry)], spec: ShaderDoc.Spec): FrameDiagnostics.BuildReason =
        match Map.get(spec#name, cache) {
            case None              => FrameDiagnostics.BuildReason.First
            case Some((stored, _)) => FrameDiagnostics.BuildReason.Changed(
                changedPart(ToString.toString(ShaderJson.toJson(stored)), ToString.toString(ShaderJson.toJson(spec))))
        }

    /// 2 つの文字列の違う所を、前後の切れ目（数字・語）まで広げて「…前の文脈 古い → 新しい」にする。
    def changedPart(old: String, fresh: String): String =
        let (a, b) = (String.toList(old), String.toList(fresh));
        let p = backToBoundary(a, commonPrefix(a, b, 0));
        let tailA = List.reverse(List.drop(p, a));
        let tailB = List.reverse(List.drop(p, b));
        let s = commonPrefix(tailA, tailB, 0);
        let s1 = backToBoundary(tailA, s) |> Int32.min(backToBoundary(tailB, s));
        let middle = (text: String) -> text |> String.dropLeft(p) |> String.dropRight(s1) |> clipText(60);
        "…${old |> String.takeLeft(p) |> String.takeRight(40)} ${middle(old)} → ${middle(fresh)}"

    def commonPrefix(a: List[Char], b: List[Char], n: Int32): Int32 = match (a, b) {
        case (x :: xs, y :: ys) if x == y => commonPrefix(xs, ys, n + 1)
        case _                            => n
    }

    /// 長さ n の共通部分を、値の途中で切らない所まで縮める（数字・文字・小数点・符号の並びの頭へ戻る）。
    def backToBoundary(chars: List[Char], n: Int32): Int32 =
        let isValueChar = (c: Char) -> Char.isLetterOrDigit(c) or c == '.' or c == '-' or c == '_';
        let kept = List.take(n, chars) |> List.reverse;
        let inValue = List.takeWhile(isValueChar, kept) |> List.length;
        n - inValue

    def clipText(limit: Int32, text: String): String =
        if (String.length(text) <= limit) text else String.takeLeft(limit, text) + "…"

    // ── 診断 ──

    /// 診断を集めている時だけ、このコマの診断を f で書き換える（集めていなければ f を呼ばない）。
    pub def noteDiagnostics(paint: Paint, f: FrameDiagnostics.Diagnostics -> FrameDiagnostics.Diagnostics): Unit \ IO =
        match Ref.get(paint#diagnosticsRef) {
            case Some(d) => Ref.put(Some(f(d)), paint#diagnosticsRef)
            case None    => ()
        }

    pub def setDiagnosticsEnabled(paint: Paint, on: Bool): Unit \ IO =
        Ref.put(if (on) Some(FrameDiagnostics.empty()) else None, paint#diagnosticsRef)

    /// 溜まった診断を取り出して空に戻す。liveShaders は起動からの作った数 − 消した数・scene3dCounts は前に取り出してからの 3D の数。
    /// shaderBuilds は 2D のシェーダーの後ろに 3D の材質のプログラムを足す（liveShaders には 3D の材質を数えない）。
    pub def consumeDiagnostics(paint: Paint): FrameDiagnostics.Diagnostics \ IO =
        let counts = paint#scene3d#takeCounts();
        match Ref.get(paint#diagnosticsRef) {
            case None    => FrameDiagnostics.empty()
            case Some(d) =>
                Ref.put(Some(FrameDiagnostics.empty()), paint#diagnosticsRef);
                let live = Array.get(0, paint#shaderLifeHolder) - Array.get(1, paint#shaderLifeHolder);
                { shaderBuilds = List.append(List.reverse(d#shaderBuilds), counts#materialBuilds), textureUploads = List.reverse(d#textureUploads), liveShaders = live,
                  scene3dCounts = counts | d }
        }

    /// 塗り（submit = 命令を出し終えるまで）と入れ替え（swap）の時間を診断に足す。呼ぶのは renderCommands（塗り）と presentFrame（swap）。
    pub def noteFrame(paint: Paint, submitNs: Int64, swapNs: Int64, drawItems: Unit -> Int32): Unit \ IO =
        noteDiagnostics(paint, d -> { submitNs = d#submitNs + submitNs, swapNs = d#swapNs + swapNs,
                                      drawItems = d#drawItems + drawItems() | d })

    /// Platform.Draw2d.drawSurface の中身。実描画はこのフレームの clear 直後（renderFrameMixed 内）で行う。ここでは溜めるだけ。
    pub def queueSurface(paint: Paint, cmd: DrawCmd.SurfaceRenderCmd): Unit \ IO =
        Array.put(cmd :: Array.get(0, paint#pendingShaderHolder), 0, paint#pendingShaderHolder)

    /// Platform.Draw3d.drawScene3d の中身。描くのは submitFrame（renderFrameMixed の中で z の位置に）。ここでは溜めるだけ。
    pub def queueScene3d(paint: Paint, cmd: Scene3d.RenderCmd): Unit \ IO =
        Array.put(cmd :: Array.get(0, paint#pendingScene3dHolder), 0, paint#pendingScene3dHolder)

    /// 使わなくなったシェーダープログラムを LRU で追い出す。
    def evictShaderPrograms(gl: GlContext, paint: Paint): Unit \ IO =
        let shaderProgramCache = paint#shaderProgramCache;
        let programUsedAtRef = paint#programUsedAtRef;
        let gen = Array.get(0, paint#frameGenHolder);
        let usedAt = Ref.get(programUsedAtRef);
        let cache0 = Ref.get(shaderProgramCache);
        // 現世代が刻まれている program は必ず守る。Render.drawShaders は 1 フレームの
        // 全ての面の buildProgram を先に全部呼ぶので、pin しないと面の数が上限を
        // 超えたときに、いまから描く面の program を自分で捨ててしまう。
        let liveNow = Map.toList(usedAt)
            |> List.filterMap(pa -> { let (prog, at) = pa; if (at == gen) Some(prog) else None })
            |> List.toSet;
        // 上限は「生きている面の数」から決める。固定の数にすると、面を多く出すゲームで
        // 毎フレーム作っては捨てるだけになる（面の数はゲームが決めるのでエンジンは知らない）。
        let cap = Int32.max(16, Set.size(liveNow) * 2);
        let lastSurfaces = Array.get(0, paint#lastFrameHolder)#surfaces;
        let pinned = lastSurfaces
            |> List.foldLeft((acc, cmd: DrawCmd.SurfaceRenderCmd) ->
                Set.insert(GpuHandle.shaderProgramInt(cmd#program), acc), liveNow)
            |> Set.insert(paint#fallbackShader);
        let entries = Map.toList(cache0) |> List.map(ke -> {
            let (key, se) = ke;
            let (_, e) = se;
            (key, e#program, Map.get(e#program, usedAt) |> Option.getWithDefault(0i64))
        });
        let victims = RenderShaderCache.computeEvictions(
            { entries = entries, pinned = pinned, cap = cap });
        if (List.isEmpty(victims)) ()
        else {
            // 鍵ごとの「その番号を指す鍵がまだ何本あるか」。コンパイルに失敗した Spec は
            // 全部同じ fallback program を値にして入るので、鍵を抜いても番号が
            // 生きていることがある。数えずに毎回探し直すと鍵の数の二乗になる。
            let counts0 = Map.valuesOf(cache0) |> List.foldLeft((acc, se) -> {
                let (_, e) = se;
                Map.insert(e#program, 1 + Option.getWithDefault(0, Map.get(e#program, acc)), acc)
            }, Map.empty());
            let (_, deleted) = List.foldLeft((acc, key) -> {
                let (counts, n) = acc;
                match Map.get(key, cache0) {
                    case None     => (counts, n)
                    case Some(se) =>
                        let (_, e) = se;
                        let prog = e#program;
                        Ref.put(Map.remove(key, Ref.get(shaderProgramCache)), shaderProgramCache);
                        let left = Option.getWithDefault(0, Map.get(prog, counts)) - 1;
                        let counts1 = Map.insert(prog, left, counts);
                        // uniform を先に消してはいけない。番号がまだ別の鍵で生きていると、
                        // その面が drawSurface で (-1,-1,-1,Nil) に落ちて、エラーも出ないまま
                        // uniform の差さらない絵になる。
                        if (left > 0) (counts1, n)
                        else {
                            deleteProgram(gl, paint, prog);
                            (counts1, n + 1)
                        }
                }
            }, (counts0, 0), victims);
            // 捨てた番号が bind されたままだと次の描画が未定義になる。毎フレームの経路では
            // ないので、実際に捨てたときだけ 1 回外す。
            if (deleted > 0) gl.useProgram(0) else ();
            Log.warn("shader: プログラムキャッシュから ${List.length(victims)} 個追い出した"
                + "（GPU から捨てた program ${deleted} 個・残り ${Map.size(Ref.get(shaderProgramCache))} 個 / 上限 ${cap}）")
        };
        retireSweep(gl, paint, pinned)

    /// 引退した program のうち、今と前のコマで使っておらず、ほかの鍵も指していない物を GPU から消す。
    def retireSweep(gl: GlContext, paint: Paint, pinned: Set[Int32]): Unit \ IO =
        let retired = Ref.get(paint#retiredProgramsRef);
        if (Set.isEmpty(retired)) ()
        else {
            let keyed = Map.valuesOf(Ref.get(paint#shaderProgramCache)) |> List.map(se -> snd(se)#program) |> List.toSet;
            let (drop, keep) = RenderShaderCache.retiredToDelete(retired, pinned, keyed);
            Ref.put(keep, paint#retiredProgramsRef);
            if (Set.isEmpty(drop)) ()
            else {
                Set.forEach(deleteProgram(gl, paint), drop);
                gl.useProgram(0)
            }
        }

    /// program を GPU から消し、uniform と最後に使った世代の控えからも外して数える。
    def deleteProgram(gl: GlContext, paint: Paint, prog: Int32): Unit \ IO =
        RenderShader.deleteProgram(gl, prog);
        Array.put(Array.get(1, paint#shaderLifeHolder) + 1, 1, paint#shaderLifeHolder);
        noteDiagnostics(paint, d -> { shaderDeletes = d#shaderDeletes + 1 | d });
        Ref.put(Map.remove(prog, Ref.get(paint#shaderUniformCache)), paint#shaderUniformCache);
        Ref.put(Map.remove(prog, Ref.get(paint#programUsedAtRef)), paint#programUsedAtRef)

    // ── レンダーターゲット ──

    /// RenderTarget.Target.beginTarget の中身。レジストリから引く。無い・寸法（テクセル寸法）が変わったら作り直す（古い方は必ず捨てる）。
    /// ターゲットのテクスチャを registry へ登録し（以降 Render.sprite(name, z) が普通のスプライトとして引ける）、bind する。
    /// clear は submitFrame（renderFrameMixed の targetClear）が行う — GL の clear 手順を 1 箇所に保つため、ここでは開いた印を残すだけ。
    pub def beginTarget(gl: GlContext, paint: Paint, spec: RenderTarget.TargetSpec): Unit \ IO =
        let name = spec#name;
        let targetsRef = paint#targetsRef;
        let freshEntry = () -> {
            let fresh = RenderTargetGl.createWithSamples(gl, spec#width, spec#height, spec#format, spec#samples);
            if (RenderTargetGl.isFallback(fresh)) warnFormatFallback(paint, name) else ();
            if (RenderTargetGl.isMsaaFallback(fresh)) warnMsaaFallback(paint, name) else ();
            Ref.put(Map.insert(name, fresh, Ref.get(targetsRef)), targetsRef);
            fresh
        };
        let entry = match Map.get(name, Ref.get(targetsRef)) {
            case Some(e) =>
                if (sameShape(spec, e)) e
                else { RenderTargetGl.destroy(gl, e); dropHistory(gl, paint, name); freshEntry() }
            case None => freshEntry()
        };
        // registry には design の寸法で載せる — sprite の大きさと region の UV は registry の寸法で決まるので、
        // 縮んだターゲットも design 全面に貼れる（region の src も design px のまま）。
        putTexture(name, ({ id = GpuHandle.wrapTextureId(entry#tex),
                            width = paint#screenW, height = paint#screenH }: RenderAsset.TextureInfo), paint);
        RenderTargetGl.bind(gl, entry);
        Array.put(Some(spec), 0, paint#activeTargetHolder)

    /// 作ってある e が spec と同じ寸法・形式・標本の数か（作り直しの鍵）。
    def sameShape(spec: RenderTarget.TargetSpec, e: RenderTargetGl.Entry): Bool =
        sameTexture(spec, e) and e#samples == spec#samples

    /// 作ってある e の絵（tex）が spec と同じ寸法・形式か（history の作り直しの鍵。history は標本を持たない）。
    def sameTexture(spec: RenderTarget.TargetSpec, e: RenderTargetGl.Entry): Bool =
        e#width == spec#width and e#height == spec#height and e#format == spec#format

    /// 標本を持つ描き先を作れずに MSAA なしで描くことを、名前ごとに 1 回だけ知らせる。
    def warnMsaaFallback(paint: Paint, name: String): Unit \ IO =
        warnTargetOnce(paint, name + "@msaa", name, "MSAA なし", "この描き先は標本を持つ FBO を作れない（GL_MAX_SAMPLES か FBO の完成）")

    /// Rgba16Float で作れずに Rgba8Unorm で作り直したことを、名前ごとに 1 回だけ知らせる。
    def warnFormatFallback(paint: Paint, name: String): Unit \ IO =
        warnTargetOnce(paint, name, name, "Rgba8Unorm", "この描き先は Rgba16Float の FBO を作れない（1 を超える明るさは 1 に切られる）")

    /// ターゲット name の作り方を既定へ落としたことを、鍵 key ごとに 1 回だけ知らせる。
    def warnTargetOnce(paint: Paint, key: String, name: String, fallback: String, reason: String): Unit \ IO =
        let warned = Ref.get(paint#targetWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), paint#targetWarnedRef);
            Log.fellBack("render-target", name, fallback, reason)
        }

    /// 描き先 fbW × fbH の画素へ design を収めた時の倍率（Target.pixelScale の答え。黒帯の分は入れない）。
    pub def pixelScaleOf(paint: Paint, fbW: Int32, fbH: Int32): Float64 =
        let (_, _, vpW, _) = RenderFrame.calcViewport(fbW, fbH, paint#screenW, paint#screenH);
        Int32.toFloat64(vpW) / Float64.max(1.0, paint#screenW)

    /// ターゲット name を作り直す時に、その history も捨てる（次に要る時に新しい寸法で透明から作る）。
    def dropHistory(gl: GlContext, paint: Paint, name: String): Unit \ IO =
        match Map.get(name, Ref.get(paint#historyRef)) {
            case None    => ()
            case Some(e) =>
                RenderTargetGl.destroy(gl, e);
                let history = RenderTarget.historyName(name);
                Ref.put(Map.remove(name, Ref.get(paint#historyRef)), paint#historyRef);
                Ref.put(Map.remove(history, Ref.get(paint#targetsRef)), paint#targetsRef);
                Ref.put(Map.remove(history, Ref.get(paint#registryRef)), paint#registryRef)
        }

    /// RenderTarget.Target.endTarget の中身。標本を持つターゲットは tex へ resolve してから、画面のフレームバッファへ戻す
    /// （以降の Pass と本編はターゲットを tex で読む）。
    pub def endTarget(gl: GlContext, paint: Paint): Unit \ IO =
        Array.get(0, paint#activeTargetHolder)
            |> Option.flatMap(spec -> Map.get(spec#name, Ref.get(paint#targetsRef)))
            |> Option.forEach(e -> RenderTargetGl.resolve(gl, e));
        RenderTargetGl.unbind(gl, paint#screenFramebuffer);
        Array.put(None, 0, paint#activeTargetHolder)
}
