// HeadlessRender — ギャラリーを描き出す共通配管。描画コマンド列を PNG に、
// フレーム列を GIF＋コマ別 PNG に描き出し、ReferenceSite 用のフィルムストリップ情報を返す。
//
// 各ゲームは「1回だけ宣言する設定（RenderConfig）」と「World → 描画コマンドへの投影」だけ用意すれば、
// RasterReq 組み立て・SoftRaster 呼び出し・GIF エンコード・コマ別 PNG 書き出し・間引きは HeadlessRender に任せられる。
// GL 不要なので画面の無い場所（テスト・CI）で走る。
//
// Replay はここに含めない（engine_world に住むため）。ゲーム側で Replay.timeline した frames: List[w] を
// 渡す。投影も engine 型 (GameEngine.Drawable / PolygonRenderCmd) で受け取り、engine_world に依存しない。

pub mod HeadlessRender {
    import java.awt.image.BufferedImage
    import java.io.File

    /// ゲームごとに 1 回宣言する生成設定。design を `scale` 倍に拡大して出力する。
    /// texturePath は Drawable#texture 名 → PNG パス。fontAtlas はメトリクス、fontTtf は実サイズ生成用 TTF。
    ///
    /// `shapeAntialias` は面の縁のなめらかさ。**画素の格子に乗せる絵（ドット絵）は false にする** —
    /// true のままだと、宣言したパレットに無い中間色が面の縁に湧く。
    /// 実測（同じ 1 枚を生成した PNG の実色数 / 宣言した色数）:
    /// 矩形だけの画面は 25 → 19 で収まるが、多角形を使うと 25 → 506、
    /// 台形（疑似 3D）だと 13 → 2884 になる。**矩形以外で描いた瞬間にドット絵でなくなる**。
    ///
    /// `textAntialias` は文字の縁と送り幅で、理由が別（色の予算ではなく可読性）。
    /// 7px の TTF は縁をならさないと字が潰れるので、ドット絵のキャラと小さい字が
    /// 同じ画面に出るゲームは `shapeAntialias = false` / `textAntialias = true` にする。
    pub type alias RenderConfig = {
        design         = Vec2.Vec2,
        scale          = Int32,
        background     = Color,
        texturePath    = Map[String, String],
        fontTtf        = String,
        fontAtlas      = FontAtlas,
        outDir         = String,
        frameW         = Int32,
        frameH         = Int32,
        gifDelayMs     = Int32,
        gifFps         = Int32,
        shapeAntialias = Bool,
        textAntialias  = Bool
    }

    /// 欠けた欄の落ち先。ゲームごとに違うのは design / outDir / フォント / 画風のつまみだけなので、
    /// 1 行はこの上に**その画面が実際に決めた欄だけ**載せて組む:
    ///
    ///   `{ design = design(), outDir = outDir, fontTtf = ttf(), fontAtlas = atlas,
    ///      frameW = 960, frameH = 600, shapeAntialias = false | HeadlessRender.defaults() }`
    ///
    /// こう書くと、載っている欄がそのままその画面の判断の一覧になる（同じ値を全ゲームへ
    /// 書き写さないので、載っている欄は必ず誰かが決めた欄）。
    pub def defaults(): RenderConfig =
        { design = { x = 640.0, y = 360.0 }, scale = 2,
          background = { r = 0.0, g = 0.0, b = 0.0 },
          texturePath = Map.empty(), fontTtf = "", fontAtlas = blankAtlas(),
          outDir = "gallery", frameW = 640, frameH = 360,
          gifDelayMs = 66, gifFps = 15,
          shapeAntialias = true, textAntialias = true }

    /// 字の無いフォントアトラス（defaults の落ち先）。文字を描くなら呼ぶ側が
    /// HeadlessFont.buildUiAtlas などで作った物を載せる。
    def blankAtlas(): FontAtlas =
        { textureName = "", fontSize = 0.0, textureSize = 0.0,
          ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    /// 走行中に作った正方形の絵（ドット絵アトラスなど）を PNG に落とし、
    /// 「名前 → PNG パス」の表を返す。RenderConfig#texturePath にそのまま入れられる。
    ///
    /// 実機は画素をそのまま GPU へ上げられるが、生成（SoftRaster）はファイルからしか
    /// 絵を読めない。この差をゲームごとに埋めていると、生成し忘れた絵だけが gallery で
    /// 消えてスナップショットが実機を守れなくなる — だから配管はここが持つ。
    pub def imagePngs(outDir: String,
                      images: List[{ name = String, side = Int32,
                                     pixelAt = (Int32, Int32) -> Int32 }]): Map[String, String] \ IO =
        discard (new File(outDir)).mkdirs();
        images |> List.foldLeft((acc, img) -> {
            if (img#side <= 0) acc
            else {
                let path = "${outDir}/${img#name}.png";
                SoftRaster.writeRadialPng(img#side, img#pixelAt, path);
                Map.insert(img#name, path, acc)
            }
        }, Map.empty())

    /// 同じ絵の一覧から「名前 → テクスチャの寸法」を引く関数を作る（Render.drawWith に渡す）。
    /// UV を解くのに辺長が要るので、PNG のパスだけでは足りない。
    pub def imageTextureInfo(images: List[{ name = String, side = Int32 | r }]):
            String -> Option[{ id = GpuHandle.TextureId, width = Float64, height = Float64 }] =
        let sides = images |> List.foldLeft((acc, img) ->
            Map.insert(img#name, img#side, acc), Map.empty());
        name -> Map.get(name, sides) |> Option.map(side ->
            { id = GpuHandle.wrapTextureId(0), width = Int32.toFloat64(side),
              height = Int32.toFloat64(side) })

    def reqOf(cfg: RenderConfig, drawables: List[GameEngine.Drawable],
              polygons: List[GameEngine.PolygonRenderCmd], outPath: String): SoftRaster.RasterReq =
        { drawables = drawables, polygons = polygons,
          design = cfg#design, scale = cfg#scale, background = cfg#background,
          texturePath = cfg#texturePath, fontTtf = cfg#fontTtf, fontAtlas = cfg#fontAtlas,
          outPath = outPath,
          shapeAntialias = cfg#shapeAntialias, textAntialias = cfg#textAntialias }

    def pngPath(cfg: RenderConfig, name: String): String = "${cfg#outDir}/${name}.png"
    def gifPath(cfg: RenderConfig, name: String): String = "${cfg#outDir}/${name}.gif"

    /// 生成する前に「この経路では絵に出ない指定」を知らせる。黙って落とすと、実機と違う絵が
    /// スナップショットに固定されてしまう（描き出した絵で証明する流儀そのものが嘘をつく）。
    def warnDropped(drawables: List[GameEngine.Drawable], name: String): Unit \ IO =
        SoftRaster.dropped(drawables)
            |> List.forEach(x -> println("${SoftRaster.droppedLine(x)}（${name}）"))

    // ════════════════════════════════════════════════════════
    // 絵の値段（1 場面が組んだ描き物の数）の記録
    // 判定は bin/check-render-budget.py が reference-check と status から読む。
    // ════════════════════════════════════════════════════════

    /// 場面 1 枚ぶんの数を PNG の隣へ書く。
    /// WhyNot: env や引数で切れる形にしない — 消せる検査は消えるので、生成したら必ず残る。
    /// WhyNot: 公開の変種どうしが委譲し合う所（renderPngWithPasses → …WithImages）では
    /// 呼ばない — 同じ name で 2 度書くと、後から来た本編だけの数が pass 込みの数を消す。
    def writeItemStats(cfg: RenderConfig, name: String, total: Int32,
                       passes: Int32, surfaces: Int32): Unit \ IO =
        // 前回の申告が残っていると、静的層をやめた場面の動的数が過小に出て黙って緑になる。
        discard (new File("${cfg#outDir}/${name}.static.tsv")).delete();
        writeText("${cfg#outDir}/${name}.items.tsv",
                  "total=${total}\tpasses=${passes}\tsurfaces=${surfaces}\n")

    /// タイル層・静的層を CPU へ投影したぶんを申告する（予算は 動的 = total − static で見る）。
    /// **PNG を生成した後に呼ぶ** — 前に呼ぶと生成側の掃除で申告が消え、動的数が過大に出る
    /// （過大は保守側なので落ちるだけで、絵が黙って緑になることはない）。
    /// WhyNot: 整数を受け取らない — 自由な数を書ける口にすると、検査が自己申告になる。
    pub def noteStaticItems(cfg: RenderConfig, name: String, staticItems: List[a]): Unit \ IO =
        writeText("${cfg#outDir}/${name}.static.tsv",
                  "static=${List.length(staticItems)}\n")

    def writeText(path: String, content: String): Unit \ IO =
        run {
            run { discard Fs.WriteFile.write({ str = content }, path) }
                with Fs.WriteFile.runWithFileWrite
        } with Fs.FileWrite.runWithIO

    /// 描画コマンド列を 1 枚の PNG に生成する（World を介さない場面や、投影済みの静止画に使う）。
    pub def renderPng(cfg: RenderConfig, drawables: List[GameEngine.Drawable],
                      polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO =
        warnDropped(drawables, name);
        writeItemStats(cfg, name, List.length(drawables) + List.length(polygons), 0, 0);
        SoftRaster.render(reqOf(cfg, drawables, polygons, pngPath(cfg, name)))

    /// 複数フォントで生成する renderPng。`extraFonts` はテクスチャ名（実機の project.json の
    /// fonts[].name に "font_" を付けた物。HeadlessFont.buildAtlas が付ける名前と同じ）→ その本。
    /// 既定フォント（cfg#fontTtf / cfg#fontAtlas）はそのまま効くので、混ぜたい本だけ渡す。
    /// 名前が実機と食い違うと、その字は既定フォントで描かれる（消えはしない）。
    pub def renderPngFonts(cfg: RenderConfig, extraFonts: Map[String, SoftRaster.FontEntry],
                           drawables: List[GameEngine.Drawable],
                           polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO =
        warnDropped(drawables, name);
        writeItemStats(cfg, name, List.length(drawables) + List.length(polygons), 0, 0);
        SoftRaster.renderFonts(reqOf(cfg, drawables, polygons, pngPath(cfg, name)), extraFonts)

    /// 宣言シェーダー面つきの renderPng。surfaces（Render.shaderSurfaces の出力と同形の
    /// 構造レコード）は ShaderEval の画素評価で生成され、z 順で他の描き物と合流する。
    /// 面の tex 場（Field.Tex）が読めるのはゲームのテクスチャだけ — pass の名前も読むなら
    /// renderPngWithPasses / renderPngWithImages を使う。
    /// 渡す側は draw の代表色ベタ塗りと二重にならないよう、items を Render.withoutShaders で
    /// 外してから draw すること。
    pub def renderPngWith(cfg: RenderConfig, drawables: List[GameEngine.Drawable],
                          polygons: List[GameEngine.PolygonRenderCmd],
                          surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO =
        warnDropped(drawables, name);
        writeItemStats(cfg, name, List.length(drawables) + List.length(polygons), 0,
                       List.length(surfaces));
        SoftRaster.renderWithSurfaces(reqOf(cfg, drawables, polygons, pngPath(cfg, name)), surfaces)

    // ════════════════════════════════════════════════════════
    // シルエット生成 — 造形（形が物として読めるか）を目視するための材料づくり
    // ════════════════════════════════════════════════════════

    /// シルエット生成の絞り方。既定に使うのは WorldBand — 全アイテムを黒にすると画面が
    /// 1 つの塊に融けて個々の形が見えないため、まず主役の z-index の範囲（world の範囲）だけに絞る。
    /// All（全アイテム黒）の用途は画面全体の重心確認に限る（docs/drawing-floor.md）。
    pub enum SilhouetteScope {
        case WorldBand
        case All
        /// z の窓（lo 以上 hi 未満）だけ。Depth.Bands で仕切った帯を 1 本ずつ描き出して、
        /// 地面・主役・手前を別の絵として見比べるための絞り。
        case ZWindow({ lo = Int32, hi = Int32 })
    }

    /// scope が z を対象に含むか。world の範囲の上端は UI 層の底（CanvasLayer.layerStride）。
    def silhouetteKeeps(scope: SilhouetteScope, z: Int32): Bool =
        match scope {
            case SilhouetteScope.WorldBand => z < CanvasLayer.layerStride()
            case SilhouetteScope.All       => true
            case SilhouetteScope.ZWindow(w) => z >= w#lo and z < w#hi
        }

    /// 描画コマンド列を「対象は真っ黒・それ以外は落とす」に写す純関数。背景を白にして
    /// 生成すれば、シルエットだけで何か分かるか（絵の下限の 5 つ目の性質）を目で確かめられる。
    /// 形の良し悪しの判定はしない — 機械は見やすい材料を出すまで。
    pub def silhouette(scope: SilhouetteScope,
                       drawables: List[GameEngine.Drawable],
                       polygons: List[GameEngine.PolygonRenderCmd]):
                       (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]) =
        (drawables |> List.filter(d -> silhouetteKeeps(scope, DrawCmd.zIndexOf(d))) |> List.map(blackenDrawable),
         polygons  |> List.filter(p -> silhouetteKeeps(scope, p#zIndex)) |> List.map(blackenPolygon))

    /// 宣言シェーダー面も含めた silhouette。面は「rect と mask の形をそのまま黒で塗る」に
    /// 写す（中の場・グラデーション・alpha の抜きは全部捨てる）。
    /// 地面や空をシェーダーの面で塗る絵では、面を外したシルエットは地平線も接地も写らず、
    /// 見る側は何も写っていない画像を見て「壊れなし」と受け取ってしまう。
    pub def silhouetteWith(scope: SilhouetteScope,
                           drawables: List[GameEngine.Drawable],
                           polygons: List[GameEngine.PolygonRenderCmd],
                           surfaces: List[SoftRaster.SurfaceCmd]):
                           (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd],
                            List[SoftRaster.SurfaceCmd]) =
        let (blackDrawables, blackPolygons) = silhouette(scope, drawables, polygons);
        (blackDrawables, blackPolygons,
         surfaces |> List.filter(s -> silhouetteKeeps(scope, s#zIndex)) |> List.map(blackenSurface))

    def silhouetteInk(): Color = { r = 0.0, g = 0.0, b = 0.0 }

    /// シェーダー面を「黒のベタ・alpha は全面 1」に写す。alpha を場のまま残すと、
    /// 面のふちの薄さが灰色として出てシルエットの縁がぼやける（blackenDrawable と同じ理由）。
    /// rect と mask は触らない — 形はそこが持っている。
    def blackenSurface(s: SoftRaster.SurfaceCmd): SoftRaster.SurfaceCmd =
        { spec = { name = s#spec#name, cycleRate = 0.0, bindings = Nil,
                   out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(silhouetteInk()),
                                              alpha = ShaderDoc.Field.Const(1.0) }) },
          blend = DrawCmd.BlendMode.Normal | s }

    /// Drawable を真っ黒の不透明に写す。texture は消さない — 絵の抜き（形）はテクスチャの
    /// α が持っていて、色は黒 tint の乗算で消えるため。blend は Normal にする（Add は黒を
    /// 足しても何も描かず、形ごと消える）。alpha を 1 に上げるのは、半透明の濃淡は塗りの
    /// 情報で、形の検査には雑音だから。
    def blackenDrawable(d: GameEngine.Drawable): GameEngine.Drawable =
        let spec = DrawCmd.toSpec(d);
        DrawCmd.make({ color = silhouetteInk(), alpha = 1.0, blend = DrawCmd.BlendMode.Normal,
          style = spec#style |> Option.map(st ->
              DrawCmd.makeStyle({ borderColor = silhouetteInk(), stripeColor = silhouetteInk(),
                                  checkerColor = silhouetteInk() | DrawCmd.styleToSpec(st) })) | spec })

    /// 多角形を真っ黒の不透明に写す。grad は外す — 頂点ごとの色は面の情報で、
    /// 残すと補間の縁が灰色に出てシルエットの縁が濁る。
    def blackenPolygon(p: GameEngine.PolygonRenderCmd): GameEngine.PolygonRenderCmd =
        { color = silhouetteInk(), alpha = 1.0, blend = DrawCmd.BlendMode.Normal,
          grad = None | p }

    /// シルエット PNG を生成する（renderPng の変形版）。対象を黒・背景を白で <name>.png に書く。
    /// 背景白を cfg でなくここで固定するのは、シルエットの読み取りが黒 / 白の 2 値で
    /// 成り立つ検査で、ゲームごとの背景色が混ざると意味が変わるため。
    pub def silhouettePng(cfg: RenderConfig, scope: SilhouetteScope,
                          drawables: List[GameEngine.Drawable],
                          polygons: List[GameEngine.PolygonRenderCmd], name: String): Unit \ IO =
        silhouettePngWith(cfg, scope, drawables, polygons, Nil, name)

    /// silhouettePng の「宣言シェーダー面も写す」版。地面・空・水面を ShaderDoc の面で
    /// 塗っているなら必ずこちらを使う — 面を渡さないと、シルエットにその面が出ない。
    pub def silhouettePngWith(cfg: RenderConfig, scope: SilhouetteScope,
                              drawables: List[GameEngine.Drawable],
                              polygons: List[GameEngine.PolygonRenderCmd],
                              surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO =
        let (blackDrawables, blackPolygons, blackSurfaces) =
            silhouetteWith(scope, drawables, polygons, surfaces);
        renderPngWith({ background = { r = 1.0, g = 1.0, b = 1.0 } | cfg },
                      blackDrawables, blackPolygons, blackSurfaces, name)

    // ════════════════════════════════════════════════════════
    // pass（レンダーターゲット）— 本編より先に別画像へ描き、名前で本編から貼る
    // ════════════════════════════════════════════════════════

    /// pass 1 枚ぶんの宣言（Render.Pass のコマンド列版）。name はそのままテクスチャ名になり、
    /// 本編の drawables から普通のスプライトとして参照できる。本編のシェーダー面の tex 場
    ///（Field.Tex）も同じ name で生成した絵を読める。
    /// drawables へ下ろすときは items を Render.withoutShaders で外してから Render.draw する
    /// こと — GL はターゲットの中の Shader 面を描かないので、代表色ベタ塗りが混ざると実機とズレる。
    pub type alias PassSpec = {
        name = String,
        clear = RenderTarget.LoadOp,
        drawables = List[GameEngine.Drawable],
        polygons = List[GameEngine.PolygonRenderCmd]
    }

    /// pass 1 枚を design 解像度（scale = 1）の画像に生成する。GL のターゲットが design ×1 の
    /// テクスチャなので、ここで cfg#scale を掛けると本編に貼るときの拡大と二重になる。
    /// clear が Clear ならその色（不透明）で塗ってから — prev は見ない（GL の glClear と
    /// 同じで、塗った時点で前の中身は消えるため）。ClearTransparent も prev を見ずに透明から。
    /// Keep なら prev のコピーの上に描き足し（残像・軌跡を GIF やプレロールで再現する口）、
    /// prev が無ければ透明から。
    pub def renderPassImage(cfg: RenderConfig, p: PassSpec,
                          prev: Option[BufferedImage]): BufferedImage \ IO =
        renderPassImageWith(cfg, Map.empty(), p, prev)

    /// renderPassImage の「先に生成したターゲットも参照できる」版。`images` は既に生成した pass の
    /// 名前 → 画像（GL が宣言順に描くのと同じで、後の pass は前の pass を貼れる）。
    pub def renderPassImageWith(cfg: RenderConfig, images: Map[String, BufferedImage],
                              p: PassSpec, prev: Option[BufferedImage]): BufferedImage \ IO =
        let req = { scale = 1 | reqOf(cfg, p#drawables, p#polygons, "") };
        match p#clear {
            case RenderTarget.LoadOp.Clear(c)         => SoftRaster.renderToImageFull({ background = c | req }, Nil, Map.empty(), images)
            case RenderTarget.LoadOp.Keep             => SoftRaster.renderPassImage(req, prev, images)
            case RenderTarget.LoadOp.ClearTransparent => SoftRaster.renderPassImage(req, None, images)
        }

    /// 追加の生成済み画像（pass のレンダーターゲットなど）を textures に混ぜて本編を PNG に生成する。
    pub def renderPngWithImages(cfg: RenderConfig, images: Map[String, BufferedImage],
                                drawables: List[GameEngine.Drawable],
                                polygons: List[GameEngine.PolygonRenderCmd],
                                surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO =
        writeItemStats(cfg, name, List.length(drawables) + List.length(polygons), 0,
                       List.length(surfaces));
        renderPngWithImagesCore(cfg, images, drawables, polygons, surfaces, name)

    /// renderPngWithImages の中身から「値段の記録」だけを外した実体。
    /// WhyNot: renderPngWithPasses からはこちらを呼ぶ — 公開の方を呼ぶと、pass を足した数を
    /// 本編だけの数で上書きしてしまい、pass へ絵を移した場面が予算をすり抜ける。
    def renderPngWithImagesCore(cfg: RenderConfig, images: Map[String, BufferedImage],
                                drawables: List[GameEngine.Drawable],
                                polygons: List[GameEngine.PolygonRenderCmd],
                                surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO =
        warnDropped(drawables, name);
        SoftRaster.renderFull(reqOf(cfg, drawables, polygons, pngPath(cfg, name)),
            surfaces, Map.empty(), images)

    /// passes を宣言順に生成してから本編を PNG に生成する（GL の renderFrame と同じ順序 —
    /// 後の pass の drawables は先に生成した pass の名前を貼れる）。
    /// 本編の drawables 同様、pass の items も Render.withoutShaders → Render.draw で
    /// 下ろすこと（PassSpec の doc の決まり）。
    pub def renderPngWithPasses(cfg: RenderConfig, passes: List[PassSpec],
                                drawables: List[GameEngine.Drawable],
                                polygons: List[GameEngine.PolygonRenderCmd],
                                surfaces: List[SoftRaster.SurfaceCmd], name: String): Unit \ IO =
        // pass の中の生成できない指定も本編と同じに知らせる（本編ぶんは renderPngWithImages が出す）。
        passes |> List.forEach(p -> warnDropped(p#drawables, "${name}:pass ${p#name}"));
        // pass の中身も実機では描く物なので予算に入れる（本編から pass へ移すだけで
        // すり抜けられると、検査は避けられる物になる）。
        let passItems = passes |> List.foldLeft((acc, p) ->
            acc + List.length(p#drawables) + List.length(p#polygons), 0);
        writeItemStats(cfg, name, List.length(drawables) + List.length(polygons) + passItems,
                       passItems, List.length(surfaces));
        let images = passes |> List.foldLeft((acc, p) -> {
            Map.insert(p#name, renderPassImageWith(cfg, acc, p, None), acc)
        }, (Map.empty(): Map[String, BufferedImage]));
        renderPngWithImagesCore(cfg, images, drawables, polygons, surfaces, name)

    /// frames を stride 枚ごとに間引き、各コマを toCmds で描いて GIF ＋ コマ別 PNG に生成する。
    /// 返り値は ReferenceSite 用のフィルムストリップ情報（駒送りビューア）。
    pub def renderGif(cfg: RenderConfig, frames: List[w], stride: Int32,
                    toCmds: w -> (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]),
                    name: String): ReferenceSite.Filmstrip \ IO =
        renderGifFonts(cfg, Map.empty(), frames, stride, toCmds, name)

    /// 複数フォントで生成する renderGif。`extraFonts` はテクスチャ名（実機の project.json の
    /// fonts[].name に "font_" を付けた物。HeadlessFont.buildAtlas が付ける名前と同じ）→ その本。
    /// 既定フォント（cfg#fontTtf / cfg#fontAtlas）はそのまま効くので、混ぜたい本だけ渡す。
    /// 名前が実機と食い違うと、その字は既定フォントで描かれる（消えはしない）。
    pub def renderGifFonts(cfg: RenderConfig, extraFonts: Map[String, SoftRaster.FontEntry],
                         frames: List[w], stride: Int32,
                         toCmds: w -> (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd]),
                         name: String): ReferenceSite.Filmstrip \ IO =
        let sampled = every(stride, frames);
        // コマ列は同じ作りの絵が続くので、報告は先頭コマぶんだけ出す（同じ警告が何十行も並ばない）。
        List.head(sampled) |> Option.forEach(w -> warnDropped(fst(toCmds(w)), name));
        // コマ別 PNG は「描くたびに 1 枚ずつ」書く（最後に一括ではなく）— 長い生成の最中でも
        // Studio が frames/ をポーリングして、出来上がりつつあるコマを流し見できる。
        // 命名・画素は Filmstrip.renderFrames と同じ経路（renderFrame）なのでバイト列も変わらない。
        let images = List.zipWithIndex(sampled) |> List.map(pair -> {
            let (i, w) = pair;
            let (drawables, polygons) = toCmds(w);
            let img = SoftRaster.renderToImageFonts(reqOf(cfg, drawables, polygons, gifPath(cfg, name)), Nil, extraFonts);
            Filmstrip.renderFrame(img, "${cfg#outDir}/frames/${name}/${i}.png");
            img
        });
        GifEncoder.encode(images, cfg#gifDelayMs, gifPath(cfg, name));
        { strip = "frames/${name}/", frameCount = List.length(images),
          frameW = cfg#frameW, frameH = cfg#frameH, fps = cfg#gifFps }

    /// シェーダー面つきの renderGif（renderPngWith の GIF 版）。toCmds が各コマの
    /// (描き物, 多角形, シェーダー面) を返し、面は ShaderEval の画素評価で z 順に合流する。
    /// 渡す側は draw の代表色ベタ塗りと二重にならないよう、items を Render.withoutShaders で
    /// 外してから draw すること（renderPngWith と同じ決まり）。
    /// 既存 renderGif に surfaces 引数を足さないのは、面チャンネルの無い呼び元のシグネチャを
    /// 割らないため。
    pub def renderGifWith(cfg: RenderConfig, frames: List[w], stride: Int32,
                        toCmds: w -> (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd],
                                      List[SoftRaster.SurfaceCmd]),
                        name: String): ReferenceSite.Filmstrip \ IO =
        let sampled = every(stride, frames);
        // コマ列は同じ作りの絵が続くので、報告は先頭コマぶんだけ出す（renderGifFonts と同じ）。
        List.head(sampled) |> Option.forEach(w -> {
            let (drawables, _, _) = toCmds(w);
            warnDropped(drawables, name)
        });
        // 欠け名の知らせもコマ列で 1 本の控えを共有する（同じ警告がコマ数ぶん並ばない）。
        let warnLog = SoftRaster.freshTexWarnLog();
        let images = List.zipWithIndex(sampled) |> List.map(pair -> {
            let (i, w) = pair;
            let (drawables, polygons, surfaces) = toCmds(w);
            let img = SoftRaster.renderToImageLogged(reqOf(cfg, drawables, polygons, gifPath(cfg, name)),
                                                     surfaces, Map.empty(), Map.empty(), warnLog);
            Filmstrip.renderFrame(img, "${cfg#outDir}/frames/${name}/${i}.png");
            img
        });
        GifEncoder.encode(images, cfg#gifDelayMs, gifPath(cfg, name));
        { strip = "frames/${name}/", frameCount = List.length(images),
          frameW = cfg#frameW, frameH = cfg#frameH, fps = cfg#gifFps }

    /// pass つきの renderGif（renderPngWithPasses の GIF 版）。toCmds が各コマの
    /// (pass 列, 描き物, 多角形, シェーダー面) を返し、コマごとに pass を宣言順に生成してから
    /// 本編と合成する — 実機の App.withPasses と同じ順序で、後の pass は先に生成した pass の
    /// 名前を貼れる。items は本編・pass とも Render.withoutShaders → Render.draw で下ろす
    /// こと（renderPngWithPasses と同じ決まり。pass は Render.passSpecOf が外してくれる）。
    /// pass の Keep はコマをまたいで持ち越さない — 実機の Keep は前フレームの画面を
    /// 引き継ぐが、GIF は途中のコマからも見られるので、頭出しの位置で絵が変わる生成物は
    /// スナップショットに固定できない。毎コマ透明から始める（静止画の renderPngWithPasses と同じ）。
    pub def renderGifWithPasses(cfg: RenderConfig, frames: List[w], stride: Int32,
                              toCmds: w -> (List[PassSpec], List[GameEngine.Drawable],
                                            List[GameEngine.PolygonRenderCmd],
                                            List[SoftRaster.SurfaceCmd]),
                              name: String): ReferenceSite.Filmstrip \ IO =
        let sampled = every(stride, frames);
        // コマ列は同じ作りの絵が続くので、報告は先頭コマぶんだけ出す（renderGifWith と同じ）。
        List.head(sampled) |> Option.forEach(w -> {
            let (passes, drawables, _, _) = toCmds(w);
            passes |> List.forEach(p -> warnDropped(p#drawables, "${name}:pass ${p#name}"));
            warnDropped(drawables, name)
        });
        // 欠け名の知らせもコマ列で 1 本の控えを共有する（同じ警告がコマ数ぶん並ばない）。
        let warnLog = SoftRaster.freshTexWarnLog();
        let images = List.zipWithIndex(sampled) |> List.map(pair -> {
            let (i, w) = pair;
            let (passes, drawables, polygons, surfaces) = toCmds(w);
            let passImages = passes |> List.foldLeft((acc, p) -> {
                Map.insert(p#name, renderPassImageWith(cfg, acc, p, None), acc)
            }, (Map.empty(): Map[String, BufferedImage]));
            let img = SoftRaster.renderToImageLogged(reqOf(cfg, drawables, polygons, gifPath(cfg, name)),
                                                     surfaces, Map.empty(), passImages, warnLog);
            Filmstrip.renderFrame(img, "${cfg#outDir}/frames/${name}/${i}.png");
            img
        });
        GifEncoder.encode(images, cfg#gifDelayMs, gifPath(cfg, name));
        { strip = "frames/${name}/", frameCount = List.length(images),
          frameW = cfg#frameW, frameH = cfg#frameH, fps = cfg#gifFps }

    /// stride 枚ごとに 1 枚を残す（0 番から）。
    pub def every(stride: Int32, xs: List[a]): List[a] =
        List.zipWithIndex(xs)
            |> List.filterMap(pair -> { let (i, x) = pair; if (Int32.modulo(i, stride) == 0) Some(x) else None })

}
