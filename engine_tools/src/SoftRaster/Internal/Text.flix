// SoftRaster.Internal.Text — フォント（グリフ Drawable を出力解像度の TTF で直接描く）。フォントの表を組み、
// グリフ 1 つを描き、字の縁の設定を本ごとに切り替える。SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲームが使う関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Text {
    import java.awt.Graphics2D
    import java.awt.RenderingHints
    import java.awt.Font
    import java.awt.font.GlyphVector
    import java.io.FileInputStream
    import java.lang.{Character => JChar}
    import java.lang.{Object => JObject}
    use SoftRaster.{FontAntialias, FontCtx, FontEntry, FontTable, RasterReq, TextureCache, awtColor, f32, ri}

    pub def fontFor(fonts: FontTable, d: DrawCmd.DrawableSpec): FontCtx =
        Map.get(d#texture, fonts#byTexture) |> Option.getWithDefault(fonts#primary)

    // ════════════════════════════════════════════════════════
    // フォント（グリフ Drawable を出力解像度で直接 drawString）
    // ════════════════════════════════════════════════════════

    /// 既定フォントと追加フォントを読み、テクスチャ名で引ける一式にする。
    /// 既定フォントも自分のテクスチャ名（fontAtlas#textureName）で引けるように入れておく —
    /// そうしないと既定と同じ名前の追加を渡されたときに二重に持つことになる。
    /// cache があれば、同じ TTF とアトラスの一式を 2 枚目からは組み直さない。
    pub def buildFontTable(cache: Option[TextureCache], req: RasterReq, extraFonts: Map[String, FontEntry],
                       fontAntialias: FontAntialias): FontTable \ IO =
        let primary = fontCtxOf(cache, req#fontTtf, req#fontAtlas);
        let table = Map.foldLeftWithKey((acc, texName, e) ->
            Map.insert(texName, fontCtxOf(cache, e#ttf, e#atlas), acc),
            Map#{ req#fontAtlas#textureName => primary }, extraFonts);
        { primary = primary, byTexture = table,
          antialiasByTexture = fontAntialias }

    /// TTF とアトラスの一式。cache に同じ TTF・同じアトラス（中身で比べる）の物があればそれを使い、
    /// 同じ TTF で別のアトラスなら読んだ Font だけ使い回す。比べるのは表を組むより安い
    /// （名前・大きさ・グリフの数が違えば中身を見ずに外れ）。
    def fontCtxOf(cache: Option[TextureCache], ttfPath: String, atlas: FontAtlas): FontCtx \ IO =
        match cache {
            case None => buildFontCtx(loadFont(ttfPath), atlas)
            case Some(TextureCache.TextureCache(_, _, fonts, _)) =>
                let known: List[FontCtx] = fonts.get(ttfPath);
                let ctxs = if (Object.isNull(known)) Nil else known;
                match List.find(c -> sameAtlas(c#atlas, atlas), ctxs) {
                    case Some(hit) => hit
                    case None =>
                        let base = match ctxs {
                            case c :: _ => c#baseFont
                            case Nil    => loadFont(ttfPath)
                        };
                        let made = buildFontCtx(base, atlas);
                        // 別のスレッドと同時に足しても、外れるのは組み直す回数だけ（どれも同じ中身）。
                        discard fonts.put(ttfPath, made :: ctxs);
                        made
                }
        }

    /// 2 つのアトラスが同じ中身か。安い欄から比べ、最後にグリフの表を 1 字ずつ比べる
    /// （record には == が無いので欄ごとに比べる）。
    def sameAtlas(a: FontAtlas, b: FontAtlas): Bool =
        a#textureName == b#textureName and a#textureSize == b#textureSize and a#fontSize == b#fontSize
            and a#ascent == b#ascent and a#descent == b#descent and a#lineGap == b#lineGap
            and Map.size(a#glyphs) == Map.size(b#glyphs)
            and Map.forAll((cp, g) -> match Map.get(cp, b#glyphs) {
                case Some(h) => sameGlyph(g, h)
                case None    => false
            }, a#glyphs)

    /// 2 つのグリフのメトリクスが同じか。
    def sameGlyph(g: TextLayout.GlyphMetrics, h: TextLayout.GlyphMetrics): Bool =
        g#xOff == h#xOff and g#yOff == h#yOff and g#glyphW == h#glyphW and g#glyphH == h#glyphH
            and g#advance == h#advance and g#s0 == h#s0 and g#t0 == h#t0 and g#s1 == h#s1 and g#t1 == h#t1

    /// TTF を Font として読む（サイズは描く時に deriveFont で決める）。
    def loadFont(ttfPath: String): Font \ IO =
        let fis = new FileInputStream(ttfPath);
        let base = Font.createFont(0i32, fis);
        fis.close();
        base

    /// アトラスの各グリフの s0/t0 からセル左上 px を逆算した codepoint 表を組む。
    def buildFontCtx(base: Font, atlas: FontAtlas): FontCtx =
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
    pub def drawGlyph(g: Graphics2D, sf: Float64, fctx: FontCtx, d: DrawCmd.DrawableSpec): Unit \ IO =
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
                let font = fctx#baseFont.deriveFont(f32(outFontSize));
                g.setFont(font);
                g.setColor(awtColor(d#color, f32(d#alpha)));
                let off: JObject = RenderingHints.VALUE_TEXT_ANTIALIAS_OFF;
                if (off.equals(g.getRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING)))
                    fillGlyphOutline(g, font, str, f32(baselineX), f32(baselineY))
                else
                    g.drawString(str, f32(baselineX), f32(baselineY))
        }

    /// 字の縁をならさない字は、字の輪郭を面として縁を切って塗る（字の色と背景の色だけになる）。
    /// WhyNot: drawString に任せない — この JVM の字の描き手は TEXT_ANTIALIAS_OFF でも縁に中間色を出す
    /// （Xolonium の 12px で 37 色・輪郭を塗ると 2 色。FontRenderContext は「ならさない」と言うのに出る）。
    /// ならす字は drawString のまま（今の絵を 1 画素も変えない）。
    def fillGlyphOutline(g: Graphics2D, font: Font, str: String, x: Float32, y: Float32): Unit \ IO =
        let glyphs: GlyphVector = font.createGlyphVector(g.getFontRenderContext(), str);
        let shapes = g.getRenderingHint(RenderingHints.KEY_ANTIALIASING);
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_OFF);
        g.fill(glyphs.getOutline(x, y));
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, shapes)

    /// 字の縁と送り幅を smooth にして draw し、元の設定へ戻す（本ごとに決めた字だけ絵全体の設定と違えるため）。
    pub def withTextHints(g: Graphics2D, smooth: Bool, draw: Unit -> Unit \ IO): Unit \ IO =
        let antialias = g.getRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING);
        let metrics = g.getRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING,
            if (smooth) RenderingHints.VALUE_TEXT_ANTIALIAS_ON else RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS,
            if (smooth) RenderingHints.VALUE_FRACTIONALMETRICS_ON else RenderingHints.VALUE_FRACTIONALMETRICS_OFF);
        draw();
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, antialias);
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, metrics)
}
