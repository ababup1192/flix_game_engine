// SoftRaster — GameEngine.Drawable / PolygonRenderCmd を Java2D で 1 枚の PNG に描き出す
// ソフトウェアラスタライザ。GL を使わないので GL コンテキストの無い場所（スナップショット
// テスト、将来の IDE ビューポートのプレビュー）で描画結果を目視確認できる。
//
// 描画規約（box/textured/font/polygon の扱い、z 順）は render_gl/Frame.drawSprite と
// 一致させてある — 各関数のコメントに規約を記す。design を `scale` 倍に拡大して出力する。
pub mod SoftRaster {
    import java.awt.image.BufferedImage
    import java.awt.image.ImageObserver
    import java.awt.Graphics2D
    import java.awt.{Color => AwtColor}
    import java.awt.Font
    import java.awt.geom.{Path2D$Double => Path2D}
    import java.awt.geom.{RoundRectangle2D$Double => RoundRect}
    import java.awt.geom.{Line2D$Double => Line2D}
    import java.awt.geom.{Rectangle2D$Double => Rect2D}
    import java.io.File
    import java.lang.System
    import java.lang.{Character => JChar}
    import java.lang.{Object => JObject}
    import java.util.concurrent.ConcurrentHashMap
    import java.util.function.IntConsumer
    import java.util.function.IntUnaryOperator
    import java.util.stream.IntStream
    import javax.imageio.ImageIO

    /// ラスタライズ要求。design 解像度の Drawable 群を `scale` 倍に拡大して `outPath` に PNG 出力。
    /// `texturePath` は DrawCmd.DrawableSpec#texture 名 → PNG ファイルパス。フォント（`font_` テクスチャ）は
    /// アトラス PNG をサンプルせず、`fontTtf` の TTF を出力解像度サイズへ deriveFont して直接
    /// drawString する。グリフ Drawable から元文字を引くため `fontAtlas`（uvOffset↔codepoint の対応）を使う。
    /// `shapeAntialias` は面の縁（fillRoundRect / fillPolygon）のなめらかさ。
    /// **画素の格子に乗せる絵（ドット絵）では false にする** — true のままだと宣言した
    /// パレットに無い中間色が縁に湧く（実測: 宣言 13 色の一人称の画面が PNG では 2884 色）。
    ///
    /// `textAntialias` は文字の縁と送り幅。こちらは**可読性**のつまみで、面とは理由が違う —
    /// 7px の TTF は縁をならさないと字が潰れる。ドット絵のキャラと小さい TTF が同じ画面に
    /// 出るゲーム（ノベル・RPG）は `shapeAntialias = false` / `textAntialias = true` にする。
    ///
    /// `scenes` は 3D の場面（SoftRaster3d が深度つきで塗る）。2D の描き物と同じ z の並びに入り、同じ z では Shader 面の後に描く。
    /// 3D を使わない絵は Nil。
    pub type alias RasterReq = {
        drawables = List[GameEngine.Drawable],
        polygons = List[GameEngine.PolygonRenderCmd],
        design = Vec2.Vec2,
        scale = Int32,
        background = Color,
        texturePath = Map[String, String],
        fontTtf = String,
        fontAtlas = FontAtlas,
        outPath = String,
        shapeAntialias = Bool,
        textAntialias = Bool,
        scenes = List[Scene3d.RenderCmd]
    }

    /// 描画品質ヒントの 2 つ組（面の縁 / 文字の縁と送り幅）。本体と下書き（blendedDraw）へ
    /// 同じ組を渡して、重ね方の違いで見た目が変わらないようにする。
    type alias QualityHints = { shapes = Bool, text = Bool }

    def hintsOf(req: RasterReq): QualityHints =
        { shapes = req#shapeAntialias, text = req#textAntialias }

    /// 追加フォント 1 本（既定フォント以外も混ぜて描き出すとき）。ttf = 実サイズ描き出し用の TTF、
    /// atlas = その TTF から HeadlessFont.buildAtlas で組んだメトリクス。
    pub type alias FontEntry = { ttf = String, atlas = FontAtlas }

    /// 字の縁を本ごとに決める表（テクスチャ名 "font_…" → ならすか）。表に無い本は絵全体の RasterReq#textAntialias に従う
    /// （ドット絵の本だけ切る時に Map#{"font_pixel" => false}）。
    /// WhyNot: FontEntry の欄にしない — `{ ttf, atlas }` と書いている今のゲームがコンパイルできなくなるため。
    pub type alias FontAntialias = Map[String, Bool]

    /// フォントグリフを直接 drawString するための描画コンテキスト。
    /// `baseFont` は素の TTF Font（サイズは deriveFont でグリフ毎に決める）。
    /// `atlas` はメトリクス（ascent/textureSize/bake fontSize）。
    /// `codepointByCell` は `(セル左上 px x, y) → Unicode codepoint`。グリフ Drawable の uvOffset は
    /// アトラスのセル s0/t0 と同一なので、これで元文字へ逆引きできる。
    type alias FontCtx = {
        baseFont = Font,
        atlas = FontAtlas,
        codepointByCell = Map[(Int32, Int32), Int32]
    }

    /// 使えるフォント一式。`primary` は既定（req#fontTtf / req#fontAtlas）、`byTexture` は
    /// テクスチャ名（"font_ui" / "font_girl" …）→ その本。セル座標 → codepoint の逆引き表は
    /// フォントごとに違う（別のフォントでも同じセルから詰まるので混ぜられない）ので、
    /// グリフを描く直前に DrawCmd.DrawableSpec#texture でこの表から 1 本選ぶ。
    /// 知らないテクスチャ名は primary を使う（fail-open — 字が消えるより既定で出るほうがよい）。
    /// `antialiasByTexture` は字の縁を本ごとに決めた物だけ（FontAntialias の表）。
    type alias FontTable = { primary = FontCtx, byTexture = Map[String, FontCtx], antialiasByTexture = Map[String, Bool] }

    /// 宣言シェーダー面 1 枚の headless ラスタライズ要求（Render.ShaderSurface と同形の
    /// 構造レコード — GL の program ハンドルを持たない純データ）。ShaderEval で画素ごとに
    /// 評価して描き出す。mask が非空なら多角形の内側だけ塗る（GL のステンシルと同じ意図）。
    pub type alias SurfaceCmd = {
        rect = Rect2.Rect2,
        spec = ShaderDoc.Spec,
        time = Float64,
        mask = List[List[Vec2.Vec2]],
        zIndex = Int32,
        blend = DrawCmd.BlendMode
    }

    /// 描き出した Pass の 1 枚（case の名前は RenderTarget.Format と同じ）。Rgba8Unorm = Java2D の画像・
    /// Rgba16Float = 1 を超える値を持つ絵（ShaderEval.HdrTexture と同じ物 — 面の tex / blur へ写さずに渡す）。
    /// 面の tex / blur は Rgba16Float を切らずに読み、sprite・3D の材質・ビルボードは 0..1 に切ってから読む（toArgbImage）。
    pub enum PassImage {
        case Rgba8Unorm(BufferedImage)
        case Rgba16Float(ShaderEval.HdrTexture)
    }

    /// 描いている途中の Rgba16Float の 1 枚（1 画素に r, g, b, α の 4 つ・行優先・値はいつも half に丸めてある）。
    /// WhyNot: float の BufferedImage（DataBufferFloat）に描かない — Java2D の合成は描き先を int の ARGB に読み直すので、1 を超えた値が何も知らせずに消える。
    type alias HdrCanvas = { width = Int32, height = Int32, rgba = Array[Float64, Static] }

    /// 描き物 1 件（z 合流用の内部タグ）。Drawable / Polygon / シェーダー面を
    /// 1 列に混ぜて (zIndex, 追加順) で安定ソートするための包み。
    enum RItem {
        case RDraw(DrawCmd.DrawableSpec)
        case RPoly(GameEngine.PolygonRenderCmd)
        case RSurf(SurfaceCmd)
        case RScene(Scene3d.RenderCmd)
    }

    // ════════════════════════════════════════════════════════
    // この経路が描けない指定（描き出す前に知らせるための照会）
    // ════════════════════════════════════════════════════════

    /// 「絵に出ない指定」1 種類ぶんの報告。attr は指定の名前、count は件数、hint は逃げ道。
    pub type alias Dropped = { attr = String, count = Int32, hint = String }

    /// この経路が描けずに落とす指定を数える（純粋・描き出す前に呼べる）。
    /// GL の描画規約と揃っていない属性はここに 1 行足すこと — 黙って落とすと、描き出した絵と実機の絵が
    /// 食い違ったままスナップショットに固定され、「絵は正しい」という嘘が残る。
    /// 対応表は docs/backend-parity.md。
    pub def dropped(ds: List[GameEngine.Drawable]): List[Dropped] =
        let styledSprite = ds |> List.count(d ->
            not String.isEmpty(DrawCmd.textureOf(d))
                and not String.startsWith({prefix = "font_"}, DrawCmd.textureOf(d))
                and not Option.isEmpty(DrawCmd.styleOf(d)));
        let styledGlyph = ds |> List.count(d ->
            String.startsWith({prefix = "font_"}, DrawCmd.textureOf(d))
                and not Option.isEmpty(DrawCmd.styleOf(d)));
        List.filter(x -> x#count > 0,
            ({ attr = "style on textured sprite", count = styledSprite,
               hint = "角丸・枠・縞・市松は単色の box にだけ描ける。スプライトの枠は box を重ねて作る" }: Dropped) ::
            ({ attr = "style on text", count = styledGlyph,
               hint = "文字は出力解像度の TTF で直接描くので style は乗らない" }: Dropped) :: Nil)

    /// 報告を 1 行の文へ（呼び出し側がそのまま出せる形）。
    pub def droppedLine(x: Dropped): String =
        "[render] 描き出せない指定: ${x#attr} ×${x#count} — ${x#hint}"

    /// 要求を 1 枚の PNG に描き出して書き出す。PNG を書く render* は RenderCache を通る
    /// （同じ鍵の絵がキャッシュにあれば塗らずに写す。バイト列は塗った時と同じ）。
    pub def render(req: RasterReq): Unit \ IO =
        RenderCache.writePlainPng(req, Nil, Map.empty(), Map.empty())

    /// 追加フォントつきの render。`extraFonts` はテクスチャ名（"font_girl" など。実機の
    /// project.json の fonts[].name に "font_" を付けた物）→ その本。既定フォント
    /// （req#fontTtf / req#fontAtlas）はそのまま効くので、混ぜたい本だけ渡せばよい。
    pub def renderFonts(req: RasterReq, extraFonts: Map[String, FontEntry]): Unit \ IO =
        RenderCache.writePlainPng(req, Nil, extraFonts, Map.empty())

    /// シェーダー面つきの render（面は ShaderEval で画素評価して z 順に合流する）。
    pub def renderWithSurfaces(req: RasterReq, surfaces: List[SurfaceCmd]): Unit \ IO =
        RenderCache.writePlainPng(req, surfaces, Map.empty(), Map.empty())

    /// 追加の描き出し済み画像（pass のレンダーターゲットなど）も混ぜて描き、PNG に書き出す render。
    pub def renderFull(req: RasterReq, surfaces: List[SurfaceCmd],
                       extraFonts: Map[String, FontEntry],
                       extraImages: Map[String, PassImage]): Unit \ IO =
        RenderCache.writePlainPng(req, surfaces, extraFonts, extraImages)

    /// 要求を 1 枚の BufferedImage に描き出して返す（PNG 書き出しはしない）。
    /// PNG スナップショット（render）と GIF アニメ（GifEncoder が 1 フレームずつ集める）の
    /// 共有ラスタライズ経路。`outPath` は使わない。
    pub def renderToImage(req: RasterReq): BufferedImage \ IO =
        renderToImageWith(req, Nil)

    /// renderToImage のシェーダー面つき版。surfaces は Drawable / Polygon と同じ
    /// (zIndex, 追加順) の安定ソートに合流する（面より手前の物は面の上に描かれる —
    /// GL 経路の renderFrameMixed と同じ z 合流の意図）。
    pub def renderToImageWith(req: RasterReq, surfaces: List[SurfaceCmd]): BufferedImage \ IO =
        renderToImageFonts(req, surfaces, Map.empty())

    /// renderToImageWith の複数フォント版。`extraFonts` はテクスチャ名 → 追加の本。
    /// グリフはテクスチャ名で本を選んで描く（知らない名前は既定フォントへ落とす）。
    pub def renderToImageFonts(req: RasterReq, surfaces: List[SurfaceCmd],
                               extraFonts: Map[String, FontEntry]): BufferedImage \ IO =
        renderToImageFull(req, surfaces, extraFonts, Map.empty())

    /// renderToImageFonts の「追加の描き出し済み画像」つき版。`extraImages` はテクスチャ名 →
    /// 描き出した BufferedImage（pass のレンダーターゲットなど、ファイルに落とさず直接混ぜたい絵）。
    /// texturePath の読み込み結果へ上書き合流する（同名は extraImages が勝つ — ファイルの
    /// 古い絵より、いま描き出したばかりの絵のほうが実機に近い）。
    pub def renderToImageFull(req: RasterReq, surfaces: List[SurfaceCmd],
                              extraFonts: Map[String, FontEntry],
                              extraImages: Map[String, PassImage]): BufferedImage \ IO =
        renderToImageLogged(req, surfaces, extraFonts, extraImages, freshTexWarnLog())

    /// tex 場の欠け名を知らせた控え。GIF などコマ列の描き出しで同じ物を渡し続けると、
    /// 同じ名前の知らせがコマ数ぶん並ばない（GL 側の missingSurfaceTexRef と同じ「一度だけ」）。
    pub type alias TexWarnLog = Ref[Set[String], Static]

    /// 欠け名の控えを新しく作る（コマ列の描き出しの前に 1 本作って持ち回る）。
    pub def freshTexWarnLog(): TexWarnLog \ IO = Ref.fresh(Static, Set.empty())

    /// テクスチャが登録されていない Drawable を飛ばしたことを、名前ごとに 1 度だけ知らせる。
    /// 文面は GL 経路（render_gl の Frame.flix）と 1 字も変えない — 同じ壊れ方が別の字で
    /// 出ると、実機と描き出しのどちらで起きたのかを grep で束ねられなくなる。
    def warnMissingTexture(warnLog: TexWarnLog, name: String): Unit \ IO =
        let warned = Ref.get(warnLog);
        if (Set.memberOf(name, warned)) ()
        else {
            Ref.put(Set.insert(name, warned), warnLog);
            Log.warn("texture '${name}' が見つからない — 描かない"
                + "（project.json の textures に同名の宣言があるか確認）")
        }

    /// renderToImageFull の欠け名控えつき版。控えは知らせの回数にだけ効き、
    /// 描き出す画素には一切影響しない（バイト一致はそのまま）。
    pub def renderToImageLogged(req: RasterReq, surfaces: List[SurfaceCmd],
                                extraFonts: Map[String, FontEntry],
                                extraImages: Map[String, PassImage],
                                warnLog: TexWarnLog): BufferedImage \ IO =
        renderToImageWithCache(req, surfaces, extraFonts, Map.empty(), extraImages, warnLog, None)

    /// texturePath の画像を 1 回だけ読むためのキャッシュ（ファイルのパス → ARGB にそろえた画像）。
    /// コマ列（動画 1 本・ギャラリー 1 周）の前に 1 本作って持ち回ると、2 コマ目からは
    /// ファイルを読まない。スレッドをまたいで共有してよい（読むだけ・同じ物を 2 回入れても同じ絵）。
    /// 寿命は 1 回の描き出しの間だけにする — 長く持つと、保存し直した絵に気づかない。
    /// 読めなかったファイルは控えない（次のコマでまた探す・今と同じ振る舞い）。
    /// 2 つ目の表は RenderCache が使う、読んだ画像の画素の指紋（パス → SHA-256）。鍵と塗りが同じ画像を
    /// 見るよう、指紋は必ずこの表の画像から取る。
    /// 3 つ目の表はフォント（TTF のパス → 読んだ Font とアトラスごとのグリフの逆引き表）。1 枚描くたびに
    /// TTF を読み直して表を組み直すと、ギャラリー 1 周で数秒になる。寿命は画像と同じ。
    /// 4 つ目の表は 3D の材質が読む絵の段（Mip.build。鍵は "tex3d:" + Texture3d の contentHash か、"file:" + パス + 更新時刻）。
    pub enum TextureCache(ConcurrentHashMap[String, BufferedImage], ConcurrentHashMap[String, String],
                          ConcurrentHashMap[String, List[FontCtx]], ConcurrentHashMap[String, Vector[ShaderEval.TexData]])

    /// 空のキャッシュを作る（コマ列の描き出しの前に 1 本）。
    pub def freshTextureCache(): TextureCache \ IO =
        TextureCache.TextureCache(new ConcurrentHashMap(), new ConcurrentHashMap(), new ConcurrentHashMap(), new ConcurrentHashMap())

    /// キャッシュからパスの画像を引く（無ければ読んで入れる。読み方は塗る時と同じ）。無い・読めないなら None。
    pub def cachedTexture(cache: TextureCache, path: String): Option[BufferedImage] \ IO =
        let TextureCache.TextureCache(table, _, _, _) = cache;
        let hit: BufferedImage = table.get(path);
        if (not Object.isNull(hit)) Some(hit)
        else match loadTexture(path) {
            case Some(img) => { discard table.putIfAbsent(path, img); Some(table.get(path)) }
            case None      => None
        }

    /// renderToImageLogged のテクスチャキャッシュつき版。画素は renderToImageLogged と 1 バイトも
    /// 変わらない（読む画像が同じで、読む回数だけが減る）。
    pub def renderToImageCached(req: RasterReq, surfaces: List[SurfaceCmd],
                                extraFonts: Map[String, FontEntry],
                                extraImages: Map[String, PassImage],
                                warnLog: TexWarnLog, cache: TextureCache): BufferedImage \ IO =
        renderToImageWithCache(req, surfaces, extraFonts, Map.empty(), extraImages, warnLog, Some(cache))

    /// renderToImageCached の、字の縁を本ごとに決める表つき版（表に無い本は絵全体の設定）。
    pub def renderToImageCachedAntialias(req: RasterReq, surfaces: List[SurfaceCmd],
                                         extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                                         extraImages: Map[String, PassImage],
                                         warnLog: TexWarnLog, cache: TextureCache): BufferedImage \ IO =
        renderToImageWithCache(req, surfaces, extraFonts, fontAntialias, extraImages, warnLog, Some(cache))

    def renderToImageWithCache(req: RasterReq, surfaces: List[SurfaceCmd],
                               extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                               extraImages: Map[String, PassImage],
                               warnLog: TexWarnLog, cache: Option[TextureCache]): BufferedImage \ IO =
        HeadlessFont.ensureHeadless();
        let (w, h) = outSize(req);
        let image = new BufferedImage(w, h, 2i32);
        fillClear(image, req#background);
        SoftRaster.Internal.DrawList.drawAllInto(image, req, surfaces, extraFonts, fontAntialias, extraImages, warnLog, cache, None);
        image

    /// image 全面を c の不透明で塗る（画面の clearColor と LoadOp.Clear の塗りはどれもこれを通す）。
    pub def fillClear(image: BufferedImage, c: Color): Unit \ IO =
        let g: Graphics2D = image.createGraphics();
        g.setColor(awtColor(c, 1.0f32));
        g.fillRect(0i32, 0i32, image.getWidth(), image.getHeight());
        g.dispose()

    /// pass（レンダーターゲット）描き出し用の入口（Rgba8Unorm・等倍）。req#background は使わない — 塗るかどうか
    /// （clearColor）の判断は呼び出し側（HeadlessRender）が持つので、ここで塗ると判断が二重になる。
    /// `base` が Some ならその画像のコピーの上に描き足す（呼び出し側の画像は変異させない —
    /// 前フレームの中身は残像の証拠としてそのまま残したい）、None なら全画素透明から始める。
    pub def renderPassImage(req: RasterReq, base: Option[BufferedImage],
                            extraImages: Map[String, PassImage]): BufferedImage \ IO =
        renderPassImageFonts(req, base, Nil, Map.empty(), Map.empty(), extraImages)

    /// 追加フォントとシェーダー面も使える renderPassImage（pass の中の字を、本編と同じ本で描く）。
    pub def renderPassImageFonts(req: RasterReq, base: Option[BufferedImage], surfaces: List[SurfaceCmd],
                                 extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                                 extraImages: Map[String, PassImage]): BufferedImage \ IO =
        toArgbImage(renderPass({ format = RenderTarget.Format.Rgba8Unorm, base = Option.map(PassImage.Rgba8Unorm, base),
                                   clear = None, texels = None }, req, surfaces, extraFonts, fontAntialias, extraImages))

    /// Pass 1 枚の描き方。format = 描き先の形式。base = 前の中身（Keep。texels が Some ならテクセル寸法の絵・None ならそのままの寸法で写す）。
    /// clear = LoadOp.Clear の色（Some なら base を見ずにその色の不透明で塗ってから描く。Rgba16Float では 1 を超える色も切らない）。
    /// texels = 縮んだターゲットのテクセル寸法（Some なら design で描いて GL がテクセルを塗る点で拾い、面はその点で評価する。戻りはテクセル寸法）。
    pub type alias PassDraw = { format = RenderTarget.Format, base = Option[PassImage], clear = Option[Color],
                                texels = Option[(Int32, Int32)] }

    /// Pass 1 枚を how の決まりで描き出す（HeadlessRender が Pass ごとに呼ぶ入口）。
    pub def renderPass(how: PassDraw, req: RasterReq, surfaces: List[SurfaceCmd],
                         extraFonts: Map[String, FontEntry], fontAntialias: FontAntialias,
                         extraImages: Map[String, PassImage]): PassImage \ IO =
        HeadlessFont.ensureHeadless();
        let (w, h) = outSize(req);
        let start = match (how#clear, how#base, how#texels) {
            case (Some(_), _, _)           => None
            case (None, Some(b), Some(_))  => Some(resampleNearestPass(b, w, h))
            case (None, Some(b), None)     => Some(b)
            case (None, None, _)           => None
        };
        let warnLog = freshTexWarnLog();
        let drawn = match how#format {
            case RenderTarget.Format.Rgba8Unorm =>
                let image = match start {
                    case Some(b) => toArgb(toArgbImage(b))
                    case None    => new BufferedImage(w, h, 2i32)
                };
                how#clear |> Option.forEach(fillClear(image));
                SoftRaster.Internal.DrawList.drawAllInto(image, req, surfaces, extraFonts, fontAntialias, extraImages, warnLog, None, how#texels);
                PassImage.Rgba8Unorm(image)
            case RenderTarget.Format.Rgba16Float =>
                let canvas = match start {
                    case Some(b) => SoftRaster.Internal.Hdr.hdrCanvasOf(b)
                    case None    => SoftRaster.Internal.Hdr.blankHdrCanvas(w, h)
                };
                how#clear |> Option.forEach(SoftRaster.Internal.Hdr.fillClearHdr(canvas));
                SoftRaster.Internal.DrawList.drawAllIntoHdr(canvas, req, surfaces, extraFonts, fontAntialias, extraImages, warnLog, how#texels);
                PassImage.Rgba16Float(SoftRaster.Internal.Hdr.freezeHdr(canvas))
        };
        match how#texels {
            case Some((tw, th)) => resampleNearestPass(drawn, tw, th)
            case None           => drawn
        }

    /// 出力ピクセル寸法（design × scale、最低 1px）。
    pub def outSize(req: RasterReq): (Int32, Int32) =
        let sf = Int32.toFloat64(req#scale);
        (Int32.max(1i32, ri(req#design#x * sf)), Int32.max(1i32, ri(req#design#y * sf)))

    /// テクセルの中心 center（design px）を塗る画素。横は floor・縦は「ちょうど画素の境目なら上の画素」。
    /// WhyNot: 縦も floor にしない — GL のターゲットは上下逆に格納されるので、標本点がちょうど縁に乗った時に
    /// 含めるのは design の下の縁（窓座標で上の縁）の側になる。floor だと奇数座標の縁で 1 行ずれる（gl_parity の passHalf）。
    def pickedPixel(center: Float64, vertical: Bool): Float64 =
        if (vertical) Float64.ceil(center) - 1.0 else Float64.floor(center)

    /// tex 場が読む縮んだターゲットのテクセルの絵の名前（sprite で貼る design 寸法の絵と並べて images に入れる）。
    /// '@' は Pass の名前に使えない（Render.resolvePassReads）ので、ゲームの名前と混ざらない。
    pub def texelsName(name: String): String = name + "@texels"

    /// img を w × h へ最近傍で写す。広げるとき（GL が Nearest で貼る式）は元の (floor((x+0.5)·元幅/w), floor((y+0.5)·元高/h))。
    /// 縮めるとき（GL が縮んだターゲットのテクセルを塗る点を拾う）は縦だけ pickedPixel の「境目なら上」。往復で元に戻る。
    pub def resampleNearest(img: BufferedImage, w: Int32, h: Int32): BufferedImage \ IO = region rc {
        let sw = img.getWidth();
        let sh = img.getHeight();
        let src: Array[Int32, rc] = Array.empty(rc, sw * sh);
        discard img.getRGB(0i32, 0i32, sw, sh, src, 0i32, sw);
        let out: Array[Int32, rc] = Array.empty(rc, w * h);
        List.range(0, h) |> List.forEach(y -> {
            let sy = nearestPick(y, h, sh, true);
            List.range(0, w) |> List.forEach(x -> Array.put(Array.get(sy * sw + nearestPick(x, w, sw, false), src), y * w + x, out))
        });
        let dest = new BufferedImage(w, h, 2i32);
        dest.setRGB(0i32, 0i32, w, h, out, 0i32, w);
        dest
    }

    /// 写した先の画素 o（0..n−1）が拾う元の画素（0..srcN−1）。resampleNearest の doc の式。
    def nearestPick(o: Int32, n: Int32, srcN: Int32, vertical: Bool): Int32 =
        let center = (Int32.toFloat64(o) + 0.5) * Int32.toFloat64(srcN) / Int32.toFloat64(n);
        let at = if (n < srcN) pickedPixel(center, vertical) else Float64.floor(center);
        Int32.max(0, Int32.min(srcN - 1, Float64.tryToInt32(at) |> Option.getWithDefault(0)))

    /// resampleNearest の PassImage 版（形式は変えない）。同じ寸法ならそのまま返す。
    pub def resampleNearestPass(img: PassImage, w: Int32, h: Int32): PassImage \ IO =
        match img {
            case PassImage.Rgba8Unorm(argb) =>
                if (argb.getWidth() == w and argb.getHeight() == h) img else PassImage.Rgba8Unorm(resampleNearest(argb, w, h))
            case PassImage.Rgba16Float(hdr) =>
                let sw = ShaderEval.hdrWidthOf(hdr);
                let sh = ShaderEval.hdrHeightOf(hdr);
                if (sw == w and sh == h) img
                else {
                    let out: Array[Float64, Static] = Array.repeat(Static, Int32.max(1, w * h) * 4, 0.0);
                    forEachPixel(w * h * 4, k -> {
                        let i = k / 4;
                        let picked = (nearestPick(i / w, h, sh, true) * sw + nearestPick(Int32.remainder(i, w), w, sw, false)) * 4;
                        Array.put(ShaderEval.hdrChannelOf(hdr, picked + Int32.remainder(k, 4)), k, out)
                    });
                    PassImage.Rgba16Float(ShaderEval.hdrTextureOf(w, h, Array.toVector(out)))
                }
        }

    // ════════════════════════════════════════════════════════
    // Rgba16Float の Pass（1 を超える値を持つ描き先）
    // ════════════════════════════════════════════════════════

    /// Pass の絵の寸法（テクセルの数）。
    pub def passImageSize(img: PassImage): (Int32, Int32) \ IO =
        match img {
            case PassImage.Rgba8Unorm(argb)  => (argb.getWidth(), argb.getHeight())
            case PassImage.Rgba16Float(hdr) => (ShaderEval.hdrWidthOf(hdr), ShaderEval.hdrHeightOf(hdr))
        }

    /// Pass の絵の 8bit の形（Rgba8Unorm はそのまま・Rgba16Float は各成分を 0..1 に切って 8bit に丸める）。
    /// sprite・3D の材質・ビルボードが Rgba16Float の Pass を読む時と、PNG に書く時に使う。
    pub def toArgbImage(img: PassImage): BufferedImage \ IO =
        match img {
            case PassImage.Rgba8Unorm(argb)  => argb
            case PassImage.Rgba16Float(hdr) =>
                let w = ShaderEval.hdrWidthOf(hdr);
                let h = ShaderEval.hdrHeightOf(hdr);
                let out: Array[Int32, Static] = Array.repeat(Static, w * h, 0);
                forEachPixel(w * h, i -> {
                    let at = c -> ShaderEval.hdrChannelOf(hdr, i * 4 + c);
                    Array.put(argbOfRgba(at(0), at(1), at(2), at(3)), i, out)
                });
                let image = new BufferedImage(w, h, 2i32);
                image.setRGB(0i32, 0i32, w, h, out, 0i32, w);
                image
        }

    /// 画素 i の 4 つを書く。
    def putHdr(rgba: Array[Float64, r], i: Int32, px: (Float64, Float64, Float64, Float64)): Unit \ r =
        let (pr, pg, pb, pa) = px;
        let k = i * 4;
        Array.put(pr, k, rgba);
        Array.put(pg, k + 1, rgba);
        Array.put(pb, k + 2, rgba);
        Array.put(pa, k + 3, rgba)

    /// Rgba16Float の描き先の画素 i へ src (sr, sg, sb, sa) を blend で混ぜ、half に丸めて書く。sa は 0..1。
    /// 式は GL の glBlendFunc と同じで、rgb は切らずに混ぜ、α にも同じ 2 つの因子を掛ける（α の 1 つ目の因子は rgb と同じ — Multiply の DST_COLOR は dst の α）:
    ///   Normal   : rgb = s·a + d·(1−a)          α = a·a + dA·(1−a)
    ///   Add      : rgb = d + s·a                α = a·a + dA
    ///   Multiply : rgb = d·(1 − a·(1−s))        α = a·dA + dA·(1−a)（= dA）
    /// 8bit の blendPixel と違い dst の α を残さない（Add は α を溜めるが、読む所で 0..1 に切る）。
    /// 混ぜた後は切らないので、Add を重ねて 65504 を超えた rgb は half の無限大になる（GPU の Rgba16Float の描き先と同じ）。
    pub def blendPixelF(blend: DrawCmd.BlendMode, sr: Float64, sg: Float64, sb: Float64, sa: Float64,
                        rgba: Array[Float64, r], i: Int32): Unit \ r =
        let k = i * 4;
        let (dr, dg, db, da) = (Array.get(k, rgba), Array.get(k + 1, rgba), Array.get(k + 2, rgba), Array.get(k + 3, rgba));
        let out = match blend {
            case DrawCmd.BlendMode.Normal   =>
                (sr * sa + dr * (1.0 - sa), sg * sa + dg * (1.0 - sa), sb * sa + db * (1.0 - sa), sa * sa + da * (1.0 - sa))
            case DrawCmd.BlendMode.Add      =>
                (dr + sr * sa, dg + sg * sa, db + sb * sa, sa * sa + da)
            case DrawCmd.BlendMode.Multiply =>
                (dr * (1.0 - sa * (1.0 - sr)), dg * (1.0 - sa * (1.0 - sg)), db * (1.0 - sa * (1.0 - sb)), sa * da + da * (1.0 - sa))
        };
        let (nr, ng, nb, na) = out;
        putHdr(rgba, i, (ShaderEval.roundToHalf(nr), ShaderEval.roundToHalf(ng), ShaderEval.roundToHalf(nb), ShaderEval.roundToHalf(na)))

    /// 画素 0..n−1 を pixelFn で塗る（Rgba16Float の描き先へ直に書く）。画素は互いの値を読まないので、shadeAll と同じく
    /// Java の並列ストリームでコアの数だけ並べる（FGE_SOFT_SERIAL=1 なら 1 本）。
    def forEachPixel(n: Int32, pixelFn: Int32 -> Unit \ IO): Unit \ IO =
        let serial = System.getenv("FGE_SOFT_SERIAL");
        let range = IntStream.range(0i32, n);
        let stream = if (not Object.isNull(serial) and serial == "1") range else range.parallel();
        stream.forEach(new IntConsumer {
            def accept(_this: IntConsumer, i: Int32): Unit \ IO = pixelFn(i)
        })

    // ════════════════════════════════════════════════════════
    // 画素の道具（SoftRaster.Internal.* の描き手も使う）
    // ════════════════════════════════════════════════════════

    /// 画素ループの外で 1 回だけ計算した値を、そのまま返す。
    /// WhyNot: 面ごとの値を `let x = 式` で直に置かない。Flix 0.78 の最適化は、純粋な let の値が
    /// ラムダの中で 1 回だけ使われると、その式をラムダの中へ書き写す（@DontInline でも止まらない）。
    /// すると Spec の組み直しや record の読み出しが画素ごとに走る。Ref を通した値は純粋でないので
    /// 動かされない。
    def onceOutsideLoop(rc: Region[r], x: a): a \ r = Ref.get(Ref.fresh(rc, x))

    /// 画素 0..n−1 を pixelOf で塗った ARGB の列。Java の並列ストリームでコアの数だけ並べて
    /// 評価する（区間の割り方とスレッドは JDK の共有プールに任せる・どれかの画素が例外を投げれば
    /// そのまま呼び元へ伝わる）。画素は互いに読まないので、並べても 1 本で回しても同じ列になる。
    /// 環境変数 FGE_SOFT_SERIAL=1 なら 1 本で評価する（速さを比べるとき・コアを空けたいとき）。
    def shadeAll(n: Int32, pixelOf: Int32 -> Int32): Array[Int32, Static] \ IO =
        // WhyNot: 引数で受けない — 並べても 1 本でも同じ列になる（出力に効かない調子の旗）ので、常駐で起こした時の
        // 値が見えても答えは変わらない。引数に通すと描き出しの pub の口の型がいくつも変わる。
        let serial = System.getenv("FGE_SOFT_SERIAL");
        let range = IntStream.range(0i32, n);
        let stream = if (not Object.isNull(serial) and serial == "1") range else range.parallel();
        stream.map(new IntUnaryOperator {
            def applyAsInt(_this: IntUnaryOperator, i: Int32): Int32 = pixelOf(i)
        }).toArray()

    /// BufferedImage を ShaderEval の画素表（ARGB・行優先・正立）へ 1 回で写す。
    def texDataOf(img: BufferedImage): ShaderEval.TexData \ IO = region rc {
        let w = Int32.max(1i32, img.getWidth());
        let h = Int32.max(1i32, img.getHeight());
        let buf: Array[Int32, rc] = Array.empty(rc, w * h);
        discard img.getRGB(0i32, 0i32, w, h, buf, 0i32, w);
        { width = w, height = h, pixels = Array.toVector(buf) }
    }

    /// 色の成分 r, g, b（0..1）と alpha（0..1）を ARGB int へ。画素ごとに呼ぶ所（シェーダー面・
    /// 頂点色の多角形・3D の層）で使うので、Color の record ではなく成分で受ける。
    /// 1 を超える値・無限大は 255、0 未満と NaN は 0（byteOf）。
    pub def argbOfRgba(r: Float64, g: Float64, b: Float64, a: Float64): Int32 =
        Int32.leftShift(byteOf(f32(a)), 24)
            |> Int32.bitwiseOr(Int32.leftShift(byteOf(f32(r)), 16))
            |> Int32.bitwiseOr(Int32.leftShift(byteOf(f32(g)), 8))
            |> Int32.bitwiseOr(byteOf(f32(b)))

    /// ARGB 1 画素の合成（src を dst に重ねた結果。out の alpha は dst のまま —
    /// 描き出しの出力は背景が不透明で埋まっているため）。式は DrawCmd.BlendMode の doc と
    /// GL 側（RenderSprite.applyBlend + シェーダの premultiply）に一致させてある:
    ///   Normal   : out = (src×a + dst×(255−a)) / 255           （SrcOver）
    ///   Add      : out = min(255, dst + src×a/255)             （明るく足す・クランプ）
    ///   Multiply : out = dst×(255 − a×(255−src)/255) / 255     （白は素通し・黒は黒・a=0 で恒等）
    /// WhyNot: 3 つの式を閉包で渡して 1 つの関数に通さない — 画素ごとに閉包を作って呼ぶ分が、
    /// 合成の計算そのものより重い（JFR で描き出しの約 1 割）。合成の種類ごとに式を書き下す。
    pub def blendPixel(blend: DrawCmd.BlendMode, srcArgb: Int32, dstArgb: Int32): Int32 =
        let a = channelOf(24, srcArgb);
        let sr = channelOf(16, srcArgb);
        let sg = channelOf(8, srcArgb);
        let sb = channelOf(0, srcArgb);
        let dr = channelOf(16, dstArgb);
        let dg = channelOf(8, dstArgb);
        let db = channelOf(0, dstArgb);
        match blend {
            case DrawCmd.BlendMode.Normal   =>
                packOver(dstArgb, normalChannel(a, sr, dr), normalChannel(a, sg, dg), normalChannel(a, sb, db))
            case DrawCmd.BlendMode.Add      =>
                packOver(dstArgb, addChannel(a, sr, dr), addChannel(a, sg, dg), addChannel(a, sb, db))
            case DrawCmd.BlendMode.Multiply =>
                packOver(dstArgb, multiplyChannel(a, sr, dr), multiplyChannel(a, sg, dg), multiplyChannel(a, sb, db))
        }

    /// Normal の 1 チャンネル（src の成分 s・dst の成分 d・src の α a。0..255 に収める）。
    def normalChannel(a: Int32, s: Int32, d: Int32): Int32 = clampI((s * a + d * (255 - a)) / 255, 0i32, 255i32)

    /// Add の 1 チャンネル。
    def addChannel(a: Int32, s: Int32, d: Int32): Int32 = clampI(d + s * a / 255, 0i32, 255i32)

    /// Multiply の 1 チャンネル。
    def multiplyChannel(a: Int32, s: Int32, d: Int32): Int32 = clampI(d * (255 - a * (255 - s) / 255) / 255, 0i32, 255i32)

    /// 合成した r, g, b に dst の alpha を付けて ARGB に組み直す。
    def packOver(dstArgb: Int32, r: Int32, g: Int32, b: Int32): Int32 =
        Int32.leftShift(channelOf(24, dstArgb), 24)
            |> Int32.bitwiseOr(Int32.leftShift(r, 16))
            |> Int32.bitwiseOr(Int32.leftShift(g, 8))
            |> Int32.bitwiseOr(b)

    /// ARGB int から 8bit チャンネルを取り出す（shift = 24/16/8/0 = A/R/G/B）。
    pub def channelOf(shift: Int32, argb: Int32): Int32 =
        Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, argb), 255)

    /// 1 枚読んで ARGB にそろえる。無いファイル・読めないファイルは None。
    def loadTexture(path: String): Option[BufferedImage] \ IO =
        let file = new File(path);
        if (file.exists()) {
            let img = ImageIO.read(file);
            if (Object.isNull(img)) None else Some(toArgb(img))
        } else None

    /// BufferedImage を TYPE_INT_ARGB(2) にコピーする（indexed / grayscale を RescaleOp 可能にする）。
    def toArgb(src: BufferedImage): BufferedImage \ IO =
        let w = Int32.max(1i32, src.getWidth());
        let h = Int32.max(1i32, src.getHeight());
        let dst = new BufferedImage(w, h, 2i32);
        let g: Graphics2D = dst.createGraphics();
        discard g.drawImage(src, 0i32, 0i32, unchecked_cast(null as ImageObserver));
        g.dispose();
        dst

    /// 扇割り三角形列から、点 at を含む三角形の補間色を引く（どの三角形にも入らなければ None）。
    /// 式は面積比の重み（バリセントリック）— GL が頂点色を画素へ補間するのと同じ線形補間。
    /// 隣り合う三角形の共有辺の上では両者の補間が一致するので、どちらが拾っても同じ色になる。
    /// 1 点だけ引く入口で、呼ぶたびに組み直す（画素ループは compileGradTris + firstGradHit）。
    pub def gradSample(tris: List[(DrawCmd.GradVertex, DrawCmd.GradVertex, DrawCmd.GradVertex)],
                       at: Vec2.Vec2): Option[DrawCmd.VertexTint] =
        SoftRaster.Internal.Gradient.firstGradHit(SoftRaster.Internal.Gradient.compileGradTris(tris), at#x, at#y)
            |> Option.map(rgba -> { let (r, g, b, a) = rgba; { color = { r = r, g = g, b = b }, alpha = a } })

    /// Flix Color(0..1) + alpha を AWT Color(0..255) へ。
    def awtColor(c: Color, alpha: Float32): AwtColor \ IO =
        new AwtColor(byteOf(f32(c#r)), byteOf(f32(c#g)), byteOf(f32(c#b)), byteOf(alpha))

    /// Float64 → Float32（±1e18 で頭打ち・NaN は NaN）。
    /// WhyNot: `Float64.clampToFloat32(min = .., max = .., x)` を使わない。名前つき引数は呼ぶたびに
    /// record を作って欄を名前で引くので、画素ごとに呼ぶ所（argbOfRgba・頂点色の補間）で重い。
    /// 値は標準ライブラリの clampToFloat32 と同じ（端は Float32 に落とした ±1e18）。
    def f32(x: Float64): Float32 =
        let limit = Float32.toFloat64(1.0e18f32);
        if (x != x) Float32.nan()
        else RenderUtil.f32(if (x < -1.0 * limit) -1.0 * limit else if (x > limit) limit else x)

    /// 0..1 の成分を 0..255 の Int32 へ丸める。1 を超える値・無限大は 255、0 未満と NaN は 0。
    /// WhyNot: 掛けてから整数にしてクランプしない — Int32 に入らない値（巨大な値・無限大）は tryToInt32 が None で 0 になり、明るすぎる画素が黒に落ちる。
    def byteOf(x: Float32): Int32 =
        let v = Float32.toFloat64(x);
        let unit = if (v >= 1.0) 1.0 else if (v > 0.0) v else 0.0;
        ri(unit * 255.0)

    /// Float64 を四捨五入して Int32 に（非負前提）。
    def ri(x: Float64): Int32 =
        Float64.tryToInt32(x + 0.5) |> Option.getWithDefault(0i32)

    /// v を [lo, hi] に収める。
    def clampI(v: Int32, lo: Int32, hi: Int32): Int32 =
        Int32.max(lo, Int32.min(hi, v))

    /// BufferedImage を PNG として書く。親ディレクトリが無ければ作る。
    /// 書き終えてから path へ置き換える（走行中のゲームの裏で描いていて途中で閉じても、書きかけを残さない）。
    def writePng(image: BufferedImage, path: String): Unit \ IO =
        AtomicFile.write(path, file -> discard ImageIO.write(image, "png", file))

    // ════════════════════════════════════════════════════════
    // RadialGlow テクスチャの PNG 書き出し（AWT 依存をここへ閉じ込める）
    // ════════════════════════════════════════════════════════

    /// size×size の正方形を pixelOf(x, y) で画素ごとに埋めて PNG に書く。
    /// RadialGlow の画素計算（純関数）と AWT の画像バッファ操作を分けるための橋渡し
    /// （RadialGlow.haloPixel/maskPixel を pixelOf に部分適用して渡す）。
    pub def writeRadialPng(size: Int32, pixelOf: (Int32, Int32) -> Int32, outPath: String): Unit \ IO = region rc {
        let s = Int32.max(1i32, size);
        let image = new BufferedImage(s, s, 2i32);
        let buf: Array[Int32, rc] = Array.empty(rc, s * s);
        Array.forEachWithIndex((i, _) -> {
            let x = Int32.remainder(i, s);
            let y = i / s;
            Array.put(pixelOf(x, y), i, buf)
        }, buf);
        image.setRGB(0i32, 0i32, s, s, buf, 0i32, s);
        writePng(image, outPath)
    }
}
