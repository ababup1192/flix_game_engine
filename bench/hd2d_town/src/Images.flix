// Images — assets の PNG を Texture3d にする（窓を開かない描き出しと実機で同じ物を使う）と、足元の楕円の影の絵をコードで作る。
mod Images {
    use fge::{Color, ImageData, Num, Texture3d}

    import java.io.File
    import java.awt.image.BufferedImage
    import javax.imageio.ImageIO

    /// 読んだ絵。path = assets からの相対・width・height = px。
    pub type alias Loaded = { path = String, texture = Texture3d.Texture3d, width = Int32, height = Int32 }

    /// assets/<path> の PNG を javax.imageio で画素にする（ブラウザでは使えない）。読めなければ Err（ファイルの名前つき）。
    // WhyNot: LoadProgress.imageDecoder を使わない — 窓を開かない描き出しの入口は App を通らず、decoder の handler が無い。
    pub def readImageIo(path: String): Result[String, ImageData.ImageData] \ IO =
        let file = "assets/${path}";
        let image: BufferedImage = ImageIO.read(new File(file));
        if (Object.isNull(image)) Err("${file} を読めない")
        else {
            let w = image.getWidth();
            let h = image.getHeight();
            let argb = List.range(0, h) |> List.flatMap(y -> List.range(0, w) |> List.map(x -> image.getRGB(x, y))) |> List.toVector;
            Ok({ width = w, height = h, argb = argb })
        }

    /// assets/<path> のバイトを decoder で画素にする（ブラウザと実機の窓で同じ道）。
    pub def readImageWith(decoder: ImageData.ImageDecoder, path: String): Result[String, ImageData.ImageData] \ Fs.FileRead + IO =
        let file = "assets/${path}";
        Fs.FileRead.readBytes(file) |> Result.mapErr(_ -> "${file} を読めない")
            |> Result.flatMap(bytes -> (decoder#decode)(bytes) |> Result.mapErr(why -> "${file}: ${why}"))

    /// 画素にした絵 image を path の絵として Texture3d にする。
    pub def loadedOf(path: String, image: ImageData.ImageData): Result[String, Loaded] =
        Texture3d.fromImage(image) |> Result.mapErr(why -> "assets/${path}: ${why}")
            |> Result.map(t -> { path = path, texture = t, width = image#width, height = image#height })

    /// 足元の楕円の影の絵（32×32）。真ん中が濃く、縁へ同じ傾きで薄くなる（色は暗い青紫・α の最大 0.6）。
    /// 絵の中の楕円は四角いっぱいの円で、四角の縦横比で楕円になる。
    pub def contactShadow(): Result[String, Texture3d.Texture3d] = blobShadow(0.6, 1.4, 2.4)

    /// 濃い足元の影の絵（芯は不透明に近く、縁は柔らかい）。
    pub def denseShadow(): Result[String, Texture3d.Texture3d] = blobShadow(0.95, 1.8, 3.4)

    /// 丸い影の絵。peak = α の最大・core・falloff = 真ん中からの距離 d で α = clamp(core − falloff × d) × peak。
    def blobShadow(peak: Float64, core: Float64, falloff: Float64): Result[String, Texture3d.Texture3d] =
        let side = 32;
        // 線形の (0.05, 0.04, 0.08) を画面の値にした色
        let color = Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(63, 16), Int32.leftShift(57, 8)), 80);
        let argb = List.range(0, side) |> List.flatMap(y -> List.range(0, side) |> List.map(x -> {
            let u = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(side) - 0.5;
            let v = (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(side) - 0.5;
            let len = Num.sqrt(u * u + v * v);
            let a = Num.clamp(0.0, 1.0, core - falloff * len) * peak;
            let alpha = Float64.round(a * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            Int32.bitwiseOr(Int32.leftShift(alpha, 24), color)
        })) |> List.toVector;
        Texture3d.fromArgb(side, side, argb)

    /// 街灯の火袋だけが光る絵（image の絵と同じ大きさ）。ガラスの画素（明るさ lumLo〜lumHi を 0〜1）× 火袋ごとの真ん中から radius 画素でなめらかに 0 へ落ちる重み（和は 1 で頭打ち）を α に、
    /// 色は重みの 3 乗で edge から core へ移す（芯ほど白く、縁ほど橙）。lanterns = 火袋の真ん中（uv・左下が 0,0）。
    pub def lanternGlowOf(lanterns: List[(Float64, Float64)], radius: Float64, lumLo: Float64, lumHi: Float64, core: Color, edge: Color, image: ImageData.ImageData): Result[String, Texture3d.Texture3d] =
        let w = image#width;
        let h = image#height;
        let byte = (v: Float64) -> Float64.round(Num.clamp(0.0, 1.0, v) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let argb = List.range(0, h) |> List.flatMap(y -> List.range(0, w) |> List.map(x -> {
            let p = Vector.nth(y * w + x, image#argb) |> Option.getWithDefault(0);
            let a = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 24, p), 255);
            let lum = (0.2126 * Int32.toFloat64(Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, p), 255))
                     + 0.7152 * Int32.toFloat64(Int32.bitwiseAnd(Int32.logicalRightShift(dist = 8, p), 255))
                     + 0.0722 * Int32.toFloat64(Int32.bitwiseAnd(p, 255))) / 255.0;
            let glass = if (a < 128) 0.0 else Num.clamp(0.0, 1.0, (lum - lumLo) / (lumHi - lumLo));
            let weight = lanterns |> List.foldLeft((acc, uv) -> {
                let cx = fst(uv) * Int32.toFloat64(w);
                let cy = (1.0 - snd(uv)) * Int32.toFloat64(h);
                let d = Num.sqrt((Int32.toFloat64(x) + 0.5 - cx) * (Int32.toFloat64(x) + 0.5 - cx) + (Int32.toFloat64(y) + 0.5 - cy) * (Int32.toFloat64(y) + 0.5 - cy));
                let k = Num.clamp(0.0, 1.0, 1.0 - d / radius);
                acc + k * k * (3.0 - 2.0 * k)
            }, 0.0);
            let wt = Float64.min(1.0, weight);
            let mix = wt * wt * wt;
            let ch = (e: Float64, c: Float64) -> byte(e + (c - e) * mix);
            Int32.bitwiseOr(Int32.leftShift(byte(glass * wt), 24),
                Int32.bitwiseOr(Int32.leftShift(ch(edge#r, core#r), 16), Int32.bitwiseOr(Int32.leftShift(ch(edge#g, core#g), 8), ch(edge#b, core#b))))
        })) |> List.toVector;
        Texture3d.fromArgb(w, h, argb)

    /// 淡いハローの丸い絵（32×32・真ん中 1 → 縁 0 を falloff 乗・色は白）。
    pub def halo(falloff: Float64): Result[String, Texture3d.Texture3d] =
        let side = 32;
        let argb = List.range(0, side) |> List.flatMap(y -> List.range(0, side) |> List.map(x -> {
            let u = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(side) - 0.5;
            let v = (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(side) - 0.5;
            let k = Num.clamp(0.0, 1.0, 1.0 - 2.0 * Num.sqrt(u * u + v * v));
            let alpha = Float64.round(Float64.pow(base = k, falloff) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            Int32.bitwiseOr(Int32.leftShift(alpha, 24), 16777215)
        })) |> List.toVector;
        Texture3d.fromArgb(side, side, argb)
}
