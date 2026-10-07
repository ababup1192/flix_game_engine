// BootFont — 起動画面が使う組み込みフォントとロゴを、埋め込みデータから組み立てる。
//
// ゲームのフォントは起動時にまさに生成している最中で使えない。起動画面はここが持つ
// 小さなビットマップだけで字を出すので、何も読み込まずに 1 枚目から絵を出せる。
//
// 素データは BootFontData（生成物）。生成し直しは `make boot-font`。
pub mod BootFont {

    /// フォントの登録名。ゲームが project.json で付ける名前と衝突しない綴りにしてある。
    pub def name(): String = "__boot"

    /// テクスチャ名は "font_" で始めない。始めると描画側が SDF 距離場として塗ってしまうが、
    /// この字は距離場ではなく素の白黒ビットマップなので、普通のテクスチャとして描かせる。
    pub def textureName(): String = "boot__font"

    pub def logoTextureName(): String = "boot__logo"

    /// ロゴの一辺（px）。
    pub def logoSide(): Int32 = BootFontData.logoSide()

    /// この大きさで字を出すとドットが 1:1 で揃う。拡大するなら整数倍にする
    /// （ビットマップなので半端な倍率では輪郭が濁る）。
    pub def fontSize(): Float64 = BootFontData.fontSize()

    /// Text.make / Text.measure がそのまま使えるフォントアトラス。
    pub def atlas(): FontAtlas =
        { textureName = textureName(),
          fontSize    = BootFontData.fontSize(),
          textureSize = Int32.toFloat64(BootFontData.side()),
          ascent      = BootFontData.ascent(),
          descent     = BootFontData.descent(),
          lineGap     = BootFontData.lineGap(),
          glyphs      = decodeGlyphs() }

    /// フォントアトラスの画素（ARGB・行優先）。字は白、地は透明。
    pub def pixelsArgb(): Vector[Int32] = region rc {
        let side = BootFontData.side();
        let buf: Array[Int32, rc] = Array.empty(rc, side * side);
        let white = Int32.leftShift(255, 24) |> Int32.bitwiseOr(0xFFFFFF);
        // 16 進 1 桁 = 4 画素。立っているビットだけ塗り、残りは透明のまま置いていく。
        discard BootFontData.bitsHex()
            |> List.flatMap(String.toList)
            |> List.foldLeft((i, ch) -> {
                let bits = nibble(ch);
                nibbleMasks() |> List.forEach(m -> {
                    let (offset, mask) = m;
                    if (Int32.bitwiseAnd(bits, mask) != 0) Array.put(white, i * 4 + offset, buf) else ()
                });
                i + 1
            }, 0);
        Array.toVector(buf)
    }

    /// ロゴの画素（ARGB・行優先）。色票の番号を 4bit で 1 画素持っている。
    pub def logoArgb(): Vector[Int32] = region rc {
        let side = BootFontData.logoSide();
        let palette = decodePalette();
        let buf: Array[Int32, rc] = Array.empty(rc, side * side);
        discard BootFontData.logoHex()
            |> List.flatMap(String.toList)
            |> List.foldLeft((i, ch) -> {
                Array.put(Vector.get(nibble(ch), palette), i, buf);
                i + 1
            }, 0);
        Array.toVector(buf)
    }

    // ── 埋め込みデータの読み解き ──────────────────────────────

    /// 16 進 1 桁の中の 4 つのビットを、左から何画素目かと取り出す印の組で表す。
    def nibbleMasks(): List[(Int32, Int32)] = (0, 8) :: (1, 4) :: (2, 2) :: (3, 1) :: Nil

    /// 1 字ぶんの桁数: 文字番号(4) 左(3) 上(3) 幅(2) 送り幅(2)。
    def glyphStride(): Int32 = 14

    def decodeGlyphs(): Map[Int32, TextLayout.GlyphMetrics] =
        let hex = BootFontData.glyphsHex();
        let side = Int32.toFloat64(BootFontData.side());
        let cellH = Int32.toFloat64(BootFontData.cellH());
        let ascent = BootFontData.ascent();
        List.range(0, String.length(hex) / glyphStride())
            |> List.foldLeft((acc, i) -> {
                let base = i * glyphStride();
                let cp = hexAt(hex, base, 4);
                let x = Int32.toFloat64(hexAt(hex, base + 4, 3));
                let y = Int32.toFloat64(hexAt(hex, base + 7, 3));
                let w = Int32.toFloat64(hexAt(hex, base + 10, 2));
                let advance = Int32.toFloat64(hexAt(hex, base + 12, 2));
                // yOff = -ascent は「マスの上端を行の上端に合わせる」という Text 側の決まり。
                let gm: TextLayout.GlyphMetrics =
                    { xOff = 0.0, yOff = -1.0 * ascent,
                      glyphW = w, glyphH = cellH, advance = advance,
                      s0 = x / side, t0 = y / side,
                      s1 = (x + w) / side, t1 = (y + cellH) / side };
                Map.insert(cp, gm, acc)
            }, Map.empty())

    /// 色票（1 色 8 桁 rrggbbaa）を ARGB の並びに直す。
    def decodePalette(): Vector[Int32] =
        let hex = BootFontData.logoPaletteHex();
        List.range(0, String.length(hex) / 8)
            |> List.map(i -> {
                let base = i * 8;
                Int32.leftShift(hexAt(hex, base + 6, 2), 24)
                    |> Int32.bitwiseOr(Int32.leftShift(hexAt(hex, base, 2), 16))
                    |> Int32.bitwiseOr(Int32.leftShift(hexAt(hex, base + 2, 2), 8))
                    |> Int32.bitwiseOr(hexAt(hex, base + 4, 2))
            })
            |> List.toVector

    /// 16 進の一部を数に直す。読めなければ 0 —
    /// 生成物が壊れていても起動画面が汚れるだけで、起動そのものは止めない。
    def hexAt(s: String, start: Int32, len: Int32): Int32 =
        String.slice({ start = start }, { end = start + len }, s)
            |> (sub -> Int32.parse(16, sub))
            |> Result.toOption
            |> Option.getWithDefault(0)

    def nibble(ch: Char): Int32 =
        let n = Char.toBmpCodePoint(ch);
        if (n >= 0x30 and n <= 0x39)      n - 0x30
        else if (n >= 0x61 and n <= 0x66) n - 0x57
        else if (n >= 0x41 and n <= 0x46) n - 0x37
        else 0
}
