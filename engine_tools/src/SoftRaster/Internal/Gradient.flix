// SoftRaster.Internal.Gradient — 頂点色つき多角形を画素ごとに描く（三角形の中の色を頂点の色からなめらかにつなぐ）。
// SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲーム向けの関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Gradient {
    import java.awt.image.BufferedImage
    use SoftRaster.{HdrCanvas, argbOfRgba, blendPixel, blendPixelF, f32, forEachPixel, onceOutsideLoop, shadeAll}
    use SoftRaster.Internal.Blend.{polygonAabb}

    /// 頂点色つき多角形の Rgba16Float 版（drawGradPolygon と同じ内外判定・補間。色は 8bit に丸めずに混ぜる）。
    pub def drawGradPolygonHdr(canvas: HdrCanvas, sf: Float64, design: Vec2.Vec2,
                           p: GameEngine.PolygonRenderCmd): Unit \ IO = region rc {
        let tris = DrawCmd.gradTriangles(p);
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, polygonAabb(design, p));
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let w = Int32.min(canvas#width, rx1) - x0;
        let h = Int32.min(canvas#height, ry1) - y0;
        if (List.isEmpty(tris) or w <= 0i32 or h <= 0i32) ()
        else {
            let compiled = onceOutsideLoop(rc, compileGradTris(tris));
            let blend = onceOutsideLoop(rc, p#blend);
            forEachPixel(w * h, j -> {
                let px = Int32.remainder(j, w) + x0;
                let py = j / w + y0;
                match firstGradHit(compiled, (Int32.toFloat64(px) + 0.5) / sf, (Int32.toFloat64(py) + 0.5) / sf) {
                    case None               => ()
                    case Some((r, g, b, a)) => blendPixelF(blend, r, g, b, Num.clamp01(a), canvas#rgba, py * canvas#width + px)
                }
            })
        }
    }

    /// 頂点色つき多角形を画素ごとに描き出す（面の中の線形補間）。Graphics2D を通さないのは、
    /// Java2D に三角形内の頂点色補間が無いため。内外は画素中心で判定する（AA なし）—
    /// GL の三角形ラスタライズと同じ硬い縁で、単色多角形（Java2D の AA 塗り）とは縁の写りが違う
    /// （対応表 docs/backend-parity.md に記載）。clip・blend は drawSurface と同じ扱いで
    /// この関数の中で済ませる（polygonAabb が clip と画面に切り詰め、blendPixel で混ぜる）。
    pub def drawGradPolygon(image: BufferedImage, sf: Float64, design: Vec2.Vec2,
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
            // 三角形は多角形ごとに 1 回だけ位置で持つ形へ組み直す（onceOutsideLoop の WhyNot）。
            let compiled = onceOutsideLoop(rc, compileGradTris(tris));
            let blend = onceOutsideLoop(rc, p#blend);
            // 下地の画素（読むだけ）。1 画素の答えは下地と三角形だけで決まるので、drawSurface と
            // 同じく shadeAll でコアの数だけ並べても 1 本で回しても同じ列になる。
            let dstPixels = Array.toVector(buf);
            let pixelOf = i -> {
                let px = Int32.remainder(i, w) + x0;
                let py = i / w + y0;
                let x = (Int32.toFloat64(px) + 0.5) / sf;
                let y = (Int32.toFloat64(py) + 0.5) / sf;
                let dst = Vector.get(i, dstPixels);
                match firstGradHit(compiled, x, y) {
                    case None               => dst
                    case Some((r, g, b, a)) => blendPixel(blend, argbOfRgba(r, g, b, a), dst)
                }
            };
            image.setRGB(x0, y0, w, h, shadeAll(n, pixelOf), 0i32, w)
        }
    }

    /// つぶれた三角形（面積 ≈ 0）とみなす行列式の下限。0 割りを避けるためだけの値で、
    /// design px の座標では 1e-9 より小さい面積の三角形は 1 画素にも満たない。
    def degenerateEps(): Float64 = 0.000000001

    /// 扇の三角形 1 つを、画素ごとの計算に要る数だけ位置で持つ形。GradVertex の record の欄は
    /// 組み直しで 1 回だけ読み、画素ごとには読まない（record の欄は名前で引くので画素ごとには重い）。
    pub enum GradTri {
        // c の x, y・重みの係数 (b.y−c.y), (c.x−b.x), (c.y−a.y), (a.x−c.x)・行列式・
        // 頂点 a, b, c の色と濃さ（r, g, b, α を a, b, c の順に 12 個。色は Float32 に落として戻した値）
        case GradTri(Float64, Float64, Float64, Float64, Float64, Float64, Float64, Vector[Float64])
    }

    /// 三角形列を GradTri の列へ組み直す（多角形ごとに 1 回）。つぶれた三角形（面積 0）はどの点も
    /// 含まないので、ここで落とす。
    pub def compileGradTris(tris: List[(DrawCmd.GradVertex, DrawCmd.GradVertex, DrawCmd.GradVertex)]): List[GradTri] =
        tris |> List.filterMap(tri -> {
            let (a, b, c) = tri;
            let byCy = b#pos#y - c#pos#y;
            let cxBx = c#pos#x - b#pos#x;
            let cyAy = c#pos#y - a#pos#y;
            let axCx = a#pos#x - c#pos#x;
            let det = byCy * axCx + cxBx * (a#pos#y - c#pos#y);
            let rounded = x -> Float32.toFloat64(f32(x));
            let tints = Vector#{rounded(a#color#r), rounded(a#color#g), rounded(a#color#b), a#alpha,
                                rounded(b#color#r), rounded(b#color#g), rounded(b#color#b), b#alpha,
                                rounded(c#color#r), rounded(c#color#g), rounded(c#color#b), c#alpha};
            if (Float64.abs(det) < degenerateEps()) None
            else Some(GradTri.GradTri(c#pos#x, c#pos#y, byCy, cxBx, cyAy, axCx, det, tints))
        })

    /// 点 (x, y) を含む最初の三角形の補間 (r, g, b, α)。どれにも入らなければ None。
    pub def firstGradHit(tris: List[GradTri], x: Float64, y: Float64): Option[(Float64, Float64, Float64, Float64)] =
        match tris {
            case Nil          => None
            case tri :: rest  => match gradTriSample(tri, x, y) {
                case Some(rgba) => Some(rgba)
                case None       => firstGradHit(rest, x, y)
            }
        }

    /// 1 三角形の中なら重み付き平均の (r, g, b, α)、外なら None。各成分は Float32 に落として返す
    /// （GL が頂点色を Float32 で補間するのと同じ丸め）。
    def gradTriSample(tri: GradTri, x: Float64, y: Float64): Option[(Float64, Float64, Float64, Float64)] =
        let GradTri.GradTri(cx, cy, byCy, cxBx, cyAy, axCx, det, tints) = tri;
        let w0 = (byCy * (x - cx) + cxBx * (y - cy)) / det;
        let w1 = (cyAy * (x - cx) + axCx * (y - cy)) / det;
        let w2 = 1.0 - w0 - w1;
        if (w0 < 0.0 or w1 < 0.0 or w2 < 0.0) None
        else {
            let lerp = k -> Float32.toFloat64(f32(w0 * Vector.get(k, tints)
                                                 + w1 * Vector.get(k + 4, tints)
                                                 + w2 * Vector.get(k + 8, tints)));
            Some((lerp(0), lerp(1), lerp(2), lerp(3)))
        }
}
