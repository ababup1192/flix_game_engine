// SoftRaster — GameEngine.Drawable / PolygonRenderCmd を Java2D で 1 枚の PNG に描き出す
// ソフトウェアラスタライザ。GL を使わないので GL コンテキストの無い場所（スナップショット
// テスト、将来の IDE ビューポートのプレビュー）で描画結果を目視確認できる。
//
// 描画規約（box/textured/font/polygon の扱い、z 順）は render_gl/Frame.drawSprite と
// 一致させてある — 各関数のコメントに規約を記す。design を `scale` 倍に拡大して出力する。
pub mod SoftRaster {
    import java.awt.image.BufferedImage
    import java.awt.image.RescaleOp
    import java.awt.image.ImageObserver
    import java.awt.Graphics2D
    import java.awt.{Color => AwtColor}
    import java.awt.RenderingHints
    import java.awt.BasicStroke
    import java.awt.Font
    import java.awt.Shape
    import java.awt.geom.{Path2D$Double => Path2D}
    import java.awt.geom.{RoundRectangle2D$Double => RoundRect}
    import java.awt.geom.{Line2D$Double => Line2D}
    import java.awt.geom.{Rectangle2D$Double => Rect2D}
    import java.io.File
    import java.io.FileInputStream
    import java.lang.System
    import java.lang.{Character => JChar}
    import javax.imageio.ImageIO

    /// ラスタライズ要求。design 解像度の Drawable 群を `scale` 倍に拡大して `outPath` に PNG 出力。
    /// `texturePath` は Drawable#texture 名 → PNG ファイルパス。フォント（`font_` テクスチャ）は
    /// アトラス PNG をサンプルせず、`fontTtf` の TTF を出力解像度サイズへ deriveFont して直接
    /// drawString する。グリフ Drawable から元文字を引くため `fontAtlas`（uvOffset↔codepoint の対応）を使う。
    /// `shapeAntialias` は面の縁（fillRoundRect / fillPolygon）のなめらかさ。
    /// **画素の格子に乗せる絵（ドット絵）では false にする** — true のままだと宣言した
    /// パレットに無い中間色が縁に湧く（実測: 宣言 13 色の一人称の画面が PNG では 2884 色）。
    ///
    /// `textAntialias` は文字の縁と送り幅。こちらは**可読性**のつまみで、面とは理由が違う —
    /// 7px の TTF は縁をならさないと字が潰れる。ドット絵のキャラと小さい TTF が同じ画面に
    /// 出るゲーム（ノベル・RPG）は `shapeAntialias = false` / `textAntialias = true` にする。
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
        textAntialias = Bool
    }

    /// 描画品質ヒントの 2 つ組（面の縁 / 文字の縁と送り幅）。本体と下書き（blendedDraw）へ
    /// 同じ組を渡して、重ね方の違いで見た目が変わらないようにする。
    type alias QualityHints = { shapes = Bool, text = Bool }

    def hintsOf(req: RasterReq): QualityHints =
        { shapes = req#shapeAntialias, text = req#textAntialias }

    /// 追加フォント 1 本（既定フォント以外も混ぜて描き出すとき）。ttf = 実サイズ描き出し用の TTF、
    /// atlas = その TTF から HeadlessFont.buildAtlas で組んだメトリクス。
    pub type alias FontEntry = { ttf = String, atlas = FontAtlas }

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
    /// グリフを描く直前に Drawable#texture でこの表から 1 本選ぶ。
    /// 知らないテクスチャ名は primary を使う（fail-open — 字が消えるより既定で出るほうがよい）。
    type alias FontTable = { primary = FontCtx, byTexture = Map[String, FontCtx] }

    def fontFor(fonts: FontTable, d: DrawCmd.DrawableSpec): FontCtx =
        Map.get(d#texture, fonts#byTexture) |> Option.getWithDefault(fonts#primary)

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

    /// 描き物 1 件（z 合流用の内部タグ）。Drawable / Polygon / シェーダー面を
    /// 1 列に混ぜて (zIndex, 追加順) で安定ソートするための包み。
    enum RItem {
        case RDraw(DrawCmd.DrawableSpec)
        case RPoly(GameEngine.PolygonRenderCmd)
        case RSurf(SurfaceCmd)
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

    /// 要求を 1 枚の PNG に描き出して書き出す。
    pub def render(req: RasterReq): Unit \ IO =
        writePng(renderToImage(req), req#outPath)

    /// 追加フォントつきの render。`extraFonts` はテクスチャ名（"font_girl" など。実機の
    /// project.json の fonts[].name に "font_" を付けた物）→ その本。既定フォント
    /// （req#fontTtf / req#fontAtlas）はそのまま効くので、混ぜたい本だけ渡せばよい。
    pub def renderFonts(req: RasterReq, extraFonts: Map[String, FontEntry]): Unit \ IO =
        writePng(renderToImageFonts(req, Nil, extraFonts), req#outPath)

    /// シェーダー面つきの render（面は ShaderEval で画素評価して z 順に合流する）。
    pub def renderWithSurfaces(req: RasterReq, surfaces: List[SurfaceCmd]): Unit \ IO =
        writePng(renderToImageWith(req, surfaces), req#outPath)

    /// 追加の描き出し済み画像（pass のレンダーターゲットなど）も混ぜて描き、PNG に書き出す render。
    pub def renderFull(req: RasterReq, surfaces: List[SurfaceCmd],
                       extraFonts: Map[String, FontEntry],
                       extraImages: Map[String, BufferedImage]): Unit \ IO =
        writePng(renderToImageFull(req, surfaces, extraFonts, extraImages), req#outPath)

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
                              extraImages: Map[String, BufferedImage]): BufferedImage \ IO =
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
            let _ = Log.warn("texture '${name}' が見つからない — 描かない"
                + "（project.json の textures に同名の宣言があるか確認）");
            Ref.put(Set.insert(name, warned), warnLog)
        }

    /// renderToImageFull の欠け名控えつき版。控えは知らせの回数にだけ効き、
    /// 描き出す画素には一切影響しない（バイト一致はそのまま）。
    pub def renderToImageLogged(req: RasterReq, surfaces: List[SurfaceCmd],
                                extraFonts: Map[String, FontEntry],
                                extraImages: Map[String, BufferedImage],
                                warnLog: TexWarnLog): BufferedImage \ IO =
        HeadlessFont.ensureHeadless();
        let (w, h) = outSize(req);
        let image = new BufferedImage(w, h, 2i32);
        let g: Graphics2D = image.createGraphics();
        // 背景（clearColor）で塗りつぶす。
        g.setColor(awtColor(req#background, 1.0f32));
        g.fillRect(0i32, 0i32, w, h);
        g.dispose();
        drawAllInto(image, req, surfaces, extraFonts, extraImages, warnLog);
        image

    /// pass（レンダーターゲット）描き出し用の入口。req#background は使わない — 塗るかどうか
    /// （clearColor）の判断は呼び出し側（HeadlessRender）が持つので、ここで塗ると判断が二重になる。
    /// `base` が Some ならその画像のコピーの上に描き足す（呼び出し側の画像は変異させない —
    /// 前フレームの中身は残像の証拠としてそのまま残したい）、None なら全画素透明から始める。
    pub def renderPassImage(req: RasterReq, base: Option[BufferedImage],
                            extraImages: Map[String, BufferedImage]): BufferedImage \ IO =
        HeadlessFont.ensureHeadless();
        let image = match base {
            case Some(b) => toArgb(b)
            case None    => { let (w, h) = outSize(req); new BufferedImage(w, h, 2i32) }
        };
        drawAllInto(image, req, Nil, Map.empty(), extraImages, freshTexWarnLog());
        image

    /// 出力ピクセル寸法（design × scale、最低 1px）。
    def outSize(req: RasterReq): (Int32, Int32) =
        let sf = Int32.toFloat64(req#scale);
        (Int32.max(1i32, ri(req#design#x * sf)), Int32.max(1i32, ri(req#design#y * sf)))

    /// 描画本体（z 合流 + 種類ごとの分岐）。背景を塗る/塗らないの違いは入口関数側に置き、
    /// ここを二重実装しない — 分岐の式が 2 か所に割れると、片方だけ直して絵が食い違う。
    def drawAllInto(image: BufferedImage, req: RasterReq, surfaces: List[SurfaceCmd],
                    extraFonts: Map[String, FontEntry],
                    extraImages: Map[String, BufferedImage],
                    warnLog: TexWarnLog): Unit \ IO = region rc {
        let sf = Int32.toFloat64(req#scale);
        let g: Graphics2D = image.createGraphics();
        applyQualityHints(g, hintsOf(req));
        // 組み込みの放射テクスチャを土台に、ゲームのテクスチャ → extraImages の順で重ねる
        //（後から入れた方が勝つ。名前は `__` 予約なので実際に潰し合うことはない）。
        // GL 側は起動時に必ず GPU へ上げるため、描き出し側も配線ゼロで同じ名前が引けないと
        // 実機と描き出しの絵がずれる。
        let textures = Map.foldLeftWithKey((acc, name, img) -> Map.insert(name, img, acc),
            Map.foldLeftWithKey((acc, name, img) -> Map.insert(name, img, acc),
                builtinRadialImages(req#drawables),
                loadTextures(req#texturePath)), extraImages);
        let fctx = buildFontTable(req, extraFonts);
        // tex 場（Field.Tex）が読む画素表。surfaces が実際に使う名前だけ 1 回で Vector 化する —
        // 画素ループの中で BufferedImage を触らない（getRGB を毎画素呼ぶと桁で遅い）。
        // 無い名前は warnLog に控えて一度だけ知らせる（eval は純関数のまま黒 0.0 を返す）。
        let usedTexNames = surfaces
            |> List.flatMap(sc -> ShaderDoc.texNames(sc#spec))
            |> List.distinct;
        let texEnv = usedTexNames |> List.foldLeft((acc, name) -> {
            match Map.get(name, textures) {
                case Some(img) => Map.insert(name, texDataOf(img), acc)
                case None =>
                    let warned = Ref.get(warnLog);
                    if (Set.memberOf(name, warned)) ()
                    else {
                        System.err.println("shader tex '${name}' が見つからない — 黒(0)で描く"
                            + "（pass なら passes に同名の宣言があるか確認）");
                        Ref.put(Set.insert(name, warned), warnLog)
                    };
                    acc
            }
        }, (Map.empty(): Map[String, ShaderEval.TexData]));
        // Drawable / Polygon / シェーダー面を 1 列にまとめ、(z, 追加順) で安定ソートする。
        // Drawable は入口で 1 回だけ名前付きレコードへ展開する（描き出しは 1 枚きりの経路
        // なので、以降の細かな読み出しをフィールド名のまま書けるほうを取る）。
        let tagged = List.append(
            List.map(d -> RItem.RDraw(DrawCmd.toSpec(d)), req#drawables),
            List.append(
                List.map(p -> RItem.RPoly(p), req#polygons),
                List.map(s -> RItem.RSurf(s), surfaces)));
        let sorted = tagged
            |> List.zipWithIndex
            |> List.sortBy(ix -> let (idx, item) = ix; (zOf(item), idx))
            |> List.map(ix -> let (_, item) = ix; item);
        // blend=Normal は従来どおり Graphics2D（SrcOver）で直接描く。Add / Multiply は
        // Java2D の標準 Composite に無い重ね方なので、下書きへ描いてから自前の式で合成する。
        // シェーダー面は Graphics2D を使わず、ShaderEval の画素評価 + blendPixel で直接混ぜる。
        List.forEach(item -> match item {
            case RItem.RDraw(d)  =>
                if (d#blend == DrawCmd.BlendMode.Normal)
                    withClip(g, sf, d#clip, () -> drawDrawable(g, sf, textures, fctx, d, warnLog))
                else
                    blendedDraw(image, sf, hintsOf(req), d#blend, d#clip, drawableAabb(req#design, textures, d),
                                gs -> drawDrawable(gs, sf, textures, fctx, d, warnLog))
            case RItem.RPoly(p) =>
                if (not Option.isEmpty(p#grad))
                    drawGradPolygon(image, sf, req#design, p)
                else if (p#blend == DrawCmd.BlendMode.Normal)
                    withClip(g, sf, p#clip, () -> drawPolygon(rc, g, sf, p))
                else
                    blendedDraw(image, sf, hintsOf(req), p#blend, p#clip, polygonAabb(req#design, p),
                                gs -> drawPolygon(rc, gs, sf, p))
            case RItem.RSurf(s) => drawSurface(image, sf, texEnv, s)
        }, sorted);
        g.dispose()
    }

    /// シェーダー面を画素ごとに描き出す。rect を出力ピクセルへ量子化し、各画素の中心を
    /// uv（rect 内 0..1）に写して ShaderEval.evalPixelAlphaTex（色と α を 1 回の shared
    /// 先行評価で一緒に返す版 — 別々に呼ぶと bindings を画素ごとに 2 回払う）で評価、
    /// blendPixel で本体へ混ぜる（Normal / Add / Multiply とも GL 側と同じ合成式）。
    /// mask が非空なら「どれかの多角形の内側」の画素だけ塗る（GL のステンシル抜きと同じ意図）。
    def drawSurface(image: BufferedImage, sf: Float64, texEnv: Map[String, ShaderEval.TexData],
                    s: SurfaceCmd): Unit \ IO = region rc {
        let dw = image.getWidth();
        let dh = image.getHeight();
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, s#rect);
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let x1 = Int32.min(dw, rx1);
        let y1 = Int32.min(dh, ry1);
        let w = x1 - x0;
        let h = y1 - y0;
        if (w <= 0i32 or h <= 0i32 or s#rect#size#x <= 0.0 or s#rect#size#y <= 0.0) ()
        else {
            let n = w * h;
            let buf: Array[Int32, rc] = Array.empty(rc, n);
            let maskPolys = List.map(List.toVector, s#mask);
            discard image.getRGB(x0, y0, w, h, buf, 0i32, w);
            Array.forEachWithIndex((i, dst) -> {
                let px = Int32.remainder(i, w) + x0;
                let py = i / w + y0;
                // 出力ピクセル中心 → design px → rect 内 uv（0..1）。
                let dx = (Int32.toFloat64(px) + 0.5) / sf;
                let dy = (Int32.toFloat64(py) + 0.5) / sf;
                if (not insideMask(maskPolys, { x = dx, y = dy })) ()
                else {
                    let uv = { x = (dx - s#rect#position#x) / s#rect#size#x,
                               y = (dy - s#rect#position#y) / s#rect#size#y };
                    let (c, a0) = ShaderEval.evalPixelAlphaTex(s#spec, uv, s#time, texEnv);
                    let a = Float64.max(0.0, Float64.min(1.0, a0));
                    let srcArgb = argbOf(c, a);
                    Array.put(blendPixel(s#blend, srcArgb, dst), i, buf)
                }
            }, buf);
            image.setRGB(x0, y0, w, h, buf, 0i32, w)
        }
    }

    /// BufferedImage を ShaderEval の画素表（ARGB・行優先・正立）へ 1 回で写す。
    def texDataOf(img: BufferedImage): ShaderEval.TexData \ IO = region rc {
        let w = Int32.max(1i32, img.getWidth());
        let h = Int32.max(1i32, img.getHeight());
        let buf: Array[Int32, rc] = Array.empty(rc, w * h);
        discard img.getRGB(0i32, 0i32, w, h, buf, 0i32, w);
        { width = w, height = h, pixels = Array.toVector(buf) }
    }

    /// mask が空なら常に真。非空なら「どれかの多角形の内側」（偶奇の交差数判定）。
    def insideMask(mask: List[Vector[Vec2.Vec2]], p: Vec2.Vec2): Bool =
        match mask {
            case Nil => true
            case _   => List.exists(vs -> pointInPoly(vs, p), mask)
        }

    /// 偶奇規則の point-in-polygon（水平レイキャスト）。
    def pointInPoly(vs: Vector[Vec2.Vec2], p: Vec2.Vec2): Bool =
        let n = Vector.length(vs);
        if (n == 0) false
        else Int32.modulo(countCrossings(vs, n, p, 0, 0), 2) == 1

    /// 辺 i→i+1 が p から右へ伸びる水平線を跨ぐ回数を、添字 i から末尾まで数え上げる。
    def countCrossings(vs: Vector[Vec2.Vec2], n: Int32, p: Vec2.Vec2, i: Int32, hits: Int32): Int32 =
        if (i >= n) hits
        else {
            let a = Vector.get(i, vs);
            let b = Vector.get(Int32.modulo(i + 1, n), vs);
            let crosses = ((a#y > p#y) != (b#y > p#y))
                and (p#x < (b#x - a#x) * (p#y - a#y) / (b#y - a#y) + a#x);
            countCrossings(vs, n, p, i + 1, if (crosses) hits + 1 else hits)
        }

    /// Color(0..1) + alpha(0..1) を ARGB int へ。
    def argbOf(c: Color, a: Float64): Int32 =
        Int32.leftShift(clampI(ri(a * 255.0), 0i32, 255i32), 24)
            |> Int32.bitwiseOr(Int32.leftShift(byteOf(f32(c#r)), 16))
            |> Int32.bitwiseOr(Int32.leftShift(byteOf(f32(c#g)), 8))
            |> Int32.bitwiseOr(byteOf(f32(c#b)))

    /// 本体と下書き（blendedDraw）が同じ見た目で描くための描画品質ヒント一式。
    ///
    /// 面と文字を別のつまみにしてあるのは、**2 つが別の理由で効く**から。
    /// 面の縁は「宣言していない中間色を画素に湧かせない」ため（色の予算）、
    /// 文字の縁は「小さい字を読めるようにする」ため（可読性）。
    /// ドット絵のキャラと 7px の TTF が同居する画面では、この 2 つは逆を向く。
    ///
    /// 送り幅（FRACTIONALMETRICS）は文字の側に付ける。効くのは字の置き場所と進み幅だけで、
    /// 面には一切触らない — 面の縁を画素の格子に乗せたいという要求とは関係が無い。
    /// 文字の縁をならさない（text = false）と決めた画面では、字も整数の画素位置に
    /// 揃ってほしいので、2 つが同じつまみで動くのが正しい。
    ///
    /// スプライト拡大の補間だけはどちらにも載せない。あれは実機（GPU）の見え方に
    /// そろえるための固定で、選ぶ余地が無い。
    def applyQualityHints(g: Graphics2D, hints: QualityHints): Unit \ IO =
        // 面の縁（fillRoundRect/fillPolygon）。切ると縁が画素の格子に乗る。
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING,
            if (hints#shapes) RenderingHints.VALUE_ANTIALIAS_ON else RenderingHints.VALUE_ANTIALIAS_OFF);
        // スプライト拡大（drawTextured の drawImage）は最近傍固定。実機の GPU 描画はドット絵を
        // 補間せず拡大するため、ここで補間すると実機と見え方がずれる（にじみ・輪郭ボケ）。
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
        // 出力解像度で小サイズ文字をくっきり描くためのテキスト品質ヒント（drawString は INTERPOLATION の対象外）。
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING,
            if (hints#text) RenderingHints.VALUE_TEXT_ANTIALIAS_ON
            else RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        // 字の送り幅。ON だと字が小数の位置に置ける（詰めが揃う）。OFF だと整数の画素に丸まる。
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS,
            if (hints#text) RenderingHints.VALUE_FRACTIONALMETRICS_ON
            else RenderingHints.VALUE_FRACTIONALMETRICS_OFF)

    // ════════════════════════════════════════════════════════
    // ブレンド合成（Add / Multiply — Java2D 標準 Composite に無い重ね方）
    // ════════════════════════════════════════════════════════

    /// Normal 以外の描画: いったん透明な下書き画像へ普通に描き、その画素を合成式で本体に混ぜる。
    /// clip は下書きへの描画に掛ける — 透明のまま残った画素は合成しないので、切り抜きの外は本体に触れない。
    /// 下書き自体は本体と同じ全面サイズで確保するが（Graphics2D の clip 計算を素直に保つため）、
    /// getRGB/setRGB で往復する範囲は `aabb`（drawable/polygon の外形、画面クランプ・design px）
    /// だけに絞る — 全面走査だと 1 個の光源・炎エフェクトのために毎フレーム画面全体を
    /// 読み書きすることになり、drawable 数に対して不釣り合いに重くなるため。
    def blendedDraw(image: BufferedImage, sf: Float64, hints: QualityHints, blend: DrawCmd.BlendMode,
                    clip: Option[Rect2.Rect2], aabb: Rect2.Rect2,
                    draw: Graphics2D -> Unit \ ef): Unit \ IO + ef =
        let w = Int32.max(1i32, image.getWidth());
        let h = Int32.max(1i32, image.getHeight());
        let scratch = new BufferedImage(w, h, 2i32);
        let gs: Graphics2D = scratch.createGraphics();
        applyQualityHints(gs, hints);
        withClip(gs, sf, clip, () -> draw(gs));
        gs.dispose();
        composeInto(image, scratch, blend, sf, aabb)

    /// 下書きの不透明画素だけを合成式で本体に書き戻す（getRGB/setRGB の行列一括転送）。
    /// 転送範囲は aabb を出力ピクセルへ量子化した矩形（画像境界にクランプ済み）だけに絞る。
    def composeInto(dst: BufferedImage, src: BufferedImage, blend: DrawCmd.BlendMode,
                    sf: Float64, aabb: Rect2.Rect2): Unit \ IO = region rc {
        let dw = dst.getWidth();
        let dh = dst.getHeight();
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, aabb);
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let x1 = Int32.min(dw, rx1);
        let y1 = Int32.min(dh, ry1);
        let w = x1 - x0;
        let h = y1 - y0;
        if (w <= 0i32 or h <= 0i32) ()
        else {
            let n = w * h;
            let dstBuf: Array[Int32, rc] = Array.empty(rc, n);
            let srcBuf: Array[Int32, rc] = Array.empty(rc, n);
            discard dst.getRGB(x0, y0, w, h, dstBuf, 0i32, w);
            discard src.getRGB(x0, y0, w, h, srcBuf, 0i32, w);
            Array.forEachWithIndex((i, sp) -> {
                if (channelOf(24, sp) == 0) ()
                else Array.put(blendPixel(blend, sp, Array.get(i, dstBuf)), i, dstBuf)
            }, srcBuf);
            dst.setRGB(x0, y0, w, h, dstBuf, 0i32, w)
        }
    }

    /// ARGB 1 画素の合成（src を dst に重ねた結果。out の alpha は dst のまま —
    /// 描き出しの出力は背景が不透明で埋まっているため）。式は DrawCmd.BlendMode の doc と
    /// GL 側（RenderSprite.applyBlend + シェーダの premultiply）に一致させてある:
    ///   Normal   : out = (src×a + dst×(255−a)) / 255           （SrcOver）
    ///   Add      : out = min(255, dst + src×a/255)             （明るく足す・クランプ）
    ///   Multiply : out = dst×(255 − a×(255−src)/255) / 255     （白は素通し・黒は黒・a=0 で恒等）
    pub def blendPixel(blend: DrawCmd.BlendMode, srcArgb: Int32, dstArgb: Int32): Int32 =
        let a = channelOf(24, srcArgb);
        let mix = f ->
            withChannels((s, d) -> clampI(f(s, d), 0i32, 255i32), srcArgb, dstArgb);
        match blend {
            case DrawCmd.BlendMode.Normal   => mix((s, d) -> (s * a + d * (255 - a)) / 255)
            case DrawCmd.BlendMode.Add      => mix((s, d) -> d + s * a / 255)
            case DrawCmd.BlendMode.Multiply => mix((s, d) -> d * (255 - a * (255 - s) / 255) / 255)
        }

    /// RGB 3 チャンネルへ同じ式 f を適用し、alpha は dst のまま ARGB に組み直す。
    def withChannels(f: (Int32, Int32) -> Int32, srcArgb: Int32, dstArgb: Int32): Int32 =
        let r = f(channelOf(16, srcArgb), channelOf(16, dstArgb));
        let g = f(channelOf(8, srcArgb), channelOf(8, dstArgb));
        let b = f(channelOf(0, srcArgb), channelOf(0, dstArgb));
        Int32.leftShift(channelOf(24, dstArgb), 24)
            |> Int32.bitwiseOr(Int32.leftShift(r, 16))
            |> Int32.bitwiseOr(Int32.leftShift(g, 8))
            |> Int32.bitwiseOr(b)

    /// ARGB int から 8bit チャンネルを取り出す（shift = 24/16/8/0 = A/R/G/B）。
    def channelOf(shift: Int32, argb: Int32): Int32 =
        Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, argb), 255)

    /// z 値取り出し（Drawable / Polygon / シェーダー面）。
    def zOf(item: RItem): Int32 =
        match item {
            case RItem.RDraw(d) => d#zIndex
            case RItem.RPoly(p) => p#zIndex
            case RItem.RSurf(s) => s#zIndex
        }

    // ════════════════════════════════════════════════════════
    // AABB（dirty-rect 化: blendedDraw が getRGB/setRGB を絞り込む範囲を出す）
    // ════════════════════════════════════════════════════════

    /// design 全体を覆う矩形（フォールバック用 — 外形が正確に分からない/計算コストに
    /// 見合わない場合に安全側を選ぶ。全面走査になるだけで結果は従来どおり正しい）。
    def fullDesignRect(design: Vec2.Vec2): Rect2.Rect2 =
        { position = Vec2.zero(), size = design }

    /// clip があれば交差、design 全体にもクランプする（画面外へ広がった外形を切り詰める）。
    def clampAabb(design: Vec2.Vec2, clip: Option[Rect2.Rect2], aabb: Rect2.Rect2): Rect2.Rect2 =
        let withClip = match clip {
            case None    => aabb
            case Some(r) => Rect2.intersect(r, aabb)
        };
        Rect2.intersect(fullDesignRect(design), withClip)

    /// Drawable 1 件の外形（design px）。box（texture=""）は scale がそのまま px サイズ、
    /// テクスチャ物は実サイズ（textures から引く）× uvScale × |scale|、font_ は
    /// グリフごとの実寸計算が煩雑なので design 全体へ安全側フォールバックする
    /// （HUD 文字は毎フレーム変わり得るため、狭く絞って文字の一部を取りこぼす方が危険）。
    def drawableAabb(design: Vec2.Vec2, textures: Map[String, BufferedImage],
                     d: DrawCmd.DrawableSpec): Rect2.Rect2 \ IO =
        if (String.startsWith({prefix = "font_"}, d#texture))
            fullDesignRect(design)
        else {
            let base = if (String.isEmpty(d#texture)) { x = 1.0, y = 1.0 }
                       else match Map.get(d#texture, textures) {
                           case Some(img) =>
                               { x = Int32.toFloat64(img.getWidth()) * d#uvScale#x,
                                 y = Int32.toFloat64(img.getHeight()) * d#uvScale#y }
                           case None      => Vec2.zero()
                       };
            let size = { x = base#x * Float64.abs(d#scale#x), y = base#y * Float64.abs(d#scale#y) };
            let topLeft = if (d#centered) Vec2.sub(d#position, Vec2.div(size, 2.0)) else d#position;
            // AA のにじみで縁の画素が塗り範囲よりわずかに外へ出るため 1px 分の余裕を足す。
            // BasicStroke の枠線は中心線基準でさらに半分だけ外へはみ出すのでその分も足す。
            let borderPad = 1.0 + match d#style {
                case Some(st) => DrawCmd.borderWidthOf(st) / 2.0
                case None     => 0.0
            };
            let quad = turnedBounds(d#rotation, { position = topLeft, size = size });
            clampAabb(design, d#clip, Rect2.grow(borderPad, quad))
        }

    /// 傾けた四角を覆う矩形（中心はそのまま・半径だけ広がる）。傾けた物の外形を
    /// 回転前のまま見積もると、Add / Multiply の合成で角がはみ出して欠ける。
    def turnedBounds(rot: Float64, r: Rect2.Rect2): Rect2.Rect2 =
        if (rot == 0.0) r
        else {
            let c = Float64.abs(RenderUtil.cosF(rot));
            let s = Float64.abs(RenderUtil.sinF(rot));
            let hw = Float64.abs(r#size#x) / 2.0;
            let hh = Float64.abs(r#size#y) / 2.0;
            let w = c * hw + s * hh;
            let h = s * hw + c * hh;
            let center = Vec2.add(r#position, Vec2.div(r#size, 2.0));
            { position = { x = center#x - w, y = center#y - h }, size = { x = w * 2.0, y = h * 2.0 } }
        }

    /// PolygonRenderCmd 1 件の外形（design px、頂点は既にスクリーン座標に変換済み）。
    /// AA のにじみで縁の画素が塗り範囲よりわずかに外へ出ることがあるため 1px 分の余裕を足す。
    def polygonAabb(design: Vec2.Vec2, p: GameEngine.PolygonRenderCmd): Rect2.Rect2 =
        let aabb = match p#vertices {
            case Nil       => { position = Vec2.zero(), size = Vec2.zero() }
            case v :: rest =>
                let lo = List.foldLeft((acc, q) -> { x = Float64.min(acc#x, q#x), y = Float64.min(acc#y, q#y) }, v, rest);
                let hi = List.foldLeft((acc, q) -> { x = Float64.max(acc#x, q#x), y = Float64.max(acc#y, q#y) }, v, rest);
                { position = lo, size = Vec2.sub(hi, lo) }
        };
        clampAabb(design, p#clip, Rect2.grow(1.0, aabb))

    /// 組み込みの放射テクスチャ（Render.lightAt / darkAt が引く）の表。作るのは
    /// drawables がその名前を実際に使うときだけ — 256×256 の画素計算を毎フレームの
    /// 描き出しに無条件で払わせない（描き出しの画素ループは既知の性能の池）。
    def builtinRadialImages(drawables: List[GameEngine.Drawable]): Map[String, BufferedImage] \ IO =
        let usedOf = name -> List.exists(d -> DrawCmd.textureOf(d) == name, drawables);
        let withEntry = (name: String, pixelsOf: Unit -> Vector[Int32],
                         acc: Map[String, BufferedImage]) ->
            if (usedOf(name)) Map.insert(name, imageOfArgb(RadialBuiltin.size(), pixelsOf()), acc)
            else acc;
        withEntry(RadialBuiltin.darkName(), _ -> RadialBuiltin.darkPixels(),
            withEntry(RadialBuiltin.lightName(), _ -> RadialBuiltin.lightPixels(), Map.empty()))

    /// ARGB 画素列（行優先・size×size）を BufferedImage へ敷き詰める。
    def imageOfArgb(size: Int32, pixels: Vector[Int32]): BufferedImage \ IO = region rc {
        let s = Int32.max(1i32, size);
        let image = new BufferedImage(s, s, 2i32);
        let buf: Array[Int32, rc] = Array.empty(rc, s * s);
        Array.forEachWithIndex((i, _) -> Array.put(Vector.get(i, pixels), i, buf), buf);
        image.setRGB(0i32, 0i32, s, s, buf, 0i32, s);
        image
    }

    /// texturePath の各エントリを ImageIO で読み込む。読めないものは飛ばす。
    /// indexed / grayscale 等の色モデルは RescaleOp（drawTextured の tint）が扱えないため、
    /// 一律 ARGB へ正規化する。
    def loadTextures(paths: Map[String, String]): Map[String, BufferedImage] \ IO =
        Map.foldLeftWithKey((acc, name, path) -> {
            let file = new File(path);
            if (file.exists()) {
                let img = ImageIO.read(file);
                if (Object.isNull(img)) acc else Map.insert(name, toArgb(img), acc)
            } else acc
        }, (Map.empty(): Map[String, BufferedImage]), paths)

    /// BufferedImage を TYPE_INT_ARGB(2) にコピーする（indexed / grayscale を RescaleOp 可能にする）。
    def toArgb(src: BufferedImage): BufferedImage \ IO =
        let w = Int32.max(1i32, src.getWidth());
        let h = Int32.max(1i32, src.getHeight());
        let dst = new BufferedImage(w, h, 2i32);
        let g: Graphics2D = dst.createGraphics();
        discard g.drawImage(src, 0i32, 0i32, unchecked_cast(null as ImageObserver));
        g.dispose();
        dst

    /// 1 つの Drawable を描く。texture が空なら box、`font_` ならグリフを直接 drawString、
    /// それ以外はテクスチャ画像。
    def drawDrawable(g: Graphics2D, sf: Float64,
                     textures: Map[String, BufferedImage], fctx: FontTable, d: DrawCmd.DrawableSpec,
                     warnLog: TexWarnLog): Unit \ IO =
        withRotation(g, sf, d#rotation, quadCenter(textures, fctx, d), () ->
            if (String.isEmpty(d#texture))
                withMask(g, sf, d#position, d#scale, d#mask, () -> drawBox(g, sf, d))
            else if (String.startsWith({prefix = "font_"}, d#texture))
                // グリフは mask の対象外（文字の可読性が第一 — docs/backend-parity.md）。
                drawGlyph(g, sf, fontFor(fctx, d), d)
            else
                match Map.get(d#texture, textures) {
                    case None      => warnMissingTexture(warnLog, d#texture)
                    case Some(img) =>
                        let size = { x = Int32.toFloat64(img.getWidth()) * d#scale#x,
                                     y = Int32.toFloat64(img.getHeight()) * d#scale#y };
                        let origin = { x = originAxis(d#centered, d#position#x, size#x),
                                       y = originAxis(d#centered, d#position#y, size#y) };
                        withMask(g, sf, origin, size, d#mask, () -> drawTextured(g, sf, img, d))
                })

    /// mask（表示クアッドのローカル design px・原点 = 反転していない側の角・回転前）を Path2D に組み、
    /// g.clip（交差）してから draw する。withRotation の内側で呼ぶのが肝 — Java2D の clip は
    /// 現在の変換で形が写るので、クアッドの回転がそのまま mask にも掛かる。
    /// 頂点を size の符号で掛け直すのは、反転（負の scale）をクアッドと同じ向きに掛けるため。
    /// 縁は AA なしの硬い縁（GL のステンシルと同じ近似 — docs/backend-parity.md）。
    /// クアッドが退化（辺長ほぼ 0）なら mask を張らずに描く（どのみち絵は出ない）。
    def withMask(g: Graphics2D, sf: Float64, origin: Vec2.Vec2, size: Vec2.Vec2,
                 mask: List[List[Vec2.Vec2]], draw: Unit -> Unit \ ef): Unit \ IO + ef =
        let aw = Float64.abs(size#x);
        let ah = Float64.abs(size#y);
        if (List.isEmpty(mask) or aw < 0.000001 or ah < 0.000001) draw()
        else {
            let saved = g.getClip();
            let path = new Path2D();
            List.forEach(poly -> match poly {
                case first :: rest =>
                    let pt = (v: Vec2.Vec2) -> ({ x = (origin#x + v#x / aw * size#x) * sf,
                                                  y = (origin#y + v#y / ah * size#y) * sf }: Vec2.Vec2);
                    let p0 = pt(first);
                    path.moveTo(p0#x, p0#y);
                    List.forEach(v -> { let p = pt(v); path.lineTo(p#x, p#y) }, rest);
                    path.closePath()
                case Nil => ()
            }, mask);
            g.clip(path);
            draw();
            g.setClip(saved)
        }

    /// 傾き（ラジアン）を掛けてから描き、終わったら座標系を戻す。回す軸は四角の中心で、
    /// render_gl/Frame の model 行列（pos + size/2 まわり）と同じ点にしてある — ここがズレると
    /// 描き出した絵と実機の絵が食い違う。
    /// 切り抜き矩形（clip）は device 空間で保たれるので、傾けても切り抜きは画面に平行なまま（Render の決まりどおり）。
    def withRotation(g: Graphics2D, sf: Float64, rot: Float64, center: Vec2.Vec2,
                     draw: Unit -> Unit \ ef): Unit \ IO + ef =
        if (rot == 0.0) draw()
        else {
            let saved = g.getTransform();
            g.rotate(rot, center#x * sf, center#y * sf);
            draw();
            g.setTransform(saved)
        }

    /// Drawable の四角の中心（design px）。表示サイズの出し方は種類ごとに drawBox /
    /// drawGlyph / drawTextured と同じ式を使う。
    def quadCenter(textures: Map[String, BufferedImage], fctx: FontTable,
                   d: DrawCmd.DrawableSpec): Vec2.Vec2 \ IO =
        let size = displaySize(textures, fctx, d);
        if (d#centered) d#position
        else {
            let origin = { x = originAxis(false, d#position#x, size#x),
                           y = originAxis(false, d#position#y, size#y) };
            Vec2.add(origin, Vec2.div(size, 2.0))
        }

    /// Drawable の表示サイズ（design px・反転の符号は残す）。box は scale がそのまま px、
    /// font_ はアトラス辺長との積、その他はテクスチャ実寸との積。
    def displaySize(textures: Map[String, BufferedImage], fctx: FontTable,
                    d: DrawCmd.DrawableSpec): Vec2.Vec2 \ IO =
        if (String.isEmpty(d#texture)) d#scale
        else if (String.startsWith({prefix = "font_"}, d#texture))
            // アトラス辺長は本ごとに違うので、回す軸がずれないよう同じ本から取る。
            let ts = fontFor(fctx, d)#atlas#textureSize;
            { x = d#scale#x * ts, y = d#scale#y * ts }
        else match Map.get(d#texture, textures) {
            case Some(img) => { x = Int32.toFloat64(img.getWidth()) * d#scale#x,
                                y = Int32.toFloat64(img.getHeight()) * d#scale#y }
            case None      => Vec2.zero()
        }

    // ════════════════════════════════════════════════════════
    // フォント（グリフ Drawable を出力解像度で直接 drawString）
    // ════════════════════════════════════════════════════════

    /// 既定フォントと追加フォントを読み、テクスチャ名で引ける一式にする。
    /// 既定フォントも自分のテクスチャ名（fontAtlas#textureName）で引けるように入れておく —
    /// そうしないと既定と同じ名前の追加を渡されたときに二重に持つことになる。
    def buildFontTable(req: RasterReq, extraFonts: Map[String, FontEntry]): FontTable \ IO =
        let primary = buildFontCtx(req#fontTtf, req#fontAtlas);
        let table = Map.foldLeftWithKey((acc, texName, e) ->
            Map.insert(texName, buildFontCtx(e#ttf, e#atlas), acc),
            Map#{ req#fontAtlas#textureName => primary }, extraFonts);
        { primary = primary, byTexture = table }

    /// TTF を読み、アトラスの各グリフの s0/t0 からセル左上 px を逆算した codepoint 表を組む。
    def buildFontCtx(ttfPath: String, atlas: FontAtlas): FontCtx \ IO =
        let fis = new FileInputStream(ttfPath);
        let base = Font.createFont(0i32, fis);
        fis.close();
        let ts = atlas#textureSize;
        let table = Map.foldLeftWithKey((acc, cp, gm) ->
            Map.insert((ri(gm#s0 * ts), ri(gm#t0 * ts)), cp, acc),
            (Map.empty(): Map[(Int32, Int32), Int32]), atlas#glyphs);
        { baseFont = base, atlas = atlas, codepointByCell = table }

    /// 1 グリフ Drawable を出力解像度の Font で直接描く。
    /// グリフのセル高さ（drawable#scale#y × textureSize）とアトラスの行高 (ascent+descent+2) の比が
    /// bake スケール = display fontSize / bake fontSize なので、そこから display fontSize を復元する。
    /// ベースラインはセル上端（drawable#position#y）から ascent × bakeScale 下。
    /// uvOffset をセル px へ戻して codepoint を逆引きし、その 1 文字を drawString する。
    def drawGlyph(g: Graphics2D, sf: Float64, fctx: FontCtx, d: DrawCmd.DrawableSpec): Unit \ IO =
        let atlas = fctx#atlas;
        let ts = atlas#textureSize;
        let rowH = atlas#ascent + atlas#descent + 2.0;
        let cellH = d#scale#y * ts;
        let bakeScale = if (rowH > 0.0) cellH / rowH else 0.0;
        let displayFontSize = bakeScale * atlas#fontSize;
        let outFontSize = displayFontSize * sf;
        let cellKey = (ri(d#uvOffset#x * ts), ri(d#uvOffset#y * ts));
        match Map.get(cellKey, fctx#codepointByCell) {
            case None     => ()
            case Some(cp) =>
                let str = JChar.toString(cp);
                let baselineX = d#position#x * sf;
                let baselineY = (d#position#y + atlas#ascent * bakeScale) * sf;
                g.setFont(fctx#baseFont.deriveFont(f32(outFontSize)));
                g.setColor(awtColor(d#color, f32(d#alpha)));
                g.drawString(str, f32(baselineX), f32(baselineY))
        }

    /// 単色矩形（角丸＋枠）。scale が design px サイズ、position が左上。
    /// 重ねる順は GL シェーダと同じ 塗り → 縞 → 市松 → 枠。
    def drawBox(g: Graphics2D, sf: Float64, d: DrawCmd.DrawableSpec): Unit \ IO =
        let x = ri(d#position#x * sf);
        let y = ri(d#position#y * sf);
        let bw = ri(d#scale#x * sf);
        let bh = ri(d#scale#y * sf);
        // headless の 1 箱ごとの経路なので、レコードへ 1 回展開して読みやすさを取る。
        let styleSpec = Option.map(DrawCmd.styleToSpec, d#style);
        let (corner, borderW, borderCol, borderA) = match styleSpec {
            case Some(st) => (st#cornerRadius, st#borderWidth, st#borderColor, st#borderAlpha)
            case None     => (0.0, 0.0, ({r = 1.0, g = 1.0, b = 1.0}: Color), 0.0)
        };
        let arc = ri(corner * 2.0 * sf);
        g.setColor(awtColor(d#color, f32(d#alpha)));
        g.fillRoundRect(x, y, bw, bh, arc, arc);
        match styleSpec {
            case Some(st) => drawBoxOverlays(g, sf, d, st)
            case None     => ()
        };
        if (borderW > 0.0 and borderA > 0.0) {
            g.setStroke(new BasicStroke(f32(borderW * sf)));
            g.setColor(awtColor(borderCol, f32(borderA)));
            g.drawRoundRect(x, y, bw, bh, arc, arc)
        } else ()

    /// 塗りの上に縞と市松を重ねる。box の角丸矩形にクリップして描き、終わったら解除する。
    def drawBoxOverlays(g: Graphics2D, sf: Float64, d: DrawCmd.DrawableSpec,
                        st: DrawCmd.BoxStyleSpec): Unit \ IO =
        let hasStripe = st#stripeWidth > 0.0 and st#stripeAlpha > 0.0 and st#stripePeriod > 0.0;
        let hasChecker = st#checkerCell > 0.0 and st#checkerAlpha > 0.0;
        if (hasStripe or hasChecker) {
            // fillRoundRect と同じ丸め済みの値でクリップ形を作り、塗りとぴったり重ねる。
            let x = ri(d#position#x * sf);
            let y = ri(d#position#y * sf);
            let bw = ri(d#scale#x * sf);
            let bh = ri(d#scale#y * sf);
            let arc = ri(st#cornerRadius * 2.0 * sf);
            let shape = new RoundRect(Int32.toFloat64(x), Int32.toFloat64(y),
                                      Int32.toFloat64(bw), Int32.toFloat64(bh),
                                      Int32.toFloat64(arc), Int32.toFloat64(arc));
            // setClip(置き換え)ではなく clip(交差)で重ねる — drawable の clip 矩形(withClip)が
            // 外側に張られているとき、縞・市松がその矩形を破って漏れないため。終わったら退避値へ
            // 戻す(setClip(null) の全解除だと、この後に描く枠線まで矩形の外へ漏れる)。
            let saved = g.getClip();
            g.clip(shape);
            if (hasStripe) drawStripes(g, sf, d, st) else ();
            if (hasChecker) drawChecker(g, sf, d, st) else ();
            g.setClip(saved)
        } else ()

    /// 縞を描く。GL シェーダと同じ box 中心原点のローカル座標 p を使い、
    /// mod(hv, period) が [0, width] に入る範囲を線分で塗る（dir 0: p.x−p.y / 1: p.y / 2: p.x）。
    def drawStripes(g: Graphics2D, sf: Float64, d: DrawCmd.DrawableSpec,
                    st: DrawCmd.BoxStyleSpec): Unit \ IO =
        let bw = d#scale#x * sf;
        let bh = d#scale#y * sf;
        let cx = d#position#x * sf + bw / 2.0;
        let cy = d#position#y * sf + bh / 2.0;
        let period = st#stripePeriod * sf;
        let width = st#stripeWidth * sf;
        g.setColor(awtColor(st#stripeColor, f32(st#stripeAlpha)));
        if (st#stripeDir == 1) {
            // 横縞: 範囲 [hv-width/2, hv+width/2] を塗り矩形で(AA が掛からずくっきり — 走査線用)。
            forEachStripe(period, bh / 2.0, width, hv ->
                g.fill(new Rect2D(cx - bw, cy + hv - width / 2.0, bw * 2.0, width)))
        } else if (st#stripeDir == 2) {
            // 縦縞: 同じく塗り矩形でくっきり。
            forEachStripe(period, bw / 2.0, width, hv ->
                g.fill(new Rect2D(cx + hv - width / 2.0, cy - bh, width, bh * 2.0)))
        } else {
            // 斜め 45°: hv = p.x − p.y。hv 空間の幅 width は幾何学的には width/√2。
            g.setStroke(new BasicStroke(f32(width / Vec2.sqrt(2.0))));
            let l = bw + bh;
            forEachStripe(period, (bw + bh) / 2.0, width, hv ->
                g.draw(new Line2D(cx + hv - l, cy - l, cx + hv + l, cy + l)))
        }

    /// mod(hv, period) が [0, width] の範囲の中心 hv を、[-halfRange, halfRange] に
    /// かかる分だけ列挙して f を呼ぶ（k*period + width/2 の等差列）。
    def forEachStripe(period: Float64, halfRange: Float64, width: Float64,
                      f: Float64 -> Unit \ ef): Unit \ ef =
        let kMin = floorI((-1.0 * halfRange - width) / period);
        let kMax = floorI(halfRange / period);
        List.range(kMin, kMax + 1) |> List.forEach(k ->
            f(Int32.toFloat64(k) * period + width / 2.0))

    /// 市松を描く。GL シェーダと同じ box 中心原点でセルを刻み、
    /// floor(p.x/cell) + floor(p.y/cell) が偶数のセルだけ塗る。
    def drawChecker(g: Graphics2D, sf: Float64, d: DrawCmd.DrawableSpec,
                    st: DrawCmd.BoxStyleSpec): Unit \ IO =
        let bw = d#scale#x * sf;
        let bh = d#scale#y * sf;
        let cx = d#position#x * sf + bw / 2.0;
        let cy = d#position#y * sf + bh / 2.0;
        let cell = st#checkerCell * sf;
        g.setColor(awtColor(st#checkerColor, f32(st#checkerAlpha)));
        let iMin = floorI(-1.0 * bw / 2.0 / cell);
        let iMax = floorI(bw / 2.0 / cell);
        let jMin = floorI(-1.0 * bh / 2.0 / cell);
        let jMax = floorI(bh / 2.0 / cell);
        List.range(iMin, iMax + 1) |> List.forEach(i ->
            List.range(jMin, jMax + 1) |> List.forEach(j ->
                if (Int32.modulo(i + j, 2) == 0)
                    g.fill(new Rect2D(cx + Int32.toFloat64(i) * cell,
                                      cy + Int32.toFloat64(j) * cell, cell, cell))
                else ()))

    /// Float64 の床を Int32 に（縞・市松の格子番号用。負値も床側へ丸める）。
    def floorI(x: Float64): Int32 =
        Num.floorInt(x)

    /// 表示矩形の起点（1 軸ぶん）。規約は GL の Frame.originAxis と同一 — flipH / flipV で
    /// display が負になっても、覆う範囲は position から正の向きへ伸ばす。
    /// dx1 > dx2 の向きが Java2D の drawImage に鏡像を描かせるので、display は負のまま使う。
    def originAxis(centered: Bool, position: Float64, display: Float64): Float64 =
        if (centered) position - display / 2.0
        else if (display < 0.0) position - display
        else position

    /// 画像 Drawable。元テクスチャの uv 部分矩形を切り出し、color で tint・alpha を乗算して
    /// design px の表示矩形へ拡大転写する。font_ アトラス（白グリフ）もこの経路で色が付く。
    def drawTextured(g: Graphics2D, sf: Float64, img: BufferedImage, d: DrawCmd.DrawableSpec): Unit \ IO =
        let texW = Int32.toFloat64(img.getWidth());
        let texH = Int32.toFloat64(img.getHeight());
        let displayW = texW * d#scale#x;
        let displayH = texH * d#scale#y;
        let posX = originAxis(d#centered, d#position#x, displayW);
        let posY = originAxis(d#centered, d#position#y, displayH);
        // 元テクスチャ内の部分矩形（uv → px）。画像範囲へクランプする。
        let sx = clampI(ri(d#uvOffset#x * texW), 0i32, img.getWidth());
        let sy = clampI(ri(d#uvOffset#y * texH), 0i32, img.getHeight());
        let sw = clampI(ri(d#uvScale#x * texW), 1i32, img.getWidth() - sx);
        let sh = clampI(ri(d#uvScale#y * texH), 1i32, img.getHeight() - sy);
        let sub = img.getSubimage(sx, sy, sw, sh);
        // color tint と alpha を各バンドに乗算（白グリフ×tint=文字色、スプライトは概ね白×1）。
        let scales = Array#{f32(d#color#r), f32(d#color#g), f32(d#color#b), f32(d#alpha)} @ Static;
        let offsets = Array#{0.0f32, 0.0f32, 0.0f32, 0.0f32} @ Static;
        let op = new RescaleOp(scales, offsets, unchecked_cast(null as RenderingHints));
        let tinted = op.filter(sub, unchecked_cast(null as BufferedImage));
        let dx1 = ri(posX * sf);
        let dy1 = ri(posY * sf);
        let dx2 = ri((posX + displayW) * sf);
        let dy2 = ri((posY + displayH) * sf);
        discard g.drawImage(tinted, dx1, dy1, dx2, dy2, 0i32, 0i32, sw, sh,
                            unchecked_cast(null as ImageObserver))

    /// clip 矩形(design px)を出力ピクセルへ floor 量子化して張り、draw を実行してから元へ戻す。
    /// 量子化は GL の glScissor と同じ DrawCmd.clipPixels — 同じ画素集合になるのがスナップショットの前提。
    /// 退避・復元で行うので、draw の内側の g.clip(交差)とも安全に入れ子になる。
    def withClip(g: Graphics2D, sf: Float64, clip: Option[Rect2.Rect2], draw: Unit -> Unit \ ef): Unit \ IO + ef =
        match clip {
            case None    => draw()
            case Some(r) => {
                let saved = g.getClip();
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, r);
                g.setClip(x0, y0, Int32.max(0, x1 - x0), Int32.max(0, y1 - y0));
                draw();
                g.setClip(saved)
            }
        }

    /// 頂点色つき多角形を画素ごとに描き出す（面の中の線形補間）。Graphics2D を通さないのは、
    /// Java2D に三角形内の頂点色補間が無いため。内外は画素中心で判定する（AA なし）—
    /// GL の三角形ラスタライズと同じ硬い縁で、単色多角形（Java2D の AA 塗り）とは縁の写りが違う
    /// （対応表 docs/backend-parity.md に記載）。clip・blend は drawSurface と同じ扱いで
    /// この関数の中で済ませる（polygonAabb が clip と画面に切り詰め、blendPixel で混ぜる）。
    def drawGradPolygon(image: BufferedImage, sf: Float64, design: Vec2.Vec2,
                        p: GameEngine.PolygonRenderCmd): Unit \ IO = region rc {
        let tris = DrawCmd.gradTriangles(p);
        let dw = image.getWidth();
        let dh = image.getHeight();
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf },
                                                      polygonAabb(design, p));
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let x1 = Int32.min(dw, rx1);
        let y1 = Int32.min(dh, ry1);
        let w = x1 - x0;
        let h = y1 - y0;
        if (List.isEmpty(tris) or w <= 0i32 or h <= 0i32) ()
        else {
            let n = w * h;
            let buf: Array[Int32, rc] = Array.empty(rc, n);
            discard image.getRGB(x0, y0, w, h, buf, 0i32, w);
            Array.forEachWithIndex((i, dst) -> {
                let px = Int32.remainder(i, w) + x0;
                let py = i / w + y0;
                let at = { x = (Int32.toFloat64(px) + 0.5) / sf,
                           y = (Int32.toFloat64(py) + 0.5) / sf };
                match gradSample(tris, at) {
                    case None     => ()
                    case Some(gv) =>
                        let srcArgb = argbOf(gv#color, gv#alpha);
                        Array.put(blendPixel(p#blend, srcArgb, dst), i, buf)
                }
            }, buf);
            image.setRGB(x0, y0, w, h, buf, 0i32, w)
        }
    }

    /// 扇割り三角形列から、点 at を含む三角形の補間色を引く（どの三角形にも入らなければ None）。
    /// 式は面積比の重み（バリセントリック）— GL が頂点色を画素へ補間するのと同じ線形補間。
    /// 隣り合う三角形の共有辺の上では両者の補間が一致するので、どちらが拾っても同じ色になる。
    pub def gradSample(tris: List[(DrawCmd.GradVertex, DrawCmd.GradVertex, DrawCmd.GradVertex)],
                       at: Vec2.Vec2): Option[DrawCmd.VertexTint] =
        tris |> List.findMap(tri -> triSample(tri, at))

    /// つぶれた三角形（面積 ≈ 0）とみなす行列式の下限。0 割りを避けるためだけの値で、
    /// design px の座標では 1e-9 より小さい面積の三角形は 1 画素にも満たない。
    def degenerateEps(): Float64 = 0.000000001

    /// 1 三角形の中なら重み付き平均の色、外なら None。つぶれた三角形（面積 0）は None。
    def triSample(tri: (DrawCmd.GradVertex, DrawCmd.GradVertex, DrawCmd.GradVertex),
                  at: Vec2.Vec2): Option[DrawCmd.VertexTint] =
        let (a, b, c) = tri;
        let det = (b#pos#y - c#pos#y) * (a#pos#x - c#pos#x)
                + (c#pos#x - b#pos#x) * (a#pos#y - c#pos#y);
        if (Float64.abs(det) < degenerateEps()) None
        else {
            let w0 = ((b#pos#y - c#pos#y) * (at#x - c#pos#x)
                    + (c#pos#x - b#pos#x) * (at#y - c#pos#y)) / det;
            let w1 = ((c#pos#y - a#pos#y) * (at#x - c#pos#x)
                    + (a#pos#x - c#pos#x) * (at#y - c#pos#y)) / det;
            let w2 = 1.0 - w0 - w1;
            if (w0 < 0.0 or w1 < 0.0 or w2 < 0.0) None
            else {
                let lerp3 = f -> f32(w0 * f(a) + w1 * f(b) + w2 * f(c));
                let ch = g -> Float32.toFloat64(lerp3(v -> Float32.toFloat64(f32(g(v)))));
                Some({ color = { r = ch(v -> v#color#r),
                                 g = ch(v -> v#color#g),
                                 b = ch(v -> v#color#b) },
                       alpha = Float32.toFloat64(lerp3(v -> v#alpha)) })
            }
        }

    /// 多角形塗り。頂点は design px。
    def drawPolygon(rc: Region[r], g: Graphics2D, sf: Float64, p: GameEngine.PolygonRenderCmd): Unit \ IO + r =
        let xs = List.toArray(rc, List.map(v -> ri(v#x * sf), p#vertices));
        let ys = List.toArray(rc, List.map(v -> ri(v#y * sf), p#vertices));
        let n = List.length(p#vertices);
        g.setColor(awtColor(p#color, f32(p#alpha)));
        g.fillPolygon(xs, ys, n)

    /// Flix Color(0..1) + alpha を AWT Color(0..255) へ。
    def awtColor(c: Color, alpha: Float32): AwtColor \ IO =
        new AwtColor(byteOf(f32(c#r)), byteOf(f32(c#g)), byteOf(f32(c#b)), byteOf(alpha))

    /// Float64 → Float32（BasicStroke 用）。
    def f32(x: Float64): Float32 =
        Float64.clampToFloat32(min = -1.0e18f32, max = 1.0e18f32, x)

    /// 0..1 の成分を 0..255 の Int32 へ丸めてクランプ。
    def byteOf(x: Float32): Int32 =
        clampI(ri(Float32.toFloat64(x) * 255.0), 0i32, 255i32)

    /// Float64 を四捨五入して Int32 に（非負前提）。
    def ri(x: Float64): Int32 =
        Float64.tryToInt32(x + 0.5) |> Option.getWithDefault(0i32)

    /// v を [lo, hi] に収める。
    def clampI(v: Int32, lo: Int32, hi: Int32): Int32 =
        Int32.max(lo, Int32.min(hi, v))

    /// BufferedImage を PNG として書く。親ディレクトリが無ければ作る。
    def writePng(image: BufferedImage, path: String): Unit \ IO =
        let file = new File(path);
        let parent = file.getParentFile();
        if (not Object.isNull(parent)) discard parent.mkdirs() else ();
        discard ImageIO.write(image, "png", file)

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
