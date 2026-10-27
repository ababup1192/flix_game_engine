// RichText — 一部だけ色や太さの違う文章を「スパンの列」として持ち、描画アイテムへ組む。
// 会話文の中で名前だけ色を変える・強調語だけ太くする、が UI の種類を問わずできる。
// 利用例: spans を組み、place に左上位置と最大幅を渡すと折返し済みの PlacedItem 列が返る。
// 文字送り（タイプライター）とは take で繋がる: 先頭 n 文字だけ残して place に渡す。
pub mod RichText {

    /// 1 スパン。tint = None は呼び側の基本色で描く。bold は同じ字を半ピクセルずらして
    /// 二度描く疑似太字（フォント 1 本で済む）。
    pub type alias Span = { text = String, tint = Option[Color], bold = Bool }

    pub def plain(text: String): Span = { text = text, tint = None, bold = false }

    pub def colored(text: String, tint: Color): Span = { text = text, tint = Some(tint), bold = false }

    pub def strong(text: String): Span = { text = text, tint = None, bold = true }

    /// 見た目を除いた素の文章（文字送りの長さ勘定・テストの pin に使う）。
    pub def plainText(spans: List[Span]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(span -> StringBuilder.append(span#text, sb), spans);
            StringBuilder.toString(sb)
        }

    /// 字の列を 1 本の String へ組む。
    def charsToString(chars: List[Char]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(ch -> StringBuilder.append(ch, sb), chars);
            StringBuilder.toString(sb)
        }

    /// 全スパンの合計文字数。
    pub def length(spans: List[Span]): Int32 =
        spans |> List.foldLeft((acc, span) -> acc + String.length(span#text), 0)

    /// 先頭 n 文字ぶんだけ残す（タイプライター表示用）。スパンの途中でも切れる。
    pub def take(n: Int32, spans: List[Span]): List[Span] =
        match spans {
            case Nil => Nil
            case span :: rest => {
                let len = String.length(span#text);
                if (n <= 0)
                    Nil
                else if (n >= len)
                    span :: take(n - len, rest)
                else {
                    let cut = String.toList(span#text) |> List.take(n) |> charsToString;
                    { text = cut | span } :: Nil
                }
            }
        }

    /// place の引数一式。pos = 左上、maxWidth = 折返し幅（pos#x からの幅）、
    /// baseTint = tint 無指定スパンの色、lineGap = 行間（px）。
    pub type alias Placement = {
        atlas = FontAtlas,
        size = Float64,
        baseTint = Color,
        z = Int32,
        pos = Vec2.Vec2,
        maxWidth = Float64,
        lineGap = Float64
    }

    /// スパン列を最大幅で行の列へ折る。折る規則は描画(place)と同一 — 字単位で、収まらない
    /// 字は次の行へ、'\n' でも改行。スパンの属性(tint / bold)は行をまたいでも保たれる。
    /// 字幅は charWidth で外から与える: place は atlas の実測を渡すが、描画の前に行数だけ
    /// 知りたい呼び側(スクロールの勘定・ページ割りなど)は「全角 2・半角 1」のような純粋な
    /// 近似を渡してよい。同じ charWidth を通す限り、勘定と描画の行割りはずれない。
    /// 行数の規約: 空の入力も「空行 1 つ」(結果が Nil になることはない)、末尾の '\n' は
    /// 末尾に空行を残す — 行数を高さの予約に使う呼び側が空文字で 0 行にならないため。
    pub def wrapLinesBy(charWidth: Char -> Float64, maxWidth: Float64, spans: List[Span]): List[List[Span]] =
        // 行の組み立て中は lines(確定行・逆順)/ line(組み立て中の行のスパン・逆順)/
        // chunk(いま処理中のスパンから今の行に積んだ文字・逆順)/ x(行の使用幅)を持ち回る。
        let final = spans |> List.foldLeft((acc, span) -> {
            let s = String.toList(span#text) |> List.foldLeft((st, ch) -> {
                if (ch == '\n')
                    { lines = closeLine(st#chunk, span, st#line) :: st#lines, line = Nil,
                      chunk = (Nil: List[Char]), x = 0.0 }
                else {
                    let w = charWidth(ch);
                    // 行頭(x = 0)では折らない — maxWidth より広い字でも 1 字は必ず置く(無限ループを作らない)。
                    let st1 = if (st#x + w > maxWidth and st#x > 0.0)
                        { lines = closeLine(st#chunk, span, st#line) :: st#lines, line = Nil,
                          chunk = (Nil: List[Char]), x = 0.0 }
                        else st;
                    { chunk = ch :: st1#chunk, x = st1#x + w | st1 }
                }
            }, { lines = acc#lines, line = acc#line, chunk = (Nil: List[Char]), x = acc#x });
            { lines = s#lines, line = pushChunk(s#chunk, span, s#line), x = s#x }
        }, { lines = (Nil: List[List[Span]]), line = (Nil: List[Span]), x = 0.0 });
        List.reverse(List.reverse(final#line) :: final#lines)

    /// 組み立て中のスパン片(逆順の字)を行へ積む(空なら何も足さない)。属性は元スパンから引き継ぐ。
    def pushChunk(chunk: List[Char], span: Span, line: List[Span]): List[Span] =
        if (List.isEmpty(chunk)) line
        else ({ text = charsToString(List.reverse(chunk)) | span }) :: line

    /// 組み立て中の行を確定する(逆順を戻す)。
    def closeLine(chunk: List[Char], span: Span, line: List[Span]): List[Span] =
        List.reverse(pushChunk(chunk, span, line))

    /// スパン列を左上 pos から 1 文字ずつ置いていく。行割りは wrapLinesBy(atlas の実測幅)で、
    /// 太字スパンは半ピクセル右にずらしてもう一度描くことで線を太らせる。
    /// 最小の呼び出し例:
    ///   RichText.place({ atlas = atlas, size = 10.0, baseTint = ink, z = 40,
    ///                    pos = { x = 16.0, y = 180.0 }, maxWidth = 288.0, lineGap = 3.0 },
    ///                  RichText.plain("こんにちは") :: Nil)
    pub def place(p: Placement, spans: List[Span]): List[Render.PlacedItem] =
        wrapLinesBy(ch -> TextDraw.width(Char.toString(ch), p#atlas, p#size), p#maxWidth, spans)
            |> List.zipWithIndex
            |> List.flatMap(pair -> {
                let (i, line) = pair;
                placeLine(p, Int32.toFloat64(i) * (p#size + p#lineGap), line)
            })

    /// 折返し済みの 1 行を y の高さに置く。
    def placeLine(p: Placement, y: Float64, line: List[Span]): List[Render.PlacedItem] =
        // 蓄積は逆順で持つ。reverse を掛けるのはスパンと字の 2 重 fold を抜けた最後の 1 回だけで、
        // 内側の fold ごとに戻すとスパン単位で順序が壊れる。太字の 2 枚目も逆順のまま積むので、
        // 素の字を先に積んでからずらした複製を積む。
        let (rev, _) = line |> List.foldLeft((acc, span) -> {
            let tint = Option.getWithDefault(p#baseTint, span#tint);
            String.toList(span#text) |> List.foldLeft((acc2, ch) -> {
                let (done, x) = acc2;
                let text = Char.toString(ch);
                let at = { x = p#pos#x + x, y = p#pos#y + y };
                let withGlyph = { at = at, item = Render.textTinted(text, p#atlas, p#size, tint, p#z) } :: done;
                let withBold = if (span#bold)
                    { at = { x = at#x + 0.5, y = at#y },
                      item = Render.textTinted(text, p#atlas, p#size, tint, p#z) } :: withGlyph
                else
                    withGlyph;
                (withBold, x + TextDraw.width(text, p#atlas, p#size))
            }, acc)
        }, (Nil, 0.0));
        List.reverse(rev)

    // ── ルビ（ふりがな）──

    /// ルビ 1 つ。start = 親字の頭（plainText の何文字目・0 始まり）、length = 親字の数、text = ふりがな。
    /// Yarn の [ruby=よみ]字[/ruby] は Yarn.markupOf の範囲そのまま（YarnRunner の出来事の Line の text で数える）。
    pub type alias Ruby = { start = Int32, length = Int32, text = String }

    /// 折り返しの 1 単位。親字とルビは 1 つの塊で、行をまたいで割らない。
    enum Piece {
        case Glyph(Char, Span, Int32)
        case Group(List[(Char, Span, Int32)], Ruby)
        case Newline
    }

    /// 字の列をルビの塊ごとに切る（ルビの範囲が字の外・重なる時は、その分は塊にしない）。
    def piecesOf(rubies: List[Ruby], spans: List[Span]): List[Piece] =
        let glyphs = spans |> List.flatMap(span -> String.toList(span#text) |> List.map(ch -> (ch, span)))
                           |> List.zipWithIndex |> List.map(match (i, (ch, span)) -> (ch, span, i));
        let rubyAt = i -> List.find(r -> r#start == i and r#length > 0, rubies);
        def go(rest: List[(Char, Span, Int32)], acc: List[Piece]): List[Piece] = match rest {
            case Nil => List.reverse(acc)
            case (ch, span, i) :: more =>
                if (ch == '\n') go(more, Piece.Newline :: acc)
                else match rubyAt(i) {
                    case Some(r) =>
                        let base = List.take(r#length, rest);
                        if (List.length(base) == r#length and not List.exists(match (c, _, _) -> c == '\n', base))
                            go(List.drop(r#length, rest), Piece.Group(base, r) :: acc)
                        else go(more, Piece.Glyph(ch, span, i) :: acc)
                    case None => go(more, Piece.Glyph(ch, span, i) :: acc)
                }
        };
        go(glyphs, Nil)

    /// 塊の幅。ルビの塊は親字とふりがなの広い方だが、ふりがなは両隣へルビ 1 字ずつ（合わせて rubySize の 2 倍まで）
    /// はみ出してよい（ふりがなの幅まで広げると、1 字の親字に 4 字のよみで前後が大きく空く）。
    def pieceWidth(charWidth: Char -> Float64, rubyWidth: String -> Float64, rubySize: Float64, piece: Piece): Float64 = match piece {
        case Piece.Glyph(ch, _, _) => charWidth(ch)
        case Piece.Group(base, r)  => Float64.max(List.foldLeft((acc, g) -> { let (c, _, _) = g; acc + charWidth(c) }, 0.0, base), rubyWidth(r#text) - 2.0 * rubySize)
        case Piece.Newline         => 0.0
    }

    /// 行頭に来てはいけない字（句読点・閉じ括弧）。はみ出しても前の行の末尾にぶら下げる。
    def isNoLineStart(ch: Char): Bool = String.contains(substr = Char.toString(ch), "、。，．・：；？！ー）」』】〉》〕｝…‥ゝゞぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ,.!?)")

    /// 塊の列を最大幅で行に割る（wrapLinesBy と同じ決まり: 行頭では折らない・'\n' で改行・空でも 1 行）。
    /// 加えて行頭に来てはいけない字はぶら下げる（はみ出しは字 1 つ分まで。続けて来ても 1 つ目だけ）。
    def wrapPieces(charWidth: Char -> Float64, rubyWidth: String -> Float64, rubySize: Float64, maxWidth: Float64, pieces: List[Piece]): List[List[Piece]] =
        let (lines, line, _) = pieces |> List.foldLeft((acc, piece) -> {
            let (done, cur, x) = acc;
            match piece {
                case Piece.Newline => (List.reverse(cur) :: done, Nil, 0.0)
                case _ =>
                    let w = pieceWidth(charWidth, rubyWidth, rubySize, piece);
                    let hangs = match piece {
                        case Piece.Glyph(ch, _, _) => isNoLineStart(ch) and x <= maxWidth
                        case _                     => false
                    };
                    if (x + w > maxWidth and x > 0.0 and not hangs) (List.reverse(cur) :: done, piece :: Nil, w)
                    else (done, piece :: cur, x + w)
            }
        }, (Nil, Nil, 0.0));
        List.reverse(List.reverse(line) :: lines)

    /// ルビつきで折った時の行数（ページ割り・窓の高さの勘定。字幅の決まりは wrapLinesBy と同じ）。
    pub def rubyLineCountBy(charWidth: Char -> Float64, rubyWidth: String -> Float64, rubySize: Float64, maxWidth: Float64,
                            rubies: List[Ruby], spans: List[Span]): Int32 =
        List.length(wrapPieces(charWidth, rubyWidth, rubySize, maxWidth, piecesOf(rubies, spans)))

    /// ルビつきの字を置く。親字の上に rubySize の字でふりがなを中央そろえで載せる（親字より広ければ親字を中央へ寄せる）。
    /// 行割りは全文で決める（visible = 見せる字の数。文字送りの途中でも行が動かない）。ふりがなは親字が全部見えてから出る。
    /// ふりがなは行の上の行間に描くので、lineGap は rubySize 以上にする（1 行目は pos の上に出る）。
    pub def placeRuby(p: Placement, rubySize: Float64, rubies: List[Ruby], visible: Int32, spans: List[Span]): List[Render.PlacedItem] =
        let cw = ch -> TextDraw.width(Char.toString(ch), p#atlas, p#size);
        let rw = text -> TextDraw.width(text, p#atlas, rubySize);
        wrapPieces(cw, rw, rubySize, p#maxWidth, piecesOf(rubies, spans))
            |> List.zipWithIndex
            |> List.flatMap(match (row, line) -> {
                let y = p#pos#y + Int32.toFloat64(row) * (p#size + p#lineGap);
                withOffsets(piece -> pieceWidth(cw, rw, rubySize, piece), line)
                    |> List.flatMap(match (piece, x) -> placePiece(p, rubySize, cw, rw, visible, piece, p#pos#x + x, y))
            })

    /// 並びの各要素に、その頭までの幅の合計を添える。
    def withOffsets(width: a -> Float64, xs: List[a]): List[(a, Float64)] =
        let (rev, _) = List.foldLeft((acc, x) -> { let (out, at) = acc; ((x, at) :: out, at + width(x)) }, (Nil, 0.0), xs);
        List.reverse(rev)

    /// 塊 1 つを x, y に置く（ルビの塊は親字を塊の幅の中央へ・ふりがなを上へ）。
    def placePiece(p: Placement, rubySize: Float64, cw: Char -> Float64, rw: String -> Float64, visible: Int32,
                   piece: Piece, x: Float64, y: Float64): List[Render.PlacedItem] = match piece {
        case Piece.Glyph(ch, span, i) => if (i < visible) glyphItems(p, span, ch, x, y) else Nil
        case Piece.Group(base, r) =>
            let w = pieceWidth(cw, rw, rubySize, piece);
            let baseW = List.foldLeft((sum, g) -> { let (c, _, _) = g; sum + cw(c) }, 0.0, base);
            let chars = withOffsets(match (c, _, _) -> cw(c), base)
                |> List.flatMap(match ((c, span, i), bx) -> if (i < visible) glyphItems(p, span, c, x + (w - baseW) / 2.0 + bx, y) else Nil);
            let tint = base |> List.head |> Option.flatMap(match (_, span, _) -> span#tint) |> Option.getWithDefault(p#baseTint);
            if (r#start + r#length <= visible)
                List.append(chars, { at = { x = x + (w - rw(r#text)) / 2.0, y = y - rubySize - 1.0 },
                                     item = Render.textTinted(r#text, p#atlas, rubySize, tint, p#z) } :: Nil)
            else chars
        case Piece.Newline => Nil
    }

    /// 字 1 つ（太字なら半ピクセルずらしてもう 1 枚）。
    def glyphItems(p: Placement, span: Span, ch: Char, x: Float64, y: Float64): List[Render.PlacedItem] =
        let tint = Option.getWithDefault(p#baseTint, span#tint);
        let text = Char.toString(ch);
        let one = { at = { x = x, y = y }, item = Render.textTinted(text, p#atlas, p#size, tint, p#z) };
        if (span#bold) one :: { at = { x = x + 0.5, y = y }, item = Render.textTinted(text, p#atlas, p#size, tint, p#z) } :: Nil
        else one :: Nil
}
