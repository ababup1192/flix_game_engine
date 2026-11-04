// SoftRaster.Internal.Blend — Add / Multiply の重ね方（下書きへ描いてから合成式で混ぜる）と、
// 合成で往復する範囲を絞る外形（AABB）。SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲーム向けの関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Blend {
    import java.awt.image.BufferedImage
    import java.awt.Graphics2D
    use SoftRaster.{QualityHints, applyQualityHints, blendPixel, channelOf, withClip}

    // ════════════════════════════════════════════════════════
    // ブレンド合成（Add / Multiply — Java2D 標準 Composite に無い重ね方）
    // ════════════════════════════════════════════════════════

    /// Normal 以外の描画: いったん透明な下書き画像へ普通に描き、その画素を合成式で本体に混ぜる。
    /// clip は下書きへの描画に掛ける — 透明のまま残った画素は合成しないので、切り抜きの外は本体に触れない。
    /// 下書き自体は本体と同じ全面サイズで確保するが（Graphics2D の clip 計算を素直に保つため）、
    /// getRGB/setRGB で往復する範囲は `aabb`（drawable/polygon の外形、画面クランプ・design px）
    /// だけに絞る — 全面走査だと 1 個の光源・炎エフェクトのために毎フレーム画面全体を
    /// 読み書きすることになり、drawable 数に対して不釣り合いに重くなるため。
    pub def blendedDraw(image: BufferedImage, sf: Float64, hints: QualityHints, blend: DrawCmd.BlendMode,
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
    pub def drawableAabb(design: Vec2.Vec2, textures: Map[String, BufferedImage],
                     d: DrawCmd.DrawableSpec): Rect2.Rect2 \ IO =
        if (String.startsWith({prefix = "font_"}, d#texture))
            fullDesignRect(design)
        else {
            let base = if (String.isEmpty(d#texture)) { x = 1.0, y = 1.0 }
                       else match Map.get(d#texture, textures) {
                           // 表示の大きさは drawTextured と同じ「テクスチャ全寸 × scale」。
                           // WhyNot: uvScale を掛けない — regionRect 付きの sprite（アトラスの 1 コマ）は scale の側で
                           //   既に region の割合を掛けてあるので、二重に掛けると外形が小さくなり、Add / Multiply の合成が欠ける。
                           case Some(img) =>
                               { x = Int32.toFloat64(img.getWidth()),
                                 y = Int32.toFloat64(img.getHeight()) }
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
    pub def polygonAabb(design: Vec2.Vec2, p: GameEngine.PolygonRenderCmd): Rect2.Rect2 =
        let aabb = match p#vertices {
            case Nil       => { position = Vec2.zero(), size = Vec2.zero() }
            case v :: rest =>
                let lo = List.foldLeft((acc, q) -> { x = Float64.min(acc#x, q#x), y = Float64.min(acc#y, q#y) }, v, rest);
                let hi = List.foldLeft((acc, q) -> { x = Float64.max(acc#x, q#x), y = Float64.max(acc#y, q#y) }, v, rest);
                { position = lo, size = Vec2.sub(hi, lo) }
        };
        clampAabb(design, p#clip, Rect2.grow(1.0, aabb))
}
