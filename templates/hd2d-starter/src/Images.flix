// Images — assets の PNG を Texture3d にする（窓を開かない描き出しと実機で同じ物を使う）と、足元の楕円の影の絵をコードで作る。
mod Images {
    use fge::{ImageData, Num, Texture3d}

    import java.io.File
    import java.awt.image.BufferedImage
    import javax.imageio.ImageIO

    /// 絵の 1 m あたりの画素（板の大きさとカメラの丸めの単位）。
    pub def texelsPerMeter(): Float64 = 32.0

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

    /// assets/<path> のバイトを decoder で画素にする（ブラウザと実機のウィンドウで同じ道）。
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
}
