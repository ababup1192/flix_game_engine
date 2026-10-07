// HeadlessFont — GL を使わずに TTF から FontAtlas を組み立てるヘッドレスなフォント生成。
//
// エンジン実機は STBTruetype + OpenGL で SDF アトラスを GPU テクスチャに生成するが、
// テスト（スナップショット）や将来の IDE ビューポートのように GL コンテキストが無い場所では
// それが使えない。ここでは Java2D（AWT）の FontMetrics だけで
//   1. TTF を読み実測メトリクス（advance / ascent / descent）を得て `FontAtlas` を組む
//   2. 各グリフの仮想アトラス座標（s0/t0/s1/t1）をペン位置から計算する
// を行う。グリフ画像そのものは生成しない — SoftRaster はアトラス PNG をサンプルせず、
// 出力解像度の Font で `drawString` を直接呼ぶ（SoftRaster.flix 参照）ため、実ラスタは不要で
// メトリクスと codepoint↔セル座標の対応表だけが要る。生成サイズ・アトラス寸法・グリフ配置は
// Text.toDrawables が期待するメトリクス規約（yOff = -ascent でセル上端が行トップに一致）に
// 合わせてある。
pub mod HeadlessFont {
    import java.awt.image.BufferedImage
    import java.awt.Graphics2D
    import java.awt.Font
    import java.awt.FontMetrics
    import java.io.FileInputStream
    import java.lang.System

    /// AWT をヘッドレスに固定する。macOS では `-XstartOnFirstThread`（GLFW/AppKit がメインスレッドを
    /// 占有）下で非ヘッドレス AWT を初期化するとメインスレッド待ちでデッドロックするため、
    /// 最初の AWT 使用より前に必ず呼ぶ。GraphicsEnvironment 初期化前に設定すれば有効。
    pub def ensureHeadless(): Unit \ IO =
        discard System.setProperty("java.awt.headless", "true")

    /// 生成ピクセル高さ。表示は Text 側で fontSize/atlas#fontSize 倍に縮小されるので、
    /// 実機の 16px より大きめに生成して縮小時のディテールを残す。
    def bakeSize(): Float32 = 32.0f32

    /// 仮想アトラスの一辺（正方）。実画像は生成しないが、s0/t0/s1/t1（0..1 正規化 UV）の分母として
    /// Text 側の displaySize 計算（texInfo#width == textureSize 前提）と揃える必要がある。
    /// フォントが持つ全 BMP グリフ（日本語フォントで ~8,000 字）が収まる大きさ。
    def atlasDim(): Int32 = 4096

    /// アトラス生成の中間状態。次のグリフを置くペン位置と、確定したメトリクス表。
    type alias PackState = {
        penX = Int32,
        penY = Int32,
        glyphs = Map[Int32, TextLayout.GlyphMetrics]
    }

    /// `ttfPath` の TTF から FontAtlas（メトリクス + codepoint↔セル座標の対応表）を組む。
    /// グリフ画像は生成しない（SoftRaster が出力解像度で直接 drawString するため不要 — HeadlessFont
    /// 冒頭コメント参照）。生成する文字は**そのフォントが持つ BMP の全グリフ**（実機の
    /// RenderFont と同じ思想 — 使う字の登録リストは無い）。第 2 引数はかつての常用漢字ファイル
    /// パスで、いまは読まない（呼び出し側の互換のため残してある）。
    /// 返す FontAtlas は Text.measure / toDrawables がそのまま使えるメトリクスを持つ
    /// （textureName = "font_ui"、textureSize = 仮想アトラス一辺）。
    pub def buildUiAtlas(ttfPath: String, _joyoPath: String): FontAtlas \ IO =
        buildAtlas("ui", ttfPath)

    /// 名前つきでアトラスを組む（textureName = "font_${name}"）。実機の RenderFont が
    /// project.json の fonts[].name から付ける名前と同じ規約なので、複数フォントを生成するときは
    /// **実機と同じ name を渡す** — 名前が食い違うと SoftRaster がそのフォントを見つけられず、
    /// その文字が PNG から黙って消える。
    pub def buildAtlas(name: String, ttfPath: String): FontAtlas \ IO =
        ensureHeadless();
        let font = loadFont(ttfPath);
        // メトリクス測定用の 1x1 スクラッチ。
        let probe = new BufferedImage(1i32, 1i32, 2i32);
        let pg: Graphics2D = probe.createGraphics();
        pg.setFont(font);
        let fm: FontMetrics = pg.getFontMetrics();
        let ascent = fm.getAscent();
        let descent = fm.getDescent();
        let leading = fm.getLeading();
        pg.dispose();
        let rowH = ascent + descent + 2i32;
        let dim = atlasDim();
        let dimF = Int32.toFloat64(dim);
        let init: PackState = { penX = 0i32, penY = 0i32, glyphs = Map.empty() };
        let baked = List.foldLeft((state, cp) ->
            bakeGlyph(fm, ascent, rowH, dim, dimF, state, cp), init, codepointsOf(font));
        { textureName = "font_${name}",
          fontSize = Float32.toFloat64(bakeSize()),
          textureSize = dimF,
          ascent = Int32.toFloat64(ascent),
          descent = Int32.toFloat64(descent),
          lineGap = Int32.toFloat64(leading),
          glyphs = baked#glyphs }

    /// フォントが実際にグリフを持つ BMP のコードポイントをすべて列挙する（U+0020..U+FFFF を走査）。
    def codepointsOf(font: Font): List[Int32] \ IO =
        List.range(0x20, 0x10000) |> List.filter(cp -> font.canDisplay(cp))

    /// 1 グリフの仮想アトラス上の位置を確定し、メトリクスを記録して次のペン位置を返す
    /// （実描画はしない — 位置とメトリクスの計算のみ）。
    /// advance が 0 以下（制御文字など）はスキップ。行に収まらなければ次の行へ折り返す。
    def bakeGlyph(fm: FontMetrics, ascent: Int32, rowH: Int32, dim: Int32,
                  dimF: Float64, state: PackState, cp: Int32): PackState \ IO =
        let advance = fm.charWidth(cp);
        if (advance <= 0i32)
            state
        else {
            let cellW = advance;
            let (penX, penY) =
                if (state#penX + cellW > dim) (0i32, state#penY + rowH)
                else (state#penX, state#penY);
            // ベースラインはセル上端から ascent 下（実描画は無いが、drawGlyph 側の逆算規約と揃える）。
            let penXF = Int32.toFloat64(penX);
            let penYF = Int32.toFloat64(penY);
            let cellWF = Int32.toFloat64(cellW);
            let rowHF = Int32.toFloat64(rowH);
            let gm: TextLayout.GlyphMetrics = {
                xOff = 0.0, yOff = -1.0 * Int32.toFloat64(ascent),
                glyphW = cellWF, glyphH = rowHF,
                advance = Int32.toFloat64(advance),
                s0 = penXF / dimF, t0 = penYF / dimF,
                s1 = (penXF + cellWF) / dimF, t1 = (penYF + rowHF) / dimF
            };
            { penX = penX + cellW, penY = penY, glyphs = Map.insert(cp, gm, state#glyphs) }
        }

    /// TTF を TRUETYPE_FONT(0) として読み、生成サイズへ deriveFont する。
    def loadFont(ttfPath: String): Font \ IO =
        let fis = new FileInputStream(ttfPath);
        let base = Font.createFont(0i32, fis);
        fis.close();
        base.deriveFont(bakeSize())
}
