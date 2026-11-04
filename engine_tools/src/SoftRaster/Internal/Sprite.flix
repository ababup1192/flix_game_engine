// SoftRaster.Internal.Sprite — Graphics2D で描く 2D の描き物: box（角丸・枠・縞・市松）・テクスチャの sprite・単色の多角形と、
// その周りの回転・mask・clip・描画品質ヒント。SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲームが使う関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Sprite {
    import java.awt.image.BufferedImage
    import java.awt.image.RescaleOp
    import java.awt.image.ImageObserver
    import java.awt.Graphics2D
    import java.awt.RenderingHints
    import java.awt.BasicStroke
    import java.awt.geom.{Path2D$Double => Path2D}
    import java.awt.geom.{RoundRectangle2D$Double => RoundRect}
    import java.awt.geom.{Line2D$Double => Line2D}
    import java.awt.geom.{Rectangle2D$Double => Rect2D}
    use SoftRaster.{FontTable, QualityHints, TexWarnLog, awtColor, clampI, f32, ri, warnMissingTexture}
    use SoftRaster.Internal.Text.{drawGlyph, fontFor, withTextHints}

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
    pub def applyQualityHints(g: Graphics2D, hints: QualityHints): Unit \ IO =
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

    /// 1 つの Drawable を描く。texture が空なら box、`font_` ならグリフを直接 drawString、
    /// それ以外はテクスチャ画像。
    pub def drawDrawable(g: Graphics2D, sf: Float64,
                     textures: Map[String, BufferedImage], fctx: FontTable, d: DrawCmd.DrawableSpec,
                     warnLog: TexWarnLog): Unit \ IO =
        withRotation(g, sf, d#rotation, quadCenter(textures, fctx, d), () ->
            if (String.isEmpty(d#texture))
                withMask(g, sf, d#position, d#scale, d#mask, () -> drawBox(g, sf, d))
            else if (String.startsWith({prefix = "font_"}, d#texture))
                // グリフは mask の対象外（文字の可読性が第一 — docs/backend-parity.md）。
                match Map.get(d#texture, fctx#antialiasByTexture) {
                    case None         => drawGlyph(g, sf, fontFor(fctx, d), d)
                    case Some(smooth) => withTextHints(g, smooth, () -> drawGlyph(g, sf, fontFor(fctx, d), d))
                }
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
            g.setStroke(new BasicStroke(f32(width / Num.sqrt(2.0))));
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

    /// 表示矩形の起点（1 軸ぶん）。規約は GL の RenderFrame.originAxis と同一 — flipH / flipV で
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
    pub def withClip(g: Graphics2D, sf: Float64, clip: Option[Rect2.Rect2], draw: Unit -> Unit \ ef): Unit \ IO + ef =
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

    /// 多角形塗り。頂点は design px。
    pub def drawPolygon(rc: Region[r], g: Graphics2D, sf: Float64, p: GameEngine.PolygonRenderCmd): Unit \ IO + r =
        let xs = List.toArray(rc, List.map(v -> ri(v#x * sf), p#vertices));
        let ys = List.toArray(rc, List.map(v -> ri(v#y * sf), p#vertices));
        let n = List.length(p#vertices);
        g.setColor(awtColor(p#color, f32(p#alpha)));
        g.fillPolygon(xs, ys, n)
}
