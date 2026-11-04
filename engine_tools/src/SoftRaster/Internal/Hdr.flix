// SoftRaster.Internal.Hdr — Rgba16Float の描き先（1 を超える値を持つ Pass）を作る・塗る・凍らせる・
// 1 つの描き物を下書きから混ぜる。SoftRaster の中身。
// ゲームからは呼ばない（SoftRaster の中身。ゲーム向けの関数は SoftRaster にある）。
pub mod SoftRaster.Internal.Hdr {
    import java.awt.image.BufferedImage
    import java.awt.Graphics2D
    use SoftRaster.{HdrCanvas, PassImage, QualityHints, blendPixelF, channelOf, forEachPixel, passImageSize, putHdr}
    use SoftRaster.Internal.Sprite.{applyQualityHints, withClip}

    pub def blankHdrCanvas(w: Int32, h: Int32): HdrCanvas \ IO =
        { width = w, height = h, rgba = Array.repeat(Static, Int32.max(1, w * h) * 4, 0.0) }

    /// img の写しの描き先（Rgba8Unorm は 8bit の値を 0..1 にして写す）。
    pub def hdrCanvasOf(img: PassImage): HdrCanvas \ IO =
        let (w, h) = passImageSize(img);
        let canvas = blankHdrCanvas(w, h);
        match img {
            case PassImage.Rgba16Float(hdr) =>
                forEachPixel(w * h * 4, i -> Array.put(ShaderEval.hdrChannelOf(hdr, i), i, canvas#rgba))
            case PassImage.Rgba8Unorm(argb) =>
                let pixels: Array[Int32, Static] = Array.repeat(Static, w * h, 0);
                discard argb.getRGB(0i32, 0i32, w, h, pixels, 0i32, w);
                forEachPixel(w * h, i -> {
                    let p = Array.get(i, pixels);
                    let ch = (shift: Int32) -> Int32.toFloat64(channelOf(shift, p)) / 255.0;
                    putHdr(canvas#rgba, i, (ShaderEval.roundToHalf(ch(16)), ShaderEval.roundToHalf(ch(8)), ShaderEval.roundToHalf(ch(0)), ShaderEval.roundToHalf(ch(24))))
                })
        };
        canvas

    /// 描き終えた描き先を凍らせる（以降は PassImage として読むだけ）。
    pub def freezeHdr(canvas: HdrCanvas): ShaderEval.HdrTexture \ IO =
        ShaderEval.hdrTextureOf(canvas#width, canvas#height, Array.toVector(canvas#rgba))

    /// 描き先の全面を c の不透明で塗る（fillClear の Rgba16Float 版。c は 0..1 に切らない）。
    pub def fillClearHdr(canvas: HdrCanvas, c: Color): Unit \ IO =
        let px = (ShaderEval.roundToHalf(c#r), ShaderEval.roundToHalf(c#g), ShaderEval.roundToHalf(c#b), 1.0);
        forEachPixel(canvas#width * canvas#height, i -> putHdr(canvas#rgba, i, px))

    /// 面の出力の書き込みの決まり（ShaderGen の GLSL の最後の行と同じ）: rgb は [0, 65504]・α は [0, 1]。
    pub def writeRule(r: Float64, g: Float64, b: Float64, a: Float64): (Float64, Float64, Float64, Float64) =
        let rgb = (x: Float64) -> if (x < 0.0) 0.0 else if (x > 65504.0) 65504.0 else x;
        (rgb(r), rgb(g), rgb(b), Num.clamp01(a))

    /// Normal も含め、1 つの描き物を 8bit の下書きに描いて blendPixelF で混ぜる（blendedDraw の Rgba16Float 版）。
    pub def blendedDrawHdr(canvas: HdrCanvas, sf: Float64, hints: QualityHints, blend: DrawCmd.BlendMode,
                       clip: Option[Rect2.Rect2], aabb: Rect2.Rect2,
                       draw: Graphics2D -> Unit \ ef): Unit \ IO + ef = region rc {
        let w = Int32.max(1i32, canvas#width);
        let h = Int32.max(1i32, canvas#height);
        let scratch = new BufferedImage(w, h, 2i32);
        let gs: Graphics2D = scratch.createGraphics();
        applyQualityHints(gs, hints);
        withClip(gs, sf, clip, () -> draw(gs));
        gs.dispose();
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, aabb);
        let x0 = Int32.max(0i32, rx0);
        let y0 = Int32.max(0i32, ry0);
        let bw = Int32.min(w, rx1) - x0;
        let bh = Int32.min(h, ry1) - y0;
        if (bw <= 0i32 or bh <= 0i32) ()
        else {
            let srcBuf: Array[Int32, rc] = Array.empty(rc, bw * bh);
            discard scratch.getRGB(x0, y0, bw, bh, srcBuf, 0i32, bw);
            Array.forEachWithIndex((j, sp) -> {
                if (channelOf(24, sp) == 0) ()
                else {
                    let unit = (shift: Int32) -> Int32.toFloat64(channelOf(shift, sp)) / 255.0;
                    let i = (y0 + j / bw) * canvas#width + x0 + Int32.remainder(j, bw);
                    blendPixelF(blend, unit(16), unit(8), unit(0), unit(24), canvas#rgba, i)
                }
            }, srcBuf)
        }
    }
}
