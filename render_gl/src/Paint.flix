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
    import org.lwjgl.opengl.GL20
    import java.lang.System

    /// 1 コマの描く命令（画面へのコマ。リサイズで描き直す時・注釈のスクショも同じ物を使う）。
    pub type alias Frame = {
        sprites = List[GameEngine.Drawable],
        tileMaps = List[GameEngine.TileMapRenderCmd],
        polygons = List[GameEngine.PolygonRenderCmd],
        staticLayer = Option[GameEngine.StaticLayerCmd],
        surfaces = List[ShaderEffect.ShaderRenderCmd]
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
        pendingShaderHolder = Array[List[ShaderEffect.ShaderRenderCmd], Static],
        // program → (uRectPos, uRectSize, uTime, texLocs)。
        shaderUniformCache = Ref[Map[Int32, (Int32, Int32, Int32, List[(Int32, Int32)])], Static],
        // レンダーターゲットの名前 → GL 実体。
        targetsRef = Ref[Map[String, RenderTargetGl.Entry], Static],
        // 今開いているターゲット (幅, 高さ, clear 指定)。None = 画面。
        activeTargetHolder = Array[Option[(Int32, Int32, RenderTarget.LoadOp)], Static],
        // テクスチャの名前 → GL の実体（実行中に増える）。
        registryRef = Ref[RenderAsset.TextureRegistry, Static],
        // ensureTexture が上げた名前 → 最後の key（同じ key の上げ直しを弾く）。
        textureKeyRef = Ref[Map[String, String], Static],
        // 静的多角形バッファのキャッシュ（RenderStatic.resolve）。
        staticCacheCell = Array[Option[RenderStatic.Entry], Static],
        // 最後に画面へ塗ったコマの命令（リサイズの描き直し・LRU の pin・注釈のスクショ）。
        lastFrameHolder = Array[Frame, Static]
    }

    /// 空のコマ。
    pub def emptyFrame(): Frame =
        { sprites = Nil, tileMaps = Nil, polygons = Nil, staticLayer = None, surfaces = Nil }

    /// GL の資源を作り、空の登録簿で塗りのコアを始める。GL の文脈が今の糸に付いていること。
    /// design = 描く座標の寸（ゲームの designWidth × designHeight）、clearColor = design の中の地の色、
    /// screenFramebuffer = 画面のフレームバッファ（窓なら 0）。
    pub def create(cfg: { designWidth = Int32, designHeight = Int32, clearColor = Color, screenFramebuffer = Int32 }): Paint \ IO =
        let screenW = Int32.toFloat64(cfg#designWidth);
        let screenH = Int32.toFloat64(cfg#designHeight);

        let spriteShader = RenderShader.createShaderProgram(
            RenderShader.vertexShaderSource(),
            RenderShader.fragmentShaderSource());
        RenderShader.setProjectionMatrix(spriteShader, screenW, screenH);

        let tileShader = RenderShader.createShaderProgram(
            RenderShader.tileVertexShaderSource(),
            RenderShader.tileFragmentShaderSource());
        RenderShader.setProjectionMatrix(tileShader, screenW, screenH);

        // 連続する同テクスチャのスプライトを 1 draw call にまとめる instanced 描画用。
        let instShader = RenderShader.createShaderProgram(
            RenderShader.spriteInstancedVertexShaderSource(),
            RenderShader.spriteInstancedFragmentShaderSource());
        RenderShader.setProjectionMatrix(instShader, screenW, screenH);

        // 連続する同 blend / 切り抜き clip 矩形の多角形を 1 draw call にまとめるバッチ描画用（頂点色）。
        let polyBatchShader = RenderShader.createShaderProgram(
            RenderShader.polyBatchVertexShaderSource(),
            RenderShader.polyBatchFragmentShaderSource());
        RenderShader.setProjectionMatrix(polyBatchShader, screenW, screenH);

        // location はリンク後に不変なので起動時に 1 回だけ引く（RenderShader.spriteUniformsOf 参照）。
        let spriteUniforms = RenderShader.spriteUniformsOf(spriteShader);
        let tileUniforms = RenderShader.tileUniformsOf(tileShader);
        let instMultiplyBlend = GL20.glGetUniformLocation(instShader, "multiplyBlend");
        let polyBatchUniforms = RenderShader.polyBatchUniformsOf(polyBatchShader);

        let (vao, quadVBO) = RenderSprite.initSpriteRenderer();
        let (polyBatchVao, polyBatchVbo) = RenderSprite.initPolygonBatchRenderer();
        let (instVao, instVbo) = RenderSprite.initSpriteInstancedRenderer(quadVBO);
        // 1 フレームぶんの instance / 頂点を書き溜める入れ物（毎フレーム作り直さず貸し出す）。
        // 初めの大きさは「よくある画面」の見当で、足りなければ描画側が広げる。
        let instBuf = RenderBuf.make(4096 * 38);
        let polyBuf = RenderBuf.make(16384 * 6);
        let tileVboRegistry: Ref[Map[Int32, Int32], Static] = Ref.fresh(Static, Map.empty());

        // 宣言シェーダー面（eff Shader）用: codegen が吐いた GLSL のコンパイル失敗時に
        // 差し替える単色フォールバックプログラム（起動時に 1 回だけ作る）。
        let fallbackShader = RenderShader.createShaderProgram(
            ShaderGen.vertexSource(), RenderShader.fallbackFragmentSource());
        RenderShader.setProjectionMatrix(fallbackShader, screenW, screenH);
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
        let pendingShaderHolder = Array#{(Nil: List[ShaderEffect.ShaderRenderCmd])} @ Static;
        // texLocs = tex 場の (uTexN, uTexFlipN) の location 列（正典順）。
        let shaderUniformCache: Ref[Map[Int32, (Int32, Int32, Int32, List[(Int32, Int32)])], Static] = Ref.fresh(Static, Map.empty());
        // tex 場の標本規約（NEAREST + CLAMP）を bind 中の unit へ強制する sampler（起動時に 1 個）。
        let surfaceSampler = RenderSprite.createSurfaceSampler();
        // 見つからないと知らせた tex 場のテクスチャ名（「一度だけ鳴らす」控え）。
        let missingSurfaceTexRef: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());

        // ターゲットは初回の beginTarget で作られ、寸法が変わらない限り使い回す。
        let targetsRef: Ref[Map[String, RenderTargetGl.Entry], Static] = Ref.fresh(Static, Map.empty());
        let activeTargetHolder = Array#{(None: Option[(Int32, Int32, RenderTarget.LoadOp)])} @ Static;

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
        // cmd#texNames と texLocs の長さ不一致は List.zip が短い方に合わせて黙って吸収する —
        // コンパイル失敗した複数 Spec が同じ fallback program を鍵に uniform cache を上書きし合い、
        // fallback では texLocs が空（または全 -1）になるため、names 2 本 × locs 0 本は正常系
        //（glUniform の location -1 も無視される）。
        let drawSurface = (cmd: ShaderEffect.ShaderRenderCmd) -> {
            let program = GpuHandle.shaderProgramInt(cmd#program);
            // buildProgram だけで使用を刻むと足りない — ShaderEffect の doc は
            // 「起動時/リロード時に 1 回 compile」と約束していて、その通りに 1 回だけ
            // compile してハンドルを持ち回るゲームの program が「未使用」に見えて
            // 追い出される。追い出された program は下の uniform 逆引きが
            // (-1,-1,-1,Nil) で握り潰すので、エラーも例外も出ず絵だけ違う形で壊れる。
            Ref.put(Map.insert(program, Array.get(0, frameGenHolder), Ref.get(programUsedAtRef)),
                    programUsedAtRef);
            let (uRectPos, uRectSize, uTime, texLocs) =
                Map.get(program, Ref.get(shaderUniformCache))
                |> Option.getWithDefault((-1, -1, -1, (Nil: List[(Int32, Int32)])));
            // 名前 → GL テクスチャ id。無い名前は 0（黒）を bind して一度だけ知らせる —
            // pass をこのフレームで宣言せず名前だけ読むと、ずっと 0 bind（黒）のままになる。
            // registry / targets はこの 1 枚の描画中は変わらないので、名前ごとに読み直さない。
            let registry = Ref.get(registryRef);
            let targets = Ref.get(targetsRef);
            let texBinds = List.zip(cmd#texNames, texLocs) |> List.zipWithIndex
                |> List.map(itb -> {
                    let (i, nameLocs) = itb;
                    let (name, locs) = nameLocs;
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
                    ({ texUnit = i, texId = texId, flipLoc = flipLoc, flip = flip }: RenderSprite.SurfaceTexBind)
                });
            // mask が空なら矩形そのまま、非空なら多角形の内側だけにステンシルで抜く
            // （多角形描画は poly バッチ経路を借りる）。
            if (List.isEmpty(cmd#mask))
                RenderSprite.drawShaderSurface(program, vao, uRectPos, uRectSize, uTime,
                                               texBinds, surfaceSampler,
                                               cmd#rect, cmd#time, cmd#blend)
            else
                RenderSprite.drawShaderSurfaceMasked(program, vao, uRectPos, uRectSize, uTime,
                                               texBinds, surfaceSampler,
                                               cmd#rect, cmd#time, cmd#blend,
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
            targetClear = None, targetNames = Set.empty(),
            texWarnLog = missingTextureRef
        };
        { screenW = screenW, screenH = screenH, screenFramebuffer = cfg#screenFramebuffer, frameArgsBase = frameArgsBase,
          quadVBO = quadVBO, fallbackShader = fallbackShader,
          tileVboRegistry = tileVboRegistry, shaderProgramCache = shaderProgramCache,
          frameGenHolder = frameGenHolder, programUsedAtRef = programUsedAtRef,
          pendingShaderHolder = pendingShaderHolder, shaderUniformCache = shaderUniformCache,
          targetsRef = targetsRef, activeTargetHolder = activeTargetHolder,
          registryRef = registryRef, textureKeyRef = textureKeyRef,
          staticCacheCell = staticCacheCell, lastFrameHolder = lastFrameHolder }

    // ── 1 コマ塗る ──

    /// 画面への 1 フレームを、今 bind されているフレームバッファ（fbW × fbH）へ塗る。静的レイヤーはここで
    /// resolve（キャッシュ照合・必要なら作り直し）し、レンジ列を FrameArgs に載せる。None なら Nil。
    /// 控え（lastFrame）も世代も進めない — リサイズの描き直しと注釈のスクショも同じ物を通る。
    pub def paintFrame(paint: Paint, fbW: Int32, fbH: Int32, frame: Frame): Unit \ IO =
        let staticRanges = match frame#staticLayer {
            case None    => Nil
            case Some(l) => RenderStatic.resolve(paint#staticCacheCell, l)
        };
        RenderFrame.renderFrameMixed({
            registry = Ref.get(paint#registryRef),
            fbW = fbW, fbH = fbH,
            sprites = frame#sprites, tileMaps = frame#tileMaps, polygons = frame#polygons,
            staticRanges = staticRanges,
            surfaces = frame#surfaces,
            targetNames = Map.keysOf(Ref.get(paint#targetsRef)) | paint#frameArgsBase })

    /// レンダーターゲットへの 1 フレーム。画面用の paintFrame と違い、黒帯 clear を
    /// せず（targetClear）、タイル層・静的レンジ・シェーダー面は乗らない（Pass の doc の
    /// 決まり）。ターゲットは design と同寸なので投影行列はそのままでよい。
    def paintTarget(paint: Paint, target: (Int32, Int32, RenderTarget.LoadOp),
                    sprites: List[GameEngine.Drawable], polygons: List[GameEngine.PolygonRenderCmd]): Unit \ IO =
        let (tw, th, op) = target;
        RenderFrame.renderFrameMixed({
            registry = Ref.get(paint#registryRef),
            designW = Int32.toFloat64(tw), designH = Int32.toFloat64(th),
            fbW = tw, fbH = th,
            sprites = sprites, polygons = polygons,
            targetClear = Some(op),
            targetNames = Map.keysOf(Ref.get(paint#targetsRef)) | paint#frameArgsBase })

    /// Game.renderCommands の中身（swap の手前まで）。レンダーターゲットが開いていればそこへ塗って false。
    /// 開いていなければ、溜めたシェーダー面を取り出して画面（今 bind されている fbW × fbH）へ塗り、
    /// 控えと世代を進めて true（呼ぶ側が swap か読み戻しをする）。
    pub def submitFrame(paint: Paint, fbW: Int32, fbH: Int32,
                        sprites: List[GameEngine.Drawable], tileMaps: List[GameEngine.TileMapRenderCmd],
                        polygons: List[GameEngine.PolygonRenderCmd],
                        staticLayer: Option[GameEngine.StaticLayerCmd]): Bool \ IO =
        match Array.get(0, paint#activeTargetHolder) {
            case Some(target) =>
                // ターゲットが開いている間の描画は画面でなくそこに着く。swap も
                // 控え（リサイズ再描画の元）も触らない — 画面のフレームは同じ絵のフレームの末尾に必ず別で来る。
                paintTarget(paint, target, sprites, polygons);
                false
            case None =>
                // queueSurface が積んだこのフレームのシェーダー面を取り出して holder を空にする。
                // 順序は積んだ順（drawShaders の列順）に戻す。z の合流は renderFrameMixed が行う。
                let surfaces = List.reverse(Array.get(0, paint#pendingShaderHolder));
                Array.put(Nil, 0, paint#pendingShaderHolder);
                let frame = { sprites = sprites, tileMaps = tileMaps, polygons = polygons,
                              staticLayer = staticLayer, surfaces = surfaces };
                Array.put(frame, 0, paint#lastFrameHolder);
                // 進めるのはここ 1 箇所だけ。上のレンダーターゲットへの分岐でも進めると、
                // Pass を N 枚描くゲームでは絵 1 枚あたり N+1 回進み、「現世代 = いま描いて
                // いる面」という数え方が壊れる。
                Array.put(Array.get(0, paint#frameGenHolder) + 1i64, 0, paint#frameGenHolder);
                paintFrame(paint, fbW, fbH, frame);
                true
        }

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

    /// project.json の textures・fonts を読み、組み込みの放射テクスチャと一緒に登録簿へ載せる。
    /// progress = 進み具合（文言・済んだ数・全部の数。窓では起動画面に出す。出さないなら何もしない関数）。
    pub def loadAssets(paint: Paint,
                       config: { textureManifest = List[RenderAsset.TextureEntry], fontManifest = List[RenderAsset.FontEntry],
                                 rootDir = String, glyphs = String | r },
                       progress: (String, Int32, Int32) -> Unit \ IO): Fonts \ IO =
        let splash = progress;
        println("Loading textures...");
        let registry0 = RenderTexture.loadTextureRegistry(config#textureManifest,
            (done, total) -> splash("loading images...", done, total));

        // このゲームが出しうる字を先に集める（数十ミリ秒）。フォントが持つ字を全部用意すると
        // 日本語 1 本で数千〜2万字になり、起動が数十秒止まる。
        let wantedGlyphs = RenderFont.startupGlyphs(config#rootDir, config#glyphs);
        Option.forEach(cps -> println("[RenderFont] このゲームが出しうる字: ${Set.size(cps)} 字"),
                       wantedGlyphs);

        println("Baking font atlases...");
        // 文言はフォントごとに 1 回だけ組み立てる（進捗は字ごとに数千回来る）。
        let fontPhases: Ref[Map[String, String], Static] = Ref.fresh(Static, Map.empty());
        let fontPhaseOf = (name: String) -> match Map.get(name, Ref.get(fontPhases)) {
            case Some(text) => text
            case None =>
                let text = "loading font ${name}...";
                Ref.put(Map.insert(name, text, Ref.get(fontPhases)), fontPhases);
                text
        };
        let (gameAtlases, registry) = RenderFont.bakeFontAtlases(config#fontManifest, registry0,
            wantedGlyphs, (name, done, total) -> splash(fontPhaseOf(name), done, total));
        // 組み込みフォントも名前で引けるようにする（fps 表示・フォント名が合わないときの受け皿）。
        // アトラスは実行中に育つ（起動時に用意しなかった字を後から足す）ので可変で持つ。
        let fontAtlasesRef = Ref.fresh(Static,
            Map.insert(BootFont.name(), BootFont.atlas(), gameAtlases));
        let growTable = RenderGlyphGrow.newTable();
        List.forEach(entry -> {
            match Map.get(entry#name, gameAtlases) {
                case None =>
                    Log.warn("font: フォント '${entry#name}' のアトラスが用意できていない"
                        + " — 起動時に用意しなかった字は後から足せない（project.json の fonts の path を確認）")
                case Some(atlas) =>
                    match Map.get(atlas#textureName, registry) {
                        case None =>
                            Log.warn("font: フォント '${entry#name}' のアトラス画像"
                                + " '${atlas#textureName}' が registry に無い"
                                + " — 起動時に用意しなかった字は後から足せない")
                        case Some(texInfo) =>
                            RenderGlyphGrow.register(growTable, atlas,
                                { path = entry#path, texId = GpuHandle.textureIdInt(texInfo#id) })
                    }
            }
        }, config#fontManifest);
        // 起動画面の分（組み込みフォント・ロゴ）を残したままゲームのテクスチャを足す。
        addTextures(registry, paint);

        // 組み込みの放射テクスチャ（Render.lightAt / darkAt が引く）。ゲームの manifest には
        // 載らない名前なので、ここで足さないと「アセット配線をしたゲームだけ光が出る」に
        // なってしまう — どのゲームでも配線ゼロで使えるよう起動時に必ず上げる。
        let radialSide = RadialBuiltin.size();
        let radialLight = RenderTexture.loadTextureFromPixels(radialSide, radialSide,
            RadialBuiltin.lightPixels());
        let radialDark = RenderTexture.loadTextureFromPixels(radialSide, radialSide,
            RadialBuiltin.darkPixels());
        putTexture(RadialBuiltin.lightName(), radialLight, paint);
        putTexture(RadialBuiltin.darkName(), radialDark, paint);

        { atlases = fontAtlasesRef, grow = (atlas, cps) -> RenderGlyphGrow.ensure(growTable, atlas, cps),
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
        Ref.put(Map.insert(name, info, Ref.get(paint#registryRef)), paint#registryRef)

    /// Game.ensureTexture の中身。key が前と同じなら何もしない（毎フレーム呼ばれる前提の関数）。
    pub def ensureTexture(paint: Paint, name: String, key: String, width: Int32, height: Int32,
                          argb: Vector[Int32]): Unit \ IO =
        let registryRef = paint#registryRef;
        let textureKeyRef = paint#textureKeyRef;
        if (Map.get(name, Ref.get(textureKeyRef)) == Some(key)) ()
        else {
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
                            RenderTexture.updateTexturePixels(old, width, height, argb);
                            old
                        } else {
                            // 辺長が変わったので作り直す。古い方は捨てる（漏らすと作り直す
                            // たびに GPU のメモリが増え続ける）。
                            RenderTexture.deleteTexture(old);
                            RenderTexture.loadTextureFromPixels(width, height, argb)
                        }
                    case None => RenderTexture.loadTextureFromPixels(width, height, argb)
                };
                Ref.put(Map.insert(name, info, Ref.get(registryRef)), registryRef);
                Ref.put(Map.insert(name, key, Ref.get(textureKeyRef)), textureKeyRef)
            }
        }

    // ── タイル層 ──

    /// Game.initTileBuffer の中身: インスタンス VBO と VAO を作り、(VAO, 個数) を返す。
    pub def initTileBuffer(paint: Paint, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        let instanceVBO = RenderSprite.buildTileInstanceVBO(instances);
        let tileVao = RenderSprite.buildTileMapVAO(paint#quadVBO, instanceVBO);
        Ref.put(Map.insert(tileVao, instanceVBO, Ref.get(paint#tileVboRegistry)), paint#tileVboRegistry);
        (GpuHandle.wrapTileVao(tileVao), List.length(instances))

    /// Game.updateTileBuffer の中身: 既にある VAO の VBO へ入れ直す（知らない VAO なら作って返す）。
    pub def updateTileBuffer(paint: Paint, vaoId: GpuHandle.TileVao, instances: List[GameEngine.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        let tileVao = GpuHandle.tileVaoInt(vaoId);
        match Map.get(tileVao, Ref.get(paint#tileVboRegistry)) {
            case Some(vbo) =>
                RenderSprite.uploadTileInstances(vbo, instances);
                (vaoId, List.length(instances))
            // レジストリに無い VAO（理論上来ない）: 新規に作って返す。
            case None => initTileBuffer(paint, instances)
        }

    // ── シェーダー面 ──

    /// ShaderEffect.Shader.buildProgram の中身。name で引き、当たりは eqSpec（Spec の構造比較）で確かめてから返す —
    /// 当たったフレームでは ShaderGen.compile（GLSL 全文の組み立て）を呼ばない。
    /// eqSpec が偽（同名で中身が違う = ホットリロード）なら作り直して差し替える。
    /// コンパイル/リンク失敗時は単色フォールバックプログラムに落ちる（黒画面でなく色は出る）。
    pub def buildProgram(paint: Paint, spec: ShaderDoc.Spec): GpuHandle.ShaderProgram \ IO =
        let shaderProgramCache = paint#shaderProgramCache;
        let cache0 = Ref.get(shaderProgramCache);
        let gen = Array.get(0, paint#frameGenHolder);
        let hit = match Map.get(spec#name, cache0) {
            case Some((stored, found)) =>
                if (ShaderGen.eqSpec(stored, spec)) Some(found) else None
            case None => None
        };
        let entry = match hit {
            case Some(found) => found
            case None =>
                let source = ShaderGen.compile(spec);
                let prog = match RenderShader.tryCreateProgram(
                        ShaderGen.vertexSource(), source, "surface:${spec#name}") {
                    case Some(p) => RenderShader.setProjectionMatrix(p, paint#screenW, paint#screenH); p
                    case None    => paint#fallbackShader
                };
                let up = GL20.glGetUniformLocation(prog, "uRectPos");
                let us = GL20.glGetUniformLocation(prog, "uRectSize");
                let ut = GL20.glGetUniformLocation(prog, "uTime");
                // tex 場の sampler / flip の location（正典順）。sampler 番号 = unit 番号を
                // リンク直後に 1 回だけ差す（毎フレーム差し直さない）。fallback に落ちた
                // program では全て -1 になり、glUniform が無視するのでそのまま通す。
                let texLocs = ShaderDoc.texNames(spec) |> List.zipWithIndex
                    |> List.map(iname -> {
                        let (i, _) = iname;
                        (GL20.glGetUniformLocation(prog, "uTex${i}"),
                         GL20.glGetUniformLocation(prog, "uTexFlip${i}"))
                    });
                if (List.isEmpty(texLocs)) ()
                else {
                    GL20.glUseProgram(prog);
                    List.forEachWithIndex((i, locs) -> {
                        let (samplerLoc, _) = locs;
                        GL20.glUniform1i(samplerLoc, i)
                    }, texLocs)
                };
                let fresh: RenderShaderCache.ProgramEntry =
                    { program = prog, uRectPos = up, uRectSize = us, uTime = ut };
                Ref.put(Map.insert(spec#name, (spec, fresh), cache0), shaderProgramCache);
                Ref.put(Map.insert(prog, (up, us, ut, texLocs), Ref.get(paint#shaderUniformCache)), paint#shaderUniformCache);
                fresh
        };
        Ref.put(Map.insert(entry#program, gen, Ref.get(paint#programUsedAtRef)), paint#programUsedAtRef);
        // 追い出しは新しく作ったときだけ。キャッシュに当たったフレームでは鍵が増えて
        // いないので、走らせても捨てる物が出ない。
        if (Option.isEmpty(hit)) evictShaderPrograms(paint) else ();
        GpuHandle.wrapShaderProgram(entry#program)

    /// ShaderEffect.Shader.drawSurface の中身。実描画はこのフレームの clear 直後（renderFrameMixed 内）で行う。ここでは溜めるだけ。
    pub def queueSurface(paint: Paint, cmd: ShaderEffect.ShaderRenderCmd): Unit \ IO =
        Array.put(cmd :: Array.get(0, paint#pendingShaderHolder), 0, paint#pendingShaderHolder)

    /// 使わなくなったシェーダープログラムを LRU で追い出す。
    def evictShaderPrograms(paint: Paint): Unit \ IO =
        let shaderProgramCache = paint#shaderProgramCache;
        let shaderUniformCache = paint#shaderUniformCache;
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
            |> List.foldLeft((acc, cmd: ShaderEffect.ShaderRenderCmd) ->
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
                            RenderShader.deleteProgram(prog);
                            Ref.put(Map.remove(prog, Ref.get(shaderUniformCache)), shaderUniformCache);
                            Ref.put(Map.remove(prog, Ref.get(programUsedAtRef)), programUsedAtRef);
                            (counts1, n + 1)
                        }
                }
            }, (counts0, 0), victims);
            // 捨てた番号が bind されたままだと次の描画が未定義になる。毎フレームの経路では
            // ないので、実際に捨てたときだけ 1 回外す。
            if (deleted > 0) GL20.glUseProgram(0) else ();
            Log.warn("shader: プログラムキャッシュから ${List.length(victims)} 個追い出した"
                + "（GPU から捨てた program ${deleted} 個・残り ${Map.size(Ref.get(shaderProgramCache))} 個 / 上限 ${cap}）")
        }

    // ── レンダーターゲット ──

    /// RenderTarget.Target.beginTarget の中身。レジストリから引く。無い・寸法が変わったら作り直す（古い方は必ず捨てる）。
    /// ターゲットのテクスチャを registry へ登録し（以降 Render.sprite(name, z) が普通のスプライトとして引ける）、bind する。
    /// clear は submitFrame（renderFrameMixed の targetClear）が行う — GL の clear 手順を 1 箇所に保つため、ここでは開いた印を残すだけ。
    pub def beginTarget(paint: Paint, name: String, w: Int32, h: Int32, clearOp: RenderTarget.LoadOp): Unit \ IO =
        let targetsRef = paint#targetsRef;
        let freshEntry = () -> {
            let fresh = RenderTargetGl.create(w, h);
            Ref.put(Map.insert(name, fresh, Ref.get(targetsRef)), targetsRef);
            fresh
        };
        let entry = match Map.get(name, Ref.get(targetsRef)) {
            case Some(e) =>
                if (e#width == w and e#height == h) e
                else { RenderTargetGl.destroy(e); freshEntry() }
            case None => freshEntry()
        };
        putTexture(name, ({ id = GpuHandle.wrapTextureId(entry#tex),
                            width = Int32.toFloat64(w), height = Int32.toFloat64(h) }: RenderAsset.TextureInfo), paint);
        RenderTargetGl.bind(entry);
        Array.put(Some((w, h, clearOp)), 0, paint#activeTargetHolder)

    /// RenderTarget.Target.endTarget の中身。画面のフレームバッファへ戻す。
    pub def endTarget(paint: Paint): Unit \ IO =
        RenderTargetGl.unbind(paint#screenFramebuffer);
        Array.put(None, 0, paint#activeTargetHolder)
}
