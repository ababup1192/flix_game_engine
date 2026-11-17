// Images — assets の PNG を Texture3d にする（窓を開かない描き出しと実機で同じ物を使う）と、足元の楕円の影の絵をコードで作る。
mod Images {
    use fge::{Num, Texture3d}

    import java.io.File
    import java.awt.image.BufferedImage
    import javax.imageio.ImageIO

    /// 読んだ絵。path = assets からの相対・width・height = px。
    pub type alias Loaded = { path = String, texture = Texture3d.Texture3d, width = Int32, height = Int32 }

    /// assets/<path> の PNG を読む。読めなければ Err（ファイルの名前つき）。
    // WhyNot: LoadProgress.imageDecoder を使わない — 窓を開かない描き出しの入口は App を通らず、decoder の handler が無い。
    pub def load(path: String): Result[String, Loaded] \ IO =
        let file = "assets/${path}";
        let image: BufferedImage = ImageIO.read(new File(file));
        if (Object.isNull(image)) Err("${file} を読めない")
        else {
            let w = image.getWidth();
            let h = image.getHeight();
            let argb = List.range(0, h) |> List.flatMap(y -> List.range(0, w) |> List.map(x -> image.getRGB(x, y))) |> List.toVector;
            Texture3d.fromArgb(w, h, argb) |> Result.mapErr(why -> "${file}: ${why}")
                |> Result.map(t -> { path = path, texture = t, width = w, height = h })
        }

    /// 足元の楕円の影の絵（32×32）。真ん中が濃く、縁へ同じ傾きで薄くなる（色は暗い青紫・α の最大 0.6）。
    /// 絵の中の楕円は四角いっぱいの円で、四角の縦横比で楕円になる。
    pub def contactShadow(): Result[String, Texture3d.Texture3d] =
        let side = 32;
        // 線形の (0.05, 0.04, 0.08) を画面の値にした色
        let color = Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(63, 16), Int32.leftShift(57, 8)), 80);
        let argb = List.range(0, side) |> List.flatMap(y -> List.range(0, side) |> List.map(x -> {
            let u = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(side) - 0.5;
            let v = (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(side) - 0.5;
            let len = Num.sqrt(u * u + v * v);
            let a = Num.clamp(0.0, 1.0, 1.4 - 2.4 * len) * 0.6;
            let alpha = Float64.round(a * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            Int32.bitwiseOr(Int32.leftShift(alpha, 24), color)
        })) |> List.toVector;
        Texture3d.fromArgb(side, side, argb)
}
