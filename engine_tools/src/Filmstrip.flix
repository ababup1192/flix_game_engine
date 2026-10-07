// Filmstrip — 同寸の BufferedImage 列を横 1 列に連結したスプライトシート PNG に描き出す。
//
// フィルムストリップ・ビューア（ダッシュボードのコマ送り UI）が背景画像 1 枚を
// background-position で横スクロールしてコマを切り替えるための素材を作る。フレーム i は
// x = i × frameW に置かれるので、ビューアは -i × (frameW/cssScale) だけ背景をずらせば
// そのコマだけを表示範囲に見せられる。
//
// ゲーム内容は一切知らない。入力は「同じ寸法の BufferedImage 列」と「出力パス」だけ。
// GifEncoder が同じフレーム列からアニメ GIF を描き出すのと対になる経路で、こちらは 1 枚の
// 静的スプライトシートにする（file:// でも動く素の JS ビューアが扱える）。
//
// 減量: フレームは平坦色のドット絵なので、使われている色が 256 以下なら
// IndexColorModel（PNG-8・インデックスカラー）で書く。パレットには実在する色だけを
// 入れるので減色による劣化は起きない。色数が 256 を超えたら安全側でフルカラー
// （TYPE_INT_RGB）にフォールバックし、結果（indexed=false）で呼び側に知らせる。
pub mod Filmstrip {
    import java.awt.image.BufferedImage
    import java.awt.image.IndexColorModel
    import java.awt.image.WritableRaster
    import java.io.File
    import java.lang.{Object => JObject}
    import javax.imageio.ImageIO

    /// 描き出しの結果（呼び側が HTML ビューアのメタデータに使う）。
    /// `frameCount`/`frameW`/`frameH`: コマ数と 1 コマの実ピクセル寸法。
    /// `width`/`height`: 出力スプライトシート全体の実ピクセル寸法（width = frameCount × frameW）。
    /// `indexed`: PNG-8（インデックスカラー）で書けたか（false ならフルカラーへフォールバックした）。
    /// `colors`: シート内の相異なる色数（indexed のときのパレット長。フォールバック時は 257 で頭打ち）。
    pub type alias RenderResult = {
        frameCount = Int32, frameW = Int32, frameH = Int32,
        width = Int32, height = Int32, indexed = Bool, colors = Int32
    }

    /// パレット判定の上限（PNG-8 は 8bit = 256 色まで）。
    def maxColors(): Int32 = 256

    /// renderFrames の結果（呼び側がビューアのメタデータに使う）。
    pub type alias FramesResult = { frameCount = Int32, frameW = Int32, frameH = Int32 }

    /// `frames` を 1 コマ 1 ファイルのコマ別 PNG として `dirPath` へ書き出す（`0.png` .. `n-1.png`）。
    /// 横連結シートはブラウザが描ける幅の上限（65,535px 超で真っ黒）に当たるので、コマ数の多い
    /// シナリオはこちらで描き出し、ビューアがコマ別にめくる。各コマはシートと同じ減量方針
    /// （256 色以下なら PNG-8、超えたらフルカラー）。frames が空なら None（ファイルは作らない）。
    pub def renderFrames(frames: List[BufferedImage], dirPath: String): Option[FramesResult] \ IO =
        match frames {
            case Nil        => None
            case first :: _ =>
                let fw = Int32.max(1i32, first.getWidth());
                let fh = Int32.max(1i32, first.getHeight());
                List.forEachWithIndex((i, img) -> renderFrame(img, "${dirPath}/${i}.png"), frames);
                Some({ frameCount = List.length(frames), frameW = fw, frameH = fh })
        }

    /// 1 コマだけをコマ別 PNG に書く（renderFrames の 1 枚ぶんと同じ経路 = 同じバイト列になる）。
    /// コマを描くたびに 1 枚ずつ書き出したい呼び側（HeadlessRender の GIF 描き出し）向けの入口 — 全コマが
    /// 揃うのを待たずに、描き出し途中のコマをファイルで見せられる。減量方針も renderFrames と
    /// 同じ（256 色以下なら PNG-8、超えたらフルカラー）。親ディレクトリは無ければ作る。
    pub def renderFrame(img: BufferedImage, outPath: String): Unit \ IO =
        let fw = Int32.max(1i32, img.getWidth());
        let fh = Int32.max(1i32, img.getHeight());
        let file = new File(outPath);
        let parent = file.getParentFile();
        if (not Object.isNull(parent)) discard parent.mkdirs() else ();
        match collectPalette(img :: Nil, fw, fh) {
            case Some(colors) =>
                discard ImageIO.write(drawIndexed(img :: Nil, fw, fw, fh, colors), "png", file)
            case None =>
                discard ImageIO.write(drawFullColor(img :: Nil, fw, fw, fh), "png", file)
        }

    /// `frames`（同寸の BufferedImage 列）を横連結して `outPath` へ PNG で書き出す。
    /// 256 色以下なら PNG-8（インデックスカラー）、超えたらフルカラーで書く。
    /// frames が空なら None（呼び側の sanity 用・ファイルは作らない）。
    pub def render(frames: List[BufferedImage], outPath: String): Option[RenderResult] \ IO =
        match frames {
            case Nil        => None
            case first :: _ =>
                let fw = Int32.max(1i32, first.getWidth());
                let fh = Int32.max(1i32, first.getHeight());
                let n = List.length(frames);
                let sheetW = n * fw;
                let file = new File(outPath);
                let parent = file.getParentFile();
                if (not Object.isNull(parent)) discard parent.mkdirs() else ();
                // Graphics2D（createGraphics）は macOS の -XstartOnFirstThread 下で AWT Toolkit の初期化を
                // 待ってデッドロックしうる。ここは Raster への直接コピーだけで描くので GraphicsEnvironment に
                // 一切触れない（headless 設定も不要）。
                match collectPalette(frames, fw, fh) {
                    case Some(colors) =>
                        discard ImageIO.write(drawIndexed(frames, fw, sheetW, fh, colors), "png", file);
                        Some({frameCount = n, frameW = fw, frameH = fh, width = sheetW, height = fh,
                              indexed = true, colors = List.length(colors)})
                    case None =>
                        discard ImageIO.write(drawFullColor(frames, fw, sheetW, fh), "png", file);
                        Some({frameCount = n, frameW = fw, frameH = fh, width = sheetW, height = fh,
                              indexed = false, colors = maxColors() + 1i32})
                }
        }

    /// フルカラー（TYPE_INT_RGB=1）のシートへ、各フレームの画素を x = i × frameW へ setRGB でコピーする。
    /// 256 色を超えた（インデックス化できない）ときのフォールバック経路。Graphics2D は使わない。
    def drawFullColor(frames: List[BufferedImage], fw: Int32, sheetW: Int32, fh: Int32): BufferedImage \ IO =
        region rc {
            let sheet = new BufferedImage(sheetW, fh, 1i32);
            let buf: Array[Int32, rc] = Array.empty(rc, fw * fh);
            List.forEachWithIndex((i, img) -> {
                discard img.getRGB(0i32, 0i32, fw, fh, buf, 0i32, fw);
                sheet.setRGB(i * fw, 0i32, fw, fh, buf, 0i32, fw)
            }, frames);
            sheet
        }

    /// インデックスカラー（TYPE_BYTE_INDEXED=13）のシートへ、各フレームの画素をパレット添字に写して
    /// Raster へ直接書き込む（Graphics2D 不使用）。パレットに実在色をそのまま入れてあるので劣化なし。
    def drawIndexed(frames: List[BufferedImage], fw: Int32, sheetW: Int32, fh: Int32,
                    colors: List[Int32]): BufferedImage \ IO =
        region rc {
            let sheet = new BufferedImage(sheetW, fh, 13i32, indexModel(rc, colors));
            let raster = sheet.getRaster();
            let lut = buildLut(rc, colors);                 // 色（24bit）→ パレット添字
            let intbuf: Array[Int32, rc] = Array.empty(rc, fw * fh);   // フレーム 1 枚ぶんの RGB
            let bytebuf: Array[Int8, rc] = Array.empty(rc, fw * fh);   // フレーム 1 枚ぶんの添字（byte）
            List.forEachWithIndex((i, img) -> {
                discard img.getRGB(0i32, 0i32, fw, fh, intbuf, 0i32, fw);
                fillIndices(intbuf, bytebuf, 0i32, fw * fh, lut);
                raster.setDataElements(i * fw, 0i32, fw, fh, unchecked_cast(bytebuf as JObject))
            }, frames);
            sheet
        }

    /// 色（下位 24bit）→ パレット添字の索引表（MutMap）。全画素がパレット内なので既定値は使われない。
    def buildLut(rc: Region[r], colors: List[Int32]): MutMap[Int32, Int32, r] \ r =
        let m = MutMap.empty(rc);
        List.forEachWithIndex((i, c) -> MutMap.put(c, i, m), colors);
        m

    /// intbuf の各画素の色を lut で添字に写し bytebuf に詰める（tail-recursive）。
    def fillIndices(intbuf: Array[Int32, r], bytebuf: Array[Int8, r], j: Int32, len: Int32,
                    lut: MutMap[Int32, Int32, r]): Unit \ r =
        if (j >= len) ()
        else {
            let rgb = Int32.bitwiseAnd(Array.get(j, intbuf), 16777215i32);
            Array.put(toByte(MutMap.getWithDefault(rgb, 0i32, lut)), j, bytebuf);
            fillIndices(intbuf, bytebuf, j + 1i32, len, lut)
        }

    /// 出現順の色（下位 24bit の RGB）から IndexColorModel（8bit・アルファなし）を組む。
    /// IndexColorModel は byte 配列を自前にコピーするので region 内の配列を渡して差し支えない。
    def indexModel(rc: Region[r], colors: List[Int32]): IndexColorModel \ IO + r =
        let size = List.length(colors);
        let rBytes = Array.empty(rc, size);
        let gBytes = Array.empty(rc, size);
        let bBytes = Array.empty(rc, size);
        List.forEachWithIndex((i, c) -> {
            Array.put(toByte(Int32.bitwiseAnd(c / 65536i32, 255i32)), i, rBytes);
            Array.put(toByte(Int32.bitwiseAnd(c / 256i32, 255i32)), i, gBytes);
            Array.put(toByte(Int32.bitwiseAnd(c, 255i32)), i, bBytes)
        }, colors);
        new IndexColorModel(8i32, size, rBytes, gBytes, bBytes)

    /// 0..255 の色成分を、同じ 8bit パターンの Int8（Java byte）に読み替える（128 以上は負値へ）。
    def toByte(v: Int32): Int8 =
        let w = if (v > 127i32) v - 256i32 else v;
        Int32.tryToInt8(w) |> Option.getWithDefault(0i8)

    /// Pass 1: フレーム群を走査し、相異なる色（下位 24bit）を出現順に集める。
    /// 色数が 256 を超えたら None（フルカラーへフォールバックすべき合図）。
    /// `seen`（MutSet）で既出を弾き、`palette`（逆順の Ref）に初出色を積む。フレームごとに getRGB で
    /// 画素をまとめて読み、tail-recursive に走査する。内部リージョンに閉じ、List[Int32] だけ返す。
    def collectPalette(frames: List[BufferedImage], fw: Int32, fh: Int32): Option[List[Int32]] \ IO = region rc {
        let seen = MutSet.empty(rc);
        let pixbuf = Array.empty(rc, fw * fh);      // フレーム 1 枚ぶんの画素バッファ（使い回す）
        let paletteRef = Ref.fresh(rc, (Nil: List[Int32]));
        let countRef = Ref.fresh(rc, 0i32);
        List.forEach(img ->
            if (Ref.get(countRef) <= maxColors()) {
                discard img.getRGB(0i32, 0i32, fw, fh, pixbuf, 0i32, fw);
                scanPixels(pixbuf, 0i32, fw * fh, seen, paletteRef, countRef)
            } else (),
            frames);
        if (Ref.get(countRef) > maxColors()) None
        else Some(List.reverse(Ref.get(paletteRef)))
    }

    /// 画素バッファ [i, len) を走査し、未出現の色を seen に記録して palette に前置する。
    /// count が上限を超えたら（この画素以降は無駄なので）打ち切る。
    def scanPixels(pixbuf: Array[Int32, r], i: Int32, len: Int32, seen: MutSet[Int32, r],
                   paletteRef: Ref[List[Int32], r], countRef: Ref[Int32, r]): Unit \ r =
        if (i >= len or Ref.get(countRef) > maxColors())
            ()
        else {
            let rgb = Int32.bitwiseAnd(Array.get(i, pixbuf), 16777215i32);
            if (not MutSet.memberOf(rgb, seen)) {
                MutSet.add(rgb, seen);
                Ref.put(rgb :: Ref.get(paletteRef), paletteRef);
                Ref.put(Ref.get(countRef) + 1i32, countRef)
            } else ();
            scanPixels(pixbuf, i + 1i32, len, seen, paletteRef, countRef)
        }
}
