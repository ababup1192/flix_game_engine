// CreditsLayout — クレジットの行を画面の幅で折った並び（純粋）。
// World（流れ切ったかの長さ）と View（描く所）が同じ並びを引くので、折って増えた行のぶんだけ長く流れる。
// 折る幅は字幅の近似で数える（全角は字の大きさ・半角は 0.6 倍）。
// WhyNot: 字の本（atlas）で測って折らない — Controls には字の本が無く、流れ切る長さと描く行の数が食い違う。
// 近似より実際の字が広い行は、View が描く時に幅へ収まるまで字を縮める（drawSize）。
mod CreditsLayout {

    /// 折った 1 行。y = クレジットの頭からの上端（px）、size = 字の大きさ。
    pub type alias Line = { text = String, style = CreditsDoc.Style, size = Float64, y = Float64 }

    /// 左右の余白（縦・横とも同じ）。
    pub def sideMargin(): Float64 = 32.0

    /// 画面の幅 screenWidth で、行を置ける幅。
    pub def room(screenWidth: Float64): Float64 = screenWidth - 2.0 * sideMargin()

    pub def sizeOf(style: CreditsDoc.Style): Float64 = match style {
        case CreditsDoc.Style.Heading => 26.0
        case CreditsDoc.Style.Body    => 19.0
        case CreditsDoc.Style.Small   => 13.0
        case CreditsDoc.Style.Gap     => 0.0
    }

    /// 行の頭から次の行の頭まで（折らない時）。
    def rowHeight(style: CreditsDoc.Style): Float64 = match style {
        case CreditsDoc.Style.Heading => 52.0
        case CreditsDoc.Style.Body    => 34.0
        case CreditsDoc.Style.Small   => 24.0
        case CreditsDoc.Style.Gap     => 40.0
    }

    /// 折った 2 行目から先の送り（同じ行の中なので、行どうしの間より詰める）。
    def wrapStep(style: CreditsDoc.Style): Float64 = sizeOf(style) * 1.35

    /// 近似の字幅（全角は size・半角は size の 0.6 倍）。
    pub def charWidth(size: Float64, ch: Char): Float64 =
        if (Char.toBmpCodePoint(ch) < 128) size * 0.6 else size

    /// 近似の字幅で測った text の幅。
    pub def widthOf(size: Float64, text: String): Float64 =
        String.toList(text) |> List.foldLeft((sum, ch) -> sum + charWidth(size, ch), 0.0)

    /// text を幅 maxWidth で折った行。切れ目は字と字の間で、行の頭に閉じの約物（、。・）」ー 小さいかな など）を置かず、
    /// 行の終わりに開きの括弧を残さず、半角の語（英単語・URL）の中では切らない。
    /// 収まる切れ目のうち、読点・中黒・閉じ括弧の後と開き括弧の前を一番に、次に空白の所を選ぶ（chooseCut）。
    /// 半角の語が 1 つで幅を越える時は、その語だけで 1 行にする（描く時に drawSize が縮める）。
    pub def wrap(maxWidth: Float64, size: Float64, text: String): List[String] =
        let chars = String.toList(text);
        let scan = { text = text, chars = List.toVector(chars), count = List.length(chars), maxWidth = maxWidth,
                     prefix = List.toVector(List.scanLeft((sum, ch) -> sum + charWidth(size, ch), 0.0, chars)) };
        wrapFrom(scan, 0, Nil)

    /// 折る 1 行分の調べ物。prefix = 頭からの近似の幅（prefix[i] = i 字目の前まで）。
    type alias Scan = { text = String, chars = Vector[Char], count = Int32, maxWidth = Float64, prefix = Vector[Float64] }

    def wrapFrom(s: Scan, start: Int32, acc: List[String]): List[String] =
        let lineStart = skipSpaces(s, start);
        if (lineStart >= s#count) List.reverse(acc)
        else {
            let cut = cutOf(s, lineStart);
            wrapFrom(s, cut, String.trim(String.dropLeft(lineStart, String.takeLeft(cut, s#text))) :: acc)
        }

    def skipSpaces(s: Scan, i: Int32): Int32 =
        if (i < s#count and Vector.get(i, s#chars) == ' ') skipSpaces(s, i + 1) else i

    def widthBetween(s: Scan, a: Int32, b: Int32): Float64 = Vector.get(b, s#prefix) - Vector.get(a, s#prefix)

    /// 行の終わりの空白を除いた終わり。
    def trimmedEnd(s: Scan, lineStart: Int32, i: Int32): Int32 =
        if (i > lineStart and Vector.get(i - 1, s#chars) == ' ') trimmedEnd(s, lineStart, i - 1) else i

    /// lineStart から始まる行の終わり（次の行の頭）。
    def cutOf(s: Scan, lineStart: Int32): Int32 =
        if (widthBetween(s, lineStart, trimmedEnd(s, lineStart, s#count)) <= s#maxWidth) s#count
        else scanCut(s, lineStart, lineStart + 1, { fit = None, mark = None, space = None })

    /// 行の中で収まる最後の切れ目: fit = どこでも、mark = 約物（読点・中黒・括弧）の所、space = 空白の所。
    type alias Cuts = { fit = Option[Int32], mark = Option[Int32], space = Option[Int32] }

    /// i の前で切れるかを頭から 1 字ずつ見る。
    def scanCut(s: Scan, lineStart: Int32, i: Int32, cuts: Cuts): Int32 =
        if (i >= s#count) chooseCut(s, lineStart, cuts, s#count)
        else if (widthBetween(s, lineStart, trimmedEnd(s, lineStart, i)) > s#maxWidth) chooseCut(s, lineStart, cuts, nextBreak(s, i))
        else if (canBreak(s, i)) scanCut(s, lineStart, i + 1, recordCut(s, i, cuts))
        else scanCut(s, lineStart, i + 1, cuts)

    def recordCut(s: Scan, i: Int32, cuts: Cuts): Cuts =
        let prev = Vector.get(i - 1, s#chars);
        let next = Vector.get(i, s#chars);
        let isMark = Set.memberOf(prev, breakAfter()) or Set.memberOf(next, breakBefore());
        let isSpace = prev == ' ' or next == ' ';
        { fit = Some(i), mark = if (isMark) Some(i) else cuts#mark, space = if (isSpace) Some(i) else cuts#space }

    /// 約物の所 → 空白の所 → 収まる一番後ろ、の順に選ぶ（行が幅の 35% より短くなる所は選ばない）。何も収まらなければ overflow。
    def chooseCut(s: Scan, lineStart: Int32, cuts: Cuts, overflow: Int32): Int32 =
        let longEnough = p -> widthBetween(s, lineStart, p) >= s#maxWidth * 0.35;
        let fallback = Option.getWithDefault(overflow, cuts#fit);
        let bySpace = Option.getWithDefault(fallback, Option.filter(longEnough, cuts#space));
        Option.getWithDefault(bySpace, Option.filter(longEnough, cuts#mark))

    /// i 以降で最初に切れる所（無ければ終わり）。
    def nextBreak(s: Scan, i: Int32): Int32 =
        if (i >= s#count or canBreak(s, i)) i else nextBreak(s, i + 1)

    def canBreak(s: Scan, i: Int32): Bool =
        let prev = Vector.get(i - 1, s#chars);
        let next = Vector.get(i, s#chars);
        not Set.memberOf(next, noLineStart()) and not Set.memberOf(prev, noLineEnd()) and not (isWordChar(prev) and isWordChar(next))

    def isWordChar(ch: Char): Bool = Char.toBmpCodePoint(ch) < 128 and ch != ' '

    def noLineStart(): Set[Char] =
        Set#{'、', '。', '，', '．', '・', '：', '；', '？', '！', '）', '」', '』', '】', '〉', '》', '〕', 'ー', '々', 'ゝ', 'ゞ',
             'ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ', 'っ', 'ゃ', 'ゅ', 'ょ', 'ゎ', 'ァ', 'ィ', 'ゥ', 'ェ', 'ォ', 'ッ', 'ャ', 'ュ', 'ョ', 'ヮ', 'ヵ', 'ヶ', '…', '‥'}

    def noLineEnd(): Set[Char] = Set#{'（', '「', '『', '【', '〈', '《', '〔'}

    def breakAfter(): Set[Char] = Set#{'、', '。', '，', '・', '）', '」', '』'}

    def breakBefore(): Set[Char] = Set#{'（', '「', '『'}

    /// 行を幅 maxWidth で折って上から並べる。gap と空の行は字を置かず、高さだけ取る。
    pub def lines(maxWidth: Float64, rows: List[CreditsDoc.Row]): List[Line] =
        let (placed, _) = rows |> List.foldLeft((acc, row) -> {
            let (done, y) = acc;
            let here = linesOfRow(maxWidth, y, row);
            (List.reverse(here) ::: done, y + heightOfRow(maxWidth, row))
        }, (Nil, 0.0));
        List.reverse(placed)

    /// 行を並べた長さ（折った行のぶんを含む）。
    pub def length(maxWidth: Float64, rows: List[CreditsDoc.Row]): Float64 =
        rows |> List.foldLeft((sum, row) -> sum + heightOfRow(maxWidth, row), 0.0)

    def textsOf(maxWidth: Float64, row: CreditsDoc.Row): List[String] =
        if (row#style == CreditsDoc.Style.Gap or String.isEmpty(String.trim(row#text))) Nil
        else wrap(maxWidth, sizeOf(row#style), row#text)

    def linesOfRow(maxWidth: Float64, y: Float64, row: CreditsDoc.Row): List[Line] =
        textsOf(maxWidth, row) |> List.mapWithIndex((i, text) ->
            { text = text, style = row#style, size = sizeOf(row#style), y = y + Int32.toFloat64(i) * wrapStep(row#style) })

    def heightOfRow(maxWidth: Float64, row: CreditsDoc.Row): Float64 =
        let extra = Int32.max(0, List.length(textsOf(maxWidth, row)) - 1);
        rowHeight(row#style) + Int32.toFloat64(extra) * wrapStep(row#style)

    /// 描く字の大きさ。実際の幅（measure = (字, 大きさ) → 幅）が maxWidth を越える行だけ、収まるまで縮める。
    pub def drawSize(measure: (String, Float64) -> Float64, maxWidth: Float64, line: Line): Float64 =
        let real = measure(line#text, line#size);
        if (real <= maxWidth) line#size else line#size * maxWidth / real
}
