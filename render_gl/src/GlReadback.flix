// GlReadback — いま bind 中のフレームバッファ（FBO でも既定でも）を読み出して画像にする核。
// GL は左下原点なので、行を逆順に詰めて左上原点にそろえる。読み出しの詰め替えを
// ここ 1 か所に集めるのは、splashShot・注釈スクショ・突き合わせ harness で同じコードが
// 3 つに増えると、上下反転やチャンネル順の直しがどれか 1 つだけ取り残されるため。
pub mod GlReadback {
    import java.awt.image.BufferedImage
    import java.io.File
    import javax.imageio.ImageIO
    import org.lwjgl.opengl.GL11
    import org.lwjgl.system.MemoryUtil

    /// bind 中のフレームバッファを RGBA で読み、左上原点の画像（alpha 付き）にする。
    /// 呼べるのは GL コンテキストが現在のスレッド（withLwjgl の f の中）だけ。
    pub def readBoundImage(w: Int32, h: Int32): BufferedImage \ IO =
        region rc {
            let buf = MemoryUtil.memAlloc(w * h * 4);
            GL11.glReadPixels(0, 0, w, h, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, buf);
            // 2i32 = TYPE_INT_ARGB。pass の絵は透明画素を持つので alpha を落とさず運ぶ。
            let image = new BufferedImage(w, h, 2i32);
            let pixels: Array[Int32, rc] = Array.empty(rc, w * h);
            let xs = List.range(0, w);
            List.forEach(y -> {
                let srcRowStart = (h - 1 - y) * w;
                List.forEach(x -> {
                    let src = (srcRowStart + x) * 4;
                    let r = Int32.bitwiseAnd(Int8.toInt32(buf.get(src)), 255);
                    let g = Int32.bitwiseAnd(Int8.toInt32(buf.get(src + 1)), 255);
                    let b = Int32.bitwiseAnd(Int8.toInt32(buf.get(src + 2)), 255);
                    let a = Int32.bitwiseAnd(Int8.toInt32(buf.get(src + 3)), 255);
                    let argb = Int32.leftShift(a, 24)
                        |> Int32.bitwiseOr(Int32.leftShift(r, 16))
                        |> Int32.bitwiseOr(Int32.leftShift(g, 8))
                        |> Int32.bitwiseOr(b);
                    Array.put(argb, y * w + x, pixels)
                }, xs)
            }, List.range(0, h));
            MemoryUtil.memFree(buf);
            image.setRGB(0, 0, w, h, pixels, 0, w);
            image
        }

    /// readBoundImage の RGB 版（alpha を落とす皮）。splashShot・注釈スクショの
    /// 既存出力が RGB の PNG なので、そこへの委譲はこちらを通す — alpha 付きに
    /// 変えると PNG のバイト列が変わり、撮り置きとの比較が全部やり直しになる。
    pub def readBoundImageRgb(w: Int32, h: Int32): BufferedImage \ IO =
        region rc {
            let src = readBoundImage(w, h);
            // 1i32 = TYPE_INT_RGB。
            let out = new BufferedImage(w, h, 1i32);
            let buf: Array[Int32, rc] = Array.empty(rc, w * h);
            discard src.getRGB(0, 0, w, h, buf, 0, w);
            out.setRGB(0, 0, w, h, buf, 0, w);
            out
        }

    /// readBoundImage を PNG に書く（親ディレクトリが無ければ作る）。
    pub def readBoundPng(w: Int32, h: Int32, path: String): Unit \ IO =
        let file = new File(path);
        let parent = file.getParentFile();
        if (not Object.isNull(parent)) discard parent.mkdirs() else ();
        discard ImageIO.write(readBoundImage(w, h), "png", file)
}
