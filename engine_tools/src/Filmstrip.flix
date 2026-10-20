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
    import java.awt.Point
    import java.awt.image.BufferedImage
    import java.awt.image.ColorModel
    import java.awt.image.DataBufferInt
    import java.awt.image.DirectColorModel
    import java.awt.image.IndexColorModel
    import java.awt.image.Raster
    import java.awt.image.WritableRaster
    import java.lang.{Object => JObject}
    import java.util.Hashtable
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
        match collectPalette(img :: Nil, fw, fh) {
            case Some(colors) =>
                writePng(drawIndexed(img :: Nil, fw, fw, fh, colors), outPath)
            case None =>
                let image = match asRgb(img) {
                    case Some(view) => view
                    case None       => drawFullColor(img :: Nil, fw, fw, fh)
                };
                writePng(image, outPath)
        }

    /// TYPE_INT_ARGB の画素バッファを、写さずに RGB（アルファなし）として見る画像。
    /// PNG には drawFullColor（TYPE_INT_RGB へ写した物）と同じバイト列が出る。
    /// 部分画像など、画素が先頭から幅ぴったりに並んでいない物は None（写す道へ）。
    def asRgb(img: BufferedImage): Option[BufferedImage] \ IO =
        let buffer = img.getRaster().getDataBuffer();
        let w = img.getWidth();
        let h = img.getHeight();
        if (not isPackedArgb(img)) None
        else region rc {
            let masks: Array[Int32, rc] = Array.empty(rc, 3i32);
            Array.put(16711680i32, 0i32, masks);
            Array.put(65280i32, 1i32, masks);
            Array.put(255i32, 2i32, masks);
            let view = Raster.createPackedRaster(buffer, w, h, w, masks, unchecked_cast(null as Point));
            let model: ColorModel = checked_cast(new DirectColorModel(24i32, 16711680i32, 65280i32, 255i32));
            Some(new BufferedImage(model, view, false, unchecked_cast(null as Hashtable[JObject, JObject])))
        }

    /// TYPE_INT_ARGB で、画素が int の配列の先頭から幅ぴったりに並んでいるか（部分画像でないか）。
    def isPackedArgb(img: BufferedImage): Bool \ IO =
        let raster = img.getRaster();
        img.getType() == 2i32 and raster.getSampleModelTranslateX() == 0i32
            and raster.getSampleModelTranslateY() == 0i32
            and raster.getDataBuffer().getSize() == img.getWidth() * img.getHeight()

    /// PNG を書き終えてから outPath へ置き換える（途中で止まっても書きかけを残さない）。
    def writePng(image: BufferedImage, outPath: String): Unit \ IO =
        AtomicFile.write(outPath, file -> discard ImageIO.write(image, "png", file))

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
                // Graphics2D（createGraphics）は macOS の -XstartOnFirstThread 下で AWT Toolkit の初期化を
                // 待ってデッドロックしうる。ここは Raster への直接コピーだけで描くので GraphicsEnvironment に
                // 一切触れない（headless 設定も不要）。
                match collectPalette(frames, fw, fh) {
                    case Some(colors) =>
                        writePng(drawIndexed(frames, fw, sheetW, fh, colors), outPath);
                        Some({frameCount = n, frameW = fw, frameH = fh, width = sheetW, height = fh,
                              indexed = true, colors = List.length(colors)})
                    case None =>
                        writePng(drawFullColor(frames, fw, sheetW, fh), outPath);
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

    /// 色（下位 24bit）→ パレット添字の索引表。全画素がパレット内なので引けない色は来ない。
    def buildLut(rc: Region[r], colors: List[Int32]): ColorTable[r] \ r =
        let table = freshColorTable(rc);
        List.forEachWithIndex((i, c) -> putColor(table, c, i), colors);
        table

    /// intbuf の各画素の色を lut で添字に写し bytebuf に詰める（tail-recursive）。
    def fillIndices(intbuf: Array[Int32, r], bytebuf: Array[Int8, r], j: Int32, len: Int32,
                    lut: ColorTable[r]): Unit \ r =
        if (j >= len) ()
        else {
            let rgb = Int32.bitwiseAnd(Array.get(j, intbuf), 16777215i32);
            let ColorTable.ColorTable(keys, vals) = lut;
            Array.put(toByte(Array.get(slotOf(keys, rgb), vals)), j, bytebuf);
            fillIndices(intbuf, bytebuf, j + 1i32, len, lut)
        }

    // ── 色の表（色 → パレット添字）──

    /// 開番地法の表（keys は色の下位 24bit・空きは -1、vals は添字）。色は 257 個までしか入れないので、
    /// 1024 枠なら空きが必ず残り、探す列も短い。
    // WhyNot: MutSet / MutMap を使わない — 1 画素ごとに木をたどって Int32 を箱に詰めるので、
    // 960×600 のコマ 1 枚で十数 ms かかる（deflate の 2〜3 割に当たる）。
    enum ColorTable[r: Region](Array[Int32, r], Array[Int32, r])

    def tableSize(): Int32 = 1024

    def freshColorTable(rc: Region[r]): ColorTable[r] \ r =
        ColorTable.ColorTable(Array.repeat(rc, tableSize(), -1i32), Array.repeat(rc, tableSize(), 0i32))

    /// rgb の入っている枠か、入るべき空き枠。
    def slotOf(keys: Array[Int32, r], rgb: Int32): Int32 \ r =
        probe(keys, rgb, Int32.logicalRightShift(dist = 22, rgb * -1640531535i32))

    def probe(keys: Array[Int32, r], rgb: Int32, slot: Int32): Int32 \ r =
        let k = Array.get(slot, keys);
        if (k == rgb or k == -1i32) slot
        else probe(keys, rgb, Int32.bitwiseAnd(slot + 1i32, tableSize() - 1i32))

    def putColor(table: ColorTable[r], rgb: Int32, index: Int32): Unit \ r =
        let ColorTable.ColorTable(keys, vals) = table;
        let slot = slotOf(keys, rgb);
        Array.put(rgb, slot, keys);
        Array.put(index, slot, vals)

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
    /// フレームごとに画素をまとめて読み（TYPE_INT_ARGB は画素の配列をそのまま、他は getRGB で）、tail-recursive に
    /// 走査する。内部リージョンに閉じ、List[Int32] だけ返す。
    def collectPalette(frames: List[BufferedImage], fw: Int32, fh: Int32): Option[List[Int32]] \ IO = region rc {
        let seen = freshColorTable(rc);
        let direct = img -> isPackedArgb(img) and img.getWidth() == fw and img.getHeight() == fh;
        // フレーム 1 枚ぶんの画素バッファ（使い回す）。全部のフレームを直接読めるなら要らない。
        let pixbuf = Array.empty(rc, if (List.forAll(direct, frames)) 0i32 else fw * fh);
        let paletteRef = Ref.fresh(rc, (Nil: List[Int32]));
        let countRef = Ref.fresh(rc, 0i32);
        // WhyNot: TYPE_INT_ARGB を getRGB で写さない — 960×600 のコマで 2.3MB の配列を毎回埋めるだけで、
        // 色の下位 24bit は画素の int そのものと同じ。
        List.forEach(img ->
            if (Ref.get(countRef) > maxColors()) ()
            else if (direct(img)) {
                let pixels: Array[Int32, Static] = unchecked_cast(img.getRaster().getDataBuffer() as DataBufferInt).getData();
                scanPixels(pixels, 0i32, fw * fh, seen, paletteRef, countRef)
            } else {
                discard img.getRGB(0i32, 0i32, fw, fh, pixbuf, 0i32, fw);
                scanPixels(pixbuf, 0i32, fw * fh, seen, paletteRef, countRef)
            },
            frames);
        if (Ref.get(countRef) > maxColors()) None
        else Some(List.reverse(Ref.get(paletteRef)))
    }

    /// 画素バッファ [i, len) を走査し、未出現の色を seen に記録して palette に前置する。
    /// count が上限を超えたら（この画素以降は無駄なので）打ち切る。
    def scanPixels(pixbuf: Array[Int32, p], i: Int32, len: Int32, seen: ColorTable[r],
                   paletteRef: Ref[List[Int32], r], countRef: Ref[Int32, r]): Unit \ p + r =
        if (i >= len or Ref.get(countRef) > maxColors())
            ()
        else {
            let rgb = Int32.bitwiseAnd(Array.get(i, pixbuf), 16777215i32);
            let ColorTable.ColorTable(keys, _) = seen;
            if (Array.get(slotOf(keys, rgb), keys) != rgb) {
                let count = Ref.get(countRef);
                if (count < maxColors()) putColor(seen, rgb, count) else ();
                Ref.put(rgb :: Ref.get(paletteRef), paletteRef);
                Ref.put(count + 1i32, countRef)
            } else ();
            scanPixels(pixbuf, i + 1i32, len, seen, paletteRef, countRef)
        }
}
