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
    use RenderFrame.Internal.GlRows
    use RenderFrame.Internal.RenderList
    use RenderPaint.Internal.DiagnosticsCollector
    use RenderPaint.Internal.TargetTable
    use RenderPaint.Internal.TextureTable
    use RenderPaint.Internal.TileTable

    /// 1 コマの描く命令（画面へのコマ。リサイズで描き直す時・注釈のスクショも同じ物を使う）。
    pub type alias Frame = {
        sprites = List[GameEngine.Drawable],
        tileMaps = List[GameEngine.TileMapRenderCmd],
        polygons = List[GameEngine.PolygonRenderCmd],
        staticLayers = List[GameEngine.StaticLayerCmd],
        surfaces = List[DrawCmd.SurfaceRenderCmd],
        scenes = List[Scene3d.RenderCmd],
        // design の外（レターボックス・ピラーボックス）へ広げて塗る絵の名前（Platform.Draw2d.fillLetterbox。無ければ余りは黒）。
        letterbox = Option[String]
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
        // 作ったタイル VAO の表（入れ直すか作るかを決める）と、タイル VAO → インスタンス VBO（updateTileBuffer が入れ直す先）。
        tiles = TileTable.Table,
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
        // 次の画面のコマで design の外へ広げる絵の名前（fillLetterbox が置き、submitFrame が取り出す）。
        pendingLetterboxHolder = Array[Option[String], Static],
        // 3D の場面の描き手（作る側が渡す）。
        scene3d = Scene3dRenderer.Renderer,
        // Pass の頭で unit 0 に貼っておく 1 × 1 の透明な黒。
        blankTexture = Int32,
        // program → (uRectPos, uRectSize, uTime, uAlpha, texLocs, paramLocs)。
        shaderUniformCache = Ref[Map[Int32, (Int32, Int32, Int32, Int32, List[(Int32, Int32)], List[Int32])], Static],
        // レンダーターゲット・history・開いているターゲットの表（作り直しと捨てる時を決める側）。
        targets = TargetTable.Table,
        // ターゲットの表の番号（色のテクスチャの番号）→ GL 実体。
        targetEntries = Ref[Map[Int32, RenderTargetGl.Entry], Static],
        // Rgba16Float で作れず Rgba8Unorm で作り直したことを知らせたターゲットの名前（名前ごとに 1 回）。
        targetWarnedRef = Ref[Set[String], Static],
        // history に前のコマを写すか（窓で遊ぶ時）、毎回透明で塗るか（1 枚撮り・動画 — 描き出しと同じ「1 コマ目」）。
        keepHistory = Bool,
        // テクスチャの名前 → GL の実体（実行中に増える）。
        registryRef = Ref[RenderAsset.TextureRegistry, Static],
        // ensureTexture が上げた名前 → 最後の key（同じ key の上げ直しを弾く）。
        textureKeyRef = Ref[Map[String, String], Static],
        // 静的多角形バッファのキャッシュ（RenderStatic.resolve）。
        staticCache = RenderStatic.Cache,
        // static layer の VAO → VBO（捨てる時に両方 delete する）。
        staticVbos = Ref[Map[Int32, Int32], Static],
        // 最後に画面へ塗ったコマの命令（リサイズの描き直し・LRU の pin・注釈のスクショ）。
        lastFrameHolder = Array[Frame, Static],
        // 1 コマぶんの診断（setDiagnosticsEnabled の間だけ Some。consumeDiagnostics が取り出す）。
        diagnosticsRef = DiagnosticsCollector.Collector,
        // 起動から作ったシェーダーと消したシェーダーの数（[作った, 消した]。診断の liveShaders の元）。
        shaderLifeHolder = Array[Int32, Static],
        // 同じ名前で作り直して鍵から外れた program（使われなくなったら evictShaderPrograms が消す）。
        retiredProgramsRef = Ref[Set[Int32], Static],
        // GPU の時間を測る口（診断を集めている間だけ使う。作る側が渡す）。
        gpuTimer = FrameTimer
    }

    /// GPU の時間を測る口。measure(name, f) = f の中の GL の仕事の時間を描き先 name の分として測る（測るコマを間引いてよい）・
    /// endFrame() = 画面のコマの終わりに、最後に結果を読めたコマの GPU の時間（まだ無ければ None）。
    /// takeSamples() = 前に呼んでから読めたコマの時間（古い順。FrameStats の行が中央値を出す）。
    /// 3D の描き手と同じく作る側が渡す（測る GL の関数は GL 3.3 と WebGL2 で持ち方が違う）。
    pub type alias FrameTimer = {
        measure = (String, Unit -> Unit \ IO) -> Unit \ IO,
        endFrame = Unit -> Option[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ IO,
        takeSamples = Unit -> List[{ gpuNs = Int64, passes = List[(String, Int64)] }] \ IO
    }

    /// 測らない口（f をそのまま呼び、時間は出さない）。
    pub def noFrameTimer(): FrameTimer =
        { measure = (_, f) -> f(), endFrame = () -> checked_ecast(None), takeSamples = () -> checked_ecast(Nil) }

    /// 空のコマ。
    pub def emptyFrame(): Frame =
        { sprites = Nil, tileMaps = Nil, polygons = Nil, staticLayers = Nil, surfaces = Nil, scenes = Nil, letterbox = None }

    /// GL の資源を作り、空の登録簿で塗りのコアを始める。GL の文脈が今の糸に付いていること。
    /// design = 描く座標の寸（ゲームの designWidth × designHeight）、clearColor = design の中の地の色、
    /// screenFramebuffer = 画面のフレームバッファ（窓なら 0）。scene3d = 3D の場面の描き手（Scene3dRenderer.Renderer）。
    pub def create(gl: GlContext, cfg: { designWidth = Int32, designHeight = Int32, clearColor = Color, screenFramebuffer = Int32,
                          scene3d = Scene3dRenderer.Renderer, gpuTimer = FrameTimer }): Paint \ IO =
        let screenW = Int32.toFloat64(cfg#designWidth);
        let screenH = Int32.toFloat64(cfg#designHeight);

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

        // location はリンク後に不変なので起動時に 1 回だけ引く。
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
        let targetEntries: Ref[Map[Int32, RenderTargetGl.Entry], Static] = Ref.fresh(Static, Map.empty());
        let floatLinearWarned: Ref[Bool, Static] = Ref.fresh(Static, false);

        // ターゲットは初回の beginTarget で作られ、寸法が変わらない限り使い回す。
        let targets = TargetTable.fresh();

        // テクスチャ表は実行時に増える（ensureTexture が生成したアトラスを足す）ので可変で持つ。
        let registryRef: Ref[RenderAsset.TextureRegistry, Static] = Ref.fresh(Static, Map.empty());
        let textureKeyRef: Ref[Map[String, String], Static] = Ref.fresh(Static, Map.empty());
        // 見つからないと知らせたテクスチャ名（renderFrameMixed へ毎フレーム貸す）。
        // フレームごとに作り直すと、同じ知らせが 60 回/秒 出てしまう。
        let missingTextureRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());

        // キー一致で使い回し・不一致で古い VBO を free して作り直す（RenderStatic.resolve）。
        let staticCache = RenderStatic.freshCache();

        // 面の行 1 つの面を GL へ描く閉包。program の uniform location を逆引きして、行の values（rect・time・alpha・params）と reads の絵を差す。
        // stencil と数えは GlRows.drawSurfaceRow が受け持つので、ここは 1 枚の描画だけに徹する。
        // 絵の数と texLocs の数・params の数と paramLocs の数の不一致は短い方に合わせて黙って吸収する —
        // コンパイル失敗した複数 Spec が同じ fallback program を鍵に uniform cache を上書きし合い、
        // fallback では locs が空（または全 -1）になるため、絵 2 枚 × locs 0 本は正常系（glUniform の location -1 も無視される）。
        let drawSurface = (surfaceGl: GlContext, rows: Array[Int32, Static], row: Int32, reads: Array[Int32, Static], values: Array[Float32, Static]) -> {
            let program = RenderList.surfaceProgramAt(rows, row);
            // buildProgram だけで使用を刻むと足りない — Platform.GpuResources.buildProgram の doc は
            // 「起動時/リロード時に 1 回 compile」と約束していて、その通りに 1 回だけ
            // compile してハンドルを持ち回るゲームの program が「未使用」に見えて
            // 追い出される。追い出された program は下の uniform 逆引きが
            // (-1,-1,-1,Nil) で握り潰すので、エラーも例外も出ず絵だけ違う形で壊れる。
            Ref.put(Map.insert(program, Array.get(0, frameGenHolder), Ref.get(programUsedAtRef)), programUsedAtRef);
            let (uRectPos, uRectSize, uTime, uAlpha, texLocs, paramLocs) =
                Map.get(program, Ref.get(shaderUniformCache))
                |> Option.getWithDefault((-1, -1, -1, -1, (Nil: List[(Int32, Int32)]), (Nil: List[Int32])));
            let at = RenderList.valuesAt(rows, row);
            let paramCount = RenderList.surfaceValueCountAt(rows, row) - 6;
            // Param の値（uParamN・正典順）。program を使う間だけ効く uniform なので、描く直前に差す。
            if (List.isEmpty(paramLocs)) ()
            else {
                surfaceGl.useProgram(program);
                List.forEachWithIndex((k, loc) -> if (k < paramCount) surfaceGl.uniform1f(loc, Array.get(at + 6 + k, values)) else (), paramLocs)
            };
            let readsAt = RenderList.surfaceFirstReadAt(rows, row);
            let readCount = RenderList.surfaceReadCountAt(rows, row);
            let texBinds = List.zipWithIndex(texLocs) |> List.filter(il -> fst(il) < readCount) |> List.map(il -> {
                let (i, (_samplerLoc, flipLoc)) = il;
                let base = (readsAt + i) * RenderList.readFields();
                let texId = Array.get(base, reads);
                let linear = Array.get(base + 1, reads) == 1;
                let floatTarget = Map.get(texId, Ref.get(targetEntries)) |> Option.exists(e -> e#storedFormat == RenderTarget.Format.R32Float);
                if (linear and floatTarget) warnFloatLinearOnce(floatLinearWarned) else ();
                let sampler = if (linear and not floatTarget) surfaceSamplerLinear else surfaceSampler;
                ({ texUnit = i, texId = texId, flipLoc = flipLoc, flip = Int32.toFloat64(Array.get(base + 2, reads)), sampler = sampler }: RenderSprite.SurfaceTexBind)
            });
            RenderSprite.drawShaderSurface(surfaceGl, program, vao, { rectPos = uRectPos, rectSize = uRectSize, time = uTime, alpha = uAlpha },
                                           texBinds, values, at, RenderFrame.blendOf(RenderList.blendAt(rows, row)))
        };
        // renderFrameMixed への FrameArgs は固定値（シェーダ・VAO・buf・uniforms 等）が
        // 大半なので、共通ベースを 1 つ組み、呼び出し側は変わる所だけ上書きする。
        // registry / targetNames は毎フレーム育つ Ref から読むため、ベースの値は仮
        // （空）に置き、呼び出し時に必ず上書きする。
        let frameArgsBase: RenderFrame.FrameArgs = {
            tileShader = tileShader, vao = vao,
            registry = Map.empty(), clearColor = cfg#clearColor,
            designW = screenW, designH = screenH, fbW = 0, fbH = 0,
            sprites = Nil, tileMaps = Nil, polygons = Nil,
            staticRanges = Nil,
            polyBatchShader = polyBatchShader, polyBatchVao = polyBatchVao,
            polyBatchVbo = polyBatchVbo, polyBatchUniforms = polyBatchUniforms,
            instShader = instShader, instVao = instVao, instVbo = instVbo,
            instBuf = instBuf, polyBuf = polyBuf,
            tileUniforms = tileUniforms,
            instMultiplyBlend = instMultiplyBlend,
            surfaces = Nil, drawSurface = drawSurface,
            scenes = Scene3dRenderer.noScenes(),
            targetClear = None, targetNames = Set.empty(),
            texWarnLog = missingTextureRef,
            drawCounts = RenderDrawCounts.fresh()
        };
        { screenW = screenW, screenH = screenH, screenFramebuffer = cfg#screenFramebuffer, frameArgsBase = frameArgsBase,
          quadVBO = quadVBO, fallbackShader = fallbackShader,
          tiles = TileTable.fresh(), tileVboRegistry = tileVboRegistry, shaderProgramCache = shaderProgramCache,
          frameGenHolder = frameGenHolder, programUsedAtRef = programUsedAtRef,
          pendingShaderHolder = pendingShaderHolder, shaderUniformCache = shaderUniformCache,
          pendingScene3dHolder = Array#{(Nil: List[Scene3d.RenderCmd])} @ Static,
          pendingLetterboxHolder = Array#{(None: Option[String])} @ Static, scene3d = cfg#scene3d,
          blankTexture = GpuHandle.textureIdInt(RenderTexture.loadTextureFromPixels(gl, 1, 1, Vector#{0})#id),
          targets = targets, targetEntries = targetEntries,
          targetWarnedRef = Ref.fresh(Static, Set.empty()), keepHistory = true,
          registryRef = registryRef, textureKeyRef = textureKeyRef,
          staticCache = staticCache, staticVbos = Ref.fresh(Static, Map.empty()), lastFrameHolder = Array#{emptyFrame()} @ Static,
          diagnosticsRef = DiagnosticsCollector.fresh(), shaderLifeHolder = Array#{0, 0} @ Static,
          retiredProgramsRef = Ref.fresh(Static, Set.empty()), gpuTimer = cfg#gpuTimer }

    // ── 1 コマ塗る ──

    /// 画面への 1 フレームを、今 bind されているフレームバッファ（fbW × fbH）へ塗る。静的レイヤーはここで
    /// resolve（id ごとのキャッシュ照合・必要なら作り直し）し、レンジ列を FrameArgs に載せる。並びが空なら Nil。
    /// 控え（lastFrame）も世代も進めない — リサイズの描き直しと注釈のスクショも同じ物を通る。
    pub def paintFrame(gl: GlContext, paint: Paint, fbW: Int32, fbH: Int32, frame: Frame): Unit \ IO =
        ensureRadialBuiltins(gl, paint, frame#sprites, frame#surfaces, frame#scenes, frame#letterbox);
        let staticRanges = RenderStatic.resolve(glStaticAllocator(gl, paint), paint#staticCache, frame#staticLayers);
        // WhyNot: 画面に標本の数を問わない — 窓は GLFW_SAMPLES を頼まずに作る（窓の MSAA は 2D の縁も変える）。
        let prepared = prepareScenes(paint, { framebuffer = paint#screenFramebuffer, format = RenderTarget.Format.Rgba8Unorm, samples = 1,
                                              measure = timedSpan(paint) }, frame#scenes);
        let args = {
            registry = Ref.get(paint#registryRef),
            fbW = fbW, fbH = fbH,
            sprites = frame#sprites, tileMaps = frame#tileMaps, polygons = frame#polygons,
            staticRanges = staticRanges,
            surfaces = frame#surfaces, scenes = prepared,
            targetNames = TargetTable.names(paint#targets) | paint#frameArgsBase };
        let screen = GlRows.passOfArgs(args);
        if (fillLetterbox(gl, paint, args, screen, frame#letterbox)) GlRows.renderPass(gl, args, RenderList.withLetterboxKept(screen))
        else GlRows.renderPass(gl, args, screen)

    /// これから描く sprites・surfaces・3D の場面のビルボード・広げる絵 letterbox が組み込みの放射の絵を引くなら、まだ上げていなければ上げる。
    // WhyNot: 3D の材質の Tex は見ない — 組み込みの名前は `__` で始まる予約の綴りで、ゲームが材質に書く名前ではない。
    def ensureRadialBuiltins(gl: GlContext, paint: Paint, sprites: List[GameEngine.Drawable],
                             surfaces: List[DrawCmd.SurfaceRenderCmd], scenes: List[Scene3d.RenderCmd], letterbox: Option[String]): Unit \ IO =
        TextureTable.ensureRadialBuiltins(glUploads(gl), textureTables(paint), () ->
            TextureTable.isTextureRead(TextureTable.isRadialBuiltinName, sprites, surfaces)
                or paint#scene3d#readsTexture(TextureTable.isRadialBuiltinName, scenes)
                or Option.exists(TextureTable.isRadialBuiltinName, letterbox))

    /// name が組み込みの放射の絵の名前なら、まだ上げていなければ上げる（GpuResources.getTextureInfo が名前で引く前）。
    pub def ensureRadialBuiltinNamed(gl: GlContext, paint: Paint, name: String): Unit \ IO =
        TextureTable.ensureRadialBuiltins(glUploads(gl), textureTables(paint), () -> TextureTable.isRadialBuiltinName(name))

    /// 絵 tex の拡大と縮小の読み方を filter にする。
    // WhyNot: Pass の絵をいつも LINEAR で作らない — Pass を読むほかの描き物（後がけ・合成）は画素を 1 つずつ読む前提で組んである。広げて貼る間だけ替える。
    // WhyNot: 元の bind に戻さない — 本編の pass は行ごとに絵を bind し直す。
    def setFilter(gl: GlContext, tex: Int32, filter: Int32): Unit \ IO =
        gl.bindTexture(GlConst.TEXTURE_2D, tex);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MIN_FILTER, filter);
        gl.texParameteri(GlConst.TEXTURE_2D, GlConst.TEXTURE_MAG_FILTER, filter)

    /// 画面の pass に余りがあり、広げる絵 letterbox が登録簿にあれば、描き先の全面を viewport にした pass でその絵を窓いっぱいに広げて塗り、真を返す。
    /// 塗らなかった時は偽（本編の pass が余りを黒で塗る）。
    def fillLetterbox(gl: GlContext, paint: Paint, args: RenderFrame.FrameArgs, screen: RenderList.PassSpec, letterbox: Option[String]): Bool \ IO =
        let texInfo = letterbox |> Option.filter(_ -> RenderList.hasLetterbox(screen))
                                |> Option.flatMap(name -> Map.get(name, args#registry) |> Option.map(info -> (name, info)));
        match texInfo {
            case None => false
            case Some((name, info)) =>
                let fill = RenderFrame.letterboxFillOf((args#fbW, args#fbH), (paint#screenW, paint#screenH), name,
                                                       (info#width, info#height));
                let only = { sprites = fill :: Nil, tileMaps = Nil, polygons = Nil, staticRanges = Nil, surfaces = Nil,
                             scenes = Scene3dRenderer.noScenes() | args };
                let tex = GpuHandle.textureIdInt(info#id);
                setFilter(gl, tex, GlConst.LINEAR);
                GlRows.renderPass(gl, only, RenderList.fullTargetPass((args#fbW, args#fbH), args#clearColor, RenderList.DepthStencil.DepthAndStencil));
                setFilter(gl, tex, GlConst.NEAREST);
                true
        }

    /// レンダーターゲットへの 1 フレーム。画面用の paintFrame と違い、黒帯 clear を
    /// せず（targetClear）、タイル層・静的レンジは乗らない。シェーダー面は画面と同じく z で合流する。
    /// 中は design 座標のまま描き、viewport がテクセル寸法へ縮める（投影行列は design 前提のまま）。
    def paintTarget(gl: GlContext, paint: Paint, target: RenderTarget.TargetSpec,
                    sprites: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd],
                    surfaces: List[DrawCmd.SurfaceRenderCmd], scenes: List[Scene3d.RenderCmd]): Unit \ IO =
        ensureRadialBuiltins(gl, paint, sprites, surfaces, scenes, None);
        let (name, tw, th, op) = (target#name, target#width, target#height, target#clear);
        let historyName = RenderTarget.historyName(name);
        let readsHistory = TargetTable.isHistoryRead(name, sprites, surfaces) or paint#scene3d#readsTexture(texture -> texture == historyName, scenes);
        let history = TargetTable.historyFor(glTargetAllocator(gl, paint), textureTables(paint), paint#targets, (paint#screenW, paint#screenH),
                                             target, readsHistory, paint#keepHistory);
        let entry = TargetTable.rowByName(paint#targets, name) |> Option.flatMap(entryOf(paint));
        Option.forEach(t -> applyHistory(gl, paint, t, history), entry);
        // WhyNot: 前の Pass が貼った絵を unit 0 に残さない — 形だけの描き物は絵を貼り直さず、残った絵が今の描き先だと、読まない枝でも WebGL2 が feedback loop と見て draw を止める。
        // WhyNot: テクスチャ 0 を貼らない — 完全でないテクスチャの読みはドライバ次第になる。
        gl.activeTexture(GlConst.TEXTURE0);
        gl.bindTexture(GlConst.TEXTURE_2D, paint#blankTexture);
        let framebuffer = entry |> Option.map(RenderTargetGl.drawFramebuffer) |> Option.getWithDefault(paint#screenFramebuffer);
        let samples = entry |> Option.map(RenderTargetGl.drawSamples) |> Option.getWithDefault(1);
        let prepared = prepareScenes(paint, { framebuffer = framebuffer, format = target#format, samples = samples, measure = timedSpan(paint) }, scenes);
        let args = {
            registry = Ref.get(paint#registryRef),
            designW = paint#screenW, designH = paint#screenH,
            fbW = tw, fbH = th,
            sprites = sprites, polygons = polygons,
            surfaces = surfaces, scenes = prepared,
            targetClear = Some(op),
            targetNames = TargetTable.names(paint#targets) | paint#frameArgsBase };
        let color = { texture = entry |> Option.map(e -> e#tex) |> Option.getWithDefault(-1),
                      format = entry |> Option.map(e -> e#storedFormat) |> Option.getWithDefault(target#format), load = op };
        let pass = RenderList.targetPass((tw, th), color, RenderList.DepthStencil.DepthAndStencil, samples, history);
        GlRows.renderPass(gl, args, pass);
        match (entry, RenderList.resolveTargetOf(pass)) {
            case (Some(e), Some(_)) =>
                // WhyNot: resolve の後を tex の FBO を bind したままにしない — 同じ描き先へ続けて来る renderCommands が標本の無い tex へ描く。
                RenderTargetGl.resolve(gl, e);
                RenderTargetGl.bind(gl, e)
            case _ => ()
        }

    /// pass を開く前の history の始末（TargetTable.historyFor の答え）を GL でする。target = 開いている描き先。描き先は target の描く FBO に戻す。
    def applyHistory(gl: GlContext, paint: Paint, target: RenderTargetGl.Entry, history: RenderList.PassHistory): Unit \ IO =
        match history {
            case RenderList.PassHistory.NoHistory           => ()
            case RenderList.PassHistory.CopyTo(n)           =>
                // WhyNot: scissor を外さずに blit しない — glBlitFramebuffer は scissor に切られる。renderFrameMixed はコマの
                // 終わりで外す決まりだが、崩れた時に history が四角く欠けて気づきにくいので、ここで 1 回外す。
                gl.disable(GlConst.SCISSOR_TEST);
                Option.forEach(h -> RenderTargetGl.copyTo(gl, target, h), Map.get(n, Ref.get(paint#targetEntries)))
            case RenderList.PassHistory.ClearTransparent(n) =>
                Option.forEach(h -> RenderTargetGl.clearTransparent(gl, h, target), Map.get(n, Ref.get(paint#targetEntries)))
        }

    /// Platform.Draw2d.renderCommands の中身（swap は Platform.Window.presentFrame）。レンダーターゲットが開いていればそこへ塗って false。
    /// 開いていなければ、溜めたシェーダー面を取り出して画面（今 bind されている fbW × fbH）へ塗り、
    /// 控えと世代を進めて true（呼ぶ側が swap か読み戻しをする）。
    pub def submitFrame(gl: GlContext, paint: Paint, fbW: Int32, fbH: Int32,
                        sprites: List[GameEngine.Drawable], tileMaps: List[GameEngine.TileMapRenderCmd],
                        polygons: List[GameEngine.PolygonRenderCmd],
                        staticLayers: List[GameEngine.StaticLayerCmd]): Bool \ IO =
        match TargetTable.activeSpec(paint#targets) {
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
                let letterbox = Array.get(0, paint#pendingLetterboxHolder);
                Array.put(None, 0, paint#pendingLetterboxHolder);
                let frame = { sprites = sprites, tileMaps = tileMaps, polygons = polygons,
                              staticLayers = staticLayers, surfaces = surfaces, scenes = takeScenes(paint), letterbox = letterbox };
                Array.put(frame, 0, paint#lastFrameHolder);
                // 進めるのはここ 1 箇所だけ。上のレンダーターゲットへの分岐でも進めると、
                // Pass を N 枚描くゲームでは絵 1 枚あたり N+1 回進み、「現世代 = いま描いて
                // いる面」という数え方が壊れる。
                Array.put(Array.get(0, paint#frameGenHolder) + 1i64, 0, paint#frameGenHolder);
                timedSpan(paint, "screen", () -> paintFrame(gl, paint, fbW, fbH, frame));
                RenderDrawCounts.endScreenFrame(paint#frameArgsBase#drawCounts);
                paint#scene3d#endFrame(Array.get(0, paint#frameGenHolder));
                noteGpuTime(paint);
                true
        }

    /// 診断を集めている時だけ、paint を GPU の時間の query で囲んで描き先 name の時間として残す。
    def timedSpan(paint: Paint, name: String, f: Unit -> Unit \ IO): Unit \ IO =
        if (Option.isEmpty(Ref.get(paint#diagnosticsRef))) f()
        else paint#gpuTimer#measure(name, f)

    /// 画面のコマの終わりに、最後に結果を読めたコマの GPU の時間を診断へ入れる。
    /// 集めていない間は 2D と 3D の数を捨てるだけ（誰も引き取らない数を溜め続けない）。
    def noteGpuTime(paint: Paint): Unit \ IO =
        if (Option.isEmpty(Ref.get(paint#diagnosticsRef))) {
            RenderDrawCounts.discardTotal(paint#frameArgsBase#drawCounts);
            discard paint#scene3d#takeCounts()
        } else match paint#gpuTimer#endFrame() {
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
        paint#scene3d#prepare(Array.get(0, paint#frameGenHolder), registeredTexture(paint), dest, scenes)

    /// ビルボードと 3D の材質が貼るテクスチャを名前で引く（レンダーターゲットは上下逆に格納されているので flipped）。
    /// version = ensureTexture の key（同じ GL ハンドルのまま画素を差し替えると変わる。key の無い絵は空の字）。
    /// R32Float で作れず Rgba8Unorm に落ちた Pass は無い物として返す（3D の描き手は画面の上の技を切り、知らせは warnFormatFallback が出している）。
    // WhyNot: 落ちた 8bit の奥行きのまま SSAO を描かない — 遠くの面の奥行きが 1 段 数十 cm に丸まり、面の全部に縞の影が出る。
    def registeredTexture(paint: Paint, name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO =
        Map.get(name, Ref.get(paint#registryRef)) |> Option.filter(info -> not isFallenFloat(paint, GpuHandle.textureIdInt(info#id))) |> Option.map(info ->
            ({ texId = GpuHandle.textureIdInt(info#id), width = info#width, height = info#height,
               flipped = TargetTable.isTarget(paint#targets, name),
               version = Map.getWithDefault(name, "", Ref.get(paint#textureKeyRef)) }: Scene3dRenderer.RegisteredTexture))

    /// テクスチャ tex が、R32Float で頼まれて Rgba8Unorm に落ちた描き先か。
    def isFallenFloat(paint: Paint, tex: Int32): Bool \ IO =
        Map.get(tex, Ref.get(paint#targetEntries)) |> Option.exists(e -> e#format == RenderTarget.Format.R32Float and RenderTargetGl.isFallback(e))

    /// 最後に画面へ塗り終えた時の 2D の draw call の数（診断を集めていなくても読める）。
    pub def lastDraw2dCounts(paint: Paint): FrameDiagnostics.Draw2dCounts \ IO =
        RenderDrawCounts.lastScreenFrame(paint#frameArgsBase#drawCounts)

    /// 最後に画面へ塗ったコマの命令。
    pub def lastFrame(paint: Paint): Frame \ IO = Array.get(0, paint#lastFrameHolder)

    /// 画面のコマの命令を控えに置く（起動画面のように submitFrame を通らず塗る物も、リサイズで描き直せるように）。
    pub def rememberFrame(paint: Paint, frame: Frame): Unit \ IO = Array.put(frame, 0, paint#lastFrameHolder)

    // ── 読み込み（テクスチャ・フォント）──

    /// 読み込んだフォントの引き口（getFontAtlas・ensureGlyphs の中身）。アトラスは実行中に育つので可変で持つ。
    /// atlases = 名前 → アトラス（組み込みフォントを含む）、grow = テクスチャ名の字を足す、missing = 知らせたフォント名。
    pub type alias Fonts = {
        atlases = Ref[Map[String, FontAtlas], Static],
        grow = (FontAtlas, Set[Int32]) -> FontAtlas \ IO,
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
                                   grow = (FontAtlas, Set[Int32]) -> FontAtlas \ IO }

    /// project.json の textures・fonts を読み、登録簿へ載せる（組み込みの放射テクスチャは描く物が引いた時に paintFrame / paintTarget が上げる）。
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
                // WhyNot: BootFont.atlas() を毎回呼ばない — 字の表を毎コマ解き直し、名前の合わないゲームの 1 コマに約 0.08 ms 乗る（読み込みで控えた物を引く）。
                match Map.get(BootFont.name(), Ref.get(fonts#atlases)) {
                    case Some(boot) => boot
                    case None       => BootFont.atlas()
                }
        }

    /// Game.ensureGlyphs の中身。起動時に用意しなかった字を出そうとした。いま作って足す（無ければ何も起きない）。
    pub def ensureGlyphs(fonts: Fonts, textureName: String, codepoints: Set[Int32]): Unit \ IO =
        let atlases = Ref.get(fonts#atlases);
        match atlases |> Map.findLeft((_n, a) -> a#textureName == textureName) {
            case None         => ()
            case Some((n, a)) =>
                let grow = fonts#grow;
                Ref.put(Map.insert(n, grow(a, codepoints), atlases), fonts#atlases)
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
        TextureTable.putTexture(textureTables(paint), name, info)

    /// Game.ensureTexture の中身。key が前と同じなら何もしない（毎フレーム呼ばれる前提の関数。決まりは TextureTable.ensureTexture）。
    pub def ensureTexture(gl: GlContext, paint: Paint, name: String, key: String, width: Int32, height: Int32,
                          argb: Vector[Int32]): Unit \ IO =
        TextureTable.ensureTexture(glUploads(gl), textureTables(paint),
                                   () -> noteDiagnostics(paint, d -> { textureUploads = name :: d#textureUploads | d }),
                                   name, key, width, height, argb)

    /// GL で絵を上げる関数の組。
    pub def glUploads(gl: GlContext): TextureTable.Uploads =
        { createArgb = (width, height, argb) -> RenderTexture.loadTextureFromPixels(gl, width, height, argb),
          createImage = (width, height, bytes, alpha) -> RenderTexture.uploadBytes(gl, { width = width, height = height, alpha = alpha }, bytes),
          writeArgb = (info, width, height, argb) -> RenderTexture.updateTexturePixels(gl, info, width, height, argb),
          drop = info -> RenderTexture.deleteTexture(gl, info) }

    /// 絵の CPU の側の表。
    def textureTables(paint: Paint): TextureTable.Tables =
        { registryRef = paint#registryRef, textureKeyRef = paint#textureKeyRef }

    // ── タイル層 ──

    /// Game.initTileBuffer の中身: インスタンス VBO と VAO を作り、(VAO, 個数) を返す。
    pub def initTileBuffer(gl: GlContext, paint: Paint, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        TileTable.init(glTileAllocator(gl, paint), paint#tiles, instances)

    /// Game.updateTileBuffer の中身: 既にある VAO の VBO へ入れ直す（VAO は増やさない。知らない VAO なら作って返す）。
    pub def updateTileBuffer(gl: GlContext, paint: Paint, vaoId: GpuHandle.TileVao, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        TileTable.update(glTileAllocator(gl, paint), paint#tiles, vaoId, instances)

    /// GL でタイルの instance の buffer を作る・入れ直す・大きくする関数の組。番号は共有の四角を読む VAO。
    /// 大きくするのも入れ直しと同じ（glBufferData は VBO の大きさを替えて上げる）。
    def glTileAllocator(gl: GlContext, paint: Paint): TileTable.TileAllocator =
        { create = (floats, _) -> {
              let instanceVBO = RenderSprite.buildTileInstanceVBO(gl, floats);
              let tileVao = RenderSprite.buildTileMapVAO(gl, paint#quadVBO, instanceVBO);
              Ref.put(Map.insert(tileVao, instanceVBO, Ref.get(paint#tileVboRegistry)), paint#tileVboRegistry);
              tileVao
          },
          write = (tileVao, floats, _) -> uploadTiles(gl, paint, tileVao, floats),
          grow = (tileVao, floats, _) -> uploadTiles(gl, paint, tileVao, floats) }

    def uploadTiles(gl: GlContext, paint: Paint, tileVao: Int32, floats: Array[Float32, Static]): Unit \ IO =
        Map.get(tileVao, Ref.get(paint#tileVboRegistry)) |> Option.forEach(vbo -> RenderSprite.uploadTileInstances(gl, vbo, floats))

    /// GL で static layer の頂点の buffer を作る・捨てる関数の組。番号は VAO。
    def glStaticAllocator(gl: GlContext, paint: Paint): RenderStatic.StaticAllocator =
        { create = (data, count) -> {
              let (vao, vbo) = RenderSprite.buildStaticPolyVBO(gl, data, count);
              Ref.put(Map.insert(vao, vbo, Ref.get(paint#staticVbos)), paint#staticVbos);
              vao
          },
          destroy = vao -> {
              Map.get(vao, Ref.get(paint#staticVbos)) |> Option.forEach(vbo -> RenderSprite.freeStaticPolyVBO(gl, vao, vbo));
              Ref.put(Map.remove(vao, Ref.get(paint#staticVbos)), paint#staticVbos)
          } }

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
        DiagnosticsCollector.note(paint#diagnosticsRef, f)

    pub def setDiagnosticsEnabled(paint: Paint, on: Bool): Unit \ IO =
        DiagnosticsCollector.setEnabled(paint#diagnosticsRef, on)

    /// 溜まった診断を取り出して空に戻す。liveShaders は起動からの作った数 − 消した数・draw2dCounts は前に取り出してから画面へ塗り終えたコマの数・scene3dCounts は前に取り出してからの数。
    pub def consumeDiagnostics(paint: Paint): FrameDiagnostics.Diagnostics \ IO =
        let counts = paint#scene3d#takeCounts();
        let draw2d = RenderDrawCounts.take(paint#frameArgsBase#drawCounts);
        let live = Array.get(0, paint#shaderLifeHolder) - Array.get(1, paint#shaderLifeHolder);
        DiagnosticsCollector.take(paint#diagnosticsRef, draw2d, counts, live)

    /// 塗り（submit = 命令を出し終えるまで）と入れ替え（swap）の時間を診断に足す。呼ぶのは renderCommands（塗り）と presentFrame（swap）。
    pub def noteFrame(paint: Paint, submitNs: Int64, swapNs: Int64, drawItems: Unit -> Int32): Unit \ IO =
        noteDiagnostics(paint, d -> { submitNs = d#submitNs + submitNs, swapNs = d#swapNs + swapNs,
                                      drawItems = d#drawItems + drawItems() | d })

    /// 次の画面のコマで design の外へ広げて塗る絵の名前を置く（Platform.Draw2d.fillLetterbox の中身）。
    pub def queueLetterbox(paint: Paint, texture: String): Unit \ IO =
        Array.put(Some(texture), 0, paint#pendingLetterboxHolder)

    /// Platform.Draw2d.drawSurface の中身。実描画はこのフレームの clear 直後（renderFrameMixed 内）で行う。ここでは溜めるだけ。
    pub def queueSurface(paint: Paint, cmd: DrawCmd.SurfaceRenderCmd): Unit \ IO =
        Array.put(cmd :: Array.get(0, paint#pendingShaderHolder), 0, paint#pendingShaderHolder)

    /// Platform.Draw3d.drawScene3d の中身。描くのは submitFrame（renderFrameMixed の中で z の位置に）。ここでは溜めるだけ。
    pub def queueScene3d(paint: Paint, cmd: Scene3d.RenderCmd): Unit \ IO =
        Array.put(cmd :: Array.get(0, paint#pendingScene3dHolder), 0, paint#pendingScene3dHolder)

    /// Platform.Draw3d.preload3d の中身。
    // WhyNot: queueScene3d のように溜めない — 溜めると、同じコマの Pass の場面が上がる前に描かれる。
    pub def preloadScene3d(paint: Paint, cmd: Scene3d.PreloadCmd): Scene3d.PreloadProgress \ IO =
        // WhyNot: 今の世代で呼ばない — 世代は画面を描く直前に進み、今の世代のまま作ると前のコマの切れた予算で進め、作った控えを画面のコマが使っていない物とみなす。
        paint#scene3d#preload(Array.get(0, paint#frameGenHolder) + 1i64, registeredTexture(paint), cmd)

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
        let lastSurfaces = lastFrame(paint)#surfaces;
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
        let row = TargetTable.begin(glTargetAllocator(gl, paint), textureTables(paint), paint#targets, (paint#screenW, paint#screenH), spec);
        Option.forEach(RenderTargetGl.bind(gl), entryOf(paint, row))

    /// GL でレンダーターゲットを作る・捨てる関数の組。表の番号は色のテクスチャの番号。
    def glTargetAllocator(gl: GlContext, paint: Paint): TargetTable.TargetAllocator =
        { create = spec -> {
              let drawn = RenderList.drawSamplesOf(spec#samples, RenderTargetGl.sampleCounts(gl));
              let fresh = RenderTargetGl.createWithSamples(gl, spec#width, spec#height, spec#format, spec#samples, drawn);
              if (RenderTargetGl.isFallback(fresh)) warnFormatFallback(paint, spec#name, spec#format) else ();
              if (RenderTargetGl.isMsaaFallback(fresh)) warnMsaaFallback(paint, spec#name) else ();
              Ref.put(Map.insert(fresh#tex, fresh, Ref.get(paint#targetEntries)), paint#targetEntries);
              fresh#tex
          },
          destroy = texture -> destroyEntry(gl, paint, texture) }

    def destroyEntry(gl: GlContext, paint: Paint, texture: Int32): Unit \ IO =
        match Map.get(texture, Ref.get(paint#targetEntries)) {
            case Some(e) =>
                RenderTargetGl.destroy(gl, e);
                Ref.put(Map.remove(texture, Ref.get(paint#targetEntries)), paint#targetEntries)
            case None => ()
        }

    /// ターゲットの表の行 row の GL 実体。
    def entryOf(paint: Paint, row: TargetTable.Row): Option[RenderTargetGl.Entry] \ IO =
        Map.get(row#texture, Ref.get(paint#targetEntries))

    /// 標本を持つ描き先を作れずに MSAA なしで描くことを、名前ごとに 1 回だけ知らせる。
    def warnMsaaFallback(paint: Paint, name: String): Unit \ IO =
        warnTargetOnce(paint, name + "@msaa", name, "MSAA なし", "この描き先は標本を持つ FBO を作れない（GL_MAX_SAMPLES か FBO の完成）")

    /// 頼まれた形式（Rgba16Float か R32Float）で作れずに Rgba8Unorm で作り直したことを、名前ごとに 1 回だけ知らせる。
    def warnFormatFallback(paint: Paint, name: String, format: RenderTarget.Format): Unit \ IO = match format {
        case RenderTarget.Format.R32Float =>
            warnTargetOnce(paint, name, name, "Rgba8Unorm",
                           "@screen-effects-no-float-target この描き先は R32Float の FBO を作れない（奥行きが 8 bit に切られ、画面の上の技（SSAO）は効かない）")
        case _ => warnTargetOnce(paint, name, name, "Rgba8Unorm", "この描き先は Rgba16Float の FBO を作れない（1 を超える明るさは 1 に切られる）")
    }

    /// Linear で読む Spec が R32Float の Pass を読む時、最も近い画素で読むことを 1 回だけ知らせる。
    def warnFloatLinearOnce(warned: Ref[Bool, Static]): Unit \ IO =
        if (Ref.get(warned)) ()
        else {
            Ref.put(true, warned);
            Log.fellBack("render-target", "R32Float", "Nearest", "R32Float の Pass は Linear で読めない（WebGL2 は 0 を返す）— 最も近い画素で読む")
        }

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

    /// RenderTarget.Target.endTarget の中身。画面のフレームバッファへ戻す（標本を持つターゲットは paintTarget が pass の終わりに tex へ resolve 済み）。
    pub def endTarget(gl: GlContext, paint: Paint): Unit \ IO =
        discard TargetTable.end(paint#targets);
        RenderTargetGl.unbind(gl, paint#screenFramebuffer)
}
