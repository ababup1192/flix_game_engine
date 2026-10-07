// ReferenceDiff — 直す前（リファレンス画像）と直した後（gallery）を左右に並べた 1 枚に描き出す。
//
// bench はバイトが違うことしか言わないので、「どこがどう変わったか」は人が 2 枚を
// 切り替えて探すことになる。並べて 1 枚にすれば、目を動かすだけで済む。
//
// 描き出す先は debug/diff/ —リファレンス画像の外なので、リグレッション防護の基準を汚さない。
// ゲーム内容は一切知らない。入力は「どの絵か」の名前だけ。
pub mod ReferenceDiff {
    import java.awt.image.BufferedImage
    import java.io.File
    import java.lang.System
    import javax.imageio.ImageIO

    /// 左右のあいだの仕切りの幅（px）。
    def gap(): Int32 = 8i32

    /// 仕切りの色（0xRRGGBB）。どちらの絵にも無さそうな彩度で、境目を疑わずに済む。
    def gapColor(): Int32 = 0x00FF00FFi32

    /// 環境変数で受け取って描き出す。DIFF_DIR = ゲームのディレクトリ、
    /// DIFF_NAMES = 並べたい PNG の名前をカンマで繋いだ物（例 "title.png,talk.png"）。
    /// 名前を呼び側（make）から貰うのは、どれが変わったかを決めるのが cmp の仕事だから。
    pub def pairs(): Unit \ IO =
        let dir = envOr("DIFF_DIR", ".");
        let names = envOr("DIFF_NAMES", "")
            |> String.splitOn(substr = ",")
            |> List.map(String.trim)
            |> List.filter(n -> not String.isEmpty(n));
        if (List.isEmpty(names))
            println("[diff] 並べる絵がありません（DIFF_NAMES が空）")
        else
            List.forEach(name -> pairOne(dir, name), names)

    def envOr(key: String, fallback: String): String \ IO =
        let value = System.getenv(key);
        if (Object.isNull(value)) fallback else value

    /// 1 枚ぶん: reference/<name> と gallery/<name> を読んで debug/diff/<name> へ並べて書く。
    /// 寸法が違うときは描き出さない — 縮尺の違う 2 枚を並べても比べたことにならない。
    def pairOne(dir: String, name: String): Unit \ IO =
        let beforePath = "${dir}/reference/${name}";
        let afterPath = "${dir}/gallery/${name}";
        match (readPng(beforePath), readPng(afterPath)) {
            case (Some(before), Some(after)) =>
                let bw = before.getWidth();
                let bh = before.getHeight();
                if (bw != after.getWidth() or bh != after.getHeight())
                    println("[diff] 寸法が違うので並べません: ${name}")
                else {
                    let out = "${dir}/debug/diff/${name}";
                    writePng(sideBySide(before, after, bw, bh), out);
                    println("[diff] ${out}")
                }
            case (None, _) => println("[diff] 前の絵がありません: ${beforePath}")
            case (_, None) => println("[diff] 後の絵がありません: ${afterPath}")
        }

    def readPng(path: String): Option[BufferedImage] \ IO =
        let file = new File(path);
        if (not file.exists()) None
        else {
            let img = ImageIO.read(file);
            if (Object.isNull(img)) None else Some(img)
        }

    /// 左に before・右に after を置いた 1 枚。Graphics2D は使わず Raster への直接コピーだけで
    /// 描く（macOS の -XstartOnFirstThread 下で AWT Toolkit の初期化を待って固まりうるため）。
    def sideBySide(before: BufferedImage, after: BufferedImage,
                   w: Int32, h: Int32): BufferedImage \ IO =
        region rc {
            let sheet = new BufferedImage(w * 2i32 + gap(), h, 1i32);
            let buf: Array[Int32, rc] = Array.empty(rc, w * h);
            discard before.getRGB(0i32, 0i32, w, h, buf, 0i32, w);
            sheet.setRGB(0i32, 0i32, w, h, buf, 0i32, w);
            discard after.getRGB(0i32, 0i32, w, h, buf, 0i32, w);
            sheet.setRGB(w + gap(), 0i32, w, h, buf, 0i32, w);
            let bar: Array[Int32, rc] = Array.repeat(rc, gap() * h, gapColor());
            sheet.setRGB(w, 0i32, gap(), h, bar, 0i32, gap());
            sheet
        }

    def writePng(img: BufferedImage, path: String): Unit \ IO =
        let file = new File(path);
        let parent = file.getParentFile();
        if (not Object.isNull(parent)) discard parent.mkdirs() else ();
        discard ImageIO.write(img, "png", file)
}
